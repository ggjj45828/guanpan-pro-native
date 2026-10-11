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
    let spansMultipleYears = bars.count > 1 && String(bars.first!.date.prefix(4)) != String(bars.last!.date.prefix(4))
    guard spansMultipleYears else { return "\(month)月" }
    return "\(String(date.prefix(4)).suffix(2))/\(month)"
}

struct MarketChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let holding: Holding
    @State private var selectedIntradayDay = ""
    @State private var selectedChartPeriod: NativeChartPeriod = .intraday
    /// 每条均线可单独开关：点图例 chip 切换，状态持久化到 UserDefaults
    @State private var maVisible: Set<Int> = MAVisibility.read()
    @State private var intradaySubchart: IntradaySubchart = .macd
    @State private var showInstrumentAI = false
    @State private var instrumentAIResult = ""
    @State private var instrumentAIMessage = ""
    @State private var instrumentAIBusy = false
    @State private var isLoading = false
    @State private var showLandscapeChart = false
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

    private var allBars: [DailyBar] { store.dailyBars[holding.code] ?? [] }
    private var range: Int { store.data.dailyChartRangeDays }
    private var bars: [DailyBar] { Array(allBars.suffix(range)) }
    /// 当前周期、只取用户选的显示区间（横坐标就画这么多根）。
    private var periodBars: [DailyBar] { aggregated(bars) }
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
    private var intradayLineColor: Color {
        switch store.data.intradayLineColorMode {
        case .automatic: return .accentColor
        case .white: return .white
        case .black: return .black
        case .upDown:
            guard let first = selectedIntradayBars.first, let last = selectedIntradayBars.last else { return .accentColor }
            return last.price >= first.price ? .red : .green
        }
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
    private var technicalSignal: (score: Int, label: String, notes: [String])? {
        guard bars.count >= 20, let latest else { return nil }
        let closes = bars.map(\.close)
        func ma(_ count: Int, endingAt index: Int) -> Double? {
            guard index + 1 >= count else { return nil }
            return closes[(index + 1 - count)...index].reduce(0, +) / Double(count)
        }
        guard let ma5 = ma(5, endingAt: bars.count - 1), let ma10 = ma(10, endingAt: bars.count - 1),
              let ma20 = ma(20, endingAt: bars.count - 1) else { return nil }
        let ma60 = ma(60, endingAt: bars.count - 1)
        var rawScore = 0
        var notes: [String] = []
        if let ma60, ma5 > ma10 && ma10 > ma20 && ma20 > ma60 {
            rawScore += 3; notes.append("MA5/10/20/60 多头排列")
        } else if let ma60, ma5 < ma10 && ma10 < ma20 && ma20 < ma60 {
            rawScore -= 3; notes.append("MA5/10/20/60 空头排列")
        } else { notes.append("短中期均线未形成一致排列") }
        if latest.close >= ma20 { rawScore += 2; notes.append("收盘在 MA20 上方") }
        else { rawScore -= 2; notes.append("收盘在 MA20 下方") }
        if let macd {
            if macd.histogram > 0 && macd.line > 0 { rawScore += 2; notes.append("MACD 位于零轴上方且柱值为正") }
            else if macd.histogram < 0 && macd.line < 0 { rawScore -= 2; notes.append("MACD 位于零轴下方且柱值为负") }
        }
        if let rsi14 {
            if rsi14 < 30 { rawScore += 1; notes.append("RSI14 低于 30") }
            else if rsi14 > 70 { rawScore -= 1; notes.append("RSI14 高于 70") }
        }
        if bars.count >= 21 {
            let prior = bars[bars.count - 2]
            let change = prior.close > 0 ? latest.close / prior.close - 1 : 0
            let avgVolume = bars.suffix(21).dropLast().map(\.volume).reduce(0, +) / 20
            if avgVolume > 0 && latest.volume >= avgVolume * 1.8 {
                rawScore += change >= 0 ? 2 : -2
                notes.append("当日成交量达到前 20 日均量 1.8 倍")
            }
        }
        let score = max(-100, min(100, Int((Double(rawScore) * 4.5).rounded())))
        let label = score >= 40 ? "强势偏多" : score >= 15 ? "偏多" : score <= -40 ? "弱势偏空" : score <= -15 ? "偏空" : "中性震荡"
        return (score, label, notes)
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
                    Picker("区间", selection: Binding(get: { store.data.dailyChartRangeDays }, set: { store.data.dailyChartRangeDays = $0; store.save(label: "修改图表区间") })) {
                        Text("60日").tag(60); Text("120日").tag(120); Text("250日").tag(250); Text("640日").tag(640)
                    }.pickerStyle(.segmented)
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
                            Chart(selectedIntradayBars) { point in
                                LineMark(x: .value("时间", point.timestamp), y: .value("价格", point.price))
                                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black).interpolationMethod(.linear)
                                    .lineStyle(StrokeStyle(lineWidth: 1.25))
                                // 均价线：累计成交额 / 累计成交量
                                ForEach(intradayAvgPoints) { avg in
                                    LineMark(x: .value("时间", avg.timestamp), y: .value("均价", avg.price))
                                        .foregroundStyle(Color.orange)
                                        .lineStyle(StrokeStyle(lineWidth: 1.1))
                                }
                                ForEach(selectedDayIOPVPoints) { point in
                                    LineMark(x: .value("时间", point.timestamp), y: .value("IOPV", point.value))
                                        .foregroundStyle(Color.purple)
                                        .lineStyle(StrokeStyle(lineWidth: 1.1))
                                }
                                // 昨收基准虚线，一眼看出现在相对昨天是红是绿
                                if let prev = intradayPrevClose {
                                    RuleMark(y: .value("昨收", prev))
                                        .foregroundStyle(Color.secondary.opacity(0.55))
                                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                            }
                            .frame(height: 320)
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                            Picker("分时副图", selection: $intradaySubchart) {
                                ForEach(IntradaySubchart.allCases) { item in Text(item.rawValue).tag(item) }
                            }.pickerStyle(.segmented)
                            if intradaySubchart == .macd {
                                Chart(minuteMACD) { point in
                                    BarMark(x: .value("时间", point.time), y: .value("MACD柱", point.histogram))
                                        .foregroundStyle(point.histogram >= 0 ? Color.red : Color.green)
                                    LineMark(x: .value("时间", point.time), y: .value("DIF", point.dif)).foregroundStyle(Color.cyan)
                                    LineMark(x: .value("时间", point.time), y: .value("DEA", point.dea)).foregroundStyle(Color.orange)
                                }.frame(height: 120).chartXAxis(.hidden)
                            } else if minuteBuckets.contains(where: { $0.volume != nil }) {
                                Chart(minuteBuckets.filter { $0.volume != nil }) { point in
                                    BarMark(x: .value("时间", point.start), y: .value("成交量", point.volume ?? 0))
                                        .foregroundStyle(Color.cyan)
                                }.frame(height: 120).chartXAxis(.hidden)
                            }
                            Text("腾讯当日分时 · 前台约 15 秒刷新 · \(minuteStatus)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView("暂无当日分时", systemImage: "chart.xyaxis.line", description: Text(minuteStatus))
                        }
                        Button { Task { await fetchTencentMinute() } } label: { Label("刷新分时", systemImage: "arrow.clockwise") }
                    } else if selectedChartPeriod == .minute30 || selectedChartPeriod == .minute60 {
                        if minuteBuckets.count > 1 {
                            Chart(minuteBuckets) { point in
                                LineMark(x: .value("时间", point.start), y: .value("价格", point.close))
                                    .foregroundStyle(intradayLineColor)
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
                                    LineMark(x: .value("时间", point.time), y: .value("DIF", point.dif))
                                        .foregroundStyle(Color.cyan)
                                    LineMark(x: .value("时间", point.time), y: .value("DEA", point.dea))
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
                    Button { Task { await load(force: true) } } label: {
                        Label(isLoading ? "正在更新…" : "更新历史日线", systemImage: "arrow.clockwise")
                    }.disabled(isLoading)
                    Text("数据：腾讯前复权日线。MA5/20/60、RSI14、MACD、区间分位与最大回撤由本机计算，仅作历史描述，不是价格预测或估值。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { showInstrumentAI = true } label: {
                        Label("AI 分析此标的", systemImage: "sparkles")
                    }.disabled(!AIAnalysisService.hasSavedAPIKey)
                    if !AIAnalysisService.hasSavedAPIKey { Text("先在 AI 页面保存接口和 API 密钥；单标的分析会把该标的行情、持仓、历史日线、历史支撑压力参考及所选交易日已有分时点发送给模型。")
                        .font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("\(holding.name) · \(holding.code)") }
                Section("历史分时") {
                    if intradayDays.isEmpty {
                        ContentUnavailableView("暂无本机分时记录", systemImage: "chart.xyaxis.line", description: Text("行情刷新采集到的数据或导入的分时 CSV 会保存在本机；没有记录的日期不会补造走势。"))
                    } else {
                        Picker("交易日", selection: $selectedIntradayDay) {
                            ForEach(intradayDays, id: \.self) { day in Text(day).tag(day) }
                        }
                        if selectedIntradayBars.count > 1 {
                            Chart {
                                ForEach(selectedIntradayBars) { point in
                                    LineMark(x: .value("时间", point.timestamp), y: .value("价格", point.price))
                                        .foregroundStyle(intradayLineColor)
                                        .interpolationMethod(.linear)
                                }
                            }
                            .frame(height: 190)
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                    AxisValueLabel(format: .dateTime.hour().minute())
                                }
                            }
                            if let first = selectedIntradayBars.first, let last = selectedIntradayBars.last {
                                Text("\(selectedIntradayBars.count) 点 · \(first.timestamp.formatted(date: .omitted, time: .shortened)) 至 \(last.timestamp.formatted(date: .omitted, time: .shortened)) · 仅本机采集/导入数据")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("所选交易日记录不足两个点，无法绘制分时线。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let latest {
                    Section("技术信号（本机指标子集）") {
                        if let signal = technicalSignal {
                            LabeledContent("综合分", value: "\(signal.score) · \(signal.label)")
                            ForEach(signal.notes, id: \.self) { Text("• \($0)").font(.footnote) }
                        } else {
                            Text("至少需要 20 个交易日，才能计算技术信号。")
                        }
                        Text("这是 MA、MACD、RSI 和成交量条件的规则统计，不复刻网页完整算法，也不构成买卖建议。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("历史指标") {
                        LabeledContent("最新收盘（\(latest.date)）", value: (latest.close).num(3))
                        if let ma20 = average(20).last?.value { LabeledContent("MA20", value: (ma20).num(3)) }
                        if let ma60 = average(60).last?.value { LabeledContent("MA60", value: (ma60).num(3)) }
                        if let rsi14 { LabeledContent("RSI14", value: "\((rsi14).num(1))") }
                        if let macd {
                            LabeledContent("MACD", value: "\((macd.line).num(4))")
                            LabeledContent("信号线 / 柱", value: "\((macd.signal).num(4)) / \((macd.histogram).num(4))")
                        }
                        if let percentile { LabeledContent("区间收盘分位", value: "\((percentile).num(1))%") }
                        if let drawdown { LabeledContent("区间最大回撤", value: "\((drawdown * 100).num(1))%") }
                    }
                }
                Section("日线规则提示") {
                    if ruleAlerts.isEmpty {
                        Label("所选区间内未触发内置规则", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        ForEach(ruleAlerts, id: \.self) { rule in
                            Label(rule, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Text("规则检查 MA20 穿越、单日 ±5%、区间回撤 10%、量能 2 倍且单日波动 3%。仅检查当前加载的日线，不是实时监控，也不会自动发通知或预测涨跌。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("MA5 / MA20 历史策略回测") {
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
                }
                Section("最近日线") {
                    ForEach(bars.suffix(20).reversed()) { bar in
                        HStack { Text(bar.date); Spacer(); Text("收 \((bar.close).num(3))"); Text("高低 \((bar.high).num(3)) / \((bar.low).num(3))").foregroundStyle(.secondary) }.font(.caption)
                    }
                }
                Section("支撑压力与中期区间") {
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
                }
            }
            .navigationTitle("日K与指标")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .background(.clear)
            .presentationBackground(.clear)
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
            .sheet(isPresented: $showInstrumentAI) {
                NavigationStack {
                    List {
                        if instrumentAIBusy { ProgressView("正在分析此标的…") }
                        if !instrumentAIMessage.isEmpty { Text(instrumentAIMessage).foregroundStyle(.secondary) }
                        if !instrumentAIResult.isEmpty { Text(instrumentAIResult).textSelection(.enabled) }
                        Text("只依据本机现有行情、日线/支撑压力参考和所选交易日已有分时点生成分析；缺少的数据不会补造。模型输出可能有误，不构成买卖指令。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .navigationTitle("\(holding.name) · AI 分析")
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .presentationBackground(.clear)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { showInstrumentAI = false } } }
                    .task { await analyzeInstrument() }
                }
            }
            .onAppear {
                if selectedIntradayDay.isEmpty { selectedIntradayDay = intradayDays.first ?? "" }
                intradaySubchart = store.data.intradaySubchartMode == "volume" ? .volume : .macd
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

    private var zoomedBarCount: Int {
        min(periodBars.count, max(6, Int(Double(periodBars.count) / (chartZoom * pinchScale))))
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


    @ViewBuilder private var dailyChartSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
            Text("捏合缩放 · 左右拖动看历史")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            // 可见窗口的最高/最低：捏合、拖动时实时跟着变，不再是整个区间的固定值
            Text(windowHighLowText(zoomedPeriodBars))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("重置") { chartZoom = 1; chartPanOffset = 0 }.font(.caption)
        }
            maLegendRow
            // GeometryReader 拿到实际绘图宽度，据此算出随缩放变化的实体宽度。
            // 之前实体固定 5pt，放大后柱子不变粗、间距却变大，看起来既稀疏又糊。
            GeometryReader { geo in
                let slot = max(60, geo.size.width) / CGFloat(max(1, zoomedPeriodBars.count))
                let bodyWidth = min(max(slot * 0.74, 2.2), 30)
                VStack(spacing: 8) {
                    candlePlot(bodyWidth: bodyWidth).frame(height: candleHeight)
                    volumePlot(bodyWidth: bodyWidth).frame(height: volumeHeight)
                }
            }
            .frame(height: chartBodyHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(MagnifyGesture()
                .updating($pinchScale) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    // 上限 8 → 40：原来最多只能把 250 根压到 31 根，单根 K 线仍然很挤。
                    chartZoom = min(40, max(1, chartZoom * value.magnification))
                })
            .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let step = max(1, Int(abs(value.translation.width) / 22))
                let maxOffset = max(0, periodBars.count - zoomedBarCount)
                chartPanOffset = min(maxOffset, max(0, chartPanOffset + (value.translation.width < 0 ? step : -step)))
            })
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
    }

    private func volumePlot(bodyWidth: CGFloat) -> some View {
        Chart {
            ForEach(zoomedPeriodBars) { bar in
                BarMark(x: .value("日期", bar.date), y: .value("成交量", bar.volume), width: .fixed(bodyWidth))
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
    private var zoomedPeriodBars: [DailyBar] {
        let end = max(zoomedBarCount, periodBars.count - chartPanOffset)
        let start = max(0, end - zoomedBarCount)
        return Array(periodBars[start..<end])
    }

    @MainActor private func fetchTencentMinute() async {
        let today = shanghaiDay(.now)
        let calendarFormatter = DateFormatter(); calendarFormatter.locale = Locale(identifier: "en_US_POSIX")
        calendarFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); calendarFormatter.dateFormat = "yyyy-MM-dd"
        if let date = calendarFormatter.date(from: today), MarketCalendar.isWeekend(date)
            || MarketCalendar.mainlandClosures2026.contains(today) || store.data.customMarketHolidays.contains(today) {
            minuteStatus = "休市 · 最近交易日历史分时仍可查看"
            return
        }
        var shanghaiCalendar = Calendar(identifier: .gregorian); shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let components = shanghaiCalendar.dateComponents([.hour, .minute], from: .now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard (570...690).contains(minutes) || (780...900).contains(minutes) else {
            minuteStatus = "非交易时段 · 最近交易日历史分时仍可查看"
            return
        }
        let shanghaiPrefixes = ["6", "9", "5", "11", "50", "51", "56", "58"]
        let exchange = shanghaiPrefixes.contains(where: { holding.code.hasPrefix($0) }) ? "sh" : "sz"
        let symbol = exchange + holding.code
        guard let url = URL(string: "https://ifzq.gtimg.cn/appstock/app/minute/query?_var=min_data_\(Int(Date().timeIntervalSince1970))&code=\(symbol)") else { return }
        do {
            let data: Data
            do {
                // 行情走 iPhone 直连优先（与主行情通道一致），不依赖 NAS 穿透
                var request = URLRequest(url: url); request.timeoutInterval = 12
                let (direct, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                data = direct
            } catch {
                // 直连失败时才走 NAS 行情代理兜底
                if let proxied = try? await NASSyncService.marketProxyData(path: "minute", queryItems: [URLQueryItem(name: "code", value: symbol)]) {
                    data = proxied
                } else { throw error }
            }
            guard let raw = String(data: data, encoding: .utf8),
                  let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let root = try JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
                  let nodes = root["data"] as? [String: Any], let node = nodes[symbol] as? [String: Any],
                  let payload = node["data"] as? [String: Any], let rows = payload["data"] as? [String] else {
                minuteStatus = "数据源未返回可识别分钟线"; return
            }
            let rawDay = (payload["date"] as? String) ?? shanghaiDay(.now)
            let day: String
            if rawDay.count == 8, rawDay.allSatisfy(\.isNumber) {
                day = "\(rawDay.prefix(4))-\(rawDay.dropFirst(4).prefix(2))-\(rawDay.suffix(2))"
            } else { day = rawDay }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
            var parsed: [IntradayBar] = []
            var previousVolume = 0.0
            for row in rows {
                let fields = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard fields.count >= 2, let price = Double(fields[1]), price > 0,
                      let date = formatter.date(from: "\(day) \(fields[0])") else { continue }
                let cumulative = fields.count > 2 ? Double(fields[2]) : nil
                let delta = cumulative.map { max(0, $0 - previousVolume) }
                if let cumulative { previousVolume = cumulative }
                parsed.append(IntradayBar(code: holding.code, timestamp: date, price: price, volume: delta, day: day))
            }
            guard !parsed.isEmpty else { minuteStatus = "今日尚无分钟数据，或市场休市"; return }
            // 腾讯分时响应另含 ETF 汇总行情 qt；折溢价率字段为百分数。
            // 仅在品种确认为 ETF 且数值有效时计算 IOPV，缺字段不以昨收净值代替。
            if let qt = root["qt"] as? [String: Any], let values = qt[symbol] as? [Any],
               values.count > 63, (values[61] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ETF" {
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
                if let premium = field(63), premium.isFinite, (-50...50).contains(premium),
                   let last = parsed.last?.price, last.isFinite, last > 0, (1 + premium / 100) > 0 {
                    let iopv = last / (1 + premium / 100)
                    if iopv.isFinite, iopv > 0 {
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
        } catch { minuteStatus = "分时获取失败：\(error.localizedDescription)" }
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
            instrumentAIResult = try await AIAnalysisService.analyzeInstrument(
                config: store.data.aiAnalysisConfig, holding: actualHolding, quote: quote, bars: allBars,
                intradayBars: selectedIntradayBars, priceLevels: priceLevelsPromptText,
                profile: store.data.investmentProfile, totalAsset: store.totalAsset)
        } catch { instrumentAIMessage = error.localizedDescription }
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
        .presentationBackground(.clear)
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
            let bodyWidth = min(max(slot * 0.74, 2.2), 30)
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
            let bodyWidth = min(max(slot * 0.74, 2.2), 30)
            Chart {
                ForEach(visibleBars) { bar in
                    BarMark(x: .value("日期", bar.date), y: .value("成交量", bar.volume), width: .fixed(bodyWidth))
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
