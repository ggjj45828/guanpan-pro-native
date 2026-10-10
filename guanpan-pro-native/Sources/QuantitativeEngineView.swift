import SwiftUI

private struct QuantEngineInstrument: Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var price: Double
    var changePct: Double
}

private struct QuantEngineSignal {
    var score: Int
    var label: String
    var notes: [String]
    var date: String
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
                price: quote?.price ?? holding.current, changePct: quote?.changePct ?? 0)
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
                }

                Section("AI 深度分析") {
                    Label("点开任一标的详情，再点“AI 分析此标的”，可用已配置模型结合该标的行情和日线分析。", systemImage: "sparkles")
                    Text("量化分数由本机即时计算，不需要 API 密钥；AI 分析需要用户主动触发并已配置接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("量化引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $selectedInstrument) { item in
                let holding = store.data.holdings.first(where: { $0.code == item.code && $0.kind == .etf })
                    ?? Holding(code: item.code, name: item.name, quantity: 0, cost: 0, current: item.price, kind: .etf)
                MarketChartView(holding: holding)
            }
        }
    }

    @ViewBuilder private func instrumentRow(_ item: QuantEngineInstrument) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(1)
                    let priceText = item.price > 0 ? item.price.num(3) : "暂无实时报价"
                    let changeText = item.changePct.pct(2)
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
            } else {
                Text("打开详情或点击上方扫描获取日线数据").font(.caption).foregroundStyle(.secondary)
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
        let source = Array(bars.suffix(640))
        guard source.count >= 20, let latest = source.last else { return nil }
        let closes = source.map(\.close)
        func average(_ count: Int) -> Double? {
            guard closes.count >= count else { return nil }
            return closes.suffix(count).reduce(0, +) / Double(count)
        }
        guard let ma5 = average(5), let ma10 = average(10), let ma20 = average(20) else { return nil }
        let ma60 = average(60)
        var raw = 0
        var notes: [String] = []
        if ma5 > ma10 && ma10 > ma20 { raw += 2; notes.append("短期均线多头排列") }
        else if ma5 < ma10 && ma10 < ma20 { raw -= 2; notes.append("短期均线空头排列") }
        if let ma60 {
            if ma20 > ma60 { raw += 1; notes.append("MA20 在 MA60 上方") }
            else { raw -= 1; notes.append("MA20 在 MA60 下方") }
        }
        if latest.close >= ma20 { raw += 1; notes.append("收盘高于 MA20") }
        else { raw -= 1; notes.append("收盘低于 MA20") }
        if source.count >= 6 {
            let momentum = latest.close / source[source.count - 6].close - 1
            if momentum >= 0.02 { raw += 1; notes.append("5 日动量为正") }
            else if momentum <= -0.02 { raw -= 1; notes.append("5 日动量为负") }
        }
        if closes.count >= 15 {
            let delta = (1..<15).map { closes[closes.count - 15 + $0] - closes[closes.count - 15 + $0 - 1] }
            let gain = delta.map { max(0, $0) }.reduce(0, +) / 14
            let loss = delta.map { max(0, -$0) }.reduce(0, +) / 14
            let rsi = loss == 0 ? (gain == 0 ? 50 : 100) : 100 - 100 / (1 + gain / loss)
            if rsi < 30 { raw += 1; notes.append("RSI14 偏低") }
            else if rsi > 70 { raw -= 1; notes.append("RSI14 偏高") }
            else { notes.append("RSI14 中性") }
        }
        if closes.count >= 35 {
            var fast = closes[0], slow = closes[0], dea = 0.0
            var histogram = 0.0
            for (index, close) in closes.enumerated() {
                if index > 0 {
                    fast += (2.0 / 13.0) * (close - fast)
                    slow += (2.0 / 27.0) * (close - slow)
                }
                let dif = fast - slow
                dea = index == 0 ? dif : dea + 0.2 * (dif - dea)
                histogram = 2 * (dif - dea)
            }
            if histogram > 0 { raw += 1; notes.append("MACD 柱值为正") }
            else if histogram < 0 { raw -= 1; notes.append("MACD 柱值为负") }
        }
        if source.count >= 21 {
            let baseline = source.suffix(21).dropLast().map(\.volume).reduce(0, +) / 20
            let change = latest.close / source[source.count - 2].close - 1
            if baseline > 0 && latest.volume >= baseline * 1.5 {
                if change >= 0 { raw += 1; notes.append("放量上涨") }
                else { raw -= 1; notes.append("放量下跌") }
            }
        }
        let score = min(100, max(0, 50 + raw * 6))
        let label = score >= 68 ? "偏强" : score >= 56 ? "偏多" : score <= 32 ? "偏弱" : score <= 44 ? "偏空" : "中性"
        return QuantEngineSignal(score: score, label: label, notes: notes, date: latest.date)
    }
}
