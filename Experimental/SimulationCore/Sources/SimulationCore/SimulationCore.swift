import Foundation

// Experimental simulation only. No PortfolioStore, network, broker or disk access.
public enum SimAsset: String { case etf, stock }
public enum SimSide { case buy, sell }
public enum SimError: Error { case invalid, duplicate, insufficientCash, insufficientShares, staleBook }
public struct SimOrder {
    public let id: UUID
    public let symbol: String
    public let asset: SimAsset
    public let side: SimSide
    public let quantity: Int
    public let limit: Decimal
    public let submittedAt: Date
    public init(id: UUID = UUID(), symbol: String, asset: SimAsset, side: SimSide,
                quantity: Int, limit: Decimal, submittedAt: Date) throws {
        guard !symbol.isEmpty, quantity > 0, quantity % 100 == 0,
              !limit.isNaN, limit > 0 else { throw SimError.invalid }
        self.id = id; self.symbol = symbol; self.asset = asset; self.side = side
        self.quantity = quantity; self.limit = limit; self.submittedAt = submittedAt
    }
}
public struct SimLevel {
    public let price: Decimal
    public let quantity: Int
    public init(price: Decimal, quantity: Int) { self.price = price; self.quantity = quantity }
}
public struct SimBook {
    public let symbol: String
    public let timestamp: Date
    public let bids: [SimLevel]
    public let asks: [SimLevel]
    public init(symbol: String, timestamp: Date, bids: [SimLevel], asks: [SimLevel]) {
        self.symbol = symbol; self.timestamp = timestamp; self.bids = bids; self.asks = asks
    }
}
public struct SimFill {
    public let orderID: UUID
    public let gross: Decimal
    public let fee: Decimal
    public let quantity: Int
}
public struct SimAccount {
    public let id = UUID()
    public private(set) var cash: Decimal = 0
    public private(set) var holdings: [String: Int] = [:]
    public private(set) var deposits: [UUID: Decimal] = [:]
    public private(set) var fills: [UUID: SimFill] = [:]
    public init() {}
    public mutating func inject(id: UUID, amount: Decimal) throws {
        guard !amount.isNaN, amount > 0 else { throw SimError.invalid }
        guard deposits[id] == nil else { throw SimError.duplicate }
        cash += amount; deposits[id] = amount
    }
    // Full fill only: insufficient depth remains waiting. A touch/last trade never implies a fill.
    // Caller supplies a NEW snapshot for each attempt; no queue position or liquidity replay claim.
    public mutating func attempt(_ order: SimOrder, book: SimBook, now: Date,
                                 stockFee: Decimal? = nil, extraSlippage: Decimal = 0) throws -> SimFill? {
        guard fills[order.id] == nil else { throw SimError.duplicate }
        guard book.symbol == order.symbol, book.timestamp >= order.submittedAt,
              book.timestamp <= now, now.timeIntervalSince(book.timestamp) <= 5 else { throw SimError.staleBook }
        guard !extraSlippage.isNaN, extraSlippage >= 0 else { throw SimError.invalid }
        let all = book.bids + book.asks
        guard all.allSatisfy({ !$0.price.isNaN && $0.price > 0 && $0.quantity >= 0 }),
              Set(book.bids.map(\.price)).count == book.bids.count,
              Set(book.asks.map(\.price)).count == book.asks.count else { throw SimError.invalid }
        if let bid = book.bids.map(\.price).max(), let ask = book.asks.map(\.price).min(), bid >= ask {
            throw SimError.invalid
        }
        let fee: Decimal
        if order.asset == .etf { fee = Decimal(string: "0.10")! }
        else {
            guard let configured = stockFee, !configured.isNaN, configured >= 0 else { throw SimError.invalid }
            fee = configured
        }
        let levels = order.side == .buy ? book.asks.sorted { $0.price < $1.price } : book.bids.sorted { $0.price > $1.price }
        var remaining = order.quantity
        var gross: Decimal = 0
        for level in levels {
            let price = order.side == .buy ? level.price + extraSlippage : level.price - extraSlippage
            guard price > 0 else { throw SimError.invalid }
            let eligible = order.side == .buy ? price <= order.limit : price >= order.limit
            if !eligible { break }
            let take = min(remaining, level.quantity)
            gross += price * Decimal(take); remaining -= take
            if remaining == 0 { break }
        }
        guard remaining == 0 else { return nil }
        let held = holdings[order.symbol, default: 0]
        if order.side == .buy {
            guard cash >= gross + fee else { throw SimError.insufficientCash }
            cash -= gross + fee; holdings[order.symbol] = held + order.quantity
        } else {
            guard held >= order.quantity else { throw SimError.insufficientShares }
            guard cash + gross >= fee else { throw SimError.insufficientCash }
            cash += gross - fee; holdings[order.symbol] = held - order.quantity
        }
        let fill = SimFill(orderID: order.id, gross: gross, fee: fee, quantity: order.quantity)
        fills[order.id] = fill
        return fill
    }
}
