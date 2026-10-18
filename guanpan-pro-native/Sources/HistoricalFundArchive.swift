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
    static func purgeArtifacts(at folder: URL? = nil, userConfirmedArchive: Bool = false) throws {
        let target = folder ?? directory
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard userConfirmedArchive else {
            throw NSError(domain: "HistoricalFundArchive", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "未取得用户确认；原始场外数据保留"])
        }
        try archiveLegacyArtifacts(at: target)
        try FileManager.default.removeItem(at: target)
    }
    static func hasHistory(_ data: PortfolioData) -> Bool {
        data.holdings.contains { $0.kind == .fund } || !data.fundTransactions.isEmpty ||
        !data.fundNAVHistory.isEmpty || !data.fundDCAPlans.isEmpty || !data.fundFeePolicies.isEmpty ||
        !data.fundConstituentSnapshots.isEmpty || data.ledger.contains { $0.kind == .fund } ||
        data.allocationTargets.contains { $0.kind == .fund } || data.tradePlans.contains { $0.kind == .fund }
    }
    /// Cleanup requires explicit confirmation after the user has verified the
    /// exported archive. Merely starting or saving the app never calls this.
    static func removingOffExchange(_ raw: Data, userConfirmedArchive: Bool = false) throws -> Data {
        guard userConfirmedArchive else {
            throw NSError(domain: "HistoricalFundArchive", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "请先确认归档备份可读取，再清理场外历史"])
        }
        _ = try archiveBytes(raw, label: "before-explicit-ledger-removal")
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
