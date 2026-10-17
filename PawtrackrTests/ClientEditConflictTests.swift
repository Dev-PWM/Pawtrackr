import XCTest
import os
import SwiftData
import Observation
@testable import Pawtrackr

/// The Edit Client sheet and the inline header edit must not silently
/// overwrite a change another device saved while the form was open.
@MainActor
final class ClientEditConflictTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    let thisDevice = UUID()
    let otherDevice = UUID()

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    private func makeClient() throws -> Client {
        let client = Client(firstName: "Ava", lastName: "Stone")
        client.setPhone("(312) 555-0111")
        client.setEmail("ava@example.com")
        client.setAddress("1 Main St")
        client.updatedAt = Date(timeIntervalSince1970: 1_000)
        client.lastModifiedBy = thisDevice
        context.insert(client)
        try context.save()
        return client
    }

    private func form(for client: Client) -> ClientEditForm {
        ClientEditForm(
            firstName: client.firstName,
            lastName: client.lastName,
            phone: ClientContactFields.formPhoneText(client.phone),
            email: client.email ?? "",
            address: client.address ?? ""
        )
    }

    /// Stands in for a CloudKit import: another context writes the other
    /// device's values, including its synced stamps, and saves.
    private func simulateEditFromOtherDevice(_ clientUUID: UUID, at date: Date, change: (Client) -> Void) throws {
        let importContext = ModelContext(container)
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate<Client> { $0.uuid == clientUUID })
        let remote = try XCTUnwrap(importContext.fetch(descriptor).first)
        change(remote)
        remote.updatedAt = date
        remote.lastModifiedBy = otherDevice
        try importContext.save()
    }

    private func stored(_ clientUUID: UUID) throws -> Client {
        let fresh = ModelContext(container)
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate<Client> { $0.uuid == clientUUID })
        return try XCTUnwrap(fresh.fetch(descriptor).first)
    }

    // MARK: - Predicate

    func testPredicateFlagsOnlyAnotherDevicesChangeToTheFormsFields() {
        let fields = ClientContactFields(firstName: "Ava", lastName: "Stone", phone: "+13125550111", email: nil, address: nil)
        let baseline = ClientEditBaseline(clientUUID: UUID(), updatedAt: Date(timeIntervalSince1970: 100), lastModifiedBy: thisDevice, fields: fields)
        var changedFields = fields
        changedFields.phone = "+13125550199"

        func current(updatedAt: TimeInterval, by device: UUID, _ fields: ClientContactFields) -> ClientEditBaseline {
            ClientEditBaseline(clientUUID: baseline.clientUUID, updatedAt: Date(timeIntervalSince1970: updatedAt), lastModifiedBy: device, fields: fields)
        }

        XCTAssertTrue(baseline.hasChangeFromAnotherDevice(current: current(updatedAt: 200, by: otherDevice, changedFields), currentDeviceID: thisDevice))
        XCTAssertFalse(baseline.hasChangeFromAnotherDevice(current: current(updatedAt: 200, by: thisDevice, changedFields), currentDeviceID: thisDevice), "This device's own change isn't a conflict.")
        XCTAssertFalse(baseline.hasChangeFromAnotherDevice(current: current(updatedAt: 200, by: otherDevice, fields), currentDeviceID: thisDevice), "A newer stamp with the form's fields unchanged (a pet added, points earned) isn't a conflict.")
        XCTAssertFalse(baseline.hasChangeFromAnotherDevice(current: current(updatedAt: 100, by: otherDevice, changedFields), currentDeviceID: thisDevice), "Nothing newer than the form.")

        // The baseline's own writer doesn't matter: a second edit by the device
        // that made the previous one is still another device's edit.
        let openedOnOthersEdit = ClientEditBaseline(clientUUID: baseline.clientUUID, updatedAt: baseline.updatedAt, lastModifiedBy: otherDevice, fields: fields)
        XCTAssertTrue(openedOnOthersEdit.hasChangeFromAnotherDevice(current: current(updatedAt: 200, by: otherDevice, changedFields), currentDeviceID: thisDevice))
    }

    func testFormKeepsAnUntouchedOlderPhoneAndRejectsAnUnreadableNewOne() {
        let original = ClientContactFields(firstName: "Ava", lastName: "Stone", phone: "555-1234", email: nil, address: nil)
        var form = ClientEditForm(firstName: "Ava", lastName: "Stone", phone: ClientContactFields.formPhoneText(original.phone), email: "", address: nil)

        XCTAssertEqual(ClientContactFields.formPhoneText("555-1234"), "555-1234", "An older phone shows as stored, not blank.")
        XCTAssertEqual(form.proposedFields(original: original)?.phone, "555-1234")
        XCTAssertEqual(form.proposedFields(original: original)?.changedFields(comparedTo: original), [])

        form.phone = "555-9999"
        XCTAssertNil(form.proposedFields(original: original), "A newly typed phone must be readable.")

        form.phone = ""
        XCTAssertEqual(form.proposedFields(original: original)?.phone, nil, "Clearing the phone is a real change.")
    }

    func testFormComparesNormalizedValuesSoAnUntouchedSaveChangesNothing() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        let untouched = form(for: client)

        XCTAssertEqual(untouched.proposedFields(original: baseline.fields), baseline.fields, "\"(312) 555-0111\" in the form is the stored +13125550111.")
        XCTAssertEqual(
            ClientEditSaver.save(untouched, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice),
            .unchanged
        )
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(client.updatedAt, Date(timeIntervalSince1970: 1_000), "A no-op Save must not stamp the client.")
    }

    // MARK: - Setters

    func testSettersDoNotStampWhenTheValueIsUnchanged() throws {
        let client = try makeClient()

        client.setFirstName(" Ava ")
        client.setLastName("Stone")
        client.setPhone("312-555-0111")
        client.setEmail("AVA@example.com")
        client.setAddress("1 Main St")

        XCTAssertFalse(context.hasChanges, "Assigning an equal value would still upload the row.")
        XCTAssertEqual(client.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(client.lastModifiedBy, thisDevice)

        client.setEmail("new@example.com")
        XCTAssertTrue(context.hasChanges)
        XCTAssertGreaterThan(client.updatedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(client.lastModifiedBy, DeviceIdentity.currentID)
    }

    // MARK: - Save paths against a real store

    func testSaveWithoutAnotherDevicesChangeSavesOnlyTheEditedField() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.email = "ava.stone@example.com"

        let outcome = ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice)

        XCTAssertEqual(outcome, .saved)
        let saved = try stored(client.uuid)
        XCTAssertEqual(saved.email, "ava.stone@example.com")
        XCTAssertEqual(saved.phone, "+13125550111")
        XCTAssertEqual(client.email, "ava.stone@example.com", "The screen's object shows the saved value.")
    }

    func testAnotherDevicesEditStopsTheSaveAndSaveMineKeepsTheirOtherField() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.email = "ava.stone@example.com"

        try simulateEditFromOtherDevice(client.uuid, at: Date(timeIntervalSince1970: 2_000)) { remote in
            remote.phone = "+13125550199"
        }

        let first = ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice)
        XCTAssertEqual(first, .changedElsewhere, "The other device's phone change must stop a silent overwrite.")
        XCTAssertEqual(try stored(client.uuid).email, "ava@example.com", "Nothing is written until the groomer chooses.")

        let second = ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: true, currentDeviceID: thisDevice)
        XCTAssertEqual(second, .saved)
        let saved = try stored(client.uuid)
        XCTAssertEqual(saved.email, "ava.stone@example.com", "Save My Changes writes the groomer's edit.")
        XCTAssertEqual(saved.phone, "+13125550199", "A field the groomer didn't touch keeps the other device's change.")
        XCTAssertEqual(client.email, "ava.stone@example.com", "The screen's object shows the saved values.")
        XCTAssertEqual(client.phone, "+13125550199")
    }

    func testSaveMineOverwritesTheSameFieldTheOtherDeviceChanged() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.phone = "(312) 555-0177"

        try simulateEditFromOtherDevice(client.uuid, at: Date(timeIntervalSince1970: 2_000)) { remote in
            remote.phone = "+13125550199"
        }

        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice),
            .changedElsewhere
        )
        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: true, currentDeviceID: thisDevice),
            .saved
        )
        XCTAssertEqual(try stored(client.uuid).phone, "+13125550177")
    }

    func testAnotherDevicesStampWithoutAFormFieldChangeDoesNotInterrupt() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.lastName = "Stone-Reyes"

        try simulateEditFromOtherDevice(client.uuid, at: Date(timeIntervalSince1970: 2_000)) { remote in
            remote.loyaltyPoints = 40
        }

        let outcome = ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice)

        XCTAssertEqual(outcome, .saved)
        let saved = try stored(client.uuid)
        XCTAssertEqual(saved.lastName, "Stone-Reyes")
        XCTAssertEqual(saved.loyaltyPoints, 40, "The other device's points survive the save.")
        XCTAssertEqual(client.loyaltyPoints, 40)
        XCTAssertEqual(client.lastName, "Stone-Reyes")
    }

    func testSavedEditReachesScreensWatchingTheClient() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.firstName = "Avery"

        try simulateEditFromOtherDevice(client.uuid, at: Date(timeIntervalSince1970: 2_000)) { remote in
            remote.loyaltyPoints = 12
        }

        let observedChange = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = client.firstName }, onChange: {
            observedChange.withLock { $0 = true }
        })
        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice),
            .saved
        )

        XCTAssertTrue(observedChange.withLock { $0 },
                      "List cards and headers observing the client must see the new name.")
        XCTAssertEqual(client.firstName, "Avery")
        XCTAssertEqual(try stored(client.uuid).loyaltyPoints, 12, "Writing through the re-read object keeps the other device's points.")
    }

    func testStaleViewObjectFallsBackToAFreshWrite() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.email = "ava.stone@example.com"

        try simulateEditFromOtherDevice(client.uuid, at: Date(timeIntervalSince1970: 2_000)) { remote in
            remote.phone = "+13125550199"
        }
        // Unsaved local edits keep a re-read from refreshing the view's object.
        client.loyaltyPoints = 7

        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: true, currentDeviceID: thisDevice),
            .saved
        )
        let saved = try stored(client.uuid)
        XCTAssertEqual(saved.email, "ava.stone@example.com")
        XCTAssertEqual(saved.phone, "+13125550199", "The edit never saves the stale view object.")
        // Known limit, outside this saver: the view context still holds that
        // dirty, stale object, and its own next save puts the old values back.
    }

    func testMissingClientIsReportedInsteadOfRecreated() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.firstName = "Avery"

        let other = ModelContext(container)
        let uuid = client.uuid
        let remote = try XCTUnwrap(other.fetch(FetchDescriptor<Client>(predicate: #Predicate<Client> { $0.uuid == uuid })).first)
        other.delete(remote)
        try other.save()

        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: nil, overwrite: false, currentDeviceID: thisDevice),
            .missing
        )
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<Client>()).isEmpty, "The edit must not bring a deleted client back.")
    }

    func testThisDevicesOwnEarlierSaveIsNotAConflict() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.firstName = "Avery"

        // Another window on this device saved a phone change.
        let sibling = ModelContext(container)
        let uuid = client.uuid
        let other = try XCTUnwrap(sibling.fetch(FetchDescriptor<Client>(predicate: #Predicate<Client> { $0.uuid == uuid })).first)
        other.phone = "+13125550155"
        other.updatedAt = Date(timeIntervalSince1970: 2_000)
        other.lastModifiedBy = thisDevice
        try sibling.save()

        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice),
            .saved
        )
        XCTAssertEqual(try stored(client.uuid).firstName, "Avery")
    }

    func testUnreadableNewPhoneIsReportedNotSaved() throws {
        let client = try makeClient()
        let baseline = ClientEditBaseline(client)
        var edited = form(for: client)
        edited.phone = "555-12"

        XCTAssertEqual(
            ClientEditSaver.save(edited, baseline: baseline, container: container, refreshing: context, overwrite: false, currentDeviceID: thisDevice),
            .invalidPhone
        )
        XCTAssertFalse(context.hasChanges)
    }
}
