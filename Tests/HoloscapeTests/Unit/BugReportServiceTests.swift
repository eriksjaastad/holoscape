import XCTest
@testable import Holoscape

final class BugReportServiceTests: XCTestCase {
    private var session: URLSession!
    private var networkService: BugReportService!

    private let pendingDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".holoscape/pending-reports")

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BugReportURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        networkService = BugReportService(
            endpoint: URL(string: "https://reports.test/reports")!,
            session: session
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
        if let files = try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
