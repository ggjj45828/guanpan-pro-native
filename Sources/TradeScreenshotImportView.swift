import SwiftUI
import PhotosUI

// MARK: - 成交截图导入：识别 → 核对 → 预览 → 批量写入
//
// 复用 Pro 已有的 `TradeCSVParser.parse` 与 `store.importTradeLedger`，
// 不另写账本逻辑：后者自带跨文件去重、卖出数量校验、成本重放与一次性写入。
// 导入只写历史流水，`affectsHoldings = false`，不会改动当前持仓与现金。

struct TradeScreenshotImportView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var tradingDay = Date()
    @State private var rows: [ScreenshotTradeRow] = []
    @State private var drafts: [TradeImportDraft] = []
    @State private var message = ""
    @State private var isWorking = false
    @State private var didValidate = false

    private var s: ThemeSemantics { .of(appearance) }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择截图") {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 10,
                                 matching: .images) {
                        Label("选择同花顺成交截图（可多选）", systemImage: "photo.on.rectangle.angled")
                    }
                    DatePicker("成交日期", selection: $tradingDay, displayedComponents: .date)
                    Button {
                        Task { await run() }
                    } label: {
                        Text(isWorking ? "识别中…" : "识别并核对")
                    }
                    .disabled(isWorking || selectedItems.isEmpty)
                    Text("长截图 / 多张截图会按行指纹去重；「价格 × 数量」与成交金额对不上、或疑似成交行解析失败时整批拦截。")
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
                    Section("识别到的成交行 · \(rows.count)") {
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

                if !drafts.isEmpty {
                    Section("导入预览 · 可写入 \(validCount) 行") {
                        ForEach($drafts) { $draft in
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
                        .disabled(validCount == 0)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("截图导入成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private var validCount: Int { drafts.filter { $0.selected && $0.isValid }.count }

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
            rows = recognized
            let table = TradeScreenshotOCR.draftTable(recognized, tradingDay: tradingDay)
            drafts = TradeCSVParser.parse(table)
            didValidate = true
            let invalid = drafts.filter { !$0.isValid }.count
            message = "识别 \(recognized.count) 行（已跨图去重），金额核对通过；解析出 \(drafts.count) 行，其中 \(invalid) 行需人工核对。"
        } catch {
            rows = []
            drafts = []
            didValidate = false
            message = error.localizedDescription
        }
    }

    private func commit() {
        guard didValidate else {
            message = "请先完成识别与金额核对。"
            return
        }
        do {
            let inserted = try store.importTradeLedger(drafts)
            message = inserted > 0
                ? "已写入 \(inserted) 条历史成交；当前持仓与现金未改动。"
                : "没有新增记录（可能都已存在，账本已按代码 / 日期 / 方向 / 数量 / 价格去重）。"
            drafts = []
            rows = []
            didValidate = false
        } catch {
            message = "写入失败，账本未被改动：\(error.localizedDescription)"
        }
    }
}
