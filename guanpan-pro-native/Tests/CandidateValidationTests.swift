import XCTest
@testable import GuanpanProNative

final class CandidateValidationTests: XCTestCase {
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
    func testArchivePreservesUnknownFieldsAndOriginalBytes() async throws {
        let original = Data("{\"unknown-legacy\":{\"nested\":[1,2,3]},\"cash\":0}".utf8)
        let file = try HistoricalFundArchive.preserve(original)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try HistoricalFundArchive.preserve(original), file)
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
