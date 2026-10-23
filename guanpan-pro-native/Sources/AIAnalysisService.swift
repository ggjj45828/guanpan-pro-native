import Foundation
import CoreFoundation
import Security

enum AIAnalysisError: LocalizedError {
    case missingKey
    case invalidEndpoint
    case keychain(OSStatus)
    case server(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "请先填写并保存 API 密钥。"
        case .invalidEndpoint: return "接口地址无效。请填写 HTTPS 的兼容接口基础地址。"
        case .keychain(let status): return "密钥无法安全保存（Keychain 错误 \(status)）。"
        case .server(let message): return "分析接口返回错误：\(message)"
        case .emptyResponse: return "接口没有返回可显示的分析内容。"
        }
    }
}

enum AIAnalysisService {
    private static let keychainService = "com.guanpan.pro.native.ai"
    private static let keychainAccount = "api-key"
    /// 固定分析标准与个性化提示分层，避免自定义要求覆盖网页版的推理深度。
    private static let analysisStandard = """
    你是有独立判断的投资研究助手，分析要帮助用户决定下一步，而不是复述行情或逐项解释指标。先形成明确但有条件的核心判断，再说明推理链：趋势结构、动能与量能、所处区间/关键支撑压力如何相互印证或冲突；只挑最能改变结论的少数证据，解释其意义，不堆数字。操作建议要落到观察触发条件、行动、仓位/节奏边界和复核时点；同时给出会推翻判断的反向信号。区分输入事实与推断，说明报价、净值、日线或样本的时效和缺口；没有的数据不得编造。结合用户实际持仓、成本、风险偏好和期限。禁止保证收益、无条件买卖指令、空泛风险套话、重复输入清单和假装使用外部信息。表达简洁自然，优先写判断与因果，不朗读指标。
    个股/ETF分析需覆盖趋势、动能量能、关键支撑压力、条件化操作与风险；没有可靠价位数据时明确说无法给价位，不得虚构。组合分析优先处理最影响结果的集中度、重复暴露、现金与期限匹配，最多提出三项优先行动，不必逐只复述全部持仓。账户画像要把流水行为与当前结构分开判断；样本不足时明确不可推断。
    """
    private static let explanationStandard = """
    你是观盘手机端统一投资顾问的解释层。手机本机规则已经产生唯一的策略判断；你只能解释输入中已有的结论和证据，不能提出、修改或替换策略动作，不能生成或推算买卖价、份额、收益、网格档位或交易指令。仅使用本次输入的数据，明确数据缺口和条件，不编造事实。若输入要求结构化格式，严格遵守其格式；无法安全解释时说明沿用本机判断。
    """

    static var hasSavedAPIKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func saveAPIKey(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !clean.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(clean.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AIAnalysisError.keychain(status) }
    }

    private static func loadAPIKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw AIAnalysisError.missingKey
        }
        return token
    }

    /// 组合分析。
    ///
    /// `extraSections` 是本机算好的补充材料（交易行为画像、大盘环境、技术面、组合风险），
    /// 由 `AIContextBuilder` 拼装 —— 这一层只负责「怎么问」，不关心 store 里有什么。
    static func analyze(config: AIAnalysisConfig, portfolio: PortfolioData,
                        extraSections: [String] = []) async throws -> String {
        let prompt = portfolioPrompt(portfolio, extraSections: extraSections)
            + "\n\n" + AISuggestionParser.formatInstruction
        return try await request(config: config, prompt: prompt)
    }

    /// 通用对话入口：供「账户智能画像」等本机规则先行、可选大模型深挖的功能复用。
    static func chat(config: AIAnalysisConfig, prompt: String) async throws -> String {
        try await request(config: config, prompt: prompt, systemInstruction: explanationStandard)
    }

    private static func request(config: AIAnalysisConfig, prompt: String,
                                systemInstruction: String? = nil) async throws -> String {
        let token = try loadAPIKey()
        let base = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw AIAnalysisError.invalidEndpoint
        }
        let target = base.lowercased().hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        let configuredModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // 兼容旧备份：2026-07 后 deepseek-chat / deepseek-reasoner 已不再是可用模型名。
        let model: String
        switch configuredModel {
        case "deepseek-chat", "deepseek-reasoner": model = "deepseek-v4-pro"
        case "deepseek-v4-flash": model = "deepseek-flash"
        default: model = configuredModel
        }
        guard let url = URL(string: target), !model.isEmpty else {
            throw AIAnalysisError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(min(180, max(5, config.timeoutSeconds)))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuredPrompt = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemMessage = systemInstruction ??
            (analysisStandard + (configuredPrompt.isEmpty ? "" : "\n\n用户补充的个性化偏好（仅在不违反以上分析标准时采用）：\n" + configuredPrompt))
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            // Flash 用非思考模式突出速度；V4 Pro 用思考模式做账户/单标的深度分析。
            "thinking": ["type": model == "deepseek-flash" ? "disabled" : "enabled"],
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIAnalysisError.server("无法读取 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            let error = payload?["error"] as? [String: Any]
            throw AIAnalysisError.server((error?["message"] as? String) ?? "HTTP \(http.statusCode)")
        }
        let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let choices = payload?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content, !content.isEmpty else { throw AIAnalysisError.emptyResponse }
        return content
    }

    private static func portfolioPrompt(_ data: PortfolioData, extraSections: [String] = []) -> String {
        let fmt: (Double) -> String = { String(format: "%.2f", $0) }
        let holdings = data.holdings.map { h -> String in
            let kindText = h.kind == .fund ? "场外基金" : "ETF/证券"
            return "- \(h.name)（\(h.code)，\(kindText)）：份额 \(fmt(h.quantity))，成本 \(fmt(h.cost))，现价/净值 \(fmt(h.current))，市值 \(fmt(h.marketValue))，浮动盈亏 \(fmt(h.pnl))）"
        }.joined(separator: "\n")
        let quotes = data.quotes.map { q -> String in
            let timeText = q.updatedAt?.formatted() ?? "未知"
            let changeText = String(format: "%.2f", q.changePct * 100)
            return "- \(q.name)（\(q.code)）：\(fmt(q.price))，涨跌 \(changeText)%，更新时间 \(timeText)"
        }.joined(separator: "\n")
        let snapshots = data.snapshots.sorted { $0.date < $1.date }.suffix(20).map {
            "\($0.date): 总资产 \(fmt($0.total))，现金 \(fmt($0.cash))"
        }.joined(separator: "\n")
        let p = data.investmentProfile
        let style = ["day": "超短线", "swing": "波段", "mid": "中线", "long": "长线定投"][p.style] ?? p.style
        let risk = ["con": "保守", "bal": "平衡", "agg": "激进"][p.risk] ?? p.risk
        let premiumText = p.premiumSensitive ? "是" : "否"
        let preferenceText = p.preference.isEmpty ? "未填写" : p.preference
        let avoidText = p.avoid.isEmpty ? "未填写" : p.avoid
        let methodText = p.method.isEmpty ? "未填写" : p.method
        let goalText = p.goal.isEmpty ? "未填写" : p.goal
        let profile = "交易风格：\(style)；风险偏好：\(risk)；典型持有周期：\(p.horizon)；单标的仓位上限：\(fmt(p.maxPositionPercent))%；ETF 溢价敏感：\(premiumText)；偏好：\(preferenceText)；忌讳：\(avoidText)；交易方式：\(methodText)；目标：\(goalText)"
        let holdingsText = holdings.isEmpty ? "（暂无）" : holdings
        let quotesText = quotes.isEmpty ? "（暂无）" : quotes
        let snapshotsText = snapshots.isEmpty ? "（暂无）" : snapshots
        let cashFlows = data.cashFlows.sorted { $0.date > $1.date }.prefix(30).map { flow in
            let direction = flow.amount >= 0 ? "转入" : "转出"
            return "\(flow.date.formatted(date: .numeric, time: .omitted)) \(direction)\(fmt(abs(flow.amount)))元，\(flow.external == false ? "账户内调拨" : "外部资金流")，备注：\(flow.memo.isEmpty ? "无" : flow.memo)"
        }.joined(separator: "\n")
        let cashFlowsText = cashFlows.isEmpty ? "暂无现金流记录；不能据此区分账户收益与外部资金转入。" : cashFlows
        let recentTrades = data.ledger.sorted { $0.date > $1.date }.prefix(30).map { trade in
            let side = trade.side == .buy ? "买入" : "卖出"
            return "\(trade.date.formatted(date: .numeric, time: .omitted)) \(side) \(trade.name)(\(trade.code))，成交额\(fmt(trade.gross))，费用\(fmt(trade.fee))，已实现盈亏\(fmt(trade.realizedPnL))"
        }.joined(separator: "\n")
        let recentTradesText = recentTrades.isEmpty ? "没有 ETF/证券买卖流水，不能判断操作胜率或交易纪律。" : recentTrades
        let fundTransactions = data.fundTransactions.sorted { $0.effectiveDate > $1.effectiveDate }.prefix(30).map { trade in
            let side = trade.side == .buy ? "申购" : trade.side == .sell ? "赎回" : "分红"
            return "\(trade.effectiveDate) \(side) \(trade.name)(\(trade.code))，份额\(fmt(trade.quantity))，净值\(fmt(trade.nav))，金额\(fmt(trade.amount))，费用\(fmt(trade.fee))，已实现盈亏\(fmt(trade.realizedPnL))，状态\(trade.status == .confirmed ? "已确认" : "待确认")"
        }.joined(separator: "\n")
        let fundTransactionsText = fundTransactions.isEmpty ? "没有基金申赎/分红流水，不能判断基金交易纪律。" : fundTransactions
        let dcaPlans = data.fundDCAPlans.map { plan in
            let frequency = [FundDCAPlan.Frequency.daily: "每日", .weekly: "每周", .biweekly: "每两周", .monthly: "每月"][plan.frequency] ?? plan.frequency.rawValue
            return "\(plan.name)(\(plan.code))，每期\(fmt(plan.amount))元，\(frequency)，\(plan.enabled ? "执行中" : "已暂停")，已执行\(plan.processedDates.count)期"
        }.joined(separator: "\n")
        let dcaPlansText = dcaPlans.isEmpty ? "暂无基金定投计划。" : dcaPlans
        let fundComposition = data.fundConstituentSnapshots.map { snapshot in
            let top = snapshot.holdings.sorted { $0.weightPercent > $1.weightPercent }.prefix(10)
                .map { "\($0.name)(\($0.code)) \($0.weightPercent.num(1))%" }.joined(separator: "、")
            return "\(snapshot.name)(\(snapshot.code))，报告日期\(snapshot.asOf)：\(top.isEmpty ? "无成分明细" : top)"
        }.joined(separator: "\n")
        let fundCompositionText = fundComposition.isEmpty ? "没有已保存的基金成分报告，不能核实基金穿透重叠。" : fundComposition
        let weighted = data.holdings.reduce(0.0) { $0 + $1.marketValue }
        let exposureText = data.holdings.sorted { $0.marketValue > $1.marketValue }.map { item in
            let weight = data.cash + weighted > 0 ? item.marketValue / (data.cash + weighted) * 100 : 0
            return "\(item.name)占总资产约\(weight.num(1))%（账面盈亏\(fmt(item.pnl))，单标的上限\(fmt(p.maxPositionPercent))%）"
        }.joined(separator: "\n")
        let exposureSummary = exposureText.isEmpty ? "暂无持仓" : exposureText
        let extrasText = extraSections.isEmpty ? "" : "\n" + extraSections.joined(separator: "\n") + "\n"
        return """
        请做组合决策分析，而不是把持仓、自选、成交和快照逐项改写。先从持仓金额、成本、现金、期限和报价质量中找出最影响下一步的一到两个矛盾或风险，解释因果关系和优先级。
        按以下结构回答：1. 核心判断：一两句话说明组合最需要处理的事、置信度和关键数据限制。2. 优先行动：最多 3 项；每项写清“问题/证据为何重要 → 触发条件 → 执行步骤与仓位边界 → 何时复核或撤销”，不要为了凑数逐只下结论。3. 组合结构：讨论现金缓冲、集中度/可能重复暴露、风险偏好与期限；没有基金成分或相关性数据时标为待核实，不得断言重仓同一行业。4. 反证与核对：说明哪些变化会推翻判断，以及最值得补充的数据。
        只把已提供数据当事实；数字只用于支撑因果判断，不要照单朗读。对推断明确标注。不得假装已查新闻、基本面、盘口或外部数据。报价/净值可能过时，缺少技术数据时降低置信度并给条件计划，不强给买卖结论。不承诺收益，不自动交易。输出自然、简洁、具体、有判断。

        【用户投资画像与约束】
        \(profile)
        【参考现金】\(fmt(data.cash))
        【持仓与总资产占比】
        \(exposureSummary)
        【持仓明细】
        \(holdingsText)
        【自选报价（附更新时间）】
        \(quotesText)
        【最近账户快照】
        \(snapshotsText.isEmpty ? "暂无快照，不能判断资产趋势。" : snapshotsText)
        【最近现金流（最多 30 笔）】
        \(cashFlowsText)
        【最近成交（最多 30 笔）】
        \(recentTradesText)
        【场外基金申赎/分红（最多 30 笔）】
        \(fundTransactionsText)
        【场外基金定投计划】
        \(dcaPlansText)
        【已保存的基金前十大成分与报告日期】
        \(fundCompositionText)
        \(extrasText)
        """
    }
}
