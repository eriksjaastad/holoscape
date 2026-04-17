import AppKit

/// Protocol the host window implements so the manager can drive the
/// actual view-layer collapse/expand for each region. Keeping this in a
/// delegate avoids tying the manager to `MainWindowController`'s AppKit
/// plumbing — tests can inject a stub that just records calls.
@MainActor
protocol ChromeRegionManagerDelegate: AnyObject {
    /// Apply the collapsed state for a region. `animated == true` means
    /// the delegate should run a 200ms ease-out transition via
    /// `NSAnimationContext`; `false` means apply immediately (used during
    /// `restoreState()` at app launch, where the initial layout should
    /// not flash).
    func regionManager(
        _ manager: ChromeRegionManager,
        setRegion region: ChromeRegionManager.Region,
        collapsed: Bool,
        animated: Bool
    )
}

/// Manages which of the four chrome regions are currently collapsed.
///
/// The manager owns the `collapsedRegions: Set<Region>` state and a
/// persistence delegate to `HoloscapeConfig.chromeRegions`; it has no
/// view references of its own. Actual layout changes happen through
/// `ChromeRegionManagerDelegate` (implemented by `MainWindowController`)
/// so the manager stays pure state + policy.
///
/// State for all four regions is tracked even though top and right
/// chrome views don't exist yet — their booleans live in
/// `ChromeRegionState` already and tracking them preserves persistence
/// compatibility when views are added in later tasks.
@MainActor
final class ChromeRegionManager {

    /// The four chrome regions per the spec (design.md §7).
    enum Region: String, CaseIterable, Codable {
        case top
        case right
        case bottom
        case left
    }

    // MARK: - State

    /// Regions currently collapsed. Changes here are the source of truth —
    /// the delegate and persistence are downstream effects.
    private(set) var collapsedRegions: Set<Region> = []

    /// View-layer driver. Weak because the host window owns the manager
    /// in the reverse direction of ownership.
    weak var delegate: ChromeRegionManagerDelegate?

    /// Persistence abstraction. Protocol so tests can inject a stub
    /// without touching disk — same pattern as DensityModeManager's
    /// config writer.
    private let configWriter: ChromeRegionConfigWriter

    // MARK: - Init

    init(
        configWriter: ChromeRegionConfigWriter,
        delegate: ChromeRegionManagerDelegate? = nil
    ) {
        self.configWriter = configWriter
        self.delegate = delegate
    }

    /// Convenience init that reads the persisted state from `ConfigService`
    /// and sets up the production writer.
    convenience init(
        configService: ConfigService,
        delegate: ChromeRegionManagerDelegate? = nil
    ) {
        self.init(
            configWriter: ConfigServiceChromeRegionWriter(service: configService),
            delegate: delegate
        )
    }

    // MARK: - Public API

    /// Flip the collapsed state of a single region. The 200ms animation
    /// runs through the delegate.
    func toggleRegion(_ region: Region) {
        if collapsedRegions.contains(region) {
            expandRegion(region, animated: true)
        } else {
            collapseRegion(region, animated: true)
        }
    }

    /// Mark `region` as collapsed and notify the delegate. No-op if
    /// already collapsed (avoids spurious animations + disk writes).
    func collapseRegion(_ region: Region, animated: Bool = true) {
        guard !collapsedRegions.contains(region) else { return }
        collapsedRegions.insert(region)
        delegate?.regionManager(self, setRegion: region, collapsed: true, animated: animated)
        persistState()
    }

    /// Mark `region` as expanded and notify the delegate. No-op if
    /// already expanded.
    func expandRegion(_ region: Region, animated: Bool = true) {
        guard collapsedRegions.contains(region) else { return }
        collapsedRegions.remove(region)
        delegate?.regionManager(self, setRegion: region, collapsed: false, animated: animated)
        persistState()
    }

    /// Write the current `collapsedRegions` set through to config.
    func persistState() {
        configWriter.writeRegionState(
            topCollapsed: collapsedRegions.contains(.top),
            rightCollapsed: collapsedRegions.contains(.right),
            bottomCollapsed: collapsedRegions.contains(.bottom),
            leftCollapsed: collapsedRegions.contains(.left)
        )
    }

    /// Seed `collapsedRegions` from persisted state and drive the
    /// delegate to apply each collapsed region immediately (no animation).
    /// Call once at app launch after the delegate is wired.
    func restoreState() {
        let persisted = configWriter.readRegionState()
        collapsedRegions.removeAll()

        if persisted.topCollapsed { collapsedRegions.insert(.top) }
        if persisted.rightCollapsed { collapsedRegions.insert(.right) }
        if persisted.bottomCollapsed { collapsedRegions.insert(.bottom) }
        if persisted.leftCollapsed { collapsedRegions.insert(.left) }

        // Apply state without animation so the initial layout doesn't flash.
        for region in Region.allCases {
            let collapsed = collapsedRegions.contains(region)
            delegate?.regionManager(self, setRegion: region, collapsed: collapsed, animated: false)
        }
    }
}

// MARK: - Persistence abstraction

/// Read/write the four collapsed booleans in `ChromeRegionState`.
/// Protocol extraction mirrors `DensityModeConfigWriter` and lets tests
/// use a stub.
protocol ChromeRegionConfigWriter {
    func writeRegionState(
        topCollapsed: Bool,
        rightCollapsed: Bool,
        bottomCollapsed: Bool,
        leftCollapsed: Bool
    )

    func readRegionState() -> (
        topCollapsed: Bool,
        rightCollapsed: Bool,
        bottomCollapsed: Bool,
        leftCollapsed: Bool
    )
}

/// Production writer wrapping `ConfigService.save` / `ConfigService.load`.
/// Round-trip is load → mutate → save — matches the pattern used by
/// `AppearanceSettingsView` and `DensityModeManager`.
final class ConfigServiceChromeRegionWriter: ChromeRegionConfigWriter {
    private let service: ConfigService

    init(service: ConfigService) {
        self.service = service
    }

    func writeRegionState(
        topCollapsed: Bool,
        rightCollapsed: Bool,
        bottomCollapsed: Bool,
        leftCollapsed: Bool
    ) {
        var config = service.load()
        var regions = config.chromeRegions ?? .default
        regions.topCollapsed = topCollapsed
        regions.rightCollapsed = rightCollapsed
        regions.bottomCollapsed = bottomCollapsed
        regions.leftCollapsed = leftCollapsed
        config.chromeRegions = regions
        service.save(config)
    }

    func readRegionState() -> (
        topCollapsed: Bool,
        rightCollapsed: Bool,
        bottomCollapsed: Bool,
        leftCollapsed: Bool
    ) {
        let regions = service.load().chromeRegions ?? .default
        return (
            topCollapsed: regions.topCollapsed,
            rightCollapsed: regions.rightCollapsed,
            bottomCollapsed: regions.bottomCollapsed,
            leftCollapsed: regions.leftCollapsed
        )
    }
}
