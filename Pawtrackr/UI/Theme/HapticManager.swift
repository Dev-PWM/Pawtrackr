import Foundation

#if os(iOS)
import UIKit
import CoreHaptics
#elseif os(macOS)
import AppKit
#endif

/// The meaning of an interaction, independent of the device's available actuator.
enum HapticEvent: Hashable, Sendable {
    case press, selection, navigation, step, confirmation, reward, success, warning, error

    /// Committed results and failures take precedence over incidental touch feedback.
    var isOutcome: Bool { self == .success || self == .warning || self == .error }

    /// Filters duplicates while allowing separate deliberate interactions.
    var minimumInterval: TimeInterval {
        switch self {
        case .selection: return 0.055
        case .press, .navigation, .step, .reward: return 0.12
        case .confirmation: return 0.30
        case .success, .warning: return 0.45
        case .error: return 0.60
        }
    }
}

/// Deterministic arbitration using monotonic time; never queues feedback to play later.
struct HapticFeedbackPolicy {
    private var lastPlayed: (event: HapticEvent, time: TimeInterval)?
    private var eventTimes: [HapticEvent: TimeInterval] = [:]

    /// Accepts an eligible signal without letting touch effects obscure a result.
    mutating func shouldPlay(_ event: HapticEvent, at time: TimeInterval, enabled: Bool,
                             active: Bool, supported: Bool, constrained: Bool) -> Bool {
        guard enabled, active, supported else {
            reset()
            return false
        }
        guard time.isFinite else { return false }
        if constrained && !event.isOutcome && event != .confirmation { return false }
        if let previous = eventTimes[event], time - previous < event.minimumInterval { return false }
        if let lastPlayed, !event.isOutcome, event != .confirmation {
            let quietPeriod = lastPlayed.event.isOutcome ? 0.20 : 0.045
            if time - lastPlayed.time < quietPeriod { return false }
        }
        eventTimes[event] = time
        lastPlayed = (event, time)
        return true
    }

    /// Clears transient arbitration after backgrounding or a preference change.
    mutating func reset() {
        lastPlayed = nil
        eventTimes.removeAll(keepingCapacity: true)
    }
}

/// Main-actor-only native feedback, gated by preferences, foreground state and hardware.
@MainActor
enum HapticManager {
    enum Impact: CaseIterable, Sendable { case light, medium, heavy, soft, rigid }
    enum NotificationType: Sendable { case success, warning, error }
    private static var policy = HapticFeedbackPolicy()

    #if os(iOS)
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGen = UISelectionFeedbackGenerator()
    private static let notificationGen = UINotificationFeedbackGenerator()
    private static let hardwareSupportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    #endif

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.hapticsEnabled) as? Bool ?? true
    }

    private static var isActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApp?.isActive == true
        #else
        false
        #endif
    }

    /// The system remains responsible for whether a supported actuator actually responds.
    private static var isSupported: Bool {
        #if os(iOS)
        hardwareSupportsHaptics
        #elseif os(macOS)
        true // AppKit safely handles the availability of a Force Touch trackpad.
        #else
        false
        #endif
    }

    private static var isConstrained: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled ||
            ProcessInfo.processInfo.thermalState == .serious ||
            ProcessInfo.processInfo.thermalState == .critical
    }

    /// Applies Settings changes immediately, including a fresh cue when feedback is enabled.
    static func preferenceDidChange() {
        policy.reset()
        if isEnabled { play(.selection) }
    }

    /// Warms the relevant native generator before an anticipated interaction or save result.
    static func prepare(_ event: HapticEvent) {
        guard isEnabled, isActive, isSupported else { return }
        guard !isConstrained || event.isOutcome || event == .confirmation else { return }
        #if os(iOS)
        switch event {
        case .selection, .navigation, .step: selectionGen.prepare()
        case .success, .warning, .error: notificationGen.prepare()
        case .confirmation: mediumGen.prepare()
        case .press, .reward: softGen.prepare()
        }
        #endif
    }

    /// Plays promptly or drops the event; never schedules a stale or background vibration.
    static func play(_ event: HapticEvent, impact style: Impact? = nil) {
        guard policy.shouldPlay(event, at: ProcessInfo.processInfo.systemUptime,
                                enabled: isEnabled, active: isActive, supported: isSupported,
                                constrained: isConstrained) else { return }
        #if os(iOS)
        switch event {
        case .selection, .navigation, .step:
            selectionGen.selectionChanged()
            selectionGen.prepare()
        case .success, .warning, .error:
            let type: UINotificationFeedbackGenerator.FeedbackType =
                event == .success ? .success : (event == .warning ? .warning : .error)
            notificationGen.notificationOccurred(type)
        case .press, .confirmation, .reward:
            let generator = impactGenerator(style ?? (event == .confirmation ? .medium : .soft))
            generator.impactOccurred(intensity: event == .press ? 0.55 : (event == .reward ? 0.8 : 1.0))
            generator.prepare()
        }
        #elseif os(macOS)
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch event {
        case .selection, .navigation, .step, .success: pattern = .alignment
        case .confirmation, .warning, .error: pattern = .levelChange
        case .press, .reward: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
        #endif
    }

    /// Retains existing call sites while using the same arbitration as semantic events.
    static func impact(_ style: Impact = .light) { play(.press, impact: style) }

    /// Selection feedback also maps to alignment on a compatible macOS trackpad.
    static func selectionChanged() { play(.selection) }

    /// Success, warning and error represent actual outcomes, not the start of an operation.
    static func notify(_ type: NotificationType) {
        switch type {
        case .success: play(.success)
        case .warning: play(.warning)
        case .error: play(.error)
        }
    }

    #if os(iOS)
    /// Reuses generators rather than allocating a feedback engine for every interaction.
    private static func impactGenerator(_ style: Impact) -> UIImpactFeedbackGenerator {
        switch style {
        case .light: lightGen
        case .medium: mediumGen
        case .heavy: heavyGen
        case .soft: softGen
        case .rigid: rigidGen
        }
    }
    #endif
}
