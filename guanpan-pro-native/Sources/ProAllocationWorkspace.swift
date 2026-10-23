import SwiftUI

struct ProAllocationWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var code = ""
    @State private var name = ""
    @State private var percent = ""
    @State private var editing = false
    @State private var error = ""
    private var targets: [AllocationTarget] { store.data.allocationTargets.filter { $0.kind == .etf } }
    private var total: Double { targets.reduce(0) { $0 + $1.targetPercent } }
    var body: some View {
        ProPage(title: "先定长期方向", subtitle: "目标只是一份计划，不改变真实持仓与现金") {
            HStack { ProMetric(title: "证券目标", value: total.num(1) + "%"); ProMetric(title: "计划保留现金", value: max(0, 100 - total).num(1) + "%") }.proSurface(tone: .teal)
            if targets.isEmpty { ProEmpty(title: "从一个可调整的目标开始", detail: "已有或尚未持有的 ETF/股票都可以安排目标，现金不足也能规划。", icon: "target") }
            ForEach(targets) { target in
                Button { code = target.code; name = target.name; percent = String(target.targetPercent); error = ""; editing = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(target.name).foregroundStyle(.primary); Text(target.code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        Spacer()
                        Text(target.targetPercent.num(1) + "%").font(.title3.monospacedDigit()).foregroundStyle(.primary)
                    }.padding(.vertical, 8)
                }
                Divider()
            }
            Button("添加目标证券", systemImage: "plus") { code = ""; name = ""; percent = ""; error = ""; editing = true }.buttonStyle(.borderedProminent)
            Text("目标合计不能超过 100%。尚未持有的目标不会自动创建持仓；用于模拟下单前，仍需确认对应证券的交易规则。")
                .font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $editing) { editor }
    }
    private var editor: some View {
        NavigationStack {
            Form {
                Section("ETF / 股票") {
                    TextField("六位证券代码", text: $code).keyboardType(.numberPad)
                    TextField("证券名称", text: $name)
                    TextField("长期目标（%）", text: $percent).keyboardType(.decimalPad)
                }
                Section {
                    Text("保存表示确认该目标；以后仍可修改。不会买卖证券或调整现金。").font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    if targets.contains(where: { $0.code == code }) {
                        Button("移除这个目标", role: .destructive) {
                            store.removeAllocationTarget(for: Holding(code: code, name: name, quantity: 0, cost: 0, current: 0, kind: .etf)); editing = false
                        }
                    }
                }
            }.navigationTitle("目标仓位").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                ToolbarItem(placement: .confirmationAction) { Button("确认保存") { save() } }
            }
        }.presentationDetents([.medium, .large])
    }
    private func save() {
        let symbol = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard symbol.count == 6, symbol.allSatisfy(\.isNumber), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let value = Double(percent) else { error = "请核对代码、名称和目标比例"; return }
        do {
            try store.saveAllocationTarget(for: Holding(code: symbol, name: name, quantity: 0, cost: 0, current: 0, kind: .etf), percent: value)
            editing = false
        } catch { self.error = error.localizedDescription }
    }
}
