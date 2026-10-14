import Foundation
import CoreFoundation
import SwiftUI

@MainActor
final class PortfolioStore: ObservableObject {
    @Published var data = PortfolioData()
    @Published var intradayBars: [IntradayBar] = []
    @Published var dailyBars: [String: [DailyBar]] = [:]
    @Published var sourceStatus = "等待刷新"
    @Published private(set) var marketChanges: [String: Double] = [:]
    /// 腾讯 ETF 报价中可核实的实时折溢价率（百分数单位）。仅用于当前界面，
    /// 不写入账本；接口没给或品种不是 ETF 时保持 nil，绝不拿昨收/净值猜。
    @Published private(set) var marketPremiums: [String: Double] = [:]
    @Published private(set) var marketIOPVs: [String: Double] = [:]
    @Published var fundNAVStatus = "尚未更新基金净值"
    @Published var fundHoldingsStatus = "基金重仓尚未更新"
    @Published var isRefreshingFundHoldings = false
    @Published var fundDCAStatus = "暂无定投补记"
    @Published var isRefreshingFunds = false
    @Published var isRefreshingQuotes = false
    /// 自动轮询的**重入保护**。故意不是 `@Published`：它每 15 秒翻两次，
    /// 发布出去就等于每 15 秒白重建两次视图树（见 `performQuoteRefresh`）。
    private var autoRefreshInFlight = false
    /// 上一次成功写回网页账本时的**内容指纹**（只覆盖会被写进 `/api/data` 的账本字段，
    /// 见 `WebLedgerWriter.ledgerFingerprint`）。内容没变就跳过，一次请求都不发。
    ///
    /// 落在 `UserDefaults` 里而不是内存里：重启一次 App 也要记得「这份内容已经写过了」，
    /// 否则每次启动都白写一份回去。
    private var lastWebLedgerWrittenFingerprint: String {
        get { UserDefaults.standard.string(forKey: NASSyncService.webLedgerFingerprintKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: NASSyncService.webLedgerFingerprintKey) }
    }
    /// 写回网页账本的防抖任务（合并短时间内连续几次改动）。
    private var webLedgerWriteBackTask: Task<Void, Never>?
    @Published private(set) var intradayArchiveStatus = "尚未补全分时档案"
    @Published private(set) var isArchivingIntraday = false
    /// 首页顶部指数条。与账本数据无关，单独缓存，不参与备份 / NAS 同步。
    @Published private(set) var indexQuotes: [MarketIndexQuote] = MarketIndexStore.load()
    @Published private(set) var isRefreshingIndices = false
    /// 指数条自动刷新的重入保护，同样故意不发布。
    private var autoIndexRefreshInFlight = false

    /// 有没有自动轮询正在进行。**故意不是 `@Published`**：它只给「手动刷新」按钮
    /// 用来避开自动刷新，不参与界面渲染。
    var isAutoRefreshing: Bool { autoRefreshInFlight || autoIndexRefreshInFlight }
    @Published var nasSyncStatus = "未配置 NAS 同步"
    @Published private(set) var operationAudit: [OperationAuditRecord] = []
    @Published private(set) var isSynchronizingNAS = false
    /// 网页版账本写回的状态文案（独立于原生账本的 `nasSyncStatus`，两者是两份文档）。
    @Published private(set) var webLedgerStatus = "尚未写回"
    private let key = "guanpan.pro.native.portfolio.v1"
    private let undoKey = "guanpan.pro.native.portfolio.undo.v1"
    private let auditKey = "guanpan.pro.native.portfolio.audit.v1"
    private let gridBarsFilename = "guanpan-intraday-bars.json"
    private let dailyBarsFilename = "guanpan-daily-bars.json"
    private let automaticNAVCheckDateKey = "guanpan.native.fundNAV.lastAutomaticCheck"
    private let intradayArchiveLastRunKey = "guanpan.native.intradayArchive.lastRun"
    private let legacyIntradayArchiveImportKey = "guanpan.native.intradayArchive.legacyImportDone"
    private var nasSyncTask: Task<Void, Never>?
    private var nasPollingTask: Task<Void, Never>?
    private var lastIntradayNASSyncAt = Date.distantPast
    /// 分时去重索引。不能每 5 秒为每只标的扫描多年历史；统一按“代码 + 自然分钟”判断。
    private var intradayMinuteKeys: Set<String> = []
    /// 「分钟键 → 分时点」主索引。
    ///
    /// 合并分时时**以它为底改写**，而不是为全部 N 个历史点重新算一遍分钟键：
    /// 档案只增不减，旧写法每次合并都要新分配 N 个字符串键 + 一张 N 项字典，
    /// 档案一大就是一次几百 MB 的瞬时内存峰值 —— 打开分时页 / 日 K 时被系统
    /// 杀进程（闪退）往往就发生在这一步。同时也是「本次合并有没有实质变化」的判定源。
    private var intradayBarByKey: [String: IntradayBar] = [:]
    /// `code|day` → 该标的该交易日、按时间升序的分时点。
    ///
    /// 详情页 / 分时档案页 / 盘中陪伴 / 网格要「某标某日」的分时一律走
    /// `intradayBars(code:day:)`，**不要**再对整个 `intradayBars` 做 filter：
    /// 那是 O(档案总点数)，而 `MarketChartView.body` 一帧里会取十几次，
    /// 档案越长越卡 —— 这正是「有的页面上下滑动特别卡」的主因。
    private var intradayBarsByCodeDay: [String: [IntradayBar]] = [:]
    /// `code` → 已有分时记录的交易日集合（稳定 O(1) 增改，读的时候再排序）。
    private var intradayDaySetByCode: [String: Set<String>] = [:]
    private var lastAutomaticMarketSaveAt = Date.distantPast
    private var applyingNASData = false
    private var isUndoingSave = false
    private var isEnsuringBackfillHistory = false
    /// 技术信号 memo。`MarketSignalCalculator.evaluate` 是 O(640) 的纯计算，
    /// 自选列表每一行渲染、按信号排序的比较器、首页「盘中机会」都会调用；
    /// 不缓存时每次滚动 / 刷新都反复重算，是列表滑动卡顿的主要来源之一。
    /// 缓存键取「根数 + 末根日期/收盘/成交量」：日线的任何实质变化
    /// （新交易日、盘中刷新最后一根）都会自然失效，无需手动清理。
    private var signalCache: [String: (key: String, signal: MarketSignal?)] = [:]

    private func invalidateSignalCache(for code: String? = nil) {
        if let code { signalCache.removeValue(forKey: code) }
        else { signalCache.removeAll(keepingCapacity: true) }
    }

    /// 取某代码的技术信号（带 memo）。视图层一律走这里，不要直接调 evaluate。
    func signal(forCode code: String) -> MarketSignal? {
        let bars = dailyBars[code] ?? []
        let last = bars.last
        let key = "\(bars.count)|\(last?.date ?? "")|\(last?.close ?? 0)|\(last?.volume ?? 0)"
        if let hit = signalCache[code], hit.key == key { return hit.signal }
        let value = MarketSignalCalculator.evaluate(bars)
        if signalCache.count > 512 { signalCache.removeAll(keepingCapacity: true) }
        signalCache[code] = (key, value)
        return value
    }

    init() {
        load()
        loadOperationAudit()
        if UserDefaults.standard.data(forKey: key) == nil,
           let initial = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(initial, forKey: key)
        }
        loadIntradayBars()
        loadDailyBars()
        processAutomaticDCA()
    }
    var appearance: AppAppearance { get { data.appearance } set { data.appearance = newValue; save(label: "修改外观主题") } }
    /// 解析掉「跟随系统」之后的实际主题。
    ///
    /// **凡是取 `AppTheme.palette(for:)` 来画色的地方都用这个，不要直接用 `appearance`。**
    /// `.system` 的 palette 写死是深色，而它的 colorScheme 跟随系统；手机在浅色模式时
    /// 会变成「近黑底 + 黑字」，整页看不见（指数详情弹窗就是这么翻车的）。
    /// 设置页的主题预览卡是唯一例外 —— 那里要如实画出 `.system` 这一档本身。
    var resolvedAppearance: AppAppearance { AppAppearance.resolved(data.appearance) }
    var totalMarketValue: Double { data.holdings.reduce(0) { $0 + $1.marketValue } }
    var totalAsset: Double { totalMarketValue + data.cash }
    var totalPnL: Double { data.holdings.reduce(0) { $0 + holdingPnL($1) } }

    // MARK: - 分模块汇总（ETF/证券 与 场外基金 各自独立，不混算）
    /// 指定类别的当前市值合计。
    func marketValue(of kind: Holding.Kind) -> Double {
        data.holdings.filter { $0.kind == kind }.reduce(0) { $0 + $1.marketValue }
    }
    /// 指定类别的持仓浮盈合计（口径与账户「持仓浮盈」一致，含成本覆盖/摊薄口径）。
    func pnl(of kind: Holding.Kind) -> Double {
        data.holdings.filter { $0.kind == kind }.reduce(0) { $0 + holdingPnL($1) }
    }
    /// 指定类别的持仓成本合计（用于成本收益率）。
    func cost(of kind: Holding.Kind) -> Double {
        data.holdings.filter { $0.kind == kind }
            .reduce(0) { $0 + $1.quantity * displayedCost(for: $1) }
    }
    /// 指定类别的成本收益率（%）。成本为 0 时返回 nil，避免除零与臆测。
    func pnlRate(of kind: Holding.Kind) -> Double? {
        let base = cost(of: kind)
        guard base > 0, base.isFinite else { return nil }
        return pnl(of: kind) / base * 100
    }

    // MARK: - 账户卡片指标（对齐网页版持仓页汇总：总资产 / 总盈亏 / 仓位 / 今日盈亏…）

    /// 全部持仓的成本合计（含成本覆盖与摊薄口径）。
    var totalCost: Double { data.holdings.reduce(0) { $0 + $1.quantity * displayedCost(for: $1) } }
    /// 总盈亏 / 总成本，即网页版「盈亏比例」。成本为 0 返回 nil。
    var totalPnLRate: Double? {
        guard totalCost > 0, totalCost.isFinite else { return nil }
        return totalPnL / totalCost * 100
    }
    /// 指定类别的当日盈亏：用最近一次拿到的涨跌幅反推昨收，不额外发请求。
    func dayPnL(of kind: Holding.Kind) -> Double {
        data.holdings.filter { $0.kind == kind }.reduce(0) { $0 + dayPnL(of: $1) }
    }
    func dayPnL(of holding: Holding) -> Double {
        // Quote.changePct / marketChanges 使用小数比率（0.01 = 1%），
        // 这里不能再除以 100，否则当日盈亏会被缩小约 100 倍。
        guard let pct = marketChanges[holding.code], pct.isFinite,
              abs(pct) > 0.000001, (1 + pct) != 0 else { return 0 }
        let previousClose = holding.current / (1 + pct)
        return holding.quantity * (holding.current - previousClose)
    }
    /// 全部持仓当日盈亏。
    ///
    /// **注意口径**：`marketChanges` 只有场内代码（自选 + ETF 持仓），场外基金不在里面，
    /// 所以这个值实际上等于 `intradayPnL`（场内）。场外基金的当日盈亏请用 `fundDayPnL`。
    /// 界面上别把这两个数混着叫「今日盈亏」，否则会出现「没算场外却像是全账户」的误读。
    var dayPnL: Double { data.holdings.reduce(0) { $0 + dayPnL(of: $1) } }
    /// 当日盈亏是否可算：至少要有一只拿到当日涨跌幅，否则显示「--」而不是 0。
    var hasDayPnL: Bool { hasIntradayPnL }
    /// 今日幅度 = 当日盈亏 / 昨收市值。
    var dayPnLRate: Double? { intradayPnLRate }

    // MARK: - 当日盈亏：场内与场外必须分开看

    /// 场内（ETF / 证券）当日盈亏。
    ///
    /// 数据来自 `marketChanges`，即最近一次行情请求拿到的涨跌幅。
    /// 休市时腾讯仍会返回**上一交易日收盘**的涨跌幅，所以周末 / 夜里这个数不是空的，
    /// 只是它的「今天」= 上一交易日 —— 界面必须用 `intradayQuoteDate` 把日期写出来。
    var intradayPnL: Double { dayPnL(of: .etf) }

    /// 场内当日盈亏是否可算：至少要有一只 ETF / 证券拿到涨跌幅。
    var hasIntradayPnL: Bool {
        data.holdings.contains { $0.kind == .etf && marketChanges[$0.code] != nil }
    }

    /// 场内行情对应的最近一个交易日（取所有场内持仓里最新的行情时间戳）。
    var intradayQuoteDate: Date? {
        data.holdings.compactMap { $0.kind == .etf ? $0.marketUpdatedAt : nil }.max()
    }

    /// 场内行情是不是**今天**的数据。
    ///
    /// 休市（周末 / 节假日）时行情源不会空手而归，它照旧返回**上一交易日收盘价**，
    /// 所以「有没有数字」根本分不出今天还是上周五 —— 必须比日期。
    /// 界面靠这个决定写「今日盈亏」还是「休市 · MM-dd 盈亏」：
    /// 场外基金在休市时是没数的（净值要 T+1 才出），场内却还在跳，
    /// 不标清楚就会被读成「今天场内赚了这么多」。
    var isIntradayQuoteToday: Bool {
        guard let date = intradayQuoteDate else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.isDateInToday(date)
    }

    /// 当前是否处于 A 股连续竞价时段（09:30–11:30 / 13:00–15:00 的工作日）。
    var isMarketOpenNow: Bool { Self.isRegularTradingSession(.now) }

    /// 今天是否休市。
    ///
    /// 四层判断，逐级降级 —— 任何一层缺数据都不至于把交易日误判成休市：
    /// ①周末：最可靠；
    /// ②上证指数日 K 反推的交易日历：覆盖得到就听它（跨年、临时休市都自动跟上）；
    /// ③内置 2026 休市表：日历还没拉到时（新装机 / 离线）的兜底；
    /// ④场内行情时间戳：**只在今天已经开过盘之后**才允许下结论。
    ///
    /// 第 ④ 层的「今天已经开过盘」这个条件是必需的，别省。
    /// 交易日 09:30 之前行情源给的必然是**上一交易日**的收盘价（日 K 里也还没有
    /// 今天这根，所以第 ② 层判不出结论），这时候拿「行情不是今天的」去推
    /// 「今天休市」，就会把正常交易日锁成休市 —— 用户看到的是
    /// 「今天休市，不用记录快照」，而首页那条记录快照的入口正是被这个判断关掉的。
    var isMarketClosedToday: Bool {
        if MarketCalendar.isWeekend(.now) { return true }
        let today = MarketCalendar.isoDay(.now)
        if MarketCalendar.covers(today) { return !MarketCalendar.loadTradingDays().contains(today) }
        if MarketCalendar.mainlandClosures2026.contains(today) { return true }
        if hasIntradayPnL, !isIntradayQuoteToday, MarketCalendar.hasOpenedToday(.now) { return true }
        return false
    }

    /// 场内今日幅度 = 场内当日盈亏 / 场内昨收市值。
    var intradayPnLRate: Double? {
        let base = marketValue(of: .etf) - intradayPnL
        guard base > 0, base.isFinite else { return nil }
        return intradayPnL / base * 100
    }

    /// 单只场外基金「最近一个净值日」的盈亏 = 份额 ×（最新净值 − 上一净值）。
    ///
    /// 场外基金一天只公布一次净值（通常 T+1 晚），没有盘中行情，
    /// 所以它和场内 ETF 永远不可能共用同一个「今天」。这里按净值日单独算，
    /// 界面必须把净值日写出来，否则又会被读成「今天的场外盈亏」。
    /// **口径**：只比「最新已公布净值 − 上一个已公布净值」，不掺任何日历日期 ——
    /// 美股基金周末休盘但净值照常公布，上一期是上一个净值日而不是昨天。
    /// 只把净值日期等于今天的变化计入今天。`fetchedAt` 仅记录数据何时到手机，
    /// 不能把昨天的净值涨跌挪到今天；迟到净值应回补到它自己的净值日/历史快照。
    func fundDayPnL(of holding: Holding) -> Double {
        guard holding.kind == .fund, holding.quantity > 0,
              let pair = currentFundDayPair(for: holding) else { return 0 }
        return holding.quantity * (pair.current.nav - pair.previous.nav)
    }

    private func currentFundDayPair(for holding: Holding) -> (current: FundNAVPoint, previous: FundNAVPoint)? {
        guard holding.kind == .fund, holding.quantity > 0 else { return nil }
        let today = MarketCalendar.isoDay(.now)
        let points = latestFundPoints(for: holding.code)
        // 必须是该基金最新的有效净值日恰好为今天。历史里即使留着今天的重复/导入点，
        // 只要该基金当前最新披露仍停在昨天，就不能把旧日收益放进今日总盈亏。
        guard points.last?.date == today, let index = points.indices.last, index > 0 else { return nil }
        let point = points[index], previous = points[index - 1]
        guard point.nav.isFinite, point.nav > 0, previous.nav.isFinite, previous.nav > 0 else { return nil }
        return (point, previous)
    }

    /// 全部场外基金「最近一个净值日」的盈亏合计。
    var fundDayPnL: Double {
        data.holdings.filter { $0.kind == .fund }.reduce(0) { $0 + fundDayPnL(of: $1) }
    }

    /// 场外基金当日盈亏是否可算：至少一只持仓基金有今天的有效净值和前一期净值。
    var hasFundDayPnL: Bool {
        data.holdings.contains { currentFundDayPair(for: $0) != nil }
    }

    /// 将旧备份/跨设备合并产生的重复净值日期压成一条，优先保留最近一次确认且数值有效的记录。
    private func latestFundPoints(for code: String) -> [FundNAVPoint] {
        let rows = data.fundNAVHistory.filter {
            $0.code == code && $0.nav.isFinite && $0.nav > 0
        }
        let grouped = Dictionary(grouping: rows, by: \.date)
        return grouped.keys.sorted().compactMap { date in
            grouped[date]?.max { lhs, rhs in
                switch (lhs.fetchedAt, rhs.fetchedAt) {
                case let (l?, r?): return l < r
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): return false
                }
            }
        }
    }

    /// 场外今日幅度 = 今日已取得有效净值的基金盈亏 / 这些基金各自前一期净值市值。
    var fundDayNAVRate: Double? {
        let base = data.holdings.reduce(0.0) { total, holding in
            guard let pair = currentFundDayPair(for: holding) else { return total }
            return total + pair.previous.nav * holding.quantity
        }
        guard base > 0, base.isFinite else { return nil }
        return fundDayPnL / base * 100
    }

    /// 最近一个已公布净值日（yyyy-MM-dd），供界面标注。
    var latestFundNAVDate: String? {
        let codes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code))
        guard !codes.isEmpty else { return nil }
        return data.fundNAVHistory.filter { codes.contains($0.code) }.map(\.date).max()
    }

    /// 当日盈亏合计 = 场内（按最近行情）+ 场外基金（按最新净值日）。
    ///
    /// 两个分项的数据日期不同（场内是交易日收盘、场外是净值公布日），
    /// 所以这个合计只是「用户最想看的那个总数」；界面上必须把两个分项一起列出来，
    /// 只留一个合计就又会变成「不知道算的是谁」。
    var dayPnLGross: Double { intradayPnL + fundDayPnL }

    /// 合计是否可算：场内或场外任一有数即可，两边都没有才显示 --。
    var hasDayPnLGross: Bool { hasIntradayPnL || hasFundDayPnL }

    /// 合计今日幅度 = 合计当日盈亏 / 全部持仓昨收市值。
    var dayPnLGrossRate: Double? {
        let base = totalMarketValue - dayPnLGross
        guard base > 0, base.isFinite else { return nil }
        return dayPnLGross / base * 100
    }
    /// 仓位（持仓市值 / 总资产）。
    var positionPercent: Double {
        guard totalAsset > 0, totalAsset.isFinite else { return 0 }
        return totalMarketValue / totalAsset * 100
    }
    /// 现金占比。
    var cashPercent: Double {
        guard totalAsset > 0, totalAsset.isFinite else { return 0 }
        return data.cash / totalAsset * 100
    }
    func displayedCost(for holding: Holding) -> Double {
        displayedCost(for: holding, dilutedRealizedSum: nil)
    }

    /// 摊薄口径的已实现盈亏合计，按「代码|类型」一次遍历算好（页面级预计算用）。
    /// 键为 "代码|nil"（旧版无类型流水）与 "代码|etf/fund"；调用方按持仓类型相加，
    /// 与 displayedCost 里 `kind == nil || kind == holding.kind` 的过滤规则一致。
    func dilutedRealizedSums() -> [String: Double] {
        var sums: [String: Double] = [:]
        for entry in data.ledger {
            sums["\(entry.code)|\(entry.kind?.rawValue ?? "nil")", default: 0] += entry.realizedPnL
        }
        return sums
    }

    /// displayedCost 的预计算版本：dilutedRealizedSum 传入页面级算好的已实现盈亏合计，
    /// 避免每次调用都全量过滤流水（持仓列表每行两次，是滚动卡顿来源之一）。
    /// sum 为 nil 时退回自行过滤，行为与原实现完全一致。
    func displayedCost(for holding: Holding, dilutedRealizedSum: Double?) -> Double {
        if let override = holding.costOverride, override.isFinite, override > 0 { return override }
        guard data.costAccountingMode == .diluted, holding.quantity > 0 else { return holding.cost }
        let realized: Double
        if let dilutedRealizedSum {
            realized = dilutedRealizedSum
        } else {
            realized = data.ledger.filter { $0.code == holding.code && ($0.kind == nil || $0.kind == holding.kind) }
                .reduce(0) { $0 + $1.realizedPnL }
        }
        return max(0, holding.cost - realized / holding.quantity)
    }
    func holdingPnL(_ holding: Holding) -> Double {
        holding.quantity * (holding.current - displayedCost(for: holding))
    }
    func setCostOverride(code: String, kind: Holding.Kind, value: Double?) {
        guard let index = data.holdings.firstIndex(where: { $0.code == code && $0.kind == kind }) else { return }
        if let value, value.isFinite, value > 0 { data.holdings[index].costOverride = value }
        else { data.holdings[index].costOverride = nil }
        save(label: "修改成本显示覆盖")
    }
    var realizedPnL: Double {
        data.ledger.reduce(0) { $0 + $1.realizedPnL }
            + data.fundTransactions.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
    }
    /// 最终生效的深浅模式：定时自动切换优先于主题自带设置。
    var effectiveColorScheme: ColorScheme? {
        if let forced = AutoThemeSchedule.override(schedule: data.autoThemeSchedule) {
            return forced ? .dark : .light
        }
        return data.appearance.colorScheme
    }
    /// 最终生效的强调色：自定义强调色优先于主题自带强调色。
    var effectiveAccentColor: Color {
        if let preset = AccentPreset(rawValue: data.accentColorName), let color = preset.color { return color }
        return data.appearance.accentColor
    }

    var marketMood: (average: Double, count: Int)? {
        let codes = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code))
        let values = codes.compactMap { code in
            marketChanges[code] ?? data.quotes.first(where: { $0.code == code })?.changePct
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), values.count)
    }

    /// 单个模块（ETF / 证券，或场外基金）自己的情绪均涨幅。
    ///
    /// 与 `marketMood` 同口径（能取到涨跌幅的标的等权平均），只是把范围收窄到
    /// 本模块有份额的持仓 —— 两个模块的资产和盈亏本来就是分开算的，情绪也应该各看各的。
    /// 取不到涨跌幅时返回 nil，不用 0 冒充「持平」。
    func marketMood(of kind: Holding.Kind) -> (average: Double, count: Int)? {
        let codes = data.holdings.filter { $0.kind == kind && $0.quantity > 0 }.map(\.code)
        guard !codes.isEmpty else { return nil }
        let values = codes.compactMap { code in
            marketChanges[code] ?? data.quotes.first(where: { $0.code == code })?.changePct
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), values.count)
    }

    func load() {
        guard let raw = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(PortfolioData.self, from: raw) else { return }
        data = value
        migrateChartRangeIfNeeded()
    }

    /// 一次性迁移：旧默认 250 日会让 K 线细到亚像素（一团灰），
    /// 新默认 120。只迁移一次，之后用户改回 250 不会被覆盖。
    private func migrateChartRangeIfNeeded() {
        let flag = "guanpan.native.chartRangeMigrated120"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if data.dailyChartRangeDays == 250 {
            data.dailyChartRangeDays = 120
            save(label: nil)
        }
    }
    private func gridBarsURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(gridBarsFilename)
    }
    private func loadIntradayBars() {
        guard let url = gridBarsURL(), let raw = try? Data(contentsOf: url) else { return }
        var loaded: [IntradayBar] = []
        if let rows = try? JSONDecoder().decode([IntradayBar].self, from: raw) {
            loaded = rows
        } else if let text = String(data: raw, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let bytes = Data(line.utf8)
                if let bar = try? JSONDecoder().decode(IntradayBar.self, from: bytes) { loaded.append(bar) }
                else if let bars = try? JSONDecoder().decode([IntradayBar].self, from: bytes) { loaded.append(contentsOf: bars) }
            }
        }
        intradayBars = Self.uniqueIntradayBars(loaded)
        rebuildIntradayMinuteIndex()
        // 旧版实时点带秒，与整分钟行情会形成重复。首次载入时压成一条/分钟并重写紧凑文件。
        // 判定用「归一化后时间戳是否变化」，不再用 `Int(时间戳) % 60` —— 一旦文件里出现
        // 坏时间戳（非有限值），`Int(_:)` 会直接 trap，整个 App 在启动即闪退。
        let needsRewrite = loaded.count != intradayBars.count
            || loaded.contains { Self.normalizedIntradayBar($0).timestamp != $0.timestamp }
        if needsRewrite {
            saveIntradayBars()
        }
    }
    private static func uniqueIntradayBars(_ bars: [IntradayBar]) -> [IntradayBar] {
        var byMinute: [String: IntradayBar] = [:]
        for raw in bars {
            var bar = normalizedIntradayBar(raw)
            let key = intradayMinuteKey(code: bar.code, at: bar.timestamp)
            if let prior = byMinute[key] {
                if bar.volume == nil { bar.volume = prior.volume }
                if bar.iopv == nil { bar.iopv = prior.iopv }
            }
            byMinute[key] = bar
        }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// 把时间戳压到自然分钟。
    ///
    /// `Int(_:)` 对 NaN / ±无穷 / 超出 Int 范围的值会**直接 trap**（Swift 的 trap 无处
    /// catch，必崩）。备份文件、旧网页回填、NAS 档案里只要出现一个坏时间戳，
    /// 全 App 都会在加载或合并分时的那一下闪退，所以这里先夹一次再转。
    /// 纯函数，显式 `nonisolated`：备份迁移（`LegacyMigration` 是非主线程隔离的 enum）
    /// 也要用它，标成 `@MainActor` 会在那边报「调用主线程隔离方法」的编译错误。
    nonisolated static func minuteStamp(_ time: Date) -> Int {
        let seconds = time.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        let clamped = min(max(seconds, -6.0e11), 6.0e11)   // ±19000 年，远超任何真实行情
        return Int(clamped / 60)
    }

    private static func normalizedIntradayBar(_ bar: IntradayBar) -> IntradayBar {
        var normalized = bar
        normalized.timestamp = Date(timeIntervalSince1970: TimeInterval(Self.minuteStamp(bar.timestamp) * 60))
        return normalized
    }

    static func intradayMinuteKey(code: String, at time: Date) -> String {
        "\(code)-\(Self.minuteStamp(time))"
    }

    /// 「标的 + 交易日」在索引里的键。做成静态方法是为了让调用方和存储共用同一种拼法。
    static func codeDayKey(code: String, day: String) -> String { "\(code)|\(day)" }

    func containsIntradayMinute(code: String, at time: Date) -> Bool {
        intradayMinuteKeys.contains(Self.intradayMinuteKey(code: code, at: time))
    }

    // MARK: - 分时读取（一律走索引，不要扫全量档案）

    /// 某标的某交易日的分时点，按时间升序。O(1) 字典命中 + 已排好序的小数组。
    func intradayBars(code: String, day: String) -> [IntradayBar] {
        intradayBarsByCodeDay[Self.codeDayKey(code: code, day: day)] ?? []
    }

    /// 某标的已有分时记录的交易日，新的在前。
    func intradayDays(forCode code: String) -> [String] {
        (intradayDaySetByCode[code] ?? []).sorted(by: >)
    }

    /// 某标的某交易日已保存的分时点数。
    func intradayCount(code: String, day: String) -> Int {
        intradayBarsByCodeDay[Self.codeDayKey(code: code, day: day)]?.count ?? 0
    }

    /// 本机已有分时记录的全部代码（按档案里存的原始写法，未做 sh/sz 归一化）。
    /// 数量是「标的数」量级，遍历它做归一化匹配远比遍历全部分钟点便宜。
    var intradayCodes: [String] { Array(intradayDaySetByCode.keys) }

    /// 本机分时档案里出现过的全部交易日（倒序）。
    var intradayAllDays: [String] {
        var union = Set<String>()
        for days in intradayDaySetByCode.values { union.formUnion(days) }
        return union.sorted(by: >)
    }

    /// 把账本里的代码解析成档案里实际使用的那个写法。
    ///
    /// 档案可能存 `sh510300`，而自选/持仓里写的是 `510300`（或反过来）。
    /// 这里只遍历「标的数」量级的代码表做一次归一化比较，
    /// 取代以前「每只标的都把整份分钟档案扫一遍」的 O(标的 × 总点数) 写法。
    func resolvedIntradayCode(_ code: String) -> String {
        if intradayDaySetByCode[code] != nil { return code }
        let target = intradayCodeKey(code)
        for candidate in intradayDaySetByCode.keys where intradayCodeKey(candidate) == target {
            return candidate
        }
        return code
    }

    /// `code` → `day` → （总点数, 带有效 IOPV 的点数）。
    /// 供分时档案页做覆盖统计：只走 O(标的 × 交易日) 的字典操作，不遍历分钟点。
    var intradayCoverageByCode: [String: [String: (points: Int, iopvPoints: Int)]] {
        var result: [String: [String: (points: Int, iopvPoints: Int)]] = [:]
        for (_, list) in intradayBarsByCodeDay {
            guard let sample = list.first else { continue }
            var iopvPoints = 0
            for bar in list where (bar.iopv ?? 0) > 0 { iopvPoints += 1 }
            result[sample.code, default: [:]][sample.day] = (list.count, iopvPoints)
        }
        return result
    }

    /// 分时索引的唯一重建入口。**只在整批替换/首次载入时调用**；
    /// 增量合并请走 `mergeIntradayBars`（它只在真有变化时才会重活一次）。
    func rebuildIntradayMinuteIndex() {
        var byKey: [String: IntradayBar] = [:]
        byKey.reserveCapacity(intradayBars.count)
        var byCodeDay: [String: [IntradayBar]] = [:]
        var daySetByCode: [String: Set<String>] = [:]
        for bar in intradayBars {
            byKey[Self.intradayMinuteKey(code: bar.code, at: bar.timestamp)] = bar
            byCodeDay[Self.codeDayKey(code: bar.code, day: bar.day), default: []].append(bar)
            daySetByCode[bar.code, default: []].insert(bar.day)
        }
        // 每一天最多 242 个点：只对同一天内部排序，不做全量 sort。
        for key in Array(byCodeDay.keys) {
            guard let list = byCodeDay[key], list.count > 1 else { continue }
            byCodeDay[key] = list.sorted { $0.timestamp < $1.timestamp }
        }
        intradayBarByKey = byKey
        intradayBarsByCodeDay = byCodeDay
        intradayDaySetByCode = daySetByCode
        intradayMinuteKeys = Set(byKey.keys)
    }

    /// 本次合并里有没有「值得重建」的实质变化。
    ///
    /// 绝大多数合并都是空转：盘中每 15 秒的刷新、重开当天分时页、NAS 两天重叠回补，
    /// 拿到的分钟点通常与已存的完全一致。旧实现无论有没有变化都要重建整张 N 项字典
    /// 和 N 个新字符串键 —— 空转也付全价，档案越长越慢、峰值内存越高。
    private func intradayMergeWouldChange(_ bars: [IntradayBar]) -> Bool {
        for raw in bars {
            let bar = Self.normalizedIntradayBar(raw)
            let key = Self.intradayMinuteKey(code: bar.code, at: bar.timestamp)
            guard let prior = intradayBarByKey[key] else { return true }
            let volume = bar.volume ?? prior.volume
            let iopv = bar.iopv ?? prior.iopv
            if prior.price != bar.price || prior.volume != volume || prior.iopv != iopv || prior.day != bar.day {
                return true
            }
        }
        return false
    }
    private func dailyBarsURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(dailyBarsFilename)
    }
    private func loadDailyBars() {
        guard let url = dailyBarsURL(), let raw = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([DailyBar].self, from: raw) else { return }
        dailyBars = Dictionary(grouping: rows, by: \.code).mapValues { $0.sorted { $0.date < $1.date } }
        invalidateSignalCache()
    }
    func saveDailyBars() {
        guard let url = dailyBarsURL() else { return }
        // 逐级显式标注类型，避免编译器在链式泛型上做长时间推断。
        let allBars: [DailyBar] = dailyBars.values.flatMap { $0 }
        let rows: [DailyBar] = allBars.sorted { $0.code == $1.code ? $0.date < $1.date : $0.code < $1.code }
        let encoder = JSONEncoder()
        if let raw: Data = try? encoder.encode(rows) { try? raw.write(to: url, options: .atomic) }
    }
    func fetchDailyBars(code rawCode: String, count: Int = 640, force: Bool = false,
                        adjustment: String = "qfq") async throws -> [DailyBar] {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        // 个股 / ETF 是 6 位纯数字；指数是带市场前缀的腾讯代码（sh000001 / usIXIC）。
        // 交易日历要拿上证指数的日 K，所以这里不能再假设「代码一定全是数字」。
        let isPrefixed = !code.allSatisfy(\.isNumber)
        guard isPrefixed ? code.count >= 6 : code.count == 6 else { throw URLError(.badURL) }
        if adjustment == "qfq", !force, let cached = dailyBars[code], !cached.isEmpty { return cached }
        let symbol = isPrefixed ? code : tencentSymbol(code)
        // 行情走 iPhone 直连优先，NAS 仅作兜底（NAS 地址是给多设备同步用的，不应成为行情必经链路）
        let endpoints = [
            "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get",
            "https://ifzq.gtimg.cn/appstock/app/newfqkline/get",
            "https://web.ifzq.gtimg.cn/appstock/app/newfqkline/get"
        ]
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for endpoint in endpoints {
            guard var components = URLComponents(string: endpoint) else { continue }
            components.queryItems = [URLQueryItem(name: "param", value: "\(symbol),day,,,\(min(max(count, 30), 640)),\(adjustment)")]
            guard let url = components.url else { continue }
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 10
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let result = parseDailyBars(bytes, code: code, symbol: symbol, adjusted: adjustment == "qfq") ?? []
                guard !result.isEmpty else { throw URLError(.cannotParseResponse) }
                if adjustment == "qfq" {
                    dailyBars[code] = result
                    invalidateSignalCache(for: code)
                    saveDailyBars()
                }
                return result
            } catch { lastError = error }
        }
        // 直连全部失败后，最后才尝试 NAS 行情代理兜底
        if let proxyBytes = try? await NASSyncService.marketProxyData(path: "daily", queryItems: [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "count", value: String(min(max(count, 30), 640))),
            URLQueryItem(name: "fq", value: adjustment)
        ]), let result = parseDailyBars(proxyBytes, code: code, symbol: symbol, adjusted: adjustment == "qfq"), !result.isEmpty {
            if adjustment == "qfq" {
                dailyBars[code] = result
                invalidateSignalCache(for: code)
                saveDailyBars()
            }
            return result
        }
        if adjustment == "qfq", let cached = dailyBars[code], !cached.isEmpty { return cached }
        throw lastError
    }

    /// Generate the same clearly-labelled approximation used by the web client:
    /// infer possible cash distributions from raw vs. forward-adjusted ETF K lines.
    /// It only updates estimated events and never converts them into confirmed income.
    func refreshETFDividendEstimates(force: Bool = false) {
        let today = MarketCalendar.isoDay(.now)
        // 键里带 v2：这次把「自选里的 ETF」也纳入自动推算，口径变了，
        // 必须让老设备在升级后立刻重跑一次，否则要等到明天才生效。
        let key = "guanpan.native.dividendEstimate.lastRun.v2"
        if !force, UserDefaults.standard.string(forKey: key) == today { return }
        UserDefaults.standard.set(today, forKey: key)
        // 原来只算「持有的 ETF」。用户看股息率最多的地方其实是**自选列表**，
        // 自选里的 ETF 一直拿不到自动推算的分红事件，只能吃那张会过期的写死表。
        let held = data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }.map(\.code)
        let watched = data.quotes.map(\.code).filter { Self.looksLikeExchangeTradedFund($0) }
        let codes = Array(Set(held + watched))
            .filter { !ETFDividendProjection.knownNonDividendCodes.contains($0) }
        guard !codes.isEmpty else { return }
        Task {
            var estimates: [String: [ETFDividendEvent]] = [:]
            var completed = Set<String>()
            for code in codes {
                do {
                    let adjusted = try await fetchDailyBars(code: code, count: 640, force: force)
                    let raw = try await fetchDailyBars(code: code, count: 640, force: force, adjustment: "")
                    completed.insert(code)
                    let inferred = ETFDividendProjection.inferredEvents(code: code, adjusted: adjusted, raw: raw)
                    if !inferred.isEmpty { estimates[code] = inferred }
                } catch { continue }
            }
            let confirmed = data.etfDividendEvents.filter { $0.isEstimated != true }
            let untouchedEstimates = data.etfDividendEvents.filter {
                $0.isEstimated == true && !completed.contains($0.code)
            }
            let refreshed = estimates.values.flatMap { $0 }
            var byKey: [String: ETFDividendEvent] = [:]
            for event in untouchedEstimates + refreshed + confirmed {
                let key = "\(event.code)|\(event.date)"
                if event.isEstimated != true || byKey[key] == nil { byKey[key] = event }
            }
            data.etfDividendEvents = byKey.values.sorted { $0.date < $1.date }
            save(label: nil)
        }
    }

    /// App 恢复前台后同步 NAS、更新历史行情/净值，并补齐可核实的漏记快照。
    func ensureBackfillHistory() async {
        guard !isEnsuringBackfillHistory else { return }
        isEnsuringBackfillHistory = true
        defer { isEnsuringBackfillHistory = false }
        // 1) ETF / 证券：每次恢复前台都拉取最新日 K（最多 640 个交易日）。
        // 仅检查最早日期会漏掉 App 关闭期间的新交易日，导致快照重建缺少当日价格。
        let etfCodes = Set(data.holdings.filter { $0.kind == .etf }.map(\.code)
            + data.ledger.filter { ($0.kind ?? .etf) == .etf }.map(\.code))
        for code in etfCodes where code.count == 6 && code.allSatisfy(\.isNumber) {
            _ = try? await fetchDailyBars(code: code, count: 640, force: true)
        }
        // 2) 每次恢复前台都合并 NAS 独立采集的净值档案并刷新已公布序列。
        // 只在本机“完全没有历史”时才拉取，会让已有但过期的净值永远不补新日期。
        let fundCodes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code))
        if !fundCodes.isEmpty { _ = await refreshFundNAVsAndWait() }

        // 不依赖“本次有没有新增净值”来触发：App 关闭期间漏掉的 ETF 交易日，
        // 也要用刚拉回的日 K 自动补快照。手动核实的快照仍由重建函数保留。
        let reconciled = reconcileProvisionalSnapshotsAfterNAVUpdate()
        let rebuilt = backfillVerifiableSnapshots(audit: false)
        if reconciled > 0 {
            save(label: rebuilt.added > 0 ? "自动重建漏记历史快照" : "按最新历史数据核对快照")
        }
        // 网络报价与净值加载完成后再更新今天的临时快照，避免只保存启动时的旧行情。
        recordSnapshot(automatic: true)
    }

    /// 用上证指数日 K 反推交易日历：**有 K 线的日期就是交易日**。
    ///
    /// 这样不用人工维护年度休市表：交易所怎么安排，K 线里就怎么体现 ——
    /// 跨年不用补表，临时的休市（纪念日、台风）也能自动跟上。
    /// 拉到就整体覆盖；拉不到就保留上一次的，不清空（宁可旧，也不要空）。
    @discardableResult
    func refreshTradingCalendar(force: Bool = false) async -> Bool {
        if !force, MarketCalendar.fetchedToday { return false }
        do {
            let bars = try await fetchDailyBars(code: MarketCalendar.probeSymbol, count: 640, force: true)
            let days = Set(bars.map(\.date))
            // 太少说明这次没取全，覆盖上去反而会把交易日误判成休市。
            guard days.count > 120 else { return false }
            MarketCalendar.saveTradingDays(days)
            MarketCalendar.markFetched()
            return true
        } catch { return false }
    }

    private func parseDailyBars(_ bytes: Data, code: String, symbol: String, adjusted: Bool = true) -> [DailyBar]? {
        guard let text = String(data: bytes, encoding: .utf8),
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let node = data[symbol] as? [String: Any],
              let rows = adjusted ? ((node["qfqday"] as? [[Any]]) ?? (node["day"] as? [[Any]]))
                                  : ((node["day"] as? [[Any]]) ?? (node["qfqday"] as? [[Any]])) else { return nil }
        let parsed = rows.compactMap { row -> DailyBar? in
            guard row.count >= 6, let date = row[0] as? String else { return nil }
            let values = row[1...5].compactMap { item -> Double? in
                if let n = item as? NSNumber { return n.doubleValue }
                if let s = item as? String { return Double(s) }
                return nil
            }
            guard values.count == 5, values.allSatisfy(\.isFinite), values[1] > 0,
                  values[2] > 0, values[3] > 0, values[4] >= 0 else { return nil }
            return DailyBar(code: code, date: date, open: values[0], close: values[1], high: values[2], low: values[3], volume: values[4])
        }.sorted { $0.date < $1.date }
        // Tencent's overlapping pages can repeat a boundary date. Charts use date as
        // the Swift Charts identity, so collapse duplicates before exposing the series.
        return Dictionary(parsed.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
            .values.sorted { $0.date < $1.date }
    }
    func saveIntradayBars() {
        guard let url = gridBarsURL() else { return }
        // 原来这里是「每根 bar 单独 `encoder.encode` 再拼起来」：档案有几十万根时，
        // 等于几十万次 JSON 编码 + 几十万次 Data 追加。改成一次性编码整个数组，
        // 再把数组两端去掉、元素间换成换行 —— 落盘格式仍是「一行一条 JSON」，
        // `loadIntradayBars` 与 `appendIntradayBars` 的追加语义都不受影响。
        // （必须保持逐行格式：`appendIntradayBars` 是往文件尾追加行，写成一个整数组会追加坏。）
        guard let raw = try? JSONEncoder().encode(intradayBars) else { return }
        guard let text = String(data: raw, encoding: .utf8), text.count >= 2 else { return }
        let body = text.dropFirst().dropLast()
        let lineDelimited = Data(body.replacingOccurrences(of: "},{", with: "}\n{").utf8)
        try? lineDelimited.write(to: url, options: .atomic)
    }
    func appendIntradayBars(_ bars: [IntradayBar]) {
        guard !bars.isEmpty, let url = gridBarsURL() else { return }
        let encoder = JSONEncoder()
        var raw = Data()
        for bar in bars {
            guard let line = try? encoder.encode(bar) else { continue }
            raw.append(line); raw.append(0x0A)
        }
        guard !raw.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: raw)
        } catch { saveIntradayBars() }
    }
    func mergeIntradayBars(_ bars: [IntradayBar]) {
        guard !bars.isEmpty else { return }
        // ① 空转快速返回：绝大多数合并（盘中 15 秒刷新、重开当天分时页、NAS 两天重叠回补）
        //    拿到的分钟点与已存的完全一致。旧实现无论有没有变化都要为全部 N 个点重建
        //    一张字典和 N 个分钟键字符串，档案越长越慢、瞬时内存峰值越高 —— 打开分时 /
        //    日 K 时被系统杀进程（看起来就是闪退），往往就发生在这一步。
        //    先判一遍，没变化就 O(本次条数) 直接返回，不动任何状态。
        guard intradayMergeWouldChange(bars) else { return }
        // ② 以「分钟键索引」为底改写。`Dictionary` 是值语义，这里先共享存储，
        //    直到真正写入才复制一次，比重新计算 N 个分钟键字符串便宜得多。
        var byMinute = intradayBarByKey
        var changed: [IntradayBar] = []
        for raw in bars {
            var bar = Self.normalizedIntradayBar(raw)
            let key = Self.intradayMinuteKey(code: bar.code, at: bar.timestamp)
            if let prior = byMinute[key] {
                if bar.volume == nil { bar.volume = prior.volume }
                if bar.iopv == nil { bar.iopv = prior.iopv }
            }
            if let prior = byMinute[key], prior.price == bar.price && prior.volume == bar.volume && prior.iopv == bar.iopv && prior.day == bar.day { continue }
            byMinute[key] = bar
            changed.append(bar)
        }
        guard !changed.isEmpty else { return }
        intradayBarByKey = byMinute
        intradayBars = byMinute.values.sorted { $0.timestamp < $1.timestamp }
        rebuildIntradayMinuteIndex()
        appendIntradayBars(changed)
        // Keep live minute history in NAS without uploading on every 15-second quote poll.
        if Date().timeIntervalSince(lastIntradayNASSyncAt) >= 60 {
            lastIntradayNASSyncAt = .now
            if !applyingNASData { scheduleNASSync(delay: 2) }
        }
    }

    /// 从行情源补全某个标的最近交易日的整日分钟线并永久落盘。
    ///
    /// 这与交易时段内的逐点采集互为兜底：用户不必整天保持 App 在前台，收盘后或
    /// 下一次打开 App 时仍可一次拿回最近交易日约 242 个点。旧交易日不会被覆盖或删除。
    @discardableResult
    func fetchAndArchiveLatestIntraday(code rawCode: String) async throws -> [IntradayBar] {
        let parsed = try await fetchLatestIntradayBars(code: rawCode)
        mergeIntradayBars(parsed)
        return parsed
    }

    /// Pull previously collected NAS minutes into the local replay archive.
    /// This runs on app launch/resume; the NAS remains the durable source if the
    /// phone was offline during the trading session.
    @discardableResult
    func syncNASMarketArchive() async -> Int {
        do {
            let bars = try await NASSyncService.marketArchive()
            guard !bars.isEmpty else { return 0 }
            applyingNASData = true
            defer { applyingNASData = false }
            mergeIntradayBars(bars)
            return bars.count
        } catch {
            intradayArchiveStatus = "NAS 历史分时同步失败：\(error.localizedDescription)"
            return 0
        }
    }

    /// 只在首次可用时从旧网页备份回填一次 gridhist，不迁移或覆盖账户数据；
    /// 后续采集完全走行情源，网页删除或断开也不影响本机历史档案。
    private func fetchLegacyWebIntradayArchive(code requestedCode: String? = nil) async -> [IntradayBar] {
        guard !UserDefaults.standard.bool(forKey: legacyIntradayArchiveImportKey) else { return [] }
        let defaults = UserDefaults.standard
        let base = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            let legacy = try await NASSyncService.legacyBackup(base: base,
                token: NASCredentialStore.load() ?? "")
            guard let bytes = legacy.data,
                  let migrated = try? LegacyMigration.decodePackage(bytes) else { return [] }
            UserDefaults.standard.set(true, forKey: legacyIntradayArchiveImportKey)
            let matching = filterLegacyIntradayArchive(migrated.intradayBars, code: requestedCode)
            guard !matching.isEmpty else { return [] }
            mergeIntradayBars(matching)
            return matching
        } catch {
            return []
        }
    }

    private func filterLegacyIntradayArchive(_ bars: [IntradayBar], code requestedCode: String?) -> [IntradayBar] {
        guard let requestedCode else { return bars }
        let key = intradayCodeKey(requestedCode)
        return bars.filter { intradayCodeKey($0.code) == key }
    }

    private func intradayCodeKey(_ raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where code.hasPrefix(prefix) {
            return String(code.dropFirst(prefix.count))
        }
        return code
    }

    /// 只下载和解析，不触发落盘。批量归档时先收集全部标的、最后合并一次，
    /// 避免多年分钟档案被每只标的重复建立整份去重字典。
    private func fetchLatestIntradayBars(code rawCode: String) async throws -> [IntradayBar] {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw URLError(.badURL) }
        let symbol = tencentSymbol(code)
        var parsed: [IntradayBar] = []
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        let isUS = symbol.lowercased().hasPrefix("us")
        let path = isUS ? "usMinute" : "minute"
        for host in (isUS ? ["web.ifzq.gtimg.cn"] : ["web.ifzq.gtimg.cn", "ifzq.gtimg.cn"]) {
            guard let url = URL(string: "https://\(host)/appstock/app/\(path)/query?_var=min_archive_\(Int(Date().timeIntervalSince1970))&code=\(symbol)") else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                parsed = parseTencentMinuteData(bytes, symbol: symbol)
                if !parsed.isEmpty { break }
                lastError = URLError(.cannotParseResponse)
            } catch {
                lastError = error
            }
        }
        // 腾讯盘中有时只返回最近一小段分钟点。与其把少量数据当作整日归档，
        // 再尝试东财 trends2；它能返回当天截至当前时刻的分钟序列。休市时以完整
        // 交易日作为目标，盘中则按已走过的交易分钟计算最低覆盖目标。
        let targetCount = expectedIntradayPointCount(now: .now, dataDay: parsed.last?.day, code: symbol)
        var eastmoney: [IntradayBar] = []
        // 只要有缺点就尝试第二行情源。原来的 90% 门槛会把 214/242 误当作够用，
        // 收盘后留下缺口，用户看到的就不是完整日线。
        if parsed.count < targetCount,
           let secid = eastmoneySecid(for: code) {
            eastmoney = await fetchEastmoneyMinutes(secid: secid)
        }

        // 收盘后的官方分钟序列仍可能因单个行情源限流而缺点。此时经已配置的
        // NAS 行情代理再取一次腾讯分钟数据并做并集；这条路径与 NAS 网页账本无关。
        let providerBars = parsed + eastmoney
        let providerDay = providerBars.map(\.day).max()
        let currentCombinedCount = Set(providerBars.filter { $0.day == providerDay }
            .map { Self.minuteStamp($0.timestamp) }).count
        var proxied: [IntradayBar] = []
        if currentCombinedCount < targetCount,
           let proxyBytes = try? await NASSyncService.marketProxyData(
               path: "minute", queryItems: [URLQueryItem(name: "code", value: symbol)]) {
            proxied = parseTencentMinuteData(proxyBytes, symbol: symbol)
        }
        guard !parsed.isEmpty || !eastmoney.isEmpty || !proxied.isEmpty else { throw lastError }
        // 通用解析器会以腾讯代码标识 bar；归档必须恢复用户账本中的纯代码，历史页才能命中。
        // 两个源按分钟并集；同一分钟优先保留腾讯价格，缺成交量时用东财补齐。
        // 后续 mergeIntradayBars 会把新行情覆盖到本机同一分钟的旧记录。
        let all = (parsed + eastmoney + proxied).filter { $0.price.isFinite && $0.price > 0 }
        guard let latestDay = all.map(\.day).max() else { throw lastError }
        var byMinute: [Int: IntradayBar] = [:]
        for bar in all where bar.day == latestDay {
            let key = Self.minuteStamp(bar.timestamp)
            if var prior = byMinute[key] {
                if prior.volume == nil { prior.volume = bar.volume }
                byMinute[key] = prior
            } else {
                byMinute[key] = bar
            }
        }
        return byMinute.values.map {
            IntradayBar(code: code, timestamp: $0.timestamp, price: $0.price,
                        volume: $0.volume, day: $0.day)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private func eastmoneySecid(for rawCode: String) -> String? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits: String
        let market: String
        if code.hasPrefix("sh"), code.dropFirst(2).count == 6 {
            market = "1"; digits = String(code.dropFirst(2))
        } else if code.hasPrefix("sz"), code.dropFirst(2).count == 6 {
            market = "0"; digits = String(code.dropFirst(2))
        } else if code.hasPrefix("bj"), code.dropFirst(2).count == 6 {
            market = "0"; digits = String(code.dropFirst(2))
        } else if code.count == 6 {
            digits = code
            market = ["5", "6", "9"].contains(String(code.prefix(1))) ? "1" : "0"
        } else {
            return nil
        }
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return "\(market).\(digits)"
    }

    private func expectedIntradayPointCount(now: Date, dataDay: String?, code: String? = nil) -> Int {
        if code?.lowercased().hasPrefix("us") == true { return 390 }
        let today = Self.shanghaiDay(now)
        guard dataDay == today, Self.isRegularTradingSession(now) else { return 242 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if minute <= 9 * 60 + 30 { return 1 }
        if minute <= 11 * 60 + 30 { return min(121, minute - (9 * 60 + 30) + 1) }
        if minute < 13 * 60 { return 121 }
        return min(242, 121 + minute - 13 * 60 + 1)
    }

    /// 补全全部自选和场内持仓最近交易日的分时。完整档案每 30 分钟检查一次；
    /// 若本机档案仍有缺点，则每 5 分钟重试，直到行情源补齐或用户手动停止使用。
    @discardableResult
    func archiveTrackedIntraday(force: Bool = false) async -> (success: Int, failure: Int) {
        guard !isArchivingIntraday else { return (0, 0) }
        let codes = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
        guard !codes.isEmpty else {
            intradayArchiveStatus = "没有可采集的自选或场内持仓"
            return (0, 0)
        }
        if !force {
            guard data.intradayCaptureEnabled else { return (0, 0) }
            let lastRun = UserDefaults.standard.object(forKey: intradayArchiveLastRunKey) as? Date ?? .distantPast
            let incomplete = codes.contains { code in
                let stored = resolvedIntradayCode(code)
                let latestDay = intradayDays(forCode: stored).first
                let count = latestDay.map { intradayCount(code: stored, day: $0) } ?? 0
                return count < expectedIntradayPointCount(now: .now, dataDay: latestDay, code: code)
            }
            let retryInterval: TimeInterval = incomplete ? 5 * 60 : 30 * 60
            guard Date().timeIntervalSince(lastRun) >= retryInterval else { return (0, 0) }
        }

        isArchivingIntraday = true
        intradayArchiveStatus = "正在补全 0/\(codes.count)…"
        defer { isArchivingIntraday = false }
        intradayArchiveStatus = "正在连接行情源补全最近交易日…"
        let webArchive = await fetchLegacyWebIntradayArchive()
        let codeKeys = codes.reduce(into: [String: String]()) { $0[$1] = intradayCodeKey($1) }
        let webArchiveByCode = Dictionary(grouping: webArchive, by: { intradayCodeKey($0.code) })
        var success = 0
        var failure = 0
        var downloaded: [IntradayBar] = []
        await withTaskGroup(of: (String, [IntradayBar]?).self) { group in
            for code in codes {
                group.addTask {
                    let latest = try? await self.fetchLatestIntradayBars(code: code)
                    if let latest, !latest.isEmpty { return (code, latest) }
                    let key = codeKeys[code] ?? code
                    let saved = webArchiveByCode[key] ?? []
                    return (code, saved.isEmpty ? nil : saved)
                }
            }
            while let (code, bars) = await group.next() {
                if let bars, !bars.isEmpty {
                    downloaded.append(contentsOf: bars)
                    success += 1
                } else {
                    failure += 1
                }
                intradayArchiveStatus = "正在补全 \(success + failure)/\(codes.count) · \(code)…"
            }
        }
        mergeIntradayBars(downloaded)
        if success > 0 { UserDefaults.standard.set(Date(), forKey: intradayArchiveLastRunKey) }
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        let pointCount = downloaded.count
        let latestDay = downloaded.map(\.day).max()
        let remaining = codes.filter { code in
            let stored = resolvedIntradayCode(code)
            let day = intradayDays(forCode: stored).first
            let count = day.map { intradayCount(code: stored, day: $0) } ?? 0
            return count < expectedIntradayPointCount(now: .now, dataDay: day, code: code)
        }.count
        let coverage = latestDay.map { "\($0) · 本次行情取回 \(pointCount) 点 · 本机已保存并去重" }
            ?? "行情源没有返回新分钟点"
        let retry = remaining > 0 ? " · \(remaining) 只未完整，5 分钟后自动重试" : " · 本机档案完整"
        intradayArchiveStatus = failure == 0
            ? "已更新 \(success) 只 · \(coverage)\(retry) · \(time)"
            : "已更新 \(success)/\(codes.count) 只，\(failure) 只未取到 · \(coverage)\(retry) · \(time)"
        return (success, failure)
    }
    /// - Parameter propagate: 是否把这次改动推给 NAS 与网页版账本。默认 `true`。
    ///   只有「自动记录当日快照」那种**纯估值刷新**才传 `false` —— 用户明确要求
    ///   「日内的持仓盈亏这些两边都会自动变，不需要实时同步，浪费穿透流量」。
    func save(label: String? = nil, propagate: Bool = true) {
        cachedLatestFundNAVKey = ""   // 净值可能变了，先把「最新净值」缓存作废
        guard let raw = try? JSONEncoder().encode(data) else { return }
        let defaults = UserDefaults.standard
        if !isUndoingSave, let previous = defaults.data(forKey: key), previous != raw {
            defaults.set(previous, forKey: undoKey)
            if let label, !applyingNASData {
                operationAudit.insert(OperationAuditRecord(date: .now, label: label, state: previous), at: 0)
                persistOperationAudit()
            }
        }
        defaults.set(raw, forKey: key)
        if !applyingNASData, propagate { scheduleNASSync() }
        // 账本一改就排队写回网页版（6 秒防抖）。用户的操作顺序常常是
        // 「App 里记一笔 → 切到浏览器打开观盘.html → 点下载」，所以这一份必须已经在 NAS 上。
        if !applyingNASData, propagate { scheduleWebLedgerWriteBack() }
    }

    /// `code → 最新净值点` 的缓存（v2.13.34）。
    ///
    /// 基金列表每一行都要问「这只基金最新净值是多少」。旧实现是每行对
    /// `data.fundNAVHistory` 做一次 `filter + max` —— 而这份历史每只基金最多 1800 个点，
    /// 十几只就是几万条；一屏十几行、滑动时每帧重算，等于每帧几万次字符串比较。
    /// 这是基金页「上下滑特别卡」的主因。这里缓存一份，写盘时作废。
    private var cachedLatestFundNAV: [String: FundNAVPoint] = [:]
    private var cachedLatestFundNAVKey = ""

    var latestFundNAVByCode: [String: FundNAVPoint] {
        let history = data.fundNAVHistory
        let key = "\(history.count)|\(history.last?.code ?? "")|\(history.last?.date ?? "")"
        if key == cachedLatestFundNAVKey { return cachedLatestFundNAV }
        var result: [String: FundNAVPoint] = [:]
        result.reserveCapacity(64)
        for point in history {
            if let existing = result[point.code] {
                if point.date > existing.date { result[point.code] = point }
            } else {
                result[point.code] = point
            }
        }
        cachedLatestFundNAV = result
        cachedLatestFundNAVKey = key
        return result
    }

    /// 保存 AI 最近结果，不占用“撤销上一次账本修改”的位置。
    /// 结果仍进入原生备份与 NAS，多设备打开时可以继续查看。
    func saveAIAnalysisCache() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(raw, forKey: key)
        if !applyingNASData { scheduleNASSync() }
    }

    /// 行情价格属于高频缓存，不应每 5–60 秒覆盖撤销点、触发整账本 NAS 上传。
    /// 最多每分钟落盘一次；用户主动保存、进入后台或退出页面时仍会保留最新状态。
    private func saveAutomaticMarketState(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAutomaticMarketSaveAt) >= 60 else { return }
        lastAutomaticMarketSaveAt = .now
        // **编码 + 落盘都搬到后台线程**（v2.13.34）。
        // 这一段原来在主线程上跑：`data` 里带着 `fundNAVHistory`（每只基金最多 1800 个点，
        // 十几只就是几万条）、全部流水、快照和分红事件，`JSONEncoder().encode(data)` 一次要
        // 几十上百毫秒。它每 60 秒被自动刷新调用一次，正好落在「刷新」这一刻 ——
        // 用户描述的就是「已经确认就是刷新的那一会就会卡」。
        // `PortfolioData` 是值类型，这里拿到的是一份 COW 快照，后台编码不会读到写了一半的状态。
        let snapshot = data
        let storageKey = key
        DispatchQueue.global(qos: .utility).async {
            guard let raw = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(raw, forKey: storageKey)
        }
    }

    func flushAutomaticMarketState() {
        saveAutomaticMarketState(force: true)
    }

    private func loadOperationAudit() {
        guard let raw = UserDefaults.standard.data(forKey: auditKey),
              let records = try? JSONDecoder().decode([OperationAuditRecord].self, from: raw) else { return }
        operationAudit = records
    }

    private func persistOperationAudit() {
        operationAudit = Array(operationAudit.prefix(20))
        var encoded = (try? JSONEncoder().encode(operationAudit)) ?? Data()
        // Bound persistent history to keep device storage predictable while retaining the newest action.
        while operationAudit.count > 1 && encoded.count > 1_500_000 {
            operationAudit.removeLast()
            encoded = (try? JSONEncoder().encode(operationAudit)) ?? Data()
        }
        UserDefaults.standard.set(encoded, forKey: auditKey)
    }

    var canUndoLatestOperation: Bool {
        guard let record = operationAudit.first else { return false }
        return (try? JSONDecoder().decode(PortfolioData.self, from: record.state)) != nil
    }

    @discardableResult
    func undoLatestOperation() -> String? {
        guard let record = operationAudit.first,
              let restored = try? JSONDecoder().decode(PortfolioData.self, from: record.state),
              let raw = try? JSONEncoder().encode(restored) else { return nil }
        isUndoingSave = true
        data = restored
        UserDefaults.standard.set(raw, forKey: key)
        operationAudit.removeFirst()
        persistOperationAudit()
        isUndoingSave = false
        if !applyingNASData { scheduleNASSync(delay: 0) }
        return record.label
    }

    func clearOperationAudit() {
        operationAudit.removeAll()
        UserDefaults.standard.removeObject(forKey: auditKey)
    }

    var canUndoLastSave: Bool { UserDefaults.standard.data(forKey: undoKey) != nil }
    func undoLastSave() -> Bool {
        let defaults = UserDefaults.standard
        guard let raw = defaults.data(forKey: undoKey),
              let restored = try? JSONDecoder().decode(PortfolioData.self, from: raw) else { return false }
        isUndoingSave = true
        data = restored
        defaults.set(raw, forKey: key)
        defaults.removeObject(forKey: undoKey)
        isUndoingSave = false
        if !applyingNASData { scheduleNASSync(delay: 0) }
        return true
    }

    func configureNASSync() {
        nasSyncTask?.cancel()
        nasPollingTask?.cancel()
        nasPollingTask = nil
        guard UserDefaults.standard.bool(forKey: NASSyncService.automaticKey) else {
            nasSyncStatus = "自动同步已关闭"
            return
        }
        let url = UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? ""
        guard !url.isEmpty else {
            nasSyncStatus = "请填写 NAS 地址；免口令模式可直接同步"
            return
        }
        scheduleNASSync(delay: 1)
        nasPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await synchronizeNASSafely()
            }
        }
    }

    func pauseNASSyncPolling() {
        flushAutomaticMarketState()
        nasPollingTask?.cancel()
        nasPollingTask = nil
        nasSyncTask?.cancel()
        nasSyncTask = nil
        // 退到后台时把网页版那份补齐：马上要去浏览器点「下载」了，
        // 这一趟不等防抖（防抖任务会被系统挂起，等不到）。
        scheduleWebLedgerWriteBack(delay: 0)
    }

    private func makeNASDocument() -> NativeSyncDocument {
        NativeSyncDocument(data: data, intradayBars: intradayBars,
                           dailyBars: dailyBars.values.flatMap { $0 }.sorted {
                               $0.code == $1.code ? $0.date < $1.date : $0.code < $1.code
                           })
    }

    private func hasNASUserData(_ document: NativeSyncDocument) -> Bool {
        let d = document.data
        return !d.holdings.isEmpty || !d.ledger.isEmpty || !d.fundTransactions.isEmpty ||
            !d.fundNAVHistory.isEmpty || !d.fundFeePolicies.isEmpty || !d.fundDCAPlans.isEmpty ||
            !d.cashFlows.isEmpty || !d.snapshots.isEmpty || !d.quotes.isEmpty || !d.quoteAlerts.isEmpty ||
            !d.manualQuoteOverrides.isEmpty || !d.etfDividendEvents.isEmpty ||
            !d.allocationTargets.isEmpty || !d.tradePlans.isEmpty || !d.dayGridPlans.isEmpty ||
            !d.legacyGridArchives.isEmpty || !d.legacyShadowArchives.isEmpty || !d.legacyDCAEvents.isEmpty ||
            !d.legacySettingsArchives.isEmpty || d.savedAccountAIAnalysis != nil || d.savedPortraitAIAnalysis != nil ||
            !d.savedInstrumentAIAnalyses.isEmpty || d.cash != 0 || d.cashLinkedByDefault || d.appearance != .system ||
            d.quoteRefreshSeconds != 60 || d.dailyPnLMode != .pnl || d.intradaySubchartMode != "macd" || d.dailyChartRangeDays != 250 || d.intradayLineColorMode != .automatic || !d.intradayCaptureEnabled || d.automaticFundNAVRefreshEnabled || d.costAccountingMode != .diluted || d.globalPositionLimitPercent != 0 || !d.positionHintsEnabled || d.rebalanceAlertThreshold != 5 || d.investmentProfile.style != "swing" || d.investmentProfile.risk != "bal" ||
            d.aiAnalysisConfig.endpoint != AIAnalysisConfig().endpoint || d.aiAnalysisConfig.model != AIAnalysisConfig().model || d.aiAnalysisConfig.timeoutSeconds != AIAnalysisConfig().timeoutSeconds || d.aiAnalysisConfig.systemPrompt != AIAnalysisConfig().systemPrompt ||
            d.investmentProfile.maxPositionPercent != 35 || d.investmentProfile.horizon != "1-3个月" ||
            !d.investmentProfile.preference.isEmpty || !d.investmentProfile.avoid.isEmpty ||
            !d.investmentProfile.method.isEmpty || !d.investmentProfile.goal.isEmpty ||
            !document.intradayBars.isEmpty || !document.dailyBars.isEmpty
    }

    private func scheduleNASSync(delay: UInt64 = 4) {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        guard defaults.bool(forKey: NASSyncService.automaticKey), !url.isEmpty else { return }
        nasSyncTask?.cancel()
        nasSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await synchronizeNASSafely()
            // 原生账本同步完，再把账本按网页格式写回一份 —— 这样在 App 里买卖之后，
            // 网页版打开也能看到同样的持仓与现金（以前两边是永久分叉的）。
            await writeBackWebLedgerIfEnabled()
        }
    }

    func synchronizeNASSafely() async {
        guard !applyingNASData, !isSynchronizingNAS else { return }
        isSynchronizingNAS = true
        defer { isSynchronizingNAS = false }
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        let token = NASCredentialStore.load() ?? ""
        guard !url.isEmpty else { nasSyncStatus = "请填写 NAS 地址；免口令模式可直接同步"; return }
        do {
            nasSyncStatus = "正在检查 NAS…"
            let local = makeNASDocument()
            let localFingerprint = try NASSyncService.fingerprint(local)
            let baseline = defaults.string(forKey: NASSyncService.fingerprintKey)
            let knownRevision = defaults.integer(forKey: NASSyncService.revisionKey)

            // ── 快速通道：先问一句版本号，再决定要不要把整份文档拉回来 ──────────
            // `/api/ping` 只回两个文档的版本号（几十字节，见 `NASSyncService.probeRevisions`）。
            // 远端版本号和本机记住的一致 → NAS 没被别人改过 → 就不需要下载整份原生文档。
            // 这一份文档里塞着**全部分时与日 K 档案**，分钟级轮询整个拉回来只为比一个指纹，
            // 是穿透流量最大的一笔（用户原话：「一直同步呀，多浪费我的穿透流量」）。
            // 探针失败、服务器没实现、或版本号确实变了 → 静默走下面的完整同步，行为不变。
            if knownRevision > 0,
               let probe = try? await NASSyncService.probeRevisions(base: url),
               let remoteRevision = probe["native"], remoteRevision == knownRevision {
                if localFingerprint == baseline {
                    nasSyncStatus = "已同步（版本 \(remoteRevision)）"
                    return
                }
                // 远端没动、本机动过 → 直接上传，同样省掉一次完整下载。
                // 万一这段时间 NAS 又被别人改了，服务端会回 409，落到下面走完整流程。
                if let result = try? await NASSyncService.put(base: url, token: token, document: local,
                                                              expectedRevision: remoteRevision) {
                    recordNASSync(revision: result.revision, document: local)
                    nasSyncStatus = "已同步到 NAS（版本 \(result.revision)）"
                    return
                }
            }

            let remote = try await NASSyncService.get(base: url, token: token)
            guard let remoteDocument = remote.data else {
                let legacy = try await NASSyncService.legacyBackup(base: url, token: token)
                if let legacyBytes = legacy.data,
                   let migrated = try? LegacyMigration.decodePackage(legacyBytes) {
                    let migratedDocument = NativeSyncDocument(data: migrated.data,
                        intradayBars: migrated.intradayBars, dailyBars: [])
                    if hasNASUserData(migratedDocument) {
                        if !hasNASUserData(local) {
                            applyNASDocument(migratedDocument)
                            let imported = makeNASDocument()
                            let result = try await NASSyncService.put(base: url, token: token,
                                document: imported, expectedRevision: remote.revision)
                            recordNASSync(revision: result.revision, document: imported)
                            nasSyncStatus = "已将 NAS 网页账本迁入原生空间并同步（版本 \(result.revision)）"
                        } else if try NASSyncService.fingerprint(migratedDocument) == localFingerprint {
                            let result = try await NASSyncService.put(base: url, token: token,
                                document: local, expectedRevision: remote.revision)
                            recordNASSync(revision: result.revision, document: local)
                            nasSyncStatus = "本机与 NAS 网页账本一致，已建立原生同步（版本 \(result.revision)）"
                        } else {
                            nasSyncStatus = "NAS 有网页账本，本机也有不同数据；为避免覆盖，请先导出本机备份并选择同步方向"
                        }
                        return
                    }
                }
                if hasNASUserData(local) {
                    let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                              expectedRevision: remote.revision)
                    recordNASSync(revision: result.revision, document: local)
                    nasSyncStatus = "已上传到 NAS（版本 \(result.revision)）"
                } else {
                    recordNASSync(revision: remote.revision, document: local)
                    nasSyncStatus = "NAS 暂无数据"
                }
                return
            }
            let remoteFingerprint = try NASSyncService.fingerprint(remoteDocument)
            if baseline == nil {
                if !hasNASUserData(local) {
                    applyNASDocument(remoteDocument)
                    recordNASSync(revision: remote.revision, document: remoteDocument)
                    nasSyncStatus = "已从 NAS 恢复（版本 \(remote.revision)）"
                } else if localFingerprint == remoteFingerprint {
                    recordNASSync(revision: remote.revision, document: local)
                    nasSyncStatus = "本机与 NAS 数据一致"
                } else {
                    nasSyncStatus = "本机和 NAS 都有数据，请选择下载或上传，自动同步已暂停"
                }
                return
            }
            if remote.revision == knownRevision {
                if localFingerprint != baseline {
                    let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                              expectedRevision: remote.revision)
                    recordNASSync(revision: result.revision, document: local)
                    nasSyncStatus = "已同步到 NAS（版本 \(result.revision)）"
                } else {
                    nasSyncStatus = "已同步（版本 \(remote.revision)）"
                }
            } else if localFingerprint == baseline {
                applyNASDocument(remoteDocument)
                recordNASSync(revision: remote.revision, document: remoteDocument)
                nasSyncStatus = "已接收另一台设备的数据（版本 \(remote.revision)）"
            } else if remoteFingerprint == baseline {
                let result = try await NASSyncService.put(base: url, token: token, document: local,
                                                          expectedRevision: remote.revision)
                recordNASSync(revision: result.revision, document: local)
                nasSyncStatus = "已上传本机更改（版本 \(result.revision)）"
            } else {
                nasSyncStatus = "本机和 NAS 都有新更改，已暂停自动覆盖；请先下载备份再选择同步方向"
            }
        } catch {
            nasSyncStatus = "NAS 同步失败：\(error.localizedDescription)"
        }
    }

    func downloadFromNAS() async {
        let defaults = UserDefaults.standard
        do {
            let response = try await NASSyncService.get(
                base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "")
            if let document = response.data {
                applyNASDocument(document)
                recordNASSync(revision: response.revision, document: document)
                nasSyncStatus = "已从 NAS 下载（版本 \(response.revision)）"
                return
            }
            let legacy = try await NASSyncService.legacyBackup(
                base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "")
            guard let bytes = legacy.data, let migrated = try? LegacyMigration.decodePackage(bytes) else {
                nasSyncStatus = "NAS 当前没有可识别的原生或网页账本数据"
                return
            }
            let imported = NativeSyncDocument(data: migrated.data, intradayBars: migrated.intradayBars, dailyBars: [])
            applyNASDocument(imported)
            let saved = makeNASDocument()
            let result = try await NASSyncService.put(base: defaults.string(forKey: NASSyncService.urlKey) ?? "",
                token: NASCredentialStore.load() ?? "", document: saved, expectedRevision: response.revision)
            recordNASSync(revision: result.revision, document: saved)
            nasSyncStatus = "网页账本已迁入原生空间（版本 \(result.revision)）"
        } catch { nasSyncStatus = "下载失败：\(error.localizedDescription)" }
    }

    func uploadToNAS(allowEmptyOverwrite: Bool = false) async {
        let defaults = UserDefaults.standard
        do {
            let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
            let token = NASCredentialStore.load() ?? ""
            let remote = try await NASSyncService.get(base: url, token: token)
            let document = makeNASDocument()
            let result = try await NASSyncService.put(base: url, token: token, document: document,
                expectedRevision: remote.revision, allowEmptyOverwrite: allowEmptyOverwrite)
            recordNASSync(revision: result.revision, document: document)
            nasSyncStatus = "已上传到 NAS（版本 \(result.revision)）"
        } catch { nasSyncStatus = "上传失败：\(error.localizedDescription)" }
        await writeBackWebLedgerIfEnabled()
    }

    // MARK: - 写回网页版账本（App 为准）
    //
    // 背景：App 与网页版在 NAS 上是**两份不同的文档** —— App 走 `/api/native/data`，
    // 网页走 `/api/data`。迁移只发生一次（原生空间为空时才把网页账本迁进来），之后两边
    // 永久分叉：在 App 里卖掉，网页版纹丝不动。这一段就是补上那条缺失的「App → 网页」。
    //
    // 安全约束（宁可这次不同步，也不能弄坏数据）：
    // ① 本机没有用户数据（空账本）→ 直接跳过，绝不拿空文档覆盖网页那份；
    // ② 读不到现有网页账本（HTTP 错误 / 返回体不是 JSON）→ 跳过并报错，不做「整份重建」；
    // ③ 写回前先把现有那份原样备份到本机（只留最近一次），可一键还原；
    // ④ 只替换账本字段，其余键（设置 / 分红参考 / 汇率 / 休市日 / 网格历史）原样保留。

    var webLedgerWriteBackEnabled: Bool {
        let defaults = UserDefaults.standard
        // **默认开**（前提：已经配了 NAS 地址）。
        //
        // 第一版把它做成默认关，结果用户升级后打开网页版一「下载」，看到的还是老数据 ——
        // 功能等于没做。用户对这件事的要求是明确的「App 为准」，那就该默认按 App 走；
        // 而且这条链路本来就有四道保护（空账本跳过、读不回就放弃、写前备份、可一键还原），
        // 误伤面很小。用户一旦手动关过，就以他关的那个状态为准，不再自动翻回来。
        guard let stored = defaults.object(forKey: NASSyncService.webLedgerKey) as? Bool else {
            let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return stored
    }

    /// 这个开关是「用户亲自设过」的，还是走的默认值。界面据此决定要不要提示默认行为。
    var webLedgerWriteBackIsExplicit: Bool {
        UserDefaults.standard.object(forKey: NASSyncService.webLedgerKey) != nil
    }

    /// 本机是否存有「上一次写回前」的网页账本备份。
    var hasWebLedgerBackup: Bool {
        UserDefaults.standard.data(forKey: NASSyncService.webLedgerBackupKey) != nil
    }

    var webLedgerBackupDate: Date? {
        UserDefaults.standard.object(forKey: NASSyncService.webLedgerBackupDateKey) as? Date
    }

    func setWebLedgerWriteBack(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: NASSyncService.webLedgerKey)
        if enabled {
            Task { await writeBackWebLedger(reason: "开启后首次") }
        } else {
            assignIfChanged(\.webLedgerStatus, "已关闭自动写回")
        }
    }

    /// 自动路径：只在**网页账本的内容真的变了**的时候写回，一次请求都不多发。
    ///
    /// 判据是 `WebLedgerWriter.ledgerFingerprint`，它只覆盖会被写出去的账本字段：
    /// 现价、涨跌幅、日内估值、分钟 / 日 K 档案一律**不算改动** ——
    /// 那些东西两边各自会算、会采（用户原话：「日内的持仓盈亏这些，两边都会自动变的，
    /// 不需要实时同步」「应该是更改了才同步吧，多浪费我的穿透流量」）。
    /// 所以交易时段里前台来回切、行情每 15 秒刷一轮、分时档案每分钟多一个点，
    /// 这里都是空转。
    func writeBackWebLedgerIfEnabled() async {
        guard webLedgerWriteBackEnabled else { return }
        let stamp = WebLedgerWriter.ledgerFingerprint(of: data)
        guard !stamp.isEmpty, stamp != lastWebLedgerWrittenFingerprint else { return }
        _ = await writeBackWebLedger(reason: "自动")
    }

    /// 防抖版的写回触发：`save()` 里每改一次账本都会调它，但真正发请求要等 6 秒静默期。
    ///
    /// **为什么不挂在 `scheduleNASSync` 上**：那条链路的第一行就是
    /// `guard defaults.bool(forKey: automaticKey)` ——「自动同步」关掉就整个不走。
    /// 可「App 账本 → 网页版」是另一件事，是用户明确要的方向（App 为准），
    /// 不该被另一个开关连带关掉，否则又回到「网页版下载还是老数据」。
    /// 只要求「配了 NAS 地址 + 写回开关是开的」。
    func scheduleWebLedgerWriteBack(delay: UInt64 = 6) {
        guard webLedgerWriteBackEnabled else { return }
        let url = UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? ""
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        webLedgerWriteBackTask?.cancel()
        webLedgerWriteBackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await writeBackWebLedgerIfEnabled()
        }
    }

    /// 把本机原生账本写回 NAS 上的**网页格式**账本（`/api/data`）。
    @discardableResult
    func writeBackWebLedger(reason: String) async -> Bool {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        guard !url.isEmpty else {
            assignIfChanged(\.webLedgerStatus, "未配置 NAS 地址，无法写回")
            return false
        }
        let local = makeNASDocument()
        // ① 空账本保护
        guard hasNASUserData(local) else {
            assignIfChanged(\.webLedgerStatus, "本机账本为空，已跳过写回（不会去清空网页版）")
            return false
        }
        let token = NASCredentialStore.load() ?? ""
        do {
            // ② 先读回现有那份：读不到就放弃，不做整份重建
            let existing = try await NASSyncService.webLedger(base: url, token: token)
            // ③ 写回前留一份原样备份
            if let existing,
               let raw = try? JSONSerialization.data(withJSONObject: existing, options: [.fragmentsAllowed]) {
                defaults.set(raw, forKey: NASSyncService.webLedgerBackupKey)
                defaults.set(Date(), forKey: NASSyncService.webLedgerBackupDateKey)
            }
            // ④ 只替换账本字段
            let document = WebLedgerWriter.document(from: data, merging: existing)
            let revision = try await NASSyncService.putWebLedger(base: url, token: token, payload: document)
            // ⑤ 写完立刻读回来核对。
            //
            // 用户的要求是「数据要准确，不能乱来」——只说一句「已写回」不足以让人放心，
            // 因为「写成功但网页下到的还是旧的」这种中间态真的会发生（比如写到了另一份文档、
            // 或服务端按 revision 拒了却又返回了 200）。这里把网页端实际会拿到的那份读回来，
            // 只比最显眼的几个数（现金 / 自选 / 场内持仓 / 流水 / 场外持仓），不一致就明说。
            let readBack = try? await NASSyncService.webLedger(base: url, token: token)
            let verification = Self.webLedgerConsistencyNote(written: document, readBack: readBack)
            let etfCount = data.holdings.filter { $0.kind == .etf }.count
            let fundCount = data.holdings.filter { $0.kind == .fund }.count
            let stamp = Date.now.formatted(date: .omitted, time: .shortened)
            let action = existing == nil ? "已新建网页账本" : "已写回网页账本"
            assignIfChanged(\.webLedgerStatus,
                "\(action)（\(reason)）· 场内 \(etfCount) 只 · 场外 \(fundCount) 只 · "
                + "流水 \(data.ledger.count) 笔 · 版本 \(revision) · \(stamp)\(verification)")
            // 成功之后才记指纹。失败（NAS 不可达、读不回、版本冲突…）时不能记，
            // 否则会被当成「这份内容已经写过了」，之后再也不补。
            lastWebLedgerWrittenFingerprint = WebLedgerWriter.ledgerFingerprint(of: data)
            return true
        } catch {
            assignIfChanged(\.webLedgerStatus, "写回失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 写回后的轻量核对：只比「页面上最显眼的那几个数」，不逐字节比整份 JSON。
    ///
    /// 逐字节比会被服务端对键顺序/数字格式的再序列化搞出假报警；
    /// 而现金、自选数、场内持仓数、流水条数、场外持仓数这几项只要对得上，
    /// 网页版「下载」拿到的就是这份 App 账本。
    private static func webLedgerConsistencyNote(written: [String: Any], readBack: [String: Any]?) -> String {
        guard let readBack else { return " · ⚠️ 写完读不回来，请在网页版点一次「下载」确认" }
        func number(_ root: [String: Any], _ key: String) -> Double? {
            if let value = root[key] as? Double { return value }
            if let value = root[key] as? NSNumber { return value.doubleValue }
            return nil
        }
        func count(_ root: [String: Any], _ path: [String]) -> Int? {
            var node: Any = root
            for key in path {
                guard let dict = node as? [String: Any], let next = dict[key] else { return nil }
                node = next
            }
            return (node as? [Any])?.count
        }
        var mismatches: [String] = []
        if let a = number(written, "cash"), let b = number(readBack, "cash"), abs(a - b) > 0.005 {
            mismatches.append("现金 \(a.cny()) → \(b.cny())")
        }
        let fields: [(String, [String])] = [
            ("自选", ["db", "watch"]),
            ("场内持仓", ["db", "hold"]),
            ("场内流水", ["db", "trades"]),
            ("网页流水", ["tr"]),
            ("场外持仓", ["fund", "hold"]),
            ("场外流水", ["fund", "trades"])
        ]
        for (label, path) in fields {
            guard let a = count(written, path), let b = count(readBack, path) else { continue }
            if a != b { mismatches.append("\(label) \(a) → \(b)") }
        }
        if mismatches.isEmpty { return " · 已读回核对一致 ✅" }
        return " · ⚠️ 读回不一致：\(mismatches.joined(separator: "、"))"
    }

    /// 误覆盖时的后悔药：把「上一次写回之前」的那份网页账本原样写回去。
    @discardableResult
    func restorePreviousWebLedger() async -> Bool {
        let defaults = UserDefaults.standard
        let url = defaults.string(forKey: NASSyncService.urlKey) ?? ""
        guard !url.isEmpty,
              let raw = defaults.data(forKey: NASSyncService.webLedgerBackupKey),
              let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            assignIfChanged(\.webLedgerStatus, "没有可还原的网页账本备份")
            return false
        }
        do {
            let revision = try await NASSyncService.putWebLedger(
                base: url, token: NASCredentialStore.load() ?? "", payload: payload)
            let stamp = Date.now.formatted(date: .omitted, time: .shortened)
            assignIfChanged(\.webLedgerStatus, "已还原写回前的网页账本 · 版本 \(revision) · \(stamp)")
            return true
        } catch {
            assignIfChanged(\.webLedgerStatus, "还原失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 应用从 NAS 下载的文档。
    ///
    /// 关键安全点：**分时与日 K 走「合并」而不是「整段替换」**。
    /// 之前这里是 `replaceData(... intradayBars: document.intradayBars)`，会把本机还
    /// 没上传过的分钟点整段清空 —— 用户明确要求「不要弄丢数据」。现在本机独有的
    /// 分钟点（远端没有的）会原样保留，与远端同键的（远端为准）覆盖，账本主体仍以
    /// NAS 为准整段替换（账本冲突由上层 revision 指纹机制裁决，不在这里混）。
    private func applyNASDocument(_ document: NativeSyncDocument) {
        applyingNASData = true
        if !document.intradayBars.isEmpty { mergeIntradayBars(document.intradayBars) }
        if !document.dailyBars.isEmpty { mergeDailyBars(document.dailyBars) }
        replaceData(document.data)
        applyingNASData = false
    }

    /// 把远端日 K 合并进本机（按 代码+日期 去重，远端为准）。本机独有的交易日保留。
    private func mergeDailyBars(_ incoming: [DailyBar]) {
        var byKey: [String: DailyBar] = [:]
        for (code, arr) in dailyBars where !arr.isEmpty {
            for b in arr { byKey["\(code)|\(b.date)"] = b }
        }
        for b in incoming { byKey["\(b.code)|\(b.date)"] = b }
        let grouped = Dictionary(grouping: byKey.values, by: \.code)
        dailyBars = grouped.mapValues { $0.sorted { $0.date < $1.date } }
        invalidateSignalCache()
        saveDailyBars()
    }

    private func recordNASSync(revision: Int, document: NativeSyncDocument) {
        let defaults = UserDefaults.standard
        defaults.set(revision, forKey: NASSyncService.revisionKey)
        if let fingerprint = try? NASSyncService.fingerprint(document) {
            defaults.set(fingerprint, forKey: NASSyncService.fingerprintKey)
        }
    }
    /// 优先读取腾讯 ETF 报价字段 78 的净值参考，缺失时才用字段 77 溢价率反推。
    /// 不用场外基金净值或昨收数据冒充 IOPV。
    func lookupETFRealtimeIOPV(code rawCode: String) async throws -> (value: Double, premiumPercent: Double?, updatedAt: Date?)? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let symbol = tencentSymbol(code)
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(symbol)&_t=\(Int(Date().timeIntervalSince1970))") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        var bytes: Data
        do {
            let (direct, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            bytes = direct
        } catch {
            if let proxied = try? await NASSyncService.marketProxyData(path: "quote", queryItems: [URLQueryItem(name: "codes", value: symbol)]) {
                bytes = proxied
            } else {
                throw error
            }
        }
        var quote = parseTencent(decodeTencent(bytes))[symbol]
        // 直连有时只回基础行情（HTTP 200），但没有 ETF 扩展字段。
        // 此时也要尝试 NAS 的同一腾讯行情代理，不能只在网络报错时兜底。
        if quote?.iopv == nil && quote?.premiumPct == nil,
           let proxied = try? await NASSyncService.marketProxyData(
                path: "quote", queryItems: [URLQueryItem(name: "codes", value: symbol)]),
           let proxyQuote = parseTencent(decodeTencent(proxied))[symbol] {
            quote = proxyQuote
        }
        guard let quote else { return nil }
        let value: Double
        if let rawNAV = quote.iopv, rawNAV.isFinite, rawNAV > 0 {
            value = rawNAV
        } else if let premium = quote.premiumPct, (1 + premium / 100) > 0 {
            value = quote.price / (1 + premium / 100)
        } else if let sinaValue = await fetchSinaFundIOPVs(codes: [code])[code], sinaValue.isFinite, sinaValue > 0 {
            // 腾讯这条路彻底拿不到字段时，再问新浪基金接口一次。
            // 溢价率这时就用「现价 ÷ 新浪 IOPV − 1」，与腾讯自己算 77 字段的口径一致。
            value = sinaValue
            return (value, quote.price / sinaValue * 100 - 100, quote.timestamp)
        } else {
            return nil
        }
        guard value.isFinite, value > 0 else { return nil }
        return (value, quote.premiumPct, quote.timestamp)
    }

    func lookupETFQuote(code rawCode: String) async throws -> Quote? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let symbol = tencentSymbol(code)
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(symbol)&_t=\(Int(Date().timeIntervalSince1970))") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let bytes: Data
        do {
            let (directBytes, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            bytes = directBytes
        } catch {
            // 直连失败时才走 NAS 行情代理兜底
            if let proxied = try? await NASSyncService.marketProxyData(path: "quote", queryItems: [URLQueryItem(name: "codes", value: symbol)]) {
                bytes = proxied
            } else { throw error }
        }
        let text = decodeTencent(bytes)
        guard let quote = parseTencent(text)[symbol], !quote.name.isEmpty else { return nil }
        return Quote(code: code, name: quote.name, price: quote.price,
                     changePct: quote.changePct, updatedAt: quote.timestamp)
    }

    /// 添加场外基金时按六位代码识别基金名称，并顺带返回最近已公布净值。
    /// 与净值刷新保持同一数据源和 NAS 回退链路，避免出现“添加时查不到、保存后刷新却能查到”。
    func lookupFundInfo(code rawCode: String) async throws -> (name: String, nav: Double?)? {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return nil }
        let cachedName = data.holdings.first(where: { $0.kind == .fund && $0.code == code && !$0.name.isEmpty })?.name
            ?? data.fundTransactions.first(where: { $0.code == code && !$0.name.isEmpty })?.name
        let cachedNAV = data.fundNAVHistory.filter { $0.code == code }.max(by: { $0.date < $1.date })?.nav
        guard let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(code).js") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
        let bytes: Data
        do {
            let (directBytes, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            bytes = directBytes
        } catch {
            if let proxied = try? await NASSyncService.marketProxyData(
                path: "fundnav", queryItems: [URLQueryItem(name: "code", value: code)]) {
                bytes = proxied
            } else if let cachedName {
                return (cachedName, cachedNAV)
            } else { throw error }
        }
        guard let text = String(data: bytes, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?:var\s+)?fS_name\s*=\s*\"((?:\\.|[^\"\\])*)\"\s*;"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return cachedName.map { ($0, cachedNAV) }
        }
        let escapedName = String(text[range])
        let nameData = Data("\"\(escapedName)\"".utf8)
        let decodedName = (try? JSONDecoder().decode(String.self, from: nameData)) ?? escapedName
        let name = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let nav = Self.parseFundNAVScript(bytes, code: code)?.last?.nav
        return (name, nav)
    }

    func refreshQuotes() {
        // 重入保护从 `isRefreshingQuotes` 换成这个**非发布**的标记：
        // 自动轮询不再动 `@Published`（见 `performQuoteRefresh` 的说明），
        // 但「同一时刻只跑一轮」的语义必须保留，所以单独用一个变量挡。
        guard !autoRefreshInFlight, !isRefreshingQuotes else { return }
        autoRefreshInFlight = true
        Task {
            _ = await performQuoteRefresh(captureIntraday: true)
            autoRefreshInFlight = false
        }
    }

    func refreshQuotesForBackground() async -> Bool {
        guard data.quoteRefreshSeconds > 0, !autoRefreshInFlight, !isRefreshingQuotes else { return false }
        autoRefreshInFlight = true
        defer { autoRefreshInFlight = false }
        return await performQuoteRefresh(captureIntraday: false)
    }

    /// 供 `.refreshable` 使用。
    /// 原来的 `refreshQuotes()` 是「发起后立刻返回」，下拉转圈会瞬间消失，看着像没刷新。
    /// 这里 await 到真正拿完（或失败）为止，转圈时长与真实耗时一致。
    @discardableResult
    func refreshQuotesAndWait() async -> Bool {
        guard !isRefreshingQuotes else { return false }
        return await performQuoteRefresh(captureIntraday: true, manual: true)
    }

    // MARK: - 首页指数条

    /// 首页右上角那一个刷新按钮：个股和指数一起刷。
    ///
    /// 指数不在 `data.quotes` 里，走的是另一条请求，所以单个 `refreshQuotes()`
    /// 不会带上它；但用户眼里「刷新」就一个动作，这里替他把两件事都做掉。
    func refreshEverything() {
        refreshQuotes()
        refreshIndexQuotes()
    }

    func refreshIndexQuotes() {
        guard !autoIndexRefreshInFlight, !isRefreshingIndices else { return }
        autoIndexRefreshInFlight = true
        Task {
            await performIndexRefresh()
            autoIndexRefreshInFlight = false
        }
    }

    /// 指数条刷新。与个股行情分开的原因：
    /// ①指数不在自选/持仓里，一条没有也不该让整个请求早退（新装用户没有自选时也要看得到大盘）；
    /// ②指数不需要写进账本、不需要触发提醒、不需要抓分时，共用 `performQuoteRefresh`
    /// 会把 `data.quotes` / `marketChanges` 弄脏。
    ///
    /// v2.13 起改成**腾讯 + 东财 + 新浪三源并行**：腾讯覆盖 A 股 / 港股 / 美股，
    /// 新浪补腾讯没有的日经与东证，东财最后兜底。三个请求分开发是有意的 ——
    /// 任一源被限流或抽风，另一边的指数照常显示，不会因为「一条请求全挂」让整排变空白。
    @discardableResult
    func performIndexRefresh(manual: Bool = false) async -> Bool {
        guard !isRefreshingIndices else { return false }
        // 与个股行情同理：`isRefreshingIndices` 是 `@Published`，自动轮询不发它，
        // 免得每 15 秒为了一个转圈状态把整棵视图树重建两遍。
        if manual { isRefreshingIndices = true }
        defer { if manual { isRefreshingIndices = false } }

        async let fromTencent = fetchTencentIndexQuotes()
        async let fromSina = fetchSinaIndexQuotes()
        async let fromEastmoney = fetchEastmoneyIndexQuotes()
        let (tencentQuotes, sinaQuotes, eastmoneyQuotes) = await (fromTencent, fromSina, fromEastmoney)

        // 按「东财 → 新浪 → 腾讯」的顺序写入，后面的覆盖前面的：
        // 腾讯的时间戳最贴近实时，新浪次之，东财在本机常年被风控排最后。
        var merged: [String: MarketIndexQuote] = [:]
        for quote in eastmoneyQuotes + sinaQuotes + tencentQuotes { merged[quote.symbol] = quote }

        let cached = Dictionary(indexQuotes.map { ($0.symbol, $0) }, uniquingKeysWith: { _, latest in latest })
        let receivedCurrentData = MarketIndexStore.catalog.contains { merged[$0.secid] != nil }
        let updated = MarketIndexStore.catalog.compactMap { entry -> MarketIndexQuote? in
            // 个别指数源偶尔漏返回（例如美股休市/接口短暂缺项）时保留其上次行情，
            // 否则一次部分成功会把纳指从首页整条删掉，直到下一次成功才恢复。
            guard var quote = merged[entry.secid] ?? cached[entry.secid] else { return nil }
            // 数据源只负责价格，首页中文名称和顺序由代码表统一控制。
            quote.name = entry.name
            return quote
        }
        // 一个都没解析出来说明这次请求白跑，保留上一次的值比清空更诚实。
        guard !updated.isEmpty else { return false }
        assignIfChanged(\.indexQuotes, updated)
        MarketIndexStore.save(updated)

        // 顺带维护交易日历（内部一天只跑一次，见 MarketCalendar.fetchedToday）。
        Task { await refreshTradingCalendar() }
        return receivedCurrentData
    }

    /// 腾讯源：`qt.gtimg.cn` 一条请求覆盖 A 股 / 港股 / 美股指数。
    private func fetchTencentIndexQuotes() async -> [MarketIndexQuote] {
        let entries = MarketIndexStore.catalog.filter { $0.tencent != nil }
        guard !entries.isEmpty else { return [] }
        let symbols = entries.compactMap { $0.tencent }
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + symbols.joined(separator: ",")
                            + "&_t=" + String(Int(Date().timeIntervalSince1970))) else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        var bytes: Data?
        if let direct = try? await URLSession.shared.data(for: request),
           (direct.1 as? HTTPURLResponse)?.statusCode == 200 {
            bytes = direct.0
        } else if let proxied = try? await NASSyncService.marketProxyData(
            path: "quote", queryItems: [URLQueryItem(name: "codes", value: symbols.joined(separator: ","))]) {
            // 直连失败才走 NAS 行情代理兜底（返回的也是腾讯格式）
            bytes = proxied
        }
        guard let bytes else { return [] }
        let values = parseTencent(decodeTencent(bytes))
        return entries.compactMap { entry -> MarketIndexQuote? in
            guard let symbol = entry.tencent, let quote = values[symbol], quote.price > 0 else { return nil }
            return MarketIndexQuote(symbol: entry.secid,
                                    name: quote.name.isEmpty ? entry.name : quote.name,
                                    price: quote.price, changePct: quote.changePct,
                                    updatedAt: quote.timestamp)
        }
    }

    /// 新浪基金源：一次取多只 ETF 的**当日实时参考净值（IOPV）**。
    ///
    /// `hq.sinajs.cn/list=fu_510300,fu_159915` → 每行
    /// `var hq_str_fu_510300="华泰柏瑞沪深300ETF,11:32:00,4.3349,4.3479,1.9393,0,-0.2999,2026-10-14,4.2907,-1.3162";`
    ///
    /// 字段含义（拿 4 只 ETF 与腾讯 88 字段逐一比对确认过）：
    /// ① 名称 ② 时间 ③ **当日 IOPV**（= 腾讯字段 78）④ 昨日 IOPV（= 腾讯字段 81）
    /// ⑤/⑥/⑦ 其他指标 ⑧ 日期 ⑨ 最近公布的单位净值 ⑩ 其他。
    /// **只取字段 3**：取 4 会拿到昨天的数、取 9 会拿到净值而不是 IOPV。
    ///
    /// 与腾讯一样必须带 `Referer: https://finance.sina.com.cn`，否则返回空 body；
    /// 编码是 GB18030，复用 `decodeTencent`。
    private func fetchSinaFundIOPVs(codes: [String]) async -> [String: Double] {
        let cleaned = codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count == 6 && $0.allSatisfy(\.isNumber) }
        guard !cleaned.isEmpty else { return [:] }
        let list = cleaned.map { "fu_\($0)" }.joined(separator: ",")
        guard let url = URL(string: "https://hq.sinajs.cn/list=" + list) else { return [:] }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
        let text = decodeTencent(bytes)
        var result: [String: Double] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let row = String(line)
            guard let range = row.range(of: "hq_str_fu_") else { continue }
            let tail = row[range.upperBound...]
            guard let equals = tail.firstIndex(of: "=") else { continue }
            let code = String(tail[tail.startIndex..<equals])
            guard code.count == 6, code.allSatisfy(\.isNumber) else { continue }
            let body = tail[tail.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
            let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, let iopv = Double(fields[2]), iopv.isFinite, iopv > 0 else { continue }
            result[code] = iopv
        }
        return result
    }

    /// 新浪源：`hq.sinajs.cn` 一次请求覆盖全部代码，用来补腾讯**没有**的日经与东证。
    ///
    /// **两个坑**（都是实测踩出来的）：
    /// ① 必须带 `Referer: https://finance.sina.com.cn`，否则返回空 body；
    /// ② `int_topix` / `int_kospi` 是空的，东证与韩国要用 `b_` 前缀（`b_TOPIX` / `b_KOSPI`）。
    ///
    /// 返回格式是「名称,现价,涨跌额,涨跌幅百分数,……」四段起步，长短不一：
    /// `b_HSI` 只有 6 段，`b_TOPIX` 有 13 段，但**前四段含义一致**，所以只读前四段。
    /// 时间戳各源位置不同，靠扫「哪一段长得像日期/时间」拿到，拿不到就留 nil。
    private func fetchSinaIndexQuotes() async -> [MarketIndexQuote] {
        let entries = MarketIndexStore.catalog.filter { $0.sina != nil }
        guard !entries.isEmpty else { return [] }
        let codes = entries.compactMap { $0.sina }
        guard let url = URL(string: "https://hq.sinajs.cn/list=" + codes.joined(separator: ",")) else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        guard let direct = try? await URLSession.shared.data(for: request),
              (direct.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let values = parseSina(decodeTencent(direct.0))
        return entries.compactMap { entry -> MarketIndexQuote? in
            guard let code = entry.sina, let quote = values[code], quote.price > 0 else { return nil }
            return MarketIndexQuote(symbol: entry.secid,
                                    name: entry.name,
                                    price: quote.price, changePct: quote.changePct,
                                    updatedAt: quote.timestamp)
        }
    }

    private func parseSina(_ text: String) -> [String: (price: Double, changePct: Double, timestamp: Date?)] {
        var result: [String: (Double, Double, Date?)] = [:]
        let pattern = #"hq_str_([A-Za-z0-9_]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        let dayPattern = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
        let timePattern = try? NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}"#)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 3 {
            let code = ns.substring(with: match.range(at: 1))
            let fields = ns.substring(with: match.range(at: 2))
                .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // 前四段：名称、现价、涨跌额、涨跌幅百分数。少于四段说明是空占位（`hq_str_x=""`）。
            guard fields.count >= 4,
                  let price = Double(fields[1]), price > 0,
                  let percent = Double(fields[3]) else { continue }
            // 时间戳：在各段里找第一个「日期」和第一个「时刻」，两个都有才算得出时间。
            var day: String?
            var clock: String?
            for field in fields {
                let range = NSRange(location: 0, length: (field as NSString).length)
                if day == nil, let m = dayPattern?.firstMatch(in: field, range: range) {
                    day = (field as NSString).substring(with: m.range)
                }
                if clock == nil, let m = timePattern?.firstMatch(in: field, range: range) {
                    clock = (field as NSString).substring(with: m.range)
                }
            }
            var stamp: Date?
            if let day, let clock {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                stamp = formatter.date(from: "\(day) \(clock)")
            }
            result[code] = (price, percent / 100, stamp)
        }
        return result
    }

    /// 东财源：`push2` 一条请求覆盖全部指数（含日经 225、韩国 KOSPI、东证 TOPIX）。
    ///
    /// 本机出口 IP 长期被风控（连续请求直接断连），所以只当兜底 —— 拿得到更好，
    /// 拿不到也有腾讯与新浪顶着，不影响指数条。
    ///
    /// **单位陷阱**：`f3` 已经是**百分数**（1.85 表示 +1.85%），而 `MarketIndexQuote.changePct`
    /// 存的是小数比例（0.0185），所以这里必须除以 100。反过来写指数条就会显示百倍涨幅。
    private func fetchEastmoneyIndexQuotes() async -> [MarketIndexQuote] {
        let secids = MarketIndexStore.catalog.map { $0.secid }
        guard !secids.isEmpty,
              var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "secids", value: secids.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "f2,f3,f12,f13,f14,f124"),
            URLQueryItem(name: "ut", value: "fa5fd1943c7b386f172d6893dbfba10b")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let direct = try? await URLSession.shared.data(for: request),
              (direct.1 as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: direct.0) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let rows = data["diff"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> MarketIndexQuote? in
            guard let market = (row["f13"] as? NSNumber)?.intValue,
                  let code = row["f12"] as? String,
                  let price = (row["f2"] as? NSNumber)?.doubleValue, price > 0 else { return nil }
            let secid = "\(market).\(code)"
            let stamp = (row["f124"] as? NSNumber)?.doubleValue ?? 0
            return MarketIndexQuote(symbol: secid,
                                    name: (row["f14"] as? String) ?? MarketIndexStore.name(for: secid) ?? code,
                                    price: price,
                                    changePct: ((row["f3"] as? NSNumber)?.doubleValue ?? 0) / 100,
                                    updatedAt: stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil)
        }
    }

    // MARK: - 指数详情：日 K 与分时

    /// 场内代码长什么样：6 位数字，且前缀落在沪/深 ETF / LOF 号段
    /// （51x / 56x / 58x 为沪市，15x / 16x / 18x 为深市）。
    /// 用来判断「这条自选值不值得去拉前复权日线推算分红」。
    static func looksLikeExchangeTradedFund(_ code: String) -> Bool {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return false }
        let prefixes = ["51", "56", "58", "15", "16", "18"]
        return prefixes.contains { code.hasPrefix($0) }
    }

    /// 东财接口的公共 token（网页版前端写死的那个，不是密钥）。
    static let eastmoneyToken = "fa5fd1943c7b386f172d6893dbfba10b"

    /// "20261009" → "2026-10-09"；已是标准格式就原样返回。
    static func normalizedDay(_ raw: String) -> String {
        guard raw.count == 8, raw.allSatisfy(\.isNumber) else { return raw }
        return "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(2))-\(raw.suffix(2))"
    }

    /// 行情源分时行的首列 → 「当天第几分钟」。
    ///
    /// 腾讯给的是紧凑写法 `0930`（也有 `930`），东财给的是 `09:30`；
    /// 一律先归一化再算，避免依赖 `DateFormatter` 对「模式有冒号、输入没冒号」的宽容度。
    /// 无法确定就返回 nil —— 宁可丢这一个点，也不猜一个时间。
    static func intradayClockMinute(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":")
            guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
            return hour * 60 + minute
        }
        guard text.allSatisfy(\.isNumber) else { return nil }
        let digits = text.count > 4 ? String(text.prefix(4)) : text
        guard digits.count == 3 || digits.count == 4, let value = Int(digits) else { return nil }
        let minute = value % 100
        let hour = value / 100
        guard hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    /// 指数日 K。腾讯有该指数就用腾讯（更稳），否则走东财 secid。
    ///
    /// 两条路都要的原因：腾讯 `ifzq` 支持 sh/sz/hk/us 前缀，但**没有**日经、韩国；
    /// 东财的 secid 号称全覆盖，只是本机出口 IP 被风控、实际常年取不到。
    /// 所以日经 225 / 东证 TOPIX / 韩国 KOSPI 这三条**两个分支都会返回空**，
    /// 这是预期行为 —— `IndexDetailView` 会据此显示「暂无分时与日 K」的说明，
    /// 而不是画一张空图。
    func fetchIndexDailyBars(quote: MarketIndexQuote, count: Int = 300) async -> [DailyBar] {
        let tencent = MarketIndexStore.catalog.first { $0.secid == quote.symbol }?.tencent
        if let tencent, let bars = try? await fetchDailyBars(code: tencent, count: count, force: true),
           !bars.isEmpty {
            return bars
        }
        return await fetchEastmoneyDailyBars(secid: quote.symbol, count: count)
    }

    /// 东财日 K。`klines` 每行是「日期,开,收,高,低,成交量,成交额,涨跌幅%」。
    private func fetchEastmoneyDailyBars(secid: String, count: Int) async -> [DailyBar] {
        guard var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "ut", value: Self.eastmoneyToken),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58"),
            URLQueryItem(name: "klt", value: "101"),
            URLQueryItem(name: "fqt", value: "1"),
            URLQueryItem(name: "beg", value: "0"),
            URLQueryItem(name: "end", value: "20500101"),
            URLQueryItem(name: "lmt", value: String(min(max(count, 60), 1000)))
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let direct = try? await URLSession.shared.data(for: request),
              (direct.1 as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: direct.0) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let rows = data["klines"] as? [String] else { return [] }
        return rows.compactMap { row -> DailyBar? in
            let f = row.split(separator: ",").map(String.init)
            guard f.count >= 6, let open = Double(f[1]), let close = Double(f[2]),
                  let high = Double(f[3]), let low = Double(f[4]), close > 0 else { return nil }
            return DailyBar(code: secid, date: f[0], open: open, close: close,
                            high: high, low: low, volume: Double(f[5]) ?? 0,
                            // f[6] 是成交额（元）。腾讯日 K 没有这一列，只有东财有。
                            amount: f.count > 6 ? Double(f[6]) : nil)
        }
    }

    /// 指数分时。四源兜底，避免单点失败让详情页变成空图：
    /// 腾讯（web.ifzq → ifzq 两个主机）→ 东财 trends2 → NAS 行情代理。
    /// 两边在休市时都会返回**最近交易日**的完整分时，所以周末打开也能看到一条完整曲线。
    func fetchIndexMinutes(quote: MarketIndexQuote) async -> [IntradayBar] {
        let tencent = MarketIndexStore.catalog.first { $0.secid == quote.symbol }?.tencent
        // 不因腾讯返回了少量分钟就提前结束：实时接口偶尔只给末尾一小段，
        // 详情页应把腾讯、东财和 NAS 代理按分钟合并，再展示同一天的完整序列。
        var sources: [[IntradayBar]] = []
        if let tencent {
            let points = await fetchTencentMinutes(symbol: tencent)
            if !points.isEmpty { sources.append(points) }
        }
        // 拆成几步写：`flatMap`/`map`/`Set` 串在一行会让 Swift 的类型检查超时
        // （报 "unable to type-check this expression in reasonable time"），
        // 中间量显式标注类型即可。
        let tencentBars: [IntradayBar] = sources.flatMap { $0 }
        let tencentMinutes: [Int] = tencentBars.map { Self.minuteStamp($0.timestamp) }
        let tencentCount = Set(tencentMinutes).count
        let targetCount = tencent?.lowercased().hasPrefix("us") == true ? 390 : 242
        // 腾讯已给出完整 A 股交易日时不再等待第二接口；只在有明显缺口时补数。
        // 非东财格式的海外指数代码也不请求东财，避免无效请求拖慢详情页。
        if tencentCount < targetCount,
           quote.symbol.range(of: "^[01]\\.\\d{6}$", options: .regularExpression) != nil {
            let em = await fetchEastmoneyMinutes(secid: quote.symbol)
            if !em.isEmpty { sources.append(em) }
        }
        // 同上：拆开写，避免一行的链式计算把类型检查拖到超时。
        let mergedBars: [IntradayBar] = sources.flatMap { $0 }
        let targetDay = mergedBars.map(\.day).max()
        let targetBars = mergedBars.filter { $0.day == targetDay }
        let targetMinutes: [Int] = targetBars.map { Self.minuteStamp($0.timestamp) }
        let count = Set(targetMinutes).count
        if count < targetCount, let tencent,
           let bytes = try? await NASSyncService.marketProxyData(path: "minute",
               queryItems: [URLQueryItem(name: "code", value: tencent)]) {
            let proxied = parseTencentMinuteData(bytes, symbol: tencent)
            if !proxied.isEmpty { sources.append(proxied) }
        }
        guard let latestDay = sources.flatMap({ $0 }).map(\.day).max() else { return [] }
        var byMinute: [Int: IntradayBar] = [:]
        for bar in sources.flatMap({ $0 }) where bar.day == latestDay && bar.price.isFinite && bar.price > 0 {
            let key = Self.minuteStamp(bar.timestamp)
            if var prior = byMinute[key] {
                if prior.volume == nil { prior.volume = bar.volume }
                byMinute[key] = prior
            } else {
                byMinute[key] = bar
            }
        }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// 腾讯分时（与 `MarketChartView` 同一条接口，抽到 store 里给指数详情页复用）。
    /// 主机按稳定性排序：`web.ifzq.gtimg.cn` 走 CDN、比裸 `ifzq` 更稳，任一成功即返回。
    func fetchTencentMinutes(symbol: String) async -> [IntradayBar] {
        let isUS = symbol.lowercased().hasPrefix("us")
        let path = isUS ? "usMinute" : "minute"
        for host in (isUS ? ["web.ifzq.gtimg.cn"] : ["web.ifzq.gtimg.cn", "ifzq.gtimg.cn"]) {
            let variable = "min_data_\(Int(Date().timeIntervalSince1970 * 1000))"
            guard let url = URL(string: "https://\(host)/appstock/app/\(path)/query?_var=\(variable)&code=\(symbol)&_t=\(Int(Date().timeIntervalSince1970))") else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            guard let direct = try? await URLSession.shared.data(for: request),
                  (direct.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let bars = parseTencentMinuteData(direct.0, symbol: symbol)
            guard !bars.isEmpty else { continue }
            return bars
        }
        return []
    }

    /// 把腾讯分时接口的整包字节解析成 `[IntradayBar]`。
    /// 接口返回 `m={...}`（带 `_var=m` 前缀）或裸 JSON，这里都兼容：从第一个 `{` 截到最后一个 `}`。
    /// `date` 字段实测是 `20261012`（8 位无横线），靠 `normalizedDay` 补成标准格式。
    func parseTencentMinuteData(_ data: Data, symbol: String) -> [IntradayBar] {
        guard let raw = String(data: data, encoding: .utf8),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let nodes = root["data"] as? [String: Any] else { return [] }
        let node = (nodes[symbol] as? [String: Any])
            ?? (nodes.first { $0.key.caseInsensitiveCompare(symbol) == .orderedSame }?.value as? [String: Any])
            ?? (nodes.values.first as? [String: Any])
        guard let node else { return [] }
        let payload = (node["data"] as? [String: Any]) ?? node
        let rows = (payload["data"] as? [String]) ?? (payload["items"] as? [String]) ?? []
        guard !rows.isEmpty else { return [] }
        let rawDay = (payload["date"] as? String) ?? (node["date"] as? String) ?? ""
        let day = Self.normalizedDay(rawDay)
        guard day.count == 10 else { return [] }
        // 时间列是**紧凑写法**「HHmm」（`0930`），没有冒号。
        //
        // 这里以前交给 `DateFormatter` 用 `"yyyy-MM-dd HH:mm"` 去啃 "2026-10-14 0930"：
        // 模式里带 `:`、输入里没有，能不能解析完全取决于 ICU 对缺失字面量的宽容度，
        // 结果就是**整段返回 nil**。表现很隐蔽 —— 因为本机分时档案里还有 NAS 归档和
        // 前台自动采集的点，持仓的分时图看着是好的，于是没人怀疑解析器；
        // 直到要看**指数**的分时（指数不在账本里、没有 NAS 归档，只能靠这条直连接口）
        // 才暴露成「上证指数那一排点开永远是空的」。
        //
        // 改成自己按整数算时分、再用上海/纽约日历组装：结果确定，也不受手机
        // 12/24 小时制开关影响（这是 DateFormatter 另一个有名的坑）。
        let zone = symbol.lowercased().hasPrefix("us")
            ? (TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!)
            : (TimeZone(identifier: "Asia/Shanghai") ?? .current)
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = zone
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { return [] }
        var parsed: [IntradayBar] = []
        var previousVolume = 0.0
        for row in rows {
            let fields = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, let price = Double(fields[1]), price > 0,
                  let minuteOfDay = Self.intradayClockMinute(fields[0]) else { continue }
            var components = DateComponents()
            components.year = dayParts[0]
            components.month = dayParts[1]
            components.day = dayParts[2]
            components.hour = minuteOfDay / 60
            components.minute = minuteOfDay % 60
            guard let date = clock.date(from: components) else { continue }
            let cumulative = fields.count > 2 ? Double(fields[2]) : nil
            let delta = cumulative.map { max(0, $0 - previousVolume) }
            if let cumulative { previousVolume = cumulative }
            parsed.append(IntradayBar(code: symbol, timestamp: date, price: price, volume: delta, day: day))
        }
        return parsed
    }

    /// 东财分时。每行是「时间,开,收,高,低,成交量,成交额,均价」——
    /// **收盘价在第 3 列**（不是第 2 列），别照腾讯的字段顺序读。
    private func fetchEastmoneyMinutes(secid: String) async -> [IntradayBar] {
        guard var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/trends2/get")
        else { return [] }
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "ut", value: Self.eastmoneyToken),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58"),
            URLQueryItem(name: "ndays", value: "1"),
            URLQueryItem(name: "iscr", value: "0")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        guard let direct = try? await URLSession.shared.data(for: request),
              (direct.1 as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: direct.0) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let rows = data["trends"] as? [String] else { return [] }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parsed: [IntradayBar] = []
        var previousVolume = 0.0
        for row in rows {
            let f = row.split(separator: ",").map(String.init)
            guard f.count >= 7, let price = Double(f[2]), price > 0,
                  let date = formatter.date(from: f[0]) else { continue }
            let cumulative = Double(f[5])
            let delta = cumulative.map { max(0, $0 - previousVolume) }
            if let cumulative { previousVolume = cumulative }
            parsed.append(IntradayBar(code: secid, timestamp: date, price: price,
                                      volume: delta, day: String(f[0].prefix(10))))
        }
        return parsed
    }

    private func performQuoteRefresh(captureIntraday: Bool, manual: Bool = false) async -> Bool {
        // Tencent's stock quote endpoint does not return OTC fund NAVs. Never send
        // fund codes there or present a stock quote as a fund valuation.
        let shadowCodes = data.legacyShadowArchives.filter { !$0.closed }.map(\.code)
        let symbols = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code) + shadowCodes)
        guard !symbols.isEmpty else { sourceStatus = "还没有标的"; return false }
        let requestCodes = symbols.map(tencentSymbol).sorted()
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + requestCodes.joined(separator: ",") + "&_t=" + String(Int(Date().timeIntervalSince1970))) else {
            sourceStatus = "行情请求地址无效"; return false
        }
        // 自动轮询「保持安静」（v2.13.34）：`isRefreshingQuotes` 与 `sourceStatus` 只在
        // **用户自己点的刷新**时才翻。这两个都是 `@Published`，每 15 秒各翻两次，
        // 每次都会发一轮改动通知把整棵视图树重建 —— 这就是用户说的
        // 「已经确认就是刷新的那一会就会卡」。自动刷新现在连这两个通知都不发。
        if manual {
            sourceStatus = "正在刷新行情…"
            isRefreshingQuotes = true
        }
        defer { if manual { isRefreshingQuotes = false } }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 12
            let bytes: Data
            var usedNASProxy = false
            do {
                let (directBytes, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                bytes = directBytes
            } catch {
                // 直连失败时才走 NAS 行情代理兜底
                if let proxied = try? await NASSyncService.marketProxyData(path: "quote", queryItems: [URLQueryItem(name: "codes", value: requestCodes.joined(separator: ","))]) {
                    bytes = proxied
                    usedNASProxy = true
                } else { throw error }
            }
            let text = decodeTencent(bytes)
            var values = parseTencent(text)
            let etfCodes = Set(data.holdings.filter { $0.kind == .etf }.map(\.code)
                + data.quotes.map(\.code)).filter { isTencentETFCode($0) }
            let incompleteETFCodes = etfCodes.filter { code in
                guard let quote = values[tencentSymbol(code)] else { return true }
                return quote.premiumPct == nil || quote.iopv == nil
            }
            if !incompleteETFCodes.isEmpty,
               let proxied = try? await NASSyncService.marketProxyData(
                    path: "quote", queryItems: [URLQueryItem(name: "codes", value: incompleteETFCodes.map(tencentSymbol).joined(separator: ","))]) {
                let proxyValues = parseTencent(decodeTencent(proxied))
                for code in incompleteETFCodes {
                    let symbol = tencentSymbol(code)
                    guard let proxy = proxyValues[symbol] else { continue }
                    if let direct = values[symbol] {
                        values[symbol] = (direct.name, direct.price, direct.changePct, direct.timestamp,
                                          direct.premiumPct ?? proxy.premiumPct, direct.iopv ?? proxy.iopv)
                    } else {
                        values[symbol] = proxy
                    }
                }
            }
            // 还没补到 IOPV 的 ETF 再走一次**新浪基金接口**。
            //
            // 为什么要第三条路：腾讯的 88 字段里字段 78 确实是当日 IOPV，但实测
            // **部分深市 ETF 会整段缺这几个字段**（返回的数组长度就不够），
            // 而 IOPV 是分时图上那条紫线唯一的来源，缺一次就少一个分钟点。
            // 新浪的 `hq.sinajs.cn/list=fu_<code>` 是**基金专用**接口：
            // 字段 3 = 当日实时参考净值（字段 4 是昨日 IOPV，字段 9 是最近公布的单位净值，
            // 三个都实测比对过，别取错）。一次请求可以批量，且与腾讯完全独立。
            // 这里**只补 IOPV**，价格 / 涨跌幅 / 时间戳一律不动。
            // `etfCodes` 是 Set，`filter` 出来还是 Set；这里要的是数组（下游按下标拼请求），
            // 顺手转成 Array —— 上一版直接把它交给了 `[String]` 形参，CI 报
            // `cannot convert value of type 'Set<String>' to expected argument type '[String]'`。
            let stillMissingIOPV = Array(incompleteETFCodes.filter { values[tencentSymbol($0)]?.iopv == nil })
            if !stillMissingIOPV.isEmpty {
                let sinaIOPVs = await fetchSinaFundIOPVs(codes: stillMissingIOPV)
                for code in stillMissingIOPV {
                    let symbol = tencentSymbol(code)
                    guard let iopv = sinaIOPVs[code], iopv.isFinite, iopv > 0,
                          let direct = values[symbol] else { continue }
                    values[symbol] = (direct.name, direct.price, direct.changePct, direct.timestamp,
                                      direct.premiumPct, iopv)
                }
            }
            guard !values.isEmpty else {
                sourceStatus = "接口未返回可识别报价"
                Task { await NativeNotifications.sendSourceHealthOnce(category: "market", body: "行情接口没有返回可识别报价。请检查数据源状态或 NAS 网络连接。") }
                return false
            }
            if Self.isRegularTradingSession(.now) {
                let unhealthyCount = requestCodes.filter { symbol in
                    guard let quote = values[symbol] else { return true }
                    return !Self.isFreshQuote(quote.timestamp, now: .now)
                }.count
                if unhealthyCount > 0 {
                    Task { await NativeNotifications.sendSourceHealthOnce(category: "market", body: "交易时段有 \(unhealthyCount) 个标的缺少报价或时间戳超过 3 分钟。请打开“数据可信度”检查报价和网络。") }
                }
            }
            // **一次刷新只让界面重绘一次**（v2.13.2）。
            //
            // 原来这里是直接在 `data` / `marketChanges` 上逐条赋值的。`data` 是 `@Published`，
            // 每一条 `data.quotes[i].price = …` 都会发一次改动通知 —— 30 个自选 + 20 只 ETF
            // 就是 50 多次，而每一次都会把 `ContentView` 的整个 body 重建一遍
            // （它身上挂着五十来个 `.sheet` 修饰器）。于是刷新时肉眼可见地「闪一下」，
            // 重建过程中列表还是空的，用户看到的就是「一闪，然后看不到数据」。
            //
            // 改成先在局部副本上改完，最后一次性赋回：通知次数从「标的数量」降到固定两次。
            // 刷新该多慢就多慢（用户明确说过慢一点没关系），但界面不再抖。
            var changes = marketChanges
            var premiums = marketPremiums
            var iopvs = marketIOPVs
            for code in symbols {
                if let quote = values[tencentSymbol(code)] {
                    changes[code] = quote.changePct
                    if let premium = quote.premiumPct { premiums[code] = premium }
                    else { premiums.removeValue(forKey: code) }
                    if let iopv = quote.iopv, iopv.isFinite, iopv > 0 { iopvs[code] = iopv }
                    else { iopvs.removeValue(forKey: code) }
                }
            }
            var updated = data
            for i in updated.quotes.indices {
                if let q = values[tencentSymbol(updated.quotes[i].code)] {
                    if updated.quotes[i].name.isEmpty || updated.quotes[i].name == updated.quotes[i].code { updated.quotes[i].name = q.name }
                    updated.quotes[i].price = q.price
                    updated.quotes[i].changePct = q.changePct
                    updated.quotes[i].updatedAt = q.timestamp
                }
            }
            for i in updated.holdings.indices where updated.holdings[i].kind == .etf {
                if let q = values[tencentSymbol(updated.holdings[i].code)] {
                    updated.holdings[i].current = q.price
                    updated.holdings[i].marketUpdatedAt = q.timestamp
                }
            }
            // 手动覆盖价也并进这一批：单独调 `applyManualQuoteOverrides()` 会再发一轮通知。
            applyManualQuoteOverrides(to: &updated, changes: &changes)
            // **值没变就不写回**（v2.13.34）。`@Published` 是无条件发布的：哪怕内容完全一样，
            // 赋一次值也会发一轮改动通知，把整棵视图树（ContentView 上挂着几十个 sheet）重建一遍。
            // 盘中每 15 秒刷一次，几十次「什么都没变」的刷新叠起来就是「所有页面滑动都卡」。
            // 这里先比后写：`Quote` 已支持 `==`，持仓只看行情相关字段。
            if marketStateChanged(from: data, to: updated) {
                data = updated
            }
            assignIfChanged(\.marketChanges, changes)
            assignIfChanged(\.marketPremiums, premiums)
            assignIfChanged(\.marketIOPVs, iopvs)
            if Self.isRegularTradingSession(Date()) {
                checkQuoteAlerts(using: values)
                if captureIntraday && data.intradayCaptureEnabled {
                    let liveCodes = Set(data.quotes.map(\.code) + data.holdings.filter { $0.kind == .etf }.map(\.code) + shadowCodes)
                    let live = liveCodes.compactMap { code -> (String, Double)? in
                        guard let quote = values[tencentSymbol(code)], Self.isFreshQuote(quote.timestamp, now: .now) else { return nil }
                        return (code, quote.price)
                    }
                    captureMinuteQuotes(live)
                    let shadowQuotes = live.compactMap { item -> (String, Double, Date)? in
                        let code = item.0
                        guard let quote = values[tencentSymbol(code)], let timestamp = quote.timestamp else { return nil }
                        return (code, quote.price, timestamp)
                    }
                    advanceLegacyShadowSimulations(shadowQuotes)
                }
                evaluateIntradayCompanions()
            }
            let route = usedNASProxy ? "NAS 代理" : "iPhone 直连"
            saveAutomaticMarketState()
            sourceStatus = "行情已更新（\(route)）· \(Date.now.formatted(date: .omitted, time: .shortened))"
            // 不把整批分时下载塞进刷新按钮的等待时间里；后台补全结束后单独更新状态。
            // 即使用户白天没有一直打开详情页，下次打开或刷新也会补回最近交易日整日数据。
            if captureIntraday && data.intradayCaptureEnabled {
                Task { await archiveTrackedIntraday() }
            }
            return true
        } catch {
            sourceStatus = "行情刷新失败：\(error.localizedDescription)"
            Task { await NativeNotifications.sendSourceHealthOnce(category: "market", body: "行情刷新失败。请打开观盘 Pro 检查数据源和网络连接。") }
            return false
        }
    }

    func addQuoteAlert(code: String, name: String, target: Double, direction: QuoteAlert.Direction) throws {
        guard !code.isEmpty, target.isFinite, target > 0 else { throw StoreError.invalidAlert }
        data.quoteAlerts.append(QuoteAlert(code: code, name: name.isEmpty ? code : name,
            target: target, direction: direction, enabled: true, lastTriggeredAt: nil))
        save(label: "新增价格提醒")
    }

    func setManualQuoteOverride(code: String, price: Double, previousClose: Double?) throws {
        let previousCloseIsValid = previousClose.map { $0.isFinite && $0 > 0 } ?? true
        guard !code.isEmpty, price.isFinite, price > 0, previousCloseIsValid else {
            throw StoreError.invalidManualPrice
        }
        data.manualQuoteOverrides[code] = ManualQuoteOverride(price: price, previousClose: previousClose)
        applyManualQuoteOverrides()
        save(label: "修改手动行情")
    }

    func clearManualQuoteOverride(code: String) {
        data.manualQuoteOverrides.removeValue(forKey: code)
        save(label: "清除手动行情")
        refreshQuotes()
    }

    /// 把手动覆盖价落到**局部副本**上。
    ///
    /// 抽成 `inout` 版本是为了让 `performQuoteRefresh` 能把手动覆盖并进它那一整批改动里 ——
    /// 否则这里会独立再发一轮 `@Published` 通知，刷新时又多闪一下。
    /// 逻辑本身与原来一致：无效价格跳过，`previousClose` 缺失时不动涨跌幅，
    /// 覆盖价没有实时时间戳所以把 `updatedAt` / `marketUpdatedAt` 清成 nil。
    private func applyManualQuoteOverrides(to target: inout PortfolioData, changes: inout [String: Double]) {
        for (code, override) in target.manualQuoteOverrides {
            guard override.price.isFinite, override.price > 0 else { continue }
            let change = override.previousClose.flatMap { $0 > 0 ? (override.price - $0) / $0 : nil }
            for index in target.quotes.indices where target.quotes[index].code == code {
                target.quotes[index].price = override.price
                if let change { target.quotes[index].changePct = change }
                target.quotes[index].updatedAt = nil
            }
            for index in target.holdings.indices where target.holdings[index].code == code && target.holdings[index].kind == .etf {
                target.holdings[index].current = override.price
                target.holdings[index].marketUpdatedAt = nil
            }
            if let change { changes[code] = change }
        }
    }

    /// 单独调用的入口：用户刚改完手动行情，要立刻在界面上生效。
    private func applyManualQuoteOverrides() {
        var updated = data
        var changes = marketChanges
        applyManualQuoteOverrides(to: &updated, changes: &changes)
        data = updated
        marketChanges = changes
    }

    /// 值相等就不写 `@Published`。内容相同的赋值同样会发通知、同样会让界面全量重建，
    /// 而盘中每 15 秒一轮的行情刷新大多数情况下什么都没变。
    @discardableResult
    private func assignIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PortfolioStore, T>,
                                               _ value: T) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    /// 行情相关字段有没有实质变化。
    ///
    /// `PortfolioData` 不是 `Equatable`（它是个大 struct，成员太多，为了性能不整体比较），
    /// 所以只比这一轮刷新真正会动的那些字段：自选的 `Quote`（已可 `==`）+ 持仓行情价与时间戳。
    /// `applyManualQuoteOverrides` 改的也只是这两组字段，因此覆盖完整。
    private func marketStateChanged(from old: PortfolioData, to new: PortfolioData) -> Bool {
        if old.quotes != new.quotes { return true }
        if old.holdings.count != new.holdings.count { return true }
        for index in old.holdings.indices {
            let before = old.holdings[index]
            let after = new.holdings[index]
            if before.current != after.current || before.marketUpdatedAt != after.marketUpdatedAt {
                return true
            }
        }
        return false
    }

    func removeQuoteAlert(_ alert: QuoteAlert) {
        data.quoteAlerts.removeAll { $0.id == alert.id }
        save(label: "删除价格提醒")
    }

    func reenableQuoteAlert(_ alert: QuoteAlert) {
        guard let index = data.quoteAlerts.firstIndex(where: { $0.id == alert.id }) else { return }
        data.quoteAlerts[index].enabled = true
        data.quoteAlerts[index].lastTriggeredAt = nil
        save(label: "重新启用价格提醒")
    }

    private func checkQuoteAlerts(using quotes: [String: (name: String, price: Double, changePct: Double, timestamp: Date?, premiumPct: Double?, iopv: Double?)]) {
        var changed = false
        for index in data.quoteAlerts.indices where data.quoteAlerts[index].enabled {
            let alert = data.quoteAlerts[index]
            guard data.manualQuoteOverrides[alert.code] == nil else { continue }
            guard let quote = quotes[tencentSymbol(alert.code)], quote.price.isFinite, quote.price > 0,
                  Self.isFreshQuote(quote.timestamp, now: .now) else { continue }
            let triggered = alert.direction == .above ? quote.price >= alert.target : quote.price <= alert.target
            guard triggered else { continue }
            data.quoteAlerts[index].enabled = false // one-shot; avoids repeated notifications on every refresh
            data.quoteAlerts[index].lastTriggeredAt = .now
            changed = true
            Task { try? await NativeNotifications.send(title: "观盘 Pro · 价格提醒", body: "\(alert.name)（\(alert.code)）现价 \(quote.price)，已\(alert.direction == .above ? "达到上穿" : "达到下穿")目标 \(alert.target)。") }
        }
        if changed { save() }
    }

    private static func isRegularTradingSession(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (570...690).contains(minute) || (780...900).contains(minute)
    }

    private static func isFreshQuote(_ timestamp: Date?, now: Date) -> Bool {
        guard let timestamp else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= -90 && age <= 180
    }

    /// 供 `.refreshable` 用：净值刷新是「发起后立即返回 + 内部 Task」，
    /// 这里等它真正跑完，下拉转圈才不会一闪而过。轮询 0.2s，最多等 30s。
    @discardableResult
    func refreshFundNAVsAndWait() async -> Bool {
        guard !isRefreshingFunds else { return false }
        refreshFundNAVs()
        let deadline = Date().addingTimeInterval(30)
        while isRefreshingFunds, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !isRefreshingFunds && !fundNAVStatus.contains("失败") && !fundNAVStatus.contains("不可用")
    }

    func refreshFundNAVs() {
        guard !isRefreshingFunds else { return }
        // 定投计划的代码也要抓净值：计划刚建好时往往还没有持仓和流水，
        // 不抓就永远没有已公布净值，processAutomaticDCA 也就一期都补不进去。
        let codes = Array(Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code)
            + data.fundDCAPlans.filter(\.enabled).map(\.code))).sorted()
        let holdingFundCodes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code))
        guard !codes.isEmpty else { fundNAVStatus = "没有场外基金持仓或历史流水"; return }
        isRefreshingFunds = true
        fundNAVStatus = "正在逐只获取已公布净值…"
        Task {
            var fetched = 0
            var changedNAVCodes = Set<String>()
            var changedHoldingNAVCodes = Set<String>()
            var usedNASProxy = false
            var failures: [String] = []
            for code in codes {
                do {
                    guard code.count == 6, code.allSatisfy(\.isNumber) else { failures.append(code); continue }
                    // 先读取 NAS 在手机离线期间采到的净值和首次发现时间。
                    // 日期仍按净值日入账；NAS 时间只用于判断数据何时可见和补历史快照。
                    if let archived = try? await NASSyncService.fundNAVArchive(code: code), !archived.isEmpty {
                        var archiveByDate = data.fundNAVHistory.filter { $0.code == code }
                            .reduce(into: [String: FundNAVPoint]()) { $0[$1.date] = $1 }
                        for point in archived {
                            if let old = archiveByDate[point.date] {
                                if point.fetchedAt != nil || abs(old.nav - point.nav) > 0.00000001 {
                                    archiveByDate[point.date] = point
                                }
                            } else { archiveByDate[point.date] = point }
                        }
                        data.fundNAVHistory.removeAll { $0.code == code }
                        data.fundNAVHistory.append(contentsOf: archiveByDate.values)
                    }
                    guard let url = URL(string: "https://fund.eastmoney.com/pingzhongdata/\(code).js") else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    request.setValue("https://fund.eastmoney.com/", forHTTPHeaderField: "Referer")
                    let bytes: Data
                    do {
                        let (directBytes, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        bytes = directBytes
                    } catch {
                        // 直连失败时才走 NAS 行情代理兜底
                        if let proxied = try? await NASSyncService.marketProxyData(path: "fundnav", queryItems: [URLQueryItem(name: "code", value: code)]) {
                            bytes = proxied
                            usedNASProxy = true
                        } else { throw error }
                    }
                    guard let points = Self.parseFundNAVScript(bytes, code: code), !points.isEmpty else {
                        throw URLError(.cannotParseResponse)
                    }
                    // Legacy/imported archives can contain duplicate (code, date) rows.
                    // Avoid a runtime trap; fetched values replace stored values below.
                    let byDate = data.fundNAVHistory
                        .filter { $0.code == code }
                        .reduce(into: [String: FundNAVPoint]()) { result, point in
                            result[point.date] = point
                        }
                    let navChanged = points.contains { point in
                        guard let old = byDate[point.date] else { return true }
                        return abs(old.nav - point.nav) > 0.00000001
                    }
                    var merged = byDate
                    // 「今天有没有更新」看采集时间。但仅在净值日期推进或数值被修正时
                    // 更新时间，重复拉取同一份旧净值不能伪装成刚刚更新。
                    let fetchStamp = Date.now
                    let newestStoredDate = byDate.keys.max()
                    let newestFetchedDate = points.last?.date
                    for (pointIndex, point) in points.enumerated() {
                        let previous = byDate[point.date]
                        let valueChanged = previous.map { abs($0.nav - point.nav) > 0.00000001 } ?? false
                        let isNewPublishedPoint = previous == nil
                            && (newestStoredDate.map { point.date > $0 } ?? (point.date == newestFetchedDate))
                        let isLegacyCurrentDayPoint = point.date == MarketCalendar.isoDay(fetchStamp)
                            && previous?.fetchedAt == nil
                        // 本次确实带来了新净值 / 修正值时才盖章；但盖章用「旧的与新的取较晚」，
                        // 而不是「旧的一律优先」—— 否则备份 / NAS 存档里那条更早的采集时刻会把
                        // 今晚刚拿到的更新压掉，卡片永远不会亮起。
                        let candidateStamp: Date? = (valueChanged || isNewPublishedPoint || isLegacyCurrentDayPoint) ? fetchStamp : nil
                        let fetchedAt = [previous?.fetchedAt, candidateStamp].compactMap { $0 }.max()
                        let previousSourcePoint = pointIndex > 0 ? points[pointIndex - 1] : nil
                        let observedDelta: Double?
                        if let existingDelta = previous?.observedDelta { observedDelta = existingDelta }
                        else if isNewPublishedPoint, let previousSourcePoint { observedDelta = point.nav - previousSourcePoint.nav }
                        else { observedDelta = nil }
                        merged[point.date] = FundNAVPoint(code: point.code, date: point.date, nav: point.nav,
                                                          fetchedAt: fetchedAt, observedDelta: observedDelta)
                    }
                    data.fundNAVHistory.removeAll { $0.code == code }
                    data.fundNAVHistory.append(contentsOf: merged.values.sorted { $0.date < $1.date }.suffix(1800))
                    if let latest = points.last,
                       let index = data.holdings.firstIndex(where: { $0.kind == .fund && $0.code == code }) {
                        data.holdings[index].current = latest.nav
                    }
                    fetched += 1
                    if navChanged {
                        changedNAVCodes.insert(code)
                        if holdingFundCodes.contains(code) { changedHoldingNAVCodes.insert(code) }
                    }
                } catch {
                    failures.append(code)
                }
            }
            let dcaBooked = processAutomaticDCA()
            let reconciledSnapshots = fetched > 0 ? reconcileProvisionalSnapshotsAfterNAVUpdate() : 0
            // 迟到净值可能对应一个此前没有快照的估值日；收到历史净值后自动补建可核实日期。
            // backfill 会跳过已有记录，因此不会覆盖手动快照。
            let backfilledSnapshots = fetched > 0 ? backfillVerifiableSnapshots(audit: false) : (added: 0, skipped: 0)
            let refreshedSnapshot = fetched > 0 ? refreshTodaySnapshotIfPresent() : false
            save()
            isRefreshingFunds = false
            let snapshotCount = reconciledSnapshots + backfilledSnapshots.added + (refreshedSnapshot ? 1 : 0)
            let snapshotNote = snapshotCount > 0
                ? "；按净值日期核对/补建 \(snapshotCount) 条快照" : ""
            let routeNote = usedNASProxy ? " · 含 NAS 代理" : " · iPhone 直连"
            if dcaBooked > 0 { fundDCAStatus = "已按已公布净值补记定投 \(dcaBooked) 期；仅更新本机账本" }
            let resultNote = "本次净值新增/变化 \(changedNAVCodes.count) 只（持仓 \(changedHoldingNAVCodes.count)/\(holdingFundCodes.count)）；成功读取 \(fetched)/\(codes.count) 个代码"
            fundNAVStatus = failures.isEmpty
                ? "\(resultNote)（净值通常 T+1）\(routeNote)\(snapshotNote)"
                : "\(resultNote)；失败 \(failures.count) 只：\(failures.prefix(3).joined(separator: "、"))\(routeNote)\(snapshotNote)"
            if !failures.isEmpty {
                Task { await NativeNotifications.sendSourceHealthOnce(category: "fundnav", body: "有 \(failures.count) 只基金净值更新失败。请检查数据源状态；已公布净值也可能因 T+1 或海外时差尚未更新。") }
            }
        }
    }

    func refreshFundConstituents() {
        guard !isRefreshingFundHoldings else { return }
        let funds = data.holdings.filter { $0.kind == .fund && $0.code.count == 6 && $0.code.allSatisfy(\.isNumber) }
        guard !funds.isEmpty else { fundHoldingsStatus = "没有场外基金持仓"; return }
        isRefreshingFundHoldings = true
        fundHoldingsStatus = "正在获取基金定期报告重仓…"
        Task {
            var updated = 0
            var failed: [String] = []
            var usedNAS = false
            for fund in funds {
                do {
                    let bytes: Data
                    do {
                        guard let url = URL(string: "https://fundf10.eastmoney.com/FundArchivesDatas.aspx?type=jjcc&code=\(fund.code)&topline=50&year=&month=") else { throw URLError(.badURL) }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 18
                        request.setValue("https://fundf10.eastmoney.com/", forHTTPHeaderField: "Referer")
                        let (body, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        bytes = body
                    } catch {
                        // 直连失败时才走 NAS 行情代理兜底
                        if let proxied = try? await NASSyncService.marketProxyData(path: "hold", queryItems: [
                            URLQueryItem(name: "code", value: fund.code), URLQueryItem(name: "topline", value: "50")
                        ]) {
                            bytes = proxied; usedNAS = true
                        } else { throw error }
                    }
                    guard let decoded = Self.parseFundConstituents(bytes, code: fund.code), !decoded.holdings.isEmpty else {
                        throw URLError(.cannotParseResponse)
                    }
                    let snapshot = FundConstituentSnapshot(code: fund.code, name: fund.name,
                        asOf: decoded.asOf, fetchedAt: .now, holdings: decoded.holdings)
                    if let index = data.fundConstituentSnapshots.firstIndex(where: { $0.code == fund.code }) {
                        data.fundConstituentSnapshots[index] = snapshot
                    } else {
                        data.fundConstituentSnapshots.append(snapshot)
                    }
                    updated += 1
                } catch { failed.append(fund.code) }
            }
            save(label: "更新基金重仓快照")
            isRefreshingFundHoldings = false
            let source = usedNAS ? "NAS 代理" : "iPhone 直连"
            fundHoldingsStatus = failed.isEmpty
                ? "已更新 \(updated) 只基金重仓（\(source)）"
                : "更新 \(updated) 只，失败 \(failed.count) 只：\(failed.prefix(3).joined(separator: "、"))（\(source)）"
        }
    }

    @discardableResult
    func refreshFundConstituentsAndWait() async -> Bool {
        guard !isRefreshingFundHoldings else { return false }
        refreshFundConstituents()
        let deadline = Date().addingTimeInterval(90)
        while isRefreshingFundHoldings, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !isRefreshingFundHoldings && !fundHoldingsStatus.contains("失败")
    }

    private static func parseFundConstituents(_ bytes: Data, code: String) -> (asOf: String, holdings: [FundConstituent])? {
        if let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let rows = json["list"] as? [[String: Any]] {
            let holdings = rows.compactMap { row -> FundConstituent? in
                guard let stock = row["code"] as? String, stock.count == 6,
                      let name = row["name"] as? String,
                      let weight = (row["w"] as? NSNumber)?.doubleValue,
                      weight.isFinite, weight >= 0 else { return nil }
                let market = row["mkt"] as? String ?? ((stock.first == "6" || stock.first == "9") ? "sh\(stock)" : "sz\(stock)")
                return FundConstituent(code: stock, name: name, weightPercent: weight, marketCode: market)
            }
            return (json["asOf"] as? String ?? "", holdings)
        }
        guard let html = String(data: bytes, encoding: .utf8) else { return nil }
        let rowRegex = try? NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let cellRegex = try? NSRegularExpression(pattern: #"<td[^>]*>(.*?)</td>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        guard let rowRegex, let cellRegex else { return nil }
        let ns = html as NSString
        let asOfRegex = try? NSRegularExpression(pattern: #"截止至：[^>]*>([^<]+)<"#)
        let asOf: String = asOfRegex?.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)).flatMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        } ?? ""
        let rows = rowRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [FundConstituent] = []
        for row in rows {
            guard let range = Range(row.range(at: 1), in: html) else { continue }
            let fragment = String(html[range]) as NSString
            let cells = cellRegex.matches(in: fragment as String, range: NSRange(location: 0, length: fragment.length))
            guard cells.count >= 7,
                  let codeRange = Range(cells[1].range(at: 1), in: fragment as String),
                  let nameRange = Range(cells[2].range(at: 1), in: fragment as String),
                  let weightRange = Range(cells[6].range(at: 1), in: fragment as String) else { continue }
            func clean(_ value: String) -> String {
                value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let stock = clean(String((fragment as String)[codeRange])).filter(\.isNumber)
            let name = clean(String((fragment as String)[nameRange]))
            let rawWeight = clean(String((fragment as String)[weightRange]).replacingOccurrences(of: "%", with: ""))
            guard stock.count == 6, let weight = Double(rawWeight), weight.isFinite else { continue }
            let market = (stock.first == "6" || stock.first == "9") ? "sh\(stock)" : "sz\(stock)"
            out.append(FundConstituent(code: stock, name: name, weightPercent: weight, marketCode: market))
        }
        return (asOf, Array(out.prefix(50)))
    }

    func maybeRefreshFundNAVsAfterMarketClose() {
        guard data.automaticFundNAVRefreshEnabled,
              data.holdings.contains(where: { $0.kind == .fund }) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard calendar.component(.hour, from: .now) >= 19 else { return }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: .now)
        guard UserDefaults.standard.string(forKey: automaticNAVCheckDateKey) != today else { return }
        UserDefaults.standard.set(today, forKey: automaticNAVCheckDateKey)
        refreshFundNAVs()
    }

    private func refreshTodaySnapshotIfPresent() -> Bool {
        let today = dayString(.now)
        guard let i = data.snapshots.firstIndex(where: { $0.date == today }) else { return false }
        guard data.snapshots[i].quality != .manual else { return false }
        data.snapshots[i].total = totalAsset
        data.snapshots[i].cash = data.cash
        data.snapshots[i].recordedAt = .now
        data.snapshots[i].quality = snapshotQuality(for: today)
        data.snapshots[i].note = data.snapshots[i].quality == .provisional ? "仍有基金净值未结算" : nil
        return true
    }

    private static func parseFundNAVScript(_ bytes: Data, code: String) -> [FundNAVPoint]? {
        guard let text = String(data: bytes, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"Data_netWorthTrend\s*=\s*(\[[\s\S]*?\])\s*;"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let json = String(text[range]).data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return nil }
        let points = rows.compactMap { row -> FundNAVPoint? in
            guard let rawTime = (row["x"] as? NSNumber)?.doubleValue,
                  let rawNAV = (row["y"] as? NSNumber)?.doubleValue,
                  rawNAV.isFinite, rawNAV > 0 else { return nil }
            let timestamp = rawTime > 100_000_000_000 ? rawTime / 1000 : rawTime
            let date = Date(timeIntervalSince1970: timestamp)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
            return FundNAVPoint(code: code, date: formatter.string(from: date), nav: rawNAV)
        }
        return points.sorted { $0.date < $1.date }
    }

    func addWatch(code: String, name: String, group: String = "") {
        let cleanCode = code.filter(\.isNumber)
        guard cleanCode.count == 6, !data.quotes.contains(where: { $0.code == cleanCode }) else { return }
        data.quotes.append(Quote(code: cleanCode, name: name.isEmpty ? cleanCode : name,
                                 price: 0, changePct: 0, updatedAt: nil, group: group))
        save(label: "新增自选")
        Task { [weak self] in
            guard let self, let quote = try? await self.lookupETFQuote(code: cleanCode),
                  let index = self.data.quotes.firstIndex(where: { $0.code == cleanCode }) else { return }
            // 保留用户选的分组：网络返回的 Quote 没有 group 字段，直接整体替换会把它抹掉。
            var merged = quote
            merged.group = self.data.quotes[index].group
            self.data.quotes[index] = merged
            self.save(label: "自动识别自选名称")
        }
    }

    // MARK: - 自选分组

    /// 当前自选用到的分组名，按首次出现顺序去重。空串（未分组）排在最后。
    var watchGroups: [String] {
        var seen: [String] = []
        for q in data.quotes where !q.group.isEmpty && !seen.contains(q.group) { seen.append(q.group) }
        return seen
    }

    func moveWatch(code: String, to group: String) {
        guard let index = data.quotes.firstIndex(where: { $0.code == code }) else { return }
        data.quotes[index].group = group
        save(label: "移动自选分组")
    }

    func renameWatchGroup(from old: String, to new: String) {
        guard !new.isEmpty else { return }
        for index in data.quotes.indices where data.quotes[index].group == old {
            data.quotes[index].group = new
        }
        save(label: "重命名自选分组")
    }

    /// 把某只自选移到列表最前（置顶）。分组不变。
    func pinWatchToTop(code: String) {
        guard let index = data.quotes.firstIndex(where: { $0.code == code }), index > 0 else { return }
        let item = data.quotes.remove(at: index)
        data.quotes.insert(item, at: 0)
        save(label: "置顶自选")
    }

    private func tencentSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let c = trimmed.lowercased()
        // 腾讯美股代码大小写敏感（usNDX / usINX）；其他市场代码统一小写。
        if c.hasPrefix("us") { return "us" + String(trimmed.dropFirst(2)) }
        if c.hasPrefix("sh") || c.hasPrefix("sz") || c.hasPrefix("bj") || c.hasPrefix("hk") { return c }
        if c.count == 5, c.allSatisfy(\.isNumber) { return "hk" + c }
        if c.hasPrefix("6") || c.hasPrefix("9") || c.hasPrefix("5") || c.hasPrefix("11") || c.hasPrefix("50") || c.hasPrefix("51") || c.hasPrefix("56") || c.hasPrefix("58") { return "sh" + c }
        if c.hasPrefix("0") || c.hasPrefix("1") || c.hasPrefix("2") || c.hasPrefix("3") { return "sz" + c }
        if c.hasPrefix("4") || c.hasPrefix("8") { return "bj" + c }
        return "sh" + c
    }

    private static func shanghaiDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func decodeTencent(_ bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return String(data: bytes, encoding: .isoLatin1) ?? "" }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding))
            ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private func parseTencent(_ text: String) -> [String: (name: String, price: Double, changePct: Double, timestamp: Date?, premiumPct: Double?, iopv: Double?)] {
        var result: [String: (String, Double, Double, Date?, Double?, Double?)] = [:]
        let pattern = #"v_([a-zA-Z0-9]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 3 {
            let rawSymbol = ns.substring(with: match.range(at: 1))
            let symbol = rawSymbol.lowercased().hasPrefix("us")
                ? "us" + String(rawSymbol.dropFirst(2))
                : rawSymbol.lowercased()
            let fields = ns.substring(with: match.range(at: 2)).split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 32, let price = Double(fields[3]), price > 0 else { continue }
            let name = String(fields[1])
            let pct = Double(fields[32]) ?? 0
            let timestamp = fields.count > 30 ? parseTencentTimestamp(String(fields[30])) : nil
            let securityType = fields.count > 61 ? String(fields[61]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : ""
            let isETF = securityType == "ETF" || isTencentETFCode(symbol)
            // 腾讯 ETF 实时报价的数组下标 77 是折溢价率；下标 78 是基金净值。
            // 注意这里按 ~ 分割后的 0-based 下标读取，不能用第 63 项（该项是其他指标）。
            let rawPremium = fields.count > 77 ? parseTencentNumericField(String(fields[77])) : nil
            let rawIOPV = fields.count > 78 ? parseTencentNumericField(String(fields[78])) : nil
            let premium: Double? = {
                guard isETF else { return nil }
                // 溢价率没有 +50% 的理论上限（跨境 QDII ETF 可能长期处于高溢价）。
                // 只排除不可能的 <= -100% 折价和非有限值，避免把真实高溢价当成缺失。
                if let rawPremium, rawPremium.isFinite, rawPremium > -100 { return rawPremium }
                return nil
            }()
            let iopv: Double? = {
                guard isETF, let rawIOPV, rawIOPV.isFinite, rawIOPV > 0 else { return nil }
                return rawIOPV
            }()
            result[symbol] = (name, price, pct / 100, timestamp, premium, iopv)
        }
        return result
    }

    /// 腾讯部分行情源会省略证券类型字段；与网页版按代码前缀识别 ETF 的方式保持一致。
    func isTencentETFCode(_ raw: String) -> Bool {
        let code = raw.filter(\.isNumber)
        guard code.count == 6 else { return false }
        return ["15", "16", "18", "50", "51", "52", "56", "58", "59"].contains { code.hasPrefix($0) }
    }

    /// 部分行情响应会给字段附加百分号或千位分隔符。
    func parseTencentNumericField(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
        return Double(cleaned)
    }

    private func parseTencentTimestamp(_ raw: String) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 12 || digits.count == 14 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = digits.count == 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
        return formatter.date(from: digits)
    }
    func addHolding(_ holding: Holding) { data.holdings.append(holding); save(label: "新增持仓") }
    func allocationActualPercent(for holding: Holding) -> Double {
        guard totalAsset > 0, totalAsset.isFinite else { return 0 }
        return holding.marketValue / totalAsset * 100
    }
    func saveAllocationTarget(for holding: Holding, percent: Double) throws {
        guard percent.isFinite, (0...100).contains(percent) else { throw StoreError.invalidAllocationTarget }
        let target = AllocationTarget(code: holding.code, name: holding.name, kind: holding.kind, targetPercent: percent)
        if let i = data.allocationTargets.firstIndex(where: { $0.code == holding.code && $0.kind == holding.kind }) {
            data.allocationTargets[i] = target
        } else { data.allocationTargets.append(target) }
        save(label: "修改目标仓位")
    }
    func removeAllocationTarget(for holding: Holding) {
        data.allocationTargets.removeAll { $0.code == holding.code && $0.kind == holding.kind }
        save(label: "删除目标仓位")
    }
    func removeHolding(_ holding: Holding) {
        data.holdings.removeAll { $0.code == holding.code && $0.kind == holding.kind }
        if holding.kind == .fund { data.fundDCAPlans.removeAll { $0.code == holding.code } }
        save(label: "删除持仓")
    }

    func removeArchivedFundHistory(code: String) {
        guard !data.holdings.contains(where: { $0.code == code && $0.kind == .fund }) else { return }
        data.fundTransactions.removeAll { $0.code == code }
        data.ledger.removeAll { $0.code == code && $0.kind == .fund }
        data.fundNAVHistory.removeAll { $0.code == code }
        data.fundFeePolicies.removeAll { $0.code == code }
        data.fundDCAPlans.removeAll { $0.code == code }
        save(label: "删除已移出基金历史")
    }

    func upsertHolding(_ holding: Holding, oldCode: String? = nil) {
        if let oldCode, let i = data.holdings.firstIndex(where: { $0.code == oldCode && $0.kind == holding.kind }) {
            data.holdings[i] = holding
            if holding.kind == .fund, oldCode != holding.code {
                data.fundDCAPlans.removeAll { $0.code == oldCode }
            }
        } else if let i = data.holdings.firstIndex(where: { $0.code == holding.code && $0.kind == holding.kind }) {
            data.holdings[i] = holding
        } else { data.holdings.append(holding) }
        save(label: "保存持仓")
    }

    func addDCAPlan(code: String, name: String, amount: Double, feeRatePercent: Double,
                    frequency: FundDCAPlan.Frequency, weekday: Int, monthDay: Int) throws {
        guard code.count == 6, code.allSatisfy(\.isNumber), amount.isFinite, amount > 0,
              feeRatePercent.isFinite, (0...5).contains(feeRatePercent),
              (1...7).contains(weekday), (1...28).contains(monthDay) else {
            throw StoreError.invalidTrade
        }
        // 同一基金同时只允许一个生效计划。单独报这条，别让通用文案把用户误导去怀疑金额/费率。
        if let existing = data.fundDCAPlans.first(where: { $0.code == code && $0.enabled }) {
            throw StoreError.duplicateDCAPlan(existing.amount.cny(), existing.startDate)
        }
        data.fundDCAPlans.append(FundDCAPlan(code: code, name: name, amount: amount, feeRate: feeRatePercent / 100,
            frequency: frequency, weekday: weekday, monthDay: monthDay,
            startDate: dayString(.now), enabled: true, processedDates: []))
        save(label: "新增定投计划")
        // 定投计划一旦设定就按规则直接入账：本地已有该基金已公布净值时立刻补记，
        // 没有就顺手抓一次净值再补记。全程静默，不弹提示、不发通知。
        let booked = processAutomaticDCA()
        if booked == 0 {
            // 第一期要等该基金下一个已公布净值日；没有净值时不猜价、不提前入账。
            fundDCAStatus = "计划已保存。第一期要等该基金下一个已公布净值日才入账（不猜价）；本机暂无净值数据时会自动抓取后补记。"
        }
        refreshFundNAVs()
    }

    /// 原地修改已有定投计划：startDate 与 processedDates 原样保留，
    /// 改参数只影响后续期次，已记批次不重算、不删除，enabled 状态不变。
    func updateDCAPlan(id: UUID, amount: Double, feeRatePercent: Double,
                       frequency: FundDCAPlan.Frequency, weekday: Int, monthDay: Int) throws {
        guard amount.isFinite, amount > 0, feeRatePercent.isFinite, (0...5).contains(feeRatePercent),
              (1...7).contains(weekday), (1...28).contains(monthDay),
              let index = data.fundDCAPlans.firstIndex(where: { $0.id == id }) else {
            throw StoreError.invalidTrade
        }
        data.fundDCAPlans[index].amount = amount
        data.fundDCAPlans[index].feeRate = feeRatePercent / 100
        data.fundDCAPlans[index].frequency = frequency
        data.fundDCAPlans[index].weekday = weekday
        data.fundDCAPlans[index].monthDay = monthDay
        save(label: "修改定投计划")
        let booked = processAutomaticDCA()
        if booked == 0 {
            fundDCAStatus = "计划已保存。第一期要等该基金下一个已公布净值日才入账（不猜价）；本机暂无净值数据时会自动抓取后补记。"
        }
        refreshFundNAVs()
    }

    func removeDCAPlan(_ plan: FundDCAPlan) {
        data.fundDCAPlans.removeAll { $0.id == plan.id }
        save(label: "删除定投计划")
    }

    func setDCAPlan(_ plan: FundDCAPlan, enabled: Bool) {
        guard let index = data.fundDCAPlans.firstIndex(where: { $0.id == plan.id }) else { return }
        data.fundDCAPlans[index].enabled = enabled
        save(label: enabled ? "恢复定投计划" : "暂停定投计划")
    }

    /// Books a local DCA ledger entry only after the corresponding published
    /// NAV exists. It never touches reference cash and never places an order.
    @discardableResult
    func processAutomaticDCA() -> Int {
        var booked = 0
        for index in data.fundDCAPlans.indices where data.fundDCAPlans[index].enabled {
            let plan = data.fundDCAPlans[index]
            let groupedHistory = Dictionary(grouping: data.fundNAVHistory.filter {
                $0.code == plan.code && $0.date >= plan.startDate
            }, by: \.date)
            let history = groupedHistory.keys.sorted().compactMap { groupedHistory[$0]?.first }
            let navPoints = dcaExecutionPoints(history, plan: plan)
            for point in navPoints where !plan.processedDates.contains(point.date) {
                guard point.nav.isFinite, point.nav > 0 else { continue }
                let feeRate = plan.feeRate ?? 0.0015
                let fee = plan.amount * feeRate
                let netAmount = plan.amount - fee
                guard fee.isFinite, netAmount > 0 else { continue }
                let quantity = netAmount / point.nav
                guard quantity.isFinite, quantity > 0 else { continue }
                if let holdingIndex = data.holdings.firstIndex(where: { $0.code == plan.code && $0.kind == .fund }) {
                    var holding = data.holdings[holdingIndex]
                    let combinedQuantity = holding.quantity + quantity
                    let combinedCost = holding.quantity * holding.cost + plan.amount
                    guard combinedQuantity.isFinite, combinedCost.isFinite else { continue }
                    holding.quantity = combinedQuantity
                    holding.cost = combinedCost / combinedQuantity
                    if let latestNAV = data.fundNAVHistory.filter({ $0.code == plan.code }).max(by: { $0.date < $1.date }) {
                        holding.current = latestNAV.nav
                    }
                    data.holdings[holdingIndex] = holding
                } else {
                    let latest = data.fundNAVHistory.filter({ $0.code == plan.code }).max(by: { $0.date < $1.date })?.nav ?? point.nav
                    data.holdings.append(Holding(code: plan.code, name: plan.name, quantity: quantity,
                        cost: point.nav, current: latest, kind: .fund))
                }
                data.fundTransactions.append(FundTransaction(code: plan.code, name: plan.name,
                    side: .buy, requestDate: point.date, effectiveDate: point.date,
                    quantity: quantity, nav: point.nav, amount: plan.amount, fee: fee,
                    realizedPnL: 0, status: .confirmed, isBackfill: false,
                    dividendMode: nil, linkedCash: false, isAutomaticDCA: true, dcaPlanID: plan.id))
                data.cashFlows.append(CashFlow(date: parseDay(point.date) ?? .now, amount: plan.amount,
                    memo: "定投外部投入 · \(plan.name)（用于快照收益调整）", affectsCash: false))
                if let planIndex = data.fundDCAPlans.firstIndex(where: { $0.id == plan.id }) {
                    data.fundDCAPlans[planIndex].processedDates.append(point.date)
                    if data.fundDCAPlans[planIndex].processedDates.count > 2000 {
                        data.fundDCAPlans[planIndex].processedDates.removeFirst(data.fundDCAPlans[planIndex].processedDates.count - 2000)
                    }
                }
                booked += 1
            }
        }
        if booked > 0 {
            refreshTodaySnapshotIfPresent()
            fundDCAStatus = "已按已公布净值补记定投 \(booked) 期；仅更新本机账本"
            save()
        }
        return booked
    }

    private func dcaExecutionPoints(_ history: [FundNAVPoint], plan: FundDCAPlan) -> [FundNAVPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        switch plan.frequency {
        case .daily:
            return history
        case .weekly:
            let grouped = Dictionary(grouping: history) { point -> String in
                guard let date = parseDay(point.date) else { return point.date }
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
            }
            let startDate = parseDay(plan.startDate)
            return grouped.values.compactMap { points in
                if let startDate, let firstPoint = points.first, let firstDate = parseDay(firstPoint.date) {
                    let startWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startDate)
                    let pointWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstDate)
                    let sameWeek = startWeek.yearForWeekOfYear == pointWeek.yearForWeekOfYear
                        && startWeek.weekOfYear == pointWeek.weekOfYear
                    let startWeekday = calendar.component(.weekday, from: startDate)
                    if sameWeek && plan.weekday < startWeekday && !(startWeekday == 1 || startWeekday == 7) { return nil }
                }
                return points.sorted { $0.date < $1.date }.first { point in
                    guard let date = parseDay(point.date) else { return false }
                    return calendar.component(.weekday, from: date) >= plan.weekday
                }
            }.sorted { $0.date < $1.date }
        case .biweekly:
            guard let startDate = parseDay(plan.startDate), let lastDate = history.compactMap({ parseDay($0.date) }).max() else { return [] }
            let sortedHistory = history.sorted { $0.date < $1.date }
            var result: [FundNAVPoint] = []
            var due = calendar.startOfDay(for: startDate)
            var lastSelected = ""
            while due <= lastDate {
                let dueString = dayString(due)
                if let selected = sortedHistory.first(where: { $0.date >= dueString && $0.date > lastSelected }),
                   let selectedDate = parseDay(selected.date),
                   ((calendar.dateComponents([.day], from: due, to: selectedDate).day) ?? 99) <= 10 {
                    result.append(selected)
                    lastSelected = selected.date
                }
                guard let nextDue = calendar.date(byAdding: .day, value: 14, to: due) else { break }
                due = nextDue
            }
            return result
        case .monthly:
            let grouped = Dictionary(grouping: history) { String($0.date.prefix(7)) }
            return grouped.values.compactMap { points in
                if let firstDate = parseDay(plan.startDate),
                   let firstPoint = points.first,
                   String(plan.startDate.prefix(7)) == String(firstPoint.date.prefix(7)),
                   calendar.component(.day, from: firstDate) > plan.monthDay { return nil }
                let month = points.first.map { String($0.date.prefix(7)) } ?? ""
                let monthDate = parseDay(month + "-01")
                let range = monthDate.flatMap { calendar.range(of: .day, in: .month, for: $0) }
                let targetDay = min(plan.monthDay, range?.count ?? plan.monthDay)
                return points.sorted { $0.date < $1.date }.first { point in
                    guard let date = parseDay(point.date) else { return false }
                    return calendar.component(.day, from: date) >= targetDay
                }
            }.sorted { $0.date < $1.date }
        }
    }

    private func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    func recordTrade(code: String, kind: Holding.Kind, side: LedgerEntry.Side, quantity: Double, price: Double,
                     fee: Double, linkedCash: Bool, date: Date = .now, settlementDate: Date? = nil,
                     fundRedemptionLots: [FundLotRedemption]? = nil,
                     fundFeeWasEstimated: Bool = false) throws {
        guard quantity > 0, price > 0, fee >= 0, quantity.isFinite, price.isFinite, fee.isFinite,
              let i = data.holdings.firstIndex(where: { $0.code == code && $0.kind == kind }) else { throw StoreError.invalidTrade }
        var h = data.holdings[i]
        let gross = quantity * price
        guard gross.isFinite else { throw StoreError.invalidTrade }
        var realized = 0.0
        switch side {
        case .buy:
            let newQty = h.quantity + quantity
            let totalCost = h.cost * h.quantity + gross + fee
            guard newQty.isFinite, newQty > 0, totalCost.isFinite else { throw StoreError.invalidTrade }
            if linkedCash && data.cash < gross + fee { throw StoreError.insufficientCash }
            h.cost = totalCost / newQty
            h.quantity = newQty
            if linkedCash { data.cash -= gross + fee }
        case .sell:
            guard quantity <= h.quantity + 1e-8 else { throw StoreError.insufficientShares }
            realized = (price - h.cost) * quantity - fee
            guard realized.isFinite else { throw StoreError.invalidTrade }
            if linkedCash {
                let proceeds = gross - fee
                guard proceeds >= 0, (data.cash + proceeds).isFinite else { throw StoreError.invalidTrade }
            }
            h.quantity = max(0, h.quantity - quantity)
            if h.quantity < 1e-8 { h.quantity = 0 }
            if linkedCash { data.cash += gross - fee }
        }
        data.holdings[i] = h
        data.ledger.append(LedgerEntry(date: date, code: code, name: h.name, side: side, quantity: quantity, price: price, fee: fee, realizedPnL: realized, linkedCash: linkedCash, kind: kind))
        if kind == .fund {
            let day = dayString(date)
            let settleDay = dayString(settlementDate ?? date)
            data.fundTransactions.append(FundTransaction(code: code, name: h.name,
                side: side == .buy ? .buy : .sell, requestDate: day,
                effectiveDate: settleDay,
                quantity: quantity, nav: price, amount: gross, fee: fee, realizedPnL: realized,
                status: .confirmed, isBackfill: false, dividendMode: nil, linkedCash: linkedCash,
                redemptionLots: side == .sell ? fundRedemptionLots : nil,
                feeWasEstimated: side == .sell && fundFeeWasEstimated))
        }
        save(label: "新增交易流水")
    }

    func undoLatestTrade() throws {
        guard let trade = data.ledger.last, trade.affectsHoldings != false,
              let holdingIndex = data.holdings.firstIndex(where: { $0.code == trade.code && $0.kind == (trade.kind ?? .etf) }) else {
            throw StoreError.noUndoableTrade
        }
        let holding = data.holdings[holdingIndex]
        let fundIndex: Int? = trade.kind == .fund ? data.fundTransactions.lastIndex(where: {
            $0.code == trade.code && $0.status == .confirmed
                && $0.side == (trade.side == .buy ? .buy : .sell)
                && abs($0.quantity - trade.quantity) <= 0.000001
                && abs($0.nav - trade.price) <= 0.000001
                && $0.requestDate == dayString(trade.date)
        }) : nil
        if trade.kind == .fund {
            guard let fundIndex,
                  !data.fundTransactions[(fundIndex + 1)...].contains(where: { $0.code == trade.code }) else {
                throw StoreError.noUndoableTrade
            }
        }
        var updated = holding
        var updatedCash = data.cash
        switch trade.side {
        case .buy:
            let remaining = holding.quantity - trade.quantity
            guard remaining >= -0.000001 else { throw StoreError.noUndoableTrade }
            if remaining <= 0.000001 {
                updated.quantity = 0
                updated.cost = 0
            } else {
                let priorBasis = holding.quantity * holding.cost - trade.gross - trade.fee
                guard priorBasis.isFinite, priorBasis >= -0.01 else { throw StoreError.noUndoableTrade }
                updated.quantity = remaining
                updated.cost = max(0, priorBasis) / remaining
            }
            if trade.linkedCash { updatedCash += trade.gross + trade.fee }
        case .sell:
            if trade.linkedCash && updatedCash + 0.000001 < trade.gross - trade.fee {
                throw StoreError.insufficientCashToUndoTrade
            }
            updated.quantity += trade.quantity
            if trade.linkedCash { updatedCash -= trade.gross - trade.fee }
        }
        guard updated.quantity.isFinite, updated.cost.isFinite, updatedCash.isFinite, updatedCash >= -0.000001 else {
            throw StoreError.noUndoableTrade
        }
        data.holdings[holdingIndex] = updated
        data.cash = max(0, updatedCash)
        if let fundIndex { data.fundTransactions.remove(at: fundIndex) }
        data.ledger.removeLast()
        if data.cash < 0.000001 { data.cash = max(0, data.cash) }
        save(label: "撤销最近一笔交易")
    }

    func confirmFundRedemptionFee(transactionID: UUID, actualFee: Double) throws {
        guard let index = data.fundTransactions.firstIndex(where: { $0.id == transactionID }) else {
            throw StoreError.invalidFundFeeCorrection
        }
        let transaction = data.fundTransactions[index]
        guard transaction.side == .sell, transaction.status == .confirmed,
              transaction.feeWasEstimated == true,
              actualFee.isFinite, actualFee >= 0, actualFee <= transaction.amount else {
            throw StoreError.invalidFundFeeCorrection
        }

        let feeDifference = transaction.fee - actualFee
        guard feeDifference.isFinite else { throw StoreError.invalidFundFeeCorrection }
        var updatedCash = data.cash
        if transaction.linkedCash {
            updatedCash += feeDifference
            guard updatedCash.isFinite, updatedCash >= -0.000001 else {
                throw StoreError.insufficientCashForFeeCorrection
            }
        }

        if let ledgerIndex = data.ledger.lastIndex(where: {
            ($0.kind ?? .etf) == .fund && $0.code == transaction.code && $0.side == .sell
                && abs($0.quantity - transaction.quantity) <= 0.000001
                && abs($0.price - transaction.nav) <= 0.000001
                && dayString($0.date) == transaction.requestDate
        }) {
            data.ledger[ledgerIndex].fee = actualFee
            data.ledger[ledgerIndex].realizedPnL += feeDifference
        }
        data.fundTransactions[index].fee = actualFee
        data.fundTransactions[index].realizedPnL += feeDifference
        data.fundTransactions[index].feeWasEstimated = false
        if transaction.linkedCash { data.cash = max(0, updatedCash) }
        save(label: "核对基金实际赎回费")
    }

    func deleteLedgerEntry(_ id: UUID) throws {
        guard let targetIndex = data.ledger.firstIndex(where: { $0.id == id }) else { throw StoreError.noUndoableTrade }
        let target = data.ledger[targetIndex]
        guard target.affectsHoldings != false else {
            data.ledger.remove(at: targetIndex)
            save(label: "删除导入的历史流水")
            return
        }
        let kind = target.kind ?? .etf
        guard kind == .etf,
              let holdingIndex = data.holdings.firstIndex(where: { $0.code == target.code && $0.kind == kind }) else {
            throw StoreError.noUndoableTrade
        }
        var quantity = data.holdings[holdingIndex].quantity
        var averageCost = data.holdings[holdingIndex].cost
        let instrumentTrades = data.ledger.filter { ($0.kind ?? .etf) == kind && $0.code == target.code && $0.affectsHoldings != false }
        for trade in instrumentTrades.reversed() {
            switch trade.side {
            case .buy:
                let priorQuantity = quantity - trade.quantity
                guard priorQuantity >= -0.000001 else { throw StoreError.noUndoableTrade }
                if priorQuantity <= 0.000001 {
                    let priorBasis = quantity * averageCost - trade.gross - trade.fee
                    guard abs(priorBasis) <= 0.02 else { throw StoreError.noUndoableTrade }
                    quantity = 0; averageCost = 0
                } else {
                    let priorBasis = quantity * averageCost - trade.gross - trade.fee
                    guard priorBasis.isFinite, priorBasis >= -0.02 else { throw StoreError.noUndoableTrade }
                    quantity = priorQuantity; averageCost = max(0, priorBasis) / priorQuantity
                }
            case .sell:
                guard trade.quantity > 0 else { throw StoreError.noUndoableTrade }
                if quantity <= 0.000001 {
                    averageCost = trade.price - (trade.realizedPnL + trade.fee) / trade.quantity
                }
                quantity += trade.quantity
            }
            guard quantity.isFinite, averageCost.isFinite, quantity >= 0, averageCost >= 0 else { throw StoreError.noUndoableTrade }
        }
        let initialQuantity = quantity
        let initialCost = averageCost
        quantity = initialQuantity; averageCost = initialCost
        var recomputedRealized: [UUID: Double] = [:]
        for trade in instrumentTrades where trade.id != id {
            switch trade.side {
            case .buy:
                let next = quantity + trade.quantity
                guard next.isFinite, next > 0 else { throw StoreError.noUndoableTrade }
                averageCost = (quantity * averageCost + trade.gross + trade.fee) / next
                quantity = next
            case .sell:
                guard trade.quantity <= quantity + 0.000001 else { throw StoreError.noUndoableTrade }
                recomputedRealized[trade.id] = (trade.price - averageCost) * trade.quantity - trade.fee
                quantity = max(0, quantity - trade.quantity)
                if quantity <= 0.000001 { quantity = 0; averageCost = 0 }
            }
        }
        var newCash = data.cash
        if target.linkedCash {
            if target.side == .buy { newCash += target.gross + target.fee }
            else {
                let proceeds = target.gross - target.fee
                guard proceeds >= 0, newCash + 0.000001 >= proceeds else { throw StoreError.insufficientCashToUndoTrade }
                newCash -= proceeds
            }
        }
        guard newCash.isFinite, quantity.isFinite, averageCost.isFinite else { throw StoreError.noUndoableTrade }
        data.holdings[holdingIndex].quantity = quantity
        data.holdings[holdingIndex].cost = averageCost
        data.cash = max(0, newCash)
        data.ledger.removeAll { $0.id == id }
        for index in data.ledger.indices {
            if let realized = recomputedRealized[data.ledger[index].id] {
                data.ledger[index].realizedPnL = realized
            }
        }
        save(label: "删除交易流水并重算持仓")
    }

    func isLatestLedgerFundTransaction(_ transaction: FundTransaction) -> Bool {
        guard let trade = data.ledger.last, trade.affectsHoldings != false, trade.kind == .fund,
              trade.code == transaction.code,
              trade.side == (transaction.side == .buy ? .buy : .sell),
              abs(trade.quantity - transaction.quantity) < 0.000001,
              abs(trade.price - transaction.nav) < 0.000001,
              dayString(trade.date) == transaction.requestDate,
              let index = data.fundTransactions.lastIndex(where: { $0.id == transaction.id }) else { return false }
        return !data.fundTransactions[(index + 1)...].contains(where: { $0.code == transaction.code })
    }

    /// - Parameter automatic: 自动路径（打开 App、前台恢复、净值刷新后）传 true。
    ///   交易日**开盘前**不自动写：那一刻行情还停在上一个交易日，写进去的其实是
    ///   上一交易日的估值，只会让收益曲线多出一段平线。手动点按钮时不拦 ——
    ///   那是用户明确要记这一次。
    func recordSnapshot(automatic: Bool = false) {
        // 休市日自动进入页面不应重复写入上一交易日估值；需要手工校正时走历史快照表单。
        guard !isMarketClosedToday else { return }
        if automatic, !MarketCalendar.hasOpenedToday(.now) { return }
        let date = dayString(.now)
        if data.snapshots.first(where: { $0.date == date })?.quality == .manual { return }
        let quality = snapshotQuality(for: date)
        let snap = PortfolioSnapshot(date: date, total: totalAsset, cash: data.cash, recordedAt: .now,
                                     quality: quality, note: quality == .provisional ? "仍有基金净值未结算" : nil)
        let previous = data.snapshots.first(where: { $0.date == date })
        if let previous,
           previous.total == snap.total, previous.cash == snap.cash,
           previous.quality == snap.quality, previous.note == snap.note, previous.recordedAt != nil {
            // 值没变就别写。原来这里每次都替换一次，而 `recordedAt` 每次都不同 ——
            // 于是每回一次前台都会「变了」，bump 一个 NAS 版本、上传一整份文档
            // （含全部分时与日 K 档案），还顺带占掉一个撤销点。
            return
        }
        if let i = data.snapshots.firstIndex(where: { $0.date == date }) { data.snapshots[i] = snap }
        else { data.snapshots.append(snap) }
        data.snapshots.sort { $0.date < $1.date }
        // **只在这一天第一次记、或快照性质变了（临时 → 已核实）时才推给 NAS 与网页版。**
        // 盘中每次回前台刷新出的只是同一行的当日估值，两边各自算就行 ——
        // 这正是用户说的「日内的持仓盈亏两边都会自动变，不需要实时同步」。
        // 自动路径下纯数值刷新只落本地盘，下一次真正的账本编辑会把最新快照一起带上去。
        let isFirstRecordToday = previous == nil
        let qualityChanged = previous.map { $0.quality != snap.quality } ?? true
        save(label: "记录资产快照", propagate: !automatic || isFirstRecordToday || qualityChanged)
    }

    func snapshotReturn(from previous: PortfolioSnapshot, to current: PortfolioSnapshot) -> Double {
        let lowerBound = previous.recordedAt ?? dayBoundary(after: previous.date)
        let upperBound = current.recordedAt ?? dayBoundary(after: current.date)
        let netFlow = data.cashFlows.reduce(0.0) { result, flow in
            flow.date > lowerBound && flow.date < upperBound && (flow.external ?? true) ? result + flow.amount : result
        }
        return current.total - previous.total - netFlow
    }

    /// Snapshot-based return for a selected calendar month. The baseline is
    /// the latest snapshot before the month (or the first snapshot in it when
    /// no earlier baseline exists); this deliberately reports the measured
    /// interval instead of inventing values for dates without snapshots.
    func snapshotMonthSummary(_ month: String) -> (start: PortfolioSnapshot, end: PortfolioSnapshot, pnl: Double, complete: Bool)? {
        let sorted = data.snapshots.sorted { $0.date < $1.date }
        let inMonth = sorted.filter { String($0.date.prefix(7)) == month }
        guard let end = inMonth.last else { return nil }
        let prior = sorted.last { $0.date < "\(month)-01" }
        let start = prior ?? inMonth.first
        guard let start, start.date < end.date else { return nil }
        let expectedStart = prior != nil
        return (start, end, snapshotReturn(from: start, to: end), expectedStart)
    }

    var snapshotMonths: [String] {
        Array(Set(data.snapshots.map { String($0.date.prefix(7)) })).sorted(by: >)
    }

    /// ETF / 证券已实现收益来自账本流水。旧版流水没有 kind 字段；
    /// 当时只支持 ETF，因此 nil 按 ETF 兼容。
    func ledgerDailyRealized(month: String) -> [(date: String, profit: Double, trades: Int)] {
        let grouped = Dictionary(grouping: data.ledger.filter {
            ($0.kind ?? .etf) == .etf && String(dayString($0.date).prefix(7)) == month
        }, by: { dayString($0.date) })
        return grouped.keys.sorted(by: >).map { date in
            let entries = grouped[date] ?? []
            return (date, entries.reduce(0) { $0 + $1.realizedPnL }, entries.count)
        }
    }

    var ledgerMonths: [String] {
        Array(Set(data.ledger.filter { ($0.kind ?? .etf) == .etf }
            .map { String(dayString($0.date).prefix(7)) })).sorted(by: >)
    }

    func adjustCash(amount: Double, memo: String) throws {
        let adjustedCash = data.cash + amount
        guard amount.isFinite, amount != 0, adjustedCash.isFinite, adjustedCash >= 0 else { throw StoreError.invalidCashFlow }
        data.cash = adjustedCash
        data.cashFlows.append(CashFlow(amount: amount, memo: memo.trimmingCharacters(in: .whitespacesAndNewlines), affectsCash: true))
        save(label: "调整参考现金")
    }

    func fundDailyPerformance(period: String? = nil) -> [FundDailyPerformance] {
        let codes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code))
        var byDay: [String: (profit: Double, base: Double, codes: Set<String>, lines: [String: FundDailyContribution])] = [:]
        for code in codes {
            var navByDay: [String: Double] = [:]
            // Use the same de-duplicated, valid history as the live NAV card. Older backups
            // may contain multiple values for one valuation date; raw array order is not authority.
            latestFundPoints(for: code).forEach { navByDay[$0.date] = $0.nav }
            let dates = navByDay.keys.sorted()
            guard dates.count > 1 else { continue }
            let trades = data.fundTransactions.filter { $0.code == code && $0.status == .confirmed }
                .sorted {
                    $0.effectiveDate == $1.effectiveDate
                        ? fundTransactionOrder($0.side) < fundTransactionOrder($1.side)
                        : $0.effectiveDate < $1.effectiveDate
                }
            let events = trades.map { (date: fundEventDate($0), trade: $0) }.sorted { $0.date < $1.date }
            var tradeIndex = 0
            var eventIndex = 0
            var sharesBeforeDate = 0.0
            for idx in 1..<dates.count {
                let previousDate = dates[idx - 1], date = dates[idx]
                while tradeIndex < trades.count && trades[tradeIndex].effectiveDate <= previousDate {
                    let trade = trades[tradeIndex]
                    switch trade.side {
                    case .buy: sharesBeforeDate += trade.quantity
                    case .sell: sharesBeforeDate -= trade.quantity
                    case .dividend where trade.dividendMode == .reinvest: sharesBeforeDate += trade.quantity
                    case .dividend: break
                    }
                    tradeIndex += 1
                }
                guard period.map({ date.hasPrefix($0) }) ?? true, let previousNAV = navByDay[previousDate],
                      let currentNAV = navByDay[date] else { continue }
                var dayTrades: [FundTransaction] = []
                while eventIndex < events.count && events[eventIndex].date <= date {
                    if events[eventIndex].date > previousDate { dayTrades.append(events[eventIndex].trade) }
                    eventIndex += 1
                }
                let distributions = dayTrades.reduce(0.0) { sum, trade in
                    trade.side == .dividend ? sum + trade.amount : sum
                }
                let fees = dayTrades.reduce(0.0) { sum, trade in trade.side == .dividend ? sum : sum + trade.fee }
                let shares = max(0, sharesBeforeDate.isFinite ? sharesBeforeDate : 0)
                guard shares > 0 || distributions != 0 || fees != 0 else { continue }
                let base = previousNAV * shares
                let change = (currentNAV - previousNAV) * shares + distributions - fees
                guard base.isFinite, change.isFinite else { continue }
                var row = byDay[date] ?? (0, 0, [], [:])
                row.profit += change; row.base += base; row.codes.insert(code)
                let holdingName = data.holdings.first(where: { $0.kind == .fund && $0.code == code })?.name
                    ?? trades.first?.name ?? code
                var line = row.lines[code] ?? FundDailyContribution(code: code, name: holdingName, profit: 0, baseValue: 0)
                line.profit += change; line.baseValue += base
                row.lines[code] = line
                byDay[date] = row
            }
        }
        return byDay.keys.sorted().compactMap { date in
            guard let row = byDay[date] else { return nil }
            return FundDailyPerformance(date: date, profit: row.profit, baseValue: row.base,
                fundCount: row.codes.count, contributions: row.lines.values.sorted { $0.profit > $1.profit })
        }
    }

    func fundDailyPerformance(month: String) -> [FundDailyPerformance] {
        fundDailyPerformance(period: month)
    }

    /// Explain holdings that cannot yet appear in the fund return calendar, instead of
    /// making a missing row look like a zero return. In particular, a manual holding
    /// needs a confirmed purchase/backfill date to know how many shares existed then.
    func fundDailyCalendarExcluded(period: String? = nil) -> [(code: String, reason: String)] {
        let codes = Set(data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }.map(\.code)
            + data.fundTransactions.map(\.code))
        return codes.sorted().compactMap { code in
            let points = latestFundPoints(for: code)
            let inPeriod = period.map { prefix in points.filter { $0.date.hasPrefix(prefix) } } ?? points
            let hasPair = inPeriod.count > 0 && points.contains { $0.date < inPeriod[0].date }
            let holdingExists = data.holdings.contains { $0.kind == .fund && $0.code == code && $0.quantity > 0 }
            let hasBuyBaseline = data.fundTransactions.contains {
                $0.code == code && $0.status == .confirmed && $0.side == .buy
            }
            if !hasPair { return (code, "缺少覆盖该月的两期已公布净值") }
            if holdingExists && !hasBuyBaseline { return (code, "缺少历史申购/起始份额，无法确认当日持有份额") }
            return nil
        }
    }

    func fundDailyCalendarExcluded(month: String) -> [(code: String, reason: String)] {
        fundDailyCalendarExcluded(period: month)
    }

    func inferredBackfillShares(for holding: Holding) -> Double {
        let sold = data.fundTransactions.filter {
            $0.code == holding.code && $0.side == .sell && $0.status == .confirmed
        }.reduce(0.0) { $0 + $1.quantity }
        let reinvested = data.fundTransactions.filter {
            $0.code == holding.code && $0.side == .dividend && $0.dividendMode == .reinvest && $0.status == .confirmed
        }.reduce(0.0) { $0 + $1.quantity }
        return max(0, holding.quantity + sold - reinvested)
    }

    func recordFundBackfill(code: String, date: Date, quantity: Double) throws {
        // 只有存在真实成交流水（已确认的卖出 / 红利再投）能解释当前份额时，才允许补录历史起点。
        // 若某只基金只是手工录入、没有任何买卖流水， inferredBackfillShares 会等于当前份额，
        // 进而凭空生成一条“早已持有”的买入记录，得到看似精确但不可靠的旧快照——此种情况明确跳过。
        let hasExplainingRecords = data.fundTransactions.contains {
            $0.code == code && $0.status == .confirmed
                && ($0.side == .sell || ($0.side == .dividend && $0.dividendMode == .reinvest))
        }
        guard quantity.isFinite, quantity > 0,
              let holding = data.holdings.first(where: { $0.code == code && $0.kind == .fund }),
              !data.fundTransactions.contains(where: { $0.code == code && $0.side == .buy }),
              hasExplainingRecords,
              abs(quantity - inferredBackfillShares(for: holding)) <= 0.01 else {
            throw StoreError.invalidFundBackfill
        }
        let day = dayString(date)
        guard day <= dayString(.now), !data.fundTransactions.contains(where: {
            $0.code == code && $0.side == .sell && $0.effectiveDate < day
        }) else { throw StoreError.invalidFundBackfill }
        data.fundTransactions.append(FundTransaction(code: code, name: holding.name,
            side: .buy, requestDate: day, effectiveDate: day, quantity: quantity,
            nav: 0, amount: 0, fee: 0, realizedPnL: 0, status: .confirmed,
            isBackfill: true, dividendMode: nil, linkedCash: false))
        save(label: "补录基金历史起点")
    }

    func recordFundDividend(code: String, date: Date, amount: Double,
                            mode: FundTransaction.DividendMode, nav: Double,
                            linkCash: Bool) throws {
        guard amount.isFinite, amount > 0,
              let index = data.holdings.firstIndex(where: { $0.code == code && $0.kind == .fund }) else {
            throw StoreError.invalidDividend
        }
        var holding = data.holdings[index]
        var shares = 0.0
        if mode == .reinvest {
            guard nav.isFinite, nav > 0 else { throw StoreError.invalidDividend }
            shares = amount / nav
            let newQuantity = holding.quantity + shares
            let newCost = holding.quantity * holding.cost + amount
            guard shares.isFinite, shares > 0, newQuantity.isFinite, newCost.isFinite else {
                throw StoreError.invalidDividend
            }
            holding.quantity = newQuantity
            holding.cost = newCost / newQuantity
            holding.current = nav
            data.holdings[index] = holding
        } else if linkCash {
            guard (data.cash + amount).isFinite else { throw StoreError.invalidCashFlow }
            data.cash += amount
        }
        let day = dayString(date)
        data.fundTransactions.append(FundTransaction(code: code, name: holding.name,
            side: .dividend, requestDate: day, effectiveDate: day,
            quantity: shares, nav: nav, amount: amount, fee: 0, realizedPnL: 0,
            status: .confirmed, isBackfill: false, dividendMode: mode, linkedCash: linkCash))
        save(label: "记录基金分红")
    }

    private func fundTransactionOrder(_ side: FundTransaction.Side) -> Int {
        switch side { case .buy, .dividend: return 0; case .sell: return 1 }
    }

    private func fundEventDate(_ trade: FundTransaction) -> String {
        trade.side == .buy ? trade.requestDate : trade.effectiveDate
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func dayBoundary(after day: String) -> Date {
        guard let parsed = parseDay(day) else { return .distantPast }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.date(byAdding: .day, value: 1, to: parsed) ?? .distantFuture
    }

    func replaceData(_ imported: PortfolioData, intradayBars: [IntradayBar]? = nil, dailyBars: [DailyBar]? = nil) {
        data = imported
        if let intradayBars { self.intradayBars = Self.uniqueIntradayBars(intradayBars) }
        rebuildIntradayMinuteIndex()
        if let dailyBars {
            self.dailyBars = Dictionary(grouping: dailyBars, by: \.code).mapValues { $0.sorted { $0.date < $1.date } }
            invalidateSignalCache()
        }
        saveDailyBars()
        saveIntradayBars(); save(label: "导入并替换账本")
    }
}

enum StoreError: LocalizedError {
    case invalidTrade, insufficientShares, insufficientCash, insufficientCashToUndoTrade, insufficientCashForFeeCorrection, noUndoableTrade, invalidCashFlow, invalidFundBackfill, invalidDividend, invalidAlert, invalidManualPrice, invalidManualSnapshot, invalidFundFeePolicy, invalidFundFeeCorrection, invalidAllocationTarget, invalidImportedLedger, duplicateDCAPlan(String, String)
    var errorDescription: String? {
        switch self {
        case .invalidTrade: return "请检查份额、价格、费用和标的。"
        case .insufficientShares: return "卖出份额不能超过当前持仓。"
        case .insufficientCash: return "参考现金不足，不能记录这笔现金联动买入。"
        case .insufficientCashToUndoTrade: return "现金不足，无法安全撤销这笔卖出；请先补足参考现金。"
        case .insufficientCashForFeeCorrection: return "按实际费用校正后参考现金会小于 0；请先核对现金账。"
        case .noUndoableTrade: return "当前最新交易无法安全撤销；请检查持仓和基金后续流水。"
        case .invalidCashFlow: return "现金流金额无效，或转出金额超过当前参考现金。"
        case .invalidFundBackfill: return "无法补录：基金不存在、份额无效，或已有买入流水。"
        case .invalidDividend: return "分红金额、净值或基金持仓无效。"
        case .invalidAlert: return "提醒代码或目标价格无效。"
        case .invalidManualPrice: return "手填价格或昨收无效。"
        case .invalidManualSnapshot: return "请输入有效日期（YYYY-MM-DD）和不小于 0 的总资产金额。"
        case .invalidFundFeePolicy: return "费率档位无效：请设置从 0 天开始的费率档，天数不能重复，费率须在 0% 到 100% 之间。"
        case .invalidFundFeeCorrection: return "这笔赎回不存在、已经核对，或实际费用超出赎回总额。"
        case .invalidAllocationTarget: return "目标仓位需在 0% 到 100% 之间。"
        case .invalidImportedLedger: return "无法安全计算成交流水：请导入包含完整买入起点的历史记录，并检查卖出数量是否超过此前买入。"
        case .duplicateDCAPlan(let amount, let startDate):
            return "该基金已有一个生效中的定投计划（每期 \(amount)，开始于 \(startDate)）。同一基金同时只能有一个生效计划；重新打开本页会直接改成修改它，也可先在「定投执行记录」里暂停或删除旧计划。"
        }
    }
}
