import SwiftUI

// MARK: - 彩色卡片（对齐网页版的彩色区块）
//
// 网页版的「市场情绪」是绿→灰→红的渐变条 + 指针，汇总卡和 AI 卡各有自己的彩色底
// （.gauge / .sum / .ai）。SwiftUI 的 List 行默认是系统灰白底，所以 App 看起来
// 「全是白卡片，没有颜色」——这不是苹果的限制，只是没给行背景上色。
// 这里统一提供彩色卡片背景与情绪量尺，颜色跟随主题深浅自动调整透明度。

/// 彩色卡片底：低透明度渐变 + 同色描边，让卡片从背景里托起来。
struct ToneCardBackground: View {
    let tone: Color
    let isLight: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(
                colors: [tone.opacity(isLight ? 0.18 : 0.26),
                         tone.opacity(isLight ? 0.06 : 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tone.opacity(isLight ? 0.26 : 0.34), lineWidth: 1)
            )
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
    }
}

extension View {
    /// 给列表行套一张彩色卡片。用 listRowBackground 注入，不参与行内容布局，
    /// 因此不会像背景图那样把页面撑乱。
    func toneCard(_ tone: Color, isLight: Bool) -> some View {
        listRowBackground(ToneCardBackground(tone: tone, isLight: isLight))
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
