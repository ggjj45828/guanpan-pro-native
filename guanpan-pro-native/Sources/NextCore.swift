import Foundation
import CryptoKit
import CoreFoundation

enum NextError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum NextMoney {
    static func parse(_ text: String) throws -> Decimal {
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw NextError.invalid("金额格式无效")
        }
        return value
    }
    static func text(_ value: Decimal, digits: Int = 3) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "--"
    }
}

// New schema: no OTC position, subscription, redemption or automatic DCA type.
struct NextPosition: Codable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    var name: String
    var units: Int
    var bookCost: Decimal
    /// 建仓日：你实际开始持有这只的日期。用来判断分红归属——只登记建仓日及之后的派息，
    /// 之前发生的除息不算你的（你刚录入持仓时不会冒出历史分红待确认）。无流水又无此日期时按迁移日处理。
    var acquiredAt: Date? = nil
    var costPerUnit: Decimal { units > 0 ? bookCost / Decimal(units) : 0 }
}
struct NextFill: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var code: String
    var side: String
    var units: Int
    var price: Decimal
    var fee: Decimal
    var realized: Decimal
}
struct NextAssetPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let total: Decimal
    let externalFlow: Decimal
}
struct NextCashMovement: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let amount: Decimal
    let reason: String
}
enum NextDividendAnalytics {
    static let verifiedHistory = [
        NextETFDividendEvent(code: "515180", date: "2025-10-21", amountPerShare: Decimal(string: "0.061")!),
        NextETFDividendEvent(code: "563020", date: "2025-12-10", amountPerShare: Decimal(string: "0.012")!),
        NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!),
        NextETFDividendEvent(code: "563020", date: "2026-09-11", amountPerShare: Decimal(string: "0.012")!),
        NextETFDividendEvent(code: "159545", date: "2025-11-12", amountPerShare: Decimal(string: "0.010")!),
        NextETFDividendEvent(code: "159545", date: "2026-02-11", amountPerShare: Decimal(string: "0.015")!)
    ]
    /// 已知**不分红**的 ETF：推算事件一律丢掉。官方记录仍然照收 ——
    /// 万一哪天真的派息，不该被这份名单挡住。
    /// 560780 半导体设备是用户确认不分红的；159941 纳指ETF 成立以来没有现金分红。
    static let knownNonDividendCodes: Set<String> = ["159941", "560780"]

    /// 推算事件的金额上限（每份）。ETF 单次现金分红超过 0.5 元/份极罕见，
    /// 超过基本可以断定是把「份额折算 / 复权口径切换」当成了分红。
    private static let estimatedAmountCap = Decimal(string: "0.5")!

    static func merged(_ supplied: [NextETFDividendEvent]) -> [NextETFDividendEvent] {
        var byKey: [String: NextETFDividendEvent] = [:]
        for item in verifiedHistory + supplied {
            if item.isEstimated == true {
                if knownNonDividendCodes.contains(item.code) { continue }
                if item.amountPerShare > estimatedAmountCap || item.amountPerShare <= 0 { continue }
            }
            let key = item.id
            if let previous = byKey[key], previous.isEstimated != true && item.isEstimated == true { continue }
            byKey[key] = item
        }
        return byKey.values.sorted { $0.date == $1.date ? $0.code < $1.code : $0.date < $1.date }
    }

    /// 这只 ETF 是否有任何可信（官方）分红记录。界面用它来决定说"不分红"还是"暂未取到"。
    static func hasConfirmedHistory(code: String, events: [NextETFDividendEvent]) -> Bool {
        merged(events).contains { $0.code == code && $0.isEstimated != true }
    }
    static func recentVerifiedPerShare(code: String, events: [NextETFDividendEvent], today: String) -> Decimal {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: today), let cutoff = calendar.date(byAdding: .day, value: -365, to: day) else { return 0 }
        let cutoffText = formatter.string(from: cutoff)
        let hits = merged(events).filter { $0.code == code && $0.isEstimated != true && $0.date >= cutoffText && $0.date <= today }
        if hits.count == 2, let first = formatter.date(from: hits[0].date), let last = formatter.date(from: hits[1].date),
           last.timeIntervalSince(first) / 86_400 >= 300 { return hits[1].amountPerShare }
        return hits.reduce(Decimal.zero) { $0 + $1.amountPerShare }
    }
    enum ProjectionSource { case recentConfirmed, historicalAverage, inferredEstimate }
    static func projectedAnnualPerShare(code: String, events: [NextETFDividendEvent], today: String) -> (amount: Decimal, source: ProjectionSource)? {
        let all = merged(events).filter { $0.code == code && $0.date <= today }
        let parsedRecent = recentVerifiedPerShare(code: code, events: all, today: today)
        if parsedRecent > 0 { return (parsedRecent, .recentConfirmed) }
        let cutoffYear = (Int(today.prefix(4)) ?? 0) - 3
        let confirmed = all.filter { $0.isEstimated != true && (Int($0.date.prefix(4)) ?? 0) >= cutoffYear }
        let totals = Dictionary(grouping: confirmed, by: { String($0.date.prefix(4)) }).mapValues { $0.reduce(Decimal.zero) { $0 + $1.amountPerShare } }
        let sumByYear = totals.values.reduce(Decimal.zero, +)
        if totals.count >= 2 {
            let average = sumByYear / Decimal(totals.count)
            if average > 0 { return (average, .historicalAverage) }
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        let yearAgo = formatter.date(from: today).flatMap { Calendar(identifier: .gregorian).date(byAdding: .day, value: -365, to: $0) }.map { formatter.string(from: $0) } ?? today
        let estimate = all.filter { $0.isEstimated == true && $0.date >= yearAgo }
            .reduce(Decimal.zero) { $0 + $1.amountPerShare }
        return estimate > 0 ? (estimate, .inferredEstimate) : nil
    }
}

struct NextETFDividendEvent: Codable, Identifiable, Equatable {
    var id: String { "\(code)-\(date)" }
    let code: String
    let date: String
    let amountPerShare: Decimal
    var isEstimated: Bool? = nil
    var recordDate: String? = nil
    var payDate: String? = nil
    func validate() throws {
        let parts = date.split(separator: "-")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let validDate = formatter.date(from: date).map { formatter.string(from: $0) == date } ?? false
        let validOptionalDates = [recordDate, payDate].compactMap { $0 }.allSatisfy { value in
            formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
        }
        guard code.count == 6, code.allSatisfy(\.isNumber), parts.count == 3,
              date.count == 10, validDate, validOptionalDates, amountPerShare > 0, !amountPerShare.isNaN else {
            throw NextError.invalid("分红事件的代码、日期或每份金额无效")
        }
    }
}

enum NextIncomeKind: String, Codable, CaseIterable, Identifiable, Equatable {
    case etfDistribution, cashInterest, other
    var id: String { rawValue }
    var title: String { switch self { case .etfDistribution: "ETF 分红"; case .cashInterest: "现金利息"; case .other: "其他收益" } }
}
enum NextIncomeStatus: String, Codable, Equatable {
    case expected, received
    var title: String { self == .expected ? "待到账" : "已到账" }
}
struct NextIncomeEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: NextIncomeKind
    var code: String?
    var name: String
    var exDate: Date?
    var payDate: Date
    var units: Int?
    var perUnit: Decimal?
    var grossAmount: Decimal
    var tax: Decimal
    var status: NextIncomeStatus = .expected
    var receivedAt: Date?
    var note: String = ""
    var netAmount: Decimal { grossAmount - tax }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              grossAmount > 0, !grossAmount.isNaN, tax >= 0, !tax.isNaN, tax <= grossAmount,
              units.map({ $0 > 0 }) ?? true,
              perUnit.map({ $0 > 0 && !$0.isNaN }) ?? true,
              (code == nil || (code!.count == 6 && code!.allSatisfy(\.isNumber))),
              status != .received || receivedAt != nil else {
            throw NextError.invalid("收息记录的金额、税额、证券代码或到账状态无效")
        }
        if kind == .etfDistribution { guard code != nil else { throw NextError.invalid("ETF 分红必须关联证券代码") } }
    }
}

struct NextBook: Codable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var cash: Decimal = 0
    var positions: [NextPosition] = []
    var fills: [NextFill] = []
    var cashMovements: [NextCashMovement] = []
    var incomeEvents: [NextIncomeEvent] = []
    var dividendEvents: [NextETFDividendEvent] = []
    // Only snapshots recorded under the new securities schema belong here.
    var history: [NextAssetPoint] = []
    var importedAt: Date?
    init(schemaVersion: Int = 1, id: UUID = UUID(), cash: Decimal = 0, positions: [NextPosition] = [], fills: [NextFill] = [], cashMovements: [NextCashMovement] = [], incomeEvents: [NextIncomeEvent] = [], dividendEvents: [NextETFDividendEvent] = [], history: [NextAssetPoint] = [], importedAt: Date? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.cash = cash; self.positions = positions
        self.fills = fills; self.cashMovements = cashMovements; self.incomeEvents = incomeEvents; self.dividendEvents = dividendEvents; self.history = history; self.importedAt = importedAt
    }
    func validate() throws {
        guard schemaVersion == 1, !cash.isNaN, cash >= 0,
              Set(positions.map(\.code)).count == positions.count,
              positions.allSatisfy({ $0.code.count == 6 && $0.code.allSatisfy(\.isNumber) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.units >= 0 && !$0.bookCost.isNaN && $0.bookCost >= 0 }),
              fills.allSatisfy({ $0.code.count == 6 && $0.code.allSatisfy(\.isNumber) && ($0.side == "buy" || $0.side == "sell") && $0.units > 0 && $0.price > 0 && !$0.price.isNaN && $0.fee >= 0 && !$0.fee.isNaN && !$0.realized.isNaN }),
              history.allSatisfy({ $0.total >= 0 && !$0.total.isNaN && !$0.externalFlow.isNaN }),
              cashMovements.allSatisfy({ !$0.amount.isNaN && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NextError.invalid("账本校验失败：现金、持仓或版本无效")
        }
        for event in incomeEvents { try event.validate() }
        for event in dividendEvents { try event.validate() }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, cash, positions, fills, cashMovements, incomeEvents, dividendEvents, history, importedAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        cash = try values.decodeIfPresent(Decimal.self, forKey: .cash) ?? 0
        positions = try values.decodeIfPresent([NextPosition].self, forKey: .positions) ?? []
        fills = try values.decodeIfPresent([NextFill].self, forKey: .fills) ?? []
        cashMovements = try values.decodeIfPresent([NextCashMovement].self, forKey: .cashMovements) ?? []
        incomeEvents = try values.decodeIfPresent([NextIncomeEvent].self, forKey: .incomeEvents) ?? []
        dividendEvents = try values.decodeIfPresent([NextETFDividendEvent].self, forKey: .dividendEvents) ?? []
        history = try values.decodeIfPresent([NextAssetPoint].self, forKey: .history) ?? []
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt)
    }
    func total(using quotes: [String: NextQuote]) -> Decimal? {
        var total = cash
        for p in positions where p.units > 0 {
            guard let q = quotes[p.code] else { return nil }
            total += q.price * Decimal(p.units)
        }
        return total
    }
}
struct NextQuote: Codable, Identifiable, Equatable {
    var id: String { code }
    let code: String
    let name: String
    let price: Decimal
    let previousClose: Decimal
    let time: Date
    let source: String
    /// exchange_time = 供应商提供的行情时间；receipt_only = 仅知道服务器收到响应的时间。
    var timeQuality: String? = nil
    var iopv: Decimal? = nil
    var providerInstrumentType: String? = nil
    var changePercent: Decimal? { previousClose > 0 ? (price / previousClose - 1) * 100 : nil }
    func isFresh(at now: Date) -> Bool { time <= now && now.timeIntervalSince(time) <= 120 && price > 0 }
    var hasReliableMarketTime: Bool {
        timeQuality != "receipt_only" && !source.localizedCaseInsensitiveContains("eastmoney")
    }
    func isFreshForPricePlan(at now: Date) -> Bool { hasReliableMarketTime && isFresh(at: now) }
}

/// Strict parser for the reviewed Tencent quote payload. It only accepts facts
/// present in the response; instrument class, settlement and IOPV history must
/// come from separately verified sources.
enum NextTencentQuoteParser {
    static func symbol(for code: String) -> String? {
        guard code.count == 6, code.allSatisfy(\.isNumber), let first = code.first else { return nil }
        let prefix: String
        switch first {
        case "5", "6", "9": prefix = "sh"
        case "0", "1", "2", "3": prefix = "sz"
        case "4", "8": prefix = "bj"
        default: return nil
        }
        return prefix + code
    }

    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextQuote? {
        guard let symbol = symbol(for: code) else { return nil }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else {
            let encoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
            guard encoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(encoding)
            guard let decoded = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) else { return nil }
            text = decoded
        }
        let pattern = #"v_([A-Za-z0-9]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: fullRange).first(where: { match in
            guard let range = Range(match.range(at: 1), in: text) else { return false }
            return text[range].lowercased() == symbol
        }), let bodyRange = Range(match.range(at: 2), in: text) else { return nil }
        let fields = text[bodyRange].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 30, fields[1].isEmpty == false,
              let price = Decimal(string: fields[3], locale: Locale(identifier: "en_US_POSIX")), price > 0,
              let previous = Decimal(string: fields[4], locale: Locale(identifier: "en_US_POSIX")), previous > 0,
              let timestamp = parseTimestamp(fields[30], fallback: receivedAt),
              timestamp <= receivedAt.addingTimeInterval(60) else { return nil }
        let providerType = fields.count > 61 ? fields[61].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : nil
        let rawIopv = providerType == "ETF" && fields.count > 78 ? Decimal(string: fields[78], locale: Locale(identifier: "en_US_POSIX")) : nil
        return NextQuote(code: code, name: fields[1], price: price, previousClose: previous, time: timestamp, source: "Tencent qt.gtimg.cn", timeQuality: "exchange_time", iopv: rawIopv.flatMap { $0 > 0 ? $0 : nil }, providerInstrumentType: providerType)
    }

    private static func parseTimestamp(_ raw: String, fallback: Date) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 12 || digits.count == 14,
              let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)), let date = Int(digits.dropFirst(6).prefix(2)),
              let hour = Int(digits.dropFirst(8).prefix(2)), let minute = Int(digits.dropFirst(10).prefix(2)),
              (1...12).contains(month), (1...31).contains(date), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = digits.count == 14 ? Int(digits.dropFirst(12).prefix(2)) ?? 0 : 0
        guard (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents(); components.year = year; components.month = month; components.day = date
        components.hour = hour; components.minute = minute; components.second = second
        guard let parsed = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        guard verified.year == year, verified.month == month, verified.day == date,
              verified.hour == hour, verified.minute == minute, verified.second == second else { return nil }
        return parsed <= fallback.addingTimeInterval(60) ? parsed : nil
    }
}

enum NextTencentMinuteParser {
    static func parse(_ data: Data, code: String, receivedAt: Date = Date()) -> NextChartDataset? {
        guard let symbol = NextTencentQuoteParser.symbol(for: code),
              let raw = String(data: data, encoding: .utf8),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let nodes = root["data"] as? [String: Any],
              let node = nodes[symbol] as? [String: Any],
              let payload = node["data"] as? [String: Any],
              let rows = (payload["data"] as? [String]) ?? (payload["items"] as? [String]),
              let day = payload["date"] as? String, day.count == 8 else { return nil }
        let y = Int(day.prefix(4)), m = Int(day.dropFirst(4).prefix(2)), d = Int(day.suffix(2))
        guard let year = y, let month = m, let date = d else { return nil }
        guard (1...12).contains(month), (1...31).contains(date) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var samples = [NextChartSample](), previousVolume: Decimal?
        for row in rows {
            let parts = row.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].count == 4,
                  let hour = Int(parts[0].prefix(2)), let minute = Int(parts[0].suffix(2)),
                  (0...23).contains(hour), (0...59).contains(minute),
                  let price = Decimal(string: parts[1], locale: Locale(identifier: "en_US_POSIX")), price > 0 else { continue }
            var components = DateComponents(); components.year = year; components.month = month; components.day = date; components.hour = hour; components.minute = minute
            guard let timestamp = calendar.date(from: components), timestamp <= receivedAt.addingTimeInterval(60) else { continue }
            let actualDay = calendar.dateComponents([.year, .month, .day], from: timestamp)
            guard actualDay.year == year, actualDay.month == month, actualDay.day == date else { continue }
            var volume: Decimal?
            if parts.count > 2, let cumulative = Decimal(string: parts[2], locale: Locale(identifier: "en_US_POSIX")), cumulative >= 0 {
                if let previousVolume, cumulative >= previousVolume { volume = cumulative - previousVolume }
                previousVolume = cumulative
            }
            samples.append(NextChartSample(timestamp: timestamp, open: nil, high: nil, low: nil, close: price, iopv: nil, volume: volume))
        }
        samples = Dictionary(samples.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.timestamp < $1.timestamp }
        guard !samples.isEmpty else { return nil }
        let result = NextChartDataset(code: code, interval: .intraday, samples: samples, costPerUnit: nil, costObservedAt: nil, priceSource: "Tencent minute history", iopvSource: nil, observedAt: receivedAt)
        do { try result.validate(); return result } catch { return nil }
    }
}

// Trading behavior is supplied by verified instrument metadata. Never infer
// settlement rules from an ETF label, code prefix, or a hard-coded T+0 flag.
enum NextSettlementRule: String, Codable { case t0, t1, unknown }
enum NextAssetClass: String, Codable { case etf, equity, other, unknown }
/// ETF 每笔固定手续费 ¥0.10：来自用户指定的核验规则，不按券商公告推断。
enum NextTradeFees {
    static let etfPerTrade = Decimal(string: "0.10")!
}
struct NextInstrumentRules: Codable, Equatable {
    let code: String
    let market: String
    let assetClass: NextAssetClass
    let settlement: NextSettlementRule
    let lotSize: Int?
    let feePerTrade: Decimal?
    let source: String
    let verifiedAt: Date?
    var isVerified: Bool { assetClass != .unknown && settlement != .unknown && lotSize != nil && feePerTrade != nil && verifiedAt != nil && !source.isEmpty && !market.isEmpty }
    static func verifiedETFMarketRule(code: String, market: String, at date: Date = Date()) -> NextInstrumentRules? {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              (code.hasPrefix("15") && market == "SZSE") || ((code.hasPrefix("5") || code.hasPrefix("56")) && market == "SSE") else { return nil }
        let provenance = market == "SSE"
            ? "SSE ETF FAQ https://www.sse.com.cn/assortment/fund/etf/question/c/c_20240118_5734754.shtml · 100份；用户指定费率¥0.10；交收未知"
            : "SZSE 基金竞价交易说明 https://investor.szse.cn/knowledge/fund/trade/t20171113_538865.html · 100份；用户指定费率¥0.10；交收未知"
        return NextInstrumentRules(code: code, market: market, assetClass: .etf, settlement: .unknown,
            lotSize: 100, feePerTrade: NextTradeFees.etfPerTrade, source: provenance, verifiedAt: date)
    }
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              (market.isEmpty || market.count <= 16), (source.isEmpty || source.count <= 160),
              lotSize.map({ $0 > 0 }) ?? true,
              feePerTrade.map({ $0 >= 0 }) ?? true else {
            throw NextError.invalid("证券交易规则无效")
        }
    }
}

struct NextBookLevel: Codable, Equatable {
    let price: Decimal
    let units: Int
}
struct NextOrderBookSnapshot: Codable, Equatable {
    let code: String
    let observedAt: Date
    let source: String
    let bids: [NextBookLevel]
    let asks: [NextBookLevel]
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !source.isEmpty,
              bids.count == 5, asks.count == 5,
              bids.allSatisfy({ $0.price > 0 && $0.units > 0 }), asks.allSatisfy({ $0.price > 0 && $0.units > 0 }),
              zip(bids, bids.dropFirst()).allSatisfy({ pair in pair.0.price >= pair.1.price }),
              zip(asks, asks.dropFirst()).allSatisfy({ pair in pair.0.price <= pair.1.price }),
              bids[0].price <= asks[0].price else {
            throw NextError.invalid("五档盘口数据无效或档位顺序错误")
        }
    }
}

enum NextIntradayAxis {
    static let length = 252.0
    static let ticks: [(Double, String)] = [(0, "09:30"), (60, "10:30"), (120, "11:30"), (132, "13:00"), (192, "14:00"), (252, "15:00")]
    /// Fixed mainland ETF session axis. The lunch break is compressed to a small
    /// 12-minute visual gap; intraday plots never stretch early samples to fill the day.
    static func minute(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = Double((parts.hour ?? 9) * 60 + (parts.minute ?? 30))
        if minute <= 570 { return 0 }
        if minute <= 690 { return minute - 570 }
        if minute < 780 { return 120 + Double(minute - 690) / 90 * 12 }
        if minute <= 900 { return 132 + minute - 780 }
        return 252
    }
    static func sameTradingDay(_ lhs: Date, _ rhs: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

enum NextChartInterval: String, Codable, CaseIterable { case intraday, fiveDay, day, week, month, threeMonth, year, all }
struct NextChartSample: Codable, Identifiable, Equatable {
    var id: Date { timestamp }
    let timestamp: Date
    let open: Decimal?
    let high: Decimal?
    let low: Decimal?
    let close: Decimal
    let iopv: Decimal?
    let volume: Decimal?
}
enum NextMovingAverage {
    /// Simple moving average of daily closes. Values remain Decimal through
    /// accumulation and division; the first period-1 bars are intentionally nil.
    static func series(_ samples: [NextChartSample], period: Int) -> [Decimal?] {
        guard period > 0 else { return Array(repeating: nil, count: samples.count) }
        var prefix: [Decimal] = [0]
        prefix.reserveCapacity(samples.count + 1)
        for sample in samples { prefix.append(prefix[prefix.count - 1] + sample.close) }
        return samples.indices.map { index in
            guard index + 1 >= period else { return nil }
            return (prefix[index + 1] - prefix[index + 1 - period]) / Decimal(period)
        }
    }
}
extension NextIntradayAxis {
    static func sessionSamples(from samples: [NextChartSample], selectedDate: Date?) -> [NextChartSample] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard let latest = ordered.last else { return [] }
        let day = selectedDate.flatMap { candidate in
            ordered.contains(where: { sameTradingDay($0.timestamp, candidate) }) ? candidate : nil
        } ?? latest.timestamp
        return ordered.filter { sameTradingDay($0.timestamp, day) }
    }
}
struct NextChartDataset: Codable, Equatable {
    let code: String
    let interval: NextChartInterval
    let samples: [NextChartSample]
    let costPerUnit: Decimal?
    let costObservedAt: Date?
    let priceSource: String
    let iopvSource: String?
    let observedAt: Date

    var orderedSamples: [NextChartSample] { samples.sorted { $0.timestamp < $1.timestamp } }
    /// 价格轴默认把 IOPV 也算进去（IOPV 与成交价共轴）。
    /// 但 IOPV 图层是可以关掉的：关掉时纵轴不应该还被它撑开，
    /// 否则成交价会被压成一条平线（例如 IOPV 4.1 而价格只有 1.05）。
    /// 所以额外提供 `includingIOPV`：画图侧按图层可见性传参，纯数据场景保持默认行为。
    var priceDomain: ClosedRange<Decimal>? { priceDomain(includingIOPV: true) }
    func priceDomain(includingIOPV: Bool) -> ClosedRange<Decimal>? {
        var values = orderedSamples.flatMap { [$0.low, $0.high, Optional($0.close)].compactMap { $0 } }
        if includingIOPV { values.append(contentsOf: orderedSamples.compactMap(\.iopv)) }
        guard let low = values.min(), let high = values.max() else { return nil }
        if low == high { let pad = max(abs(low) * Decimal(string: "0.01")!, Decimal(string: "0.0001")!); return (low - pad)...(high + pad) }
        let pad = (high - low) * Decimal(string: "0.06")!
        return (low - pad)...(high + pad)
    }
    // Premium is available for numeric labels; the IOPV price itself shares the chart's price axis.
    var iopvPremiumDomain: ClosedRange<Decimal>? {
        let values = orderedSamples.compactMap { sample -> Decimal? in
            guard let iopv = sample.iopv, iopv != 0 else { return nil }
            return (sample.close / iopv - 1) * 100
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        if low == high { return (low - 0.1)...(high + 0.1) }
        let pad = (high - low) * Decimal(string: "0.1")!
        return (low - pad)...(high + pad)
    }
    var timeDomain: ClosedRange<Date>? {
        guard let first = orderedSamples.first?.timestamp, let last = orderedSamples.last?.timestamp else { return nil }
        return first == last ? first.addingTimeInterval(-30)...last.addingTimeInterval(30) : first...last
    }
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              !samples.isEmpty,
              zip(orderedSamples, orderedSamples.dropFirst()).allSatisfy({ pair in pair.0.timestamp < pair.1.timestamp }),
              orderedSamples.allSatisfy({ $0.close > 0 && ($0.iopv.map({ $0 > 0 }) ?? true) && ($0.volume.map({ $0 >= 0 }) ?? true) }),
              (iopvSource != nil || orderedSamples.allSatisfy({ $0.iopv == nil })) else {
            throw NextError.invalid("图表数据时间、价格或来源无效")
        }
    }

    /// A live quote may supply an ETF IOPV while the minute feed supplies only
    /// price and volume. Attach it only to the nearest same-session sample
    /// within five minutes; it must never become a fabricated whole-day line.
    func attachingVerifiedIOPV(_ quote: NextQuote, maximumAge: TimeInterval = 300) -> NextChartDataset {
        guard interval == .intraday, code == quote.code, quote.providerInstrumentType == "ETF",
              let iopv = quote.iopv, iopv > 0,
              let index = samples.indices.min(by: { abs(samples[$0].timestamp.timeIntervalSince(quote.time)) < abs(samples[$1].timestamp.timeIntervalSince(quote.time)) }),
              abs(samples[index].timestamp.timeIntervalSince(quote.time)) <= maximumAge else { return self }
        var changed = samples
        let current = changed[index]
        changed[index] = NextChartSample(timestamp: current.timestamp, open: current.open, high: current.high, low: current.low, close: current.close, iopv: iopv, volume: current.volume)
        return NextChartDataset(code: code, interval: interval, samples: changed, costPerUnit: costPerUnit, costObservedAt: costObservedAt,
                                priceSource: priceSource, iopvSource: "Tencent ETF quote · 同一时段最近采样点", observedAt: observedAt)
    }
}
struct NextGoal: Codable, Equatable {
    var years = 10
    var monthlyBudget: Decimal = 1000
    var concentrationLimit: Decimal = 40
    var targetWeights: [String: Decimal] = [:]
    init(years: Int = 10, monthlyBudget: Decimal = 1000, concentrationLimit: Decimal = 40, targetWeights: [String: Decimal] = [:]) {
        self.years = years; self.monthlyBudget = monthlyBudget; self.concentrationLimit = concentrationLimit; self.targetWeights = targetWeights
    }
    private enum CodingKeys: String, CodingKey { case years, monthlyBudget, concentrationLimit, targetWeights }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        years = try values.decodeIfPresent(Int.self, forKey: .years) ?? 10
        monthlyBudget = try values.decodeIfPresent(Decimal.self, forKey: .monthlyBudget) ?? 1000
        concentrationLimit = try values.decodeIfPresent(Decimal.self, forKey: .concentrationLimit) ?? 40
        targetWeights = try values.decodeIfPresent([String: Decimal].self, forKey: .targetWeights) ?? [:]
    }
    func validate() throws {
        let totalWeight = targetWeights.values.reduce(Decimal.zero, +)
        guard years > 0, years <= 50, !monthlyBudget.isNaN, monthlyBudget >= 0,
              concentrationLimit > 0, concentrationLimit <= 100,
              targetWeights.keys.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isNumber) }),
              targetWeights.values.allSatisfy({ !$0.isNaN && $0 >= 0 && $0 <= 100 }),
              targetWeights.isEmpty || abs(totalWeight - 100) <= Decimal(string: "0.01")! else { throw NextError.invalid("目标、预算或目标仓位比例无效（目标仓位合计须为 100%）") }
    }
}
struct NextEvidence: Codable, Identifiable, Equatable {
    var id: String
    let title: String
    let detail: String
    let level: String
    let observedAt: Date
}
struct NextOption: Codable, Identifiable, Equatable {
    var id: String
    let title: String
    let rationale: String
    let tradeoff: String
    let evidenceIDs: [String]
}
struct NextDecision: Codable, Identifiable, Equatable {
    var id = UUID()
    let createdAt: Date
    var title: String
    var evidence: [NextEvidence]
    var options: [NextOption]
    var selectedOption: String?
    var review: String = ""
    var status: String = "待比较"
    let origin: String
}
enum NextResearch {
    // Local arithmetic and data checks are explicitly not model-generated AI.
    static func prepare(book: NextBook, goal: NextGoal, quotes: [String: NextQuote], now: Date) throws -> NextDecision {
        try book.validate(); try goal.validate()
        var evidence = [NextEvidence(id: "budget", title: "新增资金独立规划", detail: "每月预算 ¥\(NextMoney.text(goal.monthlyBudget))；不占用或改动真实现金。", level: "事实", observedAt: now)]
        let missing = book.positions.filter { $0.units > 0 && quotes[$0.code]?.isFresh(at: now) != true }
        evidence.append(NextEvidence(id: "quotes", title: missing.isEmpty ? "报价检查通过" : "行情证据待补齐",
                                     detail: missing.isEmpty ? "所有现有持仓报价在两分钟内。" : "\(missing.count) 只持仓没有新鲜报价；不生成带价交易方案。", level: missing.isEmpty ? "事实" : "缺口", observedAt: now))
        if let total = book.total(using: quotes), total > 0 {
            let largest = book.positions.map { Decimal($0.units) * (quotes[$0.code]?.price ?? 0) / total * 100 }.max() ?? 0
            evidence.append(NextEvidence(id: "concentration", title: "当前单只最高占比", detail: "\(NextMoney.text(largest))%；你设置的检查阈值为 \(NextMoney.text(goal.concentrationLimit))%。", level: largest > goal.concentrationLimit ? "待核对" : "事实", observedAt: now))
        }
        let options = [
            NextOption(id: "wait", title: "暂不调整，补齐证据", rationale: "保留当前仓位，先核对行情与预算。", tradeoff: "维持现有集中度，也可能错过部分行情。", evidenceIDs: ["quotes"]),
            NextOption(id: "budget", title: "用新增资金逐月靠近目标", rationale: "把每月预算单独用于下一步配置研究；不足一手时先累计。", tradeoff: "调整较慢，需要持续投入；没有收益保证。", evidenceIDs: ["budget", "quotes"])
        ]
        return NextDecision(createdAt: now, title: "本次账户研究", evidence: evidence, options: options, origin: "本地规则检查")
    }
    static func acceptModelOptions(_ options: [NextOption], evidence: [NextEvidence]) throws -> [NextOption] {
        let known = Set(evidence.map(\.id))
        guard (2...4).contains(options.count), Set(options.map(\.id)).count == options.count,
              options.allSatisfy({ !$0.title.isEmpty && !$0.rationale.isEmpty && !$0.tradeoff.isEmpty && !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: known) }) else {
            throw NextError.invalid("AI 方案缺少依据、取舍说明或引用了不存在的证据，未采用")
        }
        return options
    }
}

// Persisted navigation lets deep links, search and scene restoration return to
// the same user context instead of rebuilding a flow from an internal menu.
enum NextTab: String, Codable, CaseIterable { case overview, market, decision, laboratory, assets, income, mine }
enum NextRoute: Codable, Equatable {
    case instrument(String), intent(String, String), chart(String), portfolio(String), replay(String)
    case settings, alerts, fills, history, backups, twin(String)
}
struct NextChartState: Codable, Equatable {
    var interval = "intraday"
    var visibleLayers: Set<String> = ["price", "volume", "iopv", "cost", "average", "previous", "ma5", "ma10", "ma20", "ma60", "ma250", "trades", "range"]
    var lowerBound: Date?
    var upperBound: Date?
    var crosshairTime: Date?
    var scale = 1.0
    var intradaySessionDate: Date? = nil
    var latestIntradaySessionDate: Date? = nil
    var movingAverageDefaultsApplied: Bool? = nil
}
struct NextNavigationState: Codable, Equatable {
    var selectedTab: NextTab = .overview
    var routes: [NextRoute] = []
    var tabRoutes: [String: [NextRoute]] = [:]
    var selectedSecurity: String?
    var searchQuery = ""
    var listFilters: [String: String] = [:]
    var listSorts: [String: String] = [:]
    var scrollAnchors: [String: String] = [:]
    var chartStates: [String: NextChartState] = [:]
    mutating func openInstrument(_ code: String) {
        selectedTab = .market; selectedSecurity = code; routes.append(.instrument(code))
    }
    mutating func openIntent(_ intent: String, code: String) {
        selectedTab = .decision; selectedSecurity = code; routes.append(.intent(intent, code))
    }
}

enum NextDataQuality: String, Codable { case live, delayed, cached, stale, missing }
struct NextDataStamp: Codable, Equatable {
    let source: String
    let observedAt: Date?
    let quality: NextDataQuality
    let detail: String
    func label(now: Date) -> String {
        if quality == .live || quality == .delayed {
            guard let observedAt else { return "\(quality == .live ? "刚更新" : "延迟") · \(source)" }
            let seconds = max(0, Int(now.timeIntervalSince(observedAt)))
            if seconds <= 120 && quality == .live { return "刚更新 · \(source) · \(seconds) 秒前" }
            let age = seconds / 60
            return "\(seconds <= 900 ? "延迟" : seconds <= 86_400 ? "缓存" : "已过期") · \(age) 分钟前 · \(source)"
        }
        switch quality {
        case .live, .delayed: return "\(quality.rawValue) · \(source)"
        case .cached, .stale:
            guard let observedAt else { return quality == .cached ? "缓存数据" : "数据过期" }
            let age = max(0, Int(now.timeIntervalSince(observedAt) / 60))
            return "\(quality == .cached ? "缓存" : "已过期") · \(age) 分钟前 · \(source)"
        case .missing: return "暂无数据 · \(detail)"
        }
    }
    var canSupportPricePlan: Bool { quality == .live && source.hasPrefix("licensed:") }
}

struct NextCachedQuote: Codable, Equatable {
    let quote: NextQuote
    let stamp: NextDataStamp
    func usableForDisplay(at now: Date) -> Bool { quote.time <= now }
    func usableForPricePlan(at now: Date) -> Bool { usableForDisplay(at: now) && stamp.canSupportPricePlan && quote.isFreshForPricePlan(at: now) }
}
struct NextAssetValuation: Equatable {
    let total: Decimal?
    let partialTotal: Decimal
    let dailyChange: Decimal?
    let dailyChangePercent: Decimal?
    let pricedPositions: Int
    let totalPositions: Int
    let earliestQuote: Date?
    let quality: NextDataQuality?
    var isComplete: Bool { pricedPositions == totalPositions }
}
/// 持仓成本口径。券商软件里通常能看到两种，含义完全不同：
///
/// - **买入均价（移动加权平均）**：只由买入决定，卖出不改变每份成本。
///   账本里 `bookCost / units` 就是这一种，天然可靠，不依赖成交历史是否完整。
/// - **摊薄成本**：把卖出所得也冲减进成本 —— `(累计买入金额 + 买入费用 − 累计卖出金额 + 卖出费用) / 当前份额`。
///   卖出盈利会把成本压低，甚至出现负成本；这是同花顺等软件默认显示的「成本价」。
///
/// 摊薄成本**只有成交历史完整时才算得准**。补录的已有持仓没有买入流水，
/// 这种情况下 `hasFullHistory` 为 false，摊薄值退回加权平均，不会凭空造出一个假成本。
struct NextCostBasis: Equatable {
    let code: String
    let units: Int
    /// 账本里的持仓总成本（加权平均口径，含买入手续费）。
    let bookCost: Decimal
    let averageCost: Decimal
    let dilutedCost: Decimal?
    let hasFullHistory: Bool
    /// 已到账的现金分红合计。券商的「成本价」会把分红从成本里扣掉，
    /// 所以分红到账后成本价会下降 —— 这里把它显式记下来，界面才能解释这个变化。
    var dividendCredit: Decimal = 0
    var isNegativeDiluted: Bool { (dilutedCost ?? 0) < 0 }
}

extension NextBook {
    /// 计算一只持仓的两种成本口径。
    /// 今日买入、还没到 T+1 的份额 —— 当天不可卖。
    /// 券商显示的「可用」就是这个口径（今天 700 持仓 / 400 可用 = 今天买了 300）。
    func lockedUnits(for code: String, at now: Date) -> Int {
        guard positions.contains(where: { $0.code == code }) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return fills
            .filter { $0.code == code && $0.side == "buy" && calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + $1.units }
    }

    /// 可卖份额 = 持仓 − 今日买入。补录的持仓没有买入流水，所以整体可用。
    func availableUnits(for code: String, at now: Date) -> Int {
        guard let position = positions.first(where: { $0.code == code }) else { return 0 }
        return max(0, position.units - lockedUnits(for: code, at: now))
    }

    func costBasis(for code: String) -> NextCostBasis? {
        guard let position = positions.first(where: { $0.code == code }) else { return nil }
        let related = fills.filter { $0.code == code }
        let buys = related.filter { $0.side == "buy" }
        let sells = related.filter { $0.side == "sell" }
        let average = position.units > 0 ? position.bookCost / Decimal(position.units) : 0
        // 摊薄成本只有在「流水能解释当前份额」时才成立：
        // 买入份数 − 卖出份数 必须等于当前持仓。否则用残缺流水算出来的摊薄成本是错的
        // （极端情况会出现负成本或把成本算成一半），此时退回买入均价并在界面标注。
        let boughtUnits = buys.reduce(0) { $0 + $1.units }
        let soldUnits = sells.reduce(0) { $0 + $1.units }
        let hasFullHistory = !buys.isEmpty && (boughtUnits - soldUnits) == position.units
        // 已到账的现金分红冲减成本：这是券商「成本价」随分红下降的原因。
        // 只算「已到账 + ETF 分红」，待到账的预估不提前扣。
        let dividendCredit = incomeEvents
            .filter { $0.status == .received && $0.kind == .etfDistribution && $0.code == code }
            .reduce(Decimal.zero) { $0 + $1.netAmount }
        var diluted: Decimal?
        if hasFullHistory, position.units > 0 {
            let buyCost = buys.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.units) + $1.fee }
            let sellNet = sells.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.units) - $1.fee }
            diluted = (buyCost - sellNet - dividendCredit) / Decimal(position.units)
        }
        return NextCostBasis(code: code, units: position.units, bookCost: position.bookCost,
                             averageCost: average, dilutedCost: diluted, hasFullHistory: hasFullHistory,
                             dividendCredit: dividendCredit)
    }

    func valuation(using quotes: [String: NextCachedQuote], at now: Date) -> NextAssetValuation {
        let heldCodes = Set(positions.filter({ $0.units > 0 }).map { $0.code })
        var partial = cash
        var priced = 0
        var earliest: Date?
        var qualities = [NextDataQuality]()
        var previousTotal = cash
        var anomalous = false
        for position in positions where position.units > 0 {
            guard let cached = quotes[position.code], cached.usableForDisplay(at: now) else { continue }
            if NextPortfolioCalculator.anomalyReason(quote: cached.quote, storedCostPerUnit: position.costPerUnit) != nil {
                anomalous = true
                continue
            }
            partial += cached.quote.price * Decimal(position.units)
            previousTotal += cached.quote.previousClose * Decimal(position.units)
            priced += 1
            earliest = min(earliest ?? cached.quote.time, cached.quote.time)
            let age = now.timeIntervalSince(cached.quote.time)
            let quality: NextDataQuality = age <= 120 ? cached.stamp.quality : age <= 86_400 ? .cached : .stale
            qualities.append(quality)
        }
        let complete = priced == heldCodes.count && !anomalous
        let quality = qualities.max { qualityRank($0) < qualityRank($1) }
        // 当日参考盈亏的券商口径：
        //   昨仓 ＝ (现价 − 昨收) × 当前份额
        //   今买 ＝ (昨收 − 买入价) × 份额 − 费用   ← 补回被「按昨收」多算的部分
        //   今卖 ＝ (卖出价 − 昨收) × 份额 − 费用
        // 只按 (现价−昨收) × 当前份额 会把当日买入的份额也当成昨天就有，
        // 当天有买卖时必然和同花顺对不上。
        // 仅对“当前仍持有”的标的计入当日成交调整，与持仓列表（PortfolioSummary）逐标的汇总严格一致。
        var intradayAdjustment = Decimal.zero
        var marketCalendar = Calendar(identifier: .gregorian)
        marketCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        for fill in fills where marketCalendar.isDate(fill.date, inSameDayAs: now) && heldCodes.contains(fill.code) {
            guard let cached = quotes[fill.code] else { continue }
            let previous = cached.quote.previousClose
            if fill.side == "buy" {
                intradayAdjustment += (previous - fill.price) * Decimal(fill.units) - fill.fee
            } else {
                intradayAdjustment += (fill.price - previous) * Decimal(fill.units) - fill.fee
            }
        }
        let delta = complete ? partial - previousTotal + intradayAdjustment : nil
        let deltaPercent = delta.flatMap { previousTotal > 0 ? $0 / previousTotal * 100 : nil }
        return NextAssetValuation(total: complete ? partial : nil, partialTotal: partial, dailyChange: delta, dailyChangePercent: deltaPercent, pricedPositions: priced,
                                  totalPositions: heldCodes.count, earliestQuote: earliest, quality: quality)
    }
}
private func qualityRank(_ quality: NextDataQuality) -> Int {
    switch quality { case .live: 0; case .delayed: 1; case .cached: 2; case .stale: 3; case .missing: 4 }
}

// Buy research never invents a fair price. A limit plan is offered only when
// fresh quotations and an explicit, cited research range are both available.
struct NextPriceResearch: Codable, Equatable {
    let lower: Decimal
    let upper: Decimal
    let evidenceIDs: [String]
    let observedAt: Date
    func validate(evidence: [NextEvidence]) throws {
        guard lower > 0, upper >= lower, !evidenceIDs.isEmpty,
              Set(evidenceIDs).isSubset(of: Set(evidence.map(\.id))) else {
            throw NextError.invalid("合理价格区间缺少有效来源，不能生成限价建议")
        }
    }
}
struct NextPatientLimitStep: Codable, Identifiable, Equatable {
    var id: Int { level }
    let level: Int
    let limit: Decimal
    let units: Int
    let budget: Decimal
    let fee: Decimal
}
struct NextBuyOpportunity: Codable, Equatable {
    let code: String
    let evidence: [NextEvidence]
    let priceResearch: NextPriceResearch?
    let limitSteps: [NextPatientLimitStep]
    let riskSummary: String
    let status: String
    let canSavePlan: Bool
    static func prepare(code: String, book: NextBook, goal: NextGoal, quote: NextCachedQuote?, research: NextPriceResearch?, rules: NextInstrumentRules?, evidence: [NextEvidence], now: Date) throws -> NextBuyOpportunity {
        try book.validate(); try goal.validate()
        var reasons: [String] = []
        guard let quote, quote.usableForPricePlan(at: now) else {
            reasons.append("缺少新鲜行情，暂不生成价格或限价档位。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: nil, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "行情待更新", canSavePlan: false)
        }
        guard let research else {
            reasons.append("尚无可验证的合理价格研究，暂不猜测买入价。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: nil, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "价格依据待补", canSavePlan: false)
        }
        try research.validate(evidence: evidence)
        guard let rules, rules.code == code, rules.isVerified, rules.assetClass == .etf,
              let fee = rules.feePerTrade, fee == NextTradeFees.etfPerTrade, let lotSize = rules.lotSize else {
            reasons.append("该证券类别、交易单位或 ETF 固定手续费未核实，暂不生成限价数量。")
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: [], riskSummary: reasons.joined(separator: " "), status: "交易规则待核验", canSavePlan: false)
        }
        let budget = goal.monthlyBudget
        guard budget > fee else {
            return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: [], riskSummary: "新增预算不足以覆盖一手及费用；计划保持空白，不动用真实现金。", status: "预算不足", canSavePlan: false)
        }
        let center = (research.lower + research.upper) / 2
        let prices = [research.lower, center]
        let perStepBudget = budget / 2
        let steps = prices.enumerated().compactMap { index, price -> NextPatientLimitStep? in
            guard price > 0, perStepBudget > fee else { return nil }
            var lotCost = price * Decimal(lotSize)
            let availableBudget = perStepBudget - fee
            let unroundedLotCount = NSDecimalNumber(decimal: availableBudget)
                .dividing(by: NSDecimalNumber(decimal: lotCost)).decimalValue
            var roundedLotCount = Decimal()
            var unroundedLotCountCopy = unroundedLotCount
            NSDecimalRound(&roundedLotCount, &unroundedLotCountCopy, 0, .down)
            let rawUnits = NSDecimalNumber(decimal: roundedLotCount).intValue * lotSize
            guard rawUnits >= lotSize else { return nil }
            let amount = price * Decimal(rawUnits)
            return NextPatientLimitStep(level: index + 1, limit: price, units: rawUnits, budget: amount, fee: fee)
        }
        if steps.isEmpty { reasons.append("当前每档预算不足一手，建议先累计新增预算。") }
        reasons.append("价格只作用户可修改的等待计划；不会占用真实现金或提交订单。")
        return NextBuyOpportunity(code: code, evidence: evidence, priceResearch: research, limitSteps: steps, riskSummary: reasons.joined(separator: " "), status: "待你核对", canSavePlan: !steps.isEmpty)
    }
}

/// A patient limit plan is a reminder/decision record, never a broker order.
struct NextPatientLimitPlan: Codable, Identifiable, Equatable {
    var id = UUID()
    let code: String
    let name: String
    let limitPrice: Decimal
    let units: Int
    let createdAt: Date
    let expiresAt: Date
    var state = "等待价格提醒"
    var triggeredAt: Date?
    func shouldTrigger(with quote: NextQuote, at now: Date) -> Bool {
        state == "等待价格提醒" && quote.code == code && quote.isFresh(at: now) && quote.price <= limitPrice && now < expiresAt
    }
    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !name.isEmpty,
              !limitPrice.isNaN, limitPrice > 0, limitPrice <= 100000,
              units > 0, units <= 100000000, expiresAt > createdAt,
              ["等待价格提醒", "已暂停", "价格已触发", "已撤销", "已过期"].contains(state),
              triggeredAt.map({ $0 >= createdAt && $0 <= expiresAt }) ?? true else {
            throw NextError.invalid("耐心限价计划的证券、目标价、份额或有效期无效")
        }
    }
}

struct NextAlert: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let fingerprint: String
    let level: String
    let title: String
    let detail: String
    let createdAt: Date
    let stamp: NextDataStamp
    var read = false
    var delivery: String = "待处理"
}
enum NextPriceAlertDirection: String, Codable, CaseIterable, Identifiable, Equatable {
    case atOrAbove, atOrBelow
    var id: String { rawValue }
    var title: String { self == .atOrAbove ? "上涨至或高于" : "下跌至或低于" }
}
/// 提醒的判定维度。价格只是其中一种 —— 攒股息的标的更关心「股息率/溢价」，
/// 短线更关心「今日涨跌幅」，所以规则允许按维度设置。
enum NextAlertMetric: String, Codable, CaseIterable, Identifiable {
    case price, changePercent, premiumPercent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .price: return "价格"
        case .changePercent: return "涨跌幅"
        case .premiumPercent: return "溢折价"
        }
    }
    var unit: String { self == .price ? "元" : "%" }
}

struct NextPriceAlertRule: Codable, Identifiable, Equatable {
    var id = UUID()
    let code: String
    let name: String
    /// 阈值。价格类为元，涨跌幅/溢折价为百分数（可为负，例如折价 -2%）。
    let price: Decimal
    let direction: NextPriceAlertDirection
    /// 旧版本规则没有这个字段，缺省按「价格」处理。
    var metric: NextAlertMetric? = nil
    var enabled = true
    var isInsideTrigger = false
    var resolvedMetric: NextAlertMetric { metric ?? .price }

    /// 当前值是否满足规则。拿不到 IOPV 时溢折价规则不触发，而不是拿 0 当折价。
    func value(for quote: NextQuote) -> Decimal? {
        switch resolvedMetric {
        case .price: return quote.price
        case .changePercent: return quote.changePercent
        case .premiumPercent:
            guard let iopv = quote.iopv, iopv > 0 else { return nil }
            return (quote.price / iopv - 1) * 100
        }
    }

    func validate() throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !name.isEmpty, !price.isNaN else {
            throw NextError.invalid("提醒的代码、名称或阈值无效")
        }
        switch resolvedMetric {
        case .price:
            guard price > 0, price <= 100000 else { throw NextError.invalid("价格提醒的阈值必须大于 0") }
        case .changePercent, .premiumPercent:
            guard abs(price) <= 100 else { throw NextError.invalid("百分比提醒的阈值应在 ±100 之间") }
        }
    }
}
struct NextQuietHours: Codable, Equatable {
    var enabled = true
    var startMinute = 22 * 60
    var endMinute = 8 * 60
    func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return true }
        return startMinute < endMinute ? (minute >= startMinute && minute < endMinute) : (minute >= startMinute || minute < endMinute)
    }
}
struct NextNotificationCenter: Codable, Equatable {
    var alerts: [NextAlert] = []
    var priceRules: [NextPriceAlertRule] = []
    var quietHours = NextQuietHours()
    var dedupeMinutes = 30
    private enum CodingKeys: String, CodingKey { case alerts, priceRules, quietHours, dedupeMinutes }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alerts = try values.decodeIfPresent([NextAlert].self, forKey: .alerts) ?? []
        priceRules = try values.decodeIfPresent([NextPriceAlertRule].self, forKey: .priceRules) ?? []
        quietHours = try values.decodeIfPresent(NextQuietHours.self, forKey: .quietHours) ?? NextQuietHours()
        dedupeMinutes = try values.decodeIfPresent(Int.self, forKey: .dedupeMinutes) ?? 30
    }
    mutating func append(_ alert: NextAlert, now: Date) -> Bool {
        let duplicate = alerts.contains { $0.fingerprint == alert.fingerprint && now.timeIntervalSince($0.createdAt) >= 0 && now.timeIntervalSince($0.createdAt) < Double(max(0, dedupeMinutes) * 60) }
        guard !duplicate else { return false }
        alerts.insert(alert, at: 0)
        return true
    }
    var unreadCount: Int { alerts.filter { !$0.read }.count }
}

struct NextAuditEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    let at: Date
    let action: String
    let reason: String
    let before: NextBook
    let after: NextBook
    var undoneAt: Date?
}
struct NextAuditedBook: Codable, Equatable {
    var current: NextBook
    var events: [NextAuditEvent] = []
    mutating func apply(_ updated: NextBook, action: String, reason: String, at: Date) throws {
        try updated.validate()
        events.append(NextAuditEvent(at: at, action: action, reason: reason, before: current, after: updated))
        current = updated
    }
    mutating func undo(_ eventID: UUID, at: Date) throws {
        guard let index = events.lastIndex(where: { $0.id == eventID }), events[index].undoneAt == nil,
              events[index].after == current else { throw NextError.invalid("此变更已失效或账本已继续更新；请先核对版本") }
        current = events[index].before
        events[index].undoneAt = at
    }
}

enum NextTheme: String, Codable, CaseIterable { case system, light, dark, comfort }

enum NextMarketClock {
    /// Lightweight foreground polling window. It intentionally does not claim
    /// an exchange holiday calendar; stale/closed-session quotes never trigger
    /// a plan and the user can always refresh manually.
    static func isRegularSession(_ date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        return (570...690).contains(current) || (780...900).contains(current)
    }
}

/// Cached NAS research is portable with the encrypted local backup, but it is
/// never a source of truth for the real ledger and never carries an API key.
/// NAS 长期分时统计（1/5/20/60/120 日窗口）。手机端只拿结论，不重算、
/// 也不允许大模型凭空描述——所有数字都能追回 NAS 上归档的分钟行。
struct NextNASMinuteStats: Codable, Equatable {
    struct Window: Codable, Equatable {
        let window: Int
        let daysUsed: Int
        let dayCoverage: Double
        let minuteCoverage: Double
        let vwap: String
        let closeVsVwapPercent: Double?
        let amplitudeMedianPercent: Double?
        let roundTripsMedian: Double?
        let support: String?
        let resistance: String?
        let supportP10: String?
        let resistanceP90: String?
        let volatilityPercent: Double?
        /// Historical intraday excursions relative to each session VWAP, stored as ratios (0.01 = 1%).
        var vwapHighDeviationMedian: Double? = nil
        var vwapLowDeviationMedian: Double? = nil
        /// Share of minute rows with observed volume; a missing volume must not silently count as zero.
        var volumeCoverage: Double? = nil
    }
    struct Quality: Codable, Equatable {
        let days: Int
        let minuteCoverage: Double
        let hasVolume: Bool
        let enoughForLongTerm: Bool
        var volumeCoverage: Double? = nil
    }
    struct Freshness: Codable, Equatable {
        let lastDay: String?
        let ageMinutes: Double?
        let isToday: Bool?
        let stale: Bool
        let reason: String?
    }
    let days: Int
    let minutes: Int
    let lastDay: String?
    let quality: Quality
    let freshness: Freshness
    let windows: [String: Window]
    /// NAS-computed ordered limit touches across complete 1-minute paths. These are historical observations,
    /// not a promise that a future order will fill.
    var roundTripEvidence: RoundTripEvidence? = nil

    struct RoundTripEvidence: Codable, Equatable {
        struct Direction: Codable, Equatable {
            let firstTouched: Int
            let orderedRoundTrips: Int
            let meanWaitMinutes: Double?
        }
        let days: Int
        let completeDays: Int
        let reverse: Direction
        let forward: Direction
    }

    func window(_ count: Int) -> Window? { windows[String(count)] }
}

struct NextNASResearch: Codable, Equatable {
    struct Factor: Codable, Equatable { let code: String; let asOf: String; let source: String; let close: String; let ma20: String; let ma250: String; let state: String }
    struct AI: Codable, Equatable { let code: String; let asOf: String; let source: String; let provider: String; let model: String; let content: String; let realOrder: Bool }
    struct ProviderStatus: Codable, Equatable { let state: String; let configured: Bool; let profile: String; let model: String?; let message: String }
    let factors: Factor?
    let ai: AI?
    let providerConfigured: Bool
    var providerStatus: ProviderStatus? = nil
    /// 长期分时统计。没有就是没有（NAS 上还没攒够分钟归档），界面要如实说。
    var minuteStats: NextNASMinuteStats? = nil
}

struct NextAppArchive: Codable, Equatable {
    var schemaVersion = 1
    var book = NextBook()
    var goal = NextGoal()
    var watch = ["159941", "563020", "159545", "159352"]
    var navigation = NextNavigationState()
    var cachedQuotes: [String: NextCachedQuote] = [:]
    var chartData: [String: NextChartDataset] = [:]
    var instrumentRules: [String: NextInstrumentRules] = [:]
    var orderBooks: [String: NextOrderBookSnapshot] = [:]
    var notifications = NextNotificationCenter()
    var audits: [NextAuditEvent] = []
    var decisionHistory: [NextDecision] = []
    var nasResearch: [String: NextNASResearch] = [:]
    var dividendEvents: [String: [NextETFDividendEvent]] = [:]
    var patientLimitPlans: [NextPatientLimitPlan] = []
    var candidatePlans: [NextCandidatePlan] = []
    /// 动态投资者画像与建议轨迹：备份/恢复必须一起带走，否则换机后画像从零开始。
    var profile = NextInvestorProfile()
    var suggestions: [NextSuggestionRecord] = []
    /// AI 决策记忆：当时依据 + 改判轨迹 + 复盘。备份要带走，否则换机后 AI 就没记忆了。
    var decisionMemory: [NextDecisionRecord] = []
    /// 五套视觉主题（nil = 跟随场景）。备份要带走，换机后外观一致。
    var appTheme: AppTheme?
    var theme: NextTheme = .light
    private enum CodingKeys: String, CodingKey { case schemaVersion, book, goal, watch, navigation, cachedQuotes, chartData, instrumentRules, orderBooks, notifications, audits, decisionHistory, nasResearch, dividendEvents, patientLimitPlans, candidatePlans, decisionMemory, profile, suggestions, appTheme, theme }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        book = try values.decodeIfPresent(NextBook.self, forKey: .book) ?? NextBook()
        goal = try values.decodeIfPresent(NextGoal.self, forKey: .goal) ?? NextGoal()
        watch = try values.decodeIfPresent([String].self, forKey: .watch) ?? ["159941", "563020", "159545", "159352"]
        navigation = try values.decodeIfPresent(NextNavigationState.self, forKey: .navigation) ?? NextNavigationState()
        cachedQuotes = try values.decodeIfPresent([String: NextCachedQuote].self, forKey: .cachedQuotes) ?? [:]
        chartData = try values.decodeIfPresent([String: NextChartDataset].self, forKey: .chartData) ?? [:]
        instrumentRules = try values.decodeIfPresent([String: NextInstrumentRules].self, forKey: .instrumentRules) ?? [:]
        orderBooks = try values.decodeIfPresent([String: NextOrderBookSnapshot].self, forKey: .orderBooks) ?? [:]
        notifications = try values.decodeIfPresent(NextNotificationCenter.self, forKey: .notifications) ?? NextNotificationCenter()
        audits = try values.decodeIfPresent([NextAuditEvent].self, forKey: .audits) ?? []
        decisionHistory = try values.decodeIfPresent([NextDecision].self, forKey: .decisionHistory) ?? []
        nasResearch = try values.decodeIfPresent([String: NextNASResearch].self, forKey: .nasResearch) ?? [:]
        dividendEvents = try values.decodeIfPresent([String: [NextETFDividendEvent]].self, forKey: .dividendEvents) ?? [:]
        patientLimitPlans = try values.decodeIfPresent([NextPatientLimitPlan].self, forKey: .patientLimitPlans) ?? []
        candidatePlans = try values.decodeIfPresent([NextCandidatePlan].self, forKey: .candidatePlans) ?? []
        decisionMemory = try values.decodeIfPresent([NextDecisionRecord].self, forKey: .decisionMemory) ?? []
        profile = try values.decodeIfPresent(NextInvestorProfile.self, forKey: .profile) ?? NextInvestorProfile()
        suggestions = try values.decodeIfPresent([NextSuggestionRecord].self, forKey: .suggestions) ?? []
        appTheme = try values.decodeIfPresent(AppTheme.self, forKey: .appTheme)
        theme = try values.decodeIfPresent(NextTheme.self, forKey: .theme) ?? .light
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw NextError.invalid("本机数据版本不受支持") }
        try book.validate(); try goal.validate()
        guard Set(patientLimitPlans.map(\.id)).count == patientLimitPlans.count else { throw NextError.invalid("耐心限价计划存在重复编号") }
        for plan in patientLimitPlans { try plan.validate() }
        guard Set(candidatePlans.map(\.id)).count == candidatePlans.count else { throw NextError.invalid("候选计划存在重复编号") }
        guard Set(suggestions.map(\.id)).count == suggestions.count else { throw NextError.invalid("AI 建议记录存在重复编号") }
        for plan in candidatePlans { try plan.validate() }
        for (code, events) in dividendEvents {
            guard code.count == 6, code.allSatisfy(\.isNumber), events.allSatisfy({ $0.code == code }) else { throw NextError.invalid("分红历史代码与记录不一致") }
            for event in events { try event.validate() }
        }
        for (code, cached) in cachedQuotes {
            guard code == cached.quote.code, code.count == 6, code.allSatisfy(\.isNumber), cached.quote.price > 0,
                  cached.quote.previousClose > 0, !cached.quote.name.isEmpty, !cached.quote.source.isEmpty,
                  cached.quote.iopv.map({ $0 > 0 && cached.quote.providerInstrumentType == "ETF" }) ?? true else { throw NextError.invalid("缓存行情代码、价格、IOPV 或来源校验失败") }
        }
        guard watch.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isNumber) }), Set(watch).count == watch.count else {
            throw NextError.invalid("自选清单校验失败")
        }
        for (key, chart) in chartData {
            let validKey = key == chart.code || (chart.interval == .day && key == "\(chart.code):day")
            guard validKey else { throw NextError.invalid("图表缓存键与证券代码或周期不匹配") }
            try chart.validate()
        }
        for (code, rule) in instrumentRules { guard code == rule.code else { throw NextError.invalid("证券规则代码不匹配") }; try rule.validate() }
        for (code, book) in orderBooks { guard code == book.code else { throw NextError.invalid("盘口证券代码不匹配") }; try book.validate() }
        guard decisionHistory.count <= 1000,
              decisionHistory.allSatisfy({ decision in
                  !decision.title.isEmpty && !decision.origin.isEmpty &&
                  Set(decision.evidence.map(\.id)).count == decision.evidence.count &&
                  (decision.selectedOption == nil || decision.options.contains(where: { $0.id == decision.selectedOption }))
              }) else { throw NextError.invalid("历史决策记录校验失败") }
        try notifications.priceRules.forEach { try $0.validate() }
        for (code, report) in nasResearch {
            guard code.count == 6, code.allSatisfy(\.isNumber),
                  report.factors.map({ $0.code == code }) ?? true,
                  report.ai.map({ $0.code == code && !$0.realOrder && !$0.content.isEmpty }) ?? true else {
                throw NextError.invalid("NAS 研究缓存校验失败")
            }
        }
    }
}
struct NextArchiveEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let payload: Data
    let sha256: String
    init(archive: NextAppArchive) throws {
        try archive.validate()
        schemaVersion = 1
        payload = try JSONEncoder().encode(archive)
        sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
    func archive() throws -> NextAppArchive {
        guard schemaVersion == 1, SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw NextError.invalid("备份校验值不匹配，未恢复任何数据")
        }
        let value = try JSONDecoder().decode(NextAppArchive.self, from: payload)
        try value.validate()
        return value
    }
}

// MARK: - 账本同步指纹

extension NextBook {
    /// 用户可改动的账本内容指纹，用来判断「本机是不是有改动没上传」。
    ///
    /// 不含 `history`（资产快照是行情衍生物，每天自动增行，拿来当指纹会导致
    /// 天天提示"有未上传改动"）。每一条内容单独编码后排序再拼接，
    /// 这样数组顺序变化不会误判成改动。
    var syncFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        func encode<T: Encodable>(_ value: T) -> String {
            guard let data = try? encoder.encode(value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var parts = ["cash=\(cash)"]
        parts += positions.map { encode($0) }.sorted()
        parts += fills.map { encode($0) }.sorted()
        parts += cashMovements.map { encode($0) }.sorted()
        parts += incomeEvents.map { encode($0) }.sorted()
        parts += dividendEvents.map { encode($0) }.sorted()
        return parts.joined(separator: "\n")
    }
}
