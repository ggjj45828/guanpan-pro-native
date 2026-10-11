import SwiftUI
import Foundation

// MARK: - 账户智能画像（对齐网页版「私人顾问 · 画像」）
//
// 网页版会「看你的行为，不用你说」：从交易流水里推断交易风格、风险偏好、纪律性，
// 再把画像喂给大模型做建议。这里做同一件事：
//   1. 本机规则引擎先行 —— 不配 Key 也能推断画像（零成本、可解释、可审计）；
//   2. 配了 Key 时可选大模型深度推断 —— 把规则算出的指标发给模型，让它下结论。
// 所有指标只来自本机账本（ledger / fundTransactions / 快照 / 持仓），不上传任何数据。

// MARK: 画像数据模型

struct PortraitMetric: Identifiable {
    let title: String
    let value: String
    /// nil = 中性；true = 偏积极；false = 偏风险
    let tone: Bool?
    var id: String { title }
}

struct PortraitTag: Identifiable {
    let text: String
    /// 积极 / 中性 / 风险 三种配色
    let tone: Int // 1 积极, 0 中性, -1 风险
    var id: String { text }
}

struct AccountPortrait {
    var tags: [PortraitTag] = []
    var metrics: [PortraitMetric] = []
    var conclusions: [String] = []
    /// 推断出的投资偏好建议（可一键写入 investmentProfile）
    var suggestedStyle: String = "swing"   // day / swing / mid / long
    var suggestedRisk: String = "bal"      // con / bal / agg
    var suggestedMaxPosition: Double = 35
    var suggestedHorizon: String = "1-3个月"
    var inferredMethod: String = ""
    var sampleSize: Int = 0
    var hasAccountData = false
    var hasData: Bool { sampleSize > 0 || hasAccountData }
}

// MARK: 规则推断引擎

enum PortraitEngine {
    static func compute(data: PortfolioData, totalAsset: Double) -> AccountPortrait {
        var out = AccountPortrait()
        out.hasAccountData = !data.holdings.isEmpty || data.cash > 0 || !data.snapshots.isEmpty

        // ---- 交易样本：ETF 台账 + 基金流水（分红不算交易；自动定投单独标记）----
        let etfBuys = data.ledger.filter { $0.side == .buy }
        let etfSells = data.ledger.filter { $0.side == .sell }
        let fundBuys = data.fundTransactions.filter { $0.side == .buy }
        let fundSells = data.fundTransactions.filter { $0.side == .sell }
        let dcaCount = data.fundTransactions.filter { $0.isAutomaticDCA == true }.count
            + data.fundDCAPlans.filter { $0.enabled }.count
        let manualTrades = etfBuys.count + etfSells.count
            + fundBuies(fundBuys) + fundSells.count
        out.sampleSize = manualTrades + dcaCount

        // ---- 交易跨度（月）----
        var dates: [Date] = data.ledger.map(\.date)
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "Asia/Shanghai")
        iso.dateFormat = "yyyy-MM-dd"
        for t in data.fundTransactions where t.side != .dividend {
            if let d = iso.date(from: String(t.effectiveDate.prefix(10))) { dates.append(d) }
        }
        let spanMonths: Double
        if let first = dates.min(), let last = dates.max(), last > first {
            spanMonths = max(1, Double(Calendar.current.dateComponents([.day], from: first, to: last).day ?? 30) / 30.0)
        } else { spanMonths = 1 }
        let perMonth = Double(manualTrades) / spanMonths

        // ---- 胜负与费用 ----
        let realized = data.ledger.map(\.realizedPnL)
            + data.fundTransactions.filter { $0.side == .sell }.map(\.realizedPnL)
        let wins = realized.filter { $0 > 0.005 }.count
        let losses = realized.filter { $0 < -0.005 }.count
        let winRate: Double? = (wins + losses) > 0 ? Double(wins) / Double(wins + losses) * 100 : nil
        let turnover = data.ledger.map(\.gross).reduce(0, +)
            + data.fundTransactions.filter { $0.side != .dividend }.map(\.amount).reduce(0, +)
        let fees = data.ledger.map(\.fee).reduce(0, +)
            + data.fundTransactions.map(\.fee).reduce(0, +)
        let feeRate: Double? = turnover > 0 ? fees / turnover * 100 : nil

        // ---- 集中度与现金 ----
        let marketValue = data.holdings.reduce(0) { $0 + $1.marketValue }
        let maxWeight: Double = totalAsset > 0
            ? (data.holdings.map { $0.marketValue / totalAsset }.max() ?? 0) * 100 : 0
        let cashRatio: Double = totalAsset > 0 ? data.cash / totalAsset * 100 : 0

        // ---- 画像标签 ----
        if perMonth >= 8 {
            out.tags.append(PortraitTag(text: "高频交易", tone: -1))
        } else if perMonth >= 3 {
            out.tags.append(PortraitTag(text: "波段选手", tone: 0))
        } else if perMonth >= 1 {
            out.tags.append(PortraitTag(text: "中低频", tone: 0))
        } else if out.sampleSize > 0 {
            out.tags.append(PortraitTag(text: "低频长线", tone: 1))
        }
        if dcaCount > 0 { out.tags.append(PortraitTag(text: "定投纪律 \(dcaCount) 笔", tone: 1)) }
        if maxWeight >= 45 {
            out.tags.append(PortraitTag(text: "单仓 \(Int(maxWeight))% · 集中", tone: -1))
        } else if maxWeight > 0 && maxWeight < 20 {
            out.tags.append(PortraitTag(text: "持仓分散", tone: 1))
        }
        if let wr = winRate {
            if wr >= 60 { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))% · 不错", tone: 1)) }
            else if wr < 40 { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))% · 偏低", tone: -1)) }
            else { out.tags.append(PortraitTag(text: "胜率 \(Int(wr))%", tone: 0)) }
        }
        if cashRatio <= 3 && totalAsset > 0 { out.tags.append(PortraitTag(text: "几乎满仓", tone: -1)) }
        else if cashRatio >= 40 && totalAsset > 0 { out.tags.append(PortraitTag(text: "现金充裕", tone: 0)) }
        if let fr = feeRate, fr >= 0.5 { out.tags.append(PortraitTag(text: "费用拖累 \(fr.num(2))%", tone: -1)) }

        // ---- 指标行 ----
        out.metrics.append(PortraitMetric(title: "手动交易笔数", value: manualTrades == 0 && out.hasAccountData ? "暂无流水" : "\(manualTrades) 笔", tone: nil))
        out.metrics.append(PortraitMetric(title: "交易频率", value: manualTrades == 0 && out.hasAccountData ? "样本不足" : "\(perMonth.num(1)) 笔/月", tone: manualTrades == 0 ? nil : perMonth >= 8 ? false : nil))
        out.metrics.append(PortraitMetric(title: "卖出胜负", value: wins + losses == 0 ? "暂无卖出" : "\(wins) 胜 \(losses) 负", tone: nil))
        if let wr = winRate {
            out.metrics.append(PortraitMetric(title: "卖出胜率", value: wr.pct(1), tone: wr >= 50 ? true : false))
        }
        if let fr = feeRate {
            out.metrics.append(PortraitMetric(title: "费用占换手", value: fr.pct(2), tone: fr >= 0.5 ? false : true))
        }
        out.metrics.append(PortraitMetric(title: "最大单仓", value: maxWeight.pct(1), tone: maxWeight >= 45 ? false : nil))
        out.metrics.append(PortraitMetric(title: "现金占比", value: cashRatio.pct(1), tone: nil))
        out.metrics.append(PortraitMetric(title: "累计费用", value: fees.cny(), tone: nil))

        // ---- 推断结论 ----
        var lines: [String] = []
        if perMonth >= 8 {
            lines.append("你最近平均每月手动交易 \(perMonth.num(1)) 笔，属于高频节奏。账面费用已累计 \(fees.cny())，换手越频繁，费用对收益的侵蚀越明显——先核对一下这些交易有多少是计划内、多少是临时起意。")
        } else if perMonth >= 1 {
            lines.append("平均每月 \(perMonth.num(1)) 笔手动交易，节奏适中。保持「计划先行」的习惯比增加次数更有价值。")
        } else if out.sampleSize > 0 {
            lines.append("手动交易很少（\(manualTrades) 笔），更接近低频 / 定投风格。账户波动主要来自持仓本身而非操作。")
        } else if out.hasAccountData {
            lines.append("目前缺少买卖流水，无法判断交易频率或胜率；以下只按当前持仓集中度和现金比例分析账户结构。补录流水后再生成行为结论。")
        } else {
            lines.append("账本里还没有持仓、现金或交易记录，暂时无法形成画像。")
        }
        if maxWeight >= 45 {
            let top = data.holdings.max { $0.marketValue < $1.marketValue }
            lines.append("最大单仓占总资产 \(maxWeight.num(1))%\(top.map { "（\($0.name)）" } ?? "")，单一标的的波动会主导整个账户。网页版的再平衡建议会按同样的口径提醒你。")
        }
        if let wr = winRate, wr < 40, wins + losses >= 5 {
            lines.append("已实现的卖出里只有 \(Int(wr))% 是盈利的（\(wins) 胜 \(losses) 负）。样本不算大，但值得回看亏损卖出的共同点：是止损太早、追高被套，还是标的本身选错。")
        }
        if dcaCount > 0 {
            lines.append("检测到 \(dcaCount) 笔定投记录/计划。定投最大的价值是「纪律」，建议保持固定扣款，不要因为短期涨跌暂停。")
        }
        if cashRatio <= 3 && totalAsset > 0 {
            lines.append("现金只剩 \(cashRatio.pct(1))，几乎满仓。留 5–10% 现金不是为了收益，是为了在下跌时有子弹、在急涨时不被迫卖。")
        }
        if manualTrades == 0 && out.hasAccountData && maxWeight >= 30 {
            let top = data.holdings.max { $0.marketValue < $1.marketValue }
            lines.append("当前最大单仓占总资产 \(maxWeight.num(1))%\(top.map { "（\($0.name)）" } ?? "")。新买入前先检查它是否已接近你设定的单标的上限，避免仓位继续集中。")
        }
        if manualTrades == 0 && out.hasAccountData && totalAsset > 0 && cashRatio < 5 {
            lines.append("参考现金占比只有 \(cashRatio.num(1))%，可用缓冲较少。若计划加仓，先核对现金安排和仓位上限，避免为了补仓被迫卖出其他资产。")
        }
        if manualTrades == 0 && out.hasAccountData && totalAsset > 0 && cashRatio >= 40 {
            lines.append("参考现金占比为 \(cashRatio.num(1))%，现金缓冲较充足；可以先按目标仓位分批计划，不必因短期波动一次性投入。")
        }
        out.conclusions = lines

        // ---- 偏好建议（写入 InvestmentProfile 用）----
        out.suggestedStyle = perMonth >= 8 ? "day" : perMonth >= 3 ? "swing" : perMonth >= 1 ? "mid" : "long"
        out.suggestedRisk = (maxWeight >= 40 || cashRatio <= 5) ? "agg" : (maxWeight <= 20 && dcaCount > 0) ? "con" : "bal"
        out.suggestedMaxPosition = min(80, max(10, (maxWeight / 10).rounded(.up) * 10 + 10))
        out.suggestedHorizon = perMonth >= 8 ? "数天" : perMonth >= 3 ? "1-3个月" : perMonth >= 1 ? "3-6个月" : "1年以上"
        out.inferredMethod = perMonth >= 8
            ? "系统观察：高频手动交易，注意费用与情绪化下单。"
            : dcaCount > 0 && perMonth < 1
            ? "系统观察：低频 + 定投为主，很少手动操作。"
            : "系统观察：节奏适中，波段与中线之间。"
        return out
    }

    private static func fundBuies(_ buys: [FundTransaction]) -> Int {
        buys.filter { $0.isAutomaticDCA != true }.count
    }

    /// 把本机指标拼成大模型提示词（配了 Key 时才发送）
    static func portraitPrompt(_ p: AccountPortrait, data: PortfolioData, totalAsset: Double) -> String {
        let fmt: (Double) -> String = { String(format: "%.2f", $0) }
        let metrics = p.metrics.map { "- \($0.title)：\($0.value)" }.joined(separator: "\n")
        let holdings = data.holdings.map {
            "- \($0.name)（\($0.code)）：市值 \(fmt($0.marketValue))，浮盈亏 \(fmt($0.pnl))"
        }.joined(separator: "\n")
        let holdingsText = holdings.isEmpty ? "（暂无）" : holdings
        let inferenceSummary: String
        if p.sampleSize > 0 {
            inferenceSummary = "本机规则初步推断（请验证或反驳）：风格「\(p.suggestedStyle)」，风险「\(p.suggestedRisk)」，单仓上限参考 \(Int(p.suggestedMaxPosition))%。"
        } else {
            inferenceSummary = "目前没有可用买卖流水，不要推断交易风格或胜率；只根据当前持仓市值与现金比例给出结构性建议。"
        }
        return """
        请基于以下本机账本统计，给出有判断、有因果链的账户诊断，不要把行为指标或持仓逐项念出来。先区分「流水能证明的行为」与「当前结构反映的风险」，再挑出最值得处理的一到两个问题，说明它们为何比其他问题优先。按「行为画像（样本足够时）、关键问题及证据、接下来怎么做、什么信号出现要暂停/复核」组织；每条建议必须写明触发条件、动作和边界。明确区分事实与推断；没有买卖流水时说明无法判断胜率和操作习惯，只分析当前持仓结构。语气直接，不嘲讽，不承诺收益，不编造数据。
        总资产：\(fmt(totalAsset))，现金 \(fmt(data.cash))。
        行为指标：
        \(metrics)
        当前持仓：
        \(holdingsText)
        \(inferenceSummary)
        """
    }
}

// MARK: - 画像视图

struct AccountPortraitView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var portrait: AccountPortrait?
    @State private var aiResult = ""
    @State private var aiBusy = false
    @State private var message = ""
    @State private var savedMessage = ""

    private var keySaved: Bool { AIAnalysisService.hasSavedAPIKey }

    var body: some View {
        NavigationStack {
            Form {
                if let p = portrait, p.hasData {
                    tagsSection(p)
                    metricsSection(p)
                    conclusionsSection(p)
                    if p.sampleSize > 0 { suggestionSection(p) }
                    aiSection(p)
                } else {
                    Section {
                        Text("账本里还没有交易记录，暂时无法推断画像。先在持仓页记录几笔买入/卖出，或开启一笔定投，画像会自动生成。")
                    }
                }
                if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
                Section {
                    Text("画像只描述你已经发生的行为，不预测市场，也不构成投资建议。所有计算在本机完成；只有你主动点「大模型深度推断」时，上述统计才会发送到你配置的接口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI 智能画像")
            .keyboardDoneToolbar()
            .scrollContentBackground(.hidden)
            .background(.clear)
            .presentationBackground(.clear)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear { recompute() }
        }
    }

    private func recompute() {
        portrait = PortraitEngine.compute(data: store.data, totalAsset: store.totalAsset)
    }

    private func tagsSection(_ p: AccountPortrait) -> some View {
        Section("画像标签") {
            FlowTags(tags: p.tags)
        }
    }

    private func metricsSection(_ p: AccountPortrait) -> some View {
        Section("行为指标") {
            ForEach(p.metrics) { m in
                HStack {
                    Text(m.title).foregroundStyle(.secondary)
                    Spacer()
                    Text(m.value).monospacedDigit()
                        .foregroundStyle(m.tone == true ? PnLColor.up : m.tone == false ? PnLColor.down : Color.primary)
                }.font(.subheadline)
            }
        }
    }

    private func conclusionsSection(_ p: AccountPortrait) -> some View {
        Section("系统观察") {
            ForEach(Array(p.conclusions.enumerated()), id: \.offset) { _, line in
                Text(line).font(.subheadline)
            }
        }
    }

    private func suggestionSection(_ p: AccountPortrait) -> some View {
        Section("推断出的投资偏好") {
            LabeledContent("交易风格", value: styleName(p.suggestedStyle))
            LabeledContent("风险偏好", value: riskName(p.suggestedRisk))
            LabeledContent("单标的仓位上限", value: "\(Int(p.suggestedMaxPosition))%")
            LabeledContent("典型持有周期", value: p.suggestedHorizon)
            if !p.inferredMethod.isEmpty { Text(p.inferredMethod).font(.footnote).foregroundStyle(.secondary) }
            Button("把推断写入我的投资偏好") {
                var profile = store.data.investmentProfile
                profile.style = p.suggestedStyle
                profile.risk = p.suggestedRisk
                profile.maxPositionPercent = p.suggestedMaxPosition
                profile.horizon = p.suggestedHorizon
                if profile.method.isEmpty { profile.method = p.inferredMethod }
                store.data.investmentProfile = profile
                store.save(label: "写入智能画像推断的偏好")
                Haptics.success()
                savedMessage = "已写入。AI 账户分析会按这份偏好发送请求，你随时可以在那里改回来。"
            }
            if !savedMessage.isEmpty { Text(savedMessage).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func aiSection(_ p: AccountPortrait) -> some View {
        Section("大模型深度推断（可选）") {
            if keySaved {
                Button {
                    Task { await runAI(p) }
                } label: {
                    HStack {
                        if aiBusy { ProgressView().padding(.trailing, 4) }
                        Text(aiBusy ? "正在推断…" : "让大模型验证这份画像")
                    }
                }.disabled(aiBusy)
            } else {
                Text("还没有配置 API 密钥。到「更多 → AI 账户分析」里填好接口与密钥后，这里就能让大模型基于同样的数据做更深入的推断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !aiResult.isEmpty {
                Text(aiResult).textSelection(.enabled)
            }
            if !aiResult.isEmpty {
                Text("模型输出可能有误。画像描述的是历史行为，不代表未来收益。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor private func runAI(_ p: AccountPortrait) async {
        aiBusy = true; message = ""; aiResult = ""
        defer { aiBusy = false }
        do {
            aiResult = try await AIAnalysisService.chat(
                config: store.data.aiAnalysisConfig,
                prompt: PortraitEngine.portraitPrompt(p, data: store.data, totalAsset: store.totalAsset))
        } catch { message = error.localizedDescription }
    }

    private func styleName(_ raw: String) -> String {
        ["day": "超短线", "swing": "波段", "mid": "中线", "long": "长线定投"][raw] ?? raw
    }
    private func riskName(_ raw: String) -> String {
        ["con": "保守", "bal": "平衡", "agg": "激进"][raw] ?? raw
    }
}

/// 简单的流式标签排布（iOS 16 无 Layout 协议可用的兜底：按宽度手动换行）
private struct FlowTags: View {
    let tags: [PortraitTag]
    var body: some View {
        // 画像标签通常 2-5 个，两列网格足够；不做通用流式布局，避免引 Layout 协议的兼容负担
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(tags) { tag in
                Text(tag.text)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(tagColor(tag.tone).opacity(0.14)))
                    .foregroundStyle(tagColor(tag.tone))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tagColor(_ tone: Int) -> Color {
        tone > 0 ? PnLColor.up : tone < 0 ? PnLColor.down : Color.secondary
    }
}
