import Foundation

/// 账本重放。
///
/// 存在的理由：**手续费是可以事后更正的**。券商 App 里看到的实际费用，
/// 往往要等当晚清算完才准确；录入时猜的那个数（`feeWasEstimated`）如果一直不修，
/// 已实现盈亏、成本、收益率就全体偏一点。
///
/// 但「更正费用」不能只把那一笔的 `fee` 改掉 —— 卖出那笔的 `realizedPnL`
/// 和之后所有买入的 `cost` 都依赖它。所以必须按起点 + 逐笔重算一遍。
///
/// 重放**不改原始成交的数量与价格**，只重算派生量（成本、已实现）。
enum LedgerReplay {

    struct Key: Hashable {
        let code: String
        let kind: Holding.Kind
        var display: String { "\(code)|\(kind.rawValue)" }
    }

    struct PositionState: Equatable {
        var units: Double = 0
        var cost: Double = 0        // 单位成本
    }

    struct Result {
        var positions: [Key: PositionState] = [:]
        /// 重算过 `realizedPnL` 的成交（顺序与输入一致）。
        var fills: [LedgerEntry] = []
        /// 每笔卖出「移除掉多少成本基础」。已实现收益率的正确分母是它，
        /// 不是卖出金额 —— 用卖出金额当分母会把收益率系统性低估。
        var costBasisByFill: [UUID: Double] = [:]
        /// 起点现金 + 所有 `linkedCash` 成交的净额。
        var cashAfter: Double = 0
        var realizedTotal: Double = 0
        /// 没有起点却出现卖出、无法判定成本的成交。这些的 `realizedPnL` 保持原值。
        var unbackedSells: [UUID] = []

        func state(for code: String, kind: Holding.Kind) -> PositionState {
            positions[Key(code: code, kind: kind)] ?? PositionState()
        }
    }

    enum Failure: Error, Equatable {
        /// 卖出数量超过持有份额 —— 账本本身不自洽。
        case quantityUnderflow(code: String, fillID: UUID)
    }

    private static func key(_ code: String, _ kind: Holding.Kind) -> Key {
        Key(code: code, kind: kind)
    }

    /// 按「起点快照 + 逐笔成交」重放。
    ///
    /// `affectsHoldings == false` 的导入流水**不改变余额** —— 它们记录的是
    /// 「历史上确实发生过」，而当时的效果已经体现在起点里了。再算一次就是买了两遍。
    static func run(data: PortfolioData) throws -> Result {
        var result = Result()
        result.cashAfter = data.openingSnapshot?.cash ?? 0

        if let opening = data.openingSnapshot {
            for position in opening.positions where position.quantity > 0 {
                let k = key(position.code, position.kind)
                var state = result.positions[k] ?? PositionState()
                let totalUnits = state.units + position.quantity
                guard totalUnits > 0 else { continue }
                // 起点里同一标的只出现一次（`LedgerOpeningSnapshot` 由持仓生成），
                // 但重放要被复用，所以按加权合并写法留好余地。
                state.cost = (state.cost * state.units + position.cost * position.quantity) / totalUnits
                state.units = totalUnits
                result.positions[k] = state
            }
        }

        let ordered = data.ledger.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.date < rhs.date
        }

        for var fill in ordered {
            let kind = fill.kind ?? .etf
            let k = key(fill.code, kind)
            var state = result.positions[k] ?? PositionState()
            let gross = fill.quantity * fill.price
            let fee = max(0, fill.fee)

            if fill.affectsHoldings == false {
                // 只留档，不动余额。
                result.fills.append(fill)
                continue
            }

            switch fill.side {
            case .buy:
                let newUnits = state.units + fill.quantity
                guard newUnits > 0, newUnits.isFinite else {
                    throw Failure.quantityUnderflow(code: fill.code, fillID: fill.id)
                }
                state.cost = (state.cost * state.units + gross + fee) / newUnits
                state.units = newUnits
                fill.realizedPnL = 0
                if fill.linkedCash { result.cashAfter -= gross + fee }

            case .sell:
                guard state.units + 1e-8 >= fill.quantity else {
                    throw Failure.quantityUnderflow(code: fill.code, fillID: fill.id)
                }
                if state.units <= 1e-8 {
                    // 没有起点、也没买入就卖出：成本未知。
                    // 不编一个成本出来，保留原 `realizedPnL` 并记下这条。
                    result.unbackedSells.append(fill.id)
                } else {
                    fill.realizedPnL = (fill.price - state.cost) * fill.quantity - fee
                    result.realizedTotal += fill.realizedPnL
                    result.costBasisByFill[fill.id] = state.cost * fill.quantity
                }
                state.units = max(0, state.units - fill.quantity)
                if state.units <= 1e-8 {
                    // 清零时把残留成本抹平：留着会让下一次买入的单位成本偏小。
                    state.units = 0
                    state.cost = 0
                }
                if fill.linkedCash { result.cashAfter += gross - fee }
            }
            result.positions[k] = state
            result.fills.append(fill)
        }
        return result
    }

    /// 只算「当前状态」，不产出逐笔。给内部体检用。
    static func positionsOnly(data: PortfolioData) -> [Key: PositionState] {
        (try? run(data: data))?.positions ?? [:]
    }
}

// MARK: - 与存储值的差异

struct LedgerReplayDiscrepancy: Identifiable {
    var id: String { "\(key.code)|\(key.kind.rawValue)" }
    let key: LedgerReplay.Key
    let name: String
    let storedUnits: Double
    let replayedUnits: Double
    let storedCost: Double
    let replayedCost: Double

    var isQuantityMismatch: Bool { abs(storedUnits - replayedUnits) > 1e-6 }
    var isCostMismatch: Bool { !isQuantityMismatch && abs(storedCost - replayedCost) > 1e-6 }
}
