import SwiftUI
import Combine

/// Shares scroll visibility, accessibility, scene and resource constraints with decorative content.
struct MotionAwareView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var resourcesAllowMotion = MotionGovernor.shouldAnimate(reduceMotion: false)
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(isVisible && resourcesAllowMotion && MotionGovernor.shouldAnimate(
            reduceMotion: reduceMotion, sceneIsActive: scenePhase == .active
        ))
        .onAppear { refreshResources() }
        .onScrollVisibilityChange(threshold: 0.15) { isVisible = $0 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshResources() }
        }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in refreshResources() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in refreshResources() }
    }

    /// Rechecks permission when the device enters or leaves a constrained state.
    private func refreshResources() {
        resourcesAllowMotion = MotionGovernor.shouldAnimate(reduceMotion: false)
    }
}
