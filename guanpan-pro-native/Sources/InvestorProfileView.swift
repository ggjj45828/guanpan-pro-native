import Foundation
import SwiftUI

// MARK: - AI 对我的了解

/// 一个页面就够：不做「画像实验室」，不要求用户填问卷。
/// 每张卡都是「AI 目前的结论 + 置信度 + 为什么」，点开可以修改、可以否掉、可以重新学习。
struct InvestorProfileScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var detailTrait: NextProfileTraitID?
    @State private var editTrait: NextProfileTraitID?
    @State private var confirmingReset = false

    /// 卡片顺序：先讲长期计划，再讲交易习惯，最后讲执行方式——和用户关心的顺序一致。
    private let showcase: [NextProfileTraitID] = [.horizon, .style, .tAppetite, .tradeFrequency,
                                                  .limitPatience, .cashPreference, .gridAppetite, .execution]

    private var profile: NextInvestorProfile { model.profile }

    var body: some View {
        GPPageBackground {
            header
            summaryCard
            showcaseGrid
            thresholdCard
            roleCard
            learningCard
        }
        // 页面自带大标题：不再设 navigationTitle，否则导航条和正文标题会重复一行。
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailTrait) { id in
            ProfileTraitDetailSheet(traitID: id,
                                    onEdit: { editTrait = id; detailTrait = nil },
                                    onInaccurate: { model.markProfileTraitInaccurate(id); detailTrait = nil },
                                    onReset: { model.resetProfileLearning(); detailTrait = nil })
                .environmentObject(model)
        }
        .sheet(item: $editTrait) { id in
            ProfileTraitEditSheet(traitID: id).environmentObject(model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 对我的了解")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(p.ink)
            Text("不是风险测评问卷：每一条结论都来自你的真实持仓、真实成交和你的反馈。数据不够时它只会说「还不够判断」。")
                .font(.caption).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10).padding(.bottom, 12)
    }

    private var summaryCard: some View {
        GPCard(accent: p.terracotta) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("现在的你")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                    Text(profile.styleTags.prefix(3).joined(separator: " · "))
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(p.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                ZStack {
                    Circle().stroke(p.line, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.02, averageConfidence))
                        .stroke(p.terracotta, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((averageConfidence * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(p.ink)
                }
                .frame(width: 54, height: 54)
            }
            Divider().overlay(p.line)
            HStack(spacing: 0) {
                statTile("真实成交", "\(profile.summary.fillSampleCount) 笔")
                statTile("AI 建议", "\(profile.summary.suggestionSampleCount) 次")
                statTile("已执行", "\(profile.summary.executedCount) 次")
                statTile("看了没做", "\(profile.summary.ignoredCount) 次")
            }
            Text("最近一次学习：\(model.profile.updatedAt.formatted(date: .numeric, time: .shortened))｜样本窗口 \(profile.summary.windowDays) 天｜异常成交已过滤 \(profile.summary.anomalyCount) 笔")
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(p.muted).lineLimit(1)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(p.ink).lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showcaseGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(showcase.enumerated()), id: \.element) { index, id in
                if let trait = profile.trait(id) {
                    Button { detailTrait = id } label: {
                        ProfileTraitCard(trait: trait, tone: tone(for: index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看 AI 为什么这样判断")
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var thresholdCard: some View {
        GPCard(accent: p.chartGold) {
            HStack {
                Text("你的执行门槛").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Spacer()
                Text("AI 低于门槛时不主动推荐").font(.system(size: 10)).foregroundStyle(p.muted)
            }
            thresholdRow(.minSpread, value: String(format: "%.2f%%", profile.thresholds.minTSpreadPercent),
                         detail: "做 T 预期价差低于此值不推荐")
            thresholdRow(.minNetGain, value: "¥\(String(format: "%.0f", profile.thresholds.minTNetGain))",
                         detail: "扣完两笔手续费后的净收益门槛")
            thresholdRow(.gridTiers, value: "\(profile.thresholds.gridMaxTiers) 档",
                         detail: "网格最多档数，超过会自动压缩")
            Text("单次做 T 份额上限：可用份额的 \(Int((profile.thresholds.maxTUnitsRatio * 100).rounded()))%｜最低现金储备：总资产 \(Int((profile.thresholds.cashFloorRatio * 100).rounded()))%")
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thresholdRow(_ id: NextProfileTraitID, value: String, detail: String) -> some View {
        Button { editTrait = id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.title).font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink)
                    Text(detail).font(.system(size: 10)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 6)
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(p.chartGold)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var roleCard: some View {
        GPCard(accent: p.jade) {
            Text("每只标的的身份")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
            Text("同一套习惯不能套到所有标的：长期核心仓不做日内往返，行业机动仓才可以做 T 和网格。AI 会按真实持有行为推断，你也可以直接锁定。")
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.book.positions.isEmpty {
                GPInlineEmpty(symbol: "tray", text: "还没有真实持仓：录入持仓后，AI 才会给每只标的判定身份。")
            } else {
                ForEach(model.book.positions.filter { $0.units > 0 }) { position in
                    ProfileRoleRow(code: position.code, name: position.name,
                                   entry: profile.role(for: position.code)) { role in
                        model.setInstrumentRole(position.code, role: role)
                    }
                }
            }
        }
    }

    private var learningCard: some View {
        GPCard(accent: p.chartViolet) {
            Text("AI 是怎么学的")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
            Text("只用真实持仓、真实成交、真实反馈。不使用虚拟交易训练，不建模拟账户，不会自动下单。")
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(profile.summary.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(p.chartViolet.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                    Text(note).font(.system(size: 10)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if confirmingReset {
                Text("重新学习会清掉所有「AI 学习得到」的结论，只保留你明确设定的规则和锁定的标的。")
                    .font(.system(size: 10)).foregroundStyle(p.risk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(p.line)
            Text("在线 AI 每次只会收到这几行（不包含你的成交明细）")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(p.ink)
            ForEach(Array(NextProfileEngine.promptLines(profile: profile).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(p.forest.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                    Text(line).font(.system(size: 10)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(confirmingReset ? "确认重新学习" : "让 AI 重新学习") {
                    if confirmingReset { model.resetProfileLearning(); confirmingReset = false }
                    else { confirmingReset = true }
                }
                .font(.system(size: 12, weight: .semibold))
                .tint(confirmingReset ? p.risk : p.chartViolet)
                Spacer()
                Button("现在重算一次") { model.learnProfile() }
                    .font(.system(size: 12, weight: .semibold)).tint(p.forest)
            }
            .padding(.top, 2)
        }
    }

    private var averageConfidence: Double {
        let known = profile.knownTraits.filter { $0.isKnown && $0.source != .temporary }
        guard !known.isEmpty else { return 0 }
        return min(1, known.map(\.confidence).reduce(0, +) / Double(known.count))
    }

    private func tone(for index: Int) -> Color {
        let palette = [p.terracotta, p.forest, p.jade, p.chartGold, p.chartViolet]
        return palette[index % palette.count]
    }
}

// MARK: - 画像卡

private struct ProfileTraitCard: View {
    @Environment(\.gp) private var p
    let trait: NextProfileTrait
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: trait.id.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone)
                Text(trait.id.title).font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
                Spacer(minLength: 2)
                if trait.locked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(tone)
                }
            }
            Text(trait.label)
                .font(.system(size: 15, weight: .bold)).foregroundStyle(p.ink)
                .lineLimit(2).minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(trait.confidenceText)
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(trait.isKnown ? tone : p.muted)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tone.opacity(0.14))
                    Capsule().fill(tone.opacity(trait.isKnown ? 0.85 : 0.25))
                        .frame(width: max(3, geo.size.width * max(0.03, trait.confidence)))
                }
            }
            .frame(height: 3)
            if trait.isMuted {
                Text("已暂停学习 30 天").font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tone.opacity(0.28), lineWidth: 0.8))
    }
}

// MARK: - 为什么这样判断

private struct ProfileTraitDetailSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let traitID: NextProfileTraitID
    let onEdit: () -> Void
    let onInaccurate: () -> Void
    let onReset: () -> Void

    private var trait: NextProfileTrait? { model.profile.trait(traitID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let trait {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(trait.id.title).font(.system(size: 12, weight: .medium)).foregroundStyle(p.muted)
                            Text(trait.label).font(.system(size: 24, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                            Text(trait.detail).font(.system(size: 12)).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            badge(trait.source.rawValue, color: trait.source == .explicit ? p.jade : (trait.source == .temporary ? p.chartGold : p.forest))
                            badge(trait.confidenceText, color: p.chartViolet)
                            if trait.locked { badge("已锁定", color: p.chartGold) }
                        }
                        GPCard {
                            Text("AI 的依据").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                            ForEach(Array(trait.basis.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle().fill(p.forest.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                                    Text(line).font(.system(size: 11)).foregroundStyle(p.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("样本 \(trait.sampleCount) 个｜窗口 \(trait.windowDays == 0 ? "你直接设定" : "\(trait.windowDays) 天")｜更新于 \(trait.updatedAt.formatted(date: .numeric, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        GPCard(accent: p.chartGold) {
                            Text("画像的边界").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                            Text("这条结论只影响推荐优先级和表达方式：不改变行情事实，不降低数据质量与风险门槛，也不会让 AI 为了迎合你而制造交易机会。")
                                .font(.system(size: 10)).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        GPActionButton(title: "修改这一项", systemImage: "slider.horizontal.3") { onEdit() }
                        GPActionButton(title: "这个判断不准确", secondary: true, systemImage: "hand.thumbsdown") { onInaccurate() }
                        if trait.locked {
                            Text("这项已由你锁定：自动学习不会再改动它。")
                                .font(.system(size: 10)).foregroundStyle(p.muted)
                        }
                    } else {
                        GPStatus(title: "还没有这一项的结论", detail: "AI 需要更多真实成交或反馈才会形成判断。", symbol: "hourglass")
                    }
                }
                .padding(16)
            }
            .background(p.canvas.ignoresSafeArea())
            .navigationTitle("AI 为什么这样认为")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 修改某一项

private struct ProfileTraitEditSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let traitID: NextProfileTraitID

    @State private var numericText = ""
    @State private var selectedValue = ""
    @State private var errorText: String?

    private var trait: NextProfileTrait? { model.profile.trait(traitID) }
    private var options: [NextProfileOption] { NextProfileCatalog.options(for: traitID) }
    private var isNumeric: Bool { NextProfileCatalog.isNumeric(traitID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNumeric {
                        HStack {
                            TextField("数值", text: $numericText).keyboardType(.decimalPad)
                            Text(NextProfileCatalog.numericUnit(traitID)).foregroundStyle(.secondary)
                        }
                    } else if options.isEmpty {
                        Text("这一项由 AI 根据行为自动生成，不能直接选；可以点「这个判断不准确」让它重新学。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                selectedValue = option.value
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: selectedValue == option.value ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedValue == option.value ? p.forest : p.muted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                                        Text(option.detail).font(.system(size: 10)).foregroundStyle(p.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(traitID.title)
                } footer: {
                    Text("你改过的项目会变成「你明确设定」，AI 学习不会再覆盖它。")
                }
                if let errorText {
                    Section { Text(errorText).font(.caption).foregroundStyle(p.risk) }
                }
            }
            .navigationTitle("修改「\(traitID.title)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!isNumeric && selectedValue.isEmpty && !options.isEmpty)
                }
            }
            .onAppear { seed() }
        }
    }

    private func seed() {
        guard let trait else { return }
        selectedValue = trait.value
        if isNumeric, let numeric = trait.numeric { numericText = String(format: "%.2f", numeric) }
        if isNumeric, trait.numeric == nil { numericText = "" }
    }

    private func save() {
        if isNumeric {
            guard let value = Double(numericText.replacingOccurrences(of: ",", with: ".")) else {
                errorText = "请输入有效数字"; return
            }
            let detail: String
            switch traitID {
            case .minSpread: detail = "你设定的最低做 T 价差：低于 \(String(format: "%.2f", value))% 的机会不再主动推荐"
            case .minNetGain: detail = "你设定的最低净收益：低于 ¥\(String(format: "%.0f", value)) 不再主动推荐"
            default: detail = "你设定的网格最大档数：超过会自动压缩到 \(Int(value.rounded())) 档"
            }
            let label: String
            switch traitID {
            case .minSpread: label = String(format: "%.2f%% 以上才做", value)
            case .minNetGain: label = "≥ ¥\(String(format: "%.0f", value))"
            default: label = "最多 \(Int(value.rounded())) 档"
            }
            model.setProfileTrait(traitID, value: "explicit", label: label, detail: detail, numeric: value)
            dismiss()
            return
        }
        guard let option = options.first(where: { $0.value == selectedValue }) else {
            errorText = "请选择一个选项"; return
        }
        model.setProfileTrait(traitID, value: option.value, label: option.label, detail: option.detail)
        dismiss()
    }
}

// MARK: - 标的身份行

private struct ProfileRoleRow: View {
    @Environment(\.gp) private var p
    let code: String
    let name: String
    let entry: NextInstrumentRole
    let onPick: (NextInstrumentRole.Role) -> Void

    private var tone: Color {
        switch entry.role {
        case .core: return p.jade
        case .tactical: return p.chartGold
        case .undecided: return p.muted
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
                Text(entry.reason).font(.system(size: 9.5)).foregroundStyle(p.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Menu {
                ForEach([NextInstrumentRole.Role.core, .tactical, .undecided], id: \.rawValue) { role in
                    Button(role.rawValue) { onPick(role) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(entry.role.rawValue).font(.system(size: 10, weight: .semibold))
                    if entry.locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .semibold)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(tone)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(tone.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }
}
