import Foundation

// MARK: - 账户杂费的写入口
//
// 所有会动现金的操作都从 `PortfolioStore+Ledger` 那套「先记指纹、后写审计」的
// 流程走一遍，这里不例外 —— 少写一次审计，账本链上就多一个解释不清的缺口。

@MainActor
extension PortfolioStore {

    // MARK: 增删

    @discardableResult
    func addAccountExpense(amount: Double, category: AccountExpense.Category,
                           date: Date, memo: String, linkedCash: Bool) throws -> AccountExpense {
        let note = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount.isFinite, amount > 0, amount <= 100_000_000, !note.isEmpty else {
            throw StoreError.invalidAccountExpense
        }
        if linkedCash, amount > data.cash + 1e-9 { throw StoreError.insufficientCashForExpense }

        let prior = ledgerDigest
        var flowID: UUID?
        if linkedCash {
            let flow = CashFlow(amount: -amount,
                                memo: "账户杂费 · \(category.title) · \(note)",
                                affectsCash: true,
                                // external = false：这是成本，不是用户转出。
                                // 记成外部流出会让「净投入」变小，收益率被凭空抬高。
                                external: false)
            data.cashFlows.append(flow)
            flowID = flow.id
            data.cash = max(0, data.cash - amount)
        }
        let expense = AccountExpense(date: date, amount: amount, category: category,
                                     memo: note, linkedCash: linkedCash, cashFlowID: flowID)
        data.accountExpenses.append(expense)
        appendLedgerAudit(action: "记录账户杂费 · \(category.title)",
                          reason: "\(amount.cny()) · \(note)",
                          priorDigest: prior)
        save(label: "记录账户杂费")
        return expense
    }

    /// 删除一笔杂费。`linkedCash` 为真的会把钱补回现金，并按 `cashFlowID` 精确删掉
    /// 那条配套现金流 —— 不靠 memo 文本去猜。
    @discardableResult
    func removeAccountExpense(id: UUID, note: String) throws -> AccountExpense {
        let reason = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw LedgerError.invalidConfirmation }
        guard let index = data.accountExpenses.firstIndex(where: { $0.id == id }) else {
            throw StoreError.invalidAccountExpense
        }
        let expense = data.accountExpenses[index]
        let prior = ledgerDigest
        if expense.linkedCash {
            data.cash += expense.amount
            if let flowID = expense.cashFlowID {
                data.cashFlows.removeAll { $0.id == flowID }
            }
        }
        data.accountExpenses.remove(at: index)
        appendLedgerAudit(action: "删除账户杂费 · \(expense.category.title)",
                          reason: "\(expense.amount.cny()) · \(expense.memo) · \(reason)",
                          priorDigest: prior)
        save(label: "删除账户杂费")
        return expense
    }

    // MARK: 汇总

    /// 区间内的杂费汇总。`annualizedRate` 需要「平均总资产」当分母：
    /// 区间内有至少两个快照就用快照均值，否则退化成当前总资产并打标记 ——
    /// 让界面能说清这个百分比是怎么来的，而不是给一个没有出处的小数。
    func expenseSummary(from start: Date, to end: Date) -> AccountExpenseSummary {
        let lower = min(start, end)
        let upper = max(start, end)
        var summary = AccountExpenseSummary()
        let items = data.accountExpenses.filter { $0.date >= lower && $0.date <= upper }
        summary.count = items.count
        summary.total = items.reduce(0) { $0 + $1.amount }

        var grouped: [AccountExpense.Category: Double] = [:]
        for item in items { grouped[item.category, default: 0] += item.amount }
        summary.byCategory = grouped
            .map { AccountExpenseCategoryTotal(category: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let dayFormatter = formatter
        let lowerDay = dayFormatter.string(from: lower)
        let upperDay = dayFormatter.string(from: upper)
        let snapshots = data.snapshots
            .filter { $0.total.isFinite && $0.total > 0 }
            .filter { $0.date >= lowerDay && $0.date <= upperDay }
            .sorted { $0.date < $1.date }

        let basis: Double
        if snapshots.count >= 2 {
            basis = snapshots.reduce(0) { $0 + $1.total } / Double(snapshots.count)
        } else {
            basis = totalAsset
            summary.usedCurrentAssetFallback = true
        }
        summary.averageAssetBasis = basis

        let spanDays = upper.timeIntervalSince(lower) / 86_400
        let days = max(1, spanDays)
        if basis > 0, summary.total > 0 {
            let annualizedCost = summary.total / days * 365
            summary.annualizedRate = annualizedCost / basis
        }
        return summary
    }

    /// 最近 365 天。年化费率只在一年这个尺度上才有可比性。
    func expenseSummaryLastYear(now: Date = .now) -> AccountExpenseSummary {
        let start = Calendar.current.date(byAdding: .day, value: -365, to: now) ?? now
        return expenseSummary(from: start, to: now)
    }

    func expenseSummaryThisMonth(now: Date = .now) -> AccountExpenseSummary {
        let interval = Calendar.current.dateInterval(of: .month, for: now)
        let start = interval?.start ?? now
        return expenseSummary(from: start, to: now)
    }

    func expenseSummaryThisYear(now: Date = .now) -> AccountExpenseSummary {
        let interval = Calendar.current.dateInterval(of: .year, for: now)
        let start = interval?.start ?? now
        return expenseSummary(from: start, to: now)
    }

    /// 按月份分组，最近的在前面。给列表用。
    func expensesByMonth() -> [AccountExpenseMonthGroup] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM"
        var buckets: [String: [AccountExpense]] = [:]
        for expense in data.accountExpenses {
            buckets[formatter.string(from: expense.date), default: []].append(expense)
        }
        return buckets.keys.sorted(by: >).map { key in
            AccountExpenseMonthGroup(month: key,
                                     items: (buckets[key] ?? []).sorted { $0.date > $1.date })
        }
    }
}
