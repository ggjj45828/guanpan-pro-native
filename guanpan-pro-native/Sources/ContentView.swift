import SwiftUI
import Charts
import UniformTypeIdentifiers
import UIKit

extension View {
    func keyboardDoneToolbar() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
    }
}

/// iPad / 横屏宽视图下的分栏入口。iPhone 仍走底部 TabView。
enum PadTab: String, CaseIterable, Identifiable {
    case watchlist
    case holdings
    case funds
    case assets
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watchlist: return "自选"
        case .holdings: return "持仓"
        case .funds: return "基金"
        case .assets: return "资产"
        case .more: return "更多"
        }
    }

    var icon: String {
        switch self {
        case .watchlist: return "chart.xyaxis.line"
        case .holdings: return "briefcase.fill"
        case .funds: return "building.columns.fill"
        case .assets: return "chart.pie.fill"
        case .more: return "ellipsis.circle.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("guanpan.native.fontScale") private var fontScale: Double = 1
    /// 必须是可选型：iOS 上 `List(selection:)` 只接受 `Binding<SelectionValue?>`，
    /// 写死成非可选会匹配到 macOS 专用的重载，编译报 "unavailable in iOS"。
    @State private var padTab: PadTab? = .watchlist
    /// 定时自动切换深浅时，需要一个随时间推进的驱动器，否则计划时间到了也不会变。
    @State private var themeTick = 0
    private let themeTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            backgroundLayer
            if useSplitLayout {
                padSplitRoot
            } else {
                phoneTabRoot
            }
        }
        .preferredColorScheme(effectiveColorScheme)
        .tint(store.effectiveAccentColor)
        .appFontScale(CGFloat(fontScale))
        .environment(\.defaultMinListRowHeight, AppLayout.minimumTapHeight)
        .onAppear {
            store.configureNASSync()
            // 首次进入就主动拉一次行情和指数；后续是否按间隔继续刷新由设置决定。
            // 这条自动刷新不驱动任何手动刷新按钮的转圈状态。
            store.refreshQuotes()
            store.refreshIndexQuotes()
            store.maybeRefreshFundNAVsAfterMarketClose()
            Task {
                await store.synchronizeNASSafely()
                await store.syncNASMarketArchive()
                await store.archiveTrackedIntraday()
                await store.ensureBackfillHistory()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.configureNASSync()
                store.refreshQuotes()
                store.refreshIndexQuotes()
                store.maybeRefreshFundNAVsAfterMarketClose()
                store.recordSnapshot()   // 打开 App 自动记当天快照，免得手动忘
                Task {
                    await store.synchronizeNASSafely()
                    await store.syncNASMarketArchive()
                    await store.archiveTrackedIntraday()
                    await store.ensureBackfillHistory()
                }
            }
            else { store.pauseNASSyncPolling() }
        }
        .onReceive(themeTimer) { _ in
            // 只在开启了定时切换时才自增，避免无谓的重绘
            guard !store.data.autoThemeSchedule.isEmpty else { return }
            themeTick += 1
        }
    }

    /// 依赖 themeTick，保证定时切换到了点会重算。
    private var effectiveColorScheme: ColorScheme? {
        _ = themeTick
        return store.effectiveColorScheme
    }

    private var currentTheme: AppTheme { AppTheme.palette(for: store.resolvedAppearance) }

    // MARK: - 双形态根容器（iPhone 用 TabView，iPad 用分栏）

    /// 不能只判 `horizontalSizeClass == .regular`：
    /// iPhone Plus / Pro Max 横屏时横向也是 .regular，会被误判成 iPad，
    /// 结果手机上出现一条 200–300pt 的常驻侧栏，内容区反而被挤成一条。
    /// iPad 的特征是「横竖都是 .regular」，用两个条件同时成立来区分。
    private var useSplitLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    @ViewBuilder private var phoneTabRoot: some View {
        TabView {
            DashboardView().tabItem { Label("自选", systemImage: "chart.xyaxis.line") }
            HoldingsView(kind: .etf).tabItem { Label("持仓", systemImage: "briefcase.fill") }
            HoldingsView(kind: .fund).tabItem { Label("基金", systemImage: "building.columns.fill") }
            AssetsView().tabItem { Label("资产", systemImage: "chart.pie.fill") }
            MoreHubView().tabItem { Label("更多", systemImage: "ellipsis.circle.fill") }
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
        .toolbarBackground(currentTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    /// iPad 上底部五个 Tab 会挤在中间、列表也只剩窄窄一条，观感很差；
    /// 改成 NavigationSplitView：左侧常驻侧栏，右侧整屏详情，横向空间才真正用起来。
    @ViewBuilder private var padSplitRoot: some View {
        NavigationSplitView {
            List(selection: $padTab) {
                ForEach(PadTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle("观盘 Pro")
        } detail: {
            padDetail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }

    @ViewBuilder private var padDetail: some View {
        // 侧栏未选中（iPad 上偶发）时回落到自选，不要显示空白详情栏
        switch padTab ?? .watchlist {
        case .watchlist: DashboardView()
        case .holdings: HoldingsView(kind: .etf)
        case .funds: HoldingsView(kind: .fund)
        case .assets: AssetsView()
        case .more: MoreHubView()
        }
    }

    /// 页面底色。
    ///
    /// v2.12 起只由「配色主题」决定：图片背景 / 渐变背景 / 遮罩 / 毛玻璃 / 卡片融合
    /// 这一整组已经移除（用户要求「只留配色主题」）。原来这里会叠一层图片或渐变，
    /// 再靠 `overlayTint` 压暗、靠卡片半透明透出来；界线很难调到每种主题都好看，
    /// 而且一旦铺了图，主题底色就完全看不见了。
    /// 老用户本机残留的背景文件由 `NativeBackgroundStore.removeLegacyBackgroundIfNeeded()` 一次性清掉，
    /// 否则设置页里已经没有入口，界面却还铺着那张图，既看不见也撤不掉。
    @ViewBuilder private var backgroundLayer: some View {
        currentTheme.gradient
            .ignoresSafeArea()
    }
}

/// 自选分组后的一节。用结构体而不是元组：Swift 的 KeyPath 取不到元组元素，
/// `ForEach(..., id: \.name)` 对元组会直接编译失败。
private struct WatchSection: Identifiable {
    let name: String
    let items: [Quote]
    var id: String { name }
}

/// 首页「盘中机会」的轻量结论。它不是下单指令：日线技术分只提供底座，
/// 再用刚刷新的涨跌幅和自选/持仓环境做小幅修正，因此行情刷新时会随之变化。
private struct IntradayOpportunity: Identifiable {
    let quote: Quote
    let score: Int
    let action: String
    let detail: String
    var id: String { quote.code }

    var color: Color {
        switch action {
        case "可考虑": return .orange
        case "等确认": return Color(red: 0.30, green: 0.46, blue: 0.72)
        default: return PnLColor.down
        }
    }
}

/// 自选排序方式。默认「添加顺序」即数组原序，其余为只读排序，不改动存储。
enum WatchSortMode: String, CaseIterable, Identifiable {
    case manual
    case gainers
    case losers
    case name
    case code
    case signal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "添加顺序"
        case .gainers: return "涨幅优先"
        case .losers: return "跌幅优先"
        case .name: return "按名称"
        case .code: return "按代码"
        case .signal: return "按信号强度"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "list.number"
        case .gainers: return "arrow.up.right"
        case .losers: return "arrow.down.right"
        case .name: return "textformat.abc"
        case .code: return "number"
        case .signal: return "waveform.path.ecg"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    /// 右上角的动画只反馈用户自己点的刷新。自动轮询保持安静，不能假装成一次手动操作。
    @State private var isManuallyRefreshing = false
    @AppStorage("guanpan.native.watch.sort") private var sortMode: WatchSortMode = .manual
    @AppStorage("guanpan.native.watch.grouping") private var groupEnabled = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    /// 非 nil 时为「新建分组」弹窗的目标标的代码
    @State private var groupEditor: String?
    @State private var groupDraft = ""

    // 拿不到当日涨跌幅时显示 --，避免把「没数据」画成 0。
    private var pnlRateText: String { store.totalPnLRate.map { $0.pct(2) } ?? "--" }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdd = false
    @State private var showAlertEditor = false
    @State private var chartTarget: Holding?
    /// 盘中机会默认收起，首页先保留最重要的一条结论，避免推低自选列表。
    @State private var showIntradayOpportunities = false
    /// 顶部指数条里被点开的那一格（nil = 没打开详情）。
    @State private var indexDetailTarget: MarketIndexQuote?

    // MARK: - 自选：搜索 / 排序 / 分组

    /// 搜索（名称或代码）+ 排序后的自选列表。分组只是显示层切分，不动存储顺序。
    private var filteredQuotes: [Quote] {
        var list = store.data.quotes
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(keyword) || $0.code.contains(keyword)
            }
        }
        switch sortMode {
        case .manual: break
        case .gainers: list.sort { $0.changePct > $1.changePct }
        case .losers: list.sort { $0.changePct < $1.changePct }
        case .name:
            list.sort { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        case .code: list.sort { $0.code < $1.code }
        case .signal:
            // 预计算一次分数再排序：比较器里每比较一次就实时算分会把 O(n log n)
            // 次昂贵计算塞进一次渲染（滚动/刷新时首当其冲）。
            var scoreByCode: [String: Int] = [:]
            scoreByCode.reserveCapacity(list.count)
            for q in list { scoreByCode[q.code] = store.signal(forCode: q.code)?.score ?? -1 }
            list.sort { (scoreByCode[$0.code] ?? -1) > (scoreByCode[$1.code] ?? -1) }
        }
        return list
    }

    /// 分组后的分节数据。关掉分组时返回单节。
    private var watchSections: [WatchSection] {
        guard groupEnabled else { return [WatchSection(name: "", items: filteredQuotes)] }
        var order: [String] = []
        var buckets: [String: [Quote]] = [:]
        for q in filteredQuotes {
            let key = q.group.isEmpty ? "未分组" : q.group
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(q)
        }
        // 「未分组」永远排最后，前面按用户建立分组的顺序
        return order.sorted { a, b in
            if a == "未分组" { return false }
            if b == "未分组" { return true }
            return (store.watchGroups.firstIndex(of: a) ?? 0) < (store.watchGroups.firstIndex(of: b) ?? 0)
        }.map { WatchSection(name: $0, items: buckets[$0] ?? []) }
    }

    private func displayName(_ q: Quote) -> String { q.name.isEmpty ? q.code : q.name }

    /// 没有日线缓存时返回 -1，保证「无信号」排在最后而不是混在有信号的中间。
    private func signalScore(_ q: Quote) -> Int {
        store.signal(forCode: q.code)?.score ?? -1
    }

    private func watchDividendYield(_ q: Quote) -> Double? {
        guard q.price > 0 else { return nil }
        let holding = store.data.holdings.first { $0.kind == .etf && $0.code == q.code }
        if let holding, let projection = ETFDividendProjection.annualPerShare(for: holding, events: store.data.etfDividendEvents) {
            return projection.amount > 0 ? projection.amount / q.price * 100 : nil
        }
        let cutoff = ETFDividendProjection.yearAgoCutoff()
        let annual = ETFDividendProjection.mergedEvents(store.data.etfDividendEvents)
            .filter { $0.code == q.code && $0.date >= cutoff && $0.isEstimated != true }
            .reduce(0) { $0 + $1.amountPerShare }
        return annual > 0 ? annual / q.price * 100 : nil
    }

    private var intradayOpportunities: [IntradayOpportunity] {
        let moodPercent = (store.marketMood?.average ?? 0) * 100
        return store.data.quotes.compactMap { quote in
            // 日线没准备好时宁可不打分，也不把一条实时涨跌冒充成完整建议。
            guard let signal = store.signal(forCode: quote.code) else { return nil }
            let changeAdjustment = max(-8, min(8, quote.changePct * 100 * 3))
            let moodAdjustment = max(-6, min(6, moodPercent * 4))
            let premiumAdjustment: Double
            if let premium = store.marketPremiums[quote.code], abs(premium) >= 2 {
                premiumAdjustment = premium > 0 ? -5 : -2
            } else {
                premiumAdjustment = 0
            }
            let holding = store.data.holdings.first { $0.kind == .etf && $0.code == quote.code && $0.quantity > 0 }
            let currentWeight = holding.map { store.totalAsset > 0 ? $0.marketValue / store.totalAsset * 100 : 0 }
            let positionLimit = holding?.maxPositionPercent
                ?? (store.data.globalPositionLimitPercent > 0 ? store.data.globalPositionLimitPercent : store.data.investmentProfile.maxPositionPercent)
            let positionAdjustment: Double
            if let currentWeight {
                positionAdjustment = currentWeight >= positionLimit ? -10 : currentWeight >= positionLimit * 0.8 ? -5 : 0
            } else {
                positionAdjustment = 0
            }
            let score = Int((Double(signal.score) + changeAdjustment + moodAdjustment + premiumAdjustment + positionAdjustment).rounded())
            let clamped = min(99, max(1, score))
            let action: String
            if clamped >= 65 { action = "可考虑" }
            else if clamped >= 48 { action = "等确认" }
            else { action = "谨慎" }
            let technical = signal.tags.first?.text ?? signal.trendText
            let context = currentWeight.map { "仓位 \($0.pct(0))" }
                ?? (moodPercent >= 0.3 ? "环境配合" : moodPercent <= -0.3 ? "环境偏弱" : "环境中性")
            return IntradayOpportunity(quote: quote, score: clamped, action: action,
                                       detail: "\(technical) · \(context)")
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.quote.code < rhs.quote.code : lhs.score > rhs.score
        }
        .map { $0 }
    }

    private func marketActionHint(_ strength: Double) -> String {
        if strength >= 0.3 { return "可观察突破或回踩确认的机会，仍要看仓位与溢价。" }
        if strength <= -0.3 { return "优先控仓与等待确认，不因单一超卖信号急着补仓。" }
        return "只做有明确信号的标的，避免为凑操作而交易。"
    }

    /// 自选卡片使用稳定的柔和色轮换；涨跌含义仍只由数字旁的红/绿与方向符号承担，
    /// 避免列表里长期只有某一只标的碰巧是绿色卡片。
    private func watchCardTone(_ code: String) -> Color {
        let palette: [Color] = [.mint, .blue, .purple, .orange, .pink]
        let index = code.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[index]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    marketStrip
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section("账户") {
                    accountSummaryCard
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section("盘面环境") {
                    if let mood = store.marketMood {
                        // marketMood.average 是小数比率（0.01 = 1%），阈值与显示都按百分数走
                        let strength = mood.average * 100
                        // 分档阈值与文案统一走 MoodScale，和持仓页各模块的量尺同口径
                        let tone = MoodScale.tone(strength)
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("今日环境：\(MoodScale.label(strength))")
                                    .scaledFont(14, weight: .semibold)
                                Spacer(minLength: 8)
                                Text("\(strength.directionMark()) \(strength.pct(2))")
                                    .scaledFont(15, weight: .bold).monospacedDigit()
                                    .foregroundStyle(tone == Color.gray ? Color.primary : tone)
                                Text(MoodScale.label(strength))
                                    .scaledFont(12, weight: .semibold)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(MoodScale.badgeBackground(strength)))
                                    .foregroundStyle(MoodScale.foreground(strength))
                            }
                            MoodGauge(average: strength)
                            Text(marketActionHint(strength))
                                .scaledFont(11).foregroundStyle(.primary)
                            Text("依据：自选与场内持仓共 \(mood.count) 只标的的最近报价等权计算；它只给操作背景，不代表整个市场。")
                                .scaledFont(10).foregroundStyle(.secondary)
                        }
                        .toneCard(tone, isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
                    } else {
                        Text("获取行情后显示自选与场内持仓的平均涨跌幅。")
                            .foregroundStyle(.secondary)
                    }
                }
                if !intradayOpportunities.isEmpty {
                    Section("盘中机会") {
                        DisclosureGroup(isExpanded: $showIntradayOpportunities) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("本机规则评分：综合日线技术信号、当日涨跌、组合环境、溢价与当前仓位。它不是大模型结论，也不构成买入指令。")
                                    .scaledFont(10).foregroundStyle(.secondary)
                                ForEach(intradayOpportunities) { item in
                                    Button {
                                        chartTarget = Holding(code: item.quote.code, name: item.quote.name, quantity: 0,
                                                              cost: 0, current: item.quote.price, kind: .etf,
                                                              marketUpdatedAt: item.quote.updatedAt)
                                    } label: {
                                        HStack(spacing: 9) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(displayName(item.quote)).scaledFont(12, weight: .semibold).lineLimit(1)
                                                Text(item.detail).scaledFont(9).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                            Text("\(item.score)")
                                                .scaledFont(21, weight: .bold).monospacedDigit().foregroundStyle(item.color)
                                            Text(item.action)
                                                .scaledFont(10, weight: .semibold).foregroundStyle(item.color)
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(item.color.opacity(0.12), in: Capsule())
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if item.id != intradayOpportunities.last?.id { Divider() }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("值不值得买 · 本机规则评分")
                                        .scaledFont(13, weight: .bold)
                                    if let best = intradayOpportunities.first {
                                        Text("\(displayName(best.quote))  ·  \(best.score) 分  ·  \(best.action)")
                                            .scaledFont(11, weight: .medium)
                                            .foregroundStyle(best.color)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 6)
                                if let date = store.intradayQuoteDate {
                                    Text(date.formatted(date: .omitted, time: .shortened))
                                        .scaledFont(10).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .toneCard(store.effectiveAccentColor, isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
                    }
                }
                if store.data.quotes.isEmpty {
                    Section("自选") { Text("还没有自选标的").foregroundStyle(.secondary) }
                } else if filteredQuotes.isEmpty {
                    Section("自选") { Text("没有匹配「\(searchText)」的自选标的").foregroundStyle(.secondary) }
                } else {
                    ForEach(watchSections) { section in
                        Section {
                            watchRows(section.items)
                        } header: {
                            if !section.name.isEmpty {
                                HStack(spacing: 6) {
                                    Text(section.name).font(.subheadline.weight(.semibold))
                                    Text("\(section.items.count) 只").font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("自选")
                            }
                        }
                    }
                }
                Section("价格提醒（一次性）") {
                    if store.data.quoteAlerts.isEmpty { Text("暂无提醒。需要允许系统通知，并在行情刷新时触发。").foregroundStyle(.secondary) }
                    ForEach(store.data.quoteAlerts) { alert in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(alert.name) · \(alert.code)")
                                Text("\(alert.direction == .above ? "上穿" : "下穿") \((alert.target).num(3)) · \(alert.enabled ? "等待触发" : "已触发")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !alert.enabled {
                                Button("重启") { store.reenableQuoteAlert(alert) }.font(.caption)
                            }
                        }
                    }.onDelete { offsets in
                        let rows = store.data.quoteAlerts
                        for index in offsets { store.removeQuoteAlert(rows[index]) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear).navigationTitle("总览")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索名称或代码")
            .refreshable {
                // 下拉刷新与右上角那个按钮做同一件事：个股 + 指数。
                await manuallyRefreshDashboard()
            }
            .refreshFeedbackOverlay(refreshFeedback)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加自选", systemImage: "plus") { showAdd = true }
                    Button("添加价格提醒", systemImage: "bell.badge") { showAlertEditor = true }
                    Divider()
                    Menu {
                        ForEach(WatchSortMode.allCases) { mode in
                            Button {
                                sortMode = mode
                            } label: {
                                if sortMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: { Label("排序：\(sortMode.title)", systemImage: "arrow.up.arrow.down") }
                    Button {
                        groupEnabled.toggle()
                    } label: {
                        if groupEnabled { Label("按分组显示（已开）", systemImage: "folder.fill") }
                        else { Label("按分组显示", systemImage: "folder") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            } }
            // 刷新：从「行情状态」那一整段 Section 里挪到右上角，只留一个符号。
            // 放在菜单之后，所以它落在最右 —— 与用户说的「刷新就只是个刷新符号，在右上角」一致。
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.push()
                    Task { await manuallyRefreshDashboard() }
                } label: {
                    RefreshToolbarIcon(isRefreshing: isManuallyRefreshing)
                }
                .disabled(isManuallyRefreshing)
                .accessibilityLabel("刷新行情")
                .accessibilityHint("同时刷新自选、持仓和顶部指数")
            } }
            .sheet(isPresented: $showAdd) { WatchEditor() .themedSheetBackground() }
            .sheet(isPresented: $showAlertEditor) { QuoteAlertEditor() .themedSheetBackground() }
            .fullScreenCover(item: $chartTarget) { holding in MarketChartView(holding: holding).themedSheetBackground() }
            .sheet(item: $indexDetailTarget) { index in IndexDetailView(index: index).themedSheetBackground() }
            .alert("新建分组", isPresented: groupEditorBinding) {
                TextField("分组名", text: $groupDraft)
                Button("确定") {
                    let name = groupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let code = groupEditor { store.moveWatch(code: code, to: name) }
                    groupDraft = ""
                    groupEditor = nil
                }
                Button("取消", role: .cancel) { groupDraft = ""; groupEditor = nil }
            } message: {
                Text("分组只影响自选列表的显示与排序，不影响行情与持仓。")
            }
            .task {
                while !Task.isCancelled {
                    let interval = store.data.quoteRefreshSeconds
                    if scenePhase == .active && interval > 0 {
                        store.refreshQuotes()
                        // 指数与个股是两条请求，这里跟着自动刷新一起走，
                        // 否则只有手动点右上角时顶部那一排才会变。
                        store.refreshIndexQuotes()
                    }
                    try? await Task.sleep(for: .seconds(interval > 0 ? interval : 60))
                }
            }
        }
    }

    @MainActor private func manuallyRefreshDashboard() async {
        guard !isManuallyRefreshing else { return }
        isManuallyRefreshing = true
        defer { isManuallyRefreshing = false }
        refreshFeedback.begin("正在刷新行情和指数…")
        let deadline = Date().addingTimeInterval(25)
        while (store.isRefreshingQuotes || store.isRefreshingIndices) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !store.isRefreshingQuotes && !store.isRefreshingIndices else {
            refreshFeedback.finish("自动行情请求仍未结束，请稍后重试", succeeded: false)
            return
        }
        let quotesOK = await store.refreshQuotesAndWait()
        let indicesOK = await store.performIndexRefresh()
        let succeeded = quotesOK && indicesOK
        let message: String
        if succeeded { message = "行情和指数已更新" }
        else if quotesOK || indicesOK { message = "部分数据已更新，请稍后再试" }
        else { message = "刷新失败，请检查网络后重试" }
        refreshFeedback.finish(message, succeeded: succeeded)
    }

    // MARK: - 首页顶部指数条

    /// 顶部指数条：横向可滑，一屏放不下的往左划；点一格进该指数的详情页。
    ///
    /// 对齐网页版最上面那一排「上证指数 / 纳斯达克…」。指数不在自选里，
    /// 走 `PortfolioStore.performIndexRefresh()` 单独取，取不到就继续显示上次缓存的值。
    ///
    /// 下面那行小字是原来的「行情状态」Section：一整段 Section 只为显示一句话，
    /// 占的高度和信息量不成比例。这里压成「一个小圆点 + 一行 10px 文本」，
    /// 颜色反映数据新鲜度；刷新按钮挪到导航栏右上角，只剩一个符号。
    /// 行尾那句「左滑 · 点开看走势」是必要的：ScrollView 默认不给任何可滑提示，
    /// 一屏只露得出三四个指数，不加这句话用户不会知道右边还有、而且能点。
    private var marketStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.indexQuotes.isEmpty {
                Text("点右上角刷新按钮获取指数行情")
                    .scaledFont(11).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.indexQuotes) { item in
                            Button { Haptics.tap(); indexDetailTarget = item } label: {
                                marketIndexChip(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
            HStack(spacing: 5) {
                Circle().fill(statusDotColor).frame(width: 5, height: 5)
                Text(store.sourceStatus).scaledFont(10).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if !store.indexQuotes.isEmpty {
                    Text("左滑 · 点开看走势")
                        .scaledFont(9).foregroundStyle(.tertiary)
                        .lineLimit(1).layoutPriority(-1)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// 行情源状态圆点：蓝绿=刚更新过，琥珀=正在刷新/等待，红=上一次失败，灰=还没刷过。
    ///
    /// 这里的红是「出错」的红，不是红涨绿跌的红。圆点旁边没有任何数字，
    /// 所以直接用系统红而不走 `PnLColor` —— 走 PnLColor 反而会让人把它读成涨跌。
    private var statusDotColor: Color {
        if store.sourceStatus.contains("失败") { return .red }
        if store.isRefreshingQuotes || store.sourceStatus.contains("正在") { return CardTone.warn }
        if store.sourceStatus.contains("已更新") { return CardTone.ok }
        return Color.secondary.opacity(0.6)
    }

    private func marketIndexChip(_ item: MarketIndexQuote) -> some View {
        let tone = PnLColor.of(item.changePct)
        let percent = (item.changePct * 100).pct(2)
        return VStack(alignment: .leading, spacing: 1) {
            Text(item.name).scaledFont(10).foregroundStyle(.secondary).lineLimit(1)
            Text((item.price).num(2))
                .scaledFont(14, weight: .semibold, design: .rounded)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(tone)
            Text("\(item.changePct.directionMark()) \(percent)")
                .scaledFont(10, weight: .medium).monospacedDigit().lineLimit(1)
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(minWidth: 84, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tone.opacity(0.24), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) \((item.price).num(2))，\(item.changePct.directionMark())\(percent)")
    }

    // MARK: - 首页账户卡

    /// 首页账户卡：一行「总资产 / 当日盈亏」+ 3×3 明细。
    ///
    /// v2.12 把两张卡合成了一张，但「今日盈亏」当时只统计了场内 ETF，却和「总资产」
    /// 并排放在最显眼的位置，很容易被读成「全部账户的今日盈亏」。
    ///
    /// v2.13 按主流基金 App 的账户卡重排：主区域只留两个数 —— 左边总资产、右边当日盈亏，
    /// **并把数据日期写进标签**（「10-09 当日盈亏」），一眼能分辨谁是谁；
    /// 场内 / 场外各自的盈亏压到下面宫格里分成两格，主区域不再堆第二、第三行。
    private var accountSummaryCard: some View {
        let grossTone = store.hasDayPnLGross ? PnLColor.of(store.dayPnLGross) : Color.secondary
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("总资产").scaledFont(11).foregroundStyle(.secondary)
                    Text((store.totalAsset).cny())
                        .scaledFont(28, weight: .bold, design: .rounded)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(dayPnLLabel).scaledFont(11).foregroundStyle(.secondary)
                    Text(store.hasDayPnLGross ? store.dayPnLGross.cny() : "--")
                        .scaledFont(20, weight: .bold, design: .rounded)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(grossTone)
                    Text(store.hasDayPnLGross
                         ? "\(store.dayPnLGross.directionMark()) \(store.dayPnLGrossRate.map { $0.pct(2) } ?? "--")"
                         : "--")
                        .scaledFont(11, weight: .semibold)
                        .monospacedDigit().lineLimit(1)
                        .foregroundStyle(grossTone)
                }
            }
            Divider().opacity(0.4)
            MetricGrid(columns: 3, cells: [
                MetricCell(title: "持仓市值", value: store.totalMarketValue.cny()),
                MetricCell(title: "参考现金", value: store.data.cash.cny()),
                MetricCell(title: "仓位", value: store.positionPercent.pct(1)),
                MetricCell(title: "持仓浮盈", value: store.totalPnL.cny(), toneValue: store.totalPnL),
                MetricCell(title: "盈亏比例", value: pnlRateText, toneValue: store.totalPnL),
                MetricCell(title: "总成本", value: store.totalCost.cny()),
                MetricCell(title: "已实现", value: store.realizedPnL.cny(), toneValue: store.realizedPnL),
                MetricCell(title: "场内盈亏", value: store.hasIntradayPnL ? store.intradayPnL.cny() : "--",
                           toneValue: store.hasIntradayPnL ? store.intradayPnL : nil),
                MetricCell(title: "场外盈亏", value: store.hasFundDayPnL ? store.fundDayPnL.cny() : "--",
                           toneValue: store.hasFundDayPnL ? store.fundDayPnL : nil)
            ])
            Text("持仓市值 + 参考现金 = 总资产。当日盈亏 = 场内证券（\(intradayDateNote)）+ 净值日期为今天的场外基金变化（\(fundNAVDateNote)）。晚一天公布的美股基金净值归到它对应的净值日，不挪到公布日；补到的历史净值用于回算历史快照。")
                .scaledFont(10).foregroundStyle(.secondary)
        }
        .cardSurface(tone: CardTone.pnl(store.totalPnL))
    }

    /// 当日盈亏的标签。核心是**别让人以为是当天**：
    /// 休市时行情源照旧返回上一交易日收盘价，而场外基金要 T+1 才有净值 ——
    /// 场内还在跳、场外是空的，很容易被读成「今天场内赚了这么多」。
    /// 所以标签按数据时点分档写死：今日盈亏 / 今日收盘盈亏 / 休市 · MM-dd 盈亏。
    private var dayPnLLabel: String {
        // 只有场外基金、且今日净值还没到公布时间：没有任何可显示的数字，
        // 与其显示一个会被误读成「今天场外盈亏」的旧净值日数字，不如说清楚在等什么。
        if !store.hasIntradayPnL,
           store.data.holdings.contains(where: { $0.kind == .fund }),
           !store.hasFundDayPnL {
            return "今日盈亏（场外净值未更新）"
        }
        guard store.hasDayPnLGross else { return "当日盈亏" }
        if store.hasIntradayPnL, let day = store.intradayQuoteDate.map({ shortDay($0) }) {
            if !store.isIntradayQuoteToday {
                return store.hasFundDayPnL ? "行情休市 \(day) · 净值今日更新" : "休市 · \(day) 盈亏"
            }
            return store.isMarketOpenNow ? "今日盈亏" : "今日收盘盈亏"
        }
        // 场外实际收益只在净值估值日入账；采集日不能把前几天的变化挪成今天收益。
        if store.hasFundDayPnL, let day = store.latestFundNAVDate.map({ shortDay($0) }) {
            return "基金净值日 \(day)"
        }
        return "当日盈亏"
    }

    /// 场内行情的时点说明。休市时行情源仍会返回上一交易日收盘价 ——
    /// 必须写死状态，否则周末看到的数字会被当成当天的。
    private var intradayDateNote: String {
        guard store.hasIntradayPnL, let date = store.intradayQuoteDate else { return "无行情" }
        if !store.isIntradayQuoteToday { return "休市 · \(shortDay(date)) 收盘" }
        return store.isMarketOpenNow ? "实时" : "\(shortDay(date)) 收盘"
    }

    /// 场外基金最新公布净值日。"2026-10-08" → "净值 10-08"。
    /// 开市日白天今日净值还没公布时，场外盈亏不参与合计，这里要写明在等晚间更新。
    private var fundNAVDateNote: String {
        guard let date = store.latestFundNAVDate else { return "无净值" }
        let today = MarketCalendar.isoDay(.now)
        guard date == today, store.hasFundDayPnL else {
            return "最新净值日 \(shortDay(date)) · 今日净值未公布，不计入今日"
        }
        return "净值日 \(shortDay(date)) · 今日已公布"
    }

    // MARK: - 自选行渲染

    @ViewBuilder private func watchRows(_ items: [Quote]) -> some View {
        ForEach(items) { q in
            Button {
                chartTarget = Holding(code: q.code, name: q.name, quantity: 0, cost: 0,
                                      current: q.price, kind: .etf, marketUpdatedAt: q.updatedAt)
            } label: {
                watchCard(q)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowBackground(Color.clear)
            .contextMenu { watchContextMenu(q) }
        }
        .onDelete { offsets in
            // 搜索/排序/分组之后，这里的下标是过滤后列表的下标，
            // 直接对原数组 remove(atOffsets:) 会删错标的，所以按代码匹配删除。
            let codes = Set(offsets.map { items[$0].code })
            store.data.quotes.removeAll { codes.contains($0.code) }
            store.save(label: "删除自选")
        }
    }

    private func watchCard(_ q: Quote) -> some View {
        // 国内红涨绿跌
        let accent = q.changePct >= 0
            ? Color(red: 0.93, green: 0.30, blue: 0.37)
            : Color(red: 0.07, green: 0.77, blue: 0.55)
        let signal = store.signal(forCode: q.code)
        let premium = store.marketPremiums[q.code]
        let dividendYield = watchDividendYield(q)
        return HStack(spacing: 10) {
            // 左侧 3pt 涨跌色条：扫列表时不用逐个读数字就能分辨红绿
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.85))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(q)).font(.headline).lineLimit(1)
                        Text(q.code).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(q.price > 0 ? q.price.num(3) : "--")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        // 方向符号：色盲 / 灰度打印时也能分辨涨跌，不单靠红绿
                        Text("\((q.changePct).directionMark()) \((q.changePct * 100).pct(2))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                }
                // 技术信号标签：与网页版口径一致（MACD多空 / 超买超卖 / 放量 / MA20 位置）
                // 需要该标的日线缓存；无缓存则静默不显示，不臆测。
                if let signal {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            compactScoreTag(signal)
                            compactTrendTag(signal.trendText)
                            SignalTagRow(tags: Array(signal.tags.prefix(3)))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 3) {
                                compactScoreTag(signal)
                                compactTrendTag(signal.trendText)
                            }
                            SignalTagRow(tags: Array(signal.tags.prefix(3)))
                        }
                    }
                } else if store.dailyBars[q.code] == nil {
                    Text("点开一次可载入日线，显示技术信号")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if premium != nil || dividendYield != nil {
                    HStack(spacing: 8) {
                        if let premium {
                            Text("溢价 \(premium.pct(2))")
                                .scaledFont(9, weight: .semibold)
                                .foregroundStyle(abs(premium) >= 1 ? Color.orange : Color.purple)
                        }
                        if let dividendYield {
                            Text("股息率 \(dividendYield.pct(2))")
                                .scaledFont(9, weight: .semibold)
                                .foregroundStyle(Color(red: 0.07, green: 0.68, blue: 0.48))
                        }
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 6) {
                    let groupName = q.group.isEmpty ? "未分组" : q.group
                    HStack(spacing: 3) {
                        Image(systemName: "folder").scaledFont(8)
                        Text(groupName).scaledFont(9, weight: .medium)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer(minLength: 6)
                    if let updated = q.updatedAt {
                        Text("\(updated.formatted(date: .omitted, time: .shortened)) 更新")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("点开查看分时、日K和指标")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(AppLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanelBackground(cornerRadius: AppLayout.cardRadius,
            fallback: Color(uiColor: .secondarySystemBackground).opacity(0.72),
            tone: watchCardTone(q.code))
        // 读屏：名称 + 现价 + 涨跌一次念完，而不是 6 个独立焦点各念一遍
        .combineAccessibility()
        .accessibilityLabel(watchSpokenLabel(q))
    }

    private func compactScoreTag(_ signal: MarketSignal) -> some View {
        let tone = signal.score > 50 ? Color(red: 0.93, green: 0.30, blue: 0.37)
            : signal.score < 50 ? Color(red: 0.07, green: 0.77, blue: 0.55) : Color.secondary
        return Text("\(signal.score) \(signal.label)")
            .scaledFont(9, weight: .semibold).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(tone)
            .background(tone.opacity(0.14), in: Capsule())
    }

    private func compactTrendTag(_ text: String) -> some View {
        Text(text)
            .scaledFont(9, weight: .medium).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    /// 自选卡片的读屏文案。价格可能缺失，缺了就说「无报价」而不是念 0。
    private func watchSpokenLabel(_ q: Quote) -> String {
        let price = q.price > 0 ? "现价 \(q.price.num(3))" : "无报价"
        return "\(displayName(q))，代码 \(q.code)，\(price)，\(spokenPercent(q.changePct * 100))"
    }

    @ViewBuilder private func watchContextMenu(_ q: Quote) -> some View {
        Button { store.pinWatchToTop(code: q.code) } label: {
            Label("置顶", systemImage: "arrow.up.to.line")
        }
        Menu("移动到分组") {
            Button("未分组") { store.moveWatch(code: q.code, to: "") }
            ForEach(store.watchGroups, id: \.self) { group in
                Button(group) { store.moveWatch(code: q.code, to: group) }
            }
            Divider()
            Button("新建分组…") { groupDraft = ""; groupEditor = q.code }
        }
        Divider()
        Button(role: .destructive) {
            store.data.quotes.removeAll { $0.code == q.code }
            store.save(label: "删除自选")
        } label: { Label("删除", systemImage: "trash") }
    }

    private var groupEditorBinding: Binding<Bool> {
        Binding(get: { groupEditor != nil }, set: { if !$0 { groupEditor = nil } })
    }
}

struct MoreHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showAnalysisTools = false
    @State private var showPlanningTools = false
    @State private var showAppSettings = false
    @State private var showDataSync = false
    // AI 相关入口此前埋在「分析与规划」二级页深处（更多 → 分析与规划 → 再往下滚），
    // 三层之后基本找不到。这里提到一级页顶部做成卡片区。
    @State private var showAIAnalysis = false
    @State private var showQuantEngine = false
    @State private var showPortfolioAdvice = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        MoreHubCard(title: "AI 账户分析", subtitle: "大模型解读持仓、风险与待核对项",
                                    icon: "sparkles", tint: store.effectiveAccentColor) {
                            showAIAnalysis = true
                        }
                        HStack(spacing: 10) {
                            MoreHubTile(title: "量化信号", subtitle: "本地扫描\n自选与持仓",
                                        icon: "waveform.path.ecg", tint: Color(red: 0.16, green: 0.72, blue: 0.85)) {
                                showQuantEngine = true
                            }
                            MoreHubTile(title: "账户决策提示", subtitle: "仓位上限\n现金占比",
                                        icon: "lightbulb.fill", tint: Color(red: 1.0, green: 0.62, blue: 0.18)) {
                                showPortfolioAdvice = true
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: { Text("AI 与智能分析") } footer: {
                    Text("投资偏好（画像）与模型接口在「AI 账户分析」页内配置；密钥只存本机钥匙串。")
                        .scaledFont(10)
                }

                Section {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            MoreHubTile(title: "分析工具", subtitle: "风险、信号\n账户体检", icon: "chart.bar.xaxis", tint: .blue) {
                                showAnalysisTools = true
                            }
                            MoreHubTile(title: "计划与复盘", subtitle: "网格、收益\n历史回看", icon: "calendar.badge.clock", tint: .orange) {
                                showPlanningTools = true
                            }
                        }
                        HStack(spacing: 10) {
                            MoreHubTile(title: "应用设置", subtitle: "配色、行情\n成本口径", icon: "gearshape.fill", tint: .gray) {
                                showAppSettings = true
                            }
                            MoreHubTile(title: "数据与同步", subtitle: "备份、NAS\n通知权限", icon: "externaldrive.fill", tint: .purple) {
                                showDataSync = true
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: { Text("工具与设置") }

                Section("账户状态") {
                    LabeledContent("自选", value: "\(store.data.quotes.count) 只")
                    LabeledContent("场内持仓", value: "\(store.data.holdings.filter { $0.kind == .etf }.count) 只")
                    LabeledContent("场外基金", value: "\(store.data.holdings.filter { $0.kind == .fund }.count) 只")
                    Label(store.nasSyncStatus, systemImage: "externaldrive.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("观盘 Pro")
                    Text("本机记录与分析 · 不连接券商下单")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.palette(for: store.resolvedAppearance).surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(isPresented: $showAnalysisTools) { ToolsView(title: "分析工具") }
            .navigationDestination(isPresented: $showPlanningTools) { ToolsView(title: "计划与复盘") }
            .navigationDestination(isPresented: $showAppSettings) { SettingsView(mode: .app) }
            .navigationDestination(isPresented: $showDataSync) { SettingsView(mode: .sync) }
            .sheet(isPresented: $showAIAnalysis) { AIAnalysisView() .themedSheetBackground() }
            .sheet(isPresented: $showQuantEngine) { QuantitativeEngineView() .themedSheetBackground() }
            .sheet(isPresented: $showPortfolioAdvice) { PortfolioAdviceView() .themedSheetBackground() }
        }
    }
}

/// 一级页的横向大卡：图标 + 标题 + 说明，整块可点。
private struct MoreHubCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .scaledFont(20, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(15, weight: .semibold).foregroundStyle(.primary)
                    Text(subtitle).scaledFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 一半宽度的小卡，两个并排。
private struct MoreHubTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(tint)
                Text(title).scaledFont(13, weight: .semibold).foregroundStyle(.primary)
                Text(subtitle).scaledFont(10).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tint.opacity(0.24), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }
}

struct QuoteAlertEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var target = ""
    @State private var direction: QuoteAlert.Direction = .above
    @State private var error = ""

    /// 从持仓/自选行直接呼出时预填代码，省一次选择
    init(initialCode: String? = nil) {
        _code = State(initialValue: initialCode ?? "")
    }
    private var instruments: [AlertInstrument] {
        let values = store.data.quotes.map { AlertInstrument(code: $0.code, name: $0.name) }
            + store.data.holdings.filter { $0.kind == .etf }.map { AlertInstrument(code: $0.code, name: $0.name) }
        return Array(Dictionary(values.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.code < $1.code }
    }
    var body: some View {
        NavigationStack {
            Form {
                if !instruments.isEmpty {
                    Picker("标的", selection: $code) {
                        ForEach(instruments) { item in Text("\(item.name) · \(item.code)").tag(item.code) }
                    }
                } else { TextField("证券/ETF代码", text: $code) }
                Picker("触发方向", selection: $direction) {
                    Text("上穿目标价").tag(QuoteAlert.Direction.above)
                    Text("下穿目标价").tag(QuoteAlert.Direction.below)
                }
                TextField("目标价格", text: $target).keyboardType(.decimalPad)
                Text("沪深交易时段刷新行情并触达目标后发送一次本地通知，随后自动停用。需要允许系统通知；应用关闭、休市或行情接口不可用时不会实时监控。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("价格提醒")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { if code.isEmpty { code = instruments.first?.code ?? "" } }
        }
    }
    private func save() {
        guard let value = Double(target) else { error = "请输入有效目标价。"; return }
        let name = instruments.first { $0.code == code }?.name ?? code
        Task {
            do {
                // Alerts are one-shot. Do not save one that could silently disable
                // itself later when iOS has no permission to show its notification.
                let allowed = try await NativeNotifications.requestPermission()
                guard allowed else {
                    error = "系统通知未授权，提醒没有保存。请在 iPhone「设置 > 通知 > 观盘 Pro」开启通知后重试。"
                    return
                }
                try store.addQuoteAlert(code: code, name: name, target: value, direction: direction)
                dismiss()
            } catch let saveErr { error = saveErr.localizedDescription }
        }
    }
}

private struct AlertInstrument: Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

struct WatchEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var group = ""
    @State private var newGroup = ""
    /// Picker 里「新建分组…」的哨兵值。用哨兵而不是再开一个 Bool，
    /// 是为了让 selection 只有一个数据源，不会出现「选了新建但开关没跟上」。
    private static let newGroupValue = "__new_group__"

    private var resolvedGroup: String {
        guard group == Self.newGroupValue else { return group }
        return newGroup.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("证券/ETF代码", text: $code).keyboardType(.numberPad)
                    .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).suffix(6)) }
                LabeledContent("自动识别名称", value: name.isEmpty ? (code.count == 6 ? "查询中…" : "输入代码后识别") : name)
                Text("名称和行情将按证券代码自动获取，不需要手动填写。")
                    .font(.footnote).foregroundStyle(.secondary)
                Section("分组") {
                    Picker("分组", selection: $group) {
                        Text("未分组").tag("")
                        ForEach(store.watchGroups, id: \.self) { item in Text(item).tag(item) }
                        Text("新建分组…").tag(Self.newGroupValue)
                    }
                    if group == Self.newGroupValue {
                        TextField("新分组名", text: $newGroup)
                    }
                    Text("分组只影响自选列表的显示与排序，不影响行情与持仓。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear).navigationTitle("添加自选").keyboardDoneToolbar()
                .task(id: code) {
                    let requested = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard requested.count == 6 else { name = ""; return }
                    name = "正在识别…"
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    do {
                        if let quote = try await store.lookupETFQuote(code: requested), !Task.isCancelled,
                           code == requested { name = quote.name }
                        else if !Task.isCancelled { name = "" }
                    } catch { if !Task.isCancelled { name = "" } }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            store.addWatch(code: code.trimmingCharacters(in: .whitespaces),
                                           name: name == "正在识别…" ? "" : name.trimmingCharacters(in: .whitespaces),
                                           group: resolvedGroup)
                            Haptics.success()
                            dismiss()
                            store.refreshQuotes()
                        }.disabled(code.count != 6)
                    }
                }
        }
    }
}

struct HoldingsView: View {
    @EnvironmentObject var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    /// 自动更新基金净值时不驱动导航栏按钮；只有用户主动刷新才显示转圈。
    @State private var isManuallyRefreshing = false
    let kind: Holding.Kind
    @State private var showAdd = false
    @State private var editTarget: Holding?
    @State private var tradeTarget: Holding?
    @State private var fundHistoryTarget: Holding?
    @State private var fundReconciliationTarget: Holding?
    @State private var backfillTarget: Holding?
    @State private var dcaTarget: Holding?
    @State private var feePolicyTarget: Holding?
    @State private var feeReconciliationTarget: FundTransaction?
    @State private var marketChartTarget: Holding?
    @State private var showFundCalendar = false
    @State private var showFundQuant = false
    @State private var archivedFundTarget: ArchivedFundItem?
    @State private var deleteArchivedFundCode: String?
    @State private var undoTradeMessage: String?
    @State private var showPortfolioAdvice = false
    @State private var alertTarget: Holding?
    /// 「基金工具」原来直接用 Menu 嵌在行内 —— List 行内嵌 Menu 会抢走横向平移手势，
    /// 导致整行左滑失效（swipeActions 弹不出来）。改成按钮 + confirmationDialog。
    @State private var fundToolTarget: Holding?
    /// 长按菜单删除的确认目标
    @State private var removeTarget: Holding?
    @State private var searchText = ""
    /// 驱动“最新净值已更新”彩虹强调。窗口只到采集当天结束，所以每 60 秒推一次时钟，
    /// 跨过午夜（本地时间）后这一分钟之内就会自动恢复普通卡片。
    @State private var fundFreshnessClock = Date.now
    /// 「最近基金流水」默认收起：10 笔流水加上待核对的估算费能占掉大半屏，
    /// 把持仓卡和基金工具挤到下面。展开状态记在 AppStorage 里，下次打开保持用户选择。
    @AppStorage("guanpan.native.fundRecentTrades.expanded") private var fundRecentTradesExpanded = false
    private var holdings: [Holding] { store.data.holdings.filter { $0.kind == kind } }
    private var title: String { kind == .fund ? "场外基金" : "ETF / 证券持仓" }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isSearching: Bool { !searchQuery.isEmpty }
    /// 搜索时只按名称 / 代码过滤持仓行；其它分区在搜索态下隐藏，避免结果被无关内容淹没
    private var searchedHoldings: [Holding] {
        let base = holdings.filter { $0.quantity > 0 || kind == .fund }
        guard isSearching else { return base }
        let query = searchQuery.lowercased()
        return base.filter { $0.name.lowercased().contains(query) || $0.code.contains(query) }
    }

    private func fundTransactionLabel(_ trade: FundTransaction) -> String {
        switch trade.side {
        case .buy: return trade.isBackfill ? "历史起点补录" : ((trade.isAutomaticDCA ?? false) ? "自动定投 · \(trade.name)" : "申购 · \(trade.name)")
        case .sell: return "赎回 · \(trade.name)\(trade.feeWasEstimated == true ? " · 估算费待核对" : "")"
        case .dividend: return trade.dividendMode == .reinvest ? "红利再投资 · \(trade.name)" : "现金分红 · \(trade.name)"
        }
    }

    private func dcaDescription(_ plan: FundDCAPlan) -> String {
        switch plan.frequency {
        case .daily: return "每个有净值记录的交易日"
        case .weekly:
            let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return "每\(names.indices.contains(plan.weekday) ? names[plan.weekday] : "周一")"
        case .biweekly: return "每两周一次"
        case .monthly: return "每月\(plan.monthDay)日或其后首个有净值日"
        }
    }

    private func legacyDCAStatus(_ value: String) -> String {
        switch value {
        case "booked": return "网页端已补入份额"
        case "waiting-nav": return "等待历史净值"
        case "needs-hold": return "基金不在当前持仓"
        case "error": return "网页端补记失败"
        case "未迁入流水": return "未迁入流水"
        default: return value.isEmpty ? "状态未记录" : value
        }
    }

    /// 年股息只采用人工修正或近 12 个月已记录的分红事件；缺少记录不等于确认不分红。
    private func annualDividendProjection(for holding: Holding) -> (amount: Double, source: ETFDividendProjection.Source)? {
        if ETFDividendProjection.knownNonDividendCodes.contains(holding.code), holding.annualDividendPerShare == nil { return nil }
        if holding.annualDividendPerShare == 0 { return nil }
        // 多语句函数体没有隐式 return，少写 `return` 会报
        // "missing return in instance method expected to return ..."。
        return ETFDividendProjection.projectedAnnualPerShare(for: holding, events: store.data.etfDividendEvents)
    }

    private func annualDividendPerShare(for holding: Holding) -> Double? {
        annualDividendProjection(for: holding)?.amount
    }

    private var etfAnnualDividendIncome: Double {
        holdings.filter { $0.kind == .etf && $0.quantity > 0 }.reduce(0) { total, holding in
            total + holding.quantity * (ETFDividendProjection.recordedAnnualPerShare(for: holding, events: store.data.etfDividendEvents)?.amount ?? 0)
        }
    }

    private var etfProjectedDividendIncome: Double {
        holdings.filter { $0.kind == .etf && $0.quantity > 0 }.reduce(0) { total, holding in
            total + holding.quantity * (annualDividendProjection(for: holding)?.amount ?? 0)
        }
    }

    private var hasETFDividendData: Bool {
        etfAnnualDividendIncome > 0
    }

    private var hasETFProjectedDividendData: Bool {
        etfProjectedDividendIncome > 0
    }

    private func dividendStatus(for holding: Holding) -> String {
        if ETFDividendProjection.knownNonDividendCodes.contains(holding.code) { return "不分红" }
        if annualDividendProjection(for: holding) != nil { return "有试算" }
        if ETFDividendProjection.mergedEvents(store.data.etfDividendEvents).contains(where: {
            $0.code == holding.code && $0.isEstimated != true
        }) { return "历史派息 · 暂无年化规律" }
        if holding.annualDividendPerShare == 0 { return "不分红" }
        return "待核实"
    }

    /// 股息率的口径说明：把「这个数是怎么算出来的」直接写出来。
    ///
    /// 用户报过「港股通红利股息只有 1.9%」。这个数**通常是分母/口径问题而不是算错**：
    /// 分子只认本机记到的分红事件（人工修正 / 已核实记录 / 近三年年度均值 / 复权价差推算），
    /// 本机没记全（月月分红的 ETF 尤其容易只记到几次）就会明显偏低。
    /// 与其让用户猜，不如把次数、合计金额和覆盖入口都写在卡片上。
    private func dividendYieldNote(for holding: Holding) -> String? {
        if let manual = holding.annualDividendPerShare, manual.isFinite, manual > 0 {
            return "股息率 = 你手填的每份年分红 \(manual.num(4)) 元 ÷ 现价，不随本机记录变化。"
        }
        let source = annualDividendProjection(for: holding)?.source
        let cutoff = ETFDividendProjection.yearAgoCutoff()
        let recorded = ETFDividendProjection.mergedEvents(store.data.etfDividendEvents)
            .filter { $0.code == holding.code && $0.date >= cutoff && $0.isEstimated != true }
        let total = recorded.reduce(0) { $0 + $1.amountPerShare }
        let basis: String
        if source == .recorded || source == .projected {
            basis = "近 12 个月已核实派息 \(recorded.count) 次、合计 \(total.num(4)) 元/份"
        } else if source == .historicalAverage {
            basis = "近 12 个月没有已核实派息，按近三年有派息年度的平均值试算"
        } else if source == .inferred {
            basis = "按前复权与不复权收盘价差推算的派息合计（未经公告核实）"
        } else {
            basis = "本机已记录的分红事件合计"
        }
        return "股息率 = \(basis) ÷ 现价。月月分红的品种若本机只记到几次，这个数就会偏低；"
            + "可在「编辑持仓 → 每份年分红修正」直接填年化金额覆盖。"
    }

    /// 网页版年股息区会列出主要贡献标的。这里沿用同一口径并只显示前三只，
    /// 避免资产概览被拉得过长；完整逐笔资料仍在「分红日历」。
    private var etfDividendContributors: [Holding] {
        holdings
            .filter { holding in
                holding.kind == .etf && holding.quantity > 0 && (annualDividendPerShare(for: holding) ?? 0) > 0
            }
            .sorted { left, right in
                left.quantity * (annualDividendPerShare(for: left) ?? 0)
                    > right.quantity * (annualDividendPerShare(for: right) ?? 0)
            }
    }

    /// 每只基金的最新/上一期净值，先按估值日期去重，再一次遍历算好。
    /// 旧备份可能有重复日期；不能依赖数组顺序决定哪个净值参与日收益。
    private var fundNAVPairs: [String: (latest: FundNAVPoint, previous: FundNAVPoint?)] {
        var result: [String: (latest: FundNAVPoint, previous: FundNAVPoint?)] = [:]
        let groups = Dictionary(grouping: store.data.fundNAVHistory.filter {
            $0.nav.isFinite && $0.nav > 0
        }, by: \.code)
        for (code, rows) in groups {
            let byDate = Dictionary(rows.map { ($0.date, $0) }, uniquingKeysWith: { old, new in
                switch (old.fetchedAt, new.fetchedAt) {
                case let (a?, b?): return a >= b ? old : new
                case (_?, nil): return old
                case (nil, _?): return new
                case (nil, nil): return new
                }
            })
            let sorted = byDate.values.sorted { $0.date < $1.date }
            guard let latest = sorted.last else { continue }
            result[code] = (latest, sorted.count > 1 ? sorted[sorted.count - 2] : nil)
        }
        return result
    }

    /// 场外基金当日收益（元 / %）。用页面级预计算的 fundNAVPairs，不再逐行扫全表。
    private func fundDayMetrics(for holding: Holding,
                                using pairs: [String: (latest: FundNAVPoint, previous: FundNAVPoint?)])
        -> (amount: Double, percent: Double)? {
        guard let pair = pairs[holding.code], let previous = pair.previous,
              pair.latest.date == MarketCalendar.isoDay(.now),
              previous.nav > 0, pair.latest.nav.isFinite, previous.nav.isFinite else { return nil }
        return ((pair.latest.nav - previous.nav) * holding.quantity,
                (pair.latest.nav / previous.nav - 1) * 100)
    }

    @ViewBuilder private func holdingMetricChip(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(10, weight: .semibold)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.11)))
    }

    var body: some View {
        listContent
            .sheet(isPresented: $showAdd) { HoldingEditor(kind: kind) .themedSheetBackground() }
            .sheet(item: $editTarget) { HoldingEditor(kind: kind, initial: $0) .themedSheetBackground() }
            .sheet(item: $tradeTarget) { TradeEditor(holding: $0) .themedSheetBackground() }
            .sheet(item: $fundHistoryTarget) { FundNAVHistoryView(fund: $0) .themedSheetBackground() }
            .sheet(item: $fundReconciliationTarget) { FundReconciliationView(fund: $0) .themedSheetBackground() }
            .sheet(item: $backfillTarget) { FundBackfillView(fund: $0) .themedSheetBackground() }
            .sheet(item: $dcaTarget) { FundDCAPlanEditor(holding: $0) .themedSheetBackground() }
            .sheet(item: $feePolicyTarget) { FundFeePolicyEditor(fund: $0) .themedSheetBackground() }
            .sheet(item: $feeReconciliationTarget) { FundFeeReconciliationEditor(transaction: $0) .themedSheetBackground() }
            .fullScreenCover(item: $marketChartTarget) { MarketChartView(holding: $0) .themedSheetBackground() }
            .sheet(item: $alertTarget) { QuoteAlertEditor(initialCode: $0.code) .themedSheetBackground() }
            .sheet(isPresented: $showFundCalendar) { FundIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showFundQuant) { FundQuantView() .themedSheetBackground() }
            .sheet(isPresented: $showPortfolioAdvice) { PortfolioAdviceView() .themedSheetBackground() }
            .sheet(item: $archivedFundTarget) { ArchivedFundHistoryView(item: $0) .themedSheetBackground() }
            .confirmationDialog(fundToolTarget?.name ?? "基金工具", isPresented: Binding(get: { fundToolTarget != nil }, set: { if !$0 { fundToolTarget = nil } }), titleVisibility: .visible) {
                Button("净值走势") { if let t = fundToolTarget { fundHistoryTarget = t }; fundToolTarget = nil }
                Button("赎回费率") { if let t = fundToolTarget { feePolicyTarget = t }; fundToolTarget = nil }
                Button("流水核对") { if let t = fundToolTarget { fundReconciliationTarget = t }; fundToolTarget = nil }
                Button("取消", role: .cancel) { fundToolTarget = nil }
            } message: { Text("这只基金的历史净值、费率与流水核对工具。") }
            .alert("交易流水", isPresented: Binding(get: { undoTradeMessage != nil }, set: { if !$0 { undoTradeMessage = nil } })) {
                Button("好", role: .cancel) { undoTradeMessage = nil }
            } message: { Text(undoTradeMessage ?? "") }
            .confirmationDialog("删除这只基金的历史记录？", isPresented: Binding(get: { deleteArchivedFundCode != nil }, set: { if !$0 { deleteArchivedFundCode = nil } }), titleVisibility: .visible) {
                Button("删除历史流水与净值", role: .destructive) {
                    if let code = deleteArchivedFundCode { store.removeArchivedFundHistory(code: code) }
                    deleteArchivedFundCode = nil
                }
                Button("取消", role: .cancel) { deleteArchivedFundCode = nil }
            } message: {
                Text("此操作会删除该只已移出基金的流水和净值历史，不会删除当前持仓；操作无法直接撤回，请先确认备份。")
            }
            .onAppear {
                if kind == .fund { store.maybeRefreshFundNAVsAfterMarketClose() }
                if kind == .etf { store.refreshETFDividendEstimates() }
            }
    }

    /// 列表主体单独成表达式：与末尾十余个 sheet / alert 修饰符分开做类型检查，
    /// 否则整条 body 表达式树过大，编译报 "unable to type-check in reasonable time"。
    private var listContent: some View {
        NavigationStack {
            List {
                if isSearching {
                    holdingRowList
                } else {
                    moduleSummarySection
                    accountHintSection
                    if holdings.isEmpty {
                        ContentUnavailableView("暂无\(title)", systemImage: "tray", description: Text("点右上角添加持仓。"))
                    }
                    holdingRowList
                    if kind == .fund {
                        fundToolsSection
                    }
                    recentTradesSection
                    if kind == .fund {
                        archivedFundSection
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .searchable(text: $searchText, prompt: "搜索名称或代码")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                // 基金页下拉刷净值，ETF/证券页下拉刷行情，各自对应页面上真正会变的东西
                await manuallyRefreshHoldings()
            }
            .refreshFeedbackOverlay(refreshFeedback)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if kind == .fund {
                        Button {
                            Haptics.push()
                            Task { await manuallyRefreshHoldings() }
                        } label: {
                            RefreshToolbarIcon(isRefreshing: isManuallyRefreshing)
                        }
                            .disabled(isManuallyRefreshing)
                            .accessibilityLabel(isManuallyRefreshing ? "正在更新基金净值" : "更新基金净值")
                    }
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(kind == .fund ? "添加基金持仓" : "添加 ETF / 证券持仓")
                }
            }
            .task {
                while !Task.isCancelled {
                    fundFreshnessClock = .now
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    @MainActor private func manuallyRefreshHoldings() async {
        guard !isManuallyRefreshing else { return }
        isManuallyRefreshing = true
        defer { isManuallyRefreshing = false }
        let deadline = Date().addingTimeInterval(25)
        while (kind == .fund ? store.isRefreshingFunds : store.isRefreshingQuotes) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !(kind == .fund ? store.isRefreshingFunds : store.isRefreshingQuotes) else {
            refreshFeedback.finish(kind == .fund ? "净值请求仍未结束，请稍后重试" : "行情请求仍未结束，请稍后重试", succeeded: false)
            return
        }
        if kind == .fund {
            refreshFeedback.begin("正在更新已公布净值…")
            let ok = await store.refreshFundNAVsAndWait()
            refreshFeedback.finish(store.fundNAVStatus, succeeded: ok)
        } else {
            refreshFeedback.begin("正在刷新持仓行情…")
            let ok = await store.refreshQuotesAndWait()
            refreshFeedback.finish(ok ? "持仓行情已更新" : store.sourceStatus, succeeded: ok)
        }
    }

    /// 本模块（ETF/证券 或 场外基金）自己的汇总：市值 / 浮盈 / 收益率。
    /// 与账户页的「总资产」互不混算——两个模块各看各的，避免把合计当成单模块数字。
    /// 持仓行内的小统计：紧凑但不小于 10pt，一行放三个且保持可读。
    private func holdingStat(_ title: String, _ value: String, _ tone: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).scaledFont(10).foregroundStyle(.secondary)
            Text(value)
                .scaledFont(12, weight: .semibold, design: .rounded)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(tone.map { $0 >= 0 ? Color(red: 0.93, green: 0.30, blue: 0.37)
                                                    : Color(red: 0.07, green: 0.77, blue: 0.55) } ?? Color.primary)
                // 读屏念「当日 上涨 ¥12.34」，把颜色代表的涨跌转成文字
                .accessibilityLabel(tone.map { "\(title) \(spokenDirection($0)) \(value)" } ?? "\(title) \(value)")
        }
    }

    @ViewBuilder private var moduleSummarySection: some View {
        Section(kind == .fund ? "基金资产概览" : "ETF / 证券资产概览") {
            let value = store.marketValue(of: kind)
            let pnlValue = store.pnl(of: kind)
            let count = holdings.filter { $0.quantity > 0 }.count
            // 场内与场外的「当日盈亏」不是一个口径，不能共用 `dayPnL(of:)`：
            // 行情接口只认场内代码，`marketChanges` 里根本没有基金代码，
            // 所以之前场外这一格无论涨跌永远显示 0。场外改按最新净值日两点的净值差算。
            let dayValue = kind == .fund ? store.fundDayPnL : store.intradayPnL
            let hasDayValue = kind == .fund ? store.hasFundDayPnL : store.hasIntradayPnL
            let dayTitle = kind == .fund ? "净值日盈亏" : "今日盈亏"
            // 只有净值日期为今天才计入今天收益；迟到净值回到它自己的估值日，
            // 不因今天才采集而挪入今天，也不重复计入今天。
            let dayDateNote = kind == .fund
                ? (store.hasFundDayPnL
                    ? (store.latestFundNAVDate.map { "净值 \(shortDay($0))" } ?? "无净值")
                    : (store.latestFundNAVDate.map { "净值 \(shortDay($0)) · 今日未取到" } ?? "无净值"))
                : "行情日 \(store.intradayQuoteDate.map { shortDay($0) } ?? "--")"
            // 网页版的资产汇总卡是彩色区块（.sum）；这里按浮盈亏红绿上色，不再是一片灰白
            let cardTone: Color? = pnlValue > 0.005 ? PnLColor.up : pnlValue < -0.005 ? PnLColor.down : nil
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本模块市值").scaledFont(11).foregroundStyle(.secondary)
                        Text(value.cny())
                            .scaledFont(24, weight: .bold, design: .rounded)
                            .minimumScaleFactor(0.7).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("持仓浮盈").scaledFont(11).foregroundStyle(.secondary)
                        Text(pnlValue.cny())
                            .scaledFont(17, weight: .bold, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(pnlValue >= 0 ? Color(red: 0.93, green: 0.30, blue: 0.37)
                                                            : Color(red: 0.07, green: 0.77, blue: 0.55))
                    }
                }
                MetricGrid(columns: 3, cells: [
                    MetricCell(title: "成本收益率", value: store.pnlRate(of: kind).map { $0.pct(2) } ?? "--",
                               toneValue: pnlValue),
                    MetricCell(title: dayTitle, value: hasDayValue ? dayValue.cny() : "--",
                               toneValue: hasDayValue ? dayValue : nil),
                    MetricCell(title: "持仓数", value: "\(count) 只")
                ])
                if kind == .etf {
                    Divider().opacity(0.55)
                    let dividendIncome = etfAnnualDividendIncome
                    let dividendYield = value > 0 && hasETFDividendData ? dividendIncome / value * 100 : nil
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("近12个月已核实派息").scaledFont(10).foregroundStyle(.secondary)
                            Text(hasETFDividendData ? dividendIncome.cny() : (holdings.filter { $0.kind == .etf && $0.quantity > 0 }.allSatisfy { dividendStatus(for: $0) == "不分红" } ? "不分红" : "暂无已核实派息"))
                                .scaledFont(17, weight: .bold, design: .rounded)
                                .foregroundStyle(dividendIncome > 0 ? Color(red: 0.07, green: 0.68, blue: 0.48) : .secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("组合股息率").scaledFont(10).foregroundStyle(.secondary)
                            Text(dividendYield?.pct(2) ?? "待核实")
                                .scaledFont(15, weight: .bold, design: .rounded)
                                .foregroundStyle(dividendYield == nil ? Color.secondary : Color.orange)
                        }
                    }
                    let projectedIncome = etfProjectedDividendIncome
                    let projectedYield = value > 0 && hasETFProjectedDividendData ? projectedIncome / value * 100 : nil
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("预计未来12个月（按近12个月派息试算）").scaledFont(10).foregroundStyle(.secondary)
                            Text(hasETFProjectedDividendData ? projectedIncome.cny() : (holdings.filter { $0.kind == .etf && $0.quantity > 0 }.allSatisfy { dividendStatus(for: $0) == "不分红" } ? "不分红" : "待核实"))
                                .scaledFont(15, weight: .semibold, design: .rounded)
                                .foregroundStyle(projectedIncome > 0 ? Color(red: 0.07, green: 0.68, blue: 0.48) : .secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("预计组合股息率").scaledFont(10).foregroundStyle(.secondary)
                            Text(projectedYield?.pct(2) ?? "待核实")
                                .scaledFont(14, weight: .semibold, design: .rounded)
                                .foregroundStyle(projectedYield == nil ? Color.secondary : Color.orange)
                        }
                    }
                    if !etfDividendContributors.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(Array(etfDividendContributors.prefix(3))) { holding in
                                let perShare = annualDividendPerShare(for: holding) ?? 0
                                let contribution = holding.quantity * perShare
                                HStack(spacing: 8) {
                                    Text(holding.name).lineLimit(1)
                                    Text("\((perShare / max(holding.current, 0.000_001) * 100).pct(2)) · 仓位 \((store.allocationActualPercent(for: holding)).pct(0))")
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(contribution.cny())
                                        .fontWeight(.semibold).monospacedDigit()
                                        .foregroundStyle(Color(red: 0.07, green: 0.68, blue: 0.48))
                                }
                                .scaledFont(10)
                            }
                        }
                    }
                    Text("近12个月一栏只计已核实的实际派息；预计值按历史派息节奏试算，不代表承诺。无记录标为“待核实”；明确不分红的标的会单独标注，不按指数或名称猜测。")
                        .scaledFont(9).foregroundStyle(.secondary)
                }
                Text(kind == .fund
                     ? "只统计本页场外基金；ETF / 证券不计入。净值日盈亏 = 最新两个公布净值之差（\(dayDateNote)）。"
                     : "只统计本页 ETF / 证券；场外基金不计入。今日盈亏按最近一次行情反推昨收（\(dayDateNote)）。")
                    .scaledFont(10).foregroundStyle(.secondary)

                // 本模块自己的情绪量尺：口径与首页「市场情绪」一致（等权平均涨跌幅），
                // 但范围收窄到本页持仓 —— 两个模块的资产/盈亏本来就分开算，情绪也该各看各的。
                if let mood = store.marketMood(of: kind) {
                    let strength = mood.average * 100
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("本模块今日涨跌").scaledFont(10).foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text("\(strength.directionMark()) \(strength.pct(2))")
                                .scaledFont(11, weight: .semibold).monospacedDigit()
                                .foregroundStyle(PnLColor.of(strength))
                            Text(MoodScale.label(strength))
                                .scaledFont(10, weight: .semibold)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(MoodScale.badgeBackground(strength)))
                                .foregroundStyle(MoodScale.foreground(strength))
                        }
                        MoodGauge(average: strength)
                        Text("按本模块 \(mood.count) 只标的等权计算，只反映最近一次成功获取的报价。")
                            .scaledFont(9).foregroundStyle(.secondary)
                    }
                }
            }
            .cardSurface(tone: cardTone)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var accountHintSection: some View {
        if kind == .etf {
            Section("账户提示") {
                Button {
                    showPortfolioAdvice = true
                } label: {
                    Label("查看账户决策提示", systemImage: "lightbulb")
                }
                Text("汇总仓位上限、现金占比和基金定期报告重叠提示；只作记录核对，不预测涨跌或自动交易。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var holdingRowList: some View {
        let rows = searchedHoldings
        // 净值对与摊薄已实现盈亏都只算一次，供所有行复用（见 fundNAVPairs / dilutedRealizedSums）。
        let navPairs = fundNAVPairs
        let dilutedRealized = store.dilutedRealizedSums()
        // 本页全部场外基金里最新的一个净值日。用来标出「哪只还没公布新净值」——
        // 彩虹框只跟「这只基金自己有没有新净值」有关，落后于组内最新净值日的基金
        // 不会、也不应该亮，这里把原因直接写在卡片上，不用用户猜。
        let latestNAVDate = navPairs.values.map(\.latest.date).max()
        if isSearching && rows.isEmpty {
            Text("没有匹配「\(searchQuery)」的持仓")
                .foregroundStyle(.secondary)
        }
        ForEach(rows) { h in
            holdingRow(h, navPairs: navPairs, latestNAVDate: latestNAVDate, dilutedRealized: dilutedRealized)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private func holdingRow(_ h: Holding,
                                         navPairs: [String: (latest: FundNAVPoint, previous: FundNAVPoint?)],
                                         latestNAVDate: String?,
                                         dilutedRealized: [String: Double]) -> some View {
        // 列布局对齐养基宝：当日涨幅% / 当日收益 / 持有收益（元 + 百分比），
        // 市值在名称行右侧，占总资产挪到底部信息行 —— 4 列太挤，3 列是它的可读上限。
        // 缺当日行情时显示 --，不把「没数据」画成 0。
        let fundDay = kind == .fund ? fundDayMetrics(for: h, using: navPairs) : nil
        let dayValue = fundDay?.amount ?? store.dayPnL(of: h)
        let hasDay = kind == .fund ? fundDay != nil : store.marketChanges[h.code] != nil
        let dayPercent: Double? = kind == .fund ? fundDay?.percent : store.marketChanges[h.code].map { $0 * 100 }
        // 摊薄口径的已实现盈亏用页面级预计算值（原来每次调用都全量过滤流水）。
        let realizedSum = (dilutedRealized["\(h.code)|nil"] ?? 0) + (dilutedRealized["\(h.code)|\(h.kind.rawValue)"] ?? 0)
        let unitCost = store.displayedCost(for: h, dilutedRealizedSum: realizedSum)
        let costBasis = h.quantity * unitCost
        let holdingPnL = h.quantity * (h.current - unitCost)
        let rate = costBasis > 0 ? holdingPnL / costBasis * 100 : nil
        let annualProjection = kind == .etf ? annualDividendProjection(for: h) : nil
        let annualDividend = annualProjection?.amount
        let dividendYield = annualDividend.flatMap { h.current > 0 ? $0 / h.current * 100 : nil }
        let premium = kind == .etf ? store.marketPremiums[h.code] : nil
        let highlightFreshNAV = shouldHighlightFreshFundNAV(h, now: fundFreshnessClock)
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(h.name).font(.headline).lineLimit(1); Spacer(); Text((h.marketValue).cny()).font(.headline) }
            HStack(spacing: 9) {
                holdingStat("当日涨幅", dayPercent.map { "\($0.directionMark()) \($0.pct(2))" } ?? "--", dayPercent)
                holdingStat("当日收益", hasDay ? "\(dayValue.directionMark()) \(dayValue.cny())" : "--", hasDay ? dayValue : nil)
                holdingStat("持有收益", "\(holdingPnL.directionMark()) \(holdingPnL.cny())" + (rate.map { " · \($0.pct(2))" } ?? ""), holdingPnL)
                Spacer(minLength: 0)
            }
            Text("\(h.code) · \((h.quantity).compactNum(4)) 份 · 成本 \((unitCost).num((kind == .fund ? 4 : 3))) · 现价 \((h.current).num((kind == .fund ? 4 : 3))) · 仓位 \((store.allocationActualPercent(for: h)).pct(1))")
                .font(.caption).foregroundStyle(.secondary)
            if kind == .etf {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 7)], alignment: .leading, spacing: 6) {
                    if let premium {
                        holdingMetricChip("溢价 \(premium.pct(2))", color: abs(premium) >= 1 ? .orange : .purple)
                    }
                    if let dividendYield {
                        holdingMetricChip("股息 \(dividendYield.pct(2))", color: Color(red: 0.07, green: 0.68, blue: 0.48))
                    } else {
                        holdingMetricChip(dividendStatus(for: h), color: dividendStatus(for: h) == "不分红" ? .secondary : .orange)
                    }
                    if hasDay { holdingMetricChip("今日 \(dayValue.cny())", color: PnLColor.of(dayValue)) }
                }
                // 把股息率的口径写在卡片上：偏低的常见原因是「月月分红的品种本机只记到几次」，
                // 而不是算错。用户能据此自己判断要不要去「编辑持仓」覆盖。
                if dividendYield != nil, let note = dividendYieldNote(for: h) {
                    Text(note)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if kind == .fund, let pair = navPairs[h.code] {
                let latest = pair.latest
                if let previous = pair.previous {
                    let change = (latest.nav - previous.nav) * h.quantity
                    Text("\(latest.date) 近一期净值变化 · 按当前份额折算 \((change).cny())")
                        .font(.caption).foregroundStyle(change >= 0 ? .red : .green)
                } else {
                    Text("最新净值日期：\(latest.date)").font(.caption).foregroundStyle(.secondary)
                }
                // 没亮彩虹的常见原因：这只基金的最新净值日还落后于本组其它基金
                // （QDII 里美股、全球配置的公布节奏不同，T+1 / T+2 都可能）。
                if let newest = latestNAVDate, latest.date < newest {
                    Text("净值日 \(shortDay(latest.date)) · 本组已更新到 \(shortDay(newest))，这只的新净值还没公布；公布当晚卡片才会亮起")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 小屏/大字号下将操作按钮自动换行，避免“基金工具 / 定投 / 编辑”等入口被挤出屏幕。
            HStack(spacing: 10) {
                holdingActionButton("买入 / 卖出", icon: "arrow.left.arrow.right") { tradeTarget = h }
                if kind == .fund { holdingActionButton("净值", icon: "chart.line.uptrend.xyaxis") { fundHistoryTarget = h } }
                else { holdingActionButton("日 K", icon: "chart.xyaxis.line") { marketChartTarget = h } }
            }
        }
        .padding(12)
        .cardPanelBackground(cornerRadius: 16,
            fallback: Color(uiColor: .secondarySystemBackground).opacity(0.72),
            tone: holdingPnL > 0.005 ? PnLColor.up : holdingPnL < -0.005 ? PnLColor.down : nil)
        .overlay {
            if highlightFreshNAV {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(fundFreshNAVGradient, lineWidth: 2.2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if highlightFreshNAV {
                Capsule()
                    .fill(fundFreshNAVGradient)
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // 左滑只露出工具，禁止全滑直删：持仓是高价值数据，手指多划一点不该直接删除。
        // 后面依次是编辑 / 交易 / 图表或净值 / 提醒或定投。
        // 注意这里不能用 .buttonStyle(.plain)，会吃掉横向滑动手势（之前踩过）。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive) { removeTarget = h }
            Button("编辑") { Haptics.tap(); editTarget = h }.tint(.blue)
            Button("交易") { Haptics.tap(); tradeTarget = h }.tint(.orange)
            if kind == .fund {
                Button("工具") { fundToolTarget = h }.tint(.indigo)
                Button("定投") { dcaTarget = h }.tint(.teal)
            } else {
                Button("日K") { marketChartTarget = h }.tint(.indigo)
                Button("提醒") { alertTarget = h }.tint(.teal)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("加自选") {
                Haptics.tap()
                if !store.data.quotes.contains(where: { $0.code == h.code }) {
                    store.addWatch(code: h.code, name: h.name)
                }
            }.tint(.mint)
        }
        // 长按兜底：万一设备上 swipeActions 仍被系统手势挡住，也能走到删除 / 编辑。
        .contextMenu {
            Button { editTarget = h } label: { Label("编辑持仓", systemImage: "pencil") }
            Button { tradeTarget = h } label: { Label("买入 / 卖出", systemImage: "arrow.left.arrow.right") }
            if kind == .fund {
                Button { fundHistoryTarget = h } label: { Label("历史净值", systemImage: "chart.line.uptrend.xyaxis") }
                Button { fundToolTarget = h } label: { Label("基金工具", systemImage: "wrench.and.screwdriver") }
                Button { dcaTarget = h } label: { Label("定投", systemImage: "calendar.badge.plus") }
            } else { Button { marketChartTarget = h } label: { Label("日 K 与指标", systemImage: "chart.xyaxis.line") } }
            Button(role: .destructive) {
                Haptics.heavy()
                removeTarget = h
            } label: { Label("删除持仓", systemImage: "trash") }
        }
        .confirmationDialog("删除「\(h.name)」？", isPresented: Binding(get: { removeTarget?.id == h.id }, set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("删除持仓", role: .destructive) { store.removeHolding(h); removeTarget = nil }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: { Text("持仓会被移除，相关交易流水保留。删除后可用设置里的撤销操作找回最近一次。") }
    }
    private func holdingActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34) }
            .buttonStyle(.bordered).tint(store.effectiveAccentColor)
    }

    /// 从「拿到这份最新净值」起保持彩虹强调，**只保留到当天结束**。
    /// 因而周五晚更新只亮周五当晚，周六周日已是普通卡片；下一个交易日晚上公布新净值时再亮。
    ///
    /// **锚点是采集时间而不是净值日期**：美股 / QDII 基金净值日晚一个交易日发布
    /// （美股周六日、节假日休盘但净值照常公布），周一晚取到周五美股收盘的净值，
    /// 它同样是「刚刚更新」，卡片框要和 A 股基金一样亮起 —— 只看净值日期会因
    /// 「周五 ≠ 周一」而漏掉。
    ///
    /// 旧实现把窗口拉到「之后首个交易日 09:30」，于是周五晚更新的基金整个周末都在发彩虹，
    /// 用户反馈「第二天都休市了怎么还是彩虹框」—— 彩虹是「今晚净值刚更新」的即时提示，
    /// 不是「本机存着这份净值」的状态标记，所以窗口收回到采集当天。
    private func shouldHighlightFreshFundNAV(_ holding: Holding, now: Date) -> Bool {
        guard holding.kind == .fund,
              let latest = store.data.fundNAVHistory
                .filter({ $0.code == holding.code })
                .max(by: { $0.date < $1.date }) else { return false }
        let today = MarketCalendar.isoDay(now)
        if let fetchedAt = latest.fetchedAt {
            // 采集时刻必须落在今天：昨天的净值即使本机还留着，也不再算「刚刚更新」。
            return now >= fetchedAt && MarketCalendar.isoDay(fetchedAt) == today
        }
        // 旧存档 / 导入数据没有采集时刻：退化为「净值日本身就是今天」
        // （A 股基金当晚公布的就是当天净值），不拿昨天的净值日冒充今天更新。
        return latest.date == today
    }

    private var fundFreshNAVGradient: LinearGradient {
        LinearGradient(colors: [
            Color(red: 0.98, green: 0.30, blue: 0.42),
            Color(red: 1.00, green: 0.63, blue: 0.18),
            Color(red: 0.20, green: 0.76, blue: 0.48),
            Color(red: 0.20, green: 0.62, blue: 0.98),
            Color(red: 0.62, green: 0.40, blue: 0.96)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder private var fundToolsSection: some View {
        Section("定投与分析") {
            Button("基金量化体检") { showFundQuant = true }
            Button("基金日收益日历") { showFundCalendar = true }
            Text(store.fundNAVStatus).font(.footnote).foregroundStyle(.secondary)
            Text(store.fundDCAStatus).font(.footnote).foregroundStyle(.secondary)
            Text("净值可用页面右上角的刷新按钮更新，也可直接下拉刷新；本页只展示已公布净值。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if !store.data.legacyDCAEvents.isEmpty {
            Section("旧版定投档案") {
                ForEach(store.data.legacyDCAEvents.sorted { $0.dueDate > $1.dueDate }) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(event.name) · \(event.code)")
                        Text("计划日 \(event.dueDate) · \((event.amount).cny()) · \(legacyDCAStatus(event.status))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var recentTradesSection: some View {
        if kind == .fund {
            fundTradesSection
        } else {
            ledgerTradesSection
        }
    }

    /// 最近基金流水的实际展示集合：最近 10 笔 + 所有「估算费待核对」的赎回
    /// （后者不受 10 笔上限约束，否则待核对的条目会被挤出首屏）。
    private var fundRecentTradeEntries: [FundTransaction] {
        let codes = Set(holdings.map(\.code))
        let allEntries = store.data.fundTransactions.filter { codes.contains($0.code) }
            .sorted { $0.requestDate > $1.requestDate }
        let recentEntries = Array(allEntries.prefix(10))
        let recentIDs = Set(recentEntries.map(\.id))
        let pendingFeeChecks = allEntries.filter { $0.side == .sell && $0.feeWasEstimated == true && !recentIDs.contains($0.id) }
        return pendingFeeChecks + recentEntries
    }

    @ViewBuilder private var fundTradesSection: some View {
        let entries = fundRecentTradeEntries
        Section {
            DisclosureGroup(isExpanded: $fundRecentTradesExpanded) {
                if entries.isEmpty { Text("暂无基金流水").foregroundStyle(.secondary) }
                ForEach(entries) { trade in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(fundTransactionLabel(trade))
                            Text("\(trade.effectiveDate) · \((trade.quantity).compactNum(4)) 份\(trade.status == .pending ? " · 待确认" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trade.side == .sell && trade.feeWasEstimated == true {
                            Button("核对费用") { feeReconciliationTarget = trade }
                                .font(.caption)
                        }
                        Text((trade.amount).cny())
                    }.contextMenu {
                        if trade.side == .sell && trade.feeWasEstimated == true {
                            Button("核对实际赎回费", systemImage: "checkmark.seal") { feeReconciliationTarget = trade }
                        }
                        if store.isLatestLedgerFundTransaction(trade) {
                            Button("撤销最近一笔交易", systemImage: "arrow.uturn.backward", role: .destructive) {
                                do { try store.undoLatestTrade(); undoTradeMessage = "最近一笔交易已撤销，持仓和联动现金已回滚。" }
                                catch { undoTradeMessage = error.localizedDescription }
                            }
                        }
                    }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if store.isLatestLedgerFundTransaction(trade) {
                            Button("撤销", role: .destructive) {
                                do { try store.undoLatestTrade(); undoTradeMessage = "最近一笔交易已撤销，持仓和联动现金已回滚。" }
                                catch { undoTradeMessage = error.localizedDescription }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Label("最近基金流水", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text(entries.isEmpty ? "暂无" : "\(entries.count) 笔")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var ledgerTradesSection: some View {
        Section("最近交易流水") {
            let entries = store.data.ledger.filter { e in
                holdings.contains(where: { $0.code == e.code && (e.kind == nil || e.kind == $0.kind) })
            }.suffix(10).reversed()
            if entries.isEmpty { Text("暂无交易流水").foregroundStyle(.secondary) }
            ForEach(Array(entries)) { e in
                // 名称回填：ledger 记录若没存名称，依次从在场持仓 / 已归档基金流水中反查，
                // 避免出现「买入 ¥556.00」这种只有金额没有标的的行。
                let resolvedName: String = {
                    if !e.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return e.name }
                    if let held = store.data.holdings.first(where: { $0.code == e.code && $0.kind == e.kind }) { return held.name }
                    if let held = store.data.holdings.first(where: { $0.code == e.code }), !held.name.isEmpty { return held.name }
                    if let tx = store.data.fundTransactions.first(where: { $0.code == e.code && !$0.name.isEmpty }) { return tx.name }
                    return e.code
                }()
                HStack {
                    Text(resolvedName); Spacer()
                    Text(e.side == .buy ? "买入" : "卖出")
                    Text((e.gross).cny())
                }.font(.caption)
                    .contextMenu {
                        if store.data.ledger.last?.id == e.id {
                            Button("撤销最近一笔交易", systemImage: "arrow.uturn.backward", role: .destructive) {
                                do { try store.undoLatestTrade(); undoTradeMessage = "最近一笔交易已撤销，持仓和联动现金已回滚。" }
                                catch { undoTradeMessage = error.localizedDescription }
                            }
                        }
                    }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if store.data.ledger.last?.id == e.id {
                            Button("撤销", role: .destructive) {
                                do { try store.undoLatestTrade(); undoTradeMessage = "最近一笔交易已撤销，持仓和联动现金已回滚。" }
                                catch { undoTradeMessage = error.localizedDescription }
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder private var archivedFundSection: some View {
        Section("已移出持仓 · 左滑可删除历史") {
            let activeCodes = Set(holdings.map(\.code))
            let archivedCodes = Set(store.data.fundTransactions.map(\.code)).subtracting(activeCodes).sorted()
            if archivedCodes.isEmpty { Text("暂无已移出持仓的基金历史").foregroundStyle(.secondary) }
            ForEach(archivedCodes, id: \.self) { code in
                let trades = store.data.fundTransactions.filter { $0.code == code }
                let name = trades.first(where: { !$0.name.isEmpty })?.name ?? code
                let realized = store.data.ledger.filter { $0.code == code && $0.kind == .fund }.reduce(0) { $0 + $1.realizedPnL }
                    + trades.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
                // 之前这一行是 Button + .buttonStyle(.plain)：按钮会吃掉横向滑动手势，
                // 导致左滑不弹出删除按钮。改成普通行 + onTapGesture，swipeActions 才能生效。
                HStack {
                    VStack(alignment: .leading) { Text(name); Text("\(trades.count) 笔流水 · 历史保留").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text((realized).cny())
                }
                .contentShape(Rectangle())
                .onTapGesture { archivedFundTarget = ArchivedFundItem(code: code, name: name) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除历史", role: .destructive) { deleteArchivedFundCode = code }
                }
            }
        }
    }
}

struct ArchivedFundItem: Identifiable {
    var id: String { code }
    var code: String
    var name: String
}

struct TradeCSVImportView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var drafts: [TradeImportDraft] = []
    @State private var message = ""
    @State private var showImporter = false
    @State private var isImporting = false
    private var validSelected: Int { drafts.filter { $0.selected && $0.isValid }.count }
    private var invalidCount: Int { drafts.filter { !$0.isValid }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择数据") {
                    Button("从文件选择 CSV / 表格") { showImporter = true }
                    TextEditor(text: $text).frame(minHeight: 110)
                    Button("识别并预览") { drafts = TradeCSVParser.parse(text); message = "识别到 \(drafts.count) 行，其中 \(drafts.filter(\.isValid).count) 行可导入。" }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("需要列名：日期、代码、买卖方向、价格、数量；手续费可选。支持逗号 CSV 和制表符表格。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !drafts.isEmpty {
                    Section("预览 · 可导入 \(validSelected) 行 · 未识别 \(invalidCount) 行") {
                        ForEach($drafts) { $draft in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(isOn: $draft.selected) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("第 \(draft.rowNumber) 行 · \(draft.name) · \(draft.code)")
                                        if let date = draft.date {
                                            Text("\(date.formatted(date: .numeric, time: .omitted)) · \(draft.side == .buy ? "买入" : "卖出") · \((draft.quantity).compactNum(4)) × \((draft.price).num(4)) · 费 \((draft.fee).num(2))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }.disabled(!draft.isValid)
                                if let error = draft.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            }.padding(.vertical, 3)
                        }
                        Text("导入后只写历史流水，不变更当前份额和参考现金。卖出盈亏按完整买入历史的加权成本计算；若记录缺少更早买入、卖出超出累计买入，会拒绝整批导入。相同日期、代码、方向、数量和价格的已有流水会跳过。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { importSelected() } label: {
                        Label(isImporting ? "正在导入…" : "确认导入所选 \(validSelected) 行", systemImage: "square.and.arrow.down")
                    }.disabled(validSelected == 0 || isImporting)
                }
                if !message.isEmpty { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("导入成交历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    guard let content = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .unicode) else {
                        message = "文件编码无法识别，请另存为 UTF-8 CSV。"; return
                    }
                    text = content; drafts = TradeCSVParser.parse(content)
                    message = "已读取并识别 \(drafts.count) 行，请先核对预览。"
                } catch { message = "读取失败：\(error.localizedDescription)" }
            }
        }
    }

    private func importSelected() {
        isImporting = true
        defer { isImporting = false }
        do {
            let count = try store.importTradeLedger(drafts)
            message = count == 0 ? "所选流水均已存在，没有重复写入。" : "已导入 \(count) 笔历史成交流水；当前持仓和现金未改动。"
            drafts.removeAll()
        } catch { message = error.localizedDescription }
    }
}

struct TradeLedgerManagementView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var pending: LedgerEntry?
    @State private var showConfirm = false
    @State private var message = ""
    @State private var searchText = ""

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var allRows: [LedgerEntry] { store.data.ledger.sorted { $0.date > $1.date } }
    private var rows: [LedgerEntry] {
        guard !searchQuery.isEmpty else { return allRows }
        let query = searchQuery.lowercased()
        return allRows.filter { $0.name.lowercased().contains(query) || $0.code.contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("全部流水 · \(rows.count) 笔") {
                    if rows.isEmpty {
                        Text(searchQuery.isEmpty ? "暂无交易流水" : "没有匹配「\(searchQuery)」的流水")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(entry.name) · \(entry.side == .buy ? "买入" : "卖出")").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text((entry.gross).cny())
                            }
                            Text("\(entry.date.formatted(date: .numeric, time: .shortened)) · \((entry.quantity).compactNum(4)) × \((entry.price).num(4)) · 手续费 \((entry.fee).num(2))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.affectsHoldings == false ? "导入的历史流水，不影响当前持仓和现金" : "\(entry.kind == .fund ? "场外基金" : "当前账本交易") · \(entry.linkedCash ? "联动现金" : "未联动现金")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if entry.affectsHoldings == false || (entry.kind ?? .etf) == .etf {
                                Button("删除并重算", role: .destructive) { pending = entry; showConfirm = true }
                            } else if store.data.ledger.last?.id == entry.id {
                                Button("撤销", role: .destructive) { pending = entry; showConfirm = true }
                            }
                        }
                    }
                }
                Section {
                    Text("删除 ETF 账本交易会按该标的剩余流水重算份额和成本，并回滚该笔联动现金。导入的历史流水只删除记录，不改当前余额。场外基金旧交易只允许撤销最近一笔，避免破坏后续申赎、分红或定投批次。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Section { Text(message).font(.footnote).foregroundStyle(.orange) } }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .searchable(text: $searchText, prompt: "搜索名称或代码")
            .navigationTitle("交易流水")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("确认删除这笔流水？相关份额、成本和联动现金会按流水重算。", isPresented: $showConfirm, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    guard let entry = pending else { return }
                    Haptics.heavy()
                    do {
                        if entry.affectsHoldings == false || (entry.kind ?? .etf) == .etf {
                            try store.deleteLedgerEntry(entry.id)
                        } else {
                            try store.undoLatestTrade()
                        }
                        message = "流水已更新，持仓与现金已按可核实记录调整。"
                    } catch { message = error.localizedDescription }
                    pending = nil
                }
                Button("取消", role: .cancel) { pending = nil }
            }
        }
    }
}

struct ArchivedFundHistoryView: View {
    @EnvironmentObject var store: PortfolioStore
    let item: ArchivedFundItem

    private var transactions: [FundTransaction] {
        store.data.fundTransactions.filter { $0.code == item.code }.sorted { $0.effectiveDate > $1.effectiveDate }
    }
    private var points: [FundNAVPoint] {
        store.data.fundNAVHistory.filter { $0.code == item.code }.sorted { $0.date < $1.date }
    }
    private var realized: Double {
        store.data.ledger.filter { $0.code == item.code && $0.kind == .fund }.reduce(0) { $0 + $1.realizedPnL }
            + transactions.filter { $0.side == .dividend && $0.status == .confirmed }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("收益保留") {
                    LabeledContent("已实现盈亏", value: (realized).cny())
                    Text("移出持仓只隐藏当前持仓，不删除流水和净值历史。基金收益日历仍可使用这些记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if points.count > 1 {
                    Section("已公布净值走势") {
                        Chart(Array(points.suffix(300))) { point in
                            LineMark(x: .value("日期", point.date), y: .value("净值", point.nav))
                        }.frame(height: 210)
                    }
                }
                Section("基金流水") {
                    if transactions.isEmpty { Text("暂无流水").foregroundStyle(.secondary) }
                    ForEach(transactions) { trade in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(transactionTitle(trade)).font(.headline)
                                Spacer(); Text(trade.status == .pending ? "待确认" : "已确认")
                                    .foregroundStyle(trade.status == .pending ? Color.orange : Color.secondary)
                            }
                            Text("生效日 \(trade.effectiveDate) · \((trade.quantity).compactNum(4)) 份 · 净值 \((trade.nav).num(4))")
                                .font(.caption).foregroundStyle(.secondary)
                            if trade.fee > 0 { Text("费用 \((trade.fee).cny())").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func transactionTitle(_ trade: FundTransaction) -> String {
        switch trade.side {
        case .buy: return trade.isBackfill ? "历史起点补录" : "申购"
        case .sell: return "赎回"
        case .dividend: return trade.dividendMode == .reinvest ? "红利再投资" : "现金分红"
        }
    }
}

struct FundBackfillView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let fund: Holding
    @State private var date = Date.now
    @State private var quantity = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("历史持有起始日", selection: $date, in: ...Date.now, displayedComponents: .date)
                TextField("当时总份额", text: $quantity).keyboardType(.decimalPad)
                Text("按现有份额和已记赎回流水，系统估算的起始份额为 \((store.inferredBackfillShares(for: fund)).compactNum(4))。补录只建立收益日历的份额基准，不改当前持仓、不新增交易或现金。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("补录基金历史起点")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                if quantity.isEmpty { quantity = String(store.inferredBackfillShares(for: fund)) }
            }
        }
    }
    private func save() {
        guard let value = Double(quantity), value.isFinite else { message = "请填写有效份额"; return }
        do { try store.recordFundBackfill(code: fund.code, date: date, quantity: value); dismiss() }
        catch { message = error.localizedDescription }
    }
}

struct FundDCAPlanEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var amount = "100"
    @State private var feeRatePercent = "0.15"
    @State private var frequency: FundDCAPlan.Frequency = .daily
    @State private var weekday = 2
    @State private var monthDay = 1
    @State private var error = ""
    /// 该基金当前已有的计划（优先生效中）：存在时本页变为「修改」而不是「新增」。
    /// 之前同一基金再存一次会抛通用错误「请检查份额、价格、费用和标的」，
    /// 用户会误以为是 10 元 / 0 费率填错了，实际只是重复计划被拒。
    @State private var existingPlan: FundDCAPlan?
    @State private var didPrefill = false

    private var isEditing: Bool { existingPlan != nil }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("基金", value: "\(holding.name) · \(holding.code)")
                if let plan = existingPlan {
                    LabeledContent("当前计划", value: "每期 \(plan.amount.cny()) · 已记 \(plan.processedDates.count) 期 · 开始于 \(plan.startDate)\(plan.enabled ? "" : "（已暂停）")")
                    Text("保存将直接修改这个计划：已记期次保留、不重算，只影响后续扣款日。没有最小金额限制，10 元、0 费率都合法。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("每期计划金额（元）", text: $amount).keyboardType(.decimalPad)
                TextField("申购费率（%）", text: $feeRatePercent).keyboardType(.decimalPad)
                Picker("频率", selection: $frequency) {
                    Text("每个净值交易日").tag(FundDCAPlan.Frequency.daily)
                    Text("每周指定交易日").tag(FundDCAPlan.Frequency.weekly)
                    Text("每两周一次").tag(FundDCAPlan.Frequency.biweekly)
                    Text("每月指定日期").tag(FundDCAPlan.Frequency.monthly)
                }
                if frequency == .weekly {
                    Picker("星期", selection: $weekday) {
                        Text("周一").tag(2); Text("周二").tag(3); Text("周三").tag(4)
                        Text("周四").tag(5); Text("周五").tag(6)
                    }
                }
                if frequency == .monthly {
                    Stepper("每月第 \(monthDay) 日", value: $monthDay, in: 1...28)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("这是本机定投计划记账，不连接券商、不下单，也不改变参考现金。份额按（计划金额 − 申购费）÷ 对应日已公布净值计算，计划金额计入基金成本。默认申购费率 0.15%，请按基金实际费率修改。每周/每月休市时顺延到同周/当月首个可用净值日；没有对应净值时不猜价、不补成交。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle(isEditing ? "修改自动定投" : "设置自动定投")
            .keyboardDoneToolbar()
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                // 打开页面时若该基金已有计划，直接装入它的参数进入修改模式，
                // 不再走「新增 → 撞重复计划 → 报通用错误」的死路。
                if let plan = store.data.fundDCAPlans.first(where: { $0.code == holding.code && $0.enabled })
                    ?? store.data.fundDCAPlans.first(where: { $0.code == holding.code }) {
                    existingPlan = plan
                    amount = plan.amount == plan.amount.rounded() ? String(format: "%.0f", plan.amount) : String(plan.amount)
                    feeRatePercent = String(format: "%g", (plan.feeRate ?? 0.0015) * 100)
                    frequency = plan.frequency
                    weekday = plan.weekday
                    monthDay = plan.monthDay
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存修改" : "启用") {
                        guard let value = Double(amount), value.isFinite, value > 0,
                              let rate = Double(feeRatePercent), rate.isFinite, (0...5).contains(rate) else {
                            error = "请输入有效金额和 0～5% 的申购费率"; return
                        }
                        do {
                            if let plan = existingPlan {
                                try store.updateDCAPlan(id: plan.id, amount: value, feeRatePercent: rate,
                                    frequency: frequency, weekday: weekday, monthDay: monthDay)
                            } else {
                                try store.addDCAPlan(code: holding.code, name: holding.name, amount: value, feeRatePercent: rate,
                                    frequency: frequency, weekday: weekday, monthDay: monthDay)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

private struct FeeBandDraft: Identifiable {
    var id = UUID()
    var days: String
    var rate: String
}

struct FundFeePolicyEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let fund: Holding
    @State private var bands = [0, 7, 30, 365, 730].map { FeeBandDraft(days: String($0), rate: "") }
    @State private var sellMode: FundSellMode = .fifo
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("按基金合同配置赎回费") {
                    Picker("赎回批次策略", selection: $sellMode) {
                        ForEach(FundSellMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Text("低费率策略会优先使用当前持有天数对应费率较低的批次；同费率时先使用较早批次。策略只用于估费和本地记录，实际扣费与销售平台批次以平台确认为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach($bands) { $band in
                        HStack {
                            TextField("持有天数起点", text: $band.days).keyboardType(.numberPad)
                            Text("天起")
                            TextField("费率 %", text: $band.rate).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .onDelete { bands.remove(atOffsets: $0) }
                    Button("增加一个费率档") {
                        let next = (bands.compactMap { Int($0.days) }.max() ?? 0) + 30
                        bands.append(FeeBandDraft(days: String(next), rate: ""))
                    }
                    Text("至少需要 0 天起始档；程序按所选赎回批次逐笔计算持有天数，并套用最近的费率档。请按该基金销售页面/合同填写，缺失费率或买入批次不完整时不会估算，不会擅自认定为 0 费率。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("\(fund.name)赎回费率")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear {
                if let policy = store.data.fundFeePolicies.first(where: { $0.code == fund.code }) {
                    bands = policy.bands.map { FeeBandDraft(days: String($0.minimumHoldingDays), rate: String($0.ratePercent)) }
                    sellMode = policy.sellMode ?? .fifo
                }
            }
        }
    }

    private func save() {
        let parsed = bands.compactMap { row -> FundFeeBand? in
            guard let days = Int(row.days), let rate = Double(row.rate) else { return nil }
            return FundFeeBand(minimumHoldingDays: days, ratePercent: rate)
        }
        guard parsed.count == bands.count else { message = "每个档位都要填写持有天数和费率。"; return }
        do { try store.saveFundFeePolicy(code: fund.code, name: fund.name, bands: parsed, sellMode: sellMode); dismiss() }
        catch { message = error.localizedDescription }
    }
}

struct FundDividendEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var amount = ""
    @State private var nav = ""
    @State private var date = Date.now
    @State private var mode: FundTransaction.DividendMode = .cash
    @State private var linkCash = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("基金", value: "\(holding.name) · \(holding.code)")
                DatePicker("分红到账/确认日", selection: $date, displayedComponents: .date)
                TextField("分红金额", text: $amount).keyboardType(.decimalPad)
                Picker("分红方式", selection: $mode) {
                    Text("现金分红").tag(FundTransaction.DividendMode.cash)
                    Text("红利再投资").tag(FundTransaction.DividendMode.reinvest)
                }.pickerStyle(.segmented)
                if mode == .reinvest {
                    TextField("再投资净值", text: $nav).keyboardType(.decimalPad)
                    if let cash = Double(amount), let value = Double(nav), value > 0, cash > 0 {
                        LabeledContent("增加份额", value: (cash / value).num(4))
                    }
                } else {
                    Toggle("计入本程序参考现金", isOn: $linkCash)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("分红会计入累计收益。红利再投资按填写净值增加基金份额和成本；现金分红默认不改参考现金，只有确认资金也记在本程序现金中时才打开上面的开关。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("记录基金分红")
            .keyboardDoneToolbar()
            .onAppear { nav = nav.isEmpty ? String(holding.current) : nav }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let cash = Double(amount), cash.isFinite, cash > 0 else { error = "请输入有效分红金额"; return }
                        let effectiveNAV = Double(nav) ?? 0
                        do {
                            try store.recordFundDividend(code: holding.code, date: date, amount: cash,
                                mode: mode, nav: effectiveNAV, linkCash: mode == .cash && linkCash)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct FundIncomeCalendarView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 0
    @State private var monthOffset = 0
    @State private var yearOffset = 0
    @State private var selectedKey: String?

    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current; return c }
    private var monthDate: Date { calendar.date(byAdding: .month, value: monthOffset, to: .now) ?? .now }
    private var monthKey: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: monthDate)
    }
    private var displayedYear: Int { Calendar.current.component(.year, from: .now) + yearOffset }
    private var yearKey: String { String(displayedYear) }
    private var periodKey: String { scale == 0 ? monthKey : (scale == 1 ? yearKey : "") }
    private var days: [FundDailyPerformance] { store.fundDailyPerformance(period: periodKey.isEmpty ? nil : periodKey) }
    private var excluded: [(code: String, reason: String)] { store.fundDailyCalendarExcluded(period: periodKey.isEmpty ? nil : periodKey) }
    private var total: Double { selectedDays.reduce(0) { $0 + $1.profit } }
    private var selectedDays: [FundDailyPerformance] {
        guard let key = selectedKey else { return [] }
        return days.filter { scale == 0 ? $0.date == key : $0.date.hasPrefix(key) }
    }
    private var selectedLines: [FundDailyContribution] {
        var map: [String: FundDailyContribution] = [:]
        for day in selectedDays { for line in day.contributions {
            var item = map[line.code] ?? FundDailyContribution(code: line.code, name: line.name, profit: 0, baseValue: 0)
            item.profit += line.profit; item.baseValue += line.baseValue; map[line.code] = item
        } }
        return map.values.sorted { $0.profit > $1.profit }
    }
    private var visibleMonthDays: [FundDailyPerformance] { days.filter { $0.date.hasPrefix(monthKey) } }
    private var gridDates: [String?] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        guard let first = f.date(from: monthKey + "-01"), let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        var result: [String?] = Array(repeating: nil, count: leading)
        for offset in 0..<count { if let date = calendar.date(byAdding: .day, value: offset, to: first) { result.append(f.string(from: date)) } }
        while result.count % 7 != 0 { result.append(nil) }; return result
    }
    private var availableYears: [String] {
        let stored = Set(days.map { String($0.date.prefix(4)) })
        return (displayedYear - 4...displayedYear).reversed().map { String($0) }.filter { stored.contains($0) }
    }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("周期", selection: $scale) {
                        Text("按日").tag(0); Text("按月").tag(1); Text("按年").tag(2)
                    }.pickerStyle(.segmented).onChange(of: scale) { _, _ in selectedKey = nil }
                    HStack {
                        Button { if scale == 0 { monthOffset -= 1 } else { yearOffset -= 1 } } label: { Image(systemName: "chevron.left") }
                        Spacer(); Text(scale == 0 ? monthKey : yearKey).font(.headline)
                        Spacer(); Button { if scale == 0 { monthOffset += 1 } else { yearOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    }
                    LabeledContent(scale == 0 ? "本月收益" : (scale == 1 ? "本年收益" : "所选年份收益"), value: "\((days.reduce(0) { $0 + $1.profit }).directionMark()) \((days.reduce(0) { $0 + $1.profit }).cny())")
                        .foregroundStyle(PnLColor.of(total))
                    Text("收益按基金净值日期归属；晚到净值会回补原日期，不计入采集日。点选日期、月份或年份查看单只基金明细。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if scale == 0 {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                            ForEach(Array(gridDates.enumerated()), id: \.offset) { entry in
                                if let date = entry.element {
                                    let day = visibleMonthDays.first { $0.date == date }
                                    Button { selectedKey = date } label: {
                                        VStack(spacing: 3) { Text(String(date.suffix(2))); if let day { Text(day.profit.cny()).font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.6) } else { Text(" ").font(.system(size: 8)) } }
                                            .frame(maxWidth: .infinity, minHeight: 42)
                                            .background(selectedKey == date ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                            .foregroundStyle(day.map { PnLColor.of($0.profit) } ?? Color.secondary)
                                    }.buttonStyle(.plain)
                                } else { Color.clear.frame(height: 42) }
                            }
                        }
                    } else if scale == 1 {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                            ForEach(1...12, id: \.self) { month in
                                let key = String(format: "%04d-%02d", displayedYear, month)
                                let value = days.filter { $0.date.hasPrefix(key) }.reduce(0) { $0 + $1.profit }
                                Button { selectedKey = key } label: { VStack(spacing: 5) { Text("\(month)月"); Text(value.cny()).font(.caption).lineLimit(1).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, minHeight: 54).background(selectedKey == key ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(PnLColor.of(value)) }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                            ForEach(availableYears, id: \.self) { key in
                                let value = days.filter { $0.date.hasPrefix(key) }.reduce(0) { $0 + $1.profit }
                                Button { selectedKey = key } label: { VStack(spacing: 5) { Text(key); Text(value.cny()).font(.caption) }.frame(maxWidth: .infinity, minHeight: 54).background(selectedKey == key ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(PnLColor.of(value)) }.buttonStyle(.plain)
                            }
                        }
                        if availableYears.isEmpty {
                            Text("所选年份附近暂无可核算的净值收益。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let key = selectedKey {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(scale == 0 ? key : (scale == 1 ? "\(key) 月度明细" : "\(key) 年度明细")).font(.headline); Spacer(); Text(total.directionMark() + total.cny()).foregroundStyle(PnLColor.of(total)) }
                            if selectedLines.isEmpty { Text("该周期暂无可核算的基金收益明细").font(.footnote).foregroundStyle(.secondary) }
                            ForEach(selectedLines) { line in
                                HStack { VStack(alignment: .leading, spacing: 2) { Text(line.name); Text(line.code + (scale == 0 ? " · 净值日" : " · 区间累计")).font(.caption).foregroundStyle(.secondary) }; Spacer(); VStack(alignment: .trailing, spacing: 2) { Text(line.profit.directionMark() + line.profit.cny()).foregroundStyle(PnLColor.of(line.profit)); Text(line.baseValue > 0 ? (line.profit / line.baseValue * 100).pct(2) : "—").font(.caption).foregroundStyle(.secondary) } }
                            }
                        }.padding(.vertical, 4)
                    }
                    if !excluded.isEmpty {
                        DisclosureGroup("暂未计入 \(excluded.count) 只基金") {
                            ForEach(excluded, id: \.code) { item in
                                LabeledContent(item.code, value: item.reason)
                            }
                            Text("补齐净值历史，或在基金持仓里补录可核实的历史起始份额后，日历会按净值日期重新计算。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toneCard(CardTone.pnl(total), isLight: isLight)
                Text("日收益按前一净值日已确认份额计算；当日买入不计入当日净值变化，当日赎回份额仍计入；分红金额和申赎费用按流水日计入。手动持仓若缺少历史买入流水，会在上方列出并说明原因。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("基金收益日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

struct FundQuantView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var dcaEditorTarget: Holding?

    private var funds: [Holding] {
        store.data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }
            .sorted { $0.marketValue > $1.marketValue }
    }
    private var totalValue: Double { funds.reduce(0) { $0 + $1.marketValue } }
    private var totalCost: Double { funds.reduce(0) { $0 + $1.quantity * store.displayedCost(for: $1) } }
    private var confirmedTransactions: [FundTransaction] {
        store.data.fundTransactions.filter { $0.status == .confirmed }
    }
    private var recordedFees: Double {
        confirmedTransactions.filter { $0.side != .dividend }.reduce(0) { $0 + abs($1.fee) }
    }
    private var cashDividends: Double {
        confirmedTransactions.filter { $0.side == .dividend && $0.dividendMode == .cash }
            .reduce(0) { $0 + $1.amount }
    }
    private var reinvestedDividends: Double {
        confirmedTransactions.filter { $0.side == .dividend && $0.dividendMode == .reinvest }
            .reduce(0) { $0 + $1.amount }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    /// 定投计划对应的基金持仓；持仓被删时用计划的代码/名称兜底造一个轻量实例，
    /// 保证「修改计划」入口对任何已存计划都可用。
    private func holdingForPlan(_ plan: FundDCAPlan) -> Holding {
        store.data.holdings.first(where: { $0.code == plan.code && $0.kind == .fund })
            ?? Holding(code: plan.code, name: plan.name, quantity: 0, cost: 0, current: 0, kind: .fund)
    }
    /// 基金模块的浮盈，用于给「组合概览」卡取色。
    private var fundPnLTotal: Double { totalValue - totalCost }

    var body: some View {
        NavigationStack {
            List {
                Section("组合概览") {
                    LabeledContent("当前基金数", value: "\(funds.count)")
                    LabeledContent("当前市值", value: (totalValue).cny())
                    LabeledContent("持仓成本", value: (totalCost).cny())
                    LabeledContent("持仓浮盈", value: "\((fundPnLTotal).directionMark()) \((fundPnLTotal).cny())")
                        .foregroundStyle(PnLColor.of(fundPnLTotal))
                    if totalCost > 0 {
                        LabeledContent("成本收益率", value: ((totalValue - totalCost) / totalCost * 100).pct(2))
                    }
                }
                .toneCard(CardTone.pnl(fundPnLTotal), isLight: isLight)
                Section("持仓集中度与表现") {
                    if funds.isEmpty { Text("没有份额大于 0 的基金持仓。").foregroundStyle(.secondary) }
                    ForEach(funds) { fund in
                        let weight = totalValue > 0 ? fund.marketValue / totalValue : 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(fund.name).font(.headline)
                                Spacer()
                                Text((weight * 100).pct(1))
                                    .foregroundStyle(weight >= 0.5 ? Color.orange : Color.secondary)
                            }
                            let fundPnL = store.holdingPnL(fund)
                            Text("\(fund.code) · 市值 \((fund.marketValue).cny()) · 浮盈 \((fundPnL).cny())")
                                .font(.caption).foregroundStyle(fundPnL >= 0 ? Color.red : Color.green)
                            Text("份额 \((fund.quantity).compactNum(4)) · 现值 \((fund.current).num(4)) · 成本 \((store.displayedCost(for: fund)).num(4))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                    if funds.contains(where: { totalValue > 0 && $0.marketValue / totalValue >= 0.5 }) {
                        Text("有单只基金占当前基金市值一半或以上；这只是集中度提示，不代表买卖建议。")
                            .font(.footnote).foregroundStyle(CardTone.warn)
                    }
                }
                .plainCard(isLight: isLight)
                Section("费用与分红流水") {
                    LabeledContent("已记录申购/赎回费用", value: (recordedFees).cny())
                    LabeledContent("已记录现金分红", value: (cashDividends).cny())
                    LabeledContent("已记录红利再投资", value: (reinvestedDividends).cny())
                    Text("只汇总本机已确认流水；不包含销售平台未录入的费用、分红或管理费。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section("整笔赎回费可估性") {
                    ForEach(funds) { fund in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fund.name)
                            if store.data.fundFeePolicies.contains(where: { $0.code == fund.code }) {
                                if let estimate = store.estimateFundRedemptionFee(code: fund.code,
                                    shares: fund.quantity, nav: fund.current, on: .now) {
                                    Text("按当前费率档和批次策略估算：\((estimate.total).cny())")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("已设置费率档，但当前批次或流水不足，无法可靠估算。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("尚未设置该基金的赎回费率档。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("这是按当前份额整笔赎回的估算，不会记账或下单；最终费用以销售平台确认结果为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section("定投执行记录") {
                    if store.data.fundDCAPlans.isEmpty { Text("暂无原生定投计划。").foregroundStyle(.secondary) }
                    ForEach(store.data.fundDCAPlans) { plan in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(plan.name); Spacer(); Text(plan.enabled ? "运行中" : "已暂停").foregroundStyle(plan.enabled ? Color.green : Color.secondary) }
                            Text("每期 \(plan.amount.cny()) · 已记 \(plan.processedDates.count) 期 · 开始于 \(plan.startDate)")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("修改计划") { dcaEditorTarget = holdingForPlan(plan) }
                                    .buttonStyle(.bordered)
                                Button(plan.enabled ? "暂停计划" : "恢复计划") {
                                    store.setDCAPlan(plan, enabled: !plan.enabled)
                                }.buttonStyle(.bordered)
                                Button("删除计划", role: .destructive) { store.removeDCAPlan(plan) }
                                    .buttonStyle(.bordered)
                            }.font(.caption)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) { store.removeDCAPlan(plan) }
                            Button(plan.enabled ? "暂停" : "恢复", systemImage: plan.enabled ? "pause.fill" : "play.fill") {
                                store.setDCAPlan(plan, enabled: !plan.enabled)
                            }.tint(.orange)
                        }
                    }
                    Text("执行期数依据本机已记录的定投流水，不推断错过期次，也不连接销售平台。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .sheet(item: $dcaEditorTarget) { target in
                FundDCAPlanEditor(holding: target).themedSheetBackground()
            }
            .navigationTitle("基金量化体检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

struct FundNAVHistoryView: View {
    @EnvironmentObject var store: PortfolioStore
    let fund: Holding
    @State private var rangeDays = 90
    @State private var selectedDate: String?

    private var points: [FundNAVPoint] {
        // 旧备份可能把同一天净值重复导入。折叠成每日一条，避免 Charts
        // 收到重复 Identifiable ID 后出现连线/点选错乱。
        let byDate = store.data.fundNAVHistory
            .filter { $0.code == fund.code && $0.nav.isFinite && $0.nav > 0 }
            .reduce(into: [String: FundNAVPoint]()) { result, point in
                result[point.date] = point
            }
        return byDate.values.sorted { $0.date < $1.date }
    }
    private var chartPoints: [FundNAVPoint] {
        guard rangeDays > 0 else { return points }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -rangeDays, to: .now) ?? .distantPast
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        let key = f.string(from: cutoff)
        let filtered = points.filter { $0.date >= key }
        return filtered.isEmpty ? Array(points.suffix(30)) : filtered
    }
    private var chartDomain: ClosedRange<Double> {
        guard let low = chartPoints.map(\.nav).min(), let high = chartPoints.map(\.nav).max() else { return 0...1 }
        let pad = max(max((high - low) * 0.12, high * 0.002), 0.0001)
        return max(0, low - pad)...(high + pad)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("已公布净值，不是盘中估值") {
                    if let latest = points.last {
                        LabeledContent("最新净值日期", value: latest.date)
                        LabeledContent("最新净值", value: (latest.nav).num(4))
                        if points.count > 1, let previous = points.dropLast().last {
                            let navChange = latest.nav - previous.nav
                            LabeledContent("较上一期", value: (navChange).num(4))
                            LabeledContent("按当前份额折算", value: (navChange * fund.quantity).cny())
                        }
                    } else {
                        ContentUnavailableView("暂无净值历史", systemImage: "chart.xyaxis.line", description: Text("回到基金页点右上角刷新。"))
                    }
                }
                if points.count > 1 {
                    Section("历史净值") {
                        Picker("时间范围", selection: $rangeDays) {
                            Text("1月").tag(30); Text("3月").tag(90); Text("半年").tag(180); Text("1年").tag(365); Text("全部").tag(0)
                        }.pickerStyle(.segmented)
                        if let first = chartPoints.first, let latest = chartPoints.last {
                            let change = latest.nav - first.nav
                            let changePercent = first.nav > 0 ? change / first.nav * 100 : 0
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("区间最新净值").font(.caption).foregroundStyle(.secondary)
                                    Text(latest.nav.num(4)).font(.title2.weight(.bold)).monospacedDigit()
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(change.directionMark()) \(change.num(4))")
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(PnLColor.of(change))
                                    Text("\(changePercent.directionMark()) \(changePercent.pct(2))")
                                        .font(.caption).monospacedDigit().foregroundStyle(PnLColor.of(change))
                                }
                            }
                            .padding(.vertical, 4)
                            HStack(spacing: 4) {
                                Text(first.date)
                                Spacer(minLength: 4)
                                Text("\(chartPoints.count) 个净值点")
                                Spacer(minLength: 4)
                                Text(latest.date)
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        if let selectedDate, let point = chartPoints.first(where: { $0.date == selectedDate }) {
                            HStack {
                                Text("选中")
                                Spacer()
                                Text("\(selectedDate) · \(point.nav.num(4))")
                                    .fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.caption)
                        }
                        Chart {
                            ForEach(chartPoints) { point in
                                AreaMark(x: .value("日期", point.date), yStart: .value("区间低点", chartDomain.lowerBound), yEnd: .value("单位净值", point.nav))
                                    .foregroundStyle(Color.accentColor.opacity(0.08))
                                LineMark(x: .value("日期", point.date), y: .value("单位净值", point.nav), series: .value("曲线", "单位净值"))
                                    .interpolationMethod(.linear)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if let selectedDate, let point = chartPoints.first(where: { $0.date == selectedDate }) {
                                RuleMark(x: .value("选中日期", selectedDate))
                                    .foregroundStyle(Color.secondary.opacity(0.55))
                                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                                PointMark(x: .value("选中日期", selectedDate), y: .value("选中净值", point.nav))
                                    .foregroundStyle(Color.accentColor)
                                    .symbolSize(48)
                            }
                        }
                        .chartYScale(domain: chartDomain)
                        .chartXAxis {
                            AxisMarks(values: sampledNAVAxisDates) { value in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                                AxisValueLabel {
                                    if let date = value.as(String.self) {
                                        Text(String(date.dropFirst(5)).replacingOccurrences(of: "-", with: "/"))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                                AxisValueLabel {
                                    if let nav = value.as(Double.self) {
                                        Text(nav.num(4)).font(.system(size: 9, design: .rounded)).monospacedDigit()
                                    }
                                }
                            }
                        }
                        .frame(height: 230)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        .chartXSelection(value: $selectedDate)
                        .accessibilityLabel("\(fund.name)历史单位净值曲线")
                    }
                    Section("最近净值") {
                        ForEach(points.suffix(20).reversed()) { point in
                            HStack { Text(point.date); Spacer(); Text((point.nav).num(4)) }
                        }
                    }
                }
                Text("历史净值变化只反映单位净值变化；“按当前份额折算”没有还原过去每天的实际份额，不能当作历史账户收益。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle(fund.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var sampledNAVAxisDates: [String] {
        guard chartPoints.count > 1 else { return chartPoints.map(\.date) }
        let count = min(4, chartPoints.count)
        return (0..<count).map { index in
            chartPoints[(index * (chartPoints.count - 1)) / (count - 1)].date
        }
    }
}

struct HoldingEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let kind: Holding.Kind
    var initial: Holding?
    @State private var code: String
    @State private var name: String
    @State private var quantity: String
    @State private var cost: String
    @State private var current: String
    @State private var maxPositionPercent: String
    @State private var maWarningPeriod: String
    @State private var annualDividendPerShare: String
    @State private var lookupMessage = ""

    init(kind: Holding.Kind, initial: Holding? = nil) {
        self.kind = kind; self.initial = initial
        _code = State(initialValue: initial?.code ?? "")
        _name = State(initialValue: initial?.name ?? "")
        _quantity = State(initialValue: initial.map { String($0.quantity) } ?? "")
        _cost = State(initialValue: initial.map { String($0.cost) } ?? "")
        _current = State(initialValue: initial.map { String($0.current) } ?? "")
        _maxPositionPercent = State(initialValue: initial?.maxPositionPercent.map { String($0) } ?? "")
        _maWarningPeriod = State(initialValue: initial?.maWarningPeriod.map { String($0) } ?? "")
        _annualDividendPerShare = State(initialValue: initial?.annualDividendPerShare.map { String($0) } ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("标的信息") {
                    TextField("代码", text: $code).keyboardType(.numberPad)
                    TextField("名称", text: $name)
                    if !lookupMessage.isEmpty {
                        Text(lookupMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("份额和价格") {
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成本净值/成本价", text: $cost).keyboardType(.decimalPad)
                    TextField("当前净值/价格", text: $current).keyboardType(.decimalPad)
                }
                if kind == .etf {
                    Section("单只风险提示") {
                        TextField("仓位上限（占总资产 %，可空）", text: $maxPositionPercent).keyboardType(.decimalPad)
                        Picker("收盘价跌破均线提示", selection: $maWarningPeriod) {
                            Text("关闭").tag("")
                            ForEach([5, 10, 20, 60, 120, 250], id: \.self) { Text("MA\($0)").tag(String($0)) }
                        }
                        TextField("每份年分红修正（元，可空）", text: $annualDividendPerShare).keyboardType(.decimalPad)
                        Text("只在工具页和日线图打开时，依据本机已有日线检查；不会后台推送。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(kind == .etf
                    ? "这里只维护本机持仓，不连接券商或执行交易。输入六位代码后会尝试识别名称和现价；行情接口不可用时可手动填写。"
                    : "这里只维护本机基金持仓，不连接销售平台或执行申赎。输入六位代码后会尝试识别名称和最近已公布净值；接口不可用时可手动填写。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .onChange(of: code) { oldValue, newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(6))
                if filtered != newValue { code = filtered; return }
                if oldValue != newValue {
                    // 新增时若上一组六位代码已经自动回填，再改代码必须清掉旧名称/价格；
                    // 否则第二只基金可能被误存成第一只的名称。
                    let changedAwayFromResolvedCode = oldValue.filter(\.isNumber).count == 6
                    let changedAwayFromInitial = initial.map { $0.code != newValue } ?? false
                    if changedAwayFromResolvedCode || changedAwayFromInitial {
                        name = ""
                        current = ""
                    }
                    lookupMessage = ""
                }
            }
            .task(id: code) {
                let requested = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard requested.count == 6, requested.allSatisfy(\.isNumber),
                      initial?.code != requested else { return }
                lookupMessage = "正在识别代码…"
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                do {
                    if kind == .fund {
                        guard let info = try await store.lookupFundInfo(code: requested), !Task.isCancelled,
                              code.trimmingCharacters(in: .whitespacesAndNewlines) == requested else {
                            if !Task.isCancelled { lookupMessage = "未识别到该基金代码，可手动填写名称和净值。" }
                            return
                        }
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = info.name }
                        if let nav = info.nav,
                           current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == "0" {
                            current = String(nav)
                        }
                        lookupMessage = info.nav.map { "已识别：\(info.name) · 最新净值 \($0)" } ?? "已识别：\(info.name)"
                    } else {
                        guard let quote = try await store.lookupETFQuote(code: requested), !Task.isCancelled,
                              code.trimmingCharacters(in: .whitespacesAndNewlines) == requested else {
                            if !Task.isCancelled { lookupMessage = "未识别到该代码，可手动填写名称和现价。" }
                            return
                        }
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = quote.name }
                        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current == "0" { current = String(quote.price) }
                        lookupMessage = "已识别：\(quote.name) · 现价 \(quote.price)"
                    }
                } catch {
                    if !Task.isCancelled {
                        lookupMessage = kind == .fund
                            ? "基金信息接口暂不可用，可手动填写名称和净值。"
                            : "行情接口暂不可用，可手动填写名称和现价。"
                    }
                }
            }
            .navigationTitle(initial == nil ? "添加持仓" : "编辑持仓")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }
    private func save() {
        let cde = code.trimmingCharacters(in: .whitespaces)
        guard !cde.isEmpty, let q = Double(quantity), q >= 0, q.isFinite,
              let c = Double(cost), c >= 0, c.isFinite,
              let p = Double(current), p >= 0, p.isFinite else { return }
        let maxLimit = maxPositionPercent.isEmpty ? nil : Double(maxPositionPercent)
        if !maxPositionPercent.isEmpty {
            guard let maxLimit, maxLimit.isFinite, maxLimit > 0, maxLimit <= 100 else { return }
        }
        let dividend = annualDividendPerShare.isEmpty ? nil : Double(annualDividendPerShare)
        if !annualDividendPerShare.isEmpty {
            guard let dividend, dividend.isFinite, dividend >= 0 else { return }
        }
        let h = Holding(code: cde, name: name.isEmpty ? cde : name, quantity: q, cost: c, current: p, kind: kind,
                        maxPositionPercent: maxLimit, maWarningPeriod: Int(maWarningPeriod), annualDividendPerShare: dividend)
        store.upsertHolding(h, oldCode: initial?.code); dismiss()
    }
}

struct TradeEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    @State private var side: LedgerEntry.Side = .buy
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = "0"
    @State private var linkCash = false
    @State private var tradeDate = Date.now
    @State private var settlementDate = Date.now
    @State private var error = ""
    @State private var feeEstimateText = ""
    @State private var estimatedRedemptionLots: [FundLotRedemption]?
    @State private var estimatedFeeValue: Double?
    @State private var estimatedQuantity = ""
    @State private var estimatedTradeDay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(holding.name) {
                    Picker("方向", selection: $side) { Text("买入").tag(LedgerEntry.Side.buy); Text("卖出").tag(LedgerEntry.Side.sell) }.pickerStyle(.segmented)
                    TextField("份额", text: $quantity).keyboardType(.decimalPad)
                    TextField("成交价/净值", text: $price).keyboardType(.decimalPad)
                    TextField("手续费", text: $fee).keyboardType(.decimalPad)
                    if holding.kind == .fund {
                        if side == .sell {
                            Button("按所选批次策略估算赎回费") { estimateFundFee() }
                            if !feeEstimateText.isEmpty { Text(feeEstimateText).font(.footnote).foregroundStyle(.secondary) }
                        }
                        DatePicker("申请日期", selection: $tradeDate, displayedComponents: .date)
                        DatePicker("确认/净值生效日", selection: $settlementDate, displayedComponents: .date)
                    } else {
                        DatePicker("成交日期", selection: $tradeDate, displayedComponents: .date)
                    }
                    if holding.kind == .etf { Toggle("联动本程序现金", isOn: $linkCash) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text(holding.kind == .etf ? "ETF 手续费默认按每笔 0.10 元填写，可按券商实收修改；卖出盈亏按当前成本价计算。是否联动参考现金逐笔选择。" : "基金申赎费优先以实际扣费为准。可按基金合同配置费率与赎回批次策略；估算不等于销售平台最终扣费，交易不会连接销售平台。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("记一笔交易")
            .keyboardDoneToolbar()
            .onChange(of: quantity) { _, _ in clearFundFeeEstimate() }
            .onChange(of: tradeDate) { _, _ in clearFundFeeEstimate() }
            .onChange(of: side) { _, _ in clearFundFeeEstimate() }
            .onAppear {
                linkCash = holding.kind == .etf && store.data.cashLinkedByDefault
                fee = holding.kind == .etf ? "0.10" : "0"
                settlementDate = tradeDate
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("入账") { save() } }
            }
        }
    }
    private func save() {
        guard let q = Double(quantity), let p = Double(price), let f = Double(fee) else { error = "请输入有效数字"; return }
        do { try store.recordTrade(code: holding.code, kind: holding.kind, side: side, quantity: q, price: p,
            fee: f, linkedCash: linkCash, date: tradeDate,
            settlementDate: holding.kind == .fund ? settlementDate : nil,
            fundRedemptionLots: estimatedQuantity == quantity && estimatedTradeDay == dayKey(tradeDate) ? estimatedRedemptionLots : nil,
            fundFeeWasEstimated: holding.kind == .fund && side == .sell
                && estimatedFeeValue.map { abs($0 - f) <= 0.005 } == true); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func estimateFundFee() {
        guard let shares = Double(quantity), let nav = Double(price), shares > 0, nav > 0 else {
            feeEstimateText = "先填写有效赎回份额和净值。"; return
        }
        guard let estimate = store.estimateFundRedemptionFee(code: holding.code, shares: shares, nav: nav, on: tradeDate) else {
            feeEstimateText = "无法可靠估算：请先录入完整持有批次，并按基金合同设置全部适用费率档。"; return
        }
        fee = String(format: "%.2f", estimate.total)
        estimatedFeeValue = estimate.total
        estimatedRedemptionLots = estimate.redemptionLots
        estimatedQuantity = quantity
        estimatedTradeDay = dayKey(tradeDate)
        let detail = estimate.parts.map { String(format: "%@买入 · %d天 %.2f份 × %.3f%%", $0.purchaseDate, $0.days, $0.shares, $0.ratePercent) }.joined(separator: "；")
        feeEstimateText = "批次估算 \((estimate.total).cny())：\(detail)。请与实际扣费核对后再入账。"
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func clearFundFeeEstimate() {
        estimatedRedemptionLots = nil
        estimatedFeeValue = nil
        estimatedQuantity = ""
        estimatedTradeDay = ""
    }
}

private struct FundFeeReconciliationEditor: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let transaction: FundTransaction
    @State private var feeText = ""
    @State private var netText = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(transaction.name) {
                    LabeledContent("赎回总额", value: (transaction.amount).cny())
                    LabeledContent("原估算费用", value: (transaction.fee).cny())
                    TextField("实际扣费（可选）", text: $feeText).keyboardType(.decimalPad)
                    TextField("实际到账（可选）", text: $netText).keyboardType(.decimalPad)
                    Text("填写实际扣费或实际到账，也可以同时填写核对一致性。保存后会修正已实现盈亏；若交易联动参考现金，也会按差额校正现金。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("核对实际赎回费")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }

    private func save() {
        let gross = transaction.amount
        let hasFee = !feeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasNet = !netText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let feeValue = hasFee ? Double(feeText) : nil
        let netValue = hasNet ? Double(netText) : nil
        guard hasFee || hasNet else { message = "请填写实际扣费或实际到账。"; return }
        guard (!hasFee || feeValue?.isFinite == true), (!hasNet || netValue?.isFinite == true) else { message = "金额格式无效。"; return }
        let actualFee = feeValue ?? (gross - (netValue ?? gross))
        guard actualFee >= 0, actualFee <= gross else { message = "实际费用需在 0 元与赎回总额之间。"; return }
        if let netValue, (netValue < 0 || netValue > gross || abs((gross - actualFee) - netValue) > 0.01) {
            message = "扣费与到账金额不一致，请核对后重填。"; return
        }
        do {
            try store.confirmFundRedemptionFee(transactionID: transaction.id, actualFee: actualFee)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct AssetsView: View {
    @EnvironmentObject var store: PortfolioStore
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    @State private var showCashFlow = false
    @State private var selectedSnapshotMonth = ""
    @State private var selectedLedgerMonth = ""
    @State private var snapshotBackfillMessage = ""
    @State private var snapshotDetailsExpanded = false
    @State private var snapshotDeleteTarget: PortfolioSnapshot?
    @State private var showManualSnapshotEditor = false
    @State private var manualSnapshotDate = ""
    @State private var manualSnapshotTotal = ""
    @State private var snapshotEditorError = ""
    @State private var showClearReconstructedSnapshots = false

    private var snapshotChartData: [PortfolioSnapshot] {
        Array(store.data.snapshots.sorted { $0.date < $1.date }.suffix(60))
    }

    /// 快照图不再强制从 0 起画。资产只变几十元时，用 0…10000 会把曲线压成一条直线；
    /// 这里按可见数据的真实高低点加 8% 留白，并给极小波动保留最少 1% 的观察窗。
    private var snapshotChartDomain: ClosedRange<Double> {
        let values = snapshotChartData.map(\.total).filter { $0.isFinite }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let minimumSpan = max(abs((low + high) / 2) * 0.01, 10)
        let span = max(high - low, minimumSpan)
        let padding = span * 0.10
        return (low - padding)...(high + padding)
    }

    private var snapshotAxisDates: [String] {
        let rows = snapshotChartData
        guard let first = rows.first?.date, let last = rows.last?.date else { return [] }
        if rows.count < 3 || first == last { return [first] }
        return [first, rows[rows.count / 2].date, last]
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("总资产").font(.caption).foregroundStyle(.secondary)
                                Text((store.totalAsset).cny())
                                    .scaledFont(28, weight: .bold, design: .rounded)
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.7).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(store.hasDayPnLGross
                                     ? "\((store.dayPnLGross).directionMark()) \((store.dayPnLGross).cny())" : "--")
                                    .scaledFont(15, weight: .semibold, design: .rounded)
                                    .monospacedDigit()
                                    .foregroundStyle(dayTone)
                                    .accessibilityLabel(store.hasDayPnLGross
                                        ? "当日盈亏 \(spokenDirection(store.dayPnLGross)) \(spokenMoney(abs(store.dayPnLGross)))"
                                        : "当日盈亏暂无数据")
                                Text(store.hasDayPnLGross ? (store.dayPnLGrossRate?.pct(2) ?? "--") : "--")
                                    .font(.caption).foregroundStyle(dayTone)
                                Text("当日盈亏").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        assetComposition
                        MetricGrid(columns: 3, cells: [
                            MetricCell(title: "持仓市值", value: (store.totalMarketValue).cny()),
                            MetricCell(title: "参考现金", value: (store.data.cash).cny()),
                            MetricCell(title: "仓位", value: (store.positionPercent).pct(1)),
                            MetricCell(title: "持仓浮盈", value: (store.totalPnL).cny(), toneValue: store.totalPnL),
                            MetricCell(title: "盈亏比例", value: store.totalPnLRate.map { $0.pct(2) } ?? "--", toneValue: store.totalPnL),
                            MetricCell(title: "总成本", value: (store.totalCost).cny()),
                            MetricCell(title: "当日盈亏", value: store.hasDayPnLGross ? (store.dayPnLGross).cny() : "--",
                                      toneValue: store.hasDayPnLGross ? store.dayPnLGross : nil),
                            MetricCell(title: "当日幅度", value: store.hasDayPnLGross ? (store.dayPnLGrossRate?.pct(2) ?? "--") : "--",
                                      toneValue: store.hasDayPnLGross ? store.dayPnLGross : nil),
                            MetricCell(title: "已实现盈亏", value: (store.realizedPnL).cny(), toneValue: store.realizedPnL),
                            MetricCell(title: "ETF / 证券", value: (store.marketValue(of: .etf)).cny()),
                            MetricCell(title: "场外基金", value: (store.marketValue(of: .fund)).cny()),
                            MetricCell(title: "累计净转入", value: netDeposit.cny(), toneValue: netDeposit)
                        ])
                        Text("累计净转入 = 现金流记录里转入与转出相抵后的净额，只统计你手动记录过的流水。")
                            .scaledFont(10).foregroundStyle(.secondary)
                        Button("记录现金转入 / 转出") { showCashFlow = true }
                    }
                    .cardSurface(tone: store.hasDayPnLGross
                                 ? (store.dayPnLGross > 0.005 ? PnLColor.up : store.dayPnLGross < -0.005 ? PnLColor.down : nil)
                                 : (store.totalPnL > 0.005 ? PnLColor.up : store.totalPnL < -0.005 ? PnLColor.down : nil))
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                } header: { Text("账户总览") }
                Section("历史快照") {
                    Button("手动录入/修正某日真实值") { beginManualSnapshotEdit() }
                    // 休市日不给记录入口：这天的总资产和上一交易日几乎一样
                    // （场外净值不更新、场内是上一交易日的收盘价），记了只会让
                    // 收益曲线多出一段平线，还会把「区间收益」的分母算歪。
                    if store.isMarketClosedToday {
                        Label("今天休市，不用记录快照", systemImage: "moon.zzz")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("休市日的总资产与上一交易日基本一致，交易日再记即可。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("记录/更新今日快照") { store.recordSnapshot() }
                    }
                    Button {
                        Task {
                            await store.ensureBackfillHistory()
                            let r = store.backfillVerifiableSnapshots()
                            snapshotBackfillMessage = r.added > 0 ? "已补全 \(r.added) 个历史重建快照；\(r.skipped) 日因持仓、现金或价格不能核实而保留空白。" : "没有可安全补全的日期。"
                            if r.added > 0 { snapshotDetailsExpanded = true }
                        }
                    } label: { Label("补全可核实的历史快照", systemImage: "calendar.badge.plus") }
                    let reconstructedCount = store.data.snapshots.filter { $0.quality == .reconstructed }.count
                    if reconstructedCount > 0 {
                        Button(role: .destructive) { showClearReconstructedSnapshots = true } label: {
                            Label("清除历史重建快照（\(reconstructedCount) 条）", systemImage: "trash")
                        }
                    }
                    if !snapshotBackfillMessage.isEmpty { Text(snapshotBackfillMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("净值更新后会按净值日期自动修正可核实的历史快照，并补建缺失日期；手动核实的快照不会被覆盖。重建只使用完整流水、现金与真实历史价格，无法核实的日期会保留原值并提示。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup(isExpanded: $snapshotDetailsExpanded) {
                    if !store.snapshotMonths.isEmpty {
                        Picker("月份", selection: $selectedSnapshotMonth) {
                            ForEach(store.snapshotMonths, id: \.self) { Text($0).tag($0) }
                        }
                        if let summary = store.snapshotMonthSummary(selectedSnapshotMonth) {
                            LabeledContent("区间收益（扣除净转入）", value: (summary.pnl).cny())
                            Text("实测区间：\(summary.start.date) → \(summary.end.date)。\(summary.complete ? "有月初前基准快照；数值截至所选月最后一条快照，不代表缺失日期的逐日收益。" : "缺少月初前基准快照，当前从本月首条快照起算，不能代表完整月收益。")")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("该月快照不足两条，无法计算区间收益。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.data.snapshots.isEmpty { Text("暂无快照").foregroundStyle(.secondary) }
                    let sortedSnapshots = store.data.snapshots.sorted { $0.date < $1.date }
                    if sortedSnapshots.count > 1 {
                        let first = snapshotChartData.first
                        let last = snapshotChartData.last
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最近 \(snapshotChartData.count) 条").scaledFont(9).foregroundStyle(.secondary)
                                Text(snapshotChartData.map(\.total).min()?.cny() ?? "--").scaledFont(11, weight: .semibold)
                            }
                            Spacer()
                            if let first, let last {
                                let change = last.total - first.total
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("区间资产变化").scaledFont(9).foregroundStyle(.secondary)
                                    Text("\(change.directionMark()) \(change.cny())")
                                        .scaledFont(11, weight: .semibold).foregroundStyle(PnLColor.of(change))
                                }
                            }
                        }
                        Chart(snapshotChartData) { s in
                            AreaMark(x: .value("日期", s.date),
                                     yStart: .value("下界", snapshotChartDomain.lowerBound),
                                     yEnd: .value("总资产", s.total))
                                .foregroundStyle(store.effectiveAccentColor.opacity(0.10))
                            LineMark(x: .value("日期", s.date), y: .value("总资产", s.total))
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(store.effectiveAccentColor)
                            PointMark(x: .value("日期", s.date), y: .value("总资产", s.total))
                                .symbolSize(s.quality == .provisional ? 42 : 24)
                                .foregroundStyle(s.quality == .provisional ? Color.orange : store.effectiveAccentColor)
                        }
                        .chartYScale(domain: snapshotChartDomain)
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                                AxisValueLabel {
                                    if let amount = value.as(Double.self) { Text(amount.cny(0)).scaledFont(8) }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: snapshotAxisDates) { value in
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.10))
                                AxisValueLabel {
                                    if let day = value.as(String.self) { Text(shortDay(day)).scaledFont(8) }
                                }
                            }
                        }
                        .chartPlotStyle { plot in
                            plot.background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .frame(height: 210)
                        .accessibilityLabel("最近60条总资产快照曲线，纵轴已按真实资产区间缩放")
                    }
                    ForEach(Array(sortedSnapshots.indices.reversed()), id: \.self) { index in
                        let s = sortedSnapshots[index]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(s.date)
                                if s.quality == .provisional { Text("临时").font(.caption2).foregroundStyle(.orange) }
                                else if s.quality == .settled { Text("已结算").font(.caption2).foregroundStyle(.green) }
                                else if s.quality == .reconstructed { Text("历史重建").font(.caption2).foregroundStyle(.blue) }
                                else if s.quality == .manual { Text("手动核实").font(.caption2).foregroundStyle(.purple) }
                                Spacer()
                                Text((s.total).cny())
                                Button("修正") {
                                    manualSnapshotDate = s.date
                                    manualSnapshotTotal = s.total.num(2)
                                    snapshotEditorError = ""
                                    // 独立表单避免 List/DisclosureGroup 在编辑时重建并自动折叠。
                                    showManualSnapshotEditor = true
                                }
                                .font(.caption)
                            }
                            if let note = s.note, !note.isEmpty {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                            if index > 0 {
                                let prior = sortedSnapshots[index - 1]
                                let result = store.snapshotReturn(from: prior, to: s)
                                Text("较上次快照收益（已扣除现金流） \((result).directionMark()) \((result).cny())")
                                    .font(.caption).foregroundStyle(PnLColor.of(result))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { snapshotDeleteTarget = s } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    } label: {
                        HStack {
                            Text("查看历史快照")
                            Spacer()
                            Text("\(store.data.snapshots.count) 条")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toneCard(CardTone.pnl(snapshotMonthPnL ?? 0), isLight: isLight)
                Section("ETF / 证券已实现收益") {
                    if store.ledgerMonths.isEmpty {
                        Text("暂无 ETF / 证券卖出流水。旧版未标注类别的流水按当时唯一支持的 ETF 类型兼容。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("流水月份", selection: $selectedLedgerMonth) {
                            ForEach(store.ledgerMonths, id: \.self) { Text($0).tag($0) }
                        }
                        let daily = store.ledgerDailyRealized(month: selectedLedgerMonth)
                        let realizedTotal = daily.reduce(0) { $0 + $1.profit }
                        LabeledContent("本月已实现盈亏", value: "\((realizedTotal).directionMark()) \((realizedTotal).cny())")
                            .foregroundStyle(PnLColor.of(realizedTotal))
                        if daily.isEmpty {
                            Text("本月没有已记录的 ETF / 证券卖出流水。买入和持仓浮盈不包含在这里。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(daily.enumerated()), id: \.offset) { item in
                                let day = item.element
                                HStack {
                                    Text(day.date)
                                    Text("\(day.trades) 笔流水").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\((day.profit).directionMark()) \((day.profit).cny())")
                                        .foregroundStyle(PnLColor.of(day.profit))
                                }
                            }
                        }
                        Text("这里只统计卖出落袋盈亏；没有每日历史行情/快照时，不能还原历史持仓浮盈或完整账户每日收益。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .toneCard(CardTone.pnl(ledgerMonthRealized), isLight: isLight)
                Section("近期现金流") {
                    if store.data.cashFlows.isEmpty { Text("暂无转入或转出记录").foregroundStyle(.secondary) }
                    ForEach(store.data.cashFlows.sorted { $0.date > $1.date }.prefix(10)) { flow in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(flow.memo.isEmpty ? (flow.amount > 0 ? "现金转入" : "现金转出") : flow.memo)
                                Text(flow.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((flow.amount).cny())
                                .foregroundStyle(flow.amount >= 0 ? PnLColor.up : PnLColor.down)
                        }
                    }
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear).navigationTitle("资产")
            .navigationBarTitleDisplayMode(.inline)
                .refreshable { await manuallyRefreshAssets() }
                .refreshFeedbackOverlay(refreshFeedback)
                .onAppear {
                    if selectedSnapshotMonth.isEmpty { selectedSnapshotMonth = store.snapshotMonths.first ?? "" }
                    if selectedLedgerMonth.isEmpty { selectedLedgerMonth = store.ledgerMonths.first ?? "" }
                }
                .sheet(isPresented: $showCashFlow) { CashFlowEditor() .themedSheetBackground() }
                .sheet(isPresented: $showManualSnapshotEditor) {
                    NavigationStack {
                        Form {
                            TextField("日期 YYYY-MM-DD", text: $manualSnapshotDate)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("当日真实总资产", text: $manualSnapshotTotal).keyboardType(.decimalPad)
                            Text("只需录入总资产。现金会沿用该日已有快照；新建日期会参考最近一条历史快照。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !snapshotEditorError.isEmpty {
                                Text(snapshotEditorError).font(.footnote).foregroundStyle(.red)
                            }
                            if !manualSnapshotDate.isEmpty,
                               let total = Double(manualSnapshotTotal), total.isFinite, total >= 0 {
                                Text("将保存总资产 \(total.cny())，并用于后续区间收益计算。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("修正历史快照")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showManualSnapshotEditor = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    do {
                                        try store.recordManualSnapshot(date: manualSnapshotDate,
                                            total: Double(manualSnapshotTotal) ?? .nan)
                                        snapshotBackfillMessage = "已保存并标记为手动核实：\(manualSnapshotDate)"
                                        snapshotEditorError = ""
                                        showManualSnapshotEditor = false
                                    } catch {
                                        snapshotEditorError = "保存失败：\(error.localizedDescription)"
                                    }
                                }
                                .disabled(manualSnapshotDate.isEmpty || Double(manualSnapshotTotal)?.isFinite != true || (Double(manualSnapshotTotal) ?? -1) < 0)
                            }
                        }
                    }
                    .themedSheetBackground()
                }
                .confirmationDialog("删除快照？", isPresented: Binding(get: { snapshotDeleteTarget != nil }, set: { if !$0 { snapshotDeleteTarget = nil } }), titleVisibility: .visible) {
                    Button("删除 \(snapshotDeleteTarget?.date ?? "") 的快照", role: .destructive) {
                        if let snapshotDeleteTarget { store.removeSnapshot(date: snapshotDeleteTarget.date) }
                        snapshotDeleteTarget = nil
                    }
                    Button("取消", role: .cancel) { snapshotDeleteTarget = nil }
                } message: {
                    Text("只删除这一天的资产记录，不会删持仓、流水或行情历史。")
                }
                .confirmationDialog("清除全部历史重建快照？", isPresented: $showClearReconstructedSnapshots, titleVisibility: .visible) {
                    Button("清除历史重建快照", role: .destructive) {
                        let count = store.removeReconstructedSnapshots()
                        snapshotBackfillMessage = count > 0 ? "已清除 \(count) 个历史重建快照。" : "没有可清除的历史重建快照。"
                    }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("只清除“历史重建”标记的快照；你手动记录、已结算或临时快照都会保留。")
                }
        }
    }

    private func beginManualSnapshotEdit() {
        if manualSnapshotDate.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd"
            manualSnapshotDate = formatter.string(from: .now)
        }
        if manualSnapshotTotal.isEmpty { manualSnapshotTotal = store.totalAsset.num(2) }
        snapshotEditorError = ""
        showManualSnapshotEditor = true
    }

    @MainActor private func manuallyRefreshAssets() async {
        refreshFeedback.begin("正在刷新资产行情…")
        let ok = await store.refreshQuotesAndWait()
        refreshFeedback.finish(ok ? "资产行情已更新" : store.sourceStatus, succeeded: ok)
    }

    // MARK: - 资产构成

    /// 现金流记录里转入与转出相抵后的净额。没有记录时是 0，不臆测。
    private var netDeposit: Double { store.data.cashFlows.reduce(0) { $0 + $1.amount } }

    /// 主题深浅决定卡片色的透明度档位。
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    /// 「历史快照」卡的取色依据：所选区间的实测收益（没有快照时为 nil → 中性卡面）。
    private var snapshotMonthPnL: Double? { store.snapshotMonthSummary(selectedSnapshotMonth)?.pnl }
    /// 「ETF / 证券已实现收益」卡的取色依据：所选月份已落袋盈亏合计。
    private var ledgerMonthRealized: Double {
        store.ledgerDailyRealized(month: selectedLedgerMonth).reduce(0) { $0 + $1.profit }
    }

    /// 「账户总览」卡的当日盈亏取色依据：场内 + 场外的合计数（都没有时中性）。
    private var dayTone: Color {
        guard store.hasDayPnLGross else { return .secondary }
        return PnLColor.of(store.dayPnLGross)
    }

    /// 市值按 ETF/证券、场外基金、现金三段拆分。比「一个总数」更能看出钱压在哪。
    private var assetComposition: some View {
        let total = max(store.totalAsset, 0.0001)
        let etf = max(store.marketValue(of: .etf), 0)
        let fund = max(store.marketValue(of: .fund), 0)
        let cash = max(store.data.cash, 0)
        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(Color(red: 0.22, green: 0.53, blue: 0.90), width: geo.size.width * (etf / total))
                    segment(Color(red: 0.55, green: 0.42, blue: 0.90), width: geo.size.width * (fund / total))
                    segment(Color(red: 0.15, green: 0.75, blue: 0.62), width: geo.size.width * (cash / total))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 9)
            HStack(spacing: 12) {
                legend(Color(red: 0.22, green: 0.53, blue: 0.90), "ETF/证券", etf / total)
                legend(Color(red: 0.55, green: 0.42, blue: 0.90), "场外基金", fund / total)
                legend(Color(red: 0.15, green: 0.75, blue: 0.62), "现金", cash / total)
            }
        }
    }

    private func segment(_ color: Color, width: CGFloat) -> some View {
        Capsule().fill(color).frame(width: max(0, width))
    }

    private func legend(_ color: Color, _ title: String, _ ratio: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).scaledFont(9).foregroundStyle(.secondary)
            Text((ratio * 100).num(0) + "%").scaledFont(9, weight: .semibold).monospacedDigit()
        }
    }
}

struct CashFlowEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var isDeposit = true
    @State private var amount = ""
    @State private var memo = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("方向", selection: $isDeposit) {
                    Text("转入").tag(true); Text("转出").tag(false)
                }.pickerStyle(.segmented)
                TextField("金额", text: $amount).keyboardType(.decimalPad)
                TextField("备注（可选）", text: $memo)
                LabeledContent("当前参考现金", value: (store.data.cash).cny())
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Text("这里只记录账户外部转入/转出，用于从快照变化中剔除入金影响；不会连接券商。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("现金流记录")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }
    private func save() {
        guard let value = Double(amount), value.isFinite, value > 0 else { error = "请输入大于 0 的有效金额"; return }
        do { try store.adjustCash(amount: isDeposit ? value : -value, memo: memo); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ETFIncomeLine: Identifiable {
    var code: String
    var name: String
    var profit: Double
    var base: Double
    var hasTradeHistory: Bool
    var id: String { code }
}

private struct ETFIncomeDay: Identifiable {
    var date: String
    var profit = 0.0
    var base = 0.0
    var lines: [ETFIncomeLine] = []
    var id: String { date }
}

struct ETFIncomeCalendarView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var monthOffset = 0
    @State private var scale = 0
    @State private var yearOffset = 0
    @State private var days: [ETFIncomeDay] = []
    @State private var selectedDate: String?
    @State private var loading = false
    @State private var failedCount = 0
    @State private var staleCount = 0
    @State private var showRate = false
    @State private var tradingDates = Set<String>()
    @State private var coverageStart: String?
    @State private var coverageEnd: String?

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return value
    }
    private var monthDate: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: .now) ?? .now
    }
    private var monthKey: String { formatted(monthDate, format: "yyyy-MM") }
    private var displayedYear: Int { calendar.component(.year, from: .now) + yearOffset }
    private var yearKey: String { String(displayedYear) }
    private var startDay: String {
        if scale == 0 { return monthKey + "-01" }
        if scale == 1 { return yearKey + "-01-01" }
        return String(displayedYear - 2) + "-01-01"
    }
    private var endDay: String {
        if scale == 0 {
            let next = calendar.date(byAdding: .month, value: 1, to: monthDate) ?? monthDate
            return formatted(calendar.date(byAdding: .day, value: -1, to: next) ?? next, format: "yyyy-MM-dd")
        }
        return yearKey + "-12-31"
    }
    private var taskKey: String { "\(scale)-\(scale == 0 ? monthKey : yearKey)" }
    private var selectedPeriodDays: [ETFIncomeDay] {
        guard let selectedDate else { return [] }
        return days.filter { scale == 0 ? $0.date == selectedDate : $0.date.hasPrefix(selectedDate) }
    }
    private var selectedPeriodLines: [ETFIncomeLine] {
        var grouped: [String: ETFIncomeLine] = [:]
        for day in selectedPeriodDays { for line in day.lines {
            var item = grouped[line.code] ?? ETFIncomeLine(code: line.code, name: line.name, profit: 0, base: 0, hasTradeHistory: line.hasTradeHistory)
            item.profit += line.profit; item.base += line.base; grouped[line.code] = item
        } }
        return grouped.values.sorted { $0.profit > $1.profit }
    }
    private var dayByDate: [String: ETFIncomeDay] {
        days.reduce(into: [String: ETFIncomeDay]()) { $0[$1.date] = $1 }
    }
    private var gridDates: [String?] {
        guard let first = parseDay(startDay), let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday + 5) % 7 // Monday-first; Calendar's Sunday is 1.
        var cells: [String?] = Array(repeating: nil, count: leading)
        for day in 0..<count {
            if let date = calendar.date(byAdding: .day, value: day, to: first) {
                cells.append(formatted(date, format: "yyyy-MM-dd"))
            }
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
    private var monthlyProfit: Double { days.reduce(0) { $0 + $1.profit } }
    private var monthlyRate: Double? {
        let daily = days.filter { $0.base > 0 }
        guard !daily.isEmpty else { return nil }
        return (daily.reduce(1.0) { $0 * (1 + $1.profit / $1.base) } - 1) * 100
    }
    private var selectedPeriodProfit: Double { selectedPeriodDays.reduce(0) { $0 + $1.profit } }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("周期", selection: $scale) {
                        Text("按日").tag(0); Text("按月").tag(1); Text("按年").tag(2)
                    }.pickerStyle(.segmented).onChange(of: scale) { _, _ in selectedDate = nil }
                    HStack {
                        Button { if scale == 0 { monthOffset -= 1 } else { yearOffset -= 1 } } label: { Image(systemName: "chevron.left") }
                        Spacer(); Text(scale == 0 ? monthKey : yearKey).font(.headline)
                        Spacer(); Button { if scale == 0 { monthOffset += 1 } else { yearOffset += 1 } } label: { Image(systemName: "chevron.right") }
                    }
                    Picker("显示", selection: $showRate) {
                        Text("金额").tag(false); Text("收益率").tag(true)
                    }.pickerStyle(.segmented)
                    if days.isEmpty && !loading {
                        Text("本月没有足够的日 K 或持仓数据可核算。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if !days.isEmpty {
                        LabeledContent(scale == 0 ? "月累计收益" : (scale == 1 ? "年累计收益" : "近三年收益"), value: "\((monthlyProfit).directionMark()) \((monthlyProfit).cny())")
                            .foregroundStyle(PnLColor.of(monthlyProfit))
                        if let monthlyRate {
                            LabeledContent("复合收益率", value: monthlyRate.directionMark() + monthlyRate.pct(2))
                        } else { LabeledContent("复合收益率", value: "—") }
                    }
                    if loading { ProgressView("正在更新 ETF 日 K…") }
                    else if failedCount > 0 {
                        Text("有 \(failedCount) 只标的未取得日 K。日历不会把缺失行情当成 0 收益；检查网络后点右上角刷新。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if staleCount > 0 {
                        Text("有 \(staleCount) 只标的未更新到最近已知交易日，当前收益可能缺少最近一天；显示的是本机缓存。")
                            .font(.footnote).foregroundStyle(CardTone.warn)
                    }
                    Text("按最新前复权日 K 收盘价及交易流水反推每日持仓；不拆分成交价差与手续费，也不写入账本。没有完整流水的手动初始持仓按当前份额估算。“休市”按周末及已取得日 K 的覆盖区间推断，覆盖区间外或缺少行情的日期显示横线。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(CardTone.pnl(monthlyProfit), isLight: isLight)
                Section("交易日") {
                    if scale == 0 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        ForEach(Array(gridDates.enumerated()), id: \.offset) { item in
                            if let date = item.element {
                                let day = dayByDate[date]
                                Button { selectedDate = date } label: {
                                    VStack(spacing: 3) {
                                        Text(String(date.suffix(2)))
                                        if let day {
                                            Text(showRate && day.base > 0 ? String(format: "%.1f%%", day.profit / day.base * 100) : String(format: "%.0f", day.profit))
                                                .scaledFont(8, weight: .medium)
                                                .lineLimit(1).minimumScaleFactor(0.65)
                                        } else {
                                            Text(statusText(for: date)).scaledFont(7)
                                                .lineLimit(1).minimumScaleFactor(0.65)
                                                .foregroundStyle(statusText(for: date) == "休市" ? .secondary : .tertiary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(selectedDate == date ? Color.accentColor.opacity(0.2) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(day == nil ? Color.secondary : ((day?.profit ?? 0) >= 0 ? Color.red : Color.green))
                                }.buttonStyle(.plain)
                            } else { Color.clear.frame(height: 42) }
                        }
                    }
                    if let date = selectedDate, let day = dayByDate[date] {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(date) · \((day.profit).cny())")
                                .font(.headline).foregroundStyle(day.profit >= 0 ? .red : .green)
                            ForEach(day.lines) { line in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.name)
                                        Text(line.hasTradeHistory ? "按流水反推份额" : "按当前份额估算")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text((line.profit).cny())
                                        .foregroundStyle(line.profit >= 0 ? .red : .green)
                                }
                            }
                        }.padding(.vertical, 4)
                    } else if let date = selectedDate {
                        Text(statusText(for: date) == "休市" ? "\(date) · 休市" : "\(date) 没有足够的行情或持仓数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    } else if scale == 1 {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                            ForEach(1...12, id: \.self) { month in
                                let key = String(format: "%04d-%02d", displayedYear, month)
                                let value = days.filter { $0.date.hasPrefix(key) }.reduce(0) { $0 + $1.profit }
                                Button { selectedDate = key } label: { VStack(spacing: 5) { Text("\(month)月"); Text(value.cny()).font(.caption).lineLimit(1).minimumScaleFactor(0.7) }.frame(maxWidth: .infinity, minHeight: 54).background(selectedDate == key ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(PnLColor.of(value)) }.buttonStyle(.plain)
                            }
                        }
                        if let key = selectedDate { periodDetail(key: key, title: "\(key) 月度明细") }
                    } else {
                        let years = Array(Set(days.map { String($0.date.prefix(4)) })).sorted(by: >)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                            ForEach(years, id: \.self) { key in
                                let value = days.filter { $0.date.hasPrefix(key) }.reduce(0) { $0 + $1.profit }
                                Button { selectedDate = key } label: { VStack(spacing: 5) { Text(key); Text(value.cny()).font(.caption) }.frame(maxWidth: .infinity, minHeight: 54).background(selectedDate == key ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(PnLColor.of(value)) }.buttonStyle(.plain)
                            }
                        }
                        if let key = selectedDate { periodDetail(key: key, title: "\(key) 年度明细") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("ETF 收益日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadMonth() } } label: {
                        if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(loading)
                    .accessibilityLabel("刷新 ETF 日收益")
                }
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } }
            }
            .task(id: taskKey) { await loadMonth() }
        }
    }

    @MainActor private func loadMonth() async {
        loading = true
        defer { loading = false }
        tradingDates = []
        coverageStart = nil
        coverageEnd = nil
        failedCount = 0
        staleCount = 0
        // 用上证日 K 刷新最近实际交易日，判断某只 ETF 的日 K 是否仍停在昨天之前。
        await store.refreshTradingCalendar()
        let latestKnownTradingDay = MarketCalendar.loadTradingDays().max()
        let active = store.data.holdings.filter { $0.kind == .etf }
        let activeCodes = Set(active.map(\.code))
        let trades = store.data.ledger.filter { entry in
            entry.kind == .etf || (entry.kind == nil && activeCodes.contains(entry.code))
        }
        var currentShares: [String: Double] = [:]
        active.forEach { currentShares[$0.code, default: 0] += $0.quantity }
        let tradeCodes = Set(trades.map(\.code))
        let monthTradeCodes = Set(trades.filter {
            let date = formatted($0.date, format: "yyyy-MM-dd")
            return date >= startDay && date <= endDay
        }.map(\.code))
        let heldAtMonthStartCodes = tradeCodes.filter { code in
            let netAfterStart = trades.filter { $0.code == code && formatted($0.date, format: "yyyy-MM-dd") > startDay }
                .reduce(0.0) { $0 + ($1.side == .buy ? $1.quantity : -$1.quantity) }
            return (currentShares[code] ?? 0) - netAfterStart > 0
        }
        let candidateCodes = activeCodes.union(monthTradeCodes).union(heldAtMonthStartCodes).sorted()
        var output: [String: ETFIncomeDay] = [:]
        var failures = 0

        for code in candidateCodes {
            do {
                // Calendar data must be current: the default fetch path returns a local
                // cache immediately, which can silently omit yesterday's completed bar.
                let bars = try await store.fetchDailyBars(code: code, count: 640, force: true)
                guard bars.count > 1 else { failures += 1; continue }
                if let first = bars.first?.date, coverageStart.map({ first < $0 }) ?? true { coverageStart = first }
                if let last = bars.last?.date, coverageEnd.map({ last > $0 }) ?? true { coverageEnd = last }
                tradingDates.formUnion(bars.map(\.date).filter { $0 >= startDay && $0 <= endDay })
                if let latestKnownTradingDay,
                   latestKnownTradingDay >= startDay, latestKnownTradingDay <= endDay,
                   (bars.last?.date ?? "") < latestKnownTradingDay {
                    staleCount += 1
                }
                for index in 1..<bars.count {
                    let previous = bars[index - 1]
                    let today = bars[index]
                    guard today.date >= startDay, today.date <= endDay,
                          previous.close > 0, today.close > 0 else { continue }
                    let laterNet = trades.filter { $0.code == code && formatted($0.date, format: "yyyy-MM-dd") > previous.date }
                        .reduce(0.0) { total, entry in
                            total + (entry.side == .buy ? entry.quantity : -entry.quantity)
                        }
                    let shares = max(0, (currentShares[code] ?? 0) - laterNet)
                    guard shares > 0 else { continue }
                    let profit = (today.close - previous.close) * shares
                    let base = previous.close * shares
                    var row = output[today.date] ?? ETFIncomeDay(date: today.date)
                    row.profit += profit
                    row.base += base
                    row.lines.append(ETFIncomeLine(code: code,
                        name: active.first(where: { $0.code == code })?.name
                            ?? trades.first(where: { $0.code == code })?.name ?? code,
                        profit: profit, base: base, hasTradeHistory: tradeCodes.contains(code)))
                    output[today.date] = row
                }
            } catch { failures += 1 }
        }
        days = output.values.sorted { $0.date < $1.date }
        failedCount = failures
        // Refresh/reopen should land on the latest day with a calculated result;
        // otherwise a stale selection (e.g. Friday) can hide the newly loaded Monday detail.
        selectedDate = scale == 0 ? days.last?.date : (scale == 1 ? monthKey : yearKey)
    }

    @ViewBuilder private func periodDetail(key: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(selectedPeriodProfit.directionMark() + selectedPeriodProfit.cny())
                    .font(.headline.monospacedDigit()).foregroundStyle(PnLColor.of(selectedPeriodProfit))
            }
            if selectedPeriodLines.isEmpty {
                Text("该周期暂无可核算的 ETF 收益明细。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(selectedPeriodLines) { line in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.name).lineLimit(1)
                            Text("\(line.code) · \(line.hasTradeHistory ? "按交易流水还原" : "按当前份额估算")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(line.profit.directionMark() + line.profit.cny())
                                .foregroundStyle(PnLColor.of(line.profit))
                            Text(line.base > 0 ? (line.profit / line.base * 100).pct(2) : "—")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
    private func statusText(for date: String) -> String {
        guard let parsed = parseDay(date) else { return "—" }
        if MarketCalendar.isClosure(parsed, custom: store.data.customMarketHolidays) { return "休市" }
        if let coverageStart, let coverageEnd, date >= coverageStart, date <= coverageEnd,
           !tradingDates.contains(date) { return "休市" }
        return "—"
    }
    private func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

private struct ToolShortcut: Identifiable {
    let title: String
    let anchor: String
    var id: String { anchor }
}

struct ToolsView: View {
    let initialAnchor: String?
    let title: String
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guanpan.native.tools.showAll") private var showAllTools = false
    @State private var shockPercent = 20
    @State private var showShockDetails = false
    @State private var showRebalanceDetails = false
    @State private var showGrid = false
    @State private var showLongGridPlanner = false
    @State private var showAIAnalysis = false
    @State private var showPortrait = false
    @State private var showLedgerHealth = false
    @State private var showTradePlans = false
    @State private var showOverlap = false
    @State private var showAddCash = false
    @State private var showFundReplay = false
    @State private var showQuantEngine = false
    @State private var showTradeCSVImport = false
    @State private var showETFIncomeCalendar = false
    @State private var showDividendCalendar = false
    @State private var showPortfolioAnalysis = false
    @State private var showTradePreview = false
    @State private var showReturnSource = false
    @State private var showHistoricalReplay = false
    @State private var showIntradayArchive = false
    @State private var showDataTrust = false
    @State private var showReconciliation = false
    @State private var showTradeLedger = false
    @State private var showMonthlyReview = false
    @State private var showYearlyReview = false
    @State private var showPortfolioScenario = false
    @State private var targetEdit: Holding?

    init(initialAnchor: String? = nil, title: String = "工具") {
        self.initialAnchor = initialAnchor
        self.title = title
    }

    /// 主题深浅决定卡片色的透明度档位。
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    /// 统一冲击情景下全部持仓的假设损失（正数）。
    /// 提到视图层是为了让 Section 的 `.toneCard(...)` 能取到它——
    /// Section 的修饰器在闭包之外，读不到闭包里 `let loss = …` 的局部变量。
    private var shockLoss: Double {
        store.data.holdings.reduce(0.0) { $0 + max(0, $1.marketValue) * Double(shockPercent) / 100 }
    }
    /// 单只仓位上限 / 均线提示里已触发的条数。
    private var limitBreachCount: Int {
        store.data.holdings.filter { holding in
            guard holding.kind == .etf else { return false }
            if let limit = holding.maxPositionPercent, store.allocationActualPercent(for: holding) > limit { return true }
            if let period = holding.maWarningPeriod {
                let bars = store.dailyBars[holding.code] ?? []
                if bars.count >= period, let latest = bars.last {
                    let ma = bars.suffix(period).map(\.close).reduce(0, +) / Double(period)
                    if latest.close < ma { return true }
                }
            }
            return false
        }.count
    }
    /// 已达到再平衡偏离阈值的持仓数（与「再平衡偏离提醒」分区同口径）。
    private var rebalanceBreachCount: Int {
        let threshold = Double(store.data.rebalanceAlertThreshold)
        return store.data.holdings.filter { holding in
            guard let target = store.data.allocationTargets
                .first(where: { $0.code == holding.code && $0.kind == holding.kind })?.targetPercent else { return false }
            return abs(store.allocationActualPercent(for: holding) - target) >= threshold
        }.count
    }

    private let toolAnchors: [ToolShortcut] = [
        ToolShortcut(title: "风险", anchor: "tools-risk"),
        ToolShortcut(title: "收益", anchor: "tools-returns"),
        ToolShortcut(title: "目标", anchor: "tools-targets"),
        ToolShortcut(title: "网格", anchor: "tools-grid"),
        ToolShortcut(title: "AI", anchor: "tools-ai"),
        ToolShortcut(title: "数据", anchor: "tools-data"),
        ToolShortcut(title: "交易", anchor: "tools-trades"),
        ToolShortcut(title: "基金", anchor: "tools-funds")
    ]
    var body: some View {
        NavigationStack {
            List {
                if title == "分析工具" {
                    Section("风险与决策") { Button("资产穿透与分市场压力测试") { showPortfolioAnalysis = true }; Button("交易前沙盘") { showTradePreview = true }; Button("账户画像") { showPortrait = true } }
                    Section("信号与数据质量") { Button("日线量化信号") { showQuantEngine = true }; Button("数据可信度") { showDataTrust = true }; Button("运行账本体检") { showLedgerHealth = true }; Button("现金、盈亏与成本对账") { showReconciliation = true } }
                    Section("持仓结构") { Button("ETF / 基金成分重叠") { showOverlap = true }; Button("换仓情景试算") { showPortfolioScenario = true } }
                } else {
                    Section("计划") { Button("交易计划记录（\(store.data.tradePlans.count)）") { showTradePlans = true }; Button("日内网格计划与回放") { showGrid = true }; Button("中长期网格计划") { showLongGridPlanner = true }; Button("新增资金加仓试算") { showAddCash = true } }
                    Section("收益与复盘") { Button("ETF 每日收益日历") { showETFIncomeCalendar = true }; Button("分红日历") { showDividendCalendar = true }; Button("收益来源拆解") { showReturnSource = true }; Button("历史状态回放") { showHistoricalReplay = true }; Button("月度投资复盘") { showMonthlyReview = true }; Button("年度账单") { showYearlyReview = true } }
                    Section("历史数据") { Button("分时采集与历史复盘") { showIntradayArchive = true }; Button("导入券商成交") { showTradeCSVImport = true }; Button("全部交易流水") { showTradeLedger = true }; Button("基金定投回放") { showFundReplay = true } }
                }
            }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .appListLayout()
        .listRowBackground(Color.clear)
        .buttonStyle(.plain)
        .background(.clear).navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.palette(for: store.resolvedAppearance).surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showGrid) { DayGridView().themedSheetBackground() }
            .sheet(isPresented: $showLongGridPlanner) { StrategicGridPlannerView().environmentObject(store).themedSheetBackground() }
            .sheet(isPresented: $showAIAnalysis) { AIAnalysisView() .themedSheetBackground() }
            .sheet(isPresented: $showPortrait) { AccountPortraitView() .themedSheetBackground() }
            .sheet(isPresented: $showLedgerHealth) { LedgerHealthView() .themedSheetBackground() }
            .sheet(isPresented: $showTradePlans) { TradePlansView() .themedSheetBackground() }
            .sheet(isPresented: $showOverlap) { ETFOverlapView() .themedSheetBackground() }
            .sheet(isPresented: $showAddCash) { AddCashSimulationView() .themedSheetBackground() }
            .sheet(isPresented: $showFundReplay) { FundDCAReplayView() .themedSheetBackground() }
            .sheet(isPresented: $showQuantEngine) { QuantitativeEngineView() .themedSheetBackground() }
            .sheet(isPresented: $showTradeCSVImport) { TradeCSVImportView() .themedSheetBackground() }
            .sheet(isPresented: $showETFIncomeCalendar) { ETFIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showDividendCalendar) { DividendCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showPortfolioAnalysis) { PortfolioAnalysisView() .themedSheetBackground() }
            .sheet(isPresented: $showTradePreview) { TradePreviewView() .themedSheetBackground() }
            .sheet(isPresented: $showReturnSource) { ReturnSourceView() .themedSheetBackground() }
            .sheet(isPresented: $showHistoricalReplay) { HistoricalReplayView() .themedSheetBackground() }
            .sheet(isPresented: $showIntradayArchive) { IntradayArchiveView() .themedSheetBackground() }
            .sheet(isPresented: $showDataTrust) { DataTrustView() .themedSheetBackground() }
            .sheet(isPresented: $showReconciliation) { ReconciliationView() .themedSheetBackground() }
            .sheet(isPresented: $showTradeLedger) { TradeLedgerManagementView() .themedSheetBackground() }
            .sheet(isPresented: $showMonthlyReview) { MonthlyReviewView() .themedSheetBackground() }
            .sheet(isPresented: $showYearlyReview) { YearlyReviewView() .themedSheetBackground() }
            .sheet(isPresented: $showPortfolioScenario) { PortfolioScenarioView() .themedSheetBackground() }
            .sheet(item: $targetEdit) { holding in
                AllocationTargetEditor(holding: holding,
                    targetPercent: store.data.allocationTargets.first { $0.code == holding.code && $0.kind == holding.kind }?.targetPercent)
                    .themedSheetBackground()
            }
        }
    }
}

/// A hypothetical ETF/stock share-count editor. It intentionally has no action
/// that writes the simulated result back into the account ledger.
struct PortfolioScenarioView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var quantities: [String: String] = [:]
    @State private var addedQuotes: [String: Quote] = [:]

    private var instruments: [(id: String, code: String, name: String, price: Double, dividend: Double, baseline: Double)] {
        let held = store.data.holdings.filter { $0.kind == .etf }
        let base = held.map { holding in
            (id: holding.id, code: holding.code, name: holding.name, price: holding.current,
             dividend: annualDividend(for: holding.code, fallback: holding.annualDividendPerShare), baseline: holding.quantity)
        }
        let heldCodes = Set(held.map(\.code))
        let extra = addedQuotes.values.filter { !heldCodes.contains($0.code) }.map { quote in
            (id: "etf-\(quote.code)", code: quote.code, name: quote.name, price: quote.price,
             dividend: annualDividend(for: quote.code, fallback: nil), baseline: 0.0)
        }
        return (base + extra).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func annualDividend(for code: String, fallback: Double?) -> Double {
        if let fallback, fallback.isFinite, fallback >= 0 { return fallback }
        let cutoff = ETFDividendProjection.yearAgoCutoff()
        return ETFDividendProjection.mergedEvents(store.data.etfDividendEvents)
            .filter { $0.code == code && $0.date >= cutoff && $0.isEstimated != true }
            .reduce(0) { $0 + $1.amountPerShare }
    }

    private func quantity(for id: String, fallback: Double) -> Double {
        guard let text = quantities[id] else { return fallback }
        guard let value = Double(text), value.isFinite else { return 0 }
        return max(0, value)
    }

    private func metrics(useBaseline: Bool) -> (market: Double, dividends: Double, effective: Double, maxWeight: Double, annualizedVolatility: Double?, categories: [(String, Double)]) {
        let entries = instruments.map { item -> (String, Double, Double) in
            let count = useBaseline ? item.baseline : quantity(for: item.id, fallback: item.baseline)
            return (item.code, max(0, item.price * count), max(0, item.dividend * count))
        }.filter { $0.1 > 0 }
        let market = entries.reduce(0) { $0 + $1.1 }
        let hhi = market > 0 ? entries.reduce(0) { $0 + pow($1.1 / market, 2) } : 0
        let maxWeight = market > 0 ? (entries.map { $0.1 / market }.max() ?? 0) : 0
        var categories = Dictionary(grouping: entries, by: { category(for: $0.0) }).mapValues { rows in
            rows.reduce(0) { $0 + $1.1 }
        }
        if store.data.cash > 0 { categories["现金"] = store.data.cash }
        let categoryRows = categories.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        let volatility = annualizedVolatility(for: entries.map { ($0.0, $0.1) }, market: market)
        return (market, entries.reduce(0) { $0 + $1.2 }, hhi > 0 ? 1 / hhi : 0, maxWeight, volatility, categoryRows)
    }

    private func annualizedVolatility(for positions: [(String, Double)], market: Double) -> Double? {
        guard market > 0, !positions.isEmpty else { return nil }
        var returnsByCode: [String: [String: Double]] = [:]
        for (code, value) in positions where value > 0 {
            let bars = (store.dailyBars[code] ?? []).sorted { $0.date < $1.date }
            guard bars.count >= 2 else { return nil }
            var returns: [String: Double] = [:]
            for index in 1..<bars.count {
                let previous = bars[index - 1].close
                let current = bars[index].close
                guard previous.isFinite, previous > 0, current.isFinite, current > 0 else { continue }
                returns[bars[index].date] = current / previous - 1
            }
            guard !returns.isEmpty else { return nil }
            returnsByCode[code] = returns
        }
        guard let first = returnsByCode.values.first else { return nil }
        var commonDates = Set(first.keys)
        for returns in returnsByCode.values.dropFirst() { commonDates.formIntersection(returns.keys) }
        guard commonDates.count >= 20 else { return nil }
        let daily = commonDates.sorted().map { date in
            positions.reduce(0.0) { total, position in
                total + position.1 / market * (returnsByCode[position.0]?[date] ?? 0)
            }
        }
        let mean = daily.reduce(0, +) / Double(daily.count)
        let variance = daily.reduce(0) { $0 + pow($1 - mean, 2) } / Double(daily.count - 1)
        return sqrt(max(0, variance) * 252) * 100
    }

    private func category(for code: String) -> String {
        if ["518880", "518800", "159934"].contains(code) { return "黄金" }
        if ["511260", "511010", "511090"].contains(code) { return "债券" }
        if ["159941", "513100", "159632", "513300", "513870"].contains(code) { return "美股大盘" }
        if ["159509"].contains(code) { return "美股科技" }
        if ["513050", "159605"].contains(code) { return "中概互联" }
        if ["159545", "513630", "520660", "513530", "513950"].contains(code) { return "港股" }
        if ["563020", "512890", "515100", "159307"].contains(code) { return "A股红利" }
        if ["159352", "510300", "510500", "159338", "512200"].contains(code) { return "A股宽基" }
        if ["588000", "159915", "159901", "588080"].contains(code) { return "科创/成长" }
        if ["512880"].contains(code) { return "证券" }
        return "其他 ETF / 证券"
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section("模拟份额") {
                    if instruments.isEmpty {
                        ContentUnavailableView("没有可模拟的持仓", systemImage: "chart.pie", description: Text("先添加 ETF 或证券持仓。"))
                    }
                    ForEach(instruments, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text("\(item.code) · 现价 \((item.price).num(3))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("份额", text: Binding(
                                    get: { quantities[item.id] ?? String(item.baseline) },
                                    set: { quantities[item.id] = $0 }
                                ))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                            }
                            HStack {
                                Text("模拟市值 \((item.price * quantity(for: item.id, fallback: item.baseline)).cny())")
                                Spacer()
                                if item.dividend > 0 {
                                    Text("已知年分红/份 \((item.dividend).num(3))")
                                } else {
                                    Text("无已知分红数据")
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !availableQuotes.isEmpty {
                        Menu("从自选添加") {
                            ForEach(availableQuotes) { quote in
                                Button("\(quote.name)（\(quote.code)）") { addedQuotes[quote.code] = quote }
                            }
                        }
                    }
                    if !instruments.isEmpty {
                        Button("恢复为当前持仓", systemImage: "arrow.counterclockwise") {
                            quantities.removeAll(); addedQuotes.removeAll()
                        }
                    }
                }
                .plainCard(isLight: isLight)

                Section("当前持仓 → 模拟组合") {
                    let before = metrics(useBaseline: true)
                    let after = metrics(useBaseline: false)
                    comparison("ETF/证券市值", before.market.cny(), after.market.cny())
                    comparison("已知年分红", before.dividends.cny(), after.dividends.cny())
                    comparison("按持仓市值估算股息率",
                               (before.market > 0 ? before.dividends / before.market * 100 : 0).pct(2),
                               (after.market > 0 ? after.dividends / after.market * 100 : 0).pct(2))
                    comparison("有效持仓数", before.effective.num(2), after.effective.num(2))
                    comparison("最大单仓", (before.maxWeight * 100).pct(0), (after.maxWeight * 100).pct(0))
                    comparison("年化波动（共同日线）",
                               before.annualizedVolatility.map { String(format: "%.1f%%", $0) } ?? "数据不足",
                               after.annualizedVolatility.map { String(format: "%.1f%%", $0) } ?? "数据不足")
                    ForEach(Array(after.categories.enumerated()), id: \.offset) { item in
                        LabeledContent("模拟 · \(item.element.0)", value: (after.market + max(0, store.data.cash) > 0 ? item.element.1 / (after.market + max(0, store.data.cash)) * 100 : 0).pct(1))
                    }
                    Text("波动率只使用所有模拟持仓都有记录的共同日线日期，至少 20 个共同收益点才显示；数据不足时不填默认相关系数。分红只汇总原生账本中的每份年分红设置或近 365 天已录入 ETF 分红事件；缺失的分红不会外推。集中度仅按 ETF/证券市值计算。模拟不会改变账户现金、持仓、交易记录或同步数据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(CardTone.accent, isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("换仓情景试算")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var availableQuotes: [Quote] {
        let existing = Set(instruments.map(\.code))
        return store.data.quotes.filter { !existing.contains($0.code) && $0.price > 0 }
    }

    private func comparison(_ title: String, _ before: String, _ after: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(before).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(after).fontWeight(.semibold)
        }
    }
}

struct DividendCalendarView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: .now)

    private var etfEvents: [(ETFDividendEvent, Holding?, Double)] {
        ETFDividendProjection.mergedEvents(store.data.etfDividendEvents).filter { $0.date.hasPrefix(String(year)) }.map { event in
            let holding = store.data.holdings.first { $0.code == event.code && $0.kind == .etf }
            let estimated = event.isEstimated == true ? 0 : event.amountPerShare * (holding?.quantity ?? 0)
            return (event, holding, estimated)
        }.sorted { $0.0.date == $1.0.date ? $0.0.code < $1.0.code : $0.0.date < $1.0.date }
    }
    private var annualEstimateRows: [(Holding, Double?, ETFDividendProjection.Source?)] {
        return store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }.map { holding in
            guard let projection = ETFDividendProjection.projectedAnnualPerShare(for: holding,
                                                                                 events: store.data.etfDividendEvents),
                  projection.amount > 0 else { return (holding, nil, nil) }
            return (holding, projection.amount, projection.source)
        }
    }

    /// 近 12 个月**已核实**派息折成的年现金收入。
    ///
    /// `HoldingsView` 里有同名计算属性，但两边都是 private，跨类型访问不到
    /// （直接引用会报 `cannot find 'etfAnnualDividendIncome' in scope`）。
    /// 这里按同一口径重算：`recordedAnnualPerShare` 只认已记录的**真实**派息，
    /// 不做指数股息率外推，与模块概览的"实际派息"一致。
    private var etfAnnualDividendIncome: Double {
        store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }.reduce(0) { total, holding in
            let perShare = ETFDividendProjection.recordedAnnualPerShare(for: holding,
                                                                        events: store.data.etfDividendEvents)?.amount ?? 0
            return total + holding.quantity * perShare
        }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Stepper("年份：\(year)", value: $year, in: 2000...2100)
                    LabeledContent("已记录派息金额", value: (etfEvents.reduce(0) { $0 + $1.2 }).cny())
                    LabeledContent("近12个月已核实派息", value: etfAnnualDividendIncome.cny())
                } header: { Text("年度汇总") }
                    .plainCard(isLight: isLight)
                Section("场内 ETF 历史事件") {
                    if etfEvents.isEmpty { Text("没有迁入该年度的 ETF 分红事件。") .foregroundStyle(.secondary) }
                    ForEach(Array(etfEvents.enumerated()), id: \.offset) { item in
                        let (event, holding, estimated) = item.element
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(holding?.name ?? event.code) · \(event.date)")
                            Text(event.isEstimated == true
                                 ? "复权价格推算每份 \(event.amountPerShare.num(4)) 元 · 不是已核实的现金派息"
                                 : "每份 \(event.amountPerShare.num(4)) 元 · 按当前份额估算 \(estimated.cny())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("旧版迁入记录按复权价格推算，只作历史参考，不计入实际派息；只有已记录的现金分红才计入股息金额。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section("当前持仓分红参考") {
                    if annualEstimateRows.isEmpty { Text("暂无场内 ETF 持仓。") .foregroundStyle(.secondary) }
                    ForEach(Array(annualEstimateRows.enumerated()), id: \.offset) { item in
                        let (holding, perShare, source) = item.element
                        VStack(alignment: .leading, spacing: 3) {
                            Text(holding.name)
                            if let perShare, let source {
                                Text("每份 \(perShare.num(4)) 元 · 股息率 \((holding.current > 0 ? perShare / holding.current * 100 : 0).num(2))% · 未来12个月试算 \((perShare * holding.quantity).cny())")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(source == .manual ? "按人工核实值试算。" : source == .historicalAverage
                                     ? "按近三年实际派息年份平均试算；派息频率可能变化，金额不保证。"
                                     : source == .inferred
                                     ? "按复权价格变化估算，不能确认现金派息，金额仅供参考。"
                                     : "按近12个月已核实现金派息外推，不代表承诺。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                let hasRecordedHistory = ETFDividendProjection.mergedEvents(store.data.etfDividendEvents).contains {
                                    $0.code == holding.code && $0.isEstimated != true
                                }
                                Text(ETFDividendProjection.knownNonDividendCodes.contains(holding.code) || holding.annualDividendPerShare == 0
                                     ? "不分红 · 当前没有已确认的现金派息记录。"
                                     : hasRecordedHistory
                                     ? "有历史现金派息，但次数不足以估算稳定年股息；保留派息记录，不做年化预测。"
                                     : "待核实 · 尚无已迁入的派息记录，不能据此判断不分红。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("实际派息只统计近12个月已核实现金分红；未来试算按人工核实值或历史派息节奏计算。缺少事件数据会标为“待核实”，不会误判为不分红，也不按指数或名称猜测。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("分红日历")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct LedgerHealthView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [LedgerHealthFinding] = []
    @State private var isRunning = true
    @State private var runError = ""
    @State private var progressStage = "正在准备账本快照"
    @State private var healthCheckStartedAt = Date()

    private var errors: Int { findings.filter { $0.severity.rawValue == LedgerHealthFinding.Severity.error.rawValue }.count }
    private var warnings: Int { findings.filter { $0.severity.rawValue == LedgerHealthFinding.Severity.warning.rawValue }.count }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                if isRunning {
                    Section {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("正在体检账本").font(.headline)
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("已用时 \(max(0, Int(context.date.timeIntervalSince(healthCheckStartedAt)))) 秒")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            ProgressView()
                            Text("\(progressStage)。可以看到进度，界面没有卡住；数据较多时会稍久一些。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .plainCard(isLight: isLight)
                }
                Section("检查结果") {
                    LabeledContent("错误", value: isRunning ? "检查中" : "\(errors)")
                        .foregroundStyle(errors > 0 ? PnLColor.up : Color.primary)
                    LabeledContent("提醒", value: isRunning ? "检查中" : "\(warnings)")
                        .foregroundStyle(warnings > 0 ? CardTone.warn : Color.primary)
                    if !runError.isEmpty { Text(runError).font(.footnote).foregroundStyle(.red) }
                    Text("检查只读取本机数据。发现异常时，请先导出备份，再根据原始交易记录人工核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(errors > 0 ? PnLColor.up : (warnings > 0 ? CardTone.warn : CardTone.ok), isLight: isLight)
                Section("详细项目") {
                    if !isRunning && findings.isEmpty && runError.isEmpty {
                        Text("没有可显示的检查项目。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: finding.severity))
                                    .foregroundStyle(color(for: finding.severity))
                                Text(finding.category).font(.caption).foregroundStyle(.secondary)
                                Text(finding.title).font(.subheadline.weight(.medium))
                            }
                            if !finding.detail.isEmpty {
                                Text(finding.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .navigationTitle("账本体检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await runHealthCheck() }
        }
    }

    private func runHealthCheck() async {
        isRunning = true
        runError = ""
        healthCheckStartedAt = .now
        progressStage = "正在准备账本快照"
        // 先让弹窗和进度提示完成首帧，再开始制作只读快照。
        await Task.yield()
        do {
            let snapshot = try JSONEncoder().encode(store.data)
            let totalAsset = store.totalAsset
            progressStage = "正在核对持仓、流水和现金"
            await Task.yield()
            let result = try await Task.detached(priority: .userInitiated) {
                let data = try JSONDecoder().decode(PortfolioData.self, from: snapshot)
                return LedgerHealthAnalyzer.report(data: data, totalAsset: totalAsset)
            }.value
            progressStage = "正在整理检查结果"
            findings = result
        } catch {
            runError = "账本体检失败：\(error.localizedDescription)"
        }
        isRunning = false
    }

    private func icon(for severity: LedgerHealthFinding.Severity) -> String {
        switch severity {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: LedgerHealthFinding.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct ConstituentExposure: Identifiable {
    var code: String
    var name: String
    var exposure: Double
    var sources: [(name: String, percent: Double)]
    var id: String { code }
}

struct ETFOverlapView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var refreshFeedback = RefreshFeedbackModel()
    private var etfs: [Holding] { store.data.holdings.filter { $0.kind == .etf } }
    private var covered: [(Holding, [ETFConstituent])] {
        etfs.compactMap { holding in
            guard let rows = ETFConstituentLibrary.holdings[holding.code] else { return nil }
            return (holding, rows)
        }
    }
    private var exposureRows: [ConstituentExposure] {
        var grouped: [String: (name: String, value: Double, sources: [(String, Double)])] = [:]
        for (holding, constituents) in covered {
            let marketValue = max(0, holding.marketValue)
            for item in constituents {
                let amount = marketValue * item.weightPercent / 100
                var row = grouped[item.code] ?? (item.name, 0, [])
                row.value += amount
                row.sources.append((holding.name, item.weightPercent))
                grouped[item.code] = row
            }
        }
        for snapshot in store.data.fundConstituentSnapshots {
            guard let fund = store.data.holdings.first(where: { $0.kind == .fund && $0.code == snapshot.code }) else { continue }
            for item in snapshot.holdings {
                let amount = max(0, fund.marketValue) * item.weightPercent / 100
                var row = grouped[item.code] ?? (item.name, 0, [])
                row.value += amount
                row.sources.append((fund.name, item.weightPercent))
                grouped[item.code] = row
            }
        }
        return grouped.map { code, row in
            ConstituentExposure(code: code, name: row.name, exposure: row.value,
                sources: row.sources.sorted { $0.1 > $1.1 }.map { (name: $0.0, percent: $0.1) })
        }.sorted { $0.exposure > $1.exposure }
    }
    private var duplicates: [ConstituentExposure] { exposureRows.filter { $0.sources.count > 1 } }
    private var coveredWeight: Double {
        let etfWeight = covered.reduce(0) { $0 + $1.0.marketValue * $1.1.reduce(0) { $0 + $1.weightPercent } / 100 }
        let fundWeight = store.data.fundConstituentSnapshots.reduce(0.0) { total, snapshot in
            guard let fund = store.data.holdings.first(where: { $0.kind == .fund && $0.code == snapshot.code }) else { return total }
            return total + max(0, fund.marketValue) * snapshot.holdings.reduce(0) { $0 + $1.weightPercent } / 100
        }
        return etfWeight + fundWeight
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            List {
                Section("覆盖情况") {
                    LabeledContent("持有 ETF / 场外基金", value: "\(etfs.count) / \(store.data.holdings.filter { $0.kind == .fund }.count) 只")
                    LabeledContent("已有快照", value: "\(covered.count + store.data.fundConstituentSnapshots.count) 只")
                    LabeledContent("前十大对应市值", value: (coveredWeight).cny())
                    LabeledContent("重复成分敞口合计", value: (duplicates.reduce(0) { $0 + $1.exposure }).cny())
                    Text("ETF 快照：\(ETFConstituentLibrary.asOf)；场外基金按定期报告前十大（可取得时最多 50 只），报告日期见下方。未覆盖部分不代表没有重复持仓。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                if !store.data.holdings.filter({ $0.kind == .fund }).isEmpty {
                    Section("场外基金重仓") {
                        Button(store.isRefreshingFundHoldings ? "正在获取…" : "更新基金定期报告重仓") {
                            Task { await manuallyRefreshFundHoldings() }
                        }.disabled(store.isRefreshingFundHoldings)
                        Text(store.fundHoldingsStatus).font(.footnote).foregroundStyle(.secondary)
                        ForEach(store.data.fundConstituentSnapshots) { snapshot in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.name).font(.subheadline)
                                Text("\(snapshot.code) · 报告日期 \(snapshot.asOf.isEmpty ? "未提供" : snapshot.asOf) · \(snapshot.holdings.count) 项 · 更新于 \(snapshot.fetchedAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(snapshot.holdings.prefix(5).map { "\($0.name) \(String(format: "%.2f", $0.weightPercent))%" }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical, 2)
                        }
                    }
                    .plainCard(isLight: isLight)
                }
                Section("跨 ETF / 场外基金重复成分 · \(duplicates.count) 只") {
                    if duplicates.isEmpty { Text(covered.count + store.data.fundConstituentSnapshots.count < 2 ? "至少需要两只已有成分快照的持仓才能比较。" : "现有前十大快照中未发现重复成分。")
                        .foregroundStyle(.secondary) }
                    ForEach(duplicates) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(item.name).font(.headline); Spacer(); Text((item.exposure).cny()).font(.subheadline) }
                            Text("\(item.code) · 出现在 \(item.sources.count) 只 ETF")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.sources.map { String(format: "%@ %.2f%%", $0.name, $0.percent) }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
                .toneCard(CardTone.warnIf(!duplicates.isEmpty), isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .refreshFeedbackOverlay(refreshFeedback)
            .navigationTitle("ETF 持仓穿透")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    @MainActor private func manuallyRefreshFundHoldings() async {
        refreshFeedback.begin("正在更新基金定期报告重仓…")
        let ok = await store.refreshFundConstituentsAndWait()
        refreshFeedback.finish(store.fundHoldingsStatus, succeeded: ok)
    }
}

private struct AddCashRow: Identifiable {
    var holding: Holding
    var targetPercent: Double
    var gap: Double
    var quantity: Double
    var amount: Double
    var reason: String
    var id: String { holding.id }
}

private struct FundDCAReplaySummary {
    var code: String
    var firstDate: String
    var lastDate: String
    var contributions: Int
    var invested: Double
    var shares: Double
    var value: Double
    var lumpValue: Double
    var latestNAV: Double
    var dcaReturn: Double { invested > 0 ? (value / invested - 1) * 100 : 0 }
    var lumpReturn: Double { invested > 0 ? (lumpValue / invested - 1) * 100 : 0 }
}

struct FundDCAReplayView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var amountText = "500"
    @State private var months = 24
    private var funds: [Holding] { store.data.holdings.filter { $0.kind == .fund } }
    private var summary: FundDCAReplaySummary? {
        guard let amount = Double(amountText), amount.isFinite, amount > 0,
              !code.isEmpty else { return nil }
        let points = store.data.fundNAVHistory.filter { $0.code == code && $0.nav.isFinite && $0.nav > 0 }.sorted { $0.date < $1.date }
        guard let last = points.last, let lastDate = parse(last.date) else { return nil }
        let startDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: lastDate) ?? .distantPast
        let startKey = dayKey(startDate)
        let selected = points.filter { $0.date >= startKey }
        let grouped = Dictionary(grouping: selected, by: { String($0.date.prefix(7)) })
        let currentMonth = String(dayKey(.now).prefix(7))
        let contributions: [FundNAVPoint] = grouped.keys.sorted().compactMap { month in
            guard let rows = grouped[month]?.sorted(by: { $0.date < $1.date }) else { return nil }
            if let due = rows.first(where: { Int($0.date.suffix(2)) ?? 0 >= 15 }) { return due }
            return month == currentMonth ? nil : rows.last
        }
        guard let first = contributions.first, let end = points.last else { return nil }
        let invested = amount * Double(contributions.count)
        let shares = contributions.reduce(0.0) { $0 + amount / $1.nav }
        let value = shares * end.nav
        let lumpValue = (invested / first.nav) * end.nav
        guard [invested, shares, value, lumpValue].allSatisfy(\.isFinite) else { return nil }
        return FundDCAReplaySummary(code: code, firstDate: first.date, lastDate: end.date,
            contributions: contributions.count, invested: invested, shares: shares,
            value: value, lumpValue: lumpValue, latestNAV: end.nav)
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            Form {
                Section("回放参数") {
                    if funds.isEmpty { Text("先添加场外基金并更新已公布净值。") }
                    else {
                        Picker("基金", selection: $code) { ForEach(funds) { Text("\($0.name) · \($0.code)").tag($0.code) } }
                        TextField("每月投入（元）", text: $amountText).keyboardType(.decimalPad)
                        Picker("回溯区间", selection: $months) {
                            Text("近 1 年").tag(12); Text("近 2 年").tag(24); Text("近 3 年").tag(36); Text("全部历史").tag(1200)
                        }
                    }
                    Text("按每月 15 日或之后首个有净值的日期投入；若历史月份缺少该日期，使用该月最后一条已公布净值。一次性对照在首个定投日投入同样总额。未计申购费、赎回费、税费与现金分红再投。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                if let result = summary {
                    Section("历史结果 · \(result.firstDate) 至 \(result.lastDate)") {
                        LabeledContent("定投次数", value: "\(result.contributions)")
                        LabeledContent("累计投入", value: (result.invested).cny())
                        LabeledContent("期末份额", value: (result.shares).num(2))
                        LabeledContent("按最近净值折算", value: (result.value).cny())
                        LabeledContent("定投收益率", value: result.dcaReturn.directionMark() + result.dcaReturn.pct(2))
                        LabeledContent("一次性买入收益率", value: result.lumpReturn.directionMark() + result.lumpReturn.pct(2))
                        LabeledContent("最近已公布净值", value: (result.latestNAV).num(4))
                    }
                    .toneCard(CardTone.pnl(result.dcaReturn), isLight: isLight)
                } else if !funds.isEmpty {
                    Section { Text("当前净值历史不足以完成所选区间的回放，或投入金额无效。先刷新基金净值或缩短区间。")
                        .font(.footnote).foregroundStyle(.secondary) }
                        .toneCard(CardTone.warn, isLight: isLight)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("历史定投回放")
            .keyboardDoneToolbar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { if code.isEmpty { code = funds.first?.code ?? "" } }
        }
    }

    private func parse(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 带字段名、示例值和说明的数字输入行。
///
/// 中长期网格规划与新增资金加仓试算都用它。**字段名必须常显**（不能只当占位符）：
/// 占位符一填进内容就消失，用户回头根本不知道自己填的那个框是什么；
/// 所以这里是「字段名在上、示例值当占位符、说明在下面」，
/// 与「日内网格」的 `gridNumberField` 保持同一套观感。
struct NumberFieldWithHint: View {
    let title: String
    /// 占位符只放示例值（如 3000 / 1.5 / 0），不放整句话。
    let example: String
    let hint: String?
    @Binding var text: String
    let keyboard: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).scaledFont(10, weight: .medium).foregroundStyle(.secondary)
            TextField(example, text: $text)
                .keyboardType(keyboard)
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let hint {
                Text(hint)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AddCashSimulationView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var cashText = "10000"
    @State private var reserveText = "10"
    @State private var feeText = "0.10"
    @State private var hasRun = false
    @State private var rows: [AddCashRow] = []
    @State private var investable = 0.0
    @State private var spent = 0.0
    @State private var message = ""

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    var body: some View {
        NavigationStack {
            Form {
                Section("试算参数") {
                    NumberFieldWithHint(title: "新增资金（元）", example: "10000",
                                        hint: "这次打算新投入的金额，只用于试算，不会改动账户余额或持仓。",
                                        text: $cashText, keyboard: .decimalPad)
                    NumberFieldWithHint(title: "现金预留（%）", example: "10",
                                        hint: "从新增资金里留出多少不动，应付下跌补仓和临时用钱。填 10 就是只投 90%；填 0 是全投，满仓时遇到急跌会比较被动。",
                                        text: $reserveText, keyboard: .decimalPad)
                    NumberFieldWithHint(title: "每笔手续费（元）", example: "0.10",
                                        hint: "按「一笔」交易的固定费用估算，先扣费用再分配金额；买 N 只就算 N 笔。",
                                        text: $feeText, keyboard: .decimalPad)
                    Button("开始试算") { calculate() }
                    Text("ETF 使用 100 份整手。目标比例读取已设的持仓目标；未设置目标的标的按当前持仓占总资产比例分配。目标金额按总资产（含现金和基金）计算，场外基金不会被建议买卖。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(CardTone.warn) }
                        .toneCard(CardTone.warn, isLight: isLight)
                }
                if hasRun {
                    Section("预算") {
                        LabeledContent("可投入", value: (investable).cny())
                        LabeledContent("计划支出", value: (spent).cny())
                        LabeledContent("剩余", value: (max(0, (Double(cashText) ?? 0) - spent)).cny())
                    }
                    .plainCard(isLight: isLight)
                    Section("试算结果") {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(row.holding.name).font(.headline); Spacer(); Text(row.quantity > 0 ? "买 \(row.quantity.num(0)) 份" : row.reason).foregroundStyle(row.quantity > 0 ? .primary : .secondary) }
                                Text("目标 \((row.targetPercent).num(1))% · 缺口 \((row.gap).cny())")
                                    .font(.caption).foregroundStyle(.secondary)
                                if row.quantity > 0 { Text("估算金额 \((row.amount).cny())，不含或少量含手续费差异")
                                    .font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 3)
                        }
                    }
                    .toneCard(CardTone.accent, isLight: isLight)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("加仓试算")
            .keyboardDoneToolbar()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func calculate() {
        guard let cash = Double(cashText), cash.isFinite, cash > 0,
              let reserve = Double(reserveText), reserve.isFinite, (0...100).contains(reserve),
              let fee = Double(feeText), fee.isFinite, fee >= 0 else {
            message = "请输入有效资金、0–100% 的预留比例和非负手续费。"; hasRun = false; return
        }
        let holdings = store.data.holdings.filter { $0.kind == .etf && $0.current.isFinite && $0.current > 0 && $0.quantity.isFinite && $0.quantity >= 0 }
        guard !holdings.isEmpty else { message = "没有具备有效价格的 ETF 持仓可供试算。"; hasRun = false; return }
        let currentTotal = store.totalAsset
        investable = cash * (1 - reserve / 100)
        let postInvestmentTotal = currentTotal + investable
        var candidates: [(holding: Holding, target: Double, gap: Double, desired: Double)] = holdings.map { holding in
            let configured = store.data.allocationTargets.first { $0.code == holding.code && $0.kind == holding.kind }?.targetPercent
            let target = configured ?? (currentTotal > 0 ? holding.marketValue / currentTotal * 100 : 0)
            let gap = postInvestmentTotal * target / 100 - holding.marketValue
            let desired = gap > 0 ? max(0, (gap / holding.current / 100).rounded()) * 100 : 0
            return (holding, target, gap, desired)
        }.sorted { $0.gap > $1.gap }
        var remaining = investable
        var output: [AddCashRow] = []
        for candidate in candidates {
            let h = candidate.holding
            let requested = candidate.desired
            let maxLots = max(0, floor((remaining - fee) / h.current / 100)) * 100
            let quantity = min(requested, maxLots)
            let amount = quantity * h.current + (quantity > 0 ? fee : 0)
            remaining -= amount
            output.append(AddCashRow(holding: h, targetPercent: candidate.target, gap: candidate.gap,
                quantity: quantity, amount: amount,
                reason: candidate.gap <= 0 ? "已达目标" : (requested < 100 ? "缺口不足一手" : "预算不足")))
        }
        rows = output; spent = investable - remaining; hasRun = true; message = ""
    }
}

private struct TradePlanInstrument: Identifiable {
    var kind: Holding.Kind
    var code: String
    var name: String
    var id: String { "\(kind.rawValue)|\(code)" }
}

struct TradePlansView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var reviewTarget: TradePlan?

    private var plans: [TradePlan] { store.data.tradePlans.sorted { $0.created > $1.created } }

    var body: some View {
        NavigationStack {
            List {
                if plans.isEmpty { ContentUnavailableView("暂无交易计划", systemImage: "list.clipboard", description: Text("下单前记录理由、参考价与失效条件。")) }
                ForEach(plans) { plan in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(plan.name) · \(plan.side == .buy ? "买入" : "卖出")").font(.headline)
                            Spacer(); Text(statusName(plan.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(plan.kind == .fund ? "场外基金" : "ETF/证券") · \(plan.code) · \(plan.created)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("计划价 \((plan.price).num(3)) · 金额 \((plan.amount).cny())")
                            .font(.subheadline)
                        if let target = plan.target { Text("目标价 \((target).num(3))") }
                        if let invalid = plan.invalid { Text("失效价 \((invalid).num(3))") }
                        if !plan.reason.isEmpty { Text("理由：\(plan.reason)").font(.footnote) }
                        if !plan.trigger.isEmpty { Text("触发条件：\(plan.trigger)").font(.footnote) }
                        if let actualPrice = plan.actualPrice, let actualAmount = plan.actualAmount {
                            let variance = (plan.side == .sell ? plan.price - actualPrice : actualPrice - plan.price) * actualAmount / actualPrice
                            Text("执行价 \((actualPrice).num(3)) · 相对计划偏差 \((variance).cny())")
                                .font(.footnote).foregroundStyle(variance >= 0 ? .green : .orange)
                        }
                        if !plan.review.isEmpty { Text("复盘：\(plan.review)").font(.footnote).foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], alignment: .leading, spacing: 8) {
                            if plan.status != .cancelled {
                                Button(plan.status == .reviewed ? "修改复盘" : "记录执行/复盘") { reviewTarget = plan }
                                    .buttonStyle(.bordered)
                            }
                            if plan.status == .planned {
                                Button("取消计划", role: .destructive) { update(plan, status: .cancelled) }
                                    .buttonStyle(.bordered)
                            }
                            Button("删除", role: .destructive) {
                                store.data.tradePlans.removeAll { $0.id == plan.id }
                                store.save(label: "修改账本或设置")
                            }.buttonStyle(.bordered)
                        }.font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("交易计划与复盘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { showNew = true } }
            }
            .sheet(isPresented: $showNew) { TradePlanEditor { store.data.tradePlans.append($0); store.save(label: "修改账本或设置") } .themedSheetBackground() }
            .sheet(item: $reviewTarget) { plan in
                TradePlanReviewEditor(plan: plan) { changed in
                    if let index = store.data.tradePlans.firstIndex(where: { $0.id == changed.id }) { store.data.tradePlans[index] = changed; store.save(label: "修改账本或设置") }
                }
                .themedSheetBackground()
            }
        }
    }

    private func update(_ plan: TradePlan, status: TradePlan.Status) {
        guard let index = store.data.tradePlans.firstIndex(where: { $0.id == plan.id }) else { return }
        store.data.tradePlans[index].status = status; store.save(label: "修改账本或设置")
    }

    private func statusName(_ status: TradePlan.Status) -> String {
        switch status {
        case .planned: return "计划中"
        case .reviewed: return "已复盘"
        case .cancelled: return "已取消"
        }
    }
}

/// 新建 / 编辑交易计划。
///
/// **不再是 `private`**：个股页（`MarketChartView`）的 AI 建议也要一键转成计划，
/// 而 file-scope `private` 只在同文件可见。改成模块内可见。
struct TradePlanEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    /// 由 AI 建议一键转过来时带上的预填内容。金额一定让用户自己填 ——
    /// AI 没给仓位金额，App 不能替它编一个。
    ///
    /// 声明顺序有意放在 `onSave` **前面**：memberwise init 要求实参按声明顺序写，
    /// 而 `onSave` 放最后才能让「尾随闭包」这种普通用法继续成立
    /// （`TradePlanEditor { ... }`）。
    var prefill: AISuggestion? = nil
    var onSave: (TradePlan) -> Void
    @State private var selectedAsset = ""
    @State private var side: LedgerEntry.Side = .buy
    @State private var amount = ""
    @State private var price = ""
    @State private var target = ""
    @State private var invalid = ""
    @State private var reason = ""
    @State private var trigger = ""
    @State private var reviewDate = Date.now
    @State private var includeReviewDate = false
    @State private var message = ""
    private var instruments: [TradePlanInstrument] {
        let holdings = store.data.holdings.map { TradePlanInstrument(kind: $0.kind, code: $0.code, name: $0.name) }
        let quotes = store.data.quotes.map { TradePlanInstrument(kind: .etf, code: $0.code, name: $0.name) }
        return Array(Dictionary((holdings + quotes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.name < $1.name }
    }
    var body: some View {
        NavigationStack {
            Form {
                if instruments.isEmpty { Text("请先添加自选或持仓。") }
                else {
                    Picker("标的", selection: $selectedAsset) { ForEach(instruments) { Text("\($0.kind == .fund ? "基金" : "ETF/证券") · \($0.name) (\($0.code))").tag($0.id) } }
                    Picker("方向", selection: $side) { Text("买入/申购").tag(LedgerEntry.Side.buy); Text("卖出/赎回").tag(LedgerEntry.Side.sell) }
                    TextField("计划金额（元）", text: $amount).keyboardType(.decimalPad)
                    TextField("参考价/净值", text: $price).keyboardType(.decimalPad)
                    TextField("目标价（可选）", text: $target).keyboardType(.decimalPad)
                    TextField("失效价（可选）", text: $invalid).keyboardType(.decimalPad)
                    Toggle("设置复盘日期", isOn: $includeReviewDate)
                    if includeReviewDate { DatePicker("复盘日期", selection: $reviewDate, displayedComponents: .date) }
                    TextField("交易理由", text: $reason, axis: .vertical).lineLimit(2...4)
                    TextField("触发条件（可选）", text: $trigger, axis: .vertical).lineLimit(2...4)
                    Text("计划只作记录，不会自动交易，也不改变持仓、现金或收益。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("新建交易计划")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(instruments.isEmpty) }
            }
            .onAppear {
                applyPrefillIfNeeded()
                if selectedAsset.isEmpty { selectedAsset = instruments.first?.id ?? "" }
            }
        }
    }
    /// 把 AI 建议预填进来：标的、方向、参考价/目标价/失效价、理由都带上，
    /// 复盘日期默认给两周后（可改）；**金额留空**，由用户自己决定下多少。
    private func applyPrefillIfNeeded() {
        guard let prefill else { return }
        if let match = instruments.first(where: { $0.code == prefill.code }) {
            selectedAsset = match.id
        } else {
            // 不在自选/持仓里的代码不硬塞一个假 id —— 那样保存时会报「请填写有效金额」，
            // 把人引到错误的排查方向上。如实说清缺什么。
            message = "\(prefill.code) 还不在你的自选或持仓里，请先在「自选」里添加，再回到这里保存计划。"
        }
        side = prefill.side.ledgerSide
        price = prefill.price.map { numText($0) } ?? ""
        target = prefill.target.map { numText($0) } ?? ""
        invalid = prefill.invalid.map { numText($0) } ?? ""
        reason = prefill.reason
        trigger = prefill.hasAnyPrice ? "价格触及上述参考价时按计划执行；未触及不动作。" : ""
        reviewDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
        includeReviewDate = true
    }
    /// 去掉多余的 ".0"，让预填的输入框好看一点（"3.85" 而不是 "3.850000"）。
    private func numText(_ value: Double) -> String {
        let text = String(format: "%.4f", value)
        var trimmed = text
        while trimmed.contains("."), trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
    private func save() {
        guard let amountValue = Double(amount), amountValue.isFinite, amountValue > 0,
              let priceValue = Double(price), priceValue.isFinite, priceValue > 0,
              let instrument = instruments.first(where: { $0.id == selectedAsset }) else { message = "请填写大于零的有效金额和价格。"; return }
        let targetValue = target.isEmpty ? nil : Double(target)
        let invalidValue = invalid.isEmpty ? nil : Double(invalid)
        let targetIsValid = target.isEmpty || targetValue.map {
            $0.isFinite && (side == .buy ? $0 > priceValue : $0 < priceValue)
        } == true
        let invalidIsValid = invalid.isEmpty || invalidValue.map {
            $0.isFinite && (side == .buy ? $0 < priceValue : $0 > priceValue)
        } == true
        guard targetIsValid, invalidIsValid else {
            message = "目标价和失效价应位于计划价对应方向。"; return
        }
        onSave(TradePlan(id: UUID().uuidString, kind: instrument.kind, code: instrument.code, name: instrument.name,
            side: side, amount: amountValue, price: priceValue, target: targetValue, invalid: invalidValue,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            reviewDate: includeReviewDate ? dateKey(reviewDate) : "", created: dateKey(.now), status: .planned,
            actualPrice: nil, actualAmount: nil, review: ""))
        dismiss()
    }
    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
}

private struct TradePlanReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    var plan: TradePlan
    var onSave: (TradePlan) -> Void
    @State private var actualPrice = ""
    @State private var actualAmount = ""
    @State private var review = ""
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("执行记录") {
                    TextField("实际成交价/净值", text: $actualPrice).keyboardType(.decimalPad)
                    TextField("实际成交金额（元）", text: $actualAmount).keyboardType(.decimalPad)
                    Text("价格和金额需同时填写，或同时留空。执行偏差不是最终交易盈亏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("复盘") { TextField("记录执行结果与判断依据", text: $review, axis: .vertical).lineLimit(4...8) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("交易复盘")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { actualPrice = plan.actualPrice.map { String($0) } ?? ""; actualAmount = plan.actualAmount.map { String($0) } ?? ""; review = plan.review }
        }
    }
    private func save() {
        let price = actualPrice.isEmpty ? nil : Double(actualPrice)
        let amount = actualAmount.isEmpty ? nil : Double(actualAmount)
        let executionIsValid = actualPrice.isEmpty || (price.map { $0.isFinite && $0 > 0 } == true
            && amount.map { $0.isFinite && $0 > 0 } == true)
        guard actualPrice.isEmpty == actualAmount.isEmpty,
              executionIsValid else {
            message = "实际价格与金额请同时填写有效正数，或都留空。"; return
        }
        var changed = plan; changed.actualPrice = price; changed.actualAmount = amount
        changed.review = review.trimmingCharacters(in: .whitespacesAndNewlines); changed.status = .reviewed
        onSave(changed); dismiss()
    }
}

private enum DeepSeekModelOption: String, CaseIterable, Identifiable {
    case flash = "deepseek-flash", pro = "deepseek-v4-pro"
    var id: String { rawValue }
    /// 用户仍按“Flash / Chat”理解用途；请求值使用 DeepSeek 当前官方模型名。
    var title: String { self == .flash ? "DeepSeek Flash（快速）" : "DeepSeek Chat（V4 Pro 深度）" }
}
struct AIAnalysisView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @State private var timeoutSeconds = 45
    @State private var systemPrompt = ""
    @State private var showPortrait = false
    @State private var advisorResult = ""
    @State private var showAdvisorResult = false
    @State private var investmentProfile = InvestmentProfile()
    @State private var token = ""
    @State private var keySaved = false
    @FocusState private var apiKeyFocused: Bool
    @State private var showSavedAccountResult = false
    @State private var busy = false
    @State private var result = ""
    @State private var message = ""
    /// 一键转计划时的预填载体（同时充当 sheet(item:) 的开关）。
    @State private var planPrefill: AISuggestion?
    /// 已经处理过的建议 id，防止同一行被反复转成多条提醒。
    @State private var handledSuggestionIDs: Set<UUID> = []
    @State private var suggestionNote = ""
    @State private var showProfileSettings = false
    @State private var showModelSettings = false

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    /// 从模型回答末尾解析出的可执行建议。解析失败就是空数组，界面自然不出现这一段。
    private var suggestions: [AISuggestion] { AISuggestionParser.parse(result) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 0) {
                        insightButton(title: "账户画像", subtitle: "从持仓与流水归纳操作习惯", icon: "person.crop.circle.badge.checkmark") {
                            showPortrait = true
                        }
                        Divider().padding(.leading, 52)
                        insightButton(title: "本机账户建议", subtitle: "不需要 API 密钥，不上传数据", icon: "sparkles", expanded: showAdvisorResult) {
                            if advisorResult.isEmpty { advisorResult = LocalAdvisorEngine.review(data: store.data, totalAsset: store.totalAsset); showAdvisorResult = true }
                            else { withAnimation(.easeInOut(duration: 0.2)) { showAdvisorResult.toggle() } }
                        }
                    }
                    if showAdvisorResult, !advisorResult.isEmpty {
                        Text(advisorResult)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardPanelBackground(cornerRadius: AppLayout.cardRadius,
                                fallback: Color(uiColor: .secondarySystemBackground).opacity(0.72),
                                tone: store.effectiveAccentColor)
                    }
                }
                .toneCard(store.effectiveAccentColor, isLight: isLight)
                Section("AI 助手") {
                    Button {
                        if keySaved {
                            Task { await runAnalysis() }
                        } else {
                            message = "先在下方保存 DeepSeek API 密钥；密钥只保存在本机钥匙串。"
                            apiKeyFocused = true
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if busy { ProgressView() }
                            Image(systemName: busy ? "sparkles" : "sparkles.rectangle.stack")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(busy ? "正在分析账户…" : keySaved ? "分析我的账户" : "配置密钥后开始分析")
                                    .font(.headline)
                                Text("当前模型：\(DeepSeekModelOption(rawValue: model)?.title ?? "DeepSeek Flash（快速）")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .disabled(busy)
                    if let saved = store.data.savedAccountAIAnalysis {
                        Button { showSavedAccountResult = true } label: {
                            Label("查看上次分析 · \(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Text("账户建议和账户画像可在上方直接使用；大模型分析会读取当前账本并保存最近一次成功结果。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(store.effectiveAccentColor, isLight: isLight)
                Section {
                    DisclosureGroup(isExpanded: $showProfileSettings) {
                        Picker("交易风格", selection: $investmentProfile.style) {
                            Text("超短线").tag("day"); Text("波段").tag("swing"); Text("中线").tag("mid"); Text("长线定投").tag("long")
                        }
                        Picker("风险偏好", selection: $investmentProfile.risk) {
                            Text("保守").tag("con"); Text("平衡").tag("bal"); Text("激进").tag("agg")
                        }
                        Stepper(value: $investmentProfile.maxPositionPercent, in: 1...100, step: 1) {
                            LabeledContent("单标的仓位上限", value: "\(Int(investmentProfile.maxPositionPercent))%")
                        }
                        TextField("典型持有周期", text: $investmentProfile.horizon)
                        Toggle("关注 ETF 溢价", isOn: $investmentProfile.premiumSensitive)
                        TextField("偏好方向", text: $investmentProfile.preference, axis: .vertical).lineLimit(1...3)
                        TextField("忌讳 / 不做", text: $investmentProfile.avoid, axis: .vertical).lineLimit(1...3)
                        TextField("自己的交易方式", text: $investmentProfile.method, axis: .vertical).lineLimit(2...5)
                        TextField("投资目标", text: $investmentProfile.goal, axis: .vertical).lineLimit(1...3)
                        Button("保存投资偏好") {
                            investmentProfile.maxPositionPercent = min(100, max(1, investmentProfile.maxPositionPercent))
                            store.data.investmentProfile = investmentProfile
                            store.save(label: "修改账本或设置")
                            message = "投资偏好已保存"
                        }
                    } label: {
                        settingsSummary(title: "投资偏好", value: "\(profileStyleName(investmentProfile.style)) · \(profileRiskName(investmentProfile.risk))", icon: "slider.horizontal.3")
                    }
                }
                .plainCard(isLight: isLight)
                Section {
                    DisclosureGroup(isExpanded: $showModelSettings) {
                        LabeledContent("接口", value: "DeepSeek 官方 API")
                        Picker("DeepSeek 模型", selection: $model) { ForEach(DeepSeekModelOption.allCases) { Text($0.title).tag($0.rawValue) } }
                        Stepper(value: $timeoutSeconds, in: 5...180, step: 5) {
                            LabeledContent("请求超时", value: "\(timeoutSeconds) 秒")
                        }
                        TextField("分析要求", text: $systemPrompt, axis: .vertical).lineLimit(3...7)
                        Button("保存接口设置") {
                            var config = store.data.aiAnalysisConfig
                            config.endpoint = "https://api.deepseek.com"
                            config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                            config.timeoutSeconds = min(180, max(5, timeoutSeconds))
                            config.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            store.data.aiAnalysisConfig = config
                            store.save(label: "修改账本或设置")
                            message = "接口设置已保存"
                        }
                        Text("Flash 适合快速分析；Chat 适合更完整的账户或单标的解读。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } label: {
                        settingsSummary(title: "模型设置", value: model.isEmpty ? "未配置" : model, icon: "cpu")
                    }
                }
                .plainCard(isLight: isLight)
                Section {
                    Label("API 密钥", systemImage: "key").font(.headline)
                    HStack {
                        SecureField("粘贴 API 密钥", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($apiKeyFocused)
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { token = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("从剪贴板粘贴 API 密钥")
                    }
                    Button("安全保存密钥") {
                        do {
                            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                message = "请输入新的密钥；已保存的密钥不会显示在这里。"
                                return
                            }
                            try AIAnalysisService.saveAPIKey(token)
                            token = ""
                            keySaved = AIAnalysisService.hasSavedAPIKey
                            message = "密钥已保存到本机钥匙串"
                        } catch { message = error.localizedDescription }
                    }
                    if keySaved {
                        Button("删除本机已保存密钥", role: .destructive) {
                            do {
                                try AIAnalysisService.saveAPIKey("")
                                keySaved = false
                                message = "本机密钥已删除"
                            } catch { message = error.localizedDescription }
                        }
                    }
                    Text(keySaved ? "密钥已保存在本机钥匙串，不会写入 JSON 备份。" : "请使用你在模型服务商处创建的 API 密钥。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section {
                    DisclosureGroup("查看发送给模型的数据范围") {
                        Text("分析时会发送投资偏好、持仓、自选报价、场内与场外基金流水、定投计划、基金成分报告、参考现金、最近快照和现金流记录。本机还会计算交易行为统计、大盘指数与组合集中度、已缓存标的的均线位置并一并发送；这些补充材料在手机本地计算。请勿在提示中填写账户密码或其他敏感信息。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .plainCard(isLight: isLight)
                if !message.isEmpty {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        .plainCard(isLight: isLight)
                }
                if !result.isEmpty {
                    Section("分析结果") {
                        if let saved = store.data.savedAccountAIAnalysis {
                            Label("保存于 \(saved.updatedAt.formatted(date: .abbreviated, time: .shortened)) · 下次成功分析后替换",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // 展示用剥掉机器可读段的人话版本；解析仍然读完整的 result。
                        AIFormattedResultView(text: AISuggestionParser.displayText(result),
                                              accent: store.effectiveAccentColor)
                        Text("模型输出可能有误。价格/净值可能延迟；请核对行情与基金净值，不要仅依据模型文字交易。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !suggestions.isEmpty {
                        Section("可执行建议（\(suggestions.count) 条）") {
                            Text("模型在回答末尾给出了可落地的价位。转成计划会进「交易计划与复盘」等待你复核，转成提醒会在行情刷新时通知；两者都不会自动下单。")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(suggestions) { suggestion in
                                suggestionRow(suggestion)
                            }
                            if !suggestionNote.isEmpty {
                                Text(suggestionNote).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .toneCard(store.effectiveAccentColor, isLight: isLight)
                    }
                }
            }
            .navigationTitle("AI 账户分析")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .background(.clear)
            .themedSheetBackground()
            .sheet(isPresented: $showPortrait) { AccountPortraitView() .themedSheetBackground() }
            .sheet(isPresented: $showSavedAccountResult) {
                NavigationStack {
                    ScrollView {
                        if let saved = store.data.savedAccountAIAnalysis {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("保存于 \(saved.updatedAt.formatted(date: .complete, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                AIFormattedResultView(text: AISuggestionParser.displayText(saved.text),
                                                      accent: store.effectiveAccentColor)
                                Text("这是上次成功分析的保存结果；重新分析成功后会更新。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(12)
                        } else {
                            ContentUnavailableView("暂无已保存的分析", systemImage: "sparkles")
                        }
                    }
                    .navigationTitle("上次分析结果")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { showSavedAccountResult = false } } }
                    .themedSheetBackground()
                }
            }
            .sheet(item: $planPrefill) { suggestion in
                // 显式写 onSave: —— TradePlanEditor 的参数顺序是 (onSave, prefill)，
                // 尾随闭包语法会绑到最后一个参数（prefill）上，类型对不上。
                TradePlanEditor(prefill: suggestion, onSave: { plan in
                    store.data.tradePlans.append(plan)
                    store.save(label: "AI 建议转交易计划")
                    handledSuggestionIDs.insert(suggestion.id)
                    suggestionNote = "已存入「交易计划与复盘」，到复盘日期前都可以修改或取消。"
                })
                .themedSheetBackground()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                let savedModel = store.data.aiAnalysisConfig.model
                if savedModel == "deepseek-chat" || savedModel == "deepseek-reasoner" {
                    model = DeepSeekModelOption.pro.rawValue
                } else if savedModel == "deepseek-v4-flash" {
                    model = DeepSeekModelOption.flash.rawValue
                } else {
                    model = DeepSeekModelOption(rawValue: savedModel) == nil ? DeepSeekModelOption.flash.rawValue : savedModel
                }
                timeoutSeconds = store.data.aiAnalysisConfig.timeoutSeconds
                systemPrompt = store.data.aiAnalysisConfig.systemPrompt
                investmentProfile = store.data.investmentProfile
                keySaved = AIAnalysisService.hasSavedAPIKey
                if result.isEmpty, let saved = store.data.savedAccountAIAnalysis {
                    result = saved.text
                }
            }
        }
    }

    private func insightButton(title: String, subtitle: String, icon: String, expanded: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(store.effectiveAccentColor)
                    .frame(width: 36, height: 36)
                    .background(store.effectiveAccentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: expanded.map { $0 ? "chevron.up" : "chevron.down" } ?? "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsSummary(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(store.effectiveAccentColor).frame(width: 24)
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func profileStyleName(_ raw: String) -> String {
        ["day": "超短线", "swing": "波段", "mid": "中线", "long": "长线定投"][raw] ?? "未设置"
    }

    private func profileRiskName(_ raw: String) -> String {
        ["con": "保守", "bal": "平衡", "agg": "激进"][raw] ?? "未设置"
    }

    @MainActor
    private func runAnalysis() async {
        var config = store.data.aiAnalysisConfig
        config.endpoint = "https://api.deepseek.com"
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.timeoutSeconds = min(180, max(5, timeoutSeconds))
        config.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        store.data.aiAnalysisConfig = config
        store.save(label: "修改账本或设置")
        busy = true
        message = ""
        defer { busy = false }
        // 补充材料在本机算好再塞进 prompt：交易行为画像（按历史流水统计的习惯）、
        // 大盘指数、组合结构风险、已缓存标的的技术面。全部零网络请求，
        // 拿不到的段落直接不出现，不让模型拿到编出来的数。
        let extras = AIContextBuilder.portfolioSections(store: store)
        do {
            let newResult = try await AIAnalysisService.analyze(config: config, portfolio: store.data,
                                                                extraSections: extras)
            result = newResult
            store.data.savedAccountAIAnalysis = SavedAIAnalysis(text: newResult)
            store.saveAIAnalysisCache()
            // 只有新答案成功后，旧建议的处理状态才作废。
            handledSuggestionIDs.removeAll()
            suggestionNote = ""
        } catch {
            message = result.isEmpty ? error.localizedDescription : "\(error.localizedDescription)；上次分析结果仍已保留。"
        }
    }

    // MARK: - 可执行建议 → 计划 / 提醒

    /// 单条建议的展示与两个落地动作。
    ///
    /// 配色沿用工程口径：买=红、卖=绿（国内习惯），不吃系统 `Color.red`。
    private func suggestionRow(_ suggestion: AISuggestion) -> some View {
        let tone: Color = suggestion.side == .buy ? PnLColor.up : PnLColor.down
        let handled = handledSuggestionIDs.contains(suggestion.id)
        // 在 ViewBuilder 之外先算好，少一处「闭包里能不能写 let」的疑问。
        let prices = priceParts(suggestion)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(suggestion.side.label)
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tone.opacity(isLight ? 0.14 : 0.24), in: Capsule())
                Text("\(suggestion.displayName) · \(suggestion.code)")
                    .scaledFont(14, weight: .semibold)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                if handled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CardTone.ok)
                        .accessibilityLabel("已处理")
                }
            }
            if !prices.isEmpty {
                Text(prices.joined(separator: " · "))
                    .scaledFont(12).monospacedDigit().foregroundStyle(.secondary)
            }
            if !suggestion.reason.isEmpty {
                Text(suggestion.reason).font(.footnote)
            }
            HStack(spacing: 10) {
                Button("存入计划记录") {
                    Haptics.tap()
                    planPrefill = suggestion
                }
                .buttonStyle(.bordered)
                .disabled(handled)

                Button("设为价格提醒") {
                    createAlert(from: suggestion)
                }
                .buttonStyle(.bordered)
                .disabled(handled || alertTarget(suggestion) == nil || isFund(suggestion.code))
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
    }

    /// 「参考价 3.85 · 目标 4.20 · 失效 3.70」，没填的项不出现。
    private func priceParts(_ suggestion: AISuggestion) -> [String] {
        var parts: [String] = []
        if let price = suggestion.price { parts.append("参考价 \(price.num(3))") }
        if let target = suggestion.target { parts.append("目标 \(target.num(3))") }
        if let invalid = suggestion.invalid { parts.append("失效 \(invalid.num(3))") }
        return parts
    }

    /// 提醒挂在哪个价位：优先参考价，其次目标价/失效价 —— 有哪个用哪个。
    private func alertTarget(_ suggestion: AISuggestion) -> Double? {
        suggestion.price ?? suggestion.target ?? suggestion.invalid
    }

    /// 这个代码是不是场外基金。基金按净值成交、没有实时价，价格提醒对它无意义。
    private func isFund(_ code: String) -> Bool {
        store.data.holdings.contains { $0.code == code && $0.kind == .fund }
    }

    /// 把建议转成价格提醒。买入等回落到参考价（below），卖出等涨到参考价（above）。
    private func createAlert(from suggestion: AISuggestion) {
        guard let target = alertTarget(suggestion) else { return }
        // 场外基金没有实时价，提醒引擎永远碰不到它 —— 建一条哑提醒不如说清楚。
        if store.data.holdings.contains(where: { $0.code == suggestion.code && $0.kind == .fund }) {
            suggestionNote = "\(suggestion.displayName) 是场外基金，按净值成交、没有实时价，价格提醒不会触发；请用「存入计划记录」，到净值公布后自己核对。"
            return
        }
        let direction: QuoteAlert.Direction = suggestion.side == .buy ? .below : .above
        do {
            try store.addQuoteAlert(code: suggestion.code,
                                    name: suggestion.displayName,
                                    target: target,
                                    direction: direction)
            handledSuggestionIDs.insert(suggestion.id)
            suggestionNote = "已添加价格提醒：\(suggestion.displayName) \(direction == .below ? "跌到" : "涨到") \(target.num(3)) 时通知（一次性，触发后需手动重启）。"
        } catch {
            suggestionNote = error.localizedDescription
        }
    }
}

struct AllocationTargetEditor: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    let holding: Holding
    let targetPercent: Double?
    @State private var percent = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("标的", value: "\(holding.name) · \(holding.code)")
                TextField("目标仓位（%）", text: $percent).keyboardType(.decimalPad)
                Text("当前仓位 \((store.allocationActualPercent(for: holding)).num(2))%。保存后仅计算偏差金额，不会修改持仓或现金。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if targetPercent != nil {
                    Button("删除目标", role: .destructive) { store.removeAllocationTarget(for: holding); dismiss() }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("设置目标仓位")
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { if percent.isEmpty, let targetPercent { percent = String(targetPercent) } }
        }
    }
    private func save() {
        guard let value = Double(percent) else { error = "请输入 0 到 100 之间的百分比。"; return }
        do { try store.saveAllocationTarget(for: holding, percent: value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct GridInstrument: Identifiable {
    var code: String
    var name: String
    var price: Double
    var id: String { code }
}

struct DayGridView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var capital = "5000"
    @State private var anchor = ""
    @State private var step = "0.6"
    @State private var levels = "5"
    @State private var fee = "0.1"
    @State private var selectedDay = ""
    @State private var result: GridReplayResult?
    @State private var message = ""
    @State private var recommendationText = ""
    @State private var showImporter = false
    @State private var showStrategicGridPlanner = false
    /// 网格适合度排名（规则版评估，见 GridSuitability.swift）。
    @State private var suitability: [GridSuitability] = []
    @State private var isEvaluatingSuitability = false
    /// 「哪个标的适合做网格」默认收起：这是品种筛选参考，不是每次进来都要看的东西。
    @State private var suitabilityExpanded = false
    /// 「什么样的标的适合做网格」判断标准教学，默认收起。
    @State private var gridTutorialExpanded = false

    private var instruments: [GridInstrument] {
        let quotes = store.data.quotes.map { GridInstrument(code: $0.code, name: $0.name, price: $0.price) }
        let etfs = store.data.holdings.filter { $0.kind == .etf }.map { GridInstrument(code: $0.code, name: $0.name, price: $0.current) }
        let plans = store.data.dayGridPlans.map { GridInstrument(code: $0.code, name: $0.name, price: $0.anchor) }
        // 优先使用最新行情，其次持仓现价；保存计划里的锚点只作为最后兜底。
        return Array(Dictionary((quotes + etfs + plans).map { ($0.code, $0) }, uniquingKeysWith: { first, second in
            first.price > 0 ? first : second
        }).values).sorted { $0.code < $1.code }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var currentInstrument: GridInstrument? { instruments.first { $0.code == code } }

    var body: some View {
        NavigationStack {
            Form {
                Section("标的与参数") {
                    if instruments.isEmpty {
                        Text("先在自选或 ETF 持仓中添加标的。")
                    } else {
                        Picker("标的", selection: $code) {
                            ForEach(instruments) { item in Text("\(item.name) · \(item.code)").tag(item.code) }
                        }
                        .onChange(of: code) { _, value in
                            if let item = instruments.first(where: { $0.code == value }) {
                                name = item.name
                                anchor = item.price > 0 ? String(format: "%.4f", item.price) : ""
                                result = nil
                                recommendationText = "已切换到\(item.name)（\(item.code)），中枢价已按该标的最新行情重置。"
                            }
                        }
                        if let item = currentInstrument {
                            LabeledContent("最新参考价", value: item.price > 0 ? item.price.num(4) : "暂无有效行情")
                        }
                    }
                    // 参数填入改两列网格：5 个数字字段一屏放得下，不用来回滚动找输入框。
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                        gridNumberField("计划资金（元）", hint: "5000", text: $capital, keyboard: .decimalPad)
                        gridNumberField("每笔费用（元）", hint: "0.1", text: $fee, keyboard: .decimalPad)
                        gridNumberField("网格中枢价（元）", hint: "如 2.500", text: $anchor, keyboard: .decimalPad)
                        gridNumberField("每档间距（%）", hint: "0.6", text: $step, keyboard: .decimalPad)
                        gridNumberField("上下档数（各侧）", hint: "5", text: $levels, keyboard: .numberPad)
                        if let item = currentInstrument, item.price > 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("中枢价快捷填入").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                                Button("用最新价 \(item.price.num(3))") {
                                    anchor = String(format: "%.4f", item.price)
                                }
                                .scaledFont(11, weight: .medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                    // 快捷档位：一键填入常用间距/档数，不用为了改一个数字把键盘调起来。
                    HStack(spacing: 6) {
                        Text("间距").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                        ForEach([0.3, 0.5, 0.8, 1.2, 2.0], id: \.self) { value in
                            gridQuickChip("\(String(format: "%g", value))%", selected: Double(step) == value) {
                                step = String(format: "%g", value)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text("档数").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                        ForEach([3, 5, 8], id: \.self) { value in
                            gridQuickChip("\(value) 档", selected: Int(levels) == value) {
                                levels = String(value)
                            }
                        }
                    }
                    // 实时推算：边填边看到每档资金 / 每档可买份数 / 网格覆盖范围，不用先保存再试错。
                    if let preview = gridPlanPreview {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("每档资金").scaledFont(11).foregroundStyle(.secondary)
                                Spacer()
                                Text(preview.budgetPerLevel.cny()).scaledFont(11, weight: .semibold).monospacedDigit()
                            }
                            HStack {
                                Text("每档可买").scaledFont(11).foregroundStyle(.secondary)
                                Spacer()
                                Text(preview.sharesPerLevel >= 100
                                     ? "\(preview.sharesPerLevel.num(0)) 份（\(Int(preview.sharesPerLevel / 100)) 手）"
                                     : "不足 1 手")
                                    .scaledFont(11, weight: .semibold).monospacedDigit()
                                    .foregroundStyle(preview.sharesPerLevel >= 100 ? Color.primary : Color.orange)
                            }
                            HStack {
                                Text("网格覆盖").scaledFont(11).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(preview.lower.num(3)) – \(preview.upper.num(3))").scaledFont(11).monospacedDigit()
                            }
                            if preview.sharesPerLevel < 100 {
                                Text("每档资金不够买 1 手（100 份）：减少档数、加大计划资金，或换个价格更低 / 适合度更高的标的。")
                                    .scaledFont(10).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button("根据历史分时生成规则建议") { suggestParameters() }
                        .disabled(code.isEmpty)
                        .buttonStyle(.borderedProminent)
                    if !recommendationText.isEmpty { Text(recommendationText).font(.footnote).foregroundStyle(.secondary) }
                    Button("保存/更新本地计划") { savePlan() }.disabled(code.isEmpty)
                    Text("每档按 100 份整数手模拟。计划仍可保存，调整资金或减少档数即可；计划预设不要求市场已开盘。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section {
                    DisclosureGroup(isExpanded: $suitabilityExpanded) {
                        Text("按公开网格交易方法用本机日线计算：日均成交额（流动性）、年化波动率 15%–30%、日均振幅 0.5%–2%、收盘贴近 MA20 的震荡性、场内品种、避开 60 日单边极端。这是品种筛选参考，不是 AI 预测，也不保证收益。")
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup(isExpanded: $gridTutorialExpanded) {
                            gridTutorialList
                        } label: {
                            Label("什么样的标的适合做网格（判断标准）", systemImage: "book").font(.subheadline)
                        }
                        if isEvaluatingSuitability {
                            HStack(spacing: 8) { ProgressView(); Text("正在补日线并评估…").font(.footnote) }
                        } else {
                            Button("评估/刷新") { refreshSuitability() }
                            if suitability.contains(where: { $0.isOnExchange && $0.barCount < 60 }) {
                                Button("为数据不足的标的补日线（最多 8 只）") { Task { await backfillSuitabilityData() } }
                            }
                        }
                        if suitability.isEmpty, !isEvaluatingSuitability {
                            Text("暂无可评估标的：先在自选或 ETF 持仓里添加场内品种（ETF）。场外基金不参与评估——申购赎回费高、确认慢，一格差价不够填费用，做不了网格；想做网格请换成场内 ETF。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(suitability) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("\(item.name) · \(item.code)").font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text(item.grade.rawValue)
                                        .scaledFont(10, weight: .bold)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .foregroundStyle(.white)
                                        .background(suitabilityGradeColor(item.grade), in: Capsule())
                                    Text("\(item.score) 分").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(suitabilityMetricsText(item))
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(item.warnings, id: \.self) { line in
                                    Text("⚠ \(line)").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(item.reasons, id: \.self) { line in
                                    Text("· \(line)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 10) {
                                    Button("用它做网格") { selectSuitability(item) }
                                        .disabled(item.grade == .avoid)
                                    if item.isOnExchange, item.barCount < 60 {
                                        Button("补日线") { Task { await backfillSuitabilityData(for: item.code) } }
                                    }
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    } label: {
                        Label("哪个标的适合做网格（规则版评估）", systemImage: "square.grid.3x3").font(.headline)
                    }
                }
                .plainCard(isLight: isLight)
                Section("分时数据") {
                    Button("导入分时 CSV") { showImporter = true }
                    Text("CSV 支持 code,date,time,price,volume 或 code,timestamp,price；无 code 列时使用当前选择标的；timestamp/time 列需包含完整日期和时间（yyyy-MM-dd HH:mm[:ss]）。应用在前台且取得有效报价时才采集；已保存的分时历史不会按交易日数自动删除。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !store.gridTradingDays.isEmpty {
                        Picker("复盘日期", selection: $selectedDay) {
                            ForEach(store.gridTradingDays, id: \.self) { Text($0).tag($0) }
                        }
                        Button("复盘所选日期") { runReplay() }.disabled(code.isEmpty || selectedDay.isEmpty)
                    }
                }
                .plainCard(isLight: isLight)
                Section("中长期网格计划（独立于日内回放）") {
                    Button("打开中长期网格规划") { showStrategicGridPlanner = true }
                    Text("按近 60 日价格区间、波动幅度和可选资金生成上下买卖档；不使用分时回放数据，也不会自动下单。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let result {
                    Section("路径模拟结果 · \(result.day)") {
                        LabeledContent("模拟盈亏", value: "\((result.profit).directionMark()) \((result.profit).cny())")
                            .foregroundStyle(PnLColor.of(result.profit))
                        LabeledContent("买入 / 卖出", value: "\(result.buyCount) / \(result.sellCount) 笔")
                        LabeledContent("估算费用", value: (result.fees).cny())
                        LabeledContent("分时覆盖", value: (result.coverage * 100).pct(0))
                        Text(result.fills == 0 ? "该日没有触发网格成交。若资金不足以买入 100 份一手、网格间距超出当日波动，或数据缺点，结果可能没有代表性。" : "回放按时间顺序计算，含逐笔固定费用；不含排队、成交量、滑点、涨跌停和真实券商规则。历史最佳参数会有过拟合，不能直接当作明日建议。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .toneCard(CardTone.pnl(result.profit), isLight: isLight)
                }
                if !message.isEmpty {
                    Section { Text(message).font(.footnote) }
                        .toneCard(CardTone.warn, isLight: isLight)
                }
                Section("已保存计划") {
                    if store.data.dayGridPlans.isEmpty { Text("暂无计划") }
                    ForEach(store.data.dayGridPlans) { plan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(plan.name) · \(plan.code)").font(.headline)
                            Text("资金 \((plan.capital).num(0)) · 中枢 \((plan.anchor).num(3)) · 间距 \((plan.stepPercent * 100).num(2))% · 每档约 \((floor(plan.capital / Double(plan.levelsEachSide * 2 + 2) / (plan.anchor * 100)) * 100).num(0)) 份")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("载入参数") { loadPlan(plan) }
                            Button("删除计划", role: .destructive) { store.removeGridPlan(plan) }
                        }
                    }
                }
                .plainCard(isLight: isLight)
                if !store.data.legacyGridArchives.isEmpty {
                    Section("旧版网格记录（只读归档）") {
                        ForEach(store.data.legacyGridArchives) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(record.name) · \(record.code)")
                                Text("\(record.horizon) · \(record.mode) · \(record.status) · \(record.created)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if record.capital > 0 {
                                    Text("计划资金 \((record.capital).cny()) · 原网格 \((record.lower).num(3))–\((record.upper).num(3)) · 每档 \((record.quantity).num(0)) 份")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("旧版每条网格记录及其成交、模拟资金等字段以原始 JSON 保留；符合日内参数条件的已另外转换为可载入回放的计划。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !store.data.legacyShadowArchives.isEmpty {
                    Section("旧版影子盘历史与自动模拟") {
                        ForEach(store.data.legacyShadowArchives) { record in
                            DisclosureGroup("\(record.name) · \(record.code)") {
                                LabeledContent("模拟状态", value: record.closed ? "已结束" : (record.active ? "运行中" : "已暂停"))
                                if !record.closed {
                                    Button(record.active ? "暂停影子模拟" : "恢复影子模拟") {
                                        store.setLegacyShadowActive(record, active: !record.active)
                                    }
                                }
                                LabeledContent("影子账户盈亏（末次行情估算）", value: (record.lastEquityChange).cny())
                                LabeledContent("相对初始持有", value: (record.lastEquityChange - record.holdOnlyChange).cny())
                                LabeledContent("累计已实现", value: (record.realizedPnL).cny())
                                LabeledContent("估算费用", value: (record.totalFees).cny())
                                LabeledContent("模拟买 / 卖", value: "\(record.buys) / \(record.sells)")
                                if record.scoredSells > 0 {
                                    LabeledContent("旧记录卖出胜率", value: "\((Double(record.wins) / Double(record.scoredSells) * 100).num(1))%")
                                }
                                if !record.days.isEmpty {
                                    DisclosureGroup("每日摘要（最近 20 日）") {
                                        ForEach(Array(record.days.suffix(20).reversed())) { day in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(day.day)
                                                Text("买 \(day.buys) / 卖 \(day.sells) · 费用 \((day.fees).cny()) · 已实现 \((day.realizedPnL).cny())")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                if !record.fills.isEmpty {
                                    DisclosureGroup("成交明细（最近 20 笔，共 \(record.fills.count) 笔）") {
                                        ForEach(Array(record.fills.suffix(20).reversed())) { fill in
                                            Text("\(fill.day) \(fill.time) · \(fill.side == "buy" ? "买" : "卖") \((fill.quantity).num(0)) 份 @ \((fill.price).num(3)) · 费用 \((fill.fee).cny())")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        Text("影子盘使用隔离的虚拟资金，前台有效行情更新时按网格档位模拟，不会计入原生真实持仓或现金。价格、费用与胜率均为估算，不能代表可成交结果；暂停期间只更新参考价、不记模拟成交，恢复时会重新建立行情基准。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("日内网格 / 复盘")
            .toolbarBackground(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .themedSheetBackground()
            .listRowBackground(Color.clear)
            .buttonStyle(.plain)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if code.isEmpty, let first = instruments.first { code = first.code; name = first.name; anchor = first.price > 0 ? String(format: "%.4f", first.price) : "" }
                if selectedDay.isEmpty { selectedDay = store.gridTradingDays.first ?? "" }
                refreshSuitability()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { response in
                do {
                    guard let url = try response.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let count = try store.importIntradayCSV(Data(contentsOf: url), fallbackCode: code)
                    selectedDay = store.gridTradingDays.first ?? ""
                    message = "已导入 \(count) 个分时点。"
                } catch { message = error.localizedDescription }
            }
            .sheet(isPresented: $showStrategicGridPlanner) {
                StrategicGridPlannerView().environmentObject(store).themedSheetBackground()
            }
        }
    }

    /// 两列网格里的数字输入框：标题在上、输入框在下，比整行 LabeledContent 更紧凑，
    /// 5 个参数一屏放得下。圆角底色让它看起来就是「可点的输入位」。
    @ViewBuilder private func gridNumberField(_ title: String, hint: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).scaledFont(10, weight: .medium).foregroundStyle(.secondary)
            TextField(hint, text: text)
                .keyboardType(keyboard)
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// 快捷档位 chip：点一下填入常用值；与当前值一致时高亮，一眼看出现在用的是哪档。
    @ViewBuilder private func gridQuickChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(10, weight: .semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(uiColor: .secondarySystemBackground).opacity(0.8),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 参数实时推算：每档资金、每档可买份数（100 份整数手）、网格上下沿。
    /// 任何输入不合法时返回 nil，界面不显示推算块；下沿不可能为负（跨度 >100% 时钳到 0）。
    private var gridPlanPreview: (budgetPerLevel: Double, sharesPerLevel: Double, lower: Double, upper: Double)? {
        guard let capitalValue = Double(capital), let anchorValue = Double(anchor),
              let stepValue = Double(step), let levelValue = Int(levels),
              capitalValue.isFinite, capitalValue > 0,
              anchorValue.isFinite, anchorValue > 0,
              stepValue.isFinite, stepValue > 0,
              levelValue >= 1 else { return nil }
        let lotCost = anchorValue * 100
        guard lotCost > 0, lotCost.isFinite else { return nil }
        let budget = capitalValue / Double(levelValue * 2 + 2)
        let shares = floor(budget / lotCost) * 100
        let swing = stepValue / 100 * Double(levelValue)
        return (budget, shares, max(0, anchorValue * (1 - swing)), anchorValue * (1 + swing))
    }

    private func savePlan() {
        do {
            guard let capitalValue = Double(capital), let anchorValue = Double(anchor), let stepValue = Double(step), let levelValue = Int(levels), let feeValue = Double(fee) else { throw GridError.invalidPlan }
            let chosen = instruments.first { $0.code == code }
            try store.saveGridPlan(code: code, name: chosen?.name ?? name, capital: capitalValue, anchor: anchorValue, stepPercent: stepValue, levels: levelValue, feePerOrder: feeValue)
            message = "计划已保存，不会占用或改变主账户资金。"
        } catch { message = error.localizedDescription }
    }

    private func loadPlan(_ plan: DayGridPlan) {
        code = plan.code; name = plan.name
        capital = String(format: "%.2f", plan.capital)
        anchor = String(format: "%.4f", plan.anchor)
        step = String(format: "%.3f", plan.stepPercent * 100)
        levels = String(plan.levelsEachSide)
        fee = String(format: "%.2f", plan.feePerOrder)
        recommendationText = "已载入本地参数。"
    }

    private func suggestParameters() {
        guard let capitalValue = Double(capital), let feeValue = Double(fee) else {
            recommendationText = "先填写有效的计划资金和每笔费用。"; return
        }
        if let suggestion = store.gridRecommendation(code: code, capital: capitalValue, feePerOrder: feeValue) {
            anchor = String(format: "%.3f", suggestion.anchor)
            step = String(format: "%.3f", suggestion.stepPercent)
            levels = String(suggestion.levels)
            recommendationText = "规则评分 \(suggestion.score)/100 · \(suggestion.summary) 这是基于历史数据的参数参考，不是 AI 预测，也不保证未来收益。"
            return
        }
        // 生成不了时分开说清卡在哪：分时数据不够，还是计划资金不够（与主账户现金无关）。
        recommendationText = store.gridRecommendationBlocker(
            code: code, capital: capitalValue, feePerOrder: feeValue, fallbackAnchor: Double(anchor)
        ) ?? "暂时给不出参数：可能是数据不足（既没有 ≥3 天覆盖合格的分时，日线也不到 11 根），或计划资金/费用不足以支持至少一档。先点「补日线」，或采集/导入分时数据。"
    }

    // MARK: - 网格适合度评估（规则版，见 GridSuitability.swift）

    /// 用本地已缓存日线重新排名。纯本地计算，立即可用。
    private func refreshSuitability() {
        suitability = store.gridSuitabilityRanking()
    }

    /// 为场内且日线不足 60 根的标的补日线后重评（最多 8 只，顺序请求）。
    private func backfillSuitabilityData() async {
        guard !isEvaluatingSuitability else { return }
        isEvaluatingSuitability = true
        defer { isEvaluatingSuitability = false }
        _ = await store.ensureGridSuitabilityData(limit: 8)
        refreshSuitability()
    }

    /// 只为某一个标的补日线（行内「补日线」按钮）。
    private func backfillSuitabilityData(for targetCode: String) async {
        guard !isEvaluatingSuitability else { return }
        isEvaluatingSuitability = true
        defer { isEvaluatingSuitability = false }
        _ = try? await store.fetchDailyBars(code: targetCode, count: 640, force: false)
        refreshSuitability()
    }

    /// 把评估选中的标的装进上方参数区（与切换 Picker 同一套动作）。
    private func selectSuitability(_ item: GridSuitability) {
        code = item.code
        name = item.name
        if let instrument = currentInstrument, instrument.price > 0 {
            anchor = String(format: "%.4f", instrument.price)
        }
        result = nil
        recommendationText = "已选择\(item.name)（\(item.code)）· 适合度 \(item.score) 分（\(item.grade.rawValue)）。参数仍可手动调整。"
    }

    private func suitabilityMetricsText(_ item: GridSuitability) -> String {
        var parts: [String] = []
        parts.append(item.annualVolatilityPercent.map { "年化波动 \(String(format: "%.1f", $0))%" } ?? "年化波动 --")
        parts.append(item.avgDailyAmplitudePercent.map { "日均振幅 \(String(format: "%.2f", $0))%" } ?? "日均振幅 --")
        parts.append(item.avgTurnoverYi.map { "日均成交额 \(String(format: "%.2f", $0)) 亿" } ?? "日均成交额 --")
        parts.append(item.rangeBoundRatio.map { "震荡性 \(Int(($0 * 100).rounded()))%" } ?? "震荡性 --")
        parts.append("日线 \(item.barCount) 根")
        return parts.joined(separator: " · ")
    }

    private func suitabilityGradeColor(_ grade: GridSuitability.Grade) -> Color {
        switch grade {
        case .suitable: return Color(red: 0.07, green: 0.68, blue: 0.48)
        case .consider: return Color.orange
        case .avoid: return Color.secondary
        }
    }

    /// 「什么样的标的适合做网格」判断标准。每条都对应 `GridSuitabilityEngine` 里的一个分项，
    /// 看完能自己复算界面上那个分数是怎么来的（不是玄学打分）。
    @ViewBuilder private var gridTutorialList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.gridTutorialItems.enumerated()), id: \.offset) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(entry.offset + 1). \(entry.element.title)")
                        .font(.caption.weight(.semibold))
                    Text(entry.element.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("一句话：场内 + 流动性够 + 波动适中 + 走势震荡，四条缺任何一条，网格都会变成「单边扛单」。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 教学条目（标题 + 说明）。与 `GridSuitabilityEngine` 的评分分项一一对应。
    private static let gridTutorialItems: [(title: String, detail: String)] = [
        ("必须是场内品种", "场外基金申购费加赎回费一次要 0.1%–1.5%，确认还要 T+1～T+2，一格差价根本不够填费用。网格只做 ETF / 场内基金。"),
        ("流动性要够：日均成交额 ≥ 1 亿", "挂单能立刻成交、滑点小。成交额太小的品种，买卖价差本身就是隐形成本。"),
        ("波动率适中：年化 15%–30%", "太低（低于 15%）没有波动就没有差价可赚；太高（高于 30%）价格容易一路击穿网格下沿，钱还没补完就用光。"),
        ("日均振幅 0.5%–2%", "网格的一格价差主要来自日内波动。低于 0.5% 扣完手续费几乎白做；高于 2% 要准备更宽的价格区间和更多资金。"),
        ("震荡 > 单边", "收盘价长期在 MA20 附近来回最理想。单边上涨会早早卖飞，单边下跌会越补越套——这两个方向网格都不擅长。"),
        ("避开刚创新高 / 新低", "最新价贴着 60 日最高价，容易一买就回落；贴着最低价，容易一路向下破网。"),
        ("资金要够 4 手", "每手 100 份：锚定价 2 手 + 至少 1 档 2 手。买不满 4 手就没有机动空间，网格等于单笔押注。")
    ]

    private func runReplay() {
        guard let plan = store.data.dayGridPlans.first(where: { $0.code == code }) else { message = "先保存该标的的网格计划。"; return }
        guard let replay = store.replayGrid(plan: plan, day: selectedDay) else { message = "该日分时覆盖不足 70% 或存在超过 10 分钟的缺口，无法给出可信回放。"; return }
        result = replay
        if replay.fills == 0 {
            let budget = plan.capital / Double(plan.levelsEachSide * 2 + 2)
            let oneLot = plan.anchor * 100 + plan.feePerOrder
            message = budget < oneLot ? "资金不够：每档约 \((budget).cny())，按当前中枢买入 100 份约需 \((oneLot).cny())。减少档数或增加计划资金后复盘。" : "数据中没有穿越网格档位；也可能是该日分时覆盖不足。"
        }
    }
}

private struct StrategicGridLevel: Identifiable {
    let index: Int
    let price: Double
    let distancePercent: Double
    var id: Int { index }
}

private struct StrategicGridResult {
    let current: Double
    let atrPercent: Double
    let gridPercent: Double
    let lower: Double
    let upper: Double
    let count: Int
    let buyCount: Int
    let sellCount: Int
    let budgetPerBuy: Double
    let sellLot: Int
    let requiredShares: Int
    let ownedShares: Double
    let ma250: Double?
    let levels: [StrategicGridLevel]
}

/// 网页版的静态/中长期网格规划，和日内网格分时 CSV 回放是两项独立工具。
private struct StrategicGridPlannerView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var capital = "3000"
    @State private var gapPercent = ""
    @State private var ownedShares = ""
    @State private var result: StrategicGridResult?
    @State private var message = ""

    private var instruments: [GridInstrument] {
        let quotes = store.data.quotes.map { GridInstrument(code: $0.code, name: $0.name, price: $0.price) }
        let holdings = store.data.holdings.filter { $0.kind == .etf }.map { GridInstrument(code: $0.code, name: $0.name, price: $0.current) }
        return Array(Dictionary((quotes + holdings).map { ($0.code, $0) }, uniquingKeysWith: { first, second in first.price > 0 ? first : second }).values)
            .sorted { $0.code < $1.code }
    }
    private var selected: GridInstrument? { instruments.first { $0.code == code } }

    var body: some View {
        NavigationStack {
            Form {
                Section("标的与预算") {
                    Picker("标的", selection: $code) {
                        ForEach(instruments) { item in Text("\(item.name) · \(item.code)").tag(item.code) }
                    }
                    if let selected {
                        LabeledContent("当前行情", value: selected.price > 0 ? selected.price.num(4) : "暂无")
                        LabeledContent("日线数据", value: "\(store.dailyBars[code]?.count ?? 0) 根")
                    }
                    NumberFieldWithHint(title: "计划资金（元）", example: "3000",
                                        hint: "只用于规划买卖档位和每档预算，不会动用真实账户。金额越少，能排下的档位越少。",
                                        text: $capital, keyboard: .decimalPad)
                    NumberFieldWithHint(title: "每档间距（%）", example: "留空＝按近 14 日波动自动估算",
                                        hint: "相邻两档的价差：填 1.5 表示价格每变动 1.5% 就挂一档。留空则按近 14 日 ATR 自动估算；手动填一般是刻意做得比实测波动更宽或更窄。",
                                        text: $gapPercent, keyboard: .decimalPad)
                    NumberFieldWithHint(title: "现有持仓（份）", example: "0",
                                        hint: "用来检查上方卖档有没有货可卖；填 0 就只生成买档。这里是「份」不是「手」，1 手 = 100 份，持有 3 手请填 300。",
                                        text: $ownedShares, keyboard: .numberPad)
                    Button("生成中长期网格") { generate() }.disabled(code.isEmpty)
                    if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                if let result {
                    Section("生成的计划（对照着看）") {
                        Text("每行读法：价位 = 挂单价格；右百分比 = 距当前价多远；「约 N 份」= 这一档按预算能买/能卖的份额。现价下方是买入档，上方是卖出档。")
                            .font(.footnote).foregroundStyle(.secondary)
                        LabeledContent("当前价（参考）", value: result.current.num(4))
                        LabeledContent("网格覆盖价格", value: "\(result.lower.num(3)) – \(result.upper.num(3))（共 \(result.count) 档）")
                        LabeledContent("每档间距", value: "\(result.gridPercent.num(2))%")
                        LabeledContent("近 14 日日均波动（ATR）", value: "\(result.atrPercent.num(2))%")
                        LabeledContent("每档预算", value: result.budgetPerBuy.cny(0))
                        LabeledContent("下方买档 / 上方卖档", value: "\(result.buyCount) 档 / \(result.sellCount) 档")
                        LabeledContent("卖档需要持有", value: "\(result.requiredShares) 份（你填了 \(Int(result.ownedShares)) 份）")
                        if let ma = result.ma250 { LabeledContent("年线（MA250）", value: result.current >= ma ? "现价在年线上方 \(ma.num(3))" : "现价在年线下方 \(ma.num(3))") }
                        else { LabeledContent("年线（MA250）", value: "日线不足 250 根，暂无") }
                    }
                    Section("价位表 · 从上到下＝从高到低") {
                        ForEach(result.levels.reversed()) { level in
                            let isBuy = level.price < result.current
                            HStack {
                                Text(isBuy ? "买入" : "卖出").foregroundStyle(isBuy ? .green : .red)
                                Text(level.price.num(3)).monospacedDigit()
                                Spacer()
                                Text("\(level.distancePercent >= 0 ? "+" : "")\(level.distancePercent.num(2))%")
                                    .foregroundStyle(.secondary).monospacedDigit()
                                if isBuy {
                                    let rawShares = result.budgetPerBuy > 0 && level.price.isFinite && level.price > 0
                                        ? result.budgetPerBuy / (level.price * 100) : 0
                                    let shares = rawShares.isFinite ? Int(min(1_000_000_000, max(0, rawShares))) * 100 : 0
                                    Text("约 \(shares) 份").font(.caption).foregroundStyle(.secondary)
                                } else if abs(level.price - result.current) > result.current * 0.001 {
                                    Text("约 \(result.sellLot) 份").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Text("静态参数规划，不代表收益预测。单边上涨可能过早卖出，单边下跌可能持续买入；档位成交还受整手、费用、流动性和涨跌停影响。MA250仅作为趋势背景，不是买卖指令。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .listRowBackground(Color.clear)
            .buttonStyle(.plain)
            .background(.clear)
            .navigationTitle("中长期网格计划")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear {
                if code.isEmpty, let first = instruments.first { code = first.code; selectInstrument(first.code) }
                else { selectInstrument(code) }
            }
            .onChange(of: code) { _, value in gapPercent = ""; selectInstrument(value) }
            .task(id: code) {
                guard !code.isEmpty, (store.dailyBars[code]?.count ?? 0) < 250 else { return }
                do { _ = try await store.fetchDailyBars(code: code, count: 640, force: true) }
                catch { message = "日线加载失败：\(error.localizedDescription)" }
            }
        }
    }

    private func selectInstrument(_ value: String) {
        guard !value.isEmpty else { return }
        let bars = store.dailyBars[value] ?? []
        let owned = store.data.holdings.first { $0.code == value && $0.kind == .etf }?.quantity ?? 0
        ownedShares = owned.isFinite && owned > 0 ? String(Int(min(owned, 1_000_000_000))) : "0"
        result = nil
        if bars.count >= 15 {
            let recent = Array(bars.suffix(14))
            let ranges = recent.enumerated().map { index, bar -> Double in
                let previous = index > 0 ? recent[index - 1].close : (bars.dropLast(14).last?.close ?? bar.close)
                return max(max(bar.high - bar.low, abs(bar.high - previous)), abs(bar.low - previous))
            }
            let current = selected?.price ?? bars.last?.close ?? 0
            if current > 0, gapPercent.isEmpty {
                gapPercent = String(format: "%.2f", min(6, max(1.5, ranges.reduce(0, +) / Double(ranges.count) / current * 120)))
            }
        }
    }

    private func generate() {
        guard let selected, selected.price.isFinite, selected.price > 0 else { message = "当前标的没有有效价格，请先刷新行情。"; return }
        let bars = store.dailyBars[code] ?? []
        guard bars.count >= 60 else { message = "日线少于 60 根，无法生成完整 60 日区间；先刷新该标的日K。"; return }
        guard let cash = Double(capital), cash.isFinite, cash > 0, cash <= 1_000_000_000_000 else {
            message = "可用资金需大于 0 且不超过 1 万亿元。"; return
        }
        let current = selected.price
        let recent = Array(bars.suffix(60))
        let high60 = recent.map(\.high).max() ?? current
        let low60 = recent.map(\.low).min() ?? current
        let last14 = Array(bars.suffix(15))
        var trueRanges: [Double] = []
        if last14.count > 1 {
            for i in 1..<last14.count {
                let bar = last14[i], previous = last14[i - 1].close
                trueRanges.append(max(max(bar.high - bar.low, abs(bar.high - previous)), abs(bar.low - previous)))
            }
        }
        let atr = trueRanges.isEmpty ? current * 0.02 : trueRanges.reduce(0, +) / Double(trueRanges.count)
        let atrPercent = atr / current * 100
        let gap = (Double(gapPercent) ?? min(6, max(1.5, atrPercent * 1.2)))
        guard gap.isFinite, gap >= 0.1, gap <= 100 else { message = "每格幅度需在 0.1% 到 100% 之间。"; return }
        let oneLot = current * 100
        let affordableLots = Int(floor(cash / oneLot))
        guard affordableLots >= 1 else {
            message = "资金不足：当前价格买入 100 份约需 \(oneLot.cny())。"; result = nil; return
        }

        // 档数同时受资金、历史区间和最多 8 档约束。旧算法先把上下范围锁死在
        // 约 ±4 个格距，所以无论输入多少钱都几乎恒定为 4 个买档。
        // 现在资金越充足，可承担的买档越多；每档至少保证能买 100 份。
        let gapFraction = gap / 100
        let capitalBuyLimit = min(8, max(1, Int(log2(Double(affordableLots) + 1))))
        let historicalBuySpan = max(current - low60, current * gapFraction)
        let historicalSellSpan = max(high60 - current, current * gapFraction)
        let historyBuyLimit = min(8, max(1, Int(floor(historicalBuySpan / (current * gapFraction)))))
        let historySellLimit = min(8, max(1, Int(floor(historicalSellSpan / (current * gapFraction)))))
        let buys = min(capitalBuyLimit, historyBuyLimit)
        let sharesInput = Double(ownedShares) ?? 0
        let shares = sharesInput.isFinite && sharesInput > 0 ? min(sharesInput, 1_000_000_000) : 0
        let availableSellLots = Int(floor(shares / 100))
        let sells = availableSellLots > 0 ? min(historySellLimit, availableSellLots) : historySellLimit
        let perBuy = cash / Double(buys)
        guard perBuy + 0.0001 >= oneLot else {
            message = "资金不足以覆盖 \(buys) 个买档的整手交易，请增加资金或提高格距。"; result = nil; return
        }

        var levels: [StrategicGridLevel] = []
        for level in 1...buys {
            let price = current * pow(1 - gapFraction, Double(level))
            levels.append(StrategicGridLevel(index: -level, price: price,
                distancePercent: (price / current - 1) * 100))
        }
        for level in 1...sells {
            let price = current * pow(1 + gapFraction, Double(level))
            levels.append(StrategicGridLevel(index: level, price: price,
                distancePercent: (price / current - 1) * 100))
        }
        levels.sort { $0.price < $1.price }
        let finalLower = levels.first?.price ?? current
        let finalUpper = levels.last?.price ?? current
        let count = levels.count
        let buyLot = Int(floor(perBuy / oneLot)) * 100
        let sellLot = sells > 0 && availableSellLots > 0
            ? min(buyLot, max(1, availableSellLots / sells) * 100)
            : 0
        let ma = bars.count >= 250 ? bars.suffix(250).map(\.close).reduce(0, +) / 250 : nil
        result = StrategicGridResult(current: current, atrPercent: atrPercent, gridPercent: gap,
            lower: finalLower, upper: finalUpper, count: count, buyCount: buys, sellCount: sells,
            budgetPerBuy: perBuy, sellLot: sellLot, requiredShares: sellLot * sells,
            ownedShares: shares, ma250: ma, levels: levels)
        if shares <= 0 {
            message = "已按资金生成 \(buys) 个买档；未填写现有持仓，卖档暂不分配份额。"
        } else if shares < Double(sellLot * sells) {
            message = "规划已生成；当前持仓低于全部卖档预留份数。"
        } else {
            message = "已按资金与历史区间生成 \(buys) 个买档、\(sells) 个卖档。"
        }
    }
}

enum SettingsViewMode {
    case all, app, sync
}

struct SettingsView: View {
    let mode: SettingsViewMode
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guanpan.native.backgroundRefresh.enabled") private var backgroundRefreshEnabled = false
    @AppStorage("guanpan.native.fontScale") private var fontScale: Double = 1
    @State private var themePickerExpanded = false
    @AppStorage("guanpan.native.legacyArchive.expanded") private var legacyArchiveExpanded = false
    @AppStorage("guanpan.native.settings.showMore") private var showMoreSettings = false
    @AppStorage(NASSyncService.urlKey) private var nasURL = ""
    @AppStorage(NASSyncService.automaticKey) private var nasAutoSync = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var confirmNASDownload = false
    @State private var confirmNASUpload = false
    @State private var checkingNAS = false
    @State private var loadingNASHistory = false
    @State private var confirmNASRestore = false
    @State private var restoringNAS = false
    @State private var selectedNASVersion: NASSyncVersion?
    @State private var nasVersions: [NASSyncVersion] = []
    @State private var nasToken = ""
    @State private var message = ""
    @State private var marketHolidayText = ""
    @State private var showManualPriceEditor = false
    @State private var confirmUndoLastSave = false
    @State private var showOperationHistory = false
    @State private var notificationBusy = false
    @State private var notificationEnabled = false

    init(mode: SettingsViewMode = .all) {
        self.mode = mode
    }

    var body: some View {
        formContent
            .sheet(isPresented: $showOperationHistory) { OperationHistoryView() .themedSheetBackground() }
            .sheet(isPresented: $showManualPriceEditor) { ManualQuoteOverrideEditor() .themedSheetBackground() }
            .onAppear {
                BackgroundQuoteRefresh.configure(store: store)
                if marketHolidayText.isEmpty {
                    marketHolidayText = store.data.customMarketHolidays.sorted().joined(separator: "\n")
                }
                nasToken = NASCredentialStore.load() ?? ""
            }
            .onChange(of: backgroundRefreshEnabled) { _, _ in BackgroundQuoteRefresh.configure(store: store) }
            .onChange(of: store.data.quoteRefreshSeconds) { _, _ in BackgroundQuoteRefresh.configure(store: store) }
            .onChange(of: nasURL) { _, _ in store.configureNASSync() }
            .onChange(of: nasToken) { _, value in
                _ = NASCredentialStore.save(value)
                store.configureNASSync()
            }
            .onChange(of: nasAutoSync) { _, _ in store.configureNASSync() }
            .onDisappear { themePickerExpanded = false }
            .confirmationDialog("从 NAS 下载会覆盖本机原生账本。确认已备份本机数据？", isPresented: $confirmNASDownload, titleVisibility: .visible) {
                Button("下载并覆盖本机", role: .destructive) { Task { await store.downloadFromNAS() } }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("撤销会恢复上次保存前的整份账本，并覆盖当前本机数据。确定继续？", isPresented: $confirmUndoLastSave, titleVisibility: .visible) {
                Button("恢复上次保存前的账本", role: .destructive) {
                    message = store.undoLastSave() ? "已恢复上次保存前的账本。" : "没有可恢复的上一次保存。"
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("上传会覆盖 NAS 上的原生账本，其他原生设备下次同步会收到这份数据。确认已核对？", isPresented: $confirmNASUpload, titleVisibility: .visible) {
                Button("上传并覆盖 NAS", role: .destructive) { Task { await store.uploadToNAS(allowEmptyOverwrite: true) } }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("恢复 NAS 版本 \(selectedNASVersion?.revision ?? 0)？恢复后会替换 NAS 当前账本和本机账本，并作为新版本保存。", isPresented: $confirmNASRestore, titleVisibility: .visible) {
                Button("恢复此版本", role: .destructive) {
                    if let version = selectedNASVersion { restoreNASVersion(version) }
                }
                Button("取消", role: .cancel) { selectedNASVersion = nil }
            }
            .fileExporter(isPresented: $showExporter, document: PortfolioBackup(data: store.data, intradayBars: store.intradayBars, dailyBars: store.dailyBars.values.flatMap { $0 }), contentType: .json, defaultFilename: "观盘Pro原生备份") { result in
                handleExportResult(result)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                handleImportResult(result)
            }
    }

    /// 表单主体单独成表达式：与尾部三十余个修饰符分开做类型检查，避免整条 body 超时。
    private var formContent: some View {
        NavigationStack {
            Form {
                if mode != .sync {
                    appearanceSection
                    ledgerSection
                    quoteSection
                    accountingSection
                }
                if mode == .all {
                    Section {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showMoreSettings.toggle() }
                        } label: {
                            Label(showMoreSettings ? "收起备份、同步与通知" : "更多设置：备份、同步与通知",
                                  systemImage: showMoreSettings ? "chevron.up" : "chevron.down")
                        }
                    }
                }
                if mode == .sync || (mode == .all && showMoreSettings) {
                    dataSection
                    nasSection
                    notificationSection
                }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle(mode == .sync ? "数据与同步" : mode == .app ? "应用设置" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .appListLayout()
            .listRowBackground(Color.clear)
            .buttonStyle(.plain)
            .background(.clear)
        }
        // presentationBackground 要挂在 sheet 的导航根上；挂在 Form 内层会留下系统默认的不透明白底。
        .themedSheetBackground()
    }

    @ViewBuilder private var appearanceSection: some View {
        // 只留配色主题。
        // 图片背景 / 渐变背景 / 背景遮罩 / 毛玻璃 / 卡片融合 这一整组已按用户要求移除 ——
        // 背景图要靠卡片半透明透出来，每个主题的透明度都得单独调才好看；
        // 而配色主题本身已经能拉开观感差异，不必再维护「图 × 主题」两套变量的组合。
        Section("配色主题") {
            DisclosureGroup(isExpanded: $themePickerExpanded) {
                let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(allThemes, id: \.rawValue) { item in
                        ThemePreviewCard(appearance: item,
                                         accent: AccentPreset(rawValue: store.data.accentColorName)?.color ?? item.accentColor,
                                         selected: store.appearance == item) {
                            Haptics.selection()
                            store.appearance = item
                        }
                    }
                }
                .padding(.vertical, 6)
                Text("主题同时决定页面和卡片底色；强调色可在下方单独调整。")
                    .font(.footnote).foregroundStyle(.secondary)
            } label: {
                HStack {
                    Label("当前主题", systemImage: "paintpalette")
                    Spacer()
                    Text(store.appearance.title).foregroundStyle(.secondary)
                }
            }
        }
        if themePickerExpanded {
        Section("强调色") {
            Picker("强调色", selection: Binding(
                get: { store.data.accentColorName },
                set: { store.data.accentColorName = $0; Haptics.selection(); store.save(label: "修改账本或设置") })) {
                ForEach(AccentPreset.allCases) { preset in Text(preset.title).tag(preset.rawValue) }
            }
            Text("选「跟随主题」时用主题自带强调色；选其他则覆盖全部主题。")
                .scaledFont(10).foregroundStyle(.secondary)
        }
        Section("定时自动切换深浅") {
            Picker("自动切换", selection: Binding(
                get: { store.data.autoThemeSchedule },
                set: { store.data.autoThemeSchedule = $0; store.save(label: "修改账本或设置") })) {
                Text("关闭").tag("")
                Text("日出日落（19:00–07:00 深色）").tag("sun")
                Text("22:00–07:00 深色").tag("22:00-07:00")
                Text("20:00–08:00 深色").tag("20:00-08:00")
            }
            if !store.data.autoThemeSchedule.isEmpty {
                Text("开启后每分钟检查一次；到点自动切换，会覆盖上面所选主题的深浅。")
                    .scaledFont(10).foregroundStyle(.secondary)
            }
        }
        Section("字号") {
            Picker("字号", selection: $fontScale) {
                ForEach(FontScalePreset.allCases) { preset in Text(preset.title).tag(preset.value) }
            }
            .pickerStyle(.segmented)
            Text("App 内字号倍率，会与系统「设置 → 显示与亮度 → 文字大小」叠加。改大后部分紧凑网格会自动换行。")
                .scaledFont(10).foregroundStyle(.secondary)
            HStack {
                Text("预览：总资产 ¥1,234,567.89").scaledFont(13, weight: .semibold, design: .rounded)
                Spacer(minLength: 0)
            }
        }
        }
    }

    private var allThemes: [AppAppearance] {
        [.system, .dark, .oled, .blue, .green, .purple, .sakura, .cyber, .amber, .coffee, .graphite, .light, .paper, .mint]
    }

    /// 主题预览卡：直接画出该主题的底色渐变 + 强调色 + 深浅标记，选中加边框。
    private struct ThemePreviewCard: View {
    let appearance: AppAppearance
    let accent: Color
    let selected: Bool
    let action: () -> Void

    private var theme: AppTheme { AppTheme.palette(for: appearance) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    theme.gradient
                        .frame(height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Circle().fill(accent).frame(width: 9, height: 9)
                        .padding(6)
                }
                HStack(spacing: 3) {
                    Text(appearance.title).scaledFont(11, weight: .medium).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(11).foregroundStyle(accent)
                    }
                }
                Text(theme.isLight ? "浅色" : "深色")
                    .scaledFont(9).foregroundStyle(.secondary)
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.6) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

}

    @ViewBuilder private var ledgerSection: some View {
        Section("现金账本") {
            LabeledContent("当前参考现金", value: (store.data.cash).cny())
            Text("现金余额请在“资产”页记录转入/转出，保留现金流历史，避免影响快照收益计算。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("交易默认联动现金", isOn: Binding(get: { store.data.cashLinkedByDefault }, set: { store.data.cashLinkedByDefault = $0; store.save(label: "修改账本或设置") }))
        }
        Section("交易所休市日") {
            Text("**通常不用填**：App 会用上证指数的日 K 自动识别交易日 —— 有 K 线的日期就是交易日，没有的就是休市，跨年和临时休市都会自动跟上。这里只用于手动覆盖（例如交易所临时调休、或你想把某天排除在外）。每行一个日期（YYYY-MM-DD），自定义日期会随原生备份和 NAS 同步。")
                .font(.footnote).foregroundStyle(.secondary)
            // 全局把 UIScrollView 背景设为透明后，TextEditor（UIScrollView 子类）也跟着透明了，
            // 输入框会看不见。这里单独恢复不透明底。
            TextEditor(text: $marketHolidayText).frame(minHeight: 110)
                .font(.system(.footnote, design: .monospaced))
                .scrollContentBackground(.visible)
            HStack {
                Button("保存休市日") { saveMarketHolidays() }
                Spacer()
                Button("清空自定义日期", role: .destructive) {
                    marketHolidayText = ""; saveMarketHolidays()
                }
            }
            Text("当前自定义 \(store.data.customMarketHolidays.count) 天。ETF 日收益日历会将周末、已知休市日和日 K 覆盖区间内无交易记录的日期显示为“休市”。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var quoteSection: some View {
        Section("行情刷新") {
            Toggle("自动刷新行情", isOn: Binding(get: { store.data.quoteRefreshSeconds > 0 }, set: { store.data.quoteRefreshSeconds = $0 ? max(5, store.data.quoteRefreshSeconds) : 0; store.save(label: "修改账本或设置") }))
            Stepper(value: Binding(get: { max(5, store.data.quoteRefreshSeconds) }, set: { store.data.quoteRefreshSeconds = min(600, max(5, $0)); store.save(label: "修改账本或设置") }), in: 5...600, step: 5) {
                LabeledContent("自动刷新间隔", value: store.data.quoteRefreshSeconds > 0 ? "\(store.data.quoteRefreshSeconds) 秒" : "已关闭")
            }
            Text("最短 5 秒，与网页版一致。行情走 iPhone 直连，刷新频率由本机控制，不经过 NAS。")
                .font(.footnote).foregroundStyle(.secondary).disabled(store.data.quoteRefreshSeconds == 0)
            Toggle("自动保存每日分时", isOn: Binding(get: { store.data.intradayCaptureEnabled }, set: { store.data.intradayCaptureEnabled = $0; store.save(label: "修改账本或设置") }))
            Text("前台刷新时记录实时点，并每 30 分钟至多补全一次自选和场内持仓的最近交易日整日分时；旧日期持续保留，可在“工具－分时采集与历史复盘”查看。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("晚间打开基金页时自动更新已公布净值", isOn: Binding(get: { store.data.automaticFundNAVRefreshEnabled }, set: { store.data.automaticFundNAVRefreshEnabled = $0; store.save(label: "修改账本或设置") }))
            Text("北京时间 19:00 后每天最多检查一次；只在打开基金页时触发，不保证后台准时运行。更新的是已公布净值，不包含盘中估值。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("允许系统安排后台刷新", isOn: $backgroundRefreshEnabled)
            Text("前台按设置间隔刷新；后台刷新由 iOS 自主安排，时间和频率不保证。后台只尝试更新行情并触发已授权的本地价格提醒，不采集分时、不运行影子盘，也不刷新基金净值。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("图表显示") {
            Picker("分时价格线", selection: Binding(get: { store.data.intradayLineColorMode }, set: { store.data.intradayLineColorMode = $0; store.save(label: "修改账本或设置") })) {
                Text("跟随主题（单色）").tag(IntradayLineColorMode.automatic)
                Text("白色").tag(IntradayLineColorMode.white)
                Text("黑色").tag(IntradayLineColorMode.black)
                Text("主题单色（兼容旧设置）").tag(IntradayLineColorMode.upDown)
            }
        }
    }

    @ViewBuilder private var accountingSection: some View {
        Section("成本口径") {
            Picker("持仓成本显示", selection: Binding(get: { store.data.costAccountingMode }, set: { store.data.costAccountingMode = $0; store.save(label: "修改账本或设置") })) {
                Text("移动加权").tag(CostAccountingMode.weightedAverage)
                Text("摊薄（同花顺）").tag(CostAccountingMode.diluted)
            }
            Text("摊薄口径会把已实现盈亏折算到剩余份额的显示成本中；账本原始加权成本和每笔已实现盈亏保持不变。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("仓位提示") {
            Toggle("显示仓位类提示", isOn: Binding(get: { store.data.positionHintsEnabled }, set: { store.data.positionHintsEnabled = $0; store.save(label: "修改账本或设置") }))
            Stepper(value: Binding(get: { store.data.globalPositionLimitPercent }, set: { store.data.globalPositionLimitPercent = min(100, max(0, $0)); store.save(label: "修改账本或设置") }), in: 0...100, step: 1) {
                LabeledContent("全局单只上限", value: store.data.globalPositionLimitPercent > 0 ? "\((store.data.globalPositionLimitPercent).num(0))%" : "不限制")
            }.disabled(!store.data.positionHintsEnabled)
            Text("在工具页按持仓市值占总资产比例显示上限提示；现金占比达到 60% 或低于 5% 时也提示。只提示，不会自动交易。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("手动行情兜底") {
            Button("手动填价与恢复自动行情") { showManualPriceEditor = true }
            Text("可为自选和 ETF 持仓填写现价、昨收。手填价格会覆盖显示行情，不参与价格提醒或分时采集；清除后重新请求行情。")
                .font(.footnote).foregroundStyle(.secondary)
            if !store.data.manualQuoteOverrides.isEmpty {
                LabeledContent("当前手填", value: "\(store.data.manualQuoteOverrides.count) 只")
            }
        }
    }

    @ViewBuilder private var dataSection: some View {
        Section("数据备份") {
            Button("导出 JSON 备份") { showExporter = true }
            Button("导入 JSON 备份") { showImporter = true }
            Text("导入会整体替换原生版本地账本。可选择原生 JSON 备份或观盘 Pro 网页版完整 JSON 备份；图片背景已下线，备份只保存账本、设置和行情历史。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("操作撤销") {
            Button("操作记录与撤销（最近 \(store.operationAudit.count) 条）") { showOperationHistory = true }
            Text("记录你主动执行的账本修改，最多保留 20 条；行情、净值和后台自动补记不进入记录，只能撤销最近一条。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("撤销上一次本机保存", role: .destructive) { confirmUndoLastSave = true }
                .disabled(!store.canUndoLastSave)
            Text("只保留一份上次保存前的账本副本。撤销会恢复整份账本，并同步到已配置的 NAS；行情或其他自动保存也可能成为撤销点。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var nasSection: some View {
        Section("NAS 多设备同步") {
            HStack {
                TextField("服务器地址，例如 http://192.168.1.20:8788", text: $nasURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { nasURL = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("从剪贴板粘贴 NAS 地址")
            }
            Text("当前配套 NAS 服务支持免口令同步，填写地址后即可测试、下载和上传。")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("兼容旧服务器（可选口令）") {
                HStack {
                    TextField("服务器启用了 SYNC_TOKEN 时填写", text: $nasToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { nasToken = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("从剪贴板粘贴 NAS 口令")
                }
                Text("免口令服务器保持空白即可。已有口令只用于兼容你主动配置了 SYNC_TOKEN 的旧服务器。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("自动同步", isOn: $nasAutoSync)
            // 三个动作语义不同，各自独立成行并加说明，避免误触「上传/下载」覆盖数据
            VStack(alignment: .leading, spacing: 4) {
                Button { testNAS() } label: {
                    Label(checkingNAS ? "正在检查…" : "① 测试连接", systemImage: "antenna.radiowaves.left.and.right")
                }.disabled(checkingNAS)
                Text("只探测 NAS 地址是否可达，不改动任何数据。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { Task { await store.synchronizeNASSafely() } } label: {
                    Label("② 安全同步（双向，冲突时暂停）", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("先比对两边改动再做合并；两台设备同时修改会暂停并提示，不会静默覆盖。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { confirmNASDownload = true } label: {
                    Label("③ 从 NAS 下载（覆盖本机）", systemImage: "arrow.down.circle")
                }
                Text("用 NAS 上的账本替换本机账本。方向单一，确认后执行。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { confirmNASUpload = true } label: {
                    Label("④ 上传到 NAS（覆盖云端）", systemImage: "arrow.up.circle")
                }
                Text("用本机账本替换 NAS 上的账本。方向单一，确认后执行。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(loadingNASHistory ? "正在读取历史版本…" : "查看 NAS 历史版本") { loadNASHistory() }
                .disabled(loadingNASHistory || restoringNAS)
            if !nasVersions.isEmpty {
                ForEach(nasVersions) { version in
                    Button {
                        selectedNASVersion = version
                        confirmNASRestore = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("版本 \(version.revision)")
                                Text(version.updatedAt).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                    }.disabled(restoringNAS)
                }
            }
            Text(store.nasSyncStatus).font(.footnote).foregroundStyle(.secondary)
            Text("自动同步会在应用启动、回到前台、本机数据变更后运行，并在前台每 60 秒检查一次其他设备的更新。应用进入后台时暂停轮询；iOS 后台刷新不保证运行。若两台设备同时修改，会暂停并提示冲突。手动下载或上传会覆盖数据，请先确认方向。原生空间为空时会先迁入 NAS 上可识别的网页账本；之后网页与原生各自同步，原生改动不会反向转换回网页格式。分时和日线缓存随原生账本同步。\n\n行情与净值走 iPhone 直连，不经过 NAS，也不需要穿透；只有在直连失败时才会用 NAS 行情代理兜底（用于收藏、自选、K线和基金重仓）。因此在外使用流量时行情照常刷新。最近 10 个 NAS 历史版本可查看和恢复；如果仍使用旧版一体化服务器包，历史按钮会提示接口缺失，请用源码包附带的历史恢复接口版服务包升级服务端，并保留原有 data 数据目录。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if !store.data.legacySettingsArchives.isEmpty {
            Section("旧版资料") {
                DisclosureGroup(isExpanded: $legacyArchiveExpanded) {
                    ForEach(store.data.legacySettingsArchives) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline)
                            Text(legacyArchiveDescription(item.id))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Text("这些资料来自旧版备份，只为避免迁移时丢失信息；当前 iOS 不会把其中的代码或参数当作设置执行。")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: {
                    HStack {
                        Label("迁移存档", systemImage: "archivebox")
                        Spacer()
                        Text("\(store.data.legacySettingsArchives.count) 项 · 不生效")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func legacyArchiveDescription(_ id: String) -> String {
        switch id {
        case "cfg": return "旧版界面和刷新偏好；当前 iOS 使用本页设置，不读取它。"
        case "profile": return "旧版记录的个人风格文字；仅保留，不参与当前建议。"
        case "ai": return "旧版 AI 分析结果缓存；可能已经过期，不参与当前分析。"
        case "tradePlans": return "旧版计划的原始存档；不会自动执行。"
        case "gridExperience": return "旧版网格模拟经验；不参与当前网格参数计算。"
        case "hol": return "旧版休市日期原始存档；有效日期已另行迁入当前日历。"
        case "gridmeta": return "旧版分时采集状态；当前版本不沿用运行状态。"
        case "marketTargets": return "旧版仓位和均线参数原始存档；当前设置以 iOS 页面为准。"
        case "dividendReference": return "旧版分红估算参考，不代表真实到账。"
        case "exchangeRates": return "旧版汇率参考值；当前版本不会把它当实时汇率。"
        case "manualPrices": return "旧版手填价格原始存档；已识别的数据会迁入当前手动行情。"
        default: return "旧版迁移时保留的只读资料；当前版本不执行。"
        }
    }

    @ViewBuilder private var notificationSection: some View {
        Section("系统通知") {
            Button(notificationBusy ? "正在请求权限…" : "开启并测试本地通知") { enableNotifications() }
                .disabled(notificationBusy)
            Text(notificationEnabled ? "已获得通知权限。价格提醒和数据源异常可发送本机通知；同类数据源提醒每天最多一次。行情后台监控和远程推送尚未实现。" : "通知权限由 iOS 管理。开启后可接收价格提醒和数据源异常通知。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result { message = error.localizedDescription }
    }

    /// 导入逻辑从 fileImporter 闭包里抽成方法，缩短 body 修饰符链。
    private func handleImportResult(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf: url)
            if let package = try? JSONDecoder().decode(NativeBackupEnvelope.self, from: bytes) {
                // JSONDecoder 会忽略老备份多出的 backgroundImageData 字段；
                // 当前版本不再读取或重新导出旧背景图片。
                store.replaceData(package.data, intradayBars: package.intradayBars, dailyBars: package.dailyBars)
                message = "原生备份已恢复（含 \(package.intradayBars.count) 个分时点、\(package.dailyBars.count) 个日线点）"
            } else {
                let migrated = try LegacyMigration.decodePackage(bytes)
                var nasMigrationNotice = ""
                if let legacyNAS = migrated.nasConfig {
                    let currentURL = nasURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let legacyURL = legacyNAS.url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let currentToken = NASCredentialStore.load() ?? ""
                    if (currentURL.isEmpty || currentURL == legacyURL) && currentToken.isEmpty {
                        if currentURL.isEmpty { nasURL = legacyURL }
                        let tokenSaved = NASCredentialStore.save(legacyNAS.token)
                        nasToken = tokenSaved ? legacyNAS.token : ""
                        if legacyNAS.automatic && !legacyNAS.token.isEmpty && tokenSaved { nasAutoSync = true }
                        if !tokenSaved {
                            nasMigrationNotice = "；NAS 地址已迁入，但系统未能保存同步口令"
                        } else if legacyNAS.token.isEmpty {
                            nasMigrationNotice = "；NAS 地址已迁入，旧备份未含同步口令"
                        } else {
                            nasMigrationNotice = "；NAS 地址和口令已迁入（口令存入 iOS Keychain）"
                        }
                    }
                }
                store.replaceData(migrated.data, intradayBars: migrated.intradayBars)
                store.configureNASSync()
                message = "网页备份已迁移：\(migrated.data.fundDCAPlans.count) 个定投计划、\(migrated.data.fundNAVHistory.count) 个基金净值点、\(migrated.data.manualQuoteOverrides.count) 个手填行情、\(migrated.data.etfDividendEvents.count) 条 ETF 分红事件、\(migrated.data.legacyDCAEvents.count) 个待核对定投期次、\(migrated.data.legacyGridArchives.count) 条旧网格记录（影子盘 \(migrated.data.legacyShadowArchives.count) 条）、\(migrated.data.legacySettingsArchives.count) 项旧版只读资料、\(migrated.intradayBars.count) 个分时点、\(migrated.data.quoteAlerts.count) 条价格提醒、\(migrated.data.customMarketHolidays.count) 个自定义休市日\(nasMigrationNotice)"
            }
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    private func saveMarketHolidays() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        var valid = Set<String>(), invalid = 0
        for line in marketHolidayText.split(whereSeparator: \.isNewline) {
            let day = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  formatter.date(from: day) != nil else { invalid += 1; continue }
            valid.insert(day)
        }
        store.data.customMarketHolidays = valid.sorted()
        store.save(label: "修改账本或设置")
        marketHolidayText = valid.sorted().joined(separator: "\n")
        message = invalid == 0 ? "已保存 \(valid.count) 个自定义休市日。" : "已保存 \(valid.count) 个日期，跳过 \(invalid) 行无效内容。"
    }

    private func enableNotifications() {
        notificationBusy = true
        Task {
            do {
                let allowed = try await NativeNotifications.requestPermission()
                notificationEnabled = allowed
                if allowed { try await NativeNotifications.send(title: "观盘 Pro", body: "iPhone 本地通知已开启。") }
                message = allowed ? "已安排一条测试提醒" : "通知未获授权，请在 iPhone 设置中允许通知"
            } catch { message = "通知设置失败：\(error.localizedDescription)" }
            notificationBusy = false
        }
    }

    private func testNAS() {
        checkingNAS = true
        Task { @MainActor in
            defer { checkingNAS = false }
            do {
                _ = try await NASSyncService.ping(base: nasURL, token: nasToken)
                store.nasSyncStatus = "NAS 连接正常，原生同步接口可用"
            } catch { store.nasSyncStatus = "连接失败：\(error.localizedDescription)" }
        }
    }

    private func loadNASHistory() {
        loadingNASHistory = true
        Task { @MainActor in
            defer { loadingNASHistory = false }
            do {
                nasVersions = try await NASSyncService.history(base: nasURL, token: nasToken)
                message = nasVersions.isEmpty ? "NAS 还没有可恢复的历史版本。" : "已读取 \(nasVersions.count) 个 NAS 历史版本。"
            } catch { message = "读取 NAS 历史失败：\(error.localizedDescription)" }
        }
    }

    private func restoreNASVersion(_ version: NASSyncVersion) {
        restoringNAS = true
        selectedNASVersion = nil
        Task { @MainActor in
            defer { restoringNAS = false }
            do {
                // Read the live revision immediately before restore. The server uses
                // this as an optimistic lock so another device's new write is preserved.
                let current = try await NASSyncService.get(base: nasURL, token: nasToken)
                _ = try await NASSyncService.restore(base: nasURL, token: nasToken,
                    revision: version.revision, expectedRevision: current.revision)
                await store.downloadFromNAS()
                nasVersions = try await NASSyncService.history(base: nasURL, token: nasToken)
                if store.nasSyncStatus.contains("失败") {
                    message = "NAS 已恢复版本 \(version.revision)，但本机下载未完成：\(store.nasSyncStatus)"
                } else {
                    message = "已恢复 NAS 版本 \(version.revision)，并同步到本机。"
                }
            } catch { message = "恢复失败：\(error.localizedDescription)" }
        }
    }
}

struct OperationHistoryView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUndo = false
    @State private var confirmClear = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("最多保留 20 条用户主动修改。只有最新一条可撤销；撤销会恢复整份账本，并同步到已配置的 NAS。行情与净值自动刷新不记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("最近操作") {
                    if store.operationAudit.isEmpty {
                        ContentUnavailableView("暂无操作记录", systemImage: "clock.arrow.circlepath")
                    }
                    ForEach(store.operationAudit.indices, id: \.self) { index in
                        let item = store.operationAudit[index]
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.body)
                                Text(item.date.formatted(date: .numeric, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index == 0 {
                                Button("撤销") { confirmUndo = true }.buttonStyle(.bordered)
                                    .disabled(!store.canUndoLatestOperation)
                            } else {
                                Text("仅查看").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !store.operationAudit.isEmpty {
                        Button("清空操作记录", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("操作记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("撤销最近一次“\(store.operationAudit.first?.label ?? "数据修改")”？整份账本将恢复到该操作之前。", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("撤销最近操作", role: .destructive) {
                    if let label = store.undoLatestOperation() { message = "已撤销：\(label)" }
                    else { message = "没有可撤销的操作。" }
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("清空操作历史？不会删除账本数据。", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { store.clearOperationAudit() }
                Button("取消", role: .cancel) { }
            }
            .alert("操作记录", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {
                Button("好", role: .cancel) { message = "" }
            } message: { Text(message) }
        }
    }
}

private struct ManualQuoteInstrument: Identifiable {
    var code: String
    var name: String
    var id: String { code }
}

private struct ManualQuoteOverrideEditor: View {
    @EnvironmentObject private var store: PortfolioStore
    private var instruments: [ManualQuoteInstrument] {
        var names: [String: String] = [:]
        for quote in store.data.quotes { names[quote.code] = quote.name }
        for holding in store.data.holdings where holding.kind == .etf { names[holding.code] = holding.name }
        return names.map { ManualQuoteInstrument(code: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("手填价格会覆盖行情显示，但不会触发价格提醒或写入分时历史。未填写昨收时，保留行情源的涨跌幅。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(instruments) { item in
                    ManualQuoteOverrideRow(instrument: item, value: store.data.manualQuoteOverrides[item.code])
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .keyboardDoneToolbar()
            .navigationTitle("手动填价")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    @Environment(\.dismiss) private var dismiss
}

private struct ManualQuoteOverrideRow: View {
    @EnvironmentObject private var store: PortfolioStore
    let instrument: ManualQuoteInstrument
    let value: ManualQuoteOverride?
    @State private var price: String
    @State private var previousClose: String
    @State private var message = ""

    init(instrument: ManualQuoteInstrument, value: ManualQuoteOverride?) {
        self.instrument = instrument; self.value = value
        _price = State(initialValue: value.map { String($0.price) } ?? "")
        _previousClose = State(initialValue: value?.previousClose.map { String($0) } ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(instrument.name) · \(instrument.code)").font(.subheadline)
            HStack {
                TextField("现价", text: $price).keyboardType(.decimalPad)
                TextField("昨收（可空）", text: $previousClose).keyboardType(.decimalPad)
            }
            HStack {
                Button("保存") { save() }
                Spacer()
                if value != nil { Button("清除覆盖", role: .destructive) { store.clearManualQuoteOverride(code: instrument.code) } }
            }.font(.caption)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 4)
    }
    private func save() {
        guard let parsedPrice = Double(price), parsedPrice.isFinite, parsedPrice > 0 else { message = "请输入大于 0 的现价。"; return }
        let previous = previousClose.isEmpty ? nil : Double(previousClose)
        guard previousClose.isEmpty || previous.map({ $0.isFinite && $0 > 0 }) == true else { message = "昨收须为空或大于 0。"; return }
        do { try store.setManualQuoteOverride(code: instrument.code, price: parsedPrice, previousClose: previous); message = "已保存并应用。" }
        catch { message = error.localizedDescription }
    }
}

struct NativeBackupEnvelope: Codable {
    var formatVersion = 3
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]

    init(data: PortfolioData, intradayBars: [IntradayBar], dailyBars: [DailyBar] = []) {
        self.data = data
        self.intradayBars = intradayBars
        self.dailyBars = dailyBars
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, data, intradayBars, dailyBars }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        data = try container.decode(PortfolioData.self, forKey: .data)
        intradayBars = try container.decodeIfPresent([IntradayBar].self, forKey: .intradayBars) ?? []
        dailyBars = try container.decodeIfPresent([DailyBar].self, forKey: .dailyBars) ?? []
    }
}

struct PortfolioBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]
    init(data: PortfolioData, intradayBars: [IntradayBar], dailyBars: [DailyBar] = []) {
        self.data = data; self.intradayBars = intradayBars; self.dailyBars = dailyBars
    }
    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if let package = try? JSONDecoder().decode(NativeBackupEnvelope.self, from: raw) {
            data = package.data; intradayBars = package.intradayBars; dailyBars = package.dailyBars
        } else {
            data = try JSONDecoder().decode(PortfolioData.self, from: raw); intradayBars = []; dailyBars = []
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(NativeBackupEnvelope(data: data, intradayBars: intradayBars, dailyBars: dailyBars)))
    }
}
