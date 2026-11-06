import Foundation
import Combine

// MARK: - 新闻缓存与状态
//
// 只做三件事：抓、缓存、如实汇报状态。判断留给看的人。
//
// 为什么单独一个对象：新闻是**与账本无关的外部事实**，不能塞进 PortfolioData ——
// 那会让每次备份、每次 NAS 同步都带上几十条新闻标题，还会把「备份体积」和
// 「行情快讯」两件无关的事绑在一起。所以它只在内存 + 一个独立的小缓存键里。
//
// 用 `shared` 而不是注入：它没有任何业务依赖，全 App 只有一份，
// 免得每个 sheet 都要记得从环境里取。

/// 状态全部在主线程改，但类型本身不标 `@MainActor`：
/// 视图的属性初始化器是 nonisolated 的，标了会让 `@ObservedObject var news = NewsCenter.shared`
/// 直接编译不过。真正改状态的方法（`refresh`）单独标 `@MainActor`，
/// 于是 `Task { }` 继承主线程上下文，`@Published` 永远不会被后台线程写。
final class NewsCenter: ObservableObject, @unchecked Sendable {
    static let shared = NewsCenter()

    /// 只保留「来源可信且未过期」的条目。过期缓存继续留在内存里给界面显示「已过期」，
    /// 但不会被当成今天的背景送进 AI。
    @Published private(set) var feed: NewsFeed?
    @Published private(set) var status = "还没取过快讯"
    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastAttemptAt: Date?

    /// 两次自动抓取之间的最短间隔。手动下拉不受限制。
    private let minimumInterval: TimeInterval = 120
    private let cacheKey = "guanpan.pro.native.news.cache.v1"
    private var refreshTask: Task<Void, Never>?

    private struct CachePayload: Codable {
        var fetchedAt: Date
        var articles: [NewsArticle]
    }

    private init() {
        loadCache()
    }

    // MARK: 读取

    /// 新鲜条目（24 小时内）。为空说明现在没有可用的市场背景。
    var freshArticles: [NewsArticle] {
        feed?.recent(at: .now)?.articles ?? []
    }

    /// 界面上要显示的条目：新鲜就显示新鲜的，否则把过期缓存显示出来并说明已过期。
    /// 显示旧标题比显示一片空白更诚实 —— 空白会让人以为「今天没有消息」。
    var displayArticles: [NewsArticle] {
        let fresh = freshArticles
        if !fresh.isEmpty { return fresh }
        return feed?.articles ?? []
    }

    var isStale: Bool {
        guard let feed else { return false }
        return feed.recent(at: .now) == nil
    }

    var provider: String { feed?.provider ?? NewsTrustPolicy.providerName }

    var freshnessText: String {
        guard let feed else { return "还没取过快讯" }
        let time = Self.timeFormatter.string(from: feed.fetchedAt)
        return isStale ? "缓存于 \(time)（已超过 24 小时，只作历史参考）" : "获取于 \(time)"
    }

    /// 与这些标的直接关联的条目（条目自己列出了代码才算）。
    func articles(forCodes codes: [String], in list: [NewsArticle]) -> [NewsArticle] {
        let wanted = Set(codes.map { Self.normalizedCode($0) }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        return list.filter { article in
            article.relatedSecurities.contains { wanted.contains($0.code) }
        }
    }

    func associatedCount(forCodes codes: [String]) -> Int {
        let wanted = Set(codes.map { Self.normalizedCode($0) }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return 0 }
        return wanted.filter { code in displayArticles.contains { $0.mentions(code: code) } }.count
    }

    // MARK: 抓取

    @MainActor
    func refresh(force: Bool = false) {
        if refreshTask != nil { return }
        if !force, let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < minimumInterval { return }
        lastAttemptAt = .now
        isFetching = true
        if feed == nil { status = "正在获取市场快讯…" }

        // 这里刻意强持有 self：NewsCenter 是单例，任务结束后下面会把 refreshTask 清空，
        // 引用环随之解开。用 weak 反而会让「重置 isFetching」被提前 return 跳过。
        refreshTask = Task {
            do {
                let received = try await NewsClient.fetchLatest()
                let completedAt = Date()
                let existing = feed
                feed = NewsFeedCachePolicy.replacement(existing: existing, received: received, at: completedAt)
                if let recent = received.recent(at: completedAt) {
                    status = "共 \(recent.articles.count) 条快讯 · 获取于 \(Self.timeFormatter.string(from: recent.fetchedAt))"
                    lastError = nil
                    saveCache()
                } else if existing?.recent(at: completedAt) != nil {
                    status = "新响应没有近 24 小时的有效快讯，继续沿用上一次缓存"
                    lastError = nil
                } else {
                    status = "新闻源已响应，但没有近 24 小时的有效快讯"
                    lastError = nil
                }
            } catch {
                lastError = error.localizedDescription
                if feed?.recent(at: Date()) != nil {
                    status = "沿用上次缓存 · 更新失败：\(error.localizedDescription)"
                } else {
                    status = "获取失败 · \(error.localizedDescription)"
                }
            }
            isFetching = false
            refreshTask = nil
        }
    }

    // MARK: 缓存

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CachePayload.self, from: data),
              !payload.articles.isEmpty else { return }
        feed = NewsFeed(provider: NewsTrustPolicy.providerName,
                        fetchedAt: payload.fetchedAt,
                        articles: payload.articles)
        let time = Self.timeFormatter.string(from: payload.fetchedAt)
        status = payload.fetchedAt.timeIntervalSince(.now) > -24 * 3600
            ? "上次缓存于 \(time)"
            : "缓存于 \(time)（已过期）"
    }

    private func saveCache() {
        guard let feed else { return }
        let payload = CachePayload(fetchedAt: feed.fetchedAt, articles: feed.articles)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload), data.count <= 512 * 1024 else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        feed = nil
        status = "已清空本地快讯缓存"
        lastError = nil
    }

    // MARK: AI 证据

    /// 给大模型的新闻材料。
    ///
    /// 三条硬约束写进材料本身：这是标题不是正文、只有列了代码才算相关、
    /// 不许凭标题推断因果。模型很容易把「某行业新闻」硬套到持仓上，先把话说死。
    func evidenceText(forCodes codes: [String], limit: Int = 10) -> String? {
        let fresh = freshArticles
        guard !fresh.isEmpty else { return nil }
        let targeted = articles(forCodes: codes, in: fresh)
        let pool = targeted.isEmpty ? Array(fresh.prefix(limit)) : Array(targeted.prefix(limit))
        guard !pool.isEmpty else { return nil }

        let lines = pool.map { article -> String in
            let time = Self.shortTimeFormatter.string(from: article.publishedAt)
            let linked = article.relatedSecurities.isEmpty
                ? "市场背景（未列出个股代码，不得归因到任何标的）"
                : "条目明确关联 " + article.relatedSecurities.map { "\($0.name)(\($0.code))" }.joined(separator: "、")
            let summary = article.summary.map { "；摘要：\($0)" } ?? ""
            return "· [\(time)] \(article.title)（\(article.publisher)）\(summary)｜\(linked)｜链接 \(article.url)"
        }

        let scope = targeted.isEmpty
            ? "当前没有与持仓直接关联的条目，以下是市场背景标题"
            : "以下 \(pool.count) 条与持仓标的直接关联"

        return """
        【市场快讯（\(provider)，获取于 \(Self.timeFormatter.string(from: feed?.fetchedAt ?? .now))）】
        这是公开网页接口返回的**标题与摘要，不是已核实正文**；\(scope)。
        使用限制：只有明确列出代码的条目才可以和该标的放在一起讨论；不得仅凭标题推断因果、影响方向或幅度；引用时必须带上媒体、时间与原文链接。这些条目也不能替代行情、IOPV、折溢价与账本事实。
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: 工具

    static func normalizedCode(_ code: String) -> String {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        return value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
