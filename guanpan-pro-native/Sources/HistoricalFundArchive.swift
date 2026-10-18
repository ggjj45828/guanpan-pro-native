import Foundation
import CryptoKit

/// Keeps a verified, byte-for-byte archive before removing off-exchange history from active data.
enum HistoricalFundArchive {
    static let businessEnabled = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuanpanReadOnlyHistory-v1", isDirectory: true)
    }
    static var permanentArchiveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuanpanOffExchangeHistoryArchive-v1", isDirectory: true)
    }
    static func archiveBytes(_ bytes: Data, label: String, at root: URL? = nil) throws -> URL {
        let destinationRoot = root ?? permanentArchiveDirectory
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let safeLabel = String(label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(60))
        let destination = destinationRoot.appendingPathComponent("\(safeLabel)-\(digest).archive")
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination)
            guard existing == bytes else { throw NSError(domain: "HistoricalFundArchive", code: 3) }
        } else {
            try bytes.write(to: destination, options: .atomic)
        }
        let verified = try Data(contentsOf: destination)
        guard verified == bytes,
              SHA256.hash(data: verified) == SHA256.hash(data: bytes) else {
            throw NSError(domain: "HistoricalFundArchive", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "场外历史归档校验失败，原记录未清理"])
        }
        return destination
    }
    private struct ExportEntry: Codable {
        var name: String
        var bytes: Data
        var sha256: String
    }
    private struct ExportBundle: Codable {
        var formatVersion: Int
        var createdAt: Date
        var entries: [ExportEntry]
    }
    /// Builds a portable one-time export from all verified local archive snapshots.
    static func makeExportBundle(at root: URL? = nil) throws -> Data {
        let manager = FileManager.default
        let archiveRoot = root ?? permanentArchiveDirectory
        guard manager.fileExists(atPath: archiveRoot.path),
              let files = manager.enumerator(at: archiveRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "HistoricalFundArchive", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "没有可导出的已归档场外历史"])
        }
        var entries: [ExportEntry] = []
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: file)
            entries.append(ExportEntry(name: file.lastPathComponent, bytes: bytes, sha256: digest(bytes)))
        }
        guard !entries.isEmpty else {
            throw NSError(domain: "HistoricalFundArchive", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "没有可导出的已归档场外历史"])
        }
        entries.sort { $0.name < $1.name }
        return try JSONEncoder().encode(ExportBundle(formatVersion: 1, createdAt: .now, entries: entries))
    }
    /// Re-reads the exported file and checks every archived source blob before deletion.
    static func verifyExportBundle(_ raw: Data, archiveRoot root: URL? = nil) -> Bool {
        guard let bundle = try? JSONDecoder().decode(ExportBundle.self, from: raw),
              bundle.formatVersion == 1, !bundle.entries.isEmpty else { return false }
        guard bundle.entries.allSatisfy({ digest($0.bytes) == $0.sha256 }) else { return false }
        guard let current = try? archiveInventory(at: root), current.count == bundle.entries.count else { return false }
        let exported = Dictionary(bundle.entries.map { ($0.name, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        return current.allSatisfy { exported[$0.name] == $0.sha256 }
    }
    static func deleteLocalArchivesAfterVerifiedExport(_ raw: Data, archiveRoot: URL? = nil, recoveryRoot: URL? = nil) throws {
        guard verifyExportBundle(raw, archiveRoot: archiveRoot) else {
            throw NSError(domain: "HistoricalFundArchive", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "备份文件校验失败；本机原始数据仍保留"])
        }
        let manager = FileManager.default
        for folder in [recoveryRoot ?? directory, archiveRoot ?? permanentArchiveDirectory] where manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
    }
    static func removePreviouslyConfirmedLocalArchives() throws {
        let manager = FileManager.default
        for folder in [directory, permanentArchiveDirectory] where manager.fileExists(atPath: folder.path) {
            try manager.removeItem(at: folder)
        }
    }
    static var hasLocalArchiveFiles: Bool {
        let manager = FileManager.default
        for folder in [directory, permanentArchiveDirectory] where manager.fileExists(atPath: folder.path) {
            guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in files {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return true }
            }
        }
        return false
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func archiveInventory(at root: URL? = nil) throws -> [(name: String, sha256: String)] {
        let manager = FileManager.default
        let archiveRoot = root ?? permanentArchiveDirectory
        guard manager.fileExists(atPath: archiveRoot.path),
              let files = manager.enumerator(at: archiveRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var items: [(name: String, sha256: String)] = []
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            items.append((name: file.lastPathComponent, sha256: digest(try Data(contentsOf: file))))
        }
        return items.sorted { $0.name < $1.name }
    }
    /// Copies every old recovery artifact to the permanent archive and verifies each copy.
    static func archiveLegacyArtifacts(at folder: URL? = nil, into root: URL? = nil) throws {
        let source = folder ?? directory
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "HistoricalFundArchive", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取旧场外恢复目录；未清理任何记录"])
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let label = "legacy-" + relative
            _ = try archiveBytes(Data(contentsOf: file), label: label, at: root)
        }
    }
    /// Deletion is intentionally opt-in and refuses to run unless the caller has obtained
    /// an explicit user confirmation after verifying the permanent archive.
    static func purgeArtifacts(at folder: URL? = nil, userConfirmedArchive: Bool = false, archiveRoot: URL? = nil) throws {
        let target = folder ?? directory
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard userConfirmedArchive else {
            throw NSError(domain: "HistoricalFundArchive", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "未取得用户确认；原始场外数据保留"])
        }
        try archiveLegacyArtifacts(at: target, into: archiveRoot)
        try FileManager.default.removeItem(at: target)
    }
    static func hasHistory(_ data: PortfolioData) -> Bool {
        let fundCodes = Set(data.holdings.filter { $0.kind == .fund }.map(\.code)
            + data.fundTransactions.map(\.code) + data.fundNAVHistory.map(\.code) + data.fundDCAPlans.map(\.code))
        return data.holdings.contains { $0.kind == .fund } || !data.fundTransactions.isEmpty ||
        !data.fundNAVHistory.isEmpty || !data.fundDCAPlans.isEmpty || !data.fundFeePolicies.isEmpty ||
        !data.fundConstituentSnapshots.isEmpty || data.ledger.contains { $0.kind == .fund } ||
        data.ledger.contains { $0.kind == nil && fundCodes.contains($0.code) } ||
        data.allocationTargets.contains { $0.kind == .fund } || data.tradePlans.contains { $0.kind == .fund }
    }
    /// Cleanup requires explicit confirmation after the user has verified the
    /// exported archive. Merely starting or saving the app never calls this.
    static func removingOffExchange(_ raw: Data, userConfirmedArchive: Bool = false, archiveRoot: URL? = nil) throws -> Data {
        guard userConfirmedArchive else {
            throw NSError(domain: "HistoricalFundArchive", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "请先确认归档备份可读取，再清理场外历史"])
        }
        _ = try archiveBytes(raw, label: "before-explicit-ledger-removal", at: archiveRoot)
        guard var document = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw NSError(domain: "HistoricalFundArchive", code: 2)
        }
        for field in ["holdings", "ledger", "allocationTargets", "tradePlans"] {
            if let rows = document[field] as? [[String: Any]] {
                document[field] = rows.filter { $0["kind"] as? String != "fund" }
            }
        }
        for field in ["fundNAVHistory", "fundTransactions", "fundConstituentSnapshots", "fundFeePolicies", "fundDCAPlans"] {
            if document[field] != nil { document[field] = [] as [String] }
        }
        document["automaticFundNAVRefreshEnabled"] = false
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}
