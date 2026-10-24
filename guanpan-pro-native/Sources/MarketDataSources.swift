import Foundation

/// 行情多源链：按顺序尝试每个源，第一个成功的结果立即返回，并带上实际生效的源名。
/// 只有全部失败才抛错，且错误里列出每个源的失败原因——「数据来自哪里」必须可追溯。
enum NextMarketChain {
    static func first<T>(_ attempts: [(source: String, run: () async throws -> T)]) async throws -> (value: T, source: String) {
        var failures: [(source: String, reason: String)] = []
        for attempt in attempts {
            do { return (try await attempt.run(), attempt.source) }
            catch { failures.append((attempt.source, error.localizedDescription)) }
        }
        let trail = failures.map { "\($0.source)（\($0.reason)）" }.joined(separator: " → ")
        throw NextError.invalid("行情源全部不可用：\(trail)")
    }

    /// Keep source priority, but continue when a technically valid response is
    /// too sparse to be useful. If none reaches the target, return the richest
    /// valid response so callers can show limited history while risk guards
    /// decide whether it is enough for an actionable plan.
    static func richest<T>(_ attempts: [(source: String, run: () async throws -> T)],
                          minimumSamples: Int, sampleCount: (T) -> Int) async throws -> (value: T, source: String) {
        var best: (value: T, source: String, count: Int)?
        var failures: [(source: String, reason: String)] = []
        for attempt in attempts {
            do {
                let value = try await attempt.run()
                let count = sampleCount(value)
                if best == nil || count > best!.count { best = (value, attempt.source, count) }
                if count >= minimumSamples { return (value, attempt.source) }
                failures.append((attempt.source, "仅返回 \(count) 个样本，继续尝试备用源"))
            } catch { failures.append((attempt.source, error.localizedDescription)) }
        }
        if let best {
            return (best.value, "\(best.source) · 当前可用来源中样本最多（\(best.count)）")
        }
        let trail = failures.map { "\($0.source)（\($0.reason)）" }.joined(separator: " → ")
        throw NextError.invalid("行情源全部不可用：\(trail)")
    }

    /// Query later providers only for codes missing from earlier responses.
    /// A partial but non-empty response must not silently suppress fallback sources.
    static func fillMissing<T, Key: Hashable>(requested: [Key],
                                               attempts: [(source: String, run: ([Key]) async throws -> [T])],
                                               key: (T) -> Key?) async throws
        -> (value: [T], source: String, missing: [Key]) {
        var ordered: [Key] = []
        var seen = Set<Key>()
        for code in requested where seen.insert(code).inserted { ordered.append(code) }
        let requestedSet = Set(ordered)
        var found: [Key: T] = [:]
        var usedSources: [(String, Int)] = []
        var failures: [(String, String)] = []

        for attempt in attempts {
            let missing = ordered.filter { found[$0] == nil }
            guard !missing.isEmpty else { break }
            do {
                let rows = try await attempt.run(missing)
                var added = 0
                for row in rows {
                    guard let code = key(row), requestedSet.contains(code), found[code] == nil else { continue }
                    found[code] = row
                    added += 1
                }
                if added > 0 { usedSources.append((attempt.source, added)) }
                if added == 0 { failures.append((attempt.source, "未返回缺失代码的有效报价")) }
            } catch {
                failures.append((attempt.source, error.localizedDescription))
            }
        }

        guard !found.isEmpty else {
            let trail = failures.map { "\($0.0)（\($0.1)）" }.joined(separator: " → ")
            throw NextError.invalid("行情源未返回有效报价：\(trail)")
        }
        let missing = ordered.filter { found[$0] == nil }
        let source = usedSources.map { "\($0.0) \($0.1)只" }.joined(separator: " + ")
        return (ordered.compactMap { found[$0] },
                source + (missing.isEmpty ? "" : " · 仍缺 \(missing.count) 只"), missing)
    }
}

/// 东财证券代码（secid）：沪市(5/6/9)→1.xxxxxx；深市与北交所(0/1/2/3/4/8)→0.xxxxxx。
/// 与 NAS 服务端 server/market.py 的 em_secid 完全一致，避免两端映射分叉。
enum NextEastMoneySymbol {
    static func secid(for code: String) -> String? {
        guard code.count == 6, code.allSatisfy(\.isNumber), let first = code.first else { return nil }
        let market: String?
        switch first {
        case "5", "6", "9": market = "1"
        case "0", "1", "2", "3", "4", "8": market = "0"
        default: market = nil
        }
        return market.map { $0 + "." + code }
    }
}

/// 多源解析共用的底层工具：GB18030 解码、任意 JSON 数值转 Decimal、东八区日期口径。
enum NextMarketWire {
    static func text(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let encoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(encoding)
        return String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
    }

    static func decimal(_ raw: Any?) -> Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        switch raw {
        case let number as NSNumber: return Decimal(string: "\(number)", locale: posix)
        case let text as String: return Decimal(string: text, locale: posix)
        default: return nil
        }
    }

    /// "yyyy-MM-dd" → 东八区当日零点。上游返回未来日期一律视为脏数据。
    static func day(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    /// "yyyy-MM-dd HH:mm" → 东八区时刻，用于东财 1 分钟 K 线。
    static func minute(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: raw)
    }

    static func today() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(for: Date())
    }
}

// MARK: - 东财实时报价

/// 东财实时报价（push2.eastmoney.com/api/qt/ulist.np/get）。
/// 字段口径与 NAS 服务端 fetch_eastmoney_quotes 一致：f12 代码 / f14 名称 / f2 最新价 / f60 昨收。
/// 该接口不返回行情时间戳，time 记为请求时刻；不提供 IOPV 与证券类别，一律留空而不推断。
enum NextEastMoneyQuoteParser {
    static func parse(_ data: Data, codes: [String], receivedAt: Date = Date()) -> [NextQuote] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (root["data"] as? [String: Any])?["diff"] as? [[String: Any]] else { return [] }
        var found: [String: NextQuote] = [:]
        for row in rows {
            let rawCode = (row["f12"] as? NSNumber).map { "\($0)" } ?? (row["f12"] as? String) ?? ""
            // 东财偶发把深市代码按数字下发（000001 → 1），补齐前导零再比对。
            let code = rawCode.count < 6 && rawCode.allSatisfy(\.isNumber)
                ? String(repeating: "0", count: 6 - rawCode.count) + rawCode
                : rawCode
            guard codes.contains(code),
                  let name = row["f14"] as? String, !name.isEmpty,
                  let price = NextMarketWire.decimal(row["f2"]), price > 0,
                  let previous = NextMarketWire.decimal(row["f60"]), previous > 0 else { continue }
            found[code] = NextQuote(code: code, name: name, price: price, previousClose: previous, time: receivedAt,
                                    source: "EastMoney push2.eastmoney.com", timeQuality: "receipt_only", iopv: nil, providerInstrumentType: nil)
        }
        return codes.compactMap { found[$0] }
    }
}

// MARK: - 新浪实时报价

/// 新浪实时报价（hq.sinajs.cn/list=sh600000）。
/// 字段口径与 NAS 服务端同一源：0 名称 / 1 今开 / 2 昨收 / 3 最新价 / 30 日期 / 31 时间。
/// 新浪不提供 IOPV 与证券类别，一律留空而不推断。
enum NextSinaQuoteParser {
    static func parse(_ data: Data, codes: [String], receivedAt: Date = Date()) -> [NextQuote] {
        guard let text = NextMarketWire.text(from: data) else { return [] }
        let pattern = #"hq_str_([a-z0-9]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        var found: [String: NextQuote] = [:]
        for match in regex.matches(in: text, range: fullRange) {
            guard let symbolRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let symbol = text[symbolRange].lowercased()
            guard let code = codes.first(where: { NextTencentQuoteParser.symbol(for: $0)?.lowercased() == symbol }) else { continue }
            let fields = text[bodyRange].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 31, !fields[0].isEmpty,
                  let price = Decimal(string: fields[3], locale: Locale(identifier: "en_US_POSIX")), price > 0,
                  let previous = Decimal(string: fields[2], locale: Locale(identifier: "en_US_POSIX")), previous > 0,
                  let stamp = stamp(fields[30], fields[31], receivedAt: receivedAt) else { continue }
            found[code] = NextQuote(code: code, name: fields[0], price: price, previousClose: previous, time: stamp,
                                    source: "Sina hq.sinajs.cn", timeQuality: "exchange_time", iopv: nil, providerInstrumentType: nil)
        }
        return codes.compactMap { found[$0] }
    }

    private static func stamp(_ day: String, _ clock: String, receivedAt: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let parsed = formatter.date(from: "\(day) \(clock)"), parsed <= receivedAt.addingTimeInterval(60) else { return nil }
        return parsed
    }
}

// MARK: - 腾讯日 K

/// 腾讯日 K（proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get）。
/// URL 与校验口径与 NAS 服务端 fetch_tencent_daily 一致：qfqday 每行
/// [日期, 开, 收, 高, 低, 量(手)]；个别标的（如 159866）只有原始 day 序列，回退取用并在来源注明。
enum NextTencentDailyParser {
    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextChartDataset? {
        guard let symbol = NextTencentQuoteParser.symbol(for: code),
              let raw = NextMarketWire.text(from: data),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let node = (root["data"] as? [String: Any])?[symbol] as? [String: Any] else { return nil }
        let rows: [[Any]]
        let adjusted: Bool
        if node["qfqday"] != nil {
            rows = node["qfqday"] as? [[Any]] ?? []
            adjusted = true
        } else if node["day"] != nil {
            rows = node["day"] as? [[Any]] ?? []
            adjusted = false
        } else { return nil }
        let today = NextMarketWire.today()
        var byDay: [String: NextChartSample] = [:]
        for row in rows {
            guard row.count >= 6, let day = row[0] as? String, day.count == 10,
                  let date = NextMarketWire.day(day), date <= today,
                  let open = NextMarketWire.decimal(row[1]), let close = NextMarketWire.decimal(row[2]),
                  let high = NextMarketWire.decimal(row[3]), let low = NextMarketWire.decimal(row[4]),
                  let volume = NextMarketWire.decimal(row[5]),
                  min(open, close, high, low) > 0, volume >= 0,
                  low <= min(open, close), high >= max(open, close) else { continue }
            byDay[day] = NextChartSample(timestamp: date, open: open, high: high, low: low, close: close, iopv: nil, volume: volume)
        }
        guard byDay.count >= 2 else { return nil }
        return buildMarketDataset(code: code, samples: byDay.values.sorted { $0.timestamp < $1.timestamp },
                     priceSource: adjusted ? "Tencent 日K · 前复权" : "Tencent 日K · 未复权", observedAt: receivedAt)
    }
}

// MARK: - 东财 K 线（日 K 与 1 分钟 K 共用内核）

/// 东财历史 K 线（push2his.eastmoney.com/api/qt/stock/kline/get）。
/// 字段口径与 NAS 服务端一致：klines 每行 "日期[, 时:分],开,收,高,低,量(股),额,幅%"。
/// 日 K（klt=101, fqt=1 前复权）与 1 分钟 K（klt=1）共用同一解析内核，只差时间粒度。
enum NextEastMoneyKlineParser {
    enum Mode { case daily, minute }

    static func parse(_ data: Data, code: String, mode: Mode, priceSource: String, receivedAt: Date = Date()) -> NextChartDataset? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = (root["data"] as? [String: Any])?["klines"] as? [String], !lines.isEmpty else { return nil }
        let today = NextMarketWire.today()
        var byKey: [String: NextChartSample] = [:]
        for line in lines {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { continue }
            let stampText = parts[0]
            let timestamp: Date
            switch mode {
            case .daily:
                guard stampText.count >= 10, let date = NextMarketWire.day(String(stampText.prefix(10))), date <= today else { continue }
                timestamp = date
            case .minute:
                guard stampText.count >= 16, let date = NextMarketWire.minute(String(stampText.prefix(16))),
                      date <= receivedAt.addingTimeInterval(60) else { continue }
                timestamp = date
            }
            guard let open = NextMarketWire.decimal(parts[1]), let close = NextMarketWire.decimal(parts[2]),
                  let high = NextMarketWire.decimal(parts[3]), let low = NextMarketWire.decimal(parts[4]),
                  let volume = NextMarketWire.decimal(parts[5]),
                  min(open, close, high, low) > 0, volume >= 0,
                  low <= min(open, close), high >= max(open, close) else { continue }
            // 分时曲线只用分钟收盘价（与腾讯分时口径一致）；日 K 保留完整 OHLC。
            let sample = NextChartSample(timestamp: timestamp,
                                         open: mode == .daily ? open : nil,
                                         high: mode == .daily ? high : nil,
                                         low: mode == .daily ? low : nil,
                                         close: close, iopv: nil, volume: volume)
            byKey[stampText] = sample
        }
        guard byKey.count >= 2 else { return nil }
        return buildMarketDataset(code: code, samples: byKey.values.sorted { $0.timestamp < $1.timestamp },
                     priceSource: priceSource, observedAt: receivedAt)
    }
}

// MARK: - 新浪日 K

/// 新浪日 K（money.finance.sina.com.cn quotes_service api json_v2 getKLineData，scale=240）。
/// 口径与 NAS 服务端 _fetch_sina_kline 一致：[{day, open, high, low, close, volume}]，未复权原始价。
enum NextSinaDailyParser {
    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextChartDataset? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else { return nil }
        let today = NextMarketWire.today()
        var byDay: [String: NextChartSample] = [:]
        for row in rows {
            guard let day = row["day"] as? String, day.count >= 10,
                  let date = NextMarketWire.day(String(day.prefix(10))), date <= today,
                  let open = NextMarketWire.decimal(row["open"]), let high = NextMarketWire.decimal(row["high"]),
                  let low = NextMarketWire.decimal(row["low"]), let close = NextMarketWire.decimal(row["close"]),
                  let volume = NextMarketWire.decimal(row["volume"]),
                  min(open, close, high, low) > 0, volume >= 0,
                  low <= min(open, close), high >= max(open, close) else { continue }
            byDay[String(day.prefix(10))] = NextChartSample(timestamp: date, open: open, high: high, low: low, close: close, iopv: nil, volume: volume)
        }
        guard byDay.count >= 2 else { return nil }
        return buildMarketDataset(code: code, samples: byDay.values.sorted { $0.timestamp < $1.timestamp },
                     priceSource: "Sina 日K · 未复权", observedAt: receivedAt)
    }
}

/// 三个日 K 解析器共用的落库构造：统一 validate 后再返回，脏数据不进缓存。
private func buildMarketDataset(code: String, samples: [NextChartSample], priceSource: String, observedAt: Date) -> NextChartDataset? {
    let dataset = NextChartDataset(code: code, interval: .day, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                   priceSource: priceSource, iopvSource: nil, observedAt: observedAt)
    do { try dataset.validate(); return dataset } catch { return nil }
}
