import SwiftUI

// MARK: - 删除持仓：先把「删」的真实含义讲清楚
//
// 本文件是 `Tools/theme_contract.json` 的受管表单之一：
// 文字一律走 `ThemeSemantics`，禁止 `.secondary` / `.primary` / 写死白字；
// 固定底部确认区也用语义色，避免换主题时出现「深色卡片配浅底」。

/// 删除一只持仓时，账本里到底发生了什么。
///
/// 原来只有一句「删除持仓」，用户根本无从判断这一下会让现金变还是不变、
/// 已实现收益会不会动、历史流水还在不在。这个表单把三种可能的真实含义
/// 摆出来让他选，并且要求填一句说明 —— 那句话会进审计链，
/// 三个月后回看时还知道当时为什么删的。
struct HoldingRemovalSheet: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    let holding: Holding
    var onFinished: (String) -> Void

    @State private var mode: HoldingRemovalMode = .recordSale
    @State private var note = ""
    @State private var errorText: String?
    @State private var isRunning = false
    @FocusState private var noteFocused: Bool

    private var s: ThemeSemantics { .of(appearance) }
    private var layout: ThemeLayout { ThemeLayout.of(appearance) }
    private var accent: Color { s.accent }

    /// 该标的在账本里的成交笔数。
    private var fillCount: Int {
        store.data.ledger.filter { $0.code == holding.code && ($0.kind ?? .etf) == holding.kind }.count
    }

    private var hasHistory: Bool { fillCount > 0 }

    /// 可用模式：有成交就不能改写起点；零份额没什么可卖。
    private func isEnabled(_ candidate: HoldingRemovalMode) -> Bool {
        switch candidate {
        case .rewriteOpening: return !hasHistory
        case .recordSale: return holding.quantity > 0 && holding.current > 0
        case .removeOnly: return true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: layout.sectionGap) {
                    summaryCard
                    stateCard
                    modeSection
                    noteSection
                }
                .padding(.horizontal, layout.pageInset)
                .padding(.vertical, layout.pad)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .themedFormBackground(s)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                confirmationBar
            }
            .navigationTitle("删除持仓")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .keyboardDoneToolbar()
            .onAppear {
                // 默认选「最诚实、信息量最大」的那一条：
                // 有成交 → 记卖出；没成交 → 改写起点。
                mode = hasHistory ? .recordSale : .rewriteOpening
            }
        }
        .presentationDetents([.large])
    }

    // MARK: 标的摘要

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(holding.name)
                    .font(.headline)
                    .foregroundStyle(s.ink)
                    .lineLimit(1)
                Text(holding.code)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(s.ink2)
                Spacer()
                Text("ETF")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(accent)
            }
            HStack(spacing: 16) {
                metric("持有份额", holding.quantity.num(0))
                metric("成本单价", holding.cost.num(3))
                metric("最新价", holding.current.num(3))
            }
            HStack(spacing: 16) {
                metric("持仓市值", "¥" + holding.marketValue.cny())
                metric("浮动盈亏", (holding.pnl >= 0 ? "+" : "") + "¥" + holding.pnl.cny(),
                       tint: CardTone.pnl(holding.pnl))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(layout.pad)
        .background(cardBackground(tone: nil))
    }

    private func metric(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(s.ink2)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(tint ?? s.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 账本现状

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(hasHistory ? "这只标的已有 \(fillCount) 笔成交" : "这只标的还没有任何成交",
                  systemImage: hasHistory ? "list.bullet.rectangle" : "clock.badge.checkmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(hasHistory ? s.warn : s.ok)
            Text(hasHistory
                 ? "既然有成交，账本的全部事实就已经确定。删除必须落成笔成交，否则现金和已实现收益会凭空对不上。"
                 : "目前它只是起点快照的一部分，还没有需要保留的历史。删除等于修改起点，不产生假成交。")
                .font(.caption)
                .foregroundStyle(s.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(layout.pad)
        .background(cardBackground(tone: hasHistory ? s.warn : s.ok))
    }

    // MARK: 模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            Text("怎么删")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(s.ink2)
            ForEach(HoldingRemovalMode.allCases) { candidate in
                modeRow(candidate)
            }
        }
    }

    private func modeRow(_ candidate: HoldingRemovalMode) -> some View {
        let enabled = isEnabled(candidate)
        let selected = mode == candidate
        return Button {
            guard enabled else { return }
            Haptics.tap()
            mode = candidate
            errorText = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? accent : s.ink3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(enabled ? s.ink : s.ink3)
                    Text(enabled ? candidate.subtitle : disabledHint(candidate))
                        .font(.caption2)
                        .foregroundStyle(s.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: candidate.icon)
                    .font(.footnote)
                    .foregroundStyle(enabled ? accent.opacity(0.8) : s.ink3)
            }
            .padding(layout.pad)
            .background(cardBackground(tone: selected ? accent : nil))
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func disabledHint(_ candidate: HoldingRemovalMode) -> String {
        switch candidate {
        case .rewriteOpening: return "已有成交，起点不再是唯一事实来源，不能在设置里直接改写。"
        case .recordSale: return holding.quantity <= 0 ? "份额为 0，没有可卖的东西。" : "没有可用行情，先刷新行情再试。"
        case .removeOnly: return ""
        }
    }

    // MARK: 说明

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("改动说明（必填）")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(s.ink2)
            TextField("例如：打新中签后卖出、录错了标的", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .foregroundStyle(s.ink)
                .focused($noteFocused)
                .padding(10)
                .background(cardBackground(tone: nil))
            Text("这句话会写进账本审计链，之后在「账本与审计」里可以回看。")
                .font(.caption2)
                .foregroundStyle(s.ink3)
        }
    }

    // MARK: 固定底部确认区

    private var confirmationBar: some View {
        VStack(spacing: 6) {
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(s.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                performRemoval()
            } label: {
                HStack(spacing: 8) {
                    if isRunning { ProgressView().tint(s.onAccent) }
                    Text(isRunning ? "处理中…" : "确认删除")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                .background(mode == .recordSale ? accent : s.warn,
                            in: RoundedRectangle(cornerRadius: layout.radius, style: .continuous))
                .foregroundStyle(s.onAccent)
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(confirmTitle)
        }
        .themedConfirmBar(s)
    }

    /// 按钮上方那行说明保留完整含义，避免固定栏太窄把长句截断。
    private var confirmTitle: String {
        switch mode {
        case .recordSale: return "记入卖出并移除持仓"
        case .rewriteOpening: return "从起点快照移除"
        case .removeOnly: return "仅移除持仓行"
        }
    }

    private func performRemoval() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请先填写改动说明，审计链需要它。"
            noteFocused = true
            return
        }
        errorText = nil
        isRunning = true
        do {
            let message = try store.removeHoldingHonestly(holding, mode: mode, note: trimmed)
            Haptics.success()
            isRunning = false
            onFinished(message)
            dismiss()
        } catch {
            Haptics.heavy()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isRunning = false
        }
    }

    // MARK: 卡面

    private func cardBackground(tone: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
        let fillTint: Color = tone.map { $0.opacity(s.isLight ? 0.08 : 0.12) } ?? .clear
        let borderTint: Color = tone.map { $0.opacity(s.isLight ? 0.30 : 0.38) } ?? s.hairline
        return shape
            .fill(s.card)
            .overlay(shape.fill(fillTint))
            .overlay(shape.strokeBorder(borderTint, lineWidth: 0.8))
    }
}
