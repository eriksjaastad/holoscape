import Foundation
import XCTest
@testable import Holoscape

final class NativePTYBrokerSessionRuntimeTests: XCTestCase {
    func testLocalPTYSessionAcceptsInputProducesOutputResizesAndTerminates() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertTrue(try runtime.isRunning(id: id))
        try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 100, rows: 30))
        try runtime.sendInput(id: id, bytes: Array("holoscape-native-pty\n".utf8))

        let output = try waitForOutput(from: runtime, id: id, containing: "holoscape-native-pty")
        XCTAssertTrue(output.contains("holoscape-native-pty"), output)

        try runtime.terminateSession(id: id, exitCode: nil)
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testDuplicateSessionFailsLoudlyWithoutReplacingOriginalSession() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "duplicate-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .duplicateSession(id))
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testOperationsForMissingSessionFailLoudly() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "missing-native-pty-runtime-test")

        XCTAssertThrowsError(try runtime.sendInput(id: id, bytes: [])) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.readAvailableOutput(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 80, rows: 24))) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testReadAvailableOutputReturnsEmptyDataWhenNoOutputIsPending() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "empty-output-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())
    }

    private func waitForOutput(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            collected.append(try runtime.readAvailableOutput(id: id))
            let output = String(decoding: collected, as: UTF8.self)
            if output.contains(expected) {
                return output
            }
            usleep(20_000)
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out waiting for PTY output containing \(expected). Output: \(output)", file: file, line: line)
        return output
    }
}
