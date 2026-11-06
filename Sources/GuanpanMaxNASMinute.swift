import Foundation

// MARK: - 观盘max NAS 归档分钟线
//
// 观盘max 客户端（repo/guanpan-f/GuanpanFApp/Sources/FNASConnection.swift）里最厚的
// 一块就是历史分钟归档。这里按同一套口径移植到 Pro：
//
//   · 响应逐条校验：来源白名单、时间戳落在所问交易日、价格为正、成交量非负、
//     采集时间不早于该分钟也不来自未来；
//   · 同一分钟重复只保留第一条，客户端剔除过记录就不许再自称 complete；
//   · 完整度元数据（quality/completeness/volume/缺失点）与声明不一致时降为 partial；
//   · 200 但形状不对时给出具体诊断（字段缺失、代码不符、返回了 HTML），
//     不用「网络错误」把真实原因盖掉；
//   · 只有 404/405 才去试观盘Next 的旧分钟接口，且旧接口一律标
//     legacy-unassessed —— 它没有完整度、质量与采集时间，不能当完整数据用。
//
// 红线：这份数据是「只读归档回放」，绝不写进 Pro 的 intradayBars。
// IntradayBar 没有来源字段，写进去以后就无法区分「本机采集」与「NAS 归档」，
// 会把两种口径混成一份。

struct MaxNASMinuteSample: Equatable, Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let price: Double
    let volume: Double?
}

struct MaxNASArchivedIntraday {
    let securityCode: String
    let tradingDate: String
    /// complete / partial / missing / not-a-session / legacy-unassessed
    let coverageStatus: String
    let coverageSummary: String
    let sourceSummary: String
    let fetchedAt: Date
    let samples: [MaxNASMinuteSample]

    var isComplete: Bool { coverageStatus == "complete" }
    var hasSamples: Bool { !samples.isEmpty }
}

enum MaxNASMinuteError: Error, LocalizedError {
    case invalidAddress
    case historyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "观盘max NAS 地址无效；请填写 http(s)://主机:8788。"
        case let .historyUnavailable(reason):
            return "NAS 分钟归档读取失败：\(reason)"
        }
    }
}

enum GuanpanMaxNASMinuteArchive {

    /// 归档库里存的是 provider 的英文标识（nas/fminute/providers.py 的 name）。
    /// 中文别名只为兼容早期部署，新数据一律走英文。
    static let trustedMinuteSources: Set<String> = [
        "Tencent Finance minute/query (public web endpoint)",
        "Eastmoney push2his 1-minute kline (public web endpoint)",
        "腾讯财经 minute/query（公开网页接口）",
        "东方财富 push2his 1 分钟 K 线（公开网页接口）"
    ]

    private static func isTrustedSource(_ text: String?) -> Bool {
        guard let text else { return false }
        return trustedMinuteSources.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func canonicalDay(_ text: String) -> Bool {
        guard let date = dayFormatter.date(from: text) else { return false }
        return dayFormatter.string(from: date) == text
    }

    // MARK: 响应模型

    /// 手写解码：部署包与完整版对 securityCode / tradingDate 的键名、数值类型
    /// 并不完全一致（蛇形、纯数字代码、price 为字符串、bars 为 null 都出现过）。
    /// 这些是「形状差异」不是「数据错误」，逐个兼容，但不放宽数值校验。
    private struct HistoryResponse: Decodable {
        struct Coverage: Decodable {
            let status: String?
            let expectedCount: Int?
            let observedCount: Int?
            let missingTimestamps: [String]?
            let qualityPassed: Bool?
            let completenessPassed: Bool?
            let volumePassed: Bool?

            private enum CodingKeys: String, CodingKey {
                case status, expectedCount, observedCount, missingTimestamps
                case qualityPassed, completenessPassed, volumePassed
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                status = try? values.decodeIfPresent(String.self, forKey: .status)
                expectedCount = try? values.decodeIfPresent(Int.self, forKey: .expectedCount)
                observedCount = try? values.decodeIfPresent(Int.self, forKey: .observedCount)
                missingTimestamps = try? values.decodeIfPresent([String].self, forKey: .missingTimestamps)
                qualityPassed = try? values.decodeIfPresent(Bool.self, forKey: .qualityPassed)
                completenessPassed = try? values.decodeIfPresent(Bool.self, forKey: .completenessPassed)
                volumePassed = try? values.decodeIfPresent(Bool.self, forKey: .volumePassed)
            }
        }

        struct Bar: Decodable {
            let timestamp: String
            let price: Double
            let securityCode: String?
            let market: String?
            let tradingDate: String?
            let source: String?
            let fetchedAt: String?
            let minuteVolume: Double?

            private enum CodingKeys: String, CodingKey {
                case timestamp, price, securityCode, security_code, market
                case tradingDate, trading_date, source, fetchedAt, minuteVolume, volume
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                timestamp = try values.decode(String.self, forKey: .timestamp)
                if let numeric = try? values.decode(Double.self, forKey: .price) {
                    price = numeric
                } else if let text = try? values.decode(String.self, forKey: .price),
                          let numeric = Double(text) {
                    price = numeric
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .price, in: values,
                        debugDescription: "price must be numeric or numeric string")
                }
                if let text = try? values.decode(String.self, forKey: .securityCode) {
                    securityCode = text
                } else if let number = try? values.decode(Int.self, forKey: .securityCode) {
                    securityCode = String(number)
                } else if let text = try? values.decode(String.self, forKey: .security_code) {
                    securityCode = text
                } else if let number = try? values.decode(Int.self, forKey: .security_code) {
                    securityCode = String(number)
                } else {
                    securityCode = nil
                }
                market = try? values.decodeIfPresent(String.self, forKey: .market)
                tradingDate = (try? values.decodeIfPresent(String.self, forKey: .tradingDate))
                    ?? (try? values.decodeIfPresent(String.self, forKey: .trading_date)) ?? nil
                source = try? values.decodeIfPresent(String.self, forKey: .source)
                fetchedAt = try? values.decodeIfPresent(String.self, forKey: .fetchedAt)
                if let numeric = try? values.decodeIfPresent(Double.self, forKey: .minuteVolume) {
                    minuteVolume = numeric
                } else if let numeric = try? values.decodeIfPresent(Double.self, forKey: .volume) {
                    minuteVolume = numeric
                } else if let text = try? values.decodeIfPresent(String.self, forKey: .minuteVolume),
                          let numeric = Double(text) {
                    minuteVolume = numeric
                } else if let text = try? values.decodeIfPresent(String.self, forKey: .volume),
                          let numeric = Double(text) {
                    minuteVolume = numeric
                } else {
                    minuteVolume = nil
                }
            }
        }

        let securityCode: String
        let market: String
        let tradingDate: String
        let status: String
        let coverage: Coverage?
        let bars: [Bar]

        private enum CodingKeys: String, CodingKey {
            case securityCode, security_code, market, tradingDate, trading_date, status, coverage, bars
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? values.decode(String.self, forKey: .securityCode) {
                securityCode = text
            } else if let number = try? values.decode(Int.self, forKey: .securityCode) {
                securityCode = String(number)
            } else if let text = try? values.decode(String.self, forKey: .security_code) {
                securityCode = text
            } else if let number = try? values.decode(Int.self, forKey: .security_code) {
                securityCode = String(number)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .securityCode, in: values,
                    debugDescription: "securityCode must be a string or integer")
            }
            market = try values.decode(String.self, forKey: .market)
            if let text = try? values.decode(String.self, forKey: .tradingDate) {
                tradingDate = text
            } else {
                tradingDate = try values.decode(String.self, forKey: .trading_date)
            }
            status = (try? values.decodeIfPresent(String.self, forKey: .status)) ?? "partial"
            coverage = try? values.decodeIfPresent(Coverage.self, forKey: .coverage)
            let hasBars = values.contains(.bars)
            let barsAreNull = hasBars ? try values.decodeNil(forKey: .bars) : true
            if !hasBars || barsAreNull {
                bars = []
            } else {
                // 畸形 bar 不能静默变成空归档：调用方需要看到响应形状诊断，
                // 否则一个 HTTP 200 会把「接口返回了别的东西」伪装成「这天没数据」。
                bars = try values.decode([Bar].self, forKey: .bars)
            }
        }
    }

    /// 观盘Next 的旧分钟接口（30001 的 /v1/market/minute/<code>）。
    /// 它没有完整度、质量与采集时间，只能标 legacy-unassessed。
    private struct LegacyResponse: Decodable {
        struct Bar: Decodable {
            let timestamp: String
            let price: String
            let volume: String?
        }
        let code: String
        let day: String
        let source: String
        let rows: [Bar]
    }

    // MARK: 主入口

    /// 读取某个已完成交易日的归档分钟线。
    /// - Parameter tradingDate: Asia/Shanghai 日历日，格式 yyyy-MM-dd。
    static func fetch(code: String, tradingDate: String) async throws -> MaxNASArchivedIntraday {
        guard GuanpanMaxNAS.validateAddress() != nil,
              let digits = GuanpanMaxNAS.normalizedSecurityCode(code),
              canonicalDay(tradingDate) else { throw MaxNASMinuteError.invalidAddress }

        let query = [
            URLQueryItem(name: "securityCode", value: digits),
            URLQueryItem(name: "market", value: "CN"),
            URLQueryItem(name: "tradingDate", value: tradingDate),
            URLQueryItem(name: "minimumQuality", value: "80")
        ]
        let (data, http) = try await GuanpanMaxNAS.rawRequest(
            path: "/api/v1/minute-history", query: query, timeout: 20)

        var modernFailure: String?
        if (200..<300).contains(http.statusCode) {
            let body: HistoryResponse
            do {
                body = try JSONDecoder().decode(HistoryResponse.self, from: data)
            } catch {
                throw MaxNASMinuteError.historyUnavailable(
                    responseFailure(data: data, response: http,
                                    expectedCode: digits, expectedDay: tradingDate)
                    + "；解码位置：" + Self.decodingFailure(error))
            }
            guard body.securityCode == digits,
                  body.market.uppercased() == "CN",
                  body.tradingDate == tradingDate else {
                throw MaxNASMinuteError.historyUnavailable(
                    responseFailure(data: data, response: http,
                                    expectedCode: digits, expectedDay: tradingDate))
            }
            let archive = makeArchive(body: body, securityCode: digits, dateText: tradingDate)
            if archive.hasSamples { return archive }
            // 服务端明确说「这天没有数据」是数据可用性结论，不是接口故障。
            // 保持 Missing 可见，别再去探一条无关的旧路由、把 200+Missing 变成假错误。
            let status = body.status.lowercased()
            if ["missing", "not-a-session", "out_of_provider_coverage",
                "permanent_unavailable", "retryable"].contains(status) {
                return archive
            }
            modernFailure = "该交易日没有归档分钟点（\(body.status)）"
        } else {
            modernFailure = responseFailure(data: data, response: http,
                                            expectedCode: digits, expectedDay: tradingDate)
        }

        // 只有「当前接口不存在」才试旧路由。200 但形状不对、或传输失败时，
        // 再发一次无关请求只会追加一个 404，把第一个有用的错误盖掉。
        guard http.statusCode == 404 || http.statusCode == 405 else {
            throw MaxNASMinuteError.historyUnavailable(
                modernFailure ?? "HTTP \(http.statusCode)，未取得可用分钟点")
        }
        do {
            return try await fetchLegacy(code: digits, day: tradingDate)
        } catch {
            throw MaxNASMinuteError.historyUnavailable(
                "\(modernFailure ?? "归档接口不可用")；观盘Next 兼容接口也未取得数据：\(error.localizedDescription)")
        }
    }

    // MARK: 归档构造与降级

    private static func makeArchive(body: HistoryResponse,
                                    securityCode: String,
                                    dateText: String) -> MaxNASArchivedIntraday {
        let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let minuteFormatter = DateFormatter()
        minuteFormatter.locale = Locale(identifier: "en_US_POSIX")
        minuteFormatter.timeZone = zone
        minuteFormatter.calendar = Calendar(identifier: .gregorian)
        minuteFormatter.isLenient = false
        minuteFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dayStart = minuteFormatter.date(from: dateText + " 00:00") ?? Date.distantPast
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? Date.distantFuture
        let validationTime = Date()

        let samples: [MaxNASMinuteSample] = body.bars.compactMap { bar in
            guard bar.securityCode == nil || bar.securityCode == securityCode,
                  bar.market == nil || bar.market?.uppercased() == "CN",
                  bar.tradingDate == nil || bar.tradingDate == dateText,
                  isTrustedSource(bar.source) else { return nil }
            guard let stamp = parseTimestamp(bar.timestamp),
                  stamp >= dayStart, stamp < dayEnd, stamp <= validationTime,
                  bar.price > 0, bar.price.isFinite,
                  bar.minuteVolume.map { $0 >= 0 && $0.isFinite } ?? true else { return nil }
            if let fetchedAtText = bar.fetchedAt {
                guard let fetchedAt = parseTimestamp(fetchedAtText),
                      fetchedAt >= stamp, fetchedAt <= validationTime else { return nil }
            }
            return MaxNASMinuteSample(timestamp: stamp, price: bar.price,
                                      volume: bar.minuteVolume)
        }
        let unique = Dictionary(samples.map { ($0.timestamp, $0) },
                                uniquingKeysWith: { first, _ in first })
        let ordered = unique.keys.sorted().compactMap { unique[$0] }
        let discardedCount = body.bars.count - ordered.count

        let reportedStatus = body.status.lowercased()
        let coverageConsistent: Bool = {
            guard let coverage = body.coverage,
                  coverage.status?.lowercased() == "complete",
                  coverage.qualityPassed == true,
                  coverage.completenessPassed == true,
                  coverage.volumePassed == true,
                  let expected = coverage.expectedCount, expected > 0,
                  let observed = coverage.observedCount, observed == expected,
                  observed == body.bars.count,
                  let missing = coverage.missingTimestamps, missing.isEmpty else { return false }
            return true
        }()
        let missingProvenance = body.bars.contains { bar in
            !isTrustedSource(bar.source) || bar.fetchedAt.flatMap(parseTimestamp) == nil
        }
        let qualityFailed = body.coverage?.qualityPassed == false
        let needsDowngrade = discardedCount > 0 || missingProvenance || !coverageConsistent
        let effectiveStatus = (needsDowngrade && reportedStatus == "complete")
            ? "partial" : body.status

        let coverageSummary: String
        if let coverage = body.coverage {
            let expected = coverage.expectedCount.map { String($0) } ?? "未知"
            let observed = coverage.observedCount ?? ordered.count
            let missing = coverage.missingTimestamps?.count
            let quality = coverage.qualityPassed.map { $0 ? " · 质量合格" : " · 质量未达标" } ?? ""
            let discarded = discardedCount > 0 ? " · 客户端剔除 \(discardedCount) 条无效/重复记录" : ""
            let provenance = missingProvenance ? " · 来源未验证或采集时间缺失，降为 Partial" : ""
            let downgrade = !coverageConsistent && reportedStatus == "complete"
                ? (qualityFailed ? " · 质量门未通过，降为 Partial" : " · 完整度元数据缺失或不一致，降为 Partial")
                : ""
            coverageSummary = "\(effectiveStatus) · \(observed)/\(expected) 点 · 缺失 \(missing.map { String($0) } ?? "未知") 点\(quality)\(discarded)\(provenance)\(downgrade)"
        } else {
            coverageSummary = "\(effectiveStatus) · NAS 未提供完整度统计"
        }

        let sources = Array(Set(body.bars.compactMap { $0.source })).sorted().joined(separator: ", ")
        return MaxNASArchivedIntraday(
            securityCode: securityCode, tradingDate: dateText,
            coverageStatus: effectiveStatus, coverageSummary: coverageSummary,
            sourceSummary: sources.isEmpty ? "无有效来源" : sources,
            fetchedAt: Date(), samples: ordered)
    }

    // MARK: 旧接口兜底

    private static func fetchLegacy(code: String, day: String) async throws -> MaxNASArchivedIntraday {
        guard let base = FNASBridge.normalizedBase,
              let url = URL(string: base + "/v1/market/minute/" + code
                            + "?day=" + day) else {
            throw MaxNASMinuteError.invalidAddress
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await GuanpanMaxNAS.boundedData(for: request,
                                                                maximumBytes: 4_000_000)
        guard (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode(LegacyResponse.self, from: data),
              body.code == code, body.day == day,
              !body.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaxNASMinuteError.historyUnavailable("旧分钟接口没有该日期可用的数据")
        }
        guard let dayStart = dayFormatter.date(from: day) else {
            throw MaxNASMinuteError.historyUnavailable("交易日格式无效")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? Date.distantFuture
        let samples: [MaxNASMinuteSample] = body.rows.compactMap { row in
            guard let stamp = parseTimestamp(row.timestamp),
                  stamp >= dayStart, stamp < dayEnd,
                  let price = Double(row.price), price > 0, price.isFinite else { return nil }
            let volume = row.volume.flatMap { Double($0) }
            return MaxNASMinuteSample(timestamp: stamp, price: price, volume: volume)
        }
        let unique = Dictionary(samples.map { ($0.timestamp, $0) },
                                uniquingKeysWith: { first, _ in first })
        let ordered = unique.keys.sorted().compactMap { unique[$0] }
        guard !ordered.isEmpty else {
            throw MaxNASMinuteError.historyUnavailable("旧分钟接口有响应，但没有可用的分钟点")
        }
        return MaxNASArchivedIntraday(
            securityCode: code, tradingDate: day,
            coverageStatus: "legacy-unassessed",
            coverageSummary: "\(ordered.count) 个真实分钟点 · 兼容接口未提供完整度、质量与采集时间；完整性/新鲜度未知",
            sourceSummary: "观盘Next 兼容接口 · \(body.source)",
            fetchedAt: Date(), samples: ordered)
    }

    // MARK: 诊断

    /// 200 但形状不对时，把「哪里不对」说清楚。
    /// 最常见的一类事故是反向代理把 API 路径映射到了网页首页，
    /// 这时 Content-Type 是 text/html，笼统报「解码失败」根本没法排查。
    private static func responseFailure(data: Data, response: HTTPURLResponse,
                                        expectedCode: String,
                                        expectedDay: String) -> String {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "未知 Content-Type"
        if contentType.localizedCaseInsensitiveContains("text/html") {
            return "HTTP \(response.statusCode) 返回了网页而非分钟 JSON（\(contentType)）；API 路径可能未映射到归档服务"
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "HTTP \(response.statusCode) 响应不是可识别的分钟 JSON（\(contentType)）"
        }
        var problems: [String] = []
        let serverMessage = (object["error"] as? String).map { String($0.prefix(180)) }
        let returnedCode = object["securityCode"] ?? object["security_code"]
        if let returnedCode {
            if scalar(returnedCode) != expectedCode {
                problems.append("证券代码期望 \(expectedCode)，实际 \(scalar(returnedCode))")
            }
        } else {
            problems.append("缺少 securityCode")
        }
        let returnedDay = object["tradingDate"] ?? object["trading_date"]
        if let returnedDay {
            if scalar(returnedDay) != expectedDay {
                problems.append("交易日期望 \(expectedDay)，实际 \(scalar(returnedDay))")
            }
        } else {
            problems.append("缺少 tradingDate")
        }
        if let market = object["market"] {
            if scalar(market).uppercased() != "CN" {
                problems.append("市场期望 CN，实际 \(scalar(market))")
            }
        } else {
            problems.append("缺少 market")
        }
        if let bars = object["bars"] as? [[String: Any]], let first = bars.first {
            let keys = Set(first.keys)
            if !(keys.contains("timestamp") && keys.contains("price")) {
                problems.append("bars 首条缺少 timestamp/price（实际字段：\(keys.sorted().joined(separator: ", "))）")
            } else if !(first["timestamp"] is String)
                        || (!(first["price"] is String) && !(first["price"] is NSNumber)) {
                problems.append("bars 首条 timestamp/price 类型不兼容")
            }
            let rowCode = first["securityCode"] ?? first["security_code"]
            if let rowCode, scalar(rowCode) != expectedCode {
                problems.append("bars 首条证券代码与请求不符")
            }
        } else if let rawBars = object["bars"], !(rawBars is NSNull), !(rawBars is [Any]) {
            problems.append("bars 应为数组，实际类型不符")
        }
        let shape = problems.isEmpty ? "响应内容无法解码为分钟记录" : problems.joined(separator: "；")
        let reason = [serverMessage.map { "服务端说明：\($0)" }, Optional(shape)]
            .compactMap { $0 }.joined(separator: "；")
        return "HTTP \(response.statusCode) 分钟响应校验失败：\(reason)（顶层字段：\(object.keys.sorted().joined(separator: ", "))）"
    }

    private static func decodingFailure(_ error: Error) -> String {
        func path(_ context: DecodingError.Context, appending key: String? = nil) -> String {
            let parts = context.codingPath.map { $0.stringValue } + (key.map { [$0] } ?? [])
            return parts.isEmpty ? "<根对象>" : parts.joined(separator: ".")
        }
        guard let decodingError = error as? DecodingError else {
            return "响应无法解码（\(error.localizedDescription)）"
        }
        switch decodingError {
        case let DecodingError.keyNotFound(key, context):
            return "缺少字段 \(path(context, appending: key.stringValue))"
        case let DecodingError.typeMismatch(type, context):
            return "字段 \(path(context)) 类型不符（期望 \(String(describing: type))）"
        case let DecodingError.valueNotFound(type, context):
            return "字段 \(path(context)) 值为空（期望 \(String(describing: type))）"
        case let DecodingError.dataCorrupted(context):
            return "字段 \(path(context)) 数据损坏"
        }
    }

    private static func scalar(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "null" }
        return String(describing: type(of: value))
    }
}
