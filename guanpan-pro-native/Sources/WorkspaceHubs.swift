import SwiftUI
import Charts

struct ProOverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 } }
    private var value: Double { holdings.reduce(0) { $0 + $1.marketValue } }
    private var sortedHoldings: [Holding] { holdings.sorted { $0.marketValue > $1.marketValue } }
    var body: some View {
        NavigationStack {
            ProPage(title: "账户总览", subtitle: "真实资产 · 行情脉搏 · 研究入口") {
                VStack(alignment: .leading, spacing: 22) {
                    Label("账户总资产", systemImage: "briefcase.fill").scaledFont(15, weight: .medium).foregroundStyle(.secondary)
                    Text((value + store.data.cash).cny()).scaledFont(38, weight: .semibold, design: .rounded).monospacedDigit().minimumScaleFactor(0.62).lineLimit(1)
                    HStack(spacing: 14) { ProMetric(title: "持仓市值", value: value.cny()); ProMetric(title: "可用现金", value: store.data.cash.cny()) }
                    Text("当前记录 \(holdings.count) 只场内证券").scaledFont(12).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        Circle().fill(store.sourceStatus.contains("失败") ? .orange : .teal).frame(width: 7, height: 7)
                        Text(store.sourceStatus).scaledFont(12).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.proSurface(tone: Color(red: 0.19, green: 0.45, blue: 0.78))
                VStack(alignment: .leading, spacing: 10) {
                    ProSectionTitle(title: "继续处理", detail: "研究与计划")
                    NavigationLink { LabResearchView() } label: { ProActionRow(title: "安排下一笔资金", detail: "基于真实账户研究未来资金，不增加虚拟现金", icon: "arrow.up.right.circle.fill", tone: Color(red: 0.08, green: 0.56, blue: 0.48)) }.proSurface(tone: Color(red: 0.08, green: 0.56, blue: 0.48))
                    NavigationLink { LabResearchView() } label: { ProActionRow(title: "AI 今日指导", detail: "扫描真实持仓，判断今天是否值得操作", icon: "sparkles", tone: Color(red: 0.20, green: 0.42, blue: 0.84)) }.proSurface(tone: Color(red: 0.20, green: 0.42, blue: 0.84))
                }
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ProSectionTitle(title: "资金在哪里", detail: "最新本机价格")
                        ForEach(sortedHoldings) { h in
                            NavigationLink { ProHoldingWorkspace(holding: h) } label: {
                                HoldingSummaryRow(holding: h, share: value + store.data.cash > 0 ? h.marketValue / (value + store.data.cash) : 0)
                            }
                            if h.id != sortedHoldings.last?.id { Divider() }
                        }
                    }.proSurface(tone: .blue)
                }
            }
        }
    }
}

struct ProMarketWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.visualTheme) private var theme
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
    private var tokens: DesignTokens { ThemeManager.tokens(theme) }
    private var marketTone: Color { theme == .eastern ? tokens.accent : theme == .magazine ? tokens.secondary : tokens.accent }

    var body: some View {
        NavigationStack {
            ProPage(title: marketTitle, subtitle: marketSubtitle) {
                switch theme {
                case .eastern, .scene:
                    indexPanel
                    chartPanel
                    watchlistPanel
                case .modern:
                    chartPanel
                    indexPanel
                    watchlistPanel
                case .dashboard:
                    chartPanel
                    watchlistPanel
                    indexPanel
                case .magazine:
                    watchlistPanel
                    chartPanel
                    indexPanel
                case .bento:
                    indexPanel
                    bentoMarketSummary
                    chartPanel
                    watchlistPanel
                }
            }.searchable(text: $search, prompt: "证券名称或代码")
                .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") { store.refreshEverything() }
                    Button("添加", systemImage: "plus") { add = true }
                } }
                .sheet(isPresented: $add) { WatchEditor() }
                .fullScreenCover(item: $advanced) { MarketChartView(holding: $0) }
        }
    }

    private var marketTitle: String {
        switch theme {
        case .eastern, .scene: return "山海行情"
        case .modern: return "行情"
        case .dashboard: return "交易台"
        case .magazine: return "市场观察手册"
        case .bento: return "市场拼图"
        }
    }
    private var marketSubtitle: String {
        let stamp = Date.now.formatted(date: .abbreviated, time: .omitted)
        switch theme {
        case .magazine: return "\(stamp) · 行情、走势与数据时效"
        case .dashboard: return "盘中行情 · \(stamp)"
        default: return "真实行情 · \(stamp) · 数据时间可核对"
        }
    }

    private var indexPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProSectionTitle(title: theme == .magazine ? "今日市场刻度" : "主要指数", detail: "点按查看分时与日 K")
            if store.indexQuotes.isEmpty {
                HStack {
                    Text("指数行情尚未加载").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("获取行情") { store.refreshIndexQuotes() }
                }
            } else if theme == .bento {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    ForEach(store.indexQuotes) { item in indexCard(item, width: nil, height: 84) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme == .dashboard ? 7 : 10) {
                        ForEach(store.indexQuotes) { item in
                            indexCard(item, width: theme == .dashboard ? 112 : 128,
                                      height: theme == .dashboard ? 82 : 88)
                        }
                    }
                }
            }
        }.proSurface(tone: marketTone)
    }

    private func indexCard(_ item: MarketIndexQuote, width: CGFloat?, height: CGFloat) -> some View {
        NavigationLink { IndexDetailView(index: item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(item.price.num(2)).font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.72)
                Text((item.changePct * 100).num(2) + "% · " +
                     (item.updatedAt?.formatted(date: .omitted, time: .shortened) ?? "时间未知"))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(ProStyle.change(item.changePct)).lineLimit(1).minimumScaleFactor(0.66)
            }.padding(10).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .frame(width: width, height: height, alignment: .leading)
                .background(tokens.surface.opacity(theme == .dashboard ? 0.86 : 0.78),
                            in: RoundedRectangle(cornerRadius: theme == .bento ? 16 : tokens.corner * 0.68, style: .continuous))
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2).fill(ProStyle.change(item.changePct))
                        .frame(width: 3).padding(.vertical, 9).padding(.leading, 3)
                }
        }.buttonStyle(.plain)
    }

    private var chartPanel: some View {
        Group {
            if let q = active {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(q.name).font(theme == .magazine ? .title.weight(.bold) : .title2.weight(.semibold))
                                .lineLimit(2).minimumScaleFactor(0.8)
                            Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(q.price.num(3)).scaledFont(theme == .dashboard ? 27 : 30, weight: .semibold, design: .rounded)
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            Text((q.changePct * 100).num(2) + "%").font(.subheadline.monospacedDigit()).foregroundStyle(ProStyle.change(q.changePct))
                        }
                    }
                    if points.count > 1 {
                        Chart(points) { p in
                            LineMark(x: .value("时间", p.timestamp), y: .value("价格", p.price), series: .value("曲线", "价格"))
                                .foregroundStyle(tokens.accent).lineStyle(StrokeStyle(lineWidth: theme == .dashboard ? 2.2 : 1.8))
                            if let iopv = p.iopv {
                                LineMark(x: .value("时间", p.timestamp), y: .value("IOPV", iopv), series: .value("曲线", "IOPV"))
                                    .foregroundStyle(tokens.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                        }.chartYScale(domain: .automatic(includesZero: false)).chartXAxis(.hidden)
                            .frame(height: theme == .dashboard ? 222 : theme == .magazine ? 230 : 188)
                    } else {
                        ProEmpty(title: "等待分时数据", detail: "已有报价可以查看，历史走势不会用估算补齐。", icon: "chart.xyaxis.line")
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(q.updatedAt.map { "报价 " + $0.formatted(date: .omitted, time: .shortened) } ?? "报价时间未知")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Button("K 线与历史") {
                            advanced = Holding(code: q.code, name: q.name, quantity: 0, cost: 0, current: q.price, kind: .etf)
                        }.font(.subheadline)
                    }
                    if points.count > 1 {
                        Text("\(points.first?.day ?? "") · IOPV 仅在有原始数据时绘制")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProEmpty(title: "还没有可看的行情", detail: "刷新或添加证券后，行情图会在这里出现。", icon: "chart.xyaxis.line")
            }
        }.proSurface(tone: marketTone)
    }

    private var watchlistPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            ProSectionTitle(title: theme == .magazine ? "观察名单" : "自选证券", detail: "\(quotes.count) 只")
            if quotes.isEmpty { ProEmpty(title: "从关注的证券开始", detail: "添加场内 ETF 或股票，建立看盘清单。") }
            ForEach(quotes.indices, id: \.self) { index in
                let q = quotes[index]
                Button { selected = q.code } label: {
                    HStack(spacing: 11) {
                        if theme == .bento || theme == .eastern {
                            RoundedRectangle(cornerRadius: 6).fill(index.isMultiple(of: 2) ? tokens.accent.opacity(0.82) : tokens.secondary.opacity(0.82))
                                .frame(width: 5, height: 42)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(q.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(q.price.num(3)).monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
                            Text((q.changePct * 100).num(2) + "%").font(.caption.monospacedDigit()).foregroundStyle(ProStyle.change(q.changePct)).lineLimit(1)
                        }.frame(minWidth: 78, alignment: .trailing)
                        if theme == .magazine { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(tokens.accent) }
                    }.padding(.vertical, theme == .dashboard ? 6 : 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if index != quotes.count - 1 { Divider() }
            }
        }.proSurface(tone: marketTone)
    }

    private var bentoMarketSummary: some View {
        HStack(spacing: 10) {
            Label("自选 \(quotes.count)", systemImage: "star.fill")
            Spacer(minLength: 4)
            Label("分时 \(points.count > 1 ? "已更新" : "待更新")", systemImage: "waveform.path")
        }.font(.subheadline.weight(.semibold)).proSurface(tone: tokens.secondary)
    }
}

struct ProDecisionHubView: View {
    var body: some View {
        NavigationStack { ProPage(title: "投资决策", subtitle: "研究 · 计划 · 用户确认") {
            VStack(alignment: .leading, spacing: 16) {
                Text("私人投资顾问").font(.title2.weight(.semibold))
                Text("想等更低的价格，还是先安排未来资金？从你的真实持仓开始，一起把计划说清楚。").font(.body).foregroundStyle(.secondary).lineSpacing(6)
                NavigationLink("和私人顾问聊聊") { LabResearchView() }.buttonStyle(.borderedProminent)
            }.proSurface(tone: Color(red: 0.08, green: 0.56, blue: 0.48))
            VStack(spacing: 0) {
                NavigationLink { ProAllocationWorkspace() } label: { ProActionRow(title: "长期目标", detail: "调整并确认目标仓位", icon: "target") }
                Divider()
                NavigationLink { TradePlansView() } label: { ProActionRow(title: "耐心交易计划", detail: "价格、分档、有效期与重新评估", icon: "clock.badge.checkmark") }
                Divider()
                NavigationLink { PortfolioAdviceView() } label: { ProActionRow(title: "组合风险", detail: "现金缓冲与集中度", icon: "shield.lefthalf.filled") }
                Divider()
                NavigationLink { LabResearchView() } label: { ProActionRow(title: "查看研究证据", detail: "因子、数据覆盖和策略依据", icon: "text.magnifyingglass") }
                Divider()
                NavigationLink { ProOpportunityRadarView() } label: { ProActionRow(title: "机会雷达", detail: "独立证券池与离线研究文件", icon: "scope") }
            }.proSurface(tone: Color(red: 0.13, green: 0.56, blue: 0.50))
            Text("真实证券交易始终由你决定。").font(.caption).foregroundStyle(.secondary)
        } }
    }
}

struct ProLabWorkspace: View {
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @State private var selected = "G"
    @State private var comparison: [String: [String: Any]] = [:]
    @State private var comparisonError = ""
    private let titles = ["A": "持有与现金", "B": "初始比例", "C": "长期目标", "D": "再平衡", "E": "红利价值", "F": "趋势风控", "G": "AI 多因子"]
    private var orders: [[String: Any]] { lab.accounts[selected]?["orders"] as? [[String: Any]] ?? [] }
    var body: some View {
        NavigationStack { ProPage(title: "策略研究", subtitle: "NAS 机会筛查 · 本机研究") {
            if lab.state == nil {
                VStack(spacing: 12) {
                    ProEmpty(title: "NAS 研究等待真实数据", detail: "后台只扫描行情证据；手机 AI 会在真实持仓和行情齐备后给出统一指导。", icon: "point.3.connected.trianglepath.dotted")
                }.frame(maxWidth: .infinity).proSurface(tone: .purple)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ProSectionTitle(title: "NAS 后台机会筛查", detail: researchReady ? "行情快照已就绪" : "等待行情快照")
                    Text(researchReady
                         ? "NAS 定时筛查有足够历史数据且行情较新的标的，只把候选机会和证据写入量化通道。它不读取真实账户、不决定买卖、不生成委托或模拟成交；手机端再结合真实持仓核验。"
                         : "NAS 机会筛查需要有效的研究快照；数据缺失或行情过期时会暂停输出，不补造建议。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        Label(channels.quant.text, systemImage: channels.quant.text.contains("已连接") || channels.quant.text.contains("一致") ? "checkmark.circle.fill" : "externaldrive")
                        Spacer(minLength: 8)
                        if let lastScanAt {
                            Text("最近扫描 " + lastScanAt.formatted(date: .abbreviated, time: .shortened)).multilineTextAlignment(.trailing)
                        } else {
                            Text("尚无后台扫描记录").multilineTextAlignment(.trailing)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    Button("读取 NAS 研究结果") { Task { await channels.refresh() } }
                        .font(.subheadline.weight(.medium))
                }.proSurface(tone: researchReady ? .teal : .indigo)
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
                NavigationLink { TradingRuleSettingsView() } label: { ProActionRow(title: "核对 T+0 / T+1", detail: "按证券更正规则，保留历史成交", icon: "arrow.left.arrow.right") }
            }
            Text("NAS 只做行情研究；交易计划须由你在券商真实成交后手工确认。").font(.caption).foregroundStyle(.secondary)
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
    private var researchReady: Bool {
        (channels.marketDocument?["quality"] as? [String: Any])?["researchSnapshot"] is [String: Any]
    }
    private var lastScanAt: Date? {
        guard let raw = channels.executorInfo["lastScanAt"] as? NSNumber, raw.int64Value > 0 else { return nil }
        return Date(timeIntervalSince1970: raw.doubleValue / 1000)
    }
    private func status(_ raw: String) -> String { ["waiting": "等待成交", "partial": "部分成交", "filled": "已成交", "expired": "已到期", "cancelled": "已撤销"][raw] ?? "待核对" }
}

struct ProAssetsHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var add = false
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == .etf } }
    var body: some View {
        NavigationStack { ProPage(title: "我的资产", subtitle: "真实持仓 · 账户资料 · 设置") {
            VStack(alignment: .leading, spacing: 16) {
                ProSectionTitle(title: "账户概况", detail: "\(holdings.count) 只证券")
                HStack(spacing: 14) { ProMetric(title: "持仓市值", value: holdings.reduce(0) { $0 + $1.marketValue }.cny()); ProMetric(title: "可用现金", value: store.data.cash.cny()) }
                Text("盈亏只在各持仓卡片内展示，账户概况只显示资产构成。")
                    .scaledFont(12).foregroundStyle(.secondary)
            }.proSurface(tone: .blue)
            VStack(alignment: .leading, spacing: 10) {
                ProSectionTitle(title: "持仓明细", detail: "\(holdings.count) 只").padding(.bottom, 12)
                if holdings.isEmpty { ProEmpty(title: "建立真实资产视图", detail: "手动记录持仓，或预览 NAS 资产后确认接收。") }
                ForEach(holdings) { h in
                    NavigationLink { ProHoldingWorkspace(holding: h) } label: {
                        HoldingSummaryRow(holding: h, share: 0)
                    }
                    if h.id != holdings.last?.id { Divider() }
                }
            }.proSurface(tone: .teal)
            VStack(spacing: 0) {
                NavigationLink { AssetsView() } label: { ProActionRow(title: "资金与资产轨迹", detail: "现金流水、快照与历史回看", icon: "chart.line.uptrend.xyaxis") }
                Divider()
                NavigationLink { TradeLedgerManagementView() } label: { ProActionRow(title: "实际交易流水", detail: "核对成交与费用", icon: "list.bullet.rectangle") }
                Divider()
                NavigationLink { ManualAssetChannelView() } label: { ProActionRow(title: "手动同步真实资产", detail: "预览、核对、确认后接收", icon: "arrow.triangle.2.circlepath") }
                Divider()
                NavigationLink { ProSettingsWorkspace() } label: { ProActionRow(title: "设置与偏好", detail: "外观、行情连接、备份与研究偏好", icon: "slider.horizontal.3") }
            }.proSurface(tone: .indigo)
        }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { add = true } } }
        .sheet(isPresented: $add) { HoldingEditor(kind: .etf) } }
    }
}

private struct HoldingSummaryRow: View {
    let holding: Holding
    let share: Double
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(ProStyle.change(holding.pnl)).frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(holding.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(holding.code) · \(holding.quantity.num(0)) 份" + (share > 0 ? " · \((share * 100).num(1))%" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.78)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(holding.marketValue.cny()).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.72)
                Text(holding.pnl.cny()).font(.caption.monospacedDigit()).foregroundStyle(ProStyle.change(holding.pnl)).lineLimit(1)
            }.frame(minWidth: 92, alignment: .trailing)
        }.padding(.vertical, 8).contentShape(Rectangle())
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
            VStack(alignment: .leading, spacing: 16) {
                Text(current.marketValue.cny()).scaledFont(36, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                HStack(spacing: 12) { ProMetric(title: "数量", value: current.quantity.num(0)); ProMetric(title: "单位成本", value: current.cost.num(3)); ProMetric(title: "当前价格", value: current.current.num(3)) }
                HStack { ProMetric(title: "持仓账面盈亏", value: current.pnl.cny(), color: ProStyle.change(current.pnl)); Spacer() }
                HStack(spacing: 10) { Button("查看图表") { chart = true }.buttonStyle(.borderedProminent); Button("记录实际成交") { trade = true }.buttonStyle(.bordered) }
            }.proSurface(tone: ProStyle.change(current.pnl))
            VStack(spacing: 0) {
                NavigationLink { DayGridView() } label: { ProActionRow(title: "网格研究与复盘", detail: "行情与交易参数分析", icon: "square.grid.3x3") }
                Divider()
                Button { edit = true } label: { ProActionRow(title: "核对持仓资料", detail: "调整名称、份额和成本", icon: "pencil") }
            }.proSurface(tone: .teal)
            Text("记录成交只维护账本，不会发送证券订单。").font(.caption).foregroundStyle(.secondary)
        }.fullScreenCover(isPresented: $chart) { MarketChartView(holding: current) }.sheet(isPresented: $trade) { TradeEditor(holding: current) }.sheet(isPresented: $edit) { HoldingEditor(kind: .etf, initial: current) }
    }
}

struct ProSettingsWorkspace: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @AppStorage("guanpan.native.fontScale") private var scale = 1.0
    var body: some View {
        ProPage(title: "按你的方式观盘", subtitle: "外观、数据与研究偏好") {
            VStack(alignment: .leading, spacing: 16) {
                ProSectionTitle(title: "外观")
                Picker("显示模式", selection: Binding(get: { store.data.appearance }, set: { store.data.appearance = $0; store.save(propagate: false) })) {
                    Text("跟随系统").tag(AppAppearance.system); Text("浅色").tag(AppAppearance.light); Text("深色").tag(AppAppearance.dark); Text("护眼").tag(AppAppearance.eyeCare)
                }.pickerStyle(.menu)
                Text("护眼模式使用暖米色底和柔和绿，降低冷白背景的刺激。").font(.caption).foregroundStyle(.secondary)
                Stepper("文字大小 \(Int(scale * 100))%", value: $scale, in: 0.85...1.4, step: 0.05)
            }.proSurface(tone: .blue)
            VStack(alignment: .leading, spacing: 14) {
                ProSectionTitle(title: "三个独立通道")
                Text("真实资产 · " + channels.assets.text).font(.subheadline)
                Text("行情数据通道 · " + channels.market.text).font(.subheadline)
                Text("NAS机会筛查 · " + channels.quant.text).font(.subheadline)
                Label("在线大模型：手机直连服务商；离线规则：手机本地运行", systemImage: "iphone")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("检查行情与量化") { Task { await channels.refresh() } }.buttonStyle(.bordered)
            }.proSurface(tone: .teal)
            VStack(spacing: 0) {
                NavigationLink { ManualAssetChannelView() } label: { ProActionRow(title: "真实资产手动同步", detail: "接收前预览，冲突时保留两端", icon: "externaldrive") }
                Divider()
                NavigationLink { SettingsView() } label: { ProActionRow(title: "连接、备份与图表偏好", detail: "NAS、数据导出、主题与兼容配置", icon: "slider.horizontal.3") }
            }.proSurface(tone: .indigo)
        }
    }
}
