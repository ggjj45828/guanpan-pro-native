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

    /// 账本里是否已经存在任何真实成交。
    var hasRecordedFills: Bool {
        !data.ledger.isEmpty
    }

    /// 只有「一笔成交都没有」时，持仓才等于起点快照，才允许直接改写。
    var canRewriteOpening: Bool {
        data.ledger.isEmpty
    }

    /// 起点被锁住时，用户点不动按钮必须知道原因。
    var openingLockReason: String? {
        let venue = data.ledger.count
        return venue == 0 ? nil : "场内已有 \(venue) 笔成交"
    }

    var ledgerDigest: String {
        LedgerDigest.make(opening: data.openingSnapshot,
                          cash: data.cash,
                          fills: data.ledger)
    }

    /// 审计链体检：返回链中断的位置（0 起算）与口径升级接缝。
    /// 正常情况下断点应该永远为空。出现非空说明有代码绕过了本文件直接改账本。
    func ledgerAuditHealth() -> LedgerAuditHealth {
        let events = data.ledgerAudits
        guard events.count > 1 else { return LedgerAuditHealth() }
        var health = LedgerAuditHealth()
        for index in 1..<events.count where events[index].priorDigest != events[index - 1].resultingDigest {
            // 口径升级处前后算法不同，指纹天然对不上。这不是断链，记成迁移接缝。
            if (events[index].caliber ?? 1) != (events[index - 1].caliber ?? 1) {
                health.migrations.append(index)
            } else {
                health.breaks.append(index)
            }
        }
        return health
    }

    /// 只要断点，不管接缝。旧的调用点继续用这个。
    func ledgerAuditBreaks() -> [Int] { ledgerAuditHealth().breaks }

    // MARK: 起点快照

    /// 在第一次真正记下账本之前，把「当时的样子」定成起点。
    ///
    /// 时机很关键：必须在任何成交写入之前调用，否则起点会被成交后的持仓污染。
    /// 所以挂在 `save()` 的最前面 —— 只要这一次保存时账本还是干净的，就顺手定下来。
    ///
    /// 还没成交时每次保存都跟着刷新内容：用户往往是一只手一只地录进来的，
    /// 只在第一次录的时候抓一次快照，起点就只剩第一只标的，之后对账永远差几笔。
    /// 起点描述的是「开始跟踪时的样子」，在没有任何成交之前，那个样子就该跟着变。
    /// 一旦出现成交，这里就不再改动任何东西。
    func captureOpeningSnapshotIfNeeded() {
        guard canRewriteOpening else { return }
        guard !data.holdings.isEmpty || data.cash != 0 else { return }
        let existing = data.openingSnapshot
        var snapshot = makeOpeningSnapshot(source: existing?.source ?? .adopted)
        if let capturedAt = existing?.capturedAt { snapshot.capturedAt = capturedAt }
        guard snapshot != existing else { return }
        data.openingSnapshot = snapshot
    }

    private func makeOpeningSnapshot(source: LedgerOpeningSnapshot.Source) -> LedgerOpeningSnapshot {
        let now = Date()
        return LedgerOpeningSnapshot(
            capturedAt: now,
            source: source,
            cash: data.cash,
            positions: data.holdings.map { holding in
                LedgerOpeningPosition(code: holding.code, name: holding.name,
                                      kind: holding.kind, quantity: holding.quantity, cost: holding.cost)
            },
            // 记下录入时段：收盘后录入与盘中录入的含义不同，
            // 之后算「第一轮拿了几天」「当天涨跌算不算本轮」都要靠它。
            session: TradingSession.status(at: now, custom: data.customMarketHolidays),
            tradingDayKey: MarketCalendar.isoDay(now))
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

    // MARK: 补记起点

    /// 补记一个起点：只给「起点是空的、但账本里已经先有流水」的账户用一次。
    ///
    /// 这种情况很常见：用户先导入了成交流水，账本立刻就不是空的了，
    /// `captureOpeningSnapshotIfNeeded` 从此再也不会写入起点。结果就是账本永远
    /// 没有起点，审计页只能写「还没有记录账本起点」，起点这一章彻底缺失。
    ///
    /// 补记的语义要说清楚：它记的是「从现在开始跟踪时账户的样子」，
    /// 不是历史起点。所以时间戳用当下、来源标成 `lateAdopt`，
    /// 而且只允许在真正没有起点时做一次 —— 有过起点就不许覆盖。
    @discardableResult
    func adoptOpeningSnapshotLate(_ confirmation: LedgerConfirmation) throws -> LedgerOpeningSnapshot {
        guard confirmation.isValid else { throw LedgerError.invalidConfirmation }
        guard data.openingSnapshot == nil else { throw LedgerError.openingSnapshotAlreadyExists }
        guard !data.holdings.isEmpty || data.cash != 0 else { throw LedgerError.emptyAccount }

        let prior = ledgerDigest
        let snapshot = makeOpeningSnapshot(source: .lateAdopt)
        data.openingSnapshot = snapshot
        appendLedgerAudit(action: "补记账本起点（已有历史流水）",
                          reason: "\(confirmation.trimmedReason) · \(confirmation.trimmedNote)",
                          priorDigest: prior)
        save(label: "补记账本起点")
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

    /// 不标 private：账户杂费等其它写入口也要挂到同一条审计链上。
    func appendLedgerAudit(action: String, reason: String, priorDigest: String) {
        let event = LedgerAuditEvent(occurredAt: .now, action: action, reason: reason,
                                     priorDigest: priorDigest, resultingDigest: ledgerDigest,
                                     caliber: LedgerDigest.caliber)
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
