import CryptoKit
import Foundation

// MARK: - 任意 JSON 值
//
// 研究证据的 `evidence` 字段是一棵自由结构的树（每种研究类型的统计字段不同），
// 用固定 struct 接不住，又不能用 `[String: Any]`（不是 Codable，无法参与摘要校验）。

indirect enum ResearchJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ResearchJSONValue])
    case object([String: ResearchJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ResearchJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ResearchJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: ResearchJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - 证据信封

struct ResearchDateRange: Codable, Equatable {
    let start: String
    let end: String
}

struct ResearchSourceTrust {
    /// 目前只有观盘 NAS 归档的两条公开接口被核对过来源与覆盖度。
    static let tencentMinute = "腾讯财经 minute/query（公开网页接口）"
    static let eastmoneyMinute = "东方财富 push2his 1 分钟 K 线（公开网页接口）"
    static let trustedSources: Set<String> = [tencentMinute, eastmoneyMinute]

    static func isTrusted(_ source: String) -> Bool {
        trustedSources.contains(source.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ResearchEvidenceError: Error, Equatable {
    case invalidSchema
    case invalidTimeline
    case untrustedSource
    case qualityBelowGate
    case insufficientSamples
    case forbiddenPayload
    case digestMismatch
    case staleEvidence
}

/// NAS 研究证据。客户端**不能**因为有这段文本就采信 —— 必须先过门槛。
///
/// 移植原则与观盘F 一致：这里只接收压缩后的统计量，明确拒绝原始分钟线与可执行交易计划。
/// 让它进来是为了给「这只票适不适合做网格 / 做 T」提供样本量化的背景，
/// 不是为了把 NAS 的结论照搬成 App 的结论。
struct ResearchEvidenceEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let methodologyVersion: String
    let evidenceId: String
    let securityCode: String
    let market: String
    let range: ResearchDateRange
    /// 真正通过归档质量门槛的交易日区间（与请求区间可能不同）。
    let dataRange: ResearchDateRange?
    let strategyVersion: String?
    let asOf: String
    let generatedAt: String
    let timezone: String?
    let sessionCoverage: [String: Int]
    let qualifiedIndependentDays: Int
    let minimumQuality: Int
    let sources: [String]
    let evidence: [String: ResearchJSONValue]
    let limitations: [String]
    let rawMinuteBarsIncluded: Bool
    let tradePlan: ResearchJSONValue

    /// 允许出现在 `evidence` 里的研究类型。白名单而不是黑名单 ——
    /// 黑名单永远漏，白名单不会。
    static let allowedFamilies: Set<String> = ["vwapBreak", "morningRecovery", "gridSpacingReplay", "dividendQuality"]

    /// 可用门槛：质量分 >= 90、独立交易日 >= 25。
    ///
    /// 25 个独立交易日是「至少一个月的样本」，低于这个数的胜率基本是噪音。
    static let minimumQualityGate = 90
    static let minimumIndependentDays = 25
    /// 证据最大年龄：7 天。
    static let maximumAge: TimeInterval = 7 * 86_400

    var observedAt: Date { Self.parseTimestamp(asOf) ?? .distantPast }
    var generatedAtDate: Date { Self.parseTimestamp(generatedAt) ?? .distantPast }

    func validate(capturedAt: Date, contextCreatedAt: Date) throws {
        guard schemaVersion == 2, methodologyVersion == "minute-research-2" else {
            throw ResearchEvidenceError.invalidSchema
        }
        guard !securityCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = Self.parseDay(range.start), let end = Self.parseDay(range.end), start <= end else {
            throw ResearchEvidenceError.invalidSchema
        }
        if let dataRange {
            guard let dataStart = Self.parseDay(dataRange.start),
                  let dataEnd = Self.parseDay(dataRange.end),
                  start <= dataStart, dataStart <= dataEnd, dataEnd <= end else {
                throw ResearchEvidenceError.invalidSchema
            }
        }
        guard let asOfDate = Self.parseTimestamp(asOf),
              let generatedDate = Self.parseTimestamp(generatedAt),
              generatedDate >= asOfDate,
              asOfDate <= contextCreatedAt,
              generatedDate <= capturedAt,
              capturedAt <= contextCreatedAt else {
            throw ResearchEvidenceError.invalidTimeline
        }
        if qualifiedIndependentDays > 0 {
            guard !sources.isEmpty, sources.allSatisfy(ResearchSourceTrust.isTrusted) else {
                throw ResearchEvidenceError.untrustedSource
            }
            guard dataRange != nil, timezone != nil,
                  let zone = timezone, TimeZone(identifier: zone) != nil else {
                throw ResearchEvidenceError.invalidSchema
            }
            guard qualifiedIndependentDays <= (sessionCoverage["complete"] ?? 0) else {
                throw ResearchEvidenceError.invalidSchema
            }
        }
        guard qualifiedIndependentDays >= 0, minimumQuality >= 0, minimumQuality <= 100 else {
            throw ResearchEvidenceError.invalidSchema
        }
        guard rawMinuteBarsIncluded == false, tradePlan.isNull else {
            throw ResearchEvidenceError.forbiddenPayload
        }
        guard !evidence.isEmpty,
              Set(evidence.keys).isSubset(of: Self.allowedFamilies) else {
            throw ResearchEvidenceError.invalidSchema
        }
        guard !Self.containsForbiddenPayload(.object(evidence)) else {
            throw ResearchEvidenceError.forbiddenPayload
        }
        guard sessionCoverage.values.allSatisfy({ $0 >= 0 }) else {
            throw ResearchEvidenceError.invalidSchema
        }
        let bytes = (try? JSONEncoder().encode(evidence))?.count ?? 0
        guard bytes <= 32_768 else { throw ResearchEvidenceError.invalidSchema }
        guard (try calculatedContentDigest()) == evidenceId else {
            throw ResearchEvidenceError.digestMismatch
        }
    }

    /// 能不能进 AI 上下文。任何一条不满足就整段不出现 ——
    /// 不给模型「一份不太可信但看起来很像数据的东西」。
    func isUsableForAI(capturedAt: Date, contextCreatedAt: Date, now: Date) -> Bool {
        guard minimumQuality >= Self.minimumQualityGate,
              qualifiedIndependentDays >= Self.minimumIndependentDays,
              (try? validate(capturedAt: capturedAt, contextCreatedAt: contextCreatedAt)) != nil,
              now >= capturedAt,
              now.timeIntervalSince(observedAt) <= Self.maximumAge else { return false }
        return true
    }

    var compactSummary: String {
        "\(market)/\(securityCode) · 独立交易日 \(qualifiedIndependentDays) · 质量 \(minimumQuality) · 来源 \(sources.joined(separator: "、"))"
    }

    // MARK: 摘要

    func calculatedContentDigest() throws -> String {
        guard let asOfDate = Self.parseTimestamp(asOf),
              let generatedDate = Self.parseTimestamp(generatedAt) else {
            throw ResearchEvidenceError.invalidTimeline
        }
        let stable: [String: ResearchJSONValue] = [
            "schemaVersion": .number(Double(schemaVersion)),
            "methodologyVersion": .string(methodologyVersion),
            "securityCode": .string(securityCode),
            "market": .string(market),
            "startDate": .string(range.start),
            "endDate": .string(range.end),
            "dataRange": dataRange.map { .object(["start": .string($0.start), "end": .string($0.end)]) } ?? .null,
            "strategyVersion": strategyVersion.map { .string($0) } ?? .null,
            "asOfEpochMillis": .number(Double(asOfDate.millisecondsSince1970)),
            "generatedAtEpochMillis": .number(Double(generatedDate.millisecondsSince1970)),
            "timezone": timezone.map { .string($0) } ?? .null,
            "sessionCoverage": .object(sessionCoverage.mapValues { .number(Double($0)) }),
            "qualifiedIndependentDays": .number(Double(qualifiedIndependentDays)),
            "minimumQuality": .number(Double(minimumQuality)),
            "sources": .array(sources.map { .string($0) }),
            "evidence": .object(evidence),
            "limitations": .array(limitations.map { .string($0) }),
            "rawMinuteBarsIncluded": .bool(rawMinuteBarsIncluded),
            "tradePlan": tradePlan
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ResearchJSONValue.object(stable))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 工具

    /// 拒绝任何形似「可执行计划」或「原始行情」的键。
    private static func containsForbiddenPayload(_ value: ResearchJSONValue) -> Bool {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let lowered = key.lowercased()
                if lowered.contains("order") || lowered.contains("tradeplan")
                    || lowered.contains("targetposition") || lowered.contains("rawbars")
                    || lowered.contains("minutebar") && !lowered.contains("count") {
                    return true
                }
                if containsForbiddenPayload(child) { return true }
            }
            return false
        case .array(let items):
            return items.contains { containsForbiddenPayload($0) }
        default:
            return false
        }
    }

    private static func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func parseTimestamp(_ value: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let parsed = formatter.date(from: value) { return parsed }
        }
        return nil
    }
}

private extension Date {
    var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero))
    }
}

// MARK: - 抓取

extension FNASBridge {
    /// 拉一只标的的研究证据。
    ///
    /// NAS 没实现这个接口时返回 nil —— 不报错、不阻塞、不编造。
    /// 现在（服务端还没有 research 路由）它基本总是 nil，但协议层先就位：
    /// 等 NAS 端补上 `/v1/research/evidence`，这里不用改。
    static func researchEvidence(code: String) async -> ResearchEvidenceEnvelope? {
        guard let base = normalizedBase,
              let url = URL(string: base + "/v1/research/evidence?code=" + code) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ResearchEvidenceEnvelope.self, from: data)
    }
}
