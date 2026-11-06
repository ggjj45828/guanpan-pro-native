import Foundation

// MARK: - 持仓周期（Episode）
//
// 一个问题：这只标的我一共拿了几轮？每轮拿了多少天、赚了多少、成本是多少？
//
// Pro 原来只有「当前持仓」这一层，卖出之后那一段就消失了 —— 页面上只剩一条
// 已实现盈亏数字，看不出它是几轮交易累积的。观盘 max 用 episode 把这个问题
// 拆开：一次**清零到清零**（或起点到清零）为一个周期，下一笔买入重新开一轮。
//
// 口径说明（必须写进代码，否则以后自己都会算错）：
// · 起点快照里的持仓算作第 1 轮，`historyComplete = false` —— 我们不知道它是
//   什么时候建的仓，也不假装知道；日历天数从起点快照的时刻开始算，界面上标出来。
// · 成本用**加权平均**递推，与 `recordTrade` 完全一致：卖出时按当时单位成本
//   移除成本，不改变剩余份额的单位成本。
// · 红利再投算作一次「零现金买入」（份额加、成本加），因为它确实增加了持仓成本。
// · 同一笔基金交易在 `ledger` 和 `fundTransactions` 里各有一份，这里按
//   代码 + 方向 + 日期 + 份额 + 净值去重，绝不重复计一次买入。
// · 导入的历史流水（`affectsHoldings == false`）不参与 —— 它们的效果已经在
//   起点快照里了，再算一遍等于把同一批份额买两次。

struct EpisodeFill: Identifiable {
    let id: UUID
    let date: Date
    let code: String
    let name: String
    let kind: Holding.Kind
    let side: LedgerEntry.Side
    let quantity: Double
    let price: Double
    let fee: Double
    /// 红利再投：份额增加但没有现金支出。
    let isReinvest: Bool

    var gross: Double { quantity * price }
}

struct EpisodeTrade: Identifiable {
    let id: UUID
    let date: Date
    let side: LedgerEntry.Side
    let quantity: Double
    let price: Double
    let fee: Double
    /// 卖出这次落袋的钱（已扣费用、已扣成本），买入恒为 0。
    let realized: Double
    let isReinvest: Bool

    var gross: Double { quantity * price }
}

struct PositionEpisode: Identifiable {
    var id: String { "\(kind.rawValue)|\(code)#\(number)" }
    let code: String
    let name: String
    let kind: Holding.Kind
    let number: Int
    /// nil = 起点快照之前就持有，建仓时间未知。
    let openedAt: Date?
    var closedAt: Date?
    var currentUnits: Double
    /// 剩余份额的账面成本总额（不是单价）。
    var bookCost: Double
    /// 这一轮累计投进去的钱：起点成本 + 历次买入成交额（含费用）。
    var invested: Double
    var realized: Double
    var fees: Double
    var trades: [EpisodeTrade]
    /// false 表示这一轮的买入记录不完整（来自起点快照）。
    let historyComplete: Bool

    var isActive: Bool { closedAt == nil && currentUnits > 0.000001 }
    var averageCost: Double { currentUnits > 0.000001 ? bookCost / currentUnits : 0 }

    func days(asOf now: Date = .now) -> Int? {
        guard let openedAt else { return nil }
        let end = closedAt ?? now
        let seconds = end.timeIntervalSince(openedAt)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return max(0, Int(seconds / 86_400))
    }

    func unrealized(currentPrice: Double) -> Double? {
        guard isActive, currentPrice > 0 else { return nil }
        return currentUnits * currentPrice - bookCost
    }

    /// 这一轮的总战果：已实现 + 当前浮动。
    func total(currentPrice: Double) -> Double {
        realized + (unrealized(currentPrice: currentPrice) ?? 0)
    }

    /// 总战果 ÷ 累计投入。投入为 0（纯起点、成本未记录）时返回 nil，不给假百分比。
    func returnRate(currentPrice: Double) -> Double? {
        guard invested > 0.005 else { return nil }
        return total(currentPrice: currentPrice) / invested
    }

    var buyCount: Int { trades.filter { $0.side == .buy }.count }
    var sellCount: Int { trades.filter { $0.side == .sell }.count }
}

struct InstrumentEpisodes: Identifiable {
    var id: String { "\(kind.rawValue)|\(code)" }
    let code: String
    let name: String
    let kind: Holding.Kind
    let episodes: [PositionEpisode]
    let currentPrice: Double
    let currentUnits: Double

    var activeEpisode: PositionEpisode? { episodes.last(where: { $0.isActive }) }
    var closedEpisodes: [PositionEpisode] { episodes.filter { $0.closedAt != nil } }
    var lifetimeRealized: Double { episodes.reduce(0) { $0 + $1.realized } }
    var lifetimeFees: Double { episodes.reduce(0) { $0 + $1.fees } }
    var lifetimeInvested: Double { episodes.reduce(0) { $0 + $1.invested } }

    var wins: Int { closedEpisodes.filter { $0.realized > 0.01 }.count }
    var losses: Int { closedEpisodes.filter { $0.realized < -0.01 }.count }
    var winRate: Double? {
        let resolved = wins + losses
        return resolved > 0 ? Double(wins) / Double(resolved) : nil
    }
    var averageClosedDays: Double? {
        let values = closedEpisodes.compactMap { $0.days() }
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
    /// 已了结周期里最赚和最亏的那一轮，用来说明「赢在哪一轮」。
    var bestEpisode: PositionEpisode? { closedEpisodes.max { $0.realized < $1.realized } }
    var worstEpisode: PositionEpisode? { closedEpisodes.min { $0.realized < $1.realized } }
}

// MARK: - 投影

enum EpisodeProjection {

    struct Result {
        var instruments: [InstrumentEpisodes] = []
        var warnings: [String] = []
    }

    static func build(from data: PortfolioData, now: Date = .now) -> Result {
        var result = Result()
        let snapshot = data.openingSnapshot
        let fills = episodeFills(from: data, warnings: &result.warnings)

        // 按「资产类别 + 代码」分桶：同一串数字在场内和场外是两只不同的东西。
        var buckets: [String: [MutableEpisode]] = [:]
        var names: [String: String] = [:]

        func key(_ code: String, _ kind: Holding.Kind) -> String { "\(kind.rawValue)|\(code)" }

        if let snapshot, !snapshot.positions.isEmpty {
            for position in snapshot.positions where position.quantity > 0.000001 {
                let bucketKey = key(position.code, position.kind)
                names[bucketKey] = position.name
                var episode = MutableEpisode(code: position.code, name: position.name,
                                             kind: position.kind, number: 1,
                                             openedAt: snapshot.capturedAt,
                                             historyComplete: false)
                episode.seedOpening(units: position.quantity, unitCost: position.cost)
                buckets[bucketKey, default: []].append(episode)
            }
        }

        for fill in fills {
            let bucketKey = key(fill.code, fill.kind)
            names[bucketKey] = fill.name.isEmpty ? names[bucketKey] ?? fill.code : fill.name
            var list = buckets[bucketKey] ?? []
            switch fill.side {
            case .buy:
                if list.isEmpty || list[list.count - 1].closedAt != nil {
                    list.append(MutableEpisode(code: fill.code, name: fill.name,
                                               kind: fill.kind, number: list.count + 1,
                                               openedAt: fill.date,
                                               historyComplete: true))
                }
                list[list.count - 1].apply(fill)
            case .sell:
                guard var last = list.last, last.closedAt == nil else {
                    // 没有对应买入的卖出（历史导入不完整）。不硬凑一个周期出来。
                    continue
                }
                last.apply(fill)
                list[list.count - 1] = last
            }
            buckets[bucketKey] = list
        }

        // 不用 `Dictionary(uniqueKeysWithValues:)`：老备份里出现过同一代码同类型的
        // 重复行，那个初始化器遇到重复键会直接崩，而不是取其中一个。
        var holdingsByKey: [String: Holding] = [:]
        for holding in data.holdings {
            holdingsByKey[key(holding.code, holding.kind)] = holding
        }

        // 完全没有起点、也没有流水的持仓，也要出现在列表里 —— 否则用户会以为
        // 「这只标的没被统计」。这时它是一个没有建仓时间的空周期。
        for holding in data.holdings where holding.quantity > 0.000001 {
            let bucketKey = key(holding.code, holding.kind)
            if buckets[bucketKey] == nil {
                var episode = MutableEpisode(code: holding.code, name: holding.name,
                                             kind: holding.kind, number: 1,
                                             openedAt: nil, historyComplete: false)
                episode.seedOpening(units: holding.quantity, unitCost: holding.cost)
                buckets[bucketKey] = [episode]
                names[bucketKey] = holding.name
                result.warnings.append("\(holding.name)（\(holding.code)）没有账本起点也没有成交记录，周期从当前持仓反推，建仓时间未知。")
            }
        }

        var instruments: [InstrumentEpisodes] = []
        for (bucketKey, list) in buckets {
            guard !list.isEmpty else { continue }
            let holding = holdingsByKey[bucketKey]
            let code = list[0].code
            let kind = list[0].kind
            let name = holding?.name ?? names[bucketKey] ?? code
            let episodes = list.map { $0.snapshot(name: name) }
            instruments.append(InstrumentEpisodes(code: code, name: name, kind: kind,
                                                  episodes: episodes,
                                                  currentPrice: holding?.current ?? 0,
                                                  currentUnits: holding?.quantity ?? 0))
        }
        instruments.sort { lhs, rhs in
            let left = lhs.lifetimeRealized + (lhs.activeEpisode?.bookCost ?? 0)
            let right = rhs.lifetimeRealized + (rhs.activeEpisode?.bookCost ?? 0)
            if abs(left - right) > 0.005 { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        result.instruments = instruments
        return result
    }

    /// 场内 + 场外合并成一条时间线，并去掉同一笔基金交易的重复副本。
    private static func episodeFills(from data: PortfolioData, warnings: inout [String]) -> [EpisodeFill] {
        var fills: [EpisodeFill] = []
        var skippedImported = 0
        for entry in data.ledger {
            // 导入的历史流水没有改变过当前持仓（效果已在起点里）。
            if entry.affectsHoldings == false { skippedImported += 1; continue }
            guard entry.quantity > 0, entry.price >= 0 else { continue }
            fills.append(EpisodeFill(id: entry.id, date: entry.date, code: entry.code,
                                     name: entry.name, kind: entry.kind ?? .etf,
                                     side: entry.side, quantity: entry.quantity,
                                     price: entry.price, fee: entry.fee, isReinvest: false))
        }
        if skippedImported > 0 {
            warnings.append("有 \(skippedImported) 条导入型历史流水未参与周期计算 —— 它们的效果已经体现在账本起点里，再算一次会重复。")
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        func alreadyInLedger(code: String, side: FundTransaction.Side, quantity: Double,
                             nav: Double, days: [String]) -> Bool {
            let wantedSide: LedgerEntry.Side = side == .sell ? .sell : .buy
            let wantedDays = Set(days)
            return fills.contains { fill in
                guard fill.kind == .fund, fill.code == code, fill.side == wantedSide,
                      abs(fill.quantity - quantity) <= 0.0001,
                      abs(fill.price - nav) <= 0.0001 else { return false }
                // 日期不能只认 effectiveDate：基金 T+1 确认时，账本流水记的是委托日，
                // 只比确认日会漏配，然后把同一笔申赎算成两次买入。
                return wantedDays.contains(dayFormatter.string(from: fill.date))
            }
        }

        for trade in data.fundTransactions where trade.status == .confirmed {
            guard trade.quantity > 0.000001 || trade.amount > 0 else { continue }
            // 补录的起点份额（净值 0、金额 0）由起点快照代表，不能当成交。
            if trade.isBackfill { continue }
            let nav = trade.nav > 0 ? trade.nav : (trade.quantity > 0 ? trade.amount / trade.quantity : 0)
            guard nav > 0 else { continue }
            if alreadyInLedger(code: trade.code, side: trade.side, quantity: trade.quantity,
                               nav: nav, days: [trade.effectiveDate, trade.requestDate]) { continue }

            let side: LedgerEntry.Side
            let isReinvest: Bool
            switch trade.side {
            case .buy:
                side = .buy
                isReinvest = false
            case .sell:
                side = .sell
                isReinvest = false
            case .dividend:
                // 现金分红不是份额变动；只有红利再投才进周期。
                guard trade.dividendMode == .reinvest else { continue }
                side = .buy
                isReinvest = true
            }
            let date = Self.parseDay(trade.effectiveDate) ?? .now
            fills.append(EpisodeFill(id: trade.id, date: date, code: trade.code,
                                     name: trade.name, kind: .fund, side: side,
                                     quantity: trade.quantity, price: nav,
                                     fee: max(0, trade.fee), isReinvest: isReinvest))
        }

        return fills.sorted { $0.date < $1.date }
    }

    private static func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    // MARK: 可变状态机

    private struct MutableEpisode {
        let code: String
        let name: String
        let kind: Holding.Kind
        let number: Int
        var openedAt: Date?
        var closedAt: Date?
        var currentUnits: Double = 0
        var bookCost: Double = 0
        var invested: Double = 0
        var realized: Double = 0
        var fees: Double = 0
        var trades: [EpisodeTrade] = []
        var historyComplete: Bool

        init(code: String, name: String, kind: Holding.Kind, number: Int,
             openedAt: Date?, historyComplete: Bool) {
            self.code = code
            self.name = name
            self.kind = kind
            self.number = number
            self.openedAt = openedAt
            self.historyComplete = historyComplete
        }

        mutating func seedOpening(units: Double, unitCost: Double) {
            currentUnits = units
            bookCost = units * unitCost
            invested = units * unitCost
        }

        mutating func apply(_ fill: EpisodeFill) {
            guard fill.quantity > 0, fill.price >= 0 else { return }
            let gross = fill.gross
            let fee = fill.fee
            switch fill.side {
            case .buy:
                if trades.isEmpty && currentUnits <= 0.000001 && openedAt == nil { openedAt = fill.date }
                currentUnits += fill.quantity
                bookCost += gross + fee
                // 红利再投是「分来的钱继续买」，对用户同样是投入，计入本金。
                invested += gross + fee
                fees += fee
                trades.append(EpisodeTrade(id: fill.id, date: fill.date, side: .buy,
                                           quantity: fill.quantity, price: fill.price,
                                           fee: fee, realized: 0, isReinvest: fill.isReinvest))
            case .sell:
                let sold = min(fill.quantity, currentUnits)
                guard sold > 0 else { return }
                let unitCost = currentUnits > 0.000001 ? bookCost / currentUnits : 0
                let removedBasis = unitCost * sold
                let earned = gross - fee - removedBasis
                currentUnits -= sold
                bookCost -= removedBasis
                if currentUnits <= 0.000001 {
                    currentUnits = 0
                    bookCost = 0
                    closedAt = fill.date
                }
                realized += earned
                fees += fee
                trades.append(EpisodeTrade(id: fill.id, date: fill.date, side: .sell,
                                           quantity: sold, price: fill.price, fee: fee,
                                           realized: earned, isReinvest: false))
            }
        }

        func snapshot(name: String) -> PositionEpisode {
            PositionEpisode(code: code, name: name, kind: kind, number: number,
                            openedAt: openedAt, closedAt: closedAt,
                            currentUnits: currentUnits, bookCost: bookCost,
                            invested: invested, realized: realized, fees: fees,
                            trades: trades, historyComplete: historyComplete)
        }
    }
}
