import XCTest
@testable import Holoscape

final class PersistentChannelStateTests: XCTestCase {
    func testRuntimeStateMappingStartsWithCurrentLifecycleCompatibility() {
        XCTAssertEqual(PersistentChannelStateKind(runtimeState: .active), .running)
        XCTAssertEqual(PersistentChannelStateKind(runtimeState: .connecting), .running)
        XCTAssertEqual(PersistentChannelStateKind(runtimeState: .disconnected), .ready)
        XCTAssertEqual(PersistentChannelStateKind(runtimeState: .stale), .stale)
    }

    func testDisplayPriorityKeepsAttentionStatesAboveTransientRunning() {
        XCTAssertGreaterThan(PersistentChannelStateKind.needsApproval.displayPriority, PersistentChannelStateKind.running.displayPriority)
        XCTAssertGreaterThan(PersistentChannelStateKind.error.displayPriority, PersistentChannelStateKind.needsApproval.displayPriority)
        XCTAssertGreaterThan(PersistentChannelStateKind.stale.displayPriority, PersistentChannelStateKind.error.displayPriority)
    }

    func testOperatorAttentionAndRecoveryContract() {
        XCTAssertFalse(PersistentChannelStateKind.ready.requiresOperatorAttention)
        XCTAssertFalse(PersistentChannelStateKind.running.requiresOperatorAttention)
        XCTAssertTrue(PersistentChannelStateKind.needsApproval.requiresOperatorAttention)
        XCTAssertTrue(PersistentChannelStateKind.error.requiresOperatorAttention)
        XCTAssertTrue(PersistentChannelStateKind.stale.requiresOperatorAttention)

        XCTAssertFalse(PersistentChannelStateKind.needsApproval.isRecoverable)
        XCTAssertTrue(PersistentChannelStateKind.error.isRecoverable)
        XCTAssertTrue(PersistentChannelStateKind.stale.isRecoverable)
    }

    func testPersistentStateCodableRoundTripUsesStableRawValues() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let state = PersistentChannelState(
            kind: .needsApproval,
            source: .agentAdapter,
            updatedAt: timestamp,
            reason: "Claude permission prompt",
            recoveryAction: nil
        )

        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("needs-approval"))
        XCTAssertTrue(json.contains("agent-adapter"))

        let decoded = try JSONDecoder().decode(PersistentChannelState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testChannelMetadataDecodesWithoutPersistentStateForBackwardCompatibility() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "type": "shell",
          "role": "Shell"
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(ChannelMetadata.self, from: json)
        XCTAssertNil(metadata.persistentState)
        XCTAssertEqual(metadata.role, "Shell")
        XCTAssertEqual(metadata.type, .shell)
    }

    func testChannelMetadataEncodesPersistentState() throws {
        let metadata = ChannelMetadata(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            type: .agentDirect,
            role: "Agent",
            persistentState: PersistentChannelState(
                kind: .stale,
                source: .brokerRegistry,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
                reason: "missing broker session",
                recoveryAction: .recreateBrokerSession
            )
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(decoded.persistentState?.kind, .stale)
        XCTAssertEqual(decoded.persistentState?.source, .brokerRegistry)
        XCTAssertEqual(decoded.persistentState?.recoveryAction, .recreateBrokerSession)
    }

    func testPersistentKindsExposeStableReactiveOrdinalsForSkins() {
        XCTAssertEqual(PersistentChannelStateKind.ready.reactiveAgentStateOrdinal, 0)
        XCTAssertEqual(PersistentChannelStateKind.running.reactiveAgentStateOrdinal, 1)
        XCTAssertEqual(PersistentChannelStateKind.needsApproval.reactiveAgentStateOrdinal, 2)
        XCTAssertEqual(PersistentChannelStateKind.error.reactiveAgentStateOrdinal, 3)
        XCTAssertEqual(PersistentChannelStateKind.stale.reactiveAgentStateOrdinal, 3)

        XCTAssertEqual(PersistentChannelStateKind.ready.reactiveChannelConnectionOrdinal, 0)
        XCTAssertEqual(PersistentChannelStateKind.running.reactiveChannelConnectionOrdinal, 0)
        XCTAssertEqual(PersistentChannelStateKind.needsApproval.reactiveChannelConnectionOrdinal, 1)
        XCTAssertEqual(PersistentChannelStateKind.error.reactiveChannelConnectionOrdinal, 2)
        XCTAssertEqual(PersistentChannelStateKind.stale.reactiveChannelConnectionOrdinal, 3)

        XCTAssertEqual(PersistentChannelStateKind.ready.reactiveNotificationKindOrdinal, 0)
        XCTAssertEqual(PersistentChannelStateKind.running.reactiveNotificationKindOrdinal, 0)
        XCTAssertEqual(PersistentChannelStateKind.needsApproval.reactiveNotificationKindOrdinal, 2)
        XCTAssertEqual(PersistentChannelStateKind.error.reactiveNotificationKindOrdinal, 3)
        XCTAssertEqual(PersistentChannelStateKind.stale.reactiveNotificationKindOrdinal, 3)
    }

    func testReactiveSnapshotAppliesPersistentChannelState() {
        let snapshot = ReactiveUniformSnapshot()
        snapshot.applyPersistentChannelState(PersistentChannelState(kind: .needsApproval, source: .agentAdapter))

        XCTAssertEqual(snapshot.intValue(forMatchKey: "agentState"), 2)
        XCTAssertEqual(snapshot.intValue(forMatchKey: "channelConnectionState"), 1)
        XCTAssertEqual(snapshot.intValue(forMatchKey: "notificationKind"), 2)

        snapshot.applyPersistentChannelState(PersistentChannelState(kind: .stale, source: .brokerRegistry))

        XCTAssertEqual(snapshot.intValue(forMatchKey: "agentState"), 3)
        XCTAssertEqual(snapshot.intValue(forMatchKey: "channelConnectionState"), 3)
        XCTAssertEqual(snapshot.intValue(forMatchKey: "notificationKind"), 3)
    }
}
