import Foundation
import XCTest
@testable import Holoscape

final class HTTPResponseTests: XCTestCase {
    func testJSONPreservesValidPayloadAndRequestedStatus() throws {
        let response = HTTPResponse.json(["status": "created"], status: 201)

        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(response.statusText, "Created")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: String]
        )
        XCTAssertEqual(payload, ["status": "created"])
    }

    func testJSONSerializationFailureReturnsTruthfulInternalServerError() throws {
        let response = HTTPResponse.json(["created_at": Date()], status: 200)

        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(response.statusText, "Internal Server Error")
        XCTAssertFalse(response.body.isEmpty)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: String]
        )
        XCTAssertEqual(payload, ["error": "Failed to encode JSON response"])
    }
}
