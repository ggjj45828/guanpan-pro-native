import Foundation

// MARK: - 新闻 → 行业/证券 → 真实持仓 → 当前 AI 计划
//
// 只做「标题级」判断，不假装读懂了正文：
//   1. 每条标题按关键词分级（重大 / 关注 / 中性），命中词与命中位置一起留痕；
//   2. 标题必须能落到某只真实持仓（代码 / 名称 / 行业词），否则不进任何结论；
//   3. 重大事件对当前计划有四种作用：做T失效、网格暂停、风险升级、要求重新分析。
//
// 这个引擎不改价格、不改份额、不产生成交；它只解释「为什么原来的计划可能要停」。

enum NextNewsSeverity: String, Codable, Equatable {
    case major = "重大"
    case watch = "关注"
    case neutral = "中性"

    var rank: Int {
        switch self {
        case .major: return 2
        case .watch: return 1
        case .neutral: return 0
        }
    }
}

/// 重大事件对计划的作用。取最强的那一条。
enum NextNewsAction: String, Codable, Equatable {
    case invalidateT = "做T计划失效"
    case pauseGrid = "网格暂停"
    case reanalyze = "要求重新分析"
    case watch = "保持关注"
    case none = "无影响"

    var rank: Int {
        switch self {
        case .invalidateT: return 4
        case .pauseGrid: return 3
        case .reanalyze: return 2
        case .watch: return 1
        case .none: return 0
        }
    }

    var blocksPlan: Bool { self == .invalidateT || self == .pauseGrid || self == .reanalyze }
}

struct NextNewsHit: Codable, Equatable, Identifiable {
    var id: String { "\(title)|\(severity.rawValue)" }
    let title: String
    let source: String?
    let publishedAt: String?
    let url: String?
    let severity: NextNewsSeverity
    /// 命中的关键词，便于复核为什么被判定为重大
    let keywords: [String]
}

struct NextNewsImpact: Codable, Equatable {
    let code: String
    let hits: [NextNewsHit]
    let severity: NextNewsSeverity
    let action: NextNewsAction
    let reasons: [String]
    let evaluatedAt: Date

    var isEmpty: Bool { hits.isEmpty }
}

enum NextNewsImpactEngine {
    /// 重大：会改变「这只还能不能按原计划做」的事实。
    static let majorWords = ["停牌", "退市", "立案", "调查", "处罚", "清盘", "清算", "违约",
                             "暴雷", "暴跌", "跌停", "涨停", "重组", "合并", "收购", "拆分",
                             "暂停上市", "终止", "风险警示", "ST", "重大事项"]
    /// 关注：会改变赔率或成本，但通常不改变「能不能做」。
    static let watchWords = ["减持", "增持", "回购", "分红", "派息", "调仓", "费率",
                             "溢价", "折价", "规模", "份额", "跟踪", "指数调整", "流动性",
                             "公告", "业绩", "净值"]

    /// A headline without a parseable publication time must not influence a current plan.
    static func isFreshPublishedAt(_ raw: String?, now: Date) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? {
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: raw)
        }() ?? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: raw)
        }()
        guard let date else { return false }
        return date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
            && date <= now.addingTimeInterval(2 * 60 * 60)
    }

    static func severity(of title: String) -> (NextNewsSeverity, [String]) {
        let upper = title.uppercased()
        // `ST` is a security-risk label, not a substring. Matching it inside
        // ordinary English words such as "investment" would falsely turn a
        // neutral headline into a major event and revoke valid plans.
        var majorHits = majorWords.filter { $0 != "ST" && upper.contains($0.uppercased()) }
        if upper.range(of: #"(?<![A-Z0-9])\*?ST(?![A-Z0-9])"#, options: .regularExpression) != nil {
            majorHits.append("ST")
        }
        if !majorHits.isEmpty { return (.major, majorHits) }
        let watchHits = watchWords.filter { upper.contains($0.uppercased()) }
        if !watchHits.isEmpty { return (.watch, watchHits) }
        return (.neutral, [])
    }

    /// 标题是否属于这只持仓：代码在前（最可靠），其次是全名，再去掉 ETF/基金 的短名，最后是行业词。
    static func belongs(_ title: String, code: String, name: String, industryWords: [String] = []) -> Bool {
        if title.contains(code) { return true }
        // 全名直接命中：标题里明写「纳指ETF」就该属于纳指ETF，
        // 不能因为去掉 ETF 后只剩 2 字（短名门槛）就把全名命中也一起漏掉。
        if !name.isEmpty, title.contains(name) { return true }
        let short = name.replacingOccurrences(of: "ETF", with: "")
                                .replacingOccurrences(of: "基金", with: "")
                                .trimmingCharacters(in: .whitespaces)
        if short.count >= 3, title.contains(short) { return true }
        guard !industryWords.isEmpty else { return false }
        return industryWords.contains { !$0.isEmpty && title.contains($0) }
    }

    static func relevantHeadlines(code: String, name: String, titles: [NextNewsInput], now: Date,
                                  industryWords: [String] = []) -> [NextNewsInput] {
        let keywords = Array(Set(industryWords + InstrumentCatalog.newsKeywords(for: code, name: name)))
        return titles.filter { item in
            isFreshPublishedAt(item.publishedAt, now: now)
                && belongs(item.title, code: code, name: name, industryWords: keywords)
        }
    }

    /// 单只持仓的新闻影响。titles 必须已经属于这只（按代码抓取的新闻天然属于它）。
    static func evaluate(code: String, name: String, titles: [NextNewsInput],
                         hasTPlan: Bool, hasGridPlan: Bool, now: Date) -> NextNewsImpact {
        var hits: [NextNewsHit] = []
        for item in relevantHeadlines(code: code, name: name, titles: titles, now: now) {
            let (severity, keywords) = severity(of: item.title)
            guard severity != .neutral else { continue }
            hits.append(NextNewsHit(title: item.title, source: item.source,
                                    publishedAt: item.publishedAt, url: item.url,
                                    severity: severity, keywords: keywords))
        }
        let strongest = hits.map(\.severity).max { $0.rank < $1.rank } ?? .neutral
        var reasons: [String] = []
        var action = NextNewsAction.none

        if strongest == .major {
            action = hasTPlan ? .invalidateT : (hasGridPlan ? .pauseGrid : .reanalyze)
            reasons.append("\(name) 出现 \(hits.filter { $0.severity == .major }.count) 条重大新闻：\(hits.first { $0.severity == .major }?.title ?? "")")
            reasons.append("重大事件未经人工确认前，原计划不再作为可执行建议")
        } else if strongest == .watch {
            action = hasTPlan || hasGridPlan ? .watch : .none
            reasons.append("\(name) 有 \(hits.count) 条与成本/份额相关的新闻，继续关注即可")
        }
        if hits.contains(where: { $0.keywords.contains("停牌") }) {
            action = .pauseGrid
            reasons.append("标题含「停牌」：停牌期间无法成交，网格必须暂停")
        }
        if hits.contains(where: { $0.keywords.contains("退市") || $0.keywords.contains("清盘") }) {
            action = .invalidateT
            reasons.append("标题含退市/清盘类表述：不只做T，任何加仓计划都不应继续")
        }
        return NextNewsImpact(code: code, hits: hits, severity: strongest,
                              action: action, reasons: reasons, evaluatedAt: now)
    }

    /// 把影响落回计划：返回被改写后的指导条目（结论仍然只有一份，不产生第二个说法）。
    static func apply(_ impact: NextNewsImpact, to item: NextGuidanceItem) -> NextGuidanceItem {
        var tPlan = item.tPlan
        var gridPlan = item.gridPlan
        var riskNotes = item.riskNotes
        var actionable = item.isActionable
        if !impact.action.blocksPlan {
            riskNotes += impact.reasons
        } else {
            riskNotes += impact.reasons
            // 暂停不是新增一种「结论」，而是把原来的可执行计划收回：
            // 做T 变成「不建议做」并写明原因，网格变成「不建议挂」并写明原因。
            if impact.action == .invalidateT, tPlan?.isReady == true {
                tPlan = .notWorthwhile(["重大新闻：" + (impact.hits.first?.title ?? "事件待确认") + "；原做T计划作废"])
                actionable = false
            }
            if impact.action == .pauseGrid {
                // 停牌 = 全场暂停成交：做T与网格都收回来，不能只收网格、留下做T继续显示为可执行。
                if tPlan?.isReady == true {
                    tPlan = .notWorthwhile(["重大新闻：" + (impact.hits.first?.title ?? "事件待确认") + "；停牌期间无法成交，原做T计划作废"])
                }
                if gridPlan?.isReady == true {
                    gridPlan = .notRecommended(["重大新闻：" + (impact.hits.first?.title ?? "事件待确认") + "；网格暂停"])
                }
                actionable = false
            }
            if impact.action == .reanalyze {
                riskNotes.append("需要人工确认事件影响后再重新判断，本次不给新价格")
            }
        }
        return NextGuidanceItem(code: item.code, name: item.name, state: item.state, strategy: item.strategy,
                                headline: item.headline, whyToday: item.whyToday, tPlan: tPlan,
                                gridPlan: gridPlan, recovery: item.recovery, confidence: item.confidence,
                                portfolioNote: item.portfolioNote, riskNotes: riskNotes,
                                score: item.score, rank: item.rank, isActionable: actionable,
                                profileNote: item.profileNote, newsImpact: impact)
    }
}

extension NextTPlannerResult {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

extension NextGridPlannerResult {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// 手机直连或 NAS 回退得到的单条新闻标题（手机 AI 的最小新闻输入，不含正文）。
struct NextNewsInput: Codable, Equatable, Identifiable {
    var id: String { url ?? title }
    let title: String
    let source: String?
    let publishedAt: String?
    let url: String?

    init(title: String, source: String? = nil, publishedAt: String? = nil, url: String? = nil) {
        self.title = title; self.source = source; self.publishedAt = publishedAt; self.url = url
    }
}
