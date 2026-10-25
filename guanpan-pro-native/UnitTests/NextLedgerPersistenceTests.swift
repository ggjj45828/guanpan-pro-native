import XCTest
@testable import GuanpanProNative

final class NextLedgerPersistenceTests: XCTestCase {
    @MainActor
    private func assertAdviceCleared(_ model: NextAppModel, after update: @MainActor () -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) {
        model.unifiedAIAdvice = "旧在线分析正文"
        model.unifiedAIStatus = "在线 AI 分析已完成"
        update()
        let adviceAfterChange = model.unifiedAIAdvice
        let statusAfterChange = model.unifiedAIStatus
        XCTAssertNil(adviceAfterChange, "上下文发生变化时必须立即清除已显示的在线回答", file: file, line: line)
        XCTAssertTrue(statusAfterChange?.contains("旧在线AI回答已清除") == true,
                      "应明确告知用户旧回答已失效", file: file, line: line)
    }

    func testDisplayedOnlineAdviceIsClearedImmediatelyWhenDecisionInputsChange() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ai-context-invalidation-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = NextAppModel(repository: NextLocalRepository(directoryOverride: directory))

            self.assertAdviceCleared(model) {
                model.ledger = NextAuditedBook(current: NextBook(cash: 100))
            }
            let now = Date()
            let quote = NextQuote(code: "159941", name: "纳指ETF", price: 1.4, previousClose: 1.39,
                                  time: now, source: "licensed:test")
            self.assertAdviceCleared(model) {
                model.quotes = ["159941": NextCachedQuote(quote: quote,
                    stamp: NextDataStamp(source: "licensed:test", observedAt: now, quality: .live, detail: "test"))]
            }
            let sample = NextChartSample(timestamp: now, open: 1.39, high: 1.41, low: 1.38,
                                         close: 1.4, iopv: nil, volume: 100_000)
            self.assertAdviceCleared(model) {
                model.chartData = ["159941:day": NextChartDataset(code: "159941", interval: .day,
                    samples: [sample], costPerUnit: nil, costObservedAt: nil,
                    priceSource: "test", iopvSource: nil, observedAt: now)]
            }
            self.assertAdviceCleared(model) {
                model.nasResearch = ["159941": NextNASResearch(factors: nil, ai: nil, providerConfigured: false)]
            }
            self.assertAdviceCleared(model) {
                model.rules = ["159941": NextInstrumentRules.verifiedETFMarketRule(code: "159941", market: "SZSE", at: now)!]
            }
            let levels = Array(repeating: NextBookLevel(price: 1.39, units: 100), count: 5)
            let asks = [1.40, 1.41, 1.42, 1.43, 1.44].map { NextBookLevel(price: Decimal(string: "\($0)")!, units: 100) }
            self.assertAdviceCleared(model) {
                model.orderBooks = ["159941": NextOrderBookSnapshot(code: "159941", observedAt: now,
                    source: "test", bids: levels, asks: asks)]
            }
            self.assertAdviceCleared(model) {
                model.nasNews = ["159941": [NextNewsInput(title: "相关公告变化", source: "test")]]
            }
            self.assertAdviceCleared(model) {
                model.dividendEvents = ["159941": [NextETFDividendEvent(code: "159941", date: "2026-10-24", amountPerShare: 0.01)]]
            }
            self.assertAdviceCleared(model) {
                let plan = NextCandidatePlan(kind: .gridBuy, code: "159941", name: "纳指ETF",
                    limitPrice: 1.2, units: 100, createdAt: now, expiresAt: now.addingTimeInterval(3600),
                    triggerNote: "回落触发", cancelNote: "突破区间", quoteSource: "test", quoteTime: now,
                    dailyBarCount: 120, minuteSampleCount: 0, confidenceLevel: "medium",
                    rationale: "测试候选", expectedNetGain: nil, expectedCostReduction: nil,
                    riskNote: "价格波动", marketState: "震荡", cancelAbove: nil, cancelBelow: nil)
                model.candidatePlans = [plan]
            }
            self.assertAdviceCleared(model) {
                var changed = model.profile
                changed.updatedAt = now.addingTimeInterval(1)
                model.profile = changed
            }
            self.assertAdviceCleared(model) {
                var preferences = model.preferences
                preferences.goal.monthlyBudget += 1
                model.preferences = preferences
            }
            self.assertAdviceCleared(model) {
                var preferences = model.preferences
                preferences.marketSourceMode = .nasPreferred
                model.preferences = preferences
            }
            self.assertAdviceCleared(model) {
                var preferences = model.preferences
                preferences.nasBaseURL = "http://nas.example"
                model.preferences = preferences
            }
            self.assertAdviceCleared(model) {
                model.dailyGuidance = NextDailyGuidance(generatedAt: now, items: [], summary: "新规则结论",
                    noActionSummary: "继续持有", dataState: "新上下文")
            }
        }
    }

    func testInvalidProfileNumericInputDoesNotMutateExplicitPreferenceOrGridThreshold() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-profile-numeric-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = NextAppModel(repository: NextLocalRepository(directoryOverride: directory))
            let originalTiers = model.profile.thresholds.gridMaxTiers
            model.setProfileTrait(.gridTiers, value: "7", label: "非法档数", detail: "不可保存",
                                  numeric: .infinity)
            XCTAssertEqual(model.profile.thresholds.gridMaxTiers, originalTiers)
            XCTAssertNil(model.profile.trait(.gridTiers), "拒绝输入时不得创建或覆盖显式画像规则")
            XCTAssertTrue(model.notice.contains("有限"))

            model.setProfileTrait(.gridTiers, value: "3", label: "最多三档", detail: "用户上限",
                                  numeric: 3)
            XCTAssertEqual(model.profile.thresholds.gridMaxTiers, 3)
            XCTAssertEqual(model.profile.trait(.gridTiers)?.numeric, 3)
        }
    }

    func testRepositoryRejectsSemanticallyInvalidLedgerAndPreservesOriginalFile() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ledger-validation-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            let url = directory.appendingPathComponent("real-ledger-v1.json")
            let original = try JSONEncoder().encode(NextAuditedBook(current: NextBook(cash: -1)))
            try original.write(to: url, options: .atomic)

            let fallback = NextAuditedBook(current: NextBook())
            let loaded = repository.loadValidated(NextAuditedBook.self, filename: "real-ledger-v1.json",
                fallback: fallback, validate: { try $0.validate() })
            XCTAssertEqual(loaded, fallback)
            XCTAssertNotNil(repository.integrityWarning)
            XCTAssertNotNil(repository.save(fallback, filename: "real-ledger-v1.json"))
            XCTAssertEqual(try Data(contentsOf: url), original, "无效真实账本原文件必须保留且不能静默覆盖")
        }
    }

    func testRepositoryRejectsTruncatedLedgerJSONWithoutReplacingIt() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ledger-truncated-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            let url = directory.appendingPathComponent("real-ledger-v1.json")
            let damaged = Data("{\"current\":{\"cash\":13100,\"fills\":[".utf8)
            try damaged.write(to: url, options: .atomic)

            let fallback = NextAuditedBook(current: NextBook())
            let loaded = repository.loadValidated(NextAuditedBook.self, filename: "real-ledger-v1.json",
                fallback: fallback, validate: { try $0.validate() })
            XCTAssertEqual(loaded, fallback)
            XCTAssertNotNil(repository.integrityWarning)
            XCTAssertNotNil(repository.save(fallback, filename: "real-ledger-v1.json"))
            XCTAssertEqual(try Data(contentsOf: url), damaged, "截断账本必须保留，不能静默改成空账户")
        }
    }

    func testAppRejectsSemanticallyInvalidCandidatePlansWithoutReplacingOriginalFile() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-candidate-plan-validation-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            let now = Date().addingTimeInterval(-60)
            let invalidPlan = NextCandidatePlan(kind: .gridBuy, code: "159941", name: "纳指ETF",
                limitPrice: 1.2, units: -100, createdAt: now, expiresAt: now.addingTimeInterval(3600),
                triggerNote: "回落触发", cancelNote: "突破区间", quoteSource: "test", quoteTime: now,
                dailyBarCount: 120, minuteSampleCount: 0, confidenceLevel: "medium",
                rationale: "test candidate", expectedNetGain: nil, expectedCostReduction: nil,
                riskNote: "价格波动", marketState: "震荡", cancelAbove: nil, cancelBelow: nil)
            let original = try JSONEncoder().encode([invalidPlan])
            let url = directory.appendingPathComponent("candidate-plans-v1.json")
            try original.write(to: url, options: .atomic)

            let model = NextAppModel(repository: repository)
            XCTAssertTrue(model.candidatePlans.isEmpty, "语义无效的持久候选计划不能进入UI或后续决策上下文")
            XCTAssertTrue(model.errorMessage?.contains("candidate-plans-v1.json") == true)
            XCTAssertNotNil(repository.save([invalidPlan], filename: "candidate-plans-v1.json"),
                             "不能用空数组静默覆盖待恢复的原计划文件")
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testAppRejectsDuplicateCandidatePlanIDsWithoutReplacingOriginalFile() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-candidate-plan-duplicate-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            let now = Date().addingTimeInterval(-60)
            let first = NextCandidatePlan(kind: .gridBuy, code: "159941", name: "纳指ETF",
                limitPrice: 1.2, units: 100, createdAt: now, expiresAt: now.addingTimeInterval(3600),
                triggerNote: "回落触发", cancelNote: "突破区间", quoteSource: "test", quoteTime: now,
                dailyBarCount: 120, minuteSampleCount: 0, confidenceLevel: "medium",
                rationale: "test candidate", expectedNetGain: nil, expectedCostReduction: nil,
                riskNote: "价格波动", marketState: "震荡", cancelAbove: nil, cancelBelow: nil)
            let duplicate = first
            let original = try JSONEncoder().encode([first, duplicate])
            let url = directory.appendingPathComponent("candidate-plans-v1.json")
            try original.write(to: url, options: .atomic)

            let model = NextAppModel(repository: repository)
            XCTAssertTrue(model.candidatePlans.isEmpty, "重复候选计划ID不能让两条不同证券计划混淆")
            XCTAssertTrue(model.errorMessage?.contains("candidate-plans-v1.json") == true)
            XCTAssertNotNil(repository.save([NextCandidatePlan](), filename: "candidate-plans-v1.json"))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testFailedLedgerWriteDoesNotAdvanceTheInMemoryAccount() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ledger-write-failure-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            var preferences = LocalPreferences()
            preferences.watch = []
            XCTAssertNil(repository.save(preferences, filename: "preferences-v1.json"))
            let model = NextAppModel(repository: repository)
            let before = model.book
            try FileManager.default.removeItem(at: directory)
            var attempted = before
            attempted.cash += 1_000
            XCTAssertThrowsError(try model.commitRealLedger(attempted, action: "增加现金", reason: "测试写盘失败"))
            XCTAssertEqual(model.book, before, "本机落盘失败时内存账本必须保持原值")
        }
    }

    func testTenAppRestartsDoNotDuplicateLedgerLearningOrEraseManualReview() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ledger-restart-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            // Keep every restored fill inside the profile's observation window, while
            // ensuring neither fill is in the future when reconciliation runs.
            let stamp = Date().addingTimeInterval(-60)
            let memory = NextDecisionRecord(code: "563020", name: "红利ETF", createdAt: stamp,
                snapshot: NextDecisionSnapshot(state: "持有", strategy: "hold", headline: "继续持有", confidenceLevel: "medium"))
            let partialFillA = NextFill(date: stamp, code: "563020", side: "buy", units: 1_000,
                price: Decimal(string: "1.10")!, fee: 0.1, realized: 0, decisionMemoryID: memory.id)
            let partialFillB = NextFill(date: stamp.addingTimeInterval(20), code: "563020", side: "buy", units: 1_000,
                price: Decimal(string: "0.90")!, fee: 0.1, realized: 0, decisionMemoryID: memory.id)
            let income = NextIncomeEvent(kind: .etfDistribution, code: "563020", name: "已到账分红", exDate: stamp,
                payDate: stamp, units: 2_000, perUnit: Decimal(string: "0.05"), grossAmount: 100, tax: 0,
                status: .received, receivedAt: stamp)
            let book = NextBook(cash: 13_100,
                positions: [NextPosition(code: "563020", name: "红利ETF", units: 2_000, bookCost: 2_000, acquiredAt: stamp)],
                fills: [partialFillA, partialFillB],
                cashMovements: [NextCashMovement(date: stamp, amount: 5_000, reason: "用户手工入金")],
                incomeEvents: [income],
                dividendEvents: [NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: 0.05)],
                history: [NextAssetPoint(date: stamp, total: 15_100, externalFlow: 5_000)])
            let audited = NextAuditedBook(current: book)
            var profile = NextInvestorProfile()
            profile.summary.fillSampleCount = 2
            profile.updatedAt = stamp
            var preferences = LocalPreferences()
            preferences.watch = []
            XCTAssertNil(repository.save(audited, filename: "real-ledger-v1.json"))
            XCTAssertNil(repository.save(profile, filename: "investor-profile-v1.json"))
            XCTAssertNil(repository.save([memory], filename: "decision-memory-v1.json"))
            XCTAssertNil(repository.save(preferences, filename: "preferences-v1.json"))

            for restart in 0..<10 {
                let model = NextAppModel(repository: repository)
                XCTAssertEqual(model.ledger, audited)
                XCTAssertEqual(model.book.cash, Decimal(13_100))
                XCTAssertEqual(model.book.positions.first?.units, 2_000)
                XCTAssertEqual(model.book.fills.count, 2)
                XCTAssertEqual(model.book.fills.reduce(Decimal.zero) { $0 + $1.fee }, Decimal(string: "0.2"))
                XCTAssertEqual(model.book.incomeEvents.count, 1)
                XCTAssertEqual(model.book.cashMovements.count, 1)
                XCTAssertEqual(model.book.dividendEvents.count, 1)
                XCTAssertEqual(model.book.history.count, 1)

                if restart == 0 {
                    XCTAssertEqual(model.decisionMemory.first?.outcome, .filled)
                    XCTAssertEqual(model.decisionMemory.first?.review.filledUnits, 2_000)
                    XCTAssertEqual(model.decisionMemory.first?.review.filledPrice, "1.0000")
                    XCTAssertEqual(model.profile.summary.fillSampleCount, 2)
                    var reviewed = model.decisionMemory[0]
                    reviewed.review = NextDecisionReview(note: "人工复盘已完成", filledPrice: "1.0000",
                        filledUnits: 2_000, reviewedAt: stamp.addingTimeInterval(60))
                    model.decisionMemory = [reviewed]
                } else {
                    XCTAssertEqual(model.decisionMemory.first?.review.note, "人工复盘已完成")
                    XCTAssertEqual(model.profile.summary.fillSampleCount, 2,
                                   "重启不能重复增加画像成交样本或清除人工复盘")
                }
            }
        }
    }

    func testCashExampleStaysAt13100AfterTenRestarts() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Guanpan-ledger-cash-example-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = NextLocalRepository(directoryOverride: directory)
            var preferences = LocalPreferences()
            preferences.watch = []
            XCTAssertNil(repository.save(preferences, filename: "preferences-v1.json"))

            let model = NextAppModel(repository: repository)
            let stamp = Date()
            try model.addCash(10_000, reason: "测试初始现金")
            // 两笔 ETF 部分成交：每笔 999.90 元成交额 + 0.10 元手续费，合计扣款正好 2,000 元。
            try model.recordTrade(code: "563020", name: "红利ETF", side: "buy", units: 1_000,
                                  price: Decimal(string: "0.9999")!, fee: 0.1, at: stamp)
            try model.recordTrade(code: "563020", name: "红利ETF", side: "buy", units: 1_000,
                                  price: Decimal(string: "0.9999")!, fee: 0.1, at: stamp.addingTimeInterval(1))
            let distribution = NextIncomeEvent(kind: .etfDistribution, code: "563020", name: "红利ETF分红",
                exDate: stamp, payDate: stamp, units: 2_000, perUnit: Decimal(string: "0.05"),
                grossAmount: 100, tax: 0, status: .expected)
            try model.addIncomeEvent(distribution)
            try model.receiveIncomeEvent(distribution.id)
            try model.addCash(5_000, reason: "测试手工入金")

            let decision = NextDecisionRecord(code: "563020", name: "红利ETF", createdAt: stamp,
                snapshot: NextDecisionSnapshot(state: "持有", strategy: "hold", headline: "继续持有", confidenceLevel: "medium"))
            var reviewed = decision
            reviewed.review = NextDecisionReview(note: "人工复盘已完成", filledPrice: "0.9999",
                filledUnits: 2_000, reviewedAt: stamp.addingTimeInterval(60))
            model.decisionMemory = [reviewed]
            var profile = model.profile
            profile.summary.fillSampleCount = 2
            model.profile = profile

            var snapshot = model.book
            snapshot.history.append(NextAssetPoint(date: stamp, total: 15_100, externalFlow: 5_000))
            try model.commitRealLedger(snapshot, action: "测试记录资产快照", reason: "持久化恢复验收")
            XCTAssertEqual(model.book.cash, Decimal(13_100))

            for _ in 0..<10 {
                let restarted = NextAppModel(repository: NextLocalRepository(directoryOverride: directory))
                XCTAssertEqual(restarted.book.cash, Decimal(13_100), "10,000 - 2,000 + 100 + 5,000 应保持 13,100，不得按重启次数重复加分红")
                XCTAssertEqual(restarted.book.positions.first?.units, 2_000)
                XCTAssertEqual(restarted.book.fills.count, 2)
                XCTAssertEqual(restarted.book.cashMovements.count, 3, "两笔收支现金记录和分红到账记录必须保持固定数量")
                XCTAssertEqual(restarted.book.incomeEvents.count, 1)
                XCTAssertEqual(restarted.book.incomeEvents.first?.status, .received)
                XCTAssertEqual(restarted.book.dividendEvents.count, 1)
                XCTAssertEqual(restarted.book.history.count, 1)
                XCTAssertEqual(restarted.book.fills.reduce(0) { $0 + $1.units }, 2_000)
                XCTAssertEqual(restarted.book.fills.reduce(Decimal.zero) { $0 + $1.fee }, Decimal(string: "0.2"))
                XCTAssertEqual(restarted.book.fills.reduce(Decimal.zero) { $0 + $1.realized }, 0,
                               "分红到账和普通现金变动不能伪装成证券交易盈亏")
                XCTAssertEqual(restarted.book.fills.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.units) } / Decimal(2_000),
                               Decimal(string: "0.9999"))
                XCTAssertEqual(restarted.decisionMemory.first?.review.note, "人工复盘已完成")
                XCTAssertEqual(restarted.profile.summary.fillSampleCount, 2)
            }
        }
    }
}
