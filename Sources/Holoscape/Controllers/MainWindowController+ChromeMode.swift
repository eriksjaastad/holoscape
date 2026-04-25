import AppKit
import Foundation

// MARK: - Chrome v4 mode branch
//
// PR #6 (Task Group 11) — `applyChromeSkin` + window reconstruction.
//
// Routes v4 chrome skins through a freshly-constructed borderless
// transparent window. PR #1's Risk #1 investigation
// (`docs/research/chrome-risk1-transparency-findings.md`) proved that
// AppKit locks in opaque window backing at construction time; a
// titled window cannot be retrofitted into transparency via property
// flips, so the branch constructs a new `ShapedBorderlessWindow`
// from birth and migrates state into it (delegate, child windows,
// first responder).
//
// The existing pre-v4 `applyWindowShape` branch still runs for every
// v1/v2/v3 skin — this branch only fires when `loaded.chrome != nil`
// (Req 16.1 backward-compat invariant). No in-tree skin declares a
// `chrome` field yet (PR #14–#16 migrate the reference skins), so
// this branch is effectively dormant on `main` until those land.

extension MainWindowController {

    // MARK: - Public entry point

    /// v4 chrome entry point. Called by `reloadSkin` when
    /// `loaded.chrome != nil` and a baked Base_Layer + validator
    /// result are available. Reconstructs the window as borderless
    /// transparent (if not already), installs `ChromeHostView` and
    /// `InteriorView` under the content view, and reattaches the
    /// controller-owned app host into `InteriorView`.
    ///
    /// A validation-fatal skin (Req 12.8) arrives here with
    /// `loaded.chrome == nil` + `validationBannerReason != nil` —
    /// callers handle that case via the existing `applySkin` path.
    /// This method is only invoked when `loaded.chrome != nil`.
    func applyChromeSkin(_ loaded: LoadedSkin) {
        guard let chrome = loaded.chrome, let baseImage = loaded.baseImage else {
            assertionFailure("applyChromeSkin: caller precondition violated — chrome/baseImage nil")
            NSLog("MainWindowController: applyChromeSkin called without chrome/baseImage — caller should route through applySkin")
            return
        }

        let previousResponder = window.firstResponder
        let nominal = NSSize(width: chrome.width, height: chrome.height)
        let newWindow = reconstructAsBorderlessTransparent(size: nominal)

        // Tear down any pre-existing CA-mask state on the new
        // window's content view. The reconstruction path above did
        // not inherit a mask (new window, new content), but future
        // callers reconstructing FROM an already-masked state would
        // leave stale mask + sampler behind without this call.
        tearDownOldCAMaskPath(on: newWindow)

        guard let shapedContent = newWindow.contentView as? ShapedContentView else {
            NSLog("MainWindowController: chrome mode reconstruction produced a non-ShapedContentView root — aborting chrome install")
            return
        }

        let hostView = installChromeHostView(
            chrome: chrome,
            baseImage: baseImage,
            in: shapedContent
        )
        let interior = installInteriorView(
            interiorRect: chrome.interiorRect,
            interiorPath: chrome.interiorPath,
            in: shapedContent
        )

        // Install a content-view mask derived from Base_Layer alpha.
        // Without a mask, AppKit paints an opaque backing store even
        // when the PNG itself has transparent pixels. Using the actual
        // alpha channel lets a skin draw separate visual masses inside
        // one NSWindow: transparent gaps stay transparent instead of
        // being forced back into a single rounded slab.
        installChromeSilhouetteMask(
            on: shapedContent,
            size: nominal,
            baseImage: baseImage,
            cornerRadius: 16
        )

        currentChromeHostView = hostView
        currentChromeInteriorView = interior
        attachAppContentHost(to: interior)
        let chromeLayout = chromeResolvedLayout(loaded.layout)

        // Lock nominal size so chrome coords map 1:1 to the content
        // view. v4 chrome is fixed-size by construction (Req 3.6).
        newWindow.contentMinSize = nominal
        newWindow.contentMaxSize = nominal
        newWindow.setContentSize(nominal)
        newWindow.styleMask.remove(.resizable)

        // Keep AppKit's background-drag flag on as a harmless fallback,
        // but do not rely on it. The chrome window is populated by
        // app-content subviews, and those subviews usually win hit
        // testing before "window background" ever sees a mouseDown.
        // Dedicated invisible overlays below provide the reliable drag
        // targets users can actually grab.
        newWindow.isMovableByWindowBackground = true
        installChromeDragHandles(
            in: shapedContent,
            chrome: chrome,
            layout: chromeLayout
        )

        // Add detached traffic-light buttons so the user can close,
        // minimise, and fullscreen a chrome-mode window. Borderless
        // windows have no system titlebar buttons; we create them
        // via the class-method factory, position them at the
        // standard macOS location, and wire them through the
        // explicit handlers on the controller so these detached
        // buttons do not depend on titlebar-specific responder-chain
        // wiring that only exists for AppKit-managed title bars.
        //
        // Hover-coordination (hovering one button highlights all
        // three) is intentionally absent — that behaviour requires
        // AppKit's private titlebar machinery and is not available
        // for detached buttons. Close / miniaturize / fullscreen
        // operations are fully functional.
        installWindowControlButtons(
            in: shapedContent,
            chrome: chrome,
            layout: chromeLayout
        )
        updateChromeDragExclusions(in: shapedContent)

        // Restore first responder AFTER reparenting — the captured
        // responder's `window` now resolves to `newWindow` if it's
        // an `NSView` descendant of the reparented subtree. A
        // responder that didn't survive reparenting (unlikely; the
        // app content is a single cohesive tree) is silently
        // skipped rather than crashing `makeFirstResponder`.
        if let responder = previousResponder as? NSView,
           responder.window === newWindow {
            newWindow.makeFirstResponder(responder)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateTabBarLeading()
        }
    }

    /// Add close / miniaturise / fullscreen buttons to a borderless
    /// chrome window's content view.
    ///
    /// `NSWindow.standardWindowButton(_:for:)` (the class method) creates
    /// a standalone button styled identically to the system traffic lights
    /// but unconnected to any titlebar view.
    ///
    /// Default placement mirrors standard macOS traffic lights. Vessel
    /// skins can shift the group to a skin-painted landing dock on the
    /// main body so controls do not visually belong to the side panel.
    func installWindowControlButtons(
        in contentView: NSView,
        chrome: ChromeDescriptor,
        layout: SkinLayoutDescriptor?
    ) {
        chromeWindowControlButtons.removeAll()

        let buttonSize = CGSize(width: 12, height: 12)
        let yFromTop = chromeControlTopY(layout: layout)
        let buttonY = CGFloat(chrome.height) - yFromTop - buttonSize.height
        let leadingX = chromeControlLeadingX(chrome: chrome, layout: layout)

        let specs: [(NSWindow.ButtonType, CGFloat, Selector, String)] = [
            (.closeButton,       leadingX,      #selector(handleChromeCloseButton(_:)), "chrome-close-button"),
            (.miniaturizeButton, leadingX + 20, #selector(handleChromeMinimizeButton(_:)), "chrome-minimize-button"),
            (.zoomButton,        leadingX + 40, #selector(handleChromeZoomButton(_:)), "chrome-zoom-button"),
        ]

        for (buttonType, x, action, identifier) in specs {
            guard let btn = NSWindow.standardWindowButton(
                buttonType,
                for: [.titled, .closable, .miniaturizable, .resizable]
            ) else { continue }
            btn.frame = CGRect(x: x, y: buttonY, width: buttonSize.width, height: buttonSize.height)
            btn.identifier = NSUserInterfaceItemIdentifier(identifier)
            btn.setAccessibilityIdentifier(identifier)
            btn.isEnabled = true
            btn.target = self
            btn.action = action
            contentView.addSubview(btn)
            chromeWindowControlButtons[buttonType] = btn
        }
    }

    private func chromeControlLeadingX(
        chrome: ChromeDescriptor,
        layout: SkinLayoutDescriptor?
    ) -> CGFloat {
        guard let layout,
              let channel = layout.channelVessel,
              let seam = layout.seam else {
            return 7
        }

        switch channel.dock {
        case .left:
            // For vessel skins, traffic lights belong visually to the
            // main text body rather than the detachable channel spine.
            // Coordinate space is chrome-image top-left; frame x is
            // unchanged by AppKit's bottom-left y conversion.
            let mainBodyX = CGFloat(chrome.interiorRect.x) + channel.size + seam.thickness
            let standardGroupWidth: CGFloat = 52
            if layout.screenVessel?.variant == .mercuryScreenBody {
                let mercuryDock = CGRect(x: 296, y: 16, width: 98, height: 30)
                return mercuryDock.midX - standardGroupWidth / 2
            }
            return mainBodyX + 18
        case .unsupported:
            return 7
        }
    }

    private func chromeResolvedLayout(_ layout: SkinLayoutDescriptor?) -> SkinLayoutDescriptor? {
        guard var layout else { return nil }
        guard let vesselGap = layout.vesselGap else { return layout }

        if var seam = layout.seam {
            seam.thickness = vesselGap
            layout.seam = seam
        } else {
            layout.seam = SeamLayoutDescriptor(thickness: vesselGap, style: .flat)
        }
        return layout
    }

    private func chromeControlTopY(layout: SkinLayoutDescriptor?) -> CGFloat {
        if layout?.screenVessel?.variant == .mercuryScreenBody {
            let mercuryDock = CGRect(x: 296, y: 16, width: 98, height: 30)
            let buttonSize: CGFloat = 12
            return mercuryDock.midY - buttonSize / 2
        }
        return 6
    }

    /// Install invisible drag handles over non-content chrome. This
    /// keeps the terminal and tab/sidebar controls interactive while
    /// giving borderless chrome windows a predictable title-shelf grab
    /// target.
    func installChromeDragHandles(
        in contentView: NSView,
        chrome: ChromeDescriptor,
        layout: SkinLayoutDescriptor?
    ) {
        tearDownChromeDragHandles()

        let chromeWidth = CGFloat(chrome.width)
        let chromeHeight = CGFloat(chrome.height)
        let interiorTop = CGFloat(chrome.interiorRect.y)
        let topShelfHeight = min(max(interiorTop, 32), 52)
        guard topShelfHeight > 0 else { return }

        if let layout,
           let channel = layout.channelVessel,
           let seam = layout.seam,
           channel.dock == .left,
           layout.screenVessel?.variant == .mercuryScreenBody {
            chromeDragOverlays = mercuryDeckDragHandleRects(
                chrome: chrome,
                channel: channel,
                seam: seam
            ).compactMap { rect in
                installChromeDragOverlay(in: contentView, topLeftRect: rect, chromeHeight: chromeHeight)
            }
            (contentView as? ShapedContentView)?.chromeDragRegions = chromeDragOverlays.map(\.frame)
            return
        }

        var topLeftRects: [CGRect] = []
        if let layout,
           let channel = layout.channelVessel,
           let seam = layout.seam,
           channel.dock == .left {
            let mainBodyX = CGFloat(chrome.interiorRect.x) + channel.size + seam.thickness
            let trailingInset = max(0, chromeWidth - CGFloat(chrome.interiorRect.x + chrome.interiorRect.width))
            topLeftRects.append(CGRect(
                x: mainBodyX,
                y: 0,
                width: max(0, chromeWidth - mainBodyX - trailingInset),
                height: topShelfHeight
            ))

            if channel.variant == .mercuryControlSpine {
                // The side spine reads as a second small window. Give
                // its exposed top cap a grab strip without covering the
                // launcher below it.
                topLeftRects.append(CGRect(x: 4, y: 58, width: channel.size - 6, height: 18))
            }
        } else {
            topLeftRects.append(CGRect(x: 0, y: 0, width: chromeWidth, height: topShelfHeight))
        }

        chromeDragOverlays = topLeftRects.compactMap {
            installChromeDragOverlay(in: contentView, topLeftRect: $0, chromeHeight: chromeHeight)
        }
        (contentView as? ShapedContentView)?.chromeDragRegions = chromeDragOverlays.map(\.frame)
    }

    private func mercuryDeckDragHandleRects(
        chrome: ChromeDescriptor,
        channel: ChannelVesselLayoutDescriptor,
        seam: SeamLayoutDescriptor
    ) -> [CGRect] {
        let chromeWidth = CGFloat(chrome.width)
        let mainBodyX = CGFloat(chrome.interiorRect.x) + channel.size + seam.thickness
        let mainBodyWidth = max(0, chromeWidth - mainBodyX - 6)

        return [
            // The visible top metal shelf.
            CGRect(x: mainBodyX, y: 8, width: mainBodyWidth, height: 70),
            // Left, right, and bottom frame rails around the console.
            CGRect(x: mainBodyX, y: 78, width: 18, height: 594),
            CGRect(x: chromeWidth - 26, y: 78, width: 20, height: 594),
            CGRect(x: mainBodyX, y: 672, width: mainBodyWidth, height: 20),
            // The side panel's exposed top cap, aligned from the same
            // vertical offset the skin declares for the channel vessel.
            CGRect(
                x: 4,
                y: 58,
                width: max(0, channel.size - 6),
                height: max(18, min(40, (channel.capStart - (channel.verticalOffset ?? 0)) / 2))
            ),
        ]
    }

    private func installChromeDragOverlay(
        in contentView: NSView,
        topLeftRect rect: CGRect,
        chromeHeight: CGFloat
    ) -> WindowDragOverlay? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let overlay = WindowDragOverlay(frame: frameFromTopLeftRect(rect, chromeHeight: chromeHeight))
        overlay.autoresizingMask = []
        overlay.toolTip = "Drag Holoscape window"
        overlay.setAccessibilityElement(false)
        contentView.addSubview(overlay, positioned: .above, relativeTo: currentChromeInteriorView)
        return overlay
    }

    func tearDownChromeDragHandles() {
        for overlay in chromeDragOverlays {
            overlay.removeFromSuperview()
        }
        chromeDragOverlays.removeAll()
        if let shapedContent = window.contentView as? ShapedContentView {
            shapedContent.chromeDragRegions = []
            shapedContent.chromeDragExclusionRegions = []
        }
    }

    private func updateChromeDragExclusions(in contentView: NSView) {
        guard let shapedContent = contentView as? ShapedContentView else { return }
        shapedContent.chromeDragExclusionRegions = chromeWindowControlButtons.values.map {
            $0.frame.insetBy(dx: -6, dy: -6)
        }
    }

    private func frameFromTopLeftRect(_ rect: CGRect, chromeHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: chromeHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    @objc private func handleChromeCloseButton(_ sender: Any?) {
        guard window.styleMask.contains(.closable) else { return }
        window.close()
    }

    @objc private func handleChromeMinimizeButton(_ sender: Any?) {
        guard window.styleMask.contains(.miniaturizable) else { return }
        window.miniaturize(sender)
    }

    @objc private func handleChromeZoomButton(_ sender: Any?) {
        let optionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if optionPressed {
            window.zoom(sender)
            return
        }
        window.toggleFullScreen(sender)
    }

    /// Install a mask on the content view's layer so
    /// AppKit actually clips the window backing to the chrome
    /// silhouette. PNG alpha on `ChromeHostView` is both the visual
    /// content and the source for this mask. Without it, cut corners
    /// and inter-window gaps render opaque charcoal regardless of PNG
    /// alpha. Canonical recipe — see
    /// `docs/research/chrome-transparency-root-cause.md`.
    func installChromeSilhouetteMask(
        on contentView: NSView,
        size: NSSize,
        baseImage: CGImage? = nil,
        cornerRadius: CGFloat
    ) {
        contentView.wantsLayer = true
        // AppKit creates the backing layer lazily on the first draw.
        // We're still on the same call stack as makeKeyAndOrderFront —
        // the run loop hasn't done a display pass yet — so layer can be
        // nil here and `layer?.mask = mask` would silently no-op.
        // Explicitly assign a backing layer to force immediate creation.
        if contentView.layer == nil {
            let backingLayer = CALayer()
            backingLayer.frame = CGRect(origin: .zero, size: size)
            backingLayer.backgroundColor = NSColor.clear.cgColor
            backingLayer.isOpaque = false
            contentView.layer = backingLayer
        }
        guard let layer = contentView.layer else {
            NSLog("[chrome] installChromeSilhouetteMask: layer nil after explicit assignment — mask not installed")
            return
        }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false

        let rect = CGRect(origin: .zero, size: size)
        let mask = CALayer()
        mask.frame = rect
        if let baseImage {
            mask.contents = baseImage
            mask.contentsGravity = .resize
            mask.contentsScale = max(1, CGFloat(baseImage.width) / max(size.width, 1))
        } else {
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            let shapeMask = CAShapeLayer()
            shapeMask.frame = rect
            shapeMask.path = path
            shapeMask.fillColor = NSColor.white.cgColor
            shapeMask.fillRule = .nonZero
            layer.mask = shapeMask
            return
        }
        layer.mask = mask
    }

    // MARK: - Reconstruction

    /// Construct a fresh `ShapedBorderlessWindow` born borderless +
    /// transparent + shadow-free, migrate the main window's state
    /// into it, and replace `self.window`.
    ///
    /// Required per Requirement 3.1 — AppKit locks in opaque window
    /// backing at construction time
    /// (`docs/research/chrome-risk1-transparency-findings.md`), so
    /// transparency cannot be achieved by property-flipping the
    /// existing titled window. The isolation test from PR #1 proved
    /// the recipe works on a fresh borderless window; this method is
    /// that recipe.
    ///
    /// State migration: delegate, child windows (Reader Mode panel,
    /// BugReportDialog), first responder (when it's a view in the
    /// content tree). The old window is `orderOut`'d with a nil
    /// delegate — avoids spurious `windowWillClose` callbacks on the
    /// controller. ARC collects the old window.
    @discardableResult
    func reconstructAsBorderlessTransparent(size: NSSize) -> ShapedBorderlessWindow {
        let oldWindow = window
        let wasKey = oldWindow.isKeyWindow

        // New borderless window with the Cocoa Transparency Recipe
        // applied AT CONSTRUCTION TIME (the load-bearing invariant).
        let newWindow = ShapedBorderlessWindow(
            contentRect: NSRect(origin: oldWindow.frame.origin, size: size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        // hasShadow = true is canonical — every reference shaped-window
        // implementation uses it. AppKit computes the shadow from the
        // composited content-view alpha, so the shadow respects the
        // CAShapeLayer mask installed in `applyChromeSkin`.
        newWindow.hasShadow = true
        newWindow.title = oldWindow.title
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.collectionBehavior = oldWindow.collectionBehavior.union([.fullScreenPrimary])
        newWindow.contentMinSize = size
        newWindow.contentMaxSize = size

        // Install a fresh `ShapedContentView` root so click-through
        // + drag region hooks (`HitRegionSampler`, `DragRegionTracker`)
        // continue to find the expected view class.
        let freshContent = ShapedContentView(frame: NSRect(origin: .zero, size: size))
        // Use a layer-hosting pattern: assign the backing layer before
        // wantsLayer=true so the layer is never nil. Using `layer?`
        // optional chaining here would silently no-op because the view
        // isn't in a window yet and AppKit creates backing layers lazily.
        //
        // IMPORTANT: CALayer() defaults to CGRect.zero frame. For a
        // layer-hosting view, AppKit does NOT auto-sync the layer frame
        // to the view's bounds — that is the caller's responsibility.
        // Omitting this caused the mask to be applied to a zero-size
        // layer that had no clipping effect.
        let freshLayer = CALayer()
        freshLayer.frame = CGRect(origin: .zero, size: size)
        freshLayer.backgroundColor = NSColor.clear.cgColor
        freshLayer.isOpaque = false
        freshContent.layer = freshLayer
        freshContent.wantsLayer = true
        newWindow.contentView = freshContent
        animationEngine.hostView = freshContent

        // Migrate child windows (Reader Mode panel, BugReportDialog)
        // from old → new. `addChildWindow` on the new parent handles
        // the reparenting atomically.
        for child in oldWindow.childWindows ?? [] {
            oldWindow.removeChildWindow(child)
            newWindow.addChildWindow(child, ordered: .above)
        }

        // Install delegate. Old window's delegate is nilled to
        // suppress spurious close callbacks during the swap.
        oldWindow.delegate = nil
        newWindow.delegate = self

        // Bring the new window online BEFORE ordering the old one
        // out — prevents the app from going to background during the
        // (single-frame) window-less moment.
        if wasKey {
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            newWindow.orderFront(nil)
        }
        oldWindow.orderOut(nil)

        // First responder restoration is the CALLER's job (see
        // `applyChromeSkin`). At this point the fresh content view
        // has no subviews — the app content is still on the OLD
        // window. Any attempt to restore first responder here would
        // find `responder.window === oldWindow` and drop it
        // unconditionally, which is the dead-code path the
        // original implementation hit.
        newWindow.makeFirstResponder(nil)

        self.window = newWindow
        return newWindow
    }

    /// Inverse of `reconstructAsBorderlessTransparent` — used when a
    /// v4 chrome skin is replaced by a pre-v4 skin at runtime (Req
    /// 3.1a). Constructs a standard titled window and migrates
    /// state back. The caller installs whatever content the new
    /// non-chrome path wants inside `window.contentView`.
    /// Reverse `applyChromeSkin`: reconstruct the window as a regular
    /// titled window and reattach the stable app host directly under
    /// the titled content root.
    ///
    /// This is the exit path from chrome mode. It must be called
    /// whenever `reloadSkin` routes to a non-chrome skin while the
    /// current window is a `ShapedBorderlessWindow`; without it the
    /// window stays borderless permanently (no traffic lights, no
    /// resize chrome).
    func teardownChromeSkin() {
        guard window is ShapedBorderlessWindow else { return }

        let previousResponder = window.firstResponder
        chromeWindowControlButtons.removeAll()
        tearDownChromeDragHandles()
        currentChromeHostView = nil
        currentChromeInteriorView = nil

        let newWindow = reconstructAsTitled(size: window.frame.size)
        guard let contentView = newWindow.contentView else {
            NSLog("MainWindowController: teardownChromeSkin — contentView nil after reconstruction; app subviews orphaned")
            assertionFailure("reconstructAsTitled must produce a non-nil contentView")
            return
        }

        attachAppContentHost(to: contentView)

        // Disable background-drag (chrome mode sets this; it's wrong
        // for the regular titled window which has a real title bar).
        newWindow.isMovableByWindowBackground = false

        // Restore first responder if the view survived into the new window.
        if let responder = previousResponder as? NSView,
           responder.window === newWindow {
            newWindow.makeFirstResponder(responder)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateTabBarLeading()
        }
    }

    func reconstructAsTitled(size: NSSize) -> NSWindow {
        let oldWindow = window
        let wasKey = oldWindow.isKeyWindow

        let newWindow = NSWindow(
            contentRect: NSRect(origin: oldWindow.frame.origin, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.isOpaque = true
        newWindow.backgroundColor = .windowBackgroundColor
        newWindow.title = oldWindow.title
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.collectionBehavior = oldWindow.collectionBehavior.union([.fullScreenPrimary])

        let freshContent = ShapedContentView(frame: NSRect(origin: .zero, size: size))
        freshContent.wantsLayer = true
        newWindow.contentView = freshContent
        animationEngine.hostView = freshContent

        for child in oldWindow.childWindows ?? [] {
            oldWindow.removeChildWindow(child)
            newWindow.addChildWindow(child, ordered: .above)
        }

        oldWindow.delegate = nil
        newWindow.delegate = self

        if wasKey {
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            newWindow.orderFront(nil)
        }
        oldWindow.orderOut(nil)

        // First-responder restoration is the caller's job, same
        // contract as `reconstructAsBorderlessTransparent`.
        newWindow.makeFirstResponder(nil)

        self.window = newWindow
        return newWindow
    }

    // MARK: - Installation helpers

    /// Install `ChromeHostView` as a subview of the content view.
    /// The host paints the static Base_Layer; animated layers land
    /// in its `animatedLayersContainer` via PR #10+.
    @discardableResult
    func installChromeHostView(
        chrome: ChromeDescriptor,
        baseImage: CGImage,
        in container: NSView
    ) -> ChromeHostView {
        let host = ChromeHostView(chrome: chrome, baseImage: baseImage, clock: nil)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .below, relativeTo: nil)
        currentChromeHostView = host
        return host
    }

    /// Install `InteriorView` pinned to `chrome.interiorRect`.
    /// App-content subviews reparent into this view.
    @discardableResult
    func installInteriorView(
        interiorRect: SkinRect,
        interiorPath: [Polygon]?,
        in container: NSView
    ) -> InteriorView {
        let interior = InteriorView(rect: interiorRect, interiorPath: interiorPath)
        let frame = InteriorView.computedFrame(
            interiorRect: interiorRect,
            in: container.bounds,
            superviewIsFlipped: container.isFlipped
        )
        interior.frame = frame
        // Top-left origin — match ChromeHostView's coord convention.
        container.addSubview(interior, positioned: .above, relativeTo: nil)
        interior.needsLayout = true
        currentChromeInteriorView = interior
        return interior
    }

    /// Remove any CA-mask state left on the content view. A newly-
    /// constructed window's content view has no mask; this is a
    /// safety net for future reconstructions that might start from
    /// an already-masked state.
    func tearDownOldCAMaskPath(on targetWindow: NSWindow) {
        guard let contentView = targetWindow.contentView else { return }
        contentView.layer?.mask = nil
        (contentView as? ShapedContentView)?.sampler = nil
    }

    // MARK: - Accessibility hooks (stubs — filled in PR #13)

    /// Density mode change notification target. PR #13 (task 25.2)
    /// plumbs this to `ChromeHostView.setDensityMode` so animated
    /// layers honor Off / Minimal / Full. Stub now so integration
    /// sites in SettingsService can bind to the selector without
    /// waiting on PR #13's work.
    func updateDensityModeOnChrome(_ mode: DensityModeManager.Mode) {
        // TODO PR #13 (Task 25.2): forward to ChromeHostView
        // attached to the current window's contentView.
    }

    /// Accessibility Reduce Motion change hook. PR #13 (task 25.3)
    /// wires NSWorkspace notifications to freeze/resume the
    /// animation clock through this method.
    func handleReduceMotionChange() {
        // TODO PR #13 (Task 25.3): forward to
        // ChromeHostView.freezeForReduceMotion / resume.
    }
}
