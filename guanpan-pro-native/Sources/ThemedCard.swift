import SwiftUI

// MARK: - 彩色卡片（对齐网页版的彩色区块）
//
// 网页版的「市场情绪」是绿→灰→红的渐变条 + 指针，汇总卡和 AI 卡各有自己的彩色底
// （.gauge / .sum / .ai）。SwiftUI 的 List 行默认是系统灰白底，所以 App 看起来
// 「全是白卡片，没有颜色」——这不是苹果的限制，只是没给行背景上色。
// 这里统一提供彩色卡片背景与情绪量尺，颜色跟随主题深浅自动调整透明度。

/// 页面级配色：把「某段数值该用什么颜色」收敛到一处，
/// 免得每个页面各写一遍红涨绿跌的阈值（阈值不一致时同一页会出现两种红）。
enum CardTone {
    /// 网页版 `.ai` 区块的强调紫，用于顾问/AI 结果卡。
    static let accent = Color(red: 0.61, green: 0.42, blue: 1.0)
    /// 网页版警示/待确认区块的琥珀色。
    static let warn = Color(red: 0.98, green: 0.66, blue: 0.20)
    /// 数据新鲜、对账一致等「状态良好」的蓝绿。
    static let ok = Color(red: 0.16, green: 0.68, blue: 0.80)

    /// 按金额/百分比取涨跌色。`epsilon` 用于吸收浮点噪声，
    /// 避免 0.001 元也被染成红色。
    static func pnl(_ value: Double, epsilon: Double = 0.005) -> Color? {
        value > epsilon ? PnLColor.up : value < -epsilon ? PnLColor.down : nil
    }

    /// 条件成立时用警示色，否则不加色。
    /// 直接写 `flag ? warn : nil` 也能编译，但三元里混 `Color` 与 `nil`
    /// 在复杂表达式里偶尔会让类型检查器报 "mismatching types"，包一层更稳。
    static func warnIf(_ flag: Bool) -> Color? { flag ? warn : nil }
}

/// 彩色卡片底：低透明度渐变 + 同色描边，让卡片从背景里托起来。
struct ToneCardBackground: View {
    let tone: Color?
    let isLight: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let tone {
                shape
                    .fill(LinearGradient(
                        colors: [tone.opacity(isLight ? 0.18 : 0.26),
                                 tone.opacity(isLight ? 0.06 : 0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.strokeBorder(tone.opacity(isLight ? 0.26 : 0.34), lineWidth: 1))
            } else {
                // 中性卡面：仍然给一张「看得见的卡」，
                // 否则浅色主题下 Section 会直接融进白底，又变成用户说的「全是白的」。
                shape
                    .fill((isLight ? Color.white : Color.black).opacity(isLight ? 0.52 : 0.30))
                    .overlay(shape.strokeBorder(Color.primary.opacity(isLight ? 0.07 : 0.10), lineWidth: 0.5))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}

extension View {
    /// 给列表行套一张卡片。用 listRowBackground 注入，不参与行内容布局，
    /// 因此不会像背景图那样把页面撑乱。`tone` 为 nil 时只画中性卡面。
    func toneCard(_ tone: Color?, isLight: Bool) -> some View {
        listRowBackground(ToneCardBackground(tone: tone, isLight: isLight))
    }

    /// 给整段 Section 铺中性卡面（不染色），用于页面里那些纯叙述性的分区。
    func plainCard(isLight: Bool) -> some View {
        listRowBackground(ToneCardBackground(tone: nil, isLight: isLight))
    }
}

/// 情绪分档的统一口径：阈值和文案只定义一次。
///
/// 首页的「市场情绪」和持仓页各模块的「本模块今日涨跌」都用这一套 ——
/// 分开写两份的话，同一个平均涨跌幅在两个页面迟早出现不同的标签或颜色。
/// 入参统一是**百分数**（例如 0.42 表示 +0.42%），与 `pct()` 的口径一致。
enum MoodScale {
    /// 偏强 / 微暖 / 中性 / 偏弱 / 疲弱
    static func label(_ strength: Double) -> String {
        if strength >= 1.5 { return "偏强" }
        if strength >= 0.3 { return "微暖" }
        if strength > -0.3 { return "中性" }
        if strength > -1.5 { return "偏弱" }
        return "疲弱"
    }

    /// 卡片底色：国内红涨绿跌，中性走灰。
    static func tone(_ strength: Double) -> Color {
        if strength >= 0.3 { return PnLColor.up }
        if strength <= -0.3 { return PnLColor.down }
        return Color.gray
    }

    /// 文字/角标的前景色。中性时回落到次要色 ——
    /// 纯灰 `.gray` 在浅色主题的灰卡上会糊成一片，读不出来。
    static func foreground(_ strength: Double) -> Color {
        let tone = tone(strength)
        return tone == Color.gray ? Color.secondary : tone
    }

    /// 角标底：跟着前景色走，中性时用次级填充。
    static func badgeBackground(_ strength: Double) -> Color {
        tone(strength).opacity(0.18)
    }
}

/// 情绪量尺：绿（弱）→ 灰（中）→ 红（强）渐变条 + 白色指针。
/// 与网页版 .gbar 是同一套观感；中国市场惯例红涨绿跌。
struct MoodGauge: View {
    /// 平均涨跌幅，单位是百分数（例如 0.42 表示 +0.42%）
    let average: Double

    var body: some View {
        GeometryReader { geo in
            // ±1.5% 打满两端；超出只把指针顶到头，不溢出色条
            let clamped = min(max(average / 1.5, -1), 1)
            let x = geo.size.width * (0.5 + clamped * 0.5)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(colors: [PnLColor.down, Color.gray.opacity(0.45), PnLColor.up],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 7)
                    .offset(y: 4)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 3, height: 15)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: max(0, min(geo.size.width - 3, x - 1.5)))
            }
        }
        .frame(height: 15)
        .accessibilityLabel("市场情绪量尺，平均涨跌幅 \(average.pct(2))")
    }
}
