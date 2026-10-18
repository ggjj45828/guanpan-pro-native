import Foundation
import Combine

/// v2 channel client. No writes or downloads are applied to the real PortfolioStore.
@MainActor
final class LabChannelCoordinator: ObservableObject {
    struct Status {
        var text: String
        var progress: Double = 0
        var revision: Int = 0
    }
    @Published private(set) var assets = Status(text: "默认手动 · 待用户操作")
    @Published private(set) var market = Status(text: "自动 · 未连接")
    @Published private(set) var quant = Status(text: "自动 · 未连接")
    private var busy = false
    private let baselineKey = "guanpan.lab.quant.baseline.v2"
    private let endpointKey = "guanpan.lab.quant.endpoint.v2"
    @Published private(set) var marketDocument: [String: Any]?
    private var marketCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("guanpan-v2-market-cache.json")
    }
    init() {
        if let bytes = try? Data(contentsOf: marketCacheURL) {
            marketDocument = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
    }

    private func url(_ channel: String) throws -> URL {
        let base = UserDefaults.standard.string(forKey: NASSyncService.urlKey) ?? ""
        guard var components = URLComponents(string: base), ["http", "https"].contains(components.scheme ?? ""),
              components.host != nil, components.user == nil, components.password == nil else {
            throw InvestmentLabStore.LabError.message("请先在原设置中配置 NAS 地址")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, "api/v2/channels/\(channel)"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil; components.fragment = nil
        guard let result = components.url else { throw InvestmentLabStore.LabError.message("NAS 地址无效") }
        return result
    }
    private func request(_ channel: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: try url(channel)); req.timeoutInterval = 15
        if let token = NASCredentialStore.load(), !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw InvestmentLabStore.LabError.message("NAS 响应格式无效")
        }
        guard http.statusCode == 200, result["ok"] as? Bool == true else {
            throw InvestmentLabStore.LabError.message(http.statusCode == 409 ? "版本冲突，已暂停覆盖" : "NAS 未提供 v2 通道或请求失败（\(http.statusCode)）")
        }
        return result
    }
    func refresh(lab: InvestmentLabStore) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        // Independent failures: a failed market request never blocks the quant channel.
        market.text = "检查行情通道…"; market.progress = 0.1
        do {
            let remote = try await request("market")
            marketDocument = remote["data"] as? [String: Any]
            if let marketDocument, let bytes = try? JSONSerialization.data(withJSONObject: marketDocument) {
                try? FileManager.default.createDirectory(at: marketCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: marketCacheURL, options: [.atomic])
            }
            market.revision = remote["revision"] as? Int ?? 0; market.progress = 1
            market.text = marketDocument == nil ? "已连接 · NAS 行情通道尚无数据" : "已读取独立行情通道"
        } catch { market.text = "离线/失败 · \(error.localizedDescription)"; market.progress = 0 }
        quant.text = "检查量化通道…"; quant.progress = 0.1
        do {
            let localBefore = lab.state
            let beforeHash = try localBefore.map { try lab.digest($0) }
            let endpointBefore = try url("quant").absoluteString
            let remote = try await request("quant")
            guard endpointBefore == (try url("quant").absoluteString) else { throw InvestmentLabStore.LabError.message("NAS 地址已变化，本次结果未应用") }
            let latestHash = try lab.state.map { try lab.digest($0) }
            guard latestHash == beforeHash else { throw InvestmentLabStore.LabError.message("本机实验已变化，下次重试") }
            let revision = remote["revision"] as? Int ?? 0
            quant.revision = revision; quant.progress = 0.5
            let remoteEnvelope = remote["data"] as? [String: Any]
            let remoteLab = remoteEnvelope?["lab"] as? [String: Any]
            if remoteEnvelope?["lab"] != nil && remoteLab == nil {
                throw InvestmentLabStore.LabError.message("NAS 实验格式无效，已停止覆盖")
            }
            if let remoteLab, let localBefore, remoteLab["id"] as? String != localBefore["id"] as? String {
                throw InvestmentLabStore.LabError.message("两端是不同实验，已暂停；不会替换已有实验起点")
            }
            func payload(_ lab: [String: Any]) -> [String: Any] {
                var merged = remoteEnvelope ?? [:]
                merged["lab"] = lab
                return merged
            }
            let remoteHash = try remoteLab.map { try lab.digest($0) }
            let defaults = UserDefaults.standard
            let baseline = defaults.string(forKey: endpointKey) == endpointBefore ? defaults.string(forKey: baselineKey) : nil
            if beforeHash == remoteHash {
                quant.text = "量化账户内容一致"; quant.progress = 1
            } else if remoteLab == nil, let localBefore {
                let result = try await request("quant", body: ["schemaVersion": 2, "expectedRevision": revision,
                    "requestID": UUID().uuidString, "data": payload(localBefore)])
                quant.revision = result["revision"] as? Int ?? revision; quant.text = "独立虚拟账本已上传"; quant.progress = 1
            } else if let remoteLab, (localBefore == nil || beforeHash == baseline) {
                try lab.acceptRemote(remoteLab); quant.text = "已接收独立实验账本"; quant.progress = 1
            } else if remoteHash == baseline, let localBefore {
                let result = try await request("quant", body: ["schemaVersion": 2, "expectedRevision": revision,
                    "requestID": UUID().uuidString, "data": payload(localBefore)])
                quant.revision = result["revision"] as? Int ?? revision; quant.text = "本机实验变更已上传"; quant.progress = 1
            } else { throw InvestmentLabStore.LabError.message("两端实验不一致，保留两端数据；请先导出再选择") }
            // Baseline must describe exactly the version sent/received, not edits during await.
            let syncedHash = remoteLab != nil && (localBefore == nil || beforeHash == baseline) && beforeHash != remoteHash ? remoteHash : beforeHash
            if let syncedHash { defaults.set(syncedHash, forKey: baselineKey); defaults.set(endpointBefore, forKey: endpointKey) }
        } catch { quant.text = "暂停/离线 · \(error.localizedDescription)"; quant.progress = 0 }
    }
    func assetRequest(body: [String: Any]? = nil) async throws -> [String: Any] {
        assets.text = "用户手动操作中…"; assets.progress = 0.2
        do {
            let result = try await request("assets", body: body)
            assets.revision = result["revision"] as? Int ?? 0
            assets.progress = 1; assets.text = body == nil ? "已读取真实资产预览" : "真实资产副本已上传"
            return result
        } catch { assets.text = "已暂停 · \(error.localizedDescription)"; assets.progress = 0; throw error }
    }
}
