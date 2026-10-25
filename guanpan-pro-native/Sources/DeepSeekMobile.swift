import Foundation
import Security

enum DeepSeekMobile {
    private static let service = "com.guanpan.advisor.ios.deepseek"
    private static let account = "api-key"

    static func loadKey() -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        query[kSecAttrSynchronizable as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func saveKey(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw DeepSeekError.invalidKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        let update: [String: Any] = [kSecValueData as String: Data(normalized.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw DeepSeekError.keychain(updateStatus) }

        var item = query
        item[kSecValueData as String] = Data(normalized.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(item as CFDictionary, nil)
        // Another app operation can create the item between update and add.
        // Retry as an update instead of deleting the existing credential.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw DeepSeekError.keychain(status) }
    }

    static func deleteKey() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DeepSeekError.keychain(status) }
    }

    static func testConnection(key: String, profile: String, session: URLSession = .shared) async throws -> String {
        let model: String
        switch profile {
        case "flash": model = "deepseek-v4-flash"
        case "pro": model = "deepseek-v4-pro"
        default: throw DeepSeekError.invalidProfile
        }
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { throw DeepSeekError.network }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw DeepSeekError.invalidKey }
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "max_tokens": 8,
            "messages": [["role": "user", "content": "Reply with OK only."]]
        ])
        _ = try await send(request, session: session)
        return model
    }

    static func analyze(prompt: String, key: String, profile: String, session: URLSession = .shared) async throws -> (model: String, content: String) {
        let model: String
        switch profile {
        case "flash": model = "deepseek-v4-flash"
        case "pro": model = "deepseek-v4-pro"
        default: throw DeepSeekError.invalidProfile
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw DeepSeekError.invalidKey }
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { throw DeepSeekError.network }
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "thinking": ["type": "disabled"],
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": "你是手机端唯一的观盘 AI 私人投资顾问。输入是一份已由应用规则引擎生成的统一决策上下文，账户事实只认其中的真实持仓。NAS仅提供长期数据研究，不是另一个顾问。必须先读市场状态、行情时间、NAS样本质量、新闻、组合风险和投资画像，再用中文给出一份统一结论。请按下面的中文小标题分段输出：结论、建议方案、依据、新闻影响、风险与失效条件、下一步；没有内容的小节可以省略。每节控制在1到3条短句，避免重复和长段落。新闻是手机或NAS获得的搜索聚合标题，不含正文，来源/发布时间可能不完整；把它当待核验线索，不能断言标题已证实，说明它可能关联哪只持仓及是否足以影响候选计划。具体交易动作只能沿用上下文中的规则引擎策略和候选价格/份额；候选不存在、被标为数据不足、行情时间仅为接收时间或规则未核实时，必须明确说无法给出可靠挂单价。绝不能新算或编造价格、份额、收益、盘口、IOPV或交易规则。结论可以是做T、网格、持有、等待、暂停加仓、减仓或不交易；不交易是正常结论。说明依据、风险、计划期限/失效条件及与上次判断相比发生的变化。画像只用于排序与解释，不得降低门槛或迎合偏好造机会。未真实成交前不改写账本，不模拟收益，不自动下单。"],
                ["role": "user", "content": prompt]
            ]
        ])
        let content = try await send(request, session: session)
        return (model, content)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> String {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeepSeekError.network }
            guard http.statusCode == 200 else {
                switch http.statusCode {
                case 401, 403: throw DeepSeekError.unauthorized
                case 429: throw DeepSeekError.rateLimited
                case 500...599: throw DeepSeekError.serviceUnavailable
                default: throw DeepSeekError.http(http.statusCode)
                }
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeepSeekError.invalidResponse
            }
            return content
        } catch let error as DeepSeekError { throw error }
        catch { throw DeepSeekError.network }
    }
}

enum DeepSeekError: LocalizedError {
    case invalidKey, invalidProfile, unauthorized, rateLimited, serviceUnavailable, invalidResponse, network, http(Int), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidKey: "请输入 DeepSeek API key。"
        case .invalidProfile: "请选择有效的 DeepSeek 模型。"
        case .unauthorized: "API key 无效或没有该模型权限。"
        case .rateLimited: "请求频率或账户额度受限，请检查 DeepSeek 账户。"
        case .serviceUnavailable: "DeepSeek 服务暂时不可用。"
        case .invalidResponse: "DeepSeek 返回格式无效。"
        case .network: "连接 DeepSeek 失败，请检查网络后重试。"
        case .http(let code): "DeepSeek 返回 HTTP \(code)。"
        case .keychain(let status): "iPhone 安全钥匙串保存失败（\(status)）。"
        }
    }
}
