import AppKit
import XCTest
@testable import Holoscape

final class GroupChatV2Tests: XCTestCase {

    override func tearDown() {
        GroupChatURLProtocolStub.removeHandler()
        super.tearDown()
    }

    @MainActor
    func testSendInputSurfacesNonSuccessHTTPResponse() async throws {
        let requestReceived = expectation(description: "send request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            XCTAssertEqual(request.url?.path, "/send")
            XCTAssertEqual(request.httpMethod, "POST")
            requestReceived.fulfill()
            return Self.httpResponse(for: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )

        controller.sendInput("hello")

        await fulfillment(of: [requestReceived], timeout: 1)
        try await waitForLine(containing: "Failed to send: Server returned HTTP 503", in: controller)
    }

    @MainActor
    func testPollingRejectsNonHTTPResponseWithoutMarkingChannelActive() async throws {
        let requestReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            requestReceived.fulfill()
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: "application/json",
                expectedContentLength: 2,
                textEncodingName: "utf-8"
            )
            return GroupChatURLProtocolStub.StubResponse(response: response, data: Data("{}".utf8))
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )
        defer { controller.deactivate() }

        controller.activate()

        await fulfillment(of: [requestReceived], timeout: 1)
        try await waitForLine(containing: "Connection failed: Server returned a non-HTTP response", in: controller)
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testPollingRejectsMalformedSuccessBodyWithoutMarkingChannelActive() async throws {
        let requestReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            requestReceived.fulfill()
            return Self.httpResponse(for: request, statusCode: 200, body: "not-json")
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )
        defer { controller.deactivate() }

        controller.activate()

        await fulfillment(of: [requestReceived], timeout: 1)
        try await waitForLine(containing: "Connection failed: Server returned malformed messages", in: controller)
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testPollingRejectsNonSuccessHTTPResponseWithoutMarkingChannelActive() async throws {
        let requestReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            requestReceived.fulfill()
            return Self.httpResponse(for: request, statusCode: 503, body: #"{"messages":[]}"#)
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )
        defer { controller.deactivate() }

        controller.activate()

        await fulfillment(of: [requestReceived], timeout: 1)
        try await waitForLine(containing: "Connection failed: Server returned HTTP 503", in: controller)
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testPollingPreservesAuthenticationFailureHandling() async throws {
        let requestReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            requestReceived.fulfill()
            return Self.httpResponse(for: request, statusCode: 401, body: #"{"error":"unauthorized"}"#)
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "bad-key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )
        defer { controller.deactivate() }

        controller.activate()

        await fulfillment(of: [requestReceived], timeout: 1)
        try await waitForLine(containing: "Authentication failed. Check API key.", in: controller)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testDeactivateCancelsInvalidEndpointReconnectTimer() async throws {
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "http://[",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil
        )

        controller.activate()
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testLateInvalidPollingResponseDoesNotReactivateDeactivatedChannel() async throws {
        let requestReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            requestReceived.fulfill()
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: "application/json",
                expectedContentLength: 2,
                textEncodingName: "utf-8"
            )
            return GroupChatURLProtocolStub.StubResponse(
                response: response,
                data: Data("{}".utf8),
                delay: 0.1
            )
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )

        controller.activate()
        await fulfillment(of: [requestReceived], timeout: 1)
        controller.deactivate()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertFalse(controller.lastLines(20).contains { $0.contains("Connection failed") })
    }

    @MainActor
    func testPollingSerializesRequestsWhenResponseLatencyExceedsInterval() async throws {
        let firstRequestStarted = expectation(description: "first poll started")
        let requestCount = LockedCounter()
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            if requestCount.increment() == 1 {
                firstRequestStarted.fulfill()
            }
            return Self.httpResponse(
                for: request,
                statusCode: 200,
                body: #"{"messages":[{"sender":"claude","body":"slow success","ts":"2026-09-30T23:00:00.000Z"}]}"#,
                delay: 0.2
            )
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session,
            pollInterval: 0.05
        )
        defer { controller.deactivate() }

        controller.activate()
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        try await Task.sleep(for: .milliseconds(125))

        XCTAssertEqual(requestCount.current, 1)
        try await waitForLine(containing: "slow success", in: controller)
        XCTAssertEqual(controller.state, .active)
    }

    @MainActor
    func testSuccessfulSendAndPollingPreserveCurrentBehavior() async throws {
        let sendReceived = expectation(description: "send request received")
        let pollReceived = expectation(description: "poll request received")
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        GroupChatURLProtocolStub.setHandler { request in
            switch request.url?.path {
            case "/send":
                sendReceived.fulfill()
                return Self.httpResponse(for: request, statusCode: 204, body: "")
            case "/messages":
                pollReceived.fulfill()
                return Self.httpResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"messages":[{"sender":"claude","body":"ready","ts":"2026-09-30T23:00:00.000Z"}]}"#
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return Self.httpResponse(for: request, statusCode: 404, body: "")
            }
        }
        let controller = GroupChatChannelController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: nil,
            session: session
        )
        defer { controller.deactivate() }

        controller.sendInput("hello")
        controller.activate()

        await fulfillment(of: [sendReceived, pollReceived], timeout: 1)
        try await waitForLine(containing: "ready", in: controller)
        XCTAssertEqual(controller.state, .active)
        XCTAssertNotNil(controller.activatedAt)
        XCTAssertFalse(controller.lastLines(20).contains { $0.contains("[Error]") })
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupChatURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        body: String,
        delay: TimeInterval = 0
    ) -> GroupChatURLProtocolStub.StubResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return GroupChatURLProtocolStub.StubResponse(
            response: response,
            data: Data(body.utf8),
            delay: delay
        )
    }

    @MainActor
    private func waitForLine(
        containing expected: String,
        in controller: GroupChatChannelController
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if controller.lastLines(20).contains(where: { $0.contains(expected) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for line containing: \(expected). Lines: \(controller.lastLines(20))")
    }

    @MainActor
    func testV2DisplayLabelWithLabel() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Group Chat", instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "Group Chat")
    }

    @MainActor
    func testV2DisplayLabelWithInstance() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Group Chat", instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "Group Chat 2")
    }

    @MainActor
    func testBuiltInGroupChatCreationPreservesAssignedInstanceNumber() {
        let controller = MainWindowController.builtInGroupChatController(
            id: UUID(),
            apiURL: "https://chat.example.com",
            apiKey: "key",
            label: "Chat",
            instanceNumber: 2
        )

        XCTAssertEqual(controller.instanceNumber, 2)
        XCTAssertEqual(controller.displayLabel, "Chat 2")
    }

    @MainActor
    func testNumberedGroupChatCustomLabelIsExactPresentationValue() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Group Chat", instanceNumber: 2)

        controller.setCustomDisplayLabel("Build")

        XCTAssertEqual(controller.displayLabel, "Build")
    }

    @MainActor
    func testV1ConvenienceInitDisplaysChat() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key")
        XCTAssertEqual(controller.displayLabel, "Chat")
    }

    @MainActor
    func testActivatedAtInitiallyNil() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Chat", instanceNumber: nil)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testDeactivateResetsActivatedAt() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Chat", instanceNumber: nil)
        controller.deactivate()
        XCTAssertNil(controller.activatedAt)
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testApiURLAndKeyAccessible() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com/", apiKey: "my-key", label: "Chat", instanceNumber: nil, apiKeyEnv: "MY_KEY_ENV")
        XCTAssertEqual(controller.apiURL, "https://chat.example.com")  // trailing slash stripped
        XCTAssertEqual(controller.apiKey, "my-key")
        XCTAssertEqual(controller.apiKeyEnv, "MY_KEY_ENV")
    }

    @MainActor
    func testMessageStylingDistinguishesUserFromAgentTurns() {
        let date = Date(timeIntervalSince1970: 0)
        let user = GroupChatChannelController.attributedMessage(sender: "erik", body: "Open the log", date: date)
        let agent = GroupChatChannelController.attributedMessage(sender: "claude", body: "Reading it now", date: date)

        XCTAssertTrue(user.string.contains("YOU"))
        XCTAssertTrue(agent.string.contains("CLAUDE"))

        let userAccent = user.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let agentAccent = agent.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(userAccent, agentAccent)

        let userBackground = user.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        let agentBackground = agent.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(userBackground, agentBackground)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.withLock { value }
    }

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class GroupChatURLProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubResponse: @unchecked Sendable {
        let response: URLResponse
        let data: Data
        let delay: TimeInterval

        init(response: URLResponse, data: Data, delay: TimeInterval = 0) {
            self.response = response
            self.data = data
            self.delay = delay
        }
    }

    typealias Handler = @Sendable (URLRequest) throws -> StubResponse

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
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let stub = try currentHandler(request)
            let deliver: @Sendable () -> Void = { [self, stub] in
                client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stub.data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if stub.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
            } else {
                deliver()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
