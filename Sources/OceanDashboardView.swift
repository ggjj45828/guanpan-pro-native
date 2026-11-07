import SwiftUI

// MARK: - 蓝海浅色专用首页
//
// 与 `DashboardView` 是两套独立版式，不复用同一个 body 换色：
//   · tech  DashboardView      ：ScrollView + LazyVStack 卡片流、超大 hero 数字、
//                                绿系 AI 渐变横条、隐藏导航栏 + 自绘问候栏。
//   · ocean OceanDashboardView ：List + Section 分组、系统大标题、2×2 数字网格、
//                                紧凑自选行、平铺工具行、蓝色 AI 卡、顶部工具栏。
// 数据口径完全共用 PortfolioStore / NewsCenter，不复制任何计算逻辑。

private struct OceanTool: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

struct OceanDashboardView: View {
    @EnvironmentObject var store: PortfolioStore
    @ObservedObject private var news = NewsCenter.shared

    @State private var showAdd = false
    @State private var showAdvice = false
    @State private var showGrid = false
    @State private var showIncome = false
    @State private var showLedger = false
    @State private var showNews = false
    @State private var chartTarget: Holding?

    var onOpenAssets: () -> Void = {}

    private var palette: DsPalette { .of(store.resolvedAppearance) }

    private let tools: [OceanTool] = [
        OceanTool(id: "grid", title: "网格", symbol: "square.grid.2x2"),
        OceanTool(id: "income", title: "收息", symbol: "yensign.circle"),
        OceanTool(id: "ledger", title: "账本", symbol: "book.closed"),
        OceanTool(id: "news", title: "快讯", symbol: "newspaper"),
        OceanTool(id: "add", title: "加自选", symbol: "plus")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("资产概览") { assetGrid }
                Section("市场脉搏") { indexStrip }
                Section("自选 · \(store.data.quotes.count)") { watchRows }
                Section("常用工具") { toolGrid }
                Section("AI 顾问") { aiRow }
                if !news.displayArticles.isEmpty {
                    Section("今日快讯") { newsRows }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .listSectionSpacing(.compact)
            .navigationTitle("观盘 Pro")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        store.refreshQuotes()
                        store.refreshIndexQuotes()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshingQuotes || store.isRefreshingIndices)
                    .accessibilityLabel("刷新行情")
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加自选")
                }
            }
            .refreshable {
                store.refreshQuotes()
                store.refreshIndexQuotes()
                try? await Task.sleep(for: .seconds(1))
            }
            .sheet(isPresented: $showAdd) { WatchEditor().themedSheetBackground() }
            .sheet(isPresented: $showAdvice) { PortfolioAdviceView().themedSheetBackground() }
            .sheet(isPresented: $showGrid) { DayGridView().themedSheetBackground() }
            .sheet(isPresented: $showIncome) { IncomeHubView().themedSheetBackground() }
            .sheet(isPresented: $showLedger) { LedgerAuditView().themedSheetBackground() }
            .sheet(isPresented: $showNews) { NewsHubView().themedSheetBackground() }
            .sheet(item: $chartTarget) { holding in
                MarketChartView(holding: holding).themedSheetBackground()
            }
            .task {
                await news.refresh()
                while !Task.isCancelled {
                    let interval = store.data.quoteRefreshSeconds
                    if interval > 0 {
                        store.refreshQuotes()
                        store.refreshIndexQuotes()
                    }
                    try? await Task.sleep(for: .seconds(interval > 0 ? interval : 60))
                }
            }
        }
    }

    // MARK: - 分组行外壳

    /// 浅色分组列表的行：小圆角白卡 + 淡投影 + 窄行距，和 tech 的描边大圆角卡不同。
    private func rowCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
                    .fill(palette.card)
                    .shadow(color: Color.black.opacity(palette.shadowOpacity),
                            radius: palette.shadowRadius, y: 2)
                    .padding(.vertical, 2)
            )
    }

    // MARK: - 资产概览：2×2 数字网格，不用 hero 大数字

    private var assetGrid: some View {
        let display = store.valuationDisplay
        let total = display.total > 0 ? display.total.cny() : "--"
        let dayValue = store.hasDayPnLGross ? store.dayPnLGross : 0
        let dayText = store.hasDayPnLGross
            ? "\(dayValue.directionMark())\(abs(dayValue).cny())" : "--"
        let dayTone = store.hasDayPnLGross ? PnLColor.of(dayValue) : palette.ink2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: palette.statColumns)
        return rowCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    Text("本机真实账本 · 人民币")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink2)
                    if !display.verified {
                        Text("缓存估算")
                            .scaledFont(palette.fsMicro, weight: .medium)
                            .foregroundStyle(PnLColor.down)
                    }
                    Spacer(minLength: 4)
                    Button {
                        Haptics.tap()
                        onOpenAssets()
                    } label: {
                        HStack(spacing: 2) {
                            Text("明细").scaledFont(palette.fsMicro)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    metric("总资产", total, palette.fsStat, display.verified ? palette.ink : palette.ink3)
                    metric("今日盈亏", dayText, palette.fsRow, dayTone)
                    metric("持仓市值", store.totalMarketValue.cny(), palette.fsRow, palette.ink)
                    metric("可用现金", store.data.cash.cny(), palette.fsRow, palette.ink)
                }
                if !display.caption.isEmpty {
                    Text(display.caption)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                        .lineLimit(2)
                }
            }
        }
    }

    private func metric(_ title: String,
                        _ value: String,
                        _ size: CGFloat,
                        _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink2)
            Text(value)
                .scaledFont(size, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.cardSoft)
        }
    }

    // MARK: - 市场脉搏 / 自选

    private var indexStrip: some View {
        rowCard {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.indexQuotes) { item in
                        indexChip(item)
                    }
                }
            }
        }
    }

    private func indexChip(_ item: MarketIndexQuote) -> some View {
        let tone = PnLColor.of(item.changePct)
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
            Text(item.price.num(3))
                .scaledFont(palette.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
            Text("\(item.changePct.directionMark()) \((item.changePct * 100).pct(2))")
                .scaledFont(palette.fsMicro, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.opacity(0.10))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var watchRows: some View {
        if store.data.quotes.isEmpty {
            rowCard {
                Text("还没有自选。点右上角 + 添加一只，行情会跟着自动刷新。")
                    .scaledFont(palette.fsLabel)
                    .foregroundStyle(palette.ink2)
            }
        } else {
            ForEach(Array(store.data.quotes.prefix(8))) { q in
                rowCard { watchRow(q) }
            }
        }
    }

    private func watchRow(_ q: Quote) -> some View {
        let tone = PnLColor.of(q.changePct)
        return Button {
            Haptics.tap()
            chartTarget = Holding(code: q.code, name: q.name, quantity: 0, cost: 0,
                                  current: q.price, kind: .etf, marketUpdatedAt: q.updatedAt)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.name.isEmpty ? q.code : q.name)
                        .scaledFont(palette.fsRow, weight: .medium)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(q.code)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(q.price > 0 ? q.price.num(3) : "--")
                        .scaledFont(palette.fsRow, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink)
                    Text("\(q.changePct.directionMark()) \((q.changePct * 100).pct(2))")
                        .scaledFont(palette.fsMicro, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(tone)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具 / AI / 快讯

    private var toolGrid: some View {
        rowCard {
            HStack(spacing: 2) {
                ForEach(Array(tools.prefix(palette.quickColumns))) { tool in
                    Button {
                        Haptics.tap()
                        perform(tool.id)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .frame(width: 32, height: 32)
                                .background { Circle().fill(palette.accentDim) }
                            Text(tool.title)
                                .scaledFont(palette.fsMicro)
                                .foregroundStyle(palette.ink2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                }
            }
        }
    }

    private var aiRow: some View {
        Button {
            Haptics.push()
            showAdvice = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(Color.white.opacity(0.22)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 组合顾问")
                        .scaledFont(palette.fsRow, weight: .semibold)
                        .foregroundStyle(.white)
                    Text(store.data.holdings.isEmpty
                         ? "先建立真实持仓，再给出组合判断"
                         : "读真实账本，给结论与风险，不下单")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
                    .fill(palette.aiGradient)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private var newsRows: some View {
        ForEach(Array(news.displayArticles.prefix(3))) { article in
            rowCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .scaledFont(palette.fsLabel, weight: .medium)
                        .foregroundStyle(palette.ink)
                        .lineLimit(2)
                    Text(article.publisher)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
            }
        }
    }

    private func perform(_ id: String) {
        switch id {
        case "grid": showGrid = true
        case "income": showIncome = true
        case "ledger": showLedger = true
        case "news": showNews = true
        case "add": showAdd = true
        default: break
        }
    }
}
