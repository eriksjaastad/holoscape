import Foundation
import CryptoKit
import ZIPFoundation

/// Loads `.wamp` skin bundles (ZIP archives with a `.wamp` extension)
/// into a SHA-256-keyed on-disk cache and returns the unzipped
/// directory URL. Applies the same two-layer sandbox used for
/// directory-layout skins (`SkinEngine.validateAssetPath` string gate +
/// `assertPathResolvesInside` symlink-resolve gate) plus per-asset and
/// per-bundle 50 MB size caps so a malicious bundle can't fill the
/// cache disk.
///
/// Cache layout: `cacheRoot/<sha256-hex>/` contains the unzipped skin
/// tree (a clone of the directory-layout skin format so downstream
/// pipeline steps — `loadImages`, `loadNinepatchSidecar`, `registerFonts` —
/// don't need to care whether they started from a `.wamp` or a folder).
///
/// `@MainActor` because `SkinEngine` is `@MainActor` and this type is
/// only ever touched from there. The ZIPFoundation `Archive` API is
/// thread-safe for read-only use, but we hold everything on the main
/// actor to keep the ownership story simple.
@MainActor
final class WampBundleLoader {

    /// Errors raised by `unzipIfNeeded`. Specific cases let callers
    /// surface different banner text and distinct log lines per
    /// Requirement 13.5.
    enum LoadError: Error, Equatable {
        /// Bundle bytes couldn't be read or hashed, or a partial
        /// extraction couldn't be cleaned up.
        case ioFailure(String)
        /// File doesn't open as a ZIP archive at all.
        case notAZip(String)
        /// An entry's path violates the sandbox (`..`, absolute path,
        /// URL scheme, or a symlink resolving outside the cache subdir).
        case zipEntryEscapesSandbox(String)
        /// Single asset's uncompressed size exceeded 50 MB.
        case assetTooLarge(path: String, bytes: Int)
        /// Running total of uncompressed bytes would exceed 50 MB.
        case bundleTooLarge(bytes: Int)
        /// Bundle extracted cleanly but has no `skin.json` at the root.
        case missingManifest
    }

    /// 50 MB per-asset and per-bundle. Defaults; tests can override
    /// via init parameters to keep property tests from churning real
    /// 50 MB data on every iteration.
    static let defaultAssetSizeCap = 50 * 1024 * 1024
    static let defaultBundleSizeCap = 50 * 1024 * 1024

    // Legacy aliases so call sites and tests that read
    // `WampBundleLoader.assetSizeCap` / `.bundleSizeCap` still work.
    static let assetSizeCap = defaultAssetSizeCap
    static let bundleSizeCap = defaultBundleSizeCap

    /// Root directory for the hash-keyed cache. Usually
    /// `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    /// / Holoscape / Skins`. Injectable for tests.
    let cacheRoot: URL

    /// Instance cap on a single asset's uncompressed size. Defaults
    /// to `Self.defaultAssetSizeCap`. Property tests override with a
    /// tiny value to exercise the rejection path without writing
    /// megabytes per iteration.
    let assetSizeCap: Int

    /// Instance cap on the running total of all assets in a bundle.
    let bundleSizeCap: Int

    /// The SkinEngine holds the sandbox helpers
    /// (`validateAssetPath`, `assertPathResolvesInside`). Weak to avoid
    /// a retain cycle — the engine owns the loader.
    weak var sandbox: SkinEngine?

    init(
        cacheRoot: URL,
        assetSizeCap: Int = WampBundleLoader.defaultAssetSizeCap,
        bundleSizeCap: Int = WampBundleLoader.defaultBundleSizeCap
    ) {
        self.cacheRoot = cacheRoot
        self.assetSizeCap = assetSizeCap
        self.bundleSizeCap = bundleSizeCap
    }

    /// Return the unzipped directory URL for `bundleURL`, unzipping on
    /// cache miss. Second call with an unchanged bundle hits the cache
    /// (keyed by SHA-256 of the bundle bytes).
    ///
    /// On throw from any step beyond the initial hash read, the
    /// partial extraction is cleaned up so the cache never contains a
    /// half-unzipped subdirectory.
    func unzipIfNeeded(bundleURL: URL) throws -> URL {
        let hash = try contentHash(bundleURL)
        let subdir = cacheRoot.appendingPathComponent(hash)

        // Fast path: cache hit. We require both the directory and a
        // `skin.json` at its root so a previous failed extraction
        // (leftover empty directory) doesn't register as a hit.
        let manifestPath = subdir.appendingPathComponent("skin.json").path
        if FileManager.default.fileExists(atPath: subdir.path),
           FileManager.default.fileExists(atPath: manifestPath) {
            // Bump mtime so LRU purge sees this as recently used.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: subdir.path
            )
            return subdir
        }

        // Cache miss. Extract with validation + size caps.
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        do {
            try extractArchive(at: bundleURL, into: subdir)
        } catch {
            // Cleanup on any failure so the cache doesn't accumulate
            // half-extracted subdirectories. Best-effort; a cleanup
            // failure doesn't change the thrown error (callers care
            // about the original cause).
            try? FileManager.default.removeItem(at: subdir)
            throw error
        }

        // Post-condition: the extracted tree must have a skin.json at
        // its root. `SkinEngine.loadComposite` would fail later with a
        // more generic "unknown skin" error; catching it here pins the
        // issue to the bundle structure.
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            try? FileManager.default.removeItem(at: subdir)
            throw LoadError.missingManifest
        }

        return subdir
    }

    /// SHA-256 of `bundleURL`'s bytes, lowercase hex-encoded. Property 9
    /// (deterministic, byte-sensitive) is verified in tests.
    func contentHash(_ bundleURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: bundleURL, options: .mappedIfSafe)
        } catch {
            throw LoadError.ioFailure("could not read bundle: \(error.localizedDescription)")
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Walk `cacheRoot` and remove oldest subdirectories (by directory
    /// mtime) until the total on-disk size is ≤ `cap` (default
    /// `Self.bundleSizeCap`). `preserving` is the hash of the currently-
    /// active bundle — its subdirectory is never evicted, even if it's
    /// the oldest entry (Property 14).
    ///
    /// Callable from `SkinEngine.init` as startup cleanup. Idempotent:
    /// returns immediately when total size is already under cap.
    ///
    /// `cap` is parameterized so property tests can drive the invariant
    /// with tiny (KB-scale) entries rather than real 50 MB data, keeping
    /// the test suite fast. Production always uses the default.
    func purgeLRU(preserving: String?, cap: Int? = nil) throws {
        let effectiveCap = cap ?? self.bundleSizeCap
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return }

        struct Entry {
            let url: URL
            let mtime: Date
            let bytes: Int
            let name: String
        }

        let entries: [Entry] = (try FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )).compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let bytes = Self.directorySize(at: url)
            return Entry(url: url, mtime: mtime, bytes: bytes, name: url.lastPathComponent)
        }

        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > effectiveCap else { return }

        // Oldest first. Skip `preserving`.
        let evictable = entries
            .filter { $0.name != preserving }
            .sorted { $0.mtime < $1.mtime }

        for entry in evictable {
            guard total > effectiveCap else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    // MARK: - Private extraction

    /// Iterate archive entries once, validating each path through the
    /// SkinEngine sandbox and enforcing size caps BEFORE writing any
    /// bytes. ZIPFoundation's `Archive` is an Iterator-style type so we
    /// can read entry metadata (path, uncompressed size) without
    /// touching file-system state.
    ///
    /// Refuses to run if `sandbox` is nil. `try sandbox?.validate(_:)`
    /// in Swift is a silent no-op when the optional is nil — so without
    /// this guard, an unwired sandbox would bypass BOTH the string-path
    /// gate and the symlink-resolve gate and write every ZIP entry
    /// unchecked. The guard converts that class of bug from "silent
    /// security regression" into "loud init failure."
    private func extractArchive(at bundleURL: URL, into subdir: URL) throws {
        guard let sandbox = self.sandbox else {
            throw LoadError.ioFailure(
                "sandbox not configured — refusing to extract; SkinEngine must set loader.sandbox"
            )
        }

        let archive: Archive
        do {
            archive = try Archive(url: bundleURL, accessMode: .read)
        } catch {
            throw LoadError.notAZip(bundleURL.lastPathComponent)
        }

        var runningTotal = 0

        for entry in archive {
            // Skip every non-file entry type. Directories are implicit
            // (we mkdir the parent as needed when writing files); symlinks
            // are out of scope — a bundle that ships symlinks would let
            // a subsequent entry resolve through the symlink and escape
            // the cache sandbox even though its string path looks clean.
            // Dropping the whole non-file class means the attack surface
            // is "does any file-type entry pass the string gate AND the
            // post-write symlink-resolve gate?" which is what the two
            // existing gates are designed to catch.
            guard entry.type == .file else { continue }

            // 1. String-gate the entry path. Rejects `..`, absolute paths,
            //    URL schemes. Same rule as directory-layout asset paths.
            do {
                try sandbox.validateAssetPath(entry.path)
            } catch {
                throw LoadError.zipEntryEscapesSandbox(entry.path)
            }

            // 2. Per-asset size cap.
            let assetBytes = Int(entry.uncompressedSize)
            guard assetBytes <= self.assetSizeCap else {
                throw LoadError.assetTooLarge(path: entry.path, bytes: assetBytes)
            }

            // 3. Running-total size cap — must include THIS entry's size
            //    so a single benign-looking entry can't push us over.
            runningTotal += assetBytes
            guard runningTotal <= self.bundleSizeCap else {
                throw LoadError.bundleTooLarge(bytes: runningTotal)
            }

            // 4. Compute target file URL and create its parent directory.
            let destination = subdir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // 5. Extract the entry's bytes.
            do {
                _ = try archive.extract(entry, to: destination)
            } catch {
                throw LoadError.ioFailure("extraction failed for '\(entry.path)': \(error.localizedDescription)")
            }

            // 6. Symlink-resolve gate: after the file is on disk, verify
            //    its resolved path stays inside the cache subdirectory.
            //    Catches a smuggled symlink whose string path looks
            //    clean but whose target escapes.
            do {
                try sandbox.assertPathResolvesInside(
                    destination,
                    root: subdir,
                    originalPath: entry.path
                )
            } catch {
                throw LoadError.zipEntryEscapesSandbox(entry.path)
            }
        }
    }

    /// Recursive directory size (regular files only). Used by
    /// `purgeLRU` to compute total cache footprint.
    private static func directorySize(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return 0
        }
        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += size
            }
        }
        return total
    }
}
