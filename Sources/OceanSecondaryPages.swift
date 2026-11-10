import SwiftUI

// MARK: - 蓝海浅色的次级页面骨架
//
// 用户明确要求「每个主题布局不一样很正常，各自做」。所以这里不是给
// `HoldingsView` / `AssetsView` / `MoreHubView` 换圆角，而是另写三套：
//   · tech  ：大圆角浮起卡片、hero 大数字、九宫格工具砖、自绘小标题。
//   · ocean ：系统大标题 + List/Form 分组、紧凑表格行、2/3 列数字网格、
//             每行一枚小图标的平铺菜单，Section 之间留出系统分组间距。
// 两套共用同一个 `PortfolioStore` 与同一批业务页（编辑器、图表、复盘），
// 只是「怎么组织信息」不同；弹窗一律用单一 enum 驱动，避免同视图多 sheet
// 只有最后一个生效的老问题。

// MARK: - 共用行壳

extension View {
    /// ocean 分组列表里的行：小圆角白卡 + 淡投影 + 窄行距。
    /// 与 `OceanDashboardView.rowCard` 同一套修饰符，抽出来给次级页复用。
    func oceanSectionRow(_ palette: DsPalette) -> some View {
        self
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
}

/// ocean 的数字格：标签在上、等宽数字在下，不用 tech 那种超大 hero。
private struct OceanMetric: View {
    let palette: DsPalette
    let title: String
    let value: String
    var tone: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
            Text(value)
                .scaledFont(palette.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tone ?? palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.cardSoft)
        }
    }
}

/// 一组数字格；列数取主题的 `statColumns`。
private struct OceanMetricGroup: View {
    let palette: DsPalette
    let cells: [OceanMetricCell]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                            count: palette.statColumns)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(cells) { cell in
                OceanMetric(palette: palette, title: cell.title,
                            value: cell.value, tone: cell.tone)
            }
        }
    }
}

private struct OceanMetricCell: Identifiable {
    let id: String
    let title: String
    let value: String
    var tone: Color? = nil

    init(_ id: String, _ title: String, _ value: String, tone: Color? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.tone = tone
    }
}

// MARK: - 持仓（ocean）

private enum OceanHoldingsSheet: Identifiable {
    case chart(Holding)
    case fullEditor

    var id: String {
        switch self {
        case .chart(let holding): return "chart-" + holding.id
        case .fullEditor: return "full-editor"
        }
    }
}

struct OceanHoldingsView: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var sheetTarget: OceanHoldingsSheet?

    private var palette: DsPalette { .of(store.resolvedAppearance) }

    private var etfHoldings: [Holding] { store.data.holdings.filter { $0.kind == .etf } }

    var body: some View {
        NavigationStack {
            List {
                Section("持仓汇总") {
                    OceanMetricGroup(palette: palette, cells: [
                        OceanMetricCell("etf", "场内市值", store.marketValue(of: .etf).cny()),
                        OceanMetricCell("pnl", "持仓浮盈", store.totalPnL.cny(),
                                        tone: PnLColor.of(store.totalPnL)),
                        OceanMetricCell("position", "仓位", store.positionPercent.pct(1))
                    ])
                    .oceanSectionRow(palette)
                }
                Section("编辑") {
                    // 原来这一行放在列表最后：内容一多就落到 tab bar 底下，
                    // 只有「过度滚动」才看得到，松手又弹回去（截图反馈的正是这个）。
                    // 编辑是高频入口，提到汇总卡下面；底部再留一段滚动余量兜底。
                    Button {
                        Haptics.push()
                        sheetTarget = .fullEditor
                    } label: {
                        Label("打开完整持仓编辑（成交 / 分红 / 网格）",
                              systemImage: "square.and.pencil")
                            .scaledFont(palette.fsLabel)
                    }
                    .oceanSectionRow(palette)
                }
                Section("场内 ETF · \(etfHoldings.count)") {
                    ForEach(etfHoldings) { holding in
                        Button {
                            Haptics.tap()
                            sheetTarget = .chart(holding)
                        } label: {
                            holdingRow(holding)
                        }
                        .buttonStyle(.plain)
                        .oceanSectionRow(palette)
                    }
                    if etfHoldings.isEmpty { emptyRow("还没有场内持仓") }
                }
                Section("自选行情 · \(store.data.quotes.count)") {
                    ForEach(Array(store.data.quotes.prefix(8))) { quote in
                        Button {
                            Haptics.tap()
                            sheetTarget = .chart(Holding(code: quote.code, name: quote.name,
                                                         quantity: 0, cost: 0, current: quote.price,
                                                         kind: .etf, marketUpdatedAt: quote.updatedAt))
                        } label: {
                            quoteRow(quote)
                        }
                        .buttonStyle(.plain)
                        .oceanSectionRow(palette)
                    }
                    if store.data.quotes.isEmpty { emptyRow("还没有自选") }
                }
            }
            .listStyle(.grouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(.clear)
            // 底部给 tab bar 再让一段：内容刚好一屏多一点时，
            // 最后一行会卡在底栏后面，松手就回弹。
            .contentMargins(.bottom, 28, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("持仓")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        store.refreshQuotes()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshingQuotes)
                    .accessibilityLabel("刷新行情")
                }
            }
            .refreshable {
                store.refreshQuotes()
                try? await Task.sleep(for: .seconds(1))
            }
            .sheet(item: $sheetTarget) { target in
                switch target {
                case .chart(let holding):
                    MarketChartView(holding: holding).themedSheetBackground()
                case .fullEditor:
                    HoldingsView().themedSheetBackground()
                }
            }
        }
    }

    private func holdingRow(_ holding: Holding) -> some View {
        let pnl = store.holdingPnL(holding)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(holding.name.isEmpty ? holding.code : holding.name)
                    .scaledFont(palette.fsRow, weight: .medium)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text("\(holding.code) · \(holding.quantity.num(2)) 份 · 成本 \(holding.cost.num(3))")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(holding.marketValue.cny())
                    .scaledFont(palette.fsRow, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text("\(pnl.directionMark())\(abs(pnl).cny())")
                    .scaledFont(palette.fsMicro, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(PnLColor.of(pnl))
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private func quoteRow(_ quote: Quote) -> some View {
        let tone = PnLColor.of(quote.changePct)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.name.isEmpty ? quote.code : quote.name)
                    .scaledFont(palette.fsRow, weight: .medium)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(quote.code)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.price > 0 ? quote.price.num(3) : "--")
                    .scaledFont(palette.fsRow, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                Text("\(quote.changePct.directionMark()) \((quote.changePct * 100).pct(2))")
                    .scaledFont(palette.fsMicro, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(tone)
            }
        }
        .contentShape(Rectangle())
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .scaledFont(palette.fsLabel)
            .foregroundStyle(palette.ink2)
            .oceanSectionRow(palette)
    }
}

// MARK: - 资产（ocean）

private enum OceanAssetsSheet: Identifiable {
    case cashFlow
    case grid
    case income
    case ledger

    var id: String { String(describing: self) }
}

struct OceanAssetsView: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var sheetTarget: OceanAssetsSheet?

    private var palette: DsPalette { .of(store.resolvedAppearance) }

    private var dayText: String {
        store.hasDayPnLGross
            ? "\(store.dayPnLGross.directionMark())\(abs(store.dayPnLGross).cny())" : "--"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("资产总览") {
                    OceanMetricGroup(palette: palette, cells: [
                        OceanMetricCell("total", "总资产", store.totalAsset.cny()),
                        OceanMetricCell("market", "持仓市值", store.totalMarketValue.cny()),
                        OceanMetricCell("cash", "参考现金", store.data.cash.cny()),
                        OceanMetricCell("position", "仓位", store.positionPercent.pct(1)),
                        OceanMetricCell("pnl", "持仓浮盈", store.totalPnL.cny(),
                                        tone: PnLColor.of(store.totalPnL)),
                        OceanMetricCell("rate", "盈亏比例",
                                        store.totalPnLRate.map { $0.pct(2) } ?? "--",
                                        tone: PnLColor.of(store.totalPnL)),
                        OceanMetricCell("realized", "已实现盈亏", store.realizedPnL.cny(),
                                        tone: PnLColor.of(store.realizedPnL)),
                        OceanMetricCell("day", "当日盈亏", dayText,
                                        tone: store.hasDayPnLGross ? PnLColor.of(store.dayPnLGross) : nil)
                    ])
                    .oceanSectionRow(palette)
                    if !store.valuationDisplay.caption.isEmpty {
                        Text(store.valuationDisplay.caption)
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink3)
                            .oceanSectionRow(palette)
                    }
                }
                Section("资产构成") { compositionRow.oceanSectionRow(palette) }
                Section("常用工具") {
                    toolRow("网格试算", "square.grid.2x2", Color(hex: 0x2F5BE8), .grid).oceanSectionRow(palette)
                    toolRow("收息台账", "yensign.circle", Color(hex: 0x1E9E7A), .income).oceanSectionRow(palette)
                    toolRow("账本审计", "checklist", Color(hex: 0x8570F5), .ledger).oceanSectionRow(palette)
                }
                Section("现金流") {
                    Button {
                        Haptics.push()
                        sheetTarget = .cashFlow
                    } label: {
                        Label("记录现金转入 / 转出", systemImage: "plusminus.circle")
                            .scaledFont(palette.fsLabel)
                    }
                    .oceanSectionRow(palette)
                    Text("累计净转入只统计手动记录过的流水，不把持仓成本当现金流。")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                        .oceanSectionRow(palette)
                }
            }
            .listStyle(.grouped)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("资产")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $sheetTarget) { target in
                switch target {
                case .cashFlow: CashFlowEditor().themedSheetBackground()
                case .grid: DayGridView().themedSheetBackground()
                case .income: IncomeHubView().themedSheetBackground()
                case .ledger: LedgerAuditView().themedSheetBackground()
                }
            }
        }
    }

    private var compositionRow: some View {
        let etf = store.marketValue(of: .etf)
        let cash = store.data.cash
        let total = max(etf + cash, 0.000001)
        return VStack(alignment: .leading, spacing: 9) {
            // 按真实占比分配宽度，不用 scaleEffect 把等宽矩形压扁 ——
            // 那样画出来的比例是错的，属于「看起来像图其实在骗人」。
            GeometryReader { geo in
                HStack(spacing: 2) {
                    bar(geo.size.width * CGFloat(etf / total), Color(hex: 0x2F5BE8))
                    bar(geo.size.width * CGFloat(cash / total), Color(hex: 0x28B596))
                }
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                legend("ETF / 证券", etf, Color(hex: 0x2F5BE8))
                legend("现金", cash, Color(hex: 0x28B596))
            }
        }
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0, width - 2))
    }

    private func legend(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(value.cny())")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func toolRow(_ title: String, _ symbol: String, _ tint: Color, _ target: OceanAssetsSheet) -> some View {
        Button {
            Haptics.push()
            sheetTarget = target
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.13)) }
                Text(title)
                    .scaledFont(palette.fsRow, weight: .medium)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 我的（ocean）

private enum OceanMoreSheet: Identifiable {
    case aiAnalysis, quant, advice, newsHub, scorecard, episodes, expenses,
         marketState, analysisTools, planningTools, ledgerAudit,
         appSettings, dataSync, operationHistory

    var id: String { String(describing: self) }
}

private struct OceanMenuItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let target: OceanMoreSheet
}

private struct OceanMenuSection: Identifiable {
    let id: String
    let title: String
    let items: [OceanMenuItem]
}

struct OceanMoreView: View {
    @EnvironmentObject var store: PortfolioStore
    @State private var sheetTarget: OceanMoreSheet?

    private var palette: DsPalette { .of(store.resolvedAppearance) }

    private var sections: [OceanMenuSection] {
        [
            OceanMenuSection(id: "ai", title: "AI 与复盘", items: [
                OceanMenuItem(id: "ai", title: "AI 账户分析", subtitle: "大模型解读持仓、风险与待核对项",
                              symbol: "sparkles", tint: palette.accent, target: .aiAnalysis),
                OceanMenuItem(id: "quant", title: "量化信号", subtitle: "本地扫描自选与持仓",
                              symbol: "waveform.path.ecg", tint: Color(hex: 0x2FA4D8), target: .quant),
                OceanMenuItem(id: "advice", title: "账户决策提示", subtitle: "仓位上限与现金占比",
                              symbol: "lightbulb.fill", tint: Color(hex: 0xE89A2E), target: .advice),
                OceanMenuItem(id: "news", title: "市场快讯", subtitle: "公开接口，只给标题与来源",
                              symbol: "newspaper.fill", tint: Color(hex: 0x5C9EEB), target: .newsHub),
                OceanMenuItem(id: "scorecard", title: "决策成绩单", subtitle: "只用记录日之后的日线判对错",
                              symbol: "checkmark.seal.fill", tint: Color(hex: 0x5C9EEB), target: .scorecard),
                OceanMenuItem(id: "episodes", title: "持仓周期", subtitle: "几轮买卖、每轮战绩",
                              symbol: "arrow.triangle.2.circlepath", tint: Color(hex: 0x5CB89E), target: .episodes),
                OceanMenuItem(id: "expenses", title: "账户杂费", subtitle: "平台费与融资利息",
                              symbol: "creditcard.fill", tint: Color(hex: 0xD98552), target: .expenses),
                OceanMenuItem(id: "state", title: "市场状态与战绩", subtitle: "大盘状态、已实现与做 T",
                              symbol: "chart.xyaxis.line", tint: Color(hex: 0x8570F5), target: .marketState)
            ]),
            OceanMenuSection(id: "tools", title: "工具与设置", items: [
                OceanMenuItem(id: "analysis", title: "分析工具", subtitle: "风险、信号、账户体检",
                              symbol: "chart.bar.xaxis", tint: Color(hex: 0x2F5BE8), target: .analysisTools),
                OceanMenuItem(id: "planning", title: "计划与复盘", subtitle: "网格、收益、历史回看",
                              symbol: "calendar.badge.clock", tint: Color(hex: 0xE89A2E), target: .planningTools),
                OceanMenuItem(id: "ledger", title: "账本与审计", subtitle: "起点快照、现金对账",
                              symbol: "text.book.closed.fill", tint: Color(hex: 0x5C9EEB), target: .ledgerAudit),
                OceanMenuItem(id: "settings", title: "应用设置", subtitle: "主题、行情、成本口径",
                              symbol: "gearshape.fill", tint: Color(hex: 0x8A8A93), target: .appSettings),
                OceanMenuItem(id: "sync", title: "数据与同步", subtitle: "备份、NAS、通知权限",
                              symbol: "externaldrive.fill", tint: Color(hex: 0x9462E0), target: .dataSync),
                OceanMenuItem(id: "history", title: "操作记录", subtitle: "逐条改动、可撤回",
                              symbol: "clock.arrow.circlepath", tint: Color(hex: 0x66B880), target: .operationHistory)
            ])
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("账户") {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(palette.accentDim).frame(width: 38, height: 38)
                            Text("观")
                                .scaledFont(15, weight: .bold)
                                .foregroundStyle(palette.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("观盘 Pro")
                                .scaledFont(palette.fsRow, weight: .semibold)
                                .foregroundStyle(palette.ink)
                            Text("\(store.data.holdings.count) 只持仓 · 总资产 \(store.totalAsset.cny())")
                                .scaledFont(palette.fsMicro)
                                .foregroundStyle(palette.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text("本机")
                            .scaledFont(palette.fsMicro, weight: .semibold)
                            .foregroundStyle(palette.ink2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background { Capsule().fill(palette.cardSoft) }
                    }
                    .oceanSectionRow(palette)
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Button {
                                Haptics.push()
                                sheetTarget = item.target
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(item.tint)
                                        .frame(width: 30, height: 30)
                                        .background { Circle().fill(item.tint.opacity(0.12)) }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .scaledFont(palette.fsRow, weight: .medium)
                                            .foregroundStyle(palette.ink)
                                            .lineLimit(1)
                                        Text(item.subtitle)
                                            .scaledFont(palette.fsMicro)
                                            .foregroundStyle(palette.ink2)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(palette.ink3)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .oceanSectionRow(palette)
                        }
                    }
                }
                Section("账户状态") {
                    LabeledContent("自选", value: "\(store.data.quotes.count) 只")
                    LabeledContent("场内持仓", value: "\(store.data.holdings.filter { $0.kind == .etf }.count) 只")
                    Text(store.nasSyncStatus)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                    Text("本机记录与分析 · 不连接券商下单")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
            }
            .listStyle(.grouped)
            .listSectionSpacing(.default)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $sheetTarget) { target in
                switch target {
                case .aiAnalysis: AIAnalysisView(embedded: true)
                case .quant: QuantitativeEngineView(embedded: true)
                case .advice: PortfolioAdviceView(embedded: true)
                case .newsHub: NewsHubView(embedded: true)
                case .scorecard: DecisionScorecardView(embedded: true)
                case .episodes: EpisodeView(embedded: true)
                case .expenses: ExpenseView(embedded: true)
                case .marketState: MarketStateView(embedded: true)
                case .analysisTools:
                    ToolsView(initialAnchor: "tools-risk", title: "分析工具", embedded: true)
                case .planningTools:
                    ToolsView(initialAnchor: "tools-returns", title: "计划与复盘", embedded: true)
                case .ledgerAudit: LedgerAuditView(embedded: true)
                case .appSettings: SettingsView(mode: .app, embedded: true)
                case .dataSync: SettingsView(mode: .sync, embedded: true)
                case .operationHistory: OperationHistoryView(embedded: true)
                }
            }
        }
    }
}
