import SwiftUI

/// 三块本机规则面板：值不值得买 / 标的体检 / 账户诊断。
///
/// 全部做成**文件级 struct**，不要塞回 GuanpanAdvisorApp.swift 的页面 body 里 ——
/// 那个文件里的页面已经足够深，再嵌一层闭包会触发 SwiftUI 的类型检查超时，
/// 甚至让运行期的视图类型嵌套过深而闪退。

private enum RuleDateText {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func today() -> String { day.string(from: Date()) }
}

// MARK: - 值不值得买

struct WorthBuyPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let code: String
    @State private var assessment: NextWorthBuyAssessment?

    private var dataset: NextChartDataset? { model.chartData["\(code):day"] }
    private var quote: NextQuote? { model.quotes[code]?.quote }
    private var position: NextPosition? { model.book.positions.first { $0.code == code } }

    private var annualPerShare: Decimal {
        let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
        let today = RuleDateText.today()
        let recent = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: today)
        if recent > 0 { return recent }
        return NextDividendAnalytics.projectedAnnualPerShare(code: code, events: events, today: today)?.amount ?? 0
    }

    var body: some View {
        EditorialSection(title: "值不值得买", trailing: "本机规则打分", accent: p.terracotta) {
            if let assessment {
                WorthBuyScoreHeader(assessment: assessment)
                ScoreRadarChart(dimensions: assessment.dimensions)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Text("六维均值 \(Int(assessment.dimensionAverage.rounded()))")
                        .font(.caption.weight(.semibold)).foregroundStyle(p.terracotta)
                    Text("趋势 / 位置 / 估值 / 股息 / 仓位 / 流动性，越高越适合买入；灰色为数据不足按中性估的")
                        .font(.caption2).foregroundStyle(p.muted)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                ScoreRadarBreakdown(dimensions: assessment.dimensions)
                WorthBuyBreakdown(assessment: assessment)
                if let yield = assessment.dividendYieldPercent {
                    GPDataRow(title: "股息率（近 12 个月）",
                              value: NextNum.percent(yield),
                              note: "每份 ¥\(NextMoney.text(assessment.dividendPerShare ?? 0, digits: 3)) · " + (NextDividendRules.isOnExchangeETF(code) ? "ETF 按 IOPV 优先计算" : "按现价计算"))
                } else {
                    GPDataRow(title: "股息率", value: "无可用派息记录", note: "没有可核实的近 12 个月派息；本项按 0 分处理，不代表标的好坏")
                }
                if let position, let gap = assessment.costGapPercent {
                    GPDataRow(title: "相对账面成本", value: "\(NextNum.signed(gap))%",
                              note: "成本 ¥\(NextMoney.text(position.costPerUnit, digits: 3)) · 只作参考，不参与打分", valueColor: p.changeTone(NextNum.double(gap)))
                }
                ForEach(assessment.notes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                GPStatus(title: "日 K 不足，暂不打分",
                         detail: "本机已归档 \(dataset?.orderedSamples.count ?? 0) 根日 K，打分至少需要 20 根。切到「日K」会触发 NAS 拉取；离线时不会用分时数据冒充日线。",
                         symbol: "chart.bar.doc.horizontal")
            }
        }
        .onAppear { recompute() }
        .onChange(of: dataset?.observedAt) { _, _ in recompute() }
        .onChange(of: quote?.price) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func recompute() {
        guard let quote, quote.price > 0, let dataset else { assessment = nil; return }
        let total = NextNum.double(model.book.cash) + model.book.positions.reduce(0.0) { sum, item in
            guard let price = model.quotes[item.code]?.quote.price, price > 0 else { return sum }
            return sum + NextNum.double(price) * Double(item.units)
        }
        var weight: Double?
        if total > 0, let position {
            weight = NextNum.double(quote.price) * Double(position.units) / total * 100
        }
        assessment = NextWorthBuyEngine.evaluate(
            code: code, price: quote.price, previousClose: quote.previousClose,
            samples: dataset.orderedSamples, dividendPerShare: annualPerShare,
            iopv: quote.iopv, costPerUnit: position?.costPerUnit,
            weightPercent: weight, positionLimitPercent: NextNum.double(model.goal.concentrationLimit))
    }
}

private struct WorthBuyScoreHeader: View {
    @Environment(\.gp) private var p
    let assessment: NextWorthBuyAssessment
    private var tone: Color {
        switch assessment.action {
        case "可考虑": return p.risk
        case "等确认": return p.terracotta
        default: return p.jade
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(assessment.score)").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(assessment.action).font(.subheadline.weight(.semibold)).foregroundStyle(tone)
                Text("技术面基准 \(assessment.base) 分 · 加减 \(NextNum.signed(Double(assessment.totalAdjustment), digits: 0)) 分 · 日 K \(assessment.barCount) 根")
                    .font(.caption2).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WorthBuyBreakdown: View {
    @Environment(\.gp) private var p
    let assessment: NextWorthBuyAssessment
    var body: some View {
        VStack(spacing: 0) {
            ForEach(assessment.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.points == 0 ? "0" : NextNum.signed(Double(line.points), digits: 0))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(line.points > 0 ? p.risk : line.points < 0 ? p.jade : p.muted)
                        .frame(width: 26, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.caption.weight(.medium)).foregroundStyle(p.ink)
                        Text(line.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
            }
            HStack(spacing: 5) {
                Text("技术面").font(.caption.weight(.medium)).foregroundStyle(p.ink)
                Text("\(assessment.base)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(p.muted)
                Spacer(minLength: 0)
                ForEach(assessment.lines.prefix(3)) { line in
                    if line.points != 0 {
                        Text("\(line.title) \(NextNum.signed(Double(line.points), digits: 0))").font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
            }
            .padding(.top, 7)
        }
    }
}

// MARK: - 标的体检

struct GridCheckPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var checks: [NextGridCheck] = []
    @State private var expanded: String?

    private var codes: [String] {
        var seen = Set<String>()
        let ordered = model.book.positions.map(\.code) + model.watch
        return ordered.filter { seen.insert($0).inserted && NextGridCheckEngine.isTradableCode($0) }.prefix(10).map { $0 }
    }

    var body: some View {
        EditorialSection(title: "标的体检 · 网格适合度", trailing: "\(checks.count) 只", accent: p.chartViolet) {
            Text("按流动性、年化波动率、日均振幅、震荡性四条公开口径打分；只评价「价格结构适不适合网格/波段」，不判断涨跌方向。")
                .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if checks.isEmpty {
                GPStatus(title: "还没有可体检的标的", detail: "自选或持仓里的场内证券会自动出现在这里；需要本机至少 60 根日 K 才能给结论。", symbol: "stethoscope")
            }
            ForEach(checks) { check in
                GridCheckRow(check: check, isExpanded: expanded == check.code,
                             name: displayName(check.code)) {
                    expanded = expanded == check.code ? nil : check.code
                }
            }
            Button { recompute() } label: { Label("重新体检", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)) }
                .tint(p.forest)
        }
        .onAppear { recompute() }
        .onChange(of: model.chartData.count) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func displayName(_ code: String) -> String {
        model.book.positions.first(where: { $0.code == code })?.name
            ?? model.quotes[code]?.quote.name ?? code
    }

    private func recompute() {
        checks = codes.compactMap { code in
            guard let dataset = model.chartData["\(code):day"] else { return nil }
            return NextGridCheckEngine.evaluate(code: code, name: displayName(code),
                                               samples: dataset.orderedSamples, isOnExchange: true)
        }
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.code < rhs.code : lhs.score > rhs.score }
    }
}

private struct GridCheckRow: View {
    @Environment(\.gp) private var p
    let check: NextGridCheck
    let isExpanded: Bool
    let name: String
    let toggle: () -> Void
    private var tone: Color {
        switch check.grade {
        case .suitable: return p.risk
        case .consider: return p.terracotta
        case .avoid: return p.jade
        }
    }
    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                    Text(check.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                    Spacer(minLength: 4)
                    Text("\(check.score)").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
                    Text(check.grade.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(tone)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(tone.opacity(0.12), in: Capsule())
                }
                Text(metricLine).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                if isExpanded {
                    ForEach(check.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle").font(.caption2).foregroundStyle(p.jade)
                    }
                    ForEach(check.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(p.terracotta)
                    }
                    Text("数据：本机 \(check.barCount) 根日 K · 成交额按「量×100×收盘价」估算").font(.caption2).foregroundStyle(p.muted.opacity(0.8))
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
        .accessibilityLabel("\(name) 网格适合度 \(check.score) 分，\(check.grade.rawValue)")
    }
    private var metricLine: String {
        let volatility = check.annualVolatilityPercent.map { String(format: "波动 %.3f%%", $0) } ?? "波动 —"
        let amplitude = check.avgAmplitudePercent.map { String(format: "振幅 %.3f%%", $0) } ?? "振幅 —"
        let turnover = check.avgTurnoverYi.map { String(format: "成交 %.3f亿", $0) } ?? "成交 —"
        let range = check.rangeBoundRatio.map { String(format: "震荡 %.3f%%", $0 * 100) } ?? "震荡 —"
        return "\(volatility) · \(amplitude) · \(turnover) · \(range)"
    }
}

// MARK: - 账户诊断

struct AccountReviewPanel: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var review: NextAccountReview?

    var body: some View {
        EditorialSection(title: "账户诊断", trailing: "本机规则 · 不联网", accent: p.jade) {
            if let review {
                Text(review.headline).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(review.findings) { finding in
                    AccountFindingRow(finding: finding)
                }
                ForEach(review.footnotes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(p.muted.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                Button { recompute() } label: { Label("重新诊断", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.semibold)) }
                    .tint(p.forest)
            } else {
                GPStatus(title: "账本里还没有可分析的资产",
                         detail: "先录入持仓或现金，再生成账户诊断；诊断只看本机账本，不读取新闻和基本面。",
                         symbol: "doc.text.magnifyingglass")
            }
        }
        .onAppear { recompute() }
        .onChange(of: model.book.cash) { _, _ in recompute() }
        .onChange(of: model.book.positions.count) { _, _ in recompute() }
    }

    private func recompute() {
        let realized = model.book.fills.reduce(Decimal.zero) { $0 + $1.realized }
        review = NextAccountAdvisor.review(
            book: model.book, quotes: model.quotes.mapValues { $0.quote },
            concentrationLimitPercent: model.goal.concentrationLimit,
            targetWeights: model.goal.targetWeights,
            realizedTotal: realized)
    }
}

private struct AccountFindingRow: View {
    @Environment(\.gp) private var p
    let finding: NextAccountFinding
    private var tone: Color {
        switch finding.severity {
        case .act: return p.risk
        case .watch: return p.terracotta
        case .info: return p.forest
        }
    }
    private var symbol: String {
        switch finding.severity {
        case .act: return "exclamationmark.circle"
        case .watch: return "eye"
        case .info: return "info.circle"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tone).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                Text(finding.detail).font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
    }
}

// MARK: - 全球指数看板

/// 行情页顶部的指数条：上证、纳指100、日经、韩国、恒生科技。
/// 数据源与坑位说明见 `GlobalIndices.swift`；这里只负责显示，
/// 失败时如实写「取不到」，不拿缓存假装实时。
struct GlobalIndexStrip: View {
    @Environment(\.gp) private var p
    @State private var quotes: [GlobalIndexQuote] = []
    @State private var message = ""
    @State private var loading = false

    private var shown: [GlobalIndexQuote] {
        if !quotes.isEmpty { return quotes }
        return GlobalIndexFeed.catalog.map {
            GlobalIndexQuote(symbol: $0.symbol, name: $0.name, price: 0, changePercent: 0,
                             previousClose: nil, observedAt: nil, isStale: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Capsule().fill(p.chartViolet.opacity(0.85)).frame(width: 3, height: 12)
                Text("全球指数").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                if loading { ProgressView().scaleEffect(0.55).frame(width: 14, height: 14) }
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.forest)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("刷新全球指数")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(shown) { quote in
                        // 指数卡片以前只是纯展示，点了没有任何反应；现在整张卡都是一个导航入口。
                        NavigationLink(value: GPRoute.indexDetail(quote.symbol)) {
                            GlobalIndexCard(quote: quote)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("查看该指数走势")
                    }
                }
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 9)).foregroundStyle(p.muted)
            }
        }
        .padding(.vertical, 6)
        .task { if quotes.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let fresh = try await GlobalIndexFeed.fetch()
            quotes = fresh
            message = fresh.contains(where: \.isStale) ? "有指数为上一交易时段收盘价（已标注）" : ""
        } catch {
            message = "指数暂时取不到：\(error.localizedDescription)"
        }
    }
}

private struct GlobalIndexCard: View {
    @Environment(\.gp) private var p
    let quote: GlobalIndexQuote
    private var tone: Color {
        if quote.price <= 0 { return p.muted }
        return p.changeTone(NextNum.double(quote.changePercent))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(GlobalIndexFeed.shortName(quote.symbol)).font(.system(size: 10, weight: .medium)).foregroundStyle(p.ink).lineLimit(1)
                if quote.isStale { Text("旧").font(.system(size: 7, weight: .bold)).foregroundStyle(p.terracotta) }
            }
            Text(quote.price > 0 ? NextNum.text(quote.price) : "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(quote.price > 0 ? p.ink : p.muted)
            Text(quote.price > 0 ? "\(NextNum.signed(quote.changePercent))%" : "无报价")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(tone)
        }
        .frame(width: 92, height: 66, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            LinearGradient(colors: [p.paper, tone.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tone.opacity(0.22), lineWidth: 0.8))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(quote.name) \(quote.price > 0 ? NextNum.text(quote.price) : "无数据") \(quote.price > 0 ? NextNum.signed(quote.changePercent) + "%" : "")")
    }
}

// MARK: - 持仓行与修正

/// 资产页的持仓行：买入、卖出、修正份额/成本、删除都收进这一行的菜单里。
///
/// 关键点：**弹窗挂在这一行自己身上**。之前这些弹窗全挂在资产页根视图上，
/// 同一个页面上四个 `confirmationDialog` 互相压制，删除点下去没有反应。
struct PositionRow: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let position: NextPosition
    let quote: NextCachedQuote?
    @State private var sheet: RowSheet?
    @State private var confirmDelete = false

    private enum RowSheet: Identifiable {
        case trade(GPTradeRequest), edit
        var id: String {
            switch self {
            case .trade(let request): return "trade-\(request.id)"
            case .edit: return "edit"
            }
        }
    }

    private var validQuote: NextQuote? {
        guard let quote, quote.usableForDisplay(at: Date()) else { return nil }
        return quote.quote
    }
    private var marketValueText: String {
        guard let price = validQuote?.price else { return "—" }
        return "¥\(NextMoney.text(price * Decimal(position.units)))"
    }
    private var priceText: String {
        guard let price = validQuote?.price else { return "—" }
        return "¥\(NextMoney.text(price, digits: 3))"
    }
    private var isETF: Bool { NextDividendRules.isOnExchangeETF(position.code) }

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink(value: GPRoute.instrument(position.code)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text(position.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
                                GPPillBadge(text: isETF ? "ETF" : "股票", color: isETF ? p.jade : p.chartBlue)
                            }
                            Text("市值 \(marketValueText) · \(position.units) 份").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(priceText).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(p.ink)
                            if let change = validQuote?.changePercent {
                                Text("\(change >= 0 ? "+" : "")\(NextMoney.text(change, digits: 3))%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(p.changeTone(NextNum.double(change)))
                            }
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.leading, 2)
                    }
                    tagRow
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 0.8))
            }.buttonStyle(.plain)
            Menu {
                Button("记录买入", systemImage: "arrow.down.circle") { sheet = .trade(GPTradeRequest(code: position.code, side: "buy")) }
                Button("记录卖出", systemImage: "arrow.up.circle") { sheet = .trade(GPTradeRequest(code: position.code, side: "sell")) }
                Button("修正份额 / 成本", systemImage: "pencil") { sheet = .edit }
                Divider()
                Button("删除持仓", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(p.muted).frame(width: 38, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(position.name) 更多操作")
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .trade(let request): TradeEntrySheet(request: request)
            case .edit: PositionEditSheet(position: position)
            }
        }
        .confirmationDialog("确认删除 \(position.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除持仓", role: .destructive) {
                do { try model.deletePosition(position.code) } catch { model.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("会写入账本审计记录，可在「资产流水 → 撤销最近账本变更」回退。") }
    }
    /// 持仓行下方小标签：实时浮动盈亏 + 股息率（有数据才显示）。
    @ViewBuilder private var tagRow: some View {
        let price = quote?.quote.price
        let marketValue = price.map { $0 * Decimal(position.units) }
        let pnl = (marketValue ?? 0) - position.bookCost
        HStack(spacing: 8) {
            if let price, let marketValue, marketValue != 0 {
                Text("浮动 \(pnl >= 0 ? "+" : "")\(NextMoney.text(pnl))").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(p.changeTone(NextNum.double(pnl)))
            }
            if let yieldPct = dividendYieldPercent, yieldPct > 0 {
                Text("股息率 \(NextMoney.text(yieldPct, digits: 3))%").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(p.chartGold)
            }
            Spacer(minLength: 0)
        }.padding(.leading, 2)
    }
    /// 该持仓近 12 个月已核实每份派息 ÷ 现价 得到的股息率。
    private var dividendYieldPercent: Decimal? {
        guard let price = quote?.quote.price, price > 0 else { return nil }
        let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[position.code] ?? []))
        let per = NextDividendAnalytics.recentVerifiedPerShare(code: position.code, events: events, today: dividendTodayString())
        guard per > 0 else { return nil }
        return per / price * 100
    }
}

/// 修正录入错误的份额与总成本。只改账本事实，不产生成交、不动现金。
struct PositionEditSheet: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.dismiss) private var dismiss
    let position: NextPosition
    @State private var units = ""
    /// 每份成本（券商叫「买入均价」）。录入/修正都按单价填，合计成本由程序算，
    /// 这样不会被「总成本 ÷ 份数」的口径绕晕。
    @State private var perShareCost = ""
    @State private var error: String?
    @State private var confirm = false

    private var parsedUnits: Int? { Int(units) }
    private var parsedPerShare: Decimal? { try? NextMoney.parse(perShareCost) }
    private var totalCostValue: Decimal? {
        guard let parsedUnits, let parsedPerShare else { return nil }
        return parsedPerShare * Decimal(parsedUnits)
    }
    private var canSave: Bool {
        guard let parsedUnits, parsedUnits > 0, let parsedPerShare, parsedPerShare > 0 else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(position.name) · \(position.code)") {
                    TextField("持有份数", text: $units).keyboardType(.numberPad)
                    TextField("每份成本（元）", text: $perShareCost).keyboardType(.decimalPad)
                    Text("当前 \(position.units) 份 · 每份 ¥\(NextMoney.text(position.costPerUnit, digits: 3)) · 合计 ¥\(NextMoney.text(position.bookCost))")
                        .font(.caption).foregroundStyle(.secondary)
                    if canSave, let totalCostValue, let parsedUnits {
                        Text("修改后合计成本 ¥\(NextMoney.text(totalCostValue))（\(parsedUnits) 份 × ¥\(NextMoney.text(parsedPerShare ?? 0, digits: 3))）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("只订正账本里的份额与成本，不产生成交、不改现金；修改会写入审计记录并可撤销。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("修正持仓")
            .navigationBarTitleDisplayMode(.inline).gpKeyboardDismiss()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { confirm = true }.disabled(!canSave) }
            }
            .confirmationDialog("确认修正这条持仓？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认保存") {
                    do {
                        guard let parsedUnits, let totalCostValue else { throw NextError.invalid("份数或每份成本格式无效") }
                        try model.updatePosition(position.code, units: parsedUnits, totalCost: totalCostValue)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("\(position.code) 改为 \(units) 份 × 每份 ¥\(perShareCost) = 合计 ¥\(totalCostValue.map { NextMoney.text($0) } ?? "—")。") }
        }
        .onAppear {
            if units.isEmpty { units = String(position.units) }
            if perShareCost.isEmpty { perShareCost = NSDecimalNumber(decimal: position.costPerUnit).stringValue }
        }
    }
}


// MARK: - 值不值得买 · 总览（列表外层）

/// 总览项：评估结果本身不含代码，这里补上以便列表展示与跳转。
struct WorthOverviewItem: Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let assessment: NextWorthBuyAssessment
}

/// 自选 + 持仓一次全部打分，按分数降序。
/// 只用本机已归档的日 K（≥20 根），不联网、不预测；没日 K 的如实列进「待日K」。
/// 这样不用逐只点进去才能看到「值不值得买」。
struct WorthBuyOverviewScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @State private var items: [WorthOverviewItem] = []
    @State private var missing: [String] = []
    @State private var computing = true

    private var codes: [String] {
        model.watch + model.book.positions.map(\.code).filter { !model.watch.contains($0) }
    }
    private var portfolioTotal: Double {
        NextNum.double(model.book.cash) + model.book.positions.reduce(0.0) { sum, item in
            guard let price = model.quotes[item.code]?.quote.price, price > 0 else { return sum }
            return sum + NextNum.double(price) * Double(item.units)
        }
    }
    private var counts: (buy: Int, wait: Int, hold: Int) {
        var buy = 0, wait = 0, hold = 0
        for item in items {
            switch item.assessment.action {
            case "可考虑": buy += 1
            case "等确认": wait += 1
            default: hold += 1
            }
        }
        return (buy, wait, hold)
    }

    var body: some View {
        GPPageBackground {
            EditorialSection(title: "值不值得买 · 总览", trailing: "\(items.count)/\(codes.count) 只有分", accent: p.terracotta) {
                if computing {
                    GPStatus(title: "正在打分", detail: "只用本机已归档的日 K（≥20 根），不联网、不预测涨跌。", symbol: "hourglass")
                } else if items.isEmpty {
                    GPStatus(title: "暂无可打分的标的", detail: "总览只用本机已归档的日 K。点进标的切到「日K」会触发 NAS 拉取，回来再看。", symbol: "chart.bar.doc.horizontal")
                } else {
                    HStack(spacing: 20) {
                        GPValue(label: "可考虑", value: "\(counts.buy)", emphasis: p.risk)
                        GPValue(label: "等确认", value: "\(counts.wait)", emphasis: p.terracotta)
                        GPValue(label: "回避", value: "\(counts.hold)", emphasis: p.jade)
                    }.padding(.bottom, 2)
                    ScoreRadarPortfolioChart(assessments: items.map(\.assessment))
                    ForEach(items) { item in WorthOverviewRow(item: item) }
                    Text("分数 = 技术面基准 + 股息率 + 价格位置 + 溢折价 + 仓位修正。逐条依据点进标的看，不构成投资建议。")
                        .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
                if !missing.isEmpty {
                    Text("待日K（\(missing.count) 只）：\(missing.joined(separator: "、"))")
                        .font(.caption2).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("值不值得买").navigationBarTitleDisplayMode(.inline)
        .task { await compute() }
    }

    private func compute() async {
        computing = true
        await Task.yield()
        var scored: [WorthOverviewItem] = []
        var pending: [String] = []
        let today = RuleDateText.today()
        let total = portfolioTotal
        for code in codes {
            guard let quote = model.quotes[code]?.quote, quote.price > 0,
                  let dataset = model.chartData["\(code):day"] else { pending.append(code); continue }
            let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? []))
            let recent = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: today)
            let annual: Decimal = recent > 0 ? recent : (NextDividendAnalytics.projectedAnnualPerShare(code: code, events: events, today: today)?.amount ?? 0)
            let position = model.book.positions.first { $0.code == code }
            var weight: Double?
            if total > 0, let position { weight = NextNum.double(quote.price) * Double(position.units) / total * 100 }
            guard let assessment = NextWorthBuyEngine.evaluate(
                code: code, price: quote.price, previousClose: quote.previousClose,
                samples: dataset.orderedSamples, dividendPerShare: annual, iopv: quote.iopv,
                costPerUnit: position?.costPerUnit, weightPercent: weight,
                positionLimitPercent: NextNum.double(model.goal.concentrationLimit)) else { pending.append(code); continue }
            scored.append(WorthOverviewItem(code: code, name: model.name(for: code), assessment: assessment))
        }
        items = scored.sorted { $0.assessment.score > $1.assessment.score }
        missing = pending
        computing = false
    }
}

private struct WorthOverviewRow: View {
    @Environment(\.gp) private var p
    let item: WorthOverviewItem
    private var tone: Color {
        switch item.assessment.action {
        case "可考虑": return p.risk
        case "等确认": return p.terracotta
        default: return p.jade
        }
    }
    var body: some View {
        NavigationLink(value: GPRoute.instrument(item.code)) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(item.assessment.score)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tone).frame(width: 36, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                    Text("\(item.code) · 日K \(item.assessment.barCount) 根" + (item.assessment.dividendYieldPercent.map { " · 股息率 \(NextNum.percent($0))" } ?? ""))
                        .font(.caption2).foregroundStyle(p.muted).lineLimit(1)
                    if let hint = weakHint {
                        Text(hint).font(.caption2).foregroundStyle(p.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(item.assessment.action).font(.caption.weight(.semibold)).foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tone.opacity(0.12), in: Capsule())
            }.padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
        }.buttonStyle(.plain)
    }

    /// 六维里最低的两项，让「为什么分低」在列表页就能看出来，不必逐只点进去。
    private var weakHint: String? {
        let ranked = item.assessment.dimensions.sorted { $0.value < $1.value }.prefix(2)
        guard !ranked.isEmpty else { return nil }
        return "短板：" + ranked.map { "\($0.title) \(Int($0.value.rounded()))" }.joined(separator: " · ")
    }
}
