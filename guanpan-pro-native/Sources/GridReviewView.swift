import SwiftUI

/// 复盘页的两个模式。
///
/// 用户的原话是「复盘单独拎出来做大做强」——它其实在回答**两件不同的事**：
/// · `day`   当日最优：**这一天**事后最优的锚点与格距是什么（移植自网页版 `gridTradeReplayOptimize`）；
/// · `range` 长期参数：**同一组格距**在 N 个交易日里平均表现如何，这才是「以后该怎么挂单」的依据。
///
/// 默认落在 `range` 上：单日最优只能说明那一天，区间结论才有指导意义。
enum GridReviewMode: String, CaseIterable, Identifiable {
    case range = "长期参数"
    case day = "当日最优"
    var id: String { rawValue }
}

/// 「复盘」——独立的一级功能，与「分红日历」「中长期网格计划」同级。
///
/// 胜负标尺只有一条：`alpha = 网格盈亏 − 同一时点买入后什么都不做的盈亏`。
/// 单边上涨的日子随便一组参数都能赚，只有减掉「买了不动」那份，剩下的才是网格真正多挣的。
///
/// ⚠️ 两个模式都是**事后拟合**：用的是已经走完的完整分时，不是预测。
struct GridReviewView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: GridReviewMode = .range
    @State private var code = ""
    @State private var day = ""
    @State private var from = ""
    @State private var to = ""
    @State private var capital = "20000"
    @State private var t0 = true

    @State private var dayReport: GridOptimizeReport?
    @State private var rangeReport: GridRangeReport?
    @State private var message = ""
    @State private var showAllRangeCandidates = false
    @State private var showAllRangeDays = false
    @State private var experience: GridExperienceRecord?
    @State private var history: [GridRangeReport] = []

    @State private var advice = ""
    @State private var adviceBusy = false
    @State private var adviceStale = false

    /// 只有名下有分时档案的代码能选 —— 复盘这件事，输入必须是有分时数据的那几天。
    private var archivedCodes: [String] { store.intradayCodes.sorted() }
    /// 倒序（最近的在最前）。
    private var days: [String] { code.isEmpty ? [] : store.intradayDays(forCode: code) }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var hasKey: Bool { AIAnalysisService.hasSavedAPIKey }

    private func displayName(_ target: String) -> String {
        store.data.quotes.first { $0.code == target }?.name
            ?? store.data.holdings.first { $0.code == target }?.name
            ?? target
    }

    var body: some View {
        NavigationStack {
            Form {
                // 注意：Section 一律写在 Form 的 builder 里，不放进「返回 Section 的计算属性」——
                // 那个写法会让编译器去解析 Table 版 Section 重载，报
                // `TableHeaderRowContent<V, Text>` 不能当 View。本项目已经踩过一次。
                Section {
                    Picker("模式", selection: $mode) {
                        ForEach(GridReviewMode.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode == .range
                        ? "长期参数：拿一组格距，在区间内每个交易日各跑一遍（锚点固定为当日首价，真实长期网格就是每天按当时价位重铺），再看平均表现。"
                        : "当日最优：只跑这一天，自动搜出事后最优的锚点与格距（3 个锚点 × 7 个步长倍率 = 21 组）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                GridReviewInputSection(
                    mode: mode,
                    code: $code,
                    day: $day,
                    from: $from,
                    to: $to,
                    capital: $capital,
                    t0: $t0,
                    codes: archivedCodes,
                    days: days,
                    displayName: displayName,
                    isLight: isLight,
                    onQuickRange: applyQuickRange,
                    onRun: run
                )
                if !message.isEmpty {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    .plainCard(isLight: isLight)
                }
                if mode == .day, let dayReport {
                    GridReviewDayParamsSection(report: dayReport, isLight: isLight)
                    GridReviewDayCostSection(report: dayReport, isLight: isLight)
                    GridReviewDayPnlSection(report: dayReport, isLight: isLight)
                    GridReviewDayCandidatesSection(
                        report: dayReport,
                        expanded: $showAllRangeCandidates,
                        isLight: isLight
                    )
                    if let experience {
                        GridReviewExperienceSection(
                            name: displayName(code),
                            record: experience,
                            isLight: isLight
                        )
                    }
                }
                if mode == .range, let rangeReport {
                    GridRangeDiagnosisSection(report: rangeReport, isLight: isLight)
                    GridRangeWinnerSection(report: rangeReport, isLight: isLight)
                    GridRangeCandidatesSection(
                        report: rangeReport,
                        expanded: $showAllRangeCandidates,
                        isLight: isLight
                    )
                    GridRangeDetailsSection(
                        report: rangeReport,
                        expanded: $showAllRangeDays,
                        isLight: isLight
                    )
                    if !history.isEmpty {
                        GridRangeHistorySection(
                            name: displayName(code),
                            records: history,
                            isLight: isLight
                        )
                    }
                }
                Section("让大模型给建议") {
                    Button {
                        Task { await askAI() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text(adviceBusy ? "正在分析…" : "根据这次复盘给以后的挂单建议")
                                .scaledFont(14, weight: .semibold)
                            Spacer()
                        }
                    }
                    .disabled(adviceBusy || !hasReport)
                    if !hasKey {
                        Text("还没配 API 密钥。到「设置 → AI 分析」里填一个，本机已算好的回放结果会一起发过去。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !advice.isEmpty {
                        if adviceStale {
                            Text("输入变过了，下面这段是上一次复盘的结论。重新生成一次更可靠。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        Text(advice)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("发给模型的是本机算出来的回放结果（候选表、胜出参数、逐日明细、本机历史记录），"
                        + "不是原始分时；模型只做解读与取舍，不参与选参。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                GridReviewDisclaimerSection(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("复盘")
            .toolbarBackground(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .themedSheetBackground()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear(perform: prime)
            .onChange(of: code) { _, newValue in primeCode(newValue) }
            .onChange(of: mode) { _, _ in
                message = ""
                // 换了模式就当换了一次输入，之前那份 AI 结论不再对应这次的回放。
                adviceStale = !advice.isEmpty
            }
        }
    }

    private var hasReport: Bool {
        mode == .range ? rangeReport != nil : dayReport != nil
    }

    // MARK: - 输入与运行

    private func prime() {
        if code.isEmpty, let first = archivedCodes.first { code = first }
        primeCode(code)
    }

    private func primeCode(_ newValue: String) {
        let list = store.intradayDays(forCode: newValue)
        day = list.first ?? ""
        to = list.first ?? ""
        from = list.count > 20 ? list[19] : (list.last ?? "")
        dayReport = nil
        rangeReport = nil
        message = ""
        advice = ""
        adviceStale = false
        experience = store.gridExperience(forCode: newValue)
        history = store.gridRangeHistory(forCode: newValue)
    }

    /// 「最近 N 天」快选：日期用字符串（`yyyy-MM-dd` 字典序即时间序），不用 DatePicker ——
    /// 档案里本来就只有交易日，让用户对着日历点周末是白费事。
    private func applyQuickRange(_ count: Int) {
        let list = days
        guard !list.isEmpty else { return }
        to = list.first ?? ""
        if count <= 0 || list.count <= count {
            from = list.last ?? ""
        } else {
            from = list[count - 1]
        }
    }

    private func run() {
        let text = capital.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let money = Double(text) ?? 0
        advice = ""
        adviceStale = false
        switch mode {
        case .day:
            switch store.optimizeGridReplay(code: code, day: day, capital: money, t0: t0) {
            case .success(let output):
                dayReport = output
                rangeReport = nil
                message = ""
                store.recordGridExperience(output)
                experience = store.gridExperience(forCode: code)
            case .failure(let error):
                dayReport = nil
                message = error.localizedDescription
            }
        case .range:
            switch store.optimizeGridRange(code: code, from: from, to: to, capital: money, t0: t0) {
            case .success(let output):
                rangeReport = output
                dayReport = nil
                message = ""
                store.recordGridRangeHistory(output)
                history = store.gridRangeHistory(forCode: code)
            case .failure(let error):
                rangeReport = nil
                message = error.localizedDescription
            }
        }
    }

    // MARK: - AI

    @MainActor private func askAI() async {
        adviceBusy = true
        defer { adviceBusy = false }
        let prompt: String
        if mode == .range, let report = rangeReport {
            prompt = GridReviewAdvisor.rangePrompt(report: report, history: history,
                                                   profile: store.data.investmentProfile,
                                                   dividendYield: store.dividendContext(forCode: code)?.yieldPercent)
        } else if let report = dayReport {
            prompt = GridReviewAdvisor.dayPrompt(report: report,
                                                 name: displayName(report.code),
                                                 experience: experience,
                                                 profile: store.data.investmentProfile,
                                                 dividendYield: store.dividendContext(forCode: code)?.yieldPercent)
        } else {
            return
        }
        do {
            advice = try await AIAnalysisService.chat(config: store.data.aiAnalysisConfig, prompt: prompt)
            adviceStale = false
        } catch {
            advice = "分析失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 输入

private struct GridReviewInputSection: View {
    let mode: GridReviewMode
    @Binding var code: String
    @Binding var day: String
    @Binding var from: String
    @Binding var to: String
    @Binding var capital: String
    @Binding var t0: Bool
    let codes: [String]
    let days: [String]
    let displayName: (String) -> String
    let isLight: Bool
    let onQuickRange: (Int) -> Void
    let onRun: () -> Void

    var body: some View {
        Section("输入") {
            if codes.isEmpty {
                Text("分时档案里还没有标的。先在自选或 ETF 持仓里留着行情，应用在前台时会自动采集分时。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("标的", selection: $code) {
                    ForEach(codes, id: \.self) { item in
                        Text("\(displayName(item)) · \(item)").tag(item)
                    }
                }
                if days.isEmpty {
                    Text("这个标的还没有分时档案，换一个标的。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if mode == .day {
                    Picker("交易日", selection: $day) {
                        ForEach(days, id: \.self) { item in Text(item).tag(item) }
                    }
                } else {
                    Picker("起（早）", selection: $from) {
                        ForEach(days, id: \.self) { item in Text(item).tag(item) }
                    }
                    Picker("止（晚）", selection: $to) {
                        ForEach(days, id: \.self) { item in Text(item).tag(item) }
                    }
                    HStack(spacing: 6) {
                        Text("快选").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                        ForEach([5, 10, 20, 0], id: \.self) { count in
                            Button {
                                onQuickRange(count)
                            } label: {
                                Text(count == 0 ? "全部" : "最近 \(count)")
                                    .scaledFont(11)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Color(uiColor: .secondarySystemBackground).opacity(0.6),
                                        in: Capsule(style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("档案里共 \(days.count) 个交易日。区间里有效分钟点不足 30 个的日子会被跳过，少于 3 个能用的日子不会给结论。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("计划资金（元）") {
                    TextField("20000", text: $capital)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text("常用").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                    ForEach(["10000", "20000", "50000", "100000"], id: \.self) { value in
                        Button {
                            capital = value
                        } label: {
                            Text(capital == value ? "● \(value)" : value)
                                .scaledFont(11, weight: capital == value ? .semibold : .regular)
                                .monospacedDigit()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Color(uiColor: .secondarySystemBackground).opacity(0.6),
                                    in: Capsule(style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                Toggle("支持 T+0（当天买入可当天卖出）", isOn: $t0)
                Text("ETF / 债券 / 跨境品种支持 T+0；A 股股票当天买入的份额当天不能卖，关掉它更贴近真实。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .plainCard(isLight: isLight)

        Section {
            Button(action: onRun) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text(mode == .range ? "开始复盘这个区间" : "开始搜索当日最优参数")
                        .scaledFont(14, weight: .semibold)
                    Spacer()
                }
            }
            .disabled(codes.isEmpty || (mode == .day ? day.isEmpty : (from.isEmpty || to.isEmpty)))
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 单日：最优参数 / 成本 / 收益 / 候选 / 经验

private struct GridReviewDayParamsSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }

    var body: some View {
        Section("当日最优参数 · \(report.day)") {
            LabeledContent("起始锚点", value: report.best.anchor.num(digits))
            LabeledContent("每格格距", value: "\(report.best.step.num(digits))（\(report.best.stepPercent.num(2))%）")
            LabeledContent("每格股数 / 份数", value: report.best.quantity.num(0))
            LabeledContent("当日区间", value: "\(report.dayLow.num(digits)) ~ \(report.dayHigh.num(digits))")
            LabeledContent("有效分钟点", value: "\(report.points) 个")
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridReviewDayCostSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    var body: some View {
        Section("成交与成本") {
            LabeledContent("买入 / 卖出", value: "\(report.best.buyCount) 笔 / \(report.best.sellCount) 笔")
            LabeledContent("成交合计", value: "\(report.best.fills) 笔")
            LabeledContent("佣金", value: report.best.commissionCost.cny())
            LabeledContent("滑点", value: report.best.slippageCost.cny())
            LabeledContent("成本合计", value: report.best.fees.cny())
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridReviewDayPnlSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    private var alphaColor: Color { report.best.alpha >= 0 ? .red : .green }
    private var profitColor: Color { report.best.profit >= 0 ? .red : .green }

    var body: some View {
        Section("收益归因") {
            LabeledContent("期末权益", value: report.best.endingEquity.cny())
            HStack {
                Text("网格盈亏").scaledFont(13)
                Spacer()
                Text("\(report.best.profit.directionMark()) \(report.best.profit.cny())")
                    .scaledFont(13, weight: .semibold).monospacedDigit().foregroundStyle(profitColor)
            }
            LabeledContent("持有不动盈亏", value: "\(report.best.holdProfit.directionMark()) \(report.best.holdProfit.cny())")
            HStack {
                Text("跑赢持有").scaledFont(13, weight: .semibold)
                Spacer()
                Text("\(report.best.alpha.directionMark()) \(report.best.alpha.cny())")
                    .scaledFont(13, weight: .bold).monospacedDigit().foregroundStyle(alphaColor)
            }
            LabeledContent("最大回撤", value: "\(report.best.maxDrawdown.num(2))%")
            Text("「跑赢持有」= 网格盈亏 − 同一时点买入后什么都不做的盈亏。它才是这套参数的胜负依据："
                + "当天本来就是单边上涨的话，两组参数都能赚，但只有真正的高抛低吸才会把差值做正。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridReviewDayCandidatesSection: View {
    let report: GridOptimizeReport
    @Binding var expanded: Bool
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var visible: [GridOptimizeCandidate] {
        expanded ? report.candidates : Array(report.candidates.prefix(5))
    }

    var body: some View {
        Section("候选参数（共 \(report.candidates.count) 组）") {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                GridReviewDayCandidateRow(
                    item: item,
                    rank: index + 1,
                    digits: digits,
                    isBest: item.id == report.best.id
                )
            }
            Button(expanded ? "收起，只看前 5 组" : "展开全部 \(report.candidates.count) 组") {
                expanded.toggle()
            }
            Text("3 个锚点（首价 / 前 15 点均价 / 当日中位价）× 7 个步长倍率（1 / 1.25 / 1.5 / 2 / 2.5 / 3 / 4），"
                + "按「跑赢持有」从高到低排。锚点重复或落在当日区间外的组合已被去掉。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridReviewDayCandidateRow: View {
    let item: GridOptimizeCandidate
    let rank: Int
    let digits: Int
    let isBest: Bool

    private var alphaColor: Color { item.alpha >= 0 ? .red : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(isBest ? "#\(rank) 最优" : "#\(rank)")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(isBest ? Color.accentColor : .secondary)
                    .monospacedDigit()
                Text("锚 \(item.anchor.num(digits))").scaledFont(11).monospacedDigit()
                Text("格 \(item.step.num(digits))").scaledFont(11).monospacedDigit()
                Spacer()
                Text("\(item.alpha.directionMark()) \(item.alpha.cny())")
                    .scaledFont(12, weight: .semibold).monospacedDigit().foregroundStyle(alphaColor)
            }
            Text("每格 \(item.quantity.num(0)) 份 · 买 \(item.buyCount) 卖 \(item.sellCount) · "
                + "成本 \(item.fees.cny()) · 网格盈亏 \(item.profit.cny()) · 回撤 \(item.maxDrawdown.num(2))%")
                .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct GridReviewExperienceSection: View {
    let name: String
    let record: GridExperienceRecord
    let isLight: Bool

    var body: some View {
        Section("策略经验 · \(name)") {
            LabeledContent("已复盘次数", value: "\(record.samples) 次")
            LabeledContent("跑赢持有的次数", value: "\(record.wins) 次（\(record.winRate.num(1))%）")
            LabeledContent("平均跑赢金额", value: record.averageAlpha.cny())
            LabeledContent("中位格距", value: "\(record.medianStepPercent.num(2))%")
            Text("只统计这台设备上跑过的单日复盘，用来回答「这个标的过去几次事后最优的格距大概落在哪一档」。"
                + "它不参与选参，也不代表未来。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 区间：诊断 / 胜出参数 / 候选 / 逐日 / 历史

private struct GridRangeDiagnosisSection: View {
    let report: GridRangeReport
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var changeColor: Color { report.rangeChangePercent >= 0 ? .red : .green }

    var body: some View {
        Section("区间概况 · \(report.from) → \(report.to)") {
            LabeledContent("参与统计的交易日", value: "\(report.days.count) 天")
            if !report.skippedDays.isEmpty {
                LabeledContent("被跳过的日子", value: "\(report.skippedDays.count) 天（分时点不足或资金不够）")
            }
            LabeledContent("有效分钟点合计", value: "\(report.totalPoints) 个")
            LabeledContent("区间最低 / 最高", value: "\(report.rangeLow.num(digits)) ~ \(report.rangeHigh.num(digits))")
            HStack {
                Text("首日首价 → 末日末价").scaledFont(13)
                Spacer()
                Text("\(report.rangeChangePercent.directionMark()) \(report.rangeChangePercent.num(2))%")
                    .scaledFont(13, weight: .semibold).monospacedDigit().foregroundStyle(changeColor)
            }
            LabeledContent("日均振幅", value: "\(report.averageAmplitudePercent.num(2))%")
            Text("振幅就是格距的天花板：日均振幅越大，网格能吃的波段越多。"
                + "如果「首日到末日」几乎没动、日均振幅却不小，那正是网格最舒服的行情。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridRangeWinnerSection: View {
    let report: GridRangeReport
    let isLight: Bool

    @EnvironmentObject private var store: PortfolioStore
    @State private var savedPlanNote = ""

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var alphaColor: Color { report.best.averageAlpha >= 0 ? .red : .green }
    private var lastDay: String { report.days.last ?? "最近交易日" }

    /// 「反过来」的那一步：把胜出参数**直接落成一份日内网格计划**，
    /// 免得用户切到「日内网格计划与回放」再照着数字手抄一遍。
    ///
    /// 几个数的来源：
    /// · 锚点：最近一个交易日的收盘价（报告里能拿到的最新价）；
    /// · 格距：用报告给的「最近交易日换算后的格距比例」，不是区间平均值 ——
    ///   平均值对今天的下单没有意义；
    /// · 档数：按「离区间上下沿各有几格」反推，再夹在 3…20 之间；
    /// · 每笔费用：ETF 0.10 元，个股用 5 元（券商最低佣金是 5 元）。
    ///   `tick` 是判定品种的依据（ETF 0.001 / 个股 0.01），与引擎同一口径。
    private func saveAsDayPlan() {
        guard let anchor = report.details.last?.lastPrice ?? report.details.last?.firstPrice else {
            savedPlanNote = "这份报告没有逐日明细，无法推算锚点。"
            return
        }
        let step = report.best.lastStep
        guard anchor > 0, step > 0 else {
            savedPlanNote = "胜出档位的绝对格距或锚点不是有效数字。"
            return
        }
        let percent = max(0.05, min(10, report.best.lastStepPercent))
        let span = min(anchor - report.rangeLow, report.rangeHigh - anchor)
        let levels = max(1, min(20, max(3, Int(floor(max(0, span) / step)))))
        let etf = report.tick < 0.005
        do {
            try store.saveGridPlan(code: report.code, name: report.name, capital: report.capital,
                                   anchor: anchor, stepPercent: percent, levels: levels,
                                   feePerOrder: etf ? 0.1 : 5)
            savedPlanNote = "已存成日内网格计划：锚点 \(anchor.num(digits))、"
                + "间距 \(percent.num(2))%、上下各 \(levels) 档。到「工具 → 计划 → 日内网格计划与回放」里可以载入或复盘。"
        } catch {
            savedPlanNote = "保存失败：\(error.localizedDescription)"
        }
    }

    var body: some View {
        Section("胜出参数 · 格距 \(report.best.stepPercent.num(2))%") {
            LabeledContent("平均每天跑赢持有", value: "\(report.best.averageAlpha.directionMark()) \(report.best.averageAlpha.cny())")
            LabeledContent("跑赢的天数", value: "\(report.best.winDays) / \(report.best.samples) 天（\(report.best.winRate.num(1))%）")
            LabeledContent("区间合计跑赢", value: "\(report.best.totalAlpha.directionMark()) \(report.best.totalAlpha.cny())")
            LabeledContent("最差一天", value: "\(report.best.worstAlpha.directionMark()) \(report.best.worstAlpha.cny())")
            LabeledContent("最差单日回撤", value: "\(report.best.worstDrawdown.num(2))%")
            LabeledContent("平均每日成交", value: "\(report.best.averageFills.num(1)) 笔")
            LabeledContent("区间费用合计", value: report.best.totalFees.cny())
            Divider()
            Text("照着挂单要用这几个数（按 \(lastDay) 的价格换算）").scaledFont(12, weight: .semibold)
            LabeledContent("每格格距", value: report.best.lastStep.num(digits))
            LabeledContent("换算后的格距比例", value: "\(report.best.lastStepPercent.num(2))%")
            LabeledContent("每格股数 / 份数", value: report.best.lastQuantity.num(0))
            Text("区间里每天的价格不一样，绝对格距必须按当天价格重算，所以这里给的是「最近一个交易日」的换算值。"
                + "换到别的价位，直接按「格距比例」乘当日价格、再取整到最小变动价位即可。")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Button("按这套参数建日内计划") { saveAsDayPlan() }
            if !savedPlanNote.isEmpty {
                Text(savedPlanNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridRangeCandidatesSection: View {
    let report: GridRangeReport
    @Binding var expanded: Bool
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var visible: [GridRangeCandidate] {
        expanded ? report.candidates : Array(report.candidates.prefix(5))
    }

    var body: some View {
        Section("全部候选格距（共 \(report.candidates.count) 组）") {
            ForEach(Array(visible.enumerated()), id: \.element.stepPercent) { index, item in
                GridRangeCandidateRow(
                    item: item,
                    rank: index + 1,
                    digits: digits,
                    isBest: item.stepPercent == report.best.stepPercent
                )
            }
            Button(expanded ? "收起，只看前 5 组" : "展开全部 \(report.candidates.count) 组") {
                expanded.toggle()
            }
            Text("9 组格距百分比（0.4 / 0.6 / 0.8 / 1.0 / 1.2 / 1.5 / 2.0 / 2.5 / 3.0）各跑一遍全部交易日，"
                + "排序先比「平均跑赢」，再比跑赢天数，最后比最差回撤。"
                + "格距还有一道硬下界：一格涨跌必须覆盖买卖两笔费用加两次滑点，所以低价品种的实际格距可能比所选百分比更宽。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridRangeCandidateRow: View {
    let item: GridRangeCandidate
    let rank: Int
    let digits: Int
    let isBest: Bool

    private var alphaColor: Color { item.averageAlpha >= 0 ? .red : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(isBest ? "#\(rank) 胜出" : "#\(rank)")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(isBest ? Color.accentColor : .secondary)
                    .monospacedDigit()
                Text("格距 \(item.stepPercent.num(2))%").scaledFont(11, weight: .medium).monospacedDigit()
                Text("首日换算 \(item.lastStep.num(digits))").scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("日均 \(item.averageAlpha.directionMark()) \(item.averageAlpha.cny())")
                    .scaledFont(12, weight: .semibold).monospacedDigit().foregroundStyle(alphaColor)
            }
            Text("跑赢 \(item.winDays)/\(item.samples) 天（\(item.winRate.num(1))%）· 最差 "
                + "\(item.worstAlpha.directionMark())\(item.worstAlpha.cny()) · 最差回撤 \(item.worstDrawdown.num(2))% · "
                + "日均成交 \(item.averageFills.num(1)) 笔 · 费用 \(item.totalFees.cny())")
                .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct GridRangeDetailsSection: View {
    let report: GridRangeReport
    @Binding var expanded: Bool
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var shown: [GridRangeDayDetail] {
        // 明细是**倒序看最近**更有用：先看最近几天这套参数还灵不灵。
        let reversed = report.details.reversed()
        let list = Array(reversed)
        return expanded ? list : Array(list.prefix(6))
    }

    var body: some View {
        Section("逐日明细（胜出那组）") {
            if report.details.isEmpty {
                Text("没有可展示的逐日明细。").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.day).scaledFont(11, weight: .semibold).monospacedDigit()
                            Text("\(item.dayLow.num(digits)) ~ \(item.dayHigh.num(digits))")
                                .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            Text("\(item.alpha.directionMark()) \(item.alpha.cny())")
                                .scaledFont(12, weight: .semibold).monospacedDigit()
                                .foregroundStyle(item.alpha >= 0 ? .red : .green)
                        }
                        Text("格距 \(item.step.num(digits)) · 买 \(item.buyCount) 卖 \(item.sellCount) · "
                            + "网格 \(item.profit.cny()) · 持有 \(item.holdProfit.cny()) · "
                            + "费用 \(item.fees.cny()) · 回撤 \(item.maxDrawdown.num(2))% · \(item.points) 点")
                            .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
                if report.details.count > 6 {
                    Button(expanded ? "收起，只看最近 6 天" : "展开全部 \(report.details.count) 天") {
                        expanded.toggle()
                    }
                }
            }
            Text(report.note).font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridRangeHistorySection: View {
    let name: String
    let records: [GridRangeReport]
    let isLight: Bool

    var body: some View {
        Section("本机跑过的区间（最多留 20 次）") {
            ForEach(records) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(item.from) → \(item.to)").scaledFont(11, weight: .medium).monospacedDigit()
                        Spacer()
                        Text("格距 \(item.best.stepPercent.num(2))%")
                            .scaledFont(11, weight: .semibold).monospacedDigit()
                    }
                    Text("\(item.days.count) 天 · 日均跑赢 \(item.best.averageAlpha.directionMark())\(item.best.averageAlpha.cny()) · "
                        + "跑赢 \(item.best.winDays)/\(item.best.samples) 天 · 日均振幅 \(item.averageAmplitudePercent.num(2))%")
                        .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            Text("这是「\(name) 这段时间格距习惯」的本地账本，只存在这台设备上，不参与 NAS 同步，也不代表未来。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 免责

private struct GridReviewDisclaimerSection: View {
    let isLight: Bool

    var body: some View {
        Section("使用说明") {
            Text("① 两个模式都用了已经走完的完整分时 —— 这是事后拟合，不能当成明天的建议。\n"
                + "② 假设价格穿越档位就成交，不含盘口排队与真实成交量限制，每分钟最多模拟一笔。\n"
                + "③ 区间模式每天按当日首价重新铺网格（长期网格的真实做法），"
                + "「区间合计跑赢」不能当成能拿到的钱。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("回放数据来自本机分时档案（App 在前台时自动采集 + NAS 归档合并）。"
                + "单日有效分钟点少于 30 个会被直接拒绝；区间里能用的交易日少于 3 个也不会给结论。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}
