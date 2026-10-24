import Foundation
import SwiftUI
import Combine

@MainActor final class NextAppModel: ObservableObject {
    @Published var ledger: NextAuditedBook = NextAuditedBook(current: NextBook()) { didSet { reportSave(repository.save(ledger, filename: "real-ledger-v1.json")) } }
    @Published var preferences = LocalPreferences() { didSet { reportSave(repository.save(preferences, filename: "preferences-v1.json")) } }
    @Published var quotes: [String: NextCachedQuote] = [:] { didSet { reportSave(repository.save(quotes, filename: "cached-quotes-v1.json")) } }
    @Published var chartData: [String: NextChartDataset] = [:] { didSet { reportSave(repository.save(chartData, filename: "chart-history-v1.json")) } }
    @Published var rules: [String: NextInstrumentRules] = [:] { didSet { reportSave(repository.save(rules, filename: "instrument-rules-v1.json")) } }
    @Published var orderBooks: [String: NextOrderBookSnapshot] = [:] { didSet { reportSave(repository.save(orderBooks, filename: "order-books-v1.json")) } }
    @Published var decisions: [NextDecision] = [] { didSet { reportSave(repository.save(decisions, filename: "decision-history-v1.json")) } }
    @Published var nasResearch: [String: NextNASResearch] = [:] { didSet { reportSave(repository.save(nasResearch, filename: "nas-research-v1.json")) } }
    @Published var researchStatus: [String: String] = [:] { didSet {  } }
    @Published var dividendEvents: [String: [NextETFDividendEvent]] = [:] { didSet { reportSave(repository.save(dividendEvents, filename: "dividend-history-v1.json")) } }
    @Published var patientLimitPlans: [NextPatientLimitPlan] = [] { didSet { reportSave(repository.save(patientLimitPlans, filename: "patient-limit-plans-v1.json")) } }
    @Published var candidatePlans: [NextCandidatePlan] = [] { didSet { reportSave(repository.save(candidatePlans, filename: "candidate-plans-v1.json")) } }
    /// 动态投资者画像：只存结论与依据，不存原始成交流水（流水在账本里）。
    @Published var profile = NextInvestorProfile() { didSet { reportSave(repository.save(profile, filename: "investor-profile-v1.json")) } }
    /// AI 给过的每一次具体机会：曝光 → 反馈 → 是否真实成交，画像学习只吃这条链。
    @Published var suggestions: [NextSuggestionRecord] = [] { didSet { reportSave(repository.save(suggestions, filename: "ai-suggestions-v1.json")) } }
    /// AI 决策记忆：每条建议「当时」的行情/持仓/NAS/新闻/画像/依据/风险/有效期，加上改判轨迹与复盘。
    @Published var decisionMemory: [NextDecisionRecord] = [] { didSet { reportSave(repository.save(decisionMemory, filename: "decision-memory-v1.json")) } }
    /// 每只持仓的最新新闻标题（只存标题与来源，不存正文）。新闻→持仓→计划的影响在扫描时统一计算。
    @Published var nasNews: [String: [NextNewsInput]] = [:] { didSet { reportSave(repository.save(nasNews, filename: "nas-news-v1.json")) } }
    @Published var newsStatus: [String: String] = [:] { didSet {  } }
    @Published var dailyGuidance: NextDailyGuidance? { didSet {  } }
    @Published var guidanceStatus = "尚未生成今日指导" { didSet {  } }
    @Published var unifiedAIAdvice: String? { didSet {  } }
    @Published var unifiedAIStatus: String? { didSet {  } }
    @Published var unifiedAIIsRunning = false { didSet {  } }
    @Published var status = "行情尚未刷新 · 缓存可离线查看" { didSet {  } }
    @Published var syncStatus = "NAS 未连接" { didSet {  } }
    /// Runtime health only: configured address and prior ledger sync never imply that NAS is online.
    @Published var nasReachable: Bool?
    @Published var nasProbedAt: Date?
    @Published var legacyImportPreview: NextLegacyBookPreview? { didSet {  } }
    @Published var dailyErrors: [String: String] = [:] { didSet {  } }
    @Published var notificationStatus = "尚未检查系统通知权限" { didSet {  } }
    @Published var errorMessage: String? { didSet {  } }
    @Published var showSearch = false { didSet {  } }
    @Published var searchText = "" { didSet {  } }
    @Published var notice = "" { didSet {  } }
    @Published var requestedTab: NextTab? { didSet {  } }
    @Published var requestedRoute: GPRoute? { didSet {  } }
    @Published var routeRequestID = UUID() { didSet {  } }
    private let repository: NextLocalRepository
    /// 合并自动上传用的延迟任务；连点几次"录入"只发一次。
    private var autoUploadTask: Task<Void, Never>?

    var book: NextBook { ledger.current }
    var goal: NextGoal { preferences.goal }
    var watch: [String] { preferences.watch }
    var monitoredCodes: [String] {
        Array(Set(watch + book.positions.map(\.code) + preferences.notifications.priceRules.filter(\.enabled).map(\.code)
                  + patientLimitPlans.filter { $0.state == "等待价格提醒" }.map(\.code)
                  + candidatePlans.filter { $0.state.isOpen }.map(\.code))).sorted()
    }
    var theme: GPTheme { preferences.theme }

    /// 真实账本口径的总资产 = 现金 + 持仓市值（缺报价的按成本兜底，并保证不漏算）。
    var realBookEquity: Decimal {
        var total = book.cash
        for position in book.positions where position.units > 0 {
            if let quote = quotes[position.code]?.quote, quote.price > 0 {
                total += quote.price * Decimal(position.units)
            } else {
                total += position.bookCost
            }
        }
        return total
    }

    /// 名称解析统一入口：账本里存的名称 > 报价里的 > 名称簿（跨启动）> 内置目录 > 代码本身。
    /// 以前界面上到处是裸代码或"场内证券"，就是因为每个地方各自取一次、取不到就没人兜底。
    func name(for code: String) -> String {
        let stored = book.positions.first(where: { $0.code == code })?.name
        if let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty, stored != code { return stored }
        if let quoted = quotes[code]?.quote.name, !quoted.isEmpty, quoted != code { return quoted }
        return NextNameBook.resolve(code)
    }

    /// 把账本/自选/提醒里出现过、但还不知道名字的代码补齐。
    /// 只读一次行情并把名称记进名称簿，**不改账本字段**，所以不会产生审计噪音。
    func backfillNamesIfNeeded() async {
        let codes = Set(book.positions.map(\.code) + watch + book.fills.map(\.code)
                        + preferences.notifications.priceRules.map(\.code) + book.dividendEvents.map(\.code))
        let missing = codes.filter { code in
            let stored = book.positions.first(where: { $0.code == code })?.name ?? ""
            guard stored.isEmpty || stored == code else { return false }
            let quoted = quotes[code]?.quote.name ?? ""
            guard quoted.isEmpty || quoted == code else { return false }
            return !NextNameBook.isResolved(code)
        }
        guard !missing.isEmpty else { return }
        await refreshQuotes(codes: missing.sorted())
    }
    var selectedTab: NextTab {
        get { preferences.navigation.selectedTab }
        set { preferences.navigation.selectedTab = newValue; preferences = preferences }
    }
    init(repository: NextLocalRepository? = nil) {
        let repository = repository ?? NextLocalRepository()
        self.repository = repository
        let real = repository.load(NextAuditedBook.self, filename: "real-ledger-v1.json", fallback: NextAuditedBook(current: NextBook()))
        self.ledger = real
        self.preferences = repository.load(LocalPreferences.self, filename: "preferences-v1.json", fallback: LocalPreferences())
        self.quotes = repository.load([String: NextCachedQuote].self, filename: "cached-quotes-v1.json", fallback: [:])
        self.chartData = repository.load([String: NextChartDataset].self, filename: "chart-history-v1.json", fallback: [:])
        self.rules = repository.load([String: NextInstrumentRules].self, filename: "instrument-rules-v1.json", fallback: [:])
        self.orderBooks = repository.load([String: NextOrderBookSnapshot].self, filename: "order-books-v1.json", fallback: [:])
        self.decisions = repository.load([NextDecision].self, filename: "decision-history-v1.json", fallback: [])
        self.nasResearch = repository.load([String: NextNASResearch].self, filename: "nas-research-v1.json", fallback: [:])
        self.decisionMemory = repository.load([NextDecisionRecord].self, filename: "decision-memory-v1.json", fallback: [])
        self.nasNews = repository.load([String: [NextNewsInput]].self, filename: "nas-news-v1.json", fallback: [:])
        self.dividendEvents = repository.load([String: [NextETFDividendEvent]].self, filename: "dividend-history-v1.json", fallback: [:])
        self.patientLimitPlans = repository.load([NextPatientLimitPlan].self, filename: "patient-limit-plans-v1.json", fallback: [])
        self.candidatePlans = repository.load([NextCandidatePlan].self, filename: "candidate-plans-v1.json", fallback: [])
        self.profile = repository.load(NextInvestorProfile.self, filename: "investor-profile-v1.json", fallback: NextInvestorProfile())
        self.suggestions = repository.load([NextSuggestionRecord].self, filename: "ai-suggestions-v1.json", fallback: [])
        self.errorMessage = repository.integrityWarning
        // 启动时把「只有代码、没有名字」的标的补一次：账本里的旧数据、旧自选都能认出来。
        Task { await backfillNamesIfNeeded() }
    }
    func commitRealLedger(_ updated: NextBook, action: String, reason: String) throws {
        try updated.validate()
        var copy = ledger
        try copy.apply(updated, action: action, reason: reason, at: Date())
        ledger = copy
        scheduleAutoUpload()
    }
    /// 录入持仓。`acquiredAt` 是建仓日：只把建仓日及之后的派息算作你的，之前发生的除息不算
    /// （你刚录入一只已经持有很久、且早已分红过的票时，不会凭空冒出历史分红待确认）。不传则按录入当天处理。
    func addPosition(code: String, name: String, units: Int, cost: Decimal, acquiredAt: Date? = nil) throws {
        guard !book.positions.contains(where: { $0.code == code }), units > 0, cost > 0 else { throw NextError.invalid("代码、份额或持仓成本无效，或该证券已经存在") }
        var updated = book
        updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: cost, acquiredAt: acquiredAt ?? Date()))
        NextNameBook.remember(name, code: code)
        try commitRealLedger(updated, action: "录入场内持仓", reason: "用户确认保存")
        if !preferences.nasBaseURL.isEmpty { Task { await registerNASArchive(code) } }
    }
    /// 删除一条持仓。走的是同一条审计通道，可在「资产流水 → 撤销」里回退。
    func deletePosition(_ code: String) throws {
        guard book.positions.contains(where: { $0.code == code }) else { throw NextError.invalid("账本里没有这只持仓") }
        var updated = book
        updated.positions.removeAll { $0.code == code }
        try commitRealLedger(updated, action: "删除场内持仓", reason: "用户确认删除 \(code)")
    }

    /// 删除一条成交流水，并按相反方向回滚它对**持仓与现金**的影响。
    /// 这是必要的：只删流水不回滚，账本就会出现「有持仓无买入记录」的假账，
    /// 摊薄成本和已实现盈亏都会跟着错。
    func deleteFill(_ id: UUID) throws {
        guard let fill = book.fills.first(where: { $0.id == id }) else { throw NextError.invalid("找不到这条流水") }
        var updated = book
        updated.fills.removeAll { $0.id == id }
        let gross = fill.price * Decimal(fill.units)
        let index = updated.positions.firstIndex { $0.code == fill.code }
        if fill.side == "buy" {
            // 回滚买入：现金加回，持仓减份数、减成本。
            updated.cash += gross + fill.fee
            guard let index else { throw NextError.invalid("这只持仓已不存在，无法回滚这笔买入") }
            let newUnits = updated.positions[index].units - fill.units
            guard newUnits >= 0 else { throw NextError.invalid("回滚后份额为负：这笔买入的份额已经卖出，请先删对应的卖出流水") }
            updated.positions[index].bookCost -= gross + fill.fee
            if updated.positions[index].bookCost < 0 { updated.positions[index].bookCost = 0 }
            updated.positions[index].units = newUnits
            if newUnits == 0 { updated.positions.remove(at: index) }
        } else {
            // 回滚卖出：现金扣回，持仓加回份数与当初结转的成本。
            guard updated.cash - (gross - fill.fee) >= 0 else { throw NextError.invalid("回滚后现金为负，请先补足现金再删这笔卖出") }
            updated.cash -= gross - fill.fee
            let restoredCost = max(0, gross - fill.fee - fill.realized)
            if let index {
                updated.positions[index].units += fill.units
                updated.positions[index].bookCost += restoredCost
            } else {
                updated.positions.append(NextPosition(code: fill.code, name: fill.code, units: fill.units, bookCost: restoredCost))
            }
        }
        try commitRealLedger(updated, action: "删除成交流水",
                             reason: "用户删除 \(fill.code) \(fill.side == "buy" ? "买入" : "卖出") \(fill.units) 份 · ¥\(NextMoney.text(fill.price))，已同步回滚持仓与现金")
    }

    /// 修正录入错误的份额或总成本。**不改现金、不虚构成交**，只订正账本里的持仓事实。
    func updatePosition(_ code: String, units: Int, totalCost: Decimal) throws {
        guard units > 0, totalCost > 0, !totalCost.isNaN else { throw NextError.invalid("份额与总成本必须大于 0") }
        guard let index = book.positions.firstIndex(where: { $0.code == code }) else { throw NextError.invalid("账本里没有这只持仓") }
        var updated = book
        let previous = updated.positions[index]
        updated.positions[index].units = units
        updated.positions[index].bookCost = totalCost
        try commitRealLedger(updated, action: "修正持仓份额与成本",
                             reason: "用户订正 \(code)：\(previous.units) 份 / ¥\(NextMoney.text(previous.bookCost)) → \(units) 份 / ¥\(NextMoney.text(totalCost))")
    }

    /// 现金变动统一入口：转入/转出都走这里，写账本并留审计。
    /// 买卖会自己联动现金，这个方法只用于「券商那边真的划了钱进/出」。
    func addCash(_ amount: Decimal, reason: String) throws {
        guard !amount.isNaN, amount != 0 else { throw NextError.invalid("现金变动金额不能为零") }
        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw NextError.invalid("现金变动需要写明来源") }
        var updated = book
        guard updated.cash + amount >= 0 else { throw NextError.invalid("转出超过可用现金 ¥\(NextMoney.text(updated.cash))") }
        updated.cash += amount
        updated.cashMovements.append(NextCashMovement(date: Date(), amount: amount, reason: note))
        try commitRealLedger(updated, action: amount > 0 ? "记录现金转入" : "记录现金转出",
                             reason: "\(note)；金额 ¥\(NextMoney.text(abs(amount)))")
    }

    func recordTrade(code: String, name: String, side: String, units: Int, price: Decimal, fee: Decimal,
                     at tradedAt: Date = Date()) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), units > 0, price > 0,
              side == "buy" || side == "sell", fee >= 0, !fee.isNaN,
              tradedAt.timeIntervalSince1970.isFinite, tradedAt <= Date().addingTimeInterval(60) else {
            throw NextError.invalid("成交代码、方向、价格、份额、手续费或成交时间无效")
        }
        if rules[code]?.assetClass == .etf || quotes[code]?.quote.providerInstrumentType == "ETF" {
            guard fee == NextTradeFees.etfPerTrade else { throw NextError.invalid("已核实 ETF 的手续费按每笔 ¥0.10 记录") }
        }
        let gross = price * Decimal(units)
        var updated = book
        let positionIndex = updated.positions.firstIndex { $0.code == code }
        var realized: Decimal = 0
        if side == "buy" {
            guard updated.cash >= gross + fee else {
                let shortfall = gross + fee - updated.cash
                throw NextError.invalid("现金不足：本笔需要 ¥\(NextMoney.text(gross + fee))（含手续费 ¥\(NextMoney.text(fee))），可用 ¥\(NextMoney.text(updated.cash))，还差 ¥\(NextMoney.text(shortfall))。请点「先补充现金」记录一笔转入；若只是补录已有持仓，用「录入持仓」不会动现金。")
            }
            updated.cash -= gross + fee
            if let positionIndex {
                updated.positions[positionIndex].units += units
                updated.positions[positionIndex].bookCost += gross + fee
            } else {
                updated.positions.append(NextPosition(code: code, name: name, units: units, bookCost: gross + fee, acquiredAt: tradedAt))
            }
        } else {
            guard let positionIndex, updated.positions[positionIndex].units >= units else { throw NextError.invalid("卖出份额超过真实账本持有份额") }
            // T+1：今天买入的份额当天不能卖。券商显示「持仓 700 / 可用 400」就是这个意思。
            let available = updated.availableUnits(for: code, at: tradedAt)
            guard units <= available else {
                let locked = updated.lockedUnits(for: code, at: tradedAt)
                throw NextError.invalid("可卖份额不足：持有 \(updated.positions[positionIndex].units) 份，其中今天买入的 \(locked) 份要等下一个交易日才能卖，当前可卖 \(available) 份。")
            }
            let oldUnits = updated.positions[positionIndex].units
            let cost = updated.positions[positionIndex].bookCost * Decimal(units) / Decimal(oldUnits)
            realized = gross - fee - cost
            updated.positions[positionIndex].units -= units
            updated.positions[positionIndex].bookCost -= cost
            if updated.positions[positionIndex].units == 0 { updated.positions.remove(at: positionIndex) }
            updated.cash += gross - fee
        }
        updated.fills.append(NextFill(date: tradedAt, code: code, side: side, units: units, price: price, fee: fee, realized: realized))
        try commitRealLedger(updated, action: side == "buy" ? "记录成交买入" : "记录成交卖出", reason: "用户核对成交；本笔手续费 ¥\(NextMoney.text(fee))")
        // 真实成交是画像的主要证据来源：记完账立刻重算一次，界面上的「AI 对我的了解」同步变化。
        learnProfile()
    }
    func addIncomeEvent(_ event: NextIncomeEvent) throws {
        try event.validate()
        var updated = book
        updated.incomeEvents.append(event)
        try commitRealLedger(updated, action: "新增收益到账计划", reason: "\(event.kind.title) · \(event.name) · 预计净额 ¥\(NextMoney.text(event.netAmount))")
    }
    func receiveIncomeEvent(_ id: UUID) throws {
        guard var event = book.incomeEvents.first(where: { $0.id == id }), event.status == .expected else {
            throw NextError.invalid("这笔收息记录已处理，不能重复入账")
        }
        guard book.cash + event.netAmount >= 0 else { throw NextError.invalid("到账金额无效") }
        let now = Date()
        event.status = .received; event.receivedAt = now
        var updated = book
        guard let index = updated.incomeEvents.firstIndex(where: { $0.id == id }) else { throw NextError.invalid("找不到这笔收息计划") }
        updated.incomeEvents[index] = event
        updated.cash += event.netAmount
        if event.kind == .etfDistribution, let code = event.code, let perUnit = event.perUnit, perUnit > 0 {
            let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); dateFormatter.dateFormat = "yyyy-MM-dd"
            let dividend = NextETFDividendEvent(code: code, date: dateFormatter.string(from: event.exDate ?? now), amountPerShare: perUnit, isEstimated: false)
            updated.dividendEvents.removeAll { $0.id == dividend.id }
            updated.dividendEvents.append(dividend)
        }
        updated.cashMovements.append(NextCashMovement(date: now, amount: event.netAmount, reason: "\(event.kind.title)到账 · \(event.name)"))
        try commitRealLedger(updated, action: "确认收益到账", reason: "\(event.kind.title) · \(event.name) · 税前 ¥\(NextMoney.text(event.grossAmount)) · 税费 ¥\(NextMoney.text(event.tax)) · 净入账 ¥\(NextMoney.text(event.netAmount))")
    }
    func adjustRealCash(_ amount: Decimal, reason: String) throws {
        guard !amount.isNaN, amount != 0, book.cash + amount >= 0 else { throw NextError.invalid("变更金额无效或会导致现金为负") }
        var updated = book
        updated.cash += amount
        updated.cashMovements.append(NextCashMovement(date: Date(), amount: amount, reason: reason))
        try commitRealLedger(updated, action: amount > 0 ? "现金转入" : "现金转出", reason: reason)
    }
    func undoLatestLedgerChange() throws {
        guard let id = ledger.events.last?.id else { throw NextError.invalid("没有可撤销的账本变更") }
        var copy = ledger
        try copy.undo(id, at: Date())
        ledger = copy
    }
    func saveGoal(years: Int, monthlyBudget: Decimal, concentration: Decimal, targetWeights: [String: Decimal] = [:]) throws {
        var updated = goal; updated.years = years; updated.monthlyBudget = monthlyBudget; updated.concentrationLimit = concentration; updated.targetWeights = targetWeights
        try updated.validate(); preferences.goal = updated
    }
    func addWatch(_ code: String) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), !watch.contains(code) else { throw NextError.invalid("请输入有效且尚未关注的 6 位证券代码") }
        preferences.watch.insert(code, at: 0)
        if !preferences.nasBaseURL.isEmpty { Task { await registerNASArchive(code) } }
    }
    func removeWatch(_ code: String) { preferences.watch.removeAll { $0 == code } }
    func openInstrumentIntent(_ code: String) {
        preferences.navigation.selectedSecurity = code
        preferences.navigation.routes = [.intent("buy-opportunity", code)]
        preferences.navigation.selectedTab = .ai
        preferences = preferences
        requestedTab = .ai
        requestedRoute = .decision(code)
        routeRequestID = UUID()
    }
    func saveTheme(_ theme: GPTheme) { preferences.theme = theme }

    /// 跨页签跳转（首页卡片点进去用）：切页签 + 推入一条路由。
    func requestTab(_ tab: NextTab, route: GPRoute?) {
        preferences.navigation.selectedTab = tab
        preferences = preferences
        requestedTab = tab
        requestedRoute = route
        routeRequestID = UUID()
    }

    /// 在当前页签内推入一条路由（首页顶部的搜索/设置入口用）。
    func push(_ route: GPRoute, in tab: NextTab) {
        requestedTab = tab
        requestedRoute = route
        routeRequestID = UUID()
    }
    /// 手动选择五套视觉主题；传 nil 恢复全 App 一致的东方默认主题。
    func saveAppTheme(_ theme: AppTheme?) {
        preferences.themeStyle = theme
        notice = theme.map { "外观主题已切换为「\($0.title)」：只改展示，持仓与 AI 结论不变" } ?? "外观已改为跟随场景：首页编辑室、盘中仪表盘、AI 日报杂志卡片"
    }
    func saveAppearance(_ appearance: GPAppearance) { preferences.appearance = appearance }
    func refreshNotificationStatus() async { notificationStatus = await NextLocalNotificationService.authorizationStatus() }
    func requestNotificationPermission() async { notificationStatus = await NextLocalNotificationService.requestAuthorization() }
    func postLocalAlert(level: String, fingerprint: String, title: String, detail: String, stamp: NextDataStamp) {
        var center = preferences.notifications
        let quiet = center.quietHours.isQuiet(Date())
        let alert = NextAlert(fingerprint: fingerprint, level: level, title: title, detail: detail, createdAt: Date(), stamp: stamp,
                              delivery: quiet ? "静默记录" : "待本机投递")
        guard center.append(alert, now: Date()) else { return }
        preferences.notifications = center; preferences = preferences
        guard !quiet else { return }
        Task {
            let delivery = await NextLocalNotificationService.deliver(id: alert.id, title: title, detail: detail)
            guard let index = preferences.notifications.alerts.firstIndex(where: { $0.id == alert.id }) else { return }
            preferences.notifications.alerts[index].delivery = delivery
            preferences = preferences
        }
    }
    func addPriceAlert(code: String, price: Decimal, direction: NextPriceAlertDirection,
                       metric: NextAlertMetric = .price) throws {
        let duplicated = preferences.notifications.priceRules.contains {
            $0.code == code && $0.price == price && $0.direction == direction && $0.resolvedMetric == metric
        }
        guard code.count == 6, code.allSatisfy(\.isNumber), !duplicated else {
            throw NextError.invalid("提醒代码无效，或相同条件的提醒已存在")
        }
        let rule = NextPriceAlertRule(code: code, name: name(for: code),
                                      price: price, direction: direction, metric: metric)
        try rule.validate()
        preferences.notifications.priceRules.append(rule); preferences = preferences
    }
    func createPatientLimitPlan(code: String, price: Decimal, units: Int, expiresAt: Date) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), expiresAt > Date(),
              !patientLimitPlans.contains(where: { $0.code == code && $0.state == "等待价格提醒" && $0.limitPrice == price && $0.units == units }) else {
            throw NextError.invalid("限价计划代码、有效期无效，或相同计划已经存在")
        }
        var plan = NextPatientLimitPlan(id: UUID(), code: code, name: quotes[code]?.quote.name ?? code,
                                        limitPrice: price, units: units, createdAt: Date(), expiresAt: expiresAt)
        try plan.validate()
        patientLimitPlans.insert(plan, at: 0)
        notice = "耐心限价计划已保存。它只是提醒和研究意图，不会占用现金、模拟成交或提交券商订单。"
    }
    func pausePatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && $0.state == "等待价格提醒" }) else { return }
        patientLimitPlans[index].state = "已暂停"
    }
    func resumePatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && $0.state == "已暂停" && $0.expiresAt > Date() }) else { return }
        patientLimitPlans[index].state = "等待价格提醒"
    }
    func cancelPatientLimitPlan(_ id: UUID) {
        guard let index = patientLimitPlans.firstIndex(where: { $0.id == id && ["等待价格提醒", "已暂停"].contains($0.state) }) else { return }
        patientLimitPlans[index].state = "已撤销"
    }
    private func evaluatePatientLimitPlans(_ values: [NextQuote], now: Date = Date()) {
        var triggered: [(NextPatientLimitPlan, NextQuote)] = []
        var expired: [NextPatientLimitPlan] = []
        for index in patientLimitPlans.indices where patientLimitPlans[index].state == "等待价格提醒" {
            if patientLimitPlans[index].expiresAt <= now {
                patientLimitPlans[index].state = "已过期"
                expired.append(patientLimitPlans[index])
                continue
            }
            guard let quote = values.first(where: { $0.code == patientLimitPlans[index].code }),
                  patientLimitPlans[index].shouldTrigger(with: quote, at: now) else { continue }
            patientLimitPlans[index].state = "价格已触发"
            patientLimitPlans[index].triggeredAt = now
            triggered.append((patientLimitPlans[index], quote))
        }
        for (plan, quote) in triggered {
            postLocalAlert(level: "限价计划", fingerprint: "patient-limit-\(plan.id.uuidString)", title: "\(plan.name) 达到你的观察价",
                           detail: "最新价 ¥\(NextMoney.text(quote.price, digits: 3))，目标 ¥\(NextMoney.text(plan.limitPrice, digits: 3))，计划数量 \(plan.units) 份。仅为提醒，未下单。",
                           stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: .live, detail: "用户耐心限价计划触发"))
        }
        for plan in expired {
            postLocalAlert(level: "限价计划", fingerprint: "patient-limit-expired-\(plan.id.uuidString)", title: "\(plan.name) 观察计划已到期",
                           detail: "目标价 ¥\(NextMoney.text(plan.limitPrice, digits: 3))，计划 \(plan.units) 份。计划已停止，不会下单。",
                           stamp: NextDataStamp(source: "本机计划时钟", observedAt: now, quality: .live, detail: "耐心限价计划到期"))
        }
    }
    // MARK: - AI 今日指导（真实持仓 → 状态 → 策略 → 具体计划）

    /// 生成今日指导：补齐日 K 与分时后，扫描全部真实持仓。
    /// 只读真实账本；不创建模拟账户、不生成虚拟订单、不改变持仓与现金。
    func refreshGuidance() async {
        guard !book.positions.isEmpty else {
            dailyGuidance = nil
            guidanceStatus = "还没有真实持仓：先录入持仓，AI 才能给出基于真实账户的建议"
            return
        }
        guidanceStatus = "正在补齐日 K 与分时数据…"
        await refreshQuotes(codes: book.positions.map(\.code))
        for position in book.positions where position.units > 0 {
            // Cached charts are for display only until refreshed. In particular, a prior
            // session's minute series must never be reused as today's T evidence.
            await refreshDaily(position.code)
            if NextMarketClock.isRegularSession() { await refreshIntraday(position.code) }
        }
        // NAS 长期分时统计是「市场状态 / 做T / 网格区间」的输入之一，
        // 每次生成指导都自动向NAS核对更新；只取压缩研究结果，不拉取整段历史分钟原始数据。
        // NAS离线时 refreshNASResearch 保留已缓存证据并标记状态，但计划仍按时间/质量门槛判断。
        if !preferences.nasBaseURL.isEmpty {
            guidanceStatus = "正在取 NAS 长期分时统计…"
            for position in book.positions where position.units > 0 {
                await refreshNASResearch(position.code)
            }
        }
        // Headlines are refreshed for this guidance run; phone-direct mode does not depend on NAS.
        for position in book.positions where position.units > 0 {
            await refreshNASNews(position.code)
        }
        guidanceStatus = "正在扫描全部持仓…"
        let guidance = buildGuidance(now: Date())
        dailyGuidance = guidance
        guidanceStatus = guidance.summary
        updateDecisionMemory(with: guidance, now: Date())
        evaluateCandidatePlans()
        logGuidanceSuggestions(guidance)
        learnProfile()
    }

    /// 决策记忆：写入「当时」的快照、把同一天重复条目合并、按有效期与失效条件迁移状态、
    /// 并对已真实成交的条目做复盘。这里**不会**因为 AI 建议就写任何成交。
    private func updateDecisionMemory(with guidance: NextDailyGuidance, now: Date) {
        let quoteMap = Dictionary(uniqueKeysWithValues: quotes.map { ($0.key, $0.value.quote) })
        let incoming = NextDecisionMemory.records(from: guidance, quotes: quoteMap, book: book,
                                                  research: nasResearch, news: nasNews, profile: profile)
        var merged = NextDecisionMemory.merge(existing: decisionMemory, incoming: incoming)
        merged = NextDecisionMemory.expire(merged, at: now, quoteFor: { quoteMap[$0]?.price })
        merged = merged.map { record in
            guard record.outcome == .filled, record.review.reviewedAt == nil else { return record }
            var copy = record
            copy.review = NextDecisionMemory.review(record, laterPrice: quoteMap[record.code]?.price, at: now)
            return copy
        }
        if merged != decisionMemory { decisionMemory = merged }
    }

    /// 用户确认「我在券商真的成交了」——只有这一步会写进决策记忆的成交字段。
    /// 账本更新仍然由真实流水入口负责，这里不改持仓、不改现金。
    func confirmDecisionFilled(id: UUID, price: Decimal, units: Int, at now: Date = Date()) {
        guard let index = decisionMemory.firstIndex(where: { $0.id == id }) else { return }
        guard units > 0, price > 0 else { notice = "成交价与份额必须为正值"; return }
        decisionMemory[index].outcome = .filled
        decisionMemory[index].outcomeAt = now
        decisionMemory[index].review.filledPrice = "\(price)"
        decisionMemory[index].review.filledUnits = units
        decisionMemory[index].review.reviewedAt = nil
        notice = "已记录真实成交 \(units) 份 @ ¥\(price)。持仓与现金请在「录入真实成交」里更新。"
    }

    func markDecisionSkipped(id: UUID, at now: Date = Date()) {
        guard let index = decisionMemory.firstIndex(where: { $0.id == id }) else { return }
        decisionMemory[index].outcome = .skipped
        decisionMemory[index].outcomeAt = now
        decisionMemory[index].review.note = "我放弃了这次计划，没有成交"
    }

    private func buildGuidance(now: Date) -> NextDailyGuidance {
        let quoteMap = Dictionary(uniqueKeysWithValues: quotes.map { ($0.key, $0.value.quote) })
        var daily: [String: [NextChartSample]] = [:]
        var intraday: [String: [NextChartSample]] = [:]
        for position in book.positions {
            if let dataset = chartData["\(position.code):day"] { daily[position.code] = dataset.samples }
            if let dataset = chartData[position.code] { intraday[position.code] = dataset.samples }
        }
        return NextOpportunityScanner.scan(book: book, quotes: quoteMap, daily: daily, intraday: intraday,
                                           rules: rules, orderBooks: orderBooks,
                                           goal: goal, nasConfigured: !preferences.nasBaseURL.isEmpty,
                                           nasReachable: nasReachable, nasProbedAt: nasProbedAt,
                                           profile: profile, research: nasResearch, news: nasNews, now: now)
    }

    /// 计划状态自动迁移：过期、行情过期、价格突破作废线，都自动标记并留一条提醒。
    /// 计划永远不能凭旧价格继续挂着。
    func evaluateCandidatePlans(now: Date = Date()) {
        var updates: [String] = []
        for index in candidatePlans.indices {
            let quote = quotes[candidatePlans[index].code]?.quote
            if let change = candidatePlans[index].refresh(quote: quote, now: now) {
                updates.append(change)
                continue
            }
            guard candidatePlans[index].state.isOpen else { continue }
            let plan = candidatePlans[index]
            guard let reason = NextCandidatePlanNewsGuard.invalidationReason(
                for: plan, headlines: nasNews[plan.code] ?? [], now: now) else { continue }
            if let change = candidatePlans[index].invalidate(
                reason: reason, at: now) {
                updates.append(change)
            }
        }
        for line in updates {
            postLocalAlert(level: "AI 候选计划", fingerprint: "candidate-plan-\(UUID().uuidString)", title: line,
                           detail: "计划只是建议：请在券商自行决定是否挂单；成交后回到 App 点「我已成交」再更新账本。",
                           stamp: NextDataStamp(source: "候选计划时钟", observedAt: now, quality: .live, detail: "候选计划状态变化"))
        }
    }

    /// 从今日指导里保存一条候选计划（只是建议，不占资金、不生成虚拟持仓）。
    func saveCandidatePlan(from item: NextGuidanceItem) throws {
        let now = Date()
        var plan: NextCandidatePlan
        if let result = item.tPlan, case let .ready(value) = result {
            let isSell = value.kind == .reverse
            plan = NextCandidatePlan(kind: isSell ? .reverseT : .forwardT, code: value.code, name: value.name,
                                     limitPrice: isSell ? value.sellPrice : value.buyPrice, units: value.units,
                                     createdAt: now, expiresAt: value.validUntil,
                                     triggerNote: isSell
                                        ? "现价达到或高于 ¥\(NextMoney.text(value.sellPrice, digits: 3)) 时按计划卖出 \(value.units) 份（券商手工挂单）"
                                        : "现价达到或低于 ¥\(NextMoney.text(value.buyPrice, digits: 3)) 时按计划买入 \(value.units) 份（券商手工挂单）",
                                     cancelNote: value.cancelConditions.joined(separator: "；"),
                                     quoteSource: value.confidence.quoteSource,
                                     quoteTime: quotes[value.code]?.quote.time,
                                     dailyBarCount: value.confidence.dailyBarCount,
                                     minuteSampleCount: value.confidence.minuteSampleCount,
                                     confidenceLevel: value.confidence.level.rawValue,
                                     rationale: value.evidence.joined(separator: "；"),
                                     expectedNetGain: value.netGain, expectedCostReduction: value.costReductionPerUnit,
                                     riskNote: value.trampleRisk, marketState: item.state.rawValue,
                                     cancelAbove: isSell ? nil : value.sellPrice,
                                     cancelBelow: isSell ? value.buyPrice : nil)
        } else if let result = item.gridPlan, case let .ready(value) = result,
                  let tier = value.tiers.first(where: { $0.side == "buy" }) {
            plan = NextCandidatePlan(kind: .gridBuy, code: value.code, name: value.name,
                                     limitPrice: tier.price, units: tier.units, createdAt: now, expiresAt: value.validUntil,
                                     triggerNote: "现价回落到 ¥\(NextMoney.text(tier.price, digits: 3)) 时按网格计划买入 \(tier.units) 份（券商手工挂单）",
                                     cancelNote: value.pauseConditions.joined(separator: "；"),
                                     quoteSource: value.confidence.quoteSource,
                                     quoteTime: quotes[value.code]?.quote.time,
                                     dailyBarCount: value.confidence.dailyBarCount, minuteSampleCount: 0,
                                     confidenceLevel: value.confidence.level.rawValue,
                                     rationale: (value.reasons + ["网格 \(value.tiers.count) 档，间距 \(String(format: "%.2f", value.spacingPercent))%"]).joined(separator: "；"),
                                     expectedNetGain: nil, expectedCostReduction: nil,
                                     riskNote: value.warnings.joined(separator: "；"), marketState: item.state.rawValue,
                                     cancelAbove: value.upper, cancelBelow: value.lower)
        } else {
            throw NextError.invalid("这只标的当前没有可保存的具体计划；数据不足时只能观察")
        }
        try plan.validate()
        candidatePlans.insert(plan, at: 0)
        linkSuggestionToPlan(plan)
        notice = "候选计划已保存：只是价格建议，未成交前不影响持仓与现金。"
    }

    /// 每次只记录券商实际成交的份额；部分成交继续保留剩余候选份额。
    /// 未成交的候选计划永远不会进入真实流水。
    func confirmCandidatePlan(_ planID: UUID, price: Decimal, units: Int, fee: Decimal,
                              at tradedAt: Date = Date()) throws {
        guard let index = candidatePlans.firstIndex(where: { $0.id == planID }) else {
            throw NextError.invalid("找不到这条候选计划")
        }
        let plan = candidatePlans[index]
        var revised = plan
        try revised.confirmRealFill(price: price, units: units, fee: fee, at: tradedAt, now: Date())
        try recordTrade(code: plan.code, name: plan.name, side: plan.kind.side, units: units, price: price, fee: fee, at: tradedAt)
        candidatePlans[index] = revised
        markSuggestionExecuted(for: revised, price: revised.confirmedPrice ?? price, units: revised.confirmedUnits ?? units)
        notice = "已记录真实成交 \(units) 份；计划剩余 \(candidatePlans[index].remainingUnits) 份。真实持仓、现金与收益已重算。"
        learnProfile()
        Task { await refreshGuidance() }
    }

    /// 统一决策上下文：NAS 长期研究 + 手机离线结论汇总成一份，供在线 AI 综合时引用。
    /// 在线 AI 只能引用候选计划里的价格，不允许自行生成具体挂单价。
    func makeDecisionContext() -> NextDecisionContext {
        let guidance = dailyGuidance ?? buildGuidance(now: Date())
        var researchLines: [String] = []
        var crossMarketLines: [String] = []
        for (code, report) in nasResearch {
            if let stats = report.minuteStats {
                let w20 = stats.window(20)
                let w60 = stats.window(60)
                let w120 = stats.window(120)
                let quality = stats.quality
                researchLines.append("\(NextNameBook.resolve(code))(\(code))：NAS 1分钟档案覆盖 \(stats.days) 日，最后日 \(stats.lastDay ?? "未知")，新鲜度 \(stats.freshness.stale ? "过期" : "有效")；分钟覆盖 \(Int((quality.minuteCoverage * 100).rounded()))%，成交量覆盖 \(Int(((quality.volumeCoverage ?? 0) * 100).rounded()))%，长期可用于精确计划=\(quality.enoughForLongTerm ? "是" : "否")；20日 VWAP \(w20?.vwap ?? "无")、偏离 \(w20?.closeVsVwapPercent.map { String(format: "%+.2f%%", $0) } ?? "无")；60日振幅中位数 \(w60?.amplitudeMedianPercent.map { String(format: "%.2f%%", $0) } ?? "无")、往返 \(w60?.roundTripsMedian.map { String(format: "%.1f", $0) } ?? "无")、VWAP 高低偏离 \(w60?.vwapHighDeviationMedian.map { String(format: "%.3f%%", $0 * 100) } ?? "无")/\(w60?.vwapLowDeviationMedian.map { String(format: "%.3f%%", $0 * 100) } ?? "无")、区间 \(w60?.support ?? "无")–\(w60?.resistance ?? "无")；120日波动率 \(w120?.volatilityPercent.map { String(format: "%.3f%%", $0) } ?? "无")")
            } else {
                researchLines.append("\(NextNameBook.resolve(code))(\(code))：NAS长期分钟统计缺失")
            }
            if let evidence = report.crossMarket {
                let count = evidence.sampleCount.map(String.init) ?? "未知"
                let lag = evidence.bestLagMinutes.map { "，最佳领先 \($0) 分钟" } ?? ""
                let market = evidence.bestMarket.map { "，市场 \($0)" } ?? ""
                let marketState = evidence.currentMarketStatus.map { "，市场状态 \($0)" } ?? ""
                let freshness = evidence.ageSeconds.map { "，最新点距今 \(Int($0))秒" } ?? ""
                let useState = evidence.eligibleForTradingSignal == true
                    ? "已获准进入风险判断，仍需核对当时行情与A股确认"
                    : "仅历史研究候选，尚无预注册未来样本复现；不得作为做T/网格或加仓信号"
                let observations = evidence.liveDivergences ?? []
                let contextNow = Date()
                let observed = observations.filter { $0.state == "observed_divergence" && $0.isFresh(at: contextNow) }
                let staleCount = observations.filter { $0.state == "stale" || !$0.isFresh(at: contextNow) }.count
                let insufficientCount = observations.filter { $0.state == "insufficient_data" }.count
                let divergenceSummary: String
                if observations.isEmpty {
                    divergenceSummary = "实时跨市场背离未提供"
                } else {
                    let examples = observed.prefix(3).map { item in
                        "\(item.market)先行指数 \(item.leaderReturnPercent.map { String(format: "%+.2f%%", $0) } ?? "无") / 持仓 \(item.assetReturnPercent.map { String(format: "%+.2f%%", $0) } ?? "无")"
                    }.joined(separator: "；")
                    divergenceSummary = "15分钟观察：方向背离 \(observed.count) 个来源，过期 \(staleCount)，数据不足 \(insufficientCount)\(examples.isEmpty ? "" : "；" + examples)；仅为同窗价格观察，不是预测或交易信号"
                }
                crossMarketLines.append("\(NextNameBook.resolve(code))(\(code))：\(evidence.state)；样本 \(count)\(lag)\(market)\(marketState)\(freshness)；来源 \(evidence.source ?? "未知")；时间 \(evidence.asOf ?? "未知")；验证 \(evidence.validationState ?? "未知")；\(useState)；\(divergenceSummary)；\(evidence.reason ?? "")")
            } else {
                crossMarketLines.append("\(NextNameBook.resolve(code))(\(code))：NAS未提供跨市场验证结果；不可推断领先关系")
            }
        }
        let reportedCodes = Set(nasResearch.keys)
        for position in book.positions where position.units > 0 && !reportedCodes.contains(position.code) {
            crossMarketLines.append("\(position.name)(\(position.code))：NAS未提供跨市场验证结果；不可推断领先关系")
        }
        let quoteMap = Dictionary(uniqueKeysWithValues: quotes.map { ($0.key, $0.value.quote) })
        let newsLines = book.positions.flatMap { position in
            (nasNews[position.code] ?? []).filter { NextNewsImpactEngine.isFreshPublishedAt($0.publishedAt, now: Date()) }
                .map { "\(position.name)(\(position.code))｜\($0.title)｜来源 \($0.source ?? "未知")｜时间 \($0.publishedAt ?? "未知")｜\($0.url ?? "无链接")" }
        }
        return NextDecisionContextBuilder.build(guidance: guidance, book: book, quotes: quoteMap,
                                                nasResearchLines: researchLines,
                                                crossMarketLines: crossMarketLines,
                                                newsLines: newsLines,
                                                profileLines: NextProfileEngine.promptLines(profile: profile),
                                                now: Date())
    }

    /// 手机是唯一最终顾问：NAS只提供长期证据，在线模型不得另造价格或覆盖规则引擎门槛。
    func runUnifiedMobileAI(key: String, profile modelProfile: String) async {
        guard !book.positions.filter({ $0.units > 0 }).isEmpty else {
            unifiedAIStatus = "没有真实持仓，无法生成持仓指导。"; return
        }
        unifiedAIIsRunning = true
        unifiedAIStatus = "正在汇总真实持仓、最新行情、NAS研究、新闻和投资画像…"
        defer { unifiedAIIsRunning = false }
        await refreshGuidance()
        let context = makeDecisionContext()
        do {
            let response = try await DeepSeekMobile.analyze(prompt: context.promptBlock, key: key, profile: modelProfile)
            unifiedAIAdvice = response.content
            unifiedAIStatus = "手机端统一指导已生成 · \(response.model) · \(context.generatedAt.formatted(date: .numeric, time: .shortened))"
            let stamp = Date()
            let evidence = [
                NextEvidence(id: "unified-guidance-context", title: "统一决策上下文", detail: context.promptBlock, level: "真实持仓 + 手机规则 + NAS + 新闻 + 画像", observedAt: stamp),
                NextEvidence(id: "unified-guidance-ai", title: "手机在线 AI 最终指导", detail: response.content, level: response.model, observedAt: stamp)
            ]
            recordDecision(NextDecision(createdAt: stamp, title: "AI 今日统一指导", evidence: evidence,
                                        options: [], status: "只读建议 · 不会自动下单", origin: "手机最终AI；NAS仅提供研究"))
        } catch {
            unifiedAIStatus = "在线AI不可用：\(error.localizedDescription)；保留手机离线规则结果。"
        }
    }

    /// 持仓问答继续复用同一份手机决策上下文；聊天模型不能另造交易计划或覆盖规则引擎。
    func askUnifiedMobileAI(question: String, recentConversation: String = "",
                            key: String, profile modelProfile: String) async throws -> String {
        guard book.positions.contains(where: { $0.units > 0 }) else {
            throw NextError.invalid("当前没有真实持仓，无法进行持仓顾问问答")
        }
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty, cleanedQuestion.count <= 1200 else {
            throw NextError.invalid("问题不能为空且不能超过 1200 字")
        }
        // 每轮提问都刷新手机行情/日K/新闻和已配置的 NAS 研究；网络失败时保留时间戳明确的本机缓存。
        await refreshGuidance()
        let context = makeDecisionContext()
        let prompt = """
        以下是应用根据真实持仓、手机最新行情、离线规则、NAS长期研究、相关新闻与投资者画像生成的当前统一决策上下文。请先回答用户的问题，若涉及交易，只能解释上下文中已有的候选计划；没有合格计划时明确说数据不足或今天不建议交易。不得自行生成价格、份额、收益、交易规则或成交事实。

        \(context.promptBlock)

        最近对话（仅用于理解追问，不作为账户事实）：
        \(recentConversation.suffix(5000))

        用户问题：
        \(cleanedQuestion)
        """
        let response = try await DeepSeekMobile.analyze(prompt: prompt, key: key, profile: modelProfile)
        return response.content
    }

    // MARK: - 动态投资者画像

    /// 从「真实持仓 + 真实成交 + 真实反馈」重新学习。绝不使用虚拟交易，也不因一次异常成交改写长期结论。
    func learnProfile(now: Date = Date()) {
        var quoteMap: [String: NextQuote] = [:]
        for (code, cached) in quotes { quoteMap[code] = cached.quote }
        var daily: [String: [NextChartSample]] = [:]
        for position in book.positions {
            if let dataset = chartData["\(position.code):day"] { daily[position.code] = dataset.samples }
        }
        let updated = NextProfileEngine.learn(book: book, goal: goal, quotes: quoteMap,
                                              suggestions: suggestions, plans: candidatePlans,
                                              daily: daily, previous: profile, now: now)
        if updated != profile { profile = updated }
    }

    /// 把今日指导里真正可执行的机会落成一条轨迹。同一标的同一天同类型只记一次，避免刷新一次就刷一条。
    func logGuidanceSuggestions(_ guidance: NextDailyGuidance, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var added = 0
        for item in guidance.items where item.isActionable {
            if let tResult = item.tPlan, case let .ready(plan) = tResult {
                let kind: NextPlanKind = plan.kind == .reverse ? .reverseT : .forwardT
                let duplicated = suggestions.contains {
                    $0.code == item.code && $0.kind == kind && calendar.isDate($0.createdAt, inSameDayAs: now)
                }
                if duplicated { continue }
                suggestions.append(NextSuggestionRecord(code: item.code, name: item.name, kind: kind,
                                                       expectedNetGain: plan.netGain,
                                                       expectedSpreadPercent: NextProfileEngine.spreadPercent(sell: plan.sellPrice, buy: plan.buyPrice),
                                                       expectedCostReduction: plan.costReductionPerUnit,
                                                       confidenceLevel: plan.confidence.level.rawValue,
                                                       marketState: item.state.rawValue, createdAt: now,
                                                       expiresAt: plan.validUntil))
                added += 1
            } else if let gResult = item.gridPlan, case let .ready(grid) = gResult {
                let duplicated = suggestions.contains {
                    $0.code == item.code && $0.kind == .gridBuy && calendar.isDate($0.createdAt, inSameDayAs: now)
                }
                if duplicated { continue }
                suggestions.append(NextSuggestionRecord(code: item.code, name: item.name, kind: .gridBuy,
                                                       expectedNetGain: nil,
                                                       expectedSpreadPercent: grid.spacingPercent,
                                                       expectedCostReduction: nil,
                                                       confidenceLevel: grid.confidence.level.rawValue,
                                                       marketState: item.state.rawValue, createdAt: now,
                                                       expiresAt: grid.validUntil))
                added += 1
            }
        }
        // 过了有效期、既没保存成计划也没成交 → 记「看了没做」，这是做 T 偏好最重要的一类样本。
        for index in suggestions.indices where suggestions[index].outcome == .pending {
            if now > suggestions[index].expiresAt, suggestions[index].savedPlanID == nil {
                suggestions[index].outcome = .ignored
            }
        }
        // 只保留近 180 天轨迹，避免文件无限增长
        let cutoff = now.addingTimeInterval(-180 * 86_400)
        if suggestions.contains(where: { $0.createdAt < cutoff }) {
            suggestions = suggestions.filter { $0.createdAt >= cutoff }
        }
        if added > 0 { notice = "今日新增 \(added) 条机会记录（只用于让 AI 越来越懂你，不构成下单）" }
    }

    /// 用户打开过计划详情 → 之后没做才算「看了没做」，不能把没看到也算成不感兴趣。
    func markPlanViewed(_ planID: UUID, now: Date = Date()) {
        guard let index = candidatePlans.firstIndex(where: { $0.id == planID }) else { return }
        if candidatePlans[index].viewedAt == nil { candidatePlans[index].viewedAt = now }
        if let sIndex = suggestions.firstIndex(where: { $0.savedPlanID == planID }) {
            if suggestions[sIndex].viewedAt == nil { suggestions[sIndex].viewedAt = now }
        }
    }

    /// 一键反馈：进入画像学习，但不直接修改任何价格或计划。
    func recordPlanFeedback(_ planID: UUID, kind: NextPlanFeedbackKind, note: String? = nil, now: Date = Date()) {
        guard let index = candidatePlans.firstIndex(where: { $0.id == planID }) else { return }
        candidatePlans[index].feedback = NextPlanFeedback(kind: kind, note: note, createdAt: now)
        if let sIndex = suggestions.firstIndex(where: { $0.savedPlanID == planID }) {
            suggestions[sIndex].feedback = candidatePlans[index].feedback
            if !kind.isPositive && suggestions[sIndex].outcome == .pending {
                suggestions[sIndex].outcome = kind.impliesHoldPreference ? .ignored : .rejected
            }
        }
        notice = "已记录你的反馈：AI 会据此调整以后推荐什么、不推荐什么（不会改变行情判断）"
        learnProfile(now: now)
    }

    /// 把保存下来的候选计划与建议轨迹连起来，画像才能判断「这条建议最后有没有被执行」。
    func linkSuggestionToPlan(_ plan: NextCandidatePlan, now: Date = Date()) {
        if let index = suggestions.firstIndex(where: { $0.savedPlanID == nil && $0.code == plan.code && $0.kind == plan.kind }) {
            suggestions[index].savedPlanID = plan.id
            if suggestions[index].outcome == .pending { suggestions[index].outcome = .saved }
        }
    }

    private func markSuggestionExecuted(for plan: NextCandidatePlan, price: Decimal, units: Int) {
        guard let index = suggestions.firstIndex(where: { $0.savedPlanID == plan.id })
                ?? suggestions.firstIndex(where: { $0.code == plan.code && $0.kind == plan.kind }) else { return }
        suggestions[index].outcome = .executed
        suggestions[index].executedAt = Date()
        suggestions[index].executedPrice = price
        suggestions[index].executedUnits = units
        suggestions[index].savedPlanID = plan.id
        suggestions[index].priceEdited = plan.priceWasEdited
        suggestions[index].unitsEdited = plan.unitsWereEdited
    }

    // MARK: 画像的「用户最终控制权」

    /// 用户明确改一项：立刻变成 Explicit Preference 并锁定，学习引擎不再覆盖。
    func setProfileTrait(_ id: NextProfileTraitID, value: String, label: String, detail: String,
                         numeric: Double? = nil, lock: Bool = true, now: Date = Date()) {
        var trait = profile.trait(id) ?? NextProfileTrait(id: id, value: value, label: label, detail: detail,
                                                          confidence: 1, sampleCount: 1, windowDays: 0,
                                                          source: .explicit, locked: true, basis: [],
                                                          updatedAt: now, numeric: numeric)
        trait.value = value
        trait.label = label
        trait.detail = detail
        trait.source = .explicit
        trait.locked = lock
        trait.confidence = 1
        trait.updatedAt = now
        if let numeric { trait.numeric = numeric }
        trait.basis = ["你在「AI 对我的了解」里手动设定（\(Self.stamp(now))）"]
        if id == .minSpread, let numeric { profile.thresholds.minTSpreadPercent = numeric }
        if id == .minNetGain, let numeric { profile.thresholds.minTNetGain = numeric }
        if id == .gridTiers, let numeric { profile.thresholds.gridMaxTiers = Int(numeric.rounded()) }
        if id == .tAppetite, value == "none" { profile.thresholds.tTradeFrequencyCap = 0 }
        profile.setTrait(trait)
        notice = "已更新「\(id.title)」：这是你明确设定的规则，AI 不会自行改动"
    }

    /// 用户说「这个判断不准确」→ 置信度清零并冷却 30 天，不用一次否认就永久删掉结论。
    func markProfileTraitInaccurate(_ id: NextProfileTraitID, now: Date = Date()) {
        guard var trait = profile.trait(id) else { return }
        trait.confidence = 0
        trait.mutedUntil = now.addingTimeInterval(30 * 86_400)
        trait.basis = ["你标记过「这个判断不准确」，30 天内不再学习这一项（\(Self.stamp(now))）"]
        trait.detail = "你标记过这个判断不准确，AI 会暂停这一项的推断，先按默认门槛处理"
        profile.setTrait(trait)
        notice = "已暂停学习「\(id.title)」30 天：期间这一项不参与排序"
    }

    /// 重新学习：清掉所有「学习得到」的结论，保留用户明确设定与锁定的规则。
    func resetProfileLearning(now: Date = Date()) {
        var fresh = NextInvestorProfile()
        for (key, trait) in profile.traits where trait.locked || trait.source == .explicit {
            fresh.traits[key] = trait
        }
        fresh.instrumentRoles = profile.instrumentRoles.filter { $0.value.locked || $0.value.source == .explicit }
        fresh.updatedAt = now
        profile = fresh
        learnProfile(now: now)
        notice = "已重置 AI 学习结果：你明确设定的规则和锁定的标的保持不变"
    }

    /// 用户指定「这只是长期核心仓 / 行业机动仓」→ 学习不会再改它。
    func setInstrumentRole(_ code: String, role: NextInstrumentRole.Role, lock: Bool = true, now: Date = Date()) {
        var entry = NextInstrumentRole()
        entry.role = role
        entry.source = .explicit
        entry.locked = lock
        entry.reason = "你在持仓里手动标记为\(role.rawValue)，AI 学习不会覆盖"
        entry.updatedAt = now
        profile.instrumentRoles[code] = entry
        notice = "已把 \(name(for: code)) 标记为\(role.rawValue)：做 T / 网格建议会按这个身份重新判断"
        learnProfile(now: now)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func removePriceAlert(_ id: UUID) { preferences.notifications.priceRules.removeAll { $0.id == id }; preferences = preferences }
    private func evaluatePriceAlerts(_ values: [NextQuote]) {
        var rules = preferences.notifications.priceRules
        var triggered: [(NextPriceAlertRule, NextQuote)] = []
        for quote in values where quote.isFresh(at: Date()) {
            for index in rules.indices where rules[index].enabled && rules[index].code == quote.code {
                guard let current = rules[index].value(for: quote) else { continue }
                let match = rules[index].direction == .atOrAbove ? current >= rules[index].price : current <= rules[index].price
                if match && !rules[index].isInsideTrigger { triggered.append((rules[index], quote)) }
                rules[index].isInsideTrigger = match
            }
        }
        preferences.notifications.priceRules = rules; preferences = preferences
        for (rule, quote) in triggered {
            let relation = rule.direction == .atOrAbove ? "达到或高于" : "达到或低于"
            let metric = rule.resolvedMetric
            let current = rule.value(for: quote) ?? quote.price
            let currentText = metric == .price ? "¥\(NextMoney.text(current, digits: 3))" : "\(NextNum.signed(NextNum.double(current)))%"
            let thresholdText = metric == .price ? "¥\(NextMoney.text(rule.price, digits: 3))" : "\(NextNum.signed(NextNum.double(rule.price)))%"
            let title = metric == .price ? "\(rule.name) 价格提醒" : "\(rule.name) \(metric.title)提醒"
            postLocalAlert(level: metric.title, fingerprint: "price-rule-\(rule.id.uuidString)", title: title,
                           detail: "当前\(metric.title) \(currentText)，已\(relation)你设置的 \(thresholdText)。",
                           stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: .live, detail: "\(metric.title)规则触发"))
        }
    }
    func configureNAS(baseURL: String) throws {
        let normalized = try NextNASService.validateURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if preferences.nasBaseURL != normalized { preferences.nasRevision = nil }
        preferences.nasBaseURL = normalized; preferences = preferences
        nasReachable = nil
        nasProbedAt = nil
        syncStatus = "NAS 地址已保存；请测试连接"
    }
    func configureLegacyWeb(baseURL: String) throws {
        let normalized = try NextNASService.validateLegacySourceURL(baseURL).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        preferences.legacyWebBaseURL = normalized; preferences = preferences
    }
    private func requireEmptyNativeLedger() throws {
        guard book.cash == 0, book.positions.isEmpty, book.fills.isEmpty, book.cashMovements.isEmpty,
              book.incomeEvents.isEmpty, book.dividendEvents.isEmpty, book.history.isEmpty else {
            throw NextError.invalid("本机真实账本已有资产或流水。旧账本迁移只允许初始化空账本，不会覆盖或合并现有真实数据。")
        }
    }
    func downloadLegacyWebToPhone() async {
        do {
            try requireEmptyNativeLedger()
            let destination = try await NextNASService.readStatus(baseURL: preferences.nasBaseURL)
            guard !destination.hasBook && destination.revision == 0 else { throw NextError.invalid("新版 NAS 已有真实账本；迁移只允许用于初始化，不会覆盖现有账本。") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；迁移已停止") }
            let stagedRevision = try await NextNASService.downloadAndStageLegacyBook(legacyBaseURL: preferences.legacyWebBaseURL, newNASBaseURL: preferences.nasBaseURL)
            let preview = try await NextNASService.previewLegacyBook(baseURL: preferences.nasBaseURL)
            guard preview.revision == stagedRevision, let book = preview.book else { throw NextError.invalid("迁移暂存版本与预览不一致") }
            try book.validate()
            legacyImportPreview = preview
            syncStatus = "旧网页数据已下载并转换预览 · 暂存修订 \(preview.revision) · 尚未导入真实账本"
        } catch { legacyImportPreview = nil; syncStatus = "旧网页下载/转换失败 · \(error.localizedDescription)" }
    }
    func confirmLegacyWebImport() async {
        guard let preview = legacyImportPreview, let incoming = preview.book else { return }
        let originalBook = book
        let baseURL = preferences.nasBaseURL
        do {
            try requireEmptyNativeLedger()
            let latest = try await NextNASService.previewLegacyBook(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在迁移确认期间发生变化；请重新连接并下载预览") }
            guard latest.revision == preview.revision else { throw NextError.invalid("迁移预览版本已变化；请重新下载核对") }
            let destination = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在迁移确认期间发生变化；未导入本机账本") }
            guard !destination.hasBook && destination.revision == 0 else { throw NextError.invalid("新版 NAS 已有真实账本；为避免覆盖，导入已取消") }
            guard book == originalBook else { throw NextError.invalid("预览期间本机账本发生变化；迁移已停止，请重新核对") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；导入已停止") }
            try repository.writeSafetyCopy(try makeBackup())
            try commitRealLedger(incoming, action: "从旧网页转换导入", reason: "用户确认旧账本迁移修订 \(preview.revision)；导入前已备份")
            if let watchCodes = preview.summary?.watchCodes {
                var seen = Set<String>()
                let valid = watchCodes.filter { $0.count == 6 && $0.allSatisfy(\.isNumber) && seen.insert($0).inserted }
                if !valid.isEmpty { preferences.watch = valid }
            }
            let revision = try await NextNASService.pushBook(incoming, expectedRevision: destination.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                legacyImportPreview = nil
                syncStatus = "手机已完成导入；原 NAS 已初始化为修订 \(revision)，设置地址随后发生改变，请重新检查新 NAS。"
                return
            }
            preferences.nasRevision = revision; preferences = preferences
            legacyImportPreview = nil
            syncStatus = "旧账本已导入手机并初始化新版 NAS · NAS 修订 \(revision) · \(preview.summary?.positions ?? 0) 只持仓、\(preview.summary?.fills ?? 0) 条流水"
        } catch {
            syncStatus = "迁移未完成 · \(error.localizedDescription)"
            errorMessage = "若本机账本已导入而 NAS 上传失败，手机数据保留且有恢复副本；连接恢复后可手动上传本机账本。"
        }
    }
    func cancelLegacyWebImport() { legacyImportPreview = nil }
    func probeNAS(notifyOnFailure: Bool = true) async {
        let baseURL = preferences.nasBaseURL
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nasReachable = nil
            nasProbedAt = nil
            syncStatus = "NAS 未配置"
            return
        }
        do {
            _ = try await NextNASService.checkHealth(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { return }
            nasReachable = true
            nasProbedAt = Date()
            syncStatus = "NAS 在线 · 健康检查通过"
        } catch {
            guard preferences.nasBaseURL == baseURL else { return }
            nasReachable = false
            nasProbedAt = Date()
            syncStatus = "NAS 离线或健康检查失败 · \(error.localizedDescription)"
            if notifyOnFailure {
                postLocalAlert(level: "NAS", fingerprint: "nas-connectivity", title: "NAS 连接不可用", detail: "\(error.localizedDescription)。本机账本和缓存仍可使用。", stamp: NextDataStamp(source: "NAS 连通性检查", observedAt: Date(), quality: .stale, detail: "用户触发检查"))
            }
            return
        }
    }
    func downloadBookManually() async {
        let originalBook = book
        let baseURL = preferences.nasBaseURL
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在下载过程中发生变化；未写入本机账本") }
            guard book == originalBook else { throw NextError.invalid("本机账本在下载过程中发生变化；为避免覆盖，下载已取消") }
            guard let incoming = remote.book else { throw NextError.invalid("NAS 上还没有可下载的新账本") }
            guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；下载已停止") }
            try repository.writeSafetyCopy(try makeBackup())
            try commitRealLedger(incoming, action: "从 NAS 下载真实账本", reason: "用户确认下载 NAS 修订 \(remote.revision)；原账本已备份")
            preferences.nasRevision = remote.revision
            preferences.nasSyncedFingerprint = incoming.syncFingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = "已从 NAS 下载账本 · 修订 \(remote.revision)"
        } catch { syncStatus = "下载停止 · \(error.localizedDescription)" }
    }
    /// 手动上传。`force = true` 时跳过"本机记录的修订必须等于 NAS 修订"的检查，
    /// 直接用刚读到的远端修订号覆盖 —— 这是修订号走岔（恢复过备份、换过手机、
    /// NAS 被网页端写过）之后唯一的出路，否则会永远卡在"请先下载核对"。
    func syncBookManually(force: Bool = false) async {
        let snapshot = book
        let baseURL = preferences.nasBaseURL
        let knownRevision = preferences.nasRevision
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址在同步过程中发生变化；本次未上传") }
            guard book == snapshot, preferences.nasRevision == knownRevision else { throw NextError.invalid("本机账本或同步修订在连接期间发生变化；请重新核对后同步") }
            if !force {
                if let knownRevision {
                    guard remote.revision == knownRevision else { throw NextError.invalid("NAS 修订已变为 \(remote.revision)（本机记录 \(knownRevision)）；请先下载核对，或用「强制覆盖」") }
                } else {
                    guard remote.revision == 0 && !remote.hasBook else { throw NextError.invalid("NAS 已有账本但本机没有同步记录；请先下载核对，或用「强制覆盖」") }
                }
            }
            let revision = try await NextNASService.pushBook(snapshot, expectedRevision: remote.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                syncStatus = "已写入原 NAS 修订 \(revision)，但设置中的 NAS 地址已更改；新地址修订未修改，请重新检查连接。"
                return
            }
            preferences.nasRevision = revision
            preferences.nasSyncedFingerprint = snapshot.syncFingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = book == snapshot ? "用户确认上传完成 · 修订 \(revision)" : "NAS 已保存快照修订 \(revision)；上传期间本机账本有新变化，请再次同步。"
        } catch { syncStatus = "上传停止 · \(error.localizedDescription)" }
    }
    // MARK: - 账本上传状态

    /// 本机账本是否有改动还没上传到 NAS。按内容指纹判断，而不是"上次点没点过上传"。
    var hasPendingUpload: Bool {
        guard !preferences.nasBaseURL.isEmpty else { return false }
        return preferences.nasSyncedFingerprint != book.syncFingerprint
    }

    /// 给界面用的一句话状态：到底同步过没有、什么时候、修订几。
    var syncStateText: String {
        guard !preferences.nasBaseURL.isEmpty else { return "未配置 NAS" }
        if hasPendingUpload { return "有改动待上传" }
        if let revision = preferences.nasRevision, let at = preferences.nasSyncedAt {
            return "已同步 · 修订 \(revision) · \(at.formatted(date: .omitted, time: .shortened))"
        }
        if let revision = preferences.nasRevision { return "已同步 · 修订 \(revision)" }
        return "尚无同步记录"
    }

    /// 改账本后延迟 3 秒合并上传：连续录入不会每敲一下就打一次 NAS。
    private func scheduleAutoUpload() {
        guard preferences.nasAutoUpload, !preferences.nasBaseURL.isEmpty else { return }
        autoUploadTask?.cancel()
        autoUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.autoUploadBookIfNeeded()
        }
    }

    /// 自动上传。三条硬规矩：
    /// 1. 只在有未上传改动时才发；
    /// 2. 修订号对不上（NAS 被别人写了）**不覆盖**，只把状态说清楚；
    /// 3. 上传成功后把内容指纹记下来，界面才能显示"已同步"。
    func autoUploadBookIfNeeded() async {
        guard preferences.nasAutoUpload, !preferences.nasBaseURL.isEmpty else { return }
        guard hasPendingUpload else { return }
        let snapshot = book
        let fingerprint = snapshot.syncFingerprint
        let baseURL = preferences.nasBaseURL
        do {
            let remote = try await NextNASService.readStatus(baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL, book.syncFingerprint == fingerprint else { return }
            if let known = preferences.nasRevision {
                guard remote.revision == known else {
                    syncStatus = "未自动上传 · NAS 修订已变为 \(remote.revision)（本机记录 \(known)）；请先下载核对，不覆盖"
                    return
                }
            } else {
                guard remote.revision == 0 && !remote.hasBook else {
                    syncStatus = "未自动上传 · NAS 上已有账本但本机没有同步记录；请先下载核对"
                    return
                }
            }
            let revision = try await NextNASService.pushBook(snapshot, expectedRevision: remote.revision, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else { return }
            preferences.nasRevision = revision
            preferences.nasSyncedFingerprint = fingerprint
            preferences.nasSyncedAt = Date()
            preferences = preferences
            syncStatus = book.syncFingerprint == fingerprint
                ? "已自动上传 · 修订 \(revision) · \(Date.now.formatted(date: .omitted, time: .shortened))"
                : "已上传修订 \(revision)；之后又有新改动，稍后自动再传"
        } catch {
            syncStatus = "自动上传失败 · \(error.localizedDescription)（本机账本未受影响）"
        }
    }

    func chartState(for code: String) -> NextChartState { preferences.navigation.chartStates[code] ?? NextChartState() }
    func saveChartState(_ state: NextChartState, for code: String) {
        preferences.navigation.chartStates[code] = state
        preferences.navigation.selectedSecurity = code
        preferences = preferences
    }
    func saveNavigationPath(_ routes: [NextRoute], for tab: NextTab) {
        preferences.navigation.tabRoutes[tab.rawValue] = routes
        preferences.navigation.routes = routes
        preferences = preferences
    }
    func recordDecision(_ decision: NextDecision) {
        decisions.removeAll { $0.id == decision.id }
        decisions.insert(decision, at: 0)
        if decisions.count > 1000 { decisions.removeLast(decisions.count - 1000) }
    }
    func chooseDecision(_ decisionID: UUID, optionID: String) throws {
        guard let index = decisions.firstIndex(where: { $0.id == decisionID }), decisions[index].options.contains(where: { $0.id == optionID }) else {
            throw NextError.invalid("决策或方案已不存在；没有保存选择")
        }
        decisions[index].selectedOption = optionID
        decisions[index].status = "已记录选择"
    }
    func reviewDecision(_ decisionID: UUID, note: String) throws {
        guard let index = decisions.firstIndex(where: { $0.id == decisionID }), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NextError.invalid("请选择一条决策并填写复盘记录")
        }
        decisions[index].review = note
        decisions[index].status = "已复盘"
    }
    func acceptQuote(_ quote: NextCachedQuote) throws {
        try validateQuote(quote)
        quotes[quote.quote.code] = quote
    }
    private func validateQuote(_ quote: NextCachedQuote) throws {
        guard quote.quote.price > 0, quote.quote.previousClose > 0, quote.quote.iopv.map({ $0 > 0 && quote.quote.providerInstrumentType == "ETF" }) ?? true,
              quote.quote.time <= Date(), quote.quote.code == quote.quote.id, !quote.quote.source.isEmpty else { throw NextError.invalid("行情时间、价格、IOPV 或来源校验失败") }
    }
    func refreshQuotes(codes: [String]) async {
        let unique = Array(Set(codes)).sorted()
        guard !unique.isEmpty else { status = "先添加自选或持仓证券"; return }
        status = "正在核验行情…"
        do {
            var sourceNote = ""
            var skippedStale = 0
            let fetched: [NextQuote]
            if preferences.marketSourceMode == .phoneDirect {
                let direct = try await NextMarketDataService.fetchQuotes(codes: unique)
                fetched = direct.value
                sourceNote = "手机直连 · \(direct.source)"
            } else if preferences.marketSourceMode == .nasOnly {
                guard !preferences.nasBaseURL.isEmpty else {
                    throw NextError.invalid("行情来源设为仅使用NAS，但尚未配置NAS地址")
                }
                fetched = try await NextNASService.fetchQuotes(codes: unique, baseURL: preferences.nasBaseURL)
                sourceNote = "NAS行情（仅NAS模式）"
            } else if !preferences.nasBaseURL.isEmpty {
                do {
                    fetched = try await NextNASService.fetchQuotes(codes: unique, baseURL: preferences.nasBaseURL)
                    sourceNote = "NAS行情"
                } catch {
                    let direct = try await NextMarketDataService.fetchQuotes(codes: unique)
                    fetched = direct.value
                    sourceNote = "NAS不可用 · \(direct.source)手机备用"
                }
            } else {
                let direct = try await NextMarketDataService.fetchQuotes(codes: unique)
                fetched = direct.value
                sourceNote = "手机直连 · \(direct.source)"
            }
            var updated = quotes
            var updatedRules = rules
            var accepted: [NextQuote] = []
            for quote in fetched {
                // 旧数据不覆盖新数据：缓存里已有不早于本次的报价时，保留原值。
                if let cached = quotes[quote.code], cached.quote.time >= quote.time {
                    skippedStale += 1
                    continue
                }
                let quality: NextDataQuality = quote.isFresh(at: Date()) ? .live : .delayed
                let cached = NextCachedQuote(quote: quote, stamp: NextDataStamp(source: quote.source, observedAt: quote.time, quality: quality, detail: "按行情源时间标记；未补造 IOPV"))
                try validateQuote(cached)
                updated[quote.code] = cached
                accepted.append(quote)
                if quote.providerInstrumentType == "ETF" {
                    let market = quote.code.hasPrefix("15") ? "SZSE" : "SSE"
                    if let rule = NextInstrumentRules.verifiedETFMarketRule(code: quote.code, market: market) {
                        updatedRules[quote.code] = rule
                    }
                }
            }
            quotes = updated
            rules = updatedRules
            // 名称随报价一起收进名称簿：这样流水、提醒、分红里只存了代码的位置也能显示名字。
            recordDailySnapshotIfNeeded()
            NextNameBook.remember(pairs: accepted.compactMap { quote in
                let name = quote.name.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : (code: quote.code, name: name)
            })
            evaluatePriceAlerts(accepted)
            evaluatePatientLimitPlans(accepted)
            evaluateCandidatePlans()
            var staleNote = skippedStale > 0 ? " · \(skippedStale) 只保留较新缓存" : ""
            status = "行情已更新 · \(sourceNote) · \(accepted.count)/\(unique.count)\(staleNote) · \(Date.now.formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "行情连接失败 · 显示本地缓存"
            errorMessage = "\(error.localizedDescription)。本地账本和历史缓存仍可查看。"
            postLocalAlert(level: "行情", fingerprint: "market-refresh-unavailable", title: "行情刷新失败", detail: "\(error.localizedDescription)。当前显示本机缓存，不据此生成新的价格计划。", stamp: NextDataStamp(source: "行情刷新", observedAt: Date(), quality: .stale, detail: "请求失败"))
        }
    }
    /// 每个「收盘后」留一条资产快照。
    ///
    /// 之前 `book.history` 没有任何写入路径 —— 界面上有「区间收益 / 年化 / 基准对比」，
    /// 但永远显示"快照不足"，因为从来没人写。这里按天补齐：同一天只留一条，
    /// 取收盘后的总资产，出入金单独记在 externalFlow 里供区间收益剔除。
    func recordDailySnapshotIfNeeded() {
        guard !book.positions.isEmpty else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        // 盘中不记：总资产每 10 秒都在变，记下来只是噪音；收盘后再落一条。
        if NextMarketClock.isRegularSession(now) { return }
        if let last = book.history.last, calendar.isDate(last.date, inSameDayAs: now) { return }
        let summary = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .diluted)
        guard summary.isComplete, summary.totalValue > 0 else { return }
        let flow = book.cashMovements
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(Decimal.zero) { $0 + $1.amount }
        var updated = book
        updated.history.append(NextAssetPoint(date: calendar.startOfDay(for: now), total: summary.totalValue, externalFlow: flow))
        if updated.history.count > 750 { updated.history.removeFirst(updated.history.count - 750) }
        try? commitRealLedger(updated, action: "记录当日资产快照", reason: "收盘后总资产，用于区间收益")
    }

    /// 只刷新分时（不碰日 K 与 NAS 档案注册），用于盘中每隔一分钟补一次曲线。
    /// 行情来源严格跟随用户选择；NAS直连失败时只有“NAS优先”模式才回退手机源。
    func refreshIntraday(_ code: String) async {
        do {
            let fetched: NextChartDataset
            switch preferences.marketSourceMode {
            case .phoneDirect:
                let direct = try await NextMarketDataService.fetchIntraday(code: code)
                fetched = direct.value
            case .nasOnly:
                guard !preferences.nasBaseURL.isEmpty else { throw NextError.invalid("行情来源设为仅使用NAS，但尚未配置NAS地址") }
                fetched = try await NextNASService.fetchMinute(code: code, day: Date(), baseURL: preferences.nasBaseURL)
            case .nasPreferred:
                if !preferences.nasBaseURL.isEmpty {
                    do { fetched = try await NextNASService.fetchMinute(code: code, day: Date(), baseURL: preferences.nasBaseURL) }
                    catch {
                        let direct = try await NextMarketDataService.fetchIntraday(code: code)
                        fetched = direct.value
                    }
                } else {
                    let direct = try await NextMarketDataService.fetchIntraday(code: code)
                    fetched = direct.value
                }
            }
            let dataset = quotes[code].map { fetched.attachingVerifiedIOPV($0.quote) } ?? fetched
            try dataset.validate()
            chartData[code] = dataset
            status = "分时已更新 · \(dataset.priceSource) · \(dataset.samples.count)点 · \(dataset.observedAt.formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "分时更新失败 · 按来源设置保留本机缓存 · \(error.localizedDescription)"
        }
    }

    func refreshInstrument(_ code: String) async {
        await registerNASArchive(code)
        await refreshQuotes(codes: [code])
        await refreshDaily(code)
        await refreshIntraday(code)
    }
    func refreshDividendHistory(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do {
            let events = try await NextNASService.fetchDividendEvents(code: code, baseURL: preferences.nasBaseURL)
            dividendEvents[code] = events
        } catch {
            // The last verified local cache remains visible when NAS or upstream is offline.
            if dividendEvents[code] == nil && book.dividendEvents.filter({ $0.code == code }).isEmpty {
                notice = "分红历史暂不可更新；本机已有记录仍可查看，推算事件不会计入已收现金。"
            }
        }
    }
    /// 派息自动化：批量拉取派息历史，并按已确认派息自动登记「待收」记录。
    ///
    /// 只登记：已实施（isEstimated != true）、除息日已过且在近 400 天内、
    /// 且本机尚未登记过的派息。登记出来的是 `status == .expected` 的待确认记录，
    /// **不会自动往现金里加钱** —— 实际到账金额以券商为准，仍需点一次确认；
    /// 这样既有自动记录，又不会把「估算的派息」冒充成「已到账的现金」。
    func syncAllDividendHistory() async {
        let codes = Array(Set(book.positions.map(\.code) + preferences.watch)).sorted()
        guard !codes.isEmpty else { return }
        if !preferences.nasBaseURL.isEmpty {
            for code in codes { await refreshDividendHistory(code) }
        }
        registerAutomaticDividendDrafts()
    }

    /// 自动按持仓份额登记「派息待收」。
    /// 关键规则：只登记**建仓日（acquiredAt）及之后**的派息。建仓日之前的除息不算你的——
    /// 你录入一只早已分红过的票时，不该凭空冒出历史分红待确认。没有建仓日的老持仓会先用
    /// 「最早流水日 / 迁移日」兜底一次（幂等、结果稳定，不会每天重写）。
    func registerAutomaticDividendDrafts() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let todayText = formatter.string(from: today)
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -400, to: today) else { return }
        let cutoffText = formatter.string(from: cutoff)

        var updated = book

        // 1) 一次性迁移：没有建仓日的持仓，用「最早流水日」或「迁移日」兜底。
        var migratedCount = 0
        for idx in updated.positions.indices where updated.positions[idx].units > 0 && updated.positions[idx].acquiredAt == nil {
            let code = updated.positions[idx].code
            let earliestFill = updated.fills.filter { $0.code == code }.map { $0.date }.min()
            if let anchor = earliestFill ?? book.importedAt {
                updated.positions[idx].acquiredAt = anchor
                migratedCount += 1
            }
        }

        // 2) 每只持仓的分红门槛：建仓日；没有则用今天（只看未来，符合「以后的只是以后的」）。
        var thresholdByCode: [String: String] = [:]
        for p in updated.positions where p.units > 0 {
            thresholdByCode[p.code] = p.acquiredAt.map { formatter.string(from: $0) } ?? todayText
        }

        // 3) 清理门槛之前的自动登记草稿，避免历史分红伪待收。
        var removed: [String] = []
        updated.incomeEvents.removeAll { ev in
            guard ev.status == .expected, ev.note.hasPrefix("自动登记|"), let code = ev.code,
                  let threshold = thresholdByCode[code] else { return false }
            let parts = ev.note.split(separator: "|")
            guard parts.count >= 3 else { return false }
            let evDate = String(parts[2])
            if evDate < threshold { removed.append("\(ev.name) \(evDate)"); return true }
            return false
        }

        // 4) 登记门槛之后、cutoff 之前已实施的派息。
        var added: [String] = []
        for position in updated.positions where position.units > 0 {
            guard let threshold = thresholdByCode[position.code] else { continue }
            let events = NextDividendAnalytics.merged(book.dividendEvents + (dividendEvents[position.code] ?? []))
            for event in events where event.code == position.code && event.isEstimated != true
                && event.date <= todayText && event.date >= cutoffText && event.date >= threshold {
                let marker = "自动登记|\(event.code)|\(event.date)"
                if updated.incomeEvents.contains(where: { $0.note.hasPrefix(marker) }) { continue }
                let gross = event.amountPerShare * Decimal(position.units)
                guard gross > 0 else { continue }
                let exDate = formatter.date(from: event.date)
                let payDate = formatter.date(from: event.payDate ?? event.date) ?? exDate ?? today
                let draft = NextIncomeEvent(kind: .etfDistribution, code: event.code, name: position.name,
                                            exDate: exDate, payDate: payDate, units: position.units,
                                            perUnit: event.amountPerShare, grossAmount: gross, tax: 0,
                                            note: "\(marker)|\(position.units) 份")
                guard (try? draft.validate()) != nil else { continue }
                updated.incomeEvents.append(draft)
                added.append("\(position.name) \(event.date) ¥\(NextMoney.text(gross))")
            }
        }
        guard !added.isEmpty || migratedCount > 0 || !removed.isEmpty else { return }
        var reason = "按持仓份额与已实施派息自动登记 \(added.count) 笔"
        if migratedCount > 0 { reason += "；补全 \(migratedCount) 只持仓建仓日" }
        if !removed.isEmpty { reason += "；清理 \(removed.count) 笔历史分红伪待收" }
        do {
            try commitRealLedger(updated, action: "自动登记派息待收", reason: reason)
            notice = "已按持仓自动登记 \(added.count) 笔派息待收；确认到账后再计入现金。"
        } catch {
            notice = "派息自动登记未写入：\(error.localizedDescription)"
        }
    }

    func refreshNASResearch(_ code: String) async {        guard !preferences.nasBaseURL.isEmpty else {
            researchStatus[code] = "未配置 NAS · 显示本机研究缓存"
            return
        }
        let baseURL = preferences.nasBaseURL
        do {
            let report = try await NextNASService.fetchResearch(code: code, baseURL: baseURL)
            guard preferences.nasBaseURL == baseURL else {
                researchStatus[code] = "NAS 地址已变更 · 保留原缓存，未混用新旧服务"
                return
            }
            nasResearch[code] = report
            researchStatus[code] = "已从 NAS 刷新研究状态"
        } catch {
            researchStatus[code] = nasResearch[code] == nil
                ? "NAS 研究不可用 · 暂无本机缓存"
                : "NAS 刷新失败 · 当前显示本机缓存"
        }
    }
    /// 新闻 → 持仓：默认手机直连，NAS只按来源偏好作为备用；只保存带时间和链接的标题。
    func refreshNASNews(_ code: String) async {
        let baseURL = preferences.nasBaseURL
        let name = book.positions.first(where: { $0.code == code })?.name ?? NextNameBook.name(for: code) ?? code
        let modes: [NextMarketSourceMode]
        switch preferences.marketSourceMode {
        case .phoneDirect: modes = [.phoneDirect, .nasPreferred]
        case .nasPreferred: modes = [.nasPreferred, .phoneDirect]
        case .nasOnly: modes = [.nasOnly]
        }
        var failures: [String] = []
        for mode in modes {
            do {
                let result: (items: [NextNewsInput], source: String)
                switch mode {
                case .phoneDirect:
                    let direct = try await NextMarketDataService.fetchNews(code: code, name: name)
                    result = (direct.value, direct.source)
                case .nasPreferred, .nasOnly:
                    guard !baseURL.isEmpty else { throw NextError.invalid("未配置 NAS 地址") }
                    let nas = try await NextNASService.fetchNews(code: code, baseURL: baseURL)
                    guard preferences.nasBaseURL == baseURL else { throw NextError.invalid("NAS 地址已变更") }
                    result = (nas.items, "NAS 新闻 · \(nas.state)")
                }
                guard !result.items.isEmpty else { throw NextError.invalid("来源没有返回有效标题") }
                nasNews[code] = result.items
                newsStatus[code] = "\(result.source) · \(result.items.count)条 · \(Date.now.formatted(date: .omitted, time: .shortened))"
                return
            } catch { failures.append(error.localizedDescription) }
        }
        newsStatus[code] = nasNews[code] == nil
            ? "新闻源不可用 · \(failures.joined(separator: "；")) · 本次结论不含新闻"
            : "新闻刷新失败 · 保留本机旧缓存（不视为最新）· \(failures.joined(separator: "；"))"
    }
    func registerNASArchive(_ code: String) async {
        guard !preferences.nasBaseURL.isEmpty else { return }
        do { try await NextNASService.trackInstrument(code: code, baseURL: preferences.nasBaseURL) }
        catch { status = "NAS 后台归档登记失败 · 本机行情和缓存仍可用" }
    }
    @discardableResult func loadNASMinute(code: String, day: Date) async -> Bool {
        guard !preferences.nasBaseURL.isEmpty else { errorMessage = "先连接 NAS 才能读取归档日期"; return false }
        do {
            let dataset = try await NextNASService.fetchMinute(code: code, day: day, baseURL: preferences.nasBaseURL)
            chartData[code] = dataset
            status = "已载入 NAS 分时档案 · \(dataset.priceSource) · \(dataset.samples.count) 点"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    /// 日 K 来源跟随用户偏好；手机直连优先是默认设置，以减少 NAS 代理流量。
    /// 旧数据不覆盖新数据：新结果的最新样本不晚于缓存时，保留原缓存。
    func refreshDaily(_ code: String, required: Bool = false) async {
        if preferences.marketSourceMode == .nasOnly && preferences.nasBaseURL.isEmpty {
            dailyErrors[code] = "行情来源设为仅使用NAS，但尚未配置NAS地址"
            return
        }
        if preferences.marketSourceMode != .phoneDirect && !preferences.nasBaseURL.isEmpty {
            do {
                let dataset = try await NextNASService.fetchDaily(code: code, baseURL: preferences.nasBaseURL)
                dailyErrors.removeValue(forKey: code)
                if shouldReplaceDayDataset(chartData["\(code):day"], with: dataset) { chartData["\(code):day"] = dataset }
                return
            } catch let nasFailure {
                guard preferences.marketSourceMode == .nasPreferred else {
                    dailyErrors[code] = "仅NAS模式 · NAS日 K 不可用：\(nasFailure.localizedDescription)"
                    return
                }
                do {
                    let direct = try await NextMarketDataService.fetchDaily(code: code)
                    dailyErrors.removeValue(forKey: code)
                    if shouldReplaceDayDataset(chartData["\(code):day"], with: direct.value) { chartData["\(code):day"] = direct.value }
                } catch {
                    dailyErrors[code] = "NAS 日 K 失败：\(nasFailure.localizedDescription)；直连也失败：\(error.localizedDescription)"
                }
                return
            }
        }
        do {
            let direct = try await NextMarketDataService.fetchDaily(code: code)
            dailyErrors.removeValue(forKey: code)
            if shouldReplaceDayDataset(chartData["\(code):day"], with: direct.value) { chartData["\(code):day"] = direct.value }
        } catch {
            dailyErrors[code] = error.localizedDescription
        }
    }

    /// 多源 fallback 后各源样本口径可能不同，用「最新样本时间」做唯一裁判：
    /// 新数据没有更新就不替换，避免旧数据覆盖新数据。
    private func shouldReplaceDayDataset(_ cached: NextChartDataset?, with incoming: NextChartDataset) -> Bool {
        guard let cached, let cachedLast = cached.orderedSamples.last?.timestamp,
              let incomingLast = incoming.orderedSamples.last?.timestamp else { return true }
        return incomingLast >= cachedLast
    }
    func acceptOrderBook(_ snapshot: NextOrderBookSnapshot, marketOpen: Bool) throws {
        try snapshot.validate()
        orderBooks[snapshot.code] = snapshot
    }
    func makeBackup() throws -> NextArchiveEnvelope {
        guard repository.integrityWarning == nil else { throw NextError.invalid("本机数据完整性待恢复；为避免导出不完整账本，备份导出已停止") }
        return try NextArchiveEnvelope(archive: makeArchive())
    }
    func restoreBackup(_ envelope: NextArchiveEnvelope) throws {
        var incoming = try envelope.archive()
        let event = NextAuditEvent(at: Date(), action: "恢复已校验备份", reason: "用户确认恢复；恢复前状态另存安全副本", before: book, after: incoming.book)
        incoming.audits.append(event)
        if repository.integrityWarning == nil { try repository.writeSafetyCopy(try makeBackup()) }
        else { try repository.writeRawSafetyCopy() }
        try repository.replaceAll(with: incoming)
        ledger = NextAuditedBook(current: incoming.book, events: incoming.audits)
        preferences = LocalPreferences(goal: incoming.goal, watch: incoming.watch, navigation: incoming.navigation, theme: GPTheme(rawValue: incoming.theme.rawValue) ?? .light, appearance: preferences.appearance, notifications: incoming.notifications, nasBaseURL: preferences.nasBaseURL, legacyWebBaseURL: preferences.legacyWebBaseURL, nasRevision: nil, marketSourceMode: preferences.marketSourceMode)
        quotes = incoming.cachedQuotes; chartData = incoming.chartData; rules = incoming.instrumentRules; orderBooks = incoming.orderBooks
        decisions = incoming.decisionHistory
        nasResearch = incoming.nasResearch
        decisionMemory = incoming.decisionMemory
        dividendEvents = incoming.dividendEvents
        patientLimitPlans = incoming.patientLimitPlans
        candidatePlans = incoming.candidatePlans
        profile = incoming.profile
        suggestions = incoming.suggestions
        preferences.themeStyle = incoming.appTheme
        preferences = preferences
    }
    func research(for code: String?) -> NextDecision? {
        do {
            var decision = try NextResearch.prepare(book: book, goal: goal, quotes: Dictionary(uniqueKeysWithValues: quotes.map { ($0.key, $0.value.quote) }), now: Date())
            if let code {
                decision.title = "围绕 \(quotes[code]?.quote.name ?? code) 的买入机会"
                let item: NextEvidence
                if let cached = quotes[code], cached.usableForDisplay(at: Date()) {
                    let quote = cached.quote
                    let quality = quote.isFresh(at: Date()) ? "有效报价" : cached.stamp.label(now: Date())
                    item = NextEvidence(id: "security-\(code)", title: "证券行情", detail: "\(quote.name) 最新价 ¥\(NextMoney.text(quote.price, digits: 3))；\(quality)；\(quote.source)；源时间 \(quote.time.formatted(date: .numeric, time: .shortened))。", level: quote.isFresh(at: Date()) ? "事实" : "过期数据", observedAt: quote.time)
                } else {
                    item = NextEvidence(id: "security-\(code)", title: "证券行情待补", detail: "\(code) 当前没有可显示的本机报价缓存；需要刷新后再判断。", level: "缺口", observedAt: Date())
                }
                decision.evidence.append(item)
            }
            return decision
        }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    private func reportSave(_ failure: String?) {
        if let failure { errorMessage = "本机保存失败：\(failure)。请先确认数据安全后再继续修改。" }
    }
    private func makeArchive() -> NextAppArchive {
        var archive = NextAppArchive()
        archive.book = book
        archive.goal = goal; archive.watch = watch; archive.navigation = preferences.navigation
        archive.cachedQuotes = quotes; archive.chartData = chartData; archive.instrumentRules = rules; archive.orderBooks = orderBooks
        archive.notifications = preferences.notifications; archive.audits = ledger.events
        archive.decisionHistory = decisions
        archive.nasResearch = nasResearch
        archive.decisionMemory = decisionMemory
        archive.dividendEvents = dividendEvents
        archive.patientLimitPlans = patientLimitPlans
        archive.candidatePlans = candidatePlans
        archive.profile = profile
        archive.suggestions = suggestions
        archive.appTheme = preferences.themeStyle
        archive.theme = NextTheme(rawValue: theme.rawValue) ?? .light
        return archive
    }
}
