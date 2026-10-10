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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
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

/// 半透明磨砂卡片底，配合自定义背景图也能读清。
private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurfaceModifier()) }
}
