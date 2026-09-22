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
        XCTAssertGreaterThanOrEqual(report.outputBytesRead, 3 * 80 * 20)
        XCTAssertLessThan(report.maxInputSendLatency, 0.5, report.description)
        XCTAssertLessThan(report.duration, 5.0, report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-000"), report.description)
        XCTAssertTrue(report.echoedInputTokens.contains("probe-007"), report.description)
    }
}

private struct BrokerThroughputStallHarness {
    let outputSessionCount: Int
    let outputLinesPerSession: Int
    let inputProbeCount: Int

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
        for probeIndex in 0..<inputProbeCount {
            let token = String(format: "probe-%03d", probeIndex)
            let sendStarted = Date()
            try runtime.sendInput(id: inputID, bytes: Array("\(token)\n".utf8))
            maxInputSendLatency = max(maxInputSendLatency, Date().timeIntervalSince(sendStarted))
        }

        var outputBytesRead = 0
        var echoedInput = ""
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            echoedInput += String(decoding: try runtime.readAvailableOutput(id: inputID), as: UTF8.self)
            for id in sessionIDs where id != inputID {
                outputBytesRead += try runtime.readAvailableOutput(id: id).count
            }
            if outputBytesRead >= expectedMinimumOutputBytes,
               echoedInput.contains("probe-000"),
               echoedInput.contains(String(format: "probe-%03d", inputProbeCount - 1)) {
                break
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        return BrokerThroughputStallReport(
            outputSessionCount: outputSessionCount,
            outputLinesPerSession: outputLinesPerSession,
            inputProbeCount: inputProbeCount,
            outputBytesRead: outputBytesRead,
            maxInputSendLatency: maxInputSendLatency,
            duration: Date().timeIntervalSince(startedAt),
            echoedInputTokens: Set(echoedInput.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        )
    }

    private var expectedMinimumOutputBytes: Int {
        outputSessionCount * outputLinesPerSession * 20
    }

    private func outputScript(sessionIndex: Int) -> String {
        "i=0; while [ $i -lt \(outputLinesPerSession) ]; do printf 'session-\(sessionIndex)-%04d holoscape-throughput-baseline\\n' $i; i=$((i+1)); done; sleep 1"
    }
}

private struct BrokerThroughputStallReport: CustomStringConvertible {
    let outputSessionCount: Int
    let outputLinesPerSession: Int
    let inputProbeCount: Int
    let outputBytesRead: Int
    let maxInputSendLatency: TimeInterval
    let duration: TimeInterval
    let echoedInputTokens: Set<String>

    var description: String {
        "BrokerThroughputStallReport(outputSessionCount: \(outputSessionCount), outputLinesPerSession: \(outputLinesPerSession), inputProbeCount: \(inputProbeCount), outputBytesRead: \(outputBytesRead), maxInputSendLatency: \(maxInputSendLatency), duration: \(duration), echoedInputTokens: \(echoedInputTokens.sorted()))"
    }
}
