import Foundation
import UserNotifications

/// Local delivery is useful even while NAS is offline. Remote APNs delivery is
/// intentionally separate because it requires the user's Apple credentials and
/// a server-side signing configuration.
enum NextLocalNotificationService {
    static func authorizationStatus() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "系统通知已允许"
        case .denied: return "系统通知已关闭"
        case .notDetermined: return "尚未请求系统通知权限"
        @unknown default: return "系统通知状态未知"
        }
    }

    static func requestAuthorization() async -> String {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return allowed ? "系统通知已允许" : "系统通知未允许"
        } catch { return "通知权限请求失败：\(error.localizedDescription)" }
    }

    static func deliver(id: UUID, title: String, detail: String) async -> String {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = detail; content.sound = .default
        content.userInfo = ["guanpan-alert-id": id.uuidString]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
            return "本机通知已投递"
        } catch { return "本机通知投递失败：\(error.localizedDescription)" }
    }

    /// 每日巡检提醒：本机定时通知，到点打开 App 即可一键跑持仓巡检。
    /// 这不是远端 APNs 推送（需要你的苹果凭证与签名服务器），而是设备本地闹钟式提醒。
    static let inspectionID = "guanpan.daily.inspection"
    static func enableDailyInspection(hour: Int, minute: Int) -> String {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "观盘 Next · 每日 AI 巡检"
        content.body = "打开看看持仓盈亏、股息率与今日可关注的机会。"
        content.sound = .default
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: inspectionID, content: content, trigger: trigger)
        center.add(req) { _ in }
        return "已设置每日 \(String(format: "%02d:%02d", hour, minute)) 本机提醒"
    }
    static func disableDailyInspection() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [inspectionID])
    }
}
