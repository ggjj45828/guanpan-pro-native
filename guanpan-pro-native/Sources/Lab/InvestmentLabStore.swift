import Foundation
import JavaScriptCore
import CryptoKit
import Combine

/// A separate local vault. Never calls PortfolioStore.save/applyNASDocument.
@MainActor
final class InvestmentLabStore: ObservableObject {
    @Published private(set) var state: [String: Any]?
    @Published private(set) var message = "未创建独立实验账户"
    @Published private(set) var loadFailed = false
    private let context: JSContext
    private let directory: URL
    private let file: URL
    private var diskSignature: Data?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("GuanpanInvestmentLab-v2", isDirectory: true)
        file = directory.appendingPathComponent("lab-v2.json")
        context = JSContext()!
        do {
            for name in ["LabCore", "LabResearch", "AssetChannel"] {
                guard let resource = Bundle.main.url(forResource: name, withExtension: "js"),
                      let script = try? String(contentsOf: resource, encoding: .utf8) else {
                    throw LabError.message("核心资源缺失：\(name)")
                }
                context.evaluateScript(script)
                if let exception = context.exception { throw LabError.message(exception.toString()) }
            }
            if FileManager.default.fileExists(atPath: file.path) {
                let originalBytes = try Data(contentsOf: file)
                let value = try JSONSerialization.jsonObject(with: originalBytes)
                _ = try call("validate", [value])
                guard let loaded = value as? [String: Any] else { throw LabError.message("实验账本格式无效") }
                state = loaded; diskSignature = Data(SHA256.hash(data: originalBytes))
                message = "已恢复本机独立实验账户"
            }
        } catch { loadFailed = true; message = "读取失败，已保留原文件：\(error.localizedDescription)" }
    }

    enum LabError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    func call(_ method: String, _ args: [Any]) throws -> Any {
        context.exception = nil
        let name = method.hasPrefix("research.") ? "labResearchCall" : method.hasPrefix("assets.") ? "labAssetsCall" : "labCall"
        let verb = String(method.split(separator: ".").last ?? Substring(method))
        let request = try JSONSerialization.data(withJSONObject: ["method": verb, "args": args], options: [.sortedKeys])
        guard let fn = context.objectForKeyedSubscript(name), !fn.isUndefined,
              let response = fn.call(withArguments: [String(decoding: request, as: UTF8.self)])?.toString(),
              let bytes = response.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw LabError.message("实验核心调用失败")
        }
        guard result["ok"] as? Bool == true else {
            throw LabError.message(result["error"] as? String ?? "实验计算失败")
        }
        return result["value"] ?? NSNull()
    }

    /// Persist first, publish second. A failed write leaves the in-memory state unchanged.
    private func commit(_ next: [String: Any]) throws {
        guard !loadFailed else { throw LabError.message("请先导出并修复损坏的实验文件；禁止覆盖") }
        _ = try call("validate", [next])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        if FileManager.default.fileExists(atPath: file.path) {
            let currentBytes = try Data(contentsOf: file)
            guard Data(SHA256.hash(data: currentBytes)) == diskSignature else {
                throw LabError.message("实验文件已被其他页面更新；请先导出当前副本并重新打开，禁止覆盖")
            }
            let backup = directory.appendingPathComponent("before-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        diskSignature = Data(SHA256.hash(data: data)); state = next
    }

    func create(snapshot: [String: Any]) {
        perform {
            guard state == nil else { throw LabError.message("已有实验不会被真实持仓覆盖；请使用现有账户") }
            guard let next = try call("create", [snapshot, UUID().uuidString, SimulationCostPolicy.json]) as? [String: Any] else {
                throw LabError.message("无法创建实验")
            }
            try commit(next); message = "已创建 A–G 七个独立虚拟账户；自动模拟须显式开启"
        }
    }

    @discardableResult func action(_ action: [String: Any]) -> Bool {
        do {
            guard let current = state,
                  let next = try call("dispatch", [current, action]) as? [String: Any] else {
                throw LabError.message("请先创建实验")
            }
            try commit(next); message = "已写入独立虚拟账本"; return true
        } catch { message = error.localizedDescription; return false }
    }

    func acceptRemote(_ next: [String: Any]) throws { try commit(next) }
    func digest(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func perform(_ work: () throws -> Void) { do { try work() } catch { message = error.localizedDescription } }
    var accounts: [String: [String: Any]] { state?["accounts"] as? [String: [String: Any]] ?? [:] }
    var exportText: String {
        guard let state, let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return "未创建实验" }
        return String(decoding: data, as: UTF8.self)
    }
    static func units(_ yuan: Double, allowNegative: Bool = false) throws -> Int64 {
        guard yuan.isFinite, (allowNegative || yuan >= 0), abs(yuan) < 900_000_000 else { throw LabError.message("金额或价格超出范围") }
        return Int64((yuan * 10000).rounded())
    }
    static func yuan(_ value: Any?) -> String {
        let number = (value as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.2f", number / 10000)
    }
}
