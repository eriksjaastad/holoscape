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
}
