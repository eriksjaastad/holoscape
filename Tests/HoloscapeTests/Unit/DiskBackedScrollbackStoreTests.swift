import Foundation
import XCTest
@testable import Holoscape

final class DiskBackedScrollbackStoreTests: XCTestCase {
    func testReadTailSurvivesNewStoreInstanceForSameSession() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-survival")

        var store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try store.append(Data("first-line\n".utf8), for: id)
        try store.append(Data("second-line\n".utf8), for: id)

        store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        let restored = String(decoding: try store.readTail(for: id, maxBytes: 64), as: UTF8.self)

        XCTAssertTrue(restored.contains("first-line"), restored)
        XCTAssertTrue(restored.contains("second-line"), restored)
    }

    func testAppendPrunesDiskFileToRetentionCap() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-pruning")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 12)

        try store.append(Data("old-prefix-".utf8), for: id)
        try store.append(Data("kept-suffix".utf8), for: id)

        let restored = String(decoding: try store.readTail(for: id, maxBytes: 64), as: UTF8.self)
        XCTAssertEqual(restored, "-kept-suffix")
    }

    func testInvalidSessionIDCannotEscapeScrollbackDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        let id = BrokerSessionID(rawValue: "../escape")

        XCTAssertThrowsError(try store.append(Data("x".utf8), for: id)) { error in
            XCTAssertEqual(error as? DiskBackedScrollbackStore.StoreError, .invalidSessionID("../escape"))
        }
    }

    func testStoredByteCountReportsZeroAfterManualPrune() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "manual-scrollback-prune")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)

        try store.append(Data("sensitive-output\n".utf8), for: id)
        XCTAssertEqual(try store.storedByteCount(for: id), "sensitive-output\n".utf8.count)

        try store.remove(for: id)

        XCTAssertEqual(try store.storedByteCount(for: id), 0)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 64), Data())
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskBackedScrollbackStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
