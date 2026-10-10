import SwiftUI
import UIKit

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store: PortfolioStore
    /// App 内字号倍率（配合系统动态字号）。放在 App 入口是为了让 sheet / fullScreenCover 也能继承。
    @AppStorage("guanpan.native.fontScale") private var fontScale: Double = 1

    init() {
        // 让 App 内所有 List / Form 都透明，自定义背景图与主题底色才能真正透出来。
        // SwiftUI 的 `.scrollContentBackground(.hidden)` 只能作用于单个 List，
        // 不会沿视图层级传递 —— 之前只加在根 TabView 上，29 个 List 全部保持不透明背景，
        // 表现就是「换背景没反应」「背景透明度不起作用」。
        // iOS 17 的 List 底层是 UICollectionView，Form 是 UITableView，统一改 appearance 即可全局生效。
        UIScrollView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
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
                .preferredColorScheme(store.effectiveColorScheme)
                .tint(store.effectiveAccentColor)
                .appFontScale(CGFloat(fontScale))
        }
    }
}
