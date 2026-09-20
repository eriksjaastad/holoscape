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
        let fileManager = FileManager.default
        let url = try fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return Data() }
        let data = try Data(contentsOf: url)
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
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard id.rawValue.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StoreError.invalidSessionID(id.rawValue)
        }
        return directory.appendingPathComponent(id.rawValue).appendingPathExtension("scrollback")
    }
}
