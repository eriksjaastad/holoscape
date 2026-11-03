import XCTest
import AppKit
@testable import Holoscape

/// Task 9.1 — TabBarView reads its container and tab-state colors from
/// the injected SkinContext. Without a context the view still renders
/// the modern built-in Default constants — this is the fallback
/// path used by XCUITest fixtures that don't build a full controller.
@MainActor
final class TabBarViewSkinContextTests: XCTestCase {

    private func makeContext(tabBarContainer: NSColor = .black,
                             tabActive: NSColor = .blue) -> SkinContext {
        // Build a skin whose tabBar container and active-tab surfaces
        // override the built-in defaults, then let builtInDefaults fill
        // the rest of the 23 keys.
        let snap = ReactiveUniformSnapshot()
        let base = SkinContext.builtInDefaults(reactive: snap)
        var surfaces = base.allResolvedSurfacesForTesting
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(tabBarContainer),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil, text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        surfaces[.tabBarTabActive] = SkinContext.ResolvedSurface(
            fill: .color(tabActive),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil, text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    func testAssigningSkinContextRepaintsContainer() {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        // Before: uses the built-in constant.
        let preAssign = view.layer?.backgroundColor
        XCTAssertNotNil(preAssign)

        let magenta = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        view.skinContext = makeContext(tabBarContainer: magenta)

        XCTAssertEqual(view.layer?.backgroundColor, magenta.cgColor,
                       "Assigning a SkinContext with a magenta tabBar.container must repaint the container")
    }

    func testSkinDidChangeNotificationRepaintsInIsolation() {
        // Exercises only the `.skinDidChange` observer path, with no
        // `skinContext =` assignment between set-up and post. Breaks if
        // the observer is ever disconnected or calls the wrong method.
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        // Hold a reference to a mutable surfaces dictionary so we can
        // swap the container fill without reassigning skinContext.
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        let green = NSColor(red: 0, green: 1, blue: 0, alpha: 1)
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(green), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        // Assign once, then mutate-and-notify.
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)

        let purple = NSColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
        surfaces[.tabBarContainer] = SkinContext.ResolvedSurface(
            fill: .color(purple), border: nil, corner: .uniform(0),
            padding: .init(), shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        view.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        // didSet already repainted. Now forcibly reset and verify the
        // notification path alone drives the repaint.
        view.layer?.backgroundColor = NSColor.black.cgColor
        NotificationCenter.default.post(name: .skinDidChange, object: nil)
        XCTAssertEqual(view.layer?.backgroundColor, purple.cgColor,
                       ".skinDidChange observer must re-resolve from the held context")
    }

    func testFallsBackToBuiltInWhenNoContext() {
        // The modern built-in tabBar.container default is #121b27.
        // Without a SkinContext, setupScrollView must paint that exact
        // constant so the standalone rendering path (XCUITest fixtures)
        // stays visually identical to the skinned path's built-in mode.
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        view.layoutSubtreeIfNeeded()

        XCTAssertNil(view.skinContext)

        let expected = NSColor(hex: "#121b27")!.cgColor
        let actual = view.layer?.backgroundColor
        XCTAssertNotNil(actual, "Hardcoded fallback must paint a non-nil background")

        // CGColor `==` is pointer equality; compare components instead.
        guard let actualComps = actual?.components, let expectedComps = expected.components else {
            XCTFail("Both colors must have RGB components to compare")
            return
        }
        XCTAssertEqual(actualComps.count, expectedComps.count)
        for (a, e) in zip(actualComps, expectedComps) {
            XCTAssertEqual(a, e, accuracy: 0.001,
                           "Fallback background must match the hardcoded (0.06, 0.06, 0.12, 1.0)")
        }
    }

    func testStaleBrokerRecoveryGuidanceIsVisibleOnTabButton() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .shell, label: "Recovered", state: .stale)
        channel.recoveryActionOverride = .recreateBrokerSession

        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let buttons = view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
        guard let button = buttons.first else {
            XCTFail("Expected one tab button after updateTabs")
            return
        }

        XCTAssertTrue(button.title.contains("recreate session"), button.title)
        XCTAssertEqual(button.accessibilityValue() as? String, "stale: recreate session")
        XCTAssertTrue(button.toolTip?.contains("Broker session is stale or missing") == true, button.toolTip ?? "nil")
        XCTAssertTrue(button.accessibilityHelp()?.contains("persists the new broker session ID") == true, button.accessibilityHelp() ?? "nil")
    }

    /// #7373 follow-up — guidance belongs to the stale state. Once the tab is
    /// running again (for example after Recreate or a successful relaunch
    /// reattach), the stale instructions must not keep announcing themselves.
    func testRecoveredTabClearsStaleRecoveryGuidance() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .shell, label: "Recovered", state: .stale)
        channel.recoveryActionOverride = .recreateBrokerSession
        view.updateTabs(channels: [channel], activeId: channel.channelId)

        channel.recoveryActionOverride = nil
        channel.activate()
        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let buttons = view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
        let button = try XCTUnwrap(buttons.first)

        XCTAssertEqual(channel.state, .active)
        XCTAssertFalse(button.title.contains("recreate session"), button.title)
        XCTAssertNil(button.toolTip)
        XCTAssertNil(button.accessibilityHelp(), "Recovered tab must not keep stale recovery instructions: \(button.accessibilityHelp() ?? "nil")")
        XCTAssertEqual(button.accessibilityValue() as? String, "running")
    }

    func testStaleInteractionOutranksRoutineRunningAccessibility() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .shell, label: "Long running", state: .active)

        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            now: Date(),
            staleThreshold: -1
        )

        let button = try button(for: channel.channelId, in: view)
        XCTAssertEqual(button.accessibilityValue() as? String, "stale-interaction")
    }

    func testDurableErrorAndStaleOutrankLingeringPermissionNotification() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .agentDirect, label: "Failed", state: .active)
        channel.persistentStateOverride = PersistentChannelState(
            kind: .error,
            source: .agentAdapter,
            reason: "command failed"
        )
        view.skinContext = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())

        let lingeringPermission = [channel.channelId: "permission_prompt"]
        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            notifications: lingeringPermission
        )

        var tabButton = try button(for: channel.channelId, in: view)
        XCTAssertTrue(tabButton.title.hasPrefix("× "), tabButton.title)
        XCTAssertEqual(tabButton.accessibilityValue() as? String, "error: command failed")

        channel.persistentStateOverride = PersistentChannelState(
            kind: .stale,
            source: .brokerRegistry,
            reason: "session missing"
        )
        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            notifications: lingeringPermission
        )

        tabButton = try button(for: channel.channelId, in: view)
        XCTAssertTrue(tabButton.title.hasPrefix("◌ "), tabButton.title)
        XCTAssertEqual(tabButton.accessibilityValue() as? String, "stale: session missing")
    }

    func testSkinMarkerIsVisibleButExcludedFromAccessibilityTitle() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .shell, label: "Workspace", state: .active)
        channel.persistentStateOverride = PersistentChannelState(kind: .running, source: .processLifecycle)
        view.skinContext = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())

        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let button = try button(for: channel.channelId, in: view)
        XCTAssertEqual(button.title, "▶ Workspace")
        XCTAssertEqual(button.accessibilityTitle(), "Workspace")
        XCTAssertEqual(button.accessibilityValue() as? String, "running")
    }

    func testLiveSkinMarkerChangeRelayoutsExistingTabs() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .shell, label: "Workspace", state: .active)
        channel.persistentStateOverride = PersistentChannelState(kind: .running, source: .processLifecycle)
        view.skinContext = contextWithActiveMarker("I")
        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let initialButton = try button(for: channel.channelId, in: view)
        let initialWidth = initialButton.frame.width

        view.skinContext = contextWithActiveMarker("WWW")

        let updatedButton = try button(for: channel.channelId, in: view)
        XCTAssertEqual(updatedButton.title, "WWW Workspace")
        XCTAssertGreaterThan(updatedButton.frame.width, initialWidth,
                             "A live marker change must resize the existing tab to fit its new title")
    }

    func testPersistentNeedsApprovalPaintsActiveTopTabAsPermission() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .agentDirect, label: "Claude", state: .active)
        channel.persistentStateOverride = PersistentChannelState(
            kind: .needsApproval,
            source: .terminalOutput,
            reason: "Claude Code awaiting approval"
        )

        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let button = try XCTUnwrap(view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
            .first)
        XCTAssertEqual(button.accessibilityValue() as? String, "needs-approval")
        XCTAssertEqual(button.layer?.backgroundColor, NSColor(hex: "#4a391f")!.cgColor)
    }

    func testPerTabPersistentStatesRemainDistinctAcrossLiveSkinSwitch() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 32))
        let states: [(PersistentChannelStateKind, String, String)] = [
            (.running, "▶", "running"),
            (.needsApproval, "!", "needs-approval"),
            (.error, "×", "error: failed"),
            (.stale, "◌", "stale: missing"),
        ]
        let channels = states.enumerated().map { index, item -> MockChannelController in
            let channel = MockChannelController(type: .agentDirect, label: "Agent \(index + 1)", state: item.0 == .stale ? .stale : .active)
            channel.persistentStateOverride = PersistentChannelState(
                kind: item.0,
                source: .agentAdapter,
                reason: item.0 == .error ? "failed" : item.0 == .stale ? "missing" : nil
            )
            return channel
        }

        view.skinContext = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())
        view.updateTabs(channels: channels, activeId: channels[0].channelId)

        for (channel, expected) in zip(channels, states) {
            let button = try button(for: channel.channelId, in: view)
            XCTAssertTrue(button.title.hasPrefix(expected.1 + " "), button.title)
            XCTAssertEqual(button.accessibilityValue() as? String, expected.2)
        }

        let mercury = try SkinEngine().loadComposite(named: "MercuryDeck")
        view.skinContext = MainWindowController.buildSkinContext(
            overriding: mercury.surfaces,
            reactive: ReactiveUniformSnapshot()
        )

        let mercuryMarkers = ["▷", "!", "×", "◌"]
        for ((channel, expected), marker) in zip(zip(channels, states), mercuryMarkers) {
            let button = try button(for: channel.channelId, in: view)
            XCTAssertTrue(button.title.hasPrefix(marker + " "), button.title)
            XCTAssertEqual(button.accessibilityValue() as? String, expected.2)
        }
    }

    func testTabTitleIncludesAgentIdentityIndicatorPrefix() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .agentDirect, label: "Codex", state: .active)
        channel.tabIdentityIndicatorOverride = .codex

        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let button = try XCTUnwrap(view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
            .first)

        XCTAssertEqual(button.title, "◈ Codex")
        XCTAssertEqual(button.toolTip, "Codex tab")
        XCTAssertEqual(button.accessibilityHelp(), "Codex channel")
    }

    func testSSHIdentityIndicatorDoesNotHideStaleRecoveryGuidance() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let channel = MockChannelController(type: .ssh, label: "MacBook", state: .stale)
        channel.tabIdentityIndicatorOverride = .ssh
        channel.recoveryActionOverride = .retryBrokerHost

        view.updateTabs(channels: [channel], activeId: channel.channelId)

        let button = try XCTUnwrap(view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
            .first)

        XCTAssertEqual(button.title, "⌁ MacBook — retry broker")
        XCTAssertEqual(button.accessibilityValue() as? String, "stale: retry broker")
        XCTAssertTrue(button.toolTip?.contains("Broker host is unavailable") == true, button.toolTip ?? "nil")
    }

    func testTabCollisionSuffixClearsWhenOnlySiblingRemains() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let first = MockChannelController(type: .shell, label: "work")
        let second = MockChannelController(type: .shell, label: "work 2")
        second.displayBaseLabelOverride = "work"

        view.updateTabs(channels: [first, second], activeId: first.channelId)
        XCTAssertEqual(try buttonTitle(for: second.channelId, in: view), "work 2")

        view.updateTabs(channels: [second], activeId: second.channelId)
        XCTAssertEqual(try buttonTitle(for: second.channelId, in: view), "work")
    }

    private func buttonTitle(for channelId: UUID, in view: TabBarView) throws -> String {
        let buttons = view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
        let button = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == channelId.uuidString })
        return button.title
    }

    private func button(for channelId: UUID, in view: TabBarView) throws -> NSButton {
        let buttons = view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
        return try XCTUnwrap(buttons.first { $0.identifier?.rawValue == channelId.uuidString })
    }

    private func contextWithActiveMarker(_ symbol: String) -> SkinContext {
        let snapshot = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snapshot).allResolvedSurfacesForTesting
        surfaces[.tabBarTabActive]?.marker = StateMarkerDescriptor(symbol: symbol)
        surfaces[.tabBarTabActive]?.states = []
        return SkinContext(surfaces: surfaces, reactive: snapshot)
    }
}

// MARK: - Testing hook

extension SkinContext {
    /// Test-only accessor exposing the private `surfaces` dictionary so
    /// tests can build variants of the built-in defaults without having
    /// to reconstruct all 23 keys from scratch.
    var allResolvedSurfacesForTesting: [SurfaceKey: ResolvedSurface] {
        SurfaceKey.allCases.reduce(into: [:]) { result, key in
            result[key] = resolve(key)
        }
    }
}
