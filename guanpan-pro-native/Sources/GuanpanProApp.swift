import SwiftUI
import UIKit

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store: PortfolioStore
    /// App 内字号倍率（配合系统动态字号）。放在 App 入口是为了让 sheet / fullScreenCover 也能继承。
    @AppStorage("guanpan.native.fontScale") private var fontScale: Double = 1

    init() {
        // UIKit appearance 只负责清理滚动容器和列表 cell 的底色；每个 List / Form
        // 还必须单独隐藏 scrollContentBackground，否则它自己的系统背景仍会盖住主题图。
        UIScrollView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        UICollectionViewCell.appearance().backgroundColor = .clear
        UICollectionViewListCell.appearance().backgroundColor = .clear
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
        UINavigationBar.appearance().backgroundColor = .clear

        let store = PortfolioStore()
        _store = StateObject(wrappedValue: store)
        // Background fetch can launch the process without first showing a view.
        // Register the already-loaded store here so the delegate can refresh it.
        BackgroundQuoteRefresh.configure(store: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.appAppearance, store.resolvedAppearance)
                .preferredColorScheme(store.effectiveColorScheme)
                .tint(store.effectiveAccentColor)
                .appFontScale(CGFloat(fontScale))
        }
    }
}
