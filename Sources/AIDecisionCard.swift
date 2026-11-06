import SwiftUI

// MARK: - 今日判断卡
//
// 大模型的回答是几千字的连续文本：结论埋在第一段，风险藏在倒数第二段，
// 失效条件经常只有一句话。回头看的时候既找不到重点，也不知道「当时是靠什么下的判断」。
//
// 这一层不改变模型输出，只做两件事：
// 1. 把已经很规整的分组（AIResultParser 的产物）按「结论 / 依据 / 风险 / 等待 / 失效 / 跟踪」
//    归类，缺哪段就如实留空 —— 不为了把卡片填满去编内容；
// 2. 置信度由**本机**按「证据是否齐全 + 行情是否新鲜」算，不采信模型自称的把握程度。
//    模型自评「非常有信心」而没有任何价位和失效条件时，这里照样给低分。

struct AIDecisionSection: Identifiable {
    enum Kind: String, CaseIterable {
        case basis, risk, waiting, invalidate, tracking

        var title: String {
            switch self {
            case .basis: return "依据"
            case .risk: return "风险"
            case .waiting: return "等待条件"
            case .invalidate: return "失效条件"
            case .tracking: return "跟踪项"
            }
        }

        var symbol: String {
            switch self {
            case .basis: return "text.magnifyingglass"
            case .risk: return "exclamationmark.triangle"
            case .waiting: return "hourglass"
            case .invalidate: return "xmark.octagon"
            case .tracking: return "eye"
            }
        }

        var tone: Color {
            switch self {
            case .basis: return CardTone.ok
            case .risk: return CardTone.warn
            case .waiting: return CardTone.accent
            case .invalidate: return PnLColor.down
            case .tracking: return CardTone.ok
            }
        }

        /// 标题里出现这些词就归到本段。顺序敏感：先匹配「失效」再匹配「风险」，
        /// 否则「失效风险」会被风险先吃掉。
        var keywords: [String] {
            switch self {
            case .basis: return ["依据", "逻辑", "理由", "为什么", "数据", "证据", "分析"]
            case .risk: return ["风险", "警惕", "注意", "隐患", "回撤"]
            case .waiting: return ["等待", "条件", "触发", "观察", "待确认", "确认后", "如果"]
            case .invalidate: return ["失效", "推翻", "证伪", "止损", "错判"]
            case .tracking: return ["跟踪", "复核", "后续", "核实", "关注"]
            }
        }
    }

    let kind: Kind
    let lines: [String]
    var id: String { kind.rawValue }
}

struct AIDecision {
    let headline: String
    /// 结论段之外的分段，按 Kind.allCases 顺序。
    let sections: [AIDecisionSection]
    /// 0…1，本机根据证据完整度与行情新鲜度算出。
    let confidence: Double
    let confidenceLabel: String
    let evidenceNote: String
    let asOf: Date?

    var hasAnything: Bool { !headline.isEmpty || !sections.isEmpty }
}

enum AIDecisionBuilder {
    /// 从一次分析结果里抽判断卡。
    /// - Parameters:
    ///   - text: 模型返回的原文（或已保存的历史回答）。
    ///   - suggestions: 同一次回答里解析出的可执行建议，用来补「失效条件」与价位。
    ///   - quotesFresh: 行情是否在有效期内；不新鲜时证据链打折扣。
    static func make(text: String, suggestions: [AISuggestion],
                     quotesFresh: Bool, asOf: Date?) -> AIDecision {
        let groups = AIResultParser.parse(text)
        var headline = ""
        var buckets: [AIDecisionSection.Kind: [String]] = [:]
        var leftovers: [String] = []

        for group in groups {
            let title = group.title ?? ""
            let body = group.blocks.map { $0.text }.filter { !$0.isEmpty }
            guard !body.isEmpty else { continue }

            if let kind = matchKind(title) {
                buckets[kind, default: []].append(contentsOf: body)
            } else if headline.isEmpty, isConclusionTitle(title) {
                headline = body.joined(separator: " ")
            } else {
                // 没有明确标题的段落（摘要、背景、数据）并入依据；
                // 但如果整篇就这一段，它本身就是结论。
                if headline.isEmpty, groups.count <= 1 {
                    headline = body.joined(separator: " ")
                } else {
                    leftovers.append(contentsOf: body)
                }
            }
        }

        if headline.isEmpty, let first = leftovers.first {
            headline = first
            leftovers.removeFirst()
        }
        if !leftovers.isEmpty {
            buckets[.basis, default: []].insert(contentsOf: leftovers, at: 0)
        }

        // 建议里带失效价 / 目标价时，补一条可执行的失效条件 —— 这是模型最容易漏、也最有用的一段。
        if buckets[.invalidate]?.isEmpty ?? true {
            let invalidLines = suggestions.compactMap { suggestion -> String? in
                guard let invalid = suggestion.invalid else { return nil }
                return "\(suggestion.displayName) 跌破 \(invalid.num(3)) 视为判断被推翻"
            }
            if !invalidLines.isEmpty { buckets[.invalidate] = invalidLines }
        }

        let sections = AIDecisionSection.Kind.allCases.compactMap { kind -> AIDecisionSection? in
            guard let lines = buckets[kind], !lines.isEmpty else { return nil }
            return AIDecisionSection(kind: kind, lines: Array(lines.prefix(4)))
        }

        let (confidence, note) = score(headline: headline, sections: sections,
                                       suggestions: suggestions, quotesFresh: quotesFresh)

        return AIDecision(
            headline: clean(headline),
            sections: sections,
            confidence: confidence,
            confidenceLabel: label(for: confidence),
            evidenceNote: note,
            asOf: asOf)
    }

    private static func isConclusionTitle(_ title: String) -> Bool {
        let keys = ["结论", "判断", "核心", "总体", "摘要", "一句话"]
        return keys.contains { title.contains($0) }
    }

    private static func matchKind(_ title: String) -> AIDecisionSection.Kind? {
        guard !title.isEmpty else { return nil }
        for kind in [AIDecisionSection.Kind.invalidate, .risk, .waiting, .tracking, .basis] {
            if kind.keywords.contains(where: { title.contains($0) }) { return kind }
        }
        return nil
    }

    private static func score(headline: String, sections: [AIDecisionSection],
                              suggestions: [AISuggestion], quotesFresh: Bool) -> (Double, String) {
        var points = 0.0
        var total = 0.0
        func require(_ condition: Bool) {
            total += 1
            if condition { points += 1 }
        }
        require(!headline.isEmpty)
        require(sections.contains { $0.kind == .basis })
        require(sections.contains { $0.kind == .risk })
        require(sections.contains { $0.kind == .invalidate })
        require(!suggestions.isEmpty)
        require(quotesFresh)

        let raw = total > 0 ? points / total : 0
        var missing: [String] = []
        if headline.isEmpty { missing.append("结论") }
        if !sections.contains(where: { $0.kind == .basis }) { missing.append("依据") }
        if !sections.contains(where: { $0.kind == .risk }) { missing.append("风险") }
        if !sections.contains(where: { $0.kind == .invalidate }) { missing.append("失效条件") }
        if suggestions.isEmpty { missing.append("可执行价位") }
        if !quotesFresh { missing.append("新鲜行情") }

        let note = missing.isEmpty
            ? "结论、依据、风险、失效条件都齐，行情在有效期内"
            : "缺 " + missing.joined(separator: "、") + "；缺得越多越不该照做"
        return (raw, note)
    }

    private static func label(for value: Double) -> String {
        if value >= 0.85 { return "证据较全" }
        if value >= 0.6 { return "够用但不够硬" }
        if value >= 0.35 { return "证据偏薄" }
        return "仅作参考"
    }

    /// 结论只留第一句，避免把整段分析塞进大字标题。
    private static func clean(_ text: String) -> String {
        let trimmed = AIResultParser.removeMarkdownMarkers(text)
        guard let stop = trimmed.firstIndex(where: { "。！？；".contains($0) }) else {
            return String(trimmed.prefix(120))
        }
        return String(trimmed[...stop])
    }
}

struct AIDecisionCard: View {
    let decision: AIDecision
    @Environment(\.appAppearance) private var appearance

    private var theme: AppTheme { AppTheme.palette(for: AppAppearance.resolved(appearance)) }
    private var accent: Color { CardTone.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !decision.headline.isEmpty {
                Text(decision.headline)
                    .scaledFont(17, weight: .semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(decision.sections) { section in
                sectionView(section)
            }
            footer
        }
        .padding(AppLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cardRadius, style: .continuous)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardRadius, style: .continuous)
                .strokeBorder(accent.opacity(theme.isLight ? 0.22 : 0.30), lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日判断：\(decision.headline)。置信度 \(decision.confidenceLabel)。\(decision.evidenceNote)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "sparkles")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("今日判断").scaledFont(15, weight: .bold)
                if let asOf = decision.asOf {
                    Text(asOf.formatted(date: .omitted, time: .shortened) + " 生成")
                        .scaledFont(10)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            confidenceBadge
        }
    }

    /// 置信度配色抽成函数：嵌套三元 + Color 在 ViewBuilder 里很容易拖慢类型检查。
    private func confidenceTint(_ value: Double) -> Color {
        if value >= 0.85 { return PnLColor.up }
        if value >= 0.6 { return CardTone.ok }
        return CardTone.warn
    }

    private var confidenceBadge: some View {
        let tint = confidenceTint(decision.confidence)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(decision.confidenceLabel)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(tint)
            Text("置信度 \(Int((decision.confidence * 100).rounded()))%")
                .scaledFont(9)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.7))
    }

    private func sectionView(_ section: AIDecisionSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: section.kind.symbol)
                    .scaledFont(10, weight: .semibold)
                    .foregroundStyle(section.kind.tone)
                Text(section.kind.title)
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(section.kind.tone)
                Spacer(minLength: 0)
            }
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").scaledFont(11).foregroundStyle(.secondary)
                    Text(line)
                        .scaledFont(12)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(section.kind.tone.opacity(theme.isLight ? 0.06 : 0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        Text(decision.evidenceNote)
            .scaledFont(10)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
