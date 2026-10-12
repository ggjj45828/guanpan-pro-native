import SwiftUI

/// 用户先表达“想买/卖多少份”，本机规则随行情刷新持续复核；
/// 大模型只负责按需解释，不自动下单，也不把盘中情景写成确定预测。
struct IntradayCompanionView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding

    @State private var side: IntradayCompanionIntent.Side = .buy
    @State private var quantity = ""
    @State private var message = ""
    @State private var aiResult = ""
    @State private var aiBusy = false

    private var amount: Double { (Double(quantity) ?? 0) * currentPrice }
    private var currentPrice: Double {
        store.data.quotes.first(where: { $0.code == holding.code })?.price ?? holding.current
    }
    private var decision: IntradayCompanionDecision {
        store.intradayCompanionDecision(code: holding.code, side: side,
                                        quantity: Double(quantity) ?? 0, price: currentPrice)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("你的交易意图") {
                    Picker("方向", selection: $side) {
                        Text("想买入").tag(IntradayCompanionIntent.Side.buy)
                        Text("想卖出").tag(IntradayCompanionIntent.Side.sell)
                    }
                    .pickerStyle(.segmented)
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    LabeledContent("参考现价", value: currentPrice.num(3))
                    LabeledContent("计划金额", value: amount.cny())
                    Button("保存并开启盘中提醒") { saveIntent() }
                    if store.data.intradayCompanionIntents.contains(where: { $0.code == holding.code }) {
                        Button("关闭这只标的的盘中陪伴", role: .destructive) {
                            store.removeIntradayCompanionIntent(code: holding.code)
                            message = "已关闭；不会再随行情变化发送提醒。"
                        }
                    }
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }

                Section("当前判断") {
                    HStack {
                        Text(decision.level.rawValue).font(.headline)
                        Spacer()
                        Text("随行情刷新").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(decisionColor)
                    ForEach(decision.reasons, id: \.self) { Text("• \($0)").font(.subheadline) }
                    Text("“可执行”只表示当前计划没有触发仓位、现金和技术条件的明显冲突，不等于保证买对或卖对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("AI 情景陪伴") {
                    Button {
                        Task { await explainWithAI() }
                    } label: {
                        if aiBusy { ProgressView("正在结合盘中数据分析…") }
                        else { Label("让 DeepSeek 解释当前计划", systemImage: "sparkles") }
                    }
                    .disabled(aiBusy || !AIAnalysisService.hasSavedAPIKey || decision.level == .invalid)
                    if !AIAnalysisService.hasSavedAPIKey {
                        Text("先在 AI 账户分析里保存 DeepSeek 密钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !aiResult.isEmpty {
                        AIFormattedResultView(text: aiResult, accent: store.effectiveAccentColor)
                    }
                    Text("模型只能给“回暖 / 继续走弱”的条件化情景和失效信号，不能可靠预言下午方向；App 不会自动下单。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("盘中 AI 陪伴")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if let saved = store.data.intradayCompanionIntents.first(where: { $0.code == holding.code }) {
                    side = saved.side
                    quantity = saved.quantity.num(0)
                } else if holding.quantity > 0 {
                    quantity = min(holding.quantity, 100).num(0)
                }
            }
        }
    }

    private var decisionColor: Color {
        switch decision.level {
        case .ready: return .green
        case .wait: return .orange
        case .avoid, .invalid: return .red
        }
    }

    private func saveIntent() {
        do {
            try store.saveIntradayCompanionIntent(code: holding.code, name: holding.name,
                                                   side: side, quantity: Double(quantity) ?? 0)
            message = "已开启。前台行情刷新时会重新判断；状态变化会发本地通知。"
            Task { _ = try? await NativeNotifications.requestPermission() }
        } catch { message = "份额无效，请重新填写。" }
    }

    @MainActor private func explainWithAI() async {
        aiBusy = true
        defer { aiBusy = false }
        let today = shanghaiDay(.now)
        let points = store.intradayBars.filter { $0.code == holding.code && $0.day == today }
            .sorted { $0.timestamp < $1.timestamp }.suffix(120)
        let minuteText = points.map { "\($0.timestamp.formatted(date: .omitted, time: .shortened)) \($0.price.num(4))" }
            .joined(separator: "\n")
        let prompt = """
        用户正在考虑对 \(holding.name)（\(holding.code)）\(side == .buy ? "买入" : "卖出") \(quantity) 份，参考价 \(currentPrice.num(4))，计划金额 \(amount.cny())。
        本机当前判断：\(decision.level.rawValue)。依据：\(decision.summary)。
        当前总资产 \(store.totalAsset.cny())，现金 \(store.data.cash.cny())，该标的现持有 \(holding.quantity.num(2)) 份、成本 \(holding.cost.num(4))。
        今日本机分时样本：
        \(minuteText.isEmpty ? "暂无" : minuteText)

        请只输出四小段：当前结论、现在要等的确认信号、下午回暖情景、继续走弱情景。每段 1–3 句。
        不得声称能预测下午涨跌；只能写条件与失效信号。没有量能、新闻、盘口或实时数据就明确说没有。不要给无条件买卖指令，不自动交易。
        """
        do {
            aiResult = try await AIAnalysisService.chat(config: store.data.aiAnalysisConfig, prompt: prompt)
        } catch { aiResult = "分析失败：\(error.localizedDescription)" }
    }
}
