import XCTest
import SwiftData
@testable import Pawtrackr

final class SummaryUpdaterTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    func testRebuildDay_AggregatesCorrectly() throws {
        let pet = Pet(name: "Max", species: .dog)
        context.insert(pet)
        
        let today = Calendar.current.startOfDay(for: Date())
        
        // Visit 1: $50
        let v1 = Visit(pet: pet, startedAt: today.addingTimeInterval(3600))
        v1.total = Decimal(50)
        v1.endedAt = today.addingTimeInterval(7200)
        
        // Visit 2: $75
        let v2 = Visit(pet: pet, startedAt: today.addingTimeInterval(10000))
        v2.total = Decimal(75)
        v2.endedAt = today.addingTimeInterval(14000)
        
        try context.save()
        
        // Run rebuild
        SummaryUpdater.rebuildDay(for: today, in: context)
        
        // Verify DaySummary
        let summaries = try context.fetch(FetchDescriptor<DaySummary>())
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.revenue, Decimal(125))
        XCTAssertEqual(summaries.first?.visitCount, 2)
    }
    
    func testDedupeSummaryCaches_RemovesDuplicates() throws {
        let today = Calendar.current.startOfDay(for: Date())
        
        // Insert two summaries for the same day
        let s1 = DaySummary(day: today, revenue: 100, visitCount: 1)
        let s2 = DaySummary(day: today, revenue: 150, visitCount: 2) // "Preferred" one
        
        context.insert(s1)
        context.insert(s2)
        try context.save()
        
        SummaryUpdater.dedupeSummaryCaches(in: context)
        
        let summaries = try context.fetch(FetchDescriptor<DaySummary>())
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.visitCount, 2)
        XCTAssertEqual(summaries.first?.revenue, 150)
    }

    func testStagedSummaryIncludesPendingCheckoutAndRollsBackTogether() throws {
        let now = Date()
        let pet = Pet(name: "Pending", species: .dog)
        context.insert(pet)
        let visit = Visit(pet: pet, startedAt: now.addingTimeInterval(-3600))
        context.insert(visit)
        try context.save()

        visit.endedAt = now
        visit.total = Decimal(85)
        try SummaryUpdater.stageDayRebuild(for: now, in: context)
        let staged = try context.fetch(FetchDescriptor<DaySummary>())
        XCTAssertEqual(staged.first?.revenue, Decimal(85))
        XCTAssertEqual(staged.first?.visitCount, 1)

        context.rollback()
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<DaySummary>()), 0)
        XCTAssertNil(try reader.fetch(FetchDescriptor<Visit>()).first?.endedAt)
    }
}
