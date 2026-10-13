import SwiftUI

/// Local, read-only transaction preview. It never writes holdings, cash, or ledger entries.
struct TradePreviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var instrumentID = ""
    @State private var side: LedgerEntry.Side = .buy
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var feeText = "0"

    private var instruments: [Holding] { store.data.holdings.sorted { $0.name < $1.name } }
    private var selected: Holding? { instruments.first { $0.id == instrumentID } ?? instruments.first }
    private var quantity: Double { Double(quantityText) ?? 0 }
    private var price: Double { Double(priceText) ?? 0 }
    private var feeInput: Double { Double(feeText) ?? 0 }
    private var isFund: Bool { selected?.kind == .fund }
    private var gross: Double {
        guard selected != nil, quantity > 0, price > 0 else { return 0 }
        return isFund && side == .buy ? quantity : quantity * price
    }
    private var fee: Double { isFund && side == .buy ? gross * feeInput / 100 : feeInput }
    private var sharesDelta: Double {
        guard price > 0 else { return 0 }
        if isFund && side == .buy { return max(0, gross - fee) / price }
        return side == .buy ? quantity : -quantity
    }
    private var postValue: Double { max(0, (selected?.marketValue ?? 0) + sharesDelta * price) }
    private var cashLinked: Bool { !isFund && store.data.cashLinkedByDefault }
    private var cashDelta: Double {
        guard cashLinked else { return 0 }
        return side == .buy ? -(gross + fee) : gross - fee
    }
    private var postCash: Double { store.data.cash + cashDelta }
    private var postTotal: Double { max(0, store.totalAsset + (postValue - (selected?.marketValue ?? 0)) + cashDelta) }
    private var weight: Double { postTotal > 0 ? postValue / postTotal : 0 }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var validation: String? {
        guard let holding = selected else { return "请先添加至少一项持仓。" }
        guard quantity.isFinite, quantity > 0, price.isFinite, price > 0, feeInput.isFinite, feeInput >= 0 else { return "请输入有效数量、价格和非负费用。" }
        if side == .sell && quantity > holding.quantity { return "卖出数量超过当前持有份额。" }
        if cashLinked && side == .buy && gross + fee > store.data.cash { return "现金联动已开启，参考现金不足以覆盖本次买入与费用。" }
        if cashLinked && side == .sell && gross < fee { return "卖出费用高于成交金额。" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预演参数") {
                    if instruments.isEmpty { ContentUnavailableView("暂无持仓", systemImage: "tray", description: Text("先添加 ETF 或基金持仓，再进行交易前试算。")) }
                    else {
                        Picker("标的", selection: $instrumentID) {
                            ForEach(instruments) { item in
                                Text("\(item.kind == .fund ? "基金" : "场内") · \(item.name)（\(item.code)）").tag(item.id)
                            }
                        }
                        Picker("方向", selection: $side) {
                            Text(isFund ? "申购" : "买入").tag(LedgerEntry.Side.buy)
                            Text(isFund ? "赎回" : "卖出").tag(LedgerEntry.Side.sell)
                        }.pickerStyle(.segmented)
                        TextField(isFund && side == .buy ? "申购金额（元）" : "数量（份）", text: $quantityText).keyboardType(.decimalPad)
                        TextField(isFund ? "参考净值" : "成交价", text: $priceText).keyboardType(.decimalPad)
                        TextField(isFund && side == .buy ? "申购费率（%）" : "手续费（元）", text: $feeText).keyboardType(.decimalPad)
                    }
                    Text("交易前沙盘只预演，不写账、不改现金或持仓。基金申购默认使用外部资金，不联动参考现金。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                if let holding = selected {
                    Section("试算结果 · \(holding.name)") {
                        LabeledContent("成交金额", value: (gross).cny())
                        LabeledContent("预计费用", value: (fee).cny())
                        if isFund && side == .buy {
                            LabeledContent("预计获得份额", value: (sharesDelta).num(2))
                        }
                        LabeledContent("持仓市值", value: (holding.marketValue).cny())
                        LabeledContent("交易后市值", value: (postValue).cny())
                        LabeledContent("参考现金", value: (store.data.cash).cny())
                        LabeledContent("交易后参考现金", value: (postCash).cny())
                        LabeledContent("交易后资产占比", value: (weight * 100).pct(1))
                    }
                    .toneCard(CardTone.accent, isLight: isLight)
                }
                if let validation {
                    Section { Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(CardTone.warn) }
                        .toneCard(CardTone.warn, isLight: isLight)
                }
                Section {
                    Text("确认结果后请回到持仓页，在对应持仓卡片打开“买入 / 卖出”并再次核对。沙盘不会自动打开或提交正式流水。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("交易前沙盘")
            .keyboardDoneToolbar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if instrumentID.isEmpty, let holding = instruments.first {
                    instrumentID = holding.id
                    priceText = String(holding.current)
                    feeText = holding.kind == .fund && side == .buy ? "0.15" : (holding.kind == .etf ? "0.10" : "0")
                }
            }
            .onChange(of: instrumentID) { _, value in
                if let holding = instruments.first(where: { $0.id == value }) {
                    priceText = String(holding.current)
                    feeText = holding.kind == .fund && side == .buy ? "0.15" : (holding.kind == .etf ? "0.10" : "0")
                }
            }
            .onChange(of: side) { _, value in
                if isFund { feeText = value == .buy ? "0.15" : "0" }
                else { feeText = "0.10" }
            }
        }
    }
}
