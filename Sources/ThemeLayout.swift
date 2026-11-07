import SwiftUI
import UIKit

// MARK: - 主题版式（每套主题各做各的，不共用骨架）
//
// 之前 `DS` 里的圆角、间距、字号是全局静态常量，注释写着「深浅两套只有色值不同，
// 尺寸与层级完全一致」—— 换主题就只是换色。用户明确要求：主题不同，布局本来就该
// 不同，两套各自做。于是这里把「版式」从颜色里拆出来：
//   · tech  科技黑绿：墨绿近黑渐变底、22 大圆角、1px 描边、超大 hero 数字、
//           卡片流首页、悬浮胶囊底栏 + 中央 AI 球。
//   · ocean 蓝海浅色：浅蓝纯色底、12 小圆角、轻阴影、紧凑字号、分组列表首页、
//           贴底五项平铺导航（AI 是普通一格，没有球）。
// 颜色仍归 `DsPalette` / `AppTheme`，这里只管「怎么排」。

enum AppLayoutStyle: String, CaseIterable, Identifiable {
    case tech
    case ocean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tech: return "卡片流"
        case .ocean: return "分组列表"
        }
    }

    /// 设置页里给用户看的一句话说明：换的不只是颜色。
    var summary: String {
        switch self {
        case .tech: return "大圆角卡片流 · 悬浮 AI 球 · 超大资产数字"
        case .ocean: return "分组列表 · 五项平铺导航 · 紧凑高信息密度"
        }
    }
}

struct ThemeLayout {
    let style: AppLayoutStyle

    // MARK: 尺寸
    let radius: CGFloat
    let heroRadius: CGFloat
    let chipRadius: CGFloat
    let pad: CGFloat
    let pageInset: CGFloat
    let gap: CGFloat
    let sectionGap: CGFloat
    /// 旧 List / Form 行的上下留白。浅色分组列表更紧凑。
    let rowInset: CGFloat

    // MARK: 字号
    let fsHero: CGFloat
    let fsStat: CGFloat
    let fsTitle: CGFloat
    let fsRow: CGFloat
    let fsLabel: CGFloat
    let fsMicro: CGFloat

    // MARK: 骨架
    /// 首页用超大 hero 卡（tech）；false 时走分组列表首页（ocean）。
    let usesHeroHome: Bool
    /// 底栏是悬浮胶囊 + 中央悬浮球（tech）；false 是贴底全宽平铺栏（ocean）。
    let usesFloatingTabBar: Bool
    let usesOrb: Bool
    /// 平铺栏里 AI 是否单独占一格（ocean 才有第五格）。
    let flatTabShowsAI: Bool
    /// 系统大标题（ocean）还是自绘问候栏 + 隐藏导航栏（tech）。
    let usesLargeTitles: Bool
    /// 列表行里画不画迷你走势线。
    let showsSparklines: Bool
    /// 首页快捷入口列数。
    let quickColumns: Int
    /// 资产概览的数字网格列数。
    let statColumns: Int
    /// 卡片形态：描边（tech）还是轻阴影（ocean）。
    let usesOutline: Bool
    let shadowRadius: CGFloat
    let shadowOpacity: Double
    /// AI 块专用渐变（tech 绿系 / ocean 蓝系），白字都能读。
    let aiGradient: LinearGradient

    static let tech = ThemeLayout(
        style: .tech,
        radius: 22, heroRadius: 26, chipRadius: 12,
        pad: 16, pageInset: 18, gap: 12, sectionGap: 20, rowInset: 5,
        fsHero: 34, fsStat: 26, fsTitle: 17, fsRow: 15, fsLabel: 12, fsMicro: 10.5,
        usesHeroHome: true, usesFloatingTabBar: true, usesOrb: true,
        flatTabShowsAI: false, usesLargeTitles: false, showsSparklines: true,
        quickColumns: 4, statColumns: 2, usesOutline: true,
        shadowRadius: 0, shadowOpacity: 0,
        aiGradient: LinearGradient(colors: [
            Color(hex: 0x4FE0A0), Color(hex: 0xA6E86A), Color(hex: 0xC8F751)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    )

    static let ocean = ThemeLayout(
        style: .ocean,
        radius: 12, heroRadius: 14, chipRadius: 8,
        pad: 12, pageInset: 14, gap: 8, sectionGap: 14, rowInset: 2,
        fsHero: 28, fsStat: 20, fsTitle: 15, fsRow: 14, fsLabel: 11, fsMicro: 10,
        usesHeroHome: false, usesFloatingTabBar: false, usesOrb: false,
        flatTabShowsAI: true, usesLargeTitles: true, showsSparklines: false,
        quickColumns: 5, statColumns: 2, usesOutline: false,
        shadowRadius: 7, shadowOpacity: 0.07,
        aiGradient: LinearGradient(colors: [
            Color(hex: 0x2F5BE8), Color(hex: 0x4F7DF0), Color(hex: 0x78A6FF)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    )

    static func of(_ appearance: AppAppearance) -> ThemeLayout {
        AppAppearance.resolved(appearance).layoutStyle == .ocean ? .ocean : .tech
    }
}

extension AppAppearance {
    /// 主题 → 版式。旧的 14 套配色只为解码老存档保留，按深浅归到两套版式里，
    /// 免得老用户升级后看到第三套没人维护的布局。
    var layoutStyle: AppLayoutStyle {
        switch self {
        case .oceanBlue, .light, .paper, .mint: return .ocean
        case .system:
            return UITraitCollection.current.userInterfaceStyle == .light ? .ocean : .tech
        case .techBlack, .dark, .oled, .blue, .green, .purple, .sakura,
             .cyber, .amber, .coffee, .graphite:
            return .tech
        }
    }
}
