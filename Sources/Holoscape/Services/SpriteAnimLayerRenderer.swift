import AppKit
import QuartzCore

/// Renderer for `ChromeAnimationLayer.Kind.spriteAnim` (Req 8). A
/// single `CALayer` carries the whole sprite sheet in
/// `layer.contents`; per-frame animation advances `contentsRect`
/// through the grid at the declared `fps`. No per-frame allocation —
/// only a rect mutation.
///
/// `frameCount` may be less than `gridRows * gridCols` (the validator
/// already rejects frameCount > grid cells). Extra cells are ignored.
///
/// Loop modes (Req 8.3):
/// - `.loop`: frame % frameCount
/// - `.pingPong`: 0 → frameCount-1 → 0 → ...
/// - `.once`: holds frame (frameCount-1) after one pass
@MainActor
final class SpriteAnimLayerRenderer: AnimatedLayerRenderer {

    let id: String
    let z: Int
    let layer: CALayer
    private let rect: SkinRect
    private var params: SpriteAnimParams
    private var phaseOffset: Double
    private var speedMultiplier: Double
    private var sheet: NSImage?
    private var isPaused: Bool = false

    init(
        id: String,
        z: Int,
        rect: SkinRect,
        params: SpriteAnimParams,
        phaseOffset: Double = 0,
        speedMultiplier: Double = 1,
        sheet: NSImage? = nil
    ) {
        self.id = id
        self.z = z
        self.rect = rect
        self.params = params
        self.phaseOffset = phaseOffset
        self.speedMultiplier = speedMultiplier
        self.sheet = sheet

        let l = CALayer()
        l.zPosition = CGFloat(z)
        if let sheet {
            l.contents = sheet.cgImage
        }
        l.contentsGravity = .resize
        // Initial frame 0 UV rect.
        l.contentsRect = Self.uvRect(
            for: 0,
            gridRows: params.gridRows,
            gridCols: params.gridCols
        )
        self.layer = l
    }

    // MARK: - Install / uninstall

    func install(in parent: CALayer) {
        layer.frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        parent.addSublayer(layer)
    }

    func uninstall() {
        layer.removeFromSuperlayer()
    }

    // MARK: - Params

    func updateParams(_ next: ChromeAnimationLayer.Params) {
        guard let nextSprite = next.spriteAnim else { return }
        self.params = nextSprite
    }

    // MARK: - Frame resolution

    /// Resolve the visible frame index at a given phase seconds.
    /// Exposed for tests — pattern determinism is the load-bearing
    /// invariant (Req 9).
    func frameIndex(at phaseSeconds: Double) -> Int {
        let localPhase = (phaseSeconds + phaseOffset) * speedMultiplier
        let totalFrames = params.frameCount
        guard totalFrames > 0 else { return 0 }
        let rawFrame = Int(floor(localPhase * params.fps))

        switch params.loop {
        case .loop:
            let mod = rawFrame % totalFrames
            return mod < 0 ? mod + totalFrames : mod
        case .once:
            if rawFrame < 0 { return 0 }
            return min(rawFrame, totalFrames - 1)
        case .pingPong:
            // Period is 2*(totalFrames - 1): 0..N-1..1. Single-frame
            // case has no oscillation.
            guard totalFrames > 1 else { return 0 }
            let period = 2 * (totalFrames - 1)
            let mod = rawFrame % period
            let pos = mod < 0 ? mod + period : mod
            return pos < totalFrames ? pos : period - pos
        }
    }

    func tick(phaseSeconds: Double) {
        guard !isPaused else { return }
        let frame = frameIndex(at: phaseSeconds)
        layer.contentsRect = Self.uvRect(
            for: frame,
            gridRows: params.gridRows,
            gridCols: params.gridCols
        )
    }

    // MARK: - Pause / resume

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    // MARK: - UV helper

    /// UV rect for a given frame index inside the sheet. Frames
    /// advance left-to-right, row-by-row (row-major). Returns the
    /// unit square on degenerate grids so Core Animation still has
    /// a valid contentsRect.
    static func uvRect(for frame: Int, gridRows: Int, gridCols: Int) -> CGRect {
        guard gridRows > 0, gridCols > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let cellW = 1.0 / CGFloat(gridCols)
        let cellH = 1.0 / CGFloat(gridRows)
        let row = (frame / gridCols) % gridRows
        let col = frame % gridCols
        return CGRect(
            x: CGFloat(col) * cellW,
            y: CGFloat(row) * cellH,
            width: cellW,
            height: cellH
        )
    }
}
