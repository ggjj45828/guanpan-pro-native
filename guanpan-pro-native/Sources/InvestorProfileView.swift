import SwiftUI

/// A readout of evidence first, with explicit rules kept separate from learned observations.
struct InvestorProfileView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.visualTheme) private var theme
    @State private var editing: InvestorProfileAttribute?
    @State private var editedValue = ""

    private var tokens: DesignTokens { ThemeManager.tokens(theme) }
    private var profile: DynamicInvestorProfile { store.data.dynamicInvestorProfile }
    private let labels = [
        "tradingFrequency": "交易频率",
        "typicalTicket": "单次成交金额",
        "opportunityPreference": "机会偏好",
        "observedCashReserve": "观察到的现金比例",
        "observedStrategyExecution": "真实做T/网格执行经历"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.gap) {
                Text("AI 对我的了解")
                    .font(.system(size: 29, weight: .bold, design: theme == .magazine ? .serif : .rounded))
                Text("只从真实成交、账户快照与您对已保存建议的反馈中学习。样本不足时留空；您的明确规则不会被自动改写。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ThemePanel(tone: tokens.hero) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("已知依据", systemImage: "checkmark.shield").font(.headline)
                        Text("真实成交 \(store.data.ledger.filter { $0.affectsHoldings != false }.count) 笔 · AI反馈 \(profile.feedback.count) 条")
                            .font(.subheadline)
                        Text("画像只调整适合度与提醒优先级；行情、规则和数据质量仍决定能否提出计划。")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("我的明确规则").font(.headline).padding(.top, 5)
                ThemePanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("交易执行：我在券商手工操作", systemImage: "hand.tap")
                        Text("不使用模拟账户，不自动下单。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("原有投资设置：期限 \(store.data.investmentProfile.horizon) · 单资产上限 \(store.data.investmentProfile.maxPositionPercent.formatted())%")
                            .font(.caption)
                        Text("旧设置可能是默认值；确认之前，AI不会把它当作您亲自锁定的长期规则。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        ForEach(store.data.holdings.filter { $0.quantity > 0 }) { holding in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(holding.name).font(.subheadline.weight(.semibold))
                                    Text(holding.code).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("仓位定位", selection: roleBinding(holding.code)) {
                                    Text("未设置").tag("")
                                    Text("长期核心仓").tag(HoldingRole.core.rawValue)
                                    Text("机动仓").tag(HoldingRole.tactical.rawValue)
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }
                    }
                }
                Text("学习中的判断").font(.headline).padding(.top, 5)
                if profile.attributes.isEmpty {
                    ThemePanel {
                        Text("真实样本还不够，暂不推断您的交易风格。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach(profile.attributes) { attribute in
                    ThemePanel(tone: tokens.secondary.opacity(0.14)) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(attribute.id.hasPrefix("pause:") ? "短期状态 · \(attribute.id.dropFirst(6))" :
                                    (labels[attribute.id] ?? attribute.id)).font(.headline)
                                Spacer()
                                Text(attribute.source == .explicit ? "您已锁定" :
                                    attribute.source == .temporary ? "短期反馈" : "从真实记录学习")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(attribute.value).font(.title3.weight(.semibold))
                            Text("可信度 \(Int(attribute.confidence * 100))% · \(attribute.sampleCount) 个样本 · 更新于 \(attribute.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(attribute.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if attribute.source == .temporary {
                                    Button("恢复候选") {
                                        let symbol = String(attribute.id.dropFirst(6))
                                        store.data.dynamicInvestorProfile.feedback.removeAll {
                                            $0.symbol == symbol && $0.kind == .notNow
                                        }
                                        store.save(label: "取消暂不交易反馈")
                                    }
                                } else {
                                    Button("修改并锁定") {
                                        editedValue = attribute.value
                                        editing = attribute
                                    }
                                    Spacer()
                                    Button("判断不准确") {
                                        store.data.dynamicInvestorProfile.rejectedEvidenceCounts[attribute.id] = attribute.sampleCount
                                        store.data.dynamicInvestorProfile.attributes.removeAll { $0.id == attribute.id }
                                        store.save(label: "移除不准确的画像判断")
                                    }
                                }
                            }.font(.caption)
                        }
                    }
                }
                Text("未展示的维度正在等待足够的真实证据；做T/网格执行经历只来自券商真实成交。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(tokens.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.background.ignoresSafeArea())
        .navigationTitle("AI 对我的了解")
        .sheet(item: $editing) { attribute in
            NavigationStack {
                Form {
                    TextField("您的明确规则", text: $editedValue)
                    Text("锁定后，AI不能用后续行为自动修改这项规则。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle(labels[attribute.id] ?? "修改规则")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            let value = editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty,
                                  let index = store.data.dynamicInvestorProfile.attributes.firstIndex(where: { $0.id == attribute.id }) else { return }
                            store.data.dynamicInvestorProfile.attributes[index] = InvestorProfileAttribute(
                                id: attribute.id, value: value, confidence: 1, source: .explicit,
                                sampleCount: 0, reason: "您主动修改并锁定", updatedAt: .now, locked: true)
                            store.save(label: "锁定投资者画像规则")
                            editing = nil
                        }
                    }
                }
            }
        }
    }

    private func roleBinding(_ symbol: String) -> Binding<String> {
        Binding(
            get: { profile.holdingRules.first(where: { $0.symbol == symbol })?.role.rawValue ?? "" },
            set: { value in
                store.data.dynamicInvestorProfile.holdingRules.removeAll { $0.symbol == symbol }
                if let role = HoldingRole(rawValue: value) {
                    store.data.dynamicInvestorProfile.holdingRules.append(
                        HoldingProfileRule(symbol: symbol, role: role))
                }
                store.save(label: "设置真实持仓定位")
            })
    }
}
