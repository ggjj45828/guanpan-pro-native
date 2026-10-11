import SwiftUI

private struct QuantEngineInstrument: Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var price: Double
    var changePct: Double?
}

private struct QuantEngineSignal {
    var score: Int
    var label: String
    var notes: [String]
    var date: String
    var close: Double
    var ma20: Double?
}

struct QuantitativeEngineView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = false
    @State private var progress = 0.0
    @State private var scanMessage = ""
    @State private var selectedInstrument: QuantEngineInstrument?

    private var instruments: [QuantEngineInstrument] {
        var byCode: [String: QuantEngineInstrument] = [:]
        for quote in store.data.quotes {
            byCode[quote.code] = QuantEngineInstrument(code: quote.code, name: quote.name.isEmpty ? quote.code : quote.name,
                                                        price: quote.price, changePct: quote.changePct)
        }
        for holding in store.data.holdings where holding.kind == .etf && holding.quantity > 0 {
            let quote = store.data.quotes.first(where: { $0.code == holding.code })
            byCode[holding.code] = QuantEngineInstrument(code: holding.code, name: holding.name,
                price: quote?.price ?? holding.current, changePct: quote?.changePct)
        }
        return byCode.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var rankedInstruments: [QuantEngineInstrument] {
        instruments.sorted {
            let first = signal(for: $0)?.score ?? -1
            let second = signal(for: $1)?.score ?? -1
            return first == second ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : first > second
        }
    }

    private func signal(for item: QuantEngineInstrument) -> QuantEngineSignal? {
        Self.evaluate(store.dailyBars[item.code] ?? [])
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    /// 偏强（score ≥ 56）/ 偏弱（score ≤ 44）标的数，与 `localMarketReview` 同口径。
    /// 只用于给「技术复盘」卡取色，不影响任何计算结论。
    private var signalBreadth: (bullish: Int, bearish: Int) {
        var bullish = 0
        var bearish = 0
        for item in instruments {
            guard let s = signal(for: item) else { continue }
            if s.score >= 56 { bullish += 1 } else if s.score <= 44 { bearish += 1 }
        }
        return (bullish, bearish)
    }

    /// 多空谁占优，映射成卡片色；势均力敌时回到中性卡面。
    private var reviewTone: Color? {
        let breadth = signalBreadth
        if breadth.bullish > breadth.bearish { return PnLColor.up }
        if breadth.bearish > breadth.bullish { return PnLColor.down }
        return nil
    }

    private var localMarketReview: String {
        let available = instruments.compactMap { item -> (QuantEngineInstrument, QuantEngineSignal)? in
            guard let signal = signal(for: item) else { return nil }
            return (item, signal)
        }
        guard !available.isEmpty else {
            return "当前没有可用日线。刷新自选/持仓的历史行情后，本机引擎会给出市场概览、强弱标的和操作观察条件。"
        }
        let sorted = available.sorted { $0.1.score > $1.1.score }
        let bullish = available.filter { $0.1.score >= 56 }.count
        let bearish = available.filter { $0.1.score <= 44 }.count
        let changes = available.compactMap { $0.0.changePct }
        let mood: String
        if changes.isEmpty {
            mood = "暂时没有可用的实时涨跌数据，以下只反映日线结构。"
        } else {
            let average = changes.reduce(0, +) / Double(changes.count) * 100
            mood = "有报价的标的平均涨跌 \(average.pct(2))。"
        }
        let climate = bullish > bearish ? "日线偏强标的较多" : bearish > bullish ? "日线偏弱标的较多" : "日线多空信号接近"
        let strongest = sorted[0]
        let weakest = sorted[sorted.count - 1]
        var result = "市场概览：\(mood)\(climate)（偏强 \(bullish) 只、偏弱 \(bearish) 只、中性 \(available.count - bullish - bearish) 只）。"
        result += "\n\n相对最强：\(strongest.0.name)(\(strongest.0.code))，\(strongest.1.label)。\(strongest.1.notes.prefix(3).joined(separator: "；"))。\n\n相对最弱：\(weakest.0.name)(\(weakest.0.code))，\(weakest.1.label)。\(weakest.1.notes.prefix(3).joined(separator: "；"))。"
        if bullish > 0 && bearish > 0 {
            result += "\n\n操作观察：当前是结构分化，别只看市场平均涨跌。已有持仓按各自 MA20 和仓位上限复核；未持有标的等日线信号确认后再分批，不因排名单独追涨。"
        } else if bullish > 0 {
            result += "\n\n操作观察：日线偏强不等于适合买入。已有持仓检查是否超出仓位上限；未持有的等回踩企稳或突破后确认，不按评分追高。"
        } else {
            result += "\n\n操作观察：先控制新增风险，等待弱势标的收复关键均线或止跌结构确认，再复核是否调整。"
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await scan() }
                    } label: {
                        Label(isScanning ? "正在更新日线并扫描…" : "刷新行情并扫描全部自选/持仓",
                              systemImage: isScanning ? "hourglass" : "arrow.clockwise")
                    }.disabled(isScanning || instruments.isEmpty)
                    if isScanning { ProgressView(value: progress) }
                    if !scanMessage.isEmpty { Text(scanMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("本地规则因子：均线排列、收盘位置、5 日动量、RSI、MACD 和量能变化。分数用于排序和复核，不是收益概率或自动买卖指令。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("量化扫描") }
                    .plainCard(isLight: isLight)

                Section("技术复盘 · 本机量化引擎") {
                    Text(localMarketReview)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("由日线信号和可用行情在本机生成，无需 API Key。评分是规则信号，不是收益概率；数据缺失时会明确提示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(reviewTone, isLight: isLight)

                if instruments.isEmpty {
                    ContentUnavailableView("暂无扫描标的", systemImage: "chart.xyaxis.line",
                                           description: Text("先在自选或 ETF 持仓中添加标的。"))
                } else {
                    Section("信号排序 · \(instruments.count) 个标的") {
                        ForEach(rankedInstruments) { item in
                            Button { selectedInstrument = item } label: {
                                instrumentRow(item)
                            }.buttonStyle(.plain)
                        }
                    }
                    .plainCard(isLight: isLight)
                }

                Section("AI 深度分析") {
                    Label("点开任一标的详情，再点“AI 分析此标的”，可用已配置模型结合该标的行情和日线分析。", systemImage: "sparkles")
                    Text("量化分数由本机即时计算，不需要 API 密钥；AI 分析需要用户主动触发并已配置接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(CardTone.accent, isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("量化引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $selectedInstrument) { item in
                let holding = store.data.holdings.first(where: { $0.code == item.code && $0.kind == .etf })
                    ?? Holding(code: item.code, name: item.name, quantity: 0, cost: 0, current: item.price, kind: .etf)
                MarketChartView(holding: holding)
                    .themedSheetBackground()
            }
        }
    }

    @ViewBuilder private func instrumentRow(_ item: QuantEngineInstrument) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(1)
                    let priceText = item.price > 0 ? item.price.num(3) : "暂无实时报价"
                    let changeText = item.changePct.map { ($0 * 100).pct(2) } ?? "涨跌 --"
                    Text("\(item.code) · \(priceText) · \(changeText)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if let signal = signal(for: item) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(signal.score)").font(.title2.bold()).monospacedDigit()
                            .foregroundStyle(signal.score >= 57 ? .red : signal.score <= 43 ? .green : .primary)
                        Text(signal.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("缺日线").font(.caption).foregroundStyle(.orange)
                }
            }
            if let signal = signal(for: item) {
                Text("\(signal.date) · \(signal.notes.prefix(3).joined(separator: "；"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(actionPlan(item, signal: signal))
                    .font(.caption.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("打开详情或点击上方扫描获取日线数据").font(.caption).foregroundStyle(.secondary)
            }
            // 与自选面板一致的技术标签
            if let raw = MarketSignalCalculator.evaluate(store.dailyBars[item.code] ?? []) {
                SignalTagRow(tags: raw.tags)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @MainActor private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        scanMessage = ""
        defer { isScanning = false }
        store.refreshQuotes()
        var successes = 0
        var failures = 0
        let items = instruments
        for (index, item) in items.enumerated() {
            do {
                _ = try await store.fetchDailyBars(code: item.code, count: 640, force: true)
                successes += 1
            } catch { failures += 1 }
            progress = Double(index + 1) / Double(max(1, items.count))
        }
        scanMessage = "日线已更新 \(successes) 个 · 获取失败 \(failures) 个。失败标的仍可使用本机缓存。"
    }

    private static func evaluate(_ bars: [DailyBar]) -> QuantEngineSignal? {
        // 统一走 MarketSignalCalculator，保证自选面板与量化引擎口径完全一致
        guard let signal = MarketSignalCalculator.evaluate(bars) else { return nil }
        return QuantEngineSignal(score: signal.score, label: signal.label, notes: signal.notes,
                                  date: signal.date, close: signal.close, ma20: signal.ma20)
    }

    private func actionPlan(_ item: QuantEngineInstrument, signal: QuantEngineSignal) -> String {
        let held = store.data.holdings.first { $0.code == item.code && $0.quantity > 0 }
        let prefix = held == nil ? "未持有：" : "已有持仓："
        let price = item.price > 0 ? item.price : signal.close
        let aboveMA20 = signal.ma20.map { price >= $0 } ?? (signal.close >= (signal.ma20 ?? signal.close))
        if signal.score >= 68 {
            return prefix + (aboveMA20
                ? "日线偏强，但不要按评分追高；等回踩 MA20 附近企稳后再按计划分批，收盘重新跌回 MA20 下方时复核。"
                : "评分偏强但价格仍在 MA20 下方，先等收盘站回 MA20 并确认，不因分数单独加仓。")
        }
        if signal.score >= 56 {
            return prefix + "略偏多但确认不足；先观察 MA5/MA10 是否转强并收盘站稳 MA20，再决定是否分批，暂不追涨。"
        }
        if signal.score > 44 {
            return prefix + "日线信号中性；先观望，不因为短线波动加仓，等收盘方向和 MA20 位置更明确后再调整。"
        }
        if signal.score > 32 {
            return prefix + "日线偏弱；暂停新增仓位，若收盘持续低于 MA20，按你设定的仓位上限和退出计划复核。"
        }
        return prefix + "日线偏弱信号较多；不建议仅凭低分抄底，先等重新站稳 MA20 或形成明确止跌结构，再评估风险。"
    }
}
