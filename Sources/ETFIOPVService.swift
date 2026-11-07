import Foundation

// MARK: - ETF 净值 / IOPV / 折溢价
//
// 数据真相（2026-11-06 收盘实测，两源互证）：
//
//   新浪  https://hq.sinajs.cn/list=fu_510300   （必须带 Referer）
//     → 华泰柏瑞沪深300ETF,16:05:00,4.1312,4.1909,1.8810,0,-1.4235,2026-11-06,4.0656,-2.989
//       0 名称 / 1 时间 / 2 单位净值(=IOPV) / 3 昨日净值 / 6 净值涨跌幅% / 7 日期
//
//   腾讯  https://qt.gtimg.cn/q=jj510300
//     → 510300~华泰柏瑞沪深300ETF~0.0000~0.0000~~4.1312~1.8589~-1.4245~2026-11-06~
//       5 单位净值（与新浪 4.1312 完全一致） / 7 净值涨跌幅% / 8 日期
//
// 折溢价不用第三方不明字段，自己算：(成交价 − 净值) / 净值。
// 盘中的单位净值就是 IOPV 口径的实时净值估值；收盘后是当日净值。
//
// 诚实约束：
//   · 每个读数都带来源与时间戳，时间戳过期一律标「净值过期」，不拿旧净值算今天折溢价。
//   · 名称字段是 GBK，本文件只取 ASCII 数字字段（名称用本地持仓名），不乱码也不臆造。
//   · 拿不到就返回 nil，界面显示「无 IOPV」，绝不用成交价冒充净值。

struct ETFIOPVSnapshot: Equatable {
    let code: String
    /// 单位净值（盘中即 IOPV 口径）。
    let nav: Double
    /// 净值对应时间。
    let navAt: Date?
    let previousNav: Double?
    let navChangePercent: Double?
    /// 数据来源，界面上必须显示，不允许匿名。
    let source: String
    let fetchedAt: Date
    /// 源里的原始日期文本，便于核对。
    let rawDateText: String?

    /// 折溢价百分数：正 = 溢价（偏贵），负 = 折价（偏便宜）。
    /// 价格或净值缺失时返回 nil —— 绝不填 0 假装「平价」。
    func premiumPercent(price: Double?) -> Double? {
        guard let price, price.isFinite, price > 0, nav.isFinite, nav > 0 else { return nil }
        return (price - nav) / nav * 100
    }

    var age: TimeInterval? {
        guard let navAt else { return nil }
        let seconds = Date().timeIntervalSince(navAt)
        return seconds.isFinite ? seconds : nil
    }
}

enum ETFIOPVService {
    /// 净值盘中容忍年龄（秒）。超过就认为折溢价读数不可信。
    static let maximumNavAge: TimeInterval = 90

    private static let sourceSina = "新浪 fu_ 净值接口"
    private static let sourceTencent = "腾讯 jj 净值接口"

    // MARK: - 抓取

    /// 先新浪、失败再腾讯。两源都失败返回 nil（不猜）。
    static func fetch(code: String, session: URLSession = .shared) async -> ETFIOPVSnapshot? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return nil }

        if let text = await request("https://hq.sinajs.cn/list=fu_\(trimmed)",
                                    referer: "https://finance.sina.com.cn",
                                    session: session),
           let snapshot = parseSinaFu(text, code: trimmed) {
            return snapshot
        }
        if let text = await request("https://qt.gtimg.cn/q=jj\(trimmed)",
                                    referer: "https://finance.qq.com",
                                    session: session),
           let snapshot = parseTencentFund(text, code: trimmed) {
            return snapshot
        }
        return nil
    }

    private static func request(_ urlString: String, referer: String,
                                session: URLSession) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // 名称段是 GBK，这里用 latin1 解码：数字与日期都是 ASCII，不受影响。
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 解析

    /// 从 `var hq_str_fu_510300="..."` 里取出引号内的载荷。
    static func payload(_ text: String) -> String? {
        guard let firstQuote = text.firstIndex(of: "\"") else { return nil }
        let rest = text[text.index(after: firstQuote)...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<endQuote])
    }

    static func parseSinaFu(_ text: String, code: String, fetchedAt: Date = Date()) -> ETFIOPVSnapshot? {
        guard let body = payload(text) else { return nil }
        let fields = body.components(separatedBy: ",")
        // 0 名称 / 1 时间 / 2 净值 / 3 昨日净值 / 6 净值涨跌幅 / 7 日期
        guard fields.count >= 8 else { return nil }
        guard let nav = number(fields[2]), nav > 0 else { return nil }

        let previousNav = number(fields[3]).flatMap { $0 > 0 ? $0 : nil }
        let change = number(fields[6])
        let dateText = fields[7].trimmingCharacters(in: .whitespaces)
        let timeText = fields[1].trimmingCharacters(in: .whitespaces)

        return ETFIOPVSnapshot(code: code,
                               nav: nav,
                               navAt: timestamp(date: dateText, time: timeText),
                               previousNav: previousNav,
                               navChangePercent: change,
                               source: sourceSina,
                               fetchedAt: fetchedAt,
                               rawDateText: dateText.isEmpty ? nil : dateText)
    }

    static func parseTencentFund(_ text: String, code: String, fetchedAt: Date = Date()) -> ETFIOPVSnapshot? {
        guard let body = payload(text) else { return nil }
        let fields = body.components(separatedBy: "~")
        // 5 净值 / 7 净值涨跌幅 / 8 日期
        guard fields.count >= 9 else { return nil }
        guard let nav = number(fields[5]), nav > 0 else { return nil }

        let change = number(fields[7])
        let dateText = fields[8].trimmingCharacters(in: .whitespaces)

        return ETFIOPVSnapshot(code: code,
                               nav: nav,
                               navAt: timestamp(date: dateText, time: "15:00:00"),
                               previousNav: nil,
                               navChangePercent: change,
                               source: sourceTencent,
                               fetchedAt: fetchedAt,
                               rawDateText: dateText.isEmpty ? nil : dateText)
    }

    // MARK: - 小工具

    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 净值时间按 A 股时区解释，避免手机时区导致「净值过期」误判。
    static func timestamp(date: String, time: String) -> Date? {
        let d = date.trimmingCharacters(in: .whitespaces)
        let t = time.trimmingCharacters(in: .whitespaces)
        guard d.count == 10, t.count >= 8 else { return nil }
        return dateFormatter.date(from: "\(d) \(t.prefix(8))")
    }
}

// MARK: - 股息率

/// 股息率只在「有年化每份分红 + 有价格」时成立。
/// 数据来源分两种，界面上必须写清是哪一种：
///   · 用户填的年化每份分红（Holdings 里的 annualDividendPerShare）—— 最可靠；
///   · 过去 12 个月已分红合计（现金流记录）—— 是实际派发，不是承诺。
enum DividendYieldCalculator {
    struct Result: Equatable {
        let yieldPercent: Double
        let annualDividendPerShare: Double
        let source: String
        let isUserProvided: Bool
    }

    static func yield(annualDividendPerShare: Double?, price: Double?) -> Result? {
        guard let perShare = annualDividendPerShare, perShare.isFinite, perShare >= 0, perShare > 0 else { return nil }
        guard let price, price.isFinite, price > 0 else { return nil }
        return Result(yieldPercent: perShare / price * 100,
                      annualDividendPerShare: perShare,
                      source: "按你填写的每份年分红 ÷ 现价",
                      isUserProvided: true)
    }

    /// 用过去 12 个月实际派发合计推股息率。样本不足一年时**不外推**，返回 nil。
    static func trailingYield(paidPerShareLast12Months: Double?,
                              monthsCovered: Int,
                              price: Double?) -> Result? {
        guard let paid = paidPerShareLast12Months, paid.isFinite, paid > 0 else { return nil }
        guard monthsCovered >= 12 else { return nil }
        guard let price, price.isFinite, price > 0 else { return nil }
        return Result(yieldPercent: paid / price * 100,
                      annualDividendPerShare: paid,
                      source: "按过去 12 个月实际每份派发 ÷ 现价",
                      isUserProvided: false)
    }

    /// 从账本里的分红事件推算过去 12 个月股息率。
    ///
    /// 诚实前提：只有「账本里最早的这条分红记录已超过 12 个月」才算窗口完整。
    /// 否则可能只是用户从半年前才开始记录，加起来会低估 —— 宁可返回 nil 也不外推。
    static func trailingYield(events: [ETFDividendEvent],
                              code: String,
                              price: Double?,
                              today: Date = Date()) -> Result? {
        guard let price, price.isFinite, price > 0 else { return nil }
        let rows: [(date: Date, amount: Double)] = events
            .filter { $0.code == code }
            .compactMap { event in
                guard let day = dayFormatter.date(from: event.date),
                      event.amountPerShare.isFinite, event.amountPerShare > 0 else { return nil }
                return (day, event.amountPerShare)
            }
        guard let earliest = rows.map(\.date).min() else { return nil }

        let oneYearAgo = today.addingTimeInterval(-365 * 86_400)
        guard earliest <= oneYearAgo else { return nil }

        let paid = rows
            .filter { $0.date > oneYearAgo && $0.date <= today }
            .reduce(0.0) { $0 + $1.amount }
        guard paid > 0 else { return nil }

        return Result(yieldPercent: paid / price * 100,
                      annualDividendPerShare: paid,
                      source: "按账本里过去 12 个月实际每份派发 ÷ 现价",
                      isUserProvided: false)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
