import Foundation

/// Bounded raw-byte scrollback persistence for broker-owned terminal sessions.
///
/// This store is intentionally keyed only by broker session id and stores bytes in
/// opaque `.scrollback` files. It does not serialize environment, commands, or
/// IPC frames; those remain in `BrokerSessionRegistry`. Retention is enforced on
/// every append so disk state obeys the same per-session cap as the in-memory
/// runtime ring.
struct DiskBackedScrollbackStore: Sendable {
    enum StoreError: Error, Equatable {
        case invalidSessionID(String)
    }

    /// Maintenance-facing metadata for one persisted per-session scrollback tail.
    struct StoredScrollbackTail: Equatable, Sendable {
        let sessionID: BrokerSessionID
        let byteCount: Int
        let modifiedAt: Date?
    }

    let directory: URL
    private let maxRetainedBytes: Int

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        guard !data.isEmpty else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try fileURL(for: id)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try prune(url)
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        guard maxRetainedBytes > 0 else { return Data() }
        let fileManager = FileManager.default
        let url = try fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return Data() }
        let data = try Data(contentsOf: url)
        // A crash between append's write and its prune can leave the persisted
        // tail oversized relative to the retention cap. Repair it on read so a
        // normal store operation restores the bounded-scrollback guarantee.
        if data.count > maxRetainedBytes {
            try prune(url)
        }
        let capped = min(maxBytes, maxRetainedBytes)
        guard data.count > capped else { return data }
        return Data(data.suffix(capped))
    }

    func remove(for id: BrokerSessionID) throws {
        let fileManager = FileManager.default
        let url = try fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let fileManager = FileManager.default
        let url = try fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int ?? 0
    }

    /// Enumerates the persisted per-session scrollback tails in the configured
    /// directory, exposing just enough metadata for a settings or manual
    /// maintenance UI. Only valid `.scrollback` session files are reported;
    /// foreign files and malformed session names are skipped, and a single
    /// entry whose metadata cannot be read (for example a tail deleted between
    /// directory enumeration and this read) is skipped rather than failing the
    /// whole listing, so maintenance still surfaces every tail it can.
    ///
    /// `resourceValues` is a seam over the per-entry metadata read so the
    /// resilience path can be exercised deterministically in tests; callers
    /// that omit it get the real `URL.resourceValues(forKeys:)` read.
    func listStoredTails(
        resourceValues: (URL) throws -> URLResourceValues = { url in
            try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        }
    ) throws -> [StoredScrollbackTail] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var tails: [StoredScrollbackTail] = []
        for url in urls {
            guard url.pathExtension == "scrollback" else { continue }
            let values: URLResourceValues
            do {
                values = try resourceValues(url)
            } catch {
                // A per-entry metadata/readability race must not throw out the
                // entire listing; skip the bad entry and surface the rest.
                continue
            }
            guard values.isRegularFile == true else { continue }
            let rawID = url.deletingPathExtension().lastPathComponent
            guard Self.isValidSessionID(rawID) else { continue }
            tails.append(StoredScrollbackTail(
                sessionID: BrokerSessionID(rawValue: rawID),
                byteCount: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate
            ))
        }
        return tails.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    private func prune(_ url: URL) throws {
        guard maxRetainedBytes > 0 else {
            try Data().write(to: url, options: .atomic)
            return
        }
        let data = try Data(contentsOf: url)
        guard data.count > maxRetainedBytes else { return }
        try Data(data.suffix(maxRetainedBytes)).write(to: url, options: .atomic)
    }

    private func fileURL(for id: BrokerSessionID) throws -> URL {
        guard Self.isValidSessionID(id.rawValue) else {
            throw StoreError.invalidSessionID(id.rawValue)
        }
        return directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
    }

    static func isValidSessionID(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return rawValue.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
