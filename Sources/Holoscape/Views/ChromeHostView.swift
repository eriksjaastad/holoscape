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

    /// Live renderers. Array is empty in PR #3; first conforming type
    /// ships in PR #10 (`ParticleLayerRenderer`).
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

    /// Installs a set of animated sublayers. PR #3 no-op; PR #10+ fills
    /// this in (particle / LED / sprite / shader renderers). Exposed
    /// now so later PRs change method internals without touching the
    /// view's public surface.
    func installAnimatedLayers(_ descriptors: [ChromeAnimationLayer]) {
        // TODO PRs #10–#12 (task groups 19, 21, 23): instantiate one
        // conforming renderer per descriptor, install renderer.layer
        // into `animatedLayersContainer`, subscribe to `clock`,
        // honor `z` ordering.
    }

    /// Swap the Base_Layer image (hot reload of chrome PNG, PR #18).
    /// Rebuilds `containerMask` from the new alpha silhouette.
    func updateBaseImage(_ image: CGImage) {
        baseLayer.contents = image
        // TODO PR #13 (task 25.1): rebuild `containerMask` from the
        // new image's non-zero-alpha pixels.
    }

    /// Diff animated layers by `id` and swap params in place for
    /// anything that already exists; install new ids; remove missing
    /// ones (PR #18 hot reload for `chrome.animations`).
    func diffAnimatedLayers(_ next: [ChromeAnimationLayer]) {
        // TODO PR #18 (task group 35): id-keyed diff against current
        // `renderers`.
    }

    /// Density mode hook. `.off` tears down every renderer;
    /// `.minimal` pauses the clock; `.full` resumes (Requirements
    /// 15.4–15.9).
    func setDensityMode(_ mode: DensityModeManager.Mode) {
        // TODO PR #13 (task 25.2): tear-down / pause / resume paths.
    }

    /// Reduce Motion hook — pause the clock but keep every layer in
    /// the tree so the frame holds (Requirement 15.3, Property 10).
    func freezeForReduceMotion() {
        // TODO PR #13 (task 25.3).
    }

    func resumeFromReduceMotion() {
        // TODO PR #13 (task 25.3).
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
