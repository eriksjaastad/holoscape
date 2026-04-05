import AppKit
import UserNotifications

@MainActor
protocol NotificationChannelSwitchDelegate: AnyObject {
    func switchToChannel(_ id: UUID)
}

@MainActor
class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var authorized: Bool = false
    private let configService: ConfigService
    weak var channelSwitchDelegate: NotificationChannelSwitchDelegate?

    init(configService: ConfigService) {
        self.configService = configService
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    func notifyIfNeeded(channel: any ChannelController, firstLine: String) {
        guard authorized else { return }
        guard !NSApp.isActive else { return }

        let config = configService.load()
        let notifConfig = config.notifications ?? .default
        guard notifConfig.isEnabled(for: channel.channelType) else { return }

        let content = UNMutableNotificationContent()
        content.title = channel.displayLabel
        content.body = String(firstLine.prefix(100))
        content.threadIdentifier = channel.channelId.uuidString
        content.userInfo = ["channelId": channel.channelId.uuidString]

        let request = UNNotificationRequest(
            identifier: channel.channelId.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let idString = userInfo["channelId"] as? String,
           let channelId = UUID(uuidString: idString) {
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.channelSwitchDelegate?.switchToChannel(channelId)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Don't show notifications while app is active
        completionHandler([])
    }
}
