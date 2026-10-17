//
//  StoreFileMigration.swift
//  Pawtrackr
//
//  File-level SwiftData store migrations that must happen before
//  ModelContainer opens the configured store.
//

import Foundation
import OSLog
#if canImport(SQLite3)
import SQLite3
#endif

enum StoreFileMigration {
    enum Action: Equatable {
        case none
        case migratedToMissingNamedStore
        case restoredLegacyOverEmptyNamedStore
        case skippedNamedStoreHasData
        case skippedUnableToVerifyStoreContents
        case failed(String)
    }

    struct Outcome: Equatable {
        let action: Action
        let movedFiles: Int
        let backedUpFiles: Int
    }

    struct BackupOutcome: Equatable {
        let copiedFiles: Int
        let backupDirectory: URL?
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "StoreFileMigration")
    private static let legacyStoreName = "default.store"
    private static let currentStoreName = "Pawtrackr.store"
    private static let preMigrationBackupBuildKey = "pawtrackr.storeBackup.lastBuild"
    private static let operationalTables = [
        "ZCLIENT",
        "ZPET",
        "ZVISIT",
        "ZPAYMENT",
        "ZVISITITEM",
        "ZCHECKOUTTRANSACTION",
        "ZINVENTORYITEM",
        "ZINVENTORYTRANSACTION",
        "ZLOYALTYLEDGERENTRY"
    ]

    @discardableResult
    static func backupStoresForCurrentBuildIfNeeded(
        appSupportURL overrideAppSupportURL: URL? = nil,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        lockTimeout: TimeInterval = StoreFileLockCoordinator.defaultTimeout
    ) -> BackupOutcome {
        let buildIdentifier = appBuildIdentifier
        guard userDefaults.string(forKey: preMigrationBackupBuildKey) != buildIdentifier else {
            return BackupOutcome(copiedFiles: 0, backupDirectory: nil)
        }

        do {
            let appSupportURL = try overrideAppSupportURL ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            return try StoreFileLockCoordinator.withStoreLock(in: appSupportURL, reason: "pre-update backup", fileManager: fileManager, timeout: lockTimeout) {
                let storeFiles = try existingStoreFamily(for: currentStoreName, in: appSupportURL, fileManager: fileManager)
                    + existingStoreFamily(for: legacyStoreName, in: appSupportURL, fileManager: fileManager)
            guard !storeFiles.isEmpty else {
                userDefaults.set(buildIdentifier, forKey: preMigrationBackupBuildKey)
                return BackupOutcome(copiedFiles: 0, backupDirectory: nil)
            }

            let stamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let safeBuild = buildIdentifier.replacingOccurrences(of: "/", with: "-")
            let backupDirectory = appSupportURL.appendingPathComponent("PreMigrationBackup-\(safeBuild)-\(stamp)", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            do {
                var copied = 0
                for url in storeFiles {
                    try fileManager.copyItem(at: url, to: backupDirectory.appendingPathComponent(url.lastPathComponent))
                    copied += 1
                }

                // Photos and logos (@Attribute(.externalStorage)) live beside the
                // store; a backup without them restores rows with missing images.
                var copiedSupport: [String] = []
                for storeName in [currentStoreName, legacyStoreName] {
                    let supportName = StoreBackupRestore.supportDirectoryName(forStoreNamed: storeName)
                    let supportURL = appSupportURL.appendingPathComponent(supportName, isDirectory: true)
                    guard fileManager.fileExists(atPath: supportURL.path) else { continue }
                    try fileManager.copyItem(at: supportURL, to: backupDirectory.appendingPathComponent(supportName, isDirectory: true))
                    copiedSupport.append(supportName)
                }

                let manifest = [
                    "Pawtrackr automatic pre-update backup",
                    "Created: \(Date().formatted(date: .complete, time: .standard))",
                    "App build: \(buildIdentifier)",
                    "Copied files:",
                    (storeFiles.map(\.lastPathComponent) + copiedSupport).map { "- \($0)" }.joined(separator: "\n")
                ].joined(separator: "\n")
                try manifest.write(
                    to: backupDirectory.appendingPathComponent("README.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                userDefaults.set(buildIdentifier, forKey: preMigrationBackupBuildKey)
                log.info("Created pre-update store backup with \(copied, privacy: .public) file(s).")
                prunePreUpdateBackups(in: appSupportURL, fileManager: fileManager)
                return BackupOutcome(copiedFiles: copied, backupDirectory: backupDirectory)
            } catch {
                // Our own half-written copy: remove it so every later launch
                // doesn't leave another partial folder behind.
                try? fileManager.removeItem(at: backupDirectory)
                throw error
            }
            }
        } catch {
            // The build key stays unset, so the next launch tries again. A
            // lock timeout lands here too: never skip this backup silently.
            log.error("Pre-update store backup not made this launch; the next launch retries: \(error.localizedDescription, privacy: .public)")
            return BackupOutcome(copiedFiles: 0, backupDirectory: nil)
        }
    }

    /// Keeps the two newest pre-update backups plus the one with the most
    /// clients, so a run of builds that each copied an already-empty store can't
    /// push the last good copy out. Only `PreMigrationBackup-*` folders are ever
    /// pruned; reset and restore archives are left for the user.
    static func prunePreUpdateBackups(
        in appSupportURL: URL,
        keepNewest: Int = 2,
        fileManager: FileManager = .default
    ) {
        let backups = StoreBackupRestore.candidates(appSupportURL: appSupportURL, fileManager: fileManager)
            .filter { $0.kind == .preUpdate }
        guard backups.count > keepNewest else { return }

        var keep = Set(backups.prefix(keepNewest).map(\.directoryName))
        if let fullest = backups.max(by: { $0.clientCount < $1.clientCount }) {
            keep.insert(fullest.directoryName)
        }
        for backup in backups where !keep.contains(backup.directoryName) {
            do {
                try fileManager.removeItem(at: appSupportURL.appendingPathComponent(backup.directoryName, isDirectory: true))
                log.info("Pruned old pre-update backup \(backup.directoryName, privacy: .public).")
            } catch {
                log.error("Couldn't prune \(backup.directoryName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Moves data from SwiftData's unnamed `default.store` into the named
    /// `Pawtrackr.store` before SwiftData can create a fresh empty database.
    ///
    /// A safeguard only: the store has been named "Pawtrackr" since May 2026,
    /// before any App Store build, so no shipped user has a `default.store`.
    /// The 1.0.2 data loss was a migration failure, not a store rename (see
    /// `PawtrackrSchema` in Migrations.swift).
    @discardableResult
    static func migrateLegacyDefaultStoreIfNeeded(
        appSupportURL overrideAppSupportURL: URL? = nil,
        fileManager: FileManager = .default,
        lockTimeout: TimeInterval = StoreFileLockCoordinator.defaultTimeout
    ) -> Outcome {
        do {
            let appSupportURL = try overrideAppSupportURL ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )

            return try StoreFileLockCoordinator.withStoreLock(in: appSupportURL, reason: "legacy default.store migration", fileManager: fileManager, timeout: lockTimeout) {
                StoreMigrationJournal.recoverIfPossible(in: appSupportURL, fileManager: fileManager)

            let legacyFamily = try existingStoreFamily(for: legacyStoreName, in: appSupportURL, fileManager: fileManager)
            guard !legacyFamily.isEmpty else {
                return Outcome(action: .none, movedFiles: 0, backedUpFiles: 0)
            }

            let currentFamily = try existingStoreFamily(for: currentStoreName, in: appSupportURL, fileManager: fileManager)
            if currentFamily.isEmpty {
                let moved = try moveStoreFamily(legacyFamily, from: legacyStoreName, to: currentStoreName, in: appSupportURL, fileManager: fileManager)
                log.info("Migrated legacy default.store to Pawtrackr.store before opening SwiftData.")
                return Outcome(action: .migratedToMissingNamedStore, movedFiles: moved, backedUpFiles: 0)
            }

            let currentStoreURL = appSupportURL.appendingPathComponent(currentStoreName)
            let legacyStoreURL = appSupportURL.appendingPathComponent(legacyStoreName)
            guard let currentHasOperationalRows = hasOperationalRows(in: currentStoreURL),
                  let legacyHasOperationalRows = hasOperationalRows(in: legacyStoreURL)
            else {
                log.warning("Skipped legacy store migration because store contents could not be verified safely.")
                return Outcome(action: .skippedUnableToVerifyStoreContents, movedFiles: 0, backedUpFiles: 0)
            }

            guard !currentHasOperationalRows else {
                log.info("Skipped legacy store migration because Pawtrackr.store already contains operational data.")
                return Outcome(action: .skippedNamedStoreHasData, movedFiles: 0, backedUpFiles: 0)
            }

            guard legacyHasOperationalRows else {
                return Outcome(action: .none, movedFiles: 0, backedUpFiles: 0)
            }

            let backedUp = try archiveStoreFamily(currentFamily, in: appSupportURL, fileManager: fileManager)
            let moved = try moveStoreFamily(legacyFamily, from: legacyStoreName, to: currentStoreName, in: appSupportURL, fileManager: fileManager)
            log.info("Restored legacy default.store over an empty Pawtrackr.store backup.")
            return Outcome(action: .restoredLegacyOverEmptyNamedStore, movedFiles: moved, backedUpFiles: backedUp)
            }
        } catch {
            log.error("Legacy store migration failed: \(error.localizedDescription, privacy: .public)")
            return Outcome(action: .failed(error.localizedDescription), movedFiles: 0, backedUpFiles: 0)
        }
    }

    private static func existingStoreFamily(
        for baseName: String,
        in appSupportURL: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let contents = try fileManager.contentsOfDirectory(
            at: appSupportURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        return contents
            .filter { isStoreFamilyMember($0.lastPathComponent, baseName: baseName) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isStoreFamilyMember(_ fileName: String, baseName: String) -> Bool {
        fileName == baseName
            || fileName.hasPrefix(baseName + "-")
            || fileName.hasPrefix(baseName + "_")
            || fileName.hasPrefix("." + baseName + "-")
            || fileName.hasPrefix("." + baseName + "_")
    }

    private static func renamedStoreFamilyMember(_ fileName: String, from oldBaseName: String, to newBaseName: String) -> String {
        if fileName.hasPrefix("." + oldBaseName) {
            return "." + newBaseName + String(fileName.dropFirst(oldBaseName.count + 1))
        }
        if fileName.hasPrefix(oldBaseName) {
            return newBaseName + String(fileName.dropFirst(oldBaseName.count))
        }
        return fileName
    }

    private static func moveStoreFamily(
        _ urls: [URL],
        from oldBaseName: String,
        to newBaseName: String,
        in appSupportURL: URL,
        fileManager: FileManager
    ) throws -> Int {
        let journalEntries = urls.map { url in
            StoreMigrationJournal.Entry(
                source: url.lastPathComponent,
                destination: renamedStoreFamilyMember(url.lastPathComponent, from: oldBaseName, to: newBaseName)
            )
        }
        var journal = StoreMigrationJournal(
            id: UUID(),
            phase: .prepared,
            reason: "Move \(oldBaseName) to \(newBaseName)",
            createdAt: Date(),
            entries: journalEntries
        )
        try journal.save(in: appSupportURL)

        var moved = 0
        journal.phase = .moving
        try journal.save(in: appSupportURL)

        do {
            for url in urls {
                let newName = renamedStoreFamilyMember(url.lastPathComponent, from: oldBaseName, to: newBaseName)
            let destination = appSupportURL.appendingPathComponent(newName)
            try fileManager.moveItem(at: url, to: destination)
            moved += 1
        }
            journal.phase = .completed
            try journal.save(in: appSupportURL)
            StoreMigrationJournal.clear(in: appSupportURL, fileManager: fileManager)
        } catch {
            log.error("Store family move failed after \(moved, privacy: .public) file(s): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return moved
    }

    private static func archiveStoreFamily(_ urls: [URL], in appSupportURL: URL, fileManager: FileManager) throws -> Int {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDirectory = appSupportURL.appendingPathComponent("StoreMigrationBackup-\(stamp)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var backedUp = 0
        for url in urls {
            try fileManager.moveItem(at: url, to: backupDirectory.appendingPathComponent(url.lastPathComponent))
            backedUp += 1
        }

        let manifest = [
            "Pawtrackr automatic store migration backup",
            "Created: \(Date().formatted(date: .complete, time: .standard))",
            "Reason: an empty Pawtrackr.store was replaced with data from legacy default.store.",
            "Backed up files:",
            urls.isEmpty ? "- none" : urls.map { "- \($0.lastPathComponent)" }.joined(separator: "\n")
        ].joined(separator: "\n")
        try manifest.write(
            to: backupDirectory.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        return backedUp
    }

    private static func hasOperationalRows(in storeURL: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }

        #if canImport(SQLite3)
        guard let database = openReadOnlyDatabase(at: storeURL) else { return nil }
        defer { sqlite3_close(database) }

        for table in operationalTables where tableExists(table, in: database) {
            guard let rows = rowCount(in: table, database: database) else { return nil }
            if rows > 0 { return true }
        }
        return false
        #else
        return nil
        #endif
    }

    /// Number of client rows in a store file, read with SQLite directly so it
    /// works on stores SwiftData can't (or mustn't yet) open. `nil` means the
    /// file exists but couldn't be read.
    static func clientRowCount(in storeURL: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return 0 }

        #if canImport(SQLite3)
        guard let database = openReadOnlyDatabase(at: storeURL) else { return nil }
        defer { sqlite3_close(database) }

        guard tableExists("ZCLIENT", in: database) else { return 0 }
        return rowCount(in: "ZCLIENT", database: database)
        #else
        return nil
        #endif
    }

    /// The `uuid` of every client in a store file (SwiftData keeps UUIDs as
    /// 16-byte blobs). `nil` means the file couldn't be read.
    static func clientUUIDs(in storeURL: URL) -> Set<UUID>? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return [] }

        #if canImport(SQLite3)
        guard let database = openReadOnlyDatabase(at: storeURL) else { return nil }
        defer { sqlite3_close(database) }
        guard tableExists("ZCLIENT", in: database) else { return [] }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT ZUUID FROM ZCLIENT", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var uuids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_bytes(statement, 0) == 16, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &raw) { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16)) }
            uuids.insert(UUID(uuid: raw))
        }
        return uuids
        #else
        return nil
        #endif
    }

    static var appBuildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version)-\(build)"
    }

    #if canImport(SQLite3)
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens a store read-only without creating or changing any file.
    ///
    /// Core Data stores are in WAL mode, and a plain read-only open of a WAL
    /// database fails (SQLITE_CANTOPEN) when its `-shm` file is missing, as
    /// with a lone copied `.store`. In that case, if there's no WAL content
    /// that could be missed, fall back to `immutable=1`, which reads the main
    /// file without touching the WAL machinery.
    private static func openReadOnlyDatabase(at storeURL: URL) -> OpaquePointer? {
        if let database = SQLiteStoreFileSet.openReadOnlyDatabase(at: storeURL) {
            return database
        }
        return nil
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(statement, 0) > 0
    }

    private static func rowCount(in table: String, database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            return nil
        }

        return Int(sqlite3_column_int64(statement, 0))
    }
    #endif
}
