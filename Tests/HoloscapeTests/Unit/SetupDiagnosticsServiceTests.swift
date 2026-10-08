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
        XCTAssertFalse(configService.save(.default))

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

    func testSnapshotSurfacesCommittedSaveDiagnosticWithoutClaimingDefaults() throws {
        let configDir = temporaryConfigDir()
        enum InjectedFailure: Error { case directorySync }
        var replacementCommitted = false
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { source, destination in
                try DurableAtomicFileCommitter.replaceFile(at: source, with: destination)
                replacementCommitted = true
            },
            synchronizeDirectory: { _ in
                if replacementCommitted { throw InjectedFailure.directorySync }
            },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let configService = ConfigService(configDir: configDir, persistence: persistence)
        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Visible Committed Font"
        XCTAssertFalse(configService.save(config))
        XCTAssertEqual(configService.load().appearance.fontFamily, config.appearance.fontFamily)
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { true },
            diagnosticsDirectoryReadableProvider: { true },
            brokerFailureProvider: { nil }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .authorized)
        let item = try XCTUnwrap(snapshot.items.first { $0.title == "Config file" })
        XCTAssertEqual(item.severity, .failure)
        XCTAssertTrue(item.detail.contains("Config save failed"))
        XCTAssertTrue(item.recovery?.contains("current in-memory configuration remains active") == true)
        XCTAssertFalse(item.recovery?.contains("safe defaults") == true)
        XCTAssertFalse(item.recovery?.contains("repair the JSON") == true)
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

    func testSnapshotSurfacesProjectTrackerPluginConfigurationFailureWithoutBlockingCore() {
        let configService = ConfigService(configDir: temporaryConfigDir())
        let failure = PluginFailureState(
            pluginID: ProjectTrackerPlugin.pluginID,
            displayName: "Project Tracker",
            message: "Project Tracker plugin endpoint is invalid: project-tracker.local"
        )
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { true },
            diagnosticsDirectoryReadableProvider: { true },
            brokerFailureProvider: { nil },
            pluginStartupSnapshotProvider: {
                PluginStartupSnapshot(states: [.failed(failure)])
            }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .authorized)

        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Plugins"
                && item.severity == .failure
                && item.detail.contains("Project Tracker")
                && item.detail.contains("endpoint is invalid")
                && item.recovery?.contains("terminal startup continues") == true
        })
        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Broker host launch" && item.severity == .ok
        })
    }

    func testSnapshotReportsPluginsOkWhenPluginManagerHasNoFailures() {
        let configService = ConfigService(configDir: temporaryConfigDir())
        let service = SetupDiagnosticsService(
            configService: configService,
            accessibilityTrustProvider: { true },
            diagnosticsDirectoryReadableProvider: { true },
            brokerFailureProvider: { nil },
            pluginStartupSnapshotProvider: {
                PluginStartupSnapshot(states: [
                    .ready(
                        .init(
                            plan: ProjectTrackerPluginRuntimePlan(
                                pluginID: ProjectTrackerPlugin.pluginID,
                                displayName: "Project Tracker",
                                endpoint: URL(string: "http://localhost:8000")!,
                                healthURL: URL(string: "http://localhost:8000/health")!,
                                storageNamespace: "project-tracker",
                                capabilities: [.channelProvider, .commandProvider, .statusAdapter],
                                permissions: [.networkLocalhost, .filesystemPluginStorage]
                            ),
                            contributions: .empty
                        )
                    ),
                ])
            }
        )

        let snapshot = service.makeSnapshot(notificationStatus: .authorized)

        XCTAssertTrue(snapshot.items.contains { item in
            item.title == "Plugins"
                && item.severity == .ok
                && item.detail.contains("1 ready")
                && item.recovery == nil
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
