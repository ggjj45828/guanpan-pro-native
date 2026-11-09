import SwiftUI
import Charts

/// 周期K线（120/60/30/15 分钟）· 成交量 · MACD —— 全部按同一周期的真实 NAS 分钟归档计算。
///
/// 诚实约束（与 NAS 端 kline.py 一致）：
/// - 只消费 /api/v1/chart 从真实 1 分钟归档聚合出的周期 K 线；没有真实数据时
///   显示「不可用」横幅，绝不拿日线拼分钟线、不插值。
/// - MACD 快/慢/信号参数可改（不写死），hist=2×(DIF−DEA)；warmup 之前服务端给 null。
struct NASPeriodChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    /// 由工具页 push 时为 true：不自建导航栈，用外层返回。
    var embedded: Bool = false

    @State private var selectedCode = ""
    @State private var periodMinutes = 120
    @State private var lookbackDays = 120
    @State private var macdFast = 12
    @State private var macdSlow = 26
    @State private var macdSignal = 9

    @State private var chart: NASPeriodChart?
    @State private var loading = false
    @State private var message = ""

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    private struct Instrument: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private var instruments: [Instrument] {
        var names: [String: String] = [:]
        for quote in store.data.quotes { names[quote.code] = quote.name.isEmpty ? quote.code : quote.name }
        for holding in store.data.holdings where holding.kind == .etf {
            names[holding.code] = holding.name.isEmpty ? holding.code : holding.name
        }
        return names.map { Instrument(code: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                controls
                statusSection
                if let chart { chartSection(chart) }
            }
            .scrollContentBackground(.hidden)
            .appListLayout()
            .background(.clear)
            .navigationTitle("周期K线 · MACD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !embedded { Button("关闭") { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: {
                        if loading { ProgressView() } else { Text("绘制") }
                    }
                    .disabled(loading)
                }
            }
            .onAppear {
                if selectedCode.isEmpty { selectedCode = instruments.first?.code ?? "" }
                if chart == nil, !selectedCode.isEmpty { Task { await load() } }
            }
    }

    // MARK: - 参数区

    private var controls: some View {
        Section {
            Picker("标的", selection: $selectedCode) {
                ForEach(instruments) { item in
                    Text("\(item.name)（\(item.code)）").tag(item.code)
                }
            }
            Picker("周期", selection: $periodMinutes) {
                ForEach(NASPeriodChartService.supportedPeriods, id: \.self) { value in
                    Text("\(value) 分钟").tag(value)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Stepper("回看 \(lookbackDays) 天", value: $lookbackDays, in: 5...750, step: 5)
                    .font(.footnote)
            }
            HStack(spacing: 10) {
                parameterField("快", value: $macdFast, range: 1...250)
                parameterField("慢", value: $macdSlow, range: 2...500)
                parameterField("信号", value: $macdSignal, range: 1...100)
            }
            Button {
                Task { await load() }
            } label: {
                Label("按以上参数绘制", systemImage: "chart.xyaxis.line")
            }
            .disabled(loading || selectedCode.isEmpty)
        } header: {
            Text("周期与 MACD 参数（可改，不写死）")
        } footer: {
            Text("K线、成交量、MACD 都按所选周期的同一份真实分钟数据计算。没有真实分钟时显示不可用，不会用日线拼分钟线。")
        }
    }

    private func parameterField(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .font(.footnote.monospacedDigit())
                .frame(width: 64)
        }
    }

    // MARK: - 状态区

    private var statusSection: some View {
        Section {
            if loading {
                Label("正在读取 NAS 周期数据…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if let chart {
                switch chart.availability {
                case .unavailable(let reason, let detail):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("不可用：\(reason)", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                case .ok:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - 图表区

    @ViewBuilder
    private func chartSection(_ chart: NASPeriodChart) -> some View {
        if case .ok = chart.availability, !chart.bars.isEmpty {
            Section {
                summaryCards(chart)
                candleChart(chart)
                volumeChart(chart)
                macdChart(chart)
                legend
            } header: {
                Text("\(chart.periodMinutes) 分钟K线（\(chart.bars.count) 根）")
            } footer: {
                Text(footerText(chart))
            }
        }
    }

    private func summaryCards(_ chart: NASPeriodChart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                summaryItem("首末", chart.bars.isEmpty ? "—"
                    : "\(chart.bars.first!.timestamp.formatted(date: .abbreviated, time: .shortened)) → \(chart.bars.last!.timestamp.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
            }
            HStack(spacing: 14) {
                summaryItem("MACD", chart.macd.map { "\($0.fast)/\($0.slow)/\($0.signal)" } ?? "—")
                if let macd = chart.macd {
                    summaryItem("MACD状态", macd.available ? "可用（warmup \(macd.warmupBars)）" : "不可用")
                }
                summaryItem("完整K线", "\(chart.bars.filter(\.complete).count)/\(chart.bars.count)")
                Spacer()
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }

    private func candleChart(_ chart: NASPeriodChart) -> some View {
        Chart {
            ForEach(chart.bars) { bar in
                let up = bar.close >= bar.open
                let color = up ? Color.red : Color.green
                RuleMark(x: .value("时间", bar.timestamp),
                         yStart: .value("低", bar.low),
                         yEnd: .value("高", bar.high))
                    .foregroundStyle(color)
                RectangleMark(x: .value("时间", bar.timestamp),
                              yStart: .value("开", min(bar.open, bar.close)),
                              yEnd: .value("收", max(bar.open, bar.close)),
                              width: .fixed(5))
                    .foregroundStyle(color)
            }
        }
        .frame(height: 220)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisValueLabel(format: .dateTime.month().day().hour().minute())
        } }
    }

    private func volumeChart(_ chart: NASPeriodChart) -> some View {
        Chart {
            ForEach(chart.bars.filter { $0.volume != nil }) { bar in
                BarMark(x: .value("时间", bar.timestamp),
                        y: .value("成交量", bar.volume ?? 0))
                    .foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.7) : Color.green.opacity(0.7))
            }
        }
        .frame(height: 80)
        .chartXAxis(.hidden)
    }

    @ViewBuilder
    private func macdChart(_ chart: NASPeriodChart) -> some View {
        if let macd = chart.macd, macd.available {
            Chart {
                ForEach(Array(chart.bars.enumerated()), id: \.offset) { index, bar in
                    if index < macd.hist.count, let hist = macd.hist[index] {
                        BarMark(x: .value("时间", bar.timestamp), y: .value("MACD柱", hist))
                            .foregroundStyle(hist >= 0 ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                    }
                    if index < macd.dif.count, let dif = macd.dif[index] {
                        LineMark(x: .value("时间", bar.timestamp), y: .value("DIF", dif))
                            .foregroundStyle(.cyan)
                    }
                    if index < macd.dea.count, let dea = macd.dea[index] {
                        LineMark(x: .value("时间", bar.timestamp), y: .value("DEA", dea))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(height: 120)
            .chartXAxis(.hidden)
        } else if let macd = chart.macd {
            Text("MACD 不可用：\(macd.reason ?? "根数不足 warmup \(macd.warmupBars)")，不伪造数值")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(height: 60, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("涨", systemImage: "square.fill").foregroundStyle(.red)
            Label("跌", systemImage: "square.fill").foregroundStyle(.green)
            Label("DIF", systemImage: "minus").foregroundStyle(.cyan)
            Label("DEA", systemImage: "minus").foregroundStyle(.orange)
        }
        .font(.caption)
    }

    private func footerText(_ chart: NASPeriodChart) -> String {
        let source = chart.ohlcSource == "real_1m_ohlc"
            ? "真实 1 分钟 OHLCV"
            : chart.ohlcSource == "mixed" ? "混合口径（部分为价格快照聚合）"
            : "价格快照聚合（开=首价 收=末价 高低=桶内极值）"
        return "口径：\(source) · MACD柱=2×(DIF−DEA) · 成交量=分钟量之和 · 缺数据不插值"
    }

    // MARK: - 加载

    @MainActor private func load() async {
        guard !selectedCode.isEmpty else { return }
        loading = true
        message = ""
        defer { loading = false }
        do {
            let result = try await NASPeriodChartService.fetch(
                code: selectedCode, periodMinutes: periodMinutes, days: lookbackDays,
                macdFast: macdFast, macdSlow: macdSlow, macdSignal: macdSignal)
            chart = result
            if case .unavailable = result.availability {
                // 横幅在 statusSection 显示，这里不重复报错。
            }
        } catch {
            chart = nil
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
