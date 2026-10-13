//
//  MotionSystem.swift
//  Pawtrackr
//
//  Central motion primitives for interaction feedback, accessibility, and
//  thermal-aware visual effects.
//

import Foundation
import SwiftUI

enum MotionSystem {
    static let pressScale: CGFloat = 0.97

    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.82, blendDuration: 0.04)
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68, blendDuration: 0.08)
    static let fluid = Animation.spring(response: 0.55, dampingFraction: 0.86, blendDuration: 0.12)

    static let fastEaseOut = Animation.easeOut(duration: 0.20)
    static let breathe = Animation.easeInOut(duration: 8).repeatForever(autoreverses: true)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) ? animation : nil
    }
}

enum MotionGovernor {
    /// Evaluates motion constraints without starting a timer or a rendering workload.
    static func shouldAnimate(
        reduceMotion: Bool,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        sceneIsActive: Bool = true
    ) -> Bool {
        guard !reduceMotion, !lowPowerMode, sceneIsActive else { return false }
        switch thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = MotionSystem.pressScale
    var hapticsEnabled = false
    var hapticStyle: HapticManager.Impact = .soft
    var hapticEvent: HapticEvent = .press

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(MotionSystem.resolved(MotionSystem.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, hapticsEnabled, isEnabled {
                    HapticManager.play(hapticEvent, impact: hapticEvent == .press ? hapticStyle : nil)
                }
            }
    }
}

struct InsightsMeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = false
    @State private var resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)

    private var shouldAnimate: Bool {
        resourceAllowsAnimation && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        ZStack {
            DS.ColorToken.background

            if shouldAnimate {
                animatedBackground
                    .transition(.opacity)
            } else {
                fallbackGradient
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: DispatchQueue.main)) { _ in
            resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: DispatchQueue.main)) { _ in
            resourceAllowsAnimation = MotionGovernor.shouldAnimate(reduceMotion: false)
        }
    }

    @ViewBuilder
    private var animatedBackground: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: phase ? phaseBPoints : phaseAPoints,
                colors: meshColors
            )
            .opacity(0.46)
            .blur(radius: 24)
            .animation(MotionSystem.breathe, value: phase)
            .onAppear { phase = true }
            .onDisappear { phase = false }
        } else {
            fallbackGradient
        }
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [
                DS.ColorToken.primary.opacity(0.16),
                DS.ColorToken.success.opacity(0.10),
                DS.ColorToken.background
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var meshColors: [Color] {
        [
            DS.ColorToken.primary.opacity(0.42),
            DS.ColorToken.info.opacity(0.28),
            DS.ColorToken.success.opacity(0.24),
            DS.ColorToken.warning.opacity(0.16),
            DS.ColorToken.background.opacity(0.10),
            DS.ColorToken.primary.opacity(0.18),
            DS.ColorToken.success.opacity(0.20),
            DS.ColorToken.info.opacity(0.16),
            DS.ColorToken.background.opacity(0.08)
        ]
    }

    private var phaseAPoints: [SIMD2<Float>] {
        [
            [0.00, 0.00], [0.48, 0.02], [1.00, 0.00],
            [0.03, 0.50], [0.52, 0.48], [0.98, 0.52],
            [0.00, 1.00], [0.50, 0.98], [1.00, 1.00]
        ]
    }

    private var phaseBPoints: [SIMD2<Float>] {
        [
            [0.00, 0.00], [0.54, 0.06], [1.00, 0.00],
            [0.06, 0.44], [0.48, 0.54], [0.94, 0.48],
            [0.00, 1.00], [0.46, 0.94], [1.00, 1.00]
        ]
    }
}

extension View {
    /// Uses the shared motion policy and an optional semantic tactile cue.
    func pressScaleStyle(hapticsEnabled: Bool = false, hapticEvent: HapticEvent = .press) -> some View {
        buttonStyle(PressScaleButtonStyle(hapticsEnabled: hapticsEnabled, hapticEvent: hapticEvent))
    }

    func motionAnimation(_ animation: Animation, value: some Equatable) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(MotionSystem.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}
