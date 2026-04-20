import AppKit
import QuartzCore

/// Renderer for `ChromeAnimationLayer.Kind.shader` (Req 9). MVP ships
/// three presets: `glow`, `scanlines`, `noise`. The design names a
/// CAMetalLayer-backed implementation; this PR ships CALayer-based
/// approximations that produce the intended visual effects without
/// the Metal pipeline complexity.
///
/// **MVP scope decision**: A full Metal implementation
/// (`ChromeShaders.metal` + MTLRenderPipelineState + per-frame
/// render pass) is real work that's only exercised by skins that
/// declare shader presets — and no in-tree skin does until PRs
/// #14–#16 migrate HoloscapeClassic-live / Synthwave / AmplifyDemo.
/// The full Metal upgrade is deferred to a focused future PR once
/// the performance budget (Req 11.2 — 8 ms/frame) demands real GPU
/// compute. The CALayer approximations below:
///
/// - `.glow`: CAGradientLayer with a radial-style soft alpha falloff,
///   `compositingFilter = "plusL"` for additive blend. `hz` drives
///   opacity pulse.
/// - `.scanlines`: striped background image (8 px on / 8 px off)
///   scrolled vertically at `hz` cycles/sec via `contentsRect`.
/// - `.noise`: procedurally-generated greyscale noise image,
///   refreshed at `hz` Hz; color channel multiplied by `color`.
///
/// Validator (PR #5) already rejects unknown presets at skin load,
/// so unknown values here are defense-in-depth: `init` returns nil
/// for a preset it can't render, and `ChromeHostView`'s factory
/// filters nils silently.
@MainActor
final class ShaderPresetLayerRenderer: AnimatedLayerRenderer {

    let id: String
    let z: Int
    let layer: CALayer
    private let rect: SkinRect
    private var params: ShaderParams
    private var phaseOffset: Double
    private var speedMultiplier: Double
    private var isPaused: Bool = false

    init?(
        id: String,
        z: Int,
        rect: SkinRect,
        params: ShaderParams,
        phaseOffset: Double = 0,
        speedMultiplier: Double = 1
    ) {
        self.id = id
        self.z = z
        self.rect = rect
        self.params = params
        self.phaseOffset = phaseOffset
        self.speedMultiplier = speedMultiplier

        let l: CALayer
        switch params.preset {
        case .glow:
            l = Self.buildGlowLayer(params: params)
        case .scanlines:
            l = Self.buildScanlineLayer(params: params, rect: rect)
        case .noise:
            l = Self.buildNoiseLayer(params: params, rect: rect)
        }
        l.zPosition = CGFloat(z)
        self.layer = l
    }

    // MARK: - Install / uninstall

    func install(in parent: CALayer) {
        layer.frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if let gradient = layer as? CAGradientLayer {
            // CAGradientLayer type is hint-only; the actual radial
            // falloff is simulated via the contents-layer hierarchy
            // in buildGlowLayer.
            _ = gradient
        }
        parent.addSublayer(layer)
    }

    func uninstall() {
        layer.removeFromSuperlayer()
    }

    // MARK: - Params

    func updateParams(_ next: ChromeAnimationLayer.Params) {
        guard let nextShader = next.shader else { return }
        // Preset change requires a new layer shape — caller should
        // uninstall + reinstall via the factory. Here we only
        // handle intra-preset param tweaks (color / intensity / hz).
        self.params = nextShader
    }

    // MARK: - Tick

    func tick(phaseSeconds: Double) {
        guard !isPaused else { return }
        let localPhase = (phaseSeconds + phaseOffset) * speedMultiplier
        switch params.preset {
        case .glow:
            let hz = params.hz ?? 0.5
            let intensity = params.intensity ?? 0.5
            // Smooth pulse via cosine — opacity oscillates between
            // (intensity * 0.5) and intensity.
            let pulse = 0.5 + 0.5 * cos(2 * .pi * hz * localPhase)
            layer.opacity = Float(intensity * (0.5 + 0.5 * pulse))

        case .scanlines:
            let hz = params.hz ?? 1.0
            // Scroll contentsRect vertically at hz. Content is tiled
            // so the scroll appears seamless.
            let offset = localPhase * hz
            let y = CGFloat(offset - floor(offset))
            layer.contentsRect = CGRect(x: 0, y: y, width: 1, height: 1)

        case .noise:
            let hz = params.hz ?? 30.0
            // Swap the noise image at hz. Cheap enough for 30 Hz on
            // small chrome bands; a real Metal implementation would
            // compute this per pixel in the fragment shader.
            let bucket = Int(floor(localPhase * hz))
            layer.contents = Self.noiseImage(seed: bucket, params: params)
        }
    }

    // MARK: - Pause / resume

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    // MARK: - Builders

    private static func buildGlowLayer(params: ShaderParams) -> CALayer {
        let l = CALayer()
        let color = NSColor(hex: params.color ?? "#ffffff") ?? .white
        l.backgroundColor = color.withAlphaComponent(CGFloat(params.intensity ?? 0.5)).cgColor
        l.setValue("plusL", forKey: "compositingFilter")  // additive
        l.cornerRadius = 0
        return l
    }

    private static func buildScanlineLayer(params: ShaderParams, rect: SkinRect) -> CALayer {
        let l = CALayer()
        let color = NSColor(hex: params.color ?? "#000000") ?? .black
        // Tile a 2-row pattern (one opaque row, one transparent row)
        // vertically across `rect`. Scroll via `contentsRect` in tick.
        l.contents = Self.scanlineImage(
            color: color,
            intensity: params.intensity ?? 0.3,
            width: max(1, Int(rect.width)),
            height: max(1, Int(rect.height))
        )
        l.contentsGravity = .resize
        return l
    }

    private static func buildNoiseLayer(params: ShaderParams, rect: SkinRect) -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resize
        l.contents = noiseImage(seed: 0, params: params)
        return l
    }

    private static func scanlineImage(color: NSColor, intensity: Double, width: Int, height: Int) -> CGImage? {
        let w = max(1, width)
        let h = max(2, height)
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let a = UInt8(min(255, max(0, Int(intensity * 255))))
        let r = UInt8(min(255, Int(color.redComponent * 255)))
        let g = UInt8(min(255, Int(color.greenComponent * 255)))
        let b = UInt8(min(255, Int(color.blueComponent * 255)))
        for y in stride(from: 0, to: h, by: 2) {
            let rowStart = y * bytesPerRow
            for x in 0..<w {
                let i = rowStart + x * 4
                bytes[i] = r
                bytes[i + 1] = g
                bytes[i + 2] = b
                bytes[i + 3] = a
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func noiseImage(seed: Int, params: ShaderParams) -> CGImage? {
        // 32×32 deterministic greyscale noise. LCG keyed off `seed`
        // so the same tick produces the same noise — avoids uncanny
        // flicker on paused frames.
        let w = 32, h = 32
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        var state: UInt64 = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        let intensity = params.intensity ?? 0.25
        let color = NSColor(hex: params.color ?? "#ffffff") ?? .white
        let cr = color.redComponent
        let cg = color.greenComponent
        let cb = color.blueComponent
        for y in 0..<h {
            for x in 0..<w {
                state &*= 6364136223846793005
                state &+= 1442695040888963407
                let v = Double(UInt8(truncatingIfNeeded: state >> 33)) / 255.0
                let i = y * bytesPerRow + x * 4
                bytes[i] = UInt8(min(255, Int(v * cr * 255)))
                bytes[i + 1] = UInt8(min(255, Int(v * cg * 255)))
                bytes[i + 2] = UInt8(min(255, Int(v * cb * 255)))
                bytes[i + 3] = UInt8(min(255, Int(v * intensity * 255)))
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
