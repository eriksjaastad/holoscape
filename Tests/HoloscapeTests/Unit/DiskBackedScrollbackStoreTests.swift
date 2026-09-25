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

    func testIsValidSessionIDRejectsEmptyAndWhitespaceAndAcceptsValidID() {
        XCTAssertFalse(DiskBackedScrollbackStore.isValidSessionID(""))
        XCTAssertFalse(DiskBackedScrollbackStore.isValidSessionID("   "))
        XCTAssertFalse(DiskBackedScrollbackStore.isValidSessionID("\t\n"))
        XCTAssertTrue(DiskBackedScrollbackStore.isValidSessionID("session-valid-id"))
        XCTAssertTrue(DiskBackedScrollbackStore.isValidSessionID("Session_Valid_ID_0123"))
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

    func testListStoredTailsReportsSessionIDByteSizeAndModificationDate() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let first = BrokerSessionID(rawValue: "session-aaa")
        let second = BrokerSessionID(rawValue: "session-bbb")

        try store.append(Data("hello-world\n".utf8), for: first)
        try store.append(Data("much-longer-payload\n".utf8), for: second)

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [first, second])

        let firstRecord = try XCTUnwrap(tails.first { $0.sessionID == first })
        XCTAssertEqual(firstRecord.byteCount, "hello-world\n".utf8.count)
        XCTAssertNotNil(firstRecord.modifiedAt)

        let secondRecord = try XCTUnwrap(tails.first { $0.sessionID == second })
        XCTAssertEqual(secondRecord.byteCount, "much-longer-payload\n".utf8.count)
    }

    func testListStoredTailsReportsOnlyValidScrollbackFilesInConfiguredDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "session-only-scrollback")

        try store.append(Data("tail-bytes\n".utf8), for: id)

        // Foreign files in the same directory must not surface as session tails,
        // and a non-matching extension must be skipped.
        FileManager.default.createFile(atPath: directory.appendingPathComponent("notes.txt").path, contents: Data("unrelated\n".utf8))
        FileManager.default.createFile(atPath: directory.appendingPathComponent("session-only-scrollback.backup").path, contents: Data("not-scrollback\n".utf8))

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.count, 1)
    }

    func testListStoredTailsSkipsNonRegularScrollbackEntries() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "session-regular-only")

        try store.append(Data("real-tail\n".utf8), for: id)

        // A directory named like a session tail must not be reported.
        let phantomDirectory = directory.appendingPathComponent("phantom").appendingPathExtension("scrollback")
        try FileManager.default.createDirectory(at: phantomDirectory, withIntermediateDirectories: true)

        // A symlink named like a session tail must not be reported either.
        let realFile = directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
        let phantomSymlink = directory.appendingPathComponent("linked").appendingPathExtension("scrollback")
        try FileManager.default.createSymbolicLink(at: phantomSymlink, withDestinationURL: realFile)

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.count, 1)
    }

    func testListStoredTailsReturnsEmptyWhenDirectoryMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskBackedScrollbackStoreTests")
            .appendingPathComponent(UUID().uuidString)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)

        XCTAssertEqual(try store.listStoredTails(), [])
    }

    func testListStoredTailsThrowsWhenDirectoryIsRegularFile() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let regularFile = parent.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: regularFile.path, contents: Data("x".utf8))

        let store = DiskBackedScrollbackStore(directory: regularFile, maxRetainedBytes: 1024)

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, NSFileReadUnknownError)
        }
    }

    func testRemoveMissingTailIsSafeNoOp() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "never-persisted-session")

        XCTAssertNoThrow(try store.remove(for: id))
        XCTAssertEqual(try store.listStoredTails(), [])
    }

    func testRemoveRejectsMaliciousSessionID() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "../escape")

        XCTAssertThrowsError(try store.remove(for: id)) { error in
            XCTAssertEqual(error as? DiskBackedScrollbackStore.StoreError, .invalidSessionID("../escape"))
        }
    }

    func testListStoredTailsSkipsWhitespaceStemScrollbackFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "session-ws-guard")

        try store.append(Data("tail-bytes\n".utf8), for: id)

        // A whitespace-only stem with a `.scrollback` extension must not be reported.
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("   .scrollback").path,
            contents: Data("ws\n".utf8)
        )

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.count, 1)
    }

    func testListStoredTailsSkipsBareEmptyStemScrollbackFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let id = BrokerSessionID(rawValue: "session-empty-stem-guard")

        try store.append(Data("tail-bytes\n".utf8), for: id)

        // A bare `.scrollback` file (empty stem) must not surface as a session tail.
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(".scrollback").path,
            contents: Data("orphan\n".utf8)
        )

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.count, 1)
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskBackedScrollbackStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
