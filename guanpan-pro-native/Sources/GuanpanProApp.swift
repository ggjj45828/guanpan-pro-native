import SwiftUI
import UIKit

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store: PortfolioStore
    @StateObject private var researchEngine = PhoneResearchEngine()
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
            store.data.holdings = [
                Holding(code: "159941", name: "纳指 ETF · 演示", quantity: 100, cost: 1.2, current: 1.3, kind: .etf, marketUpdatedAt: .now),
                Holding(code: "512480", name: "半导体 ETF · 演示", quantity: 500, cost: 0.9, current: 0.842, kind: .etf, marketUpdatedAt: .now),
                Holding(code: "513520", name: "日经 ETF · 演示", quantity: 200, cost: 1.1, current: 1.238, kind: .etf, marketUpdatedAt: .now),
                Holding(code: "560510", name: "A500 ETF · 演示", quantity: 300, cost: 1.0, current: 0.965, kind: .etf, marketUpdatedAt: .now)
            ]
            store.data.quotes = store.data.holdings.map {
                Quote(code: $0.code, name: $0.name, price: $0.current,
                      changePct: $0.code == "512480" ? 0.012 : -0.003, updatedAt: .now)
            }
            store.setIndexQuotesForUITesting([
                MarketIndexQuote(symbol: "1.000001", name: "上证指数", price: 3285.62, changePct: 0.0032, updatedAt: .now),
                MarketIndexQuote(symbol: "0.399001", name: "深证成指", price: 10542.18, changePct: 0.0018, updatedAt: .now),
                MarketIndexQuote(symbol: "0.399006", name: "创业板指", price: 2198.40, changePct: -0.0045, updatedAt: .now)
            ])
            var observations: [IntradayBar] = []
            let now = Date()
            for n in 0..<30 {
                let time = now.addingTimeInterval(Double(n - 30) * 60.0)
                let price = 1.25 + Double(n) * 0.0015
                let iopv: Double? = n % 3 == 0 ? 1.24 + Double(n) * 0.0015 : nil
                observations.append(IntradayBar(code: "159941", timestamp: time, price: price, volume: nil, day: "2026-10-19", iopv: iopv))
            }
            store.intradayBars = observations
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
                .environmentObject(researchEngine)
                .environmentObject(channels)
                .environment(\.appAppearance, store.resolvedAppearance)
                .tint(store.effectiveAccentColor)
                .appFontScale(CGFloat(fontScale))
        }
    }
}
