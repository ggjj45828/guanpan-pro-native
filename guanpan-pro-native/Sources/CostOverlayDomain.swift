import Foundation

/// Display-only axis expansion: never normalizes, rescales or replaces sampled prices.
enum CostOverlayDomain {
    static func including(_ cost: Double?, in domain: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let cost, cost.isFinite, cost > 0 else { return domain }
        guard cost < domain.lowerBound || cost > domain.upperBound else { return domain }
        let low = min(cost, domain.lowerBound)
        let high = max(cost, domain.upperBound)
        let padding = max(high - low, max(abs(high), 0.0001) * 0.002) * 0.06
        return (low - padding)...(high + padding)
    }
}
