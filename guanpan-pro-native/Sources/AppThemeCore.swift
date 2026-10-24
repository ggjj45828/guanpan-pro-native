import Foundation

// 主题的「身份与选择」这部分必须放在 Core 目标里：账本存档（NextAppArchive）要记录用户选了哪套主题，
// 而 Core 不能依赖 SwiftUI。颜色与令牌在 app 目标的 ThemeKit.swift 里扩展。

// MARK: - 五套视觉主题

/// 五套主题只改变「怎么展示」，不改变任何数据与业务判断：
/// 同一份持仓、同一份 AI 结论、同一份行情，换主题只是换排版与配色。
enum AppTheme: String, CaseIterable, Identifiable, Codable, Equatable {
    case editorial = "editorial"     // 东方编辑室
    case modern = "modern"           // 现代卡片
    case dashboard = "dashboard"     // 交易仪表盘
    case magazine = "magazine"       // 杂志卡片
    case puzzle = "puzzle"           // 创意拼图

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editorial: return "东方编辑室"
        case .modern: return "现代卡片"
        case .dashboard: return "交易仪表盘"
        case .magazine: return "杂志卡片"
        case .puzzle: return "创意拼图"
        }
    }

    var tagline: String {
        switch self {
        case .editorial: return "暖纸底 + 金色 AI 卡，像一份私人晨报"
        case .modern: return "白卡 + 蓝色主色，信息密度最高"
        case .dashboard: return "深色盘面 + 仪表盘数字，盯盘最省眼"
        case .magazine: return "衬线大标题 + 留白，适合慢慢读"
        case .puzzle: return "彩色拼图块，一眼分清每类信息"
        }
    }

    /// 深色盘面主题：无论系统设置如何都走深色，否则数字读不清。
    var forcesDark: Bool { self == .dashboard }

    /// 首页骨架样式（与主题一一对应，但独立成类型，方便后续单独调整某一套）。
    var layout: LayoutStyle { LayoutStyle(rawValue: rawValue) ?? .modern }

    /// 设置页主题选择的小色块预览。
    var previewHexes: [UInt32] {
        switch self {
        case .editorial: return [0xFBF4E4, 0xF3CE8A, 0x7C5CE0]
        case .modern: return [0xF2F5FA, 0x2F6BFF, 0xFFFFFF]
        case .dashboard: return [0x0B1220, 0x7C3AED, 0x19C08A]
        case .magazine: return [0xFBF4F1, 0xE7B7C4, 0x1F2A37]
        case .puzzle: return [0xF7F3FB, 0xF6C64B, 0x4DB8F5]
        }
    }
}

/// 首页布局风格。刻意与 `AppTheme` 分开：以后允许「主题配色 A + 布局 B」的组合，
/// 也允许某个主题只换排版不改配色。
enum LayoutStyle: String, CaseIterable, Identifiable, Codable, Equatable {
    case editorial, modern, dashboard, magazine, puzzle
    var id: String { rawValue }
}

/// 场景：主题可以「跟随场景」自动切换——首页用编辑室、盘中用仪表盘……
enum ThemeScene: String, CaseIterable, Identifiable, Equatable {
    case home
    case market
    case aiReport
    case holdings
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .market: return "盘中行情"
        case .aiReport: return "AI 日报 / 指导"
        case .holdings: return "持仓快览"
        case .detail: return "详情与设置"
        }
    }

    /// 用户拍的「场景 → 主题」映射，与参考图一致：
    /// 普通首页→东方编辑室；盘中→交易仪表盘；AI 日报→杂志卡片；持仓快览→创意拼图；复杂详情/设置→现代卡片。
    var recommendedTheme: AppTheme {
        switch self {
        case .home: return .editorial
        case .market: return .dashboard
        case .aiReport: return .magazine
        case .holdings: return .puzzle
        case .detail: return .modern
        }
    }
}

/// 用户的主题选择：跟随场景，或固定一套。手动选择永远优先于场景推断。
enum ThemeSelection: Codable, Equatable {
    case auto
    case fixed(AppTheme)

    var isAuto: Bool { self == .auto }
    var fixedTheme: AppTheme? {
        if case let .fixed(theme) = self { return theme }
        return nil
    }
    var title: String {
        switch self {
        case .auto: return "跟随场景"
        case .fixed(let theme): return theme.title
        }
    }
}

/// 统一主题解析入口。这里只做「选择 → 主题」的纯函数计算，
/// 不持有状态（状态存在 `LocalPreferences.themeStyle`），避免出现第二个真相源。
enum ThemeManager {
    static func resolve(selection: ThemeSelection, scene: ThemeScene) -> AppTheme {
        selection.fixedTheme ?? scene.recommendedTheme
    }
}
