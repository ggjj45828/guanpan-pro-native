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

    static func analyze(config: AIAnalysisConfig, portfolio: PortfolioData) async throws -> String {
        try await request(config: config, prompt: portfolioPrompt(portfolio))
    }

    /// 通用对话入口：供「账户智能画像」等本机规则先行、可选大模型深挖的功能复用。
    static func chat(config: AIAnalysisConfig, prompt: String) async throws -> String {
        try await request(config: config, prompt: prompt)
    }

    static func analyzeInstrument(config: AIAnalysisConfig, holding: Holding,
                                  quote: Quote?, bars: [DailyBar],
                                  intradayBars: [IntradayBar] = [],
                                  priceLevels: String? = nil) async throws -> String {
        let fmt: (Double) -> String = { String(format: "%.4f", $0) }
        let history = bars.suffix(120).map {
            "\($0.date): 开 \(fmt($0.open)) 高 \(fmt($0.high)) 低 \(fmt($0.low)) 收 \(fmt($0.close)) 量 \(Int($0.volume))"
        }.joined(separator: "\n")
        let holdingText = holding.quantity > 0
            ? "持仓：\(holding.quantity) 份，成本 \(fmt(holding.cost))，当前账面价格 \(fmt(holding.current))，账面浮盈亏 \(fmt(holding.pnl))。"
            : "当前未持有此标的。"
        let quoteText = quote.map { "行情：\(fmt($0.price))，涨跌 \(String(format: "%.2f", $0.changePct * 100))%，时间 \($0.updatedAt?.formatted() ?? "未知")。" } ?? "自选实时行情不可用。"
        let minuteRows = intradayBars.sorted { $0.timestamp < $1.timestamp }.suffix(180)
        let minutePrices = minuteRows.map(\.price).filter { $0 > 0 }
        let minuteSummary: String
        if let first = minutePrices.first, let last = minutePrices.last,
           let low = minutePrices.min(), let high = minutePrices.max() {
            let average = minutePrices.reduce(0, +) / Double(minutePrices.count)
            let change = first > 0 ? (last / first - 1) * 100 : 0
            minuteSummary = "所选交易日分时摘要：\(minuteRows.first?.day ?? "")，\(minutePrices.count) 个有效价格点；首末变化 \(String(format: "%.2f", change))%，区间低高 \(fmt(low)) / \(fmt(high))，样本均价 \(fmt(average))。该均价是本机采样简单平均，不是交易所 VWAP。"
        } else {
            minuteSummary = "暂无可用的本机分时价格点。"
        }
        let minuteHistory = minuteRows.map {
            "\($0.timestamp.formatted(date: .omitted, time: .shortened)) \(fmt($0.price))" + ($0.volume.map { " 量 \(Int($0))" } ?? "")
        }.joined(separator: "\n")
        let historyText = history.isEmpty ? "暂无本机日线数据" : history
        let levelText = priceLevels ?? "日线不足，未计算支撑压力参考"
        let minuteHistoryText = minuteHistory.isEmpty ? "暂无本机分时数据" : minuteHistory
        let prompt = "请对单个标的做研究摘要，分为‘数据概况、技术观察、主要风险、还需核对’。只根据输入的数据作判断；不要编造新闻、估值或未提供的指标，也不要给确定涨跌预测或自动交易指令。\n标的：\(holding.name)（\(holding.code)）。\(holdingText)\(quoteText)\n日线数据（最多 120 条，前复权）：\n\(historyText)\n\n历史支撑压力参考（只使用已完成日线）：\n\(levelText)\n\n\(minuteSummary)\n分时明细（最多 180 个本机采样点）：\n\(minuteHistoryText)"
        return try await request(config: config, prompt: prompt)
    }

    private static func request(config: AIAnalysisConfig, prompt: String) async throws -> String {
        let token = try loadAPIKey()
        let base = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw AIAnalysisError.invalidEndpoint
        }
        let target = base.lowercased().hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: target), !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAnalysisError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(min(180, max(5, config.timeoutSeconds)))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "stream": false,
            "messages": [
                ["role": "system", "content": config.systemPrompt.isEmpty ? AIAnalysisConfig().systemPrompt : config.systemPrompt],
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

    private static func portfolioPrompt(_ data: PortfolioData) -> String {
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
        return "请分析以下观盘账户数据，按‘数据概况、观察到的变化、主要风险、还需核对’分段回答。只依据提供的数据；价格可能延迟，净值可能滞后。不要编造技术指标或新闻，也不要声称能确定预测涨跌。\n\n用户自述投资偏好（仅作为分析约束，不代表收益目标可实现）：\n\(profile)\n\n参考现金：\(fmt(data.cash))\n持仓：\n\(holdingsText)\n\n自选行情：\n\(quotesText)\n\n最近资产快照：\n\(snapshotsText)"
    }
}
