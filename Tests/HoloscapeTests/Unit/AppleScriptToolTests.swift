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

    func testRunAppleScriptToolReturnsResultText() async throws {
        let result = try await runAppleScriptTool(
            args: ["source": .string("return \"holoscape\"")],
            maxOutputBytes: 32
        )

        XCTAssertEqual(result.source, "return \"holoscape\"")
        XCTAssertEqual(result.output, "holoscape")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertEqual(formatAppleScriptToolResult(result), "result:\nholoscape")
    }

    func testRunAppleScriptToolCapsStdoutAndReportsTruncation() async throws {
        let result = try await runAppleScriptTool(
            args: ["source": .string("return \"123456789\"")],
            maxOutputBytes: 5
        )

        XCTAssertEqual(result.output, "12345")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertTrue(formatAppleScriptToolResult(result).contains("stdoutTruncated: true"))
    }

    func testRunAppleScriptToolCapsStderrAndReportsTruncation() async throws {
        let result = try await runAppleScriptTool(
            args: ["source": .string("log \"abcdefghi\"\nreturn \"ok\"")],
            maxOutputBytes: 5
        )

        XCTAssertEqual(result.output, "ok")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertTrue(formatAppleScriptToolResult(result).contains("stderrTruncated: true"))
    }

    func testRunAppleScriptToolSurfacesExecutionErrors() async throws {
        do {
            _ = try await runAppleScriptTool(args: ["source": .string("error \"boom\" number 1234")])
            XCTFail("Expected AppleScript execution failure")
        } catch {
            XCTAssertEqual(error as? AppleScriptToolError, .executionFailed(number: 1234, message: "boom"))
        }
    }

    func testRunAppleScriptToolReportsTruncatedExecutionErrors() async throws {
        do {
            _ = try await runAppleScriptTool(
                args: ["source": .string("error \"abcdefghi\" number 1234")],
                maxOutputBytes: 5
            )
            XCTFail("Expected truncated AppleScript execution failure")
        } catch {
            XCTAssertEqual(
                error as? AppleScriptToolError,
                .executionOutputTruncated(exitCode: 1, stdout: false, stderr: true)
            )
        }
    }

    func testRunAppleScriptToolTimesOutInsteadOfBlockingMCPServer() async throws {
        let started = Date()

        do {
            _ = try await runAppleScriptTool(args: [
                "source": .string("delay 2\nreturn \"late\""),
                "timeoutSeconds": .double(0.1),
            ])
            XCTFail("Expected AppleScript timeout")
        } catch {
            XCTAssertEqual(error as? AppleScriptToolError, .timedOut(seconds: 0.1))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        }
    }

    func testDescriptorFormattingHandlesPrimitiveResults() throws {
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor(boolean: true)), "true")
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor(int32: 42)), "42")
        XCTAssertEqual(appleScriptDescriptorString(NSAppleEventDescriptor.null()), "(no result)")
    }
}
