import SwiftUI

/// Navigation only. Every retained business feature has one owning page and a contextual location.
/// Shortcuts elsewhere may open the same destination; there is no all-tools directory.
enum WorkspaceFeature: String, Identifiable, CaseIterable {
    case aiAnalysis, portrait, rules, tradePlans, tradePreview, addCash, portfolioScenario
    case quantEngine, intradayArchive, dataTrust
    case simulation, grid, longGridPlanner, gridReview
    case historicalReplay, allocationTargets, overlap, portfolioAnalysis
    case etfIncomeCalendar, dividendCalendar, returnSource, monthlyReview, yearlyReview
    case tradeCSVImport, tradeLedger, reconciliation, ledgerHealth
    var id: String { rawValue }
    var owner: PadTab {
        switch self {
        case .aiAnalysis, .portrait, .rules, .tradePlans, .tradePreview, .addCash, .portfolioScenario: return .decisions
        case .quantEngine, .intradayArchive, .dataTrust: return .market
        case .simulation, .grid, .longGridPlanner, .gridReview: return .laboratory
        default: return .assets
        }
    }
    var title: String {
        switch self {
        case .aiAnalysis: return "AI 账户分析"
        case .portrait: return "投资画像"
        case .rules: return "账户决策提示"
        case .tradePlans: return "交易计划"
        case .tradePreview: return "交易前沙盘"
        case .addCash: return "新增资金安排"
        case .portfolioScenario: return "换仓情景试算"
        case .quantEngine: return "技术信号扫描"
        case .intradayArchive: return "分时档案与采集"
        case .dataTrust: return "行情数据可信度"
        case .simulation: return "耐心限价模拟"
        case .grid: return "日内网格"
        case .longGridPlanner: return "中长期网格"
        case .gridReview: return "网格参数复盘"
        case .historicalReplay: return "历史资产回看"
        case .allocationTargets: return "目标仓位与偏离"
        case .overlap: return "ETF 成分重叠"
        case .portfolioAnalysis: return "持仓穿透与压力测试"
        case .etfIncomeCalendar: return "每日收益日历"
        case .dividendCalendar: return "分红日历"
        case .returnSource: return "收益来源拆解"
        case .monthlyReview: return "月度投资复盘"
        case .yearlyReview: return "年度账单"
        case .tradeCSVImport: return "导入券商成交"
        case .tradeLedger: return "交易流水"
        case .reconciliation: return "现金、成本与盈亏对账"
        case .ledgerHealth: return "账本体检"
        }
    }
    var icon: String {
        switch self {
        case .aiAnalysis, .portrait, .rules: return "sparkles"
        case .tradePlans, .tradePreview: return "checklist"
        case .addCash, .portfolioScenario, .allocationTargets: return "arrow.left.arrow.right"
        case .quantEngine: return "waveform.path.ecg"
        case .intradayArchive, .historicalReplay: return "clock.arrow.circlepath"
        case .dataTrust, .reconciliation, .ledgerHealth: return "checkmark.shield"
        case .simulation, .grid, .longGridPlanner, .gridReview: return "square.grid.3x3"
        case .overlap, .portfolioAnalysis: return "chart.pie"
        case .etfIncomeCalendar, .dividendCalendar, .monthlyReview, .yearlyReview: return "calendar"
        case .returnSource: return "chart.bar.xaxis"
        case .tradeCSVImport: return "square.and.arrow.down"
        case .tradeLedger: return "list.bullet.rectangle"
        }
    }
    var tone: Color {
        switch owner {
        case .decisions: return CardTone.accent
        case .market: return WorkspaceTone.blue
        case .laboratory: return WorkspaceTone.teal
        case .assets: return WorkspaceTone.coral
        case .overview: return WorkspaceTone.blue
        }
    }
}

/// A contextual action strip opens each feature directly, without a category menu in between.
struct WorkspaceFeatureActions: View {
    let features: [WorkspaceFeature]
    @State private var selected: WorkspaceFeature?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(features) { feature in
                    Button { selected = feature } label: {
                        Label(feature.title, systemImage: feature.icon)
                            .scaledFont(13, weight: .medium)
                            .foregroundStyle(feature.tone)
                            .padding(.horizontal, 14).frame(minHeight: AppLayout.minimumTapHeight)
                            .background(feature.tone.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(feature.tone.opacity(0.25), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 2)
        }.sheet(item: $selected) { WorkspaceFeatureDestination(feature: $0) }
    }
}

struct WorkspaceFeatureDestination: View {
    @EnvironmentObject private var store: PortfolioStore
    let feature: WorkspaceFeature
    var body: some View {
        Group {
            switch feature {
            case .aiAnalysis: AIAnalysisView()
            case .portrait: AccountPortraitView()
            case .rules: PortfolioAdviceView()
            case .tradePlans: TradePlansView()
            case .tradePreview: TradePreviewView()
            case .addCash: AddCashSimulationView()
            case .portfolioScenario: PortfolioScenarioView()
            case .quantEngine: QuantitativeEngineView()
            case .intradayArchive: IntradayArchiveView()
            case .dataTrust: DataTrustView()
            case .simulation: PaperTradingView()
            case .grid: DayGridView()
            case .longGridPlanner: StrategicGridPlannerView().environmentObject(store)
            case .gridReview: GridReviewView().environmentObject(store)
            case .historicalReplay: HistoricalReplayView()
            case .allocationTargets: AllocationTargetsView().environmentObject(store)
            case .overlap: ETFOverlapView()
            case .portfolioAnalysis: PortfolioAnalysisView()
            case .etfIncomeCalendar: ETFIncomeCalendarView()
            case .dividendCalendar: DividendCalendarView()
            case .returnSource: ReturnSourceView()
            case .monthlyReview: MonthlyReviewView()
            case .yearlyReview: YearlyReviewView()
            case .tradeCSVImport: TradeCSVImportView()
            case .tradeLedger: TradeLedgerManagementView()
            case .reconciliation: ReconciliationView()
            case .ledgerHealth: LedgerHealthView()
            }
        }.themedSheetBackground()
    }
}
