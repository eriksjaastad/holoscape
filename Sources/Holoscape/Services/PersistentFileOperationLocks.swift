import Darwin
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

    private let registryLock = NSLock()
    private var locksByPath: [String: WeakLockBox] = [:]

    struct LockError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    func withLock<T>(for fileURL: URL, _ operation: () throws -> T) throws -> T {
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
            // cannot redirect flock outside the intended directory.
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

// Preserve the focused scrollback-test name while sharing this generic lock.
typealias ScrollbackSessionOperationLocks = PersistentFileOperationLocks
