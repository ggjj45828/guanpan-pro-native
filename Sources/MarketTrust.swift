import Foundation

// MARK: - 会话状态

/// A 股交易时段状态。
///
/// 之前全 App 只有一个 `isRegularTradingSession`（是不是 9:30–11:30 / 13:00–15:00），
/// 于是「收盘后录入」「午休时录入」「集合竞价时录入」被当成同一件事。
/// 但这三件事的含义完全不同：收盘后拿到的是确定价，午休拿到的是上午的最后成交，
/// 集合竞价拿到的是虚拟撮合价 —— 起点快照、估值、AI 判断都该区别对待。
enum MarketSessionStatus: String, Codable, Equatable {
    /// 交易日 09:15 之前。
    case preOpen
    /// 09:15–09:25 集合竞价：有虚拟成交价，但没有真实连续成交。
    case callAuction
    /// 09:30–11:30、13:00–15:00。
    case continuous
    /// 11:30–13:00。
    case lunchBreak
    /// 已收盘，或今天根本不是交易日。
    case closed
    /// 日历不可信（既没有自动日历，也不在兜底表覆盖范围内）。
    case unknown

    var title: String {
        switch self {
        case .preOpen: return "未开盘"
        case .callAuction: return "集合竞价"
        case .continuous: return "交易中"
        case .lunchBreak: return "午间休市"
        case .closed: return "已收盘"
        case .unknown: return "时段未知"
        }
    }

    /// 是否可能产生**新的**成交价。午休、集合竞价、收盘都不产生新的连续成交。
    var isLivePricing: Bool { self == .continuous }

    /// 是否属于「今天已经在交易流程里」—— 用来判断起点快照该不该按当日处理。
    var isSameTradingDayContext: Bool {
        switch self {
        case .continuous, .lunchBreak, .callAuction, .preOpen: return true
        case .closed, .unknown: return false
        }
    }
}

enum TradingSession {
    private static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    /// 当前时段。
    ///
    /// 注意 `custom` 要传用户的 `customMarketHolidays`：自定义休市日优先级最高，
    /// 用户手填「今天休假」时不能还按交易日算。
    static func status(at instant: Date, custom: [String] = []) -> MarketSessionStatus {
        guard instant.timeIntervalSince1970.isFinite else { return .unknown }
        let calendar = shanghai
        if MarketCalendar.isClosure(instant, custom: custom) { return .closed }
        let components = calendar.dateComponents([.hour, .minute], from: instant)
        guard let hour = components.hour, let minute = components.minute else { return .unknown }
        let minuteOfDay = hour * 60 + minute
        if minuteOfDay < 555 { return .preOpen }            // < 09:15
        if minuteOfDay < 565 { return .callAuction }        // 09:15–09:25
        if minuteOfDay < 570 { return .preOpen }            // 09:25–09:30 已撮合待开盘
        if minuteOfDay <= 690 { return .continuous }        // 09:30–11:30
        if minuteOfDay < 780 { return .lunchBreak }         // 11:30–13:00
        if minuteOfDay <= 900 { return .continuous }        // 13:00–15:00
        return .closed
    }

    /// 最近一个交易日（含今天，若今天就是交易日）。最多回溯 30 天。
    ///
    /// 用来判断「这条报价是哪天的」：非交易时段只接受落在最近交易日及之后的报价，
    /// 再旧就是缓存，不能当当前价。
    static func lastTradingDay(onOrBefore instant: Date, custom: [String] = []) -> Date? {
        let calendar = shanghai
        var cursor = calendar.startOfDay(for: instant)
        for _ in 0..<30 {
            if !MarketCalendar.isClosure(cursor, custom: custom) { return cursor }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { return nil }
            cursor = previous
        }
        return nil
    }

    /// 15:00 之后的「收盘后」—— 快照与结算该按确定价处理的那个边界。
    static func isAfterClose(_ instant: Date, custom: [String] = []) -> Bool {
        let status = status(at: instant, custom: custom)
        guard status == .closed else { return false }
        let components = shanghai.dateComponents([.hour, .minute], from: instant)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return !MarketCalendar.isClosure(instant, custom: custom) && minuteOfDay > 900
    }
}

// MARK: - 来源可信度

/// 允许支撑「决策级」报价的来源白名单。
///
/// 白名单而不是黑名单：任意非空字符串都能被当成来源标签传进来，
/// 那样等于没有校验。
enum QuoteSourceTrust {
    static let tencentDirect = "腾讯 qt.gtimg.cn"
    static let tencentNASProxy = "观盘 NAS 行情代理"
    static let guanpanFNAS = "观盘F NAS"
    static let sinaIndex = "新浪 hq.sinajs.cn"
    static let eastmoneyIndex = "东财 push2"
    /// 手动覆盖价：用户照着自己券商界面填的。它**不是**行情，
    /// 单独一档，允许显示但不假装成实时价。
    static let manualOverride = "手动覆盖价"

    static let trustedSources: Set<String> = [
        tencentDirect, tencentNASProxy, guanpanFNAS, sinaIndex, eastmoneyIndex
    ]

    static func isTrusted(_ source: String?) -> Bool {
        guard let source else { return false }
        return trustedSources.contains(source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isManual(_ source: String?) -> Bool {
        source?.trimmingCharacters(in: .whitespacesAndNewlines) == manualOverride
    }
}

enum QuoteTimestampTrust: String, Codable, Equatable {
    /// 服务端给了交易所撮合时间，且来源可信。
    case verifiedExchange
    /// 只知道本地什么时候取到的，不知道行情本身几点。
    case fetchedAtOnly
    /// 时间与来源都不可信。
    case unavailable
}

enum QuoteFreshness: String, Codable, Equatable {
    case fresh
    case stale
    case unverified
}

/// 一条报价的时间与来源可信度。
///
/// 存在的意义只有一个：**不让「本地刚请求过」冒充「行情刚成交过」**。
/// 之前界面上的「行情时间」其实就是 `builtAt`（本地时钟），
/// 网络卡住十分钟，界面照样显示「刚刚更新」。
struct QuoteTemporal {
    /// 默认最大容忍年龄（连续竞价期间）。
    static let defaultMaximumAge: TimeInterval = 180

    let quoteTimestamp: Date?
    let fetchedAt: Date?
    let source: String?
    let timestampTrust: QuoteTimestampTrust
    let session: MarketSessionStatus

    init(quoteTimestamp: Date?, fetchedAt: Date?, source: String?, session: MarketSessionStatus) {
        self.quoteTimestamp = quoteTimestamp
        self.fetchedAt = fetchedAt
        self.source = source
        self.session = session
        let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if quoteTimestamp != nil, QuoteSourceTrust.isTrusted(trimmed) {
            timestampTrust = .verifiedExchange
        } else if fetchedAt != nil {
            timestampTrust = .fetchedAtOnly
        } else {
            timestampTrust = .unavailable
        }
    }

    init(quote: Quote, session: MarketSessionStatus) {
        self.init(quoteTimestamp: quote.updatedAt, fetchedAt: quote.fetchedAt,
                  source: quote.source, session: session)
    }

    /// 新鲜度。
    ///
    /// 关键差异：**非交易时段不按 180 秒判**。晚上十点打开 App，
    /// 报价时间戳必然是当天 15:00，按秒判就是全 stale —— 那等于永远不能用。
    /// 收盘后正确的判据是「这条报价来自最近一个交易日或更晚」。
    func freshness(at now: Date,
                   maximumAge: TimeInterval = QuoteTemporal.defaultMaximumAge,
                   custom: [String] = []) -> QuoteFreshness {
        guard now.timeIntervalSince1970.isFinite,
              maximumAge.isFinite, maximumAge >= 0 else { return .unverified }
        if QuoteSourceTrust.isManual(source) { return .unverified }
        guard timestampTrust == .verifiedExchange,
              let quoteTimestamp, let fetchedAt,
              quoteTimestamp.timeIntervalSince1970.isFinite,
              fetchedAt.timeIntervalSince1970.isFinite else { return .unverified }
        // 行情时间晚于获取时间、或晚于现在，都是不可能的 —— 宁可判不可信。
        guard quoteTimestamp <= fetchedAt.addingTimeInterval(90), quoteTimestamp <= now.addingTimeInterval(90) else {
            return .unverified
        }
        switch session {
        case .continuous, .callAuction:
            return now.timeIntervalSince(quoteTimestamp) <= maximumAge ? .fresh : .stale
        case .preOpen, .lunchBreak:
            // 午休与开盘前：只接受今天（或最近交易日）的报价，不要求秒级新鲜。
            return isOnLastTradingDayOrLater(quoteTimestamp, now: now, custom: custom) ? .fresh : .stale
        case .closed, .unknown:
            return isOnLastTradingDayOrLater(quoteTimestamp, now: now, custom: custom) ? .fresh : .stale
        }
    }

    private func isOnLastTradingDayOrLater(_ timestamp: Date, now: Date, custom: [String]) -> Bool {
        guard let lastTradingDay = TradingSession.lastTradingDay(onOrBefore: now, custom: custom) else {
            return false
        }
        // 允许 6 小时容差：交易日 00:00 起算，但当天最早的有效报价在 09:15 之后，
        // 这里比的是「日期是否够新」，不是「几点」。
        return timestamp >= lastTradingDay.addingTimeInterval(-6 * 3600)
    }

    /// 界面上该怎么写时间。绝不把 `fetchedAt` 写成「行情时间」。
    func displayLabel(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) -> String {
        let hasSource = (source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        if QuoteSourceTrust.isManual(source) {
            return "手动覆盖价 · 非行情"
        }
        if timestampTrust == .verifiedExchange, hasSource, let quoteTimestamp,
           quoteTimestamp.timeIntervalSince1970.isFinite {
            formatter.dateFormat = "M月d日 HH:mm"
            let time = formatter.string(from: quoteTimestamp)
            return session == .closed ? "收盘价 · \(time)" : "行情时间 · \(time)"
        }
        if timestampTrust == .fetchedAtOnly, let fetchedAt, fetchedAt.timeIntervalSince1970.isFinite {
            formatter.dateFormat = "HH:mm:ss"
            return "获取于 \(formatter.string(from: fetchedAt)) · 行情时间未验证"
        }
        return "时间未验证"
    }
}
