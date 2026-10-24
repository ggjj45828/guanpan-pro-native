import Foundation

struct NextNASStatus {
    let revision: Int
    let hasBook: Bool
    let book: NextBook?
}
/// NAS 上保存的账本历史版本。每次写入 NAS 都会留一份完整 JSON，
/// 这里只取元数据，免得一次拉回几十份整账本。
struct NextNASBookVersion: Decodable, Identifiable {
    let revision: Int
    let bytes: Int
    let current: Bool
    var id: Int { revision }
    var sizeText: String {
        bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
    }
}
struct NextNASBookHistory: Decodable {
    let bookId: String
    let current: Int
    let versions: [NextNASBookVersion]
}

/// `/v1/ai/verify` 的返回。`state == "verified"` 才代表 NAS 上的 key、模型和出网都真的通了。
struct NextNASAIVerify: Decodable {
    let state: String
    let profile: String?
    let model: String?
    let message: String?
}

struct NextNASHealth: Decodable {
    let service: String
    let schemaVersion: Int
    let aiProvider: NextAIProviderStatus?
}
struct NextNASAIAnalysis: Decodable {
    let code: String
    let provider: String
    let model: String
    let content: String
    let realOrder: Bool
    let createdAt: String
}
struct NextAdvisorInventory: Decodable {
    struct Position: Decodable, Identifiable {
        var id: String { code }
        let code: String
        let name: String
        let units: Int
        let days: Int
        let completeDays: Int
        let firstDay: String?
        let lastDay: String?
        let decision: String
        let reasons: [String]
    }
    let bookRevision: Int
    let notice: String
    let positions: [Position]
}
struct NextAdvisorAnalysis: Decodable {
    struct Position: Decodable, Identifiable {
        struct CostBasis: Decodable {
            let bookCost: String?
            let averageCostPerUnit: String?
            let breakEvenBeforeExitFee: String?
            let breakEvenAfterOneEstimatedExitFee: String?
            let unrealizedPnlBeforeExitFee: String?
            let unrealizedReturnBeforeExitFeePercent: String?
        }
        var id: String { code }
        let code: String
        let name: String
        let units: Int
        let decision: String
        let qualifiedDays: Int
        // 以下三个为可选字段：旧版 NAS 不返回时解码为 nil，界面不显示，不影响老部署。
        let dailyStats: [String: NextJSONValue]?
        let intradayEvidence: [String: NextJSONValue]?
        let plan: [String: NextJSONValue]?
        let costBasis: CostBasis?
        let portfolioWeightPercent: String?
        let availableUnitsBasis: String?
        let risks: [String]
    }
    struct AI: Decodable { let state: String; let provider: String?; let model: String?; let content: String?; let message: String? }
    struct NewsItem: Decodable, Identifiable { var id: String { url }; let title: String; let url: String; let publishedAt: String?; let source: String? }
    struct News: Decodable, Identifiable { var id: String { code }; let code: String; let name: String; let state: String; let provider: String; let items: [NewsItem] }
    let bookRevision: Int
    let notice: String
    /// 服务端发现交易规则配置问题（缺费率/缺交割方式等）时列出；旧版 NAS 不返回为 nil。
    let ruleConfigurationIssues: [String]?
    let positions: [Position]
    let news: [News]
    let ai: AI
}
enum NextJSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: NextJSONValue]), array([NextJSONValue]), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: NextJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([NextJSONValue].self)) }
    }
    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return "—"
        case .object(let value):
            return value.keys.sorted().map { "\($0)=\(value[$0]!.displayText)" }.joined(separator: "; ")
        case .array(let values):
            return values.map(\.displayText).joined(separator: " | ")
        }
    }
}
struct NextAIProviderStatus: Decodable {
    let state: String
    let configured: Bool
    let profile: String?
    let model: String?
    let message: String

    enum CodingKeys: String, CodingKey { case state, configured, profile, model, message }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        configured = try values.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? "NAS 未返回 AI 配置状态"
    }
}
struct NextLegacyBookSummary: Decodable {
    let positions: Int
    let fills: Int
    let cashMovements: Int
    let history: Int
    let cash: Decimal?
    let watchCodes: [String]?
    let skippedPositions: Int
    let skippedTrades: Int
    let ignoredOTCFunds: Int
    let dividendEvents: Int?
}
struct NextLegacyBookPreview: Decodable {
    let revision: Int
    let book: NextBook?
    let summary: NextLegacyBookSummary?
}

enum NextNASService {
    static func analyzeRealHoldings(baseURL: String, book: NextBook, rules: [String: NextInstrumentRules], now: Date = Date(), session: URLSession = .shared) async throws -> NextAdvisorAnalysis {
        var rulePayload: [String: [String: Any]] = [:]
        for position in book.positions where position.units > 0 {
            guard let rule = rules[position.code], rule.isVerified, rule.assetClass == .etf,
                  let lot = rule.lotSize, let fee = rule.feePerTrade else { continue }
            rulePayload[position.code] = ["verified": true, "source": rule.source,
                "verifiedAt": ISO8601DateFormatter().string(from: rule.verifiedAt ?? now),
                "settlement": rule.settlement.rawValue, "lotSize": lot,
                "feePerTrade": NSDecimalNumber(decimal: fee).stringValue]
        }
        let body = try JSONSerialization.data(withJSONObject: ["userConfirmed": true, "rules": rulePayload])
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("advisor").appendingPathComponent("analyze")
        var request = URLRequest(url: url, timeoutInterval: 120); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        NextNASService.attachAdvisorToken(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("顾问分析失败：\(serverMessage(data, status: (response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return try JSONDecoder().decode(NextAdvisorAnalysis.self, from: data)
    }
    static func advisorInventory(baseURL: String, session: URLSession = .shared) async throws -> NextAdvisorInventory {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("advisor").appendingPathComponent("inventory")
        var request = URLRequest(url: url, timeoutInterval: 15)
        NextNASService.attachAdvisorToken(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("顾问检查失败：\(serverMessage(data, status: (response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        return try JSONDecoder().decode(NextAdvisorInventory.self, from: data)
    }
    /// 顾问接口口令（r31 安全加固）：用户在「我的」保存了 ≥32 位口令就带上 Bearer 头。
    /// 新旧 NAS 都兼容——旧服务端不校验该头，新服务端（GUANPAN_ADVISOR_TOKEN）必须校验。
    /// 没保存口令时不发头；此时连新服务端会返回 401/503，设置页会提示保存口令。
    static func attachAdvisorToken(_ request: inout URLRequest) {
        if let token = AdvisorAccessToken.load(), token.count >= 32 {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
    static func validateURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && isTrustedLocalHost(host))),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入 NAS 的 HTTPS 地址；家庭局域网可用 http://NAS内网地址:8789")
        }
        return url
    }

    static func validateLegacySourceURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              (scheme == "https" || (scheme == "http" && isTrustedLocalHost(host))),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil, url.password == nil else {
            throw NextError.invalid("请输入旧网页根地址；家庭网络可用 http://NAS内网地址:8789，外网请用 HTTPS")
        }
        return url
    }
    static func downloadAndStageLegacyBook(legacyBaseURL: String, newNASBaseURL: String, session: URLSession = .shared) async throws -> Int {
        let oldURL = try validateLegacySourceURL(legacyBaseURL).appendingPathComponent("api").appendingPathComponent("data")
        let (oldData, oldResponse) = try await session.data(for: URLRequest(url: oldURL, timeoutInterval: 20))
        guard let oldHTTP = oldResponse as? HTTPURLResponse, oldHTTP.statusCode == 200 else {
            throw NextError.invalid("旧网页 /api/data 下载失败（HTTP \((oldResponse as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: oldData) as? [String: Any] else { throw NextError.invalid("旧网页返回格式不是 JSON 对象") }
        let source: Any
        if let wrapped = envelope["data"] as? [String: Any] { source = wrapped }
        else if let text = envelope["data"] as? String, let bytes = text.data(using: .utf8) { source = try JSONSerialization.jsonObject(with: bytes) }
        else { source = envelope }
        guard let sourceObject = source as? [String: Any] else { throw NextError.invalid("旧网页账本数据不是对象") }

        // Ask the new NAS to validate and convert before putting anything in its
        // isolated migration inbox. This endpoint has no write side effect.
        let previewURL = try validateURL(newNASBaseURL).appendingPathComponent("v1").appendingPathComponent("legacy").appendingPathComponent("books").appendingPathComponent("main")
        let previewBody = try JSONSerialization.data(withJSONObject: ["data": sourceObject])
        var previewRequest = URLRequest(url: previewURL, timeoutInterval: 20); previewRequest.httpMethod = "POST"; previewRequest.httpBody = previewBody
        previewRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (checkData, checkResponse) = try await session.data(for: previewRequest)
        guard let checkHTTP = checkResponse as? HTTPURLResponse, checkHTTP.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: checkData) as? [String: Any])?["error"] as? String ?? "旧账本无法安全转换"
            throw NextError.invalid(message)
        }
        let stageURL = try validateURL(newNASBaseURL).appendingPathComponent("api").appendingPathComponent("data")
        let (currentData, currentResponse) = try await session.data(for: URLRequest(url: stageURL, timeoutInterval: 10))
        guard let currentHTTP = currentResponse as? HTTPURLResponse, currentHTTP.statusCode == 200,
              let current = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              let revision = current["revision"] as? Int else { throw NextError.invalid("新版 NAS 迁移暂存区读取失败") }
        let body = try JSONSerialization.data(withJSONObject: ["mode": "legacy-stage-confirmed", "expectedRevision": revision, "data": sourceObject])
        var stageRequest = URLRequest(url: stageURL, timeoutInterval: 20); stageRequest.httpMethod = "POST"; stageRequest.httpBody = body
        stageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (savedData, savedResponse) = try await session.data(for: stageRequest)
        guard let savedHTTP = savedResponse as? HTTPURLResponse else { throw NextError.invalid("新版 NAS 没有返回迁移保存状态") }
        if savedHTTP.statusCode == 409 { throw NextError.invalid("新版 NAS 暂存版本已变化，请重新开始下载") }
        guard savedHTTP.statusCode == 200,
              let saved = try JSONSerialization.jsonObject(with: savedData) as? [String: Any],
              let savedRevision = saved["revision"] as? Int else { throw NextError.invalid("新版 NAS 暂存旧账本失败（HTTP \(savedHTTP.statusCode)）") }
        return savedRevision
    }
    static func previewLegacyBook(baseURL: String, session: URLSession = .shared) async throws -> NextLegacyBookPreview {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("legacy").appendingPathComponent("books").appendingPathComponent("main")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("旧网页账本转换预览读取失败") }
        return try JSONDecoder().decode(NextLegacyBookPreview.self, from: data)
    }

    /// Permit cleartext only for loopback/private LAN NAS endpoints. Public hosts
    /// must use HTTPS; this is needed for the documented direct 8789 home-LAN URL.
    private static func isTrustedLocalHost(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if (host.hasPrefix("fc") || host.hasPrefix("fd")) && host.contains(":") { return true } // IPv6 unique-local
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
    /// 服务端拒绝时会返回 `{"error": "..."}`，以前这里直接丢掉，界面只剩「HTTP 400」，
    /// 用户根本没法判断是字段不对、修订冲突还是鉴权问题。现在原样带出来。
    static func serverMessage(_ data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = (object["error"] as? String) ?? (object["message"] as? String), !text.isEmpty {
            return "\(text)（HTTP \(status)）"
        }
        let raw = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "HTTP \(status)" : "\(raw)（HTTP \(status)）"
    }

    static func checkHealth(baseURL: String, session: URLSession = .shared) async throws -> NextNASHealth {
        let url = try validateURL(baseURL).appendingPathComponent("health")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 8))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无 HTTP 响应"
            throw NextError.invalid("NAS 健康检查失败（\(status)）")
        }
        let health = try JSONDecoder().decode(NextNASHealth.self, from: data)
        guard health.service == "guanpan-advisor", health.schemaVersion == 1 else { throw NextError.invalid("连接到的服务不是兼容的 Guanpan Advisor NAS") }
        return health
    }
    static func readStatus(baseURL: String, session: URLSession = .shared) async throws -> NextNASStatus {
        let (data, response) = try await session.data(for: URLRequest(url: try endpoint(baseURL), timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("NAS 账本读取失败：\(serverMessage(data, status: (response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        let value = try JSONDecoder().decode(RemoteBook.self, from: data)
        let book = try value.bookJSON.map { try JSONDecoder().decode(NextBook.self, from: Data($0.utf8)).validated() }
        return NextNASStatus(revision: value.revision, hasBook: value.bookJSON != nil, book: book)
    }
    static func pushBook(_ book: NextBook, expectedRevision: Int, baseURL: String, session: URLSession = .shared) async throws -> Int {
        let bookData = try JSONEncoder().encode(book)
        let body = try JSONSerialization.data(withJSONObject: ["mode": "manual-confirmed", "expectedRevision": expectedRevision, "bookJSON": String(decoding: bookData, as: UTF8.self)])
        var request = URLRequest(url: try endpoint(baseURL), timeoutInterval: 15); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        if http.statusCode == 409 { throw NextError.invalid("NAS 账本版本已变化；没有覆盖数据，请重新下载核对或用「强制覆盖」。\(serverMessage(data, status: 409))") }
        guard http.statusCode == 200 else { throw NextError.invalid("NAS 保存失败：\(serverMessage(data, status: http.statusCode))；本机账本未修改") }
        return try JSONDecoder().decode(RevisionResponse.self, from: data).revision
    }
    /// 让 NAS 用自己配置的 key 发一条最小探针（不携带持仓/行情），验证 AI 是否真的可用。
    static func verifyAI(baseURL: String, session: URLSession = .shared) async throws -> NextNASAIVerify {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("ai").appendingPathComponent("verify")
        // DeepSeek 冷启动可能较慢，给足 40 秒。
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 40))
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        if http.statusCode == 200 {
            return try JSONDecoder().decode(NextNASAIVerify.self, from: data)
        }
        struct Failure: Decodable { let error: String?; let message: String? }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        throw NextError.invalid(failure?.error ?? failure?.message ?? "AI 验证失败（HTTP \(http.statusCode)）")
    }

    /// 列出 NAS 上的账本历史版本。
    static func readBookHistory(baseURL: String, session: URLSession = .shared) async throws -> NextNASBookHistory {
        let url = try endpoint(baseURL).appendingPathComponent("history")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("NAS 备份版本读取失败（\((response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无响应")）")
        }
        return try JSONDecoder().decode(NextNASBookHistory.self, from: data)
    }

    /// 删除 NAS 上的某一个历史版本。当前生效版本服务端会拒绝（409）。
    static func deleteBookVersion(_ revision: Int, baseURL: String, session: URLSession = .shared) async throws {
        let url = try endpoint(baseURL).appendingPathComponent("history").appendingPathComponent(String(revision))
        var request = URLRequest(url: url, timeoutInterval: 10); request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 没有返回 HTTP 状态") }
        if http.statusCode == 409 { throw NextError.invalid("这是当前生效版本，不能删除；先推送一次新版本再删") }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(http.statusCode)"
            throw NextError.invalid("删除失败：\(message)")
        }
    }

    /// 只保留最近 `keep` 个版本，返回被删掉的个数。
    static func pruneBookHistory(keep: Int, baseURL: String, session: URLSession = .shared) async throws -> Int {
        var components = URLComponents(url: try endpoint(baseURL).appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "keep", value: String(keep))]
        var request = URLRequest(url: components.url!, timeoutInterval: 15); request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("清理失败（\((response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无响应")）")
        }
        struct PruneResult: Decodable { let removed: Int }
        return try JSONDecoder().decode(PruneResult.self, from: data).removed
    }

    static func fetchMinute(code: String, day: Date, baseURL: String, session: URLSession = .shared) async throws -> NextChartDataset {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd"
        var parts = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("minute").appendingPathComponent(code), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "day", value: formatter.string(from: day))]
        let (data, response) = try await session.data(for: URLRequest(url: parts.url!, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 分时档案读取失败") }
        let payload = try JSONDecoder().decode(MinuteWire.self, from: data)
        guard payload.code == code, !payload.rows.isEmpty else { throw NextError.invalid("该日期还没有 NAS 分时档案") }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let samples = try payload.rows.map { row -> NextChartSample in
            guard let stamp = iso.date(from: row.timestamp), let price = Decimal(string: row.price), price > 0,
                  (row.volume.flatMap({ Decimal(string: $0) }).map({ $0 >= 0 }) ?? true) else {
                throw NextError.invalid("NAS 分时档案时间、价格或成交量无效")
            }
            let iopv = row.iopv.flatMap { Decimal(string: $0) }
            guard iopv.map({ $0 > 0 }) ?? true else { throw NextError.invalid("NAS 分时 IOPV 无效") }
            return NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil, close: price, iopv: iopv, volume: row.volume.flatMap({ Decimal(string: $0) }))
        }
        let dataset = NextChartDataset(code: code, interval: .intraday, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                       priceSource: "NAS 永久分时档案 · \(payload.day)",
                                       iopvSource: samples.contains(where: { $0.iopv != nil }) ? "NAS 分钟采样核验 · Tencent ETF IOPV" : nil,
                                       observedAt: Date())
        try dataset.validate()
        return dataset
    }
    private struct MinuteWire: Decodable { let code: String; let day: String; let source: String; let rows: [MinuteRow] }
    private struct MinuteRow: Decodable { let timestamp: String; let price: String; let volume: String?; let iopv: String? }

    static func fetchDividendEvents(code: String, baseURL: String, session: URLSession = .shared) async throws -> [NextETFDividendEvent] {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("dividends").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 分红历史暂不可用") }
        let wire = try JSONDecoder().decode(DividendWire.self, from: data)
        guard wire.code == code else { throw NextError.invalid("NAS 分红历史证券代码不一致") }
        return try wire.events.map { row in
            guard let amount = Decimal(string: row.amountPerShare, locale: Locale(identifier: "en_US_POSIX")) else { throw NextError.invalid("NAS 分红金额格式无效") }
            let event = NextETFDividendEvent(code: row.code, date: row.date, amountPerShare: amount, isEstimated: row.isEstimated,
                                             recordDate: row.recordDate, payDate: row.payDate)
            try event.validate(); return event
        }
    }

    static func analyzeETF(context: [String: Any], baseURL: String, session: URLSession = .shared) async throws -> NextNASAIAnalysis {
        guard let security = context["security"] as? [String: Any],
              let code = security["code"] as? String, code.count == 6, code.allSatisfy(\.isNumber) else {
            throw NextError.invalid("AI 研究证券上下文无效")
        }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("ai").appendingPathComponent("analyze")
        var request = URLRequest(url: url, timeoutInterval: 55); request.httpMethod = "POST"
        // 与网页一致：只发 6 位代码，由 NAS 用账本 + 行情 + 日K + 分红拼出 context。
        // 客户端各自拼 schema，一旦与服务端口径不一致就会被判 "analysis context schema is invalid"。
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userConfirmed": true, "code": code], options: [.fragmentsAllowed])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS AI 没有返回 HTTP 状态") }
        guard http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NextError.invalid("NAS AI 分析失败：\(message ?? "HTTP \(http.statusCode)")")
        }
        let result = try JSONDecoder().decode(NextNASAIAnalysis.self, from: data)
        guard result.code == code, result.realOrder == false, !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NextError.invalid("NAS AI 返回内容未通过证券和真实交易安全校验")
        }
        return result
    }
    private struct DividendWire: Decodable {
        let code: String; let source: String; let fetchedAt: String?; let events: [Event]
        struct Event: Decodable { let code: String; let date: String; let amountPerShare: String; let isEstimated: Bool?; let recordDate: String?; let payDate: String? }
    }

    static func fetchResearch(code: String, baseURL: String, session: URLSession = .shared) async throws -> NextNASResearch {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("research").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 研究记录暂不可用") }
        let report = try JSONDecoder().decode(NextNASResearch.self, from: data)
        guard report.ai.map({ $0.code == code && !$0.realOrder }) ?? true,
              report.factors.map({ $0.code == code }) ?? true else { throw NextError.invalid("NAS 研究记录与证券不符") }
        return report
    }

    /// 新闻标题（只拿标题/来源/链接，不拿正文）。
    /// 新闻必须能落到具体持仓才进结论，所以按证券代码单独取，由调用方决定影响。
    private struct NewsWire: Decodable {
        let code: String
        let name: String?
        let state: String
        let provider: String?
        let items: [Item]
        let cached: Bool?
        struct Item: Decodable { let title: String; let url: String?; let publishedAt: String?; let source: String? }
    }

    static func fetchNews(code: String, baseURL: String, session: URLSession = .shared) async throws -> (items: [NextNewsInput], state: String) {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("news").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("NAS 新闻接口暂不可用")
        }
        let wire = try JSONDecoder().decode(NewsWire.self, from: data)
        guard wire.code == code else { throw NextError.invalid("NAS 新闻与证券不符") }
        let items = wire.items.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { NextNewsInput(title: $0.title, source: $0.source, publishedAt: $0.publishedAt, url: $0.url) }
        return (items, wire.state)
    }

    static func fetchDaily(code: String, baseURL: String, session: URLSession = .shared) async throws -> NextChartDataset {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("daily").appendingPathComponent(code)
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse else { throw NextError.invalid("NAS 日 K 请求没有收到 HTTP 响应") }
        guard http.statusCode == 200 else {
            let reason = http.statusCode == 404 ? "NAS 服务没有日 K 接口，请更新 NAS 服务包" : http.statusCode == 503 ? "NAS 无缓存且上游日 K 数据源暂不可用" : "HTTP \(http.statusCode)"
            throw NextError.invalid("NAS 日 K 暂不可用：\(reason)")
        }
        let wire = try JSONDecoder().decode(DailyWire.self, from: data)
        guard wire.code == code, !wire.bars.isEmpty else { throw NextError.invalid("NAS 日 K 代码或数据无效") }
        let dayFormat = DateFormatter(); dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = TimeZone(identifier: "Asia/Shanghai"); dayFormat.dateFormat = "yyyy-MM-dd"
        let samples = try wire.bars.map { row -> NextChartSample in
            guard let date = dayFormat.date(from: row.date), let open = Decimal(string: row.open),
                  let high = Decimal(string: row.high), let low = Decimal(string: row.low),
                  let close = Decimal(string: row.close), let volume = Decimal(string: row.volume),
                  low <= min(open, close), high >= max(open, close) else { throw NextError.invalid("NAS 日 K 数据校验失败") }
            return NextChartSample(timestamp: date, open: open, high: high, low: low, close: close, iopv: nil, volume: volume)
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = iso.date(from: wire.fetchedAt) ?? ISO8601DateFormatter().date(from: wire.fetchedAt) ?? Date()
        let dataset = NextChartDataset(code: code, interval: .day, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                       priceSource: wire.source + " · 前复权", iopvSource: nil, observedAt: observed)
        try dataset.validate()
        return dataset
    }
    private struct DailyWire: Decodable { let code: String; let source: String; let fetchedAt: String; let bars: [DailyRow] }
    private struct DailyRow: Decodable { let date: String; let open: String; let high: String; let low: String; let close: String; let volume: String }

    static func fetchQuotes(codes: [String], baseURL: String, session: URLSession = .shared) async throws -> [NextQuote] {
        var components = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("quotes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "codes", value: codes.joined(separator: ","))]
        let (data, response) = try await session.data(for: URLRequest(url: components.url!, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 行情读取失败；尝试直连行情源或使用本机缓存") }
        let payload = try JSONDecoder().decode(QuoteResponse.self, from: data)
        let values = try payload.quotes.map { try $0.quote() }
        guard values.count == codes.count, Set(values.map(\.code)) == Set(codes) else { throw NextError.invalid("NAS 行情代码集合与请求不一致") }
        return values
    }
    static func trackInstrument(code: String, baseURL: String, session: URLSession = .shared) async throws {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw NextError.invalid("证券代码无效") }
        let data = try JSONSerialization.data(withJSONObject: ["mode": "track-confirmed"])
        var request = URLRequest(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("track").appendingPathComponent(code), timeoutInterval: 10)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 未能登记该证券的后台归档") }
    }
    private struct RemoteBook: Decodable { let revision: Int; let bookJSON: String? }
    private struct RevisionResponse: Decodable { let revision: Int }
    private struct QuoteResponse: Decodable { let quotes: [QuoteWire] }
    private struct QuoteWire: Decodable {
        let code: String; let name: String; let price: String; let previousClose: String
        let time: String; let source: String; let iopv: String?; let providerInstrumentType: String?
        var timeQuality: String? = nil
        func quote() throws -> NextQuote {
            guard let price = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")), price > 0,
                  let previous = Decimal(string: previousClose, locale: Locale(identifier: "en_US_POSIX")), previous > 0,
                  !source.isEmpty, !name.isEmpty else { throw NextError.invalid("NAS 行情数值或来源无效") }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: time) ?? ISO8601DateFormatter().date(from: time)
            guard let date, date <= Date().addingTimeInterval(60) else { throw NextError.invalid("NAS 行情源时间无效或超前") }
            let parsedIOPV = iopv.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            guard parsedIOPV.map({ $0 > 0 && providerInstrumentType == "ETF" }) ?? true else { throw NextError.invalid("NAS IOPV 与证券类别校验失败") }
            return NextQuote(code: code, name: name, price: price, previousClose: previous, time: date, source: source, timeQuality: timeQuality, iopv: parsedIOPV, providerInstrumentType: providerInstrumentType)
        }
    }
    private static func endpoint(_ baseURL: String) throws -> URL {
        try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("real").appendingPathComponent("books").appendingPathComponent("main")
    }

    // MARK: - 网格状态（明日挂单表）
    /// NAS 网格引擎的整包状态：账户汇总 + 每只标的的「明日挂单表」(ladder)。
    /// 网格不预测涨跌，只回答「若明天走到某价，该买/卖多少」——这是真实的未来操作指引。
    static func fetchGridStatus(baseURL: String, session: URLSession = .shared) async throws -> NextNASGridStatus {
        let url = try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("grid").appendingPathComponent("status")
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("NAS 网格状态读取失败；确认 NAS 容器与 8789 端口可达") }
        return try JSONDecoder().decode(NextNASGridStatus.self, from: data)
    }
}

/// `GET /v1/grid/status` 的返回。价格字段来自服务端 Decimal 量化，一律以字符串传输，客户端再转 Decimal。
struct NextNASGridStatus: Decodable {
    let ok: Bool
    let initialized: Bool
    let updatedAt: String?
    let summary: NextNASGridSummary?
    let ladder: [NextNASGridLadderRow]
    /// 价格触及过哪一档。这是观察日志，**不是成交**：真正的成交只发生在券商。
    let touches: [NextNASGridTouch]
    let skipped: [NextNASGridSkipped]

    enum CodingKeys: String, CodingKey { case ok, initialized, updatedAt, summary, ladder, touches, skipped }

    // 未初始化的 NAS 只回 {ok, initialized:false, summary:null, daily:[], fills:[]}，
    // 整个 ladder 键都不存在。用合成 Decodable 会抛 keyNotFound，导致新 NAS 一打开就报错，
    // 所以这里对 ladder/daily/fills 一律按「缺省空数组」处理。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        initialized = try c.decode(Bool.self, forKey: .initialized)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        summary = try c.decodeIfPresent(NextNASGridSummary.self, forKey: .summary)
        ladder = try c.decodeIfPresent([NextNASGridLadderRow].self, forKey: .ladder) ?? []
        touches = try c.decodeIfPresent([NextNASGridTouch].self, forKey: .touches) ?? []
        skipped = try c.decodeIfPresent([NextNASGridSkipped].self, forKey: .skipped) ?? []
    }
}
/// 网格计划的整体口径。**没有虚拟本金、没有模拟盈亏**——这里描述的是
/// 「按我的真实持仓和真实现金，能挂出多少档、每档占用多少、单档往返净赚多少」。
struct NextNASGridSummary: Decodable {
    let mode: String
    let holdingsCovered: Int
    let plannedBuyCapital: String
    let plannedSellUnits: Int
    let deployableCash: String
    let reservedCash: String
    let netPerRungTotal: String
    let feePerRungTotal: String
    let todayTouches: Int
    let cashEnoughForAllBuys: Bool
    let plans: [NextNASGridPlan]

    enum CodingKeys: String, CodingKey {
        case mode, holdingsCovered, plannedBuyCapital, plannedSellUnits, deployableCash,
             reservedCash, netPerRungTotal, feePerRungTotal, todayTouches, cashEnoughForAllBuys, plans
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "plan-only"
        holdingsCovered = try c.decodeIfPresent(Int.self, forKey: .holdingsCovered) ?? 0
        plannedBuyCapital = try c.decodeIfPresent(String.self, forKey: .plannedBuyCapital) ?? "0"
        plannedSellUnits = try c.decodeIfPresent(Int.self, forKey: .plannedSellUnits) ?? 0
        deployableCash = try c.decodeIfPresent(String.self, forKey: .deployableCash) ?? "0"
        reservedCash = try c.decodeIfPresent(String.self, forKey: .reservedCash) ?? "0"
        netPerRungTotal = try c.decodeIfPresent(String.self, forKey: .netPerRungTotal) ?? "0"
        feePerRungTotal = try c.decodeIfPresent(String.self, forKey: .feePerRungTotal) ?? "0"
        todayTouches = try c.decodeIfPresent(Int.self, forKey: .todayTouches) ?? 0
        cashEnoughForAllBuys = try c.decodeIfPresent(Bool.self, forKey: .cashEnoughForAllBuys) ?? false
        plans = try c.decodeIfPresent([NextNASGridPlan].self, forKey: .plans) ?? []
    }
}
struct NextNASGridPlan: Decodable {
    let code: String
    let anchor: String
    let stepPercent: String
    let levels: Int
    let sharesPerRung: Int
    let units: Int
    let price: String?
    let buyCapital: String?
    let sellUnits: Int?
    let netPerRung: String?
}
struct NextNASGridLadderRow: Decodable, Identifiable {
    let code: String
    let price: String
    let anchor: String
    let stepPercent: String
    let position: Int
    let buysLeft: Int
    let sellsLeft: Int
    let cashEnoughFor: Int
    let rungs: [NextNASGridRung]
    let note: String
    var id: String { code }
}
struct NextNASGridRung: Decodable, Identifiable {
    let side: String
    let level: Int
    let price: String
    let units: Int
    let reachable: Bool
    var id: String { "\(side)-\(level)" }
    var isBuy: Bool { side == "buy" }
}
/// 价格触及某档的记录。**不是成交**：只说明「价格到过这里」。
struct NextNASGridTouch: Decodable, Identifiable {
    let code: String?
    let side: String?
    let level: Int?
    let price: String?
    let units: Int?
    let at: String?
    var id: String { "\(code ?? "")-\(side ?? "")-\(level ?? 0)-\(at ?? "")" }
    var isBuy: Bool { side == "buy" }
}
/// 因为市值不足一手而没能建出档位的标的。**如实说**，不假装有网格。
struct NextNASGridSkipped: Decodable {
    let code: String?
    let reason: String?
}
private extension NextBook { func validated() throws -> NextBook { try validate(); return self } }
