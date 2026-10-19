import SwiftUI

struct PaperTradingView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guanpan.paper.account.v1") private var saved = Data()
    @State private var account = PaperAccount()
    @State private var code = ""
    @State private var limit = ""
    @State private var quantity = "100"
    @State private var message = ""
    @State private var storageFailed = false
    @State private var expiry = Date.now.addingTimeInterval(86400)
    private var supportedQuotes: [Quote] {
        store.data.quotes.filter { $0.code.hasPrefix("15") || $0.code.hasPrefix("16") || $0.code.hasPrefix("51") || $0.code.hasPrefix("56") || $0.code.hasPrefix("58") }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WorkspacePageIntro(title: "耐心限价模拟", subtitle: "独立虚拟账户 · 不写入真实账本", icon: "lock.shield", tone: CardTone.accent)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("虚拟现金").font(.subheadline).foregroundStyle(.secondary)
                        Text(account.cash.cny()).scaledFont(32, weight: .bold).monospacedDigit()
                        MetricGrid(columns: 2, cells: [MetricCell(title: "可用资金", value: account.availableCash.cny()), MetricCell(title: "挂单预留", value: account.reservedCash.cny())])
                    }.cardSurface(tone: CardTone.accent)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("新建模拟买单").font(.headline)
                        TextField("ETF 代码", text: $code).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        TextField("限价（元）", text: $limit).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        TextField("份额（100 的整数倍）", text: $quantity).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        DatePicker("有效期至", selection: $expiry, in: Date.now...)
                        Button("提交虚拟限价单") { place() }.buttonStyle(.borderedProminent).disabled(storageFailed)
                        Text("ETF 每笔固定 ¥0.10，额外滑点 0。只在你主动核对时，按建单后两分钟内有效报价判断触价；按限价计价，不假设更优成交。交易日以现有市场日历校验。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.cardSurface(tone: WorkspaceTone.blue)
                    Button("用现有报价核对挂单", systemImage: "arrow.clockwise") { match() }
                        .buttonStyle(.bordered).disabled(storageFailed)
                    Text(message).font(.footnote).foregroundStyle(CardTone.warn)
                    ForEach(account.orders.reversed()) { order in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(order.code).font(.headline); Spacer(); Text(status(order.status)).foregroundStyle(CardTone.accent) }
                            Text("\(order.quantity) 份 · 限价 \(order.limit.num(4))")
                            Text("有效期：\(order.expiresAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            if order.status == .waiting {
                                Button("撤销虚拟挂单") { account.cancel(id: order.id); persist() }
                            }
                        }.cardSurface(tone: WorkspaceTone.teal)
                    }
                    if !account.positions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("虚拟持仓（含买入费用）").font(.headline)
                            ForEach(account.positions, id: \.code) { p in
                                LabeledContent(p.code, value: "\(p.quantity) 份 · 成本 \((p.bookCost / Double(p.quantity)).num(4))")
                            }
                        }.cardSurface(tone: WorkspaceTone.teal)
                    }
                }.padding(16)
            }.navigationTitle("模拟账户").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear {
                    guard !saved.isEmpty else { return }
                    do {
                        let decoded = try JSONDecoder().decode(PaperAccount.self, from: saved)
                        guard decoded.isValid else { storageFailed = true; message = "虚拟记录校验失败，原始数据已保留。"; return }
                        account = decoded
                        account.expire(at: .now)
                    }
                    catch { storageFailed = true; message = "虚拟账户读取失败，已停止写入并保留原始记录。" }
                }
        }
    }
    private func place() {
        guard !storageFailed, let price = Double(limit), let shares = Int(quantity) else { message = "请填写有效限价与份额。"; return }
        guard account.place(code: code.trimmingCharacters(in: .whitespacesAndNewlines), limit: price, quantity: shares, now: .now, expires: expiry) else {
            message = "请检查 ETF 代码、100 份整数单位、有效期与虚拟可用资金。"; return
        }
        persist(); message = "已创建虚拟挂单，等待新的有效报价。"
    }
    private func match() {
        let now = Date.now
        account.expire(at: now)
        persist()
        // Existing holiday calendar gates simulated fills as well as weekday/session checks.
        guard !store.isMarketClosedToday, !MarketCalendar.isClosure(now, custom: store.data.customMarketHolidays) else { message = "休市期间不进行模拟撮合。"; return }
        for quote in supportedQuotes {
            guard let timestamp = quote.updatedAt else { continue }
            account.observe(code: quote.code, price: quote.price, timestamp: timestamp, now: now)
        }
        persist(); message = "核对完成；未触价、缺失或过期报价不会成交。报价触价不保证真实盘口可成交。"
    }
    private func persist() {
        guard !storageFailed else { return }
        do { saved = try JSONEncoder().encode(account) }
        catch { storageFailed = true; message = "虚拟账户保存失败，已停止写入。" }
    }
    private func status(_ value: PaperOrder.Status) -> String {
        switch value { case .waiting: return "等待触价"; case .filled: return "模拟成交"; case .cancelled: return "已撤销"; case .expired: return "已到期" }
    }
}
