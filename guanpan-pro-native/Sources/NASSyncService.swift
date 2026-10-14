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

private struct NASMarketArchivePage: Decodable {
    var bars: [IntradayBar]
    var nextOffset: Int
    var hasMore: Bool
}

private struct NASFundNAVArchiveResponse: Decodable {
    var ok: Bool?
    var points: [FundNAVPoint]?
}

enum NASSyncService {
    static let urlKey = "guanpan.native.nas.url"
    static let tokenKey = "guanpan.native.nas.token"
    static let automaticKey = "guanpan.native.nas.automatic"
    static let revisionKey = "guanpan.native.nas.revision"
    static let fingerprintKey = "guanpan.native.nas.fingerprint"
    /// 「同时写回网页版账本」开关（设备本地设置，不随账本同步）。
    static let webLedgerKey = "guanpan.native.nas.webledger"
    /// 写回前那一版网页账本的原样备份（只留最近一次，可一键还原）。
    static let webLedgerBackupKey = "guanpan.native.nas.webledger.backup"
    static let webLedgerBackupDateKey = "guanpan.native.nas.webledger.backup.date"
    /// 上一次成功写回的**网页账本内容指纹**（只覆盖账本字段，见
    /// `WebLedgerWriter.ledgerFingerprint`）。存进 `UserDefaults` 而不是只放内存，
    /// 是为了「内容没变就别再发请求」这条判断**重启后依然成立** ——
    /// 否则每次启动都会白写一份回去。
    static let webLedgerFingerprintKey = "guanpan.native.nas.webledger.fingerprint"
    /// 上一次上传时「分时 / 日 K 档案」的**规模签名**与总条数、以及上传时刻。
    ///
    /// 档案由前台逐分钟自动采集，开一次 App 就会多几根 bar。它**不能**进冲突指纹
    /// （否则每次启动都被判成「本机改了」→ 上传 → NAS 版本 +1，用户原话：
    /// 「每打开一下 app，nas 自动同步一下，而且版本就升一次，这也太废了」）。
    /// 现在改成：条数比上次多 ≥ 400，或距上次上传 ≥ 12 小时，才顺带把档案传一次。
    static let archiveSignatureKey = "guanpan.native.nas.archive.signature"
    static let archiveBarCountKey = "guanpan.native.nas.archive.barcount"
    static let lastSyncAtKey = "guanpan.native.nas.lastsync"
    /// 「自动上传本机改动」开关（设备本地设置，默认开）。
    ///
    /// 用户原话：「我只是想要 nas 收集的数据自动到我手机上，而不是一直往上同步，
    /// 版本还一直变化」。关掉它之后同步只做**下行**：远端版本变了就接收下来，
    /// 本机的改动一个字节都不往上推，NAS 上的版本号也不再滚动。
    /// 手动点「上传到 NAS」不受这个开关限制。
    static let uploadKey = "guanpan.native.nas.upload"

    /// 轻量版本探针：`GET /api/ping` 只回两个文档的版本号，**不带数据**（几十字节）。
    ///
    /// 存在的理由就是省流量：整份原生文档里塞着全部分时与日 K 档案，
    /// 分钟级轮询为了比一个指纹把它整个拉回来，是穿透流量的大头。
    /// 先用这里拿到 `native.revision`，和本机记住的版本号一比就知道远端动没动过。
    ///
    /// 服务器没实现这个接口、或返回结构不是预期的样子时返回 `nil`，
    /// 调用方照旧走完整同步 —— 行为与以前完全一致，不会因为这个探针失败而少同步。
    static func probeRevisions(base: String) async throws -> [String: Int]? {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: root),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil else { throw NASSyncError.invalidAddress }
        var request = URLRequest(url: baseURL.appendingPathComponent("api").appendingPathComponent("ping"))
        request.timeoutInterval = 10
        // 当前服务端的 `/api/ping` 不校验口令，带上也无害；将来若改成要令牌就自动兼容。
        if let token = NASCredentialStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        var result: [String: Int] = [:]
        for key in ["native", "legacy"] {
            if let node = object[key] as? [String: Any], let revision = node["revision"] as? Int {
                result[key] = revision
            }
        }
        return result.isEmpty ? nil : result
    }

    /// 「本机到底有没有真的改动」的**内容指纹**，决定要不要推 NAS。
    ///
    /// 只保留**用户改得动的东西**（持仓、流水、自选成员/名称/分组、现金、净值点、
    /// 快照的日期与现金…）。所有自动采集 / 自动计算的字段一律抹平：
    /// - 自选现价、涨跌幅、报价时间；
    /// - 持仓 `current` 与行情时间 —— 场内是实时行情，场外是每晚自动落账的净值；
    /// - 快照 `total` / `recordedAt` —— 行情一动今日快照就重算，跟用户操作无关；
    /// - 净值点的 `fetchedAt` / `observedDelta` —— 每轮刷新都会重写采集时刻。
    ///
    /// **分时 / 日 K 档案不进这个指纹**（v2.13.41 改）。它们由前台逐分钟自动采集，
    /// 只要开过一次 App 就会新增，于是次次被判成「本机改了」→ 上传 → NAS 版本 +1。
    /// 用户原话：「每打开一下 app，nas 自动同步一下，而且版本就升一次，这也太废了，
    /// 应该是云端检查，发现没变化，就不要了」。档案改用 `archiveSignature` 单独判断
    /// （见 `PortfolioStore.archiveUploadDue`），条数涨够或隔天才顺带传一次。
    static func fingerprint(_ document: NativeSyncDocument) throws -> String {
        struct Content: Encodable {
            var data: PortfolioData
        }
        var stableData = document.data
        for index in stableData.quotes.indices {
            stableData.quotes[index].price = 0
            stableData.quotes[index].changePct = 0
            stableData.quotes[index].updatedAt = nil
        }
        for index in stableData.holdings.indices {
            stableData.holdings[index].current = 0
            stableData.holdings[index].marketUpdatedAt = nil
        }
        for index in stableData.snapshots.indices {
            stableData.snapshots[index].total = 0
            stableData.snapshots[index].recordedAt = nil
        }
        for index in stableData.fundNAVHistory.indices {
            stableData.fundNAVHistory[index].fetchedAt = nil
            stableData.fundNAVHistory[index].observedDelta = nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let digest = SHA256.hash(data: try encoder.encode(Content(data: stableData)))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 分时 / 日 K 档案的**规模签名**：只用「总条数 + 覆盖了多少天 + 日 K 最后一天」，
    /// 让「档案长了一大截」能触发一次上传，又不会因为多了一根 bar 就跑一趟穿透。
    static func archiveSignature(_ document: NativeSyncDocument) -> String {
        let intradayDays = Set(document.intradayBars.map(\.day)).count
        let dailyLast = document.dailyBars.map(\.date).max() ?? ""
        return "\(document.intradayBars.count)|\(intradayDays)|\(document.dailyBars.count)|\(dailyLast)"
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
                URLQueryItem(name: "fq", value: query["fq"] ?? "qfq")
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

    /// Reads the NAS's independent, permanent intraday archive. Pages are fetched
    /// incrementally so a large archive does not create an oversized HTTP response.
    static func marketArchive() async throws -> [IntradayBar] {
        guard let base = UserDefaults.standard.string(forKey: urlKey),
              !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: root) else { throw NASSyncError.invalidAddress }
        let last = UserDefaults.standard.double(forKey: "guanpan.native.nas.marketArchive.lastTimestamp")
        // 两天重叠补偿旧档修正和临时网络中断；首次连接则完整拉取 NAS 已存档案。
        let after = last > 0 ? max(0, Int(last) - 2 * 86_400) : 0
        var offset = 0
        var result: [IntradayBar] = []
        repeat {
            components.path = "/" + ([components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "api/market/archive"]
                .filter { !$0.isEmpty }.joined(separator: "/"))
            components.queryItems = [URLQueryItem(name: "after", value: String(after)),
                                     URLQueryItem(name: "offset", value: String(offset)),
                                     URLQueryItem(name: "limit", value: "5000")]
            guard let url = components.url else { throw NASSyncError.invalidAddress }
            var request = URLRequest(url: url); request.timeoutInterval = 45
            if let token = NASCredentialStore.load(), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["err"] as? String
                throw NASSyncError.server(detail ?? "读取 NAS 分时档案失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let page = try decoder.decode(NASMarketArchivePage.self, from: bytes)
            result.append(contentsOf: page.bars)
            offset = page.nextOffset
            if !page.hasMore { break }
        } while true
        if let newest = result.map({ $0.timestamp.timeIntervalSince1970 }).max() {
            UserDefaults.standard.set(newest, forKey: "guanpan.native.nas.marketArchive.lastTimestamp")
        }
        return result
    }

    /// NAS 在手机离线期间定时采集的基金净值；带首次发现时间，供历史快照补账。
    static func fundNAVArchive(code: String) async throws -> [FundNAVPoint] {
        guard let base = UserDefaults.standard.string(forKey: urlKey),
              !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: root) else { throw NASSyncError.invalidAddress }
        components.path = "/" + ([components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                    "api/fundnav/archive"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components.url else { throw NASSyncError.invalidAddress }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        if let token = NASCredentialStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        if http.statusCode == 404 { return [] } // 旧版 NAS 尚未部署净值归档
        guard (200..<300).contains(http.statusCode) else { throw NASSyncError.server("读取 NAS 基金净值档案失败（HTTP \(http.statusCode)）") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(NASFundNAVArchiveResponse.self, from: bytes)).points ?? []
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

    /// 读取 NAS 上「网页版账本」的原始 JSON（`/api/data` 的 `data` 字段）。
    ///
    /// 写回前**必须**先拿到它：写回只替换账本相关字段，其余键（设置 / 分红参考 / 汇率 /
    /// 自定义休市日 / 网格历史…）一律沿用这份现值，绝不整份覆盖。
    ///
    /// - Returns: 有网页账本时返回它的内容；服务器明确回答「没有数据」时返回 `nil`。
    /// - Throws: 读不到时（HTTP 错误、返回体不是 JSON）抛出 —— 调用方必须**放弃写回**。
    ///   宁可这次不同步，也不能拿一份空文档把网页那份数据清掉。
    static func webLedger(base: String, token: String) async throws -> [String: Any]? {
        let (_, data) = try await legacyBackup(base: base, token: token)
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 把整份网页账本写回 `/api/data`（网页版协议：`{tok, data}`）。
    /// 返回 NAS 报告的新版本号；服务器不给就返回 0。
    @discardableResult
    static func putWebLedger(base: String, token: String, payload: [String: Any]) async throws -> Int {
        let url = try webLedgerURL(base: base)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 两种鉴权都带上：新服务认 Bearer，旧服务认 body 里的 tok。
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["tok": token, "data": payload]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        if let error = object?["err"] as? String, !error.isEmpty { throw NASSyncError.server(error) }
        guard (200...299).contains(http.statusCode) else {
            throw NASSyncError.server("写回网页账本失败（HTTP \(http.statusCode)）")
        }
        return (object?["revision"] as? Int) ?? 0
    }

    private static func webLedgerURL(base: String) throws -> URL {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: root),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil else { throw NASSyncError.invalidAddress }
        return baseURL.appendingPathComponent("api").appendingPathComponent("data")
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
