import Foundation

// MARK: - 观盘Next 服务端桥接（可选实时行情源）
//
// 三套 NAS 协议互不相通，地址绝不能混填：
//   · Pro 账本同步    /api/native/*    NASSyncService
//   · 观盘Next        /v1/market/*     本文件，30001，**有实时报价**
//   · 观盘max NAS     /api/v1/*        GuanpanMaxNAS，8790，只有归档历史
//
// 观盘max（guanpan-f）的 f-minute-archive 上**没有** /v1/market/quotes，
// 把 8790 的地址填到这一栏会全部 404。反过来，把 30001 填到观盘max 那栏
// 也拿不到研究证据。两个地址分别存，设置页分别标注。
//
// 这一层只做一件事：把观盘Next 服务端的 JSON 翻成 Pro 的 Quote / DailyBar。
// 它**不写账本、不碰同步**：/api/data 是另一套数据结构，
// 把 Pro 的账本塞过去只会互相覆盖。

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

    /// **已停用**：观盘Next 的 30001 服务端不再接入。
    /// 设置页里的地址栏已删除，这里强制返回 nil，避免旧安装残留的地址
    /// 继续被当成行情兜底源（那套路径和观盘max NAS 完全不同，填错就是 -1011）。
    static var normalizedBase: String? {
        nil
    }

    static var isConfigured: Bool { false }

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
