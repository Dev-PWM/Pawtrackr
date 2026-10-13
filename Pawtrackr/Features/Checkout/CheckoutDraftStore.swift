//
//  CheckoutDraftStore.swift
//  Pawtrackr
//

import Foundation
import OSLog

actor CheckoutDraftStore {
    static let shared = CheckoutDraftStore()

    private let directoryURL: URL
    private let inMemory: Bool
    private var memoryDrafts: [UUID: CheckoutDraft] = [:]

    /// Uses actor-owned memory for practice sessions; production keeps disk crash recovery.
    init(directoryURL: URL? = nil, inMemory: Bool = false) {
        self.inMemory = inMemory
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    func loadDraft(for visitID: UUID) async -> CheckoutDraft? {
        if inMemory { return memoryDrafts[visitID] }
        let url = draftURL(for: visitID)

        do {
            return try await CheckoutDraftFileIO.loadDraft(at: url)
        } catch {
            Logger.checkoutDraft.error("Failed to load draft for \(visitID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveDraft(_ draft: CheckoutDraft) async throws {
        if inMemory {
            memoryDrafts[draft.visitID] = draft
            return
        }
        try await CheckoutDraftFileIO.saveDraft(draft, at: draftURL(for: draft.visitID), directoryURL: directoryURL)
    }

    func deleteDraft(for visitID: UUID) async throws {
        if inMemory {
            memoryDrafts.removeValue(forKey: visitID)
            return
        }
        try await CheckoutDraftFileIO.deleteDraft(at: draftURL(for: visitID))
    }

    private func draftURL(for visitID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(visitID.uuidString).json")
    }

    private static func defaultDirectoryURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("Pawtrackr", isDirectory: true)
            .appendingPathComponent("CheckoutDrafts", isDirectory: true)
    }
}

private enum CheckoutDraftFileIO {
    static func loadDraft(at url: URL) async throws -> CheckoutDraft? {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: url)
            return try decoder.decode(CheckoutDraft.self, from: data)
        }.value
    }

    static func saveDraft(_ draft: CheckoutDraft, at url: URL, directoryURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(draft)
            try data.write(to: url, options: .atomic)
        }.value
    }

    static func deleteDraft(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            try FileManager.default.removeItem(at: url)
        }.value
    }
}

private extension Logger {
    static let checkoutDraft = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "CheckoutDraftStore")
}
