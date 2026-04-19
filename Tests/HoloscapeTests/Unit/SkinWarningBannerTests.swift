import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 21.2 — SkinWarningBanner presentation and lifecycle.
///
/// Covers the headless contract: banner installs atop a host view,
/// replaces a previously-installed banner rather than stacking,
/// carries the reason in its accessibility label, and respects the
/// Reduce Motion path (instant present / dismiss, no animation).
///
/// Auto-dismiss timing (5-second hold) is NOT tested here — the
/// DispatchQueue.main.asyncAfter timer interacts badly with XCTest's
/// runloop and would add sleep time to every suite run. The
/// Reduce-Motion path exercises the synchronous removal code; the
/// animated path uses the same removeFromSuperview tail.
@MainActor
final class SkinWarningBannerTests: XCTestCase {

    private var host: NSView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    override func tearDownWithError() throws {
        host = nil
        try super.tearDownWithError()
    }

    // MARK: - Installation

    func testShowInstallsBannerAsSubview() {
        XCTAssertFalse(host.subviews.contains(where: { $0 is SkinWarningBanner }),
                       "Precondition: host has no banner before show()")

        _ = SkinWarningBanner.show(
            in: host,
            reason: "Test reason",
            reduceMotion: true
        )

        XCTAssertTrue(host.subviews.contains(where: { $0 is SkinWarningBanner }),
                      "After show(), the host must contain a SkinWarningBanner subview")
    }

    func testShowAccessibilityLabelCarriesReason() {
        let reason = "windowShape has kind: mask which is post-MVP — ignoring shape"
        let banner = SkinWarningBanner.show(
            in: host,
            reason: reason,
            reduceMotion: true
        )
        XCTAssertEqual(banner.accessibilityLabel(), reason,
                       "Banner's accessibility label must carry the reason verbatim so VoiceOver reads the same message sighted users see")
    }

    // MARK: - Replacement semantics

    func testSecondShowReplacesFirstRatherThanStacking() {
        _ = SkinWarningBanner.show(in: host, reason: "First", reduceMotion: true)
        _ = SkinWarningBanner.show(in: host, reason: "Second", reduceMotion: true)

        let banners = host.subviews.compactMap { $0 as? SkinWarningBanner }
        XCTAssertEqual(banners.count, 1,
                       "Successive show() calls must tear down the prior banner — otherwise rapid skin switches stack warnings")
        XCTAssertEqual(banners.first?.accessibilityLabel(), "Second",
                       "The surviving banner must be the most recent one")
    }

    // MARK: - Reduce Motion path

    func testReduceMotionShowsAtFullOpacityImmediately() {
        let banner = SkinWarningBanner.show(
            in: host,
            reason: "RM test",
            reduceMotion: true
        )
        XCTAssertEqual(banner.alphaValue, 1.0, accuracy: 0.0001,
                       "Reduce Motion must skip the fade-in — banner must be at full opacity immediately")
    }

    // No headless test for the animated path. Reading `alphaValue`
    // right after `show(reduceMotion: false)` returns the animator's
    // target (1.0) rather than the synchronous set-to-zero. The
    // visible fade is a layer/presentation concern that XCTest can't
    // observe without a running compositor. Reduce-Motion path above
    // pins the synchronous branch; the animated branch is visually
    // verified (live on laptop + Mac-Mini UI tests).

    // MARK: - Layout

    func testBannerPinnedToTopFullWidth() {
        host.needsLayout = true
        let banner = SkinWarningBanner.show(
            in: host,
            reason: "layout test",
            reduceMotion: true
        )
        host.layoutSubtreeIfNeeded()

        // AppKit default bottom-left origin — pinned to top means
        // banner.frame.maxY == host.bounds.maxY.
        XCTAssertEqual(banner.frame.maxY, host.bounds.maxY, accuracy: 0.0001,
                       "Banner must hug the top of the host (AppKit bottom-left, so maxY matches)")
        XCTAssertEqual(banner.frame.width, host.bounds.width, accuracy: 0.0001,
                       "Banner must span the full host width")
        XCTAssertEqual(banner.frame.height, 40, accuracy: 0.0001,
                       "Banner height is fixed at 40pt per spec")
    }
}
