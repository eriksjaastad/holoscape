import XCTest
@testable import Holoscape

/// Task 7.3 / 7.5 — ChromeRegionManager state + persistence.
///
/// Delegate and persistence are stubbed so tests stay synchronous and
/// disk-free. Actual view-layer animation timing is exercised by PR C's
/// MainWindowController integration, not here.
@MainActor
final class ChromeRegionManagerTests: XCTestCase {

    // MARK: - Stubs

    /// Records every (region, collapsed, animated) triple the manager
    /// pushes out, and every persistence write.
    final class SpyDelegate: ChromeRegionManagerDelegate {
        struct Call: Equatable {
            let region: ChromeRegionManager.Region
            let collapsed: Bool
            let animated: Bool
        }
        var calls: [Call] = []

        func regionManager(
            _ manager: ChromeRegionManager,
            setRegion region: ChromeRegionManager.Region,
            collapsed: Bool,
            animated: Bool
        ) {
            calls.append(Call(region: region, collapsed: collapsed, animated: animated))
        }
    }

    final class StubWriter: ChromeRegionConfigWriter {
        var persistedTop: Bool = false
        var persistedRight: Bool = false
        var persistedBottom: Bool = false
        var persistedLeft: Bool = false
        var writeCount: Int = 0

        func writeRegionState(topCollapsed: Bool, rightCollapsed: Bool, bottomCollapsed: Bool, leftCollapsed: Bool) {
            writeCount += 1
            persistedTop = topCollapsed
            persistedRight = rightCollapsed
            persistedBottom = bottomCollapsed
            persistedLeft = leftCollapsed
        }

        func readRegionState() -> (topCollapsed: Bool, rightCollapsed: Bool, bottomCollapsed: Bool, leftCollapsed: Bool) {
            (persistedTop, persistedRight, persistedBottom, persistedLeft)
        }
    }

    // MARK: - Initial state

    func testInitialCollapsedRegionsIsEmpty() {
        let manager = ChromeRegionManager(configWriter: StubWriter())
        XCTAssertTrue(manager.collapsedRegions.isEmpty)
    }

    // MARK: - Toggle semantics

    func testToggleAddsAndRemovesRegion() {
        let delegate = SpyDelegate()
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer, delegate: delegate)

        manager.toggleRegion(.left)
        XCTAssertTrue(manager.collapsedRegions.contains(.left))

        manager.toggleRegion(.left)
        XCTAssertFalse(manager.collapsedRegions.contains(.left))

        XCTAssertEqual(delegate.calls, [
            SpyDelegate.Call(region: .left, collapsed: true, animated: true),
            SpyDelegate.Call(region: .left, collapsed: false, animated: true),
        ])
    }

    func testMultipleRegionsTracked() {
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer)

        manager.collapseRegion(.left, animated: false)
        manager.collapseRegion(.bottom, animated: false)

        XCTAssertEqual(manager.collapsedRegions, [.left, .bottom])
    }

    // MARK: - Idempotency

    func testDoubleCollapseIsIdempotent() {
        let delegate = SpyDelegate()
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer, delegate: delegate)

        manager.collapseRegion(.left, animated: true)
        manager.collapseRegion(.left, animated: true)

        XCTAssertEqual(delegate.calls.count, 1,
                       "Second collapse must no-op (no delegate call)")
        XCTAssertEqual(writer.writeCount, 1, "Second collapse must not re-persist")
    }

    func testDoubleExpandIsIdempotent() {
        let delegate = SpyDelegate()
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer, delegate: delegate)

        // expand a region that isn't collapsed
        manager.expandRegion(.left, animated: true)
        XCTAssertEqual(delegate.calls.count, 0,
                       "Expand on an already-expanded region is a no-op")
        XCTAssertEqual(writer.writeCount, 0)
    }

    // MARK: - Animated flag forwarding

    func testAnimatedFlagPassesThroughToDelegate() {
        let delegate = SpyDelegate()
        let manager = ChromeRegionManager(configWriter: StubWriter(), delegate: delegate)

        manager.collapseRegion(.bottom, animated: false)
        manager.expandRegion(.bottom, animated: true)

        XCTAssertEqual(delegate.calls, [
            SpyDelegate.Call(region: .bottom, collapsed: true, animated: false),
            SpyDelegate.Call(region: .bottom, collapsed: false, animated: true),
        ])
    }

    // MARK: - Persistence round-trip

    func testCollapsePersistsEveryRegionBoolean() {
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer)

        manager.collapseRegion(.left, animated: false)
        manager.collapseRegion(.bottom, animated: false)

        XCTAssertTrue(writer.persistedLeft)
        XCTAssertTrue(writer.persistedBottom)
        XCTAssertFalse(writer.persistedTop)
        XCTAssertFalse(writer.persistedRight)
    }

    func testExpandClearsPersistedBoolean() {
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer)

        manager.collapseRegion(.left, animated: false)
        XCTAssertTrue(writer.persistedLeft)

        manager.expandRegion(.left, animated: false)
        XCTAssertFalse(writer.persistedLeft,
                       "Expand must flip the persisted boolean back to false")
    }

    // MARK: - restoreState

    func testRestoreStateSeedsFromWriterAndDrivesDelegate() {
        let writer = StubWriter()
        writer.persistedLeft = true
        writer.persistedBottom = true

        let delegate = SpyDelegate()
        let manager = ChromeRegionManager(configWriter: writer, delegate: delegate)

        manager.restoreState()

        XCTAssertEqual(manager.collapsedRegions, [.left, .bottom])
        // Delegate receives one call per region, animated:false, with the
        // correct collapsed flag per region.
        XCTAssertEqual(delegate.calls.count, ChromeRegionManager.Region.allCases.count)
        XCTAssertTrue(delegate.calls.allSatisfy { !$0.animated },
                      "restoreState must apply without animation to avoid first-frame flash")

        let callsByRegion = Dictionary(uniqueKeysWithValues: delegate.calls.map { ($0.region, $0.collapsed) })
        XCTAssertEqual(callsByRegion[.left], true)
        XCTAssertEqual(callsByRegion[.bottom], true)
        XCTAssertEqual(callsByRegion[.top], false)
        XCTAssertEqual(callsByRegion[.right], false)
    }

    func testRestoreStateReplacesPriorInMemoryState() {
        let writer = StubWriter()
        let manager = ChromeRegionManager(configWriter: writer)

        manager.collapseRegion(.top, animated: false)
        XCTAssertTrue(manager.collapsedRegions.contains(.top))

        // Persisted state has ONLY left collapsed — restore should
        // overwrite in-memory state, not merge.
        writer.persistedTop = false
        writer.persistedLeft = true

        manager.restoreState()

        XCTAssertEqual(manager.collapsedRegions, [.left],
                       "restoreState replaces in-memory state, doesn't merge")
    }
}
