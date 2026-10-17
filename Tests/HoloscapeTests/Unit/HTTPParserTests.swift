import Foundation
import XCTest
@testable import Holoscape

final class HTTPParserTests: XCTestCase {
    func testDeclaredBodyBeyondRequestLimitIsRejectedBeforeBodyArrives() {
        let request = Data(
            "POST /channels HTTP/1.1\r\nContent-Length: 129\r\n\r\n".utf8
        )

        let outcome = HTTPParser.parse(request, maximumRequestBytes: 128)

        guard case .payloadTooLarge = outcome else {
            return XCTFail("Expected payloadTooLarge, got \(outcome)")
        }
    }

    func testRequestBufferRejectsChunkThatWouldCrossLimit() {
        let accumulated = Data(repeating: 0x41, count: 96)
        let incoming = Data(repeating: 0x42, count: 33)

        XCTAssertNil(
            HoloscapeAPIServer.appendingRequestData(
                incoming,
                to: accumulated,
                maximumBytes: 128
            )
        )
    }
}
