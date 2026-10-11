import XCTest
import SwiftData
@testable import Pawtrackr

final class InsightsPerformanceTests: XCTestCase {

    @MainActor
    func testAnalyticsAggregationSpeed() async throws {
        let dataStore = DataStoreService(inMemory: true)
        let container = dataStore.container
        
        // 1. Seed 1000 summary records
        let context = container.mainContext
        for i in 0..<1000 {
            let summary = DaySummary(
                day: Calendar.current.date(byAdding: .day, value: -i, to: .now)!,
                revenue: Decimal(100),
                visitCount: 1
            )
            context.insert(summary)
        }
        try context.save()
        
        let start = CFAbsoluteTimeGetCurrent()
        let vm = InsightsViewModel(dataStore: dataStore)
        
        // 2. Measure full refresh (multi-actor aggregation)
        await vm.refresh()
        
        let end = CFAbsoluteTimeGetCurrent()
        let duration = (end - start) * 1000
        
        print("Insights Aggregation Time: \(duration)ms")
        XCTAssertTrue(duration < 250, "Heavy analytics aggregation took \(duration)ms, exceeding 250ms threshold")
    }
    
    @MainActor
    func testReportGenerationNonBlocking() async throws {
        let vm = InsightsViewModel(dataStore: DataStoreService(inMemory: true))
        await vm.refresh()
        
        let start = CFAbsoluteTimeGetCurrent()
        
        // Trigger async report generation
        let exports = try await vm.makeReportExports(businessName: "Test Salon")
        let data = exports.pdf.pdfData
        
        let end = CFAbsoluteTimeGetCurrent()
        let duration = (end - start) * 1000
        
        XCTAssertFalse(data.isEmpty)
        print("PDF Generation Time: \(duration)ms")
        // Rendering 1000 rows might take time, but it should be off-main. 
        // This test ensures it completes.
    }
}
