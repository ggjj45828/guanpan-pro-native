import SwiftUI

/// 资产页的「持仓盈亏」面板：一屏看全每只持仓的市值、当日盈亏、浮盈与占比，
/// 并可在「摊薄成本 / 买入均价」两种券商口径之间切换。
///
/// 之所以单独做成文件级视图：资产页本身已经嵌得很深，再往里塞 ForEach + 计算属性
/// 很容易触发 SwiftUI 的类型检查超时。
struct HoldingsBreakdownPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @AppStorage("guanpan.next.costMode") private var modeRaw = NextCostDisplayMode.diluted.rawValue
    @State private var benchmarkCode = "000300"

    private var mode: NextCostDisplayMode { NextCostDisplayMode(rawValue: modeRaw) ?? .diluted }
    private var summary: NextPortfolioSummary {
        NextPortfolioCalculator.summary(book: model.book, quotes: model.quotes, at: Date(), mode: mode)
    }
    private var benchmarkName: String {
        NextBenchmark.options.first { $0.code == benchmarkCode }?.name ?? benchmarkCode
    }
    /// 基准涨幅取与组合完全相同的起止日期，避免「同一段时间」口径不一致。
    private var benchmarkReturn: Double? {
        guard let performance = NextPerformanceCalculator.summary(points: model.book.history),
              let dataset = model.chartData["\(benchmarkCode):day"] else { return nil }
        return NextBenchmark.returnPercent(samples: dataset.orderedSamples,
                                           from: performance.startDate, to: performance.endDate)
    }
    /// 组合风险：比"涨了还是跌了"更该先看的东西 —— 钱压在哪、有多集中、有多少是现金。
    @ViewBuilder
    private func riskSummary(_ data: NextPortfolioSummary) -> some View {
        let sorted = data.positions.sorted { $0.weightPercent > $1.weightPercent }
        let top = sorted.first
        let top3 = sorted.prefix(3).reduce(0.0) { $0 + $1.weightPercent }
        let cashRatio = data.totalValue > 0 ? NextNum.double(data.cash / data.totalValue) * 100 : 0
        let winners = data.positions.filter { $0.floatingProfit > 0 }.count
        let limit = NextNum.double(model.goal.concentrationLimit)
        HStack(alignment: .top, spacing: 12) {
            GPValue(label: "最大单一", value: top.map { String(format: "%.1f%%", $0.weightPercent) } ?? "—",
                    footnote: top?.name ?? "无持仓",
                    emphasis: (top?.weightPercent ?? 0) > limit ? p.terracotta : nil)
            GPValue(label: "前三大", value: String(format: "%.1f%%", top3),
                    footnote: "集中度线 \(NextNum.percent(limit, digits: 0))",
                    emphasis: top3 > limit * 2.5 ? p.terracotta : nil)
            GPValue(label: "现金占比", value: String(format: "%.1f%%", cashRatio),
                    footnote: "可用 ¥\(NextMoney.text(data.cash))")
            GPValue(label: "盈利家数", value: "\(winners)/\(data.positions.count)",
                    footnote: "按浮动盈亏计", emphasis: winners > 0 ? p.gpUp : p.gpDown)
        }
    }

    private func rebalanceRows(from data: NextPortfolioSummary) -> [RebalanceRow] {
        guard data.totalValue > 0 else { return [] }
        return model.book.positions.compactMap { position in
            guard let target = model.goal.targetWeights[position.code], target > 0,
                  let row = data.positions.first(where: { $0.code == position.code }) else { return nil }
            return RebalanceRow(id: position.code, name: position.name,
                                targetPercent: NextNum.double(target),
                                currentPercent: row.weightPercent,
                                deltaAmount: data.totalValue * target / 100 - row.marketValue)
        }
        .sorted { abs(NextNum.double($0.deltaAmount)) > abs(NextNum.double($1.deltaAmount)) }
    }

    var body: some View {
        let data = summary
        EditorialSection(title: "持仓盈亏", trailing: mode.title, accent: p.jade) {
            HStack(alignment: .top, spacing: 14) {
                GPValue(label: "总资产", value: "¥\(NextMoney.text(data.totalValue))",
                        footnote: data.isComplete ? "市值 + 可用现金，不含券商冻结/在途"
                            : (data.anomalies.isEmpty ? "部分持仓缺报价" : "\(data.anomalies.count) 只报价异常，已排除"))
                GPValue(label: "今日盈亏", value: data.dailyChange.map { "\($0 >= 0 ? "+" : "")¥\(NextMoney.text($0))" } ?? "—",
                        footnote: data.dailyChange == nil ? "需完整新鲜行情" : "昨仓按昨收、今买按买入价",
                        emphasis: data.dailyChange.map { p.changeTone(NextNum.double($0)) })
                GPValue(label: "浮动盈亏", value: "\(data.floatingProfit >= 0 ? "+" : "")¥\(NextMoney.text(data.floatingProfit))",
                        footnote: "\(NextNum.signed(NextNum.double(data.floatingPercent)))% · \(mode.title)",
                        emphasis: p.changeTone(NextNum.double(data.floatingProfit)))
            }
            if !data.anomalies.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(data.anomalies) { item in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(p.terracotta)
                            Text("\(item.name)（\(item.code)）：\(item.reason)")
                                .font(.system(size: 10)).foregroundStyle(p.terracotta)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(.top, 2)
            }
            HStack(spacing: 6) {
                ForEach(NextCostDisplayMode.allCases) { item in
                    Button { modeRaw = item.rawValue } label: {
                        Text(item.title).font(.system(size: 10, weight: mode == item ? .semibold : .regular))
                            .foregroundStyle(mode == item ? p.forest : p.muted)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(mode == item ? p.tint : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("成本口径 \(item.title)")
                }
                Spacer(minLength: 0)
            }
            Text(mode.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let performance = NextPerformanceCalculator.summary(points: model.book.history) {
                HStack(spacing: 6) {
                    Text("基准").font(.system(size: 10)).foregroundStyle(p.muted)
                    ForEach(NextBenchmark.options) { option in
                        Button { benchmarkCode = option.code } label: {
                            Text(option.name).font(.system(size: 9.5, weight: benchmarkCode == option.code ? .semibold : .regular))
                                .foregroundStyle(benchmarkCode == option.code ? p.chartViolet : p.muted)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(benchmarkCode == option.code ? p.chartViolet.opacity(0.14) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                PerformanceBlock(summary: performance, sampleCount: model.book.history.count,
                                 benchmarkName: benchmarkName, benchmarkReturn: benchmarkReturn)
            } else {
                Text("已有 \(model.book.history.count) 条资产快照，至少需要 2 条才能算区间收益。收盘后每天自动补一条（盘中不记，避免噪音）；应用当天没打开就会缺那天，不做回填以免伪造历史。")
                    .font(.caption2).foregroundStyle(p.muted)
            }

            if !data.positions.isEmpty {
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                riskSummary(data)
            }

            // 体检放在持仓明细之前：先告诉用户"哪些数字不可信"，再让他看数字。
            let issues = NextBookHealth.issues(book: model.book, quotes: model.quotes, at: Date(),
                                               concentrationLimit: NextNum.double(model.goal.concentrationLimit))
            if !issues.isEmpty {
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                HStack(spacing: 5) {
                    Image(systemName: "stethoscope").font(.system(size: 10)).foregroundStyle(p.terracotta)
                    Text("账本体检 · \(issues.count) 项").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                    Spacer(minLength: 0)
                }
                ForEach(issues.prefix(5)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted).frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(p.ink)
                            Text(item.detail).font(.system(size: 9.5)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 2)
                }
                if issues.count > 5 {
                    Text("另有 \(issues.count - 5) 项，逐只打开详情处理").font(.system(size: 9.5)).foregroundStyle(p.muted)
                }
            }

            // 今日贡献：把"今天亏了 3.8"拆到具体标的，不用自己去加。
            if let daily = data.dailyChange, !data.positions.isEmpty {
                let contributors = Array(data.positions.sorted { abs($0.dailyChange) > abs($1.dailyChange) }.prefix(4))
                if !contributors.isEmpty {
                    Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                    HStack(spacing: 5) {
                        Text("今日贡献").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                        Spacer(minLength: 0)
                        Text("合计 \(daily >= 0 ? "+" : "")¥\(NextMoney.text(daily))").font(.system(size: 9.5)).foregroundStyle(p.changeTone(NextNum.double(daily)))
                    }
                    ForEach(contributors) { item in
                        HStack(spacing: 6) {
                            Text(item.name).font(.system(size: 10.5)).foregroundStyle(p.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(item.dailyChange >= 0 ? "+" : "")¥\(NextMoney.text(item.dailyChange))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.changeTone(NextNum.double(item.dailyChange)))
                        }.padding(.vertical, 1)
                    }
                }
            }

            // 待收分红：已实施派息会自动登记成"待到账"，这里给一个总览，免得忘了核销。
            let pendingIncome = model.book.incomeEvents.filter { $0.status == .expected }
            if !pendingIncome.isEmpty {
                let totalPending = pendingIncome.reduce(Decimal.zero) { $0 + $1.netAmount }
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                GPDataRow(title: "待收到账 · \(pendingIncome.count) 笔",
                          value: "¥\(NextMoney.text(totalPending))",
                          note: "由已实施派息自动登记；券商到账后在「资产流水」核销，不会自动加现金",
                          valueColor: p.chartGold)
            }

            if data.positions.isEmpty {
                GPStatus(title: "还没有可估算的持仓", detail: "录入持仓并且拿到报价后，这里会给出每只的市值、当日盈亏和浮动盈亏。", symbol: "chart.pie")
            } else {
                ForEach(data.positions) { item in
                    HoldingsSummaryRow(item: item, palette: p)
                }
            }

            let rebalance = rebalanceRows(from: data)
            if !rebalance.isEmpty {
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                Text("再平衡（按你设定的目标仓位）").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                ForEach(rebalance) { row in
                    GPDataRow(title: "\(row.name) 目标 \(NextNum.percent(row.targetPercent, digits: 1)) · 当前 \(NextNum.percent(row.currentPercent, digits: 1))",
                              value: "\(row.deltaAmount >= 0 ? "需买入" : "需卖出") ¥\(NextMoney.text(abs(row.deltaAmount)))",
                              note: "按总资产与目标比例折算；不含税费与最小交易单位",
                              valueColor: p.changeTone(NextNum.double(row.deltaAmount)))
                }
                Text("目标仓位只在「设置 → 你的目标与资金」里设定；这里只算差额，不生成订单。")
                    .font(.caption2).foregroundStyle(p.muted)
            }

            if data.realizedTotal != 0 || !data.recentSells.isEmpty {
                Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 4)
                GPDataRow(title: "累计已实现盈亏",
                          value: "\(data.realizedTotal >= 0 ? "+" : "")¥\(NextMoney.text(data.realizedTotal))",
                          note: "按每笔卖出的成本还原，未计分红",
                          valueColor: p.changeTone(NextNum.double(data.realizedTotal)))
                ForEach(data.realizedByCode.prefix(3)) { item in
                    GPDataRow(title: "已实现 · \(item.name)",
                              value: "\(item.amount >= 0 ? "+" : "")¥\(NextMoney.text(item.amount))",
                              valueColor: p.changeTone(NextNum.double(item.amount)))
                }
                ForEach(data.recentSells) { fill in
                    GPDataRow(title: "卖出 \(fill.code) · \(fill.date.formatted(date: .numeric, time: .omitted))",
                              value: "\(fill.units) 份 × ¥\(NextMoney.text(fill.price, digits: 3))",
                              note: "已实现 \(fill.realized >= 0 ? "+" : "")¥\(NextMoney.text(fill.realized)) · 手续费 ¥\(NextMoney.text(fill.fee))",
                              valueColor: p.changeTone(NextNum.double(fill.realized)))
                }
            }
        }
    }
}

private struct HoldingsSummaryRow: View {
    let item: NextPositionSummary
    let palette: GPPalette
    private var p: GPPalette { palette }
    private var dailyTone: Color { p.changeTone(NextNum.double(item.dailyChange)) }
    private var floatingTone: Color { p.changeTone(NextNum.double(item.floatingProfit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                Text(item.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                Spacer(minLength: 4)
                Text("¥\(NextMoney.text(item.marketValue))").font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(p.ink)
            }
            HStack(spacing: 10) {
                Text("当日 \(item.dailyChange >= 0 ? "+" : "")¥\(NextMoney.text(item.dailyChange))").foregroundStyle(dailyTone)
                Text("浮盈 \(NextNum.signed(NextNum.double(item.floatingPercent)))%").foregroundStyle(floatingTone)
                Spacer(minLength: 4)
                Text("占比 \(NextNum.percent(item.weightPercent, digits: 1))").foregroundStyle(p.muted)
            }
            .font(.system(size: 9.5, design: .monospaced))
            HStack(spacing: 6) {
                Text(NextInstrumentGroup.classify(code: item.code, name: item.name).rawValue)
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(p.chartViolet)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(p.chartViolet.opacity(0.12), in: Capsule())
                Text("\(item.units) 份 · 成本 ¥\(NextMoney.text(item.costPerUnit, digits: 3))（\(item.costSource)）")
                    .font(.system(size: 9)).foregroundStyle(p.muted.opacity(0.9))
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.65)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) 市值 \(NextMoney.text(item.marketValue)) 元，当日 \(NextNum.signed(NextNum.double(item.dailyChange))) 元，浮盈 \(NextNum.signed(NextNum.double(item.floatingPercent)))%")
    }
}

private struct PerformanceBlock: View {
    @Environment(\.gp) private var p
    let summary: NextPerformanceSummary
    let sampleCount: Int
    let benchmarkName: String
    let benchmarkReturn: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if summary.hasEnoughSamples {
                HStack(alignment: .top, spacing: 14) {
                    GPValue(label: "区间收益", value: NextNum.signed(summary.cumulativePercent) + "%",
                            footnote: "\(summary.dayCount) 天 · 已剔除出入金",
                            emphasis: p.changeTone(NextNum.double(summary.cumulativePercent)))
                    GPValue(label: "年化", value: summary.annualizedPercent.map { NextNum.signed($0) + "%" } ?? "不足 90 天",
                            footnote: summary.annualizedPercent == nil ? "样本太短不给年化" : "按区间折算")
                    GPValue(label: "最大回撤", value: "-" + NextNum.percent(summary.maxDrawdownPercent, digits: 3),
                            footnote: "快照净值峰谷", emphasis: p.terracotta)
                }
                if let benchmarkReturn {
                    GPDataRow(title: "\(benchmarkName) 同期",
                              value: NextNum.signed(benchmarkReturn) + "%",
                              note: "超额 " + NextNum.signed(summary.cumulativePercent - benchmarkReturn) + "%（组合 − 基准）",
                              valueColor: summary.cumulativePercent >= benchmarkReturn ? p.gpUp : p.gpDown)
                } else {
                    Text("基准日 K 未归档，暂时无法比较「跑没跑赢」。可在行情页打开 \(benchmarkName) 的日 K 触发归档。")
                        .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Text("自 \(summary.startDate.formatted(date: .numeric, time: .omitted)) 起，共 \(sampleCount) 个资产快照；按日收益连乘（时间加权近似）。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("资产快照只有 \(sampleCount) 个，暂不算区间收益（至少 3 个，且需有正的起始资产）。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RebalanceRow: Identifiable {
    let id: String
    let name: String
    let targetPercent: Double
    let currentPercent: Double
    let deltaAmount: Decimal
}
