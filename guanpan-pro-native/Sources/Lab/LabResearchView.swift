import SwiftUI

struct LabResearchView: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var researchEngine: PhoneResearchEngine
    @EnvironmentObject private var channels: LabChannelCoordinator
    @Environment(\.visualTheme) private var visualTheme
    @State private var question = "愿意等更低价格，如何安排未来资金？"
    @State private var monthly = ""
    @State private var months = "12"
    @State private var response = ""
    @StateObject private var dialogue = ResearchConversationStore()
    @State private var researchText = ""
    @State private var todayStatus = "正在检查真实持仓与行情…"
    @State private var decisionRows: [[String: Any]] = []
    @State private var scanError = ""
    @State private var onlineBusy = false
    @State private var onlineReply = ""
    @State private var fillCandidate: AdvisorFillCandidate?
    @State private var displayNow = Date.now
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var conversationScope: String { "real" }
    private var conversation: [String] { dialogue.histories[conversationScope] ?? [] }
    private var isLight: Bool { !tokens.isDark }
    private var tokens: DesignTokens { ThemeManager.tokens(visualTheme) }
    var body: some View {
        List {
            advisorHero
            if !scanError.isEmpty {
                Section {
                    Label(scanError, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }.toneCard(CardTone.warn, isLight: isLight)
            }
            Group {
                Text("真实持仓 · 统一指导")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tokens.secondary)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 5, leading: tokens.pageInset,
                                              bottom: 5, trailing: tokens.pageInset))
                    .listRowBackground(tokens.background)
                    .listRowSeparator(.hidden)
                NavigationLink("逐只核对 ETF 交易规则与可卖份额") { ETFTradingRuleView() }
                    .listRowBackground(tokens.surface)
                if decisionRows.isEmpty {
                    Text("暂无可核实的真实持仓指导。请检查持仓、行情时间和 NAS 数据。")
                        .foregroundStyle(.secondary)
                        .toneCard(CardTone.warn, isLight: isLight)
                        .listRowBackground(Color.clear)
                }
                ForEach(decisionRows.indices, id: \.self) { index in
                    ThemePanel(tone: tone(for: decisionRows[index]["action"] as? String ?? "").opacity(
                        visualTheme == .bento ? 0.31 : 0.17)) {
                        decisionCard(decisionRows[index], rank: index + 1)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: tokens.pageInset, bottom: 6, trailing: tokens.pageInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            Section("手机 AI · 补充解释") {
                Text("本机规则先形成唯一判断。在线模型只解释同一份真实持仓和行情快照，不能自行编造限价或相反指令。")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("研究问题与偏好", text: $question, axis: .vertical)
                Button(onlineBusy ? "正在请求已配置模型…" : "让手机大模型分析真实持仓") { Task { await askOnline() } }
                    .disabled(onlineBusy || !AIAnalysisService.hasSavedAPIKey)
                Text("手机直接请求已配置的模型；未配置密钥时仍可用本机规则。")
                    .font(.caption).foregroundStyle(.secondary)
                if !onlineReply.isEmpty {
                    Text(onlineReply).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.toneCard(CardTone.ok, isLight: isLight)
            Section("更多研究与复盘") {
                DisclosureGroup("未来资金研究") {
                    TextField("每月未来可投入金额（元）", text: $monthly).keyboardType(.decimalPad)
                    TextField("规划月数", text: $months).keyboardType(.numberPad)
                    Button("结合真实账户研究") { advise() }
                    if !response.isEmpty { Text(response).textSelection(.enabled) }
                }
                DisclosureGroup("研究明细与数据缺口") {
                    Text(researchText).font(.footnote).textSelection(.enabled)
                }
                DisclosureGroup("本机对话记录") {
                    if !dialogue.errorMessage.isEmpty { Text(dialogue.errorMessage).foregroundStyle(.red) }
                    ForEach(conversation.indices, id: \.self) { index in
                        Text(conversation[index]).font(.footnote)
                    }
                }
                DisclosureGroup("历史 AI 判断") {
                    if portfolio.data.advisorDecisionRecords.isEmpty {
                        Text("尚无真实持仓判断记录。").foregroundStyle(.secondary)
                    }
                    Text(decisionMemorySummary())
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(portfolio.data.advisorDecisionRecords.suffix(30).reversed())) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(record.name) · \(record.action)")
                                .font(.subheadline.weight(.semibold))
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)
                                + " · " + record.marketRegime + " · " + record.reason)
                                .font(.footnote).foregroundStyle(.secondary)
                            if !record.changeReason.isEmpty {
                                Text(record.changeReason).font(.footnote).foregroundStyle(CardTone.warn)
                            }
                            if let lifecycle = planLifecycle(record) {
                                Text(lifecycle).font(.footnote).foregroundStyle(CardTone.warn)
                                Button("补录该判断相关的券商实际成交") {
                                    fillCandidate = AdvisorFillCandidate(symbol: record.symbol,
                                        name: record.name, decisionID: record.id,
                                        decisionCreatedAt: record.createdAt,
                                        planType: savedPlanType(record) ?? "")
                                }
                                .buttonStyle(.bordered)
                            }
                            let actual = portfolio.data.dynamicInvestorProfile.realTradeLinks
                                .filter { $0.decisionID == record.id }
                                .compactMap { link in portfolio.data.ledger.first { $0.id == link.ledgerID } }
                            if !actual.isEmpty {
                                Text("关联券商真实成交 \(actual.count) 笔：" + actual.map {
                                    "\($0.side == .buy ? "买" : "卖")\($0.quantity.num(0))份 @ \($0.price.num(3))"
                                }.joined(separator: "；"))
                                    .font(.footnote).foregroundStyle(CardTone.ok)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let result = observedRoundTrip(actual) {
                                    Text(result).font(.footnote).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.toneCard(CardTone.warn, isLight: isLight)
        }
        .scrollContentBackground(.hidden)
        .background(tokens.background.ignoresSafeArea())
        .appListLayout().navigationTitle("AI 今日指导")
        .onAppear { scan() }
        .onChange(of: portfolio.data.ledger.count) { _, _ in scan() }
        .onChange(of: channels.market.revision) { _, _ in scan() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { time in
            displayNow = time
        }
        .sheet(item: $fillCandidate) { candidate in
            AdvisorActualFillView(candidate: candidate).environmentObject(portfolio)
        }
    }
    private var heroColors: [Color] {
        switch visualTheme {
        case .eastern: return [Color(red: 1, green: 0.86, blue: 0.54), Color(red: 1, green: 0.95, blue: 0.80)]
        case .modern: return [Color(red: 0.00, green: 0.60, blue: 0.84), Color(red: 0.28, green: 0.29, blue: 0.89)]
        case .dashboard: return [Color(red: 0.24, green: 0.36, blue: 0.86), Color(red: 0.36, green: 0.20, blue: 0.58)]
        case .magazine: return [Color(red: 1, green: 0.89, blue: 0.83), Color(red: 1, green: 0.97, blue: 0.91)]
        case .bento, .scene: return [tokens.hero, Color(red: 1, green: 0.94, blue: 0.74)]
        }
    }
    @ViewBuilder private var advisorHero: some View {
        switch visualTheme {
        case .eastern:
            heroSection {
                ZStack(alignment: .trailing) {
                    LandscapeDecoration(color: Color(red: 0.76, green: 0.48, blue: 0.14))
                        .frame(height: 160).opacity(0.24)
                    VStack(alignment: .leading, spacing: 9) {
                        Label("观盘手册 · 今日批注", systemImage: "sun.max.fill")
                            .font(.headline).foregroundStyle(Color(red: 0.55, green: 0.32, blue: 0.09))
                        Text(todayStatus).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text("真实持仓逐只核对 · 证据不足不报挂单价")
                            .font(.subheadline).foregroundStyle(.secondary)
                        scanButton
                    }.frame(maxWidth: .infinity, minHeight: 142, alignment: .leading).padding(17)
                }
            }
        case .modern:
            heroSection {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 32, weight: .medium)).frame(width: 54, height: 54)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI 今日指导").font(.headline)
                        Text(todayStatus).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text("真实持仓 · 最新行情 · NAS研究")
                            .font(.caption).foregroundStyle(.white.opacity(0.82))
                        scanButton
                    }
                    Spacer(minLength: 0)
                }.padding(18).frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            }
        case .dashboard:
            heroSection {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("统一决策台", systemImage: "waveform.path.ecg")
                            .font(.headline)
                        Spacer()
                        Text("\(decisionRows.count) 持仓")
                            .font(.caption.monospacedDigit()).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.white.opacity(0.13), in: Capsule())
                    }
                    Text(todayStatus).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Label("价格只由本机规则计算", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.white.opacity(0.80))
                        Spacer()
                        scanButton
                    }
                }.padding(17).frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            }
        case .magazine:
            heroSection {
                ZStack(alignment: .trailing) {
                    LandscapeDecoration(color: Color(red: 0.73, green: 0.33, blue: 0.38))
                        .frame(height: 168).opacity(0.24)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                            .font(.caption.weight(.semibold)).foregroundStyle(Color(red: 0.59, green: 0.29, blue: 0.30))
                        Text("今日市场观察").font(.system(size: 27, weight: .bold, design: .serif))
                        Text(todayStatus).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text("真实持仓 · 有证据才形成候选计划")
                            .font(.subheadline).foregroundStyle(.secondary)
                        scanButton
                    }.frame(maxWidth: .infinity, minHeight: 148, alignment: .leading).padding(17)
                }
            }
        case .bento, .scene:
            heroSection {
                VStack(alignment: .leading, spacing: 12) {
                    Text("今天有没有值得操作的机会？")
                        .font(.headline)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: "sparkles").font(.title3)
                            Text(todayStatus).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            Text("统一 AI 指导").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
                            .padding(13).background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("覆盖").font(.caption).foregroundStyle(.secondary)
                            Text("\(decisionRows.count)").font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("只真实持仓").font(.caption)
                            compactScanButton
                        }.frame(width: 112, alignment: .leading).padding(13)
                            .background(tokens.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(14)
            }
        }
    }
    private var scanButton: some View {
        Button("重新检查", systemImage: "arrow.clockwise") { scan() }
            .buttonStyle(.bordered).tint(visualTheme == .dashboard || visualTheme == .modern ? .white : tokens.accent)
    }
    private var compactScanButton: some View {
        Button { scan() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.headline.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.bordered)
        .tint(tokens.accent)
        .accessibilityLabel("重新检查")
    }
    private func heroSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Section { content()
            .foregroundStyle(visualTheme == .dashboard || visualTheme == .modern ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: tokens.corner, style: .continuous))
            .background(LinearGradient(colors: heroColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: tokens.corner))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: tokens.pageInset, bottom: 8, trailing: tokens.pageInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    private func tone(for action: String) -> Color {
        switch action {
        case "暂停加仓", "减仓": return CardTone.warn
        case "长期持有": return CardTone.ok
        default: return CardTone.accent
        }
    }
    private func decisionCard(_ row: [String: Any], rank: Int) -> some View {
        let name = row["name"] as? String ?? row["symbol"] as? String ?? "未知持仓"
        let symbol = row["symbol"] as? String ?? ""
        let action = row["action"] as? String ?? "不交易"
        let intraday = row["intraday"] as? [String: Any] ?? [:]
        let sessions = intraday["sessions"] as? Int ?? 0
        let quoteAt = (row["quoteAt"] as? NSNumber)?.doubleValue
        let date = quoteAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(rank)).font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(tone(for: action).opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(symbol).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(action).font(.caption.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(tone(for: action).opacity(0.16), in: Capsule())
                    .fixedSize()
            }
            Text(row["reason"] as? String ?? "证据不足").font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let change = row["changeReason"] as? String, !change.isEmpty {
                Label(change, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("状态：\(row["marketRegime"] as? String ?? "未知") · 分时 \(sessions) 日")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("行情：\(date?.formatted(date: .abbreviated, time: .shortened) ?? "缺失") · \(row["source"] as? String ?? "来源不明")")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let news = row["relatedNews"] as? [[String: Any]], !news.isEmpty {
                let shownNews = Array(news.prefix(3))
                ForEach(shownNews.indices, id: \.self) { index in
                    let item = shownNews[index]
                    let headline = item["headline"] as? String ?? "关联事件"
                    let publisher = item["publisher"] as? String ?? "来源未明"
                    if let raw = item["sourceURL"] as? String, let url = URL(string: raw) {
                        Link("\(item["importance"] as? String == "major" ? "重大事件" : "相关资讯") · \(headline) · \(publisher)", destination: url)
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let recovery = row["recovery"] as? [String: Any],
               recovery["status"] as? String == "in-loss" {
                recoveryCard(recovery)
            }
            if row["plan"] is NSNull || row["plan"] == nil {
                Label("当前无法给出可靠的具体挂单价格", systemImage: "lock.shield")
                    .font(.caption.weight(.medium)).foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
                let blockers = row["planBlockers"] as? [String] ?? []
                if !blockers.isEmpty {
                    Text(blockers.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let plan = row["plan"] as? [String: Any], isCurrentPlan(plan) {
                candidatePlanCard(plan)
                if let idText = row["decisionRecordID"] as? String,
                   let decisionID = UUID(uuidString: idText) {
                    Button("我已在券商真实成交", systemImage: "checkmark.seal") {
                        fillCandidate = AdvisorFillCandidate(symbol: symbol, name: name,
                            decisionID: decisionID,
                            decisionCreatedAt: portfolio.data.advisorDecisionRecords
                                .first(where: { $0.id == decisionID })?.createdAt ?? .now,
                            planType: plan["type"] as? String ?? "")
                    }
                    .buttonStyle(.bordered)
                }
            } else if row["plan"] is [String: Any] {
                Label("候选计划已过期；请重新检查最新行情、盘口与相关事件。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.medium)).foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let idText = row["decisionRecordID"] as? String, let id = UUID(uuidString: idText) {
                Menu {
                    ForEach(AdvisorFeedbackKind.allCases) { kind in
                        Button(kind.title) { saveFeedback(decisionID: id, symbol: symbol, kind: kind) }
                    }
                } label: {
                    Label("反馈这条判断", systemImage: "hand.thumbsup")
                        .font(.caption.weight(.medium))
                }
                if let feedback = portfolio.data.dynamicInvestorProfile.feedback.last(where: { $0.decisionID == id }) {
                    Text("已记录：\(feedback.kind.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }
    private func candidatePlanCard(_ plan: [String: Any]) -> some View {
        if plan["type"] as? String == "grid" {
            return AnyView(candidateGridCard(plan))
        }
        let type = plan["type"] as? String == "reverseT" ? "反T候选限价计划" : "正T候选限价计划"
        let quantity = (plan["quantity"] as? NSNumber)?.intValue ?? 0
        let sell = (plan["sellLimitYuan"] as? NSNumber)?.doubleValue ?? 0
        let buy = (plan["buyLimitYuan"] as? NSNumber)?.doubleValue ?? 0
        let gross = (plan["grossYuan"] as? NSNumber)?.doubleValue ?? 0
        let fees = (plan["feesYuan"] as? NSNumber)?.doubleValue ?? 0
        let net = (plan["netYuan"] as? NSNumber)?.doubleValue ?? 0
        let reduction = (plan["equivalentCostReductionYuanPerShare"] as? NSNumber)?.doubleValue ?? 0
        let history = plan["historicalTouches"] as? [String: Any] ?? [:]
        let ordered = (history["orderedRoundTrips"] as? NSNumber)?.intValue ?? 0
        let days = (history["days"] as? NSNumber)?.intValue ?? 0
        let wait = (history["meanWaitMinutes"] as? NSNumber)?.doubleValue
        let expiry = (plan["validUntil"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return AnyView(VStack(alignment: .leading, spacing: 7) {
            Label(type, systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.bold))
            Text("卖出 \(quantity)份 @ ¥\(sell.formatted(.number.precision(.fractionLength(3)))) · 买回 \(quantity)份 @ ¥\(buy.formatted(.number.precision(.fractionLength(3))))")
                .font(.subheadline.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
            Text("两笔均成交：毛价差 ¥\(gross.formatted(.number.precision(.fractionLength(2)))) · 手续费 ¥\(fees.formatted(.number.precision(.fractionLength(2)))) · 预计净收益 ¥\(net.formatted(.number.precision(.fractionLength(2))))")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("按当前全部持仓摊薄，理论等效降本 ¥\(reduction.formatted(.number.precision(.fractionLength(4))))/份；历史 \(days) 日中 \(ordered) 日按顺序触及两价，不代表未来成交概率。")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let wait {
                Text("历史完整往返平均等待约 \(wait.formatted(.number.precision(.fractionLength(0)))) 分钟；未往返的日子不计入这个平均值。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Text("研究截至：\(researchDate(plan["researchLastAt"])) · 行情：\(researchDate(plan["quoteAt"])) · 盘口：\(researchDate(plan["bookAt"]))")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("分时来源：\(plan["source"] as? String ?? "未知") · 交易规则：\(plan["ruleSource"] as? String ?? "未知")（\(researchDate(plan["ruleConfirmedAt"]))核对）")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(planCoverage(plan))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("有效至 \(expiry?.formatted(date: .omitted, time: .standard) ?? "未知") · 仅供券商手工核对")
                .font(.caption.weight(.medium)).foregroundStyle(CardTone.warn)
            if let evidence = plan["evidence"] as? [String] {
                Text("依据：" + evidence.joined(separator: "、"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let risks = plan["risks"] as? [String] {
                Text("风险：" + risks.joined(separator: "；"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let invalidation = plan["invalidation"] as? [String] {
                Text("失效：" + invalidation.joined(separator: "；"))
                    .font(.caption).foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone(for: "做T").opacity(0.11), in: RoundedRectangle(cornerRadius: 14)))
    }
    private func candidateGridCard(_ plan: [String: Any]) -> some View {
        let bands = plan["bands"] as? [[String: Any]] ?? []
        let lower = (plan["lowerYuan"] as? NSNumber)?.doubleValue ?? 0
        let upper = (plan["upperYuan"] as? NSNumber)?.doubleValue ?? 0
        let capital = (plan["maxBuyCapitalYuan"] as? NSNumber)?.doubleValue ?? 0
        let remaining = (plan["remainingSharesAfterAllSells"] as? NSNumber)?.intValue ?? 0
        return VStack(alignment: .leading, spacing: 7) {
            Label("动态网格候选计划 · \(bands.count)档", systemImage: "square.grid.3x3")
                .font(.subheadline.weight(.bold))
            Text("区间 ¥\(lower.formatted(.number.precision(.fractionLength(3))))–¥\(upper.formatted(.number.precision(.fractionLength(3)))) · 档距 ¥\(((plan["stepYuan"] as? NSNumber)?.doubleValue ?? 0).formatted(.number.precision(.fractionLength(3))))")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            ForEach(bands.indices, id: \.self) { index in
                let band = bands[index]
                let buy = (band["buyLimitYuan"] as? NSNumber)?.doubleValue ?? 0
                let sell = (band["sellLimitYuan"] as? NSNumber)?.doubleValue ?? 0
                let quantity = (band["quantity"] as? NSNumber)?.intValue ?? 0
                let net = (band["expectedNetYuan"] as? NSNumber)?.doubleValue ?? 0
                Text("第\(index + 1)档 · 买 ¥\(buy.formatted(.number.precision(.fractionLength(3)))) / 卖 ¥\(sell.formatted(.number.precision(.fractionLength(3)))) · \(quantity)份 · 两腿全成交净收益 ¥\(net.formatted(.number.precision(.fractionLength(2))))")
                    .font(.caption.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
            }
            Text("全部买档资金占用（含逐笔手续费）≤ ¥\(capital.formatted(.number.precision(.fractionLength(2)))) · 全部卖档成交后剩余 \(remaining)份")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("行情：\(researchDate(plan["quoteAt"])) · 盘口：\(researchDate(plan["bookAt"])) · 有效至：\(researchDate(plan["validUntil"]))")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("分时来源：\(plan["source"] as? String ?? "未知") · 交易规则：\(plan["ruleSource"] as? String ?? "未知")（\(researchDate(plan["ruleConfirmedAt"]))核对）")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(planCoverage(plan)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let invalidation = plan["invalidation"] as? [String] {
                Text("暂停条件：" + invalidation.joined(separator: "；"))
                    .font(.caption).foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("仅供券商手工核对；未成交不进入真实账户。")
                .font(.caption.weight(.medium))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone(for: "网格").opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
    }
    private func recoveryCard(_ recovery: [String: Any]) -> some View {
        let rise = (recovery["breakEvenRisePct"] as? NSNumber)?.doubleValue ?? 0
        let cycles = recovery["threeCompletedCycles"] as? [String: Any]
        let add = recovery["cautiousAdd"] as? [String: Any]
        let trim = recovery["trimQuarter"] as? [String: Any]
        let feeNote = recovery["exitFeeEstimated"] as? Bool == true ? "（按ETF每笔0.10元估算）" : ""
        return DisclosureGroup("回本路径与风险") {
            VStack(alignment: .leading, spacing: 6) {
                Text("不操作：现价需上涨 \((rise * 100).formatted(.number.precision(.fractionLength(2))))% 才覆盖当前成本及一笔卖出手续费\(feeNote)。")
                if let cycles {
                    let net = (cycles["netYuan"] as? NSNumber)?.doubleValue ?? 0
                    let cost = (cycles["equivalentCostYuanPerShare"] as? NSNumber)?.doubleValue ?? 0
                    Text("若重复完成三次同等价差：理论合计净价差 ¥\(net.formatted(.number.precision(.fractionLength(2))))，理论等效成本 ¥\(cost.formatted(.number.precision(.fractionLength(4))))/份；不是收益承诺。")
                }
                if let add {
                    let shares = (add["quantity"] as? NSNumber)?.intValue ?? 0
                    let cash = (add["requiredCashYuan"] as? NSNumber)?.doubleValue ?? 0
                    let cost = (add["newAverageCostYuan"] as? NSNumber)?.doubleValue ?? 0
                    Text("谨慎补仓对比：增加 \(shares)份需约 ¥\(cash.formatted(.number.precision(.fractionLength(2))))，新平均成本约 ¥\(cost.formatted(.number.precision(.fractionLength(4))))/份，同时扩大下跌敞口。")
                } else {
                    Text("当前现金、仓位上限或ETF规则不足，未提供补仓份额。")
                }
                if let trim {
                    let shares = (trim["shares"] as? NSNumber)?.intValue ?? 0
                    let exposure = (trim["exposureReductionYuan"] as? NSNumber)?.doubleValue ?? 0
                    Text("减仓对比：若真实卖出 \(shares)份，可减少约 ¥\(exposure.formatted(.number.precision(.fractionLength(2)))) 的价格敞口；是否卖出仍取决于统一指导。")
                }
                Text(recovery["caveat"] as? String ?? "只作为情形比较。")
                    .foregroundStyle(CardTone.warn)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func researchDate(_ raw: Any?) -> String {
        guard let millis = (raw as? NSNumber)?.doubleValue else { return "未知" }
        return Date(timeIntervalSince1970: millis / 1000).formatted(date: .abbreviated, time: .shortened)
    }
    private func planCoverage(_ plan: [String: Any]) -> String {
        let sessions = (plan["intradaySessions"] as? NSNumber)?.intValue ?? 0
        let complete = (plan["completeMinuteDays"] as? NSNumber)?.intValue ?? 0
        let volume = ((plan["volumeCoverage"] as? NSNumber)?.doubleValue ?? 0) * 100
        let confidence = plan["confidenceLabel"] as? String ?? "未知"
        return "历史分时 \(sessions)日 · 完整分钟日 \(complete)日 · 成交量覆盖 \(volume.formatted(.number.precision(.fractionLength(0))))% · 证据可信度：\(confidence)"
    }
    private func isCurrentPlan(_ plan: [String: Any]) -> Bool {
        guard let expiry = (plan["validUntil"] as? NSNumber)?.doubleValue else { return false }
        return expiry > displayNow.timeIntervalSince1970 * 1000
    }
    private func observedRoundTrip(_ entries: [LedgerEntry]) -> String? {
        guard let result = InvestorProfileEngine.matchedDecisionTrades(entries) else { return nil }
        return "已按时间顺序匹配真实买卖流水 \(result.quantity.num(0)) 份，观察净价差 \(result.net.cny())；费用按部分成交比例分摊，未匹配份额不计入。"
    }
    private func planLifecycle(_ record: AdvisorDecisionRecord) -> String? {
        guard let saved = record.evidenceSnapshotJSON?.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let plan = snapshot["plan"] as? [String: Any],
              let expiry = (plan["validUntil"] as? NSNumber)?.doubleValue else { return nil }
        let actualIDs = Set(portfolio.data.ledger.map(\.id))
        let linkedIDs = Set(portfolio.data.dynamicInvestorProfile.realTradeLinks
            .filter { $0.decisionID == record.id && actualIDs.contains($0.ledgerID) }
            .map(\.ledgerID))
        let actual = portfolio.data.ledger.filter { linkedIDs.contains($0.id) }
        if !actual.isEmpty {
            let late = actual.contains { $0.date.timeIntervalSince1970 * 1000 > expiry }
            return late
                ? "计划状态：已关联真实成交，其中有成交晚于原计划有效期；复盘时不能视为计划内命中。"
                : "计划状态：已关联券商真实成交，详见下方流水复盘。"
        }
        if expiry <= displayNow.timeIntervalSince1970 * 1000 { return "计划状态：已过期且未确认成交；不会计入真实流水。" }
        return "计划状态：候选有效至 " + Date(timeIntervalSince1970: expiry / 1000)
            .formatted(date: .abbreviated, time: .standard)
    }
    private func savedPlanType(_ record: AdvisorDecisionRecord) -> String? {
        guard let raw = record.evidenceSnapshotJSON?.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let plan = snapshot["plan"] as? [String: Any] else { return nil }
        return plan["type"] as? String
    }
    private func decisionMemorySummary() -> String {
        let records = portfolio.data.advisorDecisionRecords
        let actualIDs = Set(portfolio.data.ledger.map(\.id))
        var candidates = 0, linked = 0, expired = 0
        for record in records {
            guard let raw = record.evidenceSnapshotJSON?.data(using: .utf8),
                  let snapshot = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let plan = snapshot["plan"] as? [String: Any] else { continue }
            candidates += 1
            if portfolio.data.dynamicInvestorProfile.realTradeLinks.contains(where: {
                $0.decisionID == record.id && actualIDs.contains($0.ledgerID)
            }) { linked += 1 }
            else if let until = (plan["validUntil"] as? NSNumber)?.doubleValue,
                    until <= displayNow.timeIntervalSince1970 * 1000 { expired += 1 }
        }
        return "已保存 \(records.count) 条判断，其中候选计划 \(candidates) 条、关联券商真实成交 \(linked) 条、未确认成交且已过期 \(expired) 条。缺逐笔盘口时不推断触发率。"
    }
    private func saveFeedback(decisionID: UUID, symbol: String, kind: AdvisorFeedbackKind) {
        guard portfolio.data.advisorDecisionRecords.contains(where: { $0.id == decisionID && $0.symbol == symbol }) else { return }
        portfolio.data.dynamicInvestorProfile.feedback.removeAll { $0.decisionID == decisionID }
        portfolio.data.dynamicInvestorProfile.feedback.append(
            AdvisorFeedback(decisionID: decisionID, symbol: symbol, kind: kind))
        portfolio.save(label: "记录AI判断反馈")
        scan()
    }
    private func inputs() throws -> [String: Any] {
        try ResearchInputBuilder.make(portfolio: portfolio, channels: channels, at: now)
    }
    private func advise() {
        do {
            guard let value = monthly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(monthly),
                  value.isFinite, value >= 0, let count = Int(months), (0...600).contains(count) else {
                throw PhoneResearchEngine.EngineError.message("请检查未来资金计划")
            }
            let input = try inputs()
            let result = try researchEngine.call("research.decisionContext", [input, now]) as? [String: Any] ?? [:]
            let decisions = result["decisions"] as? [[String: Any]] ?? []
            response = "未来每月 \(value.cny())、共 \(count) 个月仅作为你的资金意向；尚未计入可用现金或任何持仓。\n"
                + decisions.map { "\($0["name"] as? String ?? "持仓")：\($0["action"] as? String ?? "不交易")。 \($0["reason"] as? String ?? "证据不足")" }.joined(separator: "\n")
                + "\n在真实资金到账并确认行情前，不生成买入份额与限价。"
            dialogue.append("你：\(question)\n离线顾问：\(response)", scope: conversationScope)
        } catch { response = error.localizedDescription }
    }
    private func scan() {
        do {
            let input = try inputs()
            let result = try researchEngine.call("research.radar", [input, now]) as? [String: Any] ?? [:]
            let statsResult = try researchEngine.call("research.intradayStats", [input, now]) as? [String: Any] ?? [:]
            let unified = try researchEngine.call("research.decisionContext", [input, now]) as? [String: Any] ?? [:]
            todayStatus = unified["todayStatus"] as? String ?? "今天不建议交易。"
            decisionRows = recordDecisionMemory(unified["decisions"] as? [[String: Any]] ?? [], input: input)
            scanError = ""
            let coverage = result["coverage"] as? [String: Any] ?? [:]
            let holdings = (input["realPortfolio"] as? [String: Any])?["holdings"] as? [[String: Any]] ?? []
            let holdingCodes = Set(holdings.compactMap { $0["symbol"] as? String })
            let ranked = (result["ranked"] as? [[String: Any]] ?? []).filter { holdingCodes.contains($0["symbol"] as? String ?? "") }
            let stats = Dictionary(uniqueKeysWithValues: ((statsResult["rows"] as? [[String: Any]]) ?? []).compactMap { row -> (String, [String: Any])? in
                guard let symbol = row["symbol"] as? String else { return nil }; return (symbol, row)
            })
            let decisions = Dictionary(uniqueKeysWithValues: ((unified["decisions"] as? [[String: Any]]) ?? []).compactMap { row -> (String, [String: Any])? in
                guard let symbol = row["symbol"] as? String else { return nil }; return (symbol, row)
            })
            var lines = [unified["todayStatus"] as? String ?? "今天不建议交易。",
                "真实持仓 \(holdings.count) 只 · NAS覆盖 \(coverage["count"] as? Int ?? 0) 只 · 范围 \(coverage["scope"] as? String ?? "未知")。"]
            for row in ranked.sorted(by: { (($0["score"] as? NSNumber)?.doubleValue ?? -1) > (($1["score"] as? NSNumber)?.doubleValue ?? -1) }) {
                let symbol = row["symbol"] as? String ?? "未知代码"
                let name = holdings.first(where: { $0["symbol"] as? String == symbol })?["name"] as? String ?? symbol
                let score = (row["score"] as? NSNumber)?.doubleValue
                let health = row["health"] as? [String: Any] ?? [:]
                let missing = health["missing"] as? [String] ?? []
                let s = stats[symbol] ?? [:]
                let regime = s["regime"] as? String ?? "分时证据不足"
                let sessions = s["sessions"] as? Int ?? 0
                let points = s["samplePoints"] as? Int ?? 0
                let blockers = s["blockers"] as? [String] ?? ["缺少长期分时统计"]
                let decision = decisions[symbol] ?? [:]
                let recommendation = decision["action"] as? String ?? "不交易"
                let reason = decision["reason"] as? String ?? "统一决策上下文不可用"
                lines.append("\(name)（\(symbol)）· \(recommendation) · 市场状态：\(regime) · 日线因子 \(score.map { Int($0 * 100) } ?? 0)/100")
                lines.append("判断：\(reason)")
                lines.append("分时样本：\(sessions) 个交易日 / \(points) 点 · 来源：\(s["source"] as? String ?? "未知")")
                for window in ["5", "20", "60", "120"] {
                    let w = (s["windows"] as? [String: Any])?[window] as? [String: Any] ?? [:]
                    if w["available"] as? Bool == true, let range = w["meanRangePct"] as? NSNumber {
                        lines.append("近\(window)日平均日内振幅 \((range.doubleValue * 100).num(2))%")
                    }
                }
                if decision["plan"] is [String: Any] {
                    lines.append("已生成短时有效的做T候选价；请核对卡片内盘口、费用和失效条件。")
                } else {
                    let planBlockers = decision["planBlockers"] as? [String] ?? []
                    lines.append("无法给出价格的原因：\((blockers + missing + planBlockers).isEmpty ? "当前未达到保守交易门槛" : (blockers + missing + planBlockers).joined(separator: "、"))。")
                }
            }
            if holdings.isEmpty { lines.append("没有真实持仓；不会按虚拟账户生成建议。") }
            if ranked.isEmpty && !holdings.isEmpty { lines.append("NAS未覆盖当前真实持仓或缺少有效行情；本轮不提供交易价格。") }
            researchText = lines.joined(separator: "\n")
        } catch {
            researchText = error.localizedDescription
            scanError = error.localizedDescription
            todayStatus = "当前无法形成可靠指导"
            decisionRows = []
        }
    }
    private func recordDecisionMemory(_ rows: [[String: Any]], input: [String: Any]) -> [[String: Any]] {
        var enriched: [[String: Any]] = []
        var newRecords: [AdvisorDecisionRecord] = []
        for var row in rows {
            guard let symbol = row["symbol"] as? String,
                  portfolio.data.holdings.contains(where: { $0.code == symbol && $0.quantity > 0 }) else { continue }
            let previous = portfolio.data.advisorDecisionRecords.last { $0.symbol == symbol }
            let action = row["action"] as? String ?? "不交易"
            let regime = row["marketRegime"] as? String ?? "证据不足"
            let reason = row["reason"] as? String ?? "缺少数据"
            let identity = planIdentity(row["plan"] as? [String: Any])
            let changed = previous != nil && (previous?.action != action ||
                previous?.marketRegime != regime || previous?.planIdentity != identity)
            let changeReason = changed
                ? "上次：\(previous?.action ?? "未知")（\(previous?.marketRegime ?? "未知")）；本次：\(action)（\(regime)）。" +
                    evidenceChangeSummary(previous: previous, row: row, symbol: symbol) +
                    "当前依据：\(reason)"
                : ""
            if changed { row["changeReason"] = changeReason }
            let alreadyToday = previous.map { Calendar.current.isDateInToday($0.createdAt) } ?? false
            if changed || !alreadyToday {
                let intraday = row["intraday"] as? [String: Any] ?? [:]
                let timestamp = (row["quoteAt"] as? NSNumber)?.doubleValue
                let holding = portfolio.data.holdings.first { $0.code == symbol && $0.quantity > 0 }
                let news = (input["news"] as? [[String: Any]] ?? []).filter {
                    $0["symbol"] as? String == symbol ||
                        ($0["symbol"] as? String == "MARKET" &&
                            ($0["eventScope"] as? String == "market" ||
                                ($0["affectedSymbols"] as? [String] ?? []).contains(symbol)))
                }
                let evidence: [String: Any] = [
                    "snapshotAt": now, "quoteAt": row["quoteAt"] ?? NSNull(),
                    "quotePriceUnits": row["quotePriceUnits"] ?? NSNull(),
                    "holdingQuantity": holding?.quantity ?? 0,
                    "holdingCost": holding?.cost ?? 0,
                    "holdingDisplayedCost": holding.map { portfolio.displayedCost(for: $0) } ?? 0,
                    "realCash": portfolio.data.cash,
                    "nasAvailable": row["nasScreened"] ?? false,
                    "marketRegime": regime,
                    "intraday": intraday,
                    "plan": row["plan"] ?? NSNull(),
                    "planBlockers": row["planBlockers"] ?? [],
                    "relatedNews": news,
                    "profile": InvestorProfileEngine.onlineSummary(
                        portfolio.data.dynamicInvestorProfile,
                        existingSettings: portfolio.data.investmentProfile)
                ]
                let snapshot = (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
                var record = AdvisorDecisionRecord(symbol: symbol,
                    name: row["name"] as? String ?? symbol, action: action, reason: reason,
                    marketRegime: regime,
                    quoteAt: timestamp.map { Date(timeIntervalSince1970: $0 / 1000) },
                    dataSource: row["source"] as? String ?? "来源不明",
                    intradaySessions: intraday["sessions"] as? Int ?? 0,
                    nasAvailable: row["nasScreened"] as? Bool ?? false,
                    changeReason: changeReason)
                record.evidenceSnapshotJSON = snapshot
                record.planIdentity = identity
                row["decisionRecordID"] = record.id.uuidString
                newRecords.append(record)
            } else if let previous {
                row["decisionRecordID"] = previous.id.uuidString
            }
            enriched.append(row)
        }
        if !newRecords.isEmpty {
            portfolio.data.advisorDecisionRecords.append(contentsOf: newRecords)
            if portfolio.data.advisorDecisionRecords.count > 500 {
                portfolio.data.advisorDecisionRecords.removeFirst(portfolio.data.advisorDecisionRecords.count - 500)
            }
            portfolio.save(label: "记录真实持仓 AI 判断")
        }
        return enriched
    }
    private func planIdentity(_ plan: [String: Any]?) -> String? {
        guard let plan else { return nil }
        let keys = ["type", "quantity", "sellLimitYuan", "buyLimitYuan", "lowerYuan", "upperYuan", "levels"]
        return keys.map { key in "\(key)=\(plan[key].map { String(describing: $0) } ?? "")" }
            .joined(separator: "|")
    }
    private func evidenceChangeSummary(previous: AdvisorDecisionRecord?, row: [String: Any],
                                       symbol: String) -> String {
        guard let raw = previous?.evidenceSnapshotJSON?.data(using: .utf8),
              let old = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return "旧证据快照不可用；"
        }
        var changes: [String] = []
        let oldPrice = (old["quotePriceUnits"] as? NSNumber)?.doubleValue
        let newPrice = (row["quotePriceUnits"] as? NSNumber)?.doubleValue
        if let oldPrice, let newPrice, oldPrice > 0,
           abs(newPrice / oldPrice - 1) >= 0.005 {
            changes.append("行情较上次变化 \(((newPrice / oldPrice - 1) * 100).formatted(.number.precision(.fractionLength(2))))%")
        }
        let oldShares = (old["holdingQuantity"] as? NSNumber)?.doubleValue
        let newShares = portfolio.data.holdings.first { $0.code == symbol }?.quantity
        if let oldShares, let newShares, abs(newShares - oldShares) > 0.001 {
            changes.append("真实份额由 \(oldShares.num(0)) 变为 \(newShares.num(0))")
        }
        let oldNews = old["relatedNews"] as? [[String: Any]] ?? []
        let newNews = row["relatedNews"] as? [[String: Any]] ?? []
        if oldNews.count != newNews.count { changes.append("关联事件由 \(oldNews.count) 条变为 \(newNews.count) 条") }
        if previous?.planIdentity != planIdentity(row["plan"] as? [String: Any]) {
            changes.append("候选策略限价或份额变化")
        }
        let nas = row["nasScreened"] as? Bool ?? false
        if previous?.nasAvailable != nas { changes.append("NAS机会扫描可用性变化") }
        return changes.isEmpty ? "可核对的变化：市场状态或判断依据已更新；" :
            "可核对的变化：" + changes.joined(separator: "、") + "；"
    }
    private func askOnline() async {
        guard !onlineBusy else { return }; onlineBusy = true; defer { onlineBusy = false }
        do {
            let input = try inputs()
            let replyScope = conversationScope
            let decisionContext = try researchEngine.call("research.decisionContext", [input, now]) as? [String: Any] ?? [:]
            var compactMarket = input
            if var realPortfolio = compactMarket["realPortfolio"] as? [String: Any] {
                realPortfolio.removeValue(forKey: "ledger")
                compactMarket["realPortfolio"] = realPortfolio
            }
            if var instruments = compactMarket["instruments"] as? [[String: Any]] {
                for index in instruments.indices { instruments[index].removeValue(forKey: "intradayBars") }
                compactMarket["instruments"] = instruments
            }
            compactMarket["decisionContext"] = decisionContext
            let bytes = try JSONSerialization.data(withJSONObject: ["market": compactMarket, "at": now,
                "investorProfile": InvestorProfileEngine.onlineSummary(
                    portfolio.data.dynamicInvestorProfile, existingSettings: portfolio.data.investmentProfile),
                "futureFunding": ["monthlyYuan": monthly, "months": months], "question": question,
                "conversation": Array(conversation.suffix(8))], options: [.sortedKeys])
            let prompt = "你是观盘 Pro 私人投资研究顾问。只研究用户当前真实 ETF/股票持仓与现金。必须以输入中的唯一 decisionContext 为手机离线规则基线。只用本请求同一份持仓、行情、NAS统计、新闻和投资者画像；不得编造新闻、数据、成交或具体价格，也不得改变已有策略。仅返回纯 JSON，不加 Markdown：{\"explanations\":[{\"symbol\":\"持仓代码\",\"action\":\"原 decisionContext 中逐字相同的 action\",\"text\":\"依据和变化解释，不新增价格或相反交易建议\",\"risks\":\"主要风险\"}]}。任何标的数据不足时明确说数据不足。\n" + String(decoding: bytes, as: UTF8.self)
            let reply = try await AIAnalysisService.chat(config: portfolio.data.aiAnalysisConfig, prompt: prompt)
            let checked = validateOnlineExplanation(reply, decisionContext: decisionContext)
            onlineReply = checked
            dialogue.append("你：\(question)\n在线补充解释：\(checked)", scope: replyScope)
        } catch { onlineReply = error.localizedDescription }
    }
    private func validateOnlineExplanation(_ reply: String, decisionContext: [String: Any]) -> String {
        guard let bytes = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let explanations = object["explanations"] as? [[String: Any]],
              !explanations.isEmpty, explanations.count <= 30 else {
            return "在线分析未通过统一指导格式校验，沿用上方本机结论。"
        }
        let decisions = decisionContext["decisions"] as? [[String: Any]] ?? []
        let allowed = Dictionary(uniqueKeysWithValues: decisions.compactMap { row -> (String, String)? in
            guard let symbol = row["symbol"] as? String,
                  let action = row["action"] as? String else { return nil }
            return (symbol, action)
        })
        var seen = Set<String>()
        var lines: [String] = []
        for item in explanations {
            guard let symbol = item["symbol"] as? String,
                  let action = item["action"] as? String,
                  let content = item["text"] as? String,
                  let risks = item["risks"] as? String,
                  allowed[symbol] == action, seen.insert(symbol).inserted,
                  (1...600).contains(content.count), risks.count <= 400,
                  content.range(of: #"(?:¥|@)\s*[0-9]"#, options: .regularExpression) == nil else {
                return "在线分析与统一决策不一致或包含未经核验的价格，沿用上方本机结论。"
            }
            lines.append("\(symbol) · \(action)：\(content)\n风险：\(risks)")
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct AdvisorFillCandidate: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
    let decisionID: UUID
    let decisionCreatedAt: Date
    let planType: String
}

private struct AdvisorActualFillView: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let candidate: AdvisorFillCandidate
    @State private var side: LedgerEntry.Side = .sell
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = "0.10"
    @State private var tradeAt = Date.now
    @State private var checkedBrokerReport = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("券商真实成交 · \(candidate.name)") {
                    Text("仅在券商已经成交后填写实际回报。此操作会修改真实持仓、成本、现金和流水；AI候选价格不会自动成交。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("成交方向", selection: $side) {
                        Text("买入").tag(LedgerEntry.Side.buy)
                        Text("卖出").tag(LedgerEntry.Side.sell)
                    }
                    TextField("实际成交份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("券商实际成交价", text: $price).keyboardType(.decimalPad)
                    TextField("实际手续费", text: $fee).keyboardType(.decimalPad)
                    DatePicker("实际成交时间", selection: $tradeAt,
                        displayedComponents: [.date, .hourAndMinute])
                    Toggle("我已核对券商真实成交回报", isOn: $checkedBrokerReport)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("我已成交")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认入账") { save() }.disabled(!checkedBrokerReport)
                }
            }
            .onAppear { side = candidate.planType == "positiveT" ? .buy : .sell }
        }
    }
    private func save() {
        guard checkedBrokerReport, let shares = Double(quantity), let actualPrice = Double(price),
              let actualFee = Double(fee), shares > 0, actualPrice > 0, actualFee >= 0,
              tradeAt >= candidate.decisionCreatedAt,
              tradeAt <= Date.now.addingTimeInterval(120) else {
            error = "请按券商回报填写有效份额、成交价和手续费。"; return
        }
        do {
            try portfolio.recordTrade(code: candidate.symbol, kind: .etf, side: side,
                quantity: shares, price: actualPrice, fee: actualFee,
                linkedCash: true, date: tradeAt, advisorDecisionID: candidate.decisionID)
            Task { await portfolio.refreshQuotesAndWait() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
