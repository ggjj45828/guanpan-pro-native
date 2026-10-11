import SwiftUI

/// Explains snapshot based portfolio return without inventing daily price attribution.
struct ReturnSourceView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var toDate = Date.now

    private struct CodeBreakdown: Identifiable {
        let name: String
        let amount: Double
        var id: String { name }
    }

    private struct Breakdown {
        var start: PortfolioSnapshot?
        var end: PortfolioSnapshot?
        var flow = 0.0
        var account = 0.0
        var economic = 0.0
        var realized = 0.0
        var realizedETF = 0.0
        var realizedFund = 0.0
        var cashDividends = 0.0
        var reinvestedDividends = 0.0
        var fees = 0.0
        var buys = 0
        var sells = 0
        var perCode: [CodeBreakdown] = []
        var warnings: [String] = []
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    var body: some View {
        let result = calculate()
        let canCalculate = result.start != nil && result.end != nil
        NavigationStack {
            List {
                Section("区间") {
                    DatePicker("开始日期", selection: $fromDate, displayedComponents: .date)
                    DatePicker("结束日期", selection: $toDate, displayedComponents: .date)
                    HStack {
                        Button("本月") { fromDate = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now; toDate = .now }
                        Spacer()
                        Button("今年") { fromDate = Calendar.current.dateInterval(of: .year, for: .now)?.start ?? .now; toDate = .now }
                    }
                }
                .plainCard(isLight: isLight)
                if canCalculate {
                    Section("快照核算结果") {
                        if let start = result.start, let end = result.end {
                            LabeledContent("实际快照区间", value: "\(start.date) → \(end.date)")
                        }
                        LabeledContent("净外部投入", value: (result.flow).cny())
                        LabeledContent("扣除净投入后的账户变化", value: (result.account).cny())
                        LabeledContent("加回账外现金分红的经济收益",
                                       value: "\((result.economic).directionMark()) \((result.economic).cny())")
                            .foregroundStyle(PnLColor.of(result.economic))
                    }
                    .toneCard(CardTone.pnl(result.economic), isLight: isLight)
                } else {
                    Section("快照不足") {
                        ContentUnavailableView("此区间至少需要两个全账户快照", systemImage: "chart.xyaxis.line", description: Text("只会使用所选区间内实际存在的快照；不会按行情补造缺失日期。"))
                    }
                    .plainCard(isLight: isLight)
                }
                Section("流水解释") {
                    LabeledContent("卖出/赎回已实现盈亏", value: (result.realized).cny())
                    LabeledContent("场内已实现", value: (result.realizedETF).cny())
                    LabeledContent("基金已实现", value: (result.realizedFund).cny())
                    LabeledContent("现金分红（已加回收益）", value: (result.cashDividends).cny())
                    LabeledContent("红利再投资（不重复计收益）", value: (result.reinvestedDividends).cny())
                    LabeledContent("已记录交易费用", value: (result.fees).cny())
                    LabeledContent("交易笔数", value: "买入 \(result.buys) / 卖出 \(result.sells)")
                    if canCalculate {
                        let residual = result.economic - result.realized - result.cashDividends
                        LabeledContent("未单独归因的持仓变化", value: (residual).cny())
                    }
                }
                .toneCard(CardTone.pnl(result.realized), isLight: isLight)
                if !result.perCode.isEmpty {
                    Section("分标的已实现盈亏") {
                        ForEach(result.perCode) { item in
                            LabeledContent(item.name, value: (item.amount).cny())
                        }
                    }
                    .plainCard(isLight: isLight)
                }
                if !result.warnings.isEmpty {
                    Section("口径提示") { ForEach(result.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) } }
                        .toneCard(CardTone.warn, isLight: isLight)
                }
                Section {
                    Text("总收益由两端实际全账户快照和外部投入计算。汇率、ETF 折溢价、择时及持仓浮盈变化没有独立历史快照时，会留在“未单独归因的持仓变化”，不会伪造拆分。费用已经反映在快照净结果中，只单列展示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("收益来源拆解")
            .toolbarBackground(.hidden, for: .navigationBar)
            .themedSheetBackground()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func calculate() -> Breakdown {
        var r = Breakdown()
        let from = dateFormatter.string(from: min(fromDate, toDate))
        let to = dateFormatter.string(from: max(fromDate, toDate))
        let snapshots = store.data.snapshots.filter { from...to ~= $0.date }.sorted { $0.date < $1.date }
        if snapshots.count >= 2 {
            r.start = snapshots.first; r.end = snapshots.last
            if let start = r.start, let end = r.end {
                r.flow = store.data.cashFlows.filter { $0.external ?? true }.filter {
                    let day = dateFormatter.string(from: $0.date); return day > start.date && day <= end.date
                }.reduce(0) { $0 + $1.amount }
                let ledger = store.data.ledger.filter { $0.kind != .fund }
                for trade in ledger {
                    let day = dateFormatter.string(from: trade.date)
                    guard day > start.date && day <= end.date else { continue }
                    r.fees += trade.fee
                    switch trade.side {
                    case .buy:
                        r.buys += 1
                        if !trade.linkedCash { r.flow += trade.gross + trade.fee }
                    case .sell:
                        r.sells += 1
                        if !trade.linkedCash { r.flow -= max(0, trade.gross - trade.fee) }
                        r.realizedETF += trade.realizedPnL
                        r.perCode.append(CodeBreakdown(name: trade.name, amount: trade.realizedPnL))
                    }
                }
                for trade in store.data.fundTransactions {
                    guard trade.effectiveDate > start.date && trade.effectiveDate <= end.date else { continue }
                    r.fees += max(0, trade.fee)
                    switch trade.side {
                    case .buy:
                        if trade.isBackfill { continue }
                        r.buys += 1
                        if !(trade.isAutomaticDCA ?? false) && !trade.linkedCash { r.flow += trade.amount + trade.fee }
                    case .sell:
                        guard trade.status == .confirmed else { continue }
                        r.sells += 1
                        if !trade.linkedCash { r.flow -= max(0, trade.amount - trade.fee) }
                        r.realizedFund += trade.realizedPnL
                        r.perCode.append(CodeBreakdown(name: trade.name, amount: trade.realizedPnL))
                    case .dividend:
                        guard trade.status == .confirmed else { continue }
                        if trade.dividendMode == .cash && !trade.linkedCash { r.cashDividends += trade.amount }
                        else { r.reinvestedDividends += trade.amount }
                    }
                }
                r.realized = r.realizedETF + r.realizedFund
                r.economic = end.total - start.total - r.flow + r.cashDividends
                r.account = end.total - start.total - r.flow
                if start.date != from || end.date != to { r.warnings.append("实际快照为 \(start.date) → \(end.date)，与所选日期不同；计算按实际快照区间进行。") }
            }
        } else {
            r.warnings.append("区间内不足两个全账户快照；只能查看流水归因，不能计算完整区间收益。")
        }
        if store.data.holdings.contains(where: { $0.kind == .etf }) && store.data.ledger.contains(where: { $0.kind == nil }) {
            r.warnings.append("部分旧版交易流水没有资产类别，场内/基金代码相同的记录可能无法可靠区分。")
        }
        if r.start == nil || r.end == nil {
            let from = dateFormatter.string(from: min(fromDate, toDate))
            let to = dateFormatter.string(from: max(fromDate, toDate))
            let ledger = store.data.ledger.filter { trade in
                let day = dateFormatter.string(from: trade.date); return day >= from && day <= to
            }
            let funds = store.data.fundTransactions.filter { $0.effectiveDate >= from && $0.effectiveDate <= to }
            r.realizedETF = ledger.filter { $0.side == .sell }.reduce(0) { $0 + $1.realizedPnL }
            r.realizedFund = funds.filter { $0.side == .sell && $0.status == .confirmed }.reduce(0) { $0 + $1.realizedPnL }
            r.realized = r.realizedETF + r.realizedFund
            r.cashDividends = funds.filter { $0.side == .dividend && $0.status == .confirmed && $0.dividendMode == .cash }.reduce(0) { $0 + $1.amount }
            r.reinvestedDividends = funds.filter { $0.side == .dividend && $0.status == .confirmed && $0.dividendMode == .reinvest }.reduce(0) { $0 + $1.amount }
            r.fees = ledger.reduce(0) { $0 + $1.fee } + funds.reduce(0) { $0 + max(0, $1.fee) }
            r.buys = ledger.filter { $0.side == .buy }.count + funds.filter { $0.side == .buy && !$0.isBackfill }.count
            r.sells = ledger.filter { $0.side == .sell }.count + funds.filter { $0.side == .sell && $0.status == .confirmed }.count
            r.perCode = ledger.filter { $0.side == .sell }.map { CodeBreakdown(name: $0.name, amount: $0.realizedPnL) }
                + funds.filter { $0.side == .sell && $0.status == .confirmed }.map { CodeBreakdown(name: $0.name, amount: $0.realizedPnL) }
        }
        r.perCode = Dictionary(grouping: r.perCode, by: \.name).map { pair in
            CodeBreakdown(name: pair.key, amount: pair.value.reduce(0) { $0 + $1.amount })
        }.sorted { abs($0.amount) > abs($1.amount) }
        return r
    }
}
