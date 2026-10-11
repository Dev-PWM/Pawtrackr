import XCTest
import SwiftData
import PDFKit
@testable import Pawtrackr

/// The Insights report: one period's facts, the CSV and the PDF made from
/// them.
final class BusinessReportTests: XCTestCase {
    private var container: ModelContainer!
    private var calendar = Calendar(identifier: .gregorian)
    /// Wednesday, September 30, 2026, at noon UTC.
    private var now: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        now = try date(month: 9, day: 30, hour: 12)
    }

    override func tearDownWithError() throws {
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Facts

    func testFactsCoverOnePeriodAndCompareWithThePreviousOne() throws {
        try seedSalon()
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)

        XCTAssertEqual(facts.periodStart, try date(month: 9, day: 1))
        XCTAssertEqual(facts.days.count, 30, "Every day of the period, days without visits too.")
        XCTAssertEqual(facts.revenue, Decimal(200))
        XCTAssertEqual(facts.visits, 3, "The visit still in progress doesn't count.")
        XCTAssertEqual(facts.averageTicket, try XCTUnwrap(Decimal(string: "66.67")))
        XCTAssertEqual(facts.previousRevenue, Decimal(50))
        XCTAssertEqual(facts.previousVisits, 1)

        XCTAssertEqual(facts.clients, 2)
        XCTAssertEqual(facts.firstTimeClients, 1, "Jordan came in August too.")
        XCTAssertEqual(facts.returningClients, 1)

        XCTAssertEqual(facts.services.map(\.name), ["Bath", "Full Groom"], "Tied on revenue: the one sold more often first.")
        XCTAssertEqual(facts.services.first?.count, 2)
        XCTAssertEqual(facts.payments.map(\.name), [Payment.Method.cash.displayName, Payment.Method.creditCard.displayName])
        XCTAssertEqual(facts.payments.first?.amount, Decimal(140))
        XCTAssertEqual(facts.topClients.map(\.name), ["Ava Martinez", "Jordan Lee"])
        XCTAssertEqual(facts.topClients.first?.amount, Decimal(160))

        let busiest = try date(month: 9, day: 24)
        XCTAssertEqual(facts.days[23].date, busiest)
        XCTAssertEqual(facts.days[23].revenue, Decimal(100))
        XCTAssertEqual(facts.busiestWeekday, BusinessReportFacts.Weekday(weekday: calendar.component(.weekday, from: busiest), visits: 3))

        XCTAssertEqual(facts.months.count, 6)
        XCTAssertEqual(facts.months.last?.revenue, Decimal(200))
        XCTAssertEqual(facts.months[4].revenue, Decimal(50), "August.")
    }

    // MARK: - CSV

    func testCSVContainsOnlyDatesAndTheFourBusinessTables() throws {
        try seedSalon()
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)
        let csv = BusinessReportCSV.make(facts: facts, calendar: calendar)
        let lines = csv.csvData.components(separatedBy: "\r\n")
        let blocks = csv.csvData.components(separatedBy: "\r\n\r\n")

        XCTAssertEqual(blocks.first, "Period,2026-09-01,2026-09-30\r\nGenerated,2026-09-30 12:00")
        XCTAssertEqual(blocks.dropFirst().map { $0.components(separatedBy: "\r\n")[0] }, [
            "Monthly performance", "Services", "Payment methods", "Daily revenue"
        ], "Only the requested business sections are exported, in order.")
        XCTAssertTrue(lines.contains("Month,Visits,Revenue"))
        XCTAssertTrue(lines.contains("2026-08,1,50.00"))
        XCTAssertTrue(lines.contains("2026-09,3,200.00"))
        XCTAssertEqual(blocks[2], "Services\r\nService,Sales\r\nBath,2\r\nFull Groom,1")
        XCTAssertTrue(lines.contains("Method,Payments,Amount"))
        XCTAssertTrue(lines.contains("\(Payment.Method.cash.displayName),2,140.00"))
        XCTAssertFalse(csv.csvData.contains("Average visit"))
        XCTAssertFalse(csv.csvData.contains("Share (%)"))
        XCTAssertTrue(lines.contains("Date,Weekday,Visits,Revenue"))
        XCTAssertTrue(lines.contains("2026-09-24,Thursday,2,100.00"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("2026-09-") }.count, 30, "One row per day, including days without visits.")
        XCTAssertFalse(csv.csvData.contains("Ava Martinez"), "Client details stay out of the business CSV.")
        XCTAssertFalse(csv.csvData.contains("Jordan Lee"))
        XCTAssertEqual(csv.filename, "Pawtrackr_Owner_Insights_2026-09-30.csv")
    }

    func testCSVKeepsDailyRevenueAndRecordedPaymentsAsSeparateFigures() throws {
        let start = try date(month: 9, day: 1)
        let end = try date(month: 10, day: 1)
        var facts = BusinessReportFacts(
            generatedAt: now,
            periodDays: 30,
            periodStart: start,
            periodEnd: end
        )
        facts.revenue = Decimal(120)
        facts.visits = 2
        facts.clients = 2
        facts.days = [BusinessReportFacts.Day(date: try date(month: 9, day: 30), revenue: Decimal(120), visits: 2)]
        facts.payments = [BusinessReportFacts.Line(name: Payment.Method.cash.displayName, count: 1, amount: Decimal(100))]

        let csv = BusinessReportCSV.make(facts: facts, calendar: calendar)
        let lines = csv.csvData.components(separatedBy: "\r\n")

        XCTAssertTrue(lines.contains("2026-09-30,Wednesday,2,120.00"))
        XCTAssertTrue(lines.contains("\(Payment.Method.cash.displayName),1,100.00"))
        XCTAssertFalse(csv.csvData.contains("Revenue less recorded payments"))
        XCTAssertFalse(csv.csvData.contains("Payment coverage"))
    }

    func testEmptyCSVKeepsTableHeadersAndEveryDate() throws {
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 7, now: now, calendar: calendar)
        let csv = BusinessReportCSV.make(facts: facts, calendar: calendar)
        let blocks = csv.csvData.components(separatedBy: "\r\n\r\n")
        let lines = csv.csvData.components(separatedBy: "\r\n")

        XCTAssertEqual(blocks.count, 5, "Dates and four tables, even with no completed visits.")
        XCTAssertEqual(blocks.first, "Period,2026-09-24,2026-09-30\r\nGenerated,2026-09-30 12:00")
        XCTAssertEqual(blocks[2], "Services\r\nService,Sales")
        XCTAssertEqual(blocks[3], "Payment methods\r\nMethod,Payments,Amount")
        XCTAssertEqual(lines.filter { $0.hasPrefix("2026-09-") }.count, 7)
        XCTAssertTrue(lines.contains("2026-09-24,Thursday,0,0.00"))
        XCTAssertTrue(lines.contains("2026-09-30,Wednesday,0,0.00"))
    }

    // MARK: - PDF

    @MainActor
    func testTheDocumentReadsLikeAReport() throws {
        try seedSalon()
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)
        let document = BusinessReportService.makeDocument(facts: facts, businessName: "  Repro Grooming ", reviewItems: [], calendar: calendar)

        XCTAssertEqual(document.businessName, "Repro Grooming")
        XCTAssertEqual(document.tiles.count, 4)
        XCTAssertEqual(document.tiles[0].trend, .up)
        XCTAssertTrue(document.tiles[0].detail.contains("300%"), document.tiles[0].detail)
        XCTAssertTrue(document.tiles[3].detail.contains("1 first-time"), document.tiles[3].detail)
        XCTAssertTrue(document.highlights.contains { $0.hasPrefix("Revenue is up 300%") }, "\(document.highlights)")
        XCTAssertTrue(document.highlights.contains { $0.hasPrefix("Bath earned the most") }, "\(document.highlights)")
        XCTAssertEqual(document.tables.map(\.title), ["Monthly performance", "Services", "Payment methods", "Top clients"])
        XCTAssertEqual(document.tables[1].shares?.first ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(document.chart.values.count, 30)
        XCTAssertTrue(document.filename.hasPrefix("Pawtrackr_Report_2026-09-30"))
    }

    @MainActor
    func testAnEmptyPeriodSaysSoInsteadOfShowingZeros() throws {
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 7, now: now, calendar: calendar)
        let document = BusinessReportService.makeDocument(facts: facts, businessName: "", reviewItems: [], calendar: calendar)
        XCTAssertEqual(document.businessName, "Pawtrackr")
        XCTAssertEqual(document.highlights.count, 1)
        XCTAssertTrue(document.highlights[0].hasPrefix("No finished visits"))
        XCTAssertEqual(document.tiles[0].trend, .neutral)
        XCTAssertTrue(document.tables[1].rows.isEmpty)
    }

    /// The text is really in the PDF: on the Mac it used to be drawn into
    /// whatever context was current instead.
    @MainActor
    func testTheRenderedPDFHoldsItsTextAndPageNumbers() throws {
        try seedSalon()
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)
        let document = BusinessReportService.makeDocument(facts: facts, businessName: "Repro Grooming", reviewItems: [], calendar: calendar)
        let pdf = try XCTUnwrap(PDFDocument(data: BusinessReportService.render(document)))

        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let firstPage = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(firstPage.contains("Repro Grooming"), firstPage)
        XCTAssertTrue(firstPage.contains("At a glance"))
        XCTAssertTrue(firstPage.contains("Page 1 of \(pdf.pageCount)"))
    }

    @MainActor
    func testLongTablesContinueOnTheNextPage() throws {
        var facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)
        facts.visits = 60
        facts.revenue = Decimal(3_000)
        facts.services = (1...60).map { BusinessReportFacts.Line(name: "Service \($0)", count: 1, amount: Decimal(50)) }
        let document = BusinessReportService.makeDocument(facts: facts, businessName: "Repro Grooming", reviewItems: [], calendar: calendar)
        let pdf = try XCTUnwrap(PDFDocument(data: BusinessReportService.render(document)))

        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        let secondPage = try XCTUnwrap(pdf.page(at: 1)?.string)
        XCTAssertTrue(secondPage.contains("Page 2 of \(pdf.pageCount)"), secondPage)
        let everything = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(everything.contains("Service 60"), "No row is lost at a page break.")
    }

    // MARK: - Fixtures

    private func date(month: Int, day: Int, hour: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
    }

    /// Ava: two September visits, her first ever. Jordan: one in August (the
    /// previous period) and one in September. Plus a visit still going.
    private func seedSalon() throws {
        let context = ModelContext(container)
        let fullGroom = Service(name: "Full Groom", category: .groom, basePrice: Decimal(100))
        let bath = Service(name: "Bath", category: .groom, basePrice: Decimal(50))
        context.insert(fullGroom)
        context.insert(bath)

        func pet(_ name: String, owner first: String, _ last: String) -> Pet {
            let client = Client(firstName: first, lastName: last)
            context.insert(client)
            let pet = Pet(name: name, species: .dog)
            pet.owner = client
            context.insert(pet)
            return pet
        }
        func finishedVisit(_ pet: Pet, on day: Date, service: Service, price: Int, method: Payment.Method) {
            let visit = Visit(pet: pet, startedAt: day)
            context.insert(visit)
            let item = VisitItem.from(service: service, visit: visit, priceOverride: Decimal(price))
            context.insert(item)
            visit.items = [item]
            let payment = Payment(amount: Decimal(price), method: method, paidAt: day)
            context.insert(payment)
            visit.attachPayment(payment)
            visit.markCheckedOut(total: Decimal(price), now: day.addingTimeInterval(3_600))
        }

        let milo = pet("Milo", owner: "Ava", "Martinez")
        let biscuit = pet("Biscuit", owner: "Jordan", "Lee")
        finishedVisit(milo, on: try date(month: 9, day: 10, hour: 10), service: fullGroom, price: 100, method: .cash)
        finishedVisit(milo, on: try date(month: 9, day: 24, hour: 10), service: bath, price: 60, method: .creditCard)
        finishedVisit(biscuit, on: try date(month: 8, day: 15, hour: 10), service: bath, price: 50, method: .cash)
        finishedVisit(biscuit, on: try date(month: 9, day: 24, hour: 14), service: bath, price: 40, method: .cash)
        context.insert(Visit(pet: biscuit, startedAt: try date(month: 9, day: 30, hour: 9)))
        try context.save()
    }
}
