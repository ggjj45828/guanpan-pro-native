import SwiftUI
import UIKit

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store: PortfolioStore
    @StateObject private var lab = InvestmentLabStore()
    @StateObject private var channels = LabChannelCoordinator()
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["GUANPAN_TESTING"] == "1", ProcessInfo.processInfo.environment["GUANPAN_UI_FIXTURE"] == "1" {
            store.data = PortfolioData()
            store.data.appearance = ProcessInfo.processInfo.environment["GUANPAN_UI_STYLE"] == "dark" ? .dark : .light
            store.data.cash = 3200
            store.data.holdings = [Holding(code: "159941", name: "纳指 ETF · 测试数据", quantity: 100, cost: 1.2, current: 1.3, kind: .etf, marketUpdatedAt: .now)]
            store.data.quotes = [Quote(code: "159941", name: "纳指 ETF · 测试数据", price: 1.3, changePct: 0.01, updatedAt: .now)]
            store.intradayBars = (0..<30).map { n in IntradayBar(code: "159941", timestamp: Date().addingTimeInterval(Double(n - 30) * 60), price: 1.25 + Double(n) * 0.0015, volume: nil, day: "2026-10-19", iopv: n % 3 == 0 ? 1.24 + Double(n) * 0.0015 : nil) }
        }
        #endif
        _store = StateObject(wrappedValue: store)
        // Background fetch can launch the process without first showing a view.
        // Register the already-loaded store here so the delegate can refresh it.
        if ProcessInfo.processInfo.environment["GUANPAN_TESTING"] != "1" {
            BackgroundQuoteRefresh.configure(store: store)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(lab)
                .environmentObject(channels)
                .environment(\.appAppearance, store.resolvedAppearance)
                .preferredColorScheme(store.effectiveColorScheme)
                .tint(store.effectiveAccentColor)
                .appFontScale(CGFloat(fontScale))
        }
    }
}
