import Foundation

/// 仅保留升级清理逻辑。图片/渐变背景的选择、渲染和备份功能已完全删除。
enum NativeBackgroundStore {
    private static let presetKey = "guanpan.native.background.preset"
    private static let gradientKey = "guanpan.native.background.gradient"
    private static let revisionKey = "guanpan.native.background.revision"
    private static let removalMigrationKey = "guanpan.native.background.removedInV212"

    private static var legacyFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("guanpan-custom-background.jpg")
    }

    /// 升级后清除老版本留下的选择和自定义图片，避免无入口的废弃数据继续占空间。
    static func removeLegacyBackgroundIfNeeded() {
        let defaults = UserDefaults.standard
        if let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
        defaults.removeObject(forKey: presetKey)
        defaults.removeObject(forKey: gradientKey)
        defaults.removeObject(forKey: revisionKey)
        defaults.set(true, forKey: removalMigrationKey)
    }
}
