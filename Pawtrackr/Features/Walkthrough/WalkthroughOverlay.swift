//
//  WalkthroughOverlay.swift
//  Pawtrackr
//
//  The visual layer of the guided tour: dims the whole window, cuts a glowing
//  hole around the current step's control, points an arrow at it, and floats a
//  bubble explaining what it is and why it helps. Hosted at the navigation root
//  so it spotlights the sidebar (Mac/iPad) and the tab bar (iPhone) alike.
//
//  Bubble placement adapts to where the target lives: a sidebar row on the left
//  gets a bubble to its trailing side (arrow pointing left); a bottom tab-bar
//  slot gets a bubble above it (arrow pointing down).
//

import SwiftUI

enum WalkthroughTargetFrame {
    /// Returns a visible, non-trivial target rect in the overlay's local
    /// coordinate space, or nil when SwiftUI handed us a stale/offscreen anchor.
    /// iPad split view and Stage Manager can temporarily report anchors from a
    /// transitioning host; dropping them lets the tour fall back to a centered
    /// bubble instead of drawing a misleading spotlight.
    static func validated(_ rect: CGRect?, in containerSize: CGSize, safeAreaInsets: EdgeInsets) -> CGRect? {
        guard var rect, rect.isFinite, rect.width >= 2, rect.height >= 2,
              containerSize.width >= 2, containerSize.height >= 2
        else { return nil }

        // Only the top and bottom insets clip a target, where content scrolls
        // under the toolbar. See `WalkthroughOverlayLayout.spotlightRect`.
        let visibleBounds = CGRect(
            x: 8,
            y: max(0, safeAreaInsets.top) + 8,
            width: max(1, containerSize.width - 16),
            height: max(1, containerSize.height - max(0, safeAreaInsets.top) - max(0, safeAreaInsets.bottom) - 16)
        )

        rect = rect.standardized
        let intersection = rect.intersection(visibleBounds)
        guard !intersection.isNull, !intersection.isEmpty,
              intersection.width >= 2, intersection.height >= 2
        else { return nil }

        return intersection
    }
}

private extension CGRect {
    var isFinite: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite)
    }
}

enum WalkthroughOverlayLayout {
    enum Placement: Equatable {
        case below
        case above
        case trailing
        case leading
        case center
    }

    enum ArrowDirection: Equatable {
        case up
        case down
        case left
        case right
    }

    struct Result: Equatable {
        let spotlight: CGRect?
        let bubbleFrame: CGRect
        let cardWidth: CGFloat
        let cardMaxHeight: CGFloat
        let placement: Placement
        let arrowDirection: ArrowDirection?
        /// For side placements: the arrow's distance from the top of the
        /// slot, or from its bottom when `hugsBottom`.
        let arrowOffset: CGFloat
        let isCompactViewport: Bool
        /// A side slot had to move up to fit on screen, so it ends near the
        /// target: the card sits at the slot's bottom instead of its top.
        var hugsBottom = false
    }

    private struct Metrics {
        let containerSize: CGSize
        let safeAreaInsets: EdgeInsets

        var isCompactViewport: Bool {
            containerSize.width < 430 || containerSize.height < 760
        }

        var bubbleMaxWidth: CGFloat {
            if containerSize.width >= 900 { return 520 }
            if containerSize.width >= 620 { return 480 }
            return 370
        }

        var horizontalPadding: CGFloat {
            isCompactViewport ? 16 : 20
        }

        var cardWidth: CGFloat {
            min(bubbleMaxWidth, max(1, containerSize.width - horizontalPadding * 2))
        }

        var bubbleMinHeight: CGFloat {
            isCompactViewport ? 150 : 164
        }

        /// The macOS root window draws content — and this overlay — under the
        /// unified toolbar, where the safe-area-ignoring host reports a zero top
        /// inset. Bubbles must stay clear of that chrome or they render over the
        /// traffic lights and toolbar buttons.
        var topChromeClearance: CGFloat {
            #if os(macOS)
            52
            #else
            0
            #endif
        }

        var safeTopPadding: CGFloat {
            max(max(safeAreaInsets.top + 8, 16), topChromeClearance + 8)
        }

        var safeBottomPadding: CGFloat {
            max(safeAreaInsets.bottom + 8, 16)
        }

        var readableBubbleMaxHeight: CGFloat {
            min(isCompactViewport ? 340 : 400, max(220, containerSize.height - safeTopPadding - safeBottomPadding - 20))
        }
    }

    private static let spotlightPadding: CGFloat = 10
    private static let bubbleGap: CGFloat = 16
    private static let compactBubbleGap: CGFloat = 10
    private static let arrowExtent: CGFloat = 11
    private static let trailingGap: CGFloat = 12
    private static let minimumSideBubbleWidth: CGFloat = 260

    static func layout(
        step: WalkthroughStep,
        targetRect: CGRect?,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> Result {
        let metrics = Metrics(containerSize: containerSize, safeAreaInsets: safeAreaInsets)
        let gap = metrics.isCompactViewport ? compactBubbleGap : bubbleGap
        let spotlight = spotlightRect(for: targetRect, metrics: metrics)
        guard let spotlight else {
            let height = boundedCardHeight(
                availableHeight: containerSize.height - metrics.safeTopPadding - metrics.safeBottomPadding,
                metrics: metrics
            )
            let frame = CGRect(
                x: (containerSize.width - metrics.cardWidth) / 2,
                y: (containerSize.height - height) / 2,
                width: metrics.cardWidth,
                height: height
            ).clamped(to: safeBounds(metrics: metrics))
            return Result(
                spotlight: nil,
                bubbleFrame: frame,
                cardWidth: metrics.cardWidth,
                cardMaxHeight: frame.height,
                placement: .center,
                arrowDirection: nil,
                arrowOffset: 0,
                isCompactViewport: metrics.isCompactViewport
            )
        }

        let placement = choosePlacement(for: step, spotlight: spotlight, metrics: metrics, gap: gap)
        let preferred = result(for: placement, spotlight: spotlight, metrics: metrics, gap: gap)
        if isUsable(preferred, spotlight: spotlight, metrics: metrics) {
            return preferred
        }

        for fallbackPlacement in fallbackPlacements(after: placement, spotlight: spotlight, metrics: metrics, gap: gap) {
            let fallback = result(for: fallbackPlacement, spotlight: spotlight, metrics: metrics, gap: gap)
            if isUsable(fallback, spotlight: spotlight, metrics: metrics) {
                return fallback
            }
        }

        return preferred
    }

    /// A bubble is only worth anchoring if it leaves the spotlight clear AND has
    /// room for its copy. A card shorter than `bubbleMinHeight` clips the body
    /// down to bare chrome — a header and footer with no step text — which is the
    /// "empty Back / Skip / Next strip" failure seen on wide macOS windows.
    private static func isUsable(_ result: Result, spotlight: CGRect, metrics: Metrics) -> Bool {
        guard !result.bubbleFrame.intersects(spotlight) else { return false }
        return result.cardMaxHeight >= metrics.bubbleMinHeight
    }

    private static func spotlightRect(for targetRect: CGRect?, metrics: Metrics) -> CGRect? {
        guard let targetRect, targetRect.width > 0, targetRect.height > 0 else { return nil }
        let padded = targetRect.insetBy(dx: -spotlightPadding, dy: -spotlightPadding)
        // The side insets don't clip the spotlight. In a split-view column
        // they are the sidebar's width, which the target's own layout already
        // keeps clear of, and macOS reports that width even when the column
        // starts beside the sidebar. Clipping by it cut the left part off
        // targets in Settings, such as the Academy card on About.
        let bounds = CGRect(
            x: 6,
            y: max(6, metrics.safeAreaInsets.top + 6),
            width: max(1, metrics.containerSize.width - 12),
            height: max(1, metrics.containerSize.height - metrics.safeAreaInsets.top - metrics.safeAreaInsets.bottom - 12)
        )
        let clamped = padded.intersection(bounds)
        return clamped.isNull || clamped.isEmpty ? padded : clamped
    }

    private static func choosePlacement(
        for step: WalkthroughStep,
        spotlight: CGRect,
        metrics: Metrics,
        gap: CGFloat
    ) -> Placement {
        let trailingSpace = metrics.containerSize.width - spotlight.maxX - metrics.horizontalPadding
        let leadingSpace = spotlight.minX - metrics.horizontalPadding
        let minimumSideSpace = minimumSideBubbleWidth + arrowExtent + trailingGap
        if metrics.containerSize.width >= 620 {
            if trailingSpace >= minimumSideSpace,
               trailingSpace > leadingSpace {
                return .trailing
            }

            if leadingSpace >= minimumSideSpace,
               leadingSpace >= trailingSpace {
                return .leading
            }
        }

        if spotlight.midY > metrics.containerSize.height * 0.72 { return .above }

        let below = availableBelow(spotlight: spotlight, metrics: metrics, gap: gap)
        let above = availableAbove(spotlight: spotlight, metrics: metrics, gap: gap)
        let preferredMinimum = metrics.bubbleMinHeight

        if below >= preferredMinimum || below >= above {
            return .below
        }
        if above >= preferredMinimum || above > 0 {
            return .above
        }

        // Keep an anchored bubble outside the target even in cramped layouts.
        // The card body can scroll, but the target must remain visible and tappable.
        return below >= above ? .below : .above
    }

    private static func result(
        for placement: Placement,
        spotlight: CGRect,
        metrics: Metrics,
        gap: CGFloat
    ) -> Result {
        switch placement {
        case .below:
            return verticalResult(below: true, spotlight: spotlight, metrics: metrics, gap: gap)
        case .above:
            return verticalResult(below: false, spotlight: spotlight, metrics: metrics, gap: gap)
        case .trailing:
            return trailingResult(spotlight: spotlight, metrics: metrics)
        case .leading:
            return leadingResult(spotlight: spotlight, metrics: metrics)
        case .center:
            let height = boundedCardHeight(
                availableHeight: metrics.containerSize.height - metrics.safeTopPadding - metrics.safeBottomPadding,
                metrics: metrics
            )
            let frame = CGRect(
                x: (metrics.containerSize.width - metrics.cardWidth) / 2,
                y: (metrics.containerSize.height - height) / 2,
                width: metrics.cardWidth,
                height: height
            ).clamped(to: safeBounds(metrics: metrics))
            return Result(
                spotlight: spotlight,
                bubbleFrame: frame,
                cardWidth: metrics.cardWidth,
                cardMaxHeight: frame.height,
                placement: .center,
                arrowDirection: nil,
                arrowOffset: 0,
                isCompactViewport: metrics.isCompactViewport
            )
        }
    }

    /// Alternatives tried when the preferred placement is unusable. Roomy
    /// vertical slots come first (larger side leading, so a cramped strip above a
    /// top-anchored target can never beat a spacious area below it), then the
    /// sides, then a centered card. Cramped vertical strips are never offered: a
    /// card that cannot fit its copy is worse than the centered fallback.
    private static func fallbackPlacements(
        after placement: Placement,
        spotlight: CGRect,
        metrics: Metrics,
        gap: CGFloat
    ) -> [Placement] {
        var placements: [Placement] = []

        let above = availableAbove(spotlight: spotlight, metrics: metrics, gap: gap)
        let below = availableBelow(spotlight: spotlight, metrics: metrics, gap: gap)
        let vertical: [(Placement, CGFloat)] = [(.above, above), (.below, below)]
        placements += vertical
            .filter { $0.0 != placement && $0.1 >= metrics.bubbleMinHeight }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        let trailingSpace = metrics.containerSize.width - spotlight.maxX - metrics.horizontalPadding
        if placement != .trailing,
           metrics.containerSize.width >= 620,
           trailingSpace >= minimumSideBubbleWidth + arrowExtent + trailingGap {
            placements.append(.trailing)
        }

        let leadingSpace = spotlight.minX - metrics.horizontalPadding
        if placement != .leading,
           metrics.containerSize.width >= 620,
           leadingSpace >= minimumSideBubbleWidth + arrowExtent + trailingGap {
            placements.append(.leading)
        }

        if placement != .center {
            placements.append(.center)
        }

        return placements
    }

    private static func verticalResult(
        below: Bool,
        spotlight: CGRect,
        metrics: Metrics,
        gap: CGFloat
    ) -> Result {
        let available = below
            ? availableBelow(spotlight: spotlight, metrics: metrics, gap: gap)
            : availableAbove(spotlight: spotlight, metrics: metrics, gap: gap)
        let cardHeight = boundedCardHeight(availableHeight: available, metrics: metrics)
        let totalHeight = cardHeight + arrowExtent
        let centerX = clampedBubbleCenterX(for: spotlight, cardWidth: metrics.cardWidth, metrics: metrics)
        let x = centerX - metrics.cardWidth / 2
        let y = below
            ? spotlight.maxY + gap
            : spotlight.minY - gap - totalHeight
        let frame = CGRect(x: x, y: y, width: metrics.cardWidth, height: totalHeight)
            .clamped(to: safeBounds(metrics: metrics))
        let rawOffset = spotlight.midX - frame.midX
        let limit = (metrics.cardWidth / 2) - 24
        let arrowOffset = max(-limit, min(limit, rawOffset))

        return Result(
            spotlight: spotlight,
            bubbleFrame: frame,
            cardWidth: metrics.cardWidth,
            cardMaxHeight: min(cardHeight, frame.height - arrowExtent),
            placement: below ? .below : .above,
            arrowDirection: below ? .up : .down,
            arrowOffset: arrowOffset,
            isCompactViewport: metrics.isCompactViewport
        )
    }

    private static func trailingResult(spotlight: CGRect, metrics: Metrics) -> Result {
        let safe = safeBounds(metrics: metrics)
        // Always sit fully beyond the spotlight's trailing edge. An earlier cap at
        // 55% of the container width dragged the bubble back INSIDE wide spotlights
        // (Dashboard "Today", Settings section cards on large macOS windows), which
        // rejected the trailing placement and cascaded into a cramped fallback.
        let x = spotlight.maxX + trailingGap
        let availableWidth = max(260, safe.maxX - x)
        let outerWidth = min(metrics.cardWidth + arrowExtent, availableWidth)
        let cardWidth = max(240, outerWidth - arrowExtent)
        let cardHeight = boundedCardHeight(
            availableHeight: metrics.containerSize.height - metrics.safeTopPadding - metrics.safeBottomPadding,
            metrics: metrics
        )
        let y = max(safe.minY, min(spotlight.minY - 8, safe.maxY - cardHeight))
        let frame = CGRect(x: x, y: y, width: outerWidth, height: cardHeight)
            .clamped(to: safe)
        let arrow = sideArrow(in: frame, spotlight: spotlight, metrics: metrics)

        return Result(
            spotlight: spotlight,
            bubbleFrame: frame,
            cardWidth: cardWidth,
            cardMaxHeight: frame.height,
            placement: .trailing,
            arrowDirection: .left,
            arrowOffset: arrow.offset,
            isCompactViewport: metrics.isCompactViewport,
            hugsBottom: arrow.hugsBottom
        )
    }

    private static func leadingResult(spotlight: CGRect, metrics: Metrics) -> Result {
        let safe = safeBounds(metrics: metrics)
        let availableWidth = max(260, spotlight.minX - safe.minX - trailingGap)
        let outerWidth = min(metrics.cardWidth + arrowExtent, availableWidth)
        let cardWidth = max(240, outerWidth - arrowExtent)
        let x = max(safe.minX, spotlight.minX - trailingGap - outerWidth)
        let cardHeight = boundedCardHeight(
            availableHeight: metrics.containerSize.height - metrics.safeTopPadding - metrics.safeBottomPadding,
            metrics: metrics
        )
        let y = max(safe.minY, min(spotlight.minY - 8, safe.maxY - cardHeight))
        let frame = CGRect(x: x, y: y, width: outerWidth, height: cardHeight)
            .clamped(to: safe)
        let arrow = sideArrow(in: frame, spotlight: spotlight, metrics: metrics)

        return Result(
            spotlight: spotlight,
            bubbleFrame: frame,
            cardWidth: cardWidth,
            cardMaxHeight: frame.height,
            placement: .leading,
            arrowDirection: .right,
            arrowOffset: arrow.offset,
            isCompactViewport: metrics.isCompactViewport,
            hugsBottom: arrow.hugsBottom
        )
    }

    /// Where a side bubble's card and arrow sit in its slot. The slot is as
    /// tall as the longest card and starts level with the target, unless
    /// that would run off the bottom of the screen. Then it moves up and
    /// ends near the target, and a shorter card at its top would float
    /// above the control it describes. So the card sits at the bottom
    /// instead, with the arrow pointing at the target's middle, kept low
    /// enough to stay on even the shortest card.
    private static func sideArrow(in frame: CGRect, spotlight: CGRect, metrics: Metrics) -> (offset: CGFloat, hugsBottom: Bool) {
        let arrowHeight: CGFloat = 22
        let edgeInset: CGFloat = 16
        guard frame.minY < spotlight.minY - 8 - 1 else { return (edgeInset, false) }
        let fromBottom = frame.maxY - spotlight.midY - arrowHeight / 2
        let highest = max(edgeInset, metrics.bubbleMinHeight - arrowHeight - edgeInset)
        return (min(max(edgeInset, fromBottom), highest), true)
    }

    private static func availableAbove(spotlight: CGRect, metrics: Metrics, gap: CGFloat) -> CGFloat {
        spotlight.minY - gap - arrowExtent - metrics.safeTopPadding
    }

    private static func availableBelow(spotlight: CGRect, metrics: Metrics, gap: CGFloat) -> CGFloat {
        metrics.containerSize.height - spotlight.maxY - gap - arrowExtent - metrics.safeBottomPadding
    }

    private static func boundedCardHeight(availableHeight: CGFloat, metrics: Metrics) -> CGFloat {
        min(metrics.readableBubbleMaxHeight, max(96, availableHeight))
    }

    private static func clampedBubbleCenterX(for spotlight: CGRect, cardWidth: CGFloat, metrics: Metrics) -> CGFloat {
        let halfWidth = cardWidth / 2
        let minCenter = halfWidth + metrics.horizontalPadding
        let maxCenter = metrics.containerSize.width - halfWidth - metrics.horizontalPadding
        guard maxCenter > minCenter else { return metrics.containerSize.width / 2 }
        return min(maxCenter, max(minCenter, spotlight.midX))
    }

    private static func safeBounds(metrics: Metrics) -> CGRect {
        let minX = max(0, metrics.safeAreaInsets.leading) + 8
        let minY = max(max(0, metrics.safeAreaInsets.top) + 8, metrics.topChromeClearance + 8)
        let maxX = metrics.containerSize.width - max(0, metrics.safeAreaInsets.trailing) - 8
        let maxY = metrics.containerSize.height - max(0, metrics.safeAreaInsets.bottom) - 8
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let width = min(self.width, bounds.width)
        let height = min(self.height, bounds.height)
        let x = min(max(self.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(self.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Which slice of the tour an overlay is responsible for. On iPhone (and iPad
/// split-screen compact) one overlay owns everything. On a `NavigationSplitView`
/// (iPad regular / Mac) the sidebar and detail are separate hosting contexts, and
/// a single root overlay resolves DETAIL-column anchors without the sidebar's
/// horizontal offset — so the spotlight spans the whole window instead of framing
/// the element. Splitting the work fixes that: the root overlay handles the
/// sidebar nav rows (which it CAN resolve), and an overlay hosted inside the
/// detail column handles content steps (whose anchors resolve tightly there).
enum WalkthroughOverlayScope {
    case all           // single overlay owns every step (iPhone / compact)
    case navigation    // only the primary sidebar nav-row steps
    case content       // everything except the primary nav rows
    case rootContent   // content in a column ROOT view (dashboard / insights) — NOT a pushed detail
    case detailContent // content whose anchors live in a PUSHED detail view

    static let navigationAnchors: Set<WalkthroughAnchorID> = [
        .appNavigation, .dashboard, .clients, .insights, .settings
    ]

    /// Anchors that live inside a PUSHED `NavigationStack` destination
    /// (`ClientDetailView`, `CheckoutView`, `SettingsDetailView`). On iPad / macOS
    /// these are drawn by an overlay re-hosted ON the pushed view, because the
    /// split-view detail-column overlay sits OUTSIDE the `NavigationStack` and
    /// can't resolve them. Excluding them from the detail-column overlay
    /// (`.rootContent`) stops a SECOND overlay from drawing a stray spotlight and
    /// double-dimming the real target (which left e.g. the Add Pet button un-lit
    /// with a faint stray circle elsewhere).
    static let detailAnchors: Set<WalkthroughAnchorID> = [
        .cdOwner, .cdEmergency, .emergencyContactBadges, .cdLoyalty, .cdPets, .petGenderDots,
        .cdAddPet, .cdCheckIn, .cdCheckOut, .cdPetHistory, .cdHistory, .cdVisitRow,
        .coServices, .coDetails, .coPayment, .coReview, .coConfirm,
        .setBusiness, .setLoyalty, .loyaltySimulator, .setSecurity, .setData, .setAbout, .setStartFresh
    ]

    func handles(_ step: WalkthroughStep) -> Bool {
        switch self {
        case .all: return true
        case .navigation: return Self.navigationAnchors.contains(step.anchor)
        case .content: return !Self.navigationAnchors.contains(step.anchor)
        case .rootContent:
            return !Self.navigationAnchors.contains(step.anchor) && !Self.detailAnchors.contains(step.anchor)
        case .detailContent:
            return Self.detailAnchors.contains(step.anchor)
        }
    }

    /// Whether an overlay draws `step`. Each step has one home overlay (the
    /// sheet it lives in, or the scope that owns its anchor). When that home
    /// never draws it, for example because checkout couldn't open or a pushed
    /// screen never appeared, the root overlay adopts it so the tour always
    /// shows a bubble with Back, Skip and Next.
    static func hostDraws(
        _ step: WalkthroughStep,
        presenting: WalkthroughPresentation?,
        scope: WalkthroughOverlayScope,
        adoptsOrphanedSteps: Bool,
        isOrphaned: Bool
    ) -> Bool {
        if step.presents == presenting && scope.handles(step) { return true }
        return adoptsOrphanedSteps && isOrphaned
    }

    var ignoresOverlaySafeArea: Bool {
        switch self {
        case .all, .navigation, .content:
            return true
        case .rootContent, .detailContent:
            return false
        }
    }
}

extension View {
    /// Hosts the guided-tour overlay above this view's content. Anchors registered
    /// with `.walkthroughAnchor(_:)` anywhere in the subtree are resolved here, so
    /// attach this at the navigation root that contains the sidebar / tab bar.
    /// - Parameter presenting: which modal this overlay belongs to. The root
    ///   overlay passes `nil` and renders only main-UI steps; a sheet passes its
    ///   own presentation and renders only that sheet's steps. Without this, the
    ///   root overlay also rendered sheet steps and pointed its `.topTrailingAction`
    ///   fallback at nothing on the main window.
    /// - Parameter scope: which steps this overlay should draw. See
    ///   `WalkthroughOverlayScope`. Defaults to `.all` (iPhone single overlay).
    /// - Parameter adoptsOrphanedSteps: the app's root overlay passes true so
    ///   it draws, centered, any step no other overlay drew in time.
    func walkthroughOverlay(
        _ controller: WalkthroughController,
        presenting: WalkthroughPresentation? = nil,
        scope: WalkthroughOverlayScope = .all,
        adoptsOrphanedSteps: Bool = false
    ) -> some View {
        WalkthroughOverlayHost(
            content: self,
            controller: controller,
            presenting: presenting,
            scope: scope,
            adoptsOrphanedSteps: adoptsOrphanedSteps
        )
    }
}

private struct WalkthroughOverlayHost<Content: View>: View {
    let content: Content
    let controller: WalkthroughController
    let presenting: WalkthroughPresentation?
    let scope: WalkthroughOverlayScope
    let adoptsOrphanedSteps: Bool

    @State private var frames: [WalkthroughAnchorID: CGRect] = [:]

    var body: some View {
        content
            .coordinateSpace(name: WalkthroughFramePreferenceKey.coordinateSpaceName)
            .onPreferenceChange(WalkthroughFramePreferenceKey.self) { frames = $0 }
            .overlayPreferenceValue(WalkthroughAnchorPreferenceKey.self) { anchors in
                GeometryReader { proxy in
                    if controller.isActive, let step = controller.currentStep,
                       WalkthroughOverlayScope.hostDraws(
                           step,
                           presenting: presenting,
                           scope: scope,
                           adoptsOrphanedSteps: adoptsOrphanedSteps,
                           isOrphaned: controller.isCurrentStepOrphaned
                       ) {
                        // Prefer the explicitly emitted global frame first.
                        // Pushed views inside `NavigationSplitView` can resolve
                        // local anchors without the sidebar/top-chrome offsets,
                        // which makes the bubble land over the wrong control.
                        // The anchor path remains a fallback for targets whose
                        // frame preference is unavailable.
                        let overlayFrameInGlobal = proxy.frame(in: .global)
                        let rawFrameTarget = frames[step.anchor].map { frame in
                            frame.offsetBy(dx: -overlayFrameInGlobal.minX, dy: -overlayFrameInGlobal.minY)
                        }
                        let rawAnchorTarget = anchors[step.anchor].map { proxy[$0] }
                        let frameTarget = WalkthroughTargetFrame.validated(
                            rawFrameTarget,
                            in: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        let anchorTarget = WalkthroughTargetFrame.validated(
                            rawAnchorTarget,
                            in: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        let fallbackTarget = WalkthroughTargetFrame.validated(
                            walkthroughFallbackRect(step.fallback, in: proxy),
                            in: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        let target = frameTarget ?? anchorTarget ?? fallbackTarget
                        let rawLiveTarget = frameTarget != nil ? rawFrameTarget : rawAnchorTarget
                        let isAdopted = !(step.presents == presenting && scope.handles(step))
                        // A section that only exists with data (Needs
                        // Attention) isn't drawn centered while the tour waits
                        // to see whether it appears. Without it the step is
                        // skipped (`WalkthroughController.checkTargets`).
                        if !(step.skipsWhenTargetMissing && target == nil) {
                            WalkthroughOverlayView(
                                step: step,
                                rawTargetRect: rawLiveTarget,
                                targetRect: target,
                                containerSize: proxy.size,
                                containerInsets: proxy.safeAreaInsets,
                                controller: controller,
                                isAdopted: isAdopted
                            )
                        }
                    }
                }
                .modifier(WalkthroughOverlaySafeAreaModifier(ignoresSafeArea: scope.ignoresOverlaySafeArea))
            }
    }
}

private struct WalkthroughOverlaySafeAreaModifier: ViewModifier {
    let ignoresSafeArea: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ignoresSafeArea {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

/// Computes a spotlight rect for targets that can't be anchored. Currently only
/// the iPhone bottom tab bar, whose `.tabItem` frames SwiftUI does not expose.
private func walkthroughFallbackRect(_ fallback: SpotlightFallback, in proxy: GeometryProxy) -> CGRect? {
    switch fallback {
    case .none:
        return nil
    case .tabBarItem(let index, let count):
        guard count > 0, index >= 0, index < count else { return nil }
        let tabBarHeight: CGFloat = 49
        let bottomInset = proxy.safeAreaInsets.bottom
        let slot = proxy.size.width / CGFloat(count)
        let centerX = slot * (CGFloat(index) + 0.5)
        let centerY = proxy.size.height - bottomInset - tabBarHeight / 2
        let w = min(slot - 16, 60)
        let h: CGFloat = 44
        return CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    case .topTrailingAction:
        let isCompactPhone = proxy.size.width < 430
        let width: CGFloat = isCompactPhone ? 64 : 118
        let height: CGFloat = isCompactPhone ? 48 : 44
        let margin: CGFloat = isCompactPhone ? 10 : 16
        let x = proxy.size.width - proxy.safeAreaInsets.trailing - margin - width
        // The overlay ignores safe areas, so `safeAreaInsets.top` can be zero on
        // iPhone. Keep compact highlights down in the navigation bar where the
        // blue Create check lives, instead of circling the status icons.
        let minimumTop: CGFloat = isCompactPhone ? 66 : 44
        let y = max(proxy.safeAreaInsets.top + margin, minimumTop)
        return CGRect(x: max(margin, x), y: y, width: width, height: height)
    case .bottomTrailingAction:
        let width: CGFloat = 118
        let height: CGFloat = 44
        let margin: CGFloat = 16
        let x = proxy.size.width - proxy.safeAreaInsets.trailing - margin - width
        let y = proxy.size.height - proxy.safeAreaInsets.bottom - margin - height
        return CGRect(x: max(margin, x), y: max(margin, y), width: width, height: height)
    case .topTrailingIcon:
        // A single compact toolbar icon (macOS "+"). Keep it narrow so the
        // spotlight lands on just that button, not the neighboring delete action.
        let size: CGFloat = 48
        let margin: CGFloat = 14
        let x = proxy.size.width - proxy.safeAreaInsets.trailing - margin - size
        let y = proxy.safeAreaInsets.top + margin
        return CGRect(x: max(margin, x), y: y, width: size, height: size)
    }
}

/// An isosceles triangle pointing in one of four directions — the bubble's
/// pointer into the spotlight.
private struct ArrowTriangle: Shape {
    var direction: WalkthroughOverlayLayout.ArrowDirection
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch direction {
        case .up:
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .down:
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        case .left:
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .right:
            p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

private struct WalkthroughOverlayView: View {
    let step: WalkthroughStep
    let rawTargetRect: CGRect?
    let targetRect: CGRect?
    let containerSize: CGSize
    let containerInsets: EdgeInsets
    let controller: WalkthroughController
    /// The root overlay is drawing a step its own screen never drew.
    var isAdopted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// With VoiceOver on, every stop offers Next: tapping a highlighted
    /// region isn't something VoiceOver users can be asked to find.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Gentle, continuous "breathing" of the spotlight ring to draw the eye to
    /// the highlighted control. Disabled under Reduce Motion.
    @State private var ringPulse = false

    private var dimOpacity: Double {
        #if os(macOS)
        return 0.58
        #else
        return isCompactViewport ? 0.62 : 0.54
        #endif
    }

    private var layout: WalkthroughOverlayLayout.Result {
        WalkthroughOverlayLayout.layout(
            step: step,
            targetRect: targetRect,
            containerSize: containerSize,
            safeAreaInsets: containerInsets
        )
    }

    private var spotlight: CGRect? {
        layout.spotlight
    }

    private var isCompactViewport: Bool {
        layout.isCompactViewport
    }

    private var bubbleWidth: CGFloat {
        layout.cardWidth
    }

    private var bubbleCardPadding: CGFloat {
        isCompactViewport ? 13 : 16
    }

    /// Header, progress, "mastered" line and footer: what the body can't use.
    private var bubbleChromeHeightEstimate: CGFloat {
        isCompactViewport ? 142 : 158
    }

    private var placement: WalkthroughOverlayLayout.Placement {
        layout.placement
    }

    var body: some View {
        ZStack {
            dimLayer
            spotlightRing
            spotlightTapTarget
            bubble
            accessibilityProbe
            activeAnchorProbe
        }
        // Interpolate the spotlight + bubble both when the step changes and when
        // the target frame moves (e.g. a macOS window resize mid-tour).
        .motionAnimation(MotionSystem.fluid, value: step.id)
            .motionAnimation(MotionSystem.fluid, value: targetRect)
            // Tell the controller this step is on screen, and whether it has a
            // target. Reported from a task (never from body) and only when the
            // step or the presence of a target changes.
            .task(id: ShownReport(stepID: step.id, hasTarget: targetRect != nil, isAdopted: isAdopted)) {
                controller.noteStepShown(step.id, hasTarget: targetRect != nil, adopted: isAdopted)
            }
    }

    private struct ShownReport: Equatable {
        let stepID: String
        let hasTarget: Bool
        let isAdopted: Bool
    }

    private var accessibilityProbe: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .position(x: 1, y: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("walkthrough.card")
            .accessibilityLabel(Text(step.title))
            .accessibilityValue(Text(String(
                format: AppLocalization.localized("tour.step_position_fmt", value: "%1$d of %2$d"),
                controller.stepNumber,
                controller.stepCount
            )))
    }

    private var activeAnchorProbe: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .position(x: 3, y: 3)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("walkthrough.activeAnchor.\(step.anchor.rawValue)")
            .accessibilityLabel(Text(step.anchor.rawValue))
            .accessibilityValue(Text(layoutDebugValue))
    }

    private var layoutDebugValue: String {
        [
            "placement=\(placement)",
            "raw=\(debugDescription(for: rawTargetRect))",
            "target=\(debugDescription(for: targetRect))",
            "spotlight=\(debugDescription(for: spotlight))",
            "bubble=\(debugDescription(for: layout.bubbleFrame))",
            "container=\(Int(containerSize.width.rounded()))x\(Int(containerSize.height.rounded()))"
        ].joined(separator: ";")
    }

    private func debugDescription(for rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return debugDescription(for: rect)
    }

    private func debugDescription(for rect: CGRect) -> String {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
            .map { Int($0.rounded()).description }
            .joined(separator: ",")
        return "[\(values)]"
    }

    // MARK: Dim + cutout

    private var dimLayer: some View {
        Canvas { ctx, size in
            var region = Path(CGRect(origin: .zero, size: size))
            if let s = spotlight {
                switch step.shape {
                case .circle:
                    let d = max(s.width, s.height)
                    region.addEllipse(in: CGRect(x: s.midX - d / 2, y: s.midY - d / 2, width: d, height: d))
                case .roundedRect(let cr):
                    region.addRoundedRect(in: s, cornerSize: CGSize(width: cr, height: cr), style: .continuous)
                }
            }
            // Even-odd fill leaves the cutout transparent — robust, no blend modes.
            ctx.fill(region, with: .color(.black.opacity(dimOpacity)), style: FillStyle(eoFill: true))
        }
        .contentShape(Rectangle())
        .onTapGesture { /* swallow taps/clicks on the dimmed area */ }
        .allowsHitTesting(!step.allowsTargetInteraction)
    }

    // MARK: Glowing ring

    @ViewBuilder
    private var spotlightRing: some View {
        if let s = spotlight {
            Group {
                switch step.shape {
                case .circle:
                    let d = max(s.width, s.height)
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.5)
                        .frame(width: d, height: d)
                        .position(x: s.midX, y: s.midY)
                case .roundedRect(let cr):
                    RoundedRectangle(cornerRadius: cr, style: .continuous)
                        .stroke(Color.white.opacity(0.95), lineWidth: 2.5)
                        .frame(width: s.width, height: s.height)
                        .position(x: s.midX, y: s.midY)
                }
            }
            .shadow(color: DS.ColorToken.primary.opacity(ringPulse ? 0.95 : 0.65), radius: ringPulse ? 16 : 8)
            .scaleEffect(ringPulse ? 1.035 : 1.0)
            .allowsHitTesting(false)
            .onAppear {
                guard MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    ringPulse = true
                }
            }
        }
    }

    /// Invisible tap target over the highlighted control: tapping it advances, so
    /// the tour feels like "tap the thing" without risking real navigation.
    @ViewBuilder
    private var spotlightTapTarget: some View {
        if let s = spotlight, !step.allowsTargetInteraction {
            Color.white.opacity(0.001)
                .frame(width: s.width, height: s.height)
                .contentShape(Rectangle())
                .position(x: s.midX, y: s.midY)
                .onTapGesture { controller.advance(from: step.id) }
        }
    }

    // MARK: Bubble + arrow

    @ViewBuilder
    private var bubble: some View {
        switch placement {
        case .below: verticalBubble(below: true)
        case .above: verticalBubble(below: false)
        case .trailing: trailingBubble
        case .leading: leadingBubble
        case .center: centerBubble
        }
    }

    /// Bubble above or below the spotlight (tab bar / general case).
    private func verticalBubble(below: Bool) -> some View {
        let result = layout

        return VStack(spacing: 0) {
            if below { verticalArrow(.up) }
            // Keep the card against its arrow: the top of the slot below
            // the target, the bottom of the slot above it.
            bubbleCard(maxHeight: result.cardMaxHeight, alignment: below ? .top : .bottom)
            if !below { verticalArrow(.down) }
        }
        .frame(width: result.bubbleFrame.width, height: result.bubbleFrame.height, alignment: below ? .top : .bottom)
        .position(x: result.bubbleFrame.midX, y: result.bubbleFrame.midY)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Bubble to the leading side of a right-side target, like iPad pet actions.
    private var leadingBubble: some View {
        let result = layout

        let edge: VerticalAlignment = result.hugsBottom ? .bottom : .top

        return HStack(alignment: edge, spacing: 0) {
            bubbleCard(maxHeight: result.cardMaxHeight, alignment: result.hugsBottom ? .bottom : .top)
            ArrowTriangle(direction: .right)
                .fill(DS.ColorToken.surface)
                .frame(width: 11, height: 22)
                .padding(result.hugsBottom ? .bottom : .top, result.arrowOffset)
        }
        .frame(width: result.bubbleFrame.width, height: result.bubbleFrame.height, alignment: result.hugsBottom ? .bottomLeading : .topLeading)
        .position(x: result.bubbleFrame.midX, y: result.bubbleFrame.midY)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Bubble to the trailing side of the spotlight (sidebar row on Mac/iPad).
    private var trailingBubble: some View {
        let result = layout

        let edge: VerticalAlignment = result.hugsBottom ? .bottom : .top

        return HStack(alignment: edge, spacing: 0) {
            ArrowTriangle(direction: .left)
                .fill(DS.ColorToken.surface)
                .frame(width: 11, height: 22)
                .padding(result.hugsBottom ? .bottom : .top, result.arrowOffset)
            bubbleCard(maxHeight: result.cardMaxHeight, alignment: result.hugsBottom ? .bottom : .top)
        }
        .frame(width: result.bubbleFrame.width, height: result.bubbleFrame.height, alignment: result.hugsBottom ? .bottomLeading : .topLeading)
        .position(x: result.bubbleFrame.midX, y: result.bubbleFrame.midY)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Centered fallback when a step is informational or the target hasn't
    /// appeared yet. This keeps the tour readable instead of silently dropping
    /// the bubble.
    private var centerBubble: some View {
        let result = layout
        return bubbleCard(maxHeight: result.cardMaxHeight, alignment: .center)
            .frame(width: result.bubbleFrame.width, height: result.bubbleFrame.height, alignment: .center)
            .position(x: result.bubbleFrame.midX, y: result.bubbleFrame.midY)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Up/down pointer, nudged horizontally toward the target relative to the
    /// (possibly shifted) bubble center.
    private func verticalArrow(_ dir: WalkthroughOverlayLayout.ArrowDirection) -> some View {
        return ArrowTriangle(direction: dir)
            .fill(DS.ColorToken.surface)
            .frame(width: 22, height: 11)
            .offset(x: layout.arrowOffset)
    }

    /// The card is as tall as its copy, up to `maxHeight`, and sits at
    /// `alignment` inside the slot the layout gave it. Longer copy scrolls.
    private func bubbleCard(maxHeight: CGFloat, alignment: Alignment = .top) -> some View {
        let bodyMaxHeight = max(72, maxHeight - bubbleChromeHeightEstimate)

        return VStack(alignment: .leading, spacing: isCompactViewport ? 8 : 10) {
            HStack(spacing: 8) {
                Label(chapterChipText, systemImage: step.lesson.icon)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(DS.ColorToken.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.ColorToken.primary.opacity(0.12), in: Capsule())
                Spacer(minLength: 8)
                Text(String(
                    format: AppLocalization.localized("tour.step_counter_fmt", value: "Step %1$d of %2$d"),
                    controller.stepNumber,
                    controller.stepCount
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityIdentifier("walkthrough.stepCounter")
            }

            VStack(alignment: .trailing, spacing: 4) {
                tourProgressBar
                Text(String(
                    format: AppLocalization.localized("tour.mastered_fmt", value: "%d%% mastered"),
                    Int((controller.masteredFraction * 100).rounded(.down))
                ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.ColorToken.primary)
                .monospacedDigit()
                .accessibilityIdentifier("walkthrough.mastered")
            }

            ViewThatFits(in: .vertical) {
                bubbleBody

                ScrollView {
                    bubbleBody
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: bodyMaxHeight)
            }

            footerControls
                .padding(.top, 2)
        }
        .padding(bubbleCardPadding)
        .frame(width: bubbleWidth, alignment: .top)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("walkthrough.bubble")
        .accessibilityLabel(Text(step.title))
        .accessibilityValue(Text(String(
            format: AppLocalization.localized("tour.step_position_fmt", value: "%1$d of %2$d"),
            controller.stepNumber,
            controller.stepCount
        )))
        // The cap goes after the background. Before it, the flexible frame
        // took the whole cap and the background filled it, leaving a tall
        // empty band under Back and Next on every short stop.
        .frame(maxHeight: maxHeight, alignment: alignment)
    }

    private var tourProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(DS.ColorToken.primary)
                    .frame(width: max(10, proxy.size.width * walkthroughProgress))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private var walkthroughProgress: CGFloat {
        min(max(CGFloat(controller.masteredFraction), 0), 1)
    }

    /// Next on every stop: VoiceOver users can't be asked to find a
    /// highlighted region, and UI tests drive the tour with Next (unit tests
    /// cover the stops that wait).
    private var showsNextAnyway: Bool {
        voiceOverEnabled || AppRuntime.isUITesting
    }

    /// "2 · Client Directory": the chapter's place in the Academy and its name.
    private var chapterChipText: String {
        guard controller.chapterNumber > 0 else { return step.lesson.title }
        return String(
            format: AppLocalization.localized("tour.chapter_chip_fmt", value: "%1$d · %2$@"),
            controller.chapterNumber,
            step.lesson.title
        )
    }

    @ViewBuilder
    private var footerControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backButton
                skipButton

                Spacer(minLength: 12)

                footerPrimaryControl
            }

            VStack(alignment: .leading, spacing: 10) {
                footerPrimaryControl
                HStack(spacing: 18) {
                    backButton
                    skipButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Step backward so a user who advanced too fast can re-read the prior stop.
    /// Shown on every step that has a predecessor — including the "tap the
    /// highlighted control" steps, where it's otherwise the only way back.
    @ViewBuilder
    private var backButton: some View {
        if controller.canGoBack {
            Button {
                controller.goBack(from: step.id)
            } label: {
                Label(AppLocalization.localized("tour.back", value: "Back"), systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(DS.ColorToken.primary)
            .buttonStyle(.plain)
            .accessibilityIdentifier("walkthrough.back")
        }
    }

    private var skipButton: some View {
        Button(AppLocalization.localized("tour.skip", value: "Skip tour")) {
            controller.skip()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .accessibilityIdentifier("walkthrough.skip")
    }

    @ViewBuilder
    private var footerPrimaryControl: some View {
        // Next shows when the step doesn't wait for a tap, when the host
        // released it, or when the highlighted control isn't on screen.
        if !controller.currentStepShowsNext, targetRect != nil, !showsNextAnyway {
            Label(
                step.allowsTargetInteraction
                    ? AppLocalization.localized("tour.your_turn", value: "Your turn")
                    : AppLocalization.localized("tour.tap_the_highlight", value: "Tap the highlight"),
                systemImage: "hand.tap.fill"
            )
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(DS.ColorToken.primary)
                .padding(.horizontal, isCompactViewport ? 12 : 14)
                .padding(.vertical, isCompactViewport ? 8 : 9)
                .background(DS.ColorToken.primary.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("walkthrough.tapHighlighted")
        } else {
            Button {
                controller.advance(from: step.id)
            } label: {
                HStack(spacing: 6) {
                    Text(controller.isLastStep
                         ? AppLocalization.localized("tour.done", value: "Done")
                         : AppLocalization.localized("tour.next", value: "Next"))
                        .fontWeight(.semibold)
                    Image(systemName: controller.isLastStep ? "checkmark" : "arrow.right")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(DS.ColorToken.primary)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .pressScaleStyle(hapticsEnabled: true)
            .accessibilityIdentifier("walkthrough.primary")
        }
    }

    /// Every stop reads the same way: what the control is, why it matters,
    /// and the one thing to try (missing on look-only stops).
    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: isCompactViewport ? 8 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.icon)
                    .font(.headline)
                    .foregroundStyle(DS.ColorToken.primary)
                    .frame(width: 24)
                Text(step.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            anatomyRow(
                label: AppLocalization.localized("tour.anatomy.what", value: "What it is"),
                systemImage: "eye.fill",
                text: step.directive
            )
            anatomyRow(
                label: AppLocalization.localized("tour.anatomy.why", value: "Why it matters"),
                systemImage: "star.fill",
                text: step.purpose
            )
            if let action = step.action {
                anatomyRow(
                    label: AppLocalization.localized("tour.anatomy.try", value: "Try it"),
                    systemImage: "hand.tap.fill",
                    text: action,
                    isAction: true
                )
            }

            if let coachTip = step.coachTip {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(DS.ColorToken.primary)
                        .font(.caption)
                        .padding(.top, 1)
                    Text(coachTip)
                        .font(isCompactViewport ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(isCompactViewport ? 9 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.ColorToken.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One labeled line of the stop: a small caption over the sentence. The
    /// "Try it" line stands out, since it is what moves the Academy on.
    private func anatomyRow(label: String, systemImage: String, text: String, isAction: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(isAction ? DS.ColorToken.primary : Color.secondary)
            Text(text)
                .font(anatomyFont(isAction: isAction))
                .foregroundStyle(isAction ? DS.ColorToken.primary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(isAction ? (isCompactViewport ? 8 : 9) : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isAction {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.ColorToken.primary.opacity(0.10))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func anatomyFont(isAction: Bool) -> Font {
        if isAction { return Font.subheadline.weight(.semibold) }
        return isCompactViewport ? Font.footnote : Font.callout
    }
}

// MARK: - Chapter win

/// A short reward when a chapter of the Academy ends: a medal, the chapter's
/// name and how many chapters are done. Decorative; the tour carries on
/// underneath it.
struct WalkthroughChapterWinToast: View {
    let win: WalkthroughChapterWin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var medalBounce = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "medal.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .scaleEffect(medalBounce ? 1.0 : 0.6)
                .rotationEffect(.degrees(medalBounce ? 0 : -25))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: AppLocalization.localized("tour.chapter_win.title_fmt", value: "%@ mastered!"),
                    win.chapter.title
                ))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                Text(String(
                    format: AppLocalization.localized("tour.chapter_win.progress_fmt", value: "Chapter %1$d of %2$d done"),
                    win.number,
                    win.of
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(DS.ColorToken.primary, in: Capsule())
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
        .onAppear {
            guard MotionGovernor.shouldAnimate(reduceMotion: reduceMotion) else {
                medalBounce = true
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) { medalBounce = true }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walkthrough.chapterWin")
    }
}

// MARK: - Completion celebration

/// A celebratory confetti burst shown for a couple of seconds when the user
/// FINISHES the guided tour (skipping stays quiet). Purely decorative and
/// non-interactive; the falling animation is skipped under Reduce Motion, which
/// leaves just the "You're all set!" capsule.
struct WalkthroughCelebrationView: View {
    /// Set when one replayed chapter was finished, not the whole Academy.
    var chapter: WalkthroughLesson? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bannerIn = false
    private let pieceCount = 46

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if !reduceMotion {
                    ForEach(0..<pieceCount, id: \.self) { _ in
                        WalkthroughConfettiBit(bounds: proxy.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Label(bannerText, systemImage: chapter == nil ? "graduationcap.fill" : "medal.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(DS.ColorToken.primary, in: Capsule())
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
            .padding(.top, 12)
            .offset(y: bannerIn ? 0 : -96)
            .opacity(bannerIn ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { bannerIn = true }
            }
        }
        .allowsHitTesting(false)
    }

    private var bannerText: String {
        guard let chapter else {
            return AppLocalization.localized("tour.academy.complete", value: "Academy complete! You're ready for your first shift.")
        }
        return String(
            format: AppLocalization.localized("tour.chapter_win.title_fmt", value: "%@ mastered!"),
            chapter.title
        )
    }
}

/// One falling confetti rectangle. Random visual parameters are captured once in
/// `@State` defaults so re-renders don't reshuffle them mid-flight.
private struct WalkthroughConfettiBit: View {
    let bounds: CGSize

    @State private var color: Color = [.blue, .purple, .pink, .orange, .yellow, .green, .red, .mint, .cyan].randomElement() ?? .blue
    @State private var startXFraction: CGFloat = .random(in: 0.02...0.98)
    @State private var size: CGFloat = .random(in: 6...11)
    @State private var drift: CGFloat = .random(in: -80...80)
    @State private var spin: Double = .random(in: 160...920)
    @State private var duration: Double = .random(in: 1.5...2.4)
    @State private var delay: Double = .random(in: 0...0.55)
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: size, height: size * 1.5)
            .rotationEffect(.degrees(animate ? spin : 0))
            .position(
                x: bounds.width * startXFraction + (animate ? drift : 0),
                y: animate ? bounds.height + 60 : -60
            )
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: duration).delay(delay)) { animate = true }
            }
    }
}
