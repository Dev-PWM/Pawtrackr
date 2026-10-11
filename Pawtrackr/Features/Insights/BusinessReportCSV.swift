//
//  BusinessReportCSV.swift
//  Pawtrackr
//
//  The Insights CSV keeps the report dates and four business tables:
//  monthly performance, services, payment methods, and daily revenue.
//  Numbers stay plain so every column can be summed or charted.
//  Safe off the main actor.
//

import Foundation

enum BusinessReportCSV {
    /// Exports report dates and the four business performance tables.
    static func make(
        facts: BusinessReportFacts,
        calendar: Calendar = .current
    ) -> ExportDocument {
        let dates = CSVDateFormats(timeZone: calendar.timeZone)
        var weekdayCalendar = calendar
        weekdayCalendar.locale = AppLocalization.currentLocale
        let weekdayNames = weekdayCalendar.weekdaySymbols

        func localized(_ key: String, _ value: String) -> String {
            AppLocalization.localized(key, value: value)
        }
        func label(_ key: String, _ value: String) -> String {
            CSVFormat.text(localized(key, value))
        }
        let money = CSVFormat.money
        let count = CSVFormat.integer
        let serviceTotal = facts.services.reduce(Decimal.zero) { $0 + $1.amount }
        let paidTotal = facts.payments.reduce(Decimal.zero) { $0 + $1.amount }
        var rows: [[String]] = [
            [label("report.period", "Period"), dates.day(facts.periodStart), dates.day(facts.periodLastDay)],
            [label("report.generated", "Generated"), dates.stamp(facts.generatedAt)],
            []
        ]

        rows += [
            [label("report.monthly", "Monthly performance")],
            [label("report.month", "Month"), label("report.visits", "Visits"), label("report.revenue", "Revenue"), label("report.average_ticket", "Average visit")]
        ]
        rows += facts.months.map {
            [dates.month($0.start), count($0.visits), money($0.revenue), money(BusinessReportFacts.average($0.revenue, over: $0.visits))]
        }
        rows.append([])

        rows += [
            [label("report.services", "Services")],
            [label("report.service", "Service"), label("report.sales", "Sales"), label("report.revenue", "Revenue"), label("report.share_percent", "Share (%)")]
        ]
        rows += facts.services.map {
            [CSVFormat.text($0.name), count($0.count), money($0.amount), CSVFormat.percent($0.amount, of: serviceTotal)]
        }
        rows.append([])

        rows += [
            [label("report.payment_methods", "Payment methods")],
            [label("report.method", "Method"), label("report.payments", "Payments"), label("report.amount", "Amount"), label("report.share_percent", "Share (%)")]
        ]
        rows += facts.payments.map {
            [CSVFormat.text($0.name), count($0.count), money($0.amount), CSVFormat.percent($0.amount, of: paidTotal)]
        }
        rows.append([])

        rows += [
            [label("report.daily_revenue", "Daily revenue")],
            [label("report.date", "Date"), label("report.weekday", "Weekday"), label("report.visits", "Visits"), label("report.revenue", "Revenue")]
        ]
        for day in facts.days {
            let weekday = calendar.component(.weekday, from: day.date)
            let name = weekdayNames.indices.contains(weekday - 1) ? weekdayNames[weekday - 1] : ""
            rows.append([dates.day(day.date), CSVFormat.text(name), count(day.visits), money(day.revenue)])
        }

        return ExportDocument(
            csvData: CSVFormat.document(rows),
            filename: "Pawtrackr_Owner_Insights_\(dates.day(facts.generatedAt)).csv"
        )
    }
}
