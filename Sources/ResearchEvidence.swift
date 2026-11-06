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
    /// 服务端实际写进归档的 source 标识（f-minute-archive 的 provider.name）。
    ///
    /// 这里是**英文**，不是 UI 上那串中文说明。早期客户端照抄了中文文案做白名单，
    /// 结果是每一份证据都被判成「来源不可信」整份丢掉 —— 而且不报错，
    /// 看起来就像服务端没数据。两种写法都认，比较时忽略大小写与首尾空白。
    static let tencentMinute = "Tencent Finance minute/query (public web endpoint)"
    static let eastmoneyMinute = "Eastmoney push2his 1-minute kline (public web endpoint)"
    /// 旧版归档里可能存过的中文写法。
    static let tencentMinuteLegacy = "腾讯财经 minute/query（公开网页接口）"
    static let eastmoneyMinuteLegacy = "东方财富 push2his 1 分钟 K 线（公开网页接口）"

    static let trustedSources: Set<String> = [
        tencentMinute, eastmoneyMinute, tencentMinuteLegacy, eastmoneyMinuteLegacy
    ]

    static func isTrusted(_ source: String) -> Bool {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return trustedSources.contains { $0.lowercased() == normalized }
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

    /// 支持的契约版本。
    ///
    /// 现在 NAS 上实际跑的是 `minute-research-1`，而观盘F 客户端已经写成 v2 ——
    /// 两边对不上，证据一律被拒。所以这里同时认两版：
    /// v1 是既有部署，v2 是升级后的目标；按 `schemaVersion` 分支处理差异，
    /// 不靠"猜服务端是哪个版本"。
    static let supportedSchemas: [Int: String] = [1: "minute-research-1", 2: "minute-research-2"]

    var isSchemaSupported: Bool { Self.supportedSchemas[schemaVersion] == methodologyVersion }

    /// v2 才有的字段（dataRange / strategyVersion）。v1 的摘要是把它们排除在外的。
    var hasExtendedFields: Bool { schemaVersion >= 2 }

    /// 服务端与本机的时钟差容忍。
    ///
    /// `generatedAt` 由服务端盖章，`capturedAt` 是本机收到响应的时间。
    /// NAS 和 iPhone 不可能秒级同步，卡死「生成时间必须早于收到时间」会把
    /// 整份证据丢掉 —— 丢的不是数据，是两台机器的时钟差。
    static let clockSkewAllowance: TimeInterval = 300

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
        guard isSchemaSupported else { throw ResearchEvidenceError.invalidSchema }
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
              asOfDate <= contextCreatedAt.addingTimeInterval(Self.clockSkewAllowance),
              generatedDate <= capturedAt.addingTimeInterval(Self.clockSkewAllowance),
              capturedAt <= contextCreatedAt.addingTimeInterval(Self.clockSkewAllowance) else {
            throw ResearchEvidenceError.invalidTimeline
        }
        if qualifiedIndependentDays > 0 {
            guard !sources.isEmpty, sources.allSatisfy(ResearchSourceTrust.isTrusted) else {
                throw ResearchEvidenceError.untrustedSource
            }
            // v2 起要求写明「真正达标的交易日区间」；v1 没有这个字段，
            // 拿请求区间代指就是它当时的语义，不该因此整份拒收。
            if hasExtendedFields {
                guard dataRange != nil else { throw ResearchEvidenceError.invalidSchema }
            }
            guard timezone != nil,
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
        // 摘要的字段集合必须与服务端**那一版**完全一致，多一个键、少一个键都会算出不同的哈希。
        // v1 的 stable 里没有 dataRange / strategyVersion，所以这里按版本加键，
        // 不能一律带上再置 null —— 那会让 v1 的证据全部无法通过校验。
        var stable: [String: ResearchJSONValue] = [
            "schemaVersion": .number(Double(schemaVersion)),
            "methodologyVersion": .string(methodologyVersion),
            "securityCode": .string(securityCode),
            "market": .string(market),
            "startDate": .string(range.start),
            "endDate": .string(range.end),
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
        if hasExtendedFields {
            stable["dataRange"] = dataRange.map {
                ResearchJSONValue.object(["start": .string($0.start), "end": .string($0.end)])
            } ?? .null
            stable["strategyVersion"] = strategyVersion.map { ResearchJSONValue.string($0) } ?? .null
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ResearchJSONValue.object(stable))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 工具

    /// 拒绝任何形似「可执行计划」或「原始行情」的键。
    ///
    /// `tradePlan` 要分开看：服务端在每段证据里都写 `"tradePlan": null`，
    /// 那是**声明这一节没有交易计划**，正是我们想要的样子；
    /// 只有它真的带了内容才叫「服务端塞了计划进来」。
    private static func containsForbiddenPayload(_ value: ResearchJSONValue) -> Bool {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let lowered = key.lowercased()
                if lowered.contains("tradeplan") {
                    if !child.isNull { return true }
                    continue
                }
                if lowered.contains("order") || lowered.contains("targetposition")
                    || lowered.contains("rawbars")
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

// MARK: - 分钟归档服务

/// 这个服务上到底有没有 research 路由。
///
/// 归档服务的版本比客户端慢是常态（v1 部署配 v2 客户端就是活例子）。
/// 但「服务端没这个能力」不该变成「每次 AI 分析都去试一遍」：
/// 那会在 NAS 日志里堆满失败请求，还让每次分析多等一个超时。
/// 探测一次记 6 小时，到期再试 —— 服务端升级后最多半天就能自愈。
enum ResearchEvidenceProbe {
    private static let key = "guanpan.pro.research.evidence.unsupportedAt"
    private static let addressKey = "guanpan.pro.research.evidence.unsupportedAddress"
    private static let retryInterval: TimeInterval = 6 * 3600

    static var isSuppressed: Bool {
        let stamp = UserDefaults.standard.double(forKey: key)
        guard stamp > 0 else { return false }
        // 「旧地址不支持」不能套到新地址上。用户在设置里换了 NAS 之后，
        // 不该还要等 6 小时才重新探测 —— 直接比对当时记下的地址最省事，
        // 也不依赖界面记得调用 clear()。
        guard UserDefaults.standard.string(forKey: addressKey) == FMinuteArchive.baseURLString else {
            return false
        }
        return Date().timeIntervalSince1970 - stamp < retryInterval
    }

    static func markUnsupported() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        UserDefaults.standard.set(FMinuteArchive.baseURLString, forKey: addressKey)
    }

    /// 换了地址、或想手动重试时清掉。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 观盘max NAS 的旧入口。2.20.0 里它自己管地址和请求，
/// 2.21.0 起全部收敛到 `GuanpanMaxNAS` —— 一个服务、一份契约、一个地址。
/// 保留这个类型只是兼容既有调用点（AI 分析、设置页、抑制标记），不再有自己的实现。
enum FMinuteArchive {
    static var urlKey: String { GuanpanMaxNAS.urlKey }
    static var baseURLString: String { GuanpanMaxNAS.baseURLString }
    static var normalizedBase: String? { GuanpanMaxNAS.normalizedBase }
    static var isConfigured: Bool { GuanpanMaxNAS.isConfigured }

    static func save(_ address: String) { GuanpanMaxNAS.save(address) }
    static func normalizedSecurityCode(_ raw: String) -> String? {
        GuanpanMaxNAS.normalizedSecurityCode(raw)
    }
    static func probe() async throws -> String { try await GuanpanMaxNAS.probe() }
    static func researchEvidence(code: String,
                                 lookbackDays: Int = 120,
                                 now: Date = .now) async -> ResearchEvidenceEnvelope? {
        await GuanpanMaxNAS.researchEvidence(code: code, lookbackDays: lookbackDays, now: now)
    }
}
