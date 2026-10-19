import SwiftUI

/// 分标的仓位目标的管理页 —— 目标仓位**唯一的管理入口**。
///
/// **为什么必须单独有这一页**：在此之前，目标仓位只藏在持仓行的左滑 / 长按菜单里，
/// 而且**只对场内放开**，场外基金压根设不了目标。可 `allocationTargets` 同时被
/// 「再平衡偏离」「新增资金加仓试算」「本机顾问」三处消费 —— 也就是说，对场外基金
/// 这三处一直是半残的（表里永远不会有基金的条目）。用户原话：
/// 「持仓目标怎么还是没有见哪里设置」。
///
/// 所以这里一次性解决三件事：
/// ① **看得见** —— 一个正经的管理页，不用去猜左滑菜单；
/// ② **两类都能设** —— 场内场外同一套界面，同一套口径；
/// ③ **把「实际 / 目标 / 偏离」并排放** —— 设完目标立刻能看到差多少，而不是设完就没了。
struct AllocationTargetsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Holding?

    /// 超过这个偏离幅度就标琥珀色。与「再平衡偏离」用的是同一个设置项
    /// （`rebalanceAlertThreshold`），别在两处各写一个数。
    private var threshold: Double { Double(store.data.rebalanceAlertThreshold) }

    private func target(for holding: Holding) -> Double? {
        store.data.allocationTargets
            .first { $0.code == holding.code && $0.kind == holding.kind }?.targetPercent
    }

    /// 有持仓的、或已经设过目标的都列出来（已清空的持仓不该继续占着目标）。
    /// 排序：先场内后场外，各自按实际仓位从大到小 —— 仓位越重的越该先有目标。
    private var rows: [Holding] {
        store.data.holdings
            .filter { $0.quantity > 0.000_001 || target(for: $0) != nil }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .etf }
                return store.allocationActualPercent(for: lhs) > store.allocationActualPercent(for: rhs)
            }
    }

    private var configuredCount: Int { rows.filter { target(for: $0) != nil }.count }

    private var breachCount: Int {
        rows.filter { holding in
            guard let t = target(for: holding) else { return false }
            return abs(store.allocationActualPercent(for: holding) - t) >= threshold
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    WorkspacePageIntro(title: "让仓位回到目标", subtitle: "实际持有与目标配置，并排核对", icon: "scope", tone: WorkspaceTone.teal)
                    MetricGrid(columns: 3, cells: [
                        MetricCell(title: "已设目标", value: "\(configuredCount)/\(rows.count) 只"),
                        MetricCell(title: "超过偏离阈值", value: "\(breachCount) 只"),
                        MetricCell(title: "提醒阈值", value: "±\(threshold.num(0))%")
                    ]).cardSurface(tone: breachCount > 0 ? CardTone.warn : WorkspaceTone.teal)
                    WorkspaceFeatureActions(features: [.addCash, .portfolioScenario])
                    if rows.isEmpty {
                        ContentUnavailableView("暂无可配置的持仓", systemImage: "chart.pie", description: Text("录入证券持仓后，在这里逐项设置目标比例。"))
                    }
                    ForEach(rows) { holding in
                        Button { editing = holding } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                row(holding)
                                let actual = store.allocationActualPercent(for: holding)
                                ProgressView(value: min(100, max(0, actual)), total: 100).tint(WorkspaceTone.teal)
                                HStack { Text("查看并调整目标"); Spacer(); Image(systemName: "chevron.right") }
                                    .font(.caption).foregroundStyle(WorkspaceTone.teal)
                            }.cardSurface(tone: WorkspaceTone.teal)
                        }.buttonStyle(.plain)
                    }
                    Text("实际仓位以含现金的总资产为分母。目标为 0 表示不计划持有；目标设置不修改真实持仓或现金，试算与交易计划仍由你确认。旧场外记录保留，不自动删除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }.navigationTitle("目标仓位").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $editing) { holding in
                    AllocationTargetEditor(holding: holding, targetPercent: target(for: holding)).themedSheetBackground()
                }
        }
    }

    @ViewBuilder private func row(_ holding: Holding) -> some View {
        let actual = store.allocationActualPercent(for: holding)
        let configured = target(for: holding)
        let accent = holdingKindAccent(holding.kind)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(holding.kind == .fund ? "场外" : "场内")
                    .scaledFont(9, weight: .bold)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(accent)
                    .background(Capsule().fill(accent.opacity(0.15)))
                Text(holding.name).scaledFont(14, weight: .semibold).lineLimit(1)
                Spacer(minLength: 6)
                Text(holding.marketValue.cny())
                    .scaledFont(13, weight: .semibold).monospacedDigit()
            }
            HStack(spacing: 10) {
                Text("实际 \(actual.num(2))%")
                    .scaledFont(12).monospacedDigit().foregroundStyle(.secondary)
                if let configured {
                    Text("目标 \(configured.num(2))%")
                        .scaledFont(12, weight: .semibold).monospacedDigit()
                    let drift = actual - configured
                    Text("\(drift >= 0 ? "超" : "差") \(abs(drift).num(2))%")
                        .scaledFont(12, weight: .semibold).monospacedDigit()
                        .foregroundStyle(abs(drift) >= threshold ? CardTone.warn : Color.secondary)
                } else {
                    Text("未设目标 · 点这一行设置")
                        .scaledFont(12).foregroundStyle(CardTone.warn)
                }
                Spacer(minLength: 0)
            }
            Text("\(holding.code) · \(holding.quantity.compactNum(4)) 份 · 现价 \(holding.current.num(holding.kind == .fund ? 4 : 3))")
                .scaledFont(10).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(holding.name) \(holding.kind == .fund ? "场外基金" : "场内")，实际仓位 \(actual.num(2))%"
                            + (configured.map { "，目标 \($0.num(2))%" } ?? "，未设目标"))
    }
}
