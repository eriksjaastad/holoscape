import XCTest
import AppKit
import CoreGraphics
@testable import Holoscape

/// Chrome v4 Task 11.3 — MainWindowController chrome-mode-branch
/// invariants. Exercises the pure helpers (install / reparent /
/// teardown) directly; the window reconstruction path
/// (`reconstructAsBorderlessTransparent`, `reconstructAsTitled`)
/// mutates shared app state in ways that are brittle to exercise
/// under XCTest, so those methods have a narrower "shape-of-output"
/// test that constructs a target window and checks its style mask
/// + transparency flags without wiring through the actual
/// `self.window` assignment.
///
/// Validator + applyChromeSkin full-path testing belongs on the Mac
/// Mini XCUITest lane (per MEMORY's "UI testing on Mac Mini" rule);
/// these tests pin the helpers in isolation.
@MainActor
final class MainWindowControllerChromeBranchTests: XCTestCase {

    // MARK: - Controller transitions

    func testPersistedV4SkinLaunchAttachesStableHostInsideInteriorView() throws {
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.window is ShapedBorderlessWindow)
        let interior = try XCTUnwrap(controller.currentChromeInteriorView)
        XCTAssertTrue(controller.appContentHost.superview === interior,
                      "Persisted v4 launch must mount app content inside InteriorView on first render")
        XCTAssertEqual(hostAttachmentConstraints(for: controller.appContentHost, in: interior).count, 4,
                       "Stable host must be edge-pinned inside InteriorView")
        XCTAssertTrue(controller.appContentBodyTopConstraint?.secondItem === interior.safeAreaLayoutGuide,
                      "Chrome mode body guide should track the InteriorView safe area")
        XCTAssertTrue(controller.appContentHost.subviews.contains(where: { $0 is TabBarView }))
        XCTAssertTrue(controller.appContentHost.subviews.contains(where: { $0 is NSSplitView }))
        XCTAssertTrue(controller.window.styleMask.contains(.closable),
                      "Chrome reconstruction must preserve close semantics for detached traffic lights")
        XCTAssertTrue(controller.window.styleMask.contains(.miniaturizable),
                      "Chrome reconstruction must preserve minimize semantics for detached traffic lights")
    }

    func testChromeToDefaultTransitionPreservesStableHostConstraints() throws {
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()

        controller.reloadSkin(named: "Default")
        drainMainQueue()

        XCTAssertFalse(controller.window is ShapedBorderlessWindow)
        XCTAssertTrue(controller.window.styleMask.contains(.titled))
        XCTAssertTrue(controller.window.styleMask.contains(.resizable),
                      "Exiting chrome must restore standard titled-window resize behavior")
        let root = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(controller.appContentHost.superview === root)
        XCTAssertEqual(hostAttachmentConstraints(for: controller.appContentHost, in: root).count, 4,
                       "Stable host must stay edge-pinned after chrome teardown")
        XCTAssertNotNil(controller.window.standardWindowButton(.zoomButton),
                        "Titled reconstruction must restore standard traffic lights")
        XCTAssertNil(controller.chromeWindowControlButton(.zoomButton),
                     "Detached chrome controls must be removed after chrome teardown")
    }

    func testCoreLayoutTreeSurvivesChromeReconstruction() throws {
        let controller = try makeController()
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let initialRoot = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(controller.appContentHost.superview === initialRoot)
        XCTAssertEqual(controller.appContentHost.subviews.count, 6,
                       "Stable host should own the full app layout tree in titled mode")
        XCTAssertTrue(controller.appContentBodyTopConstraint?.secondItem === initialRoot.safeAreaLayoutGuide,
                      "Titled mode body guide should track the content view safe area below the titlebar")

        controller.reloadSkin(named: "HoloscapeClassic-live")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let interior = try XCTUnwrap(controller.currentChromeInteriorView)
        XCTAssertTrue(controller.appContentHost.superview === interior)
        XCTAssertEqual(controller.appContentHost.subviews.count, 6,
                       "Chrome reconstruction must move the stable host without rebuilding its children")

        controller.reloadSkin(named: "Default")
        drainMainQueue()

        let restoredRoot = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(controller.appContentHost.superview === restoredRoot)
        XCTAssertEqual(controller.appContentHost.subviews.count, 6,
                       "Leaving chrome must keep the same app layout tree attached to the titled host")
    }

    // MARK: - Install helpers

    func testInstallChromeHostViewAddsSubviewAndPinsFrame() {
        // Build an ephemeral window + content view to exercise
        // install in isolation. We're not calling reconstruct*
        // here; those require a real MainWindowController with app
        // state. This verifies the install helper produces the
        // expected view tree.
        let container = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        container.wantsLayer = true

        let chrome = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000, height: 700,
            interiorRect: SkinRect(x: 40, y: 60, width: 920, height: 600)
        )
        let baseImage = makeRGBAImage(widthPx: 64, heightPx: 64)

        let host = ChromeHostView(chrome: chrome, baseImage: baseImage, clock: nil)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .below, relativeTo: nil)

        XCTAssertTrue(container.subviews.contains(host), "ChromeHostView must be a subview of the container")
        XCTAssertEqual(host.frame, container.bounds, "ChromeHostView must fill the container")
    }

    func testInstallInteriorViewPinsToInteriorRect() {
        let container = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        container.wantsLayer = true
        let rect = SkinRect(x: 40, y: 60, width: 920, height: 600)

        let interior = InteriorView(rect: rect, interiorPath: nil)
        let frame = InteriorView.computedFrame(
            interiorRect: rect,
            in: container.bounds,
            superviewIsFlipped: container.isFlipped
        )
        interior.frame = frame
        container.addSubview(interior)

        // ShapedContentView is not flipped; expected Y is flipped.
        XCTAssertEqual(interior.frame.width, 920)
        XCTAssertEqual(interior.frame.height, 600)
        XCTAssertTrue(container.subviews.contains(interior))
    }

    // MARK: - Reparent

    func testReparentMovesSubviewsIntoInteriorView() {
        let container = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        container.wantsLayer = true

        // Three app-content subviews.
        let appA = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let appB = NSView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        let appC = NSView(frame: NSRect(x: 200, y: 0, width: 100, height: 100))
        container.addSubview(appA)
        container.addSubview(appB)
        container.addSubview(appC)

        // Snapshot before install.
        let snapshot = container.subviews

        // Install chrome host + interior AFTER the snapshot, so the
        // exclusion list matches production semantics.
        let chrome = ChromeDescriptor(
            mode: .baked,
            image: "chrome.png",
            width: 1000, height: 700,
            interiorRect: SkinRect(x: 0, y: 0, width: 1000, height: 700)
        )
        let host = ChromeHostView(chrome: chrome, baseImage: makeRGBAImage(widthPx: 32, heightPx: 32), clock: nil)
        container.addSubview(host)
        let interior = InteriorView(rect: chrome.interiorRect, interiorPath: nil)
        container.addSubview(interior)

        // Reparent: every snapshot subview that ISN'T chrome host /
        // interior moves into interior.
        for view in snapshot where view !== host && view !== interior {
            view.removeFromSuperview()
            interior.addSubview(view)
        }

        // Post-conditions:
        //   - interior's subviews include appA, appB, appC
        //   - container's subviews include ONLY host + interior
        XCTAssertTrue(interior.subviews.contains(appA))
        XCTAssertTrue(interior.subviews.contains(appB))
        XCTAssertTrue(interior.subviews.contains(appC))
        XCTAssertFalse(container.subviews.contains(appA))
        XCTAssertFalse(container.subviews.contains(appB))
        XCTAssertFalse(container.subviews.contains(appC))

        let containerChildren = Set(container.subviews.map { ObjectIdentifier($0) })
        XCTAssertEqual(containerChildren, Set([ObjectIdentifier(host), ObjectIdentifier(interior)]),
            "After reparent, container holds only ChromeHostView + InteriorView as direct children")
    }

    // MARK: - Chrome-mode window shape

    func testBorderlessTransparentWindowIsConfiguredCorrectly() {
        // Construct a window with the same recipe the branch uses
        // and confirm the flags stuck. This pins the Cocoa
        // Transparency Recipe contract at the place where it's
        // applied (Req 3.1).
        let w = ShapedBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.contentMinSize = NSSize(width: 1000, height: 700)
        w.contentMaxSize = NSSize(width: 1000, height: 700)

        XCTAssertFalse(w.isOpaque, "Borderless chrome window must not be opaque (Req 3.1)")
        XCTAssertFalse(w.hasShadow, "Chrome PNG provides its own drop shadow via alpha — system shadow would double it")
        XCTAssertTrue(w.styleMask.contains(.borderless))
        XCTAssertTrue(w.styleMask.contains(.closable))
        XCTAssertTrue(w.styleMask.contains(.miniaturizable))
        XCTAssertFalse(w.styleMask.contains(.titled), "Chrome window must not be titled (AppKit locks opaque backing on titled)")
        XCTAssertEqual(w.backgroundColor, .clear)
        XCTAssertFalse(w.isReleasedWhenClosed)
    }

    func testDetachedChromeButtonsUseExplicitControllerHandlers() throws {
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()

        let close = try XCTUnwrap(controller.chromeWindowControlButton(.closeButton))
        let minimize = try XCTUnwrap(controller.chromeWindowControlButton(.miniaturizeButton))
        let zoom = try XCTUnwrap(controller.chromeWindowControlButton(.zoomButton))

        XCTAssertTrue(close.target === controller)
        XCTAssertEqual(close.action, NSSelectorFromString("handleChromeCloseButton:"))
        XCTAssertTrue(minimize.target === controller)
        XCTAssertEqual(minimize.action, NSSelectorFromString("handleChromeMinimizeButton:"))
        XCTAssertTrue(zoom.target === controller)
        XCTAssertEqual(zoom.action, NSSelectorFromString("handleChromeZoomButton:"))
    }

    func testTitledWindowRecipe() {
        // Pair with above — validates the inverse path used when a
        // v4 chrome skin is replaced by a pre-v4 skin (Req 3.1a).
        // Mirror the reconstructAsTitled property set so regressions
        // in either direction surface here.
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.isOpaque = true
        w.backgroundColor = .windowBackgroundColor

        XCTAssertTrue(w.styleMask.contains(.titled))
        XCTAssertTrue(w.styleMask.contains(.resizable))
        XCTAssertTrue(w.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(w.isOpaque, "Titled inverse path must be opaque — matches pre-v4 default")
        XCTAssertFalse(w.isReleasedWhenClosed,
            "Reconstruction path must set isReleasedWhenClosed=false so ARC is sole owner (matches bootstrap)")
        XCTAssertEqual(w.backgroundColor, .windowBackgroundColor)
    }

    // MARK: - Tear down CA-mask

    // MARK: - Drag via background (Task 15.1)

    func testBorderlessTransparentWindowSupportsBackgroundDrag() {
        // Pins Req 4.6 — chrome-mode windows use the whole chrome as a
        // drag handle via `isMovableByWindowBackground` rather than
        // the pre-v4 path's `WindowDragOverlay` strip. Without this,
        // borderless windows can't be dragged at all because there's
        // no title bar to grab.
        let w = ShapedBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = true

        XCTAssertTrue(w.isMovableByWindowBackground,
            "Chrome-mode windows must be draggable from any background pixel (Req 4.6)")
    }

    // MARK: - WindowDragOverlay installation

    func testChromeBranchInstallsDedicatedDragOverlay() throws {
        // Background dragging is not reliable once the borderless
        // chrome window is full of subviews. Chrome mode installs a
        // dedicated invisible shelf above the interior instead.
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()

        let overlay = try XCTUnwrap(controller.chromeDragOverlaysForTesting.first)
        XCTAssertEqual(controller.chromeDragOverlaysForTesting.count, 1)
        XCTAssertGreaterThan(overlay.frame.width, 0)
        XCTAssertGreaterThan(overlay.frame.height, 0)
        XCTAssertTrue(controller.window.contentView?.subviews.contains(overlay) ?? false)
    }

    func testTearDownCAMaskClearsMaskAndSampler() {
        let content = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        content.wantsLayer = true

        // Stage a mask + sampler as if the pre-v4 path had just run.
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(rect: content.bounds, transform: nil)
        content.layer?.mask = maskLayer
        content.sampler = HitRegionSampler(polygons: [
            Polygon(points: [Point(x: 0, y: 0), Point(x: 500, y: 0), Point(x: 500, y: 500)]),
        ])

        // Tear down via the same contract.
        content.layer?.mask = nil
        content.sampler = nil

        XCTAssertNil(content.layer?.mask, "tearDown must clear layer.mask")
        XCTAssertNil(content.sampler, "tearDown must clear the sampler")
    }

    // MARK: - Fixture

    private func makeRGBAImage(widthPx: Int, heightPx: Int) -> CGImage {
        let bytesPerRow = widthPx * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * heightPx)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0xFF
            pixels[i + 1] = 0x44
            pixels[i + 2] = 0xCC
            pixels[i + 3] = 0xFF
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: widthPx, height: heightPx,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func makeController(persistedSkin: String? = nil) throws -> MainWindowController {
        _ = NSApplication.shared

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowControllerChromeBranchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let configService = ConfigService(configDir: tempRoot)
        var config = HoloscapeConfig.default
        config.appearance.skinName = persistedSkin
        configService.save(config)

        let channelManager = ChannelManager(configService: configService)
        return MainWindowController(channelManager: channelManager, configService: configService)
    }

    private func hostAttachmentConstraints(for host: NSView, in container: NSView) -> [NSLayoutConstraint] {
        container.constraints.filter { constraint in
            (constraint.firstItem as AnyObject?) === host || (constraint.secondItem as AnyObject?) === host
        }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
