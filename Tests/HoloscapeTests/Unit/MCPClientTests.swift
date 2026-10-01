import XCTest
@testable import Holoscape

final class MCPClientTests: XCTestCase {
    private var session: URLSession!
    private var client: MCPClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPClientURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        client = MCPClient(endpoint: URL(string: "http://mcp.test/rpc")!, session: session)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        MCPClientURLProtocolStub.removeHandler()
        client = nil
        session = nil
        super.tearDown()
    }

    func testSendBeforeInitializeFailsWithoutMakingRequest() async {
        MCPClientURLProtocolStub.setHandler { _ in
            XCTFail("Uninitialized send must not make a request")
            return Self.response(statusCode: 500, body: "")
        }

        do {
            _ = try await client.sendMessage("hello")
            XCTFail("Expected notInitialized")
        } catch {
            guard case MCPClient.MCPError.notInitialized = error else {
                return XCTFail("Expected notInitialized, got \(error)")
            }
        }
    }

    func testInitializeAndSendAcceptSuccessful2xxResponses() async throws {
        MCPClientURLProtocolStub.setHandler { request in
            let body = try Self.requestJSON(from: request)
            switch body["method"] as? String {
            case "initialize":
                XCTAssertNotNil(body["id"])
                return Self.response(statusCode: 201, body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
            case "notifications/initialized":
                XCTAssertNil(body["id"])
                return Self.response(statusCode: 204, body: "")
            case "tools/call":
                let params = try XCTUnwrap(body["params"] as? [String: Any])
                let arguments = try XCTUnwrap(params["arguments"] as? [String: String])
                XCTAssertEqual(arguments["message"], "hello")
                return Self.response(
                    statusCode: 200,
                    body: #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"world"}]}}"#
                )
            default:
                XCTFail("Unexpected method: \(String(describing: body["method"]))")
                return Self.response(statusCode: 500, body: "")
            }
        }

        try await client.initialize()
        let initialized = await client.isInitialized
        XCTAssertTrue(initialized)
        let reply = try await client.sendMessage("hello")
        XCTAssertEqual(reply, "world")
    }

    func testInitializeRejectsNonSuccessRequestStatus() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 503, body: #"{"error":"unavailable"}"#)
        }

        await assertConnectionFailure(statusCode: 503) {
            try await client.initialize()
        }
        let initialized = await client.isInitialized
        XCTAssertFalse(initialized)
    }

    func testRejectedInitializedNotificationLeavesClientUninitialized() async {
        MCPClientURLProtocolStub.setHandler { request in
            let body = try Self.requestJSON(from: request)
            if body["method"] as? String == "initialize" {
                return Self.response(statusCode: 200, body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
            }
            return Self.response(statusCode: 403, body: #"{"error":"notification rejected"}"#)
        }

        await assertConnectionFailure(statusCode: 403) {
            try await client.initialize()
        }
        let initialized = await client.isInitialized
        XCTAssertFalse(initialized)
    }

    func testJSONRPCErrorEnvelopeIsSurfaced() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(
                statusCode: 200,
                body: #"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"bad request"}}"#
            )
        }

        do {
            try await client.initialize()
            XCTFail("Expected protocol error")
        } catch {
            guard case let MCPClient.MCPError.protocolError(code, message) = error else {
                return XCTFail("Expected protocolError, got \(error)")
            }
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(message, "bad request")
        }
    }

    func testResponseWithMismatchedIDIsRejected() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(
                statusCode: 200,
                body: #"{"jsonrpc":"2.0","id":999,"result":{}}"#
            )
        }

        await assertInvalidResponse {
            try await client.initialize()
        }
    }

    func testResponseWithoutIDIsRejected() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(
                statusCode: 200,
                body: #"{"jsonrpc":"2.0","result":{}}"#
            )
        }

        await assertInvalidResponse {
            try await client.initialize()
        }
    }

    func testResponseWithInvalidJSONRPCVersionIsRejected() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(
                statusCode: 200,
                body: #"{"jsonrpc":"1.0","id":1,"result":{}}"#
            )
        }

        await assertInvalidResponse {
            try await client.initialize()
        }
    }

    func testToolErrorResultIsSurfacedInsteadOfReturnedAsReply() async throws {
        MCPClientURLProtocolStub.setHandler { request in
            let body = try Self.requestJSON(from: request)
            switch body["method"] as? String {
            case "initialize":
                return Self.response(
                    statusCode: 200,
                    body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#
                )
            case "notifications/initialized":
                return Self.response(statusCode: 204, body: "")
            case "tools/call":
                XCTAssertEqual(body["id"] as? Int, 2)
                return Self.response(
                    statusCode: 200,
                    body: #"{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"delivery rejected"}]}}"#
                )
            default:
                XCTFail("Unexpected method: \(String(describing: body["method"]))")
                return Self.response(statusCode: 500, body: "")
            }
        }

        try await client.initialize()
        do {
            _ = try await client.sendMessage("hello")
            XCTFail("Expected tool error")
        } catch {
            guard case let MCPClient.MCPError.toolError(message) = error else {
                return XCTFail("Expected toolError, got \(error)")
            }
            XCTAssertEqual(message, "delivery rejected")
            XCTAssertEqual(error.localizedDescription, "MCP tool error: delivery rejected")
        }
    }

    func testMalformedResponseIsRejected() async {
        MCPClientURLProtocolStub.setHandler { _ in
            Self.response(statusCode: 200, body: #"{"jsonrpc":"2.0","id":1}"#)
        }

        do {
            try await client.initialize()
            XCTFail("Expected invalidResponse")
        } catch {
            guard case MCPClient.MCPError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    private func assertConnectionFailure(
        statusCode: Int,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected connection failure", file: file, line: line)
        } catch {
            guard case let MCPClient.MCPError.connectionFailed(actualStatusCode) = error else {
                return XCTFail("Expected connectionFailed, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(actualStatusCode, statusCode, file: file, line: line)
        }
    }

    private func assertInvalidResponse(
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalid response", file: file, line: line)
        } catch {
            guard case MCPClient.MCPError.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)", file: file, line: line)
            }
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

    private static func response(statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "http://mcp.test/rpc")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class MCPClientURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

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
            client?.urlProtocol(self, didFailWithError: MCPClient.MCPError.invalidResponse)
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
