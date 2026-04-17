import AppKit
import QuartzCore

/// Translates resolved surface descriptors into Core Animation instances and
/// drives the per-frame display link that signals "chrome is animating."
///
/// The engine owns a single `CADisplayLink` that exists only while there are
/// active animations. When all animations complete, the link is invalidated
/// so idle chrome draws zero frames per second (see Property 8 in the spec).
///
/// Animated properties (fill.color, corner.radius, border) each get their own
/// `CABasicAnimation` (or `CASpringAnimation` for spring curves). Per-property
/// curves from `ResolvedAnimation` override the fallback `default` curve.
///
/// `suppressAll()` is called by `DensityModeManager` when entering Minimal or
/// Off density modes — it strips every active animation from its layer. The
/// model values were already set to the final state when the animations were
/// queued, so the visible state jumps instantly to the destination.
@MainActor
final class AnimationEngine {

    // MARK: - Identity

    /// Keys an active animation by surface and the property being animated.
    /// Allows concurrent per-property animations on the same surface
    /// (e.g., fill at 350ms ease-out + corner at 150ms linear).
    struct AnimationID: Hashable {
        let surfaceKey: SurfaceKey
        let property: Property

        enum Property: String, Hashable {
            case fill           // layer.backgroundColor (solid-color fills only)
            case corner         // layer.cornerRadius (uniform corners only)
            case borderWidth    // layer.borderWidth
            case borderColor    // layer.borderColor
        }
    }

    /// Per-instance record for an in-flight animation. `token` is a strictly
    /// increasing counter assigned at `animate(…)` time — the completion
    /// callback uses it to confirm it still owns the slot before draining
    /// `activeAnimations`. Without that check, a cancelled predecessor's
    /// callback could remove a successor's tracking entry and stop the
    /// display link while an animation is still visually running.
    struct AnimationState {
        weak var layer: CALayer?
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let token: UInt64
    }

    // MARK: - Public state

    /// Tracked per-animation metadata. Populated by `animateSurface`, drained
    /// by `animationDidStop` delegate callbacks or `suppressAll()`.
    private(set) var activeAnimations: [AnimationID: AnimationState] = [:]

    /// Non-nil iff the display link is currently running. Reset to nil
    /// whenever `activeAnimations` drains to empty.
    private(set) var displayLink: CADisplayLink?

    /// Host view used to create the display link (NSView.displayLink requires
    /// a screen to derive refresh rate). When nil, animations still run via
    /// Core Animation's own clock; the display-link lifecycle observable is
    /// just never entered.
    weak var hostView: NSView?

    /// Density gate. When `shouldAnimate()` returns false (Minimal or Off
    /// modes), curves are nil-ed out at animate-entry so every per-property
    /// method hits its instant-application path. When nil, animation is
    /// assumed allowed — matches the pre-DensityModeManager default.
    weak var densityModeManager: DensityModeManager?

    /// Monotonically increasing counter for AnimationState tokens.
    /// UInt64 wrap would require ~18 quintillion animations in a session.
    private var tokenCounter: UInt64 = 0

    // MARK: - Init

    init(hostView: NSView? = nil, densityModeManager: DensityModeManager? = nil) {
        self.hostView = hostView
        self.densityModeManager = densityModeManager
    }

    // MARK: - Public API

    /// Transition `layer` to match `resolved`, using the supplied `animation`
    /// curves per property. Properties without a curve (neither per-property
    /// nor `default`) are applied instantly.
    ///
    /// When `densityModeManager?.shouldAnimate() == false`, all curves are
    /// ignored — every property takes its instant-application branch. This
    /// enforces the spec's "state changes apply instantly" contract for
    /// Minimal and Off density modes (Requirement 13.5).
    func animateSurface(
        _ key: SurfaceKey,
        to resolved: SkinContext.ResolvedSurface,
        on layer: CALayer,
        with animation: SkinContext.ResolvedAnimation?
    ) {
        let animationAllowed = densityModeManager?.shouldAnimate() ?? true
        let effective = animationAllowed ? animation : nil

        let defaultCurve = effective?.default
        let fillCurve = effective?.fill ?? defaultCurve
        let cornerCurve = effective?.corner ?? defaultCurve
        let borderCurve = defaultCurve

        applyFill(to: layer, for: key, resolved: resolved, curve: fillCurve)
        applyCorner(to: layer, for: key, resolved: resolved, curve: cornerCurve)
        applyBorder(to: layer, for: key, resolved: resolved, curve: borderCurve)

        startDisplayLinkIfNeeded()
    }

    /// Create the display link if there are any active animations and none
    /// currently exists. No-op if already running or no host view available.
    func startDisplayLinkIfNeeded() {
        guard displayLink == nil, !activeAnimations.isEmpty else { return }
        guard let hostView else { return }
        let link = hostView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Invalidate the display link and nil it when no animations remain.
    func stopDisplayLinkIfIdle() {
        guard activeAnimations.isEmpty else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Remove every active animation from its layer. Model values were set
    /// to the target when queued, so the visible state jumps to the final
    /// value. Used by DensityModeManager to enforce "instant state changes"
    /// in Minimal and Off density modes.
    func suppressAll() {
        for (id, state) in activeAnimations {
            state.layer?.removeAnimation(forKey: id.property.rawValue)
        }
        activeAnimations.removeAll()
        stopDisplayLinkIfIdle()
    }

    // MARK: - Per-property animation

    private func applyFill(
        to layer: CALayer,
        for key: SurfaceKey,
        resolved: SkinContext.ResolvedSurface,
        curve: SkinContext.ResolvedCurve?
    ) {
        // Only solid-color fills animate; image and gradient fills jump instantly.
        guard case .color(let color) = resolved.fill else { return }
        let targetCG = color.cgColor

        guard let curve else {
            layer.backgroundColor = targetCG
            return
        }

        let fromCG = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        animate(
            id: AnimationID(surfaceKey: key, property: .fill),
            layer: layer,
            keyPath: "backgroundColor",
            fromValue: fromCG as Any,
            toValue: targetCG,
            curve: curve
        )
        layer.backgroundColor = targetCG
    }

    private func applyCorner(
        to layer: CALayer,
        for key: SurfaceKey,
        resolved: SkinContext.ResolvedSurface,
        curve: SkinContext.ResolvedCurve?
    ) {
        // Only uniform corners animate; asymmetric corners are handled via
        // mask layer by SkinContext and don't have a single cornerRadius.
        guard case .uniform(let radius) = resolved.corner else { return }

        guard let curve else {
            layer.cornerRadius = radius
            return
        }

        let fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
        animate(
            id: AnimationID(surfaceKey: key, property: .corner),
            layer: layer,
            keyPath: "cornerRadius",
            fromValue: fromValue,
            toValue: radius,
            curve: curve
        )
        layer.cornerRadius = radius
    }

    private func applyBorder(
        to layer: CALayer,
        for key: SurfaceKey,
        resolved: SkinContext.ResolvedSurface,
        curve: SkinContext.ResolvedCurve?
    ) {
        guard let border = resolved.border else {
            // No border in target state. If animating, fade width to zero;
            // otherwise strip instantly. Color can't animate to "nil" — we
            // hold the current color through the width fade, then drop it
            // at the model-value write below.
            if let curve, layer.borderWidth > 0 {
                let from = layer.presentation()?.borderWidth ?? layer.borderWidth
                animate(
                    id: AnimationID(surfaceKey: key, property: .borderWidth),
                    layer: layer,
                    keyPath: "borderWidth",
                    fromValue: from,
                    toValue: CGFloat(0),
                    curve: curve
                )
            }
            layer.borderWidth = 0
            layer.borderColor = nil
            return
        }

        let targetColor = border.color.cgColor
        let targetWidth = border.width

        guard let curve else {
            layer.borderColor = targetColor
            layer.borderWidth = targetWidth
            return
        }

        let fromWidth = layer.presentation()?.borderWidth ?? layer.borderWidth
        animate(
            id: AnimationID(surfaceKey: key, property: .borderWidth),
            layer: layer,
            keyPath: "borderWidth",
            fromValue: fromWidth,
            toValue: targetWidth,
            curve: curve
        )

        // borderColor requires its own CABasicAnimation — explicit animations
        // on one key path do not carry implicit animations for other keys.
        if let fromColor = layer.presentation()?.borderColor ?? layer.borderColor {
            animate(
                id: AnimationID(surfaceKey: key, property: .borderColor),
                layer: layer,
                keyPath: "borderColor",
                fromValue: fromColor,
                toValue: targetColor,
                curve: curve
            )
        }
        layer.borderColor = targetColor
        layer.borderWidth = targetWidth
    }

    private func animate(
        id: AnimationID,
        layer: CALayer,
        keyPath: String,
        fromValue: Any,
        toValue: Any,
        curve: SkinContext.ResolvedCurve
    ) {
        let animation: CAAnimation
        if curve.isSpring {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.fromValue = fromValue
            spring.toValue = toValue
            spring.damping = 10
            spring.stiffness = 100
            spring.mass = 1
            spring.initialVelocity = 0
            // Spring duration is computed by Core Animation from the physics
            // params; we override with the descriptor's duration as a ceiling.
            spring.duration = curve.duration
            animation = spring
        } else {
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.fromValue = fromValue
            basic.toValue = toValue
            basic.duration = curve.duration
            basic.timingFunction = CAMediaTimingFunction(name: curve.timingFunction)
            animation = basic
        }
        animation.isRemovedOnCompletion = true
        // No fillMode=.forwards: model value is set explicitly below so the
        // final state persists after removal. fillMode would be inert anyway
        // since isRemovedOnCompletion strips the animation the instant it
        // completes.

        tokenCounter += 1
        let token = tokenCounter

        let delegate = AnimationCompletionDelegate { [weak self] finished in
            MainActor.assumeIsolated {
                self?.animationDidComplete(id: id, token: token, finished: finished)
            }
        }
        animation.delegate = delegate

        activeAnimations[id] = AnimationState(
            layer: layer,
            startTime: CACurrentMediaTime(),
            duration: curve.duration,
            token: token
        )
        layer.add(animation, forKey: id.property.rawValue)
    }

    /// Drain the tracking entry for `id` only if it still holds `token`.
    /// A cancelled-then-re-queued animation uses a fresh token; the old
    /// callback's stale token will mismatch and this becomes a no-op,
    /// preserving the successor's tracking state.
    ///
    /// Internal so unit tests can drive this path directly — CAAnimation
    /// delivery timing on non-rendered layers is implementation-defined,
    /// so real-delegate tests would be flaky.
    func animationDidComplete(id: AnimationID, token: UInt64, finished: Bool) {
        guard activeAnimations[id]?.token == token else { return }
        activeAnimations.removeValue(forKey: id)
        stopDisplayLinkIfIdle()
    }

    // MARK: - Display link tick

    /// The display link's sole job is to be observable — its existence
    /// signals "chrome is actively animating." Core Animation drives the
    /// actual per-frame redraw; we don't do any work here.
    @objc private func tick(_ link: CADisplayLink) {
        // Intentionally empty.
    }
}

// MARK: - CAAnimation completion delegate

private final class AnimationCompletionDelegate: NSObject, CAAnimationDelegate {
    private let onComplete: (Bool) -> Void

    init(_ onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        onComplete(flag)
    }
}
