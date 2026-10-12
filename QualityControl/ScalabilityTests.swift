import XCTest
import SwiftData
@testable import Pawtrackr

/// Extreme-scale verification to ensure the app stays fast with thousands of records.
final class ScalabilityTests: XCTDataTestCase {
    
    func testSearchPerformance_WithLargeDataset() async throws {
        let repo = ClientRepository(modelContainer: container)
        
        // 1. Seed 2,000 records
        let count = 2000
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    _ = try? await repo.createClient(
                        firstName: "Performance",
                        lastName: "Test \(i)",
                        phone: "555\(String(format: "%04d", i))",
                        email: "test\(i)@example.com",
                        address: "",
                        photoData: nil,
                        pets: [NewPetData(name: "Pet \(i)", species: .dog, gender: .male, breed: nil, color: nil, photoData: nil, health: nil, behaviorTags: [], birthdate: nil)],
                        contacts: []
                    )
                }
            }
        }
        
        // 2. Measure search time
        _ = try await repo.fetchClients(query: "", limit: 1, offset: 0)
        let start = Date()
        let results = try await repo.fetchClients(query: "Test 1999", limit: 20, offset: 0)
        let duration = Date().timeIntervalSince(start)
        
        // Benchmark: Search should be sub-100ms even with 2k records
        XCTAssertEqual(results.count, 1)
        XCTAssertLessThan(duration, 0.1, "Search took too long: \(duration)s")
        print("Scalability Search Duration: \(duration)s")
    }
}
