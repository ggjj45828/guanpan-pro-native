import SwiftUI

// MARK: - 资产看板卡片组件（对齐参考设计稿的布局与配色）
//
// 设计语言（来自用户提供的三张参考图）：
// 浅色柔和画布 + 白色圆角卡片；首页资产用深蓝渐变大数「英雄卡」；
// 持仓结构用环形图；市场冷热用半圆仪表；快捷入口用彩色图标圆卡。
// 涨跌一律走 GPPalette.gpUp/gpDown（红涨绿跌），不用语义色冒充。

/// 资产曲线取件区间。账本里只有「每日一个点」的资产历史，没有分钟级，
/// 所以用 月/季/半年/年，而不是设计稿里配分时图的 日/周/月/年。
enum GPAssetRange: String, CaseIterable, Identifiable {
    case month, quarter, halfYear, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .month: return "月"
        case .quarter: return "季"
        case .halfYear: return "半年"
        case .year: return "年"
        }
    }
    var days: Int {
        switch self {
        case .month: return 30
        case .quarter: return 90
        case .halfYear: return 180
        case .year: return 365
        }
    }
}

/// 迷你走势（面积 + 描边）。数据少于 2 点时不画。
struct GPSparkline: View {
    let values: [Double]
    var color: Color = .white
    var lineWidth: CGFloat = 1.6
    var height: CGFloat = 30
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let span = max(hi - lo, 0.000_000_1)
                let pts: [CGPoint] = values.enumerated().map { index, value in
                    CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                            y: size.height * (1 - CGFloat((value - lo) / span)))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for point in pts { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: pts[0])
                        for point in pts.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
    }
}

/// 英雄卡内的区间选择胶囊（日/周/月/年 形态，值取自真实数据区间）。
struct GPRangePills: View {
    @Binding var selection: GPAssetRange
    var body: some View {
        HStack(spacing: 2) {
            ForEach(GPAssetRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.title)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == range ? Color(hex: 0x1B3E8F) : Color.white.opacity(0.82))
                        .background(selection == range ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.16), in: Capsule())
    }
}

/// 首页「账户总资产」英雄卡：深蓝渐变 + 大数 + 当日盈亏 + 区间胶囊 + 迷你走势。
struct GPHeroAssetCard: View {
    let totalText: String
    var totalCaption: String? = nil
    var changeText: String? = nil
    var changePercentText: String? = nil
    var infoText: String? = nil
    let history: [NextAssetPoint]
    @State private var range: GPAssetRange = .month
    @State private var showInfo = false

    private var rangePoints: [NextAssetPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) ?? .distantPast
        return history.filter { $0.date >= cutoff }
    }
    private var series: [Double] { rangePoints.map { NextNum.double($0.total) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("账户总资产").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.82))
                if let infoText {
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("总资产口径说明")
                }
                Spacer(minLength: 0)
            }
            Text(totalText)
                .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.72)
            if let changeText, let changePercentText {
                HStack(spacing: 8) {
                    Text("今日盈亏").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.72))
                    Text(changeText).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    Text(changePercentText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            if let totalCaption {
                Text(totalCaption).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.62))
            }
            if showInfo, let infoText {
                Text(infoText).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if series.count >= 2 {
                GPRangePills(selection: $range)
                GPSparkline(values: series, color: .white, lineWidth: 1.7, height: 76)
                HStack {
                    Text(axisLabel(rangePoints.first?.date))
                    Spacer(minLength: 0)
                    Text(axisLabel(rangePoints[rangePoints.count / 2].date))
                    Spacer(minLength: 0)
                    Text(axisLabel(rangePoints.last?.date))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(hex: 0x1B3E8F), Color(hex: 0x2A5FD0), Color(hex: 0x3E7BEB)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: Color(hex: 0x1F4FBE).opacity(0.28), radius: 14, x: 0, y: 8)
    }
    private func axisLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// 环形图一段。
struct GPDonutSegment: Identifiable {
    let id = UUID()
    let title: String
    let value: Double
    let color: Color
}

/// 持仓结构环形图（环 + 右侧图例）。百分比是份额型，保持 1 位小数。
struct GPDonutView: View {
    @Environment(\.gp) private var p
    let segments: [GPDonutSegment]
    var centerValue: String = ""
    var centerLabel: String = ""

    private var total: Double { segments.reduce(0) { $0 + max($1.value, 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("持仓结构").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
            HStack(spacing: 14) {
                ZStack {
                    if total > 0 {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let before = segments.prefix(index).reduce(0) { $0 + max($1.value, 0) }
                            let start = before / total
                            let end = (before + max(segment.value, 0)) / total
                            Circle()
                                .trim(from: start, to: max(end, start + 0.001))
                                .stroke(segment.color, style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }
                    } else {
                        Circle().stroke(p.line, lineWidth: 15)
                    }
                    VStack(spacing: 1) {
                        Text(centerValue).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.55)
                        Text(centerLabel).font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(segments) { segment in
                        HStack(spacing: 7) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.title).font(.system(size: 11)).foregroundStyle(p.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(total > 0 ? NextNum.percent(max(segment.value, 0) / total * 100, digits: 1) : "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(p.ink).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}

/// 市场温度半圆仪表（0–100）。颜色从「冷清」的青绿过渡到「过热」的红。
struct GPGaugeView: View {
    @Environment(\.gp) private var p
    let value: Double
    var caption: String
    var leftLabel: String = "冷清"
    var rightLabel: String = "过热"

    private var clamped: Double { NextNum.clamp(value, 0, 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("市场温度").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.5)
                    .stroke(LinearGradient(colors: [p.jade, p.chartGold, p.risk],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(180))
                    .frame(width: 104, height: 104)
                    .offset(y: 52)
                Capsule()
                    .fill(p.ink)
                    .frame(width: 2.5, height: 38)
                    .offset(y: 52)
                    .rotationEffect(.degrees(180 - 180 * clamped / 100))
                VStack(spacing: 1) {
                    Text("\(Int(clamped.rounded()))")
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(p.ink)
                    Text(caption).font(.system(size: 9)).foregroundStyle(p.muted)
                }
                .offset(y: 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .clipped()
            HStack {
                Text(leftLabel).font(.system(size: 9)).foregroundStyle(p.muted)
                Spacer(minLength: 0)
                Text(rightLabel).font(.system(size: 9)).foregroundStyle(p.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}

/// 快捷入口卡（彩色图标圆 + 标题 + 两行说明）。目标用现有路由，不新增功能名。
struct GPQuickActionCard: View {
    @Environment(\.gp) private var p
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let route: GPRoute

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        Circle().fill(tint.opacity(0.14)).frame(width: 30, height: 30)
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(p.muted)
                    .multilineTextAlignment(.leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// 小徽章（ETF / 股票 等类型标记）。
struct GPPillBadge: View {
    let text: String
    var color: Color = Color(hex: 0x3268E8)
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 统计小块（标签 + 大值 + 脚注），用于实验室 trio 等横排指标。
struct GPStatTile: View {
    @Environment(\.gp) private var p
    let label: String
    let value: String
    var footnote: String? = nil
    var emphasis: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(p.muted)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(emphasis ?? p.ink).lineLimit(1).minimumScaleFactor(0.75)
            if let footnote {
                Text(footnote).font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(emphasis ?? p.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}

/// 计划进度卡（本月计划入金 形态）：图标 + 金额 + 进度条 + 操作按钮。
struct GPPlanProgressCard: View {
    @Environment(\.gp) private var p
    let title: String
    let amountText: String
    var periodText: String = "/ 月"
    var progress: Double = 0
    let doneText: String
    let planText: String
    let footnote: String
    let actionTitle: String
    let action: () -> Void

    private var clamped: Double { NextNum.clamp(progress, 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(p.jade.opacity(0.14)).frame(width: 32, height: 32)
                    Image(systemName: "banknote.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.jade)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 0)
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.forest)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(p.tint, in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(amountText).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(p.ink)
                Text(periodText).font(.system(size: 11)).foregroundStyle(p.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.line).frame(height: 7)
                    Capsule().fill(p.jade).frame(width: geo.size.width * clamped, height: 7)
                }
            }
            .frame(height: 7)
            HStack {
                Text(doneText).font(.system(size: 10)).foregroundStyle(p.muted)
                Spacer(minLength: 0)
                Text(planText).font(.system(size: 10)).foregroundStyle(p.muted)
            }
            Text(footnote).font(.system(size: 9)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}

/// 策略宫格块（字母徽章 + 标题 + 说明）。
struct GPStrategyTile: View {
    @Environment(\.gp) private var p
    let letter: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 30, height: 30)
                Text(letter).font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
                Text(detail).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}
