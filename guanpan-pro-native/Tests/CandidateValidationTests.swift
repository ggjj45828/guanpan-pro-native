import XCTest
@testable import GuanpanProNative

final class CandidateValidationTests: XCTestCase {
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
        let cleaned = try HistoricalFundArchive.removingOffExchange(original)
        let obj = try JSONSerialization.jsonObject(with: cleaned) as! [String: Any]
        XCTAssertEqual(obj["cash"] as? Int, 1234)
        XCTAssertEqual((obj["holdings"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((obj["ledger"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(obj["cashFlows"] as? [Int], [1])
        XCTAssertEqual((obj["unknown"] as? [String: Bool])?["keep"], true)
        XCTAssertTrue((obj["fundNAVHistory"] as? [Int])?.isEmpty == true)
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
        let lab = InvestmentLabStore(), channels = LabChannelCoordinator()
        let input = try ResearchInputBuilder.make(portfolio: store, lab: lab, channels: channels, at: 1_792_375_200_000, useVirtual: false)
        XCTAssertEqual((input.state["seed"] as? [String: Any])?["cash"] as? Int, 12_340_000)
        XCTAssertEqual(input.state["researchOnly"] as? Bool, true)
        XCTAssertEqual(store.data.cash, 1234)
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
        let runtime = InvestmentLabStore()
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
    func testOffExchangeRecoveryFolderIsDeletedWithoutTouchingSiblingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("GuanpanReadOnlyHistory-v1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("off exchange history".utf8).write(to: folder.appendingPathComponent("old.json"))
        let sibling = root.appendingPathComponent("etf-market-cache.json")
        try Data("preserve".utf8).write(to: sibling)
        try HistoricalFundArchive.purgeArtifacts(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("preserve".utf8))
    }
    @MainActor func testLoadingPurgesOffExchangeDataFromLedgerUndoAndRecoveryCopies() async throws {
        let defaults = UserDefaults.standard
        let mainKey = "guanpan.pro.native.portfolio.v1"
        let undoKey = "guanpan.pro.native.portfolio.undo.v1"
        let auditKey = "guanpan.pro.native.portfolio.audit.v1"
        let oldMain = defaults.object(forKey: mainKey), oldUndo = defaults.object(forKey: undoKey), oldAudit = defaults.object(forKey: auditKey)
        defer {
            if let oldMain { defaults.set(oldMain, forKey: mainKey) } else { defaults.removeObject(forKey: mainKey) }
            if let oldUndo { defaults.set(oldUndo, forKey: undoKey) } else { defaults.removeObject(forKey: undoKey) }
            if let oldAudit { defaults.set(oldAudit, forKey: auditKey) } else { defaults.removeObject(forKey: auditKey) }
            try? HistoricalFundArchive.purgeArtifacts()
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
        defaults.set(try JSONEncoder().encode([OperationAuditRecord(label: "synthetic prior state", state: bytes)]), forKey: auditKey)
        try FileManager.default.createDirectory(at: HistoricalFundArchive.directory, withIntermediateDirectories: true)
        try bytes.write(to: HistoricalFundArchive.directory.appendingPathComponent("synthetic-recovery.json"))

        let store = PortfolioStore()
        XCTAssertEqual(store.data.holdings.map(\.code), ["159941"])
        XCTAssertEqual(store.data.cash, 100)
        XCTAssertEqual(store.data.cashFlows.first?.memo, "shared contribution")
        XCTAssertTrue(store.data.fundNAVHistory.isEmpty)
        let cleanedUndo = try JSONDecoder().decode(PortfolioData.self, from: XCTUnwrap(defaults.data(forKey: undoKey)))
        XCTAssertFalse(HistoricalFundArchive.hasHistory(cleanedUndo))
        XCTAssertFalse(HistoricalFundArchive.hasHistory(try JSONDecoder().decode(PortfolioData.self, from: XCTUnwrap(store.operationAudit.first).state)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoricalFundArchive.directory.path))
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
}
