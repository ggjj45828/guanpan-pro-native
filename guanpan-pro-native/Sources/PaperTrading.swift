import Foundation

/// Independent paper ledger. No PortfolioStore, NAS, broker or real-ledger dependency.
struct PaperOrder: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case waiting, filled, cancelled, expired }
    let id: UUID
    let code: String
    let limit: Double
    let quantity: Int
    let createdAt: Date
    let expiresAt: Date
    var status: Status = .waiting
    var filledAt: Date?
    var fillPrice: Double?
}

struct PaperPosition: Codable, Equatable {
    var code: String
    var quantity: Int
    var bookCost: Double
}

struct PaperAccount: Codable, Equatable {
    var cash: Double = 10000
    var positions: [PaperPosition] = []
    var orders: [PaperOrder] = []
    static let fee = 0.10

    var reservedCash: Double {
        orders.filter { $0.status == .waiting }.reduce(0) { $0 + $1.limit * Double($1.quantity) + Self.fee }
    }
    var availableCash: Double { max(0, cash - reservedCash) }

    var isValid: Bool {
        cash.isFinite && cash >= 0 && reservedCash.isFinite && reservedCash <= cash + 0.000001 &&
        Set(orders.map(\.id)).count == orders.count &&
        Set(positions.map(\.code)).count == positions.count &&
        positions.allSatisfy { $0.quantity > 0 && $0.bookCost.isFinite && $0.bookCost >= 0 } &&
        orders.allSatisfy { $0.limit.isFinite && $0.limit > 0 && $0.quantity > 0 && $0.quantity % 100 == 0 && $0.expiresAt > $0.createdAt }
    }
    mutating func expire(at now: Date) {
        for i in orders.indices where orders[i].status == .waiting && now >= orders[i].expiresAt {
            orders[i].status = .expired
        }
    }

    mutating func place(code: String, limit: Double, quantity: Int, now: Date, expires: Date) -> Bool {
        expire(at: now)
        // ETF-only initial release; no naked shorting, margin or stock simulation.
        let isETF = code.count == 6 && code.allSatisfy(\.isNumber) &&
            (code.hasPrefix("15") || code.hasPrefix("16") || code.hasPrefix("51") || code.hasPrefix("56") || code.hasPrefix("58"))
        guard isETF, limit.isFinite, limit > 0, limit <= 100000,
              quantity > 0, quantity <= 100000000, quantity % 100 == 0,
              expires > now, limit * Double(quantity) + Self.fee <= availableCash else { return false }
        orders.append(PaperOrder(id: UUID(), code: code, limit: limit, quantity: quantity, createdAt: now, expiresAt: expires))
        return true
    }

    mutating func cancel(id: UUID) {
        guard let i = orders.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        orders[i].status = .cancelled
    }

    /// Only an observed, recent, post-order quote can fill a waiting order.
    /// Last-price touch is explicitly a simulation assumption, not proof of liquidity.
    mutating func observe(code: String, price: Double, timestamp: Date, now: Date) {
        expire(at: now)
        guard price.isFinite, price > 0, timestamp <= now,
              now.timeIntervalSince(timestamp) <= 120, Self.isTradingTime(timestamp) else { return }
        for i in orders.indices where orders[i].status == .waiting && orders[i].code == code {
            let order = orders[i]
            guard timestamp > order.createdAt, timestamp < order.expiresAt, price <= order.limit else { continue }
            // Conservative execution: pay the order limit even if observed price is better.
            let gross = order.limit * Double(order.quantity) + Self.fee
            guard gross.isFinite, gross <= cash else { continue }
            cash -= gross
            if let p = positions.firstIndex(where: { $0.code == code }) {
                positions[p].quantity += order.quantity
                positions[p].bookCost += gross
            } else {
                positions.append(PaperPosition(code: code, quantity: order.quantity, bookCost: gross))
            }
            orders[i].status = .filled
            orders[i].filledAt = timestamp
            orders[i].fillPrice = order.limit
        }
    }

    static func isTradingTime(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = cal.component(.weekday, from: date)
        let minute = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return (2...6).contains(day) && ((570...690).contains(minute) || (780...900).contains(minute))
    }
}
