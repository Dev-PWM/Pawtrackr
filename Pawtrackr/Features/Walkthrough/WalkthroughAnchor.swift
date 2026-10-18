//
//  WalkthroughAnchor.swift
//  Pawtrackr
//
//  Lets any control register its on-screen frame so the guided-tour overlay can
//  spotlight it. Uses SwiftUI `Anchor<CGRect>` preferences, which the overlay
//  resolves against its own coordinate space — no manual coordinate math, and it
//  stays correct through scrolling and rotation.
//

import SwiftUI

/// Collects the bounds of every registered walkthrough target in a subtree.
struct WalkthroughAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [WalkthroughAnchorID: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [WalkthroughAnchorID: Anchor<CGRect>],
        nextValue: () -> [WalkthroughAnchorID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Collects already-resolved target frames in the nearest walkthrough overlay's
/// global window coordinate space. This complements anchor preferences for views
/// inside split views, navigation stacks, and scroll views where local anchors can
/// lose the sidebar, toolbar, or scroll offset before the viewport overlay draws.
struct WalkthroughFramePreferenceKey: PreferenceKey {
    static let coordinateSpaceName = "walkthrough.overlay.viewport"
    static var defaultValue: [WalkthroughAnchorID: CGRect] { [:] }

    static func reduce(
        value: inout [WalkthroughAnchorID: CGRect],
        nextValue: () -> [WalkthroughAnchorID: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Registers this view as a spotlight target for the guided tour. Harmless
    /// when no tour is running; the overlay only reads anchors while active.
    func walkthroughAnchor(_ id: WalkthroughAnchorID) -> some View {
        // Emit BOTH the bounds anchor and the viewport frame from a DETACHED
        // `.background` subtree (a `Color.clear` that fills `self`, so its
        // `.bounds` anchor equals self's frame). This matters: applying
        // `.anchorPreference` directly to `self` places it ABOVE descendants in
        // the view tree, where a parent target's anchor — e.g. `.cdPets` on the
        // whole pets section — OVERRIDES the same-key anchors of nested targets
        // (`.cdCheckOut`, `.cdAddPet`, `.cdCheckIn`, `.cdPetHistory`). Those
        // arrive nil at the overlay, which then falls back to a stale frame and
        // spotlights the wrong place (Check Out drawn above the button; Pet
        // History landing on Recent History). Hosting the anchor in a sibling
        // background — exactly how the frame preference is already emitted, and
        // observed to merge correctly — lets every target's anchor reduce-merge
        // independently, so deeply nested controls resolve tightly.
        self.background {
            GeometryReader { proxy in
                Color.clear
                    .anchorPreference(key: WalkthroughAnchorPreferenceKey.self, value: .bounds) { anchor in [id: anchor] }
                    .preference(
                        key: WalkthroughFramePreferenceKey.self,
                        value: [id: proxy.frame(in: .global)]
                    )
            }
        }
    }

    /// Registers this view as BOTH a spotlight anchor and a scroll target, so the
    /// deep-dive tour can highlight it AND scroll it into view (via the screen's
    /// `ScrollViewReader`). Use on content sections inside a scroll view.
    func walkthroughTarget(_ id: WalkthroughAnchorID) -> some View {
        self.id(id).walkthroughAnchor(id)
    }

    /// `walkthroughTarget(_:)` on one view out of many, e.g. the one pet row
    /// the tour points at. Every row in a `ForEach` registering the same
    /// anchor would leave the spotlight on whichever row merged last, and
    /// give `ScrollViewReader` duplicate IDs.
    @ViewBuilder
    func walkthroughTarget(_ id: WalkthroughAnchorID, isActive: Bool) -> some View {
        if isActive {
            walkthroughTarget(id)
        } else {
            self
        }
    }

    @ViewBuilder
    func optionalWalkthroughTarget(_ id: WalkthroughAnchorID?) -> some View {
        if let id {
            walkthroughTarget(id)
        } else {
            self
        }
    }
}
