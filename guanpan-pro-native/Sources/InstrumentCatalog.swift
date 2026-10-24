import Foundation

// MARK: - 内置证券目录（离线名称搜索）

/// 内置的常用场内证券目录。
///
/// 存在的理由很具体：名称搜索以前只能搜「自选 + 持仓 + 已缓存报价」，
/// 新用户输入「红利」什么都搜不到，只能先知道 6 位代码。这份目录让常见标的
/// 可以按名称/拼音首字母直接命中；**它不是行情源**，只提供代码与名称。
/// 行情仍然按代码向 NAS 或腾讯请求，目录里没有的代码照旧可以手输。
struct CatalogInstrument: Identifiable, Equatable {
    let code: String
    let name: String
    /// 拼音首字母，便于输入 hb 找到「红利」类标的。
    let initials: String
    var id: String { code }
}

enum InstrumentCatalog {
    static let all: [CatalogInstrument] = [
        // 宽基
        .init(code: "510300", name: "沪深300ETF", initials: "hs300"),
        .init(code: "510500", name: "中证500ETF", initials: "zz500"),
        .init(code: "510050", name: "上证50ETF", initials: "sz50"),
        .init(code: "159915", name: "创业板ETF", initials: "cyb"),
        .init(code: "588000", name: "科创50ETF", initials: "kc50"),
        .init(code: "159352", name: "A500ETF", initials: "a500"),
        .init(code: "512100", name: "中证1000ETF", initials: "zz1000"),
        // 红利
        .init(code: "515180", name: "红利ETF", initials: "hl"),
        .init(code: "510880", name: "红利ETF易方达", initials: "hl"),
        .init(code: "563020", name: "低波红利ETF", initials: "dbhl"),
        .init(code: "159545", name: "港股红利ETF", initials: "gghl"),
        .init(code: "512890", name: "红利低波100ETF", initials: "hldb"),
        // 跨境
        .init(code: "159941", name: "纳指ETF", initials: "nz"),
        .init(code: "513100", name: "纳指100ETF", initials: "nz100"),
        .init(code: "513500", name: "标普500ETF", initials: "bp500"),
        .init(code: "513050", name: "中概互联ETF", initials: "zghl"),
        .init(code: "513130", name: "恒生科技ETF", initials: "hkst"),
        .init(code: "513180", name: "恒生科技指数ETF", initials: "hkst"),
        .init(code: "159920", name: "恒生ETF", initials: "hs"),
        .init(code: "513030", name: "德国30ETF", initials: "dg30"),
        .init(code: "513520", name: "日经225ETF", initials: "rj225"),
        // 行业
        .init(code: "512880", name: "证券ETF", initials: "zq"),
        .init(code: "512800", name: "银行ETF", initials: "yh"),
        .init(code: "512010", name: "医药ETF", initials: "yy"),
        .init(code: "159928", name: "消费ETF", initials: "xf"),
        .init(code: "512690", name: "酒ETF", initials: "j"),
        .init(code: "515790", name: "光伏ETF", initials: "gf"),
        .init(code: "515030", name: "新能源车ETF", initials: "xnyc"),
        .init(code: "512480", name: "半导体ETF", initials: "bdt"),
        .init(code: "512760", name: "芯片ETF", initials: "xp"),
        .init(code: "159995", name: "芯片ETF华夏", initials: "xp"),
        .init(code: "512660", name: "军工ETF", initials: "jg"),
        .init(code: "159611", name: "电力ETF", initials: "dl"),
        .init(code: "516970", name: "基建ETF", initials: "jj"),
        // 债券 / 黄金 / 其他
        .init(code: "511010", name: "国债ETF", initials: "gz"),
        .init(code: "511260", name: "十年国债ETF", initials: "gz"),
        .init(code: "518880", name: "黄金ETF", initials: "hj"),
        .init(code: "511990", name: "华宝添益", initials: "hbt"),
        // 指数（只作看板/基准，不可交易）
        .init(code: "000001", name: "上证指数", initials: "szzs"),
        .init(code: "000300", name: "沪深300", initials: "hs300"),
        .init(code: "000905", name: "中证500", initials: "zz500"),
        .init(code: "399006", name: "创业板指", initials: "cybz")
    ]

    /// 名称或拼音首字母匹配。空关键字返回空数组，避免把整个目录倒出来。
    static func search(_ keyword: String, limit: Int = 12) -> [CatalogInstrument] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return all.filter { item in
            item.code.hasPrefix(query)
                || item.name.localizedCaseInsensitiveContains(query)
                || item.initials.lowercased().hasPrefix(query)
        }
        .prefix(limit)
        .map { $0 }
    }

    static func name(for code: String) -> String? {
        all.first { $0.code == code }?.name
    }
}

// MARK: - 持仓分组（自动分类，不需要用户维护标签）

/// 自动分组：按代码前缀与名称归类。
/// 之所以不让用户手工打标签：一开始没人愿意填，而按标的类型分组本身就有稳定口径，
/// 用来回答「我的仓位是压在宽基上还是全在行业主题上」已经够用。
enum NextInstrumentGroup: String, CaseIterable, Identifiable {
    case broad = "宽基"
    case dividend = "红利"
    case overseas = "跨境"
    case sector = "行业主题"
    case bond = "债券/货币"
    case commodity = "商品"
    case equity = "个股"
    case other = "其他"
    var id: String { rawValue }

    static func classify(code: String, name: String = "") -> NextInstrumentGroup {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return .other }
        let label = name + (InstrumentCatalog.name(for: code) ?? "")
        if label.contains("红利") || label.contains("低波") { return .dividend }
        if label.contains("国债") || label.contains("添益") || label.contains("货币") || label.contains("债") { return .bond }
        if label.contains("黄金") || label.contains("豆粕") || label.contains("原油") { return .commodity }
        if ["513", "159920", "159941"].contains(where: { code.hasPrefix($0) }) || label.contains("纳指") || label.contains("标普") || label.contains("恒生") || label.contains("德国") || label.contains("日经") || label.contains("中概") {
            return .overseas
        }
        let isFund = ["15", "16", "18", "50", "51", "52", "56", "58", "59"].contains { code.hasPrefix($0) }
        if !isFund { return .equity }
        if label.contains("300") || label.contains("500") || label.contains("50") || label.contains("1000") || label.contains("A500") || label.contains("创业板") || label.contains("科创") {
            return .broad
        }
        return .sector
    }
}

// MARK: - 前复权

/// 前复权：把「除息日之后才发生的每份派息」从历史价格里扣掉，让 K 线连续。
///
/// 只做**分红复权**，不做送股/拆股（场内 ETF 基本没有拆股，且行情源未提供股本变动）。
/// 最新一根保持原值，历史价下调 —— 这就是券商的「前复权」观感。
/// 复权只影响画图与均线，不改账本、不改成本、不改盈亏。
enum NextPriceAdjustment {
    static func forwardAdjusted(_ samples: [NextChartSample], events: [NextETFDividendEvent], code: String) -> [NextChartSample] {
        let relevant = events.filter { $0.code == code && $0.isEstimated != true }
        guard !relevant.isEmpty else { return samples }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let dated = relevant.compactMap { event -> (Date, Decimal)? in
            guard let day = formatter.date(from: event.date) else { return nil }
            return (day, event.amountPerShare)
        }.sorted { $0.0 < $1.0 }
        guard !dated.isEmpty else { return samples }
        return samples.map { sample in
            // 该样本之后发生的派息总额，就是需要扣掉的复权金额。
            let later = dated.filter { $0.0 > sample.timestamp }.reduce(Decimal.zero) { $0 + $1.1 }
            guard later > 0 else { return sample }
            func adjust(_ value: Decimal?) -> Decimal? {
                guard let value else { return nil }
                return max(0, value - later)
            }
            return NextChartSample(timestamp: sample.timestamp,
                                   open: adjust(sample.open), high: adjust(sample.high),
                                   low: adjust(sample.low), close: max(0, sample.close - later),
                                   iopv: sample.iopv, volume: sample.volume)
        }
    }
}

// MARK: - CSV 导出

enum NextCSVExport {
    /// 生成一份可被 Excel 直接打开的 CSV（含 BOM，避免中文乱码）。
    static func text(book: NextBook, quotes: [String: NextCachedQuote]) -> String {
        var lines: [String] = []
        lines.append("类型,代码,名称,方向,数量,价格,金额,手续费,已实现,日期,备注")
        for position in book.positions {
            let price = quotes[position.code]?.quote.price ?? 0
            let value = price * Decimal(position.units)
            lines.append(row(["持仓", position.code, position.name, "", String(position.units),
                              price > 0 ? plain(price) : "", plain(value), "",
                              plain(position.bookCost), "", "账本成本"]))
        }
        for fill in book.fills.sorted(by: { $0.date > $1.date }) {
            lines.append(row(["成交", fill.code, "", fill.side == "buy" ? "买入" : "卖出", String(fill.units),
                              plain(fill.price), plain(fill.price * Decimal(fill.units)),
                              plain(fill.fee), plain(fill.realized),
                              day(fill.date), ""]))
        }
        for income in book.incomeEvents.sorted(by: { $0.payDate > $1.payDate }) {
            lines.append(row(["收益", income.code ?? "", income.name, income.kind.title, "",
                              income.perUnit.map(plain) ?? "", plain(income.grossAmount),
                              plain(income.tax), plain(income.netAmount),
                              day(income.payDate), income.status.title]))
        }
        for movement in book.cashMovements.sorted(by: { $0.date > $1.date }) {
            lines.append(row(["现金", "", movement.reason, "", "", "", plain(movement.amount), "", "", day(movement.date), ""]))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    /// 写到临时目录并返回 URL，供 ShareLink 使用。文件名带日期，避免覆盖。
    static func write(book: NextBook, quotes: [String: NextCachedQuote]) -> URL? {
        let text = text(book: book, quotes: quotes)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("观盘账本-\(formatter.string(from: Date())).csv")
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func row(_ values: [String]) -> String {
        values.map { value in
            let needsQuote = value.contains(",") || value.contains("\"") || value.contains("\n")
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return needsQuote ? "\"\(escaped)\"" : escaped
        }.joined(separator: ",")
    }

    private static func plain(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 业绩基准

struct NextBenchmarkQuote: Identifiable, Equatable {
    let code: String
    let name: String
    var id: String { code }
}

enum NextBenchmark {
    /// 只放能被 NAS 日 K 接口取到的 6 位代码，避免出现「选了但没数据」。
    static let options: [NextBenchmarkQuote] = [
        .init(code: "000300", name: "沪深300"),
        .init(code: "000905", name: "中证500"),
        .init(code: "000001", name: "上证指数")
    ]

    /// 用与组合相同的起止日期算基准涨幅（取区间内最近的两根日 K）。
    static func returnPercent(samples: [NextChartSample], from start: Date, to end: Date) -> Double? {
        let ordered = samples.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first(where: { $0.timestamp >= start }) ?? ordered.first,
              let last = ordered.last(where: { $0.timestamp <= end }) ?? ordered.last,
              first.timestamp < last.timestamp else { return nil }
        let startClose = NextNum.double(first.close)
        let endClose = NextNum.double(last.close)
        guard startClose > 0 else { return nil }
        return (endClose / startClose - 1) * 100
    }
}
