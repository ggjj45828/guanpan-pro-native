import SwiftUI

// MARK: - 底部导航（自绘，中央悬浮 AI 球）

/// 底栏页签。
///
/// 参照稿的底栏是「四格 + 中间一个悬浮球」：球不属于任何一个页签，点它是直接唤起
/// AI 顾问，所以它不进 `allCases` —— 否则切页逻辑里会多出一个「有选中态但没有页面」
/// 的非法状态。
enum ProTab: String, CaseIterable, Identifiable {
    case home, holdings, assets, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .holdings: return "持仓"
        case .assets: return "资产"
        case .more: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .holdings: return "chart.line.uptrend.xyaxis"
        case .assets: return "wallet.bifold.fill"
        case .more: return "person.fill"
        }
    }

    var inactiveIcon: String {
        switch self {
        case .home: return "house"
        case .holdings: return "chart.line.uptrend.xyaxis"
        case .assets: return "wallet.bifold"
        case .more: return "person"
        }
    }
}

/// 自绘底部导航条：悬浮胶囊 + 中央渐变球。
///
/// 不用系统 TabView 的原因见上一版：iPhone 最多平铺 5 个位置。
/// 现在只剩 4 个页签，但仍然保留自绘 —— 系统 TabView 做不出「球浮在栏上面」的效果。
struct ProTabBar: View {
    @Binding var selection: ProTab
    let surface: Color
    let accent: Color
    let isLight: Bool
    var onCenterTap: () -> Void = {}

    private var palette: DsPalette { DsPalette(isLight: isLight) }

    var body: some View {
        let bar = RoundedRectangle(cornerRadius: 26, style: .continuous)
        HStack(spacing: 0) {
            button(for: .home)
            button(for: .holdings)
            centerButton
            button(for: .assets)
            button(for: .more)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            bar.fill(isLight ? Color.white : Color(hex: 0x131315))
                .shadow(color: .black.opacity(isLight ? 0.10 : 0.55), radius: 18, y: 6)
        }
        .overlay { bar.strokeBorder(palette.hairline, lineWidth: 1) }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func button(for tab: ProTab) -> some View {
        let selected = selection == tab
        return Button {
            Haptics.tap()
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selected ? tab.icon : tab.inactiveIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? accent : palette.ink3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 中央球：渐变底 + 微光，向上探出约 16pt。
    private var centerButton: some View {
        Button {
            Haptics.push()
            onCenterTap()
        } label: {
            ZStack {
                Circle()
                    .fill(DS.aiGradient)
                    .frame(width: 52, height: 52)
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1) }
                    .shadow(color: Color(hex: 0x6A5CF0).opacity(0.55), radius: 14, y: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .offset(y: -16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI 顾问")
    }
}

// MARK: - 单页容器

/// 一个页签的容器：保留页面状态，但只让当前页可交互。
///
/// 用透明度切换而不是 `switch`：切走再切回来时，列表滚动位置、搜索词、
/// 已加载的行情都还在，和系统 TabView 的手感一致。代价是所有「访问过的」
/// 页面都留在内存里，所以外层还要配一个 `visited` 集合控制首次构建时机，
/// 避免一启动就把所有页面连同它们的网络请求全部拉起来。
struct ProTabPage<Content: View>: View {
    let isActive: Bool
    let content: Content

    /// 显式写初始化器：`@ViewBuilder` 修饰存储闭包属性时，成员初始化器是否继承
    /// 这个属性在各版本上并不一致，直接在这里把内容构建出来最稳。
    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
