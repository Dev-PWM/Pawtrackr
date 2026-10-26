//
//  ServiceManagementView.swift
//  Pawtrackr
//
//  Created by Assistant on 2025-12-05.
//

import SwiftUI
import SwiftData
import OSLog

struct ServiceManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ServiceManagementViewModel
    @State private var showingAddService = false

    init(modelContext: ModelContext) {
        _viewModel = State(initialValue: ServiceManagementViewModel(modelContext: modelContext))
    }

    var body: some View {
        List {
            ForEach(viewModel.services) { service in
                NavigationLink(destination: EditServiceView(service: service, modelContext: modelContext, wrapsInNavigationStack: false)) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(service.name).font(.headline)
                            Text(service.effectiveBasePrice.moneyString)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !service.isEnabled {
                            Text(AppLocalization.localized("service.disabled"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }
                }
            }
            .onDelete(perform: deleteService)
        }
        .navigationTitle(AppLocalization.localized("service.management_title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingAddService = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddService) {
            EditServiceView(modelContext: modelContext)
        }
        .onAppear {
            viewModel.fetchServices()
        }
        .alert(item: $viewModel.appError) { error in
            Alert(
                title: Text(AppLocalization.localized("common.error")),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text(AppLocalization.localized("common.ok")))
            )
        }
    }
    
    private func deleteService(at offsets: IndexSet) {
        for index in offsets {
            let service = viewModel.services[index]
            viewModel.deleteService(service)
        }
    }
}

// Placeholder for EditServiceView
struct EditServiceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EditServiceViewModel
    private let wrapsInNavigationStack: Bool

    init(service: Service? = nil, modelContext: ModelContext, wrapsInNavigationStack: Bool = true) {
        _viewModel = State(initialValue: EditServiceViewModel(modelContext: modelContext, service: service))
        self.wrapsInNavigationStack = wrapsInNavigationStack
    }

    var body: some View {
        if wrapsInNavigationStack {
            NavigationStack {
                editContent
            }
        } else {
            editContent
        }
    }

    private var editContent: some View {
        Form {
            Section(AppLocalization.localized("service.details")) {
                TextField(AppLocalization.localized("service.name"), text: $viewModel.name)
                    .textLengthLimit($viewModel.name, to: TextInputLimits.name)
                Picker(AppLocalization.localized("service.category"), selection: $viewModel.category) {
                    ForEach(Service.Category.allCases) { category in
                        Text(category.localizedName).tag(category)
                    }
                }
                HStack {
                    Text(AppLocalization.localized("service.icon"))
                    Spacer()
                    Image(systemName: viewModel.systemIcon)
                }
            }

            Section(AppLocalization.localized("service.pricing_duration")) {
                TextField(AppLocalization.localized("service.price"), value: $viewModel.price, format: .currency(code: "USD"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif

                Stepper(
                    String(format: AppLocalization.localized("service.duration_minutes_fmt"), viewModel.duration),
                    value: $viewModel.duration,
                    in: 5...480,
                    step: 5
                )
            }

            Section(AppLocalization.localized("service.status")) {
                Toggle(AppLocalization.localized("service.enabled_in_app"), isOn: $viewModel.isEnabled)
                Toggle(AppLocalization.localized("service.is_package"), isOn: $viewModel.isPackage)
            }
        }
        .navigationTitle(viewModel.service == nil ? AppLocalization.localized("service.add_service") : AppLocalization.localized("service.edit_service"))
        .toolbar {
            if wrapsInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("common.cancel")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalization.localized("common.save")) { saveService() }
            }
        }
        .alert(item: $viewModel.appError) { error in
            Alert(
                title: Text(AppLocalization.localized("common.error")),
                message: Text(error.localizedDescription),
                dismissButton: .default(Text(AppLocalization.localized("common.ok")))
            )
        }
    }

    private func saveService() {
        Task {
            do {
                try await viewModel.save()
                dismiss()
            } catch let error as ValidationError {
                viewModel.appError = .validation(error)
            } catch {
                Logger.database.error("Saving service failed: \(error.localizedDescription, privacy: .public)")
                viewModel.appError = .database(error.localizedDescription)
            }
        }
    }
}
