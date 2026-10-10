import SwiftUI

/// Human-readable, read-only rendering of legacy AI output. These records are
/// explicitly historical and never feed the current AI prompt or conclusions.
struct LegacyAIArchiveView: View {
    let rawJSON: String

    private struct CachedText: Decodable {
        var t: String?
        var txt: String?
        var sig: String?
    }
    private struct Payload: Decodable {
        var advisor: CachedText?
        var review: CachedText?
        var llm: [String: CachedText]?
        var prof: String?
        var profile: String?
    }

    private var payload: Payload? { try? JSONDecoder().decode(Payload.self, from: Data(rawJSON.utf8)) }
    private var entries: [(String, CachedText)] {
        guard let payload else { return [] }
        var values: [(String, CachedText)] = []
        if let advisor = payload.advisor { values.append(("账户顾问", advisor)) }
        if let review = payload.review { values.append(("组合复盘", review)) }
        for key in (payload.llm?.keys.sorted() ?? []).suffix(8) {
            if let value = payload.llm?[key] { values.append(("标的分析 · \(key)", value)) }
        }
        return values
    }

    var body: some View {
        if let payload, (!entries.isEmpty || !(payload.prof ?? payload.profile ?? "").isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                Text("历史缓存 · 仅供回看，不代表当前行情或建议")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entries.enumerated()), id: \.offset) { item in
                    let entry = item.element
                    DisclosureGroup("\(entry.0) · \(entry.1.t ?? "未记录时间")") {
                        Text(entry.1.txt ?? "缓存没有正文")
                            .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let signature = entry.1.sig, !signature.isEmpty {
                            Text("旧版数据签名：\(signature)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                if let profile = payload.prof ?? payload.profile, !profile.isEmpty {
                    DisclosureGroup("旧版 AI 偏好") {
                        Text(profile).font(.caption).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text(rawJSON).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(5).textSelection(.enabled)
        }
    }
}

/// Read-only rendering of the old grid learning samples; does not influence
/// native grid recommendations or backtests.
struct LegacyGridExperienceView: View {
    struct Record: Identifiable {
        var id: String { "\(code)-\(day)" }
        var code: String
        var day: String
        var stepPercent: Double
        var alpha: Double
        var pnl: Double
        var maxDrawdown: Double
        var fees: Double
        var commission: Double
        var slippage: Double
        var score: Int
    }

    let rawJSON: String

    private var records: [Record] {
        guard let bytes = rawJSON.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: bytes)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let code = row["code"] as? String, let day = row["day"] as? String else { return nil }
            func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
            return Record(code: code, day: day, stepPercent: number("stepPct"), alpha: number("alpha"),
                          pnl: number("pnl"), maxDrawdown: number("maxDD"), fees: number("fees"),
                          commission: number("commissionCost"), slippage: number("slippageCost"),
                          score: Int(number("score")))
        }.sorted { $0.day > $1.day }
    }

    var body: some View {
        if records.isEmpty {
            Text(rawJSON).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(5).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("历史样本 · 只读，不参与原生参数建议")
                    .font(.caption).foregroundStyle(.secondary)
                if records.count > 30 {
                    Text("共 \(records.count) 条，以下显示最近 30 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(records.prefix(30))) { item in
                    DisclosureGroup("\(item.day) · \(item.code) · 格距 \((item.stepPercent).num(2))%") {
                        LabeledContent("相对持有", value: (item.alpha).cny())
                        LabeledContent("模拟盈亏", value: (item.pnl).cny())
                        LabeledContent("最大回撤", value: "\((item.maxDrawdown).num(2))%")
                        LabeledContent("模拟费用", value: (item.fees).cny())
                        LabeledContent("佣金 / 滑点", value: "\((item.commission).num(2)) / \((item.slippage).num(2)) 元")
                        LabeledContent("旧版评分", value: "\(item.score)")
                    }
                }
            }
        }
    }
}
