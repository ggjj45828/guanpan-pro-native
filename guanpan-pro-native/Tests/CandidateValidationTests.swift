import XCTest
import CryptoKit
@testable import GuanpanProNative

final class CandidateValidationTests: XCTestCase {
    func testInvestorProfileNeedsSeveralRealTradesAndPreservesExplicitRule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var profile = DynamicInvestorProfile()
        profile.attributes = [InvestorProfileAttribute(
            id: "tradingFrequency", value: "我只做长期配置", confidence: 1,
            source: .explicit, sampleCount: 0, reason: "用户锁定",
            updatedAt: now, locked: true)]
        let oneSale = LedgerEntry(date: now, code: "159001", name: "真实ETF", side: .sell,
                                  quantity: 100_000, price: 1, fee: 0.1, realizedPnL: 0,
                                  linkedCash: true, kind: .etf)
        var learned = InvestorProfileEngine.refresh(profile, ledger: [oneSale],
                                                     decisions: [], snapshots: [], now: now)
        XCTAssertEqual(learned.attributes.first(where: { $0.id == "tradingFrequency" })?.value, "我只做长期配置")
        XCTAssertNil(learned.attributes.first(where: { $0.id == "typicalTicket" }))
        let trades = (0..<6).map { i in
            LedgerEntry(date: now.addingTimeInterval(-Double(i) * 86_400),
                        code: "159001", name: "真实ETF", side: .buy, quantity: 100,
                        price: 1, fee: 0.1, realizedPnL: 0, linkedCash: true, kind: .etf)
        }
        learned = InvestorProfileEngine.refresh(learned, ledger: trades + [oneSale],
                                                decisions: [], snapshots: [], now: now)
        XCTAssertEqual(learned.attributes.first(where: { $0.id == "tradingFrequency" })?.value, "我只做长期配置")
        XCTAssertEqual(learned.attributes.first(where: { $0.id == "typicalTicket" })?.value, "100元",
                       "A single exceptional sale must not set the typical ticket")
    }

    func testRejectedInvestorInferenceRequiresNewEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let trades = (0..<5).map { i in
            LedgerEntry(date: now.addingTimeInterval(-Double(i) * 86_400),
                        code: "159001", name: "真实ETF", side: .buy, quantity: 100,
                        price: 1, fee: 0.1, realizedPnL: 0, linkedCash: true, kind: .etf)
        }
        var profile = InvestorProfileEngine.refresh(DynamicInvestorProfile(), ledger: trades,
                                                    decisions: [], snapshots: [], now: now)
        XCTAssertNotNil(profile.attributes.first(where: { $0.id == "tradingFrequency" }))
        profile.rejectedEvidenceCounts["tradingFrequency"] = 5
        profile.attributes.removeAll { $0.id == "tradingFrequency" }
        let unchanged = InvestorProfileEngine.refresh(profile, ledger: trades,
                                                      decisions: [], snapshots: [], now: now)
        XCTAssertNil(unchanged.attributes.first(where: { $0.id == "tradingFrequency" }))
        let extra = LedgerEntry(date: now.addingTimeInterval(-5 * 86_400), code: "159001",
                                name: "真实ETF", side: .buy, quantity: 100, price: 1,
                                fee: 0.1, realizedPnL: 0, linkedCash: true, kind: .etf)
        let relearned = InvestorProfileEngine.refresh(unchanged, ledger: trades + [extra],
                                                      decisions: [], snapshots: [], now: now)
        XCTAssertNotNil(relearned.attributes.first(where: { $0.id == "tradingFrequency" }))
    }
    func testTemporaryPauseAndObservedStrategyRequireRealDecisionAndLedgerLinks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decisions = (0..<3).map { index in
            let created = now.addingTimeInterval(-Double(index) * 86_400)
            var decision = AdvisorDecisionRecord(createdAt: created,
                symbol: "159001", name: "真实ETF", action: "反T候选", reason: "样本",
                marketRegime: "宽幅震荡", quoteAt: now, dataSource: "测试样本",
                intradaySessions: 60, nasAvailable: true, changeReason: "")
            decision.evidenceSnapshotJSON = "{\"plan\":{\"type\":\"reverseT\",\"quantity\":100,\"sellLimitYuan\":1,\"validUntil\":\(Int(created.addingTimeInterval(3600).timeIntervalSince1970 * 1000))}}"
            return decision
        }
        let ledger = (0..<3).map { index in
            LedgerEntry(date: now.addingTimeInterval(-Double(index) * 86_400),
                code: "159001", name: "真实ETF", side: .sell, quantity: 100,
                price: 1, fee: 0.1, realizedPnL: 0, linkedCash: true, kind: .etf)
        }
        var profile = DynamicInvestorProfile()
        profile.feedback = [AdvisorFeedback(decisionID: decisions[0].id, symbol: "159001",
            kind: .notNow, createdAt: now)]
        profile.realTradeLinks = zip(decisions, ledger).map { pair in
            AdvisorRealTradeLink(decisionID: pair.0.id, ledgerID: pair.1.id)
        }
        let learned = InvestorProfileEngine.refresh(profile, ledger: ledger,
            decisions: decisions, snapshots: [], now: now)
        XCTAssertNotNil(learned.attributes.first { $0.id == "pause:159001" && $0.source == .temporary })
        XCTAssertEqual(learned.attributes.first { $0.id == "observedStrategyExecution" }?.sampleCount, 3)
        let revoked = InvestorProfileEngine.refresh(profile, ledger: [],
            decisions: decisions, snapshots: [], now: now.addingTimeInterval(2 * 86_400))
        XCTAssertNil(revoked.attributes.first { $0.id == "pause:159001" })
        XCTAssertNil(revoked.attributes.first { $0.id == "observedStrategyExecution" })
    }
    func testProfileDoesNotLearnPlanExecutionFromUncoveredBrokerFill() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var decision = AdvisorDecisionRecord(createdAt: now,
            symbol: "159001", name: "真实ETF", action: "反T候选", reason: "样本",
            marketRegime: "宽幅震荡", quoteAt: now, dataSource: "测试样本",
            intradaySessions: 60, nasAvailable: true, changeReason: "")
        decision.evidenceSnapshotJSON = "{\"plan\":{\"type\":\"reverseT\",\"quantity\":100,\"sellLimitYuan\":1.1,\"validUntil\":\(Int(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000))}}"
        let fill = LedgerEntry(date: now.addingTimeInterval(60), code: "159001", name: "真实ETF",
            side: .sell, quantity: 100, price: 1, fee: 0.1, realizedPnL: 0,
            linkedCash: true, kind: .etf)
        XCTAssertFalse(InvestorProfileEngine.tradeMatchesCandidate(fill, decision: decision))
        let earlier = LedgerEntry(date: now.addingTimeInterval(-1), code: "159001", name: "真实ETF",
            side: .sell, quantity: 100, price: 1.2, fee: 0.1, realizedPnL: 0,
            linkedCash: true, kind: .etf)
        XCTAssertFalse(InvestorProfileEngine.tradeMatchesCandidate(earlier, decision: decision))
        var profile = DynamicInvestorProfile()
        profile.realTradeLinks = [AdvisorRealTradeLink(decisionID: decision.id, ledgerID: fill.id)]
        let learned = InvestorProfileEngine.refresh(profile, ledger: [fill],
            decisions: [decision], snapshots: [], now: now.addingTimeInterval(120))
        XCTAssertNil(learned.attributes.first { $0.id == "observedStrategyExecution" })
    }
    func testOldAdvisorDecisionStillDecodesWithoutNewEvidenceFields() throws {
        let record = AdvisorDecisionRecord(symbol: "510300", name: "旧判断",
            action: "不交易", reason: "旧版", marketRegime: "证据不足",
            quoteAt: nil, dataSource: "旧版", intradaySessions: 0,
            nasAvailable: false, changeReason: "")
        let encoded = try JSONEncoder().encode(record)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dictionary.removeValue(forKey: "evidenceSnapshotJSON")
        dictionary.removeValue(forKey: "planIdentity")
        let legacy = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(AdvisorDecisionRecord.self, from: legacy)
        XCTAssertEqual(decoded.symbol, "510300")
        XCTAssertNil(decoded.evidenceSnapshotJSON)
        XCTAssertNil(decoded.planIdentity)
    }
    func testEyeCareThemeUsesARealLightPaletteAndDistinctMutedAccent() {
        let palette = AppTheme.palette(for: .eyeCare)
        XCTAssertTrue(palette.isLight)
        XCTAssertNotEqual(AppAppearance.eyeCare.accentColor, AppAppearance.light.accentColor)
        XCTAssertEqual(AppAppearance.eyeCare.colorScheme, .light)
        XCTAssertEqual(AppAppearance.eyeCare.title, "护眼暖绿")
    }
    func testNASAddressNormalizationKeepsProxyPrefixWithoutDuplicatingAPI() throws {
        XCTAssertEqual(try NASSyncService.endpoint(base: "http://nas.local:8788/api/native/data").absoluteString, "http://nas.local:8788/api/native/data")
        XCTAssertEqual(try NASSyncService.endpoint(base: "https://nas.example/proxy/api/data?ignored=1").absoluteString, "https://nas.example/proxy/api/native/data")
        XCTAssertThrowsError(try NASSyncService.endpoint(base: "http://user:secret@nas.example"))
    }
    func testOffExchangeCleanupPreservesCashMarketHoldingsAndUnknownFields() throws {
        let original = Data("{\"cash\":1234,\"holdings\":[{\"kind\":\"fund\",\"code\":\"001\"},{\"kind\":\"etf\",\"code\":\"159941\",\"quantity\":100}],\"ledger\":[{\"kind\":\"fund\"},{\"kind\":\"etf\"},{\"memo\":\"shared\"}],\"fundNAVHistory\":[1],\"unknown\":{\"keep\":true},\"cashFlows\":[1]}".utf8)
        let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        XCTAssertThrowsError(try HistoricalFundArchive.removingOffExchange(original))
        let cleaned = try HistoricalFundArchive.removingOffExchange(original, userConfirmedArchive: true, archiveRoot: archiveRoot)
        let obj = try JSONSerialization.jsonObject(with: cleaned) as! [String: Any]
        XCTAssertEqual(obj["cash"] as? Int, 1234)
        XCTAssertEqual((obj["holdings"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((obj["ledger"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(obj["cashFlows"] as? [Int], [1])
        XCTAssertEqual((obj["unknown"] as? [String: Bool])?["keep"], true)
        XCTAssertTrue((obj["fundNAVHistory"] as? [Int])?.isEmpty == true)
    }
    func testOffExchangeExportMustBeCompleteAndVerifiedBeforeLocalDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("original fund snapshot".utf8).write(to: recovery.appendingPathComponent("undo.json"))
        _ = try HistoricalFundArchive.archiveBytes(Data("ledger bytes".utf8), label: "ledger", at: archive)
        _ = try HistoricalFundArchive.archiveBytes(Data("undo bytes".utf8), label: "undo", at: archive)
        let exported = try HistoricalFundArchive.makeExportBundle(at: archive)
        XCTAssertTrue(HistoricalFundArchive.verifyExportBundle(exported, archiveRoot: archive))
        var incomplete = exported; incomplete.append(Data("tamper".utf8))
        XCTAssertFalse(HistoricalFundArchive.verifyExportBundle(incomplete, archiveRoot: archive))
        XCTAssertThrowsError(try HistoricalFundArchive.deleteLocalArchivesAfterVerifiedExport(incomplete, archiveRoot: archive, recoveryRoot: recovery))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        try HistoricalFundArchive.deleteLocalArchivesAfterVerifiedExport(exported, archiveRoot: archive, recoveryRoot: recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }
    @MainActor func testConfirmedOffExchangeScrubPreservesUnrelatedPortfolioFacts() {
        var source = PortfolioData()
        source.cash = 1_234
        source.holdings = [
            Holding(code: "001234", name: "synthetic fund", quantity: 5, cost: 2, current: 2.1, kind: .fund),
            Holding(code: "159941", name: "synthetic ETF", quantity: 100, cost: 1, current: 1.1, kind: .etf)
        ]
        source.fundNAVHistory = [FundNAVPoint(code: "001234", date: "2026-01-01", nav: 2)]
        source.ledger = [
            LedgerEntry(code: "001234", name: "legacy fund trade", side: .buy, quantity: 5, price: 2,
                        fee: 0, realizedPnL: 0, linkedCash: true),
            LedgerEntry(code: "159941", name: "ETF trade", side: .buy, quantity: 100, price: 1,
                        fee: 0, realizedPnL: 0, linkedCash: true, kind: .etf)
        ]
        source.allocationTargets = [
            AllocationTarget(code: "001234", name: "synthetic fund", kind: .fund, targetPercent: 20),
            AllocationTarget(code: "159941", name: "synthetic ETF", kind: .etf, targetPercent: 80)
        ]
        source.fundTransactions = [FundTransaction(code: "001234", name: "synthetic fund", side: .buy,
            requestDate: "2026-01-01", effectiveDate: "2026-01-02", quantity: 5, nav: 2,
            amount: 10, fee: 0, realizedPnL: 0, status: .confirmed, isBackfill: false,
            dividendMode: nil, linkedCash: true)]
        source.cashFlows = [CashFlow(amount: 50, memo: "shared contribution")]
        source.savedAccountAIAnalysis = SavedAIAnalysis(text: "synthetic combined account report")
        source.savedInstrumentAIAnalyses = [
            "001234": SavedAIAnalysis(text: "synthetic fund report"),
            "159941": SavedAIAnalysis(text: "synthetic ETF report")
        ]
        let clean = PortfolioStore.withoutOffExchangeHistory(source)
        XCTAssertEqual(clean.cash, 1_234)
        XCTAssertEqual(clean.holdings.map(\.code), ["159941"])
        XCTAssertTrue(clean.fundNAVHistory.isEmpty)
        XCTAssertTrue(clean.fundTransactions.isEmpty)
        XCTAssertEqual(clean.ledger.map(\.code), ["159941"], "legacy untyped fund rows should be removed by known fund code")
        XCTAssertEqual(clean.allocationTargets.map(\.code), ["159941"])
        XCTAssertEqual(clean.cashFlows.map(\.memo), ["shared contribution"])
        XCTAssertNil(clean.savedAccountAIAnalysis)
        XCTAssertNil(clean.savedInstrumentAIAnalyses["001234"])
        XCTAssertNotNil(clean.savedInstrumentAIAnalyses["159941"])
        XCTAssertEqual(source.holdings.count, 2, "cleanup must operate on a copy")
    }
    @MainActor func testConversationRestoresScopesAndDoesNotOverwriteAnotherView() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("chat.json")
        let first = ResearchConversationStore(file: file), second = ResearchConversationStore(file: file)
        first.append("real one", scope: "real")
        second.append("virtual one", scope: "virtual:lab")
        first.append("real two", scope: "real")
        let restored = ResearchConversationStore(file: file)
        XCTAssertEqual(restored.histories["real"], ["real one", "real two"])
        XCTAssertEqual(restored.histories["virtual:lab"], ["virtual one"])
    }
    @MainActor func testCorruptConversationCannotBeOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("corrupt fixture".utf8); try bytes.write(to: file)
        let store = ResearchConversationStore(file: file); store.append("new", scope: "real")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(store.errorMessage.isEmpty)
    }
    @MainActor func testRealResearchUsesCurrentPortfolioInsteadOfOldVirtualSnapshot() async throws {
        let store = PortfolioStore(); store.data = PortfolioData(); store.data.cash = 1234
        let input = try ResearchInputBuilder.make(portfolio: store, channels: LabChannelCoordinator(), at: 1_792_375_200_000)
        XCTAssertEqual((input["realPortfolio"] as? [String: Any])?["cash"] as? Double, 1234)
        XCTAssertEqual(((input["realPortfolio"] as? [String: Any])?["holdings"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(input["accounts"])
        XCTAssertNil(input["virtualPortfolio"])
        XCTAssertEqual(store.data.cash, 1234)
    }
    @MainActor func testResearchInputCarriesOnlyVerifiedRulesAndCurrentProfileState() async throws {
        let store = PortfolioStore(); store.data = PortfolioData(); store.data.cash = 2000
        let now = Date.now
        store.data.holdings = [Holding(code: "510300", name: "真实ETF", quantity: 1000,
            cost: 1, current: 1.1, kind: .etf, marketUpdatedAt: now)]
        store.data.etfTradeRules = [ETFTradeRule(symbol: "510300", settlement: .nextDay,
            lotSize: 100, tickYuan: 0.001, feePerFillYuan: 0.1,
            confirmedAt: now, confirmationSource: "券商回报", brokerSellableShares: 800,
            sellableCheckedAt: now)]
        store.data.dynamicInvestorProfile.holdingRules = [HoldingProfileRule(symbol: "510300", role: .tactical)]
        store.data.dynamicInvestorProfile.attributes = [InvestorProfileAttribute(id: "pause:510300",
            value: "暂不主动交易", confidence: 1, source: .temporary, sampleCount: 1,
            reason: "用户反馈", updatedAt: now, locked: false)]
        let input = try ResearchInputBuilder.make(portfolio: store,
            channels: LabChannelCoordinator(), at: Int64(now.timeIntervalSince1970 * 1000) + 1000)
        let real = try XCTUnwrap(input["realPortfolio"] as? [String: Any])
        let rules = try XCTUnwrap(real["verifiedTradingRules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["brokerSellableShares"] as? Double, 800)
        let roles = try XCTUnwrap(real["holdingRoles"] as? [[String: String]])
        XCTAssertEqual(roles.first?["role"], "tactical")
        XCTAssertEqual((input["profileState"] as? [String: Any])?["temporaryPauses"] as? [String], ["510300"])
    }
    @MainActor func testOlderNASQuoteCannotOverwriteNewerLocalQuote() async throws {
        let store = PortfolioStore(); store.data = PortfolioData()
        let now = Date()
        store.data.holdings = [Holding(code: "159941", name: "fixture", quantity: 100, cost: 1, current: 1.5, kind: .etf, marketUpdatedAt: now.addingTimeInterval(-60))]
        store.data.quotes = [Quote(code: "159941", name: "fixture", price: 1.6, changePct: 0, updatedAt: now)]
        store.applyV2MarketDocument(["quotes": [["symbol": "159941", "price": 12_000, "at": now.addingTimeInterval(-30).timeIntervalSince1970 * 1000]]])
        XCTAssertEqual(store.data.quotes[0].price, 1.6)
        XCTAssertEqual(store.data.holdings[0].current, 1.5)
        XCTAssertEqual(store.data.holdings[0].quantity, 100)
        store.applyV2MarketDocument(["quotes": [["symbol": "159941", "price": 12_000,
            "previousClose": 10_000, "at": now.timeIntervalSince1970 * 1000]]])
        XCTAssertEqual(store.data.quotes[0].price, 1.6, "同一时间戳的较低优先级来源不覆盖本机价格")
    }
    @MainActor func testNASMinuteVolumeNeedsConfirmedShareUnits() async throws {
        let store = PortfolioStore(); store.data = PortfolioData()
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000
        store.applyV2MarketDocument(["intraday": [["symbol": "159941", "at": timestamp,
            "price": 10_000, "volume": 300, "volumeUnit": "shares"]]])
        XCTAssertEqual(store.intradayBars.last?.volume, 300)
        store.applyV2MarketDocument(["intraday": [["symbol": "159942", "at": timestamp,
            "price": 10_000, "volume": 999]]])
        XCTAssertNil(store.intradayBars.first { $0.code == "159942" }?.volume)
    }
    @MainActor func testFreshLocalResearchQuoteKeepsNASFundamentalsAndBars() async throws {
        let old: [String: Any] = ["symbol": "159941", "quote": ["at": 10, "price": 10000], "fundamentals": ["publishedAt": 1], "bars": [["at": 5, "availableAt": 6, "close": 9000]]]
        let local: [String: Any] = ["symbol": "159941", "quote": ["at": 20, "price": 11000], "bars": [["at": 5, "availableAt": 30, "close": 8000]]]
        let merged = ResearchInputBuilder.merge(remote: ["instruments": [old]], local: [local], at: 30)
        let row = try XCTUnwrap((merged["instruments"] as? [[String: Any]])?.first)
        XCTAssertEqual((row["quote"] as? [String: Any])?["price"] as? Int, 11000)
        XCTAssertNotNil(row["fundamentals"])
        XCTAssertEqual((row["bars"] as? [[String: Any]])?.first?["close"] as? Int, 9000)
        XCTAssertEqual(merged["universeComplete"] as? Bool, false)
    }
    @MainActor func testFutureAllocationDoesNotCreateRealHoldingAndTotalCannotExceed100() async throws {
        let store = PortfolioStore(); store.data = PortfolioData(); store.data.cash = 0
        let first = Holding(code: "159941", name: "future", quantity: 0, cost: 0, current: 0, kind: .etf)
        try store.saveAllocationTarget(for: first, percent: 60)
        let second = Holding(code: "510300", name: "future two", quantity: 0, cost: 0, current: 0, kind: .etf)
        XCTAssertThrowsError(try store.saveAllocationTarget(for: second, percent: 50))
        XCTAssertTrue(store.data.holdings.isEmpty); XCTAssertEqual(store.data.cash, 0)
        XCTAssertEqual(store.data.allocationTargets.count, 1)
    }
    @MainActor func testAppleJavaScriptCoreLoadsAllBundledModules() async throws {
        let runtime = PhoneResearchEngine()
        let native: [String: Any] = ["cash": 100.01, "holdings": [], "ledger": [], "cashFlows": []]
        let projected = try runtime.call("assets.project", [native, 1]) as? [String: Any]
        XCTAssertEqual((projected?["cash"] as? NSNumber)?.intValue, 1_000_100)
        let radar = try runtime.call("research.radar", [["asOf": 1, "instruments": []], 1]) as? [String: Any]
        XCTAssertEqual((radar?["ranked"] as? [Any])?.count, 0)
    }
    @MainActor func testETFBacktestCannotDoubleCashWhenNoLotAffordable() async throws {
        let rows = (1...25).map { n in
            DailyBar(code: "510300", date: String(format: "2026-09-%02d", n), open: 1_000_000,
                     close: 1_000_000, high: 1_000_000, low: 1_000_000, volume: 0)
        }
        let result = try XCTUnwrap(StrategyBacktest.run(bars: rows, initialCash: 100, feeRate: 0))
        XCTAssertEqual(result.holdValue, 100, accuracy: 0.00001)
        XCTAssertEqual(result.strategyValue, 100, accuracy: 0.00001)
    }
    func testOffExchangeRecoveryFolderRequiresVerifiedArchiveAndUserConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("GuanpanReadOnlyHistory-v1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("off exchange history".utf8).write(to: folder.appendingPathComponent("old.json"))
        let sibling = root.appendingPathComponent("etf-market-cache.json")
        try Data("preserve".utf8).write(to: sibling)
        XCTAssertThrowsError(try HistoricalFundArchive.purgeArtifacts(at: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("old.json")), Data("off exchange history".utf8))
        try HistoricalFundArchive.archiveLegacyArtifacts(at: folder, into: root.appendingPathComponent("verified-archive"))
        let archived = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("verified-archive"), includingPropertiesForKeys: nil)?.allObjects as? [URL]).first
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(archived)), Data("off exchange history".utf8))
        try HistoricalFundArchive.purgeArtifacts(at: folder, userConfirmedArchive: true, archiveRoot: root.appendingPathComponent("verified-archive"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("preserve".utf8))
    }
    @MainActor func testLoadingArchivesOffExchangeDataAndPreservesEverySourceUntilConfirmation() async throws {
        let defaults = UserDefaults.standard
        let mainKey = "guanpan.pro.native.portfolio.v1"
        let undoKey = "guanpan.pro.native.portfolio.undo.v1"
        let auditKey = "guanpan.pro.native.portfolio.audit.v1"
        let oldMain = defaults.object(forKey: mainKey), oldUndo = defaults.object(forKey: undoKey), oldAudit = defaults.object(forKey: auditKey)
        let recoveryName = "synthetic-recovery-\(UUID().uuidString).json"
        var syntheticArchiveFiles: [URL] = []
        defer {
            if let oldMain { defaults.set(oldMain, forKey: mainKey) } else { defaults.removeObject(forKey: mainKey) }
            if let oldUndo { defaults.set(oldUndo, forKey: undoKey) } else { defaults.removeObject(forKey: undoKey) }
            if let oldAudit { defaults.set(oldAudit, forKey: auditKey) } else { defaults.removeObject(forKey: auditKey) }
            for url in syntheticArchiveFiles { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: HistoricalFundArchive.directory.appendingPathComponent(recoveryName))
        }
        var before = PortfolioData(); before.cash = 100
        before.holdings = [
            Holding(code: "000001", name: "synthetic fund", quantity: 10, cost: 1, current: 1, kind: .fund),
            Holding(code: "159941", name: "synthetic ETF", quantity: 100, cost: 1, current: 1.1, kind: .etf)
        ]
        before.fundNAVHistory = [FundNAVPoint(code: "000001", date: "2026-01-01", nav: 1)]
        before.cashFlows = [CashFlow(amount: 50, memo: "shared contribution")]
        let bytes = try JSONEncoder().encode(before)
        defaults.set(bytes, forKey: mainKey); defaults.set(bytes, forKey: undoKey)
        let auditBytes = try JSONEncoder().encode([OperationAuditRecord(label: "synthetic prior state", state: bytes)])
        defaults.set(auditBytes, forKey: auditKey)
        try FileManager.default.createDirectory(at: HistoricalFundArchive.directory, withIntermediateDirectories: true)
        try bytes.write(to: HistoricalFundArchive.directory.appendingPathComponent(recoveryName))

        func archiveURL(label: String, bytes: Data) -> URL {
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return HistoricalFundArchive.permanentArchiveDirectory.appendingPathComponent("\(label)-\(hash).archive")
        }
        syntheticArchiveFiles = [archiveURL(label: "persisted-ledger", bytes: bytes),
                                 archiveURL(label: "undo-snapshot", bytes: bytes)]
        syntheticArchiveFiles.append(archiveURL(label: "operation-audit", bytes: auditBytes))
        let recoveryArchiveBytes = try Data(contentsOf: HistoricalFundArchive.directory.appendingPathComponent(recoveryName))
        let recoveryHash = SHA256.hash(data: recoveryArchiveBytes).map { String(format: "%02x", $0) }.joined()
        let legacyLabel = String(("legacy-" + recoveryName).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(60))
        syntheticArchiveFiles.append(HistoricalFundArchive.permanentArchiveDirectory.appendingPathComponent("\(legacyLabel)-\(recoveryHash).archive"))

        let store = PortfolioStore()
        XCTAssertEqual(store.data.holdings.map(\.code), ["000001", "159941"])
        XCTAssertEqual(store.data.cash, 100)
        XCTAssertEqual(store.data.cashFlows.first?.memo, "shared contribution")
        XCTAssertEqual(store.data.fundNAVHistory.count, 1)
        XCTAssertEqual(defaults.data(forKey: mainKey), bytes)
        XCTAssertEqual(defaults.data(forKey: undoKey), bytes)
        XCTAssertTrue(HistoricalFundArchive.hasHistory(try JSONDecoder().decode(PortfolioData.self, from: XCTUnwrap(defaults.data(forKey: undoKey)))))
        XCTAssertTrue(HistoricalFundArchive.hasHistory(try JSONDecoder().decode(PortfolioData.self, from: XCTUnwrap(store.operationAudit.first).state)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: HistoricalFundArchive.directory.appendingPathComponent(recoveryName).path))
        for url in syntheticArchiveFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing verified archive \(url.lastPathComponent)")
        }
        XCTAssertEqual(try Data(contentsOf: syntheticArchiveFiles[0]), bytes)
    }
    @MainActor func testOffExchangeBusinessCannotExecuteOrMutateSyntheticLedger() async throws {
        let store = PortfolioStore()
        store.data = PortfolioData()
        store.data.cash = 100
        store.data.holdings = [Holding(code: "000001", name: "synthetic archived fund", quantity: 10, cost: 1, current: 1, kind: .fund)]
        let before = try JSONEncoder().encode(store.data)
        XCTAssertEqual(store.processAutomaticDCA(), 0)
        XCTAssertThrowsError(try store.recordTrade(code: "000001", kind: .fund, side: .buy,
                                                 quantity: 10, price: 1, fee: 0, linkedCash: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        XCTAssertTrue(originalObject.isEqual(try JSONSerialization.jsonObject(with: encoder.encode(store.data))))
    }
    @MainActor func testMarketChannelDoesNotChangeAssetFacts() async throws {
        let store = PortfolioStore(); store.data = PortfolioData(); store.data.cash = 100
        store.data.holdings = [Holding(code: "510300", name: "fixture", quantity: 100, cost: 1, current: 1, kind: .etf)]
        let now = Date().timeIntervalSince1970 * 1000
        store.applyV2MarketDocument(["quotes": [["symbol": "510300", "price": 12_000, "previousClose": 10_000, "at": now]]])
        XCTAssertEqual(store.data.cash, 100)
        XCTAssertEqual(store.data.holdings[0].quantity, 100)
        XCTAssertEqual(store.data.holdings[0].cost, 1)
        XCTAssertEqual(store.data.holdings[0].current, 1.2)
        XCTAssertTrue(store.data.ledger.isEmpty)
    }
    @MainActor func testConfirmedAdvisorFillChangesRealAccountAndUndoClearsLink() async throws {
        let store = PortfolioStore(); store.data = PortfolioData(); store.data.cash = 1000
        store.data.holdings = [Holding(code: "510300", name: "真实ETF", quantity: 1000,
            cost: 1, current: 1.1, kind: .etf)]
        let decision = AdvisorDecisionRecord(symbol: "510300", name: "真实ETF",
            action: "反T候选", reason: "仅测试真实流水", marketRegime: "宽幅震荡",
            quoteAt: .now, dataSource: "fixture", intradaySessions: 60,
            nasAvailable: true, changeReason: "")
        store.data.advisorDecisionRecords = [decision]
        try store.recordTrade(code: "510300", kind: .etf, side: .sell,
            quantity: 100, price: 1.2, fee: 0.1, linkedCash: true,
            advisorDecisionID: decision.id)
        XCTAssertEqual(store.data.holdings[0].quantity, 900)
        XCTAssertEqual(store.data.cash, 1119.9, accuracy: 0.000001)
        XCTAssertEqual(store.data.dynamicInvestorProfile.realTradeLinks.count, 1)
        try store.undoLatestTrade()
        XCTAssertEqual(store.data.holdings[0].quantity, 1000)
        XCTAssertEqual(store.data.cash, 1000, accuracy: 0.000001)
        XCTAssertTrue(store.data.dynamicInvestorProfile.realTradeLinks.isEmpty)
        XCTAssertTrue(store.data.ledger.isEmpty)
    }

    func testDecisionTradeReviewMatchesPartialFillsChronologicallyAndAllocatesFees() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            LedgerEntry(date: start, code: "510300", name: "真实ETF", side: .buy,
                        quantity: 100, price: 1, fee: 0.1, realizedPnL: 0,
                        linkedCash: true, kind: .etf),
            LedgerEntry(date: start.addingTimeInterval(60), code: "510300", name: "真实ETF", side: .sell,
                        quantity: 50, price: 1.1, fee: 0.1, realizedPnL: 0,
                        linkedCash: true, kind: .etf),
            LedgerEntry(date: start.addingTimeInterval(120), code: "510300", name: "真实ETF", side: .buy,
                        quantity: 100, price: 0.9, fee: 0.1, realizedPnL: 0,
                        linkedCash: true, kind: .etf),
            LedgerEntry(date: start.addingTimeInterval(180), code: "510300", name: "真实ETF", side: .sell,
                        quantity: 100, price: 1.2, fee: 0.1, realizedPnL: 0,
                        linkedCash: true, kind: .etf)
        ]
        let result = InvestorProfileEngine.matchedDecisionTrades(entries)
        XCTAssertEqual(result?.quantity ?? .nan, 150, accuracy: 0.000001)
        XCTAssertEqual(result?.net ?? .nan, 29.65, accuracy: 0.000001)
    }
}
