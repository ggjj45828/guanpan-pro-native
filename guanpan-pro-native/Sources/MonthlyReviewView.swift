import SwiftUI

private struct MonthlyReviewSummary {
    var buy = 0.0
    var sell = 0.0
    var fee = 0.0
    var realized = 0.0
    var cashDividend = 0.0
    var reinvestedDividend = 0.0
    var netFlow = 0.0
    var buyCount = 0
    var sellCount = 0
    var operationDays = Set<String>()
    var tradedCodes: [String: (name: String, bought: Bool, sold: Bool)] = [:]
    var snapshotStart: PortfolioSnapshot?
    var snapshotEnd: PortfolioSnapshot?
    var snapshotNetFlow = 0.0
    var tips: [String] = []
    var assetChange: Double? {
        guard let snapshotStart, let snapshotEnd, snapshotStart.id != snapshotEnd.id else { return nil }
        return snapshotEnd.total - snapshotStart.total
    }
    var adjustedChange: Double? { assetChange.map { $0 - snapshotNetFlow } }
    var netResult: Double { realized + cashDividend }
}

struct MonthlyReviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var month = Self.monthString(.now)

    private var monthStart: String { "\(month)-01" }
    private var nextMonthStart: String { Self.nextMonthStart(month) }
    private var summary: MonthlyReviewSummary { makeSummary() }
    private var reportText: String {
        let s = summary
        return "观盘 Pro · \(month) 月度投资复盘\n买入 \(s.buy.cny()) / 卖出到账 \(s.sell.cny()) / 净投入 \(s.netFlow.cny())\n已实现 \(s.realized.cny()) / 现金分红 \(s.cashDividend.cny()) / 记录费用 \(s.fee.cny())\n买入 \(s.buyCount) 笔 / 卖出 \(s.sellCount) 笔 / 操作日 \(s.operationDays.count) 天"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { month = Self.shift(month, by: -1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("上个月")
                        Spacer()
                        Text(month).font(.title3.weight(.semibold))
                        Spacer()
                        Button { month = Self.shift(month, by: 1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("下个月")
                    }
                }
                Section("本月流水") {
                    LabeledContent("已实现盈亏 + 现金分红", value: (summary.netResult).cny())
                    LabeledContent("记录费用", value: (summary.fee).cny())
                    LabeledContent("买入 / 卖出", value: "\(summary.buyCount) / \(summary.sellCount) 笔")
                    LabeledContent("买入金额", value: (summary.buy).cny())
                    LabeledContent("卖出到账", value: (summary.sell).cny())
                    LabeledContent("净外部投入", value: (summary.netFlow).cny())
                    if summary.cashDividend > 0 || summary.reinvestedDividend > 0 {
                        LabeledContent("现金分红 / 红利再投", value: "\(summary.cashDividend.cny()) / \(summary.reinvestedDividend.cny())")
                    }
                    LabeledContent("操作日期", value: "\(summary.operationDays.count) 天")
                }
                Section("已有全账户快照") {
                    if let start = summary.snapshotStart, let end = summary.snapshotEnd, start.id != end.id {
                        LabeledContent("快照区间", value: "\(start.date) → \(end.date)")
                        LabeledContent("资产变化", value: (summary.assetChange ?? 0).cny())
                        LabeledContent("扣除净外部投入后", value: (summary.adjustedChange ?? 0).cny())
                        Text("只使用本月已有快照及已记录外部资金流；这不是精确的市场收益归因。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("本月没有两条不同日期的全账户快照，不推算资产变化。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("复盘提示") {
                    ForEach(Array(summary.tips.enumerated()), id: \.offset) { _, tip in
                        Label(tip, systemImage: tip.hasPrefix("提醒") ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.subheadline)
                    }
                }
                Section {
                    Text("复盘只汇总本机已有的交易、分红、资金流和快照，不反推缺失的月末持仓或收益，也不修改账本。费用不再从已实现盈亏中重复扣除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("月度投资复盘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: reportText) { Image(systemName: "square.and.arrow.up") } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func makeSummary() -> MonthlyReviewSummary {
        var result = MonthlyReviewSummary()
        let ledgerRows = store.data.ledger.filter { ($0.kind ?? .etf) != .fund && day($0.date) >= monthStart && day($0.date) < nextMonthStart }
        for trade in ledgerRows {
            result.fee += trade.fee
            result.operationDays.insert(day(trade.date))
            var row = result.tradedCodes[trade.code] ?? (trade.name, false, false)
            if trade.side == .buy {
                result.buy += trade.gross + trade.fee
                result.buyCount += 1
                row.bought = true
            } else {
                result.sell += max(0, trade.gross - trade.fee)
                result.realized += trade.realizedPnL
                result.sellCount += 1
                row.sold = true
            }
            result.tradedCodes[trade.code] = row
        }

        let fundRows = store.data.fundTransactions.filter {
            $0.requestDate >= monthStart && $0.requestDate < nextMonthStart && $0.status == .confirmed
        }
        for trade in fundRows {
            switch trade.side {
            case .buy where !trade.isBackfill:
                result.buy += trade.amount + trade.fee
                result.fee += trade.fee
                result.buyCount += 1
                result.operationDays.insert(trade.requestDate)
                var row = result.tradedCodes[trade.code] ?? (trade.name, false, false)
                row.bought = true; result.tradedCodes[trade.code] = row
            case .sell:
                result.sell += max(0, trade.amount - trade.fee)
                result.fee += trade.fee
                result.realized += trade.realizedPnL
                result.sellCount += 1
                result.operationDays.insert(trade.requestDate)
                var row = result.tradedCodes[trade.code] ?? (trade.name, false, false)
                row.sold = true; result.tradedCodes[trade.code] = row
            case .dividend:
                if trade.dividendMode == .cash { result.cashDividend += trade.amount }
                else if trade.dividendMode == .reinvest { result.reinvestedDividend += trade.amount }
                result.operationDays.insert(trade.requestDate)
            default: break
            }
        }

        result.netFlow = store.data.cashFlows.reduce(0) { partial, flow in
            let flowDay = day(flow.date)
            guard flowDay >= monthStart, flowDay < nextMonthStart, flow.external ?? true else { return partial }
            return partial + flow.amount
        }
        // Off-account subscriptions/redemptions are external flows. Automatic DCA
        // is already represented by its dedicated CashFlow record, so skip it here.
        for trade in fundRows where !trade.linkedCash && !trade.isBackfill && trade.isAutomaticDCA != true {
            if trade.side == .buy { result.netFlow += trade.amount }
            else if trade.side == .sell { result.netFlow -= max(0, trade.amount - trade.fee) }
        }

        let snapshots = store.data.snapshots.filter { $0.date >= monthStart && $0.date < nextMonthStart }.sorted { $0.date < $1.date }
        result.snapshotStart = snapshots.first
        result.snapshotEnd = snapshots.last
        if let start = result.snapshotStart, let end = result.snapshotEnd, start.id != end.id {
            result.snapshotNetFlow = store.data.cashFlows.reduce(0) { partial, flow in
                let flowDay = day(flow.date)
                guard flowDay > start.date, flowDay <= end.date, flow.external ?? true else { return partial }
                return partial + flow.amount
            }
            for trade in fundRows where trade.requestDate > start.date && trade.requestDate <= end.date
                && !trade.linkedCash && !trade.isBackfill && trade.isAutomaticDCA != true {
                if trade.side == .buy { result.snapshotNetFlow += trade.amount }
                else if trade.side == .sell { result.snapshotNetFlow -= max(0, trade.amount - trade.fee) }
            }
        }
        let operations = result.buyCount + result.sellCount
        if operations >= 12 { result.tips.append("提醒：本月有 \(operations) 笔买卖，检查是否都符合原计划。") }
        else if operations > 0 { result.tips.append("本月有 \(operations) 笔买卖，分布在 \(result.operationDays.count) 个记录日期。") }
        else { result.tips.append("本月没有买卖流水。") }
        let roundTrips = result.tradedCodes.values.filter { $0.bought && $0.sold }.map(\.name)
        if !roundTrips.isEmpty { result.tips.append("提醒：本月既买又卖：\(roundTrips.prefix(4).joined(separator: "、"))；可核对是否按原计划执行。") }
        if result.fee > 10 && result.fee > max(1, abs(result.netResult)) * 0.25 {
            result.tips.append("提醒：本月记录费用 \(result.fee.cny())，相对已实现收益和现金分红偏高。")
        }
        if snapshots.count < 2 { result.tips.append("提醒：本月全账户快照少于两条，无法可靠比较资产变化。") }
        return result
    }

    private func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func monthString(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func nextMonthStart(_ month: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: "\(month)-01"),
              let next = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: date) else { return "9999-12-31" }
        return formatter.string(from: next)
    }

    private static func shift(_ month: String, by amount: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: "\(month)-01"),
              let shifted = Calendar(identifier: .gregorian).date(byAdding: .month, value: amount, to: date) else { return month }
        return monthString(shifted)
    }
}
