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
    /// `InteriorView` under the content view, and reparents every
    /// existing app-content subview into `InteriorView`.
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

        // Capture the OLD window's first responder before any
        // reconstruction / reparenting happens. Attempt restoration
        // AFTER reparenting below, at which point the responder's
        // superview ancestor is in the new window. Doing the restore
        // inside `reconstructAsBorderlessTransparent` fires too early
        // — the view hasn't migrated into the new window yet, so
        // `responder.window === newWindow` can never be true and
        // the first responder would be unconditionally dropped.
        let previousResponder = window.firstResponder

        // **CRITICAL**: Snapshot the REAL app subviews before
        // reconstruction. Two cases:
        //
        // 1. First entry from pre-v4 path: content view's direct
        //    subviews are the app content (tabBar, sidebarView,
        //    splitPaneManager, inputBox, sessionLauncher).
        // 2. Re-entry from a previous v4 skin: content view holds
        //    the OLD ChromeHostView + OLD InteriorView; the real
        //    app subviews are nested inside the old InteriorView.
        //    Snapshotting the content view's direct subviews here
        //    would capture the previous chrome's host+interior,
        //    reparent them INTO the new interior, and stack
        //    chrome-inside-chrome on every switch.
        //
        // Resolve to the real-app layer by preferring an existing
        // InteriorView's subviews when present.
        let appSubviewsToReparent: [NSView] = Self.extractAppSubviews(
            fromContentView: window.contentView
        )

        // Remove them from their current superview NOW so they
        // survive as unparented views (retained by
        // MainWindowController properties) rather than getting
        // released alongside the old window or old interior.
        for view in appSubviewsToReparent {
            view.removeFromSuperview()
        }

        // Reconstruct the window as borderless transparent unless
        // we're already in chrome mode (subsequent chrome-to-chrome
        // swaps just replace the ChromeHostView image in place —
        // that's PR #18 hot reload; for now every entry
        // reconstructs).
        let nominal = NSSize(width: chrome.width, height: chrome.height)
        let newWindow = reconstructAsBorderlessTransparent(size: nominal)

        // Tear down any pre-existing CA-mask state on the new
        // window's content view. The reconstruction path above did
        // not inherit a mask (new window, new content), but future
        // callers reconstructing FROM an already-masked state would
        // leave stale mask + sampler behind without this call.
        tearDownOldCAMaskPath(on: newWindow)

        // Install ChromeHostView + InteriorView as siblings under
        // the new ShapedContentView. The captured app subviews
        // (snapshotted above) migrate into InteriorView.
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

        // Install a CAShapeLayer mask on the content view. Without
        // this, the NSWindow backing store paints opaque everywhere
        // regardless of the chrome PNG's alpha — AppKit does not
        // honor layer.contents alpha as a window shape. The mask is
        // the load-bearing piece every reference implementation uses
        // (hfyeomans/winamp-macos-migration, CocoaDev BorderlessWindow,
        // Matt Gallagher). See
        // `docs/research/chrome-transparency-root-cause.md`.
        //
        // Silhouette: rounded-rect matching the chrome's nominal
        // width × height with a 16pt corner radius. The live reference
        // skins (`HoloscapeClassic-live`, `HoloscapeSynthwave`,
        // `AmplifyDemo`) all author their cut corners at 16pt. When a
        // future skin declares a different radius, promote this to a
        // ChromeDescriptor field.
        installChromeSilhouetteMask(
            on: shapedContent,
            size: nominal,
            cornerRadius: 16
        )

        reparentAppContent(
            from: appSubviewsToReparent,
            into: interior,
            excluding: [hostView, interior]
        )

        // Lock nominal size so chrome coords map 1:1 to the content
        // view. v4 chrome is fixed-size by construction (Req 3.6).
        newWindow.contentMinSize = nominal
        newWindow.contentMaxSize = nominal
        newWindow.setContentSize(nominal)
        newWindow.styleMask.remove(.resizable)

        // Task 15.1 — drag via background. The chrome PNG covers the
        // entire content view, so every opaque chrome pixel becomes a
        // drag handle when `isMovableByWindowBackground = true`. This
        // replaces the pre-v4 path's `WindowDragOverlay` (a 20pt-tall
        // invisible strip at the top of the content view), which
        // chrome mode never installs (see `reloadSkin`'s
        // `chrome != nil` branch — it skips `applyWindowShape` +
        // `applyDragRegions` entirely).
        //
        // Per Req 4.6 + 4.5: when the manifest declares
        // `dragRegions` polygons, those are honored AS WELL via
        // the existing `DragRegionTracker` installed by
        // `applyDragRegions`. Chrome mode doesn't call that path
        // today (the feature-flag check in `applyDragRegions` is
        // keyed off `ShapedWindowController.featureFlagEnabled`,
        // not chrome-mode), so for the PR #7 scope the whole-chrome-
        // drag is the only drag surface. PR #8+ may wire explicit
        // drag regions back in if needed.
        newWindow.isMovableByWindowBackground = true

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
    }

    /// Install a `CAShapeLayer` mask on the content view's layer so
    /// AppKit actually clips the window backing to the chrome
    /// silhouette. PNG alpha on `ChromeHostView` is the visual
    /// content; this mask defines the window region. Without it, the
    /// cut-corner regions render opaque charcoal regardless of PNG
    /// alpha. Canonical recipe — see
    /// `docs/research/chrome-transparency-root-cause.md`.
    func installChromeSilhouetteMask(
        on contentView: NSView,
        size: NSSize,
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
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let mask = CAShapeLayer()
        mask.frame = rect
        mask.path = path
        mask.fillColor = NSColor.white.cgColor
        mask.fillRule = .nonZero
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
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
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
    @discardableResult
    /// Reverse `applyChromeSkin`: pull the app content back out of
    /// `InteriorView`, reconstruct the window as a regular titled
    /// window, and re-add the app subviews directly to the new
    /// content view.
    ///
    /// This is the exit path from chrome mode. It must be called
    /// whenever `reloadSkin` routes to a non-chrome skin while the
    /// current window is a `ShapedBorderlessWindow`; without it the
    /// window stays borderless permanently (no traffic lights, no
    /// resize chrome).
    ///
    /// Layout after teardown: app subviews had their original
    /// Auto Layout constraints removed when `applyChromeSkin` moved
    /// them into `InteriorView`. After reinsertion their frames are
    /// at their last-computed positions, which are already in (0,0)-
    /// relative bounds space — `InteriorView.bounds.origin` is always
    /// (0,0) regardless of its frame origin, so InteriorView-relative
    /// frames are identical to content-view-relative frames. The
    /// `applySkin` call that follows teardown triggers a layout pass
    /// that resolves any remaining positional drift.
    func teardownChromeSkin() {
        guard window is ShapedBorderlessWindow else { return }

        let previousResponder = window.firstResponder

        // Extract app subviews from InteriorView (or content view
        // directly on a first-entry-but-no-InteriorView state).
        let appSubviews = Self.extractAppSubviews(fromContentView: window.contentView)
        for view in appSubviews { view.removeFromSuperview() }

        // Re-enable resize (chrome mode locks min/max to nominal).
        window.styleMask.insert(.resizable)
        window.contentMinSize = .zero
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude)

        // Reconstruct as titled. Creates a fresh ShapedContentView,
        // migrates child windows and delegate, orders new window front.
        let newWindow = reconstructAsTitled(size: window.frame.size)
        guard let contentView = newWindow.contentView else { return }

        // Re-add app subviews directly to the new content view.
        for view in appSubviews { contentView.addSubview(view) }

        // Disable background-drag (chrome mode sets this; it's wrong
        // for the regular titled window which has a real title bar).
        newWindow.isMovableByWindowBackground = false

        // Restore first responder if the view survived into the new window.
        if let responder = previousResponder as? NSView,
           responder.window === newWindow {
            newWindow.makeFirstResponder(responder)
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
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true

        let freshContent = ShapedContentView(frame: NSRect(origin: .zero, size: size))
        freshContent.wantsLayer = true
        newWindow.contentView = freshContent

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
        return interior
    }

    /// Move every existing app-content subview of the content view
    /// into `InteriorView`. Views named in `excluding` (typically
    /// the newly-installed ChromeHostView + InteriorView) stay put.
    ///
    /// `subviews` is a snapshot of the content view's children taken
    /// BEFORE chrome/interior were installed, so the exclusion list
    /// is a safety net rather than the primary filter.
    func reparentAppContent(
        from subviews: [NSView],
        into interior: InteriorView,
        excluding: [NSView]
    ) {
        for view in subviews where !excluding.contains(view) {
            // `removeFromSuperview` unparents; `addSubview` reparents
            // under the new interior. Frames carry over; autoresizing
            // masks carry over. Constraint-based layouts re-anchor
            // against their new superview on the next layout pass.
            view.removeFromSuperview()
            interior.addSubview(view)
        }
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

    /// Find the real app-content subviews given an arbitrary content
    /// view. Handles both pre-v4 layouts (app subviews directly
    /// under the content view) and v4-in-v4 skin switches (app
    /// subviews nested inside a previous `InteriorView`). Without
    /// this unwrap, skin switches wrap the previous ChromeHostView +
    /// InteriorView INSIDE the new InteriorView on every invocation,
    /// stacking chrome-in-chrome visibly.
    static func extractAppSubviews(fromContentView contentView: NSView?) -> [NSView] {
        guard let root = contentView else { return [] }
        // Preferred path: if the current tree holds a previous
        // InteriorView, the real app content is inside it. Dig
        // one level in.
        for candidate in root.subviews {
            if let interior = candidate as? InteriorView {
                return interior.subviews
            }
        }
        // No previous chrome mode — root.subviews ARE the app
        // content (pre-v4 layout where app views were added
        // directly to ShapedContentView). Log so that a future
        // layout change inserting an intermediate container view
        // (e.g. focus-ring wrapper) is visible instead of silently
        // reparenting the wrong view level.
        NSLog("MainWindowController: extractAppSubviews — no InteriorView found in content tree; falling back to direct subviews (count: \(root.subviews.count))")
        return root.subviews
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
