import Foundation
import CryptoKit

/// Retains the complete original bytes, including unknown legacy fields.
/// Archival never deletes or rewrites PortfolioData or the original UserDefaults key.
enum HistoricalFundArchive {
    static let businessEnabled = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuanpanReadOnlyHistory-v1", isDirectory: true)
    }
    @discardableResult static func preserve(_ raw: Data) throws -> URL {
        _ = try JSONSerialization.jsonObject(with: raw)
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("portfolio-\(hash).json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try raw.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        guard try Data(contentsOf: file) == raw else {
            throw NSError(domain: "HistoricalFundArchive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "历史备份字节校验失败，原账本已保留"])
        }
        return file
    }
    static func hasHistory(_ data: PortfolioData) -> Bool {
        data.holdings.contains { $0.kind == .fund } || !data.fundTransactions.isEmpty ||
        !data.fundNAVHistory.isEmpty || !data.fundDCAPlans.isEmpty || !data.fundFeePolicies.isEmpty ||
        data.ledger.contains { $0.kind == .fund }
    }
}
