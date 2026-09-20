import AppKit
import UserNotifications

@MainActor
protocol NotificationChannelSwitchDelegate: AnyObject {
    func switchToChannel(_ id: UUID)
}

protocol NotificationCenterClient: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, Error?) -> Void
    )
    func add(_ request: UNNotificationRequest)
}

final class SystemNotificationCenterClient: NotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func add(_ request: UNNotificationRequest) {
        center.add(request)
    }
}

@MainActor
class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var authorized: Bool = false
    private var authorizationRequested = false
    private let configService: ConfigService
    private let notificationCenter: NotificationCenterClient
    private let appIsActive: () -> Bool
    weak var channelSwitchDelegate: NotificationChannelSwitchDelegate?

    init(
        configService: ConfigService,
        notificationCenter: NotificationCenterClient = SystemNotificationCenterClient(),
        appIsActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.configService = configService
        self.notificationCenter = notificationCenter
        self.appIsActive = appIsActive
        super.init()
        self.notificationCenter.delegate = self
    }

    func requestAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    func notifyIfNeeded(channel: any ChannelController, firstLine: String) {
        guard !appIsActive() else { return }

        let config = configService.load()
        let notifConfig = config.notifications ?? .default
        guard notifConfig.isEnabled(for: channel.channelType) else { return }

        if authorized {
            deliverNotification(channel: channel, firstLine: firstLine)
            return
        }

        let pendingPayload = makeNotificationPayload(channel: channel, firstLine: firstLine)
        guard !authorizationRequested else { return }
        authorizationRequested = true
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorized = granted
                if granted {
                    self.notificationCenter.add(self.makeNotificationRequest(from: pendingPayload))
                }
            }
        }
    }

    private func deliverNotification(channel: any ChannelController, firstLine: String) {
        notificationCenter.add(makeNotificationRequest(from: makeNotificationPayload(channel: channel, firstLine: firstLine)))
    }

    private struct NotificationPayload: Sendable {
        let channelID: UUID
        let title: String
        let body: String
    }

    private func makeNotificationPayload(channel: any ChannelController, firstLine: String) -> NotificationPayload {
        NotificationPayload(
            channelID: channel.channelId,
            title: channel.displayLabel,
            body: String(firstLine.prefix(100))
        )
    }

    private func makeNotificationRequest(from payload: NotificationPayload) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.threadIdentifier = payload.channelID.uuidString
        content.userInfo = ["channelId": payload.channelID.uuidString]

        return UNNotificationRequest(
            identifier: payload.channelID.uuidString,
            content: content,
            trigger: nil
        )
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
