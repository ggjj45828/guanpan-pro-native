import Foundation

/// 全球指数看板：上证指数、纳斯达克100、日经225、韩国KOSPI、恒生科技。
///
/// ## 数据源口径（2026-10-20 实测，三源交叉验证过）
///
/// | 指数 | 采用 | 实测值 | 说明 |
/// |---|---|---|---|
/// | 上证指数 | 新浪 `s_sh000001` | 3727.75 | 与腾讯 `sh000001` 3726.56 一致（盘中时点差） |
/// | 日经225 | 新浪 `b_NKY` | 64056.28 -1.33% | `int_nikkei` 是陈旧错值，**禁用** |
/// | 韩国KOSPI | 新浪 `b_KOSPI` | 5522.80 -4.25% | 实时 |
/// | 恒生科技 | 新浪 `rt_hkHSTECH` | 4055.52 -1.21% | 实时 |
/// | 纳斯达克100 | 新浪 `gb_$ndx` | 29529.34 +1.17% | 与腾讯 `usNDX` 完全一致 |
///
/// 两个坑写在这里，防止以后又踩：
/// 1. **新浪 `b_NDX` 返回的是 2025-09-26 的陈旧值**（24503.85），不是纳指 100 的现值；
/// 2. **东财 `100.NDX` 的 26430.89 实际是纳斯达克综合指数**（与新浪 `gb_ixic` 完全相等），
///    拿它当纳指 100 会差 10% 以上。
///
/// 这几个源都只提供快照，没有分钟序列 —— 所以指数只做看板，不画分时，不伪造历史。
struct GlobalIndexQuote: Identifiable, Equatable {
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double
    let previousClose: Double?
    let observedAt: Date?
    let isStale: Bool
    var id: String { symbol }
}

enum GlobalIndexFeed {
    /// 固定 5 个，按用户指定顺序，不加不减。
    static let catalog: [(symbol: String, name: String, short: String)] = [
        ("s_sh000001", "上证指数", "上证"),
        ("gb_$ndx", "纳斯达克100", "纳指100"),
        ("b_NKY", "日经225", "日经"),
        ("b_KOSPI", "韩国KOSPI", "韩国"),
        ("rt_hkHSTECH", "恒生科技", "恒科")
    ]

    static let endpoint = "https://hq.sinajs.cn/list="

    static func displayName(_ symbol: String) -> String {
        catalog.first { $0.symbol == symbol }?.name ?? symbol
    }

    static func shortName(_ symbol: String) -> String {
        catalog.first { $0.symbol == symbol }?.short ?? symbol
    }

    /// 解析新浪的多行响应。只取数字字段，名称用本地目录 ——
    /// 新浪返回是 GB18030，取中文会冒乱码风险，而名称我们本来就固定。
    static func parse(_ body: String, now: Date = Date()) -> [GlobalIndexQuote] {
        var result: [GlobalIndexQuote] = []
        for line in body.split(separator: "\n") {
            let text = String(line)
            guard let keyStart = text.range(of: "hq_str_"),
                  let equals = text.range(of: "=\""),
                  let end = text.range(of: "\";") else { continue }
            let symbol = String(text[keyStart.upperBound..<equals.lowerBound])
            let payload = String(text[equals.upperBound..<end.lowerBound])
            let fields = payload.components(separatedBy: ",")
            guard fields.count >= 4 else { continue }
            guard let quote = parseFields(symbol: symbol, fields: fields, now: now) else { continue }
            result.append(quote)
        }
        // 按 catalog 顺序输出，源里缺哪个就少哪个，不补造。
        return catalog.compactMap { item in result.first { $0.symbol == item.symbol } }
    }

    private static func parseFields(symbol: String, fields: [String], now: Date) -> GlobalIndexQuote? {
        let name = displayName(symbol)
        func number(_ index: Int) -> Double? {
            guard fields.indices.contains(index) else { return nil }
            let text = fields[index].trimmingCharacters(in: .whitespaces)
            guard let value = Double(text), value.isFinite else { return nil }
            return value
        }
        var price: Double?
        var changePercent: Double?
        var previousClose: Double?
        var stamp: Date?

        if symbol.hasPrefix("gb_") {
            // 名称, 现价, 涨跌幅%, 时间, 涨跌额, ...
            price = number(1)
            changePercent = number(2)
            stamp = date(from: fields.indices.contains(3) ? fields[3] : "", formats: ["yyyy-MM-dd HH:mm:ss"])
        } else if symbol.hasPrefix("rt_hk") {
            // 代码, 名称, 今开, 昨收, 最高, 最低, 现价, 涨跌, 涨跌%, ..., 日期, 时间
            previousClose = number(3)
            price = number(6)
            changePercent = number(8)
            if fields.count >= 18 {
                stamp = date(from: "\(fields[16]) \(fields[17])", formats: ["yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"])
            }
        } else if symbol.hasPrefix("b_") {
            // 名称, 现价, 涨跌, 涨跌%, 上下午标记, 时间, 日期, ...
            price = number(1)
            changePercent = number(3)
            if fields.count >= 7 {
                stamp = date(from: "\(fields[6]) \(fields[5])", formats: ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"])
            }
        } else {
            // s_ 前缀：名称, 现价, 涨跌, 涨跌%, 成交量, 成交额 —— 不带时点
            price = number(1)
            changePercent = number(3)
        }
        guard let price, price > 0 else { return nil }
        // 陈旧判定：美股/港股收盘价可能隔夜，给 96 小时宽限；超过就标注陈旧。
        let stale = stamp.map { now.timeIntervalSince($0) > 96 * 3600 } ?? false
        return GlobalIndexQuote(symbol: symbol, name: name, price: price,
                                changePercent: changePercent ?? 0,
                                previousClose: previousClose, observedAt: stamp, isStale: stale)
    }

    private static func date(from text: String, formats: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in formats {
            formatter.dateFormat = format
            if let value = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return value }
        }
        return nil
    }

    /// 拉取一次快照。新浪要求带 Referer，否则返回空。
    static func fetch(session: URLSession = .shared) async throws -> [GlobalIndexQuote] {
        let list = catalog.map { $0.symbol }.joined(separator: ",")
        guard let url = URL(string: endpoint + list) else { throw NextError.invalid("指数行情地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("指数行情源返回异常（\((response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无响应")）")
        }
        // 只解析数字字段，中文名称用本地目录，所以按 UTF-8 宽松解码即可。
        let body = String(decoding: data, as: UTF8.self)
        let quotes = parse(body)
        guard !quotes.isEmpty else { throw NextError.invalid("指数行情源没有返回可解析的数据") }
        return quotes
    }

    /// 单个指数快照：详情页进入时先用它把表头填满，不必等五个都到。
    static func fetchQuote(symbol: String, session: URLSession = .shared) async throws -> GlobalIndexQuote {
        guard let url = URL(string: endpoint + symbol) else { throw NextError.invalid("指数行情地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NextError.invalid("指数快照读取失败（\((response as? HTTPURLResponse).map { String($0.statusCode) } ?? "无响应")）")
        }
        guard let quote = parse(String(decoding: data, as: UTF8.self)).first else {
            throw NextError.invalid("指数快照没有可解析的数据")
        }
        return quote
    }
}

// MARK: - 指数走势（分时 / 日K）

/// 每个指数能取到什么粒度，全部写死在这张表里 —— 界面照实说，取不到就不画。
///
/// 2026-10-21 实测（逐个 curl 过）：
///
/// | 指数 | 分时 | 日K | 采用的源 |
/// |---|---|---|---|
/// | 上证指数 | ✓ | ✓ | 腾讯 `appstock`（sh000001） |
/// | 恒生科技 | ✓ | ✓ | 腾讯 `appstock`（hkHSTECH） |
/// | 日经225 | ✓ | ✓ | 东财 `trends2` / `kline`（100.N225） |
/// | 韩国KOSPI | ✓ | ✓ | 东财 `trends2` / `kline`（100.KS11） |
/// | 纳斯达克100 | ✗ | ✓ | 新浪美股 `getDailyK`（.NDX） |
///
/// 三个坑记在这里：
/// 1. **东财 `100.NDX` 不是纳指100**（26424 是纳斯达克综合），拿它画纳指100 会差 11%；
/// 2. 腾讯 `usNDX` 的分时只返回 1 个点、日K 只返回当天，**不能当走势用**；
/// 3. 东财分时的时间戳是**北京时间**（日经 08:00 = 东京 09:00），所以不能套 A 股 09:30–15:00 的固定横轴。
struct GlobalIndexCapability {
    let tencentCode: String?
    let eastmoneySecid: String?
    let sinaUSTicker: String?
    var hasMinute: Bool { tencentCode != nil || eastmoneySecid != nil }
    var hasDaily: Bool { tencentCode != nil || eastmoneySecid != nil || sinaUSTicker != nil }
    var minuteSource: String { tencentCode != nil ? "腾讯行情" : (eastmoneySecid != nil ? "东方财富" : "—") }
    var dailySource: String { tencentCode != nil ? "腾讯行情" : (eastmoneySecid != nil ? "东方财富" : "新浪美股") }
    /// 取不到的那一半，要在页面上说清楚，而不是留白让人以为是加载失败。
    var missingNote: String? {
        if !hasMinute { return "新浪美股接口只提供 \(GlobalIndexFeed.displayName("gb_$ndx")) 的日K，没有分钟序列；这里不画分时、也不伪造" }
        return nil
    }
}

enum GlobalIndexSeries {
    static func capability(for symbol: String) -> GlobalIndexCapability {
        switch symbol {
        case "s_sh000001": return GlobalIndexCapability(tencentCode: "sh000001", eastmoneySecid: nil, sinaUSTicker: nil)
        case "rt_hkHSTECH": return GlobalIndexCapability(tencentCode: "hkHSTECH", eastmoneySecid: nil, sinaUSTicker: nil)
        case "b_NKY": return GlobalIndexCapability(tencentCode: nil, eastmoneySecid: "100.N225", sinaUSTicker: nil)
        case "b_KOSPI": return GlobalIndexCapability(tencentCode: nil, eastmoneySecid: "100.KS11", sinaUSTicker: nil)
        case "gb_$ndx": return GlobalIndexCapability(tencentCode: nil, eastmoneySecid: nil, sinaUSTicker: ".NDX")
        default: return GlobalIndexCapability(tencentCode: nil, eastmoneySecid: nil, sinaUSTicker: nil)
        }
    }

    /// 分时。返回样本与昨收 —— 昨收是分时图 0 轴的基准，必须跟样本同源。
    static func minute(for symbol: String, session: URLSession = .shared) async throws -> (samples: [NextChartSample], previousClose: Decimal?) {
        let capability = capability(for: symbol)
        if let code = capability.tencentCode { return try await tencentMinute(code: code, session: session) }
        if let secid = capability.eastmoneySecid { return try await eastmoneyMinute(secid: secid, session: session) }
        throw NextError.invalid(capability.missingNote ?? "该指数没有分钟序列")
    }

    /// 日K。最多取 `count` 根，周K/月K 由图表自己按日期聚合。
    static func daily(for symbol: String, count: Int = 320, session: URLSession = .shared) async throws -> [NextChartSample] {
        let capability = capability(for: symbol)
        if let code = capability.tencentCode { return try await tencentDaily(code: code, count: count, session: session) }
        if let secid = capability.eastmoneySecid { return try await eastmoneyDaily(secid: secid, count: count, session: session) }
        if let ticker = capability.sinaUSTicker { return try await sinaUSDaily(ticker: ticker, session: session) }
        throw NextError.invalid("该指数没有可用的日K数据源")
    }

    // MARK: 腾讯 appstock（上证指数 / 恒生科技）

    private static func tencentMinute(code: String, session: URLSession) async throws -> (samples: [NextChartSample], previousClose: Decimal?) {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(code)") else { throw NextError.invalid("分时地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        // 不带 Referer 时上证指数会返回空 body（实测），恒生科技则不敏感。
        request.setValue("https://gu.qq.com/\(code)", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("分时源返回异常（\(code)）") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["data"] as? [String: Any])?[code] as? [String: Any],
              let wrapper = payload["data"] as? [String: Any],
              let rows = wrapper["data"] as? [String] else { throw NextError.invalid("分时源结构不认识（\(code)）") }
        let day = wrapper["date"] as? String ?? ""
        var samples: [NextChartSample] = []
        samples.reserveCapacity(rows.count)
        for row in rows {
            // "0930 3740.57 3116093 5839258150.10"
            let parts = row.split(separator: " ")
            guard parts.count >= 2, let price = decimal(String(parts[1])), price > 0 else { continue }
            guard let stamp = minuteStamp(day: day, clock: String(parts[0])) else { continue }
            let volume = parts.count >= 3 ? decimal(String(parts[2])) : nil
            samples.append(NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil, close: price, iopv: nil, volume: volume))
        }
        guard !samples.isEmpty else { throw NextError.invalid("分时源没有返回可解析的点（\(code)）") }
        let previous = ((payload["qt"] as? [String: Any])?[code] as? [Any]).map { row -> Decimal? in
            // 腾讯 qt 的真实排布：[0]市场 [1]名称 [2]代码 [3]现价 [4]昨收 [5]今开。
            // 拿 3 号位当昨收会让分时 0 轴落在现价上（整条线贴着中轴，涨跌看不出）。
            guard row.count > 4 else { return nil }
            return decimal("\(row[4])")
        } ?? nil
        return (samples, previous)
    }

    private static func tencentDaily(code: String, count: Int, session: URLSession) async throws -> [NextChartSample] {
        let limit = max(60, min(640, count))
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(code),day,,,\(limit),qfq") else { throw NextError.invalid("日K地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("https://gu.qq.com/\(code)", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("日K源返回异常（\(code)）") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["data"] as? [String: Any])?[code] as? [String: Any],
              let rows = (payload["qfqday"] ?? payload["day"]) as? [[Any]] else { throw NextError.invalid("日K源结构不认识（\(code)）") }
        let samples = rows.compactMap { row -> NextChartSample? in
            // [日期, 开, 收, 高, 低, 量]
            guard row.count >= 6,
                  let stamp = dayStamp("\(row[0])"),
                  let open = decimal("\(row[1])"), let close = decimal("\(row[2])"),
                  let high = decimal("\(row[3])"), let low = decimal("\(row[4])") else { return nil }
            return NextChartSample(timestamp: stamp, open: open, high: high, low: low, close: close, iopv: nil,
                                   volume: decimal("\(row[5])"))
        }
        guard !samples.isEmpty else { throw NextError.invalid("日K源没有返回可解析的K线（\(code)）") }
        return samples
    }

    // MARK: 东方财富（日经225 / 韩国KOSPI）

    private static func eastmoneyMinute(secid: String, session: URLSession) async throws -> (samples: [NextChartSample], previousClose: Decimal?) {
        let text = "https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f3,f4,f5,f6,f7,f8&fields2=f51,f53,f56,f58&iscr=0&ndays=1"
        guard let url = URL(string: text) else { throw NextError.invalid("分时地址无效") }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("分时源返回异常（\(secid)）") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let rows = payload["trends"] as? [String] else { throw NextError.invalid("分时源结构不认识（\(secid)）") }
        var samples: [NextChartSample] = []
        samples.reserveCapacity(rows.count)
        for row in rows {
            // "2026-10-21 08:00,64885.95,0,64885.950"
            let fields = row.split(separator: ",")
            guard fields.count >= 2, let price = decimal(String(fields[1])), price > 0 else { continue }
            guard let stamp = stamp("\(fields[0])", format: "yyyy-MM-dd HH:mm") else { continue }
            // 海外指数没有成交量（字段恒为 0），所以 volume 留空，副图不会画一条假柱子。
            samples.append(NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil, close: price, iopv: nil, volume: nil))
        }
        guard !samples.isEmpty else { throw NextError.invalid("分时源没有返回可解析的点（\(secid)）") }
        return (samples, decimal("\(payload["preClose"] ?? "")"))
    }

    private static func eastmoneyDaily(secid: String, count: Int, session: URLSession) async throws -> [NextChartSample] {
        let limit = max(60, min(640, count))
        let text = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=\(secid)&fields1=f1,f2,f3,f4,f5&fields2=f51,f52,f53,f54,f55,f56&klt=101&fqt=0&end=20500101&lmt=\(limit)"
        guard let url = URL(string: text) else { throw NextError.invalid("日K地址无效") }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("日K源返回异常（\(secid)）") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let rows = payload["klines"] as? [String] else { throw NextError.invalid("日K源结构不认识（\(secid)）") }
        let samples = rows.compactMap { row -> NextChartSample? in
            // "日期,开,收,高,低,量"
            let fields = row.split(separator: ",")
            guard fields.count >= 6, let stamp = dayStamp("\(fields[0])"),
                  let open = decimal(String(fields[1])), let close = decimal(String(fields[2])),
                  let high = decimal(String(fields[3])), let low = decimal(String(fields[4])) else { return nil }
            let volume = decimal(String(fields[5]))
            return NextChartSample(timestamp: stamp, open: open, high: high, low: low, close: close, iopv: nil,
                                   volume: (volume ?? 0) > 0 ? volume : nil)
        }
        guard !samples.isEmpty else { throw NextError.invalid("日K源没有返回可解析的K线（\(secid)）") }
        return samples
    }

    // MARK: 新浪美股（纳斯达克100，只有日K）

    private static func sinaUSDaily(ticker: String, session: URLSession) async throws -> [NextChartSample] {
        guard let url = URL(string: "https://stock.finance.sina.com.cn/usstock/api/json_v2.php/US_MinKService.getDailyK?symbol=\(ticker)") else { throw NextError.invalid("日K地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NextError.invalid("日K源返回异常（\(ticker)）") }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NextError.invalid("日K源结构不认识（\(ticker)）") }
        let samples = rows.compactMap { row -> NextChartSample? in
            guard let day = row["d"] as? String, let stamp = dayStamp(day),
                  let open = decimal(row["o"] as? String), let close = decimal(row["c"] as? String),
                  let high = decimal(row["h"] as? String), let low = decimal(row["l"] as? String) else { return nil }
            let volume = decimal(row["v"] as? String)
            return NextChartSample(timestamp: stamp, open: open, high: high, low: low, close: close, iopv: nil,
                                   volume: (volume ?? 0) > 0 ? volume : nil)
        }
        guard !samples.isEmpty else { throw NextError.invalid("日K源没有返回可解析的K线（\(ticker)）") }
        return samples.suffix(320).map { $0 }
    }

    // MARK: 解析小工具

    private static func decimal(_ text: String?) -> Decimal? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let value = Decimal(string: text), value.isFinite { return value }
        guard let double = Double(text), double.isFinite else { return nil }
        return Decimal(double)
    }

    private static func stamp(_ text: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static func dayStamp(_ text: String) -> Date? {
        stamp(text, format: "yyyy-MM-dd")
    }

    /// 腾讯分时的 "0930" + 日期 "20261021" 拼成时间戳。
    private static func minuteStamp(day: String, clock: String) -> Date? {
        guard day.count == 8, clock.count == 4 else { return nil }
        let text = "\(day.prefix(4))-\(day.dropFirst(4).prefix(2))-\(day.suffix(2)) \(clock.prefix(2)):\(clock.suffix(2))"
        return stamp(text, format: "yyyy-MM-dd HH:mm")
    }
}

