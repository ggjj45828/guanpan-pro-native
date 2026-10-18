import SwiftUI

struct ManualAssetChannelView: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var lab: InvestmentLabStore
    @EnvironmentObject private var channels: LabChannelCoordinator
    @State private var preview: [String: Any]?
    @State private var localHash = ""
    @State private var previewEndpoint = ""
    @State private var message = "真实资产仅手动操作，首次同步不会自动覆盖任何一端。"
    @State private var showUpload = false
    @State private var showApply = false
    var body: some View {
        List {
            Section("真实资产独立通道") {
                Text(message).font(.footnote)
                Button("读取 NAS 真实资产预览") { Task { await read() } }
                Button("上传当前真实资产副本") { showUpload = true }
                if let preview {
                    Text("NAS 版本 \(preview["revision"] as? Int ?? 0)")
                    if let data = preview["data"] as? [String: Any] {
                        Text("持仓 \((data["holdings"] as? [Any] ?? []).count) 项 · 现金 ¥\(InvestmentLabStore.yuan(data["cash"]))")
                        Button("备份本机后，应用此 NAS 版本") { showApply = true }
                    }
                }
                Text("不接收行情、策略或模拟交易。NAS 地址、任一端数据或预览版本变化时暂停。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(.clear).navigationTitle("真实资产 · 手动同步")
        .confirmationDialog("将当前真实资产上传到 NAS？先读取版本，版本冲突则停止。", isPresented: $showUpload, titleVisibility: .visible) {
            Button("确认上传真实资产副本") { Task { await upload() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("用已预览版本更新本机真实持仓、成本、现金和场内流水？应用前会保留完整本机备份。", isPresented: $showApply, titleVisibility: .visible) {
            Button("确认备份并应用") { Task { await apply() } }
            Button("取消", role: .cancel) {}
        }
    }
    private func native() throws -> [String: Any] {
        let bytes = try JSONEncoder().encode(portfolio.data)
        return try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
    }
    private func project(_ at: Int64 = 0) throws -> [String: Any] {
        guard let result = try lab.call("assets.project", [try native(), at]) as? [String: Any] else {
            throw InvestmentLabStore.LabError.message("真实资产编码失败")
        }
        return result
    }
    private func read() async {
        do {
            let endpoint = try channels.assetEndpoint()
            let stamp = try lab.digest(project())
            let remote = try await channels.assetRequest(expectedEndpoint: endpoint)
            guard stamp == (try lab.digest(project())) else { throw InvestmentLabStore.LabError.message("本机真实资产已变化，请重新预览") }
            preview = remote; localHash = stamp; previewEndpoint = endpoint; message = "已读取预览，尚未应用"
        } catch { message = error.localizedDescription }
    }
    private func upload() async {
        do {
            let endpoint = try channels.assetEndpoint()
            let data = try project(Int64(Date().timeIntervalSince1970 * 1000))
            let fingerprint = try lab.digest(project())
            let before = try await channels.assetRequest(expectedEndpoint: endpoint)
            guard fingerprint == (try lab.digest(project())) else { throw InvestmentLabStore.LabError.message("读取期间本机已变化，请重新操作") }
            let revision = before["revision"] as? Int ?? 0
            _ = try await channels.assetRequest(body: ["schemaVersion": 2, "expectedRevision": revision,
                "requestID": UUID().uuidString, "intent": "manual", "data": data], expectedEndpoint: endpoint)
            message = "真实资产副本已上传；模拟通道未参与"; preview = nil
        } catch { message = error.localizedDescription }
    }
    private func apply() async {
        do {
            guard let preview, let data = preview["data"] as? [String: Any] else { return }
            let latest = try await channels.assetRequest(expectedEndpoint: previewEndpoint)
            guard latest["revision"] as? Int == preview["revision"] as? Int,
                  latest["digest"] as? String == preview["digest"] as? String,
                  localHash == (try lab.digest(project())) else { throw InvestmentLabStore.LabError.message("任一端已变化，请重新预览；没有覆盖") }
            let merged = try lab.call("assets.merge", [try native(), data])
            let bytes = try JSONSerialization.data(withJSONObject: merged)
            let value = try JSONDecoder().decode(PortfolioData.self, from: bytes)
            portfolio.data = value
            portfolio.save(label: "手动接收 v2 真实资产", propagate: false)
            self.preview = nil; message = "已按确认版本应用；本机账本已更新"
        } catch { message = error.localizedDescription }
    }
}
