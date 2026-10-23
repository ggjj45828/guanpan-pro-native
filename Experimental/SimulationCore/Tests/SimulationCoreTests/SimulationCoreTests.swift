import XCTest
@testable import SimulationCore
final class SimulationCoreTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 100)
    func order(_ side: SimSide = .buy, limit: Decimal = 1) throws -> SimOrder {
        try SimOrder(symbol: "510300", asset: .etf, side: side, quantity: 100, limit: limit, submittedAt: time)
    }
    func book(_ ask: Decimal = 1, quantity: Int = 100) -> SimBook {
        SimBook(symbol: "510300", timestamp: time, bids: [.init(price: Decimal(string: "0.99")!, quantity: 100)], asks: [.init(price: ask, quantity: quantity)])
    }
    func testFeeAndVariableDeposits() throws {
        var a = SimAccount()
        try a.inject(id: UUID(), amount: 100)
        try a.inject(id: UUID(), amount: 50)
        let f = try XCTUnwrap(a.attempt(order(), book: book(), now: time))
        XCTAssertEqual(f.fee, Decimal(string: "0.10")!)
        XCTAssertEqual(a.cash, Decimal(string: "49.90")!)
        XCTAssertEqual(a.holdings["510300"], 100)
    }
    func testWaitAndInsufficientDepthLeaveAccountUntouched() throws {
        var a = SimAccount(); try a.inject(id: UUID(), amount: 200)
        XCTAssertNil(try a.attempt(order(), book: book(2), now: time))
        XCTAssertNil(try a.attempt(order(), book: book(1, quantity: 50), now: time))
        XCTAssertEqual(a.cash, 200); XCTAssertTrue(a.holdings.isEmpty)
    }
    func testDuplicateDepositAndExecutionRejected() throws {
        var a = SimAccount(); let id = UUID()
        try a.inject(id: id, amount: 200)
        XCTAssertThrowsError(try a.inject(id: id, amount: 200))
        let o = try order()
        _ = try a.attempt(o, book: book(), now: time)
        XCTAssertThrowsError(try a.attempt(o, book: book(), now: time))
    }
    func testNoOverspendOrShortSale() throws {
        var a = SimAccount(); try a.inject(id: UUID(), amount: 100)
        XCTAssertThrowsError(try a.attempt(order(), book: book(), now: time))
        XCTAssertThrowsError(try a.attempt(order(.sell, limit: Decimal(string: "0.99")!), book: book(), now: time))
        XCTAssertEqual(a.cash, 100); XCTAssertTrue(a.fills.isEmpty)
    }
    func testStaleAndSlippageCannotBypassLimit() throws {
        var a = SimAccount(); try a.inject(id: UUID(), amount: 200)
        XCTAssertThrowsError(try a.attempt(order(), book: book(), now: time.addingTimeInterval(6)))
        XCTAssertNil(try a.attempt(order(), book: book(), now: time, extraSlippage: Decimal(string: "0.01")!))
    }
}
