import SwiftUI

// MARK: - 账本与审计

/// 账本的自证页面。
///
/// 一个账本要能被信任，必须能回答三个问题：起点是什么、后来发生了什么、
/// 现在这份状态有没有被人悄悄改过。三个问题对应三块内容：起点快照、
/// 审计链、状态指纹。现金对账和起点重录也从这里发起。
struct LedgerAuditView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var showCashReconcile = false
    @State private var showOpeningRewrite = false
    @State private var showLiquidate = false
    @State private var toast: String?

    private var isLight: Bool {
        AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight
    }

    private var accent: Color { store.effectiveAccentColor }

    private var breaks: [Int] { store.ledgerAuditBreaks() }

    var body: some View {
        NavigationStack {
            List {
                stateSection
                openingSection
                cashSection
                auditSection
                actionsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("账本与审计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showCashReconcile) {
                LedgerConfirmationSheet(
                    title: "现金对账",
                    prompt: "实际现金（券商 App 里的可用 + 冻结）",
                    initialAmount: store.data.cash,
                    confirmTitle: "按实际金额校准",
                    explain: "差额会记成一条现金流，说明来由，不会凭空产生收益。",
                    onResult: { toast = $0 }
                ) { amount, note in
                    let delta = try store.reconcileCashToActual(amount, note: note)
                    return delta == 0 ? "账面现金与实际一致，未做改动。"
                        : String(format: "已按实际现金校准，差额 %+.2f 已记入现金流。", delta)
                }
            }
            .sheet(isPresented: $showOpeningRewrite) {
                LedgerConfirmationSheet(
                    title: "重写账本起点",
                    prompt: "起点现金",
                    initialAmount: store.data.openingSnapshot?.cash ?? store.data.cash,
                    confirmTitle: "改写起点",
                    explain: "当前持仓会原样写成新的起点快照。账本已有成交时不允许这样做。",
                    onResult: { toast = $0 }
                ) { amount, note in
                    let prior = store.data.cash
                    store.data.cash = amount
                    let confirmation = LedgerConfirmation(reason: "重写起点", note: note)
                    do {
                        try store.rewriteOpeningSnapshot(confirmation)
                        return "起点已重写。"
                    } catch {
                        store.data.cash = prior
                        throw error
                    }
                }
            }
            .sheet(isPresented: $showLiquidate) {
                LedgerConfirmationSheet(
                    title: "全部清仓",
                    prompt: "确认句（例如：换仓到宽基）",
                    initialAmount: nil,
                    confirmTitle: "按最新价全部卖出",
                    explain: "所有份额大于 0 的持仓会按最新价记成卖出成交，现金同步回款。没有行情的标的会跳过并告知。",
                    onResult: { toast = $0 }
                ) { _, note in
                    let result = try store.liquidateAllHoldings(kind: nil, note: note)
                    return result.skipped.isEmpty
                        ? "已清仓 \(result.sold) 只。"
                        : "已清仓 \(result.sold) 只；\(result.skipped.joined(separator: "、")) 没有可用行情，未处理。"
                }
            }
            .alert("完成", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
                Button("好", role: .cancel) { toast = nil }
            } message: { Text(toast ?? "") }
        }
    }

    // MARK: 状态

    private var stateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    statBlock("成交笔数", "\(store.data.ledger.count)")
                    statBlock("当前现金", "¥" + store.data.cash.cny())
                    statBlock("持仓市值", "¥" + store.totalMarketValue.cny())
                }
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: breaks.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(breaks.isEmpty ? CardTone.ok : CardTone.warn)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(breaks.isEmpty ? "审计链自洽" : "审计链有 \(breaks.count) 处断点")
                            .font(.footnote.weight(.semibold))
                        Text(breaks.isEmpty
                             ? "每一次账本改动都记录了前后状态指纹，链上没有缺口。"
                             : "第 \(breaks.map { String($0 + 1) }.joined(separator: "、")) 条起前后指纹对不上，说明有改动绕过了审计入口。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Text("当前指纹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(store.ledgerDigest)
                        .font(.caption2.monospaced())
                        .foregroundStyle(accent)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("账本状态")
        } footer: {
            Text("指纹由起点快照 + 现金 + 全部成交算得。任何一项变了，指纹就会变。")
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 起点

    private var openingSection: some View {
        Section {
            if let opening = store.data.openingSnapshot {
                HStack {
                    Text("记录时间")
                    Spacer()
                    Text(Self.dayTime.string(from: opening.capturedAt))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("来源")
                    Spacer()
                    Text(opening.source == .recorded ? "录入持仓时记录" : "首次保存时采纳")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("起点现金")
                    Spacer()
                    Text("¥" + opening.cash.cny()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("起点持仓")
                    Spacer()
                    Text("\(opening.positionCount) 只 · 成本 ¥" + opening.marketCostValue.cny())
                        .foregroundStyle(.secondary)
                }
                if !opening.positions.isEmpty {
                    DisclosureGroup("查看起点明细") {
                        ForEach(opening.positions) { position in
                            HStack {
                                Text(position.name).font(.footnote)
                                Text(position.code).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(position.quantity.num(0)) 份 @ \(position.cost.num(3))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.footnote)
                }
            } else {
                Label("还没有记录账本起点", systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                showOpeningRewrite = true
            } label: {
                Label("重写起点", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
            }
            .disabled(!store.canRewriteOpening)
            .opacity(store.canRewriteOpening ? 1 : 0.45)
        } header: {
            Text("起点快照")
        } footer: {
            Text(store.canRewriteOpening
                 ? "账本里还没有任何成交，此时持仓就等于起点，可以直接改写。"
                 : "账本里已有成交，起点不再是唯一事实来源。要减仓请记真实卖出。")
        }
    }

    // MARK: 现金

    private var cashSection: some View {
        Section {
            HStack {
                Text("账面现金")
                Spacer()
                Text("¥" + store.data.cash.cny())
                    .font(.subheadline.monospacedDigit())
            }
            HStack {
                Text("现金占比")
                Spacer()
                Text(store.cashPercent.pct(1))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                showCashReconcile = true
            } label: {
                Label("按券商实际金额校准", systemImage: "equal.circle")
                    .font(.subheadline)
            }
        } header: {
            Text("现金")
        } footer: {
            Text("差额会以「现金对账差额」记成一条现金流，收益归因里能查到来源。")
        }
    }

    // MARK: 审计链

    private var auditSection: some View {
        Section {
            if store.data.ledgerAudits.isEmpty {
                Label("还没有账本改动记录", systemImage: "tray")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.data.ledgerAudits.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.action)
                                .font(.footnote.weight(.semibold))
                            Spacer()
                            Text(Self.dayTime.string(from: event.occurredAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(event.digestPair)
                            .font(.caption2.monospaced())
                            .foregroundStyle(accent.opacity(0.8))
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("审计链（\(store.data.ledgerAudits.count) 条）")
        } footer: {
            Text("尾部的「前 → 后」是状态指纹片段。相邻两条必须首尾相接。")
        }
    }

    // MARK: 操作

    private var actionsSection: some View {
        Section {
            Button(role: .destructive) {
                showLiquidate = true
            } label: {
                Label("全部清仓", systemImage: "arrow.down.to.line")
                    .font(.subheadline)
            }
            Button {
                if let label = store.undoLatestOperation() {
                    toast = "已撤回「\(label)」。"
                } else {
                    toast = "没有可撤回的操作。"
                }
            } label: {
                Label("撤回最近一次账本改动", systemImage: "arrow.uturn.backward")
                    .font(.subheadline)
            }
            .disabled(!store.canUndoLatestOperation)
        } header: {
            Text("操作")
        } footer: {
            Text("撤回是整份账本回到改动之前，会同时撤销那一次的所有连带影响。")
        }
    }

    private static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 通用「填个数字 + 写句原因」确认表单

/// 账本改写都需要同一种输入：一个可选金额、一句必填说明。
/// 三个入口共用一张表单，省得每处各写一遍校验和文案。
struct LedgerConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    let title: String
    let prompt: String
    let initialAmount: Double?
    let confirmTitle: String
    let explain: String
    /// 成功后把结论回传给上一页（用来弹提示）。
    /// 必须声明在 `perform` 之前：成员初始化器的参数顺序跟着属性声明走，
    /// 而尾部闭包只会绑定最后一个闭包参数，也就是 `perform`。
    var onResult: (String) -> Void = { _ in }
    /// 返回给用户看的结论。抛错则留在表单里显示原因。
    let perform: (Double, String) throws -> String

    @State private var amountText = ""
    @State private var note = ""
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case amount, note }

    private var isLight: Bool {
        AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight
    }

    private var parsedAmount: Double? {
        let cleaned = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if initialAmount != nil {
                    Section {
                        HStack {
                            Text("¥").foregroundStyle(.secondary)
                            TextField("0.00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .amount)
                                .monospacedDigit()
                        }
                    } header: {
                        Text(prompt)
                    }
                }

                Section {
                    TextField(initialAmount == nil ? prompt : "说明（必填）", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focus, equals: .note)
                } header: {
                    Text("原因")
                } footer: {
                    Text(explain)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CardTone.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        Text(confirmTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if let initialAmount { amountText = String(format: "%.2f", initialAmount) }
                focus = initialAmount != nil ? .amount : .note
            }
        }
    }

    private func submit() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请填写原因，审计链需要它。"
            return
        }
        let amount: Double
        if initialAmount != nil {
            guard let parsed = parsedAmount else {
                errorText = "金额必须是有效的非负数。"
                return
            }
            amount = parsed
        } else {
            amount = 0
        }
        do {
            let message = try perform(amount, trimmed)
            Haptics.success()
            onResult(message)
            dismiss()
        } catch {
            Haptics.heavy()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
