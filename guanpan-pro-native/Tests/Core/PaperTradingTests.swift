import XCTest
@testable import GuanpanResearchCore

final class PaperTradingTests: XCTestCase {
    private let t = ISO8601DateFormatter().date(from: "2026-10-19T02:00:00Z")!
    private func buy(_ a: inout PaperAccount, at time: Date? = nil) {
        XCTAssertTrue(a.place(code: "159941", limit: 1.5, quantity: 100, now: time ?? t, expires: t.addingTimeInterval(3600)))
    }
    func testFeeAndReservation() {
        var a = PaperAccount(); buy(&a)
        XCTAssertEqual(a.cash, 10000)
        XCTAssertEqual(a.availableCash, 9849.9, accuracy: 0.000001)
    }
    func testOvercommittedOrdersRejected() {
        var a = PaperAccount(cash: 200); buy(&a)
        XCTAssertFalse(a.place(code: "159941", limit: 1.5, quantity: 100, now: t, expires: t.addingTimeInterval(600)))
    }
    func testInvalidLotAndPriceRejected() {
        var a = PaperAccount()
        for p in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(a.place(code: "159941", limit: p, quantity: 100, now: t, expires: t.addingTimeInterval(600)))
        }
        XCTAssertFalse(a.place(code: "159941", limit: 1.5, quantity: 99, now: t, expires: t.addingTimeInterval(600)))
        XCTAssertFalse(a.place(code: "600000", limit: 1.5, quantity: 100, now: t, expires: t.addingTimeInterval(600)))
    }
    func testObservedFillAndNoDuplicateFill() {
        var a = PaperAccount(); buy(&a)
        let observed = t.addingTimeInterval(60)
        a.observe(code: "159941", price: 1.4, timestamp: observed, now: observed)
        XCTAssertEqual(a.orders.first?.status, .filled)
        XCTAssertEqual(a.cash, 9849.9, accuracy: 0.000001)
        XCTAssertEqual(a.positions.first?.quantity, 100)
        XCTAssertEqual(a.positions.first?.bookCost ?? 0, 150.1, accuracy: 0.000001)
        let copy = a
        a.observe(code: "159941", price: 1.4, timestamp: observed, now: observed)
        XCTAssertEqual(a, copy)
    }
    func testStaleFutureAndPreOrderQuotesDoNotFill() {
        var a = PaperAccount(); buy(&a)
        for timestamp in [t.addingTimeInterval(-30), t, t.addingTimeInterval(301)] {
            a.observe(code: "159941", price: 1.4, timestamp: timestamp, now: t.addingTimeInterval(300))
            XCTAssertEqual(a.orders.first?.status, .waiting)
        }
    }
    func testNonTouchAndWrongCodeDoNotFill() {
        var a = PaperAccount(); buy(&a)
        a.observe(code: "159941", price: 1.6, timestamp: t.addingTimeInterval(1), now: t.addingTimeInterval(1))
        a.observe(code: "563020", price: 1.0, timestamp: t.addingTimeInterval(1), now: t.addingTimeInterval(1))
        XCTAssertEqual(a.orders.first?.status, .waiting)
    }
    func testCancelAndExpireReleaseReservation() {
        var a = PaperAccount(); buy(&a)
        a.cancel(id: a.orders[0].id)
        XCTAssertEqual(a.availableCash, 10000)
        buy(&a)
        a.expire(at: t.addingTimeInterval(3600))
        XCTAssertEqual(a.orders.last?.status, .expired)
        XCTAssertEqual(a.availableCash, 10000)
    }
    func testExpiredOrderNeverFills() {
        var a = PaperAccount(); buy(&a)
        let now = t.addingTimeInterval(3600)
        a.observe(code: "159941", price: 1.4, timestamp: now, now: now)
        XCTAssertEqual(a.cash, 10000)
        XCTAssertTrue(a.positions.isEmpty)
    }
    func testSessionAndLunchBoundaries() {
        let f = ISO8601DateFormatter()
        XCTAssertFalse(PaperAccount.isTradingTime(f.date(from: "2026-10-18T02:00:00Z")!))
        XCTAssertFalse(PaperAccount.isTradingTime(f.date(from: "2026-10-19T04:00:00Z")!))
        XCTAssertTrue(PaperAccount.isTradingTime(t))
    }
    func testIndependentRoundTripAndCorruptionGuard() throws {
        var a = PaperAccount(); buy(&a)
        let b = try JSONDecoder().decode(PaperAccount.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b); XCTAssertTrue(b.isValid)
        a.cash = -1
        XCTAssertFalse(a.isValid)
    }
    func testCostInsideDomainDoesNotRescale() {
        XCTAssertEqual(CostOverlayDomain.including(1.5, in: 1...2), 1...2)
    }
    func testOutlyingCostIsVisible() {
        let lower = CostOverlayDomain.including(0.5, in: 1...2)
        let upper = CostOverlayDomain.including(3, in: 1...2)
        XCTAssertLessThan(lower.lowerBound, 0.5)
        XCTAssertGreaterThan(upper.upperBound, 3)
    }
    func testInvalidCostLeavesOriginalDomain() {
        for cost in [Double.nan, Double.infinity, 0, -1] {
            XCTAssertEqual(CostOverlayDomain.including(cost, in: 1...2), 1...2)
        }
        XCTAssertEqual(CostOverlayDomain.including(nil, in: 1...2), 1...2)
    }
}
