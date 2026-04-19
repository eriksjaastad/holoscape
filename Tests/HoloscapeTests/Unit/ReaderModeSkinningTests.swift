import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 17.4 — Reader Mode skin consumption.
///
/// Three load-bearing contracts:
/// 1. When `readerPanelBackground.font` is declared, the text view
///    picks it up.
/// 2. When the surface is absent, the pre-Amplify SF Mono 14pt
///    fallback is preserved — no regression for non-skin paths.
/// 3. When `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`
///    is true, the skin font is ignored and SF Mono 14pt is pinned
///    regardless of manifest content (Req 8.6 — long-form reading
///    accessibility beats skin authorship).
///
/// Tests inject the Increase Contrast flag via
/// `ReaderModeController.increaseContrastEnabled` closure so they
/// don't touch the actual system pref.
///
/// The activation path requires a live NSPanel + NSWindow. To keep
/// the test headless we invoke the internal skin application
/// directly through a minimal activate() path on a dedicated
/// parent window — same shape as `ShapedWindowControllerTests.testReconstructWindow...`.
@MainActor
final class ReaderModeSkinningTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal parent window so Reader Mode's frame-anchoring math
    /// doesn't crash. Closed in tearDown so the AppKit event loop
    /// doesn't retain it.
    private var parentWindow: NSWindow!

    /// Stub `ChannelController` implementation. Minimum surface for
    /// `ReaderModeController.activate(for:...)` — only `lastLines` is
    /// exercised in reader mode.
    @MainActor
    private final class StubChannel: NSObject, ChannelController {
        let channelId = UUID()
        var channelType: ChannelType = .shell
        let displayLabel = "test"
        var hasUnread: Bool = false
        var state: ChannelState = .active
        var contentView: NSView = NSView()
        var commandHistory = CommandHistory()
        weak var delegate: ChannelControllerDelegate?

        func sendInput(_ text: String) {}
        func activate() {}
        func deactivate() {}
        func retry() {}
        func lastLines(_ count: Int) -> [String] { ["hello world"] }
    }

    override func setUp() {
        super.setUp()
        parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    override func tearDown() {
        parentWindow?.close()
        parentWindow = nil
        super.tearDown()
    }

    private func makeSurface(
        font: NSFont? = nil,
        fillColor: NSColor = .textBackgroundColor,
        textColor: NSColor = .textColor
    ) -> SkinContext.ResolvedSurface {
        SkinContext.ResolvedSurface(
            fill: .color(fillColor),
            border: nil,
            corner: .uniform(0),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: font,
            text: SkinContext.ResolvedText(color: textColor, shadow: nil),
            animation: nil,
            states: []
        )
    }

    // MARK: - Font application (Task 17.3)

    func testSkinFontAppliedWhenDeclared() {
        // Skin declares a 20pt Menlo. ReaderMode text view must pick it up.
        guard let menlo = NSFont(name: "Menlo", size: 20) else {
            XCTSkip("Menlo not available on this system")
            return
        }
        let surface = makeSurface(font: menlo)
        let ctx = SkinContext(
            surfaces: [.readerPanelBackground: surface],
            reactive: ReactiveUniformSnapshot()
        )

        let controller = ReaderModeController()
        controller.skinContext = ctx
        controller.increaseContrastEnabled = { false }
        controller.activate(for: StubChannel(), parentWindow: parentWindow,
                            animationEngine: nil)
        defer { controller.dismiss() }

        let textView = findTextView(in: controller)
        // Font family name via `NSFont.familyName` — the PostScript
        // name ("Menlo-Regular") is a serialization detail; what the
        // user sees is the family. Compare on familyName + pointSize
        // for a stable assertion across macOS versions.
        XCTAssertEqual(textView?.font?.familyName, "Menlo",
                       "Skin-declared font must reach the text view when IC is off")
        XCTAssertEqual(textView?.font?.pointSize, 20)
    }

    func testMissingSurfaceKeepsSFMonoDefault() {
        // No surface defined — `resolvedFont` returns nil; text view's
        // init-time SF Mono 14pt must survive.
        let ctx = SkinContext(surfaces: [:], reactive: ReactiveUniformSnapshot())

        let controller = ReaderModeController()
        controller.skinContext = ctx
        controller.increaseContrastEnabled = { false }
        controller.activate(for: StubChannel(), parentWindow: parentWindow,
                            animationEngine: nil)
        defer { controller.dismiss() }

        let textView = findTextView(in: controller)
        XCTAssertEqual(textView?.font?.pointSize, 14,
                       "No surface → preserve pre-Amplify SF Mono 14pt")
    }

    func testIncreaseContrastOverridesSkinFont() {
        // Req 8.6 — Increase Contrast pins SF Mono 14pt regardless
        // of manifest content.
        guard let menlo = NSFont(name: "Menlo", size: 24) else {
            XCTSkip("Menlo not available on this system")
            return
        }
        let surface = makeSurface(font: menlo)
        let ctx = SkinContext(
            surfaces: [.readerPanelBackground: surface],
            reactive: ReactiveUniformSnapshot()
        )

        let controller = ReaderModeController()
        controller.skinContext = ctx
        controller.increaseContrastEnabled = { true }  // ← pinned
        controller.activate(for: StubChannel(), parentWindow: parentWindow,
                            animationEngine: nil)
        defer { controller.dismiss() }

        let textView = findTextView(in: controller)
        XCTAssertEqual(textView?.font?.pointSize, 14,
                       "Increase Contrast must override skin font → SF Mono 14pt (Req 8.6)")
        // Specifically NOT Menlo.
        XCTAssertNotEqual(textView?.font?.familyName, "Menlo")
    }

    // MARK: - Fill + text color

    func testSkinFillAppliedToTextView() {
        let navy = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.3, alpha: 1)
        let surface = makeSurface(fillColor: navy, textColor: .white)
        let ctx = SkinContext(
            surfaces: [.readerPanelBackground: surface],
            reactive: ReactiveUniformSnapshot()
        )

        let controller = ReaderModeController()
        controller.skinContext = ctx
        controller.increaseContrastEnabled = { false }
        controller.activate(for: StubChannel(), parentWindow: parentWindow,
                            animationEngine: nil)
        defer { controller.dismiss() }

        let textView = findTextView(in: controller)
        // NSColor equality across color spaces is unreliable; compare
        // in sRGB after conversion.
        let resolved = textView?.backgroundColor.usingColorSpace(.sRGB)
        XCTAssertEqual(resolved?.redComponent ?? 0, 0.1, accuracy: 0.01,
                       "Skin-declared fill color must reach the text view backgroundColor")
    }

    // MARK: - Helpers

    private func findTextView(in controller: ReaderModeController) -> NSTextView? {
        guard let panel = controller.panel,
              let scroll = panel.contentView as? NSScrollView,
              let textView = scroll.documentView as? NSTextView else {
            return nil
        }
        return textView
    }
}
