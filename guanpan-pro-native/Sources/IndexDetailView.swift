import SwiftUI

/// 指数详情：点指数卡片进来的页面。
///
/// 为什么单独做一张分时图，而不复用 `UnifiedChartView`：
/// 主图的横轴固定 09:30–15:00（沪深的交易时段），但日经是北京时间 08:00–14:00、
/// 韩国到 14:30、美股在夜里。硬套 A 股横轴会把海外指数的点挤到边界甚至丢掉。
/// 所以这里按**样本序**画，横轴刻度取首/中/末三个真实时间，任何时段都成立。
/// 日K/周K/月K 交给 `UnifiedChartView`（按根数取窗口，不涉及时段）。
struct IndexDetailScreen: View {
    @Environment(\.gp) private var p
    let symbol: String

    @State private var quote: GlobalIndexQuote?
    @State private var minuteSamples: [NextChartSample] = []
    @State private var previousClose: Decimal?
    @State private var dailySamples: [NextChartSample] = []
    @State private var tab: IndexChartTab = .intraday
    /// 交给 UnifiedChartView 的周期绑定。分时由本页自己画，所以这里只允许 .day 起步，
    /// 用户在图内切周K/月K 时它照常生效。
    @State private var kInterval: NextChartInterval = .day
    @State private var selectedTime: Date?
    @State private var loading = false
    @State private var snapshotError: String?
    @State private var minuteError: String?
    @State private var dailyError: String?

    private var capability: GlobalIndexCapability { GlobalIndexSeries.capability(for: symbol) }
    private var name: String { GlobalIndexFeed.displayName(symbol) }
    private var tone: Color {
        guard let quote, quote.price > 0 else { return p.muted }
        return p.changeTone(NextNum.double(quote.changePercent))
    }
    private var effectivePrevious: Decimal? {
        if let previousClose, previousClose > 0 { return previousClose }
        guard let quote, quote.price > 0, quote.changePercent != -100 else { return nil }
        let base = quote.price / (1 + quote.changePercent / 100)
        return base > 0 ? NextNum.decimal(base) : nil
    }
    private var dailyDataset: NextChartDataset? {
        guard !dailySamples.isEmpty else { return nil }
        return NextChartDataset(code: symbol, interval: .day, samples: dailySamples,
                                costPerUnit: nil, costObservedAt: nil,
                                priceSource: capability.dailySource, iopvSource: nil, observedAt: Date())
    }

    var body: some View {
        // 注意：GPPageBackground 自带 ScrollView 和横向 14 的内边距，
        // 这里再套一层 ScrollView 就会嵌套滚动（内层永远滚不动）。
        GPPageBackground {
            VStack(alignment: .leading, spacing: 12) {
                header
                chartCard
                footnotes
            }
            .padding(.bottom, 26)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    // MARK: 表头

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                Text(symbol).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                Spacer(minLength: 4)
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.forest).frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .accessibilityLabel("刷新指数")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(quote.map { NextNum.text($0.price) } ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(quote == nil ? p.muted : p.ink)
                if let quote, quote.price > 0 {
                    Text("\(NextNum.signed(quote.changePercent))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(tone)
                }
                if loading { ProgressView().scaleEffect(0.6).frame(width: 16, height: 16) }
            }
            HStack(spacing: 12) {
                if let previous = effectivePrevious {
                    Text("昨收 \(NextNum.text(NextNum.double(previous)))").font(.system(size: 10.5)).foregroundStyle(p.muted)
                }
                if let stamp = quote?.observedAt {
                    Text("时点 \(stamp.formatted(date: .omitted, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(p.muted)
                }
                if quote?.isStale == true {
                    Text("上一时段收盘价").font(.system(size: 10, weight: .bold)).foregroundStyle(p.terracotta)
                }
            }
            if let snapshotError {
                Text(snapshotError).font(.system(size: 10)).foregroundStyle(p.terracotta)
            }
        }
        .padding(12)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tone.opacity(0.18), lineWidth: 0.8))
        .padding(.top, 8)
    }

    // MARK: 图表

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ForEach(IndexChartTab.allCases) { item in
                    Button { tab = item; selectedTime = nil } label: {
                        Text(item.title)
                            .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? p.forest : p.muted)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(tab == item ? p.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(item == .intraday && !capability.hasMinute)
                    .opacity(item == .intraday && !capability.hasMinute ? 0.4 : 1)
                    .accessibilityIdentifier("index.tab.\(item.rawValue)")
                }
                Spacer(minLength: 0)
                Text(tab == .intraday ? capability.minuteSource : capability.dailySource)
                    .font(.system(size: 9.5)).foregroundStyle(p.muted)
            }
            if tab == .intraday {
                if minuteSamples.isEmpty {
                    if let minuteError {
                        GPStatus(title: "分时暂不可用", detail: minuteError, symbol: "wifi.exclamationmark", actionTitle: "重新获取") { Task { await loadMinute() } }
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                } else {
                    IndexIntradayChart(samples: minuteSamples, previousClose: effectivePrevious, height: 330)
                }
            } else {
                if let dataset = dailyDataset {
                    UnifiedChartView(dataset: dataset, interval: $kInterval, costPerUnit: nil,
                                     selectedTime: $selectedTime)
                } else if let dailyError {
                    GPStatus(title: "日K暂不可用", detail: dailyError, symbol: "wifi.exclamationmark", actionTitle: "重新获取") { Task { await loadDaily() } }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
        }
        .padding(12)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.muted.opacity(0.14), lineWidth: 0.8))
    }

    // MARK: 说明

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let note = capability.missingNote {
                Text(note).font(.system(size: 10)).foregroundStyle(p.terracotta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("分时口径：按该市场的真实交易时段逐点绘制，横轴刻度取首/中/末真实时间；纵轴以昨收为 0 轴、上下对称。日K 不作复权推测（指数本身无分红）。")
                .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            Text("数据源：\(capability.hasMinute ? capability.minuteSource : capability.dailySource)；指数只读，不参与买卖与账本。")
                .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 取数

    private func reload() async {
        loading = true
        defer { loading = false }
        async let snapshot: Void = loadSnapshot()
        async let minute: Void = loadMinute()
        async let daily: Void = loadDaily()
        _ = await (snapshot, minute, daily)
        if !capability.hasMinute { tab = .line }
    }

    private func loadSnapshot() async {
        do {
            quote = try await GlobalIndexFeed.fetchQuote(symbol: symbol)
            snapshotError = nil
        } catch {
            snapshotError = "快照：\(error.localizedDescription)"
        }
    }

    private func loadMinute() async {
        guard capability.hasMinute else { minuteError = capability.missingNote; return }
        do {
            let result = try await GlobalIndexSeries.minute(for: symbol)
            minuteSamples = result.samples
            previousClose = result.previousClose
            minuteError = nil
        } catch {
            minuteError = error.localizedDescription
        }
    }

    private func loadDaily() async {
        do {
            dailySamples = try await GlobalIndexSeries.daily(for: symbol)
            dailyError = nil
        } catch {
            dailyError = error.localizedDescription
        }
    }
}

enum IndexChartTab: String, CaseIterable, Identifiable {
    case intraday, line
    var id: String { rawValue }
    var title: String { self == .intraday ? "分时" : "日K" }
}

/// 指数分时图：按样本序绘制，所以日经（北京时间 08:00–14:00）、韩国、港股、美股都不会错位。
/// 纵轴以昨收为 0 轴、上下严格对称 —— 与沪深分时同一套读图习惯。
struct IndexIntradayChart: View {
    @Environment(\.gp) private var p
    let samples: [NextChartSample]
    let previousClose: Decimal?
    var height: CGFloat = 330

    private var closes: [Double] { samples.map { NextNum.double($0.close) } }
    private var base: Double {
        if let previousClose { return NextNum.double(previousClose) }
        return closes.first ?? 0
    }
    private var span: Double {
        guard base > 0 else { return 1 }
        let values = closes.filter { $0 > 0 }
        guard let high = values.max(), let low = values.min() else { return base * 0.01 }
        let deviation = max(high - base, base - low)
        // 波动极小时给 ±0.4% 保底，避免整条线贴着 0 轴；但**不与对称范围相加**，两边同一尺度。
        return max(deviation * 1.08, base * 0.004)
    }
    private var isUp: Bool { (closes.last ?? base) >= base }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawGrid(&context, size: size)
                        drawSeries(&context, size: size)
                    }
                }
                .frame(height: height)
                priceLabels
            }
            timeLabels
        }
    }

    private var priceLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(NextNum.text(base + span)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
            Text(NextNum.text(base)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
            Text(NextNum.text(base - span)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
        }
        .frame(width: 46, height: height)
    }

    private var timeLabels: some View {
        HStack(spacing: 0) {
            if let first = samples.first?.timestamp {
                Text(clock(first)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
            if samples.count > 2 {
                Text(clock(samples[samples.count / 2].timestamp)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
            if let last = samples.last?.timestamp {
                Text(clock(last)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(p.muted)
            }
        }
        .padding(.trailing, 46)
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func point(_ index: Int, _ size: CGSize) -> CGPoint {
        let width = max(1, size.width)
        let x = samples.count <= 1 ? 0 : CGFloat(index) / CGFloat(samples.count - 1) * width
        let value = closes.indices.contains(index) ? closes[index] : base
        let ratio = span > 0 ? (value - base) / span : 0
        let y = size.height / 2 - CGFloat(ratio) * (size.height / 2)
        return CGPoint(x: x, y: minimax(y, size.height))
    }

    private func minimax(_ y: CGFloat, _ height: CGFloat) -> CGFloat { min(max(y, 0), height) }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        for level in [0.0, 0.5, 1.0] {
            let y = size.height * level
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(p.muted.opacity(level == 0.5 ? 0.35 : 0.14)),
                           style: StrokeStyle(lineWidth: level == 0.5 ? 0.9 : 0.6,
                                              dash: level == 0.5 ? [3, 3] : []))
        }
    }

    private func drawSeries(_ context: inout GraphicsContext, size: CGSize) {
        guard !samples.isEmpty else { return }
        var line = Path()
        for index in samples.indices {
            let current = point(index, size)
            if index == 0 { line.move(to: current) } else { line.addLine(to: current) }
        }
        let tone = isUp ? p.gpUp : p.gpDown
        // 面积：把折线闭合到底边，用低透明度填充，幅度小的时候也不至于看不见。
        if let first = samples.indices.first, let last = samples.indices.last {
            var area = line
            area.addLine(to: CGPoint(x: point(last, size).x, y: size.height))
            area.addLine(to: CGPoint(x: point(first, size).x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [tone.opacity(0.22), tone.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        context.stroke(line, with: .color(tone), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        if let lastPoint = samples.indices.last.map({ point($0, size) }) {
            let dot = Path(ellipseIn: CGRect(x: lastPoint.x - 2, y: lastPoint.y - 2, width: 4, height: 4))
            context.fill(dot, with: .color(tone))
        }
    }
}
