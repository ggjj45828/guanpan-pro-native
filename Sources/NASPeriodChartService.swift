import Foundation

/// NAS 周期K线数据源（/api/v1/chart）。
///
/// 诚实约束：服务端只用真实 1 分钟归档聚合 15/30/60/120 分钟 OHLCV；
/// 没有真实分钟时返回 unavailable —— 本层如实透传，绝不本地拿日线拼分钟线、
/// 不插值不补全。MACD 快/慢/信号由调用方传入，不写死默认值。
struct NASPeriodBar: Identifiable, Equatable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
    let minuteCount: Int
    let complete: Bool
    /// real_1m_ohlc（1 分钟 bar 自带开高低收）/ aggregated_1m_price（价格快照聚合）
    let ohlcSource: String
    var id: Date { timestamp }
}

struct NASPeriodMACD: Equatable {
    let fast: Int
    let slow: Int
    let signal: Int
    let warmupBars: Int
    let available: Bool
    let reason: String?
    let dif: [Double?]
    let dea: [Double?]
    let hist: [Double?]
}

struct NASPeriodChart: Equatable {
    enum Availability: Equatable {
        case ok
        case unavailable(reason: String, detail: String)
    }
    let securityCode: String
    let periodMinutes: Int
    let availability: Availability
    let bars: [NASPeriodBar]
    let macd: NASPeriodMACD?
    let ohlcSource: String
    let firstTimestamp: Date?
    let lastTimestamp: Date?
}

enum NASPeriodChartError: Error, LocalizedError {
    case invalidAddress
    case invalidCode
    case invalidPeriod
    case invalidParameters(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请先在设置里填写观盘max NAS 地址"
        case .invalidCode: return "证券代码必须是 6 位数字"
        case .invalidPeriod: return "周期只支持 15 / 30 / 60 / 120 分钟"
        case .invalidParameters(let text): return text
        case .transport(let text): return text
        }
    }
}

enum NASPeriodChartService {
    /// 服务端认可的周期（与 kline.py PERIOD_MINUTES_SUPPORTED 一致）。
    static let supportedPeriods = [15, 30, 60, 120]

    static func fetch(code: String, periodMinutes: Int, days: Int = 120,
                      macdFast: Int = 12, macdSlow: Int = 26, macdSignal: Int = 9) async throws -> NASPeriodChart {
        guard GuanpanMaxNAS.validateAddress() != nil else { throw NASPeriodChartError.invalidAddress }
        guard let digits = GuanpanMaxNAS.normalizedSecurityCode(code) else { throw NASPeriodChartError.invalidCode }
        guard supportedPeriods.contains(periodMinutes) else { throw NASPeriodChartError.invalidPeriod }
        guard macdFast >= 1, macdFast < macdSlow, macdSlow <= 500, macdSignal >= 1, macdSignal <= 100 else {
            throw NASPeriodChartError.invalidParameters("MACD 参数需满足：快≥1、慢>快≤500、信号 1…100")
        }
        let query = [
            URLQueryItem(name: "securityCode", value: digits),
            URLQueryItem(name: "market", value: "CN"),
            URLQueryItem(name: "period", value: String(periodMinutes)),
            URLQueryItem(name: "days", value: String(max(1, min(days, 750)))),
            URLQueryItem(name: "macdFast", value: String(macdFast)),
            URLQueryItem(name: "macdSlow", value: String(macdSlow)),
            URLQueryItem(name: "macdSignal", value: String(macdSignal)),
        ]
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await GuanpanMaxNAS.rawRequest(path: "/api/v1/chart", query: query,
                                                              timeout: 25, maximumBytes: 8_000_000)
        } catch {
            throw NASPeriodChartError.transport(GuanpanMaxNAS.connectionHint(for: error))
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverText = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw NASPeriodChartError.transport(serverText ?? "NAS 返回 HTTP \(http.statusCode)")
        }
        return try parse(payload: data, fallbackCode: digits, periodMinutes: periodMinutes)
    }

    // MARK: - 解析（字段对齐 kline.py chart_payload）

    private static func parse(payload: Data, fallbackCode: String,
                              periodMinutes: Int) throws -> NASPeriodChart {
        struct RawBar: Decodable {
            let timestamp: String
            let open: Double
            let high: Double
            let low: Double
            let close: Double
            let volume: Double?
            let minuteCount: Int
            let complete: Bool
            let ohlcSource: String?
        }
        struct RawMACD: Decodable {
            let fast: Int
            let slow: Int
            let signal: Int
            let warmupBars: Int
            let available: Bool
            let reason: String?
            let dif: [Double?]
            let dea: [Double?]
            let hist: [Double?]
        }
        struct RawCoverage: Decodable {
            let firstTimestamp: String?
            let lastTimestamp: String?
        }
        struct RawPayload: Decodable {
            let status: String
            let securityCode: String?
            let periodMinutes: Int?
            let ohlcSource: String?
            let unavailable: RawUnavailable?
            let bars: [RawBar]?
            let macd: RawMACD?
            let coverage: RawCoverage?
        }
        struct RawUnavailable: Decodable {
            let reason: String?
            let detail: String?
        }
        let decoder = JSONDecoder()
        let raw: RawPayload
        do {
            raw = try decoder.decode(RawPayload.self, from: payload)
        } catch {
            throw NASPeriodChartError.transport("NAS 响应结构无法解析：\(error.localizedDescription)")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseTime(_ text: String?) -> Date? {
            guard let text else { return nil }
            return iso.date(from: text) ?? isoPlain.date(from: text) ?? Date(timeIntervalSince1970: 0)
        }
        let bars = (raw.bars ?? []).map {
            NASPeriodBar(timestamp: parseTime($0.timestamp) ?? Date(timeIntervalSince1970: 0),
                         open: $0.open, high: $0.high, low: $0.low, close: $0.close,
                         volume: $0.volume, minuteCount: $0.minuteCount, complete: $0.complete,
                         ohlcSource: $0.ohlcSource ?? "aggregated_1m_price")
        }
        let macd = raw.macd.map {
            NASPeriodMACD(fast: $0.fast, slow: $0.slow, signal: $0.signal, warmupBars: $0.warmupBars,
                          available: $0.available, reason: $0.reason, dif: $0.dif, dea: $0.dea, hist: $0.hist)
        }
        let availability: NASPeriodChart.Availability
        if raw.status == "unavailable", let u = raw.unavailable {
            availability = .unavailable(reason: u.reason ?? "no_real_minute_data",
                                        detail: u.detail ?? "该区间没有真实分钟数据")
        } else if bars.isEmpty {
            availability = .unavailable(reason: "no_real_minute_data",
                                        detail: "该区间没有真实分钟数据；不会用日线拼分钟线")
        } else {
            availability = .ok
        }
        return NASPeriodChart(
            securityCode: raw.securityCode ?? fallbackCode,
            periodMinutes: raw.periodMinutes ?? periodMinutes,
            availability: availability,
            bars: bars,
            macd: macd,
            ohlcSource: raw.ohlcSource ?? "aggregated_1m_price",
            firstTimestamp: parseTime(raw.coverage?.firstTimestamp),
            lastTimestamp: parseTime(raw.coverage?.lastTimestamp))
    }
}
