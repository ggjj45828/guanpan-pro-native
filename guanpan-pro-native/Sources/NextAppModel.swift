import Foundation
import SwiftUI
import Combine

enum NextMarketSourceMode: String, Codable, CaseIterable, Identifiable {
    case nasPreferred
    case nasOnly
    case phoneDirect

    var id: String { rawValue }
    var title: String {
        switch self {
        case .nasPreferred: return "NAS优先，断线备用"
        case .nasOnly: return "仅使用NAS"
        case .phoneDirect: return "手机直连优先"
        }
    }
    var detail: String {
        switch self {
        case .nasPreferred: return "报价、日K、分时和新闻先取NAS；失败才切手机来源。长期分时研究仍由NAS提供。"
        case .nasOnly: return "报价、日K、分时和新闻只取NAS；NAS不可用时保留旧缓存，不会悄悄切到手机直连。"
        case .phoneDirect: return "手机多源直连获取报价、日K、分时和新闻；NAS只提供长期分时研究与账本同步，减少穿透流量。"
        }
    }
}

struct LocalPreferences: Codable {
    var goal = NextGoal()
    var watch = ["159941", "563020", "159545", "159352"]
    var navigation = NextNavigationState()
    var theme = GPTheme.light
    /// 字号档位 / 字体族 / 自定义文字·卡片·背景色。
    var appearance = GPAppearance()
    var notifications = NextNotificationCenter()
    var nasBaseURL = ""
    var legacyWebBaseURL = ""
    var nasRevision: Int?
    /// 上次成功上传到 NAS 时本机账本的指纹；和当前账本不一致就说明「有改动没上传」。
    var nasSyncedFingerprint: String?
    /// 上次成功上传的时间，用来在界面上说清"到底什么时候同步过"。
    var nasSyncedAt: Date?
    /// 自动上传本机账本（默认开）。关掉后只保留手动上传。
    var nasAutoUpload = true
    /// Explicitly controls where live quotes/charts come from. Long-term research remains NAS-only.
    var marketSourceMode: NextMarketSourceMode = .phoneDirect
    /// User-configurable estimate for one ETF transaction; actual fills retain broker-reported fee.
    var etfFeePerTrade: Decimal = NextTradeFees.etfPerTrade
    /// 五套视觉主题：nil = 跟随场景（首页编辑室 / 盘中仪表盘 / AI 日报杂志 / 持仓拼图 / 详情现代卡片）。
    /// 用户手动选一套后写成具体值，手动选择永远优先于场景推断。
    var themeStyle: AppTheme?
    enum CodingKeys: String, CodingKey { case goal, watch, navigation, theme, appearance, notifications, nasBaseURL, legacyWebBaseURL, nasRevision, nasSyncedFingerprint, nasSyncedAt, nasAutoUpload, marketSourceMode, etfFeePerTrade, themeStyle }
    init(goal: NextGoal = NextGoal(), watch: [String] = ["159941", "563020", "159545", "159352"], navigation: NextNavigationState = NextNavigationState(), theme: GPTheme = .light, appearance: GPAppearance = GPAppearance(), notifications: NextNotificationCenter = NextNotificationCenter(), nasBaseURL: String = "", legacyWebBaseURL: String = "", nasRevision: Int? = nil, nasSyncedFingerprint: String? = nil, nasSyncedAt: Date? = nil, nasAutoUpload: Bool = true, marketSourceMode: NextMarketSourceMode = .phoneDirect, etfFeePerTrade: Decimal = NextTradeFees.etfPerTrade, themeStyle: AppTheme? = nil) {
        self.goal = goal; self.watch = watch; self.navigation = navigation; self.theme = theme; self.appearance = appearance; self.notifications = notifications
        self.nasBaseURL = nasBaseURL; self.legacyWebBaseURL = legacyWebBaseURL; self.nasRevision = nasRevision
        self.nasSyncedFingerprint = nasSyncedFingerprint; self.nasSyncedAt = nasSyncedAt; self.nasAutoUpload = nasAutoUpload
        self.marketSourceMode = marketSourceMode
        self.etfFeePerTrade = etfFeePerTrade
        self.themeStyle = themeStyle
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decodeIfPresent(NextGoal.self, forKey: .goal) ?? NextGoal()
        watch = try values.decodeIfPresent([String].self, forKey: .watch) ?? ["159941", "563020", "159545", "159352"]
        navigation = try values.decodeIfPresent(NextNavigationState.self, forKey: .navigation) ?? NextNavigationState()
        theme = try values.decodeIfPresent(GPTheme.self, forKey: .theme) ?? .light
        appearance = try values.decodeIfPresent(GPAppearance.self, forKey: .appearance) ?? GPAppearance()
        notifications = try values.decodeIfPresent(NextNotificationCenter.self, forKey: .notifications) ?? NextNotificationCenter()
        nasBaseURL = try values.decodeIfPresent(String.self, forKey: .nasBaseURL) ?? ""
        legacyWebBaseURL = try values.decodeIfPresent(String.self, forKey: .legacyWebBaseURL) ?? ""
        nasRevision = try values.decodeIfPresent(Int.self, forKey: .nasRevision)
        nasSyncedFingerprint = try values.decodeIfPresent(String.self, forKey: .nasSyncedFingerprint)
        nasSyncedAt = try values.decodeIfPresent(Date.self, forKey: .nasSyncedAt)
        nasAutoUpload = try values.decodeIfPresent(Bool.self, forKey: .nasAutoUpload) ?? true
        marketSourceMode = try values.decodeIfPresent(NextMarketSourceMode.self, forKey: .marketSourceMode) ?? .phoneDirect
        etfFeePerTrade = try values.decodeIfPresent(Decimal.self, forKey: .etfFeePerTrade) ?? NextTradeFees.etfPerTrade
        guard NextTradeFees.isValid(etfFeePerTrade) else { throw NextError.invalid("备份中的 ETF 手续费无效") }
        themeStyle = try values.decodeIfPresent(AppTheme.self, forKey: .themeStyle)
    }
}

/// The real ledger and app preferences use separate versioned files.
/// No legacy defaults or mixed OTC records are silently imported.
@MainActor
final class NextLocalRepository {
    private let directory: URL
    private let recoveryDirectory: URL
    private var blockedFiles = Set<String>()
    private(set) var integrityWarning: String?
    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = appSupport ?? fileManager.temporaryDirectory
        directory = directoryOverride ?? base.appendingPathComponent("GuanpanProNative", isDirectory: true)
        recoveryDirectory = directoryOverride?.appendingPathComponent("Recovery", isDirectory: true)
            ?? base.appendingPathComponent("GuanpanProNative-Recovery", isDirectory: true)
        // UI tests run repeatedly in one simulator and otherwise inherit the
        // previous test's saved navigation stack/preferences. Reset only the
        // app's own sandbox when both the test scheme and explicit test flag
        // are present; normal launches never delete persisted account data.
        let args = ProcessInfo.processInfo.arguments
        let isUITestReset = args.contains("-ui-testing") && args.contains("-ui-testing-reset")
        if isUITestReset {
            try? fileManager.removeItem(at: directory)
            try? fileManager.removeItem(at: recoveryDirectory)
        }
        guard appSupport != nil || directoryOverride != nil else {
            integrityWarning = "iOS 未提供持久化应用目录；真实账本写入已停止。"
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        } catch {
            integrityWarning = "本机安全存储无法初始化：\(error.localizedDescription)；真实账本写入已停止。"
        }
    }
    func load<T: Decodable>(_ type: T.Type, filename: String, fallback: T) -> T {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch {
            blockedFiles.insert(filename)
            integrityWarning = "本机数据文件 \(filename) 无法读取或校验；原文件已保留，相关写入已停止。请先导出/恢复经过验证的备份。"
            return fallback
        }
    }
    func loadValidated<T: Decodable>(_ type: T.Type, filename: String, fallback: T,
                                     validate: (T) throws -> Void) -> T {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
            try validate(value)
            return value
        } catch {
            blockedFiles.insert(filename)
            integrityWarning = "本机数据文件 \(filename) 无法读取或校验；原文件已保留，相关写入已停止。请先导出/恢复经过验证的备份。"
            return fallback
        }
    }
    func save<T: Encodable>(_ value: T, filename: String) -> String? {
        if let integrityWarning { return integrityWarning }
        if blockedFiles.contains(filename) { return "\(filename) 校验失败；为避免覆盖原始数据，保存已停止" }
        let url = directory.appendingPathComponent(filename)
        guard let data = try? JSONEncoder().encode(value) else { return "本机数据无法编码" }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            return nil
        } catch { return error.localizedDescription }
    }
    /// Writes a small set of related preference files as one recoverable
    /// operation. If any write fails, previously written files are restored
    /// to their exact pre-operation bytes (or removed if they did not exist).
    func saveTransaction(_ files: [(filename: String, data: Data)]) -> String? {
        if let integrityWarning { return integrityWarning }
        guard Set(files.map { $0.filename }).count == files.count else { return "事务中出现重复文件名" }
        if let blocked = files.first(where: { blockedFiles.contains($0.filename) }) {
            return "\(blocked.filename) 校验失败；为避免覆盖原始数据，保存已停止"
        }
        let fileManager = FileManager.default
        var originals: [String: Data] = [:]
        for file in files {
            let url = directory.appendingPathComponent(file.filename)
            if fileManager.fileExists(atPath: url.path) {
                do { originals[file.filename] = try Data(contentsOf: url) }
                catch { return "无法读取 \(file.filename) 原文件；事务未开始：\(error.localizedDescription)" }
            }
        }
        var written: [String] = []
        do {
            for file in files {
                try file.data.write(to: directory.appendingPathComponent(file.filename), options: .atomic)
                written.append(file.filename)
                try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: directory.appendingPathComponent(file.filename).path)
            }
            return nil
        } catch {
            var rollbackErrors: [String] = []
            for filename in written.reversed() {
                let url = directory.appendingPathComponent(filename)
                do {
                    if let original = originals[filename] {
                        try original.write(to: url, options: .atomic)
                    } else if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                } catch { rollbackErrors.append("\(filename): \(error.localizedDescription)") }
            }
            let rollback = rollbackErrors.isEmpty ? "" : "；回滚失败（\(rollbackErrors.joined(separator: "、"))），请立即检查本地设置文件"
            return "多文件设置保存失败：\(error.localizedDescription)\(rollback)"
        }
    }
    func writeSafetyCopy(_ archive: NextArchiveEnvelope) throws -> URL {
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let url = recoveryDirectory.appendingPathComponent("before-restore-\(UUID().uuidString).guanpanbackup")
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }
    func writeRawSafetyCopy() throws -> URL {
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let url = recoveryDirectory.appendingPathComponent("before-restore-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: directory, to: url)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }
    func replaceAll(with archive: NextAppArchive) throws {
        try archive.validate()
        let encoder = JSONEncoder()
        let files: [(String, Data)] = [
            ("real-ledger-v1.json", try encoder.encode(NextAuditedBook(current: archive.book, events: archive.audits))),
            ("preferences-v1.json", try encoder.encode(LocalPreferences(goal: archive.goal, watch: archive.watch, navigation: archive.navigation, theme: GPTheme(rawValue: archive.theme.rawValue) ?? .light, notifications: archive.notifications, themeStyle: archive.appTheme))),
            ("cached-quotes-v1.json", try encoder.encode(archive.cachedQuotes)),
            ("chart-history-v1.json", try encoder.encode(archive.chartData)),
            ("instrument-rules-v1.json", try encoder.encode(archive.instrumentRules)),
            ("order-books-v1.json", try encoder.encode(archive.orderBooks)),
            ("decision-history-v1.json", try encoder.encode(archive.decisionHistory)),
            ("nas-research-v1.json", try encoder.encode(archive.nasResearch)),
            ("decision-memory-v1.json", try encoder.encode(archive.decisionMemory)),
            ("dividend-history-v1.json", try encoder.encode(archive.dividendEvents)),
            ("patient-limit-plans-v1.json", try encoder.encode(archive.patientLimitPlans)),
            ("candidate-plans-v1.json", try encoder.encode(archive.candidatePlans)),
            ("investor-profile-v1.json", try encoder.encode(archive.profile)),
            ("ai-suggestions-v1.json", try encoder.encode(archive.suggestions))
        ]
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("GuanpanProNative-staging-\(UUID().uuidString)", isDirectory: true)
        let prior = recoveryDirectory.appendingPathComponent("pre-restore-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for (name, data) in files {
                let url = staging.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.moveItem(at: directory, to: prior) }
            do { try FileManager.default.moveItem(at: staging, to: directory) }
            catch {
                if FileManager.default.fileExists(atPath: prior.path) { try? FileManager.default.moveItem(at: prior, to: directory) }
                throw error
            }
            blockedFiles.removeAll()
            integrityWarning = nil
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
