import SwiftUI

private struct DataTrustQuoteRow: Identifiable {
    var code: String
    var name: String
    var timestamp: Date?
    var id: String { code }
}

/// Shows provenance and age of locally available data without inferring freshness from price values.
struct DataTrustView: View {
    @EnvironmentObject private var store: PortfolioStore
    @AppStorage(NASSyncService.automaticKey) private var nasAutoSync = false
    @AppStorage(NASSyncService.urlKey) private var nasURL = ""

    private var quoteRows: [DataTrustQuoteRow] {
        let holdingRows = store.data.holdings.filter { $0.kind == .etf }.map { holding in
            DataTrustQuoteRow(code: holding.code, name: holding.name,
                timestamp: holding.marketUpdatedAt ?? store.data.quotes.first(where: { $0.code == holding.code })?.updatedAt)
        }
        let watchRows = store.data.quotes.map { quote in
            DataTrustQuoteRow(code: quote.code, name: quote.name, timestamp: quote.updatedAt)
        }
        return Dictionary((holdingRows + watchRows).map { ($0.code, $0) }, uniquingKeysWith: { first, second in
            first.timestamp == nil ? second : first
        }).values.sorted { $0.name < $1.name }
    }

    private var activeFunds: [Holding] { store.data.holdings.filter { $0.kind == .fund && $0.quantity > 0 } }
    private var isRegularSession: Bool {
        let now = Date.now
        // 休市判断统一走 MarketCalendar：它优先用「上证指数日 K 反推的交易日历」，
        // 不再依赖那张写死的年度表，跨年和临时休市都能自动跟上。
        guard !MarketCalendar.isClosure(now, custom: store.data.customMarketHolidays) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return (570...690).contains(minute) || (780...900).contains(minute)
    }
    private var sessionDescription: String {
        let now = Date.now
        if MarketCalendar.isClosure(now, custom: store.data.customMarketHolidays) {
            return "休市日；显示的证券价格不会继续刷新。"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if (570...690).contains(minute) || (780...900).contains(minute) { return "沪深交易时段；以行情源时间戳确认报价是否及时。" }
        if (690..<780).contains(minute) { return "午间休市；当前报价可能是上午收盘价。" }
        return "非交易时段；报价通常是最近一次交易时段的数据。"
    }

    private var latestQuoteTime: Date? { quoteRows.compactMap(\.timestamp).max() }

    private var isLight: Bool { AppTheme.palette(for: store.appearance).isLight }
    /// 交易时段内超过 3 分钟没更新的报价条数（含「时间未知」）。
    private var staleCount: Int { quoteRows.filter { isStale($0.timestamp) }.count }

    var body: some View {
        NavigationStack {
            List {
                Section("行情更新时间") {
                    LabeledContent("交易时段", value: sessionDescription)
                    LabeledContent("刷新状态", value: store.sourceStatus)
                    LabeledContent("最近行情时间戳", value: latestQuoteTime.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "行情源未提供时间戳")
                    Button(store.isRefreshingQuotes ? "正在刷新行情…" : "手动刷新行情") { store.refreshQuotes() }
                        .disabled(store.isRefreshingQuotes)
                    if quoteRows.isEmpty {
                        Text("尚无自选或 ETF 行情记录。获取时间未知时不会把保存价格称作实时价。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(quoteRows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name)
                                Text(row.code).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ageLabel(row.timestamp))
                                .font(.caption).foregroundStyle(isStale(row.timestamp) ? .orange : .secondary)
                        }
                    }
                    Text("非交易时段会返回上一交易时段的收盘或最近报价。数据源没有给出时间戳时，原生版会标记未知时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(staleCount > 0 ? CardTone.warn : CardTone.ok, isLight: isLight)
                Section("场外基金已公布净值") {
                    if activeFunds.isEmpty { Text("没有当前场外基金持仓。").foregroundStyle(.secondary) }
                    Button(store.isRefreshingFunds ? "正在更新净值…" : "更新已公布净值") { store.refreshFundNAVs() }
                        .disabled(store.isRefreshingFunds)
                    Text(store.fundNAVStatus).font(.footnote).foregroundStyle(.secondary)
                    ForEach(activeFunds) { fund in
                        let point = store.data.fundNAVHistory.filter { $0.code == fund.code }.max { $0.date < $1.date }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(fund.name); Spacer(); Text(point?.date ?? "没有本地净值") }
                            Text(point.map { "最近公布净值 \(($0.nav).num(4))" } ?? "没有可用的历史净值")
                                .font(.caption).foregroundStyle(point == nil ? Color.orange : Color.secondary)
                        }
                    }
                    Text("这里展示已公布净值及日期，不含基金盘中估值。QDII 等海外资产净值可能有时差。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section("历史行情覆盖") {
                    LabeledContent("本机缓存日线", value: "\(store.dailyBars.values.reduce(0) { $0 + $1.count }) 条 · \(store.dailyBars.count) 个代码")
                    LabeledContent("本机永久分时", value: "\(store.gridBarCount) 点 · \(store.gridTradingDays.count) 个交易日")
                    Text("历史图表仅使用本机已有的行情缓存。缓存缺失的日期或品种不会用插值补齐。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
                Section("NAS 同步") {
                    LabeledContent("自动同步", value: nasAutoSync ? "已开启" : "已关闭")
                    LabeledContent("服务器地址", value: nasURL.isEmpty ? "未配置" : "已配置（地址已隐藏）")
                    Text(store.nasSyncStatus)
                    Text("NAS 免口令模式无需填写口令；若服务器主动启用 SYNC_TOKEN，口令会保存在本机钥匙串。同步状态按客户端最近结果显示；iOS 后台不会保证准时同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .plainCard(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("数据可信度")
        }
    }

    private func ageLabel(_ timestamp: Date?) -> String {
        guard let timestamp else { return "时间未知" }
        let seconds = Date.now.timeIntervalSince(timestamp)
        guard seconds >= 0 else { return "时间戳异常" }
        if seconds < 60 { return "\(Int(seconds)) 秒前" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    private func isStale(_ timestamp: Date?) -> Bool {
        guard let timestamp else { return true }
        return isRegularSession && Date.now.timeIntervalSince(timestamp) > 180
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
