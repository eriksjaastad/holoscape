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
            "POST /channels HTTP/1.1\r\nContent-Length: 129\r\nContent-Length: 2\r\n\r\n{}".utf8
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
    private func makeServer() -> HoloscapeAPIServer {
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
            port: 0
        )
    }
}

private final class RecordingHTTPServerConnection: HTTPServerConnection, @unchecked Sendable {
    private let data: Data?
    private let isComplete: Bool
    private let error: NWError?
    private(set) var sentContent: Data?
    private(set) var cancelCallCount = 0

    init(data: Data?, isComplete: Bool, error: NWError?) {
        self.data = data
        self.isComplete = isComplete
        self.error = error
    }

    func start(queue: DispatchQueue) {}

    func receive(completion: @escaping @Sendable (Data?, Bool, NWError?) -> Void) {
        completion(data, isComplete, error)
    }

    func send(content: Data, completion: @escaping @Sendable () -> Void) {
        sentContent = content
        completion()
    }

    func cancel() {
        cancelCallCount += 1
    }
}
