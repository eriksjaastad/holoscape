import Foundation
import Network
import XCTest
@testable import Holoscape

final class HTTPParserTests: XCTestCase {
    func testOversizedNumericDeclaredBodyProducesPayloadTooLargeResponse() throws {
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 184467440737095516160\r\n\r\n".utf8
        )

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 413)
        XCTAssertEqual(response.statusText, "Payload Too Large")
        XCTAssertTrue(String(decoding: response.serialize(), as: UTF8.self).hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
    }

    func testStreamedChunkCrossingLimitProducesPayloadTooLargeResponse() {
        let accumulated = Data(repeating: 0x41, count: 96)
        let incoming = Data(repeating: 0x42, count: 33)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: accumulated,
            incoming: incoming,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 413)
    }

    func testRepresentableDeclaredBodyBeyondTotalBudgetProducesPayloadTooLargeResponse() {
        let request = Data("POST /channels HTTP/1.1\r\nContent-Length: 129\r\n\r\n".utf8)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 413)
    }

    func testValidRequestAtExactLimitIsRouted() throws {
        let maximumBytes = 128
        var bodyLength = maximumBytes
        var header = Data()
        while true {
            header = Data("POST /channels HTTP/1.1\r\nContent-Length: \(bodyLength)\r\n\r\n".utf8)
            let adjustedLength = maximumBytes - header.count
            if adjustedLength == bodyLength { break }
            bodyLength = adjustedLength
        }
        let requestData = header + Data(repeating: 0x41, count: bodyLength)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: requestData,
            isComplete: false,
            maximumBytes: maximumBytes
        )

        guard case .route(let request) = decision else {
            return XCTFail("Expected route, got \(decision)")
        }
        XCTAssertEqual(requestData.count, maximumBytes)
        XCTAssertEqual(try XCTUnwrap(request.body).count, bodyLength)
    }

    func testIncompleteRequestPreservesBytesForNextReceive() {
        let partial = Data("POST /channels HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: partial,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .receiveMore(let accumulated) = decision else {
            return XCTFail("Expected receiveMore, got \(decision)")
        }
        XCTAssertEqual(accumulated, partial)
    }

    func testMalformedContentLengthProducesBadRequestResponse() {
        let request = Data("POST /channels HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testConflictingContentLengthsDoNotRouteRequest() {
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}".utf8
        )

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testIdenticalContentLengthsRouteRequest() throws {
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8
        )

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .route(let parsedRequest) = decision else {
            return XCTFail("Expected route, got \(decision)")
        }
        XCTAssertEqual(try XCTUnwrap(parsedRequest.body), Data("{}".utf8))
    }

    func testTransferEncodingWithContentLengthDoesNotRouteRequest() {
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        )

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testMalformedOrUnsupportedRequestLinesDoNotRouteRequest() {
        let requestLines = [
            "DELETE /channels/123",
            "DELETE /channels/123 HTTP/9.9"
        ]

        for requestLine in requestLines {
            let decision = HoloscapeAPIServer.requestReceiveDecision(
                accumulated: Data(),
                incoming: Data("\(requestLine)\r\n\r\n".utf8),
                isComplete: false,
                maximumBytes: 128
            )

            guard case .respond(let response) = decision else {
                return XCTFail("Expected response for \(requestLine), got \(decision)")
            }
            XCTAssertEqual(response.status, 400)
        }
    }

    func testUTF8BOMBeforeRequestLineDoesNotRouteRequest() {
        let request = Data([0xef, 0xbb, 0xbf]) + Data("GET /channels HTTP/1.1\r\n\r\n".utf8)

        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: request,
            isComplete: false,
            maximumBytes: 128
        )

        guard case .respond(let response) = decision else {
            return XCTFail("Expected response, got \(decision)")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testMalformedHeaderLinesDoNotRouteRequest() {
        let malformedHeaders = [
            "Content-Length 100",
            "Content-Length : 100",
            "X-Test:\u{0}"
        ]

        for header in malformedHeaders {
            let decision = HoloscapeAPIServer.requestReceiveDecision(
                accumulated: Data(),
                incoming: Data("POST /channels HTTP/1.1\r\n\(header)\r\n\r\n".utf8),
                isComplete: false,
                maximumBytes: 128
            )

            guard case .respond(let response) = decision else {
                return XCTFail("Expected response for \(header.debugDescription), got \(decision)")
            }
            XCTAssertEqual(response.status, 400)
        }
    }

    func testMalformedRequestTargetsDoNotRouteRequest() {
        let requestTargets = [
            "?",
            "/channels?bad=\u{0}",
            "/channels?bad=%GG",
            "/channels#fragment",
            "/channels\\input"
        ]

        for requestTarget in requestTargets {
            let decision = HoloscapeAPIServer.requestReceiveDecision(
                accumulated: Data(),
                incoming: Data("GET \(requestTarget) HTTP/1.1\r\n\r\n".utf8),
                isComplete: false,
                maximumBytes: 128
            )

            guard case .respond(let response) = decision else {
                return XCTFail("Expected response for \(requestTarget.debugDescription), got \(decision)")
            }
            XCTAssertEqual(response.status, 400)
        }
    }

    func testValidRequestTargetAndHeaderValueRoute() throws {
        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: Data("GET /channels?label=Agent%20One&filter=ready?now HTTP/1.1\r\nX-Test:\tvalue\r\n\r\n".utf8),
            isComplete: false,
            maximumBytes: 128
        )

        guard case .route(let request) = decision else {
            return XCTFail("Expected route, got \(decision)")
        }
        XCTAssertEqual(request.path, "/channels")
        XCTAssertEqual(request.queryParams["label"], "Agent One")
        XCTAssertEqual(request.queryParams["filter"], "ready?now")
    }

    func testHTTP10RequestRoutes() {
        let decision = HoloscapeAPIServer.requestReceiveDecision(
            accumulated: Data(),
            incoming: Data("GET /channels HTTP/1.0\r\n\r\n".utf8),
            isComplete: false,
            maximumBytes: 128
        )

        guard case .route = decision else {
            return XCTFail("Expected route, got \(decision)")
        }
    }

    @MainActor
    func testCompleteOversizedCallbackWithErrorSends413AndCancels() throws {
        let server = makeServer()
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8
        )
        let connection = RecordingHTTPServerConnection(
            data: request,
            isComplete: true,
            error: NWError.posix(.ECONNRESET)
        )

        server.handleConnection(connection)

        let response = try XCTUnwrap(connection.sentContent)
        let serialized = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(serialized.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
        XCTAssertTrue(serialized.contains("\r\nConnection: close\r\n"))
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    @MainActor
    func testCompleteValidCallbackWithErrorStillRoutesContent() async throws {
        let responseSent = expectation(description: "route response sent")
        let server = makeServer()
        let connection = RecordingHTTPServerConnection(
            receiveEvents: [
                .init(
                    data: Data("GET /channels HTTP/1.1\r\n\r\n".utf8),
                    isComplete: true,
                    error: NWError.posix(.ECONNRESET)
                )
            ],
            onSend: {
                responseSent.fulfill()
            }
        )

        server.handleConnection(connection)
        await fulfillment(of: [responseSent], timeout: 1)

        let response = try XCTUnwrap(connection.sentContent)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        XCTAssertEqual(connection.receiveCallCount, 1)
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    @MainActor
    func testIncompleteCallbackWithErrorCancelsWithoutAnotherReceive() {
        let server = makeServer()
        let connection = RecordingHTTPServerConnection(
            data: Data("POST /channels HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8),
            isComplete: false,
            error: NWError.posix(.ECONNRESET)
        )

        server.handleConnection(connection)

        XCTAssertNil(connection.sentContent)
        XCTAssertEqual(connection.receiveCallCount, 1)
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    @MainActor
    func testTerminalIncompleteCallbackSends400AndCancels() throws {
        let server = makeServer()
        let connection = RecordingHTTPServerConnection(
            data: Data("POST /channels HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8),
            isComplete: true,
            error: nil
        )

        server.handleConnection(connection)

        let response = try XCTUnwrap(connection.sentContent)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    @MainActor
    func testSendFailureIsReportedBeforeConnectionCancellation() throws {
        let events = OrderedEventRecorder()
        let server = makeServer(responseSendErrorReporter: { _ in
            events.record("sendError")
        })
        let connection = RecordingHTTPServerConnection(
            receiveEvents: [
                .init(data: Data("broken".utf8), isComplete: true, error: nil)
            ],
            sendError: NWError.posix(.EPIPE),
            onCancel: {
                events.record("cancel")
            }
        )

        server.handleConnection(connection)

        XCTAssertNotNil(connection.sentContent)
        XCTAssertEqual(connection.cancelCallCount, 1)
        XCTAssertEqual(events.values, ["sendError", "cancel"])
    }

    @MainActor
    func testSplitReadsReachRouteResponseAndCancel() async throws {
        let responseSent = expectation(description: "route response sent")
        let server = makeServer()
        let connection = RecordingHTTPServerConnection(
            receiveEvents: [
                .init(data: Data("GET /chan".utf8), isComplete: false, error: nil),
                .init(data: Data("nels HTTP/1.1\r\n\r\n".utf8), isComplete: false, error: nil)
            ],
            onSend: {
                responseSent.fulfill()
            }
        )

        server.handleConnection(connection)
        await fulfillment(of: [responseSent], timeout: 1)

        let response = try XCTUnwrap(connection.sentContent)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        XCTAssertEqual(connection.receiveCallCount, 2)
        XCTAssertEqual(connection.cancelCallCount, 1)
    }

    @MainActor
    private func makeServer(
        responseSendErrorReporter: @escaping @Sendable (NWError) -> Void = { _ in }
    ) -> HoloscapeAPIServer {
        let configService = ConfigService(
            configDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("HTTPParserTests-")
                .appendingPathComponent(UUID().uuidString)
        )
        let channelManager = ChannelManager(configService: configService)
        let windowController = MainWindowController(
            channelManager: channelManager,
            configService: configService
        )
        return HoloscapeAPIServer(
            channelManager: channelManager,
            windowController: windowController,
            port: 0,
            responseSendErrorReporter: responseSendErrorReporter
        )
    }
}

private final class RecordingHTTPServerConnection: HTTPServerConnection, @unchecked Sendable {
    struct ReceiveEvent {
        let data: Data?
        let isComplete: Bool
        let error: NWError?
    }

    private var receiveEvents: [ReceiveEvent]
    private let sendError: NWError?
    private let onSend: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private(set) var sentContent: Data?
    private(set) var cancelCallCount = 0
    private(set) var receiveCallCount = 0

    init(data: Data?, isComplete: Bool, error: NWError?) {
        receiveEvents = [.init(data: data, isComplete: isComplete, error: error)]
        sendError = nil
        onSend = {}
        onCancel = {}
    }

    init(
        receiveEvents: [ReceiveEvent],
        sendError: NWError? = nil,
        onSend: @escaping @Sendable () -> Void = {},
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.receiveEvents = receiveEvents
        self.sendError = sendError
        self.onSend = onSend
        self.onCancel = onCancel
    }

    func start(queue: DispatchQueue) {}

    func receive(completion: @escaping @Sendable (Data?, Bool, NWError?) -> Void) {
        receiveCallCount += 1
        let event = receiveEvents.removeFirst()
        completion(event.data, event.isComplete, event.error)
    }

    func send(content: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        sentContent = content
        completion(sendError)
        onSend()
    }

    func cancel() {
        cancelCallCount += 1
        onCancel()
    }
}

private final class OrderedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func record(_ value: String) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}
