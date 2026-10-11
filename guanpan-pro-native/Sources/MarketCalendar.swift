import Foundation

/// 交易日历。
///
/// v2.13 之前只有「周末 + 一张写死的 2026 年休市表」，跨年就得人工补，
/// 交易所临时调整也跟不上。现在改成**用上证指数日 K 反推**：
/// 有 K 线的日期就是交易日，没有的就是休市 —— 交易所怎么安排，K 线里就怎么体现。
/// 写死的 2026 表降级为「还没取到日历时的离线兜底」。
enum MarketCalendar {
    /// 上证指数（腾讯代码）。它的日 K 就是最权威的交易日清单。
    static let probeSymbol = "sh000001"

    /// 2026 年内置休市安排（离线兜底）。
    /// 正常情况下由 `PortfolioStore.refreshTradingCalendar()` 自动维护，不再需要人工补表。
    static let mainlandClosures2026: Set<String> = [
        "2026-01-01", "2026-01-02", "2026-01-03",
        "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
        "2026-04-04", "2026-04-05", "2026-04-06",
        "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
        "2026-06-19", "2026-06-20", "2026-06-21",
        "2026-09-25", "2026-09-26", "2026-09-27",
        "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"
    ]

    private static let tradingDaysKey = "guanpan.native.market.tradingDays"
    private static let fetchedOnKey = "guanpan.native.market.calendarFetchedOn"

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func isoDay(_ date: Date) -> String { isoFormatter.string(from: date) }

    static func isWeekend(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    // MARK: - 自动交易日历

    /// 由上证指数日 K 反推的交易日集合（"yyyy-MM-dd"）。
    static func loadTradingDays() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: tradingDaysKey) ?? [])
    }

    static func saveTradingDays(_ days: Set<String>) {
        UserDefaults.standard.set(Array(days).sorted(), forKey: tradingDaysKey)
    }

    /// 是否已经有可用的自动日历。
    static var hasAutoCalendar: Bool { !loadTradingDays().isEmpty }

    /// 自动日历是否覆盖该日期。
    ///
    /// 只覆盖「已经取得日 K 的区间」：区间外的日期**不下结论**，
    /// 免得把还没到的交易日误判成休市（比如今天还在盘中，日 K 里当然没有今天）。
    static func covers(_ isoDay: String) -> Bool {
        let days = loadTradingDays()
        guard let first = days.min(), let last = days.max() else { return false }
        return isoDay >= first && isoDay <= last
    }

    /// 该日期是否休市。
    ///
    /// 自定义休市日优先（用户手填的可以覆盖自动结果）；自动日历覆盖得到就用它，
    /// 覆盖不到再退回内置 2026 表。周末由 `isClosure(_ date:)` 那一版负责。
    static func isClosure(_ isoDay: String, custom: Set<String> = []) -> Bool {
        if custom.contains(isoDay) { return true }
        if covers(isoDay) { return !loadTradingDays().contains(isoDay) }
        return mainlandClosures2026.contains(isoDay)
    }

    static func isClosure(_ date: Date, custom: Set<String> = []) -> Bool {
        isWeekend(date) || isClosure(isoDay(date), custom: custom)
    }

    // MARK: - 拉取节流

    /// 今天是否已经拉过交易日历。一天一次就够 —— 日 K 一天才多一根。
    static var fetchedToday: Bool {
        UserDefaults.standard.string(forKey: fetchedOnKey) == isoDay(.now)
    }

    static func markFetched(on date: Date = .now) {
        UserDefaults.standard.set(isoDay(date), forKey: fetchedOnKey)
    }
}
