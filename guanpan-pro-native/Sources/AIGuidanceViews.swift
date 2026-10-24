import SwiftUI

private struct AIAdviceLine: Identifiable {
    let id: Int
    let text: String
    let isBullet: Bool
}

private struct AIAdviceBlock: Identifiable {
    let id: Int
    let title: String?
    let lines: [AIAdviceLine]
}

/// Presentation-only formatter. It recognizes common Chinese/Markdown headings while
/// preserving every non-empty sentence and never changes any price or recommendation.
private enum AIAdviceFormatter {
    private static let headings = ["结论", "今日判断", "操作建议", "交易计划", "建议方案", "建议", "依据", "证据",
                                   "新闻影响", "对持仓的影响", "组合风险", "风险", "失效条件", "有效期",
                                   "置信度", "数据质量", "下一步", "后续跟踪", "等待条件", "补充说明"]

    static func parse(_ source: String) -> [AIAdviceBlock] {
        var blocks: [AIAdviceBlock] = []
        var title: String?
        var lines: [AIAdviceLine] = []
        func flush() {
            guard !lines.isEmpty else { title = nil; return }
            blocks.append(AIAdviceBlock(id: blocks.count, title: title, lines: lines))
            title = nil
            lines = []
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let (heading, remainder) = splitHeading(line) {
                flush()
                title = heading
                if !remainder.isEmpty { lines.append(makeLine(remainder, id: 0)) }
            } else {
                lines.append(makeLine(line, id: lines.count))
            }
        }
        flush()
        return blocks
    }

    private static func splitHeading(_ raw: String) -> (String, String)? {
        var line = raw
        while line.hasPrefix("#") || line.hasPrefix("**") { line.removeFirst(line.hasPrefix("**") ? 2 : 1) }
        line = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if let separator = line.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            let candidate = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            if let match = headings.first(where: { candidate == $0 || candidate.hasPrefix($0) }) {
                return (match, clean(String(line[line.index(after: separator)...])))
            }
        }
        let exact = line.trimmingCharacters(in: CharacterSet(charactersIn: " ：:"))
        return headings.contains(exact) ? (exact, "") : nil
    }

    private static func makeLine(_ raw: String, id: Int) -> AIAdviceLine {
        var value = raw.trimmingCharacters(in: .whitespaces)
        let bullet = ["•", "·", "-", "–", "—"].contains(where: { value.hasPrefix($0) })
            || value.range(of: #"^\d+[\.、)]\s*"#, options: .regularExpression) != nil
        if bullet {
            value = value.replacingOccurrences(of: #"^(?:[•·\-–—]\s*|\d+[\.、)]\s*)"#, with: "", options: .regularExpression)
        }
        return AIAdviceLine(id: id, text: clean(value), isBullet: bullet)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AIAdviceFormattedView: View {
    @Environment(\.gp) private var p
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(AIAdviceFormatter.parse(text)) { block in
                VStack(alignment: .leading, spacing: 7) {
                    if let title = block.title {
                        HStack(spacing: 6) {
                            Image(systemName: symbol(for: title)).font(.system(size: 11, weight: .bold)).foregroundStyle(tone(for: title))
                            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(p.ink)
                            Rectangle().fill(p.line.opacity(0.75)).frame(height: 1)
                        }
                    }
                    ForEach(block.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(line.isBullet ? tone(for: block.title ?? "") : p.line)
                                .frame(width: line.isBullet ? 5 : 3, height: line.isBullet ? 5 : 3).padding(.top, 6)
                            Text(line.text)
                                .font(.system(size: block.title == "结论" && line.id == 0 ? 14 : 12,
                                              weight: block.title == "结论" && line.id == 0 ? .semibold : .regular))
                                .foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(block.title == "结论" ? tone(for: "结论").opacity(0.09) : p.paperAlt.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func tone(for title: String) -> Color {
        if title.contains("风险") || title.contains("失效") { return p.risk }
        if title.contains("依据") || title.contains("证据") { return p.chartBlue }
        if title.contains("交易") || title.contains("操作") || title.contains("建议") { return p.forest }
        if title.contains("新闻") { return p.chartGold }
        return p.chartViolet
    }
    private func symbol(for title: String) -> String {
        if title.contains("风险") || title.contains("失效") { return "exclamationmark.shield.fill" }
        if title.contains("依据") || title.contains("证据") { return "checkmark.seal.fill" }
        if title.contains("交易") || title.contains("操作") || title.contains("建议") { return "arrow.left.arrow.right" }
        if title.contains("新闻") { return "newspaper.fill" }
        if title.contains("结论") { return "sparkles" }
        return "text.alignleft"
    }
}

// MARK: - AI 持仓问答

private struct AdvisorChatMessage: Identifiable {
    enum Role { case user, advisor }
    let id = UUID()
    let role: Role
    let text: String
}

/// 手机端问答始终复用统一决策上下文，NAS只作为长期研究证据源。
/// 聊天内容不写入账户账本，也不能创建或修改交易计划。
struct AIChatScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var messages: [AdvisorChatMessage] = [
        AdvisorChatMessage(role: .advisor, text: "我会结合你的真实持仓、手机行情、NAS长期研究、相关新闻和投资者画像回答。涉及交易时，我只解释已通过规则校验的候选计划；数据不足就会明确说明。")
    ]
    @State private var question = ""
    @State private var isSending = false
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool

    private let suggestions = ["今天我的持仓有值得操作的机会吗？", "哪些数据让这条计划仍然有效？", "最近的判断和上次相比有什么变化？"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        contextStatus
                        if model.book.positions.isEmpty {
                            GPCard(accent: p.chartGold) {
                                GPInlineEmpty(symbol: "person.crop.circle.badge.questionmark", text: "还没有录入真实持仓。添加持仓后，手机 AI 才能基于你的账户回答。")
                            }
                        }
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if isSending {
                            HStack(spacing: 8) {
                                ProgressView().tint(p.chartViolet)
                                Text("正在更新行情与决策上下文…").font(.caption).foregroundStyle(p.muted)
                            }.padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        if let errorText {
                            GPCard(accent: p.risk) {
                                Text(errorText).font(.caption).foregroundStyle(p.risk).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
            composer
        }
        .background(LinearGradient(colors: [p.canvas, p.forest.opacity(0.07), p.canvas],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .navigationTitle("AI 持仓问答")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.book.positions.isEmpty == false { await model.refreshGuidance() } }
    }

    private var contextStatus: some View {
        GPCard(accent: p.chartViolet) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.chartViolet)
                VStack(alignment: .leading, spacing: 4) {
                    Text("手机 AI · 统一顾问").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                    Text(contextSummary)
                        .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if messages.count == 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(suggestions, id: \.self) { item in
                            Button { question = item; inputFocused = true } label: {
                                Text(item).font(.caption2.weight(.medium)).foregroundStyle(p.forest)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(p.tint.opacity(0.75), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }

    private var contextSummary: String {
        let holdingCount = model.book.positions.filter { $0.units > 0 }.count
        let researchCount = model.nasResearch.count
        let researchSummary = researchCount == 0 ? "尚无已同步数据" : "已加载 \(researchCount) 只研究"
        return "真实持仓 \(holdingCount) 只 · NAS长期研究 \(researchSummary)"
    }

    private func messageBubble(_ message: AdvisorChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .advisor {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.chartViolet).padding(.top, 9)
            } else { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .advisor ? "AI 顾问" : "我")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
                if message.role == .advisor {
                    AIAdviceFormattedView(text: message.text)
                } else {
                    Text(message.text).font(.subheadline).foregroundStyle(p.ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .advisor ? p.paper : p.tint.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line.opacity(0.7), lineWidth: 0.7))
            if message.role == .advisor { Spacer(minLength: 20) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("询问你的真实持仓…", text: $question, axis: .vertical)
                .lineLimit(1...4).font(.subheadline).focused($inputFocused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 0.8))
                .accessibilityIdentifier("ai.chat.message")
                .onSubmit { send() }
            Button(action: send) {
                Image(systemName: isSending ? "hourglass" : "arrow.up")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(p.forestDeep, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .disabled(isSending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.book.positions.allSatisfy { $0.units <= 0 })
            .accessibilityLabel("发送问题")
            .accessibilityIdentifier("ai.chat.send")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.canvas.opacity(0.97))
        .overlay(alignment: .top) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.6) }
    }

    private func send() {
        guard !isSending else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 1200 else { errorText = "问题不能超过 1200 字。"; return }
        guard let key = DeepSeekMobile.loadKey() else {
            errorText = "请先在「我的 / 手机 AI 接口设置」保存 API Key。密钥只保存在本机钥匙串。"
            return
        }
        guard model.book.positions.contains(where: { $0.units > 0 }) else {
            errorText = "当前没有真实持仓，请先在持仓页录入账户事实。"
            return
        }
        errorText = nil
        question = ""
        inputFocused = false
        messages.append(AdvisorChatMessage(role: .user, text: text))
        isSending = true
        let recent = messages.suffix(10).map { "\($0.role == .user ? "用户" : "顾问")：\($0.text)" }.joined(separator: "\n")
        let profile = UserDefaults.standard.string(forKey: "guanpan.deepseek.profile") ?? "flash"
        Task {
            defer { isSending = false }
            do {
                let reply = try await model.askUnifiedMobileAI(question: text, recentConversation: recent,
                                                               key: key, profile: profile)
                messages.append(AdvisorChatMessage(role: .advisor, text: reply))
            } catch {
                errorText = "暂时无法完成分析：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - AI 今日指导（首页主入口）

/// 打开 App 先看到的一句话：今天有没有值得操作的机会？
/// 有就给具体计划；没有就明确说「今天不建议交易」。不做模拟账户、不生成虚拟订单。
struct AIGuidanceSection: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var selected: NextGuidanceItem?
    @State private var generating = false
    @State private var showMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.forest)
                Text("AI 今日指导").font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 6)
                Text(NextMarketClock.sessionDescription()).font(.system(size: 9, weight: .medium)).foregroundStyle(p.muted).lineLimit(1).minimumScaleFactor(0.8)
                if generating { ProgressView().controlSize(.mini) }
            }
            if let guidance = model.dailyGuidance {
                summaryCard(guidance)
                unifiedAIBlock
                ForEach(guidance.items) { item in
                    guidanceRow(item)
                }
                if guidance.items.isEmpty {
                    GPCard { GPInlineEmpty(symbol: "tray", text: "没有可扫描的持仓。先在「持仓」页录入真实份额。") }
                }
            } else {
                GPCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("今天有没有值得操作的机会？").font(.system(size: 16, weight: .semibold)).foregroundStyle(p.ink)
                        Text(model.guidanceStatus).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        GPActionButton(title: generating ? "正在扫描…" : "生成今日指导", systemImage: "sparkles") {
                            Task {
                                generating = true
                                await model.refreshGuidance()
                                generating = false
                            }
                        }.disabled(generating || model.book.positions.isEmpty)
                        Text("只读真实持仓；不创建模拟账户、不生成虚拟订单。数据不足时宁可不给挂单价。").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !model.candidatePlans.isEmpty { candidatePlansCard }
        }
        .sheet(item: $selected) { item in
            AIGuidanceDetailSheet(item: item)
        }
        .sheet(isPresented: $showMemory) {
            DecisionMemoryView().environmentObject(model)
        }
    }

    private var unifiedAIBlock: some View {
        GPCard(accent: p.chartViolet) {
            HStack {
                Text("手机 AI 最终指导").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                Spacer()
                Text("NAS只提供研究").font(.system(size: 9, weight: .medium)).foregroundStyle(p.muted)
            }
            if let status = model.unifiedAIStatus {
                Text(status).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let advice = model.unifiedAIAdvice {
                AIAdviceFormattedView(text: advice)
            }
            GPActionButton(title: model.unifiedAIIsRunning ? "正在综合分析…" : "生成唯一综合指导",
                           systemImage: "sparkles") {
                guard let key = DeepSeekMobile.loadKey() else {
                    model.unifiedAIStatus = "请先在「我的 / 手机 AI 接口设置」保存 API Key。"
                    return
                }
                let profile = UserDefaults.standard.string(forKey: "guanpan.deepseek.profile") ?? "flash"
                Task { await model.runUnifiedMobileAI(key: key, profile: profile) }
            }.disabled(model.unifiedAIIsRunning || model.book.positions.allSatisfy { $0.units <= 0 })
            Text("具体价格只能引用规则引擎通过数据门槛生成的候选计划；缺少长期数据、交易规则或新鲜行情时，AI必须说明无法可靠出价。")
                .font(.system(size: 9)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryCard(_ guidance: NextDailyGuidance) -> some View {
        let noAction = guidance.actionableItems.isEmpty
        return DataPanel(title: noAction ? "今天不建议交易" : "今天有值得关注的机会",
                         accent: noAction ? p.muted : p.forest,
                         caption: "\(guidance.items.count) 只持仓已扫描") {
            Text(guidance.summary).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !guidance.noActionSummary.isEmpty {
                Text(guidance.noActionSummary).font(.caption).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(guidance.dataState).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background((guidance.dataState.contains("可用") ? p.jade : p.chartGold).opacity(0.12), in: Capsule())
                    .foregroundStyle(guidance.dataState.contains("可用") ? p.jade : p.chartGold)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button {
                    Task { await model.refreshGuidance() }
                } label: {
                    Text(generating ? "分析中…" : "重新分析").font(.caption.weight(.semibold)).foregroundStyle(p.forest)
                }.disabled(generating)
            }
            HStack(spacing: 8) {
                Button { showMemory = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                        Text("决策记忆 \(model.decisionMemory.count)").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(p.chartBlue.opacity(0.12), in: Capsule())
                    .foregroundStyle(p.chartBlue)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text("生成于 \(guidance.generatedAt.formatted(date: .omitted, time: .shortened)) · 计划只是建议，真实成交后才会更新账本").font(.caption2).foregroundStyle(p.muted)
        }
    }

    private func guidanceRow(_ item: NextGuidanceItem) -> some View {
        Button { selected = item } label: {
            GPCard(accent: item.isActionable ? p.forest : p.line) {
                HStack(alignment: .top, spacing: 9) {
                    Text("\(item.rank)")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                        .frame(width: 20, height: 20)
                        .background((item.isActionable ? p.forest : p.muted).opacity(0.12), in: Circle())
                        .foregroundStyle(item.isActionable ? p.forest : p.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
                            Text(item.state.rawValue).font(.system(size: 9)).foregroundStyle(p.muted)
                        }
                        Text(item.headline).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.isActionable ? p.forest : p.muted).lineLimit(2)
                        if let first = item.whyToday.first {
                            Text(first).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(2)
                        }
                        if let impact = item.newsImpact, impact.action != .none {
                            HStack(spacing: 4) {
                                Image(systemName: impact.action.blocksPlan ? "exclamationmark.triangle.fill" : "newspaper")
                                    .font(.system(size: 8))
                                Text("新闻·\(impact.action.rawValue)").font(.system(size: 9, weight: .semibold))
                            }
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background((impact.action.blocksPlan ? p.risk : p.chartGold).opacity(0.12), in: Capsule())
                            .foregroundStyle(impact.action.blocksPlan ? p.risk : p.chartGold)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(item.confidence.level.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2.5)
                            .background(tone(for: item.confidence.level).opacity(0.12), in: Capsule())
                            .foregroundStyle(tone(for: item.confidence.level))
                            .lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    private var candidatePlansCard: some View {
        GPCard {
            HStack {
                Text("AI 候选计划").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                Spacer()
                Text("未成交不影响账本").font(.system(size: 9)).foregroundStyle(p.muted)
            }
            ForEach(model.candidatePlans) { plan in
                CandidatePlanRow(plan: plan)
            }
        }
    }

    private func tone(for level: NextDataConfidence.Level) -> Color {
        switch level {
        case .high: return p.jade
        case .medium: return p.chartGold
        case .low: return p.terracotta
        case .blocked: return p.risk
        }
    }
}

// MARK: - 候选计划行

struct CandidatePlanRow: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let plan: NextCandidatePlan
    @State private var showFill = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(plan.name) · \(plan.kind.rawValue)").font(.caption.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(plan.state.rawValue).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(stateTone.opacity(0.12), in: Capsule())
                    .foregroundStyle(stateTone)
            }
            Text("\(NextMoney.text(plan.limitPrice, digits: 3)) × \(plan.units) 份 · 有效至 \(plan.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(p.muted)
            if let filled = plan.confirmedUnits, filled > 0 {
                Text("券商已确认 \(filled) 份 · 剩余候选 \(plan.remainingUnits) 份 · 实际费用 ¥\(NextMoney.text(plan.confirmedFee ?? 0))")
                    .font(.caption2).foregroundStyle(p.jade).fixedSize(horizontal: false, vertical: true)
            }
            if plan.canConfirmRealFill {
                HStack(spacing: 8) {
                    Button(plan.state.isOpen ? "我已成交" : "补录实际成交") { showFill = true }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.forest)
                    if plan.state.isOpen {
                        Button("取消计划") { cancel() }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                    } else {
                        Text("仅记录券商已真实成交的份额")
                            .font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 4)
                    // 一键反馈：不是问卷，只让 AI 知道「这类机会适不适合我」。
                    if plan.state.isOpen {
                        Menu {
                            ForEach(NextPlanFeedbackKind.allCases) { kind in
                                Button {
                                    model.recordPlanFeedback(plan.id, kind: kind)
                                } label: {
                                    Label(kind.rawValue, systemImage: kind.symbol)
                                }
                            }
                        } label: {
                            Text(plan.feedback?.kind.rawValue ?? "反馈给 AI")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(plan.feedback == nil ? p.muted : p.chartViolet)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background((plan.feedback == nil ? p.line : p.chartViolet.opacity(0.14)), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.6)).frame(height: 0.5) }
        .sheet(isPresented: $showFill) {
            AIFillSheet(plan: plan, code: plan.code, name: plan.name, side: plan.kind.side,
                        suggestedPrice: plan.limitPrice, suggestedUnits: plan.remainingUnits)
        }
        .onAppear { model.markPlanViewed(plan.id) }
    }

    private var stateTone: Color {
        switch plan.state {
        case .active: return p.forest
        case .triggered: return p.chartGold
        case .partiallyConfirmed: return p.chartBlue
        case .confirmed: return p.jade
        case .expired, .invalidated, .withdrawn: return p.muted
        }
    }

    private func cancel() {
        guard let index = model.candidatePlans.firstIndex(where: { $0.id == plan.id }) else { return }
        model.candidatePlans[index].state = .withdrawn
        model.candidatePlans[index].stateChangedAt = Date()
    }
}

// MARK: - 今日指导详情

struct AIGuidanceDetailSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let item: NextGuidanceItem
    @State private var showFill = false
    @State private var saveError: String?

    private var readyTPlan: NextTPlan? {
        guard let result = item.tPlan else { return nil }
        if case let .ready(plan) = result { return plan }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if let result = item.tPlan { tPlanBlock(result) }
                    if let result = item.gridPlan { gridBlock(result) }
                    if let recovery = item.recovery { recoveryBlock(recovery) }
                    if !item.riskNotes.isEmpty { risksBlock }
                    dataBlock
                    newsBlock
                    actions
                }.padding(16)
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $showFill) {
                if let plan = readyTPlan {
                    AIFillSheet(plan: nil, code: plan.code, name: plan.name,
                                side: plan.kind == .reverse ? "sell" : "buy",
                                suggestedPrice: plan.kind == .reverse ? plan.sellPrice : plan.buyPrice,
                                suggestedUnits: plan.units)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.state.rawValue).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(p.forest.opacity(0.12), in: Capsule()).foregroundStyle(p.forest)
                Text("建议 \(item.strategy.rawValue)").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 0)
            }
            Text(item.headline).font(.system(size: 12)).foregroundStyle(p.muted)
            if let note = item.portfolioNote {
                Text(note).font(.caption).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func tPlanBlock(_ result: NextTPlannerResult) -> some View {
        switch result {
        case .ready(let plan):
            DataPanel(title: plan.kind.rawValue, accent: p.chartViolet, caption: "候选限价 · 非订单") {
                HStack(spacing: 10) {
                    GPStatTile(label: "卖出限价", value: "¥\(NextMoney.text(plan.sellPrice, digits: 3))", emphasis: p.risk)
                    GPStatTile(label: "计划买回", value: "¥\(NextMoney.text(plan.buyPrice, digits: 3))", emphasis: p.jade)
                }
                HStack(spacing: 10) {
                    GPStatTile(label: "份额", value: "\(plan.units) 份", footnote: "整手")
                    GPStatTile(label: "预计净收益", value: "¥\(NextMoney.text(plan.netGain))", footnote: "已扣两笔手续费 ¥\(NextMoney.text(plan.feeTotal))", emphasis: p.forest)
                }
                GPDataRow(title: "等效成本降低", value: "¥\(NextMoney.text(plan.costReductionPerUnit, digits: 3))/份")
                GPDataRow(title: "需扣除手续费", value: "¥\(NextMoney.text(plan.feeTotal))", note: "ETF 每笔 ¥0.10，两笔")
                Text(plan.volumeSupport).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                Text(plan.trampleRisk).font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                Text(plan.continuedDropRisk).font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                Text("有效期至 \(plan.validUntil.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(p.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("失效条件").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.ink)
                    ForEach(plan.cancelConditions, id: \.self) { line in
                        Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .notWorthwhile(let reasons):
            GPCard {
                Text("有数据，但今天不值得做").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                ForEach(reasons, id: \.self) { line in
                    Text("· \(line)").font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .insufficientData(let confidence, let reasons):
            GPCard(accent: p.risk) {
                Text("数据不足，不出挂单价").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                Text(confidence.summary).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(reasons, id: \.self) { line in
                    Text("· \(line)").font(.caption).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func gridBlock(_ result: NextGridPlannerResult) -> some View {
        switch result {
        case .ready(let plan):
            DataPanel(title: "智能网格 · \(plan.tiers.count) 档", accent: p.chartBlue, caption: "间距 \(String(format: "%.2f", plan.spacingPercent))%") {
                GPDataRow(title: "区间", value: "¥\(NextMoney.text(plan.lower, digits: 3)) – ¥\(NextMoney.text(plan.upper, digits: 3))")
                GPDataRow(title: "最大资金占用", value: "¥\(NextMoney.text(plan.maxCashUsage))")
                GPDataRow(title: "全部卖档后剩余", value: "\(plan.remainingUnitsAfterAllSells) 份")
                ForEach(plan.tiers.indices, id: \.self) { index in
                    let tier = plan.tiers[index]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tier.side == "buy" ? "买" : "卖").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(tier.side == "buy" ? p.forest : p.risk)
                            Text("¥\(NextMoney.text(tier.price, digits: 3))").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(p.ink)
                            Spacer()
                            Text("\(tier.units) 份").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(p.muted)
                        }
                        if let gain = tier.expectedNetGain {
                            Text("与最近对侧档往返，预计净收益 ¥\(NextMoney.text(gain))（已扣双边手续费）")
                                .font(.system(size: 9)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("暂无可配对档位，净收益不估算")
                                .font(.system(size: 9)).foregroundStyle(p.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("暂停条件").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.ink)
                    ForEach(plan.pauseConditions, id: \.self) { line in
                        Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .notRecommended(let reasons):
            GPCard {
                Text("不建议网格").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                ForEach(reasons, id: \.self) { line in
                    Text("· \(line)").font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .insufficientData(let confidence, let reasons):
            GPCard(accent: p.risk) {
                Text("网格数据不足").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                Text(confidence.summary).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(reasons, id: \.self) { line in
                    Text("· \(line)").font(.caption).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func recoveryBlock(_ reading: NextRecoveryReading) -> some View {
        GPCard {
            Text("回本路径").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            Text(reading.verdict).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let add = reading.addOption {
                Text("补仓：\(add.note)").font(.system(size: 10)).foregroundStyle(add.allowed ? p.muted : p.terracotta).fixedSize(horizontal: false, vertical: true)
            }
            if let reduce = reading.reduceOption {
                Text("减仓：\(reduce.note)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(reading.warnings, id: \.self) { line in
                Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var risksBlock: some View {
        GPCard {
            Text("风险与前提").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            ForEach(item.riskNotes, id: \.self) { line in
                Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dataBlock: some View {
        GPCard {
            Text("数据依据").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
            Text(item.confidence.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(item.whyToday, id: \.self) { line in
                Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let result = readyTPlan, !result.evidence.isEmpty {
                ForEach(result.evidence, id: \.self) { line in
                    Text("· \(line)").font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var newsBlock: some View {
        GPCard(accent: item.newsImpact?.action.blocksPlan == true ? p.risk : p.chartGold) {
            HStack(spacing: 6) {
                Text("相关新闻与计划影响").font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                if let impact = item.newsImpact {
                    Text(impact.action.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((impact.action.blocksPlan ? p.risk : p.chartGold).opacity(0.12), in: Capsule())
                        .foregroundStyle(impact.action.blocksPlan ? p.risk : p.chartGold)
                }
            }
            if let impact = item.newsImpact, !impact.hits.isEmpty {
                ForEach(impact.hits.prefix(4)) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("· \(hit.title)").font(.system(size: 10)).foregroundStyle(p.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(hit.severity.rawValue) · 命中 \(hit.keywords.joined(separator: "/"))\(hit.source.map { " · \($0)" } ?? "")")
                            .font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
                if item.newsImpact?.action.blocksPlan == true {
                    Text("重大事件未经你确认前，原计划已收回：不会给出新价格，也不会自动下单。")
                        .font(.system(size: 9)).foregroundStyle(p.risk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.newsStatus[item.code] ?? "没有相关新闻标题：本次结论不含新闻因素。")
                    .font(.system(size: 10)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if readyTPlan != nil {
                GPActionButton(title: "我已成交（更新真实账本）", systemImage: "checkmark.seal") { showFill = true }
            }
            GPActionButton(title: "保存为候选计划", secondary: true, systemImage: "bookmark") {
                do { try model.saveCandidatePlan(from: item); dismiss() }
                catch { saveError = error.localizedDescription }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(p.risk).fixedSize(horizontal: false, vertical: true)
            }
            Text("候选计划不会占用现金、不会生成虚拟持仓；只有你在券商真实成交并确认后才写入流水。")
                .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 真实成交录入（我已成交）

struct AIFillSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let plan: NextCandidatePlan?
    let code: String
    let name: String
    let side: String
    let suggestedPrice: Decimal
    let suggestedUnits: Int

    @State private var priceText = ""
    @State private var unitsText = ""
    @State private var feeText = "0.10"
    @State private var tradedAt = Date()
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("券商实际成交") {
                    Text(side == "sell" ? "方向：实际卖出" : "方向：实际买入")
                    if let plan {
                        Text("本计划剩余 \(plan.remainingUnits) 份；只填写本次真正成交的份额")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("成交价（元）", text: $priceText).keyboardType(.decimalPad)
                    TextField("成交份额", text: $unitsText).keyboardType(.numberPad)
                    TextField("手续费（元）", text: $feeText).keyboardType(.decimalPad)
                    DatePicker("成交时间", selection: $tradedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Text("只有券商已真实成交才填写。保存后会立刻更新真实份额、成本、现金与已实现收益，AI 随即按新账户状态重新分析。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let submitError {
                    Section { Text(submitError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(side == "sell" ? "确认卖出成交" : "确认买入成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记录成交") { submit() }.disabled(priceText.isEmpty || unitsText.isEmpty)
                }
            }
            .onAppear {
                if priceText.isEmpty { priceText = NextMoney.text(suggestedPrice, digits: 3) }
                if unitsText.isEmpty { unitsText = "\(suggestedUnits)" }
            }
        }
    }

    private func submit() {
        do {
            let price = try NextMoney.parse(priceText)
            guard let units = Int(unitsText), units > 0 else { throw NextError.invalid("成交份额必须是正整数") }
            let fee = try NextMoney.parse(feeText)
            if let plan {
                try model.confirmCandidatePlan(plan.id, price: price, units: units, fee: fee, at: tradedAt)
            } else {
                try model.recordTrade(code: code, name: name, side: side, units: units, price: price, fee: fee, at: tradedAt)
                Task { await model.refreshGuidance() }
            }
            dismiss()
        } catch { submitError = error.localizedDescription }
    }
}
