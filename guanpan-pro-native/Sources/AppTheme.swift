import SwiftUI

/// 每个外观主题一套独立底色，让「换主题」在视觉上立刻可分辨。
///
/// 背景：此前主题只影响 `preferredColorScheme`（深/浅）与 `tint`（强调色），
/// 而 10 个深色主题全部返回 `.dark`，互相之间除了强调色几乎看不出差别 ——
/// 用户因此觉得「主题更换不起作用」。现在每个主题自带底色渐变与卡片色调。
struct AppTheme {
    var top: Color
    var bottom: Color
    /// 列表分区背景的叠加色，用于把卡片从底色里托起来。
    var surface: Color
    var isLight: Bool

    static func palette(for appearance: AppAppearance) -> AppTheme {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        switch appearance {
        case .system:
            return AppTheme(top: c(14, 16, 22), bottom: c(8, 9, 13), surface: .black.opacity(0.22), isLight: false)
        case .dark:      // 深空灰
            return AppTheme(top: c(28, 30, 36), bottom: c(14, 15, 19), surface: .black.opacity(0.26), isLight: false)
        case .oled:      // 纯黑 OLED
            return AppTheme(top: .black, bottom: .black, surface: .black.opacity(0.42), isLight: false)
        case .blue:      // 午夜蓝
            return AppTheme(top: c(10, 24, 52), bottom: c(4, 10, 26), surface: .black.opacity(0.24), isLight: false)
        case .green:     // 松墨绿
            return AppTheme(top: c(9, 34, 28), bottom: c(4, 16, 14), surface: .black.opacity(0.24), isLight: false)
        case .purple:    // 暗夜紫
            return AppTheme(top: c(28, 16, 52), bottom: c(12, 7, 26), surface: .black.opacity(0.24), isLight: false)
        case .sakura:    // 樱花粉
            return AppTheme(top: c(48, 20, 34), bottom: c(22, 9, 18), surface: .black.opacity(0.22), isLight: false)
        case .cyber:     // 赛博朋克
            return AppTheme(top: c(6, 26, 48), bottom: c(30, 6, 40), surface: .black.opacity(0.20), isLight: false)
        case .amber:     // 琥珀金
            return AppTheme(top: c(48, 32, 8), bottom: c(22, 14, 4), surface: .black.opacity(0.22), isLight: false)
        case .coffee:    // 拿铁棕
            return AppTheme(top: c(44, 28, 18), bottom: c(20, 12, 8), surface: .black.opacity(0.24), isLight: false)
        case .graphite:  // 石墨灰
            return AppTheme(top: c(38, 40, 44), bottom: c(20, 21, 24), surface: .black.opacity(0.28), isLight: false)
        case .light:     // 明亮白
            return AppTheme(top: c(238, 242, 250), bottom: c(222, 228, 240), surface: .white.opacity(0.34), isLight: true)
        case .paper:     // 纸白
            return AppTheme(top: c(250, 246, 236), bottom: c(238, 232, 218), surface: c(255, 252, 244).opacity(0.42), isLight: true)
        case .mint:      // 薄荷
            return AppTheme(top: c(228, 248, 242), bottom: c(206, 238, 228), surface: .white.opacity(0.36), isLight: true)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}
