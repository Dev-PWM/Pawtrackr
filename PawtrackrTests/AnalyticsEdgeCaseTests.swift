import XCTest
import SwiftData
@testable import Pawtrackr

final class AnalyticsEdgeCaseTests: XCTestCase {
    var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    func testFetchMonthlyGrowth_HandlesEmptyMonthsCorrectly() async throws {
        let context = ModelContext(container)
        let actor = InsightsActor(modelContainer: container)
        
        // Add one visit 3 months ago
        let cal = Calendar.current
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: Date())!
        let summary = DaySummary(day: cal.startOfDay(for: threeMonthsAgo), revenue: 500, visitCount: 5)
        context.insert(summary)
        try context.save()
        
        let growth = try await actor.fetchMonthlyGrowth()
        
        // Growth should contain 6 months of data (current + 5 previous)
        XCTAssertEqual(growth.count, 6)
        
        // Verify that months with no data have 0 revenue, not "nil" or "missing"
        let emptyMonths = growth.filter { $0.revenue == 0 }
        XCTAssertEqual(emptyMonths.count, 5, "Five out of six months should have zero revenue.")
        
        let activeMonth = growth.first(where: { $0.revenue == 500 })
        XCTAssertNotNil(activeMonth)
    }
    
    func testFetchDistributions_HandlesZeroVisitData() async throws {
        let actor = InsightsActor(modelContainer: container)
        
        // Fetch distributions with an empty database
        let result = try await actor.fetchDistributions(periodDays: 30)
        
        XCTAssertTrue(result.services.isEmpty)
        XCTAssertTrue(result.categories.isEmpty)
        XCTAssertTrue(result.payments.isEmpty)
    }
}
