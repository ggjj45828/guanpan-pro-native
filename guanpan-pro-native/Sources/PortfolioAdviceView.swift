import SwiftUI

private struct PortfolioAdviceItem: Identifiable {
    var id: String
    var title: String
    var detail: String
    var highPriority: Bool
}

struct PortfolioAdviceView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    private var isLight: Bool { AppTheme.palette(for: store.appearance).isLight }
    /// 有高优先提示时整卡转琥珀，否则用「状态良好」的蓝绿。
    private var tipsTone: Color { items.contains { $0.highPriority } ? CardTone.warn : CardTone.ok }

    private var items: [PortfolioAdviceItem] {
        var result: [PortfolioAdviceItem] = []
        let total = store.totalAsset
        guard total > 0 else { return result }

        for holding in store.data.holdings where holding.quantity > 0 {
            let personalLimit = holding.maxPositionPercent ?? 0
            let limit = personalLimit > 0 ? personalLimit : store.data.globalPositionLimitPercent
            guard limit > 0, limit < 100 else { continue }
            let actual = store.allocationActualPercent(for: holding)
            if actual > limit {
                result.append(PortfolioAdviceItem(id: "limit-\(holding.id)", title: "持仓超过已设上限",
                    detail: "\(holding.name) 当前占比 \(String(format: "%.1f", actual))%，高于设置值 \(String(format: "%.1f", limit))%。",
                    highPriority: actual >= limit * 1.5))
            }
        }

        let invested = store.totalMarketValue
        if invested > 0 {
            let cashPercent = store.data.cash / total * 100
            if cashPercent >= 60 {
                result.append(PortfolioAdviceItem(id: "cash-high", title: "现金占比较高",
                    detail: "参考现金占总资产 \(String(format: "%.1f", cashPercent))%；这会让账户表现更多取决于现金配置。", highPriority: false))
            } else if cashPercent <= 5 {
                result.append(PortfolioAdviceItem(id: "cash-low", title: "现金余量较低",
                    detail: "参考现金占总资产 \(String(format: "%.1f", cashPercent))%；留意后续资金安排。", highPriority: false))
            }
        }

        let funds = store.data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }
        let snapshots = Dictionary(uniqueKeysWithValues: store.data.fundConstituentSnapshots.map { ($0.code, $0) })
        if funds.count > 1 {
            for leftIndex in 0..<(funds.count - 1) {
                for rightIndex in (leftIndex + 1)..<funds.count {
                    let left = funds[leftIndex], right = funds[rightIndex]
                    guard let a = snapshots[left.code], let b = snapshots[right.code] else { continue }
                    let weightsA = Dictionary(a.holdings.map { ($0.code, $0.weightPercent) }, uniquingKeysWith: { max($0, $1) })
                    let weightsB = Dictionary(b.holdings.map { ($0.code, $0.weightPercent) }, uniquingKeysWith: { max($0, $1) })
                    let overlap = weightsA.reduce(0.0) { sum, row in sum + min(row.value, weightsB[row.key] ?? 0) }
                    if overlap >= 40 {
                        result.append(PortfolioAdviceItem(id: "overlap-\(left.code)-\(right.code)", title: "两只基金重仓成分重复",
                            detail: "\(left.name) 与 \(right.name) 前十大重叠约 \(String(format: "%.1f", overlap))%（报告日期：\(a.asOf.isEmpty ? "未知" : a.asOf) / \(b.asOf.isEmpty ? "未知" : b.asOf)）。",
                            highPriority: overlap >= 60))
                    }
                }
            }
        }

        for fund in funds where fund.marketValue >= 100 && fund.current > 0 {
            guard let estimate = store.estimateFundRedemptionFee(code: fund.code, shares: fund.quantity, nav: fund.current, on: .now), estimate.total <= 0.0001 else { continue }
            result.append(PortfolioAdviceItem(id: "fee-free-\(fund.code)", title: "基金整笔赎回费估算为零",
                detail: "按已录入的费率档与申购/分红批次，\(fund.name) 当前份额估算费为 0 元；实际扣费仍以销售平台为准。", highPriority: false))
        }
        return result.sorted {
            if $0.highPriority != $1.highPriority { return $0.highPriority }
            return $0.title < $1.title
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("本地规则提示") {
                    if items.isEmpty {
                        Label("当前没有触发已设置规则的提示", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CardTone.ok)
                    } else {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.title, systemImage: item.highPriority ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundStyle(item.highPriority ? CardTone.warn : Color.primary)
                                Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                .toneCard(items.isEmpty ? CardTone.ok : tipsTone, isLight: isLight)
                Section {
                    Text("只根据已保存的仓位上限、现金、基金定期报告和赎回费率流水生成提示，不使用 PE 估值、不预测涨跌，也不会自动买卖。基金重叠受报告日期和前十大覆盖范围限制；赎回费只是本地估算。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("账户决策提示")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
