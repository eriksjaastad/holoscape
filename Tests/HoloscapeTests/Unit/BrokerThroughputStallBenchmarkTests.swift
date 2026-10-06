import Foundation
import Darwin
import XCTest
@testable import Holoscape

final class BrokerThroughputStallBenchmarkTests: XCTestCase {
    private static let socketBenchmarkChildEnvironmentKey = "HOLOSCAPE_SOCKET_BENCHMARK_CHILD"

    private struct SocketBenchmarkChild {
        let process: Process
        let exited: DispatchSemaphore
    }

    func testBrokerThroughputHarnessCapturesOutputAndInputLatencyBaseline() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 3,
            outputLinesPerSession: 80,
            inputProbeCount: 8,
            durationBudget: 5.0
        )

        let report = try harness.run()

        XCTAssertEqual(report.outputSessionCount, 3)
        XCTAssertEqual(report.inputProbeCount, 8)
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.0, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.35, report.description)
        XCTAssertLessThan(report.duration, 5.0, report.description)
        for probeIndex in 0..<harness.inputProbeCount {
            XCTAssertTrue(
                report.echoedInputTokens.contains(String(format: "probe-%03d", probeIndex)),
                report.description
            )
        }
    }

    func testBrokerThroughputHarnessScalesManyOutputSessionsWhileInputStaysResponsive() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 8,
            outputLinesPerSession: 220,
            inputProbeCount: 24,
            durationBudget: 7.0
        )

        let report = try harness.run()

        XCTAssertEqual(report.outputSessionCount, 8)
        XCTAssertEqual(report.inputProbeCount, 24)
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes, report.description)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.5, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.5, report.description)
        XCTAssertLessThan(report.duration, 7.0, report.description)
        for probeIndex in 0..<harness.inputProbeCount {
            XCTAssertTrue(
                report.echoedInputTokens.contains(String(format: "probe-%03d", probeIndex)),
                report.description
            )
        }
    }

    func testBrokerThroughputHarnessDrainsBurstyOutputFromEverySessionWhileInputStaysResponsive() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 6,
            outputLinesPerSession: 140,
            inputProbeCount: 18,
            durationBudget: 7.0,
            outputPayloadBytes: 512
        )

        let report = try harness.run()

        XCTAssertEqual(report.outputSessionCount, 6)
        XCTAssertEqual(report.inputProbeCount, 18)
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes, report.description)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.5, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.5, report.description)
        XCTAssertLessThan(report.duration, 7.0, report.description)
        for sessionIndex in 0..<harness.outputSessionCount {
            XCTAssertTrue(
                report.outputCompletionTokens.contains(String(format: "session-%d-complete", sessionIndex)),
                report.description
            )
        }
        for probeIndex in 0..<harness.inputProbeCount {
            XCTAssertTrue(
                report.echoedInputTokens.contains(String(format: "probe-%03d", probeIndex)),
                report.description
            )
        }
    }

    func testBrokerThroughputHarnessExercisesProductionUnixSocketPath() throws {
        let socketPath = "/tmp/hs-throughput-\(UUID().uuidString).sock"
        let child = try launchSocketBenchmarkHost(at: socketPath)
        addTeardownBlock {
            try Self.stopSocketBenchmarkHost(child, socketPath: socketPath)
        }

        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            requestTimeoutMilliseconds: 2_000
        )
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try transport.sendFrame(frame)
        }
        try waitForSocketBenchmarkHost(client)

        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 4,
            outputLinesPerSession: 120,
            inputProbeCount: 12,
            durationBudget: 7.0,
            outputPayloadBytes: 512,
            runtimeFactory: { client }
        )

        let report = try harness.run()

        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes, report.description)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.5, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.5, report.description)
        XCTAssertLessThan(report.duration, 7.0, report.description)
        for sessionIndex in 0..<harness.outputSessionCount {
            XCTAssertTrue(
                report.outputCompletionTokens.contains(String(format: "session-%d-complete", sessionIndex)),
                report.description
            )
        }
        for probeIndex in 0..<harness.inputProbeCount {
            XCTAssertTrue(
                report.echoedInputTokens.contains(String(format: "probe-%03d", probeIndex)),
                report.description
            )
        }
    }

    func testSocketBenchmarkHostTerminationCleansLivePTYSession() throws {
        let socketPath = "/tmp/hs-throughput-cleanup-\(UUID().uuidString).sock"
        let child = try launchSocketBenchmarkHost(at: socketPath)
        addTeardownBlock {
            try Self.stopSocketBenchmarkHost(child, socketPath: socketPath)
        }

        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            requestTimeoutMilliseconds: 2_000
        )
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try transport.sendFrame(frame)
        }
        try waitForSocketBenchmarkHost(client)
        try client.createSession(
            id: BrokerSessionID(rawValue: "socket-benchmark-cleanup"),
            request: BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )

        try Self.stopSocketBenchmarkHost(child, socketPath: socketPath)

        XCTAssertFalse(child.process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath + ".lock"))
    }

    func testSocketBenchmarkChildHost() throws {
        guard let socketPath = ProcessInfo.processInfo.environment[Self.socketBenchmarkChildEnvironmentKey] else {
            throw XCTSkip("Executed only by the spawned Unix-socket throughput benchmark host")
        }

        let runtime = NativePTYBrokerSessionRuntime()
        signal(SIGTERM, SIG_IGN)
        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM)
        terminationSource.setEventHandler {
            do {
                for id in try runtime.listSessions() {
                    try runtime.markSessionErrored(id: id)
                }
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                Darwin.exit(EXIT_FAILURE)
            }
        }
        terminationSource.resume()

        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtime)
        )
        try server.run()
    }

    private func launchSocketBenchmarkHost(at socketPath: String) throws -> SocketBenchmarkChild {
        let child = Process()
        let exited = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [
            "-XCTest",
            "HoloscapeTests.BrokerThroughputStallBenchmarkTests/testSocketBenchmarkChildHost",
            Bundle(for: Self.self).bundleURL.path,
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            Self.socketBenchmarkChildEnvironmentKey: socketPath,
        ]) { _, childValue in childValue }
        child.terminationHandler = { _ in exited.signal() }
        try child.run()
        return SocketBenchmarkChild(process: child, exited: exited)
    }

    private func waitForSocketBenchmarkHost(_ client: BrokerSessionHostClientRuntime) throws {
        let deadline = Date().addingTimeInterval(3)
        var lastError: Error?
        while Date() < deadline {
            do {
                _ = try client.listSessions()
                return
            } catch {
                lastError = error
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        throw lastError ?? BrokerSessionHostUnixSocketTransport.TransportError.timedOut("socket benchmark host did not start")
    }

    private static func stopSocketBenchmarkHost(_ child: SocketBenchmarkChild, socketPath: String) throws {
        if child.process.isRunning {
            child.process.terminate()
            if child.exited.wait(timeout: .now() + 2) == .timedOut {
                let result = Darwin.kill(child.process.processIdentifier, SIGKILL)
                guard result == 0 || errno == ESRCH else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "could not kill socket benchmark host"]
                    )
                }
                guard child.exited.wait(timeout: .now() + 1) == .success else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(ETIMEDOUT),
                        userInfo: [NSLocalizedDescriptionKey: "socket benchmark host did not exit after SIGKILL"]
                    )
                }
            }
        }
        guard child.process.terminationReason == .exit,
              child.process.terminationStatus == EXIT_SUCCESS else {
            throw NSError(
                domain: "BrokerThroughputStallBenchmarkTests",
                code: Int(child.process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "socket benchmark host did not confirm PTY cleanup"]
            )
        }
        for path in [socketPath, socketPath + ".lock"] {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "could not remove socket benchmark artifact at \(path)"]
                )
            }
        }
    }
}

private struct BrokerThroughputStallHarness {
    let outputSessionCount: Int
    let outputLinesPerSession: Int
    let inputProbeCount: Int
    /// Upper bound for a single collection run, aligned with the test's
    /// advertised duration assertion. The drain loop is allowed to run for the
    /// full budget so a slow-but-accepted drain is never cut off by a shorter
    /// per-session deadline.
    let durationBudget: TimeInterval
    var outputPayloadBytes = 0
    var runtimeFactory: () throws -> any BrokerSessionRuntime = {
        NativePTYBrokerSessionRuntime()
    }

    func run() throws -> BrokerThroughputStallReport {
        let runtime = try runtimeFactory()
        let inputID = BrokerSessionID(rawValue: "throughput-input-\(UUID().uuidString)")
        var sessionIDs: [BrokerSessionID] = []
        var barrierPaths: [String] = []
        let startedAt = Date()

        let barrierDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-throughput-barrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: barrierDirectory, withIntermediateDirectories: true)
        defer {
            for id in sessionIDs {
                try? runtime.markSessionErrored(id: id)
            }
            try? FileManager.default.removeItem(at: barrierDirectory)
        }

        try runtime.createSession(id: inputID, request: BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        ))
        sessionIDs.append(inputID)

        for index in 0..<outputSessionCount {
            let barrierPath = barrierDirectory.appendingPathComponent("start-\(index)").path
            try makeFIFO(at: barrierPath)
            barrierPaths.append(barrierPath)

            let id = BrokerSessionID(rawValue: "throughput-output-\(index)-\(UUID().uuidString)")
            try runtime.createSession(id: id, request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", outputScript(sessionIndex: index, barrierPath: barrierPath)],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ))
            sessionIDs.append(id)
        }

        var maxInputSendLatency: TimeInterval = 0
        var probeSendTimes: [String: Date] = [:]
        var unsentProbeIndex = 0
        var lastProbeSentAt = Date.distantPast
        let firstProbeDueAt = Date()
        var didReleaseProducers = false

        var outputBytesRead = 0
        var outputTextBySession: [BrokerSessionID: String] = [:]
        var completedOutputSessions = Set<Int>()
        var echoedInput = ""
        var echoedInputTokens = Set<String>()
        var maxInputEchoLatency: TimeInterval = 0
        var maxRunLoopProbeGap: TimeInterval = 0
        var previousRunLoopProbe = Date()

        let deadline = startedAt.addingTimeInterval(durationBudget)
        while Date() < deadline {
            let now = Date()
            if unsentProbeIndex < inputProbeCount,
               (unsentProbeIndex == 0 && now >= firstProbeDueAt || now.timeIntervalSince(lastProbeSentAt) >= 0.02) {
                let token = String(format: "probe-%03d", unsentProbeIndex)
                let sendStarted = Date()
                try runtime.sendInput(id: inputID, bytes: Array("\(token)\n".utf8))
                maxInputSendLatency = max(maxInputSendLatency, Date().timeIntervalSince(sendStarted))
                probeSendTimes[token] = sendStarted
                lastProbeSentAt = sendStarted
                unsentProbeIndex += 1
            }

            // Start output only after the first input probe has entered the
            // active session, so the measured probes overlap producer output
            // instead of observing data that was already buffered in memory.
            if !didReleaseProducers, unsentProbeIndex > 0 {
                for barrierPath in barrierPaths {
                    try releaseFIFO(at: barrierPath, deadline: deadline)
                }
                didReleaseProducers = true
            }

            let inputChunk = String(decoding: try runtime.readAvailableOutput(id: inputID), as: UTF8.self)
            echoedInput += inputChunk
            echoedInputTokens = Set(echoedInput.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            for token in echoedInputTokens {
                if let sentAt = probeSendTimes[token] {
                    maxInputEchoLatency = max(maxInputEchoLatency, Date().timeIntervalSince(sentAt))
                    probeSendTimes[token] = nil
                }
            }

            for index in 0..<outputSessionCount {
                let id = sessionIDs[index + 1]
                let output = try runtime.readAvailableOutput(id: id)
                outputBytesRead += output.count
                if !output.isEmpty {
                    outputTextBySession[id, default: ""] += String(decoding: output, as: UTF8.self)
                }
                if !completedOutputSessions.contains(index),
                   outputTextBySession[id, default: ""].contains(completionMarker(sessionIndex: index)) {
                    completedOutputSessions.insert(index)
                }
            }

            let completed = completedOutputSessions.count == outputSessionCount
                && outputBytesRead >= expectedMinimumOutputBytes
                && unsentProbeIndex == inputProbeCount
                && (0..<inputProbeCount).allSatisfy({
                    echoedInputTokens.contains(String(format: "probe-%03d", $0))
                })
            if !completed {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            let runLoopProbe = Date()
            maxRunLoopProbeGap = max(maxRunLoopProbeGap, runLoopProbe.timeIntervalSince(previousRunLoopProbe))
            previousRunLoopProbe = runLoopProbe
            if completed {
                break
            }
        }

        return BrokerThroughputStallReport(
            outputSessionCount: outputSessionCount,
            outputLinesPerSession: outputLinesPerSession,
            inputProbeCount: inputProbeCount,
            outputBytesRead: outputBytesRead,
            expectedMinimumOutputBytes: expectedMinimumOutputBytes,
            maxInputSendLatency: maxInputSendLatency,
            maxInputEchoLatency: maxInputEchoLatency,
            maxRunLoopProbeGap: maxRunLoopProbeGap,
            duration: Date().timeIntervalSince(startedAt),
            echoedInputTokens: Set(echoedInput.split(whereSeparator: { $0.isWhitespace }).map(String.init)),
            outputCompletionTokens: Set(outputTextBySession.values.flatMap { outputText in
                outputText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            })
        )
    }

    private var expectedMinimumOutputBytes: Int {
        outputSessionCount * outputLinesPerSession * minimumBytesPerOutputLine
    }

    private var minimumBytesPerOutputLine: Int {
        // Matches the per-line shape emitted by outputScript(_:barrierPath:):
        // the largest session index and line number bound the per-line byte count.
        let payload = String(repeating: "x", count: outputPayloadBytes)
        let referenceLine = String(
            format: "session-%d-%04d \(payload) holoscape-throughput-baseline\n",
            outputSessionCount - 1,
            outputLinesPerSession - 1
        )
        return referenceLine.utf8.count
    }

    /// Distinct token emitted by each output session only after its final
    /// payload line, so seeing it proves that session's full output was drained.
    private func completionMarker(sessionIndex: Int) -> String {
        String(format: "session-%d-complete", sessionIndex)
    }

    private func makeFIFO(at path: String) throws {
        let result = path.withCString { mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "mkfifo failed: \(String(cString: strerror(errno)))"]
            )
        }
    }

    private func releaseFIFO(at path: String, deadline: Date) throws {
        var fd: Int32 = -1
        while fd < 0, Date() < deadline {
            fd = path.withCString { open($0, O_WRONLY | O_NONBLOCK) }
            if fd < 0, errno == ENXIO || errno == EAGAIN {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open fifo for writing failed: \(String(cString: strerror(errno)))"]
            )
        }
        defer { close(fd) }
        let byte: UInt8 = 0
        let bytesWritten = withUnsafePointer(to: byte) { ptr in
            write(fd, ptr, 1)
        }
        guard bytesWritten == 1 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "write fifo release byte failed: \(String(cString: strerror(errno)))"]
            )
        }
    }

    private func outputScript(sessionIndex: Int, barrierPath: String) -> String {
        let payload = String(repeating: "x", count: outputPayloadBytes)
        let completion = completionMarker(sessionIndex: sessionIndex)
        return "dd bs=1 count=1 < '\(barrierPath)' 2>/dev/null; i=0; while [ $i -lt \(outputLinesPerSession) ]; do printf 'session-\(sessionIndex)-%04d \(payload) holoscape-throughput-baseline\\n' $i; i=$((i+1)); done; printf '\(completion)\\n'; sleep 1"
    }
}

private struct BrokerThroughputStallReport: CustomStringConvertible {
    let outputSessionCount: Int
    let outputLinesPerSession: Int
    let inputProbeCount: Int
    let outputBytesRead: Int
    let expectedMinimumOutputBytes: Int
    let maxInputSendLatency: TimeInterval
    let maxInputEchoLatency: TimeInterval
    let maxRunLoopProbeGap: TimeInterval
    let duration: TimeInterval
    let echoedInputTokens: Set<String>
    let outputCompletionTokens: Set<String>

    var description: String {
        "BrokerThroughputStallReport(outputSessionCount: \(outputSessionCount), outputLinesPerSession: \(outputLinesPerSession), inputProbeCount: \(inputProbeCount), outputBytesRead: \(outputBytesRead), expectedMinimumOutputBytes: \(expectedMinimumOutputBytes), maxInputSendLatency: \(maxInputSendLatency), maxInputEchoLatency: \(maxInputEchoLatency), maxRunLoopProbeGap: \(maxRunLoopProbeGap), duration: \(duration), echoedInputTokens: \(echoedInputTokens.sorted()), outputCompletionTokens: \(outputCompletionTokens.sorted()))"
    }
}
