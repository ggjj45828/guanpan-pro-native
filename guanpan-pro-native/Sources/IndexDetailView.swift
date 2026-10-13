import SwiftUI

/// 指数详情页：分时 / 日 K + 均线。
///
/// **为什么不复用 `MarketChartView`**：那个页面是给持仓看的，绑定了成本、浮动盈亏、
/// 网格计划、IOPV 折溢价这些东西 —— 指数没有成本，这些格子只会是空的或算错的。
/// 这里只保留「看走势」需要的部分，涨跌口径与首页那张指数卡完全一致
/// （红涨绿跌、恒带 ▲▼）。
struct IndexDetailView: View {
    let index: MarketIndexQuote

    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var tab: Tab = .intraday
    @State private var minutes: [IntradayBar] = []
    @State private var bars: [DailyBar] = []
    @State private var status = "正在加载…"
    @State private var isLoading = true
    /// 日 K 只画最近这么多根 —— 一屏塞 300 根蜡烛，每根不到一个像素，看不出形态。
    @State private var visibleCount = 120

    enum Tab: String, CaseIterable, Identifiable {
        case intraday = "分时"
        case daily = "日K"
        var id: String { rawValue }
    }

    private var tone: Color { PnLColor.of(index.changePct) }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var gridColor: Color { Color.primary.opacity(isLight ? 0.10 : 0.16) }

    /// 昨收。指数当前价与涨跌幅都在手里，反推即可 —— 和 `dayPnL(of:)` 用的是同一套算法。
    private var previousClose: Double {
        let pct = index.changePct
        guard pct.isFinite, abs(pct) > 0.000001, (1 + pct) != 0 else { return index.price }
        return index.price / (1 + pct)
    }

    private var displayedBars: [DailyBar] {
        Array(bars.suffix(max(20, visibleCount)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 230)
                    } else if minutes.isEmpty && bars.isEmpty {
                        unavailableSection
                    } else if tab == .intraday {
                        intradaySection
                    } else {
                        dailySection
                    }

                    indicatorGrid

                    Text(status)
                        .scaledFont(10).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .navigationTitle(index.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isLoading = true; Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .task { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        let change = index.price - previousClose
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(index.price.num(2))
                    .scaledFont(30, weight: .bold, design: .rounded)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(tone)
                Text("\(change.directionMark()) \(change.num(2))")
                    .scaledFont(14, weight: .semibold).monospacedDigit()
                    .foregroundStyle(tone)
                Text("\((index.changePct * 100).pct(2))")
                    .scaledFont(14, weight: .semibold).monospacedDigit()
                    .foregroundStyle(tone)
                Spacer(minLength: 0)
            }
            Text(quoteTimeText)
                .scaledFont(10).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index.name) \((index.price).num(2))，\(spokenDirection(change)) \((abs(change)).num(2))，\((index.changePct * 100).pct(2))")
    }

    /// 行情时点。休市时行情源给的是上一交易日收盘价，必须写出来，否则会被当成实时。
    private var quoteTimeText: String {
        guard let date = index.updatedAt else { return "行情源未提供时间戳" }
        let day = shortDay(date)
        let today = shortDay(Date())
        if day != today { return "休市 · \(day) 收盘" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return "\(day) \(formatter.string(from: date))"
    }

    // MARK: - 分时

    private var intradaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if minutes.count < 2 {
                Text(minutes.isEmpty ? "暂无分时数据。该市场可能还没开盘，或数据源未返回。" : "分时点不足，无法成线。")
                    .scaledFont(11).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                intradayPlot
                intradayAxis
            }
        }
    }

    private var intradayPlot: some View {
        let closes = minutes.map(\.price)
        let base = previousClose
        // 以昨收为中心**对称**取值域：分时图的视觉重心就是涨跌，上下不对称会放大或缩小涨跌感。
        let span = max((closes.map { abs($0 - base) }.max() ?? 0) * 1.18, base * 0.0016, 0.0001)
        let lo = base - span, hi = base + span
        let volumes = minutes.map { $0.volume ?? 0 }
        let maxVolume = max(volumes.max() ?? 1, 1)

        return HStack(alignment: .top, spacing: 6) {
            // 左侧刻度：上/昨收/下
            VStack(alignment: .trailing) {
                Text(hi.num(2)); Spacer(); Text(base.num(2)); Spacer(); Text(lo.num(2))
            }
            .scaledFont(9).foregroundStyle(.secondary).monospacedDigit()
            .frame(width: 54, height: 168)

            VStack(spacing: 3) {
                GeometryReader { geo in
                    let size = geo.size
                    ZStack {
                        // 昨收虚线 + 上下四分位参考线
                        Path { path in
                            for ratio in [0.25, 0.5, 0.75] {
                                let y = size.height * ratio
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                        }
                        .stroke(gridColor, style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))

                        linePath(closes, size: size, lo: lo, hi: hi)
                            .stroke(tone, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 168)

                // 成交量柱
                GeometryReader { geo in
                    let size = geo.size
                    let step = size.width / CGFloat(max(volumes.count, 1))
                    ZStack(alignment: .bottomLeading) {
                        ForEach(Array(volumes.enumerated()), id: \.offset) { item in
                            let height = size.height * CGFloat(item.element / maxVolume)
                            let rising = item.offset == 0
                                ? minutes[item.offset].price >= base
                                : minutes[item.offset].price >= minutes[item.offset - 1].price
                            Rectangle()
                                .fill((rising ? Color.red : Color.green).opacity(0.55))
                                .frame(width: max(0.6, step * 0.72), height: max(0.5, height))
                                .offset(x: step * CGFloat(item.offset) + step * 0.14,
                                        y: size.height - max(0.5, height))
                        }
                    }
                }
                .frame(height: 40)
            }
        }
    }

    private var intradayAxis: some View {
        // 横轴标签按真实分时数据的首/中/尾时间生成，不再给港股、美股硬套 A 股 09:30–15:00。
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        fmt.dateFormat = "HH:mm"
        let times = minutes.map(\.timestamp)
        let start = times.first.map { fmt.string(from: $0) } ?? "--:--"
        let end = times.last.map { fmt.string(from: $0) } ?? "--:--"
        let mid: String = {
            guard let f = times.first, let l = times.last else { return "--:--" }
            return fmt.string(from: f.addingTimeInterval(l.timeIntervalSince(f) / 2))
        }()
        return HStack {
            Text(start)
            Spacer()
            Text(mid)
            Spacer()
            Text(end)
        }
        .scaledFont(9).foregroundStyle(.secondary)
        .padding(.leading, 60)
    }

    // MARK: - 日 K

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if displayedBars.count < 2 {
                Text("暂无日 K 数据。")
                    .scaledFont(11).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                dailyPlot
                dailyAxis
            }
        }
    }

    private var dailyPlot: some View {
        let shown = displayedBars
        let closes = bars.map(\.close)
        let ma5 = movingAverage(closes, period: 5)
        let ma10 = movingAverage(closes, period: 10)
        let ma20 = movingAverage(closes, period: 20)
        let ma60 = movingAverage(closes, period: 60)
        let start = bars.count - shown.count

        var lo = shown.map(\.low).min() ?? 0
        var hi = shown.map(\.high).max() ?? 1
        // 均线可能跑到蜡烛区间外（比如急跌后的 MA60），要一起纳入值域，否则线会画到框外。
        for series in [ma5, ma10, ma20, ma60] {
            // 变量名不叫 index：这个类型里 `index` 是持有的那只指数，遮蔽掉容易埋雷。
            for cursor in start..<bars.count where cursor < series.count {
                if let value = series[cursor] { lo = min(lo, value); hi = max(hi, value) }
            }
        }
        if hi <= lo { hi = lo + 1 }
        let pad = (hi - lo) * 0.06
        lo -= pad; hi += pad

        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing) {
                Text(hi.num(2)); Spacer(); Text(((hi + lo) / 2).num(2)); Spacer(); Text(lo.num(2))
            }
            .scaledFont(9).foregroundStyle(.secondary).monospacedDigit()
            .frame(width: 54, height: 200)

            GeometryReader { geo in
                let size = geo.size
                let step = size.width / CGFloat(max(shown.count, 1))
                let bodyWidth = max(1, step * 0.62)
                ZStack {
                    Path { path in
                        for ratio in [0.25, 0.5, 0.75] {
                            let y = size.height * ratio
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(gridColor, style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))

                    // 蜡烛
                    ForEach(Array(shown.enumerated()), id: \.offset) { item in
                        let x = step * (CGFloat(item.offset) + 0.5)
                        let bar = item.element
                        let up = bar.close >= bar.open
                        let color = up ? PnLColor.up : PnLColor.down
                        let yHigh = yFor(bar.high, size: size, lo: lo, hi: hi)
                        let yLow = yFor(bar.low, size: size, lo: lo, hi: hi)
                        let yOpen = yFor(bar.open, size: size, lo: lo, hi: hi)
                        let yClose = yFor(bar.close, size: size, lo: lo, hi: hi)
                        Path { path in
                            path.move(to: CGPoint(x: x, y: yHigh))
                            path.addLine(to: CGPoint(x: x, y: yLow))
                        }
                        .stroke(color, lineWidth: 0.7)
                        Path { path in
                            path.addRect(CGRect(x: x - bodyWidth / 2, y: min(yOpen, yClose),
                                                width: bodyWidth, height: max(0.8, abs(yClose - yOpen))))
                        }
                        .fill(color)
                    }

                    // 四条均线取同一套颜色口径，和 K 线页保持一致
                    ForEach(Array(movingLineSources().enumerated()), id: \.offset) { item in
                        linePath(item.element.points, size: size, lo: lo, hi: hi, start: start)
                            .stroke(item.element.color, lineWidth: 1)
                    }
                }
            }
            .frame(height: 200)
        }
    }

    private var dailyAxis: some View {
        HStack(spacing: 10) {
            Text(displayedBars.first?.date ?? "")
            Spacer()
            Text(displayedBars.last?.date ?? "")
        }
        .scaledFont(9).foregroundStyle(.secondary)
        .padding(.leading, 60)
    }

    /// 四条均线的值 + 颜色。统一在这里给，避免图例和线本身的颜色对不上。
    private func movingLineSources() -> [(points: [Double], color: Color)] {
        let closes = bars.map(\.close)
        // 均线在起点处是缺失的，用首根收盘价补平，否则线会从半空中开始。
        func filled(_ period: Int, _ color: Color) -> (points: [Double], color: Color) {
            let series = movingAverage(closes, period: period)
            let fallback = closes.first ?? 0
            return (series.map { $0 ?? fallback }, color)
        }
        return [
            filled(5, Color(red: 0.98, green: 0.68, blue: 0.20)),
            filled(10, Color(red: 0.35, green: 0.68, blue: 0.98)),
            filled(20, Color(red: 0.72, green: 0.48, blue: 0.92)),
            filled(60, Color(red: 0.42, green: 0.78, blue: 0.62))
        ]
    }

    // MARK: - 指标区

    private var indicatorGrid: some View {
        let closes = bars.map(\.close)
        let ma5 = movingAverage(closes, period: 5).last ?? nil
        let ma10 = movingAverage(closes, period: 10).last ?? nil
        let ma20 = movingAverage(closes, period: 20).last ?? nil
        let ma60 = movingAverage(closes, period: 60).last ?? nil
        return VStack(alignment: .leading, spacing: 8) {
            Text("均线位置").scaledFont(11, weight: .medium)
            HStack(spacing: 10) {
                maCell("MA5", ma5)
                maCell("MA10", ma10)
                maCell("MA20", ma20)
                maCell("MA60", ma60)
            }
            if let ma20, let first = bars.last {
                Text(maPositionText(close: first.close, ma20: ma20, ma60: ma60))
                    .scaledFont(10).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .cardSurface()
    }

    private func maCell(_ title: String, _ value: Double?) -> some View {
        let above = value.map { index.price >= $0 }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(10).foregroundStyle(.secondary)
            Text(value.map { $0.num(2) } ?? "--")
                .scaledFont(12, weight: .semibold, design: .rounded).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(above.map { $0 ? PnLColor.up : PnLColor.down } ?? Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 用「现价站在哪几条均线之上」给一句人话结论，比单纯列数字好读。
    ///
    /// 别写成 `(close >= ma20 ? above : below).append("MA20")` ——
    /// 三元表达式的结果是**不可变**的临时值，`append` 会报
    /// 「cannot use mutating member on immutable value: result of conditional operator」。
    private func maPositionText(close: Double, ma20: Double?, ma60: Double?) -> String {
        var above: [String] = []
        var below: [String] = []
        if let ma20 {
            if close >= ma20 { above.append("MA20") } else { below.append("MA20") }
        }
        if let ma60 {
            if close >= ma60 { above.append("MA60") } else { below.append("MA60") }
        }
        if above.isEmpty && below.isEmpty { return "日 K 样本不足，还不能判断均线位置。" }
        if below.isEmpty { return "现价站在 \(above.joined(separator: "、")) 之上，中期结构偏强。" }
        if above.isEmpty { return "现价跌到 \(below.joined(separator: "、")) 之下，中期结构偏弱。" }
        return "现价在 \(above.joined(separator: "、")) 之上、\(below.joined(separator: "、")) 之下，处在均线纠缠区。"
    }

    // MARK: - 绘制辅助

    private func yFor(_ value: Double, size: CGSize, lo: Double, hi: Double) -> CGFloat {
        guard hi > lo else { return size.height / 2 }
        return size.height * (1 - CGFloat((value - lo) / (hi - lo)))
    }

    /// `start` 用来把「全量序列上的某个区间」映射到当前画布上（日 K 只画末尾一段）。
    private func linePath(_ values: [Double], size: CGSize, lo: Double, hi: Double, start: Int = 0) -> Path {
        var path = Path()
        let slice: ArraySlice<Double>
        if start > 0 {
            guard start < values.count else { return path }
            slice = values[start...]
        } else {
            slice = values[...]
        }
        guard slice.count > 1 else { return path }
        let step = size.width / CGFloat(slice.count - 1)
        for (offset, value) in slice.enumerated() {
            let point = CGPoint(x: step * CGFloat(offset), y: yFor(value, size: size, lo: lo, hi: hi))
            offset == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func movingAverage(_ values: [Double], period: Int) -> [Double?] {
        guard period > 0, values.count >= period else {
            return Array(repeating: nil, count: values.count)
        }
        var out: [Double?] = Array(repeating: nil, count: values.count)
        var sum = 0.0
        for index in values.indices {
            sum += values[index]
            if index >= period { sum -= values[index - period] }
            if index >= period - 1 { out[index] = sum / Double(period) }
        }
        return out
    }

    // MARK: - 取数

    @MainActor private func load() async {
        guard isLoading else { return }
        // 不再用「有没有腾讯代码」提前拦请求：日经 / 东证 / 韩国没有腾讯代码，
        // 但只要发请求，store 内部会依次尝试 腾讯 → 东方财富 → NAS 代理，
        // 东财 / NAS 兜底因此能真正被执行，而不是在请求前被跳过。
        async let minuteResult = store.fetchIndexMinutes(quote: index)
        async let barResult = store.fetchIndexDailyBars(quote: index, count: 320)
        let (minuteBars, dailyBars) = await (minuteResult, barResult)
        minutes = minuteBars.sorted { $0.timestamp < $1.timestamp }
        bars = dailyBars
        isLoading = false

        if !minuteBars.isEmpty, let day = minuteBars.last?.day {
            let isToday = day == shortDayDate(Date())
            status = isToday ? "分时 \(minuteBars.count) 个点 · 实时" : "分时 \(minuteBars.count) 个点 · 休市，显示 \(day) 的分时"
        } else if !dailyBars.isEmpty {
            status = "日 K \(dailyBars.count) 根，最新 \(dailyBars.last?.date ?? "--")"
        } else {
            status = "数据源未返回该指数的行情。"
        }
    }

    /// 这个指数有没有可用的历史行情源。
    ///
    /// 实测结论：腾讯 `ifzq` 的日 K / 分时只覆盖 A 股、港股、美股；
    /// 日经 225、东证 TOPIX、韩国 KOSPI 三条在所有源上都只有实时快照。
    /// 与其让用户点进来看到一张空白图，不如说清「它本来就没有」。
    private var hasHistorySource: Bool {
        MarketIndexStore.catalog.first { $0.secid == index.symbol }?.tencent != nil
    }

    /// 没有历史数据时的占位说明。
    private var unavailableSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("暂无分时与日 K")
                .scaledFont(15, weight: .semibold)
            Text("日经 225、东证 TOPIX、韩国 KOSPI 目前只能取到实时价与涨跌幅（见上方数字），历史曲线暂时没有可用的公开接口。指数条上的价格是准的，只是画不出线。")
                .scaledFont(12).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.horizontal, 8)
    }

    /// `yyyy-MM-dd` 形态的「今天」。
    private func shortDayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
