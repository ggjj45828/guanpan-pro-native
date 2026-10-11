import Foundation

/// 模型回答里那段「可执行建议」的结构化形态。
///
/// **为什么要做这一步**：大模型给的建议看完就散了 —— 过两天既想不起来当时
/// 为什么说要买，也想不起来打算在什么价位动手。把回答末尾那几行定长字段
/// 解析成结构体，就能一键落进已有的「交易计划与复盘」记录或价格提醒，
/// 让建议真正进入可复核的闭环，而不是停在聊天框里。
struct AISuggestion: Identifiable, Hashable {
    enum Side: String, Hashable {
        case buy, sell

        var label: String { self == .buy ? "买入/加仓" : "卖出/减仓" }
        /// 落到 `LedgerEntry.Side`（交易计划、流水的方向口径）。
        var ledgerSide: LedgerEntry.Side { self == .buy ? .buy : .sell }
    }

    var id = UUID()
    var side: Side
    var code: String
    var name: String
    /// 参考价 / 计划价。
    var price: Double?
    /// 目标价（止盈参考）。
    var target: Double?
    /// 失效价（止损或判断被推翻的价位）。
    var invalid: Double?
    var reason: String

    /// 名称缺失时用代码兜底，避免列表里出现空白行。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? code : trimmed
    }

    var hasAnyPrice: Bool { price != nil || target != nil || invalid != nil }
}

enum AISuggestionParser {
    /// 约定的行首标记。中英文之间不加分隔符，模型照抄时不容易抄错。
    static let marker = "观盘建议"

    /// 追加在 prompt 末尾的机器可读格式要求。
    ///
    /// 单独抽出来（而不是塞进 `analysisStandard`）是因为：这一段是**给本 App 解析用的协议**，
    /// 不是投资分析方法论。用户自定义 systemPrompt 时不该被它干扰，改协议时也只动这一处。
    static let formatInstruction = """
    【可执行建议（机器可读，供 App 一键转成交易计划或价格提醒）】
    如果本次分析确实得出可以落到具体价位的操作，请在回答最末尾另起一段，逐行按下面的固定格式写出；一条都没有就写「无」，不要为了凑格式编造。
    格式：\(marker)|方向|代码|名称|参考价|目标价|失效价|一句话理由
    方向只写 buy 或 sell。代码必须来自上面提供的持仓或自选，不得虚构。
    参考价/目标价/失效价只写数字，没有把握的字段留空。最多 3 条。
    示例：
    \(marker)|buy|510300|沪深300ETF|3.85|4.20|3.70|回踩年线且缩量，风险收益比合适
    \(marker)|sell|159915|创业板ETF|2.10||1.95|跌破平台且量能背离
    """

    /// 从模型回答里抓出可执行建议。
    ///
    /// 解析失败**不抛错、返回空数组** —— 这个函数的定位是「有就顺手用上，没有就算了」，
    /// 不能因为模型换了措辞就让整个分析页报错。所以对全角符号、前后缀项目符号、
    /// 字段粘连、多余字段都做了容错。
    static func parse(_ text: String) -> [AISuggestion] {
        // 模型可能把整段包在代码围栏里，先把围栏去掉再逐行看。
        let lines = text
            .replacingOccurrences(of: "```", with: "\n")
            .components(separatedBy: .newlines)

        var results: [AISuggestion] = []
        var seen = Set<String>()
        for raw in lines {
            guard let suggestion = parseLine(raw) else { continue }
            // 同方向同代码只留第一条：模型偶尔会把同一条重复两遍。
            let key = "\(suggestion.side.rawValue)|\(suggestion.code)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(suggestion)
            if results.count >= 6 { break }
        }
        return results
    }

    /// 把机器可读段从展示文本里剥掉，正文只留人话。
    ///
    /// 注意：**解析要用原文，展示才用剥过的文本**。如果先剥离再解析，
    /// 一旦剥离规则与解析规则有偏差就会把建议一起吃掉。
    static func displayText(_ text: String) -> String {
        let kept = text
            .replacingOccurrences(of: "```", with: "")
            .components(separatedBy: .newlines)
            .filter { parseLine($0) == nil }
        // 连续空行压成一个，避免剥离后正文中间出现一片空白。
        var collapsed: [String] = []
        for line in kept {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 单行解析

    private static func parseLine(_ raw: String) -> AISuggestion? {
        // 全角竖线、全角数字分隔符都归一化；顺手去掉行首的项目符号与空格。
        var line = raw
            .replacingOccurrences(of: "｜", with: "|")
            .replacingOccurrences(of: "。", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.first, "-•·*#　 \t".contains(first) {
            line.removeFirst()
        }
        line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(marker + "|") else { return nil }

        let fields = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 至少要有：标记、方向、代码、名称。
        guard fields.count >= 4 else { return nil }

        guard let side = side(from: fields[1]) else { return nil }
        let code = fields[2]
        guard !code.isEmpty else { return nil }
        let name = fields[3]

        // 字段下标：0 标记 / 1 方向 / 2 代码 / 3 名称 / 4 参考价 / 5 目标价 / 6 失效价 / 7.. 理由。
        // 理由里若含竖线会被多拆几段，用 dropFirst(7) 拼回来；缺理由就是空串，
        // 绝不能拿 fields[6]（那是失效价）当理由。
        let reason = fields.count >= 8 ? fields.dropFirst(7).joined(separator: "|") : ""

        return AISuggestion(side: side,
                            code: code,
                            name: name,
                            price: number(fields, at: 4),
                            target: number(fields, at: 5),
                            invalid: number(fields, at: 6),
                            reason: reason)
    }

    private static func side(from raw: String) -> AISuggestion.Side? {
        let value = raw.lowercased()
        if value.contains("buy") || value.contains("买") || value.contains("加仓") { return .buy }
        if value.contains("sell") || value.contains("卖") || value.contains("减仓") { return .sell }
        return nil
    }

    /// 取第 `index` 个字段并转成数字；空串、"--"、"无" 一律当「没填」。
    private static func number(_ fields: [String], at index: Int) -> Double? {
        guard fields.count > index else { return nil }
        let raw = fields[index]
        guard !raw.isEmpty, raw != "--", raw != "无", raw != "N/A", raw != "na" else { return nil }
        // 容忍 "3.85 元"、"3,85"（逗号当小数点）这类写法。
        let cleaned = raw
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return value
    }
}
