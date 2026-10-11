import XCTest
@testable import Pawtrackr

final class CheckoutDraftStoreTests: XCTestCase {

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
