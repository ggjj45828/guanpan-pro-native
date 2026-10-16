import SwiftUI

// MARK: - 入口寻址

/// 「打开某个标的的明细」用的轻量引用。
///
/// 持仓卡用得上，交易流水页也用得上 —— 后者可能指向一只**已经移出持仓**的基金
/// （没有 `Holding`，但流水还留着），所以不能把 `Holding` 当唯一入口参数。
struct InstrumentRef: Identifiable {
    let code: String
    let kind: Holding.Kind
    let name: String
    var id: String { "\(kind.rawValue)-\(code)" }
}

// MARK: - 单标的明细

/// 单个标的的完整明细 —— 买入 / 卖出、数量、金额、税费、分红，以及**做 T** 统计。
///
/// **为什么要有这一页**：在此之前，App 里只有「全部交易流水」一条大列表，按时间把所有标的
/// 混在一起。想知道「我在这只上总共投了多少钱、交了多少费、做 T 到底赚没赚」，只能自己拿
/// 计算器加。用户原话：「少了单个标的的明细，就是买入卖出 金额数量 税费 做 t 这些」。
///
/// 数据口径（全部来自本机已记录的流水，**不联网、不插值、不估算**）：
///   · 场内（ETF / 个股）：`data.ledger` 里 code 命中的条目（`kind == nil` 视为场内旧数据）。
///   · 场外（基金）：`data.fundTransactions` 的申购 / 赎回 / 分红 / 红利再投。
///   · 已实现盈亏：场内直接汇总 `realizedPnL`；场外沿用 `ArchivedFundHistoryView` 的既有口径
///     （`ledger(kind == .fund)` 的 `realizedPnL` + 已确认现金分红），保证两页数字对得上。
///   · **做 T = 同一天既买又卖**：取 `min(当日买入份额, 当日卖出份额)` 配对，价差按
///     「当日买入含费均价」与「当日卖出净价」算。判据是**价差**、不是趋势 ——
///     与盘中陪伴同一口径（见 `IntradayCompanionStore`）。
struct InstrumentDetailView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    let code: String
    let kind: Holding.Kind
    let name: String

    /// 场内按分钟排序；场外的 `effectiveDate` 只到日，补 `00:00` 让两种行共用同一个排序键。
    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var holding: Holding? {
        store.data.holdings.first { $0.code == code && $0.kind == kind }
    }

    /// 名称兜底：持仓 → 流水 → 代码本身，避免出现「某只标的」这种没有名字的标题。
    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let held = holding { return held.name }
        if let tx = store.data.fundTransactions.first(where: { $0.code == code && !$0.name.isEmpty }) { return tx.name }
        if let entry = store.data.ledger.first(where: { $0.code == code && !$0.name.isEmpty }) { return entry.name }
        return code
    }

    private var accent: Color { holdingKindAccent(kind) }

    // MARK: 统一成交行

    /// 场内的 `LedgerEntry` 与场外的 `FundTransaction` 字段名完全不同，
    /// 先归一化成同一种行，界面只画一次 —— 否则两套行会慢慢长歪。
    struct TradeRow: Identifiable {
        enum Side: String {
            case buy = "买入"
            case sell = "卖出"
            case dividend = "现金分红"
            case reinvest = "红利再投"
        }

        let id: String
        /// `yyyy-MM-dd HH:mm`，纯字符串排序（跨越场内/场外两种数据源都不用解析日期）。
        let sortKey: String
        let dayKey: String
        let monthKey: String
        let dateText: String
        let side: Side
        let quantity: Double
        let price: Double
        /// 成交金额（**不含**费用）。
        let amount: Double
        let fee: Double
        let realizedPnL: Double
        let note: String

        var isBuy: Bool { side == .buy }
        var isSell: Bool { side == .sell }
        var isCashDividend: Bool { side == .dividend }
    }

    private var rows: [TradeRow] {
        kind == .fund ? fundRows : etfRows
    }

    private var etfRows: [TradeRow] {
        store.data.ledger
            .filter { $0.code == code && ($0.kind ?? .etf) == .etf }
            .map { entry in
                let key = Self.minuteFormatter.string(from: entry.date)
                let day = String(key.prefix(10))
                var note = ""
                if entry.affectsHoldings == false {
                    note = "导入的历史流水（不影响当前持仓与现金）"
                } else if !entry.linkedCash {
                    note = "未联动现金"
                }
                return TradeRow(id: entry.id.uuidString, sortKey: key, dayKey: day,
                                monthKey: String(day.prefix(7)), dateText: key,
                                side: entry.side == .buy ? .buy : .sell,
                                quantity: entry.quantity, price: entry.price,
                                amount: entry.gross, fee: entry.fee,
                                realizedPnL: entry.realizedPnL, note: note)
            }
    }

    private var fundRows: [TradeRow] {
        store.data.fundTransactions
            .filter { $0.code == code }
            .map { tx in
                let day = String(tx.effectiveDate.prefix(10))
                let side: TradeRow.Side
                switch tx.side {
                case .buy: side = .buy
                case .sell: side = .sell
                case .dividend: side = tx.dividendMode == .reinvest ? .reinvest : .dividend
                }
                var notes: [String] = []
                if tx.status == .pending { notes.append("待确认") }
                if tx.isBackfill { notes.append("历史起点补录") }
                if tx.feeWasEstimated == true { notes.append("费用为估算") }
                return TradeRow(id: tx.id.uuidString, sortKey: day + " 00:00", dayKey: day,
                                monthKey: String(day.prefix(7)), dateText: day,
                                side: side, quantity: tx.quantity, price: tx.nav,
                                amount: tx.amount, fee: tx.fee,
                                realizedPnL: tx.realizedPnL,
                                note: notes.isEmpty ? "" : notes.joined(separator: " · "))
            }
    }

    private var sortedRows: [TradeRow] {
        rows.sorted { $0.sortKey > $1.sortKey }
    }

    // MARK: 累计汇总

    private struct Totals {
        var buyCount = 0, sellCount = 0, cashDividendCount = 0, reinvestCount = 0
        var buyQuantity = 0.0, sellQuantity = 0.0
        var buyAmount = 0.0, sellAmount = 0.0
        var buyFee = 0.0, sellFee = 0.0
        var cashDividend = 0.0, reinvestAmount = 0.0

        /// 含费买入成本 —— 真正从口袋里出去的钱。
        var buyCost: Double { buyAmount + buyFee }
        /// 扣掉卖出费之后拿回来的钱。
        var sellNet: Double { sellAmount - sellFee }
        /// 净压在这只上的钱 = 买入含费 − 卖出净额 − 已收到的现金分红。
        /// 红利再投不算回款（那笔钱没回来，只是换成了份额），所以不参与减法。
        var netInvested: Double { buyCost - sellNet - cashDividend }
        var totalFee: Double { buyFee + sellFee }
    }

    private var totals: Totals {
        var t = Totals()
        for row in rows {
            switch row.side {
            case .buy:
                t.buyCount += 1; t.buyQuantity += row.quantity
                t.buyAmount += row.amount; t.buyFee += row.fee
            case .sell:
                t.sellCount += 1; t.sellQuantity += row.quantity
                t.sellAmount += row.amount; t.sellFee += row.fee
            case .dividend:
                t.cashDividendCount += 1; t.cashDividend += row.amount
            case .reinvest:
                t.reinvestCount += 1; t.reinvestAmount += row.amount
            }
        }
        return t
    }

    /// 已实现盈亏：场外按 `ArchivedFundHistoryView` 的既有口径，场内直接汇总。
    private var realizedPnL: Double {
        if kind == .fund {
            let ledgerPart = store.data.ledger
                .filter { $0.code == code && $0.kind == .fund }
                .reduce(0.0) { $0 + $1.realizedPnL }
            let dividendPart = store.data.fundTransactions
                .filter { $0.code == code && $0.side == .dividend && $0.status == .confirmed }
                .reduce(0.0) { $0 + $1.amount }
            return ledgerPart + dividendPart
        }
        return rows.reduce(0.0) { $0 + $1.realizedPnL }
    }

    // MARK: 做 T

    /// 一天之内既买又卖的那部分算做 T。`quantity` 是配对份额，
    /// `excessSell` 是当天超出买入的卖出份额 —— 那部分属于**减仓**，不是做 T。
    struct TDay: Identifiable {
        let id: String
        let dayKey: String
        let quantity: Double
        let buyCostPerShare: Double
        let sellNetPerShare: Double
        let profit: Double
        let excessSell: Double
        var isProfit: Bool { profit > 0.005 }
    }

    private var tDays: [TDay] {
        let trades = rows.filter { $0.isBuy || $0.isSell }
        guard !trades.isEmpty else { return [] }
        let grouped = Dictionary(grouping: trades, by: \.dayKey)
        var out: [TDay] = []
        for (day, items) in grouped {
            let buys = items.filter(\.isBuy)
            let sells = items.filter(\.isSell)
            guard !buys.isEmpty, !sells.isEmpty else { continue }
            let buyQuantity = buys.reduce(0.0) { $0 + $1.quantity }
            let sellQuantity = sells.reduce(0.0) { $0 + $1.quantity }
            guard buyQuantity > 0.000_001, sellQuantity > 0.000_001 else { continue }
            let buyCost = buys.reduce(0.0) { $0 + $1.amount } + buys.reduce(0.0) { $0 + $1.fee }
            let sellNet = sells.reduce(0.0) { $0 + $1.amount } - sells.reduce(0.0) { $0 + $1.fee }
            let matched = min(buyQuantity, sellQuantity)
            let costPerShare = buyCost / buyQuantity
            let netPerShare = sellNet / sellQuantity
            out.append(TDay(id: day, dayKey: day, quantity: matched,
                            buyCostPerShare: costPerShare, sellNetPerShare: netPerShare,
                            profit: matched * (netPerShare - costPerShare),
                            excessSell: max(0, sellQuantity - buyQuantity)))
        }
        return out.sorted { $0.dayKey > $1.dayKey }
    }

    private var tQuantityTotal: Double { tDays.reduce(0.0) { $0 + $1.quantity } }
    private var tProfitTotal: Double { tDays.reduce(0.0) { $0 + $1.profit } }
    private var tWinDays: Int { tDays.filter(\.isProfit).count }

    // MARK: 按月分组

    struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let rows: [TradeRow]
        let summary: String
    }

    private var months: [MonthGroup] {
        let grouped = Dictionary(grouping: sortedRows, by: \.monthKey)
        var out: [MonthGroup] = []
        // `sorted(by:)` 不写在 `for ... in` 里：紧跟其后的循环体花括号会被自检脚本
        // 误当成它的尾随闭包（同族误报，见本文件 `months` 的注释）。
        let keysDescending = grouped.keys.sorted(by: >)
        for key in keysDescending {
            let monthRows = grouped[key] ?? []
            let buys = monthRows.filter(\.isBuy)
            let sells = monthRows.filter(\.isSell)
            let fee = monthRows.reduce(0.0) { $0 + $1.fee }
            var parts: [String] = []
            if !buys.isEmpty {
                parts.append("买入 \(buys.count) 笔 \((buys.reduce(0.0) { $0 + $1.quantity }).compactNum(4)) 份")
            }
            if !sells.isEmpty {
                parts.append("卖出 \(sells.count) 笔 \((sells.reduce(0.0) { $0 + $1.quantity }).compactNum(4)) 份")
            }
            let others = monthRows.count - buys.count - sells.count
            if others > 0 { parts.append("分红 / 其它 \(others) 笔") }
            if fee > 0.005 { parts.append("费用 \((fee).cny())") }
            // 排序先落成局部量再塞进 `append` —— 排序闭包直接写在 `append(...)` 的实参位置时，
            // 自检脚本 `_check_closures.py` 会把它当成「闭包末条缺 return」（同族误报），
            // 与其加到误报基线里，不如把闭包挪出来。
            let monthRowsSorted = monthRows.sorted { $0.sortKey > $1.sortKey }
            out.append(MonthGroup(id: key, title: Self.monthTitle(key),
                                  rows: monthRowsSorted,
                                  summary: parts.joined(separator: " · ")))
        }
        return out
    }

    private static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        return "\(parts[0]) 年 \(month) 月"
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                if let holding { holdingSection(holding) }
                totalsSection
                doingTSection
                ForEach(months) { group in
                    Section {
                        ForEach(group.rows) { row in rowView(row) }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text(group.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if rows.isEmpty { Section { Text("这只标的还没有任何已记录的流水").foregroundStyle(.secondary) } }
                notesSection
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .listRowBackground(Color.clear)
            .background(.clear)
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.palette(for: store.resolvedAppearance).surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    // MARK: 持仓概览

    @ViewBuilder private func holdingSection(_ holding: Holding) -> some View {
        Section("当前持仓") {
            LabeledContent("类型") {
                Text(kind == .fund ? "场外基金" : "场内（ETF / 个股）")
                    .foregroundStyle(accent)
            }
            // 成本走 `displayedCost` —— 卡片上的「持有收益」用的就是它（含摊薄口径与人工覆盖），
            // 这里若直接用 `holding.cost`，同一只标的在列表和明细页会出现两个持有收益。
            let unitCost = store.displayedCost(for: holding)
            LabeledContent("份额", value: "\(holding.quantity.compactNum(4)) 份")
            LabeledContent("持仓成本", value: "\(unitCost.num(kind == .fund ? 4 : 3)) 元/份")
            LabeledContent("现价" + (kind == .fund ? "（最新净值）" : ""),
                           value: "\(holding.current.num(kind == .fund ? 4 : 3))")
            LabeledContent("市值", value: holding.marketValue.cny())
            let pnl = holding.quantity * (holding.current - unitCost)
            LabeledContent("浮动盈亏") {
                Text("\(pnl.directionMark()) \(pnl.cny())")
                    .foregroundStyle(PnLColor.of(pnl))
            }
            LabeledContent("占总资产", value: store.allocationActualPercent(for: holding).pct(1))
            if let target = store.data.allocationTargets
                .first(where: { $0.code == holding.code && $0.kind == holding.kind })?.targetPercent {
                LabeledContent("目标仓位", value: target.pct(1))
            }
        }
    }

    // MARK: 累计

    private var totalsSection: some View {
        Section("累计（全部已记录流水）") {
            let t = totals
            if t.buyCount > 0 {
                LabeledContent("累计买入", value: "\(t.buyCount) 笔 · \(t.buyQuantity.compactNum(4)) 份")
                LabeledContent("买入金额", value: t.buyAmount.cny())
            }
            if t.sellCount > 0 {
                LabeledContent("累计卖出", value: "\(t.sellCount) 笔 · \(t.sellQuantity.compactNum(4)) 份")
                LabeledContent("卖出金额", value: t.sellAmount.cny())
            }
            if t.cashDividendCount > 0 {
                LabeledContent("现金分红", value: "\(t.cashDividendCount) 笔 · \((t.cashDividend).cny())")
            }
            if t.reinvestCount > 0 {
                LabeledContent("红利再投", value: "\(t.reinvestCount) 笔 · \((t.reinvestAmount).cny())")
            }
            LabeledContent("买入费用", value: t.buyFee.cny())
            LabeledContent("卖出费用", value: t.sellFee.cny())
            LabeledContent("费用合计") {
                Text(t.totalFee.cny())
                    .foregroundStyle(t.totalFee > 0.005 ? CardTone.warn : Color.primary)
            }
            LabeledContent("净投入（含费买 − 卖出净额 − 现金分红）", value: t.netInvested.cny())
            LabeledContent("已实现盈亏") {
                Text("\(realizedPnL.directionMark()) \(realizedPnL.cny())")
                    .foregroundStyle(PnLColor.of(realizedPnL))
            }
        }
    }

    // MARK: 做 T

    private var doingTSection: some View {
        Section("做 T（同一天既买又卖的那部分）") {
            if tDays.isEmpty {
                Text("还没有做过 T。买入与卖出落在同一天，才会被算成做 T；跨日的买卖属于建仓 / 减仓。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                LabeledContent("做 T 天数", value: "\(tDays.count) 天（其中 \(tWinDays) 天赚、\(tDays.count - tWinDays) 天亏）")
                LabeledContent("累计做 T 份额", value: "\(tQuantityTotal.compactNum(4)) 份")
                LabeledContent("做 T 净收支") {
                    Text("\(tProfitTotal.directionMark()) \(tProfitTotal.cny())")
                        .foregroundStyle(PnLColor.of(tProfitTotal))
                }
                ForEach(tDays) { day in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(day.dayKey).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(day.profit.directionMark()) \(day.profit.cny())")
                                .font(.subheadline)
                                .foregroundStyle(PnLColor.of(day.profit))
                        }
                        Text("配对 \(day.quantity.compactNum(4)) 份 · 买入含费 \((day.buyCostPerShare).num(4)) → 卖出净 \((day.sellNetPerShare).num(4))")
                            .font(.caption).foregroundStyle(.secondary)
                        if day.excessSell > 0.000_001 {
                            Text("另有 \((day.excessSell).compactNum(4)) 份超出当日买入，属于减仓、不是做 T")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 明细行

    @ViewBuilder private func rowView(_ row: TradeRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.side.rawValue)
                    .scaledFont(9, weight: .bold)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(sideTone(row.side))
                    .background(Capsule().fill(sideTone(row.side).opacity(0.15)))
                Text(row.dateText).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(row.amount.cny()).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            let detail = "\(row.quantity.compactNum(4)) 份 × \(row.price.num(4)) · 费用 \(row.fee.cny())"
            Text(row.isCashDividend ? "金额 \(row.amount.cny()) · 费用 \(row.fee.cny())" : detail)
                .font(.caption).foregroundStyle(.secondary)
            if abs(row.realizedPnL) > 0.005 {
                Text("已实现盈亏 \(row.realizedPnL.directionMark()) \(row.realizedPnL.cny())")
                    .font(.caption).foregroundStyle(PnLColor.of(row.realizedPnL))
            }
            if !row.note.isEmpty {
                Text(row.note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func sideTone(_ side: TradeRow.Side) -> Color {
        switch side {
        case .buy: return PnLColor.up
        case .sell: return PnLColor.down
        case .dividend, .reinvest: return CardTone.accent
        }
    }

    // MARK: 口径说明

    private var notesSection: some View {
        Section {
            Text("「净投入」= 含费买入成本 − 卖出净额 − 已收到的现金分红。红利再投不算回款（钱没回来，只是换成了份额），所以不参与减法。")
            Text("「做 T 净收支」按当日买入含费均价与当日卖出净价算价差，只反映当天回转的那部分，不是这只标的的总收益。")
            Text("数据来自本机已记录的流水；费用是流水里记的值，不替券商估算。要改哪一笔，去「工具 → 全部交易流水」。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
