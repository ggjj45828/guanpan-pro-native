import SwiftUI

struct FundReconciliationView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let fund: Holding

    private var transactions: [FundTransaction] {
        store.data.fundTransactions.filter { $0.code == fund.code }
            .sorted { left, right in
                if left.effectiveDate != right.effectiveDate { return left.effectiveDate < right.effectiveDate }
                return order(left) < order(right)
            }
    }
    private var confirmed: [FundTransaction] { transactions.filter { $0.status == .confirmed } }
    private var ledgerShares: Double {
        confirmed.reduce(0) { total, trade in
            switch trade.side {
            case .buy: return total + trade.quantity
            case .sell: return total - trade.quantity
            case .dividend: return total + (trade.dividendMode == .reinvest ? trade.quantity : 0)
            }
        }
    }
    private var difference: Double { fund.quantity - ledgerShares }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section("份额对比") {
                    LabeledContent("当前持仓", value: (fund.quantity).num(4))
                    LabeledContent("已确认流水净份额", value: (ledgerShares).num(4))
                    LabeledContent("持仓减流水", value: (difference).num(4))
                    LabeledContent("待确认记录", value: "\(transactions.filter { $0.status == .pending }.count) 笔")
                    if abs(difference) <= 0.01 {
                        Label("当前份额与已确认流水基本一致", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CardTone.ok)
                    } else {
                        Label("份额存在差异", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(CardTone.warn)
                        Text("差额可能来自未录入的历史老仓、手动修改、缺失流水或待确认记录。请先核对原始记录。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .toneCard(abs(difference) <= 0.01 ? CardTone.ok : CardTone.warn, isLight: isLight)
                Section("流水明细") {
                    if transactions.isEmpty {
                        ContentUnavailableView("没有基金流水", systemImage: "list.bullet.rectangle")
                    } else {
                        ForEach(transactions.reversed()) { trade in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(trade))
                                    Text("申请 \(trade.requestDate) · 确认日 \(trade.effectiveDate)\(trade.status == .pending ? " · 待确认" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text((signedShares(trade)).num(4))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .plainCard(isLight: isLight)
                Section {
                    Text("此页只读核对已确认流水的份额加总，不会修改持仓、成本、现金或基金批次。历史起点补录会计入流水；现金分红不改变份额，红利再投会增加份额。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("基金流水核对")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func order(_ trade: FundTransaction) -> Int {
        switch trade.side { case .buy, .dividend: return 0; case .sell: return 1 }
    }

    private func title(_ trade: FundTransaction) -> String {
        switch trade.side {
        case .buy: return trade.isBackfill ? "历史起点补录" : (trade.isAutomaticDCA == true ? "自动定投" : "申购")
        case .sell: return "赎回"
        case .dividend: return trade.dividendMode == .reinvest ? "红利再投资" : "现金分红"
        }
    }

    private func signedShares(_ trade: FundTransaction) -> Double {
        guard trade.status == .confirmed else { return 0 }
        switch trade.side {
        case .buy: return trade.quantity
        case .sell: return -trade.quantity
        case .dividend: return trade.dividendMode == .reinvest ? trade.quantity : 0
        }
    }
}
