import SwiftUI

// MARK: - 动态字体适配
//
// 问题：v2.3 为了「字体变小、内容变多」，把大量字号写死成 9/10/11/13 pt。
// 写死字号有两个副作用：
//   1) 系统「设置 → 显示与亮度 → 文字大小」调大后，App 完全不响应；
//   2) 视力不佳的用户无法放大，只能靠 App 内重新排版。
//
// 解法分两层：
//   · 系统层：读取 @Environment(\.dynamicTypeSize) 换算成倍率（并做上限封顶，
//     避免无障碍超大档位把紧凑网格撑破）；
//   · App 层：新增「字号」设置（0.9 / 1.0 / 1.1 / 1.25），与系统倍率相乘。
// 两者相乘后仍对最小字号做 9pt 兜底，紧凑但不缩成难以辨认的小字。

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// App 内字号倍率，由设置页「字号」控制，默认 1.0（标准）。
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

extension View {
    func appFontScale(_ value: CGFloat) -> some View {
        environment(\.appFontScale, value)
    }
}

private struct ScaledFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    @Environment(\.appFontScale) private var appFontScale
    /// 基准 17pt 是系统默认 .body 字号。@ScaledMetric 会随「设置 → 显示与亮度 → 文字大小」
    /// 变化，相除即得系统倍率；再乘上 App 内倍率。
    @ScaledMetric(relativeTo: .body) private var bodyMetric: CGFloat = 17

    func body(content: Content) -> some View {
        // 上下限：太小读不清，太大（无障碍档位）会把紧凑数字网格撑到互相遮挡。
        let systemFactor = min(max(bodyMetric / 17, 0.85), 1.6)
        return content.font(.system(size: max(size * systemFactor * appFontScale, 9),
                                    weight: weight, design: design))
    }
}

extension View {
    /// 替代 `.font(.system(size:))`：写死的基准字号会被系统动态字号与 App 内字号倍率共同缩放。
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

// MARK: - 字号档位

enum FontScalePreset: String, CaseIterable, Identifiable {
    case small = "small"
    case standard = "standard"
    case large = "large"
    case extraLarge = "extraLarge"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "紧凑"
        case .standard: return "标准"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }

    var value: Double {
        switch self {
        case .small: return 0.9
        case .standard: return 1.0
        case .large: return 1.1
        case .extraLarge: return 1.25
        }
    }

    static func preset(for value: Double) -> FontScalePreset {
        allCases.min(by: { abs($0.value - value) < abs($1.value - value) }) ?? .standard
    }
}
