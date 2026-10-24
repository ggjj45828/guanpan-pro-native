import SwiftUI

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
                Text(advice).font(.system(size: 12)).foregroundStyle(p.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
            if plan.state.isOpen {
                HStack(spacing: 8) {
                    Button("我已成交") { showFill = true }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.forest)
                    Button("取消计划") { cancel() }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                    Spacer(minLength: 4)
                    // 一键反馈：不是问卷，只让 AI 知道「这类机会适不适合我」。
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
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.6)).frame(height: 0.5) }
        .sheet(isPresented: $showFill) {
            AIFillSheet(plan: plan, code: plan.code, name: plan.name, side: plan.kind.side,
                        suggestedPrice: plan.limitPrice, suggestedUnits: plan.units)
        }
        .onAppear { model.markPlanViewed(plan.id) }
    }

    private var stateTone: Color {
        switch plan.state {
        case .active: return p.forest
        case .triggered: return p.chartGold
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
                    HStack(spacing: 6) {
                        Text(tier.side == "buy" ? "买" : "卖").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tier.side == "buy" ? p.forest : p.risk)
                        Text("¥\(NextMoney.text(tier.price, digits: 3))").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(p.ink)
                        Spacer()
                        Text("\(tier.units) 份").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(p.muted)
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
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("券商实际成交") {
                    TextField("成交价（元）", text: $priceText).keyboardType(.decimalPad)
                    TextField("成交份额", text: $unitsText).keyboardType(.numberPad)
                    TextField("手续费（元）", text: $feeText).keyboardType(.decimalPad)
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
                try model.confirmCandidatePlan(plan.id, price: price, units: units, fee: fee)
            } else {
                try model.recordTrade(code: code, name: name, side: side, units: units, price: price, fee: fee)
                Task { await model.refreshGuidance() }
            }
            dismiss()
        } catch { submitError = error.localizedDescription }
    }
}
