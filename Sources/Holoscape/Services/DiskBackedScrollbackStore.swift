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

    private enum ExistingLockAcquisition<Value> {
        case completed(Value)
        case opened(descriptor: Int32, directoryMarker: Data?)
    }

    private let registryLock = NSLock()
    private var locksByPath: [String: WeakLockBox] = [:]
    private static let ownerXattr = "com.holoscape.scrollback.lock-owner"
    private static let legacyFormatMarkerName = ".holoscape-scrollback-format-v1"
    private static let legacyFormatMarkerContents = Data("HoloScapeScrollbackDirectoryV1\n".utf8)
    private static let currentFormatMarkerName = ".holoscape-scrollback-format-v2"
    private let directoryMetadata: @Sendable (Int32) throws -> stat
    private let descriptorSync: @Sendable (Int32) -> Int32
    private let descriptorClose: @Sendable (Int32) -> Int32

    struct LockError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    init(
        directoryMetadata: @escaping @Sendable (Int32) throws -> stat = { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                let code = errno
                throw LockError(
                    message: "fstat failed for directory descriptor: \(String(cString: strerror(code))) (errno \(code))"
                )
            }
            return status
        },
        descriptorSync: @escaping @Sendable (Int32) -> Int32 = { fsync($0) },
        descriptorClose: @escaping @Sendable (Int32) -> Int32 = { Darwin.close($0) }
    ) {
        self.directoryMetadata = directoryMetadata
        self.descriptorSync = descriptorSync
        self.descriptorClose = descriptorClose
    }

    func withLock<T>(for fileURL: URL, _ operation: () throws -> T) throws -> T {
        let standardizedURL = fileURL.standardizedFileURL
        let canonicalDirectory = standardizedURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalURL = canonicalDirectory.appendingPathComponent(standardizedURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: canonicalDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw LockError(message: "createDirectory failed for \(canonicalDirectory.path): \(error)")
        }
        let directoryDescriptor = Darwin.open(
            canonicalDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw LockError(message: Self.posixFailure("open", path: canonicalDirectory.path, code: errno))
        }
        let directoryStatus: stat
        do {
            directoryStatus = try directoryMetadata(directoryDescriptor)
        } catch {
            if descriptorClose(directoryDescriptor) != 0 {
                let closeFailure = Self.posixFailure("close", path: canonicalDirectory.path, code: errno)
                throw LockError(message: "\(error); cleanup also failed: \(closeFailure)")
            }
            throw error
        }
        let result = Result {
            try withLock(
                directoryDescriptor: directoryDescriptor,
                directoryStatus: directoryStatus,
                fileName: canonicalURL.lastPathComponent,
                displayPath: canonicalURL.path,
                operation
            )
        }
        if descriptorClose(directoryDescriptor) != 0 {
            let closeFailure = Self.posixFailure("close", path: canonicalDirectory.path, code: errno)
            if case .failure(let error) = result {
                throw LockError(message: "\(error); cleanup also failed: \(closeFailure)")
            }
            throw LockError(message: closeFailure)
        }
        return try result.get()
    }

    func withLock<T>(
        directoryDescriptor: Int32,
        directoryStatus: stat,
        fileName: String,
        displayPath: String,
        legacyIdentityValidator: (String, stat) throws -> Bool = { _, _ in false },
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
            let directoryPath = (displayPath as NSString).deletingLastPathComponent
            let directoryMarkerName = Self.directoryMarkerXattr(lockName: lockName)
            var directoryMarker: Data?
            let descriptor = try Self.withDirectoryCreationLock(
                directoryDescriptor,
                displayPath: directoryPath
            ) {
                directoryMarker = try Self.getXattr(
                    descriptor: directoryDescriptor,
                    name: directoryMarkerName,
                    allowMissing: true,
                    displayPath: directoryPath
                )
                var opened = Darwin.openat(
                    directoryDescriptor,
                    lockName,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
                if opened >= 0 { return opened }
                guard errno == ENOENT else {
                    throw LockError(message: Self.posixFailure("openat", path: lockPath, code: errno))
                }
                guard directoryMarker == nil else {
                    throw LockError(message: "missing authoritative lock file at \(lockPath)")
                }

                var token = Data()
                let temporaryName = ".\(lockName).staging"
                var stagingWasCreated = true
                opened = Darwin.openat(
                    directoryDescriptor,
                    temporaryName,
                    O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                    S_IRUSR | S_IWUSR
                )
                if opened < 0, errno == EEXIST {
                    stagingWasCreated = false
                    opened = Darwin.openat(
                        directoryDescriptor,
                        temporaryName,
                        O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    )
                }
                guard opened >= 0 else {
                    throw LockError(message: Self.posixFailure("openat", path: lockPath, code: errno))
                }
                do {
                    var stagingStatus = stat()
                    guard fstat(opened, &stagingStatus) == 0,
                          stagingStatus.st_mode & S_IFMT == S_IFREG else {
                        throw LockError(message: Self.posixFailure("fstat", path: lockPath, code: errno == 0 ? EINVAL : errno))
                    }
                    let prefix = Self.ownerMarkerPrefix(
                        lockName: lockName,
                        directoryStatus: directoryStatus,
                        fileStatus: stagingStatus
                    )
                    if stagingWasCreated {
                        token = Self.ownerMarker(
                            lockName: lockName,
                            directoryStatus: directoryStatus,
                            fileStatus: stagingStatus,
                            nonce: UUID().uuidString
                        )
                        try Self.setXattr(
                            descriptor: opened,
                            name: Self.ownerXattr,
                            value: token,
                            flags: XATTR_CREATE,
                            displayPath: lockPath
                        )
                    } else {
                        let existing = try Self.getXattr(
                            descriptor: opened,
                            name: Self.ownerXattr,
                            allowMissing: true,
                            displayPath: lockPath
                        )
                        guard let existing,
                              existing.starts(with: prefix),
                              existing.count > prefix.count else {
                            throw LockError(message: "unowned lock staging file at \(lockPath)")
                        }
                        token = existing
                    }
                    guard descriptorSync(opened) == 0 else {
                        throw LockError(message: Self.posixFailure("fsync", path: lockPath, code: errno))
                    }
                    try Self.requirePathIdentity(
                        directoryDescriptor: directoryDescriptor,
                        name: temporaryName,
                        descriptor: opened,
                        displayPath: lockPath
                    )
                    guard renameatx_np(
                        directoryDescriptor,
                        temporaryName,
                        directoryDescriptor,
                        lockName,
                        UInt32(RENAME_EXCL)
                    ) == 0 else {
                        throw LockError(message: Self.posixFailure("renameatx_np", path: lockPath, code: errno))
                    }
                    guard descriptorSync(directoryDescriptor) == 0 else {
                        throw LockError(message: Self.posixFailure("fsync", path: directoryPath, code: errno))
                    }
                    try Self.establishDirectoryMarker(
                        descriptor: directoryDescriptor,
                        name: directoryMarkerName,
                        token: token,
                        displayPath: directoryPath
                    )
                    directoryMarker = token
                    return opened
                } catch {
                    if Darwin.close(opened) != 0 {
                        throw LockError(message: "\(error); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                    }
                    throw error
                }
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let lockFailure = Self.posixFailure("flock(LOCK_EX)", path: lockPath, code: errno)
                if Darwin.close(descriptor) != 0 {
                    throw LockError(message: "\(lockFailure); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                }
                throw LockError(message: lockFailure)
            }

            let result: Result<T, Error> = Result {
                let fileMarker = try Self.validateAuthorityDescriptor(
                    descriptor,
                    lockName: lockName,
                    directoryStatus: directoryStatus,
                    allowLegacyV1: false,
                    displayPath: lockPath,
                    currentPathStatus: {
                    var pathStatus = stat()
                    guard fstatat(directoryDescriptor, lockName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw LockError(message: Self.posixFailure("fstatat", path: lockPath, code: errno))
                    }
                    return pathStatus
                    },
                    legacyIdentityValidator: { try legacyIdentityValidator(lockName, $0) }
                )
                try Self.establishDirectoryMarker(
                    descriptor: directoryDescriptor,
                    name: directoryMarkerName,
                    token: fileMarker,
                    displayPath: directoryPath
                )
                return try operation()
            }

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

    func withExistingLock<T>(
        directoryDescriptor: Int32,
        directoryStatus: stat,
        fileName: String,
        displayPath: String,
        legacyIdentityValidator: (String, stat) throws -> Bool = { _, _ in false },
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
            let directoryPath = (displayPath as NSString).deletingLastPathComponent
            let acquisition = try Self.withDirectoryReadLock(
                directoryDescriptor,
                displayPath: directoryPath
            ) {
                let currentMarker = try Self.getXattr(
                    descriptor: directoryDescriptor,
                    name: Self.directoryMarkerXattr(lockName: lockName),
                    allowMissing: true,
                    displayPath: directoryPath
                )
                let opened = Darwin.openat(
                    directoryDescriptor,
                    lockName,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
                if opened < 0, errno == ENOENT, currentMarker == nil {
                    return ExistingLockAcquisition.completed(try operation())
                }
                guard opened >= 0 else {
                    if errno == ENOENT {
                        throw LockError(message: "missing authoritative lock file at \(lockPath)")
                    }
                    throw LockError(message: Self.posixFailure("openat", path: lockPath, code: errno))
                }
                return ExistingLockAcquisition.opened(
                    descriptor: opened,
                    directoryMarker: currentMarker
                )
            }
            let descriptor: Int32
            let directoryMarker: Data?
            switch acquisition {
            case .completed(let value):
                return value
            case .opened(let opened, let currentMarker):
                descriptor = opened
                directoryMarker = currentMarker
            }

            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0,
                  descriptorStatus.st_mode & S_IFMT == S_IFREG else {
                let code = errno == 0 ? EISDIR : errno
                let openFailure = Self.posixFailure("openat", path: lockPath, code: code)
                if descriptorClose(descriptor) != 0 {
                    throw LockError(message: "\(openFailure); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                }
                throw LockError(message: openFailure)
            }
            guard flock(descriptor, LOCK_SH) == 0 else {
                let lockFailure = Self.posixFailure("flock(LOCK_SH)", path: lockPath, code: errno)
                if descriptorClose(descriptor) != 0 {
                    throw LockError(message: "\(lockFailure); cleanup also failed: \(Self.posixFailure("close", path: lockPath, code: errno))")
                }
                throw LockError(message: lockFailure)
            }

            let result: Result<T, Error> = Result {
                let fileMarker = try Self.validateReadOnlyAuthorityDescriptor(
                    descriptor,
                    descriptorStatus: descriptorStatus,
                    lockName: lockName,
                    directoryStatus: directoryStatus,
                    displayPath: lockPath,
                    currentPathStatus: {
                    var pathStatus = stat()
                    guard fstatat(directoryDescriptor, lockName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw LockError(message: Self.posixFailure("fstatat", path: lockPath, code: errno))
                    }
                    return pathStatus
                    },
                    legacyIdentityValidator: { try legacyIdentityValidator(lockName, $0) }
                )
                guard directoryMarker == fileMarker else {
                    throw LockError(message: "foreign lock authority at \(directoryPath)")
                }
                return try operation()
            }

            var cleanupFailures: [String] = []
            if flock(descriptor, LOCK_UN) != 0 {
                cleanupFailures.append(Self.posixFailure("flock(LOCK_UN)", path: lockPath, code: errno))
            }
            if descriptorClose(descriptor) != 0 {
                cleanupFailures.append(Self.posixFailure("close", path: lockPath, code: errno))
            }
            if !cleanupFailures.isEmpty {
                let prefix = result.failure.map { "operation failed: \($0); " } ?? ""
                throw LockError(message: prefix + cleanupFailures.joined(separator: "; "))
            }
            return try result.get()
        }
    }

    func adoptLegacyLock(
        directoryDescriptor: Int32,
        lockName: String,
        displayPath: String,
        allowLegacyV1: Bool,
        allowUnowned: Bool
    ) throws {
        let descriptor = Darwin.openat(
            directoryDescriptor,
            lockName,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw LockError(message: Self.posixFailure("openat", path: displayPath, code: errno))
        }
        let result: Result<Void, Error> = Result {
            var directoryStatus = stat()
            var fileStatus = stat()
            guard fstat(directoryDescriptor, &directoryStatus) == 0,
                  fstat(descriptor, &fileStatus) == 0,
                  fileStatus.st_mode & S_IFMT == S_IFREG else {
                throw LockError(message: Self.posixFailure("fstat", path: displayPath, code: errno == 0 ? EINVAL : errno))
            }
            var pathStatus = stat()
            guard fstatat(directoryDescriptor, lockName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  pathStatus.st_dev == fileStatus.st_dev,
                  pathStatus.st_ino == fileStatus.st_ino else {
                throw LockError(message: "lock pathname identity changed at \(displayPath)")
            }
            let prefix = Self.ownerMarkerPrefix(
                lockName: lockName,
                directoryStatus: directoryStatus,
                fileStatus: fileStatus
            )
            let existing = try Self.getXattr(
                descriptor: descriptor,
                name: Self.ownerXattr,
                allowMissing: true,
                displayPath: displayPath
            )
            let token: Data
            if let existing, existing.starts(with: prefix), existing.count > prefix.count {
                token = existing
                guard fsync(descriptor) == 0 else {
                    throw LockError(message: Self.posixFailure("fsync", path: displayPath, code: errno))
                }
            } else if let existing,
                      allowLegacyV1,
                      existing == Self.legacyOwnerMarker(lockName: lockName) {
                token = Self.ownerMarker(
                    lockName: lockName,
                    directoryStatus: directoryStatus,
                    fileStatus: fileStatus,
                    nonce: UUID().uuidString
                )
                try Self.setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: token,
                    flags: XATTR_REPLACE,
                    displayPath: displayPath
                )
                guard fsync(descriptor) == 0 else {
                    throw LockError(message: Self.posixFailure("fsync", path: displayPath, code: errno))
                }
            } else if existing == nil, allowUnowned {
                token = Self.ownerMarker(
                    lockName: lockName,
                    directoryStatus: directoryStatus,
                    fileStatus: fileStatus,
                    nonce: UUID().uuidString
                )
                try Self.setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: token,
                    flags: XATTR_CREATE,
                    displayPath: displayPath
                )
                guard fsync(descriptor) == 0 else {
                    throw LockError(message: Self.posixFailure("fsync", path: displayPath, code: errno))
                }
            } else if existing == nil {
                return
            } else {
                throw LockError(message: "unowned lock file at \(displayPath)")
            }
            let directoryPath = (displayPath as NSString).deletingLastPathComponent
            let markerName = Self.directoryMarkerXattr(lockName: lockName)
            try Self.establishDirectoryMarker(
                descriptor: directoryDescriptor,
                name: markerName,
                token: token,
                displayPath: directoryPath
            )
        }
        if Darwin.close(descriptor) != 0 {
            let closeFailure = Self.posixFailure("close", path: displayPath, code: errno)
            if case .failure(let error) = result {
                throw LockError(message: "\(error); cleanup also failed: \(closeFailure)")
            }
            throw LockError(message: closeFailure)
        }
        return try result.get()
    }

    private static func ownerMarkerPrefix(
        lockName: String,
        directoryStatus: stat,
        fileStatus: stat
    ) -> Data {
        Data(
            "holoscape-scrollback-lock-v4:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(lockName):\(fileStatus.st_dev):\(fileStatus.st_ino):".utf8
        )
    }

    private static func legacyV3OwnerMarkerPrefix(
        lockName: String,
        directoryStatus: stat
    ) -> Data {
        Data(
            "holoscape-scrollback-lock-v3:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(lockName):".utf8
        )
    }

    private static func ownerMarker(
        lockName: String,
        directoryStatus: stat,
        fileStatus: stat,
        nonce: String
    ) -> Data {
        var marker = ownerMarkerPrefix(
            lockName: lockName,
            directoryStatus: directoryStatus,
            fileStatus: fileStatus
        )
        marker.append(Data(nonce.utf8))
        return marker
    }

    private static func directoryMarkerXattr(lockName: String) -> String {
        let digest = SHA256.hash(data: Data(lockName.utf8))
        return "com.holoscape.scrollback.lock-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func legacyOwnerMarker(lockName: String) -> Data {
        Data("holoscape-scrollback-lock-v1:\(lockName)".utf8)
    }

    private static func validateAuthorityDescriptor(
        _ descriptor: Int32,
        lockName: String,
        directoryStatus: stat,
        allowLegacyV1: Bool,
        displayPath: String,
        currentPathStatus: () throws -> stat,
        legacyIdentityValidator: (stat) throws -> Bool
    ) throws -> Data {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG else {
            let code = errno == 0 ? EINVAL : errno
            throw LockError(message: Self.posixFailure("fstat", path: displayPath, code: code))
        }
        let expectedPrefix = ownerMarkerPrefix(
            lockName: lockName,
            directoryStatus: directoryStatus,
            fileStatus: descriptorStatus
        )
        let existing = try getXattr(
            descriptor: descriptor,
            name: ownerXattr,
            allowMissing: true,
            displayPath: displayPath
        )
        let marker: Data
        if let existing, existing.starts(with: expectedPrefix), existing.count > expectedPrefix.count {
            marker = existing
            guard fsync(descriptor) == 0 else {
                throw LockError(message: Self.posixFailure("fsync", path: displayPath, code: errno))
            }
        } else if let existing,
                  existing.starts(with: legacyV3OwnerMarkerPrefix(
                    lockName: lockName,
                    directoryStatus: directoryStatus
                  )),
                  try legacyIdentityValidator(descriptorStatus) {
            marker = existing
        } else if let existing,
                  allowLegacyV1,
                  existing == legacyOwnerMarker(lockName: lockName) {
            marker = ownerMarker(
                lockName: lockName,
                directoryStatus: directoryStatus,
                fileStatus: descriptorStatus,
                nonce: UUID().uuidString
            )
            try setXattr(
                descriptor: descriptor,
                name: ownerXattr,
                value: marker,
                flags: XATTR_REPLACE,
                displayPath: displayPath
            )
            guard fsync(descriptor) == 0 else {
                throw LockError(message: Self.posixFailure("fsync", path: displayPath, code: errno))
            }
        } else {
            throw LockError(message: "unowned lock file at \(displayPath)")
        }
        let pathStatus = try currentPathStatus()
        guard pathStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino else {
            throw LockError(message: "lock pathname identity changed at \(displayPath)")
        }
        return marker
    }

    private static func validateReadOnlyAuthorityDescriptor(
        _ descriptor: Int32,
        descriptorStatus: stat,
        lockName: String,
        directoryStatus: stat,
        displayPath: String,
        currentPathStatus: () throws -> stat,
        legacyIdentityValidator: (stat) throws -> Bool
    ) throws -> Data {
        let expectedPrefix = ownerMarkerPrefix(
            lockName: lockName,
            directoryStatus: directoryStatus,
            fileStatus: descriptorStatus
        )
        guard let marker = try getXattr(
            descriptor: descriptor,
            name: ownerXattr,
            allowMissing: true,
            displayPath: displayPath
        ) else {
            throw LockError(message: "unowned lock file at \(displayPath)")
        }
        let isCurrent = marker.starts(with: expectedPrefix) && marker.count > expectedPrefix.count
        let isPreAnchor = try marker.starts(with: legacyV3OwnerMarkerPrefix(
            lockName: lockName,
            directoryStatus: directoryStatus
        )) && legacyIdentityValidator(descriptorStatus)
        guard isCurrent || isPreAnchor else {
            throw LockError(message: "unowned lock file at \(displayPath)")
        }
        let pathStatus = try currentPathStatus()
        guard pathStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_dev == descriptorStatus.st_dev,
              pathStatus.st_ino == descriptorStatus.st_ino else {
            throw LockError(message: "lock pathname identity changed at \(displayPath)")
        }
        return marker
    }

    private static func withDirectoryCreationLock<T>(
        _ descriptor: Int32,
        displayPath: String,
        _ operation: () throws -> T
    ) throws -> T {
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LockError(message: posixFailure("flock(LOCK_EX)", path: displayPath, code: errno))
        }
        let result = Result { try operation() }
        if flock(descriptor, LOCK_UN) != 0 {
            let unlockFailure = posixFailure("flock(LOCK_UN)", path: displayPath, code: errno)
            if case .failure(let error) = result {
                throw LockError(message: "\(error); cleanup also failed: \(unlockFailure)")
            }
            throw LockError(message: unlockFailure)
        }
        return try result.get()
    }

    private static func withDirectoryReadLock<T>(
        _ descriptor: Int32,
        displayPath: String,
        _ operation: () throws -> T
    ) throws -> T {
        guard flock(descriptor, LOCK_SH) == 0 else {
            throw LockError(message: posixFailure("flock(LOCK_SH)", path: displayPath, code: errno))
        }
        let result = Result { try operation() }
        if flock(descriptor, LOCK_UN) != 0 {
            let unlockFailure = posixFailure("flock(LOCK_UN)", path: displayPath, code: errno)
            if case .failure(let error) = result {
                throw LockError(message: "\(error); cleanup also failed: \(unlockFailure)")
            }
            throw LockError(message: unlockFailure)
        }
        return try result.get()
    }

    private static func establishDirectoryMarker(
        descriptor: Int32,
        name: String,
        token: Data,
        displayPath: String
    ) throws {
        if let existing = try getXattr(
            descriptor: descriptor,
            name: name,
            allowMissing: true,
            displayPath: displayPath
        ) {
            guard existing == token else {
                throw LockError(message: "foreign lock authority at \(displayPath)")
            }
            guard fsync(descriptor) == 0 else {
                throw LockError(message: posixFailure("fsync", path: displayPath, code: errno))
            }
            return
        }
        try setXattr(
            descriptor: descriptor,
            name: name,
            value: token,
            flags: XATTR_CREATE,
            displayPath: displayPath
        )
        guard fsync(descriptor) == 0 else {
            throw LockError(message: posixFailure("fsync", path: displayPath, code: errno))
        }
    }

    private static func isLegacyFormatDirectory(
        _ directoryDescriptor: Int32,
        displayPath: String
    ) throws -> Bool {
        var currentStatus = stat()
        if fstatat(
            directoryDescriptor,
            currentFormatMarkerName,
            &currentStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw LockError(message: posixFailure("fstatat", path: displayPath, code: errno))
        }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            legacyFormatMarkerName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw LockError(message: posixFailure("openat", path: displayPath, code: errno))
        }
        let result: Result<Bool, Error> = Result {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else {
                throw LockError(message: posixFailure("fstat", path: displayPath, code: errno == 0 ? EINVAL : errno))
            }
            let capacity = legacyFormatMarkerContents.count + 1
            var data = Data(count: capacity)
            let count = data.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress, capacity, 0)
            }
            guard count == legacyFormatMarkerContents.count else { return false }
            data.removeLast()
            return data == legacyFormatMarkerContents
        }
        let closeResult = Darwin.close(descriptor)
        if closeResult != 0 {
            let closeFailure = posixFailure("close", path: displayPath, code: errno)
            if case .failure(let error) = result {
                throw LockError(message: "\(error); cleanup also failed: \(closeFailure)")
            }
            throw LockError(message: closeFailure)
        }
        return try result.get()
    }

    private static func getXattr(
        descriptor: Int32,
        name: String,
        allowMissing: Bool,
        displayPath: String
    ) throws -> Data? {
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard size >= 0 else {
            let code = errno
            if allowMissing, code == ENOATTR { return nil }
            throw LockError(message: posixFailure("fgetxattr", path: displayPath, code: code))
        }
        guard size <= 4_096 else { throw LockError(message: "oversized lock marker at \(displayPath)") }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { bytes in
            fgetxattr(descriptor, name, bytes.baseAddress, size, 0, 0)
        }
        guard count == size else {
            let code = count < 0 ? errno : EIO
            throw LockError(message: posixFailure("fgetxattr", path: displayPath, code: code))
        }
        return value
    }

    private static func setXattr(
        descriptor: Int32,
        name: String,
        value: Data,
        flags: Int32,
        displayPath: String
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            fsetxattr(descriptor, name, bytes.baseAddress, value.count, 0, flags)
        }
        guard result == 0 else {
            throw LockError(message: posixFailure("fsetxattr", path: displayPath, code: errno))
        }
    }


    private static func requirePathIdentity(
        directoryDescriptor: Int32,
        name: String,
        descriptor: Int32,
        displayPath: String
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw LockError(message: "lock staging pathname identity changed at \(displayPath)")
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
    enum LegacyDirectoryHandoff: Equatable, Sendable {
        case denied
        case trustedDeployedStore
    }

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

        private var markerLabel: String {
            switch self {
            case .main: return "main"
            case .recovery: return "recovery"
            }
        }

        func markerPrefix(fileName: String, directoryStatus: stat, fileStatus: stat) -> Data {
            Data(
                "holoscape-scrollback-\(markerLabel)-v3:\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(fileName):\(fileStatus.st_dev):\(fileStatus.st_ino):".utf8
            )
        }

        func marker(fileName: String, directoryStatus: stat, fileStatus: stat, nonce: String) -> Data {
            var value = markerPrefix(
                fileName: fileName,
                directoryStatus: directoryStatus,
                fileStatus: fileStatus
            )
            value.append(Data(nonce.utf8))
            return value
        }

        func deterministicV2Marker(fileName: String, directoryStatus: stat) -> Data {
            let identity = "\(directoryStatus.st_dev):\(directoryStatus.st_ino):\(fileName)"
            switch self {
            case .main: return Data("holoscape-scrollback-main-v2:\(identity)".utf8)
            case .recovery: return Data("holoscape-scrollback-recovery-v2:\(identity)".utf8)
            }
        }

        func legacyMarker(fileName: String) -> Data {
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

    private enum ReadDecision<Value> {
        case result(Value)
        case repair
    }

    private enum DirectoryAccess {
        case readOnly
        case mutating
    }

    private enum LegacyRetirementProvenance: String, CaseIterable {
        case fresh
        case legacy
        case deployed
    }

    private enum LegacyMarkerState {
        case missing
        case version1
        case retired(LegacyRetirementProvenance)

        var isVersion1: Bool {
            if case .version1 = self { return true }
            return false
        }
    }

    private struct OpenedDescriptor {
        let descriptor: Int32
        let status: stat
    }

    private struct DirectoryAuthority {
        let descriptor: Int32
        let status: stat
    }

    private final class DirectoryIdentityAnchor: @unchecked Sendable {
        private let lock = NSLock()
        private var identity: (device: dev_t, inode: ino_t)?

        func validate(_ status: stat, path: String) throws {
            try lock.withLock {
                if let identity {
                    guard identity.device == status.st_dev, identity.inode == status.st_ino else {
                        throw StoreError.unsafeScrollbackDirectory(path)
                    }
                } else {
                    identity = (status.st_dev, status.st_ino)
                }
            }
        }
    }

    private final class DirectoryIdentityRegistry: @unchecked Sendable {
        static let shared = DirectoryIdentityRegistry()

        private let lock = NSLock()
        private var anchorsByConfiguredPath: [String: DirectoryIdentityAnchor] = [:]

        func anchor(for configuredPath: String) -> DirectoryIdentityAnchor {
            lock.withLock {
                if let existing = anchorsByConfiguredPath[configuredPath] { return existing }
                let created = DirectoryIdentityAnchor()
                anchorsByConfiguredPath[configuredPath] = created
                return created
            }
        }
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
    private static let legacyFormatMarkerName = ".holoscape-scrollback-format-v1"
    private static let legacyFormatMarkerContents = Data("HoloScapeScrollbackDirectoryV1\n".utf8)
    private static let formatMarkerName = ".holoscape-scrollback-format-v2"
    private static let formatMarkerContents = Data("HoloScapeScrollbackDirectoryV2\n".utf8)
    private static let formatAuthorityXattr = "com.holoscape.scrollback.format-owner"
    private static let migrationLockName = ".holoscape-scrollback-migration.lock"

    let directory: URL
    private let maxRetainedBytes: Int
    private let operationLocks = ScrollbackSessionOperationLocks.shared
    private let directoryIdentity: DirectoryIdentityAnchor
    private let beforeLeafMutation: @Sendable (URL) -> Void
    private let beforeDescriptorMutation: @Sendable (URL) -> Void
    private let afterDirectoryOpen: @Sendable (URL) -> Void
    private let transactionPhaseHook: @Sendable (TransactionPhase) throws -> Void
    private let descriptorSync: @Sendable (Int32) -> Int32
    private let directoryEntrySync: @Sendable (Int32) -> Int32
    private let descriptorClose: @Sendable (Int32) -> Int32
    private let listingMetadata: @Sendable (Int32) throws -> stat
    private let beforeDirectoryStreamOpen: @Sendable (Int32) -> Void
    private let directoryEntryRead: @Sendable (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?
    private let directoryStreamClose: @Sendable (UnsafeMutablePointer<DIR>) -> Int32
    private let beforeOwnedFilePublish: @Sendable (URL) throws -> Void
    private let beforeFormatMarkerPublish: @Sendable () throws -> Void
    private let beforeLegacyRetirementMarkerPublish: @Sendable () throws -> Void
    private let afterFormatMarkerOpen: @Sendable (URL) -> Void
    private let afterFormatMarkerValidationBeforePublish: @Sendable () throws -> Void
    private let directoryIdentityAuthorityDirectory: URL
    private let legacyDirectoryHandoff: LegacyDirectoryHandoff

    init(
        directory: URL,
        maxRetainedBytes: Int = ScrollbackPersistencePolicy.maxRetainedBytesPerSession,
        beforeLeafMutation: @escaping @Sendable (URL) -> Void = { _ in },
        beforeDescriptorMutation: @escaping @Sendable (URL) -> Void = { _ in },
        afterDirectoryOpen: @escaping @Sendable (URL) -> Void = { _ in },
        transactionPhaseHook: @escaping @Sendable (TransactionPhase) throws -> Void = { _ in },
        descriptorSync: @escaping @Sendable (Int32) -> Int32 = { fsync($0) },
        directoryEntrySync: @escaping @Sendable (Int32) -> Int32 = { fsync($0) },
        descriptorClose: @escaping @Sendable (Int32) -> Int32 = { Darwin.close($0) },
        listingMetadata: @escaping @Sendable (Int32) throws -> stat = { descriptor in
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return status
        },
        beforeDirectoryStreamOpen: @escaping @Sendable (Int32) -> Void = { _ in },
        directoryEntryRead: @escaping @Sendable (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) },
        directoryStreamClose: @escaping @Sendable (UnsafeMutablePointer<DIR>) -> Int32 = { closedir($0) },
        beforeOwnedFilePublish: @escaping @Sendable (URL) throws -> Void = { _ in },
        beforeFormatMarkerPublish: @escaping @Sendable () throws -> Void = {},
        beforeLegacyRetirementMarkerPublish: @escaping @Sendable () throws -> Void = {},
        afterFormatMarkerOpen: @escaping @Sendable (URL) -> Void = { _ in },
        afterFormatMarkerValidationBeforePublish: @escaping @Sendable () throws -> Void = {},
        directoryIdentityAuthorityDirectory: URL? = nil,
        legacyDirectoryHandoff: LegacyDirectoryHandoff? = nil
    ) {
        self.directory = directory
        self.maxRetainedBytes = maxRetainedBytes
        directoryIdentity = DirectoryIdentityRegistry.shared.anchor(
            for: directory.standardizedFileURL.path
        )
        self.beforeLeafMutation = beforeLeafMutation
        self.beforeDescriptorMutation = beforeDescriptorMutation
        self.afterDirectoryOpen = afterDirectoryOpen
        self.transactionPhaseHook = transactionPhaseHook
        self.descriptorSync = descriptorSync
        self.directoryEntrySync = directoryEntrySync
        self.descriptorClose = descriptorClose
        self.listingMetadata = listingMetadata
        self.beforeDirectoryStreamOpen = beforeDirectoryStreamOpen
        self.directoryEntryRead = directoryEntryRead
        self.directoryStreamClose = directoryStreamClose
        self.beforeOwnedFilePublish = beforeOwnedFilePublish
        self.beforeFormatMarkerPublish = beforeFormatMarkerPublish
        self.beforeLegacyRetirementMarkerPublish = beforeLegacyRetirementMarkerPublish
        self.afterFormatMarkerOpen = afterFormatMarkerOpen
        self.afterFormatMarkerValidationBeforePublish = afterFormatMarkerValidationBeforePublish
        self.directoryIdentityAuthorityDirectory = directoryIdentityAuthorityDirectory
            ?? Self.defaultDirectoryIdentityAuthorityDirectory()
        self.legacyDirectoryHandoff = legacyDirectoryHandoff
            ?? (directory.standardizedFileURL == ScrollbackPersistencePolicy.defaultDiskDirectory.standardizedFileURL
                ? .trustedDeployedStore
                : .denied)
    }

    func append(_ data: Data, for id: BrokerSessionID) throws {
        let url = try fileURL(for: id)
        try withDirectoryAuthority(createIfMissing: true, access: .mutating) { authority in
            try withSessionLock(authority, url: url) {
                let mainExists = try pathExists(authority, name: url.lastPathComponent)
                let hadMainAuthority = try hasMainAuthority(authority, fileName: url.lastPathComponent)
                if !mainExists {
                    try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                    if hadMainAuthority {
                        throw StoreError.unsafeScrollbackFile(url.path)
                    }
                    guard !data.isEmpty else { return }
                }
                let appended: Void? = try withOwnedDescriptor(
                    authority,
                    at: url,
                    flags: O_RDWR,
                    createIfMissing: !data.isEmpty && !mainExists,
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
                        let retained = try readSuffix(descriptor, count: retainedLimit)
                        try commitRewrite(
                            authority,
                            descriptor,
                            status: sourceStatus,
                            mainURL: url,
                            payload: retained
                        )
                    } else {
                        try sync(descriptor)
                    }
                    try requireIdentity(authority, at: url, matches: sourceStatus, kind: .main)
                }
                guard appended != nil else {
                    throw StoreError.unsafeScrollbackFile(url.path)
                }
            }
        }
    }

    func readTail(for id: BrokerSessionID, maxBytes: Int) throws -> Data {
        let url = try fileURL(for: id)
        guard let result = try withExistingDirectoryAuthority(access: .readOnly, { authority in
            let decision = try withExistingSessionLock(authority, url: url) {
                let inspected = try withOwnedDescriptor(
                    authority,
                    at: url,
                    flags: O_RDONLY,
                    createIfMissing: false,
                    kind: .main
                ) { descriptor, status -> ReadDecision<Data> in
                    let recovery = try observeRecovery(
                        authority,
                        at: recoveryURL(for: url),
                        mainStatus: status
                    )
                    if case .none = recovery,
                       status.st_size <= off_t(max(0, maxRetainedBytes)) {
                        return .result(cappedTail(try readAll(descriptor), requestedBytes: maxBytes))
                    }
                    return .repair
                }
                guard let inspected else {
                    try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                    return ReadDecision.result(Data())
                }
                return inspected
            }
            switch decision {
            case .result(let data):
                return data
            case .repair:
                try ensurePersistentDirectoryIdentity(authority)
                return try withSessionLock(authority, url: url) {
                    try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                        cappedTail(try readAll(descriptor), requestedBytes: maxBytes)
                    }
                }
            }
        }) else { return Data() }
        return result
    }

    /// Clears bytes through the validated descriptor and deliberately retains
    /// the empty, owned inode. Darwin has no identity-conditional unlink; not
    /// unlinking prevents a pathname rebound from deleting a foreign file.
    func remove(for id: BrokerSessionID) throws {
        _ = try clearAndReturnByteCount(for: id)
    }

    /// Returns the byte count observed by the same process-shared session lock
    /// that performs the clear, so maintenance UI never reports a stale count.
    func clearAndReturnByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        guard let clearedBytes = try withExistingDirectoryAuthority(access: .mutating, { authority in
            try withSessionLock(authority, url: url) {
                let removed: Int? = try withOwnedDescriptor(
                    authority,
                    at: url,
                    flags: O_RDWR,
                    createIfMissing: false,
                    kind: .main
                ) { descriptor, status in
                    try prepareMutation(authority, mainURL: url, mainStatus: status)
                    try repairIfNeeded(authority, descriptor, status: status, mainURL: url)
                    var currentStatus = stat()
                    guard fstat(descriptor, &currentStatus) == 0,
                          currentStatus.st_size >= 0,
                          currentStatus.st_size <= off_t(Int.max) else {
                        throw Self.posixError(code: errno == 0 ? EFBIG : errno)
                    }
                    try rewrite(descriptor, with: Data())
                    try sync(descriptor)
                    try requireIdentity(authority, at: url, matches: status, kind: .main)
                    return Int(currentStatus.st_size)
                }
                if let removed { return removed }
                try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                return 0
            }
        }) else { return 0 }
        return clearedBytes
    }

    func storedByteCount(for id: BrokerSessionID) throws -> Int {
        let url = try fileURL(for: id)
        guard let result = try withExistingDirectoryAuthority(access: .readOnly, { authority in
            let decision = try withExistingSessionLock(authority, url: url) {
                let inspected = try withOwnedDescriptor(
                    authority,
                    at: url,
                    flags: O_RDONLY,
                    createIfMissing: false,
                    kind: .main
                ) { _, status -> ReadDecision<Int> in
                    let recovery = try observeRecovery(
                        authority,
                        at: recoveryURL(for: url),
                        mainStatus: status
                    )
                    if case .none = recovery,
                       status.st_size <= off_t(max(0, maxRetainedBytes)) {
                        return .result(Int(status.st_size))
                    }
                    return .repair
                }
                guard let inspected else {
                    try rejectRecoveryWithoutMain(authority, at: recoveryURL(for: url))
                    return ReadDecision.result(0)
                }
                return inspected
            }
            switch decision {
            case .result(let count):
                return count
            case .repair:
                try ensurePersistentDirectoryIdentity(authority)
                return try withSessionLock(authority, url: url) {
                    try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                        var status = stat()
                        guard fstat(descriptor, &status) == 0 else {
                            throw Self.posixError(code: errno)
                        }
                        return Int(status.st_size)
                    }
                }
            }
        }) else { return 0 }
        return result
    }

    func listStoredTails() throws -> [StoredScrollbackTail] {
        guard let result = try withExistingDirectoryAuthority(access: .readOnly, { authority in
            let names = try directoryEntryNames(authority)
            var tails: [StoredScrollbackTail] = []
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard url.pathExtension == "scrollback" else { continue }
                let rawID = url.deletingPathExtension().lastPathComponent
                guard Self.isValidSessionID(rawID) else { continue }
                let metadata: stat?
                do {
                    let decision = try withExistingSessionLock(authority, url: url) {
                        let inspected = try withOwnedDescriptor(
                            authority,
                            at: url,
                            flags: O_RDONLY,
                            createIfMissing: false,
                            kind: .main
                        ) { descriptor, status -> ReadDecision<stat?> in
                            let recovery = try observeRecovery(
                                authority,
                                at: recoveryURL(for: url),
                                mainStatus: status
                            )
                            guard case .none = recovery,
                                  status.st_size <= off_t(max(0, maxRetainedBytes)) else {
                                return .repair
                            }
                            let currentStatus = try listingMetadata(descriptor)
                            guard currentStatus.st_mode & S_IFMT == S_IFREG else {
                                throw StoreError.unsafeScrollbackFile(url.path)
                            }
                            try requireIdentity(authority, at: url, matches: status, kind: .main)
                            return .result(currentStatus)
                        }
                        return inspected ?? .result(nil)
                    }
                    switch decision {
                    case .result(let currentStatus):
                        metadata = currentStatus
                    case .repair:
                        try ensurePersistentDirectoryIdentity(authority)
                        metadata = try withSessionLock(authority, url: url) {
                            try withRepairedWritableMain(authority, at: url) { descriptor, _ in
                                let currentStatus = try listingMetadata(descriptor)
                                guard currentStatus.st_mode & S_IFMT == S_IFREG else {
                                    throw StoreError.unsafeScrollbackFile(url.path)
                                }
                                return currentStatus
                            }
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
                    case .unsafeScrollbackDirectory:
                        throw error
                    case .invalidSessionID, .unsafeScrollbackFile:
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
        access: DirectoryAccess,
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
                    if mkdirat(descriptor, component, S_IRWXU) == 0 {
                        try syncDirectoryEntry(descriptor)
                    } else if errno != EEXIST {
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
        do {
            if try pathExists(authority, name: Self.formatMarkerName) {
                try prepareEstablishedFormatAuthority(
                    authority,
                    standardized: standardized,
                    access: access
                )
            } else {
                try withExclusiveDirectoryLock(authority) {
                    if try pathExists(authority, name: Self.formatMarkerName) {
                        try prepareEstablishedFormatAuthority(
                            authority,
                            standardized: standardized,
                            access: access
                        )
                        return
                    }
                    try classifyLegacyDirectory(authority)
                    try directoryIdentity.validate(directoryStatus, path: directory.path)
                    try synchronizeDirectoryComponents(at: standardized)
                    _ = try validatePersistentDirectoryIdentity(directoryStatus, allowCreation: true)
                    try migrateLegacyFilesIfNeeded(authority)
                }
            }
        } catch {
            return try close(descriptor, after: .failure(error))
        }
        afterDirectoryOpen(directory)
        let result = Result { try operation(authority) }
        return try close(descriptor, after: result)
    }

    private func prepareEstablishedFormatAuthority(
        _ authority: DirectoryAuthority,
        standardized: URL,
        access: DirectoryAccess
    ) throws {
        try directoryIdentity.validate(authority.status, path: directory.path)
        let hasPersistentIdentity = try validatePersistentDirectoryIdentity(
            authority.status,
            allowCreation: false
        )
        if !hasPersistentIdentity {
            guard legacyDirectoryHandoff == .trustedDeployedStore else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            if access == .mutating {
                try synchronizeDirectoryComponents(at: standardized)
                _ = try validatePersistentDirectoryIdentity(authority.status, allowCreation: true)
            }
        } else if access == .mutating {
            try synchronizeDirectoryComponents(at: standardized)
            _ = try validatePersistentDirectoryIdentity(authority.status, allowCreation: true)
        }
        guard try formatMarkerExists(authority) else {
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
    }

    private func withExistingDirectoryAuthority<T>(
        access: DirectoryAccess,
        _ operation: (DirectoryAuthority) throws -> T
    ) throws -> T? {
        try withDirectoryAuthority(createIfMissing: false, access: access, operation)
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

    @discardableResult
    private func validatePersistentDirectoryIdentity(
        _ status: stat,
        allowCreation: Bool
    ) throws -> Bool {
        let configuredPath = directory.standardizedFileURL.path
        let authorityPath = directoryIdentityAuthorityDirectory.standardizedFileURL.path
        var descriptor = Darwin.open(
            authorityPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT, allowCreation {
            let existed = FileManager.default.fileExists(atPath: authorityPath)
            try FileManager.default.createDirectory(
                at: directoryIdentityAuthorityDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !existed {
                guard let resolved = realpath(authorityPath, nil) else {
                    throw Self.posixError(code: errno)
                }
                defer { free(resolved) }
                try synchronizeDirectoryComponents(at: URL(
                    fileURLWithPath: String(cString: resolved),
                    isDirectory: true
                ))
            }
            descriptor = Darwin.open(
                authorityPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT, !allowCreation { return false }
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let lockError = Self.posixError(code: errno)
            return try close(descriptor, after: .failure(lockError))
        }

        let result: Result<Bool, Error> = Result {
            if allowCreation {
                try cleanupStaleTestDirectoryIdentities(
                    descriptor: descriptor,
                    preserving: configuredPath
                )
            }
            let name = Self.directoryIdentityXattr(configuredPath: configuredPath)
            let expected = Self.directoryIdentityValue(configuredPath: configuredPath, status: status)
            if let existing = try getXattr(
                descriptor: descriptor,
                name: name,
                allowMissing: true
            ) {
                guard existing == expected else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                // A failed publication fsync can leave a visible xattr that is
                // not durable. Never accept it without syncing again.
                try sync(descriptor)
                return true
            }

            guard allowCreation else { return false }
            do {
                try setXattr(
                    descriptor: descriptor,
                    name: name,
                    value: expected,
                    flags: XATTR_CREATE
                )
                try sync(descriptor)
            } catch let error as POSIXError where error.code == .EEXIST {
                guard try getXattr(
                    descriptor: descriptor,
                    name: name,
                    allowMissing: false
                ) == expected else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                try sync(descriptor)
            }
            return true
        }

        let unlocked: Result<Bool, Error>
        if flock(descriptor, LOCK_UN) == 0 {
            unlocked = result
        } else {
            let unlockError = Self.posixError(code: errno)
            switch result {
            case .success:
                unlocked = .failure(unlockError)
            case .failure(let operationError):
                unlocked = .failure(StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationError),
                    close: String(describing: unlockError)
                ))
            }
        }
        return try close(descriptor, after: unlocked)
    }

    private func ensurePersistentDirectoryIdentity(_ authority: DirectoryAuthority) throws {
        try synchronizeDirectoryComponents(at: try canonicalDirectoryURL())
        _ = try validatePersistentDirectoryIdentity(authority.status, allowCreation: true)
    }

    private func validatePersistentFileIdentity(
        name: String,
        status: stat,
        allowCreation: Bool
    ) throws -> Bool {
        let authorityPath = directoryIdentityAuthorityDirectory.standardizedFileURL.path
        let descriptor = Darwin.open(
            authorityPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0,
           errno == ENOENT,
           allowCreation,
           legacyDirectoryHandoff == .trustedDeployedStore {
            // A caller-authorized one-time handoff may inspect the exact
            // deployed v2 inodes without making read-only storage writable.
            // The first mutation publishes the external identity authority.
            return true
        }
        if descriptor < 0, errno == ENOENT, !allowCreation { return false }
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let lockError = Self.posixError(code: errno)
            return try close(descriptor, after: .failure(lockError))
        }
        let result: Result<Bool, Error> = Result {
            let xattr = Self.persistentFileIdentityXattr(
                configuredPath: directory.standardizedFileURL.path,
                name: name
            )
            let expected = Self.persistentFileIdentityValue(name: name, status: status)
            if let existing = try getXattr(
                descriptor: descriptor,
                name: xattr,
                allowMissing: true
            ) {
                guard existing == expected else {
                    throw StoreError.unsafeScrollbackFile(directory.appendingPathComponent(name).path)
                }
                try sync(descriptor)
                return true
            }
            guard allowCreation else { return false }
            try setXattr(
                descriptor: descriptor,
                name: xattr,
                value: expected,
                flags: XATTR_CREATE
            )
            try sync(descriptor)
            return true
        }
        let unlocked: Result<Bool, Error>
        if flock(descriptor, LOCK_UN) == 0 {
            unlocked = result
        } else {
            let unlockError = Self.posixError(code: errno)
            switch result {
            case .success:
                unlocked = .failure(unlockError)
            case .failure(let operationError):
                unlocked = .failure(StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationError),
                    close: String(describing: unlockError)
                ))
            }
        }
        return try close(descriptor, after: unlocked)
    }

    private func classifyLegacyDirectory(_ authority: DirectoryAuthority) throws {
        if case .missing = try legacyMarkerState(authority) {
            _ = try unmarkedRetirementProvenance(authority)
        }
    }

    private func withExclusiveDirectoryLock<T>(
        _ authority: DirectoryAuthority,
        _ operation: () throws -> T
    ) throws -> T {
        guard flock(authority.descriptor, LOCK_EX) == 0 else {
            throw Self.posixError(code: errno)
        }
        let result = Result { try operation() }
        guard flock(authority.descriptor, LOCK_UN) == 0 else {
            let unlockError = Self.posixError(code: errno)
            if case .failure(let operationError) = result {
                throw StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationError),
                    close: String(describing: unlockError)
                )
            }
            throw unlockError
        }
        return try result.get()
    }

    private func synchronizeDirectoryComponents(at url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw StoreError.unsafeScrollbackDirectory(url.path)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }

        do {
            for component in url.pathComponents.dropFirst() where component != "/" {
                let next = Darwin.openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else { throw Self.posixError(code: errno) }
                do {
                    try syncDirectoryEntry(descriptor)
                } catch {
                    return try close(next, after: .failure(error))
                }
                let previous = descriptor
                descriptor = next
                try close(previous, after: .success(()))
            }
        } catch {
            return try close(descriptor, after: .failure(error))
        }
        _ = try close(descriptor, after: .success(()))
    }

    private func syncDirectoryEntry(_ descriptor: Int32) throws {
        guard directoryEntrySync(descriptor) == 0 else {
            throw Self.posixError(code: errno)
        }
    }

    private static func defaultDirectoryIdentityAuthorityDirectory() -> URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("HoloscapeTests", isDirectory: true)
                .appendingPathComponent("ScrollbackDirectoryIdentityAuthority", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Holoscape", isDirectory: true)
            .appendingPathComponent("ScrollbackDirectoryIdentityAuthority", isDirectory: true)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains(where: { $0.contains(".xctest") })
    }

    private static func directoryIdentityValue(configuredPath: String, status: stat) -> Data {
        Data(
            "holoscape-scrollback-directory-v2:\(status.st_dev):\(status.st_ino)\n\(configuredPath)".utf8
        )
    }

    private func cleanupStaleTestDirectoryIdentities(
        descriptor: Int32,
        preserving configuredPath: String
    ) throws {
        guard Self.isRunningTests else { return }
        let size = flistxattr(descriptor, nil, 0, 0)
        guard size >= 0 else { throw Self.posixError(code: errno) }
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        let count = flistxattr(descriptor, &names, names.count, 0)
        guard count == size else {
            if count < 0 { throw Self.posixError(code: errno) }
            throw Self.posixError(code: EIO)
        }
        var removed = false
        var offset = 0
        while offset < names.count {
            let name = names.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            guard name.hasPrefix("com.holoscape.scrollback.directory-") else { continue }
            guard let value = try getXattr(descriptor: descriptor, name: name, allowMissing: true),
                  let newline = value.lastIndex(of: 0x0A) else { continue }
            let path = String(decoding: value[value.index(after: newline)...], as: UTF8.self)
            guard path != configuredPath, !FileManager.default.fileExists(atPath: path) else { continue }
            if fremovexattr(descriptor, name, 0) == 0 {
                removed = true
            } else if errno != ENOATTR {
                throw Self.posixError(code: errno)
            }
        }
        if removed { try sync(descriptor) }
    }

    private static func directoryIdentityXattr(configuredPath: String) -> String {
        let digest = SHA256.hash(data: Data(configuredPath.utf8))
        return "com.holoscape.scrollback.directory-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func persistentFileIdentityXattr(configuredPath: String, name: String) -> String {
        let digest = SHA256.hash(data: Data("\(configuredPath)\n\(name)".utf8))
        return "com.holoscape.scrollback.file-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func persistentFileIdentityValue(name: String, status: stat) -> Data {
        Data("holoscape-scrollback-file-v1:\(status.st_dev):\(status.st_ino):\(name)".utf8)
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
            legacyIdentityValidator: { name, status in
                try validatePersistentFileIdentity(
                    name: name,
                    status: status,
                    allowCreation: legacyDirectoryHandoff == .trustedDeployedStore
                )
            },
            operation
        )
    }

    private func withExistingSessionLock<T>(
        _ authority: DirectoryAuthority,
        url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try operationLocks.withExistingLock(
            directoryDescriptor: authority.descriptor,
            directoryStatus: authority.status,
            fileName: url.lastPathComponent,
            displayPath: url.path,
            legacyIdentityValidator: { name, status in
                try validatePersistentFileIdentity(
                    name: name,
                    status: status,
                    allowCreation: legacyDirectoryHandoff == .trustedDeployedStore
                )
            },
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
        beforeDirectoryStreamOpen(enumerationDescriptor)
        guard let stream = fdopendir(enumerationDescriptor) else {
            let code = errno
            let operationFailure = String(describing: Self.posixError(code: code))
            if descriptorClose(enumerationDescriptor) != 0 {
                let closeCode = errno
                throw StoreError.fileOperationAndCloseFailed(
                    operation: "fdopendir failed: \(operationFailure)",
                    close: "close failed for \(directory.path): \(String(cString: strerror(closeCode))) (errno \(closeCode))"
                )
            }
            throw Self.posixError(code: code)
        }
        var names: [String] = []
        errno = 0
        while let entry = directoryEntryRead(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        let readCode = errno
        let closeCode = directoryStreamClose(stream) == 0 ? 0 : errno
        if readCode != 0, closeCode != 0 {
            throw StoreError.fileOperationAndCloseFailed(
                operation: "readdir failed for \(directory.path): \(String(cString: strerror(readCode))) (errno \(readCode))",
                close: "closedir failed for \(directory.path): \(String(cString: strerror(closeCode))) (errno \(closeCode))"
            )
        }
        if readCode != 0 { throw Self.posixError(code: readCode) }
        if closeCode != 0 { throw Self.posixError(code: closeCode) }
        return names
    }

    private func migrateLegacyFilesIfNeeded(_ authority: DirectoryAuthority) throws {
        // Retire a valid v1 marker atomically, or claim only a genuinely empty
        // unmarked directory. The durable provenance prevents another process
        // from confusing a legacy migration with unsafe unmarked adoption.
        _ = try establishLegacyRetirementMarker(authority)
        let lockBase = String(Self.migrationLockName.dropLast(".lock".count))
        try operationLocks.withLock(
            directoryDescriptor: authority.descriptor,
            directoryStatus: authority.status,
            fileName: lockBase,
            displayPath: directory.appendingPathComponent(lockBase).path
        ) {
            let provenance = try requireLegacyRetirementMarker(authority)
            if try formatMarkerExists(authority) { return }
            for name in try directoryEntryNames(authority) {
                let url = directory.appendingPathComponent(name)
                if url.pathExtension == "lock" {
                    let dataURL = url.deletingPathExtension()
                    if dataURL.pathExtension == "scrollback",
                       Self.isValidSessionID(dataURL.deletingPathExtension().lastPathComponent) {
                        try operationLocks.adoptLegacyLock(
                            directoryDescriptor: authority.descriptor,
                            lockName: name,
                            displayPath: url.path,
                            allowLegacyV1: provenance == .legacy,
                            allowUnowned: provenance == .deployed
                        )
                    }
                    continue
                }

                let kind: FileKind
                let sessionID: String
                if url.pathExtension == "scrollback" {
                    kind = .main
                    sessionID = url.deletingPathExtension().lastPathComponent
                } else if url.pathExtension == "recovery" {
                    let mainURL = url.deletingPathExtension()
                    guard mainURL.pathExtension == "scrollback" else { continue }
                    kind = .recovery
                    sessionID = mainURL.deletingPathExtension().lastPathComponent
                } else {
                    continue
                }
                guard Self.isValidSessionID(sessionID) else { continue }
                try migrateLegacyOwnedFile(
                    authority,
                    name: name,
                    url: url,
                    kind: kind,
                    legacyFormatExists: provenance == .legacy,
                    allowUnowned: provenance == .deployed
                )
            }
            _ = try requireLegacyRetirementMarker(authority)
            try createFormatMarker(authority)
        }
    }

    private func migrateLegacyOwnedFile(
        _ authority: DirectoryAuthority,
        name: String,
        url: URL,
        kind: FileKind,
        legacyFormatExists: Bool,
        allowUnowned: Bool
    ) throws {
        let descriptor = Darwin.openat(
            authority.descriptor,
            name,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == EISDIR { return }
            throw Self.posixError(code: errno)
        }
        let result: Result<Void, Error> = Result {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
            guard status.st_mode & S_IFMT == S_IFREG else { return }
            let expected = kind.marker(
                fileName: name,
                directoryStatus: authority.status,
                fileStatus: status,
                nonce: UUID().uuidString
            )
            let existing = try getXattr(
                descriptor: descriptor,
                name: Self.ownerXattr,
                allowMissing: true
            )
            let currentPrefix = kind.markerPrefix(
                fileName: name,
                directoryStatus: authority.status,
                fileStatus: status
            )
            if let existing, existing.starts(with: currentPrefix), existing.count > currentPrefix.count {
                try sync(descriptor)
                try establishFileAuthority(authority, kind: kind, fileName: name, marker: existing)
                return
            }
            if legacyFormatExists, existing == kind.legacyMarker(fileName: name) {
                try setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: expected,
                    flags: XATTR_REPLACE
                )
                try sync(descriptor)
                try establishFileAuthority(authority, kind: kind, fileName: name, marker: expected)
                return
            }
            if existing == nil, allowUnowned {
                try setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: expected,
                    flags: XATTR_CREATE
                )
                try sync(descriptor)
                try establishFileAuthority(authority, kind: kind, fileName: name, marker: expected)
                return
            }
            if existing == nil { return }
            throw StoreError.unsafeScrollbackFile(url.path)
        }
        _ = try close(descriptor, after: result)
    }

    private func legacyRetirementMarkerContents(
        _ authority: DirectoryAuthority,
        provenance: LegacyRetirementProvenance
    ) -> Data {
        Data(
            "HoloScapeScrollbackDirectoryV1Retired:\(authority.status.st_dev):\(authority.status.st_ino):\(provenance.rawValue)\n".utf8
        )
    }

    private func legacyRetirementStagingOwner(
        _ authority: DirectoryAuthority,
        provenance: LegacyRetirementProvenance
    ) -> Data {
        Data(
            "holoscape-scrollback-format-v1-retirement:\(authority.status.st_dev):\(authority.status.st_ino):\(provenance.rawValue)".utf8
        )
    }

    private func requireLegacyRetirementMarker(
        _ authority: DirectoryAuthority
    ) throws -> LegacyRetirementProvenance {
        guard case .retired(let provenance) = try legacyMarkerState(authority) else {
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
        return provenance
    }

    private func establishLegacyRetirementMarker(
        _ authority: DirectoryAuthority
    ) throws -> LegacyRetirementProvenance {
        guard flock(authority.descriptor, LOCK_EX) == 0 else {
            throw Self.posixError(code: errno)
        }
        let result: Result<LegacyRetirementProvenance, Error> = Result {
            let state = try legacyMarkerState(authority)
            if case .retired(let provenance) = state { return provenance }

            let provenance: LegacyRetirementProvenance
            switch state {
            case .version1:
                provenance = .legacy
            case .missing:
                provenance = try unmarkedRetirementProvenance(authority)
            case .retired:
                preconditionFailure("handled above")
            }

            let temporaryName = "\(Self.legacyFormatMarkerName).staging"
            let expectedContents = legacyRetirementMarkerContents(
                authority,
                provenance: provenance
            )
            let expectedOwner = legacyRetirementStagingOwner(
                authority,
                provenance: provenance
            )
            var stagingWasCreated = true
            var descriptor = Darwin.openat(
                authority.descriptor,
                temporaryName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            if descriptor < 0, errno == EEXIST {
                stagingWasCreated = false
                descriptor = Darwin.openat(
                    authority.descriptor,
                    temporaryName,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
            guard descriptor >= 0 else {
                if errno == ELOOP || errno == EISDIR {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                throw Self.posixError(code: errno)
            }

            let initialization: Result<Void, Error> = Result {
                var status = stat()
                guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
                guard status.st_mode & S_IFMT == S_IFREG else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                if stagingWasCreated {
                    try setXattr(
                        descriptor: descriptor,
                        name: Self.ownerXattr,
                        value: expectedOwner,
                        flags: XATTR_CREATE
                    )
                } else {
                    guard try getXattr(
                        descriptor: descriptor,
                        name: Self.ownerXattr,
                        allowMissing: true
                    ) == expectedOwner else {
                        throw StoreError.unsafeScrollbackDirectory(directory.path)
                    }
                }
                try rewrite(descriptor, with: expectedContents)
                try sync(descriptor)
                try beforeLegacyRetirementMarkerPublish()
            }
            if case .failure(let error) = initialization {
                return try close(descriptor, after: .failure(error))
            }
            do {
                try requirePathIdentity(
                    authority,
                    name: temporaryName,
                    descriptor: descriptor,
                    failure: .unsafeScrollbackDirectory(directory.path)
                )
            } catch {
                return try close(descriptor, after: .failure(error))
            }

            let renameFlags = state.isVersion1 ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            guard renameatx_np(
                authority.descriptor,
                temporaryName,
                authority.descriptor,
                Self.legacyFormatMarkerName,
                renameFlags
            ) == 0 else {
                let code = errno
                do {
                    _ = try close(descriptor, after: .success(()))
                } catch {
                    throw StoreError.fileOperationAndCloseFailed(
                        operation: "renameatx_np failed for \(directory.path): \(String(cString: strerror(code))) (errno \(code))",
                        close: String(describing: error)
                    )
                }
                if code == EEXIST {
                    guard case .retired(let winner) = try legacyMarkerState(authority) else {
                        throw StoreError.unsafeScrollbackDirectory(directory.path)
                    }
                    return winner
                }
                throw Self.posixError(code: code)
            }
            do {
                try requirePathIdentity(
                    authority,
                    name: Self.legacyFormatMarkerName,
                    descriptor: descriptor,
                    failure: .unsafeScrollbackDirectory(directory.path)
                )
            } catch {
                return try close(descriptor, after: .failure(error))
            }
            _ = try close(descriptor, after: .success(()))
            // RENAME_SWAP leaves the displaced v1 marker at the staging name.
            // Preserve it: Darwin has no identity-conditional unlink, so cleanup
            // could otherwise delete a foreign pathname replacement after the
            // validation above.
            try sync(authority.descriptor)
            return provenance
        }
        if flock(authority.descriptor, LOCK_UN) != 0 {
            let unlockFailure = Self.posixError(code: errno)
            if case .failure(let error) = result {
                throw StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: error),
                    close: String(describing: unlockFailure)
                )
            }
            throw unlockFailure
        }
        return try result.get()
    }

    private func legacyMarkerState(_ authority: DirectoryAuthority) throws -> LegacyMarkerState {
        let descriptor = Darwin.openat(
            authority.descriptor,
            Self.legacyFormatMarkerName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return .missing }
            if errno == ELOOP { throw StoreError.unsafeScrollbackDirectory(directory.path) }
            throw Self.posixError(code: errno)
        }
        let result: Result<LegacyMarkerState, Error> = Result {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            let maximumSize = max(
                Self.legacyFormatMarkerContents.count,
                LegacyRetirementProvenance.allCases.map {
                    legacyRetirementMarkerContents(authority, provenance: $0).count
                }.max() ?? 0
            )
            guard status.st_size >= 0, status.st_size <= off_t(maximumSize) else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            let contents = try readAll(descriptor)
            try requirePathIdentity(
                authority,
                name: Self.legacyFormatMarkerName,
                descriptor: descriptor,
                failure: .unsafeScrollbackDirectory(directory.path)
            )
            if contents == Self.legacyFormatMarkerContents { return .version1 }
            for provenance in LegacyRetirementProvenance.allCases where
                contents == legacyRetirementMarkerContents(authority, provenance: provenance) {
                return .retired(provenance)
            }
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
        return try close(descriptor, after: result)
    }

    private func unmarkedRetirementProvenance(
        _ authority: DirectoryAuthority
    ) throws -> LegacyRetirementProvenance {
        let names = try directoryEntryNames(authority)
        guard !names.isEmpty else { return .fresh }
        let temporaryName = "\(Self.legacyFormatMarkerName).staging"
        if names != [temporaryName] {
            guard legacyDirectoryHandoff == .trustedDeployedStore,
                  try isDeployedUnmarkedStore(authority, names: names) else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            return .deployed
        }
        guard names == [temporaryName] else {
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
        let descriptor = Darwin.openat(
            authority.descriptor,
            temporaryName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw StoreError.unsafeScrollbackDirectory(directory.path) }
        let result: Result<LegacyRetirementProvenance, Error> = Result {
            try requirePathIdentity(
                authority,
                name: temporaryName,
                descriptor: descriptor,
                failure: .unsafeScrollbackDirectory(directory.path)
            )
            let contents = try readAll(descriptor)
            let owner = try getXattr(
                descriptor: descriptor,
                name: Self.ownerXattr,
                allowMissing: true
            )
            for provenance in LegacyRetirementProvenance.allCases where
                contents == legacyRetirementMarkerContents(authority, provenance: provenance)
                && owner == legacyRetirementStagingOwner(authority, provenance: provenance) {
                return provenance
            }
            throw StoreError.unsafeScrollbackDirectory(directory.path)
        }
        return try close(descriptor, after: result)
    }

    private func isDeployedUnmarkedStore(
        _ authority: DirectoryAuthority,
        names: [String]
    ) throws -> Bool {
        let visible = Set(names)
        let tails = names.filter { name in
            let url = URL(fileURLWithPath: name)
            return url.pathExtension == "scrollback"
                && Self.isValidSessionID(url.deletingPathExtension().lastPathComponent)
        }
        guard !tails.isEmpty, visible.count == tails.count * 2 else { return false }
        for tail in tails {
            let lock = tail + ".lock"
            guard visible.contains(lock) else { return false }
            for name in [tail, lock] {
                let descriptor = Darwin.openat(
                    authority.descriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
                guard descriptor >= 0 else { return false }
                let result: Result<Bool, Error> = Result {
                    var status = stat()
                    guard fstat(descriptor, &status) == 0,
                          status.st_mode & S_IFMT == S_IFREG,
                          try getXattr(
                            descriptor: descriptor,
                            name: name.hasSuffix(".lock")
                                ? "com.holoscape.scrollback.lock-owner"
                                : Self.ownerXattr,
                            allowMissing: true
                          ) == nil else { return false }
                    if name.hasSuffix(".lock"), status.st_size != 0 { return false }
                    try requirePathIdentity(
                        authority,
                        name: name,
                        descriptor: descriptor,
                        failure: .unsafeScrollbackDirectory(directory.path)
                    )
                    return true
                }
                guard try close(descriptor, after: result) else { return false }
            }
        }
        return true
    }

    private func formatMarkerExists(_ authority: DirectoryAuthority) throws -> Bool {
        try markerExists(
            authority,
            name: Self.formatMarkerName,
            contents: Self.formatMarkerContents
        )
    }

    private func markerExists(
        _ authority: DirectoryAuthority,
        name: String,
        contents: Data
    ) throws -> Bool {
        let descriptor = Darwin.openat(
            authority.descriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP { throw StoreError.unsafeScrollbackDirectory(directory.path) }
            throw Self.posixError(code: errno)
        }
        if name == Self.formatMarkerName {
            afterFormatMarkerOpen(directory.appendingPathComponent(name))
        }
        let result: Result<Bool, Error>
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
            guard status.st_mode & S_IFMT == S_IFREG,
                  status.st_size == off_t(contents.count),
                  try readAll(descriptor) == contents else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            if name == Self.formatMarkerName {
                guard let marker = try getXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    allowMissing: true
                ) else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
                let prefix = formatMarkerPrefix(authority, fileStatus: status)
                let isCurrent = try marker.starts(with: prefix)
                    && marker.count > prefix.count
                    && getXattr(
                        descriptor: authority.descriptor,
                        name: Self.formatAuthorityXattr,
                        allowMissing: true
                    ) == marker
                let isPreAnchor = try marker == deterministicV2FormatMarker(authority)
                    && validatePersistentFileIdentity(
                        name: name,
                        status: status,
                        allowCreation: legacyDirectoryHandoff == .trustedDeployedStore
                    )
                guard isCurrent || isPreAnchor else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
            }
            try requirePathIdentity(
                authority,
                name: name,
                descriptor: descriptor,
                failure: .unsafeScrollbackDirectory(directory.path)
            )
            result = .success(true)
        } catch { result = .failure(error) }
        return try close(descriptor, after: result)
    }

    private func createFormatMarker(_ authority: DirectoryAuthority) throws {
        let temporaryName = "\(Self.formatMarkerName).staging"
        var stagingWasCreated = true
        var descriptor = Darwin.openat(
            authority.descriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0, errno == EEXIST {
            stagingWasCreated = false
            descriptor = Darwin.openat(
                authority.descriptor,
                temporaryName,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { throw Self.posixError(code: errno) }
        let initialization: Result<Void, Error> = Result {
            var stagingStatus = stat()
            guard fstat(descriptor, &stagingStatus) == 0,
                  stagingStatus.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.unsafeScrollbackDirectory(directory.path)
            }
            let prefix = formatMarkerPrefix(authority, fileStatus: stagingStatus)
            if stagingWasCreated {
                try setXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    value: formatMarker(
                        authority,
                        fileStatus: stagingStatus,
                        nonce: UUID().uuidString
                    ),
                    flags: XATTR_CREATE
                )
            } else {
                guard let existing = try getXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    allowMissing: true
                ), existing.starts(with: prefix), existing.count > prefix.count else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
            }
            try rewrite(descriptor, with: Self.formatMarkerContents)
            try sync(descriptor)
            try beforeFormatMarkerPublish()
        }
        if case .failure(let error) = initialization {
            let failure: Result<Void, Error> = .failure(error)
            _ = try close(descriptor, after: failure)
            throw error
        }
        do {
            try requirePathIdentity(
                authority,
                name: temporaryName,
                descriptor: descriptor,
                failure: .unsafeScrollbackDirectory(directory.path)
            )
            try afterFormatMarkerValidationBeforePublish()
        } catch {
            return try close(descriptor, after: .failure(error))
        }

        guard renameatx_np(
            authority.descriptor,
            temporaryName,
            authority.descriptor,
            Self.formatMarkerName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            do {
                _ = try close(descriptor, after: .success(()))
            } catch {
                throw StoreError.fileOperationAndCloseFailed(
                    operation: "renameatx_np failed for \(directory.path): \(String(cString: strerror(code))) (errno \(code))",
                    close: String(describing: error)
                )
            }
            if code == EEXIST, try formatMarkerExists(authority) { return }
            throw Self.posixError(code: code)
        }
        do {
            try requirePathIdentity(
                authority,
                name: Self.formatMarkerName,
                descriptor: descriptor,
                failure: .unsafeScrollbackDirectory(directory.path)
            )
        } catch {
            return try close(descriptor, after: .failure(error))
        }
        _ = try close(descriptor, after: .success(()))
        try sync(authority.descriptor)
        let publishedDescriptor = Darwin.openat(
            authority.descriptor,
            Self.formatMarkerName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard publishedDescriptor >= 0 else { throw Self.posixError(code: errno) }
        let publication: Result<Void, Error> = Result {
            guard let marker = try getXattr(
                descriptor: publishedDescriptor,
                name: Self.ownerXattr,
                allowMissing: false
            ) else { throw StoreError.unsafeScrollbackDirectory(directory.path) }
            if let existing = try getXattr(
                descriptor: authority.descriptor,
                name: Self.formatAuthorityXattr,
                allowMissing: true
            ) {
                guard existing == marker else {
                    throw StoreError.unsafeScrollbackDirectory(directory.path)
                }
            } else {
                try setXattr(
                    descriptor: authority.descriptor,
                    name: Self.formatAuthorityXattr,
                    value: marker,
                    flags: XATTR_CREATE
                )
            }
            try sync(authority.descriptor)
        }
        _ = try close(publishedDescriptor, after: publication)
    }

    private func formatMarkerPrefix(_ authority: DirectoryAuthority, fileStatus: stat) -> Data {
        Data(
            "holoscape-scrollback-format-v3:\(authority.status.st_dev):\(authority.status.st_ino):\(fileStatus.st_dev):\(fileStatus.st_ino):".utf8
        )
    }

    private func formatMarker(
        _ authority: DirectoryAuthority,
        fileStatus: stat,
        nonce: String
    ) -> Data {
        var marker = formatMarkerPrefix(authority, fileStatus: fileStatus)
        marker.append(Data(nonce.utf8))
        return marker
    }

    private func deterministicV2FormatMarker(_ authority: DirectoryAuthority) -> Data {
        Data(
            "holoscape-scrollback-format-v2-staging:\(authority.status.st_dev):\(authority.status.st_ino)".utf8
        )
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
        var descriptor = Darwin.openat(
            authority.descriptor,
            url.lastPathComponent,
            flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        var created = false
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let temporaryName = ".\(url.lastPathComponent).staging"
            var stagingWasCreated = true
            descriptor = Darwin.openat(
                authority.descriptor,
                temporaryName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                S_IRUSR | S_IWUSR
            )
            if descriptor < 0, errno == EEXIST {
                stagingWasCreated = false
                descriptor = Darwin.openat(
                    authority.descriptor,
                    temporaryName,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
            guard descriptor >= 0 else { throw Self.posixError(code: errno) }
            let initialization: Result<Void, Error> = Result {
                var stagingStatus = stat()
                guard fstat(descriptor, &stagingStatus) == 0,
                      stagingStatus.st_mode & S_IFMT == S_IFREG else {
                    throw StoreError.unsafeScrollbackFile(
                        directory.appendingPathComponent(temporaryName).path
                    )
                }
                let prefix = kind.markerPrefix(
                    fileName: url.lastPathComponent,
                    directoryStatus: authority.status,
                    fileStatus: stagingStatus
                )
                if stagingWasCreated {
                    try setXattr(
                        descriptor: descriptor,
                        name: Self.ownerXattr,
                        value: kind.marker(
                            fileName: url.lastPathComponent,
                            directoryStatus: authority.status,
                            fileStatus: stagingStatus,
                            nonce: UUID().uuidString
                        ),
                        flags: XATTR_CREATE
                    )
                } else {
                    guard let existing = try getXattr(
                        descriptor: descriptor,
                        name: Self.ownerXattr,
                        allowMissing: true
                    ), existing.starts(with: prefix), existing.count > prefix.count else {
                        throw StoreError.unsafeScrollbackFile(
                            directory.appendingPathComponent(temporaryName).path
                        )
                    }
                }
                try rewrite(descriptor, with: Data())
                if kind == .recovery { try setRecoveryPhase(.idle, descriptor: descriptor) }
                try sync(descriptor)
                try beforeOwnedFilePublish(url)
                try requirePathIdentity(
                    authority,
                    name: temporaryName,
                    descriptor: descriptor,
                    failure: .unsafeScrollbackFile(
                        directory.appendingPathComponent(temporaryName).path
                    )
                )
            }
            if case .failure(let error) = initialization {
                return try close(descriptor, after: .failure(error))
            }

            guard renameatx_np(
                authority.descriptor,
                temporaryName,
                authority.descriptor,
                url.lastPathComponent,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                let code = errno
                do {
                    _ = try close(descriptor, after: .success(()))
                } catch {
                    throw StoreError.fileOperationAndCloseFailed(
                        operation: "renameatx_np failed for \(url.path): \(String(cString: strerror(code))) (errno \(code))",
                        close: String(describing: error)
                    )
                }
                if code == EEXIST {
                    descriptor = Darwin.openat(
                        authority.descriptor,
                        url.lastPathComponent,
                        flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    )
                } else {
                    throw Self.posixError(code: code)
                }
                guard descriptor >= 0 else { throw Self.posixError(code: errno) }
                created = false
                return try validateOpenedDescriptor(
                    descriptor,
                    authority: authority,
                    url: url,
                    kind: kind,
                    created: created
                )
            }
            created = true
            do {
                try sync(authority.descriptor)
                var publishedStatus = stat()
                guard fstat(descriptor, &publishedStatus) == 0 else {
                    throw Self.posixError(code: errno)
                }
                guard let marker = try getXattr(
                    descriptor: descriptor,
                    name: Self.ownerXattr,
                    allowMissing: false
                ) else {
                    throw StoreError.unsafeScrollbackFile(url.path)
                }
                try establishFileAuthority(
                    authority,
                    kind: kind,
                    fileName: url.lastPathComponent,
                    marker: marker
                )
            } catch {
                return try close(descriptor, after: .failure(error))
            }
        }
        guard descriptor >= 0 else {
            let code = errno
            if !createIfMissing, code == ENOENT { return nil }
            if code == ELOOP { throw StoreError.unsafeScrollbackFile(url.path) }
            throw Self.posixError(code: code)
        }
        return try validateOpenedDescriptor(
            descriptor,
            authority: authority,
            url: url,
            kind: kind,
            created: created
        )
    }

    private func validateOpenedDescriptor(
        _ descriptor: Int32,
        authority: DirectoryAuthority,
        url: URL,
        kind: FileKind,
        created: Bool
    ) throws -> OpenedDescriptor {
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw Self.posixError(code: errno) }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw StoreError.unsafeScrollbackFile(url.path)
            }
            try requireOwnership(
                descriptor: descriptor,
                status: status,
                authority: authority,
                path: url.path,
                kind: kind
            )
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
            try requireOwnership(
                descriptor: descriptor,
                status: currentStatus,
                authority: authority,
                path: url.path,
                kind: kind
            )
            result = .success(())
        } catch { result = .failure(error) }
        try close(descriptor, after: result)
    }

    private func requirePathIdentity(
        _ authority: DirectoryAuthority,
        name: String,
        descriptor: Int32,
        failure: @autoclosure () -> StoreError
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              fstatat(authority.descriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              Self.isSameFile(descriptorStatus, pathStatus) else {
            throw failure()
        }
    }

    private func hasMainAuthority(_ authority: DirectoryAuthority, fileName: String) throws -> Bool {
        guard let marker = try getXattr(
            descriptor: authority.descriptor,
            name: Self.fileAuthorityXattr(kind: .main, fileName: fileName),
            allowMissing: true
        ) else { return false }
        let currentPrefix = Data(
            "holoscape-scrollback-main-v3:\(authority.status.st_dev):\(authority.status.st_ino):\(fileName):".utf8
        )
        guard (marker.starts(with: currentPrefix) && marker.count > currentPrefix.count)
                || marker == FileKind.main.deterministicV2Marker(
                    fileName: fileName,
                    directoryStatus: authority.status
                ) else {
            throw StoreError.unsafeScrollbackFile(directory.appendingPathComponent(fileName).path)
        }
        return true
    }

    private func establishFileAuthority(
        _ authority: DirectoryAuthority,
        kind: FileKind,
        fileName: String,
        marker: Data
    ) throws {
        let name = Self.fileAuthorityXattr(kind: kind, fileName: fileName)
        if let existing = try getXattr(
            descriptor: authority.descriptor,
            name: name,
            allowMissing: true
        ) {
            guard existing == marker else {
                throw StoreError.unsafeScrollbackFile(directory.appendingPathComponent(fileName).path)
            }
            try sync(authority.descriptor)
            return
        }
        try setXattr(
            descriptor: authority.descriptor,
            name: name,
            value: marker,
            flags: XATTR_CREATE
        )
        try sync(authority.descriptor)
    }

    private static func fileAuthorityXattr(kind: FileKind, fileName: String) -> String {
        let label: String
        switch kind {
        case .main: label = "main"
        case .recovery: label = "recovery"
        }
        let digest = SHA256.hash(data: Data("\(label):\(fileName)".utf8))
        return "com.holoscape.scrollback.\(label)-\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private func requireOwnership(
        descriptor: Int32,
        status: stat,
        authority: DirectoryAuthority,
        path: String,
        kind: FileKind
    ) throws {
        let fileName = (path as NSString).lastPathComponent
        guard let marker = try getXattr(
            descriptor: descriptor,
            name: Self.ownerXattr,
            allowMissing: true
        ) else { throw StoreError.unsafeScrollbackFile(path) }
        let prefix = kind.markerPrefix(
            fileName: fileName,
            directoryStatus: authority.status,
            fileStatus: status
        )
        let isCurrent = try marker.starts(with: prefix)
            && marker.count > prefix.count
            && getXattr(
                descriptor: authority.descriptor,
                name: Self.fileAuthorityXattr(kind: kind, fileName: fileName),
                allowMissing: true
            ) == marker
        let isPreAnchor = try marker == kind.deterministicV2Marker(
            fileName: fileName,
            directoryStatus: authority.status
        ) && validatePersistentFileIdentity(
            name: fileName,
            status: status,
            allowCreation: legacyDirectoryHandoff == .trustedDeployedStore
        )
        guard isCurrent || isPreAnchor else {
            throw StoreError.unsafeScrollbackFile(path)
        }
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

    private func setXattr(
        descriptor: Int32,
        name: String,
        value: Data,
        flags: Int32 = 0
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            fsetxattr(descriptor, name, bytes.baseAddress, value.count, 0, flags)
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
        guard descriptorSync(descriptor) == 0 else { throw Self.posixError(code: errno) }
    }


    private func cleanupTemporaryName(
        _ authority: DirectoryAuthority,
        name: String
    ) throws {
        guard unlinkat(authority.descriptor, name, 0) == 0 || errno == ENOENT else {
            throw Self.posixError(code: errno)
        }
    }

    private func cleanupOpenTemporary(
        _ authority: DirectoryAuthority,
        name: String,
        descriptor: Int32,
        displayPath: String,
        after operationError: Error? = nil
    ) throws {
        var failures: [String] = []
        if unlinkat(authority.descriptor, name, 0) != 0, errno != ENOENT {
            failures.append("unlinkat failed for \(displayPath): \(String(cString: strerror(errno))) (errno \(errno))")
        }
        if descriptorClose(descriptor) != 0 {
            failures.append("close failed for \(displayPath): \(String(cString: strerror(errno))) (errno \(errno))")
        }
        if let operationError {
            guard failures.isEmpty else {
                throw StoreError.fileOperationAndCloseFailed(
                    operation: String(describing: operationError),
                    close: failures.joined(separator: "; ")
                )
            }
            throw operationError
        }
        guard failures.isEmpty else {
            throw StoreError.descriptorCloseFailed(failures.joined(separator: "; "))
        }
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
