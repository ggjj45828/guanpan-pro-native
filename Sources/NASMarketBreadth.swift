import Foundation
import Security

// MARK: - 观盘max NAS 全市场量能 / 广度（8788 契约 v1）
//
// 契约来源：F/nas/WINDOWS-NAS-INTEGRATION.md。NAS 侧已把对外响应固定为版本化
// camelCase（数据库内部仍是 snake_case），本文件只做「读」：不写 NAS、不上传账本。
//
// 五条硬口径，少一条就会把错误数据端到界面上：
//   1. 只认 `apiVersion == 1`。缺失或不等于 1 → 整段不展示，绝不硬解成半份数据。
//   2. 缺值是 JSON `null`，不是 0。0 表示「观测到 0 家」，未知表示「没拿到」，两者不能混。
//   3. `quoteTimestamp` 为 null 表示上游没给源报价时间；不得拿 `fetchedAt` 冒充行情源时间。
//   4. `status` / `freshness` / `quality` / `coverage` 都必须读。HTTP 200 不代表数据可用。
//   5. 金额单位是人民币元；界面换算成亿元只用于显示，不参与判定单位。
//
// 另外一条本工程自己的不变量：**盘中累计成交额不等于单日成交额**。收盘集合竞价
// 在 14:57–15:00，若 NAS 最后一笔快照是 14:59，那个累计值仍可能少一截。所以只有
// 快照时钟到 15:00 才允许当作「全天」使用，其余一律按盘中处理。

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
            return "还没保存市场量能令牌。8788 的 /api/v1/market/* 需要 Bearer 令牌（F_MARKET_BREADTH_API_TOKEN）。"
        case .unauthorized:
            return "令牌被拒绝（401）。请核对设置里的市场量能令牌与 NAS 的 F_MARKET_BREADTH_API_TOKEN 是否一致。"
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

// MARK: - 快照（契约 v1）

/// 嵌套类型别名：本工程的静态符号核对脚本不解析嵌套类型构造，
/// 直接写 `QuXianChaoGe.AObservation(...)` 会被误报成「没有这个静态成员」。
private typealias QXCGAObservation = QuXianChaoGe.AObservation

struct NASMarketSnapshot: Decodable {
    // 版本与状态
    let apiVersion: Int?
    let status: String?
    let snapshotId: String?
    let tradingDate: String?
    let sampleMinute: String?
    let quoteTimestamp: String?
    let fetchedAt: String?
    let calculatedAt: String?
    let asOfTime: String?
    let asOfBasis: String?
    let marketScope: String?
    let source: String?
    let quality: String?
    let completeness: String?
    let freshness: String?

    // 覆盖与样本
    let sourceTotal: Int?
    let stockTotal: Int?
    let etfTotal: Int?
    let validCount: Int?
    let coverage: Double?
    let breadthCoverage: Double?
    let amountCoverage: Double?

    // 宽度
    let upCount: Int?
    let downCount: Int?
    let flatCount: Int?
    let up1Count: Int?
    let up3Count: Int?
    let up5Count: Int?
    let down1Count: Int?
    let down3Count: Int?
    let down5Count: Int?
    let risingRatio: Double?
    let breadthState: String?

    // 成交额（单位：元）
    let aShareStockAmount: Double?
    let marketCommonAmount: Double?
    let amountQuality: String?
    let previousDaySameTimeTurnover: Double?
    let previousFiveDaySameTimeAverage: Double?
    let turnoverChangeRatio: Double?
    let turnoverVsFiveDayRatio: Double?
    let sameTimeSampleCount: Int?
    let projectedFullDayTurnover: Double?
    let projectionConfidence: String?
    let turnoverState: String?
}

extension NASMarketSnapshot {

    /// 元 → 亿元。只用于显示。
    var sessionAmountYi: Double? { aShareStockAmount.map { $0 / 100_000_000 } }
    var previousSameTimeYi: Double? { previousDaySameTimeTurnover.map { $0 / 100_000_000 } }
    var fiveDayAverageYi: Double? { previousFiveDaySameTimeAverage.map { $0 / 100_000_000 } }
    var projectedFullDayYi: Double? { projectedFullDayTurnover.map { $0 / 100_000_000 } }

    /// 契约只允许三种状态语义：observed / stale / unavailable。
    var isObserved: Bool { (status ?? "") == "observed" }
    var isFresh: Bool { (freshness ?? "") == "fresh" }

    /// "2026-11-10T14:57" → "14:57"。sampleMinute 不带时区，是上海本地时钟。
    var sampleClock: String? {
        guard let raw = sampleMinute else { return nil }
        let parts = raw.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let clock = String(parts[1].prefix(5))
        return clock.count == 5 ? clock : nil
    }

    /// 最后一笔快照是否已经到收盘（15:00）。不到就不许当全天成交额用。
    var coversClose: Bool {
        guard let clock = sampleClock else { return false }
        return clock >= "15:00"
    }

    /// 覆盖率的百分比显示口径（契约给的是 0–1 小数）。
    var coveragePercent: Double? { coverage.map { $0 * 100 } }

    /// 供 A 条件使用的观测量。nil 表示这份快照给不出成交额口径。
    var aObservation: QXCGAObservation? {
        let amount = sessionAmountYi
        let previous = previousSameTimeYi
        guard amount != nil || previous != nil else { return nil }
        return QXCGAObservation(tradingDate: tradingDate ?? "—",
                                         sampleClock: sampleClock,
                                         sessionAmountYi: amount,
                                         previousSameTimeAmountYi: previous,
                                         sameTimeRatio: turnoverChangeRatio,
                                         coversClose: coversClose,
                                         amountIsComplete: (amountCoverage ?? 0) >= 0.9999,
                                         capturedAtText: fetchedAt ?? asOfTime ?? "—",
                                         sourceNote: amountQuality ?? "NAS 未给成交额质量说明")
    }
}

// MARK: - 客户端

enum NASMarketBreadth {

    /// 只读 GET。超时压到 8 秒：这块数据是「锦上添花」，
    /// 不能因为它卡住整个页面（NAS 不可用时 App 必须照常离线可用）。
    static func fetchLatest(timeout: TimeInterval = 8) async throws -> NASMarketSnapshot {
        guard let base = GuanpanMaxNAS.validateAddress() else {
            throw NASMarketBreadthError.notConfigured
        }
        guard let token = NASMarketToken.load() else {
            throw NASMarketBreadthError.missingToken
        }
        let url = base.appendingPathComponent("api/v1/market/realtime")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        let snapshot: NASMarketSnapshot
        do {
            snapshot = try JSONDecoder().decode(NASMarketSnapshot.self, from: data)
        } catch {
            throw NASMarketBreadthError.decoding(error.localizedDescription)
        }
        guard let version = snapshot.apiVersion else {
            throw NASMarketBreadthError.unsupportedVersion(nil)
        }
        guard version == 1 else {
            throw NASMarketBreadthError.unsupportedVersion(version)
        }
        return snapshot
    }
}
