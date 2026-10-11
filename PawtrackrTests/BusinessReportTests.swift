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

    func testCSVStartsWithOwnerDecisionsThenKeepsSupportingDetail() throws {
        try seedSalon()
        let facts = try BusinessReportFacts.build(in: ModelContext(container), periodDays: 30, now: now, calendar: calendar)
        let review = [BusinessReportReviewItem(title: "Missing phone", count: 2, detail: "Add a phone so reminders reach them.")]
        let csv = BusinessReportCSV.make(facts: facts, businessName: "Repro Grooming", currencySymbol: "$", reviewItems: review, calendar: calendar)
        let lines = csv.csvData.components(separatedBy: "\r\n")

        XCTAssertEqual(lines.first, "Business Owner Insights")
        XCTAssertTrue(lines.contains("Business,Repro Grooming"))
        XCTAssertTrue(lines.contains("Period,2026-09-01,2026-09-30"))
        XCTAssertTrue(lines.contains("Report scope,\"Operational insights from completed visits. Excludes expenses, taxes collected, refunds, and deductions; not a tax report.\""))
        XCTAssertTrue(lines.contains("Metric,This period,Previous period,Change (%)"))
        XCTAssertTrue(lines.contains("Completed visit revenue,200.00,50.00,300"))
        XCTAssertTrue(lines.contains("Recorded payments,200.00,,"))
        XCTAssertTrue(lines.contains("Revenue less recorded payments,0.00,,"))
        XCTAssertTrue(lines.contains("Payment coverage (%),100,,"))
        XCTAssertTrue(lines.contains("Visits,3,1,200"))
        XCTAssertTrue(lines.contains("Revenue per client,100.00,,"))
        XCTAssertTrue(lines.contains("Returning client rate (%),50,,"))
        XCTAssertTrue(lines.contains("Revenue trend,300% vs previous 30 days,Shows whether completed sales are growing."))
        XCTAssertTrue(lines.contains("Returning clients,1 of 2 clients · 50%,Shows how much business came from repeat clients."))
        XCTAssertTrue(lines.contains("Top service,Bath · 50% of service revenue,Shows which service drives the most revenue."))
        XCTAssertTrue(lines.contains("Busiest weekday,Thursday · 3 completed visits,Helps plan staffing and appointment capacity."))
        XCTAssertTrue(lines.contains("Top payment method,Cash · 70% of recorded payments,Helps reconcile where client payments were recorded."))
        XCTAssertTrue(lines.contains("Bath,2,100.00,50"))
        XCTAssertTrue(lines.contains("\(Payment.Method.cash.displayName),2,140.00,70"))
        XCTAssertTrue(lines.contains("Ava Martinez,2,160.00"))
        XCTAssertTrue(lines.contains("2026-08,1,50.00,50.00"))
        XCTAssertTrue(lines.contains("Missing phone,2,Add a phone so reminders reach them."))
        let sections = ["Owner snapshot", "What to focus on", "Monthly performance", "Services", "Payment methods", "Top clients", "Daily revenue", "Data to review"]
        for section in sections {
            let index = try XCTUnwrap(lines.firstIndex(of: section), section)
            XCTAssertEqual(lines[index - 1], "", "\(section) follows a blank line.")
        }
        let sectionIndexes = try sections.map { try XCTUnwrap(lines.firstIndex(of: $0), $0) }
        XCTAssertEqual(sectionIndexes, sectionIndexes.sorted(), "The owner summary comes before supporting detail.")
        XCTAssertEqual(lines.filter { $0.hasPrefix("2026-09-") }.count, 30, "One row per day.")
        XCTAssertTrue(csv.filename.hasPrefix("Pawtrackr_Owner_Insights_2026-09-30"))
    }

    func testCSVSurfacesCompletedRevenueWithoutARecordedPayment() throws {
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

        let csv = BusinessReportCSV.make(
            facts: facts,
            businessName: "Repro Grooming",
            currencySymbol: "$",
            reviewItems: [],
            calendar: calendar
        )
        let lines = csv.csvData.components(separatedBy: "\r\n")

        XCTAssertTrue(lines.contains("Completed visit revenue,120.00,0.00,"))
        XCTAssertTrue(lines.contains("Recorded payments,100.00,,"))
        XCTAssertTrue(lines.contains("Revenue less recorded payments,20.00,,"))
        XCTAssertTrue(lines.contains("Payment coverage (%),83,,"))
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
