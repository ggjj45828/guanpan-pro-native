import SwiftUI
import Foundation

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
                    LabeledContent("意图金额（参考）", value: amount.cny())
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
                        Text(decision.title(for: side)).font(.headline)
                        Spacer()
                        Text("随行情刷新").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(decisionColor)
                    ForEach(decision.reasons, id: \.self) { Text("• \($0)").font(.subheadline) }
                    Text("这里记录的是交易意图，不会占用或校验你的参考现金，也不会自动下单。系统按意图份额和现价估算金额，并结合画像、趋势、持仓及仓位上限给出分析；仓位数据只作风险提示。卖出份额超过账面持仓时会提示核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("AI 情景解读（点按分析）") {
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
                    Text("本机规则会随行情刷新复核；大模型只在你点按时分析，提供“回暖 / 继续走弱”的条件情景和失效信号，不能可靠预言下午方向；App 不会自动下单。")
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
        let points = store.intradayBars(code: holding.code, day: today).suffix(120)
        let minuteText = points.map { "\($0.timestamp.formatted(date: .omitted, time: .shortened)) \($0.price.num(4))" }
            .joined(separator: "\n")
        let profile = store.data.investmentProfile
        let behavior = BehaviorProfile.build(data: store.data, dailyBars: store.dailyBars)
        let preference = profile.preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let includesDipPreference = preference.localizedCaseInsensitiveContains("抄底")
            || preference.localizedCaseInsensitiveContains("回调")
        let effectivePreference = preference.isEmpty ? "喜欢抄底、偏好回调后分批布局"
            : (includesDipPreference ? preference : "\(preference)；同时喜欢抄底、偏好回调后分批布局")
        let profileText = "交易风格：\(profile.style)，风险偏好：\(profile.risk)，持有周期：\(profile.horizon)，单标的仓位上限：\(profile.maxPositionPercent.num(1))%；用户偏好：\(effectivePreference)；投资目标：\(profile.goal.isEmpty ? "未填写" : profile.goal)；回避项：\(profile.avoid.isEmpty ? "未填写" : profile.avoid)。\n本机交易行为统计：\(behavior.promptText)"
        let dividendCtx = store.dividendContext(forCode: holding.code)
        let dividendText: String
        let dividendInstruction: String
        if let dc = dividendCtx, dc.yieldPercent > 0 {
            dividendText = "该标的股息率约 \(dc.yieldPercent.pct(2))%（年分红约 \(dc.annualPerShare.num(4)) 元/份），\(dc.isIncomePlay ? "属于红利/攒股息型标的" : "有一定分红")）。"
            dividendInstruction = dc.isIncomePlay
                ? "该标的是红利/攒股息型：请带入「下跌抬高股息率、上涨压低股息率」的视角——价格回调对攒股息是更好买点，不应单纯视为利空；若用户意图卖出，提醒卖出会减少未来股息收入，除非分红前景恶化或需再平衡，否则以收息为目的应优先持有。"
                : "该标的虽有一定分红，但未达红利型标准（股息率<3%）；可正常按价差与趋势分析，不必特别强调股息视角。"
        } else {
            dividendText = "该标的暂无可用的股息率数据（非分红型或不适合用股息率评价）。"
            dividendInstruction = "该标的无可用股息率数据，按普通价差/趋势标的分析即可。"
        }
        let prompt = """
        用户正在考虑对 \(holding.name)（\(holding.code)）\(side == .buy ? "买入" : "卖出") \(quantity) 份，参考价 \(currentPrice.num(4))，意图金额约 \(amount.cny())。这只是情景分析，不是下单；不得用账户现金余额否定或拦截该意图。
        用户投资画像与行为：\(profileText)
        \(dividendText)
        \(dividendInstruction)
        本机当前判断：\(decision.title(for: side))。依据：\(decision.summary)。
        当前总资产 \(store.totalAsset.cny())，该标的现持有 \(holding.quantity.num(2)) 份、成本 \(holding.cost.num(4))。不要把交易意图金额与参考现金作可执行性校验；仓位变化只作为风险背景。
        今日本机分时样本：
        \(minuteText.isEmpty ? "暂无" : minuteText)

        请结合画像给出意见：用户偏好抄底，应把回调视作观察机会，但不能把“跌得多”直接等同买点；需要区分低位、止跌/企稳、趋势风险和仓位限制。卖出时，份额足够只代表账面可卖，必须说明趋势/仓位/止盈计划等具体依据；若没有足够依据，应明确说“暂不建议卖出/继续观察”，不能迎合用户的卖出意图。不要臆造用户画像、技术数据或止盈目标。
        请只输出四小段：当前结论、画像如何影响判断、现在要等的确认/失效信号、回暖与继续走弱两种条件情景。每段 1–3 句。
        不得声称能预测下午涨跌；只能写条件与失效信号。没有量能、新闻、盘口或实时数据就明确说没有。不要给无条件买卖指令，不自动交易。
        """
        do {
            aiResult = try await AIAnalysisService.chat(config: store.data.aiAnalysisConfig, prompt: prompt)
        } catch { aiResult = "分析失败：\(error.localizedDescription)" }
    }

    private func shanghaiDay(_ date: Date) -> String {
        MarketCalendar.isoDay(date)
    }
}
