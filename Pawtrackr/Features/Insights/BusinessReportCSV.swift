//
//  BusinessReportCSV.swift
//  Pawtrackr
//
//  The Insights report as a spreadsheet: an owner-first snapshot and the
//  signals worth acting on, followed by supporting monthly, service,
//  payment, client, and daily detail. Numbers stay plain so every column can
//  be summed or charted.
//  Safe off the main actor.
//

import Foundation

/// Something in the salon's records worth a look (Insights' data quality
/// checks), as the report lists it.
struct BusinessReportReviewItem: Sendable, Equatable {
    let title: String
    let count: Int
    let detail: String
}

enum BusinessReportCSV {
    static func make(
        facts: BusinessReportFacts,
        businessName: String,
        currencySymbol: String,
        reviewItems: [BusinessReportReviewItem],
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
        let paymentDifference = (facts.revenue - paidTotal).roundedMoney()
        let returningRate = CSVFormat.percent(Decimal(facts.returningClients), of: Decimal(facts.clients))

        var rows: [[String]] = [
            [label("report.csv.owner_title", "Business Owner Insights")],
            [label("report.business", "Business"), CSVFormat.text(businessName)],
            [label("report.period", "Period"), dates.day(facts.periodStart), dates.day(facts.periodLastDay)],
            [label("report.days", "Days"), count(facts.periodDays)],
            [label("report.generated", "Generated"), dates.stamp(facts.generatedAt)],
            [label("report.currency", "Currency"), CSVFormat.text(currencySymbol)],
            [
                label("report.scope", "Report scope"),
                CSVFormat.text(localized(
                    "report.scope.operational",
                    "Operational insights from completed visits. Excludes expenses, taxes collected, refunds, and deductions; not a tax report."
                ))
            ],
            []
        ]

        rows += [
            [label("report.owner_snapshot", "Owner snapshot")],
            [
                label("report.metric", "Metric"),
                label("report.this_period", "This period"),
                label("report.previous_period", "Previous period"),
                label("report.change_percent", "Change (%)")
            ],
            [
                label("report.completed_visit_revenue", "Completed visit revenue"),
                money(facts.revenue),
                money(facts.previousRevenue),
                CSVFormat.change(from: facts.previousRevenue, to: facts.revenue)
            ],
            [label("report.recorded_payments", "Recorded payments"), money(paidTotal), "", ""],
            [label("report.revenue_less_payments", "Revenue less recorded payments"), money(paymentDifference), "", ""],
            [label("report.payment_coverage_percent", "Payment coverage (%)"), CSVFormat.percent(paidTotal, of: facts.revenue), "", ""],
            [
                label("report.visits", "Visits"),
                count(facts.visits),
                count(facts.previousVisits),
                CSVFormat.change(from: Decimal(facts.previousVisits), to: Decimal(facts.visits))
            ],
            [
                label("report.average_ticket", "Average visit"),
                money(facts.averageTicket),
                facts.previousVisits > 0 ? money(facts.previousAverageTicket) : "",
                facts.previousVisits > 0 ? CSVFormat.change(from: facts.previousAverageTicket, to: facts.averageTicket) : ""
            ],
            [label("report.clients_served", "Clients served"), count(facts.clients), "", ""],
            [
                label("report.revenue_per_client", "Revenue per client"),
                facts.clients > 0 ? money(BusinessReportFacts.average(facts.revenue, over: facts.clients)) : "",
                "",
                ""
            ],
            [label("report.first_time_clients", "First-time clients"), count(facts.firstTimeClients), "", ""],
            [label("report.returning_clients", "Returning clients"), count(facts.returningClients), "", ""],
            [label("report.returning_client_rate", "Returning client rate (%)"), returningRate, "", ""],
            []
        ]

        rows += [
            [label("report.owner_focus", "What to focus on")],
            [label("report.focus", "Focus"), label("report.result", "Result"), label("report.why_it_matters", "Why it matters")]
        ]
        if facts.visits == 0 {
            rows.append([CSVFormat.text(localized("report.no_visits", "No finished visits in this period.")), "", ""])
        } else {
            let revenueResult: String
            let revenueChange = CSVFormat.change(from: facts.previousRevenue, to: facts.revenue)
            if revenueChange.isEmpty {
                revenueResult = localized("report.change_none", "Nothing earlier to compare")
            } else {
                revenueResult = String(
                    format: localized("report.focus.revenue_result_fmt", "%1$@%% vs previous %2$d days"),
                    revenueChange,
                    facts.periodDays
                )
            }
            rows.append([
                label("report.focus.revenue_trend", "Revenue trend"),
                CSVFormat.text(revenueResult),
                label("report.focus.revenue_use", "Shows whether completed sales are growing.")
            ])

            if facts.clients > 0 {
                let result = String(
                    format: localized("report.focus.returning_result_fmt", "%1$d of %2$d clients · %3$@%%"),
                    facts.returningClients,
                    facts.clients,
                    returningRate
                )
                rows.append([
                    label("report.focus.returning_clients", "Returning clients"),
                    CSVFormat.text(result),
                    label("report.focus.returning_use", "Shows how much business came from repeat clients.")
                ])
            }

            if let topService = facts.services.first {
                let result = String(
                    format: localized("report.focus.service_result_fmt", "%1$@ · %2$@%% of service revenue"),
                    topService.name,
                    CSVFormat.percent(topService.amount, of: serviceTotal)
                )
                rows.append([
                    label("report.focus.top_service", "Top service"),
                    CSVFormat.text(result),
                    label("report.focus.service_use", "Shows which service drives the most revenue.")
                ])
            }

            if let busiest = facts.busiestWeekday {
                let weekdayName = weekdayNames.indices.contains(busiest.weekday - 1) ? weekdayNames[busiest.weekday - 1] : ""
                let result = String(
                    format: localized("report.focus.weekday_result_fmt", "%1$@ · %2$d completed visits"),
                    weekdayName,
                    busiest.visits
                )
                rows.append([
                    label("report.focus.busiest_weekday", "Busiest weekday"),
                    CSVFormat.text(result),
                    label("report.focus.weekday_use", "Helps plan staffing and appointment capacity.")
                ])
            }

            if let topPayment = facts.payments.first {
                let result = String(
                    format: localized("report.focus.payment_result_fmt", "%1$@ · %2$@%% of recorded payments"),
                    topPayment.name,
                    CSVFormat.percent(topPayment.amount, of: paidTotal)
                )
                rows.append([
                    label("report.focus.top_payment_method", "Top payment method"),
                    CSVFormat.text(result),
                    label("report.focus.payment_use", "Helps reconcile where client payments were recorded.")
                ])
            }
        }
        rows.append([])

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
            [label("report.top_clients", "Top clients")],
            [label("report.client", "Client"), label("report.visits", "Visits"), label("report.spend", "Spend")]
        ]
        rows += facts.topClients.map { [CSVFormat.text($0.name), count($0.count), money($0.amount)] }
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

        if !reviewItems.isEmpty {
            rows += [
                [],
                [label("report.data_to_review", "Data to review")],
                [label("report.issue", "Issue"), label("report.count", "Count"), label("report.detail", "Detail")]
            ]
            rows += reviewItems.map { [CSVFormat.text($0.title), count($0.count), CSVFormat.text($0.detail)] }
        }

        return ExportDocument(
            csvData: CSVFormat.document(rows),
            filename: "Pawtrackr_Owner_Insights_\(dates.day(facts.generatedAt)).csv"
        )
    }
}
