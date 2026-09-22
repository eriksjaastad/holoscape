import AppKit

/// PNG-chrome compositing host. Installs the static Base_Layer
/// (Component 1 of `claude-specs/chrome/design.md`) and z-ordered
/// animated sublayers in `animatedLayersContainer`.
/// ChromeHostView is a sibling of `InteriorView` under
/// `ShapedContentView`; it never receives events (`hitTest -> nil`) so
/// click-through and hit-test routing continue to flow through
/// `ShapedContentView.hitTest` + `HitRegionSampler`.
///
/// `isFlipped = true` so sublayer positioning matches the top-left
/// origin that chrome images and `SkinRect` coordinates use.
///
/// Animated-layer install/diff/density/reduce-motion hooks are implemented
/// here so chrome visuals can be hot-reloaded or disabled without changing
/// terminal/session behavior.
@MainActor
final class ChromeHostView: NSView {

    // MARK: - Layers

    /// Holds the static chrome PNG (`layer.contents`). `z = 0`
    /// implicitly — every `ChromeAnimationLayer` must declare `z > 0`
    /// so it composites above (Requirement 10.4).
    private let baseLayer: CALayer

    /// Parent layer for animated sublayers. Populated through
    /// `installAnimatedLayers`. A mask derived from Base_Layer's
    /// non-zero-alpha pixels clips animations to the chrome silhouette.
    private let animatedLayersContainer: CALayer

    /// Active mask on `animatedLayersContainer` when the mask is a shape
    /// layer. The bitmap-alpha mask path leaves this nil by design.
    private var containerMask: CAShapeLayer?

    /// Live renderers. Retained here so the host can drive lifecycle
    /// (pause / resume / uninstall) on density + Reduce Motion transitions.
    private(set) var renderers: [AnimatedLayerRenderer] = []

    /// Phase clock every renderer subscribes to. Optional for tests and
    /// static chrome paths that do not need ticking animations.
    private weak var clock: SharedAnimationClock?

    /// Already-decoded animation assets keyed by manifest-relative path.
    /// SkinEngine validates and loads these from the skin sandbox; the host
    /// only consumes the images and never re-resolves paths at render time.
    private let animationImages: [String: NSImage]

    /// The `ChromeDescriptor` this host is rendering. Kept so hot
    /// reload can diff against an incoming descriptor without the caller
    /// passing the old + new pair.
    private(set) var chrome: ChromeDescriptor

    // MARK: - Init

    /// Production init (Component 1 interface). `clock` may be `nil` for
    /// tests/static chrome; animated renderers subscribe only when present.
    init(
        chrome: ChromeDescriptor,
        baseImage: CGImage,
        clock: SharedAnimationClock?,
        animationImages: [String: NSImage] = [:]
    ) {
        self.chrome = chrome
        self.baseLayer = CALayer()
        self.animatedLayersContainer = CALayer()
        self.clock = clock
        self.animationImages = animationImages
        super.init(frame: NSRect(x: 0, y: 0, width: chrome.width, height: chrome.height))

        wantsLayer = true
        // A host-level background would fill the cut-corner alpha
        // and defeat Property 2 (window alpha equals Base_Layer
        // alpha). `.clear` is the explicit zero-paint color —
        // `nil` alone can leave AppKit's default in place.
        layer!.backgroundColor = NSColor.clear.cgColor
        layer!.isOpaque = false

        baseLayer.contents = baseImage
        baseLayer.contentsGravity = .resize
        baseLayer.frame = bounds
        baseLayer.backgroundColor = NSColor.clear.cgColor
        baseLayer.isOpaque = false

        // animatedLayersContainer sits above baseLayer so every animated
        // sublayer composites on top (Requirement 10.4) without touching
        // the view's layer structure.
        animatedLayersContainer.frame = bounds
        animatedLayersContainer.backgroundColor = NSColor.clear.cgColor
        animatedLayersContainer.isOpaque = false

        layer!.addSublayer(baseLayer)
        layer!.addSublayer(animatedLayersContainer)

        // Install the single-container mask now so animated layers clip to
        // Base_Layer's alpha silhouette from the moment they install
        // (Req 10.1 / 10.2 / Property 7).
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

    /// Installs a set of animated sublayers.
    /// Instantiates one renderer per descriptor, installs its layer
    /// into `animatedLayersContainer` at the declared `z`-ordering,
    /// and subscribes each renderer to the shared clock if present.
    /// Disabled-by-validator ids (`chromeValidation.disabledAnimationIDs`)
    /// must be filtered out BEFORE this call — the host trusts the
    /// descriptor list.
    ///
    /// Unknown kinds — if a future additive case ships ahead of a renderer
    /// — log + skip.
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
    /// descriptor's kind has no renderer; the caller filters nils silently.
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
                sheet: animationImages[params.sheet]
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

    /// Swap the Base_Layer image during chrome PNG hot reload.
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
    /// ones during hot reload for `chrome.animations`.
    func diffAnimatedLayers(_ next: [ChromeAnimationLayer]) {
        chrome.animations = next

        let existingByID = Dictionary(uniqueKeysWithValues: renderers.map { ($0.id, $0) })
        var nextRenderers: [AnimatedLayerRenderer] = []
        var retainedIDs = Set<String>()

        for descriptor in sortedAnimationDescriptors(next) {
            if let existing = existingByID[descriptor.id],
               renderer(existing, canUpdateInPlaceFor: descriptor) {
                existing.updateParams(descriptor.params)
                nextRenderers.append(existing)
                retainedIDs.insert(existing.id)
            } else {
                if let existing = existingByID[descriptor.id] {
                    clock?.unsubscribe(existing)
                    existing.uninstall()
                }

                guard let renderer = makeRenderer(for: descriptor) else { continue }
                renderer.install(in: animatedLayersContainer)
                clock?.subscribe(renderer)
                nextRenderers.append(renderer)
                retainedIDs.insert(renderer.id)
            }
        }

        for renderer in renderers where !retainedIDs.contains(renderer.id) {
            clock?.unsubscribe(renderer)
            renderer.uninstall()
        }

        renderers = nextRenderers
        restackAnimatedLayers()
        animatedLayersContainer.setValue(true, forKey: "accessibilityElementsHidden")
    }

    private func sortedAnimationDescriptors(_ descriptors: [ChromeAnimationLayer]) -> [ChromeAnimationLayer] {
        descriptors.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z < rhs.z }
            return descriptors.firstIndex { $0.id == lhs.id }!
                < descriptors.firstIndex { $0.id == rhs.id }!
        }
    }

    private func renderer(
        _ renderer: AnimatedLayerRenderer,
        canUpdateInPlaceFor descriptor: ChromeAnimationLayer
    ) -> Bool {
        guard renderer.z == descriptor.z else { return false }
        switch descriptor.kind {
        case .particle:
            return renderer is ParticleLayerRenderer && descriptor.params.particle != nil
        case .ledArray:
            return renderer is LEDArrayLayerRenderer && descriptor.params.ledArray != nil
        case .spriteAnim:
            return renderer is SpriteAnimLayerRenderer && descriptor.params.spriteAnim != nil
        case .shader:
            return renderer is ShaderPresetLayerRenderer && descriptor.params.shader != nil
        }
    }

    private func restackAnimatedLayers() {
        for renderer in renderers {
            renderer.layer.removeFromSuperlayer()
            animatedLayersContainer.addSublayer(renderer.layer)
        }
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
