import Foundation
import JavaScriptCore
import Combine
import CryptoKit

/// Runs the local evidence rules without loading or persisting any strategy account.
@MainActor
final class PhoneResearchEngine: ObservableObject {
    enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private let context = JSContext()!
    private var loadError: String?

    init() {
        for name in ["LabCore", "LabResearch", "AssetChannel"] {
            guard let resource = Bundle.main.url(forResource: name, withExtension: "js"),
                  let script = try? String(contentsOf: resource, encoding: .utf8) else {
                loadError = "本机研究规则缺少资源：\(name)"
                return
            }
            context.evaluateScript(script)
            if let exception = context.exception {
                loadError = "本机研究规则加载失败：\(exception.toString())"
                return
            }
        }
    }

    func call(_ method: String, _ args: [Any]) throws -> Any {
        if let loadError { throw EngineError.message(loadError) }
        context.exception = nil
        let name = method.hasPrefix("research.") ? "labResearchCall" :
            method.hasPrefix("assets.") ? "labAssetsCall" : "labCall"
        let verb = String(method.split(separator: ".").last ?? Substring(method))
        let request = try JSONSerialization.data(withJSONObject: ["method": verb, "args": args], options: [.sortedKeys])
        guard let function = context.objectForKeyedSubscript(name), !function.isUndefined,
              let response = function.call(withArguments: [String(decoding: request, as: UTF8.self)])?.toString(),
              let bytes = response.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw EngineError.message("本机研究引擎调用失败")
        }
        guard result["ok"] as? Bool == true else {
            throw EngineError.message(result["error"] as? String ?? "本机研究计算失败")
        }
        return result["value"] ?? NSNull()
    }

    static func units(_ yuan: Double, allowNegative: Bool = false) throws -> Int64 {
        guard yuan.isFinite, (allowNegative || yuan >= 0), abs(yuan) < 900_000_000 else {
            throw EngineError.message("金额或价格超出范围")
        }
        return Int64((yuan * 10_000).rounded())
    }

    static func yuan(_ value: Any?) -> String {
        let number = (value as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.2f", number / 10_000)
    }

    func digest(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
