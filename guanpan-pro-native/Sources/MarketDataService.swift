import Foundation

/// 直连行情源（不经过 NAS）的多源 fallback。
///
/// 报价按代码逐源补齐缺口；分时与日 K 按优先级尝试首个完整有效来源。
/// 返回来源名供界面追溯；报价部分缺失会在结果中标出，不把缺少报价的证券伪装成已更新。
/// 源链与 NAS 服务端 server/market.py 完全一致，两端行为不分叉：
/// - 报价：腾讯 qt → 东财 ulist → 新浪 hq
/// - 分时：腾讯 minute → 东财 1 分钟 K 线
/// - 日 K：腾讯 newfqkline → 东财 kline → 新浪 getKLineData
enum NextMarketDataService {
    /// Phone-first portfolio headlines. Articles are treated as search results, not verified facts.
    /// Titles and links only are retained; the app never downloads article bodies.
    static func fetchNews(code: String, name: String, session: URLSession = .shared) async throws -> (value: [NextNewsInput], source: String) {
        guard code.count == 6, code.allSatisfy(\.isNumber),
              var components = URLComponents(string: "https://news.google.com/rss/search") else {
            throw NextError.invalid("证券代码或新闻请求地址无效")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: "\"\(name)\" ETF OR \(code)"),
            URLQueryItem(name: "hl", value: "zh-CN"),
            URLQueryItem(name: "gl", value: "CN"),
            URLQueryItem(name: "ceid", value: "CN:zh-Hans")
        ]
        guard let url = components.url else { throw NextError.invalid("新闻请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("GuanpanPro/3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NextError.invalid("手机新闻源暂不可用") }
        let parser = NextRSSNewsParser(data: data)
        guard parser.parse() else { throw NextError.invalid("手机新闻源响应格式无效") }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let futureLimit = Date().addingTimeInterval(2 * 60 * 60)
        let items = parser.items.compactMap { item -> NextNewsInput? in
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let rawDate = item.publishedAt, let date = NextRSSNewsParser.date(rawDate),
                  date >= cutoff, date <= futureLimit,
                  let rawURL = item.url, let parsedURL = URL(string: rawURL), parsedURL.scheme == "https" else { return nil }
            return NextNewsInput(title: String(title.prefix(300)), source: item.source,
                                 publishedAt: rawDate, url: parsedURL.absoluteString)
        }
        guard !items.isEmpty else { throw NextError.invalid("手机新闻源没有返回30天内且带有效时间和链接的标题") }
        return (Array(items.prefix(8)), "Google News RSS（手机直连·搜索聚合，未核实事实）")
    }

    static func fetchQuotes(codes: [String], session: URLSession = .shared) async throws -> (value: [NextQuote], source: String) {
        let result = try await NextMarketChain.fillMissing(requested: codes, attempts: [
            ("腾讯行情", { missing in try await tencentQuotes(codes: missing, session: session) }),
            ("东财行情", { missing in try await eastMoneyQuotes(codes: missing, session: session) }),
            ("新浪行情", { missing in try await sinaQuotes(codes: missing, session: session) })
        ], key: { $0.code })
        return (result.value, result.source)
    }

    static func fetchIntraday(code: String, now: Date = Date(), session: URLSession = .shared) async throws -> (value: NextChartDataset, source: String) {
        let marketOpen = NextMarketClock.isRegularSession(now)
        let attempts: [(source: String, run: () async throws -> NextChartDataset)] = [
            ("腾讯分时", {
                let data = try await tencentMinute(code: code, session: session)
                return try NextIntradayDatasetGuard.currentSessionOrThrow(data, now: now, marketOpen: marketOpen)
            }),
            ("东财分时", {
                let data = try await eastMoneyMinute(code: code, session: session)
                return try NextIntradayDatasetGuard.currentSessionOrThrow(data, now: now, marketOpen: marketOpen)
            })
        ]
        return try await NextMarketChain.richest(attempts, minimumSamples: 30) { $0.samples.count }
    }

    static func fetchDaily(code: String, now: Date = Date(), session: URLSession = .shared) async throws -> (value: NextChartDataset, source: String) {
        let attempts: [(source: String, run: () async throws -> NextChartDataset)] = [
            ("腾讯日K", {
                let data = try await tencentDaily(code: code, session: session)
                return try NextDailyDatasetGuard.currentHistoryOrThrow(data, now: now)
            }),
            ("东财日K", {
                let data = try await eastMoneyDaily(code: code, session: session)
                return try NextDailyDatasetGuard.currentHistoryOrThrow(data, now: now)
            }),
            ("新浪日K", {
                let data = try await sinaDaily(code: code, session: session)
                return try NextDailyDatasetGuard.currentHistoryOrThrow(data, now: now)
            })
        ]
        return try await NextMarketChain.richest(attempts, minimumSamples: 120) { $0.samples.count }
    }

    // MARK: - 报价

    private static func tencentQuotes(codes: [String], session: URLSession) async throws -> [NextQuote] {
        let symbols = codes.compactMap(NextTencentQuoteParser.symbol(for:))
        guard !symbols.isEmpty, symbols.count == codes.count else { throw NextError.invalid("证券代码无效或交易所来源尚未支持") }
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(symbols.joined(separator: ","))&_t=\(Int(Date().timeIntervalSince1970))") else { throw NextError.invalid("腾讯行情请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NextError.invalid("腾讯行情服务暂不可用") }
        let receivedAt = Date()
        let quotes = codes.compactMap { NextTencentQuoteParser.parse(data, code: $0, receivedAt: receivedAt) }
        guard !quotes.isEmpty else { throw NextError.invalid("腾讯行情响应未通过代码、价格或时间校验") }
        return quotes
    }

    private static func eastMoneyQuotes(codes: [String], session: URLSession) async throws -> [NextQuote] {
        let secids = codes.compactMap(NextEastMoneySymbol.secid(for:))
        guard secids.count == codes.count, !secids.isEmpty else { throw NextError.invalid("证券代码无效或交易所来源尚未支持") }
        guard var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get") else { throw NextError.invalid("东财行情请求地址无效") }
        components.queryItems = [
            URLQueryItem(name: "fields", value: "f12,f13,f14,f2,f3,f4,f6,f60"),
            URLQueryItem(name: "secids", value: secids.joined(separator: ",")),
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "np", value: "1")
        ]
        guard let url = components.url else { throw NextError.invalid("东财行情请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NextError.invalid("东财行情服务暂不可用") }
        let receivedAt = Date()
        let quotes = NextEastMoneyQuoteParser.parse(data, codes: codes, receivedAt: receivedAt)
        guard !quotes.isEmpty else { throw NextError.invalid("东财行情响应未通过代码、价格或时间校验") }
        return quotes
    }

    private static func sinaQuotes(codes: [String], session: URLSession) async throws -> [NextQuote] {
        let symbols = codes.compactMap(NextTencentQuoteParser.symbol(for:))
        guard symbols.count == codes.count, !symbols.isEmpty else { throw NextError.invalid("证券代码无效或交易所来源尚未支持") }
        guard var components = URLComponents(string: "https://hq.sinajs.cn/list/\(symbols.joined(separator: ","))") else { throw NextError.invalid("新浪行情请求地址无效") }
        components.queryItems = [URLQueryItem(name: "_t", value: "\(Int(Date().timeIntervalSince1970))")]
        guard let url = components.url else { throw NextError.invalid("新浪行情请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NextError.invalid("新浪行情服务暂不可用") }
        let quotes = NextSinaQuoteParser.parse(data, codes: codes)
        guard !quotes.isEmpty else { throw NextError.invalid("新浪行情响应未通过代码、价格或时间校验") }
        return quotes
    }

    // MARK: - 分时

    private static func tencentMinute(code: String, session: URLSession) async throws -> NextChartDataset {
        guard let symbol = NextTencentQuoteParser.symbol(for: code),
              var components = URLComponents(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query") else {
            throw NextError.invalid("证券代码无效")
        }
        components.queryItems = [URLQueryItem(name: "code", value: symbol), URLQueryItem(name: "_var", value: "min_data_\(symbol)")]
        guard let url = components.url else { throw NextError.invalid("腾讯分时请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let chart = NextTencentMinuteParser.parse(data, code: code, receivedAt: receivedAt) else {
            throw NextError.invalid("腾讯分时数据没有通过响应、时间或价格校验")
        }
        return chart
    }

    private static func eastMoneyMinute(code: String, session: URLSession) async throws -> NextChartDataset {
        guard let secid = NextEastMoneySymbol.secid(for: code) else { throw NextError.invalid("证券代码无效") }
        guard var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get") else { throw NextError.invalid("东财分时请求地址无效") }
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58"),
            URLQueryItem(name: "klt", value: "1"),
            URLQueryItem(name: "fqt", value: "0"),
            URLQueryItem(name: "end", value: "20500101"),
            URLQueryItem(name: "lmt", value: "240")
        ]
        guard let url = components.url else { throw NextError.invalid("东财分时请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let chart = NextEastMoneyKlineParser.parse(data, code: code, mode: .minute, priceSource: "EastMoney 分时 · 1分钟粒度", receivedAt: receivedAt) else {
            throw NextError.invalid("东财分时数据没有通过响应、时间或价格校验")
        }
        return chart
    }

    // MARK: - 日 K

    private static func tencentDaily(code: String, session: URLSession) async throws -> NextChartDataset {
        guard let symbol = NextTencentQuoteParser.symbol(for: code) else { throw NextError.invalid("证券代码无效") }
        guard var components = URLComponents(string: "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get") else { throw NextError.invalid("腾讯日K请求地址无效") }
        components.queryItems = [URLQueryItem(name: "param", value: "\(symbol),day,,,640,qfq")]
        guard let url = components.url else { throw NextError.invalid("腾讯日K请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let dataset = NextTencentDailyParser.parse(data, code: code, receivedAt: receivedAt) else {
            throw NextError.invalid("腾讯日 K 数据没有通过响应、代码、价格或时间校验")
        }
        return dataset
    }

    private static func eastMoneyDaily(code: String, session: URLSession) async throws -> NextChartDataset {
        guard let secid = NextEastMoneySymbol.secid(for: code) else { throw NextError.invalid("证券代码无效") }
        guard var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get") else { throw NextError.invalid("东财日K请求地址无效") }
        components.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58"),
            URLQueryItem(name: "klt", value: "101"),
            URLQueryItem(name: "fqt", value: "1"),
            URLQueryItem(name: "end", value: "20500101"),
            URLQueryItem(name: "lmt", value: "640")
        ]
        guard let url = components.url else { throw NextError.invalid("东财日K请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let dataset = NextEastMoneyKlineParser.parse(data, code: code, mode: .daily, priceSource: "EastMoney 日K · 前复权", receivedAt: receivedAt) else {
            throw NextError.invalid("东财日 K 数据没有通过响应、代码、价格或时间校验")
        }
        return dataset
    }

    private static func sinaDaily(code: String, session: URLSession) async throws -> NextChartDataset {
        guard let symbol = NextTencentQuoteParser.symbol(for: code) else { throw NextError.invalid("证券代码无效") }
        guard var components = URLComponents(string: "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketDataService.getKLineData") else { throw NextError.invalid("新浪日K请求地址无效") }
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "scale", value: "240"),
            URLQueryItem(name: "ma", value: "no"),
            URLQueryItem(name: "datalen", value: "320")
        ]
        guard let url = components.url else { throw NextError.invalid("新浪日K请求地址无效") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let dataset = NextSinaDailyParser.parse(data, code: code, receivedAt: receivedAt) else {
            throw NextError.invalid("新浪日 K 数据没有通过响应、代码、价格或时间校验")
        }
        return dataset
    }
}

private final class NextRSSNewsParser: NSObject, XMLParserDelegate {
    struct Item { var title: String?; var url: String?; var publishedAt: String?; var source: String? }
    private let data: Data
    private var current: Item?
    private var currentElement = ""
    private var text = ""
    private(set) var items: [Item] = []

    init(data: Data) { self.data = data }

    func parse() -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        text = ""
        if currentElement == "item" { current = Item() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "title": current?.title = value
        case "link": current?.url = value
        case "pubdate": current?.publishedAt = value
        case "source": current?.source = value
        case "item":
            if let item = current { items.append(item) }
            current = nil
        default: break
        }
        currentElement = ""
        text = ""
    }

    static func date(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}
