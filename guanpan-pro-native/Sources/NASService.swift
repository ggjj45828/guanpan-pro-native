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

struct NextNASHealth: Decodable {
    let service: String
    let schemaVersion: Int
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
        guard var components = URLComponents(url: try endpoint(baseURL).appendingPathComponent("history"), resolvingAgainstBaseURL: false) else {
            throw NextError.invalid("NAS 历史地址无效")
        }
        components.queryItems = [URLQueryItem(name: "keep", value: String(keep))]
        guard let url = components.url else { throw NextError.invalid("NAS 历史地址无法生成") }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "DELETE"
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
        guard var parts = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("minute").appendingPathComponent(code), resolvingAgainstBaseURL: false) else {
            throw NextError.invalid("NAS 分时地址无效")
        }
        parts.queryItems = [URLQueryItem(name: "day", value: formatter.string(from: day))]
        guard let url = parts.url else { throw NextError.invalid("NAS 分时地址无法生成") }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
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
                                       observedAt: samples.map(\.timestamp).max() ?? .distantPast)
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
        guard let observed = iso.date(from: wire.fetchedAt) ?? ISO8601DateFormatter().date(from: wire.fetchedAt),
              observed <= Date().addingTimeInterval(60) else {
            throw NextError.invalid("NAS 日 K 归档时间无效；不能把旧数据标为刚刚获取")
        }
        let dataset = NextChartDataset(code: code, interval: .day, samples: samples, costPerUnit: nil, costObservedAt: nil,
                                       priceSource: wire.source + " · 前复权", iopvSource: nil, observedAt: observed)
        try dataset.validate()
        return dataset
    }
    private struct DailyWire: Decodable { let code: String; let source: String; let fetchedAt: String; let bars: [DailyRow] }
    private struct DailyRow: Decodable { let date: String; let open: String; let high: String; let low: String; let close: String; let volume: String }

    static func fetchQuotes(codes: [String], baseURL: String, session: URLSession = .shared) async throws -> [NextQuote] {
        guard var components = URLComponents(url: try validateURL(baseURL).appendingPathComponent("v1").appendingPathComponent("market").appendingPathComponent("quotes"), resolvingAgainstBaseURL: false) else {
            throw NextError.invalid("NAS 行情地址无效")
        }
        components.queryItems = [URLQueryItem(name: "codes", value: codes.joined(separator: ","))]
        guard let url = components.url else { throw NextError.invalid("NAS 行情地址无法生成") }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
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
}

private extension NextBook { func validated() throws -> NextBook { try validate(); return self } }
