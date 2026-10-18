import SwiftUI

struct ProOverviewView: View {
    @EnvironmentObject private var store: PortfolioStore
    var body: some View {
        NavigationStack {
            List {
                Section("场内账户总览") {
                    LabeledContent("现金", value: store.data.cash.cny())
                    LabeledContent("场内持仓市值", value: store.marketValue(of: .etf).cny())
                    LabeledContent("场内资产与现金", value: (store.marketValue(of: .etf) + store.data.cash).cny())
                    Text("场外历史不进入此处当前场内统计；原始账本和历史快照保留原口径。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("投资与复盘") {
                    NavigationLink("投资数字孪生与独立虚拟账户") { InvestmentLabView() }
                    NavigationLink("风险与目标仓位") { PortfolioAdviceView() }
                    NavigationLink("原有工具与设置") { MoreHubView() }
                    NavigationLink("场外历史只读归档") { ReadOnlyFundArchiveView() }
                }
                Section("数据状态") {
                    Text(store.sourceStatus)
                    Text(store.historicalArchiveStatus).font(.caption)
                    Text("真实交易由你决定。模拟账户不会改变此处现金和持仓。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden).background(.clear)
            .navigationTitle("总览")
        }
    }
}

struct ProDecisionHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showAI = false
    @State private var showQuant = false
    var body: some View {
        NavigationStack {
            List {
                Section("私人投资顾问") {
                    NavigationLink("离线研究、风险与未来资金安排") { LabResearchView() }
                    Button("使用已配置模型研究账户") { showAI = true }
                    Text("模型研究由你主动发起；现金不足也可研究目标配置。不会自动执行真实交易。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("长期目标仓位") { AllocationTargetsView() }
                }
                Section("行情与决策") {
                    Button("原有技术扫描与分析") { showQuant = true }
                    NavigationLink("决策记录、压力测试与策略对照") { InvestmentLabView() }
                }
            }
            .scrollContentBackground(.hidden).background(.clear).navigationTitle("AI 决策")
            .sheet(isPresented: $showAI) { AIAnalysisView().themedSheetBackground() }
            .sheet(isPresented: $showQuant) { QuantitativeEngineView().themedSheetBackground() }
        }
    }
}

struct ProAssetsHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var showHoldings = false
    @State private var showStatistics = false
    var body: some View {
        NavigationStack {
            List {
                Section("ETF / 股票与现金") {
                    LabeledContent("现金", value: store.data.cash.cny())
                    LabeledContent("场内持仓市值", value: store.marketValue(of: .etf).cny())
                    Button("查看与管理场内持仓") { showHoldings = true }
                    Button("历史资产、快照和资金流水") { showStatistics = true }
                }
                Section("场外历史") {
                    NavigationLink("已停止业务 · 查看只读记录") { ReadOnlyFundArchiveView() }
                    Text(store.historicalArchiveStatus).font(.caption)
                }
                Section("应用与同步") { NavigationLink("工具、备份、主题及设置") { MoreHubView() } }
                Section("真实资产独立通道") { NavigationLink("预览、上传与备份后接收（手动）") { ManualAssetChannelView() } }
            }
            .scrollContentBackground(.hidden).background(.clear).navigationTitle("资产")
            .sheet(isPresented: $showHoldings) { HoldingsView(kind: .etf).themedSheetBackground() }
            .sheet(isPresented: $showStatistics) { AssetsView().themedSheetBackground() }
        }
    }
}

struct ReadOnlyFundArchiveView: View {
    @EnvironmentObject private var store: PortfolioStore
    @State private var export = ""
    var body: some View {
        List {
            Section("业务已停止 · 历史只读") {
                Text(store.historicalArchiveStatus)
                Text("原持仓、成本、份额、流水、净值和定投历史均保留。此页不提供申赎、分红登记、定投执行或删除。")
                    .font(.caption).foregroundStyle(.secondary)
                if !export.isEmpty { ShareLink("导出完整原账本副本", item: export) }
            }
            Section("原场外持仓") {
                ForEach(store.data.holdings.filter { $0.kind == .fund }) { h in
                    VStack(alignment: .leading) {
                        Text("\(h.name) · \(h.code)")
                        Text("历史份额 \(h.quantity.num(4)) · 原单位成本 \(h.cost.num(4))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("历史记录数量") {
                LabeledContent("基金流水", value: String(store.data.fundTransactions.count))
                LabeledContent("历史净值", value: String(store.data.fundNAVHistory.count))
                LabeledContent("原定投安排（不再执行）", value: String(store.data.fundDCAPlans.count))
            }
        }
        .scrollContentBackground(.hidden).background(.clear).navigationTitle("场外历史归档")
        .task {
            do {
                let bytes = try JSONEncoder().encode(store.data)
                _ = try HistoricalFundArchive.preserve(bytes)
                export = String(decoding: bytes, as: UTF8.self)
            } catch { export = "" }
        }
    }
}
