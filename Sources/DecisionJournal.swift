import SwiftUI

// MARK: - 决策成绩单
//
// AI 每次给出「参考价 / 目标价 / 失效价」，当时看着都合理。
// 事后到底准不准，靠记忆是记不住的 —— 人只会记得对的那几次。
//
// 所以这里做一件很朴素的事：把每条带价位的建议原样记下来，
// 之后用**真实日线**去判：先摸到目标就是命中，先跌破失效就是错判，
// 两边都没走到的，明说「还在等」。不预测、不补数、不美化。
//
// 判读只用记录日**之后**的日线。记录当天的最高最低价一律不算 ——
// 那是「事后挑一个好看的价」，不是判断能力。

// MARK: - 模型

struct DecisionRecord: Codable, Identifiable {
    var id: UUID = UUID()
    /// 记录时刻。判读时只用它之后的日线。
    var recordedAt: Date = .now
    /// 归一化后的代码（小写、去 sh/sz 前缀），与账本同一口径。
    var code: String
    var name: String
    /// 存字符串而不是复用解析层的枚举：那是 UI 产物，
    /// 改它的 rawValue 会一次性毁掉所有历史记录。
    var side: String
    /// 参考价。缺了就用记录时的最新价补，仍缺则这条不参与收益率统计。
    var entryPrice: Double?
    var target: Double?
    var invalid: Double?
    var reason: String = ""
    /// 来源：组合分析 / 个股分析。
    var source: String = ""
    /// 用户手动了结（例如自己提前卖了，或判断已经不需要再跟）。
    var settledAt: Date? = nil
    var settleNote: String = ""

    // MARK: 留痕（全部 Optional）
    //
    // 这里刻意全用 Optional：`DecisionRecord` 用的是合成 `Decodable`，
    // 给「有默认值但非 Optional」的属性加字段会让老记录整条解码失败 ——
    // Swift 对这种情况仍然会调 `decode`，默认值不参与兜底。
    /// 逐层裁决：数据质量 / 技术数据 / 市场状态 / 资金与仓位。
    var layerTrace: [DecisionLayerTrace]? = nil
    /// 记录那一刻屏幕上的真实报价（与 `entryPrice` 分开，两者可能不同）。
    var observation: DecisionObservation? = nil
    /// 数据质量分级。老记录为 nil，按 `.unknown` 处理。
    var dataQuality: String? = nil
    /// 事后人工复核。
    var reviewNote: String? = nil
    var reviewedAt: Date? = nil

    var isBuy: Bool { side == "buy" }
    var sideLabel: String { isBuy ? "买入" : "卖出" }
}

enum DecisionVerdict: Equatable {
    /// 先摸到目标价。
    case targetHit(price: Double, date: String, days: Int)
    /// 先跌破（或涨破）失效价。
    case invalidHit(price: Double, date: String, days: Int)
    /// 同一根日线里目标与失效都被摸到，先后无法判定。单独计数，不算命中也不算错判。
    case bothTouched(date: String, days: Int)
    /// 有日线但两边都还没走到。
    case waiting(days: Int, lastClose: Double)
    /// 一条日线都没有（新记录的标的还没拉过行情）。
    case noData

    var isResolved: Bool {
        switch self {
        case .targetHit, .invalidHit: return true
        case .bothTouched, .waiting, .noData: return false
        }
    }

    var isHit: Bool {
        if case .targetHit = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .targetHit: return "命中目标"
        case .invalidHit: return "判断失效"
        case .bothTouched: return "同日双触"
        case .waiting: return "还在等"
        case .noData: return "缺日线"
        }
    }
}

// MARK: - 判读

enum DecisionEvaluator {
    /// 上海时区的交易日键，与日线 `date` 字段同一格式。
    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func evaluate(_ record: DecisionRecord, bars: [DailyBar]) -> DecisionVerdict {
        guard let lastBar = bars.last else { return .noData }
        // 手动了结的条目不再用行情判读 —— 用户已经知道结局，不要让曲线替他改口。
        if record.settledAt != nil { return .waiting(days: 0, lastClose: lastBar.close) }

        let key = dayKey(record.recordedAt)
        // 严格大于：记录当天的最高最低价不算。
        let future = bars.filter { $0.date > key }
        guard !future.isEmpty else { return .waiting(days: 0, lastClose: lastBar.close) }

        var index = 0
        for bar in future {
            index += 1
            let targetHit = hitsTarget(record: record, bar: bar)
            let invalidHit = hitsInvalid(record: record, bar: bar)
            if targetHit && invalidHit {
                return .bothTouched(date: bar.date, days: index)
            }
            if invalidHit {
                return .invalidHit(price: record.invalid ?? 0, date: bar.date, days: index)
            }
            if targetHit {
                return .targetHit(price: record.target ?? 0, date: bar.date, days: index)
            }
        }
        let lastClose = future.last?.close ?? lastBar.close
        return .waiting(days: future.count, lastClose: lastClose)
    }

    /// 买入看「涨到目标」：当天最高价摸到即算；卖出看「跌到目标」：当天最低价摸到即算。
    private static func hitsTarget(record: DecisionRecord, bar: DailyBar) -> Bool {
        guard let target = record.target else { return false }
        return record.isBuy ? bar.high >= target : bar.low <= target
    }

    /// 买入看「跌破失效」；卖出看「涨破失效」。
    private static func hitsInvalid(record: DecisionRecord, bar: DailyBar) -> Bool {
        guard let invalid = record.invalid else { return false }
        return record.isBuy ? bar.low <= invalid : bar.high >= invalid
    }

    /// 这条判断如果照着做，到不了结点时的收益率。
    /// 卖出方向反过来算：卖出后价格跌到目标，避损就是正收益。
    static func shadowReturn(_ record: DecisionRecord, verdict: DecisionVerdict) -> Double? {
        guard let entry = record.entryPrice, entry > 0 else { return nil }
        switch verdict {
        case .targetHit(let price, _, _):
            return record.isBuy ? price / entry - 1 : 1 - price / entry
        case .invalidHit(let price, _, _):
            return record.isBuy ? price / entry - 1 : 1 - price / entry
        case .bothTouched, .waiting, .noData:
            return nil
        }
    }
}

// MARK: - 汇总

/// 一条判断有没有被真的执行。
///
/// 命中率只说明判断本身准不准。但「判断对了却没买」和「判断对了并且买了」
/// 是两种完全不同的人生结果 —— 不区分的话，成绩单会一直高估这份判断的价值。
///
/// 判定只认账本里的真实成交：同代码、记录日**当天或之后**、方向相符。
/// 记录日当天算数，因为 AI 分析常在盘中跑，当天下午下单是最正常的情形；
/// 这与行情判读「记录日当天不算」的口径不同，两者刻意分开：
/// 判读要防事后挑价，执行要认已经发生的事实。
struct DecisionExecution: Equatable {
    enum State: String, Equatable {
        /// 账本里找不到对应成交。
        case none
        /// 找到了方向相同的成交。
        case executed
        /// 只有方向相反的成交（例如建议买入却卖了）。
        case contrary
    }

    var state: State = .none
    /// 命中的那笔成交日期。
    var date: String = ""
    var quantity: Double = 0
    var price: Double = 0

    var isExecuted: Bool { state == .executed }

    var label: String {
        switch state {
        case .none: return "未执行"
        case .executed: return "已执行"
        case .contrary: return "反向操作"
        }
    }
}

/// 一条记录 + 它的判读结果。
///
/// 用结构体而不是 `(record:verdict:)` 元组：`ForEach` 的 id 要写成 key path，
/// 而 Swift 的 key path 不能指向元组元素。
struct DecisionJudgement: Identifiable {
    let record: DecisionRecord
    let verdict: DecisionVerdict
    let execution: DecisionExecution

    var id: UUID { record.id }
}

struct DecisionScoreboard {
    var hits = 0
    var misses = 0
    var undecided = 0
    var waiting = 0
    var noData = 0
    var settled = 0
    var returns: [Double] = []
    var daysToHit: [Int] = []

    // 执行情况。只在「已了结」的条目上统计，否则新记录会一直拉低执行率。
    var executedCount = 0
    var unexecutedCount = 0
    var contraryCount = 0
    /// 判断对并且真做了。
    var hitAndExecuted = 0
    /// 判断对但没动。
    var hitNotExecuted = 0
    /// 判断错但也没做 —— 少亏一次。
    var missAvoided = 0
    /// 判断错还真做了。
    var missAndExecuted = 0

    /// 已了结条数。命中率的分母只用它 —— 把「还在等」算进分母是在虚增难度。
    var resolved: Int { hits + misses }
    var total: Int { hits + misses + undecided + waiting + noData + settled }

    var hitRate: Double? {
        resolved > 0 ? Double(hits) / Double(resolved) : nil
    }

    /// 已了结条目里真正按判断动过手的比例。
    var executionRate: Double? {
        let acted = executedCount + unexecutedCount + contraryCount
        guard acted > 0 else { return nil }
        return Double(executedCount) / Double(acted)
    }

    var averageReturn: Double? {
        returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
    }

    var averageDaysToTarget: Double? {
        daysToHit.isEmpty ? nil : Double(daysToHit.reduce(0, +)) / Double(daysToHit.count)
    }

    static func build(_ items: [DecisionJudgement]) -> DecisionScoreboard {
        var board = DecisionScoreboard()
        for item in items {
            // 手动标记了结的只当档案，不进任何统计 —— 否则用户随手一点就能改命中率。
            if item.record.settledAt != nil {
                board.settled += 1
                continue
            }
            switch item.verdict {
            case .targetHit(_, _, let days):
                board.hits += 1
                board.daysToHit.append(days)
            case .invalidHit:
                board.misses += 1
            case .bothTouched:
                board.undecided += 1
            case .waiting:
                board.waiting += 1
            case .noData:
                board.noData += 1
            }
            if let value = DecisionEvaluator.shadowReturn(item.record, verdict: item.verdict) {
                board.returns.append(value)
            }
            // 执行情况只在有结论的条目上累计。
            guard item.verdict.isResolved else { continue }
            switch item.execution.state {
            case .executed: board.executedCount += 1
            case .none: board.unexecutedCount += 1
            case .contrary: board.contraryCount += 1
            }
            switch (item.verdict.isHit, item.execution.isExecuted) {
            case (true, true): board.hitAndExecuted += 1
            case (true, false): board.hitNotExecuted += 1
            case (false, true): board.missAndExecuted += 1
            case (false, false): board.missAvoided += 1
            }
        }
        return board
    }
}

// MARK: - Store 扩展

extension PortfolioStore {
    /// 把一次分析里的可执行建议落成成绩单条目。
    ///
    /// 只有带价位的建议才记 —— 没有价位就没法事后判读，记下来只是噪音。
    /// 同一标的、同一方向、同一天只记一条：模型在同一天被问两次不该算两票。
    @discardableResult
    func recordDecisions(from suggestions: [AISuggestion], source: String) -> Int {
        let today = DecisionEvaluator.dayKey(.now)
        // 市场状态整批只算一次：它在循环里每算一次都要重扫一遍日线并写缓存。
        let regime = marketRegime()
        var added = 0
        for suggestion in suggestions {
            guard suggestion.price != nil || suggestion.target != nil || suggestion.invalid != nil else { continue }
            let code = normalizedDecisionCode(suggestion.code)
            guard !code.isEmpty else { continue }
            let side = suggestion.side == .buy ? "buy" : "sell"
            let duplicated = data.decisionJournal.contains { existing in
                existing.code == code
                    && existing.side == side
                    && DecisionEvaluator.dayKey(existing.recordedAt) == today
            }
            if duplicated { continue }

            // 参考价缺失时用当前行情兜底；两者都没有就留空，收益率统计会跳过这条。
            let matchedQuote = data.quotes.first { normalizedDecisionCode($0.code) == code }
            let marketPrice = matchedQuote?.price
            var entry = suggestion.price
            if entry == nil, let marketPrice, marketPrice > 0 { entry = marketPrice }

            // 装配留痕：数据质量、技术数据、市场状态、仓位。
            // 这样事后才能分清「判断错了」和「当时数据本来就不可信」。
            let holding = data.holdings.first { normalizedDecisionCode($0.code) == code }
            let trace = DecisionTraceBuilder.build(quote: matchedQuote,
                                                   session: sessionStatus,
                                                   regime: regime,
                                                   hasDailyBars: !(dailyBars[code] ?? []).isEmpty,
                                                   heldQuantity: holding?.quantity ?? 0,
                                                   positionLimitPercent: data.globalPositionLimitPercent)

            data.decisionJournal.append(DecisionRecord(
                recordedAt: .now,
                code: code,
                name: suggestion.displayName,
                side: side,
                entryPrice: entry,
                target: suggestion.target,
                invalid: suggestion.invalid,
                reason: suggestion.reason,
                source: source,
                layerTrace: trace.traces,
                observation: trace.observation,
                dataQuality: trace.quality.rawValue))
            added += 1
        }
        if added > 0 { save(label: "记录决策") }
        return added
    }

    /// 代码归一化：小写 + 去掉市场前缀，与归档、账本同一口径。
    /// 不统一会出现「sh510300」和「510300」两套互不相认的键。
    func normalizedDecisionCode(_ raw: String) -> String {
        var code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where code.hasPrefix(prefix) && code.count > prefix.count + 2 {
            code = String(code.dropFirst(prefix.count))
        }
        return code
    }

    /// 全部条目与判读结果，最近记录的在前。
    func decisionVerdicts() -> [DecisionJudgement] {
        let ledger = data.ledger
        return data.decisionJournal
            .sorted { $0.recordedAt > $1.recordedAt }
            .map { record in
                DecisionJudgement(record: record,
                                  verdict: DecisionEvaluator.evaluate(record, bars: dailyBars[record.code] ?? []),
                                  execution: decisionExecution(for: record, ledger: ledger))
            }
    }

    /// 这条判断有没有被真的执行。
    ///
    /// 只认账本里的真实成交。记录日当天及之后都算 —— 盘中给的判断当天下午下单，
    /// 是最正常的情形，不该因为「不是第二天」而被判成没执行。
    func decisionExecution(for record: DecisionRecord, ledger: [LedgerEntry]? = nil) -> DecisionExecution {
        let fills = ledger ?? data.ledger
        let start = DecisionEvaluator.dayKey(record.recordedAt)
        let wantBuy = record.isBuy
        var opposite: DecisionExecution?

        for entry in fills.sorted(by: { $0.date < $1.date }) {
            guard normalizedDecisionCode(entry.code) == record.code else { continue }
            let day = DecisionEvaluator.dayKey(entry.date)
            guard day >= start else { continue }
            // 基金分红不在这张表里，这里只有买和卖。
            let isBuy = entry.side == .buy
            if isBuy == wantBuy {
                return DecisionExecution(state: .executed, date: day,
                                         quantity: entry.quantity, price: entry.price)
            }
            if opposite == nil {
                opposite = DecisionExecution(state: .contrary, date: day,
                                             quantity: entry.quantity, price: entry.price)
            }
        }
        return opposite ?? DecisionExecution()
    }

    func removeDecision(_ record: DecisionRecord) {
        data.decisionJournal.removeAll { $0.id == record.id }
        save(label: "删除决策记录")
    }

    /// 手动了结：不再参与命中率，但保留在列表里当档案。
    func settleDecision(_ record: DecisionRecord, note: String) {
        guard let index = data.decisionJournal.firstIndex(where: { $0.id == record.id }) else { return }
        data.decisionJournal[index].settledAt = .now
        data.decisionJournal[index].settleNote = note
        save(label: "了结决策记录")
    }

    /// 补拉成绩单里缺日线的标的。返回成功拉到的只数。
    @discardableResult
    func refreshDecisionBars() async -> Int {
        var codes: [String] = []
        for record in data.decisionJournal where codes.contains(record.code) == false {
            let bars = dailyBars[record.code] ?? []
            // 判读还没结束的才值得刷新；已了结的再拉也不会改结论。
            let verdict = DecisionEvaluator.evaluate(record, bars: bars)
            if bars.isEmpty || (!verdict.isResolved && record.settledAt == nil) {
                codes.append(record.code)
            }
        }
        var ok = 0
        for code in codes.prefix(20) {
            if (try? await fetchDailyBars(code: code, force: true)) != nil { ok += 1 }
        }
        return ok
    }
}

// MARK: - 页面

struct DecisionScorecardView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var filter: Filter = .all
    @State private var refreshing = false
    @State private var refreshNote = ""
    @State private var removeTarget: DecisionRecord?
    private enum Filter: String, CaseIterable, Identifiable {
        case all, open, resolved

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .open: return "待验证"
            case .resolved: return "已了结"
            }
        }
    }

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    private var allPairs: [DecisionJudgement] {
        store.decisionVerdicts()
    }

    private var board: DecisionScoreboard {
        DecisionScoreboard.build(allPairs)
    }

    private var shownPairs: [DecisionJudgement] {
        switch filter {
        case .all: return allPairs
        case .open: return allPairs.filter { !$0.verdict.isResolved && $0.record.settledAt == nil }
        case .resolved: return allPairs.filter { $0.verdict.isResolved || $0.record.settledAt != nil }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    heroCard
                    statRow
                    crossCard
                    filterBar
                    if shownPairs.isEmpty {
                        emptyCard
                    } else {
                        VStack(spacing: 10) {
                            ForEach(shownPairs) { item in
                                recordRow(item.record, verdict: item.verdict, execution: item.execution)
                            }
                        }
                    }
                    methodNote
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("决策成绩单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable {
                refreshing = true
                let ok = await store.refreshDecisionBars()
                refreshing = false
                refreshNote = ok > 0 ? "已更新 \(ok) 只标的日线" : "日线没有新增，判读结论不变"
                Haptics.success()
            }
            .confirmationDialog("删除这条决策记录？",
                                isPresented: Binding(get: { removeTarget != nil },
                                                     set: { if !$0 { removeTarget = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let target = removeTarget { store.removeDecision(target) }
                    removeTarget = nil
                }
                Button("取消", role: .cancel) { removeTarget = nil }
            } message: {
                Text("只删这一条成绩记录，不影响持仓、账本与分析缓存。")
            }
        }
    }

    // MARK: 汇总卡

    private var heroCard: some View {
        let rate = board.hitRate
        let rateText = rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
        let subtitle: String
        if board.total == 0 {
            subtitle = "还没有记录。跑一次 AI 分析，带价位的建议会自动记进来。"
        } else if board.resolved == 0 {
            subtitle = "\(board.total) 条判断都还没走到目标或失效，先给它们时间。"
        } else {
            subtitle = "已了结 \(board.resolved) 条里对了 \(board.hits) 条 · 另有 \(board.waiting) 条还在等"
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("目标命中率")
                .scaledFont(palette.fsLabel, weight: .medium)
                .foregroundStyle(palette.ink2)
            Text(rateText)
                .scaledFont(palette.fsHero, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(rateColor)
                .lineLimit(1)
            Text(subtitle)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let average = board.averageReturn {
                HStack(spacing: 6) {
                    Image(systemName: average >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PnLColor.of(average))
                    Text("照做平均 \(average.pct(2))")
                        .scaledFont(palette.fsLabel, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(PnLColor.of(average))
                    if let days = board.averageDaysToTarget {
                        Text("· 平均 \(Int(days.rounded())) 个交易日到目标")
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                }
            }
            if let rate = board.executionRate {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Text("已了结的 \(board.resolved) 条里，真的照做了 \(Int((rate * 100).rounded()))%")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink2)
                }
            }
            if refreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在补拉日线…")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
            } else if !refreshNote.isEmpty {
                Text(refreshNote)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.heroRadius, padding: 18, glow: rateColor)
    }

    private var rateColor: Color {
        guard let rate = board.hitRate else { return palette.ink2 }
        if rate >= 0.6 { return PnLColor.up }
        if rate >= 0.4 { return palette.accent }
        return PnLColor.down
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            DsStatTile(palette: palette, symbol: "target", title: "命中目标",
                       value: "\(board.hits)", tint: PnLColor.up)
            DsStatTile(palette: palette, symbol: "xmark.octagon", title: "判断失效",
                       value: "\(board.misses)", tint: PnLColor.down)
            DsStatTile(palette: palette, symbol: "hourglass", title: "还在等",
                       value: "\(board.waiting)", tint: palette.accent)
        }
    }

    /// 「判断对/错 × 有没有动手」四格。这是成绩单里最有用的一块：
    /// 命中率高但从不执行，等于没有判断；命中率低但也没做，说明纪律救了账户。
    @ViewBuilder private var crossCard: some View {
        if board.resolved > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("判断 × 执行")
                    .scaledFont(palette.fsLabel, weight: .semibold)
                    .foregroundStyle(palette.ink2)
                HStack(spacing: 10) {
                    crossCell(title: "看对了也做了", value: board.hitAndExecuted, tone: CardTone.ok)
                    crossCell(title: "看对了没动手", value: board.hitNotExecuted, tone: CardTone.warn)
                }
                HStack(spacing: 10) {
                    crossCell(title: "看错但没做", value: board.missAvoided, tone: CardTone.ok)
                    crossCell(title: "看错还做了", value: board.missAndExecuted, tone: PnLColor.down)
                }
                Text(crossNote)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(palette, radius: 20, padding: 14)
        }
    }

    private func crossCell(title: String, value: Int, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .scaledFont(20, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(value > 0 ? tone : palette.ink3)
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.cardSoft) }
    }

    /// 一句诚实的解读。不吹「判断很准」，先看有没有真的执行。
    private var crossNote: String {
        if board.hitNotExecuted > board.hitAndExecuted {
            return "看对的次数多于真正动手的次数 —— 命中率再高，没执行也不进账户。"
        }
        if board.missAndExecuted > 0 && board.missAndExecuted >= board.hitAndExecuted {
            return "看错的几次都真金白银做了。这类记录比命中率更值得盯。"
        }
        if board.executedCount == 0 && board.unexecutedCount > 0 {
            return "已了结的判断一条都没落到账本上。要么是判断没执行，要么成交记在了别处。"
        }
        return "执行情况按账本里的真实成交匹配：同代码、记录日当天或之后、方向相符。"
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { item in
                let selected = filter == item
                Button {
                    Haptics.selection()
                    filter = item
                } label: {
                    Text(item.title)
                        .scaledFont(palette.fsLabel, weight: .semibold)
                        .foregroundStyle(selected ? palette.ink : palette.ink2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(selected ? palette.cardSoft : Color.clear)
                        }
                        .overlay {
                            Capsule().strokeBorder(selected ? palette.hairline : Color.clear, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("\(shownPairs.count) 条")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, 2)
    }

    // MARK: 单条

    private func recordRow(_ record: DecisionRecord, verdict: DecisionVerdict,
                          execution: DecisionExecution) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(record.sideLabel)
                    .scaledFont(10, weight: .bold)
                    .foregroundStyle(record.isBuy ? PnLColor.up : PnLColor.down)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill((record.isBuy ? PnLColor.up : PnLColor.down)
                            .opacity(palette.isLight ? 0.12 : 0.18))
                    }
                Text(record.name)
                    .scaledFont(palette.fsRow, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(record.code)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                verdictPill(verdict)
            }

            HStack(spacing: 14) {
                priceLabel("参考", record.entryPrice)
                priceLabel("目标", record.target)
                priceLabel("失效", record.invalid)
                Spacer(minLength: 0)
            }

            executionRow(execution)

            if !record.reason.isEmpty {
                Text(record.reason)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 只显示被降级或拦截的那几层。全显示的噪音太大，
            // 而「哪一层曾经不同意」才是复盘时真正想看的东西。
            if !record.trace.filter({ $0.isBlocking || $0.isDegrading }).isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(record.trace.filter { $0.isBlocking || $0.isDegrading }.prefix(2)) { item in
                        HStack(alignment: .top, spacing: 5) {
                            Text(item.action)
                                .scaledFont(9, weight: .bold)
                                .foregroundStyle(item.isBlocking ? PnLColor.down : PnLColor.up)
                            Text("\(item.layer)：\(item.note)")
                                .scaledFont(9.5)
                                .foregroundStyle(palette.ink3)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text(recordedText(record))
                    .scaledFont(9.5)
                    .foregroundStyle(palette.ink3)
                if !record.source.isEmpty {
                    Text("· \(record.source)")
                        .scaledFont(9.5)
                        .foregroundStyle(palette.ink3)
                }
                if record.hasTrace {
                    Text("· \(record.quality.shortTitle)")
                        .scaledFont(9.5, weight: .medium)
                        .foregroundStyle(record.quality == .complete ? palette.ink3 : PnLColor.up)
                }
                Spacer(minLength: 0)
                Menu {
                    if record.settledAt == nil {
                        Button("标记为了结") {
                            store.settleDecision(record, note: "手动标记")
                            Haptics.tap()
                        }
                    }
                    Button("删除这条", role: .destructive) { removeTarget = record }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.ink3)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 18, padding: 14)
    }

    private func priceLabel(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text(value.map { $0.num(3) } ?? "--")
                .scaledFont(palette.fsLabel, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(value == nil ? palette.ink3 : palette.ink)
        }
    }

    /// 执行情况那一行。判断准不准是一回事，有没有真动手是另一回事。
    private func executionRow(_ execution: DecisionExecution) -> some View {
        let tint: Color
        let detail: String
        switch execution.state {
        case .executed:
            tint = CardTone.ok
            detail = "\(execution.date) · \(execution.quantity.num(0)) 份 @ \(execution.price.num(3))"
        case .contrary:
            tint = CardTone.warn
            detail = "\(execution.date) 有反向成交，方向不符"
        case .none:
            tint = palette.ink3
            detail = "账本里没有对应成交"
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(execution.label)
                .scaledFont(9.5, weight: .semibold)
                .foregroundStyle(tint)
            Text(detail)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(palette.isLight ? 0.07 : 0.10)) }
    }

    private func verdictTint(_ verdict: DecisionVerdict) -> Color {
        switch verdict {
        case .targetHit: return PnLColor.up
        case .invalidHit: return PnLColor.down
        case .bothTouched: return CardTone.warn
        case .waiting: return palette.accent
        case .noData: return palette.ink3
        }
    }

    private func verdictDetail(_ verdict: DecisionVerdict) -> String {
        switch verdict {
        case .targetHit(_, let date, let days), .invalidHit(_, let date, let days):
            return "\(date) · \(days) 个交易日"
        case .bothTouched(let date, let days):
            return "\(date) · 同日双触，无法判先后（第 \(days) 日）"
        case .waiting(let days, let close):
            return days == 0 ? "记录当日尚无可判日线" : "已 \(days) 个交易日 · 现价 \(close.num(3))"
        case .noData:
            return "补拉日线后才能判读"
        }
    }

    private func verdictPill(_ verdict: DecisionVerdict) -> some View {
        let tint = verdictTint(verdict)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(verdict.title)
                .scaledFont(9.5, weight: .bold)
                .foregroundStyle(tint)
            Text(verdictDetail(verdict))
                .scaledFont(8.5)
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background { Capsule().fill(tint.opacity(palette.isLight ? 0.10 : 0.14)) }
    }

    private func recordedText(_ record: DecisionRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: record.recordedAt)
    }

    // MARK: 空态与口径

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filter == .all ? "还没有判读样本" : "这一档是空的")
                .scaledFont(palette.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            Text(filter == .all
                 ? "去「AI 账户分析」跑一次。模型给出带参考价 / 目标价 / 失效价的建议时，会自动记进这里，之后用真实日线逐条判读。"
                 : "换一档看，或下拉补拉日线。")
                .scaledFont(palette.fsLabel)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 18, padding: 16)
    }

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("判读口径")
                .scaledFont(palette.fsLabel, weight: .semibold)
                .foregroundStyle(palette.ink2)
            Text("只用记录日**之后**的日线。买入看最高价是否摸到目标、最低价是否跌破失效，卖出相反。同一根日线两边都碰到时记为「同日双触」，不计入命中率——先后无法确定的事不硬判。命中率分母只算已了结条数，「还在等」不抬高也不拉低它。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text("照做平均收益按参考价到目标 / 失效价计算，不含手续费、滑点与仓位差异，只用来衡量「判断本身」值不值钱。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text("执行情况只认账本里的真实成交：同代码、记录日当天或之后、方向相符。记录日当天算数 —— 盘中给的判断当天下午下单很正常；这与行情判读「记录日当天不算」刻意不同：判读要防事后挑价，执行要认已经发生的事。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }
}
