import Foundation
import SwiftUI
import UniformTypeIdentifiers

@main struct GuanpanAdvisorApp: App {
    @StateObject private var model = NextAppModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(model) } }
}

enum GPRoute: Hashable { case instrument(String), chart(String), decision(String?), grid, chat, portfolioAnalysis, dividends(String?), news, settings, alerts, fills, history, backups, worthOverview, indexDetail(String), profile }
private extension GPRoute {
    var persisted: NextRoute {
        switch self {
        case .instrument(let code): .instrument(code)
        case .chart(let code): .chart(code)
        case .decision(let code): .intent("decision", code ?? "")
        case .grid: .intent("grid", "")
        case .chat: .intent("ai-chat", "")
        case .portfolioAnalysis: .intent("portfolio-analysis", "")
        case .dividends(let code): .intent("dividends", code ?? "")
        case .news: .intent("news", "")
        case .settings: .settings
        case .alerts: .alerts
        case .fills: .fills
        case .history: .history
        case .backups: .backups
        case .worthOverview: .intent("worth", "")
        case .indexDetail(let symbol): .intent("index", symbol)
        case .profile: .intent("profile", "")
        }
    }
    static func restore(_ route: NextRoute) -> GPRoute? {
        switch route {
        case .instrument(let code): .instrument(code)
        case .chart(let code): .chart(code)
        case .intent(let action, let code):
            if action == "decision" { .decision(code.isEmpty ? nil : code) }
            else if action == "grid" { .grid }
            else if action == "ai-chat" { .chat }
            else if action == "portfolio-analysis" { .portfolioAnalysis }
            else if action == "dividends" { .dividends(code.isEmpty ? nil : code) }
            else if action == "news" { .news }
            else if action == "worth" { .worthOverview }
            else if action == "index" { code.isEmpty ? nil : .indexDetail(code) }
            else if action == "profile" { .profile }
            else { nil }
        case .settings: .settings
        case .alerts: .alerts
        case .fills: .fills
        case .history: .history
        case .backups: .backups
        // 数字孪生（A–H）已从 UI 全删，路由仅保留给旧备份解码；恢复时直接忽略。
        case .portfolio(_), .replay(_), .twin(_): nil
        }
    }
}
private struct GPTabItem {
    let tab: NextTab
    let title: String
    let icon: String
    /// XCUITest 定位用：自绘底栏不是系统 TabBar，`app.tabBars` 查不到，
    /// UI 测试一律按 `tab.<case>` identifier 找页签。
    let id: String
}

/// 五项主导航；做T/网格由 AI 指导进入，收息从真实持仓进入。
private struct GPTabBar: View {
    @Binding var selection: NextTab
    @Environment(\.gp) private var p
    private let items: [GPTabItem] = [
        GPTabItem(tab: .decision, title: "首页", icon: "house.fill", id: "tab.decision"),
        GPTabItem(tab: .market, title: "行情", icon: "chart.xyaxis.line", id: "tab.market"),
        GPTabItem(tab: .assets, title: "持仓", icon: "square.stack.3d.up.fill", id: "tab.assets"),
        GPTabItem(tab: .ai, title: "AI", icon: "sparkles", id: "tab.ai"),
        GPTabItem(tab: .mine, title: "我的", icon: "person.crop.circle.fill", id: "tab.mine")
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                tabButton(item)
            }
        }
        .padding(.top, 5)
        .padding(.bottom, 2)
        .background(p.paper)
        .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 0.7) }
    }

    private func tabButton(_ item: GPTabItem) -> some View {
        let selected = selection == item.tab
        return Button {
            selection = item.tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon).font(.system(size: 19, weight: .medium))
                Text(item.title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selected ? p.forest : p.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background { selectionMark(selected: selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.id)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 编辑室 / 拼图 / 杂志把选中项做成一块色块，仪表盘用顶线，现代卡片保持纯色文字。
    @ViewBuilder
    private func selectionMark(selected: Bool) -> some View {
        if selected {
            switch p.theme {
            case .editorial, .puzzle, .magazine:
                Capsule().fill(p.tint).padding(.horizontal, 12).padding(.vertical, 2)
            case .dashboard:
                VStack {
                    Capsule().fill(p.primary).frame(width: 16, height: 2)
                    Spacer(minLength: 0)
                }
            case .modern:
                Color.clear
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.scenePhase) private var scenePhase
    /// 底栏没有「overview」页签：历史默认值 / 旧版本存档里的 .overview 一律落到今日指导，
    /// 否则首次启动会整屏空白（所有页面 opacity 都是 0）。
    private var activeTab: NextTab {
        if let forced = Self.tabArgument { return forced }
        let stored = model.preferences.navigation.selectedTab
        switch stored {
        case .overview: return .decision
        case .laboratory: return .ai
        case .income: return .assets
        default: return stored
        }
    }
    private var tabSelection: Binding<NextTab> { Binding(get: { activeTab }, set: { model.preferences.navigation.selectedTab = $0; model.preferences = model.preferences }) }
    /// 保留当前页面场景作为语义信息；主题解析固定使用同一主题，避免跨页面忽明忽暗。
    private var activeScene: ThemeScene {
        switch activeTab {
        case .decision: return .home
        case .market: return .market
        case .assets: return .holdings
        case .income: return .aiReport
        case .ai: return .aiReport
        case .laboratory, .mine, .overview: return .detail
        }
    }
    /// 截图/回归专用启动参数：`-theme editorial|modern|dashboard|magazine|puzzle`
    /// 只在启动参数里出现时才生效，且只作用于本次运行，绝不写回偏好。
    /// 目的是让自动截图能拍到五套主题的真实渲染结果，而不是靠人手点。
    static let themeArgument: AppTheme? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-theme"), args.indices.contains(index + 1) else { return nil }
        return AppTheme(rawValue: args[index + 1])
    }()
    /// `-screen profile` 直达「AI 对我的了解」，用于截该页。
    static let screenArgument: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-screen"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()
    /// 截图/回归专用：`-tab assets` 等直达对应页签（持仓结构卡在 assets 页，窄屏环形图布局回归要截它）。
    /// 只作用于本次运行，绝不写回偏好（与 themeArgument 一致）。
    static let tabArgument: NextTab? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-tab"), args.indices.contains(index + 1) else { return nil }
        let tab = NextTab(rawValue: args[index + 1])
        switch tab {
        case .overview: return .decision
        case .laboratory: return .ai
        case .income: return .assets
        default: return tab
        }
    }()
    /// 手动选择优先；未选择时使用统一的东方编辑室默认主题，保证跨页配色一致。
    private var themeSelection: ThemeSelection {
        if let forced = Self.themeArgument { return .fixed(forced) }
        return model.preferences.themeStyle.map { ThemeSelection.fixed($0) } ?? .auto
    }
    private var resolvedTheme: AppTheme {
        // 自动主题采用编辑室作为全 App 的一致默认；用户选定任一主题后，所有页面共享它。
        ThemeManager.resolve(selection: themeSelection, scene: .home)
    }
    private var palette: GPPalette {
        GPPalette(scheme: effectiveScheme, comfort: model.theme == .comfort && !resolvedTheme.forcesDark,
                  appearance: model.preferences.appearance, theme: resolvedTheme)
    }
    var body: some View {
        // 五个主入口；隐藏页用透明度切换，保留各页导航状态。
        ZStack {
            palette.canvas.ignoresSafeArea()
            PrimaryNavigation(title: "行情", tab: .market) { MarketScreen() }
                .opacity(tabSelection.wrappedValue == .market ? 1 : 0)
                .allowsHitTesting(tabSelection.wrappedValue == .market)
                .accessibilityHidden(tabSelection.wrappedValue != .market)
            PrimaryNavigation(title: "持仓", tab: .assets) { AssetsScreen() }
                .opacity(tabSelection.wrappedValue == .assets ? 1 : 0)
                .allowsHitTesting(tabSelection.wrappedValue == .assets)
                .accessibilityHidden(tabSelection.wrappedValue != .assets)
            PrimaryNavigation(title: "AI", tab: .ai) { AIHubScreen() }
                .opacity(tabSelection.wrappedValue == .ai ? 1 : 0)
                .allowsHitTesting(tabSelection.wrappedValue == .ai)
                .accessibilityHidden(tabSelection.wrappedValue != .ai)
            PrimaryNavigation(title: "首页", tab: .decision, showsHeader: false) { ThemeHomeScreen() }
                .opacity(tabSelection.wrappedValue == .decision ? 1 : 0)
                .allowsHitTesting(tabSelection.wrappedValue == .decision)
                .accessibilityHidden(tabSelection.wrappedValue != .decision)
            PrimaryNavigation(title: "我的", tab: .mine) { MyHubScreen() }
                .opacity(tabSelection.wrappedValue == .mine ? 1 : 0)
                .allowsHitTesting(tabSelection.wrappedValue == .mine)
                .accessibilityHidden(tabSelection.wrappedValue != .mine)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { GPTabBar(selection: tabSelection) }
        .tint(palette.forest)
        .environment(\.gp, palette)
        .environment(\.gpAppearance, model.preferences.appearance)
        .dynamicTypeSize(model.preferences.appearance.dynamicTypeSize)
        // Use the same resolved scheme as the palette. Applying the legacy
        // appearance preference here could make native bars/status regions use
        // light mode while the selected theme's cards use dark colors.
        .preferredColorScheme(effectiveScheme)
        .sheet(isPresented: $model.showSearch) { SearchSheet() }
        .fullScreenCover(isPresented: .constant(Self.screenArgument == "profile")) {
            NavigationStack {
                InvestorProfileScreen()
                    .toolbar(.hidden, for: .navigationBar)
            }
            // 全屏覆盖层不总是继承父级自定义环境值，这里显式再注入一次，
            // 保证截图里的画像页和当前主题完全一致（五套主题读同一份画像数据）。
            .environment(\.gp, palette)
            .environment(\.gpAppearance, model.preferences.appearance)
            .preferredColorScheme(effectiveScheme)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // 派息不再需要手工一条条录：每次回到前台先同步派息历史，
            // 并按已实施派息与当前持仓份额自动登记待收（不自动加现金）。
            Task { await model.syncAllDividendHistory() }
            // 回到前台先补一次账本上传：手机上改了持仓、没手动点过上传，NAS 上就一直是旧快照。
            Task { await model.autoUploadBookIfNeeded() }
            // 打开软件就先刷一次：进来就有最新价，不用手动点。
            if !model.monitoredCodes.isEmpty { await model.refreshQuotes(codes: model.monitoredCodes) }
            if let code = model.preferences.navigation.selectedSecurity, !code.isEmpty {
                await model.refreshInstrument(code)
            }
            var tick = 0
            while !Task.isCancelled {
                let isSession = NextMarketClock.isRegularSession()
                if isSession {
                    await model.refreshQuotes(codes: model.monitoredCodes)
                    // 分时是分钟级数据，行情 10 秒一跳、曲线每 60 秒（6 跳）补一次就够。
                    tick += 1
                    if tick % 6 == 0,
                       let code = model.preferences.navigation.selectedSecurity, !code.isEmpty {
                        await model.refreshIntraday(code)
                    }
                }
                let delay: UInt64 = isSession ? 10_000_000_000 : 300_000_000_000
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
            }
        }
    }
    private var effectiveScheme: ColorScheme {
        // 五套主题各自保持完整的明暗语言。系统深色不会把浅色主题的二级页
        // 或原生导航栏单独翻成黑色；仪表盘也不会出现白色设置页。
        resolvedTheme.forcesDark || model.theme == .dark ? .dark : .light
    }
}

private struct PrimaryNavigation<Content: View>: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let title: String
    let tab: NextTab
    /// 首页自绘头部（问候语 + 主题化标题），这里就不再叠一层系统标题条。
    var showsHeader = true
    @State private var path: [GPRoute] = []
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack(path: $path) {
            content
                .gpKeyboardDismiss()
                .navigationTitle(title).navigationBarTitleDisplayMode(.large)
                .toolbar(path.isEmpty ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    if !path.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { model.showSearch = true } label: {
                                Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("全局搜索证券")
                            .accessibilityIdentifier("search.open")
                        }
                        if path.last != .settings {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { path.append(.settings) } label: {
                                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("设置")
                                .accessibilityIdentifier("settings.open")
                            }
                        }
                    }
                }
                .navigationDestination(for: GPRoute.self) { route in RouteDestination(route: route) }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if path.isEmpty && showsHeader {
                        HStack(spacing: 8) {
                            Text(title).font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                            Spacer()
                            Button { model.showSearch = true } label: {
                                Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(p.ink).frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("全局搜索证券")
                            .accessibilityIdentifier("search.open")
                            if tab != .mine {
                                Button { path.append(.settings) } label: {
                                    Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(p.ink).frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("设置")
                                .accessibilityIdentifier("settings.open")
                            }
                        }
                        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 4)
                        .background(p.canvas)
                    }
                }
        }
        .toolbarBackground(p.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(p.scheme, for: .navigationBar)
        .onAppear { path = (model.preferences.navigation.tabRoutes[tab.rawValue] ?? []).compactMap(GPRoute.restore) }
        .onChange(of: path) { _, value in model.saveNavigationPath(value.map(\.persisted), for: tab) }
        .onChange(of: model.routeRequestID) { _, _ in
            guard model.requestedTab == tab, let route = model.requestedRoute else { return }
            path.append(route)
        }
    }
}

private struct RouteDestination: View {
    let route: GPRoute
    @ViewBuilder var body: some View {
        switch route {
        case .instrument(let code): InstrumentDetailScreen(code: code)
        case .chart(let code): FullscreenChartScreen(code: code)
        case .decision(let code): DecisionScreen(code: code)
        case .grid: GridCandidateListScreen()
        case .chat: AIChatScreen()
        case .portfolioAnalysis: PortfolioAnalysisScreen()
        case .dividends(let code): DividendHistoryScreen(code: code)
        case .news: HoldingsNewsScreen()
        case .settings: SettingsScreen()
        case .alerts: AlertCenterScreen()
        case .fills: LedgerHistoryScreen()
        case .history: DecisionHistoryScreen()
        case .backups: BackupRestoreScreen()
        case .worthOverview: WorthBuyOverviewScreen()
        case .indexDetail(let symbol): IndexDetailScreen(symbol: symbol)
        case .profile: InvestorProfileScreen()
        }
    }
}

/// AI 主入口只给今天的结论与清晰的二级入口，避免把研究工具堆成一页长清单。
private struct AIHubScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p

    private var actions: [AIHubShortcut] {
        [
            AIHubShortcut(identifier: "ai.chat.open", title: "AI 持仓问答", detail: "基于真实持仓、最新行情和 NAS 研究继续追问", symbol: "bubble.left.and.bubble.right", route: .chat, accent: p.chartBlue),
            AIHubShortcut(identifier: "ai.grid.open", title: "智能网格候选", detail: "只展示今日统一指导生成的网格计划", symbol: "square.grid.2x2", route: .grid, accent: p.chartViolet),
            AIHubShortcut(identifier: "ai.news.open", title: "新闻与持仓影响", detail: "查看与真实持仓相关的事件", symbol: "newspaper", route: .news, accent: p.chartCost),
            AIHubShortcut(identifier: "ai.history.open", title: "决策记忆与复盘", detail: "查看过去判断和真实成交反馈", symbol: "clock.arrow.circlepath", route: .history, accent: p.jade)
        ]
    }

    private var guidanceSummary: String { model.dailyGuidance?.summary ?? model.guidanceStatus }
    private var guidanceMeta: String? {
        guard let guidance = model.dailyGuidance else { return nil }
        return "已扫描 \(guidance.items.count) 只真实持仓 · \(guidance.generatedAt.formatted(date: .omitted, time: .shortened))生成"
    }

    var body: some View {
        GPPageBackground { themedContent }
        .task { if model.dailyGuidance == nil { await model.refreshGuidance() } }
    }

    @ViewBuilder private var themedContent: some View {
        switch p.theme {
        case .editorial:
            VStack(alignment: .leading, spacing: 0) {
                EditorialSection(title: "今天需要做什么？", trailing: NextMarketClock.sessionDescription(), accent: p.chartGold) {
                    guidanceCard(style: .editorial)
                }
                EditorialSection(title: "研究与复盘", accent: p.jade) {
                    GPCard(accent: p.jade) {
                        ForEach(actions) { action in AIHubShortcutCard(action: action, layout: .editorialRow) }
                    }
                }
            }
        case .modern:
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI 私人投资顾问").font(.caption.weight(.semibold)).foregroundStyle(p.primary)
                    Spacer()
                    Text(NextMarketClock.sessionDescription()).font(.caption2).foregroundStyle(p.muted)
                }
                guidanceCard(style: .modern)
                EditorialSection(title: "研究与复盘", accent: p.chartBlue) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(actions) { action in AIHubShortcutCard(action: action, layout: .modernTile) }
                    }
                }
            }
        case .dashboard:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AI DECISION DESK").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.2)
                    Spacer()
                    Text(NextMarketClock.sessionDescription()).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                }.foregroundStyle(p.primary).padding(.horizontal, 3)
                guidanceCard(style: .dashboard)
                HStack(spacing: 8) {
                    dashboardMetric(title: "真实持仓", value: "\(model.book.positions.filter { $0.units > 0 }.count) 只")
                    dashboardMetric(title: "候选机会", value: "\(model.dailyGuidance?.items.filter(\.isActionable).count ?? 0) 条")
                    dashboardMetric(title: "NAS研究", value: NextServiceConnectionStatus.text(
                        configured: !model.preferences.nasBaseURL.isEmpty,
                        reachable: model.nasReachable, probedAt: model.nasProbedAt))
                }
                EditorialSection(title: "操作台", trailing: "研究 · 复盘", accent: p.chartBlue) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                        ForEach(actions) { action in AIHubShortcutCard(action: action, layout: .dashboardTile) }
                    }
                }
            }
        case .magazine:
            VStack(alignment: .leading, spacing: 8) {
                Text(Date.now.formatted(.dateTime.month(.abbreviated).day().weekday(.wide)))
                    .font(.caption.weight(.medium)).foregroundStyle(p.muted)
                Text("今天的投资判断")
                    .font(.system(size: 29, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                Text("观盘 · AI 私人投资手册").font(.caption).foregroundStyle(p.muted)
                guidanceCard(style: .magazine)
                EditorialSection(title: "延伸阅读", accent: p.chartCost) {
                    VStack(spacing: 8) {
                        ForEach(actions) { action in AIHubShortcutCard(action: action, layout: .magazineRow) }
                    }
                }
            }
        case .puzzle:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("观盘").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(p.ink)
                    Text("AI 私人投资顾问 · \(Date.now.formatted(.dateTime.month(.twoDigits).day()))")
                        .font(.caption2).foregroundStyle(p.muted)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    guidanceCard(style: .puzzle).gridCellColumns(2)
                    ForEach(actions) { action in AIHubShortcutCard(action: action, layout: .puzzleTile) }
                }
            }
        }
    }

    private func guidanceCard(style: AIHubGuidanceStyle) -> some View {
        GPCard(accent: style.accent(in: p)) {
            VStack(alignment: .leading, spacing: style == .magazine ? 12 : 8) {
                HStack {
                    Label("AI 今日指导", systemImage: "sparkles")
                        .font(.system(size: style == .dashboard ? 12 : 14, weight: .bold, design: style == .magazine ? .serif : .default))
                        .foregroundStyle(style.accent(in: p))
                    Spacer()
                    if style == .dashboard { Text("唯一建议").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(p.muted) }
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(p.muted)
                }
                Text(guidanceSummary)
                    .font(.system(size: style == .magazine ? 20 : (style == .dashboard ? 14 : 16), weight: .semibold,
                                  design: style == .magazine || style == .editorial ? .serif : .default))
                    .foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                if let guidanceMeta { Text(guidanceMeta).font(.caption2).foregroundStyle(p.muted) }
                NavigationLink(value: GPRoute.decision(nil)) {
                    if style == .puzzle {
                        Label("打开逐只持仓指导", systemImage: "arrow.right.circle.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(p.ink)
                    } else {
                        IntentRow(icon: "sparkles", title: "打开完整 AI 今日指导", detail: "查看做T、网格、持有或不交易的依据")
                    }
                }.accessibilityIdentifier("ai.guidance.open")
            }
        }
    }

    private func dashboardMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(p.muted)
            Text(value).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.line.opacity(0.7), lineWidth: 0.7))
    }
}

private enum AIHubGuidanceStyle: Equatable { case editorial, modern, dashboard, magazine, puzzle
    func accent(in palette: GPPalette) -> Color {
        switch self {
        case .editorial: palette.chartGold
        case .modern: palette.primary
        case .dashboard: palette.chartViolet
        case .magazine: palette.chartCost
        case .puzzle: palette.chartGold
        }
    }
}

private struct AIHubShortcut: Identifiable {
    let identifier: String
    let title: String
    let detail: String
    let symbol: String
    let route: GPRoute
    let accent: Color
    var id: String { identifier }
}

private enum AIHubShortcutLayout: Equatable { case editorialRow, modernTile, dashboardTile, magazineRow, puzzleTile }

private struct AIHubShortcutCard: View {
    @Environment(\.gp) private var p
    let action: AIHubShortcut
    let layout: AIHubShortcutLayout

    var body: some View {
        NavigationLink(value: action.route) {
            Group {
                switch layout {
                case .editorialRow, .magazineRow:
                    IntentRow(icon: action.symbol, title: action.title, detail: action.detail)
                case .modernTile:
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: action.symbol).font(.system(size: 19, weight: .semibold)).foregroundStyle(action.accent)
                        Text(action.title).font(.subheadline.weight(.bold)).foregroundStyle(p.ink)
                        Text(action.detail).font(.caption2).foregroundStyle(p.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, minHeight: 94, alignment: .leading).padding(12)
                case .dashboardTile:
                    HStack(spacing: 9) {
                        Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(action.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title).font(.system(size: 12, weight: .bold)).foregroundStyle(p.ink)
                            Text(action.detail).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 66, alignment: .leading).padding(10)
                case .puzzleTile:
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: action.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(action.accent)
                        Text(action.title).font(.subheadline.weight(.bold)).foregroundStyle(p.ink)
                        Text(action.detail).font(.caption2).foregroundStyle(p.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 102, alignment: .leading).padding(12)
                }
            }
            .background(p.tint.opacity(layout == .puzzleTile ? 0.7 : 0.45),
                        in: RoundedRectangle(cornerRadius: p.theme == .puzzle ? 18 : p.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.theme == .puzzle ? 18 : p.cardRadius, style: .continuous)
                .stroke(action.accent.opacity(0.28), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.identifier)
    }
}

/// 网格只是统一指导的一个结果；本页不维护第二套网格状态或模拟成交。
private struct GridCandidateListScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var selected: NextGuidanceItem?

    private var items: [NextGuidanceItem] {
        (model.dailyGuidance?.items ?? []).filter { $0.strategy == .grid }
    }

    var body: some View {
        GPPageBackground {
            EditorialSection(title: "智能网格候选", trailing: "真实持仓", accent: p.chartViolet) {
                if items.isEmpty {
                    GPStatus(title: "今天没有合格的网格计划",
                             detail: "市场状态、长期分时、成交量、交易规则和现金门槛不满足时，顾问不会强行生成档位。",
                             symbol: "square.grid.2x2")
                }
                ForEach(items) { item in
                    Button { selected = item } label: {
                        GPCard(accent: p.chartViolet) {
                            GPDataRow(title: item.name, value: item.headline,
                                      note: "\(item.code) · \(item.confidence.summary)")
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("智能网格候选").navigationBarTitleDisplayMode(.inline)
        .task { if model.dailyGuidance == nil { await model.refreshGuidance() } }
        .sheet(item: $selected) { item in AIGuidanceDetailSheet(item: item).environmentObject(model) }
    }
}

private struct PortfolioAnalysisScreen: View {
    var body: some View {
        GPPageBackground {
            HoldingsBreakdownPanel()
            AccountReviewPanel()
        }
        .navigationTitle("持仓盈亏与风险").navigationBarTitleDisplayMode(.inline)
    }
}

/// 持仓新闻入口：显示手机直连优先的真实新闻标题；同一批标题也会进入 AI 今日指导。
private struct HoldingsNewsScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var refreshing = false

    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 8) {
                Text("与你的真实持仓相关的新闻")
                    .font(.headline).foregroundStyle(p.ink)
                Text("手机会自动获取相关新闻标题并交给 AI 今日指导分析，你不必逐条阅读。这里仅用于查看来源；标题来自搜索聚合，AI会把它当线索而非已核实事实。")
                    .font(.caption).foregroundStyle(p.muted)
                Button {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        for position in model.book.positions { await model.refreshNASNews(position.code) }
                        refreshing = false
                    }
                } label: {
                    Label(refreshing ? "正在更新持仓新闻…" : "刷新全部持仓新闻", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(refreshing || model.book.positions.isEmpty)
                if model.book.positions.isEmpty {
                    GPStatus(title: "还没有真实持仓", detail: "录入或同步真实持仓后，新闻会按证券逐只关联。", symbol: "newspaper")
                }
                ForEach(model.book.positions) { position in
                    let items = model.nasNews[position.code] ?? []
                    EditorialSection(title: position.name, trailing: position.code) {
                        let status = model.newsStatus[position.code] ?? "尚未刷新"
                        Text(status).font(.caption2).foregroundStyle(p.muted)
                        let impact = NextNewsImpactEngine.evaluate(
                            code: position.code, name: position.name,
                            titles: items.map { NextNewsInput(title: $0.title, source: $0.source, publishedAt: $0.publishedAt, url: $0.url) },
                            hasTPlan: false, hasGridPlan: false, now: Date())
                        if impact.action.blocksPlan {
                            Label("检测到可能影响原计划的事件：\(impact.action.rawValue)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(p.risk)
                        }
                        if items.isEmpty {
                            Text("暂无已缓存新闻。刷新失败时不会用旧版示例数据代替。")
                                .font(.caption).foregroundStyle(p.muted)
                        } else {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let rawURL = item.url, let url = URL(string: rawURL) {
                                        Link(destination: url) {
                                            Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    } else {
                                        Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                                    }
                                    Text([item.source, item.publishedAt].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(p.muted)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                }
                if !model.book.positions.isEmpty {
                    NavigationLink(value: GPRoute.decision(nil)) {
                        IntentRow(icon: "sparkles", title: "查看新闻对今日指导的影响", detail: "进入统一 AI 指导，查看持仓机会与风险")
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("新闻与事件")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for position in model.book.positions where model.nasNews[position.code] == nil {
                await model.refreshNASNews(position.code)
            }
        }
    }
}

private struct MarketScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var entry = ""
    @State private var selectedFilter = "全部"
    @State private var tradeRequest: GPTradeRequest?
    private var visibleCodes: [String] {
        switch selectedFilter {
        case "持仓": return model.book.positions.map(\.code)
        case "自选": return model.watch
        default: return model.watch + model.book.positions.map(\.code).filter { !model.watch.contains($0) }
        }
    }
    private var scoredCount: Int { visibleCodes.filter { model.chartData["\($0):day"] != nil }.count }
    var body: some View {
        List {
            Section {
                GlobalIndexStrip()
            }
            .listRowBackground(p.canvas)
            .listRowSeparator(.hidden)
            Section {
                NavigationLink(value: GPRoute.worthOverview) {
                    HStack(spacing: 9) {
                        Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 15)).foregroundStyle(p.terracotta)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("值不值得买 · 总览").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                            Text("本机规则打分 · \(visibleCodes.count) 只标的，已归档日K \(scoredCount) 只").font(.caption2).foregroundStyle(p.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.muted)
                    }.padding(.vertical, 4)
                }
            }
            .listRowBackground(p.paper)
            .listRowSeparator(.hidden)
            Section {
                HStack(alignment: .top) { Text("用熟悉的证券代码开始，详情里再展开行情、图表与研究。").font(.subheadline).foregroundStyle(p.muted); Spacer(); Button { Task { await model.refreshQuotes(codes: visibleCodes) } } label: { Label("刷新", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }.disabled(visibleCodes.isEmpty) }
                    .listRowBackground(p.canvas)
                HStack(spacing: 8) { TextField("添加 6 位证券代码", text: $entry).keyboardType(.numberPad).textFieldStyle(.roundedBorder).submitLabel(.done).onSubmit(add); Button(selectedFilter == "持仓" ? "录入" : "添加", action: add).buttonStyle(.borderedProminent).tint(p.forest) }
                    .listRowBackground(p.canvas)
                Picker("证券筛选", selection: $selectedFilter) { ForEach(["全部", "自选", "持仓"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    .listRowBackground(p.canvas)
                HStack { Text("证券").frame(maxWidth: .infinity, alignment: .leading); Text("最新").frame(width: 78, alignment: .trailing); Text("涨跌").frame(width: 58, alignment: .trailing) }.font(.caption2.weight(.medium)).foregroundStyle(p.muted).listRowBackground(p.canvas)
            }
            if visibleCodes.isEmpty {
                GPStatus(title: "这个列表还没有证券", detail: selectedFilter == "持仓" ? "从自选点进 ETF，选择记录买入或补录已有持仓；也可在上方输入代码。" : "搜索并添加一只场内 ETF，点入可查看详情。", symbol: "magnifyingglass").listRowBackground(p.canvas).listRowSeparator(.hidden)
            }
            ForEach(visibleCodes, id: \.self) { code in
                NavigationLink(value: GPRoute.instrument(code)) {
                    InstrumentRow(code: code, name: model.book.positions.first(where: { $0.code == code })?.name ?? model.quotes[code]?.quote.name ?? knownName(code), units: model.book.positions.first(where: { $0.code == code })?.units, quote: model.quotes[code])
                }.accessibilityIdentifier("instrument.row.\(code)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if model.watch.contains(code) { Button("移除", systemImage: "star.slash", role: .destructive) { model.removeWatch(code) } }
                        Button("买入", systemImage: "plus.circle") { tradeRequest = GPTradeRequest(code: code, side: "buy") }.tint(p.forest)
                        if model.book.positions.contains(where: { $0.code == code && $0.units > 0 }) { Button("卖出", systemImage: "minus.circle") { tradeRequest = GPTradeRequest(code: code, side: "sell") }.tint(p.terracotta) }
                        Button("分析", systemImage: "sparkles") { model.openInstrumentIntent(code) }.tint(p.forest)
                    }
                    .listRowBackground(p.paper)
                    .contextMenu {
                        Button("记录买入", systemImage: "plus.circle") { tradeRequest = GPTradeRequest(code: code, side: "buy") }
                        if model.book.positions.contains(where: { $0.code == code && $0.units > 0 }) {
                            Button("记录卖出", systemImage: "minus.circle") { tradeRequest = GPTradeRequest(code: code, side: "sell") }
                        }
                        Button("分析买入机会", systemImage: "sparkles") { model.openInstrumentIntent(code) }
                        if model.watch.contains(code) {
                            Button("移出自选", systemImage: "star.slash", role: .destructive) { model.removeWatch(code) }
                        }
                    }
            }
            Section("行情连接状态") {
                VStack(alignment: .leading, spacing: 6) { Text(model.status).font(.subheadline.weight(.medium)); Text("来源：Tencent 公共报价接口。失败时保留本地缓存；ETF 属性、交易规则、五档盘口及 IOPV 不从报价接口推断。").font(.caption).foregroundStyle(p.muted); Button("重试") { Task { await model.refreshQuotes(codes: visibleCodes) } }.font(.caption.weight(.semibold)).tint(p.forest) }
                    .listRowBackground(p.canvas)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(p.canvas).scrollDismissesKeyboard(.interactively)
        .navigationTitle("行情").navigationBarTitleDisplayMode(.large)
        .sheet(item: $tradeRequest) { TradeEntrySheet(request: $0) }
        .onAppear { selectedFilter = model.preferences.navigation.listFilters["market"] ?? "全部" }
        .onChange(of: selectedFilter) { _, value in model.preferences.navigation.listFilters["market"] = value; model.preferences = model.preferences }
    }
    private func add() {
        let code = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { model.errorMessage = "请输入有效的 6 位场内证券代码"; return }
        if selectedFilter == "持仓" || model.watch.contains(code) {
            tradeRequest = GPTradeRequest(code: code, side: "buy")
            entry = ""
            return
        }
        do {
            try model.addWatch(code); entry = ""
            Task { await model.refreshQuotes(codes: [code]) }
        } catch { model.errorMessage = error.localizedDescription }
    }
}

struct InstrumentRow: View {
    @Environment(\.gp) private var p
    @EnvironmentObject private var model: NextAppModel
    let code: String; let name: String; var units: Int?; let quote: NextCachedQuote?
    private var validQuote: NextQuote? { guard let quote, quote.usableForDisplay(at: Date()) else { return nil }; return quote.quote }
    private var isETF: Bool { NextDividendRules.isOnExchangeETF(code) }
    /// 近 30 个日 K 收盘，画迷你走势；不足 2 点不画。
    private var sparkValues: [Double] {
        let samples = model.chartData["\(code):day"]?.orderedSamples.suffix(30) ?? []
        return samples.map { NextNum.double($0.close) }
    }
    private var marketValueLine: String {
        guard let units, let price = validQuote?.price else { return "\(code)\(units.map { " · \($0) 份" } ?? "")" }
        return "\(code) · 市值 ¥\(NextMoney.text(price * Decimal(units)))"
    }
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(name).gpFont(size: 14, relativeTo: .body, weight: .semibold).foregroundStyle(p.ink).lineLimit(1)
                    GPPillBadge(text: isETF ? "ETF" : "股票", color: isETF ? p.jade : p.chartBlue)
                }
                Text(marketValueLine).gpFont(size: 10, relativeTo: .caption, design: .monospaced).foregroundStyle(p.muted).lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 4) { Text(validQuote.map { "¥\(NextMoney.text($0.price, digits: 3))" } ?? "—").gpFont(size: 13, relativeTo: .subheadline, weight: .semibold, design: .rounded).monospacedDigit().foregroundStyle(p.ink); if let validQuote, let change = validQuote.changePercent { Text("\(change >= 0 ? "+" : "")\(NextMoney.text(change, digits: 3))%").gpFont(size: 10, relativeTo: .caption, design: .monospaced).foregroundStyle(p.changeTone(NextNum.double(change))) }; Text(quote?.stamp.label(now: Date()) ?? "暂无行情").gpFont(size: 8, relativeTo: .caption2).foregroundStyle(quote?.stamp.quality == .stale ? p.terracotta : p.muted).lineLimit(1) }
            if sparkValues.count >= 2 {
                GPSparkline(values: sparkValues,
                            color: validQuote?.changePercent.map { p.changeTone(NextNum.double($0)) } ?? p.forest,
                            lineWidth: 1.4, height: 26).frame(width: 44)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.leading, 2)
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}

private struct InstrumentDetailScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var interval: NextChartInterval = .intraday
    @State private var selectedTime: Date?
    @State private var tradeRequest: GPTradeRequest?
    @State private var addIncome = false
    private var dividendEvents: [NextETFDividendEvent] { NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? [])).filter { $0.code == code } }
    private var recentDividendPerShare: Decimal {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return NextDividendAnalytics.recentVerifiedPerShare(code: code, events: dividendEvents, today: formatter.string(from: Date()))
    }
    private var dividendProjection: (amount: Decimal, source: NextDividendAnalytics.ProjectionSource)? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        return NextDividendAnalytics.projectedAnnualPerShare(code: code, events: dividendEvents, today: formatter.string(from: Date()))
    }
    private var position: NextPosition? { model.book.positions.first { $0.code == code } }
    private var quote: NextQuote? { model.quotes[code]?.quote }
    private var name: String { position?.name ?? quote?.name ?? knownName(code) }
    private var cost: Decimal? { position?.costPerUnit }
    /// 分时样本（今日）。开/高/低/量只取真实可取到的值，取不到就显示 —，不推算。
    private var intradaySamples: [NextChartSample] { model.chartData[code]?.orderedSamples ?? [] }
    private var intradayOpen: Decimal? { intradaySamples.first.flatMap { $0.open ?? $0.close } }
    private var intradayHigh: Decimal? { intradaySamples.compactMap(\.high).max() }
    private var intradayLow: Decimal? { intradaySamples.compactMap(\.low).min() }
    /// 分时成交量为日内累计口径，直接取最后一个样本，不做加总。
    private var intradayVolume: Decimal? { intradaySamples.last?.volume }
    private var premiumText: String? {
        guard let quote, let iopv = quote.iopv, iopv > 0 else { return nil }
        let premium = (quote.price / iopv - 1) * 100
        return "\(premium >= 0 ? "+" : "")\(NextMoney.text(premium, digits: 3))%"
    }
    private func volumeText(_ value: Decimal) -> String {
        let amount = NextNum.double(value)
        if amount >= 100_000_000 { return String(format: "%.3f亿", amount / 100_000_000) }
        if amount >= 10_000 { return String(format: "%.3f万", amount / 10_000) }
        return NextMoney.text(value, digits: 0)
    }
    @ViewBuilder private var crossMarketEvidenceSection: some View {
        if let evidence = model.nasResearch[code]?.crossMarket {
            EditorialSection(title: "跨市场研究", trailing: evidence.eligibleForTradingSignal == true ? "已验证 · 风险参考" : "研究参考", accent: p.chartViolet) {
                GPCard(accent: p.chartViolet) {
                    GPDataRow(title: "历史结论", value: crossMarketStateTitle(evidence.state),
                              note: evidence.reason ?? "仅基于 NAS 已归档的独立交易日样本")
                    if let market = evidence.bestMarket {
                        GPDataRow(title: "历史候选来源", value: market,
                                  note: "\(evidence.sampleCount ?? 0) 个独立交易日 · \(evidence.bestLagMinutes.map { "领先约 \($0) 分钟" } ?? "未给出稳定窗口")")
                    }
                    if let age = evidence.ageSeconds {
                        GPDataRow(title: "跨市场数据年龄", value: age <= 600 ? "\(Int(age)) 秒" : "已过期",
                                  note: "来源 \(evidence.source ?? "未知") · \(evidence.asOf ?? "未知时间")",
                                  valueColor: age <= 600 ? p.forest : p.terracotta)
                    }
                    let currentObservations = (evidence.liveDivergences ?? []).filter { $0.state == "observed_divergence" && $0.isFresh(at: Date()) }
                    if !currentObservations.isEmpty {
                        ForEach(currentObservations.prefix(2), id: \.market) { observation in
                            GPDataRow(title: "\(observation.market) 同窗观察",
                                      value: "\(observation.leaderReturnPercent.map { String(format: "%+.2f%%", $0) } ?? "—") / \(observation.assetReturnPercent.map { String(format: "%+.2f%%", $0) } ?? "—")",
                                      note: "15分钟价格观察 · 资格 \(observation.eligibleForTradingSignal == true ? "已验证风险参考" : "仅观察")")
                        }
                    } else {
                        GPDataRow(title: "实时跨市场观察", value: "暂无新鲜背离",
                                  note: "数据不足或已过期时不沿用旧观察")
                    }
                    if let fx = evidence.currencyContext {
                        let fxMove = fx.fxReturnPercent.map { String(format: "%+.4f%%", $0) } ?? "—"
                        GPDataRow(title: "USD/CNY 上下文", value: fx.state == "observed_context" ? fxMove : fx.state,
                                  note: "\(fx.source ?? "来源未验证") · \(fx.asOf ?? fx.reason ?? "暂无同窗样本")；仅用于风险复核")
                    }
                    Text("历史领先关系不代表因果。没有通过预注册未来复现时，跨市场观察不会改变策略；它也不会生成挂单价格或份额。")
                        .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func crossMarketStateTitle(_ state: String) -> String {
        switch state {
        case "stable_candidate": return "历史候选 · 待未来复现"
        case "no_stable_relationship": return "没有稳定领先关系"
        case "insufficient_real_archive", "insufficient": return "历史样本不足"
        case "stale": return "来源数据已过期"
        default: return state
        }
    }
    @ViewBuilder private func statCell(title: String, value: String, valueColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(p.muted)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(valueColor ?? p.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                // 参考设计稿「行情详情」：白卡 + 大字价格 + 六宫格。涨跌走红/绿语义色。
                let priceTone: Color = quote.map { p.changeTone(NextNum.double($0.changePercent ?? 0)) } ?? p.ink
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                            Text("\(code) · \(quote.map { $0.source } ?? "数据源待接入")").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        Spacer()
                        Button { Task { await model.refreshInstrument(code) } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(p.forest).frame(width: 40, height: 40).contentShape(Rectangle()) }.accessibilityLabel("刷新行情")
                        Button { if model.watch.contains(code) { model.removeWatch(code) } else { try? model.addWatch(code) } } label: { Image(systemName: model.watch.contains(code) ? "star.fill" : "star").foregroundStyle(p.terracotta).frame(width: 40, height: 40).contentShape(Rectangle()) }.accessibilityLabel(model.watch.contains(code) ? "取消关注" : "关注")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(quote.map { "¥\(NextMoney.text($0.price, digits: 3))" } ?? "暂无有效报价")
                            .font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(priceTone)
                        if let quote, let change = quote.changePercent {
                            let delta = quote.price - quote.previousClose
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(delta >= 0 ? "+" : "")\(NextMoney.text(delta, digits: 3))").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(priceTone)
                                Text("\(change >= 0 ? "+" : "")\(NextMoney.text(change, digits: 3))%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(priceTone.opacity(0.12), in: Capsule())
                                    .foregroundStyle(priceTone)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(quote?.time.formatted(date: .omitted, time: .shortened) ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    if let stamp = model.quotes[code]?.stamp { Text(stamp.label(now: Date())).font(.system(size: 9)).foregroundStyle(stamp.quality == .stale ? p.terracotta : p.muted) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        statCell(title: "昨收", value: quote.map { "¥\(NextMoney.text($0.previousClose, digits: 3))" } ?? "—")
                        statCell(title: "今开", value: intradayOpen.map { "¥\(NextMoney.text($0, digits: 3))" } ?? "—")
                        statCell(title: "最高", value: intradayHigh.map { "¥\(NextMoney.text($0, digits: 3))" } ?? "—", valueColor: p.gpUp)
                        statCell(title: "最低", value: intradayLow.map { "¥\(NextMoney.text($0, digits: 3))" } ?? "—", valueColor: p.gpDown)
                        statCell(title: "成交量", value: intradayVolume.map { volumeText($0) } ?? "—")
                        statCell(title: "溢折率", value: premiumText ?? "—", valueColor: premiumText == nil ? nil : p.terracotta)
                    }
                }
                .padding(14)
                .background(p.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 0.8))
                .padding(.top, 5).padding(.bottom, 12)
                DataPanel(title: "行情图表", accent: p.chartBlue, caption: model.chartData[code].map { "\($0.priceSource) · \($0.observedAt.formatted(date: .omitted, time: .shortened))" } ?? "暂无本机历史") {
                    UnifiedChartView(dataset: interval == .intraday ? model.chartData[code] : model.chartData["\(code):day"], interval: $interval, costPerUnit: cost, selectedTime: $selectedTime, securityCode: code)
                    if interval != .intraday, let dailyError = model.dailyErrors[code] {
                        GPStatus(title: "日 K 暂不可用", detail: dailyError, symbol: "externaldrive.badge.exclamationmark", actionTitle: "重新获取") { Task { await model.refreshDaily(code, required: true) } }
                    }
                    HStack { Button { Task { await model.refreshInstrument(code) } } label: { Label("刷新行情与分时", systemImage: "arrow.clockwise").font(.caption.weight(.semibold)) }; Spacer(); NavigationLink(value: GPRoute.chart(code)) { Label("全屏分析", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.semibold)) }.accessibilityIdentifier("chart.fullscreen") }.tint(p.forest)
                }
                WorthBuyPanel(code: code)
                EditorialSection(title: "交易盘口", trailing: model.rules[code]?.isVerified == true ? "规则已验证" : "规则待验证", accent: p.chartViolet) {
                    if let snapshot = model.orderBooks[code] {
                        if model.rules[code]?.isVerified != true {
                            GPStatus(title: "交易规则尚未验证", detail: "不会假设 ETF 是 T+0，也不会固定推断手数或费用。", symbol: "checkmark.shield")
                        } else {
                            OrderBookView(snapshot: snapshot)
                        }
                    } else {
                        GPStatus(title: "盘口数据尚未连接", detail: "五档报价未到达前不展示模拟档位或推测成交。", symbol: "rectangle.split.3x1")
                    }
                }
                EditorialSection(title: "账户与规则", accent: p.chartGold) {
                    if let basis = model.book.costBasis(for: code) {
                        GPDataRow(title: "持有数量", value: "\(basis.units) 份")
                        GPDataRow(title: "买入均价（加权平均）", value: "¥\(NextMoney.text(basis.averageCost, digits: 3))",
                                  note: "只由买入决定、含买入手续费；卖出不改变这个数")
                        if let diluted = basis.dilutedCost {
                            GPDataRow(title: "摊薄成本（券商口径）", value: "¥\(NextMoney.text(diluted, digits: 3))" + (basis.isNegativeDiluted ? " · 负成本" : ""),
                                      note: basis.dividendCredit > 0
                                        ? "买入总额 − 卖出所得 − 已到账分红 ¥\(NextMoney.text(basis.dividendCredit))，再摊到当前份额；分红到账后成本价会下降，与券商「成本价」同口径"
                                        : "买入总额减去卖出所得后摊到当前份额；与同花顺的「成本价」同一算法",
                                      valueColor: basis.isNegativeDiluted ? p.terracotta : nil)
                        } else {
                            GPDataRow(title: "摊薄成本（券商口径）", value: "无法计算",
                                      note: "这只持仓是补录的、没有买入流水，无法还原摊薄成本")
                        }
                        GPDataRow(title: "来源", value: "本机真实账本", note: "改动写入审计记录，可在资产流水撤销")
                    }
                    else { Text("尚未录入真实账本；当前没有真实持仓；该证券详情只展示公开行情与研究资料。").font(.caption).foregroundStyle(p.muted) }
                    if let rules = model.rules[code] { GPDataRow(title: "结算规则", value: rules.settlement == .unknown ? "未知" : rules.settlement.rawValue.uppercased(), note: rules.source); if let lot = rules.lotSize { GPDataRow(title: "交易单位", value: "\(lot) 份") } }
                    else { GPDataRow(title: "ETF 交易规则", value: "未接入来源") }
                }
                if position != nil { crossMarketEvidenceSection }
                EditorialSection(title: "分红与收息参考", trailing: "历史数据", accent: p.chartGold) {
                    NavigationLink(value: GPRoute.dividends(code)) { IntentRow(icon: "calendar", title: "查看完整派息历史", detail: "登记日、除息日、发放日与数据来源") }.buttonStyle(.plain)
                    // 先讲清楚"这只到底分不分红"。很多宽基/行业 ETF 成立以来从不分红，
                    // 以前这里会静默显示 0，看起来像"没数据"，还容易被价格差推算污染。
                    let hasConfirmed = NextDividendAnalytics.hasConfirmedHistory(code: code, events: dividendEvents)
                    let knownNone = NextDividendAnalytics.knownNonDividendCodes.contains(code)
                    GPDataRow(title: "分红属性",
                              value: hasConfirmed ? "有派息记录" : (knownNone ? "已知不分红" : "暂无可核实派息"),
                              note: hasConfirmed
                                ? "以官方派息记录为准；推算值只做参考，不参与股息率评分"
                                : "没有官方记录就不推算分红，股息率按 0 处理，也不加分")
                    let heldUnits = position?.units ?? 0
                    GPDataRow(title: "近365日已记录每份派息",
                              value: recentDividendPerShare > 0 ? "¥\(NextMoney.text(recentDividendPerShare, digits: 3))" : "—",
                              note: recentDividendPerShare > 0
                                ? (quote.map { $0.price > 0 ? "按当前价历史收益率 \(NextMoney.text(recentDividendPerShare / $0.price * 100, digits: 3))% · 不代表未来承诺" : "不计算收益率" } ?? "行情价格不可用")
                                : "近 12 个月没有已核实的派息")
                    if heldUnits > 0 { GPDataRow(title: "按当前账面份额折算", value: "¥\(NextMoney.text(recentDividendPerShare * Decimal(heldUnits)))", note: "不是历史实际到账金额；请以券商流水为准") }
                    if let dividendProjection {
                        let source = switch dividendProjection.source {
                        case .recentConfirmed: "按近365日已实施派息外推；金额可能变化"
                        case .historicalAverage: "按近三年有派息年份平均；金额不保证"
                        case .inferredEstimate: "按复权价格变化推算；不是已核实现金分红"
                        }
                        GPDataRow(title: "未来12个月历史节奏试算", value: "¥\(NextMoney.text(dividendProjection.amount, digits: 3))/份", note: source)
                    }
                    ForEach(dividendEvents.sorted { $0.date > $1.date }.prefix(4)) { event in
                        let dates = [event.recordDate.map { "登记 \($0)" }, event.payDate.map { "发放 \($0)" }].compactMap { $0 }.joined(separator: " · ")
                        let confirmedNote = dates.isEmpty ? "已实施派息事件" : "已实施派息 · \(dates)"
                        GPDataRow(title: "除息日 \(event.date)", value: "每份 ¥\(NextMoney.text(event.amountPerShare, digits: 3))", note: event.isEstimated == true ? "复权价格变化估算 · 尚未核实现金派息" : confirmedNote)
                    }
                    if dividendEvents.isEmpty { GPStatus(title: "暂无可核实的派息历史", detail: "NAS 连接后会查询历史事件；网络失败时不会清除本机缓存，也不会把估算数据记成到账。", symbol: "calendar.badge.clock") }
                    Button { addIncome = true } label: { Label("记录分红 / 实际到账", systemImage: "yensign.circle").font(.caption.weight(.semibold)) }.tint(p.forest)
                }
                EditorialSection(title: "下一步", accent: p.terracotta) {
                    HStack { Button("记录买入") { tradeRequest = GPTradeRequest(code: code, side: "buy") }; if (position?.units ?? 0) > 0 { Button("记录卖出") { tradeRequest = GPTradeRequest(code: code, side: "sell") } } }.buttonStyle(.bordered).tint(p.forest)
                    NavigationLink(value: GPRoute.decision(code)) { IntentRow(icon: "sparkles", title: "分析买入机会", detail: "组织行情、持仓、资金、限价计划与风险") }.accessibilityIdentifier("instrument.analyze-buy")
                    NavigationLink(value: GPRoute.alerts) { IntentRow(icon: "bell.badge", title: "设置价格提醒", detail: "自动带入当前证券代码；只用新鲜行情触发") }
                }
                if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(p.muted).padding(.vertical, 8) }
            }
        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
            .sheet(item: $tradeRequest) { TradeEntrySheet(request: $0) }
            .sheet(isPresented: $addIncome) { IncomeRecordSheet(initialCode: code) { event in do { try model.addIncomeEvent(event) } catch { model.errorMessage = error.localizedDescription } } }
            .onAppear { model.preferences.navigation.selectedSecurity = code; model.preferences = model.preferences; Task { await model.registerNASArchive(code); await model.refreshDaily(code); await model.refreshDividendHistory(code) } }
    }
}

private struct OrderBookView: View {
    @Environment(\.gp) private var p
    let snapshot: NextOrderBookSnapshot
    private var isFresh: Bool { snapshot.observedAt <= Date() && Date().timeIntervalSince(snapshot.observedAt) <= 5 }
    private var maxAskUnits: Int { max(snapshot.asks.map(\.units).max() ?? 1, 1) }
    private var maxBidUnits: Int { max(snapshot.bids.map(\.units).max() ?? 1, 1) }
    var body: some View {
        VStack(spacing: 8) {
            // 参考设计稿「五档盘口」：左卖出（绿）/ 右买入（红），每档 价格 + 比例条 + 数量。
            HStack(spacing: 12) {
                VStack(spacing: 7) {
                    Text("卖出").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.gpDown).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(snapshot.asks.reversed().enumerated()), id: \.offset) { index, level in
                        bookRow(label: "卖\(5 - index)", level: level, color: p.gpDown, maxUnits: maxAskUnits)
                    }
                }
                VStack(spacing: 7) {
                    Text("买入").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.gpUp).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(snapshot.bids.enumerated()), id: \.offset) { index, level in
                        bookRow(label: "买\(index + 1)", level: level, color: p.gpUp, maxUnits: maxBidUnits)
                    }
                }
            }
            Text("\(snapshot.source) · \(snapshot.observedAt.formatted(date: .omitted, time: .standard)) · \(isFresh ? "数据新鲜" : "数据已过期")").font(.system(size: 9, design: .monospaced)).foregroundStyle(isFresh ? p.muted : p.terracotta).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine).accessibilityLabel("\(snapshot.code) 五档买卖盘口，\(isFresh ? "数据新鲜" : "数据已过期")")
    }
    private func bookRow(label: String, level: NextBookLevel, color: Color, maxUnits: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundStyle(p.muted).frame(width: 24, alignment: .leading)
            Text(NextMoney.text(level.price, digits: 3)).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.10)).frame(height: 5)
                    Capsule().fill(color.opacity(0.45)).frame(width: geo.size.width * CGFloat(level.units) / CGFloat(maxUnits), height: 5)
                }
            }.frame(height: 5)
            Text("\(level.units)").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).frame(width: 40, alignment: .trailing)
        }
    }
}

private struct FullscreenChartScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var interval: NextChartInterval = .intraday
    @State private var crosshair: Date?
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(knownName(code)).font(.headline)
                        Text("\(code) · \(model.quotes[code]?.stamp.label(now: Date()) ?? "暂无行情")").font(.caption).foregroundStyle(p.muted)
                    }
                    Spacer()
                    NavigationLink(value: GPRoute.decision(code)) { Label("分析", systemImage: "sparkles").font(.caption.weight(.semibold)) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chart.fullscreen.header")
                DataPanel(title: "价格与 IOPV", accent: p.chartViolet, caption: geo.size.width > geo.size.height ? "横屏 · 拖动/双指缩放" : "竖屏") {
                    UnifiedChartView(dataset: interval == .intraday ? model.chartData[code] : model.chartData["\(code):day"], interval: $interval, costPerUnit: model.book.positions.first(where: { $0.code == code })?.costPerUnit, selectedTime: $crosshair, securityCode: code, expanded: true)
                    if interval != .intraday, let dailyError = model.dailyErrors[code] {
                        GPStatus(title: "日 K 暂不可用", detail: dailyError, symbol: "externaldrive.badge.exclamationmark", actionTitle: "重新获取") { Task { await model.refreshDaily(code, required: true) } }
                    }
                    if let dataset = (interval == .intraday ? model.chartData[code] : model.chartData["\(code):day"]) { Text("图表来源：\(dataset.priceSource) · 观测 \(dataset.observedAt.formatted(date: .numeric, time: .shortened)) · IOPV 历史\(dataset.iopvSource == nil ? "不可用" : "可用")").font(.caption2).foregroundStyle(p.muted) }
                }
                DataPanel(title: "十字光标数据") { if let crosshair { GPDataRow(title: "时间", value: crosshair.formatted(date: .numeric, time: .shortened)) } else { Text("拖动图表定位历史时点；返回详情后周期和光标状态继续保留。").font(.caption).foregroundStyle(p.muted) } }
                Spacer(minLength: 0)
            }.padding(16).background(p.canvas).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.navigationTitle("全屏行情分析").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
            .onAppear { Task { await model.refreshDaily(code) } }
    }
}

private struct DecisionScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String?
    @State private var years: String = "10"
    @State private var budget: String = "1000"
    @State private var limit: String = "40"
    @State private var targetWeightsText: [String: String] = [:]
    @State private var analyzed = false
    @State private var result: NextDecision?
    @State private var mobileAIKeyAvailable = DeepSeekMobile.loadKey() != nil

    @State private var patientLimitPrice = ""
    @State private var patientLimitUnits = "100"
    @State private var patientLimitExpiry = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date().addingTimeInterval(30 * 86400)
    @State private var inspectResults: [InspectHolding] = []
    @State private var inspectSummary: String?
    @State private var inspecting = false
    private var targetCodes: [String] {
        Array(Set(model.preferences.watch + model.book.positions.filter { $0.units > 0 }.map(\.code)
            + Array(model.goal.targetWeights.keys))).sorted()
    }
    private var hasRecordedMobileAI: Bool {
        guard let code, let result else { return false }
        return result.evidence.contains { $0.id == "deepseek-mobile-\(code)" }
    }
    private func researchDateStatus(_ report: NextNASResearch, code: String) -> String? {
        guard let researchDateString = report.factors?.asOf else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        guard let latestBar = model.chartData["\(code):day"]?.samples.last,
              let latestDate = formatter.date(from: formatter.string(from: latestBar.timestamp)),
              let researchDate = formatter.date(from: researchDateString), latestDate > researchDate else { return nil }
        return "NAS统计研究截至 \(researchDateString)；本机已有更新日 K 至 \(formatter.string(from: latestBar.timestamp))"
    }
    /// 账户体检的逐持仓结论（本机规则扫描，非 AI 预测）。
    private struct InspectHolding: Identifiable, Equatable {
        var id: String { code }
        let code: String
        let name: String
        let weight: Double
        let pnlPercent: Double
        let yieldPercent: Double?
        let suggestion: String
    }
    /// 账户体检：按报告方法论，先看账户（集中度、现金覆盖），再看单只资产，最后看执行。
    private func runInspection() {
        inspecting = true
        defer { inspecting = false }
        let targetYield = Decimal(string: UserDefaults.standard.string(forKey: "guanpan.targetYield") ?? "4") ?? 4
        let positions = model.book.positions
        let totalMV = positions.reduce(Decimal.zero) { acc, pos in
            guard let price = model.quotes[pos.code]?.quote.price else { return acc }
            return acc + price * Decimal(pos.units)
        }
        var results: [InspectHolding] = []
        for pos in positions {
            let price = model.quotes[pos.code]?.quote.price
            let mv = price.map { $0 * Decimal(pos.units) } ?? 0
            let weight = totalMV > 0 ? NSDecimalNumber(decimal: mv).doubleValue / NSDecimalNumber(decimal: totalMV).doubleValue : 0
            let cost = pos.bookCost
            let pnlPct = cost != 0 ? NSDecimalNumber(decimal: (mv - cost) / cost).doubleValue * 100 : 0
            let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[pos.code] ?? []))
            let per = NextDividendAnalytics.recentVerifiedPerShare(code: pos.code, events: events, today: dividendTodayString())
            let yld = price.map { $0 > 0 ? NSDecimalNumber(decimal: per / $0 * 100).doubleValue : 0 } ?? 0
            let suggestion: String
            if weight > 0.4 { suggestion = "仓位偏重 · 暂停加仓" }
            else if yld >= NSDecimalNumber(decimal: targetYield).doubleValue && yld > 0 { suggestion = "股息达标 · 可关注" }
            else if pnlPct < -10 { suggestion = "深跌 · 观察不补仓" }
            else { suggestion = "持有 · 观察" }
            results.append(InspectHolding(code: pos.code, name: pos.name, weight: weight, pnlPercent: pnlPct, yieldPercent: yld > 0 ? yld : nil, suggestion: suggestion))
        }
        results.sort { $0.weight > $1.weight }
        inspectResults = results
        let over = results.filter { $0.weight > 0.4 }.count
        inspectSummary = over > 0
            ? "有 \(over) 只持仓占比超过 40%，注意组合集中度（账户级风险优先于单只机会）。本机扫描仅供参考，不构成交易指令。"
            : "持仓集中度在正常范围。本机扫描按「先看账户、再看资产、最后看执行」的思路给出，仅供参考，不构成交易指令。"
    }
    /// 选中标的时的大字价格卡（参考设计稿英雄卡）：现价、涨跌、口径一屏可见。
    /// 没有缓存报价就明说，不猜价格——AI 结论也只能基于真实缓存。
    @ViewBuilder private func decisionHeroCard(code: String) -> some View {
        if let cached = model.quotes[code] {
            let quote = cached.quote
            let change = quote.changePercent.map { NextNum.double($0) }
            let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
            let per = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: dividendTodayString())
            let yld = (per > 0 && quote.price > 0) ? NextNum.double(per / quote.price * 100) : nil
            DataPanel(title: knownName(code), accent: p.forest, caption: code) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("¥\(NextMoney.text(quote.price, digits: 3))").font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.72)
                    if let change {
                        Text("\(change >= 0 ? "+" : "")\(NextNum.signed(change))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(p.changeTone(change).opacity(0.14), in: Capsule())
                            .foregroundStyle(p.changeTone(change))
                    }
                    Spacer(minLength: 0)
                    if let iopv = quote.iopv, iopv > 0 {
                        let premium = NextNum.double((quote.price / iopv - 1) * 100)
                        GPPillBadge(text: "IOPV \(premium >= 0 ? "+" : "")\(String(format: "%.2f", premium))%", color: p.chartBlue)
                    }
                }
                HStack(spacing: 10) {
                    GPValue(label: "昨收", value: "¥\(NextMoney.text(quote.previousClose, digits: 3))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GPValue(label: "近12月已核实股息率", value: yld.map { "\(NextMoney.text(Decimal($0), digits: 3))%" } ?? "—", footnote: yld == nil ? "缺已核实派息" : nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GPValue(label: "行情", value: quote.source, footnote: cached.stamp.label(now: Date()))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !quote.isFresh(at: Date()) {
                    Text("行情\(cached.stamp.label(now: Date()))，价格与分数按该缓存价计算").font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            GPStatus(title: "暂无缓存报价", detail: "先去行情页刷新一次；AI 分析会把缺口标明，不推测价格。", symbol: "chart.xyaxis.line")
        }
    }
    /// NAS 授权分析结果：一卡一只持仓 + 新闻 + AI 结论，全部只读。
    @ViewBuilder private func inspectRow(_ r: InspectHolding) -> some View {
        let yldText = r.yieldPercent.map { "股息率 \(NextMoney.text(Decimal($0), digits: 3))%" } ?? "股息率 —"
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(r.name) · \(r.code)").font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                Text("占比 \(NextMoney.text(Decimal(r.weight * 100), digits: 0))% · 浮动 \(r.pnlPercent >= 0 ? "+" : "")\(NextMoney.text(Decimal(r.pnlPercent), digits: 3))% · \(yldText)")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            Spacer(minLength: 4)
            GPPillBadge(text: r.suggestion, color: suggestionColor(r.suggestion))
        }.padding(.vertical, 6).overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.6)).frame(height: 0.5) }
    }
    private func suggestionColor(_ s: String) -> Color {
        if s.contains("偏重") { return p.risk }
        if s.contains("达标") { return p.jade }
        if s.contains("深跌") { return p.chartGold }
        return p.muted
    }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles").foregroundStyle(p.forest)
                    Text("私人投资顾问").font(.caption.weight(.semibold)).foregroundStyle(p.forest)
                    Spacer()
                    Text(code.flatMap { model.researchStatus[$0] } ?? (code.flatMap { model.nasResearch[$0]?.factors } == nil ? "本地规则 · NAS研究待同步" : "NAS统计研究已同步"))
                        .font(.caption2).foregroundStyle(p.muted).lineLimit(2).multilineTextAlignment(.trailing)
                }.padding(.top, 7)
                Text(code.map { "围绕 \(knownName($0))，把已知信息整理成下一步" } ?? "你的真实持仓，今天怎么处理").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink).padding(.top, 10)
                // 今日指导放在最前面：打开 AI 页第一眼就是「今天有没有值得操作的机会」。
                AIGuidanceSection().padding(.top, 10)
                // 选中标的时先给一张大字价格卡（参考设计稿英雄卡）：价格、涨跌、口径一屏可见，后面的 AI 结论才有锚点。
                if let code { decisionHeroCard(code: code).padding(.top, 12) }
                // 账户体检：按报告方法论，先看账户（集中度、现金覆盖），再看单只资产，最后看执行。
                EditorialSection(title: "账户体检 · 一键扫描", trailing: inspecting ? "扫描中" : "本机规则", accent: p.forest) {
                    VStack(alignment: .leading, spacing: 10) {
                        GPActionButton(title: inspecting ? "扫描中…" : "一键体检全部持仓", secondary: true, systemImage: "stethoscope") { runInspection() }
                        if let inspectSummary { Text(inspectSummary).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
                        if !inspectResults.isEmpty {
                            let totalMV = inspectResults.reduce(Decimal.zero) { acc, r in
                                guard let price = model.quotes[r.code]?.quote.price else { return acc }
                                let units = model.book.positions.first(where: { $0.code == r.code })?.units ?? 0
                                return acc + price * Decimal(units)
                            }
                            let annual = model.book.positions.reduce(Decimal.zero) { acc, pos in
                                let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[pos.code] ?? []))
                                let per = NextDividendAnalytics.recentVerifiedPerShare(code: pos.code, events: events, today: dividendTodayString())
                                return acc + per * Decimal(pos.units)
                            }
                            let maxW = inspectResults.map(\.weight).max() ?? 0
                            // 四联指标两行两列：手机上每张卡有足够宽度显示完整金额，不会挤成省略号。
                            HStack(spacing: 10) {
                                GPStatTile(label: "持仓市值", value: "¥\(NextMoney.text(totalMV))", emphasis: p.chartBlue)
                                GPStatTile(label: "现金", value: "¥\(NextMoney.text(model.book.cash))", emphasis: p.jade)
                            }
                            HStack(spacing: 10) {
                                GPStatTile(label: "最高占比", value: "\(NextMoney.text(Decimal(maxW * 100), digits: 0))%", emphasis: maxW > 0.4 ? p.risk : p.terracotta)
                                GPStatTile(label: "预计年股息", value: "¥\(NextMoney.text(annual))", emphasis: p.chartGold)
                            }
                            GPCard {
                                Text("逐持仓结论（按仓位占比排序）").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                                ForEach(inspectResults) { r in inspectRow(r) }
                            }
                        } else if inspectSummary != nil {
                            GPInlineEmpty(symbol: "tray", text: "暂无可体检持仓：先在「持仓」页录入份额，再回来一键扫描。")
                        }
                    }
                }
                Text("分析会结合本机账本、有效行情、预算和风险限制。没有来源的数据会明确标为缺口。").font(.subheadline).foregroundStyle(p.muted).padding(.top, 5)
                EditorialSection(title: "你的目标与资金") {
                    GPCard {
                        HStack(spacing: 10) { compactField("期限（年）", text: $years); compactField("每月新增预算", text: $budget); compactField("集中度线 %", text: $limit) }
                        Text("长期目标仓位（ETF目标合计可低于100%；剩余比例自动作为现金储备）")
                            .font(.caption2).foregroundStyle(p.muted)
                        ForEach(targetCodes, id: \.self) { targetCode in
                            HStack(spacing: 8) {
                                Text("\(knownName(targetCode)) · \(targetCode)").font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                TextField("目标 %", text: Binding(get: { targetWeightsText[targetCode] ?? "" }, set: { targetWeightsText[targetCode] = $0 }))
                                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 86).accessibilityLabel("\(targetCode) 目标仓位百分比")
                            }
                        }
                        HStack {
                            Button("保存目标") {
                                do {
                                    var weights: [String: Decimal] = [:]
                                    for (targetCode, text) in targetWeightsText where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { weights[targetCode] = try NextMoney.parse(text) }
                                    try model.saveGoal(years: Int(years) ?? 0, monthlyBudget: try NextMoney.parse(budget), concentration: try NextMoney.parse(limit), targetWeights: weights)
                                } catch { model.errorMessage = error.localizedDescription }
                            }.font(.caption.weight(.semibold)).tint(p.forest)
                            Spacer(minLength: 8)
                            Text("只保存在本机").font(.caption2).foregroundStyle(p.muted)
                        }
                        GPDataRow(title: "资金边界", value: "不动用真实现金", note: "计划和真实账本分开")
                    }
                }
                GPActionButton(title: "分析买入机会", systemImage: "sparkles") {
                    result = model.research(for: code)
                    if let result { model.recordDecision(result) }
                    analyzed = true
                    if let code { Task { await model.refreshNASResearch(code) } }
                }.padding(.vertical, 10)
                if let code {
                    AIInputsCard(code: code)
                    EditorialSection(title: "手机端统一 AI 指导", accent: p.terracotta) {
                        GPCard(accent: p.terracotta) {
                            Text("手机端统一读取全部真实持仓、最新缓存行情、NAS长期研究与相关新闻、离线规则结论及投资画像，生成唯一一份最终建议。具体价格只引用规则引擎通过门槛的候选计划。")
                                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                            GPActionButton(title: model.unifiedAIIsRunning ? "正在综合分析…" : "生成唯一综合指导", secondary: true, systemImage: "sparkles") {
                                guard let key = DeepSeekMobile.loadKey() else {
                                    model.unifiedAIStatus = "请先在「我的 / 手机 AI 接口设置」保存 API Key。"
                                    return
                                }
                                let profile = UserDefaults.standard.string(forKey: "guanpan.deepseek.profile") ?? "flash"
                                Task { await model.runUnifiedMobileAI(key: key, profile: profile) }
                            }.disabled(model.unifiedAIIsRunning || !mobileAIKeyAvailable)
                            if !mobileAIKeyAvailable {
                                Text("请先在设置 → AI 投资研究输入并测试 DeepSeek API key。")
                                    .font(.caption).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                            }
                            if let mobileAIError = model.unifiedAIStatus { GPStatus(title: "手机端 AI 状态", detail: mobileAIError, symbol: "info.circle") }
                        }
                        if let mobileAIResult = model.unifiedAIAdvice {
                            DataPanel(title: "唯一综合指导", accent: p.terracotta, caption: "已记录到历史决策") {
                                AIAdviceFormattedView(text: mobileAIResult)
                            }
                        }
                    }
                }
                if analyzed {
                    if let code, let report = model.nasResearch[code] {
                        EditorialSection(title: "NAS 长期研究证据", trailing: "已归档", accent: p.chartViolet) {
                            DataPanel(title: "NAS长期统计研究", accent: p.chartViolet, caption: "最终AI只在手机运行") {
                                if let factors = report.factors {
                                    GPDataRow(title: "本地因子", value: factors.state, note: "\(factors.source) · \(factors.asOf)")
                                    Text("NAS 只提供归档数据与可追溯统计研究；手机端使用本机 API Key 调用大模型，生成唯一指导。")
                                        .font(.caption).foregroundStyle(p.muted)
                                    if let staleMessage = researchDateStatus(report, code: code) {
                                        Label(staleMessage, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(p.terracotta)
                                    }
                                } else { GPInlineEmpty(symbol: "clock", text: "NAS 尚无研究记录：等待日 K 归档与后台研究任务完成。") }
                            }
                        }
                    }
                    EditorialSection(title: "结论", accent: p.forest) {
                        DataPanel(title: "当前结论", accent: p.forest, caption: result == nil ? "待生成" : (hasRecordedMobileAI ? "含手机端分析" : nil)) {
                            Text(result?.title ?? "先补齐行情和证据").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                            Text(hasRecordedMobileAI ? "已包含 DeepSeek 手机端分析；建议基于所列行情快照，仅供研究，不构成交易指令。" : (result?.origin == "本地规则检查" ? "当前结果由本地规则整理，不是 AI 生成建议。" : "待接入 AI 服务，并为每项结论保存可追溯来源。"))
                                .font(.caption).foregroundStyle(p.muted)
                        }
                    }
                    EditorialSection(title: "依据与风险", accent: p.chartGold) {
                        DataPanel(title: "证据与风险", accent: p.chartGold, caption: "可逐条核对") {
                            if let result, !result.evidence.isEmpty {
                                ForEach(result.evidence) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        GPDataRow(title: item.title, value: item.level)
                                        Text(item.detail).font(.caption).foregroundStyle(p.muted).textSelection(.enabled)
                                    }.padding(.vertical, 4)
                                }
                            } else {
                                GPInlineEmpty(symbol: "doc.text.magnifyingglass", text: "证据暂不完整：补充有效行情或持仓后，才会展开可核实的依据。")
                            }
                        }
                    }
                    EditorialSection(title: "耐心限价计划", accent: p.jade) {
                        GPCard(accent: p.jade) {
                            Text("设置你愿意观察的价格与份额。达到条件时通知你；这不是券商订单，不占用现金，也不会自动买入。")
                                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("观察限价（¥）").font(.caption2).foregroundStyle(p.muted)
                                    TextField("自行输入目标价", text: $patientLimitPrice).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).accessibilityLabel("观察限价")
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("计划份额").font(.caption2).foregroundStyle(p.muted)
                                    TextField("100", text: $patientLimitUnits).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("计划份额")
                                }
                            }
                            DatePicker("提醒有效至", selection: $patientLimitExpiry, in: Date()..., displayedComponents: .date)
                                .font(.caption).tint(p.forest)
                            GPActionButton(title: "保存观察计划", secondary: true, systemImage: "bell.badge") {
                                guard let code else { return }
                                do {
                                    try model.createPatientLimitPlan(code: code, price: NextMoney.parse(patientLimitPrice), units: Int(patientLimitUnits) ?? 0, expiresAt: patientLimitExpiry)
                                    patientLimitPrice = ""
                                } catch { model.errorMessage = error.localizedDescription }
                            }
                            let plans = model.patientLimitPlans.filter { $0.code == code }
                            if plans.isEmpty {
                                Text("尚无此证券的观察计划。目标价由你决定，不会用未经验证的 AI 价格替你填入。")
                                    .font(.caption2).foregroundStyle(p.muted)
                            }
                            ForEach(plans) { plan in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(plan.name) · ¥\(NextMoney.text(plan.limitPrice, digits: 3)) · \(plan.units) 份").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                                        Spacer()
                                        Text(plan.state).font(.caption2.weight(.medium)).foregroundStyle(plan.state == "价格已触发" ? p.forest : p.muted)
                                    }
                                    GPDataRow(title: "有效期", value: plan.expiresAt.formatted(date: .abbreviated, time: .omitted), note: plan.triggeredAt.map { "触发于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "本机保存 · 到价提醒 · 不会下单")
                                    if plan.state == "等待价格提醒" {
                                        HStack {
                                            Button("暂停提醒") { model.pausePatientLimitPlan(plan.id) }.font(.caption.weight(.medium))
                                            Button("撤销计划", role: .destructive) { model.cancelPatientLimitPlan(plan.id) }.font(.caption.weight(.medium))
                                        }
                                    } else if plan.state == "已暂停" {
                                        HStack {
                                            Button("恢复提醒") { model.resumePatientLimitPlan(plan.id) }.font(.caption.weight(.medium))
                                            Button("撤销计划", role: .destructive) { model.cancelPatientLimitPlan(plan.id) }.font(.caption.weight(.medium))
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                    EditorialSection(title: "后续跟踪") { NavigationLink(value: GPRoute.alerts) { IntentRow(icon: "bell", title: "设置价格与风险提醒", detail: "触发时检查数据时间和来源") } }
                    EditorialSection(title: "历史决策成绩") { NavigationLink(value: GPRoute.history) { IntentRow(icon: "clock.arrow.circlepath", title: "查看决策复盘", detail: "保留当时结论和证据快照") } }
                    if let result {
                        ForEach(result.options) { option in
                            Button {
                                do { try model.chooseDecision(result.id, optionID: option.id); self.result?.selectedOption = option.id; self.result?.status = "已记录选择" }
                                catch { model.errorMessage = error.localizedDescription }
                            } label: {
                                DataPanel(title: option.title, caption: result.selectedOption == option.id ? "已选择" : "") {
                                    Text(option.rationale).font(.subheadline).foregroundStyle(p.ink)
                                    Text("需要考虑：\(option.tradeoff)").font(.caption).foregroundStyle(p.muted)
                                    if result.selectedOption == option.id { Label("已保存到决策记录", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(p.forest) }
                                }
                            }.buttonStyle(.plain).accessibilityHint("选择此研究方案并保存到历史记录")
                        }
                    }
                } else {
                    EditorialSection(title: "你可以直接从证券详情发起") { NavigationLink(value: GPRoute.instrument(model.watch.first ?? "159941")) { IntentRow(icon: "chart.xyaxis.line", title: "从 ETF 行情开始", detail: "自动携带证券上下文") } }
                }
            }
        }.onAppear {
            years = String(model.goal.years)
            budget = NSDecimalNumber(decimal: model.goal.monthlyBudget).stringValue
            limit = NSDecimalNumber(decimal: model.goal.concentrationLimit).stringValue
            targetWeightsText = model.goal.targetWeights.mapValues { NSDecimalNumber(decimal: $0).stringValue }
            mobileAIKeyAvailable = DeepSeekMobile.loadKey() != nil
            if let code { Task { await model.refreshNASResearch(code) } }
        }
    }

}

/// 借鉴小万量化的「结构化结论」：把 AI 自由文本按 结论/证据/风险/等待条件/失效条件/后续跟踪 拆成区块，
/// 并抽出「置信度：高/中/低」做成徽标；拆不出区块就原样展示全文（优雅降级，不丢信息）。
private struct AIAnswerView: View {
    @Environment(\.gp) private var p
    let text: String
    /// 模型可能写成同义小节（事实依据 / 推断 / 观察 / 跟踪……），这里统一折叠到六个规范标题。
    /// 服务端 prompt 与手机端解析必须对得上——对不上就会退化成一大段没有结构的文字。
    private static let headerMap: [(match: String, title: String)] = [
        ("结论", "结论"),
        ("证据", "证据"), ("事实依据", "证据"), ("推断", "推断"),
        ("风险", "风险"),
        ("等待条件", "等待条件"), ("等待", "等待条件"), ("观察", "等待条件"),
        ("失效条件", "失效条件"),
        ("后续跟踪", "后续跟踪"), ("跟踪", "后续跟踪")
    ]

    private var confidence: String? {
        guard let r = text.range(of: "置信度") else { return nil }
        let tail = text[r.upperBound...].prefix(8)
        if tail.contains("高") { return "高" }
        if tail.contains("中") { return "中" }
        if tail.contains("低") { return "低" }
        return nil
    }
    private var sections: [(title: String, body: String)] {
        var out: [(title: String, body: String)] = []
        var currentTitle: String?
        var buffer: [String] = []
        func flush() {
            if let title = currentTitle {
                let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append((title: title, body: body)) }
            }
            currentTitle = nil; buffer = []
        }
        for raw in text.components(separatedBy: "\n") {
            let probe = Self.stripped(raw.trimmingCharacters(in: .whitespaces))
            if let hit = Self.headerMap.first(where: { probe.hasPrefix($0.match) }) {
                flush()
                currentTitle = hit.title
                var rest = String(probe.dropFirst(hit.match.count)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") || rest.hasPrefix("：") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
                while rest.hasPrefix("*") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
                if !rest.isEmpty { buffer.append(rest) }
            } else if currentTitle != nil {
                buffer.append(raw)
            }
        }
        flush()
        return out
    }
    private static func lines(_ body: String) -> [String] {
        body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static func isBullet(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "·•-*".contains(first)
    }
    private static func bulletText(_ line: String) -> String {
        String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    private static func stripped(_ s: String) -> String {
        var r = s
        while let f = r.first, "*#>".contains(f) || f == "-" || f == "•" || f == " " { r.removeFirst() }
        return r
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let confidence {
                HStack(spacing: 6) {
                    Text("置信度").font(.caption2).foregroundStyle(p.muted)
                    Text(confidence).font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(confidence == "高" ? p.forest.opacity(0.16) : confidence == "中" ? p.chartGold.opacity(0.20) : p.risk.opacity(0.16), in: Capsule())
                        .foregroundStyle(confidence == "高" ? p.forest : confidence == "中" ? p.chartGold : p.risk)
                }
            }
            if sections.isEmpty {
                Text(text).font(.subheadline).foregroundStyle(p.ink).textSelection(.enabled)
            } else {
                ForEach(sections.indices, id: \.self) { i in
                    let sec = sections[i]
                    let caution = sec.title == "风险" || sec.title == "失效条件"
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: caution ? "exclamationmark.triangle.fill" : "circle.fill").font(.system(size: 7)).foregroundStyle(caution ? p.terracotta : p.forest)
                            Text(sec.title).font(.caption.weight(.semibold)).foregroundStyle(caution ? p.terracotta : p.forest)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            let lines = Self.lines(sec.body)
                            ForEach(lines.indices, id: \.self) { j in
                                let line = lines[j]
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if Self.isBullet(line) {
                                        Text("·").foregroundStyle(p.muted)
                                        Text(Self.bulletText(line)).font(.subheadline).foregroundStyle(p.ink)
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    } else {
                                        Text(line).font(.subheadline).foregroundStyle(p.ink)
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Text("AI 生成 · 仅供研究，不构成交易指令。").font(.caption2).foregroundStyle(p.muted)
        }
    }
}

/// 借鉴小万量化的「来源采集/决策链」——但用诚实版：把本次分析真正吃进去的输入列出来供核对，
/// 不假装有多阶段引擎。只读展示，不改任何数据。
private struct AIInputsCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    private var healthCount: Int {
        NextBookHealth.issues(book: model.book, quotes: model.quotes, at: Date(), concentrationLimit: NextNum.double(model.goal.concentrationLimit)).count
    }
    var body: some View {
        EditorialSection(title: "本次分析的输入", trailing: "可核对", accent: p.forest) {
            GPCard {
                if let cached = model.quotes[code] {
                    GPDataRow(title: "行情快照", value: "¥\(NextMoney.text(cached.quote.price, digits: 3))",
                              note: "\(cached.quote.source) · \(cached.quote.time.formatted(date: .numeric, time: .shortened)) · \(cached.stamp.label(now: Date()))")
                } else {
                    GPDataRow(title: "行情快照", value: "无缓存报价", note: "分析会标为缺口，不推测价格")
                }
                if let position = model.book.positions.first(where: { $0.code == code }) {
                    GPDataRow(title: "本机持仓", value: "\(position.units) 份 · 成本 ¥\(NextMoney.text(position.bookCost))",
                              note: "每份 ¥\(NextMoney.text(position.costPerUnit, digits: 3))")
                } else {
                    GPDataRow(title: "本机持仓", value: "未记录", note: "仅给出一般性观察")
                }
                GPDataRow(title: "账本体检", value: "\(healthCount) 项待处理", note: "名称/成本/报价/集中度缺口会写进提示")
                GPDataRow(title: "投资目标", value: "\(model.goal.years) 年 · 月预算 ¥\(NextMoney.text(model.goal.monthlyBudget))",
                          note: "集中度线 \(NextMoney.text(model.goal.concentrationLimit))%")
            }
        }
    }
}

private struct AssetsScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var addPosition = false
    @State private var cashAmount = ""
    /// 「按券商余额校准」输入框：填券商显示的可用，系统只补差额。
    @State private var brokerCash = ""
    @State private var cashReason = "用户记录的场内现金变动"
    @State private var cashDirection: Decimal = 1
    /// 同一视图上挂多个 confirmationDialog，SwiftUI 只保证最后一个能弹。
    /// 之前收益到账 / 现金变更 / 撤销 / 删除四个弹窗互相压制，删除点不动就是这个原因。
    /// 现在统一成一个状态驱动一个弹窗。
    @State private var assetsConfirm: AssetsConfirm?

    private enum AssetsConfirm: Identifiable {
        case cash, undo
        var id: String {
            switch self {
            case .cash: return "cash"
            case .undo: return "undo"
            }
        }
        var title: String {
            switch self {
            case .cash: return "确认真实账本变更？"
            case .undo: return "撤销最近账本变更？"
            }
        }
        var message: String {
            switch self {
            case .cash: return "本操作会改变真实场内账本，写入审计记录；不会向券商下单。"
            case .undo: return "撤销前会检查当前账本版本，仅当账本仍匹配该审计版本时生效。"
            }
        }
    }
    private var valuation: NextAssetValuation { model.book.valuation(using: model.quotes, at: Date()) }
    private var freshQuoteCount: Int {
        model.book.positions.filter { position in
            guard let quote = model.quotes[position.code] else { return false }
            return quote.quote.isFreshForPricePlan(at: Date())
        }.count
    }

    @ViewBuilder private var assetThemePrelude: some View {
        switch p.theme {
        case .editorial:
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill").foregroundStyle(p.chartGold)
                Text("场内资产手册").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(p.ink)
                Spacer()
                Text("真实账本").font(.caption2.weight(.medium)).foregroundStyle(p.muted)
            }.padding(.horizontal, 3)
        case .modern:
            EmptyView()
        case .dashboard:
            HStack(spacing: 8) {
                assetMetric(title: "持仓", value: "\(model.book.positions.filter { $0.units > 0 }.count)", note: "只真实证券")
                assetMetric(title: "现金", value: "¥\(NextMoney.text(model.book.cash))", note: "账本余额")
                assetMetric(title: "新鲜报价", value: "\(freshQuoteCount)/\(model.book.positions.filter { $0.units > 0 }.count)", note: "只计有效时点")
            }
        case .magazine:
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(.dateTime.year().month(.wide).day()))
                    .font(.caption.weight(.medium)).foregroundStyle(p.muted)
                Text("我的资产与现金流")
                    .font(.system(size: 25, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                Text("以真实流水为底稿，行情估值会随数据时点更新。")
                    .font(.caption).foregroundStyle(p.muted)
            }.padding(.vertical, 3)
        case .puzzle:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                assetMetric(title: "持仓标的", value: "\(model.book.positions.filter { $0.units > 0 }.count)", note: "真实账本")
                assetMetric(title: "可用现金", value: "¥\(NextMoney.text(model.book.cash))", note: "不含未成交计划")
                assetMetric(title: "今日盈亏", value: valuation.dailyChange.map { "¥\(NextMoney.text($0))" } ?? "数据不足",
                            note: "由真实流水与可靠行情计算")
                assetMetric(title: "有效报价", value: "\(freshQuoteCount) 只", note: "有时间戳且新鲜")
            }
        }
    }

    private func assetMetric(title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(p.muted)
            Text(value).font(.system(size: p.theme == .dashboard ? 12 : 15, weight: .bold,
                                     design: p.theme == .magazine ? .serif : .rounded))
                .monospacedDigit().foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.75)
            Text(note).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: p.theme == .puzzle ? 72 : 54, alignment: .leading)
        .padding(10)
        .background(p.theme == .puzzle ? p.tint : p.paper,
                    in: RoundedRectangle(cornerRadius: p.theme == .puzzle ? 17 : 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.theme == .puzzle ? 17 : 11, style: .continuous)
            .stroke(p.primary.opacity(0.18), lineWidth: 0.8))
    }

    private var analysisEntry: some View {
        NavigationLink(value: GPRoute.portfolioAnalysis) {
            GPCard(accent: p.jade) {
                IntentRow(icon: "chart.pie", title: "持仓盈亏与风险分析", detail: "成本口径、区间表现、集中度与账户诊断")
            }
        }.buttonStyle(.plain).accessibilityIdentifier("assets.analysis.open")
    }

    private var positionsSection: some View {
        EditorialSection(title: "持仓明细", trailing: "\(model.book.positions.count) 项", accent: p.jade) {
            HStack {
                Button { addPosition = true } label: { Label("录入已确认持仓", systemImage: "plus") }.font(.caption.weight(.semibold))
                Spacer()
                NavigationLink(value: GPRoute.fills) { Label("资产流水", systemImage: "list.bullet.rectangle") }.font(.caption)
            }.tint(p.forest)
            if model.book.positions.isEmpty {
                GPStatus(title: "账本为空", detail: "只录入你确认的场内证券，不自动导入旧账本或场外基金。", symbol: "tray")
            }
            ForEach(model.book.positions) { position in PositionRow(position: position, quote: model.quotes[position.code]) }
            NavigationLink(value: GPRoute.dividends(nil)) {
                IntentRow(icon: "yensign.circle", title: "收息与派息", detail: "实际到账、待到账及股息买入参考")
            }.buttonStyle(.plain)
        }
    }

    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 12) {
                GPHeroAssetCard(
                    totalText: valuation.total.map { "¥\(NextMoney.text($0))" } ?? "行情数据不足",
                    totalCaption: valuation.isComplete ? nil : "\(valuation.pricedPositions)/\(valuation.totalPositions) 只持仓有报价，暂不算总资产",
                    changeText: valuation.dailyChange.map { "\($0 >= 0 ? "+" : "")¥\(NextMoney.text($0))" },
                    changePercentText: valuation.dailyChangePercent.map { "\($0 >= 0 ? "+" : "")\(NextNum.signed(NextNum.double($0)))%" },
                    infoText: "总资产 = 账本现金 + 持仓市值，全部本机计算、不联网。只有持仓与最新报价齐备时才显示合计；缺报价时不会把部分估值当成总资产。",
                    history: model.book.history
                )
                .padding(.top, 6)
                assetThemePrelude
                switch p.theme {
                case .editorial, .dashboard:
                    analysisEntry
                    positionsSection
                case .modern, .magazine:
                    positionsSection
                    analysisEntry
                case .puzzle:
                    analysisEntry
                    positionsSection
                }
                // 收息通过持仓明细进入，共用同一真实账本，不再占一个主导航位。
                EditorialSection(title: "现金变动", trailing: "可用 ¥\(NextMoney.text(model.book.cash))") {
                    HStack { Button("转入") { cashDirection = 1 }; Button("转出") { cashDirection = -1 }.foregroundStyle(p.risk) }.buttonStyle(.bordered)
                    Text("金额").font(.caption2).foregroundStyle(.secondary)
                    TextField("金额", text: $cashAmount).font(.subheadline).textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad).submitLabel(.done).accessibilityIdentifier("assets.cash.amount")
                    Text("用途/备注").font(.caption2).foregroundStyle(.secondary)
                    TextField("用途/备注", text: $cashReason).font(.subheadline).textFieldStyle(.roundedBorder)
                        .submitLabel(.done).accessibilityIdentifier("assets.cash.reason")
                    GPActionButton(title: "审核并记录现金变动", secondary: true) { assetsConfirm = .cash }
                        .accessibilityIdentifier("assets.cash.record")
                    Divider().overlay(p.line.opacity(0.7)).padding(.vertical, 2)
                    // 券商每天会有预扣、结息、佣金结算，逐个记太累；直接对余额校准一次。
                    Text("按券商余额校准").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                    compactField("券商里显示的可用（元）", text: $brokerCash)
                    GPActionButton(title: "校准到券商余额", secondary: true) {
                        if let target = try? NextMoney.parse(brokerCash) {
                            let delta = target - model.book.cash
                            if delta == 0 { model.errorMessage = "与账本现金一致，无需校准" }
                            else {
                                do {
                                    try model.adjustRealCash(delta, reason: "按券商余额校准到 ¥\(NextMoney.text(target))")
                                    brokerCash = ""
                                } catch { model.errorMessage = error.localizedDescription }
                            }
                        } else { model.errorMessage = "请输入券商显示的可用金额" }
                    }
                    Text("只补差额，不改写历史；差额会作为一条现金流水留痕。").font(.caption2).foregroundStyle(p.muted)
                    if let latest = model.book.cashMovements.last { GPDataRow(title: latest.reason, value: "\(latest.amount >= 0 ? "+" : "")¥\(NextMoney.text(latest.amount))", note: latest.date.formatted(date: .numeric, time: .shortened)) }
                }
                EditorialSection(title: "安全与数据") {
                    Button { assetsConfirm = .undo } label: { IntentRow(icon: "arrow.uturn.backward", title: "撤销最近账本变更", detail: "仅当账本仍匹配该审计版本时可撤销") }.buttonStyle(.plain)
                    Text("审计记录与备份恢复已归入「我的」页，这里不再重复放置。").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.sheet(isPresented: $addPosition) { AddPositionSheet { code, name, units, cost, acquiredAt in do { try model.addPosition(code: code, name: name, units: units, cost: cost, acquiredAt: acquiredAt) } catch { model.errorMessage = error.localizedDescription } } }
        .confirmationDialog(assetsConfirm?.title ?? "", isPresented: Binding(get: { assetsConfirm != nil }, set: { if !$0 { assetsConfirm = nil } }), titleVisibility: .visible) {
            if let action = assetsConfirm {
                switch action {
                case .cash:
                    Button("确认记录", role: .destructive) {
                        do { try model.adjustRealCash(cashDirection * NextMoney.parse(cashAmount), reason: cashReason); cashAmount = "" } catch { model.errorMessage = error.localizedDescription }
                        assetsConfirm = nil
                    }
                case .undo:
                    Button("确认撤销", role: .destructive) {
                        do { try model.undoLatestLedgerChange() } catch { model.errorMessage = error.localizedDescription }
                        assetsConfirm = nil
                    }
                }
                Button("取消", role: .cancel) { assetsConfirm = nil }
            }
        } message: { Text(assetsConfirm?.message ?? "") }
        .task {
            guard !model.book.positions.isEmpty else { return }
            for pos in model.book.positions { await model.refreshDividendHistory(pos.code) }
        }
    }
}

private struct IncomeRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let onSave: (NextIncomeEvent) -> Void
    private let initialCode: String?
    init(initialCode: String? = nil, onSave: @escaping (NextIncomeEvent) -> Void) {
        self.initialCode = initialCode; self.onSave = onSave
        _code = State(initialValue: initialCode ?? "")
    }
    @State private var kind: NextIncomeKind = .etfDistribution
    @State private var code = ""
    @State private var name = ""
    @State private var gross = ""
    @State private var tax = "0"
    @State private var perUnit = ""
    @State private var units = ""
    @State private var exDate = Date()
    @State private var payDate = Date()
    @State private var note = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("收益类型") {
                    Picker("类型", selection: $kind) { ForEach(NextIncomeKind.allCases) { Text($0.title).tag($0) } }
                    if kind == .etfDistribution {
                        TextField("ETF 六位代码", text: $code).keyboardType(.numberPad)
                        if let position = model.book.positions.first(where: { $0.code == code }) {
                            Text("当前账面份额：\(position.units) · 分红金额和实际到账以券商记录为准。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let quote = model.quotes[code]?.quote {
                            Text("\(quote.name) · 尚未录入真实持仓份额；只记录到账金额。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField(kind == .etfDistribution ? "收益名称" : "来源 / 账户", text: $name)
                    TextField("预计税前金额（元）", text: $gross).keyboardType(.decimalPad)
                    TextField("预计税费（元）", text: $tax).keyboardType(.decimalPad)
                    if kind == .etfDistribution {
                        TextField("每份分红（可选，元）", text: $perUnit).keyboardType(.decimalPad)
                        TextField("登记日份额（可选）", text: $units).keyboardType(.numberPad)
                        DatePicker("除息日", selection: $exDate, displayedComponents: .date)
                    }
                    DatePicker("预计到账日", selection: $payDate, displayedComponents: .date)
                    TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4)
                }
                Section {
                    Text("这只是待到账计划，不会改变现金。实际到账后在资产页点“确认到账”，才把税后金额记入真实账本并留下审计记录。数据由你根据券商或公告录入；App 不自动猜测分红承诺。")
                        .font(.caption).foregroundStyle(p.muted)
                }
                if let error { Section { Text(error).font(.caption).foregroundStyle(p.risk) } }
            }
            .navigationTitle("记录收息计划").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存计划") { save() }.disabled(gross.isEmpty)
                }
            }
            .onAppear {
                if let initialCode, let position = model.book.positions.first(where: { $0.code == initialCode }) { name = position.name }
                else if let initialCode, let quote = model.quotes[initialCode]?.quote { name = quote.name }
            }
            .onChange(of: code) { _, value in
                if let position = model.book.positions.first(where: { $0.code == value }) { name = position.name }
                else if let quote = model.quotes[value]?.quote { name = quote.name }
            }
            .onChange(of: kind) { _, value in
                if value == .cashInterest { name = "现金账户" }
                else if value == .other { name = "其他收益" }
            }
        }
    }
    private func save() {
        do {
            guard let amount = Decimal(string: gross), amount > 0,
                  let taxAmount = Decimal(string: tax.isEmpty ? "0" : tax), taxAmount >= 0 else {
                throw NextError.invalid("请输入有效的税前金额和税费")
            }
            let per = perUnit.isEmpty ? nil : try NextMoney.parse(perUnit)
            let quantity = units.isEmpty ? nil : Int(units)
            if !units.isEmpty && quantity == nil { throw NextError.invalid("登记日份额必须为整数") }
            let securityName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let event = NextIncomeEvent(kind: kind, code: code.isEmpty ? nil : code,
                name: securityName.isEmpty ? kind.title : securityName,
                exDate: kind == .etfDistribution ? exDate : nil, payDate: payDate,
                units: quantity, perUnit: per, grossAmount: amount, tax: taxAmount,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            try event.validate()
            onSave(event); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct AddPositionSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gp) private var p
    @State private var code = ""; @State private var name = ""; @State private var units = ""; @State private var cost = ""; @State private var confirm = false
    /// 建仓日：你实际开始持有这只的日期。只把这一天才算数的派息登记为「待收」，
    /// 之前发生的除息不算你的（录入一只早已分红过的票时不会凭空冒出历史分红）。默认今天。
    @State private var acquiredAt = Date()
    /// 券商里「成本金额」往往比「成本价」精确：1.4715 会被券商显示成 1.472，
    /// 按每份价录入会差几分钱。允许直接录合计成本，误差就归零。
    @State private var costByTotal = false
    private var totalCostValue: Decimal? {
        guard let count = Int(units), count > 0, let parsed = try? NextMoney.parse(cost) else { return nil }
        return costByTotal ? parsed : parsed * Decimal(count)
    }
    private var perUnitCostValue: Decimal? {
        guard let count = Int(units), count > 0, let total = totalCostValue else { return nil }
        return total / Decimal(count)
    }
    @State private var lookupStatus = "输入 6 位代码后自动查询名称"
    var body: some View {
        NavigationStack {
            Form {
                Section("证券信息") {
                    TextField("6 位场内代码", text: $code).keyboardType(.numberPad)
                    TextField("名称（自动填入）", text: $name)
                    Text(lookupStatus).font(.caption).foregroundStyle(.secondary)
                    TextField("份数（股 / 份）", text: $units).keyboardType(.numberPad)
                    Picker("录入方式", selection: $costByTotal) {
                        Text("按每份成本").tag(false)
                        Text("按合计成本").tag(true)
                    }.pickerStyle(.segmented)
                    TextField(costByTotal ? "合计成本（元）" : "每份成本（元，建议 4 位小数）", text: $cost).keyboardType(.decimalPad)
                    if let total = totalCostValue, let perUnit = perUnitCostValue, let count = Int(units) {
                        GPDataRow(title: costByTotal ? "每份成本（自动计算）" : "合计成本（自动计算）",
                                  value: costByTotal ? "¥\(NextMoney.text(perUnit, digits: 3))" : "¥\(NextMoney.text(total))",
                                  note: "\(count) 份 × ¥\(NextMoney.text(perUnit, digits: 3)) = ¥\(NextMoney.text(total)) · 券商里这个价叫「买入均价」")
                        if !costByTotal {
                            Text("券商若显示 1.4715 这类 4 位小数，请按原始值录入，否则每份差 0.0005 会让持仓盈亏差几毛钱。")
                                .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DatePicker("建仓日", selection: $acquiredAt, displayedComponents: .date)
                    Text("只把建仓日及之后的派息算作你的「待收」；之前发生的除息不登记（你录入的持仓已是分红后的，不再回溯历史分红）。").font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Text("录入持仓只记录**当前事实**：份数 + 每份买入成本 + 建仓日。它不产生买入流水，因此**不会计算摊薄成本**，也**不会动现金**（现金只由买入/卖出、以及「现金变动」改变）。").font(.caption).foregroundStyle(p.muted)
                }
            }
                .navigationTitle("录入持仓").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
                .onChange(of: code) { _, value in
                    guard value.count == 6, value.allSatisfy(\.isNumber) else { name = ""; lookupStatus = "输入 6 位代码后自动查询名称"; return }
                    lookupStatus = "正在查询证券名称…"
                    Task {
                        await model.refreshQuotes(codes: [value])
                        guard code == value else { return }
                        if let found = model.quotes[value]?.quote.name, !found.isEmpty { name = found; lookupStatus = "名称来自行情源" }
                        else if let known = InstrumentCatalog.name(for: value) { name = known; lookupStatus = "名称来自内置目录" }
                        else if NextNameBook.isResolved(value) { name = NextNameBook.resolve(value); lookupStatus = "名称来自本机记录" }
                        else { name = ""; lookupStatus = "名称未查到，请检查代码或稍后重试" }
                    }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("核对并保存") { confirm = true }.disabled(code.count != 6 || name.isEmpty || Int(units) == nil || cost.isEmpty) } }
                .confirmationDialog("确认录入真实账本？", isPresented: $confirm, titleVisibility: .visible) { Button("确认保存") { guard let u = Int(units), let total = totalCostValue else { return }; onSave(code, name, u, total, acquiredAt); dismiss() }; Button("取消", role: .cancel) { } } message: { Text("\(code) · \(name) · \(units) 份，合计成本 ¥\(NextMoney.text(totalCostValue ?? 0))（每份 ¥\(NextMoney.text(perUnitCostValue ?? 0, digits: 3))），建仓日 \(Self.dateText(acquiredAt))。保存后会产生可审计记录。") }
        }
    }
    static func dateText(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    let onSave: (String, String, Int, Decimal, Date) -> Void
}

struct GPTradeRequest: Identifiable {
    let code: String
    let side: String
    var id: String { code + side }
}

struct TradeEntrySheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.gp) private var p
    let request: GPTradeRequest
    @State private var units = ""
    @State private var price = ""
    @State private var fee = ""
    @State private var confirm = false
    @State private var confirmImport = false
    @State private var linkedDecisionID: UUID?
    private var name: String { model.name(for: request.code) }
    /// 名称没查出来时返回的是代码本身（不再用「场内证券」这种占位词），据此判断是否还在等名称。
    private var nameResolved: Bool { name != request.code }
    private var verifiedETF: Bool { model.rules[request.code]?.assetClass == .etf || model.quotes[request.code]?.quote.providerInstrumentType == "ETF" }
    private var linkableDecisions: [NextDecisionRecord] {
        model.decisionMemory.filter { NextDecisionMemory.canLinkManualFill($0, code: request.code, at: Date()) }
    }
    /// 本笔需要的现金（买入含手续费）。字段没填全就是 nil。
    private var tradeAmount: Decimal? {
        guard let count = Int(units), count > 0,
              let unitPrice = try? NextMoney.parse(price), unitPrice > 0 else { return nil }
        let feeValue = (try? NextMoney.parse(fee)) ?? 0
        return unitPrice * Decimal(count) + max(0, feeValue)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("\(name) · \(request.code)") {
                    Text(nameResolved ? name : "正在查询证券名称…").font(.subheadline).foregroundStyle(.secondary)
                    TextField("成交价格", text: $price).keyboardType(.decimalPad)
                    TextField("成交份额", text: $units).keyboardType(.numberPad)
                    TextField("本笔手续费", text: $fee).keyboardType(.decimalPad)
                    Text(verifiedETF ? "ETF 手续费默认每笔 ¥0.10" : "证券类别或费率尚未核实，请按券商成交记录填写手续费。")
                    Text("仅记录已在券商完成的交易，不会发出委托。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("真实账本") {
                    Text("可用现金 ¥\(NextMoney.text(model.book.cash))")
                    let held = model.book.positions.first(where: { $0.code == request.code })?.units ?? 0
                    let sellsAvailable = model.book.availableUnits(for: request.code, at: Date())
                    let locked = model.book.lockedUnits(for: request.code, at: Date())
                    Text("持有 \(held) 份 · 可卖 \(sellsAvailable) 份")
                    if locked > 0 {
                        Text("其中 \(locked) 份是今天买入的，T+1 才能卖").font(.caption).foregroundStyle(p.terracotta)
                    }
                    if request.side == "sell", let count = Int(units), count > sellsAvailable {
                        Text("卖出 \(count) 份超过可卖 \(sellsAvailable) 份").font(.caption).foregroundStyle(p.risk)
                    }
                    if let amount = tradeAmount {
                        if request.side == "buy" {
                            let after = model.book.cash - amount
                            if after < 0 {
                                Text("本笔需 ¥\(NextMoney.text(amount))，成交后现金会变成 ¥\(NextMoney.text(after))，还差 ¥\(NextMoney.text(-after))。")
                                    .font(.caption).foregroundStyle(p.risk)
                                Button("先补充现金 ¥\(NextMoney.text(-after))") {
                                    do {
                                        try model.addCash(-after, reason: "买入 \(name) \(units) 份前补充现金")
                                        model.errorMessage = nil
                                    } catch { model.errorMessage = error.localizedDescription }
                                }
                                Text("补充会记一笔现金转入（可审计），然后就可以正常记录这笔买入了。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("本笔需 ¥\(NextMoney.text(amount))（含手续费），成交后剩 ¥\(NextMoney.text(after))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("本笔回款 ¥\(NextMoney.text(amount))，成交后现金 ¥\(NextMoney.text(model.book.cash + amount))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if request.side == "buy" && model.book.positions.allSatisfy({ $0.code != request.code }) {
                        Button("这是已有持仓：直接补录") { confirmImport = true }
                            .disabled(!nameResolved || Int(units) == nil || price.isEmpty)
                        Text("补录已有持仓只记录当前总成本，不虚构历史成交或改动现金。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !linkableDecisions.isEmpty {
                    Section("AI 决策记忆（可选关联）") {
                        Picker("对应的当日判断", selection: $linkedDecisionID) {
                            Text("不关联").tag(Optional<UUID>.none)
                            ForEach(linkableDecisions) { record in
                                Text("\(record.snapshot.headline) · \(record.createdAt.formatted(date: .omitted, time: .shortened))")
                                    .tag(Optional(record.id))
                            }
                        }
                        Text("只有你确认本笔真实成交确实来自所选判断时才关联；未选择时只记真实流水，不自动猜测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(request.side == "buy" ? "记录买入" : "记录卖出")
            .navigationBarTitleDisplayMode(.inline)
            .gpKeyboardDismiss()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("核对") { confirm = true }.disabled(!nameResolved || Int(units) == nil || price.isEmpty || fee.isEmpty) }
            }
            .confirmationDialog("确认补录真实持仓？", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("确认补录") {
                    do {
                        guard let count = Int(units) else { throw NextError.invalid("份额无效") }
                        try model.addPosition(code: request.code, name: name, units: count, cost: try NextMoney.parse(price) * Decimal(count))
                        dismiss()
                    } catch { model.errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("\(name) \(units) 份，每份成本 ¥\(price)。只写入当前真实持仓，不虚构历史成交。") }
            .confirmationDialog("确认写入真实交易流水？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认记录") {
                    do {
                        guard let count = Int(units) else { throw NextError.invalid("份额无效") }
                        try model.recordTrade(code: request.code, name: name, side: request.side, units: count,
                                              price: try NextMoney.parse(price), fee: try NextMoney.parse(fee),
                                              decisionMemoryID: linkedDecisionID)
                        Task { await model.refreshGuidance() }
                        dismiss()
                    } catch { model.errorMessage = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("\(request.side == "buy" ? "买入" : "卖出") \(name) \(units) 份，价格 ¥\(price)，另计手续费 ¥\(fee)。") }
        }.task {
            if !nameResolved { await model.refreshQuotes(codes: [request.code]) }
            if verifiedETF { fee = "0.10" }
        }
    }
}

/// 「我的」只展示身份、连接与少量高频入口。具体配置进入二级页，
/// 避免把全部开关和工具堆在底栏页面形成无限长的滚动列表。
private struct MyHubScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p

    var body: some View {
        GPPageBackground {
            EditorialSection(title: "账户与顾问", accent: p.chartViolet) {
                GPCard(accent: p.chartViolet) {
                    Text("一个真实账户 · 一份 AI 指导")
                        .font(.headline).foregroundStyle(p.ink)
                    Text("\(model.book.positions.count) 只持仓 · \(model.syncStateText)")
                        .font(.caption).foregroundStyle(p.muted)
                    NavigationLink(value: GPRoute.profile) {
                        IntentRow(icon: "person.text.rectangle", title: "AI 对我的了解", detail: "真实成交与反馈形成的投资者画像")
                    }
                }
            }
            EditorialSection(title: "连接与设置", accent: p.chartBlue) {
                GPCard(accent: p.chartBlue) {
                    GPDataRow(title: "NAS", value: model.syncStatus)
                    NavigationLink(value: GPRoute.settings) {
                        IntentRow(icon: "gearshape", title: "应用设置", detail: "主题、手机 AI、NAS 同步与通知")
                    }.accessibilityIdentifier("my.settings.open")
                }
            }
            EditorialSection(title: "我的记录", accent: p.chartGold) {
                GPCard(accent: p.chartGold) {
                    NavigationLink(value: GPRoute.fills) {
                        IntentRow(icon: "list.bullet.rectangle", title: "真实成交与账本", detail: "查看已确认的交易记录")
                    }
                    NavigationLink(value: GPRoute.history) {
                        IntentRow(icon: "clock.arrow.circlepath", title: "AI 判断历史", detail: "回看建议、变化原因和复盘")
                    }
                }
            }
        }
    }
}

private struct SettingsScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var dynamicTypeNote = false
    @State private var nasURL = ""
    @State private var confirmSync = false
    @State private var confirmDownload = false
    @State private var deepSeekKey = ""
    @State private var deepSeekProfile = UserDefaults.standard.string(forKey: "guanpan.deepseek.profile") ?? "flash"
    @State private var mobileAIStatus = DeepSeekMobile.loadKey() == nil ? "未保存 API key" : "本机钥匙串已保存 API key"
    @State private var mobileAIKeyAvailable = DeepSeekMobile.loadKey() != nil
    // MARK: 外观（字号 / 字体 / 自定义颜色）
    @AppStorage("guanpan.targetYield") private var targetYieldInput = "4"
    @State private var inspectEnabled = UserDefaults.standard.bool(forKey: "guanpan.inspect.enabled")
    @State private var inspectHourText = "9"
    private var appearance: GPAppearance { model.preferences.appearance }
    private func updateAppearance(_ mutate: (inout GPAppearance) -> Void) {
        var next = model.preferences.appearance
        mutate(&next)
        model.saveAppearance(next)
    }
    private var inkBinding: Binding<Color> {
        Binding(get: { appearance.inkHex.map { Color(hex: $0) } ?? p.ink },
                set: { hex in if let value = hex.gpHex { updateAppearance { $0.inkHex = value } } })
    }
    private var paperBinding: Binding<Color> {
        Binding(get: { appearance.paperHex.map { Color(hex: $0) } ?? p.paper },
                set: { hex in if let value = hex.gpHex { updateAppearance { $0.paperHex = value } } })
    }
    private var canvasBinding: Binding<Color> {
        Binding(get: { appearance.canvasHex.map { Color(hex: $0) } ?? p.canvas },
                set: { hex in if let value = hex.gpHex { updateAppearance { $0.canvasHex = value } } })
    }
    @State private var testingMobileAI = false
    private func themeChip(title: String, hexes: [UInt32], selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach(Array(hexes.enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(hex: hex)).frame(width: 12, height: 12)
                    }
                }
                Text(title).font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? p.ink : p.muted).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(selected ? p.tint : p.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? p.forest : p.line, lineWidth: selected ? 1.4 : 0.8))
        }
        .buttonStyle(.plain)
    }

    private var profileDigest: String {
        let tags = model.profile.styleTags
        guard !tags.isEmpty else { return "还没有足够行为样本：记录几笔真实成交后 AI 会开始形成结论" }
        return tags.prefix(3).joined(separator: " · ") + "（点开可修改或否掉）"
    }
    var body: some View {
        GPPageBackground {
            VStack(alignment: .leading, spacing: 0) {
                Text("用舒适的方式查看市场").font(.system(.title2, design: .serif).weight(.semibold)).foregroundStyle(p.ink).padding(.top, 8)
                EditorialSection(title: "外观", accent: p.chartViolet) {
                    GPCard(accent: p.chartViolet) {
                        Text("视觉主题").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                themeChip(title: "东方默认", hexes: [0xFBF4E4, 0xC9893A, 0x496B56], selected: model.preferences.themeStyle == nil) {
                                    model.saveAppTheme(nil)
                                }
                                ForEach(AppTheme.allCases) { theme in
                                    themeChip(title: theme.title, hexes: theme.previewHexes,
                                              selected: model.preferences.themeStyle == theme) {
                                        model.saveAppTheme(theme)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Text(model.preferences.themeStyle == nil
                             ? "当前使用东方编辑室作为统一默认主题；你选择任一主题后，首页、持仓、行情和详情都会保持同一套视觉。"
                             : "已固定为「\(model.preferences.themeStyle?.title ?? "")」：所有页面统一这一套外观，数据与 AI 结论不受影响。")
                            .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                        Picker("明暗", selection: Binding(get: { model.theme }, set: model.saveTheme)) { ForEach(GPTheme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("settings.theme")
                        Picker("字号", selection: Binding(get: { appearance.fontScale }, set: { (value: Double) in updateAppearance { $0.fontScale = value } })) {
                            ForEach(GPAppearance.scaleOptions, id: \.value) { option in Text(option.title).tag(option.value) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("settings.fontScale")
                        Picker("字体", selection: Binding(get: { appearance.fontFamily }, set: { (value: GPFontFamily) in updateAppearance { $0.fontFamily = value } })) {
                            ForEach(GPFontFamily.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("settings.fontFamily")
                        ColorPicker("文字颜色", selection: inkBinding, supportsOpacity: false)
                            .accessibilityIdentifier("settings.inkColor")
                        ColorPicker("卡片颜色", selection: paperBinding, supportsOpacity: false)
                            .accessibilityIdentifier("settings.paperColor")
                        ColorPicker("背景颜色", selection: canvasBinding, supportsOpacity: false)
                            .accessibilityIdentifier("settings.canvasColor")
                        if appearance.hasCustomColors {
                            Button("恢复主题默认颜色") { updateAppearance { $0.inkHex = nil; $0.paperHex = nil; $0.canvasHex = nil } }
                                .font(.caption.weight(.semibold)).tint(p.forest)
                        }
                        Text("字号改的是系统动态字体档位，导航栏、列表、表单会一起放大；颜色是在当前主题之上做覆盖。").font(.caption).foregroundStyle(p.muted)
                    }
                }
                EditorialSection(title: "AI 对我的了解", trailing: "真实行为学习", accent: p.terracotta) {
                    GPCard(accent: p.terracotta) {
                        NavigationLink(value: GPRoute.profile) {
                            IntentRow(icon: "person.text.rectangle", title: "AI 对我的了解", detail: profileDigest)
                        }
                        Text("画像只影响推荐什么、怎么表达；不改变行情判断，也不降低风险与数据门槛。")
                            .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                EditorialSection(title: "通知与提醒") {
                    GPCard { NavigationLink(value: GPRoute.alerts) { IntentRow(icon: "bell.badge", title: "提醒和通知中心", detail: "价格、风险、限价计划与 NAS 状态") } }
                }
                EditorialSection(title: "账本与数据") {
                    GPCard {
                        NavigationLink(value: GPRoute.fills) { IntentRow(icon: "list.bullet.rectangle", title: "审计记录", detail: "真实资产修改、撤销和版本") }
                        NavigationLink(value: GPRoute.backups) { IntentRow(icon: "externaldrive", title: "备份与恢复", detail: "数据隔离、校验、确认恢复") }
                    }
                }
                EditorialSection(title: "连接状态", trailing: model.hasPendingUpload ? "有改动待上传" : "已同步") {
                    GPCard {
                        // 顺序按"用户最关心什么"排：账本有没有传上去 → 能不能自动传 → 服务在不在。
                        GPDataRow(title: "账本上传", value: model.syncStateText,
                                  note: "按账本内容指纹判断；只有真的改了才会传，修订号冲突时停止不覆盖")
                        Toggle("自动上传本机账本", isOn: Binding(
                            get: { model.preferences.nasAutoUpload },
                            set: { value in
                                model.preferences.nasAutoUpload = value; model.preferences = model.preferences
                                if value { Task { await model.autoUploadBookIfNeeded() } }
                            }))
                            .font(.caption)
                            .accessibilityIdentifier("settings.nas.autoUpload")
                        GPDataRow(title: "NAS 服务", value: model.syncStatus)
                        GPDataRow(title: "行情服务", value: model.status,
                                  note: "盘中每 10 秒自动刷新，分时每 60 秒；收盘后每 5 分钟。打开应用即刷一次")
                        GPDataRow(title: "行情来源", value: model.preferences.marketSourceMode.title,
                                  note: "真实账本只在你确认后同步；长期研究和相关新闻由已配置的NAS提供")
                    }
                }
                EditorialSection(title: "AI 投资研究", accent: p.terracotta) {
                    GPCard(accent: p.terracotta) {
                    Picker("DeepSeek 模型", selection: $deepSeekProfile) {
                        Text("Flash · 日常研究").tag("flash")
                        Text("Pro · 深度研究").tag("pro")
                    }.pickerStyle(.segmented).onChange(of: deepSeekProfile) { _, value in UserDefaults.standard.set(value, forKey: "guanpan.deepseek.profile") }
                    SecureField("输入 DeepSeek API key", text: $deepSeekKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.deepseek.key")
                    GPDataRow(title: "iPhone 密钥", value: mobileAIStatus, note: "保存在本机 Keychain，不上传 NAS、不进入账本或备份")
                    HStack {
                        Button("保存密钥") {
                            do {
                                try DeepSeekMobile.saveKey(deepSeekKey)
                                deepSeekKey = ""
                                mobileAIKeyAvailable = true
                                mobileAIStatus = "本机钥匙串已保存 API key"
                                model.notice = "DeepSeek key 已安全保存在此 iPhone。"
                            } catch { model.errorMessage = error.localizedDescription }
                        }.font(.caption.weight(.semibold)).tint(p.forest).disabled(deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        Button("删除本机密钥", role: .destructive) {
                            do { try DeepSeekMobile.deleteKey(); deepSeekKey = ""; mobileAIKeyAvailable = false; mobileAIStatus = "本机密钥已删除" }
                            catch { model.errorMessage = error.localizedDescription }
                        }.font(.caption)
                    }
                    GPActionButton(title: testingMobileAI ? "正在测试…" : "测试手机端 DeepSeek 连接", secondary: true, systemImage: "bolt.horizontal.circle") {
                        Task {
                            testingMobileAI = true
                            defer { testingMobileAI = false }
                            let key = deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DeepSeekMobile.loadKey() ?? "" : deepSeekKey
                            do {
                                let modelName = try await DeepSeekMobile.testConnection(key: key, profile: deepSeekProfile)
                                if !deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try DeepSeekMobile.saveKey(deepSeekKey); deepSeekKey = "" }
                                mobileAIKeyAvailable = true
                                mobileAIStatus = "连接成功 · \(modelName) · 已保存在本机钥匙串"
                            } catch { mobileAIStatus = "连接失败 · \(error.localizedDescription)" }
                        }
                    }.disabled(testingMobileAI)
                    Text("连接测试只发送简短探针，不发送持仓、账本或行情；服务商可能计费。API Key 只保存在本机钥匙串。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    Text("NAS 负责长期1分钟行情采集、历史统计与账本同步；手机直连获取最新行情、日K和新闻，并由手机统一生成最终建议。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                EditorialSection(title: "股息策略", accent: p.chartGold) {
                    GPCard(accent: p.chartGold) {
                    HStack(spacing: 8) {
                    Text("目标年化股息率门槛").font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                        Spacer()
                        TextField("4", text: $targetYieldInput).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 72).multilineTextAlignment(.trailing)
                        Text("%").font(.subheadline).foregroundStyle(p.muted)
                    }
                    Text("全App共用，修改后自动保存。按近12个月已核实派息反推参考买入价，并作为收息评分门槛；默认4%，不是收益承诺或买入建议，派息会变化。").font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                EditorialSection(title: "AI 巡检提醒", accent: p.forest) {
                    GPCard {
                    Toggle("每日本机提醒", isOn: Binding(get: { inspectEnabled }, set: { value in
                        inspectEnabled = value
                        if value {
                            let h = min(max(Int(inspectHourText) ?? 9, 0), 23)
                            model.notice = NextLocalNotificationService.enableDailyInspection(hour: h, minute: 0)
                        } else {
                            NextLocalNotificationService.disableDailyInspection()
                            model.notice = "已关闭每日巡检提醒"
                        }
                        UserDefaults.standard.set(value, forKey: "guanpan.inspect.enabled")
                    })).font(.caption)
                    HStack(spacing: 8) {
                        Text("提醒时间").font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                        Spacer()
                        TextField("9", text: $inspectHourText).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                        Text("点（0–23）").font(.caption).foregroundStyle(p.muted)
                        Button("保存时间") {
                            let h = min(max(Int(inspectHourText) ?? 9, 0), 23)
                            inspectHourText = "\(h)"
                            if inspectEnabled { model.notice = NextLocalNotificationService.enableDailyInspection(hour: h, minute: 0) }
                        }.font(.caption.weight(.semibold)).tint(p.forest)
                    }
                    Text("这是设备本机定时提醒（非远端推送，不需要苹果证书）；到点打开 App，到「AI 引擎」点「一键巡检持仓」即可扫描全部持仓的盈亏、股息率与机会。").font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                EditorialSection(title: "NAS 数据服务") {
                    GPCard {
                    Picker("行情与图表来源", selection: Binding(
                        get: { model.preferences.marketSourceMode },
                        set: { mode in
                            model.preferences.marketSourceMode = mode
                            model.preferences = model.preferences
                            model.status = "行情来源已切换为「\(mode.title)」；下一次行情刷新生效"
                        }
                    )) {
                        ForEach(NextMarketSourceMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.menu).accessibilityIdentifier("settings.market.source-mode")
                    Text(model.preferences.marketSourceMode.detail)
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    GPDataRow(title: "当前行情状态", value: model.status,
                              note: "报价、日K、分时和新闻遵循上方来源偏好；NAS长期分钟研究独立运行")
                    TextField("NAS 地址，例如 http://192.168.1.10:8789", text: $nasURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.nas.address")
                    HStack { Button("保存并测试") { do { try model.configureNAS(baseURL: nasURL); Task { await model.probeNAS() } } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).accessibilityIdentifier("settings.nas.save-test"); Spacer(); Button("重新检查") { Task { await model.probeNAS() } }.font(.caption).accessibilityIdentifier("settings.nas.recheck") }.tint(p.forest)
                    GPActionButton(title: "从 NAS 下载账本", secondary: true, systemImage: "arrow.down.doc") { confirmDownload = true }
                    GPActionButton(title: "上传本机账本到 NAS", secondary: true, systemImage: "arrow.up.doc") { confirmSync = true }
                    Divider().padding(.vertical, 4)
                    Text("默认手机直连获取报价、日K、分时和新闻，减少 NAS 穿透流量；NAS地址用于长期分钟档案与研究、必要时的备用来源、分红和真实账本同步。真实账本可关闭自动上传；下载与强制覆盖需要确认，并通过修订号防止静默覆盖。公网连接请使用 HTTPS。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                EditorialSection(title: "无障碍") {
                    GPCard {
                    Button("减少动态效果") { dynamicTypeNote = true }.font(.caption.weight(.medium))
                    Text("底部导航、表单、列表行和图表均提供可访问标签；页面遵循安全区并避让系统键盘。").font(.caption).foregroundStyle(p.muted)
                    }
                }
                // 读取 Info.plist 真实版本，装错包一眼能看出来（旧包会显示老的 build 号）。
                let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("观盘 Next · v\(appVer) (build \(appBuild))").font(.caption2).foregroundStyle(p.muted).padding(.vertical, 18)
            }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { mobileAIKeyAvailable = DeepSeekMobile.loadKey() != nil; nasURL = model.preferences.nasBaseURL }
            .confirmationDialog("确认从 NAS 下载真实账本并替换本机账本？", isPresented: $confirmDownload, titleVisibility: .visible) {
                Button("确认下载", role: .destructive) { Task { await model.downloadBookManually() } }
                Button("取消", role: .cancel) { }
            } message: { Text("本机数据先保存可验证的恢复副本；NAS 账本经校验后写入本机并留下审计记录。") }
            .confirmationDialog("确认把本机真实账本同步到新 NAS？", isPresented: $confirmSync, titleVisibility: .visible) {
                Button("确认同步", role: .destructive) { Task { await model.syncBookManually() } }
                Button("强制覆盖 NAS 上的版本", role: .destructive) { Task { await model.syncBookManually(force: true) } }
                Button("取消", role: .cancel) { }
            } message: { Text("确认同步：只有服务端修订与上次同步一致（或服务端为空）才写入。若一直提示「NAS 修订已变化」，说明两边修订号走岔了（恢复过备份/换过手机/网页端写过），可以改用「强制覆盖」：以本机账本为准覆盖 NAS 当前版本。真实资产不会自动合并、不连接券商。") }
            .alert("系统动效设置", isPresented: $dynamicTypeNote) { Button("好", role: .cancel) { } } message: { Text("请在 iOS 设置 → 辅助功能 → 动态效果中启用“减少动态效果”。应用会遵循系统设置。") }
    }
}

private struct GPSearchHit: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let symbol: String
    let route: GPRoute
    var securityCode: String? = nil
}

private struct SearchSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func matches(_ values: String...) -> Bool {
        query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    private var results: [GPSearchHit] {
        var hits = [GPSearchHit]()
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = Set(model.watch + model.book.positions.map(\.code) + model.quotes.keys)
        let candidates = known.union(query.count == 6 && query.allSatisfy(\.isNumber) ? [query] : [])
        let knownCodes = Set(candidates)
        for item in InstrumentCatalog.search(model.searchText) where !knownCodes.contains(item.code) {
            hits.append(GPSearchHit(id: "catalog-\(item.code)", category: "目录", title: item.name, detail: "\(item.code) · 内置目录（离线可搜，行情仍需联网）", symbol: "book", route: .instrument(item.code), securityCode: item.code))
        }
        for code in candidates.sorted() {
            let name = model.book.positions.first(where: { $0.code == code })?.name ?? model.quotes[code]?.quote.name ?? knownName(code)
            guard matches(code, name) else { continue }
            let position = model.book.positions.first(where: { $0.code == code })
            hits.append(GPSearchHit(id: "security-\(code)", category: "证券", title: name, detail: "\(code)\(position.map { " · 持有 \($0.units) 份" } ?? (model.watch.contains(code) ? " · 自选" : ""))", symbol: "chart.xyaxis.line", route: .instrument(code), securityCode: code))
        }
        for fill in model.book.fills.reversed() where !query.isEmpty && matches(fill.code, fill.side, NextMoney.text(fill.price), fill.date.formatted(date: .numeric, time: .shortened)) {
            hits.append(GPSearchHit(id: "fill-\(fill.id)", category: "交易流水", title: "\(fill.code) · \(fill.side) \(fill.units) 份", detail: "成交价 ¥\(NextMoney.text(fill.price, digits: 3)) · 手续费 ¥\(NextMoney.text(fill.fee)) · \(fill.date.formatted(date: .numeric, time: .shortened))", symbol: "arrow.left.arrow.right", route: .fills))
        }
        for income in model.book.incomeEvents.reversed() where !query.isEmpty && matches(income.name, income.kind.title, income.status.title, NextMoney.text(income.netAmount)) {
            hits.append(GPSearchHit(id: "income-\(income.id)", category: "交易流水", title: "\(income.kind.title) · \(income.name)", detail: "\(income.status.title) · 净额 ¥\(NextMoney.text(income.netAmount))", symbol: "yensign.circle", route: .fills))
        }
        for movement in model.book.cashMovements.reversed() where !query.isEmpty && matches(movement.reason, NextMoney.text(movement.amount), movement.date.formatted(date: .numeric, time: .shortened)) {
            hits.append(GPSearchHit(id: "cash-\(movement.id)", category: "交易流水", title: movement.reason, detail: "\(movement.amount >= 0 ? "+" : "−")¥\(NextMoney.text(movement.amount >= 0 ? movement.amount : -movement.amount)) · \(movement.date.formatted(date: .numeric, time: .shortened))", symbol: "yensign.circle", route: .fills))
        }
        for decision in model.decisions where !query.isEmpty && matches(decision.title, decision.status, decision.origin) {
            hits.append(GPSearchHit(id: "decision-\(decision.id)", category: "历史决策", title: decision.title, detail: "\(decision.status) · \(decision.createdAt.formatted(date: .numeric, time: .shortened))", symbol: "sparkles", route: .history))
        }
        for alert in model.preferences.notifications.alerts where !query.isEmpty && matches(alert.title, alert.detail, alert.level) {
            hits.append(GPSearchHit(id: "alert-\(alert.id)", category: "提醒", title: alert.title, detail: "\(alert.level) · \(alert.stamp.label(now: Date()))", symbol: "bell.badge", route: .alerts))
        }
        return Array(hits.prefix(250))
    }
    private var categories: [String] { ["证券", "交易流水", "历史决策", "提醒"] }
    private func results(in category: String) -> [GPSearchHit] { results.filter { $0.category == category } }
    @ViewBuilder private func hitRow(_ hit: GPSearchHit) -> some View {
        HStack(spacing: 8) {
            NavigationLink(value: hit.route) {
                HStack(spacing: 10) {
                    Image(systemName: hit.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(p.forest).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) { Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink); Text(hit.detail).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }
                    Spacer(minLength: 2); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.muted)
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("search.hit.\(hit.id)")
            if let code = hit.securityCode {
                Button { model.openInstrumentIntent(code); dismiss() } label: { Image(systemName: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(p.forest).frame(width: 38, height: 42).background(p.tint, in: RoundedRectangle(cornerRadius: 11)) }
                    .accessibilityLabel("分析 \(hit.title) 买入机会")
                    .accessibilityIdentifier("search.analyze.\(code)")
            }
        }
    }
    var body: some View {
        NavigationStack {
            GPPageBackground {
                HStack(spacing: 8) {
                    TextField("输入代码或名称", text: $model.searchText).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    if !query.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.muted).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("清除搜索")
                            .accessibilityIdentifier("search.clear")
                    }
                }.padding(.top, 8)
                if results.isEmpty { GPStatus(title: query.isEmpty ? "搜索证券、流水、决策或提醒" : "没有找到匹配内容", detail: query.isEmpty ? "输入代码或关键词；证券结果也可一键进入买入机会分析。" : "可搜索本机证券、交易流水、历史决策和通知记录。", symbol: "magnifyingglass") }
                ForEach(categories, id: \.self) { category in
                    let rows = results(in: category)
                    if !rows.isEmpty {
                        EditorialSection(title: category, trailing: "\(rows.count)") {
                            ForEach(rows) { hit in hitRow(hit) }
                        }
                    }
                }
            }.navigationTitle("全局搜索").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { model.searchText = model.preferences.navigation.searchQuery }
                .onChange(of: model.searchText) { _, query in model.preferences.navigation.searchQuery = query; model.preferences = model.preferences }
                .navigationDestination(for: GPRoute.self) { RouteDestination(route: $0) }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private struct AlertCenterScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    private var quietEnabled: Binding<Bool> { Binding(get: { model.preferences.notifications.quietHours.enabled }, set: { model.preferences.notifications.quietHours.enabled = $0; model.preferences = model.preferences }) }
    private var quietStart: Binding<Int> { Binding(get: { model.preferences.notifications.quietHours.startMinute / 60 }, set: { model.preferences.notifications.quietHours.startMinute = $0 * 60; model.preferences = model.preferences }) }
    private var quietEnd: Binding<Int> { Binding(get: { model.preferences.notifications.quietHours.endMinute / 60 }, set: { model.preferences.notifications.quietHours.endMinute = $0 * 60; model.preferences = model.preferences }) }
    @State private var priceCode = ""
    @State private var price = ""
    @State private var direction: NextPriceAlertDirection = .atOrBelow
    @State private var metric: NextAlertMetric = .price
    var body: some View {
        GPPageBackground {
            EditorialSection(title: "通知记录", trailing: "去重与静默时段") {
                Text("支持价格、均线、组合风险、限价计划、AI候选计划状态和 NAS 数据异常。本机提醒遵循系统通知权限；NAS 的 APNs 远程推送需单独配置。").font(.caption).foregroundStyle(p.muted)
                HStack { Button("允许本机通知") { Task { await model.requestNotificationPermission() } }; Button("发送测试提醒") { model.postLocalAlert(level: "测试", fingerprint: "local-notification-test", title: "观盘Max提醒测试", detail: "这是一条本机通知测试，不代表交易信号。", stamp: NextDataStamp(source: "本机测试", observedAt: Date(), quality: .live, detail: "用户手动触发")) } }.buttonStyle(.bordered).tint(p.forest)
                Text(model.notificationStatus).font(.caption2).foregroundStyle(p.muted)
                if model.preferences.notifications.alerts.isEmpty { GPStatus(title: "暂无通知记录", detail: "网络或 NAS 未连接时仍可查看本机已有提醒。", symbol: "bell.slash") }
                ForEach(model.preferences.notifications.alerts) { alert in DataPanel(title: alert.title, caption: alert.level) { Text(alert.detail).font(.subheadline); Text(alert.stamp.label(now: Date())).font(.caption2.monospaced()).foregroundStyle(p.muted); Text(alert.delivery).font(.caption2).foregroundStyle(p.muted); if !alert.read { Button("标为已读") { guard let index = model.preferences.notifications.alerts.firstIndex(where: { $0.id == alert.id }) else { return }; model.preferences.notifications.alerts[index].read = true; model.preferences = model.preferences }.font(.caption.weight(.semibold)).tint(p.forest) } } }
            }
            EditorialSection(title: "条件提醒", accent: p.terracotta) {
                Picker("维度", selection: $metric) { ForEach(NextAlertMetric.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    TextField("代码", text: $priceCode).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    TextField(metric == .price ? "价格（元）" : "阈值（%，可填负）", text: $price).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                }
                Picker("条件", selection: $direction) { ForEach(NextPriceAlertDirection.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Button("添加\(metric.title)提醒") { do { try model.addPriceAlert(code: priceCode.trimmingCharacters(in: .whitespacesAndNewlines), price: try NextMoney.parse(price), direction: direction, metric: metric); price = "" } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).tint(p.forest)
                if model.preferences.notifications.priceRules.isEmpty { Text("仅以新鲜行情触发；缓存行情不会触发价格提醒。添加后可在任意刷新行情时检查。") .font(.caption).foregroundStyle(p.muted) }
                ForEach(model.preferences.notifications.priceRules) { rule in HStack { VStack(alignment: .leading, spacing: 3) { Text("\(rule.name) · \(rule.code)").font(.subheadline.weight(.semibold)); Text("\(rule.resolvedMetric.title) \(rule.direction.title) " + (rule.resolvedMetric == .price ? "¥\(NextMoney.text(rule.price, digits: 3))" : "\(NextNum.signed(NextNum.double(rule.price)))%") + " · \(rule.enabled ? "已启用" : "已暂停")").font(.caption).foregroundStyle(p.muted) }; Spacer(); Button(rule.enabled ? "暂停" : "启用") { guard let index = model.preferences.notifications.priceRules.firstIndex(where: { $0.id == rule.id }) else { return }; model.preferences.notifications.priceRules[index].enabled.toggle(); model.preferences = model.preferences }.font(.caption); Button("删除", role: .destructive) { model.removePriceAlert(rule.id) }.font(.caption) } }
            }
            EditorialSection(title: "静默时段") {
                Toggle("在此期间只记录、不弹出", isOn: quietEnabled).tint(p.forest)
                HStack { Picker("开始", selection: quietStart) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }; Picker("结束", selection: quietEnd) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } } }.pickerStyle(.menu)
                Text("\(model.preferences.notifications.quietHours.startMinute / 60):00 – \(model.preferences.notifications.quietHours.endMinute / 60):00；静默期间通知保留在记录中，不重复弹出。").font(.caption).foregroundStyle(p.muted)
            }
        }.navigationTitle("通知中心").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss().task {
            if priceCode.isEmpty, let code = model.preferences.navigation.selectedSecurity { priceCode = code }
            await model.refreshNotificationStatus()
        }
    }
}

private struct LedgerHistoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var exportURL: URL?
    @State private var pendingFillDelete: UUID?
    var body: some View {
        GPPageBackground {
            EditorialSection(title: "账本修改审计", trailing: "\(model.ledger.events.count) 条") {
                if model.ledger.events.isEmpty { GPStatus(title: "暂无变更记录", detail: "每次真实账本写入都将记录前后版本和原因。", symbol: "checkmark.shield") }
                ForEach(model.ledger.events.reversed()) { event in DataPanel(title: event.action, caption: event.at.formatted(date: .numeric, time: .shortened)) { Text(event.reason).font(.caption); GPDataRow(title: "账前现金", value: "¥\(NextMoney.text(event.before.cash))"); GPDataRow(title: "账后现金", value: "¥\(NextMoney.text(event.after.cash))"); if event.undoneAt != nil { Text("已撤销").font(.caption).foregroundStyle(p.terracotta) } } }
            }
            EditorialSection(title: "导出", accent: p.chartGold) {
                if let exportURL {
                    ShareLink(item: exportURL) { Label("导出 CSV（持仓 / 成交 / 收益 / 现金）", systemImage: "square.and.arrow.up") }
                        .font(.caption.weight(.semibold)).tint(p.forest)
                } else {
                    Text("正在准备导出文件…").font(.caption).foregroundStyle(p.muted)
                }
                Button { exportURL = NextCSVExport.write(book: model.book, quotes: model.quotes) } label: {
                    Label("重新生成", systemImage: "arrow.clockwise").font(.caption)
                }.tint(p.forest)
                Text("含 BOM，Excel 直接打开不乱码；只导出本机账本，不含行情缓存与图片。")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            EditorialSection(title: "真实资产流水") {
                ForEach(model.book.cashMovements.reversed()) { flow in GPDataRow(title: flow.reason, value: "\(flow.amount >= 0 ? "+" : "")¥\(NextMoney.text(flow.amount))", note: flow.date.formatted(date: .numeric, time: .shortened)) }
                ForEach(model.book.fills.reversed()) { fill in
                    let buy = fill.side == "buy"
                    HStack(alignment: .center, spacing: 6) {
                        GPDataRow(title: "\(model.name(for: fill.code)) · \(fill.code) · \(buy ? "买入" : "卖出")",
                                  value: "\(fill.units) 份 × ¥\(NextMoney.text(fill.price, digits: 3))",
                                  note: "手续费 ¥\(NextMoney.text(fill.fee))" + (buy ? "" : " · 已实现 \(fill.realized >= 0 ? "+" : "")¥\(NextMoney.text(fill.realized))") + " · \(fill.date.formatted(date: .numeric, time: .shortened))",
                                  valueColor: buy ? p.gpUp : p.gpDown)
                        Button { pendingFillDelete = fill.id } label: {
                            Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(p.risk.opacity(0.85)).frame(width: 30, height: 30)
                        }.buttonStyle(.plain).accessibilityLabel("删除这条流水")
                    }
                }
                if model.book.fills.isEmpty { Text("暂无成交流水。删除流水会同步回滚该笔对持仓与现金的影响。").font(.caption2).foregroundStyle(p.muted) }
                ForEach(model.book.incomeEvents.reversed()) { income in GPDataRow(title: "\(income.kind.title) · \(income.name) · \(income.status.title)", value: "+¥\(NextMoney.text(income.netAmount))", note: (income.status == .received && income.kind == .etfDistribution ? "已冲减该标的摊薄成本 · " : "") + "\(income.status == .received ? income.receivedAt?.formatted(date: .numeric, time: .shortened) ?? "已到账" : "预计到账 \(income.payDate.formatted(date: .numeric, time: .omitted))") · 税前 ¥\(NextMoney.text(income.grossAmount)) · 税费 ¥\(NextMoney.text(income.tax))") }
            }
        }.navigationTitle("资产流水与审计").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
        .confirmationDialog("删除这条成交流水？", isPresented: Binding(get: { pendingFillDelete != nil }, set: { if !$0 { pendingFillDelete = nil } }), titleVisibility: .visible) {
            Button("删除并回滚持仓与现金", role: .destructive) {
                guard let id = pendingFillDelete else { return }
                do { try model.deleteFill(id) } catch { model.errorMessage = error.localizedDescription }
                pendingFillDelete = nil
            }
            Button("取消", role: .cancel) { pendingFillDelete = nil }
        } message: {
            Text("删除后这笔买入/卖出对持仓份额、账面成本和现金的影响会一并撤销；操作仍记入审计，可撤销。")
        }
        .task { if exportURL == nil { exportURL = NextCSVExport.write(book: model.book, quotes: model.quotes) } }
    }
}

private struct DecisionHistoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var reviewNotes: [UUID: String] = [:]
    var body: some View {
        GPPageBackground {
            if model.decisions.isEmpty { GPStatus(title: "尚无已留存的历史决策", detail: "分析后会保存当时行情、来源、风险和你的选择；未持久化前不显示虚构成绩。", symbol: "clock.arrow.circlepath") }
            ForEach(model.decisions) { decision in
                EditorialSection(title: decision.title, trailing: decision.createdAt.formatted(date: .numeric, time: .shortened)) {
                    GPDataRow(title: "研究来源", value: decision.origin, note: decision.status)
                    if let selected = decision.selectedOption, let option = decision.options.first(where: { $0.id == selected }) {
                        GPDataRow(title: "已选方案", value: option.title)
                    }
                    ForEach(decision.evidence) { evidence in VStack(alignment: .leading, spacing: 3) { GPDataRow(title: evidence.title, value: evidence.level); Text(evidence.detail).font(.caption).foregroundStyle(p.muted) } }
                    if !decision.review.isEmpty { Text("复盘：\(decision.review)").font(.caption).foregroundStyle(p.muted) }
                    if decision.review.isEmpty {
                        TextField("复盘：后来发生了什么？", text: Binding(get: { reviewNotes[decision.id] ?? "" }, set: { reviewNotes[decision.id] = $0 }), axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                        Button("保存复盘") { do { try model.reviewDecision(decision.id, note: reviewNotes[decision.id] ?? ""); reviewNotes[decision.id] = "" } catch { model.errorMessage = error.localizedDescription } }.font(.caption.weight(.semibold)).tint(p.forest)
                    }
                }
            }
        }.navigationTitle("历史决策").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
    }
}

// 单独成 struct 而不是留在 ForEach 闭包里：原来 HStack + 多个 GPDataRow +
// 三处 isEstimated 三元表达式挤在同一个表达式里，编译器类型检查直接超时
// （error: unable to type-check this expression in reasonable time）。
private struct DividendEventRow: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let event: NextETFDividendEvent

    private var estimated: Bool { event.isEstimated == true }
    private var statusText: String { estimated ? "复权行情估算 · 未核实" : "历史派息数据 · 非到账凭证" }
    private var statusSymbol: String { estimated ? "function" : "checkmark.seal" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                NavigationLink(value: GPRoute.instrument(event.code)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name(for: event.code)).font(.subheadline.weight(.semibold)).foregroundStyle(p.forest)
                        Text(event.code).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(p.muted)
                    }
                }
                Spacer()
                Text("¥\(NextMoney.text(event.amountPerShare, digits: 3))/份")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(p.ink)
            }
            GPDataRow(title: "除息日", value: event.date)
            if let record = event.recordDate { GPDataRow(title: "权益登记日", value: record) }
            if let pay = event.payDate { GPDataRow(title: "现金发放日", value: pay) }
            Label(statusText, systemImage: statusSymbol)
                .font(.caption2)
                .foregroundStyle(estimated ? p.terracotta : p.muted)
        }
        .padding(.vertical, 9)
    }
}

/// 股息买入参考（收息页首卡）。口径对齐常见「股息率更新」表：
///   近12个月每份已核实派息 ÷ 现价 = 当前股息率
///   目标买入价 = 近12个月每份已核实派息 ÷ 目标股息率
///   买入点参考「目标价 +15% 以内」（与该表备注一致）
/// 只用已核实派息，不用推算值冒充；下次分红按最近一次除息月份外推，标注为预估。
private struct DividendAdviceCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var entry = ""
    @State private var code: String?
    @AppStorage("guanpan.targetYield") private var targetYieldText = "4"
    @State private var loading = false
    @State private var note: String?

    private var targetYield: Decimal { Decimal(string: targetYieldText.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var events: [NextETFDividendEvent] {
        guard let code else { return [] }
        let merged = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
        return merged.filter { $0.code == code }
    }
    private var perShare: Decimal {
        guard let code else { return 0 }
        return NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: dividendTodayString())
    }
    private var quote: NextQuote? {
        guard let code else { return nil }
        return model.quotes[code]?.quote
    }
    private var displayName: String {
        guard let code else { return "" }
        return quote?.name ?? model.book.positions.first(where: { $0.code == code })?.name ?? knownName(code)
    }
    private var yieldPercent: Decimal? {
        guard let price = quote?.price, price > 0, perShare > 0 else { return nil }
        return perShare / price * 100
    }
    private var targetPrice: Decimal? {
        guard targetYield > 0, perShare > 0 else { return nil }
        return perShare / (targetYield / 100)
    }
    private var dividendScore: DividendBuyScore? {
        guard let code else { return nil }
        return DividendBuyScoreEngine.evaluate(
            code: code,
            perShare: perShare,
            price: quote?.price,
            iopv: quote?.iopv,
            samples: model.chartData["\(code):day"]?.orderedSamples ?? [],
            dividendEvents: events,
            today: dividendTodayString(),
            targetYieldPercent: targetYield
        )
    }
    private var dividendScoreSummary: String? {
        guard let score = dividendScore else { return nil }
        let base = "股息 \(score.yieldPoints)/40 · 价格位置 \(score.positionPoints)/35 · 回撤 \(score.drawdownPoints)/15 · 分红稳定 \(score.stabilityPoints)/10"
        guard !score.missing.isEmpty else { return base }
        return "\(base)；缺少 \(score.missing.joined(separator: "、"))"
    }
    private var nextDividendText: String? {
        let confirmed = events.filter { $0.isEstimated != true }.map(\.date).sorted()
        guard let last = confirmed.last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return "预计 \(year + 1) 年 \(month) 月前后（按最近除息日 \(last) 外推）"
    }
    private var advice: (headline: String, detail: String, tone: Color)? {
        guard code != nil else { return nil }
        guard let price = quote?.price, price > 0 else {
            return ("还没拿到这只的行情", "点「查询」会自动拉现价与派息历史；离线时只显示本机缓存。", p.muted)
        }
        guard let quote, quote.isFresh(at: Date()) else {
            let time = quote?.time.formatted(date: .abbreviated, time: .shortened) ?? "未知"
            return ("行情已过期，暂不判断当前价位", "最后报价时间：\(time)。历史股息和价格统计可以查看，但不能据此生成今天的买入倾向。", p.muted)
        }
        guard perShare > 0 else {
            return ("近 12 个月没有已核实派息", "无法计算股息率与目标买入价；不会用推算值冒充已核实分红。", p.muted)
        }
        guard let target = targetPrice, target > 0 else {
            return ("先填目标股息率", "目标买入价 = 近12个月每份 ¥\(NextMoney.text(perShare, digits: 3)) ÷ 目标股息率。", p.muted)
        }
        let current = NextMoney.text(perShare / price * 100, digits: 3)
        guard let score = dividendScore else {
            return ("综合数据不足，暂不判断", "当前股息率约 \(current)%，但缺少可用综合评分数据；目标股息率只是筛选门槛，不单独构成买入理由。", p.muted)
        }
        let factorSummary = "综合 \(score.total) 分（股息 \(score.yieldPoints)/40、价格位置 \(score.positionPoints)/35、回撤 \(score.drawdownPoints)/15、分红稳定 \(score.stabilityPoints)/10）"
        if !score.missing.isEmpty {
            return ("综合评分数据不完整", "\(factorSummary)。缺少：\(score.missing.joined(separator: "、"))。目标价 ¥\(NextMoney.text(target, digits: 3))只作参考，不据此提示买入。", p.muted)
        }
        if price <= target, score.total >= 60 {
            return ("达到股息门槛，价格与分红条件值得关注", "当前股息率约 \(current)%，\(factorSummary)。仍需结合基金质量、组合仓位和风险判断；这不是买入指令。", p.jade)
        }
        if price <= target {
            return ("股息率达标，但综合条件尚不足", "当前股息率约 \(current)%，\(factorSummary)。高股息可能来自价格下跌，先核查原因，不因单一指标买入。", p.chartGold)
        }
        return ("尚未达到目标股息率门槛", "当前股息率约 \(current)%，\(factorSummary)；目标参考价 ¥\(NextMoney.text(target, digits: 3))。继续观察价格和分红变化，不把历史派息视为保证。", p.terracotta)
    }

    var body: some View {
        EditorialSection(title: "股息综合参考", trailing: "非下单建议", accent: p.chartGold) {
            Text("输入代码查看当前股息率、目标参考价，以及股息率、价格区间、回撤和分红稳定性的综合评分。只有股息率达到门槛且价格/分红条件也合适时才提示关注；仍需人工判断，不是下单建议。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("输入 6 位代码，如 159941", text: $entry).keyboardType(.numberPad).textFieldStyle(.roundedBorder).submitLabel(.done)
                Button(loading ? "查询中…" : "查询", action: query).buttonStyle(.borderedProminent).tint(p.forest).disabled(loading)
            }
            if !displayName.isEmpty { Text("\(displayName) · \(code ?? entry)").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink) }
            if let note { Text(note).font(.caption).foregroundStyle(p.muted) }
            if code != nil {
                GPDataRow(title: "现价", value: quote.map { "¥\(NextMoney.text($0.price, digits: 3))" } ?? "—", note: quote.map { "行情 \($0.time.formatted(date: .omitted, time: .shortened))" } ?? "点查询刷新行情")
                GPDataRow(title: "近12个月每份派息（已核实）", value: perShare > 0 ? "¥\(NextMoney.text(perShare, digits: 3))" : "—", note: perShare > 0 ? "只统计已核实派息" : "无已核实记录")
                GPDataRow(title: "当前股息率", value: yieldPercent.map { "\(NextMoney.text($0, digits: 3))%" } ?? "—", note: "每份派息 ÷ 现价")
                GPDataRow(title: "目标买入价", value: targetPrice.map { "¥\(NextMoney.text($0, digits: 3))" } ?? "—", note: "按目标股息率 \(NextMoney.text(targetYield, digits: 3))% 反推")
                GPDataRow(title: "下次分红", value: nextDividendText ?? "—", note: "按历史除息月份外推，以基金公告为准")
                if let score = dividendScore {
                    GPDataRow(title: "综合股息参考", value: "\(score.total) 分 · \(score.tier.rawValue)", note: dividendScoreSummary ?? "")
                }
                if let advice {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(advice.headline).font(.subheadline.weight(.semibold)).foregroundStyle(advice.tone)
                        Text(advice.detail).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 4)
                }
                HStack(spacing: 6) {
                    Text("统一目标年化股息率 %").font(.caption2).foregroundStyle(p.muted)
                    TextField("4", text: $targetYieldText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 64)
                }
            }
        }
    }

    private func query() {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard value.count == 6, value.allSatisfy(\.isNumber) else { note = "请输入 6 位场内证券代码"; return }
        note = nil; loading = true
        let target = value
        code = target
        Task {
            await model.refreshDividendHistory(target)
            await model.refreshInstrument(target)
            loading = false
        }
    }
}

func dividendTodayString() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

private struct DividendHistoryScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String?
    private var events: [NextETFDividendEvent] {
        let all = NextDividendAnalytics.merged(model.book.dividendEvents + model.dividendEvents.values.flatMap { $0 })
        return all.filter { code == nil || $0.code == code }.sorted { $0.date > $1.date }
    }
    private var securities: [String] {
        let held = model.book.positions.map(\.code)
        let watched = model.watch
        return Array(Set(held + watched + (code.map { [$0] } ?? []))).sorted()
    }
    // 这两个字符串原本直接内联在 EditorialSection 的实参里，跟后面的大闭包一起
    // 让编译器类型检查超时（error: unable to type-check this expression in reasonable time）。
    private var sectionTitle: String { code.map { "\($0) 派息记录" } ?? "全部 ETF 派息记录" }
    private var sectionTrailing: String { "\(events.count) 条" }
    @State private var addIncome = false
    @State private var incomeConfirm: UUID?
    @State private var recordsExpanded = false
    @State private var adviceExpanded = false
    private var receivedTotal: Decimal {
        model.book.incomeEvents.filter { $0.status == .received }.reduce(Decimal.zero) { $0 + $1.netAmount }
    }
    private var expectedTotal: Decimal {
        model.book.incomeEvents.filter { $0.status == .expected }.reduce(Decimal.zero) { $0 + $1.netAmount }
    }
    var body: some View {
        GPPageBackground {
            // 收息总览：真实到账与待到账的核心数字，始终展开。
            EditorialSection(title: "收息总览", trailing: "真实账本", accent: p.chartGold) {
                HStack(spacing: 20) {
                    GPValue(label: "已到账净收入", value: "¥\(NextMoney.text(receivedTotal))", emphasis: p.jade)
                    GPValue(label: "待到账计划", value: "¥\(NextMoney.text(expectedTotal))", footnote: "不计入账本现金")
                }
                GPActionButton(title: "记录预期分红 / 收息", secondary: true, systemImage: "yensign.circle") { addIncome = true }
                ForEach(model.book.incomeEvents.sorted { $0.payDate > $1.payDate }) { event in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(event.kind.title) · \(event.name)").font(.subheadline.weight(.medium))
                            Text("\(event.status.title) · \(event.payDate.formatted(date: .numeric, time: .omitted)) · 税后 ¥\(NextMoney.text(event.netAmount))")
                                .font(.caption).foregroundStyle(p.muted)
                        }
                        Spacer()
                        if event.status == .expected {
                            Button("确认到账") { incomeConfirm = event.id }.font(.caption.weight(.semibold)).tint(p.forest)
                        }
                    }
                }
                if model.book.incomeEvents.isEmpty {
                    GPStatus(title: "还没有收息记录", detail: "点上方「记录预期分红 / 收息」登记待收计划；券商实际到账后再确认，税后净额会计入真实现金。", symbol: "yensign.circle")
                }
            }
            // 红利买入时机 · 自选打分：价格越跌、股息率越高，分数越高；全部本机可复算。
            DividendBuyScoreCard()
            // 股息买入参考（按 IMG_5912 的口径：股息率 / 目标买入价 / 收盘价 / 下次分红），默认折叠。
            DisclosureGroup(isExpanded: $adviceExpanded) {
                DividendAdviceCard()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Capsule().fill(p.chartGold.opacity(0.85)).frame(width: 3, height: 15).offset(y: 1)
                    Text("股息买入参考").font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text("推荐方法").font(.caption).foregroundStyle(p.chartGold.opacity(0.85))
                }.padding(.vertical, 14)
            }
            .accentColor(p.forest)
            // 派息记录：没数据或暂时不用时折叠起来，不占篇幅。
            DisclosureGroup(isExpanded: $recordsExpanded) {
                Text("这里记录基金公告或历史数据源中的派息事件，不等于你在除息日实际持有的份额，也不代表现金已到账。已到账金额请以券商流水核对后录入资产账本。")
                    .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                if events.isEmpty {
                    GPStatus(title: "暂无已缓存派息事件", detail: "联网或 NAS 可用时会尝试更新；离线时保留本机记录。估算事件会单独标注，不作为已确认分红。", symbol: "calendar.badge.clock")
                }
                ForEach(events) { event in
                    DividendEventRow(event: event)
                    if event.id != events.last?.id { Divider().overlay(p.line) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Capsule().fill(p.chartGold.opacity(0.85)).frame(width: 3, height: 15).offset(y: 1)
                    Text("派息记录").font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text("\(events.count) 条").font(.caption).foregroundStyle(p.chartGold.opacity(0.85))
                }.padding(.vertical, 14)
            }
            .accentColor(p.forest)
        }
        .navigationTitle("派息历史").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
        .task {
            for security in securities {
                await model.refreshInstrument(security)
                await model.refreshDividendHistory(security)
            }
        }
        .sheet(isPresented: $addIncome) { IncomeRecordSheet(initialCode: code) { event in do { try model.addIncomeEvent(event) } catch { model.errorMessage = error.localizedDescription } } }
        .confirmationDialog("确认这笔收益已实际到账？", isPresented: Binding(get: { incomeConfirm != nil }, set: { if !$0 { incomeConfirm = nil } }), titleVisibility: .visible) {
            Button("确认到账并计入现金", role: .destructive) {
                if let id = incomeConfirm { do { try model.receiveIncomeEvent(id) } catch { model.errorMessage = error.localizedDescription } }
                incomeConfirm = nil
            }
            Button("取消", role: .cancel) { incomeConfirm = nil }
        } message: { Text("只有收到券商或银行实际到账后才确认。本操作会把税后净额写入真实现金和审计流水，不会下单。") }
    }
}

private struct BackupRestoreScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var document = GuanpanBackupDocument()
    @State private var pending: NextArchiveEnvelope?
    @State private var restoreSummary = ""
    @State private var confirmRestore = false
    var body: some View {
        GPPageBackground {
            GPStatus(title: "本机备份与可验证恢复", detail: "导出文件包含独立账本、行情缓存、图表、交易规则和审计记录，并带 SHA-256 校验。", symbol: "externaldrive")
            DataPanel(title: "操作前保护") { GPDataRow(title: "真实账本", value: "独立文件 · iOS 文件保护"); GPDataRow(title: "行情与规则", value: "独立文件缓存"); GPDataRow(title: "恢复前副本", value: "自动保存到本机恢复目录"); GPDataRow(title: "旧版资产", value: "不自动迁移或覆盖") }
            NASBookVersionsPanel()
            GPActionButton(title: "导出完整备份", secondary: true, systemImage: "square.and.arrow.up") {
                do { document = GuanpanBackupDocument(data: try JSONEncoder().encode(model.makeBackup())); isExporting = true }
                catch { model.errorMessage = error.localizedDescription }
            }
            GPActionButton(title: "选择备份并校验", secondary: true, systemImage: "square.and.arrow.down") { isImporting = true }
            Text("恢复前会检查版本、结构和校验值，再显示数据数量供你确认。若安全副本写入失败，恢复会停止。")
                .font(.caption).foregroundStyle(p.muted).padding(.vertical, 8)
        }.navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
            .fileExporter(isPresented: $isExporting, document: document, contentType: .json, defaultFilename: "观盘Max-安全备份") { result in
                if case .failure(let error) = result { model.errorMessage = "导出失败：\(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let envelope = try JSONDecoder().decode(NextArchiveEnvelope.self, from: Data(contentsOf: url))
                    let archive = try envelope.archive(); pending = envelope
                    restoreSummary = "\(archive.book.positions.count) 只持仓 · \(archive.book.fills.count + archive.book.cashMovements.count + archive.book.incomeEvents.count) 条资产流水 · \(archive.audits.count) 条审计记录"
                    confirmRestore = true
                } catch { model.errorMessage = "备份没有通过校验，未修改账本：\(error.localizedDescription)" }
            }
            .confirmationDialog("确认恢复此备份？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("备份当前数据并恢复", role: .destructive) {
                    guard let pending else { return }
                    do { try model.restoreBackup(pending); self.pending = nil }
                    catch { model.errorMessage = "恢复已停止，当前数据仍保留：\(error.localizedDescription)" }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: { Text("\(restoreSummary)。恢复前状态会生成独立本机安全副本。") }
    }
}

private struct IntentRow: View {
    @Environment(\.gp) private var p
    let icon: String; let title: String; let detail: String
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(p.forest).frame(width: 34); VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink); Text(detail).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true) }; Spacer(minLength: 6); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(p.muted) }.padding(.vertical, 10).contentShape(Rectangle()) }
}

private func compactField(_ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption2).foregroundStyle(.secondary); TextField(title, text: text).font(.subheadline).textFieldStyle(.roundedBorder).keyboardType(.decimalPad).submitLabel(.done) }.frame(maxWidth: .infinity) }
/// 名称解析：名称簿（跨启动记录的真实名称）→ 内置目录 → 代码本身。
/// 原来这里只有 4 条硬编码，其余一律返回「场内证券」，界面上就只剩代码可看。
private func knownName(_ code: String) -> String { NextNameBook.resolve(code) }


// MARK: - NAS 账本版本（可删除）

/// NAS 每接受一次账本写入就留一份完整历史版本。这里列出并允许删除旧版本。
/// 只删 NAS 上的历史副本，不动手机账本，也不动当前生效版本（服务端会 409）。
private struct NASBookVersionsPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var versions: [NextNASBookVersion] = []
    @State private var action: VersionAction?
    @State private var loading = false
    @State private var note = ""

    private enum VersionAction: Identifiable {
        case delete(NextNASBookVersion), prune
        var id: String {
            switch self { case .delete(let version): return "delete-\(version.revision)"; case .prune: return "prune" }
        }
    }

    private var baseURL: String { model.preferences.nasBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dialogTitle: String {
        switch action {
        case .delete(let version): return "删除 NAS 版本 \(version.revision)？"
        case .prune: return "只保留最近 20 个版本？"
        case nil: return ""
        }
    }
    private var dialogMessage: String {
        switch action {
        case .delete: return "只删除 NAS 上的这份历史副本，手机账本与当前 NAS 账本不受影响。"
        case .prune: return "会删除第 21 个及更早的版本，当前生效版本始终保留。"
        case nil: return ""
        }
    }

    var body: some View {
        EditorialSection(title: "NAS 备份版本",
                         trailing: baseURL.isEmpty ? "未配置" : (loading ? "读取中…" : "\(versions.count) 个"),
                         accent: p.chartGold) {
            if baseURL.isEmpty {
                Text("先在设置里填写 NAS 地址，才能管理服务端保存的账本版本。").font(.caption).foregroundStyle(p.muted)
            } else {
                if versions.isEmpty {
                    Text(loading ? "正在读取 NAS 版本…" : "NAS 上还没有保存过账本版本。同步一次账本后就会出现第一个版本。")
                        .font(.caption).foregroundStyle(p.muted)
                }
                ForEach(versions) { version in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("版本 \(version.revision)").font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                            Text(version.sizeText + (version.current ? " · 当前生效" : " · 历史版本"))
                                .font(.caption2).foregroundStyle(version.current ? p.jade : p.muted)
                        }
                        Spacer(minLength: 6)
                        if !version.current {
                            Button { action = .delete(version) } label: {
                                Image(systemName: "trash").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(p.risk.opacity(0.85)).frame(width: 32, height: 32)
                            }.buttonStyle(.plain).accessibilityLabel("删除版本 \(version.revision)")
                        }
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
                }
                HStack(spacing: 12) {
                    Button("只留最近 20 个") { action = .prune }.disabled(versions.count <= 20)
                    Button("重新读取") { Task { await reload() } }
                }.font(.caption.weight(.semibold)).tint(p.forest).padding(.top, 4)
                if !note.isEmpty { Text(note).font(.caption2).foregroundStyle(p.muted) }
                Text("每次同步账本，NAS 都会留一份完整版本。当前生效版本不能删；删除只影响 NAS 上的历史副本，不动手机账本。")
                    .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await reload() }
        .confirmationDialog(dialogTitle,
                            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
                            titleVisibility: .visible) {
            switch action {
            case .delete(let version):
                Button("删除版本 \(version.revision)", role: .destructive) {
                    Task { await remove(version) }
                    action = nil
                }
            case .prune:
                Button("清理旧版本", role: .destructive) {
                    Task { await prune() }
                    action = nil
                }
            case nil:
                EmptyView()
            }
            Button("取消", role: .cancel) { action = nil }
        } message: {
            Text(dialogMessage)
        }
    }

    private func reload() async {
        guard !baseURL.isEmpty else { return }
        loading = true
        do {
            let history = try await NextNASService.readBookHistory(baseURL: baseURL)
            versions = history.versions
            note = "当前生效版本 \(history.current)"
        } catch {
            versions = []
            note = error.localizedDescription
        }
        loading = false
    }

    private func remove(_ version: NextNASBookVersion) async {
        do {
            try await NextNASService.deleteBookVersion(version.revision, baseURL: baseURL)
            note = "已删除版本 \(version.revision)"
            await reload()
        } catch { note = error.localizedDescription }
    }

    private func prune() async {
        do {
            let removed = try await NextNASService.pruneBookHistory(keep: 20, baseURL: baseURL)
            note = removed > 0 ? "已清理 \(removed) 个旧版本" : "没有可清理的旧版本"
            await reload()
        } catch { note = error.localizedDescription }
    }
}


