import SwiftUI
import Charts

/// 把代码统一到「去掉 sh / sz / bj 前缀、小写」的写法。
/// 文件级：档案页的行渲染与抽出的子视图都要用，跨类型时私有成员不可见。
func archiveNormalizedCode(_ value: String) -> String {
    let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for prefix in ["sh", "sz", "bj"] where code.hasPrefix(prefix) { return String(code.dropFirst(2)) }
    return code
}

/// 档案页 Picker 用的标的（文件级：页面级嵌套类型在抽出的子视图里不可见）。
private struct IntradayArchiveInstrument: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

/// 档案页里三份「按全量数据算」的结果，按输入指纹做一层单槽缓存。
///
/// **为什么需要**：`instruments`（建名字表 + 排序）、`coverageByCode`（每个标的取最新交易日
/// → O(标的 × 交易日)）、`tradePoints`（每条流水都要在 242 个分钟点里找最近一分钟
/// → O(流水 × 242)）原来都是页面级的计算属性，**只要本页 `body` 重跑就整套重算**。
/// 而这一页的 body 会被两类事件反复触发：拖动主图选择线（每秒几十次）、
/// store 每 10~15 秒发布一次行情。用户 2026-10-14 反馈的「分时档案一卡一卡」就是它。
/// 现在把三者收进一个按指纹缓存的结果里，指纹不变就是 O(1)。
@MainActor
private enum IntradayArchiveMemo {
    struct Payload {
        var instruments: [IntradayArchiveInstrument] = []
        var coverage: [String: (day: String?, count: Int, iopvCount: Int)] = [:]
        var trades: [IntradayChartTradeMarker] = []
    }

    private static var key = ""
    private static var cached = Payload()

    static func value(_ version: String, build: () -> Payload) -> Payload {
        if version == key { return cached }
        let made = build()
        key = version
        cached = made
        return made
    }
}

/// 档案页主图 + 选择线。**必须独立成类型**：
/// 选择态（长按 / 拖动看分钟值）原来挂在 `IntradayArchiveView` 上，拖动时每秒会触发
/// 几十次**页面级** `body` 重算 —— 均价、MACD、流水标记、覆盖统计全跟着重跑，
/// 这正是「分时档案一卡一卡」里最直白的一块。把选择态收进这个子视图后，
/// 拖动只重画图表本身，父视图一次都不重算。
private struct ArchivePriceChart: View {
    let bars: [IntradayBar]
    let lines: [IntradayLine]
    let average: [IntradayLine]
    let iopv: [IntradayLine]
    let tradeMarkers: [IntradayChartTradeMarker]
    let lineColor: Color
    let xDomain: ClosedRange<Date>
    let yDomain: ClosedRange<Double>
    let ticks: [(time: Date, label: String)]
    let compressLunch: Bool
    let showAverage: Bool
    let showIOPV: Bool
    @State private var selectedTime: Date?

    private func chartTime(_ time: Date) -> Date {
        intradayCompressedTime(time, compressLunch: compressLunch)
    }

    /// 选中点最近的分钟值。只在**本视图**重算 —— 父视图不读 `selectedTime`。
    private var selectionLabel: String {
        guard let selectedTime else { return "" }
        let nearest = bars.min {
            abs(chartTime($0.timestamp).timeIntervalSince(selectedTime))
                < abs(chartTime($1.timestamp).timeIntervalSince(selectedTime))
        }
        guard let bar = nearest else { return "" }
        return "\(bar.timestamp.formatted(date: .omitted, time: .shortened))  \(bar.price.num(4))"
    }

    var body: some View {
        IntradayMainChart(
            lines: lines,
            average: average,
            iopv: iopv,
            estimatedIOPV: [],
            previousClose: nil,
            showAverage: showAverage,
            showIOPV: showIOPV,
            showPreviousClose: false,
            lineColor: lineColor,
            xDomain: xDomain,
            yDomain: yDomain,
            ticks: ticks,
            compressLunch: compressLunch,
            height: 300,
            lineWidth: 1.15,
            selection: $selectedTime,
            selectionLabel: selectionLabel.isEmpty ? nil : selectionLabel,
            tradeMarkers: tradeMarkers
        )
    }
}

/// 分时采集、每日归档和历史复盘的统一入口。
/// 只展示真实落盘数据；没有采到的分钟不会插值伪造。
struct IntradayArchiveView: View {
    @EnvironmentObject private var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCode = ""
    @State private var selectedDay = ""
    @State private var subchart: Subchart = .volume
    /// 主图线条开关。和持仓分时页共用同一份偏好（`IntradayVisibility` 存在 UserDefaults 里），
    /// 所以在哪一页切换，另一页跟着变。价格线是基准，不提供关闭。
    @State private var showAverageLine = IntradayVisibility.showAverage
    @State private var showIOPVLine = IntradayVisibility.showIOPV

    private enum Subchart: String, CaseIterable, Identifiable {
        case volume = "分时量"
        case macd = "分时 MACD"
        var id: String { rawValue }
    }

    private struct AveragePoint: Identifiable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    private struct MACDPoint: Identifiable {
        let time: Date
        let dif: Double
        let dea: Double
        let histogram: Double
        var id: Date { time }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    /// 按屏幕宽度和实际点数计算柱宽：少量数据不会变成细线，全天 242 点也不会互相盖住。
    private func minuteBarWidth(_ count: Int) -> CGFloat {
        let plotWidth = max(220, UIScreen.main.bounds.width - 72)
        return min(10, max(1.8, plotWidth / CGFloat(max(count, 1)) * 0.82))
    }
    private var priceLineColor: Color {
        switch store.data.intradayLineColorMode {
        case .automatic: return isLight ? .black : .white
        case .white: return .white
        case .black: return .black
        // 旧版涨跌着色偏好只兼容读取；历史价格线统一跟随主题单色。
        case .upDown: return isLight ? .black : .white
        }
    }

    /// 三份「按全量数据算」的结果（标的表 / 覆盖统计 / 流水标记）统一走一层带指纹的缓存。
    ///
    /// 指纹只覆盖真正会影响它们的输入：档案条数、覆盖统计条数、流水条数、自选与持仓条数、
    /// 当前选中的标的与交易日。这些没变就直接返回上次的结果（O(1)）。
    private var archivePayload: IntradayArchiveMemo.Payload {
        let version = "\(store.intradayBars.count)|\(store.intradayCoverageByCode.count)"
            + "|\(store.data.ledger.count)|\(store.data.quotes.count)|\(store.data.holdings.count)"
            + "|\(selectedCode)|\(selectedDay)|\(resolvedCode)"
        return IntradayArchiveMemo.value(version) {
            var names: [String: String] = [:]
            for quote in store.data.quotes { names[quote.code] = quote.name.isEmpty ? quote.code : quote.name }
            for holding in store.data.holdings where holding.kind == .etf {
                names[holding.code] = holding.name.isEmpty ? holding.code : holding.name
            }
            let instruments = names.map { IntradayArchiveInstrument(code: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            var coverage: [String: (day: String?, count: Int, iopvCount: Int)] = [:]
            for (code, days) in store.intradayCoverageByCode {
                guard let latest = days.keys.max(), let entry = days[latest] else { continue }
                coverage[code] = (latest, entry.points, entry.iopvPoints)
            }

            let markers = Self.tradeMarkers(bars: store.intradayBars(code: resolvedCode, day: selectedDay),
                                            code: selectedCode, day: selectedDay,
                                            ledger: store.data.ledger)
            return IntradayArchiveMemo.Payload(instruments: instruments, coverage: coverage, trades: markers)
        }
    }
    private var instruments: [IntradayArchiveInstrument] { archivePayload.instruments }
    private var coverageByCode: [String: (day: String?, count: Int, iopvCount: Int)] { archivePayload.coverage }
    /// 当日流水在分时图上的标记（B / S）。
    private var tradePoints: [IntradayChartTradeMarker] { archivePayload.trades }

    /// 每条流水在当日分时里找最近的一分钟。**只在这份缓存被重建时跑一次**，
    /// 不再像以前那样挂在页面计算属性上、拖一下主图就重算一遍（O(流水 × 242)）。
    private static func tradeMarkers(bars: [IntradayBar], code: String, day: String,
                                     ledger: [LedgerEntry]) -> [IntradayChartTradeMarker] {
        guard !bars.isEmpty else { return [] }
        let target = archiveNormalizedCode(code)
        var result: [IntradayChartTradeMarker] = []
        for trade in ledger where archiveNormalizedCode(trade.code) == target
            && shanghaiDay(trade.date) == day {
            guard let nearest = bars.min(by: {
                abs($0.timestamp.timeIntervalSince(trade.date)) < abs($1.timestamp.timeIntervalSince(trade.date))
            }) else { continue }
            result.append(IntradayChartTradeMarker(
                id: trade.id,
                time: nearest.timestamp,
                price: trade.price > 0 ? trade.price : nearest.price,
                isBuy: trade.side == .buy))
        }
        return result
    }

    /// 覆盖统计。从 store 的「code|day」索引直接读，只做 O(标的 × 交易日) 次字典操作。
    ///
    /// 旧实现每帧遍历整份分钟档案，并为每个「标的 + 交易日」新建一个 Set 去重 ——
    /// 档案攒到几十万个点以后，光这一项就够把这一页拖到滑不动。分时点在入库时
    /// 已经按「代码 + 自然分钟」去过重，所以这里直接取条数即可，不必再建 Set。
    /// 现在由 `archivePayload` 带指纹缓存（见那里的说明）。

    /// 把用户选中的代码解析成档案里实际存的那个写法
    /// （档案可能存的是 `sh510300`，而选择器里是 `510300`）。
    private var resolvedCode: String {
        let target = archiveNormalizedCode(selectedCode)
        return store.intradayCodes.first { archiveNormalizedCode($0) == target } ?? selectedCode
    }

    private var days: [String] {
        store.intradayDays(forCode: resolvedCode)
    }

    private var bars: [IntradayBar] {
        store.intradayBars(code: resolvedCode, day: selectedDay)
    }

    private func normalizedCode(_ value: String) -> String { archiveNormalizedCode(value) }

    private var compressLunchBreak: Bool {
        let code = normalizedCode(selectedCode)
        return code.count == 6 && code.allSatisfy(\.isNumber)
    }

    /// A 股坐标把 11:30–13:00 午休压成一分钟视觉接缝，线段不会横跨空白时段。
    private func chartTime(_ time: Date) -> Date {
        guard compressLunchBreak else { return time }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= 13 * 60 ? time.addingTimeInterval(-89 * 60) : time
    }

    private var chartAxisTicks: [(time: Date, label: String)] {
        guard compressLunchBreak else { return [] }
        // 原来每次都现造 `DateFormatter`，而 `chartAxisLabel` 在 `AxisMarks` 闭包里
        // 逐刻度调它 —— 拖动选择线时一秒能走几十次。走全局缓存后只剩一次字符串转换。
        let formatter = FormatCache.shanghai("yyyy-MM-dd HH:mm")
        return ["09:30", "10:30", "11:30", "14:00", "15:00"].compactMap { label in
            guard let date = formatter.date(from: "\(selectedDay) \(label)") else { return nil }
            return (chartTime(date), label)
        }
    }

    private func chartAxisLabel(_ time: Date) -> String {
        chartAxisTicks.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) })?.label
            ?? time.formatted(date: .omitted, time: .shortened)
    }

    private var chartTimeDomain: ClosedRange<Date>? {
        guard let first = bars.first, let last = bars.last else { return nil }
        let formatter = FormatCache.shanghai("yyyy-MM-dd HH:mm")
        guard let start = formatter.date(from: "\(first.day) 09:30"),
              let end = formatter.date(from: "\(first.day) 15:00") else { return nil }
        if compressLunchBreak { return chartTime(start)...chartTime(end) }
        return first.timestamp...last.timestamp
    }

    private var timeDomain: ClosedRange<Date> {
        if let domain = chartTimeDomain { return domain }
        let lo = bars.first?.timestamp ?? Date()
        let hi = bars.last?.timestamp ?? lo
        return chartTime(lo)...chartTime(hi)
    }

    private var average: [AveragePoint] {
        var simpleSum = 0.0
        var weightedSum = 0.0
        var totalVolume = 0.0
        return bars.enumerated().map { index, bar in
            simpleSum += bar.price
            if let volume = bar.volume, volume.isFinite, volume > 0 {
                weightedSum += bar.price * volume
                totalVolume += volume
            }
            let value = totalVolume > 0 ? weightedSum / totalVolume : simpleSum / Double(index + 1)
            return AveragePoint(time: bar.timestamp, value: value)
        }
    }

    private var iopvBars: [IntradayBar] {
        bars.filter { ($0.iopv ?? 0).isFinite && ($0.iopv ?? 0) > 0 }
    }

    private var macd: [MACDPoint] {
        guard let first = bars.first else { return [] }
        var ema12 = first.price, ema26 = first.price, dea = 0.0
        return bars.map { bar in
            ema12 = ema12 * 11 / 13 + bar.price * 2 / 13
            ema26 = ema26 * 25 / 27 + bar.price * 2 / 27
            let dif = ema12 - ema26
            dea = dea * 8 / 10 + dif * 2 / 10
            return MACDPoint(time: bar.timestamp, dif: dif, dea: dea, histogram: (dif - dea) * 2)
        }
    }

    private var priceDomain: ClosedRange<Double> {
        // 上下限由**当前显示的三条线**共同决定（价格 / 均价 / IOPV），与持仓分时页同一口径。
        // 档案页没有「昨收」输入（历史某天的前收不在本机），所以不参与定轴。
        var values = bars.map(\.price)
        if showAverageLine { values += average.map(\.value) }
        if showIOPVLine { values += iopvBars.compactMap(\.iopv) }
        return intradaySharedYDomain(values)
    }
    private var macdDomain: ClosedRange<Double> { let p = max(macd.flatMap { [abs($0.dif),abs($0.dea),abs($0.histogram)] }.max() ?? 0, 0.000001) * 1.12; return -p...p }

    var body: some View {
        NavigationStack {
            List {
                // Section 必须留在 List 内部：把它整个放进计算属性返回会让编译器
                // 解析到 Table 版的 Section 重载（TableHeaderRowContent 无法当作 View），
                // 所以这里只把 Section 的内容抽出去，Section 本身原样内联。
                Section("采集与归档") {
                    archiveContent
                }
                .toneCard(store.effectiveAccentColor, isLight: isLight)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))

                Section("覆盖状态") {
                    coverageContent
                }
                .plainCard(isLight: isLight)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))

                Section("历史复盘 / 学习") {
                    replayContent
                }
                .plainCard(isLight: isLight)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .refreshFeedbackOverlay(refreshFeedback)
            .navigationTitle("分时档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if selectedCode.isEmpty { selectedCode = instruments.first?.code ?? "" }
                subchart = store.data.intradaySubchartMode == "macd" ? .macd : .volume
                // 偏好可能刚在持仓分时页改过，进来时对齐一次。
                showAverageLine = IntradayVisibility.showAverage
                showIOPVLine = IntradayVisibility.showIOPV
                selectLatestDay()
            }
            .onChange(of: subchart) { _, value in
                store.data.intradaySubchartMode = value == .macd ? "macd" : "volume"
                store.save(label: nil)
            }
        }
    }

    @ViewBuilder private var archiveContent: some View {
        HStack(spacing: 12) {
            Image(systemName: store.isArchivingIntraday ? "arrow.triangle.2.circlepath" : "externaldrive.badge.checkmark")
                .foregroundStyle(store.effectiveAccentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.intradayArchiveStatus).font(.headline)
                Text("打开 App 或刷新行情时自动补全；旧交易日永久保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Button {
            Task { await manuallyArchive() }
        } label: {
            Label(store.isArchivingIntraday ? "正在补全…" : "立即补全全部标的", systemImage: "arrow.down.to.line.compact")
        }
        .disabled(store.isArchivingIntraday)
        Text("iPhone 将 App 完全关闭后，系统不会保证持续采集。这里会在下次打开或刷新时从行情源补回最近交易日整日分钟线，因此不用整天挂着页面。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var coverageContent: some View {
        if instruments.isEmpty {
            Text("先添加自选或场内持仓。")
                .foregroundStyle(.secondary)
        } else {
            let coverageMap = coverageByCode
            ForEach(instruments) { instrument in
                let entry = coverageMap[archiveNormalizedCode(instrument.code)] ?? (day: nil, count: 0, iopvCount: 0)
                let latestDay = entry.day
                let count = entry.count
                Button {
                    selectedCode = instrument.code
                    selectedDay = latestDay ?? ""
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(instrument.name).font(.subheadline.weight(.semibold))
                            Text("\(instrument.code) · \(latestDay ?? "暂无日期")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(count == 0 ? "未采集" : "\(count) 点")
                                .foregroundStyle(coverageColor(code: instrument.code, day: latestDay, count: count))
                            Text(coverageText(code: instrument.code, day: latestDay, count: count))
                                .font(.caption).foregroundStyle(.secondary)
                            if store.isTencentETFCode(instrument.code) {
                                Text(coverage.latestIOPVCount > 0 ? "IOPV \(coverage.latestIOPVCount) 点" : "IOPV 未采集")
                                    .font(.caption2).foregroundStyle(coverage.latestIOPVCount > 0 ? Color.purple : Color.secondary)
                            }
                        }
                    }
                }
            }
        }
        Text("A 股完整交易日通常约 242 个分钟点；状态只反映本机实际保存数量，不会把缺口补造成行情。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var replayContent: some View {
        if instruments.isEmpty {
            ContentUnavailableView("暂无可复盘标的", systemImage: "chart.xyaxis.line")
        } else {
            Picker("标的", selection: $selectedCode) {
                ForEach(instruments) { Text("\($0.name) · \($0.code)").tag($0.code) }
            }
            .onChange(of: selectedCode) { _, _ in selectLatestDay() }

            if days.isEmpty {
                ContentUnavailableView("暂无历史分时", systemImage: "clock.arrow.circlepath", description: Text("点“立即补全全部标的”后再查看。"))
            } else {
                Picker("交易日", selection: $selectedDay) {
                    ForEach(days, id: \.self) { Text($0).tag($0) }
                }

                if let first = bars.first, let last = bars.last {
                    HStack {
                        metric("开", first.price)
                        metric("高", bars.map(\.price).max() ?? first.price)
                        metric("低", bars.map(\.price).min() ?? first.price)
                        metric("收", last.price)
                    }
                    .padding(.vertical, 4)
                }

                priceChart

                HStack(spacing: 8) {
                    archiveLegendChip(title: "价格", color: priceLineColor, isOn: true, available: true, action: nil)
                    archiveLegendChip(title: "均价", color: .orange, isOn: showAverageLine, available: !average.isEmpty) {
                        showAverageLine.toggle()
                        IntradayVisibility.write(average: showAverageLine)
                    }
                    if store.isTencentETFCode(selectedCode) {
                        archiveLegendChip(title: "IOPV", color: .purple, isOn: showIOPVLine, available: !iopvBars.isEmpty) {
                            showIOPVLine.toggle()
                            IntradayVisibility.write(iopv: showIOPVLine)
                        }
                    }
                    Text("点图看分钟值 · B买入 / S卖出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if store.isTencentETFCode(selectedCode), iopvBars.isEmpty {
                    Text("这一天没有保存到真实 IOPV。NAS 升级后开始逐分钟留存；更早的交易日无法从分钟价量反推出历史 IOPV。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Picker("副图", selection: $subchart) {
                    ForEach(Subchart.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if subchart == .volume {
                    volumeChart
                } else {
                    HStack(spacing: 12) {
                        Label("DIF", systemImage: "minus").foregroundStyle(priceLineColor)
                        Label("DEA", systemImage: "minus").foregroundStyle(.orange)
                        Text("柱：红正 / 绿负").foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    macdChart
                }

                replaySummary
            }
        }
    }

    /// 主图图例。可点的那些同时也是**线条开关** —— 用户要求档案页的分时图也能决定显示哪几条线。
    /// 没有那条线的数据（例如非 ETF 没有 IOPV）时置灰不可点。
    @ViewBuilder
    private func archiveLegendChip(title: String, color: Color, isOn: Bool,
                                   available: Bool, action: (() -> Void)? = nil) -> some View {
        let chip = HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 2)
                .opacity(isOn ? 1 : 0.3)
            Text(title).font(.caption)
                .foregroundStyle(isOn ? color : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background((isOn ? color : Color.secondary).opacity(isOn ? 0.12 : 0.06), in: Capsule())
        .opacity(available ? 1 : 0.4)
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .disabled(!available)
        } else {
            chip
        }
    }

    /// 只组装参数；**选择态与绘图实体都在 `ArchivePriceChart` 里**（见那里的说明：
    /// 把选择态留在本视图会让每一次拖动都重算整页的重活）。
    private var priceChart: some View {
        ArchivePriceChart(
            bars: bars,
            lines: bars.map { IntradayLine(time: $0.timestamp, price: $0.price) },
            average: average.map { IntradayLine(time: $0.time, price: $0.value) },
            iopv: iopvBars.compactMap { bar in
                guard let value = bar.iopv, value.isFinite, value > 0 else { return nil }
                return IntradayLine(time: bar.timestamp, price: value)
            },
            tradeMarkers: tradePoints,
            lineColor: priceLineColor,
            xDomain: timeDomain,
            yDomain: priceDomain,
            ticks: chartAxisTicks,
            compressLunch: compressLunchBreak,
            showAverage: showAverageLine,
            showIOPV: showIOPVLine
        )
        // 换交易日 = 换一张图：整体重建，选择线随之复位。
        .id("\(resolvedCode)|\(selectedDay)")
    }

    @ViewBuilder private var volumeChart: some View {
        Chart {
            ForEach(bars.indices, id: \.self) { index in
                let point = bars[index]
                if let volume = point.volume, volume > 0 {
                BarMark(x: .value("时间", chartTime(point.timestamp)), y: .value("成交量", volume), width: .fixed(minuteBarWidth(bars.count)))
                        .foregroundStyle(volumeColor(at: index).opacity(0.78))
                        .cornerRadius(1)
                }
            }
        }
        .frame(height: 165)
        .chartXScale(domain: timeDomain)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12)); AxisValueLabel().font(.caption2).foregroundStyle(.secondary) } }
    }

    @ViewBuilder private var macdChart: some View {
        Chart {
            RuleMark(y: .value("零轴", 0))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            ForEach(macd) { point in
                hollowIntradayMACDColumn(time: chartTime(point.time), value: point.histogram, interval: 60,
                    color: point.histogram >= 0 ? .red : .green)
            }
            ForEach(macd) { point in
                LineMark(x: .value("时间", chartTime(point.time)), y: .value("DIF", point.dif), series: .value("MACD序列", "DIF"))
                    .foregroundStyle(priceLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
            }
            ForEach(macd) { point in
                LineMark(x: .value("时间", chartTime(point.time)), y: .value("DEA", point.dea), series: .value("MACD序列", "DEA"))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 165)
        .chartYScale(domain: macdDomain)
        .chartXScale(domain: timeDomain)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12)); AxisValueLabel().font(.caption2).foregroundStyle(.secondary) } }
    }

    @MainActor private func manuallyArchive() async {
        refreshFeedback.begin("正在补全全部标的分时…")
        let result = await store.archiveTrackedIntraday(force: true)
        // failure == 0 即视为完成：success / failure 同时为 0 表示没有可采集的标的
        // （或已有补全任务在跑），此时状态文案自己会说清楚原因，不算失败。
        refreshFeedback.finish(store.intradayArchiveStatus, succeeded: result.failure == 0)
    }

    @ViewBuilder private func metric(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.num(4)).font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var replaySummary: some View {
        if let first = bars.first, let last = bars.last {
            let high = bars.map(\.price).max() ?? last.price
            let low = bars.map(\.price).min() ?? last.price
            let change = first.price > 0 ? (last.price / first.price - 1) * 100 : 0
            let position = high > low ? (last.price - low) / (high - low) * 100 : 50
            VStack(alignment: .leading, spacing: 7) {
                Text("复盘摘要").font(.headline)
                Text("当日 \(change >= 0 ? "+" : "")\(change.num(2))% · 振幅 \(((high - low) / max(low, 0.000001) * 100).num(2))% · 收盘位于日内区间 \(position.num(0))%")
                Text("已保存 \(bars.count) 个真实分钟点，流水标记 \(tradePoints.count) 笔。可点主图逐分钟查看价格。")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 5)
        }
    }

    private func selectLatestDay() {
        selectedDay = days.first ?? ""
    }

    private func volumeColor(at index: Int) -> Color {
        guard bars.indices.contains(index), index > 0 else { return .secondary }
        return bars[index].price >= bars[index - 1].price ? .red : .green
    }

    private func expectedPoints(for code: String) -> Int? {
        let value = code.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.replacingOccurrences(of: "^(sh|sz|bj)", with: "", options: .regularExpression)
        if digits.count == 6, digits.allSatisfy(\.isNumber) { return 242 }
        if value.hasPrefix("hk") || (digits.count == 5 && digits.allSatisfy(\.isNumber)) { return 332 }
        if value.hasPrefix("us") { return 391 }
        return nil
    }

    private func coverageText(code: String, day: String?, count: Int) -> String {
        guard count > 0 else { return "等待补全" }
        guard let expected = expectedPoints(for: code) else { return "已保存" }
        let missing = max(0, expected - count)
        let percent = min(100, Int((Double(count) / Double(expected) * 100).rounded()))
        if day == shanghaiDay(.now), isShanghaiTradingDayInProgress() && missing > 0 {
            return "采集中 · \(percent)%"
        }
        return "\(percent)% · 缺口 \(missing) 分"
    }

    private func coverageColor(code: String, day: String?, count: Int) -> Color {
        guard count > 0 else { return .secondary }
        guard let expected = expectedPoints(for: code) else { return .green }
        if day == shanghaiDay(.now), isShanghaiTradingDayInProgress() { return store.effectiveAccentColor }
        return count >= expected - 2 ? .green : .orange
    }

    private func isShanghaiTradingDayInProgress() -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date.now
        let weekday = calendar.component(.weekday, from: now)
        guard weekday != 1, weekday != 7 else { return false }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return minute >= 9 * 60 + 15 && minute < 15 * 60 + 10
    }

    private func shanghaiDay(_ date: Date) -> String {
        MarketCalendar.isoDay(date)
    }
}
