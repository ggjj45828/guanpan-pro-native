import SwiftUI
import Charts

/// 分时采集、每日归档和历史复盘的统一入口。
/// 只展示真实落盘数据；没有采到的分钟不会插值伪造。
struct IntradayArchiveView: View {
    @EnvironmentObject private var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCode = ""
    @State private var selectedDay = ""
    @State private var subchart: Subchart = .volume
    @State private var selectedTime: Date?

    private enum Subchart: String, CaseIterable, Identifiable {
        case volume = "分时量"
        case macd = "分时 MACD"
        var id: String { rawValue }
    }

    private struct Instrument: Identifiable {
        let code: String
        let name: String
        var id: String { code }
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

    private struct TradePoint: Identifiable {
        let id: UUID
        let time: Date
        let price: Double
        let side: LedgerEntry.Side
    }

    private struct Coverage {
        let latestDay: String?
        let latestCount: Int
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    private var instruments: [Instrument] {
        var names: [String: String] = [:]
        for quote in store.data.quotes { names[quote.code] = quote.name.isEmpty ? quote.code : quote.name }
        for holding in store.data.holdings where holding.kind == .etf {
            names[holding.code] = holding.name.isEmpty ? holding.code : holding.name
        }
        return names.map { Instrument(code: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 一次遍历完成全部标的覆盖统计，避免列表每一行都重新扫描整份多年分钟档案。
    private var coverageByCode: [String: Coverage] {
        var counts: [String: [String: Int]] = [:]
        for bar in store.intradayBars { counts[bar.code, default: [:]][bar.day, default: 0] += 1 }
        return counts.mapValues { days in
            let latest = days.keys.max()
            return Coverage(latestDay: latest, latestCount: latest.flatMap { days[$0] } ?? 0)
        }
    }

    private var days: [String] {
        Array(Set(store.intradayBars.filter { $0.code == selectedCode }.map(\.day))).sorted(by: >)
    }

    private var bars: [IntradayBar] {
        store.intradayBars
            .filter { $0.code == selectedCode && $0.day == selectedDay }
            .sorted { $0.timestamp < $1.timestamp }
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

    private var tradePoints: [TradePoint] {
        guard !bars.isEmpty else { return [] }
        return store.data.ledger.filter { $0.code == selectedCode && shanghaiDay($0.date) == selectedDay }.compactMap { trade in
            let nearest = bars.min { abs($0.timestamp.timeIntervalSince(trade.date)) < abs($1.timestamp.timeIntervalSince(trade.date)) }
            guard let nearest else { return nil }
            return TradePoint(id: trade.id, time: nearest.timestamp, price: trade.price > 0 ? trade.price : nearest.price, side: trade.side)
        }
    }

    private var selectedBar: IntradayBar? {
        guard let selectedTime else { return nil }
        return bars.min { abs($0.timestamp.timeIntervalSince(selectedTime)) < abs($1.timestamp.timeIntervalSince(selectedTime)) }
    }
    private var priceDomain: ClosedRange<Double> {
        let v = (bars.map(\.price) + average.map(\.value)).filter { $0 > 0 }
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        let ref = max(abs(lo), abs(hi), 0.0001), spread = max(hi - lo, ref * 0.002), p = max(spread * 0.09, ref * 0.0006)
        return (lo-p)...(hi+p)
    }
    private var macdDomain: ClosedRange<Double> { let p = max(macd.flatMap { [abs($0.dif),abs($0.dea),abs($0.histogram)] }.max() ?? 0, 0.000001) * 1.12; return -p...p }

    var body: some View {
        NavigationStack {
            List {
                Section("采集与归档") {
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
                .toneCard(store.effectiveAccentColor, isLight: isLight)

                Section("覆盖状态") {
                    if instruments.isEmpty {
                        Text("先添加自选或场内持仓。")
                            .foregroundStyle(.secondary)
                    } else {
                        let coverageMap = coverageByCode
                        ForEach(instruments) { instrument in
                            let coverage = coverageMap[instrument.code] ?? Coverage(latestDay: nil, latestCount: 0)
                            let latestDay = coverage.latestDay
                            let count = coverage.latestCount
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
                                    }
                                }
                            }
                        }
                    }
                    Text("A 股完整交易日通常约 242 个分钟点；状态只反映本机实际保存数量，不会把缺口补造成行情。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)

                Section("历史复盘 / 学习") {
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
                            .onChange(of: selectedDay) { _, _ in selectedTime = nil }

                            if let first = bars.first, let last = bars.last {
                                HStack {
                                    metric("开", first.price)
                                    metric("高", bars.map(\.price).max() ?? first.price)
                                    metric("低", bars.map(\.price).min() ?? first.price)
                                    metric("收", last.price)
                                }
                                .padding(.vertical, 4)
                            }

                            Chart {
                                ForEach(bars) { point in
                                    LineMark(x: .value("时间", point.timestamp), y: .value("价格", point.price))
                                        .foregroundStyle(store.effectiveAccentColor)
                                        .interpolationMethod(.linear)
                                }
                                ForEach(average) { point in
                                    LineMark(x: .value("时间", point.time), y: .value("均价", point.value))
                                        .foregroundStyle(Color.orange)
                                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                                }
                                ForEach(tradePoints) { trade in
                                    PointMark(x: .value("交易时间", trade.time), y: .value("成交价", trade.price))
                                        .foregroundStyle(trade.side == .buy ? Color.red : Color.green)
                                        .symbolSize(60)
                                        .annotation(position: trade.side == .buy ? .top : .bottom) {
                                            Text(trade.side == .buy ? "B" : "S")
                                                .font(.caption2.bold())
                                                .foregroundStyle(trade.side == .buy ? Color.red : Color.green)
                                        }
                                }
                                if let selectedBar {
                                    RuleMark(x: .value("选中", selectedBar.timestamp))
                                        .foregroundStyle(Color.secondary)
                                        .annotation(position: .top, alignment: .leading) {
                                            Text("\(selectedBar.timestamp.formatted(date: .omitted, time: .shortened))  \(selectedBar.price.num(4))")
                                                .font(.caption.monospacedDigit())
                                                .padding(6)
                                                .background(isLight ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 7))
                                        }
                                }
                            }
                            .frame(height: 260)
                            .chartYScale(domain: priceDomain)
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                            .chartXSelection(value: $selectedTime)

                            HStack(spacing: 14) {
                                Label("价格", systemImage: "minus").foregroundStyle(store.effectiveAccentColor)
                                Label("均价", systemImage: "minus").foregroundStyle(.orange)
                                Text("点图看分钟值 · B买入 / S卖出")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)

                            Picker("副图", selection: $subchart) {
                                ForEach(Subchart.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            if subchart == .volume {
                                Chart(bars.filter { $0.volume != nil }) { point in
                                    BarMark(x: .value("时间", point.timestamp), y: .value("成交量", point.volume ?? 0))
                                        .foregroundStyle(point.price >= (bars.first?.price ?? point.price) ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                                }
                                .frame(height: 110)
                                .chartXAxis(.hidden)
                            } else {
                                Chart(macd) { point in
                                    BarMark(x: .value("时间", point.time), y: .value("MACD", point.histogram))
                                        .foregroundStyle(point.histogram >= 0 ? Color.red : Color.green)
                                    LineMark(x: .value("时间", point.time), y: .value("DIF", point.dif)).foregroundStyle(Color.primary)
                                    LineMark(x: .value("时间", point.time), y: .value("DEA", point.dea)).foregroundStyle(Color.orange)
                                }
                                .frame(height: 110)
                                .chartYScale(domain: macdDomain)
                                .chartXAxis(.hidden)
                            }

                            replaySummary
                        }
                    }
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .appListLayout()
            .background(.clear)
            .refreshFeedbackOverlay(refreshFeedback)
            .navigationTitle("分时档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if selectedCode.isEmpty { selectedCode = instruments.first?.code ?? "" }
                subchart = store.data.intradaySubchartMode == "macd" ? .macd : .volume
                selectLatestDay()
            }
            .onChange(of: subchart) { _, value in
                store.data.intradaySubchartMode = value == .macd ? "macd" : "volume"
                store.save(label: nil)
            }
        }
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
        selectedTime = nil
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
