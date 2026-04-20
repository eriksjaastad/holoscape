import QuartzCore

/// Per-kind renderer for an animated chrome layer. One conforming type
/// per `ChromeAnimationLayer.Kind` — `ParticleLayerRenderer` (PR #10),
/// `LEDArrayLayerRenderer` + `SpriteAnimLayerRenderer` (PR #11),
/// `ShaderPresetLayerRenderer` (PR #12).
///
/// `ChromeHostView.installAnimatedLayers` drives the lifecycle:
/// instantiate per descriptor → `install(in:)` on the animated-layer
/// container → subscribe to `SharedAnimationClock` → tick forwards
/// `phaseSeconds` (from `CACurrentMediaTime()`). `pause`/`resume`
/// serve Reduce Motion + density `.minimal` (Req 15.3 / 15.5).
/// `uninstall` tears down when density transitions to `.off` or the
/// skin unloads.
///
/// Each renderer OWNS its `layer`; the host view installs the layer
/// into `animatedLayersContainer` and consults `z` for ordering.
@MainActor
protocol AnimatedLayerRenderer: AnyObject {
    /// Stable id from `ChromeAnimationLayer.id`. Used for
    /// `diffAnimatedLayers` id-keyed swap + banner text on validation
    /// failure.
    var id: String { get }

    /// Z-ordering relative to Base_Layer (which sits at implicit
    /// z = 0). Validator rejects `z <= 0` at load time.
    var z: Int { get }

    /// The renderer's root `CALayer`. Host view reads this to
    /// install/order/mask; subclasses paint into it directly.
    var layer: CALayer { get }

    /// Install the layer under `parent` with the correct z-order.
    /// Called once per renderer lifetime by `ChromeHostView`.
    func install(in parent: CALayer)

    /// Swap descriptor params in place (hot reload — PR #18).
    func updateParams(_ params: ChromeAnimationLayer.Params)

    /// Advance animation state to the given phase seconds.
    /// `SharedAnimationClock` delivers these at vsync or
    /// best-effort 60 fps. Implementations must be idempotent in
    /// the pause case (tick called with same phaseSeconds twice
    /// produces no visible drift).
    func tick(phaseSeconds: Double)

    /// Pause animation while keeping the layer in the tree
    /// (Req 15.3 Reduce Motion, Req 15.5 density `.minimal`).
    func pause()

    /// Resume animation after pause.
    func resume()

    /// Remove the layer from its superlayer and release any
    /// external resources (sprite sheets, Metal buffers, etc.).
    /// Called when density transitions to `.off` or skin unloads.
    func uninstall()
}
