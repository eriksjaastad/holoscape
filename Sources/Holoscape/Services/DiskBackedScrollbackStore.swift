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

    private static func posixFailure(_ operation: String, path: String, code: Int32) -> String {
        "\(operation) failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Bounded raw-byte scrollback persistence for broker-owned terminal sessions.
///
/// Main and recovery inodes carry descriptor-written ownership markers. An
/// unmarked file is never adopted, even when it occupies a valid session path.
/// Retention rewrites use a descriptor-bound recovery record so interruption
/// cannot expose a mixed prefix/suffix or discard the last durable tail.
struct DiskBackedScrollbackStore: Sendable {
    enum StoreError: Error, Equatable {
        case invalidSessionID(String)
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

    let directory: URL
    private let maxRetainedBytes: Int
    private let operationLocks = ScrollbackSessionOperationLocks.shared
    private let beforeLeafMutation: @Sendable (URL) -> Void
    private let beforeDescriptorMutation: @Sendable (URL) -> Void
    private let transactionPhaseHook: @Sendable (TransactionPhase) throws -> Void
    private let descriptorClose: @Sendable (Int32) -> Int32

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession,
        beforeLeafMutation: @escaping @Sendable (URL) -> Void = { _ in },
        beforeDescriptorMutation: @escaping @Sendable (URL) -> Void = { _ in },
        transactionPhaseHook: @escaping @Sendable (TransactionPhase) throws -> Void = { _ in },
        descriptorClose: @escaping @Sendable (Int32) -> Int32 = { Darwin.close($0) }
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
        self.beforeLeafMutation = beforeLeafMutation
        self.beforeDescriptorMutation = beforeDescriptorMutation
        self.transactionPhaseHook = transactionPhaseHook
        self.descriptorClose = descriptorClose
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try operationLocks.withLock(for: url) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !Self.pathExistsWithoutFollowingSymlinks(url) {
                try rejectRecoveryWithoutMain(at: recoveryURL(for: url))
                guard !data.isEmpty else { return }
            }
            _ = try withOwnedDescriptor(
                at: url,
                flags: O_RDWR,
                createIfMissing: !data.isEmpty,
                kind: .main
            ) { descriptor, sourceStatus in
                beforeLeafMutation(url)
                try requireIdentity(at: url, matches: sourceStatus, kind: .main)
                beforeDescriptorMutation(url)
                try repairIfNeeded(descriptor, status: sourceStatus, mainURL: url)
                guard !data.isEmpty else { return }

                let end = Darwin.lseek(descriptor, 0, SEEK_END)
                guard end >= 0 else { throw Self.posixError(code: errno) }
                guard end <= off_t(Int.max - data.count) else {
                    throw Self.posixError(code: EFBIG)
                }
                try writeAll(descriptor, data: data, offset: end)
                let retainedLimit = max(0, maxRetainedBytes)
                if Int(end) + data.count > retainedLimit {
                    // The appended primary is durable before the recovery intent
                    // becomes authoritative. A pre-intent crash can safely derive
                    // the same suffix from this intact oversized primary.
                    try sync(descriptor)
                    let retained = try readSuffix(descriptor, count: retainedLimit)
                    try commitRewrite(
                        descriptor,
                        status: sourceStatus,
                        mainURL: url,
                        payload: retained
                    )
                }
                try requireIdentity(at: url, matches: sourceStatus, kind: .main)
            }
        }
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
            let decision = try withOwnedDescriptor(
                at: url,
                flags: O_RDONLY,
                createIfMissing: false,
                kind: .main
            ) { descriptor, status -> Data? in
                let recovery = try observeRecovery(at: recoveryURL(for: url), mainStatus: status)
                if case .none = recovery,
                   status.st_size <= off_t(max(0, maxRetainedBytes)) {
                    return cappedTail(try readAll(descriptor), requestedBytes: maxBytes)
                }
                return nil
            }
            guard let decision else {
                try rejectRecoveryWithoutMain(at: recoveryURL(for: url))
                return Data()
            }
            if let result = decision { return result }
            return try withRepairedWritableMain(at: url) { descriptor, _ in
                cappedTail(try readAll(descriptor), requestedBytes: maxBytes)
            }
        }
    }

    /// Clears bytes through the validated descriptor and deliberately retains
    /// the empty, owned inode. Darwin has no identity-conditional unlink; not
    /// unlinking prevents a pathname rebound from deleting a foreign file.
    func remove(for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try operationLocks.withLock(for: url) {
            let removed: Void? = try withOwnedDescriptor(
                at: url,
                flags: O_RDWR,
                createIfMissing: false,
                kind: .main
            ) { descriptor, status in
                try prepareMutation(mainURL: url, mainStatus: status)
                try repairIfNeeded(descriptor, status: status, mainURL: url)
                try rewrite(descriptor, with: Data())
                try sync(descriptor)
                try requireIdentity(at: url, matches: status, kind: .main)
            }
            if removed == nil { try rejectRecoveryWithoutMain(at: recoveryURL(for: url)) }
        }
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        return try operationLocks.withLock(for: url) {
            let decision = try withOwnedDescriptor(
                at: url,
                flags: O_RDONLY,
                createIfMissing: false,
                kind: .main
            ) { _, status -> Int? in
                let recovery = try observeRecovery(at: recoveryURL(for: url), mainStatus: status)
                if case .none = recovery, status.st_size <= off_t(max(0, maxRetainedBytes)) {
                    return Int(status.st_size)
                }
                return nil
            }
            guard let decision else {
                try rejectRecoveryWithoutMain(at: recoveryURL(for: url))
                return 0
            }
            if let result = decision { return result }
            return try withRepairedWritableMain(at: url) { descriptor, _ in
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
                return Int(status.st_size)
            }
        }
    }

    func listStoredTails(
        resourceValues: (URL) throws -> URLResourceValues = { url in
            try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
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
            let rawID = url.deletingPathExtension().lastPathComponent
            guard Self.isValidSessionID(rawID), Self.isRegularFileWithoutFollowingSymlinks(url) else { continue }
            let values: URLResourceValues?
            do {
                values = try operationLocks.withLock(for: url) {
                    try withOwnedDescriptor(
                        at: url,
                        flags: O_RDONLY,
                        createIfMissing: false,
                        kind: .main
                    ) { _, status in
                        guard case .none = try observeRecovery(
                            at: recoveryURL(for: url), mainStatus: status
                        ) else { return nil }
                        let values = try resourceValues(url)
                        try requireIdentity(at: url, matches: status, kind: .main)
                        return values
                    } ?? nil
                }
            } catch let error as ScrollbackSessionOperationLocks.LockError {
                throw error
            } catch let error as StoreError {
                switch error {
                case .descriptorCloseFailed, .fileOperationAndCloseFailed:
                    throw error
                case .invalidSessionID, .unsafeScrollbackFile, .corruptRecoveryFile:
                    continue
                }
            } catch {
                // Foreign, malformed, and racy entries are omitted without
                // disclosing metadata or mutating either inode.
                continue
            }
            guard let values,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount > 0 else { continue }
            tails.append(StoredScrollbackTail(
                sessionID: BrokerSessionID(rawValue: rawID),
                byteCount: byteCount,
                modifiedAt: values.contentModificationDate
            ))
        }
        return tails.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    private func withRepairedWritableMain<T>(
        at url: URL,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T {
        guard let result = try withOwnedDescriptor(
            at: url,
            flags: O_RDWR,
            createIfMissing: false,
            kind: .main,
            { descriptor, status in
                try prepareMutation(mainURL: url, mainStatus: status)
                try repairIfNeeded(descriptor, status: status, mainURL: url)
                let result = try operation(descriptor, status)
                try requireIdentity(at: url, matches: status, kind: .main)
                return result
            }
        ) else { return try operationOnMissingMain(url) }
        return result
    }

    private func operationOnMissingMain<T>(_ url: URL) throws -> T {
        try rejectRecoveryWithoutMain(at: recoveryURL(for: url))
        throw StoreError.unsafeScrollbackFile(url.path)
    }

    private func prepareMutation(mainURL: URL, mainStatus: stat) throws {
        beforeLeafMutation(mainURL)
        try requireIdentity(at: mainURL, matches: mainStatus, kind: .main)
        beforeDescriptorMutation(mainURL)
    }

    private func repairIfNeeded(_ descriptor: Int32, status: stat, mainURL: URL) throws {
        let sidecarURL = recoveryURL(for: mainURL)
        switch try observeRecovery(at: sidecarURL, mainStatus: status) {
        case .none:
            break
        case .ready(let payload):
            try withRequiredOwnedDescriptor(at: sidecarURL, flags: O_RDWR, kind: .recovery) {
                recoveryDescriptor, recoveryStatus in
                try requireIdentity(at: mainURL, matches: status, kind: .main)
                try requireIdentity(at: sidecarURL, matches: recoveryStatus, kind: .recovery)
                try rewrite(descriptor, with: payload)
                try sync(descriptor)
                try finishRecovery(recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
            }
        case .preparing, .idleNeedsCleanup:
            // `ready` is durable before primary mutation starts. Preparing is
            // therefore safe to discard; idle means the primary is already durable.
            try withRequiredOwnedDescriptor(at: sidecarURL, flags: O_RDWR, kind: .recovery) {
                recoveryDescriptor, recoveryStatus in
                try finishRecovery(recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
            }
        }

        let retainedLimit = max(0, maxRetainedBytes)
        var currentStatus = stat()
        guard fstat(descriptor, &currentStatus) == 0 else {
            throw Self.posixError(code: errno)
        }
        if currentStatus.st_size > off_t(retainedLimit) {
            try commitRewrite(
                descriptor,
                status: status,
                mainURL: mainURL,
                payload: try readSuffix(descriptor, count: retainedLimit)
            )
        }
    }

    private func commitRewrite(
        _ mainDescriptor: Int32,
        status mainStatus: stat,
        mainURL: URL,
        payload: Data
    ) throws {
        let sidecarURL = recoveryURL(for: mainURL)
        _ = try withOwnedDescriptor(
            at: sidecarURL,
            flags: O_RDWR,
            createIfMissing: true,
            kind: .recovery
        ) { recoveryDescriptor, recoveryStatus in
            try requireIdentity(at: mainURL, matches: mainStatus, kind: .main)
            try requireIdentity(at: sidecarURL, matches: recoveryStatus, kind: .recovery)

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

            try requireIdentity(at: mainURL, matches: mainStatus, kind: .main)
            try requireIdentity(at: sidecarURL, matches: recoveryStatus, kind: .recovery)
            try rewrite(mainDescriptor, with: payload)
            try sync(mainDescriptor)
            try transactionPhaseHook(.primaryRewriteDurable)

            try requireIdentity(at: mainURL, matches: mainStatus, kind: .main)
            try finishRecovery(recoveryDescriptor, status: recoveryStatus, url: sidecarURL)
        }
    }

    private func finishRecovery(_ descriptor: Int32, status: stat, url: URL) throws {
        try requireIdentity(at: url, matches: status, kind: .recovery)
        // Idle becomes durable only after the primary is durable. Stale bytes
        // left after this point are cleanup-only, never an authoritative intent.
        try setRecoveryPhase(.idle, descriptor: descriptor)
        try sync(descriptor)
        try rewrite(descriptor, with: Data())
        try sync(descriptor)
        try requireIdentity(at: url, matches: status, kind: .recovery)
    }

    private func observeRecovery(at url: URL, mainStatus: stat) throws -> RecoveryObservation {
        try withOwnedDescriptor(
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

    private func rejectRecoveryWithoutMain(at url: URL) throws {
        guard Self.pathExistsWithoutFollowingSymlinks(url) else { return }
        _ = try withOwnedDescriptor(
            at: url,
            flags: O_RDONLY,
            createIfMissing: false,
            kind: .recovery
        ) { _, _ in throw StoreError.corruptRecoveryFile(url.path) }
    }

    private func withOwnedDescriptor<T>(
        at url: URL,
        flags: Int32,
        createIfMissing: Bool,
        kind: FileKind,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T? {
        guard let opened = try openOwnedDescriptor(
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
        at url: URL,
        flags: Int32,
        kind: FileKind,
        _ operation: (Int32, stat) throws -> T
    ) throws -> T {
        guard let result = try withOwnedDescriptor(
            at: url,
            flags: flags,
            createIfMissing: false,
            kind: kind,
            operation
        ) else { throw StoreError.corruptRecoveryFile(url.path) }
        return result
    }

    private func openOwnedDescriptor(
        at url: URL,
        flags: Int32,
        createIfMissing: Bool,
        kind: FileKind
    ) throws -> OpenedDescriptor? {
        var created = false
        var descriptor: Int32
        if createIfMissing {
            descriptor = Darwin.open(
                url.path,
                flags | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            if descriptor >= 0 {
                created = true
            } else if errno == EEXIST {
                descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
        } else {
            descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
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
                try syncDirectory(containing: url)
            } else {
                try requireOwnership(descriptor: descriptor, path: url.path, kind: kind)
            }
            // Creation authority is established through the new descriptor, then
            // the path must still name that inode before any file data is changed.
            try requireIdentity(at: url, matches: status, kind: kind)
            return OpenedDescriptor(descriptor: descriptor, status: status)
        } catch {
            return try close(descriptor, after: .failure(error))
        }
    }

    private func requireIdentity(at url: URL, matches expectedStatus: stat, kind: FileKind) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
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

    private func syncDirectory(containing url: URL) throws {
        let directoryDescriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw Self.posixError(code: errno) }
        let result: Result<Void, Error> = fsync(directoryDescriptor) == 0
            ? .success(())
            : .failure(Self.posixError(code: errno))
        try close(directoryDescriptor, after: result)
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

    private static func isRegularFileWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFREG
    }

    private static func pathExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
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
