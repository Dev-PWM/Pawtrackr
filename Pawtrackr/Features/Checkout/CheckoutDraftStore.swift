//
//  CheckoutDraftStore.swift
//  Pawtrackr
//

import Foundation
import OSLog

actor CheckoutDraftStore {
    // Tests can seed shipped visit UUIDs. Their default store must neither restore
    // an earlier test's step nor touch production drafts. Disk tests inject their own directory.
    static let shared = CheckoutDraftStore(inMemory: AppRuntime.isUITesting || AppRuntime.isRunningTests)

    private let directoryURL: URL
    private let inMemory: Bool
    private var memoryDrafts: [UUID: CheckoutDraft] = [:]
    private var fileOperationTail: Task<Void, Never>?
    private var latestRevisions: [UUID: UInt64] = [:]

    /// Reserves editor order before asynchronous work can be reordered by an executor.
    nonisolated static func nextRevision() -> UInt64 { CheckoutDraftRevisionClock.shared.next() }

    /// Uses actor-owned memory for practice sessions; production keeps disk crash recovery.
    init(directoryURL: URL? = nil, inMemory: Bool = false) {
        self.inMemory = inMemory
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    func loadDraft(for visitID: UUID) async -> CheckoutDraft? {
        if inMemory { return memoryDrafts[visitID] }
        let url = draftURL(for: visitID)

        do {
            return try await performFileOperation { try await CheckoutDraftFileIO.loadDraft(at: url) }
        } catch {
            Logger.checkoutDraft.error("Failed to load draft for \(visitID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveDraft(_ draft: CheckoutDraft, revision: UInt64 = CheckoutDraftStore.nextRevision()) async throws {
        guard revision > latestRevisions[draft.visitID, default: 0] else { return }
        latestRevisions[draft.visitID] = revision
        if inMemory {
            memoryDrafts[draft.visitID] = draft
            return
        }
        let url = draftURL(for: draft.visitID)
        let directory = directoryURL
        try await performFileOperation {
            try await CheckoutDraftFileIO.saveDraft(draft, at: url, directoryURL: directory)
        }
    }

    func deleteDraft(for visitID: UUID, revision: UInt64 = CheckoutDraftStore.nextRevision()) async throws {
        guard revision > latestRevisions[visitID, default: 0] else { return }
        // Keep a tombstone so a task holding an older snapshot cannot resurrect the draft.
        latestRevisions[visitID] = revision
        if inMemory {
            memoryDrafts.removeValue(forKey: visitID)
            return
        }
        let url = draftURL(for: visitID)
        try await performFileOperation { try await CheckoutDraftFileIO.deleteDraft(at: url) }
    }

    /// Preserves actor arrival order across suspended detached I/O, including deletion.
    /// A failed operation still releases the next operation; cancellation never drops cleanup.
    private func performFileOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = fileOperationTail
        let current = Task {
            await previous?.value
            return try await operation()
        }
        fileOperationTail = Task { _ = try? await current.value }
        return try await current.value
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

/// Process-wide ordering across checkout windows; mutable state is protected by the lock.
private final class CheckoutDraftRevisionClock: @unchecked Sendable {
    static let shared = CheckoutDraftRevisionClock()
    private let lock = NSLock()
    private var revision: UInt64 = 0

    /// Allocates a monotonically increasing revision without crossing an actor.
    func next() -> UInt64 {
        lock.withLock {
            revision += 1
            return revision
        }
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
