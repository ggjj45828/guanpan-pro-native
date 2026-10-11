import SwiftUI

/// 账户/持仓页的小卡片排版组件。
///
/// 目的：网页版持仓页一张卡里塞了十来个数字（总资产、总盈亏、仓位、今日盈亏…），
/// App 原来只有零散几行 `LabeledContent`，信息密度差很多。
/// 这里统一成「大数字 + 3 列小格」，标签 10px、数值 13px，字体缩小但信息量翻倍。

/// 单个指标格：标题 10px 次要色，数值 13px 半粗等宽数字，可选涨跌染色。
struct MetricCell: View {
    var title: String
    var value: String
    /// nil = 中性色；否则 >=0 红、<0 绿（国内红涨绿跌）
    var toneValue: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(10)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .scaledFont(13, weight: .semibold, design: .rounded)
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

/// 半透明磨砂卡片底，配合自定义背景图也能读清。带 tone 时给卡片上色。
private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var tone: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(12)
            .photoPanelBackground(cornerRadius: 14,
                fallback: scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.62),
                tone: tone)
    }
}

/// Applies the web app's photo-imprinted translucent panel style to native cards.
/// The opacity slider now changes both the wallpaper veil and the card scrim.
private struct PhotoPanelBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("guanpan.native.background.revision") private var backgroundRevision = 0
    @AppStorage("guanpan.native.background.overlayOpacity") private var overlayOpacity = 0.48
    @AppStorage("guanpan.native.background.panelImprint") private var panelImprint = true
    let cornerRadius: CGFloat
    let fallback: Color
    /// 非 nil 时给卡片上色（网页版 .sum / .ai / .gauge 那类彩色区块）。
    /// App 原来所有卡片都是系统灰白，看起来「没有颜色」——不是苹果限制，只是没上色。
    var tone: Color? = nil

    func body(content: Content) -> some View {
        let _ = backgroundRevision
        let usePhotoPanel = panelImprint && NativeBackgroundStore.hasActiveBackground
        // Slider 值直接控制面板遮罩；之前强行限制在 38% 以上，拖到最透明也几乎看不出变化。
        let veil = min(0.82, max(0.04, overlayOpacity))
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // 用 AnyShapeStyle 统一两条分支的类型：Swift 的 opaque return type 要求
        // 函数体所有 return 的底层类型一致，直接返回 LinearGradient / Color 会编译失败。
        let fillStyle: AnyShapeStyle
        let strokeStyle: AnyShapeStyle
        let strokeWidth: CGFloat
        if let tone {
            // 有色调时优先用色调渐变（对齐网页版 .sum / .ai / .gauge 彩色区块）
            fillStyle = AnyShapeStyle(LinearGradient(
                colors: [tone.opacity(scheme == .dark ? 0.30 : 0.17),
                         tone.opacity(scheme == .dark ? 0.10 : 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            strokeStyle = AnyShapeStyle(tone.opacity(scheme == .dark ? 0.38 : 0.30))
            strokeWidth = 1
        } else {
            fillStyle = AnyShapeStyle(usePhotoPanel
                ? (scheme == .dark ? Color.black : Color.white).opacity(veil)
                : fallback)
            strokeStyle = AnyShapeStyle(Color.primary.opacity(0.10))
            strokeWidth = 0.5
        }
        return content
            .background(shape.fill(fillStyle))
            .overlay(shape.strokeBorder(strokeStyle, lineWidth: strokeWidth))
            .clipShape(shape)
    }
}

extension View {
    func cardSurface(tone: Color? = nil) -> some View { modifier(CardSurfaceModifier(tone: tone)) }
    func photoPanelBackground(cornerRadius: CGFloat, fallback: Color, tone: Color? = nil) -> some View {
        modifier(PhotoPanelBackgroundModifier(cornerRadius: cornerRadius, fallback: fallback, tone: tone))
    }
}
