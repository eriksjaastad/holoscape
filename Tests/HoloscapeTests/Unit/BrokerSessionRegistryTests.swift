import Darwin
import XCTest
@testable import Holoscape

final class BrokerSessionRegistryTests: XCTestCase {
    private final class ErrorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Error] = []

        var errors: [Error] { lock.withLock { storage } }

        func append(_ error: Error) {
            lock.withLock { storage.append(error) }
        }
    }

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

    func testSaveSynchronizesTemporaryFileBeforeReplacementAndDirectoryAfterReplacement() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        try Data().write(to: registryURL.appendingPathExtension("lock"))
        var events: [String] = []
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in
                events.append("write-and-sync-file")
                try data.write(to: temporaryURL)
            },
            replaceFile: { temporaryURL, destinationURL in
                events.append("replace")
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            },
            synchronizeDirectory: { directoryURL in
                events.append("sync-directory:\(directoryURL.path)")
            },
            removeTemporaryFile: { temporaryURL in
                events.append("remove-temporary")
                try FileManager.default.removeItem(at: temporaryURL)
            }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)
        let record = makeRecord(id: "session-durable", lifecycle: .running, updatedAt: 2)

        try registry.save([record])

        XCTAssertEqual(Array(events.suffix(3)), [
            "write-and-sync-file",
            "replace",
            "sync-directory:\(tempDirectory.path)",
        ])
        XCTAssertEqual(try BrokerSessionRegistry(fileURL: registryURL).load(), [record])
    }

    func testFirstSaveSynchronizesEveryCreatedDirectoryEntryBeforeWritingRegistry() throws {
        let firstDirectory = tempDirectory.appendingPathComponent("first", isDirectory: true)
        let registryDirectory = firstDirectory.appendingPathComponent("registry", isDirectory: true)
        let registryURL = registryDirectory.appendingPathComponent("sessions.json")
        var events: [String] = []
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in
                events.append("write-and-sync-file")
                try data.write(to: temporaryURL)
            },
            replaceFile: { temporaryURL, destinationURL in
                events.append("replace")
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            },
            synchronizeDirectory: { directoryURL in
                events.append("sync-directory:\(directoryURL.path)")
            },
            removeTemporaryFile: { temporaryURL in try FileManager.default.removeItem(at: temporaryURL) }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        try registry.save([makeRecord(id: "session-first-save", lifecycle: .running, updatedAt: 2)])

        let firstDirectorySync = "sync-directory:\(tempDirectory.path)"
        let registryDirectoryParentSync = "sync-directory:\(firstDirectory.path)"
        let writeIndex = try XCTUnwrap(events.firstIndex(of: "write-and-sync-file"))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: firstDirectorySync)), writeIndex)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: registryDirectoryParentSync)), writeIndex)
        XCTAssertEqual(Array(events.suffix(3)), [
            "write-and-sync-file",
            "replace",
            "sync-directory:\(registryDirectory.path)",
        ])
    }

    func testFirstSaveCreatedDirectorySynchronizationFailurePreventsRegistryWrite() throws {
        let registryURL = tempDirectory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("sessions.json")
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { _, _ in
                XCTFail("Registry bytes must not be written before the new directory entry is durable")
            },
            replaceFile: { _, _ in XCTFail("Registry must not be replaced after directory synchronization fails") },
            synchronizeDirectory: { _ in throw RegistryPersistenceFailure.directorySync },
            removeTemporaryFile: { _ in XCTFail("No registry temporary file should exist") }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([
            makeRecord(id: "session-first-save", lifecycle: .running, updatedAt: 2),
        ])) { error in
            let lockError = error as? PersistentFileOperationLocks.LockError
            XCTAssertTrue(lockError?.message.contains("directorySync") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))
    }

    func testLegacyLockFileDoesNotSkipAncestorDurabilityInitialization() throws {
        let registryDirectory = tempDirectory.appendingPathComponent("legacy", isDirectory: true)
        let registryURL = registryDirectory.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data().write(to: registryURL.appendingPathExtension("lock"))
        var events: [String] = []
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in
                events.append("write")
                try data.write(to: temporaryURL)
            },
            replaceFile: { temporaryURL, destinationURL in
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            },
            synchronizeDirectory: { events.append("sync:\($0.path)") },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )

        try BrokerSessionRegistry(fileURL: registryURL, persistence: persistence).save([
            makeRecord(id: "legacy-lock", lifecycle: .running, updatedAt: 2),
        ])

        let writeIndex = try XCTUnwrap(events.firstIndex(of: "write"))
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "sync:\(tempDirectory.path)")),
            writeIndex
        )
    }

    func testFileSynchronizationFailurePreservesPriorRegistryAndRemovesTemporaryFile() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let original = makeRecord(id: "session-original", lifecycle: .running, updatedAt: 1)
        try BrokerSessionRegistry(fileURL: registryURL).save([original])
        var removedTemporaryURL: URL?
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in
                try data.write(to: temporaryURL)
                throw RegistryPersistenceFailure.fileSync
            },
            replaceFile: { _, _ in XCTFail("A failed file sync must not replace the registry") },
            synchronizeDirectory: { _ in XCTFail("A failed file sync must not synchronize the directory") },
            removeTemporaryFile: { _ in XCTFail("descriptor cleanup must be used") },
            removeTemporaryFileAtDescriptor: { descriptor, leaf in
                removedTemporaryURL = self.tempDirectory.appendingPathComponent(leaf)
                try DurableAtomicFileCommitter.removeTemporaryFile(at: descriptor, named: leaf)
            }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([
            makeRecord(id: "session-new", lifecycle: .detached, updatedAt: 2),
        ])) { error in
            XCTAssertEqual(error as? RegistryPersistenceFailure, .fileSync)
        }
        XCTAssertNotNil(removedTemporaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedTemporaryURL?.path ?? ""))
        XCTAssertEqual(try BrokerSessionRegistry(fileURL: registryURL).load(), [original])
    }

    func testReplacementFailurePreservesPriorRegistryAndRemovesTemporaryFile() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let original = makeRecord(id: "session-original", lifecycle: .running, updatedAt: 1)
        try BrokerSessionRegistry(fileURL: registryURL).save([original])
        var removedTemporaryURL: URL?
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in try data.write(to: temporaryURL) },
            replaceFile: { _, _ in throw RegistryPersistenceFailure.replace },
            synchronizeDirectory: { _ in XCTFail("A failed replacement must not synchronize the directory") },
            removeTemporaryFile: { _ in XCTFail("descriptor cleanup must be used") },
            removeTemporaryFileAtDescriptor: { descriptor, leaf in
                removedTemporaryURL = self.tempDirectory.appendingPathComponent(leaf)
                try DurableAtomicFileCommitter.removeTemporaryFile(at: descriptor, named: leaf)
            }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([
            makeRecord(id: "session-new", lifecycle: .detached, updatedAt: 2),
        ])) { error in
            XCTAssertEqual(error as? RegistryPersistenceFailure, .replace)
        }
        XCTAssertNotNil(removedTemporaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedTemporaryURL?.path ?? ""))
        XCTAssertEqual(try BrokerSessionRegistry(fileURL: registryURL).load(), [original])
    }

    func testDirectorySynchronizationFailurePropagatesAfterValidAtomicReplacement() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let replacement = makeRecord(id: "session-new", lifecycle: .detached, updatedAt: 2.75)
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in try data.write(to: temporaryURL) },
            replaceFile: { temporaryURL, destinationURL in
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            },
            synchronizeDirectory: { _ in throw RegistryPersistenceFailure.directorySync },
            removeTemporaryFile: { temporaryURL in try FileManager.default.removeItem(at: temporaryURL) }
        )
        try BrokerSessionRegistry(fileURL: registryURL).save([
            makeRecord(id: "session-original", lifecycle: .running, updatedAt: 1),
        ])
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([replacement])) { error in
            guard case let BrokerSessionRegistry.RegistryError.replacementCommitted(records, durabilityFailure) = error else {
                return XCTFail("Expected typed committed replacement, got \(error)")
            }
            XCTAssertTrue(durabilityFailure.contains("directorySync"), durabilityFailure)
            XCTAssertEqual(records, try? BrokerSessionRegistry(fileURL: registryURL).load())
        }
        XCTAssertEqual(try BrokerSessionRegistry(fileURL: registryURL).load().map(\.id), [replacement.id])
    }

    func testLockCleanupFailureAfterSuccessfulSavePreservesCommittedRecordIdentity() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        try BrokerSessionRegistry(fileURL: registryURL).save([])
        let replacement = makeRecord(id: "lock-cleanup", lifecycle: .running, updatedAt: 3.75)
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in try data.write(to: temporaryURL) },
            replaceFile: { temporaryURL, destinationURL in
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            },
            synchronizeDirectory: { _ in },
            removeTemporaryFile: { temporaryURL in try FileManager.default.removeItem(at: temporaryURL) },
            unlockFileLock: { _ in -1 }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([replacement])) { error in
            guard case let BrokerSessionRegistry.RegistryError.replacementCommitted(records, cleanupFailure) = error else {
                return XCTFail("Expected committed replacement with cleanup failure, got \(error)")
            }
            XCTAssertTrue(cleanupFailure.contains("LOCK_UN"), cleanupFailure)
            XCTAssertEqual(records, try? BrokerSessionRegistry(fileURL: registryURL).load())
        }
    }

    func testLockCleanupFailurePreservesCommittedDirectorySyncFailureIdentity() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        try BrokerSessionRegistry(fileURL: registryURL).save([])
        let replacement = makeRecord(id: "combined-cleanup", lifecycle: .running, updatedAt: 4.75)
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in try data.write(to: temporaryURL) },
            replaceFile: { temporaryURL, destinationURL in
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            },
            synchronizeDirectory: { _ in throw RegistryPersistenceFailure.directorySync },
            removeTemporaryFile: { temporaryURL in try FileManager.default.removeItem(at: temporaryURL) },
            unlockFileLock: { _ in -1 }
        )

        XCTAssertThrowsError(try BrokerSessionRegistry(fileURL: registryURL, persistence: persistence).save([replacement])) { error in
            guard case let BrokerSessionRegistry.RegistryError.replacementCommitted(records, failure) = error else {
                return XCTFail("Expected committed replacement with combined failure, got \(error)")
            }
            XCTAssertTrue(failure.contains("directorySync"), failure)
            XCTAssertTrue(failure.contains("LOCK_UN"), failure)
            XCTAssertEqual(records, try? BrokerSessionRegistry(fileURL: registryURL).load())
        }
    }

    func testSaveReportsBothPersistenceAndTemporaryCleanupFailures() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        try Data().write(to: registryURL.appendingPathExtension("lock"))
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in
                try data.write(to: temporaryURL)
                throw RegistryPersistenceFailure.fileSync
            },
            replaceFile: { _, _ in XCTFail("A failed file sync must not replace the registry") },
            synchronizeDirectory: { _ in },
            removeTemporaryFile: { _ in XCTFail("descriptor cleanup must be used") },
            removeTemporaryFileAtDescriptor: { _, _ in throw RegistryPersistenceFailure.cleanup }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.save([
            makeRecord(id: "session-new", lifecycle: .running, updatedAt: 1),
        ])) { error in
            guard case let BrokerSessionRegistry.RegistryError.persistenceAndCleanupFailed(operation, cleanup) = error else {
                return XCTFail("Expected combined persistence and cleanup error, got \(error)")
            }
            XCTAssertTrue(operation.contains("fileSync"), operation)
            XCTAssertTrue(cleanup.contains("cleanup"), cleanup)
        }
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

    func testConcurrentUpsertsPreserveEverySessionRecord() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let records = (0..<40).map { index in
            makeRecord(id: "session-\(index)", lifecycle: .running, updatedAt: TimeInterval(index + 1))
        }
        let queue = DispatchQueue(label: "BrokerSessionRegistryTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = ErrorRecorder()

        for record in records {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try registry.upsert(record)
                } catch {
                    failures.append(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.errors.isEmpty, "Concurrent registry writes failed: \(failures.errors)")
        XCTAssertEqual(Set(try registry.load().map(\.id)), Set(records.map(\.id)))
    }

    func testSpawnedProcessesPreserveEverySessionRecord() throws {
        if let registryPath = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_CHILD_PATH"],
           let gatePath = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_CHILD_GATE"],
           let prefix = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_CHILD_PREFIX"],
           let countValue = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_CHILD_COUNT"],
           let count = Int(countValue) {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: gatePath) {
                guard Date() < deadline else {
                    return XCTFail("Timed out waiting for parent process gate")
                }
                usleep(1_000)
            }

            let registry = BrokerSessionRegistry(fileURL: URL(fileURLWithPath: registryPath))
            for index in 0..<count {
                try registry.upsert(makeRecord(
                    id: "\(prefix)-\(index)",
                    lifecycle: .running,
                    updatedAt: TimeInterval(index + 1)
                ))
            }
            return
        }

        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let gateURL = tempDirectory.appendingPathComponent("start-gate")
        let processCount = 4
        let recordsPerProcess = 30
        var children: [(process: Process, exited: DispatchSemaphore, output: Pipe)] = []

        for childIndex in 0..<processCount {
            let child = Process()
            let output = Pipe()
            let exited = DispatchSemaphore(value: 0)
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [
                "-XCTest",
                "HoloscapeTests.BrokerSessionRegistryTests/testSpawnedProcessesPreserveEverySessionRecord",
                Bundle(for: Self.self).bundleURL.path,
            ]
            child.environment = ProcessInfo.processInfo.environment.merging([
                "HOLOSCAPE_REGISTRY_CHILD_PATH": registryURL.path,
                "HOLOSCAPE_REGISTRY_CHILD_GATE": gateURL.path,
                "HOLOSCAPE_REGISTRY_CHILD_PREFIX": "child-\(childIndex)",
                "HOLOSCAPE_REGISTRY_CHILD_COUNT": String(recordsPerProcess),
            ]) { _, childValue in childValue }
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { _ in exited.signal() }
            try child.run()
            children.append((child, exited, output))
        }

        try Data().write(to: gateURL)
        for child in children {
            let result = child.exited.wait(timeout: .now() + 15)
            if result == .timedOut {
                child.process.terminate()
                if child.exited.wait(timeout: .now() + 1) == .timedOut {
                    _ = Darwin.kill(child.process.processIdentifier, SIGKILL)
                    _ = child.exited.wait(timeout: .now() + 1)
                }
            }
            let diagnostic = String(
                data: child.output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(result, .success, "Child process timed out: \(diagnostic)")
            XCTAssertEqual(child.process.terminationReason, .exit, "Child process was signaled: \(diagnostic)")
            XCTAssertEqual(child.process.terminationStatus, 0, "Child process failed: \(diagnostic)")
        }

        let records = try BrokerSessionRegistry(fileURL: registryURL).load()
        XCTAssertEqual(records.count, processCount * recordsPerProcess)
        XCTAssertEqual(Set(records.map(\.id)).count, processCount * recordsPerProcess)
    }

    func testConditionalReplaceDoesNotOverwriteNewerLifecycle() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let running = makeRecord(id: "session-race", lifecycle: .running, updatedAt: 1.125)
        let terminating = makeRecord(id: "session-race", lifecycle: .terminating, updatedAt: 2.875)
        let staleDetach = makeRecord(id: "session-race", lifecycle: .detached, updatedAt: 3)
        try registry.save([running])
        XCTAssertTrue(try registry.replace(terminating, ifUnchangedFrom: running))

        XCTAssertFalse(try registry.replace(staleDetach, ifUnchangedFrom: running))
        XCTAssertEqual(try registry.load().map(\.lifecycle), [.terminating])
    }

    func testSpawnedProcessConditionalReplacesAllowOnlyOneWinner() throws {
        if let registryPath = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_REPLACE_CHILD_PATH"],
           let gatePath = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_REPLACE_CHILD_GATE"],
           let resultPath = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_REPLACE_CHILD_RESULT"],
           let lifecycleValue = ProcessInfo.processInfo.environment["HOLOSCAPE_REGISTRY_REPLACE_CHILD_LIFECYCLE"] {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: gatePath) {
                guard Date() < deadline else {
                    return XCTFail("Timed out waiting for parent process gate")
                }
                usleep(1_000)
            }

            let lifecycle: BrokerSessionLifecycle = lifecycleValue == "detached" ? .detached : .terminating
            let expected = makeRecord(id: "session-race", lifecycle: .running, updatedAt: 1)
            let replacement = makeRecord(id: "session-race", lifecycle: lifecycle, updatedAt: 2)
            let replaced = try BrokerSessionRegistry(fileURL: URL(fileURLWithPath: registryPath))
                .replace(replacement, ifUnchangedFrom: expected)
            try Data(replaced ? "1".utf8 : "0".utf8).write(to: URL(fileURLWithPath: resultPath))
            return
        }

        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let gateURL = tempDirectory.appendingPathComponent("replace-gate")
        let registry = BrokerSessionRegistry(fileURL: registryURL)
        try registry.save([makeRecord(id: "session-race", lifecycle: .running, updatedAt: 1)])
        var children: [(process: Process, exited: DispatchSemaphore, output: Pipe, resultURL: URL)] = []

        for lifecycle in ["detached", "terminating"] {
            let child = Process()
            let output = Pipe()
            let exited = DispatchSemaphore(value: 0)
            let resultURL = tempDirectory.appendingPathComponent("replace-\(lifecycle)-result")
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [
                "-XCTest",
                "HoloscapeTests.BrokerSessionRegistryTests/testSpawnedProcessConditionalReplacesAllowOnlyOneWinner",
                Bundle(for: Self.self).bundleURL.path,
            ]
            child.environment = ProcessInfo.processInfo.environment.merging([
                "HOLOSCAPE_REGISTRY_REPLACE_CHILD_PATH": registryURL.path,
                "HOLOSCAPE_REGISTRY_REPLACE_CHILD_GATE": gateURL.path,
                "HOLOSCAPE_REGISTRY_REPLACE_CHILD_RESULT": resultURL.path,
                "HOLOSCAPE_REGISTRY_REPLACE_CHILD_LIFECYCLE": lifecycle,
            ]) { _, childValue in childValue }
            child.standardOutput = output
            child.standardError = output
            child.terminationHandler = { _ in exited.signal() }
            try child.run()
            children.append((child, exited, output, resultURL))
        }

        try Data().write(to: gateURL)
        var results: [String] = []
        for child in children {
            let waitResult = child.exited.wait(timeout: .now() + 10)
            if waitResult == .timedOut {
                child.process.terminate()
                if child.exited.wait(timeout: .now() + 1) == .timedOut {
                    _ = Darwin.kill(child.process.processIdentifier, SIGKILL)
                    _ = child.exited.wait(timeout: .now() + 1)
                }
            }
            let diagnostic = String(
                data: child.output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(waitResult, .success, "Child process timed out: \(diagnostic)")
            XCTAssertEqual(child.process.terminationStatus, 0, "Child process failed: \(diagnostic)")
            if FileManager.default.fileExists(atPath: child.resultURL.path) {
                results.append(try String(contentsOf: child.resultURL, encoding: .utf8))
            }
        }

        XCTAssertEqual(results.sorted(), ["0", "1"])
        XCTAssertTrue([BrokerSessionLifecycle.detached, .terminating].contains(try registry.load()[0].lifecycle))
    }

    func testLoadMissingRegistryReturnsEmptyList() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("missing/sessions.json"))

        XCTAssertEqual(try registry.load(), [])
    }

    func testLoadPropagatesPersistentLockSetupFailure() throws {
        let parentFile = tempDirectory.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: parentFile.path, contents: Data("x".utf8))
        let registry = BrokerSessionRegistry(fileURL: parentFile.appendingPathComponent("sessions.json"))

        XCTAssertThrowsError(try registry.load()) { error in
            let lockError = error as? PersistentFileOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("createDirectory failed") == true)
            XCTAssertTrue(lockError?.message.contains(parentFile.path) == true)
        }
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

    func testPruneFinalRecordsOlderThanCutoffRemovesOnlyExitedAndErroredSessions() throws {
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let oldExited = makeRecord(id: "old-exited", lifecycle: .exited, exitCode: 0, updatedAt: 10)
        let oldErrored = makeRecord(id: "old-errored", lifecycle: .errored, updatedAt: 20)
        let oldStale = makeRecord(id: "old-stale", lifecycle: .stale, updatedAt: 30)
        let oldDetached = makeRecord(id: "old-detached", lifecycle: .detached, updatedAt: 40)
        let recentExited = makeRecord(id: "recent-exited", lifecycle: .exited, exitCode: 0, updatedAt: 90)
        try registry.save([recentExited, oldStale, oldExited, oldDetached, oldErrored])

        let removed = try registry.pruneFinalRecords(updatedBefore: Date(timeIntervalSince1970: 50))

        XCTAssertEqual(removed.map(\.id.rawValue).sorted(), ["old-errored", "old-exited"])
        XCTAssertEqual(
            try registry.load().map(\.id.rawValue),
            ["old-detached", "old-stale", "recent-exited"]
        )
    }

    func testPruneFailurePreservesRemovedAndRetainedCommittedIdentity() throws {
        let registryURL = tempDirectory.appendingPathComponent("prune-committed.json")
        let oldExited = makeRecord(id: "old-exited", lifecycle: .exited, exitCode: 0, updatedAt: 10.75)
        let retained = makeRecord(id: "retained", lifecycle: .running, updatedAt: 20.75)
        try BrokerSessionRegistry(fileURL: registryURL).save([oldExited, retained])
        let persistedOldExited = try XCTUnwrap(
            BrokerSessionRegistry(fileURL: registryURL).load().first { $0.id == oldExited.id }
        )
        let persistence = BrokerSessionRegistry.Persistence(
            writeAndSynchronizeTemporaryFile: { data, temporaryURL in try data.write(to: temporaryURL) },
            replaceFile: { temporaryURL, destinationURL in
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            },
            synchronizeDirectory: { _ in throw RegistryPersistenceFailure.directorySync },
            removeTemporaryFile: { temporaryURL in try FileManager.default.removeItem(at: temporaryURL) }
        )
        let registry = BrokerSessionRegistry(fileURL: registryURL, persistence: persistence)

        XCTAssertThrowsError(try registry.pruneFinalRecords(updatedBefore: Date(timeIntervalSince1970: 15))) { error in
            guard case let BrokerSessionRegistry.RegistryError.pruneCommitted(
                removedRecords,
                retainedRecords,
                durabilityFailure
            ) = error else {
                return XCTFail("Expected typed committed prune, got \(error)")
            }
            XCTAssertEqual(removedRecords, [persistedOldExited])
            XCTAssertEqual(retainedRecords, try? BrokerSessionRegistry(fileURL: registryURL).load())
            XCTAssertTrue(durabilityFailure.contains("directorySync"), durabilityFailure)
        }
        XCTAssertEqual(try BrokerSessionRegistry(fileURL: registryURL).load().map(\.id), [retained.id])
    }

    func testPruneFinalRecordsValidatesBeforeWriting() throws {
        let registryURL = tempDirectory.appendingPathComponent("sessions.json")
        let invalid = makeRecord(id: "invalid-exited", lifecycle: .exited, exitCode: nil, updatedAt: 10)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([invalid]).write(to: registryURL)
        let registry = BrokerSessionRegistry(fileURL: registryURL)

        XCTAssertThrowsError(try registry.pruneFinalRecords(updatedBefore: Date(timeIntervalSince1970: 50)))
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

private enum RegistryPersistenceFailure: Error, Equatable {
    case fileSync
    case replace
    case directorySync
    case cleanup
}
