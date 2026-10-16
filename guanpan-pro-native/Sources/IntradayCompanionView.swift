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
    /// 今天在这只上已经成交过什么（来自用户自己的流水）。
    private var todayTrades: IntradayTodayTrades { store.intradayTodayTrades(code: holding.code) }
    /// 这笔卖出里「平掉今日买入」那一部分的收支与保本价。今天没买过就是 nil。
    private var tSettlement: IntradayTSettlement? {
        store.intradayTSettlement(code: holding.code, quantity: Double(quantity) ?? 0,
                                  price: currentPrice, trades: todayTrades)
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

                // 今天已经动过这只时，把「做 T」这笔账单独摊开算给你看 ——
                // 它和「减仓」用的不是同一个成本，也不是同一套判据。
                if todayTrades.hasAny {
                    Section("今日成交与做 T") {
                        if let summary = todayTrades.summary() {
                            Text(summary).font(.subheadline)
                        }
                        if side == .sell, let s = tSettlement {
                            LabeledContent("做 T 成本（今日买入含费）", value: s.costPerShare.num(4))
                            LabeledContent("卖出保本价", value: s.breakEvenPrice.num(4))
                            HStack {
                                Text("这笔 T 的净收支").font(.subheadline)
                                Spacer()
                                Text(s.profit.cny())
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(s.isProfit ? PnLColor.up : PnLColor.down)
                            }
                            if s.excessQuantity > 0.000_001 {
                                Text("其中 \(s.quantity.num(0)) 份算平掉今天买的那笔（做 T），另外 \(s.excessQuantity.num(0)) 份属于减仓 —— 减仓仍按趋势与仓位看。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Text("净收支已扣掉今日买入费与预估的卖出费（\(store.companionEstimatedSellFee(trades: todayTrades).num(2)) 元），实际费用以你的流水为准。做 T 只赚当天价差，不改变长期持仓成本。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("前提是当天买入的份额当天可卖：跨境 / 商品 / 债券 ETF 支持 T+0，境内股票 ETF 与股票多为 T+1 —— 以你券商显示的可卖数量为准。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
        let trades = todayTrades
        let todayTradesText = trades.summary().map { "今日该标的的成交（来自用户自己的流水）：\($0)。" }
            ?? "今日该标的没有任何已记录成交。"
        let tText: String
        if side == .sell, let s = tSettlement {
            let excess = s.excessQuantity > 0.000_001
                ? "另有 \(s.excessQuantity.num(0)) 份超出今日买入，那部分是减仓、不是做 T。"
                : ""
            tText = """
            这笔卖出里有 \(s.quantity.num(0)) 份是在平掉今天买入的部分（做 T / 当日回转）：今日买入含费成本 \(s.costPerShare.num(4))，卖出保本价 \(s.breakEvenPrice.num(4))，按现价卖出扣掉双边费用后约 \(s.profit.cny())。
            \(excess)
            做 T 的判据是**价差**，不是趋势：只要卖出价盖住了今日买入成本与卖出费用，这笔 T 就是成立的，不要用「没有减仓信号 / 还在 MA20 上方」去否定它；反过来若现价低于保本价，就直接说这笔 T 会亏，并给出保本价这个要等的价位。同时提醒做 T 只赚当天价差、不改变长期持仓成本，频繁做 T 会被手续费与滑点吃掉（价差至少要盖住两笔费用）。
            """
        } else {
            tText = "今日没有该标的的买入记录，本次卖出按普通减仓口径评估（趋势 / 仓位 / 止盈计划）。"
        }
        let prompt = """
        用户正在考虑对 \(holding.name)（\(holding.code)）\(side == .buy ? "买入" : "卖出") \(quantity) 份，参考价 \(currentPrice.num(4))，意图金额约 \(amount.cny())。这只是情景分析，不是下单；不得用账户现金余额否定或拦截该意图。
        用户投资画像与行为：\(profileText)
        \(dividendText)
        \(dividendInstruction)
        \(todayTradesText)
        \(tText)
        本机当前判断：\(decision.title(for: side))。依据：\(decision.summary)。
        当前总资产 \(store.totalAsset.cny())，该标的现持有 \(holding.quantity.num(2)) 份、成本 \(holding.cost.num(4))。不要把交易意图金额与参考现金作可执行性校验；仓位变化只作为风险背景。
        今日本机分时样本：
        \(minuteText.isEmpty ? "暂无" : minuteText)

        请结合画像给出意见：用户偏好抄底，应把回调视作观察机会，但不能把“跌得多”直接等同买点；需要区分低位、止跌/企稳、趋势风险和仓位限制。卖出时，份额足够只代表账面可卖，必须说明趋势/仓位/止盈计划等具体依据；若没有足够依据，应明确说“暂不建议卖出/继续观察”，不能迎合用户的卖出意图。**但若上面给了做 T 口径，那部分就按价差评估 —— 不要用趋势依据去否定一笔做 T 计划，也不要给无条件买卖指令。**不要臆造用户画像、技术数据或止盈目标。
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
