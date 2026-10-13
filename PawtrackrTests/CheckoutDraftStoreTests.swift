import XCTest
@testable import Pawtrackr

final class CheckoutDraftStoreTests: XCTestCase {

    func testLateEditorSnapshotCannotReplaceANewerSnapshotOrResurrectDeletion() async throws {
        for inMemory in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CheckoutDraftStore(directoryURL: root, inMemory: inMemory)
            let old = CheckoutDraft(visitID: UUID(), petID: UUID(), currentStepRawValue: 2,
                sessionNotes: "Old", amountString: "85", selectedServiceUUIDs: [], selectedAddOnUUIDs: [],
                selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
                beforePhotoData: nil, afterPhotoData: nil, externalReference: "", tags: [])
            var new = old
            new.selectedPaymentMethodRawValue = Payment.Method.zelle.rawValue
            new.externalReference = "Newest reference"
            try await store.saveDraft(new, revision: 2)
            try await store.saveDraft(old, revision: 1)
            let loaded = await store.loadDraft(for: old.visitID)
            XCTAssertEqual(loaded?.externalReference, "Newest reference")
            XCTAssertEqual(loaded?.selectedPaymentMethodRawValue, Payment.Method.zelle.rawValue)
            try await store.deleteDraft(for: old.visitID, revision: 3)
            try await store.saveDraft(old, revision: 1)
            let deleted = await store.loadDraft(for: old.visitID)
            XCTAssertNil(deleted)
            // Discarding a recovered draft must still allow subsequent new editor work.
            try await store.saveDraft(new, revision: 4)
            let restarted = await store.loadDraft(for: old.visitID)
            XCTAssertEqual(restarted?.externalReference, "Newest reference")
        }
    }

    @MainActor
    func testDeleteWaitsForAnEarlierSuspendedDiskWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckoutDraftStore(directoryURL: root)
        let draft = CheckoutDraft(visitID: UUID(), petID: UUID(), currentStepRawValue: 2,
            sessionNotes: String(repeating: "Recovery note. ", count: 1_000_000),
            amountString: "85", selectedServiceUUIDs: [], selectedAddOnUUIDs: [],
            selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
            beforePhotoData: nil, afterPhotoData: nil, externalReference: "", tags: [])
        let first = Task { try await store.saveDraft(draft) }
        // Directory creation happens inside detached I/O, after the store has queued the write.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: root.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try await store.deleteDraft(for: draft.visitID)
        try await first.value
        let loaded = await store.loadDraft(for: draft.visitID)
        XCTAssertNil(loaded, "An earlier detached write must not resurrect a completed checkout draft.")
    }

    func testPracticeDraftsNeverReadWriteOrDeleteDiskDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = CheckoutDraftStore(directoryURL: root)
        let practice = CheckoutDraftStore(directoryURL: root, inMemory: true)
        let draft = CheckoutDraft(visitID: UUID(), petID: UUID(), currentStepRawValue: 2,
            sessionNotes: "Real checkout", amountString: "$42.00", selectedServiceUUIDs: [],
            selectedAddOnUUIDs: [], selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
            beforePhotoData: nil, afterPhotoData: nil, externalReference: "", tags: [])
        try await disk.saveDraft(draft)
        let existingFile = root.appendingPathComponent("\(draft.visitID.uuidString).json")
        let originalData = try Data(contentsOf: existingFile)
        let initialPracticeDraft = await practice.loadDraft(for: draft.visitID)
        XCTAssertNil(initialPracticeDraft)
        var practiceDraft = draft
        practiceDraft.sessionNotes = "Practice checkout"
        try await practice.saveDraft(practiceDraft)
        let loaded = await practice.loadDraft(for: draft.visitID)
        XCTAssertEqual(loaded, practiceDraft)
        XCTAssertEqual(try Data(contentsOf: existingFile), originalData)
        let nextSession = CheckoutDraftStore(directoryURL: root, inMemory: true)
        let nextDraft = await nextSession.loadDraft(for: draft.visitID)
        XCTAssertNil(nextDraft)
        try await practice.deleteDraft(for: draft.visitID)
        XCTAssertEqual(try Data(contentsOf: existingFile), originalData)
        var newDraft = practiceDraft
        newDraft.visitID = UUID()
        try await practice.saveDraft(newDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(newDraft.visitID.uuidString).json").path))
    }

    func testPracticeCheckoutEventsNeverCreateTraceFiles() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logURL = root.appendingPathComponent("checkout.log")
        let recorder = CheckoutEventRecorder(logURL: logURL, persistsEvents: false)
        for _ in 0..<12 {
            await recorder.record("practice_checkout", visitID: UUID(), petName: "Practice pet")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDraftRoundTrip_SaveLoadDelete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CheckoutDraftStore(directoryURL: root)
        let visitID = UUID()
        let petID = UUID()

        let draft = CheckoutDraft(
            visitID: visitID,
            petID: petID,
            currentStepRawValue: 2,
            sessionNotes: "Calm during groom",
            amountString: "$42.00",
            tipAmountString: "$6.30",
            selectedTipPercentage: 15,
            selectedServiceUUIDs: [UUID()],
            selectedAddOnUUIDs: [UUID()],
            selectedPaymentMethodRawValue: Payment.Method.cash.rawValue,
            beforePhotoData: Data([0x01, 0x02]),
            afterPhotoData: Data([0x03, 0x04]),
            hadBeforePhoto: true,
            hadAfterPhoto: true,
            externalReference: "1234",
            tags: ["Friendly"],
            selectedLoyaltyReward: LoyaltyReward.builtInCatalog[0]
        )

        try await store.saveDraft(draft)
        let loaded = await store.loadDraft(for: visitID)
        XCTAssertEqual(loaded?.visitID, draft.visitID)
        XCTAssertEqual(loaded?.petID, draft.petID)
        XCTAssertEqual(loaded?.currentStepRawValue, draft.currentStepRawValue)
        XCTAssertEqual(loaded?.sessionNotes, draft.sessionNotes)
        XCTAssertEqual(loaded?.amountString, draft.amountString)
        XCTAssertEqual(loaded?.tipAmountString, draft.tipAmountString)
        XCTAssertEqual(loaded?.selectedTipPercentage, draft.selectedTipPercentage)
        XCTAssertEqual(loaded?.selectedServiceUUIDs, draft.selectedServiceUUIDs)
        XCTAssertEqual(loaded?.selectedAddOnUUIDs, draft.selectedAddOnUUIDs)
        XCTAssertEqual(loaded?.selectedPaymentMethodRawValue, draft.selectedPaymentMethodRawValue)
        XCTAssertEqual(loaded?.beforePhotoData, draft.beforePhotoData)
        XCTAssertEqual(loaded?.afterPhotoData, draft.afterPhotoData)
        XCTAssertEqual(loaded?.hadBeforePhoto, draft.hadBeforePhoto)
        XCTAssertEqual(loaded?.hadAfterPhoto, draft.hadAfterPhoto)
        XCTAssertEqual(loaded?.externalReference, draft.externalReference)
        XCTAssertEqual(loaded?.tags, draft.tags)
        XCTAssertEqual(loaded?.selectedLoyaltyReward, draft.selectedLoyaltyReward)

        try await store.deleteDraft(for: visitID)
        let deleted = await store.loadDraft(for: visitID)
        XCTAssertNil(deleted)
    }

    func testLegacyDraftWithoutTipFieldsStillDecodes() throws {
        let visitID = UUID()
        let petID = UUID()
        let serviceID = UUID()
        let json = """
        {
          "visitID" : "\(visitID.uuidString)",
          "petID" : "\(petID.uuidString)",
          "updatedAt" : "2026-05-11T16:00:00Z",
          "currentStepRawValue" : 2,
          "sessionNotes" : "Legacy draft",
          "amountString" : "$42.00",
          "selectedServiceUUIDs" : ["\(serviceID.uuidString)"],
          "selectedAddOnUUIDs" : [],
          "selectedPaymentMethodRawValue" : "\(Payment.Method.cash.rawValue)",
          "externalReference" : "",
          "tags" : []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(CheckoutDraft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.visitID, visitID)
        XCTAssertEqual(draft.tipAmountString, "")
        XCTAssertNil(draft.selectedTipPercentage)
        XCTAssertNil(draft.selectedLoyaltyReward)
        XCTAssertFalse(draft.hadBeforePhoto)
        XCTAssertFalse(draft.hadAfterPhoto)
    }

    func testLegacyDraftInfersPhotoFlagsFromEmbeddedData() throws {
        let visitID = UUID()
        let petID = UUID()
        let json = """
        {
          "visitID" : "\(visitID.uuidString)",
          "petID" : "\(petID.uuidString)",
          "updatedAt" : "2026-05-11T16:00:00Z",
          "currentStepRawValue" : 1,
          "sessionNotes" : "Legacy draft with photos",
          "amountString" : "$42.00",
          "tipAmountString" : "",
          "selectedServiceUUIDs" : [],
          "selectedAddOnUUIDs" : [],
          "selectedPaymentMethodRawValue" : "\(Payment.Method.cash.rawValue)",
          "beforePhotoData" : "AQI=",
          "afterPhotoData" : "AwQ=",
          "externalReference" : "",
          "tags" : []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(CheckoutDraft.self, from: Data(json.utf8))

        XCTAssertTrue(draft.hadBeforePhoto)
        XCTAssertTrue(draft.hadAfterPhoto)
    }
}
