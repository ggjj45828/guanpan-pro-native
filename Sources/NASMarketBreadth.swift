import Foundation
import Security

// MARK: - 观盘max NAS 全市场量能 / 广度
//
// NAS 侧存在两代对外契约，本文件同时支持，避免「换个部署包就整块失效」：
//
//   · 契约 v2（当前 F-NAS-DEPLOYMENT-2026-11-10-DEPLOYABLE）
//       顶层 `schemaVersion` + `market` 嵌套对象；`curvechao` 引擎已算好
//       市场阶段、操作倾向、风险等级、作者 A/B 条件、`closeConfirmed`。
//   · 契约 v1（早期独立 market-breadth 容器）
//       顶层 `apiVersion` + 平铺字段（turnover / upCount / amountCoverage…）。
//
// 两代都归一成同一个 `NASMarketSnapshot` 视图模型，界面层不必关心来源。
//
// 六条硬口径，少一条就会把错误数据端到界面上：
//   1. 版本只认 1。缺失或不等于 1 → 整段不展示，绝不硬解成半份数据。
//   2. 缺值是 JSON `null`，不是 0。0 表示「观测到 0 家」，未知表示「没拿到」，两者不能混。
//   3. `quoteTimestamp` 为 null 表示上游没给源报价时间；不得拿 `fetchedAt` 冒充行情源时间。
//   4. `status` / `freshness` / `quality` / `coverage` 都必须读。HTTP 200 不代表数据可用。
//   5. 金额单位是人民币元；界面换算成亿元只用于显示，不参与判定单位。
//   6. NAS 明确「两市成交额汇总口径」尚未接入时，`marketCommonAmount` 恒为 null；
//      绝不拿「沪深 A 股逐股合计」冒充官方两市成交额。
//
// 本工程自己的不变量：**盘中累计成交额不等于单日成交额**。所以「是否已收盘」一律
// 采信 NAS 的 `authorAddPosition.closeConfirmed`（NAS 有服务器时钟 + 10 分钟窗口 +
// 当日 + 样本量四重校验），iOS 不自己拿时间戳猜。

// MARK: - 令牌（Keychain）

/// 市场量能 API 的 Bearer 令牌。与 NAS 地址分开存：地址可以填错重填，
/// 令牌是密钥，只能进 Keychain，绝不写 UserDefaults、绝不拼进 URL。
enum NASMarketToken {
    static let service = "com.guanpan.pro.native.market"
    static let account = "breadth-token"

    static var hasToken: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 空字符串等于清除令牌（换 NAS 或轮换密钥时用）。
    static func save(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !clean.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(clean.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "NASMarketToken", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "令牌无法写入 Keychain（错误 \(status)）"])
        }
    }
}

// MARK: - 错误

enum NASMarketBreadthError: LocalizedError {
    case notConfigured
    case missingToken
    case unauthorized
    case unsupportedVersion(Int?)
    case httpStatus(Int)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填观盘max NAS 地址。设置 → 观盘max NAS 里填 http(s)://主机:8788。"
        case .missingToken:
            return "这版 NAS 部署不需要令牌就能读 /api/v1/market/*，请直接点「测试取数」。如果服务端加了鉴权，再把 PRO_SYNC_TOKEN 或 F_MARKET_BREADTH_API_TOKEN 填进来。"
        case .unauthorized:
            return "令牌被拒绝（401）。说明这版 NAS 给 /api/v1/market/* 加了鉴权：把 NAS 的 PRO_SYNC_TOKEN 填到设置里，或把令牌留空再看一次。"
        case .unsupportedVersion(let version):
            let shown = version.map { "\($0)" } ?? "缺失"
            return "NAS 返回的市场契约版本是 \(shown)，本机只支持 1。这一整块数据不展示，避免半份数据被当成完整快照。"
        case .httpStatus(let code):
            return "NAS 返回 HTTP \(code)。404 多半是这版部署还没有 /api/v1/market/* 路由。"
        case .decoding(let detail):
            return "NAS 响应解析失败：\(detail)"
        case .transport(let detail):
            return "连不上 NAS：\(detail)"
        }
    }
}

// MARK: - 上游数值（既可能是数字，也可能被格式化成字符串）

/// 上游同一份契约里，`coverage.universeRatio` 是数字、`breadth.coverageRatio` 是字符串。
/// 统一吃两种写法；解析不了就是 `nil`（未知，不是 0）。
private struct FlexNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        if let double = try? container.decode(Double.self) { value = double; return }
        if let int = try? container.decode(Int.self) { value = Double(int); return }
        if let text = try? container.decode(String.self) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = (clean.isEmpty || clean == "-" || clean == "--") ? nil : Double(clean)
            return
        }
        value = nil
    }
}

// MARK: - 归一后的快照（界面只认这一个）

/// 两代契约归一后的视图模型。字段名沿用 v1 叫法，减少界面层改动；
/// 新增字段承接 NAS v2 已经算好的市场结论。
struct NASMarketSnapshot {

    /// 内部契约编号：2 = `schemaVersion` + `market` 嵌套，1 = `apiVersion` 平铺。
    let contractVersion: Int
    /// 上游自报的模型名，便于排查「NAS 换引擎了」。
    let schemaLabel: String

    // 版本与状态
    let status: String?
    let freshness: String?
    let quality: String?
    let tradingDate: String?
    /// 快照时钟（上海本地 HH:mm）。NAS 不给 source 行情时间时，这是「采集时刻」。
    let sampleClock: String?
    let quoteTimestamp: String?
    let fetchedAt: String?
    let source: String?

    // 覆盖与样本
    let marketScope: String?
    let stockTotal: Int?
    let etfTotal: Int?
    let validCount: Int?
    /// 0–1 小数。上游两代口径不同，这里统一成小数，展示时再乘 100。
    let coverage: Double?
    let amountComplete: Bool
    let amountValidCount: Int?
    let amountUniverseCount: Int?

    // 宽度
    let upCount: Int?
    let downCount: Int?
    let flatCount: Int?
    let up3Count: Int?
    let up5Count: Int?
    let down3Count: Int?
    let down5Count: Int?
    /// 上涨占比 0–1。
    let risingRatio: Double?

    // 成交额（单位：元）
    let aShareStockAmount: Double?
    /// 逐股合计不完整时的观测值：只用于诊断，绝不参与阈值判定。
    let partialAmount: Double?
    let marketCommonAmount: Double?
    let marketCommonReason: String?
    let amountQuality: String?
    /// 较前一交易日**同一时刻**的变化，0.1 表示 +10%。
    let turnoverChangeRatio: Double?
    let comparisonSnapshotAt: String?

    // NAS v2 已算好的市场结论（v1 全为 nil）
    let marketStage: String?
    let stanceLabel: String?
    let stanceReason: String?
    let riskLevel: String?
    let summary: String?
    let reasons: [String]
    let mainlineClarity: String?
    let rotationState: String?
    let aStatus: String?
    let bStatus: String?
    /// NAS 权威判定：当日收盘快照是否可确认（服务器时钟 + 当日 + ≥15:00 + 10 分钟窗口 + 样本量）。
    let closeConfirmed: Bool
    let intradayCandidateOnly: Bool
}

extension NASMarketSnapshot {

    /// 元 → 亿元。只用于显示。
    var sessionAmountYi: Double? { aShareStockAmount.map { $0 / 100_000_000 } }
    var partialAmountYi: Double? { partialAmount.map { $0 / 100_000_000 } }
    var marketCommonAmountYi: Double? { marketCommonAmount.map { $0 / 100_000_000 } }
    var coveragePercent: Double? { coverage.map { $0 * 100 } }
    var risingPercent: Double? { risingRatio.map { $0 * 100 } }

    /// 成交额是否可当「全天」用：必须收盘确认 + 逐股合计完整 + 有值。
    var coversClose: Bool { closeConfirmed }

    /// NAS v2 的 `status` 取值是 available / closed / stale / unavailable。
    var isObserved: Bool {
        let value = (status ?? "").lowercased()
        return value == "available" || value == "closed" || value == "observed"
    }

    /// v2 的 freshness 是 fresh-at-fetch / last-session / stale。
    var isFresh: Bool {
        let value = (freshness ?? "").lowercased()
        return value == "fresh" || value == "fresh-at-fetch"
    }

    /// 今天是否还开着盘（NAS 说 `last-session` 就是收盘后沿用上一场）。
    var isLastSession: Bool { (freshness ?? "").lowercased() == "last-session" }

    /// 展示用的范围说明。v2 没给 marketScope，按实际采集范围拼一句，不编造。
    var scopeText: String {
        if let marketScope, !marketScope.isEmpty { return marketScope }
        return "沪深A股 + ETF候选"
    }

    /// 供 A 条件使用的观测量。nil 表示这份快照给不出成交额口径。
    ///
    /// 注意 `previousSameTimeAmountYi` 是**前一交易日同一时刻**的值，反推自 NAS 的同刻
    /// 变化比例；只有收盘确认时，同刻才等价于前一日全天，此时才允许按增额口径比。
    var aObservation: QuXianChaoGe.AObservation? {
        let amount = sessionAmountYi
        let previous: Double? = {
            guard let amount, let ratio = turnoverChangeRatio, ratio > -0.999 else { return nil }
            return amount / (1 + ratio)
        }()
        guard amount != nil || previous != nil || intradayCandidateOnly else { return nil }
        return QXCGAObservationMake(tradingDate: tradingDate ?? "—",
                                    sampleClock: sampleClock,
                                    sessionAmountYi: amount,
                                    previousSameTimeAmountYi: previous,
                                    sameTimeRatio: turnoverChangeRatio,
                                    coversClose: closeConfirmed,
                                    amountIsComplete: amountComplete,
                                    capturedAtText: fetchedAt ?? tradingDate ?? "—",
                                    sourceNote: amountQuality ?? "NAS 未给成交额质量说明")
    }
}

/// 嵌套类型构造：静态符号核对脚本不解析嵌套构造，直接用 typealias 构造点，
/// 但**属性声明类型必须写完整路径**（写别名会把属性降级成 fileprivate）。
private typealias QXCGAObservation = QuXianChaoGe.AObservation

private func QXCGAObservationMake(tradingDate: String,
                                  sampleClock: String?,
                                  sessionAmountYi: Double?,
                                  previousSameTimeAmountYi: Double?,
                                  sameTimeRatio: Double?,
                                  coversClose: Bool,
                                  amountIsComplete: Bool,
                                  capturedAtText: String,
                                  sourceNote: String) -> QuXianChaoGe.AObservation {
    QXCGAObservation(tradingDate: tradingDate,
                     sampleClock: sampleClock,
                     sessionAmountYi: sessionAmountYi,
                     previousSameTimeAmountYi: previousSameTimeAmountYi,
                     sameTimeRatio: sameTimeRatio,
                     coversClose: coversClose,
                     amountIsComplete: amountIsComplete,
                     capturedAtText: capturedAtText,
                     sourceNote: sourceNote)
}

// MARK: - 契约 v2 原始结构（schemaVersion + market 嵌套）

private struct NASPayloadV2: Decodable {
    struct Turnover: Decodable {
        let aShareYuan: FlexNumber?
        let aShareObservedPartialYuan: FlexNumber?
        let aShareAmountQuality: String?
        let changeVsPriorSameTimePercent: FlexNumber?
        let comparisonSnapshotAt: String?
        let classification: String?
    }
    struct Breadth: Decodable {
        let advancing: Int?
        let declining: Int?
        let unchanged: Int?
        let validCount: Int?
        let unavailableCount: Int?
        let upAtLeast3Percent: Int?
        let upAtLeast5Percent: Int?
        let downAtLeast3Percent: Int?
        let downAtLeast5Percent: Int?
        let coverageRatio: FlexNumber?
        let advanceDeclineRatio: FlexNumber?
        let limitStateUnavailableReason: String?
    }
    struct AuthorAdd: Decodable {
        /// 上游键名是作者原文的大写 `A` / `B`，这里映射成符合 Swift 命名的属性。
        let aRaw: String?
        let bRaw: String?
        let combined: String?
        let intradayIsCandidateOnly: Bool?
        let closeConfirmed: Bool?

        enum CodingKeys: String, CodingKey {
            case aRaw = "A"
            case bRaw = "B"
            case combined
            case intradayIsCandidateOnly
            case closeConfirmed
        }
    }
    struct ModelAction: Decodable {
        let stance: String?
        let label: String?
        let reason: String?
    }
    struct Risk: Decodable {
        let level: String?
        let note: String?
    }
    struct Rotation: Decodable {
        let state: String?
        let basisWindow: String?
        let available: Bool?
        let note: String?
    }
    struct Market: Decodable {
        let status: String?
        let freshness: String?
        let source: String?
        let updatedAt: String?
        let providerTimestamp: String?
        let snapshotTimestamp: String?
        let aShareCount: Int?
        let etfCandidateCount: Int?
        let marketStage: String?
        let summary: String?
        let reasons: [String]?
        let mainlineClarity: String?
        let turnover: Turnover?
        let breadth: Breadth?
        let authorAddPosition: AuthorAdd?
        let modelAction: ModelAction?
        let risk: Risk?
        let rotation: Rotation?
    }
    struct Coverage: Decodable {
        let detail: String?
        let aShare: Int?
        let etfCandidate: Int?
        let universeReported: Int?
        let universeArchived: Int?
        let universeRatio: FlexNumber?
        let latestScanComplete: Bool?
        let breadthValid: Int?
        let breadthUnavailable: Int?
        let aShareAmountValid: Int?
        let aShareAmountUniverse: Int?
        let aShareAmountComplete: Bool?
        let coreIndexReported: Int?
        let coreIndexArchived: Int?
        let coreIndexComplete: Bool?
    }
    struct CommonAmount: Decodable {
        let value: FlexNumber?
        let quality: String?
        let reason: String?
        let asOfTime: String?
    }

    let schemaVersion: Int?
    let model: String?
    let status: String?
    let source: String?
    let quoteTimestamp: String?
    let fetchedAt: String?
    let calculatedAt: String?
    let quality: String?
    let coverage: Coverage?
    let market: Market?
    let marketCommonAmount: CommonAmount?
}

// MARK: - 契约 v1 原始结构（apiVersion + 平铺）

private struct NASPayloadV1: Decodable {
    let apiVersion: Int?
    let status: String?
    let snapshotId: String?
    let tradingDate: String?
    let sampleMinute: String?
    let quoteTimestamp: String?
    let fetchedAt: String?
    let asOfTime: String?
    let marketScope: String?
    let source: String?
    let quality: String?
    let completeness: String?
    let freshness: String?
    let sourceTotal: Int?
    let stockTotal: Int?
    let etfTotal: Int?
    let validCount: Int?
    let coverage: FlexNumber?
    let breadthCoverage: FlexNumber?
    let amountCoverage: FlexNumber?
    let upCount: Int?
    let downCount: Int?
    let flatCount: Int?
    let up3Count: Int?
    let up5Count: Int?
    let down3Count: Int?
    let down5Count: Int?
    let risingRatio: FlexNumber?
    let aShareStockAmount: FlexNumber?
    let marketCommonAmount: FlexNumber?
    let amountQuality: String?
    let previousDaySameTimeTurnover: FlexNumber?
    let turnoverChangeRatio: FlexNumber?
    let sameTimeSampleCount: Int?
    let turnoverState: String?
}

// MARK: - 归一与时间工具

private enum NASMarketMapping {

    /// 解析 ISO8601。NAS 的 `captured_at` 带 **6 位微秒**
    /// （实测 `2026-11-10T09:44:14.207969+00:00`），而 `ISO8601DateFormatter`
    /// 的 `.withFractionalSeconds` 只保证 3 位毫秒，直接喂会解成 nil——
    /// 那样日期和快照时钟都会变成「—」。所以先原样试，失败就把小数位截到 3 位。
    static func parseISO(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        if let dot = raw.firstIndex(of: ".") {
            let afterDot = raw.index(after: dot)
            var end = afterDot
            while end < raw.endIndex, raw[end].isNumber { end = raw.index(after: end) }
            let digits = raw[afterDot..<end]
            if digits.count > 3 {
                let trimmed = String(raw[..<afterDot]) + "." + String(digits.prefix(3)) + String(raw[end...])
                if let date = formatter.date(from: trimmed) { return date }
            }
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// UTC ISO8601 → 上海本地日期 + 时钟。解析不了就返回 nil（不猜）。
    static func shanghaiParts(_ iso: String?) -> (date: String, clock: String)? {
        guard let iso, !iso.isEmpty, let date = parseISO(iso) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute else { return nil }
        let dateText = String(format: "%04d-%02d-%02d", year, month, day)
        let clockText = String(format: "%02d:%02d", hour, minute)
        return (dateText, clockText)
    }

    /// v1 的 `sampleMinute` 是 `2026-11-10T14:57`（不带时区，已是上海本地钟）。
    static func v1Parts(_ sampleMinute: String?) -> (date: String, clock: String)? {
        guard let sampleMinute else { return nil }
        let comps = sampleMinute.split(separator: "T")
        guard comps.count == 2 else { return nil }
        let clock = String(comps[1].prefix(5))
        guard clock.count == 5 else { return nil }
        return (String(comps[0]), clock)
    }

    static func from(_ payload: NASPayloadV2) -> NASMarketSnapshot {
        let market = payload.market
        // 快照时刻取自 market.snapshotTimestamp（NAS 的 captured_at，UTC）。
        let parts = shanghaiParts(market?.snapshotTimestamp)
        let turnover = market?.turnover
        let breadth = market?.breadth
        let author = market?.authorAddPosition
        let amountYuan = turnover?.aShareYuan?.value
        let partialYuan = turnover?.aShareObservedPartialYuan?.value
        let amountComplete = payload.coverage?.aShareAmountComplete ?? false
        // 同刻变化：NAS 给百分数（10.0 = +10%），这里统一成小数（0.1）。
        let changeRatio = turnover?.changeVsPriorSameTimePercent?.value.map { $0 / 100 }
        // 上涨占比：优先用 adv/(adv+dec)（口径明确），不拿 coverageRatio 顶替。
        let risingRatio: Double? = {
            guard let adv = breadth?.advancing, let dec = breadth?.declining, adv + dec > 0 else {
                return nil
            }
            return Double(adv) / Double(adv + dec)
        }()
        let common = payload.marketCommonAmount
        return NASMarketSnapshot(
            contractVersion: 2,
            schemaLabel: payload.model ?? "TodayResearchPayload-v1",
            status: market?.status ?? payload.status,
            freshness: market?.freshness,
            quality: payload.quality,
            tradingDate: parts?.date,
            sampleClock: parts?.clock,
            quoteTimestamp: payload.quoteTimestamp,
            fetchedAt: market?.updatedAt ?? payload.fetchedAt,
            source: market?.source ?? payload.source,
            marketScope: nil,
            stockTotal: market?.aShareCount ?? payload.coverage?.aShare,
            etfTotal: market?.etfCandidateCount ?? payload.coverage?.etfCandidate,
            validCount: breadth?.validCount ?? payload.coverage?.breadthValid,
            coverage: payload.coverage?.universeRatio?.value,
            amountComplete: amountComplete,
            amountValidCount: payload.coverage?.aShareAmountValid,
            amountUniverseCount: payload.coverage?.aShareAmountUniverse,
            upCount: breadth?.advancing,
            downCount: breadth?.declining,
            flatCount: breadth?.unchanged,
            up3Count: breadth?.upAtLeast3Percent,
            up5Count: breadth?.upAtLeast5Percent,
            down3Count: breadth?.downAtLeast3Percent,
            down5Count: breadth?.downAtLeast5Percent,
            risingRatio: risingRatio,
            aShareStockAmount: amountYuan,
            partialAmount: partialYuan,
            marketCommonAmount: common?.value?.value,
            marketCommonReason: common?.reason,
            amountQuality: turnover?.aShareAmountQuality,
            turnoverChangeRatio: changeRatio,
            comparisonSnapshotAt: turnover?.comparisonSnapshotAt,
            marketStage: market?.marketStage,
            stanceLabel: market?.modelAction?.label,
            stanceReason: market?.modelAction?.reason,
            riskLevel: market?.risk?.level,
            summary: market?.summary,
            reasons: market?.reasons ?? [],
            mainlineClarity: market?.mainlineClarity,
            rotationState: market?.rotation?.state,
            aStatus: author?.aRaw,
            bStatus: author?.bRaw,
            closeConfirmed: author?.closeConfirmed ?? false,
            intradayCandidateOnly: author?.intradayIsCandidateOnly ?? false
        )
    }

    static func from(_ payload: NASPayloadV1) -> NASMarketSnapshot {
        let parts = v1Parts(payload.sampleMinute)
        let changeRatio: Double? = {
            // v1 的 turnoverChangeRatio 明确是小数口径（0.1 = +10%）；大于 1 视为百分数误用。
            guard let raw = payload.turnoverChangeRatio?.value else { return nil }
            return abs(raw) > 1 ? raw / 100 : raw
        }()
        return NASMarketSnapshot(
            contractVersion: 1,
            schemaLabel: "market-breadth-v1",
            status: payload.status,
            freshness: payload.freshness,
            quality: payload.quality,
            tradingDate: payload.tradingDate ?? parts?.date,
            sampleClock: parts?.clock,
            quoteTimestamp: payload.quoteTimestamp,
            fetchedAt: payload.fetchedAt ?? payload.asOfTime,
            source: payload.source,
            marketScope: payload.marketScope,
            stockTotal: payload.stockTotal,
            etfTotal: payload.etfTotal,
            validCount: payload.validCount,
            coverage: payload.coverage?.value,
            amountComplete: (payload.amountCoverage?.value ?? 0) >= 0.9999,
            amountValidCount: nil,
            amountUniverseCount: payload.stockTotal,
            upCount: payload.upCount,
            downCount: payload.downCount,
            flatCount: payload.flatCount,
            up3Count: payload.up3Count,
            up5Count: payload.up5Count,
            down3Count: payload.down3Count,
            down5Count: payload.down5Count,
            risingRatio: payload.risingRatio?.value,
            aShareStockAmount: payload.aShareStockAmount?.value,
            partialAmount: nil,
            marketCommonAmount: payload.marketCommonAmount?.value,
            marketCommonReason: nil,
            amountQuality: payload.amountQuality,
            turnoverChangeRatio: changeRatio,
            comparisonSnapshotAt: nil,
            marketStage: nil,
            stanceLabel: nil,
            stanceReason: nil,
            riskLevel: nil,
            summary: nil,
            reasons: [],
            mainlineClarity: nil,
            rotationState: nil,
            aStatus: nil,
            bStatus: nil,
            // v1 契约没有 closeConfirmed：只有 sampleMinute 到 15:00 且成交额完整才认。
            closeConfirmed: {
                guard let clock = parts?.clock, clock >= "15:00" else { return false }
                return (payload.amountCoverage?.value ?? 0) >= 0.9999
            }(),
            intradayCandidateOnly: false
        )
    }
}

// MARK: - 客户端

enum NASMarketBreadth {

    /// 只读 GET。超时压到 12 秒：v2 一次响应包含 `market` + `sectors` + 12 个板块窗口
    /// + 9 个核心指数，比 v1 单表大得多；但也不能因为它卡住整个页面
    /// （NAS 不可用时 App 必须照常离线可用）。
    ///
    /// **令牌是可选的**：`F-NAS-DEPLOYMENT-2026-11-10` 这版把 `/api/v1/market/*` 做成了
    /// 公开只读路由（只有 `/api/native/*` 需要 `PRO_SYNC_TOKEN`）。所以「没配令牌」不等于
    /// 「取不到数」——有令牌就带上（兼容以后加鉴权的部署），没有就不带，让服务端自己决定。
    static func fetchLatest(timeout: TimeInterval = 12) async throws -> NASMarketSnapshot {
        guard let base = GuanpanMaxNAS.validateAddress() else {
            throw NASMarketBreadthError.notConfigured
        }
        let url = base.appendingPathComponent("api/v1/market/realtime")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = NASMarketToken.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NASMarketBreadthError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NASMarketBreadthError.transport("响应不是 HTTP")
        }
        if http.statusCode == 401 { throw NASMarketBreadthError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw NASMarketBreadthError.httpStatus(http.statusCode)
        }
        return try decode(data)
    }

    /// 单独拆出来便于纯函数测试：给一段 JSON，返回归一后的快照。
    static func decode(_ data: Data) throws -> NASMarketSnapshot {
        let decoder = JSONDecoder()
        // 先按 v2 试：判定依据是存在 `market` 对象（v1 没有这个键）。
        // 不用 `schemaVersion` 单独判定，因为 v1 也可能被上游顺手加上。
        if let probe = try? decoder.decode(NASVersionProbe.self, from: data),
           probe.hasMarketObject {
            let payload: NASPayloadV2
            do {
                payload = try decoder.decode(NASPayloadV2.self, from: data)
            } catch {
                throw NASMarketBreadthError.decoding(error.localizedDescription)
            }
            guard let version = payload.schemaVersion else {
                throw NASMarketBreadthError.unsupportedVersion(nil)
            }
            guard version == 1 else {
                throw NASMarketBreadthError.unsupportedVersion(version)
            }
            return NASMarketMapping.from(payload)
        }
        let payload: NASPayloadV1
        do {
            payload = try decoder.decode(NASPayloadV1.self, from: data)
        } catch {
            throw NASMarketBreadthError.decoding(error.localizedDescription)
        }
        guard let version = payload.apiVersion else {
            throw NASMarketBreadthError.unsupportedVersion(nil)
        }
        guard version == 1 else {
            throw NASMarketBreadthError.unsupportedVersion(version)
        }
        return NASMarketMapping.from(payload)
    }
}

/// 只用来判断「这是不是 v2 结构」：有非空的 `market` 对象就是。
private struct NASVersionProbe: Decodable {
    struct MarketProbe: Decodable {
        let status: String?
    }
    let market: MarketProbe?
    let schemaVersion: Int?

    var hasMarketObject: Bool { market != nil }
}
