import SwiftUI

/// Reconstructs a historical ledger state by reversing later recorded trades.
/// Historical prices come only from cached observations at or before the date.
struct HistoricalReplayView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date.now

    private struct Position: Identifiable {
        var key: String
        var code: String
        var name: String
        var kind: Holding.Kind
        var quantity: Double
        var cost: Double
        var price: Double?
        var priceDate: String?
        var id: String { key }
        var value: Double? { price.map { quantity * $0 } }
    }

    private struct Replay {
        var positions: [Position]
        var cash: Double
        var cashKnown: Bool
        var snapshot: PortfolioSnapshot?
        var realizedETF: Double
        var realizedFund: Double
        var cashDividends: Double
        var fees: Double
        var laterBuys: Double
        var laterSells: Double
        var warnings: [String]
    }

    private var day: String { format(selectedDate) }
    private var replay: Replay { reconstruct() }
    private var valuedTotal: Double? {
        guard replay.cashKnown, replay.positions.allSatisfy({ $0.value != nil }) else { return nil }
        return replay.cash + replay.positions.reduce(0) { $0 + ($1.value ?? 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("回放日期") {
                    DatePicker("截至日期", selection: $selectedDate, in: ...Date.now, displayedComponents: .date)
                    if let snapshot = replay.snapshot {
                        LabeledContent("最近全账户快照", value: "\(snapshot.date) · \((snapshot.total).cny())")
                    } else {
                        Text("所选日期之前没有全账户快照。历史总资产不作为精确结果显示。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    LabeledContent("反推现金", value: replay.cashKnown ? replay.cash.cny() : "无法可靠反推")
                    LabeledContent("持仓市值合计", value: valuedTotal.map { $0 - replay.cash }.map { $0.cny() } ?? "历史行情不完整")
                    if let valuedTotal {
                        LabeledContent("回放估算总资产", value: (valuedTotal).cny())
                    }
                    Text("持仓份额和现金按所选日期之后的流水反推；估值使用该日或此前最近的本地日线/基金净值。此结果是历史重建估算，不代表当日快照。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("场内持仓") {
                    let rows = replay.positions.filter { $0.kind == .etf && $0.quantity > 1e-8 }
                    if rows.isEmpty { Text("该日没有可还原的场内持仓").foregroundStyle(.secondary) }
                    ForEach(rows) { positionRow($0) }
                }
                Section("场外基金") {
                    let rows = replay.positions.filter { $0.kind == .fund && $0.quantity > 1e-8 }
                    if rows.isEmpty { Text("该日没有可还原的基金持仓").foregroundStyle(.secondary) }
                    ForEach(rows) { positionRow($0) }
                }
                Section("该日累计流水") {
                    LabeledContent("场内已实现盈亏", value: (replay.realizedETF).cny())
                    LabeledContent("基金已实现盈亏", value: (replay.realizedFund).cny())
                    LabeledContent("现金分红", value: (replay.cashDividends).cny())
                    LabeledContent("已记录费用", value: (replay.fees).cny())
                    LabeledContent("此后买入金额", value: (replay.laterBuys).cny())
                    LabeledContent("此后卖出到账", value: (replay.laterSells).cny())
                }
                if !replay.warnings.isEmpty {
                    Section("还原限制") {
                        ForEach(replay.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("历史状态回放")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    @ViewBuilder private func positionRow(_ item: Position) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(item.name).font(.headline); Spacer(); Text((item.quantity).num(2)) }
            Text("\(item.code) · 成本 \((item.cost).num(4))")
                .font(.caption).foregroundStyle(.secondary)
            if let price = item.price, let priceDate = item.priceDate {
                Text("估值价 \((price).num(4))（\(priceDate)） · 市值 \(((item.value ?? 0)).cny())")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("所选日期之前没有本地历史价格，未用当前价格代替。").font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 3)
    }

    private func reconstruct() -> Replay {
        struct MutablePosition { var code: String; var name: String; var kind: Holding.Kind; var quantity: Double; var cost: Double }
        var positions: [String: MutablePosition] = [:]
        func key(_ kind: Holding.Kind, _ code: String) -> String { "\(kind.rawValue)|\(code)" }
        for holding in store.data.holdings {
            positions[key(holding.kind, holding.code)] = MutablePosition(code: holding.code, name: holding.name,
                kind: holding.kind, quantity: max(0, holding.quantity), cost: max(0, holding.cost))
        }
        let target = day
        let laterLedger = store.data.ledger.enumerated().filter { _, trade in trade.kind != .fund && format(trade.date) > target }
            .sorted { format($0.element.date) > format($1.element.date) }
        for (_, trade) in laterLedger {
            let kind = trade.kind ?? .etf, id = key(kind, trade.code)
            var p = positions[id] ?? MutablePosition(code: trade.code, name: trade.name, kind: kind, quantity: 0, cost: 0)
            let quantity = max(0, trade.quantity), gross = quantity * trade.price
            switch trade.side {
            case .buy:
                let previousQuantity = max(0, p.quantity - quantity)
                let previousCost = p.cost * p.quantity - gross - trade.fee
                p.quantity = previousQuantity
                p.cost = previousQuantity > 1e-8 ? max(0, previousCost) / previousQuantity : 0
            case .sell:
                let unitCost = quantity > 0 ? max(0, trade.price - (trade.realizedPnL + trade.fee) / quantity) : p.cost
                let totalCost = p.cost * p.quantity + unitCost * quantity
                p.quantity += quantity
                p.cost = p.quantity > 1e-8 ? totalCost / p.quantity : 0
            }
            positions[id] = p
        }
        let laterFundTrades = store.data.fundTransactions.filter { $0.effectiveDate > target && $0.status == .confirmed }
            .sorted { $0.effectiveDate > $1.effectiveDate }
        for trade in laterFundTrades {
            let id = key(.fund, trade.code)
            var p = positions[id] ?? MutablePosition(code: trade.code, name: trade.name, kind: .fund, quantity: 0, cost: 0)
            switch trade.side {
            case .buy:
                let quantity = max(0, trade.quantity)
                let previousQuantity = max(0, p.quantity - quantity)
                let addedCost = (trade.isAutomaticDCA ?? false) ? trade.amount : trade.amount + trade.fee
                let previousBasis = p.cost * p.quantity - addedCost
                p.quantity = previousQuantity
                p.cost = previousQuantity > 1e-8 ? max(0, previousBasis) / previousQuantity : 0
            case .sell:
                guard trade.status == .confirmed else { continue }
                let quantity = max(0, trade.quantity)
                let unitCost = quantity > 0 ? max(0, trade.nav - (trade.realizedPnL + trade.fee) / quantity) : p.cost
                let totalCost = p.cost * p.quantity + unitCost * quantity
                p.quantity += quantity
                p.cost = p.quantity > 1e-8 ? totalCost / p.quantity : 0
            case .dividend:
                guard trade.status == .confirmed, trade.dividendMode == .reinvest else { continue }
                let quantity = max(0, trade.quantity), previousQuantity = max(0, p.quantity - quantity)
                let previousBasis = p.cost * p.quantity - trade.amount
                p.quantity = previousQuantity
                p.cost = previousQuantity > 1e-8 ? max(0, previousBasis) / previousQuantity : 0
            }
            positions[id] = p
        }

        var cash = store.data.cash, cashKnown = true
        for flow in store.data.cashFlows where (flow.affectsCash ?? true) && format(flow.date) > target { cash -= flow.amount }
        for (_, trade) in laterLedger where trade.linkedCash {
            cash += trade.side == .buy ? trade.gross + trade.fee : -(trade.gross - trade.fee)
        }
        for trade in laterFundTrades where trade.linkedCash {
            switch trade.side {
            case .buy: cash += trade.amount + trade.fee
            case .sell: cash -= trade.amount - trade.fee
            case .dividend where trade.dividendMode == .cash: cash -= trade.amount
            case .dividend: break
            }
        }
        if cash < -0.01 || !cash.isFinite { cashKnown = false }; cash = max(0, cash)

        let rows = positions.values.filter { $0.quantity > 1e-8 }.map { p -> Position in
            let pricePoint: (Double, String)?
            if p.kind == .fund {
                pricePoint = store.data.fundNAVHistory.filter { $0.code == p.code && $0.date <= target }.max { $0.date < $1.date }.map { ($0.nav, $0.date) }
            } else {
                pricePoint = store.dailyBars[p.code]?.filter { $0.date <= target }.max { $0.date < $1.date }.map { ($0.close, $0.date) }
            }
            return Position(key: key(p.kind, p.code), code: p.code, name: p.name, kind: p.kind,
                quantity: p.quantity, cost: p.cost, price: pricePoint?.0, priceDate: pricePoint?.1)
        }.sorted { $0.kind == $1.kind ? $0.name < $1.name : $0.kind == .etf }

        let ledgerToDate = store.data.ledger.filter { $0.kind != .fund && format($0.date) <= target }
        let fundToDate = store.data.fundTransactions.filter { $0.effectiveDate <= target && $0.status == .confirmed }
        let snapshot = store.data.snapshots.filter { $0.date <= target }.max { $0.date < $1.date }
        var warnings: [String] = []
        if store.data.holdings.contains(where: { holding in
            holding.quantity > 0 && !store.data.ledger.contains(where: { $0.code == holding.code && $0.kind != .fund && $0.side == .buy })
        }) {
            warnings.append("部分当前手动持仓可能缺少买入起点流水，回放份额只按现有持仓和可见流水反推。")
        }
        if store.data.holdings.contains(where: { holding in
            holding.kind == .fund && holding.quantity > 0 && !store.data.fundTransactions.contains(where: { $0.code == holding.code && $0.side == .buy })
        }) {
            warnings.append("部分当前基金没有申购或历史起点记录，所选日期的基金份额和成本可能不完整。")
        }
        if store.data.fundTransactions.contains(where: { $0.side == .buy && $0.isBackfill && $0.effectiveDate > target }) {
            warnings.append("有基金历史起点补录日期晚于所选日；更早的基金份额无法完整核实。")
        }
        if !cashKnown { warnings.append("现金反推结果为负数或无效；可能缺少期初现金/现金流水记录。") }
        if snapshot == nil { warnings.append("所选日期前没有全账户快照，无法对比当时记录的总资产。") }
        if rows.contains(where: { $0.price == nil }) { warnings.append("部分持仓没有所选日之前的本地历史价格，因此总资产估值未完整显示。") }
        if store.data.ledger.contains(where: { $0.kind == nil }) { warnings.append("部分旧版交易流水没有资产类别，回放暂按场内证券处理。") }
        let realizedETF = ledgerToDate.filter { $0.side == .sell }.reduce(0) { $0 + $1.realizedPnL }
        let realizedFund = fundToDate.filter { $0.side == .sell }.reduce(0) { $0 + $1.realizedPnL }
        let cashDividends = fundToDate.filter { $0.side == .dividend && $0.dividendMode == .cash && !$0.linkedCash }.reduce(0) { $0 + $1.amount }
        let fees = ledgerToDate.reduce(0) { $0 + $1.fee } + fundToDate.reduce(0) { $0 + $1.fee }
        let laterBuys = store.data.ledger.filter { $0.kind != .fund && format($0.date) > target && $0.side == .buy }.reduce(0) { $0 + $1.gross + $1.fee }
            + laterFundTrades.filter { $0.side == .buy && !$0.isBackfill }.reduce(0) { $0 + $1.amount + (($1.isAutomaticDCA ?? false) ? 0 : $1.fee) }
        let laterSells = store.data.ledger.filter { $0.kind != .fund && format($0.date) > target && $0.side == .sell }.reduce(0) { $0 + max(0, $1.gross - $1.fee) }
            + laterFundTrades.filter { $0.side == .sell && $0.status == .confirmed }.reduce(0) { $0 + max(0, $1.amount - $1.fee) }
        if rows.contains(where: { position in
            position.kind == .fund && store.data.fundTransactions.contains(where: { $0.code == position.code && $0.isBackfill })
        }) {
            warnings.append("基金历史起点补录只提供份额基线，未记录的早期申购成本无法精确还原。")
        }
        return Replay(positions: rows, cash: cash, cashKnown: cashKnown, snapshot: snapshot,
            realizedETF: realizedETF, realizedFund: realizedFund, cashDividends: cashDividends,
            fees: fees, laterBuys: laterBuys, laterSells: laterSells, warnings: warnings)
    }

    private func format(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
