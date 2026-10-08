import Darwin
import CryptoKit
import Foundation

/// Coordinates file transactions both within this process and with other
/// processes that use the same persistent advisory-lock path.
final class PersistentFileOperationLocks: @unchecked Sendable {
    static let shared = PersistentFileOperationLocks()

    private final class LockBox: @unchecked Sendable {
        let lock = NSLock()
    }

    private final class WeakLockBox {
        weak var value: LockBox?

        init(_ value: LockBox) {
            self.value = value
        }
    }

    private struct DirectoryLinkIdentity: Equatable {
        let directory: DurableDirectoryIdentity
        let parent: DurableDirectoryIdentity

        static func read(at directoryURL: URL) throws -> DirectoryLinkIdentity {
            DirectoryLinkIdentity(
                directory: try DurableDirectoryIdentity.read(at: directoryURL),
                parent: try DurableDirectoryIdentity.read(at: directoryURL.deletingLastPathComponent())
            )
        }

        static func == (lhs: DirectoryLinkIdentity, rhs: DirectoryLinkIdentity) -> Bool {
            lhs.directory.hasSameAuthority(as: rhs.directory) && lhs.parent == rhs.parent
        }
    }

    private struct StableAuthorityRecord: Codable, Equatable {
        let directoryDevice: UInt64
        let directoryInode: UInt64
        let directoryGeneration: UInt32
        let parentDevice: UInt64
        let parentInode: UInt64
        let parentGeneration: UInt32

        init(_ identity: DirectoryLinkIdentity) {
            directoryDevice = identity.directory.device
            directoryInode = identity.directory.inode
            directoryGeneration = identity.directory.generation
            parentDevice = identity.parent.device
            parentInode = identity.parent.inode
            parentGeneration = identity.parent.generation
        }

        func matches(_ identity: DirectoryLinkIdentity) -> Bool {
            directoryDevice == identity.directory.device
                && directoryInode == identity.directory.inode
                && directoryGeneration == identity.directory.generation
                && parentDevice == identity.parent.device
                && parentInode == identity.parent.inode
                && parentGeneration == identity.parent.generation
        }
    }

    private let registryLock = NSLock()
    private var locksByPath: [String: WeakLockBox] = [:]
    private var durableDirectoryIdentities: [String: DirectoryLinkIdentity] = [:]

    struct LockError: LocalizedError {
        let message: String
        let operationError: Error?
        let operationSucceeded: Bool

        init(
            message: String,
            operationError: Error? = nil,
            operationSucceeded: Bool = false
        ) {
            self.message = message
            self.operationError = operationError
            self.operationSucceeded = operationSucceeded
        }

        var errorDescription: String? { message }
    }

    func withLock<T>(
        for fileURL: URL,
        synchronizeCreatedDirectoryEntries: ((URL) throws -> Void)? = nil,
        unlockDescriptor: (Int32) -> Int32 = { flock($0, LOCK_UN) },
        closeDescriptor: (Int32) -> Int32 = Darwin.close,
        _ operation: () throws -> T
    ) throws -> T {
        let standardizedURL = fileURL.standardizedFileURL
        // Canonicalize the containing directory so callers using equivalent
        // directory aliases share authority, but never resolve the data-file
        // leaf. A concurrent leaf symlink swap must not redirect the advisory
        // lock outside the intended directory.
        let canonicalURL = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardizedURL.lastPathComponent)
        let key = canonicalURL.path
        let lockBox = registryLock.withLock {
            locksByPath = locksByPath.filter { $0.value.value != nil }
            if let existing = locksByPath[key]?.value {
                return existing
            }
            let created = LockBox()
            locksByPath[key] = WeakLockBox(created)
            return created
        }
        return try lockBox.lock.withLock {
            let targetDirectoryURL = canonicalURL.deletingLastPathComponent()
            let missingDirectories = Self.missingDirectories(endingAt: targetDirectoryURL)
            do {
                try FileManager.default.createDirectory(
                    at: targetDirectoryURL,
                    withIntermediateDirectories: true
                )
                if let synchronizeCreatedDirectoryEntries {
                    let currentIdentity = try DirectoryLinkIdentity.read(at: targetDirectoryURL)
                    let needsDurabilityInitialization = registryLock.withLock {
                        !missingDirectories.isEmpty || durableDirectoryIdentities[key] != currentIdentity
                    }
                    let directoriesToSynchronize = needsDurabilityInitialization
                        ? Self.directoryEntryParents(endingAt: targetDirectoryURL)
                        : missingDirectories.reversed().map { $0.deletingLastPathComponent() }
                    for directory in directoriesToSynchronize {
                        try synchronizeCreatedDirectoryEntries(directory)
                    }
                }
            } catch {
                throw LockError(
                    message: "createDirectory failed or synchronization failed for \(targetDirectoryURL.path): \(error)"
                )
            }

            // Acquire the deletion-stable authority first, then the legacy
            // sibling lock so a surviving pre-migration broker remains
            // serialized with the current GUI during a rolling relaunch.
            let lockURL = Self.lockURL(forCanonicalFileURL: canonicalURL)
            let legacyLockURL = canonicalURL.appendingPathExtension("lock")
            var heldDescriptors: [(descriptor: Int32, url: URL)] = []

            func acquire(_ url: URL) throws {
                let descriptor = Darwin.open(
                    url.path,
                    O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
                guard descriptor >= 0 else {
                    throw LockError(message: Self.posixFailure("open", path: url.path, code: errno))
                }
                guard flock(descriptor, LOCK_EX) == 0 else {
                    let lockFailure = Self.posixFailure("flock(LOCK_EX)", path: url.path, code: errno)
                    if closeDescriptor(descriptor) != 0 {
                        let closeFailure = Self.posixFailure("close", path: url.path, code: errno)
                        throw LockError(message: "\(lockFailure); cleanup also failed: \(closeFailure)")
                    }
                    throw LockError(message: lockFailure)
                }
                heldDescriptors.append((descriptor, url))
            }

            do {
                try acquire(lockURL)
                guard let stableDescriptor = heldDescriptors.first?.descriptor else {
                    throw LockError(message: "stable lock acquisition produced no authority descriptor")
                }
                let initialIdentity = try DirectoryLinkIdentity.read(at: targetDirectoryURL)
                // The stable lock persists the directory authority observed
                // before compatibility locking. Once initialized, replacement
                // of that directory fails closed instead of opening a different
                // legacy sibling inode from a surviving older broker.
                let stableAuthority = try Self.readOrInitializeStableAuthority(
                    descriptor: stableDescriptor,
                    identity: initialIdentity,
                    path: lockURL.path
                )
                guard stableAuthority.matches(initialIdentity) else {
                    throw LockError(
                        message: "directory authority changed for \(targetDirectoryURL.path); refusing split legacy lock authority"
                    )
                }
                try acquire(legacyLockURL)
                let lockedIdentity = try DirectoryLinkIdentity.read(at: targetDirectoryURL)
                guard stableAuthority.matches(lockedIdentity) else {
                    throw LockError(
                        message: "directory authority changed for \(targetDirectoryURL.path); refusing split legacy lock authority"
                    )
                }
            } catch {
                let cleanupFailures = Self.release(
                    heldDescriptors,
                    unlockDescriptor: unlockDescriptor,
                    closeDescriptor: closeDescriptor
                )
                let cleanupSuffix = cleanupFailures.isEmpty
                    ? ""
                    : "; cleanup also failed: " + cleanupFailures.joined(separator: "; ")
                throw LockError(message: "lock acquisition failed: \(error)\(cleanupSuffix)")
            }

            do {
                let currentIdentity = try DirectoryLinkIdentity.read(at: targetDirectoryURL)
                registryLock.withLock {
                    durableDirectoryIdentities[key] = currentIdentity
                }
            } catch {
                let cleanupFailures = Self.release(
                    heldDescriptors,
                    unlockDescriptor: unlockDescriptor,
                    closeDescriptor: closeDescriptor
                )
                let cleanupSuffix = cleanupFailures.isEmpty
                    ? ""
                    : "; cleanup also failed: " + cleanupFailures.joined(separator: "; ")
                throw LockError(
                    message: "directory authority read failed for \(targetDirectoryURL.path): \(error)\(cleanupSuffix)"
                )
            }

            let result: Result<T, Error>
            do {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }

            let cleanupFailures = Self.release(
                heldDescriptors,
                unlockDescriptor: unlockDescriptor,
                closeDescriptor: closeDescriptor
            )
            if !cleanupFailures.isEmpty {
                switch result {
                case .success:
                    throw LockError(
                        message: cleanupFailures.joined(separator: "; "),
                        operationSucceeded: true
                    )
                case .failure(let error):
                    throw LockError(
                        message: "operation failed: \(error); " + cleanupFailures.joined(separator: "; "),
                        operationError: error
                    )
                }
            }
            return try result.get()
        }
    }

    private static func posixFailure(_ operation: String, path: String, code: Int32) -> String {
        "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    }

    private static func readOrInitializeStableAuthority(
        descriptor: Int32,
        identity: DirectoryLinkIdentity,
        path: String
    ) throws -> StableAuthorityRecord {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw LockError(message: posixFailure("fstat", path: path, code: errno))
        }
        if metadata.st_size == 0 {
            let record = StableAuthorityRecord(identity)
            let data = try JSONEncoder().encode(record)
            var writeOffset = 0
            while writeOffset < data.count {
                let written = data.withUnsafeBytes { buffer in
                    Darwin.pwrite(
                        descriptor,
                        buffer.baseAddress?.advanced(by: writeOffset),
                        buffer.count - writeOffset,
                        off_t(writeOffset)
                    )
                }
                guard written > 0 else {
                    let code = written < 0 ? errno : EIO
                    throw LockError(message: posixFailure("pwrite", path: path, code: code))
                }
                writeOffset += written
            }
            guard ftruncate(descriptor, off_t(data.count)) == 0 else {
                throw LockError(message: posixFailure("ftruncate", path: path, code: errno))
            }
            guard fsync(descriptor) == 0 else {
                throw LockError(message: posixFailure("fsync", path: path, code: errno))
            }
            return record
        }
        guard metadata.st_size > 0, metadata.st_size <= 4_096 else {
            throw LockError(message: "invalid stable lock authority record at \(path)")
        }
        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard bytesRead == data.count else {
            let code = bytesRead < 0 ? errno : EIO
            throw LockError(message: posixFailure("pread", path: path, code: code))
        }
        do {
            return try JSONDecoder().decode(StableAuthorityRecord.self, from: data)
        } catch {
            throw LockError(message: "invalid stable lock authority record at \(path): \(error)")
        }
    }

    private static func release(
        _ descriptors: [(descriptor: Int32, url: URL)],
        unlockDescriptor: (Int32) -> Int32,
        closeDescriptor: (Int32) -> Int32
    ) -> [String] {
        var failures: [String] = []
        for held in descriptors.reversed() {
            if unlockDescriptor(held.descriptor) != 0 {
                failures.append(posixFailure("flock(LOCK_UN)", path: held.url.path, code: errno))
            }
            if closeDescriptor(held.descriptor) != 0 {
                failures.append(posixFailure("close", path: held.url.path, code: errno))
            }
        }
        return failures
    }

    static func lockURL(for fileURL: URL) -> URL {
        let standardizedURL = fileURL.standardizedFileURL
        let canonicalURL = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardizedURL.lastPathComponent)
        return lockURL(forCanonicalFileURL: canonicalURL)
    }

    private static func lockURL(forCanonicalFileURL fileURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(fileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent(".holoscape-operation-\(digest).lock")
    }

    private static func missingDirectories(endingAt directoryURL: URL) -> [URL] {
        var result: [URL] = []
        var candidate = directoryURL.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            result.append(candidate)
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return result
    }

    /// Until the persistent lock authority exists, synchronize the full path
    /// from root to leaf. This makes retries safe after a prior directory-sync
    /// failure left an in-memory directory tree that was never durably linked.
    private static func directoryEntryParents(endingAt directoryURL: URL) -> [URL] {
        let components = directoryURL.standardizedFileURL.pathComponents
        guard components.first == "/", components.count > 1 else { return [] }

        var result = [URL(fileURLWithPath: "/", isDirectory: true)]
        var parent = result[0]
        for component in components.dropFirst().dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            result.append(parent)
        }
        return result
    }
}

// Preserve the focused scrollback-test name while sharing this generic lock.
typealias ScrollbackSessionOperationLocks = PersistentFileOperationLocks
