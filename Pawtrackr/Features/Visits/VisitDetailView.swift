//
//  VisitDetailView.swift
//  Pawtrackr
//
//  Read-only detail view for a single Visit.
//  Shows pet, timestamps, duration, services, notes, total, and payment method.
//  Mirrors the design language used across PetHistory and RecentHistory.
//
//  Created by mac on 8/16/25.
//

import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct VisitDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    let visit: Visit
    private let heroNamespace: Namespace.ID?
    @State private var showCheckout = false
    @State private var previewData: Data? = nil
    @State private var previewTitle: String = ""

    init(visit: Visit, heroNamespace: Namespace.ID? = nil) {
        self.visit = visit
        self.heroNamespace = heroNamespace
    }

    private var usesTabletLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    private var usesWideDetailLayout: Bool {
        #if os(macOS)
        true
        #else
        usesTabletLayout
        #endif
    }

    private var contentMaxWidth: CGFloat? {
        #if os(macOS)
        920
        #else
        usesTabletLayout ? 1040 : nil
        #endif
    }

    private var contentHorizontalPadding: CGFloat {
        #if os(macOS)
        18
        #else
        usesTabletLayout ? 24 : 16
        #endif
    }

    private var contentSpacing: CGFloat {
        usesWideDetailLayout ? 16 : 12
    }

    private var contentBottomPadding: CGFloat {
        #if os(iOS)
        if usesWideDetailLayout {
            return 28
        }

        // Paid detail screens hide the tab bar. Unpaid visits can still show
        // the checkout action in the bottom toolbar, so keep space for it.
        return visit.payment == nil ? 104 : 44
        #else
        return 28
        #endif
    }

    var body: some View {
        visitContent
            .navigationTitle(NSLocalizedString("visit.title", comment: ""))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
#endif
            .toolbar { toolbarContent }
            .modifier(VisitCheckoutModifier(showCheckout: $showCheckout, visit: visit))
            .modifier(VisitPreviewModifier(previewItem: previewItemBinding))
    }

    private var visitContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: contentSpacing) {
                header

                if usesWideDetailLayout {
                    tabletDetailLayout
                } else {
                    compactDetailLayout
                }
                
                VisitLoyaltyReceipt(visit: visit)
                metadataFooter
            }
            .frame(maxWidth: contentMaxWidth ?? .infinity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.top, usesWideDetailLayout ? 18 : 8)
            .padding(.bottom, contentBottomPadding)
        }
        .background(detailBackground.ignoresSafeArea())
    }

    private var detailBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    private var metadataFooter: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: NSLocalizedString("common.updated_fmt", value: "Updated %@", comment: ""), visit.lastModifiedAt.formatted(date: .abbreviated, time: .shortened)))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private var compactDetailLayout: some View {
        VStack(spacing: contentSpacing) {
            timelineCard
            paymentCard
            servicesCard
            photosCard
            notesCard
            behaviorTagsCard
        }
    }

    private var tabletDetailLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    timelineCard
                    servicesCard
                    notesCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 16) {
                    paymentCard
                    photosCard
                    behaviorTagsCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            compactDetailLayout
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            exportButton
        }
        checkoutToolbarItem
    }

    private var exportButton: some View {
        let csv = exportCSVForVisit()
        return ShareLink(
            item: CSVDoc(data: Data(csv.utf8), filename: "Pawtrackr_Visit.csv"),
            preview: SharePreview("Pawtrackr_Visit.csv")
        ) {
            Label(NSLocalizedString("common.export", comment: ""), systemImage: "square.and.arrow.up")
        }
        .disabled(csv.isEmpty)
        .accessibilityHint(csv.isEmpty ? NSLocalizedString("sharelink.accessibility.hint.no_data_to_export", comment: "") : NSLocalizedString("sharelink.accessibility.hint.export_visit", comment: ""))
    }

    @ToolbarContentBuilder
    private var checkoutToolbarItem: some ToolbarContent {
        #if os(iOS)
        if !usesTabletLayout {
            ToolbarItem(placement: .bottomBar) {
                checkoutButton
            }
        }
        #else
        ToolbarItem(placement: .secondaryAction) {
            checkoutButton
        }
        #endif
    }

    @ViewBuilder
    private var checkoutButton: some View {
        if visit.payment == nil {
            Button {
                showCheckout = true
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(visit.endedAt == nil ? NSLocalizedString("visit.check_out", comment: "") : NSLocalizedString("visit.resume_checkout", comment: ""))
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityLabel(NSLocalizedString("visit.checkout_a11y", value: "Open checkout to complete payment", comment: ""))
        }
    }

    private var previewItemBinding: Binding<PreviewItem?> {
        Binding(
            get: { previewData.map { PreviewItem(data: $0, title: previewTitle) } },
            set: { newValue in
                if let v = newValue {
                    previewData = v.data
                    previewTitle = v.title
                } else {
                    previewData = nil
                    previewTitle = ""
                }
            }
        )
    }
    
    // MARK: - Header (pet summary) 
    
    private var header: some View {
        Card(elevation: .regular, accent: .leading(.color(DS.ColorToken.gender(visit.pet?.gender)), thickness: 4)) {
            ViewThatFits(in: .horizontal) {
                headerHorizontal
                headerVertical
            }
        }
    }

    private var headerHorizontal: some View {
        HStack(spacing: 12) {
            heroAvatar
            headerText
            Spacer(minLength: 12)
            statusCluster
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerVertical: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                heroAvatar
                headerText
                Spacer()
            }
            statusCluster
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(visit.pet?.name ?? NSLocalizedString("common.unknown_pet", comment: ""))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(petSubtitle(visit.pet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .layoutPriority(2)
    }

    private var statusCluster: some View {
        HStack(spacing: 8) {
            statusBadge
            if let total = amountText {
                Chip(total, style: .tinted, size: .sm, tint: Color.accentColor)
                    .accessibilityLabel(String(format: NSLocalizedString("visit.total_a11y_fmt", value: "Total %@", comment: ""), total))
            }
        }
        .layoutPriority(1)
    }

    private var statusBadge: some View {
        Text(statusBadgeTitle)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusBadgeTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusBadgeTitle: String {
        if visit.isPaid {
            return NSLocalizedString("status.paid", comment: "")
        } else if visit.isCompleted {
            return NSLocalizedString("status.completed", comment: "")
        } else {
            return NSLocalizedString("status.in_session", comment: "")
        }
    }

    private var statusBadgeTint: Color {
        if visit.isPaid {
            return .green
        } else if visit.isCompleted {
            return .orange
        } else {
            return .blue
        }
    }
    
    private func petSubtitle(_ pet: Pet?) -> String {
        guard let pet = pet else { return "" }
        if let breed = pet.breed, !breed.isEmpty { return "\(breed) • \(pet.species.displayName)" }
        return pet.species.displayName
    }

    @ViewBuilder
    private var heroAvatar: some View {
        let avatar = AvatarView(
            .pet(
                species: visit.pet?.species,
                gender: visit.pet?.gender,
                name: visit.pet?.name ?? NSLocalizedString("common.unknown_pet", comment: ""),
                imageData: visit.pet?.photoData,
                thumbnailData: visit.pet?.thumbnailData
            ),
            size: .lg
        )

        if let heroNamespace {
            avatar.matchedGeometryEffect(id: heroID, in: heroNamespace, isSource: false)
        } else {
            avatar
        }
    }

    private var heroID: String {
        "visit-avatar-\(visit.uuid.uuidString)"
    }
    
    private var amountText: String? {
        visit.total > 0 ? visit.totalCurrencyString : nil
    }
    
    // MARK: - Timing & Payment

    private var timelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("visit.when", comment: ""), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))

                Divider().opacity(0.08)

                detailRow(
                    icon: "arrow.down.circle.fill",
                    title: NSLocalizedString("visit.check_in_time", comment: ""),
                    value: visit.startedAt.formatted(date: .abbreviated, time: .shortened)
                )

                detailRow(
                    icon: "arrow.up.circle.fill",
                    title: NSLocalizedString("visit.check_out_time", comment: ""),
                    value: visit.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? NSLocalizedString("visit.in_progress", comment: "")
                )

                durationRow
            }
        }
    }

    /// Duration ticks live while the visit is still in progress; once it's
    /// checked out the value is fixed, so a static row is enough.
    @ViewBuilder
    private var durationRow: some View {
        if visit.endedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                detailRow(
                    icon: "clock.fill",
                    title: NSLocalizedString("visit.duration", comment: ""),
                    value: visit.durationString
                )
            }
        } else {
            detailRow(
                icon: "clock.fill",
                title: NSLocalizedString("visit.duration", comment: ""),
                value: visit.durationString
            )
        }
    }

    private var paymentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("visit.payment", comment: ""), systemImage: visit.payment?.method.systemImage ?? "creditcard")
                    .font(.subheadline.weight(.semibold))

                Divider().opacity(0.08)

                if let payment = visit.payment {
                    detailRow(
                        icon: payment.method.systemImage,
                        title: payment.method.displayName,
                        value: payment.amountCurrencyString
                    )

                    if let ref = payment.externalReference, !ref.isEmpty {
                        Text(String(format: NSLocalizedString("visit.ref_fmt", comment: ""), ref))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Label(NSLocalizedString("visit.payment_pending", comment: ""), systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let total = amountText {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NSLocalizedString("visit.total", comment: ""))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 12)
                        Text(total)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: NSLocalizedString("visit.total_amount_a11y_fmt", value: "Total amount %@", comment: ""), total))
                }

                if visit.payment == nil && usesTabletLayout {
                    checkoutButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 12)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - Services
    
    @ViewBuilder
    private var servicesCard: some View {
        // Split into simpler subviews to aid type-checking
        if (visit.items ?? []).isEmpty { servicesEmptyCard } else { servicesContentCard }
    }
    
    private var servicesEmptyCard: some View {
        Card {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("visit.no_services", comment: ""))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("visit.no_services_a11y", value: "No services recorded for this visit", comment: ""))
        }
    }
    
    private var servicesContentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("visit.services_performed", comment: ""))
                    .font(.subheadline.weight(.semibold))

                // A visual ledger of WHAT was performed — names only. Per-service
                // dollar amounts and a computed services subtotal are intentionally
                // omitted; the final charge is the operator-entered amount shown on
                // the Payment card, not a sum of the listed services. Main services
                // first, then any add-ons under their own heading.
                servicesChips

                if !addOnItems.isEmpty {
                    Text(NSLocalizedString("visit.add_ons", value: "Add-ons", comment: ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    addOnChips
                }
            }
        }
        .accessibilityHint(NSLocalizedString("visit.services_hint", value: "Services performed.", comment: ""))
    }

    /// Catalog add-ons snapshot their category as `Service.Category.addOn.rawValue`.
    /// Everything else — including custom items whose `serviceCategoryRaw` is nil —
    /// counts as a main service so nothing silently disappears from the ledger.
    private var mainItems: [VisitItem] {
        Array(visit.items ?? []).filter { $0.serviceCategoryRaw != Service.Category.addOn.rawValue }
    }

    private var addOnItems: [VisitItem] {
        Array(visit.items ?? []).filter { $0.serviceCategoryRaw == Service.Category.addOn.rawValue }
    }

    private var servicesChips: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(mainItems, id: \.uuid) { (item: VisitItem) in
                Chip(item.displayName, style: .tinted, size: .sm, tint: .blue)
                    .accessibilityLabel(String(format: NSLocalizedString("visit.service_a11y_fmt", value: "Service %@", comment: ""), item.displayName))
                    .allowsHitTesting(false)
            }
        }
    }

    private var addOnChips: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(addOnItems, id: \.uuid) { (item: VisitItem) in
                Chip(item.displayName, style: .tinted, size: .sm, tint: .purple)
                    .accessibilityLabel(String(format: NSLocalizedString("visit.add_on_a11y_fmt", value: "Add-on %@", comment: ""), item.displayName))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Photos (Before / After) 
    
    @State private var showTransformation = false

    private var beforeDisplayPhoto: Data? {
        visit.beforeThumbnailData ?? visit.beforePhotoData
    }

    private var afterDisplayPhoto: Data? {
        visit.afterThumbnailData ?? visit.afterPhotoData
    }

    private var beforePreviewPhoto: Data? {
        visit.beforePhotoData ?? visit.beforeThumbnailData
    }

    private var afterPreviewPhoto: Data? {
        visit.afterPhotoData ?? visit.afterThumbnailData
    }

    private var hasVisitPhotos: Bool {
        beforePreviewPhoto != nil || afterPreviewPhoto != nil
    }

    private var photoBoxAspectRatio: CGFloat {
        usesWideDetailLayout ? 4 / 3 : 1
    }

    private var photoBoxMaxWidth: CGFloat? {
        usesWideDetailLayout ? 280 : nil
    }

    private var photosCard: some View {
        Group {
            if !hasVisitPhotos {
                EmptyView()
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(NSLocalizedString("visit.photos", comment: ""))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if beforePreviewPhoto != nil && afterPreviewPhoto != nil {
                                Button {
                                    showTransformation = true
                                } label: {
                                    Label(NSLocalizedString("transformation.title_short", value: "Transformation", comment: ""), systemImage: "sparkles.tv")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.blue)
                            }
                        }

                        photosLayout
                    }
                }
            }
        }
        .sheet(isPresented: $showTransformation) {
            TransformationView(
                beforeData: beforePreviewPhoto,
                afterData: afterPreviewPhoto,
                petName: visit.pet?.name ?? NSLocalizedString("common.unknown_pet", comment: "")
            )
        }
    }

    @ViewBuilder
    private var photosLayout: some View {
        if usesWideDetailLayout {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    photoBox(
                        title: NSLocalizedString("photobox.before", comment: ""),
                        displayData: beforeDisplayPhoto,
                        previewData: beforePreviewPhoto
                    )
                    photoBox(
                        title: NSLocalizedString("photobox.after", comment: ""),
                        displayData: afterDisplayPhoto,
                        previewData: afterPreviewPhoto
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                compactPhotosLayout
            }
        } else {
            compactPhotosLayout
        }
    }

    @ViewBuilder
    private var compactPhotosLayout: some View {
        #if os(iOS)
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            photoBox(
                title: NSLocalizedString("photobox.before", comment: ""),
                displayData: beforeDisplayPhoto,
                previewData: beforePreviewPhoto
            )
            photoBox(
                title: NSLocalizedString("photobox.after", comment: ""),
                displayData: afterDisplayPhoto,
                previewData: afterPreviewPhoto
            )
        }
        #else
        VStack(spacing: 12) {
            photoBox(
                title: NSLocalizedString("photobox.before", comment: ""),
                displayData: beforeDisplayPhoto,
                previewData: beforePreviewPhoto
            )
            photoBox(
                title: NSLocalizedString("photobox.after", comment: ""),
                displayData: afterDisplayPhoto,
                previewData: afterPreviewPhoto
            )
        }
        #endif
    }
    
    @ViewBuilder
    private func photoBox(title: String, displayData: Data?, previewData: Data?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button {
                if let previewData {
                    self.previewData = previewData
                    previewTitle = title
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.gray.opacity(0.2))
                    Group {
                        if let displayData {
                            LazyImageDataImage(data: displayData, maxDimension: 420)
                        } else {
                            placeholder
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .clipped()
                }
                .frame(maxWidth: photoBoxMaxWidth ?? .infinity)
                .aspectRatio(photoBoxAspectRatio, contentMode: .fit)
                .accessibilityLabel(Text(String(format: NSLocalizedString("visit.photo_a11y_label_fmt", comment: ""), title)))
                .accessibilityHint(Text(NSLocalizedString("visit.photo_a11y_hint", comment: "")))
            }
            .disabled(previewData == nil)
            .buttonStyle(.plain)
        }
    }

        private var placeholder: some View {
            VStack(spacing: 6) {
                Image(systemName: "photo")
                Text(NSLocalizedString("visit.no_photo", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        
        // MARK: - Notes
        
        private var notesCard: some View {
            Group {
                let trimmed = visit.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    Card {
                        HStack {
                            Text(NSLocalizedString("visit.no_notes", comment: ""))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("visit.notes", comment: ""))
                                .font(.subheadline.weight(.semibold))
                            let attr = (try? AttributedString(markdown: trimmed)) ?? AttributedString(trimmed)
                            Text(attr)
                                .font(.body)
                                .textSelection(.enabled)
                                .lineSpacing(2)
                                .accessibilityLabel(String(format: NSLocalizedString("visit.notes_a11y_fmt", value: "Notes, %@", comment: ""), trimmed))
                        }
                    }
                }
            }
        }
        
        @ViewBuilder
        private var behaviorTagsCard: some View {
            if !visit.behaviorTags.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("visit.behavior_tags", comment: ""))
                            .font(.subheadline.weight(.semibold))
                        FlowLayout(spacing: 8, rowSpacing: 8) {
                            ForEach(visit.behaviorTags, id: \.self) { tag in
                                Chip(tag, style: .tinted, size: .sm, tint: .blue)
                            }
                        }
                    }
                }
            }
        }
        
        // MARK: - Export (CSV)
        
        private func exportCSVForVisit() -> String {
            let header = NSLocalizedString("visit.csv.header", value: "startedAt,endedAt,pet,owner,services,amount,payment,notes", comment: "")

            func escape(_ text: String) -> String {
                let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }

            let started = visit.startedAt.ISO8601Format()
            let ended = visit.endedAt?.ISO8601Format() ?? ""
            let petName = visit.pet?.name ?? NSLocalizedString("common.unknown_pet", comment: "")
            let ownerName = visit.pet?.owner.map { "\($0.firstName) \($0.lastName)" } ?? ""
            let services = (visit.items ?? []).map { $0.displayName }.joined(separator: "; ")
            let amount = visit.totalCurrencyString
            let payment = visit.payment?.method.displayName ?? ""
            let notes = (visit.note ?? "").replacingOccurrences(of: "\n", with: " ")

            let row: [String] = [
                started,
                ended,
                petName,
                ownerName,
                services,
                amount,
                payment,
                notes
            ].map(escape)
            
            return header + "\n" + row.joined(separator: ",")
        }
    }
    
    // Wrapper type to drive fullScreenCover(item:)
fileprivate struct PreviewItem: Identifiable {
    let id = UUID()
    let data: Data
    let title: String
}

private struct VisitCheckoutModifier: ViewModifier {
    @Binding var showCheckout: Bool
    let visit: Visit

    func body(content: Content) -> some View {
        #if os(iOS)
        content.adaptiveCover(isPresented: $showCheckout) {
            if let pet = visit.pet {
                CheckoutView(pet: pet, visit: visit)
            }
        }
        #else
        content.sheet(isPresented: $showCheckout) {
            if let pet = visit.pet {
                CheckoutView(pet: pet, visit: visit)
            }
        }
        #endif
    }
}

private struct VisitPreviewModifier: ViewModifier {
    let previewItem: Binding<PreviewItem?>

    func body(content: Content) -> some View {
        #if os(iOS)
        content.adaptiveCover(item: previewItem) { item in
            PhotoPreview(imageData: item.data, title: item.title)
        }
        #else
        content.sheet(item: previewItem) { item in
            PhotoPreview(imageData: item.data, title: item.title)
        }
        #endif
    }
}
