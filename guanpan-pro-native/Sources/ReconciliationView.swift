import SwiftUI

struct ReconciliationView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var brokerCash = ""
    @State private var brokerDayPnL = ""
    @State private var brokerTotalPnL = ""
    @State private var costTarget: Holding?
    private var marketDay: String {
        let dates = store.data.quotes.compactMap(\.updatedAt) + store.data.holdings.compactMap(\.marketUpdatedAt)
        if let latest = dates.max() { return dayString(latest) }
        if let latestFundDay = store.data.fundNAVHistory.map(\.date).max() { return latestFundDay }
        return dayString(.now)
    }

    private var cashFlowTotal: Double {
        store.data.cashFlows.filter { $0.affectsCash != false }.reduce(0) { $0 + $1.amount }
    }
    private var linkedTradeCashDelta: Double {
        store.data.ledger.filter(\.linkedCash).reduce(0) { total, entry in
            total + (entry.side == .buy ? -(entry.gross + entry.fee) : entry.gross - entry.fee)
        }
    }
    private var dayRows: [(Holding, Double?)] {
        var holdings = store.data.holdings
        let heldCodes = Set(holdings.filter { $0.kind == .etf }.map(\.code))
        let soldOnlyCodes = Set(store.data.ledger.filter {
            $0.kind != .fund && dayString($0.date) == marketDay
        }.map(\.code)).subtracting(heldCodes)
        for code in soldOnlyCodes {
            let quote = store.data.quotes.first { $0.code == code }
            holdings.append(Holding(code: code, name: quote?.name ?? code, quantity: 0,
                                    cost: 0, current: quote?.price ?? 0, kind: .etf))
        }
        return holdings.map { holding in (holding, dailyPnL(for: holding)) }
    }
    private var estimatedDayPnL: Double? {
        guard !dayRows.isEmpty, dayRows.allSatisfy({ $0.1 != nil }) else { return nil }
        return dayRows.reduce(0) { $0 + ($1.1 ?? 0) }
    }

    private func dailyPnL(for holding: Holding) -> Double? {
        if holding.kind == .fund {
            let points = store.data.fundNAVHistory.filter { $0.code == holding.code && $0.nav > 0 }
                .sorted { $0.date > $1.date }
            guard points.count >= 2 else { return nil }
            return holding.quantity * (points[0].nav - points[1].nav)
        }
        let quote = store.data.quotes.first { $0.code == holding.code }
        let manual = store.data.manualQuoteOverrides[holding.code]
        let current = manual?.price ?? quote?.price ?? holding.current
        let previous: Double?
        if let manualPrevious = manual?.previousClose, manualPrevious > 0 {
            previous = manualPrevious
        } else if let quote, quote.changePct.isFinite, quote.changePct > -1 {
            previous = quote.price / (1 + quote.changePct)
        } else if let change = store.marketChanges[holding.code], change.isFinite, change > -1, current > 0 {
            previous = current / (1 + change)
        } else {
            previous = nil
        }
        guard let previous, previous.isFinite, previous > 0, current.isFinite, current > 0 else { return nil }
        let trades = store.data.ledger.filter {
            $0.code == holding.code && $0.kind != .fund && dayString($0.date) == marketDay
        }
        let buys = trades.filter { $0.side == .buy }
        let sells = trades.filter { $0.side == .sell }
        let buyQuantity = buys.reduce(0) { $0 + $1.quantity }
        let sellQuantity = sells.reduce(0) { $0 + $1.quantity }
        let buyGross = buys.reduce(0) { $0 + $1.gross }
        let sellGross = sells.reduce(0) { $0 + $1.gross }
        let floating = (current - previous) * holding.quantity
        switch store.data.dailyPnLMode {
        case .float:
            return floating
        case .pnl, .today:
            return floating + sells.reduce(0) { $0 + $1.realizedPnL }
        case .open:
            return (current - previous) * max(0, holding.quantity + sellQuantity - buyQuantity)
        case .ths:
            let openingQuantity = max(0, holding.quantity + sellQuantity - buyQuantity)
            return current * holding.quantity + sellGross - buyGross - previous * openingQuantity
        case .old:
            return floating + sells.reduce(0) { $0 + ($1.price - previous) * $1.quantity }
        }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    /// 填了券商金额才判色：一致=蓝绿，有差额=琥珀，没填=中性。
    private var cashTone: Color? {
        guard let broker = Double(brokerCash), broker.isFinite else { return nil }
        return abs(store.data.cash - broker) < 0.005 ? CardTone.ok : CardTone.warn
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
            List {
                cashSection
                dayPnLSection
                costSection
                totalPnLSection
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("账务对账")
            .keyboardDoneToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $costTarget) { CostOverrideEditor(holding: $0) .themedSheetBackground() }
        }
    }

    // 各分区拆成独立视图表达式；Section 的闭包内容再抽一层属性，
    // 否则编译器会把 Section 匹配到 SwiftUI 的 Table 版初始化器（@TableRowBuilder），
    // 报 "generic parameter 'V' could not be inferred"。

    @ViewBuilder private var cashSection: some View {
        Section("现金对账") { cashSectionBody }
            .toneCard(cashTone, isLight: isLight)
    }

    @ViewBuilder private var cashSectionBody: some View {
        LabeledContent("原生账本现金", value: (store.data.cash).cny())
        LabeledContent("账本现金流水净额", value: (cashFlowTotal).cny())
        LabeledContent("联动成交净额", value: (linkedTradeCashDelta).cny())
        TextField("券商可用资金（元）", text: $brokerCash).keyboardType(.decimalPad)
        brokerCashCompare
        Text("下方按流水拆分现金变化，帮助定位差额；填写券商金额只用于对比，不会改账。")
            .font(.footnote).foregroundStyle(.secondary)
        ForEach(store.data.cashFlows.sorted { $0.date > $1.date }.prefix(8)) { flow in
            cashFlowRow(flow)
        }
        ForEach(store.data.ledger.filter(\.linkedCash).sorted { $0.date > $1.date }.prefix(8)) { entry in
            ledgerRow(entry)
        }
    }

    @ViewBuilder private var brokerCashCompare: some View {
        if let broker = Double(brokerCash), broker.isFinite {
            let difference = store.data.cash - broker
            LabeledContent("观盘 − 券商", value: (difference).cny())
            Text(cashDifferenceText(difference))
                .font(.footnote).foregroundStyle(abs(difference) < 0.005 ? Color.secondary : CardTone.warn)
        }
    }

    private func cashFlowRow(_ flow: CashFlow) -> some View {
        HStack {
            Text(flow.memo.isEmpty ? "现金流水" : flow.memo)
            Spacer()
            Text((flow.amount).cny())
        }.font(.caption)
    }

    private func ledgerRow(_ entry: LedgerEntry) -> some View {
        let delta = linkedCashDelta(entry)
        return HStack {
            Text("\(entry.side == .buy ? "买入" : "卖出") · \(entry.name)")
            Spacer()
            Text((delta).cny())
                .foregroundStyle(delta >= 0 ? .green : .primary)
        }.font(.caption)
    }

    private func linkedCashDelta(_ entry: LedgerEntry) -> Double {
        entry.side == .buy ? -(entry.gross + entry.fee) : entry.gross - entry.fee
    }

    @ViewBuilder private var dayPnLSection: some View {
        Section("当日盈亏对账") {
            LabeledContent("行情基准日", value: marketDay)
            Picker("计算口径", selection: Binding(get: { store.data.dailyPnLMode }, set: { store.data.dailyPnLMode = $0; store.save(label: "修改当日盈亏口径") })) {
                ForEach(DailyPnLMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            if let estimate = estimatedDayPnL {
                LabeledContent("\(store.data.dailyPnLMode.title)", value: (estimate).cny())
            } else {
                Text("行情涨跌数据不完整，暂时不能汇总当日盈亏。")
                    .foregroundStyle(.secondary)
            }
            TextField("券商显示的当日盈亏（元）", text: $brokerDayPnL).keyboardType(.decimalPad)
            if let broker = Double(brokerDayPnL), broker.isFinite, let estimate = estimatedDayPnL {
                LabeledContent("估算 − 券商", value: (estimate - broker).cny())
            }
            ForEach(Array(dayRows.enumerated()), id: \.offset) { row in
                HStack {
                    Text(row.element.0.name)
                    Spacer()
                    if let value = row.element.1 { Text((value).cny()) }
                    else { Text("缺行情").foregroundStyle(.secondary) }
                }.font(.caption)
            }
            Text("ETF 昨收优先取手填昨收，否则由行情现价和涨跌幅反推；同花顺口径按当日成交额，不扣手续费。基金只按最近两期已公布净值变化估算，可能滞后。旧网页的当日盈亏口径设置会迁入；不重建日内成交时点，结果可能与券商不同。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }

    @ViewBuilder private var costSection: some View {
        Section("成本对账") {
            ForEach(store.data.holdings) { holding in
                Button { costTarget = holding } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(holding.name).foregroundStyle(.primary)
                            Text("账本基准 \((holding.cost).num(6)) · 当前显示 \((store.displayedCost(for: holding)).num(6)) · \((holding.quantity).compactNum(4)) 份")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(holding.costOverride == nil ? "对齐" : "已锁定")
                            .font(.caption).foregroundStyle(holding.costOverride == nil ? .blue : .orange)
                    }
                }.buttonStyle(.plain)
            }
            Text("可用券商成本覆盖显示口径或取消覆盖。原始加权成本、成交流水和历史已实现盈亏不被改写。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }

    @ViewBuilder private var totalPnLSection: some View {
        Section("总盈亏对账") {
            LabeledContent("原生浮动盈亏", value: (store.totalPnL).cny())
            TextField("券商显示的总浮盈（元）", text: $brokerTotalPnL).keyboardType(.decimalPad)
            if let broker = Double(brokerTotalPnL), broker.isFinite {
                LabeledContent("原生 − 券商", value: (store.totalPnL - broker).cny())
            }
            ForEach(store.data.holdings.sorted { abs(store.holdingPnL($0)) > abs(store.holdingPnL($1)) }) { holding in
                HStack {
                    Text(holding.name)
                    Spacer()
                    Text((store.holdingPnL(holding)).cny())
                }.font(.caption)
            }
            Text("优先核对差异较大的持仓份额、成本和行情；此处只对比浮动盈亏，不包含已实现盈亏及外部现金流。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .toneCard(CardTone.pnl(store.totalPnL), isLight: isLight)
    }

    /// 差额文案用普通方法返回，避免在 ViewBuilder 的 if 分支里做赋值。
    private func cashDifferenceText(_ difference: Double) -> String {
        if abs(difference) < 0.005 { return "金额一致" }
        if difference > 0 { return "观盘现金较多；核对买入手续费、期初现金或可用/可取口径。" }
        return "观盘现金较少；核对卖出手续费、遗漏转入或现金流水。"
    }
}

private struct CostOverrideEditor: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(holding.name) {
                    LabeledContent("账本基准成本", value: (holding.cost).num(4))
                    TextField("券商显示成本", text: $value).keyboardType(.decimalPad)
                    Text("覆盖只影响原生显示成本和浮动盈亏，不改原始账本成本与卖出流水。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("保存成本覆盖") {
                    guard let number = Double(value), number.isFinite, number > 0 else { return }
                    store.setCostOverride(code: holding.code, kind: holding.kind, value: number)
                    dismiss()
                }.disabled(Double(value).map { !$0.isFinite || $0 <= 0 } ?? true)
                if holding.costOverride != nil {
                    Button("取消覆盖，恢复自动成本", role: .destructive) {
                        store.setCostOverride(code: holding.code, kind: holding.kind, value: nil)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("成本校准")
            .keyboardDoneToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { value = String(holding.costOverride ?? store.displayedCost(for: holding)) }
        }
    }
}
