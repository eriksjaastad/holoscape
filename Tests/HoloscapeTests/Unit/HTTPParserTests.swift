import Foundation
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
}
