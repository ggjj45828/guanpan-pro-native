import Foundation

// MARK: - 逐层裁决留痕
//
// 一条 AI 判断不是凭空冒出来的：数据可不可信、市场状态是什么、量化信号有没有、
// 组合约束允不允许 —— 每一层都可能拦一次或降一次级。
// 之前只存最终结论，事后想问「当时为什么这么判」只能靠猜。
//
// 这不是为了给判断找理由，而是为了**事后能分清「判断错了」和「数据本来就不可信」**：
// 后者不该被记成 AI 的失误，前者也不能拿数据当挡箭牌。

struct DecisionLayerTrace: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// 层名：「数据质量」「市场状态」「技术信号」「组合约束」「资金与仓位」。
    var layer: String
    /// 该层的动作：「通过」「降级」「拦截」「仅观察」。
    var action: String
    /// 一句话说明为什么。
    var note: String

    var isBlocking: Bool { action == "拦截" }
    var isDegrading: Bool { action == "降级" || action == "仅观察" }
}

/// 判断发出那一刻看到的行情。
///
/// 与 `entryPrice` 分开存：那是「判断用的参考价」，这是「当时屏幕上的真实报价」。
/// 两者可能不同（用户手填参考价），而事后复盘要能看见差异。
struct DecisionObservation: Codable, Equatable {
    var price: Double
    var source: String?
    var quoteTimestamp: Date?
    var fetchedAt: Date?
    var session: String
    var freshness: String

    var trustLabel: String {
        QuoteSourceTrust.isTrusted(source) ? (source ?? "") : "来源未验证"
    }
}

/// 数据质量分级。判断的正确性必须和它的数据质量一起看。
enum DecisionDataQuality: String, Codable, CaseIterable {
    /// 报价新鲜、来源可信、日线完整。
    case complete
    /// 有缺口但仍可用（例如最新一根未走完）。
    case partial
    /// 用了缓存价或手动价。
    case degraded
    /// 完全无法验证。
    case unknown

    var title: String {
        switch self {
        case .complete: return "数据完整"
        case .partial: return "数据有缺口"
        case .degraded: return "数据降级"
        case .unknown: return "数据未验证"
        }
    }

    var shortTitle: String {
        switch self {
        case .complete: return "完整"
        case .partial: return "有缺口"
        case .degraded: return "降级"
        case .unknown: return "未验证"
        }
    }
}

// MARK: - 记录的留痕字段
//
// 全部写成 Optional：`DecisionRecord` 用的是合成 `Decodable`，
// 给「有默认值的非 Optional 属性」加字段会让老记录整条解码失败
// （Swift 对这种情况仍然会调 `decode`，不会用默认值兜底）。

extension DecisionRecord {
    var trace: [DecisionLayerTrace] { layerTrace ?? [] }
    var quality: DecisionDataQuality {
        DecisionDataQuality(rawValue: dataQuality ?? "") ?? .unknown
    }
    /// 只看有留痕的记录才能做分层统计。老记录一律 `.unknown`。
    var hasTrace: Bool { !trace.isEmpty || observation != nil }
}

// MARK: - 留痕装配

enum DecisionTraceBuilder {
    /// 按当时的行情与上下文装配留痕。
    static func build(quote: Quote?,
                      session: MarketSessionStatus,
                      regime: MarketRegimeAssessment?,
                      hasDailyBars: Bool,
                      heldQuantity: Double,
                      positionLimitPercent: Double?) -> (traces: [DecisionLayerTrace],
                                                          observation: DecisionObservation?,
                                                          quality: DecisionDataQuality) {
        var traces: [DecisionLayerTrace] = []
        var quality: DecisionDataQuality = .complete

        // 1) 数据质量
        if let quote {
            let temporal = quote.temporal(in: session)
            let freshness = temporal.freshness(at: .now)
            switch freshness {
            case .fresh:
                traces.append(DecisionLayerTrace(layer: "数据质量", action: "通过",
                                                 note: temporal.displayLabel()))
            case .stale:
                quality = .degraded
                traces.append(DecisionLayerTrace(layer: "数据质量", action: "降级",
                                                 note: "报价已过期：\(temporal.displayLabel())"))
            case .unverified:
                quality = .degraded
                traces.append(DecisionLayerTrace(layer: "数据质量", action: "降级",
                                                 note: QuoteSourceTrust.isManual(quote.source)
                                                    ? "使用了手动覆盖价，不是行情"
                                                    : "报价来源或时间未经验证"))
            }
        } else {
            quality = .unknown
            traces.append(DecisionLayerTrace(layer: "数据质量", action: "降级", note: "没有这条标的的报价"))
        }

        // 2) 技术数据
        if hasDailyBars {
            traces.append(DecisionLayerTrace(layer: "技术数据", action: "通过", note: "本机有日线样本"))
        } else {
            quality = quality == .unknown ? .unknown : .partial
            traces.append(DecisionLayerTrace(layer: "技术数据", action: "降级",
                                             note: "本机没有这只标的的日线，判断只基于报价"))
        }

        // 3) 市场状态
        if let regime {
            if regime.regime == .dataUnreliable {
                traces.append(DecisionLayerTrace(layer: "市场状态", action: "仅观察",
                                                 note: "市场状态不可判：\(regime.reasons.first ?? "数据不足")"))
            } else {
                let action = regime.observationOnly ? "仅观察" : "通过"
                traces.append(DecisionLayerTrace(layer: "市场状态", action: action,
                                                 note: "\(regime.regime.title) · \(regime.riskLevel.title)"))
            }
        } else {
            traces.append(DecisionLayerTrace(layer: "市场状态", action: "仅观察",
                                             note: "未取到指数日线，无法判断市场状态"))
        }

        // 4) 资金与仓位
        if heldQuantity <= 0 {
            traces.append(DecisionLayerTrace(layer: "资金与仓位", action: "通过", note: "当前未持有"))
        } else {
            traces.append(DecisionLayerTrace(layer: "资金与仓位", action: "通过",
                                             note: "当前持有 \(heldQuantity.num(0)) 份"))
        }
        if let limit = positionLimitPercent, limit > 0, limit < 100 {
            traces.append(DecisionLayerTrace(layer: "资金与仓位", action: "通过",
                                             note: "单标的上限设为 \(limit.num(0))%"))
        }

        let observation = quote.map { quote in
            let temporal = quote.temporal(in: session)
            return DecisionObservation(price: quote.price,
                                       source: quote.source,
                                       quoteTimestamp: quote.updatedAt,
                                       fetchedAt: quote.fetchedAt,
                                       session: session.rawValue,
                                       freshness: temporal.freshness(at: .now).rawValue)
        }
        return (traces, observation, quality)
    }
}

// MARK: - 决策记忆投影
//
// `decisionJournal` 会一直长。真正有用的是两件事：
// ① 每个标的**最新**的那条判断（现在该看什么）；
// ② 每个标的的历史命中率（这只票我到底看不看得准）。
//
// 每次 AI 分析都全量重扫一遍既慢又会把 prompt 撑爆，所以先投影。

struct DecisionMemoryEntry: Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let latest: DecisionRecord
    let latestVerdict: DecisionVerdict
    let totalRecords: Int
    let hits: Int
    let misses: Int

    /// 只在这个标的有已了结记录时才算得出。
    var hitRate: Double? {
        let resolved = hits + misses
        return resolved > 0 ? Double(hits) / Double(resolved) : nil
    }

    var hitRateLabel: String {
        guard let hitRate else { return "还没有了结记录" }
        return "\(hits)/\(hits + misses) 命中（\(hitRate.pct(0))）"
    }
}

enum DecisionMemoryProjection {
    static func build(_ judgements: [DecisionJudgement]) -> [DecisionMemoryEntry] {
        var grouped: [String: [DecisionJudgement]] = [:]
        for item in judgements {
            grouped[item.record.code, default: []].append(item)
        }
        return grouped.compactMap { code, items -> DecisionMemoryEntry? in
            let ordered = items.sorted { $0.record.recordedAt > $1.record.recordedAt }
            guard let newest = ordered.first else { return nil }
            // 手动标记了结的不进命中率 —— 那是档案，不是战绩。
            let resolved = ordered.filter { $0.record.settledAt == nil && $0.verdict.isResolved }
            let hits = resolved.filter { $0.verdict.isHit }.count
            let misses = resolved.filter {
                if case .invalidHit = $0.verdict { return true }
                return false
            }.count
            return DecisionMemoryEntry(code: code,
                                       name: newest.record.name,
                                       latest: newest.record,
                                       latestVerdict: newest.verdict,
                                       totalRecords: ordered.count,
                                       hits: hits,
                                       misses: misses)
        }
        .sorted { $0.totalRecords > $1.totalRecords }
    }

    /// 给 AI 上下文用的一段话。只写事实，不加评价。
    static func promptText(_ entries: [DecisionMemoryEntry], limit: Int = 8) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines: [String] = []
        for entry in entries.prefix(limit) {
            let verdictText: String
            switch entry.latestVerdict {
            case .targetHit(_, _, let days): verdictText = "已命中目标（\(days) 个交易日）"
            case .invalidHit(_, _, let days): verdictText = "已失效（\(days) 个交易日）"
            case .bothTouched: verdictText = "同日双触，无法判定先后"
            case .waiting(_, let close): verdictText = "仍在等，最新收盘 \(close.num(3))"
            case .noData: verdictText = "缺日线"
            }
            lines.append("\(entry.name)（\(entry.code)）最新一条：\(entry.latest.sideLabel) "
                + "参考 \(entry.latest.entryPrice?.num(3) ?? "--") / 目标 \(entry.latest.target?.num(3) ?? "--")"
                + " / 失效 \(entry.latest.invalid?.num(3) ?? "--")，\(verdictText)；"
                + "该标的历史 \(entry.totalRecords) 条，\(entry.hitRateLabel)")
        }
        return """
        【本机决策记忆（用户过去自己采纳过的判断，非本次结论）】
        \(lines.joined(separator: "\n"))
        说明：命中率只统计行情已经给出结论的条目，仍在等待的不计入分母；手动标记了结的不计入。
        """
    }
}
