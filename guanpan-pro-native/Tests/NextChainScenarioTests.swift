import XCTest
@testable import GuanpanAdvisorCore

/// 端到端场景：真实持仓 → 行情 → 日K/分时 → NAS 长期统计 → 市场状态 → 策略选择 →
/// 具体限价与份额 → 净收益/等效降本 → 新闻 → 一份统一结论。
///
/// 这五个场景就是验收清单里的 A–E。数据是合成夹具，但走的是**生产代码路径**：
/// 没有为测试单独开分支，也没有任何 Mock 价格。
final class NextChainScenarioTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1792375200)
    let code = "159941"

    private func rules() -> NextInstrumentRules {
        NextInstrumentRules(code: code, market: "SZ", assetClass: .etf, settlement: .t0, lotSize: 100,
                            feePerTrade: Decimal(string: "0.10"), source: "fixture", verifiedAt: now)
    }

    private func quote(price: Double, previousClose: Double = 1.400, iopv: Double? = nil) -> NextQuote {
        NextQuote(code: code, name: "纳指ETF", price: Decimal(string: String(format: "%.3f", price))!,
                  previousClose: Decimal(string: String(format: "%.3f", previousClose))!,
                  time: now, source: "fixture", timeQuality: "exchange_time",
                  iopv: iopv.flatMap { Decimal(string: String(format: "%.3f", $0)) },
                  providerInstrumentType: iopv == nil ? nil : "ETF")
    }

    private func book(units: Int = 10_000, cash: Double = 50_000) -> NextBook {
        NextBook(cash: Decimal(string: String(format: "%.2f", cash))!, positions: [
            NextPosition(code: code, name: "纳指ETF", units: units,
                         bookCost: Decimal(string: "13800")!)
        ])
    }

    private func orderBook() -> NextOrderBookSnapshot {
        NextOrderBookSnapshot(code: code, observedAt: now, source: "synthetic test fixture",
                              bids: ["1.399", "1.398", "1.397", "1.396", "1.395"].map {
                                  NextBookLevel(price: Decimal(string: $0)!, units: 2_000)
                              },
                              asks: ["1.401", "1.402", "1.403", "1.404", "1.405"].map {
                                  NextBookLevel(price: Decimal(string: $0)!, units: 2_000)
                              })
    }

    /// 日 K 夹具：按收盘价序列生成，高低点按比例包住收盘价，成交量给到「上亿成交额」量级。
    private func bars(_ closes: [Double], bandPercent: Double = 0.6, volume: Int = 900_000) -> [NextChartSample] {
        closes.enumerated().map { index, value in
            let price = Decimal(string: String(format: "%.4f", value))!
            let band = Decimal(string: String(format: "%.4f", bandPercent / 100))!
            return NextChartSample(timestamp: now.addingTimeInterval(Double(index - closes.count) * 86_400),
                                   open: price, high: price * (1 + band), low: price * (1 - band),
                                   close: price, iopv: nil, volume: Decimal(volume))
        }
    }

    /// 分时夹具：在 [low, high] 之间按 given 序列走，用来控制「穿越 VWAP 次数」。
    private func minutes(_ prices: [Double]) -> [NextChartSample] {
        prices.enumerated().map { index, value in
            let price = Decimal(string: String(format: "%.4f", value))!
            // The final sample is known at the decision instant. Earlier points
            // are historical; placing them after `now` would correctly trigger
            // the production look-ahead filter and leave a one-point fixture.
            let secondsBeforeNow = Double(prices.count - 1 - index) * 60
            return NextChartSample(timestamp: now.addingTimeInterval(-secondsBeforeNow),
                                   open: price, high: price, low: price, close: price,
                                   iopv: nil, volume: 10_000)
        }
    }

    /// 120 根日 K：1.388 / 1.412 / 1.400 三值循环，最新价落在区间中部，
    /// 既满足「贴近 MA20」（震荡），又不会被判成 60 日极端。
    private func oscillatingCloses() -> [Double] {
        (0..<120).map { [1.388, 1.412, 1.400][$0 % 3] }
    }

    func testUnifiedAIContextCannotInventUnverifiedCrossMarketLeads() {
        let guidance = NextDailyGuidance(generatedAt: now, items: [], summary: "暂无操作机会",
                                         noActionSummary: "继续持有", dataState: "跨市场研究不可用")
        let missing = NextDecisionContextBuilder.build(guidance: guidance, book: NextBook(), quotes: [:],
                                                       nasResearchLines: [], newsLines: [], now: now)
        XCTAssertTrue(missing.promptBlock.contains("NAS尚无可引用的跨市场分钟研究"))
        XCTAssertTrue(missing.promptBlock.contains("不得凭经验推断某海外市场会领先持仓"))

        let evidenced = NextDecisionContextBuilder.build(guidance: guidance, book: NextBook(), quotes: [:],
                                                          nasResearchLines: [],
                                                          crossMarketLines: ["半导体：no_stable_relationship；15分钟观察：方向背离 1 个来源；仅为同窗价格观察，不是预测或交易信号"],
                                                          newsLines: [], now: now)
        XCTAssertTrue(evidenced.promptBlock.contains("方向背离 1 个来源"))
        XCTAssertTrue(evidenced.promptBlock.contains("仅为同窗价格观察，不是预测或交易信号"))
        XCTAssertTrue(evidenced.promptBlock.contains("缺失/过期/样本不足"))
        XCTAssertTrue(evidenced.promptBlock.contains("不能描述成今天的海外实时方向信号"))
        XCTAssertTrue(evidenced.promptBlock.contains("预注册的未来未见样本复现"))
    }

    func testUnifiedAIContextIncludesPortfolioTargetAndRuleRiskEvidence() {
        let confidence = NextDataConfidence.assess(quote: nil, now: now, dailyBarCount: 0, minuteSampleCount: 0)
        let item = NextGuidanceItem(code: "159941", name: "纳指ETF", state: .wideRange,
            strategy: .noTrade, headline: "组合仓位超限", whyToday: ["低于目标权重，仅作排序参考"],
            tPlan: nil, gridPlan: nil, recovery: nil, confidence: confidence,
            portfolioNote: "组合行情不完整，暂停加仓", riskNotes: ["没有可靠来源报价"],
            score: 0, rank: 1, isActionable: false)
        let guidance = NextDailyGuidance(generatedAt: now, items: [item], summary: "今天不建议交易",
                                         noActionSummary: "继续持有", dataState: "持仓数据不足")
        let portfolioReview = NextAccountReview(headline: "组合估值不完整",
            findings: [NextAccountFinding(title: "现金储备", detail: "低于长期目标，优先保留现金", severity: .act)],
            footnotes: ["组合占比未计算：报价不全"])
        let context = NextDecisionContextBuilder.build(guidance: guidance, book: NextBook(), quotes: [:],
                                                       nasResearchLines: [], newsLines: [],
                                                       goal: NextGoal(targetWeights: ["159941": 60, "563020": 30]),
                                                       portfolioReview: portfolioReview, now: now)
        XCTAssertTrue(context.promptBlock.contains("低于目标权重，仅作排序参考"))
        XCTAssertTrue(context.promptBlock.contains("组合行情不完整，暂停加仓"))
        XCTAssertTrue(context.promptBlock.contains("没有可靠来源报价"))
        XCTAssertTrue(context.promptBlock.contains("长期现金储备目标 10.0%"))
        XCTAssertTrue(context.promptBlock.contains("若没有通过价格、数据和组合风险检查的机会，应保留现金"))
        XCTAssertTrue(context.promptBlock.contains("现金储备：低于长期目标，优先保留现金"))
        XCTAssertTrue(context.promptBlock.contains("组合占比未计算：报价不全"))
    }

    func testDecisionContextDoesNotPresentStalePortfolioWeightsAsCurrent() {
        let book = NextBook(cash: 10_000, positions: [
            NextPosition(code: code, name: "纳指ETF", units: 1_000, bookCost: 1_300),
            NextPosition(code: "513100", name: "日经ETF", units: 1_000, bookCost: 1_100)
        ])
        let first = quote(price: 1.4)
        let second = NextQuote(code: "513100", name: "日经ETF", price: 1.1, previousClose: 1.1,
                               time: now.addingTimeInterval(-121), source: "fixture", timeQuality: "exchange_time")
        let guidance = NextDailyGuidance(generatedAt: now, items: [], summary: "无候选",
                                         noActionSummary: "继续持有", dataState: "行情过期")
        let stale = NextDecisionContextBuilder.build(guidance: guidance, book: book,
            quotes: [code: first, "513100": second], nasResearchLines: [], newsLines: [], now: now)
        XCTAssertFalse(stale.holdingsLines.contains(where: { $0.contains("占比") }),
            "任一持仓行情过期时不应把其他旧估值显示成当前组合占比")

        let freshSecond = NextQuote(code: "513100", name: "日经ETF", price: 1.1, previousClose: 1.1,
                                    time: now, source: "fixture", timeQuality: "exchange_time")
        let fresh = NextDecisionContextBuilder.build(guidance: guidance, book: book,
            quotes: [code: first, "513100": freshSecond], nasResearchLines: [], newsLines: [], now: now)
        XCTAssertTrue(fresh.holdingsLines.allSatisfy { $0.contains("占比") },
            "全持仓行情新鲜可信时才显示组合占比")
    }

    func testPortfolioCorrelationUsesAlignedHistoricalBarsAndRejectsInsufficientOrFutureSamples() {
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: code, name: "纳指ETF", units: 1_000, bookCost: 1_300),
            NextPosition(code: "513100", name: "日经ETF", units: 1_000, bookCost: 1_100)
        ])
        let changes: [Double] = [0.010, -0.014, 0.006, -0.003, 0.018, -0.009, 0.004]
        var closeA = 100.0, closeB = 80.0
        var barsA: [NextChartSample] = [], barsB: [NextChartSample] = []
        for index in 0...120 {
            if index > 0 {
                let change = changes[(index - 1) % changes.count]
                closeA *= 1 + change
                closeB *= 1 + change
            }
            let stamp = now.addingTimeInterval(-Double(120 - index) * 86_400)
            barsA.append(NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil,
                close: Decimal(string: String(format: "%.6f", closeA))!, iopv: nil, volume: nil))
            barsB.append(NextChartSample(timestamp: stamp, open: nil, high: nil, low: nil,
                close: Decimal(string: String(format: "%.6f", closeB))!, iopv: nil, volume: nil))
        }
        let daily = [code: barsA, "513100": barsB]
        let pairs = NextPortfolioCorrelationEngine.analyze(book: book, dailyBars: daily, now: now)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].windows.count, 3)
        XCTAssertEqual(pairs[0].windows[0].sampleCount, 20)
        XCTAssertEqual(pairs[0].windows[1].sampleCount, 60)
        XCTAssertEqual(pairs[0].windows[2].sampleCount, 120)
        XCTAssertEqual(pairs[0].windows[2].coefficient ?? 0, 1, accuracy: 0.0001)

        var withFuture = daily
        let future = now.addingTimeInterval(86_400)
        for key in [code, "513100"] {
            withFuture[key, default: []].append(NextChartSample(timestamp: future, open: nil, high: nil,
                low: nil, close: 999, iopv: nil, volume: nil))
        }
        let futureFiltered = NextPortfolioCorrelationEngine.analyze(book: book, dailyBars: withFuture, now: now)
        XCTAssertEqual(futureFiltered, pairs, "未来日K不能进入历史相关性")

        let shortBook = NextBook(cash: 0, positions: [
            NextPosition(code: code, name: "纳指ETF", units: 1_000, bookCost: 1_300),
            NextPosition(code: "513100", name: "日经ETF", units: 1_000, bookCost: 1_100)
        ])
        let shortA = Array(barsA.suffix(12)), shortB = Array(barsB.suffix(12))
        let short = NextPortfolioCorrelationEngine.analyze(book: shortBook,
            dailyBars: [code: shortA, "513100": shortB], now: now)
        XCTAssertTrue(short[0].windows.allSatisfy { $0.coefficient == nil },
            "少于20个共同收益样本时明确显示不足，不产生相关结论")

        let context = NextDecisionContextBuilder.build(
            guidance: NextDailyGuidance(generatedAt: now, items: [], summary: "无候选",
                noActionSummary: "持有", dataState: "研究中"),
            book: book, quotes: [:], nasResearchLines: [], newsLines: [], dailyBars: daily, now: now)
        XCTAssertTrue(context.portfolioCorrelationLines.first?.contains("120日 r=") == true)
        XCTAssertTrue(context.promptBlock.contains("不代表成分重叠、因果或未来预测"))
    }

    func testOnlineAIOutputGuardBlocksUnplannedActionPrices() {
        let guidance = NextDailyGuidance(generatedAt: now, items: [], summary: "今天不建议交易",
                                         noActionSummary: "继续持有", dataState: "无合格计划")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedActionPrice("建议卖出 500 份 @ 0.850 元，再在 0.830 买回。", guidance: guidance))
        XCTAssertFalse(NextAIOutputGuard.containsUnverifiedActionPrice("今天不建议交易，继续持有并等待数据更新。", guidance: guidance))
        XCTAssertFalse(NextAIOutputGuard.containsUnverifiedActionPrice("预计净收益约 ¥96.5，置信度中。", guidance: guidance))
        let planPrices: Set<Decimal> = [Decimal(string: "0.850")!, Decimal(string: "0.830")!]
        XCTAssertFalse(NextAIOutputGuard.containsUnverifiedAction("建议卖出 500 份 @ 0.850 元，再在 0.830 买回 500 份。",
                                                                    approvedPrices: planPrices, approvedUnits: [500]))
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedAction("建议卖出 500 份 @ 0.850 元，再在 0.831 买回 500 份。",
                                                                   approvedPrices: planPrices, approvedUnits: [500]),
                      "命中合法卖价不能授权模型另造买回价")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedAction("建议卖出 900 份 @ 0.850 元。",
                                                                   approvedPrices: planPrices, approvedUnits: [500]))
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedAction("建议卖出价 1 元。",
                                                                   approvedPrices: planPrices, approvedUnits: [500]),
                      "整数价位同样不能绕过价格授权检查")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedFinancialClaim("预计净收益约 ¥96.5，等效降本 0.019 元/份。"),
                      "大模型不能重述或编造计划收益与降本数值")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedFinancialClaim("手续费 0.10 元/笔。"),
                      "手续费只能使用交易规则卡片的确定值")
        XCTAssertFalse(NextAIOutputGuard.containsUnverifiedFinancialClaim("今天先观察，主要风险是单边下跌。"))

        let confidence = NextDataConfidence.assess(quote: quote(price: 1.4), now: now,
            dailyBarCount: 60, minuteSampleCount: 120, intradayLatestAt: now, dailyLatestAt: now)
        let withdrawnPlan = NextTPlan(kind: .reverse, code: code, name: "纳指ETF",
            sellPrice: Decimal(string: "0.850")!, buyPrice: Decimal(string: "0.830")!, units: 500,
            grossSpread: 10, feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "9.80")!,
            costReductionPerUnit: Decimal(string: "0.0098")!, estimatedMissedUpside: 2,
            estimatedContinuedDropLoss: 3, trampleRisk: "踏空风险", continuedDropRisk: "下跌风险",
            volumeSupport: "成交量可支持", validUntil: now.addingTimeInterval(3600), cancelConditions: [],
            evidence: [], confidence: confidence, historyMissRate: nil)
        let withdrawnItem = NextGuidanceItem(code: code, name: "纳指ETF", state: .wideRange,
            strategy: .tTrade, headline: "组合风险撤回", whyToday: [], tPlan: .ready(withdrawnPlan),
            gridPlan: nil, recovery: nil, confidence: confidence,
            portfolioNote: "组合仓位超过目标上限", riskNotes: [], score: 0, rank: 1, isActionable: false)
        let withdrawnGuidance = NextDailyGuidance(generatedAt: now, items: [withdrawnItem],
            summary: "今天不建议交易", noActionSummary: "继续持有", dataState: "组合风险撤回")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedActionPrice(
            "建议卖出 500 份 @ 0.850 元，再在 0.830 买回。", guidance: withdrawnGuidance),
            "被组合风险撤回的计划不能授权在线模型引用其中的价格或份额")

        let allowedItem = NextGuidanceItem(code: code, name: "纳指ETF", state: .wideRange,
            strategy: .tTrade, headline: "规则计划可执行", whyToday: [], tPlan: .ready(withdrawnPlan),
            gridPlan: nil, recovery: nil, confidence: confidence, portfolioNote: nil, riskNotes: [],
            score: 1, rank: 1, isActionable: true)
        let otherPlan = NextTPlan(kind: .reverse, code: "513100", name: "日经ETF",
            sellPrice: Decimal(string: "1.110")!, buyPrice: Decimal(string: "1.100")!, units: 200,
            grossSpread: 2, feeTotal: Decimal(string: "0.20")!, netGain: Decimal(string: "1.80")!,
            costReductionPerUnit: Decimal(string: "0.009")!, estimatedMissedUpside: 2,
            estimatedContinuedDropLoss: 3, trampleRisk: "踏空风险", continuedDropRisk: "下跌风险",
            volumeSupport: "成交量可支持", validUntil: now.addingTimeInterval(3600), cancelConditions: [],
            evidence: [], confidence: confidence, historyMissRate: nil)
        let otherItem = NextGuidanceItem(code: "513100", name: "日经ETF", state: .wideRange,
            strategy: .tTrade, headline: "规则计划可执行", whyToday: [], tPlan: .ready(otherPlan),
            gridPlan: nil, recovery: nil, confidence: confidence, portfolioNote: nil, riskNotes: [],
            score: 1, rank: 2, isActionable: true)
        let twoHoldingGuidance = NextDailyGuidance(generatedAt: now, items: [allowedItem, otherItem],
            summary: "有两只候选", noActionSummary: "无", dataState: "完整")
        XCTAssertFalse(NextAIOutputGuard.containsUnverifiedActionPrice(
            "纳指ETF建议卖出 500 份 @ 0.850 元；513100日经ETF建议买回 200 份 @ 1.100 元。",
            guidance: twoHoldingGuidance))
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedActionPrice(
            "513100日经ETF建议买回 200 份 @ 0.850 元。", guidance: twoHoldingGuidance),
            "一只ETF的有效价格不能被挪用到另一只ETF")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedActionPrice(
            "建议卖出 500 份 @ 0.850 元。", guidance: twoHoldingGuidance),
            "存在多个可执行持仓时，未标证券的具体交易数字应拒绝")
        let withdrawnOther = NextGuidanceItem(code: "510050", name: "上证50ETF", state: .trendingDown,
            strategy: .pauseAdd, headline: "暂停加仓", whyToday: [], tPlan: nil, gridPlan: nil,
            recovery: nil, confidence: confidence, portfolioNote: "组合超限", riskNotes: [],
            score: -1, rank: 3, isActionable: false)
        let mixedGuidance = NextDailyGuidance(generatedAt: now,
            items: [allowedItem, otherItem, withdrawnOther], summary: "有候选", noActionSummary: "无",
            dataState: "组合风险拦截")
        XCTAssertTrue(NextAIOutputGuard.containsUnverifiedActionPrice(
            "上证50ETF建议卖出 500 份 @ 0.850 元。", guidance: mixedGuidance),
            "非actionable标的不能借用其他ETF的有效数字")
    }

    func testPhoneQuoteChainFillsOnlyMissingCodesFromFallbackSources() async throws {
        struct QuoteStub { let code: String }
        let result = try await NextMarketChain.fillMissing(
            requested: ["A", "B", "B"],
            attempts: [
                ("主源", { codes -> [QuoteStub] in
                    codes.filter { $0 == "A" }.map { QuoteStub(code: $0) }
                }),
                ("备用源", { codes -> [QuoteStub] in
                    XCTAssertEqual(codes, ["B"], "备用源只应收到主源缺失的证券")
                    return [QuoteStub(code: "B")]
                })
            ],
            key: { $0.code })
        XCTAssertEqual(result.value.map(\.code), ["A", "B"])
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(result.source, "主源 1只 + 备用源 1只")
    }

    func testHistoricalChainFallsThroughSparseSuccessAndKeepsSourcePriority() async throws {
        struct Samples { let count: Int }
        var tertiaryWasCalled = false
        let result = try await NextMarketChain.richest([
            ("优先源", { Samples(count: 2) }),
            ("备用源", { Samples(count: 120) }),
            ("第三源", { tertiaryWasCalled = true; return Samples(count: 200) })
        ], minimumSamples: 120, sampleCount: { $0.count })
        XCTAssertEqual(result.value.count, 120)
        XCTAssertEqual(result.source, "备用源")
        XCTAssertFalse(tertiaryWasCalled, "Stop once a fallback meets the history target")

        let limited = try await NextMarketChain.richest([
            ("短历史", { Samples(count: 8) }),
            ("较完整历史", { Samples(count: 40) })
        ], minimumSamples: 120, sampleCount: { $0.count })
        XCTAssertEqual(limited.value.count, 40)
        XCTAssertTrue(limited.source.contains("样本最多"))
    }

    func testHistoricalCrossMarketCandidateDecodesAsNonTradingEvidence() throws {
        let payload = """
        {"factors":null,"ai":null,"providerConfigured":false,"crossMarket":{
          "state":"stable_candidate","reason":null,"source":"verified archive",
          "asOf":"2026-10-23T03:00:00+00:00","sampleCount":120,
          "bestLagMinutes":15,"conditionalWinRate":0.62,"bestMarket":"KR_KOSPI",
          "currentMarketStatus":"closed","ageSeconds":300,
          "eligibleForTradingSignal":false,
          "validationState":"requires_pre_registered_future_replication"}}
        """
        let report = try JSONDecoder().decode(NextNASResearch.self, from: Data(payload.utf8))
        XCTAssertEqual(report.crossMarket?.bestMarket, "KR_KOSPI")
        XCTAssertEqual(report.crossMarket?.eligibleForTradingSignal, false)
        XCTAssertEqual(report.crossMarket?.validationState, "requires_pre_registered_future_replication")
    }

    func testMismatchedQuoteCodeCannotSupportPortfolioGuidance() {
        let wrongQuote = NextQuote(code: "000001", name: "错误映射", price: 1.4, previousClose: 1.4,
                                   time: now, source: "fixture", timeQuality: "exchange_time")
        let guidance = NextOpportunityScanner.scan(book: book(), quotes: [code: wrongQuote],
            daily: [:], intraday: [:], rules: [:], goal: NextGoal(), now: now)
        XCTAssertEqual(guidance.items.count, 1)
        XCTAssertFalse(guidance.items[0].isActionable)
        XCTAssertTrue(guidance.items[0].portfolioNote?.contains("组合内并非所有真实持仓") == true)
        XCTAssertEqual(guidance.items[0].confidence.level, .blocked)
    }

    private func scan(_ scanBook: NextBook, quote q: NextQuote, daily: [NextChartSample],
                      intraday: [NextChartSample], research: [String: NextNASResearch] = [:],
                      news: [String: [NextNewsInput]] = [:],
                      profile: NextInvestorProfile? = nil, nasConfigured: Bool? = nil,
                      nasReachable: Bool? = nil) -> NextDailyGuidance {
        NextOpportunityScanner.scan(book: scanBook, quotes: [code: q], daily: [code: daily],
                                    intraday: [code: intraday], rules: [code: rules()],
                                    orderBooks: [code: orderBook()], goal: NextGoal(),
                                    nasConfigured: nasConfigured ?? !research.isEmpty,
                                    nasReachable: nasReachable,
                                    nasProbedAt: nasReachable == nil ? nil : now,
                                    profile: profile, research: research, news: news, now: now)
    }

    private func research(days: Int = 60, amplitude: Double = 1.6, roundTrips: Double = 2.4,
                          stale: Bool = false) -> NextNASResearch {
        let window = NextNASMinuteStats.Window(window: 60, daysUsed: days, dayCoverage: 1,
                                              minuteCoverage: 0.95, vwap: "1.3990",
                                              closeVsVwapPercent: 0.35,
                                              amplitudeMedianPercent: amplitude,
                                              roundTripsMedian: roundTrips,
                                              support: "1.3600", resistance: "1.4400",
                                              supportP10: "1.3700", resistanceP90: "1.4300",
                                              volatilityPercent: 1.1, vwapHighDeviationMedian: 0.008,
                                              vwapLowDeviationMedian: -0.008, volumeCoverage: 0.95)
        let short = NextNASMinuteStats.Window(window: 20, daysUsed: min(days, 20), dayCoverage: 1,
                                              minuteCoverage: 0.95, vwap: "1.3990",
                                              closeVsVwapPercent: 0.35,
                                              amplitudeMedianPercent: amplitude,
                                              roundTripsMedian: roundTrips,
                                              support: "1.3800", resistance: "1.4300",
                                              supportP10: "1.3800", resistanceP90: "1.4300",
                                              volatilityPercent: 1.0)
        let stats = NextNASMinuteStats(days: days, minutes: days * 240, lastDay: "2026-10-22",
                                       quality: .init(days: days, minuteCoverage: 0.95, hasVolume: true,
                                                      enoughForLongTerm: days >= 60, volumeCoverage: 0.95),
                                       freshness: .init(lastDay: "2026-10-22", ageMinutes: 120,
                                                        isToday: true, stale: stale,
                                                        reason: stale ? "最后一条分时超过一天" : nil),
                                       windows: ["20": short, "60": window])
        return NextNASResearch(factors: nil, ai: nil, providerConfigured: false, minuteStats: stats)
    }

    // MARK: - A 上涨趋势：拿住，不做T、不追高

    func testScenarioA_TrendUpHoldsWithoutAnyPlan() {
        let closes = (0..<120).map { 1.20 * pow(1.004, Double($0)) }
        let last = closes.last!
        let guidance = scan(book(), quote: quote(price: last, previousClose: last / 1.006), daily: bars(closes),
                            intraday: minutes((0..<60).map { 1.90 + Double($0) * 0.0005 }))
        let item = try! XCTUnwrap(guidance.items.first)
        XCTAssertEqual(item.state, .trendingUp, item.whyToday.joined(separator: " | "))
        XCTAssertEqual(item.strategy, .hold)
        XCTAssertNil(item.tPlan)
        XCTAssertNil(item.gridPlan)
        XCTAssertFalse(item.isActionable)
        XCTAssertTrue(item.whyToday.joined().contains("20 日上涨"))
    }

    // MARK: - B 日内往返：给出具体限价、份额、净收益与等效降本

    func testScenarioB_IntradayRoundTripGivesRealPricesAndNetGain() {
        // 日 K 在 1.388/1.412 之间来回，分时在 VWAP 上下穿 4 次以上。
        let closes = oscillatingCloses()
        let intraday = minutes((0..<60).map { [1.386, 1.412, 1.387, 1.413, 1.388, 1.414][$0 % 6] })
        let guidance = scan(book(), quote: quote(price: 1.400), daily: bars(closes),
                            intraday: intraday, research: [code: research()])
        let item = try! XCTUnwrap(guidance.items.first)
        XCTAssertEqual(item.state, .wideRange, item.whyToday.joined(separator: " | "))
        XCTAssertEqual(item.strategy, .tTrade)
        XCTAssertTrue(item.isActionable)
        guard let result = item.tPlan, case let .ready(plan) = result else {
            return XCTFail("日内往返应给出做T计划：\(String(describing: item.tPlan))")
        }
        XCTAssertTrue(plan.buyPrice > 0 && plan.sellPrice > plan.buyPrice)
        XCTAssertEqual(plan.units % 100, 0, "份额必须是整手")
        XCTAssertGreaterThan(plan.netGain, 0, "净收益必须扣完两笔手续费后为正")
        XCTAssertGreaterThan(plan.costReductionPerUnit, 0, "等效降本必须为正")
        XCTAssertEqual(plan.feeTotal, Decimal(string: "0.20")!, "两笔手续费都要进计算")
        let amplitude = try! XCTUnwrap(NextIntradayStatsEngine.compute(samples: intraday, previousClose: quote(price: 1.400).previousClose).amplitudePercent)
        XCTAssertEqual(plan.estimatedMissedUpside,
                       plan.sellPrice * Decimal(amplitude / 100) * Decimal(plan.units) + Decimal(string: "0.10")!,
                       "踏空情景只计算卖出后涨幅与已发生的卖出手续费，不重复计入计划价差")
        XCTAssertEqual(plan.estimatedContinuedDropLoss,
                       plan.buyPrice * Decimal(amplitude / 100) * Decimal(plan.units) + Decimal(string: "0.10")!,
                       "下跌情景应单列买入后继续下跌的风险量级")
        XCTAssertTrue(plan.continuedDropRisk.contains("情景"))
        XCTAssertTrue(plan.evidence.contains { $0.contains("VWAP") })
        XCTAssertFalse(plan.cancelConditions.isEmpty)
        XCTAssertEqual(plan.validUntil, NextPlanClock.sessionEnd(after: now))
        // NAS 长期统计必须真的进了这条结论，而不是只存在字典里。
        XCTAssertTrue(item.whyToday.contains { $0.contains("NAS") }, item.whyToday.joined(separator: " | "))
        XCTAssertFalse(guidance.dataState.contains("离线"))
    }

    func testFutureDatedMarketSamplesCannotChangeStateOrTradePrices() throws {
        let closes = oscillatingCloses()
        let intraday = minutes((0..<60).map { [1.386, 1.412, 1.387, 1.413, 1.388, 1.414][$0 % 6] })
        let q = quote(price: 1.400)
        let researchData = [code: research()]
        let baseline = try XCTUnwrap(scan(book(), quote: q, daily: bars(closes), intraday: intraday,
                                          research: researchData).items.first)
        let future = NextChartSample(timestamp: now.addingTimeInterval(86_400), open: 5, high: 5, low: 5,
                                     close: 5, iopv: nil, volume: 10_000_000)
        let polluted = try XCTUnwrap(scan(book(), quote: q, daily: bars(closes) + [future],
                                          intraday: intraday + [future], research: researchData).items.first)

        XCTAssertEqual(polluted.state, baseline.state)
        XCTAssertEqual(polluted.strategy, baseline.strategy)
        XCTAssertEqual(polluted.confidence.dailyBarCount, baseline.confidence.dailyBarCount)
        XCTAssertEqual(polluted.confidence.minuteSampleCount, baseline.confidence.minuteSampleCount)
        guard case let .ready(expected) = try XCTUnwrap(baseline.tPlan),
              case let .ready(actual) = try XCTUnwrap(polluted.tPlan) else {
            return XCTFail("未来数据不能让既有的可靠计划变成缺失或改变策略")
        }
        XCTAssertEqual(actual.buyPrice, expected.buyPrice)
        XCTAssertEqual(actual.sellPrice, expected.sellPrice)
        XCTAssertEqual(actual.units, expected.units)
        XCTAssertEqual(actual.netGain, expected.netGain)
    }

    func testGuidanceSeparatesNASReachabilityFromCachedResearch() throws {
        let q = quote(price: 1.400)
        let closes = oscillatingCloses()
        let intraday = minutes((0..<60).map { [1.386, 1.412, 1.387, 1.413, 1.388, 1.414][$0 % 6] })
        let fresh = scan(book(), quote: q, daily: bars(closes), intraday: intraday,
                         research: [code: research()], nasConfigured: true, nasReachable: true)
        XCTAssertTrue(fresh.dataState.contains("NAS 在线"), fresh.dataState)
        XCTAssertTrue(fresh.dataState.contains("新鲜长期研究"), fresh.dataState)

        let unprobed = scan(book(), quote: q, daily: bars(closes), intraday: intraday,
                            research: [code: research()], nasConfigured: true)
        XCTAssertTrue(unprobed.dataState.contains("NAS 连接待检测"), unprobed.dataState)

        let cached = scan(book(), quote: q, daily: bars(closes), intraday: intraday,
                          research: [code: research()], nasConfigured: true, nasReachable: false)
        XCTAssertTrue(cached.dataState.contains("NAS 当前不可达"), cached.dataState)
        XCTAssertTrue(cached.dataState.contains("本机缓存"), cached.dataState)

        let stale = scan(book(), quote: q, daily: bars(closes), intraday: intraday,
                         research: [code: research(stale: true)], nasConfigured: true, nasReachable: true)
        XCTAssertTrue(stale.dataState.contains("NAS 在线"), stale.dataState)
        XCTAssertTrue(stale.dataState.contains("已过期或质量不足"), stale.dataState)
    }

    func testFreshMajorNewsInvalidatesSavedPlanButStaleNewsDoesNot() throws {
        let plan = NextCandidatePlan(kind: .gridBuy, code: code, name: "纳指ETF",
            limitPrice: Decimal(string: "1.380")!, units: 100,
            createdAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(3600),
            triggerNote: "回落触发", cancelNote: "突破区间",
            quoteSource: "fixture", quoteTime: now, dailyBarCount: 120, minuteSampleCount: 0,
            confidenceLevel: "high", rationale: "新闻失效闭环测试", expectedNetGain: nil,
            expectedCostReduction: nil, riskNote: "事件风险", marketState: "震荡",
            cancelAbove: nil, cancelBelow: nil)
        let formatter = ISO8601DateFormatter()
        let freshAt = formatter.string(from: now.addingTimeInterval(-60))
        let staleAt = formatter.string(from: now.addingTimeInterval(-31 * 86_400))
        let fresh = [NextNewsInput(title: "\(code) 纳指ETF 停牌公告",
                                   source: "交易所公告", publishedAt: freshAt, url: "https://example.test/notice")]
        let stale = [NextNewsInput(title: "\(code) 纳指ETF 停牌公告",
                                   source: "交易所公告", publishedAt: staleAt, url: "https://example.test/notice")]

        XCTAssertNotNil(NextCandidatePlanNewsGuard.invalidationReason(for: plan, headlines: fresh, now: now))
        XCTAssertNil(NextCandidatePlanNewsGuard.invalidationReason(for: plan, headlines: stale, now: now))
        XCTAssertNil(NextCandidatePlanNewsGuard.invalidationReason(
            for: plan, headlines: [NextNewsInput(title: "\(code) 市场观察", source: "新闻", publishedAt: freshAt)], now: now))
    }

    // MARK: - C 多日区间：网格档数由波动率与区间推导，不是固定 4 档

    func testScenarioC_GridTiersComeFromVolatilityNotAFixedFour() {
        let intraday = minutes((0..<60).map { 1.390 + Double($0) * 0.0003 })
        // 同一段区间，只把日均振幅从 1.2% 调到 1.8%：档数与间距都必须跟着变。
        let narrow = scan(book(), quote: quote(price: 1.400), daily: bars(oscillatingCloses(), bandPercent: 0.6),
                          intraday: intraday, research: [code: research()])
        let wide = scan(book(), quote: quote(price: 1.400), daily: bars(oscillatingCloses(), bandPercent: 0.9),
                        intraday: intraday, research: [code: research()])
        let item = try! XCTUnwrap(narrow.items.first)
        XCTAssertEqual(item.strategy, .grid, item.whyToday.joined(separator: " | "))
        guard case let .ready(planNarrow)? = item.gridPlan else {
            return XCTFail("区间稳定应给出网格档位：\(String(describing: item.gridPlan))")
        }
        guard case let .ready(planWide)? = wide.items.first?.gridPlan else {
            return XCTFail("振幅变大后仍应给出网格档位")
        }
        XCTAssertTrue(planNarrow.tiers.contains { $0.side == "buy" })
        XCTAssertTrue(planNarrow.tiers.contains { $0.side == "sell" }, "有真实持仓时必须给出卖出档")
        // 档数、间距都是推导出来的：不是写死的 4 档，也不是固定百分比。
        XCTAssertNotEqual(planNarrow.spacingPercent, planWide.spacingPercent,
                          "间距必须跟随日均振幅变化")
        XCTAssertNotEqual(planNarrow.tiers.count, planWide.tiers.count,
                          "档数必须由区间/间距推导")
        XCTAssertGreaterThan(planNarrow.spacingPercent, 0.39)
        XCTAssertLessThan(planNarrow.spacingPercent, 1.01, "间距应取「半倍日均振幅」")
        for plan in [planNarrow, planWide] {
            XCTAssertGreaterThan(plan.maxCashUsage, 0)
            XCTAssertLessThanOrEqual(plan.maxCashUsage, Decimal(50_000) + 10, "买入档不能超过可用现金")
            XCTAssertTrue(plan.upper > plan.lower)
            for tier in plan.tiers where tier.side == "buy" {
                XCTAssertGreaterThan(tier.cashRequired, tier.price * Decimal(tier.units),
                                     "每档买入成本必须含手续费")
                XCTAssertTrue(tier.price >= plan.lower && tier.price <= plan.upper)
            }
            XCTAssertTrue(plan.pauseConditions.contains { $0.contains("突破") })
        }
    }

    func testReliableLargeETFIOPVPremiumBlocksTAndGridExecutionPlans() throws {
        let intraday = minutes((0..<60).map { [1.386, 1.412, 1.387, 1.413, 1.388, 1.414][$0 % 6] })
        // 现价 1.400、可靠 IOPV 1.370，溢价约 +2.19%，超过明确的 ±1% 执行保护线。
        let inflated = quote(price: 1.400, iopv: 1.370)
        let tGuidance = scan(book(), quote: inflated, daily: bars(oscillatingCloses()),
                             intraday: intraday, research: [code: research()])
        let tItem = try XCTUnwrap(tGuidance.items.first)
        guard case let .notWorthwhile(reasons)? = tItem.tPlan else {
            return XCTFail("可靠 IOPV 大幅溢价必须阻止做T具体限价：\(String(describing: tItem.tPlan))")
        }
        XCTAssertTrue(reasons.joined(separator: " ").contains("IOPV"))
        XCTAssertFalse(tItem.isActionable)

        let gridGuidance = scan(book(), quote: inflated,
                                daily: bars(oscillatingCloses(), bandPercent: 0.6),
                                intraday: minutes((0..<60).map { 1.390 + Double($0) * 0.0003 }),
                                research: [code: research()])
        let gridItem = try XCTUnwrap(gridGuidance.items.first)
        guard case let .notRecommended(gridReasons)? = gridItem.gridPlan else {
            return XCTFail("可靠 IOPV 大幅溢价必须阻止网格具体档位：\(String(describing: gridItem.gridPlan))")
        }
        XCTAssertTrue(gridReasons.joined(separator: " ").contains("溢价"))
        XCTAssertFalse(gridItem.isActionable)
    }

    // MARK: - D 数据不足：拒绝给价格

    func testScenarioD_InsufficientDataRefusesToPrice() {
        let guidance = scan(book(), quote: quote(price: 1.400), daily: bars((0..<10).map { _ in 1.40 }),
                            intraday: minutes((0..<5).map { _ in 1.40 }))
        let item = try! XCTUnwrap(guidance.items.first)
        XCTAssertEqual(item.state, .insufficient)
        XCTAssertEqual(item.strategy, .noTrade)
        XCTAssertNil(item.tPlan)
        XCTAssertNil(item.gridPlan)
        XCTAssertFalse(item.isActionable)
        XCTAssertEqual(item.confidence.level, .blocked)
        XCTAssertTrue(item.whyToday.contains { $0.contains("20 根") })
    }

    // MARK: - E 重大新闻：收回原计划，但仍然只有一份结论

    func testScenarioE_MajorNewsRetractsGridPlanInTheSameConclusion() {
        let closes = oscillatingCloses()
        let intraday = minutes((0..<60).map { 1.390 + Double($0) * 0.0003 })
        let freshAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let news = [code: [NextNewsInput(title: "159941 公告：因重大事项停牌", source: "测试源",
                                        publishedAt: freshAt)]]
        let guidance = scan(book(), quote: quote(price: 1.400), daily: bars(closes),
                            intraday: intraday, news: news)
        let item = try! XCTUnwrap(guidance.items.first)
        XCTAssertEqual(item.newsImpact?.action, .pauseGrid)
        XCTAssertNotNil(item.gridPlan, "计划对象仍在，但已不是「可执行」")
        XCTAssertFalse(item.gridPlan?.isReady == true)
        XCTAssertFalse(item.isActionable)
        XCTAssertTrue(item.riskNotes.contains { $0.contains("停牌") })
        // 统一结论：不能被新闻另起一条互相矛盾的建议。
        XCTAssertEqual(guidance.items.count, 1)
        XCTAssertTrue(guidance.actionableItems.isEmpty)
    }

    // MARK: - 画像：只改优先级，不改价格

    func testProfileOnlyChangesPriorityNeverPrices() {
        var profile = NextInvestorProfile()
        profile.setTrait(NextProfileTrait(id: .tAppetite, value: "none", label: "不做日内往返",
                                          detail: "用户明确设定", confidence: 0.9, sampleCount: 0,
                                          windowDays: 90, source: .explicit, locked: true,
                                          basis: ["用户设定"], updatedAt: now))
        let closes = oscillatingCloses()
        let intraday = minutes((0..<60).map { [1.386, 1.412, 1.387, 1.413, 1.388, 1.414][$0 % 6] })
        let researchData = [code: research()]
        let plain = scan(book(), quote: quote(price: 1.400), daily: bars(closes), intraday: intraday,
                         research: researchData)
        let withProfile = scan(book(), quote: quote(price: 1.400), daily: bars(closes),
                               intraday: intraday, research: researchData, profile: profile)
        let a = try! XCTUnwrap(plain.items.first)
        let b = try! XCTUnwrap(withProfile.items.first)
        guard case let .ready(pa) = a.tPlan!, case let .ready(pb) = b.tPlan! else {
            return XCTFail("两边都应有可执行计划")
        }
        XCTAssertEqual(pa.buyPrice, pb.buyPrice, "画像不得改动价格")
        XCTAssertEqual(pa.sellPrice, pb.sellPrice, "画像不得改动价格")
        // 画像只能「压小」份额（上限），绝不放大；价格与净价差口径完全不变。
        XCTAssertLessThanOrEqual(pb.units, pa.units)
        XCTAssertGreaterThanOrEqual(pb.units, 100)
        XCTAssertLessThan(b.score, a.score, "画像只能降低优先级")
        XCTAssertNotNil(b.profileNote)
    }
}
