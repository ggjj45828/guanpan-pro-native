import SwiftUI
import Foundation

// MARK: - 技术研究页（K 线六形态 + 多周期 MACD + 量价）
//
// 设计对齐：repo/layout-mockups（M1~M5）+ repo/chart-mockups（V3 深色专业 / V5 高密度多指标）
//   · 双主题：科技黑绿（近黑底、卡片浮层、强调柠檬绿 #C8F751）
//             / 蓝海浅色（浅灰底、白卡、蓝紫强调）。全部走 ThemeSemantics 契约，不硬编码色。
//   · 卡片：大圆角、无色阶分层（tech）/ 淡影（ocean），与模拟图一致，不堆孤立白卡。
//   · 所有技术信号标记为「实验级 · 观察证据」：本机规则计算，不联网、不预测、不是买卖建议。
//   · 与六维评分 / 技术指标评分解耦：本页只呈现「看见了什么」，不新增任何买卖评分。

struct TechnicalResearchView: View {
    @Environment(\.appAppearance) private var appearance
    @EnvironmentObject private var store: PortfolioStore

    let code: String
    let name: String

    private var bars: [DailyBar] { store.dailyBars[code] ?? [] }
    private var macd: MultiTimeframeMACDAssessment? { store.multiTimeframeMACD120(code: code) }
    private var patterns: CandlePatternReport? { store.candlePatterns(code: code) }
    private var volume: VolumeAnalysisResult? {
        guard !bars.isEmpty else { return nil }
        return VolumeAnalysisEngine.daily(bars)
    }

    /// 市场环境（指数）：复用本机 MarketRegime 引擎，与全 App 一致（含防抖记忆）。
    @State private var regime: MarketRegimeAssessment? = nil

    var body: some View {
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        ScrollView {
            VStack(alignment: .leading, spacing: layout.gap * 1.4) {
                header
                macdCard
                patternCard
                volumeCard
                marketRegimeCard
                disclaimerCard
            }
            .padding(layout.pageInset)
        }
        .task { regime = store.marketRegime() }
        .themedFormBackground(ThemeSemantics.of(appearance))
        .navigationTitle("技术研究")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 头部

    private var header: some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.title2.bold()).foregroundStyle(sem.ink)
                Text(code).font(.subheadline).foregroundStyle(sem.ink3)
                Spacer(minLength: 0)
            }
            if let latest = bars.last {
                Text("最新收盘 \(latest.close.num(3)) · \(latest.date)")
                    .font(.caption).foregroundStyle(sem.ink3)
            } else {
                Text("暂无日线数据").font(.caption).foregroundStyle(sem.ink3)
            }
        }
    }

    // MARK: - 多周期 MACD

    private var macdCard: some View {
        ResearchCard(title: "多周期 MACD",
                     subtitle: "日线 12,26,9 · 120分 6,13,5 · 周线 12,26,9",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let macd {
                    let items = [macd.daily] + [macd.weekly, macd.intraday].compactMap { $0 }
                    ForEach(Array(items.enumerated()), id: \.element.timeframe) { idx, a in
                        macdRow(a)
                        if idx < items.count - 1 { Divider().background(sem.hairline) }
                    }
                    Divider().background(sem.hairline)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "link").font(.caption2).foregroundStyle(sem.ink3)
                        Text(macd.relationship).font(.caption).foregroundStyle(sem.ink2)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(sem.ink3)
                        Text(macd.resonance).font(.caption).foregroundStyle(sem.ink2)
                    }
                } else {
                    Text("日线数据不足，暂无法计算 MACD。").font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func macdRow(_ a: MACDTimeframeAssessment) -> some View {
        let sem = ThemeSemantics.of(appearance)
        let params: String = {
            switch a.timeframe {
            case .minutes120: return "6,13,5"
            default: return "12,26,9"
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.timeframe.title).font(.subheadline.bold()).foregroundStyle(sem.ink)
                Text(params).font(.caption2).foregroundStyle(sem.ink3)
                Spacer(minLength: 0)
                Text(a.trend.title)
                    .font(.caption.bold())
                    .foregroundStyle(trendColor(a.trend, sem: sem))
            }
            HStack(spacing: 12) {
                crossBadge(a.cross, sem: sem)
                if let above = a.difAboveZero {
                    Text(above ? "DIF 在零轴上" : "DIF 在零轴下")
                        .font(.caption2).foregroundStyle(sem.ink3)
                }
                if let inc = a.histogramIncreasing {
                    Text(inc ? "红柱扩大" : "绿柱缩短（非买点）")
                        .font(.caption2)
                        .foregroundStyle(inc ? sem.ok : sem.ink3)
                }
                Spacer(minLength: 0)
            }
            if a.divergence == .bullish || a.divergence == .bearish {
                HStack(spacing: 6) {
                    Image(systemName: a.divergence == .bullish ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(a.divergence.title)
                        .font(.caption2.bold())
                }
                .foregroundStyle(a.divergence == .bullish ? sem.ok : sem.danger)
            }
            HStack(spacing: 8) {
                if !a.signalConfirmed {
                    Text("最新一根未走完 · 信号未收盘确认")
                        .font(.caption2).foregroundStyle(sem.warn)
                }
                Text("数据\(a.qualityLabel)")
                    .font(.caption2).foregroundStyle(sem.ink3)
            }
        }
    }

    private func trendColor(_ t: MACDTrend, sem: ThemeSemantics) -> Color {
        switch t {
        case .bullishImproving, .shortTermRebound: return sem.ok
        case .weakening, .bearish: return sem.danger
        case .neutral: return sem.ink3
        case .dataInsufficient: return sem.warn
        }
    }

    private func crossBadge(_ cross: MACDCross, sem: ThemeSemantics) -> some View {
        let spec: (String, Color, Color) = {
            switch cross {
            case .golden: return ("金叉", sem.accent, sem.accent.opacity(0.16))
            case .death: return ("死叉", sem.danger, sem.danger.opacity(0.16))
            case .none: return ("无交叉", sem.ink3, Color.clear)
            }
        }()
        return Text(spec.0).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(spec.2))
            .foregroundStyle(spec.1)
    }

    // MARK: - K 线六形态

    private var patternCard: some View {
        ResearchCard(title: "K 线六形态识别",
                     subtitle: "放量突破 / 回踩确认 / 止跌 / 阴线缩小 / 长下影 / 放量阴",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let report = patterns {
                    if report.hits.isEmpty {
                        Text("历史长度不足，无法识别 K 线形态。").font(.footnote).foregroundStyle(sem.ink3)
                    } else {
                        ForEach(Array(report.hits.enumerated()), id: \.element.kind) { idx, hit in
                            patternRow(hit)
                            if idx < report.hits.count - 1 { Divider().background(sem.hairline) }
                        }
                    }
                } else {
                    Text("日线数据不足，暂无法识别。").font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func patternRow(_ hit: CandlePatternHit) -> some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.kind.title).font(.subheadline).foregroundStyle(sem.ink)
                Spacer(minLength: 0)
                if hit.detected {
                    Text("已识别").font(.caption2.bold()).foregroundStyle(sem.ok)
                } else {
                    Text("未识别").font(.caption2).foregroundStyle(sem.ink3)
                }
            }
            if let note = hit.notes.first {
                Text(note).font(.caption2)
                    .foregroundStyle(hit.detected ? sem.ink2 : sem.ink3)
            }
            if hit.detected {
                HStack(spacing: 6) {
                    Capsule().fill(sem.ink3.opacity(0.3))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(sem.accent)
                                .frame(width: max(8, CGFloat(hit.strength) * 140), height: 4)
                        }
                    Text(String(format: "强度 %.0f%%", hit.strength * 100))
                        .font(.caption2).foregroundStyle(sem.ink3)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - 量价分析

    private var volumeCard: some View {
        ResearchCard(title: "量价分析",
                     subtitle: "量能 vs 20日均量 · 价量关系",
                     badge: "实验级 · 观察证据") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let vol = volume, let latest = vol.latest {
                    row(label: "最新量 / 20日均量") {
                        if let r = latest.volumeToMA20 {
                            Text(String(format: "%.2f×", r))
                                .font(.subheadline.bold())
                                .foregroundStyle(r >= 1.5 ? sem.warn : (r >= 1.0 ? sem.accent : sem.ink2))
                        } else { Text("—").foregroundStyle(sem.ink3) }
                    }
                    row(label: "量能状态") {
                        Text(volumeStateTitle(latest.state)).font(.subheadline).foregroundStyle(sem.ink2)
                    }
                    row(label: "价量关系") {
                        Text(priceVolumeTitle(latest.priceVolumeRelation)).font(.caption).foregroundStyle(sem.ink2)
                    }
                    row(label: "连续放量 / 缩量") {
                        Text("\(latest.consecutiveExpansionCount) 天放量 / \(latest.consecutiveContractionCount) 天缩量")
                            .font(.caption).foregroundStyle(sem.ink3)
                    }
                    if !latest.isFinal {
                        Text("当前 K 线尚未收盘，量能为形成中估算。").font(.caption2).foregroundStyle(sem.warn)
                    }
                } else {
                    Text("成交量数据不足，暂无法分析。").font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        let sem = ThemeSemantics.of(appearance)
        return HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(sem.ink)
            Spacer(minLength: 0)
            content()
        }
    }

    private func volumeStateTitle(_ s: VolumeState) -> String {
        switch s {
        case .unavailable: return "不可用"
        case .formingProvisional: return "形成中（估算）"
        case .aboveSameTimeBaseline: return "高于同进度基线"
        case .belowSameTimeBaseline: return "低于同进度基线"
        case .atSameTimeBaseline: return "持平同进度基线"
        }
    }

    private func priceVolumeTitle(_ p: PriceVolumeRelation) -> String {
        switch p {
        case .unavailable: return "不可用"
        case .provisional: return "形成中"
        case .priceUpVolumeAboveBaseline: return "价涨量增"
        case .priceUpVolumeAtOrBelowBaseline: return "价涨量平/缩"
        case .priceDownVolumeAboveBaseline: return "价跌量增（派发？）"
        case .priceDownVolumeAtOrBelowBaseline: return "价跌量缩（惜售？）"
        case .unchangedPriceVolumeAboveBaseline: return "价平量增"
        case .unchangedPriceVolumeAtOrBelowBaseline: return "价平量缩"
        }
    }

    // MARK: - 诚实声明

    private var disclaimerCard: some View {
        let sem = ThemeSemantics.of(appearance)
        return VStack(alignment: .leading, spacing: 4) {
            Text("诚实声明").font(.caption.bold()).foregroundStyle(sem.ink2)
            Text("本页全部为「本机规则计算的观察材料」，evidenceLevel = experimental：只描述历史与当下形态，不预测、不构成买卖建议，也不对收益负责。绿柱缩短、金叉、形态识别均属实验级证据，禁止单独翻成买入。信号与六维评分、技术指标评分、AI 顾问相互独立；最新 K 线未收盘时一律标记「未确认」。NAS 不可用不影响本页（本地离线计算）。")
                .font(.caption2).foregroundStyle(sem.ink3)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 市场环境（复用本机 MarketRegime 引擎）

    private var marketRegimeCard: some View {
        ResearchCard(title: "市场环境（上证指数）",
                     subtitle: "指数环境 · 多周期均线结构",
                     badge: "观察级别") {
            let sem = ThemeSemantics.of(appearance)
            let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
            VStack(alignment: .leading, spacing: layout.gap) {
                if let r = regime {
                    HStack {
                        Text(r.regime.title)
                            .font(.headline.bold())
                            .foregroundStyle(sem.ink)
                        Spacer(minLength: 0)
                        Text(r.riskLevel.title)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(riskTint(r.riskLevel, sem: sem).opacity(0.16)))
                            .foregroundStyle(riskTint(r.riskLevel, sem: sem))
                    }
                    HStack(spacing: 16) {
                        if let v = r.return5Sessions { metric("近 5 日", v, sem: sem) }
                        if let v = r.return20Sessions { metric("近 20 日", v, sem: sem) }
                        if let v = r.drawdown20Sessions { metric("20 日回撤", v, sem: sem) }
                    }
                    HStack(spacing: 6) {
                        Text("置信度 \(r.confidenceLabel)")
                            .font(.caption2).foregroundStyle(sem.ink3)
                        if let d = r.dataAsOf {
                            Text("· 截至 \(MarketCalendar.isoDay(d))")
                                .font(.caption2).foregroundStyle(sem.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                    if r.observationOnly {
                        HStack(spacing: 6) {
                            Image(systemName: "eye").font(.caption2)
                            Text("观察级别：可据此调整节奏，不构成买卖指令")
                                .font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(sem.ink2)
                    }
                    if !r.reasons.isEmpty {
                        ForEach(Array(r.reasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                            Text("· " + reason).font(.caption2).foregroundStyle(sem.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("上证指数日线不足 60 个交易日，暂无法判定市场环境（去行情页刷新一次即可）。")
                        .font(.footnote).foregroundStyle(sem.ink3)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: Double, sem: ThemeSemantics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(sem.ink3)
            Text(value.pct(2)).font(.subheadline.bold()).monospacedDigit()
                .foregroundStyle(PnLColor.of(value))
        }
    }

    private func riskTint(_ level: MarketRiskLevel, sem: ThemeSemantics) -> Color {
        switch level {
        case .r0Normal: return sem.ink2
        case .r1Elevated: return sem.warn
        case .r2High, .r3Severe, .r4Extreme: return sem.danger
        }
    }
}

// MARK: - 双主题卡片容器

private struct ResearchCard<Content: View>: View {
    @Environment(\.appAppearance) private var appearance
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let sem = ThemeSemantics.of(appearance)
        let layout = ThemeLayout.of(AppAppearance.resolved(appearance))
        VStack(alignment: .leading, spacing: layout.gap) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(sem.ink)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(sem.ink3)
                    }
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(sem.warn.opacity(0.16)))
                        .foregroundStyle(sem.warn)
                }
            }
            content()
        }
        .padding(layout.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
                .fill(sem.card)
                .shadow(color: Color.black.opacity(layout.shadowOpacity), radius: layout.shadowRadius, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: layout.radius, style: .continuous)
                        .strokeBorder(sem.hairline, lineWidth: 1)
                )
        )
    }
}
