import UserNotifications
import XCTest
@testable import Holoscape

@MainActor
final class OffscreenNotificationUXTests: XCTestCase {
    private final class FakeNotificationCenter: NotificationCenterClient {
        var delegate: UNUserNotificationCenterDelegate?
        var addRequests: [UNNotificationRequest] = []

        func requestAuthorization(
            options: UNAuthorizationOptions,
            completionHandler: @escaping @Sendable (Bool, Error?) -> Void
        ) {}

        func add(_ request: UNNotificationRequest) {
            addRequests.append(request)
        }

        func getNotificationSettings(
            completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void
        ) {}
    }


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

    func testDesktopNotificationDeliveryUsesInjectedOptionalCenter() {
        let channelID = UUID()
        let center = FakeNotificationCenter()

        HoloscapeAPIServer.sendDesktopNotification(
            type: "awaiting_approval",
            tool: "codex",
            channelID: channelID,
            channelLabel: "Codex",
            notificationCenter: nil
        )
        HoloscapeAPIServer.sendDesktopNotification(
            type: "awaiting_approval",
            tool: "codex",
            channelID: channelID,
            channelLabel: "Codex",
            notificationCenter: center
        )

        XCTAssertEqual(center.addRequests.count, 1)
        XCTAssertEqual(center.addRequests.first?.content.title, "Permission Needed")
    }
}
