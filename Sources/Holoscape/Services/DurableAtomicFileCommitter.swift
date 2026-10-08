import Darwin
import Foundation

/// Filesystem identity for detecting delete-and-recreate replacement at an
/// unchanged pathname. `st_gen` distinguishes inode reuse when the filesystem
/// provides a generation number.
struct DurableDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    func hasSameAuthority(as other: DurableDirectoryIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && generation == other.generation
    }

    static func read(at url: URL) throws -> DurableDirectoryIdentity {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var metadata = stat()
        let metadataError: Error? = Darwin.fstat(descriptor, &metadata) == 0
            ? nil
            : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        let closeError: Error? = Darwin.close(descriptor) == 0
            ? nil
            : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        if let metadataError, let closeError {
            throw DurableAtomicFileCommitter.CommitError.persistenceAndCleanupFailed(
                operation: String(describing: metadataError),
                cleanup: String(describing: closeError)
            )
        }
        if let metadataError { throw metadataError }
        if let closeError { throw closeError }
        return DurableDirectoryIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen,
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }
}

enum DurableDirectoryAuthorityError: Error, LocalizedError {
    case replaced(path: String)
    case unavailable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .replaced(path):
            return "Directory authority changed during durable commit: \(path)"
        case let .unavailable(path, reason):
            return "Directory authority became unavailable during durable commit at \(path): \(reason)"
        }
    }
}

/// Commits one file through a synchronized sibling temporary file and atomic
/// replacement. A post-replacement failure is distinct because the new bytes
/// are already visible and callers must not pretend the old value remains
/// authoritative.
struct DurableAtomicFileCommitter {
    enum CommitError: Error, Equatable, LocalizedError {
        case persistenceAndCleanupFailed(operation: String, cleanup: String)
        case replacementCommitted(durabilityFailure: String)

        var errorDescription: String? {
            switch self {
            case let .persistenceAndCleanupFailed(operation, cleanup):
                return "Persistence failed (\(operation)); temporary-file cleanup also failed (\(cleanup))"
            case let .replacementCommitted(durabilityFailure):
                return "Atomic replacement committed, but durability could not be confirmed: \(durabilityFailure)"
            }
        }
    }

    struct Persistence: @unchecked Sendable {
        let writeAndSynchronizeTemporaryFile: (Data, URL) throws -> Void
        let writeAndSynchronizeTemporaryFileAtDescriptor: ((Data, Int32, String) throws -> Void)?
        let replaceFile: (URL, URL) throws -> Void
        let synchronizeDirectory: (URL) throws -> Void
        let removeTemporaryFile: (URL) throws -> Void
        let removeTemporaryFileAtDescriptor: (Int32, String) throws -> Void
        let closeDirectoryDescriptor: (Int32) -> Int32
        let readDirectoryIdentity: (URL) throws -> DurableDirectoryIdentity

        init(
            writeAndSynchronizeTemporaryFile: @escaping (Data, URL) throws -> Void,
            writeAndSynchronizeTemporaryFileAtDescriptor: ((Data, Int32, String) throws -> Void)? = nil,
            replaceFile: @escaping (URL, URL) throws -> Void,
            synchronizeDirectory: @escaping (URL) throws -> Void,
            removeTemporaryFile: @escaping (URL) throws -> Void,
            removeTemporaryFileAtDescriptor: @escaping (Int32, String) throws -> Void = DurableAtomicFileCommitter.removeTemporaryFile,
            closeDirectoryDescriptor: @escaping (Int32) -> Int32 = Darwin.close,
            readDirectoryIdentity: @escaping (URL) throws -> DurableDirectoryIdentity = DurableDirectoryIdentity.read
        ) {
            self.writeAndSynchronizeTemporaryFile = writeAndSynchronizeTemporaryFile
            self.writeAndSynchronizeTemporaryFileAtDescriptor = writeAndSynchronizeTemporaryFileAtDescriptor
            self.replaceFile = replaceFile
            self.synchronizeDirectory = synchronizeDirectory
            self.removeTemporaryFile = removeTemporaryFile
            self.removeTemporaryFileAtDescriptor = removeTemporaryFileAtDescriptor
            self.closeDirectoryDescriptor = closeDirectoryDescriptor
            self.readDirectoryIdentity = readDirectoryIdentity
        }

        static let live = Persistence(
            writeAndSynchronizeTemporaryFile: DurableAtomicFileCommitter.writeAndSynchronizeTemporaryFile,
            writeAndSynchronizeTemporaryFileAtDescriptor: DurableAtomicFileCommitter.writeAndSynchronizeTemporaryFile,
            replaceFile: DurableAtomicFileCommitter.replaceFile,
            synchronizeDirectory: DurableAtomicFileCommitter.synchronizeDirectory,
            removeTemporaryFile: { try FileManager.default.removeItem(at: $0) },
            removeTemporaryFileAtDescriptor: DurableAtomicFileCommitter.removeTemporaryFile,
            closeDirectoryDescriptor: Darwin.close,
            readDirectoryIdentity: DurableDirectoryIdentity.read
        )
    }

    let persistence: Persistence

    init(persistence: Persistence = .live) {
        self.persistence = persistence
    }

    /// Returns only after both file contents and the containing-directory
    /// replacement entry have been synchronized.
    func commit(
        _ data: Data,
        to destinationURL: URL,
        directoryIdentity expectedDirectoryIdentity: DurableDirectoryIdentity? = nil,
        additionalDirectoriesToSynchronize: [URL] = []
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let authorityDescriptor: Int32?
        if expectedDirectoryIdentity != nil {
            let descriptor = directoryURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw DurableDirectoryAuthorityError.unavailable(
                    path: directoryURL.path,
                    reason: String(cString: strerror(errno))
                )
            }
            authorityDescriptor = descriptor
        } else {
            authorityDescriptor = nil
        }

        var replacementCommitted = false
        let operationResult: Result<Void, Error>
        do {
            try validateDirectoryIdentity(expectedDirectoryIdentity, at: directoryURL)
            if let authorityDescriptor,
               let descriptorWriter = persistence.writeAndSynchronizeTemporaryFileAtDescriptor {
                try descriptorWriter(data, authorityDescriptor, temporaryURL.lastPathComponent)
            } else {
                try persistence.writeAndSynchronizeTemporaryFile(data, temporaryURL)
            }
            try validateDirectoryIdentity(expectedDirectoryIdentity, at: directoryURL)
            try persistence.replaceFile(temporaryURL, destinationURL)
            replacementCommitted = true
            try persistence.synchronizeDirectory(directoryURL)
            for directory in additionalDirectoriesToSynchronize {
                try persistence.synchronizeDirectory(directory)
            }
            try validateDirectoryIdentity(expectedDirectoryIdentity, at: directoryURL)
            operationResult = .success(())
        } catch {
            let operationError = error
            if replacementCommitted {
                do {
                    try validateDirectoryIdentity(expectedDirectoryIdentity, at: directoryURL)
                    operationResult = .failure(CommitError.replacementCommitted(
                        durabilityFailure: String(describing: operationError)
                    ))
                } catch {
                    // The replacement remains authoritative only while it is
                    // visible through the directory pathname the caller owns.
                    operationResult = .failure(error)
                }
            } else {
                do {
                    try removeTemporaryFileIfPresent(
                        temporaryURL,
                        authorityDescriptor: authorityDescriptor
                    )
                    operationResult = .failure(operationError)
                } catch {
                    operationResult = .failure(CommitError.persistenceAndCleanupFailed(
                        operation: String(describing: operationError),
                        cleanup: String(describing: error)
                    ))
                }
            }
        }

        if let authorityDescriptor, persistence.closeDirectoryDescriptor(authorityDescriptor) != 0 {
            let closeError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            switch operationResult {
            case .success where replacementCommitted:
                throw CommitError.replacementCommitted(durabilityFailure: String(describing: closeError))
            case .success:
                throw closeError
            case .failure(let operationError):
                if case let CommitError.replacementCommitted(durabilityFailure) = operationError {
                    throw CommitError.replacementCommitted(
                        durabilityFailure: durabilityFailure
                            + "; directory authority cleanup failed: "
                            + String(describing: closeError)
                    )
                }
                throw CommitError.persistenceAndCleanupFailed(
                    operation: String(describing: operationError),
                    cleanup: String(describing: closeError)
                )
            }
        }
        return try operationResult.get()
    }

    private func removeTemporaryFileIfPresent(
        _ temporaryURL: URL,
        authorityDescriptor: Int32?
    ) throws {
        if let authorityDescriptor {
            try persistence.removeTemporaryFileAtDescriptor(
                authorityDescriptor,
                temporaryURL.lastPathComponent
            )
            return
        }
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try persistence.removeTemporaryFile(temporaryURL)
        }
    }

    static func removeTemporaryFile(at descriptor: Int32, named name: String) throws {
        let result = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
        if result == 0 || errno == ENOENT { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func validateDirectoryIdentity(
        _ expectedIdentity: DurableDirectoryIdentity?,
        at directoryURL: URL
    ) throws {
        guard let expectedIdentity else { return }
        let currentIdentity: DurableDirectoryIdentity
        do {
            currentIdentity = try persistence.readDirectoryIdentity(directoryURL)
        } catch {
            throw DurableDirectoryAuthorityError.unavailable(
                path: directoryURL.path,
                reason: String(describing: error)
            )
        }
        guard currentIdentity.hasSameAuthority(as: expectedIdentity) else {
            throw DurableDirectoryAuthorityError.replaced(path: directoryURL.path)
        }
    }

    static func writeAndSynchronizeTemporaryFile(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try writeSynchronizeAndClose(data, descriptor: descriptor)
    }

    static func writeAndSynchronizeTemporaryFile(
        _ data: Data,
        at directoryDescriptor: Int32,
        named name: String
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try writeSynchronizeAndClose(data, descriptor: descriptor)
    }

    private static func writeSynchronizeAndClose(_ data: Data, descriptor: Int32) throws {
        var operationError: Error?
        do {
            try writeAll(data, to: descriptor)
            try fullSync(descriptor)
        } catch {
            operationError = error
        }

        let closeResult = Darwin.close(descriptor)
        let closeError = closeResult == 0
            ? nil
            : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        if let operationError, let closeError {
            throw CommitError.persistenceAndCleanupFailed(
                operation: String(describing: operationError),
                cleanup: String(describing: closeError)
            )
        }
        if let operationError { throw operationError }
        if let closeError { throw closeError }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += result
            }
        }
    }

    private static func fullSync(_ descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let fullSyncCode = errno
        if fullSyncCode != EINVAL && fullSyncCode != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: fullSyncCode) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func replaceFile(at sourceURL: URL, with destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var syncError: Error?
        do {
            try fullSync(descriptor)
        } catch {
            syncError = error
        }
        let closeResult = Darwin.close(descriptor)
        let closeError = closeResult == 0
            ? nil
            : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        if let syncError, let closeError {
            throw CommitError.persistenceAndCleanupFailed(
                operation: String(describing: syncError),
                cleanup: String(describing: closeError)
            )
        }
        if let syncError { throw syncError }
        if let closeError { throw closeError }
    }
}
