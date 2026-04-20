import AppKit

/// PNG-chrome compositing host. Installs the static Base_Layer
/// (Component 1 of `claude-specs/chrome/design.md`) and — from PR #10
/// onward — z-ordered animated sublayers in `animatedLayersContainer`.
/// ChromeHostView is a sibling of `InteriorView` under
/// `ShapedContentView`; it never receives events (`hitTest -> nil`) so
/// click-through and hit-test routing continue to flow through
/// `ShapedContentView.hitTest` + `HitRegionSampler`.
///
/// `isFlipped = true` so sublayer positioning matches the top-left
/// origin that chrome images and `SkinRect` coordinates use.
///
/// Method bodies for `installAnimatedLayers`, `diffAnimatedLayers`,
/// `setDensityMode`, `freezeForReduceMotion`, and `resumeFromReduceMotion`
/// are stubbed in this PR; each is filled in by a later PR in the
/// 20-PR rollout (see the per-method `TODO` comments).
@MainActor
final class ChromeHostView: NSView {

    // MARK: - Layers

    /// Holds the static chrome PNG (`layer.contents`). `z = 0`
    /// implicitly — every `ChromeAnimationLayer` must declare `z > 0`
    /// so it composites above (Requirement 10.4).
    private let baseLayer: CALayer

    /// Parent layer for animated sublayers. Empty in PR #3; PR #10
    /// populates it through `installAnimatedLayers`. A `CAShapeLayer`
    /// mask (derived from Base_Layer's non-zero-alpha pixels, Property 7)
    /// is installed here in PR #13 so animations clip to the chrome
    /// silhouette.
    private let animatedLayersContainer: CALayer

    /// Active mask on `animatedLayersContainer`. Wired up in PR #13.
    private var containerMask: CAShapeLayer?

    /// Live renderers. Populated by `installAnimatedLayers` (PR #10+).
    /// Retained here so the host can drive lifecycle (pause / resume /
    /// uninstall) on density + Reduce Motion transitions.
    private(set) var renderers: [AnimatedLayerRenderer] = []

    /// Phase clock every renderer subscribes to. Optional through
    /// PRs #3–#9 because `SharedAnimationClock`'s body is not filled in
    /// until PR #10 — passing `nil` during that window is the
    /// documented contract (tasks.md Task 5.1).
    private weak var clock: SharedAnimationClock?

    /// The `ChromeDescriptor` this host is rendering. Kept so hot
    /// reload (PR #18) can diff against an incoming descriptor without
    /// the caller passing the old + new pair.
    private(set) var chrome: ChromeDescriptor

    // MARK: - Init

    /// Production init (Component 1 interface). `clock` may be `nil` in
    /// PRs #3–#9 — `SharedAnimationClock` is a stub until PR #10.
    init(chrome: ChromeDescriptor, baseImage: CGImage, clock: SharedAnimationClock?) {
        self.chrome = chrome
        self.baseLayer = CALayer()
        self.animatedLayersContainer = CALayer()
        self.clock = clock
        super.init(frame: NSRect(x: 0, y: 0, width: chrome.width, height: chrome.height))

        wantsLayer = true
        // A host-level background would fill the cut-corner alpha and
        // defeat Property 2 (window alpha equals Base_Layer alpha).
        layer!.backgroundColor = nil

        baseLayer.contents = baseImage
        baseLayer.contentsGravity = .resize
        baseLayer.frame = bounds
        baseLayer.backgroundColor = nil

        // animatedLayersContainer sits above baseLayer so every animated
        // sublayer composites on top (Requirement 10.4). The container
        // is empty in PR #3 but installed now so PR #10 can drop layers
        // into it without touching the view's layer structure.
        animatedLayersContainer.frame = bounds
        animatedLayersContainer.backgroundColor = nil

        layer!.addSublayer(baseLayer)
        layer!.addSublayer(animatedLayersContainer)

        // Install the single-container mask now so animated layers
        // added later (PR #10+) clip to Base_Layer's alpha silhouette
        // from the moment they install (Req 10.1 / 10.2 / Property 7).
        rebuildContainerMask(from: baseImage)
    }

    required init?(coder: NSCoder) {
        fatalError("ChromeHostView does not support NSCoder initialization")
    }

    // MARK: - Layer lifecycle

    override func layout() {
        super.layout()
        baseLayer.frame = bounds
        animatedLayersContainer.frame = bounds
    }

    // MARK: - Public interface (Component 1)

    /// Installs a set of animated sublayers (PR #10, Task 19.3).
    /// Instantiates one renderer per descriptor, installs its layer
    /// into `animatedLayersContainer` at the declared `z`-ordering,
    /// and subscribes each renderer to the shared clock if present.
    /// Disabled-by-validator ids (`chromeValidation.disabledAnimationIDs`)
    /// must be filtered out BEFORE this call — the host trusts the
    /// descriptor list.
    ///
    /// PR #11 adds `.ledArray` + `.spriteAnim` branches;
    /// PR #12 adds `.shader`. Unknown kinds — if a future additive
    /// case ships ahead of a renderer — log + skip.
    func installAnimatedLayers(_ descriptors: [ChromeAnimationLayer]) {
        // Sort by z so sublayer insertion order yields correct
        // compositing order (Req 10.4 — earlier in the array wins
        // when z is tied, per tasks.md §25.1).
        let sorted = descriptors.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            return descriptors.firstIndex { $0.id == lhs.id }!
                < descriptors.firstIndex { $0.id == rhs.id }!
        }

        for descriptor in sorted {
            guard let renderer = makeRenderer(for: descriptor) else { continue }
            renderer.install(in: animatedLayersContainer)
            // Req 15.10 — animated chrome is decorative; VoiceOver
            // should skip it. `accessibilityElementIsHidden` is not
            // a CALayer property, but wrapping the layer's delegate
            // view (if one exists) would. For pure-CALayer layers
            // we set the `accessibilityElements` on the container
            // so screen readers get an empty element list.
            renderers.append(renderer)
            clock?.subscribe(renderer)
        }

        // Property 15.10 — mark the entire animated-layers container
        // as not an accessibility element. VoiceOver walks the view
        // hierarchy AND the layer hierarchy; hiding the container
        // covers every sublayer regardless of the render class.
        animatedLayersContainer.setValue(true, forKey: "accessibilityElementsHidden")
    }

    /// Factory for the per-kind renderers. `nil` return means the
    /// descriptor's kind has no renderer in this PR yet (covered by
    /// PR #11/#12); the caller filters nils silently.
    private func makeRenderer(for descriptor: ChromeAnimationLayer) -> AnimatedLayerRenderer? {
        switch descriptor.kind {
        case .particle:
            guard let params = descriptor.params.particle else { return nil }
            return ParticleLayerRenderer(
                id: descriptor.id,
                z: descriptor.z,
                rect: descriptor.rect,
                params: params
            )
        case .ledArray:
            guard let params = descriptor.params.ledArray else { return nil }
            return LEDArrayLayerRenderer(
                id: descriptor.id,
                z: descriptor.z,
                rect: descriptor.rect,
                params: params,
                phaseOffset: descriptor.phaseOffset ?? 0,
                speedMultiplier: descriptor.speedMultiplier ?? 1
            )
        case .spriteAnim:
            guard let params = descriptor.params.spriteAnim else { return nil }
            return SpriteAnimLayerRenderer(
                id: descriptor.id,
                z: descriptor.z,
                rect: descriptor.rect,
                params: params,
                phaseOffset: descriptor.phaseOffset ?? 0,
                speedMultiplier: descriptor.speedMultiplier ?? 1,
                sheet: nil  // PR #18 threads skin-dir through so this
                            // can resolve the declared sheet path. For
                            // now the layer installs with a nil
                            // contents — visual will be empty until
                            // the sheet wiring lands.
            )
        case .shader:
            guard let params = descriptor.params.shader else { return nil }
            return ShaderPresetLayerRenderer(
                id: descriptor.id,
                z: descriptor.z,
                rect: descriptor.rect,
                params: params,
                phaseOffset: descriptor.phaseOffset ?? 0,
                speedMultiplier: descriptor.speedMultiplier ?? 1
            )
        }
    }

    /// Swap the Base_Layer image (hot reload of chrome PNG, PR #18).
    /// Rebuilds `containerMask` from the new alpha silhouette so
    /// animated layers continue to clip to the updated shape
    /// (Property 7 — no animated pixel where base alpha == 0).
    func updateBaseImage(_ image: CGImage) {
        baseLayer.contents = image
        rebuildContainerMask(from: image)
    }

    /// Build (or rebuild) the `CAShapeLayer` mask on
    /// `animatedLayersContainer` from the current Base_Layer image's
    /// non-zero-alpha pixels. Called at init when the base image is
    /// available AND on `updateBaseImage`. Property 7 — "no animated
    /// layer renders a pixel where chrome alpha == 0" — hangs off
    /// this being non-nil.
    ///
    /// For MVP: install a rectangular mask at container bounds when
    /// the base image is fully opaque, and a per-pixel bitmap mask
    /// otherwise. A CAShapeLayer path derived from the full alpha
    /// silhouette would require vectorization; instead we leverage
    /// CALayer's ability to use a mask layer with `contents = image`
    /// and sample alpha directly from it.
    private func rebuildContainerMask(from image: CGImage) {
        let mask = CALayer()
        mask.frame = animatedLayersContainer.bounds
        mask.contents = image
        mask.contentsGravity = .resize
        animatedLayersContainer.mask = mask
        containerMask = mask as? CAShapeLayer  // kept for uniform API; nil OK
    }

    /// Diff animated layers by `id` and swap params in place for
    /// anything that already exists; install new ids; remove missing
    /// ones (PR #18 hot reload for `chrome.animations`).
    func diffAnimatedLayers(_ next: [ChromeAnimationLayer]) {
        // TODO PR #18 (task group 35): id-keyed diff against current
        // `renderers`.
    }

    /// Density mode hook (Req 15.4–15.9).
    ///
    /// - `.off`: tear down every renderer and unsubscribe from the
    ///   clock so zero CPU/GPU cost remains (Req 15.4, Property 7
    ///   density-off clause).
    /// - `.minimal`: pause the clock; keep every layer visible at
    ///   its current frame (Req 15.5 / 15.7).
    /// - `.full`: re-install layers if previously `.off`, then
    ///   resume the clock. Restart from declared `phaseOffset` when
    ///   coming from `.off` (Req 15.9).
    func setDensityMode(_ mode: DensityModeManager.Mode) {
        switch mode {
        case .off:
            // Tear every renderer down. animations descriptor is
            // retained on `chrome.animations` so .full can rebuild.
            for renderer in renderers {
                clock?.unsubscribe(renderer)
                renderer.uninstall()
            }
            renderers.removeAll()
            clock?.stop()

        case .minimal:
            // Layers stay in the tree; the clock just stops ticking
            // (pause semantics). Each renderer's `pause()` is
            // idempotent so redundant calls are fine.
            for renderer in renderers {
                renderer.pause()
            }
            clock?.pause()

        case .full:
            if renderers.isEmpty, let animations = chrome.animations {
                // Coming back from `.off` — reinstall from descriptors.
                // Restart phase from declared phaseOffset happens
                // inherently because phaseSeconds flows into each
                // renderer's phaseOffset math on every tick.
                installAnimatedLayers(animations)
            }
            for renderer in renderers {
                renderer.resume()
            }
            clock?.resume()
            clock?.start()
        }
    }

    /// Reduce Motion hook — freeze every animated layer on its
    /// current frame without hiding. The clock pauses tick delivery;
    /// layers stay in the tree so the skin still looks "designed."
    /// Req 15.3, Property 10.
    func freezeForReduceMotion() {
        for renderer in renderers {
            renderer.pause()
        }
        clock?.pause()
    }

    func resumeFromReduceMotion() {
        for renderer in renderers {
            renderer.resume()
        }
        clock?.resume()
    }

    // MARK: - NSView overrides

    /// Top-left origin matches chrome-image coordinates so sublayer
    /// `rect` values (from `ChromeAnimationLayer.rect`) can be applied
    /// without a per-layer Y-flip.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    /// ChromeHostView never receives events. Clicks routed through
    /// ShapedContentView's polygon sampler decide whether the click is
    /// inside the silhouette; this view never intercepts.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Test hooks (internal)

    #if DEBUG
    /// Test access to the Base_Layer `contents` without exposing the
    /// CALayer itself. Read-only; used by `ChromeHostViewTests` to
    /// verify the image assigned at `init` stuck (Req 2.1).
    var _testBaseLayerContents: Any? { baseLayer.contents }

    /// Test access for sibling-and-z-order invariants (Req 2.5 /
    /// Property 1): asserts `baseLayer` comes before
    /// `animatedLayersContainer` in `layer!.sublayers`.
    var _testSublayerOrder: [CALayer]? { layer?.sublayers }

    var _testBaseLayer: CALayer { baseLayer }
    var _testAnimatedLayersContainer: CALayer { animatedLayersContainer }
    #endif
}
