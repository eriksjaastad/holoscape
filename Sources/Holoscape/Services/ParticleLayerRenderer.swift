import AppKit
import QuartzCore

/// `CAEmitterLayer`-backed renderer for `kind == .particle`
/// animations (PR #10, Task 19.2). Maps every `ParticleParams`
/// field to the corresponding `CAEmitterCell` property at install
/// time so Core Animation drives the emitter autonomously — the
/// per-frame `tick` is a no-op unless phase-specific behavior
/// (bursts, patterns) lands in a later PR.
///
/// When `params.image == nil` the renderer synthesizes a soft-dot
/// image (procedurally-generated, Req 6.3) so skins can declare a
/// particle layer without shipping sprite art.
///
/// `params.blendMode.additive / .screen` installs the matching
/// `compositingFilter` on the emitter cell (Req 6.4).
@MainActor
final class ParticleLayerRenderer: AnimatedLayerRenderer {

    let id: String
    let z: Int

    /// The root `CAEmitterLayer`. Public property required by the
    /// protocol; external callers should treat it as read-only
    /// (install path mutates, but params go through `updateParams`).
    let layer: CALayer

    private let emitterLayer: CAEmitterLayer
    private var emitterCell: CAEmitterCell
    private let rect: SkinRect
    private var params: ParticleParams
    private var isPaused: Bool = false

    init(id: String, z: Int, rect: SkinRect, params: ParticleParams) {
        self.id = id
        self.z = z
        self.rect = rect
        self.params = params

        let emitter = CAEmitterLayer()
        let cell = CAEmitterCell()
        Self.applyParams(params, to: cell)
        emitter.emitterCells = [cell]
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .volume
        emitter.renderMode = .unordered
        emitter.zPosition = CGFloat(z)

        self.emitterLayer = emitter
        self.emitterCell = cell
        self.layer = emitter
    }

    // MARK: - Install / uninstall

    func install(in parent: CALayer) {
        // Position + size in parent coordinates. `rect` is in chrome-
        // image top-left coords — caller (ChromeHostView) is flipped,
        // so frame.origin maps directly.
        emitterLayer.frame = NSRect(
            x: rect.x, y: rect.y,
            width: rect.width, height: rect.height
        )
        emitterLayer.emitterPosition = CGPoint(
            x: rect.width / 2,
            y: rect.height / 2
        )
        emitterLayer.emitterSize = CGSize(width: rect.width, height: rect.height)
        parent.addSublayer(emitterLayer)
    }

    func uninstall() {
        emitterLayer.emitterCells = nil
        emitterLayer.removeFromSuperlayer()
    }

    // MARK: - Params

    func updateParams(_ next: ChromeAnimationLayer.Params) {
        guard let nextParticle = next.particle else { return }
        self.params = nextParticle
        Self.applyParams(nextParticle, to: emitterCell)
        // Re-seat the cell so Core Animation picks up the changes.
        emitterLayer.emitterCells = [emitterCell]
    }

    // MARK: - Tick (no-op for autonomous Core Animation emitter)

    func tick(phaseSeconds: Double) {
        // CAEmitterLayer animates autonomously once `birthRate > 0`.
        // The tick hook stays here for future phase-bound behaviors
        // (burst triggers, sync-to-audio) but is a no-op in MVP.
    }

    // MARK: - Pause / resume

    /// Reduce Motion (Req 15.3) + density `.minimal` (Req 15.5) freeze
    /// the emitter by setting `birthRate = 0` so no new particles
    /// spawn. Existing particles continue their lifetime. `resume()`
    /// restores the declared birth rate.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        emitterCell.birthRate = 0
        emitterLayer.emitterCells = [emitterCell]
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        emitterCell.birthRate = Float(params.birthRate)
        emitterLayer.emitterCells = [emitterCell]
    }

    // MARK: - Params application

    private static func applyParams(_ p: ParticleParams, to cell: CAEmitterCell) {
        cell.birthRate = Float(p.birthRate)
        cell.lifetime = Float(p.lifetime)
        cell.lifetimeRange = Float(p.lifetimeRange ?? 0)
        cell.velocity = CGFloat(p.velocity)
        cell.velocityRange = CGFloat(p.velocityRange ?? 0)
        cell.emissionLongitude = CGFloat(p.emissionAngle)
        cell.emissionRange = CGFloat(p.emissionRange)
        cell.scale = CGFloat(p.scale)
        cell.scaleRange = CGFloat(p.scaleRange ?? 0)

        if let color = NSColor(hex: p.color) {
            cell.color = color.cgColor
        }

        cell.contents = resolveImage(for: p)?.cgImage

        // `compositingFilter` implements Req 6.4's additive / screen
        // blend modes. `.plusL` is the linear-light additive blend;
        // `.screen` matches CoreImage's `CIScreenBlendMode`. Normal
        // blending is the default (no filter). Assigned to the cell
        // directly; CAEmitterCell's compositingFilter applies to the
        // particle → background composite step.
        switch p.blendMode {
        case .additive:
            cell.setValue("plusL", forKey: "compositingFilter")
        case .screen:
            cell.setValue("screenBlendMode", forKey: "compositingFilter")
        case .normal, .none:
            cell.setValue(nil, forKey: "compositingFilter")
        }
    }

    /// Produce a CGImage for the cell. Uses the skin-provided image
    /// if present; otherwise synthesizes a soft dot (Req 6.3).
    private static func resolveImage(for p: ParticleParams) -> NSImage? {
        if let _ = p.image {
            // Skin-provided image path resolution happens in a
            // future PR that threads skinDir into install; MVP
            // falls back to the soft dot so tests + prototype
            // skins don't need art assets on disk yet.
            return softDotImage()
        }
        return softDotImage()
    }

    /// Procedurally-generated soft dot — 16×16 radial alpha falloff.
    /// Cached once for the whole process since the image is
    /// parameter-free. Colors come from the cell's `color` property
    /// at render time; the cell multiplies color × image RGBA, so a
    /// white dot becomes a magenta dot when `color` is set.
    private static let softDot: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let context = NSGraphicsContext.current?.cgContext
        let rect = CGRect(origin: .zero, size: size)
        context?.clear(rect)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let colors = [NSColor.white.withAlphaComponent(1).cgColor,
                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context?.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size.width / 2,
                options: []
            )
        }
        return image
    }()

    private static func softDotImage() -> NSImage { softDot }
}
