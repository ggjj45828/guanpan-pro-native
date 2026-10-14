import Foundation
import UserNotifications
import UIKit

@MainActor
final class GuanpanAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        BackgroundQuoteRefresh.perform(completion: completionHandler)
    }

    /// 支持的方向。
    ///
    /// 原来这里返回 `OrientationLock.shared.mask`，那个类只服务于「K 线横屏大图」；
    /// 该功能已按用户要求整组下线，于是这里直接写死成原来的默认值（`OrientationLock`
    /// 的初始 mask 就是它），行为完全不变，只是少了一层没用的间接。
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

@MainActor
enum BackgroundQuoteRefresh {
    static let enabledKey = "guanpan.native.backgroundRefresh.enabled"
    private(set) static var store: PortfolioStore?

    static func configure(store: PortfolioStore) {
        self.store = store
        let enabled = UserDefaults.standard.bool(forKey: enabledKey) && store.data.quoteRefreshSeconds > 0
        UIApplication.shared.setMinimumBackgroundFetchInterval(enabled ? UIApplication.backgroundFetchIntervalMinimum : UIApplication.backgroundFetchIntervalNever)
    }

    static func perform(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard UserDefaults.standard.bool(forKey: enabledKey), let store, store.data.quoteRefreshSeconds > 0 else {
            completion(.noData); return
        }
        Task { @MainActor in
            let updated = await store.refreshQuotesForBackground()
            completion(updated ? .newData : .failed)
        }
    }
}

@MainActor
enum NativeNotifications {
    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func send(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "guanpan-\(UUID().uuidString)", content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    static func sendSourceHealthOnce(category: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        let key = "guanpan.native.health.last.\(category)"
        let today = day.string(from: .now)
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        do {
            try await send(title: "观盘 Pro · 数据源提醒", body: body)
            UserDefaults.standard.set(today, forKey: key)
        } catch {
            // A later refresh may retry if notification delivery is temporarily unavailable.
        }
    }
}
