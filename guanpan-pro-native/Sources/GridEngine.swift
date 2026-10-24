import Foundation

@MainActor
extension PortfolioStore {
    private static func isGridETF(_ code: String) -> Bool {
        let digits = code.lowercased().replacingOccurrences(of: "^(sh|sz|bj)", with: "", options: .regularExpression)
        return digits.range(of: "^(51|56|58|159|150|16|18)|^(15|16|18)\\d{4}$", options: .regularExpression) != nil
    }

    private static func gridTradeFee(code: String, side: String, amount: Double) -> Double {
        SimulationCostPolicy.fee(isETF: isGridETF(code), side: side, amount: amount)
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
            data.dayGridPlans[index].feePerOrder = Self.isGridETF(code) ? 0.10 : feePerOrder
        } else {
            data.dayGridPlans.append(DayGridPlan(code: code, name: name, capital: capital, anchor: anchor,
                stepPercent: stepPercent / 100, levelsEachSide: levels, feePerOrder: Self.isGridETF(code) ? 0.10 : feePerOrder, enabled: true))
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

        let feeFloor = 2 * (Self.isGridETF(code) ? 0.10 : feePerOrder) / (anchor * 100) + 2 * SimulationCostPolicy.extraSlippageTicks * (Self.isGridETF(code) ? 0.001 : 0.01) / anchor
        let stepFraction = max(0.0005, min(0.01, max(medianRange * 0.25, feeFloor)))
        guard stepFraction <= medianRange * 0.8 else { return nil }
        let lotCost = anchor * 100 + (Self.isGridETF(code) ? 0.10 : feePerOrder)
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
            let lotCost = anchor * 100 + (Self.isGridETF(code) ? 0.10 : feePerOrder)
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
                if previous > buyLevel && current <= buyLevel && cash >= sharesPerRung * current + Self.gridTradeFee(code: plan.code, side: "buy", amount: sharesPerRung * current) {
                    cash -= sharesPerRung * current + Self.gridTradeFee(code: plan.code, side: "buy", amount: sharesPerRung * current); shares += sharesPerRung; fees += Self.gridTradeFee(code: plan.code, side: "buy", amount: sharesPerRung * current); buys += 1
                }
                let sellLevel = plan.anchor * pow(1 + plan.stepPercent, Double(level))
                if previous < sellLevel && current >= sellLevel && shares >= sharesPerRung {
                    cash += sharesPerRung * current - Self.gridTradeFee(code: plan.code, side: "sell", amount: sharesPerRung * current); shares -= sharesPerRung; fees += Self.gridTradeFee(code: plan.code, side: "sell", amount: sharesPerRung * current); sells += 1
                }
            }
            previous = current
        }
        return GridReplayResult(code: plan.code, day: day, fills: buys + sells, buyCount: buys,
            sellCount: sells, startCapital: plan.capital, endingValue: cash + shares * last.price,
            fees: fees, coverage: coverage)
    }

    // MARK: - 复盘并寻找当日最优（移植自网页版 gridTradeReplayOptimize）
    //
    // 与上面 `replayGrid(plan:day:)` 的分工：
    //   · `replayGrid` 是「我给参数，你告诉我结果」——考的是我自己拟的计划；
    //   · 本函数是「我只给资金，你搜出当天事后最优的锚点 + 格距」——考的是这一天本身值不值得做网格。
    // 参数、常量、判定顺序全部按网页版逐条对齐，不做「优化」。

    /// 自动搜索当日事后最优网格参数。返回 `.failure` 时原因可直接展示给用户。
    func optimizeGridReplay(code: String, day: String, capital: Double, t0: Bool)
        -> Result<GridOptimizeReport, GridOptimizeError> {
        let bars = intradayBars(code: code, day: day)
        let prices = bars.map(\.price).filter { $0.isFinite && $0 > 0 }
        // 有效分钟点不足 30 个：当天采样太稀，任何「最优」都是噪音。
        guard prices.count >= 30, let first = prices.first, let last = prices.last else {
            return .failure(.notEnoughPoints(prices.count))
        }
        let etf = Self.isGridETF(code)
        let tick = etf ? 0.001 : 0.01
        let decimals = etf ? 3 : 2
        let dayLow = prices.min() ?? first
        let dayHigh = prices.max() ?? first
        let money = capital.isFinite && capital > 0 ? capital : 0

        // 每一手股数：分母里的 4 = 「2 手初始建仓 + 2 手留给网格买入」，
        // 所以 qty < 100 意味着资金连最基本的网格骨架都撑不起来。
        let quantity = (money / (max(first, 0.0001) * 4 * 100)).rounded(.down) * 100
        guard quantity >= 100 else { return .failure(.capitalTooSmall) }

        // 中位跳动（相邻分钟价差绝对值的中位数）代表这个标的当天的「典型抖动」。
        let moves = zip(prices, prices.dropFirst()).map { abs($1 - $0) }.filter { $0 > 0 }.sorted()
        let medianMove = moves.isEmpty ? tick : moves[moves.count / 2]
        let minStep = (max(tick, medianMove * 1.3) / tick).rounded(.up) * tick

        // 三个锚点：首价 / 前 15 点均价 / 当日中位价 —— 分别代表「开盘就布」「等一刻钟看方向」「按全天中枢布」。
        let sortedPrices = prices.sorted()
        let head = prices.prefix(min(15, prices.count))
        let headAverage = head.reduce(0, +) / Double(max(1, head.count))
        var anchors: [Double] = []
        var seenAnchors = Set<Double>()
        for raw in [first, headAverage, sortedPrices[sortedPrices.count / 2]] {
            let value = gridRound(raw, decimals: decimals)
            // 锚点必须落在当天真实价格区间内，否则回放会以不存在的价位开局。
            guard value >= dayLow, value <= dayHigh else { continue }
            if seenAnchors.insert(value).inserted { anchors.append(value) }
        }

        // 步长的第二条下界：一格涨跌必须能覆盖「买+卖两次费用 + 配置的两次额外滑点」，
        // 否则来回一趟净亏，格距再密也是白忙。1.15 是留出的安全边际。
        let sampleQuantity = max(100, quantity)
        let roundTripCost = (Self.gridTradeFee(code: code, side: "buy", amount: first * sampleQuantity)
            + Self.gridTradeFee(code: code, side: "sell", amount: first * sampleQuantity)
            + 2 * SimulationCostPolicy.extraSlippageTicks * tick * sampleQuantity) / sampleQuantity
        let minGridStep = max(minStep, roundTripCost * 1.15)
        let stepMultipliers: [Double] = [1, 1.25, 1.5, 2, 2.5, 3, 4]
        let steps = stepMultipliers.map { multiplier in
            max(tick, (minGridStep * multiplier / tick).rounded(.up) * tick)
        }

        var candidates: [GridOptimizeCandidate] = []
        var best: GridOptimizeCandidate?

        for anchorSeed in anchors {
            for step in steps {
                var anchor = anchorSeed
                let initialShares = quantity * 2
                var shares = initialShares
                // eligible 是 T+0 校验：A股当天买入的份额当天不能卖，`t0=false` 时买入不增加它。
                var eligible = initialShares
                var cash = money - initialShares * anchorSeed
                var cost = anchorSeed
                var buyCount = 0, sellCount = 0, fillCount = 0
                var fees = 0.0, commissionCost = 0.0, slippageCost = 0.0
                var peak = money
                var maxDrawdown = 0.0

                for price in prices {
                    if price <= anchor - step - tick / 2, anchor - step >= dayLow - tick / 2 {
                        // 向下穿越一档且该档没跌出当天低点 → 买一手（含费用 + 配置的额外滑点）。
                        let target = gridRound(anchor - step, decimals: decimals)
                        let fee = Self.gridTradeFee(code: code, side: "buy", amount: target * quantity)
                        let slippage = SimulationCostPolicy.extraSlippageTicks * tick * quantity
                        if cash >= target * quantity + fee + slippage {
                            cost = (shares * cost + target * quantity + fee + slippage) / (shares + quantity)
                            shares += quantity
                            if t0 { eligible += quantity }
                            cash -= target * quantity + fee + slippage
                            fees += fee + slippage
                            commissionCost += fee
                            slippageCost += slippage
                            buyCount += 1
                            fillCount += 1
                            anchor = target
                        }
                    } else if price >= anchor + step + tick / 2, anchor + step <= dayHigh + tick / 2, eligible >= quantity {
                        // 向上穿越一档且没涨出当天高点、且有可卖份额 → 卖一手。
                        let target = gridRound(anchor + step, decimals: decimals)
                        let fee = Self.gridTradeFee(code: code, side: "sell", amount: target * quantity)
                        let slippage = SimulationCostPolicy.extraSlippageTicks * tick * quantity
                        shares -= quantity
                        eligible -= quantity
                        cash += target * quantity - fee - slippage
                        fees += fee + slippage
                        commissionCost += fee
                        slippageCost += slippage
                        sellCount += 1
                        fillCount += 1
                        anchor = target
                    }
                    let equity = cash + shares * price
                    if equity > peak { peak = equity }
                    if peak > 0 {
                        let drawdown = (peak - equity) / peak * 100
                        if drawdown > maxDrawdown { maxDrawdown = drawdown }
                    }
                }

                let endingEquity = cash + shares * last
                let profit = endingEquity - money
                let holdProfit = initialShares * (last - anchorSeed)
                let item = GridOptimizeCandidate(
                    anchor: anchorSeed,
                    finalAnchor: anchor,
                    step: step,
                    stepPercent: step / first * 100,
                    quantity: quantity,
                    buyCount: buyCount,
                    sellCount: sellCount,
                    fills: fillCount,
                    fees: fees,
                    commissionCost: commissionCost,
                    slippageCost: slippageCost,
                    profit: profit,
                    holdProfit: holdProfit,
                    alpha: profit - holdProfit,
                    maxDrawdown: maxDrawdown,
                    endingEquity: endingEquity
                )
                candidates.append(item)
                if let current = best {
                    // 先比 alpha；完全打平时取最大回撤更小的那组（同样多赚，波动更小）。
                    if item.alpha > current.alpha
                        || (item.alpha == current.alpha && item.maxDrawdown < current.maxDrawdown) {
                        best = item
                    }
                } else {
                    best = item
                }
            }
        }

        guard let winner = best else { return .failure(.noCandidate) }
        let resolvedName = data.quotes.first { $0.code == code }?.name
            ?? data.holdings.first { $0.code == code }?.name
            ?? code
        let report = GridOptimizeReport(
            code: code,
            name: resolvedName,
            day: day,
            capital: money,
            t0: t0,
            tick: tick,
            dayLow: dayLow,
            dayHigh: dayHigh,
            firstPrice: first,
            lastPrice: last,
            points: prices.count,
            best: winner,
            candidates: candidates.sorted { $0.alpha > $1.alpha },
            note: "ETF 每笔成交 0.10 元；股票暂按最低佣金估算，费率和税费待确认。"
                + "额外滑点默认 0，按统一模拟费用设置；历史触价回放不是盘口实盘成交。"
        )
        return .success(report)
    }

    // MARK: - 策略经验累积

    func gridExperience(forCode code: String) -> GridExperienceRecord? {
        gridExperienceMap()[code]
    }

    /// 把一次「找最优」的结果并进该标的的经验累积（只统计，不参与选参）。
    func recordGridExperience(_ report: GridOptimizeReport) {
        var map = gridExperienceMap()
        var record = map[report.code] ?? GridExperienceRecord()
        record.samples += 1
        if report.best.alpha > 0 { record.wins += 1 }
        record.alphaSum += report.best.alpha
        record.stepPercentSamples.append(report.best.stepPercent)
        // 只留最近 200 次：经验是「近期这个标的的格距习惯」，不是永久账本。
        if record.stepPercentSamples.count > 200 {
            record.stepPercentSamples.removeFirst(record.stepPercentSamples.count - 200)
        }
        map[report.code] = record
        guard let raw = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(raw, forKey: gridExperienceDefaultsKey)
    }

    private func gridExperienceMap() -> [String: GridExperienceRecord] {
        guard let raw = UserDefaults.standard.data(forKey: gridExperienceDefaultsKey),
              let map = try? JSONDecoder().decode([String: GridExperienceRecord].self, from: raw) else { return [:] }
        return map
    }

    // MARK: - 按区间复盘（长周期网格参数）
    //
    // 与 `optimizeGridReplay` 的关系：
    //   · 单日版问「这一天事后最优是什么」——只能说明这一天；
    //   · 区间版问「同一组格距，在这些天里平均表现如何」——这才有资格指导以后怎么挂单。
    // 逐日判定口径**完全复用同一套 alpha**（网格盈亏 − 买了不动），只是把结果按天汇总。
    //
    // 锚点固定为「每天的首价」：真实的长期网格就是每天早上按当时的价位重铺一遍，
    // 用一个跨越几十天的固定绝对价当锚点是不成立的（价格早跑没了）。

    /// 按区间搜索长周期网格参数。`from` / `to` 用 `yyyy-MM-dd`，顺序无所谓。
    func optimizeGridRange(code: String, from: String, to: String, capital: Double, t0: Bool,
                           stepPercents: [Double] = GridRangeDefaults.stepPercents)
        -> Result<GridRangeReport, GridOptimizeError> {
        let lower = min(from, to)
        let upper = max(from, to)
        // `yyyy-MM-dd` 的字典序就是时间序，可以直接比较，不必先转 Date。
        let archived = intradayDays(forCode: code).filter { $0 >= lower && $0 <= upper }.sorted()
        guard !archived.isEmpty else { return .failure(.noArchivedDay) }

        let money = capital.isFinite && capital > 0 ? capital : 0
        guard money > 0 else { return .failure(.capitalTooSmall) }
        let etf = Self.isGridETF(code)
        let tick = etf ? 0.001 : 0.01
        let decimals = etf ? 3 : 2

        // 逐日预处理一次，9 组候选反复复用 —— 不然每天都要重扫一遍整份分钟档案。
        var setups: [GridRangeDaySetup] = []
        var skipped: [String] = []
        var totalPoints = 0
        var overallLow = Double.greatestFiniteMagnitude
        var overallHigh = 0.0
        var amplitudeSum = 0.0
        for day in archived {
            let bars = intradayBars(code: code, day: day)
            let prices = bars.map(\.price).filter { $0.isFinite && $0 > 0 }
            guard prices.count >= 30, let first = prices.first, let last = prices.last else {
                skipped.append(day)
                continue
            }
            let low = prices.min() ?? first
            let high = prices.max() ?? first
            // 每格股数：分母 4 = 「2 手初始建仓 + 2 手留给网格买入」，与单日复盘同一条规则。
            let quantity = (money / (max(first, 0.0001) * 4 * 100)).rounded(.down) * 100
            guard quantity >= 100 else {
                skipped.append(day)
                continue
            }
            setups.append(GridRangeDaySetup(day: day, prices: prices, first: first, last: last,
                                            low: low, high: high, quantity: quantity))
            totalPoints += prices.count
            overallLow = min(overallLow, low)
            overallHigh = max(overallHigh, high)
            if first > 0 { amplitudeSum += (high - low) / first * 100 }
        }
        guard setups.count >= 3 else { return .failure(.notEnoughRangeDays(setups.count)) }

        var candidates: [GridRangeCandidate] = []
        var detailsByPercent: [Double: [GridRangeDayDetail]] = [:]
        for percent in stepPercents where percent.isFinite && percent > 0 {
            var samples = 0, winDays = 0, fillsTotal = 0
            var totalAlpha = 0.0, totalProfit = 0.0, totalHold = 0.0, totalFees = 0.0
            var worstAlpha = Double.greatestFiniteMagnitude
            var worstDrawdown = 0.0
            var details: [GridRangeDayDetail] = []
            for setup in setups {
                let step = rangeStep(code: code, percent: percent, setup: setup, tick: tick)
                let anchor = gridRound(setup.first, decimals: decimals)
                let outcome = replayGridDay(code: code, setup: setup, step: step, anchor: anchor,
                                            money: money, t0: t0, tick: tick, decimals: decimals)
                samples += 1
                if outcome.alpha > 0 { winDays += 1 }
                fillsTotal += outcome.fills
                totalAlpha += outcome.alpha
                totalProfit += outcome.profit
                totalHold += outcome.holdProfit
                totalFees += outcome.fees
                worstAlpha = min(worstAlpha, outcome.alpha)
                worstDrawdown = max(worstDrawdown, outcome.maxDrawdown)
                details.append(GridRangeDayDetail(day: setup.day, points: setup.prices.count,
                                                  firstPrice: setup.first, lastPrice: setup.last,
                                                  dayLow: setup.low, dayHigh: setup.high, step: step,
                                                  buyCount: outcome.buyCount, sellCount: outcome.sellCount,
                                                  fills: outcome.fills, profit: outcome.profit,
                                                  holdProfit: outcome.holdProfit, alpha: outcome.alpha,
                                                  maxDrawdown: outcome.maxDrawdown, fees: outcome.fees))
            }
            guard samples > 0 else { continue }
            // 「填单要用什么数」按**最近一个交易日**算：区间平均格距对今天的下单没有意义。
            let latest = setups[setups.count - 1]
            let lastStep = rangeStep(code: code, percent: percent, setup: latest, tick: tick)
            candidates.append(GridRangeCandidate(
                stepPercent: percent,
                samples: samples,
                winDays: winDays,
                totalAlpha: totalAlpha,
                averageAlpha: totalAlpha / Double(samples),
                totalProfit: totalProfit,
                totalHoldProfit: totalHold,
                totalFees: totalFees,
                worstAlpha: worstAlpha == .greatestFiniteMagnitude ? 0 : worstAlpha,
                worstDrawdown: worstDrawdown,
                averageFills: Double(fillsTotal) / Double(samples),
                lastStep: lastStep,
                lastQuantity: latest.quantity,
                lastStepPercent: latest.first > 0 ? lastStep / latest.first * 100 : percent))
            detailsByPercent[percent] = details
        }

        guard let winner = pickBestRangeCandidate(candidates) else { return .failure(.noCandidate) }
        let resolvedName = data.quotes.first { $0.code == code }?.name
            ?? data.holdings.first { $0.code == code }?.name
            ?? code
        let firstSetup = setups[0]
        let lastSetup = setups[setups.count - 1]
        let changePercent = firstSetup.first > 0 ? (lastSetup.last / firstSetup.first - 1) * 100 : 0
        let report = GridRangeReport(
            code: code,
            name: resolvedName,
            from: lower,
            to: upper,
            capital: money,
            t0: t0,
            tick: tick,
            days: setups.map(\.day),
            skippedDays: skipped,
            totalPoints: totalPoints,
            rangeLow: overallLow,
            rangeHigh: overallHigh,
            rangeChangePercent: changePercent,
            averageAmplitudePercent: amplitudeSum / Double(setups.count),
            best: winner,
            candidates: candidates.sorted(by: rangeCandidateOrder),
            details: detailsByPercent[winner.stepPercent] ?? [],
            note: "每天按当日首价重新铺一次网格（长期网格的真实做法），格距按下单当日价格换算成绝对价。"
                + "ETF 每笔成交 0.10 元；股票暂按最低佣金估算，费率和税费待确认。"
                + "费用按统一模拟设置，额外滑点默认 0。格距下界覆盖买卖两笔费用及配置滑点，"
                + "所以低价品种实际格距可能比所选百分比更宽。"
        )
        return .success(report)
    }

    // MARK: - 把「日内计划里那一套参数」丢进最近 N 个交易日验证

    /// 「日内试出来的参数 → 拿到近期区间里验一遍」。
    ///
    /// 为什么需要它：`replayGrid` 只考**一天**，而单日样本是过拟合风险最大的一档 ——
    /// 一个格距在那天好看，很可能只是因为那天正好来回震荡。这里把同一套格距
    /// 放进最近 N 个交易日各跑一遍，用「平均跑赢持有 / 跑赢天数 / 最差一天 / 最大回撤」
    /// 判断它是真有优势，还是只是那一天运气好。
    ///
    /// 顺带把 `GridRangeDefaults.stepPercents` 那 9 档一起跑出来当参照，
    /// 这样用户能直接看到「我这一档在邻近档位里排第几、有没有更划算的选择」，
    /// 而不用自己去复盘页重填一遍参数。
    ///
    /// 返回报告里的 `candidates` **一定包含用户那一档**（`stepPercent` 就是传入值）；
    /// `best` 是否等于它，本身就是结论。
    func verifyGridPlan(code: String, capital: Double, stepPercent: Double,
                        recentDays: Int = 20) -> Result<GridRangeReport, GridOptimizeError> {
        let allDays = intradayDays(forCode: code).sorted()
        guard allDays.count >= 3 else { return .failure(.notEnoughRangeDays(allDays.count)) }
        // 只取最近 N 个有档案的交易日：越久远的行情对「现在该怎么挂单」参考价值越低。
        let window = Array(allDays.suffix(max(3, recentDays)))
        guard let from = window.first, let to = window.last else { return .failure(.noArchivedDay) }
        // 用户那档可能不在默认 9 档里（比如 0.7%），先补进去再一起跑。
        var percents = GridRangeDefaults.stepPercents
        if !percents.contains(where: { abs($0 - stepPercent) < 0.0001 }) { percents.append(stepPercent) }
        // t0 按品种判定：场内 ETF 支持当日回转，个股 T+1。
        return optimizeGridRange(code: code, from: from, to: to, capital: capital,
                                 t0: Self.isGridETF(code), stepPercents: percents)
    }

    /// 一组候选的排序：先比「平均跑赢」，再比跑赢天数，最后比最差一天的回撤。
    ///
    /// 为什么是平均 alpha 而不是总 alpha：区间里交易日数对每组都一样，
    /// 但用平均能直接对上「每天大概多赚多少」，比总和更好读；排序结果两者等价。
    private func rangeCandidateOrder(_ lhs: GridRangeCandidate, _ rhs: GridRangeCandidate) -> Bool {
        if lhs.averageAlpha != rhs.averageAlpha { return lhs.averageAlpha > rhs.averageAlpha }
        if lhs.winDays != rhs.winDays { return lhs.winDays > rhs.winDays }
        if lhs.worstDrawdown != rhs.worstDrawdown { return lhs.worstDrawdown < rhs.worstDrawdown }
        return lhs.stepPercent < rhs.stepPercent
    }

    private func pickBestRangeCandidate(_ candidates: [GridRangeCandidate]) -> GridRangeCandidate? {
        candidates.min(by: { rangeCandidateOrder($0, $1) })
    }

    /// 把「格距百分比」换算成当天的绝对格距。
    ///
    /// 取 `max(百分比换算值, 往返成本 × 1.15)` 再向上取整到一跳 —— 与单日复盘那条下界同源：
    /// 一格连买卖两笔费用都覆盖不了的话，来回一趟净亏，格距再密也是白忙。
    private func rangeStep(code: String, percent: Double, setup: GridRangeDaySetup, tick: Double) -> Double {
        let raw = percent / 100 * setup.first
        let sampleQuantity = max(100, setup.quantity)
        let roundTripCost = (Self.gridTradeFee(code: code, side: "buy", amount: setup.first * sampleQuantity)
            + Self.gridTradeFee(code: code, side: "sell", amount: setup.first * sampleQuantity)
            + 2 * SimulationCostPolicy.extraSlippageTicks * tick * sampleQuantity) / sampleQuantity
        let floorStep = roundTripCost * 1.15
        let chosen = max(raw, floorStep)
        return max(tick, (chosen / tick).rounded(.up) * tick)
    }

    /// 单日回放。口径与 `optimizeGridReplay` 的单日分支逐条一致，只是抽出来给区间复盘复用。
    private func replayGridDay(code: String, setup: GridRangeDaySetup, step: Double, anchor anchorSeed: Double,
                               money: Double, t0: Bool, tick: Double, decimals: Int) -> GridRangeDayOutcome {
        let prices = setup.prices
        let quantity = setup.quantity
        let initialShares = quantity * 2
        var shares = initialShares
        // eligible 是 T+0 校验：A股当天买入的份额当天不能卖，`t0=false` 时买入不增加它。
        var eligible = initialShares
        var cash = money - initialShares * anchorSeed
        var cost = anchorSeed
        var anchor = anchorSeed
        var buyCount = 0, sellCount = 0, fillCount = 0
        var fees = 0.0, commissionCost = 0.0, slippageCost = 0.0
        var peak = money
        var maxDrawdown = 0.0

        for price in prices {
            if price <= anchor - step - tick / 2, anchor - step >= setup.low - tick / 2 {
                let target = gridRound(anchor - step, decimals: decimals)
                let fee = Self.gridTradeFee(code: code, side: "buy", amount: target * quantity)
                let slippage = SimulationCostPolicy.extraSlippageTicks * tick * quantity
                if cash >= target * quantity + fee + slippage {
                    cost = (shares * cost + target * quantity + fee + slippage) / (shares + quantity)
                    shares += quantity
                    if t0 { eligible += quantity }
                    cash -= target * quantity + fee + slippage
                    fees += fee + slippage
                    commissionCost += fee
                    slippageCost += slippage
                    buyCount += 1
                    fillCount += 1
                    anchor = target
                }
            } else if price >= anchor + step + tick / 2, anchor + step <= setup.high + tick / 2,
                      eligible >= quantity {
                let target = gridRound(anchor + step, decimals: decimals)
                let fee = Self.gridTradeFee(code: code, side: "sell", amount: target * quantity)
                let slippage = SimulationCostPolicy.extraSlippageTicks * tick * quantity
                shares -= quantity
                eligible -= quantity
                cash += target * quantity - fee - slippage
                fees += fee + slippage
                commissionCost += fee
                slippageCost += slippage
                sellCount += 1
                fillCount += 1
                anchor = target
            }
            let equity = cash + shares * price
            if equity > peak { peak = equity }
            if peak > 0 {
                let drawdown = (peak - equity) / peak * 100
                if drawdown > maxDrawdown { maxDrawdown = drawdown }
            }
        }

        let endingEquity = cash + shares * setup.last
        let profit = endingEquity - money
        let holdProfit = initialShares * (setup.last - anchorSeed)
        return GridRangeDayOutcome(profit: profit, holdProfit: holdProfit, alpha: profit - holdProfit,
                                   fees: fees, commissionCost: commissionCost, slippageCost: slippageCost,
                                   buyCount: buyCount, sellCount: sellCount, fills: fillCount,
                                   maxDrawdown: maxDrawdown, endingEquity: endingEquity)
    }

    // MARK: - 区间复盘的历史记录

    /// 某标的在本机跑过的区间复盘，最近的在前。
    func gridRangeHistory(forCode code: String) -> [GridRangeReport] {
        gridRangeHistoryMap()[code] ?? []
    }

    /// 记住一次区间复盘。每个标的只留最近 20 次 —— 这是「这段时间的格距习惯」，
    /// 不是永久账本，越老的对现在的参考价值越低。
    func recordGridRangeHistory(_ report: GridRangeReport) {
        var map = gridRangeHistoryMap()
        var list = map[report.code] ?? []
        list.removeAll { $0.id == report.id }
        list.insert(report, at: 0)
        if list.count > 20 { list.removeLast(list.count - 20) }
        map[report.code] = list
        guard let raw = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(raw, forKey: gridRangeHistoryDefaultsKey)
    }

    private func gridRangeHistoryMap() -> [String: [GridRangeReport]] {
        guard let raw = UserDefaults.standard.data(forKey: gridRangeHistoryDefaultsKey),
              let map = try? JSONDecoder().decode([String: [GridRangeReport]].self, from: raw) else { return [:] }
        return map
    }
}

/// 区间复盘的默认格距候选（百分比）。
///
/// 这 9 档是按「一格大致等于当日振幅的 1/3 ~ 1/10」铺的：太密一趟连买卖两笔费用都覆盖不了，
/// 太稀长期下来成交太少、等于没做网格。中间两档（1.0% / 1.2%）在多数 A 股宽基 ETF 上最常用。
///
/// 注意：这里只能放**文件作用域的类型**，不能放到 `extension PortfolioStore` 里当存储属性 ——
/// Swift 不允许 extension 新增存储属性；而且默认参数引用的声明必须至少和函数本身一样可见。
enum GridRangeDefaults {
    static let stepPercents: [Double] = [0.4, 0.6, 0.8, 1.0, 1.2, 1.5, 2.0, 2.5, 3.0]
}

/// 区间复盘里某一天的预处理结果。放在文件作用域而不是函数内，方便被多个私有方法共用。
private struct GridRangeDaySetup {
    let day: String
    let prices: [Double]
    let first: Double
    let last: Double
    let low: Double
    let high: Double
    let quantity: Double
}

/// 单日回放的输出（字段与 `GridOptimizeCandidate` 一一对应，只是不带锚点/格距那些入参）。
private struct GridRangeDayOutcome {
    var profit: Double
    var holdProfit: Double
    var alpha: Double
    var fees: Double
    var commissionCost: Double
    var slippageCost: Double
    var buyCount: Int
    var sellCount: Int
    var fills: Int
    var maxDrawdown: Double
    var endingEquity: Double
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

/// 「复盘并寻找当日最优」的可展示错误（对应网页版返回的 `error` 文案）。
enum GridOptimizeError: LocalizedError {
    case notEnoughPoints(Int)
    case capitalTooSmall
    case noCandidate
    /// 区间复盘：所选区间内这个标的没有任何分时档案
    case noArchivedDay
    /// 区间复盘：够用的交易日太少
    case notEnoughRangeDays(Int)

    var errorDescription: String? {
        switch self {
        case .notEnoughPoints(let count):
            return "有效分钟点只有 \(count) 个（少于 30 个），不能可靠回放。"
        case .capitalTooSmall:
            return "计划资金不足以覆盖至少两手初始份额和两手网格买入，请加大资金或换单价更低的标的。"
        case .noCandidate:
            return "没有可计算的网格参数。"
        case .noArchivedDay:
            return "所选区间里这个标的还没有分时档案。先在自选或 ETF 持仓里留着它，应用在前台时会自动采集。"
        case .notEnoughRangeDays(let count):
            return "所选区间里只有 \(count) 个交易日的分时够用（至少需要 3 个，且每天有效分钟点要满 30 个）。把区间放宽，或换一个档案更全的标的。"
        }
    }
}

/// 按小数位取整（网页版 `roundFix`）：ETF 3 位、个股 2 位。
/// 先放大再取整再缩回，避免 1.2340000000000002 这种浮点尾数漏出来。
private func gridRound(_ value: Double, decimals: Int) -> Double {
    guard value.isFinite else { return value }
    let scale = pow(10.0, Double(decimals))
    return (value * scale).rounded() / scale
}

/// 策略经验的 UserDefaults 键。**口径变了就改版本号**，否则老设备上不会重算。
private let gridExperienceDefaultsKey = "guanpan.native.gridExperience.v1"

/// 区间复盘历史（按标的分组）的 UserDefaults 键。同样地，口径变了要改版本号。
private let gridRangeHistoryDefaultsKey = "guanpan.native.gridRangeHistory.v1"
