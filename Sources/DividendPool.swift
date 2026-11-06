import SwiftUI

// MARK: - 收息池（从观盘 max 移植）

/// 收息池的一条：代码 + 名称 + 每份年化现金分红（元）。
///
/// 分红不自动抓取 —— 没有稳定公开接口，猜一个数比空着更危险。
/// 用户按基金公告 / 年报填，填错会直接算错股息率，所以界面上要写明这一点。
struct DividendPoolEntry: Codable, Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    /// 每份每年现金分红（元）。ETF 按每份，个股按每股。
    var dividendPerUnit: Double
}

/// 一条的估值结果。所有字段都允许 nil：缺现价或缺分红时不许编数。
struct DividendValuation: Identifiable {
    var id: String { entry.code }
    let entry: DividendPoolEntry
    let price: Double?
    let yieldPercent: Double?
    /// 达到目标股息率对应的买入价。
    let targetPrice: Double?
    /// 现价在最近 60 日区间的位置（0 = 最低，1 = 最高）。
    let percentile: Double?
    let score: Int
    let verdict: String
}

enum DividendPoolEngine {
    /// 评分只用两类可解释事实：股息率相对目标的高低（60 分），
    /// 现价在最近 60 日区间的位置（40 分，越低越好）。
    ///
    /// 之所以不引入「历史分红增长」「行业均值」这些因子：本机没有可靠数据源，
    /// 一旦引入就是编造。两项都基于用户填的数与真实 K 线，错了也能指出来错在哪。
    static func valuation(entry: DividendPoolEntry,
                          price: Double?,
                          bars: [DailyBar],
                          targetYield: Double) -> DividendValuation {
        guard let price, price > 0, price.isFinite else {
            return DividendValuation(entry: entry, price: nil, yieldPercent: nil,
                                     targetPrice: nil, percentile: nil, score: 0,
                                     verdict: "缺现价")
        }
        let yieldPercent: Double? = entry.dividendPerUnit > 0
            ? entry.dividendPerUnit / price * 100
            : nil
        let targetPrice: Double? = (entry.dividendPerUnit > 0 && targetYield > 0)
            ? entry.dividendPerUnit / targetYield * 100
            : nil

        var percentile: Double?
        let window = Array(bars.suffix(60))
        if window.count >= 20 {
            let lows = window.map { $0.low }
            let highs = window.map { $0.high }
            if let low = lows.min(), let high = highs.max(), high > low {
                percentile = (price - low) / (high - low)
            }
        }

        guard let yieldPercent else {
            return DividendValuation(entry: entry, price: price, yieldPercent: nil,
                                     targetPrice: nil, percentile: percentile, score: 0,
                                     verdict: "待填分红")
        }
        let yieldScore = min(max(yieldPercent / max(targetYield, 0.1), 0), 1.4) / 1.4 * 60
        let positionScore = (1 - (percentile ?? 0.5)) * 40
        let raw = yieldScore + positionScore
        let score = Int(raw.rounded())
        let verdict: String
        if score >= 70 { verdict = "值得分批" }
        else if score >= 50 { verdict = "观察等位" }
        else { verdict = "偏贵 / 收益不足" }
        return DividendValuation(entry: entry, price: price, yieldPercent: yieldPercent,
                                 targetPrice: targetPrice, percentile: percentile,
                                 score: score, verdict: verdict)
    }
}

// MARK: - 页面

struct DividendPoolView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.appAppearance) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var newCode = ""
    @State private var newDividend = ""
    @State private var status = ""
    /// 拖动中的目标股息率。拖完才落盘，避免每一格都写一次备份。
    @State private var targetDraft: Double?

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight)
    }

    private var entries: [DividendPoolEntry] { store.data.dividendPool }

    private var targetYield: Double { store.data.dividendTargetYield }

    private var canAdd: Bool {
        newCode.trimmingCharacters(in: .whitespaces).count == 6
            && Double(newDividend.trimmingCharacters(in: .whitespaces)) != nil
    }

    private var valuations: [DividendValuation] {
        entries.map { entry in
            let price = currentPrice(for: entry.code)
            let bars = store.dailyBars[entry.code] ?? []
            return DividendPoolEngine.valuation(entry: entry, price: price,
                                                bars: bars, targetYield: targetYield)
        }
        .sorted { $0.score > $1.score }
    }

    private var reachedCount: Int {
        valuations.filter { ($0.yieldPercent ?? 0) >= targetYield }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    summaryCard
                    targetCard
                    addCard
                    if valuations.isEmpty {
                        emptyCard
                    } else {
                        ForEach(valuations) { item in
                            row(item)
                        }
                    }
                    Text("分红数据没有公开稳定接口，本页不自动抓取也不估算：每份分红请按基金公告 / 年报填写，填错会直接算错股息率。ETF 分红会除权，股息率高不等于总回报高。")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.horizontal, DS.pageInset)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("收息池")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    // MARK: 卡片

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("池内标的")
                .scaledFont(DS.fsLabel, weight: .medium)
                .foregroundStyle(palette.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(entries.count)")
                    .scaledFont(DS.fsHero, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                Text("只 · 已达目标 \(reachedCount) 只")
                    .scaledFont(DS.fsLabel)
                    .foregroundStyle(palette.ink2)
            }
            Text("目标股息率 \(targetYield.num(1))%。现价低于「目标买价」才算到了位置。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.heroRadius, padding: 18)
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("目标股息率")
                    .scaledFont(DS.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                Spacer()
                Text("\(targetYield.num(1))%")
                    .scaledFont(DS.fsRow, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
            }
            Slider(value: Binding(get: { targetDraft ?? targetYield },
                                  set: { targetDraft = $0 }),
                   in: 2...8, step: 0.5,
                   onEditingChanged: { editing in
                       if !editing { commitTarget() }
                   })
                .tint(palette.accent)
            Text("拖动即保存。每一行会算出「达到该股息率所需的买入价」。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
        }
        .dsSurface(palette, radius: 18, padding: 16)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("加入标的")
                .scaledFont(DS.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            HStack(spacing: 8) {
                TextField("六位代码", text: $newCode)
                    .keyboardType(.numberPad)
                    .scaledFont(13)
                    .foregroundStyle(palette.ink)
                    .padding(10)
                    .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.cardSoft) }
                TextField("每份年分红", text: $newDividend)
                    .keyboardType(.decimalPad)
                    .scaledFont(13)
                    .foregroundStyle(palette.ink)
                    .padding(10)
                    .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.cardSoft) }
            }
            Button {
                addEntry()
            } label: {
                Text("加入收息池")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(canAdd ? .white : palette.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(canAdd ? palette.accent : palette.cardSoft)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)

            if !status.isEmpty {
                Text(status)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
            if !store.data.quotes.isEmpty {
                Text("从自选快速加入")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.data.quotes.prefix(12)) { quote in
                            Button {
                                newCode = quote.code
                                Haptics.tap()
                            } label: {
                                Text(quote.name.isEmpty ? quote.code : quote.name)
                                    .scaledFont(DS.fsMicro, weight: .medium)
                                    .foregroundStyle(palette.ink2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background { Capsule().fill(palette.cardSoft) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .dsSurface(palette, radius: 18, padding: 16)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("收息池还是空的")
                .scaledFont(DS.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            Text("把常看的红利 ETF 或高股息个股加进来，填上最近一次年度分红就能评分。")
                .scaledFont(DS.fsLabel)
                .foregroundStyle(palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 18, padding: 16)
    }

    private func row(_ item: DividendValuation) -> some View {
        let tone = scoreTone(item.score)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DsIconTile(symbol: "yensign.circle.fill", tint: tone, size: 36, palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entry.name.isEmpty ? item.entry.code : item.entry.name)
                        .scaledFont(DS.fsRow, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(item.entry.code)
                        .scaledFont(DS.fsMicro)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink2)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(item.score)")
                        .scaledFont(17, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(tone)
                    Text(item.verdict)
                        .scaledFont(9.5, weight: .medium)
                        .foregroundStyle(palette.ink3)
                }
            }
            HStack(spacing: 14) {
                detail("现价", item.price.map { $0.num(3) } ?? "--")
                detail("股息率", item.yieldPercent.map { $0.pct(2) } ?? "--")
                detail("目标买价", item.targetPrice.map { $0.num(3) } ?? "--")
                detail("60日位置", item.percentile.map { ($0 * 100).pct(0) } ?? "--")
            }
            if let target = item.targetPrice, let price = item.price {
                Text(price <= target
                     ? "现价已低于目标买价 \(((target - price) / target * 100).pct(1))"
                     : "还要再跌 \(((price - target) / price * 100).pct(1)) 才到目标买价")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(price <= target ? PnLColor.up : palette.ink3)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)
        }
        .contextMenu {
            Button(role: .destructive) {
                remove(item.entry.code)
            } label: { Label("从收息池移除", systemImage: "trash") }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(DS.fsLabel, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
    }

    private func scoreTone(_ score: Int) -> Color {
        if score >= 70 { return PnLColor.down }
        if score >= 50 { return Color(hex: 0xE8B33A) }
        return palette.ink3
    }

    // MARK: 数据

    private func currentPrice(for code: String) -> Double? {
        if let quote = store.data.quotes.first(where: { $0.code == code }), quote.price > 0 {
            return quote.price
        }
        if let holding = store.data.holdings.first(where: { $0.code == code }), holding.current > 0 {
            return holding.current
        }
        return nil
    }

    private func commitTarget() {
        guard let draft = targetDraft else { return }
        store.data.dividendTargetYield = draft
        store.save(label: "收息目标股息率")
        targetDraft = nil
    }

    private func addEntry() {
        let code = newCode.trimmingCharacters(in: .whitespaces)
        guard code.count == 6, let dividend = Double(newDividend.trimmingCharacters(in: .whitespaces)) else {
            status = "代码要六位，分红要填数字。"
            return
        }
        guard dividend > 0 else {
            status = "每份年分红要大于 0；不知道就先去查公告，不要先填 0。"
            return
        }
        if store.data.dividendPool.contains(where: { $0.code == code }) {
            status = "\(code) 已经在池里了，移除后再重加可以改分红。"
            return
        }
        let name = store.data.quotes.first(where: { $0.code == code })?.name
            ?? store.data.holdings.first(where: { $0.code == code })?.name
            ?? ""
        store.data.dividendPool.append(DividendPoolEntry(code: code, name: name, dividendPerUnit: dividend))
        store.save(label: "收息池加入 \(code)")
        Haptics.success()
        status = "已加入 \(name.isEmpty ? code : name)。"
        newCode = ""
        newDividend = ""
    }

    private func remove(_ code: String) {
        store.data.dividendPool.removeAll { $0.code == code }
        store.save(label: "收息池移除 \(code)")
        Haptics.tap()
    }
}
