import Foundation

struct StrategyBacktestResult {
    var startDate: String
    var endDate: String
    var strategyValue: Double
    var holdValue: Double
    var strategyReturn: Double
    var holdReturn: Double
    var maxDrawdown: Double
    var orders: Int
}

@MainActor
enum StrategyBacktest {
    /// MA5/MA20 close signals execute at the next session's open to avoid
    /// using a closing signal and pretending to fill at that same close.
    static func run(bars: [DailyBar], initialCash: Double, feeRate: Double, isETF: Bool = true) -> StrategyBacktestResult? {
        let rows = bars.sorted { $0.date < $1.date }
        guard rows.count >= 25, initialCash.isFinite, initialCash >= 100,
              feeRate.isFinite, (0...0.02).contains(feeRate),
              rows.allSatisfy({ $0.open.isFinite && $0.close.isFinite && $0.open > 0 && $0.close > 0 }) else { return nil }
        let closes = rows.map(\.close)
        func average(endingAt index: Int, window: Int) -> Double? {
            guard index + 1 >= window else { return nil }
            return closes[(index + 1 - window)...index].reduce(0, +) / Double(window)
        }
        // feeRate is retained for source compatibility. ETF uses the fixed fee policy.
        func tradeFee(_ gross: Double, side: String) -> Double {
            SimulationCostPolicy.fee(isETF: isETF, side: side, amount: gross)
        }
        func lotCount(cash: Double, price: Double) -> Double {
            guard price > 0 else { return 0 }
            var result = max(0, floor(cash / price / 100) * 100)
            while result > 0 && result * price + tradeFee(result * price, side: "buy") > cash { result -= 100 }
            return result
        }
        var cash = initialCash, shares = 0.0, orders = 0, peak = initialCash, worstDrawdown = 0.0
        for session in 2..<rows.count {
            let prior = session - 1, before = session - 2
            guard let fastNow = average(endingAt: prior, window: 5),
                  let slowNow = average(endingAt: prior, window: 20),
                  let fastBefore = average(endingAt: before, window: 5),
                  let slowBefore = average(endingAt: before, window: 20) else { continue }
            let buyCross = fastBefore <= slowBefore && fastNow > slowNow
            let sellCross = fastBefore >= slowBefore && fastNow < slowNow
            let price = rows[session].open
            if buyCross && shares == 0 {
                let quantity = lotCount(cash: cash, price: price)
                if quantity > 0 {
                    let gross = quantity * price, fee = tradeFee(quantity * price, side: "buy")
                    cash -= gross + fee; shares = quantity; orders += 1
                }
            } else if sellCross && shares > 0 {
                let gross = shares * price
                cash += gross - tradeFee(gross, side: "sell"); shares = 0; orders += 1
            }
            let equity = cash + shares * rows[session].close
            peak = max(peak, equity)
            if peak > 0 { worstDrawdown = min(worstDrawdown, equity / peak - 1) }
        }
        if shares > 0 {
            let gross = shares * rows[rows.count - 1].close
            cash += gross - tradeFee(gross, side: "sell"); shares = 0; orders += 1
        }
        let finalPeak = max(peak, cash)
        if finalPeak > 0 { worstDrawdown = min(worstDrawdown, cash / finalPeak - 1) }
        let holdShares = lotCount(cash: initialCash, price: rows[0].open)
        let holdCost = holdShares * rows[0].open
        let holdProceeds = holdShares > 0 ? holdShares * rows[rows.count - 1].close - tradeFee(holdShares * rows[rows.count - 1].close, side: "sell") : 0
        let holdValue = initialCash - holdCost - (holdShares > 0 ? tradeFee(holdCost, side: "buy") : 0) + holdProceeds
        return StrategyBacktestResult(startDate: rows[0].date, endDate: rows[rows.count - 1].date,
            strategyValue: cash, holdValue: holdValue,
            strategyReturn: cash / initialCash - 1,
            holdReturn: holdValue / initialCash - 1,
            maxDrawdown: worstDrawdown, orders: orders)
    }
}
