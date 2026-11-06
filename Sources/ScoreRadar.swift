import SwiftUI

// MARK: - 六维评分雷达
//
// 「值不值得买」不该只给一个总分：同样是 70 分，有的标的是趋势强但位置高，
// 有的是位置便宜但趋势还在往下。拆成六维之后，用户才知道这个分数是怎么来的、
// 哪一维是自己不认可的。
//
// 口径说明（必须诚实）：
// · 本机只有日线 + 当前报价，没有 PE/PB、没有资金流明细，所以**不做基本面估值**。
//   第二维叫「位置」，是现价在近 250 日区间里的分位（越低越接近历史便宜区），
//   不等于估值便宜。
// · 每一维都在 0…100，缺数据的维度直接不显示，不用 50 分凑数。

struct RadarDimension: Identifiable {
    enum Kind: String, CaseIterable {
        case trend, position, volume, momentum, risk, odds

        var title: String {
            switch self {
            case .trend: return "趋势"
            case .position: return "位置"
            case .volume: return "量能"
            case .momentum: return "动量"
            case .risk: return "风险"
            case .odds: return "赔率"
            }
        }
    }

    let kind: Kind
    /// 0…100
    let value: Double
    /// 这一维的分是怎么算出来的，一句话。
    let note: String

    var id: String { kind.rawValue }
}

struct RadarResult {
    let dimensions: [RadarDimension]
    /// 有数据维度的平均值；维度少于 3 个时为 nil（不拿两维的平均冒充结论）。
    let total: Double?
    let summary: String

    var hasEnoughData: Bool { dimensions.count >= 3 }
}

enum RadarEngine {
    /// 全部输入都来自本机已有的日线，不发起请求。
    static func evaluate(bars: [DailyBar]) -> RadarResult? {
        let source = Array(bars.suffix(250))
        guard source.count >= 30, let last = source.last else { return nil }
        let close = last.close
        guard close > 0 else { return nil }

        var dims: [RadarDimension] = []
        let closes = source.map(\.close)

        if let trend = trendScore(source: source, close: close) {
            dims.append(RadarDimension(kind: .trend, value: trend.value, note: trend.note))
        }
        if let position = positionScore(closes: closes, close: close) {
            dims.append(RadarDimension(kind: .position, value: position.value, note: position.note))
        }
        if let volume = volumeScore(source: source) {
            dims.append(RadarDimension(kind: .volume, value: volume.value, note: volume.note))
        }
        if let momentum = momentumScore(closes: closes) {
            dims.append(RadarDimension(kind: .momentum, value: momentum.value, note: momentum.note))
        }
        if let risk = riskScore(source: source) {
            dims.append(RadarDimension(kind: .risk, value: risk.value, note: risk.note))
        }
        if let odds = oddsScore(source: source, close: close) {
            dims.append(RadarDimension(kind: .odds, value: odds.value, note: odds.note))
        }

        let total = dims.count >= 3 ? dims.map(\.value).reduce(0, +) / Double(dims.count) : nil
        return RadarResult(dimensions: dims, total: total, summary: summary(dims: dims, total: total))
    }

    private static func average(_ values: [Double], _ window: Int) -> Double? {
        guard values.count >= window, window > 0 else { return nil }
        let slice = values.suffix(window)
        return slice.reduce(0, +) / Double(slice.count)
    }

    private static func trendScore(source: [DailyBar], close: Double) -> (value: Double, note: String)? {
        let closes = source.map(\.close)
        guard let ma20 = average(closes, 20), let ma60 = average(closes, 60),
              let ma5 = average(closes, 5), let ma10 = average(closes, 10) else { return nil }
        var score = 0.0
        var hits: [String] = []
        if close >= ma20 { score += 25; hits.append("站上 MA20") } else { hits.append("破 MA20") }
        if ma20 >= ma60 { score += 25; hits.append("MA20 在 MA60 之上") } else { hits.append("MA20 在 MA60 之下") }
        if ma5 >= ma10 && ma10 >= ma20 { score += 25; hits.append("短均线多头排列") }
        let change20 = closes.count > 20 ? (close / closes[closes.count - 21] - 1) * 100 : 0
        if change20 > 0 { score += 25 }
        return (min(100, score), "近 20 日 \(change20.num(1))%；" + hits.joined(separator: "、"))
    }

    private static func positionScore(closes: [Double], close: Double) -> (value: Double, note: String)? {
        guard let high = closes.max(), let low = closes.min(), high > low else { return nil }
        let percentile = (close - low) / (high - low)
        let value = (1 - percentile) * 100
        return (value, "现价处于近 \(closes.count) 日区间 \(percentile.pct(0)) 分位（越高越接近区间顶部）")
    }

    private static func volumeScore(source: [DailyBar]) -> (value: Double, note: String)? {
        let volumes = source.map(\.volume).filter { $0 > 0 }
        guard let last = source.last, last.volume > 0,
              let avg = average(volumes, 20), avg > 0 else { return nil }
        let ratio = last.volume / avg
        let value = min(100, ratio / 2 * 100)
        return (value, "当日量能为 20 日均量的 \(ratio.num(2)) 倍")
    }

    private static func momentumScore(closes: [Double]) -> (value: Double, note: String)? {
        guard closes.count >= 6 else { return nil }
        let change5 = (closes[closes.count - 1] / closes[closes.count - 6] - 1) * 100
        // 把 -5%…+5% 映射到 0…100，超出部分截断。
        let value = min(100, max(0, (change5 + 5) / 10 * 100))
        return (value, "近 5 日 \(change5.num(2))%")
    }

    private static func riskScore(source: [DailyBar]) -> (value: Double, note: String)? {
        guard source.count >= 21 else { return nil }
        var returns: [Double] = []
        for i in 1..<source.count {
            let prev = source[i - 1].close
            guard prev > 0 else { continue }
            returns.append(source[i].close / prev - 1)
        }
        guard returns.count >= 20 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count)
        let dailyVol = variance.squareRoot()
        // 日波动 0.5% 视为很稳，2.5% 视为很抖。
        let value = min(100, max(0, (1 - (dailyVol - 0.005) / 0.02) * 100))
        let drawdown = maxDrawdown(source.map(\.close))
        return (value, "日波动 \(dailyVol.pct(2))；区间最大回撤 \(drawdown.pct(1))")
    }

    private static func oddsScore(source: [DailyBar], close: Double) -> (value: Double, note: String)? {
        guard let level = SupportResistanceCalculator.evaluate(source) else { return nil }
        guard let up = level.nearestResistance, let down = level.nearestSupport,
              up > close, down < close else { return nil }
        let upside = up - close
        let downside = close - down
        guard downside > 0 else { return nil }
        let ratio = upside / downside
        // 1:1 得 50 分，3:1 以上给满分。
        let value = min(100, max(0, ratio / 3 * 100))
        return (value, "上方空间 \(upside.num(3))（\(level.resistanceRoomPercent?.pct(1) ?? "--")），下方空间 \(downside.num(3))（\(level.supportRoomPercent?.pct(1) ?? "--")）")
    }

    private static func maxDrawdown(_ closes: [Double]) -> Double {
        var peak = closes.first ?? 0
        var worst = 0.0
        for close in closes {
            if close > peak { peak = close }
            guard peak > 0 else { continue }
            worst = min(worst, close / peak - 1)
        }
        return worst * 100
    }

    private static func summary(dims: [RadarDimension], total: Double?) -> String {
        guard let total else { return "有效维度不足 3 个，先不评分 —— 数据不够时给分等于编。" }
        let strongest = dims.max { $0.value < $1.value }
        let weakest = dims.min { $0.value < $1.value }
        var text = "综合 \(total.num(0)) 分（本机规则分，不含 PE/PB 等基本面）"
        if let strongest, let weakest, strongest.kind != weakest.kind {
            text += "；最强是\(strongest.kind.title) \(strongest.value.num(0))，最弱是\(weakest.kind.title) \(weakest.value.num(0))"
        }
        return text
    }
}

struct ScoreRadarView: View {
    let dimensions: [RadarDimension]
    var accent: Color = CardTone.accent

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = size / 2 - 18
            ZStack {
                ringLayer(center: center, radius: radius)
                dataLayer(center: center, radius: radius)
                ForEach(Array(dimensions.enumerated()), id: \.element.id) { index, dimension in
                    labelView(dimension, index: index, center: center, radius: radius)
                }
            }
        }
        .frame(height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dimensions.map { "\($0.kind.title) \($0.value.num(0)) 分" }.joined(separator: "，"))
    }

    private func ringLayer(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            gridPath(center: center, radius: radius)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.7)
            ForEach(Array(stride(from: 0.33, through: 1.0, by: 0.33)), id: \.self) { ratio in
                gridPath(center: center, radius: radius * ratio)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            }
            axisPath(center: center, radius: radius)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func dataLayer(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            valuePath(center: center, radius: radius).fill(accent.opacity(0.22))
            valuePath(center: center, radius: radius).stroke(accent, lineWidth: 1.6)
        }
    }

    /// 第 index 个顶点的角度（从 12 点方向起，顺时针）。
    ///
    /// 单独抽成函数是因为：这个角度表达式直接写在 `Path` / `View` 的构造里时，
    /// Swift 的类型检查器会推断到超时（CI 上已连续踩两次 "unable to type-check"）。
    /// 给它一个明确的返回类型，推断就有落点了。
    private func angle(at index: Int, count: Int) -> Double {
        let safeCount = max(3, count)
        let step: Double = 2.0 * Double.pi / Double(safeCount)
        let base: Double = -Double.pi / 2.0
        return base + Double(index) * step
    }

    private func points(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        let count = max(3, dimensions.count)
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let radians = angle(at: index, count: count)
            let dx: CGFloat = radius * CGFloat(cos(radians))
            let dy: CGFloat = radius * CGFloat(sin(radians))
            result.append(CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return result
    }

    private func gridPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let pts = points(center: center, radius: radius)
        guard let first = pts.first else { return path }
        path.move(to: first)
        for point in pts.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func axisPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for point in points(center: center, radius: radius) {
            path.move(to: center)
            path.addLine(to: point)
        }
        return path
    }

    private func valuePath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let count = dimensions.count
        guard count >= 3 else { return path }
        var angles: [Double] = []
        angles.reserveCapacity(count)
        for index in 0..<count { angles.append(angle(at: index, count: count)) }
        for (index, dimension) in dimensions.enumerated() {
            // 拆成三个局部量：写成一行嵌套表达式会让类型检查器直接超时（已在 CI 上踩过）。
            let clamped = min(100.0, max(0.0, dimension.value))
            let ratio = CGFloat(clamped / 100)
            let angle = angles[index]
            let dx = radius * ratio * CGFloat(cos(angle))
            let dy = radius * ratio * CGFloat(sin(angle))
            let point = CGPoint(x: center.x + dx, y: center.y + dy)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func labelView(_ dimension: RadarDimension, index: Int, center: CGPoint, radius: CGFloat) -> some View {
        let count = max(3, dimensions.count)
        let radians = angle(at: index, count: count)
        let offset: CGFloat = radius + 14
        let dx: CGFloat = offset * CGFloat(cos(radians))
        let dy: CGFloat = offset * CGFloat(sin(radians))
        let point = CGPoint(x: center.x + dx, y: center.y + dy)
        return VStack(spacing: 0) {
            Text(dimension.kind.title)
                .scaledFont(9, weight: .medium)
                .foregroundStyle(.secondary)
            Text(dimension.value.num(0))
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(.primary)
        }
        .position(point)
    }
}

struct ScoreRadarCard: View {
    let result: RadarResult
    /// 放进 List 的 Section 里时关掉自带底色，避免「卡片套卡片」。
    var showsBackground: Bool = true
    @Environment(\.appAppearance) private var appearance

    private var palette: DsPalette { DsPalette.of(AppAppearance.resolved(appearance)) }

    /// 分数配色：66 分以上按「偏强」染红（国内红涨），33 以下按「偏弱」染绿。
    /// 写成函数而不是嵌套三元，避免在 ViewBuilder 里拖慢类型检查。
    private func scoreColor(_ value: Double) -> Color {
        if value >= 66 { return PnLColor.up }
        if value >= 33 { return palette.ink }
        return PnLColor.down
    }

    var body: some View {
        if showsBackground {
            content.dsSurface(palette, radius: DS.radius, padding: DS.pad)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                DsIconTile(symbol: "hexagon", tint: palette.accent, size: 30, palette: palette)
                VStack(alignment: .leading, spacing: 1) {
                    Text("值不值得买 · 六维")
                        .scaledFont(DS.fsRow, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text("本机规则计算，不联网")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 4)
                if let total = result.total {
                    Text(total.num(0))
                        .scaledFont(26, weight: .bold, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(total))
                }
            }

            if result.hasEnoughData {
                // 尺寸由 ScoreRadarView 自己定（内部 210pt），这里不要再套一层 frame，
                // 否则内层的固定高度会顶出外层，标签被裁掉。
                ScoreRadarView(dimensions: result.dimensions, accent: palette.accent)
                VStack(spacing: 8) {
                    ForEach(result.dimensions) { dimension in
                        dimensionRow(dimension)
                    }
                }
            } else {
                Text("日线不足，六维里能算的维度少于 3 个。补足历史行情再来看分数。")
                    .scaledFont(DS.fsLabel)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(result.summary)
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一维一行：名称 + 说明 + 迷你条 + 分值。条比数字更好扫读，
    /// 但分数值仍保留 —— 条只能看相对大小，看不出 62 与 66 这种边界。
    private func dimensionRow(_ dimension: RadarDimension) -> some View {
        let tint = scoreColor(dimension.value)
        let ratio = min(1, max(0, dimension.value / 100))
        return HStack(alignment: .center, spacing: 8) {
            Text(dimension.kind.title)
                .scaledFont(DS.fsMicro, weight: .semibold)
                .foregroundStyle(palette.ink2)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.cardSoft)
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 4)
            Text(dimension.value.num(0))
                .scaledFont(DS.fsMicro, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dimension.kind.title) \(dimension.value.num(0)) 分，\(dimension.note)")
    }
}
