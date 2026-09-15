import XCTest
@testable import Holoscape

final class BrokerSessionRegistryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionRegistryTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testSaveAndLoadRoundTripsBrokerSessionRecords() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let registry = BrokerSessionRegistry(fileURL: registryURL)
        let record = makeRecord(id: "session-1", lifecycle: .running, updatedAt: 2)

        try registry.save([record])

        let reloaded = BrokerSessionRegistry(fileURL: registryURL)
        XCTAssertEqual(try reloaded.load(), [record])
    }

    func testUpsertReplacesExistingRecordAndKeepsStableSortOrder() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let old = makeRecord(id: "session-b", lifecycle: .running, updatedAt: 1)
        let first = makeRecord(id: "session-a", lifecycle: .detached, updatedAt: 2)
        let replacement = makeRecord(id: "session-b", lifecycle: .detached, updatedAt: 3)

        try registry.save([old])
        try registry.upsert(first)
        try registry.upsert(replacement)

        XCTAssertEqual(try registry.load(), [first, replacement])
    }

    func testLoadMissingRegistryReturnsEmptyList() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("missing/sessions.json"))

        XCTAssertEqual(try registry.load(), [])
    }

    func testSaveValidatesRecordsBeforeWriting() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let registry = BrokerSessionRegistry(fileURL: registryURL)
        let invalid = makeRecord(id: "session-exited", lifecycle: .exited, exitCode: nil, updatedAt: 2)

        XCTAssertThrowsError(try registry.save([invalid])) { error in
            XCTAssertEqual(
                error as? BrokerSessionRegistry.RegistryError,
                .invalidRecord(BrokerSessionID(rawValue: "session-exited"), .exitedSessionMissingExitCode)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))
    }

    func testLoadRejectsCorruptRegistryInsteadOfSilentlyFallingBack() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        try Data("not-json".utf8).write(to: registryURL)
        let registry = BrokerSessionRegistry(fileURL: registryURL)

        XCTAssertThrowsError(try registry.load())
    }

    private func makeRecord(
        id: String,
        lifecycle: BrokerSessionLifecycle,
        exitCode: Int32? = nil,
        updatedAt: TimeInterval
    ) -> BrokerSessionRecord {
        BrokerSessionRecord(
            id: BrokerSessionID(rawValue: id),
            channelType: .shell,
            label: "shell",
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/Users/test/project",
            environmentProfile: .shell,
            lifecycle: lifecycle,
            exitCode: exitCode,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            lastAttachedChannelID: nil
        )
    }
}
