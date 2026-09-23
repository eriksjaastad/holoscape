import XCTest
@testable import Holoscape

@MainActor
final class ChannelRenderSnapshotTests: XCTestCase {
    func testHighestPriorityPersistentStateWinsForApprovalErrorAndStale() {
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000007439")!
        let base = ChannelRenderSnapshot(
            channelID: channelID,
            channelType: .agentDirect,
            displayLabel: "Codex",
            isActive: true,
            hasUnread: false,
            persistentState: PersistentChannelState(kind: .running, source: .processLifecycle),
            recoveryAction: nil,
            agentIdentity: .codex,
            lastInteractionAt: Date(timeIntervalSince1970: 100),
            capturedAt: Date(timeIntervalSince1970: 200)
        )

        let merged = base.replacingStateWithHighestPriority([
            PersistentChannelState(kind: .running, source: .terminalOutput),
            PersistentChannelState(kind: .needsApproval, source: .agentAdapter),
            PersistentChannelState(kind: .error, source: .processLifecycle, reason: "broker write failed"),
            PersistentChannelState(kind: .stale, source: .brokerRegistry, recoveryAction: .recreateBrokerSession),
        ])

        XCTAssertEqual(merged.persistentState.kind, .stale)
        XCTAssertEqual(merged.recoveryAction, .recreateBrokerSession)
        XCTAssertEqual(merged.agentIdentity, .codex)
        XCTAssertEqual(merged.lastInteractionAt, Date(timeIntervalSince1970: 100))
    }

    func testReactiveUniformsConsumeImmutableRenderSnapshotWithSkinsOff() {
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000007440")!
        let renderSnapshot = ChannelRenderSnapshot(
            channelID: channelID,
            channelType: .shell,
            displayLabel: "Shell",
            isActive: true,
            hasUnread: true,
            persistentState: PersistentChannelState(kind: .needsApproval, source: .agentAdapter)
        )
        let reactive = ReactiveUniformSnapshot()
        let skinlessContext = SkinContext(surfaces: [:], reactive: reactive)

        reactive.applyChannelRenderSnapshot(renderSnapshot)

        XCTAssertEqual(reactive.channelId, renderSnapshot.channelIDOrdinal)
        XCTAssertEqual(reactive.channelIsActive, 1)
        XCTAssertEqual(reactive.channelUnread, 1)
        XCTAssertEqual(reactive.agentState, PersistentChannelStateKind.needsApproval.reactiveAgentStateOrdinal)
        XCTAssertEqual(reactive.channelConnectionState, PersistentChannelStateKind.needsApproval.reactiveChannelConnectionOrdinal)
        XCTAssertNotNil(skinlessContext.currentState(for: .tabBarTabActive))
    }

    func testTerminalRenderSnapshotSelectsActiveChannelWithoutExternalDependencies() {
        let activeID = UUID(uuidString: "00000000-0000-0000-0000-000000007441")!
        let inactiveID = UUID(uuidString: "00000000-0000-0000-0000-000000007442")!
        let active = ChannelRenderSnapshot(
            channelID: activeID,
            channelType: .shell,
            displayLabel: "Active Shell",
            isActive: true,
            hasUnread: false,
            persistentState: PersistentChannelState(kind: .ready, source: .processLifecycle)
        )
        let inactive = ChannelRenderSnapshot(
            channelID: inactiveID,
            channelType: .agentDirect,
            displayLabel: "Inactive Agent",
            isActive: false,
            hasUnread: true,
            persistentState: PersistentChannelState(kind: .error, source: .agentAdapter, reason: "failed")
        )

        let terminal = TerminalRenderSnapshot(activeChannelID: activeID, channels: [inactive, active])

        XCTAssertEqual(terminal.activeChannel, active)
        XCTAssertEqual(terminal.channels.map(\.displayLabel), ["Inactive Agent", "Active Shell"])
    }
}
