import Foundation
import XCTest
@testable import Holoscape

final class BrokerSessionHostProtocolTests: XCTestCase {
    func testRequestFramesRoundTripAndEndWithNewlineDelimiter() throws {
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "session-host-protocol-test")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
        let requests: [BrokerSessionHostRequest] = [
            .create(
                id: sessionID,
                request: BrokerSessionLaunchRequest(
                    command: "/bin/zsh",
                    arguments: ["-o", "nopromptsp", "--login"],
                    workingDirectory: "/tmp",
                    environmentProfile: .shell,
                    initialSize: TerminalGridSize(columns: 120, rows: 40)
                )
            ),
            .detach(id: sessionID),
            .attach(id: sessionID, channelID: channelID),
            .terminate(id: sessionID, exitCode: 0),
            .markErrored(id: sessionID),
            .sendInput(id: sessionID, bytes: Data("pwd\n".utf8)),
            .readAvailableOutput(id: sessionID),
            .readScrollbackTail(id: sessionID, maxBytes: 4096),
            .resize(id: sessionID, size: TerminalGridSize(columns: 132, rows: 48)),
            .isRunning(id: sessionID),
            .terminationStatus(id: sessionID),
        ]

        for request in requests {
            let frame = try codec.encodeRequest(request)
            XCTAssertEqual(frame.last, 0x0A)
            XCTAssertEqual(try codec.decodeRequest(frame), request)
        }
    }

    func testResponseFramesRoundTripAndCarryBinaryOutputAsData() throws {
        let codec = BrokerSessionHostCodec()
        let responses: [BrokerSessionHostResponse] = [
            .ok,
            .output(Data([0x00, 0x01, 0x02, 0x0A, 0xFF])),
            .running(true),
            .running(false),
            .terminationStatus(nil),
            .terminationStatus(7),
            .failure(BrokerSessionHostFailure(code: "missing-session", message: "session not found")),
        ]

        for response in responses {
            let frame = try codec.encodeResponse(response)
            XCTAssertEqual(frame.last, 0x0A)
            XCTAssertEqual(try codec.decodeResponse(frame), response)
        }
    }

    func testCreateRequestFrameDoesNotSerializeRawEnvironmentSecrets() throws {
        let codec = BrokerSessionHostCodec()
        let request = BrokerSessionHostRequest.create(
            id: BrokerSessionID(rawValue: "secret-free-launch-frame"),
            request: BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                arguments: ["--login"],
                workingDirectory: "/tmp",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )

        let frame = try codec.encodeRequest(request)
        let json = String(decoding: frame, as: UTF8.self)

        XCTAssertTrue(json.contains("agentOAuth"), json)
        XCTAssertFalse(json.contains("environment\":"), json)
        XCTAssertFalse(json.contains("PATH="), json)
        XCTAssertFalse(json.contains("API_KEY"), json)
        XCTAssertFalse(json.contains("TOKEN"), json)
    }

    func testDecoderRejectsEmptyAndNonUTF8FramesBeforeJSONParsing() throws {
        let codec = BrokerSessionHostCodec()

        XCTAssertThrowsError(try codec.decodeRequest(Data([0x0A]))) { error in
            XCTAssertEqual(error as? BrokerSessionHostCodec.CodecError, .emptyFrame)
        }
        XCTAssertThrowsError(try codec.decodeResponse(Data([0xFF, 0x0A]))) { error in
            XCTAssertEqual(error as? BrokerSessionHostCodec.CodecError, .nonUTF8Frame)
        }
    }

    func testHostDispatchesDecodedRequestsToRuntimeAndEncodesResponses() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("broker-output".utf8)
        runtime.isRunning = true
        runtime.terminationStatus = 9
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-dispatch-test")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009002")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertEqual(try host.handle(codec.encodeRequest(.create(id: sessionID, request: request))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.attach(id: sessionID, channelID: channelID))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.sendInput(id: sessionID, bytes: Data("pwd\n".utf8)))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.readAvailableOutput(id: sessionID))), try codec.encodeResponse(.output(Data("broker-output".utf8))))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.isRunning(id: sessionID))), try codec.encodeResponse(.running(true)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.terminationStatus(id: sessionID))), try codec.encodeResponse(.terminationStatus(9)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.readScrollbackTail(id: sessionID, maxBytes: 64))), try codec.encodeResponse(.output(Data("scrollback-tail".utf8))))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.resize(id: sessionID, size: TerminalGridSize(columns: 100, rows: 30)))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.detach(id: sessionID))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.terminate(id: sessionID, exitCode: 9))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.markErrored(id: sessionID))), try codec.encodeResponse(.ok))

        XCTAssertEqual(runtime.events, [
            "create host-dispatch-test /bin/zsh --login /tmp shell 80x24",
            "attach host-dispatch-test 00000000-0000-0000-0000-000000009002",
            "sendInput host-dispatch-test pwd\\n",
            "readAvailableOutput host-dispatch-test",
            "isRunning host-dispatch-test",
            "terminationStatus host-dispatch-test",
            "readScrollbackTail host-dispatch-test 64",
            "resize host-dispatch-test 100x30",
            "detach host-dispatch-test",
            "terminate host-dispatch-test 9",
            "markErrored host-dispatch-test",
        ])
    }

    func testHostTurnsRuntimeErrorsIntoFailureFrames() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.error = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(BrokerSessionID(rawValue: "missing-host-session"))
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.isRunning(id: BrokerSessionID(rawValue: "missing-host-session"))))
        )

        guard case let .failure(failure) = response else {
            return XCTFail("Expected failure response, got \(response)")
        }
        XCTAssertEqual(failure.code, "runtime-error")
        XCTAssertTrue(failure.message.contains("missingSession"), failure.message)
    }

    func testClientRuntimeSendsRequestsThroughHostTransportAndDecodesResponses() throws {
        let hostedRuntime = RecordingBrokerSessionRuntime()
        hostedRuntime.output = Data("client-output".utf8)
        hostedRuntime.isRunning = true
        hostedRuntime.terminationStatus = 12
        let host = BrokerSessionHost(runtime: hostedRuntime)
        let client = BrokerSessionHostClientRuntime { frame in
            try host.handle(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "client-runtime-test")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009003")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try client.createSession(id: sessionID, request: request)
        try client.attachSession(id: sessionID, channelID: channelID)
        try client.sendInput(id: sessionID, bytes: Array("pwd\n".utf8))
        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data("client-output".utf8))
        XCTAssertTrue(try client.isRunning(id: sessionID))
        XCTAssertEqual(try client.terminationStatus(id: sessionID), 12)
        XCTAssertEqual(try client.readScrollbackTail(id: sessionID, maxBytes: 32), Data("scrollback-tail".utf8))
        try client.resizeSession(id: sessionID, size: TerminalGridSize(columns: 120, rows: 40))
        try client.detachSession(id: sessionID)
        try client.terminateSession(id: sessionID, exitCode: 12)
        try client.markSessionErrored(id: sessionID)

        XCTAssertEqual(hostedRuntime.events, [
            "create client-runtime-test /bin/zsh --login /tmp shell 80x24",
            "attach client-runtime-test 00000000-0000-0000-0000-000000009003",
            "sendInput client-runtime-test pwd\\n",
            "readAvailableOutput client-runtime-test",
            "isRunning client-runtime-test",
            "terminationStatus client-runtime-test",
            "readScrollbackTail client-runtime-test 32",
            "resize client-runtime-test 120x40",
            "detach client-runtime-test",
            "terminate client-runtime-test 12",
            "markErrored client-runtime-test",
        ])
    }

    func testClientRuntimeTurnsHostFailureFramesIntoTypedErrors() throws {
        let hostedRuntime = RecordingBrokerSessionRuntime()
        hostedRuntime.error = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(BrokerSessionID(rawValue: "missing-client-session"))
        let host = BrokerSessionHost(runtime: hostedRuntime)
        let client = BrokerSessionHostClientRuntime { frame in
            try host.handle(frame)
        }

        XCTAssertThrowsError(try client.isRunning(id: BrokerSessionID(rawValue: "missing-client-session"))) { error in
            guard case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error else {
                return XCTFail("Expected hostFailure, got \(error)")
            }
            XCTAssertEqual(code, "runtime-error")
            XCTAssertTrue(message.contains("missingSession"), message)
        }
    }

    func testClientRuntimeFailsLoudlyWhenHostReturnsUnexpectedResponseShape() throws {
        let codec = BrokerSessionHostCodec()
        let client = BrokerSessionHostClientRuntime { _ in
            try codec.encodeResponse(.running(true))
        }

        XCTAssertThrowsError(try client.detachSession(id: BrokerSessionID(rawValue: "unexpected-response-client-session"))) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostClientRuntime.ClientError,
                .unexpectedResponse(expected: "ok", actual: .running(true))
            )
        }
    }

    func testStdioServerProcessesMultipleDelimitedFramesUntilEOF() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("stdio-output".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let sessionID = BrokerSessionID(rawValue: "stdio-server-session")

        let server = BrokerSessionHostStdioServer(
            host: host,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            readChunkSize: 7
        )

        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.readAvailableOutput(id: sessionID)))
        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.isRunning(id: sessionID)))
        try inputPipe.fileHandleForWriting.close()

        try server.runUntilEOF()
        try outputPipe.fileHandleForWriting.close()

        let frames = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map { Data("\($0)\n".utf8) }

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(try codec.decodeResponse(frames[0]), .output(Data("stdio-output".utf8)))
        XCTAssertEqual(try codec.decodeResponse(frames[1]), .running(false))
        XCTAssertEqual(runtime.events, [
            "readAvailableOutput stdio-server-session",
            "isRunning stdio-server-session",
        ])
    }

    func testStdioServerReturnsProtocolFailureForMalformedFramesAndKeepsRunning() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let sessionID = BrokerSessionID(rawValue: "stdio-server-protocol-error-session")

        let server = BrokerSessionHostStdioServer(
            host: host,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            readChunkSize: 5
        )

        try inputPipe.fileHandleForWriting.write(contentsOf: Data("not-json\n".utf8))
        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.isRunning(id: sessionID)))
        try inputPipe.fileHandleForWriting.close()

        try server.runUntilEOF()
        try outputPipe.fileHandleForWriting.close()

        let frames = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map { Data("\($0)\n".utf8) }

        XCTAssertEqual(frames.count, 2)
        guard case let .failure(failure) = try codec.decodeResponse(frames[0]) else {
            return XCTFail("Expected protocol failure response")
        }
        XCTAssertEqual(failure.code, "protocol-error")
        XCTAssertTrue(failure.message.contains("dataCorrupted") || failure.message.contains("DecodingError"), failure.message)
        XCTAssertEqual(try codec.decodeResponse(frames[1]), .running(false))
        XCTAssertEqual(runtime.events, ["isRunning stdio-server-protocol-error-session"])
    }

    func testProcessTransportRoundTripsOneDelimitedFrameThroughHelperStdio() throws {
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat")
        )
        defer { transport.close() }

        let firstFrame = Data("{\"status\":\"first\"}\n".utf8)
        let secondFrame = Data("{\"status\":\"second\"}\n".utf8)

        XCTAssertEqual(try transport.sendFrame(firstFrame), firstFrame)
        XCTAssertEqual(try transport.sendFrame(secondFrame), secondFrame)
    }

    func testProcessTransportFailsLoudlyWhenHelperExitsBeforeResponse() throws {
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        defer { transport.close() }

        XCTAssertThrowsError(try transport.sendFrame(Data("{}\n".utf8))) { error in
            switch error as? BrokerSessionHostProcessTransport.TransportError {
            case .helperExited, .writeFailed, .helperClosedPipe:
                break
            default:
                XCTFail("Expected process transport failure, got \(error)")
            }
        }
    }

    func testLazyProcessTransportDoesNotLaunchUntilFirstFrameAndThenReusesHelper() throws {
        let transport = LazyBrokerSessionHostProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )
        defer { transport.close() }

        let firstFrame = Data("{\"status\":\"lazy-first\"}\n".utf8)
        let secondFrame = Data("{\"status\":\"lazy-second\"}\n".utf8)

        XCTAssertEqual(try transport.sendFrame(firstFrame), firstFrame)
        XCTAssertEqual(try transport.sendFrame(secondFrame), secondFrame)
    }

    func testBrokerHostCommandRunsOnlyWhenExplicitlyRequested() throws {
        let command = BrokerSessionHostCommand(arguments: ["Holoscape"])
        XCTAssertFalse(try command.runIfRequested())
    }

    func testBrokerHostCommandRejectsUnexpectedArgumentsInsteadOfLaunchingGUIFallback() throws {
        let command = BrokerSessionHostCommand(arguments: ["Holoscape", "--broker-host", "--unknown"])

        XCTAssertThrowsError(try command.runIfRequested()) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostCommand.CommandError,
                .unexpectedArguments(["--unknown"])
            )
        }
    }

    func testBrokerHostCommandProcessesStdioFramesWithNativeRuntimeBoundary() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.isRunning = true
        let codec = BrokerSessionHostCodec()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let sessionID = BrokerSessionID(rawValue: "broker-host-command-session")
        let command = BrokerSessionHostCommand(
            arguments: ["Holoscape", "--broker-host"],
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            runtimeFactory: { runtime }
        )

        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.isRunning(id: sessionID)))
        try inputPipe.fileHandleForWriting.close()

        XCTAssertTrue(try command.runIfRequested())
        try outputPipe.fileHandleForWriting.close()

        let responseFrame = outputPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(try codec.decodeResponse(responseFrame), .running(true))
        XCTAssertEqual(runtime.events, ["isRunning broker-host-command-session"])
    }
}

private final class RecordingBrokerSessionRuntime: BrokerSessionRuntime {
    var events: [String] = []
    var output = Data()
    var isRunning = false
    var terminationStatus: Int32?
    var error: Error?

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        try throwIfNeeded()
        events.append("create \(id.rawValue) \(request.command) \(request.arguments.joined(separator: " ")) \(request.workingDirectory ?? "nil") \(request.environmentProfile.rawValue) \(request.initialSize.columns)x\(request.initialSize.rows)")
    }

    func detachSession(id: BrokerSessionID) throws {
        try throwIfNeeded()
        events.append("detach \(id.rawValue)")
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        try throwIfNeeded()
        events.append("attach \(id.rawValue) \(channelID.uuidString)")
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        try throwIfNeeded()
        events.append("terminate \(id.rawValue) \(exitCode.map(String.init) ?? "nil")")
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        try throwIfNeeded()
        events.append("markErrored \(id.rawValue)")
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try throwIfNeeded()
        events.append("sendInput \(id.rawValue) \(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n"))")
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try throwIfNeeded()
        events.append("readAvailableOutput \(id.rawValue)")
        return output
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        try throwIfNeeded()
        events.append("readScrollbackTail \(id.rawValue) \(maxBytes)")
        return Data("scrollback-tail".utf8)
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        try throwIfNeeded()
        events.append("resize \(id.rawValue) \(size.columns)x\(size.rows)")
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        try throwIfNeeded()
        events.append("isRunning \(id.rawValue)")
        return isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        try throwIfNeeded()
        events.append("terminationStatus \(id.rawValue)")
        return terminationStatus
    }

    private func throwIfNeeded() throws {
        if let error {
            throw error
        }
    }
}
