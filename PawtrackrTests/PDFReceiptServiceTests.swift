import XCTest
import SwiftData
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Pawtrackr

/// Coverage for the receipt snapshot pipeline. Especially the regression case where a Visit
/// fetched post-checkout must render the persisted total instead of `$0.00`.
@MainActor
final class PDFReceiptServiceTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        Formatters.updateCurrencySymbol("$")
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
    }

    func testMakeSnapshot_PopulatedVisit_RendersFullReceipt() throws {
        let visit = try makePersistedCheckedOutVisit()
        let snapshot = PDFReceiptService.shared.makeSnapshot(for: visit)

        XCTAssertTrue(snapshot.receiptNumber.hasPrefix("RECEIPT: #"))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items.map(\.name).sorted(), ["Bath", "Nail Trim"])
        XCTAssertEqual(snapshot.totalString, "$45.00")
        XCTAssertNotNil(snapshot.payment)
        XCTAssertTrue(snapshot.payment?.infoLine.contains("Cash") ?? false)
        XCTAssertTrue(snapshot.petLine.contains("Buddy"))
        XCTAssertEqual(snapshot.clientName, "Jane Doe")
    }

    /// Regression guard: even when the Visit is fetched fresh from the container (the path
    /// CheckoutVM now uses after actor success), the receipt must render the real total.
    func testMakeSnapshot_FreshlyFetchedVisit_ShowsCorrectTotal() throws {
        let original = try makePersistedCheckedOutVisit()
        let visitUUID = original.uuid

        let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.uuid == visitUUID })
        let refetched = try XCTUnwrap(try context.fetch(descriptor).first)

        let snapshot = PDFReceiptService.shared.makeSnapshot(for: refetched)
        XCTAssertEqual(snapshot.totalString, "$45.00")
        XCTAssertNotEqual(snapshot.totalString, "$0.00",
            "Receipt regressed to rendering an empty Visit — see CheckoutViewModel.processPayment refresh path.")
    }

    func testMakeSnapshot_VisitWithoutPayment_OmitsPaymentSection() {
        let pet = makePet()
        let visit = Visit(pet: pet)
        context.insert(visit)
        visit.addItem(title: "Bath", unitPrice: Decimal(30))
        visit.markCheckedOut(total: Decimal(30))

        let snapshot = PDFReceiptService.shared.makeSnapshot(for: visit)
        XCTAssertNil(snapshot.payment)
        XCTAssertEqual(snapshot.totalString, "$30.00")
    }

    func testMakeSnapshot_VisitWithoutOwner_FallsBackToValuedCustomer() {
        let pet = Pet(name: "Stray", species: .dog)
        context.insert(pet)
        let visit = Visit(pet: pet)
        context.insert(visit)
        visit.markCheckedOut(total: Decimal(10))

        let snapshot = PDFReceiptService.shared.makeSnapshot(for: visit)
        XCTAssertEqual(snapshot.clientName, "Valued Customer")
    }

    func testRender_ProducesNonTrivialPDFData() throws {
        let visit = try makePersistedCheckedOutVisit()
        let snapshot = PDFReceiptService.shared.makeSnapshot(for: visit)
        let data = PDFReceiptService.render(snapshot: snapshot)
        XCTAssertGreaterThan(data.count, 1024,
            "PDF appears suspiciously small; renderer may have produced an empty page.")
        // Sanity-check that the data is a real PDF (signature %PDF-).
        let prefix = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(prefix, "%PDF-")
    }

    func testReceiptRendersIdenticalInkInLightAndDarkAppearances() throws {
        let snapshot = PDFReceiptService.shared.makeSnapshot(for: try makePersistedCheckedOutVisit())
        var light = Data()
        var dark = Data()
        #if os(iOS)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            light = PDFReceiptService.render(snapshot: snapshot)
        }
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = PDFReceiptService.render(snapshot: snapshot)
        }
        #else
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = PDFReceiptService.render(snapshot: snapshot)
        }
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = PDFReceiptService.render(snapshot: snapshot)
        }
        #endif
        let lightPixels = try rasterizedPage(light)
        let darkPixels = try rasterizedPage(dark)
        XCTAssertEqual(lightPixels, darkPixels, "App appearance must never change printed receipt ink.")
        let inkPixels = stride(from: 0, to: lightPixels.count, by: 4).filter {
            lightPixels[$0] < 100 && lightPixels[$0 + 1] < 100 && lightPixels[$0 + 2] < 100
        }.count
        XCTAssertGreaterThan(inkPixels, 1_000, "The receipt must contain visible ink.")
    }

    private func rasterizedPage(_ data: Data) throws -> Data {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 306, height: 396, bitsPerComponent: 8, bytesPerRow: 306 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 306, height: 396))
        context.scaleBy(x: 0.5, y: 0.5)
        page.draw(with: .mediaBox, to: context)
        return Data(bytes: try XCTUnwrap(context.data), count: 306 * 396 * 4)
    }

    private func makePet() -> Pet {
        let client = Client(firstName: "Jane", lastName: "Doe", phone: "5551234567")
        context.insert(client)
        let pet = Pet(name: "Buddy", species: .dog)
        pet.owner = client
        context.insert(pet)
        return pet
    }

    private func makePersistedCheckedOutVisit() throws -> Visit {
        let pet = makePet()
        let visit = Visit(pet: pet)
        context.insert(visit)
        visit.addItem(title: "Bath", unitPrice: Decimal(30))
        visit.addItem(title: "Nail Trim", unitPrice: Decimal(15))
        let payment = Payment(amount: Decimal(45), method: .cash, paidAt: .now)
        context.insert(payment)
        visit.attachPayment(payment)
        visit.markCheckedOut(total: Decimal(45))
        try context.save()
        return visit
    }
}
