import XCTest
@testable import GuanpanAdvisorCore

final class NextCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1792375200)
    func quote(time: Date, price: Decimal = 1.4) -> NextQuote {
        NextQuote(code: "159941", name: "纳指ETF", price: price, previousClose: 1.4, time: time, source: "test")
    }
    func etfRules(_ code: String = "159941", settlement: NextSettlementRule = .t0, assetClass: NextAssetClass = .etf) -> NextInstrumentRules {
        NextInstrumentRules(code: code, market: "SZ", assetClass: assetClass, settlement: settlement, lotSize: 100, feePerTrade: Decimal(string: "0.10"), source: "verified test fixture", verifiedAt: now)
    }
    func testProfileLearnsExpectedThresholdWithoutCallingItRealizedProfit() {
        func suggestion(kind: NextPlanKind = .reverseT, gain: Decimal?, outcome: NextSuggestionOutcome = .executed) -> NextSuggestionRecord {
            var value = NextSuggestionRecord(code: "159941", name: "纳指ETF", kind: kind,
                expectedNetGain: gain, expectedSpreadPercent: 0.8,
                expectedCostReduction: Decimal(string: "0.001"), confidenceLevel: "high",
                marketState: "震荡", createdAt: now, expiresAt: now.addingTimeInterval(3600))
            value.outcome = outcome
            return value
        }
        var executed = suggestion(gain: Decimal(string: "8.50"))
        executed.outcome = .executed
        executed.executedNetGain = Decimal(string: "-2.00") // actual paired result differs; it must not be confused with plan estimate
        XCTAssertEqual(NextProfileEngine.executedExpectedNetGain(executed), 8.5)

        XCTAssertNil(NextProfileEngine.executedExpectedNetGain(suggestion(gain: Decimal(string: "8.50"), outcome: .pending)))
        XCTAssertNil(NextProfileEngine.executedExpectedNetGain(suggestion(gain: Decimal(string: "-1.00"))))
        XCTAssertNil(NextProfileEngine.executedExpectedNetGain(suggestion(kind: .gridBuy, gain: Decimal(string: "8.50"))))
    }
    func testProfileBehaviorWindowRejectsFutureAndOutOfWindowEvidence() {
        XCTAssertTrue(NextProfileEngine.isInBehaviorWindow(now, now: now))
        XCTAssertTrue(NextProfileEngine.isInBehaviorWindow(now.addingTimeInterval(-90 * 86_400), now: now))
        XCTAssertFalse(NextProfileEngine.isInBehaviorWindow(now.addingTimeInterval(1), now: now))
        XCTAssertFalse(NextProfileEngine.isInBehaviorWindow(now.addingTimeInterval(-90 * 86_400 - 1), now: now))
        XCTAssertFalse(NextProfileEngine.isInBehaviorWindow(now, now: now, days: 0))
    }
    func testGridPairedNetGainDeductsBothConfiguredFeesAndRejectsLossMakingPair() {
        XCTAssertEqual(NextGridPlanner.pairedExpectedNetGain(
            price: Decimal(string: "1.000")!, oppositePrice: Decimal(string: "1.010")!,
            units: 100, feePerTrade: Decimal(string: "0.10")!), Decimal(string: "0.80"))
        XCTAssertNil(NextGridPlanner.pairedExpectedNetGain(
            price: Decimal(string: "1.000")!, oppositePrice: Decimal(string: "1.001")!,
            units: 100, feePerTrade: Decimal(string: "0.10")!))
        XCTAssertNil(NextGridPlanner.pairedExpectedNetGain(
            price: Decimal(string: "1.000")!, oppositePrice: Decimal(string: "1.010")!,
            units: 0, feePerTrade: Decimal(string: "0.10")!))
    }
    func testPortfolioCapWithdrawsActionableGridPlan() {
        let confidence = NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 0, minuteSampleCount: 0)
        let plan = NextGridPlan(code: "159941", name: "纳指ETF", upper: 1.2, lower: 1.0,
            tiers: [NextGridTier(side: "buy", price: 1.1, units: 100, cashRequired: 110,
                                 expectedNetGain: 0.8)], maxCashUsage: 110,
            remainingUnitsAfterAllSells: 100, spacingPercent: 0.5,
            validUntil: now.addingTimeInterval(3600), pauseConditions: [], reasons: [],
            warnings: [], confidence: confidence)
        guard case let .notRecommended(reasons) = NextPortfolioRiskGuard.apply(
            overweightNote: "单只资产超组合上限", to: .ready(plan)) else {
            return XCTFail("组合超限时网格计划不应继续保持可执行")
        }
        XCTAssertTrue(reasons.joined(separator: " ").contains("组合上限"))
        guard case .ready = NextPortfolioRiskGuard.apply(overweightNote: nil, to: .ready(plan)) else {
            return XCTFail("没有超限时不应更改网格结果")
        }
    }
    func testPortfolioAllocationTargetInformsOrBlocksWithoutCreatingAnOrder() {
        let under = NextPortfolioRiskGuard.allocationAssessment(currentPercent: 12, concentrationLimit: 40,
                                                                targetPercent: 20)
        XCTAssertNil(under.blockingNote)
        XCTAssertTrue(under.context?.contains("长期配置排序参考") == true)
        XCTAssertGreaterThan(under.priorityBoost, 0)

        let overTarget = NextPortfolioRiskGuard.allocationAssessment(currentPercent: 21, concentrationLimit: 40,
                                                                     targetPercent: 20)
        XCTAssertTrue(overTarget.blockingNote?.contains("目标权重") == true)
        XCTAssertNil(overTarget.context)
        XCTAssertEqual(overTarget.priorityBoost, 0)

        let overLimit = NextPortfolioRiskGuard.allocationAssessment(currentPercent: 41, concentrationLimit: 40,
                                                                    targetPercent: 60)
        XCTAssertTrue(overLimit.blockingNote?.contains("组合上限") == true)
        XCTAssertEqual(overLimit.priorityBoost, 0)
        XCTAssertTrue(NextPortfolioRiskGuard.allocationAssessment(currentPercent: .infinity,
                                                                   concentrationLimit: 40,
                                                                   targetPercent: nil).blockingNote?.contains("无法可靠计算") == true)

        let noTarget = NextPortfolioRiskGuard.allocationAssessment(currentPercent: 12,
                                                                     concentrationLimit: 40,
                                                                     targetPercent: nil)
        XCTAssertNil(noTarget.blockingNote)
        XCTAssertNil(noTarget.context)
        XCTAssertEqual(noTarget.priorityBoost, 0)
    }
    func testCashReserveIsHardLimitForPlannedBuys() {
        let total = Decimal(10_000)
        XCTAssertNil(NextPortfolioRiskGuard.cashReserveBlock(availableCash: 3_000, totalAssets: total,
            targetCashPercent: 20, requiredCash: 1_000), "储备目标是 2,000 元，剩余 1,000 元可用于买入")
        let blocked = NextPortfolioRiskGuard.cashReserveBlock(availableCash: 3_000, totalAssets: total,
            targetCashPercent: 20, requiredCash: 1_001)
        XCTAssertTrue(blocked?.contains("超过现金扣除长期储备目标") == true)
        XCTAssertTrue(NextPortfolioRiskGuard.cashReserveBlock(availableCash: 0, totalAssets: total,
            targetCashPercent: 20, requiredCash: 1)?.contains("暂停新增买入") == true)
        XCTAssertNil(NextPortfolioRiskGuard.cashReserveBlock(availableCash: 100, totalAssets: nil,
            targetCashPercent: nil, requiredCash: 100), "没有配置长期现金目标时不增加此限制")
        XCTAssertNotNil(NextPortfolioRiskGuard.cashReserveBlock(availableCash: 99, totalAssets: nil,
            targetCashPercent: nil, requiredCash: 100), "无储备目标时也必须守住真实可用现金")
        XCTAssertNotNil(NextPortfolioRiskGuard.cashReserveBlock(availableCash: 100, totalAssets: nil,
            targetCashPercent: 20, requiredCash: 0), "设置了现金目标但总资产不可核验时必须 fail-closed")

        let confidence = NextDataConfidence.assess(quote: quote(time: now), now: now,
            dailyBarCount: 60, minuteSampleCount: 120, intradayLatestAt: now, dailyLatestAt: now)
        let forward = NextTPlan(kind: .forward, code: "159941", name: "纳指ETF",
            sellPrice: Decimal(string: "1.520")!, buyPrice: Decimal(string: "1.500")!, units: 1_000,
            grossSpread: 20, feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "19.80")!,
            costReductionPerUnit: Decimal(string: "0.0198")!, estimatedMissedUpside: 1,
            estimatedContinuedDropLoss: 1, trampleRisk: "测试风险", continuedDropRisk: "测试下跌",
            volumeSupport: "测试流动性", validUntil: now.addingTimeInterval(3600), cancelConditions: [],
            evidence: [], confidence: confidence, historyMissRate: nil)
        guard case .notWorthwhile = NextPortfolioRiskGuard.applyCashReserve(availableCash: 3_000,
            totalAssets: total, targetCashPercent: 20, to: .ready(forward)) else {
            return XCTFail("正T首笔买入会跌破现金储备时必须撤回")
        }
        let grid = NextGridPlan(code: "159941", name: "纳指ETF", upper: 1.6, lower: 1.2,
            tiers: [NextGridTier(side: "buy", price: 1.5, units: 1_000, cashRequired: 1_500.1,
                                 expectedNetGain: 19.8)], maxCashUsage: 1_500.1,
            remainingUnitsAfterAllSells: 0, spacingPercent: 1,
            validUntil: now.addingTimeInterval(3600), pauseConditions: [], reasons: [], warnings: [],
            confidence: confidence)
        guard case .notRecommended = NextPortfolioRiskGuard.applyCashReserve(availableCash: 3_000,
            totalAssets: total, targetCashPercent: 20, to: .ready(grid)) else {
            return XCTFail("最坏情形下网格买档会跌破现金储备时必须撤回")
        }
    }
    func testRecoveryAddOptionRequiresCompletePortfolioQuotesAndCashGuard() {
        let held = NextPosition(code: "159941", name: "纳指ETF", units: 1_000, bookCost: 2_000)
        let other = NextPosition(code: "563020", name: "行业ETF", units: 1_000, bookCost: 3_000)
        let book = NextBook(cash: 10_000, positions: [held, other])
        let ownQuote = quote(time: now)
        let missingOther = NextRecoveryAnalyzer.analyze(book: book, quotes: [held.code: ownQuote],
            quote: ownQuote, rules: etfRules(), goal: NextGoal(concentrationLimit: 100), tNetGain: nil, now: now)
        XCTAssertEqual(missingOther?.addOption?.allowed, false,
            "缺少其他持仓的行情时，不能把组合总值默认为零并放行补仓")
        XCTAssertTrue(missingOther?.addOption?.note.contains("组合占比无法核验") == true)

        let otherQuote = NextQuote(code: other.code, name: other.name, price: 1.4, previousClose: 1.4,
                                   time: now, source: "test")
        let completeQuotes = [held.code: ownQuote, other.code: otherQuote]
        let reserveBlocks = NextRecoveryAnalyzer.analyze(book: book, quotes: completeQuotes, quote: ownQuote,
            rules: etfRules(), goal: NextGoal(concentrationLimit: 100, targetWeights: [held.code: 10]),
            tNetGain: nil, now: now)
        XCTAssertEqual(reserveBlocks?.addOption?.allowed, false,
            "补仓资金会侵占目标现金储备时，不应显示允许")

        let noReserve = NextRecoveryAnalyzer.analyze(book: book, quotes: completeQuotes, quote: ownQuote,
            rules: etfRules(), goal: NextGoal(concentrationLimit: 100), tNetGain: nil, now: now)
        XCTAssertEqual(noReserve?.addOption?.allowed, true,
            "报价完整、现金足够且未超集中度时，补仓情景可以标为通过账户守卫")
        XCTAssertEqual(noReserve?.addOption?.newAverageCost, Decimal(string: "1.70005"),
            "新成本应含真实买入手续费，并按持仓账面成本和实际新增份额重算")
    }
    func testCandidatePlanLinksToSameDayDecisionMemoryAcrossRevision() throws {
        let expires = now.addingTimeInterval(3600)
        let plan = NextCandidatePlan(kind: .gridBuy, code: "159941", name: "纳指ETF",
            limitPrice: Decimal(string: "1.380")!, units: 200, createdAt: now, expiresAt: expires,
            triggerNote: "回落触发", cancelNote: "突破区间", quoteSource: "test", quoteTime: now,
            dailyBarCount: 120, minuteSampleCount: 0, confidenceLevel: "high",
            rationale: "manual candidate", expectedNetGain: nil, expectedCostReduction: nil,
            riskNote: "波动风险", marketState: "震荡", cancelAbove: nil, cancelBelow: nil)
        let original = NextDecisionSnapshot(state: "宽幅震荡", strategy: "做T", headline: "先观察做T",
            validUntil: now.addingTimeInterval(-600), limitPrice: "1.400", limitUnits: 100,
            confidenceLevel: "high")
        var record = NextDecisionRecord(code: plan.code, name: plan.name,
            createdAt: now.addingTimeInterval(-3_600), snapshot: original)
        _ = record.revise(with: NextDecisionSnapshot(state: "宽幅震荡", strategy: "网格",
            headline: "网格计划", validUntil: now.addingTimeInterval(1800),
            limitPrice: "1.380", limitUnits: 200, confidenceLevel: "high"),
            at: now.addingTimeInterval(-30))
        XCTAssertEqual(NextDecisionMemory.matchingRecordID(for: plan, records: [record]), record.id,
            "同日改判到网格后，网格候选应链接最新判断，同时保留最初做T快照")
        let otherDay = NextDecisionRecord(code: plan.code, name: plan.name,
            createdAt: now.addingTimeInterval(-86_400), snapshot: original)
        XCTAssertNil(NextDecisionMemory.matchingRecordID(for: plan, records: [otherDay]))
        let otherStrategy = NextDecisionRecord(code: plan.code, name: plan.name,
            createdAt: now, snapshot: NextDecisionSnapshot(state: "震荡", strategy: "持有",
                headline: "继续持有", confidenceLevel: "high"))
        XCTAssertNil(NextDecisionMemory.matchingRecordID(for: plan, records: [otherStrategy]))

        var filled = record
        XCTAssertTrue(NextDecisionMemory.confirmFill(&filled, price: Decimal(string: "1.379")!, units: 100, at: now))
        XCTAssertEqual(filled.outcome, .filled)
        XCTAssertEqual(filled.review.filledUnits, 100)
        XCTAssertEqual(filled.review.filledPrice, NextMoney.text(Decimal(string: "1.379")!, digits: 4))
        var invalid = record
        XCTAssertFalse(NextDecisionMemory.confirmFill(&invalid, price: 0, units: 100, at: now))
        XCTAssertEqual(invalid.outcome, .pending, "无效回填不能把建议误记为成交")
        let encoded = try JSONEncoder().encode(plan)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "decisionMemoryID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacyPlan = try JSONDecoder().decode(NextCandidatePlan.self, from: legacyData)
        XCTAssertNil(decodedLegacyPlan.decisionMemoryID, "旧版候选计划缺少关联字段时仍应可读取")
    }
    func testWithdrawnGuidanceCannotBeSavedAsCandidatePlan() {
        let confidence = NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 0, minuteSampleCount: 0)
        let blocked = NextGuidanceItem(code: "159941", name: "纳指ETF", state: .wideRange,
            strategy: .grid, headline: "组合风险暂停", whyToday: [], tPlan: nil, gridPlan: nil,
            recovery: nil, confidence: confidence, portfolioNote: "已超过目标权重", riskNotes: [],
            score: 0, rank: 1, isActionable: false)
        XCTAssertTrue(NextPortfolioRiskGuard.candidateSaveBlock(for: blocked, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: nil, currentLedgerFingerprint: nil, quote: nil, now: now)?
            .contains("已超过目标权重") == true)
        let quote = quote(time: now)
        let readyConfidence = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 60,
            minuteSampleCount: 60, intradayLatestAt: now, dailyLatestAt: now)
        let plan = NextTPlan(kind: .reverse, code: "159941", name: "纳指ETF",
            sellPrice: Decimal(string: "1.500")!, buyPrice: Decimal(string: "1.490")!, units: 100,
            grossSpread: 1, feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "0.80")!,
            costReductionPerUnit: Decimal(string: "0.008")!, estimatedMissedUpside: 1,
            estimatedContinuedDropLoss: 1, trampleRisk: "踏空风险", continuedDropRisk: "继续下跌风险",
            volumeSupport: "成交量支持", validUntil: now.addingTimeInterval(8 * 3600), cancelConditions: [],
            evidence: ["分钟价量统计"], confidence: readyConfidence, historyMissRate: nil)
        let actionable = NextGuidanceItem(code: "159941", name: "纳指ETF", state: .wideRange,
            strategy: .tTrade, headline: "规则计划可执行", whyToday: [], tPlan: .ready(plan), gridPlan: nil,
            recovery: nil, confidence: readyConfidence, portfolioNote: nil, riskNotes: [],
            score: 1, rank: 1, isActionable: true)
        XCTAssertNil(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: "account-v1", currentLedgerFingerprint: "account-v1",
            quote: quote, now: now))
        XCTAssertTrue(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: "account-v1", currentLedgerFingerprint: "account-v1",
            quote: self.quote(time: now.addingTimeInterval(-121)), now: now)?
            .contains("过期") == true, "保存时必须复核当前行情，而不是只信任生成时的数据")
        XCTAssertTrue(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: "account-v1", currentLedgerFingerprint: "account-v1",
            quote: self.quote(time: now.addingTimeInterval(6 * 3600)), now: now.addingTimeInterval(6 * 3600))?
            .contains("交易时段") == true, "收盘后不得保存为当日可执行计划")
        XCTAssertTrue(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable,
            guidanceGeneratedAt: now.addingTimeInterval(-121), guidanceLedgerFingerprint: "account-v1",
            currentLedgerFingerprint: "account-v1", quote: quote, now: now)?
            .contains("今日指导已过期") == true, "过期的持仓/新闻/风险决策不得重新包装成新计划")
        XCTAssertTrue(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: "account-v1", currentLedgerFingerprint: "account-v2",
            quote: quote, now: now)?.contains("真实持仓、现金或成交流水") == true,
            "持仓或现金改变后不得保存旧账户状态对应的计划")
        XCTAssertNotNil(NextPortfolioRiskGuard.candidateSaveBlock(for: actionable, guidanceGeneratedAt: now,
            guidanceLedgerFingerprint: nil, currentLedgerFingerprint: "account-v1", quote: quote, now: now),
            "没有指导时账户快照必须拒绝保存")
    }
    func testCandidatePlanSaveRechecksLiveInvalidationLines() {
        let plan = NextCandidatePlan(kind: .gridBuy, code: "159941", name: "纳指ETF",
            limitPrice: Decimal(string: "1.300")!, units: 100, createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(3600), triggerNote: "回落买入", cancelNote: "突破区间",
            quoteSource: "test", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 0,
            confidenceLevel: "high", rationale: "测试", expectedNetGain: nil, expectedCostReduction: nil,
            riskNote: "波动", marketState: "震荡", cancelAbove: Decimal(string: "1.500")!,
            cancelBelow: Decimal(string: "1.250")!)
        XCTAssertNil(NextPortfolioRiskGuard.currentPlanQuoteBlock(for: plan,
            quote: quote(time: now, price: Decimal(string: "1.400")!), now: now))
        XCTAssertTrue(NextPortfolioRiskGuard.currentPlanQuoteBlock(for: plan,
            quote: quote(time: now, price: Decimal(string: "1.240")!), now: now)?.contains("下方失效线") == true)
        XCTAssertNotNil(NextPortfolioRiskGuard.currentPlanQuoteBlock(for: plan,
            quote: quote(time: now.addingTimeInterval(-121)), now: now))
        XCTAssertNotNil(NextPortfolioRiskGuard.currentPlanQuoteBlock(for: plan,
            quote: nil, now: now))
    }
    func testHomeNASStatusRequiresRecentHealthProbe() {
        let now = Date(timeIntervalSince1970: 1_797_375_200)
        XCTAssertFalse(NextServiceConnectionStatus.isOnline(configured: true, reachable: nil, probedAt: nil, now: now))
        XCTAssertEqual(NextServiceConnectionStatus.text(configured: true, reachable: nil, probedAt: nil, now: now), "待检测")

        XCTAssertFalse(NextServiceConnectionStatus.isOnline(configured: true, reachable: false, probedAt: now, now: now))
        XCTAssertTrue(NextServiceConnectionStatus.text(configured: true, reachable: false, probedAt: now, now: now).contains("离线"))

        XCTAssertFalse(NextServiceConnectionStatus.isOnline(configured: true, reachable: true,
                                                            probedAt: now.addingTimeInterval(-600), now: now))
        XCTAssertEqual(NextServiceConnectionStatus.text(configured: true, reachable: true,
                                                        probedAt: now.addingTimeInterval(-600), now: now), "状态待检测")

        XCTAssertFalse(NextServiceConnectionStatus.isOnline(configured: false, reachable: true, probedAt: now, now: now))
        XCTAssertEqual(NextServiceConnectionStatus.text(configured: true, reachable: true, probedAt: now, now: now), "刚刚检测在线")
        XCTAssertFalse(NextServiceConnectionStatus.isOnline(configured: true, reachable: true,
                                                            probedAt: now.addingTimeInterval(1), now: now),
                       "未来探测时间不可显示在线")
    }
    func testIncomeAndDividendDataRoundTripsAndDoesNotRequireOldBookKeys() throws {
        let planned = NextIncomeEvent(kind: .etfDistribution, code: "563020", name: "红利ETF",
            exDate: now, payDate: now.addingTimeInterval(86400), units: 100,
            perUnit: Decimal(string: "0.012"), grossAmount: Decimal(string: "1.20")!, tax: Decimal(string: "0.10")!)
        try planned.validate()
        var book = NextBook(cash: 50, incomeEvents: [planned],
            dividendEvents: [NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!,
                isEstimated: false, recordDate: "2026-06-09", payDate: "2026-06-15")])
        let encoded = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(NextBook.self, from: encoded)
        XCTAssertEqual(decoded.incomeEvents.first?.netAmount, Decimal(string: "1.10"))
        XCTAssertEqual(decoded.dividendEvents.count, 1)
        XCTAssertEqual(decoded.dividendEvents[0].recordDate, "2026-06-09")
        XCTAssertEqual(decoded.dividendEvents[0].payDate, "2026-06-15")
        XCTAssertNoThrow(try decoded.validate())
        let old = "{\"schemaVersion\":1,\"id\":\"\(UUID().uuidString)\",\"cash\":0,\"positions\":[],\"fills\":[],\"history\":[]}"
        XCTAssertNoThrow(try JSONDecoder().decode(NextBook.self, from: Data(old.utf8)))
        book.incomeEvents[0].tax = Decimal(string: "2.00")!
        XCTAssertThrowsError(try book.incomeEvents[0].validate())
    }
    func testBookRejectsMalformedFillAndHistoryValuesBeforeBackup() throws {
        let malformedFill = NextFill(date: now, code: "159941", side: "purchase", units: 100,
                                     price: 1.2, fee: 0.1, realized: 0)
        XCTAssertThrowsError(try NextBook(fills: [malformedFill]).validate())
        let malformedPoint = NextAssetPoint(date: now, total: -1, externalFlow: 0)
        XCTAssertThrowsError(try NextBook(history: [malformedPoint]).validate())
        let validFill = NextFill(date: now, code: "159941", side: "buy", units: 100,
                                 price: 1.2, fee: 0.1, realized: 0)
        XCTAssertNoThrow(try NextBook(fills: [validFill]).validate())
    }
    func testDividendAnalyticsUsesSuppliedRecordsWithoutBundledHistory() {
        let events = NextDividendAnalytics.merged([
            NextETFDividendEvent(code: "159545", date: "2026-05-15", amountPerShare: Decimal(string: "0.014")!, isEstimated: true),
            NextETFDividendEvent(code: "159941", date: "2026-05-15", amountPerShare: Decimal(string: "0.100")!)
        ])
        XCTAssertTrue(events.contains { $0.code == "159545" && $0.isEstimated == true })
        XCTAssertTrue(events.contains { $0.code == "159941" && $0.date == "2026-05-15" })
        XCTAssertFalse(events.contains { $0.code == "563020" }, "没有真实来源时不得注入内置分红样例")
    }

    func testMissingQuoteDoesNotPretendAssetTotal() {
        var book = NextBook(); book.cash = 100
        book.positions = [NextPosition(code: "159941", name: "纳指ETF", units: 100, bookCost: 120)]
        XCTAssertNil(book.total(using: [:]))
        XCTAssertEqual(book.total(using: ["159941": quote(time: now)]), 240)
        XCTAssertEqual(book.positions[0].costPerUnit, 1.2)
    }
    /// 当日盈亏必须与持仓列表（PortfolioSummary）同一口径：
    /// 只要每只持仓都有可用行情就出数，行情是缓存的也照样给（新鲜度由 quality 标注，
    /// 不谎称实时）；缺报价、或报价异常（疑似串号）才保守隐藏。
    /// 旧逻辑额外要求「全部行情都新鲜」，会出现首页/真实资产页显示
    /// 「需完整新鲜行情」而持仓列表照样给数 —— 同一个数两处不一致。
    func testDailyAssetChangeMatchesHoldingsSummaryRegardlessOfFreshness() {
        var book = NextBook(); book.cash = 100
        book.positions = [NextPosition(code: "159941", name: "纳指ETF", units: 100, bookCost: 120)]
        let fresh = quote(time: now, price: 1.5)
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let value = book.valuation(using: ["159941": NextCachedQuote(quote: fresh, stamp: stamp)], at: now)
        XCTAssertEqual(value.total, 250)
        XCTAssertEqual(value.dailyChange, 10)
        XCTAssertEqual(NSDecimalNumber(decimal: value.dailyChangePercent ?? 0).doubleValue, 4.1666666667, accuracy: 0.000001)
        // 缓存行情：仍然给数（与持仓列表一致），但 quality 不能是实时
        let stale = quote(time: now.addingTimeInterval(-3600), price: 1.5)
        let oldStamp = NextDataStamp(source: "test", observedAt: stale.time, quality: .cached, detail: "")
        let staleValue = book.valuation(using: ["159941": NextCachedQuote(quote: stale, stamp: oldStamp)], at: now)
        XCTAssertEqual(staleValue.dailyChange, 10)
        XCTAssertTrue(staleValue.quality != .live)
        // 缺报价：绝不把部分估值当作当日盈亏
        XCTAssertNil(book.valuation(using: [:], at: now).dailyChange)
        // 报价异常（疑似串号）：保守隐藏，与持仓列表一致
        let bogus = quote(time: now, price: 5)
        let bogusStamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let bogusValue = book.valuation(using: ["159941": NextCachedQuote(quote: bogus, stamp: bogusStamp)], at: now)
        XCTAssertNil(bogusValue.dailyChange)
        XCTAssertNil(bogusValue.total)
    }
    func testOnlineQuoteCacheLabelAgesWithoutAnotherNetworkRequest() {
        let observed = now.addingTimeInterval(-3600)
        let stamp = NextDataStamp(source: "feed", observedAt: observed, quality: .live, detail: "")
        XCTAssertTrue(stamp.label(now: now).contains("缓存"))
        XCTAssertTrue(stamp.label(now: now).contains("60 分钟前"))
    }
    func testBudgetDoesNotDependOnRealCashOrMutateBook() throws {
        let book = NextBook(); let goal = NextGoal()
        let result = try NextResearch.prepare(book: book, goal: goal, quotes: [:], now: now)
        XCTAssertEqual(result.options.count, 2)
        XCTAssertEqual(book.cash, 0)
        XCTAssertEqual(result.origin, "本地规则检查")
    }
    func testModelEvidenceMustExistAndDescribeTradeoff() throws {
        let result = try NextResearch.prepare(book: NextBook(), goal: NextGoal(), quotes: [:], now: now)
        XCTAssertEqual(try NextResearch.acceptModelOptions(result.options, evidence: result.evidence).count, 2)
        let fake = NextOption(id: "fake", title: "方案", rationale: "理由", tradeoff: "未知", evidenceIDs: ["invented"])
        XCTAssertThrowsError(try NextResearch.acceptModelOptions([fake, result.options[0]], evidence: result.evidence))
    }
    func testPatientBuyAnalysisRequiresFreshQuoteAndCitedPriceResearch() throws {
        var book = NextBook(); book.cash = 0
        var goal = NextGoal(); goal.monthlyBudget = 1000
        let facts = [NextEvidence(id: "range-source", title: "估值区间", detail: "样例依据", level: "事实", observedAt: now)]
        let range = NextPriceResearch(lower: 1.4, upper: 1.6, evidenceIDs: ["range-source"], observedAt: now)
        let missing = try NextBuyOpportunity.prepare(code: "159941", book: book, goal: goal, quote: nil, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertFalse(missing.canSavePlan)
        XCTAssertTrue(missing.limitSteps.isEmpty)
        let q = quote(time: now)
        let stale = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "cache", observedAt: now.addingTimeInterval(-900), quality: .stale, detail: "old"))
        let staleResult = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: stale, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertFalse(staleResult.canSavePlan)
        let live = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "licensed:feed", observedAt: now, quality: .live, detail: ""))
        let plan = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: live, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertTrue(plan.canSavePlan, plan.riskSummary)
        XCTAssertEqual(plan.limitSteps.count, 2, plan.riskSummary)
        XCTAssertEqual(plan.limitSteps[0].fee, Decimal(string: "0.10"))
        XCTAssertEqual(book.cash, 0, "planning never spends the real ledger")
        let unverified = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: live, research: range, rules: nil, evidence: facts, now: now)
        XCTAssertFalse(unverified.canSavePlan, "a plausible lot size must not be guessed")
        let publicFeed = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "Tencent qt.gtimg.cn", observedAt: now, quality: .live, detail: ""))
        XCTAssertFalse(publicFeed.usableForPricePlan(at: now), "public quotes remain display-only until a vetted price-plan source is configured")
    }
    func testPriceResearchCannotReferenceInventedEvidence() throws {
        let range = NextPriceResearch(lower: 1.2, upper: 1.4, evidenceIDs: ["made-up"], observedAt: now)
        XCTAssertThrowsError(try range.validate(evidence: []))
    }
    func testAuditedBookCanUndoOnlyTheLatestMatchingChange() throws {
        var ledger = NextAuditedBook(current: NextBook())
        var changed = ledger.current; changed.cash = 100
        try ledger.apply(changed, action: "修改现金", reason: "用户确认", at: now)
        let id = try XCTUnwrap(ledger.events.last?.id)
        try ledger.undo(id, at: now.addingTimeInterval(1))
        XCTAssertEqual(ledger.current.cash, 0)
        XCTAssertNotNil(ledger.events.last?.undoneAt)
        XCTAssertThrowsError(try ledger.undo(id, at: now.addingTimeInterval(2)))
    }
    func testNotificationDedupeAndQuietHoursAcrossMidnight() {
        var center = NextNotificationCenter(); center.dedupeMinutes = 30
        center.quietHours = NextQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 15))!
        XCTAssertTrue(center.quietHours.isQuiet(date, calendar: calendar))
        let stamp = NextDataStamp(source: "feed", observedAt: date, quality: .live, detail: "")
        let alert = NextAlert(fingerprint: "159941:price:1.5", level: "P1", title: "观察价", detail: "触发", createdAt: date, stamp: stamp)
        XCTAssertTrue(center.append(alert, now: date))
        var duplicate = alert; duplicate.id = UUID()
        XCTAssertFalse(center.append(duplicate, now: date.addingTimeInterval(60)))
        XCTAssertEqual(center.alerts.count, 1)
    }
    func testPriceAlertRuleRequiresAValidInstrumentAndPositivePrice() throws {
        let valid = NextPriceAlertRule(code: "159941", name: "纳指ETF", price: 1.2, direction: .atOrBelow)
        XCTAssertNoThrow(try valid.validate())
        XCTAssertThrowsError(try NextPriceAlertRule(code: "bad", name: "", price: 0, direction: .atOrAbove).validate())
    }
    func testNavigationRestoresSecurityFiltersChartAndCrosshair() throws {
        var nav = NextNavigationState(); nav.listFilters["market"] = "ETF"; nav.scrollAnchors["watchlist"] = "159941"
        nav.openInstrument("159941"); nav.openIntent("buy-opportunity", code: "159941")
        nav.tabRoutes[NextTab.market.rawValue] = [.instrument("159941"), .chart("159941")]
        nav.chartStates["159941"] = NextChartState(interval: "1d", visibleLayers: ["price", "iopv", "cost"], lowerBound: now, upperBound: now.addingTimeInterval(60), crosshairTime: now.addingTimeInterval(20), scale: 2)
        let roundTrip = try JSONDecoder().decode(NextNavigationState.self, from: JSONEncoder().encode(nav))
        XCTAssertEqual(roundTrip, nav)
        XCTAssertEqual(roundTrip.selectedSecurity, "159941")
        XCTAssertEqual(roundTrip.chartStates["159941"]?.crosshairTime, now.addingTimeInterval(20))
    }
    func testPatientLimitPlanIsAValidatedReminderAndRequiresFreshQuote() throws {
        let plan = NextPatientLimitPlan(id: UUID(), code: "159941", name: "纳指ETF", limitPrice: Decimal(string: "1.35")!, units: 100,
            createdAt: now, expiresAt: now.addingTimeInterval(86400))
        try plan.validate()
        XCTAssertTrue(plan.shouldTrigger(with: quote(time: now, price: Decimal(string: "1.35")!), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: quote(time: now, price: Decimal(string: "1.36")!), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: quote(time: now.addingTimeInterval(-121), price: 1.2), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: NextQuote(code: "563020", name: "其他ETF", price: 1, previousClose: 1, time: now, source: "test"), at: now))
        var paused = plan; paused.state = "已暂停"
        try paused.validate()
        XCTAssertFalse(paused.shouldTrigger(with: quote(time: now, price: 1.2), at: now))
        var invalid = plan
        invalid.state = "已成交"
        XCTAssertThrowsError(try invalid.validate())
    }
    func testCandidatePlanTracksTwoRealPartialFillsWithoutInventingTheRemainder() throws {
        var plan = NextCandidatePlan(kind: .reverseT, code: "512480", name: "半导体ETF",
            limitPrice: Decimal(string: "0.850")!, units: 500,
            createdAt: now, expiresAt: now.addingTimeInterval(3600),
            triggerNote: "券商手工卖出", cancelNote: "突破区间时取消",
            quoteSource: "test", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 200,
            confidenceLevel: "high", rationale: "长期分时", expectedNetGain: 9,
            expectedCostReduction: Decimal(string: "0.018")!, riskNote: "踏空",
            marketState: "宽幅震荡", cancelAbove: nil, cancelBelow: nil)
        try plan.confirmRealFill(price: Decimal(string: "0.850")!, units: 300,
                                 fee: Decimal(string: "0.10")!, at: now.addingTimeInterval(10),
                                 now: now.addingTimeInterval(10))
        XCTAssertEqual(plan.state, .partiallyConfirmed)
        XCTAssertEqual(plan.confirmedUnits, 300)
        XCTAssertEqual(plan.remainingUnits, 200)
        XCTAssertThrowsError(try plan.confirmRealFill(price: 0.86, units: 300, fee: 0.1,
            at: now.addingTimeInterval(15), now: now.addingTimeInterval(15)))
        XCTAssertEqual(plan.remainingUnits, 200, "超量成交反馈不得改变计划")
        try plan.confirmRealFill(price: Decimal(string: "0.860")!, units: 200,
                                 fee: Decimal(string: "0.10")!, at: now.addingTimeInterval(20),
                                 now: now.addingTimeInterval(20))
        XCTAssertEqual(plan.state, .confirmed)
        XCTAssertEqual(plan.confirmedUnits, 500)
        XCTAssertEqual(plan.remainingUnits, 0)
        XCTAssertEqual(plan.confirmedPrice, Decimal(string: "0.854")!)
        XCTAssertEqual(plan.confirmedFee, Decimal(string: "0.20")!)
        XCTAssertThrowsError(try plan.confirmRealFill(price: 0.86, units: 1, fee: 0.1,
            at: now.addingTimeInterval(30), now: now.addingTimeInterval(30)))
    }
    func testCandidatePlanReconcilesProgressOnlyFromLinkedRealLedgerFills() {
        let planID = UUID()
        var plan = NextCandidatePlan(id: planID, kind: .reverseT, code: "512480", name: "半导体ETF",
            limitPrice: Decimal(string: "0.850")!, units: 500,
            createdAt: now, expiresAt: now.addingTimeInterval(3600),
            triggerNote: "券商手工卖出", cancelNote: "突破区间时取消",
            quoteSource: "test", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 200,
            confidenceLevel: "high", rationale: "账本恢复测试", expectedNetGain: 9,
            expectedCostReduction: Decimal(string: "0.018")!, riskNote: "踏空",
            marketState: "宽幅震荡", cancelAbove: nil, cancelBelow: nil)
        plan.state = .invalidated
        let fills = [
            NextFill(date: now.addingTimeInterval(10), code: "512480", side: "sell", units: 200,
                    price: Decimal(string: "0.850")!, fee: Decimal(string: "0.10")!, realized: 0,
                    candidatePlanID: planID),
            NextFill(date: now.addingTimeInterval(20), code: "512480", side: "sell", units: 300,
                    price: Decimal(string: "0.860")!, fee: Decimal(string: "0.10")!, realized: 0,
                    candidatePlanID: planID),
            NextFill(date: now.addingTimeInterval(30), code: "159941", side: "sell", units: 100,
                    price: 1, fee: Decimal(string: "0.10")!, realized: 0)
        ]

        XCTAssertTrue(plan.reconcileLedgerFills(fills))
        XCTAssertEqual(plan.confirmedUnits, 500)
        XCTAssertEqual(plan.confirmedPrice, Decimal(string: "0.856")!)
        XCTAssertEqual(plan.confirmedFee, Decimal(string: "0.20")!)
        XCTAssertEqual(plan.confirmedAt, now.addingTimeInterval(20))
        XCTAssertEqual(plan.state, .confirmed)
        XCTAssertFalse(plan.canConfirmRealFill)
        XCTAssertFalse(plan.reconcileLedgerFills(fills), "relaunch reconciliation must be idempotent")

        var untouched = plan
        untouched.confirmedUnits = nil
        untouched.confirmedPrice = nil
        untouched.confirmedFee = nil
        untouched.confirmedAt = nil
        XCTAssertFalse(untouched.reconcileLedgerFills([
            NextFill(date: now.addingTimeInterval(10), code: "512480", side: "buy", units: 200,
                    price: 0.85, fee: 0.1, realized: 0, candidatePlanID: planID)
        ]), "a linked but mismatched code/side is not valid fill evidence")
        XCTAssertNil(untouched.confirmedUnits)
    }
    func testLegacyLedgerFillWithoutCandidatePlanIDStillDecodes() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","date":1792375200,"code":"159941","side":"buy","units":100,"price":1.4,"fee":0.1,"realized":0}"#.data(using: .utf8)!
        let fill = try JSONDecoder().decode(NextFill.self, from: json)
        XCTAssertNil(fill.candidatePlanID, "升级前的真实流水继续可读，且不会被猜测关联候选计划")
        XCTAssertNil(fill.decisionMemoryID)
        XCTAssertEqual(fill.code, "159941")
    }
    func testCandidatePlanInvalidatesWhenQuoteCannotSafelyValidateIt() throws {
        func plan() -> NextCandidatePlan {
            NextCandidatePlan(kind: .reverseT, code: "159941", name: "纳指ETF",
                limitPrice: Decimal(string: "1.450")!, units: 100,
                createdAt: now, expiresAt: now.addingTimeInterval(3600),
                triggerNote: "触及计划价", cancelNote: "行情或区间失效",
                quoteSource: "test", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 200,
                confidenceLevel: "high", rationale: "仅用于状态迁移回归测试", expectedNetGain: nil,
                expectedCostReduction: nil, riskNote: "行情风险", marketState: "震荡",
                cancelAbove: nil, cancelBelow: nil)
        }
        func quote(code: String = "159941", time: Date? = nil,
                   timeQuality: String? = "exchange_time", price: Decimal = 1.4) -> NextQuote {
            NextQuote(code: code, name: "纳指ETF", price: price, previousClose: 1.4,
                      time: time ?? now, source: "test", timeQuality: timeQuality)
        }

        let invalidCases: [(String, NextQuote?)] = [
            ("缺失行情", nil),
            ("证券代码不符", quote(code: "510300")),
            ("供应商时间超前", quote(time: now.addingTimeInterval(61))),
            ("仅有接收时间", quote(timeQuality: "receipt_only")),
            ("报价过期", quote(time: now.addingTimeInterval(-121))),
            ("无效价格", quote(price: 0))
        ]
        for (label, incoming) in invalidCases {
            var candidate = plan()
            let message = candidate.refresh(quote: incoming, now: now)
            XCTAssertEqual(candidate.state, .invalidated, label)
            XCTAssertNotNil(message, label)
            XCTAssertNil(candidate.triggeredAt, label)
        }

        var valid = plan()
        let triggered = valid.refresh(quote: quote(price: Decimal(string: "1.451")!), now: now)
        XCTAssertEqual(valid.state, .triggered)
        XCTAssertNotNil(triggered)
    }
    func testExpiredCandidateStillRecordsBrokerConfirmedPartialFills() throws {
        var plan = NextCandidatePlan(kind: .reverseT, code: "159941", name: "纳指ETF",
            limitPrice: Decimal(string: "1.450")!, units: 500,
            createdAt: now, expiresAt: now.addingTimeInterval(3600),
            triggerNote: "券商手工挂单", cancelNote: "行情失效",
            quoteSource: "test", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 200,
            confidenceLevel: "high", rationale: "真实成交回填测试", expectedNetGain: nil,
            expectedCostReduction: nil, riskNote: "行情风险", marketState: "震荡",
            cancelAbove: nil, cancelBelow: nil)
        _ = plan.invalidate(reason: "重大新闻使原计划失效", at: now.addingTimeInterval(10))
        XCTAssertEqual(plan.state, .invalidated)
        XCTAssertTrue(plan.canConfirmRealFill)

        try plan.confirmRealFill(price: Decimal(string: "1.450")!, units: 300,
                                 fee: Decimal(string: "0.10")!, at: now.addingTimeInterval(20),
                                 now: now.addingTimeInterval(30))
        XCTAssertEqual(plan.confirmedUnits, 300)
        XCTAssertEqual(plan.state, .invalidated, "部分真实成交不能把已失效的计划重新标成有效")
        XCTAssertTrue(plan.canConfirmRealFill, "剩余真实成交仍应可补录")

        try plan.confirmRealFill(price: Decimal(string: "1.451")!, units: 200,
                                 fee: Decimal(string: "0.10")!, at: now.addingTimeInterval(3700),
                                 now: now.addingTimeInterval(3800))
        XCTAssertEqual(plan.confirmedUnits, 500)
        XCTAssertEqual(plan.state, .confirmed)
        XCTAssertFalse(plan.canConfirmRealFill)
    }
    // IOPV 图层是可选的：关掉时纵轴只按成交价，不被 IOPV 撑开；
    // 打开时才把 IOPV 纳入同一根价格轴（UnifiedChartView 也按 visibleLayers 处理）。
    func testChartPriceDomainFollowsIOPVLayerVisibility() throws {
        let first = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: 4, volume: 100)
        let later = NextChartSample(timestamp: now.addingTimeInterval(3600), open: 1.1, high: 1.2, low: 1.0, close: 1.15, iopv: 4.1, volume: 200)
        let chart = NextChartDataset(code: "159941", interval: .intraday, samples: [later, first], costPerUnit: 1.02, costObservedAt: now, priceSource: "feed", iopvSource: "feed", observedAt: now)
        try chart.validate()
        XCTAssertEqual(chart.orderedSamples.map(\.timestamp), [now, now.addingTimeInterval(3600)])
        // 关闭 IOPV 图层：价格轴只由成交价决定，上界不越过 2
        XCTAssertLessThan(chart.priceDomain(includingIOPV: false)!.upperBound, 2)
        // 打开 IOPV 图层：价格轴必须覆盖 IOPV
        XCTAssertGreaterThanOrEqual(chart.priceDomain(includingIOPV: true)!.upperBound, Decimal(string: "4.1")!)
        // 属性入口保持默认（含 IOPV），与既有调用兼容
        XCTAssertEqual(chart.priceDomain, chart.priceDomain(includingIOPV: true))
        XCTAssertNotNil(chart.iopvPremiumDomain)
        XCTAssertEqual(chart.timeDomain!.upperBound, now.addingTimeInterval(3600))
    }
    func testUnknownInstrumentRulesCannotClaimT0() throws {
        let rules = NextInstrumentRules(code: "159941", market: "SZ", assetClass: .unknown, settlement: .unknown, lotSize: nil, feePerTrade: nil, source: "未接入", verifiedAt: nil)
        try rules.validate()
        XCTAssertFalse(rules.isVerified)
        let confirmed = NextInstrumentRules(code: "159941", market: "SZ", assetClass: .etf, settlement: .t0, lotSize: 100, feePerTrade: Decimal(string: "0.10"), source: "official", verifiedAt: now)
        XCTAssertTrue(confirmed.isVerified)
    }
    func testOfficialETFRuleKeepsSettlementUnknownAndFixedFee() {
        let sz = NextInstrumentRules.verifiedETFMarketRule(code: "159941", market: "SZSE", at: now)
        let sh = NextInstrumentRules.verifiedETFMarketRule(code: "563020", market: "SSE", at: now)
        XCTAssertEqual(sz?.lotSize, 100)
        XCTAssertEqual(sh?.lotSize, 100)
        XCTAssertEqual(sz?.feePerTrade, NextTradeFees.etfPerTrade)
        XCTAssertFalse(sz?.isVerified ?? true)
        XCTAssertEqual(sz?.settlement, .unknown)
        XCTAssertNil(NextInstrumentRules.verifiedETFMarketRule(code: "123456", market: "SZSE", at: now))
    }
    func testForegroundMarketClockUsesChinaSessionsAndWeekdays() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        XCTAssertTrue(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 10:00")!))
        XCTAssertTrue(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 14:00")!))
        XCTAssertFalse(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 12:00")!))
        XCTAssertFalse(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-18 10:00")!))
        XCTAssertFalse(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-05 10:00")!), "国庆休市不能被当作普通周一")
        XCTAssertTrue(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-08 10:00")!), "官方安排的节后开市日应允许正常交易时段")
        let unsupportedYear = formatter.date(from: "2027-01-04 10:00")!
        XCTAssertFalse(NextMarketClock.canGenerateActionablePlan(unsupportedYear), "缺少新年度官方日历时应禁止具体挂单价")
        XCTAssertTrue(NextMarketClock.sessionDescription(unsupportedYear).contains("未同步"))
    }
    func testBackupChecksumAndSchemaMustValidateBeforeRestore() throws {
        var archive = NextAppArchive(); archive.book.cash = 250; archive.audits = []
        let envelope = try NextArchiveEnvelope(archive: archive)
        XCTAssertEqual(try envelope.archive().book.cash, 250)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        raw["payload"] = (envelope.payload + Data([0])).base64EncodedString()
        let corrupt = try JSONDecoder().decode(NextArchiveEnvelope.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try corrupt.archive())
        archive.book.positions = [NextPosition(code: "bad", name: "invalid", units: 1, bookCost: 1)]
        XCTAssertThrowsError(try NextArchiveEnvelope(archive: archive))
    }
    func testDecisionHistoryIsIncludedAndLegacyArchiveDefaultsIt() throws {
        var archive = NextAppArchive()
        let decision = try NextResearch.prepare(book: NextBook(), goal: NextGoal(), quotes: [:], now: now)
        archive.decisionHistory = [decision]
        let envelope = try NextArchiveEnvelope(archive: archive)
        XCTAssertEqual(try envelope.archive().decisionHistory, [decision])
        let legacy = try JSONDecoder().decode(NextAppArchive.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.decisionHistory.isEmpty)
    }
    func testGoalTargetWeightsAreValidatedAndOlderSettingsStillDecode() throws {
        let legacy = try JSONDecoder().decode(NextGoal.self, from: Data("{\"years\":10,\"monthlyBudget\":1000,\"concentrationLimit\":40}".utf8))
        XCTAssertTrue(legacy.targetWeights.isEmpty)
        var goal = NextGoal(targetWeights: ["159941": 60, "563020": 40])
        XCTAssertNoThrow(try goal.validate())
        goal.targetWeights["563020"] = 30
        XCTAssertNoThrow(try goal.validate(), "目标ETF未分配的比例应成为现金储备")
        XCTAssertEqual(goal.targetCashPercent, 10)
        goal.targetWeights["563020"] = 50
        XCTAssertThrowsError(try goal.validate(), "ETF目标合计超过100%时必须拒绝")
    }
    func testAccountAdvisorFlagsCashBelowConfiguredReserve() {
        let book = NextBook(cash: 100, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 100, bookCost: 800)
        ])
        let currentQuote = NextQuote(code: "159941", name: "纳指ETF", price: 9, previousClose: 9,
                                     time: now, source: "test")
        let review = NextAccountAdvisor.review(book: book, quotes: ["159941": currentQuote],
            concentrationLimitPercent: 100, targetWeights: ["159941": 80], now: now)
        XCTAssertTrue(review?.findings.contains(where: {
            $0.title == "现金低于长期储备目标" && $0.detail.contains("20.0%")
        }) == true)
    }
    func testDailyChartCacheKeySurvivesBackupValidation() throws {
        let sample = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: nil, volume: 100)
        let daily = NextChartDataset(code: "159941", interval: .day, samples: [sample], costPerUnit: nil, costObservedAt: nil, priceSource: "NAS", iopvSource: nil, observedAt: now)
        var archive = NextAppArchive(); archive.chartData["159941:day"] = daily
        XCTAssertEqual(try NextArchiveEnvelope(archive: archive).archive().chartData["159941:day"], daily)
        archive.chartData = ["bad:day": daily]
        XCTAssertThrowsError(try NextArchiveEnvelope(archive: archive))
    }
    func testTencentQuoteParserChecksSymbolFieldsAndSourceTime() {
        XCTAssertEqual(NextTencentQuoteParser.symbol(for: "159941"), "sz159941")
        XCTAssertEqual(NextTencentQuoteParser.symbol(for: "510300"), "sh510300")
        XCTAssertNil(NextTencentQuoteParser.symbol(for: "12345"))
        var fields = Array(repeating: "", count: 90)
        fields[1] = "纳指ETF"; fields[3] = "1.234"; fields[4] = "1.200"
        fields[30] = "20261019143000"
        fields[61] = "ETF"
        fields[78] = "1.230"
        let payload = "v_sz159941=\"\(fields.joined(separator: "~"))\";"
        let received = ISO8601DateFormatter().date(from: "2026-10-19T06:30:30Z")!
        let combined = "v_sh510300=\"\(fields.joined(separator: "~"))\";" + payload
        let quote = NextTencentQuoteParser.parse(Data(combined.utf8), code: "159941", receivedAt: received)
        XCTAssertEqual(quote?.name, "纳指ETF")
        XCTAssertEqual(quote?.price, Decimal(string: "1.234"))
        XCTAssertEqual(quote?.previousClose, Decimal(string: "1.200"))
        XCTAssertEqual(quote?.iopv, Decimal(string: "1.230"))
        XCTAssertEqual(quote?.providerInstrumentType, "ETF")
        XCTAssertNotNil(NextTencentQuoteParser.parse(Data(combined.utf8), code: "510300", receivedAt: received))
        XCTAssertNil(NextTencentQuoteParser.parse(Data(payload.utf8), code: "510300", receivedAt: received))
        fields[61] = "Stock"
        let nonETF = "v_sz159941=\"\(fields.joined(separator: "~"))\";"
        XCTAssertNil(NextTencentQuoteParser.parse(Data(nonETF.utf8), code: "159941", receivedAt: received)?.iopv)
        XCTAssertNil(NextTencentQuoteParser.parse(Data("v_sz159941=\"bad\"".utf8), code: "159941", receivedAt: received))
    }
    func testTencentMinuteParserKeepsActualTimePriceVolumeAndNoInventedIOPV() throws {
        let json: [String: Any] = ["data": ["sz159941": ["data": ["date": "20261019", "data": ["1430 1.234 1000", "1431 1.240 1200"]]]]]
        let body = "min_data_sz159941=\(try JSONSerialization.data(withJSONObject: json).utf8String);"
        let received = ISO8601DateFormatter().date(from: "2026-10-19T06:31:30Z")!
        let dataset = try XCTUnwrap(NextTencentMinuteParser.parse(Data(body.utf8), code: "159941", receivedAt: received))
        XCTAssertEqual(dataset.samples.count, 2)
        XCTAssertEqual(dataset.samples[0].close, Decimal(string: "1.234"))
        XCTAssertEqual(dataset.samples[1].volume, 200)
        XCTAssertNil(dataset.samples[0].iopv)
        XCTAssertNil(dataset.iopvSource)
        try dataset.validate()
    }
    func testIntradayFreshnessUsesSampleTimeNotResponseReceiptTime() throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = try XCTUnwrap(formatter.date(from: "2026-10-20 10:05:00"))
        func dataset(_ stamp: String) throws -> NextChartDataset {
            let sampleTime = try XCTUnwrap(formatter.date(from: stamp))
            return NextChartDataset(code: "159941", interval: .intraday,
                                    samples: [NextChartSample(timestamp: sampleTime, open: nil, high: nil, low: nil,
                                                              close: Decimal(string: "1.2")!, iopv: nil, volume: 100)],
                                    costPerUnit: nil, costObservedAt: nil, priceSource: "fixture", iopvSource: nil,
                                    observedAt: now)
        }
        XCTAssertTrue(NextIntradayDatasetGuard.isCurrentSessionData(try dataset("2026-10-20 10:04:00"), now: now, marketOpen: true))
        XCTAssertFalse(NextIntradayDatasetGuard.isCurrentSessionData(try dataset("2026-10-19 15:00:00"), now: now, marketOpen: false),
                       "A response received now must not make yesterday's minute bars look current")
        XCTAssertFalse(NextIntradayDatasetGuard.isCurrentSessionData(try dataset("2026-10-20 09:59:00"), now: now, marketOpen: true),
                       "During the session, minute samples older than five minutes are rejected")
        XCTAssertFalse(NextIntradayDatasetGuard.isCurrentSessionData(try dataset("2026-10-20 10:06:30"), now: now, marketOpen: true),
                       "Future sample timestamps are rejected")
    }
    func testIntradayRefreshCannotReplaceCacheWithOlderSamples() throws {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        func dataset(_ offset: TimeInterval) -> NextChartDataset {
            NextChartDataset(code: "159941", interval: .intraday,
                            samples: [NextChartSample(timestamp: first.addingTimeInterval(offset), open: nil, high: nil, low: nil,
                                                      close: Decimal(string: "1.2")!, iopv: nil, volume: 100)],
                            costPerUnit: nil, costObservedAt: nil, priceSource: "fixture", iopvSource: nil,
                            observedAt: first.addingTimeInterval(10_000))
        }
        XCTAssertFalse(NextIntradayDatasetGuard.shouldReplace(dataset(120), with: dataset(60)))
        XCTAssertTrue(NextIntradayDatasetGuard.shouldReplace(dataset(60), with: dataset(120)))
        XCTAssertTrue(NextIntradayDatasetGuard.shouldReplace(dataset(120), with: dataset(120)),
                      "Equal-minute samples may refresh a forming candle")
    }
    func testCrossMarketResearchDecodesStatusFreshnessAndOlderServerPayloads() throws {
        let current = Data(#"{"factors":null,"ai":null,"providerConfigured":false,"crossMarket":{"state":"no_stable_relationship","reason":"没有稳定领先关系","source":"Eastmoney trends","asOf":"2026-10-23T09:30:00+09:00","sampleCount":120,"bestLagMinutes":null,"conditionalWinRate":null,"bestMarket":"KR_KOSPI","currentMarketStatus":"closed","ageSeconds":7200,"liveDivergences":[{"market":"JP_N225","state":"observed_divergence","reason":null,"windowMinutes":15,"leaderReturnPercent":-0.6,"assetReturnPercent":0.4,"leaderAgeSeconds":0,"assetAgeSeconds":0,"eligibleForTradingSignal":false,"expiresAt":"2026-10-23T10:00:00+09:00"}],"overnightAbsorption":[{"market":"US_NDX","state":"descriptive_only","sampleCount":42,"minimumSessions":30,"leaderOpenGapCorrelation":0.25,"meanLeaderReturnPercent":0.7,"meanOpeningGapPercent":0.4,"meanFirstThirtyMinuteReturnPercent":-0.1,"meanGapAbsorptionFraction":0.25,"absorptionSampleCount":36,"eligibleForTradingSignal":false,"note":"仅描述历史关系"}],"tailToNextDay":{"state":"descriptive_only","sampleCount":40,"minimumSessions":30,"tailToOpenGapCorrelation":0.1,"tailToFirstThirtyMinuteCorrelation":-0.2,"meanTailReturnPercent":0.15,"meanNextOpeningGapPercent":0.05,"meanFirstThirtyMinuteReturnPercent":-0.03,"eligibleForTradingSignal":false,"note":"仅描述历史路径"},"rollingValidity":[{"market":"KR_KOSPI","lagMinutes":0,"horizonMinutes":15,"windows":[{"windowSessions":20,"sampleCount":20,"state":"descriptive_only","correlation":0.2,"conditionalDirectionRate":0.55,"eligibleForTradingSignal":false}],"eligibleForTradingSignal":false,"note":"研究用途"}],"timeProfiles":[{"market":"KR_KOSPI","lagMinutes":0,"horizonMinutes":15,"bucketMinutes":30,"minimumSessions":20,"profiles":[{"startMinute":570,"endMinute":600,"sampleCount":20,"state":"descriptive_only","correlation":0.1,"conditionalDirectionRate":0.5,"eligibleForTradingSignal":false}],"eligibleForTradingSignal":false,"note":"研究用途"}],"currencyContext":{"pair":"USD/CNY","source":"Sina FX fixture","state":"observed_context","reason":null,"asOf":"2026-10-23T09:30:00+08:00","ageSeconds":0,"windowMinutes":60,"fxReturnPercent":0.12,"assetReturnPercent":0.2,"assetLatestAt":"2026-10-23T09:30:00+08:00","eligibleForTradingSignal":false,"note":"上下文"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(NextNASResearch.self, from: current)
        XCTAssertEqual(decoded.crossMarket?.state, "no_stable_relationship")
        XCTAssertEqual(decoded.crossMarket?.bestMarket, "KR_KOSPI")
        XCTAssertEqual(decoded.crossMarket?.currentMarketStatus, "closed")
        XCTAssertEqual(decoded.crossMarket?.ageSeconds, 7200)
        XCTAssertEqual(decoded.crossMarket?.liveDivergences?.first?.state, "observed_divergence")
        XCTAssertEqual(decoded.crossMarket?.liveDivergences?.first?.eligibleForTradingSignal, false)
        XCTAssertEqual(decoded.crossMarket?.overnightAbsorption?.first?.market, "US_NDX")
        XCTAssertEqual(decoded.crossMarket?.overnightAbsorption?.first?.sampleCount, 42)
        XCTAssertEqual(decoded.crossMarket?.overnightAbsorption?.first?.eligibleForTradingSignal, false)
        XCTAssertEqual(decoded.crossMarket?.tailToNextDay?.state, "descriptive_only")
        XCTAssertEqual(decoded.crossMarket?.tailToNextDay?.sampleCount, 40)
        XCTAssertEqual(decoded.crossMarket?.tailToNextDay?.eligibleForTradingSignal, false)
        XCTAssertEqual(decoded.crossMarket?.rollingValidity?.first?.windows.first?.windowSessions, 20)
        XCTAssertEqual(decoded.crossMarket?.rollingValidity?.first?.eligibleForTradingSignal, false)
        XCTAssertEqual(decoded.crossMarket?.timeProfiles?.first?.profiles.first?.startMinute, 570)
        XCTAssertEqual(decoded.crossMarket?.timeProfiles?.first?.eligibleForTradingSignal, false)
        XCTAssertEqual(decoded.crossMarket?.currencyContext?.pair, "USD/CNY")
        XCTAssertEqual(decoded.crossMarket?.currencyContext?.state, "observed_context")
        XCTAssertEqual(decoded.crossMarket?.currencyContext?.eligibleForTradingSignal, false)
        let expiry = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T10:00:00+09:00"))
        let divergence = try XCTUnwrap(decoded.crossMarket?.liveDivergences?.first)
        XCTAssertFalse(divergence.isFresh(at: expiry))
        XCTAssertTrue(divergence.isFresh(at: expiry.addingTimeInterval(-120)))

        let older = Data(#"{"factors":null,"ai":null,"providerConfigured":false,"crossMarket":{"state":"insufficient_real_archive","reason":null,"source":null,"asOf":null,"sampleCount":0,"bestLagMinutes":null,"conditionalWinRate":null}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(NextNASResearch.self, from: older).crossMarket?.currentMarketStatus)
    }
    func testCrossMarketRiskGuardOnlyBlocksFreshProspectivelyReplicatedEvidence() throws {
        let payload = Data(#"{"factors":null,"ai":null,"providerConfigured":false,"crossMarket":{"state":"validated","currentMarketStatus":"open","eligibleForTradingSignal":true,"validationState":"prospectively_replicated","liveDivergences":[{"market":"KR_KOSPI","state":"observed_divergence","eligibleForTradingSignal":true,"expiresAt":"2026-10-23T10:00:00Z"}]}}"#.utf8)
        let evidence = try XCTUnwrap(JSONDecoder().decode(NextNASResearch.self, from: payload).crossMarket)
        let formatter = ISO8601DateFormatter()
        let freshAt = try XCTUnwrap(formatter.date(from: "2026-10-23T09:59:00Z"))
        let riskReason = NextCrossMarketRiskGuard.blockingReason(evidence: evidence, now: freshAt)
        XCTAssertNotNil(riskReason)
        XCTAssertTrue(riskReason?.contains("KR_KOSPI") == true)
        XCTAssertNil(NextCrossMarketRiskGuard.blockingReason(evidence: evidence, now: freshAt.addingTimeInterval(120)),
                     "过期的跨市场观察不得继续拦截或制造当天判断")
        let historicalOnly = try XCTUnwrap(JSONDecoder().decode(NextNASResearch.self,
            from: Data(#"{"factors":null,"ai":null,"providerConfigured":false,"crossMarket":{"state":"validated","currentMarketStatus":"open","eligibleForTradingSignal":false,"validationState":"historical_candidate","liveDivergences":[{"market":"KR_KOSPI","state":"observed_divergence","eligibleForTradingSignal":true,"expiresAt":"2026-10-23T10:00:00Z"}]}}"#.utf8)).crossMarket)
        XCTAssertNil(NextCrossMarketRiskGuard.blockingReason(evidence: historicalOnly, now: freshAt),
                     "仅历史候选绝不能改变做T或网格计划")
    }
    func testFixedIntradayAxisCoversFullSessionAndCompressesLunch() throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let open = try XCTUnwrap(formatter.date(from: "2026-10-20 09:30"))
        let morningEnd = try XCTUnwrap(formatter.date(from: "2026-10-20 11:30"))
        let lunch = try XCTUnwrap(formatter.date(from: "2026-10-20 12:15"))
        let afternoon = try XCTUnwrap(formatter.date(from: "2026-10-20 13:00"))
        let close = try XCTUnwrap(formatter.date(from: "2026-10-20 15:00"))
        XCTAssertEqual(NextIntradayAxis.minute(open), 0)
        XCTAssertEqual(NextIntradayAxis.minute(morningEnd), 120)
        XCTAssertEqual(NextIntradayAxis.minute(lunch), 126, accuracy: 0.001)
        XCTAssertEqual(NextIntradayAxis.minute(afternoon), 132)
        XCTAssertEqual(NextIntradayAxis.minute(close), NextIntradayAxis.length)
        XCTAssertEqual(NextIntradayAxis.length, 252)
        XCTAssertEqual(NextIntradayAxis.ticks.first?.1, "09:30")
        XCTAssertEqual(NextIntradayAxis.ticks.last?.1, "15:00")
        XCTAssertTrue(NextIntradayAxis.sameTradingDay(open, close))
        XCTAssertFalse(NextIntradayAxis.sameTradingDay(open, close.addingTimeInterval(86_400)))
    }
    func testIntradayArchiveSelectsOneTradingDayAndDefaultsToNewest() throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let first = try XCTUnwrap(formatter.date(from: "2026-10-19 09:30"))
        let second = try XCTUnwrap(formatter.date(from: "2026-10-20 09:30"))
        let samples = [
            NextChartSample(timestamp: first, open: nil, high: nil, low: nil, close: 1, iopv: nil, volume: nil),
            NextChartSample(timestamp: second, open: nil, high: nil, low: nil, close: 2, iopv: nil, volume: nil)
        ]
        XCTAssertEqual(NextIntradayAxis.sessionSamples(from: samples, selectedDate: first).map(\.close), [1])
        XCTAssertEqual(NextIntradayAxis.sessionSamples(from: samples, selectedDate: nil).map(\.close), [2])
    }
    func testSimpleMovingAveragesUseDailyCloseAndStayUnavailableUntilFullWindow() throws {
        let bars = (1...5).map { value in
            NextChartSample(timestamp: now.addingTimeInterval(Double(value) * 86_400), open: nil, high: nil, low: nil,
                            close: Decimal(value), iopv: nil, volume: nil)
        }
        XCTAssertEqual(NextMovingAverage.series(bars, period: 3), [nil, nil, 2, 3, 4])
        XCTAssertTrue(NextMovingAverage.series(bars, period: 250).allSatisfy { $0 == nil })
        let fullHistory = (1...250).map { value in
            NextChartSample(timestamp: now.addingTimeInterval(Double(value) * 86_400), open: nil, high: nil, low: nil,
                            close: Decimal(value), iopv: nil, volume: nil)
        }
        XCTAssertEqual(NextMovingAverage.series(fullHistory, period: 250)[249], Decimal(string: "125.5"))
    }
    func testChartStateDecodesBeforeMovingAverageDefaultsWereAdded() throws {
        let oldState = #"{"interval":"day","visibleLayers":["price","cost"],"lowerBound":null,"upperBound":null,"crosshairTime":null,"scale":1}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(NextChartState.self, from: oldState)
        XCTAssertEqual(state.interval, "day")
        XCTAssertNil(state.movingAverageDefaultsApplied)
        XCTAssertNil(state.latestIntradaySessionDate)
    }
    func testChartPriceDomainIncludesIOPVWhenItExtendsBeyondPriceBars() throws {
        let sample = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: 1.4, volume: 100)
        let chart = NextChartDataset(code: "159941", interval: .intraday, samples: [sample], costPerUnit: nil, costObservedAt: nil, priceSource: "feed", iopvSource: "verified ETF quote", observedAt: now)
        let domain = try XCTUnwrap(chart.priceDomain)
        XCTAssertLessThan(domain.lowerBound, 0.9)
        XCTAssertGreaterThan(domain.upperBound, 1.4)
    }
    func testLiveETFIOPVOnlyEnrichesNearestCurrentMinutePoint() throws {
        let first = NextChartSample(timestamp: now, open: nil, high: nil, low: nil, close: 1.2, iopv: nil, volume: 100)
        let last = NextChartSample(timestamp: now.addingTimeInterval(60), open: nil, high: nil, low: nil, close: 1.21, iopv: nil, volume: 100)
        let raw = NextChartDataset(code: "159941", interval: .intraday, samples: [first, last], costPerUnit: nil, costObservedAt: nil, priceSource: "minute", iopvSource: nil, observedAt: now)
        let etf = NextQuote(code: "159941", name: "纳指ETF", price: 1.21, previousClose: 1.2, time: now.addingTimeInterval(90), source: "quote", iopv: 1.205, providerInstrumentType: "ETF")
        let enriched = raw.attachingVerifiedIOPV(etf)
        XCTAssertNil(enriched.samples[0].iopv)
        XCTAssertEqual(enriched.samples[1].iopv, 1.205)
        XCTAssertNotNil(enriched.iopvSource)
        let far = NextQuote(code: "159941", name: "纳指ETF", price: 1.21, previousClose: 1.2, time: now.addingTimeInterval(500), source: "quote", iopv: 1.205, providerInstrumentType: "ETF")
        XCTAssertEqual(raw.attachingVerifiedIOPV(far), raw)
    }
    // MARK: - 本机规则引擎

    private func dailyBars(_ closes: [Double], start: Date? = nil) -> [NextChartSample] {
        let base = start ?? Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { index, value in
            let price = Decimal(string: String(format: "%.4f", value))!
            return NextChartSample(timestamp: base.addingTimeInterval(Double(index) * 86_400),
                                   open: price, high: price, low: price, close: price,
                                   iopv: nil, volume: 1_000_000)
        }
    }

    func testDividendPointsAreMonotonicAndNeverNegative() {
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: nil), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 0), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 1.9), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 2.5), 2)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 3.5), 5)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 4.5), 8)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 5.5), 11)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 9), 14)
    }

    func testDividendYieldPrefersIOPVForOnExchangeETFOnly() {
        // ETF：分母用净值。场内溢价 25% 时，若用场内价会低估股息率。
        let etf = NextDividendRules.yieldPercent(code: "515180", perShare: Decimal(string: "0.06")!, price: 1.25, iopv: 1.0)
        XCTAssertEqual(etf ?? 0, 6, accuracy: 0.0001)
        // 个股：没有 IOPV 概念，分母用现价。
        let stock = NextDividendRules.yieldPercent(code: "600519", perShare: Decimal(string: "0.06")!, price: 1.25, iopv: 1.0)
        XCTAssertEqual(stock ?? 0, 4.8, accuracy: 0.0001)
        // REITs（508/180）不在 ETF 白名单，不能被当作 ETF 套 IOPV。
        XCTAssertFalse(NextDividendRules.isOnExchangeETF("508000"))
        XCTAssertFalse(NextDividendRules.isOnExchangeETF("180101"))
        XCTAssertTrue(NextDividendRules.isOnExchangeETF("159941"))
        XCTAssertTrue(NextDividendRules.isOnExchangeETF("515180"))
    }

    func testWorthBuyNeedsEnoughDailyBars() {
        let quotePrice = Decimal(string: "1.20")!
        let short = dailyBars(Array(repeating: 1.2, count: 12))
        XCTAssertNil(NextWorthBuyEngine.evaluate(code: "159941", price: quotePrice, previousClose: quotePrice,
                                                 samples: short, dividendPerShare: 0, iopv: nil,
                                                 costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil))
        let enough = dailyBars(Array(repeating: 1.2, count: 40))
        XCTAssertNotNil(NextWorthBuyEngine.evaluate(code: "159941", price: quotePrice, previousClose: quotePrice,
                                                    samples: enough, dividendPerShare: 0, iopv: nil,
                                                    costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil))
        // 40 根平盘样本：均线全部交织、无动量，分数必须落在合法区间且不被抬高。
        let signal = NextSignalEngine.evaluate(enough)
        XCTAssertNotNil(signal)
        XCTAssertTrue((signal?.score ?? -1) >= 0 && (signal?.score ?? 101) <= 100)
        XCTAssertEqual(signal?.trend, "均线交织 · 震荡")
    }

    func testIncomePlayDampensSameDayChangePenalty() {
        let bars = dailyBars(Array(repeating: 1.0, count: 40))
        let price = Decimal(string: "0.97")!
        let previous = Decimal(string: "1.0")!
        let plain = NextWorthBuyEngine.evaluate(code: "159941", price: price, previousClose: previous,
                                                samples: bars, dividendPerShare: 0, iopv: nil,
                                                costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil)
        let income = NextWorthBuyEngine.evaluate(code: "515180", price: price, previousClose: previous,
                                                 samples: bars, dividendPerShare: Decimal(string: "0.04")!,
                                                 iopv: nil, costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(income)
        XCTAssertTrue(income?.isIncomePlay == true)
        // 当天跌 3%：普通标的按 -8 计，红利标的只按 -2.67 计。
        let plainChange = plain?.lines.first(where: { $0.title == "当日涨跌" })?.points ?? 0
        let incomeChange = income?.lines.first(where: { $0.title == "当日涨跌" })?.points ?? 0
        XCTAssertEqual(plainChange, -8)
        XCTAssertTrue(incomeChange > plainChange)
    }

    func testGridCheckRefusesToGradeWithTooFewBars() {
        let bars = dailyBars(Array(repeating: 1.0, count: 30))
        let check = NextGridCheckEngine.evaluate(code: "159941", name: "纳指ETF", samples: bars, isOnExchange: true)
        XCTAssertEqual(check.grade, .avoid)
        XCTAssertEqual(check.barCount, 30)
        XCTAssertTrue(check.warnings.contains { $0.contains("60") })
    }

    func testAccountAdvisorFlagsConcentrationAndMissingQuote() {
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "12000")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.2")!, previousClose: Decimal(string: "1.2")!, time: now, source: "test")
        let review = NextAccountAdvisor.review(book: book, quotes: ["159941": quote], concentrationLimitPercent: 40, now: now)
        XCTAssertNotNil(review)
        XCTAssertTrue(review?.findings.contains { $0.title.contains("超过单仓上限") } == true)
        // 缺报价的持仓要单独提示，不能静默算进比例。
        let missing = NextBook(cash: 1000, positions: [
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 100)
        ])
        let missingReview = NextAccountAdvisor.review(book: missing, quotes: [:], concentrationLimitPercent: 40)
        XCTAssertTrue(missingReview?.findings.contains { $0.title.contains("缺少有效报价") } == true)
        XCTAssertTrue(missingReview?.headline.contains("组合估值不完整") == true)
        XCTAssertFalse(missingReview?.findings.contains { $0.title.contains("现金占比") } == true,
                       "报价不全时不应基于不完整分母给出现金比例")
        let staleQuote = NextQuote(code: "515180", name: "红利ETF", price: 1.0, previousClose: 1.0,
                                   time: now.addingTimeInterval(-121), source: "test")
        let staleReview = NextAccountAdvisor.review(book: missing, quotes: ["515180": staleQuote],
                                                    concentrationLimitPercent: 40, now: now)
        XCTAssertTrue(staleReview?.headline.contains("组合估值不完整") == true,
                      "过期报价不能被当作当前组合权重事实")
    }

    func testReceiptTimestampFallbackCannotSupportPrecisePlan() {
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: 1.2, previousClose: 1.2,
                              time: now, source: "EastMoney push2", timeQuality: "receipt_only")
        XCTAssertTrue(quote.isFresh(at: now), "接收时间可用于展示新鲜度，但不能冒充行情源时间")
        XCTAssertFalse(quote.isFreshForPricePlan(at: now))
        let confidence = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                                   minuteSampleCount: 240)
        XCTAssertEqual(confidence.level, .blocked)
        XCTAssertTrue(confidence.missing.contains { $0.contains("供应商时间戳") })
    }

    func testTConfidenceRejectsPriorDayOrStaleIntradaySamples() {
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: 1.2, previousClose: 1.2,
                              time: now, source: "test")
        let prior = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                              minuteSampleCount: 240, intradayLatestAt: now.addingTimeInterval(-86_400),
                                              dailyLatestAt: now)
        XCTAssertEqual(prior.level, .blocked)
        XCTAssertTrue(prior.missing.contains { $0.contains("上个交易日缓存") })

        let stale = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                              minuteSampleCount: 240, intradayLatestAt: now.addingTimeInterval(-301),
                                              dailyLatestAt: now)
        XCTAssertEqual(stale.level, .blocked)
        XCTAssertTrue(stale.missing.contains { $0.contains("超过5分钟") })

        let current = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                                minuteSampleCount: 240, intradayLatestAt: now.addingTimeInterval(-60),
                                                dailyLatestAt: now)
        XCTAssertFalse(current.missing.contains { $0.contains("分时样本") })

        let staleDaily = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                                  minuteSampleCount: 0, intradayRequired: false,
                                                  dailyLatestAt: now.addingTimeInterval(-16 * 86_400))
        XCTAssertEqual(staleDaily.level, .blocked)
        XCTAssertTrue(staleDaily.missing.contains { $0.contains("日K最新记录超过15天") })
        let longHoliday = NextDataConfidence.assess(quote: quote, now: now, dailyBarCount: 120,
                                                   minuteSampleCount: 0, intradayRequired: false,
                                                   dailyLatestAt: now.addingTimeInterval(-10 * 86_400))
        XCTAssertFalse(longHoliday.missing.contains { $0.contains("日K最新记录超过15天") })
    }

    func testMACDSeriesWarmsUpBeforeReturningValues() {
        let flat = Array(repeating: 1.0, count: 60)
        let series = NextMACD.series(flat)
        XCTAssertEqual(series.count, 60)
        XCTAssertTrue(series.prefix(33).allSatisfy { $0 == nil })
        XCTAssertNotNil(series[33])
        XCTAssertEqual(series[59]?.histogram ?? 1, 0, accuracy: 0.000001)
    }

    func testGlobalIndexParserReadsFiveUserSelectedIndices() {
        // 这一段是 2026-10-20 12:59 从新浪实际抓到的响应（原样）。
        let body = """
        var hq_str_s_sh000001="上证指数,3727.7542,-3.1658,-0.08,2485176,44185013";
        var hq_str_gb_$ndx="纳斯达克100,29529.3445,1.17,2026-10-20 05:30:00,341.7958,29539.3116,29788.7588,29461.3209";
        var hq_str_b_NKY="日经225指数,64056.2800,-860.42,-1.33,2:12 AM,14:12:00,2026-10-20,12:59:20,64755.4900";
        var hq_str_b_KOSPI="韩国KOSPI指数,5522.8000,-245.21,-4.25,2:27 AM,14:27:00,2026-10-20,12:59:20,5733.5700";
        var hq_str_rt_hkHSTECH="HSTECH,恒生科技指数,4055.520,4108.240,4083.660,4033.240,4058.390,-49.850,-1.210,0.000,0.000,22406330,546961768,0.000,0.000,6198.680,4042.050,2026/10/20,12:59:56";
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = formatter.date(from: "2026-10-20 13:00:00")!
        let quotes = GlobalIndexFeed.parse(body, now: now)
        // 顺序与本地目录一致：上证、纳指100、日经、韩国、恒生科技。
        XCTAssertEqual(quotes.map(\.symbol), GlobalIndexFeed.catalog.map { $0.symbol })
        XCTAssertEqual(quotes.count, 5)
        XCTAssertEqual(quotes[0].price, 3727.7542, accuracy: 0.0001)
        XCTAssertEqual(quotes[0].changePercent, -0.08, accuracy: 0.0001)
        XCTAssertEqual(quotes[1].price, 29529.3445, accuracy: 0.0001)
        XCTAssertEqual(quotes[1].changePercent, 1.17, accuracy: 0.0001)
        XCTAssertEqual(quotes[2].price, 64056.28, accuracy: 0.0001)
        XCTAssertEqual(quotes[3].price, 5522.80, accuracy: 0.0001)
        // 港股用第 6 位现价、第 8 位涨跌幅，不是第 1/2 位。
        XCTAssertEqual(quotes[4].price, 4058.39, accuracy: 0.0001)
        XCTAssertEqual(quotes[4].changePercent, -1.21, accuracy: 0.0001)
        XCTAssertEqual(quotes[4].previousClose ?? 0, 4108.24, accuracy: 0.0001)
        // 最新时点与本地时间相差 1 小时以内，不能判陈旧。
        XCTAssertFalse(quotes[1].isStale)
        XCTAssertNotNil(quotes[2].observedAt)
    }

    func testCostBasisKeepsAverageCostAndComputesDilutedCost() {
        // 买 1000 份 @1.00（费 0.10），再卖 500 份 @1.20（费 0.10），剩 500 份。
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: Decimal(string: "500.05")!)
        ], fills: [
            NextFill(date: now, code: "159941", side: "buy", units: 1000, price: 1, fee: Decimal(string: "0.10")!, realized: 0),
            NextFill(date: now, code: "159941", side: "sell", units: 500, price: Decimal(string: "1.20")!, fee: Decimal(string: "0.10")!, realized: 0)
        ])
        let basis = book.costBasis(for: "159941")
        XCTAssertNotNil(basis)
        // 买入均价：只由买入决定，(1000 + 0.10) / 1000。
        XCTAssertEqual(basis?.averageCost ?? 0, Decimal(string: "1.0001")!)
        // 摊薄成本：(1000.10 − 599.90) / 500 = 0.8004，卖出盈利把成本压低。
        XCTAssertEqual(basis?.dilutedCost ?? 0, Decimal(string: "0.8004")!)
        XCTAssertTrue(basis?.hasFullHistory == true)
    }

    func testCostBasisRefusesDilutedCostWithoutBuyFills() {
        // 补录的已有持仓没有买入流水，摊薄口径不成立，不能凭空造一个成本。
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 120)
        ])
        let basis = book.costBasis(for: "515180")
        XCTAssertNotNil(basis)
        XCTAssertNil(basis?.dilutedCost)
        XCTAssertFalse(basis?.hasFullHistory == true)
        XCTAssertEqual(basis?.averageCost ?? 0, Decimal(string: "1.2")!)
    }

    func testDailyChangeUsesBuyPriceForTodaysPurchases() {
        // 昨仓 1000 份（昨收 1.00），今天再买 500 份 @1.02，现价 1.05。
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 1500, bookCost: Decimal(string: "1510.1")!)
        ], fills: [
            NextFill(date: now, code: "159941", side: "buy", units: 500, price: Decimal(string: "1.02")!, fee: Decimal(string: "0.10")!, realized: 0)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.05")!,
                              previousClose: 1, time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let valuation = book.valuation(using: ["159941": NextCachedQuote(quote: quote, stamp: stamp)], at: now)
        // 昨仓：(1.05 − 1.00) × 1000 = 50；今买：(1.05 − 1.02) × 500 − 0.10 = 14.9
        XCTAssertEqual(valuation.dailyChange, Decimal(string: "64.9")!)
    }

    func testPortfolioSummaryComparesAverageAndDilutedCost() {
        let yesterday = now.addingTimeInterval(-86_400)
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: Decimal(string: "500.05")!)
        ], fills: [
            NextFill(date: yesterday, code: "159941", side: "buy", units: 1000, price: 1,
                     fee: Decimal(string: "0.10")!, realized: 0),
            NextFill(date: yesterday, code: "159941", side: "sell", units: 500,
                     price: Decimal(string: "1.20")!, fee: Decimal(string: "0.10")!, realized: Decimal(string: "99.90")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.30")!,
                              previousClose: Decimal(string: "1.28")!, time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let quotes = ["159941": NextCachedQuote(quote: quote, stamp: stamp)]

        let average = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .average)
        let diluted = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .diluted)
        // 市值 500 × 1.30 = 650；均价成本 500.05 → 149.95；摊薄成本 400.20 → 249.80
        XCTAssertEqual(average.floatingProfit, Decimal(string: "149.95")!)
        XCTAssertEqual(diluted.floatingProfit, Decimal(string: "249.80")!)
        // 昨日成交不参与今日调整：(1.30 − 1.28) × 500 = 10
        XCTAssertEqual(average.dailyChange, Decimal(string: "10")!)
        XCTAssertEqual(average.positions.first?.weightPercent ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(average.realizedTotal, Decimal(string: "99.90")!)
    }

    func testPortfolioSummaryWithholdsDailyChangeWhenQuoteMissing() {
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: 500),
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 120)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: 1, previousClose: 1,
                              time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let summary = NextPortfolioCalculator.summary(book: book,
            quotes: ["159941": NextCachedQuote(quote: quote, stamp: stamp)], at: now, mode: .average)
        XCTAssertFalse(summary.isComplete)
        XCTAssertNil(summary.dailyChange)
        XCTAssertEqual(summary.positions.count, 1)
    }

    func testPerformanceSummaryRemovesExternalFlows() {
        let points = [
            NextAssetPoint(date: now, total: 1000, externalFlow: 0),
            NextAssetPoint(date: now.addingTimeInterval(86_400), total: 1600, externalFlow: 500),
            NextAssetPoint(date: now.addingTimeInterval(172_800), total: 1100, externalFlow: 0)
        ]
        let summary = NextPerformanceCalculator.summary(points: points)
        // 第 2 天：(1600 − 500) / 1000 − 1 = +10%；第 3 天：1100 / 1600 − 1 = −31.25%
        // 连乘 1.10 × 0.6875 = 0.75625 → −24.375%
        XCTAssertEqual(summary?.cumulativePercent ?? 0, -24.375, accuracy: 0.0001)
        XCTAssertNil(summary?.annualizedPercent)
        XCTAssertEqual(summary?.dayCount, 2)
        XCTAssertEqual(summary?.maxDrawdownPercent ?? 0, 31.25, accuracy: 0.0001)
    }

    func testCatalogSearchMatchesNameAndInitialsButNotEmptyQuery() {
        XCTAssertTrue(InstrumentCatalog.search("").isEmpty)
        XCTAssertTrue(InstrumentCatalog.search("红利").contains { $0.code == "515180" })
        XCTAssertTrue(InstrumentCatalog.search("nz").contains { $0.code == "159941" })
        XCTAssertTrue(InstrumentCatalog.search("5103").contains { $0.code == "510300" })
        XCTAssertTrue(InstrumentCatalog.search("不存在的名字").isEmpty)
    }

    func testInstrumentGroupClassifiesKnownPrefixedCodes() {
        XCTAssertEqual(NextInstrumentGroup.classify(code: "515180", name: "红利ETF"), .dividend)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "513100", name: "纳指100ETF"), .overseas)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "510300", name: "沪深300ETF"), .broad)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "511010", name: "国债ETF"), .bond)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "600519", name: "贵州茅台"), .equity)
    }

    func testForwardAdjustmentLowersHistoryAfterDividendOnly() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let before = formatter.date(from: "2026-01-05")!
        let after = formatter.date(from: "2026-03-05")!
        let samples = [
            NextChartSample(timestamp: before, open: 1.0, high: 1.1, low: 0.9, close: 1.0, iopv: nil, volume: 100),
            NextChartSample(timestamp: after, open: 1.0, high: 1.1, low: 0.9, close: 1.0, iopv: nil, volume: 100)
        ]
        let events = [NextETFDividendEvent(code: "510300", date: "2026-02-01", amountPerShare: Decimal(string: "0.05")!)]
        let adjusted = NextPriceAdjustment.forwardAdjusted(samples, events: events, code: "510300")
        // 除息日之前的那根下调 0.05，之后的保持原值。
        XCTAssertEqual(adjusted[0].close, Decimal(string: "0.95")!)
        XCTAssertEqual(adjusted[1].close, 1.0)
        // 没有派息事件时原样返回。
        XCTAssertEqual(NextPriceAdjustment.forwardAdjusted(samples, events: [], code: "510300"), samples)
    }

    func testBenchmarkReturnUsesSameWindow() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: "2026-01-01")!
        let samples = (0..<5).map { index -> NextChartSample in
            let price = Decimal(string: String(format: "%.1f", 100 + Double(index) * 10))!
            return NextChartSample(timestamp: start.addingTimeInterval(Double(index) * 86_400),
                                   open: price, high: price, low: price, close: price, iopv: nil, volume: 1)
        }
        // 从第 100 点到第 140 点：+40%
        let value = NextBenchmark.returnPercent(samples: samples, from: start, to: start.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(value ?? 0, 40, accuracy: 0.0001)
        XCTAssertNil(NextBenchmark.returnPercent(samples: [], from: start, to: start))
    }

    // MARK: - 红利买入时机打分

    private func bar(_ day: Int, low: Decimal, high: Decimal, close: Decimal) -> NextChartSample {
        let start = Date(timeIntervalSince1970: 1792375200)
        return NextChartSample(timestamp: start.addingTimeInterval(Double(day) * 86_400),
                               open: close, high: high, low: low, close: close, iopv: nil, volume: 1)
    }

    func testDividendBuyScoreNeedsVerifiedPerShareAndPrice() {
        // 没有已核实派息：不打分
        XCTAssertNil(DividendBuyScoreEngine.evaluate(code: "563020", perShare: 0, price: 1, iopv: nil,
            samples: [bar(0, low: 1, high: 1, close: 1)], dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
        // 没有行情：不打分
        XCTAssertNil(DividendBuyScoreEngine.evaluate(code: "563020", perShare: 0.05, price: nil, iopv: nil,
            samples: [bar(0, low: 1, high: 1, close: 1)], dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
    }

    func testDividendBuyScoreComponentsSumToTotalAndTierFollowsTotal() {
        // 近三个自然年都有已核实派息 → 稳定 10 分。
        let events = [
            NextETFDividendEvent(code: "563020", date: "2024-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2025-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!)
        ]
        // 窗口低 1.0 高 2.0；现价 1.0（贴区间下沿）→ 位置 35；回撤 50% → 回撤 15。
        let samples = (-179...0).map { bar($0, low: 1, high: 2, close: 1) }
        // 每份 0.05、现价 1.0 → 股息率 5%，目标 4% → 拿满 40。
        let score = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.05")!,
            price: 1, iopv: nil, samples: samples, dividendEvents: events, today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(score?.yieldPoints, 40)
        XCTAssertEqual(score?.positionPoints, 35)
        XCTAssertEqual(score?.drawdownPoints, 15)
        XCTAssertEqual(score?.stabilityPoints, 10)
        XCTAssertEqual(score?.total, 100)
        XCTAssertEqual(score?.tier, .attention)
        XCTAssertTrue(score?.missing.isEmpty ?? false)
    }

    func testDividendBuyScoreScalesYieldPositionDrawdownAndStability() {
        // 股息率只有目标的一半 → 20 分。
        let halfYield = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.02")!,
            price: 1, iopv: nil, samples: [], dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(halfYield?.yieldPoints, 20)
        // 没有日 K：位置与回撤记缺失、计 0，不拿中性分冒充。
        XCTAssertEqual(halfYield?.positionPoints, 0)
        XCTAssertEqual(halfYield?.drawdownPoints, 0)
        XCTAssertTrue(halfYield?.missing.contains("日K") ?? false)
        XCTAssertEqual(halfYield?.tier, .insufficient)
        // 没有派息事件：稳定 0。
        XCTAssertEqual(halfYield?.stabilityPoints, 0)

        // 现价贴区间上沿 → 位置 0；回撤 0 → 回撤分 0。
        let samples = [bar(0, low: 1, high: 2, close: 2), bar(1, low: 1, high: 2, close: 2)]
        let atHigh = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.02")!,
            price: 2, iopv: nil, samples: samples, dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(atHigh?.positionPoints, 0)
        XCTAssertEqual(atHigh?.drawdownPoints, 0)

        // 回撤 10%（满分线 20% 的一半）→ 8 分（四舍五入）。
        let halfDrawdown = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.02")!,
            price: Decimal(string: "1.8")!, iopv: nil, samples: samples, dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(halfDrawdown?.drawdownPoints, 8)

        // 只有一年有已核实派息 → 4 分；推测事件不算。
        let events = [
            NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2026-09-10", amountPerShare: Decimal(string: "0.012")!, isEstimated: true)
        ]
        let oneYear = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.02")!,
            price: 1, iopv: nil, samples: [], dividendEvents: events, today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(oneYear?.stabilityPoints, 4)
    }

    func testDividendBuyScoreUsesIOPVForETFAndTargetYieldGate() {
        // ETF 有 IOPV：股息率按净值算。每份 0.05、现价 1.2、IOPV 1.0 → 5%。
        let samples = [bar(0, low: 1, high: 1, close: 1)]
        let byNav = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.05")!,
            price: Decimal(string: "1.2")!, iopv: 1, samples: samples, dividendEvents: [], today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(byNav?.yieldBase, 1)
        XCTAssertEqual(byNav?.yieldPercent ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(byNav?.yieldPoints, 40)

        // 目标股息率没设（≤0）：股息率项 0 分并记缺失。
        let noTarget = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.05")!,
            price: 1, iopv: nil, samples: samples, dividendEvents: [], today: "2026-10-20", targetYieldPercent: 0))
        XCTAssertEqual(noTarget?.yieldPoints, 0)
        XCTAssertTrue(noTarget?.missing.contains("目标股息率") ?? false)
    }

    func testDividendBuyScoreTierBoundaries() {
        let events = [
            NextETFDividendEvent(code: "563020", date: "2024-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2025-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!)
        ]
        let samples = (-179...0).map { bar($0, low: 1, high: 2, close: 1) }
        // 全拿满：40 + 35 + 15 + 10 = 100 → 值得关注。
        let high = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.05")!,
            price: 1, iopv: nil, samples: samples, dividendEvents: events, today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(high?.total, 100)
        XCTAssertEqual(high?.tier, .attention)
        // 边界用组件分直接验证档位划分。
        let batch = DividendBuyScore(code: "563020", price: 1, perShare: 0.03, yieldBase: 1,
            yieldPercent: 3, targetYieldPercent: 4, yieldPoints: 30, positionPoints: 20, drawdownPoints: 8,
            stabilityPoints: 7, windowLow: nil, windowHigh: nil, missing: [])
        XCTAssertEqual(batch.total, 65)
        XCTAssertEqual(batch.tier, .batch)
        let observe = DividendBuyScore(code: "563020", price: 1, perShare: 0.01, yieldBase: 1,
            yieldPercent: 1, targetYieldPercent: 4, yieldPoints: 10, positionPoints: 20, drawdownPoints: 8,
            stabilityPoints: 4, windowLow: nil, windowHigh: nil, missing: [])
        XCTAssertEqual(observe.total, 42)
        XCTAssertEqual(observe.tier, .observe)
        let wait = DividendBuyScore(code: "563020", price: 1, perShare: 0.001, yieldBase: 1,
            yieldPercent: 0.1, targetYieldPercent: 4, yieldPoints: 1, positionPoints: 20, drawdownPoints: 8,
            stabilityPoints: 4, windowLow: nil, windowHigh: nil, missing: [])
        XCTAssertEqual(wait.total, 33)
        XCTAssertEqual(wait.tier, .wait)
    }

    func testDividendBuyScoreDoesNotRecommendOnShortDailyHistory() {
        let events = [
            NextETFDividendEvent(code: "563020", date: "2024-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2025-06-10", amountPerShare: Decimal(string: "0.012")!),
            NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!)
        ]
        let shortHistory = (-4...0).map { bar($0, low: 1, high: 2, close: 1) }
        let score = try? XCTUnwrap(DividendBuyScoreEngine.evaluate(code: "563020", perShare: Decimal(string: "0.05")!,
            price: 1, iopv: nil, samples: shortHistory, dividendEvents: events,
            today: "2026-10-20", targetYieldPercent: 4))
        XCTAssertEqual(score?.total, 100, "The partial score remains inspectable")
        XCTAssertEqual(score?.tier, .insufficient, "Short history must block an attractive buy signal")
        XCTAssertTrue(score?.missing.contains("近180日日K不足") ?? false)
    }

}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
