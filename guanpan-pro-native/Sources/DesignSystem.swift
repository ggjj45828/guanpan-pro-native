import SwiftUI
import UIKit

// Guanpan Pro's native system: editorial warmth for guidance and assets,
// disciplined data rhythm for market, order book, chart, and quant surfaces.
enum GPTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark, comfort
    var id: String { rawValue }
    var title: String { switch self { case .system: "主题默认"; case .light: "浅色"; case .dark: "深色"; case .comfort: "护眼" } }
    var colorScheme: ColorScheme? { switch self { case .system, .comfort: nil; case .light: .light; case .dark: .dark } }
}

/// 字号档位选项。必须是结构体：命名元组不能用作 ForEach 的 id keyPath。
struct GPScaleOption: Identifiable, Equatable {
    var id: Double { value }
    let title: String
    let value: Double
}

/// 字体族：系统 / 圆体 / 衬线 / 等宽。只影响通过 `gpFont` 渲染的正文，
/// 系统控件（导航栏、Tab）跟随系统字体，避免混排出两种排版风格。
enum GPFontFamily: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "系统"; case .rounded: "圆体"; case .serif: "衬线"; case .monospaced: "等宽" }
    }
    var design: Font.Design {
        switch self { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
    }
}

/// 用户可调外观。颜色用 `0xRRGGBB` 存，nil 表示跟随当前主题。
/// 字号不直接改 point，而是映射到 Dynamic Type 档位 —— 这样所有系统字体
/// （导航栏、列表、表单）会一起放大，而不是只有自定义文本变大、系统控件不变。
struct GPAppearance: Codable, Equatable {
    var fontScale: Double = 1.0
    var fontFamily: GPFontFamily = .system
    var inkHex: UInt32?
    var paperHex: UInt32?
    var canvasHex: UInt32?

    var dynamicTypeSize: DynamicTypeSize {
        switch fontScale {
        case ..<0.92: return .small
        case ..<1.0: return .medium
        case ..<1.12: return .large
        case ..<1.28: return .xLarge
        case ..<1.45: return .xxLarge
        default: return .xxxLarge
        }
    }
    var fontScaleTitle: String {
        switch fontScale {
        case ..<0.92: return "小"
        case ..<1.0: return "稍小"
        case ..<1.12: return "标准"
        case ..<1.28: return "大"
        case ..<1.45: return "特大"
        default: return "最大"
        }
    }
    var hasCustomColors: Bool { inkHex != nil || paperHex != nil || canvasHex != nil }

    /// 设置页字号档位。值不是 point，而是 Dynamic Type 档位的代表值。
    /// 用结构体而不是元组：Swift 不支持对命名元组做 keyPath，ForEach(id://.value) 会编译失败。
    static let scaleOptions: [GPScaleOption] = [
        GPScaleOption(title: "小", value: 0.88),
        GPScaleOption(title: "稍小", value: 0.96),
        GPScaleOption(title: "标准", value: 1.0),
        GPScaleOption(title: "大", value: 1.20),
        GPScaleOption(title: "特大", value: 1.36),
        GPScaleOption(title: "最大", value: 1.50)
    ]
}

private struct GPAppearanceKey: EnvironmentKey {
    static let defaultValue = GPAppearance()
}
extension EnvironmentValues {
    var gpAppearance: GPAppearance { get { self[GPAppearanceKey.self] } set { self[GPAppearanceKey.self] = newValue } }
}

struct GPPalette {
    let scheme: ColorScheme
    let comfort: Bool
    var appearance = GPAppearance()
    /// 当前生效的五套视觉主题（东方编辑室 / 现代卡片 / 交易仪表盘 / 杂志卡片 / 创意拼图）。
    /// 主题只换外观：所有颜色都从 `DesignTokens` 派生，数据与判断逻辑完全共享。
    var theme: AppTheme = .modern

    /// 令牌在构造时算一次并缓存：颜色访问在列表里会被调用几百次，
    /// 每次重算三十个 Color 会直接拖慢滚动。
    private let cached: DesignTokens

    init(scheme: ColorScheme, comfort: Bool, appearance: GPAppearance = GPAppearance(), theme: AppTheme = .modern) {
        self.scheme = scheme
        self.comfort = comfort
        self.appearance = appearance
        self.theme = theme
        self.cached = DesignTokens.resolve(theme: theme, scheme: scheme, comfort: comfort, appearance: appearance)
    }

    var tokens: DesignTokens { cached }

    var canvas: Color { tokens.canvas }
    var canvasEdge: Color { tokens.canvasEdge }
    var paper: Color { tokens.paper }
    var paperAlt: Color { tokens.paperAlt }
    var raised: Color { tokens.raised }
    var ink: Color { tokens.ink }
    var muted: Color { tokens.muted }
    var line: Color { tokens.line }
    var forest: Color { tokens.primary }
    var forestDeep: Color { tokens.primaryDeep }
    var terracotta: Color { tokens.secondary }
    /// 主题语义别名：新页面用 primary/secondary 表达「主题主色 / 次色」，
    /// 与 forest/terracotta 指同一份令牌，读的是同一份数据。
    var primary: Color { tokens.primary }
    var primaryDeep: Color { tokens.primaryDeep }
    var secondary: Color { tokens.secondary }
    var jade: Color { tokens.jade }
    var risk: Color { tokens.risk }
    var tint: Color { tokens.tint }
    var heroSurface: Color { tokens.heroSurface }
    var chartBlue: Color { tokens.chartBlue }
    var chartViolet: Color { tokens.chartViolet }
    var chartGold: Color { tokens.chartGold }
    var chartLongMA: Color { tokens.chartLongMA }
    var chartCost: Color { tokens.chartCost }
    /// 涨跌语义色（全局唯一来源）：国内口径「红涨绿跌」。
    /// 任何价格变动的着色都必须走 `changeTone(_:)` 或这两个属性；
    /// 不要再拿 risk / jade / terracotta 当涨跌色用（它们是「警示 / 建议 / 均线」语义）。
    var gpUp: Color { tokens.up }
    var gpDown: Color { tokens.down }
    /// 价格线本身用 `ink`（近黑），涨跌用 `gpUp`/`gpDown`，与「price=黑、涨红跌绿」一致。
    func changeTone(_ value: Double) -> Color { value >= 0 ? gpUp : gpDown }

    /// AI 指导卡渐变与卡上文字色：五套主题各自一套，但数据完全一样。
    var heroGradient: LinearGradient {
        LinearGradient(colors: [tokens.heroStart, tokens.heroEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var heroInk: Color { tokens.heroInk }
    var heroMutedInk: Color { tokens.heroMutedInk }
    var cardRadius: CGFloat { tokens.cardRadius }
    var heroRadius: CGFloat { tokens.heroRadius }
    var chipRadius: CGFloat { tokens.chipRadius }
    var cardShadowOpacity: Double { tokens.shadowOpacity }
    var cardShadowRadius: CGFloat { tokens.shadowRadius }
    var cardShowsBorder: Bool { tokens.showsBorder }
}

private struct GPPaletteKey: EnvironmentKey {
    static let defaultValue = GPPalette(scheme: .light, comfort: false, appearance: GPAppearance(), theme: .modern)
}
extension EnvironmentValues {
    var gp: GPPalette { get { self[GPPaletteKey.self] } set { self[GPPaletteKey.self] = newValue } }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
    /// 存回 `GPAppearance` 用的 0xRRGGBB。取不到分量时返回 nil，界面保持"跟随主题"。
    var gpHex: UInt32? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func clamp(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (clamp(r) << 16) | (clamp(g) << 8) | clamp(b)
    }
}

private struct GPScaledFontModifier: ViewModifier {
    @Environment(\.gpAppearance) private var appearance
    @ScaledMetric private var scaledSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    init(size: CGFloat, relativeTo: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View {
        // 用户选了字体族就整体替换，否则保留调用处原本的排版意图。
        let resolved = appearance.fontFamily == .system ? design : appearance.fontFamily.design
        return content.font(.system(size: scaledSize, weight: weight, design: resolved))
    }
}
extension View {
    func gpFont(size: CGFloat, relativeTo: Font.TextStyle = .body, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(GPScaledFontModifier(size: size, relativeTo: relativeTo, weight: weight, design: design))
    }
}

struct EditorialSection<Content: View>: View {
    @Environment(\.gp) private var p
    let title: String
    var trailing: String? = nil
    /// 分组主色。默认森林绿；行情/买卖类用陶红，风险类用 risk，
    /// 这样一屏扫下来能靠颜色分辨「这是哪一类信息」，而不是一片灰字。
    var accent: Color? = nil
    @ViewBuilder var content: Content
    private var tone: Color { accent ?? p.forest }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Capsule().fill(tone.opacity(0.85)).frame(width: 3, height: 15).offset(y: 1)
                Text(title).font(.system(.headline, design: .serif).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(tone.opacity(0.85)) }
            }
            content
        }.padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [tone.opacity(0.34), p.line.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 0.8)
        }
    }
}

struct DataPanel<Content: View>: View {
    @Environment(\.gp) private var p
    let title: String
    var accent: Color? = nil
    var caption: String? = nil
    @ViewBuilder var content: Content
    private var tone: Color { accent ?? p.forest }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(p.ink)
                Spacer(minLength: 6)
                if let caption { Text(caption).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tone.opacity(0.8)) }
            }
            content
        }.padding(13)
        .background(
            LinearGradient(colors: [p.paper, tone.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tone.opacity(0.22), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tone.opacity(0.75)).frame(width: 2.5).padding(.vertical, 14).padding(.leading, 1.2)
        }
        .shadow(color: tone.opacity(0.08), radius: 7, x: 0, y: 3)
    }
}

/// 白色圆角卡：参考设计稿「浅色柔和卡片」的统一容器。
/// 与 DataPanel 的分工——DataPanel 带色条和渐变，用于「一条结论/一块结果」；
/// GPCard 就是一张干净的白卡，用于承载表单、说明、列表这类成组内容。
struct GPCard<Content: View>: View {
    @Environment(\.gp) private var p
    var accent: Color? = nil
    var padding: CGFloat = 13
    @ViewBuilder var content: Content
    private var tone: Color { accent ?? p.forest }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.paper, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tone.opacity(0.25), lineWidth: 0.8))
            .shadow(color: tone.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

/// 卡内轻量空态：有图标有说法，但不带 GPStatus 的大内边距（卡中嵌卡会显空）。
struct GPInlineEmpty: View {
    @Environment(\.gp) private var p
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(p.forest)
            Text(text).font(.caption).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

struct GPValue: View {
    @Environment(\.gp) private var p
    let label: String
    let value: String
    var footnote: String? = nil
    var emphasis: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(p.muted)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(emphasis ?? p.ink).lineLimit(1).minimumScaleFactor(0.78)
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(p.muted).lineLimit(1) }
        }
    }
}

struct GPStatus: View {
    @Environment(\.gp) private var p
    let title: String
    let detail: String
    var symbol = "clock"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(p.forest)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
            Text(detail).font(.caption).foregroundStyle(p.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action { Button(actionTitle, action: action).font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(p.forest) }
        }.frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
    }
}

struct GPDataRow: View {
    @Environment(\.gp) private var p
    let title: String
    let value: String
    var note: String? = nil
    var valueColor: Color? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(.subheadline, design: .default).weight(.medium)).foregroundStyle(p.ink); if let note { Text(note).font(.caption2).foregroundStyle(p.muted) } }
            Spacer(minLength: 8)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit().foregroundStyle(valueColor ?? p.ink).multilineTextAlignment(.trailing)
        }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(p.line.opacity(0.7)).frame(height: 0.5) }
    }
}

struct GPActionButton: View {
    @Environment(\.gp) private var p
    let title: String
    var secondary = false
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { if let systemImage { Image(systemName: systemImage) }; Text(title).lineLimit(1) }
                .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 46)
                .foregroundStyle(secondary ? p.forest : Color.white)
                .background(secondary ? p.tint : p.forestDeep, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }.buttonStyle(.plain).accessibilityAddTraits(.isButton)
    }
}

struct GPPageBackground<Content: View>: View {
    @Environment(\.gp) private var p
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.bottom, 32)
                .frame(maxWidth: 820).frame(maxWidth: .infinity, alignment: .top)
        }
        // 极浅的双色渐变：纸张底 + 一抹青绿，避免整页糊成一片灰白。
        .background(
            LinearGradient(colors: [p.canvas, p.forest.opacity(0.07), p.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - 键盘收起

/// 数字键盘没有回车键，输入完必须点别的区域才能收起来。
/// 这里统一给一个键盘上方的「完成」按钮，并让内容下拉时立即收起键盘。
struct GPKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { GPKeyboardDismiss.resign() }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("keyboard.done")
                }
            }
            .scrollDismissesKeyboard(.immediately)
    }
    static func resign() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension View {
    /// 给页面/表单加「完成」键盘工具条。可重复应用，不会叠加出多个按钮。
    func gpKeyboardDismiss() -> some View { modifier(GPKeyboardDismiss()) }
}
