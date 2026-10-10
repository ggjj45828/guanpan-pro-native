import SwiftUI

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store: PortfolioStore

    init() {
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
                .preferredColorScheme(store.appearance.colorScheme)
                .tint(store.appearance.accentColor)
        }
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paper, .mint: return .light
        default: return .dark
        }
    }

    var accentColor: Color {
        switch self {
        case .oled, .dark, .graphite: return Color(red: 0.31, green: 0.55, blue: 1.0)
        case .light: return Color(red: 0.15, green: 0.39, blue: 0.92)
        case .blue: return Color(red: 0.30, green: 0.62, blue: 1.0)
        case .green: return Color(red: 0.24, green: 0.79, blue: 0.63)
        case .purple: return Color(red: 0.66, green: 0.42, blue: 1.0)
        case .sakura: return Color(red: 1.0, green: 0.47, blue: 0.69)
        case .cyber: return Color(red: 0.0, green: 0.90, blue: 1.0)
        case .amber: return Color(red: 1.0, green: 0.69, blue: 0.13)
        case .paper: return Color(red: 0.66, green: 0.44, blue: 0.10)
        case .mint: return Color(red: 0.07, green: 0.56, blue: 0.49)
        case .coffee: return Color(red: 0.85, green: 0.60, blue: 0.31)
        case .system: return Color.accentColor
        }
    }
}
