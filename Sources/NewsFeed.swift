import Foundation

// MARK: - 新闻证据（移植自观盘 max 的 FNewsClient / NewsData）
//
// 这一层刻意什么都不相信：
// · 来源是同花顺 7×24 的**公开网页接口**，不是签约数据源，所以来源名必须原样带出去；
// · 返回的是「标题 + 摘要」，不是已核实正文，所以只能当背景，不能当事实；
// · 只有条目自己列出了证券代码，才算「与该标的直接关联」——不允许从标题里猜因果；
// · 解析全程 fail-closed：http 链接、带账号信息的链接、超时、超大响应一律丢弃。
//
// 观盘 max 里这套边界是被反复打磨过的，这里不做「简化」。

enum NewsFeedParseError: Error, Equatable {
    case responseTooLarge
    case invalidResponse
}

enum NewsTrustPolicy {
    static let providerName = "同花顺财经 7×24 新闻（公开网页接口）"

    static func isTrustedProvider(_ provider: String) -> Bool {
        provider.trimmingCharacters(in: .whitespacesAndNewlines) == providerName
    }
}

struct NewsSecurityReference: Codable, Equatable, Identifiable, Sendable {
    var id: String { code }
    let code: String
    let name: String
}

struct NewsArticle: Codable, Equatable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let summary: String?
    let publisher: String
    let url: String
    let publishedAt: Date
    let relatedSecurities: [NewsSecurityReference]

    /// 该条是否明确列出了这只标的的代码。没有列就是「不相关」，不是「大概相关」。
    func mentions(code: String) -> Bool {
        relatedSecurities.contains { $0.code == code }
    }
}

struct NewsFeed: Equatable, Sendable {
    let provider: String
    let fetchedAt: Date
    let articles: [NewsArticle]

    func articlesAssociated(with code: String) -> [NewsArticle] {
        articles.filter { $0.mentions(code: code) }
    }

    /// 只留下「来源可信、未过期、链接可信」的条目。取不到就返回 nil，
    /// 让调用方去说「没有可用快讯」，而不是拿一条过期新闻当今天的背景。
    func recent(at now: Date, maximumAge: TimeInterval = 24 * 60 * 60) -> NewsFeed? {
        guard NewsTrustPolicy.isTrustedProvider(provider),
              maximumAge.isFinite, maximumAge >= 0,
              now.timeIntervalSince1970.isFinite, fetchedAt.timeIntervalSince1970.isFinite,
              fetchedAt <= now, now.timeIntervalSince(fetchedAt) <= maximumAge else { return nil }
        let cutoff = now.addingTimeInterval(-maximumAge)
        var seen = Set<String>()
        let kept = articles.filter { article in
            guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let components = URLComponents(string: article.url),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  article.publishedAt >= cutoff, article.publishedAt <= fetchedAt,
                  let normalized = components.url?.absoluteString,
                  seen.insert(normalized).inserted else { return false }
            return article.relatedSecurities.allSatisfy { reference in
                reference.code.utf8.count == 6
                    && reference.code.utf8.allSatisfy { (48...57).contains($0) }
                    && !reference.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        guard !kept.isEmpty else { return nil }
        return NewsFeed(provider: provider, fetchedAt: fetchedAt, articles: kept)
    }
}

enum NewsFeedParser {
    static let maximumResponseBytes = 1_000_000
    private static let maximumAge: TimeInterval = 24 * 60 * 60
    private static let maximumArticles = 40

    static func parse(_ data: Data, fetchedAt: Date) throws -> NewsFeed {
        guard fetchedAt.timeIntervalSince1970.isFinite else { throw NewsFeedParseError.invalidResponse }
        guard data.count <= maximumResponseBytes else { throw NewsFeedParseError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              scalar(root["code"]) == "200",
              let payload = root["data"] as? [String: Any],
              let rawItems = payload["list"] as? [[String: Any]] else {
            throw NewsFeedParseError.invalidResponse
        }

        let cutoff = fetchedAt.addingTimeInterval(-maximumAge)
        var seen = Set<String>()
        let parsed = rawItems.compactMap { item -> NewsArticle? in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let rawURL = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let components = URLComponents(string: rawURL),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  let link = components.url,
                  let publishedAt = parseTimestamp(item["ctime"]),
                  publishedAt >= cutoff, publishedAt <= fetchedAt,
                  seen.insert(link.absoluteString).inserted else { return nil }

            let references = (item["stock"] as? [[String: Any]] ?? []).compactMap { stock -> NewsSecurityReference? in
                guard let codeValue = stock["stockCode"],
                      let name = (stock["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                let rawCode = scalar(codeValue)
                guard !rawCode.isEmpty, rawCode.utf8.count <= 6,
                      rawCode.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                let code = String(repeating: "0", count: 6 - rawCode.utf8.count) + rawCode
                return NewsSecurityReference(code: code, name: String(name.prefix(100)))
            }
            let publisher = (item["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (item["digest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NewsArticle(title: String(title.prefix(300)),
                               summary: summary.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) },
                               publisher: publisher.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? "同花顺财经",
                               url: link.absoluteString,
                               publishedAt: publishedAt,
                               relatedSecurities: references)
        }
        return NewsFeed(provider: NewsTrustPolicy.providerName, fetchedAt: fetchedAt,
                        articles: Array(parsed.prefix(maximumArticles)))
    }

    private static func scalar(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let text = value as? String else { return nil }
        if let raw = Double(text), raw.isFinite, raw > 0 {
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// 一次成功但「没有可用条目」的响应，不足以抹掉仍然新鲜的缓存。
enum NewsFeedCachePolicy {
    static func replacement(existing: NewsFeed?, received: NewsFeed, at now: Date) -> NewsFeed? {
        received.recent(at: now) ?? existing
    }
}

// MARK: - 抓取

enum NewsClientError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case feedTooLarge
    case invalidFeed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "新闻源地址无效"
        case .httpStatus(let status): return "新闻源 HTTP \(status)"
        case .feedTooLarge: return "新闻源响应超出大小限制"
        case .invalidFeed: return "新闻源返回格式变化或字段不完整"
        }
    }
}

enum NewsClient {
    static let providerName = NewsTrustPolicy.providerName
    private static let endpointString = "https://news.10jqka.com.cn/tapp/news/push/stock/"

    static func fetchLatest(now: Date = Date()) async throws -> NewsFeed {
        guard let endpoint = URL(string: endpointString),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw NewsClientError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "tag", value: ""),
            URLQueryItem(name: "track", value: "website"),
            URLQueryItem(name: "pagesize", value: "40")
        ]
        guard let url = components.url else { throw NewsClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://news.10jqka.com.cn/realtimenews.html", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("GuanpanPro/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsClientError.invalidFeed }
        guard (200..<300).contains(http.statusCode) else { throw NewsClientError.httpStatus(http.statusCode) }
        if http.expectedContentLength > Int64(NewsFeedParser.maximumResponseBytes) {
            throw NewsClientError.feedTooLarge
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), NewsFeedParser.maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < NewsFeedParser.maximumResponseBytes else { throw NewsClientError.feedTooLarge }
            data.append(byte)
        }
        do {
            return try NewsFeedParser.parse(data, fetchedAt: now)
        } catch NewsFeedParseError.responseTooLarge {
            throw NewsClientError.feedTooLarge
        } catch {
            throw NewsClientError.invalidFeed
        }
    }
}
