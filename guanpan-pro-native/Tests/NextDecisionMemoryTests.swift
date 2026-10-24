import XCTest
@testable import GuanpanAdvisorCore

/// 决策记忆 / 新闻影响 / 画像硬约束 三条链路的回归测试。
/// 这些测试锁住的是「AI 有没有真的在读数据、有没有真的受约束」，
/// 而不是文案或页面是否存在。
final class NextDecisionMemoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1792375200)

    // MARK: - 夹具

    private func snapshot(price: String = "1.400", state: String = "窄幅震荡", strategy: String = "做T",
                          headline: String = "反T · 先卖后买", limitPrice: String? = "1.420",
                          limitUnits: Int? = 3000, vwapDeviation: Double = 0.4,
                          nasDays: Int = 20, nasStale: Bool = false,
                          validUntil: Date? = nil, risks: [String] = [],
                          news: [String] = [], confidence: String = "高") -> NextDecisionSnapshot {
        NextDecisionSnapshot(price: price, previousClose: "1.396", quoteSource: "test", quoteAt: now,
                             units: 10_000, averageCost: "1.38",
                             nasDays: nasDays, nasVwap20: "1.398", nasCloseVsVwap20: vwapDeviation,
                             nasAmplitude60: 1.6, nasRoundTrips60: 2.4, nasVolatility120: 1.1,
                             nasSupportP10: "1.360", nasResistanceP90: "1.440",
                             nasStale: nasStale, nasEnoughForLongTerm: nasDays >= 5,
                             newsTitles: news, profileTags: ["中期", "做T活跃"],
                             state: state, strategy: strategy, headline: headline,
                             evidence: ["VWAP 1.398"], risks: risks,
                             validUntil: validUntil ?? now.addingTimeInterval(3600 * 2),
                             invalidConditions: ["跌破 1.36"],
                             limitPrice: limitPrice, limitUnits: limitUnits,
                             expectedNetGain: "3.80", expectedCostReduction: "0.0004",
                             confidenceLevel: confidence)
    }

    private func record(_ snapshot: NextDecisionSnapshot) -> NextDecisionRecord {
        NextDecisionRecord(code: "159941", name: "纳指ETF", createdAt: now, snapshot: snapshot)
    }

    // MARK: - 变化解释

    func testDiffExplainsWhatChangedWithTraceableNumbers() {
        let old = snapshot()
        let new = snapshot(price: "1.430", state: "趋势上涨", strategy: "持有",
                           headline: "持有", limitPrice: nil, limitUnits: nil,
                           vwapDeviation: 1.9, nasStale: true, confidence: "中")
        let changes = NextDecisionDiff.compare(old: old, new: new)
        XCTAssertTrue(changes.contains { $0.contains("市场状态从「窄幅震荡」变为「趋势上涨」") })
        XCTAssertTrue(changes.contains { $0.contains("策略从「做T」变为「持有」") })
        XCTAssertTrue(changes.contains { $0.contains("+2.14%") }, "价格变化要带具体幅度：\(changes)")
        XCTAssertTrue(changes.contains { $0.contains("VWAP") })
        XCTAssertTrue(changes.contains { $0.contains("过期") })
        XCTAssertTrue(changes.contains { $0.contains("限价从 ¥1.420 变为 ¥无") })
        XCTAssertTrue(changes.contains { $0.contains("置信度从 高 变为 中") })
    }

    func testDiffIgnoresTinyPriceJitter() {
        // 0.1% 的抖动不值得改判：结论没变就不该冒出「变化说明」。
        let changes = NextDecisionDiff.compare(old: snapshot(price: "1.400"), new: snapshot(price: "1.4014"))
        XCTAssertTrue(changes.isEmpty, "微小价格抖动不应产生改判记录：\(changes)")
    }

    func testReviseOnlyAppendsWhenSomethingActuallyChanged() {
        var memory = record(snapshot())
        XCTAssertNil(memory.revise(with: snapshot(), at: now.addingTimeInterval(60)))
        XCTAssertTrue(memory.revisions.isEmpty)
        let revision = memory.revise(with: snapshot(price: "1.450", headline: "持有"), at: now.addingTimeInterval(120))
        XCTAssertNotNil(revision)
        XCTAssertEqual(memory.revisions.count, 1)
        XCTAssertEqual(memory.revisions[0].fromHeadline, "反T · 先卖后买")
        XCTAssertEqual(memory.revisions[0].toHeadline, "持有")
        XCTAssertFalse(memory.revisions[0].changes.isEmpty)
        // 快照本身不能被改写：记忆要保留「当时」。
        XCTAssertEqual(memory.snapshot.price, "1.400")
    }

    func testMergeKeepsOnePendingRecordPerDayAndRecordsRevision() {
        let first = record(snapshot())
        let second = record(snapshot(price: "1.450", headline: "持有"))
        let merged = NextDecisionMemory.merge(existing: [first], incoming: [second])
        XCTAssertEqual(merged.count, 1, "同一天同一只只保留一条待处理记录")
        XCTAssertEqual(merged[0].snapshot.price, "1.400", "保留的是当时那一份快照")
        XCTAssertEqual(merged[0].revisions.count, 1)
    }

    func testExpireMarksExpiredWithoutProducingAnyFill() {
        let expiredAt = now.addingTimeInterval(-60)
        let open = record(snapshot(validUntil: expiredAt))
        let result = NextDecisionMemory.expire([open], at: now, quoteFor: { _ in Decimal(string: "1.400") })
        XCTAssertEqual(result[0].outcome, .expired)
        XCTAssertFalse(result[0].outcome.isFilled)
        XCTAssertNil(result[0].review.filledPrice)
        XCTAssertTrue(result[0].review.note.contains("未记录到真实成交"))
    }

    func testExpireInvalidatesWhenPriceBreaksAwayFromPlan() {
        let open = record(snapshot(limitPrice: "1.420"))
        let result = NextDecisionMemory.expire([open], at: now, quoteFor: { _ in Decimal(string: "1.500") })
        XCTAssertEqual(result[0].outcome, .invalidated)
        XCTAssertTrue(result[0].review.note.contains("原计划失效"))
    }

    func testReviewUsesRealFillAndNeverClaimsProfit() {
        var record = self.record(snapshot())
        record.outcome = .filled
        record.review.filledPrice = "1.418"
        record.review.filledUnits = 3000
        let review = NextDecisionMemory.review(record, laterPrice: Decimal(string: "1.404")!, at: now)
        XCTAssertEqual(review.filledUnits, 3000)
        XCTAssertEqual(review.laterChangePercent ?? 0, -0.9887, accuracy: 0.01)
        XCTAssertTrue(review.note.contains("仅复盘记录"), "复盘不能变成收益账户：\(review.note)")
    }

    func testReviewWithoutFillDoesNotPretendToHaveTraded() {
        let record = self.record(snapshot())
        let review = NextDecisionMemory.review(record, laterPrice: Decimal(string: "1.430")!, at: now)
        XCTAssertNil(review.filledPrice)
        XCTAssertTrue(review.note.contains("未记录真实成交"))
    }

    // MARK: - 新闻 → 持仓 → 计划

    private var currentNewsDate: String {
        ISO8601DateFormatter().string(from: now)
    }

    func testStaleOrUntimedHeadlineCannotInvalidateCurrentPlan() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "纳指ETF 公告停牌", source: "测试源", publishedAt: "2025-01-01T00:00:00Z"),
                     NextNewsInput(title: "纳指ETF 退市风险", source: "测试源")],
            hasTPlan: true, hasGridPlan: false, now: now)
        XCTAssertTrue(impact.isEmpty, "旧标题或没有发布时间的标题不能取消现在的交易计划")
    }

    func testMajorHeadlineInvalidatesReadyTPlan() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "纳指ETF 159941 公告：基金份额持有人大会决议停牌", source: "测试源", publishedAt: currentNewsDate)],
            hasTPlan: true, hasGridPlan: false, now: now)
        XCTAssertEqual(impact.severity, .major)
        XCTAssertEqual(impact.action, .pauseGrid, "停牌意味着无法成交，网格必须暂停")
        let item = guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil)
        let applied = NextNewsImpactEngine.apply(impact, to: item)
        XCTAssertFalse(applied.isActionable)
        XCTAssertNotNil(applied.newsImpact)
        XCTAssertTrue(applied.riskNotes.contains { $0.contains("停牌") })
    }

    func testDelistingHeadlineInvalidatesTPlan() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "某基金发布退市风险提示", publishedAt: currentNewsDate)],
            hasTPlan: true, hasGridPlan: true, now: now)
        XCTAssertEqual(impact.action, .invalidateT)
        let applied = NextNewsImpactEngine.apply(impact, to: guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil))
        XCTAssertFalse(applied.tPlan?.isReady == true)
        XCTAssertFalse(applied.isActionable)
    }

    func testUnrelatedOrNeutralHeadlinesChangeNothing() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "今天天气不错")],
            hasTPlan: true, hasGridPlan: true, now: now)
        XCTAssertTrue(impact.isEmpty)
        XCTAssertEqual(impact.action, .none)
        let item = guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil)
        let applied = NextNewsImpactEngine.apply(impact, to: item)
        XCTAssertTrue(applied.isActionable)
        XCTAssertTrue(applied.riskNotes.isEmpty)
    }

    func testWatchLevelHeadlineOnlyAddsNote() {
        let impact = NextNewsImpactEngine.evaluate(
            code: "159941", name: "纳指ETF",
            titles: [NextNewsInput(title: "纳指ETF 管理费费率下调 0.05%", publishedAt: currentNewsDate)],
            hasTPlan: true, hasGridPlan: false, now: now)
        XCTAssertEqual(impact.severity, .watch)
        XCTAssertEqual(impact.action, .watch)
        let applied = NextNewsImpactEngine.apply(impact, to: guidanceItem(tPlan: .ready(tPlan()), gridPlan: nil))
        XCTAssertTrue(applied.isActionable, "关注级新闻不能直接否掉计划")
        XCTAssertFalse(applied.riskNotes.isEmpty)
    }

    func testHeadlineMustBelongToTheHolding() {
        XCTAssertTrue(NextNewsImpactEngine.belongs("159941 今日放量", code: "159941", name: "纳指ETF"))
        XCTAssertTrue(NextNewsImpactEngine.belongs("纳指ETF 盘中溢价", code: "159941", name: "纳指ETF"))
        XCTAssertTrue(NextNewsImpactEngine.belongs("半导体板块走强", code: "512480", name: "半导体ETF",
                                                   industryWords: ["半导体"]))
        XCTAssertFalse(NextNewsImpactEngine.belongs("白酒板块走强", code: "512480", name: "半导体ETF",
                                                    industryWords: ["半导体"]))
    }

    // MARK: - 画像硬约束

    func testPlanCapsTranslateProfileIntoHardLimits() {
        var profile = NextInvestorProfile()
        profile.thresholds.maxTUnitsRatio = 0.25
        profile.thresholds.gridMaxTiers = 3
        profile.thresholds.gridMaxCashRatio = 0.4
        let book = NextBook(cash: 100_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let caps = NextPlanCaps.make(profile: profile, nasStats: nil, book: book, code: "159941",
                                     lotSize: 100, now: now)
        XCTAssertEqual(caps.maxTUnits, 2500)
        XCTAssertEqual(caps.maxGridTiers, 3)
        XCTAssertEqual(caps.maxGridCash, Decimal(string: "40000"))
        XCTAssertTrue(caps.gridNotes.first?.contains("40%") == true)
    }

    func testTPlannerCapsUnitsByProfileRatio() {
        let book = NextBook(cash: 50_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.400")!,
                              previousClose: Decimal(string: "1.396")!, time: now, source: "test")
        let result = NextTradeTPlanner.plan(kind: .reverse, book: book, quote: quote, daily: dailyBars(),
                                            intraday: oscillatingMinutes(), rules: rules(), orderBook: orderBook(),
                                            caps: NextPlanCaps(maxTUnits: 2000, tUnitsNote: "测试上限",
                                                               nasRoundTrips60: 3, nasDays: 60,
                                                               nasVolumeCoverage60: 0.95,
                                                               nasVwapHighDeviation60: 0.008,
                                                               nasVwapLowDeviation60: -0.008,
                                                               nasLongTermQuality: true,
                                                               nasFreshnessValid: true),
                                            now: now)
        guard case let .ready(plan) = result else {
            return XCTFail("反T 应能出价：\(result)")
        }
        XCTAssertEqual(plan.units, 2000, "份额必须被画像上限压住，而不是只在界面上提示")
        XCTAssertTrue(plan.evidence.contains { $0.contains("测试上限") })
        XCTAssertTrue(plan.evidence.contains { $0.contains("压到 2000 份") })
    }

    func testTPlannerRejectsStaleOrLowQualityNASStats() {
        let book = NextBook(cash: 50_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.400")!,
                              previousClose: Decimal(string: "1.396")!, time: now, source: "test")
        let result = NextTradeTPlanner.plan(kind: .reverse, book: book, quote: quote, daily: dailyBars(),
                                            intraday: oscillatingMinutes(), rules: rules(), orderBook: orderBook(),
                                            caps: NextPlanCaps(nasRoundTrips60: 3, nasDays: 120,
                                                               nasVolumeCoverage60: 1,
                                                               nasVwapHighDeviation60: 0.008,
                                                               nasVwapLowDeviation60: -0.008,
                                                               nasLongTermQuality: true,
                                                               nasFreshnessValid: false),
                                            now: now)
        guard case let .insufficientData(_, reasons) = result else {
            return XCTFail("过期NAS统计不得生成做T价格：\(result)")
        }
        XCTAssertTrue(reasons.contains { $0.contains("NAS 60 日") })
    }

    func testGridPlannerHonoursTierAndCashCaps() {
        let book = NextBook(cash: 100_000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "13800")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.400")!,
                              previousClose: Decimal(string: "1.396")!, time: now, source: "test")
        let check = NextGridCheck(code: "159941", name: "纳指ETF", barCount: 120, score: 80, grade: .suitable,
                                  annualVolatilityPercent: 20, avgAmplitudePercent: 1.6, avgTurnoverYi: 2.0,
                                  rangeBoundRatio: 0.6, atExtreme: false, isOnExchange: true, isETF: true,
                                  reasons: ["区间震荡"], warnings: [])
        let result = NextGridPlanner.plan(book: book, quote: quote, daily: dailyBars(), gridCheck: check,
                                          rules: rules(),
                                          nasRange: NextNasRange(stats: nasRangeStats()),
                                          orderBook: orderBook(),
                                          caps: NextPlanCaps(maxGridTiers: 2, maxGridCash: Decimal(string: "15000"),
                                                             gridNotes: ["资金封顶 15%"]),
                                          now: now)
        guard case let .ready(plan) = result else {
            return XCTFail("网格应能出价：\(result)")
        }
        XCTAssertLessThanOrEqual(plan.maxCashUsage, Decimal(string: "15000")!, "买入档资金占用不得超过画像上限")
        XCTAssertTrue(plan.reasons.contains { $0.contains("档数从") })
        XCTAssertTrue(plan.reasons.contains { $0.contains("资金封顶 15%") })
    }

    // MARK: - 夹具构造

    private func nasRangeStats() -> NextNASMinuteStats {
        let window = NextNASMinuteStats.Window(window: 60, daysUsed: 60, dayCoverage: 1,
            minuteCoverage: 0.95, vwap: "1.4000", closeVsVwapPercent: 0,
            amplitudeMedianPercent: 1.6, roundTripsMedian: 3,
            support: "1.3000", resistance: "1.5000", supportP10: "1.3000",
            resistanceP90: "1.5000", volatilityPercent: 20, volumeCoverage: 0.95)
        return NextNASMinuteStats(days: 60, minutes: 14_400, lastDay: "2026-10-23",
            quality: .init(days: 60, minuteCoverage: 0.95, hasVolume: true,
                           enoughForLongTerm: true, volumeCoverage: 0.95),
            freshness: .init(lastDay: "2026-10-23", ageMinutes: 60,
                             isToday: true, stale: false, reason: nil),
            windows: ["60": window])
    }

    private func orderBook() -> NextOrderBookSnapshot {
        NextOrderBookSnapshot(code: "159941", observedAt: now, source: "synthetic test fixture",
                              bids: ["1.399", "1.398", "1.397", "1.396", "1.395"].map {
                                  NextBookLevel(price: Decimal(string: $0)!, units: 2_000)
                              },
                              asks: ["1.401", "1.402", "1.403", "1.404", "1.405"].map {
                                  NextBookLevel(price: Decimal(string: $0)!, units: 2_000)
                              })
    }

    private func rules() -> NextInstrumentRules {
        NextInstrumentRules(code: "159941", market: "SZ", assetClass: .etf, settlement: .t0, lotSize: 100,
                            feePerTrade: Decimal(string: "0.10"), source: "fixture", verifiedAt: now)
    }

    private func tPlan() -> NextTPlan {
        NextTPlan(kind: .reverse, code: "159941", name: "纳指ETF", sellPrice: Decimal(string: "1.42")!,
                  buyPrice: Decimal(string: "1.38")!, units: 3000, grossSpread: Decimal(string: "0.04")!,
                  feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "119.80")!,
                  costReductionPerUnit: Decimal(string: "0.012")!,
                  estimatedMissedUpside: Decimal(string: "30.10")!,
                  estimatedContinuedDropLoss: Decimal(string: "29.50")!,
                  trampleRisk: "踏空风险", continuedDropRisk: "买入后继续下跌风险",
                  volumeSupport: "成交充足", validUntil: now.addingTimeInterval(3600),
                  cancelConditions: ["跌破 VWAP"], evidence: ["VWAP 1.398"],
                  confidence: NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 120,
                                                        minuteSampleCount: 200),
                  historyMissRate: nil)
    }

    private func guidanceItem(tPlan: NextTPlannerResult?, gridPlan: NextGridPlannerResult?) -> NextGuidanceItem {
        NextGuidanceItem(code: "159941", name: "纳指ETF", state: .narrowRange, strategy: .tTrade,
                         headline: "反T · 先卖后买", whyToday: ["振幅 2.9%"],
                         tPlan: tPlan, gridPlan: gridPlan, recovery: nil,
                         confidence: NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 120,
                                                               minuteSampleCount: 200),
                         portfolioNote: nil, riskNotes: [], score: 5, rank: 1, isActionable: true)
    }

    private func dailyBars() -> [NextChartSample] {
        // 120 根：1.38–1.42 区间反复，振幅约 1.4%，不创 60 日极端。
        (0..<120).map { index in
            let center = index % 2 == 0 ? 1.386 : 1.414
            let price = Decimal(string: String(format: "%.3f", center))!
            return NextChartSample(timestamp: now.addingTimeInterval(Double(index - 120) * 86_400),
                                   open: price,
                                   high: price * Decimal(string: "1.007")!,
                                   low: price * Decimal(string: "0.993")!,
                                   close: price, iopv: nil, volume: 3_000_000)
        }
    }

    private func oscillatingMinutes() -> [NextChartSample] {
        (0..<60).map { index in
            // 09:30 起每分钟一条，价格在 1.38–1.42 之间来回，保证 VWAP 与高低点都成立。
            let price = Decimal(string: String(format: "%.3f", index % 2 == 0 ? 1.386 : 1.414))!
            return NextChartSample(timestamp: now.addingTimeInterval(Double(index) * 60),
                                   open: price,
                                   high: price * Decimal(string: "1.002")!,
                                   low: price * Decimal(string: "0.998")!,
                                   close: price, iopv: nil, volume: 10_000)
        }
    }
}
