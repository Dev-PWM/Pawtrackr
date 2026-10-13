//
//  GlobalEventBus.swift
//  Pawtrackr
//
//  Lightweight event bus for cross-module communication using AsyncStream.
//

import Foundation
import SwiftData
import Combine

struct CheckoutCompletionContext: Equatable {
    let visitID: PersistentIdentifier
    let petID: PersistentIdentifier?
    let clientID: PersistentIdentifier?
    let endedAt: Date
    let total: Decimal
}

enum AppEvent: Equatable {
    case storeCommitted
    case checkoutCompleted(CheckoutCompletionContext)
    case dataStoreReset
    case refreshRequired
    case clientCreated(clientID: PersistentIdentifier)
    case navigateToPet(petID: PersistentIdentifier)
    case navigateToClient(clientID: PersistentIdentifier)
    case clientOpenRequested(clientID: PersistentIdentifier)
    case selectNavigationItem(item: String)
    case showNewClientSheet
    
    static func == (lhs: AppEvent, rhs: AppEvent) -> Bool {
        switch (lhs, rhs) {
        case (.storeCommitted, .storeCommitted),
             (.dataStoreReset, .dataStoreReset),
             (.refreshRequired, .refreshRequired),
             (.showNewClientSheet, .showNewClientSheet):
            return true
        case (.checkoutCompleted(let lhs), .checkoutCompleted(let rhs)):
            return lhs == rhs
        case (.clientCreated(let id1), .clientCreated(let id2)),
             (.navigateToPet(let id1), .navigateToPet(let id2)),
             (.navigateToClient(let id1), .navigateToClient(let id2)),
             (.clientOpenRequested(let id1), .clientOpenRequested(let id2)):
            return id1 == id2
        case (.selectNavigationItem(let i1), .selectNavigationItem(let i2)):
            return i1 == i2
        default:
            return false
        }
    }
}

@Observable
final class GlobalEventBus {
    private var continuations: [ObjectIdentifier: AsyncStream<AppEvent>.Continuation] = [:]
    
    // We use a broadcast-like pattern or a simple publisher
    private var subject = PassthroughSubject<AppEvent, Never>()
    
    func publish(_ event: AppEvent) {
        subject.send(event)
    }
    
    var stream: AsyncStream<AppEvent> {
        AsyncStream { continuation in
            let cancellable = subject.sink { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
