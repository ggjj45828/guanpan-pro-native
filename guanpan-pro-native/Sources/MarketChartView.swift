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

/// Align 30/60-minute bars to each market's actual session open. Flooring Unix
/// timestamps puts Shanghai 60-minute bars on the hour (09:00, 10:00…), even
/// though the session opens at 09:30; the first bar then gets clipped by the
/// 09:30 chart domain and every later point appears half an hour early.
private func intradayBucketStart(_ time: Date, code: String, widthMinutes: Int) -> Date {
    guard time.timeIntervalSince1970.isFinite else { return time }
    guard widthMinutes > 1 else {
        return Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / 60) * 60)
    }
    let normalized = code.lowercased()
    let isUS = normalized.hasPrefix("us")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: isUS ? "America/New_York" : "Asia/Shanghai") ?? .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
    guard let year = parts.year, let month = parts.month, let day = parts.day,
          let hour = parts.hour, let minute = parts.minute else { return time }
    let minuteOfDay = hour * 60 + minute
    let open = 9 * 60 + 30
    let close = isUS ? 16 * 60 : 15 * 60
    let afternoonOpen = 13 * 60
    let afternoonClose = 15 * 60
    let startMinute: Int
    if isUS {
        guard minuteOfDay >= open, minuteOfDay <= close else { return time }
        let elapsed = min(minuteOfDay - open, close - open - 1)
        startMinute = open + (elapsed / widthMinutes) * widthMinutes
    } else if minuteOfDay >= open && minuteOfDay < 11 * 60 + 30 {
        startMinute = open + ((minuteOfDay - open) / widthMinutes) * widthMinutes
    } else if minuteOfDay >= afternoonOpen && minuteOfDay <= afternoonClose {
        let elapsed = min(minuteOfDay - afternoonOpen, afternoonClose - afternoonOpen - 1)
        startMinute = afternoonOpen + (elapsed / widthMinutes) * widthMinutes
    } else {
        // Preserve unexpected/imported timestamps instead of silently dropping them.
        return Date(timeIntervalSince1970: floor(time.timeIntervalSince1970 / (Double(widthMinutes) * 60)) * Double(widthMinutes) * 60)
    }
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = startMinute / 60; components.minute = startMinute % 60
    return calendar.date(from: components) ?? time
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
enum IntradayVisibility {
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

/// 空心 MACD 柱；DIF/DEA 单独在最后绘制，确保曲线始终位于柱体上层。
@ChartContentBuilder
func hollowIntradayMACDColumn(time: Date, value: Double, interval: TimeInterval,
                              color: Color, lineWidth: CGFloat = 1.0) -> some ChartContent {
    if value.isFinite, abs(value) > 0.0000000001 {
        let halfWidth = max(1, interval) * 0.36
        let left = time.addingTimeInterval(-halfWidth)
        let right = time.addingTimeInterval(halfWidth)
        let low = min(0, value)
        let high = max(0, value)
        // 竖边：固定 x、y 取区间 —— `RuleMark(x:yStart:yEnd:)`
        RuleMark(x: .value("柱左边", left), yStart: .value("柱下沿", low), yEnd: .value("柱上沿", high))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        RuleMark(x: .value("柱右边", right), yStart: .value("柱下沿", low), yEnd: .value("柱上沿", high))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        // 横边：固定 y、x 取区间 —— `RuleMark(xStart:xEnd:y:)`。
        // 参数顺序不能写成 `(y:xStart:xEnd:)`，Charts 没有那个重载，会报
        // "incorrect argument labels in call (have 'y:xStart:xEnd:', expected 'xStart:xEnd:y:')"。
        RuleMark(xStart: .value("柱左边", left), xEnd: .value("柱右边", right), y: .value("柱顶边", value))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
        RuleMark(xStart: .value("柱左边", left), xEnd: .value("柱右边", right), y: .value("柱基线", 0))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
    }
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

/// MA 均线显示开关（UserDefaults 持久化，点图例 chip 切换）。
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

/// X 轴的日期刻度点。
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

/// 日 K 下方副图的三种形态。主流站点（东方财富 / 同花顺）都在副图左上角放一排小标签切换，
/// 这里沿用同一交互：点标签即换图，选中态记住。
enum DailySubChart: String, CaseIterable, Identifiable {
    case volume = "成交量"
    case amount = "成交额"
    case macd = "MACD"
    var id: String { rawValue }
}

// MARK: - 图表独立视图类型（防 SwiftUI 视图类型嵌套过深）
//
// ⚠️ 这些图表**必须**放在独立类型里，不能写成 `MarketChartView` 的 `@ViewBuilder` 计算属性。
//
// 原因（2026-10-14 崩溃日志定位到的确定事实）：
// SwiftUI 的视图类型是按泛型嵌套展开的 —— `Chart { ... }` 的 `ChartContentBuilder` 会生成
// 一层层 `TupleChartContent` / `ModifiedContent`，外面再套 `VStack` → `if/else` → `Section`
// → `List` → `NavigationStack`，一个视图的**类型名**能嵌套 30 多层。
// 运行时首次创建该类型元数据时，`swift_getTypeByMangledNameInContext2` 必须递归解析这个类型名
// （崩溃栈里就是 `decodeMangledType` / `decodeGenericArgs` 递归三十来层），主线程 1MB 栈被
// ViewGraph 的 `update_attribute` 链和解析器一起用光，命中「栈保护页」（Stack Guard）→ SIGSEGV。
// 用户看到的现象就是「点开日 K / 自选卡片**瞬间**闪退」，而不是某种数据错误。
// 拆成独立类型后，父视图里只出现一个类型名（嵌套 1 层），深度立刻回到安全范围。

/// 分时折线的一个点（主图价格 / 均价 / IOPV 共用同一形状）。
struct IntradayLine: Identifiable {
    let time: Date
    let price: Double
    var id: Date { time }
}

struct IntradayChartTradeMarker: Identifiable {
    let id: UUID
    let time: Date
    let price: Double
    let isBuy: Bool
}

/// 价格、均价和 IOPV 的共用动态范围，供持仓分时与历史档案调用。
func intradaySharedYDomain(_ source: [Double]) -> ClosedRange<Double> {
    let values = source.filter { $0.isFinite && $0 > 0 }
    guard let low = values.min(), let high = values.max() else { return 0...1 }
    let reference = max(abs(low), abs(high), 0.0001)
    let spread = max(high - low, reference * 0.002)
    let padding = max(spread * 0.05, reference * 0.0006)
    return (low - padding)...(high + padding)
}

/// 把一串点按「时间连续」切成若干段：相邻两点间隔超过 `maxGap` 秒就断开。
///
/// 专治 IOPV 这种**稀疏采样**序列：样本是前台逐分钟攒出来的，中间可能断几十分钟
/// （App 退后台、午休、刚安装还没攒够）。直接连线会把相隔很远的两个点画成一条
/// 横跨半张图的斜线 —— 看起来就是「线坏了」。断开重起一段，视觉上就诚实了。
func intradaySegmentedLines(_ points: [IntradayLine], maxGap: TimeInterval = 300) -> [[IntradayLine]] {
    var result: [[IntradayLine]] = []
    var current: [IntradayLine] = []
    for point in points.sorted(by: { $0.time < $1.time }) where point.price.isFinite && point.price > 0 {
        if let last = current.last, point.time.timeIntervalSince(last.time) > maxGap {
            result.append(current)
            current = []
        }
        current.append(point)
    }
    if !current.isEmpty { result.append(current) }
    return result
}

/// 用「两个真实 IOPV 锚点 + 分时价格」还原一条 IOPV 曲线（**估算**，非实测）。
///
/// 背景：腾讯和东财的分钟线接口**都不给 IOPV**，快照接口也只给两个数 ——
/// 字段 78（今天此刻的 IOPV）和字段 81（昨天的 IOPV）。所以「分时 IOPV 曲线」
/// 在任何行情源上都不存在真数据，网页版（`观盘.html` 的 `iopvSeries()`）的做法是：
///
///   1. `昨收 ÷ 昨IOPV − 1` = **昨天收盘时的溢价率**；
///   2. `现价 ÷ 今IOPV − 1` = **此刻的溢价率**；
///   3. 假设溢价率在日内**线性变化**，对每个分时点插值出该时刻的溢价率；
///   4. `IOPV = 该时点价格 ÷ (1 + 该时点溢价率)`，末端用真实 IOPV 校正。
///
/// 这条线**首尾是真实值、中间是插值估计**。之所以够用：ETF 的折溢价日内通常变化平缓，
/// 曲线形状基本跟随价格线，只是被溢价率调制；而用户看这条线是为了「价格离净值有多远」，
/// 这个差值本身就在插值里被保留下来了。
///
/// **必须画成虚线并标注「估算」**：它和前台逐分钟采集的实测点不是一回事，
/// 混成一条实线就是在骗人。实测够用时优先用实测（见 `iopvLineMode`）。
///
/// - Parameters:
///   - points: 当日分时价格序列（时间升序或乱序都可，内部会排）。
///   - previousClose: 昨收价（分时接口自带）。
///   - navPrev: 昨日 IOPV（腾讯字段 81 / 新浪字段 4）。
///   - navNow: 今日 IOPV（腾讯字段 78 / 新浪字段 3）。
///   - priceNow: 现价；传 nil 时退化为用最后一个分时点。
func estimatedIOPVSeries(points: [IntradayLine],
                         previousClose: Double?,
                         navPrev: Double?,
                         navNow: Double?,
                         priceNow: Double? = nil) -> [IntradayLine] {
    guard points.count >= 2,
          let previousClose, previousClose.isFinite, previousClose > 0,
          let navPrev, navPrev.isFinite, navPrev > 0,
          let navNow, navNow.isFinite, navNow > 0 else { return [] }
    let ordered = points
        .filter { $0.price.isFinite && $0.price > 0 }
        .sorted { $0.time < $1.time }
    guard ordered.count >= 2 else { return [] }
    let lastPrice: Double = {
        if let priceNow, priceNow.isFinite, priceNow > 0 { return priceNow }
        return ordered[ordered.count - 1].price
    }()
    guard lastPrice > 0 else { return [] }
    let premiumPrev = previousClose / navPrev - 1   // 昨天收盘时的溢价率
    let premiumNow = lastPrice / navNow - 1         // 此刻的溢价率
    // 溢价率必须有限，且 1+溢价 > 0（否则 IOPV = 价格 ÷ 非正数 会翻号或爆掉）。
    guard premiumPrev.isFinite, premiumNow.isFinite,
          (1 + premiumPrev) > 0.01, (1 + premiumNow) > 0.01 else { return [] }
    let denominator = Double(ordered.count - 1)
    var result: [IntradayLine] = []
    result.reserveCapacity(ordered.count)
    for (index, point) in ordered.enumerated() {
        let ratio = index == ordered.count - 1 ? 1 : Double(index) / denominator
        let premium = premiumPrev + (premiumNow - premiumPrev) * ratio
        let value = (1 + premium) > 0 ? point.price / (1 + premium) : point.price
        guard value.isFinite, value > 0 else { continue }
        result.append(IntradayLine(time: point.time, price: value))
    }
    guard result.count >= 2 else { return [] }
    // 末端用真实 IOPV 对齐：中间的插值有估计误差，但收盘那一刻的 IOPV 是实打实的。
    result[result.count - 1] = IntradayLine(time: result[result.count - 1].time, price: navNow)
    return result
}

/// 分时均价点（原先是 `MarketChartView` 的嵌套类型，抽图后要跨类型使用）。
private struct IntradayAvgPoint: Identifiable {
    let timestamp: Date
    let price: Double
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}

/// 午休压缩：把 11:30–13:00 这 90 分钟从横轴上折掉，13:00 之后的点整体左移 89 分钟。
func intradayCompressedTime(_ time: Date, compressLunch: Bool) -> Date {
    guard compressLunch else { return time }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let parts = calendar.dateComponents([.hour, .minute], from: time)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= 13 * 60
        ? time.addingTimeInterval(-89 * 60) : time
}

/// 给时间点找最接近的固定刻度文案（压缩午休后 15:00 会落在 13:31，所以刻度点本身也是压缩后的时间）。
func intradayAxisLabel(_ time: Date, ticks: [(time: Date, label: String)]) -> String {
    ticks.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) })?.label
        ?? time.formatted(date: .omitted, time: .shortened)
}

/// 分时主图 / 30-60 分主图共用的纵轴上下限（同花顺口径）。
///
/// 规则只有两条（按用户 2026-10-14 的口径）：
/// ① **昨收＝0 轴**；② 上下限**对称**，都等于「今日实际到达的最大涨跌幅」——
///    今天最高价涨到 0.83%，轴就扩到 ±0.83%，**不取整、不额外留余量**，
///    价格线的顶点正好贴到图的上边框（同花顺那种观感）。
///
/// 唯一例外：全天几乎不波动时兜底到 **±0.5%**。
/// 否则纵轴会被压到接近 0，价格线在纵向被无限放大，看起来像剧烈波动
/// —— 那是缩放假象，不是真实振幅。此处兜底值就是用户确认的 0.5%，
/// 不是先前误写的 1%，也不是任何「档位表」。
private func symmetricIntradayYDomain(low: Double, high: Double, previous: Double?) -> ClosedRange<Double>? {
    guard let previous = previous, previous > 0, previous.isFinite,
          low.isFinite, high.isFinite else { return nil }
    let upMove = (high - previous) / previous
    let downMove = (previous - low) / previous
    let move = max(abs(upMove), abs(downMove))
    guard move.isFinite else { return nil }
    let bound = max(move, 0.005)
    return (previous * (1 - bound))...(previous * (1 + bound))
}

/// 分时量柱涨跌配色。`prevClose` 是第一根柱的前收基准。
/// 参数用到文件私有的 `MinuteBucket`，所以这里必须是 `private`（文件作用域 private ≡ fileprivate，同文件内可见）。
private func intradayVolumeColor(at index: Int, in buckets: [MinuteBucket], prevClose: Double?) -> Color {
    guard buckets.indices.contains(index) else { return Color.secondary }
    let previous = index > 0 ? buckets[index - 1].close : (prevClose ?? buckets[index].close)
    return buckets[index].close >= previous ? Color.red.opacity(0.82) : Color.green.opacity(0.82)
}

func intradayVolumeMAColor(_ period: Int) -> Color {
    switch period {
    case 20: return ChartPalette.ma20
    case 60: return ChartPalette.ma60
    default: return ChartPalette.ma250
    }
}

/// 连续时间轴上的柱宽按点数自适应，既保留柱间距，也避免 242 点挤成实心色块。
func intradayBarWidth(_ count: Int) -> CGFloat {
    let plotWidth = max(200, UIScreen.main.bounds.width - 112)
    return min(8, max(1.2, plotWidth / CGFloat(max(count, 1)) * 0.72))
}

/// 成交额（元）。腾讯日 K 没有成交额这一列，缺真实值时按「量（手）× 100 × 收盘价」估算。
func dailyTurnover(of bar: DailyBar) -> Double {
    let real = bar.amount ?? 0
    return real > 0 ? real : bar.volume * 100 * bar.close
}

func compactAmountText(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 100_000_000 { return "\((value / 100_000_000).num(2))亿" }
    if magnitude >= 10_000 { return "\((value / 10_000).num(1))万" }
    return value.num(0)
}

/// 分时主图：价格线 + 可选均价 / IOPV / 昨收。
struct IntradayMainChart: View {
    let lines: [IntradayLine]
    let average: [IntradayLine]
    let iopv: [IntradayLine]
    /// **估算** IOPV 曲线：由「昨 IOPV / 今 IOPV 两个真实锚点 + 分时价格」插值而来
    /// （见 `estimatedIOPVSeries`）。只在**实测点连不成线**时使用，画虚线。
    /// 它原来叫 `iopvFallback`（一个 Double，什么都不画），现在换成真正能画的一条线。
    let estimatedIOPV: [IntradayLine]
    let previousClose: Double?
    let showAverage: Bool
    let showIOPV: Bool
    let showPreviousClose: Bool
    let lineColor: Color
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let ticks: [(time: Date, label: String)]
    let compressLunch: Bool
    let height: CGFloat
    let lineWidth: CGFloat
    var selection: Binding<Date?>? = nil
    var selectionLabel: String? = nil
    var tradeMarkers: [IntradayChartTradeMarker] = []

    @Environment(\.colorScheme) private var colorScheme

    /// IOPV 采样里「连成线」的那些段（每段至少 2 个点，段内相邻点间隔 ≤ 5 分钟）。
    private var iopvSegments: [[IntradayLine]] {
        guard showIOPV, iopv.count >= 2 else { return [] }
        return intradaySegmentedLines(iopv).filter { $0.count >= 2 }
    }

    /// IOPV 采样里的落单点（前后 5 分钟内没有第二个采样）。画不出线，但可以点出来。
    private var iopvIsolatedPoints: [IntradayLine] {
        guard showIOPV, !iopv.isEmpty else { return [] }
        return intradaySegmentedLines(iopv).filter { $0.count == 1 }.compactMap(\.first)
    }

    /// 实测点连不成线时，用插值曲线顶上。实测够用就**不画估算线** —— 两条叠在一起
    /// 只能看出「哪条是真的」是看不出来的，反倒是视觉噪音。
    private var showsEstimatedIOPV: Bool {
        showIOPV && iopvSegments.isEmpty && estimatedIOPV.count >= 2
    }

    init(lines: [IntradayLine], average: [IntradayLine], iopv: [IntradayLine],
         estimatedIOPV: [IntradayLine], previousClose: Double?, showAverage: Bool,
         showIOPV: Bool, showPreviousClose: Bool, lineColor: Color,
         xDomain: ClosedRange<Date>, yDomain: ClosedRange<Double>,
         ticks: [(time: Date, label: String)], compressLunch: Bool,
         height: CGFloat, lineWidth: CGFloat,
         selection: Binding<Date?>? = nil, selectionLabel: String? = nil,
         tradeMarkers: [IntradayChartTradeMarker] = []) {
        self.lines = lines
        self.average = average
        self.iopv = iopv
        self.estimatedIOPV = estimatedIOPV
        self.previousClose = previousClose
        self.showAverage = showAverage
        self.showIOPV = showIOPV
        self.showPreviousClose = showPreviousClose
        self.lineColor = lineColor
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.ticks = ticks
        self.compressLunch = compressLunch
        self.height = height
        self.lineWidth = lineWidth
        self.selection = selection
        self.selectionLabel = selectionLabel
        self.tradeMarkers = tradeMarkers
    }

    private func t(_ time: Date) -> Date { intradayCompressedTime(time, compressLunch: compressLunch) }

    /// 昨收线用「浅黑虚线」，现价线用「浅黄虚线」—— 两条都要在深浅两套主题下都看得见。
    /// 纯黑 / 纯黄放到对面主题里会彻底消失，所以按 colorScheme 分别取色。
    private var previousCloseLineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.32)
    }
    private var currentPriceLineColor: Color {
        colorScheme == .dark
            ? Color(red: 0.99, green: 0.90, blue: 0.48)
            : Color(red: 0.78, green: 0.60, blue: 0.04)
    }

    var body: some View {
        Chart {
            ForEach(lines) { p in
                AreaMark(x: .value("时间", t(p.time)), yStart: .value("区间下沿", yDomain.lowerBound), yEnd: .value("价格", p.price), series: .value("主图序列", "价格填充"))
                    .foregroundStyle(lineColor.opacity(0.08))
                    .interpolationMethod(.linear)
                LineMark(x: .value("时间", t(p.time)), y: .value("价格", p.price), series: .value("主图序列", "价格"))
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if showAverage {
                ForEach(average) { p in
                    LineMark(x: .value("时间", t(p.time)), y: .value("均价", p.price), series: .value("主图序列", "均价"))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            if showIOPV {
                // IOPV **没有历史分时接口**（腾讯 / 东财的分钟线只给价量，IOPV 只在快照字段里给
                // 一个当前值），所以本机这条线是「前台逐分钟实测攒出来的」，样本天生稀疏：
                // 中间可能断几十分钟（App 退到后台、午休、刚装上还没攒）。
                //
                // 因此**不能**直接把点连起来：
                //   · 09:35 一个点、14:30 一个点 —— `LineMark` 会把它们连成一条横跨半张图的斜线，
                //     看起来像数据坏了（用户反馈的「没有数据的时候是斜线」）。
                //   · 只有 1 个点时 `LineMark` 什么都画不出来，之前退化成一条「当前值参考线」，
                //     用户明确否掉（「直线」「补虚假的」）。
                // 现在的规则：同一段内相邻样本间隔超过 5 分钟就断开；每段 ≥2 点才连线，
                // 落单的点只画一个小圆点；**一个样本都没有时什么都不画**。
                ForEach(Array(iopvSegments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { p in
                        LineMark(x: .value("时间", t(p.time)), y: .value("IOPV", p.price),
                                 series: .value("主图序列", "IOPV-\(index)"))
                            .foregroundStyle(Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(iopvIsolatedPoints) { p in
                    PointMark(x: .value("时间", t(p.time)), y: .value("IOPV", p.price))
                        .foregroundStyle(Color.purple).symbolSize(18)
                }
            }
            // 实测一个点都连不起来时，用「昨 IOPV / 今 IOPV + 分时价格」插值出的曲线顶上。
            // **虚线**是刻意的：这条线首尾是真实值、中间是估算，不能和实测实线混为一谈。
            if showsEstimatedIOPV {
                ForEach(estimatedIOPV) { p in
                    LineMark(x: .value("时间", t(p.time)), y: .value("IOPV", p.price),
                             series: .value("主图序列", "IOPV估算"))
                        .foregroundStyle(Color.purple.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                               lineJoin: .round, dash: [4, 3]))
                }
            }
            if showPreviousClose, let value = previousClose {
                RuleMark(y: .value("昨收", value)).foregroundStyle(previousCloseLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            ForEach(tradeMarkers) { trade in
                PointMark(x: .value("交易时间", t(trade.time)), y: .value("成交价", trade.price))
                    .foregroundStyle(trade.isBuy ? Color.red : Color.green)
                    .symbolSize(60)
                    .annotation(position: trade.isBuy ? .top : .bottom) {
                        Text(trade.isBuy ? "B" : "S").font(.caption2.bold())
                            .foregroundStyle(trade.isBuy ? Color.red : Color.green)
                    }
            }
            if let selectedTime = selection?.wrappedValue, let selectionLabel {
                RuleMark(x: .value("选中", t(selectedTime)))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text(selectionLabel).font(.caption.monospacedDigit()).padding(6)
                            .background(colorScheme == .light ? Color.white : Color.black,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
            }
            // 现在价：一条浅黄淡虚线横轴。分时图上「我此刻在哪个价位」是最常被找的一根线，
            // 光有折线的末尾点不够显眼（尤其缩略看的时候）。放在最后画，保证压在其他线之上。
            if let last = lines.last?.price, last.isFinite, last > 0 {
                RuleMark(y: .value("现价", last)).foregroundStyle(currentPriceLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 0.95, dash: [5, 4]))
            }
        }
        .frame(height: height)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if compressLunch, !ticks.isEmpty {
                AxisMarks(values: ticks.map { $0.time }) { value in
                    AxisValueLabel {
                        if let time = value.as(Date.self) {
                            Text(intradayAxisLabel(time, ticks: ticks)).font(.system(size: 9))
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 9))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13))
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .chartXSelection(value: selection ?? .constant(nil))
    }
}

/// 分时副图 · MACD（空心柱 + DIF / DEA），主图与 30/60 分图共用。
private struct IntradayMACDChart: View {
    let points: [MinuteMACDPoint]
    let lineColor: Color
    let interval: TimeInterval
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let compressLunch: Bool
    let height: CGFloat

    private func t(_ time: Date) -> Date { intradayCompressedTime(time, compressLunch: compressLunch) }

    var body: some View {
        Chart {
            RuleMark(y: .value("零轴", 0)).foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            ForEach(points) { p in
                hollowIntradayMACDColumn(time: t(p.time), value: p.histogram,
                    interval: interval,
                    color: p.histogram >= 0 ? .red : .green)
            }
            ForEach(points) { p in
                LineMark(x: .value("时间", t(p.time)), y: .value("DIF", p.dif), series: .value("MACD序列", "DIF"))
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            ForEach(points) { p in
                LineMark(x: .value("时间", t(p.time)), y: .value("DEA", p.dea), series: .value("MACD序列", "DEA"))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
        }
        .frame(height: height)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13))
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 分时副图 · 成交量（量柱 + 可选量均线）。
private struct IntradayVolumeChart: View {
    let buckets: [MinuteBucket]
    let prevClose: Double?
    let maPeriods: [Int]
    let maSeries: [Int: [IntradayVolumeMAPoint]]
    let xDomain: ClosedRange<Date>
    let compressLunch: Bool
    let height: CGFloat

    private func t(_ time: Date) -> Date { intradayCompressedTime(time, compressLunch: compressLunch) }

    var body: some View {
        Chart {
            ForEach(buckets.indices, id: \.self) { index in
                let point = buckets[index]
                if let volume = point.volume, volume > 0 {
                    BarMark(x: .value("时间", t(point.start)), y: .value("量", volume),
                            width: .fixed(intradayBarWidth(buckets.count)))
                        .foregroundStyle(intradayVolumeColor(at: index, in: buckets, prevClose: prevClose))
                        .cornerRadius(1)
                }
            }
            ForEach(maPeriods, id: \.self) { period in
                ForEach(maSeries[period] ?? []) { point in
                    LineMark(x: .value("时间", t(point.time)), y: .value("量均线", point.value),
                             series: .value("量均线周期", "MA\(period)"))
                        .foregroundStyle(intradayVolumeMAColor(period))
                        .lineStyle(StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .chartXScale(domain: xDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.13))
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 分时右侧的开关栏按钮。
private struct IntradayRailButton: View {
    let title: String
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(isOn ? color : Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

/// 量均线开关（MA20 / MA60 / MA250）。
private struct IntradayVolumeMAToggle: View {
    let period: Int
    let isOn: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        let color = intradayVolumeMAColor(period)
        Button(action: action) {
            Text("MA\(period)").scaledFont(10, weight: .semibold)
                .foregroundStyle(isOn ? color : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background((isOn ? color : Color.secondary).opacity(isOn ? 0.13 : 0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.38)
    }
}

/// 分时面板右侧的图例 / 开关栏。
private struct IntradaySideRail: View {
    let lineColor: Color
    let showAverage: Bool
    let showIOPV: Bool
    let showPreviousClose: Bool
    let subchart: IntradaySubchart
    let volumeMAs: Set<Int>
    let bucketVolumeCount: Int
    let onToggleAverage: () -> Void
    let onToggleIOPV: () -> Void
    let onTogglePreviousClose: () -> Void
    let onSelectSubchart: (IntradaySubchart) -> Void
    let onToggleVolumeMA: (Int) -> Void

    var body: some View {
        VStack(spacing: 7) {
            Text("主图").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Capsule().fill(lineColor).frame(width: 10, height: 2)
                Text("价格").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            IntradayRailButton(title: "均价", isOn: showAverage, color: .orange, action: onToggleAverage)
            IntradayRailButton(title: "IOPV", isOn: showIOPV, color: .purple, action: onToggleIOPV)
            IntradayRailButton(title: "昨收", isOn: showPreviousClose, color: .gray, action: onTogglePreviousClose)
            Divider(); Text("副图").font(.caption2).foregroundStyle(.secondary)
            IntradayRailButton(title: "MACD", isOn: subchart == .macd, color: .blue) { onSelectSubchart(.macd) }
            IntradayRailButton(title: "分时量", isOn: subchart == .volume, color: .orange) { onSelectSubchart(.volume) }
            if subchart == .volume {
                Text("量均线").font(.system(size: 8)).foregroundStyle(.secondary)
                IntradayVolumeMAToggle(period: 20, isOn: volumeMAs.contains(20), available: bucketVolumeCount >= 20) { onToggleVolumeMA(20) }
                IntradayVolumeMAToggle(period: 60, isOn: volumeMAs.contains(60), available: bucketVolumeCount >= 60) { onToggleVolumeMA(60) }
                IntradayVolumeMAToggle(period: 250, isOn: volumeMAs.contains(250), available: bucketVolumeCount >= 250) { onToggleVolumeMA(250) }
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                }
                Text("涨 / 跌").font(.system(size: 8)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    Capsule().fill(lineColor).frame(width: 7, height: 2)
                    Capsule().fill(.orange).frame(width: 7, height: 2)
                }
                Text("DIF / DEA").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(width: 68)
    }
}

/// 分时面板：主图 + 副图 + 右侧开关栏。分时档与 30/60 分档共用。
private struct IntradayPanelView: View {
    let lines: [IntradayLine]
    let average: [IntradayLine]
    let iopv: [IntradayLine]
    let estimatedIOPV: [IntradayLine]
    let previousClose: Double?
    let macdPoints: [MinuteMACDPoint]
    let volumeBuckets: [MinuteBucket]
    let volumePrevClose: Double?
    let histInterval: TimeInterval
    let hasVolume: Bool
    let volumeMAs: Set<Int>
    let volumeMASeries: [Int: [IntradayVolumeMAPoint]]
    let lineColor: Color
    let xDomain: ClosedRange<Date>
    let priceYDomain: ClosedRange<Double>
    let macdYDomain: ClosedRange<Double>
    let compressLunch: Bool
    let ticks: [(time: Date, label: String)]
    let showAverage: Bool
    let showIOPV: Bool
    let showPreviousClose: Bool
    let subchart: IntradaySubchart
    let mainHeight: CGFloat
    let subHeight: CGFloat
    let lineWidth: CGFloat
    /// 副图顶部是否显示 MACD / 分时量 的分段选择器（30/60 分档用；分时档用右侧开关栏）。
    let showsSubchartPicker: Bool
    /// 是否显示右侧的图例 / 开关栏（30/60 分档没有叠加层，不显示）。
    let showsSideRail: Bool
    /// 没有成交量时副图里的说明文案（分时档与 30/60 分档的原因不同）。
    let volumeUnavailableHint: String
    let onToggleAverage: () -> Void
    let onToggleIOPV: () -> Void
    let onTogglePreviousClose: () -> Void
    let onSelectSubchart: (IntradaySubchart) -> Void
    let onToggleVolumeMA: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 7) {
                IntradayMainChart(lines: lines, average: average, iopv: iopv,
                    estimatedIOPV: estimatedIOPV, previousClose: previousClose,
                    showAverage: showAverage, showIOPV: showIOPV, showPreviousClose: showPreviousClose,
                    lineColor: lineColor, xDomain: xDomain, yDomain: priceYDomain,
                    ticks: ticks, compressLunch: compressLunch, height: mainHeight, lineWidth: lineWidth)
                if showsSubchartPicker {
                    Picker("分时副图", selection: Binding(get: { subchart }, set: { onSelectSubchart($0) })) {
                        ForEach(IntradaySubchart.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented)
                }
                if subchart == .macd {
                    IntradayMACDChart(points: macdPoints, lineColor: lineColor, interval: histInterval,
                        xDomain: xDomain, yDomain: macdYDomain, compressLunch: compressLunch, height: subHeight)
                } else if hasVolume {
                    IntradayVolumeChart(buckets: volumeBuckets, prevClose: volumePrevClose,
                        maPeriods: volumeMAs.sorted(), maSeries: volumeMASeries,
                        xDomain: xDomain, compressLunch: compressLunch, height: subHeight)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("暂无可用分时量").scaledFont(11, weight: .semibold)
                        Text(volumeUnavailableHint)
                            .scaledFont(9).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 125)
                }
            }
            if showsSideRail {
                IntradaySideRail(lineColor: lineColor, showAverage: showAverage, showIOPV: showIOPV,
                    showPreviousClose: showPreviousClose, subchart: subchart, volumeMAs: volumeMAs,
                    bucketVolumeCount: volumeBuckets.compactMap(\.volume).count,
                    onToggleAverage: onToggleAverage, onToggleIOPV: onToggleIOPV,
                    onTogglePreviousClose: onTogglePreviousClose,
                    onSelectSubchart: onSelectSubchart, onToggleVolumeMA: onToggleVolumeMA)
            }
        }.padding(6).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 日 K 成交标记（B 画在最低价下方、S 画在最高价上方）。
private struct TradeMarker: Identifiable {
    let id: UUID
    let day: String
    let price: Double
    let side: LedgerEntry.Side
}

/// 日 K 副图的 MACD 点。
private struct MACDSeriesPoint: Identifiable {
    let date: String
    let dif: Double
    let dea: Double
    let histogram: Double
    var id: String { date }
}

/// 日 K 主图：蜡烛 + 影线 + B/S 标记 + 选中十字 + 五条均线。
private struct DailyCandleChart: View {
    static let maWindows = [5, 10, 20, 60, 250]

    let visible: [DailyBar]
    let maSeries: [Int: [IndicatorPoint]]
    let markers: [TradeMarker]
    let selectedDate: String?
    let selectedClose: Double?
    let accentColor: Color
    let yDomain: ClosedRange<Double>
    let bodyWidth: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        Chart {
            ForEach(visible) { bar in
                let candleColor = bar.close >= bar.open ? Color.red : Color.green
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
            ForEach(markers) { marker in
                let color = marker.side == .buy ? ChartPalette.buyMark : ChartPalette.sellMark
                PointMark(x: .value("成交日", marker.day), y: .value("成交价", marker.price))
                    .foregroundStyle(color)
                    .symbolSize(18)
                    .annotation(position: marker.side == .buy ? .bottom : .top, spacing: 3) {
                        Text(marker.side == .buy ? "B" : "S")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3.5).padding(.vertical, 2)
                            // 白描边：不管压在深色还是浅色背景、红绿蜡烛附近都能看清
                            .background(color, in: RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 0.7))
                    }
            }
            if let selectedDate, let selectedClose {
                RuleMark(x: .value("选中日期", selectedDate))
                    .foregroundStyle(accentColor.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("选中日期", selectedDate), y: .value("收盘", selectedClose))
                    .foregroundStyle(accentColor)
                    .symbolSize(30)
            }
            ForEach(DailyCandleChart.maWindows, id: \.self) { window in
                ForEach(maSeries[window] ?? []) { point in
                    LineMark(x: .value("日期", point.date), y: .value("MA\(window)", point.value),
                             series: .value("均线", "MA\(window)"))
                        .foregroundStyle(ChartPalette.color(forMA: window))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
        }
        // Y 轴显式跟随可见窗口：捏合/拖动后上下界立即重算（含均线），不再是一整段区间
        .chartYScale(domain: yDomain)
        // X 轴按月抽稀：不再逐根显示日期，标签互相压叠又看不清
        .chartXAxis {
            AxisMarks(values: xAxisDates(visible)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {
                    if let date = value.as(String.self) {
                        Text(xAxisLabel(date, visible)).font(.system(size: 9)).foregroundStyle(.secondary)
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
                        onSelect(visible[index].date)
                        Haptics.selection()
                    })
            }
        }
    }
}

/// 日 K 副图 · 成交量。
private struct DailyVolumeSubChart: View {
    let bars: [DailyBar]
    let width: CGFloat

    var body: some View {
        Chart {
            ForEach(bars) { bar in
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
}

/// 日 K 副图 · 成交额（腾讯日 K 缺该列时按收盘价估算，标签会写明）。
private struct DailyAmountSubChart: View {
    let bars: [DailyBar]
    let width: CGFloat

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("日期", bar.date), y: .value("成交额", dailyTurnover(of: bar)), width: .fixed(width))
                    .foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                // 注意：刻度值取自 AxisMarks 的闭包参数，`AxisValueLabel { ... }` 自己没有 value 参数，
                // 写成 `AxisValueLabel { value in ... }` 会被解析成 StringProtocol 那个重载而报
                // “type '(_) -> ()' cannot conform to 'StringProtocol'”。
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(compactAmountText(number)).font(.system(size: 9))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// 日 K 副图 · MACD（柱 + DIF / DEA）。
private struct DailyMACDSubChart: View {
    let series: [MACDSeriesPoint]
    let width: CGFloat

    var body: some View {
        Chart {
            ForEach(series) { point in
                BarMark(x: .value("日期", point.date), y: .value("MACD", point.histogram), width: .fixed(width))
                    .foregroundStyle(point.histogram >= 0 ? Color.red.opacity(0.78) : Color.green.opacity(0.78))
            }
            ForEach(series) { point in
                LineMark(x: .value("日期", point.date), y: .value("DIF", point.dif), series: .value("指标线", "DIF"))
                    .foregroundStyle(ChartPalette.ma5)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(series) { point in
                LineMark(x: .value("日期", point.date), y: .value("DEA", point.dea), series: .value("指标线", "DEA"))
                    .foregroundStyle(ChartPalette.ma10)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            RuleMark(y: .value("零轴", 0))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 日 K 副图左上角的一排小标签（成交量 / 成交额 / MACD），点一下换图。
private struct DailySubChartTabs: View {
    let selection: DailySubChart
    let accentColor: Color
    let amountIsEstimated: Bool
    let onSelect: (DailySubChart) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DailySubChart.allCases) { mode in
                let selected = selection == mode
                Button {
                    Haptics.selection()
                    onSelect(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? accentColor : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill((selected ? accentColor : Color.secondary)
                                .opacity(selected ? 0.16 : 0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("副图切换 \(mode.rawValue)")
            }
            Spacer(minLength: 0)
            if selection == .amount, amountIsEstimated {
                Text("按收盘价估算").font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if selection == .macd {
                Text("DIF / DEA 12/26/9").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 20)
    }
}

struct MarketChartView: View {
    /// **只建一次**的日期格式化器。
    ///
    /// `DateFormatter()` 初始化 + 设 locale/timeZone/dateFormat 一次要几十微秒，
    /// 而本文件里的转换函数都写在 `body` 与逐根 K 线 / 逐条流水的路径上
    /// （`shanghaiDay` 出现在 ledger 的 `filter` 闭包里，周 / 月聚合会逐根解析日期，
    /// 分时横轴刻度每次重绘都要造一个）。每次现建一个，等于把一次字符串转换
    /// 放大成一次格式化器构造 —— 这是分时 / 日 K 页缩放与滑动掉帧的直接来源之一。
    /// 所有调用都在主线程；`DateFormatter` 自 iOS 7 起格式化是线程安全的。
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 「yyyy-MM-dd HH:mm」解析器：分时横轴刻度与全天时段边界共用。
    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    @EnvironmentObject private var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let holding: Holding
    @State private var selectedIntradayDay = ""
    @State private var selectedChartPeriod: NativeChartPeriod = .intraday
    /// 每条均线可单独开关：点图例 chip 切换，状态持久化到 UserDefaults
    @State private var maVisible: Set<Int> = MAVisibility.read()
    /// 日 K 副图切到哪一项（成交量 / 成交额 / MACD）。存原始值字符串，
    /// 枚举改名或加项都不会把老用户的选择卡死，读不到就回落成交量。
    @AppStorage("guanpan.native.dailySubChart") private var dailySubChartRaw: String = DailySubChart.volume.rawValue
    private var dailySubChart: DailySubChart {
        get { DailySubChart(rawValue: dailySubChartRaw) ?? .volume }
        nonmutating set { dailySubChartRaw = newValue.rawValue }
    }
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
    @State private var lastIOPVFallbackAt: Date?
    @State private var chartZoom = 1.0
    @GestureState private var pinchScale = 1.0
    @State private var chartPanOffset = 0
    @State private var chartDragAppliedX: CGFloat = 0
    @State private var selectedDailyDate: String?

    private var allBars: [DailyBar] {
        // 走 store 的带缓存版本（v2.13.35）：日 K 页一次 body 里会取十几次日线，
        // 每次都做一遍 filter + 去重字典 + 全量排序的话，捏合缩放就是逐帧付这个钱。
        store.normalizedDailyBars(forCode: holding.code)
    }
    private var bars: [DailyBar] { allBars }
    /// 日 K 始终基于完整历史；屏幕上显示多少根只由捏合缩放与拖动决定。
    private var periodBars: [DailyBar] { aggregated(allBars) }
    /// 当前周期、但用**本机全部**日线聚合。
    ///
    /// 均线一律用这一份来算。显示区间可以只有 60 根，但 MA60 / MA250 需要更早的收盘价
    /// 才能算出区间左端的值 —— 之前只有 MA250 走了这条路，MA5/10/20/60 是拿 `bars`
    /// 当计算源，于是捏合放大到「可见根数 < 窗口长度」时，`source.count >= window`
    /// 不成立，整条线直接消失；拖动去看更早的历史也一样。
    ///
    /// v2.13.35：它就是 `periodBars`（两者都是 `aggregated(allBars)`，一字不差），
    /// 原来各算一遍等于把周 / 月聚合的日期解析做两遍。改为直接复用。
    private var periodAllBars: [DailyBar] { periodBars }

    /// 把日线聚合成当前周期（日 / 周 / 月）。
    /// 传 `bars` 得到显示区间的序列，传 `allBars` 得到全量序列，两者口径完全一致 ——
    /// 只有口径一致，均线「用全量算、按可见日期取」才对得上横坐标。
    ///
    /// 周 / 月的结果按「标的 + 周期 + 源序列边界」memo（v2.13.35）：
    /// 这个函数一次 body 会被调十几次（`periodBars`、均线、支撑压力、副图…），
    /// 每次都要把每根日线的日期字符串解析一遍再分组排序；缓存之后只算一次。
    private func aggregated(_ source: [DailyBar]) -> [DailyBar] {
        switch selectedChartPeriod {
        case .intraday, .minute30, .minute60: return []
        case .day: return source
        case .week, .month:
            let key = "\(holding.code)|\(selectedChartPeriod.rawValue)|\(source.count)"
                + "|\(source.first?.date ?? "")|\(source.last?.date ?? "")"
            return ChartAggregationMemo.value(key: key) { buildAggregated(source) }
        }
    }

    private func buildAggregated(_ source: [DailyBar]) -> [DailyBar] {
        switch selectedChartPeriod {
        case .intraday, .minute30, .minute60: return []
        case .day: return source
        case .week, .month:
            let calendar = Calendar(identifier: .iso8601)
            let formatter = Self.dayFormatter
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
    /// 本机已有分时记录的交易日（倒序）。
    ///
    /// 走 store 的「code → 交易日集合」索引，不再 `store.intradayBars.filter{...}`：
    /// 后者是 O(档案总点数)，而 body 一帧里会取十几次，档案越长滑动越卡。
    private var intradayDays: [String] {
        store.intradayDays(forCode: holding.code)
    }
    /// 当前实际生效的交易日：用户选的还在就用它，否则退回最近一个有记录的交易日。
    private var intradaySelectedDay: String {
        let days = intradayDays
        return days.contains(selectedIntradayDay) ? selectedIntradayDay : (days.first ?? "")
    }
    /// 所选交易日的分时点（时间升序）。索引里已经排好序，这里不再重复 sort。
    private var selectedIntradayBars: [IntradayBar] {
        store.intradayBars(code: holding.code, day: intradaySelectedDay)
    }

    /// 分时均价点：有量就用「累计成交额 / 累计量」的加权均价，
    /// 全程没量（导入的历史分时）就退化为简单算术均价，两种口径都不臆造。
    /// 点类型 `IntradayAvgPoint` 已移到文件级（抽成独立图表类型后要跨类型使用）。
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
                shares += volume
                amount += bar.price * volume
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
    private var selectedDayPremium: Double? {
        if intradayIOPVDay == selectedIntradayDay,
           let value = intradayPremiumPercent, value.isFinite, value > -100 { return value }
        // 分时接口偶尔只返回分钟线；首页行情已从腾讯 ETF 报价 77 项取得溢价率。
        // 只给当前交易日兜底，历史日期不套用今天的数据。
        guard holding.kind == .etf,
              selectedIntradayDay.isEmpty || selectedIntradayDay == shanghaiDay(.now),
              let value = store.marketPremiums[holding.code], value.isFinite, value > -100 else { return nil }
        return value
    }
    private var selectedDayIOPV: Double? {
        if let archived = selectedIntradayBars.reversed().compactMap(\.iopv).first(where: { $0.isFinite && $0 > 0 }) { return archived }
        if intradayIOPVDay == selectedIntradayDay,
           let value = intradayIOPV, value.isFinite, value > 0 { return value }
        if let premium = selectedDayPremium,
           let price = intradayLatestPrice, price.isFinite, price > 0,
           1 + premium / 100 > 0 {
            let value = price / (1 + premium / 100)
            if value.isFinite, value > 0 { return value }
        }
        guard holding.kind == .etf,
              selectedIntradayDay.isEmpty || selectedIntradayDay == shanghaiDay(.now),
              let value = store.marketIOPVs[holding.code], value.isFinite, value > 0 else { return nil }
        return value
    }
    private var selectedDayIOPVPoints: [IntradayIOPVPoint] {
        let archived = selectedIntradayBars.compactMap { bar -> IntradayIOPVPoint? in
            guard let value = bar.iopv, value.isFinite, value > 0 else { return nil }
            return IntradayIOPVPoint(timestamp: bar.timestamp, value: value)
        }
        guard intradayIOPVDay == selectedIntradayDay else { return archived }
        // 逐条写入，不用 `Dictionary(uniqueKeysWithValues:)`：
        // 一旦同一分钟出现两条（备份合并、旧档案重复日期都可能出现），
        // 那个构造器会直接 trap（Fatal error: Duplicate values for key），整个 App 闪退。
        var byMinute: [Int: IntradayIOPVPoint] = [:]
        // 分钟键一律走 `PortfolioStore.minuteStamp`：`Int(时间戳 / 60)` 遇到坏时间戳
        // （非有限值 / 超出 Int 范围）会直接 trap，这种崩法 catch 不到。
        for point in archived { byMinute[PortfolioStore.minuteStamp(point.timestamp)] = point }
        for point in intradayIOPVPoints { byMinute[PortfolioStore.minuteStamp(point.timestamp)] = point }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }
    private var selectedDayETFQuoteSummary: IntradayETFQuoteSummary? {
        intradayETFQuoteSummaryDay == selectedIntradayDay ? intradayETFQuoteSummary : nil
    }
    /// 估算 IOPV 曲线：实测点连不成线时的兜底（见 `estimatedIOPVSeries`）。
    ///
    /// 为什么需要它：IOPV 的**分时数据在任何行情源上都不存在**，本机那条紫线是
    /// 「前台逐分钟采集」攒出来的 —— 刚装上、或退后台几十分钟，就是空的。
    /// 网页版没有这个空窗，因为它从来就是用两个真实锚点（昨 IOPV / 今 IOPV）
    /// 加价格插值算一条，这里把同一套算法搬过来了。
    ///
    /// 只在 ETF、且**当日**分时上提供：历史某天没有那天的 78/81 字段，无从插值。
    private var estimatedIOPVLine: [IntradayLine] {
        guard holding.kind == .etf else { return [] }
        guard selectedIntradayDay.isEmpty || selectedIntradayDay == shanghaiDay(.now) else { return [] }
        // 实测点自己已经能连成线时不给估算 —— 两条线叠在一起只会互相干扰。
        let measured = selectedDayIOPVPoints.map { IntradayLine(time: $0.timestamp, price: $0.value) }
        if intradaySegmentedLines(measured).contains(where: { $0.count >= 2 }) { return [] }
        return estimatedIOPVSeries(
            points: selectedIntradayBars.map { IntradayLine(time: $0.timestamp, price: $0.price) },
            previousClose: intradayPrevClose,
            navPrev: store.marketNavPrevs[holding.code],
            navNow: selectedDayIOPV,
            priceNow: intradayLatestPrice)
    }
    private var intradayChangeText: String {
        guard let latest = intradayLatestPrice, let previous = intradayPrevClose, previous > 0 else { return "涨跌暂无" }
        let change = latest - previous
        return "\(change >= 0 ? "+" : "")\(change.num(3))  \((change / previous * 100).pct(3))"
    }

    private var minuteBuckets: [MinuteBucket] {
        let widthMinutes: Int
        switch selectedChartPeriod {
        case .intraday: widthMinutes = 1
        case .minute30: widthMinutes = 30
        default: widthMinutes = 60
        }
        let grouped = Dictionary(grouping: selectedIntradayBars) { bar in
            intradayBucketStart(bar.timestamp, code: holding.code, widthMinutes: widthMinutes)
        }
        return grouped.compactMap { start, rows in
            guard let last = rows.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let volumeRows = rows.compactMap(\.volume)
            return MinuteBucket(start: start, close: last.price,
                                volume: volumeRows.isEmpty ? nil : volumeRows.reduce(0, +))
        }.sorted { $0.start < $1.start }
    }
    /// 连续时间轴上的柱宽按点数自适应（实现已移到文件级 `intradayBarWidth(_:)`，
    /// 供独立图表类型复用）。
    private var intradayHistogramInterval: TimeInterval {
        switch selectedChartPeriod {
        case .minute30: return 30 * 60
        case .minute60: return 60 * 60
        default: return 60
        }
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
    /// 量柱涨跌配色：实现已移到文件级 `intradayVolumeColor(at:in:prevClose:)`。
    /// 那里同样要求**把当次渲染用的桶数组传进去**（不要在函数体里重新读 `minuteBuckets`）：
    /// 重读会拿到「此刻」的数组，而 ForEach 的 index 是上一刻算出来的下标 ——
    /// 盘中每 15 秒刷新一次，数组长度刚好在这两处之间变化时就会下标越界崩溃。
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
        case .automatic: return colorScheme == .dark ? .white : .black
        case .white: return .white
        case .black: return .black
        // 旧版“涨红跌绿”偏好迁移成主题单色，避免价格线颜色随方向跳变。
        case .upDown: return colorScheme == .dark ? .white : .black
        }
    }

    private var compressIntradayLunch: Bool {
        let code = holding.code.lowercased().hasPrefix("sh") || holding.code.lowercased().hasPrefix("sz") || holding.code.lowercased().hasPrefix("bj")
            ? String(holding.code.dropFirst(2)) : holding.code
        return code.count == 6 && code.allSatisfy(\.isNumber)
    }

    private func intradayChartTime(_ time: Date) -> Date {
        intradayCompressedTime(time, compressLunch: compressIntradayLunch)
    }

    private var intradayAxisTicks: [(time: Date, label: String)] {
        guard compressIntradayLunch, let day = selectedIntradayBars.first?.day else { return [] }
        // 静态缓存的解析器：这个属性每次重绘都要取值，原来每次现造一个 DateFormatter。
        let formatter = Self.minuteFormatter
        return ["09:30", "10:30", "11:30", "14:00", "15:00"].compactMap { label in
            guard let date = formatter.date(from: "\(day) \(label)") else { return nil }
            return (intradayChartTime(date), label)
        }
    }

    /// 分时横轴**固定为完整交易时段**（09:30–15:00，午休压缩到同一点）。
    ///
    /// 以前盘中会让右边界跟着「已到达的最后一根分钟线」往后延伸，图个曲线铺满绘图区。
    /// 但分时的意义恰恰是「现在走到一天的哪个位置」——横轴必须是稳定参照物。
    /// 用户反馈「有时候打开没固定，有时候打开又固定了」：那正是这个延伸逻辑在起作用
    /// （盘中有数据就延伸、数据没到就退回全天，同一时刻两次打开看到的横轴都可能不同）。
    /// 现在无条件画全天，主图、MACD 与分时量共用同一个域，时间点严格上下对齐。
    private var intradaySessionDomain: ClosedRange<Date>? {
        guard let first = selectedIntradayBars.first else { return nil }
        let formatter = Self.minuteFormatter
        let day = shanghaiDay(first.timestamp)
        guard let start = formatter.date(from: "\(day) 09:30"),
              let end = formatter.date(from: "\(day) 15:00") else { return nil }
        // 压缩午休后 15:00 会映射到 13:31，仍晚于 09:30；这里再做一次上下界保护，
        // 任何情况下都不把「下界 > 上界」的区间交给 Swift Charts（那是一定崩的）。
        let lower = min(intradayChartTime(start), intradayChartTime(end))
        let upper = max(intradayChartTime(start), intradayChartTime(end))
        guard upper > lower else { return nil }
        return lower...upper
    }

    /// 实际给图表用的横轴域：拿不到交易日就用数据自身首尾兜底（导入的历史分时可能跨夜）。
    private var intradayXDomain: ClosedRange<Date> {
        if let session = intradaySessionDomain { return session }
        let bars = selectedIntradayBars
        let first = intradayChartTime(bars.first?.timestamp ?? .now)
        let last = intradayChartTime(bars.last?.timestamp ?? .now)
        // 兜底区间同样要保证下界 < 上界：没有分时点、或数据乱序时 first/last 会相等甚至倒挂，
        // 退化区间会让图表内部缩放除零。最少给一小时可见窗口。
        let lower = min(first, last)
        let upper = max(first, last)
        if upper.timeIntervalSince(lower) < 60 { return lower...lower.addingTimeInterval(3600) }
        return lower...upper
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
    /// 30/60 分主图纵轴：与分时档**同一口径**（昨收为 0 轴、上下对称扩到今日最大涨跌幅），
    /// 切换档位时轴不会跳。拿不到昨收时才退回「跟着数据自适应 + 留余量」。
    private var minuteAggregatedPriceYDomain: ClosedRange<Double> {
        let closes = minuteBuckets.map(\.close).filter { $0.isFinite && $0 > 0 }
        guard let low = closes.min(), let high = closes.max() else { return 0...1 }
        if let domain = symmetricIntradayYDomain(low: low, high: high, previous: intradayPrevClose) {
            return domain
        }
        let ref = max(abs(low), abs(high), 0.0001)
        let spread = max(high - low, ref * 0.002)
        let pad = max(spread * 0.09, ref * 0.0006)
        return (low - pad)...(high + pad)
    }
    private var intradayPriceYDomain: ClosedRange<Double> {
        // 纵轴上下限要同时框住**价格、均价、IOPV 三条线**（用户要求：以前只按价格线定轴，
        // 现在三条线都得落在上下限里面）。
        //
        // 主口径不变：以昨收为 0 轴、按今日价格的最大涨跌幅对称铺开（和 30/60 分档同源）。
        // IOPV 打开后，高溢价品种（如纳指 ETF）的紫线可能落在这个对称区间之外，
        // 所以只在**不够的那一侧单侧补足**，能不动另一侧就不动 ——
        // 这样 IOPV 关闭时的纵轴与旧版完全一致，不会因为纳入 IOPV 就把价格线压成一条平线。
        var visible = selectedIntradayBars.map(\.price)
        if showIntradayAverage { visible += intradayAvgPoints.map(\.price) }
        var all = visible
        if showIntradayIOPV {
            all += selectedDayIOPVPoints.map(\.value)
            // 一个历史点都没有、但快照给了当前值时，把它也留进范围，免得线一出现就贴着边。
            if selectedDayIOPVPoints.isEmpty, let currentIOPV = selectedDayIOPV { all.append(currentIOPV) }
            // 估算线（插值）也要进范围：两端是真值，中间由溢价率插值决定，可能落在价格线外侧。
            all += estimatedIOPVLine.map(\.price)
        }
        let finiteAll = all.filter { $0 > 0 && $0.isFinite }
        guard let low = finiteAll.min(), let high = finiteAll.max() else { return 0...1 }
        // 三线共同范围 + 5% 边距，作为「无论如何都不能裁掉线」的保底区间。
        let tight = intradaySharedYDomain(finiteAll)
        let finiteVisible = visible.filter { $0 > 0 && $0.isFinite }
        if let vLow = finiteVisible.min(), let vHigh = finiteVisible.max(),
           let symmetric = symmetricIntradayYDomain(low: vLow, high: vHigh, previous: intradayPrevClose) {
            return min(symmetric.lowerBound, tight.lowerBound)...max(symmetric.upperBound, tight.upperBound)
        }
        return tight
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
                            Text("实时参考净值 (IOPV)：\(selectedDayIOPV?.num(4) ?? "行情源暂未提供")").foregroundStyle(.purple)
                            Text("溢价率：\(selectedDayPremium?.pct(2) ?? "暂不可用")")
                                .foregroundStyle((selectedDayPremium ?? 0) >= 0 ? .red : .green)
                        }
                        .font(.caption.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        // IOPV 曲线是**实测攒出来的**：行情源的分时接口只给价量，
                        // IOPV 只在快照里给一个当前值，没有任何「历史 IOPV」可拉。
                        // 采样天生稀疏，所以中间断开的地方就是「那段没采到」——
                        // 不再连线、也不再补一条当前值参考线（用户明确否掉）。
                        if store.isTencentETFCode(holding.code), selectedDayIOPV != nil {
                            if selectedDayIOPVPoints.count >= 2 {
                                Text("IOPV 曲线：本机实测 \(selectedDayIOPVPoints.count) 个分钟点。行情源不提供历史 IOPV，只能前台逐分钟攒；断开处就是那段没采到，不连线。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if selectedDayIOPVPoints.count == 1 {
                                Text("IOPV 只攒到 1 个点，图上画成一个小点（不够连成线）。前台每刷新一分钟就多一个点。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("这一天还没有采到 IOPV 点，图上不画 IOPV 线。历史日期的 IOPV 无法回溯补齐。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let stats = selectedDayETFQuoteSummary {
                            Text("换手 \(stats.turnoverPercent.map { $0.pct(2) } ?? "暂无")  ·  振幅 \(stats.amplitudePercent.map { $0.pct(2) } ?? "暂无")  ·  成交额 \(stats.amountYi.map { "\($0.num(2))亿" } ?? "暂无")  ·  规模 \(stats.marketCapYi.map { "\($0.num(2))亿" } ?? "暂无")")
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(2).minimumScaleFactor(0.75)
                        }
                        if selectedIntradayBars.count > 1 {
                            intradayPanel
                                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                                .listRowSeparator(.hidden)
                            Text("行情源当日分时 · 前台约 15 秒刷新 · \(minuteStatus)").font(.caption).foregroundStyle(.secondary)
                            if showIntradayIOPV, !estimatedIOPVLine.isEmpty {
                                Text("紫色 IOPV 是估算线：行情源不提供逐分钟 IOPV，这条线由「昨 IOPV / 今 IOPV」两个实测锚点加分时价格插值而来，首尾是真实值、中间是估计；本机逐分钟实测点攒够两段以上后会自动改回实测实线。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            ContentUnavailableView("暂无当日分时", systemImage: "chart.xyaxis.line", description: Text(minuteStatus))
                        }
                        HStack(spacing: 10) {
                            Button { Task { await manuallyRefreshMinute() } } label: {
                                Label(isManuallyRefreshingMinute ? "正在补齐…" : "刷新分时并补齐",
                                      systemImage: isManuallyRefreshingMinute ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("刷新并补齐当前标的分时")
                            .disabled(isManuallyRefreshingMinute)
                            Button { showIntradayCompanion = true } label: {
                                Label("盘中 AI 陪伴", systemImage: "sparkles.rectangle.stack")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if selectedChartPeriod == .minute30 || selectedChartPeriod == .minute60 {
                        if minuteBuckets.count > 1 {
                            // 30/60 分档与分时档共用同一套独立图表类型（见文件顶部注释），
                            // 这里只是换数据源、换高度、换成顶部分段选择器。
                            IntradayPanelView(
                                lines: minuteBuckets.map { IntradayLine(time: $0.start, price: $0.close) },
                                average: [], iopv: [], estimatedIOPV: [], previousClose: nil,
                                macdPoints: minuteMACD,
                                volumeBuckets: minuteBuckets,
                                volumePrevClose: intradayPrevClose,
                                histInterval: intradayHistogramInterval,
                                hasVolume: minuteBuckets.contains { $0.volume != nil },
                                volumeMAs: [],
                                volumeMASeries: [:],
                                lineColor: intradayLineColor,
                                xDomain: intradayXDomain,
                                priceYDomain: minuteAggregatedPriceYDomain,
                                macdYDomain: minuteMACDYDomain,
                                compressLunch: compressIntradayLunch,
                                ticks: intradayAxisTicks,
                                showAverage: false, showIOPV: false, showPreviousClose: false,
                                subchart: intradaySubchart,
                                mainHeight: 240, subHeight: 155, lineWidth: 1.0,
                                showsSubchartPicker: true,
                                showsSideRail: false,
                                volumeUnavailableHint: "所选分时记录没有成交量列；导入含 volume 列的 CSV 后可查看分时量。",
                                onToggleAverage: {}, onToggleIOPV: {}, onTogglePreviousClose: {},
                                onSelectSubchart: { intradaySubchart = $0 },
                                onToggleVolumeMA: { _ in })
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
            .listStyle(.plain)
            .background(.clear)
            .refreshFeedbackOverlay(refreshFeedback)
            .themedSheetBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 32).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                        guard value.startLocation.x <= 32,
                              value.translation.width >= 85,
                              abs(value.translation.height) < 70 else { return }
                        dismiss()
                    })
                    .accessibilityHidden(true)
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
                    .listStyle(.plain)
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
                // 实时接口可能返回 200 点以上但仍缺少收盘前的分钟；首次打开时仍走
                // 完整归档链路补齐，避免把 214/242 这种不完整数据误判为整日完成。
                if selectedIntradayBars.count < 242 {
                    do {
                        let completed = try await store.fetchAndArchiveLatestIntraday(code: holding.code)
                        if let day = completed.last?.day {
                            selectedIntradayDay = day
                            minuteStatus = "已补齐行情源数据：\(completed.count) 点 · \(day)"
                        }
                    } catch {
                        minuteStatus = selectedIntradayBars.isEmpty
                            ? "暂时无法补齐分时：\(error.localizedDescription)"
                            : "补齐暂不可用，继续显示本机已保存的 \(selectedIntradayBars.count) 点"
                    }
                }
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
            let savedCount = store.intradayCount(code: holding.code, day: day)
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

    /// 默认可见根数。原来默认 120 根：手机上每根槽位只有约 3pt，
    /// 量柱被压到 1.4pt 宽，密到看不出一根根柱子（用户报的「量柱太密，根本看不到」）。
    /// 收到 90 根后槽位约 4.3pt，量柱 2.6pt + 1.7pt 间隙，既能看清又不糊成一片；
    /// 想看更长区间继续双指缩小即可（最多 40 倍）。
    private static let comfortableBarCount = 90

    private var zoomedBarCount: Int {
        let comfortableDefault = min(Self.comfortableBarCount, max(1, periodAllBars.count))
        let magnification = pinchScale.isFinite ? max(0.1, pinchScale) : 1
        let zoom = chartZoom.isFinite ? max(0.1, chartZoom) : 1
        let scaledCount = Double(comfortableDefault) / (zoom * magnification)
        // 先夹到 [1, 总数] 再转 Int：`Int()` 对 NaN / 无穷大会直接 trap，
        // 手势在手势状态里给出异常 magnification 时就会把整个页面带走。
        guard scaledCount.isFinite else { return min(periodAllBars.count, comfortableDefault) }
        let clamped = min(max(scaledCount, 1), Double(max(1, periodAllBars.count)))
        return min(periodAllBars.count, max(6, Int(clamped)))
    }

    private var maxChartPanOffset: Int { max(0, periodAllBars.count - zoomedBarCount) }
    private var minimumChartZoom: Double {
        guard !periodAllBars.isEmpty else { return 1 }
        return min(1, Double(min(Self.comfortableBarCount, periodAllBars.count)) / Double(periodAllBars.count))
    }

    // MARK: - 日K 图（主图 + 成交量副图）

    // 四条均线色相尽量拉开，避免挤在相邻波段导致「看起来都是一个颜色」。
    // 色值统一放在 ChartPalette，日 K 主图与这里共用同一套，不会两处配色不一致。
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
        // 副图上方多了一排指标标签（20pt），加上 VStack 两处 8pt 间距，主图高度要相应让出 36pt
        max(180, chartBodyHeight - volumeHeight - 36)
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
        // 前复权价格可能与账本成交价略有差异，把可见 B/S 标记纳入范围，避免标记被裁掉。
        // 标记本身在最低价下方 / 最高价上方，所以这里用标记价而不是成交价。
        if selectedChartPeriod == .day {
            for marker in tradeMarkers {
                low = min(low, marker.price)
                high = max(high, marker.price)
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
        let matching = store.data.ledger.filter { $0.code == holding.code && dates.contains(shanghaiDay($0.date)) }
        // 旧备份 / 跨设备合并可能留下 id 完全相同的重复流水。日 K 上的 B/S 标记
        // 用流水 id 当 SwiftUI 标识，重复标识会让 Chart 的 ForEach 渲染异常，
        // 所以这里先按 id 去重，再按日期排序。
        let unique = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.sorted { $0.date < $1.date }
    }

    /// 日 K 上的成交标记。**B 画在当日最低价下方、S 画在当日最高价上方** ——
    /// 这是主流站点（东方财富 / 同花顺）的做法，标记完全不压在蜡烛实体和影线上。
    /// 原来直接画在成交价处，字块正好盖住 K 线本身，看不见那根是涨是跌。
    /// （`TradeMarker` 类型已移到文件级，供独立图表类型使用。）
    private var tradeMarkers: [TradeMarker] {
        guard selectedChartPeriod == .day else { return [] }
        let barsByDay = Dictionary(zoomedPeriodBars.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        return visibleTradeEntries.compactMap { entry in
            let day = shanghaiDay(entry.date)
            guard let bar = barsByDay[day] else { return nil }
            // 一字线（开=高=低）时振幅为 0，给一个按价位缩放的最小间距
            let amplitude = max(bar.high - bar.low, max(bar.high, 0.0001) * 0.004)
            let offset = amplitude * 0.38
            // 买入标在下方、卖出标在上方，且都留在 K 线之外
            let mark = entry.side == .buy ? bar.low - offset : bar.high + offset
            return TradeMarker(id: entry.id, day: day, price: mark, side: entry.side)
        }
    }

    private func transactions(on day: String) -> [LedgerEntry] {
        let matching = store.data.ledger.filter { $0.code == holding.code && shanghaiDay($0.date) == day }
        // 同 visibleTradeEntries：重复 id 的旧流水先去掉，避免 List / ForEach 标识冲突。
        return Array(Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.date < $1.date }
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
                    // 绘制实体全部在文件级独立视图里（见文件顶部注释：视图类型嵌套过深会栈溢出闪退）。
                    DailyCandleChart(
                        visible: zoomedPeriodBars,
                        maSeries: dailyMASeries,
                        markers: selectedChartPeriod == .day ? tradeMarkers : [],
                        selectedDate: selectedDailyDate,
                        selectedClose: selectedDailyBar?.close,
                        accentColor: store.effectiveAccentColor,
                        yDomain: yDomain(for: zoomedPeriodBars, full: periodAllBars),
                        bodyWidth: bodyWidth,
                        onSelect: { selectedDailyDate = $0 })
                        .frame(height: candleHeight)
                    DailySubChartTabs(selection: dailySubChart,
                        accentColor: store.effectiveAccentColor,
                        amountIsEstimated: amountIsEstimated,
                        onSelect: { dailySubChart = $0 })
                    dailySubPlot(width: barWidth).frame(height: volumeHeight)
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
                    // 手势状态异常时 translation 可能大到离谱，`Int(_:)` 超出 Int 范围会直接
                    // trap；先在安全范围内夹一次再转（拖动的可见效果不受影响）。
                    let rawStep = unapplied / pointsPerBar
                    guard rawStep.isFinite else { return }
                    let step = Int(min(max(rawStep, -1_000_000), 1_000_000))
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

    /// 可见窗口的五条均线（只在开关打开时才计算；拖动 / 捏合时每帧只算一次）。
    private var dailyMASeries: [Int: [IndicatorPoint]] {
        let visible = zoomedPeriodBars
        let full = periodAllBars
        var out: [Int: [IndicatorPoint]] = [:]
        for window in DailyCandleChart.maWindows where maVisible.contains(window) {
            out[window] = average(window, source: visible, full: full)
        }
        return out
    }

    /// 日 K 副图切换（成交量 / 成交额 / MACD）。绘制实体在文件级独立视图里。
    @ViewBuilder private func dailySubPlot(width: CGFloat) -> some View {
        switch dailySubChart {
        case .volume: DailyVolumeSubChart(bars: zoomedPeriodBars, width: width)
        case .amount: DailyAmountSubChart(bars: zoomedPeriodBars, width: width)
        case .macd: DailyMACDSubChart(series: macdSeries(full: periodAllBars, visible: zoomedPeriodBars), width: width)
        }
    }

    // MARK: - 日K 副图：成交量 / 成交额 / MACD
    //
    // 三个副图的绘制实体已抽成文件级独立视图（`DailyVolumeSubChart` / `DailyAmountSubChart` /
    // `DailyMACDSubChart`），这里只保留数据口径（MACD 序列、成交额估算）。

    /// MACD(12,26,9)，口径与 `MarketSignals` 的信号计算保持一致：
    /// DEA 用 0.2 平滑（即 EMA9），柱 = 2 ×（DIF − DEA）。
    /// **必须先用全量序列预热再截可见窗口** —— 否则窗口第一根的 DIF/DEA 从 0 起步，
    /// 开头会画出一段并不存在的金叉 / 死叉。
    private func macdSeries(full: [DailyBar], visible: [DailyBar]) -> [MACDSeriesPoint] {
        guard !full.isEmpty else { return [] }
        var ema12 = full[0].close, ema26 = full[0].close, dea = 0.0
        var all: [MACDSeriesPoint] = []
        for (index, bar) in full.enumerated() {
            ema12 = ema12 * 11 / 13 + bar.close * 2 / 13
            ema26 = ema26 * 25 / 27 + bar.close * 2 / 27
            let dif = ema12 - ema26
            dea = index == 0 ? dif : dea + 0.2 * (dif - dea)
            all.append(MACDSeriesPoint(date: bar.date, dif: dif, dea: dea, histogram: 2 * (dif - dea)))
        }
        guard let first = visible.first?.date,
              let start = all.firstIndex(where: { $0.date == first }) else { return [] }
        return Array(all[start...].prefix(visible.count))
    }

    /// 成交额是否含估算值（腾讯日 K 没有成交额列）。实体在 `DailyAmountSubChart` 里。
    private var amountIsEstimated: Bool { zoomedPeriodBars.contains { ($0.amount ?? 0) <= 0 } }

    private func quoteMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// 分时面板。**这里只组装参数，绘制实体全在文件级独立视图里** ——
    /// 原因见文件顶部那段注释：视图类型嵌套过深时，运行时解析类型名会递归几十层而栈溢出，
    /// 表现就是「点开自选卡片 / 日 K 瞬间闪退」。
    private var intradayPanel: some View {
        IntradayPanelView(
            lines: selectedIntradayBars.map { IntradayLine(time: $0.timestamp, price: $0.price) },
            average: intradayAvgPoints.map { IntradayLine(time: $0.timestamp, price: $0.price) },
            iopv: selectedDayIOPVPoints.map { IntradayLine(time: $0.timestamp, price: $0.value) },
            estimatedIOPV: estimatedIOPVLine,
            previousClose: intradayPrevClose,
            macdPoints: minuteMACD,
            volumeBuckets: minuteBuckets,
            volumePrevClose: intradayPrevClose,
            histInterval: intradayHistogramInterval,
            hasVolume: hasIntradayVolume,
            volumeMAs: intradayVolumeMAs,
            volumeMASeries: volumeMASeries,
            lineColor: intradayLineColor,
            xDomain: intradayXDomain,
            priceYDomain: intradayPriceYDomain,
            macdYDomain: minuteMACDYDomain,
            compressLunch: compressIntradayLunch,
            ticks: intradayAxisTicks,
            showAverage: showIntradayAverage,
            showIOPV: showIntradayIOPV,
            showPreviousClose: showIntradayPreviousClose,
            subchart: intradaySubchart,
            mainHeight: 300,
            subHeight: 165,
            lineWidth: 1.15,
            showsSubchartPicker: false,
            showsSideRail: true,
            volumeUnavailableHint: "行情源尚未返回成交量；完整分钟线到达后会自动补上。",
            onToggleAverage: { showIntradayAverage.toggle(); IntradayVisibility.write(average: showIntradayAverage) },
            onToggleIOPV: { showIntradayIOPV.toggle(); IntradayVisibility.write(iopv: showIntradayIOPV) },
            onTogglePreviousClose: { showIntradayPreviousClose.toggle(); IntradayVisibility.write(previousClose: showIntradayPreviousClose) },
            onSelectSubchart: { intradaySubchart = $0 },
            onToggleVolumeMA: { period in
                if intradayVolumeMAs.contains(period) { intradayVolumeMAs.remove(period) } else { intradayVolumeMAs.insert(period) }
                IntradayVisibility.write(volumeMAs: intradayVolumeMAs)
            })
    }

    /// 已打开的量均线序列（没开的周期不计算）。
    private var volumeMASeries: [Int: [IntradayVolumeMAPoint]] {
        var out: [Int: [IntradayVolumeMAPoint]] = [:]
        for period in intradayVolumeMAs { out[period] = intradayVolumeMA(period) }
        return out
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
            let isUS = symbol.lowercased().hasPrefix("us")
            let path = isUS ? "usMinute" : "minute"
            for host in (isUS ? ["web.ifzq.gtimg.cn"] : ["web.ifzq.gtimg.cn", "ifzq.gtimg.cn"]) {
                let variable = "min_data_\(Int(Date().timeIntervalSince1970 * 1000))"
                guard let url = URL(string: "https://\(host)/appstock/app/\(path)/query?_var=\(variable)&code=\(symbol)") else { continue }
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
            var parsed = sourceBars.map {
                IntradayBar(code: holding.code, timestamp: $0.timestamp, price: $0.price,
                            volume: $0.volume, day: $0.day)
            }
            let day = parsed.last?.day ?? today
            var root: [String: Any]?
            if let raw = String(data: data, encoding: .utf8),
               let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
               start <= end,
               let decoded = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] {
                root = decoded
            }
            // 腾讯分时响应另含 ETF 汇总行情 qt；折溢价率字段为百分数。
            // 仅在品种确认为 ETF 且数值有效时计算 IOPV，缺字段不以昨收净值代替。
            let quoteValues = (root?["qt"] as? [String: Any]).flatMap { qt in
                (qt[symbol] ?? qt.first(where: { $0.key.caseInsensitiveCompare(symbol) == .orderedSame })?.value) as? [Any]
            }
            var resolvedIOPVFromMinute = false
            if let values = quoteValues, store.isTencentETFCode(holding.code) {
                func field(_ index: Int) -> Double? {
                    guard values.indices.contains(index) else { return nil }
                    if let text = values[index] as? String { return store.parseTencentNumericField(text) }
                    return (values[index] as? NSNumber)?.doubleValue
                }
                let amountInTenThousands = field(37)
                intradayETFQuoteSummary = IntradayETFQuoteSummary(
                    turnoverPercent: field(38), amplitudePercent: field(43),
                    amountYi: amountInTenThousands.map { $0 / 10_000 }, marketCapYi: field(44))
                intradayETFQuoteSummaryDay = day
                // 腾讯 ETF qt：下标 77 是折溢价率，下标 78 是净值参考；
                // 下标 63 是其他指标，不能拿来代替。优先直读 78，缺失时才由 77 反推。
                let lastPrice = parsed.last?.price
                let premium = field(77).flatMap { $0.isFinite && $0 > -100 ? $0 : nil }
                let rawIOPV = field(78).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                let derivedIOPV = premium.flatMap { premium -> Double? in
                    guard let last = lastPrice, last.isFinite, last > 0, 1 + premium / 100 > 0 else { return nil }
                    let value = last / (1 + premium / 100)
                    return value.isFinite && value > 0 ? value : nil
                }
                if let iopv = rawIOPV ?? derivedIOPV {
                    resolvedIOPVFromMinute = true
                    intradayIOPV = iopv
                    if let premium { intradayPremiumPercent = premium }
                    if let time = parsed.last?.timestamp {
                        let currentDay = parsed.last?.day ?? day
                        if intradayIOPVDay != currentDay { intradayIOPVPoints = [] }
                        intradayIOPVDay = currentDay
                        intradayIOPVPoints.removeAll { Calendar.current.isDate($0.timestamp, equalTo: time, toGranularity: .minute) }
                        intradayIOPVPoints.append(IntradayIOPVPoint(timestamp: time, value: iopv))
                        if let index = parsed.indices.last { parsed[index].iopv = iopv }
                        if intradayIOPVPoints.count > 400 { intradayIOPVPoints.removeFirst(intradayIOPVPoints.count - 400) }
                    }
                }
            }
            // 分时接口有时只返回分钟线、不带 qt 汇总字段；独立查询腾讯实时 ETF 报价补 IOPV。
            // 最多每分钟尝试一次，避免每个 15 秒刷新周期额外等待行情请求。
            let shouldRetryIOPV = lastIOPVFallbackAt.map { Date.now.timeIntervalSince($0) >= 60 } ?? true
            if holding.kind == .etf, !resolvedIOPVFromMinute, shouldRetryIOPV {
                lastIOPVFallbackAt = .now
                if let snapshot = try? await store.lookupETFRealtimeIOPV(code: holding.code) {
                    intradayIOPV = snapshot.value
                    intradayPremiumPercent = snapshot.premiumPercent
                    if intradayIOPVDay != day { intradayIOPVPoints = [] }
                    intradayIOPVDay = day
                    let time = snapshot.updatedAt ?? parsed.last?.timestamp ?? .now
                    intradayIOPVPoints.removeAll { Calendar.current.isDate($0.timestamp, equalTo: time, toGranularity: .minute) }
                    intradayIOPVPoints.append(IntradayIOPVPoint(timestamp: time, value: snapshot.value))
                    if let index = parsed.indices.last, parsed[index].day == shanghaiDay(time) {
                        parsed[index].iopv = snapshot.value
                    }
                    if intradayIOPVPoints.count > 400 { intradayIOPVPoints.removeFirst(intradayIOPVPoints.count - 400) }
                }
            }
            store.mergeIntradayBars(parsed)
            selectedIntradayDay = day
            minuteStatus = day == today
                ? "更新于 \(Date.now.formatted(date: .omitted, time: .shortened))"
                : (store.isMarketClosedToday ? "休市 · 最近交易日 \(day)" : "尚未开盘 · 最近交易日 \(day)")
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

    /// 上海时区的 `yyyy-MM-dd`。直接复用 `MarketCalendar` 里那个缓存好的格式化器 ——
    /// 本函数会被 ledger / 分时点**逐条**调用，原来自建 `DateFormatter` 等于每次几十微秒。
    private func shanghaiDay(_ date: Date) -> String {
        MarketCalendar.isoDay(date)
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

// MARK: - 图表共用配色与宽度

/// 均线配色单一数据源。日 K 主图从这里取，避免两处配色漂移。
/// 「日线周期聚合」memo（周 K / 月 K 用）。
///
/// 一次 `body` 里 `periodBars` / `periodAllBars` 会被取十几次（均线、支撑压力、
/// 副图、刻度…），而周 / 月聚合每次都要把每根日线的日期字符串解析一遍再分组排序 ——
/// 640 根 × 十几次就是几千次日期解析，捏合缩放 / 拖动时**逐帧**都付这个钱。
/// 这里按「标的 + 周期 + 源序列边界」缓存结果；日线一变（新交易日、盘中刷新末根）
/// 键就变，自然失效，不需要手动清理。只保留最近 12 条，避免逛过很多标的后长驻内存。
///
/// 全部调用都在主线程（SwiftUI 视图是 `@MainActor`），所以这里是单线程状态。
@MainActor
private enum ChartAggregationMemo {
    private static var storage: [String: [DailyBar]] = [:]
    private static var order: [String] = []

    static func value(key: String, build: () -> [DailyBar]) -> [DailyBar] {
        if let hit = storage[key] { return hit }
        let built = build()
        storage[key] = built
        order.append(key)
        while order.count > 12 {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return built
    }
}

private enum ChartPalette {
    static let ma5 = Color(red: 1.0, green: 0.62, blue: 0.11)    // 橙
    static let ma10 = Color(red: 0.30, green: 0.66, blue: 1.0)   // 蓝
    static let ma20 = Color(red: 0.80, green: 0.36, blue: 1.0)   // 紫
    static let ma60 = Color(red: 0.16, green: 0.88, blue: 0.76)  // 青绿
    static let ma250 = Color(red: 0.96, green: 0.35, blue: 0.58) // 玫红

    /// 买卖标记配色：刻意避开 K 线的红涨绿跌。
    /// 之前 B 用红、S 用绿，和蜡烛图完全撞色，标记压在实体上根本分不清哪个是成交点。
    static let buyMark = Color(red: 0.98, green: 0.72, blue: 0.18)   // 琥珀金
    static let sellMark = Color(red: 0.40, green: 0.48, blue: 0.95)  // 蓝紫

    /// 按均线窗口取色。日 K 主图用 `ForEach` 遍历窗口列表统一画五条线（比写五段 `if` 类型嵌套更浅）。
    static func color(forMA window: Int) -> Color {
        switch window {
        case 5: return ma5
        case 10: return ma10
        case 20: return ma20
        case 60: return ma60
        default: return ma250
        }
    }
}

/// K 线实体与量柱的宽度口径（日 K 主图与量能副图共用）。
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
    /// 0.46 → 0.60、下限 1.4 → 2.0：默认 90 根时槽位约 4.3pt，
    /// 量柱 2.6pt + 1.7pt 间隙 —— 原来 1.4pt 的细柱在手机上密到看不见。
    static func volume(slot: CGFloat) -> CGFloat {
        min(max(slot * 0.60, 2.0), 18)
    }
}
