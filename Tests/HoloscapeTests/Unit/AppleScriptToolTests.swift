import XCTest
import MCP
@testable import HoloscapeMCP

final class AppleScriptToolTests: XCTestCase {
    func testAppleScriptSourceRequiresNonEmptySource() throws {
        XCTAssertThrowsError(try appleScriptSource(from: [:])) { error in
            XCTAssertEqual(error as? AppleScriptToolError, .missingSource)
        }

        XCTAssertThrowsError(try appleScriptSource(from: ["source": .string("   \n\t")])) { error in
            XCTAssertEqual(error as? AppleScriptToolError, .missingSource)
        }
    }

    func testAppleScriptSourceTrimsWhitespace() throws {
        let source = try appleScriptSource(from: ["source": .string("  return 1  \n")])
        XCTAssertEqual(source, "return 1")
    }

    func testRunAppleScriptToolReturnsResultText() throws {
        let result = try runAppleScriptTool(args: ["source": .string("return \"holoscape\"")])

        XCTAssertEqual(result.source, "return \"holoscape\"")
        XCTAssertEqual(result.output, "holoscape")
        XCTAssertEqual(formatAppleScriptToolResult(result), "result:\nholoscape")
    }

    func testRunAppleScriptToolSurfacesExecutionErrors() throws {
        XCTAssertThrowsError(try runAppleScriptTool(args: ["source": .string("error \"boom\" number 1234")])) { error in
            XCTAssertEqual(error as? AppleScriptToolError, .executionFailed(number: 1234, message: "boom"))
        }
    }

    func testDescriptorFormattingHandlesPrimitiveResults() throws {
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor(boolean: true)), "true")
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor(int32: 42)), "42")
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor.null()), "(no result)")
    }
}
