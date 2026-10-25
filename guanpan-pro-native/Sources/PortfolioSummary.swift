import Foundation

/// 成本展示口径。券商软件两种口径的差异全部来自「卖出怎么处理」：
///
/// - `average` 买入均价（移动加权平均）：只由买入决定，卖出不改变每份成本。
/// - `diluted` 摊薄成本：卖出所得冲减成本，卖出盈利会把成本压低甚至变负；
///   同花顺「成本价」默认是这一种。
///
/// 补录的持仓没有买入流水，摊薄口径无法成立，此时自动退回买入均价并在界面上标注，
/// 不拿一个算不准的数冒充摊薄成本。
enum NextCostDisplayMode: String, CaseIterable, Identifiable {
    case diluted, average
    var id: String { rawValue }
    var title: String { self == .diluted ? "摊薄成本" : "买入均价" }
    var detail: String {
        switch self {
        case .diluted: return "卖出所得冲减成本，与同花顺「成本价」一致"
        case .average: return "只由买入决定，卖出不改变每份成本"
        }
    }
}

struct NextPositionSummary: Identifiable, Equatable {
    let code: String
    let name: String
    let units: Int
    let price: Decimal
    let previousClose: Decimal
    let marketValue: Decimal
    /// 当日盈亏：昨仓按昨收、今买按买入价、今卖按卖出价，与资产页汇总同一口径。
    let dailyChange: Decimal
    /// 选定口径下的每份成本。
    let costPerUnit: Decimal
    /// 该成本的来源说明，用于界面上区分「真摊薄」与「退回均价」。
    let costSource: String
    let floatingProfit: Decimal
    let floatingPercent: Decimal
    /// 占总资产的比例（0–100）。
    var weightPercent: Double
    var id: String { code }
}

/// 报价异常：行情源偶发串号（同一个代码返回了别的品种）时，价格会离谱到几十倍。
/// 这种情况必须**把该持仓排除在总资产之外并明说**，不能拿它算市值 ——
/// 一次串号就能把总资产从 9 千算成 1 万 5。
struct NextPortfolioAnomaly: Identifiable, Equatable {
    let code: String
    let name: String
    let reason: String
    var id: String { code }
}

struct NextRealizedItem: Identifiable, Equatable {
    let code: String
    let name: String
    let amount: Decimal
    var id: String { code }
}

struct NextPortfolioSummary: Equatable {
    let mode: NextCostDisplayMode
    let cash: Decimal
    let investedValue: Decimal
    let totalValue: Decimal
    /// 有报价的持仓是否覆盖了全部持仓；不完整时当日盈亏不可信，置空。
    let isComplete: Bool
    let dailyChange: Decimal?
    let floatingProfit: Decimal
    let floatingPercent: Decimal
    let positions: [NextPositionSummary]
    let realizedTotal: Decimal
    let realizedByCode: [NextRealizedItem]
    let recentSells: [NextFill]
    /// 被排除在汇总之外的异常报价（有持仓但报价不可信）。
    let anomalies: [NextPortfolioAnomaly]
}

enum NextPortfolioCalculator {
    static func summary(book: NextBook, quotes: [String: NextCachedQuote], at now: Date,
                        mode: NextCostDisplayMode) -> NextPortfolioSummary {
        var marketCalendar = Calendar(identifier: .gregorian)
        marketCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let todaysFills = book.fills.filter { marketCalendar.isDate($0.date, inSameDayAs: now) }

        var rows: [NextPositionSummary] = []
        var priced = 0
        var invested = Decimal.zero
        var floating = Decimal.zero
        var pricedCost = Decimal.zero
        var daily = Decimal.zero
        var complete = true
        var anomalies: [NextPortfolioAnomaly] = []

        for position in book.positions where position.units > 0 {
            guard let cached = quotes[position.code], cached.usableForDisplay(at: now) else {
                complete = false
                continue
            }
            let quote = cached.quote
            let storedCost = position.costPerUnit
            if let reason = anomalyReason(quote: quote, storedCostPerUnit: storedCost) {
                anomalies.append(NextPortfolioAnomaly(code: position.code,
                                                      name: NextNameBook.display(position.name, code: position.code),
                                                      reason: reason))
                complete = false
                continue
            }
            let value = quote.price * Decimal(position.units)
            let basis = book.costBasis(for: position.code)
            var perUnit: Decimal
            var source: String
            switch mode {
            case .average:
                perUnit = basis?.averageCost ?? position.costPerUnit
                source = "买入均价"
            case .diluted:
                if let diluted = basis?.dilutedCost {
                    perUnit = diluted
                    source = "摊薄成本"
                } else {
                    perUnit = basis?.averageCost ?? position.costPerUnit
                    source = "买入均价（补录，无成交历史）"
                }
            }
            if !perUnit.isFinite { perUnit = position.costPerUnit }
            let cost = perUnit * Decimal(position.units)
            var delta = (quote.price - quote.previousClose) * Decimal(position.units)
            for fill in todaysFills where fill.code == position.code {
                if fill.side == "buy" {
                    delta += (quote.previousClose - fill.price) * Decimal(fill.units) - fill.fee
                } else {
                    delta += (fill.price - quote.previousClose) * Decimal(fill.units) - fill.fee
                }
            }
            rows.append(NextPositionSummary(
                code: position.code, name: NextNameBook.display(position.name, code: position.code), units: position.units,
                price: quote.price, previousClose: quote.previousClose,
                marketValue: value, dailyChange: delta,
                costPerUnit: perUnit, costSource: source,
                floatingProfit: value - cost,
                floatingPercent: cost > 0 ? (value - cost) / cost * 100 : 0,
                weightPercent: 0))
            invested += value
            floating += value - cost
            pricedCost += cost
            daily += delta
            priced += 1
        }

        let cash = book.cash
        let total = cash + invested
        for index in rows.indices {
            rows[index].weightPercent = total > 0 ? NextNum.double(rows[index].marketValue / total) * 100 : 0
        }

        var realizedByCode: [String: Decimal] = [:]
        for fill in book.fills where fill.side == "sell" {
            realizedByCode[fill.code, default: 0] += fill.realized
        }
        let names = Dictionary(book.positions.map { ($0.code, $0.name) }, uniquingKeysWith: { first, _ in first })
        let realizedItems = realizedByCode
            .map { NextRealizedItem(code: $0.key, name: names[$0.key] ?? $0.key, amount: $0.value) }
            .sorted { abs(NextNum.double($0.amount)) > abs(NextNum.double($1.amount)) }

        let dailyTotal = (complete && priced == book.positions.filter({ $0.units > 0 }).count) ? daily : nil
        return NextPortfolioSummary(
            mode: mode, cash: cash, investedValue: invested, totalValue: total,
            isComplete: complete, dailyChange: dailyTotal,
            floatingProfit: floating,
            floatingPercent: pricedCost > 0 ? floating / pricedCost * 100 : 0,
            positions: rows.sorted { $0.marketValue > $1.marketValue },
            realizedTotal: book.fills.reduce(Decimal.zero) { $0 + $1.realized },
            realizedByCode: realizedItems,
            recentSells: book.fills.filter { $0.side == "sell" }.sorted { $0.date > $1.date }.prefix(5).map { $0 },
            anomalies: anomalies)
    }

    /// 报价异常判定。两种都能在不误伤正常行情的前提下抓住「串号」：
    /// 1. 与昨收偏离超过 25%（ETF 有涨跌幅限制，正常到不了）；
    /// 2. 与账本成本相差 3 倍以上（除权不会让价格在一天内变三倍）。
    static func anomalyReason(quote: NextQuote, storedCostPerUnit: Decimal) -> String? {
        guard quote.price > 0, quote.previousClose > 0 else { return "报价缺失或为零" }
        let change = quote.price / quote.previousClose - 1
        let limit = Decimal(25) / Decimal(100)
        if change > limit || change < -limit {
            let percent = NextNum.double(change) * 100
            return "报价与昨收偏离 \(String(format: "%.3f", percent))%，疑似行情源串号，已排除在总资产之外"
        }
        guard storedCostPerUnit > 0 else { return nil }
        let ratio = quote.price / storedCostPerUnit
        if ratio > 3 || ratio < Decimal(3333) / Decimal(10_000) {
            return "报价是账本成本的 \(String(format: "%.3f", NextNum.double(ratio))) 倍，疑似行情源串号，已排除在总资产之外"
        }
        return nil
    }
}

// MARK: - 区间收益

/// 用本机资产快照算区间收益。**剔除出入金**，否则转入一笔钱就显示「大赚」。
///
/// 做法是时间加权（TWR）近似：逐日 `r = (今日总资产 − 今日外部流入) / 昨日总资产 − 1`，
/// 再把各日收益率连乘。它不是券商那种精确 TWR（没有盘中现金流时点），
/// 但对「这段时间到底赚没赚」够用，且算法写在界面上可复算。
struct NextPerformanceSummary: Equatable {
    let startDate: Date
    let endDate: Date
    let cumulativePercent: Double
    let annualizedPercent: Double?
    let maxDrawdownPercent: Double
    let dayCount: Int
    let hasEnoughSamples: Bool
}

enum NextPerformanceCalculator {
    static func summary(points: [NextAssetPoint], minimumSamples: Int = 3) -> NextPerformanceSummary? {
        let ordered = points.sorted { $0.date < $1.date }
        guard ordered.count >= 2, let first = ordered.first, let last = ordered.last else { return nil }
        var equity = 1.0
        var peak = 1.0
        var maxDrawdown = 0.0
        var emptyBase = false
        for index in 1..<ordered.count {
            let previous = NextNum.double(ordered[index - 1].total)
            guard previous > 0 else { emptyBase = true; continue }
            let current = NextNum.double(ordered[index].total)
            let flow = NextNum.double(ordered[index].externalFlow)
            let daily = (current - flow) / previous - 1
            guard daily.isFinite, daily > -1 else { continue }
            equity *= (1 + daily)
            peak = max(peak, equity)
            if peak > 0 { maxDrawdown = max(maxDrawdown, (peak - equity) / peak * 100) }
        }
        let days = max(1, Int(last.date.timeIntervalSince(first.date) / 86_400))
        let cumulative = (equity - 1) * 100
        // 不足 90 天不给年化：把几天的波动放大到一年纯属误导。
        let annualized: Double? = days >= 90 && equity > 0 ? (pow(equity, 365.0 / Double(days)) - 1) * 100 : nil
        return NextPerformanceSummary(startDate: first.date, endDate: last.date,
                                      cumulativePercent: cumulative, annualizedPercent: annualized,
                                      maxDrawdownPercent: maxDrawdown, dayCount: days,
                                      hasEnoughSamples: ordered.count >= minimumSamples && !emptyBase)
    }
}

// MARK: - 账本体检

/// 一条待处理的数据问题。都能直接指到具体代码，并说明"怎么办"。
struct NextBookIssue: Identifiable, Equatable {
    let code: String
    let title: String
    let detail: String
    var id: String { code + "|" + title }
}

/// 账本体检：只检查**会让数字失真**的已知问题，不做主观评价。
///
/// 为什么需要它：总资产/当日盈亏对不上时，用户第一反应是"软件算错了"，
/// 但九成原因是数据缺口（没报价、名字没有、成本为 0、报价串号、超集中度）。
/// 把这些问题显式列出来，比让人自己猜要诚实得多。
enum NextBookHealth {
    static func issues(book: NextBook, quotes: [String: NextCachedQuote], at now: Date,
                       concentrationLimit: Double) -> [NextBookIssue] {
        var issues: [NextBookIssue] = []
        let positions = book.positions.filter { $0.units > 0 }
        var total = book.cash
        for position in positions {
            if let quote = quotes[position.code]?.quote, quote.price > 0 {
                total += quote.price * Decimal(position.units)
            }
        }
        for position in positions {
            if !NextNameBook.isResolved(position.code) {
                issues.append(NextBookIssue(code: position.code, title: "名称缺失",
                                            detail: "只有代码，看起来像一只陌生标的；在详情页刷新一次行情就会记住名称"))
            }
            if position.costPerUnit <= 0 {
                issues.append(NextBookIssue(code: position.code, title: "成本为零",
                                            detail: "成本为 0 会让盈亏比例失真；在资产流水里修正每份成本"))
            }
            guard let cached = quotes[position.code] else {
                issues.append(NextBookIssue(code: position.code, title: "没有报价",
                                            detail: "这一只不计入市值与当日盈亏；联网刷新后再看"))
                continue
            }
            if !cached.usableForDisplay(at: now) {
                issues.append(NextBookIssue(code: position.code, title: "报价已过期",
                                            detail: "缓存报价不会被当成实时价格；刷新行情或检查 NAS 连接"))
            }
            if let reason = NextPortfolioCalculator.anomalyReason(quote: cached.quote, storedCostPerUnit: position.costPerUnit) {
                issues.append(NextBookIssue(code: position.code, title: "报价异常", detail: reason))
            }
            if total > 0, concentrationLimit > 0 {
                let weight = NextNum.double(cached.quote.price * Decimal(position.units) / total) * 100
                if weight > concentrationLimit {
                    issues.append(NextBookIssue(code: position.code, title: "超出集中度线",
                                                detail: String(format: "占 %.1f%%，你设的提醒线是 %.0f%%", weight, concentrationLimit)))
                }
            }
        }
        return issues
    }
}

// MARK: - 真实持仓历史共振（不是成分重叠或预测）

struct NextPortfolioCorrelationWindow: Equatable {
    let requestedDays: Int
    let sampleCount: Int
    let coefficient: Double?
    let startDay: String?
    let endDay: String?
}

struct NextPortfolioCorrelation: Identifiable, Equatable {
    let codeA: String
    let nameA: String
    let codeB: String
    let nameB: String
    let windows: [NextPortfolioCorrelationWindow]
    var id: String { "\(codeA)-\(codeB)" }
}

enum NextPortfolioCorrelationEngine {
    private static let windows = [20, 60, 120]
    private static let minimumSamples = 20

    /// Computes aligned close-to-close return correlation from the user's stored
    /// daily bars. It describes historical co-movement only; it is not constituent
    /// overlap, causal evidence, or a trading signal.
    static func analyze(book: NextBook, dailyBars: [String: [NextChartSample]], now: Date)
        -> [NextPortfolioCorrelation] {
        let positions = book.positions.filter { $0.units > 0 }.sorted { $0.code < $1.code }
        guard positions.count > 1 else { return [] }
        var result: [NextPortfolioCorrelation] = []
        for leftIndex in 0..<(positions.count - 1) {
            for rightIndex in (leftIndex + 1)..<positions.count {
                let left = positions[leftIndex], right = positions[rightIndex]
                let leftCloses = closesBySession(dailyBars[left.code] ?? [], now: now)
                let rightCloses = closesBySession(dailyBars[right.code] ?? [], now: now)
                let commonDays = Set(leftCloses.keys).intersection(rightCloses.keys).sorted()
                guard commonDays.count >= 2 else {
                    result.append(NextPortfolioCorrelation(codeA: left.code, nameA: left.name,
                        codeB: right.code, nameB: right.name,
                        windows: windows.map { NextPortfolioCorrelationWindow(requestedDays: $0,
                            sampleCount: 0, coefficient: nil, startDay: nil, endDay: nil) }))
                    continue
                }
                var returns: [(day: String, a: Double, b: Double)] = []
                for index in 1..<commonDays.count {
                    let previousDay = commonDays[index - 1], day = commonDays[index]
                    guard let a0 = leftCloses[previousDay], let a1 = leftCloses[day],
                          let b0 = rightCloses[previousDay], let b1 = rightCloses[day],
                          a0 > 0, a1 > 0, b0 > 0, b1 > 0 else { continue }
                    let aReturn = a1 / a0 - 1, bReturn = b1 / b0 - 1
                    guard aReturn.isFinite, bReturn.isFinite else { continue }
                    returns.append((day: day, a: aReturn, b: bReturn))
                }
                let summaries = windows.map { days -> NextPortfolioCorrelationWindow in
                    let sample = Array(returns.suffix(days))
                    let coefficient = sample.count == days && sample.count >= minimumSamples
                        ? pearson(sample.map { ($0.a, $0.b) }) : nil
                    return NextPortfolioCorrelationWindow(requestedDays: days,
                        sampleCount: sample.count, coefficient: coefficient,
                        startDay: sample.first?.day, endDay: sample.last?.day)
                }
                result.append(NextPortfolioCorrelation(codeA: left.code, nameA: left.name,
                    codeB: right.code, nameB: right.name, windows: summaries))
            }
        }
        return result
    }

    static func contextLines(book: NextBook, dailyBars: [String: [NextChartSample]], now: Date)
        -> [String] {
        analyze(book: book, dailyBars: dailyBars, now: now).map { pair in
            let windows = pair.windows.map { window in
                if let value = window.coefficient {
                    let range = [window.startDay, window.endDay].compactMap { $0 }.joined(separator: "–")
                    return "\(window.requestedDays)日 r=\(String(format: "%+.2f", value)) (n=\(window.sampleCount)，\(range))"
                }
                return "\(window.requestedDays)日样本不足 (n=\(window.sampleCount)/\(window.requestedDays))"
            }.joined(separator: "；")
            return "\(pair.nameA)(\(pair.codeA)) / \(pair.nameB)(\(pair.codeB))：\(windows)；仅为历史价格共振代理，不代表成分重叠、因果或未来预测；不得单独生成交易指令"
        }
    }

    private static func closesBySession(_ samples: [NextChartSample], now: Date) -> [String: Double] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var latest: [String: (Date, Double)] = [:]
        for sample in samples where sample.timestamp <= now && sample.close > 0 && !sample.close.isNaN {
            let parts = calendar.dateComponents([.year, .month, .day], from: sample.timestamp)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            let close = NextNum.double(sample.close)
            guard close.isFinite, close > 0 else { continue }
            if latest[key].map({ $0.0 < sample.timestamp }) ?? true { latest[key] = (sample.timestamp, close) }
        }
        return latest.mapValues { $0.1 }
    }

    private static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= minimumSamples else { return nil }
        let meanA = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let meanB = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (a, b) in pairs {
            let da = a - meanA, db = b - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 0, varianceB > 0 else { return nil }
        let coefficient = covariance / sqrt(varianceA * varianceB)
        guard coefficient.isFinite else { return nil }
        return max(-1, min(1, coefficient))
    }
}
