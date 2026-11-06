import SwiftUI
import UIKit

// MARK: - 触觉反馈

/// 全局触觉反馈入口。
///
/// iPhone 的线性马达在「确认类」操作上给一次轻反馈，能明显降低误触感；
/// 之前全工程一处都没有，所有按钮点下去只有视觉变化。
/// 这里统一走 UIKit 的 FeedbackGenerator，SwiftUI 的 `sensoryFeedback` 要 iOS 17+
/// 且对旧机型无效，工程最低版本就是 17.0，但 UIKit 口径在任何机型上都稳定。
enum Haptics {
    /// 轻点：用于切换、翻页、选中
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 中等力度：用于「有实际后果」的操作，如保存、刷新
    static func push() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 重力度：用于删除、重置这类不可逆操作
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// 选择变化：用于 Picker / 滑块连续变化
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - 无障碍文案

/// 把「涨跌数值」翻译成读屏能念出来的中文。
///
/// 界面上涨跌主要靠红绿颜色区分，读屏用户和色弱用户拿不到这个信息。
/// 这里统一补一条 accessibilityLabel，念成「上涨 1.23%」而不是干巴巴的「1.23%」。
func spokenDirection(_ value: Double) -> String {
    if value > 0 { return "上涨" }
    if value < 0 { return "下跌" }
    return "持平"
}

/// 涨跌百分比的读屏文案
func spokenPercent(_ value: Double) -> String {
    "\(spokenDirection(value)) \(value.pct(2))"
}

/// 涨跌金额的读屏文案
func spokenMoney(_ value: Double) -> String {
    "\(spokenDirection(value)) \(value.cny())"
}

extension View {
    /// 给涨跌百分比文本挂读屏标签。
    func pnlAccessibility(percent value: Double) -> some View {
        accessibilityLabel(spokenPercent(value))
    }

    /// 给涨跌金额文本挂读屏标签。
    func pnlAccessibility(money value: Double) -> some View {
        accessibilityLabel(spokenMoney(value))
    }

    /// 把一组子元素合并成一个可访问元素。
    ///
    /// 卡片里的「名称 + 金额 + 涨跌幅」默认是三个独立焦点，读屏要划三次；
    /// 合并后一次念完，效率差很多。
    func combineAccessibility() -> some View {
        accessibilityElement(children: .combine)
    }
}

// MARK: - 统一刷新反馈

/// 所有“用户主动刷新”共用的轻提示。自动刷新不调用它，避免前台常驻时反复打扰。
@MainActor
final class RefreshFeedbackModel: ObservableObject {
    struct Item: Equatable {
        var message: String
        var isLoading: Bool
        var succeeded: Bool
    }

    @Published private(set) var item: Item?
    private var hideTask: Task<Void, Never>?

    func begin(_ message: String) {
        hideTask?.cancel()
        item = Item(message: message, isLoading: true, succeeded: true)
    }

    func finish(_ message: String, succeeded: Bool = true) {
        hideTask?.cancel()
        item = Item(message: message, isLoading: false, succeeded: succeeded)
        if succeeded { Haptics.success() } else { Haptics.warning() }
        let expected = item
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, self?.item == expected else { return }
            self?.item = nil
        }
    }
}

private struct RefreshFeedbackBanner: View {
    let item: RefreshFeedbackModel.Item

    var body: some View {
        HStack(spacing: 9) {
            if item.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(item.succeeded ? Color.green : Color.orange)
            }
            Text(item.message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.message)
    }
}

extension View {
    /// 贴在当前页面内容顶部，不使用透明玻璃材质。
    func refreshFeedbackOverlay(_ model: RefreshFeedbackModel) -> some View {
        overlay(alignment: .top) {
            if let item = model.item {
                RefreshFeedbackBanner(item: item)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.item)
    }
}

/// 导航栏刷新按钮统一为 24×24 的视觉盒；ProgressView 和箭头不会再一大一小。
struct RefreshToolbarIcon: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - 减弱动态效果

/// 系统「减弱动态效果 / 降低透明度 / 不区分颜色」开关的读取助手。
///
/// SwiftUI 的环境值只能在 View 里读，而很多动画开关写在回调里，
/// 所以这里用一个可注入的环境包装：视图读一次，往下传给需要的逻辑。
struct AccessibilityPreference {
    var reduceMotion = false
    var reduceTransparency = false
    var differentiateWithoutColor = false
}

private struct AccessibilityPreferenceKey: EnvironmentKey {
    static let defaultValue = AccessibilityPreference()
}

extension EnvironmentValues {
    var accessibilityPreference: AccessibilityPreference {
        get { self[AccessibilityPreferenceKey.self] }
        set { self[AccessibilityPreferenceKey.self] = newValue }
    }
}

/// 在根视图插一次，把三个系统无障碍开关读进环境，供子视图按需取用。
struct AccessibilityPreferenceReader: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    func body(content: Content) -> some View {
        content.environment(\.accessibilityPreference,
                            AccessibilityPreference(reduceMotion: reduceMotion,
                                                    reduceTransparency: reduceTransparency,
                                                    differentiateWithoutColor: differentiate))
    }
}

extension View {
    func readAccessibilityPreferences() -> some View {
        modifier(AccessibilityPreferenceReader())
    }

    /// 只在用户没开「减弱动态效果」时才应用动画。
    @ViewBuilder
    func respectReduceMotion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(ReduceMotionModifier(animation: animation, value: value))
    }
}

private struct ReduceMotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - 涨跌配色（集中一处，方便「不区分颜色」时统一加形状）

/// 国内口径：涨=红，跌=绿。
///
/// 注意：只给颜色是不够的。所有用这两个色的地方必须同时带
/// `directionMark()` 的 ▲▼ 符号，否则开了灰度或色弱模式就完全读不出方向。
enum PnLColor {
    static let up = Color(red: 0.93, green: 0.30, blue: 0.37)
    static let down = Color(red: 0.07, green: 0.77, blue: 0.55)
    static let flat = Color.secondary

    static func of(_ value: Double) -> Color {
        if value > 0 { return up }
        if value < 0 { return down }
        return flat
    }
}
