import SwiftUI

struct LabResearchView: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @State private var question = "愿意等更低价格，如何安排未来资金？"
    @State private var monthly = ""
    @State private var months = "12"
    @State private var response = ""
    @StateObject private var dialogue = ResearchConversationStore()
    @State private var useVirtual = false
    @State private var researchText = ""
    @State private var onlineBusy = false
    @State private var onlineReply = ""
    @State private var proposalText = ""
    @State private var proposalHash = ""
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var conversationScope: String { useVirtual ? "virtual:" + (lab.state?["id"] as? String ?? "none") : "real" }
    private var conversation: [String] { dialogue.histories[conversationScope] ?? [] }
    var body: some View {
        List {
            Section("私人研究 · 本机可解释规则") {
                Text("此页为离线规则顾问与多因子研究，不伪装成大语言模型。现金不足不会停止研究。在线模型入口继续使用原配置，由你主动发起。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("研究问题与偏好", text: $question, axis: .vertical)
                Toggle("研究独立虚拟账户", isOn: $useVirtual).disabled(lab.state == nil)
                Text(useVirtual ? "当前使用虚拟实验账户；不会修改真实资产。" : "当前使用本机最新真实 ETF/股票资产的临时研究副本。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("每月未来可投入金额（元）", text: $monthly).keyboardType(.decimalPad)
                TextField("规划月数", text: $months).keyboardType(.numberPad)
                Button("结合账户和未来资金研究") { advise() }
                if !response.isEmpty { Text(response).textSelection(.enabled) }
                Button(onlineBusy ? "正在请求已配置模型…" : "向已配置在线模型追问") { Task { await askOnline(proposal: false) } }
                    .disabled(onlineBusy || !AIAnalysisService.hasSavedAPIKey)
                Text("在线研究沿用原模型与钥匙串配置，点击后发送本页研究摘要与对话。没有密钥时仍可使用离线研究。")
                    .font(.caption).foregroundStyle(.secondary)
                if !onlineReply.isEmpty { Text(onlineReply).textSelection(.enabled) }
            }
            Section("对话与规则记忆") {
                if !dialogue.errorMessage.isEmpty { Text(dialogue.errorMessage).foregroundStyle(.red) }
                ForEach(Array(conversation.enumerated()), id: \.offset) { row in Text(row.element).font(.caption) }
                Button("将当前偏好记入独立实验") {
                    lab.action(["type": "memory", "id": UUID().uuidString, "at": now, "text": question])
                }.disabled(lab.state == nil)
                Text("记忆保存在虚拟实验通道；不会作为真实交易指令。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("A–G 策略与风险研究") {
                Button("扫描当前已提供的证券数据") { scan() }
                if !researchText.isEmpty { Text(researchText).font(.caption).textSelection(.enabled) }
                Text("雷达只报告实际提供数据的覆盖范围。红利、估值或盘口缺失时，明确显示缺证据，不编造因子或成交。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("在线模型 · G 虚拟提案") {
                Button("请求模型生成 G 模拟限价提案") { Task { await askOnline(proposal: true) } }
                    .disabled(onlineBusy || lab.state == nil || !AIAnalysisService.hasSavedAPIKey)
                if !proposalText.isEmpty {
                    Text("提案已收到，尚未创建虚拟订单；核验标的、证据、仓位和资金后才能写入。")
                    Button("核验并写入 G 虚拟挂单") { approveProposal() }
                }
                Text("这里只能写入独立虚拟账户。模型不能越过原始持仓保护、资金和组合风险限制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(.clear).navigationTitle("投资研究与资金安排")
    }
    private func inputs(forceVirtual: Bool = false) throws -> (state: [String: Any], data: [String: Any]) {
        try ResearchInputBuilder.make(portfolio: portfolio, lab: lab, channels: channels, at: now, useVirtual: useVirtual, forceVirtual: forceVirtual)
    }
    private func advise() {
        do {
            guard let value = monthly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : Double(monthly), let count = Int(months) else { throw InvestmentLabStore.LabError.message("请检查未来资金计划") }
            let input = try inputs()
            let result = try lab.call("research.advisor", [input.state, input.data, now, question, ["monthly": try InvestmentLabStore.units(value), "months": count]]) as? [String: Any]
            response = result?["text"] as? String ?? "暂无研究结果"
            dialogue.append("你：\(question)\n离线顾问：\(response)", scope: conversationScope)
        } catch { response = error.localizedDescription }
    }
    private func scan() {
        do {
            let input = try inputs(forceVirtual: lab.state != nil)
            var sections: [String] = []
            for code in ["A", "B", "C", "D", "E", "F", "G"] {
                let result = try lab.call("research.research", [input.state, code, input.data, now]) as? [String: Any] ?? [:]
                let decisions = result["decisions"] as? [[String: Any]] ?? []
                let warnings = result["warnings"] as? [String] ?? []
                var lines = ["策略 \(code)"]
                if decisions.isEmpty { lines.append("本轮没有满足条件的新交易计划") }
                for d in decisions {
                    let side = d["side"] as? String == "buy" ? "研究买入" : "研究减仓"
                    let confidence = (d["confidence"] as? NSNumber)?.doubleValue ?? 0
                    let price = ((d["referencePrice"] as? NSNumber)?.doubleValue ?? 0) / 10000
                    lines.append("\(d["symbol"] as? String ?? "") · \(side) \(d["quantity"] as? Int ?? 0) 股 · 参考价 \(price.num(3))")
                    lines.append("证据完整度 \(Int(confidence * 100))%，不代表盈利概率；分档限价、到期复核。")
                    let sources = d["evidenceIDs"] as? [String] ?? []
                    if !sources.isEmpty { lines.append("依据：" + sources.joined(separator: "、")) }
                }
                lines.append(contentsOf: warnings)
                sections.append(lines.joined(separator: "\n"))
            }
            researchText = sections.joined(separator: "\n\n")
        } catch { researchText = error.localizedDescription }
    }
    private func askOnline(proposal: Bool) async {
        guard !onlineBusy else { return }; onlineBusy = true; defer { onlineBusy = false }
        do {
            let input = try inputs(forceVirtual: proposal)
            let replyScope = conversationScope
            if proposal { guard let state = lab.state else { return }; proposalHash = try lab.digest(state) }
            let bytes = try JSONSerialization.data(withJSONObject: ["state": input.state, "market": input.data, "at": now,
                "futureFunding": ["monthlyYuan": monthly, "months": months], "question": question,
                "conversation": Array(conversation.suffix(8))], options: [.sortedKeys])
            var prompt = "你是观盘 Pro 私人投资研究顾问。只研究 ETF/股票。现金不足也要研究长期目标和未来资金。用户愿意等待较低限价。不得编造证据或执行真实交易。区分事实、推断和缺失数据，允许对话澄清并由用户确认目标。\n" + String(decoding: bytes, as: UTF8.self)
            if proposal {
                prompt += "\n只返回 JSON：{\"schemaVersion\":1,\"model\":\"当前配置模型\",\"decisions\":[{\"symbol\":\"已登记代码\",\"side\":\"buy或sell\",\"quantity\":100,\"limit\":10000,\"expiresAt\":0,\"evidenceIDs\":[\"输入中实际证据ID\"],\"reason\":\"依据与失效条件\"}]}。金额/价格为1/10000元整数，expiresAt为未来UTC毫秒，不超过30天。不得引用未提供证据，数据不充分时 decisions=[]。只对独立G虚拟账户给出提案。"
            }
            let reply = try await AIAnalysisService.chat(config: portfolio.data.aiAnalysisConfig, prompt: prompt)
            if proposal { proposalText = reply; onlineReply = "模型提案已收到，等待本机核验。" }
            else { onlineReply = reply; dialogue.append("你：\(question)\n在线模型：\(reply)", scope: replyScope) }
        } catch { onlineReply = error.localizedDescription }
    }
    private func approveProposal() {
        do {
            guard let state = lab.state, proposalHash == (try lab.digest(state)) else {
                throw InvestmentLabStore.LabError.message("实验已变化，请重新研究，未写入任何订单")
            }
            let input = try inputs(forceVirtual: true)
            let result = try lab.call("research.reviewModel", [state, input.data, proposalText, now]) as? [String: Any] ?? [:]
            guard let next = result["state"] as? [String: Any] else { return }
            let accepted = result["accepted"] as? [Any] ?? [], rejected = result["rejected"] as? [[String: Any]] ?? []
            if !accepted.isEmpty { try lab.acceptRemote(next) }
            onlineReply = "已写入 G 虚拟挂单 \(accepted.count) 笔；拒绝 \(rejected.count) 笔。\n" + rejected.compactMap { $0["reason"] as? String }.joined(separator: "\n")
            proposalText = ""
        } catch { onlineReply = error.localizedDescription }
    }
}
