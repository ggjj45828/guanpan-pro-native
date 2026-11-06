import SwiftUI

// MARK: - 底部导航（自绘）

/// 底栏页签。
///
/// 走到 7 个入口就必须自绘底栏：系统的 `TabView` 在 iPhone 上最多平铺 5 个位置，
/// 第 6 个起会被折叠进系统「More」列表，用户得点两层才找得到——网格和收息
/// 放在那里等于没有。所以这里自己画一条，七个入口全部平铺。
enum ProTab: String, CaseIterable, Identifiable {
    case watchlist, holdings, funds, grid, income, assets, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watchlist: return "自选"
        case .holdings: return "持仓"
        case .funds: return "基金"
        case .grid: return "网格"
        case .income: return "收息"
        case .assets: return "资产"
        case .more: return "更多"
        }
    }

    var icon: String {
        switch self {
        case .watchlist: return "chart.xyaxis.line"
        case .holdings: return "briefcase.fill"
        case .funds: return "building.columns.fill"
        case .grid: return "square.grid.2x2.fill"
        case .income: return "yensign.circle.fill"
        case .assets: return "chart.pie.fill"
        case .more: return "ellipsis.circle.fill"
        }
    }
}

/// 自绘底部导航条。图标 18pt、文字 9.5pt 是为了让 7 个入口在 390pt 宽度上
/// 每个还能拿到约 55pt 的点击区，同时不把中文标签挤成两行。
struct ProTabBar: View {
    @Binding var selection: ProTab
    let surface: Color
    let accent: Color
    let isLight: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProTab.allCases) { tab in
                button(for: tab)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(isLight ? 0.10 : 0.16))
                .frame(height: 0.7)
        }
    }

    private func button(for tab: ProTab) -> some View {
        let selected = selection == tab
        return Button {
            Haptics.tap()
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 单页容器

/// 一个页签的容器：保留页面状态，但只让当前页可交互。
///
/// 用透明度切换而不是 `switch`：切走再切回来时，列表滚动位置、搜索词、
/// 已加载的行情都还在，和系统 TabView 的手感一致。代价是所有「访问过的」
/// 页面都留在内存里，所以外层还要配一个 `visited` 集合控制首次构建时机，
/// 避免一启动就把七个页面连同它们的网络请求全部拉起来。
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
