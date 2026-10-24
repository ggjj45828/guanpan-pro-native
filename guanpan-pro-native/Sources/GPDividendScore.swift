import SwiftUI

/// 收息页「红利买入时机 · 自选打分」卡。对自选与持仓逐只打分，点击进行情详情。
struct DividendBuyScoreCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @AppStorage("guanpan.targetYield") private var targetYieldText = "4"
    @State private var methodExpanded = false
    @State private var refreshing = false

    private var targetYield: Decimal { Decimal(string: targetYieldText.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var today: String { dividendTodayString() }
    private var codes: [String] { Array(Set(model.watch + model.book.positions.map(\.code))).sorted() }
    private var rows: [DividendBuyScore] {
        let target = targetYield
        return codes.compactMap { code -> DividendBuyScore? in
            let events = NextDividendAnalytics.merged(model.book.dividendEvents + (model.dividendEvents[code] ?? [])).filter { $0.code == code }
            let perShare = NextDividendAnalytics.recentVerifiedPerShare(code: code, events: events, today: today)
            let quote = model.quotes[code]?.quote
            let samples = model.chartData["\(code):day"]?.orderedSamples ?? []
            return DividendBuyScoreEngine.evaluate(code: code, perShare: perShare, price: quote?.price,
                iopv: quote?.iopv, samples: samples, dividendEvents: events,
                today: today, targetYieldPercent: target)
        }.sorted { $0.total > $1.total }
    }
    private var unscoredCount: Int { codes.count - rows.count }
    private var scoredCount: Int { rows.count }
    private var sectionTrailing: String { "\(scoredCount) 只打分" }

    var body: some View {
        EditorialSection(title: "红利买入时机 · 自选打分", trailing: sectionTrailing, accent: p.chartGold) {
            intro
            DisclosureGroup(isExpanded: $methodExpanded) {
                methodPanel
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Capsule().fill(p.chartGold.opacity(0.85)).frame(width: 3, height: 14).offset(y: 1)
                    Text("打分方法").font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text("40/35/15/10").font(.caption).foregroundStyle(p.chartGold.opacity(0.85))
                }
            }
            .accentColor(p.forest)
            targetYieldEditor
            if rows.isEmpty {
                GPStatus(title: "暂时没有可打分的标的",
                         detail: "需要近 12 个月有已核实派息、且能取到行情。点「刷新打分数据」拉取派息历史与行情；只用已核实数据，不用推算值冒充。",
                         symbol: "star.slash")
            } else {
                ForEach(rows) { score in
                    DividendBuyScoreRow(score: score, targetYield: targetYield)
                    if score.code != rows.last?.code { Divider().overlay(p.line) }
                }
                if unscoredCount > 0 {
                    Text("另有 \(unscoredCount) 只未打分：近 12 个月没有已核实派息，或暂无行情。")
                        .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            GPActionButton(title: refreshing ? "刷新中…" : "刷新打分数据", secondary: true, systemImage: "arrow.clockwise", action: refresh).disabled(refreshing)
        }
    }

    private var intro: some View {
        Text("价格越跌、股息率越高，分数越高。全部用本机已核实数据现算：近 12 个月每份派息、现价/IOPV、近半年日 K 高低点、近三年分红年份。不预测价格，也不预测分红；只是把「现在适不适合开始关注」拆成可核对的分数。")
            .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var methodPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            GPDataRow(title: "股息率 · 40 分", value: "达到目标股息率拿满", note: "近12个月每份已核实派息 ÷ 现价（ETF 有 IOPV 按净值）；按比例给分")
            GPDataRow(title: "价格位置 · 35 分", value: "越靠区间下沿分越高", note: "现价在近 180 个交易日高低区间中的位置")
            GPDataRow(title: "高点回撤 · 15 分", value: "回撤 20% 拿满", note: "相对近 180 个交易日高点；跌得越深分越高")
            GPDataRow(title: "分红稳定性 · 10 分", value: "3 年 10 / 2 年 7 / 1 年 4", note: "近三个自然年有已核实派息的年份数")
            Text("档位：≥80 值得关注 · 60–79 可分批 · 40–59 观望 · <40 等待。缺数据的项按 0 分计并在行内标注，不拿中性分冒充。")
                .font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var targetYieldEditor: some View {
        HStack(spacing: 6) {
            Text("目标年化股息率门槛 %").font(.caption).foregroundStyle(p.muted)
            TextField("4", text: $targetYieldText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 64)
                .onChange(of: targetYieldText) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if let v = Decimal(string: trimmed), v > 0 { UserDefaults.standard.set(NextMoney.text(v, digits: 3), forKey: "guanpan.targetYield") }
                }
            Spacer(minLength: 4)
            Text("统一设置 · 仅供参考筛选").font(.caption2).foregroundStyle(p.muted)
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            for security in codes {
                await model.refreshInstrument(security)
                await model.refreshDividendHistory(security)
            }
            refreshing = false
        }
    }
}

struct DividendBuyScoreRow: View {
    @Environment(\.gp) private var p
    @EnvironmentObject private var model: NextAppModel
    let score: DividendBuyScore
    let targetYield: Decimal

    private var tone: Color {
        switch score.tier {
        case .attention: return p.jade
        case .batch: return p.chartGold
        case .observe: return p.chartBlue
        case .wait: return p.muted
        case .insufficient: return p.muted
        }
    }
    private var isETF: Bool { NextDividendRules.isOnExchangeETF(score.code) }
    private var name: String {
        let quoted = model.quotes[score.code]?.quote.name ?? ""
        if !quoted.isEmpty, quoted != score.code { return quoted }
        return model.book.positions.first(where: { $0.code == score.code })?.name ?? NextNameBook.resolve(score.code)
    }
    private var yieldBasisText: String { isETF && score.yieldBase != score.price ? "按净值" : "按现价" }
    private var targetPriceText: String {
        guard targetYield > 0 else { return "—" }
        return "¥\(NextMoney.text(score.perShare / (targetYield / 100), digits: 3))"
    }
    private var priceLine: String {
        "现价 ¥\(NextMoney.text(score.price, digits: 3)) · 股息率 \(NextNum.text(score.yieldPercent, digits: 3))%（\(yieldBasisText)）· 目标买入价 \(targetPriceText)"
    }
    private var componentsLine: String {
        "股息率 \(score.yieldPoints)/40 · 位置 \(score.positionPoints)/35 · 回撤 \(score.drawdownPoints)/15 · 稳定 \(score.stabilityPoints)/10"
    }
    /// 行情不新鲜时明说：分数按缓存价算，不能冒充实时。
    private var staleQuoteNote: String? {
        guard let cached = model.quotes[score.code], !cached.quote.isFresh(at: Date()) else { return nil }
        return "行情\(cached.stamp.label(now: Date()))，分数按该缓存价计算"
    }

    var body: some View {
        NavigationLink(value: GPRoute.instrument(score.code)) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
                    GPPillBadge(text: isETF ? "ETF" : "股票", color: isETF ? p.jade : p.chartBlue)
                    Spacer(minLength: 4)
                    Text("\(score.total) 分").font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(tone)
                    Text(score.tier.rawValue).font(.caption.weight(.semibold)).foregroundStyle(tone)
                }
                Text(priceLine).font(.caption).foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.8)
                Text(componentsLine).font(.caption2).foregroundStyle(p.muted).lineLimit(1).minimumScaleFactor(0.8)
                if !score.missing.isEmpty {
                    Text("缺 \(score.missing.joined(separator: "、"))，该项按 0 分计")
                        .font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
                if let staleQuoteNote {
                    Text(staleQuoteNote)
                        .font(.caption2).foregroundStyle(p.terracotta).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
