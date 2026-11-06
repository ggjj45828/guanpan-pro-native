import Foundation

/// 按标的的已实现业绩。
///
/// 与「账户已实现总额」不是一回事：总额只说「一共赚了多少」，
/// 这个说「哪只赚的、哪只在亏、卖了多少次、这笔卖出占用了多少成本」。
/// 收益率的分母是**移除掉的成本基础**（`costBasisRemoved`），不是卖出金额 ——
/// 用卖出金额当分母会把收益率系统性低估（10 元卖 12 元是 +20%，用 12 做分母就成了 +16.7%）。
struct RealizedInstrumentPerformance: Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    let code: String
    let name: String
    let kind: Holding.Kind
    let sellFillCount: Int
    let unitsSold: Double
    let grossProceeds: Double
    let fees: Double
    let costBasisRemoved: Double
    let netRealizedProfit: Double

    var returnOnRemovedCost: Double? {
        guard costBasisRemoved > 0 else { return nil }
        let value = netRealizedProfit / costBasisRemoved
        return value.isFinite ? value : nil
    }

    var isWin: Bool { netRealizedProfit > 0.01 }
}

struct RealizedPerformanceSnapshot {
    let sellFillCount: Int
    let unitsSold: Double
    let grossProceeds: Double
    let fees: Double
    let costBasisRemoved: Double
    let netRealizedProfit: Double
    let byInstrument: [RealizedInstrumentPerformance]

    /// 卖出胜率：按标的算（赚的标的数 / 有卖出的标的数），不是按笔算。
    ///
    /// 按笔算会被「同一只反复做 T」放大：一只票做 20 次小赚就能刷出 90% 胜率，
    /// 但它只代表一次判断。按标的算更接近「选股对不对」。
    var instrumentWinRate: Double? {
        let resolved = byInstrument.filter { abs($0.netRealizedProfit) > 0.01 }
        guard !resolved.isEmpty else { return nil }
        return Double(resolved.filter(\.isWin).count) / Double(resolved.count)
    }

    var averageReturnOnCost: Double? {
        let values = byInstrument.compactMap(\.returnOnRemovedCost)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

enum RealizedPerformance {
    /// 只从账本事实推导：起点 + 逐笔成交（含更正后的费用）。
    /// 不用行情、不用市值、不用未实现浮盈 —— 那些都不是「已经发生」。
    static func derive(data: PortfolioData) -> RealizedPerformanceSnapshot {
        // 重放一遍拿到每笔卖出移除的成本基础。账本不自洽时退化为「用已存 realizedPnL」，
        // 但那样分母缺失，收益率会整体为空 —— 这正是诚实的表现。
        let replay = try? LedgerReplay.run(data: data)
        let costBasis = replay?.costBasisByFill ?? [:]
        let fills = (replay?.fills ?? data.ledger).sorted { $0.date < $1.date }

        // 用结构体累计而不是元组：9 个元素的元组字面量在 SwiftUI 工程里
        // 很容易把类型检查拖慢，而且字段名比位置更不容易写错。
        struct Bucket {
            var code = ""
            var name = ""
            var kind: Holding.Kind = .etf
            var count = 0
            var units = 0.0
            var proceeds = 0.0
            var fees = 0.0
            var cost = 0.0
            var net = 0.0
        }

        var accumulator: [String: Bucket] = [:]
        var totalCount = 0
        var totalUnits = 0.0
        var totalProceeds = 0.0
        var totalFees = 0.0
        var totalCost = 0.0

        for fill in fills where fill.side == .sell && fill.affectsHoldings != false {
            let kind = fill.kind ?? .etf
            let key = "\(kind.rawValue)-\(fill.code)"
            let removed = costBasis[fill.id] ?? max(0, fill.gross - fill.realizedPnL - fill.fee)
            var item = accumulator[key] ?? Bucket()
            item.code = fill.code
            item.name = fill.name
            item.kind = kind
            item.count += 1
            item.units += fill.quantity
            item.proceeds += fill.gross
            item.fees += max(0, fill.fee)
            item.cost += removed
            item.net += fill.realizedPnL
            accumulator[key] = item

            totalCount += 1
            totalUnits += fill.quantity
            totalProceeds += fill.gross
            totalFees += max(0, fill.fee)
            totalCost += removed
        }

        let rows = accumulator.values
            .map { item in
                RealizedInstrumentPerformance(code: item.code, name: item.name, kind: item.kind,
                                              sellFillCount: item.count, unitsSold: item.units,
                                              grossProceeds: item.proceeds, fees: item.fees,
                                              costBasisRemoved: item.cost,
                                              netRealizedProfit: item.net)
            }
            .sorted { $0.netRealizedProfit > $1.netRealizedProfit }

        return RealizedPerformanceSnapshot(sellFillCount: totalCount, unitsSold: totalUnits,
                                           grossProceeds: totalProceeds, fees: totalFees,
                                           costBasisRemoved: totalCost,
                                           netRealizedProfit: totalProceeds - totalFees - totalCost,
                                           byInstrument: rows)
    }
}

extension PortfolioStore {
    var realizedPerformance: RealizedPerformanceSnapshot {
        RealizedPerformance.derive(data: data)
    }
}
