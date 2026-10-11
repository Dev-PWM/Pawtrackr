//
//  BusinessReportService.swift
//  Pawtrackr
//
//  The Insights report as a PDF. `makeDocument` turns one period's facts
//  (`BusinessReportFacts`) into translated, formatted text on the main actor,
//  where the app's currency formatter lives. `render` lays that out on
//  Letter pages and draws it off the main actor:
//  - a header with the salon's name, the period and when it was made,
//  - four tiles (revenue, visits, average ticket, clients) with the change
//    on the previous period,
//  - "At a glance": a few plain sentences about what stands out,
//  - the daily revenue chart,
//  - tables for months, services, payment methods and top clients.
//  A table that runs past the page continues on the next one under its
//  header row, and every page has a footer with its number. Colors are fixed
//  print colors: system label colors turn white in Dark Mode.
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Everything the report PDF shows, already formatted and translated.
struct BusinessReportDocument: Sendable {
    enum Trend: Sendable {
        /// No direction to show: nothing earlier to compare, or not a change.
        case up, down, flat, neutral
    }

    struct Tile: Sendable {
        let title: String
        let value: String
        let detail: String
        let trend: Trend
    }

    struct DateLabel: Sendable {
        let index: Int
        let text: String
    }

    struct Chart: Sendable {
        /// One value per day, in order.
        let values: [Double]
        let topLabel: String
        let middleLabel: String
        let bottomLabel: String
        let dateLabels: [DateLabel]
        let emptyText: String
    }

    struct Column: Sendable {
        let title: String
        /// Share of the content width; a table's columns add up to 1.
        let width: CGFloat
        let alignsRight: Bool
    }

    struct Table: Sendable {
        let title: String
        let columns: [Column]
        let rows: [[String]]
        /// 0...1 for each row, drawn as a bar in the last column beside
        /// that cell's text.
        let shares: [Double]?
        let emptyText: String
    }

    let businessName: String
    let title: String
    let periodLine: String
    let generatedLine: String
    let tiles: [Tile]
    let highlightsTitle: String
    let highlights: [String]
    let chartTitle: String
    let chart: Chart
    let tables: [Table]
    let footer: String
    /// "Page %1$d of %2$d".
    let pageFormat: String
    let filename: String
}

enum BusinessReportService {

    // MARK: - Document

    @MainActor
    static func makeDocument(
        facts: BusinessReportFacts,
        businessName: String,
        calendar: Calendar = .current
    ) -> BusinessReportDocument {
        typealias Doc = BusinessReportDocument
        func text(_ key: String, _ value: String) -> String {
            AppLocalization.localized(key, value: value)
        }
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = AppLocalization.currentLocale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        let shortDay = formatter("MMMd")
        let fullDay = formatter("yMMMd")
        let monthName = formatter("yMMM")
        let stamp = formatter("yMMMdjmm")

        let trimmedName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "Pawtrackr" : trimmedName
        let days = facts.periodDays

        // Tiles: the period's numbers and how they moved.
        func change(_ previous: Decimal, _ current: Decimal) -> Change? {
            guard previous > .zero else { return nil }
            let ratio = NSDecimalNumber(decimal: (current - previous) / previous).doubleValue
            let percent = Int((ratio * 100).rounded())
            return Change(trend: percent > 0 ? .up : (percent < 0 ? .down : .flat), percent: abs(percent))
        }
        func detail(_ change: Change?) -> (String, Doc.Trend) {
            guard let change else {
                return (text("report.change_none", "Nothing earlier to compare"), .neutral)
            }
            switch change.trend {
            case .up:
                return (String(format: text("report.change_up_fmt", "▲ %1$d%% vs previous %2$d days"), change.percent, days), .up)
            case .down:
                return (String(format: text("report.change_down_fmt", "▼ %1$d%% vs previous %2$d days"), change.percent, days), .down)
            case .flat, .neutral:
                return (String(format: text("report.change_flat_fmt", "Same as previous %d days"), days), .flat)
            }
        }
        let revenueChange = change(facts.previousRevenue, facts.revenue)
        let visitsChange = change(Decimal(facts.previousVisits), Decimal(facts.visits))
        let ticketChange = facts.previousVisits > 0 ? change(facts.previousAverageTicket, facts.averageTicket) : nil
        let revenueDetail = detail(revenueChange)
        let visitsDetail = detail(visitsChange)
        let ticketDetail = detail(ticketChange)
        let tiles = [
            Doc.Tile(title: text("report.revenue", "Revenue"), value: facts.revenue.moneyString, detail: revenueDetail.0, trend: revenueDetail.1),
            Doc.Tile(title: text("report.visits", "Visits"), value: "\(facts.visits)", detail: visitsDetail.0, trend: visitsDetail.1),
            Doc.Tile(title: text("report.average_ticket", "Average visit"), value: facts.averageTicket.moneyString, detail: ticketDetail.0, trend: ticketDetail.1),
            Doc.Tile(
                title: text("report.clients", "Clients"),
                value: "\(facts.clients)",
                detail: String(format: text("report.clients_detail_fmt", "%1$d first-time · %2$d returning"), facts.firstTimeClients, facts.returningClients),
                trend: .neutral
            )
        ]

        // At a glance: what stands out, in plain sentences.
        let serviceTotal = facts.services.reduce(Decimal.zero) { $0 + $1.amount }
        let paidTotal = facts.payments.reduce(Decimal.zero) { $0 + $1.amount }
        var highlights: [String] = []
        if facts.visits == 0 {
            highlights.append(text("report.highlight.empty", "No finished visits in this period yet. Checkouts show up here as they happen."))
        } else {
            if let revenueChange {
                switch revenueChange.trend {
                case .up:
                    highlights.append(String(format: text("report.highlight.revenue_up_fmt", "Revenue is up %1$d%% on the previous %2$d days, at %3$@."), revenueChange.percent, days, facts.revenue.moneyString))
                case .down:
                    highlights.append(String(format: text("report.highlight.revenue_down_fmt", "Revenue is down %1$d%% on the previous %2$d days, at %3$@."), revenueChange.percent, days, facts.revenue.moneyString))
                case .flat, .neutral:
                    highlights.append(String(format: text("report.highlight.revenue_flat_fmt", "Revenue held steady at %1$@ compared with the previous %2$d days."), facts.revenue.moneyString, days))
                }
            } else {
                highlights.append(String(format: text("report.highlight.revenue_new_fmt", "%1$@ from %2$d visits. The previous %3$d days had no finished visits."), facts.revenue.moneyString, facts.visits, days))
            }
            if let top = facts.services.first, serviceTotal > .zero {
                highlights.append(String(format: text("report.highlight.top_service_fmt", "%1$@ earned the most: %2$@, %3$d%% of service sales."), top.name, top.amount.moneyString, percent(top.amount, of: serviceTotal)))
            }
            if facts.clients > 0 {
                if facts.firstTimeClients > 0 {
                    highlights.append(String(format: text("report.highlight.clients_fmt", "%1$d clients came in, %2$d of them for the first time."), facts.clients, facts.firstTimeClients))
                } else {
                    highlights.append(String(format: text("report.highlight.clients_returning_fmt", "%d clients came in, all of them returning."), facts.clients))
                }
            }
            if facts.visits >= 3, let busiest = facts.busiestWeekday, busiest.visits >= 2 {
                var localCalendar = calendar
                localCalendar.locale = AppLocalization.currentLocale
                let names = localCalendar.weekdaySymbols
                if names.indices.contains(busiest.weekday - 1) {
                    highlights.append(String(format: text("report.highlight.busiest_day_fmt", "%1$@ was the busiest day of the week, with %2$d visits."), names[busiest.weekday - 1], busiest.visits))
                }
            }
            if let method = facts.payments.first, paidTotal > .zero {
                highlights.append(String(format: text("report.highlight.payment_fmt", "%1$@ covers %2$d%% of what clients paid."), method.name, percent(method.amount, of: paidTotal)))
            }
        }

        // The daily chart.
        let peak = facts.days.map(\.revenue).max() ?? .zero
        var labelIndexes: [Int] = []
        if !facts.days.isEmpty {
            for index in [0, facts.days.count / 2, facts.days.count - 1] where !labelIndexes.contains(index) {
                labelIndexes.append(index)
            }
        }
        let chart = Doc.Chart(
            values: facts.days.map { NSDecimalNumber(decimal: $0.revenue).doubleValue },
            topLabel: peak.moneyString,
            middleLabel: (peak / 2).roundedMoney().moneyString,
            bottomLabel: Decimal.zero.moneyString,
            dateLabels: labelIndexes.map { Doc.DateLabel(index: $0, text: shortDay.string(from: facts.days[$0].date)) },
            emptyText: text("report.chart_empty", "No revenue in this period yet.")
        )

        // Tables.
        let noVisits = text("report.no_visits", "No finished visits in this period.")
        let revenueTitle = text("report.revenue", "Revenue")
        let visitsTitle = text("report.visits", "Visits")
        let shareTitle = text("report.share", "Share")
        let tables: [Doc.Table] = [
            Doc.Table(
                title: text("report.monthly", "Monthly performance"),
                columns: [
                    Doc.Column(title: text("report.month", "Month"), width: 0.36, alignsRight: false),
                    Doc.Column(title: visitsTitle, width: 0.16, alignsRight: true),
                    Doc.Column(title: revenueTitle, width: 0.24, alignsRight: true),
                    Doc.Column(title: text("report.average_ticket", "Average visit"), width: 0.24, alignsRight: true)
                ],
                rows: facts.months.map {
                    [
                        monthName.string(from: $0.start),
                        "\($0.visits)",
                        $0.revenue.moneyString,
                        BusinessReportFacts.average($0.revenue, over: $0.visits).moneyString
                    ]
                },
                shares: nil,
                emptyText: noVisits
            ),
            Doc.Table(
                title: text("report.services", "Services"),
                columns: [
                    Doc.Column(title: text("report.service", "Service"), width: 0.38, alignsRight: false),
                    Doc.Column(title: text("report.sales", "Sales"), width: 0.12, alignsRight: true),
                    Doc.Column(title: revenueTitle, width: 0.2, alignsRight: true),
                    Doc.Column(title: shareTitle, width: 0.3, alignsRight: true)
                ],
                rows: facts.services.map {
                    ["\($0.name)", "\($0.count)", $0.amount.moneyString, "\(percent($0.amount, of: serviceTotal))%"]
                },
                shares: facts.services.map { share($0.amount, of: serviceTotal) },
                emptyText: noVisits
            ),
            Doc.Table(
                title: text("report.payment_methods", "Payment methods"),
                columns: [
                    Doc.Column(title: text("report.method", "Method"), width: 0.38, alignsRight: false),
                    Doc.Column(title: text("report.payments", "Payments"), width: 0.12, alignsRight: true),
                    Doc.Column(title: text("report.amount", "Amount"), width: 0.2, alignsRight: true),
                    Doc.Column(title: shareTitle, width: 0.3, alignsRight: true)
                ],
                rows: facts.payments.map {
                    [$0.name, "\($0.count)", $0.amount.moneyString, "\(percent($0.amount, of: paidTotal))%"]
                },
                shares: facts.payments.map { share($0.amount, of: paidTotal) },
                emptyText: noVisits
            ),
            Doc.Table(
                title: text("report.top_clients", "Top clients"),
                columns: [
                    Doc.Column(title: text("report.client", "Client"), width: 0.56, alignsRight: false),
                    Doc.Column(title: visitsTitle, width: 0.16, alignsRight: true),
                    Doc.Column(title: text("report.spend", "Spend"), width: 0.28, alignsRight: true)
                ],
                rows: facts.topClients.map { [$0.name, "\($0.count)", $0.amount.moneyString] },
                shares: nil,
                emptyText: noVisits
            )
        ]
        return BusinessReportDocument(
            businessName: displayName,
            title: text("report.title", "Business Report"),
            periodLine: String(
                format: text("report.period_fmt", "Last %1$d days · %2$@ – %3$@"),
                days,
                shortDay.string(from: facts.periodStart),
                fullDay.string(from: facts.periodLastDay)
            ),
            generatedLine: String(format: text("report.generated_fmt", "Generated %@"), stamp.string(from: facts.generatedAt)),
            tiles: tiles,
            highlightsTitle: text("report.at_a_glance", "At a glance"),
            highlights: highlights,
            chartTitle: text("report.daily_revenue", "Daily revenue"),
            chart: chart,
            tables: tables,
            footer: displayName == "Pawtrackr" ? "Pawtrackr" : "Pawtrackr · \(displayName)",
            pageFormat: text("report.page_fmt", "Page %1$d of %2$d"),
            filename: "Pawtrackr_Report_\(CSVDateFormats(timeZone: calendar.timeZone).day(facts.generatedAt)).pdf"
        )
    }

    private struct Change {
        let trend: BusinessReportDocument.Trend
        let percent: Int
    }

    private static func share(_ part: Decimal, of whole: Decimal) -> Double {
        guard whole > .zero else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: part / whole).doubleValue))
    }

    private static func percent(_ part: Decimal, of whole: Decimal) -> Int {
        Int((share(part, of: whole) * 100).rounded())
    }

    // MARK: - Rendering

    static func renderAsync(_ document: BusinessReportDocument) async -> Data {
        await Task.detached(priority: .userInitiated) {
            Self.render(document)
        }.value
    }

    static func render(_ document: BusinessReportDocument) -> Data {
        let pages = paginate(blocks(for: document))
        return PDFCanvas.render(bounds: Layout.page, pageCount: pages.count) { index, context in
            for placed in pages[index] {
                placed.draw(context, placed.y)
            }
            drawFooter(document, page: index, of: pages.count, in: context)
        }
    }

    private typealias Drawer = (CGContext, CGFloat) -> Void

    private struct Block {
        let height: CGFloat
        var spacingAfter: CGFloat = 0
        /// Starts a new page together with the block after it: section
        /// titles and table headers never end a page on their own.
        var keepsWithNext = false
        /// Drawn first when this block has to start a new page: a table's
        /// header row above its continuing rows.
        var header: (height: CGFloat, draw: Drawer)?
        let draw: Drawer
    }

    private struct Placed {
        let y: CGFloat
        let draw: Drawer
    }

    private enum Layout {
        static let page = PDFCanvas.letter
        static let margin: CGFloat = 40
        static let contentWidth = page.width - margin * 2
        static let top: CGFloat = 40
        static let footerTop = page.height - 36
        static let bottom = footerTop - 12
    }

    private enum Palette {
        static var ink: PlatformColor { color(17, 24, 39) }
        static var body: PlatformColor { color(55, 65, 81) }
        static var muted: PlatformColor { color(107, 114, 128) }
        static var hairline: PlatformColor { color(229, 231, 235) }
        static var surface: PlatformColor { color(248, 250, 252) }
        static var accent: PlatformColor { color(79, 70, 229) }
        static var accentSoft: PlatformColor { color(238, 242, 255) }
        static var positive: PlatformColor { color(5, 150, 105) }
        static var negative: PlatformColor { color(220, 38, 38) }
        static var bar: PlatformColor { color(16, 185, 129) }

        static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> PlatformColor {
            PlatformColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        }
    }

    private static func paginate(_ blocks: [Block]) -> [[Placed]] {
        var pages: [[Placed]] = [[]]
        var y = Layout.top
        for (index, block) in blocks.enumerated() {
            // The block and every block it must stay with.
            var needed = block.height
            var next = index
            while blocks[next].keepsWithNext, next + 1 < blocks.count {
                needed += blocks[next].spacingAfter + blocks[next + 1].height
                next += 1
            }
            if y + needed > Layout.bottom, y > Layout.top {
                pages.append([])
                y = Layout.top
                if let header = block.header {
                    pages[pages.count - 1].append(Placed(y: y, draw: header.draw))
                    y += header.height
                }
            }
            pages[pages.count - 1].append(Placed(y: y, draw: block.draw))
            y += block.height + block.spacingAfter
        }
        return pages
    }

    private static func blocks(for document: BusinessReportDocument) -> [Block] {
        var blocks = [headerBlock(document), tilesBlock(document)]
        if !document.highlights.isEmpty {
            blocks.append(highlightsBlock(document))
        }
        blocks.append(sectionTitle(document.chartTitle))
        blocks.append(chartBlock(document.chart))
        for table in document.tables {
            blocks += tableBlocks(table)
        }
        return blocks
    }

    // MARK: Blocks

    private static func headerBlock(_ document: BusinessReportDocument) -> Block {
        Block(height: 62, spacingAfter: 18) { context, y in
            fill(CGRect(x: 0, y: 0, width: Layout.page.width, height: 6), Palette.accent, in: context)
            let left = Layout.margin
            let width = Layout.contentWidth
            draw(document.generatedLine, in: CGRect(x: left, y: y + 6, width: width, height: 14),
                 attributes: attributes(font(9), Palette.muted, alignment: .right))
            draw(document.businessName, in: CGRect(x: left, y: y, width: width - 190, height: 28),
                 attributes: attributes(font(22, .bold), Palette.ink, lineBreak: .byTruncatingTail))
            draw(document.title.uppercased(), in: CGRect(x: left, y: y + 31, width: width, height: 14),
                 attributes: attributes(font(9.5, .semibold), Palette.accent, kern: 1.2))
            draw(document.periodLine, in: CGRect(x: left, y: y + 46, width: width, height: 14),
                 attributes: attributes(font(10), Palette.muted))
        }
    }

    private static func tilesBlock(_ document: BusinessReportDocument) -> Block {
        let tileHeight: CGFloat = 76
        return Block(height: tileHeight, spacingAfter: 18) { context, y in
            let gap: CGFloat = 10
            let count = CGFloat(max(1, document.tiles.count))
            let tileWidth = (Layout.contentWidth - gap * (count - 1)) / count
            for (index, tile) in document.tiles.enumerated() {
                let rect = CGRect(x: Layout.margin + CGFloat(index) * (tileWidth + gap), y: y, width: tileWidth, height: tileHeight)
                fill(rect, Palette.surface, radius: 8, in: context)
                stroke(rect, Palette.hairline, radius: 8, in: context)
                fill(CGRect(x: rect.minX, y: rect.minY + 12, width: 3, height: 22), Palette.accent, radius: 1.5, in: context)
                let inner = rect.insetBy(dx: 12, dy: 0)
                draw(tile.title.uppercased(), in: CGRect(x: inner.minX, y: rect.minY + 11, width: inner.width, height: 12),
                     attributes: attributes(font(7.5, .semibold), Palette.muted, lineBreak: .byTruncatingTail, kern: 0.6))
                draw(tile.value, in: CGRect(x: inner.minX, y: rect.minY + 25, width: inner.width, height: 24),
                     attributes: attributes(digits(17, .bold), Palette.ink, lineBreak: .byTruncatingTail))
                let trendColor: PlatformColor
                switch tile.trend {
                case .up: trendColor = Palette.positive
                case .down: trendColor = Palette.negative
                case .flat, .neutral: trendColor = Palette.muted
                }
                draw(tile.detail, in: CGRect(x: inner.minX, y: rect.minY + 51, width: inner.width, height: 22),
                     attributes: attributes(font(7.5, .medium), trendColor))
            }
        }
    }

    private static func highlightsBlock(_ document: BusinessReportDocument) -> Block {
        let textLeft = Layout.margin + 30
        let textWidth = Layout.contentWidth - 46
        let bodyAttributes = attributes(font(10), Palette.body)
        let heights = document.highlights.map { height(of: $0, width: textWidth, attributes: bodyAttributes) }
        let total = 34 + heights.reduce(0) { $0 + $1 + 6 } + 6
        return Block(height: total, spacingAfter: 20) { context, y in
            let rect = CGRect(x: Layout.margin, y: y, width: Layout.contentWidth, height: total)
            fill(rect, Palette.accentSoft, radius: 10, in: context)
            draw(document.highlightsTitle, in: CGRect(x: Layout.margin + 16, y: y + 12, width: textWidth, height: 16),
                 attributes: attributes(font(11, .bold), Palette.accent))
            var lineY = y + 34
            for (sentence, lineHeight) in zip(document.highlights, heights) {
                fill(CGRect(x: Layout.margin + 18, y: lineY + 5, width: 5, height: 5), Palette.accent, radius: 2.5, in: context)
                draw(sentence, in: CGRect(x: textLeft, y: lineY, width: textWidth, height: lineHeight + 2), attributes: bodyAttributes)
                lineY += lineHeight + 6
            }
        }
    }

    private static func sectionTitle(_ title: String) -> Block {
        Block(height: 18, spacingAfter: 8, keepsWithNext: true) { _, y in
            draw(title, in: CGRect(x: Layout.margin, y: y, width: Layout.contentWidth, height: 18),
                 attributes: attributes(font(13, .bold), Palette.ink))
        }
    }

    private static func chartBlock(_ chart: BusinessReportDocument.Chart) -> Block {
        Block(height: 160, spacingAfter: 22) { context, y in
            let axisWidth: CGFloat = 58
            let plot = CGRect(x: Layout.margin + axisWidth, y: y + 6, width: Layout.contentWidth - axisWidth, height: 128)
            let axisAttributes = attributes(digits(7.5), Palette.muted, alignment: .right)
            for (fraction, label) in [(0.0, chart.bottomLabel), (0.5, chart.middleLabel), (1.0, chart.topLabel)] {
                let lineY = plot.maxY - plot.height * CGFloat(fraction)
                line(from: CGPoint(x: plot.minX, y: lineY), to: CGPoint(x: plot.maxX, y: lineY), Palette.hairline, in: context)
                draw(label, in: CGRect(x: Layout.margin, y: lineY - 5, width: axisWidth - 8, height: 11), attributes: axisAttributes)
            }

            let slot = plot.width / CGFloat(max(1, chart.values.count))
            let peak = chart.values.max() ?? 0
            if peak > 0 {
                let barWidth = max(1.5, min(22, slot * 0.64))
                for (index, value) in chart.values.enumerated() where value > 0 {
                    let barHeight = max(1.5, plot.height * CGFloat(value / peak))
                    let bar = CGRect(
                        x: plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2,
                        y: plot.maxY - barHeight,
                        width: barWidth,
                        height: barHeight
                    )
                    fill(bar, Palette.accent, radius: min(3, barWidth / 2), in: context)
                }
            } else {
                draw(chart.emptyText, in: CGRect(x: plot.minX, y: plot.midY - 7, width: plot.width, height: 14),
                     attributes: attributes(font(10), Palette.muted, alignment: .center))
            }

            let labelWidth: CGFloat = 80
            for label in chart.dateLabels {
                let center = plot.minX + slot * (CGFloat(label.index) + 0.5)
                let x = min(max(center - labelWidth / 2, plot.minX), plot.maxX - labelWidth)
                draw(label.text, in: CGRect(x: x, y: plot.maxY + 6, width: labelWidth, height: 12),
                     attributes: attributes(font(7.5), Palette.muted, alignment: .center))
            }
        }
    }

    private static func tableBlocks(_ table: BusinessReportDocument.Table) -> [Block] {
        var blocks = [sectionTitle(table.title)]
        let columnWidths = table.columns.map { $0.width * Layout.contentWidth }
        var starts: [CGFloat] = []
        var x = Layout.margin
        for width in columnWidths {
            starts.append(x)
            x += width
        }
        let columnStarts = starts

        let headerHeight: CGFloat = 22
        let drawHeader: Drawer = { context, y in
            fill(CGRect(x: Layout.margin, y: y, width: Layout.contentWidth, height: headerHeight), Palette.surface, radius: 6, in: context)
            for (index, column) in table.columns.enumerated() {
                draw(column.title.uppercased(),
                     in: CGRect(x: columnStarts[index] + 8, y: y + 7, width: columnWidths[index] - 16, height: 11),
                     attributes: attributes(font(7.5, .semibold), Palette.muted, alignment: column.alignsRight ? .right : .left, lineBreak: .byTruncatingTail, kern: 0.5))
            }
        }
        blocks.append(Block(height: headerHeight, keepsWithNext: true, draw: drawHeader))

        guard !table.rows.isEmpty else {
            blocks.append(Block(height: 28, spacingAfter: 20) { _, y in
                draw(table.emptyText, in: CGRect(x: Layout.margin + 8, y: y + 8, width: Layout.contentWidth - 16, height: 14),
                     attributes: attributes(font(9.5), Palette.muted))
            })
            return blocks
        }

        let lastColumn = table.columns.count - 1
        for (rowIndex, row) in table.rows.enumerated() {
            let share = table.shares.flatMap { $0.indices.contains(rowIndex) ? $0[rowIndex] : nil }
            let cellAttributes: [[NSAttributedString.Key: Any]] = table.columns.enumerated().map { index, column in
                attributes(index == 0 ? font(9.5, .medium) : digits(9.5), index == 0 ? Palette.ink : Palette.body,
                           alignment: column.alignsRight ? .right : .left)
            }
            var measured: CGFloat = 22
            for (index, cell) in row.enumerated() where index < table.columns.count && !(index == lastColumn && share != nil) {
                measured = max(measured, height(of: cell, width: columnWidths[index] - 16, attributes: cellAttributes[index]) + 10)
            }
            let rowHeight = measured
            let isLast = rowIndex == table.rows.count - 1
            blocks.append(Block(height: rowHeight, spacingAfter: isLast ? 22 : 0, header: (headerHeight, drawHeader)) { context, y in
                for (index, cell) in row.enumerated() where index < table.columns.count {
                    let cellX = columnStarts[index] + 8
                    let cellWidth = columnWidths[index] - 16
                    if index == lastColumn, let share {
                        let percentWidth: CGFloat = 34
                        let track = CGRect(x: cellX, y: y + rowHeight / 2 - 3, width: max(0, cellWidth - percentWidth - 6), height: 6)
                        fill(track, Palette.hairline, radius: 3, in: context)
                        fill(CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(share), height: track.height), Palette.bar, radius: 3, in: context)
                        draw(cell, in: CGRect(x: cellX + cellWidth - percentWidth, y: y + 5, width: percentWidth, height: rowHeight - 8),
                             attributes: attributes(digits(9.5), Palette.body, alignment: .right))
                    } else {
                        draw(cell, in: CGRect(x: cellX, y: y + 5, width: cellWidth, height: rowHeight - 8), attributes: cellAttributes[index])
                    }
                }
                line(from: CGPoint(x: Layout.margin, y: y + rowHeight), to: CGPoint(x: Layout.margin + Layout.contentWidth, y: y + rowHeight), Palette.hairline, in: context)
            })
        }
        return blocks
    }

    private static func drawFooter(_ document: BusinessReportDocument, page: Int, of count: Int, in context: CGContext) {
        let y = Layout.footerTop
        line(from: CGPoint(x: Layout.margin, y: y), to: CGPoint(x: Layout.margin + Layout.contentWidth, y: y), Palette.hairline, in: context)
        let half = Layout.contentWidth / 2
        draw(document.footer, in: CGRect(x: Layout.margin, y: y + 8, width: half, height: 12),
             attributes: attributes(font(8), Palette.muted, lineBreak: .byTruncatingTail))
        draw(String(format: document.pageFormat, page + 1, count), in: CGRect(x: Layout.margin + half, y: y + 8, width: half, height: 12),
             attributes: attributes(font(8), Palette.muted, alignment: .right))
    }

    // MARK: Drawing helpers

    private static func font(_ size: CGFloat, _ weight: PlatformFont.Weight = .regular) -> PlatformFont {
        PlatformFont.systemFont(ofSize: size, weight: weight)
    }

    /// Figures line up in columns.
    private static func digits(_ size: CGFloat, _ weight: PlatformFont.Weight = .regular) -> PlatformFont {
        PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func attributes(
        _ font: PlatformFont,
        _ color: PlatformColor,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byWordWrapping,
        kern: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if kern != 0 {
            result[.kern] = kern
        }
        return result
    }

    private static func height(of text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(bounds.height)
    }

    private static func draw(_ text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }

    private static func fill(_ rect: CGRect, _ color: PlatformColor, radius: CGFloat = 0, in context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.setFillColor(color.cgColor)
        let cornerRadius = min(radius, rect.width / 2, rect.height / 2)
        if cornerRadius > 0 {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    private static func stroke(_ rect: CGRect, _ color: PlatformColor, radius: CGFloat, in context: CGContext) {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let cornerRadius = min(radius, inset.width / 2, inset.height / 2)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.strokePath()
    }

    private static func line(from start: CGPoint, to end: CGPoint, _ color: PlatformColor, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(0.75)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }
}
