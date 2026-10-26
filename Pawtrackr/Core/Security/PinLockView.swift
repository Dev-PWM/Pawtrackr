//
//  PinLockView.swift
//  Pawtrackr
//
//  Standalone 4-digit PIN (default: 1994) + a reusable gate wrapper.
//  No changes required in PawtrackrApp.swift.
//

import SwiftUI

// MARK: - Gate Wrapper
/// Wrap any sensitive content with this. While locked, it shows the PIN UI.
/// Usage:
///   PinLockGate { ClientsView() }   // or PetHistoryView(), etc.
public struct PinLockGate<Content: View>: View {
    @State private var isUnlocked = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var appSettings
    @State private var inactivityTimer: Timer? = nil
    private let onUnlock: () -> Void
    private let content: Content

    public init(onUnlock: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.onUnlock = onUnlock
        self.content = content()
    }

    public var body: some View {
        trackedGateContent
            .onChange(of: scenePhase) { _, phase in
                if appSettings.autoLockOnBackground, phase != .active {
                    isUnlocked = false
                    invalidateInactivityTimer()
                } else if phase == .active {
                    resetInactivityLock()
                }
            }
            .onChange(of: appSettings.autoLockAfterInactivity) { _, _ in resetInactivityLock() }
            // A shorter timeout must apply now, not after the next drag.
            .onChange(of: appSettings.idleLockMinutes) { _, _ in resetInactivityLock() }
            .onChange(of: appSettings.isBiometricLockEnabled) { _, _ in resetInactivityLock() }
            .onChange(of: appSettings.isLockEnabled) { _, enabled in
                if !enabled {
                    isUnlocked = true
                    onUnlock()
                }
                resetInactivityLock()
            }
            .onChange(of: isUnlocked) { _, unlocked in
                if unlocked {
                    onUnlock()
                    resetInactivityLock()
                } else {
                    invalidateInactivityTimer()
                }
            }
            .onAppear {
                if !appSettings.isLockEnabled || !appSettings.isPINSet {
                    isUnlocked = true
                    onUnlock()
                }
                resetInactivityLock()
            }
            .onDisappear { invalidateInactivityTimer() }
    }

    @ViewBuilder
    private var trackedGateContent: some View {
        if shouldTrackInactivity {
            gateContent.simultaneousGesture(activityResetGesture)
        } else {
            gateContent
        }
    }

    @ViewBuilder
    private var gateContent: some View {
        if isUnlocked || !appSettings.isLockEnabled || !appSettings.isPINSet {
            content
        } else {
            PinLockView(isUnlocked: $isUnlocked)
        }
    }

    private var shouldTrackInactivity: Bool {
        appSettings.autoLockAfterInactivity && appSettings.isLockEnabled
    }

    private var activityResetGesture: some Gesture {
        // IMPORTANT: do NOT use `minimumDistance: 0` here. A zero-distance
        // simultaneous DragGesture registers every touch as a drag from
        // the first frame, which on iPad NavigationSplitView silently
        // breaks the system sidebar toggle tap AND the sidebar `List`
        // row-selection taps — the drag fires first, SwiftUI's tap
        // recognizers never see a clean tap end, and the user has to
        // swipe / use arrow keys instead. A small but non-zero distance
        // lets real touches resolve as taps and only treats sustained
        // movement as activity. Pure motionless taps won't reset the
        // inactivity timer; that's acceptable because the buttons users
        // actually tap have their own action paths that can reset the
        // timer, and any realistic finger interaction includes >5pt of
        // motion.
        DragGesture(minimumDistance: 8)
            .onChanged { _ in resetInactivityLock() }
            .onEnded { _ in resetInactivityLock() }
    }

    private func resetInactivityLock() {
        invalidateInactivityTimer()
        guard appSettings.autoLockAfterInactivity, appSettings.isLockEnabled else { return }
        let interval = max(1, appSettings.idleLockMinutes * 60)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: false) { _ in
            isUnlocked = false
        }
    }

    private func invalidateInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }
}

// MARK: - Lock Screen (4 digits; default PIN 1994)
public struct PinLockView: View {
    /// Brute-force throttling lives in `PinLockoutGuard`, which persists the
    /// failed-attempt count and lockout deadline in the Keychain so force-quit /
    /// relaunch / reinstall can't reset them. This view only mirrors the live
    /// countdown for display.

    @Environment(AppSettings.self) private var appSettings
    @State private var authenticator = BiometricAuthenticator()
    /// Cached biometric type — computing this allocates a fresh `LAContext`
    /// each call, so we resolve once on appear instead of inside `body`
    /// (which would churn an LAContext on every redraw).
    @State private var cachedBiometricType: BiometricType = .none
    @Binding var isUnlocked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var digits: [Int] = []
    @State private var shakeOffset: CGFloat = 0
    @State private var lockoutCountdown: TimeInterval = 0
    @State private var lockoutTimer: Timer? = nil

    // Uses AppSettings.appPIN for a changeable PIN.

    public init(isUnlocked: Binding<Bool>) {
        self._isUnlocked = isUnlocked
    }

    public var body: some View {
        lockContent
            .padding(24)
            .frame(maxWidth: 420)
            .onAppear {
                cachedBiometricType = authenticator.biometricType()
                resumeLockoutCountdownIfNeeded()
                authenticateWithBiometrics()
            }
            .onDisappear {
                lockoutTimer?.invalidate()
                lockoutTimer = nil
            }
            .accessibilityElement(children: .contain)
    }

    private var isLockedOut: Bool { PinLockoutGuard.isLockedOut }

    private var lockContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            titleSection
            pinDots
            keypad
            Spacer()
        }
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text(AppLocalization.localized("pin.enter")).font(.title2).bold()
            if isLockedOut {
                Text(String(format: AppLocalization.localized("pin.lockout_fmt", value: "Too many incorrect attempts. Try again in %ds."), Int(lockoutCountdown.rounded(.up))))
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(AppLocalization.localized("pin.requirement"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pinDots: some View {
        HStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { idx in
                Circle()
                    .fill(idx < digits.count ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 14, height: 14)
            }
        }
        .offset(x: shakeOffset)
        .animation(.easeInOut(duration: 0.06), value: shakeOffset)
    }

    private var keypad: some View {
        VStack(spacing: 12) {
            keyRow([1,2,3])
            keyRow([4,5,6])
            keyRow([7,8,9])
            keypadBottomRow
        }
    }

    private var keypadBottomRow: some View {
        HStack(spacing: 12) {
            switch cachedBiometricType {
            case .faceID:
                KeyButton(systemName: "faceid") { authenticateWithBiometrics() }
                    .accessibilityLabel(AppLocalization.localized("pin.face_id_a11y", value: "Authenticate with Face ID"))
            case .touchID:
                KeyButton(systemName: "touchid") { authenticateWithBiometrics() }
                    .accessibilityLabel(AppLocalization.localized("pin.touch_id_a11y", value: "Authenticate with Touch ID"))
            case .unavailable, .none:
                // Biometrics either don't exist on this device, or are
                // temporarily unavailable (lockout/not-enrolled). PIN-only.
                KeypadSpacer()
            }
            KeyButton(label: "0") { tapDigit(0) }
            KeyButton(systemName: "delete.left.fill") { deleteDigit() }
                .accessibilityLabel(AppLocalization.localized("common.delete"))
        }
    }

    private func authenticateWithBiometrics() {
        // Biometric path bypasses the PIN lockout intentionally — the
        // operating system already enforces its own retry limits and
        // failure thresholds, so a successful Face ID / Touch ID is a
        // strong enough signal to clear the cooldown.
        switch cachedBiometricType {
        case .faceID, .touchID:
            break
        case .none, .unavailable:
            return
        }
        authenticator.authenticate { success, _ in
            if success {
                resetLockoutState()
                isUnlocked = true
            }
        }
    }

    // MARK: - Rows
    @ViewBuilder
    private func keyRow(_ values: [Int]) -> some View {
        HStack(spacing: 12) {
            ForEach(values, id: \.self) { v in
                KeyButton(label: String(v)) { tapDigit(v) }
            }
        }
    }

    // MARK: - Actions
    private func tapDigit(_ v: Int) {
        guard !isLockedOut else { return }
        guard digits.count < 4 else { return }
        digits.append(v)
        // Validate from the tap (not via .onChange(of: digits)) so we never
        // mutate `digits` inside its own change handler — that produced the
        // "onChange(of: Array<Int>) tried to update multiple times per frame"
        // runtime warning.
        if digits.count == 4 { validateIfComplete() }
    }

    private func deleteDigit() {
        guard !digits.isEmpty else { return }
        _ = digits.removeLast()
    }

    private func validateIfComplete() {
        guard digits.count == 4 else { return }
        // Defense in depth: the keypad refuses input during lockout, but
        // also reject here in case state ever advances some other way.
        guard !isLockedOut else {
            digits.removeAll()
            return
        }

        let entered = digits.map(String.init).joined()
        if appSettings.validatePIN(entered) {
            resetLockoutState()
            isUnlocked = true
        } else {
            performShake()
            HapticManager.notify(.error)

            // Persisted via the Keychain so a force-quit can't reset the count.
            // Once the threshold is hit this opens (or escalates) the lockout.
            if PinLockoutGuard.registerFailure() != nil {
                startLockoutCountdown()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                digits.removeAll()
            }
        }
    }

    /// Resumes the visible countdown when the view appears mid-lockout — e.g.
    /// the user force-quit during a cooldown and relaunched; the deadline
    /// persisted in the Keychain, so the lock screen must keep counting down
    /// instead of silently granting a fresh batch of attempts.
    private func resumeLockoutCountdownIfNeeded() {
        guard PinLockoutGuard.isLockedOut else { return }
        startLockoutCountdown()
    }

    /// Drives the on-screen countdown from the persisted deadline. `PinLockoutGuard`
    /// is the source of truth; this timer only refreshes the label and stops once
    /// the deadline passes.
    private func startLockoutCountdown() {
        lockoutCountdown = PinLockoutGuard.remaining
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor in
                let remaining = PinLockoutGuard.remaining
                if remaining <= 0 {
                    timer.invalidate()
                    lockoutTimer = nil
                    lockoutCountdown = 0
                    // Deadline elapsed: `isLockedOut` is already false (it compares
                    // against the stored deadline). We deliberately keep the
                    // escalated attempt count so renewed guessing jumps to the
                    // next, longer rung. A successful unlock clears everything.
                } else {
                    lockoutCountdown = remaining
                }
            }
        }
    }

    private func resetLockoutState() {
        lockoutTimer?.invalidate()
        lockoutTimer = nil
        lockoutCountdown = 0
        PinLockoutGuard.reset()
    }

    private func performShake() {
        // The error haptic and cleared dots still signal a wrong PIN.
        guard !reduceMotion else { return }
        let sequence: [CGFloat] = [-10, 10, -8, 8, -5, 5, 0]
        var delay: Double = 0
        for x in sequence {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.06)) { shakeOffset = x }
            }
            delay += 0.06
        }
    }
}

// MARK: - Keypad Pieces
private struct KeyButton: View {
    var label: String? = nil
    var systemName: String? = nil
    var action: () -> Void

    init(label: String, action: @escaping () -> Void) {
        self.label = label; self.action = action
    }
    init(systemName: String, action: @escaping () -> Void) {
        self.systemName = systemName; self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.12))
                if let label { Text(label).font(.title2).fontWeight(.semibold) }
                if let systemName { Image(systemName: systemName).font(.title2) }
            }
            .frame(width: 74, height: 74)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }
}

private struct KeypadSpacer: View {
    var body: some View { Circle().fill(Color.clear).frame(width: 74, height: 74) }
}
