//
//  PDFReceiptService.swift
//  Pawtrackr
//
//  Generates a professional PDF receipt for a Visit.
//  Snapshot is built on the main actor (uses SwiftData + main-actor formatters);
//  rendering runs nonisolated so it can execute off the main thread.
//

import Foundation
import SwiftUI
import PDFKit
import SwiftData
import OSLog

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#endif

struct ReceiptSnapshot: Sendable {
    struct Item: Sendable {
        let name: String
        let priceString: String
    }
    struct PaymentInfo: Sendable {
        let infoLine: String
        let referenceLine: String?
    }

    let businessName: String
    let businessAddress: String?
    let contactLine: String?
    let receiptNumber: String
    let clientName: String
    let clientPhoneFormatted: String?
    let petLine: String
    let dateLine: String
    let items: [Item]
    let totalString: String
    let payment: PaymentInfo?
}

final class PDFReceiptService {
    static let shared = PDFReceiptService()

    @MainActor
    func generatePDF(for visit: Visit) -> Data {
        let snapshot = makeSnapshot(for: visit)
        return Self.render(snapshot: snapshot)
    }

    @MainActor
    func makeSnapshot(for visit: Visit) -> ReceiptSnapshot {
        let config: BusinessConfig
        if let modelContext = visit.modelContext {
            let descriptor = FetchDescriptor<BusinessConfig>()
            let configs: [BusinessConfig]
            do {
                configs = try modelContext.fetch(descriptor)
            } catch {
                Logger.pdfReceipt.error("BusinessConfig fetch failed: \(String(describing: error))")
                configs = []
            }
            config = configs.first(where: \.isSetupComplete) ?? configs.first ?? .default
        } else {
            config = .default
        }

        let contactParts = [config.email, config.phone].compactMap { $0 }.filter { !$0.isEmpty }
        let contactLine = contactParts.isEmpty ? nil : contactParts.joined(separator: " | ")

        let dateSource = visit.endedAt ?? visit.startedAt
        let dateLine = "Date: " + dateSource.formatted(date: .long, time: .shortened)

        let phone = visit.pet?.owner?.phone
        let phoneFormatted = phone.flatMap { PhoneUtils.display($0) ?? $0 }

        let items = (visit.items ?? []).map { item in
            ReceiptSnapshot.Item(name: item.name, priceString: item.lineTotal.moneyString)
        }

        let payment: ReceiptSnapshot.PaymentInfo?
        if let p = visit.payment {
            let infoLine = "Paid via \(p.method.displayName) on \(p.paidAt.formatted(date: .abbreviated, time: .omitted))"
            let refLine = p.externalReference.map { "Reference: \($0)" }
            payment = .init(infoLine: infoLine, referenceLine: refLine)
        } else {
            payment = nil
        }

        return ReceiptSnapshot(
            businessName: config.name,
            businessAddress: config.address?.isEmpty == false ? config.address : nil,
            contactLine: contactLine,
            receiptNumber: "RECEIPT: #\(visit.uuid.uuidString.prefix(8).uppercased())",
            clientName: visit.pet?.owner?.fullName ?? "Valued Customer",
            clientPhoneFormatted: phoneFormatted,
            petLine: "Pet: \(visit.pet?.name ?? "Unknown") (\(visit.pet?.breed ?? "General"))",
            dateLine: dateLine,
            items: items,
            totalString: visit.total.moneyString,
            payment: payment
        )
    }

    /// Pre-render PDF off the main actor. Builds the snapshot on main, then renders on a background task.
    @MainActor
    func generatePDFAsync(for visit: Visit) async -> Data {
        let snapshot = makeSnapshot(for: visit)
        return await Task.detached(priority: .userInitiated) {
            Self.render(snapshot: snapshot)
        }.value
    }

    nonisolated static func render(snapshot: ReceiptSnapshot) -> Data {
        let bounds = PDFCanvas.letter
        // PDFCanvas makes the PDF the current context on the Mac too, where
        // the receipt's text otherwise never reached the page.
        return PDFCanvas.render(bounds: bounds, pageCount: 1) { _, context in
            drawContent(in: context, snapshot: snapshot, bounds: bounds)
        }
    }

    /// Fixed print colors deliberately do not follow the app's appearance.
    private enum Palette {
        static var ink: PlatformColor { PlatformColor(red: 20/255, green: 20/255, blue: 23/255, alpha: 1) }
        static var paper: PlatformColor { .white }
        static var muted: PlatformColor { PlatformColor(red: 92/255, green: 90/255, blue: 102/255, alpha: 1) }
        static var hairline: PlatformColor { PlatformColor(red: 229/255, green: 226/255, blue: 220/255, alpha: 1) }
        static var accent: PlatformColor { PlatformColor(red: 91/255, green: 79/255, blue: 233/255, alpha: 1) }
    }

    private nonisolated static func drawContent(in context: CGContext, snapshot: ReceiptSnapshot, bounds: CGRect) {
        context.setFillColor(Palette.paper.cgColor)
        context.fill(bounds)

        let margin: CGFloat = 50
        var currentY: CGFloat = 60

        // --- HEADER ---
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 28, weight: .black),
            .foregroundColor: Palette.accent
        ]
        snapshot.businessName.uppercased().draw(at: CGPoint(x: margin, y: currentY), withAttributes: titleAttributes)

        let receiptNumAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.ink
        ]
        let receiptNumSize = snapshot.receiptNumber.size(withAttributes: receiptNumAttributes)
        snapshot.receiptNumber.draw(at: CGPoint(x: 612 - margin - receiptNumSize.width, y: currentY + 10), withAttributes: receiptNumAttributes)

        currentY += 45

        context.setStrokeColor(Palette.accent.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: margin, y: currentY))
        context.addLine(to: CGPoint(x: 612 - margin, y: currentY))
        context.strokePath()

        currentY += 25

        // --- BUSINESS INFO ---
        let businessNameAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: Palette.ink
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 11),
            .foregroundColor: Palette.ink
        ]

        snapshot.businessName.draw(at: CGPoint(x: margin, y: currentY), withAttributes: businessNameAttributes)
        currentY += 18

        if let address = snapshot.businessAddress {
            address.draw(at: CGPoint(x: margin, y: currentY), withAttributes: bodyAttributes)
            currentY += 15
        }

        if let contact = snapshot.contactLine {
            contact.draw(at: CGPoint(x: margin, y: currentY), withAttributes: bodyAttributes)
            currentY += 15
        }

        currentY += 30

        // --- CLIENT & PET INFO ---
        let sectionHeaderAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: Palette.muted
        ]

        "BILL TO".draw(at: CGPoint(x: margin, y: currentY), withAttributes: sectionHeaderAttributes)
        "DETAILS".draw(at: CGPoint(x: 350, y: currentY), withAttributes: sectionHeaderAttributes)

        currentY += 20

        let clientAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: Palette.ink
        ]
        snapshot.clientName.draw(at: CGPoint(x: margin, y: currentY), withAttributes: clientAttributes)
        snapshot.dateLine.draw(at: CGPoint(x: 350, y: currentY), withAttributes: bodyAttributes)

        currentY += 18
        if let phone = snapshot.clientPhoneFormatted {
            phone.draw(at: CGPoint(x: margin, y: currentY), withAttributes: bodyAttributes)
            currentY += 15
        }
        snapshot.petLine.draw(at: CGPoint(x: 350, y: currentY), withAttributes: bodyAttributes)

        currentY += 50

        // --- SERVICES TABLE ---
        let tableHeaderAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: Palette.paper
        ]

        let tableHeaderRect = CGRect(x: margin, y: currentY, width: 512, height: 25)
        context.setFillColor(Palette.ink.cgColor)
        context.fill(tableHeaderRect)

        "SERVICE DESCRIPTION".draw(at: CGPoint(x: margin + 10, y: currentY + 6), withAttributes: tableHeaderAttributes)
        let priceHeader = "AMOUNT"
        let priceHeaderSize = priceHeader.size(withAttributes: tableHeaderAttributes)
        priceHeader.draw(at: CGPoint(x: 612 - margin - 10 - priceHeaderSize.width, y: currentY + 6), withAttributes: tableHeaderAttributes)

        currentY += 35

        for item in snapshot.items {
            item.name.draw(at: CGPoint(x: margin + 10, y: currentY), withAttributes: bodyAttributes)
            let priceSize = item.priceString.size(withAttributes: bodyAttributes)
            item.priceString.draw(at: CGPoint(x: 612 - margin - 10 - priceSize.width, y: currentY), withAttributes: bodyAttributes)

            currentY += 20

            context.setStrokeColor(Palette.hairline.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: currentY))
            context.addLine(to: CGPoint(x: 612 - margin, y: currentY))
            context.strokePath()

            currentY += 10
        }

        currentY += 20

        // --- TOTAL ---
        let totalLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: Palette.ink
        ]
        let totalValueAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 20, weight: .black),
            .foregroundColor: Palette.accent
        ]

        "GRAND TOTAL".draw(at: CGPoint(x: 350, y: currentY + 5), withAttributes: totalLabelAttributes)

        let totalSize = snapshot.totalString.size(withAttributes: totalValueAttributes)
        snapshot.totalString.draw(at: CGPoint(x: 612 - margin - 10 - totalSize.width, y: currentY), withAttributes: totalValueAttributes)

        currentY += 60

        // --- PAYMENT INFO ---
        if let payment = snapshot.payment {
            let payTitleAttributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Palette.ink
            ]
            "PAYMENT INFORMATION".draw(at: CGPoint(x: margin, y: currentY), withAttributes: payTitleAttributes)
            currentY += 20

            payment.infoLine.draw(at: CGPoint(x: margin, y: currentY), withAttributes: bodyAttributes)

            if let ref = payment.referenceLine {
                currentY += 15
                ref.draw(at: CGPoint(x: margin, y: currentY), withAttributes: bodyAttributes)
            }
        }

        // --- FOOTER ---
        #if canImport(UIKit)
        let italicFont = PlatformFont.italicSystemFont(ofSize: 10)
        #else
        let italicFont = NSFontManager.shared.convert(PlatformFont.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
        #endif

        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: Palette.muted
        ]
        let footer = "Thank you for choosing Pawtrackr! We look forward to seeing your pet again soon."
        let footerSize = footer.size(withAttributes: footerAttributes)
        footer.draw(at: CGPoint(x: (612 - footerSize.width) / 2, y: 740), withAttributes: footerAttributes)
    }
}

private extension Logger {
    static let pdfReceipt = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "PDFReceipt")
}
