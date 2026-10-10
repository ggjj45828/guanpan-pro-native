import SwiftUI

/// 可选标的：持仓 + 自选，去重后按名称排序
struct ValuationCandidate: Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

/// 位置体检的结论档位
struct ValuationVerdict {
    var title: String
    var detail: String
    /// 红=偏高（贵）/ 绿=偏低（便宜）/ 灰=中性。注意这是「位置」不是「涨跌预测」
    var tone: Tone
    enum Tone { case expensive, cheap, neutral }
    var color: Color {
        switch tone {
        case .expensive: return PnLColor.up      // 位置高 → 用涨色提示追高风险
        case .cheap: return PnLColor.down        // 位置低 → 用跌色
        case .neutral: return Color.secondary
        }
    }

    /// 用 switch 而不是 `tone == .x`，省掉对 Equatable 合成规则的依赖
    var iconName: String {
        switch tone {
        case .expensive: return "arrow.up.circle"
        case .cheap: return "arrow.down.circle"
        case .neutral: return "equal.circle"
        }
    }
}

/// 单只标的的位置体检（俗称「值不值得买」）。
///
/// 重要边界：本机没有 PE / PB / 财报数据，所以**不做基本面估值**。
/// 这里回答的是「当前价格在它自己最近 N 日的历史区间里处于什么位置」，
/// 属于技术面描述，不是价值判断，也不构成投资建议。
struct ValuationView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var bars: [DailyBar] = []
    @State private var isLoading = false
    @State private var note: String?
    @State private var window: Int = 250

    private var candidates: [ValuationCandidate] {
        var seen: Set<String> = []
        var out: [ValuationCandidate] = []
        for holding in store.data.holdings where holding.kind != .fund {
            guard seen.insert(holding.code).inserted else { continue }
            out.append(.init(code: holding.code, name: holding.name))
        }
        for quote in store.data.quotes {
            guard seen.insert(quote.code).inserted else { continue }
            out.append(.init(code: quote.code, name: quote.name))
        }
        return out.sorted { $0.name < $1.name }
    }

    private var currentName: String {
        candidates.first { $0.code == code }?.name ?? code
    }
    private var holding: Holding? {
        store.data.holdings.first { $0.code == code }
    }
    private var quote: Quote? {
        store.data.quotes.first { $0.code == code }
    }
    private var latest: DailyBar? { bars.last }
    private var currentPrice: Double {
        let manual = store.data.manualQuoteOverrides[code]
        return manual?.price ?? quote?.price ?? latest?.close ?? holding?.current ?? 0
    }

    private var windowBars: [DailyBar] { Array(bars.suffix(window)) }
    private var signal: MarketSignal? { MarketSignalCalculator.evaluate(bars) }
    private var levels: SupportResistance? { SupportResistanceCalculator.evaluate(bars) }

    /// 现价在最近 N 日收盘区间里的分位（0=区间最低，100=区间最高）
    private var percentile: Double? {
        let prices = windowBars.map(\.close)
        guard let low = prices.min(), let high = prices.max(), high > low else { return nil }
        return (currentPrice - low) / (high - low) * 100
    }
    private var rangeLow: Double? { windowBars.map(\.close).min() }
    private var rangeHigh: Double? { windowBars.map(\.close).max() }

    /// 年化波动率（%）：日收益标准差 × √244
    private var annualVolatility: Double? {
        let closes = windowBars.map(\.close)
        guard closes.count >= 30 else { return nil }
        var returns: [Double] = []
        for i in 1..<closes.count where closes[i - 1] > 0 {
            returns.append(closes[i] / closes[i - 1] - 1)
        }
        guard returns.count >= 20 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
        return sqrt(variance) * sqrt(244) * 100
    }
    /// 区间最大回撤（%）
    private var maxDrawdown: Double? {
        guard !windowBars.isEmpty else { return nil }
        var peak = windowBars[0].close
        var worst = 0.0
        for bar in windowBars {
            peak = max(peak, bar.close)
            if peak > 0 { worst = min(worst, bar.close / peak - 1) }
        }
        return worst * 100
    }

    /// 综合评分：正数=位置偏低，负数=位置偏高
    private var score: Int {
        var raw = 0
        if let p = percentile {
            if p < 20 { raw += 2 } else if p < 35 { raw += 1 }
            else if p > 80 { raw -= 2 } else if p > 65 { raw -= 1 }
        }
        if let rsi = signal?.rsi {
            if rsi < 30 { raw += 1 } else if rsi > 70 { raw -= 1 }
        }
        if let above = signal?.aboveMA20 { raw += above ? 1 : -1 }
        if let ma20 = signal?.ma20, let ma60 = signal?.ma60 { raw += ma20 > ma60 ? 1 : -1 }
        if let room = levels?.supportRoomPercent, abs(room) <= 3 { raw += 1 }
        if let room = levels?.resistanceRoomPercent, room <= 2 { raw -= 1 }
        return raw
    }

    private var verdict: ValuationVerdict {
        let s = score
        guard bars.count >= 60 else {
            return .init(title: "数据不足", detail: "本机只有 \(bars.count) 根日线，至少需要 60 根才做位置判断。", tone: .neutral)
        }
        switch s {
        case 4...: return .init(title: "位置偏低", detail: "现价处于近 \(window) 日区间下沿附近，多项指标同时偏冷。历史上这种位置继续下跌的空间通常有限，但也可能意味着趋势已经转弱。", tone: .cheap)
        case 2...3: return .init(title: "相对偏低", detail: "多数指标指向区间偏下侧，但并非极端位置。", tone: .cheap)
        case -1 ... 1: return .init(title: "中性区间", detail: "指标相互抵消，现价处在近 \(window) 日区间的中间地带，没有明显的位置优势或劣势。", tone: .neutral)
        case -3 ... -2: return .init(title: "相对偏高", detail: "多数指标指向区间偏上侧，追高的性价比在下降。", tone: .expensive)
        default: return .init(title: "位置偏高", detail: "现价处于近 \(window) 日区间上沿附近，多项指标同时偏热。追高需要更严格的止损，因为回撤到区间中部的空间较大。", tone: .expensive)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("选择标的") { pickerBody }
                Section("位置结论") { verdictBody }
                Section("区间位置") { positionBody }
                Section("技术指标") { indicatorBody }
                Section("支撑与压力") { levelBody }
                Section("波动与回撤") { riskBody }
                Section("持仓视角") { holdingBody }
                Section { disclaimerBody }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("位置体检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isLoading)
                        .accessibilityLabel("重新获取日线")
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await loadInitial() }
        }
    }

    // MARK: 分区

    @ViewBuilder private var pickerBody: some View {
        if candidates.isEmpty {
            Text("还没有持仓或自选，先去自选里加一只标的。").foregroundStyle(.secondary)
        } else {
            Picker("标的", selection: $code) {
                ForEach(candidates) { item in
                    Text("\(item.name) · \(item.code)").tag(item.code)
                }
            }
            .onChange(of: code) { _, _ in
                Haptics.selection()
                Task { await reload(force: false) }
            }
            Picker("回看区间", selection: $window) {
                Text("近 120 日").tag(120)
                Text("近 250 日").tag(250)
                Text("近 640 日").tag(640)
            }.pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var verdictBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: verdict.iconName)
                    .foregroundStyle(verdict.color)
                Text(verdict.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(verdict.color)
                Spacer()
                Text("评分 \(score > 0 ? "+" : "")\(score)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verdict.detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .combineAccessibility()
        if isLoading {
            HStack { ProgressView(); Text("正在获取日线…").font(.footnote).foregroundStyle(.secondary) }
        }
        if let note {
            Text(note).font(.footnote).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var positionBody: some View {
        if let percentile, let low = rangeLow, let high = rangeHigh {
            LabeledContent("现价", value: (currentPrice).num(3))
            LabeledContent("近 \(window) 日区间", value: "\((low).num(3)) ~ \((high).num(3))")
            LabeledContent("区间分位", value: (percentile / 100).pct(1))
                .accessibilityLabel("现价处于近 \(window) 日区间的 \((percentile / 100).pct(1)) 分位")
            percentileBar(percentile)
        } else {
            Text("没有足够的日线数据计算区间位置。").foregroundStyle(.secondary)
        }
    }

    private func percentileBar(_ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let clamped = min(max(value, 0), 100)
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 8)
                    Capsule()
                        // 分位越高 → 位置越偏高 → 用涨色（红）提示追高风险
                        .fill(PnLColor.of(value - 50))
                        .frame(width: width * CGFloat(clamped / 100), height: 8)
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 12, height: 12)
                        .offset(x: width * CGFloat(clamped / 100) - 6)
                }
            }
            .frame(height: 12)
            HStack {
                Text("低").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("高").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityLabel("区间位置条，当前 \(value.num(1))%")
    }

    @ViewBuilder private var indicatorBody: some View {
        if let signal {
            LabeledContent("趋势", value: signal.trendText)
            if let ma20 = signal.ma20 {
                LabeledContent("距 MA20", value: deviationText(currentPrice, ma20))
            }
            if let ma60 = signal.ma60 {
                LabeledContent("距 MA60", value: deviationText(currentPrice, ma60))
            }
            if let rsi = signal.rsi {
                LabeledContent("RSI14", value: (rsi).num(1))
            }
            if let ratio = signal.volumeRatio {
                LabeledContent("量比（对 20 日均量）", value: (ratio).num(2))
            }
            SignalTagRow(tags: signal.tags)
        } else {
            Text("日线不足 20 根，无法计算技术指标。").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var levelBody: some View {
        if let levels {
            if let support = levels.nearestSupport, let room = levels.supportRoomPercent {
                LabeledContent("最近支撑", value: "\((support).num(3))（\(room.num(1))%）")
                    .accessibilityLabel("最近支撑 \((support).num(3))，距现价 \(room.num(1))%")
            } else {
                LabeledContent("最近支撑", value: "区间内无更低摆动低点")
            }
            if let resistance = levels.nearestResistance, let room = levels.resistanceRoomPercent {
                LabeledContent("最近压力", value: "\((resistance).num(3))（+\(room.num(1))%）")
                    .accessibilityLabel("最近压力 \((resistance).num(3))，距现价 \(room.num(1))%")
            } else {
                LabeledContent("最近压力", value: "已在区间高点上方")
            }
        } else {
            Text("日线不足以识别支撑压力。").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var riskBody: some View {
        if let vol = annualVolatility {
            LabeledContent("年化波动率", value: (vol).num(1) + "%")
        }
        if let dd = maxDrawdown {
            LabeledContent("近 \(window) 日最大回撤", value: (dd).num(1) + "%")
                .pnlAccessibility(percent: dd / 100)
        }
        if annualVolatility == nil && maxDrawdown == nil {
            Text("日线不足 30 根，无法估算波动率与回撤。").foregroundStyle(.secondary)
        } else {
            Text("波动率与回撤只描述过去的价格波动幅度，不代表未来风险，也不用于预测。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var holdingBody: some View {
        if let holding {
            let cost = store.displayedCost(for: holding)
            LabeledContent("持仓份额", value: (holding.quantity).num(4))
            LabeledContent("成本 / 现价", value: "\((cost).num(3)) / \((currentPrice).num(3))")
            if cost > 0 {
                let deviation = (currentPrice / cost - 1) * 100
                LabeledContent("相对成本", value: "\(deviation.directionMark()) \(deviation.num(2))%")
                    .pnlAccessibility(percent: deviation / 100)
            }
            let share = store.totalAsset > 0 ? holding.marketValue / store.totalAsset * 100 : 0
            LabeledContent("占总资产", value: (share / 100).pct(1))
            Text("成本偏离只说明浮盈浮亏，不代表该不该加仓；加仓还要看仓位上限和原计划。")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("该标的当前没有持仓，只做行情位置体检。").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var disclaimerBody: some View {
        Text("这项体检只用本机已缓存的日线、行情和持仓成本，回答的是「现价在自己历史区间里的位置」。它**不是** PE / PB 基本面估值，不包含财报、行业和宏观信息，也不预测涨跌、不构成投资建议。日线来自腾讯前复权数据，缓存不足时会向腾讯直连拉取，失败才走 NAS 代理。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    // MARK: 数据

    // store 是 @MainActor，这两个方法要改 @State，所以显式标在主线程上，
    // 避免 Swift 并发检查把「跨 actor 改 @State」判成错误。
    @MainActor private func loadInitial() async {
        if code.isEmpty { code = candidates.first?.code ?? "" }
        await reload(force: false)
    }

    @MainActor private func reload(force: Bool) async {
        guard !code.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        if !force, let cached = store.dailyBars[code], !cached.isEmpty {
            bars = cached
            note = nil
            return
        }
        do {
            bars = try await store.fetchDailyBars(code: code, force: force)
            note = nil
            Haptics.success()
        } catch {
            if let cached = store.dailyBars[code], !cached.isEmpty {
                bars = cached
                note = "日线拉取失败，已使用本机缓存（\(cached.count) 根）。"
            } else {
                note = "无法获取 \(code) 的日线：\(error.localizedDescription)"
            }
            Haptics.error()
        }
    }

    private func deviationText(_ current: Double, _ ma: Double) -> String {
        guard ma > 0, current > 0 else { return "--" }
        let value = (current / ma - 1) * 100
        return "\(value.directionMark()) \(value.num(2))%"
    }
}
