import Foundation
import SwiftData

/// Cancels long-lived observation without retaining the view model that owns it.
final class EventObservationLifetime {
    var task: Task<Void, Never>?
    var notificationTokens: [NSObjectProtocol] = []
    deinit {
        task?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
}

/// Turns successful writes from this container into presentation invalidations.
/// The saving context is inspected on its own executor; only a signal crosses
/// to MainActor. Readers then retain a fresh graph rather than dirtying stale models.
@MainActor
final class LocalStoreCommitBridge {
    private var observer: NSObjectProtocol?
    private var deliveryTask: Task<Void, Never>?
    private let eventBus: GlobalEventBus

    /// Registers before writers run, including writers invoked by App Intents.
    init(container: ModelContainer, eventBus: GlobalEventBus) {
        self.eventBus = eventBus
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] notification in
            guard let writer = notification.object as? ModelContext,
                  writer.container === container else { return }
            Task { @MainActor [weak self] in self?.scheduleDelivery() }
        }
    }

    /// Coalesces a burst of saves while retaining a delivery for the final commit.
    private func scheduleDelivery() {
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.deliveryTask = nil
            self.eventBus.publish(.storeCommitted)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        deliveryTask?.cancel()
    }
}
