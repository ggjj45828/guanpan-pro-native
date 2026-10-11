import SwiftUI
import Charts

// MARK: - 区间流水聚合

/// 一个时间段内的流水汇总。
///
/// 口径与《月度投资复盘》完全一致（同一套过滤条件、同一套外部资金流判定），
/// 额外多了胜率、换手费率、按标的拆分的已实现盈亏——年度账单要看的东西比月度多。
/// 只汇总本机已有的记录，缺的月份就显示为空，不反推、不补造。
struct PeriodLedgerAggregate {
    var buy = 0.0
    var sell = 0.0
    var fee = 0.0
    var realized = 0.0
    var cashDividend = 0.0
    var reinvestedDividend = 0.0
    var netFlow = 0.0
    var buyCount = 0
    var sellCount = 0
    var winCount = 0
    var loseCount = 0
    var operationDays: Set<String> = []
    var realizedByCode: [String: RealizedRow] = [:]
    var snapshotStart: PortfolioSnapshot?
    var snapshotEnd: PortfolioSnapshot?
    var snapshotNetFlow = 0.0

    /// 已实现盈亏 + 现金分红
    var netResult: Double { realized + cashDividend }
    /// 卖出笔数里赚钱的比例；没有卖出记录时返回 nil（不是 0，0 会被误读成「全亏」）
    var winRate: Double? {
        let total = winCount + loseCount
        guard total > 0 else { return nil }
        return Double(winCount) / Double(total) * 100
    }
    /// 双边换手额
    var turnover: Double { buy + sell }
    /// 费用占换手额的比例
    var feeRate: Double? {
        guard turnover > 0 else { return nil }
        return fee / turnover * 100
    }
    var assetChange: Double? {
        guard let snapshotStart, let snapshotEnd, snapshotStart.id != snapshotEnd.id else { return nil }
        return snapshotEnd.total - snapshotStart.total
    }
    var adjustedChange: Double? { assetChange.map { $0 - snapshotNetFlow } }
    var operationCount: Int { buyCount + sellCount }
}

/// 单个标的在一段时期内的已实现盈亏
struct RealizedRow: Identifiable {
    var code: String
    var name: String
    var pnl: Double
    var id: String { code }
}

/// 逐月明细行（用结构体而不是元组，ForEach 才能用 KeyPath 取 id）
struct MonthAggregateRow: Identifiable {
    var month: String
    var aggregate: PeriodLedgerAggregate
    var id: String { month }
    /// 图表横轴只显示两位月份
    var label: String { String(month.suffix(2)) }
}

enum LedgerPeriodAggregator {
    static func aggregate(data: PortfolioData, from startDay: String, to endDay: String) -> PeriodLedgerAggregate {
        var result = PeriodLedgerAggregate()

        // —— 证券 / ETF 流水 ——
        let ledgerRows = data.ledger.filter {
            ($0.kind ?? .etf) != .fund && dayString($0.date) >= startDay && dayString($0.date) < endDay
        }
        for trade in ledgerRows {
            result.fee += trade.fee
            result.operationDays.insert(dayString(trade.date))
            if trade.side == .buy {
                result.buy += trade.gross + trade.fee
                result.buyCount += 1
            } else {
                result.sell += max(0, trade.gross - trade.fee)
                result.realized += trade.realizedPnL
                result.sellCount += 1
                if trade.realizedPnL > 0 { result.winCount += 1 }
                else if trade.realizedPnL < 0 { result.loseCount += 1 }
                var row = result.realizedByCode[trade.code] ?? RealizedRow(code: trade.code, name: trade.name, pnl: 0)
                row.pnl += trade.realizedPnL
                result.realizedByCode[trade.code] = row
            }
        }

        // —— 基金流水 ——
        let fundRows = data.fundTransactions.filter {
            $0.requestDate >= startDay && $0.requestDate < endDay && $0.status == .confirmed
        }
        for trade in fundRows {
            switch trade.side {
            case .buy where !trade.isBackfill:
                result.buy += trade.amount + trade.fee
                result.fee += trade.fee
                result.buyCount += 1
                result.operationDays.insert(trade.requestDate)
            case .sell:
                result.sell += max(0, trade.amount - trade.fee)
                result.fee += trade.fee
                result.realized += trade.realizedPnL
                result.sellCount += 1
                result.operationDays.insert(trade.requestDate)
                if trade.realizedPnL > 0 { result.winCount += 1 }
                else if trade.realizedPnL < 0 { result.loseCount += 1 }
                var row = result.realizedByCode[trade.code] ?? RealizedRow(code: trade.code, name: trade.name, pnl: 0)
                row.pnl += trade.realizedPnL
                result.realizedByCode[trade.code] = row
            case .dividend:
                if trade.dividendMode == .cash { result.cashDividend += trade.amount }
                else if trade.dividendMode == .reinvest { result.reinvestedDividend += trade.amount }
                result.operationDays.insert(trade.requestDate)
            default: break
            }
        }

        // —— 外部资金流 ——
        result.netFlow = data.cashFlows.reduce(0) { partial, flow in
            let flowDay = dayString(flow.date)
            guard flowDay >= startDay, flowDay < endDay, flow.external ?? true else { return partial }
            return partial + flow.amount
        }
        // 场外申赎也是外部资金流；自动定投已有专门的 CashFlow 记录，这里跳过避免重复计算
        for trade in fundRows where !trade.linkedCash && !trade.isBackfill && trade.isAutomaticDCA != true {
            if trade.side == .buy { result.netFlow += trade.amount }
            else if trade.side == .sell { result.netFlow -= max(0, trade.amount - trade.fee) }
        }

        // —— 全账户快照 ——
        let snapshots = data.snapshots.filter { $0.date >= startDay && $0.date < endDay }.sorted { $0.date < $1.date }
        result.snapshotStart = snapshots.first
        result.snapshotEnd = snapshots.last
        if let start = result.snapshotStart, let end = result.snapshotEnd, start.id != end.id {
            result.snapshotNetFlow = data.cashFlows.reduce(0) { partial, flow in
                let flowDay = dayString(flow.date)
                guard flowDay > start.date, flowDay <= end.date, flow.external ?? true else { return partial }
                return partial + flow.amount
            }
            for trade in fundRows where trade.requestDate > start.date && trade.requestDate <= end.date
                    && !trade.linkedCash && !trade.isBackfill && trade.isAutomaticDCA != true {
                if trade.side == .buy { result.snapshotNetFlow += trade.amount }
                else if trade.side == .sell { result.snapshotNetFlow -= max(0, trade.amount - trade.fee) }
            }
        }
        return result
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func nextMonthStart(_ month: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: "\(month)-01"),
              let next = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: date)
        else { return "9999-12-31" }
        return formatter.string(from: next)
    }

    static func currentYear() -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy"
        return Int(formatter.string(from: .now)) ?? 2026
    }
}

// MARK: - 年度账单

/// 年度账单：把 12 个月的流水汇总成一份年报。
///
/// 与「月度投资复盘」的区别：
/// - 年度视角的胜率、换手费率、操作密度（这些单月看不出意义）
/// - 逐月柱状图，一眼看出哪个月赚/亏、哪个月投入最多
/// - 全年最佳 / 最差标的
struct YearlyReviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int = LedgerPeriodAggregator.currentYear()

    private var yearStart: String { "\(year)-01-01" }
    private var nextYearStart: String { "\(year + 1)-01-01" }

    /// 主题深浅决定卡片色的透明度档位（浅色底上要更淡才不刺眼）。
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    private var aggregate: PeriodLedgerAggregate {
        LedgerPeriodAggregator.aggregate(data: store.data, from: yearStart, to: nextYearStart)
    }
    private var monthRows: [MonthAggregateRow] {
        (1...12).map { month in
            let key = String(format: "%d-%02d", year, month)
            let agg = LedgerPeriodAggregator.aggregate(data: store.data,
                                                       from: "\(key)-01",
                                                       to: LedgerPeriodAggregator.nextMonthStart(key))
            return MonthAggregateRow(month: key, aggregate: agg)
        }
    }
    private var rankedRows: [RealizedRow] {
        aggregate.realizedByCode.values.sorted { $0.pnl > $1.pnl }
    }
    private var hasAnyData: Bool {
        aggregate.operationCount > 0 || aggregate.cashDividend > 0 || aggregate.netFlow != 0
    }
    private var canGoForward: Bool { year < LedgerPeriodAggregator.currentYear() }
    private var reportText: String {
        let a = aggregate
        let feeText = a.feeRate.map { "（占换手 \($0.pct(2))）" } ?? ""
        let lines = [
            "观盘 Pro · \(year) 年度账单",
            "已实现盈亏 \(a.realized.cny()) / 现金分红 \(a.cashDividend.cny()) / 合计 \(a.netResult.cny())",
            "买入 \(a.buy.cny())（\(a.buyCount) 笔）/ 卖出 \(a.sell.cny())（\(a.sellCount) 笔）",
            "交易费用 \(a.fee.cny())\(feeText)",
            "净外部投入 \(a.netFlow.cny()) / 有操作的日期 \(a.operationDays.count) 天",
            "卖出胜率 " + (a.winRate.map { $0.pct(1) } ?? "无卖出记录")
        ]
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                Section { yearSwitcherBody }
                Section("全年结果") { headlineBody }
                    .toneCard(CardTone.pnl(aggregate.netResult), isLight: isLight)
                Section("交易活跃度") { activityBody }
                    .plainCard(isLight: isLight)
                Section("全账户快照") { snapshotBody }
                    .toneCard(CardTone.pnl(aggregate.adjustedChange ?? 0), isLight: isLight)
                Section("逐月已实现盈亏 + 现金分红") { monthlyChartBody }
                    .plainCard(isLight: isLight)
                Section("逐月明细") { monthlyTableBody }
                    .plainCard(isLight: isLight)
                Section("全年标的表现") { rankingBody }
                    .toneCard(CardTone.pnl(aggregate.realized), isLight: isLight)
                Section("年度提示") { tipsBody }
                    .toneCard(tips.contains { $0.hasPrefix("提醒") } ? CardTone.warn : CardTone.ok, isLight: isLight)
                Section { disclaimerBody }
                    .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .listStyle(.insetGrouped)
            .navigationTitle("\(year) 年度账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: reportText) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    // 说明：Section 的内容统一抽成 @ViewBuilder 属性。
    // 直接把多行异构内容写在 Section 闭包里，编译器有时会把 Section 匹配到
    // SwiftUI 的 Table 版初始化器（@TableRowBuilder），报 "generic parameter 'V' could not be inferred"。

    @ViewBuilder private var yearSwitcherBody: some View {
        HStack {
            Button { year -= 1; Haptics.selection() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("上一年")
            Spacer()
            Text("\(year) 年").font(.title3.weight(.semibold))
            Spacer()
            Button { year += 1; Haptics.selection() } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("下一年")
                .disabled(!canGoForward)
        }
    }

    @ViewBuilder private var headlineBody: some View {
        LabeledContent("已实现盈亏 + 现金分红", value: (aggregate.netResult).cny())
            .pnlAccessibility(money: aggregate.netResult)
        LabeledContent("其中已实现盈亏", value: (aggregate.realized).cny())
        if aggregate.cashDividend > 0 || aggregate.reinvestedDividend > 0 {
            LabeledContent("现金分红 / 红利再投",
                           value: "\(aggregate.cashDividend.cny()) / \(aggregate.reinvestedDividend.cny())")
        }
        if let winRate = aggregate.winRate {
            LabeledContent("卖出胜率", value: "\(winRate.pct(1))（\(aggregate.winCount) 赚 / \(aggregate.loseCount) 亏）")
                .accessibilityLabel("卖出胜率 \(winRate.pct(1))，\(aggregate.winCount) 笔赚钱，\(aggregate.loseCount) 笔亏损")
        } else {
            LabeledContent("卖出胜率", value: "全年无卖出记录")
        }
    }

    @ViewBuilder private var activityBody: some View {
        LabeledContent("买入 / 卖出", value: "\(aggregate.buyCount) / \(aggregate.sellCount) 笔")
        LabeledContent("买入金额", value: (aggregate.buy).cny())
        LabeledContent("卖出到账", value: (aggregate.sell).cny())
        LabeledContent("记录费用", value: (aggregate.fee).cny())
        if let feeRate = aggregate.feeRate {
            LabeledContent("费用占换手额", value: feeRate.pct(2))
                .accessibilityLabel("交易费用占换手额 \(feeRate.pct(2))")
        }
        LabeledContent("净外部投入", value: (aggregate.netFlow).cny())
        LabeledContent("有操作的日期", value: "\(aggregate.operationDays.count) 天")
        if aggregate.operationCount > 0 {
            LabeledContent("月均买卖笔数", value: (Double(aggregate.operationCount) / 12.0).num(1))
        }
    }

    @ViewBuilder private var snapshotBody: some View {
        if let start = aggregate.snapshotStart, let end = aggregate.snapshotEnd, start.id != end.id {
            LabeledContent("快照区间", value: "\(start.date) → \(end.date)")
            LabeledContent("资产变化", value: (aggregate.assetChange ?? 0).cny())
                .pnlAccessibility(money: aggregate.assetChange ?? 0)
            LabeledContent("扣除净外部投入后", value: (aggregate.adjustedChange ?? 0).cny())
                .pnlAccessibility(money: aggregate.adjustedChange ?? 0)
            Text("只使用本年已有快照及已记录外部资金流；这不是精确的市场收益归因。")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("本年没有两条不同日期的全账户快照，不推算资产变化。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var monthlyChartBody: some View {
        Chart(monthRows) { row in
            BarMark(
                x: .value("月份", row.label),
                y: .value("盈亏", row.aggregate.netResult)
            )
            .foregroundStyle(PnLColor.of(row.aggregate.netResult))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.10))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
        .accessibilityLabel("逐月已实现盈亏与现金分红柱状图")
        Text("红为净赚、绿为净亏；高度为 0 的月份表示该月没有卖出或分红记录。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var monthlyTableBody: some View {
        ForEach(monthRows) { row in
            HStack(spacing: 10) {
                Text(row.label + " 月")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                Text((row.aggregate.netResult).num(0))
                    .font(.caption.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(row.aggregate.netResult == 0 ? Color.secondary : PnLColor.of(row.aggregate.netResult))
                Spacer()
                Text("\(row.aggregate.operationCount) 笔")
                    .font(.caption).foregroundStyle(.secondary)
                Text("投入 \((row.aggregate.netFlow).num(0))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .combineAccessibility()
        }
    }

    @ViewBuilder private var rankingBody: some View {
        if rankedRows.isEmpty {
            Text("本年没有卖出记录，无法按已实现盈亏排名。")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(topRows.enumerated()), id: \.offset) { index, row in
                rankedRow(row: row, rank: index + 1)
            }
            if !bottomRows.isEmpty {
                ForEach(Array(bottomRows.enumerated()), id: \.offset) { index, row in
                    rankedRow(row: row, rank: rankedRows.count - bottomRows.count + index + 1)
                }
            }
        }
        Text("按已实现盈亏排序，只统计本年已卖出的部分；仍持有的浮动盈亏不在这里。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var tipsBody: some View {
        ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
            Label(tip, systemImage: tip.hasPrefix("提醒") ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.subheadline)
        }
    }

    @ViewBuilder private var disclaimerBody: some View {
        Text("年度账单只汇总本机已有的交易、分红、资金流和全账户快照，不反推缺失的持仓或收益，也不修改账本。费用不再从已实现盈亏中重复扣除。胜率只统计本年卖出且已记录已实现盈亏的笔数。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func rankedRow(row: RealizedRow, rank: Int) -> some View {
        HStack {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(row.name).lineLimit(1)
            Spacer()
            Text((row.pnl).cny())
                .font(.caption.monospacedDigit())
                .foregroundStyle(PnLColor.of(row.pnl))
        }
        .combineAccessibility()
    }

    // MARK: 计算

    private var topRows: [RealizedRow] { Array(rankedRows.prefix(5)) }

    /// 倒数 5 名；总数不足 6 时为空，避免和前 5 名重复
    private var bottomRows: [RealizedRow] {
        guard rankedRows.count > 5 else { return [] }
        return Array(rankedRows.suffix(min(5, rankedRows.count - 5)))
    }

    private var tips: [String] {
        var out: [String] = []
        let a = aggregate
        if !hasAnyData {
            out.append("本年没有买卖、分红或资金流记录。")
            return out
        }
        if a.operationCount >= 60 {
            let perMonth = Double(a.operationCount) / 12.0
            out.append("提醒：全年 \(a.operationCount) 笔买卖，平均每月 \(perMonth.num(1)) 笔，检查是否都存在计划依据。")
        } else if a.operationCount > 0 {
            out.append("全年 \(a.operationCount) 笔买卖，分布在 \(a.operationDays.count) 个记录日期。")
        } else {
            out.append("本年没有买卖流水。")
        }
        if let feeRate = a.feeRate {
            if feeRate > 0.5 {
                out.append("提醒：全年费用占换手额 \(feeRate.pct(2))，偏高的交易频率会明显吃掉收益。")
            } else {
                out.append("全年费用占换手额 \(feeRate.pct(2))。")
            }
        }
        if let winRate = a.winRate, winRate < 40, a.sellCount >= 5 {
            out.append("提醒：卖出胜率 \(winRate.pct(1))，低于四成；核对止损与止盈是否对称。")
        }
        if let adjusted = a.adjustedChange {
            out.append("快照口径下，扣除净外部投入后资产变化 \(adjusted.cny())。")
        }
        let busy = monthRows.filter { $0.aggregate.operationCount >= 8 }.map { $0.label + " 月" }
        if !busy.isEmpty {
            out.append("提醒：\(busy.joined(separator: "、"))操作较密集（单月 ≥ 8 笔）。")
        }
        if out.isEmpty { out.append("本年记录完整，没有明显异常。") }
        return out
    }
}
