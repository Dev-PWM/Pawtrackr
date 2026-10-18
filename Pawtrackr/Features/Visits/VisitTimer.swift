//
//  VisitTimer.swift
//  Pawtrackr
//
//  Created by mac on 8/17/25.
//

import Foundation
import Combine

/// A lightweight, UI-friendly stopwatch for active visits.
/// - Does **not** reference app model types to avoid access-control cycles.
/// - Ticks on the main actor every 1s with a small tolerance to save battery.
/// - Survives background/foreground by computing elapsed from absolute dates.
@MainActor
final class VisitTimer: ObservableObject {

    // MARK: - Published state

    /// `true` while the timer is running.
    @Published private(set) var isRunning: Bool = false

    /// Start timestamp for the current run.
    @Published private(set) var startedAt: Date?

    /// Optional end timestamp (set on stop); nil while running.
    @Published private(set) var endedAt: Date?

    /// Whole seconds elapsed for the *current* run (derived from `startedAt`).
    /// The only per-tick published value, so each second invalidates observers once.
    @Published private(set) var elapsedSeconds: Int = 0

    /// Human-friendly clock string like "1h 12m" (USD app uses English).
    var formattedElapsed: String { Self.format(seconds: elapsedSeconds) }

    /// Accessibility-friendly, fully spelled-out duration (e.g., "1 hour 2 minutes", "45 seconds").
    var accessibilityElapsedLabel: String { Self.spelledOut(seconds: elapsedSeconds) }

    // MARK: - Internal state

    /// Accumulated seconds from previous runs (if the timer was paused/resumed).
    private var accumulatedSeconds: Int = 0

    /// Subscription to the shared time hub to keep all timers in sync.
    private var tickSubscription: AnyCancellable?

    // MARK: - Lifecycle

    deinit {
        // Avoid cross-actor call in deinit by inlining cancellation.
        tickSubscription?.cancel()
        tickSubscription = nil
    }

    // MARK: - Public API

    /// Call when the scene becomes active/foreground. Safely restarts ticking if needed and snaps the UI to now.
    func sceneBecameActive(now: Date = .now) {
        if isRunning { if tickSubscription == nil { beginTicking() }; updateElapsed(now: now) }
    }

    /// Call when the scene resigns active/backgrounds. Stops ticking to save battery and freezes the current elapsed.
    func sceneWillResignActive(now: Date = .now) {
        if isRunning { updateElapsed(now: now) }
        endTicking()
    }

    /// Manually force an elapsed recompute (does not alter running/paused state).
    func refresh(now: Date = .now) {
        updateElapsed(now: now)
        if isRunning && tickSubscription == nil { beginTicking() }
    }

    /// Start (or resume) the timer at a specific wall-clock time.
    /// - Parameter date: If omitted, uses `Date.now`.
    func start(at date: Date = .now) {
        guard !isRunning else { return }

        // If resuming with prior accumulation, shift startedAt back by that amount.
        if startedAt == nil {
            if accumulatedSeconds > 0 {
                startedAt = date.addingTimeInterval(TimeInterval(-accumulatedSeconds))
            } else {
                startedAt = date
            }
        } else {
            // Defensive: ensure accumulation is respected if a prior start exists
            startedAt = date.addingTimeInterval(TimeInterval(-accumulatedSeconds))
        }

        endedAt = nil
        isRunning = true
        beginTicking()
        updateElapsed(now: date)
    }

    /// Stop the timer and freeze elapsed.
    /// - Parameter date: If omitted, uses `Date.now`.
    func stop(at date: Date = .now) {
        guard isRunning else { return }
        isRunning = false
        endedAt = date

        // Finalize accumulation and clear startedAt (we keep endedAt for reference).
        if let started = startedAt {
            accumulatedSeconds = Self.seconds(between: started, and: date)
        }
        startedAt = nil

        endTicking()
        updateElapsed(now: date)
    }

    /// Pause the timer without marking an end date (can be resumed).
    func pause(at date: Date = .now) {
        guard isRunning else { return }
        if let started = startedAt {
            accumulatedSeconds = Self.seconds(between: started, and: date)
        }
        isRunning = false
        startedAt = nil
        // Keep `endedAt` as nil to indicate a paused (not finished) session.
        endTicking()
        updateElapsed(now: date)
    }

    /// Reset to initial state (not running, zeroed time).
    func reset() {
        endTicking()
        isRunning = false
        startedAt = nil
        endedAt = nil
        accumulatedSeconds = 0
        elapsedSeconds = 0
    }

    /// Initialize the timer from persisted visit dates (e.g., when opening a screen).
    /// If `end` is nil, the timer will begin (or continue) ticking from `start`.
    func load(startedAt start: Date, endedAt end: Date?) {
        if let end {
            // Completed visit — freeze at the final elapsed value.
            isRunning = false
            startedAt = nil
            endedAt = end
            accumulatedSeconds = max(0, Self.seconds(between: start, and: end))
            elapsedSeconds = accumulatedSeconds
            endTicking()
        } else {
            // Active visit — compute from absolute start and keep ticking.
            accumulatedSeconds = 0
            startedAt = min(start, .now) // defensive: avoid future starts
            endedAt = nil
            isRunning = true
            beginTicking()
            updateElapsed(now: .now)
        }
    }

    /// Manually set the elapsed total (e.g., when restoring from a visit).
    /// If `running` is true, it will continue from this value.
    func setElapsed(seconds: Int, running: Bool) {
        accumulatedSeconds = max(0, seconds)
        if running {
            // Continue from now with accumulated baseline.
            startedAt = .now.addingTimeInterval(TimeInterval(-accumulatedSeconds))
            endedAt = nil
            isRunning = true
            beginTicking()
            updateElapsed(now: .now)
        } else {
            startedAt = nil
            endedAt = .now
            isRunning = false
            endTicking()
            elapsedSeconds = accumulatedSeconds
        }
    }

    // MARK: - Formatting

    /// Short human format like `1h 05m`, `12m`, or `45s` for sub-minute.
    static func format(seconds: Int) -> String {
        Formatters.durationString(seconds: seconds)
    }

    /// Fully spelled-out duration for VoiceOver (e.g., "1 hour 2 minutes", "12 minutes", "45 seconds").
    static func spelledOut(seconds: Int) -> String {
        let s = max(0, seconds)
        // Prefer hours+minutes when applicable, else minutes, else seconds.
        let f = s >= 3600 ? hourMinuteFormatter : (s >= 60 ? minuteFormatter : secondFormatter)
        return f.string(from: TimeInterval(s)) ?? "\(s) seconds"
    }

    // Live timers ask for this label every second, so the formatters are built once.
    // The autoupdating calendar keeps them following the system locale like a fresh formatter.
    private static let hourMinuteFormatter = makeSpelledOutFormatter([.hour, .minute])
    private static let minuteFormatter = makeSpelledOutFormatter([.minute])
    private static let secondFormatter = makeSpelledOutFormatter([.second])

    private static func makeSpelledOutFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let f = DateComponentsFormatter()
        f.calendar = .autoupdatingCurrent
        f.unitsStyle = .full
        f.allowedUnits = units
        f.zeroFormattingBehavior = [.dropAll]
        return f
    }

    // MARK: - Private helpers

    private func beginTicking() {
        // Subscribe to the shared hub so all timers update in sync.
        tickSubscription?.cancel()
        tickSubscription = TimeHub.shared.$now.sink { [weak self] now in
            self?.updateElapsed(now: now)
        }
    }

    private func endTicking() {
        tickSubscription?.cancel()
        tickSubscription = nil
    }

    private func updateElapsed(now: Date) {
        let newValue: Int
        if let started = startedAt {
            newValue = Self.seconds(between: started, and: now)
        } else {
            newValue = accumulatedSeconds
        }
        if newValue != elapsedSeconds {
            elapsedSeconds = newValue
        }
    }

    private static func seconds(between from: Date, and to: Date) -> Int {
        max(0, Int(to.timeIntervalSince(from)))
    }
}

// MARK: - Preview / Manual test hooks (DEBUG only)

#if DEBUG
extension VisitTimer {
    static func demoRunning() -> VisitTimer {
        let t = VisitTimer()
        t.setElapsed(seconds: 75, running: true) // 1m 15s and counting
        return t
    }
    static func demoStopped() -> VisitTimer {
        let t = VisitTimer()
        t.setElapsed(seconds: 3725, running: false) // 1h 2m 5s
        return t
    }
}
#endif
