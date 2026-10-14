import Foundation
import CryptoKit

/// 把 App 的原生账本写成「网页版（观盘.html）」的 `/api/data` 格式。
///
/// **三条硬规则**（用户要求：数据要准确，不能乱来）：
///
/// 1. **字段名以 App 自己的网页账本读取器为准**（`LegacyMigration.decodePackage`）——
///    能被正确读回来的名字，才拿去写，避免「写得进、读不出」。
///    例子：场外分红记录的 `side` 网页端写的是 `div` 而不是 `dividend`；
///    交易记录的日期字段，`db.trades` 用 `date`、旧版 `tr` 用 `d` —— 两边不一样，必须分开写。
/// 2. **只替换账本相关的键**：`_v` / `_t` / `cash` / `db`（只动 `watch`、`hold`、`trades`）/
///    `tr` / `fund`（只动 `hold`、`trades`）/ `fundnav` / `cashlog` / `snap` / `mp`。
///    其余键 —— `cfg` 设置、`div` 分红参考、`fx` 汇率、`hol` 自定义休市日、`tgt` 止盈止损、
///    `profile`、`ai`、`gridhist`、`gridmeta` —— **原样沿用 NAS 上那份现值**，一概不碰。
/// 3. **同 code 的条目逐项合并**：先取 NAS 上原有那条为底，再覆盖 App 管得到的字段。
///    这样网页那边独有的字段（`hold[].tp/sl/wmax/maw`、`fund.hold[].feeMode/feeR`）不会丢。
///
/// 本转换器**只负责生成文档**，不做任何网络请求；读旧文档、写回、备份都由调用方负责。
enum WebLedgerWriter {

    /// 生成要写回的网页账本文档。
    /// - Parameters:
    ///   - data: 本机原生账本（唯一真相）。
    ///   - existing: NAS 上现有那份网页账本的原样内容；传 `nil` 表示服务器上没有（新建一份）。
    static func document(from data: PortfolioData,
                         merging existing: [String: Any]?,
                         now: Date = .now) -> [String: Any] {
        var document = existing ?? [:]
        document["_v"] = 3
        document["_t"] = isoTimestamp(now)
        document["cash"] = number(data.cash)

        // ── 场内：自选 / 持仓 / 交易记录 ──────────────────────────────────
        let previousDB = existing?["db"] as? [String: Any]
        let previousWatch = byCode(previousDB?["watch"])
        let previousHold = byCode(previousDB?["hold"])

        var db = previousDB ?? [:]
        db["watch"] = data.quotes.map { quote in
            merge(previousWatch[quote.code], [
                "code": quote.code,
                "name": quote.name,
                "price": number(quote.price),
                "pct": number(quote.changePct * 100),
            ])
        }
        db["hold"] = data.holdings.filter { $0.kind == .etf }.map { holding in
            var row: [String: Any] = [
                "code": holding.code,
                "name": holding.name,
                "cost": number(holding.cost),
                "num": number(holding.quantity),
            ]
            if let lock = holding.costOverride, lock.isFinite, lock > 0 { row["costLock"] = lock }
            return merge(previousHold[holding.code], row)
        }
        let exchangeTrades = data.ledger.filter { ($0.kind ?? .etf) == .etf }
        db["trades"] = exchangeTrades.map(webTradeRow)
        document["db"] = db
        // 旧版 `tr` 与 `db.trades` 是网页端两套并行的交易记录（字段名不同），
        // 网页的「交易记录 / 已实现盈亏」读 `tr`，成本与持仓核对读 `db.trades` —— 两套都要写。
        document["tr"] = exchangeTrades.map(legacyTradeRow)

        // ── 场外基金 ──────────────────────────────────────────────────
        document["fund"] = fundSection(data, existing: existing)
        document["fundnav"] = navSection(data)
        document["cashlog"] = data.cashFlows.filter { $0.amount != 0 }.map(cashLogRow)
        document["snap"] = data.snapshots.map(snapshotRow)
        document["mp"] = manualPriceSection(data)
        return document
    }

    // MARK: - 内容指纹（决定「要不要写这一趟」）

    /// 网页账本的**内容指纹**：只覆盖真正会被写进 `/api/data` 的账本字段。
    ///
    /// 它回答的是一个问题：**这一次还有必要发请求吗？**
    /// 所以下面三类东西必须排除，否则流量会被白白烧掉（用户原话：
    /// 「那也不能一直刷新呀，一直同步呀，多浪费我的穿透流量，应该是更改了才同步吧」）：
    ///
    /// 1. **高频行情缓存**：`db.watch[].price/pct`、`snap[].total/mv`。
    ///    它们每一轮行情刷新都会变，但行情与当日估值两边本来就各算各的 ——
    ///    「日内的持仓盈亏这些，两边都会自动变的，不需要实时同步」。
    ///    注意 `snap` 里的**日期与现金**仍然参与（那是账本事实，不是估值派生）。
    /// 2. **分钟 / 日 K 档案**：网页账本里根本没有这两个键（它们只走原生账本文档），
    ///    而交易时段每分钟都在长。
    /// 3. `_t` 写入时间戳：每次调用都会变，纯噪声。
    ///
    /// 剩下的（现金、自选成员与名称、持仓份额与成本、交易流水、场外持仓与流水、
    /// 基金净值历史、资金流水、快照日期、手填价）都是「你不编辑就不会变」的，
    /// 这才叫「更改了才同步」。
    ///
    /// 用 `sortedKeys` 序列化：字典键顺序在 Swift 里不保证稳定，不排序会随进程漂移。
    static func ledgerFingerprint(of data: PortfolioData) -> String {
        var document = document(from: data, merging: nil, now: Date(timeIntervalSince1970: 0))
        document.removeValue(forKey: "_t")
        if var db = document["db"] as? [String: Any] {
            if var watch = db["watch"] as? [[String: Any]] {
                for index in watch.indices {
                    watch[index].removeValue(forKey: "price")
                    watch[index].removeValue(forKey: "pct")
                }
                db["watch"] = watch
            }
            document["db"] = db
        }
        if var snap = document["snap"] as? [[String: Any]] {
            for index in snap.indices {
                snap[index].removeValue(forKey: "total")
                snap[index].removeValue(forKey: "mv")
            }
            document["snap"] = snap
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else {
            return ""
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 场内

    /// 网页 `db.trades` 的一行：`date` / `num` / `amt` / `pnl` / `cashLinked`。
    private static func webTradeRow(_ entry: LedgerEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "date": dayString(entry.date),
            "code": entry.code,
            "name": entry.name,
            "side": entry.side.rawValue,
            "price": number(entry.price),
            "num": number(entry.quantity),
            "amt": number(entry.quantity * entry.price),
            "fee": number(entry.fee),
            "pnl": entry.side == .sell ? number(entry.realizedPnL) : 0,
            "cashLinked": entry.linkedCash,
        ]
    }

    /// 旧版 `tr` 的一行：日期字段叫 `d`，只有网页记交易记录时用的那几个字段。
    private static func legacyTradeRow(_ entry: LedgerEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "code": entry.code,
            "side": entry.side.rawValue,
            "d": dayString(entry.date),
            "price": number(entry.price),
            "num": number(entry.quantity),
            "fee": number(entry.fee),
        ]
    }

    // MARK: - 场外

    private static func fundSection(_ data: PortfolioData, existing: [String: Any]?) -> [String: Any] {
        let previousFund = existing?["fund"] as? [String: Any]
        let previousHold = byCode(previousFund?["hold"])
        let latestNAV = latestNAVByCode(data.fundNAVHistory)
        var policyByCode: [String: FundFeePolicy] = [:]
        for policy in data.fundFeePolicies { policyByCode[policy.code] = policy }

        var fund = previousFund ?? [:]
        fund["hold"] = data.holdings.filter { $0.kind == .fund }.map { holding in
            var row: [String: Any] = [
                "code": holding.code,
                "name": holding.name,
                "cost": number(holding.cost),
                "shares": number(holding.quantity),
            ]
            if let point = latestNAV[holding.code] {
                row["nav"] = point.nav
                row["navDate"] = point.date
            }
            // 网页那边的费率表固定是 0 / 7 / 30 / 365 / 730 五档，只有五档齐全才写，
            // 免得写进去一张半截表把网页原来的费率设置弄坏。
            if let policy = policyByCode[holding.code] {
                var table: [String: Any] = [:]
                for band in policy.bands { table[String(band.minimumHoldingDays)] = number(band.ratePercent) }
                let required = [0, 7, 30, 365, 730]
                if required.allSatisfy({ table[String($0)] != nil }) { row["feeTable"] = table }
            }
            return merge(previousHold[holding.code], row)
        }
        fund["trades"] = data.fundTransactions.map(fundTradeRow)
        return fund
    }

    /// 网页 `fund.trades` 的一行。注意 `side` 网页端用 `div` 表示分红，不是 `dividend`。
    private static func fundTradeRow(_ entry: FundTransaction) -> [String: Any] {
        let side: String
        switch entry.side {
        case .buy: side = "buy"
        case .sell: side = "sell"
        case .dividend: side = "div"
        }
        var row: [String: Any] = [
            "id": entry.id.uuidString,
            "code": entry.code,
            "name": entry.name,
            "side": side,
            "date": entry.requestDate,
            "settleDate": entry.effectiveDate,
            "shares": number(entry.quantity),
            "nav": number(entry.nav),
            "amt": number(entry.amount),
            "fee": number(entry.fee),
            "status": entry.status == .pending ? "pending" : "done",
        ]
        if entry.linkedCash { row["cashSrc"] = "cash" }
        return row
    }

    /// 场外净值历史：`{代码: [{date, nav}]}`。每只最多写最近 500 个点，
    /// 够网页画几年曲线，又不至于让同步包膨胀到几兆。
    private static func navSection(_ data: PortfolioData) -> [String: Any] {
        var grouped: [String: [FundNAVPoint]] = [:]
        for point in data.fundNAVHistory where point.nav.isFinite && point.nav > 0 {
            grouped[point.code, default: []].append(point)
        }
        var result: [String: Any] = [:]
        for (code, points) in grouped {
            let rows: [[String: Any]] = points.sorted { $0.date < $1.date }.suffix(500).map {
                ["date": $0.date, "nav": $0.nav]
            }
            if !rows.isEmpty { result[code] = rows }
        }
        return result
    }

    private static func latestNAVByCode(_ history: [FundNAVPoint]) -> [String: FundNAVPoint] {
        var result: [String: FundNAVPoint] = [:]
        for point in history {
            guard point.nav.isFinite, point.nav > 0 else { continue }
            if let existing = result[point.code] {
                if point.date > existing.date { result[point.code] = point }
            } else {
                result[point.code] = point
            }
        }
        return result
    }

    // MARK: - 现金流水 / 快照 / 手填价

    /// 网页 `cashlog` 的一行：`amt` / `type` / `note` / `internal`。
    private static func cashLogRow(_ flow: CashFlow) -> [String: Any] {
        var row: [String: Any] = [
            "id": flow.id.uuidString,
            "type": flow.amount >= 0 ? "in" : "out",
            "amt": abs(number(flow.amount)),
            "date": dayString(flow.date),
            "note": flow.memo,
        ]
        // 网页用 `internal === 'fund'` 表示「账本内部转账，不算外部资金流入」。
        if flow.external == false { row["internal"] = "fund" }
        return row
    }

    private static func snapshotRow(_ snapshot: PortfolioSnapshot) -> [String: Any] {
        [
            "d": snapshot.date,
            "scope": "all",
            "cash": number(snapshot.cash),
            "total": number(snapshot.total),
            "mv": number(snapshot.total - snapshot.cash),
        ]
    }

    private static func manualPriceSection(_ data: PortfolioData) -> [String: Any] {
        var result: [String: Any] = [:]
        for (code, override) in data.manualQuoteOverrides
        where override.price.isFinite && override.price > 0 && !code.isEmpty {
            var row: [String: Any] = ["price": override.price]
            if let previous = override.previousClose, previous.isFinite, previous > 0 {
                row["prev"] = previous
            }
            result[code] = row
        }
        return result
    }

    // MARK: - 工具

    private static func number(_ value: Double) -> Double { value.isFinite ? value : 0 }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 同 code 逐项合并：以 NAS 上原有那条为底，覆盖 App 管得到的字段。
    private static func merge(_ previous: [String: Any]?, _ overrides: [String: Any]) -> [String: Any] {
        var row = previous ?? [:]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    private static func byCode(_ raw: Any?) -> [String: [String: Any]] {
        guard let rows = raw as? [[String: Any]] else { return [:] }
        var result: [String: [String: Any]] = [:]
        for row in rows {
            guard let code = row["code"] as? String, !code.isEmpty else { continue }
            result[code] = row
        }
        return result
    }
}
