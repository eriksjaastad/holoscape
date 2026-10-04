import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Holoscape

final class DiskBackedScrollbackStoreTests: XCTestCase {
    func testAppendSupportsStableSymlinkedConfiguredDirectory() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        let configured = parent.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: target)
        let id = BrokerSessionID(rawValue: "symlinked-directory")
        let store = DiskBackedScrollbackStore(directory: configured, maxRetainedBytes: 64)

        try store.append(Data("persisted".utf8), for: id)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("symlinked-directory.scrollback")),
            Data("persisted".utf8)
        )
    }

    func testAppendSupportsStableSymlinkedConfiguredDirectoryAncestor() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("scrollback"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let configured = alias.appendingPathComponent("scrollback")
        let store = DiskBackedScrollbackStore(directory: configured, maxRetainedBytes: 64)

        try store.append(Data("persisted".utf8), for: BrokerSessionID(rawValue: "ancestor"))
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("scrollback/ancestor.scrollback")),
            Data("persisted".utf8)
        )
    }

    func testAppendRemainsBoundToOpenedDirectoryAcrossConfiguredDirectoryReplacement() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let configured = parent.appendingPathComponent("configured")
        let displaced = parent.appendingPathComponent("displaced")
        let foreign = parent.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.moveItem(at: configured, to: displaced)
            try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: foreign)
        }
        let id = BrokerSessionID(rawValue: "directory-replacement")
        let store = DiskBackedScrollbackStore(
            directory: configured,
            maxRetainedBytes: 64,
            afterDirectoryOpen: mutation.run
        )

        try store.append(Data("pinned".utf8), for: id)

        XCTAssertEqual(
            try Data(contentsOf: displaced.appendingPathComponent("directory-replacement.scrollback")),
            Data("pinned".utf8)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), [])
    }

    func testFreshStoreRejectsConfiguredDirectoryReplacementBetweenOperations() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let configured = parent.appendingPathComponent("configured")
        let displaced = parent.appendingPathComponent("displaced")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        let id = BrokerSessionID(rawValue: "directory-reanchoring")
        let store = DiskBackedScrollbackStore(directory: configured, maxRetainedBytes: 64)

        try store.append(Data("original".utf8), for: id)
        try FileManager.default.moveItem(at: configured, to: displaced)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        let replacementStore = DiskBackedScrollbackStore(directory: configured, maxRetainedBytes: 64)

        XCTAssertThrowsError(try replacementStore.append(Data("replacement".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(configured.path)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: displaced.appendingPathComponent("directory-reanchoring.scrollback")),
            Data("original".utf8)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: configured.path), [])
    }

    func testFreshProcessRejectsConfiguredDirectoryReplacement() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let configured = parent.appendingPathComponent("configured")
        let displaced = parent.appendingPathComponent("displaced")
        let authorityDirectory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)

        let seed = makeStoreHelper(
            mode: "seed-directory-authority",
            directory: configured,
            authorityDirectory: authorityDirectory
        )
        try seed.run()
        guard waitForProcessExit(seed) else { return }
        XCTAssertEqual(seed.terminationStatus, 0)

        try FileManager.default.moveItem(at: configured, to: displaced)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)

        let replacement = makeStoreHelper(
            mode: "reject-replaced-directory",
            directory: configured,
            authorityDirectory: authorityDirectory
        )
        try replacement.run()
        guard waitForProcessExit(replacement) else { return }
        XCTAssertEqual(replacement.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: configured.path), [])
    }

    func testFreshProcessRejectsConfiguredDirectoryAncestorReplacement() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let configuredAncestor = parent.appendingPathComponent("configured-root")
        let configured = configuredAncestor.appendingPathComponent("nested/scrollback")
        let displacedAncestor = parent.appendingPathComponent("displaced-root")
        let authorityDirectory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)

        let seed = makeStoreHelper(
            mode: "seed-directory-authority",
            directory: configured,
            authorityDirectory: authorityDirectory
        )
        try seed.run()
        guard waitForProcessExit(seed) else { return }
        XCTAssertEqual(seed.terminationStatus, 0)

        try FileManager.default.moveItem(at: configuredAncestor, to: displacedAncestor)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)

        let replacement = makeStoreHelper(
            mode: "reject-replaced-directory",
            directory: configured,
            authorityDirectory: authorityDirectory
        )
        try replacement.run()
        guard waitForProcessExit(replacement) else { return }
        XCTAssertEqual(replacement.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: configured.path), [])
    }

    func testOwnedFilesPublishOnlyAfterDurableInitialization() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "atomic-main-publish")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeOwnedFilePublish: { url in
                if url == tailURL { throw ScrollbackTransactionInterruption() }
            }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains(where: { $0.contains(".creating-") })
        )

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try recovered.append(Data("payload".utf8), for: id)
        XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 1_024), Data("payload".utf8))
    }

    func testFormatMarkerPublishesOnlyAfterDurableInitialization() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "atomic-marker-publish")
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeFormatMarkerPublish: { throw ScrollbackTransactionInterruption() }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains(where: { $0.contains(".creating-") })
        )

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try recovered.append(Data("payload".utf8), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testFormatPublicationResumesAfterPostRenameInterruption() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "format-post-rename-recovery")
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            transactionPhaseHook: { phase in
                if phase == .formatPublicationRenamed { throw ScrollbackTransactionInterruption() }
            }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try recovered.append(Data("payload".utf8), for: id)
        XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 1_024), Data("payload".utf8))
    }

    func testMainPublicationResumesAfterPostRenameInterruption() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "main-post-rename-recovery")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            transactionPhaseHook: { phase in
                if phase == .mainPublicationRenamed { throw ScrollbackTransactionInterruption() }
            }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path))

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try recovered.append(Data("payload".utf8), for: id)
        XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 1_024), Data("payload".utf8))
    }

    func testRecoveryPublicationResumesAfterPostRenameInterruption() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "recovery-post-rename-recovery")
        try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            .append(Data("oversized".utf8), for: id)
        let recoveryURL = directory
            .appendingPathComponent("\(id.rawValue).scrollback")
            .appendingPathExtension("recovery")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            transactionPhaseHook: { phase in
                if phase == .recoveryPublicationRenamed { throw ScrollbackTransactionInterruption() }
            }
        )

        XCTAssertThrowsError(try interrupted.readTail(for: id, maxBytes: 4))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 4)
        XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 4), Data("ized".utf8))
    }

    func testFormatMainAndRecoveryPublicationResumeFromDurablePreRenameIntent() throws {
        do {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let id = BrokerSessionID(rawValue: "format-pre-rename-recovery")
            let interrupted = DiskBackedScrollbackStore(
                directory: directory,
                maxRetainedBytes: 1_024,
                transactionPhaseHook: { phase in
                    if phase == .formatPublicationIntentDurable {
                        throw ScrollbackTransactionInterruption()
                    }
                }
            )
            XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            ))

            let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            try recovered.append(Data("payload".utf8), for: id)
            XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 1_024), Data("payload".utf8))
        }

        do {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let id = BrokerSessionID(rawValue: "main-pre-rename-recovery")
            let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
            let interrupted = DiskBackedScrollbackStore(
                directory: directory,
                maxRetainedBytes: 1_024,
                transactionPhaseHook: { phase in
                    if phase == .mainPublicationIntentDurable {
                        throw ScrollbackTransactionInterruption()
                    }
                }
            )
            XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path))

            let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            try recovered.append(Data("payload".utf8), for: id)
            XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 1_024), Data("payload".utf8))
        }

        do {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let id = BrokerSessionID(rawValue: "recovery-pre-rename-recovery")
            try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
                .append(Data("oversized".utf8), for: id)
            let recoveryURL = directory
                .appendingPathComponent("\(id.rawValue).scrollback")
                .appendingPathExtension("recovery")
            let interrupted = DiskBackedScrollbackStore(
                directory: directory,
                maxRetainedBytes: 4,
                transactionPhaseHook: { phase in
                    if phase == .recoveryPublicationIntentDurable {
                        throw ScrollbackTransactionInterruption()
                    }
                }
            )
            XCTAssertThrowsError(try interrupted.readTail(for: id, maxBytes: 4))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))

            let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 4)
            XCTAssertEqual(try recovered.readTail(for: id, maxBytes: 4), Data("ized".utf8))
        }
    }

    func testPostRenamePublicationReplacementFailsClosedForFormatMainAndRecovery() throws {
        try assertPostRenameReplacementFailsClosed(
            phase: .formatPublicationRenamed,
            id: BrokerSessionID(rawValue: "format-post-rename-replacement"),
            publishedURL: { directory, _ in
                directory.appendingPathComponent(".holoscape-scrollback-format-v2")
            },
            operation: { store, id in
                try store.append(Data("payload".utf8), for: id)
            },
            expectedError: { directory, _ in .unsafeScrollbackDirectory(directory.path) }
        )
        try assertPostRenameReplacementFailsClosed(
            phase: .mainPublicationRenamed,
            id: BrokerSessionID(rawValue: "main-post-rename-replacement"),
            publishedURL: { directory, id in
                directory.appendingPathComponent("\(id.rawValue).scrollback")
            },
            operation: { store, id in
                try store.append(Data("payload".utf8), for: id)
            },
            expectedError: { _, url in .unsafeScrollbackFile(url.path) }
        )

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "recovery-post-rename-replacement")
        try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            .append(Data("oversized".utf8), for: id)
        let recoveryURL = directory
            .appendingPathComponent("\(id.rawValue).scrollback")
            .appendingPathExtension("recovery")
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            transactionPhaseHook: { phase in
                if phase == .recoveryPublicationRenamed { throw ScrollbackTransactionInterruption() }
            }
        )
        XCTAssertThrowsError(try interrupted.readTail(for: id, maxBytes: 4))
        try replacePublishedFileWithMarkerClone(at: recoveryURL)

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 4)
        XCTAssertThrowsError(try recovered.readTail(for: id, maxBytes: 4)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(recoveryURL.path)
            )
        }
    }

    func testOwnedStagingReplacementIsPreservedAndRejected() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "owned-staging-replacement")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let stagingURL = directory.appendingPathComponent(".\(tailURL.lastPathComponent).staging")
        let displacedURL = directory.appendingPathComponent("owned-staging-displaced")
        let foreign = Data("foreign-staging".utf8)
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeOwnedFilePublish: { url in
                guard url == tailURL else { return }
                try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
                try foreign.write(to: stagingURL)
            }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        XCTAssertThrowsError(try recovered.append(Data("payload".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(stagingURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path))
    }

    func testFormatStagingReplacementIsPreservedAndRejected() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "format-staging-replacement")
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let stagingURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2.staging")
        let displacedURL = directory.appendingPathComponent("format-staging-displaced")
        let foreign = Data("foreign-format-staging".utf8)
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeFormatMarkerPublish: {
                try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
                try foreign.write(to: stagingURL)
            }
        )

        XCTAssertThrowsError(try interrupted.append(Data("payload".utf8), for: id))
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        XCTAssertThrowsError(try recovered.append(Data("payload".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testFormatMarkerRejectsStagingReplacementAfterValidationBeforeRename() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let stagingURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2.staging")
        let displacedURL = directory.appendingPathComponent("validated-format-staging")
        let foreign = Data("foreign-after-validation".utf8)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            afterFormatMarkerValidationBeforePublish: {
                try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
                try foreign.write(to: stagingURL)
            }
        )

        XCTAssertThrowsError(
            try store.append(
                Data("payload".utf8),
                for: BrokerSessionID(rawValue: "format-post-validation-race")
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), foreign)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("format-post-validation-race.scrollback").path
            )
        )
    }

    func testFormatMarkerValidationRejectsPathReplacementAfterOpen() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "format-marker-validation-race")
        let payload = Data("persisted".utf8)
        try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            .append(payload, for: id)
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let displacedURL = directory.appendingPathComponent("format-marker-displaced")
        let validContents = try Data(contentsOf: markerURL)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.moveItem(at: markerURL, to: displacedURL)
            try validContents.write(to: markerURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            afterFormatMarkerOpen: mutation.run
        )

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), validContents)
        XCTAssertEqual(try Data(contentsOf: displacedURL), validContents)
    }

    func testFormatMarkerRejectsForeignPreOpenReplacementWithPublicContents() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let authorityDirectory = parent.appendingPathComponent("authority")
        let id = BrokerSessionID(rawValue: "format-marker-owner")
        let payload = Data("persisted".utf8)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: authorityDirectory
        )
        try store.append(payload, for: id)
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let displacedURL = directory.appendingPathComponent("format-marker-displaced")
        let publicContents = try Data(contentsOf: markerURL)
        try FileManager.default.moveItem(at: markerURL, to: displacedURL)
        try publicContents.write(to: markerURL)

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), publicContents)
        XCTAssertEqual(try Data(contentsOf: displacedURL), publicContents)
    }

    func testLegacyMarkerPublicationRaceFailsBeforeV2Authority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "legacy-publication-race")
        let legacyMarkerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v1")
        let legacyContents = Data("HoloScapeScrollbackDirectoryV1\n".utf8)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeLegacyRetirementMarkerPublish: {
                try legacyContents.write(to: legacyMarkerURL, options: .withoutOverwriting)
            }
        )

        XCTAssertThrowsError(try store.append(Data("payload".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: legacyMarkerURL), legacyContents)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-migration.lock").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(id.rawValue).scrollback").path
            )
        )
    }

    func testLegacyRetirementPublicationRejectsStagingPathReplacement() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "legacy-staging-replacement")
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v1")
        let stagingURL = directory.appendingPathComponent(".holoscape-scrollback-format-v1.staging")
        let displacedURL = directory.appendingPathComponent("legacy-staging-displaced")
        let foreign = Data("foreign-legacy-staging".utf8)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeLegacyRetirementMarkerPublish: {
                try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
                try foreign.write(to: stagingURL)
            }
        )

        XCTAssertThrowsError(try store.append(Data("payload".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            )
        )
    }

    func testOversizedFormatMarkerFailsBeforeUnboundedRead() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = BrokerSessionID(rawValue: "format-marker-seed")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("seed".utf8), for: seed)
        let markerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let descriptor = Darwin.open(markerURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, off_t(4) * 1_024 * 1_024 * 1_024), 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        XCTAssertThrowsError(try store.readTail(for: seed, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        XCTAssertEqual(attributes[.size] as? UInt64, 4 * 1_024 * 1_024 * 1_024)
    }

    func testEstablishedV1OwnedDirectoryMigratesToV2() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "prior-v1-owned")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let legacyMarkerURL = directory.appendingPathComponent(".holoscape-scrollback-format-v1")
        let legacyOwner = Data("holoscape-scrollback-main-v1:\(tailURL.lastPathComponent)".utf8)

        try Data("legacy-owned-tail".utf8).write(to: tailURL)
        try Data("HoloScapeScrollbackDirectoryV1\n".utf8).write(to: legacyMarkerURL)
        try setExtendedAttribute(
            at: tailURL,
            name: "com.holoscape.scrollback.owner",
            value: legacyOwner
        )

        let lockURL = tailURL.appendingPathExtension("lock")
        FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        try setExtendedAttribute(
            at: lockURL,
            name: "com.holoscape.scrollback.lock-owner",
            value: Data("holoscape-scrollback-lock-v1:\(lockURL.lastPathComponent)".utf8)
        )

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), Data("legacy-owned-tail".utf8))
        XCTAssertEqual(try Data(contentsOf: tailURL), Data("legacy-owned-tail".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(".holoscape-scrollback-format-v1.staging")),
            Data("HoloScapeScrollbackDirectoryV1\n".utf8)
        )
    }

    func testTrustedOriginMainUnmarkedStoreMigratesWithoutBlessingUntrustedMimic() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let trustedDirectory = parent.appendingPathComponent("trusted")
        let foreignDirectory = parent.appendingPathComponent("foreign")
        let trustedAuthority = parent.appendingPathComponent("trusted-authority")
        let foreignAuthority = parent.appendingPathComponent("foreign-authority")
        try FileManager.default.createDirectory(at: trustedDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: false)
        let id = BrokerSessionID(rawValue: "origin-main-tail")
        let payload = Data("deployed-unmarked-tail".utf8)

        for directory in [trustedDirectory, foreignDirectory] {
            let tail = directory.appendingPathComponent("\(id.rawValue).scrollback")
            try payload.write(to: tail)
            XCTAssertTrue(FileManager.default.createFile(atPath: tail.appendingPathExtension("lock").path, contents: Data()))
        }

        let trusted = DiskBackedScrollbackStore(
            directory: trustedDirectory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: trustedAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )
        XCTAssertEqual(try trusted.readTail(for: id, maxBytes: 1_024), payload)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: trustedDirectory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            )
        )

        let foreign = DiskBackedScrollbackStore(
            directory: foreignDirectory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: foreignAuthority,
            legacyDirectoryHandoff: .denied
        )
        XCTAssertThrowsError(try foreign.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(foreignDirectory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: foreignDirectory.appendingPathComponent("\(id.rawValue).scrollback")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignAuthority.path))
    }

    func testTrustedOriginMainMigrationPreservesSafeOrphanLegacyLock() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let authorityDirectory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let id = BrokerSessionID(rawValue: "deployed-tail")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let lockURL = tailURL.appendingPathExtension("lock")
        let orphanLockURL = directory.appendingPathComponent("orphan-session.scrollback.lock")
        let payload = Data("deployed-unmarked-tail".utf8)
        try payload.write(to: tailURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: orphanLockURL.path, contents: Data()))

        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: authorityDirectory,
            legacyDirectoryHandoff: .trustedDeployedStore
        )

        XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanLockURL.path))
        XCTAssertEqual(try Data(contentsOf: orphanLockURL), Data())
        XCTAssertFalse(
            try extendedAttribute(
                at: orphanLockURL,
                name: "com.holoscape.scrollback.lock-owner"
            ).isEmpty
        )
    }

    func testTrustedOriginMainMigrationRejectsUnsafeOrphanLegacyLocks() throws {
        for unsafeLeaf in [
            "malformed lock.scrollback.lock",
            "foreign.scrollback.lock",
            "nonregular.scrollback.lock",
        ] {
            let parent = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("scrollback")
            let authorityDirectory = parent.appendingPathComponent("authority")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let id = BrokerSessionID(rawValue: "deployed-tail")
            let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
            try Data("deployed-unmarked-tail".utf8).write(to: tailURL)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: tailURL.appendingPathExtension("lock").path,
                contents: Data()
            ))
            let unsafeURL = directory.appendingPathComponent(unsafeLeaf)
            if unsafeLeaf.hasPrefix("nonregular") {
                try FileManager.default.createDirectory(at: unsafeURL, withIntermediateDirectories: false)
            } else if unsafeLeaf.hasPrefix("malformed") {
                XCTAssertTrue(FileManager.default.createFile(atPath: unsafeURL.path, contents: Data()))
            } else {
                XCTAssertTrue(FileManager.default.createFile(atPath: unsafeURL.path, contents: Data("foreign".utf8)))
            }
            let store = DiskBackedScrollbackStore(
                directory: directory,
                maxRetainedBytes: 1_024,
                directoryIdentityAuthorityDirectory: authorityDirectory,
                legacyDirectoryHandoff: .trustedDeployedStore
            )

            XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
                XCTAssertEqual(
                    error as? DiskBackedScrollbackStore.StoreError,
                    .unsafeScrollbackDirectory(directory.path)
                )
            }
        }
    }

    func testPreAnchorV2RequiresTrustedExternalHandoffAndDoesNotMutateStore() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let seedAuthority = parent.appendingPathComponent("seed-authority")
        let deniedAuthority = parent.appendingPathComponent("denied-authority")
        let handoffAuthority = parent.appendingPathComponent("handoff-authority")
        let id = BrokerSessionID(rawValue: "pre-anchor-v2")
        let payload = Data("established-v2".utf8)
        try DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: seedAuthority
        ).append(payload, for: id)
        try FileManager.default.removeItem(at: seedAuthority)

        // Rewrite the just-seeded files to the exact deterministic ownership
        // scheme shipped by the pre-anchor v2 implementation.
        let directoryStatus = try metadata(at: directory)
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let lockURL = tailURL.appendingPathExtension("lock")
        let formatURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let oldMainOwner = Data(
            "holoscape-scrollback-main-v2:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(tailURL.lastPathComponent)".utf8
        )
        let oldFormatOwner = Data(
            "holoscape-scrollback-format-v2-staging:\(directoryStatus.st_dev):\(directoryStatus.st_ino)".utf8
        )
        let oldLockOwner = Data(
            "holoscape-scrollback-lock-v3:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(lockURL.lastPathComponent):legacy-nonce".utf8
        )
        try setExtendedAttribute(at: tailURL, name: "com.holoscape.scrollback.owner", value: oldMainOwner)
        try setExtendedAttribute(at: formatURL, name: "com.holoscape.scrollback.owner", value: oldFormatOwner)
        try setExtendedAttribute(at: lockURL, name: "com.holoscape.scrollback.lock-owner", value: oldLockOwner)
        try removeExtendedAttributes(at: directory, prefixes: [
            "com.holoscape.scrollback.main-",
            "com.holoscape.scrollback.format-owner",
        ])
        let lockDigest = SHA256.hash(data: Data(lockURL.lastPathComponent.utf8))
            .map { String(format: "%02x", $0) }.joined()
        try setExtendedAttribute(
            at: directory,
            name: "com.holoscape.scrollback.lock-\(lockDigest)",
            value: oldLockOwner
        )

        let namesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let attributesBefore = try namesBefore.reduce(into: [String: [FileAttributeKey: Any]]()) { result, name in
            result[name] = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
        }
        let denied = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: deniedAuthority,
            legacyDirectoryHandoff: .denied
        )
        XCTAssertThrowsError(try denied.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deniedAuthority.path))

        let trusted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: handoffAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )
        XCTAssertEqual(try trusted.readTail(for: id, maxBytes: 1_024), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffAuthority.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), namesBefore)
        for name in namesBefore {
            let after = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            XCTAssertEqual(after[.systemFileNumber] as? UInt64, attributesBefore[name]?[.systemFileNumber] as? UInt64)
            XCTAssertEqual(after[.size] as? UInt64, attributesBefore[name]?[.size] as? UInt64)
            XCTAssertEqual(after[.modificationDate] as? Date, attributesBefore[name]?[.modificationDate] as? Date)
        }
    }

    func testReadOnlyPreAnchorInspectionDoesNotMutateExistingEmptyAuthorityDirectory() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let seedAuthority = parent.appendingPathComponent("seed-authority")
        let handoffAuthority = parent.appendingPathComponent("handoff-authority")
        let id = BrokerSessionID(rawValue: "read-only-pre-anchor")
        let payload = Data("established-v2".utf8)
        try seedPreAnchorV2Store(
            directory: directory,
            authorityDirectory: seedAuthority,
            id: id,
            payload: payload
        )
        try FileManager.default.createDirectory(at: handoffAuthority, withIntermediateDirectories: false)
        let before = try metadata(at: handoffAuthority)
        let attributesBefore = try extendedAttributeNames(at: handoffAuthority)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: handoffAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )

        XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), payload)
        let after = try metadata(at: handoffAuthority)
        XCTAssertEqual(try extendedAttributeNames(at: handoffAuthority), attributesBefore)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
    }

    func testTrustedV2HandoffCannotBlessReplacementAfterDirectoryAuthorityExists() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let seedAuthority = parent.appendingPathComponent("seed-authority")
        let handoffAuthority = parent.appendingPathComponent("handoff-authority")
        let legacyID = BrokerSessionID(rawValue: "legacy-v2-tail")
        let anchorID = BrokerSessionID(rawValue: "anchor-current-authority")
        try seedPreAnchorV2Store(
            directory: directory,
            authorityDirectory: seedAuthority,
            id: legacyID,
            payload: Data("trusted-legacy".utf8)
        )
        let trusted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: handoffAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )
        try trusted.append(Data("anchor".utf8), for: anchorID)

        let legacyURL = directory.appendingPathComponent("\(legacyID.rawValue).scrollback")
        let deterministicOwner = try extendedAttribute(
            at: legacyURL,
            name: "com.holoscape.scrollback.owner"
        )
        let displaced = directory.appendingPathComponent("displaced-legacy-v2-tail")
        try FileManager.default.moveItem(at: legacyURL, to: displaced)
        try Data("attacker-replacement".utf8).write(to: legacyURL)
        try setExtendedAttribute(
            at: legacyURL,
            name: "com.holoscape.scrollback.owner",
            value: deterministicOwner
        )

        XCTAssertThrowsError(try trusted.readTail(for: legacyID, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(legacyURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: legacyURL), Data("attacker-replacement".utf8))
    }

    func testTrustedV2InspectionRequiresExactAuthorityAfterAnyFileRecordExists() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let seedAuthority = parent.appendingPathComponent("seed-authority")
        let handoffAuthority = parent.appendingPathComponent("handoff-authority")
        let id = BrokerSessionID(rawValue: "partial-file-authority")
        try seedPreAnchorV2Store(
            directory: directory,
            authorityDirectory: seedAuthority,
            id: id,
            payload: Data("trusted-legacy".utf8)
        )
        try FileManager.default.createDirectory(at: handoffAuthority, withIntermediateDirectories: false)
        let formatURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let lockURL = tailURL.appendingPathExtension("lock")
        try setPersistentFileIdentity(
            authorityDirectory: handoffAuthority,
            configuredDirectory: directory,
            fileURL: formatURL
        )
        try setPersistentFileIdentity(
            authorityDirectory: handoffAuthority,
            configuredDirectory: directory,
            fileURL: lockURL
        )

        let deterministicOwner = try extendedAttribute(
            at: tailURL,
            name: "com.holoscape.scrollback.owner"
        )
        try FileManager.default.moveItem(
            at: tailURL,
            to: directory.appendingPathComponent("displaced-partial-file-authority")
        )
        try Data("attacker-replacement".utf8).write(to: tailURL)
        try setExtendedAttribute(
            at: tailURL,
            name: "com.holoscape.scrollback.owner",
            value: deterministicOwner
        )
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: handoffAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
    }

    func testPreAnchorReadRepairCompletesHandoffBeforeMutatingLegacyFile() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let seedAuthority = parent.appendingPathComponent("seed-authority")
        let handoffAuthority = parent.appendingPathComponent("handoff-authority")
        let id = BrokerSessionID(rawValue: "pre-anchor-read-repair")
        try seedPreAnchorV2Store(
            directory: directory,
            authorityDirectory: seedAuthority,
            id: id,
            payload: Data("oversized".utf8)
        )
        try FileManager.default.createDirectory(at: handoffAuthority, withIntermediateDirectories: false)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            directoryIdentityAuthorityDirectory: handoffAuthority,
            legacyDirectoryHandoff: .trustedDeployedStore
        )

        XCTAssertEqual(try store.readTail(for: id, maxBytes: 4), Data("ized".utf8))
        XCTAssertTrue(
            try extendedAttributeNames(at: handoffAuthority)
                .contains(where: { $0.hasPrefix("com.holoscape.scrollback.directory-") })
        )

        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let deterministicOwner = try extendedAttribute(
            at: tailURL,
            name: "com.holoscape.scrollback.owner"
        )
        try FileManager.default.moveItem(
            at: tailURL,
            to: directory.appendingPathComponent("displaced-read-repair")
        )
        try Data("evil".utf8).write(to: tailURL)
        try setExtendedAttribute(
            at: tailURL,
            name: "com.holoscape.scrollback.owner",
            value: deterministicOwner
        )
        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 4))
    }

    func testUnmarkedNonemptyDirectoryIsNeverAdopted() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "unmarked-nonempty")
        let tailURL = directory.appendingPathComponent("unmarked-nonempty.scrollback")
        try Data("foreign".utf8).write(to: tailURL)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)

        XCTAssertThrowsError(try store.append(Data("payload".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(directory.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), Data("foreign".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".holoscape-scrollback-format-v2").path
            )
        )
    }

    func testUnsafeUnmarkedDirectoryDoesNotPublishPersistentIdentity() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("unsafe")
        let authorityDirectory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: directory.appendingPathComponent("foreign"))
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 64,
            directoryIdentityAuthorityDirectory: authorityDirectory
        )

        XCTAssertThrowsError(
            try store.append(Data("payload".utf8), for: BrokerSessionID(rawValue: "unsafe-no-anchor"))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorityDirectory.path))
    }

    func testPostMarkerUnmarkedTailRemainsForeign() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownedID = BrokerSessionID(rawValue: "owned-tail")
        let foreignID = BrokerSessionID(rawValue: "post-marker-foreign")
        let foreignURL = directory.appendingPathComponent("post-marker-foreign.scrollback")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)

        try store.append(Data("owned".utf8), for: ownedID)
        try Data("foreign".utf8).write(to: foreignURL)

        XCTAssertThrowsError(try store.readTail(for: foreignID, maxBytes: 64)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(foreignURL.path)
            )
        }
        XCTAssertEqual(try store.listStoredTails().map(\.sessionID), [ownedID])
        XCTAssertEqual(try Data(contentsOf: foreignURL), Data("foreign".utf8))
    }


    func testEveryStoreOperationRemainsBoundToOpenedDirectoryAcrossReplacement() throws {
        try assertOperationUsesPinnedDirectory { store, id, _, _ in
            XCTAssertEqual(try store.readTail(for: id, maxBytes: 64), Data("pinned".utf8))
        }
        try assertOperationUsesPinnedDirectory { store, id, _, _ in
            XCTAssertEqual(try store.storedByteCount(for: id), 6)
        }
        try assertOperationUsesPinnedDirectory { store, id, displaced, _ in
            try store.remove(for: id)
            XCTAssertEqual(
                try Data(contentsOf: displaced.appendingPathComponent("directory-operation.scrollback")),
                Data()
            )
        }
        try assertOperationUsesPinnedDirectory { store, id, _, _ in
            XCTAssertEqual(try store.listStoredTails().map(\.sessionID), [id])
        }
    }

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
        try writer.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))

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
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        try store.append(Data(), for: id)
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

    func testConcurrentFirstAuthorityCreationConvergesAcrossProcesses() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let startURL = parent.appendingPathComponent("first-create-start")
        let readyA = parent.appendingPathComponent("first-create-ready-a")
        let readyB = parent.appendingPathComponent("first-create-ready-b")
        let id = BrokerSessionID(rawValue: "cross-process-first-create")

        func makeChild(payload: String, readyURL: URL) -> Process {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = [
                "xctest",
                "-XCTest",
                "HoloscapeTests.DiskBackedScrollbackStoreTests/testConcurrentFirstCreationHelper",
                Bundle(for: Self.self).bundleURL.path
            ]
            child.environment = ProcessInfo.processInfo.environment.merging([
                "HOLOSCAPE_SCROLLBACK_FIRST_CREATE_HELPER": "1",
                "HOLOSCAPE_SCROLLBACK_DIRECTORY": directory.path,
                "HOLOSCAPE_SCROLLBACK_SESSION_ID": id.rawValue,
                "HOLOSCAPE_SCROLLBACK_PAYLOAD": payload,
                "HOLOSCAPE_SCROLLBACK_READY_PATH": readyURL.path,
                "HOLOSCAPE_SCROLLBACK_START_PATH": startURL.path
            ]) { _, helperValue in helperValue }
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            return child
        }

        let childA = makeChild(payload: "A", readyURL: readyA)
        let childB = makeChild(payload: "B", readyURL: readyB)
        let exitedA = expectation(description: "first creation helper A exited")
        let exitedB = expectation(description: "first creation helper B exited")
        childA.terminationHandler = { _ in exitedA.fulfill() }
        childB.terminationHandler = { _ in exitedB.fulfill() }
        try childA.run()
        try childB.run()
        defer {
            for child in [childA, childB] where child.isRunning { child.terminate() }
        }

        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline,
              (!FileManager.default.fileExists(atPath: readyA.path)
                  || !FileManager.default.fileExists(atPath: readyB.path)) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyB.path))
        try Data().write(to: startURL)
        wait(for: [exitedA, exitedB], timeout: 8)
        XCTAssertEqual(childA.terminationStatus, 0)
        XCTAssertEqual(childB.terminationStatus, 0)

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let tail = try store.readTail(for: id, maxBytes: 1_024)
        XCTAssertEqual(Set(tail), Set(Data("AB".utf8)))
        XCTAssertEqual(tail.count, 2)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains(where: { $0.contains(".creating-") })
        )
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
            XCTAssertTrue(lockError?.message.contains(parentFile.lastPathComponent) == true)
        }
    }

    func testLockSetupReportsMetadataAndCleanupFailures() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locks = ScrollbackSessionOperationLocks(
            directoryMetadata: { _ in throw ScrollbackListingMetadataFailure() },
            descriptorClose: { descriptor in
                _ = Darwin.close(descriptor)
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(
            try locks.withLock(for: directory.appendingPathComponent("session.scrollback")) {}
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("ScrollbackListingMetadataFailure"), message)
            XCTAssertTrue(message.contains("cleanup also failed"), message)
            XCTAssertTrue(message.contains("close failed"), message)
        }
    }

    func testAuthorityRetryResyncsStagingAfterOneShotFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oneShotSync = OneShotDescriptorSyncFailure()
        let locks = ScrollbackSessionOperationLocks(descriptorSync: oneShotSync.sync)
        let sessionURL = directory.appendingPathComponent("authority-retry.scrollback")

        XCTAssertThrowsError(try locks.withLock(for: sessionURL) {})
        var operationRan = false
        try locks.withLock(for: sessionURL) {
            operationRan = true
        }

        XCTAssertTrue(operationRan)
        XCTAssertGreaterThan(oneShotSync.callCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("authority-retry.scrollback.lock").path
            )
        )
    }

    func testFailedLockStagingDoesNotUnlinkReplacement() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("lock-staging-replacement.scrollback")
        let stagingURL = directory.appendingPathComponent(".lock-staging-replacement.scrollback.lock.staging")
        let displacedURL = directory.appendingPathComponent("lock-staging-displaced")
        let foreign = Data("foreign-lock-staging".utf8)
        let oneShotSync = OneShotDescriptorSyncFailure {
            try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
            try foreign.write(to: stagingURL)
        }
        let locks = ScrollbackSessionOperationLocks(descriptorSync: oneShotSync.sync)

        XCTAssertThrowsError(try locks.withLock(for: sessionURL) {})
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
        XCTAssertThrowsError(try locks.withLock(for: sessionURL) {}) { error in
            XCTAssertTrue(String(describing: error).contains("unowned lock staging file"))
        }
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
    }

    func testLockPublicationRejectsStagingPathReplacement() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("lock-publication-replacement.scrollback")
        let lockURL = directory.appendingPathComponent("lock-publication-replacement.scrollback.lock")
        let stagingURL = directory.appendingPathComponent(".lock-publication-replacement.scrollback.lock.staging")
        let displacedURL = directory.appendingPathComponent("lock-publication-displaced")
        let foreign = Data("foreign-lock-staging".utf8)
        let oneShotMutation = OneShotDescriptorSyncMutation {
            try FileManager.default.moveItem(at: stagingURL, to: displacedURL)
            try foreign.write(to: stagingURL)
        }
        let locks = ScrollbackSessionOperationLocks(descriptorSync: oneShotMutation.sync)

        XCTAssertThrowsError(try locks.withLock(for: sessionURL) {}) { error in
            XCTAssertTrue(String(describing: error).contains("pathname identity changed"))
        }
        XCTAssertEqual(try Data(contentsOf: stagingURL), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testAppendRejectsSymlinkedTailWithoutMutatingTarget() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "append-symlink-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let targetURL = directory.appendingPathComponent("foreign-append-target")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let original = Data("foreign-original".utf8)
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: tailURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try store.append(Data("-must-not-append".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tailURL.path), targetURL.path)
    }

    func testForeignRegularTailIsRejectedByDirectOperationsAndOmittedFromListing() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "foreign-regular-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        // Unmarked files present before the format marker are legitimate legacy
        // tails. Establish the upgraded format before introducing this foreign
        // regular file so it cannot be adopted by the one-time migration.
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignData = Data("foreign-secret".utf8)
        try foreignData.write(to: tailURL)

        for operation in [
            { try store.append(Data("must-not-append".utf8), for: id) },
            { _ = try store.readTail(for: id, maxBytes: 1_024) },
            { _ = try store.storedByteCount(for: id) },
            { try store.remove(for: id) },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? DiskBackedScrollbackStore.StoreError,
                    .unsafeScrollbackFile(tailURL.path)
                )
            }
            XCTAssertEqual(try? Data(contentsOf: tailURL), foreignData)
        }
        XCTAssertEqual(try store.listStoredTails(), [])
        XCTAssertEqual(try Data(contentsOf: tailURL), foreignData)
    }

    func testStoreOwnedTailReboundFromAnotherSessionIsRejected() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = BrokerSessionID(rawValue: "owned-session-first")
        let secondID = BrokerSessionID(rawValue: "owned-session-second")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("first-data".utf8), for: firstID)
        try store.append(Data("second-data".utf8), for: secondID)
        let firstURL = directory.appendingPathComponent(firstID.rawValue).appendingPathExtension("scrollback")
        let secondURL = directory.appendingPathComponent(secondID.rawValue).appendingPathExtension("scrollback")
        let temporaryURL = directory.appendingPathComponent("swap-temporary")
        try FileManager.default.moveItem(at: firstURL, to: temporaryURL)
        try FileManager.default.moveItem(at: secondURL, to: firstURL)
        try FileManager.default.moveItem(at: temporaryURL, to: secondURL)

        XCTAssertThrowsError(try store.readTail(for: firstID, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(firstURL.path)
            )
        }
        XCTAssertThrowsError(try store.readTail(for: secondID, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(secondURL.path)
            )
        }
        XCTAssertEqual(try store.listStoredTails(), [])
    }

    func testReadAndCountWorkForOwnedReadOnlyTailWhileMutationsFail() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "read-only-owned-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let payload = Data("readable-owned-tail".utf8)
        try store.append(payload, for: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: tailURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tailURL.path) }

        XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), payload)
        XCTAssertEqual(try store.storedByteCount(for: id), payload.count)
        XCTAssertEqual(try store.listStoredTails().map(\.sessionID), [id])
        XCTAssertThrowsError(try store.append(Data("x".utf8), for: id)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EACCES))
        }
        XCTAssertThrowsError(try store.remove(for: id)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EACCES))
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), payload)
    }

    func testSubCapAppendPropagatesDurabilityFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "append-fsync-failure")
        try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            .append(Data("initial".utf8), for: id)
        let failing = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            descriptorSync: { _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(try failing.append(Data("unacknowledged".utf8), for: id)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
    }

    func testEstablishedV2ReadsNeedNeitherWritableLocksNorMigrationAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "established-read-only")
        let payload = Data("read-only-established-v2".utf8)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(payload, for: id)

        let sessionLock = directory.appendingPathComponent("\(id.rawValue).scrollback.lock")
        let migrationLock = directory.appendingPathComponent(".holoscape-scrollback-migration.lock")
        let displacedMigrationLock = directory.appendingPathComponent("migration-lock-displaced")
        try FileManager.default.moveItem(at: migrationLock, to: displacedMigrationLock)
        try FileManager.default.createSymbolicLink(
            at: migrationLock,
            withDestinationURL: directory.appendingPathComponent("foreign-migration-target")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: sessionLock.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionLock.path)
        }

        let reader = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        XCTAssertEqual(try reader.readTail(for: id, maxBytes: 1_024), payload)
        XCTAssertEqual(try reader.storedByteCount(for: id), payload.count)
        XCTAssertEqual(try reader.listStoredTails().map(\.sessionID), [id])
    }

    func testPreAnchorEstablishedV2ReadsDoNotPublishOnReadOnlyStorage() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let authorityDirectory = parent.appendingPathComponent("authority")
        let seed = makeStoreHelper(
            mode: "seed-directory-authority",
            directory: directory,
            authorityDirectory: authorityDirectory
        )
        try seed.run()
        guard waitForProcessExit(seed) else { return }
        XCTAssertEqual(seed.terminationStatus, 0)

        try FileManager.default.removeItem(at: authorityDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let reader = makeStoreHelper(
            mode: "read-pre-anchor-v2",
            directory: directory,
            authorityDirectory: authorityDirectory
        )
        try reader.run()
        guard waitForProcessExit(reader) else { return }
        XCTAssertEqual(reader.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: authorityDirectory.path))
    }

    func testExistingPersistentIdentityIsResyncedAfterPublicationSyncFailure() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("scrollback")
        let authorityDirectory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: authorityDirectory, withIntermediateDirectories: false)
        let authorityStatus = try metadata(at: authorityDirectory)
        let syncProbe = ParentDirectorySyncFailure(expectedParent: authorityStatus)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            descriptorSync: syncProbe.sync,
            directoryIdentityAuthorityDirectory: authorityDirectory
        )
        let id = BrokerSessionID(rawValue: "identity-redurabilization")

        XCTAssertThrowsError(try store.append(Data("first".utf8), for: id))
        try store.append(Data("second".utf8), for: id)

        XCTAssertGreaterThanOrEqual(syncProbe.matchingCallCount, 2)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), Data("second".utf8))
    }

    func testEstablishedV2MissingSessionReadsDoNotCreateLockAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("seed".utf8), for: BrokerSessionID(rawValue: "seed"))
        let missing = BrokerSessionID(rawValue: "missing-session")
        let lockURL = directory.appendingPathComponent("missing-session.scrollback.lock")

        XCTAssertEqual(try store.readTail(for: missing, maxBytes: 1_024), Data())
        XCTAssertEqual(try store.storedByteCount(for: missing), 0)
        XCTAssertEqual(try store.listStoredTails().map(\.sessionID), [BrokerSessionID(rawValue: "seed")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testSmallAppendsDoNotCreateRecoverySidecar() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "efficient-small-appends")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let recoveryURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
            .appendingPathExtension("recovery")

        for byte in UInt8(0)..<32 {
            try store.append(Data([byte]), for: id)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
        XCTAssertEqual(try store.storedByteCount(for: id), 32)
    }

    func testForeignRecoverySidecarBlocksDirectOperationsAndListingWithoutMutation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "foreign-recovery")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let recoveryURL = tailURL.appendingPathExtension("recovery")
        let payload = Data("owned-primary".utf8)
        let foreignRecovery = Data("foreign-recovery-secret".utf8)
        try store.append(payload, for: id)
        try foreignRecovery.write(to: recoveryURL)

        for operation in [
            { try store.append(Data("must-not-append".utf8), for: id) },
            { _ = try store.readTail(for: id, maxBytes: 1_024) },
            { _ = try store.storedByteCount(for: id) },
            { try store.remove(for: id) },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? DiskBackedScrollbackStore.StoreError,
                    .unsafeScrollbackFile(recoveryURL.path)
                )
            }
            XCTAssertEqual(try? Data(contentsOf: tailURL), payload)
            XCTAssertEqual(try? Data(contentsOf: recoveryURL), foreignRecovery)
        }
        XCTAssertThrowsError(try store.listStoredTails()) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(recoveryURL.path)
            )
        }
    }

    func testEmptyForeignRecoverySidecarIsNotTrustedByPathname() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "empty-foreign-recovery")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let recoveryURL = tailURL.appendingPathExtension("recovery")
        let payload = Data("owned-primary".utf8)
        try store.append(payload, for: id)
        XCTAssertTrue(FileManager.default.createFile(atPath: recoveryURL.path, contents: Data()))

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(recoveryURL.path)
            )
        }
        XCTAssertThrowsError(try store.listStoredTails()) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(recoveryURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), payload)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), Data())
    }

    func testRecoveryAfterInterruptionOnceIntentIsDurable() throws {
        try assertRecovery(after: .recoveryIntentDurable)
    }

    func testRecoveryAfterInterruptionOncePrimaryRewriteIsDurable() throws {
        try assertRecovery(after: .primaryRewriteDurable)
    }

    func testMalformedDurableRecoveryFailsClosedWithoutMutatingPrimary() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "malformed-owned-recovery")
        let initialStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        try initialStore.append(Data("12345678".utf8), for: id)
        let interruptedStore = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 8,
            transactionPhaseHook: { phase in
                if phase == .recoveryIntentDurable { throw ScrollbackTransactionInterruption() }
            }
        )
        XCTAssertThrowsError(try interruptedStore.append(Data("ABC".utf8), for: id))

        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let recoveryURL = tailURL.appendingPathExtension("recovery")
        let primaryBeforeCorruption = try Data(contentsOf: tailURL)
        let recoveryHandle = try FileHandle(forWritingTo: recoveryURL)
        try recoveryHandle.truncate(atOffset: 0)
        try recoveryHandle.write(contentsOf: Data("malformed".utf8))
        try recoveryHandle.synchronize()
        try recoveryHandle.close()

        let recoveryStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        XCTAssertThrowsError(try recoveryStore.readTail(for: id, maxBytes: 64))
        XCTAssertThrowsError(try recoveryStore.storedByteCount(for: id))
        XCTAssertThrowsError(try recoveryStore.append(Data("D".utf8), for: id))
        XCTAssertThrowsError(try recoveryStore.remove(for: id))
        XCTAssertThrowsError(try recoveryStore.listStoredTails()) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .corruptRecoveryFile(recoveryURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), primaryBeforeCorruption)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), Data("malformed".utf8))
    }

    func testHugeSparseOwnedRecoveryFailsBeforeUnboundedRead() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "huge-sparse-recovery")
        let initialStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        try initialStore.append(Data("12345678".utf8), for: id)
        let interruptedStore = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 8,
            transactionPhaseHook: { phase in
                if phase == .recoveryIntentDurable { throw ScrollbackTransactionInterruption() }
            }
        )
        XCTAssertThrowsError(try interruptedStore.append(Data("ABC".utf8), for: id))

        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let recoveryURL = tailURL.appendingPathExtension("recovery")
        let primaryBeforeCorruption = try Data(contentsOf: tailURL)
        let descriptor = Darwin.open(recoveryURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, off_t(4) * 1_024 * 1_024 * 1_024), 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        let recoveryStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        XCTAssertThrowsError(try recoveryStore.readTail(for: id, maxBytes: 8)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .corruptRecoveryFile(recoveryURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), primaryBeforeCorruption)
        let attributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        XCTAssertEqual(attributes[.size] as? UInt64, 4 * 1_024 * 1_024 * 1_024)
    }

    func testReadAndCountRejectSymlinkedTailWithoutDisclosingTarget() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "read-symlink-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let targetURL = directory.appendingPathComponent("foreign-read-target")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        try Data("foreign-secret".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: tailURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertThrowsError(try store.storedByteCount(for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
    }

    func testRemoveRejectsSymlinkedTailWithoutDeletingLinkOrTarget() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "remove-symlink-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let targetURL = directory.appendingPathComponent("foreign-remove-target")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let original = Data("foreign-preserved".utf8)
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: tailURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try store.remove(for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tailURL.path), targetURL.path)
    }

    func testFIFOLeafIsRejectedWithoutBlocking() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "fifo-tail")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        try store.append(Data(), for: BrokerSessionID(rawValue: "format-seed"))
        XCTAssertEqual(mkfifo(tailURL.path, S_IRUSR | S_IWUSR), 0)

        let done = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                _ = try store.readTail(for: id, maxBytes: 1_024)
            } catch {
                errors.record(error)
            }
        }

        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            errors.values.first as? DiskBackedScrollbackStore.StoreError,
            .unsafeScrollbackFile(tailURL.path)
        )
    }

    func testRemoveRejectsSymlinkSwappedAfterDescriptorValidation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "remove-swap-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let targetURL = directory.appendingPathComponent("remove-swap-target")
        let targetData = Data("preserve-target".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try setupStore.append(Data("tail".utf8), for: id)
        try targetData.write(to: targetURL)
        let mutation = OneShotScrollbackLeafMutation { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: targetURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeLeafMutation: mutation.run
        )

        XCTAssertThrowsError(try store.remove(for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tailURL.path), targetURL.path)
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
    }

    func testPruneRejectsSymlinkSwappedAfterDescriptorValidation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "prune-swap-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let targetURL = directory.appendingPathComponent("prune-swap-target")
        let targetData = Data("preserve-target".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 4)
        try setupStore.append(Data("ABCD".utf8), for: id)
        try targetData.write(to: targetURL)
        let mutation = OneShotScrollbackLeafMutation { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: targetURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            beforeLeafMutation: mutation.run
        )

        XCTAssertThrowsError(try store.append(Data("E".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tailURL.path), targetURL.path)
        XCTAssertEqual(try Data(contentsOf: targetURL), targetData)
    }

    func testAppendDoesNotMutateReplacementReboundAfterIdentityValidation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "descriptor-append-rebind-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignData = Data("foreign-primary".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 4)
        try setupStore.append(Data("ABCD".utf8), for: id)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.removeItem(at: tailURL)
            try foreignData.write(to: tailURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            beforeDescriptorMutation: mutation.run
        )

        XCTAssertThrowsError(try store.append(Data("E".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), foreignData)
    }

    func testReadRepairRejectsSourceLeafReboundAfterDescriptorRead() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "read-source-rebind-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignData = Data("foreign-source".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try setupStore.append(Data("oversized-tail".utf8), for: id)
        let mutation = OneShotScrollbackLeafMutation { url in
            XCTAssertEqual(url, tailURL)
            try FileManager.default.removeItem(at: url)
            try foreignData.write(to: url)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            beforeLeafMutation: mutation.run
        )

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 4)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), foreignData)
    }

    func testReadRepairDoesNotMutateReplacementReboundAfterIdentityValidation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "descriptor-read-rebind-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignData = Data("foreign-primary".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try setupStore.append(Data("oversized-tail".utf8), for: id)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.removeItem(at: tailURL)
            try foreignData.write(to: tailURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 4,
            beforeDescriptorMutation: mutation.run
        )

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 4)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), foreignData)
    }

    func testRemoveDoesNotMutateReplacementReboundAfterIdentityValidation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "descriptor-remove-rebind-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignData = Data("foreign-primary".utf8)
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try setupStore.append(Data("tail".utf8), for: id)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.removeItem(at: tailURL)
            try foreignData.write(to: tailURL)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 64,
            beforeDescriptorMutation: mutation.run
        )

        XCTAssertThrowsError(try store.remove(for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: tailURL), foreignData)
    }

    func testRemoveClearsInodeAndHidesEmptyTailWithoutPathDeletion() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "descriptor-cleared-tail")
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try store.append(Data("sensitive-tail".utf8), for: id)

        try store.remove(for: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path))
        XCTAssertEqual(try Data(contentsOf: tailURL), Data())
        XCTAssertEqual(try store.listStoredTails(), [])
    }

    func testListStoredTailsRejectsSymlinkedLockWithoutCreatingForeignTarget() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-symlink-lock")
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try setupStore.append(Data("persisted-tail".utf8), for: id)
        let lockURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
            .appendingPathExtension("lock")
        let foreignTarget = directory.appendingPathComponent("foreign-lock-target")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: foreignTarget)

        XCTAssertThrowsError(try setupStore.listStoredTails()) { error in
            let lockError = error as? ScrollbackSessionOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("openat failed") == true)
            XCTAssertTrue(lockError?.message.contains(lockURL.path) == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignTarget.path))
    }

    func testRegularLockReplacementCannotCreateSplitProcessAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { _ = Darwin.close(directoryDescriptor) }
        var mutableDirectoryStatus = stat()
        XCTAssertEqual(fstat(directoryDescriptor, &mutableDirectoryStatus), 0)
        let directoryStatus = mutableDirectoryStatus
        let fileName = "split-authority.scrollback"
        let displayPath = directory.appendingPathComponent(fileName).path
        let lockURL = directory.appendingPathComponent(fileName + ".lock")
        let firstLocks = ScrollbackSessionOperationLocks()
        let secondLocks = ScrollbackSessionOperationLocks()
        let firstHeld = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()

        DispatchQueue.global().async {
            defer { firstDone.signal() }
            do {
                try firstLocks.withLock(
                    directoryDescriptor: directoryDescriptor,
                    directoryStatus: directoryStatus,
                    fileName: fileName,
                    displayPath: displayPath
                ) {
                    firstHeld.signal()
                    releaseFirst.wait()
                }
            } catch {
                errors.record(error)
                firstHeld.signal()
            }
        }
        XCTAssertEqual(firstHeld.wait(timeout: .now() + 2), .success)
        try FileManager.default.moveItem(
            at: lockURL,
            to: directory.appendingPathComponent("displaced.lock")
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data()))

        XCTAssertThrowsError(
            try secondLocks.withLock(
                directoryDescriptor: directoryDescriptor,
                directoryStatus: directoryStatus,
                fileName: fileName,
                displayPath: displayPath
            ) {
                secondEntered.signal()
            }
        ) { error in
            let lockError = error as? ScrollbackSessionOperationLocks.LockError
            XCTAssertNotNil(lockError)
            XCTAssertTrue(lockError?.message.contains("unowned lock file") == true)
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected holder errors: \(errors.values)")
    }

    func testMetadataPreservingLockCloneCannotReplayPublishedAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        guard directoryDescriptor >= 0 else { return }
        defer { _ = Darwin.close(directoryDescriptor) }
        var measuredDirectoryStatus = stat()
        XCTAssertEqual(fstat(directoryDescriptor, &measuredDirectoryStatus), 0)
        let directoryStatus = measuredDirectoryStatus
        let fileName = "cloned-lock.scrollback"
        let displayPath = directory.appendingPathComponent(fileName).path
        let lockURL = directory.appendingPathComponent(fileName + ".lock")
        let cloneURL = directory.appendingPathComponent("cloned-lock-replacement")
        let displacedURL = directory.appendingPathComponent("cloned-lock-original")
        let firstLocks = ScrollbackSessionOperationLocks()
        let secondLocks = ScrollbackSessionOperationLocks()
        let firstHeld = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()

        DispatchQueue.global().async {
            defer { firstDone.signal() }
            do {
                try firstLocks.withLock(
                    directoryDescriptor: directoryDescriptor,
                    directoryStatus: directoryStatus,
                    fileName: fileName,
                    displayPath: displayPath
                ) {
                    firstHeld.signal()
                    releaseFirst.wait()
                }
            } catch {
                errors.record(error)
                firstHeld.signal()
            }
        }
        XCTAssertEqual(firstHeld.wait(timeout: .now() + 2), .success)
        try FileManager.default.copyItem(at: lockURL, to: cloneURL)
        try FileManager.default.moveItem(at: lockURL, to: displacedURL)
        try FileManager.default.moveItem(at: cloneURL, to: lockURL)

        XCTAssertThrowsError(
            try secondLocks.withLock(
                directoryDescriptor: directoryDescriptor,
                directoryStatus: directoryStatus,
                fileName: fileName,
                displayPath: displayPath
            ) {
                XCTFail("A cloned lock inode must not acquire parallel authority")
            }
        )
        releaseFirst.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected holder errors: \(errors.values)")
    }

    func testMetadataPreservingMainCloneCannotReplayPublishedAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "cloned-main")
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(Data("original".utf8), for: id)
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let cloneURL = directory.appendingPathComponent("cloned-main-replacement")
        let displacedURL = directory.appendingPathComponent("cloned-main-original")
        try FileManager.default.copyItem(at: tailURL, to: cloneURL)
        try FileManager.default.moveItem(at: tailURL, to: displacedURL)
        try FileManager.default.moveItem(at: cloneURL, to: tailURL)

        XCTAssertThrowsError(try store.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
    }

    func testMissingHeldLockCannotCreateSplitProcessAuthority() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        var mutableDirectoryStatus = stat()
        XCTAssertEqual(fstat(descriptor, &mutableDirectoryStatus), 0)
        let directoryStatus = mutableDirectoryStatus
        let fileName = "missing-authority.scrollback"
        let displayPath = directory.appendingPathComponent(fileName).path
        let lockURL = directory.appendingPathComponent(fileName + ".lock")
        let firstLocks = ScrollbackSessionOperationLocks()
        let secondLocks = ScrollbackSessionOperationLocks()
        let firstHeld = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let errors = ScrollbackStoreErrorRecorder()

        DispatchQueue.global().async {
            defer { firstDone.signal() }
            do {
                try firstLocks.withLock(
                    directoryDescriptor: descriptor,
                    directoryStatus: directoryStatus,
                    fileName: fileName,
                    displayPath: displayPath
                ) {
                    firstHeld.signal()
                    releaseFirst.wait()
                }
            } catch {
                errors.record(error)
                firstHeld.signal()
            }
        }
        XCTAssertEqual(firstHeld.wait(timeout: .now() + 2), .success)
        try FileManager.default.moveItem(
            at: lockURL,
            to: directory.appendingPathComponent("displaced-missing.lock")
        )

        XCTAssertThrowsError(
            try secondLocks.withLock(
                directoryDescriptor: descriptor,
                directoryStatus: directoryStatus,
                fileName: fileName,
                displayPath: displayPath
            ) {
                XCTFail("Missing authority must not enter a replacement critical section")
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("missing authoritative lock file"))
        }
        releaseFirst.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected holder errors: \(errors.values)")
    }

    func testSameNamedOwnedTailAndLockFromAnotherDirectoryAreRejected() throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let id = BrokerSessionID(rawValue: "same-name-foreign")
        let first = DiskBackedScrollbackStore(directory: firstDirectory, maxRetainedBytes: 1_024)
        let second = DiskBackedScrollbackStore(directory: secondDirectory, maxRetainedBytes: 1_024)
        try first.append(Data("first-directory".utf8), for: id)
        try second.append(Data("second-directory".utf8), for: id)

        let firstTail = firstDirectory.appendingPathComponent("\(id.rawValue).scrollback")
        let secondTail = secondDirectory.appendingPathComponent("\(id.rawValue).scrollback")
        try FileManager.default.removeItem(at: secondTail)
        try FileManager.default.moveItem(at: firstTail, to: secondTail)
        XCTAssertThrowsError(try second.readTail(for: id, maxBytes: 1_024)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(secondTail.path)
            )
        }

        let firstLock = firstTail.appendingPathExtension("lock")
        let secondLock = secondTail.appendingPathExtension("lock")
        try FileManager.default.removeItem(at: secondLock)
        try FileManager.default.moveItem(at: firstLock, to: secondLock)
        XCTAssertThrowsError(try second.storedByteCount(for: id)) { error in
            XCTAssertTrue(String(describing: error).contains("lock file"))
        }
    }

    func testListStoredTailsRejectsSymlinkSwappedAfterPreflightWithoutForeignLock() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-symlink-swap")
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try setupStore.append(Data("persisted-tail".utf8), for: id)
        let tailURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
        let foreignTarget = directory.appendingPathComponent("swap-target.txt")
        try Data("foreign".utf8).write(to: foreignTarget)
        let mutation = OneShotScrollbackLeafMutation { url in
            guard url.lastPathComponent == tailURL.lastPathComponent else { return }
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: foreignTarget)
        }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            listingMetadata: { descriptor in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                mutation.run(tailURL)
                return status
            }
        )

        let tails = try store.listStoredTails()

        XCTAssertTrue(tails.isEmpty)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: tailURL.path),
            foreignTarget.path
        )
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
            XCTAssertTrue(lockError?.message.contains("openat failed") == true)
            XCTAssertTrue(lockError?.message.contains(lockURL.path) == true)
        }
    }

    func testListStoredTailsPropagatesDescriptorCloseFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-close-failure")
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try setupStore.append(Data("persisted-tail".utf8), for: id)
        let closeFailure = OneShotDescriptorCloseFailure()
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            descriptorClose: closeFailure.close
        )

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            guard case .descriptorCloseFailed = error as? DiskBackedScrollbackStore.StoreError else {
                return XCTFail("Expected descriptor close failure, got \(error)")
            }
        }
    }

    func testDirectoryEnumerationReportsOpenAndCleanupFailures() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            beforeDirectoryStreamOpen: { descriptor in
                XCTAssertEqual(Darwin.close(descriptor), 0)
            }
        )

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            guard case .fileOperationAndCloseFailed(let operation, let close) =
                error as? DiskBackedScrollbackStore.StoreError else {
                return XCTFail("Expected combined enumeration cleanup failure, got \(error)")
            }
            XCTAssertTrue(operation.contains("fdopendir"))
            XCTAssertTrue(close.contains("close"))
        }
    }

    func testDirectoryEnumerationReportsReadAndCloseFailures() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryEntryRead: { _ in
                errno = EIO
                return nil
            },
            directoryStreamClose: { stream in
                _ = closedir(stream)
                errno = EBADF
                return -1
            }
        )

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            guard case .fileOperationAndCloseFailed(let operation, let close) =
                error as? DiskBackedScrollbackStore.StoreError else {
                return XCTFail("Expected combined enumeration read/close failure, got \(error)")
            }
            XCTAssertTrue(operation.contains("readdir"))
            XCTAssertTrue(operation.contains("errno \(EIO)"))
            XCTAssertTrue(close.contains("closedir"))
            XCTAssertTrue(close.contains("errno \(EBADF)"))
        }
    }

    func testListStoredTailsRepairsInterruptedOwnedRecoveryInsteadOfOmittingTail() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-interrupted-recovery")
        let initialStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        try initialStore.append(Data("12345678".utf8), for: id)
        let interruptedStore = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 8,
            transactionPhaseHook: { phase in
                if phase == .recoveryIntentDurable { throw ScrollbackTransactionInterruption() }
            }
        )
        XCTAssertThrowsError(try interruptedStore.append(Data("ABC".utf8), for: id))

        let recoveryStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        let tails = try recoveryStore.listStoredTails()

        XCTAssertEqual(tails.map(\.sessionID), [id])
        XCTAssertEqual(tails.map(\.byteCount), [8])
        XCTAssertEqual(try recoveryStore.readTail(for: id, maxBytes: 64), Data("45678ABC".utf8))
    }

    func testListStoredTailsPropagatesUnexpectedDescriptorMetadataFailure() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "list-metadata-failure")
        let initialStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try initialStore.append(Data("tail".utf8), for: id)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 64,
            listingMetadata: { _ in throw ScrollbackListingMetadataFailure() }
        )

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            XCTAssertTrue(error is ScrollbackListingMetadataFailure, "Unexpected error: \(error)")
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

    func testEstablishedV2ReadBypassesHeldGlobalMigrationLock() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "migration-lock-bypass")
        let payload = Data("parallel-read".utf8)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        try store.append(payload, for: id)

        let readyURL = directory.appendingPathComponent("migration-holder-ready")
        let releaseURL = directory.appendingPathComponent("migration-holder-release")
        let child = makeLockHelper(
            lockPath: directory.appendingPathComponent(".holoscape-scrollback-migration.lock").path,
            readyURL: readyURL,
            releaseURL: releaseURL
        )
        try child.run()
        defer {
            try? Data().write(to: releaseURL)
            if child.isRunning { child.terminate() }
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))

        let readDone = DispatchSemaphore(value: 0)
        let result = ScrollbackDataRecorder()
        DispatchQueue.global().async {
            defer { readDone.signal() }
            result.record(Result { try store.readTail(for: id, maxBytes: 1_024) })
        }
        XCTAssertEqual(readDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try result.value?.get(), payload)

        try Data().write(to: releaseURL)
        guard waitForProcessExit(child) else { return }
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testFirstDirectoryComponentCreationSyncsParentAndSurfacesFailure() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("new/scrollback")
        let parentStatus = try metadata(at: parent)
        let syncProbe = ParentDirectorySyncFailure(expectedParent: parentStatus)
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryEntrySync: syncProbe.sync
        )

        XCTAssertThrowsError(
            try store.append(Data("payload".utf8), for: BrokerSessionID(rawValue: "parent-sync"))
        ) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
        XCTAssertTrue(syncProbe.didFailExpectedParent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent("new").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let retry = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryEntrySync: syncProbe.sync
        )
        try retry.append(Data("payload".utf8), for: BrokerSessionID(rawValue: "parent-sync"))
        XCTAssertGreaterThanOrEqual(syncProbe.matchingCallCount, 2)
    }

    func testConcurrentFirstCreationHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOLOSCAPE_SCROLLBACK_FIRST_CREATE_HELPER"] == "1" else {
            throw XCTSkip("Subprocess-only first-creation helper")
        }
        let directory = URL(
            fileURLWithPath: try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_DIRECTORY"]),
            isDirectory: true
        )
        let id = BrokerSessionID(
            rawValue: try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_SESSION_ID"])
        )
        let payload = Data(try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_PAYLOAD"]).utf8)
        let readyURL = URL(fileURLWithPath: try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_READY_PATH"]))
        let startPath = try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_START_PATH"])
        try Data().write(to: readyURL)

        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: startPath), Date() < startDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startPath))
        try DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
            .append(payload, for: id)
    }

    func testConfiguredDirectoryAuthorityHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["HOLOSCAPE_SCROLLBACK_DIRECTORY_AUTHORITY_HELPER"] else {
            throw XCTSkip("Subprocess-only configured-directory authority helper")
        }
        let directory = URL(
            fileURLWithPath: try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_DIRECTORY"]),
            isDirectory: true
        )
        let authorityDirectory = URL(
            fileURLWithPath: try XCTUnwrap(environment["HOLOSCAPE_SCROLLBACK_AUTHORITY_DIRECTORY"]),
            isDirectory: true
        )
        let id = BrokerSessionID(rawValue: "cross-process-directory-authority")
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: authorityDirectory,
            legacyDirectoryHandoff: mode == "read-pre-anchor-v2" ? .trustedDeployedStore : .denied
        )
        switch mode {
        case "seed-directory-authority":
            try store.append(Data("original".utf8), for: id)
        case "reject-replaced-directory":
            XCTAssertThrowsError(try store.append(Data("replacement".utf8), for: id)) { error in
                XCTAssertEqual(
                    error as? DiskBackedScrollbackStore.StoreError,
                    .unsafeScrollbackDirectory(directory.path)
                )
            }
        case "read-pre-anchor-v2":
            XCTAssertEqual(try store.readTail(for: id, maxBytes: 1_024), Data("original".utf8))
            XCTAssertEqual(try store.storedByteCount(for: id), 8)
            XCTAssertEqual(try store.listStoredTails().map(\.sessionID), [id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: authorityDirectory.path))
        default:
            XCTFail("Unknown configured-directory authority helper mode: \(mode)")
        }
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
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        let suffix = "KEPTTAIL" // exactly 8 bytes

        // Simulate a crash between append's FileHandle write and its prune: the
        // persisted file is left larger than the retention cap.
        let oversized = Data(("LEFTOVER-PREFIX-" + suffix).utf8)
        try setupStore.append(oversized, for: id)

        let tail = try store.readTail(for: id, maxBytes: 64)
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), suffix)

        // The read must repair the persisted file back down to the cap.
        XCTAssertEqual(try store.storedByteCount(for: id), 8)
    }

    func testReadTailRepairsHugeSparseFileWithoutReadingItsOversizedPrefix() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "huge-sparse-tail")
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        try setupStore.append(Data(repeating: 0x41, count: 8), for: id)
        let url = directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(ftruncate(descriptor, off_t(4) * 1_024 * 1_024 * 1_024), 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 8), Data(repeating: 0, count: 8))
        XCTAssertEqual(try store.storedByteCount(for: id), 8)
    }

    func testReadTailZeroRetentionOnExistingPersistedFileReturnsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-zero-retention")

        // An owned tail left behind by a positive-retention store.
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try setupStore.append(Data("persisted-tail\n".utf8), for: id)

        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 0)
        XCTAssertEqual(try store.readTail(for: id, maxBytes: 64), Data())
    }

    func testReadTailNegativeRetentionOnExistingPersistedFileReturnsEmpty() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-scrollback-negative-retention")

        // An owned tail left behind by a positive-retention store.
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 64)
        try setupStore.append(Data("persisted-tail\n".utf8), for: id)

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
        let directory = canonicalTemporaryDirectory()
            .appendingPathComponent("DiskBackedScrollbackStoreTests")
            .appendingPathComponent(UUID().uuidString)
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)

        XCTAssertEqual(try store.listStoredTails(), [])
    }

    func testMissingDirectoryTraversalReportsCloseFailureWithoutClosingDescriptorTwice() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("missing").appendingPathComponent("scrollback")
        let parentStatus = try metadata(at: parent)
        let closeFailure = TargetDescriptorCloseFailure(target: parentStatus)
        let store = DiskBackedScrollbackStore(
            directory: missing,
            maxRetainedBytes: 1_024,
            descriptorClose: closeFailure.close
        )

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            guard case .descriptorCloseFailed = error as? DiskBackedScrollbackStore.StoreError else {
                return XCTFail("Expected the original typed close failure, got \(error)")
            }
        }
        XCTAssertEqual(closeFailure.targetCloseCallCount, 1)
    }

    func testListStoredTailsThrowsWhenDirectoryIsRegularFile() throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let regularFile = parent.appendingPathComponent("not-a-directory")
        FileManager.default.createFile(atPath: regularFile.path, contents: Data("x".utf8))

        let store = DiskBackedScrollbackStore(directory: regularFile, maxRetainedBytes: 1024)

        XCTAssertThrowsError(try store.listStoredTails()) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackDirectory(regularFile.path)
            )
        }
    }

    func testAppendRejectsMissingPreviouslyOwnedMainWithoutRecreatingIt() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let id = BrokerSessionID(rawValue: "deleted-owned-main")
        let tailURL = directory.appendingPathComponent("deleted-owned-main.scrollback")

        try store.append(Data("durable".utf8), for: id)
        try FileManager.default.removeItem(at: tailURL)

        XCTAssertThrowsError(try store.append(Data("replacement".utf8), for: id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                .unsafeScrollbackFile(tailURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path))
    }

    func testClearReturnsExactByteCountFromSameLockedMutation() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        let id = BrokerSessionID(rawValue: "clear-byte-count")
        try store.append(Data("exact-count".utf8), for: id)

        XCTAssertEqual(try store.clearAndReturnByteCount(for: id), 11)
        XCTAssertEqual(try store.storedByteCount(for: id), 0)
        XCTAssertEqual(try store.clearAndReturnByteCount(for: id), 0)
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
        let setupStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1024)
        let surviving = BrokerSessionID(rawValue: "session-survives")
        let vanishing = BrokerSessionID(rawValue: "session-vanishing")

        try setupStore.append(Data("good-tail\n".utf8), for: surviving)
        try setupStore.append(Data("bad-tail\n".utf8), for: vanishing)

        // Simulate the per-entry race where a tail is deleted after descriptor
        // metadata is read. Descriptor identity determines exactly which entry
        // vanishes without returning to pathname metadata.
        let vanishingURL = directory.appendingPathComponent("session-vanishing.scrollback")
        var vanishingStatus = stat()
        XCTAssertEqual(lstat(vanishingURL.path, &vanishingStatus), 0)
        let vanishingDevice = vanishingStatus.st_dev
        let vanishingInode = vanishingStatus.st_ino
        let store = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1024,
            listingMetadata: { descriptor in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if status.st_dev == vanishingDevice,
                   status.st_ino == vanishingInode {
                    try FileManager.default.removeItem(at: vanishingURL)
                }
                return status
            }
        )
        let tails = try store.listStoredTails()

        XCTAssertEqual(tails.map(\.sessionID), [surviving])
        XCTAssertEqual(tails.count, 1)
    }

    private func assertPostRenameReplacementFailsClosed(
        phase: DiskBackedScrollbackStore.TransactionPhase,
        id: BrokerSessionID,
        publishedURL: (URL, BrokerSessionID) -> URL,
        operation: (DiskBackedScrollbackStore, BrokerSessionID) throws -> Void,
        expectedError: (URL, URL) -> DiskBackedScrollbackStore.StoreError
    ) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let interrupted = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            transactionPhaseHook: { observed in
                if observed == phase { throw ScrollbackTransactionInterruption() }
            }
        )
        XCTAssertThrowsError(try operation(interrupted, id))
        let url = publishedURL(directory, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try replacePublishedFileWithMarkerClone(at: url)

        let recovered = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 1_024)
        XCTAssertThrowsError(try operation(recovered, id)) { error in
            XCTAssertEqual(
                error as? DiskBackedScrollbackStore.StoreError,
                expectedError(directory, url)
            )
        }
    }

    private func replacePublishedFileWithMarkerClone(at url: URL) throws {
        let contents = try Data(contentsOf: url)
        let owner = try extendedAttribute(at: url, name: "com.holoscape.scrollback.owner")
        let displaced = url.deletingLastPathComponent()
            .appendingPathComponent("displaced-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: displaced)
        try contents.write(to: url)
        try setExtendedAttribute(
            at: url,
            name: "com.holoscape.scrollback.owner",
            value: owner
        )
    }

    private func seedPreAnchorV2Store(
        directory: URL,
        authorityDirectory: URL,
        id: BrokerSessionID,
        payload: Data
    ) throws {
        try DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 1_024,
            directoryIdentityAuthorityDirectory: authorityDirectory
        ).append(payload, for: id)
        try FileManager.default.removeItem(at: authorityDirectory)

        let directoryStatus = try metadata(at: directory)
        let tailURL = directory.appendingPathComponent("\(id.rawValue).scrollback")
        let lockURL = tailURL.appendingPathExtension("lock")
        let formatURL = directory.appendingPathComponent(".holoscape-scrollback-format-v2")
        let oldMainOwner = Data(
            "holoscape-scrollback-main-v2:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(tailURL.lastPathComponent)".utf8
        )
        let oldFormatOwner = Data(
            "holoscape-scrollback-format-v2-staging:\(directoryStatus.st_dev):\(directoryStatus.st_ino)".utf8
        )
        let oldLockOwner = Data(
            "holoscape-scrollback-lock-v3:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(lockURL.lastPathComponent):legacy-nonce".utf8
        )
        try setExtendedAttribute(at: tailURL, name: "com.holoscape.scrollback.owner", value: oldMainOwner)
        try setExtendedAttribute(at: formatURL, name: "com.holoscape.scrollback.owner", value: oldFormatOwner)
        try setExtendedAttribute(at: lockURL, name: "com.holoscape.scrollback.lock-owner", value: oldLockOwner)
        try removeExtendedAttributes(at: directory, prefixes: [
            "com.holoscape.scrollback.main-",
            "com.holoscape.scrollback.format-owner",
        ])
        let lockDigest = SHA256.hash(data: Data(lockURL.lastPathComponent.utf8))
            .map { String(format: "%02x", $0) }.joined()
        try setExtendedAttribute(
            at: directory,
            name: "com.holoscape.scrollback.lock-\(lockDigest)",
            value: oldLockOwner
        )
    }

    private func setPersistentFileIdentity(
        authorityDirectory: URL,
        configuredDirectory: URL,
        fileURL: URL
    ) throws {
        let configuredPath = configuredDirectory.standardizedFileURL.path
        let name = fileURL.lastPathComponent
        let status = try metadata(at: fileURL)
        let digest = SHA256.hash(data: Data("\(configuredPath)\n\(name)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        try setExtendedAttribute(
            at: authorityDirectory,
            name: "com.holoscape.scrollback.file-\(digest)",
            value: Data(
                "holoscape-scrollback-file-v1:\(status.st_dev):\(status.st_ino):\(name)".utf8
            )
        )
    }

    private func setExtendedAttribute(at url: URL, name: String, value: Data) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let result = value.withUnsafeBytes { bytes in
            fsetxattr(descriptor, name, bytes.baseAddress, value.count, 0, 0)
        }
        XCTAssertEqual(result, 0)
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func extendedAttribute(at url: URL, name: String) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        XCTAssertGreaterThanOrEqual(size, 0)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { bytes in
            fgetxattr(descriptor, name, bytes.baseAddress, size, 0, 0)
        }
        XCTAssertEqual(count, size)
        guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }

    private func extendedAttributeNames(at url: URL) throws -> [String] {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let size = flistxattr(descriptor, nil, 0, 0)
        XCTAssertGreaterThanOrEqual(size, 0)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard size > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: size)
        let count = flistxattr(descriptor, &bytes, bytes.count, 0)
        XCTAssertEqual(count, size)
        guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var names: [String] = []
        var offset = 0
        while offset < bytes.count {
            let name = bytes.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            names.append(name)
            offset += name.utf8.count + 1
        }
        return names.sorted()
    }

    private func removeExtendedAttributes(at url: URL, prefixes: [String]) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let size = flistxattr(descriptor, nil, 0, 0)
        XCTAssertGreaterThanOrEqual(size, 0)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var names = [CChar](repeating: 0, count: size)
        let count = flistxattr(descriptor, &names, names.count, 0)
        XCTAssertEqual(count, size)
        guard count == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var offset = 0
        while offset < names.count {
            let name = names.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            guard prefixes.contains(where: name.hasPrefix) else { continue }
            XCTAssertEqual(fremovexattr(descriptor, name, 0), 0)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let directory = canonicalTemporaryDirectory()
            .appendingPathComponent("DiskBackedScrollbackStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStoreHelper(mode: String, directory: URL, authorityDirectory: URL) -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "HoloscapeTests.DiskBackedScrollbackStoreTests/testConfiguredDirectoryAuthorityHelper",
            Bundle(for: Self.self).bundleURL.path
        ]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "HOLOSCAPE_SCROLLBACK_DIRECTORY_AUTHORITY_HELPER": mode,
            "HOLOSCAPE_SCROLLBACK_DIRECTORY": directory.path,
            "HOLOSCAPE_SCROLLBACK_AUTHORITY_DIRECTORY": authorityDirectory.path
        ]) { _, helperValue in helperValue }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    @discardableResult
    private func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning else { return true }

        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        XCTFail("Subprocess did not exit within \(timeout) seconds", file: file, line: line)
        return !process.isRunning
    }

    private func makeLockHelper(lockPath: String, readyURL: URL, releaseURL: URL) -> Process {
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
        return child
    }

    private func metadata(at url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func assertOperationUsesPinnedDirectory(
        _ operation: (
            DiskBackedScrollbackStore,
            BrokerSessionID,
            URL,
            URL
        ) throws -> Void
    ) throws {
        let parent = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let configured = parent.appendingPathComponent("configured")
        let displaced = parent.appendingPathComponent("displaced")
        let foreign = parent.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let id = BrokerSessionID(rawValue: "directory-operation")
        try DiskBackedScrollbackStore(directory: configured, maxRetainedBytes: 64)
            .append(Data("pinned".utf8), for: id)
        let mutation = OneShotScrollbackLeafMutation { _ in
            try FileManager.default.moveItem(at: configured, to: displaced)
            try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: foreign)
        }
        let store = DiskBackedScrollbackStore(
            directory: configured,
            maxRetainedBytes: 64,
            afterDirectoryOpen: mutation.run
        )

        try operation(store, id, displaced, foreign)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), [])
    }

    private func canonicalTemporaryDirectory() -> URL {
        let path = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(path, nil) else {
            return FileManager.default.temporaryDirectory
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func assertRecovery(after phase: DiskBackedScrollbackStore.TransactionPhase) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "transaction-\(phase)")
        let initialStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        try initialStore.append(Data("12345678".utf8), for: id)
        let interruptedStore = DiskBackedScrollbackStore(
            directory: directory,
            maxRetainedBytes: 8,
            transactionPhaseHook: { observedPhase in
                if observedPhase == phase { throw ScrollbackTransactionInterruption() }
            }
        )

        XCTAssertThrowsError(try interruptedStore.append(Data("ABC".utf8), for: id))

        let recoveryStore = DiskBackedScrollbackStore(directory: directory, maxRetainedBytes: 8)
        XCTAssertEqual(
            try recoveryStore.readTail(for: id, maxBytes: 64),
            Data("45678ABC".utf8)
        )
        XCTAssertEqual(try recoveryStore.storedByteCount(for: id), 8)
        let recoveryURL = directory
            .appendingPathComponent(id.rawValue)
            .appendingPathExtension("scrollback")
            .appendingPathExtension("recovery")
        let recoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        XCTAssertEqual(recoveryAttributes[.size] as? Int, 0)
    }
}

private struct ScrollbackTransactionInterruption: Error {}
private struct ScrollbackListingMetadataFailure: Error {}

private final class OneShotDescriptorSyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private var calls = 0
    private let beforeFailure: () throws -> Void

    init(beforeFailure: @escaping () throws -> Void = {}) {
        self.beforeFailure = beforeFailure
    }

    var callCount: Int { lock.withLock { calls } }

    func sync(_ descriptor: Int32) -> Int32 {
        let fail = lock.withLock {
            calls += 1
            defer { shouldFail = false }
            return shouldFail
        }
        guard fail else { return Darwin.fsync(descriptor) }
        do {
            try beforeFailure()
        } catch {
            XCTFail("Descriptor sync mutation failed: \(error)")
        }
        errno = EIO
        return -1
    }
}

private final class OneShotDescriptorSyncMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldMutate = true
    private let mutation: () throws -> Void

    init(mutation: @escaping () throws -> Void) {
        self.mutation = mutation
    }

    func sync(_ descriptor: Int32) -> Int32 {
        let mutate = lock.withLock {
            defer { shouldMutate = false }
            return shouldMutate
        }
        if mutate {
            do {
                try mutation()
            } catch {
                XCTFail("Descriptor sync mutation failed: \(error)")
                errno = EIO
                return -1
            }
        }
        return Darwin.fsync(descriptor)
    }
}

private final class OneShotDescriptorCloseFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func close(_ descriptor: Int32) -> Int32 {
        let fail = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        let result = Darwin.close(descriptor)
        guard fail, result == 0 else { return result }
        errno = EIO
        return -1
    }
}

private final class TargetDescriptorCloseFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let targetDevice: dev_t
    private let targetInode: ino_t
    private var targetDescriptor: Int32?
    private var targetCalls = 0

    init(target: stat) {
        targetDevice = target.st_dev
        targetInode = target.st_ino
    }

    var targetCloseCallCount: Int {
        lock.withLock { targetCalls }
    }

    func close(_ descriptor: Int32) -> Int32 {
        let targetCall = lock.withLock { () -> Int? in
            if targetDescriptor == descriptor {
                targetCalls += 1
                return targetCalls
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_dev == targetDevice,
                  status.st_ino == targetInode else { return nil }
            targetDescriptor = descriptor
            targetCalls += 1
            return targetCalls
        }
        guard let targetCall else { return Darwin.close(descriptor) }
        let result = Darwin.close(descriptor)
        guard targetCall == 1, result == 0 else { return result }
        errno = EIO
        return -1
    }
}

private final class OneShotScrollbackLeafMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false
    private let action: (URL) throws -> Void

    init(action: @escaping (URL) throws -> Void) {
        self.action = action
    }

    func run(_ url: URL) {
        let shouldRun = lock.withLock {
            guard !hasRun else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }
        do {
            try action(url)
        } catch {
            XCTFail("Leaf mutation failed: \(error)")
        }
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

private final class ScrollbackDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Data, Error>?

    var value: Result<Data, Error>? {
        lock.withLock { storage }
    }

    func record(_ result: Result<Data, Error>) {
        lock.withLock {
            storage = result
        }
    }
}

private final class ParentDirectorySyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedDevice: dev_t
    private let expectedInode: ino_t
    private var failedExpectedParent = false
    private var expectedParentCalls = 0

    init(expectedParent: stat) {
        expectedDevice = expectedParent.st_dev
        expectedInode = expectedParent.st_ino
    }

    var didFailExpectedParent: Bool {
        lock.withLock { failedExpectedParent }
    }

    var matchingCallCount: Int {
        lock.withLock { expectedParentCalls }
    }

    func sync(_ descriptor: Int32) -> Int32 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return -1 }
        let shouldFail = lock.withLock {
            guard status.st_dev == expectedDevice,
                  status.st_ino == expectedInode else { return false }
            expectedParentCalls += 1
            guard !failedExpectedParent else { return false }
            failedExpectedParent = true
            return true
        }
        guard shouldFail else { return Darwin.fsync(descriptor) }
        errno = EIO
        return -1
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
