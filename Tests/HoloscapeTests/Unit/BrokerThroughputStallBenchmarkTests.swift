import Foundation
import XCTest
@testable import Holoscape

final class BrokerThroughputStallBenchmarkTests: XCTestCase {
    func testBrokerThroughputHarnessCapturesOutputAndInputLatencyBaseline() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 3,
            outputLinesPerSession: 80,
            inputProbeCount: 8
        )

        let report = try harness.run()

        XCTAssertEqual(report.outputSessionCount, 3)
        XCTAssertEqual(report.inputProbeCount, 8)
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.0, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.35, report.description)
        XCTAssertLessThan(report.duration, 5.0, report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-000"), report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-007"), report.description)
    }

    func testBrokerThroughputHarnessScalesManyOutputSessionsWhileInputStaysResponsive() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 8,
            outputLinesPerSession: 220,
            inputProbeCount: 24
        )

        let report = try harness.run()

        XCTAssertEqual(report.outputSessionCount, 8)
        XCTAssertEqual(report.inputProbeCount, 24)
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, report.expectedMinimumOutputBytes, report.description)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.maxInputEchoLatency, 1.5, report.description)
        XCTAssertLessThan(report.maxRunLoopProbeGap, 0.5, report.description)
        XCTAssertLessThan(report.duration, 7.0, report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-000"), report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-023"), report.description)
    }

    func testBrokerThroughputHarnessDrainsBurstyOutputFromEverySessionWhileInputStaysResponsive() throws {
        let harness = BrokerThroughputStallHarness(
            outputSessionCount: 6,
            outputLinesPerSession: 140,
            inputProbeCount: 18,
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
                report.outputCompletionTokens.contains(String(format: "session-%d-%04d", sessionIndex, harness.outputLinesPerSession - 1)),
                report.description
            )
        }
        XCTAssertTrue(report.echoedInputTokens.contains("probe-000"), report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-017"), report.description)
    }
}

private struct BrokerThroughputStallHarness {
    let outputSessionCount: Int
    let outputLinesPerSession: Int
    let inputProbeCount: Int
    var outputPayloadBytes = 0

    func run() throws -> BrokerThroughputStallReport {
        let runtime = NativePTYBrokerSessionRuntime()
        let inputID = BrokerSessionID(rawValue: "throughput-input-\(UUID().uuidString)")
        var sessionIDs: [BrokerSessionID] = []
        let startedAt = Date()

        try runtime.createSession(id: inputID, request: BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        ))
        sessionIDs.append(inputID)

        for index in 0..<outputSessionCount {
            let id = BrokerSessionID(rawValue: "throughput-output-\(index)-\(UUID().uuidString)")
            try runtime.createSession(id: id, request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", outputScript(sessionIndex: index)],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ))
            sessionIDs.append(id)
        }
        defer {
            for id in sessionIDs {
                try? runtime.markSessionErrored(id: id)
            }
        }

        var maxInputSendLatency: TimeInterval = 0
        var probeSendTimes: [String: Date] = [:]
        var unsentProbeIndex = 0
        var lastProbeSentAt = Date.distantPast
        let firstProbeDueAt = Date()

        var outputBytesRead = 0
        var outputTextBySession: [BrokerSessionID: String] = [:]
        var completedOutputSessions = Set<Int>()
        var echoedInput = ""
        var echoedInputTokens = Set<String>()
        var maxInputEchoLatency: TimeInterval = 0
        var maxRunLoopProbeGap: TimeInterval = 0
        var previousRunLoopProbe = Date()
        let deadline = Date().addingTimeInterval(max(3, Double(outputSessionCount) * 0.5))
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

            let inputChunk = String(decoding: try runtime.readAvailableOutput(id: inputID), as: UTF8.self)
            echoedInput += inputChunk
            for token in inputChunk.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                echoedInputTokens.insert(token)
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

            if completedOutputSessions.count == outputSessionCount,
               outputBytesRead >= expectedMinimumOutputBytes,
               unsentProbeIndex == inputProbeCount,
               echoedInputTokens.contains("probe-000"),
               echoedInputTokens.contains(String(format: "probe-%03d", inputProbeCount - 1)) {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            let runLoopProbe = Date()
            maxRunLoopProbeGap = max(maxRunLoopProbeGap, runLoopProbe.timeIntervalSince(previousRunLoopProbe))
            previousRunLoopProbe = runLoopProbe
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
        // Matches the per-line shape emitted by outputScript(_:): the largest
        // session index and line number bound the per-line byte count.
        let payload = String(repeating: "x", count: outputPayloadBytes)
        let referenceLine = String(
            format: "session-%d-%04d \(payload) holoscape-throughput-baseline\n",
            outputSessionCount - 1,
            outputLinesPerSession - 1
        )
        return referenceLine.utf8.count
    }

    private func completionMarker(sessionIndex: Int) -> String {
        String(format: "session-%d-%04d", sessionIndex, outputLinesPerSession - 1)
    }

    private func outputScript(sessionIndex: Int) -> String {
        let payload = String(repeating: "x", count: outputPayloadBytes)
        return "i=0; while [ $i -lt \(outputLinesPerSession) ]; do printf 'session-\(sessionIndex)-%04d \(payload) holoscape-throughput-baseline\\n' $i; i=$((i+1)); done; sleep 1"
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
