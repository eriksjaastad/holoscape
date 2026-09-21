import UserNotifications
import XCTest
@testable import Holoscape

@MainActor
final class SetupDiagnosticsServiceTests: XCTestCase {
    func testSnapshotSurfacesConfigDiagnosticAndPermissionState() throws {
        let configDir = temporaryConfigDir()
        let configURL = configDir.appendingPathComponent("config.json")
        try "{ broken json".write(to: configURL, atomically: true, encoding: .utf8)
        let configService = ConfigService(configDir: configDir)
        _ = configService.load()

        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { false },
            diagnosticsDirectoryReadableProvider: { true },
            brokerFailureProvider: { nil },
            now: { Date(timeIntervalSince1970: 123) }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .denied)

        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 123))
        XCTAssertTrue(snapshot.hasProblems)
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Config file"
                && item.severity == .failure
                && item.detail.contains(configURL.path)
                && item.recovery?.contains("does not overwrite malformed config") == true
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Notifications"
                && item.severity == .warning
                && item.detail.contains("denied")
                && item.settingsURL == SystemSettingsURL.notifications
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Accessibility"
                && item.severity == .warning
                && item.recovery?.contains("Privacy & Security > Accessibility") == true
                && item.settingsURL == SystemSettingsURL.accessibility
        })
    }

    func testSnapshotSurfacesBrokerHostLaunchFailure() {
        let configService = ConfigService(configDir: temporaryConfigDir())
        let brokerFailure = SetupDiagnosticItem(
            title: "Broker host launch",
            severity: .failure,
            detail: "Could not launch broker host at /missing/helper: file missing",
            recovery: "Rebuild Holoscape"
        )
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { true },
            diagnosticsDirectoryReadableProvider: { true },
            brokerFailureProvider: { brokerFailure }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .authorized)

        XCTAssertTrue(snapshot.items.contains(brokerFailure))
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Notifications" && item.severity == .ok
        })
    }

    func testBrokerHostLaunchDiagnosticsRecorderKeepsLatestFailure() {
        BrokerHostLaunchDiagnostics.clearLaunchFailure()

        BrokerHostLaunchDiagnostics.recordLaunchFailure(
            executablePath: "/tmp/missing-broker",
            message: "No such file"
        )

        let item = BrokerHostLaunchDiagnostics.lastLaunchFailure()
        XCTAssertEqual(item?.title, "Broker host launch")
        XCTAssertEqual(item?.severity, .failure)
        XCTAssertTrue(item?.detail.contains("/tmp/missing-broker") == true)
        XCTAssertTrue(item?.recovery?.contains("do not fall back in-process") == true)

        BrokerHostLaunchDiagnostics.clearLaunchFailure()
        XCTAssertNil(BrokerHostLaunchDiagnostics.lastLaunchFailure())
    }

    func testSnapshotWarnsWhenCrashDiagnosticsDirectoryIsUnreadable() {
        let configService = ConfigService(configDir: temporaryConfigDir())
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { true },
            diagnosticsDirectoryReadableProvider: { false },
            brokerFailureProvider: { nil }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .authorized)

        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Crash diagnostics"
                && item.severity == .warning
                && item.detail.contains("DiagnosticReports")
                && item.recovery?.contains("Full Disk Access") == true
                && item.settingsURL == SystemSettingsURL.fullDiskAccess
        })
    }

    func testSnapshotIncludesSystemSettingsLinksForActionablePermissionRows() {
        let configService = ConfigService(configDir: temporaryConfigDir())
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { false },
            diagnosticsDirectoryReadableProvider: { false },
            brokerFailureProvider: { nil }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .notDetermined)

        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Notifications" && item.settingsURL == SystemSettingsURL.notifications
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Accessibility" && item.settingsURL == SystemSettingsURL.accessibility
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Automation" && item.settingsURL == SystemSettingsURL.automation
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Crash diagnostics" && item.settingsURL == SystemSettingsURL.fullDiskAccess
        })
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupDiagnosticsServiceTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
