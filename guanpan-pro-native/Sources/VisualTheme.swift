import SwiftUI

/// Presentation only. Every style reads the same portfolio, market and advisor data.
enum VisualTheme: String, CaseIterable, Identifiable {
    case scene, eastern, modern, dashboard, magazine, bento
    var id: String { rawValue }
    var title: String {
        switch self {
        case .scene: return "跟随场景"
        case .eastern: return "东方编辑室"
        case .modern: return "现代卡片"
        case .dashboard: return "交易仪表盘"
        case .magazine: return "杂志卡片"
        case .bento: return "创意拼图"
        }
    }
}

enum VisualScene {
    case home, intraday, daily, holdings, detail
}

enum LayoutStyle {
    case editorial, stacked, trading, magazine, mosaic
}

struct DesignTokens {
    let backgroundTop: Color
    let backgroundBottom: Color
    let surface: Color
    let hero: Color
    let accent: Color
    let secondary: Color
    let corner: CGFloat
    let gap: CGFloat
    let pageInset: CGFloat
    let isDark: Bool
    let layout: LayoutStyle

    var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum ThemeManager {
    static let storageKey = "guanpan.native.visualTheme"

    static func resolve(_ requested: VisualTheme, for scene: VisualScene) -> VisualTheme {
        guard requested == .scene else { return requested }
        switch scene {
        case .home: return .eastern
        case .intraday: return .dashboard
        case .daily: return .magazine
        case .holdings: return .bento
        case .detail: return .modern
        }
    }

    static func appearance(_ theme: VisualTheme) -> AppAppearance {
        switch theme {
        case .eastern, .magazine: return .paper
        case .modern, .bento, .scene: return .light
        case .dashboard: return .blue
        }
    }

    static func tokens(_ theme: VisualTheme) -> DesignTokens {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(red: r / 255, green: g / 255, blue: b / 255)
        }
        switch theme {
        case .eastern:
            return DesignTokens(backgroundTop: c(255, 249, 234), backgroundBottom: c(248, 234, 209),
                surface: c(255, 252, 244), hero: c(255, 222, 146), accent: c(191, 124, 29),
                secondary: c(77, 148, 108), corner: 23, gap: 13, pageInset: 14, isDark: false, layout: .editorial)
        case .modern:
            return DesignTokens(backgroundTop: c(242, 248, 255), backgroundBottom: c(226, 238, 253),
                surface: .white, hero: c(19, 118, 235), accent: c(16, 105, 226),
                secondary: c(69, 173, 221), corner: 19, gap: 11, pageInset: 14, isDark: false, layout: .stacked)
        case .dashboard:
            return DesignTokens(backgroundTop: c(8, 24, 44), backgroundBottom: c(8, 13, 28),
                surface: c(22, 38, 63), hero: c(57, 60, 138), accent: c(98, 134, 244),
                secondary: c(46, 194, 201), corner: 15, gap: 11, pageInset: 13, isDark: true, layout: .trading)
        case .magazine:
            return DesignTokens(backgroundTop: c(255, 249, 245), backgroundBottom: c(249, 237, 225),
                surface: c(255, 252, 248), hero: c(255, 232, 214), accent: c(179, 49, 101),
                secondary: c(39, 106, 152), corner: 18, gap: 17, pageInset: 16, isDark: false, layout: .magazine)
        case .bento:
            return DesignTokens(backgroundTop: c(249, 245, 255), backgroundBottom: c(232, 240, 255),
                surface: .white, hero: c(255, 224, 143), accent: c(103, 55, 174),
                secondary: c(44, 130, 228), corner: 20, gap: 9, pageInset: 12, isDark: false, layout: .mosaic)
        case .scene:
            return tokens(.eastern)
        }
    }
}

private struct VisualThemeKey: EnvironmentKey {
    static let defaultValue = VisualTheme.modern
}

extension EnvironmentValues {
    var visualTheme: VisualTheme {
        get { self[VisualThemeKey.self] }
        set { self[VisualThemeKey.self] = newValue }
    }
}

struct ThemePanel<Content: View>: View {
    @Environment(\.visualTheme) private var theme
    let tone: Color?
    let content: Content
    init(tone: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.content = content()
    }
    var body: some View {
        let tokens = ThemeManager.tokens(theme)
        let shape = RoundedRectangle(cornerRadius: tokens.corner, style: .continuous)
        content
            .padding(theme == .dashboard ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tone ?? tokens.surface))
            .overlay(shape.strokeBorder(tokens.accent.opacity(theme == .dashboard ? 0.45 : 0.18), lineWidth: 1))
            .shadow(color: tokens.accent.opacity(theme == .magazine ? 0.10 : 0.07), radius: theme == .magazine ? 13 : 8, x: 0, y: 5)
    }
}

/// Original local vector illustration; no remote or licensed image is required.
struct LandscapeDecoration: View {
    var color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Circle().fill(color.opacity(0.16))
                    .frame(width: proxy.size.height * 0.65).offset(x: proxy.size.width * 0.20, y: -proxy.size.height * 0.22)
                MountainShape().fill(color.opacity(0.13)).frame(height: proxy.size.height * 0.50)
                MountainShape().fill(color.opacity(0.20)).frame(height: proxy.size.height * 0.31).offset(x: 30)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.width * 0.19, y: rect.height * 0.46))
            path.addLine(to: CGPoint(x: rect.width * 0.30, y: rect.height * 0.68))
            path.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.12))
            path.addLine(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.72))
            path.addLine(to: CGPoint(x: rect.width * 0.88, y: rect.height * 0.39))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
