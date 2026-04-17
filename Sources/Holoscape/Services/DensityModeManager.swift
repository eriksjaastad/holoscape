import Foundation

/// Runtime switch that gates the chrome skinning system's three density levels:
///
/// - `.full` — all skin features active: images, gradients, state-variant
///   animations, shadows. The "show me everything" mode.
/// - `.minimal` — color fills only; images skipped; animations suppressed.
///   State changes apply instantly. For users who want the color theme but
///   none of the motion or asset weight.
/// - `.off` — skin engine bypassed entirely; chrome views render the
///   pre-skinning hardcoded defaults. Zero-overhead idle chrome is one of
///   the spec's hard performance guarantees (Property 7, Requirement 15.1):
///   no `SkinContext` allocation, no `FSEventStream` watcher, no
///   `CADisplayLink` for chrome, no CALayer image compositing.
///
/// Holds a weak reference to `AnimationEngine` so it can call
/// `suppressAll()` when transitioning into a non-animating mode.
/// `SkinEngine` is NOT held here — the relationship is the reverse:
/// SkinEngine queries this manager's predicates at apply-time (wired in
/// PR B). Predicates: `isSkinActive()` / `shouldRenderImages()` /
/// `shouldAnimate()`.
@MainActor
final class DensityModeManager {

    /// Density levels. Codable so `HoloscapeConfig` round-trips the mode
    /// via `ChromeRegionState.densityMode: String?`.
    enum Mode: String, Codable, CaseIterable {
        case full
        case minimal
        case off
    }

    // MARK: - State

    /// Current mode. Initialized from `ChromeRegionState.densityMode` at
    /// construction; subsequent changes go through `setMode`.
    private(set) var mode: Mode

    /// AnimationEngine that `setMode` drains when entering a non-animating
    /// mode. Weak because the engine outlives this manager via the app's
    /// object graph.
    weak var animationEngine: AnimationEngine?

    /// Persistence delegate. Protocol-based so tests can inject a stub
    /// without touching disk.
    private let configWriter: DensityModeConfigWriter

    // MARK: - Init

    init(
        initialMode: Mode = .full,
        configWriter: DensityModeConfigWriter,
        animationEngine: AnimationEngine? = nil
    ) {
        self.mode = initialMode
        self.configWriter = configWriter
        self.animationEngine = animationEngine
    }

    /// Convenience initializer that loads the starting mode from the config's
    /// `chromeRegions.densityMode` field, falling back to `.full` for missing
    /// or unrecognized values.
    convenience init(
        configService: ConfigService,
        animationEngine: AnimationEngine? = nil
    ) {
        let config = configService.load()
        let persisted = config.chromeRegions?.densityMode
        let initial = persisted.flatMap(Mode.init(rawValue:)) ?? .full
        self.init(
            initialMode: initial,
            configWriter: ConfigServiceDensityWriter(service: configService),
            animationEngine: animationEngine
        )
    }

    // MARK: - Public API

    /// Transition to `newMode`. No-op when already in that mode.
    ///
    /// On a transition that disables animation (entering `.minimal` or
    /// `.off`), active animations are suppressed BEFORE the notification
    /// is posted so observers that re-queue animations on mode change see
    /// the new mode and stay consistent.
    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        let previous = mode
        mode = newMode

        if !shouldAnimate() {
            animationEngine?.suppressAll()
        }

        configWriter.writeDensityMode(newMode.rawValue)

        NotificationCenter.default.post(
            name: .densityModeDidChange,
            object: self,
            userInfo: [
                "previous": previous.rawValue,
                "current": newMode.rawValue,
            ]
        )
    }

    /// `false` when mode is `.off` — the skin engine bypass mode.
    /// Callers should short-circuit any skin work when this returns false.
    func isSkinActive() -> Bool {
        mode != .off
    }

    /// `false` when mode is `.minimal` or `.off`. When false, `SkinEngine`
    /// should substitute color fills for image fills at ResolvedSurface
    /// build time (see Task 8.1 for where this hook lands).
    func shouldRenderImages() -> Bool {
        mode == .full
    }

    /// `false` when mode is `.minimal` or `.off`. `AnimationEngine` should
    /// force instant application (no curves) whenever this returns false.
    func shouldAnimate() -> Bool {
        mode == .full
    }
}

// MARK: - Persistence abstraction

/// Minimal interface for writing the density mode back to persisted config.
/// Protocol extraction keeps the manager testable without a real ConfigService.
protocol DensityModeConfigWriter {
    func writeDensityMode(_ modeRawValue: String)
}

/// Production implementation: load, mutate `chromeRegions.densityMode`, save.
final class ConfigServiceDensityWriter: DensityModeConfigWriter {
    private let service: ConfigService

    init(service: ConfigService) {
        self.service = service
    }

    func writeDensityMode(_ modeRawValue: String) {
        var config = service.load()
        var regions = config.chromeRegions ?? .default
        regions.densityMode = modeRawValue
        config.chromeRegions = regions
        service.save(config)
    }
}
