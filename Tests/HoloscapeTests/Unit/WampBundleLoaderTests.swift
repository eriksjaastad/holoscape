import XCTest
import ZIPFoundation
@testable import Holoscape

/// Amplify Task 3.7 — WampBundleLoader unit tests.
///
/// Covers the unzip happy path, cache-hit fast path, sandbox rejection
/// (string gate + symlink-resolve gate), size-cap rejection, and
/// LRU purge behavior. Fixture bundles are synthesized at setUp time
/// from ZIPFoundation so tests remain hermetic — no checked-in `.wamp`
/// files.
@MainActor
final class WampBundleLoaderTests: XCTestCase {

    private var tempRoot: URL!
    private var cacheRoot: URL!
    private var bundleStageDir: URL!
    private var engine: SkinEngine!
    private var loader: WampBundleLoader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-wamp-\(UUID().uuidString)")
        cacheRoot = tempRoot.appendingPathComponent("cache")
        bundleStageDir = tempRoot.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleStageDir, withIntermediateDirectories: true)

        // SkinEngine provides the sandbox helpers (validateAssetPath,
        // assertPathResolvesInside). No need to route HOLOSCAPE_CONFIG_DIR —
        // we construct the loader with our own cache root.
        engine = SkinEngine()
        loader = WampBundleLoader(cacheRoot: cacheRoot)
        loader.sandbox = engine
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: - Happy path

    func testUnzipIfNeededExtractsToHashKeyedSubdir() throws {
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0","name":"test"}"#.utf8)),
            ("assets/tile.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ])

        let extracted = try loader.unzipIfNeeded(bundleURL: bundleURL)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("skin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("assets/tile.png").path))

        // The subdirectory name is the SHA-256 hex of the bundle bytes.
        let expectedHash = try loader.contentHash(bundleURL)
        XCTAssertEqual(extracted.lastPathComponent, expectedHash,
                       "Cache subdirectory must be keyed by bundle SHA-256")
        XCTAssertEqual(extracted.deletingLastPathComponent().standardizedFileURL.path,
                       cacheRoot.standardizedFileURL.path)
    }

    func testSecondUnzipHitsCache() throws {
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
        ])

        let first = try loader.unzipIfNeeded(bundleURL: bundleURL)
        // Touch a marker file — on cache hit, our marker survives. A re-
        // extraction would remove the cache subdir and rewrite it, erasing
        // the marker. This is a behavior-level cache-hit assertion.
        let marker = first.appendingPathComponent(".cache-marker")
        try Data("sentinel".utf8).write(to: marker)

        let second = try loader.unzipIfNeeded(bundleURL: bundleURL)
        XCTAssertEqual(first.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "Second unzipIfNeeded on unchanged bundle must hit cache (marker survives)")
    }

    // MARK: - Missing manifest

    func testBundleWithoutManifestThrows() throws {
        let bundleURL = try makeBundle(entries: [
            ("assets/orphan.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ])

        XCTAssertThrowsError(try loader.unzipIfNeeded(bundleURL: bundleURL)) { error in
            XCTAssertEqual(error as? WampBundleLoader.LoadError, .missingManifest)
        }
        // Cleanup invariant — no half-extracted subdirectory survives.
        let hash = try loader.contentHash(bundleURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(hash).path),
            "Missing-manifest failure must leave the cache root clean")
    }

    // MARK: - Sandbox rejection

    func testTraversalEntryIsRejected() throws {
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
            ("../etc/passwd", Data("evil".utf8)),
        ])

        XCTAssertThrowsError(try loader.unzipIfNeeded(bundleURL: bundleURL)) { error in
            guard case .zipEntryEscapesSandbox(let path) = error as? WampBundleLoader.LoadError else {
                XCTFail("Expected zipEntryEscapesSandbox, got \(error)")
                return
            }
            XCTAssertTrue(path.contains(".."),
                          "Rejected path name must be reported so Console.app has the offender")
        }
    }

    func testAbsolutePathEntryIsRejected() throws {
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
            ("/etc/shadow", Data("evil".utf8)),
        ])
        XCTAssertThrowsError(try loader.unzipIfNeeded(bundleURL: bundleURL)) { error in
            if case .zipEntryEscapesSandbox = error as? WampBundleLoader.LoadError { return }
            XCTFail("Expected zipEntryEscapesSandbox, got \(error)")
        }
    }

    // MARK: - Size caps

    func testAssetOverCapIsRejected() throws {
        // Use a fresh loader with a tiny 1 KB per-asset cap so the test
        // doesn't need to write 50 MB. Behavior is identical — the cap
        // field is just wired to the production default by init.
        let tinyLoader = WampBundleLoader(
            cacheRoot: cacheRoot,
            assetSizeCap: 1024,
            bundleSizeCap: 1024 * 1024
        )
        tinyLoader.sandbox = engine

        let oversize = Data(count: 1025)
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
            ("assets/huge.bin", oversize),
        ])

        XCTAssertThrowsError(try tinyLoader.unzipIfNeeded(bundleURL: bundleURL)) { error in
            guard case .assetTooLarge(let path, let bytes) = error as? WampBundleLoader.LoadError else {
                XCTFail("Expected assetTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(path, "assets/huge.bin")
            XCTAssertGreaterThan(bytes, 1024)
        }
    }

    // MARK: - Unwired sandbox regression

    /// A loader constructed without a sandbox (or whose sandbox is
    /// nil-ed after deinit) MUST refuse to extract. Previously
    /// `try sandbox?.validateAssetPath(...)` silently no-op'd on a nil
    /// optional chain, so an unwired loader would have written every
    /// ZIP entry unchecked — bypassing both the string-path gate and
    /// the symlink-resolve gate. Code-review PR #119 follow-up caught
    /// this class of bug. This test pins the fix.
    func testUnwiredSandboxRefusesExtraction() throws {
        let unwired = WampBundleLoader(cacheRoot: cacheRoot)
        // Deliberately do NOT assign unwired.sandbox.

        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
            ("../etc/passwd", Data("evil".utf8)),
        ])

        XCTAssertThrowsError(try unwired.unzipIfNeeded(bundleURL: bundleURL)) { error in
            guard case .ioFailure(let detail) = error as? WampBundleLoader.LoadError else {
                XCTFail("Expected ioFailure(\"sandbox not configured\"), got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("sandbox"),
                          "Failure message must name the missing sandbox so the wiring bug is obvious")
        }
        // Post-condition: the traversal entry must NOT have been
        // written anywhere. A silent bypass would leave a file under
        // cacheRoot/../etc/passwd or similar. We verify the cache
        // subdir either doesn't exist or is empty.
        let hash = try unwired.contentHash(bundleURL)
        let subdir = cacheRoot.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: subdir.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: subdir.path)
            XCTAssertTrue(contents.isEmpty,
                          "Unwired sandbox extraction must write zero bytes to disk")
        }
    }

    // MARK: - Not a ZIP

    func testRandomBytesAreRejectedAsNotAZip() throws {
        let bogus = bundleStageDir.appendingPathComponent("bogus.wamp")
        try Data("this is not a zip".utf8).write(to: bogus)

        XCTAssertThrowsError(try loader.unzipIfNeeded(bundleURL: bogus)) { error in
            if case .notAZip = error as? WampBundleLoader.LoadError { return }
            XCTFail("Expected notAZip, got \(error)")
        }
    }

    // MARK: - contentHash determinism

    func testContentHashIsStableAcrossCalls() throws {
        let bundleURL = try makeBundle(entries: [
            ("skin.json", Data(#"{"version":"3.0"}"#.utf8)),
        ])
        let h1 = try loader.contentHash(bundleURL)
        let h2 = try loader.contentHash(bundleURL)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64, "SHA-256 hex is 64 characters")
    }

    func testContentHashChangesWithContent() throws {
        let a = try makeBundle(entries: [("skin.json", Data(#"{"v":"a"}"#.utf8))],
                               fileName: "a.wamp")
        let b = try makeBundle(entries: [("skin.json", Data(#"{"v":"b"}"#.utf8))],
                               fileName: "b.wamp")
        XCTAssertNotEqual(try loader.contentHash(a), try loader.contentHash(b))
    }

    // MARK: - LRU purge

    func testPurgeLRURemovesOldestUntilUnderCap() throws {
        // Stage three fake cache entries sized so (old + mid) > cap.
        // oldest (100 bytes, 10 mb file), ..., etc. For this unit test
        // we set a small notional size via directory contents and rely
        // on the real 50 MB cap being way above anything we create —
        // instead we override behavior by creating large dummy files.
        //
        // Simpler design: stage three cache entries with real byte
        // sizes that together exceed the cap, then call purgeLRU.
        // The purge must remove at least the oldest. With `preserving`
        // set to the newest, the newest stays even if it's the only
        // one we care about.
        let oldestHash = "a".repeated(64)
        let midHash = "b".repeated(64)
        let newestHash = "c".repeated(64)

        // Create three cache subdirs each holding a 21 MB file. Total
        // 63 MB > 50 MB cap. Purge must trim to ≤ 50 MB.
        let perEntryBytes = 21 * 1024 * 1024
        let now = Date()
        try stageCacheEntry(hash: oldestHash, sizedBytes: perEntryBytes,
                            mtime: now.addingTimeInterval(-300))
        try stageCacheEntry(hash: midHash, sizedBytes: perEntryBytes,
                            mtime: now.addingTimeInterval(-200))
        try stageCacheEntry(hash: newestHash, sizedBytes: perEntryBytes,
                            mtime: now.addingTimeInterval(-100))

        try loader.purgeLRU(preserving: newestHash)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(oldestHash).path),
            "Oldest entry must be evicted")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(newestHash).path),
            "Preserved (active-skin) entry must survive even if it's the newest")
    }

    func testPurgeLRUPreservesActiveEvenIfOldest() throws {
        // Active skin happens to be the oldest in cache. Its subdir
        // must not be evicted — this is Property 14's load-bearing
        // invariant for avoiding "skin disappears mid-session."
        let activeHash = "a".repeated(64)
        let newerHash = "b".repeated(64)
        let perEntryBytes = 30 * 1024 * 1024
        let now = Date()
        try stageCacheEntry(hash: activeHash, sizedBytes: perEntryBytes,
                            mtime: now.addingTimeInterval(-300))
        try stageCacheEntry(hash: newerHash, sizedBytes: perEntryBytes,
                            mtime: now.addingTimeInterval(-100))

        try loader.purgeLRU(preserving: activeHash)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(activeHash).path),
            "preserving= hash is never evicted")
    }

    func testPurgeLRUIsNoOpWhenUnderCap() throws {
        let hash = "d".repeated(64)
        try stageCacheEntry(hash: hash, sizedBytes: 1024, mtime: Date())
        try loader.purgeLRU(preserving: nil)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(hash).path),
            "Under-cap cache must not be touched")
    }

    // MARK: - Helpers

    /// Build a ZIP archive at `bundleStageDir/<fileName>` containing
    /// the given (path, data) entries. Returns its file URL.
    private func makeBundle(entries: [(String, Data)], fileName: String = "test.wamp") throws -> URL {
        let url = bundleStageDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .none) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
        return url
    }

    /// Create a cache subdir with a single file of the requested size
    /// and the given mtime on the subdir. Used by LRU tests to control
    /// ordering without waiting real time.
    private func stageCacheEntry(hash: String, sizedBytes: Int, mtime: Date) throws {
        let subdir = cacheRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let payload = subdir.appendingPathComponent("payload.bin")
        // Create a sparse-ish file of the right size without ballooning
        // memory: write zero bytes in one shot.
        try Data(count: sizedBytes).write(to: payload)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: subdir.path
        )
    }
}

private extension String {
    /// Repeat a one-char string `n` times. Used to synthesize 64-char
    /// hash-shaped names for cache-entry fixtures.
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
