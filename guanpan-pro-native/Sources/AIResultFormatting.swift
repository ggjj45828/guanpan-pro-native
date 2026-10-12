import SwiftUI
import Foundation

/// 把大模型返回的 Markdown 文本整理成适合手机阅读的分层卡片。
/// 模型输出仍保留原文含义，只在展示层识别标题、粗体、分隔线和列表。
struct AIFormattedResultView: View {
    let text: String
    let accent: Color

    @Environment(\.appAppearance) private var appearance

    private var groups: [AIResultGroup] { AIResultParser.parse(text) }
    private var theme: AppTheme { AppTheme.palette(for: AppAppearance.resolved(appearance)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups.indices, id: \.self) { index in
                resultCard(groups[index], index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func resultCard(_ group: AIResultGroup, index: Int) -> some View {
        let style = cardStyle(for: group.title, index: index)
        return VStack(alignment: .leading, spacing: 11) {
            if let title = group.title, !title.isEmpty {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: style.icon)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(style.color)
                        .frame(width: 28, height: 28)
                        .background(style.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title)
                        .scaledFont(16, weight: .bold)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }

            ForEach(group.blocks) { block in
                blockView(block, color: style.color)
            }
        }
        .padding(AppLayout.cardPadding)
        .background(RoundedRectangle(cornerRadius: AppLayout.cardRadius, style: .continuous).fill(theme.surface))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(style.color.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardRadius, style: .continuous)
                .strokeBorder(style.color.opacity(theme.isLight ? 0.20 : 0.28), lineWidth: 0.8)
        }
    }

    @ViewBuilder private func blockView(_ block: AIResultBlock, color: Color) -> some View {
        switch block.kind {
        case .paragraph:
            markdownText(block.text)
                .scaledFont(15)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .subheading:
            markdownText(block.text)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(.primary)
                .padding(.top, 2)
        case .bullet(let marker):
            HStack(alignment: .top, spacing: 9) {
                if let marker {
                    Text(marker)
                        .scaledFont(11, weight: .bold, design: .rounded)
                        .foregroundStyle(color)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(color.opacity(0.12), in: Circle())
                } else {
                    Circle().fill(color).frame(width: 6, height: 6).padding(.top, 7)
                }
                markdownText(block.text)
                    .scaledFont(15)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .divider:
            Divider().opacity(0.55)
        }
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value) {
            return Text(attributed)
        }
        return Text(AIResultParser.removeMarkdownMarkers(value))
    }

    private func cardStyle(for title: String?, index: Int) -> (icon: String, color: Color) {
        let value = title ?? ""
        if value.contains("风险") || value.contains("限制") || value.contains("反证") || value.contains("核对") || value.contains("失效") {
            return ("exclamationmark.triangle.fill", CardTone.warn)
        }
        if value.contains("行动") || value.contains("计划") || value.contains("建议") || value.contains("优先") {
            return ("arrow.right.circle.fill", accent)
        }
        if value.contains("画像") || value.contains("行为") || value.contains("事实") || value.contains("依据") {
            return ("chart.bar.fill", CardTone.ok)
        }
        if value.contains("结论") || value.contains("判断") || index == 0 {
            return ("checkmark.seal.fill", accent)
        }
        return ("doc.text.fill", accent)
    }
}

private struct AIResultGroup: Identifiable {
    let id = UUID()
    var title: String?
    var blocks: [AIResultBlock]
}

private struct AIResultBlock: Identifiable {
    enum Kind {
        case paragraph
        case subheading
        case bullet(marker: String?)
        case divider
    }

    let id = UUID()
    var kind: Kind
    var text: String
}

enum AIResultParser {
    static func parse(_ raw: String) -> [AIResultGroup] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var groups: [AIResultGroup] = []
        var title: String?
        var blocks: [AIResultBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let value = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(AIResultBlock(kind: .paragraph, text: value)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushGroup() {
            flushParagraph()
            guard title != nil || !blocks.isEmpty else { return }
            groups.append(AIResultGroup(title: title, blocks: blocks))
            title = nil
            blocks = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }

            if isDivider(line) {
                flushParagraph()
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                if heading.level <= 2 {
                    flushGroup()
                    title = cleanHeading(heading.text)
                } else {
                    blocks.append(AIResultBlock(kind: .subheading, text: cleanHeading(heading.text)))
                }
                continue
            }

            // 大模型经常按中文报告习惯输出“一、核心判断”，而不是 Markdown 的 ##。
            // 旧解析器会把整篇回答塞进一张巨型卡片，手机上很难找到结论和行动。
            if let heading = structuredHeading(from: line) {
                flushParagraph()
                flushGroup()
                title = heading
                continue
            }

            if isShortBoldHeading(line) {
                flushParagraph()
                blocks.append(AIResultBlock(kind: .subheading, text: removeMarkdownMarkers(line)))
                continue
            }

            if let bullet = bullet(from: line) {
                flushParagraph()
                blocks.append(AIResultBlock(kind: .bullet(marker: bullet.marker), text: bullet.text))
                continue
            }

            paragraph.append(line)
        }

        flushGroup()
        if groups.isEmpty {
            return [AIResultGroup(title: "分析摘要", blocks: [AIResultBlock(kind: .paragraph, text: removeMarkdownMarkers(raw))])]
        }
        if groups.count > 1, groups.first?.title == nil {
            groups[0].title = "分析摘要"
        }
        return groups
    }

    static func removeMarkdownMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "---", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            guard character == "#" else { break }
            level += 1
        }
        guard level > 0, level <= 6 else { return nil }
        let index = line.index(line.startIndex, offsetBy: level)
        let value = line[index...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (level, value)
    }

    private static func structuredHeading(from line: String) -> String? {
        let clean = removeMarkdownMarkers(line)
        let prefixes = ["一、", "二、", "三、", "四、", "五、", "六、",
                        "1. ", "2. ", "3. ", "4. ", "5. ", "6. ",
                        "1、", "2、", "3、", "4、", "5、", "6、"]
        let keywords = ["判断", "结论", "依据", "行动", "计划", "建议", "风险", "失效", "核实", "关键价位"]
        for prefix in prefixes where clean.hasPrefix(prefix) {
            let value = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 28,
                  keywords.contains(where: value.contains) else { return nil }
            return value
        }
        if clean.count <= 20, keywords.contains(where: clean.contains),
           !clean.contains("。"), !clean.contains("；") {
            return clean.trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
        }
        return nil
    }

    private static func bullet(from line: String) -> (marker: String?, text: String)? {
        for prefix in ["- ", "• ", "· ", "* "] where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return (nil, value) }
        }

        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." || line[index] == "、" else { return nil }
        index = line.index(after: index)
        let value = String(line[index...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (digits, value)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func isShortBoldHeading(_ line: String) -> Bool {
        guard line.hasPrefix("**"), line.hasSuffix("**"), line.count <= 48 else { return false }
        let value = removeMarkdownMarkers(line)
        return value.hasSuffix("：") || value.hasSuffix(":") || value.count <= 20
    }

    private static func cleanHeading(_ value: String) -> String {
        var text = removeMarkdownMarkers(value)
        while let first = text.first, first.isNumber { text.removeFirst() }
        while let first = text.first, ".、:：)） ".contains(first) { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
