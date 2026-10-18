import SwiftUI

/// First integration surface, opened from the existing quant screen.
/// Read-only snapshot access to PortfolioStore; all mutations target the lab vault.
struct InvestmentLabView: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @State private var kinds: [String: String] = [:]
    @State private var tPlusOne: [String: Bool] = [:]
    @State private var amount = ""
    @State private var flowDate = Date()
    @State private var specifyFlowDate = false
    @State private var newSymbol = ""
    @State private var newAsset = "etf"
    @State private var newRule = "unknown"
    @State private var isWithdrawal = false
    @State private var month = String(MarketCalendar.isoDay(.now).prefix(7))
    @State private var monthlyAmount = ""
    @State private var paused = false
    @State private var schedulePlan = false
    @State private var scheduledDate = Date()
    @State private var account = "G"
    @State private var symbol = ""
    @State private var side = "buy"
    @State private var limit = ""
    @State private var shares = "100"
    @State private var validMinutes = "60"
    @State private var error = ""
    private let names = ["A": "持有与现金", "B": "初始比例新增", "C": "长期目标新增", "D": "定期再平衡",
                         "E": "红利价值规则", "F": "趋势风控规则", "G": "本机多因子自主模拟"]
    private var holdings: [Holding] { portfolio.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 } }
    private var isLight: Bool { AppTheme.palette(for: portfolio.resolvedAppearance).isLight }
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var body: some View {
        List {
            Section("开发验证版 · 独立实验账本") {
                Text("模拟交易与真实持仓隔离。A–G 使用可解释规则和同一资金流；盘口缺失就等待。当前 iOS 版本仍需编译与真机验收。")
                Text(lab.message).font(.footnote)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(CardTone.warn) }
            }.plainCard(isLight: isLight)
            if lab.state == nil { creationSection }
            else {
                Section("自动模拟与研究") {
                    Toggle("允许 NAS 规则策略自动生成虚拟限价单", isOn: Binding(
                        get: { (lab.state?["autonomous"] as? [String: Any])?["enabled"] as? Bool ?? false },
                        set: { lab.action(["type": "autonomy", "enabled": $0, "intervalMs": 86_400_000]) }))
                    Text("只影响虚拟账户；默认关闭。开启后每日复核规则，数据不全不强制交易，卖出仍受原始持仓权限约束。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("研究、风险与未来资金安排") { LabResearchView() }
                    NavigationLink("真实资产通道 · 仅手动") { ManualAssetChannelView() }
                    NavigationLink("模拟费用与滑点版本") { SimulationFeeSettingsView() }
                    Button("确认使用当前长期目标，剩余资金保留现金") { confirmTargets() }
                }.plainCard(isLight: isLight)
                Section("登记目标配置中的新证券") {
                    TextField("ETF / 股票代码", text: $newSymbol)
                    Picker("证券类型", selection: $newAsset) { Text("ETF").tag("etf"); Text("股票").tag("stock") }
                    Picker("回转交易规则", selection: $newRule) {
                        Text("请选择").tag("unknown"); Text("T+0 · 当日可卖").tag("t0"); Text("T+1 · 后续交易日可卖").tag("t1")
                    }
                    Button("确认交易规则并登记，不创建持仓") {
                        lab.action(["type": "instrument", "at": now, "definition": ["symbol": newSymbol,
                            "asset": newAsset, "quantity": 0, "cost": 0, "price": 1,
                            "tick": newAsset == "etf" ? 10 : 100, "lot": 100, "tPlusOne": newRule == "t1"]])
                    }.disabled(newRule == "unknown")
                    Text("规则登记不会生成行情价格或改变初始快照。参考价仍须来自后续有效行情。特殊证券交易单位请先核实，当前界面按 100 股整手登记。")
                        .font(.caption).foregroundStyle(.secondary)
                }.plainCard(isLight: isLight)
                Section("策略对照账户") {
                    ForEach(Array(names.keys).sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(key) · \(names[key] ?? key)").font(.headline)
                            Text("虚拟现金 ¥\(InvestmentLabStore.yuan(lab.accounts[key]?["cash"]))")
                            Text(performance(key)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.plainCard(isLight: isLight)
                Section("外部资金流 · 七策略使用相同日期和金额") {
                    TextField("金额（元）", text: $amount).keyboardType(.decimalPad)
                    Toggle("指定已发生的资金时间", isOn: $specifyFlowDate)
                    if specifyFlowDate { DatePicker("资金发生时间", selection: $flowDate, in: ...Date()) }
                    Toggle("资金流出", isOn: $isWithdrawal)
                    Button("记录临时资金流") { recordFlow() }
                    Text("流出不能动用挂单冻结资金；任一策略现金不足时，整组操作拒绝。入金不计为投资收益。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.plainCard(isLight: isLight)
                Section("月度可变入金计划") {
                    TextField("月份 YYYY-MM", text: $month)
                    TextField("本月金额（元）", text: $monthlyAmount).keyboardType(.decimalPad)
                    Toggle("暂停本月入金", isOn: $paused)
                    Toggle("指定虚拟入金时间", isOn: $schedulePlan)
                    if schedulePlan { DatePicker("计划时间", selection: $scheduledDate) }
                    Button("保存本月安排") { savePlan() }
                    Toggle("允许 NAS 按计划记入虚拟资金", isOn: Binding(get: { (lab.state?["fundingSchedule"] as? [String: Any])?["enabled"] as? Bool ?? false }, set: { lab.action(["type": "fundingSchedule", "enabled": $0]) }))
                    Button("执行当前月份入金") { lab.action(["type": "executePlan", "month": month, "at": now]) }
                    Text("自动记账仅影响七个虚拟账户，不代表真实资金到账；错过整月的安排会提示核对，不倒填资金时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.plainCard(isLight: isLight)
                orderSection
                Section("导出与收益计算边界") {
                    ShareLink("导出独立实验 JSON", item: lab.exportText)
                    Text("精确时间加权收益需要资金流发生时的估值；缺少估值则显示数据不足。当前界面尚未接入完整收益对照图。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.plainCard(isLight: isLight)
            }
            Section("三通道独立状态 · v2 协议") {
                statusRow("真实资产", channels.assets)
                statusRow("行情数据", channels.market)
                statusRow("AI 量化", channels.quant)
                Button("检查独立通道") { Task { await channels.refresh(lab: lab) } }
                Text("此页不会上传或下载真实账本；原设置的手动备份入口保留。行情通道自动读取，量化通道自动同步独立实验账本；版本冲突暂停。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.plainCard(isLight: isLight)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .navigationTitle("投资数字孪生 · 实验")
        .navigationBarTitleDisplayMode(.inline)
        .task { await channels.refresh(lab: lab) }
    }

    private var creationSection: some View {
        Section("从当前真实持仓创建一次性副本") {
            Text("请逐个确认证券类型和交收规则。旧版的“场内”类型也可能包含其他证券；未支持品种请先从本实验排除，不能当作 ETF。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(holdings) { h in
                VStack(alignment: .leading) {
                    Text("\(h.name) · \(h.code) · \(h.quantity.num(0)) 股")
                    Picker("实验类型", selection: Binding(get: { kinds[h.code] ?? "unknown" }, set: { kinds[h.code] = $0 })) {
                        Text("待确认").tag("unknown"); Text("ETF").tag("etf"); Text("股票").tag("stock"); Text("排除本实验").tag("exclude")
                    }
                    Picker("回转交易规则", selection: Binding(get: { tPlusOne[h.code].map { $0 ? "t1" : "t0" } ?? "unknown" }, set: { value in
                        if value == "unknown" { tPlusOne.removeValue(forKey: h.code) } else { tPlusOne[h.code] = value == "t1" }
                    })) {
                        Text("待确认").tag("unknown"); Text("T+0 · 当日可卖").tag("t0"); Text("T+1 · 后续交易日可卖").tag("t1")
                    }
                }
            }
            Text("快照将复制数量、单位成本、现金和创建时间；估值使用当前本机价格，可能为缓存。场外历史数据保留于原账本，不进入实验。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("确认并创建 A–G 独立账户") { create() }.disabled(lab.loadFailed)
        }.plainCard(isLight: isLight)
    }
    private var orderSection: some View {
        Section("虚拟限价单 · 不提交真实交易") {
            Picker("策略账户", selection: $account) { ForEach(Array(names.keys).sorted(), id: \.self) { Text($0).tag($0) } }
            Picker("可卖出的虚拟仓位", selection: Binding(
                get: { lab.accounts[account]?["salePolicy"] as? String ?? "lockOriginal" },
                set: { lab.action(["type": "salePolicy", "account": account, "value": $0]) })) {
                Text("禁止卖出初始持仓").tag("lockOriginal")
                Text("只卖系统策略买入批次").tag("aiOnly")
                if !["A", "B", "C"].contains(account) { Text("允许全部虚拟仓位").tag("all") }
            }
            TextField("代码（须在快照中确认规则）", text: $symbol)
            Picker("方向", selection: $side) { Text("买入").tag("buy"); Text("卖出").tag("sell") }.pickerStyle(.segmented)
            TextField("限价（元）", text: $limit).keyboardType(.decimalPad)
            TextField("股数", text: $shares).keyboardType(.numberPad)
            TextField("等待有效期（分钟，最多 30 天）", text: $validMinutes).keyboardType(.numberPad)
            Button("创建独立虚拟挂单") { submit() }
            Button("更新到期状态") { lab.action(["type": "expire", "account": account, "at": now]) }
            ForEach(orders, id: \.id) { row in
                VStack(alignment: .leading) {
                    Text(row.text).font(.caption)
                    if row.open { Button("撤销虚拟挂单") { lab.action(["type": "cancel", "account": account, "id": row.id, "at": now]) } }
                }
            }
            Text("NAS 执行器只使用已接入的有效盘口；盘口缺失时挂单等待或到期。费用使用创建订单时的版本，默认 ETF 每个成交事件 0.10 元、额外滑点 0。")
                .font(.footnote).foregroundStyle(.secondary)
        }.plainCard(isLight: isLight)
    }
    private struct OrderRow { let id: String; let text: String; let open: Bool }
    private func performance(_ code: String) -> String {
        guard let state = lab.state, let result = try? lab.call("metrics", [state, code]) as? [String: Any] else { return "暂无绩效记录" }
        guard result["status"] as? String == "ok" else { return "估值/资金流时点不足，不显示虚假收益率" }
        let twr = (result["timeWeightedReturn"] as? NSNumber)?.doubleValue ?? 0
        let dd = (result["maxDrawdown"] as? NSNumber)?.doubleValue ?? 0
        let mwr = (result["moneyWeightedAnnualReturn"] as? NSNumber).map { String(format: "%.2f%%", $0.doubleValue * 100) } ?? "无唯一解/不足一年化条件"
        return "TWR \(String(format: "%.2f%%", twr * 100)) · MWR \(mwr) · 回撤 \(String(format: "%.2f%%", dd * 100)) · 净收益 ¥\(InvestmentLabStore.yuan(result["profit"]))"
    }
    private var orders: [OrderRow] {
        let rows = lab.accounts[account]?["orders"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let status = row["status"] as? String ?? ""
            return OrderRow(id: id, text: "\(row["symbol"] as? String ?? "") · \(status) · 剩余 \(row["remaining"] as? Int ?? 0) 股",
                            open: ["waiting", "partial"].contains(status))
        }
    }
    private func statusRow(_ title: String, _ status: LabChannelCoordinator.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline); Text(status.text).font(.caption)
            ProgressView(value: status.progress)
        }
    }
    private func create() {
        do {
            var positions: [[String: Any]] = []
            for h in holdings {
                let kind = kinds[h.code] ?? "unknown"
                guard kind != "unknown" else { throw InvestmentLabStore.LabError.message("请确认每只证券类型或排除") }
                if kind == "exclude" { continue }
                guard let sellNextDay = tPlusOne[h.code] else { throw InvestmentLabStore.LabError.message("请确认 \(h.code) 的 T+0/T+1 规则；美股跨境 ETF 不能统一设为 T+1") }
                guard h.quantity.isFinite, h.quantity.rounded() == h.quantity, h.quantity <= 100_000_000 else {
                    throw InvestmentLabStore.LabError.message("初始数量须为有效整数股")
                }
                positions.append(["symbol": h.code, "asset": kind, "quantity": Int64(h.quantity),
                    "cost": try InvestmentLabStore.units(h.cost, allowNegative: true), "price": try InvestmentLabStore.units(h.current),
                    "tick": kind == "etf" ? 10 : 100, "lot": 100, "tPlusOne": sellNextDay])
            }
            let closures = Array(MarketCalendar.mainlandClosures2026.union(portfolio.data.customMarketHolidays))
            lab.create(snapshot: ["at": now, "cash": try InvestmentLabStore.units(portfolio.data.cash), "positions": positions,
                                  "marketCalendar": ["closedDays": closures, "source": "iOS 现有日历及用户确认休市日"]])
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func recordFlow() {
        do {
            guard let number = Double(amount), number > 0 else { throw InvestmentLabStore.LabError.message("请输入正金额") }
            let units = try InvestmentLabStore.units(number)
            lab.action(["type": "flow", "id": UUID().uuidString, "at": specifyFlowDate ? Int64(flowDate.timeIntervalSince1970 * 1000) : now, "amount": isWithdrawal ? -units : units])
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func confirmTargets() {
        var weights: [String: Int] = [:]
        for target in portfolio.data.allocationTargets where target.kind == .etf {
            guard target.targetPercent.isFinite, (0...100).contains(target.targetPercent) else { error = "目标仓位无效"; return }
            weights[target.code] = Int((target.targetPercent * 100).rounded())
        }
        let allocated = weights.values.reduce(0, +)
        guard !weights.isEmpty, allocated <= 10000 else { error = "请先设置目标仓位，合计不得超过 100%"; return }
        weights["cash"] = 10000 - allocated
        lab.action(["type": "targets", "confirmed": true, "at": now, "weights": weights])
    }
    private func savePlan() {
        do {
            guard let value = Double(monthlyAmount) else { throw InvestmentLabStore.LabError.message("请输入月度金额") }
            var action: [String: Any] = ["type": "plan", "month": month, "amount": try InvestmentLabStore.units(value), "paused": paused]
            if schedulePlan { action["executeAt"] = Int64(scheduledDate.timeIntervalSince1970 * 1000) }
            lab.action(action)
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func submit() {
        do {
            guard let price = Double(limit), let quantity = Int(shares), let minutes = Int64(validMinutes), (1...43200).contains(minutes) else {
                throw InvestmentLabStore.LabError.message("请检查价格、股数和有效期")
            }
            let at = now
            lab.action(["type": "order", "account": account, "id": UUID().uuidString, "symbol": symbol,
                "side": side, "quantity": quantity, "limit": try InvestmentLabStore.units(price), "at": at,
                "expiresAt": at + minutes * 60000, "session": MarketCalendar.isoDay(.now),
                "evidence": ["用户创建的虚拟限价计划"], "reassess": "有效期结束撤销；重新检查行情和资金后创建新单"])
            error = ""
        } catch { self.error = error.localizedDescription }
    }
}
