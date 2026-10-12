import SwiftUI
import Charts
import UIKit

private struct IndicatorPoint: Identifiable {
    var date: String
    var value: Double
    var id: String { date }
}

private enum NativeChartPeriod: String, CaseIterable, Identifiable {
    case intraday = "分时", day = "日K", week = "周K", month = "月K", minute30 = "30分", minute60 = "60分"
    var id: String { rawValue }
}

private struct MinuteBucket: Identifiable {
    var start: Date
    var close: Double
    var volume: Double?
    var id: Date { start }
}

private struct IntradayVolumeMAPoint: Identifiable {
    let time: Date
    let value: Double
    let period: Int
    var id: String { "\(period)-\(time.timeIntervalSince1970)" }
}

private struct IntradayIOPVPoint: Identifiable {
    let timestamp: Date
    let value: Double
    var id: Date { timestamp }
}

private struct IntradayETFQuoteSummary {
    let turnoverPercent: Double?
    let amplitudePercent: Double?
    let amountYi: Double?
    let marketCapYi: Double?
}

private enum IntradaySubchart: String, CaseIterable, Identifiable {
    case macd = "分时 MACD", volume = "分时量"
    var id: String { rawValue }
}

/// 分时叠加层的显示偏好。只影响图表外观，不属于账本数据。
private enum IntradayVisibility {
    private static let averageKey = "guanpan.intraday.show.average"
    private static let iopvKey = "guanpan.intraday.show.iopv"
    private static let previousCloseKey = "guanpan.intraday.show.previous-close"
    private static let volumeMAKey = "guanpan.intraday.volume-ma"

    static func readBool(_ key: String, default value: Bool = true) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
    static var showAverage: Bool { readBool(averageKey) }
    static var showIOPV: Bool { readBool(iopvKey) }
    static var showPreviousClose: Bool { readBool(previousCloseKey) }
    static var volumeMAs: Set<Int> {
        let raw = UserDefaults.standard.string(forKey: volumeMAKey) ?? "20,60"
        return Set(raw.split(separator: ",").compactMap { Int($0) })
    }
    static func write(average: Bool? = nil, iopv: Bool? = nil, previousClose: Bool? = nil,
                      volumeMAs: Set<Int>? = nil) {
        let defaults = UserDefaults.standard
        if let average { defaults.set(average, forKey: averageKey) }
        if let iopv { defaults.set(iopv, forKey: iopvKey) }
        if let previousClose { defaults.set(previousClose, forKey: previousCloseKey) }
        if let volumeMAs { defaults.set(volumeMAs.sorted().map(String.init).joined(separator: ","), forKey: volumeMAKey) }
    }
}

private struct MinuteMACDPoint: Identifiable {
    var time: Date
    var dif: Double
    var dea: Double
    var histogram: Double
    var id: Date { time }
}

private struct PriceLevelSummary {
    var sourceDay: String
    var pivot: Double
    var support1: Double
    var support2: Double
    var resistance1: Double
    var resistance2: Double
    var channelHigh: Double
    var channelLow: Double
    var channelPosition: Double
    var bollingerUpper: Double
    var bollingerMiddle: Double
    var bollingerLower: Double
}

/// MA 均线显示开关（竖屏/横屏共用同一份 UserDefaults，点图例 chip 切换）。
private enum MAVisibility {
    static let key = "guanpan.native.ma.visible"
    static let ma250DefaultMigrationKey = "guanpan.native.ma250.default.migrated"
    static func read() -> Set<Int> {
        // MA250 默认显示；旧版本已有的均线选择仅迁移一次，之后仍允许用户手动关闭。
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: key) ?? "5,20"
        var visible = Set(raw.split(separator: ",").compactMap { Int($0) })
        if !defaults.bool(forKey: ma250DefaultMigrationKey) {
            visible.insert(250)
            write(visible)
            defaults.set(true, forKey: ma250DefaultMigrationKey)
        }
        return visible
    }
    static func write(_ set: Set<Int>) {
        UserDefaults.standard.set(set.sorted().map(String.init).joined(separator: ","), forKey: key)
    }
}

/// X 轴的日期刻度点（竖屏 / 横屏共用）。
///
/// 逐根显示日期时，相邻标签间距会被压到 10pt 以下互相压叠，小字号下基本读不出来。
/// 改成「每个月只取当月第一个交易日」，上限 5 个；整个可见区间都在同一个月内时等间隔取日期。
private func xAxisDates(_ bars: [DailyBar]) -> [String] {
    guard !bars.isEmpty else { return [] }
    let limit = 5
    var firstOfMonth: [String] = []
    var seenMonths = Set<String>()
    for bar in bars {
        let month = String(bar.date.prefix(7))
        if !seenMonths.contains(month) {
            seenMonths.insert(month)
            firstOfMonth.append(bar.date)
        }
    }
    if firstOfMonth.count >= 2 {
        guard firstOfMonth.count > limit else { return firstOfMonth }
        let stride = Int(ceil(Double(firstOfMonth.count) / Double(limit)))
        return Swift.stride(from: 0, to: firstOfMonth.count, by: stride).map { firstOfMonth[$0] }
    }
    let step = max(1, bars.count / limit)
    return Swift.stride(from: 0, to: bars.count, by: step).map { bars[$0].date }
}

/// 刻度文案：跨月只显示年月（同年「10月」，跨年「25/10」），同一个月内才显示 MM/DD。
private func xAxisLabel(_ date: String, _ bars: [DailyBar]) -> String {
    let sameMonth = bars.isEmpty || Set(bars.map { String($0.date.prefix(7)) }).count <= 1
    if sameMonth { return String(date.suffix(5)).replacingOccurrences(of: "-", with: "/") }
    let month = String(date.dropFirst(5).prefix(2))
    let spansMultipleYears = bars.first.map { first in
        bars.last.map { String(first.date.prefix(4)) != String($0.date.prefix(4)) } ?? false
    } ?? false
    guard spansMultipleYears else { return "\(month)月" }
    return "\(String(date.prefix(4)).suffix(2))/\(month)"
}

struct MarketChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let holding: Holding
    @State private var selectedIntradayDay = ""
    @State private var selectedChartPeriod: NativeChartPeriod = .intraday
    /// 每条均线可单独开关：点图例 chip 切换，状态持久化到 UserDefaults
    @State private var maVisible: Set<Int> = MAVisibility.read()
    @State private var intradaySubchart: IntradaySubchart = .macd
    @State private var showIntradayAverage = IntradayVisibility.showAverage
    @State private var showIntradayIOPV = IntradayVisibility.showIOPV
    @State private var showIntradayPreviousClose = IntradayVisibility.showPreviousClose
    @State private var intradayVolumeMAs = IntradayVisibility.volumeMAs
    @State private var showInstrumentAI = false
    @State private var showIntradayCompanion = false
    @State private var instrumentAIResult = ""
    @State private var instrumentAIMessage = ""
    @State private var instrumentAIBusy = false
    /// AI 建议一键转计划时的预填载体（同时充当 sheet 开关）。
    @State private var planPrefill: AISuggestion?
    @State private var handledSuggestionIDs: Set<UUID> = []
    @State private var suggestionNote = ""
    @State private var isLoading = false
    @State private var isManuallyUpdatingDaily = false
    @State private var isFetchingMinute = false
    @State private var isManuallyRefreshingMinute = false
    @State private var showLandscapeChart = false
    @State private var showRecentDailyBars = false
    @State private var showTechnicalNotes = false
    @State private var showDecisionFactors = false
    @State private var showHistoricalIndicators = false
    @State private var showRuleDetails = false
    @State private var showBacktestDetails = false
    @State private var showSupportResistanceDetails = false
    @State private var showIntradayHistory = false
    @State private var showIntradayJudgment = false
    @State private var message = ""
    @State private var backtestCapital = "100000"
    @State private var backtestFeePercent = "0.03"
    @State private var backtestResult: StrategyBacktestResult?
    @State private var backtestMessage = ""
    @State private var minuteStatus = "正在加载当日分时…"
    @State private var intradayIOPV: Double?
    @State private var intradayPremiumPercent: Double?
    @State private var intradayIOPVDay = ""
    @State private var intradayIOPVPoints: [IntradayIOPVPoint] = []
    @State private var intradayETFQuoteSummary: IntradayETFQuoteSummary?
    @State private var intradayETFQuoteSummaryDay = ""
    @State private var chartZoom = 1.0
    @GestureState private var pinchScale = 1.0
    @State private var chartPanOffset = 0
    @State private var chartDragAppliedX: CGFloat = 0
    @State private var selectedDailyDate: String?

    private var allBars: [DailyBar] { store.dailyBars[holding.code] ?? [] }
    private var bars: [DailyBar] { allBars }
    /// 日 K 始终基于完整历史；屏幕上显示多少根只由捏合缩放与拖动决定。
    private var periodBars: [DailyBar] { aggregated(allBars) }
    /// 当前周期、但用**本机全部**日线聚合。
    ///
    /// 均线一律用这一份来算。显示区间可以只有 60 根，但 MA60 / MA250 需要更早的收盘价
    /// 才能算出区间左端的值 —— 之前只有 MA250 走了这条路，MA5/10/20/60 是拿 `bars`
    /// 当计算源，于是捏合放大到「可见根数 < 窗口长度」时，`source.count >= window`
    /// 不成立，整条线直接消失；拖动去看更早的历史也一样。
    private var periodAllBars: [DailyBar] { aggregated(allBars) }

    /// 把日线聚合成当前周期（日 / 周 / 月）。
    /// 传 `bars` 得到显示区间的序列，传 `allBars` 得到全量序列，两者口径完全一致 ——
    /// 只有口径一致，均线「用全量算、按可见日期取」才对得上横坐标。
    private func aggregated(_ source: [DailyBar]) -> [DailyBar] {
        switch selectedChartPeriod {
        case .intraday, .minute30, .minute60: return []
        case .day: return source
        case .week, .month:
            let calendar = Calendar(identifier: .iso8601)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd"
            let grouped = Dictionary(grouping: source) { bar -> String in
                guard let date = formatter.date(from: bar.date) else { return bar.date }
                if selectedChartPeriod == .month { return String(bar.date.prefix(7)) }
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
            }
            return grouped.values.compactMap { rows in
                let sorted = rows.sorted { $0.date < $1.date }
                guard let first = sorted.first, let last = sorted.last else { return nil }
                let key = selectedChartPeriod == .month ? String(first.date.prefix(7)) + "-01" : first.date
                return DailyBar(code: holding.code, date: key, open: first.open, close: last.close,
                    high: sorted.map(\.high).max() ?? last.high, low: sorted.map(\.low).min() ?? last.low,
                    volume: sorted.reduce(0) { $0 + $1.volume })
            }.sorted { $0.date < $1.date }
        }
    }
    private var intradayDays: [String] {
        Array(Set(store.intradayBars.filter { $0.code == holding.code }.map(\.day))).sorted(by: >)
    }
    private var selectedIntradayBars: [IntradayBar] {
        let day = intradayDays.contains(selectedIntradayDay) ? selectedIntradayDay : (intradayDays.first ?? "")
        return store.intradayBars.filter { $0.code == holding.code && $0.day == day }.sorted { $0.timestamp < $1.timestamp }
    }

    /// 分时均价点：有量就用「累计成交额 / 累计量」的加权均价，
    /// 全程没量（导入的历史分时）就退化为简单算术均价，两种口径都不臆造。
    private struct IntradayAvgPoint: Identifiable {
        let timestamp: Date
        let price: Double
        var id: TimeInterval { timestamp.timeIntervalSince1970 }
    }
    private var intradayAvgPoints: [IntradayAvgPoint] {
        let bars = selectedIntradayBars
        guard !bars.isEmpty else { return [] }
        let hasVolume = bars.contains { ($0.volume ?? 0) > 0 }
        var amount = 0.0
        var shares = 0.0
        var count = 0.0
        var out: [IntradayAvgPoint] = []
        out.reserveCapacity(bars.count)
        for bar in bars {
            if hasVolume {
                let volume = max(bar.volume ?? 0, 0)
                amount += bar.price * volume
                shares += volume
                out.append(IntradayAvgPoint(timestamp: bar.timestamp, price: shares > 0 ? amount / shares : bar.price))
            } else {
                count += 1
                amount += bar.price
                out.append(IntradayAvgPoint(timestamp: bar.timestamp, price: amount / count))
            }
        }
        return out
    }

    /// 昨收基准：优先手填昨收，其次由现价和涨跌幅反推。
    private var intradayPrevClose: Double? {
        // 历史分时必须取该交易日前一根日线收盘，不能拿今天的实时昨收套到旧日期。
        if !selectedIntradayDay.isEmpty,
           let priorClose = (store.dailyBars[holding.code] ?? [])
                .filter({ $0.date < selectedIntradayDay })
                .max(by: { $0.date < $1.date })?.close,
           priorClose.isFinite, priorClose > 0 {
            return priorClose
        }
        guard selectedIntradayDay.isEmpty || selectedIntradayDay == shanghaiDay(.now) else { return nil }
        let manual = store.data.manualQuoteOverrides[holding.code]
        if let previous = manual?.previousClose, previous > 0 { return previous }
        let quote = store.data.quotes.first { $0.code == holding.code }
        if let quote, quote.changePct.isFinite, quote.changePct > -1, quote.price > 0 {
            return quote.price / (1 + quote.changePct)
        }
        if let change = store.marketChanges[holding.code], change.isFinite, change > -1 {
            let price = manual?.price ?? quote?.price ?? holding.current
            if price > 0 { return price / (1 + change) }
        }
        return nil
    }
    private var intradayLatestPrice: Double? {
        selectedIntradayBars.last?.price ?? store.data.quotes.first(where: { $0.code == holding.code })?.price
    }
    private var selectedDayIOPV: Double? { intradayIOPVDay == selectedIntradayDay ? intradayIOPV : nil }
    private var selectedDayPremium: Double? { intradayIOPVDay == selectedIntradayDay ? intradayPremiumPercent : nil }
    private var selectedDayIOPVPoints: [IntradayIOPVPoint] {
        guard intradayIOPVDay == selectedIntradayDay else { return [] }
        return intradayIOPVPoints
    }
    private var selectedDayETFQuoteSummary: IntradayETFQuoteSummary? {
        intradayETFQuoteSummaryDay == selectedIntradayDay ? intradayETFQuoteSummary : nil
    }
    private var intradayChangeText: String {
        guard let latest = intradayLatestPrice, let previous = intradayPrevClose, previous > 0 else { return "涨跌暂无" }
        let change = latest - previous
        return "\(change >= 0 ? "+" : "")\(change.num(3))  \((change / previous * 100).pct(3))"
    }

    private var minuteBuckets: [MinuteBucket] {
        let width: TimeInterval
        switch selectedChartPeriod {
        case .intraday: width = 60
        case .minute30: width = 30 * 60
        default: width = 60 * 60
        }
        let grouped = Dictionary(grouping: selectedIntradayBars) { Int($0.timestamp.timeIntervalSince1970 / width) }
        return grouped.compactMap { key, rows in
            guard let last = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let volumeRows = rows.compactMap(\.volume)
            return MinuteBucket(start: Date(timeIntervalSince1970: Double(key) * width), close: last.price,
                                volume: volumeRows.isEmpty ? nil : volumeRows.reduce(0, +))
        }.sorted { $0.start < $1.start }
    }
    private var minuteMACD: [MinuteMACDPoint] {
        guard minuteBuckets.count >= 2 else { return [] }
        var fast = minuteBuckets[0].close, slow = fast, dea = 0.0
        return minuteBuckets.enumerated().map { index, point in
            if index == 0 { dea = 0 }
            else {
                fast += (2.0 / 13.0) * (point.close - fast)
                slow += (2.0 / 27.0) * (point.close - slow)
            }
            let dif = fast - slow
            dea = index == 0 ? dif : dea + 0.2 * (dif - dea)
            return MinuteMACDPoint(time: point.start, dif: dif, dea: dea, histogram: 2 * (dif - dea))
        }
    }
    private var hasIntradayVolume: Bool {
        minuteBuckets.contains { ($0.volume ?? 0) > 0 }
    }
    private func volumeColor(at index: Int) -> Color {
        let buckets = minuteBuckets
        let previous = index > 0 ? buckets[index - 1].close : (intradayPrevClose ?? buckets[index].close)
        return buckets[index].close >= previous ? Color.red.opacity(0.82) : Color.green.opacity(0.82)
    }
    private func intradayVolumeMA(_ period: Int) -> [IntradayVolumeMAPoint] {
        let source = minuteBuckets.compactMap { point -> (Date, Double)? in
            guard let volume = point.volume else { return nil }
            return (point.start, volume)
        }
        guard period > 0, source.count >= period else { return [] }
        var rolling = 0.0
        var result: [IntradayVolumeMAPoint] = []
        result.reserveCapacity(source.count - period + 1)
        for index in source.indices {
            rolling += source[index].1
            if index >= period { rolling -= source[index - period].1 }
            if index >= period - 1 {
                result.append(IntradayVolumeMAPoint(time: source[index].0,
                    value: rolling / Double(period), period: period))
            }
        }
        return result
    }
    private var intradayLineColor: Color {
        switch store.data.intradayLineColorMode {
        // 「自动」按分时图惯例走黑白：浅色黑线、深色白线。
        // 原来返回 .accentColor（默认蓝），和均价橙、IOPV 紫挤在同一条主图里分不清主线。
        case .automatic: return .primary
        case .white: return .white
        case .black: return .black
        case .upDown:
            guard let first = selectedIntradayBars.first, let last = selectedIntradayBars.last else { return .primary }
            return last.price >= first.price ? .red : .green
        }
    }

    /// 分时图固定横轴：A 股上午 09:30–11:30、下午 13:00–15:00。
    ///
    /// 原来横轴由数据的首尾自动决定：盘中只采到 10:00 时整条线被拉满全宽，
    /// 看着像"已经收盘"；补全后又突然变扁，每次刷新都在跳。固定域之后
    /// 任何时候打开都是同一条轴，午休那段没有分钟点自然留空，
    /// 价格 / MACD / 分时量三个图也才能真正上下对齐。
    private var intradaySessionDomain: ClosedRange<Date>? {
        guard let first = selectedIntradayBars.first else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let start = formatter.date(from: "\(shanghaiDay(first.timestamp)) 09:30"),
              let end = formatter.date(from: "\(shanghaiDay(first.timestamp)) 15:00") else { return nil }
        return start...end
    }

    /// 实际给图表用的横轴域：拿不到交易日就用数据自身首尾兜底（导入的历史分时可能跨夜）。
    private var intradayXDomain: ClosedRange<Date> {
        if let session = intradaySessionDomain { return session }
        let bars = selectedIntradayBars
        return (bars.first?.timestamp ?? .now)...(bars.last?.timestamp ?? .now)
    }

    /// 分时 MACD 纵轴按数据零轴对称铺开（留 12% 余量）。
    ///
    /// 原来纵轴自动拟合：柱子一大就把 DIF/DEA 压成两条贴边的直线，
    /// 而金叉死叉恰恰都发生在零轴附近 —— 域不对称时交叉点被挤到边缘，根本看不出来。
    private var minuteMACDYDomain: ClosedRange<Double> {
        let peak = minuteMACD.flatMap { [abs($0.dif), abs($0.dea), abs($0.histogram)] }.max() ?? 0
        let bound = (peak.isFinite && peak > 0 ? peak : 1) * 1.12
        return -bound...bound
    }
    private var intradayPriceYDomain: ClosedRange<Double> {
        var values = selectedIntradayBars.map(\.price)
        if showIntradayAverage { values += intradayAvgPoints.map(\.price) }
        if showIntradayIOPV { values += selectedDayIOPVPoints.map(\.value); if selectedDayIOPVPoints.isEmpty, let v = selectedDayIOPV { values.append(v) } }
        if showIntradayPreviousClose, let v = intradayPrevClose { values.append(v) }
        values = values.filter { $0 > 0 && $0.isFinite }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let ref = max(abs(low), abs(high), 0.0001), spread = max(high - low, ref * 0.002), pad = max(spread * 0.09, ref * 0.0006)
        return (low - pad)...(high + pad)
    }
    private var priceLevels: PriceLevelSummary? {
        let today = shanghaiDay(.now)
        let completed = allBars.filter { $0.date < today }.sorted { $0.date < $1.date }
        guard let previous = completed.last, previous.high > 0, previous.low > 0, previous.close > 0 else { return nil }
        let pivot = (previous.high + previous.low + previous.close) / 3
        let window = Array(completed.suffix(20))
        guard window.count >= 3 else { return nil }
        let high = window.map(\.high).max() ?? previous.high
        let low = window.map(\.low).min() ?? previous.low
        let closes = window.map(\.close)
        let middle = closes.reduce(0, +) / Double(closes.count)
        let variance = closes.reduce(0.0) { $0 + pow($1 - middle, 2) } / Double(max(1, closes.count - 1))
        let deviation = sqrt(max(0, variance))
        let position = high > low ? ((closes.last ?? previous.close) - low) / (high - low) * 100 : 50
        return PriceLevelSummary(sourceDay: previous.date, pivot: pivot,
            support1: 2 * pivot - previous.high, support2: pivot - (previous.high - previous.low),
            resistance1: 2 * pivot - previous.low, resistance2: pivot + (previous.high - previous.low),
            channelHigh: high, channelLow: low, channelPosition: min(100, max(0, position)),
            bollingerUpper: middle + 2 * deviation, bollingerMiddle: middle, bollingerLower: middle - 2 * deviation)
    }
    private var priceLevelsPromptText: String? {
        guard let levels = priceLevels else { return nil }
        return "枢轴参考日 \(levels.sourceDay)：P \(levels.pivot)，S1/S2 \(levels.support1)/\(levels.support2)，R1/R2 \(levels.resistance1)/\(levels.resistance2)。近 20 个完整日线高低 \(levels.channelHigh)/\(levels.channelLow)，收盘区间位置 \(String(format: "%.1f", levels.channelPosition))%；布林上中下 \(levels.bollingerUpper)/\(levels.bollingerMiddle)/\(levels.bollingerLower)。"
    }
    private var latest: DailyBar? { bars.last }
    /// 单参数版：直接在「显示区间的日线」上算，供 MA20 / MA60 这类只看当前值的
    /// 文字展示使用（不画线，不需要往前借历史，也就不受显示区间长短影响）。
    private func average(_ window: Int) -> [IndicatorPoint] {
        guard window > 0, bars.count >= window else { return [] }
        return bars.indices.compactMap { index in
            guard index + 1 >= window else { return nil }
            let values = bars[(index + 1 - window)...index].map(\.close)
            return IndicatorPoint(date: bars[index].date, value: values.reduce(0, +) / Double(window))
        }
    }

    /// 画线用的均线：**计算源永远是当前周期的全量序列（`full`），`source` 只用来决定画哪些日期**。
    ///
    /// v2.11 及以前只有 MA250 是这么算的，MA5/10/20/60 拿可见窗口当计算源，
    /// 于是捏合放大到「可见根数 < 窗口长度」时 `source.count >= window` 不成立，
    /// 整条线直接返回空 —— 用户看到的正是「只有 250 一直显示，其它线一放大就没了」；
    /// 往左拖去看更早的历史，从区间左端起整段变空也是同一个原因。
    /// 现在所有窗口统一走这条路：够不够长看全量，画哪些点看可见。
    ///
    /// `full` 显式传参而不是在函数体里取 `periodAllBars`：全量聚合要按日期字符串分组，
    /// 一条曲线调一次，五条均线加 Y 轴自适应会调十次，捏合时每帧都重算会拖慢手势。
    /// 所以由调用方（`candlePlot`）算一次、五条线共用。
    private func average(_ window: Int, source: [DailyBar], full: [DailyBar]) -> [IndicatorPoint] {
        guard window > 0, full.count >= window, !source.isEmpty else { return [] }
        let visibleDates = Set(source.map(\.date))
        guard !visibleDates.isEmpty else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity(visibleDates.count)
        for index in (window - 1)..<full.count where visibleDates.contains(full[index].date) {
            let values = full[(index - window + 1)...index].map(\.close)
            out.append(IndicatorPoint(date: full[index].date, value: values.reduce(0, +) / Double(window)))
        }
        return out
    }
    private var drawdown: Double? {
        guard !bars.isEmpty else { return nil }
        var peak = bars[0].close
        var worst = 0.0
        for bar in bars { peak = max(peak, bar.close); worst = min(worst, bar.close / peak - 1) }
        return worst
    }
    private var percentile: Double? {
        guard let latest else { return nil }
        let prices = bars.map(\.close)
        guard !prices.isEmpty else { return nil }
        return Double(prices.filter { $0 <= latest.close }.count) / Double(prices.count) * 100
    }
    private var rsi14: Double? {
        guard bars.count >= 15 else { return nil }
        let closes = bars.suffix(15).map(\.close)
        let changes = (1..<closes.count).map { closes[$0] - closes[$0 - 1] }
        let gains = changes.map { max(0, $0) }.reduce(0, +) / 14
        let losses = changes.map { max(0, -$0) }.reduce(0, +) / 14
        if losses == 0 { return gains == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gains / losses)
    }
    private var macd: (line: Double, signal: Double, histogram: Double)? {
        guard bars.count >= 35 else { return nil }
        let closes = bars.map(\.close)
        var ema12 = closes[0], ema26 = closes[0]
        var lines: [Double] = []
        for (index, close) in closes.enumerated() {
            if index > 0 { ema12 += (2.0 / 13.0) * (close - ema12); ema26 += (2.0 / 27.0) * (close - ema26) }
            if index >= 25 { lines.append(ema12 - ema26) }
        }
        guard let first = lines.first else { return nil }
        var signal = first
        for line in lines.dropFirst() { signal += 0.2 * (line - signal) }
        let line = lines[lines.count - 1]
        return (line, signal, 2 * (line - signal))
    }
    /// 自选标签、详情页和量化引擎统一使用同一套 0...100 技术观察分。
    /// 旧详情页曾另算一套 -100...100 分数，导致同一标的在两个页面结论相反。
    /// 走 store 的 memo 入口：详情页任何重绘（缩放/拖动/刷新）都不重复跑 O(640) 计算。
    private var technicalSignal: MarketSignal? { store.signal(forCode: holding.code) }

    /// “值不值得买”不是第二套趋势分，而是在统一技术分上加入位置与撑压后的条件复核。
    /// 不使用并不存在的 ETF 实时估值字段，避免把猜测包装成“估值分”。
    private var decisionAssessment: (score: Int, label: String, factors: [String])? {
        guard let signal = technicalSignal, let latest else { return nil }
        var score = signal.score
        var factors = ["技术结构 \(signal.score) 分（与自选、量化引擎同口径）"]

        let recent = Array(bars.suffix(60))
        if let low = recent.map(\.low).min(), let high = recent.map(\.high).max(), high > low {
            let position = (latest.close - low) / (high - low) * 100
            if position <= 20 {
                score += 8; factors.append("近 60 日位置 \(position.num(0))%，处于低位，但仍要等止跌确认")
            } else if position >= 80 {
                score -= 10; factors.append("近 60 日位置 \(position.num(0))%，接近上沿，不宜按强势分追高")
            } else {
                factors.append("近 60 日位置 \(position.num(0))%，处于区间中部")
            }
        }
        if signal.isOverbought {
            score -= 8; factors.append("RSI/KDJ 显示超买，短线性价比下降")
        } else if signal.isOversold {
            score += 4; factors.append("RSI/KDJ 显示超卖，只增加观察价值，不等同于见底")
        }
        if let sr = SupportResistanceCalculator.evaluate(bars) {
            if let room = sr.resistanceRoomPercent, room >= 0, room < 2.5 {
                score -= 7; factors.append("距最近历史压力约 \(room.num(1))%，上方空间较窄")
            }
            if let room = sr.supportRoomPercent, room <= 0, abs(room) < 2.5 {
                score += 3; factors.append("距最近历史支撑约 \(abs(room).num(1))%，可等支撑有效性确认")
            }
        }
        score = min(100, max(0, score))
        let label = score >= 68 ? "可关注" : score >= 55 ? "等确认" : score >= 40 ? "谨慎" : "暂避"
        return (score, label, factors)
    }

    private var intradayJudgment: (label: String, factors: [String])? {
        let points = selectedIntradayBars.map(\.price).filter { $0 > 0 }
        guard points.count >= 2, let first = points.first, let last = points.last,
              let low = points.min(), let high = points.max() else { return nil }
        let average = points.reduce(0, +) / Double(points.count)
        let position = high > low ? (last - low) / (high - low) * 100 : 50
        let fromOpen = first > 0 ? (last / first - 1) * 100 : 0
        var strength = 0
        strength += last >= average ? 1 : -1
        if let previous = intradayPrevClose { strength += last >= previous ? 1 : -1 }
        strength += position >= 65 ? 1 : position <= 35 ? -1 : 0
        let label = strength >= 2 ? "盘中偏强" : strength <= -2 ? "盘中偏弱" : "盘中震荡"
        var factors = [
            "最新价 \(last.num(3))，相对当日首个采样点 \(fromOpen.pct(2))",
            last >= average ? "价格在采样均价 \(average.num(3)) 上方" : "价格在采样均价 \(average.num(3)) 下方",
            "处于当日采样区间约 \(position.num(0))% 位置"
        ]
        if let previous = intradayPrevClose {
            factors.append(last >= previous ? "当前高于昨收 \(previous.num(3))" : "当前低于昨收 \(previous.num(3))")
        }
        return (label, factors)
    }
    private var ruleAlerts: [String] {
        guard let latest, bars.count >= 2 else { return [] }
        var alerts: [String] = []
        let previous = bars[bars.count - 2]
        let dailyChange = latest.close / previous.close - 1
        if dailyChange <= -0.05 { alerts.append("单日收盘跌幅达到 5%") }
        if dailyChange >= 0.05 { alerts.append("单日收盘涨幅达到 5%") }
        let ma20 = average(20)
        if ma20.count >= 2 {
            let priorMA = ma20[ma20.count - 2].value, currentMA = ma20[ma20.count - 1].value
            if previous.close >= priorMA && latest.close < currentMA { alerts.append("收盘价下穿 MA20") }
            if previous.close <= priorMA && latest.close > currentMA { alerts.append("收盘价上穿 MA20") }
        }
        if let period = holding.maWarningPeriod, allBars.count >= period,
           let final = allBars.last {
            let average = allBars.suffix(period).map(\.close).reduce(0, +) / Double(period)
            if final.close < average { alerts.append("收盘价下穿你设置的 MA\(period)") }
        }
        if let drawdown, drawdown <= -0.10 { alerts.append("所选区间最大回撤达到 10%") }
        if bars.count >= 21 {
            let referenceVolume = bars.suffix(21).dropLast().map(\.volume).reduce(0, +) / 20
            if referenceVolume > 0 && latest.volume >= referenceVolume * 2 && abs(dailyChange) >= 0.03 {
                alerts.append("成交量达到前 20 日均量 2 倍且单日波动达到 3%")
            }
        }
        return alerts
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let quote = store.data.quotes.first(where: { $0.code == holding.code })
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((quote?.price ?? holding.current).num(3))
                                .scaledFont(30, weight: .bold, design: .rounded)
                            Text("\(holding.name) · \(holding.code)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let quote {
                                Text((quote.changePct * 100).pct(2))
                                    .foregroundStyle(quote.changePct >= 0 ? .red : .green).font(.headline)
                            } else {
                                Text("涨跌幅待更新").font(.caption).foregroundStyle(.secondary)
                            }
                            Text((quote?.updatedAt ?? holding.marketUpdatedAt)?.formatted(date: .omitted, time: .shortened) ?? "等待行情")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if holding.quantity > 0 {
                        HStack(spacing: 10) {
                            quoteMetric("持有份额", "\(holding.quantity.compactNum(2))份")
                            quoteMetric("持仓成本", holding.cost.num(3))
                            quoteMetric("持仓浮盈", holding.pnl.cny())
                                .foregroundStyle(PnLColor.of(holding.pnl))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let first = selectedIntradayBars.first, !selectedIntradayBars.isEmpty {
                        let points = selectedIntradayBars
                        HStack(spacing: 0) {
                            quoteMetric("开盘", first.price.num(3))
                            quoteMetric("最高", (points.map(\.price).max() ?? first.price).num(3))
                            quoteMetric("最低", (points.map(\.price).min() ?? first.price).num(3))
                            quoteMetric("成交量", points.compactMap(\.volume).reduce(0, +).formatted(.number.notation(.compactName)))
                        }
                    }
                    Picker("图表周期", selection: $selectedChartPeriod) {
                        ForEach(NativeChartPeriod.allCases) { period in Text(period.rawValue).tag(period) }
                    }.pickerStyle(.menu)
                    if selectedChartPeriod == .intraday {
                        HStack(spacing: 12) {
                            Text("均价 \(intradayAvgPoints.last?.price.num(3) ?? "暂无")").foregroundStyle(.orange)
                            Text("最新 \(intradayLatestPrice?.num(3) ?? "暂无")").foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            Text(intradayChangeText).foregroundStyle((intradayLatestPrice ?? 0) >= (intradayPrevClose ?? .infinity) ? .red : .green)
                        }
                        .font(.caption.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        HStack(spacing: 12) {
                            Text("实时参考净值 (IOPV)：\(selectedDayIOPV?.num(4) ?? "暂无")").foregroundStyle(.purple)
                            Text("溢价率：\(selectedDayPremium?.pct(2) ?? "暂无")")
                                .foregroundStyle((selectedDayPremium ?? 0) >= 0 ? .red : .green)
                        }
                        .font(.caption.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        if let stats = selectedDayETFQuoteSummary {
                            Text("换手 \(stats.turnoverPercent.map { $0.pct(2) } ?? "暂无")  ·  振幅 \(stats.amplitudePercent.map { $0.pct(2) } ?? "暂无")  ·  成交额 \(stats.amountYi.map { "\($0.num(2))亿" } ?? "暂无")  ·  规模 \(stats.marketCapYi.map { "\($0.num(2))亿" } ?? "暂无")")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(2).minimumScaleFactor(0.75)
                        }
                        if selectedIntradayBars.count > 1 {
                            intradayPanel
                            Text("行情源当日分时 · 前台约 15 秒刷新 · \(minuteStatus)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView("暂无当日分时", systemImage: "chart.xyaxis.line", description: Text(minuteStatus))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Button { Task { await manuallyRefreshMinute() } } label: {
                                HStack(spacing: 6) {
                                    RefreshToolbarIcon(isRefreshing: isManuallyRefreshingMinute)
                                    Text("刷新并补齐")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("刷新并补齐当前标的分时")
                            .disabled(isManuallyRefreshingMinute)
                            .padding(.vertical, 8)
                            Divider()
                            Button { showIntradayCompanion = true } label: {
                                Label("盘中 AI 陪伴", systemImage: "sparkles.rectangle.stack")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.vertical, 8)
                        }
                    } else if selectedChartPeriod == .minute30 || selectedChartPeriod == .minute60 {
                        if minuteBuckets.count > 1 {
                            Chart(minuteBuckets) { point in
                                LineMark(x: .value("时间", point.start), y: .value("价格", point.close), series: .value("分时序列", "价格"))
                                    .foregroundStyle(intradayLineColor)
                                    .lineStyle(StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.linear)
                            }
                            .frame(height: 240)
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                            Picker("分时副图", selection: $intradaySubchart) {
                                ForEach(IntradaySubchart.allCases) { item in Text(item.rawValue).tag(item) }
                            }.pickerStyle(.segmented)
                            if intradaySubchart == .macd {
                                Chart(minuteMACD) { point in
                                    BarMark(x: .value("时间", point.time), y: .value("MACD柱", point.histogram))
                                        .foregroundStyle(point.histogram >= 0 ? Color.red : Color.green)
                                    LineMark(x: .value("时间", point.time), y: .value("DIF", point.dif), series: .value("MACD序列", "DIF"))
                                        .foregroundStyle(Color.cyan)
                                    LineMark(x: .value("时间", point.time), y: .value("DEA", point.dea), series: .value("MACD序列", "DEA"))
                                        .foregroundStyle(Color.orange)
                                }
                                .frame(height: 110)
                                .chartXAxis(.hidden)
                            } else if minuteBuckets.contains(where: { $0.volume != nil }) {
                                Chart(minuteBuckets.filter { $0.volume != nil }) { point in
                                    BarMark(x: .value("时间", point.start), y: .value("成交量", point.volume ?? 0))
                                        .foregroundStyle(Color.cyan)
                                }
                                .frame(height: 110)
                                .chartXAxis(.hidden)
                            } else {
                                Text("所选分时记录没有成交量列；导入含 volume 列的 CSV 后可查看分时量。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("按本机已保存的分时点聚合；仅显示 \(selectedIntradayDay)，缺失分钟不会补造。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView("该日分时点不足", systemImage: "chart.xyaxis.line", description: Text("先在前台采集行情或导入分时 CSV。30/60 分钟图只根据本机保存的分时点聚合。"))
                        }
                    } else if periodBars.count > 1 {
                        dailyChartSection
                    } else {
                        ContentUnavailableView("暂无\(selectedChartPeriod.rawValue)", systemImage: "chart.xyaxis.line", description: Text("联网获取历史行情，或在备份中导入已有日线缓存。"))
                    }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button { Task { await manuallyRefreshDaily() } } label: {
                        HStack(spacing: 6) {
                            RefreshToolbarIcon(isRefreshing: isManuallyUpdatingDaily)
                            Text(isManuallyUpdatingDaily ? "正在更新…" : "更新历史日线")
                        }
                    }.disabled(isManuallyUpdatingDaily)
                    Text("数据：腾讯前复权日线。MA5/20/60、RSI14、MACD、区间分位与最大回撤由本机计算，仅作历史描述，不是价格预测或估值。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        if let saved = store.data.savedInstrumentAIAnalyses[holding.code] {
                            instrumentAIResult = saved.text
                        }
                        showInstrumentAI = true
                    } label: {
                        Label("AI 分析此标的", systemImage: "sparkles")
                    }.disabled(!AIAnalysisService.hasSavedAPIKey)
                    if !AIAnalysisService.hasSavedAPIKey { Text("先在 AI 页面保存接口和 API 密钥；单标的分析会把该标的行情、持仓、历史日线、历史支撑压力参考及所选交易日已有分时点发送给模型。")
                        .font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("\(holding.name) · \(holding.code)") }
                Section {
                  DisclosureGroup(isExpanded: $showIntradayHistory) {
                    if intradayDays.isEmpty {
                        ContentUnavailableView("暂无本机分时记录", systemImage: "chart.xyaxis.line", description: Text("行情刷新采集到的数据或导入的分时 CSV 会保存在本机；没有记录的日期不会补造走势。"))
                    } else {
                        Picker("交易日", selection: $selectedIntradayDay) {
                            ForEach(intradayDays, id: \.self) { day in Text(day).tag(day) }
                        }
                        if selectedIntradayBars.count > 1 {
                            intradayPanel
                            if let first = selectedIntradayBars.first, let last = selectedIntradayBars.last {
                                Text("\(selectedIntradayBars.count) 点 · \(first.timestamp.formatted(date: .omitted, time: .shortened)) 至 \(last.timestamp.formatted(date: .omitted, time: .shortened)) · 仅本机采集/导入数据")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("所选交易日记录不足两个点，无法绘制分时线。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                  } label: {
                      HStack { Text("历史分时"); Spacer(); Text(showIntradayHistory ? "收起" : "展开").font(.caption).foregroundStyle(.secondary) }
                  }
                }
                Section {
                  DisclosureGroup(isExpanded: $showIntradayJudgment) {
                    if let judgment = intradayJudgment {
                        Label(judgment.label, systemImage: judgment.label.contains("偏强") ? "arrow.up.right" : judgment.label.contains("偏弱") ? "arrow.down.right" : "arrow.right")
                            .font(.headline)
                            .foregroundStyle(judgment.label.contains("偏强") ? PnLColor.up : judgment.label.contains("偏弱") ? PnLColor.down : Color.secondary)
                        ForEach(judgment.factors, id: \.self) { Text("• \($0)").font(.subheadline) }
                    } else {
                        Text("当前分时样本不足；刷新分时或选择已有记录的交易日后再研判。")
                            .foregroundStyle(.secondary)
                    }
                    Text("盘中结论只描述所选交易日的价格位置与采样均价，不代替日线趋势，也不把简单平均价冒充交易所 VWAP。")
                        .font(.footnote).foregroundStyle(.secondary)
                  } label: {
                      HStack {
                          Text("盘中研判")
                          Spacer()
                          Text(intradayJudgment?.label ?? "样本不足")
                              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                          Image(systemName: showIntradayJudgment ? "chevron.up" : "chevron.down")
                              .font(.caption2).foregroundStyle(.tertiary)
                      }
                  }
                }
                if let latest {
                    Section("技术指标 · 统一评分") {
                        if let signal = technicalSignal {
                            LabeledContent("技术观察分", value: "\(signal.score) · \(signal.label)")
                            SignalTagRow(tags: signal.tags)
                            DisclosureGroup(isExpanded: $showTechnicalNotes) {
                                ForEach(signal.notes, id: \.self) { Text("• \($0)").font(.footnote) }
                            } label: {
                                Text(showTechnicalNotes ? "收起评分依据" : "查看评分依据（\(signal.notes.count) 项）")
                                    .font(.caption.weight(.medium))
                            }
                        } else {
                            Text("至少需要 20 个交易日，才能计算技术信号。")
                        }
                        Text("这项分数与自选标签、量化引擎完全同口径，只衡量日线结构，不是上涨概率。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("值不值得买 · 条件复核") {
                        if let assessment = decisionAssessment {
                            LabeledContent("复核分", value: "\(assessment.score) · \(assessment.label)")
                            DisclosureGroup(isExpanded: $showDecisionFactors) {
                                ForEach(assessment.factors, id: \.self) { Text("• \($0)").font(.subheadline) }
                            } label: {
                                Text(showDecisionFactors ? "收起条件" : "展开判断条件（\(assessment.factors.count) 项）")
                                    .font(.caption.weight(.medium))
                            }
                        } else {
                            Text("日线数据不足，暂时无法复核。")
                        }
                        Text("高分不等于立即买入：它把统一技术分与近 60 日位置、超买超卖和历史撑压合并；没有可靠 ETF 估值数据时，不虚构“估值分”。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                      DisclosureGroup(isExpanded: $showHistoricalIndicators) {
                        LabeledContent("最新收盘（\(latest.date)）", value: (latest.close).num(3))
                        if let signal = technicalSignal {
                            if let value = signal.ma5 { LabeledContent("MA5 / MA10", value: "\(value.num(3)) / \(signal.ma10?.num(3) ?? "--")") }
                            if let value = signal.ma20 { LabeledContent("MA20 / MA60", value: "\(value.num(3)) / \(signal.ma60?.num(3) ?? "--")") }
                            if signal.ma120 != nil || signal.ma250 != nil {
                                LabeledContent("MA120 / MA250", value: "\(signal.ma120?.num(3) ?? "--") / \(signal.ma250?.num(3) ?? "--")")
                            }
                            if let value = signal.rsi { LabeledContent("RSI14", value: value.num(1)) }
                            if let value = signal.kdjJ { LabeledContent("KDJ · J", value: value.num(1)) }
                            if let value = signal.volumeRatio { LabeledContent("量比（20日）", value: value.num(2)) }
                        }
                        if let macd {
                            LabeledContent("MACD", value: "\((macd.line).num(4))")
                            LabeledContent("信号线 / 柱", value: "\((macd.signal).num(4)) / \((macd.histogram).num(4))")
                        }
                        if let percentile { LabeledContent("区间收盘分位", value: "\((percentile).num(1))%") }
                        if let drawdown { LabeledContent("区间最大回撤", value: "\((drawdown * 100).num(1))%") }
                      } label: {
                          HStack {
                              Text("查看详细指标")
                              Spacer()
                              Text(showHistoricalIndicators ? "收起" : "展开")
                                  .font(.caption).foregroundStyle(.secondary)
                          }
                      }
                    } header: { Text("历史指标") }
                }
                Section {
                  DisclosureGroup(isExpanded: $showRuleDetails) {
                    if ruleAlerts.isEmpty {
                        Label("所选区间内未触发内置规则", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        ForEach(ruleAlerts, id: \.self) { rule in
                            Label(rule, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Text("规则检查 MA20 穿越、单日 ±5%、区间回撤 10%、量能 2 倍且单日波动 3%。仅检查当前加载的日线，不是实时监控，也不会自动发通知或预测涨跌。")
                        .font(.footnote).foregroundStyle(.secondary)
                  } label: {
                      HStack { Text("日线规则提示"); Spacer(); Text(showRuleDetails ? "收起" : "展开").font(.caption).foregroundStyle(.secondary) }
                  }
                } header: { Text("日线规则提示") }
                Section {
                  DisclosureGroup(isExpanded: $showBacktestDetails) {
                    TextField("初始资金（元）", text: $backtestCapital).keyboardType(.decimalPad)
                    TextField("单边费率（%）", text: $backtestFeePercent).keyboardType(.decimalPad)
                    Button("回测当前所选区间") { runBacktest() }
                    if let result = backtestResult {
                        LabeledContent("回测区间", value: "\(result.startDate) 至 \(result.endDate)")
                        LabeledContent("MA 策略期末资产", value: (result.strategyValue).cny())
                        LabeledContent("MA 策略收益", value: (result.strategyReturn * 100).pct(2))
                        LabeledContent("买入持有期末资产", value: (result.holdValue).cny())
                        LabeledContent("买入持有收益", value: (result.holdReturn * 100).pct(2))
                        LabeledContent("MA 策略最大回撤", value: (result.maxDrawdown * 100).pct(2))
                        LabeledContent("模拟委托次数", value: "\(result.orders)")
                    }
                    if !backtestMessage.isEmpty { Text(backtestMessage).font(.footnote).foregroundStyle(.orange) }
                    Text("收盘信号在下一交易日开盘成交，按 100 份整手及单边费率估算；不含滑点、停牌、涨跌停、真实税费与交易限制。腾讯前复权数据可能调整；历史结果不代表未来收益，也不构成买卖建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                  } label: {
                      HStack { Text("MA5 / MA20 历史策略回测"); Spacer(); Text(showBacktestDetails ? "收起" : "展开").font(.caption).foregroundStyle(.secondary) }
                  }
                } header: { Text("历史策略回测") }
                Section("最近日线") {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.2)) { showRecentDailyBars.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(showRecentDailyBars ? "收起最近 20 根" : "展开最近 20 根")
                                    .font(.subheadline.weight(.semibold))
                                if let latest = bars.last {
                                    Text("最新 \(latest.date) · 收盘 \((latest.close).num(3))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showRecentDailyBars ? 180 : 0))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showRecentDailyBars ? "收起最近日线" : "展开最近日线")

                    if showRecentDailyBars {
                        ForEach(bars.suffix(20).reversed()) { bar in
                            HStack {
                                Text(bar.date)
                                Spacer()
                                Text("收 \((bar.close).num(3))")
                                Text("高低 \((bar.high).num(3)) / \((bar.low).num(3))").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .transition(.opacity)
                        }
                    }
                }
                Section {
                  DisclosureGroup(isExpanded: $showSupportResistanceDetails) {
                    if let levels = priceLevels {
                        LabeledContent("枢轴参考日", value: levels.sourceDay)
                        LabeledContent("中枢 P", value: (levels.pivot).num(3))
                        LabeledContent("支撑 S1 / S2", value: "\((levels.support1).num(3)) / \((levels.support2).num(3))")
                        LabeledContent("压力 R1 / R2", value: "\((levels.resistance1).num(3)) / \((levels.resistance2).num(3))")
                        LabeledContent("近 20 个完整交易日高 / 低", value: "\((levels.channelHigh).num(3)) / \((levels.channelLow).num(3))")
                        LabeledContent("收盘在区间的位置", value: String(format: "%.0f%%", levels.channelPosition))
                        LabeledContent("布林上 / 中 / 下", value: "\((levels.bollingerUpper).num(3)) / \((levels.bollingerMiddle).num(3)) / \((levels.bollingerLower).num(3))")
                    } else {
                        Text("本机完整日线不足，暂时无法计算。")
                            .foregroundStyle(.secondary)
                    }
                    Text("枢轴位用最近一个已完成交易日的高低收计算；中期通道和布林带只用本机已保存的完整日线。行情源没有盘口深度字段，因此不显示挂单强弱。以上均为历史价格参考，不是买卖建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                  } label: {
                      HStack { Text("支撑压力与中期区间"); Spacer(); Text(showSupportResistanceDetails ? "收起" : "展开").font(.caption).foregroundStyle(.secondary) }
                  }
                } header: { Text("支撑压力与中期区间") }
            }
            .navigationTitle(holding.quantity > 0 ? "持仓分析" : "标的分析")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .background(.clear)
            .refreshFeedbackOverlay(refreshFeedback)
            .themedSheetBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLandscapeChart = true } label: {
                        Label("横屏大图", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            .fullScreenCover(isPresented: $showLandscapeChart) {
                LandscapeChartView(holding: holding)
            }
            .sheet(isPresented: $showIntradayCompanion) { IntradayCompanionView(holding: holding).themedSheetBackground() }
            .sheet(isPresented: $showInstrumentAI) {
                NavigationStack {
                    List {
                        if instrumentAIBusy { ProgressView("正在分析此标的…") }
                        if !instrumentAIMessage.isEmpty { Text(instrumentAIMessage).foregroundStyle(.secondary) }
                        if !instrumentAIResult.isEmpty {
                            // 展示剥掉机器可读段的人话版本；解析仍读完整原文。
                            Section("分析结果") {
                                if let saved = store.data.savedInstrumentAIAnalyses[holding.code] {
                                    Label("上次成功分析：\(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                                          systemImage: "clock.arrow.circlepath")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                AIFormattedResultView(text: AISuggestionParser.displayText(instrumentAIResult),
                                                      accent: store.effectiveAccentColor)
                            }
                        }
                        if !instrumentAISuggestions.isEmpty {
                            Section("可执行建议（\(instrumentAISuggestions.count) 条）") {
                                ForEach(instrumentAISuggestions) { suggestion in
                                    instrumentSuggestionRow(suggestion)
                                }
                                if !suggestionNote.isEmpty {
                                    Text(suggestionNote).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .toneCard(CardTone.accent, isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
                        }
                        Text("只依据本机现有行情、日线/支撑压力参考和所选交易日已有分时点生成分析；缺少的数据不会补造。模型输出可能有误，不构成买卖指令。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .navigationTitle("\(holding.name) · AI 分析")
                    .navigationBarTitleDisplayMode(.inline)
                    .scrollContentBackground(.hidden)
                    .appListLayout()
                    .background(.clear)
                    .themedSheetBackground()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if !instrumentAIResult.isEmpty {
                                Button(instrumentAIBusy ? "分析中…" : "重新分析") { Task { await analyzeInstrument() } }
                                    .disabled(instrumentAIBusy)
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) { Button("关闭") { showInstrumentAI = false } }
                    }
                    .task {
                        if instrumentAIResult.isEmpty { await analyzeInstrument() }
                    }
                    .sheet(item: $planPrefill) { suggestion in
                        TradePlanEditor(prefill: suggestion, onSave: { plan in
                            store.data.tradePlans.append(plan)
                            store.save(label: "AI 建议转交易计划")
                            handledSuggestionIDs.insert(suggestion.id)
                            suggestionNote = "已存入「交易计划与复盘」，到复盘日期前都可以修改或取消。"
                        })
                        .themedSheetBackground()
                    }
                }
                .themedSheetBackground()
            }
            .onAppear {
                if selectedIntradayDay.isEmpty { selectedIntradayDay = intradayDays.first ?? "" }
                intradaySubchart = store.data.intradaySubchartMode == "volume" ? .volume : .macd
                if !selectedIntradayBars.isEmpty {
                    minuteStatus = "显示本机已保存的 \(selectedIntradayDay) 分时 · 正在检查更新"
                }
            }
            .onChange(of: intradaySubchart) { _, value in
                store.data.intradaySubchartMode = value == .volume ? "volume" : "macd"
                store.save(label: "修改分时副图")
            }
            .task {
                // 显示区间可以只有 60 日，但 MA250 需要更早的 250 根收盘价作计算窗口。
                // 本地历史不足时主动拉取最多 640 根，缩放/缩短横坐标范围不影响均线计算。
                if allBars.count < 250 { await load(force: !allBars.isEmpty) }
                while !Task.isCancelled {
                    await fetchTencentMinute()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    @MainActor private func manuallyRefreshMinute() async {
        guard !isManuallyRefreshingMinute else { return }
        isManuallyRefreshingMinute = true
        defer { isManuallyRefreshingMinute = false }
        refreshFeedback.begin("正在补齐当前标的分时…")
        let deadline = Date().addingTimeInterval(20)
        while isFetchingMinute && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            let refreshed = try await store.fetchAndArchiveLatestIntraday(code: holding.code)
            guard let day = refreshed.last?.day else { throw URLError(.cannotParseResponse) }
            selectedIntradayDay = day
            let savedCount = store.intradayBars.filter { $0.code == holding.code && $0.day == day }.count
            minuteStatus = "已更新 \(day) · 本机现有 \(savedCount) 个分钟点"
            refreshFeedback.finish(minuteStatus, succeeded: true)
        } catch {
            minuteStatus = selectedIntradayBars.isEmpty
                ? "分时补全失败：\(error.localizedDescription)"
                : "补全失败，仍显示本机已保存的 \(selectedIntradayDay) 分时"
            refreshFeedback.finish(minuteStatus, succeeded: false)
        }
    }

    @MainActor private func manuallyRefreshDaily() async {
        guard !isManuallyUpdatingDaily else { return }
        isManuallyUpdatingDaily = true
        defer { isManuallyUpdatingDaily = false }
        refreshFeedback.begin("正在更新历史日线…")
        let deadline = Date().addingTimeInterval(20)
        while isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard !isLoading else {
            refreshFeedback.finish("日线请求仍未结束，请稍后重试", succeeded: false)
            return
        }
        await load(force: true)
        let ok = !message.contains("失败")
        refreshFeedback.finish(message.isEmpty ? (ok ? "历史日线已更新" : "历史日线更新失败") : message,
                               succeeded: ok)
    }

    private var zoomedBarCount: Int {
        let comfortableDefault = min(120, max(1, periodAllBars.count))
        return min(periodAllBars.count, max(6, Int(Double(comfortableDefault) / (chartZoom * pinchScale))))
    }

    private var maxChartPanOffset: Int { max(0, periodAllBars.count - zoomedBarCount) }
    private var minimumChartZoom: Double {
        guard !periodAllBars.isEmpty else { return 1 }
        return min(1, Double(min(120, periodAllBars.count)) / Double(periodAllBars.count))
    }

    // MARK: - 日K 图（主图 + 成交量副图）

    // 四条均线色相尽量拉开，避免挤在相邻波段导致「看起来都是一个颜色」。
    // 色值统一放在 ChartPalette，横屏大图与这里共用同一套，不会两处配色不一致。
    private var ma5Color: Color { ChartPalette.ma5 }
    private var ma10Color: Color { ChartPalette.ma10 }
    private var ma20Color: Color { ChartPalette.ma20 }
    private var ma60Color: Color { ChartPalette.ma60 }

    // 日 K 区高度原来写死 390（主图 300 + 副图 82）。
    // 固定值在 SE 上顶到屏幕外、在 Pro Max / iPad 上又只占中间一小块，
    // 所以改成按屏幕高度取比例再夹一个区间：小屏保底 300，大屏最多 540。
    private var chartBodyHeight: CGFloat {
        min(max(UIScreen.main.bounds.height * 0.42, 300), 540)
    }
    private var volumeHeight: CGFloat {
        min(max(chartBodyHeight * 0.21, 60), 120)
    }
    private var candleHeight: CGFloat {
        max(180, chartBodyHeight - volumeHeight - 8)
    }


    // MARK: 可见窗口的 Y 轴自适应

    /// 显式按「当前可见的 K 线」计算 Y 轴区间。
    ///
    /// 之前依赖 SwiftUI Charts 的自动 domain：它会带一层不可控的留白，
    /// 缩放时变化不明显，看起来就像高低区间是死的。
    /// 显式给 domain 后，捏合和拖动都会立即重算上下界。
    /// 均线也一并纳入，避免 MA60 在窗口外被裁掉。
    ///
    /// `full` 由调用方传进来（同一次渲染里与 `candlePlot` 共用一份全量聚合），
    /// 不在函数里现取，理由见 `average(_:source:full:)`。
    private func yDomain(for bars: [DailyBar], full: [DailyBar]) -> ClosedRange<Double> {
        guard !bars.isEmpty else { return 0...1 }
        var low = bars.map(\.low).min() ?? 0
        var high = bars.map(\.high).max() ?? 1
        for window in [5, 10, 20, 60, 250] where maVisible.contains(window) {
            let source = average(window, source: bars, full: full)
            for point in source {
                low = min(low, point.value)
                high = max(high, point.value)
            }
        }
        // 前复权价格可能与账本成交价略有差异，把可见 B/S 价格纳入范围，避免标记被裁掉。
        if selectedChartPeriod == .day {
            for entry in visibleTradeEntries where entry.price > 0 {
                low = min(low, entry.price)
                high = max(high, entry.price)
            }
        }
        guard high > low else {
            let base = max(high, 0.0001)
            return (base * 0.999)...(base * 1.001)
        }
        let padding = (high - low) * 0.06
        return (low - padding)...(high + padding)
    }

    /// 可见窗口最高/最低的文字，用于图上方实时提示
    private func windowHighLowText(_ bars: [DailyBar]) -> String {
        guard let high = bars.map(\.high).max(), let low = bars.map(\.low).min(), !bars.isEmpty else { return "" }
        return "高 \((high).num(3))  低 \((low).num(3))"
    }

    private var selectedDailyBar: DailyBar? {
        guard let selectedDailyDate else { return nil }
        return zoomedPeriodBars.first { $0.date == selectedDailyDate }
    }

    private var visibleTradeEntries: [LedgerEntry] {
        guard selectedChartPeriod == .day else { return [] }
        let dates = Set(zoomedPeriodBars.map(\.date))
        return store.data.ledger.filter { $0.code == holding.code && dates.contains(shanghaiDay($0.date)) }
    }

    private func transactions(on day: String) -> [LedgerEntry] {
        store.data.ledger.filter { $0.code == holding.code && shanghaiDay($0.date) == day }
    }

    private func selectedDailyBarCard(_ bar: DailyBar) -> some View {
        let full = periodAllBars
        let index = full.firstIndex { $0.date == bar.date }
        let previous = index.flatMap { $0 > 0 ? full[$0 - 1].close : nil }
        let change = previous.flatMap { $0 > 0 ? (bar.close / $0 - 1) * 100 : nil }
        let trades = transactions(on: bar.date)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bar.date).font(.caption.weight(.semibold)).monospacedDigit()
                Spacer()
                if let change {
                    Text(change.pct(2)).font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(change >= 0 ? Color.red : Color.green)
                }
            }
            HStack(spacing: 10) {
                Text("开 \(bar.open.num(3))")
                Text("高 \(bar.high.num(3))")
                Text("低 \(bar.low.num(3))")
                Text("收 \(bar.close.num(3))")
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 8) {
                Text("量 \(bar.volume.num(0))").font(.caption2).foregroundStyle(.secondary)
                ForEach(trades) { entry in
                    Text("\(entry.side == .buy ? "B 买" : "S 卖") \(entry.quantity.num(0)) @ \(entry.price.num(3))")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(entry.side == .buy ? Color.red : Color.green)
                }
            }
        }
        .padding(9)
        .background(store.effectiveAccentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }


    @ViewBuilder private var dailyChartSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
            Text("轻点看当日 · 双指自由缩放 · 左右拖动")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            // 可见窗口的最高/最低：捏合、拖动时实时跟着变，不再是整个区间的固定值
            Text(windowHighLowText(zoomedPeriodBars))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("重置") { chartZoom = 1; chartPanOffset = 0; selectedDailyDate = nil }.font(.caption)
        }
            if let selected = selectedDailyBar { selectedDailyBarCard(selected) }
            maLegendRow
            // GeometryReader 拿到实际绘图宽度，据此算出随缩放变化的实体宽度。
            // 之前实体固定 5pt，放大后柱子不变粗、间距却变大，看起来既稀疏又糊。
            GeometryReader { geo in
                let slot = max(60, geo.size.width) / CGFloat(max(1, zoomedPeriodBars.count))
                let bodyWidth = ChartBarWidth.candle(slot: slot)
                let barWidth = ChartBarWidth.volume(slot: slot)
                VStack(spacing: 8) {
                    candlePlot(bodyWidth: bodyWidth).frame(height: candleHeight)
                    volumePlot(width: barWidth).frame(height: volumeHeight)
                }
            }
            .frame(height: chartBodyHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(MagnifyGesture()
                .updating($pinchScale) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    // 上限 8 → 40：原来最多只能把 250 根压到 31 根，单根 K 线仍然很挤。
                    chartZoom = min(40, max(minimumChartZoom, chartZoom * value.magnification))
                    chartPanOffset = min(chartPanOffset, maxChartPanOffset)
                })
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let chartWidth = max(240, UIScreen.main.bounds.width - 64)
                    let pointsPerBar = max(5, chartWidth / CGFloat(max(1, zoomedBarCount)))
                    let unapplied = value.translation.width - chartDragAppliedX
                    let step = Int(unapplied / pointsPerBar)
                    guard step != 0 else { return }
                    // 内容跟手：向右拖查看更早的 K 线，向左拖回最近行情。
                    chartPanOffset = min(maxChartPanOffset, max(0, chartPanOffset + step))
                    chartDragAppliedX += CGFloat(step) * pointsPerBar
                }
                .onEnded { _ in chartDragAppliedX = 0 })
            supportResistanceRow
        }
    }

    /// 撑压分析：网页版有、此前 App 没有的一块。只描述历史摆动区间，不预测突破。
    @ViewBuilder private var supportResistanceRow: some View {
        if let sr = SupportResistanceCalculator.evaluate(periodBars) {
            VStack(alignment: .leading, spacing: 6) {
                Text("撑压分析").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    srChip("压力", sr.resistances, Color(red: 0.93, green: 0.30, blue: 0.37))
                    srChip("现价", [sr.current], Color.primary)
                    srChip("支撑", sr.supports, Color(red: 0.07, green: 0.77, blue: 0.55))
                    Spacer(minLength: 0)
                }
                Text("由近 160 根日线的摆动高低点推出；只是历史成交区间的描述，不代表未来会止跌或受阻。")
                    .scaledFont(10).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private func srChip(_ title: String, _ values: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(9).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v.num(3)).scaledFont(11, weight: .semibold, design: .rounded)
                    .monospacedDigit().foregroundStyle(color)
            }
            if values.isEmpty { Text("--").scaledFont(11).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var maLegendRow: some View {
        HStack(spacing: 10) {
            maChip("MA5", 5, ma5Color)
            maChip("MA10", 10, ma10Color)
            maChip("MA20", 20, ma20Color)
            maChip("MA60", 60, ma60Color)
            maChip("MA250", 250, ChartPalette.ma250)
            Spacer(minLength: 0)
        }.font(.caption2)
    }

    private func maChip(_ title: String, _ window: Int, _ color: Color) -> some View {
        let on = maVisible.contains(window)
        return Button {
            Haptics.selection()
            if on { maVisible.remove(window) } else { maVisible.insert(window) }
            MAVisibility.write(maVisible)
        } label: {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(on ? color : Color.secondary.opacity(0.3)).frame(width: 12, height: 3)
                Text(title).foregroundStyle(on ? color : Color.secondary)
            }
            .scaledFont(10, weight: .semibold)
            .opacity(on ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)显示开关，当前\(on ? "打开" : "关闭")")
    }

    private func candlePlot(bodyWidth: CGFloat) -> some View {
        // 全量序列与可见窗口都只取一次，五条均线和 Y 轴自适应共用。
        // 全量聚合要按日期字符串逐根分组，若每条线各自去取，捏合时每帧要多跑十次聚合。
        let full = periodAllBars
        let visible = zoomedPeriodBars
        func maSeries(_ window: Int) -> [IndicatorPoint] {
            maVisible.contains(window) ? average(window, source: visible, full: full) : []
        }
        let ma5 = maSeries(5)
        let ma10 = maSeries(10)
        let ma20 = maSeries(20)
        let ma60 = maSeries(60)
        let ma250 = maSeries(250)
        return Chart {
            ForEach(visible) { bar in
                let rising = bar.close >= bar.open
                let candleColor = rising ? Color.red : Color.green
                let lowBody = min(bar.open, bar.close)
                let highBody = max(bar.open, bar.close)
                // 一字线（开=收）时给一个最小高度，否则实体画不出来
                let pad = (highBody - lowBody) < highBody * 0.0008 ? highBody * 0.0008 : 0
                RuleMark(x: .value("日期", bar.date), yStart: .value("最低", bar.low), yEnd: .value("最高", bar.high))
                    .foregroundStyle(candleColor.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: max(1.2, bodyWidth * 0.2)))
                RectangleMark(x: .value("日期", bar.date),
                              yStart: .value("开盘", lowBody),
                              yEnd: .value("收盘", highBody + pad),
                              width: .fixed(bodyWidth))
                    .foregroundStyle(candleColor)
            }
            if selectedChartPeriod == .day {
                ForEach(visibleTradeEntries) { entry in
                    PointMark(x: .value("成交日", shanghaiDay(entry.date)), y: .value("成交价", entry.price))
                        .foregroundStyle(entry.side == .buy ? Color.red : Color.green)
                        .symbolSize(24)
                        .annotation(position: entry.side == .buy ? .bottom : .top, spacing: 2) {
                            Text(entry.side == .buy ? "B" : "S")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(entry.side == .buy ? Color.red : Color.green,
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                }
            }
            if let selected = selectedDailyBar {
                RuleMark(x: .value("选中日期", selected.date))
                    .foregroundStyle(store.effectiveAccentColor.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("选中日期", selected.date), y: .value("收盘", selected.close))
                    .foregroundStyle(store.effectiveAccentColor)
                    .symbolSize(30)
            }
            ForEach(ma5) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA5", point.value), series: .value("均线", "MA5"))
                    .foregroundStyle(ma5Color).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(ma10) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA10", point.value), series: .value("均线", "MA10"))
                    .foregroundStyle(ma10Color).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(ma20) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA20", point.value), series: .value("均线", "MA20"))
                    .foregroundStyle(ma20Color).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(ma60) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA60", point.value), series: .value("均线", "MA60"))
                    .foregroundStyle(ma60Color).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(ma250) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA250", point.value), series: .value("均线", "MA250"))
                    .foregroundStyle(ChartPalette.ma250).lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        // Y 轴显式跟随可见窗口：捏合/拖动后上下界立即重算（含均线），不再是一整段区间
        .chartYScale(domain: yDomain(for: visible, full: full))
        // X 轴按月抽稀：不再逐根显示日期，标签互相压叠又看不清
        .chartXAxis {
            AxisMarks(values: xAxisDates(visible)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let date = value.as(String.self) {
                        Text(xAxisLabel(date, visible))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        let x = value.location.x - frame.origin.x
                        guard x >= 0, x <= frame.width, !visible.isEmpty else { return }
                        let fraction = min(0.999_999, max(0, x / max(1, frame.width)))
                        let index = min(visible.count - 1, Int(fraction * CGFloat(visible.count)))
                        selectedDailyDate = visible[index].date
                        Haptics.selection()
                    })
            }
        }
    }

    private func volumePlot(width: CGFloat) -> some View {
        Chart {
            ForEach(zoomedPeriodBars) { bar in
                BarMark(x: .value("日期", bar.date), y: .value("成交量", bar.volume), width: .fixed(width))
                    .foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func quoteMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var intradayPanel: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 7) {
                Chart {
                    ForEach(selectedIntradayBars) { p in
                        LineMark(x: .value("时间", p.timestamp), y: .value("价格", p.price), series: .value("主图序列", "价格"))
                            .foregroundStyle(intradayLineColor)
                            .lineStyle(StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                    if showIntradayAverage { ForEach(intradayAvgPoints) { p in
                        LineMark(x: .value("时间", p.timestamp), y: .value("均价", p.price), series: .value("主图序列", "均价"))
                            .foregroundStyle(Color.orange)
                            .lineStyle(StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                    } }
                    if showIntradayIOPV { ForEach(selectedDayIOPVPoints) { p in
                        LineMark(x: .value("时间", p.timestamp), y: .value("IOPV", p.value), series: .value("主图序列", "IOPV"))
                            .foregroundStyle(Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round, dash: [3, 2]))
                    } }
                    if showIntradayIOPV, selectedDayIOPVPoints.isEmpty, let v = selectedDayIOPV {
                        RuleMark(y: .value("IOPV", v)).foregroundStyle(.purple).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4,3]))
                    }
                    if showIntradayPreviousClose, let v = intradayPrevClose {
                        RuleMark(y: .value("昨收", v)).foregroundStyle(Color.secondary.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3,3]))
                    }
                }
                .frame(height: 280).chartXScale(domain: intradayXDomain).chartYScale(domain: intradayPriceYDomain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9)) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13)); AxisValueLabel().font(.system(size: 8)).foregroundStyle(.secondary) } }
                if intradaySubchart == .macd {
                    Chart(minuteMACD) { p in
                        BarMark(x: .value("时间", p.time), y: .value("柱", p.histogram))
                            .foregroundStyle(p.histogram >= 0 ? Color.red.opacity(0.82) : Color.green.opacity(0.82))
                            .cornerRadius(1)
                        LineMark(x: .value("时间", p.time), y: .value("DIF", p.dif), series: .value("MACD序列", "DIF")).foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                        LineMark(x: .value("时间", p.time), y: .value("DEA", p.dea), series: .value("MACD序列", "DEA")).foregroundStyle(Color.orange)
                            .lineStyle(StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                        RuleMark(y: .value("零轴", 0)).foregroundStyle(.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3,3]))
                    }.frame(height: 125).chartXScale(domain: intradayXDomain).chartYScale(domain: minuteMACDYDomain).chartXAxis(.hidden)
                } else if hasIntradayVolume {
                    Chart {
                        ForEach(minuteBuckets.indices, id: \.self) { index in
                            let point = minuteBuckets[index]
                            if let volume = point.volume, volume > 0 {
                                BarMark(x: .value("时间", point.start), y: .value("量", volume))
                                    .foregroundStyle(volumeColor(at: index))
                                    .cornerRadius(1)
                            }
                        }
                        ForEach(intradayVolumeMAs.sorted(), id: \.self) { period in
                            ForEach(intradayVolumeMA(period)) { point in
                                LineMark(x: .value("时间", point.time), y: .value("量均线", point.value), series: .value("量均线周期", "MA\(period)"))
                                    .foregroundStyle(intradayVolumeMAColor(period))
                                    .lineStyle(StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                        .frame(height: 125).chartXScale(domain: intradayXDomain).chartXAxis(.hidden)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("暂无可用分时量")
                            .scaledFont(11, weight: .semibold)
                        Text("行情源尚未返回成交量；完整分钟线到达后会自动补上。")
                            .scaledFont(9).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 125)
                }
            }
            VStack(spacing: 7) {
                Text("主图").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Capsule().fill(intradayLineColor).frame(width: 10, height: 2)
                    Text("价格").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                rail("均价", showIntradayAverage, .orange) { showIntradayAverage.toggle(); IntradayVisibility.write(average: showIntradayAverage) }
                rail("IOPV", showIntradayIOPV, .purple) { showIntradayIOPV.toggle(); IntradayVisibility.write(iopv: showIntradayIOPV) }
                rail("昨收", showIntradayPreviousClose, .gray) { showIntradayPreviousClose.toggle(); IntradayVisibility.write(previousClose: showIntradayPreviousClose) }
                Divider(); Text("副图").font(.caption2).foregroundStyle(.secondary)
                rail("MACD", intradaySubchart == .macd, .blue) { intradaySubchart = .macd }
                rail("分时量", intradaySubchart == .volume, .orange) { intradaySubchart = .volume }
                if intradaySubchart == .volume {
                    Text("量均线").font(.system(size: 8)).foregroundStyle(.secondary)
                    intradayVolumeMAButton(20)
                    intradayVolumeMAButton(60)
                    intradayVolumeMAButton(250)
                    HStack(spacing: 3) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                    Text("涨 / 跌").font(.system(size: 8)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 2) {
                        Capsule().fill(.blue).frame(width: 7, height: 2)
                        Capsule().fill(.orange).frame(width: 7, height: 2)
                    }
                    Text("DIF / DEA").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
            }.frame(width: 76)
        }.padding(8).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    private func rail(_ title: String, _ on: Bool, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(on ? Color.white : Color.secondary).background(on ? color : Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain)
    }
    private func intradayLayerButton(_ title: String, isOn: Bool, color: Color,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(isOn ? color : Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
                Text(title).scaledFont(11, weight: .semibold)
            }
            .foregroundStyle(isOn ? color : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((isOn ? color : Color.secondary).opacity(isOn ? 0.13 : 0.07), in: Capsule())
            .overlay { Capsule().strokeBorder((isOn ? color : Color.secondary).opacity(0.22), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)叠加层，当前\(isOn ? "显示" : "隐藏")")
    }
    private func intradayVolumeMAButton(_ period: Int) -> some View {
        let available = minuteBuckets.compactMap(\.volume).count >= period
        let isOn = intradayVolumeMAs.contains(period)
        let color = intradayVolumeMAColor(period)
        return Button {
            if isOn { intradayVolumeMAs.remove(period) } else { intradayVolumeMAs.insert(period) }
            IntradayVisibility.write(volumeMAs: intradayVolumeMAs)
        } label: {
            Text("MA\(period)").scaledFont(10, weight: .semibold)
                .foregroundStyle(isOn ? color : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background((isOn ? color : Color.secondary).opacity(isOn ? 0.13 : 0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.38)
    }
    private func intradayVolumeMAColor(_ period: Int) -> Color {
        switch period {
        case 20: return ChartPalette.ma20
        case 60: return ChartPalette.ma60
        default: return ChartPalette.ma250
        }
    }
    private var zoomedPeriodBars: [DailyBar] {
        let source = periodAllBars
        guard !source.isEmpty else { return [] }
        let safeOffset = min(chartPanOffset, max(0, source.count - zoomedBarCount))
        let end = max(zoomedBarCount, source.count - safeOffset)
        let start = max(0, end - zoomedBarCount)
        return Array(source[start..<end])
    }

    @MainActor private func fetchTencentMinute() async {
        guard !isFetchingMinute, !isManuallyRefreshingMinute else { return }
        isFetchingMinute = true
        defer { isFetchingMinute = false }
        let today = shanghaiDay(.now)
        // 休市 / 非交易时段**不提前返回**：腾讯的分时接口在这两种情况下仍会返回
        // 最近一个交易日的完整分时（实测周末请求 sh000001 能拿到上一交易日 242 个点），
        // 直接画出来比留一张空图有用得多。状态文案在拿到数据后按实际日期写
        // —— 见末尾「休市 · 最近交易日 xx-xx」那一行。
        // 指数代码自带市场前缀（sh000001 / usIXIC），个股 / ETF 才是 6 位纯数字。
        let symbol: String
        if holding.code.allSatisfy(\.isNumber) {
            let shanghaiPrefixes = ["6", "9", "5", "11", "50", "51", "56", "58"]
            let exchange = shanghaiPrefixes.contains(where: { holding.code.hasPrefix($0) }) ? "sh" : "sz"
            symbol = exchange + holding.code
        } else {
            symbol = holding.code
        }
        do {
            var data: Data?
            var sourceBars: [IntradayBar] = []
            // 双主机直连（web.ifzq → ifzq，与指数 / 后台补全同一套主机顺序），任一主机成功即用；
            // 全部直连失败再走 NAS 行情代理兜底；仍失败则抛给外层 catch 统一设置失败文案。
            // 修掉旧代码只用裸 ifzq 单主机导致“某些网络下指数能取、ETF 却空白”的问题。
            for host in ["web.ifzq.gtimg.cn", "ifzq.gtimg.cn"] {
                let variable = "min_data_\(Int(Date().timeIntervalSince1970 * 1000))"
                guard let url = URL(string: "https://\(host)/appstock/app/minute/query?_var=\(variable)&code=\(symbol)") else { continue }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                guard let (candidate, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let parsed = store.parseTencentMinuteData(candidate, symbol: symbol)
                guard !parsed.isEmpty else { continue }
                data = candidate
                sourceBars = parsed
                break
            }
            if sourceBars.isEmpty,
               let proxied = try? await NASSyncService.marketProxyData(path: "minute", queryItems: [URLQueryItem(name: "code", value: symbol)]) {
                let parsed = store.parseTencentMinuteData(proxied, symbol: symbol)
                if !parsed.isEmpty {
                    data = proxied
                    sourceBars = parsed
                }
            }
            guard let data, !sourceBars.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
            // 公共解析器按腾讯 symbol 回填 code；这里改回持仓代码，方便本机历史筛选。
            let parsed = sourceBars.map {
                IntradayBar(code: holding.code, timestamp: $0.timestamp, price: $0.price,
                            volume: $0.volume, day: $0.day)
            }
            let day = parsed.last?.day ?? today
            var root: [String: Any]?
            if let raw = String(data: data, encoding: .utf8),
               let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
               let decoded = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] {
                root = decoded
            }
            // 腾讯分时响应另含 ETF 汇总行情 qt；折溢价率字段为百分数。
            // 仅在品种确认为 ETF 且数值有效时计算 IOPV，缺字段不以昨收净值代替。
            let quoteValues = (root?["qt"] as? [String: Any]).flatMap { qt in
                (qt[symbol] ?? qt.first(where: { $0.key.caseInsensitiveCompare(symbol) == .orderedSame })?.value) as? [Any]
            }
            if let values = quoteValues,
               values.count > 44, (values[61] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ETF" {
                func field(_ index: Int) -> Double? {
                    guard values.indices.contains(index) else { return nil }
                    if let text = values[index] as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    return (values[index] as? NSNumber)?.doubleValue
                }
                let amountInTenThousands = field(37)
                intradayETFQuoteSummary = IntradayETFQuoteSummary(
                    turnoverPercent: field(38), amplitudePercent: field(43),
                    amountYi: amountInTenThousands.map { $0 / 10_000 }, marketCapYi: field(44))
                intradayETFQuoteSummaryDay = day
                // 折溢价率取扩展字段 77（百分数），基金份额参考净值 IOPV 取字段 78。
                // 旧版取字段 63 —— 那是别的指标：广发纳指ETF 会被算成 4.12%，
                // 而交易所公布的折溢价率是 14.01%，差了三倍多。
                // IOPV 直接用字段 78，比「现价 /(1 + 溢价率)」反推更准。
                let lastPrice = parsed.last?.price
                if let premium = field(77), premium.isFinite, (-50...50).contains(premium) {
                    var resolvedIOPV = field(78).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    if resolvedIOPV == nil, let last = lastPrice, last.isFinite, last > 0, (1 + premium / 100) > 0 {
                        let derived = last / (1 + premium / 100)
                        resolvedIOPV = derived.isFinite && derived > 0 ? derived : nil
                    }
                    if let iopv = resolvedIOPV {
                        intradayIOPV = iopv
                        intradayPremiumPercent = premium
                        if let time = parsed.last?.timestamp {
                            let currentDay = parsed.last?.day ?? day
                            if intradayIOPVDay != currentDay { intradayIOPVPoints = [] }
                            intradayIOPVDay = currentDay
                            intradayIOPVPoints.removeAll { Calendar.current.isDate($0.timestamp, equalTo: time, toGranularity: .minute) }
                            intradayIOPVPoints.append(IntradayIOPVPoint(timestamp: time, value: iopv))
                            if intradayIOPVPoints.count > 400 { intradayIOPVPoints.removeFirst(intradayIOPVPoints.count - 400) }
                        }
                    }
                }
            }
            store.mergeIntradayBars(parsed)
            selectedIntradayDay = day
            minuteStatus = day == today ? "更新于 \(Date.now.formatted(date: .omitted, time: .shortened))" : "休市 · 最近交易日 \(day)"
        } catch {
            minuteStatus = selectedIntradayBars.isEmpty
                ? "分时获取失败：\(error.localizedDescription)"
                : "更新失败，继续显示本机已保存的 \(selectedIntradayDay) 分时"
        }
    }

    @MainActor private func load(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true; message = ""
        defer { isLoading = false }
        do { _ = try await store.fetchDailyBars(code: holding.code, count: 640, force: force); message = "已载入 \(store.dailyBars[holding.code]?.count ?? 0) 个交易日" }
        catch { message = "获取失败：\(error.localizedDescription)" }
    }

    private func runBacktest() {
        guard let capital = Double(backtestCapital), let feePercent = Double(backtestFeePercent),
              let result = StrategyBacktest.run(bars: bars, initialCash: capital, feeRate: feePercent / 100) else {
            backtestResult = nil
            backtestMessage = "当前日线不足或参数无效；至少需要 25 个交易日，费率需为 0%–2%。"
            return
        }
        backtestResult = result; backtestMessage = ""
    }

    private func shanghaiDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor private func analyzeInstrument() async {
        guard !instrumentAIBusy else { return }
        instrumentAIBusy = true
        instrumentAIMessage = ""
        defer { instrumentAIBusy = false }
        let quote = store.data.quotes.first(where: { $0.code == holding.code })
        let actualHolding = store.data.holdings.first(where: { $0.code == holding.code && $0.kind == .etf }) ?? holding
        do {
            let result = try await AIAnalysisService.analyzeInstrument(
                config: store.data.aiAnalysisConfig, holding: actualHolding, quote: quote, bars: allBars,
                intradayBars: selectedIntradayBars, priceLevels: priceLevelsPromptText,
                profile: store.data.investmentProfile, totalAsset: store.totalAsset)
            instrumentAIResult = result
            store.data.savedInstrumentAIAnalyses[holding.code] = SavedAIAnalysis(text: result)
            store.saveAIAnalysisCache()
            // 只有新结果成功返回后，上一轮建议的处理状态才作废。
            handledSuggestionIDs.removeAll()
            suggestionNote = ""
        } catch {
            instrumentAIMessage = "分析失败：\(error.localizedDescription)\(instrumentAIResult.isEmpty ? "" : "；已保留上次成功结果。")"
        }
    }

    // MARK: - AI 可执行建议 → 计划 / 提醒

    private var instrumentAISuggestions: [AISuggestion] {
        AISuggestionParser.parse(instrumentAIResult)
    }

    /// 单条建议的展示与两个落地动作。与组合分析页同一套口径（买=红、卖=绿）。
    private func instrumentSuggestionRow(_ suggestion: AISuggestion) -> some View {
        let tone: Color = suggestion.side == .buy ? PnLColor.up : PnLColor.down
        let handled = handledSuggestionIDs.contains(suggestion.id)
        let light = AppTheme.palette(for: store.resolvedAppearance).isLight
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(suggestion.side.label)
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tone.opacity(light ? 0.14 : 0.24), in: Capsule())
                Text(suggestion.displayName)
                    .scaledFont(14, weight: .semibold)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if handled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CardTone.ok)
                        .accessibilityLabel("已处理")
                }
            }
            if let price = suggestion.price {
                Text("参考价 \(price.num(3))").scaledFont(12).monospacedDigit().foregroundStyle(.secondary)
            }
            if !suggestion.reason.isEmpty { Text(suggestion.reason).font(.footnote) }
            HStack(spacing: 10) {
                Button("存入计划记录") {
                    Haptics.tap()
                    planPrefill = suggestion
                }
                .buttonStyle(.bordered)
                .disabled(handled)
                Button("设为价格提醒") { createInstrumentAlert(from: suggestion) }
                    .buttonStyle(.bordered)
                    // 场外基金不走实时行情，提醒永远不会触发 —— 与其建一条哑的，不如不给按。
                    .disabled(handled || suggestion.price == nil || holding.kind == .fund)
            }
            .font(.caption)
            if holding.kind == .fund {
                Text("场外基金按净值成交，没有实时价格提醒；可以转成计划记录，到净值公布后自己核对。")
                    .scaledFont(11).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// 个股页提醒：买入等回落到参考价（below），卖出等涨到参考价（above）。
    /// 这里只用「参考价」而不用目标价/失效价 —— 单标的页给出的第一个价位就是它建议的动手点。
    private func createInstrumentAlert(from suggestion: AISuggestion) {
        guard let target = suggestion.price else { return }
        let direction: QuoteAlert.Direction = suggestion.side == .buy ? .below : .above
        do {
            try store.addQuoteAlert(code: suggestion.code,
                                    name: suggestion.displayName,
                                    target: target,
                                    direction: direction)
            handledSuggestionIDs.insert(suggestion.id)
            suggestionNote = "已添加价格提醒：\(suggestion.displayName) \(direction == .below ? "跌到" : "涨到") \(target.num(3)) 时通知（一次性，触发后需手动重启）。"
        } catch {
            suggestionNote = error.localizedDescription
        }
    }
}

// MARK: - 横屏大图

/// 均线配色单一数据源。竖屏日K、横屏大图都从这里取，避免两处配色漂移。
private enum ChartPalette {
    static let ma5 = Color(red: 1.0, green: 0.62, blue: 0.11)    // 橙
    static let ma10 = Color(red: 0.30, green: 0.66, blue: 1.0)   // 蓝
    static let ma20 = Color(red: 0.80, green: 0.36, blue: 1.0)   // 紫
    static let ma60 = Color(red: 0.16, green: 0.88, blue: 0.76)  // 青绿
    static let ma250 = Color(red: 0.96, green: 0.35, blue: 0.58) // 玫红
}

/// K 线实体与量柱的宽度口径（竖屏日K、横屏大图共用）。
///
/// **量柱为什么必须比 K 线实体窄**：两处原先共用一个 `bodyWidth`，量柱和实体一样宽。
/// 缩到 120 根以上时每根只有几 pt，相邻两根的边正好贴在一起 ——
/// 视觉上连成一条实心色带，看不出「一根根柱子」，用户说的「量柱太粗、不清晰」就是这个。
/// 量柱取实体的 62%，两侧留出间隙，根与根之间才分得开。
/// 下限同时放小（1.4 而不是 2.2）：细到 6 根一根也仍能看见，但不会糊成一片。
enum ChartBarWidth {
    /// K 线实体宽度。
    static func candle(slot: CGFloat) -> CGFloat {
        min(max(slot * 0.74, 2.2), 30)
    }

    /// 量柱宽度。比实体窄一档，保证相邻柱子之间始终有缝。
    static func volume(slot: CGFloat) -> CGFloat {
        min(max(slot * 0.46, 1.4), 18)
    }
}

/// 横屏 K 线大图。
///
/// 为什么单独写一个视图而不是复用 MarketChartView：
/// 后者是塞了分时 / 副图 / 回测 / AI 的长 List，横屏下上半屏是列表、下半屏才是图，
/// 图反而更小。这里只保留日K + 四条均线 + 成交量，横向铺满整屏，
/// 并在 onAppear/onDisappear 里锁 / 解锁横屏。
struct LandscapeChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var showVolume = true
    /// 与竖屏共用同一份开关状态（UserDefaults）
    @State private var maVisible: Set<Int> = MAVisibility.read()

    private var allBars: [DailyBar] { store.dailyBars[holding.code] ?? [] }

    /// 缩放后实际显示的 K 线根数。下限 20 根：再少就没有形态可言了。
    private var visibleBars: [DailyBar] {
        guard !allBars.isEmpty else { return [] }
        let target = Int((CGFloat(allBars.count) / (zoom * pinch)).rounded())
        return Array(allBars.suffix(min(max(target, 20), allBars.count)))
    }

    /// 与主视图同口径：Y 轴显式跟随可见窗口（含均线），放大缩小都实时重算。
    /// 横屏只有日K，`allBars` 就是字典取值、没有聚合开销，所以直接在这里取全量。
    private func yDomain(for bars: [DailyBar]) -> ClosedRange<Double> {
        guard !bars.isEmpty else { return 0...1 }
        var low = bars.map(\.low).min() ?? 0
        var high = bars.map(\.high).max() ?? 1
        let visibleWindows = [5, 10, 20, 60, 250].filter { maVisible.contains($0) }
        for window in visibleWindows {
            let source = average(window, source: bars, full: allBars)
            for point in source {
                low = min(low, point.value)
                high = max(high, point.value)
            }
        }
        guard high > low else {
            let base = max(high, 0.0001)
            return (base * 0.999)...(base * 1.001)
        }
        let padding = (high - low) * 0.06
        return (low - padding)...(high + padding)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                if visibleBars.isEmpty {
                    Spacer(minLength: 0)
                    Text("还没有日线数据，先在主界面打开一次行情")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    candleChart(height: geo.size.height * (showVolume ? 0.74 : 0.92))
                    if showVolume {
                        volumeChart(height: geo.size.height * 0.16)
                    }
                }
            }
        }
        .background(.clear)
        .themedSheetBackground()
        .onAppear { OrientationLock.shared.lockLandscape() }
        .onDisappear { OrientationLock.shared.unlock() }
    }

    private var topBar: some View {
        let quote = store.data.quotes.first(where: { $0.code == holding.code })
        return HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭横屏图表")
            VStack(alignment: .leading, spacing: 1) {
                Text(holding.name.isEmpty ? holding.code : holding.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("日K · \(visibleBars.count) 根")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text((quote?.price ?? holding.current).num(3))
                .font(.system(.headline, design: .rounded)).monospacedDigit()
            if let quote {
                Text((quote.changePct * 100).pct(2))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(quote.changePct >= 0 ? .red : .green)
            }
            Spacer(minLength: 0)
            maChip("MA5", 5, ChartPalette.ma5)
            maChip("MA10", 10, ChartPalette.ma10)
            maChip("MA20", 20, ChartPalette.ma20)
            maChip("MA60", 60, ChartPalette.ma60)
            maChip("MA250", 250, ChartPalette.ma250)
            Button { showVolume.toggle() } label: {
                Image(systemName: showVolume ? "chart.bar.fill" : "chart.bar").font(.caption)
            }.buttonStyle(.bordered)
                .accessibilityLabel(showVolume ? "隐藏成交量" : "显示成交量")
            Button("复位") { zoom = 1 }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func maChip(_ title: String, _ window: Int, _ color: Color) -> some View {
        let on = maVisible.contains(window)
        return Button {
            Haptics.selection()
            if on { maVisible.remove(window) } else { maVisible.insert(window) }
            MAVisibility.write(maVisible)
        } label: {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(on ? color : Color.secondary.opacity(0.3)).frame(width: 10, height: 3)
                Text(title).scaledFont(9, weight: .semibold).foregroundStyle(on ? color : Color.secondary)
            }.opacity(on ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)显示开关，当前\(on ? "打开" : "关闭")")
    }

    private func candleChart(height: CGFloat) -> some View {
        GeometryReader { geo in
            let bars = visibleBars
            let count = max(bars.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let bodyWidth = ChartBarWidth.candle(slot: slot)
            Chart {
                ForEach(bars) { bar in
                    let rising = bar.close >= bar.open
                    let candleColor = rising ? Color.red : Color.green
                    let lowBody = min(bar.open, bar.close)
                    let highBody = max(bar.open, bar.close)
                    // 一字线（开=收）时给最小高度，否则实体画不出来
                    let pad = (highBody - lowBody) < highBody * 0.0008 ? highBody * 0.0008 : 0
                    RuleMark(x: .value("日期", bar.date), yStart: .value("最低", bar.low), yEnd: .value("最高", bar.high))
                        .foregroundStyle(candleColor.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: max(1.2, bodyWidth * 0.2)))
                    RectangleMark(x: .value("日期", bar.date),
                                  yStart: .value("开盘", lowBody),
                                  yEnd: .value("收盘", highBody + pad),
                                  width: .fixed(bodyWidth))
                        .foregroundStyle(candleColor)
                }
                if maVisible.contains(5) {
                    ForEach(average(5, source: bars, full: allBars)) { point in
                        LineMark(x: .value("日期", point.date), y: .value("MA5", point.value), series: .value("均线", "MA5"))
                            .foregroundStyle(ChartPalette.ma5).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                if maVisible.contains(10) {
                    ForEach(average(10, source: bars, full: allBars)) { point in
                        LineMark(x: .value("日期", point.date), y: .value("MA10", point.value), series: .value("均线", "MA10"))
                            .foregroundStyle(ChartPalette.ma10).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                if maVisible.contains(20) {
                    ForEach(average(20, source: bars, full: allBars)) { point in
                        LineMark(x: .value("日期", point.date), y: .value("MA20", point.value), series: .value("均线", "MA20"))
                            .foregroundStyle(ChartPalette.ma20).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                if maVisible.contains(60) {
                    ForEach(average(60, source: bars, full: allBars)) { point in
                        LineMark(x: .value("日期", point.date), y: .value("MA60", point.value), series: .value("均线", "MA60"))
                            .foregroundStyle(ChartPalette.ma60).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                if maVisible.contains(250) {
                    ForEach(average(250, source: bars, full: allBars)) { point in
                        LineMark(x: .value("日期", point.date), y: .value("MA250", point.value), series: .value("均线", "MA250"))
                            .foregroundStyle(ChartPalette.ma250).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
            }
            // 横屏同样显式跟随可见窗口
            .chartYScale(domain: yDomain(for: bars))
            .chartXAxis {
                AxisMarks(values: xAxisDates(bars)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                    AxisValueLabel {
                        if let date = value.as(String.self) {
                            Text(xAxisLabel(date, bars))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.10))
                    AxisValueLabel().font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .gesture(magnifyGesture)
        }
        .frame(height: height)
        .clipped()
    }

    private func volumeChart(height: CGFloat) -> some View {
        GeometryReader { geo in
            let count = max(visibleBars.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let barWidth = ChartBarWidth.volume(slot: slot)
            Chart {
                ForEach(visibleBars) { bar in
                    BarMark(x: .value("日期", bar.date), y: .value("成交量", bar.volume), width: .fixed(barWidth))
                        .foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: height)
        .clipped()
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = min(max(zoom * value, 1), 12) }
    }

    /// 横屏大图的均线。横屏只有日K，所以「全量序列」就是 `allBars`，
    /// 口径与竖屏 `MarketChartView` 的那一份完全一致（详见那边的注释）。
    private func average(_ window: Int, source: [DailyBar], full: [DailyBar]) -> [IndicatorPoint] {
        guard window > 0, full.count >= window, !source.isEmpty else { return [] }
        let visibleDates = Set(source.map(\.date))
        guard !visibleDates.isEmpty else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity(visibleDates.count)
        for index in (window - 1)..<full.count where visibleDates.contains(full[index].date) {
            let values = full[(index - window + 1)...index].map(\.close)
            out.append(IndicatorPoint(date: full[index].date, value: values.reduce(0, +) / Double(window)))
        }
        return out
    }
}
