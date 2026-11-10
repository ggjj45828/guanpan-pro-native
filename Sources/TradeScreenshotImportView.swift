import SwiftUI
import PhotosUI

// MARK: - 成交截图导入：识别 → 金额核对 → 逐笔↔汇总对账 → 费用确认 → 预览 → 批量写入
//
// 复用 Pro 已有的 `TradeCSVParser.parse` 与 `store.importTradeLedger`，
// 不另写账本逻辑：后者自带跨文件去重、卖出数量校验、成本重放与一次性写入。
// 导入只写历史流水，`affectsHoldings = false`，不会改动当前持仓与现金。
//
// 两条红线（对照观盘max 清单里标「未完成」的两项）：
// 1. 截图没有手续费列，不能把「不知道」记成 0 —— 必须逐笔补录，或明确勾选参考值。
// 2. 选了汇总截图就必须与逐笔截图对上；任一代码缺失或数量/金额不符，整批拦截。

struct TradeScreenshotImportView: View {
    /// 推入已有导航栈时 true：不再自建 NavigationStack，隐藏完成/关闭按钮。
    var embedded: Bool = false
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var summaryItems: [PhotosPickerItem] = []
    @State private var tradingDay = Date()
    @State private var rows: [ScreenshotTradeRow] = []
    @State private var summaryRows: [ScreenshotSummaryRow] = []
    @State private var drafts: [TradeImportDraft] = []
    @State private var message = ""
    @State private var isWorking = false
    @State private var didValidate = false
    @State private var useReferenceFee = false

    private var s: ThemeSemantics { .of(appearance) }
    private var validCount: Int { drafts.filter { $0.selected && $0.isValid }.count }
    private var missingFeeCount: Int {
        drafts.filter { $0.selected && $0.isValid && feeFor($0) == nil }.count
    }
    private var commitReady: Bool { didValidate && validCount > 0 && missingFeeCount == 0 }

    var body: some View {
        PageHost(embedded: embedded) {
            Form {
                Section("选择截图") {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 10,
                                 matching: .images) {
                        Label("逐笔成交截图（可多选）", systemImage: "photo.on.rectangle.angled")
                    }
                    PhotosPicker(selection: $summaryItems, maxSelectionCount: 4,
                                 matching: .images) {
                        Label("按股票汇总截图（可选，用于交叉核对）", systemImage: "list.bullet.rectangle")
                    }
                    DatePicker("成交日期", selection: $tradingDay, displayedComponents: .date)
                    Button {
                        Task { await run() }
                    } label: {
                        Text(isWorking ? "识别中…" : "识别并核对")
                    }
                    .disabled(isWorking || selectedItems.isEmpty)
                    Text("长截图 / 多张截图会按行指纹去重；价×量与金额不符、疑似成交行解析失败、或逐笔与汇总对不上，都整批拦截。未提供汇总截图时不做交叉核对，结果里会明确写出。")
                        .font(.footnote)
                        .foregroundStyle(s.ink2)
                    Text("截图里没有手续费列，必须逐笔补录或明确确认使用参考值，不能按 0 计入成本。")
                        .font(.footnote)
                        .foregroundStyle(s.ink2)
                }

                if !message.isEmpty {
                    Section("识别结果") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(s.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !rows.isEmpty {
                    Section("逐笔成交 · \(rows.count)") {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(row.name).font(.subheadline).foregroundStyle(s.ink)
                                    Spacer()
                                    Text(row.side)
                                        .font(.caption)
                                        .foregroundStyle(row.side == "买入" ? s.danger : s.ok)
                                }
                                Text("\(row.code) · \(row.time) · \(row.price) × \(row.units) = \(row.amount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(s.ink2)
                            }
                        }
                    }
                }

                if !summaryRows.isEmpty {
                    Section("汇总行 · \(summaryRows.count)") {
                        ForEach(summaryRows) { row in
                            HStack {
                                Text("\(row.name.isEmpty ? row.code : row.name) · \(row.code)")
                                    .font(.caption).foregroundStyle(s.ink)
                                Spacer()
                                Text("\(row.units) 份 / ¥\(row.amount)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(s.ink2)
                            }
                        }
                    }
                }

                if !drafts.isEmpty {
                    Section("导入预览 · 可写入 \(validCount) 行") {
                        ForEach($drafts) { $draft in
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(isOn: $draft.selected) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(draft.name.isEmpty ? draft.code : draft.name) · \(draft.code)")
                                            .font(.subheadline)
                                            .foregroundStyle(s.ink)
                                        Text(draft.error ?? "\(draft.side?.rawValue == "sell" ? "卖出" : "买入") \(draft.quantity.num(0)) × \(draft.price.num(3))")
                                            .font(.caption)
                                            .foregroundStyle(draft.error == nil ? s.ink2 : s.danger)
                                    }
                                }
                                .disabled(draft.error != nil)
                                if draft.error == nil {
                                    HStack(spacing: 8) {
                                        Text("手续费 ¥").font(.caption).foregroundStyle(s.ink2)
                                        TextField("未填写", text: $draft.feeText)
                                            .keyboardType(.decimalPad)
                                            .multilineTextAlignment(.trailing)
                                            .foregroundStyle(s.ink)
                                            .frame(maxWidth: 90)
                                        Spacer(minLength: 4)
                                        feeHint(draft)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        Toggle(isOn: $useReferenceFee) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("未填写的用每笔 ¥0.10 参考值")
                                    .font(.subheadline).foregroundStyle(s.ink)
                                Text("占位值，不是券商实际收费；只用于不把成本记成 0，之后仍应逐笔更正。")
                                    .font(.caption2).foregroundStyle(s.ink3)
                            }
                        }

                        if missingFeeCount > 0 {
                            Text("还有 \(missingFeeCount) 笔手续费未确认，不能写入账本。")
                                .font(.caption).foregroundStyle(s.warn)
                        }

                        Button {
                            commit()
                        } label: {
                            Text("批量写入账本（仅历史流水）")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                                .foregroundStyle(s.onAccent)
                        }
                        .listRowBackground(s.accent)
                        .disabled(!commitReady)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("截图导入成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if !embedded { Button("完成") { dismiss() } } }
            }
            .keyboardDoneToolbar()
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func feeHint(_ draft: TradeImportDraft) -> some View {
        if !draft.feeText.isEmpty && parsedFee(draft.feeText) == nil {
            Text("数值无效").font(.caption2).foregroundStyle(s.danger)
        } else if !draft.feeText.isEmpty {
            Text("已逐笔补录").font(.caption2).foregroundStyle(s.ok)
        } else if useReferenceFee {
            Text("参考值 ¥0.10").font(.caption2).foregroundStyle(s.warn)
        } else {
            Text("待确认").font(.caption2).foregroundStyle(s.warn)
        }
    }

    private func parsedFee(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "¥", with: "")
        guard let fee = Double(value), fee.isFinite, fee >= 0 else { return nil }
        return fee
    }

    private func feeFor(_ draft: TradeImportDraft) -> Double? {
        if let typed = parsedFee(draft.feeText) { return typed }
        if useReferenceFee { return 0.10 }
        return nil
    }

    private func appliedDrafts() -> [TradeImportDraft] {
        drafts.map { draft in
            var copy = draft
            if let typed = parsedFee(draft.feeText) {
                copy.fee = typed
                copy.feeKnown = true
                copy.feeOrigin = .confirmed
            } else if useReferenceFee {
                copy.fee = 0.10
                copy.feeKnown = true
                copy.feeOrigin = .reference
            } else {
                copy.feeKnown = false
                copy.feeOrigin = .missing
            }
            return copy
        }
    }

    private func run() async {
        isWorking = true
        defer { isWorking = false }
        do {
            var data: [Data] = []
            for item in selectedItems {
                if let imageData = try await item.loadTransferable(type: Data.self) {
                    data.append(imageData)
                }
            }
            guard !data.isEmpty else { throw ScreenshotOCRError.invalidImage }
            let recognized = try await TradeScreenshotOCR.extractRows(from: data)
            try TradeScreenshotOCR.validate(recognized)

            var summaryData: [Data] = []
            for item in summaryItems {
                if let imageData = try await item.loadTransferable(type: Data.self) {
                    summaryData.append(imageData)
                }
            }
            var checkedSummary: [ScreenshotSummaryRow] = []
            if !summaryItems.isEmpty {
                guard !summaryData.isEmpty else { throw ScreenshotOCRError.invalidImage }
                checkedSummary = try await TradeScreenshotOCR.extractSummaryRows(from: summaryData)
                try TradeScreenshotOCR.reconcile(details: recognized, summary: checkedSummary)
            }

            let table = TradeScreenshotOCR.draftTable(recognized, tradingDay: tradingDay)
            let parsed = TradeCSVParser.parse(table).map { draft in
                var copy = draft
                copy.feeKnown = false
                copy.feeOrigin = .missing
                copy.feeText = ""
                return copy
            }
            rows = recognized
            summaryRows = checkedSummary
            drafts = parsed
            didValidate = true
            let invalid = parsed.filter { !$0.isValid }.count
            let reconcileText = checkedSummary.isEmpty
                ? "未提供汇总截图，未做逐笔↔汇总交叉核对"
                : "与 \(checkedSummary.count) 行汇总交叉核对通过"
            message = "识别 \(recognized.count) 行（已跨图去重），价量金额核对通过；\(reconcileText)。解析出 \(parsed.count) 行，其中 \(invalid) 行需人工核对；手续费需逐笔确认。"
        } catch {
            rows = []
            summaryRows = []
            drafts = []
            didValidate = false
            message = error.localizedDescription
        }
    }

    private func commit() {
        guard commitReady else {
            message = "请先完成识别、对账，并确认每一笔手续费。"
            return
        }
        do {
            let inserted = try store.importTradeLedger(appliedDrafts())
            message = inserted > 0
                ? "已写入 \(inserted) 条历史成交；当前持仓与现金未改动。"
                : "没有新增记录（可能都已存在，账本已按代码 / 日期 / 方向 / 数量 / 价格去重）。"
            drafts = []
            rows = []
            summaryRows = []
            didValidate = false
        } catch {
            message = "写入失败，账本未被改动：\(error.localizedDescription)"
        }
    }
}
