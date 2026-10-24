import Foundation
import Combine

enum NASResearchSettings {
    static let urlKey = "guanpan.native.researchNASURL"
}

/// v2 channel client. No writes or downloads are applied to the real PortfolioStore.
@MainActor
final class LabChannelCoordinator: ObservableObject {
    enum SyncError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    struct Status {
        var text: String
        var progress: Double = 0
        var revision: Int = 0
    }
    @Published private(set) var assets = Status(text: "默认手动 · 待用户操作")
    @Published private(set) var market = Status(text: "自动 · 未连接")
    @Published private(set) var quant = Status(text: "自动 · 未连接")
    private var busy = false
    @Published private(set) var marketDocument: [String: Any]?
    private var activeResearchBase = ""
    /// Last persisted NAS worker diagnostics, kept separate from the local experiment state.
    @Published private(set) var executorInfo: [String: Any] = [:]
    @Published private(set) var opportunityScan: [String: Any] = [:]
    private var marketCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("guanpan-v2-market-cache.json")
    }
    private var researchBase: String {
        let dedicated = UserDefaults.standard.string(forKey: NASResearchSettings.urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return dedicated.isEmpty ? (UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? "") : dedicated
    }
    private var researchToken: String? {
        let syncBase = (UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let research = researchBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return syncBase == research ? NASCredentialStore.load() : nil
    }
    init() {
        activeResearchBase = researchBase
        if let bytes = try? Data(contentsOf: marketCacheURL),
           let cached = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           cached["sourceBase"] as? String == activeResearchBase {
            marketDocument = cached["data"] as? [String: Any]
        }
    }

    private func url(_ channel: String) throws -> URL {
        let base = channel == "assets" ? (UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? "") : researchBase
        guard var components = URLComponents(url: try NASSyncService.normalizedBaseURL(base), resolvingAgainstBaseURL: false) else {
            throw SyncError.message("请先在原设置中配置 NAS 地址")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, "api/v2/channels/\(channel)"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil; components.fragment = nil
        guard let result = components.url else { throw SyncError.message("NAS 地址无效") }
        return result
    }
    private func request(_ channel: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: try url(channel)); req.timeoutInterval = 15
        let token = channel == "assets" ? NASCredentialStore.load() : researchToken
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        guard req.url == (try url(channel)) else { throw SyncError.message("NAS 地址已变化，本次结果未应用") }
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.message("NAS 响应格式无效")
        }
        if http.statusCode == 404 { throw SyncError.message("NAS 未开放独立三通道接口（404）；请更新 NAS 服务或检查代理路径。本机功能仍可使用，未改动真实资产。") }
        if http.statusCode == 401 { throw SyncError.message("NAS 口令不匹配（401），请核对设置") }
        guard let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw SyncError.message("NAS 返回的不是同步 JSON（HTTP \(http.statusCode)），请检查地址是否指向网页或代理错误页")
        }
        guard http.statusCode == 200, result["ok"] as? Bool == true else {
            throw SyncError.message(http.statusCode == 409 ? "版本冲突，已暂停覆盖" : "NAS 未提供 v2 通道或请求失败（\(http.statusCode)）")
        }
        return result
    }
    private func legacyResearch() async throws -> [String: Any] {
        let base = researchBase
        let root = try NASSyncService.normalizedBaseURL(base)
        let endpoint = root.appendingPathComponent("v1/mobile/research")
        var req = URLRequest(url: endpoint); req.timeoutInterval = 30
        if let token = researchToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        guard base == researchBase else { throw SyncError.message("NAS 研究地址已变化，本次结果未应用") }
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 16 * 1024 * 1024,
              let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              result["ok"] as? Bool == true,
              let data = result["data"] as? [String: Any],
              let quality = data["quality"] as? [String: Any],
              quality["researchSnapshot"] is [String: Any] else {
            throw SyncError.message("旧 NAS 未提供有效的只读研究档案")
        }
        return data
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if activeResearchBase != researchBase {
            activeResearchBase = researchBase
            marketDocument = nil; executorInfo = [:]; opportunityScan = [:]
        }
        // Independent failures: a failed market request never blocks the quant channel.
        market.text = "检查行情通道…"; market.progress = 0.1
        var usedLegacyResearch = false
        do {
            let remote = try await request("market")
            marketDocument = remote["data"] as? [String: Any]
            if let marketDocument, let bytes = try? JSONSerialization.data(withJSONObject: ["sourceBase": activeResearchBase, "data": marketDocument]) {
                try? FileManager.default.createDirectory(at: marketCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: marketCacheURL, options: [.atomic])
            }
            market.revision = remote["revision"] as? Int ?? 0; market.progress = 1
            market.text = marketDocument == nil ? "已连接 · NAS 行情通道尚无数据" : "已读取独立行情通道"
        } catch {
            if let syncError = error as? SyncError,
               case .message(let detail) = syncError,
               detail.contains("(404)") {
                do {
                    marketDocument = try await legacyResearch()
                    if let marketDocument, let bytes = try? JSONSerialization.data(withJSONObject: ["sourceBase": activeResearchBase, "data": marketDocument]) {
                        try? FileManager.default.createDirectory(at: marketCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? bytes.write(to: marketCacheURL, options: [.atomic])
                    }
                    market.progress = 1
                    market.text = "已读取旧 NAS 的只读历史档案；成交量单位待核验"
                    usedLegacyResearch = true
                } catch { market.text = "离线/失败 · \(error.localizedDescription)"; market.progress = 0 }
            } else { market.text = "离线/失败 · \(error.localizedDescription)"; market.progress = 0 }
        }
        if usedLegacyResearch {
            executorInfo = [:]; opportunityScan = [:]
            quant.progress = 0; quant.text = "旧 NAS 无独立机会筛查；手机规则继续判断"
            return
        }
        quant.text = "检查量化通道…"; quant.progress = 0.1
        do {
            let endpointBefore = try url("quant").absoluteString
            let remote = try await request("quant")
            guard endpointBefore == (try url("quant").absoluteString) else { throw SyncError.message("NAS 地址已变化，本次结果未应用") }
            let revision = remote["revision"] as? Int ?? 0
            let remoteEnvelope = remote["data"] as? [String: Any]
            executorInfo = remoteEnvelope?["executor"] as? [String: Any] ?? [:]
            opportunityScan = remoteEnvelope?["opportunityScan"] as? [String: Any] ?? [:]
            quant.revision = revision; quant.progress = 1
            quant.text = opportunityScan.isEmpty ? "已读取 · NAS 尚无机会扫描" : "已读取 NAS 研究筛查结果"
        } catch { quant.text = "暂停/离线 · \(error.localizedDescription)"; quant.progress = 0 }
    }
    func assetEndpoint() throws -> String { try url("assets").absoluteString }
    func researchPage(offset: Int, at: Int64) async throws -> [String: Any] {
        let base = researchBase
        let root = try NASSyncService.normalizedBaseURL(base)
        var components = URLComponents(url: root.appendingPathComponent("api/v2/market/research-page"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "at", value: String(at))]
        guard let endpoint = components.url else { throw SyncError.message("NAS 地址无效") }
        var req = URLRequest(url: endpoint); req.timeoutInterval = 30
        if let token = researchToken, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        guard root == (try NASSyncService.normalizedBaseURL(researchBase)) else { throw SyncError.message("NAS 地址已变化，扫描已停止") }
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 16 * 1024 * 1024,
              let page = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], page["ok"] as? Bool == true else {
            throw SyncError.message("NAS 未提供证券池研究接口或响应无效；可先导入离线研究文件")
        }
        return page
    }
    func assetRequest(body: [String: Any]? = nil, expectedEndpoint: String? = nil) async throws -> [String: Any] {
        assets.text = "用户手动操作中…"; assets.progress = 0.2
        do {
            if let expectedEndpoint, expectedEndpoint != (try assetEndpoint()) { throw SyncError.message("NAS 地址已变化，请重新预览资产") }
            let result = try await request("assets", body: body)
            assets.revision = result["revision"] as? Int ?? 0
            assets.progress = 1; assets.text = body == nil ? "已读取真实资产预览" : "真实资产副本已上传"
            return result
        } catch { assets.text = "已暂停 · \(error.localizedDescription)"; assets.progress = 0; throw error }
    }
}
