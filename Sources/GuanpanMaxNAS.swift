import Foundation

// MARK: - 观盘max NAS 适配层
//
// 观盘max = 仓库 guanpan-f（App 显示名「观盘max」，代码名 GuanpanF）。
// 它的 NAS 是 f-minute-archive：独立进程、默认 8788、按交易日归档历史数据。
//
// 三套服务绝不能共用一个地址：
//   · Pro 账本同步    /api/native/*     Pro 自己的协议
//   · 观盘Next 服务端 /v1/market/*     30001，实时行情转发（可选）
//   · 观盘max NAS     /api/v1/*        8788，归档历史 + 研究证据
//
// 最重要的口径：**观盘max NAS 没有实时报价接口**。
// 它给的是已完成交易日的日 K、分钟线与统计证据。直连腾讯失败时可以用它补历史，
// 但不能把归档收盘价包装成「实时价」塞进 Quote —— 那会让估值门禁误判数据可信。
//
// 另外：部署包（Downloads/guanpanF）是较旧的一版，只有分钟线/研究证据路由；
// 工作区 repo/guanpan-f/nas 的完整版还多了证券日 K、指数日 K、回填状态。
// 所以下面每个新接口都按「有就用、没有就 404 静默降级」处理，绝不阻断原有链路。

enum GuanpanMaxNAS {

    // 沿用 2.20.0 里用户已经填过的地址。换个名字不该让人重填一遍。
    static let urlKey = "guanpan.pro.fminute.url"
    static let serviceIdentifier = "f-minute-archive"

    /// 归档日线的来源标识，来自 nas/fminute/index_history.py 的 SOURCE / NAVER_KOSPI_SOURCE。
    /// 白名单而不是「非空即可」：NAS 上若换了没核对过的采集源，宁可不采信。
    static let trustedDailySources: Set<String> = [
        "Tencent Finance daily K-line (archived by F NAS)",
        "Naver Finance KOSPI daily chart (public web endpoint)"
    ]

    static var baseURLString: String {
        UserDefaults.standard.string(forKey: urlKey) ?? ""
    }

    static var normalizedBase: String? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static var isConfigured: Bool { normalizedBase != nil }

    static func save(_ address: String) {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
        // 换了地址，之前「这个服务不支持某能力」的结论全部作废。
        ResearchEvidenceProbe.clear()
    }

    /// 归档服务只认 6 位纯数字 A 股代码（provider 的 _instrument_symbol 会自己拼 sh/sz）。
    /// Pro 内部持仓码是 sh600519 形态，不剥前缀会被判 400，而 400 长得和「样本不够」一样。
    static func normalizedSecurityCode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = value.replacingOccurrences(of: "^(sh|sz|bj|hk|us)", with: "", options: .regularExpression)
        guard digits.count == 6, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return digits
    }

    // MARK: 请求与解析工具

    private static func request(path: String,
                                query: [URLQueryItem] = [],
                                timeout: TimeInterval = 15) async throws -> (Data, Int) {
        guard let base = normalizedBase,
              var components = URLComponents(string: base + path) else { throw URLError(.badURL) }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func canonicalDay(_ text: String) -> Date? {
        guard let date = dayFormatter.date(from: text),
              dayFormatter.string(from: date) == text else { return nil }
        return date
    }

    private static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// 归档新鲜度：服务端盖章时间不能来自未来，也不能旧过 36 小时。
    private static func isFresh(_ fetchedAt: String?, now: Date) -> Bool {
        guard let stamp = parseTimestamp(fetchedAt), stamp <= now,
              now.timeIntervalSince(stamp) <= 36 * 3600 else { return false }
        return true
    }

    // MARK: 探活与能力摘要

    /// /livez 验身份，/readyz 只用来补充能力描述。
    /// 身份校验必须硬：同一个端口上挂别的服务时，「能连上」比「连不上」更难查。
    static func probe() async throws -> String {
        let (liveData, liveStatus) = try await request(path: "/livez", timeout: 8)
        guard liveStatus == 200,
              let live = (try? JSONSerialization.jsonObject(with: liveData)) as? [String: Any],
              live["service"] as? String == serviceIdentifier else {
            throw URLError(.cannotParseResponse)
        }
        var parts = ["连接正常 · \(serviceIdentifier) 在线"]
        // 旧部署包的 /readyz 字段较少，拿不到不能判失败。
        if let (readyData, readyStatus) = try? await request(path: "/readyz", timeout: 12),
           readyStatus == 200,
           let ready = (try? JSONSerialization.jsonObject(with: readyData)) as? [String: Any] {
            if let markets = ready["configuredMarkets"] as? [String], !markets.isEmpty {
                parts.append("市场 " + markets.joined(separator: "/"))
            }
            if let state = ready["status"] as? String {
                parts.append(state == "ready" ? "归档已就绪" : "归档未就绪")
            }
            if let worker = ready["realtimeWorker"] as? [String: Any],
               let value = worker["status"] as? String { parts.append("实时采集 " + value) }
            if let worker = ready["backfillWorker"] as? [String: Any],
               let value = worker["status"] as? String { parts.append("历史补采 " + value) }
            if let history = ready["indexDailyHistory"] as? [String: Any],
               let value = history["status"] as? String { parts.append("日K " + value) }
        }
        ResearchEvidenceProbe.clear()
        return parts.joined(separator: " · ")
    }

    // MARK: 证券日 K

    private struct SecurityDailyResponse: Decodable {
        struct Bar: Decodable {
            let tradingDate: String
            let open: String
            let close: String
            let high: String
            let low: String
            let volume: String
        }
        let securityCode: String
        let status: String
        let source: String
        let fetchedAt: String?
        let sampleCount: Int
        let adjustment: String
        let bars: [Bar]
        let unavailableReason: String?
    }

    /// 直连腾讯全失败后的历史日线兜底。校验口径与观盘max 客户端一致：
    /// 来源、盖章时间、复权方式、样本数、日期严格递增、最后交易日不超过 5 天。
    /// 任何一条不满足就整份丢弃，不拿残缺数据凑数。
    static func securityDaily(code: String, now: Date = .now) async throws -> [DailyBar] {
        guard let digits = normalizedSecurityCode(code) else { throw URLError(.badURL) }
        let (data, status) = try await request(
            path: "/api/v1/security-daily-history",
            query: [URLQueryItem(name: "securityCode", value: digits)], timeout: 20)
        guard status == 200 else { throw URLError(.badServerResponse) }
        guard let body = try? JSONDecoder().decode(SecurityDailyResponse.self, from: data),
              body.securityCode == digits,
              body.status == "available",
              body.adjustment == "不复权",
              trustedDailySources.contains(body.source),
              body.sampleCount == body.bars.count,
              body.bars.count >= 60,
              isFresh(body.fetchedAt, now: now) else {
            throw URLError(.cannotParseResponse)
        }
        var result: [DailyBar] = []
        result.reserveCapacity(body.bars.count)
        var previous: Date?
        let todayText = dayFormatter.string(from: now)
        for row in body.bars {
            // tradingDate 必须是已完成交易日：当天那根还没收盘，不能进历史。
            guard row.tradingDate < todayText,
                  let day = canonicalDay(row.tradingDate), day < now,
                  let open = Double(row.open), let close = Double(row.close),
                  let high = Double(row.high), let low = Double(row.low),
                  let volume = Double(row.volume),
                  close > 0, volume >= 0,
                  high >= max(open, close), low <= min(open, close), high >= low else {
                throw URLError(.cannotParseResponse)
            }
            if let previous, previous >= day { throw URLError(.cannotParseResponse) }
            previous = day
            result.append(DailyBar(code: code, date: row.tradingDate, open: open,
                                   close: close, high: high, low: low, volume: volume))
        }
        guard let lastDay = canonicalDay(result.last?.date ?? ""),
              now.timeIntervalSince(lastDay) <= 5 * 86_400 else {
            throw URLError(.cannotParseResponse)
        }
        return result
    }

    // MARK: 指数日 K（只取交易日，不编造 OHLCV）

    /// 观盘max 的指数归档**只有 close 是必填**，OHLCV 可以整段缺失。
    /// Pro 的 DailyBar 四个字段都是非 optional Double，填 0 或拿 close 冒充就是编造数据。
    /// 所以这里只返回交易日列表，专门给交易日历反推用 —— 不写进 dailyBars，
    /// 也就不会污染 MACD、图表和市场状态因子。
    static func indexTradingDays(indexCode: String, now: Date = .now) async throws -> [String] {
        // 只认 A 股指数：时区固定 Asia/Shanghai，日历口径才和交易日历一致。
        let supported: Set<String> = ["sh000001", "sh000300", "sh000510", "sz399001", "sz399006"]
        guard supported.contains(indexCode) else { throw URLError(.badURL) }
        let (data, status) = try await request(
            path: "/api/v1/index-daily-history",
            query: [URLQueryItem(name: "indexCode", value: indexCode)], timeout: 20)
        guard status == 200 else { throw URLError(.badServerResponse) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["indexCode"] as? String == indexCode,
              object["status"] as? String == "available",
              object["timezone"] as? String == "Asia/Shanghai",
              let source = object["source"] as? String, trustedDailySources.contains(source),
              let sampleCount = object["sampleCount"] as? Int,
              let rows = object["bars"] as? [[String: Any]],
              sampleCount == rows.count, rows.count > 120,
              isFresh(object["fetchedAt"] as? String, now: now) else {
            throw URLError(.cannotParseResponse)
        }
        var days: [String] = []
        days.reserveCapacity(rows.count)
        var previous: Date?
        let todayText = dayFormatter.string(from: now)
        for row in rows {
            guard let text = row["tradingDate"] as? String, text < todayText,
                  let day = canonicalDay(text), day < now,
                  let closeText = row["close"] as? String,
                  let close = Double(closeText), close > 0 else {
                throw URLError(.cannotParseResponse)
            }
            if let previous, previous >= day { throw URLError(.cannotParseResponse) }
            previous = day
            days.append(text)
        }
        return days
    }

    // MARK: 分钟归档诊断

    /// 给设置页看的「地址通了，但样本够不够」。
    /// 研究证据要求 ≥25 个达标交易日；不够时接口返回 400，客户端静默降级，
    /// 这里把原因显式说出来，免得用户以为功能坏了。
    static func minuteDiagnostics(code: String) async throws -> String {
        guard let digits = normalizedSecurityCode(code) else { throw URLError(.badURL) }
        let (data, status) = try await request(
            path: "/api/v1/minute-history/diagnostics",
            query: [URLQueryItem(name: "securityCode", value: digits),
                    URLQueryItem(name: "market", value: "CN")], timeout: 15)
        guard status == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let days = object["days"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        let complete = days.filter { ($0["completeness"] as? String) == "complete" }.count
        let queued = object["queuedBackfillSessions"] as? Int ?? 0
        return "分钟归档 \(days.count) 个交易日 · 完整 \(complete) 天 · 待补采 \(queued) 天"
    }

    // MARK: 研究证据

    /// 契约以 NAS 实际部署为准：
    /// GET /api/v1/minute-history/research?securityCode=&market=&startDate=&endDate=&asOf=
    static func researchEvidence(code: String,
                                 lookbackDays: Int = 120,
                                 now: Date = .now) async -> ResearchEvidenceEnvelope? {
        guard !ResearchEvidenceProbe.isSuppressed,
              normalizedBase != nil,
              let securityCode = normalizedSecurityCode(code) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayFormatter.timeZone
        guard let start = calendar.date(byAdding: .day, value: -lookbackDays, to: now) else { return nil }
        // 服务端要求 asOf 不晚于它自己盖章的 generatedAt。手机快几秒就会 400，留 30 秒余量。
        let asOf = now.addingTimeInterval(-30)
        let stamp = ISO8601DateFormatter().string(from: asOf)
        let query = [
            URLQueryItem(name: "securityCode", value: securityCode),
            URLQueryItem(name: "market", value: "CN"),
            URLQueryItem(name: "startDate", value: dayFormatter.string(from: start)),
            URLQueryItem(name: "endDate", value: dayFormatter.string(from: now)),
            URLQueryItem(name: "asOf", value: stamp),
            URLQueryItem(name: "minimumIndependentDays", value: String(ResearchEvidenceEnvelope.minimumIndependentDays)),
            URLQueryItem(name: "minimumQuality", value: String(ResearchEvidenceEnvelope.minimumQualityGate))
        ]
        guard let (data, status) = try? await request(
            path: "/api/v1/minute-history/research", query: query, timeout: 20) else { return nil }
        switch status {
        case 200:
            break
        case 404, 501:
            // 这个服务上根本没有 research 路由，记下来 6 小时内别再问。
            ResearchEvidenceProbe.markUnsupported()
            return nil
        default:
            // 400 是区间/样本问题，属于「这次没数据」而不是「能力不存在」。
            return nil
        }
        guard data.count <= 1_048_576 else { return nil }
        // 服务端可能按别的键缓存过响应。先对一次标的与市场，
        // 否则「A 票的证据」会被写进 B 票的 prompt。
        guard let envelope = try? JSONDecoder().decode(ResearchEvidenceEnvelope.self, from: data),
              envelope.securityCode.trimmingCharacters(in: .whitespacesAndNewlines) == securityCode,
              envelope.market == "CN" else { return nil }
        return envelope
    }
}
