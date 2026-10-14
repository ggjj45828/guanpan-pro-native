import Foundation

@MainActor
extension PortfolioStore {
    func setLegacyShadowActive(_ archive: LegacyShadowArchive, active: Bool) {
        guard let index = data.legacyShadowArchives.firstIndex(where: { $0.id == archive.id }),
              !data.legacyShadowArchives[index].closed else { return }
        data.legacyShadowArchives[index].active = active
        // Reset the crossing baseline on resume so a paused interval cannot create
        // a synthetic fill when the next quote arrives.
        data.legacyShadowArchives[index].lastPrice = 0
        data.legacyShadowArchives[index].lastTimestamp = ""
        save(label: "启停旧版模拟网格")
    }

    func advanceLegacyShadowSimulations(_ quotes: [(String, Double, Date)]) {
        let byCode = Dictionary(quotes.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { _, latest in latest })
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter(); timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); timeFormatter.dateFormat = "HH:mm:ss"

        for index in data.legacyShadowArchives.indices {
            var shadow = data.legacyShadowArchives[index]
            guard !shadow.closed, let (price, timestamp) = byCode[shadow.code],
                  price.isFinite, price > 0 else { continue }
            let day = dayFormatter.string(from: timestamp)
            let time = timeFormatter.string(from: timestamp)
            let stamp = "\(day) \(time)"
            let previous = shadow.lastPrice > 0 ? shadow.lastPrice : price
            let dayIndex: Int
            if let found = shadow.days.firstIndex(where: { $0.day == day }) {
                dayIndex = found
            } else {
                shadow.days.append(LegacyShadowDay(day: day, fills: 0, buys: 0, sells: 0,
                    fees: 0, realizedPnL: 0, startEquity: shadow.cash + shadow.shares * previous,
                    endEquity: shadow.cash + shadow.shares * previous))
                dayIndex = shadow.days.count - 1
            }

            if shadow.lastTimestamp != stamp && shadow.lastPrice > 0 && shadow.active && shadow.step > 0 && shadow.quantity > 0 {
                let etf = Self.isGridETF(shadow.code)
                let tick = etf ? 0.001 : 0.01
                let decimals = etf ? 3.0 : 2.0
                let scale = pow(10.0, decimals)
                let buyLevel = ((shadow.anchor - shadow.step) * scale).rounded() / scale
                let sellLevel = ((shadow.anchor + shadow.step) * scale).rounded() / scale
                if previous > buyLevel + tick / 2, price <= buyLevel - tick / 2, buyLevel >= shadow.lower {
                    let amount = buyLevel * shadow.quantity
                    let fee = Self.legacyShadowFee(code: shadow.code, side: "buy", amount: amount)
                    let slippage = tick * shadow.quantity
                    let debit = amount + fee + slippage
                    if shadow.cash >= debit {
                        shadow.cost = ((shadow.shares * (shadow.cost > 0 ? shadow.cost : buyLevel)) + amount + fee + slippage) / (shadow.shares + shadow.quantity)
                        shadow.cash -= debit; shadow.shares += shadow.quantity
                        if shadow.t0 { shadow.eligible += shadow.quantity }
                        shadow.totalFees += fee + slippage; shadow.buys += 1
                        shadow.anchor = buyLevel
                        shadow.days[dayIndex].buys += 1; shadow.days[dayIndex].fills += 1
                        shadow.days[dayIndex].fees += fee + slippage
                        shadow.fills.append(LegacyShadowFill(index: Int(timestamp.timeIntervalSince1970), day: day,
                            time: time, side: "buy", price: buyLevel, quantity: shadow.quantity,
                            fee: fee + slippage, realizedPnL: 0))
                    }
                } else if previous < sellLevel - tick / 2, price >= sellLevel + tick / 2,
                          sellLevel <= shadow.upper, shadow.eligible >= shadow.quantity {
                    let amount = sellLevel * shadow.quantity
                    let fee = Self.legacyShadowFee(code: shadow.code, side: "sell", amount: amount)
                    let slippage = tick * shadow.quantity
                    let realized = (sellLevel - (shadow.cost > 0 ? shadow.cost : sellLevel)) * shadow.quantity - fee - slippage
                    shadow.cash += amount - fee - slippage; shadow.shares -= shadow.quantity
                    shadow.eligible -= shadow.quantity
                    if shadow.shares <= 0 { shadow.shares = 0; shadow.cost = 0 }
                    shadow.totalFees += fee + slippage; shadow.realizedPnL += realized
                    shadow.sells += 1; shadow.scoredSells += 1
                    if realized > 0 { shadow.wins += 1 }
                    shadow.anchor = sellLevel
                    shadow.days[dayIndex].sells += 1; shadow.days[dayIndex].fills += 1
                    shadow.days[dayIndex].fees += fee + slippage
                    shadow.days[dayIndex].realizedPnL += realized
                    shadow.fills.append(LegacyShadowFill(index: Int(timestamp.timeIntervalSince1970), day: day,
                        time: time, side: "sell", price: sellLevel, quantity: shadow.quantity,
                        fee: fee + slippage, realizedPnL: realized))
                }
            }

            shadow.lastPrice = price
            shadow.lastTimestamp = stamp
            shadow.days[dayIndex].endEquity = shadow.cash + shadow.shares * price
            shadow.days.sort { $0.day < $1.day }
            if shadow.days.count > 60 { shadow.days.removeFirst(shadow.days.count - 60) }
            if shadow.fills.count > 300 { shadow.fills.removeFirst(shadow.fills.count - 300) }
            data.legacyShadowArchives[index] = shadow
        }
    }

    private static func isGridETF(_ code: String) -> Bool {
        let digits = code.lowercased().replacingOccurrences(of: "^(sh|sz|bj)", with: "", options: .regularExpression)
        return digits.range(of: "^(51|56|58|159|150|16|18)|^(15|16|18)\\d{4}$", options: .regularExpression) != nil
    }

    private static func legacyShadowFee(code: String, side: String, amount: Double) -> Double {
        if isGridETF(code) { return 0.10 }
        let commission = max(5, amount * 0.000086)
        return commission + (side == "sell" ? amount * 0.0005 : 0)
    }

    var gridTradingDays: [String] {
        intradayAllDays
    }

    var gridBarCount: Int { intradayBars.count }

    func saveGridPlan(code: String, name: String, capital: Double, anchor: Double,
                      stepPercent: Double, levels: Int, feePerOrder: Double) throws {
        guard !code.isEmpty, capital.isFinite, capital > 0, anchor.isFinite, anchor > 0,
              stepPercent.isFinite, (0.05...10).contains(stepPercent), (1...20).contains(levels),
              feePerOrder.isFinite, feePerOrder >= 0, feePerOrder <= 100 else {
            throw GridError.invalidPlan
        }
        if let index = data.dayGridPlans.firstIndex(where: { $0.code == code }) {
            data.dayGridPlans[index].name = name
            data.dayGridPlans[index].capital = capital
            data.dayGridPlans[index].anchor = anchor
            data.dayGridPlans[index].stepPercent = stepPercent / 100
            data.dayGridPlans[index].levelsEachSide = levels
            data.dayGridPlans[index].feePerOrder = feePerOrder
        } else {
            data.dayGridPlans.append(DayGridPlan(code: code, name: name, capital: capital, anchor: anchor,
                stepPercent: stepPercent / 100, levelsEachSide: levels, feePerOrder: feePerOrder, enabled: true))
        }
        save(label: "修改网格计划")
    }

    func removeGridPlan(_ plan: DayGridPlan) {
        data.dayGridPlans.removeAll { $0.id == plan.id }
        save(label: "修改网格计划")
    }

    /// Transparent rule-based sizing helper. It is deliberately not labelled AI:
    /// it estimates a spacing from saved intraday ranges and refuses sparse data.
    ///
    /// **振幅样本分两档（用户问「为什么生成规则建议必须三天」）**：
    /// 判断「振幅大不大、走势震不震荡」本来就不需要三天分时 —— 日线的 (high−low)/前收
    /// 就是当天真实的日内波幅，只是看不到盘中怎么走的。所以：
    /// - 覆盖合格的分时 ≥3 天 → 用分时振幅中位数（口径最细，能看到日内路径）；
    /// - 分时不够（0–2 天）但日线够多 → **降到日线振幅中位数兜底**，照样给参数，
    ///   只在结论里标明来源和「看不到盘中路径」这一限制；
    /// - 两者都拿不到才返回 nil（由 gridRecommendationBlocker 说明卡在哪）。
    func gridRecommendation(code: String, capital: Double, feePerOrder: Double) -> GridRecommendation? {
        guard capital.isFinite, capital > 0, capital <= 1_000_000_000_000,
              feePerOrder.isFinite, feePerOrder >= 0 else { return nil }
        let reliableDays = reliableIntradayDays(code: code)
        let bars = dailyBars[code] ?? []

        // ---- 振幅样本：分时优先，日线兜底 ----
        var ranges: [Double] = []
        var sampleDays = 0
        var coverage = 0.0
        var sourceNote = ""
        if reliableDays.count >= 3 {
            ranges = reliableDays.compactMap { day -> Double? in
                let prices = day.map(\.price).filter { $0.isFinite && $0 > 0 }
                guard let low = prices.min(), let high = prices.max(), low > 0 else { return nil }
                return (high - low) / ((high + low) / 2)
            }.sorted()
            sampleDays = reliableDays.count
            coverage = reliableDays.map { min(1, Double($0.count) / 240) }.reduce(0, +) / Double(reliableDays.count)
            sourceNote = "基于最近 \(sampleDays) 个覆盖合格的交易日分时"
        } else {
            // 日线兜底：用近 21 根的 (high − low) / 前收。覆盖度按 0.6 折算 ——
            // 看不到盘中路径，打分相应保守，不假装和分时数据一样可信。
            let window = Array(bars.suffix(21))
            guard window.count >= 11 else { return nil }
            for index in 1..<window.count {
                let previousClose = window[index - 1].close
                guard previousClose > 0, window[index].high > 0, window[index].low > 0 else { continue }
                ranges.append((window[index].high - window[index].low) / previousClose)
            }
            ranges.sort()
            sampleDays = ranges.count
            coverage = 0.6
            sourceNote = "本机分时覆盖不足 3 天，改用最近 \(sampleDays) 个交易日的日线振幅估算（看不到盘中路径，仅供起步参考）"
        }
        guard !ranges.isEmpty else { return nil }
        guard let medianRange = ranges.dropFirst(max(0, (ranges.count - 1) / 2)).first,
              medianRange.isFinite, medianRange > 0 else { return nil }

        // ---- 中枢价：分时最后一价优先，其次最后一根日线收盘 ----
        let anchor: Double
        if let intradayLast = reliableDays.last?.last?.price, intradayLast.isFinite, intradayLast > 0 {
            anchor = intradayLast
        } else if let close = bars.last?.close, close.isFinite, close > 0 {
            anchor = close
        } else {
            return nil
        }

        let feeFloor = 2 * feePerOrder / (anchor * 100) + 0.001 // fees plus a modest friction buffer
        let stepFraction = max(0.0005, min(0.01, max(medianRange * 0.25, feeFloor)))
        guard stepFraction <= medianRange * 0.8 else { return nil }
        let lotCost = anchor * 100 + feePerOrder
        guard lotCost.isFinite, lotCost > 0 else { return nil }
        let rawMaximumLevels = floor((capital / lotCost - 2) / 2)
        guard rawMaximumLevels.isFinite else { return nil }
        let maximumLevels = rawMaximumLevels >= 5 ? 5 : Int(rawMaximumLevels)
        guard maximumLevels >= 1 else { return nil }
        let levels = min(5, maximumLevels)
        let dayFactor = min(1, Double(sampleDays) / 10)
        let feeRatio = min(1, feeFloor / stepFraction)
        let score = max(0, min(100, Int((coverage * 55 + dayFactor * 30 + (1 - feeRatio) * 15).rounded())))
        return GridRecommendation(anchor: anchor, stepPercent: stepFraction * 100, levels: levels, score: score,
            daysUsed: sampleDays, medianDailyRangePercent: medianRange * 100,
            summary: "\(sourceNote)；日内振幅中位数 \(String(format: "%.2f", medianRange * 100))%。分数只代表数据覆盖、样本量和费用空间，不预测收益。")
    }

    /// 「覆盖合格」的交易日：当天 ≥168 个分钟点，且任意相邻两点间隔 ≤10 分钟。
    /// gridRecommendation 与失败原因诊断共用这一判定，避免两处口径漂移。
    private func reliableIntradayDays(code: String) -> [[IntradayBar]] {
        // 只按该标的已有的交易日取数（走索引），不再对整份分钟档案做 filter。
        var grouped: [String: [IntradayBar]] = [:]
        for day in intradayDays(forCode: code) {
            let dayBars = intradayBars(code: code, day: day)
            if !dayBars.isEmpty { grouped[day] = dayBars }
        }
        return grouped.values.compactMap { dayBars in
            let sorted = dayBars.sorted { $0.timestamp < $1.timestamp }
            guard sorted.count >= 168 else { return nil }
            let largestGap = zip(sorted, sorted.dropFirst()).map { $0.1.timestamp.timeIntervalSince($0.0.timestamp) }.max() ?? .infinity
            return largestGap <= 10 * 60 ? sorted : nil
        }.sorted { ($0.last?.timestamp ?? .distantPast) < ($1.last?.timestamp ?? .distantPast) }.suffix(20).map { $0 }
    }

    /// 规则建议生成失败的具体原因。与 gridRecommendation 同一套判定，
    /// 但把「数据不够」和「计划资金不够」分开说清，并给出可操作的下一步。
    /// 注意：这里只校验界面传入的计划资金，与主账户现金无关（影子盘本来就是隔离虚拟资金）。
    func gridRecommendationBlocker(code: String, capital: Double, feePerOrder: Double,
                                   fallbackAnchor: Double?) -> String? {
        let reliableDays = reliableIntradayDays(code: code)
        let bars = dailyBars[code] ?? []
        var blockers: [String] = []

        // 分时不足 3 天**不再直接判死**：只要日线够多，gridRecommendation 会用日线振幅兜底
        // （判断振幅与震荡性靠日线的 high/low 就够，不需要三天分时）。
        // 只有「分时不够且日线也不够」才真的给不出参数。
        if reliableDays.count < 3 && bars.count < 11 {
            let totalDays = intradayDays(forCode: code).count
            let detail = totalDays > reliableDays.count
                ? "本机共有 \(totalDays) 个有分时记录的交易日，但只有 \(reliableDays.count) 天覆盖合格"
                : "本机只有 \(reliableDays.count) 个覆盖合格的交易日"
            blockers.append("数据不足：\(detail)；日线也只有 \(bars.count) 根。"
                + "判断振幅和震荡并不需要三天分时 ——「≥3 天覆盖合格的分时」或「≥11 根日线」有其一即可。"
                + "点上方「补日线」通常最快（一次能拿到几百天日线）；交易时间把 App 保持前台可自动采集分时，或用「导入分时 CSV」补齐。")
        }

        // 资金门槛按 4 手估算（锚定占 2 手 + 至少 1 档 2 手），与 gridRecommendation 的
        // rawMaximumLevels = floor((capital / lotCost - 2) / 2) ≥ 1 一致。
        let anchor = reliableDays.last?.last?.price ?? bars.last?.close ?? fallbackAnchor
        if let anchor, anchor.isFinite, anchor > 0,
           capital.isFinite, capital > 0, feePerOrder.isFinite, feePerOrder >= 0 {
            let lotCost = anchor * 100 + feePerOrder
            let minimumCapital = lotCost * 4
            if capital < minimumCapital {
                blockers.append("计划资金不足：按中枢价约 \(anchor.num(3)) 元估算，支撑 1 档网格至少需要约 \(minimumCapital.cny())"
                    + "（≈4 手，每手 100 份 + 每笔费用 \(feePerOrder.num(2)) 元）。"
                    + "把上方「计划资金」提高到该数值以上即可——这里只校验你填的计划资金，与主账户现金无关。")
            }
        }
        return blockers.isEmpty ? nil : blockers.joined(separator: "\n\n")
    }

    /// 网格适合度排名：合并自选与 **ETF 持仓**，**只用本地已缓存日线，不发起请求**。
    /// **列表里不含场外基金**（用户要求）——申赎费用高、到账慢，本来就做不了网格，
    /// 把它排在榜上只会让人误以为「也能评一评」；为什么不能做，写在界面上的说明里。
    func gridSuitabilityRanking() -> [GridSuitability] {
        var seen: Set<String> = []
        var items: [(code: String, name: String, price: Double, onExchange: Bool)] = []
        // 持仓类型是本机最可靠的品种来源：只取场内持仓（ETF）。
        for holding in data.holdings where holding.kind == .etf {
            guard seen.insert(holding.code).inserted else { continue }
            items.append((holding.code, holding.name, holding.current, true))
        }
        // Quote 只表示行情可查，不一定代表可网格交易；至少要求标准六位 ASCII 数字代码。
        for quote in data.quotes where GridSuitabilityEngine.isTradableCode(quote.code) {
            guard seen.insert(quote.code).inserted else { continue }
            items.append((quote.code, quote.name, quote.price, true))
        }
        return items.map { item in
            GridSuitabilityEngine.evaluate(code: item.code, name: item.name,
                bars: dailyBars[item.code] ?? [], isOnExchange: item.onExchange, latestPrice: item.price)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.code < rhs.code
        }
    }

    /// 为适合度评估补齐缺失日线：只补「场内且本地不足 60 根」的标的，每次最多 limit 只。
    /// 顺序发起请求，避免把行情接口打满；返回实际补到的只数。
    @discardableResult
    func ensureGridSuitabilityData(limit: Int = 8) async -> Int {
        let needy = gridSuitabilityRanking().filter { $0.isOnExchange && $0.barCount < 60 }
        var fetched = 0
        for item in needy where fetched < limit {
            if (try? await fetchDailyBars(code: item.code, count: 640, force: false)) != nil { fetched += 1 }
        }
        return fetched
    }

    /// Import minute CSV using either separate date/time columns or a full timestamp column.
    /// Duplicate code+minute observations are replaced by the imported row.
    func importIntradayCSV(_ dataBytes: Data, fallbackCode: String) throws -> Int {
        guard let text = String(data: dataBytes, encoding: .utf8) else { throw GridError.invalidCSV }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { throw GridError.invalidCSV }
        let header = lines[0].replacingOccurrences(of: "\u{FEFF}", with: "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let codeColumn = header.firstIndex(of: "code")
        let dateColumn = header.firstIndex(where: { ["date", "日期"].contains($0) })
        let timeColumn = header.firstIndex(where: { ["time", "时间"].contains($0) })
        let stampColumn = header.firstIndex(where: { ["timestamp", "datetime", "date_time", "时间戳"].contains($0) })
        let priceColumn = header.firstIndex(where: { ["price", "close", "收盘", "收盘价", "价格"].contains($0) })
        let volumeColumn = header.firstIndex(of: "volume")
        guard let priceColumn,
              (codeColumn != nil || !fallbackCode.isEmpty),
              (dateColumn != nil && timeColumn != nil) || stampColumn != nil || (dateColumn == nil && timeColumn != nil) else {
            throw GridError.invalidCSV
        }
        var parsed: [IntradayBar] = []
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dateFormats = ["yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"]
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = tz
        let dayFormatter = DateFormatter(); dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.timeZone = tz; dayFormatter.dateFormat = "yyyy-MM-dd"
        for raw in lines.dropFirst() {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            guard cols.indices.contains(priceColumn), let price = Double(cols[priceColumn]), price.isFinite, price > 0 else { continue }
            let code = codeColumn.flatMap { cols.indices.contains($0) ? cols[$0] : nil } ?? fallbackCode
            let rawStamp: String
            if let dateColumn, let timeColumn {
                guard cols.indices.contains(dateColumn), cols.indices.contains(timeColumn) else { continue }
                rawStamp = "\(cols[dateColumn]) \(cols[timeColumn])"
            } else if let stampColumn {
                guard cols.indices.contains(stampColumn) else { continue }
                rawStamp = cols[stampColumn]
            } else if let timeColumn {
                guard cols.indices.contains(timeColumn) else { continue }
                rawStamp = cols[timeColumn]
            } else { continue }
            var timestamp: Date?
            for format in dateFormats {
                formatter.dateFormat = format
                timestamp = formatter.date(from: rawStamp)
                if timestamp != nil { break }
            }
            guard let timestamp else { continue }
            let volumeText = volumeColumn.flatMap { cols.indices.contains($0) ? cols[$0] : nil }
            let volume: Double?
            if let volumeText, let value = Double(volumeText), value.isFinite, value >= 0 { volume = value }
            else { volume = nil }
            parsed.append(IntradayBar(code: code.isEmpty ? fallbackCode : code, timestamp: timestamp,
                price: price, volume: volume, day: dayFormatter.string(from: timestamp)))
        }
        guard !parsed.isEmpty else { throw GridError.invalidCSV }
        let minuteKeys = Set(parsed.map { Self.intradayMinuteKey(code: $0.code, at: $0.timestamp) })
        intradayBars.removeAll { minuteKeys.contains(Self.intradayMinuteKey(code: $0.code, at: $0.timestamp)) }
        let minuteUnique = Dictionary(parsed.map { (Self.intradayMinuteKey(code: $0.code, at: $0.timestamp), $0) }, uniquingKeysWith: { _, latest in latest })
        rebuildIntradayMinuteIndex()
        mergeIntradayBars(Array(minuteUnique.values))
        return minuteUnique.count
    }

    /// Store only points observed while the app is foregrounded. The caller
    /// must provide a validated live quote; no synthetic bars are generated.
    func captureMinuteQuote(code: String, price: Double, at time: Date = .now) {
        captureMinuteQuotes([(code, price)], at: time)
    }

    func captureMinuteQuotes(_ quotes: [(String, Double)], at time: Date = .now) {
        guard !quotes.isEmpty else { return }
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = tz; formatter.dateFormat = "yyyy-MM-dd"
        let minute = Self.minuteStamp(time)
        var added: [IntradayBar] = []
        for (code, price) in quotes where !code.isEmpty && price.isFinite && price > 0 {
            guard !containsIntradayMinute(code: code, at: time) else { continue }
            let minuteTime = Date(timeIntervalSince1970: TimeInterval(minute * 60))
            // 顺手把 ETF 的实时 IOPV 记进分时点。
            //
            // 为什么以前取不到：腾讯的**分时接口本身不带 IOPV**，IOPV 只在快照接口的
            // 第 78 个字段里给。所以「分时图叠加 IOPV」「分时档案里的 IOPV 线」一直是空的 ——
            // 不是画不出来，是采集时根本没往 `IntradayBar.iopv` 里写过值。
            // 采到的点从这一版起会带 IOPV；历史点无法凭空补出来，界面会如实说明覆盖情况。
            var bar = IntradayBar(code: code, timestamp: minuteTime, price: price,
                                  volume: nil, day: formatter.string(from: time))
            if let iopv = marketIOPVs[code], iopv.isFinite, iopv > 0 { bar.iopv = iopv }
            added.append(bar)
        }
        mergeIntradayBars(added)
    }

    func replayGrid(plan: DayGridPlan, day: String) -> GridReplayResult? {
        let bars = intradayBars(code: plan.code, day: day)
        guard bars.count >= 10, let first = bars.first, let last = bars.last else { return nil }
        let expected = 240.0
        let coverage = min(1, Double(bars.count) / expected)
        let largestGap = zip(bars, bars.dropFirst()).map { $0.1.timestamp.timeIntervalSince($0.0.timestamp) }.max() ?? .infinity
        guard coverage >= 0.70, largestGap <= 10 * 60 else { return nil }
        let levels = max(1, plan.levelsEachSide)
        let lot = 100.0
        let perRungBudget = plan.capital / Double(levels * 2 + 2)
        let sharesPerRung = floor(perRungBudget / (plan.anchor * lot)) * lot
        guard sharesPerRung >= lot else { return GridReplayResult(code: plan.code, day: day, fills: 0, buyCount: 0, sellCount: 0, startCapital: plan.capital, endingValue: plan.capital, fees: 0, coverage: coverage) }

        // Start with half in inventory and half in cash, matching an already-held
        // ETF plus reserve cash. This is a self-contained simulation account.
        var shares = floor((plan.capital * 0.5 / first.price) / lot) * lot
        var cash = plan.capital - shares * first.price
        var fees = 0.0, buys = 0, sells = 0
        var previous = first.price
        for bar in bars.dropFirst() {
            let current = bar.price
            for level in 1...levels {
                let buyLevel = plan.anchor * pow(1 - plan.stepPercent, Double(level))
                if previous > buyLevel && current <= buyLevel && cash >= sharesPerRung * current + plan.feePerOrder {
                    cash -= sharesPerRung * current + plan.feePerOrder; shares += sharesPerRung; fees += plan.feePerOrder; buys += 1
                }
                let sellLevel = plan.anchor * pow(1 + plan.stepPercent, Double(level))
                if previous < sellLevel && current >= sellLevel && shares >= sharesPerRung {
                    cash += sharesPerRung * current - plan.feePerOrder; shares -= sharesPerRung; fees += plan.feePerOrder; sells += 1
                }
            }
            previous = current
        }
        return GridReplayResult(code: plan.code, day: day, fills: buys + sells, buyCount: buys,
            sellCount: sells, startCapital: plan.capital, endingValue: cash + shares * last.price,
            fees: fees, coverage: coverage)
    }
}

enum GridError: LocalizedError {
    case invalidPlan, invalidCSV
    var errorDescription: String? {
        switch self {
        case .invalidPlan: return "请检查代码、资金、锚点、网格间距、档位和单笔费用。"
        case .invalidCSV: return "CSV无法解析。请提供代码、完整日期时间、价格列；支持 date,time 或 timestamp 表头。"
        }
    }
}
