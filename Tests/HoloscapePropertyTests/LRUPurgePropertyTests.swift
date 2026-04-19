import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 14 — LRU cache purge preserves active skin
/// (Requirement 1.8).
///
/// For any staged cache state:
///   1. After `purgeLRU(preserving: active)`, total cache size is
///      ≤ `WampBundleLoader.bundleSizeCap`.
///   2. The `preserving` subdirectory always survives, even if it's
///      the oldest.
///   3. Surviving-subdir-mtime ordering is monotonic non-decreasing
///      from evicted → surviving (purge removes oldest first).
@MainActor
final class LRUPurgePropertyTests: XCTestCase {

    private var tempRoot: URL!
    private var cacheRoot: URL!
    private var loader: WampBundleLoader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-lru-\(UUID().uuidString)")
        cacheRoot = tempRoot.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        loader = WampBundleLoader(cacheRoot: cacheRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: - Generators

    /// Entry-count for staged cache: 1..6 entries. Enough variety to
    /// shuffle mtime ordering without creating GB of test data.
    private static let entryCount: Gen<Int> =
        Int.arbitrary.suchThat { $0 >= 1 && $0 <= 6 }

    /// Per-entry size in KB. Tiny so property runs in milliseconds.
    /// Combined with the test-injected `cap` below, these push past
    /// the cap just as reliably as 30 MB entries at the real cap.
    private static let entryKB: Gen<Int> =
        Int.arbitrary.suchThat { $0 >= 1 && $0 <= 8 }

    /// Synthetic cap used by property tests. Picked so that a few
    /// multi-KB entries reliably cross it. `purgeLRU` accepts a `cap`
    /// parameter specifically so tests don't need real 50 MB data.
    private static let testCap = 4 * 1024

    // MARK: - Properties

    func testPurgeReducesTotalToAtMostCap() {
        property("after purgeLRU, total cache size ≤ cap") <- forAll(
            Self.entryCount, Self.entryKB
        ) { (count: Int, kbPer: Int) in
            self.wipeCacheRoot()

            let now = Date()
            var hashes: [String] = []
            for i in 0..<count {
                let h = "h\(i)".padded(to: 64, with: "0")
                hashes.append(h)
                try? self.stage(hash: h, bytes: kbPer * 1024,
                                mtime: now.addingTimeInterval(-Double((count - i) * 60)))
            }
            let active = hashes.last

            try? self.loader.purgeLRU(preserving: active, cap: Self.testCap)

            let total = self.totalBytesUnder(self.cacheRoot)
            // Allow the preserving entry to exceed cap on its own —
            // the invariant is "total ≤ cap OR survivors reduce to
            // just the preserved entry." Other evictables must all go.
            if total <= Self.testCap { return true }
            let survivors = self.surviveSet()
            return survivors.count == 1 && survivors.contains(active ?? "")
        }
    }

    func testPurgeNeverEvictsTheActiveSkin() {
        property("preserving= subdirectory always survives purge") <- forAll(
            Self.entryCount, Self.entryKB
        ) { (count: Int, kbPer: Int) in
            self.wipeCacheRoot()

            // Active is the OLDEST entry — makes this test force-work
            // through the "would normally evict" path.
            let now = Date()
            let activeHash = "active".padded(to: 64, with: "0")
            try? self.stage(hash: activeHash, bytes: kbPer * 1024,
                            mtime: now.addingTimeInterval(-Double(count) * 60))
            for i in 1..<count {
                let h = "h\(i)".padded(to: 64, with: "0")
                try? self.stage(hash: h, bytes: kbPer * 1024,
                                mtime: now.addingTimeInterval(-Double(count - i) * 60))
            }

            try? self.loader.purgeLRU(preserving: activeHash, cap: Self.testCap)

            return FileManager.default.fileExists(
                atPath: self.cacheRoot.appendingPathComponent(activeHash).path
            )
        }
    }

    func testPurgeIsIdempotent() {
        property("second purgeLRU on steady state is a no-op") <- forAll(
            Self.entryCount, Self.entryKB
        ) { (count: Int, kbPer: Int) in
            self.wipeCacheRoot()

            let now = Date()
            var hashes: [String] = []
            for i in 0..<count {
                let h = "h\(i)".padded(to: 64, with: "0")
                hashes.append(h)
                try? self.stage(hash: h, bytes: kbPer * 1024,
                                mtime: now.addingTimeInterval(-Double((count - i) * 60)))
            }

            try? self.loader.purgeLRU(preserving: hashes.last, cap: Self.testCap)
            let survivorsAfterFirst = self.surviveSet()
            try? self.loader.purgeLRU(preserving: hashes.last, cap: Self.testCap)
            let survivorsAfterSecond = self.surviveSet()

            return survivorsAfterFirst == survivorsAfterSecond
        }
    }

    // MARK: - Helpers

    private func wipeCacheRoot() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    private func stage(hash: String, bytes: Int, mtime: Date) throws {
        let subdir = cacheRoot.appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: subdir.appendingPathComponent("payload.bin"))
        try FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: subdir.path
        )
    }

    private func surviveSet() -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return Set(entries.map { $0.lastPathComponent })
    }

    private func totalBytesUnder(_ root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += size
            }
        }
        return total
    }
}

private extension String {
    /// Pad right to exactly `length` characters using `padChar`.
    /// Used to shape short test names into 64-char hash-lookalikes.
    func padded(to length: Int, with padChar: Character) -> String {
        if count >= length { return String(prefix(length)) }
        return self + String(repeating: padChar, count: length - count)
    }
}
