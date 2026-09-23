import Foundation
import XCTest
@testable import Holoscape

final class BrokerSessionHostProtocolTests: XCTestCase {
    func testRequestFramesRoundTripAndEndWithNewlineDelimiter() throws {
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "session-host-protocol-test")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
        let requests: [BrokerSessionHostRequest] = [
            .listSessions,
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
            .waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 250),
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
            .sessionIDs([
                BrokerSessionID(rawValue: "response-session-a"),
                BrokerSessionID(rawValue: "response-session-b"),
            ]),
            .output(Data([0x00, 0x01, 0x02, 0x0A, 0xFF])),
            .outputAvailable(true),
            .outputAvailable(false),
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
        XCTAssertEqual(try host.handle(codec.encodeRequest(.listSessions)), try codec.encodeResponse(.sessionIDs([sessionID])))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.attach(id: sessionID, channelID: channelID))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.sendInput(id: sessionID, bytes: Data("pwd\n".utf8)))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.readAvailableOutput(id: sessionID))), try codec.encodeResponse(.output(Data("broker-output".utf8))))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 0))), try codec.encodeResponse(.outputAvailable(false)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.isRunning(id: sessionID))), try codec.encodeResponse(.running(true)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.terminationStatus(id: sessionID))), try codec.encodeResponse(.terminationStatus(9)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.readScrollbackTail(id: sessionID, maxBytes: 64))), try codec.encodeResponse(.output(Data("scrollback-tail".utf8))))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.resize(id: sessionID, size: TerminalGridSize(columns: 100, rows: 30)))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.detach(id: sessionID))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.terminate(id: sessionID, exitCode: 9))), try codec.encodeResponse(.ok))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.markErrored(id: sessionID))), try codec.encodeResponse(.ok))

        XCTAssertEqual(runtime.events, [
            "create host-dispatch-test /bin/zsh --login /tmp shell 80x24",
            "listSessions",
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
        XCTAssertEqual(failure.code, "missing-session")
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
        XCTAssertEqual(try client.listSessions(), [sessionID])
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
            "listSessions",
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
            XCTAssertEqual(code, "missing-session")
            XCTAssertTrue(message.contains("missingSession"), message)
        }
    }

    func testHostWaitForOutputAvailabilityBlocksUntilRuntimeSignals() throws {
        let runtime = SignalingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-output-availability")
        let responseReady = expectation(description: "wait response returned after signal")
        let responseBox = LockedBrokerResponseBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let frame = try host.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 1_000)))
                responseBox.set(try codec.decodeResponse(frame))
            } catch {
                XCTFail("wait request failed: \(error)")
            }
            responseReady.fulfill()
        }

        XCTAssertTrue(runtime.waitUntilHandlerInstalled(timeout: 1))
        runtime.signal(id: sessionID)
        wait(for: [responseReady], timeout: 1)
        XCTAssertEqual(responseBox.value, .outputAvailable(true))
        XCTAssertFalse(runtime.handlerIsInstalled)
    }

    func testHostWaitForOutputAvailabilityReturnsFalseOnTimeout() throws {
        let runtime = SignalingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-output-timeout")

        let startedAt = Date()
        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 10)))
        )

        XCTAssertEqual(response, .outputAvailable(false))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertFalse(runtime.handlerIsInstalled)
    }

    func testClientRuntimeOutputAvailabilityHandlerWakesFromHostSignal() throws {
        let runtime = SignalingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let client = BrokerSessionHostClientRuntime { frame in
            try host.handle(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "client-output-availability")
        let signaled = expectation(description: "client handler was signaled")

        try client.setOutputAvailabilityHandler(id: sessionID) { id in
            XCTAssertEqual(id, sessionID)
            signaled.fulfill()
        }
        XCTAssertTrue(runtime.waitUntilHandlerInstalled(timeout: 2))
        runtime.signal(id: sessionID)
        wait(for: [signaled], timeout: 2)
        try client.setOutputAvailabilityHandler(id: sessionID, handler: nil)
    }

    func testClientRuntimeOutputAvailabilityCanBeDisabledForFiniteSocketHarnesses() throws {
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { _ in
            XCTFail("disabled output monitoring must not touch the transport")
            return Data()
        }
        let sessionID = BrokerSessionID(rawValue: "disabled-client-output-availability")

        XCTAssertTrue(client.supportsOutputAvailabilityMonitoring)
        try client.setOutputAvailabilityHandler(id: sessionID) { _ in
            XCTFail("disabled output monitoring must not install handlers")
        }
        try client.setOutputAvailabilityHandler(id: sessionID, handler: nil)
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

    func testClientRuntimeFailsLoudlyWhenListSessionsReturnsUnexpectedResponseShape() throws {
        let codec = BrokerSessionHostCodec()
        let client = BrokerSessionHostClientRuntime { _ in
            try codec.encodeResponse(.ok)
        }

        XCTAssertThrowsError(try client.listSessions()) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostClientRuntime.ClientError,
                .unexpectedResponse(expected: "sessionIDs", actual: .ok)
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

    func testBrokerHostCommandRejectsMissingSocketPath() throws {
        let command = BrokerSessionHostCommand(arguments: ["Holoscape", "--broker-host-socket"])

        XCTAssertThrowsError(try command.runIfRequested()) { error in
            XCTAssertEqual(error as? BrokerSessionHostCommand.CommandError, .missingSocketPath)
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

    func testBrokerHostCommandProcessesUnixSocketFramesWithNativeRuntimeBoundary() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.isRunning = true
        let codec = BrokerSessionHostCodec()
        let socketPath = "/tmp/hs-command-\(UUID().uuidString).sock"
        let sessionID = BrokerSessionID(rawValue: "broker-host-socket-command-session")
        let command = BrokerSessionHostCommand(
            arguments: ["Holoscape", "--broker-host-socket", socketPath],
            runtimeFactory: { runtime },
            socketMaxConnections: 1
        )
        let serverFinished = expectation(description: "socket command served one request")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                XCTAssertTrue(try command.runIfRequested())
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let responseFrame = try transport.sendFrame(codec.encodeRequest(.isRunning(id: sessionID)))

        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(try codec.decodeResponse(responseFrame), .running(true))
        XCTAssertEqual(runtime.events, ["isRunning broker-host-socket-command-session"])
    }

    func testHostedNativePTYSessionSurvivesClientRuntimeDiscardAndReattach() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let sessionID = BrokerSessionID(rawValue: "hosted-native-pty-reattach-session")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009005")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        var firstClient: BrokerSessionHostClientRuntime? = BrokerSessionHostClientRuntime { frame in
            try host.handle(frame)
        }
        try firstClient?.createSession(id: sessionID, request: request)
        try firstClient?.detachSession(id: sessionID)
        firstClient = nil

        let secondClient = BrokerSessionHostClientRuntime { frame in
            try host.handle(frame)
        }
        XCTAssertEqual(try secondClient.listSessions(), [sessionID])
        try secondClient.attachSession(id: sessionID, channelID: channelID)
        XCTAssertTrue(try secondClient.isRunning(id: sessionID))
        try secondClient.sendInput(id: sessionID, bytes: Array("reattached-hosted-native-pty\n".utf8))

        let output = try waitForOutput(
            from: secondClient,
            id: sessionID,
            containing: "reattached-hosted-native-pty"
        )
        XCTAssertTrue(output.contains("reattached-hosted-native-pty"), output)

        try secondClient.terminateSession(id: sessionID, exitCode: nil)
        XCTAssertEqual(try secondClient.listSessions(), [sessionID])
        XCTAssertFalse(try secondClient.isRunning(id: sessionID))
        let scrollback = String(
            decoding: try secondClient.readScrollbackTail(id: sessionID, maxBytes: 4096),
            as: UTF8.self
        )
        XCTAssertTrue(scrollback.contains("reattached-hosted-native-pty"), scrollback)
        try secondClient.markSessionErrored(id: sessionID)
        XCTAssertEqual(try secondClient.listSessions(), [])
    }

    func testUnixSocketBrokerKeepsRuntimeAcrossDisconnectedClients() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.isRunning = true
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: host,
            readChunkSize: 5
        )
        let serverFinished = expectation(description: "socket broker served all requests")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 4)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let firstTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath, readChunkSize: 3)
        let firstClient = BrokerSessionHostClientRuntime { frame in
            try firstTransport.sendFrame(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "unix-socket-client-session")
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000009004")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try firstClient.createSession(id: sessionID, request: request)
        try firstClient.detachSession(id: sessionID)

        let secondTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath, readChunkSize: 3)
        let secondClient = BrokerSessionHostClientRuntime { frame in
            try secondTransport.sendFrame(frame)
        }

        XCTAssertEqual(try secondClient.listSessions(), [sessionID])
        try secondClient.attachSession(id: sessionID, channelID: channelID)

        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "create unix-socket-client-session /bin/zsh --login /tmp shell 80x24",
            "detach unix-socket-client-session",
            "listSessions",
            "attach unix-socket-client-session 00000000-0000-0000-0000-000000009004",
        ])
    }

    func testUnixSocketServerDetectsReachableBrokerBeforeReplacingSocketPath() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.isRunning = true
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-existing-broker-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: host,
            readChunkSize: 5
        )
        let serverFinished = expectation(description: "socket broker served probe and request")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        XCTAssertTrue(BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath))

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath, readChunkSize: 3)
        let client = BrokerSessionHostClientRuntime { frame in
            try transport.sendFrame(frame)
        }

        XCTAssertTrue(try client.isRunning(id: BrokerSessionID(rawValue: "existing-broker-session")))
        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "listSessions",
            "isRunning existing-broker-session",
        ])
    }

    func testUnixSocketServerDoesNotBlockUnrelatedSessionBehindSlowRequest() throws {
        let runtime = DelayedBrokerSessionRuntime()
        runtime.isRunning = true
        let slowID = BrokerSessionID(rawValue: "slow-unrelated-session")
        let fastID = BrokerSessionID(rawValue: "fast-unrelated-session")
        runtime.delayReadOutput(for: slowID, seconds: 0.35)
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-concurrent-unrelated-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(socketPath: socketPath, host: host)
        let serverFinished = expectation(description: "concurrent socket broker served slow and fast requests")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let slowStarted = runtime.expectReadStarted(for: slowID)
        let slowFinished = expectation(description: "slow output request finished")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                _ = try client.readAvailableOutput(id: slowID)
            } catch {
                serverError.set(error)
            }
            slowFinished.fulfill()
        }
        wait(for: [slowStarted], timeout: 1)

        let fastStartedAt = Date()
        let fastTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let fastClient = BrokerSessionHostClientRuntime { frame in try fastTransport.sendFrame(frame) }
        XCTAssertTrue(try fastClient.isRunning(id: fastID))
        XCTAssertLessThan(Date().timeIntervalSince(fastStartedAt), 0.2)

        wait(for: [slowFinished, serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events.filter { $0.contains("unrelated-session") }.count, 2)
    }

    func testUnixSocketServerBoundsConcurrentRequestHandlers() throws {
        let runtime = DelayedBrokerSessionRuntime()
        let firstID = BrokerSessionID(rawValue: "bounded-first-session")
        let secondID = BrokerSessionID(rawValue: "bounded-second-session")
        runtime.delayReadOutput(for: firstID, seconds: 0.25)
        runtime.delayReadOutput(for: secondID, seconds: 0.25)
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-bounded-handlers-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: host,
            maxConcurrentHandlers: 1
        )
        let serverFinished = expectation(description: "bounded socket broker served both requests")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let firstStarted = runtime.expectReadStarted(for: firstID)
        let secondStarted = runtime.expectReadStarted(for: secondID)
        let firstFinished = expectation(description: "first bounded request finished")
        let secondFinished = expectation(description: "second bounded request finished")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                _ = try client.readAvailableOutput(id: firstID)
            } catch {
                serverError.set(error)
            }
            firstFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                _ = try client.readAvailableOutput(id: secondID)
            } catch {
                serverError.set(error)
            }
            secondFinished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertFalse(
            runtime.events.contains { $0.contains(secondID.rawValue) },
            "The second request must not enter runtime handling while the single handler slot is occupied"
        )

        wait(for: [firstFinished], timeout: 1)
        wait(for: [secondStarted, secondFinished, serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "readAvailableOutput bounded-first-session",
            "readAvailableOutput bounded-second-session",
        ])
    }

    func testHostPreservesSameSessionOrderingAcrossConcurrentSocketRequests() throws {
        let runtime = DelayedBrokerSessionRuntime()
        let sessionID = BrokerSessionID(rawValue: "same-session-ordering")
        runtime.delaySendInput(containing: "first", seconds: 0.25)
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-same-session-ordering-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(socketPath: socketPath, host: host)
        let serverFinished = expectation(description: "concurrent socket broker served ordered writes")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let firstStarted = runtime.expectSendStarted(containing: "first")
        let firstFinished = expectation(description: "first send finished")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                try client.sendInput(id: sessionID, bytes: Array("first\n".utf8))
            } catch {
                serverError.set(error)
            }
            firstFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        let secondFinished = expectation(description: "second send finished")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                try client.sendInput(id: sessionID, bytes: Array("second\n".utf8))
            } catch {
                serverError.set(error)
            }
            secondFinished.fulfill()
        }

        wait(for: [firstFinished, secondFinished, serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "sendInput same-session-ordering first\\n",
            "sendInput same-session-ordering second\\n",
        ])
    }

    @MainActor
    func testBrokerBackedShellTabRestoresThroughUnixSocketHostRuntimeAcrossAppRelaunch() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocketHostedShellRelaunchTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketPath = "/tmp/hs-shell-relaunch-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: NativePTYBrokerSessionRuntime())
        )
        let serverFinished = expectation(description: "socket broker served shell relaunch requests")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 12)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let configService = ConfigService(configDir: tempDirectory)
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let firstTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let firstCoordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in try firstTransport.sendFrame(frame) },
            now: { Date(timeIntervalSince1970: 9_200) }
        )
        let firstLaunchManager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: firstCoordinator
        )
        let firstShell = firstLaunchManager.createChannel(
            type: .shell,
            role: "Socket Shell",
            workingDirectory: tempDirectory
        ) { id, _, _, instanceNumber, workDir in
            ShellChannelController.brokerBacked(
                id: id,
                instanceNumber: instanceNumber,
                label: "Socket Shell",
                workingDirectory: workDir?.path,
                coordinator: firstCoordinator
            )
        }
        firstShell.activate()
        let brokerSessionID = try XCTUnwrap((firstShell as? ShellChannelController)?.brokerSessionID)
        firstLaunchManager.saveState()
        firstLaunchManager.detachAllChannelsForAppTermination()

        XCTAssertEqual(configService.load().channels.count, 1)
        XCTAssertEqual(configService.load().channels.first?.brokerSessionID, brokerSessionID)

        let secondTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let secondCoordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in try secondTransport.sendFrame(frame) },
            now: { Date(timeIntervalSince1970: 9_201) }
        )
        let secondLaunchManager = ChannelManager(
            configService: configService,
            brokerBackedShellCoordinator: secondCoordinator
        )
        let appDelegate = AppDelegate()
        appDelegate.channelManagerRef = secondLaunchManager
        secondLaunchManager.restoreState { metadata in
            guard let controller = appDelegate.createChannelFromMetadata(metadata) else { return nil }
            controller.activate()
            return controller
        }

        XCTAssertEqual(appDelegate.restoreUnmatchedBrokerBackedSessionsAsTabs(), 0)
        XCTAssertEqual(secondLaunchManager.count, 1)
        let restoredShell = try XCTUnwrap(secondLaunchManager.allChannels().first as? ShellChannelController)
        XCTAssertEqual(restoredShell.brokerSessionID, brokerSessionID)
        XCTAssertEqual(restoredShell.workingDirectory, tempDirectory.path)
        XCTAssertTrue(try secondCoordinator.isRunning(brokerSessionID))
        try secondCoordinator.sendInput(brokerSessionID, bytes: Array("hosted-shell-relaunch-reattach\n".utf8))
        let output = try waitForCoordinatorOutput(
            from: secondCoordinator,
            id: brokerSessionID,
            containing: "hosted-shell-relaunch-reattach"
        )
        XCTAssertTrue(output.contains("hosted-shell-relaunch-reattach"), output)

        let records = try registry.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, brokerSessionID)
        XCTAssertEqual(records[0].channelType, .shell)
        XCTAssertEqual(records[0].lifecycle, .running)
        XCTAssertEqual(records[0].lastAttachedChannelID, restoredShell.channelId)
        XCTAssertEqual(configService.load().channels.map(\.brokerSessionID), [brokerSessionID])

        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
    }

    @MainActor
    func testBrokerBackedAgentSessionReattachesThroughUnixSocketHostRuntime() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocketHostedAgentReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketPath = "/tmp/hs-agent-reattach-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: NativePTYBrokerSessionRuntime())
        )
        let serverFinished = expectation(description: "socket broker served agent relaunch requests")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 6)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let firstTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let firstCoordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in try firstTransport.sendFrame(frame) },
            now: { Date(timeIntervalSince1970: 9_100) }
        )
        let firstChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000009101")!
        let firstTerminal = BrokerBackedTerminalProcess(
            channelID: firstChannelID,
            channelType: .agentDirect,
            label: "Socket Agent",
            environmentProfile: .agentOAuth,
            coordinator: firstCoordinator
        )
        firstTerminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: tempDirectory.path
        )
        let brokerSessionID = try XCTUnwrap(firstTerminal.brokerSessionID)
        firstTerminal.detachBrokerSession()

        let secondTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let secondCoordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in try secondTransport.sendFrame(frame) },
            now: { Date(timeIntervalSince1970: 9_101) }
        )
        let restoredChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000009102")!
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: restoredChannelID,
            channelType: .agentDirect,
            label: "Socket Agent",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: brokerSessionID,
            coordinator: secondCoordinator
        )
        restoredTerminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: tempDirectory.path
        )

        XCTAssertEqual(restoredTerminal.brokerSessionID, brokerSessionID)
        XCTAssertTrue(try secondCoordinator.isRunning(brokerSessionID))
        let records = try registry.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, brokerSessionID)
        XCTAssertEqual(records[0].channelType, .agentDirect)
        XCTAssertEqual(records[0].lifecycle, .running)
        XCTAssertEqual(records[0].lastAttachedChannelID, restoredChannelID)

        _ = try secondCoordinator.markErrored(brokerSessionID)
        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
    }

    func testUnixSocketServerRefusesToReplaceReachableBrokerAtSamePath() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.isRunning = true
        let host = BrokerSessionHost(runtime: runtime)
        let socketPath = "/tmp/hs-refuse-replace-broker-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(socketPath: socketPath, host: host)
        let serverFinished = expectation(description: "original socket broker stayed reachable")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 3)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let replacement = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime())
        )
        XCTAssertThrowsError(try replacement.run(maxConnections: 1)) { error in
            guard case let BrokerSessionHostUnixSocketServer.ServerError.bindFailed(message) = error else {
                return XCTFail("Expected bindFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("already has a reachable broker"), message)
        }

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        let client = BrokerSessionHostClientRuntime { frame in
            try transport.sendFrame(frame)
        }
        XCTAssertEqual(try client.listSessions(), [])
        XCTAssertTrue(try client.isRunning(id: BrokerSessionID(rawValue: "original-broker-still-active")))

        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "listSessions",
            "listSessions",
            "isRunning original-broker-still-active",
        ])
    }

    private func waitForSocket(at path: String) throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            usleep(10_000)
        }
        XCTFail("Timed out waiting for broker socket at \(path)")
    }

    private func waitForOutput(
        from runtime: BrokerSessionHostClientRuntime,
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
        XCTFail("Timed out waiting for output containing \(expected). Saw: \(output)", file: file, line: line)
        return output
    }

    private func waitForCoordinatorOutput(
        from coordinator: any BrokerSessionCoordinating,
        id: BrokerSessionID,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            collected.append(try coordinator.readAvailableOutput(id))
            let output = String(decoding: collected, as: UTF8.self)
            if output.contains(expected) {
                return output
            }
            usleep(20_000)
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out waiting for coordinator output containing \(expected). Saw: \(output)", file: file, line: line)
        return output
    }
}

private final class LockedErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func set(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class LockedBrokerResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResponse: BrokerSessionHostResponse?

    var value: BrokerSessionHostResponse? {
        lock.lock()
        defer { lock.unlock() }
        return storedResponse
    }

    func set(_ response: BrokerSessionHostResponse) {
        lock.lock()
        storedResponse = response
        lock.unlock()
    }
}

private final class SignalingBrokerSessionRuntime: BrokerSessionRuntime, BrokerOutputAvailabilityMonitoringRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (BrokerSessionID) -> Void)?

    var handlerIsInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    func waitUntilHandlerInstalled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if handlerIsInstalled { return true }
            usleep(1_000)
        }
        return handlerIsInstalled
    }

    func signal(id: BrokerSessionID) {
        lock.lock()
        let currentHandler = handler
        lock.unlock()
        currentHandler?(id)
    }

    func setOutputAvailabilityHandler(id: BrokerSessionID, handler: (@Sendable (BrokerSessionID) -> Void)?) throws {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func listSessions() throws -> [BrokerSessionID] { [] }
    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
    func detachSession(id: BrokerSessionID) throws {}
    func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
    func markSessionErrored(id: BrokerSessionID) throws {}
    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
    func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
    func isRunning(id: BrokerSessionID) throws -> Bool { true }
    func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
}

private final class DelayedBrokerSessionRuntime: BrokerSessionRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var readDelays: [BrokerSessionID: TimeInterval] = [:]
    private var sendDelays: [(needle: String, seconds: TimeInterval)] = []
    private var readStartedExpectations: [BrokerSessionID: XCTestExpectation] = [:]
    private var sendStartedExpectations: [(needle: String, expectation: XCTestExpectation)] = []
    private var storedEvents: [String] = []
    var isRunning = false

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func delayReadOutput(for id: BrokerSessionID, seconds: TimeInterval) {
        lock.lock()
        readDelays[id] = seconds
        lock.unlock()
    }

    func delaySendInput(containing needle: String, seconds: TimeInterval) {
        lock.lock()
        sendDelays.append((needle, seconds))
        lock.unlock()
    }

    func expectReadStarted(for id: BrokerSessionID) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "read started for \(id.rawValue)")
        lock.lock()
        readStartedExpectations[id] = expectation
        lock.unlock()
        return expectation
    }

    func expectSendStarted(containing needle: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "send started containing \(needle)")
        lock.lock()
        sendStartedExpectations.append((needle, expectation))
        lock.unlock()
        return expectation
    }

    func listSessions() throws -> [BrokerSessionID] { [] }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        appendEvent("create \(id.rawValue)")
    }

    func detachSession(id: BrokerSessionID) throws {
        appendEvent("detach \(id.rawValue)")
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        appendEvent("attach \(id.rawValue)")
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        appendEvent("terminate \(id.rawValue)")
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        appendEvent("markErrored \(id.rawValue)")
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        let text = String(decoding: bytes, as: UTF8.self)
        let delay = sendDelay(for: text)
        fulfillSendStarted(for: text)
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        appendEvent("sendInput \(id.rawValue) \(text.replacingOccurrences(of: "\n", with: "\\n"))")
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        let delay = readDelay(for: id)
        fulfillReadStarted(for: id)
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        appendEvent("readAvailableOutput \(id.rawValue)")
        return Data("delayed-output".utf8)
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        appendEvent("readScrollbackTail \(id.rawValue)")
        return Data()
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        appendEvent("resize \(id.rawValue)")
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        appendEvent("isRunning \(id.rawValue)")
        return isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }

    private func readDelay(for id: BrokerSessionID) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return readDelays[id] ?? 0
    }

    private func sendDelay(for text: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sendDelays.first { text.contains($0.needle) }?.seconds ?? 0
    }

    private func fulfillReadStarted(for id: BrokerSessionID) {
        lock.lock()
        let expectation = readStartedExpectations[id]
        lock.unlock()
        expectation?.fulfill()
    }

    private func fulfillSendStarted(for text: String) {
        lock.lock()
        let expectations = sendStartedExpectations.filter { text.contains($0.needle) }.map(\.expectation)
        lock.unlock()
        for expectation in expectations {
            expectation.fulfill()
        }
    }

    private func appendEvent(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

private final class RecordingBrokerSessionRuntime: BrokerSessionRuntime {
    var events: [String] = []
    var output = Data()
    var isRunning = false
    var terminationStatus: Int32?
    var error: Error?

    func listSessions() throws -> [BrokerSessionID] {
        try throwIfNeeded()
        events.append("listSessions")
        return events.compactMap { event in
            guard event.hasPrefix("create ") else { return nil }
            let parts = event.split(separator: " ")
            guard parts.count > 1 else { return nil }
            return BrokerSessionID(rawValue: String(parts[1]))
        }
    }

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
