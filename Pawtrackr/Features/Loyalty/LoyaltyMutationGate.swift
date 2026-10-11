import Foundation

/// Serializes balance mutations for a client across separate model actor instances.
actor LoyaltyMutationGate {
    static let shared = LoyaltyMutationGate()
    private var active = Set<UUID>()
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Reserves the client's balance until the entire transaction has finished.
    func acquire(_ clientUUID: UUID) async {
        if active.insert(clientUUID).inserted { return }
        await withCheckedContinuation { waiters[clientUUID, default: []].append($0) }
    }

    /// Hands the reservation to the next operation, or frees it.
    func release(_ clientUUID: UUID) {
        guard var queue = waiters[clientUUID], !queue.isEmpty else {
            active.remove(clientUUID)
            waiters.removeValue(forKey: clientUUID)
            return
        }
        let next = queue.removeFirst()
        waiters[clientUUID] = queue
        next.resume()
    }
}
