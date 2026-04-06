import XCTest
@testable import Holoscape

final class BugReportServiceTests: XCTestCase {

    private let pendingDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".holoscape/pending-reports")

    private func cleanPendingDir() {
        try? FileManager.default.removeItem(at: pendingDir)
    }

    override func tearDown() {
        if let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    private func makeBugReport() -> BugReport {
        BugReport(
            channelName: "Shell",
            channelType: .shell,
            lastOutputLines: ["line1", "line2"],
            timestamp: Date(),
            macOSVersion: "15.0",
            description: "test bug",
            appVersion: "1.0",
            hardwareModel: "Mac",
            allChannelStates: nil,
            appearanceConfig: nil,
            splitLayout: nil,
            uptime: 60,
            historyBuffer: nil,
            screenshotData: nil
        )
    }

    private func makeCrashReport() -> CrashReport {
        CrashReport(
            crashTrace: "crash trace here",
            lastChannelState: nil,
            timestamp: Date(),
            macOSVersion: "15.0",
            appVersion: "1.0",
            hardwareModel: "Mac",
            historySnapshot: nil
        )
    }

    func testSavePendingBugReport() {
        let service = BugReportService()
        service.savePendingBugReport(makeBugReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let bugFiles = files?.filter { $0.lastPathComponent.hasPrefix("bug-") } ?? []
        XCTAssertGreaterThan(bugFiles.count, 0, "Bug report should be saved to pending directory")
    }

    func testSavePendingCrashReport() {
        let service = BugReportService()
        service.savePendingCrashReport(makeCrashReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let crashFiles = files?.filter { $0.lastPathComponent.hasPrefix("crash-") } ?? []
        XCTAssertGreaterThan(crashFiles.count, 0, "Crash report should be saved to pending directory")
    }

    func testPendingDirectoryCreatedOnDemand() {
        cleanPendingDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDir.path), "Pending dir should not exist after cleanup")

        let service = BugReportService()
        service.savePendingBugReport(makeBugReport())

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDir.path), "Pending dir should be recreated on save")
    }

    func testSavedReportIsValidJSON() {
        let service = BugReportService()
        service.savePendingBugReport(makeBugReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let bugFiles = files?.filter { $0.lastPathComponent.hasPrefix("bug-") } ?? []
        guard let file = bugFiles.last else {
            XCTFail("No bug report file found")
            return
        }

        guard let data = try? Data(contentsOf: file) else {
            XCTFail("Failed to read saved report file")
            return
        }
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), "Saved report should be valid JSON")
    }

    func testSavedReportDecodable() {
        let service = BugReportService()
        let original = makeBugReport()
        service.savePendingBugReport(original)

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let bugFiles = files?.filter { $0.lastPathComponent.hasPrefix("bug-") } ?? []
        guard let file = bugFiles.last else {
            XCTFail("No bug report file found")
            return
        }

        guard let data = try? Data(contentsOf: file) else {
            XCTFail("Failed to read saved report file")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(BugReport.self, from: data) else {
            XCTFail("Failed to decode saved report")
            return
        }
        XCTAssertEqual(decoded.channelName, "Shell")
        XCTAssertEqual(decoded.description, "test bug")
    }

    func testMultipleReportsSavedSeparately() {
        let service = BugReportService()
        service.savePendingBugReport(makeBugReport())
        service.savePendingBugReport(makeBugReport())
        service.savePendingCrashReport(makeCrashReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let reportFiles = files?.filter { $0.pathExtension == "json" } ?? []
        XCTAssertGreaterThanOrEqual(reportFiles.count, 3, "Each save should create a separate file")
    }

    func testAgingDeletesOldReports() throws {
        let service = BugReportService()
        service.savePendingBugReport(makeBugReport())

        let files = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        guard let bugFile = files.first(where: { $0.lastPathComponent.hasPrefix("bug-") }) else {
            XCTFail("No bug report file found")
            return
        }

        // Backdate the file to 31 days ago
        let oldDate = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.creationDate: oldDate], ofItemAtPath: bugFile.path)

        // Run retry (which should age out the old file)
        service.retryPendingReports()

        // Poll for file deletion instead of fixed sleep
        let startTime = Date()
        while FileManager.default.fileExists(atPath: bugFile.path) {
            if Date().timeIntervalSince(startTime) > 5 {
                XCTFail("Aging did not delete old report within 5 seconds")
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        // File was deleted — test passes
    }
}
