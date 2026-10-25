import SwiftUI

/// 图表下方副图类型。老工程用「成交量 / 成交额 / MACD」三选一，这里的口径一致。
enum NextSubchartKind: String, CaseIterable, Identifiable {
    case volume, amount, macd, off
    var id: String { rawValue }
    var title: String {
        switch self { case .volume: "成交量"; case .amount: "成交额"; case .macd: "MACD"; case .off: "关" }
    }
}

/// Shared by ETF detail, full-screen chart, asset history and AI evidence.
/// Price and IOPV share one dynamically fitted price axis so neither curve is
/// visually detached. Cost remains a reference overlay and never distorts scale.
struct UnifiedChartView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let dataset: NextChartDataset?
    let interval: Binding<NextChartInterval>
    let costPerUnit: Decimal?
    @Binding var selectedTime: Date?
    var securityCode: String? = nil
    var expanded = false
    /// 所有周期都允许放大；分时默认显示完整交易时段，放大后聚焦最新区间。
    private var zoomAllowed: Bool { true }
    /// 分时图比日 K 更吃高度。同花顺的分时主图几乎占满一屏，副图（MACD/量）也要能看清。
    /// 之前统一 250 / 430，手机上主图被压得只剩一条带，MACD 柱挤成一条缝。
    private var chartHeight: CGFloat {
        let isIntraday = interval.wrappedValue == .intraday
        if expanded { return isIntraday ? 760 : 640 }
        return isIntraday ? 500 : 380
    }
    @State private var magnification = 1.0
    @State private var pinchBase: Double?
    @State private var intradaySessionDate = Date()
    @State private var latestIntradaySessionDate = Date()
    @State private var initializedIntradaySession = false
    private var marketTimeZone: TimeZone { TimeZone(identifier: "Asia/Shanghai") ?? .current }
    private var marketCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = marketTimeZone
        return calendar
    }
    @State private var visibleLayers: Set<String> = ["price", "volume", "iopv", "cost", "average", "previous", "ma5", "ma10", "ma20", "ma60", "ma250", "trades", "range"]
    /// 下方副图：成交量 / 成交额 / MACD / 关。
    /// 老工程把这三张副图都做了，而且分时图下面就是 MACD —— 这里补齐同样的口径。
    @State private var subchart: NextSubchartKind = .volume
    /// 日 K 是否前复权。分红除息会在原始价上留下缺口，长期均线会被拉歪；
    /// 默认开启（与券商一致），可切换成不复权看真实成交价。
    @State private var adjustedPrices = true
    private var activeDataset: NextChartDataset? {
        guard let dataset else { return nil }
        if interval.wrappedValue == .intraday, expanded, let code = securityCode {
            if !NextIntradayAxis.sameTradingDay(intradaySessionDate, latestIntradaySessionDate) {
                // Never leave today's line on screen under a selected historical date
                // while that archive is loading or unavailable.
                return model.historicalMinuteData[NextIntradayDatasetGuard.archiveKey(code: code, day: intradaySessionDate)]
            }
            return dataset.interval == .intraday ? dataset : nil
        }
        return (interval.wrappedValue == .intraday ? dataset.interval == .intraday : dataset.interval == .day) ? dataset : nil
    }

    /// 应用复权后的全量样本。分时不受影响；日线在开启复权时按派息事件下调历史价。
    private var workingSamples: [NextChartSample] {
        guard let dataset = activeDataset else { return [] }
        let base = dataset.orderedSamples
        guard interval.wrappedValue != .intraday, dataset.interval == .day,
              adjustedPrices, let code = securityCode else { return base }
        let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
        return NextPriceAdjustment.forwardAdjusted(base, events: events, code: code)
    }

    private var samples: [NextChartSample] {
        let all = workingSamples
        guard !all.isEmpty else { return [] }
        // Intraday coordinates represent one exchange session. When an archive
        // contains multiple days, never overlay them on the same fixed axis.
        let sessionSamples = interval.wrappedValue == .intraday
            ? NextIntradayAxis.sessionSamples(from: all, selectedDate: selectedTime)
            : all
        let chartBars: [NextChartSample]
        if interval.wrappedValue == .week || interval.wrappedValue == .month {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            let groups = Dictionary(grouping: sessionSamples) { sample -> String in
                let parts = calendar.dateComponents([.year, .month, .weekOfYear], from: sample.timestamp)
                return interval.wrappedValue == .week ? "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)" : "\(parts.year ?? 0)-M\(parts.month ?? 0)"
            }
            chartBars = groups.values.compactMap { rows in
                let ordered = rows.sorted { $0.timestamp < $1.timestamp }
                guard let first = ordered.first, let last = ordered.last else { return nil }
                let highs = ordered.compactMap(\.high), lows = ordered.compactMap(\.low)
                let volume = ordered.compactMap(\.volume).reduce(Decimal.zero, +)
                return NextChartSample(timestamp: last.timestamp, open: first.open, high: highs.max(), low: lows.min(), close: last.close,
                    iopv: last.iopv, volume: volume > 0 ? volume : nil)
            }.sorted { $0.timestamp < $1.timestamp }
        } else { chartBars = sessionSamples }
        let window: Int
        switch interval.wrappedValue {
        case .fiveDay: window = min(5, chartBars.count)
        case .threeMonth: window = min(66, chartBars.count)
        case .year: window = min(252, chartBars.count)
        case .intraday, .day, .week, .month, .all: window = chartBars.count
        }
        let effectiveZoom = magnification
        let count = max(1, Int(Double(min(chartBars.count, window)) / max(1, effectiveZoom)))
        return Array(chartBars.suffix(count))
    }
    private var visibleTimeDomain: ClosedRange<Date>? {
        guard let first = samples.first?.timestamp else { return nil }
        if interval.wrappedValue == .intraday && magnification <= 1.001 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            guard let start = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: first),
                  let end = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: first) else { return nil }
            return start...end
        }
        guard let last = samples.last?.timestamp else { return nil }
        return first == last ? first.addingTimeInterval(-30)...last.addingTimeInterval(30) : first...last
    }
    private var visiblePriceDomain: ClosedRange<Decimal>? {
        var values = samples.flatMap { [$0.low, $0.high, Optional($0.close)].compactMap { $0 } }
        if visibleLayers.contains("iopv") { values.append(contentsOf: samples.compactMap(\.iopv)) }
        var intradayPrevious: Decimal?
        if interval.wrappedValue == .intraday, visibleLayers.contains("previous"), let code = securityCode,
           let previous = model.quotes[code]?.quote.previousClose, previous > 0 {
            intradayPrevious = previous
            values.append(previous)
        }
        if let dataset = activeDataset, dataset.interval == .day,
           let first = samples.first?.timestamp, let last = samples.last?.timestamp {
            let moving: [(String, Int)] = [("ma5", 5), ("ma10", 10), ("ma20", 20), ("ma60", 60), ("ma250", 250)]
            let source = workingSamples
            // MA250 在历史不足 250 根时按实际可用根数降级，否则这条线永远不出现。
            for (key, period) in moving where visibleLayers.contains(key)
                && source.count >= (key == "ma250" ? 2 : period)
                && (key != "ma250" || interval.wrappedValue != .intraday) {
                let effective = key == "ma250" ? min(period, source.count) : period
                let average = NextMovingAverage.series(source, period: effective)
                for index in source.indices where source[index].timestamp >= first && source[index].timestamp <= last {
                    if let value = average[index] { values.append(value) }
                }
            }
        }
        guard let low = values.min(), let high = values.max() else { return nil }
        // 分时口径与老工程一致：**昨收 = 0 轴，上下严格对称**，
        // 都取「今天实际到达的最大涨跌幅」，不取整、不额外留余量；
        // 全天几乎不动时兜底 ±0.5%，否则纵轴被压到接近 0，价格线会被放大成剧烈波动。
        // IOPV / 均价超出时先放宽再对称，避免把曲线画出画布。
        if interval.wrappedValue == .intraday, let previous = intradayPrevious, previous > 0 {
            let base = NextNum.double(previous)
            let up = (NextNum.double(high) - base) / base
            let down = (base - NextNum.double(low)) / base
            let move = max(abs(up), abs(down), 0.005)
            return NextNum.decimal(base * (1 - move))...NextNum.decimal(base * (1 + move))
        }
        let pad = low == high ? max(abs(low) / Decimal(100), Decimal(1) / Decimal(10_000)) : (high - low) * Decimal(6) / Decimal(100)
        return (low - pad)...(high + pad)
    }
    private var displayedCrosshairTime: Date? {
        guard let selectedTime, let visibleTimeDomain else { return nil }
        return min(max(selectedTime, visibleTimeDomain.lowerBound), visibleTimeDomain.upperBound)
    }
    private var selectedSample: NextChartSample? {
        guard let displayedCrosshairTime else { return nil }
        return samples.min { abs($0.timestamp.timeIntervalSince(displayedCrosshairTime)) < abs($1.timestamp.timeIntervalSince(displayedCrosshairTime)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if expanded && interval.wrappedValue == .intraday {
                HStack(spacing: 8) {
                    Text(intradaySessionDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption.monospacedDigit()).foregroundStyle(p.muted)
                    if !model.preferences.nasBaseURL.isEmpty, let code = securityCode {
                        DatePicker("选择历史交易日", selection: $intradaySessionDate, in: ...Date.now, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.compact)
                            .environment(\.calendar, marketCalendar).environment(\.timeZone, marketTimeZone)
                            .accessibilityLabel("选择历史分时日期")
                            .onChange(of: intradaySessionDate) { _, day in
                                let previous = latestIntradaySessionDate
                                selectedTime = nil
                                Task {
                                    if await model.loadNASMinute(code: code, day: day) {
                                        saveChartState()
                                    } else {
                                        intradaySessionDate = previous
                                        saveChartState()
                                    }
                                }
                            }
                        Button("最新") {
                            intradaySessionDate = latestIntradaySessionDate
                            selectedTime = nil
                            saveChartState()
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(p.forest)
                        .accessibilityIdentifier("chart.intraday.latest")
                    } else {
                        Text("连接 NAS 可查询历史分时")
                            .font(.caption2).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(NextChartInterval.allCases, id: \.rawValue) { value in
                            Button { interval.wrappedValue = value; selectedTime = nil; magnification = 1; saveChartState() } label: {
                                Text(label(value)).font(.system(size: 10, weight: interval.wrappedValue == value ? .semibold : .regular))
                                    .foregroundStyle(interval.wrappedValue == value ? p.forest : p.muted)
                                    .padding(.vertical, 6).padding(.horizontal, 6)
                                    .background(interval.wrappedValue == value ? p.tint : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityIdentifier("chart.period.\(value.rawValue)")
                        }
                    }
                }
                if zoomAllowed {
                    HStack(spacing: 1) {
                        Button { changeZoom(by: 1 / 1.5) } label: {
                            Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 30)
                        }
                        .accessibilityLabel("缩小图表")
                        .accessibilityIdentifier("chart.zoom.out")
                        .disabled(magnification <= 1.001)
                        Text("×\(magnification, specifier: "%.1f")")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(p.muted).frame(minWidth: 27)
                            .accessibilityIdentifier("chart.zoom.level")
                        Button { changeZoom(by: 1.5) } label: {
                            Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 30)
                        }
                        .accessibilityLabel("放大图表")
                        .accessibilityIdentifier("chart.zoom.in")
                        .disabled(magnification >= 12)
                        Button { magnification = 1; saveChartState() } label: {
                            Text("复位").font(.system(size: 9, weight: .medium)).frame(height: 30).padding(.horizontal, 4)
                        }
                        .accessibilityIdentifier("chart.zoom.reset")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.forest)
                    .background(p.tint.opacity(0.7), in: Capsule())
                    .fixedSize()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    layerButton("价格", key: "price", available: true)
                    layerButton("IOPV", key: "iopv", available: activeDataset?.iopvSource != nil)
                    layerButton("成本线", key: "cost", available: costPerUnit != nil)
                    layerButton("MA5", key: "ma5", available: (activeDataset?.orderedSamples.count ?? 0) >= 5)
                    layerButton("MA10", key: "ma10", available: (activeDataset?.orderedSamples.count ?? 0) >= 10)
                    layerButton("MA20", key: "ma20", available: (activeDataset?.orderedSamples.count ?? 0) >= 20)
                    layerButton("MA60", key: "ma60", available: (activeDataset?.orderedSamples.count ?? 0) >= 60)
                    layerButton("MA250", key: "ma250", available: activeDataset?.interval == .day && (activeDataset?.orderedSamples.count ?? 0) >= 2)
                    layerButton("均价", key: "average", available: activeDataset?.interval == .intraday && samples.contains(where: { $0.volume != nil }))
                    layerButton("昨收", key: "previous", available: activeDataset?.interval == .intraday && securityCode.flatMap { model.quotes[$0]?.quote.previousClose } != nil)
                    layerButton("B/S", key: "trades", available: securityCode.map { code in model.book.fills.contains(where: { $0.code == code }) } ?? false)
                    layerButton("高低", key: "range", available: true)
                }
            }
            HStack(spacing: 6) {
                Text("副图").font(.system(size: 9)).foregroundStyle(p.muted)
                ForEach(NextSubchartKind.allCases) { kind in
                    Button { subchart = kind } label: {
                        Text(kind.title).font(.system(size: 9, weight: subchart == kind ? .semibold : .regular))
                            .foregroundStyle(subchart == kind ? p.forest : p.muted)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(subchart == kind ? p.tint : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("副图 \(kind.title)")
                }
                Spacer(minLength: 0)
                if interval.wrappedValue == .day {
                    Button { adjustedPrices.toggle() } label: {
                        Text(adjustedPrices ? "前复权" : "不复权")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(adjustedPrices ? p.chartViolet : p.muted)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(adjustedPrices ? p.chartViolet.opacity(0.14) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(adjustedPrices ? "当前前复权，点击切换不复权" : "当前不复权，点击切换前复权")
                }
            }
            if interval.wrappedValue == .day && (activeDataset?.orderedSamples.count ?? 0) < 250 {
                Text("MA250 需要 250 根有效日 K · 当前已归档 \(activeDataset?.orderedSamples.count ?? 0) 根；补足后会自动计算并绘制。")
                    .font(.caption2).foregroundStyle(p.muted)
                    .accessibilityIdentifier("chart.ma250.insufficient-history")
            }
            if samples.isEmpty {
                if let dataset {
                    GPStatus(title: "该周期暂无历史数据", detail: "当前数据周期为“\(label(dataset.interval))”。切换日 K 或分时查看；不会把其他周期的数据冒充为本周期。", symbol: "chart.xyaxis.line")
                        .frame(height: chartHeight)
                } else {
                    GPStatus(title: "暂无可绘制行情", detail: "分时由手机读取，日 K 由 NAS 归档后下载；离线时显示已有缓存。", symbol: "chart.xyaxis.line")
                        .frame(height: chartHeight)
                }
            } else {
                GeometryReader { geometry in
                    Canvas { context, size in draw(context: &context, size: size) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 8).onChanged { value in
                            guard value.startLocation.x > 26, let range = visibleTimeDomain else { return }
                            let rightAxis: CGFloat = 12
                            let ratio = min(1, max(0, (value.location.x - 43) / max(1, geometry.size.width - 43 - rightAxis)))
                            if interval.wrappedValue == .intraday {
                                let target = NextIntradayAxis.length * ratio
                                selectedTime = samples.min { abs(NextIntradayAxis.minute($0.timestamp) - target) < abs(NextIntradayAxis.minute($1.timestamp) - target) }?.timestamp
                            } else {
                                selectedTime = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) * ratio)
                            }
                        }.onEnded { _ in saveChartState() })
                        .simultaneousGesture(MagnifyGesture().onChanged { value in
                            guard zoomAllowed else { return }
                            if pinchBase == nil { pinchBase = magnification }
                            magnification = min(12, max(1, (pinchBase ?? magnification) * Double(value.magnification)))
                        }.onEnded { _ in pinchBase = nil; saveChartState() })
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("chart.plot")
                        .accessibilityLabel("价格、IOPV、成交量共用价格纵轴的图表")
                        .accessibilityValue(selectedSample.map { "\($0.timestamp.formatted(date: .numeric, time: .shortened))，价格 ¥\(NextMoney.text($0.close, digits: 3))" } ?? "拖动或使用前后数据点操作查看历史")
                        .accessibilityAction(named: "放大图表") { guard zoomAllowed else { return }; magnification = min(12, magnification * 1.5); saveChartState() }
                        .accessibilityAction(named: "缩小图表") { guard zoomAllowed else { return }; magnification = max(1, magnification / 1.5); saveChartState() }
                        .accessibilityAction(named: "上一个数据点") { moveCrosshair(-1) }
                        .accessibilityAction(named: "下一个数据点") { moveCrosshair(1) }
                }.frame(height: chartHeight)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        legend("价格", color: p.chartBlue)
                        if visibleLayers.contains("average") && activeDataset?.interval == .intraday { legend("均价", color: p.chartGold) }
                        if visibleLayers.contains("ma5") && activeDataset?.interval == .day && (activeDataset?.orderedSamples.count ?? 0) >= 5 { legend("MA5", color: p.chartGold) }
                        if visibleLayers.contains("ma10") && activeDataset?.interval == .day && (activeDataset?.orderedSamples.count ?? 0) >= 10 { legend("MA10", color: p.chartBlue) }
                        if visibleLayers.contains("ma20") && activeDataset?.interval == .day && (activeDataset?.orderedSamples.count ?? 0) >= 20 { legend("MA20", color: p.jade) }
                        if visibleLayers.contains("ma60") && activeDataset?.interval == .day && (activeDataset?.orderedSamples.count ?? 0) >= 60 { legend("MA60", color: p.chartViolet) }
                        if visibleLayers.contains("ma250") && activeDataset?.interval == .day {
                            let bars = activeDataset?.orderedSamples.count ?? 0
                            legend(bars >= 250 ? "MA250" : "MA250·\(bars)根", color: p.chartLongMA)
                        }
                        if visibleLayers.contains("previous") && activeDataset?.interval == .intraday { legend("昨收", color: p.muted) }
                        if activeDataset?.iopvSource != nil { legend("IOPV · 同轴", color: p.chartViolet) }
                        if costPerUnit != nil { legend("成本", color: p.chartCost) }
                        if visibleLayers.contains("trades") { legend("B 买 / S 卖", color: p.jade) }
                        if visibleLayers.contains("range") { legend("可视高低", color: p.muted) }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    if let point = selectedSample {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("¥\(NextMoney.text(point.close, digits: 3)) · \(point.timestamp.formatted(date: .omitted, time: .shortened))")
                            if let iopv = point.iopv { Text("IOPV ¥\(NextMoney.text(iopv, digits: 3)) · 溢折价 \(NextMoney.text((point.close / iopv - 1) * 100, digits: 3))%") }
                            if let volume = point.volume { Text("成交量 \(NextMoney.text(volume, digits: 0))") }
                        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(p.ink).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .onAppear {
            refreshLatestIntradaySession()
        }
        .onChange(of: dataset?.observedAt) { _, _ in
            refreshLatestIntradaySession()
        }
        .onAppear { restoreChartState() }
        .onChange(of: interval.wrappedValue) { _, value in
            saveChartState()
            if value != .intraday, let securityCode { Task { await model.refreshDaily(securityCode, required: true) } }
        }
        .onChange(of: visibleLayers) { _, _ in saveChartState() }
    }

    /// Decimal 不能直接丢给 CGFloat(...)：CGFloat 只有 BinaryInteger / BinaryFloatingPoint
    /// 两种泛型入口，Decimal 两个都不满足。统一从 NSDecimalNumber 转 Double 再转 CGFloat。
    private func cg(_ value: Decimal) -> CGFloat {
        CGFloat(NSDecimalNumber(decimal: value).doubleValue)
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard let dataset = activeDataset, let domain = visiblePriceDomain, let time = visibleTimeDomain, samples.count > 0 else { return }
        // 左侧只留价格刻度的宽度，右侧几乎贴边：手机上横向空间很紧，
        // 原来 43 + 12 的留白让绘图区少了 55pt，看起来整张图偏窄。
        let left: CGFloat = 33, right: CGFloat = 5, top: CGFloat = 9
        let axisHeight: CGFloat = 17
        let subHeight: CGFloat = subchart == .off ? 0 : 78
        let subGap: CGFloat = subchart == .off ? 0 : 9
        let plot = CGRect(x: left, y: top, width: max(1, size.width - left - right),
                          height: max(40, size.height - top - axisHeight - subHeight - subGap))
        for tick in 0...4 {
            let y = plot.minY + plot.height * CGFloat(tick) / 4
            var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(grid, with: .color(p.line.opacity(0.75)), lineWidth: 0.7)
            let v = domain.upperBound - (domain.upperBound - domain.lowerBound) * Decimal(tick) / 4
            context.draw(Text(NextMoney.text(v, digits: 3)).font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: left / 2, y: y))
        }
        func x(_ date: Date) -> CGFloat {
            let fraction: Double
            if interval.wrappedValue == .intraday {
                fraction = NextIntradayAxis.minute(date) / NextIntradayAxis.length
            } else {
                fraction = date.timeIntervalSince(time.lowerBound) / max(0.001, time.upperBound.timeIntervalSince(time.lowerBound))
            }
            return plot.minX + plot.width * CGFloat(min(1, max(0, fraction)))
        }
        func priceY(_ value: Decimal) -> CGFloat { plot.maxY - plot.height * cg((value - domain.lowerBound) / max(Decimal(1) / Decimal(10_000_000), domain.upperBound - domain.lowerBound)) }
        var pricePath = Path()
        for (i, point) in samples.enumerated() {
            let pos = CGPoint(x: x(point.timestamp), y: priceY(point.close))
            if i == 0 { pricePath.move(to: pos) } else { pricePath.addLine(to: pos) }
        }
        if visibleLayers.contains("price") {
            let hasOHLC = interval.wrappedValue != .intraday && samples.contains { $0.open != nil && $0.high != nil && $0.low != nil }
            if hasOHLC {
                // 蜡烛体必须落在整像素上：以前用圆角矩形 + 亚像素中心，宽度只有 1–3px 时
                // 圆角会把两侧糊成灰边，一串 K 线看上去发虚。改成直角矩形 + 整像素对齐，
                // 影线固定 1pt（3x 屏正好 3 个像素），才和同花顺一样"细但清"。
                let rawWidth = plot.width / CGFloat(max(1, samples.count)) * 0.62
                let candleWidth = max(1, min(9, rawWidth.rounded()))
                let half = candleWidth / 2
                for point in samples {
                    guard let open = point.open, let high = point.high, let low = point.low else { continue }
                    let snapped = (x(point.timestamp) + 0.5).rounded() - 0.5
                    let yHigh = priceY(high), yLow = priceY(low)
                    let rising = point.close >= open
                    let color = rising ? p.gpUp : p.gpDown
                    var wick = Path()
                    wick.move(to: CGPoint(x: snapped, y: yHigh))
                    wick.addLine(to: CGPoint(x: snapped, y: yLow))
                    context.stroke(wick, with: .color(color), lineWidth: 1)
                    let yOpen = priceY(open), yClose = priceY(point.close)
                    let top = min(yOpen, yClose).rounded()
                    let bottom = max(yOpen, yClose).rounded()
                    let rect = CGRect(x: (snapped - half).rounded(), y: top,
                                      width: candleWidth, height: max(1, bottom - top))
                    context.fill(Path(rect), with: .color(color))
                }
            } else {
                context.stroke(pricePath, with: .color(p.ink), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
        if visibleLayers.contains("iopv") {
            var iopvPath = Path(); var started = false
            for point in samples {
                guard let iopv = point.iopv, iopv > 0 else { started = false; continue }
                let pos = CGPoint(x: x(point.timestamp), y: priceY(iopv))
                if !started { iopvPath.move(to: pos); started = true } else { iopvPath.addLine(to: pos) }
            }
            context.stroke(iopvPath, with: .color(p.chartViolet), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [3, 2]))
        }
        // Moving averages include earlier bars outside the zoom window.
        let fullSamples = workingSamples
        for (key, period, color, width) in [("ma5", 5, p.chartGold, 1.2), ("ma10", 10, p.chartBlue, 1.1), ("ma20", 20, p.jade, 1.15), ("ma60", 60, p.chartViolet, 1.1), ("ma250", 250, p.chartLongMA, 1.25)]
        where visibleLayers.contains(key)
            && fullSamples.count >= (key == "ma250" ? 2 : period)
            && (key != "ma250" || dataset.interval == .day) {
            // 与 visiblePriceDomain 保持一致：MA250 历史不足时按可用根数降级，缩放不影响。
            let effective = key == "ma250" ? min(period, fullSamples.count) : period
            let averages = NextMovingAverage.series(fullSamples, period: effective)
            var path = Path(); var started = false
            for (index, point) in fullSamples.enumerated() where index >= effective - 1 && point.timestamp >= time.lowerBound && point.timestamp <= time.upperBound {
                guard let average = averages[index] else { continue }
                let position = CGPoint(x: x(point.timestamp), y: priceY(average))
                if !started { path.move(to: position); started = true } else { path.addLine(to: position) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        func referenceLine(_ value: Decimal, color: Color, title: String, dash: [CGFloat]) {
            let y = priceY(value)
            guard y >= plot.minY && y <= plot.maxY else { return }
            var path = Path(); path.move(to: CGPoint(x: plot.minX, y: y)); path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 0.9, dash: dash))
            context.draw(Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(color),
                         at: CGPoint(x: plot.maxX - 44, y: max(plot.minY + 9, min(plot.maxY - 9, y - 8))))
        }
        if visibleLayers.contains("previous"), dataset.interval == .intraday, let code = securityCode,
           let quote = model.quotes[code]?.quote, let first = samples.first,
           Calendar(identifier: .gregorian).isDate(quote.time, inSameDayAs: first.timestamp) {
            let previous = quote.previousClose
            referenceLine(previous, color: p.muted, title: "昨收 ¥\(NextMoney.text(previous, digits: 3))", dash: [3, 3])
        }
        if visibleLayers.contains("average"), dataset.interval == .intraday {
            var cumulativePrice = Decimal.zero; var cumulativeVolume = Decimal.zero; var averagePath = Path(); var started = false
            for point in samples {
                guard let volume = point.volume, volume > 0 else { continue }
                cumulativePrice += point.close * volume; cumulativeVolume += volume
                let position = CGPoint(x: x(point.timestamp), y: priceY(cumulativePrice / cumulativeVolume))
                if !started { averagePath.move(to: position); started = true } else { averagePath.addLine(to: position) }
            }
            if started { context.stroke(averagePath, with: .color(p.chartGold), style: StrokeStyle(lineWidth: 1, lineCap: .round)) }
        }
        if visibleLayers.contains("range"), let highest = samples.compactMap({ $0.high ?? $0.close }).max(),
           let lowest = samples.compactMap({ $0.low ?? $0.close }).min() {
            referenceLine(highest, color: p.muted, title: "高 ¥\(NextMoney.text(highest, digits: 3))", dash: [1, 5])
            referenceLine(lowest, color: p.muted, title: "低 ¥\(NextMoney.text(lowest, digits: 3))", dash: [1, 5])
        }
        if visibleLayers.contains("trades"), let code = securityCode {
            for fill in model.book.fills where fill.code == code {
                var marketCalendar = Calendar(identifier: .gregorian)
                marketCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                let stamp = dataset.interval == .day ? marketCalendar.startOfDay(for: fill.date) : fill.date
                guard stamp >= time.lowerBound, stamp <= time.upperBound,
                      fill.price >= domain.lowerBound, fill.price <= domain.upperBound else { continue }
                let center = CGPoint(x: x(stamp), y: priceY(fill.price))
                let buy = fill.side == "buy"
                let color = buy ? p.gpUp : p.gpDown
                context.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(color))
                context.draw(Text(buy ? "B" : "S").font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: center)
            }
        }
        if visibleLayers.contains("cost"), let cost = costPerUnit {
            let y = priceY(cost)
            if y >= plot.minY && y <= plot.maxY {
                var costPath = Path(); costPath.move(to: CGPoint(x: plot.minX, y: y)); costPath.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(costPath, with: .color(p.chartCost), style: StrokeStyle(lineWidth: 0.9, dash: [6, 3]))
            } else {
                let labelY = cost < domain.lowerBound ? plot.maxY : plot.minY
                context.draw(Text("成本线超出本段价格轴 · ¥\(NextMoney.text(cost, digits: 3))").font(.system(size: 8, weight: .medium)).foregroundColor(p.muted), at: CGPoint(x: plot.midX, y: labelY))
            }
        }
        if subchart != .off, subHeight > 1 {
            let subRect = CGRect(x: left, y: plot.maxY + subGap, width: plot.width, height: subHeight)
            var separator = Path()
            separator.move(to: CGPoint(x: plot.minX, y: subRect.minY - subGap / 2))
            separator.addLine(to: CGPoint(x: plot.maxX, y: subRect.minY - subGap / 2))
            context.stroke(separator, with: .color(p.line.opacity(0.8)), lineWidth: 0.7)
            switch subchart {
            case .volume: drawVolumeBars(context: &context, in: subRect, xOf: x)
            case .amount: drawAmountBars(context: &context, in: subRect, xOf: x)
            case .macd: drawMACD(context: &context, in: subRect, time: time, xOf: x)
            case .off: break
            }
        }
        if let selectedTime = displayedCrosshairTime {
            let crossX = x(selectedTime)
            var cross = Path(); cross.move(to: CGPoint(x: crossX, y: plot.minY)); cross.addLine(to: CGPoint(x: crossX, y: plot.maxY + subGap + subHeight))
            context.stroke(cross, with: .color(p.terracotta), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
        if interval.wrappedValue == .intraday {
            for (minute, title) in NextIntradayAxis.ticks {
                let markX = plot.minX + plot.width * CGFloat(minute / NextIntradayAxis.length)
                var tick = Path(); tick.move(to: CGPoint(x: markX, y: plot.maxY)); tick.addLine(to: CGPoint(x: markX, y: plot.maxY + 3))
                context.stroke(tick, with: .color(p.muted.opacity(0.6)), lineWidth: 0.7)
                let labelX: CGFloat
                switch title {
                case "09:30": labelX = markX + 14
                case "11:30": labelX = markX - 10
                case "13:00": labelX = markX + 10
                case "15:00": labelX = markX - 14
                default: labelX = markX
                }
                let labelY = size.height - 5
                context.draw(Text(title).font(.system(size: 7.2, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: labelX, y: labelY))
            }
            // Explicit lunch-break marker: its small fixed gap preserves morning/afternoon scale.
            let breakX = plot.minX + plot.width * CGFloat(126.0 / NextIntradayAxis.length)
            context.draw(Text("休市").font(.system(size: 6.5)).foregroundColor(p.muted.opacity(0.7)), at: CGPoint(x: breakX, y: plot.maxY - 5))
        } else {
            context.draw(Text("\(time.lowerBound.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: plot.minX + 12, y: size.height - 5))
            context.draw(Text("\(time.upperBound.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 8, design: .monospaced)).foregroundColor(p.muted), at: CGPoint(x: plot.maxX - 12, y: size.height - 5))
        }
    }

    // MARK: - 副图

    /// 量柱涨跌配色（与老工程一致）：逐根与上一根收盘比，第一根用昨收作基准。
    /// 国内口径红涨绿跌。收盘序列在调用处算一次，避免循环里反复重建 `samples`。
    private func volumeTones() -> [Color] {
        let closes = samples.map(\.close)
        let first = securityCode.flatMap { model.quotes[$0]?.quote.previousClose }
        return closes.enumerated().map { index, close in
            let baseline = index > 0 ? closes[index - 1] : (first ?? close)
            return close >= baseline ? p.gpUp : p.gpDown
        }
    }

    private func drawVolumeBars(context: inout GraphicsContext, in rect: CGRect, xOf: (Date) -> CGFloat) {
        let bars = samples
        guard let maxVolume = bars.compactMap(\.volume).max(), maxVolume > 0 else {
            context.draw(Text("无成交量数据").font(.system(size: 8)).foregroundColor(p.muted), at: CGPoint(x: rect.midX, y: rect.midY))
            return
        }
        let barWidth = max(1, min(9, rect.width / CGFloat(max(1, bars.count)) * 0.62))
        let tones = volumeTones()
        for (index, point) in bars.enumerated() {
            guard let volume = point.volume, tones.indices.contains(index) else { continue }
            let height = (rect.height - 12) * cg(volume / maxVolume)
            let snapped = (xOf(point.timestamp) + 0.5).rounded() - 0.5
            let barRect = CGRect(x: (snapped - barWidth / 2).rounded(), y: rect.maxY - max(1, height), width: max(1, barWidth.rounded()), height: max(1, height))
            context.fill(Path(barRect), with: .color(tones[index]))
        }
        context.draw(Text("量 \(NextMoney.text(maxVolume, digits: 0))").font(.system(size: 7.5, design: .monospaced)).foregroundColor(p.muted),
                     at: CGPoint(x: rect.minX + 30, y: rect.minY + 5))
    }

    private func drawAmountBars(context: inout GraphicsContext, in rect: CGRect, xOf: (Date) -> CGFloat) {
        // 日 K 没有成交额列，按「量（手）×100×收盘价」估算，界面上标明是估算。
        let bars = samples
        let turnovers = bars.map { point -> Decimal in
            guard let volume = point.volume, volume > 0 else { return 0 }
            return volume * 100 * point.close
        }
        guard let maxTurnover = turnovers.max(), maxTurnover > 0 else {
            context.draw(Text("无成交额数据").font(.system(size: 8)).foregroundColor(p.muted), at: CGPoint(x: rect.midX, y: rect.midY))
            return
        }
        let barWidth = max(1, min(9, rect.width / CGFloat(max(1, bars.count)) * 0.62))
        let tones = volumeTones()
        for (index, point) in bars.enumerated() {
            let value = turnovers[index]
            guard value > 0, tones.indices.contains(index) else { continue }
            let height = (rect.height - 12) * cg(value / maxTurnover)
            let snapped = (xOf(point.timestamp) + 0.5).rounded() - 0.5
            let barRect = CGRect(x: (snapped - barWidth / 2).rounded(), y: rect.maxY - max(1, height), width: max(1, barWidth.rounded()), height: max(1, height))
            context.fill(Path(barRect), with: .color(tones[index].opacity(0.9)))
        }
        context.draw(Text("额 \(amountText(maxTurnover))·估算").font(.system(size: 7.5, design: .monospaced)).foregroundColor(p.muted),
                     at: CGPoint(x: rect.minX + 46, y: rect.minY + 5))
    }

    private func amountText(_ value: Decimal) -> String {
        let amount = NextNum.double(value)
        if amount >= 100_000_000 { return String(format: "%.3f亿", amount / 100_000_000) }
        if amount >= 10_000 { return String(format: "%.3f万", amount / 10_000) }
        return String(format: "%.0f", amount)
    }

    /// MACD 副图：柱 + DIF/DEA。分时用当前交易日的分钟收盘序列，
    /// 日 K 用全量日线（缩放只改变可视区间，不改变已经算好的 EMA）。
    private func drawMACD(context: inout GraphicsContext, in rect: CGRect, time: ClosedRange<Date>, xOf: (Date) -> CGFloat) {
        let source = interval.wrappedValue == .intraday ? samples : workingSamples
        guard source.count >= 35 else {
            context.draw(Text("MACD 需 35 根以上数据（当前 \(source.count) 根）").font(.system(size: 8)).foregroundColor(p.muted),
                         at: CGPoint(x: rect.midX, y: rect.midY))
            return
        }
        let points = NextMACD.series(source.map { NextNum.double($0.close) })
        let visible = zip(source, points).filter { pair in
            pair.1 != nil && pair.0.timestamp >= time.lowerBound && pair.0.timestamp <= time.upperBound
        }
        guard let maxAbs = visible.compactMap({ $0.1 }).map({ max(abs($0.dif), abs($0.dea), abs($0.histogram)) }).max(), maxAbs > 0 else {
            context.draw(Text("MACD 数据不足").font(.system(size: 8)).foregroundColor(p.muted), at: CGPoint(x: rect.midX, y: rect.midY))
            return
        }
        func y(_ value: Double) -> CGFloat { rect.midY - (rect.height - 12) / 2 * CGFloat(value / maxAbs) }
        var zero = Path()
        zero.move(to: CGPoint(x: rect.minX, y: rect.midY))
        zero.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        context.stroke(zero, with: .color(p.line.opacity(0.9)), lineWidth: 0.6)
        let barWidth = max(0.8, min(6, rect.width / CGFloat(max(1, visible.count)) * 0.55))
        for (sample, point) in visible {
            guard let point else { continue }
            let centerX = xOf(sample.timestamp)
            let top = min(y(0), y(point.histogram))
            let height = max(0.8, abs(y(point.histogram) - y(0)))
            let color = point.histogram >= 0 ? p.gpUp : p.gpDown
            context.fill(Path(roundedRect: CGRect(x: centerX - barWidth / 2, y: top, width: barWidth, height: height), cornerRadius: 0.5),
                         with: .color(color.opacity(0.8)))
        }
        func line(_ keyPath: (NextMACDPoint) -> Double, color: Color, width: CGFloat) {
            var path = Path(); var started = false
            for (sample, point) in visible {
                guard let point else { continue }
                let position = CGPoint(x: xOf(sample.timestamp), y: y(keyPath(point)))
                if !started { path.move(to: position); started = true } else { path.addLine(to: position) }
            }
            if started { context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)) }
        }
        line({ $0.dif }, color: p.chartGold, width: 1.2)
        line({ $0.dea }, color: p.chartBlue, width: 1.2)
        context.draw(Text("MACD(12,26,9)").font(.system(size: 7.5, design: .monospaced)).foregroundColor(p.muted),
                     at: CGPoint(x: rect.minX + 48, y: rect.minY + 5))
    }

    private func label(_ interval: NextChartInterval) -> String { switch interval { case .intraday: "分时"; case .fiveDay: "5日"; case .day: "日K"; case .week: "周K"; case .month: "月K"; case .threeMonth: "近3月"; case .year: "近1年"; case .all: "全部" } }
    private func restoreChartState() {
        guard let securityCode else { return }
        let state = model.chartState(for: securityCode)
        if let saved = NextChartInterval(rawValue: state.interval) { interval.wrappedValue = saved }
        var restored = state
        if restored.movingAverageDefaultsApplied != true {
            restored.visibleLayers.formUnion(["ma5", "ma10", "ma20", "ma60", "ma250"])
            restored.movingAverageDefaultsApplied = true
            model.saveChartState(restored, for: securityCode)
        }
        if !restored.visibleLayers.isEmpty { visibleLayers = restored.visibleLayers }
        selectedTime = state.crosshairTime
        // 分时窗口固定，历史缩放值不再套用，避免切到分时后还带着日 K 的放大倍数。
        magnification = min(12, max(1, state.scale))
        let datasetDay = dataset?.orderedSamples.last?.timestamp
        latestIntradaySessionDate = state.latestIntradaySessionDate ?? datasetDay ?? Date()
        intradaySessionDate = state.intradaySessionDate ?? datasetDay ?? latestIntradaySessionDate
        initializedIntradaySession = true
    }
    private func initializeIntradaySessionIfNeeded() {
        guard !initializedIntradaySession, let latest = dataset?.orderedSamples.last?.timestamp else { return }
        let state = securityCode.map { model.chartState(for: $0) } ?? NextChartState()
        latestIntradaySessionDate = state.latestIntradaySessionDate ?? latest
        intradaySessionDate = state.intradaySessionDate ?? latest
        initializedIntradaySession = true
    }
    private func refreshLatestIntradaySession() {
        initializeIntradaySessionIfNeeded()
        guard let newest = dataset?.orderedSamples.last?.timestamp else { return }
        if newest > latestIntradaySessionDate {
            let selectionFollowedLatest = NextIntradayAxis.sameTradingDay(intradaySessionDate, latestIntradaySessionDate)
            latestIntradaySessionDate = newest
            if selectionFollowedLatest { intradaySessionDate = newest }
            saveChartState()
        }
    }
    private func saveChartState() {
        guard let securityCode else { return }
        var state = model.chartState(for: securityCode)
        state.interval = interval.wrappedValue.rawValue
        state.visibleLayers = visibleLayers
        state.crosshairTime = selectedTime
        state.scale = magnification
        state.intradaySessionDate = intradaySessionDate
        state.latestIntradaySessionDate = latestIntradaySessionDate
        state.movingAverageDefaultsApplied = true
        model.saveChartState(state, for: securityCode)
    }
    private func changeZoom(by factor: Double) {
        magnification = min(12, max(1, magnification * factor))
        saveChartState()
    }
    private func moveCrosshair(_ offset: Int) {
        guard !samples.isEmpty else { return }
        let current = selectedSample.flatMap { sample in samples.firstIndex(of: sample) } ?? (offset > 0 ? -1 : samples.count)
        selectedTime = samples[min(samples.count - 1, max(0, current + offset))].timestamp
        saveChartState()
    }
    private func layerButton(_ title: String, key: String, available: Bool) -> some View {
        let active = visibleLayers.contains(key)
        let indicatorColor: Color
        switch key {
        case "ma5", "average": indicatorColor = p.chartGold
        case "ma10": indicatorColor = p.chartBlue
        case "ma60": indicatorColor = p.chartViolet
        case "iopv": indicatorColor = p.chartViolet
        case "ma20", "trades": indicatorColor = p.jade
        case "ma250": indicatorColor = p.chartLongMA
        case "cost": indicatorColor = p.chartCost
        case "price": indicatorColor = p.chartBlue
        default: indicatorColor = p.forest
        }
        return Button { if active { visibleLayers.remove(key) } else { visibleLayers.insert(key) } } label: {
            Text(title).font(.system(size: 9, weight: active ? .semibold : .regular)).foregroundStyle(!available ? p.muted.opacity(0.45) : active ? indicatorColor : p.muted)
                .padding(.horizontal, 8).padding(.vertical, 5).background(active ? p.tint : .clear, in: Capsule())
        }.buttonStyle(.plain).disabled(!available).accessibilityLabel("\(title)指标\(!available ? "不可用" : active ? "已显示" : "已隐藏")")
    }
    private func legend(_ title: String, color: Color) -> some View { HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(.system(size: 9)).foregroundStyle(p.muted) } }
}
