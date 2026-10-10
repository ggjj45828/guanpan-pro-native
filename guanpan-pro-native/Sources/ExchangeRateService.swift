import Foundation

/// 实时汇率快照。
///
/// 数据通道说明（2026-10 实测）：
/// - 腾讯财经 `qt.gtimg.cn`：本工程行情层已在用的同一域名，带 `Access-Control-Allow-Origin: *`，
///   不校验 Referer，App 与网页端都能直连，覆盖 9 个常用币种，是**主通道**。
/// - 新浪财经 `hq.sinajs.cn`：必须携带 `Referer` 请求头，否则返回 403；浏览器端跨域取不到。
///   App 端可以直连，仅用于补齐腾讯没有的日元，是**备用通道**。
/// - 东方财富 `push2.eastmoney.com`：单只接口实测连接超时（`[000]`），不作为数据源。
struct ExchangeRate: Codable, Identifiable, Equatable {
    var id: String { code }
    /// 货币对代码，如 `USDCNY`。
    let code: String
    /// 展示名称，如 `美元/人民币`。
    let name: String
    /// 报价：每 `unit` 单位外币兑人民币。
    let price: Double
    /// 涨跌额（人民币）。
    let change: Double
    /// 涨跌幅，单位为百分数，`-0.16` 表示 -0.16%。
    let changePct: Double
    /// 报价单位，日元为 100，其余为 1。
    let unit: Double
    /// 行情时间戳。
    let updatedAt: Date?
    /// 数据来源，用于在界面标注通道。
    let source: String
}

/// 支持的货币对定义。
enum FXPair: String, CaseIterable {
    case usd = "USDCNY"
    case eur = "EURCNY"
    case hkd = "HKDCNY"
    case gbp = "GBPCNY"
    case jpy = "JPYCNY"
    case aud = "AUDCNY"
    case cad = "CADCNY"
    case sgd = "SGDCNY"
    case chf = "CHFCNY"
    case nzd = "NZDCNY"

    /// 界面展示名称。
    var displayName: String {
        switch self {
        case .usd: return "美元/人民币"
        case .eur: return "欧元/人民币"
        case .hkd: return "港元/人民币"
        case .gbp: return "英镑/人民币"
        case .jpy: return "100 日元/人民币"
        case .aud: return "澳元/人民币"
        case .cad: return "加元/人民币"
        case .sgd: return "新加坡元/人民币"
        case .chf: return "瑞士法郎/人民币"
        case .nzd: return "新西兰元/人民币"
        }
    }

    /// 报价单位：日元按 100 报价，符合国内看盘习惯。
    var unit: Double { self == .jpy ? 100 : 1 }

    /// 腾讯外汇代码。`nil` 表示腾讯没有该币种。
    var tencentSymbol: String? {
        switch self {
        case .jpy: return nil
        default: return "wh" + rawValue
        }
    }

    /// 新浪外汇代码。
    var sinaSymbol: String { "fx_s" + rawValue.lowercased() }

    /// 界面排序权重，常用币种在前。
    var order: Int {
        switch self {
        case .usd: return 0
        case .hkd: return 1
        case .eur: return 2
        case .jpy: return 3
        case .gbp: return 4
        case .aud: return 5
        case .cad: return 6
        case .sgd: return 7
        case .chf: return 8
        case .nzd: return 9
        }
    }
}

/// 汇率抓取与缓存。
enum ExchangeRateService {
    private static let cacheKey = "guanpan.fx.snapshot.v1"
    /// 缓存有效期：非交易日或接口不可用时仍能展示最近一次成功值。
    private static let cacheLifetime: TimeInterval = 60 * 60 * 24

    struct Snapshot: Codable {
        var rates: [ExchangeRate]
        var fetchedAt: Date
    }

    // MARK: - 对外接口

    /// 读取本地缓存（不含过期判断），用于界面首屏立即出数。
    static func cached() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 抓取实时汇率。成功则写入缓存；全部通道失败时退回最近缓存。
    /// - Parameter includingStale: 为 true 时允许返回过期缓存。
    static func fetch(includingStale: Bool = true) async -> Snapshot? {
        var collected: [String: ExchangeRate] = [:]

        let tencent = await fetchTencent()
        for rate in tencent { collected[rate.code] = rate }

        // 腾讯缺日元，用新浪补齐；腾讯整体失败时也尝试新浪全量兜底。
        let missing = FXPair.allCases.filter { collected[$0.rawValue] == nil }
        if !missing.isEmpty {
            let sina = await fetchSina(pairs: missing)
            for rate in sina where collected[rate.code] == nil { collected[rate.code] = rate }
        }

        guard !collected.isEmpty else {
            return includingStale ? cached() : nil
        }

        let snapshot = Snapshot(
            rates: collected.values.sorted { $0.pairOrder < $1.pairOrder },
            fetchedAt: Date()
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return snapshot
    }

    /// 判断缓存是否已超过有效期，用于界面提示「数据可能滞后」。
    static func isStale(_ snapshot: Snapshot) -> Bool {
        Date().timeIntervalSince(snapshot.fetchedAt) > cacheLifetime
    }

    // MARK: - 腾讯通道

    /// 一次请求取回所有腾讯支持的币种。
    private static func fetchTencent() async -> [ExchangeRate] {
        let symbols = FXPair.allCases.compactMap { $0.tencentSymbol }
        guard !symbols.isEmpty else { return [] }
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://qt.gtimg.cn/q=" + symbols.joined(separator: ",") + "&_t=\(stamp)") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // 与行情层一致的移动端标识，避免被网关识别为异常流量。
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let text = await loadText(request) else { return [] }
        return parseTencentFX(text)
    }

    /// 解析腾讯外汇返回：
    /// `v_whUSDCNY="310~美元人民币~USDCNY~6.6925~0~20261010030003~6.7031~6.7000~6.7001~6.6911~6.6925~6.6929~-0.0106~-0.16~..."`
    /// 字段：1 名称 / 2 代码 / 3 最新价 / 5 时间 / 6 昨收 / 12 涨跌额 / 13 涨跌幅(%)
    private static func parseTencentFX(_ text: String) -> [ExchangeRate] {
        var result: [ExchangeRate] = []
        let pattern = #"v_(wh[A-Za-z]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges == 3 {
            let symbol = ns.substring(with: match.range(at: 1)).uppercased()
            let fields = ns.substring(with: match.range(at: 2)).split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count > 13,
                  let pair = FXPair.allCases.first(where: { $0.tencentSymbol?.uppercased() == symbol }),
                  let price = Double(fields[3]), price > 0 else { continue }
            let change = Double(fields[12]) ?? 0
            let pct = Double(fields[13]) ?? 0
            result.append(ExchangeRate(
                code: pair.rawValue,
                name: pair.displayName,
                price: price,
                change: change,
                changePct: pct,
                unit: pair.unit,
                updatedAt: parseTencentTimestamp(String(fields[5])),
                source: "腾讯财经"
            ))
        }
        return result
    }

    private static func parseTencentTimestamp(_ raw: String) -> Date? {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 14 || digits.count == 12 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = digits.count == 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
        return formatter.date(from: digits)
    }

    // MARK: - 新浪通道（备用）

    private static func fetchSina(pairs: [FXPair]) async -> [ExchangeRate] {
        guard !pairs.isEmpty else { return [] }
        let list = pairs.map(\.sinaSymbol).joined(separator: ",")
        guard let url = URL(string: "https://hq.sinajs.cn/list=" + list) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // 新浪校验 Referer，缺失时直接 403。
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let text = await loadText(request) else { return [] }
        return parseSinaFX(text, pairs: pairs)
    }

    /// 解析新浪外汇返回：
    /// `var hq_str_fx_susdcny="03:00:01,6.6925,...,6.6929000000,在岸人民币,...,2026-10-10";`
    /// 价格取字段 8，回退 3 / 1；涨跌幅取字段 10 / 11（部分币种为空，此时置 0）。
    private static func parseSinaFX(_ text: String, pairs: [FXPair]) -> [ExchangeRate] {
        var result: [ExchangeRate] = []
        for pair in pairs {
            let marker = "hq_str_\(pair.sinaSymbol)=\""
            guard let start = text.range(of: marker)?.upperBound,
                  let end = text[start...].firstIndex(of: "\"") else { continue }
            let fields = text[start..<end].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 8 else { continue }
            func value(_ index: Int) -> Double? {
                guard fields.indices.contains(index) else { return nil }
                return Double(fields[index])
            }
            guard let raw = value(8) ?? value(3) ?? value(1), raw > 0 else { continue }
            let pct = value(10) ?? 0
            // 新浪个别币种用错误值填充，异常幅度直接丢弃。
            let safePct = abs(pct) < 20 ? pct : 0
            result.append(ExchangeRate(
                code: pair.rawValue,
                name: pair.displayName,
                price: raw * pair.unit,
                change: 0,
                changePct: safePct,
                unit: pair.unit,
                updatedAt: nil,
                source: "新浪财经"
            ))
        }
        return result
    }

    // MARK: - 网络与编码

    /// 请求并做 GB18030 解码（腾讯返回 `charset=GBK`）。
    private static func loadText(_ request: URLRequest) async -> String? {
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return String(data: bytes, encoding: .isoLatin1)
        }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding))
            ?? String(data: bytes, encoding: .isoLatin1)
    }
}

private extension ExchangeRate {
    /// 排序用权重，读取币种定义。
    var pairOrder: Int { FXPair(rawValue: code)?.order ?? 999 }
}
