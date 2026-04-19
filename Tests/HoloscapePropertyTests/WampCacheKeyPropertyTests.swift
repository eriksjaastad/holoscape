import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 9 — SHA-256 cache key determinism (Requirements
/// 1.2, 10.3, 10.4).
///
/// For any bundle bytes: `contentHash(_:)` returns the same hex string
/// on every call; identical bytes produce identical hashes; different
/// bytes produce different hashes (with probability > 1 − 2⁻²⁵⁶).
@MainActor
final class WampCacheKeyPropertyTests: XCTestCase {

    private var tempRoot: URL!
    private var cacheRoot: URL!
    private var loader: WampBundleLoader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-hash-\(UUID().uuidString)")
        cacheRoot = tempRoot.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("bundles"),
                                                 withIntermediateDirectories: true)
        loader = WampBundleLoader(cacheRoot: cacheRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: - Generators

    /// A byte sequence of length 0..512 so SwiftCheck shrinking produces
    /// readable counterexamples. Real bundles are much larger; the
    /// hash invariant is independent of size.
    private static let byteCount: Gen<Int> =
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 512 }

    // MARK: - Properties

    func testHashIsStableAcrossCalls() {
        property("same bytes → same hash across repeated calls") <- forAll(
            Self.byteCount
        ) { (count: Int) in
            let url = self.writeBundle(bytes: self.pseudoBytes(seed: 1, count: count))
            guard let h1 = try? self.loader.contentHash(url),
                  let h2 = try? self.loader.contentHash(url),
                  let h3 = try? self.loader.contentHash(url) else {
                return false
            }
            return h1 == h2 && h2 == h3
        }
    }

    func testHashIs64HexChars() {
        property("every hash is 64 lowercase hex characters") <- forAll(
            Self.byteCount
        ) { (count: Int) in
            let url = self.writeBundle(bytes: self.pseudoBytes(seed: 2, count: count))
            guard let hash = try? self.loader.contentHash(url) else { return false }
            if hash.count != 64 { return false }
            return hash.allSatisfy { "0123456789abcdef".contains($0) }
        }
    }

    func testDistinctBytesProduceDistinctHashes() {
        // Generate two different seeds and assert their hashes differ.
        // `seed` is used as the start byte so identical counts with
        // different seeds still produce different content.
        property("bytes that differ in at least one position hash to different values") <- forAll(
            Self.byteCount,
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 255 },
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 255 }
        ) { (count: Int, seedA: Int, seedB: Int) in
            guard count > 0, seedA != seedB else { return true }  // vacuous

            let a = self.pseudoBytes(seed: UInt8(seedA), count: count)
            let b = self.pseudoBytes(seed: UInt8(seedB), count: count)
            guard a != b else { return true }  // seeds yielded identical bytes (unlikely at count>0)

            let urlA = self.writeBundle(bytes: a)
            let urlB = self.writeBundle(bytes: b)
            guard let hA = try? self.loader.contentHash(urlA),
                  let hB = try? self.loader.contentHash(urlB) else {
                return false
            }
            return hA != hB
        }
    }

    func testCopyingBundlePreservesHash() {
        // Copying the same byte content to a different file path must
        // produce the same hash. Path must not influence the cache key.
        property("identical contents at different paths have identical hashes") <- forAll(
            Self.byteCount
        ) { (count: Int) in
            let bytes = self.pseudoBytes(seed: 3, count: count)
            let urlA = self.writeBundle(bytes: bytes, fileName: "a.wamp")
            let urlB = self.writeBundle(bytes: bytes, fileName: "b.wamp")
            guard let hA = try? self.loader.contentHash(urlA),
                  let hB = try? self.loader.contentHash(urlB) else {
                return false
            }
            return hA == hB
        }
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random bytes so property shrinks are reproducible.
    /// Uses `(seed + i * 17) mod 256` — not cryptographic, just varied.
    private func pseudoBytes(seed: Int, count: Int) -> Data {
        pseudoBytes(seed: UInt8(truncatingIfNeeded: seed), count: count)
    }

    private func pseudoBytes(seed: UInt8, count: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for i in 0..<count {
            bytes.append(UInt8((Int(seed) + i &* 17) & 0xFF))
        }
        return Data(bytes)
    }

    private func writeBundle(bytes: Data, fileName: String = "bundle.wamp") -> URL {
        let url = tempRoot.appendingPathComponent("bundles/\(UUID().uuidString)-\(fileName)")
        try? bytes.write(to: url)
        return url
    }
}
