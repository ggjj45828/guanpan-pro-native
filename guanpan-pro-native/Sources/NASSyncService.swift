import Foundation
import CryptoKit
import Security
import CoreFoundation

struct NativeSyncDocument: Codable {
    var schemaVersion: Int = 1
    var updatedAt: Date = .now
    var data: PortfolioData
    var intradayBars: [IntradayBar]
    var dailyBars: [DailyBar]
}

struct NASSyncResponse: Decodable {
    var ok: Bool?
    var err: String?
    var revision: Int
    var updatedAt: String?
    var data: NativeSyncDocument?
}

struct NASSyncVersion: Decodable, Identifiable {
    var revision: Int
    var updatedAt: String
    var id: Int { revision }
}

private struct NASSyncHistoryResponse: Decodable {
    var ok: Bool?
    var err: String?
    var versions: [NASSyncVersion]
}

private struct NASSyncErrorResponse: Decodable { var err: String? }

enum NASSyncService {
    static let urlKey = "guanpan.native.nas.url"
    static let tokenKey = "guanpan.native.nas.token"
    static let automaticKey = "guanpan.native.nas.automatic"
    static let revisionKey = "guanpan.native.nas.revision"
    static let fingerprintKey = "guanpan.native.nas.fingerprint"

    static func fingerprint(_ document: NativeSyncDocument) throws -> String {
        struct Content: Encodable {
            var data: PortfolioData
            var intradayBars: [IntradayBar]
            var dailyBars: [DailyBar]
        }
        // 现价、涨跌幅和时间戳是高频缓存。若把它们计入冲突指纹，前台每次行情刷新
        // 都会被判断为“账本已修改”，导致 NAS 版本每分钟滚动并制造假冲突。
        // 自选成员、名称、分组、持仓份额/成本等真实账本字段仍参与指纹。
        var stableData = document.data
        for index in stableData.quotes.indices {
            stableData.quotes[index].price = 0
            stableData.quotes[index].changePct = 0
            stableData.quotes[index].updatedAt = nil
        }
        for index in stableData.holdings.indices where stableData.holdings[index].kind == .etf {
            stableData.holdings[index].current = 0
            stableData.holdings[index].marketUpdatedAt = nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let content = Content(data: stableData, intradayBars: document.intradayBars, dailyBars: document.dailyBars)
        let digest = SHA256.hash(data: try encoder.encode(content))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func endpoint(base: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let root = URL(string: trimmed), ["http", "https"].contains(root.scheme?.lowercased() ?? ""), root.host != nil else {
            throw NASSyncError.invalidAddress
        }
        return root.appendingPathComponent("api").appendingPathComponent("native").appendingPathComponent("data")
    }

    /// Optional authenticated market-data relay through the configured NAS.
    /// Supports both the deployed integrated-server routes (raw upstream body)
    /// and the newer /api/market routes (JSON-wrapped base64 body).
    static func marketProxyData(path: String, queryItems: [URLQueryItem]) async throws -> Data? {
        guard ["quote", "daily", "fundnav", "hold", "minute"].contains(path),
              let base = UserDefaults.standard.string(forKey: urlKey),
              !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: root) else { throw NASSyncError.invalidAddress }
        let query = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, later in later })
        let integratedPath: String
        let integratedQuery: [URLQueryItem]
        switch path {
        case "hold":
            integratedPath = "/api/holdjson"
            integratedQuery = [
                URLQueryItem(name: "code", value: query["code"] ?? ""),
                URLQueryItem(name: "topline", value: query["topline"] ?? "50")
            ]
        case "quote":
            integratedPath = "/api/quote"
            integratedQuery = [URLQueryItem(name: "codes", value: query["codes"] ?? "")]
        case "daily":
            integratedPath = "/api/kline"
            integratedQuery = [
                URLQueryItem(name: "code", value: query["symbol"] ?? ""),
                URLQueryItem(name: "period", value: "day"),
                URLQueryItem(name: "n", value: query["count"] ?? "640"),
                URLQueryItem(name: "fq", value: "qfq")
            ]
        case "minute":
            integratedPath = "/api/minute"
            integratedQuery = [URLQueryItem(name: "code", value: query["code"] ?? "")]
        default:
            integratedPath = "/api/fundinfo"
            integratedQuery = [URLQueryItem(name: "code", value: query["code"] ?? "")]
        }
        let candidates: [(String, [URLQueryItem], Bool)] = [
            (integratedPath, integratedQuery, false),
            ("/api/market/\(path)", queryItems, true)
        ]
        var lastError: Error = NASSyncError.server("NAS 行情代理未返回有效数据")
        for (path, items, wrapped) in candidates {
            var candidate = components
            let basePath = candidate.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            candidate.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
                .filter { !$0.isEmpty }.joined(separator: "/"))
            candidate.queryItems = items
            guard let url = candidate.url else { throw NASSyncError.invalidAddress }
            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            if let token = NASCredentialStore.load(), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (bytes, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NASSyncError.server("NAS 行情代理 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                if wrapped {
                    guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let encoded = object["dataBase64"] as? String,
                          let decoded = Data(base64Encoded: encoded) else {
                        let detail = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["err"] as? String
                        throw NASSyncError.server(detail ?? "NAS 行情代理包装格式无效")
                    }
                    return decoded
                }
                return bytes
            } catch { lastError = error }
        }
        throw lastError
    }

    static func legacyBackup(base: String, token: String) async throws -> (revision: Int, data: Data?) {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: root), ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else {
            throw NASSyncError.invalidAddress
        }
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("data")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        guard (200...299).contains(http.statusCode),
              let rootObject = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw NASSyncError.server("无法读取 NAS 网页账本（HTTP \(http.statusCode)）")
        }
        if let error = rootObject["err"] as? String { throw NASSyncError.server(error) }
        let payload = rootObject["data"] as? [String: Any]
        let encoded = try payload.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
        return (rootObject["revision"] as? Int ?? 0, encoded)
    }

    static func request(base: String, token: String, method: String, path: String = "/api/native/data", body: Data? = nil) async throws -> NASSyncResponse {
        let url: URL
        if path == "/api/native/data" { url = try endpoint(base: base) }
        else {
            let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let baseURL = URL(string: root), ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else { throw NASSyncError.invalidAddress }
            url = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/")
                .reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        let decoded = try? JSONDecoder.nasSync.decode(NASSyncResponse.self, from: bytes)
        if !(200...299).contains(http.statusCode) {
            if http.statusCode == 409 { throw NASSyncError.conflict(decoded?.err ?? "NAS 上的数据已变化") }
            if http.statusCode == 404 && path.hasSuffix("/history") {
                throw NASSyncError.server("当前一体化服务器包没有开放历史版本列表接口；账本同步不受影响")
            }
            if http.statusCode == 404 && path.hasSuffix("/restore") {
                throw NASSyncError.server("当前一体化服务器包没有开放历史版本恢复接口；账本同步不受影响")
            }
            throw NASSyncError.server(decoded?.err ?? "HTTP \(http.statusCode)")
        }
        guard let decoded else { throw NASSyncError.invalidResponse }
        return decoded
    }

    static func get(base: String, token: String) async throws -> NASSyncResponse {
        try await request(base: base, token: token, method: "GET")
    }

    static func ping(base: String, token: String) async throws -> NASSyncResponse {
        try await request(base: base, token: token, method: "GET", path: "/api/native/ping")
    }

    static func history(base: String, token: String) async throws -> [NASSyncVersion] {
        let url = try endpoint(base: base).deletingLastPathComponent().appendingPathComponent("history")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        if http.statusCode == 404 {
            throw NASSyncError.server("当前一体化服务器包没有开放历史版本列表接口；账本同步不受影响")
        }
        guard (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(NASSyncHistoryResponse.self, from: bytes) else {
            let error = (try? JSONDecoder().decode(NASSyncErrorResponse.self, from: bytes))?.err
            throw NASSyncError.server(error ?? "读取 NAS 历史版本失败（HTTP \(http.statusCode)）")
        }
        return decoded.versions
    }

    static func restore(base: String, token: String, revision: Int,
                        expectedRevision: Int) async throws -> NASSyncResponse {
        let body = try JSONEncoder().encode(Restore(revision: revision, expectedRevision: expectedRevision))
        return try await request(base: base, token: token, method: "POST",
                                 path: "/api/native/restore", body: body)
    }

    static func put(base: String, token: String, document: NativeSyncDocument,
                    expectedRevision: Int, allowEmptyOverwrite: Bool = false) async throws -> NASSyncResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Upload(data: document, expectedRevision: expectedRevision,
                                             allowEmptyOverwrite: allowEmptyOverwrite))
        return try await request(base: base, token: token, method: "POST", body: body)
    }

    private struct Upload: Encodable {
        var data: NativeSyncDocument
        var expectedRevision: Int
        var allowEmptyOverwrite: Bool
    }

    private struct Restore: Encodable {
        var revision: Int
        var expectedRevision: Int
    }
}

private extension JSONDecoder {
    static var nasSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum NASSyncError: LocalizedError {
    case invalidAddress, invalidResponse
    case conflict(String), server(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请填写完整的 NAS 地址，例如 http://192.168.1.20:8788。"
        case .invalidResponse: return "NAS 返回的数据格式无法识别。"
        case .conflict(let message), .server(let message): return message
        }
    }
}

enum NASCredentialStore {
    private static let service = "com.guanpan.pro.native.nas"
    private static let account = "sync-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let update: [String: Any] = [kSecValueData as String: Data(cleaned.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = key
            update.forEach { insert[$0.key] = $0.value }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
