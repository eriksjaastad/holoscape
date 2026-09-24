import AppKit
import XCTest
@testable import Holoscape

/// Regression guards for the three-way session-truth boundary: a normal
/// disconnected tab (`.disconnected` + `.reconnect`) must never be conflated
/// with a stale/restored broker-backed tab (`.stale` + recreate/retry
/// guidance), and vice-versa — through the durable persistent-state model,
/// the saved-metadata round-trip, and the tab accessibility surface.
///
/// These fill the "distinguish stale from disconnected" acceptance gap left by
/// `StaleBrokerRelaunchTests` (stale/relaunch side only) and the stale-focused
/// accessibility tests in `TabBarViewSkinContextTests` /
/// `SidebarViewSkinContextTests` (stale side only). The disconnected/reconnect
/// side of the boundary was previously unexercised.
@MainActor
final class DisconnectedVsStaleBrokerTruthTests: XCTestCase {

    // MARK: - Durable model truth

    func testDisconnectedPersistentStateCarriesReconnectNotStale() {
        let state = PersistentChannelState.fromRuntimeState(.disconnected, recoveryAction: .reconnect)

        XCTAssertEqual(state.kind, .disconnected, "A disconnected channel keeps a distinct disconnected durable kind")
        XCTAssertNotEqual(state.kind, .ready, "A disconnected channel must not be persisted as ready/usable")
        XCTAssertNotEqual(state.kind, .stale, "A disconnected channel must not be persisted as stale")
        XCTAssertEqual(state.recoveryAction, .reconnect, "A disconnected channel reports reconnect guidance")
    }

    func testStalePersistentStateCarriesRecreateNotReconnect() {
        let state = PersistentChannelState.fromRuntimeState(.stale, recoveryAction: .recreateBrokerSession)

        XCTAssertEqual(state.kind, .stale)
        XCTAssertEqual(state.recoveryAction, .recreateBrokerSession)
        XCTAssertNotEqual(
            state.recoveryAction,
            .reconnect,
            "A stale tab must not be mistaken for a plain disconnected reconnect"
        )
    }

    func testStalePersistentStateCarriesRetryBrokerHostDistinctFromReconnect() {
        let state = PersistentChannelState.fromRuntimeState(.stale, recoveryAction: .retryBrokerHost)

        XCTAssertEqual(state.kind, .stale)
        XCTAssertEqual(state.recoveryAction, .retryBrokerHost)
        XCTAssertNotEqual(state.recoveryAction, .reconnect)
    }

    // MARK: - Saved-metadata round-trip

    /// The stale round-trip is covered by
    /// `PersistentChannelStateTests.testChannelMetadataEncodesPersistentState`,
    /// but the disconnected/reconnect case was not: prove a saved disconnected
    /// tab keeps its `.reconnect` guidance through the durable metadata
    /// boundary instead of degrading to stale or dropping the action.
    func testDisconnectedReconnectActionSurvivesChannelMetadataRoundTrip() throws {
        let metadata = ChannelMetadata(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            type: .shell,
            role: "Shell",
            persistentState: PersistentChannelState(
                kind: .disconnected,
                source: .processLifecycle,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_002),
                recoveryAction: .reconnect
            )
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)

        XCTAssertEqual(decoded.persistentState?.kind, .disconnected)
        XCTAssertEqual(decoded.persistentState?.recoveryAction, .reconnect)
        XCTAssertNotEqual(
            decoded.persistentState?.recoveryAction,
            .recreateBrokerSession,
            "A disconnected tab's reconnect guidance must not round-trip as stale recreate guidance"
        )
    }

    // MARK: - Recovery-action surface text stays distinct

    func testRecoveryActionSurfaceTextKeepsTheThreeStatesDistinct() {
        XCTAssertNotEqual(
            ChannelRecoveryAction.reconnect.surfaceStatusText,
            ChannelRecoveryAction.recreateBrokerSession.surfaceStatusText
        )
        XCTAssertNotEqual(
            ChannelRecoveryAction.reconnect.surfaceStatusText,
            ChannelRecoveryAction.retryBrokerHost.surfaceStatusText
        )
        XCTAssertNotEqual(
            ChannelRecoveryAction.recreateBrokerSession.surfaceStatusText,
            ChannelRecoveryAction.retryBrokerHost.surfaceStatusText
        )
    }

    // MARK: - Accessibility surface

    func testDisconnectedTabDoesNotAdvertiseStaleBrokerRecoveryGuidance() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let disconnected = MockChannelController(type: .shell, label: "Shell", state: .disconnected)

        view.updateTabs(channels: [disconnected], activeId: disconnected.channelId)

        let button = try XCTUnwrap(tabButtons(in: view).first)

        XCTAssertNil(
            button.accessibilityHelp(),
            "A normal disconnected tab must not announce stale recovery guidance"
        )
        let value = button.accessibilityValue() as? String ?? ""
        XCTAssertFalse(
            value.hasPrefix("stale:"),
            "A disconnected tab must not be labelled stale, got: \(value)"
        )
    }

    func testStaleAndDisconnectedTabsAreDistinguishableAtTheAccessibilitySurface() throws {
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let stale = MockChannelController(type: .shell, label: "Recovered", state: .stale)
        stale.recoveryActionOverride = .recreateBrokerSession
        let disconnected = MockChannelController(type: .shell, label: "Shell", state: .disconnected)

        view.updateTabs(channels: [stale, disconnected], activeId: disconnected.channelId)

        let buttons = tabButtons(in: view)
        let staleButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == stale.channelId.uuidString })
        let disconnectedButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == disconnected.channelId.uuidString })

        XCTAssertEqual(staleButton.accessibilityValue() as? String, "stale: recreate session")
        let disconnectedValue = disconnectedButton.accessibilityValue() as? String ?? ""
        XCTAssertFalse(
            disconnectedValue.hasPrefix("stale:"),
            "A disconnected tab must not carry stale guidance, got: \(disconnectedValue)"
        )
    }

    // MARK: - Helpers

    private func tabButtons(in view: TabBarView) -> [NSButton] {
        view.subviews
            .compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView }
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
    }
}
