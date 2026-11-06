import Foundation
import SwiftUI

// MARK: - 账本起点、审计与真实的删除

/// 账本写操作的统一入口。
///
/// 这里解决的是一类具体问题：Pro 原来的 `removeHolding` 只是把持仓行从数组里拿掉，
/// 流水和现金完全不动。只要账本里有过成交，删完之后「持仓市值 + 现金」就再也
/// 对不上「起点 + 流水」，而 App 里没有任何地方会告诉你这件事。
///
/// 现在所有会改变账本事实的操作都走这里：先算改动前的状态指纹，做完再算一次，
/// 连同用户填的原因一起追加进审计链。链是只追加的，断没断一眼就能看出来。
extension PortfolioStore {

    // MARK: 状态判定

    /// 账本里是否已经存在任何真实成交。基金交易流水也算 —— 那是同一批事实的另一张表。
    var hasRecordedFills: Bool {
        !data.ledger.isEmpty || !data.fundTransactions.isEmpty
    }

    /// 只有「一笔成交都没有」时，持仓才等于起点快照，才允许直接改写。
    var canRewriteOpening: Bool {
        data.ledger.isEmpty && data.fundTransactions.isEmpty
    }

    var ledgerDigest: String {
        LedgerDigest.make(opening: data.openingSnapshot, cash: data.cash, fills: data.ledger)
    }

    /// 审计链自洽检查：返回链中断的位置（0 起算）。
    /// 正常情况下应该永远为空。出现非空说明有代码绕过了本文件直接改账本。
    func ledgerAuditBreaks() -> [Int] {
        let events = data.ledgerAudits
        guard events.count > 1 else { return [] }
        var broken: [Int] = []
        for index in 1..<events.count where events[index].priorDigest != events[index - 1].resultingDigest {
            broken.append(index)
        }
        return broken
    }

    // MARK: 起点快照

    /// 在第一次真正记下账本之前，把「当时的样子」定成起点。
    ///
    /// 时机很关键：必须在任何成交写入之前调用，否则起点会被成交后的持仓污染。
    /// 所以挂在 `save()` 的最前面 —— 只要这一次保存时账本还是干净的，就顺手定下来。
    func captureOpeningSnapshotIfNeeded() {
        guard data.openingSnapshot == nil, canRewriteOpening else { return }
        // 一只持仓都没有、现金也是 0 的空账本，没必要占一个起点。
        guard !data.holdings.isEmpty || data.cash != 0 else { return }
        data.openingSnapshot = makeOpeningSnapshot(source: .adopted)
    }

    private func makeOpeningSnapshot(source: LedgerOpeningSnapshot.Source) -> LedgerOpeningSnapshot {
        LedgerOpeningSnapshot(
            capturedAt: .now,
            source: source,
            cash: data.cash,
            positions: data.holdings.map { holding in
                LedgerOpeningPosition(code: holding.code, name: holding.name,
                                      kind: holding.kind, quantity: holding.quantity, cost: holding.cost)
            })
    }

    /// 改写起点快照。账本已经有过成交就直接拒绝 —— 那种情况下诚实的做法是记一笔卖出。
    @discardableResult
    func rewriteOpeningSnapshot(_ confirmation: LedgerConfirmation) throws -> LedgerOpeningSnapshot {
        guard confirmation.isValid else { throw LedgerError.invalidConfirmation }
        guard canRewriteOpening else { throw LedgerError.openingSnapshotLocked }
        guard data.cash.isFinite, data.cash >= 0 else { throw LedgerError.invalidAmount }

        let prior = ledgerDigest
        // 起点的时间要不要延续？延续。它描述的是「这批持仓是什么时候开始被跟踪的」，
        // 改的只是内容，不是开始跟踪的时刻。
        let previousCapturedAt = data.openingSnapshot?.capturedAt
        var snapshot = makeOpeningSnapshot(source: data.openingSnapshot?.source ?? .recorded)
        if let previousCapturedAt { snapshot.capturedAt = previousCapturedAt }
        data.openingSnapshot = snapshot
        appendLedgerAudit(action: "重写账本起点（尚无成交）",
                          reason: "\(confirmation.trimmedReason) · \(confirmation.trimmedNote)",
                          priorDigest: prior)
        save(label: "重写账本起点")
        return snapshot
    }

    // MARK: 删除 / 清仓

    /// 删除一只持仓。返回给用户看的一句话结论。
    @discardableResult
    func removeHoldingHonestly(_ holding: Holding, mode: HoldingRemovalMode,
                               note: String) throws -> String {
        let confirmation = LedgerConfirmation(reason: mode.title, note: note)
        guard confirmation.isValid else { throw LedgerError.invalidConfirmation }
        guard let index = data.holdings.firstIndex(where: { $0.code == holding.code && $0.kind == holding.kind }) else {
            throw LedgerError.missingHolding
        }
        let current = data.holdings[index]
        let prior = ledgerDigest
        var message = ""

        switch mode {
        case .rewriteOpening:
            guard canRewriteOpening else { throw LedgerError.openingSnapshotLocked }
            data.holdings.remove(at: index)
            data.openingSnapshot = makeOpeningSnapshot(source: data.openingSnapshot?.source ?? .recorded)
            message = "已从起点快照中移除「\(current.name)」，没有产生假成交。"

        case .recordSale:
            guard current.quantity > 0 else {
                // 零份额持仓没有可卖的东西，等价于脏数据清理。
                data.holdings.remove(at: index)
                message = "「\(current.name)」份额为 0，已直接移除。"
                break
            }
            guard current.current.isFinite, current.current > 0 else {
                throw LedgerError.noQuotedPrice(current.name)
            }
            let gross = current.quantity * current.current
            try recordTrade(code: current.code, kind: current.kind, side: .sell,
                            quantity: current.quantity, price: current.current, fee: 0,
                            linkedCash: data.cashLinkedByDefault)
            // 卖完之后份额归零，这一行已经是历史痕迹，按用户意图移除。
            data.holdings.removeAll { $0.code == current.code && $0.kind == current.kind }
            message = String(format: "已按 %.3f 记入卖出 %.2f 份，回款约 ¥%@。",
                             current.current, current.quantity, gross.cnyText())

        case .removeOnly:
            let orphan = data.ledger.contains { $0.code == current.code && ($0.kind ?? .etf) == current.kind }
            data.holdings.remove(at: index)
            message = orphan
                ? "已移除「\(current.name)」，其历史流水仍留在账本里，对账页会提示找不到对应持仓。"
                : "已移除「\(current.name)」。"
        }

        if current.kind == .fund {
            data.fundDCAPlans.removeAll { $0.code == current.code }
        }
        appendLedgerAudit(action: "删除持仓 · \(mode.title)",
                          reason: "\(current.name)（\(current.code)）· \(confirmation.trimmedNote)",
                          priorDigest: prior)
        save(label: "删除持仓")
        return message
    }

    /// 清仓：把所有份额大于 0 的持仓按最新价记成卖出。
    /// 没有行情的标的不会被动到，最后一起报给用户，而不是静默跳过。
    @discardableResult
    func liquidateAllHoldings(kind: Holding.Kind?, note: String) throws -> (sold: Int, skipped: [String]) {
        let confirmation = LedgerConfirmation(reason: "全部清仓", note: note)
        guard confirmation.isValid else { throw LedgerError.invalidConfirmation }
        let targets = data.holdings.filter { holding in
            holding.quantity > 0 && (kind == nil || holding.kind == kind)
        }
        guard !targets.isEmpty else { throw LedgerError.nothingToLiquidate }

        let prior = ledgerDigest
        var sold = 0
        var skipped: [String] = []
        for holding in targets {
            guard holding.current.isFinite, holding.current > 0 else {
                skipped.append(holding.name)
                continue
            }
            // 单只失败不能中断整批：记下名字继续，最后一起交代。
            do {
                try recordTrade(code: holding.code, kind: holding.kind, side: .sell,
                                quantity: holding.quantity, price: holding.current, fee: 0,
                                linkedCash: data.cashLinkedByDefault)
                sold += 1
            } catch {
                skipped.append(holding.name)
            }
        }
        if sold == 0 {
            throw LedgerError.noQuotedPrice(skipped.joined(separator: "、"))
        }
        appendLedgerAudit(action: "批量清仓（\(sold) 只）",
                          reason: confirmation.trimmedNote,
                          priorDigest: prior)
        save(label: "批量清仓")
        return (sold, skipped)
    }

    // MARK: 现金对账

    /// 把账面现金改成券商实际现金，差额记一条现金流说明来由。
    /// 直接赋值会让「收益归因」凭空多出一块无来源的钱，所以必须留下一条可解释的记录。
    @discardableResult
    func reconcileCashToActual(_ actual: Double, note: String) throws -> Double {
        guard actual.isFinite, actual >= 0 else { throw LedgerError.invalidAmount }
        let confirmation = LedgerConfirmation(reason: "现金对账", note: note)
        guard confirmation.isValid else { throw LedgerError.invalidConfirmation }
        let delta = actual - data.cash
        guard abs(delta) >= 0.005 else { return 0 }

        let prior = ledgerDigest
        data.cash = actual
        data.cashFlows.append(CashFlow(amount: delta,
                                       memo: "现金对账差额 · \(confirmation.trimmedNote)",
                                       affectsCash: true))
        appendLedgerAudit(action: String(format: "现金对账 %+.2f", delta),
                          reason: confirmation.trimmedNote,
                          priorDigest: prior)
        save(label: "现金对账")
        return delta
    }

    // MARK: 内部

    private func appendLedgerAudit(action: String, reason: String, priorDigest: String) {
        let event = LedgerAuditEvent(occurredAt: .now, action: action, reason: reason,
                                     priorDigest: priorDigest, resultingDigest: ledgerDigest)
        data.ledgerAudits.append(event)
        // 链只追加，但长度要可控；截断时保留最近的 200 条，断链检查从保留段开始仍然成立。
        if data.ledgerAudits.count > 200 {
            data.ledgerAudits.removeFirst(data.ledgerAudits.count - 200)
        }
    }
}

private extension Double {
    /// 审计文案里用的人民币写法，避免为了两句话引入整套格式化依赖。
    func cnyText() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }
}
