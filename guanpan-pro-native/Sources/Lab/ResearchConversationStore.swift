import Foundation
import Combine

@MainActor
final class ResearchConversationStore: ObservableObject {
    @Published private(set) var histories: [String: [String]] = [:]
    @Published private(set) var errorMessage = ""
    private let file: URL
    private var writable = true

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuanpanResearch/conversations-v1.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                histories = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: self.file))
            }
        } catch {
            writable = false
            errorMessage = "对话记录读取失败，已保留原文件并停止覆盖：\(error.localizedDescription)"
        }
    }

    func append(_ text: String, scope: String) {
        guard writable else { return }
        guard !scope.isEmpty, text.count <= 100_000 else { errorMessage = "对话过长，未保存；请先导出或缩短本轮内容"; return }
        do {
            var next = histories
            if FileManager.default.fileExists(atPath: file.path) {
                next = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: file))
            }
            next[scope] = Array(((next[scope] ?? []) + [text]).suffix(200))
            let bytes = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            histories = next
        } catch { errorMessage = "对话未保存：\(error.localizedDescription)" }
    }
}
