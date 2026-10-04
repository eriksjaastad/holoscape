import Darwin
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
            .snapshotAvailableOutput(id: sessionID),
            .waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 250),
            .readScrollbackTail(id: sessionID, maxBytes: 4096),
            .snapshotScrollbackReplay(id: sessionID, maxBytes: 4096),
            .acknowledgeOutput(id: sessionID, throughGeneration: 42),
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
            .created(agentStatusOwnerTokenApplied: true),
            .sessionIDs([
                BrokerSessionID(rawValue: "response-session-a"),
                BrokerSessionID(rawValue: "response-session-b"),
            ]),
            .output(Data([0x00, 0x01, 0x02, 0x0A, 0xFF])),
            .scrollbackReplay(
                ScrollbackReplay(
                    data: Data("replay".utf8),
                    source: .liveBrokerMemory,
                    maxBytes: 4096
                )
            ),
            .outputSnapshot(BrokerOutputSnapshot(data: Data("snapshot".utf8), generation: 42)),
            .scrollbackReplaySnapshot(
                BrokerScrollbackReplaySnapshot(
                    replay: ScrollbackReplay(
                        data: Data("snapshot-replay".utf8),
                        source: .liveBrokerMemory,
                        maxBytes: 4096
                    ),
                    generation: 43
                )
            ),
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
        XCTAssertEqual(
            try host.handle(codec.encodeRequest(.snapshotAvailableOutput(id: sessionID))),
            try codec.encodeResponse(.outputSnapshot(BrokerOutputSnapshot(data: Data("broker-output".utf8), generation: 1)))
        )
        XCTAssertEqual(try host.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 0))), try codec.encodeResponse(.outputAvailable(false)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.isRunning(id: sessionID))), try codec.encodeResponse(.running(true)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.terminationStatus(id: sessionID))), try codec.encodeResponse(.terminationStatus(9)))
        XCTAssertEqual(try host.handle(codec.encodeRequest(.readScrollbackTail(id: sessionID, maxBytes: 64))), try codec.encodeResponse(.output(Data("scrollback-tail".utf8))))
        XCTAssertEqual(
            try host.handle(codec.encodeRequest(.snapshotScrollbackReplay(id: sessionID, maxBytes: 64))),
            try codec.encodeResponse(
                .scrollbackReplaySnapshot(
                    BrokerScrollbackReplaySnapshot(
                        replay: ScrollbackReplay(
                            data: Data("scrollback-replay".utf8),
                            source: .liveBrokerMemory,
                            maxBytes: 64
                        ),
                        generation: nil
                    )
                )
            )
        )
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
            "readScrollbackReplay host-dispatch-test 64",
            "resize host-dispatch-test 100x30",
            "detach host-dispatch-test",
            "terminate host-dispatch-test 9",
            "markErrored host-dispatch-test",
        ])
    }

    func testHostDoesNotAcknowledgeOwnerTokenForRuntimeWithoutCapability() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-unacknowledged-owner-token")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp",
            environmentProfile: .agentOAuth,
            agentStatusOwnerToken: "owner-token",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.create(id: sessionID, request: request)))
        )

        XCTAssertEqual(response, .created(agentStatusOwnerTokenApplied: false))
        XCTAssertEqual(runtime.events.count, 1)
        XCTAssertTrue(runtime.events[0].hasPrefix("create host-unacknowledged-owner-token "))
    }

    func testHostReportsOwnerTokenAcknowledgementFromCapableRuntime() throws {
        let runtime = AcknowledgingRecordingBrokerSessionRuntime()
        runtime.ownerTokenWasApplied = true
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-acknowledged-owner-token")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp",
            environmentProfile: .agentOAuth,
            agentStatusOwnerToken: "owner-token",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.create(id: sessionID, request: request)))
        )

        XCTAssertEqual(response, .created(agentStatusOwnerTokenApplied: true))
        XCTAssertEqual(runtime.events.count, 1)
        XCTAssertTrue(runtime.events[0].hasPrefix("create host-acknowledged-owner-token "))
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

    func testHostTurnsScrollbackPersistenceErrorsIntoTypedFailureFrames() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let sessionID = BrokerSessionID(rawValue: "failed-scrollback-host-session")
        runtime.error = NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(
            sessionID,
            reason: "disk full"
        )
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.snapshotAvailableOutput(id: sessionID)))
        )

        guard case let .failure(failure) = response else {
            return XCTFail("Expected failure response, got \(response)")
        }
        XCTAssertEqual(failure.code, "scrollback-persistence-failed")
        XCTAssertTrue(failure.message.contains(sessionID.rawValue), failure.message)
        XCTAssertTrue(failure.message.contains("disk full"), failure.message)
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
        XCTAssertEqual(
            try client.readScrollbackReplay(id: sessionID, maxBytes: 32),
            ScrollbackReplay(
                data: Data("scrollback-replay".utf8),
                source: .liveBrokerMemory,
                maxBytes: 32
            )
        )
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
            "acknowledgeOutput client-runtime-test 1",
            "isRunning client-runtime-test",
            "terminationStatus client-runtime-test",
            "readScrollbackTail client-runtime-test 32",
            "readScrollbackReplay client-runtime-test 32",
            "resize client-runtime-test 120x40",
            "detach client-runtime-test",
            "terminate client-runtime-test 12",
            "markErrored client-runtime-test",
        ])
    }

    func testHostClientLiveReplayConsumesDetachedOutputExactlyOnce() throws {
        let nativeRuntime = NativePTYBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: nativeRuntime)
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try host.handle(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "host-client-live-replay-once")
        try client.createSession(
            id: sessionID,
            request: BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "printf host-client-replay-marker; sleep 5"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        )
        defer { try? client.markSessionErrored(id: sessionID) }

        let deadline = Date().addingTimeInterval(3)
        var tail = Data()
        while Date() < deadline {
            tail = try client.readScrollbackTail(id: sessionID, maxBytes: 4096)
            if String(decoding: tail, as: UTF8.self).contains("host-client-replay-marker") { break }
            usleep(20_000)
        }
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).contains("host-client-replay-marker"))

        let replay = try client.readScrollbackReplay(id: sessionID, maxBytes: 4096)

        XCTAssertEqual(replay.source, .liveBrokerMemory)
        XCTAssertTrue(String(decoding: replay.data, as: UTF8.self).contains("host-client-replay-marker"))
        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data())
    }

    func testLostOutputResponseLeavesSnapshotAvailableForRetry() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("response-loss-output".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let readAttempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            let response = try host.handle(frame)
            if case .snapshotAvailableOutput = try codec.decodeRequest(frame), readAttempts.increment() == 1 {
                throw BrokerSessionHostUnixSocketTransport.TransportError.timedOut("lost after host snapshot")
            }
            return response
        }
        let sessionID = BrokerSessionID(rawValue: "lost-output-response")

        XCTAssertThrowsError(try client.readAvailableOutput(id: sessionID))
        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data("response-loss-output".utf8))
        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data())
    }

    func testLostAcknowledgementResponseIsRetriedBeforeNextRead() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("ack-loss-output".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let ackAttempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            let response = try host.handle(frame)
            if case .acknowledgeOutput = try codec.decodeRequest(frame), ackAttempts.increment() == 1 {
                throw BrokerSessionHostUnixSocketTransport.TransportError.timedOut("lost after host ack")
            }
            return response
        }
        let sessionID = BrokerSessionID(rawValue: "lost-output-ack")

        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data("ack-loss-output".utf8))
        XCTAssertEqual(try client.readAvailableOutput(id: sessionID), Data())
        XCTAssertEqual(ackAttempts.value, 2)
    }

    func testConcurrentLegacyOutputReadsDeliverGenerationOnce() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("single-output-generation".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let firstSnapshotEntered = DispatchSemaphore(value: 0)
        let releaseFirstSnapshot = DispatchSemaphore(value: 0)
        let snapshotAttempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            let request = try codec.decodeRequest(frame)
            let response = try host.handle(frame)
            if case .snapshotAvailableOutput = request, snapshotAttempts.increment() == 1 {
                firstSnapshotEntered.signal()
                _ = releaseFirstSnapshot.wait(timeout: .now() + 2)
            }
            return response
        }
        let sessionID = BrokerSessionID(rawValue: "concurrent-legacy-output")
        let results = LockedDataResults()
        let errors = LockedErrorBox()
        let firstFinished = expectation(description: "first legacy output read")
        let secondFinished = expectation(description: "second legacy output read")
        let secondStarted = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do { results.append(try client.readAvailableOutput(id: sessionID)) } catch { errors.set(error) }
            firstFinished.fulfill()
        }
        XCTAssertEqual(firstSnapshotEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            secondStarted.signal()
            do { results.append(try client.readAvailableOutput(id: sessionID)) } catch { errors.set(error) }
            secondFinished.fulfill()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        usleep(20_000)
        releaseFirstSnapshot.signal()
        wait(for: [firstFinished, secondFinished], timeout: 2)

        XCTAssertNil(errors.value)
        XCTAssertEqual(results.values.filter { !$0.isEmpty }, [Data("single-output-generation".utf8)])
        XCTAssertEqual(snapshotAttempts.value, 2)
    }

    func testConcurrentLegacyReplayReadsDeliverGenerationOnce() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("unread-replay-generation".utf8)
        runtime.scrollbackReplayGeneration = 1
        let host = BrokerSessionHost(runtime: runtime)
        let firstSnapshotEntered = DispatchSemaphore(value: 0)
        let releaseFirstSnapshot = DispatchSemaphore(value: 0)
        let snapshotAttempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            let request = try codec.decodeRequest(frame)
            let response = try host.handle(frame)
            if case .snapshotScrollbackReplay = request, snapshotAttempts.increment() == 1 {
                firstSnapshotEntered.signal()
                _ = releaseFirstSnapshot.wait(timeout: .now() + 2)
            }
            return response
        }
        let sessionID = BrokerSessionID(rawValue: "concurrent-legacy-replay")
        let results = LockedDataResults()
        let errors = LockedErrorBox()
        let firstFinished = expectation(description: "first legacy replay read")
        let secondFinished = expectation(description: "second legacy replay read")
        let secondStarted = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do { results.append(try client.readScrollbackReplay(id: sessionID, maxBytes: 4096).data) } catch { errors.set(error) }
            firstFinished.fulfill()
        }
        XCTAssertEqual(firstSnapshotEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            secondStarted.signal()
            do { results.append(try client.readScrollbackReplay(id: sessionID, maxBytes: 4096).data) } catch { errors.set(error) }
            secondFinished.fulfill()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        usleep(20_000)
        releaseFirstSnapshot.signal()
        wait(for: [firstFinished, secondFinished], timeout: 2)

        XCTAssertNil(errors.value)
        XCTAssertEqual(results.values.filter { !$0.isEmpty }, [Data("scrollback-replay".utf8)])
        XCTAssertEqual(snapshotAttempts.value, 2)
    }

    func testTransactionalAcknowledgementFailureThrowsAndRemainsPendingForRetry() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("strict-ack-output".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let ackAttempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            if case .acknowledgeOutput = try codec.decodeRequest(frame), ackAttempts.increment() == 1 {
                throw BrokerSessionHostUnixSocketTransport.TransportError.timedOut("ack never reached host")
            }
            return try host.handle(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "strict-output-ack")
        let transactionalClient: any BrokerTransactionalOutputRuntime = client
        let snapshot = try transactionalClient.snapshotAvailableOutput(id: sessionID)
        let generation = try XCTUnwrap(snapshot.generation)

        XCTAssertThrowsError(
            try transactionalClient.acknowledgeOutput(id: sessionID, through: generation),
            "A delivery owner must not publish exit or retire the runtime without confirmed acknowledgement"
        )
        XCTAssertEqual(runtime.output, Data("strict-ack-output".utf8))

        let nextSnapshot = try transactionalClient.snapshotAvailableOutput(id: sessionID)
        XCTAssertEqual(nextSnapshot.data, Data())
        XCTAssertEqual(ackAttempts.value, 2)
    }

    func testTransactionalSnapshotRequestUsesProtocolShapeLegacyHostCannotDispatch() throws {
        let codec = BrokerSessionHostCodec()
        let frame = try codec.encodeRequest(
            .snapshotAvailableOutput(id: BrokerSessionID(rawValue: "version-separated-output"))
        )
        let json = String(decoding: frame, as: UTF8.self)

        XCTAssertTrue(json.contains("snapshotAvailableOutput"), json)
        XCTAssertFalse(json.contains("\"readAvailableOutput\""), json)
    }

    func testTransactionalClientDefersAcknowledgementUntilDeliveryOwnerAcceptsSnapshot() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.output = Data("delivery-owned-output".utf8)
        let host = BrokerSessionHost(runtime: runtime)
        let client = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try host.handle(frame)
        }
        let sessionID = BrokerSessionID(rawValue: "delivery-owned-output")

        let transactionalClient: any BrokerTransactionalOutputRuntime = client
        let snapshot = try transactionalClient.snapshotAvailableOutput(id: sessionID)

        XCTAssertEqual(snapshot.data, Data("delivery-owned-output".utf8))
        XCTAssertFalse(runtime.events.contains("acknowledgeOutput delivery-owned-output 1"))
        XCTAssertEqual(runtime.output, Data("delivery-owned-output".utf8))

        try transactionalClient.acknowledgeOutput(id: sessionID, through: try XCTUnwrap(snapshot.generation))

        XCTAssertTrue(runtime.events.contains("acknowledgeOutput delivery-owned-output 1"))
        XCTAssertEqual(runtime.output, Data())
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
        let sendableHost = TestSendableValue(value: host)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-output-availability")
        let responseReady = expectation(description: "wait response returned after signal")
        let responseBox = LockedBrokerResponseBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let frame = try sendableHost.value.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 1_000)))
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

    func testHostWaitForOutputAvailabilityReturnsImmediatelyForBufferedNativeOutput() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let sessionID = BrokerSessionID(rawValue: "host-prebuffered-output-availability")
        let marker = "host-prebuffered-output-marker"
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf \(marker); sleep 5"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: sessionID, request: request)
        defer { try? runtime.markSessionErrored(id: sessionID) }

        let bufferedDeadline = Date().addingTimeInterval(3)
        while Date() < bufferedDeadline {
            let scrollback = try runtime.readScrollbackTail(id: sessionID, maxBytes: 4096)
            if scrollback.contains(Data(marker.utf8)) { break }
            usleep(20_000)
        }
        XCTAssertTrue(
            try runtime.readScrollbackTail(id: sessionID, maxBytes: 4096).contains(Data(marker.utf8)),
            "fixture output never reached the runtime buffer"
        )

        let startedAt = Date()
        let response = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 1_000)))
        )

        XCTAssertEqual(response, .outputAvailable(true))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)

        let snapshotResponse = try codec.decodeResponse(
            try host.handle(codec.encodeRequest(.snapshotAvailableOutput(id: sessionID)))
        )
        guard case let .outputSnapshot(snapshot) = snapshotResponse else {
            return XCTFail("Expected output snapshot, got \(snapshotResponse)")
        }
        XCTAssertTrue(snapshot.data.contains(Data(marker.utf8)))
        let generation = try XCTUnwrap(snapshot.generation)
        XCTAssertEqual(
            try codec.decodeResponse(
                try host.handle(codec.encodeRequest(.acknowledgeOutput(id: sessionID, throughGeneration: generation)))
            ),
            .ok
        )
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

    func testClientRuntimeOutputMonitorRetriesTransientTransportFailure() throws {
        let codec = BrokerSessionHostCodec()
        let attempts = LockedCounter()
        let client = BrokerSessionHostClientRuntime { frame in
            guard case .waitForOutputAvailability = try codec.decodeRequest(frame) else {
                throw NSError(domain: "BrokerSessionHostProtocolTests", code: 4)
            }
            let attempt = attempts.increment()
            if attempt == 1 {
                throw BrokerSessionHostUnixSocketTransport.TransportError.timedOut("test")
            }
            return try codec.encodeResponse(.outputAvailable(attempt == 2))
        }
        let sessionID = BrokerSessionID(rawValue: "client-output-retry")
        let signaled = expectation(description: "client output monitor recovered after transient failure")

        try client.setOutputAvailabilityHandler(id: sessionID) { _ in signaled.fulfill() }
        wait(for: [signaled], timeout: 3)
        try client.setOutputAvailabilityHandler(id: sessionID, handler: nil)
        XCTAssertGreaterThanOrEqual(attempts.value, 2)
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

    func testProductionSocketRuntimeUsesFallbackSamplingInsteadOfPerSessionLongPolls() {
        let client = BrokerSessionHostClientRuntime.currentExecutableSocketHostRuntime(
            socketPath: "/tmp/unused-production-socket-runtime.sock"
        )

        XCTAssertFalse(client.supportsOutputAvailabilityMonitoring)
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

    func testClientRuntimeTreatsMalformedResponseAsAmbiguousTransportFailure() {
        let client = BrokerSessionHostClientRuntime { _ in Data("not-json\n".utf8) }

        XCTAssertThrowsError(
            try client.createSession(
                id: BrokerSessionID(rawValue: "malformed-create-response"),
                request: BrokerSessionLaunchRequest(
                    command: "/bin/zsh",
                    workingDirectory: "/tmp",
                    environmentProfile: .shell,
                    initialSize: TerminalGridSize(columns: 80, rows: 24)
                )
            )
        ) { error in
            guard case let BrokerSessionHostClientRuntime.ClientError.transportFailed(message) = error else {
                return XCTFail("Expected ambiguous transport failure, got \(error)")
            }
            XCTAssertTrue(message.contains("responseDecodeFailed"))
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

        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.snapshotAvailableOutput(id: sessionID)))
        try inputPipe.fileHandleForWriting.write(contentsOf: codec.encodeRequest(.isRunning(id: sessionID)))
        try inputPipe.fileHandleForWriting.close()

        try server.runUntilEOF()
        try outputPipe.fileHandleForWriting.close()

        let frames = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map { Data("\($0)\n".utf8) }

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(
            try codec.decodeResponse(frames[0]),
            .outputSnapshot(BrokerOutputSnapshot(data: Data("stdio-output".utf8), generation: 1))
        )
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

    func testStdioServerRejectsOversizedUnterminatedFrameAndProcessesNextFrame() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let sessionID = BrokerSessionID(rawValue: "stdio-server-after-oversized-frame")
        let validFrame = try codec.encodeRequest(.isRunning(id: sessionID))
        let maximumFrameSize = validFrame.count

        let server = BrokerSessionHostStdioServer(
            host: host,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            readChunkSize: 4,
            maximumFrameSize: maximumFrameSize
        )

        try inputPipe.fileHandleForWriting.write(
            contentsOf: Data(repeating: 0x78, count: maximumFrameSize + 1)
        )
        try inputPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        try inputPipe.fileHandleForWriting.write(contentsOf: validFrame)
        try inputPipe.fileHandleForWriting.close()

        try server.runUntilEOF()
        try outputPipe.fileHandleForWriting.close()

        let frames = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map { Data("\($0)\n".utf8) }

        XCTAssertEqual(frames.count, 2)
        guard case let .failure(failure) = try codec.decodeResponse(frames[0]) else {
            return XCTFail("Expected oversized-frame protocol failure response")
        }
        XCTAssertEqual(failure.code, "protocol-error")
        XCTAssertTrue(failure.message.contains("frameTooLarge"), failure.message)
        XCTAssertTrue(failure.message.contains("\(maximumFrameSize)"), failure.message)
        XCTAssertEqual(try codec.decodeResponse(frames[1]), .running(false))
        XCTAssertEqual(runtime.events, ["isRunning stdio-server-after-oversized-frame"])
    }

    func testStdioServerAcceptsFrameExactlyAtMaximumSize() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let sessionID = BrokerSessionID(rawValue: "stdio-server-exact-frame-limit")
        let frame = try codec.encodeRequest(.isRunning(id: sessionID))

        let server = BrokerSessionHostStdioServer(
            host: host,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            readChunkSize: 5,
            maximumFrameSize: frame.count
        )

        try inputPipe.fileHandleForWriting.write(contentsOf: frame)
        try inputPipe.fileHandleForWriting.close()

        try server.runUntilEOF()
        try outputPipe.fileHandleForWriting.close()

        let response = outputPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(try codec.decodeResponse(response), .running(false))
        XCTAssertEqual(runtime.events, ["isRunning stdio-server-exact-frame-limit"])
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

    func testProcessTransportAcceptsResponseAtMaximumFrameSize() throws {
        let maximumFrameSize = 16
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            maximumResponseFrameSize: maximumFrameSize
        )
        defer { transport.close() }
        var frame = Data(repeating: 0x78, count: maximumFrameSize - 1)
        frame.append(0x0A)

        XCTAssertEqual(try transport.sendFrame(frame), frame)
    }

    func testProcessTransportRejectsOversizedDelimitedResponse() throws {
        let maximumFrameSize = 16
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            maximumResponseFrameSize: maximumFrameSize
        )
        defer { transport.close() }
        var frame = Data(repeating: 0x78, count: maximumFrameSize)
        frame.append(0x0A)

        XCTAssertThrowsError(try transport.sendFrame(frame)) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostProtocolError,
                .frameTooLarge(maximumBytes: maximumFrameSize)
            )
        }
    }

    func testProcessTransportRejectsOversizedResponseBeforeDelimiter() throws {
        let maximumFrameSize = 16
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportOversizedResponseTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("oversized-response")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        IFS= read -r line
        printf xxxxxxxxxxxxxxxxx
        while :; do sleep 1; done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: helperURL,
            responseTimeoutSeconds: 2,
            maximumResponseFrameSize: maximumFrameSize
        )
        defer { transport.close() }

        XCTAssertThrowsError(try transport.sendFrame(Data("{}\n".utf8))) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostProtocolError,
                .frameTooLarge(maximumBytes: maximumFrameSize)
            )
        }
    }

    func testProcessTransportDrainsHighVolumeStderrBeforeHelperResponse() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("stderr-before-response")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        /usr/bin/head -c 1048576 /dev/zero >&2
        IFS= read -r line
        printf '%s\\n' "$line"
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let transport = try BrokerSessionHostProcessTransport(
            executableURL: helperURL,
            responseTimeoutSeconds: 1
        )
        defer { transport.close() }
        let frame = Data("{\"status\":\"after-stderr\"}\n".utf8)

        XCTAssertEqual(try transport.sendFrame(frame), frame)
    }

    func testProcessTransportCloseEscalatesWhenHelperIgnoresTermination() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportCloseTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("ignore-termination")
        let terminationTrapInstalledURL = temporaryDirectory.appendingPathComponent("termination-trap-installed")
        let helperPIDURL = temporaryDirectory.appendingPathComponent("helper-pid")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        trap '' TERM
        : > "$1"
        printf '%s\\n' "$$" > "$2"
        IFS= read -r line
        printf '%s\\n' "$line"
        while :; do :; done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let transport = try BrokerSessionHostProcessTransport(
            executableURL: helperURL,
            arguments: [terminationTrapInstalledURL.path, helperPIDURL.path]
        )
        try waitForFile(at: terminationTrapInstalledURL.path)
        let helperPID = try helperPID(at: helperPIDURL)
        defer { _ = Darwin.kill(helperPID, SIGKILL) }
        let frame = Data("{\"status\":\"ready\"}\n".utf8)
        XCTAssertEqual(try transport.sendFrame(frame), frame)

        let closeStarted = DispatchTime.now().uptimeNanoseconds
        transport.close()
        let closeElapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - closeStarted) / 1_000_000_000
        XCTAssertLessThan(closeElapsedSeconds, 1.5, "TERM-to-KILL close was not bounded")
        XCTAssertTrue(waitForProcessToExit(helperPID), "Helper PID \(helperPID) survived TERM-to-KILL escalation")
    }

    func testLazyProcessTransportCloseInterruptsInFlightPartialResponse() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportConcurrentCloseTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("stream-partial-response")
        let requestReceivedURL = temporaryDirectory.appendingPathComponent("request-received")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        trap '' TERM
        IFS= read -r line
        : > "$1"
        (sleep 2; kill -KILL $$) &
        while :; do
            printf x
            sleep 0.05
        done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let transport = LazyBrokerSessionHostProcessTransport(
            executableURL: helperURL,
            arguments: [requestReceivedURL.path],
            responseTimeoutSeconds: 1
        )
        defer { transport.close() }
        let sendFinished = expectation(description: "in-flight send interrupted")
        let sendError = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try transport.sendFrame(Data("{}\n".utf8))
            } catch {
                sendError.set(error)
            }
            sendFinished.fulfill()
        }

        let requestDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: requestReceivedURL.path), Date() < requestDeadline {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestReceivedURL.path))

        let start = Date()
        transport.close()

        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        wait(for: [sendFinished], timeout: 1)
        XCTAssertNotNil(sendError.value)
    }

    func testDirectProcessTransportCloseRetainsAdmittedDescriptorAfterPollReadiness() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportDescriptorLifetimeTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("ready-response")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        IFS= read -r line
        printf partial
        while :; do sleep 1; done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let readReady = DispatchSemaphore(value: 0)
        let allowRead = DispatchSemaphore(value: 0)
        let descriptorUsed = expectation(description: "cached descriptor used after close")
        let transport = try BrokerSessionHostProcessTransport(
            executableURL: helperURL,
            responseTimeoutSeconds: 5,
            responseReadObserver: { descriptor in
                readReady.signal()
                allowRead.wait()
                XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1, "close released or reused the admitted descriptor")
                descriptorUsed.fulfill()
            }
        )
        let sendFinished = expectation(description: "admitted direct send returned")
        let sendError = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do { _ = try transport.sendFrame(Data("{}\n".utf8)) } catch { sendError.set(error) }
            sendFinished.fulfill()
        }

        XCTAssertEqual(readReady.wait(timeout: .now() + 1), .success)
        transport.close()
        allowRead.signal()
        wait(for: [descriptorUsed, sendFinished], timeout: 1)
        XCTAssertEqual(sendError.value as? BrokerSessionHostProcessTransport.TransportError, .transportClosed)
    }

    func testDirectProcessTransportBrokenPipeReturnsTypedErrorUnderDefaultSIGPIPEInChildProcess() throws {
        if let resultPath = ProcessInfo.processInfo.environment["HOLOSCAPE_SIGPIPE_CHILD_RESULT"],
           let helperPath = ProcessInfo.processInfo.environment["HOLOSCAPE_SIGPIPE_CHILD_HELPER"],
           let stdinClosedPath = ProcessInfo.processInfo.environment["HOLOSCAPE_SIGPIPE_CHILD_STDIN_CLOSED"],
           let helperPIDPath = ProcessInfo.processInfo.environment["HOLOSCAPE_SIGPIPE_CHILD_HELPER_PID"] {
            Self.runBrokenPipeProbe(
                helperURL: URL(fileURLWithPath: helperPath),
                stdinClosedURL: URL(fileURLWithPath: stdinClosedPath),
                helperPIDURL: URL(fileURLWithPath: helperPIDPath),
                resultURL: URL(fileURLWithPath: resultPath)
            )
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostProcessTransportSIGPIPETests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("closed-stdin")
        let stdinClosedURL = temporaryDirectory.appendingPathComponent("stdin-closed")
        let helperPIDURL = temporaryDirectory.appendingPathComponent("helper-pid")
        let resultURL = temporaryDirectory.appendingPathComponent("child-result")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        trap '' TERM
        exec 0<&-
        : > "$1"
        printf '%s\\n' "$$" > "$2"
        while :; do sleep 1; done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [
            "-XCTest",
            "HoloscapeTests.BrokerSessionHostProtocolTests/testDirectProcessTransportBrokenPipeReturnsTypedErrorUnderDefaultSIGPIPEInChildProcess",
            Bundle(for: Self.self).bundleURL.path,
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "HOLOSCAPE_SIGPIPE_CHILD_RESULT": resultURL.path,
            "HOLOSCAPE_SIGPIPE_CHILD_HELPER": helperURL.path,
            "HOLOSCAPE_SIGPIPE_CHILD_STDIN_CLOSED": stdinClosedURL.path,
            "HOLOSCAPE_SIGPIPE_CHILD_HELPER_PID": helperPIDURL.path,
        ]) { _, childValue in childValue }
        let childExited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in childExited.signal() }
        try child.run()
        let initialExit = childExited.wait(timeout: .now() + 5)
        if initialExit == .timedOut {
            child.terminate()
            if childExited.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(child.processIdentifier, SIGKILL)
                _ = childExited.wait(timeout: .now() + 1)
            }
        }
        if FileManager.default.fileExists(atPath: helperPIDURL.path), let helperPID = try? helperPID(at: helperPIDURL) {
            if !waitForProcessToExit(helperPID) {
                _ = Darwin.kill(helperPID, SIGKILL)
            }
            XCTAssertTrue(waitForProcessToExit(helperPID), "SIGPIPE probe left helper PID \(helperPID) running")
        }
        guard initialExit == .success else {
            return XCTFail("SIGPIPE probe child exceeded its parent-enforced five-second deadline")
        }
        XCTAssertEqual(child.terminationReason, .exit, "Child died from signal \(child.terminationStatus) instead of returning typed writeFailed")
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: resultURL, encoding: .utf8), "W", "Expected normal typed writeFailed completion")
    }

    func testLazyProcessTransportCloseCancelsBlockedAndQueuedRequestsWithoutResurrection() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazyBrokerSessionHostProcessTransportQueuedCloseTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("block-response")
        let requestReceivedURL = temporaryDirectory.appendingPathComponent("request-received")
        let launchCountURL = temporaryDirectory.appendingPathComponent("launch-count")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        printf x >> "$2"
        trap '' TERM
        IFS= read -r line
        : > "$1"
        while :; do sleep 1; done
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let secondRequestWaitingForLock = DispatchSemaphore(value: 0)
        let transport = LazyBrokerSessionHostProcessTransport(
            executableURL: helperURL,
            arguments: [requestReceivedURL.path, launchCountURL.path],
            responseTimeoutSeconds: 5,
            transportFactory: { executableURL, arguments, environment, responseTimeoutSeconds in
                try BrokerSessionHostProcessTransport(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    responseTimeoutSeconds: responseTimeoutSeconds,
                    requestLockWaitObserver: { secondRequestWaitingForLock.signal() }
                )
            }
        )
        let firstFinished = expectation(description: "blocked first request returned")
        let secondFinished = expectation(description: "queued second request returned")
        let firstError = LockedErrorBox()
        let secondError = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do { _ = try transport.sendFrame(Data("{\"request\":1}\n".utf8)) } catch { firstError.set(error) }
            firstFinished.fulfill()
        }
        try waitForFile(at: requestReceivedURL.path)
        DispatchQueue.global(qos: .userInitiated).async {
            do { _ = try transport.sendFrame(Data("{\"request\":2}\n".utf8)) } catch { secondError.set(error) }
            secondFinished.fulfill()
        }

        XCTAssertEqual(secondRequestWaitingForLock.wait(timeout: .now() + 1), .success)
        transport.close()
        wait(for: [firstFinished, secondFinished], timeout: 1)
        XCTAssertEqual(firstError.value as? BrokerSessionHostProcessTransport.TransportError, .transportClosed)
        XCTAssertEqual(secondError.value as? BrokerSessionHostProcessTransport.TransportError, .transportClosed)
        XCTAssertEqual(try String(contentsOf: launchCountURL, encoding: .utf8), "x")
        XCTAssertThrowsError(try transport.sendFrame(Data("{\"request\":3}\n".utf8))) { error in
            XCTAssertEqual(error as? BrokerSessionHostProcessTransport.TransportError, .transportClosed)
        }
        XCTAssertEqual(try String(contentsOf: launchCountURL, encoding: .utf8), "x")
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

    func testLazyProcessTransportCloseBeforeFirstSendIsTerminalAndNeverLaunches() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazyBrokerSessionHostProcessTransportCloseBeforeLaunchTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("count-launch")
        let launchCountURL = temporaryDirectory.appendingPathComponent("launch-count")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try """
        #!/bin/sh
        printf x >> "$1"
        exec /bin/cat
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let transport = LazyBrokerSessionHostProcessTransport(
            executableURL: helperURL,
            arguments: [launchCountURL.path]
        )
        transport.close()
        transport.close()

        for _ in 0..<3 {
            XCTAssertThrowsError(try transport.sendFrame(Data("{}\n".utf8))) { error in
                XCTAssertEqual(
                    error as? BrokerSessionHostProcessTransport.TransportError,
                    .transportClosed
                )
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchCountURL.path))
    }

    func testBrokerHostCommandRunsOnlyWhenExplicitlyRequested() throws {
        let command = BrokerSessionHostCommand(arguments: ["Holoscape"])
        XCTAssertFalse(try command.runIfRequested())
    }

    func testBrokerHostDefaultRuntimePersistsScrollbackAcrossRuntimeReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionHostCommandScrollbackTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = BrokerSessionID(rawValue: "broker-host-default-runtime-scrollback")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf broker-host-durable-scrollback; exit 0"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        var firstRuntime: (any BrokerSessionRuntime)? = BrokerSessionHostCommand.makeDefaultRuntime(
            scrollbackDirectory: directory
        )
        try firstRuntime?.createSession(id: sessionID, request: request)

        var observedOutput = Data()
        let deadline = Date().addingTimeInterval(3)
        while !String(decoding: observedOutput, as: UTF8.self).contains("broker-host-durable-scrollback"),
              Date() < deadline {
            observedOutput.append(try firstRuntime?.readAvailableOutput(id: sessionID) ?? Data())
            usleep(20_000)
        }
        XCTAssertTrue(
            String(decoding: observedOutput, as: UTF8.self).contains("broker-host-durable-scrollback"),
            String(decoding: observedOutput, as: UTF8.self)
        )
        firstRuntime = nil

        let replacementRuntime = BrokerSessionHostCommand.makeDefaultRuntime(
            scrollbackDirectory: directory
        )
        let restored = try replacementRuntime.readScrollbackTail(id: sessionID, maxBytes: 4096)

        XCTAssertTrue(
            String(decoding: restored, as: UTF8.self).contains("broker-host-durable-scrollback"),
            String(decoding: restored, as: UTF8.self)
        )
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
        let sendableCommand = TestSendableValue(value: command)
        let serverFinished = expectation(description: "socket command served one request")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handled = try sendableCommand.value.runIfRequested()
                XCTAssertTrue(handled)
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

    func testUnixSocketServerRejectsOversizedRequestWithoutDispatchingRuntime() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let host = BrokerSessionHost(runtime: runtime)
        let codec = BrokerSessionHostCodec()
        let socketPath = "/tmp/hs-oversized-frame-\(UUID().uuidString).sock"
        let frame = try codec.encodeRequest(
            .isRunning(id: BrokerSessionID(rawValue: "unix-socket-oversized-frame"))
        )
        let maximumFrameSize = frame.count - 1
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: host,
            maximumFrameSize: maximumFrameSize
        )
        let serverFinished = expectation(description: "socket broker rejected oversized request")
        let serverError = LockedErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 1)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath, readChunkSize: 3)
        let response = try codec.decodeResponse(transport.sendFrame(frame))

        wait(for: [serverFinished], timeout: 2)
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        guard case let .failure(failure) = response else {
            return XCTFail("Expected oversized-frame protocol failure response")
        }
        XCTAssertEqual(failure.code, "protocol-error")
        XCTAssertTrue(failure.message.contains("frameTooLarge"), failure.message)
        XCTAssertTrue(failure.message.contains("\(maximumFrameSize)"), failure.message)
        XCTAssertEqual(runtime.events, [])
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

        XCTAssertTrue(BrokerSessionHostUnixSocketServer.socketPathHasActiveBrokerLock(socketPath))
        XCTAssertTrue(BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath))

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath, readChunkSize: 3)
        let client = BrokerSessionHostClientRuntime { frame in
            try transport.sendFrame(frame)
        }

        XCTAssertTrue(try client.isRunning(id: BrokerSessionID(rawValue: "existing-broker-session")))
        wait(for: [serverFinished], timeout: 2)
        XCTAssertFalse(BrokerSessionHostUnixSocketServer.socketPathHasActiveBrokerLock(socketPath))
        XCTAssertNil(serverError.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "listSessions",
            "isRunning existing-broker-session",
        ])
    }

    func testUnixSocketTransportTimesOutWhenAcceptedServerNeverResponds() throws {
        let socketPath = "/tmp/hs-silent-broker-\(UUID().uuidString).sock"
        let serverFD = try makeListeningUnixSocket(at: socketPath)
        defer {
            Darwin.close(serverFD)
            unlink(socketPath)
        }

        let serverFinished = expectation(description: "silent socket server released client")
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                var request = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &request, request.count)
                usleep(500_000)
                Darwin.close(clientFD)
            }
            serverFinished.fulfill()
        }

        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            requestTimeoutMilliseconds: 100
        )
        let startedAt = Date()
        XCTAssertThrowsError(try transport.sendFrame(Data("{}\n".utf8))) { error in
            guard case BrokerSessionHostUnixSocketTransport.TransportError.timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.3)
        wait(for: [serverFinished], timeout: 1)
    }

    func testUnixSocketTransportAcceptsResponseAtMaximumFrameSize() throws {
        let maximumFrameSize = 16
        var response = Data(repeating: 0x78, count: maximumFrameSize - 1)
        response.append(0x0A)

        XCTAssertEqual(
            try rawUnixSocketTransportResult(
                response: response,
                maximumResponseFrameSize: maximumFrameSize
            ).get(),
            response
        )
    }

    func testUnixSocketTransportRejectsOversizedDelimitedResponse() throws {
        let maximumFrameSize = 16
        var response = Data(repeating: 0x78, count: maximumFrameSize)
        response.append(0x0A)

        XCTAssertThrowsError(
            try rawUnixSocketTransportResult(
                response: response,
                maximumResponseFrameSize: maximumFrameSize
            ).get()
        ) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostProtocolError,
                .frameTooLarge(maximumBytes: maximumFrameSize)
            )
        }
    }

    func testUnixSocketTransportRejectsOversizedResponseBeforeDelimiter() throws {
        let maximumFrameSize = 16
        let response = Data(repeating: 0x78, count: maximumFrameSize + 1)

        XCTAssertThrowsError(
            try rawUnixSocketTransportResult(
                response: response,
                maximumResponseFrameSize: maximumFrameSize
            ).get()
        ) { error in
            XCTAssertEqual(
                error as? BrokerSessionHostProtocolError,
                .frameTooLarge(maximumBytes: maximumFrameSize)
            )
        }
    }

    func testUnixSocketServerRefusesToReplaceSilentReachableSocket() throws {
        let socketPath = "/tmp/hs-silent-existing-broker-\(UUID().uuidString).sock"
        let existingServerFD = try makeListeningUnixSocket(at: socketPath)
        defer {
            Darwin.close(existingServerFD)
            unlink(socketPath)
        }

        let existingServerFinished = expectation(description: "silent existing server released probe")
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(existingServerFD, nil, nil)
            if clientFD >= 0 {
                var request = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &request, request.count)
                usleep(500_000)
                Darwin.close(clientFD)
            }
            existingServerFinished.fulfill()
        }

        let replacement = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime())
        )
        XCTAssertThrowsError(try replacement.run(maxConnections: 0)) { error in
            guard case let BrokerSessionHostUnixSocketServer.ServerError.bindFailed(message) = error else {
                return XCTFail("Expected bindFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("may have a reachable broker"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        wait(for: [existingServerFinished], timeout: 1)
    }

    func testLazyUnixSocketTransportDoesNotReplaceIndeterminateBroker() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazyUnixSocketIndeterminateTests-\(UUID().uuidString)")
        let helperURL = temporaryDirectory.appendingPathComponent("replacement-broker")
        let launchMarkerURL = temporaryDirectory.appendingPathComponent("launched")
        let socketPath = "/tmp/hs-lazy-indeterminate-\(UUID().uuidString).sock"
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            unlink(socketPath)
        }
        try """
        #!/bin/sh
        touch "\(launchMarkerURL.path)"
        """.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let existingServerFD = try makeListeningUnixSocket(at: socketPath)
        defer { Darwin.close(existingServerFD) }
        let existingServerFinished = expectation(description: "indeterminate broker released probe")
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(existingServerFD, nil, nil)
            if clientFD >= 0 {
                var request = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &request, request.count)
                usleep(500_000)
                Darwin.close(clientFD)
            }
            existingServerFinished.fulfill()
        }

        let transport = LazyBrokerSessionHostUnixSocketTransport(
            executableURL: helperURL,
            socketPath: socketPath,
            socketWaitTimeoutMilliseconds: 100,
            requestTimeoutMilliseconds: 100
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try transport.sendFrame(Data("{}\n".utf8))) { error in
            guard case BrokerSessionHostUnixSocketTransport.TransportError.timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
        XCTAssertLessThan(Double(elapsedNanoseconds) / 1_000_000_000, 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarkerURL.path))
        wait(for: [existingServerFinished], timeout: 1)
    }

    func testLazyUnixSocketTransportSendsRequestWithoutProbeWhenBrokerIsBusy() throws {
        let runtime = DelayedBrokerSessionRuntime()
        runtime.isRunning = true
        let slowID = BrokerSessionID(rawValue: "busy-broker-slow-session")
        let fastID = BrokerSessionID(rawValue: "busy-broker-fast-session")
        runtime.delayReadOutput(for: slowID, seconds: 0.35)
        let socketPath = "/tmp/hs-lazy-busy-broker-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtime),
            maxConcurrentHandlers: 1
        )
        let serverFinished = expectation(description: "busy broker served both real requests")
        let slowFinished = expectation(description: "slow broker request finished")
        let errorBox = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                errorBox.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let slowStarted = runtime.expectReadStarted(for: slowID)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let directTransport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
                let client = BrokerSessionHostClientRuntime { frame in try directTransport.sendFrame(frame) }
                _ = try client.readAvailableOutput(id: slowID)
            } catch {
                errorBox.set(error)
            }
            slowFinished.fulfill()
        }
        wait(for: [slowStarted], timeout: 1)

        let lazyTransport = LazyBrokerSessionHostUnixSocketTransport(
            executableURL: URL(fileURLWithPath: "/unused-broker-helper"),
            socketPath: socketPath,
            socketWaitTimeoutMilliseconds: 100,
            requestTimeoutMilliseconds: 1_000
        )
        let client = BrokerSessionHostClientRuntime { frame in try lazyTransport.sendFrame(frame) }
        XCTAssertTrue(try client.isRunning(id: fastID))

        wait(for: [slowFinished, serverFinished], timeout: 2)
        XCTAssertNil(errorBox.value.map(String.init(describing:)))
        XCTAssertEqual(runtime.events, [
            "readAvailableOutput busy-broker-slow-session",
            "isRunning busy-broker-fast-session",
        ])
    }

    func testUnixSocketServerRefusesToReplaceBrokerWithMalformedProbeResponse() throws {
        let socketPath = "/tmp/hs-malformed-existing-broker-\(UUID().uuidString).sock"
        let existingServerFD = try makeListeningUnixSocket(at: socketPath)
        defer {
            Darwin.close(existingServerFD)
            unlink(socketPath)
        }

        let existingServerFinished = expectation(description: "malformed existing server answered probe")
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(existingServerFD, nil, nil)
            if clientFD >= 0 {
                var request = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &request, request.count)
                _ = Data("not-a-broker-response\n".utf8).withUnsafeBytes { bytes in
                    Darwin.write(clientFD, bytes.baseAddress, bytes.count)
                }
                Darwin.close(clientFD)
            }
            existingServerFinished.fulfill()
        }

        let replacement = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime())
        )
        XCTAssertThrowsError(try replacement.run(maxConnections: 0)) { error in
            guard case let BrokerSessionHostUnixSocketServer.ServerError.bindFailed(message) = error else {
                return XCTFail("Expected bindFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("may have a reachable broker"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        wait(for: [existingServerFinished], timeout: 1)
    }

    func testUnixSocketServerTimesOutSilentClientsAndReleasesHandlerCapacity() throws {
        let socketPath = "/tmp/hs-server-request-timeout-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime()),
            maxConcurrentHandlers: 1,
            requestTimeoutMilliseconds: 100
        )
        let serverFinished = expectation(description: "server released silent clients")
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

        let firstSilentClient = try makeConnectedUnixSocket(to: socketPath)
        let secondSilentClient = try makeConnectedUnixSocket(to: socketPath)
        defer {
            Darwin.close(firstSilentClient)
            Darwin.close(secondSilentClient)
        }

        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            requestTimeoutMilliseconds: 1_000
        )
        let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
        XCTAssertEqual(try client.listSessions(), [])

        wait(for: [serverFinished], timeout: 2)
        XCTAssertEqual(
            serverError.value as? BrokerSessionHostUnixSocketServer.ServerError,
            .timedOut(socketPath)
        )
    }

    func testUnixSocketServerDoesNotDispatchAcceptedRequestAfterAdmissionDeadline() throws {
        let runtime = DelayedBrokerSessionRuntime()
        let blockingID = BrokerSessionID(rawValue: "deadline-blocking-session")
        let expiredID = BrokerSessionID(rawValue: "deadline-expired-session")
        runtime.delayReadOutput(for: blockingID, seconds: 0.3)
        let socketPath = "/tmp/hs-server-admission-timeout-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtime),
            maxConcurrentHandlers: 1,
            requestTimeoutMilliseconds: 100
        )
        let serverFinished = expectation(description: "server rejected expired accepted request")
        let blockingClientFinished = expectation(description: "blocking request returned")
        let expiredClientFinished = expectation(description: "expired request returned")
        let serverError = LockedErrorBox()
        let blockingClientError = LockedErrorBox()
        let expiredClientError = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 2)
            } catch {
                serverError.set(error)
            }
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let blockingStarted = runtime.expectReadStarted(for: blockingID)
        DispatchQueue.global(qos: .userInitiated).async {
            let transport = BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: 1_000
            )
            let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
            do {
                _ = try client.readAvailableOutput(id: blockingID)
            } catch {
                blockingClientError.set(error)
            }
            blockingClientFinished.fulfill()
        }
        wait(for: [blockingStarted], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            let transport = BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: 1_000
            )
            let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
            do {
                try client.sendInput(id: expiredID, bytes: Array("must-not-run\n".utf8))
            } catch {
                expiredClientError.set(error)
            }
            expiredClientFinished.fulfill()
        }

        wait(for: [blockingClientFinished, expiredClientFinished, serverFinished], timeout: 2)
        XCTAssertEqual(
            serverError.value as? BrokerSessionHostUnixSocketServer.ServerError,
            .timedOut(socketPath)
        )
        XCTAssertNotNil(blockingClientError.value)
        XCTAssertNotNil(expiredClientError.value)
        XCTAssertEqual(runtime.events, ["readAvailableOutput deadline-blocking-session"])
    }

    func testUnixSocketServerDoesNotDispatchBackloggedRequestsAfterClientsDisconnect() throws {
        let runtime = DelayedBrokerSessionRuntime()
        let blockingID = BrokerSessionID(rawValue: "backlog-blocking-session")
        runtime.delayReadOutput(for: blockingID, seconds: 0.35)
        let socketPath = "/tmp/hs-server-backlog-expiry-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtime),
            maxConcurrentHandlers: 1,
            requestTimeoutMilliseconds: 1_000
        )
        let serverFinished = expectation(description: "server drained disconnected backlog")
        let blockingClientFinished = expectation(description: "blocking backlog request returned")
        let expiredClientsFinished = expectation(description: "expired backlog requests returned")
        expiredClientsFinished.expectedFulfillmentCount = 2
        let expiredClientErrors = LockedCounter()
        DispatchQueue.global(qos: .userInitiated).async {
            try? server.run(maxConnections: 3)
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let blockingStarted = runtime.expectReadStarted(for: blockingID)
        DispatchQueue.global(qos: .userInitiated).async {
            let transport = BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: 1_000
            )
            let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
            _ = try? client.readAvailableOutput(id: blockingID)
            blockingClientFinished.fulfill()
        }
        wait(for: [blockingStarted], timeout: 1)

        for index in 1...2 {
            DispatchQueue.global(qos: .userInitiated).async {
                let transport = BrokerSessionHostUnixSocketTransport(
                    socketPath: socketPath,
                    requestTimeoutMilliseconds: 100
                )
                let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
                do {
                    try client.sendInput(
                        id: BrokerSessionID(rawValue: "backlog-expired-\(index)"),
                        bytes: Array("must-not-run-\(index)\n".utf8)
                    )
                } catch {
                    _ = expiredClientErrors.increment()
                }
                expiredClientsFinished.fulfill()
            }
        }

        wait(for: [expiredClientsFinished], timeout: 1)
        wait(for: [blockingClientFinished, serverFinished], timeout: 2)
        XCTAssertEqual(expiredClientErrors.value, 2)
        XCTAssertEqual(runtime.events, ["readAvailableOutput backlog-blocking-session"])
    }

    func testUnixSocketServerRechecksDisconnectedClientInsideSameSessionLane() throws {
        let runtime = DelayedBrokerSessionRuntime()
        let sessionID = BrokerSessionID(rawValue: "lane-expiry-session")
        runtime.delaySendInput(containing: "first", seconds: 0.35)
        let socketPath = "/tmp/hs-server-lane-expiry-\(UUID().uuidString).sock"
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: runtime),
            maxConcurrentHandlers: 2,
            requestTimeoutMilliseconds: 1_000
        )
        let serverFinished = expectation(description: "server drained same-session lane")
        let firstClientFinished = expectation(description: "first lane request returned")
        let expiredClientFinished = expectation(description: "expired lane request returned")
        let expiredClientError = LockedErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            try? server.run(maxConnections: 2)
            serverFinished.fulfill()
        }
        try waitForSocket(at: socketPath)

        let firstStarted = runtime.expectSendStarted(containing: "first")
        DispatchQueue.global(qos: .userInitiated).async {
            let transport = BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: 1_000
            )
            let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
            try? client.sendInput(id: sessionID, bytes: Array("first\n".utf8))
            firstClientFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            let transport = BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: 100
            )
            let client = BrokerSessionHostClientRuntime { frame in try transport.sendFrame(frame) }
            do {
                try client.sendInput(id: sessionID, bytes: Array("second-must-not-run\n".utf8))
            } catch {
                expiredClientError.set(error)
            }
            expiredClientFinished.fulfill()
        }

        wait(for: [expiredClientFinished], timeout: 1)
        wait(for: [firstClientFinished, serverFinished], timeout: 2)
        XCTAssertNotNil(expiredClientError.value)
        XCTAssertEqual(runtime.events, ["sendInput lane-expiry-session first\\n"])
    }

    func testUnixSocketReachabilityPreservesPreLockSocketWhenConnectIsRefused() throws {
        let socketPath = "/tmp/hs-pre-lock-refused-\(UUID().uuidString).sock"
        let legacyServerFD = try makeListeningUnixSocket(at: socketPath)
        Darwin.close(legacyServerFD)
        defer {
            unlink(socketPath)
            unlink(socketPath + ".lock")
        }

        XCTAssertEqual(
            BrokerSessionHostUnixSocketServer.socketPathBrokerReachability(
                socketPath,
                timeoutMilliseconds: 50
            ),
            .indeterminate
        )

        let replacement = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime())
        )
        XCTAssertThrowsError(try replacement.run(maxConnections: 0)) { error in
            guard case let BrokerSessionHostUnixSocketServer.ServerError.bindFailed(message) = error else {
                return XCTFail("Expected bindFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("may have a reachable broker"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath + ".lock"))

        XCTAssertThrowsError(try replacement.run(maxConnections: 0)) { error in
            guard case BrokerSessionHostUnixSocketServer.ServerError.bindFailed = error else {
                return XCTFail("Expected a second bindFailed, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath + ".lock"))
    }

    func testUnixSocketReachabilityRecoversCurrentBrokerStaleSocketWithLockMarker() throws {
        let socketPath = "/tmp/hs-current-stale-\(UUID().uuidString).sock"
        let staleServerFD = try makeListeningUnixSocket(at: socketPath)
        Darwin.close(staleServerFD)
        let lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        Darwin.close(lockFD)
        defer {
            unlink(socketPath)
            unlink(socketPath + ".lock")
        }

        XCTAssertEqual(
            BrokerSessionHostUnixSocketServer.socketPathBrokerReachability(
                socketPath,
                timeoutMilliseconds: 50
            ),
            .unreachable
        )

        let replacement = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: RecordingBrokerSessionRuntime())
        )
        XCTAssertNoThrow(try replacement.run(maxConnections: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testUnixSocketServerDisablesSIGPIPEOnAcceptedDescriptors() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        try BrokerSessionHostUnixSocketServer.configureAcceptedClientSocket(descriptors[0])

        var noSigPipe: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &optionLength),
            0
        )
        XCTAssertEqual(noSigPipe, 1)
        XCTAssertNotEqual(fcntl(descriptors[0], F_GETFL) & O_NONBLOCK, 0)
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

    func testSchedulerReclaimsIdleLanesAfterManyUniqueSessions() throws {
        let scheduler = BrokerSessionOperationScheduler()

        for index in 0..<500 {
            let sessionID = BrokerSessionID(rawValue: "retired-session-\(index)")
            try scheduler.perform(.terminate(id: sessionID, exitCode: 0)) {}
        }

        XCTAssertEqual(scheduler.activeLaneCount, 0)
    }

    func testSchedulerKeepsOneLaneUntilAllAdmittedSameSessionWorkCompletes() throws {
        let scheduler = BrokerSessionOperationScheduler()
        let sessionID = BrokerSessionID(rawValue: "retirement-race")
        let firstStarted = expectation(description: "first operation started")
        let operationsFinished = expectation(description: "both operations finished")
        operationsFinished.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let errors = LockedErrorBox()
        let operationOrder = LockedStringResults()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try scheduler.perform(.terminate(id: sessionID, exitCode: 0)) {
                    operationOrder.append("terminate-start")
                    firstStarted.fulfill()
                    releaseFirst.wait()
                    operationOrder.append("terminate-end")
                }
            } catch {
                errors.set(error)
            }
            operationsFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try scheduler.perform(.sendInput(id: sessionID, bytes: Data("after\n".utf8))) {
                    operationOrder.append("send-input")
                }
            } catch {
                errors.set(error)
            }
            operationsFinished.fulfill()
        }

        let admissionDeadline = Date().addingTimeInterval(1)
        while Date() < admissionDeadline,
              scheduler.admittedOperationCount(for: sessionID) != 2 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(scheduler.admittedOperationCount(for: sessionID), 2)
        XCTAssertEqual(scheduler.activeLaneCount, 1)

        releaseFirst.signal()
        wait(for: [operationsFinished], timeout: 2)

        XCTAssertNil(errors.value)
        XCTAssertEqual(operationOrder.values, ["terminate-start", "terminate-end", "send-input"])
        XCTAssertEqual(scheduler.activeLaneCount, 0)
        XCTAssertEqual(scheduler.admittedOperationCount(for: sessionID), 0)
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
                try server.run(maxConnections: 64)
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
        let firstStartDeadline = Date().addingTimeInterval(1)
        while Date() < firstStartDeadline,
              (firstShell as? ShellChannelController)?.brokerSessionID == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let brokerSessionID = try XCTUnwrap((firstShell as? ShellChannelController)?.brokerSessionID)
        firstLaunchManager.saveState()
        firstLaunchManager.detachAllChannelsForAppTermination()
        let detachDeadline = Date().addingTimeInterval(1)
        while Date() < detachDeadline,
              try registry.load().first(where: { $0.id == brokerSessionID })?.lifecycle != .detached {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            try registry.load().first(where: { $0.id == brokerSessionID })?.lifecycle,
            .detached,
            "The asynchronous host detach must commit before simulating the relaunched UI"
        )

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
        let reattachDeadline = Date().addingTimeInterval(1)
        while Date() < reattachDeadline, restoredShell.brokerSessionID != brokerSessionID {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(restoredShell.brokerSessionID, brokerSessionID)
        XCTAssertEqual(restoredShell.workingDirectory, tempDirectory.path)
        XCTAssertTrue(try secondCoordinator.isRunning(brokerSessionID))
        try secondCoordinator.sendInput(brokerSessionID, bytes: Array("hosted-shell-relaunch-reattach\n".utf8))
        let outputDeadline = Date().addingTimeInterval(3)
        while Date() < outputDeadline,
              !restoredShell.lastLines(20).joined(separator: "\n").contains("hosted-shell-relaunch-reattach") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let output = restoredShell.lastLines(20).joined(separator: "\n")
        XCTAssertTrue(output.contains("hosted-shell-relaunch-reattach"), output)

        let records = try registry.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, brokerSessionID)
        XCTAssertEqual(records[0].channelType, .shell)
        XCTAssertEqual(records[0].lifecycle, .running)
        XCTAssertEqual(records[0].lastAttachedChannelID, restoredShell.channelId)
        XCTAssertEqual(configService.load().channels.map(\.brokerSessionID), [brokerSessionID])

        // The terminal's off-main start/reattach lanes make the exact number of
        // background output polls scheduling-dependent. Drain the bounded test
        // server deterministically instead of coupling this integration test to
        // one incidental connection count.
        for _ in 0..<64 {
            guard (try? secondCoordinator.isRunning(brokerSessionID)) != nil else { break }
        }
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
        let firstStartDeadline = Date().addingTimeInterval(1)
        while Date() < firstStartDeadline, firstTerminal.brokerSessionID == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
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

        let reattachDeadline = Date().addingTimeInterval(1)
        while Date() < reattachDeadline {
            if (try? registry.load().first?.lifecycle) == .running { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
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
                try server.run(maxConnections: 2)
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
            XCTAssertTrue(message.contains("broker lock is already held"), message)
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
            "isRunning original-broker-still-active",
        ])
    }

    private func rawUnixSocketTransportResult(
        response: Data,
        maximumResponseFrameSize: Int
    ) throws -> Result<Data, Error> {
        let socketPath = "/tmp/hs-raw-response-\(UUID().uuidString).sock"
        let serverFD = try makeListeningUnixSocket(at: socketPath)
        defer {
            Darwin.close(serverFD)
            unlink(socketPath)
        }
        let serverFinished = expectation(description: "raw socket response sent")
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                var request = [UInt8](repeating: 0, count: 4096)
                _ = Darwin.read(clientFD, &request, request.count)
                response.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(clientFD, baseAddress.advanced(by: offset), bytes.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
                Darwin.close(clientFD)
            }
            serverFinished.fulfill()
        }

        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            readChunkSize: 3,
            maximumResponseFrameSize: maximumResponseFrameSize
        )
        let result = Result { try transport.sendFrame(Data("{}\n".utf8)) }
        wait(for: [serverFinished], timeout: 1)
        return result
    }

    private func makeListeningUnixSocket(at path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "BrokerSessionHostProtocolTests", code: 2)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in pathBytes.indices {
                rawBuffer[index] = pathBytes[index]
            }
            rawBuffer[pathBytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            let savedErrno = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
        }
        return descriptor
    }

    private func makeConnectedUnixSocket(to path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "BrokerSessionHostProtocolTests", code: 3)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in pathBytes.indices {
                rawBuffer[index] = pathBytes[index]
            }
            rawBuffer[pathBytes.count] = 0
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let savedErrno = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno))
        }
        return descriptor
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

    private func waitForFile(at path: String) throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            usleep(10_000)
        }
        XCTFail("Timed out waiting for helper marker at \(path)")
    }

    private static func waitForFileCreation(at path: String) -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            usleep(10_000)
        }
        return false
    }

    private func helperPID(at url: URL) throws -> pid_t {
        try waitForFile(at: url.path)
        guard let pid = pid_t(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "BrokerSessionHostProtocolTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper did not report a valid PID"])
        }
        return pid
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

    private static func runBrokenPipeProbe(
        helperURL: URL,
        stdinClosedURL: URL,
        helperPIDURL: URL,
        resultURL: URL
    ) {
        _ = Darwin.signal(SIGPIPE, SIG_DFL)
        let result: String
        do {
            let transport = try BrokerSessionHostProcessTransport(
                executableURL: helperURL,
                arguments: [stdinClosedURL.path, helperPIDURL.path]
            )
            defer { transport.close() }
            guard waitForFileCreation(at: stdinClosedURL.path) else {
                try? "E".write(to: resultURL, atomically: true, encoding: .utf8)
                return
            }
            do {
                _ = try transport.sendFrame(Data("{}\\n".utf8))
                result = "N"
            } catch let error as BrokerSessionHostProcessTransport.TransportError {
                result = error == .writeFailed("Broken pipe") ? "W" : "E"
            } catch {
                result = "E"
            }
        } catch {
            result = "E"
        }
        try? result.write(to: resultURL, atomically: true, encoding: .utf8)
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

/// Test-only boundary for immutable values moved to one worker queue.
///
/// Each use joins the worker before the test reads related state. This wrapper
/// deliberately avoids claiming that the production value is generally
/// `Sendable`.
private struct TestSendableValue<Value>: @unchecked Sendable {
    let value: Value
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() -> Int {
        lock.withLock {
            storedValue += 1
            return storedValue
        }
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

private final class LockedStringResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func append(_ value: String) {
        lock.withLock { storedValues.append(value) }
    }
}

private final class LockedDataResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Data] = []

    var values: [Data] {
        lock.withLock { storedValues }
    }

    func append(_ value: Data) {
        lock.withLock { storedValues.append(value) }
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

private final class DelayedBrokerSessionRuntime: BrokerSessionRuntime, BrokerTransactionalOutputRuntime, @unchecked Sendable {
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

    func snapshotAvailableOutput(id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        BrokerOutputSnapshot(data: try readAvailableOutput(id: id), generation: nil)
    }

    func snapshotScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
        BrokerScrollbackReplaySnapshot(
            replay: ScrollbackReplay(data: Data(), source: .liveBrokerMemory, maxBytes: maxBytes),
            generation: nil
        )
    }

    func acknowledgeOutput(id: BrokerSessionID, through generation: UInt64) throws {}

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

private class RecordingBrokerSessionRuntime: BrokerSessionRuntime, ScrollbackReplayReportingRuntime, BrokerTransactionalOutputRuntime {
    var events: [String] = []
    var output = Data()
    var scrollbackReplayGeneration: UInt64?
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

    func snapshotAvailableOutput(id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        let data = try readAvailableOutput(id: id)
        return BrokerOutputSnapshot(data: data, generation: data.isEmpty ? nil : 1)
    }

    func acknowledgeOutput(id: BrokerSessionID, through generation: UInt64) throws {
        try throwIfNeeded()
        events.append("acknowledgeOutput \(id.rawValue) \(generation)")
        if generation >= 1 {
            output.removeAll()
            scrollbackReplayGeneration = nil
        }
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        try throwIfNeeded()
        events.append("readScrollbackTail \(id.rawValue) \(maxBytes)")
        return Data("scrollback-tail".utf8)
    }

    func readScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        try throwIfNeeded()
        events.append("readScrollbackReplay \(id.rawValue) \(maxBytes)")
        return ScrollbackReplay(
            data: Data("scrollback-replay".utf8),
            source: .liveBrokerMemory,
            maxBytes: maxBytes
        )
    }

    func snapshotScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
        BrokerScrollbackReplaySnapshot(
            replay: try readScrollbackReplay(id: id, maxBytes: maxBytes),
            generation: scrollbackReplayGeneration
        )
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

private final class AcknowledgingRecordingBrokerSessionRuntime:
    RecordingBrokerSessionRuntime,
    BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime
{
    var ownerTokenWasApplied = false

    func createSessionAcknowledgingAgentStatusOwnerToken(
        id: BrokerSessionID,
        request: BrokerSessionLaunchRequest
    ) throws -> Bool {
        try createSession(id: id, request: request)
        return ownerTokenWasApplied
    }
}
