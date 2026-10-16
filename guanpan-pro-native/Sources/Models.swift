import Foundation

/// `Equatable` 是给 `PortfolioStore.performQuoteRefresh` 用的：
/// 那一轮刷新会先在副本上算好新的行情再整体赋回 `data`，而 `@Published` 是无条件发布的 ——
/// 内容一模一样也会发一次改动通知，把整棵视图树重建一遍。有了 `==` 就能先比后写，
/// 盘中行情没变的那几十轮刷新就不会再触发全量重绘（这是「滑动卡顿」的主因之一）。
struct Quote: Codable, Identifiable, Equatable {
    var id: String { code }
    var code: String
    var name: String
    var price: Double
    /// 涨跌比例按小数存储：0.0123 表示上涨 1.23%；用于界面百分数时需乘 100。
    var changePct: Double
    var updatedAt: Date?
    /// 自选分组名。空串归入「未分组」。
    ///
    /// 这是后加的字段：Swift 合成的 `Decodable` 对「有默认值但非 Optional」的属性
    /// 仍然调用 `decode(_:forKey:)`，老备份里没有这个 key 会直接抛错、整份账本打不开。
    /// 所以这里手写一次解码，缺 key 时回落到空串。
    var group: String = ""

    private enum CodingKeys: String, CodingKey {
        case code, name, price, changePct, updatedAt, group
    }

    init(code: String, name: String, price: Double, changePct: Double,
         updatedAt: Date? = nil, group: String = "") {
        self.code = code
        self.name = name
        self.price = price
        self.changePct = changePct
        self.updatedAt = updatedAt
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? code
        price = try c.decodeIfPresent(Double.self, forKey: .price) ?? 0
        changePct = try c.decodeIfPresent(Double.self, forKey: .changePct) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
    }
}

/// 首页顶部指数条的一项。
///
/// 指数和自选/持仓不是一回事：它不在账本里、也不参与盈亏计算，
/// 只是「现在大盘什么水平」的参照，所以单独建模、单独缓存，
/// 不塞进 `PortfolioData`（塞进去会被写进备份、被 NAS 同步当账本推来推去）。
struct MarketIndexQuote: Codable, Identifiable, Hashable {
    var id: String { symbol }
    /// 唯一标识 = 东方财富 secid（`1.000001`、`100.N225`）。
    /// 列表行情和详情页的 K 线 / 分时都拿它去取数；对应的腾讯代码见 `MarketIndexStore.catalog`。
    var symbol: String
    var name: String
    var price: Double
    /// 涨跌比例按小数存储：0.0005 表示上涨 0.05%；上屏前要乘 100。
    var changePct: Double
    var updatedAt: Date?
}

/// 首页指数条的代码表与本地缓存。
///
/// 缓存只为了「冷启动时这一排不是空的」：指数条每次进首页都会重新取，
/// 拿不到新数据时就继续显示上次的值，用户至少知道上次是什么水平。
enum MarketIndexStore {
    /// 一条指数：东财 secid（稳定主键，也是缓存对齐用的键）+ 腾讯代码 + 新浪代码。
    /// 三个源都填 nil 不可能出现 —— 至少得有一个拿得到数。
    struct Entry {
        let secid: String
        let tencent: String?
        let name: String
        /// 新浪全球指数代码（`int_nikkei` / `b_TOPIX`）。腾讯没有日经与东证，
        /// 而东财 `push2` 在本机会被风控，所以这几个只能靠新浪。
        let sina: String?

        init(secid: String, tencent: String?, name: String, sina: String? = nil) {
            self.secid = secid
            self.tencent = tencent
            self.name = name
            self.sina = sina
        }
    }

    /// 顺序即展示顺序：常用的上证、深证、标普和纳指 100 放在首页首屏，
    /// 其他指数继续横向滑动查看。
    ///
    /// **为什么三个源都要**（都是实测结论，不是推测）：
    /// · 腾讯 `qt.gtimg.cn` 覆盖 A 股 / 港股 / 美股，但**没有**日经与东证 ——
    ///   试过 jp/nk/us 各前缀 × 一批指数名，命中的全是同名美股
    ///   （例如 `usDAX` 其实是 DAX 德国指数 ETF）。
    /// · 东方财富 `push2` 覆盖面最全，但本机出口 IP 已被风控（连续请求直接断连），
    ///   所以只能当作「有就用」的备选，不能当作主力。
    /// · 新浪 `hq.sinajs.cn` 的 `b_NKY` 给日经、`b_TOPIX` 给东证、`b_KOSPI` 给韩国，
    ///   正好补上腾讯的缺口。**必须用 `b_` 前缀**：实测（2026-10-15）`int_nikkei` 返回的是
    ///   `44946.64 / -0.90%` 这种陈旧错值，而 `b_NKY` 返回 `64425.73 / -4.90%`，
    ///   与东财 `100.N225` 的 `64425.95 / -4.90%` 一致；`int_topix` / `int_kospi` 则直接是空的。
    /// 三个源**并行**取、后写的覆盖先写的：谁挂都不至于让整排空白。
    ///
    /// 台湾加权、英国富时、德国 DAX 已按用户要求下线（「太偏了」）。
    static let catalog: [Entry] = [
        Entry(secid: "1.000001", tencent: "sh000001", name: "上证指数"),
        Entry(secid: "0.399001", tencent: "sz399001", name: "深证成指"),
        Entry(secid: "100.SPX", tencent: "usINX", name: "标普500", sina: "b_SPX"),
        // NDX 是纳斯达克 100；IXIC 是纳斯达克综合指数，二者不能混用。
        Entry(secid: "100.NDX", tencent: "usNDX", name: "纳斯达克100"),
        Entry(secid: "0.399006", tencent: "sz399006", name: "创业板指"),
        Entry(secid: "1.000300", tencent: "sh000300", name: "沪深300"),
        Entry(secid: "1.000688", tencent: "sh000688", name: "科创50"),
        Entry(secid: "100.HSI", tencent: "hkHSI", name: "恒生指数", sina: "b_HSI"),
        Entry(secid: "124.HSTECH", tencent: "hkHSTECH", name: "恒生科技"),
        // 道琼斯已按用户要求下线（2026-10-14：「道琼斯删了」）。
        Entry(secid: "100.N225", tencent: nil, name: "日经225", sina: "b_NKY"),
        Entry(secid: "100.TOPIX", tencent: nil, name: "东证TOPIX", sina: "b_TOPIX"),
        Entry(secid: "100.KS11", tencent: nil, name: "韩国KOSPI", sina: "b_KOSPI")
    ]

    /// secid → 展示名，方便别处按 secid 反查。
    static func name(for secid: String) -> String? {
        catalog.first { $0.secid == secid }?.name
    }

    private static let cacheKey = "guanpan.native.index.quotes"

    static func load() -> [MarketIndexQuote] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let list = try? JSONDecoder().decode([MarketIndexQuote].self, from: data) else { return [] }
        // 只保留仍在代码表里的项，并按代码表顺序重排 ——
        // 改过代码表之后，老缓存里多出来的项不该继续占位置。
        // （`Entry` 是 struct，可以走键路径；这里用闭包写法与工程其他处保持一致。）
        let order = catalog.map { $0.secid }
        return order.compactMap { secid in
            guard var quote = list.first(where: { $0.symbol == secid }) else { return nil }
            quote.name = name(for: secid) ?? quote.name
            return quote
        }
    }

    static func save(_ list: [MarketIndexQuote]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

struct QuoteAlert: Codable, Identifiable {
    enum Direction: String, Codable { case above, below }
    var id: UUID = UUID()
    var code: String
    var name: String
    var target: Double
    var direction: Direction
    var enabled: Bool
    var lastTriggeredAt: Date?
}
struct IntradayCompanionIntent: Codable, Identifiable {
    enum Side: String, Codable { case buy, sell }
    var id = UUID(); var code: String; var name: String; var side: Side; var quantity: Double
    var enabled = true; var createdAt = Date.now; var lastDecision = ""; var lastNotifiedAt: Date?
}

struct Holding: Codable, Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    var code: String
    var name: String
    var quantity: Double
    var cost: Double
    var current: Double
    var kind: Kind
    /// Exchange quote timestamp reported by the market data source, if available.
    var marketUpdatedAt: Date? = nil
    var maxPositionPercent: Double? = nil
    var maWarningPeriod: Int? = nil
    var annualDividendPerShare: Double? = nil
    var costOverride: Double? = nil

    enum Kind: String, Codable { case etf, fund }
    var marketValue: Double { quantity * current }
    var pnl: Double { quantity * (current - cost) }
}

struct ManualQuoteOverride: Codable {
    var price: Double
    var previousClose: Double?
    var updatedAt: Date = .now
}

struct ETFDividendEvent: Codable, Identifiable {
    var id: String { "\(code)-\(date)" }
    var code: String
    var date: String
    var amountPerShare: Double
    /// True for old events inferred from adjusted prices, which do not verify a cash payout.
    /// Optional keeps existing JSON archives decodable; missing means a recorded event.
    var isEstimated: Bool? = nil
}

/// ETF 年股息只采用人工录入或近 12 个月已记录的现金分红，不按指数风格猜测。
enum ETFDividendProjection {
    enum Source: Equatable { case manual, recorded, projected, historicalAverage, inferred, none }

    /// 不按「分红型标的」处理的代码：不再计算任何年股息/股息率，本机旧存的推算与
    /// 已核实事件也会在 `refreshETFDividendEstimates` 里被清掉。
    ///
    /// - **159941 广发纳指 ETF**：公开分红档案没有现金派息记录；不把「指数成分股分红」
    ///   当作 ETF 给持有人的现金分红。
    /// - **159352 中证A500ETF南方**：基金合同只在「累计报酬率超过标的指数同期累计报酬率
    ///   达到 1% 以上」时才**可**分配，属不定期分配，不是红利型标的。事实层面它只在
    ///   2025-07-14 除息派过一次（每 10 份 0.11 元 = 0.011 元/份，合计 1.92 亿元，
    ///   深交所 2025-07-09 分红公告）。用户 2026-10-14 明确要求按「不分红」显示，
    ///   因此连那条历史事件也从 `verifiedEvents` 移除 —— **如需恢复，把下面那行加回去即可**。
    static let knownNonDividendCodes: Set<String> = ["159941", "159352"]

    /// 已核对公开分红档案的事件，用于旧设备/未导入网页分红缓存时先显示可追溯的历史基准。
    /// 金额均为每份；这些历史事件不是未来承诺。其余事件继续由本机数据或用户记录提供。
    static let verifiedEvents: [ETFDividendEvent] = [
        ETFDividendEvent(code: "515180", date: "2025-10-21", amountPerShare: 0.061),
        ETFDividendEvent(code: "563020", date: "2025-12-10", amountPerShare: 0.012),
        ETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: 0.012),
        ETFDividendEvent(code: "563020", date: "2026-09-11", amountPerShare: 0.012),
        ETFDividendEvent(code: "159545", date: "2025-11-12", amountPerShare: 0.010),
        ETFDividendEvent(code: "159545", date: "2026-02-11", amountPerShare: 0.015)
    ]

    /// `mergedEvents` 的缓存键与结果。
    ///
    /// 为什么必须有：自选页每一行、持仓页每一行、基金页每一行都会调它，
    /// 而它每次都要「建字典 + 排序」—— 一屏十几行就是十几次 O(N log N)。
    /// 滑动时每帧都重算，这正是「上下滑特别卡」的直接来源之一。
    /// 事件数组只在导入/刷新分红时才变，用「条数 + 推算条数 + 首末日期 + 金额合计」当键
    /// 就能可靠地判断「没变」，命中即直接返回上次的结果。
    private static var cachedMergedKey = ""
    private static var cachedMergedValue: [ETFDividendEvent] = []

    static func mergedEvents(_ events: [ETFDividendEvent]) -> [ETFDividendEvent] {
        var estimatedCount = 0
        var total = 0.0
        for event in events {
            if event.isEstimated == true { estimatedCount += 1 }
            total += event.amountPerShare
        }
        let key = "\(events.count)|\(estimatedCount)|\(events.first?.date ?? "")|\(events.last?.date ?? "")|\(total)"
        if key == cachedMergedKey { return cachedMergedValue }

        var values: [String: ETFDividendEvent] = [:]
        // Built-in verified rows are only fallbacks. Prefer a user's imported/confirmed row
        // for the same code and date so synchronization or a corrected announcement wins.
        for event in verifiedEvents + events {
            let eventKey = "\(event.code)|\(event.date)"
            if let old = values[eventKey], old.isEstimated != true && event.isEstimated == true { continue }
            values[eventKey] = event
        }
        let merged = values.values.sorted { $0.date == $1.date ? $0.code < $1.code : $0.date < $1.date }
        cachedMergedKey = key
        cachedMergedValue = merged
        return merged
    }

    /// 共享的上海时区日期格式化器。DateFormatter 建一次约毫秒级，
    /// 而年股息试算在自选列表里是「每行每次渲染」都会走的路径，必须复用。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// 截止日按自然日缓存：同一天内所有行共用同一个「近 12 个月」窗口，
    /// 跨天自动重算。比每行每次渲染都新建 Calendar + DateFormatter 便宜几个量级。
    private static var cachedCutoffDay = ""
    private static var cachedCutoffValue = ""

    /// 近 12 个月窗口的截止日（yyyy-MM-dd，含当天）。
    static func yearAgoCutoff(now: Date = .now) -> String {
        let today = dayFormatter.string(from: now)
        if today != cachedCutoffDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = dayFormatter.timeZone
            cachedCutoffValue = dayFormatter.string(
                from: calendar.date(byAdding: .day, value: -365, to: now) ?? .distantPast)
            cachedCutoffDay = today
        }
        return cachedCutoffValue
    }

    static func annualPerShare(for holding: Holding, events: [ETFDividendEvent], now: Date = .now)
        -> (amount: Double, source: Source)? {
        if let manual = holding.annualDividendPerShare, manual.isFinite, manual >= 0 {
            return (manual, .manual)
        }
        return projectedAnnualPerShare(for: holding, events: events, now: now)
    }

    /// 已核实的近 12 个月现金派息；不包含人工预测值，也不包含复权价格推算事件。
    static func recordedAnnualPerShare(for holding: Holding, events: [ETFDividendEvent], now: Date = .now)
        -> (amount: Double, source: Source)? {
        let cutoff = yearAgoCutoff(now: now)
        let today = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Asia/Shanghai") ?? .current, from: now)
        let todayKey = String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
        let hits = mergedEvents(events).filter {
            $0.code == holding.code && $0.date >= cutoff && $0.date <= todayKey && $0.isEstimated != true
        }
        let recorded = collapsingAnnualRepeat(hits).reduce(0) { $0 + $1.amountPerShare }
        if recorded > 0 { return (recorded, .recorded) }
        return nil
    }

    /// 近 12 个月「每份分红」，**按代码联网/按行情自动算出来**的口径。
    ///
    /// 与 `recordedAnnualPerShare` 的区别只有一个，但这一个是决定性的：
    /// 它把「前复权与不复权收盘价差推算出来的派息事件」（`inferredEvents`，`isEstimated == true`）
    /// 也计进去。写死的那张 `verifiedEvents` 表会过期 —— 用户实测 159545 就是这样：
    /// 表里只有 2026-02-11 的 0.015 和 2025-11-12 的 0.010（合计 0.025），
    /// 而前复权价差显示 2026-05-15 还有一次 0.014 没被记上，真实合计是 0.039。
    /// 按 1.29 的现价算，0.025 得 1.9%（= 用户看到的那个数），0.039 得 3.0%。
    ///
    /// `mergedEvents` 已经按 `代码|日期` 去重且**已核实记录优先**，所以同一天的推算事件
    /// 不会和已核实记录重复计数；只有本机完全没有记录的那些派息才会被补进来。
    static func twelveMonthPerShare(forCode code: String, events: [ETFDividendEvent], now: Date = .now)
        -> (amount: Double, includesEstimate: Bool, count: Int, estimatedCount: Int, collapsedRepeat: Bool) {
        let cutoff = yearAgoCutoff(now: now)
        let today = dayFormatter.string(from: now)
        var hits: [ETFDividendEvent] = []
        for event in mergedEvents(events) {
            guard event.code == code, event.date >= cutoff, event.date <= today else { continue }
            guard event.amountPerShare.isFinite, event.amountPerShare > 0 else { continue }
            hits.append(event)
        }
        let kept = collapsingAnnualRepeat(hits)
        var total = 0.0
        var estimatedCount = 0
        for event in kept {
            total += event.amountPerShare
            if event.isEstimated == true { estimatedCount += 1 }
        }
        return (total, estimatedCount > 0, kept.count, estimatedCount, kept.count != hits.count)
    }

    /// 把「一年派一次」的标的在除息日前后被窗口同时装进来的两次年度派息折叠成一次。
    ///
    /// **为什么需要**：窗口是滚动的 `[今天 − 365 天, 今天]`。只要今年除息日**早于**
    /// 「去年除息日 + 365 天」，就会有一小段日子同时含「去年那次」和「今年这次」——
    /// 实测 515180（红利ETF易方达，每年 10 月除息一次）2026-10-16 除息当天：
    /// 10-15 还是 4.20%（窗口里 1 次 0.061），10-16 起变成 8.40%（窗口里 2 次 0.122），
    /// 10-22 去年那次掉出窗口又回落 —— 用户会以为「股息被谁改高了」。
    ///
    /// **判据用平均间隔、不用相邻两次的间隔**：一年派一次的节奏平均间隔 ≈ 360 天；
    /// 一年派 2~4 次的（563020 / 159545）只有 90~185 天。阈值 300 天正落在两者中间，
    /// 既切得开跨年度重复，又不会把真正的多次派息标的误伤成一次。
    /// 窗口只有 365 天，所以 3 条以上事件的平均间隔必然 < 183 天，实际只有「2 条」会被折叠。
    private static func collapsingAnnualRepeat(_ events: [ETFDividendEvent]) -> [ETFDividendEvent] {
        guard events.count >= 2 else { return events }
        let sorted = events.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last,
              let start = dayFormatter.date(from: first.date),
              let end = dayFormatter.date(from: last.date) else { return events }
        let averageGapDays = end.timeIntervalSince(start) / Double(sorted.count - 1) / 86_400
        guard averageGapDays >= 300 else { return events }
        return [last]
    }

    /// 未来 12 个月的保守试算：优先使用人工核实值；否则沿用近 12 个月
    /// 已核实现金派息总额。它只是历史节奏外推，不把指数股息率当成 ETF 派息。
    static func projectedAnnualPerShare(for holding: Holding, events: [ETFDividendEvent], now: Date = .now)
        -> (amount: Double, source: Source)? {
        if let manual = holding.annualDividendPerShare, manual.isFinite, manual >= 0 {
            return (manual, .manual)
        }
        if knownNonDividendCodes.contains(holding.code) { return (0, .none) }
        if let actual = recordedAnnualPerShare(for: holding, events: events, now: now), actual.amount > 0 {
            return (actual.amount, .projected)
        }
        // 若最近 12 个月没有派息，但近三年存在已核实的分红，按“有派息的年份”平均，
        // 保留低频派息 ETF 的可用试算；一年仅派一次的标的不会因为刚过周年日瞬间归零。
        let cutoff3y: String = {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = dayFormatter.timeZone
            let date = calendar.date(byAdding: .year, value: -3, to: now) ?? .distantPast
            return dayFormatter.string(from: date)
        }()
        let recent = mergedEvents(events).filter {
            $0.code == holding.code && $0.isEstimated != true && $0.date >= cutoff3y
                && $0.date <= dayFormatter.string(from: now)
        }
        if !recent.isEmpty {
            let totalsByYear = Dictionary(grouping: recent, by: { String($0.date.prefix(4)) })
                .mapValues { $0.reduce(0) { $0 + $1.amountPerShare } }
            // 单次历史派息只进入历史事件，不足以证明形成年度现金流；至少有两个派息年度
            // 才给年化试算，避免把「历史只派过一次息」的标的包装成稳定年股息。
            if totalsByYear.count >= 2 {
                let amount = totalsByYear.values.reduce(0, +) / Double(totalsByYear.count)
                if amount.isFinite, amount > 0 { return (amount, .historicalAverage) }
            }
        }
        let cutoff = yearAgoCutoff(now: now)
        let today = dayFormatter.string(from: now)
        let inferred = mergedEvents(events).filter {
            $0.code == holding.code && $0.date >= cutoff && $0.date <= today && $0.isEstimated == true
        }.reduce(0) { $0 + $1.amountPerShare }
        return inferred > 0 ? (inferred, .inferred) : nil
    }

    /// Match the web estimator: compare raw close / forward-adjusted close factors,
    /// detect downward factor steps, and combine events within eight calendar days.
    /// This is a quote-derived estimate, never proof of a cash distribution.
    static func inferredEvents(code: String, adjusted: [DailyBar], raw: [DailyBar]) -> [ETFDividendEvent] {
        guard adjusted.count >= 60, raw.count >= 60 else { return [] }
        let rawClose = Dictionary(raw.map { ($0.date, $0.close) }, uniquingKeysWith: { _, newer in newer })
        var factorByDay: [(day: String, factor: Double, adjustedClose: Double)] = []
        for bar in adjusted {
            guard let rawValue = rawClose[bar.date], rawValue > 0, bar.close > 0 else { continue }
            factorByDay.append((bar.date, rawValue / bar.close, bar.close))
        }
        guard factorByDay.count >= 2 else { return [] }
        var candidates: [(String, Double)] = []
        for index in 1..<factorByDay.count {
            let before = factorByDay[index - 1], after = factorByDay[index]
            let move = after.factor / before.factor - 1
            let amount = (before.factor - after.factor) * after.adjustedClose
            if move < -0.0025 && amount >= 0.003 && amount.isFinite {
                candidates.append((after.day, amount))
            }
        }
        guard !candidates.isEmpty else { return [] }
        var merged: [(String, Double)] = []
        for candidate in candidates {
            if let last = merged.last, let a = dayFormatter.date(from: last.0),
               let b = dayFormatter.date(from: candidate.0), b.timeIntervalSince(a) <= 8 * 86_400 {
                merged[merged.count - 1] = (candidate.0, last.1 + candidate.1)
            } else { merged.append(candidate) }
        }
        return merged.map { ETFDividendEvent(code: code, date: $0.0, amountPerShare: $0.1, isEstimated: true) }
    }
}

struct AllocationTarget: Codable, Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    var code: String
    var name: String
    var kind: Holding.Kind
    var targetPercent: Double
}

enum AppAppearance: String, Codable {
    case system, dark, oled, light, blue, green, purple, sakura, cyber, amber, paper, mint, coffee, graphite
}
enum CostAccountingMode: String, Codable { case weightedAverage, diluted }
enum DailyPnLMode: String, Codable, CaseIterable, Identifiable {
    case float, pnl, today, open, ths, old
    var id: String { rawValue }
    var title: String {
        switch self {
        case .float: return "纯持仓浮动"
        case .pnl: return "含当日卖出已实现（默认）"
        case .today: return "含当日全部交易"
        case .open: return "按开盘初始份额"
        case .ths: return "同花顺成交额口径"
        case .old: return "近似口径"
        }
    }
}
enum IntradayLineColorMode: String, Codable { case automatic, white, black, upDown }

struct InvestmentProfile: Codable {
    var style = "swing"
    var risk = "bal"
    var maxPositionPercent = 35.0
    var horizon = "1-3个月"
    var premiumSensitive = true
    var preference = ""
    var avoid = ""
    var method = ""
    var goal = ""

    private enum CodingKeys: String, CodingKey { case style, risk, maxPositionPercent, horizon, premiumSensitive, preference, avoid, method, goal }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "swing"
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? "bal"
        let decodedMaxPosition = try c.decodeIfPresent(Double.self, forKey: .maxPositionPercent)
        maxPositionPercent = decodedMaxPosition ?? 35
        horizon = try c.decodeIfPresent(String.self, forKey: .horizon) ?? "1-3个月"
        let decodedPremium = try c.decodeIfPresent(Bool.self, forKey: .premiumSensitive)
        premiumSensitive = decodedPremium ?? true
        preference = try c.decodeIfPresent(String.self, forKey: .preference) ?? ""
        avoid = try c.decodeIfPresent(String.self, forKey: .avoid) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
    }
}

struct TradePlan: Codable, Identifiable {
    enum Status: String, Codable { case planned, reviewed, cancelled }
    var id: String
    var kind: Holding.Kind
    var code: String
    var name: String
    var side: LedgerEntry.Side
    var amount: Double
    var price: Double
    var target: Double?
    var invalid: Double?
    var reason: String
    var trigger: String
    var reviewDate: String
    var created: String
    var status: Status
    var actualPrice: Double?
    var actualAmount: Double?
    var review: String
}

struct PortfolioSnapshot: Codable, Identifiable {
    enum Quality: String, Codable { case provisional, settled, reconstructed, manual }
    var id: String { date }
    var date: String
    var total: Double
    var cash: Double
    var recordedAt: Date? = nil
    var quality: Quality? = nil
    var note: String? = nil
}

struct CashFlow: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    /// Positive is money added to the tracked account; negative is withdrawn.
    var amount: Double
    var memo: String
    /// False denotes an external investment booked into holdings without changing reference cash.
    var affectsCash: Bool? = true
    /// Whether the flow is external to the tracked portfolio for return adjustment.
    /// Nil preserves the legacy behavior and is interpreted as true.
    var external: Bool? = true
}

struct FundNAVPoint: Codable, Identifiable {
    var id: String { "\(code)-\(date)" }
    var code: String
    var date: String
    var nav: Double
    /// 这份净值是什么时候取到本机的。
    ///
    /// **为什么需要它**：场内基金当晚发布当天净值，净值日 = 当天；美股 / QDII 等境外市场
    /// 基金净值日天然晚一个交易日（美股周六日、节假日休盘，但净值随后照样公布），
    /// 净值日 ≠ 当天。所以「今天有没有更新过」只能看采集时间，不能看净值日期是不是今天。
    /// 旧存档 / 导入数据没有这个字段时为 nil；只有成功刷新时确认的新净值才会补记采集时间，
    /// 避免旧净值仅因日期匹配而被重复算入今天。
    var fetchedAt: Date? = nil
    /// NAV movement per share against the prior valuation point; receipt time is provenance,
    /// while `date` is the economic day to which this movement belongs.
    var observedDelta: Double? = nil
}

struct FundTransaction: Codable, Identifiable {
    enum Side: String, Codable { case buy, sell, dividend }
    enum Status: String, Codable { case confirmed, pending }
    enum DividendMode: String, Codable { case cash, reinvest }

    var id: UUID = UUID()
    var code: String
    var name: String
    var side: Side
    var requestDate: String
    var effectiveDate: String
    var quantity: Double
    var nav: Double
    var amount: Double
    var fee: Double
    var realizedPnL: Double
    var status: Status
    var isBackfill: Bool
    var dividendMode: DividendMode?
    var linkedCash: Bool
    var isAutomaticDCA: Bool? = nil
    var dcaPlanID: UUID? = nil
    var legacyPlanID: String? = nil
    var legacyPlanDue: String? = nil
    var redemptionLots: [FundLotRedemption]? = nil
    /// True while a confirmed redemption fee remains an estimate awaiting platform confirmation.
    var feeWasEstimated: Bool? = nil
}

struct FundConstituent: Codable, Identifiable {
    var code: String
    var name: String
    var weightPercent: Double
    var marketCode: String
    var id: String { code }
}

struct FundConstituentSnapshot: Codable, Identifiable {
    var code: String
    var name: String
    var asOf: String
    var fetchedAt: Date = .now
    var holdings: [FundConstituent]
    var id: String { code }
}

struct FundFeeBand: Codable, Identifiable {
    var id: UUID = UUID()
    var minimumHoldingDays: Int
    var ratePercent: Double
}

struct FundFeePolicy: Codable, Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var bands: [FundFeeBand]
    // Nil means FIFO for policies saved by older native versions.
    var sellMode: FundSellMode? = nil
}

enum FundSellMode: String, Codable, CaseIterable, Identifiable {
    case fifo, lifo, lowestFee
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fifo: return "先进先出"
        case .lifo: return "后进先出"
        case .lowestFee: return "优先低费率"
        }
    }
}

struct FundLotRedemption: Codable {
    var purchaseDate: String
    var shares: Double
}

struct FundFeeEstimate {
    var total: Double
    var parts: [(purchaseDate: String, days: Int, shares: Double, ratePercent: Double, fee: Double)]
    var redemptionLots: [FundLotRedemption]
}

struct FundDCAPlan: Codable, Identifiable {
    enum Frequency: String, Codable { case daily, weekly, biweekly, monthly }
    var id: UUID = UUID()
    var code: String
    var name: String
    var amount: Double
    /// Fraction of the planned cash amount; nil on an older native backup means 0.15%.
    var feeRate: Double? = nil
    var frequency: Frequency
    /// Calendar weekday: Sunday = 1 ... Saturday = 7.
    var weekday: Int
    /// Day of month, limited to 1...28 so the date always exists.
    var monthDay: Int
    var startDate: String
    var enabled: Bool
    var processedDates: [String]
}

struct FundDailyPerformance: Identifiable {
    var id: String { date }
    var date: String
    var profit: Double
    var baseValue: Double
    var fundCount: Int
    var contributions: [FundDailyContribution] = []
}

struct FundDailyContribution: Identifiable {
    var id: String { code }
    var code: String
    var name: String
    var profit: Double
    var baseValue: Double
}

/// Locally captured or imported one-minute observations. These are market data,
/// never portfolio transactions. `day` uses Asia/Shanghai calendar dates.
struct IntradayBar: Codable, Identifiable, Sendable {
    var id: String { "\(code)-\(timestamp.timeIntervalSince1970)" }
    var code: String
    var timestamp: Date
    var price: Double
    var volume: Double?
    var day: String
    /// ETF 实时参考净值（IOPV）；缺数据时保持 nil，不用估算伪造历史曲线。
    var iopv: Double? = nil
}

/// Tencent daily adjusted K-line observation. Historical market data only.
struct DailyBar: Codable, Identifiable {
    var id: String { "\(code)-\(date)" }
    var code: String
    var date: String
    var open: Double
    var close: Double
    var high: Double
    var low: Double
    var volume: Double
    /// 成交额（元）。只有东财日 K 直接给这一列，腾讯日 K 没有 —— 缺数据时为 nil，
    /// 界面按「成交量 × 100 × 收盘价」估算并标注「估算」，不把估算值当成真实成交额。
    /// 用可选类型是为了让老备份 / 老缓存（没有这个键）仍能正常解码。
    var amount: Double? = nil
}

struct DayGridPlan: Codable, Identifiable {
    var id: UUID = UUID()
    var code: String
    var name: String
    var capital: Double
    var anchor: Double
    var stepPercent: Double
    var levelsEachSide: Int
    var feePerOrder: Double
    var enabled: Bool
    var legacyRecordID: String? = nil
}


struct GridReplayResult: Identifiable {
    var id: UUID = UUID()
    var code: String
    var day: String
    var fills: Int
    var buyCount: Int
    var sellCount: Int
    var startCapital: Double
    var endingValue: Double
    var fees: Double
    var coverage: Double
    var profit: Double { endingValue - startCapital }
}

// MARK: - 复盘并寻找当日最优（移植自网页版 gridTradeReplayOptimize）

/// 一组网格参数的模拟结果（网页版 item 的对应物）。
///
/// 关键字段是 `alpha`：**网格盈亏 − 同期「买了就不动」的盈亏**。
/// 单边上涨的日子里，随便一组参数都能比本金赚得多 —— 只有减掉「躺着不动」那份，
/// 剩下的才是网格真正多挣出来的钱，所以胜负按 alpha 判，而不是按 `profit`。
struct GridOptimizeCandidate: Identifiable {
    var id: UUID = UUID()
    /// 起始锚点：首价 / 前 15 点均价 / 当日中位价，三选一。
    var anchor: Double
    /// 走完当天后锚点停在哪（动态网格会跟着成交价移动）。
    var finalAnchor: Double
    /// 格距（元）
    var step: Double
    /// 格距占首价的百分比
    var stepPercent: Double
    /// 每格股数 / 份数
    var quantity: Double
    var buyCount: Int
    var sellCount: Int
    var fills: Int
    /// 费用合计（佣金 + 滑点）
    var fees: Double
    var commissionCost: Double
    var slippageCost: Double
    /// 期末权益 − 本金
    var profit: Double
    /// 初始份额「买了不动」的盈亏
    var holdProfit: Double
    /// 网格相对「买了不动」多挣的部分，用于排名
    var alpha: Double
    /// 按权益曲线算的最大回撤（%）
    var maxDrawdown: Double
    var endingEquity: Double
}

/// 一次「复盘并寻找当日最优」的完整报告。
struct GridOptimizeReport: Identifiable {
    var id: UUID = UUID()
    var code: String
    var name: String
    var day: String
    var capital: Double
    var t0: Bool
    /// 最小价位变动（ETF 0.001 / 个股 0.01）
    var tick: Double
    var dayLow: Double
    var dayHigh: Double
    var firstPrice: Double
    var lastPrice: Double
    /// 参与回放的有效分钟点数
    var points: Int
    var best: GridOptimizeCandidate
    /// 全部候选（3 个锚点 × 7 个步长倍率，去重后可能少于 21 组）
    var candidates: [GridOptimizeCandidate]
    var note: String
}

/// 「按区间复盘」里的一组候选参数：**一个格距百分比，跑遍区间内全部有分时档案的交易日**。
///
/// 这是「找一组长期能用的网格参数」的最小单元。与单日复盘的区别在于：
/// 单日只问「这一天事后最优是什么」，区间会问「同一组参数在这些天里平均表现如何」——
/// 后者才有资格指导以后的操作。逐日判定口径与单日复盘完全一致（同一套 `alpha`）。
struct GridRangeCandidate: Codable, Identifiable, Hashable {
    /// 用格距百分比本身当 id：同一区间内不会有两组相同百分比。
    var id: Double { stepPercent }
    /// 格距占**当日首价**的百分比（区间内每日各自换算成绝对格距）。
    var stepPercent: Double
    /// 真正跑成功的交易日数（分时点不足或资金不够的日子不计入）
    var samples: Int
    /// `alpha > 0` 的天数 —— 「跑赢持有不动」的天数
    var winDays: Int
    var totalAlpha: Double
    var averageAlpha: Double
    var totalProfit: Double
    var totalHoldProfit: Double
    var totalFees: Double
    /// 区间内最差一天的 alpha
    var worstAlpha: Double
    /// 区间内单日最大回撤的最大值（%）
    var worstDrawdown: Double
    /// 平均每日成交笔数
    var averageFills: Double
    /// 最近一个交易日按该格距换算出的**绝对格距**（填券商单子时用这个数）
    var lastStep: Double
    /// 最近一个交易日、按计划资金算出的每格份数
    var lastQuantity: Double
    var lastStepPercent: Double

    var winRate: Double { samples > 0 ? Double(winDays) / Double(samples) * 100 : 0 }
}

/// 区间复盘里某一天的逐日明细（只保留最终胜出那组参数的结果）。
struct GridRangeDayDetail: Codable, Identifiable, Hashable {
    var id: String { day }
    var day: String
    var points: Int
    var firstPrice: Double
    var lastPrice: Double
    var dayLow: Double
    var dayHigh: Double
    var step: Double
    var buyCount: Int
    var sellCount: Int
    var fills: Int
    var profit: Double
    var holdProfit: Double
    var alpha: Double
    var maxDrawdown: Double
    var fees: Double
}

/// 一次「按区间复盘」的完整报告。
///
/// ⚠️ 依然是**事后拟合**：用的是已经走完的完整分时。它的价值不在于预测，
/// 而在于把「这个标的过去 N 天里，多大的格距最经得起折腾」用同一把尺子量出来。
struct GridRangeReport: Codable, Identifiable, Hashable {
    var id: String { "\(code)|\(from)|\(to)" }
    var code: String
    var name: String
    var from: String
    var to: String
    var capital: Double
    var t0: Bool
    var tick: Double
    /// 真正参与统计的交易日（正序）
    var days: [String]
    /// 档案里在区间内、但因为分时点不足 30 个而被跳过的交易日
    var skippedDays: [String]
    var totalPoints: Int
    var rangeLow: Double
    var rangeHigh: Double
    /// 区间内「第一日首价 → 最后一日末价」的变化百分比
    var rangeChangePercent: Double
    /// 日均振幅（每日最高/最低的百分比振幅，取平均）
    var averageAmplitudePercent: Double
    var best: GridRangeCandidate
    var candidates: [GridRangeCandidate]
    /// 胜出那组的逐日明细
    var details: [GridRangeDayDetail]
    var note: String
}

/// 策略经验累积（网页版 `DB.gridExperience` 的对应物）。
struct GridExperienceRecord: Codable {
    var samples = 0
    var wins = 0
    var alphaSum = 0.0
    var stepPercentSamples: [Double] = []

    var averageAlpha: Double { samples > 0 ? alphaSum / Double(samples) : 0 }

    var winRate: Double { samples > 0 ? Double(wins) / Double(samples) * 100 : 0 }

    var medianStepPercent: Double {
        guard !stepPercentSamples.isEmpty else { return 0 }
        let sorted = stepPercentSamples.sorted()
        return sorted[sorted.count / 2]
    }
}

struct GridRecommendation {
    var anchor: Double
    var stepPercent: Double
    var levels: Int
    var score: Int
    var daysUsed: Int
    var medianDailyRangePercent: Double
    var summary: String
}

struct AIAnalysisConfig: Codable {
    var endpoint = "https://api.deepseek.com"
    var model = "deepseek-flash"
    var timeoutSeconds = 45
    var systemPrompt = "你是一个谨慎但有判断力的投资研究助手。结合用户真实持仓、成本、仓位约束与投资期限，给出有条件、可执行的下一步计划和失效条件；不要逐项复述指标。只依据输入，区分事实和推断，说明数据缺口，不编造外部消息，不承诺收益，不自动交易。"

    private enum CodingKeys: String, CodingKey { case endpoint, model, timeoutSeconds, systemPrompt }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? "https://api.deepseek.com"
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-flash"
        // DeepSeek 已停用旧的 deepseek-chat / deepseek-reasoner 名称。
        // 旧备份自动迁到当前官方模型，避免升级后分析按钮直接返回“模型不存在”。
        switch decodedModel {
        case "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash":
            model = decodedModel == "deepseek-v4-flash" ? "deepseek-flash" : "deepseek-v4-pro"
        default:
            model = decodedModel
        }
        timeoutSeconds = min(180, max(5, try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 45))
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? "你是一个谨慎但有判断力的投资研究助手。结合用户真实持仓、成本、仓位约束与投资期限，给出有条件、可执行的下一步计划和失效条件；不要逐项复述指标。只依据输入，区分事实和推断，说明数据缺口，不编造外部消息，不承诺收益，不自动交易。"
    }
}

/// 最近一次成功的大模型结果。失败的重试不会覆盖它；下一次成功后才替换。
struct SavedAIAnalysis: Codable {
    var text: String
    var updatedAt: Date = .now
}

struct LedgerEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    var code: String
    var name: String
    var side: Side
    var quantity: Double
    var price: Double
    var fee: Double
    var realizedPnL: Double
    var linkedCash: Bool
    // Optional so backups created before asset-kind tagging remain readable.
    var kind: Holding.Kind? = nil
    // False for imported history that was added without changing current balances.
    var affectsHoldings: Bool? = nil

    enum Side: String, Codable { case buy, sell }
    var gross: Double { quantity * price }
}

struct OperationAuditRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = .now
    var label: String
    /// Full pre-operation portfolio state, excluding separately stored chart caches.
    var state: Data
}

struct PortfolioData: Codable {
    var quotes: [Quote] = []
    var quoteAlerts: [QuoteAlert] = []
    var intradayCompanionIntents: [IntradayCompanionIntent] = []
    var manualQuoteOverrides: [String: ManualQuoteOverride] = [:]
    var etfDividendEvents: [ETFDividendEvent] = []
    var holdings: [Holding] = []
    var allocationTargets: [AllocationTarget] = []
    var snapshots: [PortfolioSnapshot] = []
    var cashFlows: [CashFlow] = []
    var fundNAVHistory: [FundNAVPoint] = []
    var fundTransactions: [FundTransaction] = []
    var fundConstituentSnapshots: [FundConstituentSnapshot] = []
    var fundFeePolicies: [FundFeePolicy] = []
    var fundDCAPlans: [FundDCAPlan] = []
    var dayGridPlans: [DayGridPlan] = []
    var aiAnalysisConfig = AIAnalysisConfig()
    var savedAccountAIAnalysis: SavedAIAnalysis?
    var savedPortraitAIAnalysis: SavedAIAnalysis?
    var savedInstrumentAIAnalyses: [String: SavedAIAnalysis] = [:]
    var ledger: [LedgerEntry] = []
    var cash: Double = 0
    var cashLinkedByDefault = false
    var appearance: AppAppearance = .system
    var quoteRefreshSeconds = 60
    var dailyPnLMode: DailyPnLMode = .pnl
    var intradaySubchartMode = "macd"
    // 仅保留用于读取旧备份；新版界面不再提供固定日数，K 线由手势自由缩放。
    var dailyChartRangeDays = 120
    var intradayLineColorMode: IntradayLineColorMode = .automatic
    var intradayCaptureEnabled = true
    var automaticFundNAVRefreshEnabled = false
    var costAccountingMode: CostAccountingMode = .diluted
    var globalPositionLimitPercent = 0.0
    var positionHintsEnabled = true
    var rebalanceAlertThreshold = 5
    var investmentProfile = InvestmentProfile()
    var tradePlans: [TradePlan] = []
    /// User-maintained exchange closure dates (YYYY-MM-DD); synced with the portfolio.
    var customMarketHolidays: [String] = []
    /// 自定义强调色名（空串 = 跟随主题自带强调色）。
    var accentColorName = ""
    /// 按时间自动切换深浅：空串 = 关闭；"sun" = 日出日落；否则为 "HH:mm-HH:mm" 深色时段。
    var autoThemeSchedule = ""

    private enum CodingKeys: String, CodingKey {
        case quotes, quoteAlerts, intradayCompanionIntents, manualQuoteOverrides, etfDividendEvents, holdings, allocationTargets, snapshots, cashFlows, fundNAVHistory, fundTransactions, fundConstituentSnapshots, fundFeePolicies, fundDCAPlans, dayGridPlans, aiAnalysisConfig, savedAccountAIAnalysis, savedPortraitAIAnalysis, savedInstrumentAIAnalyses, ledger, cash, cashLinkedByDefault, appearance, quoteRefreshSeconds, dailyPnLMode, intradaySubchartMode, dailyChartRangeDays, intradayLineColorMode, intradayCaptureEnabled, automaticFundNAVRefreshEnabled, costAccountingMode, globalPositionLimitPercent, positionHintsEnabled, rebalanceAlertThreshold, investmentProfile, tradePlans, customMarketHolidays, accentColorName, autoThemeSchedule
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotes = try c.decodeIfPresent([Quote].self, forKey: .quotes) ?? []
        quoteAlerts = try c.decodeIfPresent([QuoteAlert].self, forKey: .quoteAlerts) ?? []
        intradayCompanionIntents = try c.decodeIfPresent([IntradayCompanionIntent].self, forKey: .intradayCompanionIntents) ?? []
        manualQuoteOverrides = try c.decodeIfPresent([String: ManualQuoteOverride].self, forKey: .manualQuoteOverrides) ?? [:]
        etfDividendEvents = try c.decodeIfPresent([ETFDividendEvent].self, forKey: .etfDividendEvents) ?? []
        holdings = try c.decodeIfPresent([Holding].self, forKey: .holdings) ?? []
        allocationTargets = try c.decodeIfPresent([AllocationTarget].self, forKey: .allocationTargets) ?? []
        snapshots = try c.decodeIfPresent([PortfolioSnapshot].self, forKey: .snapshots) ?? []
        cashFlows = try c.decodeIfPresent([CashFlow].self, forKey: .cashFlows) ?? []
        fundNAVHistory = try c.decodeIfPresent([FundNAVPoint].self, forKey: .fundNAVHistory) ?? []
        fundTransactions = try c.decodeIfPresent([FundTransaction].self, forKey: .fundTransactions) ?? []
        fundConstituentSnapshots = try c.decodeIfPresent([FundConstituentSnapshot].self, forKey: .fundConstituentSnapshots) ?? []
        fundFeePolicies = try c.decodeIfPresent([FundFeePolicy].self, forKey: .fundFeePolicies) ?? []
        fundDCAPlans = try c.decodeIfPresent([FundDCAPlan].self, forKey: .fundDCAPlans) ?? []
        dayGridPlans = try c.decodeIfPresent([DayGridPlan].self, forKey: .dayGridPlans) ?? []
        aiAnalysisConfig = try c.decodeIfPresent(AIAnalysisConfig.self, forKey: .aiAnalysisConfig) ?? AIAnalysisConfig()
        savedAccountAIAnalysis = try c.decodeIfPresent(SavedAIAnalysis.self, forKey: .savedAccountAIAnalysis)
        savedPortraitAIAnalysis = try c.decodeIfPresent(SavedAIAnalysis.self, forKey: .savedPortraitAIAnalysis)
        savedInstrumentAIAnalyses = try c.decodeIfPresent([String: SavedAIAnalysis].self, forKey: .savedInstrumentAIAnalyses) ?? [:]
        ledger = try c.decodeIfPresent([LedgerEntry].self, forKey: .ledger) ?? []
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        cashLinkedByDefault = try c.decodeIfPresent(Bool.self, forKey: .cashLinkedByDefault) ?? false
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        accentColorName = try c.decodeIfPresent(String.self, forKey: .accentColorName) ?? ""
        autoThemeSchedule = try c.decodeIfPresent(String.self, forKey: .autoThemeSchedule) ?? ""
        quoteRefreshSeconds = min(600, max(0, try c.decodeIfPresent(Int.self, forKey: .quoteRefreshSeconds) ?? 60))
        dailyPnLMode = try c.decodeIfPresent(DailyPnLMode.self, forKey: .dailyPnLMode) ?? .pnl
        let subchart = try c.decodeIfPresent(String.self, forKey: .intradaySubchartMode) ?? "macd"
        intradaySubchartMode = ["macd", "volume"].contains(subchart) ? subchart : "macd"
        let chartRange = try c.decodeIfPresent(Int.self, forKey: .dailyChartRangeDays) ?? 250
        dailyChartRangeDays = [60, 120, 250, 640].min(by: { abs($0 - chartRange) < abs($1 - chartRange) }) ?? 250
        intradayLineColorMode = try c.decodeIfPresent(IntradayLineColorMode.self, forKey: .intradayLineColorMode) ?? .automatic
        intradayCaptureEnabled = try c.decodeIfPresent(Bool.self, forKey: .intradayCaptureEnabled) ?? true
        automaticFundNAVRefreshEnabled = try c.decodeIfPresent(Bool.self, forKey: .automaticFundNAVRefreshEnabled) ?? false
        costAccountingMode = try c.decodeIfPresent(CostAccountingMode.self, forKey: .costAccountingMode) ?? .diluted
        globalPositionLimitPercent = min(100, max(0, try c.decodeIfPresent(Double.self, forKey: .globalPositionLimitPercent) ?? 0))
        positionHintsEnabled = try c.decodeIfPresent(Bool.self, forKey: .positionHintsEnabled) ?? true
        rebalanceAlertThreshold = min(20, max(1, try c.decodeIfPresent(Int.self, forKey: .rebalanceAlertThreshold) ?? 5))
        investmentProfile = try c.decodeIfPresent(InvestmentProfile.self, forKey: .investmentProfile) ?? InvestmentProfile()
        tradePlans = try c.decodeIfPresent([TradePlan].self, forKey: .tradePlans) ?? []
        customMarketHolidays = Array(Set(try c.decodeIfPresent([String].self, forKey: .customMarketHolidays) ?? [])).sorted()
    }
}
