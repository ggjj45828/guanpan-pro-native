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

// MARK: - 主题自带的深浅模式与强调色

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paper, .mint: return .light
        default: return .dark
        }
    }

    var accentColor: Color {
        switch self {
        case .oled, .dark, .graphite: return Color(red: 0.31, green: 0.55, blue: 1.0)
        case .light: return Color(red: 0.15, green: 0.39, blue: 0.92)
        case .blue: return Color(red: 0.30, green: 0.62, blue: 1.0)
        case .green: return Color(red: 0.24, green: 0.79, blue: 0.63)
        case .purple: return Color(red: 0.66, green: 0.42, blue: 1.0)
        case .sakura: return Color(red: 1.0, green: 0.47, blue: 0.69)
        case .cyber: return Color(red: 0.0, green: 0.90, blue: 1.0)
        case .amber: return Color(red: 1.0, green: 0.69, blue: 0.13)
        case .paper: return Color(red: 0.66, green: 0.44, blue: 0.10)
        case .mint: return Color(red: 0.07, green: 0.56, blue: 0.49)
        case .coffee: return Color(red: 0.85, green: 0.60, blue: 0.31)
        case .system: return Color.accentColor
        }
    }
}

// MARK: - 强调色（可独立于主题自选）

enum AccentPreset: String, CaseIterable, Identifiable {
    case auto, azure, teal, emerald, amber, rose, violet, indigo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "跟随主题"
        case .azure: return "天蓝"
        case .teal: return "青碧"
        case .emerald: return "翠绿"
        case .amber: return "琥珀"
        case .rose: return "玫红"
        case .violet: return "紫罗兰"
        case .indigo: return "靛青"
        }
    }
    var color: Color? {
        switch self {
        case .auto: return nil
        case .azure: return Color(red: 0.20, green: 0.55, blue: 1.0)
        case .teal: return Color(red: 0.10, green: 0.72, blue: 0.72)
        case .emerald: return Color(red: 0.16, green: 0.74, blue: 0.50)
        case .amber: return Color(red: 1.0, green: 0.68, blue: 0.16)
        case .rose: return Color(red: 1.0, green: 0.42, blue: 0.55)
        case .violet: return Color(red: 0.66, green: 0.42, blue: 1.0)
        case .indigo: return Color(red: 0.36, green: 0.40, blue: 0.95)
        }
    }
}

// MARK: - 按时间自动切换深浅

enum AutoThemeSchedule {
    /// 依据 schedule 决定覆盖成深还是浅；返回 nil 表示不覆盖（跟随主题设置）。
    /// - "sun"：日出日落近似（07:00–19:00 浅，其余深）
    /// - "HH:mm-HH:mm"：该区间为深色
    static func override(schedule: String, now: Date = .now) -> Bool? {
        guard !schedule.isEmpty else { return nil }
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        func parse(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }

        if schedule == "sun" { return minute < 7 * 60 || minute >= 19 * 60 }

        let range = schedule.split(separator: "-").map(String.init)
        guard range.count == 2, let start = parse(range[0]), let end = parse(range[1]) else { return nil }
        if start <= end { return minute >= start && minute < end }
        // 跨零点，如 22:00-07:00
        return minute >= start || minute < end
    }
}
