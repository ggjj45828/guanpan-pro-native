import SwiftUI

/// 账户/持仓页的小卡片排版组件。
///
/// 目的：网页版持仓页一张卡里塞了十来个数字（总资产、总盈亏、仓位、今日盈亏…），
/// App 原来只有零散几行 `LabeledContent`，信息密度差很多。
/// 这里统一成「大数字 + 3 列小格」，标签 11pt、数值 14pt，兼顾密度和可读性。

/// 单个指标格：标题 11pt 次要色，数值 14pt 半粗等宽数字，可选涨跌染色。
struct MetricCell: View {
    var title: String
    var value: String
    /// nil = 中性色；否则 >=0 红、<0 绿（国内红涨绿跌）
    var toneValue: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .scaledFont(14, weight: .semibold, design: .rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(toneColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toneColor: Color {
        guard let v = toneValue else { return .primary }
        return v >= 0 ? Color(red: 0.93, green: 0.30, blue: 0.37) : Color(red: 0.07, green: 0.77, blue: 0.55)
    }
}

/// 固定列数网格。用显式数组而不是 ViewBuilder，
/// 避免在 List 里出现类型检查超时与 LazyVGrid 高度塌陷。
struct MetricGrid: View {
    var columns: Int = 3
    var spacing: CGFloat = 10
    var cells: [MetricCell]

    private var rows: [[MetricCell]] {
        let cols = max(1, columns)
        var out: [[MetricCell]] = []
        var index = 0
        while index < cells.count {
            out.append(Array(cells[index..<min(index + cols, cells.count)]))
            index += cols
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cell
                    }
                    if row.count < columns {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// 不透明卡片底。带 tone 时只叠加轻量色调，不使用毛玻璃或透出下层内容。
private struct CardSurfaceModifier: ViewModifier {
    var tone: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(AppLayout.cardPadding)
            .cardPanelBackground(cornerRadius: AppLayout.cardRadius,
                fallback: .clear,
                tone: tone)
    }
}

/// 卡片底：带 tone 时给卡片上色，否则铺一层中性卡面。
///
/// v2.12 起图片 / 渐变背景整组下线，原来只服务于「背景图 + 半透明卡片」的
/// `overlayOpacity` / `panelImprint` 两个开关也一并没了入口，所以这里不再读它们，
/// 也不再有「照片面板」分支 —— 直接给固定的中性卡面：浅色主题偏白、深色主题偏亮，
/// 保证卡片在纯配色背景上仍能立起来。
private struct CardPanelBackgroundModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let fallback: Color
    /// 非 nil 时给卡片上色（网页版 .sum / .ai / .gauge 那类彩色区块）。
    /// App 原来所有卡片都是系统灰白，看起来「没有颜色」——不是苹果限制，只是没上色。
    var tone: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // 用 AnyShapeStyle 统一两条分支的类型：Swift 的 opaque return type 要求
        // 函数体所有 return 的底层类型一致，直接返回 LinearGradient / Color 会编译失败。
        let theme = AppTheme.palette(for: AppAppearance.resolved(appearance, colorScheme: colorScheme))
        let strokeStyle: AnyShapeStyle
        let strokeWidth: CGFloat
        if let tone {
            strokeStyle = AnyShapeStyle(tone.opacity(theme.isLight ? 0.36 : 0.52))
            strokeWidth = 1
        } else {
            strokeStyle = AnyShapeStyle(Color.primary.opacity(0.10))
            strokeWidth = 0.5
        }
        return content
            .background {
                shape.fill(theme.surface)
                if let tone {
                    shape.fill(tone.opacity(theme.isLight ? 0.08 : 0.13))
                }
            }
            .overlay(shape.strokeBorder(strokeStyle, lineWidth: strokeWidth).allowsHitTesting(false))
            .clipShape(shape)
    }
}

extension View {
    func cardSurface(tone: Color? = nil) -> some View { modifier(CardSurfaceModifier(tone: tone)) }
    func cardPanelBackground(cornerRadius: CGFloat, fallback: Color, tone: Color? = nil) -> some View {
        modifier(CardPanelBackgroundModifier(cornerRadius: cornerRadius, fallback: fallback, tone: tone))
    }
}
