import XCTest
@testable import HoloscapeMCP

final class HoloscapeClientTests: XCTestCase {
    private var session: URLSession!
    private var client: HoloscapeClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HoloscapeClientURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        client = HoloscapeClient(baseURL: "http://holoscape.test", session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        HoloscapeClientURLProtocolStub.removeHandler()
        client = nil
        session = nil
        super.tearDown()
    }

    func testCreateChannelPreservesRequestAndDecodesObjectResponse() async throws {
        HoloscapeClientURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "http://holoscape.test/channels")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try Self.requestBody(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, [
                "type": "shell",
                "dir": "/tmp/project",
                "label": "Build",
                "cmd": "swift test",
            ])
            return Self.response(statusCode: 201, body: #"{"id":"channel-1","label":"Build"}"#)
        }

        let result = try await client.createChannel(
            type: "shell",
            dir: "/tmp/project",
            label: "Build",
            cmd: "swift test"
        )

        XCTAssertEqual(result["id"] as? String, "channel-1")
        XCTAssertEqual(result["label"] as? String, "Build")
    }

    func testObjectEndpointsRejectMalformedOrWrongShapedJSON() async {
        await assertInvalidResponse(body: "not-json") {
            try await client.createChannel(type: "shell", dir: nil, label: nil, cmd: nil)
        }
        await assertInvalidResponse(body: "[]") {
            try await client.switchChannel(id: "channel-1")
        }
        await assertInvalidResponse(body: "[]") {
            try await client.closeChannel(id: "channel-1")
        }
        await assertInvalidResponse(body: "[]") {
            try await client.sendInput(id: "channel-1", text: "pwd\n")
        }
        await assertInvalidResponse(body: "[]") {
            try await client.readOutput(id: "channel-1")
        }
    }

    func testListChannelsRejectsWrongShapedJSON() async {
        await assertInvalidResponse(body: "{}") {
            try await client.listChannels()
        }
    }

    func testAllHTTPMethodsRejectNonSuccessStatus() async {
        for statusCode in [300, 404, 503] {
            HoloscapeClientURLProtocolStub.setHandler { request in
                XCTAssertTrue(["GET", "POST", "DELETE"].contains(request.httpMethod ?? ""))
                return Self.response(statusCode: statusCode, body: #"{"error":"not ready"}"#)
            }

            await assertHTTPError(statusCode: statusCode) {
                try await client.listChannels()
            }
            await assertHTTPError(statusCode: statusCode) {
                try await client.createChannel(type: "shell", dir: nil, label: nil, cmd: nil)
            }
            await assertHTTPError(statusCode: statusCode) {
                try await client.closeChannel(id: "channel-1")
            }
        }
    }

    func testEveryRequestUsesBoundedLocalAPITimeout() async throws {
        HoloscapeClientURLProtocolStub.setHandler { request in
            XCTAssertGreaterThan(request.timeoutInterval, 0)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
            let body = request.httpMethod == "GET" ? "[]" : "{}"
            return Self.response(statusCode: 200, body: body)
        }

        _ = try await client.listChannels()
        _ = try await client.createChannel(type: "shell", dir: nil, label: nil, cmd: nil)
        _ = try await client.closeChannel(id: "channel-1")
    }

    func testTransportFailureUsesStableConnectionFailedError() async {
        HoloscapeClientURLProtocolStub.setHandler { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await client.listChannels()
            XCTFail("Expected connection failure")
        } catch {
            XCTAssertEqual(error as? HoloscapeError, .connectionFailed)
        }
    }

    func testTaskCancellationIsNotMisreportedAsConnectionFailure() async {
        HoloscapeClientURLProtocolStub.setHandler { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await client.listChannels()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
    }

    private func assertInvalidResponse<T>(
        body: String,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        HoloscapeClientURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: body)
        }

        do {
            _ = try await operation()
            XCTFail("Expected invalid response", file: file, line: line)
        } catch {
            guard case HoloscapeError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertHTTPError<T>(
        statusCode: Int,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected HTTP error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HoloscapeError, .httpError(statusCode: statusCode), file: file, line: line)
        }
    }

    private static func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 {
                break
            }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func response(statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "http://holoscape.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class HoloscapeClientURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.withLock {
            handler = newHandler
        }
    }

    static func removeHandler() {
        lock.withLock {
            handler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentHandler = Self.lock.withLock { Self.handler }
        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: HoloscapeError.invalidResponse)
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
