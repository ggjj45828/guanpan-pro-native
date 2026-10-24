import SwiftUI

private struct HomeAdvisorDecision: Identifiable {
    let symbol: String
    let name: String
    let action: String
    let reason: String
    let hasValidatedPlan: Bool
    let validUntil: Date?
    var id: String { symbol }
}

/// Five presentation compositions over one real portfolio and one advisor result.
struct VisualHomeView: View {
    @EnvironmentObject private var store: PortfolioStore
    @EnvironmentObject private var researchEngine: PhoneResearchEngine
    @EnvironmentObject private var channels: LabChannelCoordinator
    @Environment(\.visualTheme) private var theme
    @State private var guidance = "正在检查真实持仓…"
    @State private var decisions: [HomeAdvisorDecision] = []
    @State private var displayNow = Date.now
    private var tokens: DesignTokens { ThemeManager.tokens(theme) }
    private var holdings: [Holding] {
        store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }
            .sorted { $0.marketValue > $1.marketValue }
    }
    private var equity: Double { holdings.reduce(store.data.cash) { $0 + $1.marketValue } }
    private var importantPlan: HomeAdvisorDecision? {
        decisions.first { $0.hasValidatedPlan && ($0.validUntil ?? .distantPast) > displayNow }
    }
    private var headline: String {
        importantPlan.map { "\($0.name)：\($0.action)" }
            ?? (decisions.contains(where: { $0.hasValidatedPlan })
                ? "候选计划已过期，请刷新后再判断" : guidance)
    }
    private var nasResearchFresh: Bool {
        let now = Date.now.timeIntervalSince1970 * 1000
        guard let scannedAt = (channels.opportunityScan["at"] as? NSNumber)?.doubleValue else { return false }
        return scannedAt <= now && now - scannedAt <= 3 * 86_400_000
    }
    private var nasStatusText: String {
        if let scannedAt = (channels.opportunityScan["at"] as? NSNumber)?.doubleValue,
           scannedAt <= Date.now.timeIntervalSince1970 * 1000,
           Date.now.timeIntervalSince1970 * 1000 - scannedAt <= 3 * 86_400_000 {
            return "研究截至 " + Date(timeIntervalSince1970: scannedAt / 1000)
                .formatted(date: .omitted, time: .shortened)
        }
        if !channels.opportunityScan.isEmpty { return "研究已过期" }
        if channels.quant.text.contains("尚无机会扫描") { return "等待首次扫描" }
        if channels.quant.text.hasPrefix("暂停/离线") { return "离线" }
        return "待连接"
    }
    private var nasOnline: Bool {
        nasResearchFresh
    }
    private var relatedNewsCount: Int {
        let snapshot = (channels.marketDocument?["quality"] as? [String: Any])?["researchSnapshot"] as? [String: Any]
        let heldCodes = Set(holdings.map(\.code))
        let now = Date.now.timeIntervalSince1970 * 1000
        return (snapshot?["news"] as? [[String: Any]] ?? []).filter { item in
            guard let symbol = item["symbol"] as? String,
                  let at = (item["at"] as? NSNumber)?.doubleValue,
                  let available = (item["availableAt"] as? NSNumber)?.doubleValue else { return false }
            let affected = item["affectedSymbols"] as? [String] ?? []
            let mapped = heldCodes.contains(symbol) || (symbol == "MARKET" &&
                (item["eventScope"] as? String == "market" ||
                    (item["eventScope"] as? String == "industry" && !heldCodes.isDisjoint(with: affected))))
            return mapped && at <= available && available <= now
                && now - at <= 7 * 86_400_000
        }.count
    }
    private var newsSummary: String {
        relatedNewsCount > 0 ? "带来源的持仓事件 \(relatedNewsCount) 条" : "暂无带来源的关联事件"
    }
    private var mood: String {
        guard let value = store.marketMood?.average else { return "行情待更新" }
        let codes = Set(store.data.quotes.map(\.code) + store.data.holdings
            .filter { $0.kind == .etf }.map(\.code))
        let timestamps = codes.compactMap { code -> Date? in
            let quoteDate = store.data.quotes.first(where: { $0.code == code })?.updatedAt
            let holdingDate = store.data.holdings.first(where: { $0.code == code })?.marketUpdatedAt
            return [quoteDate, holdingDate].compactMap { $0 }.max()
        }
        guard timestamps.count == codes.count, let latest = timestamps.max() else { return "行情时间不明" }
        if timestamps.contains(where: { $0 > Date.now.addingTimeInterval(60) }) { return "行情时间异常" }
        if timestamps.contains(where: { Date.now.timeIntervalSince($0) > 15 * 60 }) {
            return "部分行情超时 · 最近更新 " + latest.formatted(date: .omitted, time: .shortened)
        }
        return MoodScale.label(value * 100)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.gap) {
                    switch theme {
                    case .eastern: easternHome
                    case .modern: modernHome
                    case .dashboard: dashboardHome
                    case .magazine: magazineHome
                    case .bento: bentoHome
                    case .scene: easternHome
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, tokens.pageInset)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .background(tokens.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { refreshGuidance() }
        .onChange(of: store.data.ledger.count) { _, _ in refreshGuidance() }
        .onChange(of: channels.market.revision) { _, _ in refreshGuidance() }
        .onChange(of: store.sourceStatus) { _, _ in refreshGuidance() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { time in
            displayNow = time
        }
    }

    private var easternHome: some View {
        Group {
            ZStack(alignment: .leading) {
                LandscapeDecoration(color: tokens.accent)
                    .frame(width: 172, height: 125)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 5) {
                    Text("早上好！").font(.system(size: 29, weight: .bold, design: .serif))
                    Text(Date.now.formatted(date: .long, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(importantPlan == nil ? "今天先观察真实持仓" : headline)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                }.padding(18)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 24))
            indexRow(includeNAS: true)
            heroCard
            featuredHoldings(vertical: true, illustrated: true)
            bottomEvidence
        }
    }

    private var modernHome: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("观盘").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("AI 私人投资顾问 · \(Date.now.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
            HStack(spacing: 8) {
                statusPill("今日机会", highlighted: true)
                statusPill("持仓总览", highlighted: false)
                statusPill("市场行情", highlighted: false)
            }
            heroCard
            indexRow(includeNAS: false)
            ThemePanel(tone: tokens.surface) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("我的持仓（\(holdings.count)）").font(.headline)
                        Text("总资产 \(equity.cny())").font(.subheadline)
                        Text("现金 \(store.data.cash.cny())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    allocationRing
                }
            }
            sectionTitle("机会雷达")
            featuredHoldings(vertical: true, illustrated: false)
            bottomEvidence
        }
    }

    private var dashboardHome: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 18) {
                    Text("市场").foregroundStyle(tokens.accent)
                    Text("持仓")
                    Text("AI").foregroundStyle(tokens.secondary)
                    Text("新闻")
                    Spacer()
                    Image(systemName: "magnifyingglass")
                }.font(.subheadline.weight(.semibold))
                Text(Date.now.formatted(date: .long, time: .omitted) + " · " + mood)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 10)
            indexRow(includeNAS: false)
            heroCard
            sectionTitle("重点机会")
            featuredHoldings(vertical: false, illustrated: false)
            sectionTitle("其他持仓")
            ForEach(Array(holdings.dropFirst(2))) { holding in
                compactHolding(holding)
            }
            bottomEvidence
        }
    }

    private var magazineHome: some View {
        Group {
            ZStack(alignment: .trailing) {
                LandscapeDecoration(color: tokens.accent)
                    .frame(width: 188, height: 115)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Text("观盘投资手册")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(tokens.secondary)
                    Text("AI 私人投资顾问").font(.caption).foregroundStyle(.secondary)
                    Text(Date.now.formatted(date: .long, time: .omitted))
                        .font(.caption.weight(.semibold))
                        .padding(.top, 6)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 120)
            ThemePanel(tone: tokens.hero) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("今日市场观察", systemImage: "sun.max.fill").font(.headline)
                    Text("市场 \(mood)。\(newsSummary)。")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
            heroCard
            indexRow(includeNAS: false)
            sectionTitle("今日重点机会")
            featuredHoldings(vertical: true, illustrated: true)
            bottomEvidence
        }
    }

    private var bentoHome: some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text("观盘").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("AI 私人投资顾问").font(.caption).foregroundStyle(.secondary)
                Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.bottom, 5)
            HStack(alignment: .top, spacing: tokens.gap) {
                NavigationLink { LabResearchView() } label: {
                    mosaicTile("AI 今日指导", detail: headline, icon: "sun.max.fill",
                        color: Color(red: 1, green: 0.85, blue: 0.45))
                }
                ThemePanel(tone: Color(red: 0.97, green: 0.76, blue: 0.88)) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("市场状态").font(.headline)
                        Text(mood).font(.title3.weight(.bold))
                        Text("真实行情").font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
                }
            }
            let pairs = Array(holdings.prefix(4)).chunked(into: 2)
            ForEach(pairs.indices, id: \.self) { index in
                let pair = pairs[index]
                HStack(alignment: .top, spacing: tokens.gap) {
                    ForEach(pair) { holding in
                        NavigationLink { ProHoldingWorkspace(holding: holding) } label: {
                            mosaicHolding(holding)
                        }
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
            HStack(alignment: .top, spacing: tokens.gap) {
                NavigationLink { LabResearchView() } label: {
                    evidenceTile("新闻事件", detail: newsSummary, icon: "newspaper",
                        color: Color(red: 0.89, green: 0.83, blue: 1))
                }.buttonStyle(.plain)
                evidenceTile("NAS 状态", detail: nasStatusText,
                    icon: "externaldrive", color: Color(red: 0.78, green: 0.95, blue: 0.86))
                evidenceTile("持仓总览", detail: "\(holdings.count) 只",
                    icon: "square.stack.3d.up", color: Color(red: 0.78, green: 0.88, blue: 1))
            }
            indexRow(includeNAS: false)
        }
    }

    private var heroCard: some View {
        let colors: [Color] = {
            switch theme {
            case .eastern: return [Color(red: 1, green: 0.88, blue: 0.60), Color(red: 1, green: 0.94, blue: 0.79)]
            case .modern: return [Color(red: 0.00, green: 0.66, blue: 0.84), Color(red: 0.26, green: 0.28, blue: 0.88)]
            case .dashboard: return [Color(red: 0.25, green: 0.32, blue: 0.85), Color(red: 0.38, green: 0.21, blue: 0.55)]
            case .magazine: return [Color(red: 1, green: 0.92, blue: 0.84), Color(red: 1, green: 0.98, blue: 0.93)]
            case .bento, .scene: return [tokens.hero, tokens.hero]
            }
        }()
        return NavigationLink { LabResearchView() } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("AI 今日指导", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                }
                Text(headline)
                    .font(.system(size: theme == .dashboard ? 20 : 18, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(importantPlan?.reason ?? "没有通过数据质量与成本校验的候选限价计划时，先继续观察。")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("查看依据、风险与数据时效  →").font(.caption.weight(.semibold))
            }
            .foregroundStyle(theme == .modern || theme == .dashboard ? .white : .primary)
            .padding(theme == .eastern ? 20 : 17)
            .frame(maxWidth: .infinity, minHeight: theme == .eastern ? 165 : 142, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: tokens.corner))
            .overlay(RoundedRectangle(cornerRadius: tokens.corner)
                .strokeBorder(tokens.accent.opacity(0.3), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func indexRow(includeNAS: Bool) -> some View {
        HStack(alignment: .top, spacing: theme == .bento ? 6 : 8) {
            ForEach(Array(store.indexQuotes.prefix(3))) { quote in
                NavigationLink { IndexDetailView(index: quote) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(quote.name).font(.caption2.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(quote.price.num(2))
                            .font(.subheadline.weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                        Text((quote.changePct * 100).pct(2))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(changeColor(quote.changePct))
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(quote.updatedAt.map {
                            Date.now.timeIntervalSince($0) > 900
                                ? "截至 \($0.formatted(date: .omitted, time: .shortened))"
                                : "最近更新"
                        } ?? "时间不明")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: theme == .dashboard ? 73 : 68, alignment: .topLeading)
                    .padding(9)
                    .background(tokens.surface, in: RoundedRectangle(cornerRadius: theme == .dashboard ? 10 : 13))
                }.buttonStyle(.plain).frame(maxWidth: .infinity)
            }
            if store.indexQuotes.isEmpty {
                Text("指数行情待更新").font(.caption).frame(maxWidth: .infinity, minHeight: 66)
                    .background(tokens.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            if includeNAS {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NAS").font(.caption2.weight(.semibold))
                    Text(nasStatusText).font(.caption.weight(.bold))
                        .foregroundStyle(nasOnline ? Color.green : Color.orange)
                }
                .frame(maxWidth: .infinity, minHeight: theme == .dashboard ? 73 : 68, alignment: .topLeading)
                .padding(9)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 13))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func featuredHoldings(vertical: Bool, illustrated: Bool) -> some View {
        Group {
            if holdings.isEmpty {
                ThemePanel {
                    Text("尚无真实 ETF 持仓。添加持仓后，这里会按实际行情展示。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if vertical {
                ForEach(Array(holdings.prefix(3))) { holding in
                    NavigationLink { ProHoldingWorkspace(holding: holding) } label: {
                        holdingPanel(holding, illustrated: illustrated)
                    }.buttonStyle(.plain)
                }
            } else {
                Grid(horizontalSpacing: tokens.gap) {
                    GridRow {
                        ForEach(Array(holdings.prefix(2))) { holding in
                            NavigationLink { ProHoldingWorkspace(holding: holding) } label: {
                                holdingPanel(holding, illustrated: false)
                            }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func holdingPanel(_ holding: Holding, illustrated: Bool) -> some View {
        let decision = decisions.first { $0.symbol == holding.code }
        let change = store.data.quotes.first { $0.code == holding.code }?.changePct
        let color = holdingColor(holding)
        let rounded = RoundedRectangle(cornerRadius: tokens.corner, style: .continuous)
        return ZStack(alignment: .trailing) {
            if illustrated { LandscapeDecoration(color: color).frame(height: 145).opacity(0.09).allowsHitTesting(false) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holding.name).font(.subheadline.weight(.bold))
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .frame(minHeight: 35, alignment: .topLeading)
                        Text(holding.code).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 2)
                    Text(displayAction(decision))
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(color.opacity(0.18), in: Capsule())
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(holding.current.num(3))
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                    if let change {
                        Text((change * 100).pct(2)).font(.caption.weight(.bold))
                            .foregroundStyle(changeColor(change))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Text(decision?.hasValidatedPlan == true && (decision?.validUntil ?? .distantPast) <= displayNow
                    ? "原候选已过期，需重新核对行情与盘口" : (decision?.reason ?? "等待真实行情与历史数据"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(holding.marketUpdatedAt.map {
                    "行情截至 \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "行情时间待核实")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: illustrated ? 120 : 112, alignment: .leading)
            .padding(14)
        }
        .background(color.opacity(theme == .dashboard ? 0.17 : 0.10), in: rounded)
        .overlay(rounded.strokeBorder(color.opacity(0.25), lineWidth: 1))
        .clipShape(rounded)
    }

    private func compactHolding(_ holding: Holding) -> some View {
        NavigationLink { ProHoldingWorkspace(holding: holding) } label: {
            HStack {
                Text(holding.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(holding.current.num(3)).font(.subheadline.monospacedDigit())
                Text(displayAction(decisions.first { $0.symbol == holding.code }))
                    .font(.caption2).foregroundStyle(tokens.secondary)
            }.padding(12)
                .background(tokens.surface, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private var allocationRing: some View {
        let invested = holdings.reduce(0) { $0 + $1.marketValue }
        let ratio = equity > 0 ? invested / equity : 0
        return ZStack {
            Circle().stroke(tokens.accent.opacity(0.15), lineWidth: 9)
            Circle().trim(from: 0, to: min(1, max(0, ratio)))
                .stroke(tokens.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text((ratio * 100).num(0) + "%")
                .font(.caption.weight(.bold)).monospacedDigit()
        }.frame(width: 66, height: 66)
    }

    private func statusPill(_ title: String, highlighted: Bool) -> some View {
        Text(title).font(.caption.weight(.semibold))
            .foregroundStyle(highlighted ? .white : tokens.accent)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(highlighted ? tokens.accent : tokens.surface, in: Capsule())
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(theme == .magazine ? .title3.weight(.bold) : .headline)
            .padding(.top, theme == .magazine ? 7 : 3)
    }

    private var bottomEvidence: some View {
        HStack(alignment: .top, spacing: tokens.gap) {
            evidenceTile("NAS 长期研究", detail: nasStatusText,
                icon: "externaldrive", color: tokens.secondary.opacity(0.2))
            NavigationLink { LabResearchView() } label: {
                evidenceTile("新闻与事件", detail: newsSummary,
                    icon: "newspaper", color: tokens.accent.opacity(0.16))
            }.buttonStyle(.plain)
        }
    }

    private func evidenceTile(_ title: String, detail: String, icon: String, color: Color) -> some View {
        ThemePanel(tone: color) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon).font(.subheadline.weight(.semibold))
                Text(title).font(.caption.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 63, alignment: .leading)
        }
    }

    private func mosaicTile(_ title: String, detail: String, icon: String, color: Color) -> some View {
        ThemePanel(tone: color) {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: icon).font(.subheadline.weight(.bold))
                Text(detail).font(.caption)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
        }
    }

    private func mosaicHolding(_ holding: Holding) -> some View {
        let change = store.data.quotes.first { $0.code == holding.code }?.changePct
        let color = holdingColor(holding)
        return ThemePanel(tone: color.opacity(0.22)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(holding.name).font(.caption.weight(.bold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(holding.current.num(3)).font(.title3.weight(.bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(change.map { ($0 * 100).pct(2) } ?? "行情待更新")
                    .font(.caption).foregroundStyle(change.map(changeColor) ?? .secondary)
                Spacer(minLength: 4)
                Text(decisions.first { $0.symbol == holding.code }?.action ?? "待分析")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(color.opacity(0.20), in: Capsule())
            }.frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        }
    }

    private func holdingColor(_ holding: Holding) -> Color {
        let palette: [Color] = [.blue, .green, .purple, .orange, .pink]
        let index = holding.code.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[index]
    }
    private func displayAction(_ decision: HomeAdvisorDecision?) -> String {
        guard let decision else { return "待分析" }
        return decision.hasValidatedPlan && (decision.validUntil ?? .distantPast) <= displayNow
            ? "已过期" : decision.action
    }

    private func changeColor(_ value: Double) -> Color {
        value > 0 ? PnLColor.up : value < 0 ? PnLColor.down : .secondary
    }

    private func refreshGuidance() {
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let input = try ResearchInputBuilder.make(portfolio: store, channels: channels, at: now)
            let context = try researchEngine.call("research.decisionContext", [input, now]) as? [String: Any] ?? [:]
            guidance = context["todayStatus"] as? String ?? "当前不建议交易"
            decisions = (context["decisions"] as? [[String: Any]] ?? []).compactMap { row in
                guard let symbol = row["symbol"] as? String else { return nil }
                return HomeAdvisorDecision(symbol: symbol, name: row["name"] as? String ?? symbol,
                    action: row["action"] as? String ?? "不交易",
                    reason: row["reason"] as? String ?? "证据不足",
                    hasValidatedPlan: row["plan"] is [String: Any],
                    validUntil: ((row["plan"] as? [String: Any])?["validUntil"] as? NSNumber)
                        .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
            }
        } catch {
            guidance = "数据不足，暂无法形成可靠指导"
            decisions = []
        }
    }
}

private extension Array {
    func chunked(into count: Int) -> [[Element]] {
        guard count > 0 else { return [] }
        return stride(from: 0, to: self.count, by: count).map {
            Array(self[$0..<Swift.min($0 + count, self.count)])
        }
    }
}
