import XCTest
@testable import Holoscape

final class BugReportServiceTests: XCTestCase {
    private var session: URLSession!
    private var networkService: BugReportService!
    private var pendingDir: URL!

    override func setUp() {
        super.setUp()
        pendingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-pending-reports-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BugReportURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        networkService = BugReportService(
            endpoint: URL(string: "https://reports.test/reports")!,
            session: session,
            pendingDirectory: pendingDir
        )
    }

    private func cleanPendingDir() {
        try? FileManager.default.removeItem(at: pendingDir)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        BugReportURLProtocolStub.removeHandler()
        networkService = nil
        session = nil
        try? FileManager.default.removeItem(at: pendingDir)
        pendingDir = nil
        super.tearDown()
    }

    private func makeBugReport(timestamp: Date = Date()) -> BugReport {
        BugReport(
            channelName: "Shell",
            channelType: .shell,
            lastOutputLines: ["line1", "line2"],
            timestamp: timestamp,
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

    private func makeCrashReport(timestamp: Date = Date()) -> CrashReport {
        CrashReport(
            crashTrace: "crash trace here",
            lastChannelState: nil,
            timestamp: timestamp,
            macOSVersion: "15.0",
            appVersion: "1.0",
            hardwareModel: "Mac",
            historySnapshot: nil
        )
    }

    func testSubmitBugReportPostsISO8601PayloadAndDecodesSuccessful2xxResponse() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        BugReportURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://reports.test/reports/bug")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try Self.requestJSON(from: request)
            XCTAssertEqual(json["channelName"] as? String, "Shell")
            XCTAssertEqual(json["description"] as? String, "test bug")
            try Self.assertISO8601Timestamp(json["timestamp"], equals: timestamp)
            return Self.response(statusCode: 201, body: #"{"success":true,"message":"received"}"#)
        }

        let response = try await networkService.submitBugReport(makeBugReport(timestamp: timestamp))

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "received")
    }

    func testSubmitCrashReportPostsISO8601PayloadAndPreservesAPIRejection() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        BugReportURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://reports.test/reports/crash")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try Self.requestJSON(from: request)
            XCTAssertEqual(json["crashTrace"] as? String, "crash trace here")
            try Self.assertISO8601Timestamp(json["timestamp"], equals: timestamp)
            return Self.response(statusCode: 202, body: #"{"success":false,"message":"duplicate"}"#)
        }

        let response = try await networkService.submitCrashReport(makeCrashReport(timestamp: timestamp))

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.message, "duplicate")
    }

    func testSubmissionsRejectNonSuccessStatusEvenWhenBodyClaimsSuccess() async {
        for statusCode in [300, 400, 503] {
            BugReportURLProtocolStub.setHandler { _ in
                Self.response(statusCode: statusCode, body: #"{"success":true,"message":"accepted"}"#)
            }

            await assertServiceError(.httpError(statusCode: statusCode)) {
                try await networkService.submitBugReport(makeBugReport())
            }
            await assertServiceError(.httpError(statusCode: statusCode)) {
                try await networkService.submitCrashReport(makeCrashReport())
            }
        }
    }

    func testSubmissionRejectsNonHTTPResponse() async {
        BugReportURLProtocolStub.setHandler { request in
            (
                URLResponse(
                    url: try XCTUnwrap(request.url),
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }

        await assertServiceError(.nonHTTPResponse) {
            try await networkService.submitBugReport(makeBugReport())
        }
    }

    func testSubmissionRejectsMalformedResponseBody() async {
        BugReportURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: "not-json")
        }

        await assertServiceError(.invalidResponse) {
            try await networkService.submitCrashReport(makeCrashReport())
        }
    }

    func testSubmissionPropagatesTransportFailure() async {
        BugReportURLProtocolStub.setHandler { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await networkService.submitBugReport(makeBugReport())
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testSubmissionFailureFeedbackPreservesSpecificErrorAndRetryStatus() {
        let httpError = BugReportServiceError.httpError(statusCode: 503)
        XCTAssertEqual(
            MainWindowController.bugReportSubmissionFailureMessage(for: httpError),
            "Report server returned HTTP status 503. Report saved locally for retry."
        )

        let transportError = URLError(.notConnectedToInternet)
        XCTAssertEqual(
            MainWindowController.bugReportSubmissionFailureMessage(for: transportError),
            "Network error: \(transportError.localizedDescription). Report saved locally for retry."
        )
    }

    func testSubmissionFailureFeedbackReportsPersistenceFailure() {
        let submissionError = BugReportServiceError.httpError(statusCode: 503)
        let persistenceError = CocoaError(.fileWriteNoPermission)

        XCTAssertEqual(
            MainWindowController.bugReportSubmissionFailureMessage(
                for: submissionError,
                persistenceError: persistenceError
            ),
            "Report server returned HTTP status 503. Report could not be saved locally: \(persistenceError.localizedDescription)"
        )
    }

    func testSavePendingBugReportPropagatesFilesystemFailure() throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-report-parent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        let service = BugReportService(pendingDirectory: parentFile.appendingPathComponent("reports"))

        XCTAssertThrowsError(try service.savePendingBugReport(makeBugReport()))
    }

    func testSavePendingBugReport() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingBugReport(makeBugReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let bugFiles = files?.filter { $0.lastPathComponent.hasPrefix("bug-") } ?? []
        XCTAssertGreaterThan(bugFiles.count, 0, "Bug report should be saved to pending directory")
    }

    func testSavePendingCrashReport() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingCrashReport(makeCrashReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let crashFiles = files?.filter { $0.lastPathComponent.hasPrefix("crash-") } ?? []
        XCTAssertGreaterThan(crashFiles.count, 0, "Crash report should be saved to pending directory")
    }

    func testPendingDirectoryCreatedOnDemand() throws {
        cleanPendingDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDir.path), "Pending dir should not exist after cleanup")

        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingBugReport(makeBugReport())

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDir.path), "Pending dir should be recreated on save")
    }

    func testSavedReportIsValidJSON() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingBugReport(makeBugReport())

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

    func testSavedReportDecodable() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        let original = makeBugReport()
        try service.savePendingBugReport(original)

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

    func testMultipleReportsSavedSeparately() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingBugReport(makeBugReport())
        try service.savePendingBugReport(makeBugReport())
        try service.savePendingCrashReport(makeCrashReport())

        let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        let reportFiles = files?.filter { $0.pathExtension == "json" } ?? []
        XCTAssertGreaterThanOrEqual(reportFiles.count, 3, "Each save should create a separate file")
    }

    func testRetryPendingReportsReturnsAfterAcceptedReportIsRemoved() async throws {
        BugReportURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: #"{"success":true,"message":"received"}"#)
        }
        try networkService.savePendingBugReport(makeBugReport())

        let summary = await networkService.retryPendingReports()

        XCTAssertEqual(summary.discoveredCount, 1)
        XCTAssertEqual(summary.retriedCount, 1)
        XCTAssertEqual(summary.expiredCount, 0)
        XCTAssertTrue(summary.failures.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRetryPendingReportsRetainsAndReportsMalformedSavedReport() async throws {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let file = pendingDir.appendingPathComponent("bug-malformed.json")
        try Data("not-json".utf8).write(to: file)

        let summary = await networkService.retryPendingReports()

        XCTAssertEqual(summary.failures.map(\.stage), [.decode])
        XCTAssertEqual(summary.failures.first?.fileName, file.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRetryPendingReportsRetainsAndReportsServerRejection() async throws {
        BugReportURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: #"{"success":false,"message":"duplicate"}"#)
        }
        try networkService.savePendingCrashReport(makeCrashReport())

        let summary = await networkService.retryPendingReports()

        XCTAssertEqual(summary.failures.map(\.stage), [.rejected])
        XCTAssertEqual(summary.failures.first?.message, "duplicate")
        let remaining = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 1)
    }

    func testRetryPendingReportsReportsEnumerationFailure() async throws {
        let directoryPathOccupiedByFile = pendingDir.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: directoryPathOccupiedByFile)
        let service = BugReportService(pendingDirectory: directoryPathOccupiedByFile)

        let summary = await service.retryPendingReports()

        XCTAssertEqual(summary.discoveredCount, 0)
        XCTAssertEqual(summary.failures.map(\.stage), [.enumerate])
        XCTAssertNil(summary.failures.first?.fileName)
    }

    func testRetryPendingReportsTreatsOnlyMissingDirectoryAsEmpty() async {
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDir.path))
        let missingService = BugReportService(pendingDirectory: pendingDir)
        let inaccessibleService = BugReportService(
            pendingDirectory: pendingDir,
            directoryContents: { _ in throw CocoaError(.fileReadNoPermission) }
        )

        let missingSummary = await missingService.retryPendingReports()
        let inaccessibleSummary = await inaccessibleService.retryPendingReports()

        XCTAssertEqual(missingSummary, PendingReportRetrySummary())
        XCTAssertEqual(inaccessibleSummary.failures.map(\.stage), [.enumerate])
    }

    func testRetryPendingReportsReportsMetadataFailureWithoutSubmitting() async throws {
        try networkService.savePendingBugReport(makeBugReport())
        BugReportURLProtocolStub.setHandler { _ in
            XCTFail("Metadata failure must retain the report without submitting it")
            return Self.response(statusCode: 200, body: #"{"success":true}"#)
        }
        let service = BugReportService(
            endpoint: URL(string: "https://reports.test/reports")!,
            session: session,
            pendingDirectory: pendingDir,
            creationDate: { _ in throw CocoaError(.fileReadNoPermission) }
        )

        let summary = await service.retryPendingReports()

        XCTAssertEqual(summary.failures.map(\.stage), [.metadata])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil).count, 1)
    }

    func testRetryPendingReportsReportsReadFailureWithoutSubmitting() async throws {
        try networkService.savePendingBugReport(makeBugReport())
        BugReportURLProtocolStub.setHandler { _ in
            XCTFail("Read failure must retain the report without submitting it")
            return Self.response(statusCode: 200, body: #"{"success":true}"#)
        }
        let service = BugReportService(
            endpoint: URL(string: "https://reports.test/reports")!,
            session: session,
            pendingDirectory: pendingDir,
            creationDate: { _ in nil },
            dataReader: { _ in throw CocoaError(.fileReadCorruptFile) }
        )

        let summary = await service.retryPendingReports()

        XCTAssertEqual(summary.failures.map(\.stage), [.read])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil).count, 1)
    }

    func testRetryPendingReportsReportsTransportFailureAndRetainsReport() async throws {
        try networkService.savePendingCrashReport(makeCrashReport())
        BugReportURLProtocolStub.setHandler { _ in throw URLError(.notConnectedToInternet) }

        let summary = await networkService.retryPendingReports()

        XCTAssertEqual(summary.failures.map(\.stage), [.submit])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil).count, 1)
    }

    func testRetryPendingReportsReportsRemovalFailureAfterAcceptance() async throws {
        try networkService.savePendingBugReport(makeBugReport())
        BugReportURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: #"{"success":true,"message":"received"}"#)
        }
        let service = BugReportService(
            endpoint: URL(string: "https://reports.test/reports")!,
            session: session,
            pendingDirectory: pendingDir,
            fileRemover: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        let summary = await service.retryPendingReports()

        XCTAssertEqual(summary.retriedCount, 0)
        XCTAssertEqual(summary.failures.map(\.stage), [.remove])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil).count, 1)
        XCTAssertTrue(summary.logMessage.contains("discovered=1, retried=0, expired=0, failures=1"))
        XCTAssertTrue(summary.logMessage.contains("[remove]"))
    }

    func testAgingDeletesOldReports() throws {
        let service = BugReportService(pendingDirectory: pendingDir)
        try service.savePendingBugReport(makeBugReport())

        let files = try FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        guard let bugFile = files.first(where: { $0.lastPathComponent.hasPrefix("bug-") }) else {
            XCTFail("No bug report file found")
            return
        }

        // Backdate the file to 31 days ago
        let oldDate = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.creationDate: oldDate], ofItemAtPath: bugFile.path)

        // Run retry (which should age out the old file)
        let completion = expectation(description: "retry completes")
        Task {
            _ = await service.retryPendingReports()
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)

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

    private func assertServiceError<T>(
        _ expected: BugReportServiceError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BugReportServiceError, expected, file: file, line: line)
        }
    }

    private static func requestJSON(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func assertISO8601Timestamp(_ value: Any?, equals expected: Date) throws {
        let timestamp = try XCTUnwrap(value as? String)
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        XCTAssertEqual(parsed, expected)
    }

    private static func response(statusCode: Int, body: String) -> (URLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://reports.test/reports")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class BugReportURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler }
    }

    static func removeHandler() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let currentHandler = Self.lock.withLock { Self.handler }
        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
