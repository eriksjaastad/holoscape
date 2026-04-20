import Foundation

/// Phase-clock shared by every `AnimatedLayerRenderer` attached to a
/// `ChromeHostView`. A single `CADisplayLink` drives every subscribed
/// renderer so layers remain in phase (Requirement 11.2) and the
/// animated-chrome per-frame budget is measured from one place
/// (Requirement 11.3, `os_signpost` category `"chrome.animation.tick"`).
///
/// PR #10 / Task 19.1 fills in `CADisplayLink` lifecycle, subscribe /
/// unsubscribe, start / stop / pause / resume, and signpost
/// instrumentation. This file holds the type declaration so
/// `ChromeHostView` (PR #3) can carry a `SharedAnimationClock?`
/// property through PRs #3–#9 before any renderer exists.
@MainActor
final class SharedAnimationClock {
    // Placeholder. Real subscribe / unsubscribe / start / stop / pause /
    // resume + CADisplayLink wiring lands in task group 19 (PR #10).
}
