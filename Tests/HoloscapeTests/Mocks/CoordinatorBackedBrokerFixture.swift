import Foundation
import XCTest
@testable import Holoscape

/// Shared fixture for coordinator-backed channel tests.
///
/// Provides a temp registry plus a real `BrokerSessionCoordinator` over a runtime
/// whose broker operations can be failed on demand, so the coordinator-owning
/// channel paths (`SSHChannelController`, and shell/agent controllers with an
/// injected coordinator) can be exercised end to end.
@MainActor
final class CoordinatorBackedBrokerFixture {
    let directory: URL
    let registry: BrokerSessionRegistry
    let runtime: FailingBrokerSessionRuntime
    let coordinator: BrokerSessionCoordinator

    init(timestamp: Date = Date(timeIntervalSince1970: 900)) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatorBackedBrokerFixture-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = BrokerSessionRegistry(fileURL: directory.appendingPathComponent("sessions.json"))
        runtime = FailingBrokerSessionRuntime()
        coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { timestamp }
        )
    }

    func records() throws -> [BrokerSessionRecord] {
        try registry.load()
    }

    func singleRecord(file: StaticString = #filePath, line: UInt = #line) throws -> BrokerSessionRecord {
        let records = try registry.load()
        XCTAssertEqual(records.count, 1, file: file, line: line)
        return records[0]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Make the registry unreadable the way a truncated or corrupt
    /// `sessions.json` does: `BrokerSessionRegistry.load()` throws rather than
    /// pretending the registry is empty, which is what the restore paths must
    /// survive without trapping.
    func corruptRegistry() throws {
        try Data("{ this is not a broker session registry".utf8)
            .write(to: registry.fileURL, options: [.atomic])
    }

    func registryFileContents() throws -> String {
        try String(contentsOf: registry.fileURL, encoding: .utf8)
    }
}
