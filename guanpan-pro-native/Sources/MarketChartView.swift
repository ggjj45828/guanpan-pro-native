import SwiftUI
import Charts

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

struct MarketChartView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var selectedIntradayDay = ""
    @State private var selectedChartPeriod: NativeChartPeriod = .intraday
    @State private var intradaySubchart: IntradaySubchart = .macd
    @State private var showInstrumentAI = false
    @State private var instrumentAIResult = ""
    @State private var instrumentAIMessage = ""
    @State private var instrumentAIBusy = false
    @State private var isLoading = false
    @State private var message = ""
    @State private var backtestCapital = "100000"
    @State private var backtestFeePercent = "0.03"
    @State private var backtestResult: StrategyBacktestResult?
    @State private var backtestMessage = ""
    @State private var minuteStatus = "正在加载当日分时…"
    @State private var chartZoom = 1.0
    @GestureState private var pinchScale = 1.0
    @State private var chartPanOffset = 0

    private var allBars: [DailyBar] { store.dailyBars[holding.code] ?? [] }
    private var range: Int { store.data.dailyChartRangeDays }
    private var bars: [DailyBar] { Array(allBars.suffix(range)) }
    private var periodBars: [DailyBar] {
        switch selectedChartPeriod {
        case .intraday: return []
        case .day: return bars
        case .week, .month:
            let calendar = Calendar(identifier: .iso8601)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd"
            let grouped = Dictionary(grouping: bars) { bar -> String in
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
        case .minute30, .minute60: return []
        }
    }
    private var intradayDays: [String] {
        Array(Set(store.intradayBars.filter { $0.code == holding.code }.map(\.day))).sorted(by: >)
    }
    private var selectedIntradayBars: [IntradayBar] {
        let day = intradayDays.contains(selectedIntradayDay) ? selectedIntradayDay : (intradayDays.first ?? "")
        return store.intradayBars.filter { $0.code == holding.code && $0.day == day }.sorted { $0.timestamp < $1.timestamp }
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
    private func average(_ window: Int) -> [IndicatorPoint] {
        average(window, source: bars)
    }
    private func average(_ window: Int, source: [DailyBar]) -> [IndicatorPoint] {
        guard source.count >= window else { return [] }
        return source.indices.compactMap { index in
            guard index + 1 >= window else { return nil }
            let values = source[(index + 1 - window)...index].map(\.close)
            return IndicatorPoint(date: source[index].date, value: values.reduce(0, +) / Double(window))
        }
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
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("\(holding.name) · \(holding.code)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let quote {
                                Text((quote.changePct).pct(2))
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
                        if selectedIntradayBars.count > 1 {
                            Chart(selectedIntradayBars) { point in
                                LineMark(x: .value("时间", point.timestamp), y: .value("价格", point.price))
                                    .foregroundStyle(intradayLineColor).interpolationMethod(.linear)
                            }
                            .frame(height: 280)
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
                        LabeledContent("MA 策略收益", value: (result.strategyReturn).pct(2))
                        LabeledContent("买入持有期末资产", value: (result.holdValue).cny())
                        LabeledContent("买入持有收益", value: (result.holdReturn).pct(2))
                        LabeledContent("MA 策略最大回撤", value: (result.maxDrawdown).pct(2))
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
                if allBars.isEmpty { await load(force: false) }
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
    private var ma5Color: Color { Color(red: 1.0, green: 0.62, blue: 0.11) }    // 橙
    private var ma10Color: Color { Color(red: 0.30, green: 0.66, blue: 1.0) }   // 蓝
    private var ma20Color: Color { Color(red: 0.80, green: 0.36, blue: 1.0) }   // 紫
    private var ma60Color: Color { Color(red: 0.16, green: 0.88, blue: 0.76) }  // 青绿

    @ViewBuilder private var dailyChartSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("捏合缩放 · 左右拖动看历史")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重置") { chartZoom = 1; chartPanOffset = 0 }.font(.caption)
            }
            maLegendRow
            // GeometryReader 拿到实际绘图宽度，据此算出随缩放变化的实体宽度。
            // 之前实体固定 5pt，放大后柱子不变粗、间距却变大，看起来既稀疏又糊。
            GeometryReader { geo in
                let slot = max(60, geo.size.width) / CGFloat(max(1, zoomedPeriodBars.count))
                let bodyWidth = min(max(slot * 0.68, 1.2), 18)
                VStack(spacing: 8) {
                    candlePlot(bodyWidth: bodyWidth).frame(height: 300)
                    volumePlot(bodyWidth: bodyWidth).frame(height: 82)
                }
            }
            .frame(height: 390)
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
                    .font(.system(size: 10)).foregroundStyle(.secondary)
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
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v.num(3)).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(color)
            }
            if values.isEmpty { Text("--").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var maLegendRow: some View {
        HStack(spacing: 10) {
            maChip("MA5", ma5Color)
            maChip("MA10", ma10Color)
            maChip("MA20", ma20Color)
            maChip("MA60", ma60Color)
            Spacer(minLength: 0)
        }.font(.caption2)
    }

    private func maChip(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 12, height: 3)
            Text(title).foregroundStyle(color)
        }
        .font(.system(size: 10, weight: .semibold))
    }

    private func candlePlot(bodyWidth: CGFloat) -> some View {
        Chart {
            ForEach(zoomedPeriodBars) { bar in
                let rising = bar.close >= bar.open
                let candleColor = rising ? Color.red : Color.green
                let lowBody = min(bar.open, bar.close)
                let highBody = max(bar.open, bar.close)
                // 一字线（开=收）时给一个最小高度，否则实体画不出来
                let pad = (highBody - lowBody) < highBody * 0.0008 ? highBody * 0.0008 : 0
                RuleMark(x: .value("日期", bar.date), yStart: .value("最低", bar.low), yEnd: .value("最高", bar.high))
                    .foregroundStyle(candleColor.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: max(0.8, bodyWidth * 0.16)))
                RectangleMark(x: .value("日期", bar.date),
                              yStart: .value("开盘", lowBody),
                              yEnd: .value("收盘", highBody + pad),
                              width: .fixed(bodyWidth))
                    .foregroundStyle(candleColor)
            }
            ForEach(average(5, source: zoomedPeriodBars)) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA5", point.value))
                    .foregroundStyle(ma5Color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(average(10, source: zoomedPeriodBars)) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA10", point.value))
                    .foregroundStyle(ma10Color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(average(20, source: zoomedPeriodBars)) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA20", point.value))
                    .foregroundStyle(ma20Color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(average(60, source: zoomedPeriodBars)) { point in
                LineMark(x: .value("日期", point.date), y: .value("MA60", point.value))
                    .foregroundStyle(ma60Color).lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
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
        do {
            instrumentAIResult = try await AIAnalysisService.analyzeInstrument(
                config: store.data.aiAnalysisConfig, holding: holding, quote: quote, bars: allBars,
                intradayBars: selectedIntradayBars, priceLevels: priceLevelsPromptText)
        } catch { instrumentAIMessage = error.localizedDescription }
    }
}
