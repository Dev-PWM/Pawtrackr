import XCTest
@testable import Pawtrackr

final class CheckoutCentAllocationTests: XCTestCase {
    func testChosenTotalIsPreservedAcrossRoundingBoundaries() {
        for count in 1...12 {
            for cents in 0...99 {
                let weights = (0..<count).map { Decimal(($0 * 17 + cents) % 41) / 100 }
                let amount = Decimal(cents) / 100
                let result = CheckoutCalculatorActor.reconcileLineTotals(weights: weights, finalTotal: amount)
                XCTAssertEqual(result.reduce(Decimal.zero, +), amount, "\(count) lines, \(cents) cents")
                XCTAssertTrue(result.allSatisfy { $0 >= .zero && $0 == $0.roundedMoney() })
            }
        }
    }

    func testHistoricalWeightsDistributeTheChosenEightyFiveDollarsExactly() {
        let result = CheckoutCalculatorActor.reconcileLineTotals(weights: [Decimal(string: "82.50")!, 15], finalTotal: 85)
        XCTAssertEqual(result, [Decimal(string: "71.92")!, Decimal(string: "13.08")!])
    }

    func testEditingUnitPriceOrQuantityClearsTheCheckoutRemainder() {
        let pet = Pet(name: "Test", species: .dog)
        let visit = Visit(pet: pet)
        let item = VisitItem(name: "Custom", unitPrice: 10, quantity: 3, visit: visit)
        item.setReconciledLineTotal(10)
        XCTAssertEqual(item.lineTotal, 10)
        item.setUnitPrice(4)
        XCTAssertEqual(item.lineTotal, 12)
        item.setReconciledLineTotal(10)
        item.setQuantity(2)
        XCTAssertEqual(item.lineTotal, Decimal(string: "6.66"))
    }
}
