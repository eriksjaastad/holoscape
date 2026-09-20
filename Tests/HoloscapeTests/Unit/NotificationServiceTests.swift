import AppKit
import UserNotifications
import XCTest
@testable import Holoscape

@MainActor
final class NotificationServiceTests: XCTestCase {
    private final class FakeNotificationCenter: NotificationCenterClient {
        var delegate: UNUserNotificationCenterDelegate?
        var requestCount = 0
        var addRequests: [UNNotificationRequest] = []
        var grantAuthorization = true

        func requestAuthorization(
            options: UNAuthorizationOptions,
            completionHandler: @escaping @Sendable (Bool, Error?) -> Void
        ) {
            requestCount += 1
            completionHandler(grantAuthorization, nil)
        }

        func add(_ request: UNNotificationRequest) {
            addRequests.append(request)
        }
    }

    private final class TestChannel: ChannelController {
        let channelId = UUID(uuidString: "00000000-0000-0000-0000-000000007172")!
        let channelType: ChannelType
        let displayLabel = "Codex"
        var hasUnread = false
        let state: ChannelState = .active
        let contentView = NSView(frame: .zero)
        let commandHistory = CommandHistory()
        weak var delegate: ChannelControllerDelegate?
        var activatedAt: Date?

        init(channelType: ChannelType) {
            self.channelType = channelType
        }

        func sendInput(_ text: String) {}
        func activate() {}
        func deactivate() {}
        func retry() {}
        func lastLines(_ count: Int) -> [String] { [] }
        func applyPersistentState(_ state: PersistentChannelState) {}
    }

    func testInitDoesNotRequestNotificationAuthorization() {
        let center = FakeNotificationCenter()

        _ = NotificationService(
            configService: ConfigService(configDir: temporaryConfigDir()),
            notificationCenter: center,
            appIsActive: { false }
        )

        XCTAssertEqual(center.requestCount, 0, "First launch must not trigger a macOS notification permission prompt before the user sees app context")
    }

    func testFirstEligibleBackgroundNotificationRequestsPermissionThenDelivers() {
        let center = FakeNotificationCenter()
        let service = NotificationService(
            configService: ConfigService(configDir: temporaryConfigDir()),
            notificationCenter: center,
            appIsActive: { false }
        )

        service.notifyIfNeeded(channel: TestChannel(channelType: .agentDirect), firstLine: "needs approval")

        XCTAssertEqual(center.requestCount, 1)
        waitUntil { center.addRequests.count == 1 }
        XCTAssertEqual(center.addRequests.count, 1)
        XCTAssertEqual(center.addRequests.first?.content.title, "Codex")
        XCTAssertEqual(center.addRequests.first?.content.body, "needs approval")
    }

    func testActiveAppDoesNotRequestPermissionOrDeliverNotification() {
        let center = FakeNotificationCenter()
        let service = NotificationService(
            configService: ConfigService(configDir: temporaryConfigDir()),
            notificationCenter: center,
            appIsActive: { true }
        )

        service.notifyIfNeeded(channel: TestChannel(channelType: .agentDirect), firstLine: "ignored")

        XCTAssertEqual(center.requestCount, 0)
        XCTAssertTrue(center.addRequests.isEmpty)
    }

    func testDisabledNotificationConfigDoesNotRequestPermission() {
        let center = FakeNotificationCenter()
        let configService = ConfigService(configDir: temporaryConfigDir())
        var config = HoloscapeConfig.default
        config.notifications = NotificationConfig(enabled: false, perChannelType: nil)
        configService.save(config)
        let service = NotificationService(
            configService: configService,
            notificationCenter: center,
            appIsActive: { false }
        )

        service.notifyIfNeeded(channel: TestChannel(channelType: .agentDirect), firstLine: "ignored")

        XCTAssertEqual(center.requestCount, 0)
        XCTAssertTrue(center.addRequests.isEmpty)
    }

    private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationServiceTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
