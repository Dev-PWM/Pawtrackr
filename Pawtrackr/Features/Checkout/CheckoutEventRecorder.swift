//
//  CheckoutEventRecorder.swift
//  Pawtrackr
//

import Foundation
import OSLog
import CryptoKit

actor CheckoutEventRecorder {
    static let shared = CheckoutEventRecorder()

    private let logURL: URL
    private let persistsEvents: Bool
    private let maxLines: Int
    private let maxFileBytes: Int
    private let iso8601 = ISO8601DateFormatter()

    // Buffered lines waiting to be flushed to disk.
    private var pendingLines: [String] = []
    private var flushTask: Task<Void, Never>?

    /// Practice sessions retain OSLog diagnostics without writing a trace file.
    init(logURL: URL? = nil, maxLines: Int = 300, maxFileBytes: Int = 64 * 1024, persistsEvents: Bool = true) {
        self.persistsEvents = persistsEvents
        self.logURL = logURL ?? Self.defaultLogURL()
        self.maxLines = max(1, maxLines)
        self.maxFileBytes = max(1, maxFileBytes)
    }

    func record(_ event: String, visitID: UUID, petName: String) {
        let petNameToken = Self.pseudonymousToken(for: petName)
        let line = "\(iso8601.string(from: .now)) | visit=\(visitID.uuidString) | petNameToken=\(petNameToken) | \(event)"
        // OSLog goes to system-wide captures (sysdiagnose, support bundles) where pet
        // name counts as customer PII. Keep the visit UUID public for cross-referencing
        // and write only a deterministic token for the pet.
        Logger.checkoutTrace.info("checkout event=\(event, privacy: .public) visit=\(visitID.uuidString, privacy: .public) petNameToken=\(petNameToken, privacy: .public)")

        guard persistsEvents else { return }
        pendingLines.append(line)

        // Flush immediately once the buffer is large enough; otherwise schedule a deferred flush.
        if pendingLines.count >= 10 {
            flush()
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            await self?.flush()
        }
    }

    private func flush() {
        guard !pendingLines.isEmpty else { return }
        flushTask?.cancel()
        flushTask = nil

        let batch = pendingLines
        pendingLines = []

        do {
            try ensureParentDirectory()
            let existing = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            var lines = existing.split(separator: "\n").map(String.init)
            lines.append(contentsOf: batch)
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }
            lines = lines.trimmedToUTF8ByteLimit(maxFileBytes)
            try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.checkoutTrace.error("Failed to persist checkout trace: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureParentDirectory() throws {
        let parent = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func defaultLogURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("Pawtrackr", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("checkout-events.log")
    }

    /// Per-install random salt (32 bytes), persisted in the Keychain. Keeps trace
    /// tokens stable within an install while making them non-reversible (no
    /// rainbow-tabling low-entropy pet names) and non-linkable across installs.
    private static let traceTokenSalt: Data = {
        let account = "checkout.trace.token.salt"
        if let stored = KeychainStorage.string(forKey: account),
           let data = Data(base64Encoded: stored) {
            return data
        }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        _ = KeychainStorage.set(data.base64EncodedString(), forKey: account)
        return data
    }()

    /// Returns a salted, keyed (HMAC-SHA256) trace token without storing the
    /// original customer-visible text. The per-install salt makes the token
    /// non-reversible and non-linkable across installs (replaces the prior
    /// unsalted hash, which was brute-forceable for low-entropy pet names).
    private static func pseudonymousToken(for value: String) -> String {
        let key = SymmetricKey(data: traceTokenSalt)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.lowercased().utf8), using: key)
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Logger {
    static let checkoutTrace = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pawtrackr", category: "CheckoutTrace")
}

private extension Array where Element == String {
    /// Keeps the newest complete lines that fit within a UTF-8 byte budget.
    func trimmedToUTF8ByteLimit(_ maxBytes: Int) -> [String] {
        guard maxBytes > 0 else { return [] }

        var keptNewestFirst: [String] = []
        var byteCount = 0

        for line in reversed() {
            let separatorBytes = keptNewestFirst.isEmpty ? 0 : 1
            let lineBytes = line.utf8.count
            let nextByteCount = byteCount + separatorBytes + lineBytes

            if nextByteCount <= maxBytes {
                keptNewestFirst.append(line)
                byteCount = nextByteCount
            } else if keptNewestFirst.isEmpty {
                let suffix = line.utf8.suffix(maxBytes)
                return [String(decoding: suffix, as: UTF8.self)]
            } else {
                break
            }
        }

        return keptNewestFirst.reversed()
    }
}
