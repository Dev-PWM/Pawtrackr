import Foundation

/// Pure cent allocation used on the checkout persistence actor's executor.
actor CheckoutCalculatorActor {
    /// Allocates whole cents by largest remainder, preserving the exact nonnegative total.
    /// Decimal quotas avoid overflow from converting large currency values to machine integers.
    nonisolated static func reconcileLineTotals(weights: [Decimal], finalTotal: Decimal) -> [Decimal] {
        guard !weights.isEmpty else { return [] }
        let totalCents = max(.zero, finalTotal.roundedMoney()) * 100
        let nonnegative = weights.map { max(.zero, $0) }
        let subtotal = nonnegative.reduce(Decimal.zero, +)
        let quotas = nonnegative.map {
            subtotal > .zero ? totalCents * $0 / subtotal : totalCents / Decimal(weights.count)
        }
        var cents = quotas.map { value -> Decimal in
            var input = value
            var output = Decimal.zero
            NSDecimalRound(&output, &input, 0, .down)
            return output
        }
        let remainder = totalCents - cents.reduce(Decimal.zero, +)
        let ranking = quotas.indices.sorted {
            let lhs = quotas[$0] - cents[$0]
            let rhs = quotas[$1] - cents[$1]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        // The sum of fractional remainders is strictly smaller than the line count.
        let extraCents = min(weights.count, max(0, NSDecimalNumber(decimal: remainder).intValue))
        for index in ranking.prefix(extraCents) { cents[index] += 1 }
        return cents.map { ($0 / 100).roundedMoney() }
    }
}
