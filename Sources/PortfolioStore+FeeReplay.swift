import Foundation

/// 费用更正后的重放落地。
///
/// 与 `confirmFundRedemptionFee` 的分工：那个函数管「用户确认基金实际赎回费」这件事本身，
/// 这里管「改完之后所有派生量怎么重算」。
extension PortfolioStore {

    /// 按重放结果校正持仓成本与每笔成交的已实现盈亏。
    ///
    /// 只改**派生量**：`Holding.cost`（单位成本）与 `LedgerEntry.realizedPnL`。
    /// 份额、价格、日期一律不动 —— 那是用户确认过的成交事实。
    /// - Returns: 重放失败（账本不自洽）时返回 false，调用方应保持原状并提示。
    @discardableResult
    func rebuildDerivedLedgerValues() -> Bool {
        guard let replay = try? LedgerReplay.run(data: data) else { return false }
        data.ledger = replay.fills
        for index in data.holdings.indices {
            let holding = data.holdings[index]
            let state = replay.state(for: holding.code, kind: holding.kind)
            // 份额对不上说明这份持仓与流水不是同一条链路（典型是导入历史但没有起点）。
            // 这种情况下改成本只会让数字更假，宁可不改。
            guard abs(state.units - holding.quantity) <= 1e-6 else { continue }
            data.holdings[index].cost = state.cost
        }
        return true
    }

    /// 账本与存储值的差异体检。用于「账本审计」页：
    /// 正常情况下应为空；不为空说明有代码绕过了 `recordTrade` 直接改了持仓。
    func ledgerReplayDiscrepancies() -> [LedgerReplayDiscrepancy] {
        guard let replay = try? LedgerReplay.run(data: data) else { return [] }
        var rows: [LedgerReplayDiscrepancy] = []
        for holding in data.holdings {
            let state = replay.state(for: holding.code, kind: holding.kind)
            if abs(state.units - holding.quantity) > 1e-6 {
                rows.append(LedgerReplayDiscrepancy(key: .init(code: holding.code, kind: holding.kind),
                                                    name: holding.name,
                                                    storedUnits: holding.quantity,
                                                    replayedUnits: state.units,
                                                    storedCost: holding.cost,
                                                    replayedCost: state.cost))
            } else if abs(state.cost - holding.cost) > 1e-6 && holding.quantity > 0 {
                rows.append(LedgerReplayDiscrepancy(key: .init(code: holding.code, kind: holding.kind),
                                                    name: holding.name,
                                                    storedUnits: holding.quantity,
                                                    replayedUnits: state.units,
                                                    storedCost: holding.cost,
                                                    replayedCost: state.cost))
            }
        }
        return rows
    }

    /// 场内成交的手续费更正。
    ///
    /// 之前只有基金赎回费能改（`confirmFundRedemptionFee`），场内成交录错了费用
    /// 就只能删掉重录 —— 而删除会连带改现金、改份额、写审计，代价太大。
    func correctTradeFee(fillID: UUID, actualFee: Double, reason: String) throws {
        guard let index = data.ledger.firstIndex(where: { $0.id == fillID }) else {
            throw StoreError.noUndoableTrade
        }
        let fill = data.ledger[index]
        guard actualFee.isFinite, actualFee >= 0,
              fill.affectsHoldings != false,
              actualFee <= fill.gross + 1e-9 else {
            throw StoreError.invalidFeeCorrection
        }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { throw StoreError.invalidFeeCorrection }

        let priorDigest = ledgerDigest
        let oldFee = fill.fee
        let delta = actualFee - oldFee
        guard delta.isFinite, abs(delta) > 1e-9 else { return }   // 没变化，不写审计

        // 先把可能被改动的两处都留一份底，任何一步失败就原样退回去 ——
        // 只回滚 fee 而把 cash 留在改过一半的状态，是最糟的结果。
        let cashBackup = data.cash
        data.ledger[index].fee = actualFee
        if fill.linkedCash {
            switch fill.side {
            case .buy: data.cash -= delta
            case .sell: data.cash += delta
            }
            guard data.cash.isFinite, data.cash >= -1e-6 else {
                data.ledger[index].fee = oldFee
                data.cash = cashBackup
                throw StoreError.insufficientCashForFeeCorrection
            }
            if data.cash < 0 { data.cash = 0 }
        }

        guard rebuildDerivedLedgerValues() else {
            data.ledger[index].fee = oldFee
            data.cash = cashBackup
            throw StoreError.invalidImportedLedger
        }

        let direction = delta > 0 ? "上调" : "下调"
        appendLedgerAudit(action: "更正手续费 \(direction)",
                          reason: "\(fill.name)（\(fill.code)）\(fill.side == .buy ? "买入" : "卖出")"
                            + "\(fill.quantity.num(0)) 份：\(oldFee.cny()) → \(actualFee.cny())。"
                            + "按新费用重放了此后全部成交的成本与已实现。原因：\(trimmedReason)",
                          priorDigest: priorDigest)
        save(label: "更正手续费")
    }

    /// 更正前后会差多少 —— 给确认弹窗用，让人先看到影响再点确定。
    struct FeeCorrectionPreview {
        let oldFee: Double
        let newFee: Double
        let cashDelta: Double
        let realizedDelta: Double
        /// 受影响的后续成交笔数（同标的、此笔之后）。
        let affectedFollowingFills: Int
    }

    func feeCorrectionPreview(fillID: UUID, newFee: Double) -> FeeCorrectionPreview? {
        guard let fill = data.ledger.first(where: { $0.id == fillID }),
              newFee.isFinite, newFee >= 0 else { return nil }
        let currentRealized = data.ledger.reduce(0) { $0 + $1.realizedPnL }
        var copy = data
        guard let index = copy.ledger.firstIndex(where: { $0.id == fillID }) else { return nil }
        copy.ledger[index].fee = newFee
        guard let replay = try? LedgerReplay.run(data: copy) else { return nil }
        let following = data.ledger.filter {
            $0.code == fill.code && ($0.kind ?? .etf) == (fill.kind ?? .etf) && $0.date >= fill.date
        }.count
        return FeeCorrectionPreview(oldFee: fill.fee,
                                    newFee: newFee,
                                    cashDelta: fill.linkedCash ? (fill.side == .buy ? -(newFee - fill.fee) : (newFee - fill.fee)) : 0,
                                    realizedDelta: replay.realizedTotal - currentRealized,
                                    affectedFollowingFills: max(0, following - 1))
    }
}
