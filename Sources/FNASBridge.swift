import Foundation

// MARK: - 观盘F NAS 桥接
//
// 观盘 Pro 原本只认自家 NAS 服务端（/api/native/*、/api/quote 这类「原样转发上游字节」的接口）。
// 而观盘F（Next）的服务端是另一套 REST：/health、/v1/market/quotes、/v1/market/daily/<code>。
// 两者协议不同，不能混用同一个地址。
//
// 这一层只做一件事：把 F 服务端的 JSON 翻成 Pro 的 Quote / DailyBar。
// 它**不写账本、不碰同步**：F 服务端的 /api/data 是 F App 自己的数据结构，
// 把 Pro 的账本塞过去只会互相覆盖，所以这里不做备份同步，设置页也如实写明。

struct FNASQuoteRow: Decodable {
    let code: String
    let name: String
    let price: String
    let previousClose: String
    let time: String?
    let providerInstrumentType: String?
}

private struct FNASQuotesResponse: Decodable {
    let quotes: [FNASQuoteRow]
}

struct FNASDailyRow: Decodable {
    let date: String
    let open: String
    let close: String
    let high: String
    let low: String
    let volume: String
}

private struct FNASDailyResponse: Decodable {
    let code: String?
    let bars: [FNASDailyRow]
}

enum FNASBridge {
    /// 与 Pro 自己的 NAS 地址分开存：两者端口和路径都不一样，
    /// 共用一个字段会让「换一台 NAS 当行情源」变成改坏同步配置。
    static let urlKey = "guanpan.native.fnas.url"

    static var baseURLString: String {
        UserDefaults.standard.string(forKey: urlKey) ?? ""
    }

    static var normalizedBase: String? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static var isConfigured: Bool { normalizedBase != nil }

    static func save(_ address: String) {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }

    /// /health 返回部署版本，用来确认「填的地址真的是观盘F 服务端」，
    /// 而不是把 Pro 自己的 NAS 地址填到这一栏。
    static func health() async throws -> String? {
        guard let base = normalizedBase,
              let url = URL(string: base + "/health") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?["codeVersion"] as? String
    }

    /// 一次最多 60 个代码，与 F 服务端的校验一致；超过的部分直接截断而不是整批失败。
    static func quotes(codes: [String]) async throws -> [String: Quote] {
        let unique = Array(Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count == 6 && $0.allSatisfy(\.isNumber) })).sorted()
        guard !unique.isEmpty, let base = normalizedBase else { return [:] }
        let list = unique.prefix(60).joined(separator: ",")
        guard let encoded = list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: base + "/v1/market/quotes?codes=" + encoded) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(FNASQuotesResponse.self, from: data)
        var result: [String: Quote] = [:]
        for row in decoded.quotes {
            guard let price = Double(row.price), let previous = Double(row.previousClose),
                  price > 0, previous > 0 else { continue }
            result[row.code] = Quote(code: row.code, name: row.name, price: price,
                                     changePct: (price - previous) / previous,
                                     updatedAt: parseTimestamp(row.time),
                                     // 观盘F 服务端转发的行情也要打来源标签，
                                     // 否则估值门禁无法区分「可信的 NAS 报价」与「来路不明的缓存」。
                                     source: QuoteSourceTrust.guanpanFNAS,
                                     fetchedAt: Date())
        }
        return result
    }

    static func daily(code: String, count: Int) async throws -> [DailyBar] {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              let base = normalizedBase,
              let url = URL(string: base + "/v1/market/daily/" + code) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(FNASDailyResponse.self, from: data)
        let bars = decoded.bars.compactMap { row -> DailyBar? in
            guard let open = Double(row.open), let close = Double(row.close),
                  let high = Double(row.high), let low = Double(row.low),
                  let volume = Double(row.volume), close > 0 else { return nil }
            return DailyBar(code: code, date: row.date, open: open, close: close,
                            high: high, low: low, volume: volume)
        }.sorted { $0.date < $1.date }
        guard !bars.isEmpty else { throw URLError(.cannotParseResponse) }
        return Array(bars.suffix(min(max(count, 30), 640)))
    }

    /// F 服务端给的是带时区的 ISO8601（例：2026-11-06T15:00:00+08:00）。
    private static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
