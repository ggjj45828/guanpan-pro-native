import SwiftUI
import UIKit

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
            return AppTheme(top: c(14, 16, 22), bottom: c(8, 9, 13), surface: c(28, 31, 39), isLight: false)
        case .dark:      // 深空灰
            return AppTheme(top: c(28, 30, 36), bottom: c(14, 15, 19), surface: c(39, 42, 50), isLight: false)
        case .oled:      // 纯黑 OLED
            return AppTheme(top: .black, bottom: .black, surface: c(24, 24, 26), isLight: false)
        case .blue:      // 午夜蓝
            return AppTheme(top: c(10, 24, 52), bottom: c(4, 10, 26), surface: c(22, 39, 70), isLight: false)
        case .green:     // 松墨绿
            return AppTheme(top: c(9, 34, 28), bottom: c(4, 16, 14), surface: c(22, 51, 43), isLight: false)
        case .purple:    // 暗夜紫
            return AppTheme(top: c(28, 16, 52), bottom: c(12, 7, 26), surface: c(44, 30, 70), isLight: false)
        case .sakura:    // 樱花粉
            return AppTheme(top: c(48, 20, 34), bottom: c(22, 9, 18), surface: c(66, 34, 49), isLight: false)
        case .cyber:     // 赛博朋克
            return AppTheme(top: c(6, 26, 48), bottom: c(30, 6, 40), surface: c(26, 43, 66), isLight: false)
        case .amber:     // 琥珀金
            return AppTheme(top: c(48, 32, 8), bottom: c(22, 14, 4), surface: c(67, 49, 22), isLight: false)
        case .coffee:    // 拿铁棕
            return AppTheme(top: c(44, 28, 18), bottom: c(20, 12, 8), surface: c(62, 43, 31), isLight: false)
        case .graphite:  // 石墨灰
            return AppTheme(top: c(38, 40, 44), bottom: c(20, 21, 24), surface: c(52, 54, 59), isLight: false)
        case .light:     // 明亮白
            return AppTheme(top: c(238, 242, 250), bottom: c(222, 228, 240), surface: c(250, 252, 255), isLight: true)
        case .paper:     // 纸白
            return AppTheme(top: c(250, 246, 236), bottom: c(238, 232, 218), surface: c(255, 252, 244), isLight: true)
        case .mint:      // 薄荷
            return AppTheme(top: c(228, 248, 242), bottom: c(206, 238, 228), surface: c(245, 255, 251), isLight: true)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 弹出界面的主题底色

private struct AppAppearanceKey: EnvironmentKey {
    static let defaultValue = AppAppearance.system
}

extension EnvironmentValues {
    /// 当前配色主题。由 App 根视图注入，供 sheet / fullScreenCover 自己补底色用。
    ///
    /// 走环境而不是让每个弹窗各自去取 `store`：弹窗有四十来处，
    /// 只有少数几处需要它，而它们分布在不同的文件里，不能保证都能拿到 `store`。
    var appAppearance: AppAppearance {
        get { self[AppAppearanceKey.self] }
        set { self[AppAppearanceKey.self] = newValue }
    }
}

/// 弹出界面（sheet / fullScreenCover）的主题底色。
///
/// **为什么弹窗必须自己画底**：`GuanpanProApp.init()` 为了让页面主题色透出来，
/// 把 `UITableView` / `UINavigationBar` 等全局外观的底色统一清成了 clear；
/// 而每个弹窗里的 `List` / `Form` 又都写了 `.scrollContentBackground(.hidden)`
/// 加 `.background(.clear)`。两边一叠加，弹窗内容本身**一点颜色都不画**，
/// 全靠系统给的那层 sheet 背板撑着。而系统背板并不可靠 —— 新版 iOS 的 sheet
/// 默认是半透明材质，于是底下那一页直接透上来：
/// 用户看到的是「弹窗闪一下就变透明、上一页的文字叠在自己的行之间、整页糊在一起」。
///
/// 所以这里**不依赖系统背板**，由内容自己画一层不透明的主题渐变：
/// ① 无论系统背板是透明、玻璃还是纯色，都盖得住；
/// ② 与挂在视图树哪一层无关，不会踩「挂在 Form 内层就留下系统白底」这种位置陷阱。
///
/// **不要改回 `presentationBackground`**：它只能挂在弹窗内容的**根视图**上，
/// 挂进 `NavigationStack` 里面（挂到 `List` / `Form` 上）会被系统忽略，
/// 留下默认的不透明白底 —— 深色主题下就是一条刺眼的白边。
struct ThemedSheetBackground: View {
    @Environment(\.appAppearance) private var appearance

    var body: some View {
        AppTheme.palette(for: appearance).gradient
            .ignoresSafeArea()
    }
}

extension View {
    /// 给 sheet / fullScreenCover 的**内容**铺一层不透明的主题底色。
    ///
    /// 挂在弹窗内容的根视图上即可，层级不限；同一个弹窗重复挂也不会画错（同色叠加）。
    /// 漏挂的直接后果就是「弹窗透明、下层页面透上来」，所以**新增弹窗时必须带上它**。
    func themedSheetBackground() -> some View {
        let surface = AppTheme.palette(for: AppAppearance.resolved(appAppearance)).surface
        return background { ThemedSheetBackground() }
            .toolbarBackground(surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - 「跟随系统」的解析

extension AppAppearance {
    /// 把「跟随系统」解析成一套**具体**主题。
    ///
    /// 为什么必须要这一步：`.system` 的配色在 `palette(for:)` 里是写死的一套深色
    /// （近黑底 `#0E1016`），而它的 `colorScheme` 又返回 nil（跟随系统）。
    /// 手机在**浅色**模式下这两者就打架了 —— 底是近黑的，文字却按浅色模式取成黑的，
    /// 结果黑底黑字，整页读不出来（用户报的「指数详情弹窗一片黑，看不到」就是这个）。
    ///
    /// 所以凡是「要取一个具体主题来画色」的地方（页面底、卡片深浅、弹窗底），
    /// 都先过这一层解析，不要直接拿 `store.appearance` 去取 palette。
    ///
    /// 注意：设置页的主题预览卡**不能**用它 —— 那里要如实画出 `.system` 这一档本身。
    static func resolved(_ appearance: AppAppearance) -> AppAppearance {
        guard appearance == .system else { return appearance }
        return UITraitCollection.current.userInterfaceStyle == .light ? .light : .dark
    }
}

// MARK: - 主题自带的深浅模式与强调色

extension AppAppearance {
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深空灰"
        case .oled: return "纯黑 OLED"
        case .blue: return "午夜蓝"
        case .green: return "松墨绿"
        case .purple: return "暗夜紫"
        case .sakura: return "樱花粉"
        case .cyber: return "赛博朋克"
        case .amber: return "琥珀金"
        case .coffee: return "拿铁棕"
        case .graphite: return "石墨灰"
        case .light: return "明亮白"
        case .paper: return "纸白"
        case .mint: return "薄荷"
        }
    }

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
