import Foundation

/// Removes off-exchange history from active data and old recovery artifacts.
enum HistoricalFundArchive {
    static let businessEnabled = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuanpanReadOnlyHistory-v1", isDirectory: true)
    }
    static func purgeArtifacts(at folder: URL? = nil) throws {
        let target = folder ?? directory
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }
    static func hasHistory(_ data: PortfolioData) -> Bool {
        data.holdings.contains { $0.kind == .fund } || !data.fundTransactions.isEmpty ||
        !data.fundNAVHistory.isEmpty || !data.fundDCAPlans.isEmpty || !data.fundFeePolicies.isEmpty ||
        !data.fundConstituentSnapshots.isEmpty || data.ledger.contains { $0.kind == .fund } ||
        data.allocationTargets.contains { $0.kind == .fund } || data.tradePlans.contains { $0.kind == .fund }
    }
    /// Explicitly requested removal of off-exchange records. Cash and shared
    /// snapshots/flows retain their original facts; a deletion is not a sale.
    static func removingOffExchange(_ raw: Data) throws -> Data {
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
