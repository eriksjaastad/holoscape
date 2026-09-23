import AppKit
import ApplicationServices
import Foundation
import UserNotifications

struct SetupDiagnosticItem: Equatable, Sendable {
    enum Severity: String, Sendable {
        case ok
        case warning
        case failure
    }

    let title: String
    let severity: Severity
    let detail: String
    let recovery: String?
    let settingsURL: URL?

    init(
        title: String,
        severity: Severity,
        detail: String,
        recovery: String?,
        settingsURL: URL? = nil
    ) {
        self.title = title
        self.severity = severity
        self.detail = detail
        self.recovery = recovery
        self.settingsURL = settingsURL
    }
}

struct SetupDiagnosticsSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let items: [SetupDiagnosticItem]

    var hasProblems: Bool {
        items.contains { $0.severity != .ok }
    }
}

final class BrokerHostLaunchDiagnosticStore: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: SetupDiagnosticItem?

    func recordLaunchFailure(executablePath: String, message: String) {
        let item = SetupDiagnosticItem(
            title: "Broker host launch",
            severity: .failure,
            detail: "Could not launch broker host at \(executablePath): \(message)",
            recovery: "Rebuild Holoscape and verify the app bundle contains the broker host helper. Broker-backed terminal sessions intentionally do not fall back in-process."
        )
        lock.lock()
        failure = item
        lock.unlock()
    }

    func clearLaunchFailure() {
        lock.lock()
        failure = nil
        lock.unlock()
    }

    func lastLaunchFailure() -> SetupDiagnosticItem? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

enum BrokerHostLaunchDiagnostics {
    private static let store = BrokerHostLaunchDiagnosticStore()

    static func recordLaunchFailure(executablePath: String, message: String) {
        store.recordLaunchFailure(executablePath: executablePath, message: message)
    }

    static func clearLaunchFailure() {
        store.clearLaunchFailure()
    }

    static func lastLaunchFailure() -> SetupDiagnosticItem? {
        store.lastLaunchFailure()
    }
}

typealias NotificationAuthorizationStatusProvider = (@escaping @Sendable (UNAuthorizationStatus) -> Void) -> Void

@MainActor
final class SetupDiagnosticsService {
    private let configService: ConfigService
    private let notificationSettingsProvider: NotificationAuthorizationStatusProvider
    private let accessibilityTrustProvider: () -> Bool
    private let diagnosticsDirectoryReadableProvider: () -> Bool
    private let brokerFailureProvider: () -> SetupDiagnosticItem?
    private let pluginStartupSnapshotProvider: () -> PluginStartupSnapshot
    private let now: () -> Date

    init(
        configService: ConfigService,
        notificationSettingsProvider: @escaping NotificationAuthorizationStatusProvider = { completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(settings.authorizationStatus)
            }
        },
        accessibilityTrustProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
        diagnosticsDirectoryReadableProvider: @escaping () -> Bool = {
            let diagnosticsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports")
            return FileManager.default.isReadableFile(atPath: diagnosticsURL.path)
        },
        brokerFailureProvider: @escaping () -> SetupDiagnosticItem? = { BrokerHostLaunchDiagnostics.lastLaunchFailure() },
        pluginStartupSnapshotProvider: (() -> PluginStartupSnapshot)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.configService = configService
        self.notificationSettingsProvider = notificationSettingsProvider
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.diagnosticsDirectoryReadableProvider = diagnosticsDirectoryReadableProvider
        self.brokerFailureProvider = brokerFailureProvider
        self.pluginStartupSnapshotProvider = pluginStartupSnapshotProvider ?? {
            PluginManager(config: configService.load()).prepareStartup()
        }
        self.now = now
    }

    func snapshot(completion: @escaping @Sendable (SetupDiagnosticsSnapshot) -> Void) {
        notificationSettingsProvider { [weak self] notificationStatus in
            Task { @MainActor [weak self] in
                guard let self else { return }
                completion(self.makeSnapshot(notificationStatus: notificationStatus))
            }
        }
    }

    func makeSnapshot(notificationStatus: UNAuthorizationStatus) -> SetupDiagnosticsSnapshot {
        var items: [SetupDiagnosticItem] = []
        items.append(configDiagnosticItem())
        if let brokerFailure = brokerFailureProvider() {
            items.append(brokerFailure)
        } else {
            items.append(SetupDiagnosticItem(
                title: "Broker host launch",
                severity: .ok,
                detail: "No broker host launch failure recorded in this run.",
                recovery: nil
            ))
        }
        items.append(notificationDiagnosticItem(status: notificationStatus))
        items.append(accessibilityDiagnosticItem(isTrusted: accessibilityTrustProvider()))
        items.append(automationDiagnosticItem())
        items.append(crashDiagnosticsItem(isReadable: diagnosticsDirectoryReadableProvider()))
        items.append(pluginDiagnosticItem(snapshot: pluginStartupSnapshotProvider()))
        return SetupDiagnosticsSnapshot(capturedAt: now(), items: items)
    }

    private func configDiagnosticItem() -> SetupDiagnosticItem {
        guard let diagnostic = configService.lastDiagnostic else {
            return SetupDiagnosticItem(
                title: "Config file",
                severity: .ok,
                detail: "Config loaded/saved without recorded errors.",
                recovery: nil
            )
        }
        let verb = diagnostic.operation.rawValue
        return SetupDiagnosticItem(
            title: "Config file",
            severity: .failure,
            detail: "Config \(verb) failed at \(diagnostic.configPath): \(diagnostic.message)",
            recovery: "Fix permissions or repair the JSON file. Holoscape is using safe defaults and does not overwrite malformed config automatically."
        )
    }

    private func notificationDiagnosticItem(status: UNAuthorizationStatus) -> SetupDiagnosticItem {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return SetupDiagnosticItem(
                title: "Notifications",
                severity: .ok,
                detail: "macOS notification authorization is \(label(for: status)).",
                recovery: nil
            )
        case .denied:
            return SetupDiagnosticItem(
                title: "Notifications",
                severity: .warning,
                detail: "macOS notification authorization is denied.",
                recovery: "Open System Settings > Notifications > Holoscape and enable notifications if you want off-screen channel alerts.",
                settingsURL: SystemSettingsURL.notifications
            )
        case .notDetermined:
            return SetupDiagnosticItem(
                title: "Notifications",
                severity: .warning,
                detail: "macOS notification authorization has not been requested yet. Holoscape defers this prompt until the first eligible background notification.",
                recovery: "No action is required unless you want to pre-grant notifications in System Settings > Notifications.",
                settingsURL: SystemSettingsURL.notifications
            )
        @unknown default:
            return SetupDiagnosticItem(
                title: "Notifications",
                severity: .warning,
                detail: "macOS returned an unknown notification authorization state.",
                recovery: "Check System Settings > Notifications > Holoscape.",
                settingsURL: SystemSettingsURL.notifications
            )
        }
    }

    private func accessibilityDiagnosticItem(isTrusted: Bool) -> SetupDiagnosticItem {
        if isTrusted {
            return SetupDiagnosticItem(
                title: "Accessibility",
                severity: .ok,
                detail: "Holoscape is trusted for Accessibility automation.",
                recovery: nil
            )
        }
        return SetupDiagnosticItem(
            title: "Accessibility",
            severity: .warning,
            detail: "Holoscape is not currently trusted for Accessibility automation.",
            recovery: "If agent or setup workflows need UI control, enable Holoscape in System Settings > Privacy & Security > Accessibility.",
            settingsURL: SystemSettingsURL.accessibility
        )
    }

    private func automationDiagnosticItem() -> SetupDiagnosticItem {
        SetupDiagnosticItem(
            title: "Automation",
            severity: .warning,
            detail: "macOS tracks Automation permission per target app and may prompt when Holoscape first controls System Events or another app.",
            recovery: "Review System Settings > Privacy & Security > Automation after first use; enable the specific target apps Holoscape is allowed to control.",
            settingsURL: SystemSettingsURL.automation
        )
    }

    private func crashDiagnosticsItem(isReadable: Bool) -> SetupDiagnosticItem {
        if isReadable {
            return SetupDiagnosticItem(
                title: "Crash diagnostics",
                severity: .ok,
                detail: "Holoscape can read the current user's DiagnosticReports folder for recent Holoscape crash reports.",
                recovery: nil
            )
        }
        return SetupDiagnosticItem(
            title: "Crash diagnostics",
            severity: .warning,
            detail: "Holoscape cannot read ~/Library/Logs/DiagnosticReports, so recent-crash detection may miss reports.",
            recovery: "Do not grant broad Full Disk Access by default. If crash detection matters on this machine, open System Settings > Privacy & Security > Full Disk Access and enable Holoscape intentionally.",
            settingsURL: SystemSettingsURL.fullDiskAccess
        )
    }

    private func pluginDiagnosticItem(snapshot: PluginStartupSnapshot) -> SetupDiagnosticItem {
        let failures = snapshot.failures
        guard failures.isEmpty else {
            let detail = failures.map { failure in
                "\(failure.displayName) (\(failure.pluginID)): \(failure.message)"
            }.joined(separator: "\n")
            return SetupDiagnosticItem(
                title: "Plugins",
                severity: .failure,
                detail: detail,
                recovery: "Fix the plugin configuration or disable the affected plugin. Holoscape terminal startup continues without plugin contributions."
            )
        }

        let readyCount = snapshot.states.filter { state in
            if case .ready = state { return true }
            return false
        }.count
        let disabledCount = snapshot.states.filter { state in
            if case .disabled = state { return true }
            return false
        }.count
        return SetupDiagnosticItem(
            title: "Plugins",
            severity: .ok,
            detail: "Plugin startup prepared with \(readyCount) ready and \(disabledCount) disabled plugin(s).",
            recovery: nil
        )
    }

    private func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}

enum SystemSettingsURL {
    static let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
