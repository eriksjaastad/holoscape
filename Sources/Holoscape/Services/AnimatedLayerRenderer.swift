import QuartzCore

/// Per-kind renderer for an animated chrome layer. One conforming type
/// per `ChromeAnimationLayer.Kind` — `ParticleLayerRenderer` (PR #10,
/// Task 19.2), `LEDArrayLayerRenderer` + `SpriteAnimLayerRenderer`
/// (PR #11, Tasks 21.1 / 21.2), `ShaderPresetLayerRenderer` (PR #12,
/// Task 23.2). `ChromeHostView.installAnimatedLayers` (PR #3) carries
/// an array of these forward as a typed hook; the first conforming
/// type ships in PR #10.
///
/// The protocol's method surface is intentionally deferred to PR #10
/// so the first concrete renderer can pull the shape of the contract
/// from its actual render loop (Requirements 6 / 7 / 8 / 9) instead of
/// an invented-up-front abstraction.
@MainActor
protocol AnimatedLayerRenderer: AnyObject {
    // Method set defined in PR #10 (Task 19.2) when
    // `ParticleLayerRenderer` lands as the first conforming type.
}
