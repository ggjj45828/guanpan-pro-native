import SwiftUI

/// 嵌套类型的文件内别名：本工程的静态符号核对脚本不解析嵌套类型构造，
/// 用 `QuXianChaoGe.BInput(...)` 会被误报成「QuXianChaoGe 没有静态成员 BInput」。
/// 别名同时让这一页读起来短一些。
private typealias QXCGBInput = QuXianChaoGe.BInput
private typealias QXCGTransition = QuXianChaoGe.PositionTransition
private typealias NASIndexBar = GuanpanMaxNAS.IndexDailyBar
private typealias QXCGBResult = QuXianChaoGe.BConditionResult

/// 曲线超哥 · 独立模块。
///
/// 这一页只做四件事：
///   1. 把方法知识库（16 章）按五级归因摆出来，让人能查、能引用；
///   2. 用真实指数归档日 K 检查 B（四指数连续 3 日不创新低），A 由你录入口径与成交额后比较；
///   3. 三个买点作为参考卡（不是信号）；
///   4. 仓位状态机的本机记录，每次转移要写清条件、证据、风险预算与失效线。
///
/// 明确不做：不输出买卖信号、不做评分/排名/评级、不自动交易、不把软件口径归因作者。
struct QuXianChaoGeView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    /// 由工具页 push 时为 true：不自建导航栈，用外层返回。
    var embedded: Bool = false

    // B 条件
    @State private var bResult: QuXianChaoGe.BConditionResult?
    @State private var checkingB = false
    @State private var bFailureNote = ""

    // A 条件
    @State private var caliber: QuXianChaoGe.ACaliber = .total2000
    @State private var caliberChosen = false
    @State private var todayTurnoverText = ""
    @State private var previousTurnoverText = ""

    // 仓位状态机
    @State private var currentState: QuXianChaoGe.PositionState = .observe
    @State private var journal: [QuXianChaoGe.PositionTransition] = []
    @State private var pendingTarget: QuXianChaoGe.PositionState?
    @State private var transitionCondition = ""
    @State private var transitionEvidence = ""
    @State private var transitionRisk = ""
    @State private var transitionInvalidation = ""

    @State private var expandedBuyPoint: Int?
    @State private var showAllDiscipline = false

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var palette: DsPalette { DsPalette.of(store.resolvedAppearance) }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                guidanceSection
                conditionSection
                buyPointSection
                positionSection
                knowledgeSection
                disciplineSection
            }
            .scrollContentBackground(.hidden)
            .appListLayout()
            .background(.clear)
            .navigationTitle("曲线超哥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !embedded { Button("关闭") { dismiss() } }
                }
            }
            .onAppear(perform: reloadJournal)
            // 主动检查：进页面就把 B 算出来，不用先点按钮。
            .task {
                if bResult == nil { await runBCheck() }
            }
    }

    // MARK: - 主动指导

    /// B 还没算出来时也要能渲染结论卡，所以给一个显式的「未算」结果，而不是 Optional 到处判空。
    private var bForBrief: QuXianChaoGe.BConditionResult {
        bResult ?? QXCGBResult(readings: [],
                               verdict: .unknown,
                               asOfSession: nil,
                               window: 20,
                               required: 3,
                               definitionNote: "")
    }

    private var brief: QuXianChaoGe.Brief {
        QuXianChaoGe.brief(b: bForBrief,
                           a: aEvaluation,
                           state: currentState,
                           holdingCount: store.data.holdings.count)
    }

    private var guidanceSection: some View {
        let brief = self.brief
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(brief.headline)
                        .scaledFont(palette.fsTitle, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Spacer()
                    if checkingB {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(brief.summary)
                    .scaledFont(palette.fsRow)
                    .foregroundStyle(palette.ink2)
                Text(brief.asOf.map { "指数数据截至 \($0)" } ?? "指数数据未取到")
                    .font(.caption2)
                    .foregroundStyle(palette.ink3)
            }
            ForEach(brief.items) { item in
                guidanceRow(item)
            }
            Button {
                Task { await runBCheck() }
            } label: {
                Label("重新判定", systemImage: "arrow.triangle.2.circlepath")
                    .scaledFont(palette.fsRow)
            }
            .disabled(checkingB)
        } header: {
            Text("现在该怎么做")
        } footer: {
            Text("这是按方法条件算出的结论，不是买卖信号。软件只回答「能不能加仓、下一步做什么」，不替你下单，也不给评分排名。")
                .font(.footnote)
                .foregroundStyle(palette.ink3)
        }
        .toneCard(toneColor(brief.verdict), isLight: isLight)
    }

    private func toneColor(_ verdict: QuXianChaoGe.ABVerdict) -> Color {
        switch verdict {
        case .atLeastOneSatisfied: return CardTone.ok
        case .noneSatisfied: return PnLColor.down
        case .unknown: return CardTone.warn
        }
    }

    private func guidanceRow(_ item: QuXianChaoGe.Guidance) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(guidanceToneColor(item.tone))
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.headline)
                    .scaledFont(palette.fsRow, weight: .medium)
                    .foregroundStyle(palette.ink)
                if !item.why.isEmpty {
                    Text(item.why)
                        .font(.caption)
                        .foregroundStyle(palette.ink2)
                }
                if !item.todo.isEmpty {
                    Text("下一步：" + item.todo)
                        .font(.caption)
                        .foregroundStyle(palette.ink3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func guidanceToneColor(_ tone: QuXianChaoGe.Guidance.Tone) -> Color {
        switch tone {
        case .act: return CardTone.ok
        case .caution: return CardTone.warn
        case .block: return PnLColor.down
        case .note: return palette.ink3
        }
    }

    // MARK: - 说明

    private var introSection: some View {
        Section {
            Text("把「市场环境 → A/B 加仓条件 → 三个买点 → 仓位状态」分开记录。条件成立不等于上涨，市场级条件也不等于任意标的买点。")
                .scaledFont(palette.fsRow)
                .foregroundStyle(palette.ink)
            Text("本模块只解释方法、检索证据、形成条件计划；不输出买卖信号，不做评分与排名，不自动交易。所有「作者方法」与「软件量化建议」逐条分开标注。")
                .font(.footnote)
                .foregroundStyle(palette.ink2)
        } header: {
            Text("这个模块是什么")
        }
        .plainCard(isLight: isLight)
    }

    // MARK: - A/B 条件

    private var conditionSection: some View {
        Section {
            aConditionRows
            Divider().overlay(palette.hairline)
            bConditionRows
            Divider().overlay(palette.hairline)
            combinedRow
        } header: {
            Text("A / B 加仓条件（或关系）")
        } footer: {
            Text("A：单日明显放量；B：上证、深成指、创业板、科创板四指数同时连续 3 交易日不创新低。满足其一才考虑加仓，不是必须同时满足。")
                .font(.footnote)
                .foregroundStyle(palette.ink3)
        }
        .toneCard(CardTone.warn, isLight: isLight)
    }

    @ViewBuilder
    private var aConditionRows: some View {
        Text("A · 单日明显放量")
            .scaledFont(palette.fsLabel, weight: .semibold)
            .foregroundStyle(palette.ink)
        Toggle("我已选定放量口径", isOn: $caliberChosen)
            .scaledFont(palette.fsRow)
        if caliberChosen {
            Picker("口径", selection: $caliber) {
                ForEach(QuXianChaoGe.ACaliber.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            Text(caliber.sourceNote)
                .font(.caption)
                .foregroundStyle(palette.ink3)
            HStack {
                Text("今日全市场成交额（亿元）")
                    .scaledFont(palette.fsRow)
                Spacer()
                TextField("如 8600", text: $todayTurnoverText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .textFieldStyle(.roundedBorder)
            }
            if caliber == .increase10 {
                HStack {
                    Text("前一交易日成交额（亿元）")
                        .scaledFont(palette.fsRow)
                    Spacer()
                    TextField("如 7800", text: $previousTurnoverText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        let a = aEvaluation
        HStack(spacing: 8) {
            verdictBadge(a.verdict)
            Text(a.detail)
                .font(.footnote)
                .foregroundStyle(palette.ink2)
        }
    }

    @ViewBuilder
    private var bConditionRows: some View {
        HStack {
            Text("B · 四指数连续 3 日不创新低")
                .scaledFont(palette.fsLabel, weight: .semibold)
                .foregroundStyle(palette.ink)
            Spacer()
            if checkingB {
                ProgressView().controlSize(.small)
            } else {
                verdictBadge(bEvaluationVerdict)
            }
        }
        Button {
            Task { await runBCheck() }
        } label: {
            Label("用 NAS 归档日 K 检查 B", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(checkingB)

        if let bResult {
            ForEach(bResult.readings) { reading in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(reading.displayName)
                            .scaledFont(palette.fsRow, weight: .medium)
                            .foregroundStyle(palette.ink)
                        verdictBadge(reading.verdict, compact: true)
                        Spacer()
                        Text(reading.verdict == .unknown ? "—" : "连续 \(reading.streak) 日")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(palette.ink2)
                    }
                    Text(reading.reason)
                        .font(.caption)
                        .foregroundStyle(palette.ink3)
                    Text("\(reading.roleNote)")
                        .font(.caption2)
                        .foregroundStyle(palette.ink3)
                    Text("口径：\(reading.priceBasis) · 截至 \(reading.lastSession) · 已完成 \(reading.tradingDays) 日 · 来源：\(reading.dataSource)")
                        .font(.caption2)
                        .foregroundStyle(palette.ink3)
                }
                .padding(.vertical, 2)
            }
            if let asOf = bResult.asOfSession {
                Text("数据截至 \(asOf)（只用已完成交易日；盘中不算确认）")
                    .font(.caption2)
                    .foregroundStyle(palette.ink3)
            }
            Text(bResult.definitionNote)
                .font(.caption2)
                .foregroundStyle(palette.ink3)
        } else if !bFailureNote.isEmpty {
            Text(bFailureNote)
                .font(.caption)
                .foregroundStyle(palette.ink3)
        } else {
            Text("还没检查：B 需要 NAS 的指数日 K 归档。取不到就显示「未知」，不会拿别的指数顶替。")
                .font(.caption)
                .foregroundStyle(palette.ink3)
        }
    }

    private var combinedRow: some View {
        let combined = QuXianChaoGe.combine(a: aEvaluation.verdict, b: bEvaluationVerdict)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("A OR B")
                    .scaledFont(palette.fsLabel, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text(combined.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(tone(combined))
            }
            Text(combined.detail)
                .font(.caption)
                .foregroundStyle(palette.ink2)
        }
    }

    private var aEvaluation: QuXianChaoGe.AConditionResult {
        QuXianChaoGe.evaluateA(caliber: caliberChosen ? caliber : nil,
                               todayAmountYi: Double(todayTurnoverText.trimmingCharacters(in: .whitespaces)),
                               previousAmountYi: Double(previousTurnoverText.trimmingCharacters(in: .whitespaces)))
    }

    private var bEvaluationVerdict: QuXianChaoGe.ConditionVerdict {
        bResult?.verdict ?? .unknown
    }

    // MARK: - 三个买点

    private var buyPointSection: some View {
        Section {
            ForEach(QuXianChaoGe.buyPoints) { point in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedBuyPoint == point.id },
                    set: { expandedBuyPoint = $0 ? point.id : nil }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledLine("背景", point.background)
                        labeledLine("触发", point.trigger)
                        labeledLine("失效", point.invalidation)
                        labeledLine("归因", point.evidence)
                        labeledLine("试错风险", point.risk)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text(point.title)
                        .scaledFont(palette.fsRow, weight: .medium)
                        .foregroundStyle(palette.ink)
                }
            }
        } header: {
            Text("三个买点（参考卡，不是信号）")
        } footer: {
            Text("三类独立建模：背景、触发、失效、证据、试错风险分别记录。极端家数与跌幅阈值应按具体作品保留，不擅自统一成永久规则。")
                .font(.footnote)
                .foregroundStyle(palette.ink3)
        }
        .plainCard(isLight: isLight)
    }

    private func labeledLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.ink3)
            Text(text)
                .font(.caption)
                .foregroundStyle(palette.ink2)
        }
    }

    // MARK: - 仓位状态机

    private var positionSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("当前状态")
                    .scaledFont(palette.fsRow)
                    .foregroundStyle(palette.ink2)
                Spacer()
                Text(currentState.rawValue)
                    .scaledFont(palette.fsTitle, weight: .semibold)
                    .foregroundStyle(palette.accent)
            }
            Text(currentState.guidance)
                .font(.caption)
                .foregroundStyle(palette.ink2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(currentState.allowedNext) { target in
                        Button {
                            pendingTarget = target
                            transitionCondition = ""
                            transitionEvidence = ""
                            transitionRisk = ""
                            transitionInvalidation = ""
                        } label: {
                            Text("→ \(target.rawValue)")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(palette.accentDim, in: Capsule())
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)
            }

            if let target = pendingTarget {
                transitionEditor(target: target)
            }

            if !journal.isEmpty {
                DisclosureGroup("转移记录（\(journal.count)）") {
                    ForEach(journal.reversed()) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(row.from) → \(row.to)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.ink)
                                Spacer()
                                Text(row.stamp.formatted(date: .numeric, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(palette.ink3)
                            }
                            if !row.condition.isEmpty {
                                Text("条件：\(row.condition)").font(.caption2).foregroundStyle(palette.ink2)
                            }
                            if !row.evidence.isEmpty {
                                Text("证据：\(row.evidence)").font(.caption2).foregroundStyle(palette.ink2)
                            }
                            if !row.riskBudget.isEmpty {
                                Text("风险预算：\(row.riskBudget)").font(.caption2).foregroundStyle(palette.ink2)
                            }
                            if !row.invalidation.isEmpty {
                                Text("失效线：\(row.invalidation)").font(.caption2).foregroundStyle(palette.ink2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("仓位状态机（本机记录）")
        } footer: {
            Text("观察→轻仓试探→确认→加仓→重仓确认→持有→减仓→退出。允许失败后回退，不强制逐级上行。完整状态机是整理方案，不是作者逐字制定的算法；作者没有给出统一固定仓位比例与止盈百分比。")
                .font(.footnote)
                .foregroundStyle(palette.ink3)
        }
        .plainCard(isLight: isLight)
    }

    private func transitionEditor(target: QuXianChaoGe.PositionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("转移到「\(target.rawValue)」")
                .scaledFont(palette.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            field("触发条件（必填）", text: $transitionCondition, placeholder: "如：四指数连续 3 日不创新低 + 回踩 60% 守住")
            field("证据", text: $transitionEvidence, placeholder: "来源 / 数据时刻 / 已完成或盘中")
            field("风险预算", text: $transitionRisk, placeholder: "这一笔最多认亏多少，不是仓位百分比承诺")
            field("失效线", text: $transitionInvalidation, placeholder: "什么情况算这套判断错了")
            HStack {
                Button("取消") { pendingTarget = nil }
                Spacer()
                Button("记下这次转移") { commitTransition(target: target) }
                    .disabled(transitionCondition.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.footnote.weight(.medium))
        }
        .padding(.vertical, 4)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.ink3)
            TextField(placeholder, text: text, axis: .vertical)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
    }

    private func commitTransition(target: QuXianChaoGe.PositionState) {
        let row = QXCGTransition(from: currentState.rawValue,
                                                 to: target.rawValue,
                                                 condition: transitionCondition.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 evidence: transitionEvidence.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 riskBudget: transitionRisk.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 invalidation: transitionInvalidation.trimmingCharacters(in: .whitespacesAndNewlines))
        QuXianChaoGe.PositionJournal.append(row)
        pendingTarget = nil
        reloadJournal()
    }

    private func reloadJournal() {
        journal = QuXianChaoGe.PositionJournal.load()
        currentState = QuXianChaoGe.PositionJournal.currentState()
    }

    // MARK: - 知识库

    private var knowledgeSection: some View {
        Section {
            ForEach(QuXianChaoGe.chapters) { chapter in
                NavigationLink {
                    QuXianChaoGeChapterView(chapter: chapter)
                        .environmentObject(store)
                } label: {
                    HStack(spacing: 8) {
                        Text("\(chapter.id)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.ink3)
                            .frame(width: 18, alignment: .trailing)
                        Text(chapter.title)
                            .scaledFont(palette.fsRow)
                            .foregroundStyle(palette.ink)
                    }
                }
            }
        } header: {
            Text("方法知识库（16 章 · 五级归因）")
        } footer: {
            Text("正文是导读，附录是可检索证据层；发生歧义时回查附录，不按常见技术分析补齐作者规则。")
                .font(.footnote)
                .foregroundStyle(palette.ink3)
        }
        .plainCard(isLight: isLight)
    }

    // MARK: - 纪律

    private var disciplineSection: some View {
        Section {
            ForEach(Array(QuXianChaoGe.forbiddenMisattributions.enumerated()), id: \.offset) { item in
                Text("· \(item.element)")
                    .font(.caption)
                    .foregroundStyle(palette.ink2)
            }
            if showAllDiscipline {
                ForEach(Array(QuXianChaoGe.antiLookAheadRules.enumerated()), id: \.offset) { item in
                    Text("· \(item.element)")
                        .font(.caption)
                        .foregroundStyle(palette.ink2)
                }
                Text("尚未确认的口径")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 4)
                ForEach(Array(QuXianChaoGe.unresolvedItems.enumerated()), id: \.offset) { item in
                    Text("· \(item.element)")
                        .font(.caption)
                        .foregroundStyle(palette.ink2)
                }
                Text("历史验证（对话转述，非本次重算）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 4)
                ForEach(QuXianChaoGe.historicalValidation) { stat in
                    HStack {
                        Text(stat.label).font(.caption).foregroundStyle(palette.ink2)
                        Spacer()
                        Text(stat.value).font(.caption.monospacedDigit()).foregroundStyle(palette.ink)
                    }
                }
                Text(QuXianChaoGe.historicalValidationNote)
                    .font(.caption2)
                    .foregroundStyle(palette.ink3)
            }
            Button(showAllDiscipline ? "收起纪律与未确认清单" : "展开纪律与未确认清单") {
                withAnimation(.easeInOut(duration: 0.2)) { showAllDiscipline.toggle() }
            }
            .font(.footnote.weight(.medium))
        } header: {
            Text("禁止误归因")
        }
        .plainCard(isLight: isLight)
    }

    // MARK: - 结果徽标

    private func verdictBadge(_ verdict: QuXianChaoGe.ConditionVerdict, compact: Bool = false) -> some View {
        Text(verdict.rawValue)
            .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
            .foregroundStyle(tone(verdict))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone(verdict).opacity(isLight ? 0.12 : 0.20)))
    }

    private func tone(_ verdict: QuXianChaoGe.ConditionVerdict) -> Color {
        switch verdict {
        case .satisfied: return CardTone.ok
        case .unsatisfied: return palette.ink2
        case .unknown: return CardTone.warn
        }
    }

    private func tone(_ verdict: QuXianChaoGe.ABVerdict) -> Color {
        switch verdict {
        case .atLeastOneSatisfied: return CardTone.ok
        case .noneSatisfied: return palette.ink2
        case .unknown: return CardTone.warn
        }
    }

    // MARK: - B 检查

    @MainActor private func runBCheck() async {
        checkingB = true
        bFailureNote = ""
        defer { checkingB = false }
        // 先试 NAS 归档（主力来源）；NAS 没有这个指数（例如科创 50 未收录）时，
        // 用本机日线兜底 —— 但来源会逐项标注，绝不把两个来源混成一个数字。
        var inputs: [QXCGBInput] = []
        for requirement in QuXianChaoGe.bRequirements {
            if let bars = try? await GuanpanMaxNAS.indexDailyBars(indexCode: requirement.indexCode),
               !bars.isEmpty {
                inputs.append(QXCGBInput(requirement: requirement, bars: bars,
                                         failure: nil, dataSource: "NAS 归档日 K"))
                continue
            }
            if let local = try? await store.fetchDailyBars(code: requirement.indexCode, count: 260),
               !local.isEmpty {
                let converted = local.map {
                    NASIndexBar(tradingDate: $0.date,
                                close: $0.close,
                                open: $0.open,
                                high: $0.high,
                                low: $0.low,
                                volume: $0.volume)
                }
                inputs.append(QXCGBInput(requirement: requirement, bars: converted,
                                         failure: nil, dataSource: "本机日线（腾讯，NAS 未收录该指数时兜底）"))
                continue
            }
            let nasHint = GuanpanMaxNAS.isConfigured ? "NAS 未收录该指数" : "未配置 NAS"
            inputs.append(QXCGBInput(requirement: requirement, bars: nil,
                                     failure: "取不到日 K：\(nasHint)，本机日线也拉取失败。B 记为未知。",
                                     dataSource: "无可用来源"))
        }
        bResult = QuXianChaoGe.evaluateB(inputs)
        if bResult?.readings.allSatisfy({ $0.verdict == .unknown }) == true {
            bFailureNote = "四个指数都没取到日 K：B 记为未知。确认 NAS 已归档指数日线、且手机能访问行情源后再查。"
        }
    }
}

// MARK: - 章节详情

private struct QuXianChaoGeChapterView: View {
    let chapter: QuXianChaoGe.Chapter
    @EnvironmentObject private var store: PortfolioStore

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var palette: DsPalette { DsPalette.of(store.resolvedAppearance) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(chapter.paragraphs) { paragraph in
                    VStack(alignment: .leading, spacing: 5) {
                        if let attribution = paragraph.attribution {
                            Text(attribution.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(badgeTone(attribution))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(badgeTone(attribution).opacity(isLight ? 0.12 : 0.20)))
                        }
                        Text(paragraph.text)
                            .scaledFont(palette.fsRow)
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("归因说明")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.ink)
                ForEach(QuXianChaoGe.Attribution.allCases) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(badgeTone(item))
                        Text(item.explanation)
                            .font(.caption2)
                            .foregroundStyle(palette.ink3)
                    }
                }
            }
            .padding(.horizontal, palette.pageInset)
            .padding(.vertical, 14)
        }
        .background(palette.canvas.ignoresSafeArea())
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func badgeTone(_ attribution: QuXianChaoGe.Attribution) -> Color {
        switch attribution {
        case .authorMethod: return palette.accent
        case .authorCase: return CardTone.ok
        case .softwareRule: return CardTone.warn
        case .userResearch: return PnLColor.down
        case .unconfirmed: return palette.ink2
        }
    }
}
