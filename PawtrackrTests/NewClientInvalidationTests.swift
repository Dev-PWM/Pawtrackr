import XCTest
import SwiftData
import Observation
import os
@testable import Pawtrackr

@MainActor
final class NewClientInvalidationTests: XCTestCase {
    /// Tracks the same error dictionaries the form reads without observing the field text itself.
    func testTypingWithoutErrorsDoesNotInvalidateValidationPresentation() throws {
        let model = try makeModel()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({
            _ = model.fieldErrors
            _ = model.contactFieldErrors
        }, onChange: { changed.withLock { $0 = true } })
        let contactID = try XCTUnwrap(model.contacts.first?.id)
        for _ in 0..<100 {
            model.clearValidationError(for: .first)
            model.clearValidationError(for: .last)
            model.clearValidationError(for: .phone)
            model.clearValidationError(for: .email)
            model.clearContactValidationErrors(for: contactID)
        }
        XCTAssertFalse(changed.withLock { $0 }, "Valid input must not publish hundreds of no-op error changes.")
    }

    func testClearingAnActualOwnerErrorStillNotifiesAndPreservesOtherErrors() async throws {
        let model = try makeModel()
        let result = await model.createClient()
        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(model.validationError(for: .first))
        XCTAssertNotNil(model.validationError(for: .last))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = model.fieldErrors }, onChange: { changed.withLock { $0 = true } })
        model.clearValidationError(for: .first)
        XCTAssertTrue(changed.withLock { $0 })
        XCTAssertNil(model.validationError(for: .first))
        XCTAssertNotNil(model.validationError(for: .last))
    }

    func testEditingOneContactClearsOnlyThatRowsErrors() async throws {
        let model = try makeModel()
        model.first = "Clara"
        model.last = "Watson"
        model.contacts[0].name = "Ava Martinez"
        // A name-only contact is valid, so an unusable number produces the phone error.
        model.contacts[0].phone = "12"
        model.addContact()
        model.contacts[1].phone = "2025550177"
        let firstID = model.contacts[0].id
        let secondID = model.contacts[1].id
        let result = await model.createClient()
        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(model.contactValidationError(for: firstID, field: .phone))
        XCTAssertNotNil(model.contactValidationError(for: secondID, field: .name))
        model.clearContactValidationErrors(for: firstID)
        XCTAssertNil(model.contactValidationError(for: firstID, field: .phone))
        XCTAssertNotNil(model.contactValidationError(for: secondID, field: .name))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = model.contactFieldErrors }, onChange: { changed.withLock { $0 = true } })
        model.clearContactValidationErrors(for: firstID)
        XCTAssertFalse(changed.withLock { $0 })
    }

    /// Keeps the production validation path and repository wiring on a disposable local store.
    private func makeModel() throws -> NewClientViewModel {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        return NewClientViewModel(modelContext: container.mainContext)
    }
}
