import Darwin
import XCTest
@testable import HoloscapeMCP

final class ProcessToolTests: XCTestCase {
    private final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: pid_t?

        func store(_ pid: pid_t) {
            lock.lock()
            value = pid
            lock.unlock()
        }

        func load() -> pid_t? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

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

    func testProcessGroupPresenceTreatsPermissionDeniedAsExisting() {
        XCTAssertEqual(processToolGroupPresence(killResult: -1, error: EPERM), true)
        XCTAssertEqual(processToolGroupPresence(killResult: -1, error: ESRCH), false)
        XCTAssertNil(processToolGroupPresence(killResult: -1, error: EINVAL))
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
        let result = try await runProcessTool(
            request(command: "test \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"$$\""),
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

    func testTimeoutTerminatesGroupAfterRootExitsBeforeCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-root-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let childPIDURL = directory.appendingPathComponent("child.pid")
        let command = """
        zmodload zsh/zselect
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while true; do zselect -t 100; done
        """

        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 0.5),
            launcherExecutableURL: launcherExecutableURL,
            beforeTimeoutTermination: { rootPID in
                _ = Darwin.kill(rootPID, SIGKILL)
                let deadline = DispatchTime.now() + .seconds(1)
                while DispatchTime.now() < deadline {
                    errno = 0
                    if Darwin.kill(rootPID, 0) == -1, errno == ESRCH { return }
                    usleep(10_000)
                }
            }
        )

        let childPID = try pid(from: childPIDURL)
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processCleanupConfirmed, true)
        assertProcessIsGone(childPID, "Timed-out descendants must be gone when the root exits before cleanup")
    }

    func testRunProcessToolReportsUnconfirmedCleanupOutsideCappedStderr() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidURL = directory.appendingPathComponent("process.pid")
        let result = try await runProcessTool(
            request(
                command: "zmodload zsh/zselect; echo $$ > \(pidURL.path); printf 123456789 >&2; while true; do zselect -t 100; done",
                timeoutSeconds: 0.25
            ),
            maxOutputBytes: 5,
            launcherExecutableURL: launcherExecutableURL,
            terminateProcessTree: { _ in false }
        )
        let processPID = try pid(from: pidURL)
        defer { _ = Darwin.kill(processPID, SIGKILL) }

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processCleanupConfirmed, false)
        XCTAssertEqual(result.stderr, "12345")
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertTrue(formatProcessToolResult(result).contains("processCleanupConfirmed: false"))
    }

    func testIdentityCaptureFailureKillsResistantProcessGroupBeforeThrowing() async throws {
        let capturedPID = PIDBox()

        do {
            _ = try await runProcessTool(
                request(
                    command: "zmodload zsh/zselect; trap '' TERM; while true; do zselect -t 100; done"
                ),
                launcherExecutableURL: launcherExecutableURL,
                processIdentityProvider: { pid in
                    capturedPID.store(pid)
                    usleep(100_000)
                    return nil
                }
            )
            XCTFail("Expected identity capture failure")
        } catch let error as ProcessToolError {
            guard case .launchFailed = error else {
                return XCTFail("Expected launchFailed, got \(error)")
            }
        }

        let processPID = try XCTUnwrap(capturedPID.load())
        assertProcessIsGone(processPID, "Identity capture failure must not leak the launched group")
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
