import CryptoKit
import Darwin
import Foundation

final class ScrollbackSessionOperationLocks: @unchecked Sendable {
    static let shared = ScrollbackSessionOperationLocks()

    private final class LockBox: @unchecked Sendable {
        let lock = NSLock()
    }

    private final class WeakLockBox {
        weak var value: LockBox?

        init(_ value: LockBox) {
            self.value = value
        }
    }

    private let registryLock = NSLock()
    private var locksByPath: [String: WeakLockBox] = [:]

    struct LockError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    func withLock<T>(for fileURL: URL, _ operation: () throws -> T) throws -> T {
        let standardizedURL = fileURL.standardizedFileURL
        // Canonicalize the containing directory so callers using equivalent
        // directory aliases share authority, but never resolve the session-file
        // leaf. A concurrent leaf symlink swap must not redirect the advisory
        // lock outside the scrollback directory.
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
            let lockURL = canonicalURL.appendingPathExtension("lock")
            do {
                try FileManager.default.createDirectory(
                    at: lockURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                throw LockError(
                    message: "createDirectory failed for \(lockURL.deletingLastPathComponent().path): \(error)"
                )
            }

            // The lock leaf is persistent authority, not an aliasable path.
            // Refuse symlinks atomically at open so a concurrent replacement
            // cannot redirect flock to a file outside the scrollback directory.
            let descriptor = Darwin.open(
                lockURL.path,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw LockError(message: Self.posixFailure("open", path: lockURL.path, code: errno))
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let lockFailure = Self.posixFailure("flock(LOCK_EX)", path: lockURL.path, code: errno)
                if Darwin.close(descriptor) != 0 {
                    let closeFailure = Self.posixFailure("close", path: lockURL.path, code: errno)
                    throw LockError(message: "\(lockFailure); cleanup also failed: \(closeFailure)")
                }
                throw LockError(message: lockFailure)
            }

            let result: Result<T, Error>
            do {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }

            var cleanupFailures: [String] = []
            if flock(descriptor, LOCK_UN) != 0 {
                cleanupFailures.append(Self.posixFailure("flock(LOCK_UN)", path: lockURL.path, code: errno))
            }
            if Darwin.close(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("close", path: lockURL.path, code: errno))
            }
            if !cleanupFailures.isEmpty {
                let operationFailure: String
                switch result {
                case .success:
                    operationFailure = ""
                case .failure(let error):
                    operationFailure = "operation failed: \(error); "
                }
                throw LockError(message: operationFailure + cleanupFailures.joined(separator: "; "))
            }
            return try result.get()
        }
    }

    func withLock<T>(
        directoryDescriptor: Int32,
        directoryStatus: stat,
        fileName: String,
        displayPath: String,
        _ operation: () throws -> T
    ) throws -> T {
        let key = "\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(fileName)"
        let lockBox = registryLock.withLock {
            locksByPath = locksByPath.filter { $0.value.value != nil }
            if let existing = locksByPath[key]?.value { return existing }
            let created = LockBox()
            locksByPath[key] = WeakLockBox(created)
            return created
        }
        return try lockBox.lock.withLock {
            let lockName = fileName + ".lock"
            let lockPath = displayPath + ".lock"
            let descriptor = Darwin.openat(
                directoryDescriptor,
                lockName,
                O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw LockError(message: Self.posixFailure("openat", path: lockPath, code: errno))
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else {
                let code = errno == 0 ? EINVAL : errno
                let failure = Self.posixFailure("fstat", path: lockPath, code: code)
                if Darwin.close(descriptor) != 0 {
                    throw LockError(message: "\(failure); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                }
                throw LockError(message: failure)
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let lockFailure = Self.posixFailure("flock(LOCK_EX)", path: lockPath, code: errno)
                if Darwin.close(descriptor) != 0 {
                    throw LockError(message: "\(lockFailure); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                }
                throw LockError(message: lockFailure)
            }

            let result = Result { try operation() }
            var cleanupFailures: [String] = []
            if flock(descriptor, LOCK_UN) != 0 {
                cleanupFailures.append(Self.posixFailure("flock(LOCK_UN)", path: lockPath, code: errno))
            }
            if Darwin.close(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("close", path: lockPath, code: errno))
            }
            if !cleanupFailures.isEmpty {
                let prefix = result.failure.map { "operation failed: \($0); " } ?? ""
                throw LockError(message: prefix + cleanupFailures.joined(separator: "; "))
            }
            return try result.get()
        }
    }

    private static func posixFailure(_ operation: String, path: String, code: Int32) -> String {
        "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

/// Bounded raw-byte scrollback persistence for broker-owned terminal sessions.
///
/// Main and recovery inodes carry descriptor-written ownership markers. A
/// directory format marker permits one locked migration of legacy main tails;
/// after that marker is durable, unmarked files are never adopted.
/// Retention rewrites use a descriptor-bound recovery record so interruption
/// cannot expose a mixed prefix/suffix or discard the last durable tail.
struct DiskBackedScrollbackStore: Sendable {
    enum StoreError: Error, Equatable {
        case invalidSessionID(String)
        case unsafeScrollbackDirectory(String)
        case unsafeScrollbackFile(String)
        case corruptRecoveryFile(String)
        case descriptorCloseFailed(String)
        case fileOperationAndCloseFailed(operation: String, close: String)
    }

    enum TransactionPhase: Equatable, Sendable {
        case recoveryIntentDurable
        case primaryRewriteDurable
    }

    struct StoredScrollbackTail: Equatable, Sendable {
        let sessionID: BrokerSessionID
        let byteCount: Int
        let modifiedAt: Date?
    }

    private enum FileKind {
        case main
        case recovery

        func marker(forPath path: String) -> Data {
            let fileName = (path as NSString).lastPathComponent
            switch self {
            case .main: return Data("holoscape-scrollback-main-v1:\(fileName)".utf8)
            case .recovery: return Data("holoscape-scrollback-recovery-v1:\(fileName)".utf8)
            }
        }
    }

    private enum RecoveryPhase: String {
        case idle
        case preparing
        case ready
    }

    private enum RecoveryObservation {
        case none
        case preparing
        case ready(Data)
        case idleNeedsCleanup
    }

    private struct OpenedDescriptor {
        let descriptor: Int32
        let status: stat
    }

    private struct DirectoryAuthority {
        let descriptor: Int32
        let status: stat
    }

    private struct RecoveryRecord {
        static let magic = Data("HoloScapeScrollbackRecoveryV1\0".utf8)
        static let digestCount = 32
        static let headerSize = magic.count + 8 + 8 + 8 + digestCount

        let device: UInt64
        let inode: UInt64
        let payload: Data

        init(mainStatus: stat, payload: Data) {
            device = UInt64(bitPattern: Int64(mainStatus.st_dev))
            inode = UInt64(mainStatus.st_ino)
            self.payload = payload
        }

        private init(device: UInt64, inode: UInt64, payload: Data) {
            self.device = device
            self.inode = inode
            self.payload = payload
        }

        func encoded() -> Data {
            var data = Self.magic
            data.appendBigEndian(device)
            data.appendBigEndian(inode)
            data.appendBigEndian(UInt64(payload.count))
            data.append(contentsOf: SHA256.hash(data: payload))
            data.append(payload)
            return data
        }

        static func decode(_ data: Data, path: String) throws -> RecoveryRecord {
            guard data.count >= headerSize, data.prefix(magic.count) == magic else {
                throw StoreError.corruptRecoveryFile(path)
            }
            var offset = magic.count
            let device = try data.readBigEndianUInt64(at: &offset, recoveryPath: path)
            let inode = try data.readBigEndianUInt64(at: &offset, recoveryPath: path)
            let count = try data.readBigEndianUInt64(at: &offset, recoveryPath: path)
            guard count <= UInt64(Int.max - headerSize),
                  data.count == headerSize + Int(count) else {
                throw StoreError.corruptRecoveryFile(path)
            }
            let expectedDigest = Data(data[offset..<(offset + digestCount)])
            offset += digestCount
            let payload = Data(data[offset...])
            guard Data(SHA256.hash(data: payload)) == expectedDigest else {
                throw StoreError.corruptRecoveryFile(path)
            }
            return RecoveryRecord(device: device, inode: inode, payload: payload)
        }

        func matches(_ status: stat) -> Bool {
            device == UInt64(bitPattern: Int64(status.st_dev))
                && inode == UInt64(status.st_ino)
        }
    }

    private static let ownerXattr = "com.holoscape.scrollback.owner"
    private static let recoveryPhaseXattr = "com.holoscape.scrollback.recovery-phase"
    private static let formatMarkerName = ".holoscape-scrollback-format-v1"
    private static let formatMarkerContents = Data("HoloScapeScrollbackDirectoryV1\n".utf8)
    private static let migrationLockName = ".holoscape-scrollback-migration.lock"

    let directory: URL
    private let maxRetainedBytes: Int
    private let operationLocks = ScrollbackSessionOperationLocks.shared
    private let beforeLeafMutation: @Sendable (URL) -> Void
    private let beforeDescriptorMutation: @Sendable (URL) -> Void
    private let afterDirectoryOpen: @Sendable (URL) -> Void
    private let transactionPhaseHook: @Sendable (TransactionPhase) throws -> Void
    private let descriptorClose: @Sendable (Int32) -> Int32
    private let listingMetadata: @Sendable (Int32) throws -> stat

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession,
        beforeLeafMutation: @escaping @Sendable (URL) -> Void = { _ in },
        beforeDescriptorMutation: @escaping @Sendable (URL) -> Void = { _ in },
        afterDirectoryOpen: @escaping @Sendable (URL) -> Void = { _ in },
        transactionPhaseHook: @escaping @Sendable (TransactionPhase) throws -> Void = { _ in },
        descriptorClose: @escaping @Sendable (Int32) -> Int32 = { Darwin.close($0) },
        listingMetadata: @escaping @Sendable (Int32) throws -> stat = { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return status
        }
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
        self.beforeLeafMutation = beforeLeafMutation
        self.beforeDescriptorMutation = beforeDescriptorMutation
        self.afterDirectoryOpen = afterDirectoryOpen
        self.transactionPhaseHook = transactionPhaseHook
        self.descriptorClose = descriptorClose
        self.listingMetadata = listingMetadata
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try withDirectoryAuthority(createIfMissing: true) { authority in
            try withSessionLock(authority, url: url) {
                if try !pathExists(authority, name: url.lastPathComponent) {
                    try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                    guard !data.isEmpty else { return }
                }
                _ = try withOwnedDescriptor(
                    authority,
                    at: url,
                    flags: O_RDWR,
                    createIfMissing: !data.isEmpty,
                    kind: .main
                ) { descriptor, sourceStatus in
                    beforeLeafMutation(url)
                    try requireIdentity(authority, at: url, matches: sourceStatus, kind: .main)
                    beforeDescriptorMutation(url)
                    try repairIfNeeded(authority, descriptor, status: sourceStatus, mainURL: url)
                    guard !data.isEmpty else { return }

                    let end = Darwin.lseek(descriptor, 0, SEEK_END)
                    guard end >= 0 else { throw Self.posixError(code: errno) }
                    guard end <= off_t(Int.max - data.count) else {
                        throw Self.posixError(code: EFBIG)
                    }
                    try writeAll(descriptor, data: data, offset: end)
                    let retainedLimit = max(0, maxRetainedBytes)
                    if Int(end) + data.count > retainedLimit {
                        try sync(descriptor)
                        let retained = try readSuffix(descriptor, count: retainedLimit)
                        try commitRewrite(
                            authority,
                            descriptor,
                            status: sourceStatus,
                            mainURL: url,
                            payload: retained
                        )
                    }
                    try requireIdentity(authority, at: url, matches: sourceStatus, kind: .main)
                }
            }
        }
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        let url = try fileURL(for: id)
        guard let result = try withExistingDirectoryAuthority({ authority in
            try withSessionLock(authority, url: url) {
            let decision = try withOwnedDescriptor(
                authority,
                at: url,
                flags: O_RDONLY,
                createIfMissing: false,
                kind: .main
            ) { descriptor, status -> Data? in
                let recovery = try observeRecovery(authority, at: recoveryURL(for: url), mainStatus: status)
                if case .none = recovery,
                   status.st_size <= off_t(max(0, maxRetainedBytes)) {
                    return cappedTail(try readAll(descriptor), requestedBytes: maxBytes)
                }
                return nil
            }
            guard let decision else {
                try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                return Data()
            }
            if let result = decision { return result }
            return try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                cappedTail(try readAll(descriptor), requestedBytes: maxBytes)
            }
            }
        }) else { return Data() }
        return result
    }

    /// Clears bytes through the validated descriptor and deliberately retains
    /// the empty, owned inode. Darwin has no identity-conditional unlink; not
    /// unlinking prevents a pathname rebound from deleting a foreign file.
    func remove(for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        guard let _: Void = try withExistingDirectoryAuthority({ authority in
            try withSessionLock(authority, url: url) {
            let removed: Void? = try withOwnedDescriptor(
                authority,
                at: url,
                flags: O_RDWR,
                createIfMissing: false,
                kind: .main
            ) { descriptor, status in
                try prepareMutation(authority, mainURL: url, mainStatus: status)
                try repairIfNeeded(authority, descriptor, status: status, mainURL: url)
                try rewrite(descriptor, with: Data())
                try sync(descriptor)
                try requireIdentity(authority, at: url, matches: status, kind: .main)
            }
            if removed == nil { try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url)) }
            }
        }) else { return }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        guard let result = try withExistingDirectoryAuthority({ authority in
            try withSessionLock(authority, url: url) {
            let decision = try withOwnedDescriptor(
                authority,
                at: url,
                flags: O_RDONLY,
                createIfMissing: false,
                kind: .main
            ) { _, status -> Int? in
                let recovery = try observeRecovery(authority, at: recoveryURL(for: url), mainStatus: status)
                if case .none = recovery, status.st_size <= off_t(max(0, maxRetainedBytes)) {
                    return Int(status.st_size)
                }
                return nil
            }
            guard let decision else {
                try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                return 0
            }
            if let result = decision { return result }
            return try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
                return Int(status.st_size)
            }
            }
        }) else { return 0 }
        return result
    }

    func listStoredTails() throws -> [StoredScrollbackTail] {
        guard let result = try withExistingDirectoryAuthority({ authority in
            let names = try directoryEntryNames(authority)
            var tails: [StoredScrollbackTail] = []
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard url.pathExtension == "scrollback" else { continue }
                let rawID = url.deletingPathExtension().lastPathComponent
                guard Self.isValidSessionID(rawID) else { continue }
                let metadata: stat?
                do {
                    metadata = try withSessionLock(authority, url: url) {
                        let decision = try withOwnedDescriptor(
                            authority,
                            at: url,
                            flags: O_RDONLY,
                            createIfMissing: false,
                            kind: .main
                        ) { descriptor, status -> stat? in
                            let recovery = try observeRecovery(
                                authority,
                                at: recoveryURL(for: url),
                                mainStatus: status
                            )
                            guard case .none = recovery,
                                  status.st_size <= off_t(max(0, maxRetainedBytes)) else {
                                return nil
                            }
                            let currentStatus = try listingMetadata(descriptor)
                            guard currentStatus.st_mode & S_IFMT == S_IFREG else {
                                throw StoreError.unsafeScrollbackFile(url.path)
                            }
                            try requireIdentity(authority, at: url, matches: status, kind: .main)
                            return currentStatus
                        }
                        guard let decision else { return nil }
                        if let currentStatus = decision { return currentStatus }
                        return try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                            let currentStatus = try listingMetadata(descriptor)
                            guard currentStatus.st_mode & S_IFMT == S_IFREG else {
                                throw StoreError.unsafeScrollbackFile(url.path)
                            }
                            return currentStatus
                        }
                    }
                } catch let error as ScrollbackSessionOperationLocks.LockError {
                    throw error
                } catch let error as StoreError {
                    switch error {
                    case .descriptorCloseFailed, .fileOperationAndCloseFailed:
                        throw error
                    case .unsafeScrollbackFile(let path) where path.hasSuffix(".scrollback.recovery"):
                        throw error
                    case .invalidSessionID, .unsafeScrollbackDirectory, .unsafeScrollbackFile:
                        continue
                    case .corruptRecoveryFile:
                        throw error
                    }
                } catch {
                    throw error
                }
                guard let metadata, metadata.st_size > 0, metadata.st_size <= off_t(Int.max) else { continue }
                tails.append(StoredScrollbackTail(
                    sessionID: BrokerSessionID(rawValue: rawID),
                    byteCount: Int(metadata.st_size),
                    modifiedAt: Date(
                        timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                            + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
                    )
                ))
            }
            return tails.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
        }) else { return [] }
        return result
    }

    private func withDirectoryAuthority<T>(
        createIfMissing: Bool,
        _ operation: (DirectoryAuthority) throws -> T
    ) throws -> T? {
        // Resolve stable aliases (including macOS's `/var` -> `/private/var`)
        // once, then traverse the resulting absolute path with descriptor-relative
        // opens. Every operation remains bound to the opened directory even if
        // the configured alias or one of its ancestors is rebound afterward.
        let standardized = try canonicalDirectoryURL()
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }

        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }
        var directoryStatus = stat()
        let components = standardized.pathComponents.dropFirst()

        do {
            for component in components where component != "/" {
                var next = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT, createIfMissing {
                    if mkdirat(descriptor, component, S_IRWXU) != 0, errno != EEXIST {
                        throw Self.posixError(code: errno)
                    }
                    next = Darwin.openat(
                        descriptor,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    let code = errno
                    if code == ENOENT, !createIfMissing {
                        try close(descriptor, after: .success(()))
                        return nil
                    }
                    if code == ELOOP || code == ENOTDIR {
                        throw StoreError.unsafeScrollbackDirectory(directory.path)
                    }
                    throw Self.posixError(code: code)
                }
                let previous = descriptor
                descriptor = next
                try close(previous, after: .success(()))
            }

            guard fstat(descriptor, &directoryStatus) == 0 else { throw Self.posixError(code: errno) }
            guard directoryStatus.st_mode & S_IFMT == S_IFDIR else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
        } catch {
            return try close(descriptor, after: .failure(error))
        }

        let authority = DirectoryAuthority(
            descriptor: descriptor,
            status: directoryStatus
        )
        afterDirectoryOpen(directory)
        do {
            try migrateLegacyFilesIfNeeded(authority)
        } catch {
            return try close(descriptor, after: .failure(error))
        }
        let result = Result { try operation(authority) }
        return try close(descriptor, after: result)
    }

    private func withExistingDirectoryAuthority<T>(
        _ operation: (DirectoryAuthority) throws -> T
    ) throws -> T? {
        try withDirectoryAuthority(createIfMissing: false, operation)
    }

    private func canonicalDirectoryURL() throws -> URL {
        var candidate = directory.standardizedFileURL
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
        var missingComponents: [String] = []
        while true {
            errno = 0
            if let resolved = realpath(candidate.path, nil) {
                defer { free(resolved) }
                var result = URL(
                    fileURLWithPath: String(cString: resolved),
                    isDirectory: true
                )
                for component in missingComponents.reversed() {
                    result.appendPathComponent(component, isDirectory: true)
                }
                return result
            }

            let code = errno
            guard code == ENOENT else {
                if code == ELOOP || code == ENOTDIR {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                throw Self.posixError(code: code)
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path, !candidate.lastPathComponent.isEmpty else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            missingComponents.append(candidate.lastPathComponent)
            candidate = parent
        }
    }

    private func withSessionLock<T>(
        _ authority: DirectoryAuthority,
        url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try operationLocks.withLock(
            directoryDescriptor: authority.descriptor,
            directoryStatus: authority.status,
            fileName: url.lastPathComponent,
            displayPath: url.path,
            operation
        )
    }

    private func pathExists(_ authority: DirectoryAuthority, name: String) throws -> Bool {
        var status = stat()
        if fstatat(authority.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw Self.posixError(code: errno)
    }

    private func directoryEntryNames(_ authority: DirectoryAuthority) throws -> [String] {
        // `dup` would share the directory stream offset with the authority.
        // Open `.` relative to the pinned directory so migration and listing can
        // enumerate independently during the same store operation.
        let enumerationDescriptor = Darwin.openat(
            authority.descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw Self.posixError(code: errno) }
        guard let stream = fdopendir(enumerationDescriptor) else {
            let code = errno
            _ = Darwin.close(enumerationDescriptor)
            throw Self.posixError(code: code)
        }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        let readCode = errno
        let closeCode = closedir(stream) == 0 ? 0 : errno
        if readCode != 0 { throw Self.posixError(code: readCode) }
        if closeCode != 0 { throw Self.posixError(code: closeCode) }
        return names
    }

    private func migrateLegacyFilesIfNeeded(_ authority: DirectoryAuthority) throws {
        let lockBase = String(Self.migrationLockName.dropLast(".lock".count))
        try operationLocks.withLock(
            directoryDescriptor: authority.descriptor,
            directoryStatus: authority.status,
            fileName: lockBase,
            displayPath: directory.appendingPathComponent(lockBase).path
        ) {
            if try formatMarkerExists(authority) { return }
            for name in try directoryEntryNames(authority) {
                let url = directory.appendingPathComponent(name)
                guard url.pathExtension == "scrollback",
                      Self.isValidSessionID(url.deletingPathExtension().lastPathComponent) else { continue }
                let descriptor = Darwin.openat(
                    authority.descriptor,
                    name,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
                guard descriptor >= 0 else {
                    if errno == ENOENT || errno == ELOOP || errno == EISDIR { continue }
                    throw Self.posixError(code: errno)
                }
                let result: Result<Void, Error> = Result {
                    var status = stat()
                    guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
                    guard status.st_mode & S_IFMT == S_IFREG else { return }
                    let expected = FileKind.main.marker(forPath: url.path)
                    let existing = try getXattr(
                        descriptor: descriptor,
                        name: Self.ownerXattr,
                        allowMissing: true
                    )
                    if let existing, existing != expected {
                        throw StoreError.unsafeScrollbackFile(url.path)
                    }
                    if existing == nil {
                        try setXattr(descriptor: descriptor, name: Self.ownerXattr, value: expected)
                        try sync(descriptor)
                    }
                }
                _ = try close(descriptor, after: result)
            }
            try createFormatMarker(authority)
        }
    }

    private func formatMarkerExists(_ authority: DirectoryAuthority) throws -> Bool {
        let descriptor = Darwin.openat(
            authority.descriptor,
            Self.formatMarkerName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP { throw StoreError.unsafeScrollbackDirectory(directory.path) }
            throw Self.posixError(code: errno)
        }
        let result: Result<Bool, Error>
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
            guard status.st_mode & S_IFMT == S_IFREG,
                  try readAll(descriptor) == Self.formatMarkerContents else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            result = .success(true)
        } catch { result = .failure(error) }
        return try close(descriptor, after: result)
    }

    private func createFormatMarker(_ authority: DirectoryAuthority) throws {
        let descriptor = Darwin.openat(
            authority.descriptor,
            Self.formatMarkerName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }
        let result: Result<Void, Error>
        do {
            try writeAll(descriptor, data: Self.formatMarkerContents, offset: 0)
            try sync(descriptor)
            result = .success(())
        } catch { result = .failure(error) }
        _ = try close(descriptor, after: result)
        try sync(authority.descriptor)
    }

    private func withRepairedWritableMain<T>(
        _ authority: DirectoryAuthority,
        at url: URL,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T {
        guard let result = try withOwnedDescriptor(
            authority,
            at: url,
            flags: O_RDWR,
            createIfMissing: false,
            kind: .main,
            { descriptor, status in
                try prepareMutation(authority, mainURL: url, mainStatus: status)
                try repairIfNeeded(authority, descriptor, status: status, mainURL: url)
                let result = try operation(descriptor, status)
                try requireIdentity(authority, at: url, matches: status, kind: .main)
                return result
            }
        ) else { return try operationOnMissingMain(authority, url) }
        return result
    }

    private func operationOnMissingMain<T>(_ authority: DirectoryAuthority, _ url: URL) throws -> T {
        try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
        throw StoreError.unsafeScrollbackFile(url.path)
    }

    private func prepareMutation(_ authority: DirectoryAuthority, mainURL: URL, mainStatus: stat) throws {
        beforeLeafMutation(mainURL)
        try requireIdentity(authority, at: mainURL, matches: mainStatus, kind: .main)
        beforeDescriptorMutation(mainURL)
    }

    private func repairIfNeeded(_ authority: DirectoryAuthority, _ descriptor: Int32, status: stat, mainURL: URL) throws {
        let sidecarURL = recoveryURL(for: mainURL)
        switch try observeRecovery(authority, at: sidecarURL, mainStatus: status) {
        case .none:
            break
        case .ready(let payload):
            try withRequiredOwnedDescriptor(authority, at: sidecarURL, flags: O_RDWR, kind: .recovery) {
                recoveryDescriptor, recoveryStatus in
                try requireIdentity(authority, at: mainURL, matches: status, kind: .main)
                try requireIdentity(authority, at: sidecarURL, matches: recoveryStatus, kind: .recovery)
                try rewrite(descriptor, with: payload)
                try sync(descriptor)
                try finishRecovery(authority, recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
            }
        case .preparing, .idleNeedsCleanup:
            // `ready` is durable before primary mutation starts. Preparing is
            // therefore safe to discard; idle means the primary is already durable.
            try withRequiredOwnedDescriptor(authority, at: sidecarURL, flags: O_RDWR, kind: .recovery) {
                recoveryDescriptor, recoveryStatus in
                try finishRecovery(authority, recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
            }
        }

        let retainedLimit = max(0, maxRetainedBytes)
        var currentStatus = stat()
        guard fstat(descriptor, &currentStatus) == 0 else {
            throw Self.posixError(code: errno)
        }
        if currentStatus.st_size > off_t(retainedLimit) {
            try commitRewrite(
                authority,
                descriptor,
                status: status,
                mainURL: mainURL,
                payload: try readSuffix(descriptor, count: retainedLimit)
            )
        }
    }

    private func commitRewrite(
        _ authority: DirectoryAuthority,
        _ mainDescriptor: Int32,
        status mainStatus: stat,
        mainURL: URL,
        payload: Data
    ) throws {
        let sidecarURL = recoveryURL(for: mainURL)
        _ = try withOwnedDescriptor(
            authority,
            at: sidecarURL,
            flags: O_RDWR,
            createIfMissing: true,
            kind: .recovery
        ) { recoveryDescriptor, recoveryStatus in
            try requireIdentity(authority, at: mainURL, matches: mainStatus, kind: .main)
            try requireIdentity(authority, at: sidecarURL, matches: recoveryStatus, kind: .recovery)

            try setRecoveryPhase(.preparing, descriptor: recoveryDescriptor)
            try sync(recoveryDescriptor)
            try rewrite(
                recoveryDescriptor,
                with: RecoveryRecord(mainStatus: mainStatus, payload: payload).encoded()
            )
            try sync(recoveryDescriptor)
            try setRecoveryPhase(.ready, descriptor: recoveryDescriptor)
            try sync(recoveryDescriptor)
            try transactionPhaseHook(.recoveryIntentDurable)

            try requireIdentity(authority, at: mainURL, matches: mainStatus, kind: .main)
            try requireIdentity(authority, at: sidecarURL, matches: recoveryStatus, kind: .recovery)
            try rewrite(mainDescriptor, with: payload)
            try sync(mainDescriptor)
            try transactionPhaseHook(.primaryRewriteDurable)

            try requireIdentity(authority, at: mainURL, matches: mainStatus, kind: .main)
            try finishRecovery(authority, recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
        }
    }

    private func finishRecovery(_ authority: DirectoryAuthority, _ descriptor: Int32, status: stat, url: URL) throws {
        try requireIdentity(authority, at: url, matches: status, kind: .recovery)
        // Idle becomes durable only after the primary is durable. Stale bytes
        // left after this point are cleanup-only, never an authoritative intent.
        try setRecoveryPhase(.idle, descriptor: descriptor)
        try sync(descriptor)
        try rewrite(descriptor, with: Data())
        try sync(descriptor)
        try requireIdentity(authority, at: url, matches: status, kind: .recovery)
    }

    private func observeRecovery(_ authority: DirectoryAuthority, at url: URL, mainStatus: stat) throws -> RecoveryObservation {
        try withOwnedDescriptor(
            authority,
            at: url,
            flags: O_RDONLY,
            createIfMissing: false,
            kind: .recovery
        ) { descriptor, status in
            let maximumPayload = max(
                max(0, maxRetainedBytes),
                ScrollbackPersistencePolicy.maxRetainedBytesPerSession
            )
            let maximumRecordSize = RecoveryRecord.headerSize + maximumPayload
            guard status.st_size >= 0,
                  status.st_size <= off_t(maximumRecordSize) else {
                throw StoreError.corruptRecoveryFile(url.path)
            }
            let data = try readAll(descriptor)
            let phaseData = try getXattr(
                descriptor: descriptor,
                name: Self.recoveryPhaseXattr,
                allowMissing: true
            )
            guard let phaseData,
                  let phaseValue = String(data: phaseData, encoding: .utf8),
                  let phase = RecoveryPhase(rawValue: phaseValue) else {
                if data.isEmpty { return .none }
                throw StoreError.corruptRecoveryFile(url.path)
            }
            switch phase {
            case .idle:
                return data.isEmpty ? .none : .idleNeedsCleanup
            case .preparing:
                return .preparing
            case .ready:
                let record = try RecoveryRecord.decode(data, path: url.path)
                guard record.matches(mainStatus) else {
                    throw StoreError.corruptRecoveryFile(url.path)
                }
                return .ready(record.payload)
            }
        } ?? .none
    }

    private func rejectRecoveryWithoutMain(_ authority: DirectoryAuthority, at url: URL) throws {
        guard try pathExists(authority, name: url.lastPathComponent) else { return }
        _ = try withOwnedDescriptor(
            authority,
            at: url,
            flags: O_RDONLY,
            createIfMissing: false,
            kind: .recovery
        ) { _, _ in throw StoreError.corruptRecoveryFile(url.path) }
    }

    private func withOwnedDescriptor<T>(
        _ authority: DirectoryAuthority,
        at url: URL,
        flags: Int32,
        createIfMissing: Bool,
        kind: FileKind,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T? {
        guard let opened = try openOwnedDescriptor(
            authority,
            at: url,
            flags: flags,
            createIfMissing: createIfMissing,
            kind: kind
        ) else { return nil }
        let result: Result<T, Error>
        do { result = .success(try operation(opened.descriptor, opened.status)) }
        catch { result = .failure(error) }
        return try close(opened.descriptor, after: result)
    }

    private func withRequiredOwnedDescriptor<T>(
        _ authority: DirectoryAuthority,
        at url: URL,
        flags: Int32,
        kind: FileKind,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T {
        guard let result = try withOwnedDescriptor(
            authority,
            at: url,
            flags: flags,
            createIfMissing: false,
            kind: kind,
            operation
        ) else { throw StoreError.corruptRecoveryFile(url.path) }
        return result
    }

    private func openOwnedDescriptor(
        _ authority: DirectoryAuthority,
        at url: URL,
        flags: Int32,
        createIfMissing: Bool,
        kind: FileKind
    ) throws -> OpenedDescriptor? {
        var created = false
        var descriptor: Int32
        if createIfMissing {
            descriptor = Darwin.openat(
                authority.descriptor,
                url.lastPathComponent,
                flags | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 {
                created = true
            } else if errno == EEXIST {
                descriptor = Darwin.openat(authority.descriptor, url.lastPathComponent, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
        } else {
            descriptor = Darwin.openat(authority.descriptor, url.lastPathComponent, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let code = errno
            if !createIfMissing, code == ENOENT { return nil }
            if code == ELOOP { throw StoreError.unsafeScrollbackFile(url.path) }
            throw Self.posixError(code: code)
        }

        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.unsafeScrollbackFile(url.path)
            }
            if created {
                try setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: kind.marker(forPath: url.path)
                )
                if kind == .recovery { try setRecoveryPhase(.idle, descriptor: descriptor) }
                try sync(descriptor)
                try sync(authority.descriptor)
            } else {
                try requireOwnership(descriptor: descriptor, path: url.path, kind: kind)
            }
            // Creation authority is established through the new descriptor, then
            // the path must still name that inode before any file data is changed.
            try requireIdentity(authority, at: url, matches: status, kind: kind)
            return OpenedDescriptor(descriptor: descriptor, status: status)
        } catch {
            return try close(descriptor, after: .failure(error))
        }
    }

    private func requireIdentity(_ authority: DirectoryAuthority, at url: URL, matches expectedStatus: stat, kind: FileKind) throws {
        let descriptor = Darwin.openat(
            authority.descriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw StoreError.unsafeScrollbackFile(url.path) }
        let result: Result<Void, Error>
        do {
            var currentStatus = stat()
            guard fstat(descriptor, &currentStatus) == 0 else { throw Self.posixError(code: errno) }
            guard currentStatus.st_mode & S_IFMT == S_IFREG,
                  Self.isSameFile(currentStatus, expectedStatus) else {
                throw StoreError.unsafeScrollbackFile(url.path)
            }
            try requireOwnership(descriptor: descriptor, path: url.path, kind: kind)
            result = .success(())
        } catch { result = .failure(error) }
        try close(descriptor, after: result)
    }

    private func requireOwnership(descriptor: Int32, path: String, kind: FileKind) throws {
        guard try getXattr(
            descriptor: descriptor,
            name: Self.ownerXattr,
            allowMissing: true
        ) == kind.marker(forPath: path) else { throw StoreError.unsafeScrollbackFile(path) }
    }

    private func setRecoveryPhase(_ phase: RecoveryPhase, descriptor: Int32) throws {
        try setXattr(
            descriptor: descriptor,
            name: Self.recoveryPhaseXattr,
            value: Data(phase.rawValue.utf8)
        )
    }

    private func getXattr(
        descriptor: Int32,
        name: String,
        allowMissing: Bool
    ) throws -> Data? {
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard size >= 0 else {
            let code = errno
            if allowMissing, code == ENOATTR { return nil }
            throw Self.posixError(code: code)
        }
        var data = Data(count: size)
        let readCount = data.withUnsafeMutableBytes { bytes in
            fgetxattr(descriptor, name, bytes.baseAddress, size, 0, 0)
        }
        guard readCount == size else {
            if readCount < 0 { throw Self.posixError(code: errno) }
            throw Self.posixError(code: EIO)
        }
        return data
    }

    private func setXattr(descriptor: Int32, name: String, value: Data) throws {
        let result = value.withUnsafeBytes { bytes in
            fsetxattr(descriptor, name, bytes.baseAddress, value.count, 0, 0)
        }
        guard result == 0 else { throw Self.posixError(code: errno) }
    }

    private func readAll(_ descriptor: Int32) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
        guard status.st_size >= 0, status.st_size <= off_t(Int.max) else {
            throw Self.posixError(code: EFBIG)
        }
        let expectedCount = Int(status.st_size)
        var data = Data(count: expectedCount)
        var totalRead = 0
        while totalRead < expectedCount {
            let result = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: totalRead),
                    expectedCount - totalRead,
                    off_t(totalRead)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(code: errno)
            }
            if result == 0 {
                data.removeSubrange(totalRead..<data.count)
                break
            }
            totalRead += result
        }
        return data
    }

    private func readSuffix(_ descriptor: Int32, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
        guard status.st_size >= 0, status.st_size <= off_t(Int.max) else {
            throw Self.posixError(code: EFBIG)
        }
        let available = min(Int(status.st_size), count)
        var data = Data(count: available)
        let start = status.st_size - off_t(available)
        var totalRead = 0
        while totalRead < available {
            let result = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: totalRead),
                    available - totalRead,
                    start + off_t(totalRead)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(code: errno)
            }
            guard result > 0 else { throw Self.posixError(code: EIO) }
            totalRead += result
        }
        return data
    }

    private func writeAll(_ descriptor: Int32, data: Data, offset: off_t) throws {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { bytes in
                Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    data.count - written,
                    offset + off_t(written)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(code: errno)
            }
            guard result > 0 else { throw Self.posixError(code: EIO) }
            written += result
        }
    }

    private func rewrite(_ descriptor: Int32, with data: Data) throws {
        try writeAll(descriptor, data: data, offset: 0)
        guard ftruncate(descriptor, off_t(data.count)) == 0 else {
            throw Self.posixError(code: errno)
        }
    }

    private func sync(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw Self.posixError(code: errno) }
    }


    private func close<T>(_ descriptor: Int32, after result: Result<T, Error>) throws -> T {
        guard descriptorClose(descriptor) == 0 else {
            let closeError = StoreError.descriptorCloseFailed(
                String(describing: Self.posixError(code: errno))
            )
            switch result {
            case .success: throw closeError
            case .failure(let operationError):
                throw StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationError),
                    close: String(describing: closeError)
                )
            }
        }
        return try result.get()
    }

    private func cappedTail(_ data: Data, requestedBytes: Int) -> Data {
        let capped = min(max(0, requestedBytes), max(0, maxRetainedBytes))
        guard capped > 0 else { return Data() }
        guard data.count > capped else { return data }
        return Data(data.suffix(capped))
    }

    private func recoveryURL(for mainURL: URL) -> URL {
        mainURL.appendingPathExtension("recovery")
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


    private static func posixError(code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func isSameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndianUInt64(at offset: inout Int, recoveryPath: String) throws -> UInt64 {
        guard offset >= 0, count >= offset + 8 else {
            throw DiskBackedScrollbackStore.StoreError.corruptRecoveryFile(recoveryPath)
        }
        let value = self[offset..<(offset + 8)].reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        offset += 8
        return value
    }
}
