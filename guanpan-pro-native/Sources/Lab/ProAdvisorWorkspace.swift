import SwiftUI

struct ProAdvisorWorkspace: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @StateObject private var dialogue = ResearchConversationStore()
    @State private var question = ""
    @State private var virtual = false
    @State private var online = false
    @State private var sending = false
    @State private var error = ""
    @State private var planning = false
    @FocusState private var composing: Bool
    @AppStorage("guanpan.research.monthlyCNY") private var monthly = ""
    @AppStorage("guanpan.research.planMonths") private var months = "12"
    private var scope: String { virtual ? "virtual:" + (lab.state?["id"] as? String ?? "none") : "real" }
    private var turns: [String] { dialogue.histories[scope] ?? [] }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    context
                    if turns.isEmpty { introduction }
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        VStack(alignment: .leading, spacing: 12) {
                            if let split = turn.firstIndex(of: "\n") {
                                Text(String(turn[..<split])).scaledFont(15, weight: .semibold).frame(maxWidth: .infinity, alignment: .trailing)
                                Text(String(turn[turn.index(after: split)...])).scaledFont(17).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).proSurface(tone: Color(red: 0.08, green: 0.56, blue: 0.48))
                            } else { Text(turn).textSelection(.enabled) }
                        }.id(index)
                    }
                    if sending { Label("正在结合账户研究…", systemImage: "ellipsis.bubble").font(.subheadline).foregroundStyle(.secondary) }
                    if !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(.red) }
                    if !dialogue.errorMessage.isEmpty { Text(dialogue.errorMessage).font(.caption).foregroundStyle(.red) }
                    Color.clear.frame(height: 1).id("bottom")
                }.frame(maxWidth: 900, alignment: .leading).padding(22).frame(maxWidth: .infinity)
            }
            .background(ProStyle.background)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("私人投资顾问").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("资金计划", systemImage: "calendar.badge.plus") { planning = true } } }
            .sheet(isPresented: $planning) { planningSheet }
            .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
    private var context: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(virtual ? "独立虚拟实验" : "本机最新真实资产", systemImage: virtual ? "flask" : "briefcase").font(.subheadline.weight(.medium))
                Spacer()
                Menu {
                    Button("真实资产研究") { virtual = false }
                    Button("虚拟实验研究") { virtual = true }.disabled(lab.state == nil)
                } label: { Text("切换").font(.caption) }.disabled(sending)
            }
            Text((monthly.isEmpty ? "未来资金尚未设置" : "每月计划 \(monthly) 元 · \(months) 个月") + " · " + (online ? "已配置在线模型" : "离线规则研究"))
                .font(.caption).foregroundStyle(.secondary)
            Text("研究不会执行真实交易。虚拟账户与真实资产的对话分别保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("先把你的想法说清楚").scaledFont(28, weight: .semibold)
            Text("愿意等更低价格，现金暂时不足，或想重新安排长期仓位，都可以从这里开始。")
                .font(.body).foregroundStyle(.secondary).lineSpacing(6)
            ForEach(["新增资金怎么分阶段投入？", "先帮我检查组合风险", "红利配置需要哪些证据？"], id: \.self) { text in
                Button { question = text } label: { HStack { Text(text); Spacer(); Image(systemName: "arrow.up.left") }.font(.subheadline).padding(.vertical, 10) }
            }
            NavigationLink("查看并调整长期目标") { ProAllocationWorkspace() }.font(.subheadline)
        }.padding(.vertical, 20)
    }
    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("说说你的目标、顾虑或资金安排", text: $question, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain).focused($composing).accessibilityIdentifier("advisor.question")
                Button { Task { await send() } } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 40, height: 40).background(Color.accentColor, in: Circle()).foregroundStyle(.white) }
                    .disabled(sending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送研究问题").accessibilityIdentifier("advisor.send")
            }
            HStack {
                Toggle("使用已配置在线模型", isOn: $online).font(.caption).disabled(sending || !AIAnalysisService.hasSavedAPIKey)
                Spacer()
                if !turns.isEmpty { ShareLink(item: turns.joined(separator: "\n\n")) { Image(systemName: "square.and.arrow.up") } }
            }
        }.padding(.horizontal, 22).padding(.vertical, 14).background(ProStyle.surface).overlay(alignment: .top) { Rectangle().fill(ProStyle.line).frame(height: 0.5) }
    }
    private var planningSheet: some View {
        NavigationStack {
            Form {
                Section("未来资金，仅用于研究") {
                    TextField("每月可投入金额（元）", text: $monthly).keyboardType(.decimalPad)
                    TextField("计划月数", text: $months).keyboardType(.numberPad)
                    Text("这里只描述未来计划，不会增加真实现金或自动创建虚拟入金。").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("资金安排").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { planning = false } } }
        }.presentationDetents([.medium, .large])
    }
    @MainActor private func send() async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty else { return }
        composing = false
        sending = true; error = ""; defer { sending = false }
        let savedScope = scope
        do {
            guard let amount = monthly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(monthly), amount.isFinite, amount >= 0, let count = Int(months), (0...600).contains(count) else { throw InvestmentLabStore.LabError.message("请先检查资金计划中的金额和月数") }
            let at = Int64(Date().timeIntervalSince1970 * 1000)
            let input = try ResearchInputBuilder.make(portfolio: portfolio, lab: lab, channels: channels, at: at, useVirtual: virtual)
            let future: [String: Any] = ["monthly": try InvestmentLabStore.units(amount), "months": count]
            let reply: String
            if online {
                let payload: [String: Any] = ["at": at, "accountScope": savedScope, "state": input.state, "market": input.data, "futureFunding": future, "question": text, "conversation": Array(turns.suffix(8))]
                let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                reply = try await AIAnalysisService.chat(config: portfolio.data.aiAnalysisConfig, prompt: "你是观盘Pro的私人投资研究顾问。结合当前账户与对话回答本轮问题。明确区分事实、推断与缺失证据；现金不足仍研究未来资金。用户偏好等待较低限价。建议具体但不编造数据或盈利保证，不执行真实交易。给出理由、风险和下一步，由用户确认长期目标。\n" + String(decoding: bytes, as: UTF8.self))
            } else {
                let result = try lab.call("research.advisor", [input.state, input.data, at, text, future]) as? [String: Any]
                reply = "离线规则顾问：\n" + (result?["text"] as? String ?? "当前证据不足，请补充持仓或行情。")
            }
            dialogue.append("你：\(text)\n\(reply)", scope: savedScope)
            if question == text { question = "" }
        } catch { self.error = error.localizedDescription }
    }
}

