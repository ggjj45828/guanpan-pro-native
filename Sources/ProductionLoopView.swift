import SwiftUI

// MARK: - 生产闭环只读页：盯盘计划 / 状态事件 / 成交关联 / 今日 T vs HOLD
//
// 这一页只呈现已发生的状态与建议，不提供任何下单或写账入口。
// 「确认关联」也只标记计划与成交的对应关系，不改现金、持仓或 Ledger。

enum ProductionLoopTab: String, CaseIterable, Identifiable {
    case plans, events, links, review

    var id: String { rawValue }
    var title: String {
        switch self {
        case .plans: return "盯盘计划"
        case .events: return "状态留痕"
        case .links: return "成交关联"
        case .review: return "今日复盘"
        }
    }
}

struct ProductionLoopView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance
    @State private var tab: ProductionLoopTab = .plans

    private var s: ThemeSemantics { .of(appearance) }
    private var review: TodayTComparison { store.todayTComparison() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("视图", selection: $tab) {
                        ForEach(ProductionLoopTab.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("行情刷新时自动评估盯盘计划；触发只表示价格进入过计划区间，不是下单许可，也不会写入账本。")
                        .font(.footnote).foregroundStyle(s.ink2)
                }

                if tab == .plans { plansSection }
                if tab == .events { eventsSection }
                if tab == .links { linksSection }
                if tab == .review { reviewSection }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("生产盯盘与复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
    }

    // MARK: 计划

    private var plansSection: some View {
        Section("已保存计划 · \(store.data.triggerPlans.count) 条") {
            if store.data.triggerPlans.isEmpty {
                Text("还没有盯盘计划。在「规则验证台」填好候选区间后点「保存为盯盘计划」。")
                    .font(.footnote).foregroundStyle(s.ink2)
            }
            ForEach(store.data.triggerPlans) { plan in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(plan.candidate.code) · \(plan.candidate.direction == .buy ? "买入" : "卖出")")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(s.ink)
                        Spacer()
                        Text(plan.isActive ? plan.state.title : "已停用")
                            .font(.caption).foregroundStyle(plan.state == .triggered ? s.warn : s.ink2)
                    }
                    Text("区间 \(plan.candidate.lowerPrice.num(3))–\(plan.candidate.upperPrice.num(3)) · 目标 \(plan.candidate.targetPrice.num(3)) · 数量 \(plan.candidate.quantity.num(0))")
                        .font(.caption).foregroundStyle(s.ink2)
                    Text("有效期至 \(plan.candidate.validUntil.formatted(date: .omitted, time: .shortened)) · 上次评估 \(plan.lastEvaluatedAt?.formatted(date: .omitted, time: .shortened) ?? "尚未评估")")
                        .font(.caption2).foregroundStyle(s.ink3)
                    if plan.linkConfirmedByUser {
                        Text("已人工确认关联成交").font(.caption2).foregroundStyle(s.ok)
                    }
                    ForEach(plan.lastReasons, id: \.self) { reason in
                        Text(reason).font(.caption2).foregroundStyle(s.ink3)
                    }
                    HStack(spacing: 14) {
                        Button(plan.isActive ? "暂停" : "恢复") {
                            store.setTriggerPlanActive(plan.id, active: !plan.isActive)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(s.accent)
                        Button("删除") { store.removeTriggerPlan(plan.id) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(s.danger)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 事件

    private var eventsSection: some View {
        Section("状态变更留痕 · 最近 \(min(50, store.data.triggerEvents.count)) 条") {
            if store.data.triggerEvents.isEmpty {
                Text("还没有状态变更。保存计划后，行情刷新时若状态变化会在这里留痕。")
                    .font(.footnote).foregroundStyle(s.ink2)
            }
            ForEach(store.data.triggerEvents.prefix(50)) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(event.from.title) → \(event.to.title)")
                            .font(.subheadline).foregroundStyle(s.ink)
                        Spacer()
                        Text(event.at.formatted(date: .numeric, time: .shortened))
                            .font(.caption2).foregroundStyle(s.ink3)
                    }
                    Text(event.code + " · 置信 \(event.confidence)%")
                        .font(.caption).foregroundStyle(s.ink2)
                    ForEach(event.reasons, id: \.self) { reason in
                        Text(reason).font(.caption2).foregroundStyle(s.ink3)
                    }
                }
            }
        }
    }

    // MARK: 关联

    private var linksSection: some View {
        Section("成交 ↔ 候选 · \(store.data.candidateLinks.count) 条") {
            Text("关联只是复核建议，不是成交事实的证明。确认后只标记对应关系，不写账本、不改现金和持仓。")
                .font(.footnote).foregroundStyle(s.ink2)
            if store.data.candidateLinks.isEmpty {
                Text("暂无关联建议。导入或录入成交后会自动重算。")
                    .font(.footnote).foregroundStyle(s.ink2)
            }
            ForEach(store.data.candidateLinks) { link in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(link.code) · \(link.side == "buy" ? "买入" : "卖出")")
                            .font(.subheadline).foregroundStyle(s.ink)
                        Spacer()
                        Text("\(link.confidence)%").font(.caption.monospacedDigit()).foregroundStyle(s.ink2)
                    }
                    Text(link.status.title)
                        .font(.caption)
                        .foregroundStyle(link.status == .rejected ? s.ink3 : (link.status == .confirmed ? s.ok : s.warn))
                    Text(link.reasons.joined(separator: "、"))
                        .font(.caption2).foregroundStyle(s.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if link.status == .pending || link.status == .auto {
                        HStack(spacing: 14) {
                            Button("确认关联") { store.decideCandidateLink(link.id, accept: true) }
                                .buttonStyle(.borderless).foregroundStyle(s.accent)
                            Button("排除") { store.decideCandidateLink(link.id, accept: false) }
                                .buttonStyle(.borderless).foregroundStyle(s.danger)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: 今日复盘

    private var reviewSection: some View {
        let r = review
        return Section("今日 T vs HOLD · \(r.day)") {
            HStack {
                Text("成交 \(r.fillCount) 笔 · 配对回合 \(r.roundTrips.count) 个")
                    .font(.subheadline).foregroundStyle(s.ink)
                Spacer()
                Text(r.coverageComplete ? "配对覆盖完整" : "存在未配平卖出")
                    .font(.caption).foregroundStyle(r.coverageComplete ? s.ok : s.warn)
            }
            HStack {
                Text("做 T 净贡献").font(.caption).foregroundStyle(s.ink2)
                Spacer()
                Text(r.tContribution.num(2)).font(.caption.monospacedDigit()).foregroundStyle(s.ink)
            }
            HStack {
                Text("T vs HOLD 差额（配平部分）").font(.caption).foregroundStyle(s.ink2)
                Spacer()
                Text(r.holdDifferential.map { $0.num(2) } ?? "无配对回合")
                    .font(.caption.monospacedDigit()).foregroundStyle(s.ink)
            }
            Text("数量配平时，做 T 与一直持有的持仓数量相同，差额就是卖价−回补价再扣分摊费用。未配平部分需要可信的当日收盘价，当前没有该证据，留空不编造。")
                .font(.footnote).foregroundStyle(s.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("当日费用 \(r.feesTotal.num(2)) · 其中配对分摊 \(r.feesAllocated.num(2))")
                    .font(.caption).foregroundStyle(s.ink2)
                Spacer()
            }
            if r.unpairedSellQuantity > 0 {
                Text("未回补卖出 \(r.unpairedSellQuantity.num(0)) 份，不进入 T vs HOLD 差额。")
                    .font(.caption).foregroundStyle(s.warn)
            }
            ForEach(r.roundTrips) { trip in
                HStack {
                    Text("\(trip.code) · \(trip.quantity.num(0)) 份")
                        .font(.caption).foregroundStyle(s.ink2)
                    Spacer()
                    Text(trip.contribution.num(2))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(trip.contribution >= 0 ? s.ok : s.danger)
                }
            }
            Text("证据等级：\(r.evidenceLevel) · 口径：" + r.reasonCodes.joined(separator: "、"))
                .font(.caption2).foregroundStyle(s.ink3)
        }
    }
}
