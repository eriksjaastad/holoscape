import Darwin
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

    func testConcurrentAppendsForSameSessionPreserveEveryPayload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "concurrent-append-session")
        let payloadSize = 4_096
        let payloadCount = 64
        let expectedSize = payloadSize * payloadCount
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: expectedSize)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let errors = ScrollbackStoreErrorRecorder()

        for payloadIndex in 0..<payloadCount {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                start.wait()
                do {
                    try store.append(
                        Data(repeating: UInt8(payloadIndex), count: payloadSize),
                        for: id
                    )
                } catch {
                    errors.record(error)
                }
            }
        }
        for _ in 0..<payloadCount {
            start.signal()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected append errors: \(errors.values)")

        let persisted = try store.readTail(for: id, maxBytes: expectedSize)
        XCTAssertEqual(persisted.count, expectedSize)
        for payloadIndex in 0..<payloadCount {
            XCTAssertEqual(
                persisted.filter { $0 == UInt8(payloadIndex) }.count,
                payloadSize,
                "Payload \(payloadIndex) was overwritten or duplicated"
            )
        }
    }

    func testAppendAndRemoveSerializePerSessionAcrossStoreInstances() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locks = ScrollbackSessionOperationLocks.shared
        let writer = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024
        )
        let remover = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024
        )
        let blockedID = BrokerSessionID(rawValue: "blocked-session")
        let independentID = BrokerSessionID(rawValue: "independent-session")
        let blockedURL = directory
            .appendingPathComponent(blockedID.rawValue)
            .appendingPathExtension("scrollback")
        let lockHeld = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        let appendStarted = DispatchSemaphore(value: 0)
        let appendDone = DispatchSemaphore(value: 0)
        let removeStarted = DispatchSemaphore(value: 0)
        let removeDone = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()
        let firstPayload = Data("first-payload".utf8)

        DispatchQueue.global().async {
            defer { holderDone.signal() }
            do {
                try locks.withLock(for: blockedURL) {
                    lockHeld.signal()
                    releaseLock.wait()
                }
            } catch {
                errors.record(error)
                lockHeld.signal()
            }
        }
        XCTAssertEqual(lockHeld.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            appendStarted.signal()
            do {
                try writer.append(firstPayload, for: blockedID)
            } catch {
                errors.record(error)
            }
            appendDone.signal()
        }
        DispatchQueue.global().async {
            removeStarted.signal()
            do {
                try remover.remove(for: blockedID)
            } catch {
                errors.record(error)
            }
            removeDone.signal()
        }

        XCTAssertEqual(appendStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(removeStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(appendDone.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(removeDone.wait(timeout: .now() + 0.1), .timedOut)

        let independentPayload = Data("independent".utf8)
        try writer.append(independentPayload, for: independentID)
        XCTAssertEqual(
            try writer.readTail(for: independentID, maxBytes: 1_024),
            independentPayload
        )

        releaseLock.signal()
        XCTAssertEqual(holderDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(appendDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(removeDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected operation errors: \(errors.values)")

        let racedTail = try writer.readTail(for: blockedID, maxBytes: 1_024)
        XCTAssertTrue(racedTail.isEmpty || racedTail == firstPayload)

        let postRacePayload = Data("post-race".utf8)
        try writer.append(postRacePayload, for: blockedID)
        XCTAssertTrue(
            try writer.readTail(for: blockedID, maxBytes: 1_024).suffix(postRacePayload.count) == postRacePayload
        )
    }

    func testAppendWaitsForProcessSharedSessionLock() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "cross-process-session")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let scrollbackURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let lockPath = scrollbackURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathExtension("lock")
            .path
        let readyURL = directory.appendingPathComponent("child-ready")
        let releaseURL = directory.appendingPathComponent("child-release")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "HoloscapeTests.DiskBackedScrollbackStoreTests/testProcessSharedLockHelper",
            Bundle(for: Self.self).bundleURL.path
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "HOLOSCAPE_SCROLLBACK_LOCK_HELPER": "1",
            "HOLOSCAPE_SCROLLBACK_LOCK_PATH": lockPath,
            "HOLOSCAPE_SCROLLBACK_READY_PATH": readyURL.path,
            "HOLOSCAPE_SCROLLBACK_RELEASE_PATH": releaseURL.path
        ]) { _, helperValue in helperValue }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? Data().write(to: releaseURL)
            if child.isRunning {
                child.terminate()
            }
        }

        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let appendDone = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()
        DispatchQueue.global().async {
            defer { appendDone.signal() }
            do {
                try store.append(Data("cross-process-payload".utf8), for: id)
            } catch {
                errors.record(error)
            }
        }
        XCTAssertEqual(appendDone.wait(timeout: .now() + 0.1), .timedOut)

        try Data().write(to: releaseURL)
        XCTAssertEqual(appendDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected append errors: \(errors.values)")
        XCTAssertEqual(
            try store.readTail(for: id, maxBytes: 1_024),
            Data("cross-process-payload".utf8)
        )

        let childExited = expectation(description: "process-shared lock helper exited")
        child.terminationHandler = { _ in childExited.fulfill() }
        wait(for: [childExited], timeout: 3)
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testLockSetupWrapsParentDirectoryFailureAsLockError() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentFile = directory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: parentFile.path, contents: Data("x".utf8))
        let sessionURL = parentFile.appendingPathComponent("session.scrollback")

        XCTAssertThrowsError(
            try ScrollbackSessionOperationLocks.shared.withLock(for: sessionURL) {}
        ) { error in
            let lockError = error as? ScrollbackSessionOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("createDirectory failed") == true)
            XCTAssertTrue(lockError?.message.contains(parentFile.path) == true)
        }
    }

    func testListStoredTailsRejectsSymlinkedLockWithoutCreatingForeignTarget() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-symlink-lock")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("persisted-tail".utf8), for: id)
        let lockURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
            .appendingPathExtension("lock")
        let foreignTarget = directory.appendingPathComponent("foreign-lock-target")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: foreignTarget)

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            let lockError = error as? ScrollbackSessionOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("open failed") == true)
            XCTAssertTrue(lockError?.message.contains(lockURL.path) == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignTarget.path))
    }

    func testListStoredTailsRejectsSymlinkSwappedAfterPreflightWithoutForeignLock() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-symlink-swap")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("persisted-tail".utf8), for: id)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignTarget = directory.appendingPathComponent("swap-target.txt")
        try Data("foreign".utf8).write(to: foreignTarget)
        var didSwap = false

        let tails = try store.listStoredTails(resourceValues: { url in
            if url.lastPathComponent == tailURL.lastPathComponent, !didSwap {
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreignTarget)
                didSwap = true
            }
            return try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        })

        XCTAssertTrue(didSwap)
        XCTAssertTrue(tails.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: foreignTarget.appendingPathExtension("lock").path
        ))
    }

    func testListStoredTailsPropagatesProcessSharedLockOpenFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-lock-open-failure")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("persisted-tail".utf8), for: id)

        let lockURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
            .appendingPathExtension("lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            let lockError = error as? ScrollbackSessionOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("open failed") == true)
            XCTAssertTrue(lockError?.message.contains(lockURL.path) == true)
        }
    }

    func testListStoredTailsWaitsForProcessSharedSessionLock() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "cross-process-list-session")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("persisted-tail".utf8), for: id)

        let scrollbackURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let lockPath = scrollbackURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathExtension("lock")
            .path
        let readyURL = directory.appendingPathComponent("list-child-ready")
        let releaseURL = directory.appendingPathComponent("list-child-release")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "HoloscapeTests.DiskBackedScrollbackStoreTests/testProcessSharedLockHelper",
            Bundle(for: Self.self).bundleURL.path
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "HOLOSCAPE_SCROLLBACK_LOCK_HELPER": "1",
            "HOLOSCAPE_SCROLLBACK_LOCK_PATH": lockPath,
            "HOLOSCAPE_SCROLLBACK_READY_PATH": readyURL.path,
            "HOLOSCAPE_SCROLLBACK_RELEASE_PATH": releaseURL.path
        ]) { _, helperValue in helperValue }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? Data().write(to: releaseURL)
            if child.isRunning {
                child.terminate()
            }
        }

        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let listDone = DispatchSemaphore(value: 0)
        let result = ScrollbackTailListRecorder()
        DispatchQueue.global().async {
            defer { listDone.signal() }
            do {
                result.record(.success(try store.listStoredTails()))
            } catch {
                result.record(.failure(error))
            }
        }
        XCTAssertEqual(listDone.wait(timeout: .now() + 0.1), .timedOut)

        try Data().write(to: releaseURL)
        XCTAssertEqual(listDone.wait(timeout: .now() + 2), .success)
        let tails = try result.value?.get()
        XCTAssertEqual(tails?.map(\.sessionID), [id])

        let childExited = expectation(description: "process-shared list lock helper exited")
        child.terminationHandler = { _ in childExited.fulfill() }
        wait(for: [childExited], timeout: 3)
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testProcessSharedLockHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOLOSCAPE_SCROLLBACK_LOCK_HELPER"] == "1" else {
            throw XCTSkip("Subprocess-only lock helper")
        }
        let lockPath = try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_LOCK_PATH"])
        let readyPath = try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_READY_PATH"])
        let releasePath = try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_RELEASE_PATH"])
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        try Data().write(to: URL(fileURLWithPath: readyPath))

        let releaseDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: releasePath), Date() < releaseDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: releasePath))
    }

    func testReadTailRepairsOversizedPersistedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "crash-oversized-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        let suffix = "KEPTTAIL" // exactly 8 bytes

        // Simulate a crash between append's FileHandle write and its prune: the
        // persisted file is left larger than the retention cap.
        let oversized = Data(("LEFTOVER-PREFIX-" + suffix).utf8)
        let url = directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
        try oversized.write(to: url)

        let tail = try store.readTail(for: id, maxBytes: 64)
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), suffix)

        // The read must repair the persisted file back down to the cap.
        XCTAssertEqual(try store.storedByteCount(for: id), 8)
    }

    func testReadTailZeroRetentionOnExistingPersistedFileReturnsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-zero-retention")

        // An existing persisted tail left behind by a positive-retention store.
        let url = directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
        try Data("persisted-tail\n".utf8).write(to: url)

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 0)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 64), Data())
    }

    func testReadTailNegativeRetentionOnExistingPersistedFileReturnsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-negative-retention")

        // An existing persisted tail left behind by a positive-retention store.
        let url = directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
        try Data("persisted-tail\n".utf8).write(to: url)

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: -1)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 64), Data())
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

        // A symlink named like a session tail must not be reported or cause a
        // lock file to be created beside its foreign target.
        let foreignTarget = directory.appendingPathComponent("foreign-target.txt")
        FileManager.default.createFile(atPath: foreignTarget.path, contents: Data("foreign\n".utf8))
        let phantomSymlink = directory.appendingPathComponent("linked").appendingPathExtension("scrollback")
        try FileManager.default.createSymbolicLink(at: phantomSymlink, withDestinationURL: foreignTarget)

        let tails = try store.listStoredTails()
        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignTarget.appendingPathExtension("lock").path))
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

    func testListStoredTailsSkipsEntryWhoseMetadataCannotBeRead() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let surviving = BrokerSessionID(rawValue: "session-survives")
        let vanishing = BrokerSessionID(rawValue: "session-vanishing")

        try store.append(Data("good-tail\n".utf8), for: surviving)
        try store.append(Data("bad-tail\n".utf8), for: vanishing)

        // Simulate the per-entry race where a tail is deleted between directory
        // enumeration and its metadata read: the read throws for exactly that
        // entry while every other entry reads normally. Compare on the session
        // ID stem rather than full URL equality, since the temporary directory
        // path can be returned in symlink-resolved form.
        let tails = try store.listStoredTails(resourceValues: { url in
            if url.deletingPathExtension().lastPathComponent == vanishing.rawValue {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        })

        XCTAssertEqual(tails.map(\.sessionID), [surviving])
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

private final class ScrollbackTailListRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<[DiskBackedScrollbackStore.StoredScrollbackTail], Error>?

    var value: Result<[DiskBackedScrollbackStore.StoredScrollbackTail], Error>? {
        lock.withLock { storage }
    }

    func record(_ result: Result<[DiskBackedScrollbackStore.StoredScrollbackTail], Error>) {
        lock.withLock {
            storage = result
        }
    }
}

private final class ScrollbackStoreErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.withLock { storage }
    }

    func record(_ error: Error) {
        lock.withLock {
            storage.append(error)
        }
    }
}
