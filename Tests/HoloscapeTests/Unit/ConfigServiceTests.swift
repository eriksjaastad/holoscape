import XCTest
@testable import Holoscape

final class ConfigServiceTests: XCTestCase {
    func testConfigSerializationRoundTrip() throws {
        let config = HoloscapeConfig(
            appearance: AppearanceConfig(
                backgroundColor: "#ff0000",
                transparency: 0.8,
                fontFamily: "Menlo",
                fontSize: 14.0,
                ansiColors: ["red": "#ff0000"]
            ),
            channels: [
                ChannelMetadata(
                    id: UUID(),
                    type: .shell,
                    role: "Shell",
                    context: nil,
                    instanceNumber: 1,
                    workingDirectory: "/tmp"
                ),
            ],
            lastLaunchTimestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(decoded.appearance.backgroundColor, config.appearance.backgroundColor)
        XCTAssertEqual(decoded.appearance.transparency, config.appearance.transparency)
        XCTAssertEqual(decoded.appearance.fontFamily, config.appearance.fontFamily)
        XCTAssertEqual(decoded.channels.count, config.channels.count)
        XCTAssertEqual(decoded.channels.first?.type, .shell)
    }

    func testMalformedConfigFallsBackToDefaults() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let malformed = "{ not valid json !!!".data(using: .utf8)!
        let result = try? decoder.decode(HoloscapeConfig.self, from: malformed)
        XCTAssertNil(result, "Malformed JSON should not decode successfully")
    }

    func testMalformedConfigRecordsDiagnosticWithoutOverwritingFile() throws {
        let configDir = temporaryConfigDir()
        let configURL = configDir.appendingPathComponent("config.json")
        let malformed = "{ not valid json !!!"
        try malformed.write(to: configURL, atomically: true, encoding: .utf8)
        let service = ConfigService(configDir: configDir)

        let loaded = service.load()

        XCTAssertEqual(loaded, HoloscapeConfig.default)
        XCTAssertEqual(service.lastDiagnostic?.operation, .load)
        XCTAssertEqual(service.lastDiagnostic?.configPath, configURL.path)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), malformed)
    }

    func testFailedSaveDoesNotPoisonLoadCacheWithUnsavedConfig() throws {
        let tempRoot = temporaryConfigDir()
        let configDir = tempRoot.appendingPathComponent("not-a-directory")
        try "blocking file".write(to: configDir, atomically: true, encoding: .utf8)
        let service = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Unsaved Font"

        XCTAssertFalse(service.save(config))
        let loaded = service.load()

        XCTAssertEqual(service.lastDiagnostic?.operation, .load)
        XCTAssertEqual(loaded.appearance.fontFamily, HoloscapeConfig.default.appearance.fontFamily)
    }

    func testSaveSynchronizesTemporaryBytesBeforeReplacementAndDirectoryAfterward() throws {
        let configDir = temporaryConfigDir()
        var operations: [String] = []
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                operations.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                operations.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { _ in operations.append("sync-directory") },
            removeTemporaryFile: { url in
                operations.append("remove")
                try FileManager.default.removeItem(at: url)
            }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Durable Font"

        XCTAssertTrue(service.save(config))
        XCTAssertEqual(
            Array(operations.suffix(4)),
            ["write", "replace", "sync-directory", "sync-directory"]
        )
        XCTAssertEqual(ConfigService(configDir: configDir).load().appearance.fontFamily, "Durable Font")
    }

    func testPreReplacementFailurePreservesPriorConfigAndCache() throws {
        let configDir = temporaryConfigDir()
        let baselineService = ConfigService(configDir: configDir)
        var baseline = HoloscapeConfig.default
        baseline.appearance.fontFamily = "Baseline Font"
        XCTAssertTrue(baselineService.save(baseline))

        enum InjectedFailure: Error { case write }
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { _, _ in throw InjectedFailure.write },
            replaceFile: { _, _ in XCTFail("replacement must not run") },
            synchronizeDirectory: { _ in XCTFail("directory sync must not run") },
            removeTemporaryFile: { _ in XCTFail("no temporary file was created") }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        var replacement = baseline
        replacement.appearance.fontFamily = "Unsaved Font"

        XCTAssertFalse(service.save(replacement))
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        XCTAssertEqual(ConfigService(configDir: configDir).load().appearance.fontFamily, "Baseline Font")
        XCTAssertEqual(service.lastDiagnostic?.operation, .save)
    }

    func testPostReplacementSyncFailureKeepsCommittedConfigAuthoritative() throws {
        let configDir = temporaryConfigDir()
        enum InjectedFailure: Error { case directorySync }
        var replacementCommitted = false
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                replacementCommitted = true
            },
            synchronizeDirectory: { _ in
                if replacementCommitted { throw InjectedFailure.directorySync }
            },
            removeTemporaryFile: { _ in XCTFail("committed replacement must not be removed") }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Visible Committed Font"

        XCTAssertFalse(service.save(config))
        XCTAssertEqual(service.load().appearance.fontFamily, "Visible Committed Font")
        XCTAssertEqual(
            ConfigService(configDir: configDir).load().appearance.fontFamily,
            "Visible Committed Font"
        )
        XCTAssertEqual(service.lastDiagnostic?.operation, .save)
        XCTAssertTrue(service.lastDiagnostic?.message.contains("replacement committed") == true)
    }

    func testFirstSaveSynchronizesEveryCreatedDirectoryEntryBeforeWriting() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("nested/config")
        var operations: [String] = []
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                operations.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                operations.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { url in operations.append("sync:\(url.path)") },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )

        XCTAssertTrue(ConfigService(configDir: configDir, persistence: persistence).save(.default))
        XCTAssertEqual(
            Array(operations.suffix(6)),
            [
                "sync:\(root.path)",
                "sync:\(root.appendingPathComponent("nested").path)",
                "write",
                "replace",
                "sync:\(configDir.path)",
                "sync:\(configDir.deletingLastPathComponent().path)",
            ]
        )
    }

    func testReplacementFailureRemovesTemporaryFileAndPreservesPriorConfig() throws {
        let configDir = temporaryConfigDir()
        var baseline = HoloscapeConfig.default
        baseline.appearance.fontFamily = "Prior Font"
        XCTAssertTrue(ConfigService(configDir: configDir).save(baseline))

        enum InjectedFailure: Error { case replace }
        var removedTemporaryURL: URL?
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { _, _ in throw InjectedFailure.replace },
            synchronizeDirectory: { _ in XCTFail("directory sync must not run") },
            removeTemporaryFile: { _ in XCTFail("descriptor cleanup must be used") },
            removeTemporaryFileAtDescriptor: { descriptor, leaf in
                removedTemporaryURL = configDir.appendingPathComponent(leaf)
                try DurableAtomicFileCommitter.removeTemporaryFile(at: descriptor, named: leaf)
            }
        )
        var replacement = baseline
        replacement.appearance.fontFamily = "Replacement Font"
        let service = ConfigService(configDir: configDir, persistence: persistence)

        XCTAssertFalse(service.save(replacement))
        XCTAssertNotNil(removedTemporaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedTemporaryURL!.path))
        XCTAssertEqual(ConfigService(configDir: configDir).load().appearance.fontFamily, "Prior Font")
    }

    func testCreatedDirectorySyncFailureRetriesDurabilityInitializationBeforeWriting() throws {
        let configDir = temporaryConfigDir().appendingPathComponent("new-config")
        enum InjectedFailure: Error { case directorySync }
        var events: [String] = []
        var shouldFailSynchronization = true
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                events.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                events.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { url in
                events.append("sync:\(url.path)")
                if shouldFailSynchronization {
                    shouldFailSynchronization = false
                    throw InjectedFailure.directorySync
                }
            },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)

        XCTAssertFalse(service.save(.default))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configDir.appendingPathComponent("config.json").path)
        )
        XCTAssertEqual(service.lastDiagnostic?.operation, .save)

        XCTAssertTrue(service.save(.default))
        XCTAssertTrue(events[1].hasPrefix("sync:"), "retry must resynchronize directory ancestry before write")
        XCTAssertGreaterThan(events.firstIndex(of: "write") ?? 0, 1)
    }

    func testRecreatedDirectorySyncFailureRetriesDurabilityInitializationBeforeWriting() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("recreated-config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        var events: [String] = []
        var failRecreationSynchronization = false
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                events.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                events.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { url in
                events.append("sync:\(url.path)")
                if failRecreationSynchronization {
                    failRecreationSynchronization = false
                    throw CocoaError(.fileWriteUnknown)
                }
            },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        XCTAssertTrue(service.save(.default))

        try FileManager.default.removeItem(at: configDir)
        events.removeAll()
        failRecreationSynchronization = true
        XCTAssertFalse(service.save(.default))
        XCTAssertFalse(events.contains("write"))

        events.removeAll()
        XCTAssertTrue(service.save(.default))
        let firstWrite = try XCTUnwrap(events.firstIndex(of: "write"))
        XCTAssertTrue(
            events[..<firstWrite].contains("sync:\(root.path)"),
            "retry must resynchronize the recreated directory entry before writing"
        )
    }

    func testCompletedDirectoryRecreationResynchronizesParentBeforeWriting() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("replaced-config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        var events: [String] = []
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                events.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                events.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { events.append("sync:\($0.path)") },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        XCTAssertTrue(service.save(.default))

        try FileManager.default.removeItem(at: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        events.removeAll()

        XCTAssertTrue(service.save(.default))
        let firstWrite = try XCTUnwrap(events.firstIndex(of: "write"))
        XCTAssertTrue(
            events[..<firstWrite].contains("sync:\(root.path)"),
            "same-path directory replacement must invalidate cached durability authority"
        )
    }

    func testFreshServiceWithExistingConfigResynchronizesCanonicalParentBeforeWriting() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("restored-config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: configDir.appendingPathComponent("config.json"))
        var events: [String] = []
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                events.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                events.append("replace")
                try DurableAtomicFileCommitter.replaceFile(at: source, with: destination)
            },
            synchronizeDirectory: { events.append("sync:\($0.path)") },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(
            configDir: configDir,
            persistence: persistence,
            assumeExistingDirectoryIsDurable: false
        )

        XCTAssertTrue(service.save(.default))
        let firstWrite = try XCTUnwrap(events.firstIndex(of: "write"))
        XCTAssertTrue(events[..<firstWrite].contains("sync:\(root.path)"))
    }

    func testSymlinkedConfigRootSynchronizesTargetParentBeforeWriting() throws {
        let root = temporaryConfigDir()
        let targetParent = root.appendingPathComponent("target-parent")
        let target = targetParent.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("config-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        var events: [String] = []
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                events.append("write")
                try data.write(to: url)
            },
            replaceFile: { source, destination in
                events.append("replace")
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { events.append("sync:\($0.path)") },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(
            configDir: alias,
            persistence: persistence,
            assumeExistingDirectoryIsDurable: false
        )

        XCTAssertTrue(service.save(.default))
        let firstWrite = try XCTUnwrap(events.firstIndex(of: "write"))
        XCTAssertTrue(events[..<firstWrite].contains("sync:\(targetParent.path)"))
    }

    func testDirectorySwapDuringCommitFailsBeforeReplacement() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        let displaced = root.appendingPathComponent("displaced")
        var didReplace = false
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                try data.write(to: url)
                try FileManager.default.moveItem(at: configDir, to: displaced)
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
            },
            replaceFile: { _, _ in didReplace = true },
            synchronizeDirectory: { _ in },
            removeTemporaryFile: { url in
                let displacedTemporary = displaced.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: displacedTemporary.path) {
                    try FileManager.default.removeItem(at: displacedTemporary)
                }
            }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)

        XCTAssertFalse(service.save(HoloscapeConfig.default))
        XCTAssertFalse(didReplace)
        XCTAssertTrue(service.lastDiagnostic?.message.contains("Directory authority changed") == true)
        let displacedEntries = try FileManager.default.contentsOfDirectory(atPath: displaced.path)
        XCTAssertFalse(displacedEntries.contains { $0.hasSuffix(".tmp") })
    }

    func testDirectorySwapAfterReplacementDoesNotPoisonCache() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        var baseline = HoloscapeConfig.default
        baseline.appearance.fontFamily = "Baseline Font"
        XCTAssertTrue(ConfigService(configDir: configDir).save(baseline))

        let displaced = root.appendingPathComponent("displaced")
        var didSwap = false
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { source, destination in
                try DurableAtomicFileCommitter.replaceFile(at: source, with: destination)
            },
            synchronizeDirectory: { _ in
                guard !didSwap else { return }
                didSwap = true
                try FileManager.default.moveItem(at: configDir, to: displaced)
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
            },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        var replacement = baseline
        replacement.appearance.fontFamily = "Uncertain Font"

        XCTAssertFalse(service.save(replacement))
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        XCTAssertTrue(service.lastDiagnostic?.message.contains("Directory authority changed") == true)
    }

    func testDirectorySwapAndSyncFailureAfterReplacementDoesNotPoisonCache() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        var baseline = HoloscapeConfig.default
        baseline.appearance.fontFamily = "Baseline Font"
        XCTAssertTrue(ConfigService(configDir: configDir).save(baseline))

        let displaced = root.appendingPathComponent("displaced")
        enum InjectedFailure: Error { case directorySync }
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { source, destination in
                try DurableAtomicFileCommitter.replaceFile(at: source, with: destination)
            },
            synchronizeDirectory: { url in
                guard url.path == configDir.path else { return }
                try FileManager.default.moveItem(at: configDir, to: displaced)
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
                throw InjectedFailure.directorySync
            },
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        var replacement = baseline
        replacement.appearance.fontFamily = "Unreachable Font"

        XCTAssertFalse(service.save(replacement))
        XCTAssertEqual(service.load().appearance.fontFamily, "Baseline Font")
        XCTAssertTrue(service.lastDiagnostic?.message.contains("Directory authority") == true)
    }

    func testPreReplacementDisplacementCleansAuthorityWithoutDeletingReplacementLeaf() throws {
        let root = temporaryConfigDir()
        let configDir = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
        let displaced = root.appendingPathComponent("displaced")
        let replacementMarker = Data("replacement-authority".utf8)
        var temporaryLeaf = ""
        enum InjectedFailure: Error { case replace }
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in
                temporaryLeaf = url.lastPathComponent
                try data.write(to: url)
                try FileManager.default.moveItem(at: configDir, to: displaced)
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false)
                try replacementMarker.write(to: configDir.appendingPathComponent(temporaryLeaf))
            },
            replaceFile: { _, _ in throw InjectedFailure.replace },
            synchronizeDirectory: { _ in },
            removeTemporaryFile: { _ in XCTFail("cleanup must remain bound to retained directory authority") }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)

        XCTAssertFalse(service.save(.default))
        XCTAssertEqual(
            try Data(contentsOf: configDir.appendingPathComponent(temporaryLeaf)),
            replacementMarker
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: displaced.appendingPathComponent(temporaryLeaf).path)
        )
    }

    func testDescriptorBoundCleanupFailureIsReported() throws {
        let configDir = temporaryConfigDir()
        enum InjectedFailure: Error { case replace, cleanup }
        let persistence = DurableAtomicFileCommitter.Persistence(
            writeAndSynchronizeTemporaryFile: { data, url in try data.write(to: url) },
            replaceFile: { _, _ in throw InjectedFailure.replace },
            synchronizeDirectory: { _ in },
            removeTemporaryFile: { _ in XCTFail("descriptor cleanup must be used") },
            removeTemporaryFileAtDescriptor: { _, _ in throw InjectedFailure.cleanup }
        )
        let service = ConfigService(configDir: configDir, persistence: persistence)

        XCTAssertFalse(service.save(.default))
        XCTAssertTrue(service.lastDiagnostic?.message.contains("cleanup also failed") == true)
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigServiceTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
