import XCTest
@testable import GuanpanProNative

final class CandidateValidationTests: XCTestCase {
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
