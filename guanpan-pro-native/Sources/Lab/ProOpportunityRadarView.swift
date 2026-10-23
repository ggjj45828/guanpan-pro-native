import SwiftUI
import UniformTypeIdentifiers

struct ProOpportunityRadarView: View {
    @EnvironmentObject private var channels: LabChannelCoordinator
    @EnvironmentObject private var researchEngine: PhoneResearchEngine
    @State private var rows: [String: RadarItem] = [:]
    @State private var coverage = "尚未配置证券池"
    @State private var error = ""
    @State private var sourceVersion: Int64?
    @State private var busy = false
    @State private var importing = false
    @State private var scan: Task<Void, Never>?
    private var file: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GuanpanResearch/radar-v1.json") }
    private var ranked: [RadarItem] { rows.values.sorted { ($0.score ?? -1) > ($1.score ?? -1) } }
    var body: some View {
        ProPage(title: "机会雷达", subtitle: "证券池独立于持仓，覆盖范围如实显示") {
            VStack(alignment: .leading, spacing: 14) {
                Label(coverage, systemImage: "scope").font(.subheadline)
                Text("已研究 \(rows.count) 只 · 得分是规则研究结果，不代表盈利概率或买入指令。")
                    .font(.caption).foregroundStyle(.secondary)
                if busy {
                    ProgressView("分批读取与研究…")
                    Button("停止扫描") { scan?.cancel() }
                } else { Button("扫描 NAS 已配置证券池") { scan = Task { await load() } }.buttonStyle(.borderedProminent) }
                Button("导入离线研究文件") { importing = true }.disabled(busy)
            }.proSurface(tone: .teal)
            if !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(.red) }
            if rows.isEmpty { ProEmpty(title: "没有数据，也不编造机会", detail: "可由 NAS 接入合法行情，或导入离线工具输出的研究文件。缺失基本面会保留为数据不足。", icon: "text.magnifyingglass") }
            ForEach(ranked) { row in
                DisclosureGroup {
                    Text("来源：" + row.source).font(.caption).textSelection(.enabled)
                    Text(row.evidence.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let at = row.quoteAt { Text("报价时间 " + Date(timeIntervalSince1970: Double(at) / 1000).formatted()).font(.caption).foregroundStyle(.secondary) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.symbol).font(.headline.monospaced()).foregroundStyle(.primary)
                            Text(row.trap ? "有红利陷阱信号，需复核" : row.score == nil ? "因子证据不足" : "研究评分").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.score.map { ($0 * 100).num(0) } ?? "—").font(.title2.monospacedDigit()).foregroundStyle(.primary)
                    }
                }
                Divider()
            }
            Text("缓存与离线文件不是实时行情；请核对每条报价时间。此页不创建交易订单。").font(.caption).foregroundStyle(.secondary)
        }
        .task { restore() }
        .onDisappear { scan?.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else { throw PhoneResearchEngine.EngineError.message("文件超过 16 MB，请分批导入") }
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
                let data = (object["page"] as? [String: Any])?["research"] as? [String: Any] ?? object
                try evaluate(data, replace: true)
                coverage = "离线文件 · 仅覆盖文件中的证券"; persist()
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func load() async {
        guard !busy else { return }; busy = true; error = ""; defer { busy = false }
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        var offset = 0; var seen = Set<Int>(); var started = false
        do {
            repeat {
                try Task.checkCancellation()
                guard seen.insert(offset).inserted else { throw PhoneResearchEngine.EngineError.message("NAS 分页重复，扫描已停止") }
                let page = try await channels.researchPage(offset: offset, at: at)
                let c = page["coverage"] as? [String: Any] ?? [:]
                let version = (c["asOf"] as? NSNumber)?.int64Value
                if started && version != sourceVersion { throw PhoneResearchEngine.EngineError.message("证券池已变化，请重新扫描") }
                guard let data = page["research"] as? [String: Any] else { throw PhoneResearchEngine.EngineError.message("证券研究数据缺失") }
                if (c["registered"] as? Int ?? 0) == 0 { throw PhoneResearchEngine.EngineError.message("NAS 尚未配置证券池，已保留本机结果；可先导入离线文件") }
                try evaluate(data, replace: !started)
                if !started { sourceVersion = version; started = true }
                coverage = "提供方：\(c["source"] as? String ?? "未配置") · 清单 \(c["registered"] as? Int ?? 0) 只 · 新鲜报价 \(c["freshQuotes"] as? Int ?? 0) 只"
                persist()
                guard let next = page["nextOffset"] as? Int else { break }
                guard next > offset, seen.count < 400 else { throw PhoneResearchEngine.EngineError.message("分页范围无效，扫描已停止") }
                offset = next
            } while !Task.isCancelled
        } catch is CancellationError { error = "已停止；已读取结果仍可查看。" }
        catch { self.error = error.localizedDescription }
    }
    private func evaluate(_ data: [String: Any], replace: Bool = false) throws {
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        guard let result = try researchEngine.call("research.radar", [data, at]) as? [String: Any] else { throw PhoneResearchEngine.EngineError.message("研究结果无效") }
        var next: [String: RadarItem] = replace ? [:] : rows
        for row in result["ranked"] as? [[String: Any]] ?? [] {
            guard let symbol = row["symbol"] as? String else { continue }
            next[symbol] = RadarItem(symbol: symbol, score: (row["score"] as? NSNumber)?.doubleValue, trap: row["trap"] as? Bool ?? false, source: row["source"] as? String ?? "未知", quoteAt: (row["quoteAt"] as? NSNumber)?.int64Value, evidence: row["evidenceIDs"] as? [String] ?? [])
        }
        rows = next
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(rows.values)).write(to: file, options: .atomic)
        } catch { self.error = "结果未保存：\(error.localizedDescription)" }
    }
    private func restore() {
        guard rows.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let values = try JSONDecoder().decode([RadarItem].self, from: Data(contentsOf: file))
            for value in values { rows[value.symbol] = value }; coverage = "本机研究缓存 · 请核对报价时间"
        } catch { self.error = "研究缓存读取失败，原文件未覆盖" }
    }
    private struct RadarItem: Codable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let score: Double?
        let trap: Bool
        let source: String
        let quoteAt: Int64?
        let evidence: [String]
    }
}
