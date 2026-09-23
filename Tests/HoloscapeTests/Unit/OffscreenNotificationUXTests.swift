import XCTest
@testable import Holoscape

@MainActor
final class OffscreenNotificationUXTests: XCTestCase {
    func testDockBadgeCountsOnlyUnmutedPendingNotificationChannels() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            HoloscapeAPIServer.dockBadgeLabel(
                notificationChannelIds: [first, second, third],
                mutedChannelIds: [second],
                activeChannelId: nil
            ),
            "2"
        )
    }

    func testDockBadgeClearsWhenAllPendingNotificationChannelsAreMuted() {
        let first = UUID()
        let second = UUID()

        XCTAssertNil(
            HoloscapeAPIServer.dockBadgeLabel(
                notificationChannelIds: [first, second],
                mutedChannelIds: [first, second],
                activeChannelId: nil
            )
        )
    }

    func testDockBadgeIgnoresActiveChannelNotification() {
        let active = UUID()
        let offscreen = UUID()

        XCTAssertEqual(
            HoloscapeAPIServer.dockBadgeLabel(
                notificationChannelIds: [active, offscreen],
                mutedChannelIds: [],
                activeChannelId: active
            ),
            "1"
        )
    }

    func testCodexHookEventsAreEligibleForOffscreenAttention() {
        XCTAssertEqual(
            HoloscapeAPIServer.offscreenAttentionKind(type: "awaiting_approval", tool: "codex"),
            .needsApproval
        )
        XCTAssertEqual(
            HoloscapeAPIServer.offscreenAttentionKind(type: "response_completed", tool: "codex"),
            .ready
        )
    }

    func testUnknownHookEventsDoNotRequestOffscreenAttention() {
        XCTAssertNil(HoloscapeAPIServer.offscreenAttentionKind(type: "token_delta", tool: "codex"))
    }
}
