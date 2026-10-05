import Darwin
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
        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertTrue(try runtime.readScrollbackTail(id: id, maxBytes: 4096).contains(Data("holoscape-native-pty".utf8)))
    }

    func testNativePTYInputPreservesWriteOrderAndBytes() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "native-pty-input-order-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "stty raw -echo; printf READY; exec cat"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        _ = try waitForOutput(from: runtime, id: id, containing: "READY")

        let chunks: [[UInt8]] = [
            [0x00, 0x01, 0x02, 0x03],
            Array("holoscape".utf8),
            [0x7f, 0x80, 0xfe, 0xff],
        ]
        for chunk in chunks {
            try runtime.sendInput(id: id, bytes: chunk)
        }

        let expected = Data(chunks.flatMap { $0 })
        var observed = Data()
        let deadline = Date().addingTimeInterval(3)
        while observed.count < expected.count, Date() < deadline {
            observed.append(try runtime.readAvailableOutput(id: id))
            if observed.count < expected.count { usleep(10_000) }
        }
        XCTAssertEqual(observed, expected)
    }

    func testInputBackpressureFailsBoundedlyWithoutReportingSuccess() throws {
        let runtime = NativePTYBrokerSessionRuntime(inputWriteTimeoutMilliseconds: 100)
        let id = BrokerSessionID(rawValue: "native-pty-input-backpressure-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let startedAt = DispatchTime.now()
        XCTAssertThrowsError(try runtime.sendInput(id: id, bytes: [UInt8](repeating: 0x61, count: 64 * 1_024 * 1_024))) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .inputWriteTimedOut(id))
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        XCTAssertLessThan(elapsed, 1_000_000_000)
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testTeardownInterruptsAnInputWriteBeforeItsDeadline() throws {
        let writeStarted = DispatchSemaphore(value: 0)
        let runtime = NativePTYBrokerSessionRuntime(
            inputWriteTimeoutMilliseconds: 5_000,
            inputWriteDidStart: { _ in writeStarted.signal() }
        )
        let id = BrokerSessionID(rawValue: "native-pty-input-teardown-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        let writeFinished = DispatchSemaphore(value: 0)
        let capturedError = LockedRuntimeErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.sendInput(
                    id: id,
                    bytes: [UInt8](repeating: 0x62, count: 64 * 1_024 * 1_024)
                )
            } catch {
                capturedError.store(error)
            }
            writeFinished.signal()
        }

        XCTAssertEqual(writeStarted.wait(timeout: .now() + 1), .success)
        let teardownStartedAt = DispatchTime.now()
        try runtime.markSessionErrored(id: id)
        let teardownElapsed = DispatchTime.now().uptimeNanoseconds - teardownStartedAt.uptimeNanoseconds

        XCTAssertEqual(writeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(capturedError.value as? NativePTYBrokerSessionRuntime.RuntimeError, .inputClosed(id))
        XCTAssertLessThan(teardownElapsed, 1_000_000_000)
        XCTAssertThrowsError(try runtime.sendInput(id: id, bytes: [0x63])) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testBrokerHostTeardownInterruptsInputAlreadyRunningOnTheSessionLane() throws {
        let writeStarted = DispatchSemaphore(value: 0)
        let runtime = NativePTYBrokerSessionRuntime(
            inputWriteTimeoutMilliseconds: 5_000,
            inputWriteDidStart: { _ in writeStarted.signal() }
        )
        let scheduler = BrokerSessionOperationScheduler()
        let host = BrokerSessionHost(runtime: runtime, scheduler: scheduler)
        let sendableHost = NativeSendableHostBox(host)
        let codec = BrokerSessionHostCodec()
        let id = BrokerSessionID(rawValue: "native-pty-host-input-teardown-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        try runtime.createSession(id: id, request: request)

        let sendFrame = try codec.encodeRequest(
            .sendInput(id: id, bytes: Data(repeating: 0x64, count: 16 * 1_024 * 1_024))
        )
        let sendResponses = NativeLockedDataResults()
        let sendErrors = LockedRuntimeErrorBox()
        let sendFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                sendResponses.append(try sendableHost.value.handle(sendFrame))
            } catch {
                sendErrors.store(error)
            }
            sendFinished.signal()
        }

        XCTAssertEqual(writeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(scheduler.admittedOperationCount(for: id), 1)

        let teardownStartedAt = DispatchTime.now()
        let teardownFrame = try codec.encodeRequest(.markErrored(id: id))
        XCTAssertEqual(try codec.decodeResponse(host.handle(teardownFrame)), .ok)
        let teardownElapsed = DispatchTime.now().uptimeNanoseconds - teardownStartedAt.uptimeNanoseconds

        XCTAssertEqual(sendFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(sendErrors.value)
        let sendResponse = try XCTUnwrap(sendResponses.values.first)
        guard case let .failure(failure) = try codec.decodeResponse(sendResponse) else {
            return XCTFail("Expected interrupted input to return a failure response")
        }
        XCTAssertEqual(failure.code, "input-closed")
        XCTAssertTrue(failure.message.contains("inputClosed"), failure.message)
        XCTAssertLessThan(teardownElapsed, 1_000_000_000)
        XCTAssertEqual(scheduler.activeLaneCount, 0)
    }

    func testInputDescriptorCloseFailureRetiresSessionAndReportsWithoutRetry() throws {
        let closer = FailingInputDescriptorCloser()
        let runtime = NativePTYBrokerSessionRuntime(inputDescriptorCloser: closer.close)
        let id = BrokerSessionID(rawValue: "native-pty-input-close-failure-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        try runtime.createSession(id: id, request: request)

        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .retirementCompletedWithInputCloseFailure(id, errno: EIO)
            )
        }
        XCTAssertEqual(closer.attemptCount, 1)
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .missingSession(id)
            )
        }
        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .missingSession(id)
            )
        }
        XCTAssertEqual(closer.attemptCount, 1)
    }

    func testRetainedInputDescriptorOwnershipSurvivesForCleanupRetry() throws {
        let closer = RetainingThenClosingInputDescriptorCloser()
        let runtime = NativePTYBrokerSessionRuntime(inputDescriptorCloser: closer.close)
        let id = BrokerSessionID(rawValue: "native-pty-retained-input-close-test")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )

        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            guard case let .retirementFailed(failedID, closeErrno, _) =
                    error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected retained descriptor ownership, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertEqual(closeErrno, EIO)
        }
        XCTAssertEqual(try runtime.listSessions(), [id])
        XCTAssertGreaterThanOrEqual(closer.attemptCount, 1)

        closer.allowClosure()
        try runtime.markSessionErrored(id: id)
        XCTAssertEqual(try runtime.listSessions(), [])
        XCTAssertGreaterThanOrEqual(closer.attemptCount, 2)
    }

    func testLaunchFailureRetainsInputDescriptorCloseFailure() throws {
        let closer = FailingInputDescriptorCloser()
        let runtime = NativePTYBrokerSessionRuntime(inputDescriptorCloser: closer.close)
        let id = BrokerSessionID(rawValue: "native-pty-launch-close-failure-test")
        let request = BrokerSessionLaunchRequest(
            command: "/definitely/missing/holoscape-command",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            guard case let .launchFailedWithInputCloseFailure(reason, closeErrno) =
                    error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected combined launch and close failure, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertEqual(closeErrno, EIO)
        }
        XCTAssertEqual(closer.attemptCount, 1)
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testHostCoordinatorFinalizesErroredMetadataAfterAmbiguousInputClose() throws {
        let closer = FailingInputDescriptorCloser()
        let nativeRuntime = NativePTYBrokerSessionRuntime(inputDescriptorCloser: closer.close)
        let host = BrokerSessionHost(runtime: nativeRuntime)
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try host.handle(frame)
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePTYCloseFailureCoordinatorTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let coordinator = BrokerSessionCoordinator(
            registry: BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json")),
            runtime: client
        )
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "close-failure",
            attachedChannelID: UUID()
        )

        XCTAssertThrowsError(try coordinator.markErrored(record.id)) { error in
            guard case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error else {
                return XCTFail("Expected typed broker-host cleanup warning, got \(error)")
            }
            XCTAssertEqual(code, "retirement-completed-with-input-close-failure")
            XCTAssertTrue(message.contains("retirementCompletedWithInputCloseFailure"), message)
        }
        XCTAssertEqual(try coordinator.loadAll().first?.lifecycle, .errored)
        XCTAssertEqual(closer.attemptCount, 1)
        XCTAssertThrowsError(try client.isRunning(id: record.id)) { error in
            guard case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error else {
                return XCTFail("Expected missing-session host failure, got \(error)")
            }
            XCTAssertEqual(code, "missing-session")
            XCTAssertTrue(message.contains("missingSession"), message)
        }
    }

    func testTeardownReleasesNativePTYInputDescriptors() throws {
        let closer = TrackingInputDescriptorCloser()
        let runtime = NativePTYBrokerSessionRuntime(inputDescriptorCloser: closer.close)
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        for index in 0..<8 {
            let id = BrokerSessionID(rawValue: "native-pty-input-descriptor-lifecycle-\(index)")
            try runtime.createSession(id: id, request: request)
            try runtime.markSessionErrored(id: id)
        }

        XCTAssertEqual(closer.attemptCount, 8)
        XCTAssertEqual(closer.closeFailures, [])
    }

    func testShellProfileStripsInheritedAgentOwnerToken() throws {
        let runtime = NativePTYBrokerSessionRuntime(processEnvironment: [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "SHELL": "/bin/zsh",
            "HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN": "parent-agent-token",
        ])
        let id = BrokerSessionID(rawValue: "shell-owner-token-isolation-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: [
                "-lc",
                "if [ -z \"${HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN+x}\" ]; then printf token-absent; else printf token-present; fi",
            ],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            agentStatusOwnerToken: "request-agent-token",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("token-absent"), output)
        XCTAssertFalse(output.contains("token-present"), output)
    }

    func testPTYSessionReportsARealTTYInsteadOfAPlainPipe() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "tty-smoke-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-lc", "tty"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("/dev/tty"), output)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("not a tty"), output)
    }

    func testPTYSessionSttySizeReflectsInitialAndResizedGrid() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "stty-size-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-lc", "stty size; read _; stty size"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 81, rows: 22)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let initialOutput = try waitForOutput(from: runtime, id: id, containing: "22 81")
        XCTAssertTrue(initialOutput.contains("22 81"), initialOutput)

        try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 132, rows: 43))
        try runtime.sendInput(id: id, bytes: Array("continue\n".utf8))
        _ = try waitForTerminationStatus(from: runtime, id: id)
        let resizedOutput = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(resizedOutput.contains("43 132"), resizedOutput)
    }

    func testCreateSessionRejectsGridDimensionsThatDoNotFitPTYWinsize() {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "oversized-create-grid-native-pty-runtime-test")
        let oversized = Int(UInt16.max) + 1
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: oversized, rows: 24)
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(TerminalGridSize(columns: oversized, rows: 24))
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testCreateSessionRejectsNonPositiveGridDimensionsDecodedFromBrokerProtocol() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "negative-create-grid-native-pty-runtime-test")
        let invalidSize = try JSONDecoder().decode(
            TerminalGridSize.self,
            from: Data(#"{"columns":80,"rows":-1}"#.utf8)
        )
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: invalidSize
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(invalidSize)
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testResizeSessionRejectsGridDimensionsThatDoNotFitPTYWinsizeAndKeepsSessionRunning() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "oversized-resize-grid-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let oversizedSize = TerminalGridSize(columns: 80, rows: Int(UInt16.max) + 1)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: oversizedSize)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(oversizedSize)
            )
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testResizeSessionRejectsNonPositiveGridDimensionsDecodedFromBrokerProtocol() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "negative-resize-grid-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let invalidSize = try JSONDecoder().decode(
            TerminalGridSize.self,
            from: Data(#"{"columns":-1,"rows":24}"#.utf8)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: invalidSize)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(invalidSize)
            )
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testPTYSessionLaunchesInRequestedWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePTYBrokerSessionRuntimeCwdTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // /var/... on macOS is a symlink to /private/var/...; resolve it so the
        // PTY child's getcwd() output matches the directory we actually created.
        let resolvedDirectory = directory.resolvingSymlinksInPath().path

        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "cwd-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/pwd",
            workingDirectory: resolvedDirectory,
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains(resolvedDirectory), output)
    }

    func testTerminatePreservesExitedSessionForScrollbackReads() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "terminated-scrollback-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf preserved-scrollback; exit 3"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        XCTAssertEqual(try waitForTerminationStatus(from: runtime, id: id), 3)
        _ = try waitForOutput(from: runtime, id: id, containing: "preserved-scrollback")

        try runtime.terminateSession(id: id, exitCode: 3)

        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertEqual(try runtime.terminationStatus(id: id), 3)
        XCTAssertEqual(try runtime.listSessions(), [id])
        let scrollback = String(decoding: try runtime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        XCTAssertTrue(scrollback.contains("preserved-scrollback"), scrollback)
    }

    func testForcedRetirementDrainsUnreadPTYOutputBeforeRemovingSession() throws {
        let scrollbackDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forced-retirement-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scrollbackDirectory) }
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackDirectory: scrollbackDirectory,
            installsOutputReadabilityHandler: false
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-output")
        let marker = "unread-final-output-marker"
        let outputWrittenSentinel = scrollbackDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("forced-retirement-written-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputWrittenSentinel) }

        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "printf \(marker); touch \(outputWrittenSentinel.path); exec sleep 30",
                ],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )

        let outputDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: outputWrittenSentinel.path), Date() < outputDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputWrittenSentinel.path), "test command did not write output")

        try runtime.markSessionErrored(id: id)

        XCTAssertTrue(try runtime.listSessions().isEmpty)
        let persisted = try runtime.readScrollbackTail(id: id, maxBytes: 4_096)
        XCTAssertTrue(persisted.contains(Data(marker.utf8)), String(decoding: persisted, as: UTF8.self))
    }

    func testForcedRetirementSerializesWithReadabilityAndPersistsBytesExactlyOnce() throws {
        let scrollbackDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forced-retirement-read-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scrollbackDirectory) }
        let readGate = OneShotOutputReadGate()
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackDirectory: scrollbackDirectory,
            outputReadDidStart: { _ in readGate.blockFirstRead() }
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-read-race")
        let marker = "serialized-final-output-marker"

        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "printf \(marker); exec sleep 30"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        XCTAssertEqual(readGate.started.wait(timeout: .now() + 3), .success)

        let retirementFinished = DispatchSemaphore(value: 0)
        let retirementError = LockedRuntimeErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.markSessionErrored(id: id)
            } catch {
                retirementError.store(error)
            }
            retirementFinished.signal()
        }
        XCTAssertEqual(retirementFinished.wait(timeout: .now() + 0.05), .timedOut)
        readGate.allowRead.signal()
        XCTAssertEqual(retirementFinished.wait(timeout: .now() + 3), .success)
        XCTAssertNil(retirementError.value)

        let persisted = try runtime.readScrollbackTail(id: id, maxBytes: 4_096)
        let text = String(decoding: persisted, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, text)
    }

    func testForcedRetirementSurfacesFinalOutputPersistenceFailureAfterCleanup() throws {
        let outputWrittenSentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("forced-retirement-failed-persistence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputWrittenSentinel) }
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackAppender: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            installsOutputReadabilityHandler: false
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-persistence-failure")

        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "printf final-output; touch \(outputWrittenSentinel.path); exec sleep 30",
                ],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        let outputDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: outputWrittenSentinel.path), Date() < outputDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputWrittenSentinel.path), "test command did not write output")

        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            guard case let NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure(
                warningID,
                reason
            ) = error else {
                return XCTFail("Expected completed output warning, got \(error)")
            }
            XCTAssertEqual(warningID, id)
            XCTAssertTrue(reason.contains("fileWriteNoPermission") || reason.contains("permission"), reason)
        }
        XCTAssertTrue(try runtime.listSessions().isEmpty)
    }

    func testForcedRetirementPreservesOutputAndInputCleanupWarningsTogether() throws {
        let closer = FailingInputDescriptorCloser()
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackAppender: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            inputDescriptorCloser: closer.close,
            installsOutputReadabilityHandler: false
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-combined-output-input-warning")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "printf final-output; exec sleep 30"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        usleep(100_000)

        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            guard case let NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure(
                warningID,
                reason
            ) = error else {
                return XCTFail("Expected combined completed output warning, got \(error)")
            }
            XCTAssertEqual(warningID, id)
            XCTAssertTrue(reason.contains("permission"), reason)
            XCTAssertTrue(reason.contains("inputCloseFailed"), reason)
        }
        XCTAssertTrue(try runtime.listSessions().isEmpty)
    }

    func testForcedRetirementBoundsContinuousPTYOutputBeforeTerminatingProcess() throws {
        let runtime = NativePTYBrokerSessionRuntime(
            outputCleanupTimeoutMilliseconds: 50,
            installsOutputReadabilityHandler: false
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-continuous-output")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/usr/bin/yes",
                arguments: ["0123456789abcdef"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        usleep(50_000)

        let startedAt = DispatchTime.now()
        let retirementError: Error?
        do {
            try runtime.markSessionErrored(id: id)
            retirementError = nil
        } catch {
            retirementError = error
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds

        XCTAssertLessThan(elapsed, 2_000_000_000)
        if let retirementError {
            guard case NativePTYBrokerSessionRuntime.RuntimeError.retirementFailed = retirementError else {
                return XCTFail("Expected bounded retirement failure, got \(retirementError)")
            }
            XCTAssertEqual(try runtime.listSessions(), [id])
        } else {
            XCTAssertTrue(try runtime.listSessions().isEmpty)
        }
    }

    func testForcedRetirementTimesOutBlockedPersistenceWithoutReportingSuccess() throws {
        let appender = BlockingScrollbackAppender(shouldFail: false)
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackAppender: appender.append,
            outputCleanupTimeoutMilliseconds: 100,
            installsOutputReadabilityHandler: false
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-blocked-persistence")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "printf blocked-final-output; exec sleep 30"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        usleep(50_000)

        let retirementFinished = DispatchSemaphore(value: 0)
        let retirementError = LockedRuntimeErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.markSessionErrored(id: id)
            } catch {
                retirementError.store(error)
            }
            retirementFinished.signal()
        }
        XCTAssertEqual(appender.waitUntilEntered(), .success)
        XCTAssertEqual(retirementFinished.wait(timeout: .now() + 2), .success)
        appender.release()

        guard case let NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure(
            warningID,
            reason
        )? = retirementError.value as? NativePTYBrokerSessionRuntime.RuntimeError else {
            return XCTFail("Expected bounded persistence warning, got \(String(describing: retirementError.value))")
        }
        XCTAssertEqual(warningID, id)
        XCTAssertTrue(reason.contains("persistence timed out"), reason)
        XCTAssertTrue(try runtime.listSessions().isEmpty)
    }

    func testContinuousOutputWithBlockedPersistenceKeepsOneBoundedBacklogAndBoundsRetirement() throws {
        let appender = BlockingScrollbackAppender(shouldFail: false)
        let runtime = NativePTYBrokerSessionRuntime(
            scrollbackAppender: appender.append,
            outputCleanupTimeoutMilliseconds: 100
        )
        let id = BrokerSessionID(rawValue: "forced-retirement-continuous-blocked-persistence")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/usr/bin/yes",
                arguments: ["0123456789abcdef"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        XCTAssertEqual(appender.waitUntilEntered(), .success)
        var backlogReachedLimit = false
        for _ in 0..<200 {
            if try runtime.outputPersistenceBacklogByteCount(id: id)
                == ScrollbackPersistencePolicy.maxRetainedBytesPerSession {
                backlogReachedLimit = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(backlogReachedLimit, "Continuous output must pause at the persistence backlog limit")
        XCTAssertLessThanOrEqual(
            try runtime.outputPersistenceBacklogByteCount(id: id),
            ScrollbackPersistencePolicy.maxRetainedBytesPerSession
        )
        XCTAssertFalse(try runtime.isOutputMonitoring(id: id))

        let retirementFinished = DispatchSemaphore(value: 0)
        let retirementError = LockedRuntimeErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try runtime.markSessionErrored(id: id)
            } catch {
                retirementError.store(error)
            }
            retirementFinished.signal()
        }
        XCTAssertEqual(retirementFinished.wait(timeout: .now() + 2), .success)
        appender.release()

        guard let observedError = retirementError.value as? NativePTYBrokerSessionRuntime.RuntimeError else {
            return XCTFail("Expected bounded retirement failure, got \(String(describing: retirementError.value))")
        }
        switch observedError {
        case let .retirementCompletedWithOutputFailure(warningID, reason):
            XCTAssertEqual(warningID, id)
            XCTAssertTrue(reason.contains("bounded retention limit"), reason)
        case let .retirementFailed(warningID, _, processFailure):
            XCTAssertEqual(warningID, id)
            XCTAssertTrue(processFailure.contains("bounded retention limit"), processFailure)
            XCTAssertEqual(try runtime.listSessions(), [id])
        default:
            XCTFail("Expected bounded persistence warning, got \(observedError)")
        }
        if case .retirementCompletedWithOutputFailure = observedError {
            XCTAssertTrue(try runtime.listSessions().isEmpty)
        }
    }

    func testTerminatePreservesExitCodeMismatchFailure() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "exit-code-mismatch-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        XCTAssertEqual(try waitForTerminationStatus(from: runtime, id: id), 7)

        XCTAssertThrowsError(try runtime.terminateSession(id: id, exitCode: 0)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .exitCodeMismatch(expected: 0, observed: 7)
            )
        }
        XCTAssertEqual(try runtime.listSessions(), [id])
    }

    func testTerminateForceKillsProcessThatIgnoresSIGTERMWithinBoundedTime() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "sigterm-resistant-terminate-native-pty-runtime-test")
        let pids = try createSIGTERMResistantSession(runtime: runtime, id: id)
        defer { try? runtime.markSessionErrored(id: id) }
        let completed = DispatchSemaphore(value: 0)
        let capturedError = LockedRuntimeErrorBox()

        DispatchQueue.global().async {
            do {
                try runtime.terminateSession(id: id, exitCode: nil)
            } catch {
                capturedError.store(error)
            }
            completed.signal()
        }

        let firstWait = completed.wait(timeout: .now() + 1.5)
        if firstWait == .timedOut {
            try? runtime.markSessionErrored(id: id)
            _ = completed.wait(timeout: .now() + 1)
        }

        XCTAssertEqual(firstWait, .success, "termination exceeded its bounded deadline")
        XCTAssertNil(capturedError.value)
        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertNotNil(try runtime.terminationStatus(id: id))
        XCTAssertTrue(waitForProcessToExit(pids.child), "termination left descendant PID \(pids.child) running")
    }

    func testMarkErroredForceKillsProcessThatIgnoresSIGTERMWithinBoundedTime() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "sigterm-resistant-error-native-pty-runtime-test")
        let pids = try createSIGTERMResistantSession(runtime: runtime, id: id)
        defer { try? runtime.markSessionErrored(id: id) }
        let completed = DispatchSemaphore(value: 0)
        let capturedError = LockedRuntimeErrorBox()

        DispatchQueue.global().async {
            do {
                try runtime.markSessionErrored(id: id)
            } catch {
                capturedError.store(error)
            }
            completed.signal()
        }

        let firstWait = completed.wait(timeout: .now() + 1.5)
        if firstWait == .timedOut {
            try? runtime.markSessionErrored(id: id)
            _ = completed.wait(timeout: .now() + 1)
        }

        XCTAssertEqual(firstWait, .success, "error cleanup exceeded its bounded deadline")
        XCTAssertNil(capturedError.value)
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { runtimeError in
            XCTAssertEqual(runtimeError as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertTrue(waitForProcessToExit(pids.root), "error cleanup left root PID \(pids.root) running")
        XCTAssertTrue(waitForProcessToExit(pids.child), "error cleanup left descendant PID \(pids.child) running")
    }

    func testNaturalLeaderExitKillsSIGTERMResistantDescendant() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "natural-exit-descendant-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sh -c 'trap \"\" TERM HUP; sleep 5' & child=$!; printf 'ORPHAN_READY:%d\\n' \"$child\"; exit 0"
            ],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        let startedAt = Date()
        let output = try waitForOutput(from: runtime, id: id, containing: "ORPHAN_READY:")
        guard let marker = output.range(of: "ORPHAN_READY:"),
              let childPID = pid_t(output[marker.upperBound...].prefix(while: { $0.isNumber })) else {
            return XCTFail("Could not parse descendant PID from: \(output)")
        }

        XCTAssertEqual(try waitForTerminationStatus(from: runtime, id: id), 0)
        XCTAssertTrue(
            waitForProcessToExit(childPID),
            "natural leader exit left descendant PID \(childPID) running"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.5,
            "natural leader cleanup waited for the descendant to exit on its own"
        )
    }

    func testNaturalLeaderCleanupFailureIsLoudWithoutRetryingStaleProcessGroup() throws {
        let signaler = FailFirstProcessGroupSignaler()
        let runtime = NativePTYBrokerSessionRuntime(processGroupSignal: signaler.signal)
        let id = BrokerSessionID(rawValue: "natural-exit-cleanup-failure-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: [
                "-c",
                "/bin/sh -c 'trap \"\" TERM HUP; sleep 5' & child=$!; printf 'ORPHAN_READY:%d\\n' \"$child\"; exit 0"
            ],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        _ = try waitForOutput(from: runtime, id: id, containing: "ORPHAN_READY:")

        let deadline = Date().addingTimeInterval(1)
        var cleanupError: Error?
        while Date() < deadline, cleanupError == nil {
            do {
                _ = try runtime.terminationStatus(id: id)
            } catch {
                cleanupError = error
            }
            if cleanupError == nil { usleep(10_000) }
        }
        guard case let .terminationFailed(failedID, reason) = cleanupError as? NativePTYBrokerSessionRuntime.RuntimeError else {
            return XCTFail("Expected loud automatic cleanup failure, got \(String(describing: cleanupError))")
        }
        XCTAssertEqual(failedID, id)
        XCTAssertTrue(reason.contains("Operation not permitted"), reason)

        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            guard case let .retirementFailed(retryID, inputCloseErrno, retryReason) =
                    error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected retained cleanup failure, got \(error)")
            }
            XCTAssertEqual(retryID, id)
            XCTAssertNil(inputCloseErrno)
            XCTAssertTrue(retryReason.contains(reason), retryReason)
        }
        XCTAssertEqual(try runtime.listSessions(), [id])
    }

    func testExplicitTerminationFailureIsLoudWithoutRetryingStaleProcessGroup() throws {
        let signaler = FailFirstProcessGroupSignaler()
        let runtime = NativePTYBrokerSessionRuntime(processGroupSignal: signaler.signal)
        let id = BrokerSessionID(rawValue: "retryable-termination-failure-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { signaler.forceCleanup() }

        var firstFailureReason: String?
        XCTAssertThrowsError(try runtime.terminateSession(id: id, exitCode: nil)) { error in
            guard case let .terminationFailed(failedID, reason) = error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected terminationFailed, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertTrue(reason.contains("Operation not permitted"), reason)
            firstFailureReason = reason
        }
        XCTAssertEqual(try runtime.listSessions(), [id])
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            guard case let .terminationFailed(failedID, reason) = error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected retained termination failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertEqual(reason, firstFailureReason)
        }
        XCTAssertThrowsError(try runtime.markSessionErrored(id: id)) { error in
            guard case let .retirementFailed(failedID, inputCloseErrno, reason) =
                    error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected non-retryable termination failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertNil(inputCloseErrno)
            XCTAssertTrue(reason.contains(firstFailureReason ?? ""), reason)
        }
        XCTAssertEqual(try runtime.listSessions(), [id])
    }

    func testTerminationPreservesInputCloseAndProcessCleanupFailuresTogether() throws {
        let closer = FailingInputDescriptorCloser()
        let signaler = FailFirstProcessGroupSignaler()
        let runtime = NativePTYBrokerSessionRuntime(
            inputDescriptorCloser: closer.close,
            processGroupSignal: signaler.signal
        )
        let id = BrokerSessionID(rawValue: "combined-retirement-failure-native-pty-runtime-test")
        try runtime.createSession(
            id: id,
            request: BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        defer { signaler.forceCleanup() }

        XCTAssertThrowsError(try runtime.terminateSession(id: id, exitCode: nil)) { error in
            guard case let .retirementFailed(failedID, closeErrno, processFailure) =
                error as? NativePTYBrokerSessionRuntime.RuntimeError else {
                return XCTFail("Expected combined retirement failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertEqual(closeErrno, EIO)
            XCTAssertTrue(processFailure.contains("terminationFailed"), processFailure)
            XCTAssertTrue(processFailure.contains("Operation not permitted"), processFailure)
        }
        XCTAssertEqual(closer.attemptCount, 1)
        XCTAssertEqual(try runtime.listSessions(), [id])
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

    func testListSessionsReturnsStableSortedSessionIDsWithoutTouchingMissingSessions() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let firstID = BrokerSessionID(rawValue: "list-native-pty-runtime-b")
        let secondID = BrokerSessionID(rawValue: "list-native-pty-runtime-a")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertEqual(try runtime.listSessions(), [])
        try runtime.createSession(id: firstID, request: request)
        defer { try? runtime.markSessionErrored(id: firstID) }
        try runtime.createSession(id: secondID, request: request)
        defer { try? runtime.markSessionErrored(id: secondID) }

        XCTAssertEqual(try runtime.listSessions(), [secondID, firstID])
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

    func testScrollbackTailRetainsOutputAfterPendingOutputIsConsumed() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "scrollback-tail-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        try runtime.sendInput(id: id, bytes: Array("first-scrollback-line\nsecond-scrollback-line\n".utf8))
        _ = try waitForOutput(from: runtime, id: id, containing: "second-scrollback-line")
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())

        let fullTail = String(decoding: try runtime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        XCTAssertTrue(fullTail.contains("first-scrollback-line"), fullTail)
        XCTAssertTrue(fullTail.contains("second-scrollback-line"), fullTail)

        let clippedTail = try runtime.readScrollbackTail(id: id, maxBytes: 8)
        XCTAssertEqual(clippedTail.count, 8)
        XCTAssertTrue(String(decoding: clippedTail, as: UTF8.self).contains("line"))
        XCTAssertEqual(try runtime.readScrollbackTail(id: id, maxBytes: 0), Data())
    }

    func testInstallingAvailabilityHandlerSignalsAlreadyBufferedOutput() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "prebuffered-output-availability-test")
        let marker = "prebuffered-output-marker"
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf \(marker); sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let bufferedDeadline = Date().addingTimeInterval(3)
        while Date() < bufferedDeadline {
            let scrollback = try runtime.readScrollbackTail(id: id, maxBytes: 4096)
            if scrollback.contains(Data(marker.utf8)) { break }
            usleep(20_000)
        }
        XCTAssertTrue(
            try runtime.readScrollbackTail(id: id, maxBytes: 4096).contains(Data(marker.utf8)),
            "fixture output never reached the runtime buffer"
        )

        let outputAvailable = DispatchSemaphore(value: 0)
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }

        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 1), .success)
        let snapshot = try runtime.snapshotAvailableOutput(id: id)
        XCTAssertTrue(snapshot.data.contains(Data(marker.utf8)))
        try runtime.acknowledgeOutput(id: id, through: try XCTUnwrap(snapshot.generation))
        XCTAssertEqual(try runtime.snapshotAvailableOutput(id: id).data, Data())
    }

    func testInstallingAvailabilityHandlerDuringPersistenceSignalsAfterCommit() throws {
        let appender = BlockingScrollbackAppender(shouldFail: false)
        let runtime = NativePTYBrokerSessionRuntime(scrollbackAppender: appender.append)
        let id = BrokerSessionID(rawValue: "handler-during-persistence-test")
        let marker = "handler-during-persistence-marker"
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf \(marker); sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        XCTAssertEqual(appender.waitUntilEntered(), .success)

        let outputAvailable = DispatchSemaphore(value: 0)
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 0.1), .timedOut)

        appender.release()
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)
        let snapshot = try runtime.snapshotAvailableOutput(id: id)
        XCTAssertTrue(snapshot.data.contains(Data(marker.utf8)))
        try runtime.acknowledgeOutput(id: id, through: try XCTUnwrap(snapshot.generation))
        XCTAssertEqual(try runtime.snapshotAvailableOutput(id: id).data, Data())
    }

    func testLiveScrollbackReplayConsumesOnlyTheReplayedUnreadGeneration() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "live-replay-consumes-unread-generation-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf detached-replay-marker; sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        let replay = try runtime.readScrollbackReplay(id: id, maxBytes: 4096)

        XCTAssertEqual(replay.source, .liveBrokerMemory)
        XCTAssertTrue(String(decoding: replay.data, as: UTF8.self).contains("detached-replay-marker"))
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())
    }

    func testConcurrentLegacyOutputReadsDeliverNativeGenerationOnce() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "concurrent-native-output-generation")
        let marker = "single-native-output-generation"
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf \(marker); sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)
        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        let results = NativeLockedDataResults()
        let errors = LockedRuntimeErrorBox()
        let start = DispatchSemaphore(value: 0)
        let readsFinished = expectation(description: "concurrent native output reads")
        readsFinished.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = start.wait(timeout: .now() + 1)
                do { results.append(try runtime.readAvailableOutput(id: id)) } catch { errors.store(error) }
                readsFinished.fulfill()
            }
        }
        start.signal()
        start.signal()
        wait(for: [readsFinished], timeout: 2)

        XCTAssertNil(errors.value)
        XCTAssertEqual(results.values.filter { !$0.isEmpty }.count, 1)
        XCTAssertNotNil(results.values.reduce(into: Data()) { $0.append($1) }.range(of: Data(marker.utf8)))
    }

    func testConcurrentLegacyReplayReadsDeliverNativeGenerationOnce() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "concurrent-native-replay-generation")
        let marker = "single-native-replay-generation"
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf \(marker); sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)
        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        let results = NativeLockedDataResults()
        let errors = LockedRuntimeErrorBox()
        let start = DispatchSemaphore(value: 0)
        let readsFinished = expectation(description: "concurrent native replay reads")
        readsFinished.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = start.wait(timeout: .now() + 1)
                do { results.append(try runtime.readScrollbackReplay(id: id, maxBytes: 4096).data) } catch { errors.store(error) }
                readsFinished.fulfill()
            }
        }
        start.signal()
        start.signal()
        wait(for: [readsFinished], timeout: 2)

        XCTAssertNil(errors.value)
        XCTAssertEqual(results.values.filter { !$0.isEmpty }.count, 1)
        XCTAssertNotNil(results.values.reduce(into: Data()) { $0.append($1) }.range(of: Data(marker.utf8)))
    }

    func testLiveScrollbackTailDoesNotConsumeUnreadOutput() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "live-tail-preserves-unread-output-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf tail-preserves-output-marker; sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        let tail = try runtime.readScrollbackTail(id: id, maxBytes: 4096)
        let unreadOutput = try runtime.readAvailableOutput(id: id)

        XCTAssertTrue(String(decoding: tail, as: UTF8.self).contains("tail-preserves-output-marker"))
        XCTAssertTrue(String(decoding: unreadOutput, as: UTF8.self).contains("tail-preserves-output-marker"))
    }

    func testLiveReplayLeavesUnreadOutputIntactWhenReplayLimitCannotContainIt() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "limited-live-replay-preserves-output-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf output-larger-than-replay-limit; sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        let replay = try runtime.readScrollbackReplay(id: id, maxBytes: 4)
        let unreadOutput = try runtime.readAvailableOutput(id: id)

        XCTAssertEqual(replay.data, Data())
        XCTAssertTrue(String(decoding: unreadOutput, as: UTF8.self).contains("output-larger-than-replay-limit"))
    }

    func testLiveReplayDoesNotConsumePendingOrFailedPersistenceOutput() throws {
        let appender = BlockingScrollbackAppender(shouldFail: true)
        let runtime = NativePTYBrokerSessionRuntime(scrollbackAppender: appender.append)
        let id = BrokerSessionID(rawValue: "failed-persistence-live-replay-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in outputAvailable.signal() }
        try runtime.sendInput(id: id, bytes: Array("failed-replay-persistence-marker\n".utf8))
        XCTAssertEqual(appender.waitUntilEntered(), .success)

        XCTAssertEqual(try runtime.readScrollbackReplay(id: id, maxBytes: 4096).data, Data())

        appender.release()
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)
        XCTAssertThrowsError(try runtime.readScrollbackReplay(id: id, maxBytes: 4096)) { error in
            guard case let NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(failedID, _) = error else {
                return XCTFail("Expected retained persistence failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
        }
        XCTAssertThrowsError(try runtime.readAvailableOutput(id: id))
    }

    func testScrollbackPersistenceFailureDefersOutputWithoutBlockingPollingReads() throws {
        let appender = BlockingScrollbackAppender(shouldFail: true)
        let runtime = NativePTYBrokerSessionRuntime(scrollbackAppender: appender.append)
        let id = BrokerSessionID(rawValue: "failed-disk-scrollback-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in
            outputAvailable.signal()
        }

        try runtime.sendInput(id: id, bytes: Array("unpersisted-scrollback-marker\n".utf8))
        XCTAssertEqual(appender.waitUntilEntered(), .success)

        // A stalled filesystem write must not retain a broker scheduler lane.
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 0.1), .timedOut)

        appender.release()
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)

        var retainedReason = ""
        XCTAssertThrowsError(try runtime.readAvailableOutput(id: id)) { error in
            guard case let NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(failedID, reason) = error else {
                return XCTFail("Expected retained scrollback persistence failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertFalse(reason.isEmpty)
            retainedReason = reason
        }

        let liveTail = String(decoding: try runtime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        XCTAssertTrue(liveTail.contains("unpersisted-scrollback-marker"), liveTail)
        XCTAssertThrowsError(try runtime.readAvailableOutput(id: id)) { error in
            guard case let NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(failedID, reason) = error else {
                return XCTFail("Expected repeated reads to retain the persistence failure, got \(error)")
            }
            XCTAssertEqual(failedID, id)
            XCTAssertEqual(reason, retainedReason)
        }
    }

    func testPollingReadDefersOutputUntilScrollbackPersistenceSucceedsWithoutBlocking() throws {
        let appender = BlockingScrollbackAppender(shouldFail: false)
        let runtime = NativePTYBrokerSessionRuntime(scrollbackAppender: appender.append)
        let id = BrokerSessionID(rawValue: "delayed-disk-scrollback-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in
            outputAvailable.signal()
        }

        try runtime.sendInput(id: id, bytes: Array("persisted-scrollback-marker\n".utf8))
        XCTAssertEqual(appender.waitUntilEntered(), .success)
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 0.1), .timedOut)

        appender.release()
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)
        let output = String(decoding: try runtime.readAvailableOutput(id: id), as: UTF8.self)
        XCTAssertTrue(output.contains("persisted-scrollback-marker"), output)
    }

    func testTerminatedSessionDefersFinalStatusAndOutputUntilPersistenceCompletes() throws {
        let appender = BlockingScrollbackAppender(shouldFail: false)
        let runtime = NativePTYBrokerSessionRuntime(scrollbackAppender: appender.append)
        let id = BrokerSessionID(rawValue: "terminated-delayed-scrollback-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf final-persisted-scrollback"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let outputAvailable = DispatchSemaphore(value: 0)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        try runtime.setOutputAvailabilityHandler(id: id) { _ in
            outputAvailable.signal()
        }
        XCTAssertEqual(appender.waitUntilEntered(), .success)

        // The process may already have exited, but neither its final status nor
        // bytes are authoritative until the PTY monitor and persistence settle.
        XCTAssertNil(try runtime.terminationStatus(id: id))
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())

        appender.release()
        XCTAssertEqual(outputAvailable.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try waitForTerminationStatus(from: runtime, id: id), 0)
        let output = String(decoding: try runtime.readAvailableOutput(id: id), as: UTF8.self)
        XCTAssertTrue(output.contains("final-persisted-scrollback"), output)
    }

    func testDiskBackedScrollbackCanBeReadAfterRuntimeInstanceLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePTYBrokerSessionRuntimeScrollbackTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf durable-scrollback; exit 0"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        let firstRuntime = NativePTYBrokerSessionRuntime(scrollbackDirectory: directory)
        try firstRuntime.createSession(id: id, request: request)
        _ = try waitForTerminationStatus(from: firstRuntime, id: id)
        _ = try waitForOutput(from: firstRuntime, id: id, containing: "durable-scrollback")

        let replacementRuntime = NativePTYBrokerSessionRuntime(scrollbackDirectory: directory)
        let restored = String(decoding: try replacementRuntime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        let replay = try replacementRuntime.readScrollbackReplay(id: id, maxBytes: 4096)

        XCTAssertTrue(restored.contains("durable-scrollback"), restored)
        XCTAssertEqual(replay.source, .persistedDiskTail)
        XCTAssertTrue(String(decoding: replay.data, as: UTF8.self).contains("durable-scrollback"))
    }

    func testTerminationStatusIsNilWhileRunningAndExitCodeAfterProcessEnds() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "termination-status-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let exitCode = try waitForTerminationStatus(from: runtime, id: id)
        XCTAssertEqual(exitCode, 7)
        XCTAssertFalse(try runtime.isRunning(id: id))
    }

    func testPTYEOFStopsOutputMonitoring() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "eof-output-monitoring-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf eof-output; exit 0"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForOutput(from: runtime, id: id, containing: "eof-output")
        _ = try waitForTerminationStatus(from: runtime, id: id)

        let deadline = Date().addingTimeInterval(3)
        while try runtime.isOutputMonitoring(id: id), Date() < deadline {
            usleep(20_000)
        }

        XCTAssertFalse(try runtime.isOutputMonitoring(id: id))
    }

    func testShellProfileSetsDeterministicTerminalEnvironmentFromSparseGUIEnvironment() throws {
        let runtime = NativePTYBrokerSessionRuntime(processEnvironment: [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh"
        ])
        let id = BrokerSessionID(rawValue: "shell-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
        XCTAssertTrue(output.contains("LANG=en_US.UTF-8"), output)
        XCTAssertTrue(output.contains("TERM_PROGRAM=Apple_Terminal"), output)
    }

    func testShellProfilePreservesExistingUTF8Locale() throws {
        let runtime = NativePTYBrokerSessionRuntime(processEnvironment: [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
            "LANG": "C.UTF-8"
        ])
        let id = BrokerSessionID(rawValue: "shell-locale-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("LANG=C.UTF-8"), output)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
    }

    func testAgentOAuthProfileUsesCleanEnvironmentWithoutAPIKeyLeakage() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "agent-oauth-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentOAuth,
            agentStatusOwnerToken: "native-runtime-owner-token",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
        XCTAssertTrue(
            output.contains("HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN=native-runtime-owner-token"),
            output
        )
        XCTAssertFalse(output.contains("ANTHROPIC_API_KEY="), output)
    }

    func testAgentAPIProfileFailsLoudlyUntilKeychainRecipeExists() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "agent-api-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentAPI,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .unsupportedEnvironmentProfile(
                    .agentAPI,
                    reason: "agent API broker sessions require a Keychain-backed environment recipe"
                )
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testRejectedEnvironmentProfilesDoNotLeakPTYFileDescriptors() {
        let runtime = NativePTYBrokerSessionRuntime()
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentAPI,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let descriptorCountBefore = openFileDescriptorCount()

        for index in 0..<32 {
            let id = BrokerSessionID(rawValue: "rejected-environment-fd-leak-\(index)")
            XCTAssertThrowsError(try runtime.createSession(id: id, request: request))
        }

        XCTAssertEqual(openFileDescriptorCount(), descriptorCountBefore)
    }

    private func openFileDescriptorCount() -> Int {
        (0..<Int(getdtablesize())).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(Int32(descriptor), F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
    }

    private func createSIGTERMResistantSession(
        runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID
    ) throws -> (root: pid_t, child: pid_t) {
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: [
                "-c",
                "ready=0; trap 'ready=1' USR1; trap '' TERM; /bin/sh -c 'trap \"\" TERM; kill -USR1 \"$1\"; while :; do :; done' sh \"$$\" & child=$!; while [ \"$ready\" -eq 0 ]; do :; done; printf 'SIGTERM_READY:%d:%d\\n' \"$$\" \"$child\"; wait \"$child\""
            ],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        try runtime.createSession(id: id, request: request)
        do {
            let output = try waitForOutput(from: runtime, id: id, containing: "SIGTERM_READY:")
            guard let marker = output.range(of: "SIGTERM_READY:") else {
                throw CocoaError(.coderReadCorrupt)
            }
            let components = output[marker.upperBound...]
                .prefix(while: { $0.isNumber || $0 == ":" })
                .split(separator: ":")
            guard components.count == 2,
                  let rootPID = pid_t(components[0]),
                  let childPID = pid_t(components[1]) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return (rootPID, childPID)
        } catch {
            do {
                try runtime.markSessionErrored(id: id)
            } catch let cleanupError {
                XCTFail("Fixture setup failed with \(error); cleanup also failed with \(cleanupError)")
                throw cleanupError
            }
            XCTFail("Could not prepare SIGTERM-resistant process tree: \(error)")
            throw error
        }
    }

    private func waitForProcessToExit(_ pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        }
        return false
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

    private func waitForTerminationStatus(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int32? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let status = try runtime.terminationStatus(id: id) {
                return status
            }
            usleep(20_000)
        }
        XCTFail("Timed out waiting for PTY termination status", file: file, line: line)
        return nil
    }

    private func collectOutput(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let chunk = try runtime.readAvailableOutput(id: id)
            if chunk.isEmpty, !collected.isEmpty {
                return String(decoding: collected, as: UTF8.self)
            }
            collected.append(chunk)
            usleep(20_000)
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out collecting PTY output. Output: \(output)", file: file, line: line)
        return output
    }
}

private final class NativeLockedDataResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Data] = []

    var values: [Data] {
        lock.withLock { storedValues }
    }

    func append(_ value: Data) {
        lock.withLock { storedValues.append(value) }
    }
}

private final class NativeSendableHostBox: @unchecked Sendable {
    let value: BrokerSessionHost

    init(_ value: BrokerSessionHost) {
        self.value = value
    }
}

private final class FailingInputDescriptorCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttemptCount = 0

    var attemptCount: Int {
        lock.withLock { storedAttemptCount }
    }

    func close(_ descriptor: Int32) -> NativePTYBrokerSessionRuntime.InputDescriptorCloseResult {
        lock.withLock { storedAttemptCount += 1 }
        _ = Darwin.close(descriptor)
        return .closedWithWarning(EIO)
    }
}

private final class TrackingInputDescriptorCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttemptCount = 0
    private var storedCloseFailures: [Int32] = []

    var attemptCount: Int {
        lock.withLock { storedAttemptCount }
    }

    var closeFailures: [Int32] {
        lock.withLock { storedCloseFailures }
    }

    func close(_ descriptor: Int32) -> NativePTYBrokerSessionRuntime.InputDescriptorCloseResult {
        let result = Darwin.close(descriptor)
        let closeError = result == 0 ? nil : errno
        lock.withLock {
            storedAttemptCount += 1
            if let closeError {
                storedCloseFailures.append(closeError)
            }
        }
        return closeError.map { .ownershipRetained($0) } ?? .closed
    }
}

private final class RetainingThenClosingInputDescriptorCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttemptCount = 0
    private var closureAllowed = false

    var attemptCount: Int { lock.withLock { storedAttemptCount } }

    func allowClosure() {
        lock.withLock { closureAllowed = true }
    }

    func close(_ descriptor: Int32) -> NativePTYBrokerSessionRuntime.InputDescriptorCloseResult {
        lock.lock()
        storedAttemptCount += 1
        let shouldClose = closureAllowed
        lock.unlock()
        guard shouldClose else { return .ownershipRetained(EIO) }
        return Darwin.close(descriptor) == 0 ? .closed : .ownershipRetained(errno)
    }
}

private final class LockedRuntimeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class OneShotOutputReadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let allowRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func blockFirstRead() {
        let shouldBlock = lock.withLock {
            guard !hasBlocked else { return false }
            hasBlocked = true
            return true
        }
        guard shouldBlock else { return }
        started.signal()
        _ = allowRead.wait(timeout: .now() + 3)
    }
}

private final class BlockingScrollbackAppender: @unchecked Sendable {
    private let shouldFail: Bool
    private let entered = DispatchSemaphore(value: 0)
    private let releaseCondition = NSCondition()
    private var isReleased = false

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        entered.signal()
        releaseCondition.lock()
        let deadline = Date().addingTimeInterval(3)
        while !isReleased {
            guard releaseCondition.wait(until: deadline) else {
                releaseCondition.unlock()
                throw CocoaError(.fileWriteUnknown)
            }
        }
        releaseCondition.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 3)
    }

    func release() {
        releaseCondition.lock()
        isReleased = true
        releaseCondition.broadcast()
        releaseCondition.unlock()
    }
}

private final class FailFirstProcessGroupSignaler: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private var lastProcessGroupID: pid_t?

    func signal(_ processGroupID: pid_t, _ signal: Int32) -> Int32 {
        lock.lock()
        lastProcessGroupID = processGroupID
        if shouldFail {
            shouldFail = false
            lock.unlock()
            return EPERM
        }
        lock.unlock()
        return Darwin.kill(-processGroupID, signal) == 0 ? 0 : errno
    }

    func forceCleanup() {
        lock.lock()
        let processGroupID = lastProcessGroupID
        lock.unlock()
        if let processGroupID {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
    }
}
