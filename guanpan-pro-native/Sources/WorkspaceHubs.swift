import SwiftUI
import Charts

struct ProOverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 } }
    private var value: Double { holdings.reduce(0) { $0 + $1.marketValue } }
    var body: some View {
        NavigationStack {
            ProPage(title: "看清当下，再做决定", subtitle: "观盘 Pro · 真实账户") {
                VStack(alignment: .leading, spacing: 22) {
                    Label("场内资产与现金", systemImage: "briefcase").font(.subheadline).foregroundStyle(.secondary)
                    Text((value + store.data.cash).cny()).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    HStack { ProMetric(title: "持仓市值", value: value.cny()); ProMetric(title: "现金", value: store.data.cash.cny()); ProMetric(title: "证券", value: "\(holdings.count) 只") }
                }.proSurface(tone: Color(red: 0.19, green: 0.45, blue: 0.78))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ProSectionTitle(title: "下一步，按你的节奏")
                    NavigationLink { ProAdvisorWorkspace() } label: { ProActionRow(title: "安排下一笔资金", detail: "结合持仓、长期目标与耐心买入偏好", icon: "arrow.up.right.circle") }
                    Divider()
                    NavigationLink { ProLabWorkspace() } label: { ProActionRow(title: "先看模拟，再做决定", detail: "相同起点与资金流，观察不同策略的结果", icon: "point.3.connected.trianglepath.dotted") }
                }
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        ProSectionTitle(title: "资金在哪里", detail: "最新本机价格")
                        ForEach(holdings.sorted { $0.marketValue > $1.marketValue }) { h in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(h.name).font(.subheadline.weight(.medium)); Text(h.code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(h.marketValue.cny()).font(.subheadline.monospacedDigit())
                                    Text((value + store.data.cash > 0 ? h.marketValue / (value + store.data.cash) * 100 : 0).num(1) + "%").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text(store.sourceStatus).font(.caption).foregroundStyle(.secondary)
            }.toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ProSettingsWorkspace() } label: { Image(systemName: "slider.horizontal.3") } } }
        }
    }
}

struct ProMarketWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var selected = ""
    @State private var search = ""
    @State private var add = false
    @State private var advanced: Holding?
    private var quotes: [Quote] { store.data.quotes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.code.contains(search) } }
    private var active: Quote? { quotes.first { $0.code == selected } ?? quotes.first }
    private var points: [IntradayBar] {
        let rows = store.intradayBars.filter { $0.code == active?.code }
        let day = rows.map(\.day).max()
        return rows.filter { $0.day == day }.sorted { $0.timestamp < $1.timestamp }
    }
    var body: some View {
        NavigationStack {
            ProPage(title: "市场工作台", subtitle: "价格、走势与数据时效") {
                if let q = active {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) { Text(q.name).font(.title2.weight(.semibold)); Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(q.price.num(3)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text((q.changePct * 100).num(2) + "%").font(.subheadline.monospacedDigit()).foregroundStyle(ProStyle.change(q.changePct))
                            }
                        }
                        if points.count > 1 {
                            Chart(points) { p in
                                LineMark(x: .value("时间", p.timestamp), y: .value("价格", p.price), series: .value("曲线", "价格")).foregroundStyle(Color.accentColor)
                                if let iopv = p.iopv { LineMark(x: .value("时间", p.timestamp), y: .value("IOPV", iopv), series: .value("曲线", "IOPV")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                            }.chartYScale(domain: .automatic(includesZero: false)).chartXAxis(.hidden).frame(height: 180)
                            Text("\(points.first?.day ?? "") · 虚线为原始 IOPV，缺失时不绘制").font(.caption).foregroundStyle(.secondary)
                        } else { ProEmpty(title: "等待分时数据", detail: "已有报价可以查看，历史走势不会用估算补齐。", icon: "chart.xyaxis.line") }
                        HStack {
                            Text(q.updatedAt.map { "报价 " + $0.formatted(date: .omitted, time: .shortened) } ?? "报价时间未知").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("K 线与历史") { advanced = Holding(code: q.code, name: q.name, quantity: 0, cost: 0, current: q.price, kind: .etf) }.font(.subheadline)
                        }
                    }.proSurface(tone: Color(red: 0.16, green: 0.51, blue: 0.69))
                }
                VStack(spacing: 0) {
                    ProSectionTitle(title: "自选证券", detail: "\(quotes.count) 只").padding(.bottom, 12)
                    if quotes.isEmpty { ProEmpty(title: "从关注的证券开始", detail: "添加场内 ETF 或股票，建立看盘清单。") }
                    ForEach(quotes) { q in
                        Button { selected = q.code } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(q.name).foregroundStyle(.primary); Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                Spacer()
                                Text(q.price.num(3)).monospacedDigit().foregroundStyle(.primary)
                                Text((q.changePct * 100).num(2) + "%").font(.subheadline.monospacedDigit()).foregroundStyle(ProStyle.change(q.changePct)).frame(width: 76, alignment: .trailing)
                            }.padding(.vertical, 15)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.searchable(text: $search, prompt: "证券名称或代码")
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") { store.refreshQuotes() }
                    Button("添加", systemImage: "plus") { add = true }
                } }
                .sheet(isPresented: $add) { WatchEditor() }
                .fullScreenCover(item: $advanced) { MarketChartView(holding: $0) }
        }
    }
}

struct ProDecisionHubView: View {
    var body: some View {
        NavigationStack { ProPage(title: "每个决定，都有依据", subtitle: "研究 · 计划 · 用户确认") {
            VStack(alignment: .leading, spacing: 18) {
                Text("先谈目标，再谈买卖").font(.title2.weight(.semibold))
                Text("想等更低的价格，还是先安排未来资金？从你的真实持仓开始，一起把计划说清楚。").font(.body).foregroundStyle(.secondary).lineSpacing(6)
                NavigationLink("和私人顾问聊聊") { ProAdvisorWorkspace() }.buttonStyle(.borderedProminent)
            }.proSurface(tone: Color(red: 0.08, green: 0.56, blue: 0.48))
            Divider()
            VStack(spacing: 0) {
                NavigationLink { AllocationTargetsView() } label: { ProActionRow(title: "长期目标", detail: "调整并确认目标仓位", icon: "target") }
                Divider()
                NavigationLink { TradePlansView() } label: { ProActionRow(title: "耐心交易计划", detail: "价格、分档、有效期与重新评估", icon: "clock.badge.checkmark") }
                Divider()
                NavigationLink { PortfolioAdviceView() } label: { ProActionRow(title: "组合风险", detail: "现金缓冲与集中度", icon: "shield.lefthalf.filled") }
                Divider()
                NavigationLink { LabResearchView() } label: { ProActionRow(title: "查看研究证据", detail: "因子、数据覆盖和策略依据", icon: "text.magnifyingglass") }
            }
            Text("真实证券交易始终由你决定。").font(.caption).foregroundStyle(.secondary)
        } }
    }
}

struct ProLabWorkspace: View {
    @EnvironmentObject private var lab: InvestmentLabStore
    @State private var selected = "G"
    @State private var comparison: [String: [String: Any]] = [:]
    @State private var comparisonError = ""
    private let titles = ["A": "持有与现金", "B": "初始比例", "C": "长期目标", "D": "再平衡", "E": "红利价值", "F": "趋势风控", "G": "AI 多因子"]
    private var orders: [[String: Any]] { lab.accounts[selected]?["orders"] as? [[String: Any]] ?? [] }
    var body: some View {
        NavigationStack { ProPage(title: "让策略先走一遍", subtitle: "独立虚拟账户 · 相同起点与资金流") {
            if lab.state == nil {
                ProEmpty(title: "先建立一个公平的起点", detail: "复制持仓、成本、现金与时间，创建七个独立策略账户。", icon: "point.3.connected.trianglepath.dotted")
                NavigationLink("创建数字孪生") { InvestmentLabView() }.buttonStyle(.borderedProminent)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ProSectionTitle(title: "策略对照", detail: "不把入金当成收益")
                    if !comparisonError.isEmpty { Text(comparisonError).font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(titles.keys).sorted(), id: \.self) { code in
                        HStack(alignment: .top) {
                            Text(code).font(.headline.monospaced()).frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) { Text(titles[code] ?? code).font(.subheadline); Text(metric(code)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) { Text("¥" + InvestmentLabStore.yuan(lab.accounts[code]?["cash"])).font(.subheadline.monospacedDigit()); Text("虚拟现金").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                }.proSurface(tone: Color(red: 0.49, green: 0.37, blue: 0.73))
                VStack(alignment: .leading, spacing: 16) {
                    ProSectionTitle(title: "订单追踪", detail: "为什么还在等待")
                    Picker("账户", selection: $selected) { ForEach(Array(titles.keys).sorted(), id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    if orders.isEmpty { Text("没有挂单。策略可以选择等待，不必强行成交。").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(Array(orders.enumerated()), id: \.offset) { _, order in
                        HStack {
                            Text(order["symbol"] as? String ?? "").monospaced()
                            Spacer()
                            Text("¥" + InvestmentLabStore.yuan(order["limit"])).monospacedDigit()
                            Text(status(order["status"] as? String ?? "")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                }
                NavigationLink { InvestmentLabView() } label: { ProActionRow(title: "调整实验", detail: "入金安排、挂单、卖出权限与交易规则", icon: "slider.horizontal.3") }
                NavigationLink { TradingRuleSettingsView() } label: { ProActionRow(title: "核对 T+0 / T+1", detail: "按证券更正规则，保留历史成交", icon: "arrow.left.arrow.right") }
            }
            Text("这里只进行模拟，不向券商提交交易。").font(.caption).foregroundStyle(.secondary)
        }.onReceive(lab.$state) { state in
            guard let state else { comparison = [:]; return }
            do {
                comparison = try lab.call("compare", [state]) as? [String: [String: Any]] ?? [:]
                comparisonError = ""
            } catch { comparison = [:]; comparisonError = "观察日期或资金流不一致，暂不比较收益。" }
        } }
    }
    private func metric(_ code: String) -> String {
        guard let m = comparison[code], m["status"] as? String == "ok" else { return "观察时点不足，收益暂不可比" }
        func pct(_ key: String) -> String { guard let n = m[key] as? NSNumber else { return "—" }; return (n.doubleValue * 100).num(2) + "%" }
        return "TWR " + pct("timeWeightedReturn") + " · 年化资金加权 " + pct("moneyWeightedAnnualReturn") + " · 回撤 " + pct("maxDrawdown")
    }
    private func status(_ raw: String) -> String { ["waiting": "等待成交", "partial": "部分成交", "filled": "已成交", "expired": "已到期", "cancelled": "已撤销"][raw] ?? "待核对" }
}

struct ProAssetsHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var add = false
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == .etf } }
    var body: some View {
        NavigationStack { ProPage(title: "我的资产", subtitle: "真实持仓与资金") {
            HStack { ProMetric(title: "持仓市值", value: holdings.reduce(0) { $0 + $1.marketValue }.cny()); ProMetric(title: "现金", value: store.data.cash.cny()) }
            Divider()
            VStack(spacing: 0) {
                ProSectionTitle(title: "持仓明细", detail: "\(holdings.count) 只").padding(.bottom, 12)
                if holdings.isEmpty { ProEmpty(title: "建立真实资产视图", detail: "手动记录持仓，或预览 NAS 资产后确认接收。") }
                ForEach(holdings) { h in
                    NavigationLink { ProHoldingWorkspace(holding: h) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) { Text(h.name).foregroundStyle(.primary); Text(h.code + " · " + h.quantity.num(0) + " 股").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) { Text(h.marketValue.cny()).monospacedDigit().foregroundStyle(.primary); Text(h.pnl.cny()).font(.caption.monospacedDigit()).foregroundStyle(ProStyle.change(h.pnl)) }
                        }.padding(.vertical, 17)
                    }
                    Divider()
                }
            }
            NavigationLink { AssetsView() } label: { ProActionRow(title: "资金与资产轨迹", detail: "现金流水、快照与历史回看", icon: "chart.line.uptrend.xyaxis") }
            NavigationLink { TradeLedgerManagementView() } label: { ProActionRow(title: "实际交易流水", detail: "核对成交与费用", icon: "list.bullet.rectangle") }
            NavigationLink { ManualAssetChannelView() } label: { ProActionRow(title: "手动同步真实资产", detail: "预览、核对、确认后接收", icon: "arrow.triangle.2.circlepath") }
        }.toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { add = true }; NavigationLink { ProSettingsWorkspace() } label: { Image(systemName: "gearshape") } } }
        .sheet(isPresented: $add) { HoldingEditor(kind: .etf) } }
    }
}

struct ProHoldingWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    let holding: Holding
    @State private var chart = false
    @State private var trade = false
    @State private var edit = false
    private var current: Holding { store.data.holdings.first { $0.id == holding.id } ?? holding }
    var body: some View {
        ProPage(title: current.name, subtitle: current.code + " · 真实持仓") {
            Text(current.marketValue.cny()).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack { ProMetric(title: "数量", value: current.quantity.num(0)); ProMetric(title: "单位成本", value: current.cost.num(3)); ProMetric(title: "当前价格", value: current.current.num(3)) }
            Divider()
            HStack { Button("查看图表") { chart = true }.buttonStyle(.borderedProminent); Button("记录实际成交") { trade = true }.buttonStyle(.bordered) }
            ProMetric(title: "持仓账面盈亏", value: current.pnl.cny(), color: ProStyle.change(current.pnl))
            NavigationLink { DayGridView() } label: { ProActionRow(title: "网格研究与复盘", detail: "行情与交易参数分析", icon: "square.grid.3x3") }
            Button("核对持仓资料") { edit = true }
            Text("记录成交只维护账本，不会发送证券订单。").font(.caption).foregroundStyle(.secondary)
        }.fullScreenCover(isPresented: $chart) { MarketChartView(holding: current) }.sheet(isPresented: $trade) { TradeEditor(holding: current) }.sheet(isPresented: $edit) { HoldingEditor(kind: .etf, initial: current) }
    }
}

struct ProSettingsWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @AppStorage("guanpan.native.fontScale") private var scale = 1.0
    var body: some View {
        ProPage(title: "按你的方式观盘", subtitle: "外观、数据与研究偏好") {
            VStack(alignment: .leading, spacing: 16) {
                ProSectionTitle(title: "外观")
                Picker("显示模式", selection: Binding(get: { store.data.appearance }, set: { store.data.appearance = $0; store.save(propagate: false) })) {
                    Text("跟随系统").tag(AppAppearance.system); Text("浅色").tag(AppAppearance.light); Text("深色").tag(AppAppearance.dark)
                }.pickerStyle(.segmented)
                Stepper("文字大小 \(Int(scale * 100))%", value: $scale, in: 0.85...1.4, step: 0.05)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                ProSectionTitle(title: "三个独立通道")
                Text("真实资产 · " + channels.assets.text).font(.subheadline)
                Text("行情数据 · " + channels.market.text).font(.subheadline)
                Text("AI 量化 · " + channels.quant.text).font(.subheadline)
                Button("检查行情与量化") { Task { await channels.refresh(lab: lab) } }.buttonStyle(.bordered)
            }
            NavigationLink { ManualAssetChannelView() } label: { ProActionRow(title: "真实资产手动同步", detail: "接收前预览，冲突时保留两端", icon: "externaldrive") }
            NavigationLink { SimulationFeeSettingsView() } label: { ProActionRow(title: "模拟交易费用", detail: "ETF 每笔 0.10 元；额外滑点默认 0", icon: "equal.circle") }
            NavigationLink { SettingsView() } label: { ProActionRow(title: "连接、备份与图表偏好", detail: "NAS、数据导出、主题与兼容配置", icon: "slider.horizontal.3") }
        }
    }
}
