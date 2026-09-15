import XCTest
@testable import Holoscape

final class BrokerSessionRecordTests: XCTestCase {
    func testLaunchRequestStoresEnvironmentProfileWithoutRawEnvironment() {
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/Users/test/project",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 120, rows: 40)
        )

        XCTAssertEqual(request.command, "/bin/zsh")
        XCTAssertEqual(request.arguments, ["--login"])
        XCTAssertEqual(request.workingDirectory, "/Users/test/project")
        XCTAssertEqual(request.environmentProfile, .shell)
        XCTAssertEqual(request.initialSize.columns, 120)
        XCTAssertEqual(request.initialSize.rows, 40)
    }

    func testSessionRecordRoundTripsWithStableIdentifierAndLifecycle() throws {
        let id = BrokerSessionID(rawValue: "session-123")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let record = BrokerSessionRecord(
            id: id,
            channelType: .shell,
            label: "holoscape",
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/Users/test/project",
            environmentProfile: .shell,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAttachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(BrokerSessionRecord.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.channelType, .shell)
        XCTAssertEqual(decoded.label, "holoscape")
        XCTAssertEqual(decoded.lifecycle, .detached)
        XCTAssertEqual(decoded.environmentProfile, .shell)
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/project")
        XCTAssertNil(decoded.exitCode)
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.updatedAt, updatedAt)
        XCTAssertEqual(decoded.lastAttachedChannelID?.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testExitedSessionRequiresExitCode() {
        let record = BrokerSessionRecord(
            id: BrokerSessionID(rawValue: "session-124"),
            channelType: .agentDirect,
            label: "agent",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: nil,
            environmentProfile: .agentOAuth,
            lifecycle: .exited,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            lastAttachedChannelID: nil
        )

        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(error as? BrokerSessionRecord.ValidationError, .exitedSessionMissingExitCode)
        }
    }
}
