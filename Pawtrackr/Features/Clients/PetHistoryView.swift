//
//  PetHistoryView.swift
//  Pawtrackr
//
//  Shows a pet’s visit history/timeline.
//  Updated by Assistant on 2025-09-03.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// A wrapper to make CSV data transferable for use with ShareLink.
struct CSVDoc: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        // A named file first, for AirDrop, Mail, Messages and Files.
        FileRepresentation(exportedContentType: .commaSeparatedText) { doc in
            SentTransferredFile(try SharedExportFile.write(doc.data, named: doc.filename))
        }
        DataRepresentation(contentType: .commaSeparatedText) { doc in
            doc.data
        } importing: { data in
            // Default filename for imported data, can be ignored.
            CSVDoc(data: data, filename: "data.csv")
        }
        .suggestedFileName { doc in
            doc.filename
        }
    }
}

struct PetHistoryView: View {
    @Environment(GlobalEventBus.self) private var eventBus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var envModelContext
    @Namespace private var visitHeroNamespace
    @State private var viewModel: PetHistoryViewModel? = nil
    private let pet: Pet
    private let wrapsInNavigationStack: Bool

    init(pet: Pet, wrapsInNavigationStack: Bool = true) {
        self.pet = pet
        self.wrapsInNavigationStack = wrapsInNavigationStack
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                if wrapsInNavigationStack {
                    NavigationStack {
                        historyContent(vm)
                    }
                } else {
                    historyContent(vm)
                }
            } else {
                loadingState
                    .task {
                        // Initialize using the pet's context if available, else environment.
                        let ctx = pet.modelContext ?? envModelContext
                        viewModel = PetHistoryViewModel(pet: pet, modelContext: ctx, eventBus: eventBus)
                    }
            }
        }
    }

    private func historyContent(_ vm: PetHistoryViewModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard(vm)
                    .padding(.horizontal)
                controls(vm)
                    .padding(.horizontal)

                if vm.isLoading && vm.filtered.isEmpty {
                    historyRowsSkeleton
                } else if vm.visits.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("pet_history.empty_title", comment: ""),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(String(format: NSLocalizedString("pet_history.empty_desc_fmt", comment: ""), vm.pet.name))
                    )
                    .padding(.top, 40)
                } else if vm.filtered.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("pet_history.no_matches_title", value: "No Matching Visits", comment: ""),
                        systemImage: "magnifyingglass",
                        description: Text(NSLocalizedString("pet_history.no_matches_desc", value: "Try a different service, note, or reference.", comment: ""))
                    )
                    .padding(.top, 40)
                } else {
                    visitList(vm)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(vm.pet.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent(vm) }
        .alert(item: Binding(
            get: { vm.appError },
            set: { vm.appError = $0 }
        )) { error in
            Alert(
                title: Text(NSLocalizedString("pet_history.error_title", value: "History Error", comment: "")),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text(NSLocalizedString("common.ok", comment: "")))
            )
        }
        .task { await vm.refresh() }
    }

    private func visitList(_ vm: PetHistoryViewModel) -> some View {
        let groups = Dictionary(grouping: vm.filtered, by: { Calendar.current.startOfDay(for: $0.sortKeyDate) })
        let sortedDays = groups.keys.sorted(by: >)

        return LazyVStack(spacing: 16, pinnedViews: .sectionHeaders) {
            ForEach(sortedDays, id: \.self) { day in
                Section {
                    ForEach(groups[day]!.sorted { $0.sortKeyDate > $1.sortKeyDate }) { visit in
                        NavigationLink(destination: VisitDetailView(visit: visit, heroNamespace: visitHeroNamespace)) {
                            // Use the new, standalone VisitTimelineRow.
                            VisitTimelineRow(visit: visit, heroNamespace: visitHeroNamespace)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .background(.background)
                }
            }

            if vm.canLoadMore {
                Button {
                    vm.loadMore()
                } label: {
                    HStack(spacing: 8) {
                        if vm.isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Text(NSLocalizedString("common.load_more", comment: "Load More"))
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("petHistory.loadMore")
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("petHistory.list")
    }

    private func controls(_ vm: PetHistoryViewModel) -> some View {
        @Bindable var vm = vm
        return VStack(spacing: 10) {
            SearchField(text: $vm.searchText, accessibilityIdentifier: "petHistory.search")
            Picker(NSLocalizedString("pet_history.range", value: "History Range", comment: ""), selection: $vm.scope) {
                ForEach(PetHistoryViewModel.Scope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("petHistory.scope")
        }
    }

    private func headerCard(_ vm: PetHistoryViewModel) -> some View {
        Card(elevation: .regular, accent: .leading(.color(DS.ColorToken.gender(vm.pet.gender)), thickness: 4)) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(.pet(species: vm.pet.species, gender: vm.pet.gender, name: vm.pet.name, imageData: vm.pet.photoData), size: .lg)

                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.pet.name).font(.title3.weight(.semibold))
                    Text(vm.pet.shortDescriptor).font(.subheadline).foregroundStyle(.secondary)

                    FlowLayout(spacing: 8) {
                        let visits = vm.totalVisits
                        let visitsText = String.localizedStringWithFormat(NSLocalizedString("visits.count", comment: "visit count"), visits)
                        Chip.info(visitsText)
                        Chip.info(String(format: "%@ %@",
                                         NSLocalizedString("visits.avg_duration", comment: "avg duration short"), vm.averageDurationString))
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }
        }
    }
    
    @ToolbarContentBuilder
    private func toolbarContent(_ vm: PetHistoryViewModel) -> some ToolbarContent {
        if wrapsInNavigationStack {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.done", comment: "")) { dismiss() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                let csvData = vm.exportCSV()
                ShareLink(
                    item: CSVDoc(data: csvData, filename: "\(vm.pet.name)_History.csv"),
                    preview: SharePreview("\(vm.pet.name)_History.csv")
                ) {
                    Label("common.export", systemImage: "tablecells")
                }
                .disabled(vm.filtered.isEmpty)

                let textData = vm.exportPlainText()
                ShareLink(
                    item: textData,
                    preview: SharePreview(vm.pet.name)
                ) {
                    Label("common.export_text", systemImage: "doc.text")
                }
                .disabled(vm.filtered.isEmpty)
            } label: {
                Label("common.export", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var loadingState: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerSkeleton
                    .padding(.horizontal)
                controlsSkeleton
                    .padding(.horizontal)
                historyRowsSkeleton
            }
            .padding(.top, 8)
        }
    }

    private var headerSkeleton: some View {
        Card(elevation: .regular) {
            HStack(spacing: 12) {
                Circle().fill(Color.secondary.opacity(0.15)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(width: 120, height: 14)
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)).frame(width: 160, height: 12)
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)).frame(width: 90, height: 24)
                }
                Spacer()
            }
        }
        .redacted(reason: .placeholder)
    }

    private var controlsSkeleton: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 44)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 32)
        }
        .redacted(reason: .placeholder)
    }

    private var historyRowsSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                Card {
                    HStack(spacing: 12) {
                        Circle().fill(Color.secondary.opacity(0.15)).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(width: 170, height: 12)
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)).frame(width: 120, height: 10)
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)).frame(width: 200, height: 10)
                        }
                        Spacer()
                    }
                }
                .redacted(reason: .placeholder)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}
