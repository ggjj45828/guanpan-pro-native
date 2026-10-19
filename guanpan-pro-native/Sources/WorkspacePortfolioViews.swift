import SwiftUI
import Charts

/// Shared shell for the redesigned primary pages. Existing record editors remain intact.
struct WorkspaceCanvas<Content: View>: View {
    let title: String
    let content: () -> Content
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22, content: content)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct WorkspaceSectionHeading: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).scaledFont(19, weight: .bold)
            Spacer(minLength: 8)
            Text(detail).scaledFont(11).foregroundStyle(.secondary)
        }
    }
}

struct WorkspaceOverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showMarket = false
    @State private var showTools = false
    @State private var showPlans = false
    @State private var showHealth = false
    @State private var selectedIndex: MarketIndexQuote?
    private var activeHoldings: [Holding] { store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 } }
    var body: some View {
        WorkspaceCanvas(title: "总览") {
            WorkspacePageIntro(title: "把握节奏，从容观盘", subtitle: store.isMarketClosedToday ? "今日休市 · 查看最近有效行情" : "行情与计划，各有依据", icon: "square.grid.2x2", tone: WorkspaceTone.blue)
            WorkspaceSectionHeading(title: "市场温度", detail: "自选与场内持仓")
            VStack(alignment: .leading, spacing: 14) {
                if let mood = store.marketMood {
                    let strength = mood.average * 100
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(MoodScale.label(strength)).scaledFont(28, weight: .bold)
                            Text("\(mood.count) 只标的 · 等权观察").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(strength.directionMark()) \(strength.pct(2))")
                            .scaledFont(24, weight: .semibold).monospacedDigit().foregroundStyle(PnLColor.of(strength))
                    }
                    MoodGauge(average: strength)
                    Text("仅反映关注标的的最近报价，不代表全市场。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("等待有效行情").font(.headline)
                    Text("刷新后显示关注标的的市场温度。") .font(.subheadline).foregroundStyle(.secondary)
                }
            }.cardSurface(tone: WorkspaceTone.teal)
            if !store.indexQuotes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.indexQuotes) { index in
                            Button { selectedIndex = index } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(index.name).font(.caption).foregroundStyle(.secondary)
                                    Text(index.price.num(2)).font(.headline).monospacedDigit().foregroundStyle(.primary)
                                    Text("\(index.changePct.directionMark()) \((index.changePct * 100).pct(2))")
                                        .font(.caption.bold()).foregroundStyle(PnLColor.of(index.changePct))
                                }.frame(minWidth: 110, alignment: .leading).cardSurface(tone: WorkspaceTone.blue)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            WorkspaceSectionHeading(title: "今日关注", detail: "先核对，再行动")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: "checklist").foregroundStyle(CardTone.accent).font(.title2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("交易计划").font(.headline)
                        Text("已保存 \(store.data.tradePlans.count) 条计划 · 场内持仓 \(activeHoldings.count) 只")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Button("查看计划与复盘", systemImage: "arrow.right") { showPlans = true }
                    .buttonStyle(.bordered)
            }.cardSurface(tone: CardTone.accent)
            HStack(alignment: .top, spacing: 12) {
                overviewTile("行情工作台", "自选 · 价格提醒", "chart.xyaxis.line", WorkspaceTone.blue) { showMarket = true }
                overviewTile("数据体检", "可信度 · 同步状态", "checkmark.shield", CardTone.warn) { showHealth = true }
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("数据状态", systemImage: "externaldrive").font(.headline)
                Text(store.sourceStatusText).font(.caption).foregroundStyle(.secondary)
                Text(store.nasSyncStatus).font(.caption).foregroundStyle(.secondary)
                Button("外观、连接与备份", systemImage: "slider.horizontal.3") { showTools = true }
            }.cardSurface(tone: WorkspaceTone.blue)
        }
        .refreshable { store.refreshQuotes(); store.refreshIndexQuotes() }
        .sheet(isPresented: $showMarket) { DashboardView(marketOnly: true).themedSheetBackground() }
        .sheet(isPresented: $showTools) { WorkspaceSettingsView().themedSheetBackground() }
        .sheet(isPresented: $showPlans) { TradePlansView().themedSheetBackground() }
        .sheet(isPresented: $showHealth) { DataTrustView().themedSheetBackground() }
        .sheet(item: $selectedIndex) { IndexDetailView(index: $0).themedSheetBackground() }
    }
    private func overviewTile(_ title: String, _ detail: String, _ icon: String, _ tone: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(tone)
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).cardSurface(tone: tone)
        }.buttonStyle(.plain)
    }
}

struct WorkspaceMarketView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var query = ""
    @State private var holdingsOnly = false
    @State private var detail: Holding?
    @State private var showWatchManagement = false
    @State private var showHoldings = false
    private var rows: [Quote] {
        var byCode = Dictionary(store.data.quotes.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        for h in store.data.holdings where h.kind == .etf && h.quantity > 0 && byCode[h.code] == nil {
            byCode[h.code] = Quote(code: h.code, name: h.name, price: h.current, changePct: 0, updatedAt: h.marketUpdatedAt)
        }
        return byCode.values.filter { q in
            let held = store.data.holdings.contains { $0.kind == .etf && $0.quantity > 0 && $0.code == q.code }
            return (!holdingsOnly || held) && (query.isEmpty || q.name.localizedCaseInsensitiveContains(query) || q.code.contains(query))
        }.sorted { $0.code < $1.code }
    }
    var body: some View {
        WorkspaceCanvas(title: "行情") {
            WorkspacePageIntro(title: "市场工作台", subtitle: store.sourceStatusText, icon: "chart.xyaxis.line", tone: WorkspaceTone.blue)
            WorkspaceFeatureActions(features: [.intradayArchive, .dataTrust])
            HStack {
                Button("管理自选与提醒", systemImage: "plus.circle") { showWatchManagement = true }
                Spacer()
                Button("持仓", systemImage: "briefcase") { showHoldings = true }
            }.buttonStyle(.bordered)
            Picker("行情范围", selection: $holdingsOnly) {
                Text("全部关注").tag(false); Text("我的持仓").tag(true)
            }.pickerStyle(.segmented)
            WorkspaceFeatureActions(features: [.quantEngine])
            if rows.isEmpty {
                ContentUnavailableView("暂无匹配标的", systemImage: "magnifyingglass", description: Text("添加自选，或调整搜索条件。"))
            }
            ForEach(rows) { q in
                let h = store.data.holdings.first { $0.code == q.code && $0.kind == .etf && $0.quantity > 0 }
                Button {
                    detail = h ?? Holding(code: q.code, name: q.name, quantity: 0, cost: 0, current: q.price, kind: .etf)
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(q.name.isEmpty ? q.code : q.name).scaledFont(17, weight: .semibold).foregroundStyle(.primary)
                                Text(q.code).font(.caption).foregroundStyle(.secondary)
                                Text(q.updatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "行情时间未知").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(q.price > 0 ? q.price.num(4) : "--").scaledFont(22, weight: .bold).monospacedDigit().foregroundStyle(.primary)
                                if store.data.quotes.contains(where: { $0.code == q.code }) {
                                    Text("\(q.changePct.directionMark()) \((q.changePct * 100).pct(2))")
                                        .font(.subheadline.bold()).foregroundStyle(PnLColor.of(q.changePct))
                                } else { Text("涨跌待更新").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                        HStack {
                            if let h { Text("成本 \(store.displayedCost(for: h).num(4)) · \(h.quantity.num(0)) 份") }
                            else { Text("关注标的") }
                            Spacer()
                            Label("分时 / 日K", systemImage: "chevron.right")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.cardSurface(tone: h == nil ? WorkspaceTone.blue : WorkspaceTone.teal)
                }.buttonStyle(.plain)
            }
        }
        .searchable(text: $query, prompt: "名称或证券代码")
        .refreshable { store.refreshQuotes() }
        .sheet(item: $detail) { MarketChartView(holding: $0).themedSheetBackground() }
        .sheet(isPresented: $showWatchManagement) { DashboardView(marketOnly: true).themedSheetBackground() }
        .sheet(isPresented: $showHoldings) { HoldingsView(kind: .etf).themedSheetBackground() }
    }
}

struct WorkspaceAssetsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showRecords = false
    @State private var showHoldings = false
    @State private var showLedger = false
    @State private var showTools = false
    private var positions: [Holding] { store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 } }
    private var snapshots: [PortfolioSnapshot] { Array(store.data.snapshots.sorted { $0.date < $1.date }.suffix(60)) }
    private var domain: ClosedRange<Double> {
        let values = snapshots.map(\.total).filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max(high - low, max(abs(high) * 0.01, 10)) * 0.1
        return (low - pad)...(high + pad)
    }
    var body: some View {
        WorkspaceCanvas(title: "资产") {
            WorkspacePageIntro(title: "我的资产", subtitle: "真实账本 · 与虚拟账户独立", icon: "lock.shield", tone: WorkspaceTone.blue)
            VStack(alignment: .leading, spacing: 18) {
                Text("账户总资产").font(.subheadline).foregroundStyle(.secondary)
                Text(store.totalAsset.cny()).scaledFont(36, weight: .bold, design: .rounded).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                MetricGrid(columns: 2, spacing: 16, cells: [
                    MetricCell(title: "当日盈亏", value: store.hasDayPnLGross ? store.dayPnLGross.cny() : "--", toneValue: store.hasDayPnLGross ? store.dayPnLGross : nil),
                    MetricCell(title: "持仓浮盈", value: store.totalPnL.cny(), toneValue: store.totalPnL),
                    MetricCell(title: "证券市值", value: store.marketValue(of: .etf).cny()),
                    MetricCell(title: "参考现金", value: store.data.cash.cny())])
                if store.marketValue(of: .fund) != 0 {
                    Text("含旧账本场外资产 \(store.marketValue(of: .fund).cny())；迁移前保留历史口径，未删除数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.cardSurface(tone: WorkspaceTone.blue)
            WorkspaceFeatureActions(features: [.etfIncomeCalendar, .returnSource, .dividendCalendar])
            WorkspaceFeatureActions(features: [.monthlyReview, .yearlyReview])
            WorkspaceSectionHeading(title: "资产轨迹", detail: "最近 \(snapshots.count) 条快照")
            VStack(alignment: .leading, spacing: 14) {
                if snapshots.count >= 2 {
                    Chart(snapshots) { p in
                        AreaMark(x: .value("日期", p.date), yStart: .value("下界", domain.lowerBound), yEnd: .value("总资产", p.total))
                            .foregroundStyle(WorkspaceTone.blue.opacity(0.08))
                        LineMark(x: .value("日期", p.date), y: .value("总资产", p.total))
                            .interpolationMethod(.catmullRom).foregroundStyle(WorkspaceTone.blue)
                        PointMark(x: .value("日期", p.date), y: .value("总资产", p.total)).symbolSize(18)
                            .foregroundStyle(p.quality == .provisional ? CardTone.warn : (p.quality == .reconstructed ? WorkspaceTone.teal : WorkspaceTone.blue))
                    }.chartYScale(domain: domain).chartXAxis(.hidden).frame(height: 150)
                    Text("资产变化含资金转入转出；收益请查看快照详情。蓝色为实测、蓝绿为历史重建、琥珀为待核对。")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("快照不足两条，暂不绘制曲线。").foregroundStyle(.secondary) }
                Button("快照管理与收益明细", systemImage: "calendar") { showRecords = true }.buttonStyle(.bordered)
            }.cardSurface(tone: WorkspaceTone.teal)
            WorkspaceFeatureActions(features: [.historicalReplay])
            WorkspaceSectionHeading(title: "证券分布", detail: "\(positions.count) 只持仓")
            VStack(alignment: .leading, spacing: 16) {
                if positions.isEmpty { Text("暂无场内持仓").foregroundStyle(.secondary) }
                ForEach(positions) { h in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(h.name).font(.subheadline.weight(.medium)); Spacer(); Text(h.marketValue.cny()).monospacedDigit() }
                        ProgressView(value: min(1, max(0, store.totalAsset > 0 ? h.marketValue / store.totalAsset : 0))).tint(WorkspaceTone.teal)
                    }
                }
                Button("管理持仓与成交记录", systemImage: "briefcase") { showHoldings = true }
            }.cardSurface(tone: WorkspaceTone.teal)
            WorkspaceFeatureActions(features: [.allocationTargets, .overlap, .portfolioAnalysis])
            WorkspaceSectionHeading(title: "成交与账本核对", detail: "记录真实发生的交易")
            WorkspaceFeatureActions(features: [.tradeCSVImport, .reconciliation, .ledgerHealth])
            HStack {
                Button("交易流水", systemImage: "list.bullet.rectangle") { showLedger = true }
                Spacer()
                Button("设置与备份", systemImage: "gearshape") { showTools = true }
            }.buttonStyle(.bordered)
        }
        .sheet(isPresented: $showRecords) { AssetsView().themedSheetBackground() }
        .sheet(isPresented: $showHoldings) { HoldingsView(kind: .etf).themedSheetBackground() }
        .sheet(isPresented: $showLedger) { TradeLedgerManagementView().themedSheetBackground() }
        .sheet(isPresented: $showTools) { WorkspaceSettingsView().themedSheetBackground() }
    }
}

struct WorkspaceSettingsView: View {
    @State private var destination: Destination?
    enum Destination: String, Identifiable { case appearance, sync; var id: String { rawValue } }
    var body: some View {
        WorkspaceCanvas(title: "设置") {
            WorkspacePageIntro(title: "设置与连接", subtitle: "外观、NAS 连接与备份", icon: "slider.horizontal.3", tone: WorkspaceTone.blue)
            tool("外观与偏好", "浅色、深色、跟随系统与护眼主题", "paintpalette", CardTone.accent, .appearance)
            tool("备份与数据同步", "保留现有手动确认与防覆盖流程", "externaldrive", WorkspaceTone.teal, .sync)
        }.sheet(item: $destination) { d in
            Group {
                switch d {
                case .appearance: SettingsView(mode: .app)
                case .sync: SettingsView(mode: .sync)
                }
            }.themedSheetBackground()
        }
    }
    private func tool(_ title: String, _ subtitle: String, _ icon: String, _ tone: Color, _ d: Destination) -> some View {
        Button { destination = d } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(tone).frame(width: 40)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.frame(minHeight: 68).cardSurface(tone: tone)
        }.buttonStyle(.plain)
    }
}
