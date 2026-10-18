import SwiftUI

/// A reward milestone with finite fill movement and a resource-gated, clock-driven light sweep.
struct AnimatedRewardProgressBar: View {
    let currentPoints: Int
    let targetPoints: Int
    let rewardTitle: String

    var body: some View {
        MotionAwareView { allowsMotion in
            RewardProgressTrack(progress: Self.fraction(points: currentPoints, target: targetPoints),
                                allowsMotion: allowsMotion)
        }
        .frame(height: 18)
        .accessibilityRepresentation {
            ProgressView(value: Self.fraction(points: currentPoints, target: targetPoints))
                .accessibilityLabel(rewardTitle)
                .accessibilityValue(String(format: AppLocalization.localized(
                    "loyalty.client.progress_value_fmt", value: "%1$d of %2$d points"
                ), min(max(0, currentPoints), max(0, targetPoints)), max(0, targetPoints)))
        }
        .accessibilityIdentifier("clientLoyalty.animatedProgress")
    }

    /// Keeps zero, negative and overfunded balances within the bar without changing saved points.
    static func fraction(points: Int, target: Int) -> CGFloat {
        guard target > 0 else { return 0 }
        return min(1, max(0, CGFloat(points) / CGFloat(target)))
    }
}

private struct RewardProgressTrack: View {
    let progress: CGFloat
    let allowsMotion: Bool
    @State private var displayed: CGFloat

    init(progress: CGFloat, allowsMotion: Bool) {
        self.progress = progress
        self.allowsMotion = allowsMotion
        _displayed = State(initialValue: progress)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let fill = width * (allowsMotion ? displayed : progress)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.ColorToken.border.opacity(0.65)).frame(height: 12)
                if fill > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [DS.ColorToken.primary, .blue, .cyan],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: fill, height: 12)
                        .overlay {
                            if allowsMotion {
                                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                                    let phase = context.date.timeIntervalSinceReferenceDate
                                        .truncatingRemainder(dividingBy: 2.4) / 2.4
                                    LinearGradient(colors: [.clear, .white.opacity(0.65), .clear],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                        .frame(width: max(16, fill * 0.4))
                                        .offset(x: CGFloat(phase * 1.6 - 0.6) * fill)
                                }
                                .clipShape(Capsule())
                            }
                        }
                    progressTip(fill: fill, width: width)
                }
            }
            .frame(height: geometry.size.height)
        }
        .onChange(of: allowsMotion) { _, permitted in
            if !permitted { displayed = progress }
        }
        .onChange(of: progress) { _, value in
            withAnimation(allowsMotion ? .spring(response: 0.75, dampingFraction: 0.78) : nil) { displayed = value }
        }
    }

    /// Keeps the light at the fill's edge and inside the available width.
    private func progressTip(fill: CGFloat, width: CGFloat) -> some View {
        Group {
            if allowsMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let pulse = sin(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.2)
                    tip.scaleEffect(1 + pulse * 0.08)
                }
            } else {
                tip
            }
        }
        .frame(width: 14, height: 14)
        .offset(x: max(0, min(width - 14, fill - 7)))
    }

    private var tip: some View {
        Image(systemName: progress >= 1 ? "gift.fill" : "sparkle")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(DS.ColorToken.primary, in: Circle())
            .shadow(color: allowsMotion ? DS.ColorToken.primary.opacity(0.3) : .clear,
                    radius: allowsMotion ? 4 : 0)
    }
}
