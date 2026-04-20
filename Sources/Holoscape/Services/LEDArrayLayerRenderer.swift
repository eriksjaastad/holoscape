import AppKit
import QuartzCore

/// Renderer for `ChromeAnimationLayer.Kind.ledArray` (Req 7). One
/// `CALayer` per cell, sized `cellSize × cellSize`, positioned at the
/// cell's `(x, y)` in top-left coords inside the layer's rect.
///
/// Cell geometry + palette swatches are built once at install; `tick`
/// only mutates `backgroundColor` per-cell so zero per-frame
/// allocations happen on the animation hot path (Req 11 performance
/// budget).
///
/// Five patterns implement Req 7.4–7.8, each deterministic against
/// `phaseSeconds` + `phaseOffset`:
/// - `.steady`: every cell holds `defaultState` indefinitely
/// - `.blink(hz, duty)`: alternate `defaultState` ↔ `(defaultState+1) % palette.count`
/// - `.phased(hz)`: light cells in sequence, `hz` cells-per-second
/// - `.random(hz, density)`: re-randomize every 1/hz, `density` fraction off-state
/// - `.marquee(cellsPerSecond, windowSize)`: advance a window through the array
@MainActor
final class LEDArrayLayerRenderer: AnimatedLayerRenderer {

    let id: String
    let z: Int
    let layer: CALayer
    private let rect: SkinRect
    private var params: LedArrayParams
    private var phaseOffset: Double
    private var speedMultiplier: Double
    private var cellLayers: [CALayer] = []
    private var paletteColors: [CGColor] = []
    private var isPaused: Bool = false

    init(
        id: String,
        z: Int,
        rect: SkinRect,
        params: LedArrayParams,
        phaseOffset: Double = 0,
        speedMultiplier: Double = 1
    ) {
        self.id = id
        self.z = z
        self.rect = rect
        self.params = params
        self.phaseOffset = phaseOffset
        self.speedMultiplier = speedMultiplier

        let container = CALayer()
        container.zPosition = CGFloat(z)
        self.layer = container

        rebuildPalette()
        rebuildCells()
    }

    // MARK: - Install / uninstall

    func install(in parent: CALayer) {
        layer.frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        parent.addSublayer(layer)
    }

    func uninstall() {
        layer.removeFromSuperlayer()
        cellLayers.removeAll()
    }

    // MARK: - Params

    func updateParams(_ next: ChromeAnimationLayer.Params) {
        guard let nextLed = next.ledArray else { return }
        let geometryChanged = nextLed.cellSize != params.cellSize
            || nextLed.cells.count != params.cells.count
            || nextLed.palette != params.palette
        self.params = nextLed
        rebuildPalette()
        if geometryChanged { rebuildCells() }
    }

    // MARK: - Tick (pattern evolution)

    /// Resolve per-cell palette index at the given phase seconds.
    /// Exposed for tests so pattern determinism (Req 9) can be
    /// asserted without actually painting cells.
    func stateIndices(at phaseSeconds: Double) -> [Int] {
        let localPhase = (phaseSeconds + phaseOffset) * speedMultiplier
        switch params.pattern {
        case .steady:
            return params.cells.map { $0.defaultState }

        case .blink(let hz, let duty):
            let cycle = localPhase * hz
            let onFraction = cycle - floor(cycle)
            let isOn = onFraction < duty
            return params.cells.map { cell in
                isOn
                    ? cell.defaultState
                    : (cell.defaultState + 1) % max(1, params.palette.count)
            }

        case .phased(let hz):
            // One cell lit at a time, cycling at hz cells/second.
            guard !params.cells.isEmpty else { return [] }
            let litIndex = Int(floor(localPhase * hz)) % params.cells.count
            return params.cells.enumerated().map { idx, cell in
                idx == (litIndex < 0 ? litIndex + params.cells.count : litIndex)
                    ? (cell.defaultState + 1) % max(1, params.palette.count)
                    : cell.defaultState
            }

        case .random(let hz, let density):
            // Deterministic pseudo-random using the current time bucket
            // + cell index. Same phase → same pattern (Req 9 phase
            // determinism). Density names the fraction of cells in
            // the NON-default state.
            let bucket = Int(floor(localPhase * hz))
            return params.cells.enumerated().map { idx, cell in
                var hasher = Hasher()
                hasher.combine(bucket)
                hasher.combine(idx)
                let normalized = Double(UInt32(truncatingIfNeeded: hasher.finalize())) / Double(UInt32.max)
                if normalized < density {
                    return (cell.defaultState + 1) % max(1, params.palette.count)
                } else {
                    return cell.defaultState
                }
            }

        case .marquee(let cps, let windowSize):
            // A `windowSize`-wide window of lit cells sweeps the array
            // at cps cells/second. Cells inside the window use
            // (default+1), rest use default.
            guard !params.cells.isEmpty else { return [] }
            let head = Int(floor(localPhase * cps)) % params.cells.count
            let adjustedHead = head < 0 ? head + params.cells.count : head
            return params.cells.enumerated().map { idx, cell in
                var inWindow = false
                for k in 0..<max(1, windowSize) {
                    let windowIdx = (adjustedHead - k + params.cells.count) % params.cells.count
                    if idx == windowIdx { inWindow = true; break }
                }
                return inWindow
                    ? (cell.defaultState + 1) % max(1, params.palette.count)
                    : cell.defaultState
            }
        }
    }

    func tick(phaseSeconds: Double) {
        guard !isPaused else { return }
        let states = stateIndices(at: phaseSeconds)
        for (i, state) in states.enumerated() where i < cellLayers.count {
            let idx = max(0, min(paletteColors.count - 1, state))
            if !paletteColors.isEmpty {
                cellLayers[i].backgroundColor = paletteColors[idx]
            }
        }
    }

    // MARK: - Pause / resume

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    // MARK: - Build

    private func rebuildPalette() {
        paletteColors = params.palette.compactMap { NSColor(hex: $0)?.cgColor }
    }

    private func rebuildCells() {
        for old in cellLayers { old.removeFromSuperlayer() }
        cellLayers.removeAll()
        for cell in params.cells {
            let cellLayer = CALayer()
            cellLayer.frame = NSRect(
                x: cell.x, y: cell.y,
                width: params.cellSize, height: params.cellSize
            )
            let idx = max(0, min(paletteColors.count - 1, cell.defaultState))
            if !paletteColors.isEmpty {
                cellLayer.backgroundColor = paletteColors[idx]
            }
            layer.addSublayer(cellLayer)
            cellLayers.append(cellLayer)
        }
    }

    #if DEBUG
    var _testCellCount: Int { cellLayers.count }
    #endif
}
