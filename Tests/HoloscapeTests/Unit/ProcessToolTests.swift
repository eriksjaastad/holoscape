import Darwin
import XCTest
@testable import HoloscapeMCP

final class ProcessToolTests: XCTestCase {
    private var launcherExecutableURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("HoloscapeMCP")
    }

    func testTimeoutClaimTreatsExitBeforeClaimAsNormalCompletion() {
        let completion = ProcessToolCompletion()
        var states = [true, false]

        let claim = completion.claimTimeout { states.removeFirst() }

        XCTAssertEqual(claim, .processExited)
        XCTAssertFalse(completion.claim())
    }

    func testControllerStatusParsesCleanupFailureOutsideProcessOutput() {
        XCTAssertEqual(
            parseProcessToolControllerStatus("timedOut:unconfirmed"),
            .timedOut(cleanupConfirmed: false)
        )
        XCTAssertEqual(
            parseProcessToolControllerStatus("completed:17"),
            .completed(exitCode: 17)
        )
        XCTAssertNil(parseProcessToolControllerStatus("timedOut:maybe"))
    }

    func testRunProcessToolPreservesOutputBelowLimit() async throws {
        let result = try await runProcessTool(
            request(command: "printf holoscape; printf warning >&2"),
            maxOutputBytes: 32,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "holoscape")
        XCTAssertEqual(result.stderr, "warning")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertNil(result.processCleanupConfirmed)
        XCTAssertFalse(formatProcessToolResult(result).contains("Truncated"))
    }

    func testRunProcessToolCapsStdoutAndReportsTruncation() async throws {
        let result = try await runProcessTool(
            request(command: "printf 123456789"),
            maxOutputBytes: 5,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.stdout, "12345")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertTrue(formatProcessToolResult(result).contains("stdoutTruncated: true"))
    }

    func testRunProcessToolCapsStderrAndReportsTruncation() async throws {
        let result = try await runProcessTool(
            request(command: "printf abcdefghi >&2"),
            maxOutputBytes: 5,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.stderr, "abcde")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertTrue(formatProcessToolResult(result).contains("stderrTruncated: true"))
    }

    func testRunProcessToolPreservesNonzeroExit() async throws {
        let result = try await runProcessTool(
            request(command: "exit 17"),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertFalse(result.timedOut)
    }

    func testRunProcessToolLaunchesDedicatedProcessGroup() async throws {
        let callerProcessGroup = getpgrp()
        let result = try await runProcessTool(
            request(command: "test \"$(ps -o pgid= -p $$ | tr -d ' ')\" != \"\(callerProcessGroup)\""),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testRunProcessToolTimeoutTerminatesResistantProcessTreeBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let command = """
        zmodload zsh/zselect
        echo $$ > \(parentPIDURL.path)
        trap '' TERM
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while true; do zselect -t 100; done
        """

        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 0.5),
            maxOutputBytes: 32,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processCleanupConfirmed, true)
        let parentPID = try pid(from: parentPIDURL)
        let childPID = try pid(from: childPIDURL)
        defer {
            _ = Darwin.kill(parentPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGKILL)
        }
        assertProcessIsGone(parentPID, "Timed-out shell must be gone before returning")
        assertProcessIsGone(childPID, "Timed-out descendants must be gone before returning")
    }

    func testNormalCompletionCleansDescendantsAfterRootExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-root-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let childPIDURL = directory.appendingPathComponent("child.pid")
        let command = """
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while [[ ! -f \(childPIDURL.path) ]]; do sleep 0.01; done
        exit 0
        """

        let result = try await runProcessTool(
            request(command: command),
            launcherExecutableURL: launcherExecutableURL
        )

        let childPID = try pid(from: childPIDURL)
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        assertProcessIsGone(childPID, "Normal completion must not leave descendants after the root exits")
    }

    func testImmediateCommandsDoNotRaceControllerSetup() async throws {
        for _ in 0..<20 {
            let result = try await runProcessTool(
                request(command: "exit 0"),
                launcherExecutableURL: launcherExecutableURL
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testCommandCannotEscapeCleanupByKillingItsDirectParent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-parent-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let commandPIDURL = directory.appendingPathComponent("command.pid")
        let command = """
        echo $$ > \(commandPIDURL.path)
        kill -KILL $PPID
        while true; do sleep 1; done
        """

        do {
            _ = try await runProcessTool(
                request(command: command, timeoutSeconds: 1),
                launcherExecutableURL: launcherExecutableURL
            )
            XCTFail("Expected the shell runner failure to fail closed")
        } catch let error as ProcessToolError {
            guard case .launchFailed = error else {
                return XCTFail("Expected launchFailed, got \(error)")
            }
        }

        let commandPID = try pid(from: commandPIDURL)
        defer { _ = Darwin.kill(commandPID, SIGKILL) }
        assertProcessIsGone(commandPID, "A command must not escape cleanup by killing its direct parent")
    }

    private func request(command: String, timeoutSeconds: Double = 2) -> ProcessToolRequest {
        ProcessToolRequest(
            command: command,
            workingDirectory: nil,
            environment: [:],
            timeoutSeconds: timeoutSeconds
        )
    }

    private func pid(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    private func assertProcessIsGone(_ pid: pid_t, _ message: String) {
        errno = 0
        let result = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1, message)
        XCTAssertEqual(error, ESRCH, message)
    }
}
