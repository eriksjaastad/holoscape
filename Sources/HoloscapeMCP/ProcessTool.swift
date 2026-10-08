import Darwin
import Foundation
import MCP

struct ProcessToolRequest: Sendable {
    let command: String
    let workingDirectory: String?
    let environment: [String: String]
    let timeoutSeconds: Double
}

struct ProcessToolResult: Sendable {
    let command: String
    let workingDirectory: String?
    let exitCode: Int32?
    let timedOut: Bool
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    /// Whether process-group signaling and output-pipe closure completed.
    /// Descendants that deliberately leave the group are outside this contract.
    let processGroupCleanupSucceeded: Bool?
}

enum ProcessToolError: LocalizedError {
    case missingCommand
    case invalidTimeout
    case invalidWorkingDirectory(String)
    case launchFailed(String)
    case executionStatusUnavailable(String)
    case cancellationSignalFailed(String)
    case statusCleanupFailed(String)
    case cancellationCleanupFailed

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "Missing 'command' parameter"
        case .invalidTimeout:
            return "timeoutSeconds must be greater than 0"
        case .invalidWorkingDirectory(let path):
            return "Working directory does not exist or is not a directory: \(path)"
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        case .executionStatusUnavailable(let reason):
            return "Process execution status is unavailable: \(reason). The command may have run; do not retry automatically"
        case .cancellationSignalFailed(let reason):
            return "Process cancellation signaling failed: \(reason)"
        case .statusCleanupFailed(let reason):
            return "Process status cleanup failed: \(reason)"
        case .cancellationCleanupFailed:
            return "Process cancellation could not prove that the owned process group was terminated"
        }
    }
}

final class ProcessToolOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var byteCount = 0
    private var didTruncate = false
    private let maxBytes: Int

    init(maxBytes: Int = .max) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let remaining = max(0, maxBytes - byteCount)
        if data.count > remaining {
            if remaining > 0 {
                chunks.append(data.prefix(remaining))
                byteCount += remaining
            }
            didTruncate = true
        } else {
            chunks.append(data)
            byteCount += data.count
        }
        lock.unlock()
    }

    func snapshot() -> (string: String, truncated: Bool) {
        lock.lock()
        let data = chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }
        let truncated = didTruncate
        lock.unlock()
        return (
            String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self),
            truncated
        )
    }

    func string() -> String {
        snapshot().string
    }
}

final class ProcessToolCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

private func writeProcessToolCancellationSignal(to handle: FileHandle) throws {
    try handle.write(contentsOf: Data([1]))
}

private func writeProcessToolStatusAcknowledgement(to handle: FileHandle) throws {
    try handle.write(contentsOf: Data([2]))
}

private func closeProcessToolCancellationSignal(_ handle: FileHandle) throws {
    try handle.close()
}

private func isProcessToolBrokenPipe(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPIPE) {
        return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isProcessToolBrokenPipe(underlying)
    }
    return false
}

/// Arbitrates task cancellation against process completion and owns the write
/// end of the controller's cancellation pipe. Whichever side claims the lock
/// first determines whether an otherwise successful result is cancelled.
final class ProcessToolCancellationSignal: @unchecked Sendable {
    struct Outcome: Sendable {
        struct Failure: Sendable {
            let message: String
            let isBrokenPipeWrite: Bool
        }

        let wasRequested: Bool
        let failures: [Failure]

        func signalingFailure(ignoringBrokenPipeWrite: Bool = false) -> String? {
            let messages = failures.compactMap { failure in
                ignoringBrokenPipeWrite && failure.isBrokenPipeWrite ? nil : failure.message
            }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
    }

    typealias HandleOperation = @Sendable (FileHandle) throws -> Void

    private let lock = NSLock()
    private var writeHandle: FileHandle?
    private var requested = false
    private var completed = false
    private var signalingFailures: [Outcome.Failure] = []
    private let writeOperation: HandleOperation
    private let closeOperation: HandleOperation

    init(
        writeHandle: FileHandle,
        writeOperation: @escaping HandleOperation = writeProcessToolCancellationSignal,
        closeOperation: @escaping HandleOperation = closeProcessToolCancellationSignal
    ) {
        self.writeHandle = writeHandle
        self.writeOperation = writeOperation
        self.closeOperation = closeOperation
        if fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            signalingFailures.append(.init(
                message: "Could not configure cancellation signal: \(String(cString: strerror(errno)))",
                isBrokenPipeWrite: false
            ))
        }
    }

    func request() {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, let handle = writeHandle else { return }

        requested = true
        do {
            try writeOperation(handle)
        } catch {
            signalingFailures.append(.init(
                message: "write failed: \(error.localizedDescription)",
                isBrokenPipeWrite: isProcessToolBrokenPipe(error)
            ))
            do {
                try closeOperation(handle)
            } catch {
                signalingFailures.append(.init(
                    message: "close after write failure failed: \(error.localizedDescription)",
                    isBrokenPipeWrite: false
                ))
            }
            writeHandle = nil
        }
    }

    func acknowledgeStatus() {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, let handle = writeHandle else { return }
        do {
            try writeProcessToolStatusAcknowledgement(to: handle)
        } catch {
            signalingFailures.append(.init(
                message: "status acknowledgement failed: \(error.localizedDescription)",
                isBrokenPipeWrite: isProcessToolBrokenPipe(error)
            ))
        }
    }

    func recordFailure(_ failure: String) {
        lock.lock()
        signalingFailures.append(.init(message: failure, isBrokenPipeWrite: false))
        lock.unlock()
    }

    func finish() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        completed = true
        if let handle = writeHandle {
            do {
                try closeOperation(handle)
            } catch {
                signalingFailures.append(.init(
                    message: "close failed: \(error.localizedDescription)",
                    isBrokenPipeWrite: false
                ))
            }
            writeHandle = nil
        }
        return Outcome(wasRequested: requested, failures: signalingFailures)
    }
}

final class ProcessToolStatusExchange: @unchecked Sendable {
    struct Outcome: Sendable {
        let status: String?
        let cleanupFailure: String?
        let observationFailure: String?
    }

    private let condition = NSCondition()
    private var storedOutcome: Outcome?
    private var stopped = false

    func start(
        statusURL: URL,
        remover: @escaping ProcessToolStatusRemover,
        acknowledge: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                condition.lock()
                let shouldStop = stopped
                condition.unlock()
                if shouldStop { return }

                if FileManager.default.fileExists(atPath: statusURL.path) {
                    let status: String
                    do {
                        status = try String(contentsOf: statusURL, encoding: .utf8)
                    } catch {
                        condition.lock()
                        storedOutcome = Outcome(
                            status: nil,
                            cleanupFailure: nil,
                            observationFailure: error.localizedDescription
                        )
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                    let cleanupFailure: String?
                    do {
                        try remover(statusURL)
                        cleanupFailure = nil
                    } catch {
                        cleanupFailure = error.localizedDescription
                    }
                    acknowledge()
                    condition.lock()
                    storedOutcome = Outcome(
                        status: status,
                        cleanupFailure: cleanupFailure,
                        observationFailure: nil
                    )
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                usleep(5_000)
            }
        }
    }

    func finish(timeoutSeconds: Double = 0.5) -> Outcome? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while storedOutcome == nil, !stopped {
            if !condition.wait(until: deadline) { break }
        }
        stopped = true
        condition.broadcast()
        return storedOutcome
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

enum ProcessToolControllerStatus: Equatable {
    case completed(exitCode: Int32)
    case completedCleanupFailed(exitCode: Int32)
    case timedOut(groupCleanupSucceeded: Bool)
    case cancelled(groupCleanupSucceeded: Bool)
    case launchFailed(String)
}

func parseProcessToolControllerStatus(_ text: String) -> ProcessToolControllerStatus? {
    let status = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.hasPrefix("completed:"),
       let exitCode = Int32(status.dropFirst("completed:".count)) {
        return .completed(exitCode: exitCode)
    }
    if status.hasPrefix("completedCleanupFailed:"),
       let exitCode = Int32(status.dropFirst("completedCleanupFailed:".count)) {
        return .completedCleanupFailed(exitCode: exitCode)
    }
    if status == "timedOut:groupSignaled" {
        return .timedOut(groupCleanupSucceeded: true)
    }
    if status == "timedOut:groupSignalFailed" {
        return .timedOut(groupCleanupSucceeded: false)
    }
    if status == "cancelled:groupSignaled" {
        return .cancelled(groupCleanupSucceeded: true)
    }
    if status == "cancelled:groupSignalFailed" {
        return .cancelled(groupCleanupSucceeded: false)
    }
    if status.hasPrefix("launchFailed:") {
        return .launchFailed(String(status.dropFirst("launchFailed:".count)))
    }
    return nil
}

private func writeProcessToolStatus(_ status: String, to path: String) {
#if DEBUG
    if ProcessInfo.processInfo.environment["HOLOSCAPE_PROCESS_TOOL_TEST_STATUS_WRITE_FAILURE"] == "1" {
        FileHandle.standardError.write(Data("Injected process status write failure\n".utf8))
        return
    }
#endif
    do {
        try Data(status.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("Failed to write process status: \(error.localizedDescription)\n".utf8))
    }
}

private func spawnProcessToolShell(command: String, processGroupID: pid_t) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        throw ProcessToolError.launchFailed("Could not initialize shell launch attributes")
    }
    defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
    }

    guard posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
    ) == 0,
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
    posix_spawnattr_setpgroup(&attributes, processGroupID) == 0 else {
        throw ProcessToolError.launchFailed("Could not configure shell process group")
    }

    var spawnedPID: pid_t = 0
    let result = "/bin/zsh".withCString { shellPointer in
        "-lc".withCString { flagPointer in
            command.withCString { commandPointer in
                var arguments: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: shellPointer),
                    UnsafeMutablePointer(mutating: flagPointer),
                    UnsafeMutablePointer(mutating: commandPointer),
                    nil,
                ]
                return arguments.withUnsafeMutableBufferPointer { buffer in
                    posix_spawn(
                        &spawnedPID,
                        shellPointer,
                        &fileActions,
                        &attributes,
                        buffer.baseAddress!,
                        environ
                    )
                }
            }
        }
    }
    guard result == 0 else {
        throw ProcessToolError.launchFailed(String(cString: strerror(result)))
    }
    return spawnedPID
}

/// Launches a sacrificial direct parent for the command as leader of a fresh
/// process group. The timeout controller keeps this child waitable until cleanup
/// signals are sent, so its PID cannot be reused as an unrelated group ID.
private func spawnProcessToolGroupLeader(command: String, statusPath: String) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        throw ProcessToolError.launchFailed("Could not initialize group leader launch attributes")
    }
    defer { posix_spawnattr_destroy(&attributes) }

    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        throw ProcessToolError.launchFailed("Could not configure group leader process group")
    }

    var spawnedPID: pid_t = 0
    let executablePath = CommandLine.arguments[0]
    let result = executablePath.withCString { executablePointer in
        "--holoscape-process-shell-runner".withCString { modePointer in
            command.withCString { commandPointer in
                statusPath.withCString { statusPointer in
                    var arguments: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executablePointer),
                        UnsafeMutablePointer(mutating: modePointer),
                        UnsafeMutablePointer(mutating: commandPointer),
                        UnsafeMutablePointer(mutating: statusPointer),
                        nil,
                    ]
                    return arguments.withUnsafeMutableBufferPointer { buffer in
                        posix_spawn(
                            &spawnedPID,
                            executablePointer,
                            nil,
                            &attributes,
                            buffer.baseAddress!,
                            environ
                        )
                    }
                }
            }
        }
    }
    guard result == 0 else {
        throw ProcessToolError.launchFailed(String(cString: strerror(result)))
    }
    return spawnedPID
}

private func processToolExitCode(from waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : signal
}

private func waitForProcessToolChild(_ pid: pid_t) -> Result<Int32, ProcessToolError> {
    var waitStatus: Int32 = 0
    while true {
        if waitpid(pid, &waitStatus, 0) == pid {
            return .success(processToolExitCode(from: waitStatus))
        }
        if errno != EINTR {
            return .failure(.launchFailed("Could not wait for child process: \(String(cString: strerror(errno)))"))
        }
    }
}

/// Reaps a child if it exits before the deadline. Returning nil leaves the
/// still-running child to the OS when the controller exits instead of allowing
/// a failed cleanup signal to defeat the caller's timeout indefinitely.
func waitForProcessToolChild(
    _ pid: pid_t,
    timeoutSeconds: Double
) -> Result<Int32, ProcessToolError>? {
#if DEBUG
    if ProcessInfo.processInfo.environment["HOLOSCAPE_PROCESS_TOOL_TEST_WAIT_FAILURE"] == "1" {
        return .failure(.launchFailed("Injected child wait failure"))
    }
#endif
    let deadline = DispatchTime.now() + timeoutSeconds
    var waitStatus: Int32 = 0
    while true {
        let result = waitpid(pid, &waitStatus, WNOHANG)
        if result == pid {
            return .success(processToolExitCode(from: waitStatus))
        }
        if result == -1, errno != EINTR {
            return .failure(.launchFailed("Could not wait for child process: \(String(cString: strerror(errno)))"))
        }
        if DispatchTime.now() >= deadline {
            return nil
        }
        usleep(5_000)
    }
}

/// Keeps the timeout controller outside the command's group. `$PPID` therefore
/// identifies this sacrificial runner; stopping or killing it cannot disable the
/// controller, and its unreaped PID continues to reserve the group ID.
func runProcessToolShellRunner(command: String, statusPath: String) -> Never {
#if DEBUG
    if ProcessInfo.processInfo.environment["HOLOSCAPE_PROCESS_TOOL_TEST_RUNNER_FAILURE"] == "1" {
        writeProcessToolStatus("launchFailed:Injected shell-runner launch failure", to: statusPath)
        Darwin.exit(127)
    }
#endif
    let shellPID: pid_t
    do {
        shellPID = try spawnProcessToolShell(command: command, processGroupID: getpgrp())
    } catch {
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath)
        FileHandle.standardError.write(Data("Failed to launch process shell: \(error.localizedDescription)\n".utf8))
        Darwin.exit(127)
    }

    switch waitForProcessToolChild(shellPID) {
    case .success(let exitCode):
        Darwin.exit(exitCode)
    case .failure(let error):
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath)
        FileHandle.standardError.write(Data("Failed to wait for process shell: \(error.localizedDescription)\n".utf8))
        Darwin.exit(127)
    }
}

private func processToolChildHasExited(_ pid: pid_t) -> Result<Bool, ProcessToolError> {
    var information = siginfo_t()
    while true {
        let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 {
            let exited = information.si_pid == pid
                && (information.si_code == CLD_EXITED
                    || information.si_code == CLD_KILLED
                    || information.si_code == CLD_DUMPED)
            return .success(exited)
        }
        if errno != EINTR {
            return .failure(.launchFailed("Could not inspect child process: \(String(cString: strerror(errno)))"))
        }
    }
}

private func configureProcessToolCancellationInput() throws {
    let currentFlags = fcntl(STDIN_FILENO, F_GETFL)
    guard currentFlags != -1,
          fcntl(STDIN_FILENO, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
        throw ProcessToolError.launchFailed(
            "Could not configure cancellation channel: \(String(cString: strerror(errno)))"
        )
    }
}

private enum ProcessToolCancellationInput {
    case none
    case requested
    case statusAcknowledged
    case callerDisconnected
    case failed(ProcessToolError)
}

/// The caller owns stdin's write end. A byte is an explicit task-cancellation
/// request; EOF means the caller process disappeared.
private func readProcessToolCancellationInput() -> ProcessToolCancellationInput {
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count > 0 { return byte == 2 ? .statusAcknowledged : .requested }
        if count == 0 { return .callerDisconnected }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .none }
        return .failed(.launchFailed(
            "Could not read cancellation channel: \(String(cString: strerror(errno)))"
        ))
    }
}

/// Returns true only when the owned, unreaped group leader is the group's sole
/// remaining member. Enumeration failure or any descendant is uncertainty.
private func processToolGroupContainsOnlyLeader(_ processGroupID: pid_t) -> Bool {
#if DEBUG
    if ProcessInfo.processInfo.environment["HOLOSCAPE_PROCESS_TOOL_TEST_ENUMERATION_FAILURE"] == "1" {
        return false
    }
#endif
    errno = 0
    let capacity = proc_listpgrppids(processGroupID, nil, 0)
    guard capacity > 0, errno == 0 else { return false }

    var processIDs = [pid_t](repeating: 0, count: Int(capacity))
    errno = 0
    let count = proc_listpgrppids(
        processGroupID,
        &processIDs,
        Int32(processIDs.count * MemoryLayout<pid_t>.size)
    )
    guard count > 0, errno == 0 else { return false }

    let members = processIDs.prefix(Int(count)).filter { $0 > 0 }
    return members.count == 1 && members[0] == processGroupID
}

/// Sends bounded TERM-to-KILL escalation while the unreaped group leader still
/// reserves the numeric process-group ID. This proves signals target the owned
/// group; it does not claim to contain descendants that deliberately call setsid.
private func terminateProcessToolGroup(_ processGroupID: pid_t) -> Bool {
#if DEBUG
    if ProcessInfo.processInfo.environment["HOLOSCAPE_PROCESS_TOOL_TEST_SIGNAL_FAILURE"] == "1" {
        return false
    }
#endif
    func absentOrOnlyLeaderAfterPermissionFailure() -> Bool {
        errno == ESRCH || (errno == EPERM && processToolGroupContainsOnlyLeader(processGroupID))
    }

    if Darwin.kill(-processGroupID, SIGTERM) == -1 {
        return absentOrOnlyLeaderAfterPermissionFailure()
    }

    usleep(250_000)
    if Darwin.kill(-processGroupID, SIGKILL) == -1 {
        return absentOrOnlyLeaderAfterPermissionFailure()
    }
    let deadline = DispatchTime.now() + .seconds(1)
    while DispatchTime.now() < deadline {
        if processToolGroupContainsOnlyLeader(processGroupID) {
            return true
        }
        usleep(5_000)
    }
    return false
}

private func drainProcessToolPipe(
    _ handle: FileHandle,
    into buffer: ProcessToolOutputBuffer
) -> Bool {
    let descriptor = handle.fileDescriptor
    let currentFlags = fcntl(descriptor, F_GETFL)
    guard currentFlags != -1,
          fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
        try? handle.close()
        return false
    }

    var bytes = [UInt8](repeating: 0, count: 8_192)
    let deadline = DispatchTime.now() + .milliseconds(100)
    while DispatchTime.now() < deadline {
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            buffer.append(Data(bytes.prefix(count)))
            continue
        }
        if count == 0 {
            do {
                try handle.close()
                return true
            } catch {
                return false
            }
        }
        let readError = errno
        if readError == EINTR { continue }
        if readError == EAGAIN || readError == EWOULDBLOCK {
            usleep(1_000)
            continue
        }
        try? handle.close()
        return false
    }
    try? handle.close()
    return false
}

/// Serializes asynchronous readability callbacks with final draining and
/// snapshotting. Clearing FileHandle's handler does not join an invocation that
/// is already running, so the explicit lock is the ownership boundary.
final class ProcessToolPipeReader: @unchecked Sendable {
    typealias Output = (string: String, truncated: Bool)

    struct Outcome {
        let output: Output
        let closedCleanly: Bool
    }

    private let handle: FileHandle
    private let buffer: ProcessToolOutputBuffer
    private let beforeAppend: (() -> Void)?
    private let lock = NSLock()
    private var active = true

    init(
        handle: FileHandle,
        buffer: ProcessToolOutputBuffer,
        beforeAppend: (() -> Void)? = nil
    ) {
        self.handle = handle
        self.buffer = buffer
        self.beforeAppend = beforeAppend
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle)
        }
    }

    private func consumeAvailableData(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let data = handle.availableData
        beforeAppend?()
        buffer.append(data)
    }

    func finish() -> Outcome {
        handle.readabilityHandler = nil
        lock.lock()
        active = false
        let closedCleanly = drainProcessToolPipe(handle, into: buffer)
        let output = buffer.snapshot()
        lock.unlock()
        return Outcome(output: output, closedCleanly: closedCleanly)
    }

    func cancel() {
        handle.readabilityHandler = nil
        lock.lock()
        active = false
        try? handle.close()
        lock.unlock()
    }
}

private func exitProcessToolControllerAfterCallerDisconnect(
    statusPath: String,
    runnerStatusPath: String? = nil,
    groupCleanupSucceeded: Bool
) -> Never {
    if unlink(statusPath) == -1, errno != ENOENT {
        Darwin.exit(124)
    }
    if let runnerStatusPath,
       unlink(runnerStatusPath) == -1,
       errno != ENOENT {
        Darwin.exit(124)
    }
    Darwin.exit(groupCleanupSucceeded ? 0 : 125)
}

private func removeUnacknowledgedProcessToolStatus(_ statusPath: String) -> Bool {
    unlink(statusPath) == 0 || errno == ENOENT
}

private func publishProcessToolStatus(
    _ status: String,
    to statusPath: String,
    exitCode: Int32
) -> Never {
    writeProcessToolStatus(status, to: statusPath)
    let acknowledgementDeadline = DispatchTime.now() + .seconds(2)
    while DispatchTime.now() < acknowledgementDeadline {
        switch readProcessToolCancellationInput() {
        case .statusAcknowledged:
            Darwin.exit(exitCode)
        case .callerDisconnected:
            exitProcessToolControllerAfterCallerDisconnect(
                statusPath: statusPath,
                groupCleanupSucceeded: exitCode == 0
            )
        case .failed:
            Darwin.exit(removeUnacknowledgedProcessToolStatus(statusPath) ? 126 : 124)
        case .none, .requested:
            usleep(5_000)
        }
    }
    Darwin.exit(removeUnacknowledgedProcessToolStatus(statusPath) ? 123 : 124)
}

private func processToolControllerExitFailure(
    for status: ProcessToolControllerStatus,
    terminationReason: Process.TerminationReason,
    terminationStatus: Int32
) -> ProcessToolError? {
    if let protocolFailure = processToolControllerProtocolFailure(
        terminationReason: terminationReason,
        terminationStatus: terminationStatus
    ) {
        return protocolFailure
    }

    let expectedExitCodes: Set<Int32>
    switch status {
    case .completed, .completedCleanupFailed, .timedOut(groupCleanupSucceeded: true),
         .cancelled(groupCleanupSucceeded: true):
        expectedExitCodes = [0]
    case .timedOut(groupCleanupSucceeded: false), .cancelled(groupCleanupSucceeded: false):
        expectedExitCodes = [0, 125]
    case .launchFailed:
        expectedExitCodes = [125, 127]
    }
    guard expectedExitCodes.contains(terminationStatus) else {
        return .executionStatusUnavailable(
            "Controller exit \(terminationStatus) did not confirm its published status"
        )
    }
    return nil
}

private func processToolControllerProtocolFailure(
    terminationReason: Process.TerminationReason,
    terminationStatus: Int32
) -> ProcessToolError? {
    guard terminationReason == .exit else {
        return .executionStatusUnavailable(
            "Controller terminated by signal \(terminationStatus) before its status could be confirmed"
        )
    }

    switch terminationStatus {
    case 123:
        return .executionStatusUnavailable(
            "Controller exited before status acknowledgement completed"
        )
    case 124:
        return .statusCleanupFailed(
            "Controller could not remove an unacknowledged status record"
        )
    case 126:
        return .executionStatusUnavailable(
            "Controller cancellation channel failed after status publication"
        )
    default:
        return nil
    }
}

private func processToolSignalingFailure(
    _ signalingFailure: String,
    alongside status: ProcessToolControllerStatus
) -> ProcessToolError {
    switch status {
    case .launchFailed(let reason):
        return .launchFailed(
            "\(reason); cancellation signaling also failed: \(signalingFailure)"
        )
    case .completedCleanupFailed(let exitCode):
        return .cancellationSignalFailed(
            "\(signalingFailure); controller also reported process-group cleanup failure after exit \(exitCode)"
        )
    case .timedOut(groupCleanupSucceeded: false), .cancelled(groupCleanupSucceeded: false):
        return .cancellationSignalFailed(
            "\(signalingFailure); controller also reported process-group cleanup failure"
        )
    case .completed, .timedOut(groupCleanupSucceeded: true), .cancelled(groupCleanupSucceeded: true):
        return .cancellationSignalFailed(signalingFailure)
    }
}

private func processToolFailure(
    _ primary: ProcessToolError,
    addingSignalingFailure signalingFailure: String?
) -> ProcessToolError {
    guard let signalingFailure else { return primary }
    let suffix = "; cancellation signaling also failed: \(signalingFailure)"
    switch primary {
    case .launchFailed(let reason):
        return .launchFailed(reason + suffix)
    case .executionStatusUnavailable(let reason):
        return .executionStatusUnavailable(reason + suffix)
    case .cancellationSignalFailed(let reason):
        return .cancellationSignalFailed(reason + "; \(signalingFailure)")
    case .statusCleanupFailed(let reason):
        return .statusCleanupFailed(reason + suffix)
    case .cancellationCleanupFailed:
        return .cancellationSignalFailed(
            "\(signalingFailure); controller also could not prove process-group cleanup"
        )
    case .missingCommand, .invalidTimeout, .invalidWorkingDirectory:
        return primary
    }
}

private func processToolCleanupFailureSuffix(
    groupCleanupSucceeded: Bool,
    childResult: Result<Int32, ProcessToolError>?
) -> String {
    var failures: [String] = []
    if !groupCleanupSucceeded {
        failures.append("process-group signaling did not prove cleanup")
    }
    switch childResult {
    case .none:
        failures.append("group leader did not exit before the cleanup deadline")
    case .failure(let error):
        failures.append("group leader wait failed: \(error.localizedDescription)")
    case .success:
        break
    }
    return failures.isEmpty ? "" : "; cleanup was not proven: " + failures.joined(separator: "; ")
}

private func consumeProcessToolRunnerFailure(at statusPath: String) -> Result<String?, ProcessToolError> {
    guard FileManager.default.fileExists(atPath: statusPath) else {
        return .success(nil)
    }
    do {
        let status = try String(contentsOfFile: statusPath, encoding: .utf8)
        try FileManager.default.removeItem(atPath: statusPath)
        guard case .launchFailed(let reason) = parseProcessToolControllerStatus(status) else {
            return .failure(.launchFailed("Shell runner published an invalid status record"))
        }
        return .success(reason)
    } catch {
        return .failure(.launchFailed(
            "Could not consume shell-runner status: \(error.localizedDescription)"
        ))
    }
}

/// Owns timeout arbitration outside the command's process group. The direct
/// shell remains an unreaped child until cleanup finishes, preventing PGID reuse
/// between timeout detection and group signaling.
func runProcessToolController(
    command: String,
    timeoutSeconds: Double,
    statusPath: String
) -> Never {
    let runnerStatusPath = statusPath + ".runner"
    do {
        try configureProcessToolCancellationInput()
    } catch {
        publishProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath, exitCode: 127)
    }

    let groupLeaderPID: pid_t
    do {
        groupLeaderPID = try spawnProcessToolGroupLeader(command: command, statusPath: runnerStatusPath)
    } catch {
        publishProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath, exitCode: 127)
    }

    let deadline = DispatchTime.now() + timeoutSeconds
    var timedOut = false
    var cancelled = false
    var callerDisconnected = false
    var inspectionFailure: ProcessToolError?
    while true {
        switch processToolChildHasExited(groupLeaderPID) {
        case .success(true):
            break
        case .success(false):
            switch readProcessToolCancellationInput() {
            case .none:
                break
            case .requested:
                cancelled = true
            case .statusAcknowledged:
                break
            case .callerDisconnected:
                callerDisconnected = true
            case .failed(let error):
                inspectionFailure = error
            }
            if cancelled || callerDisconnected || inspectionFailure != nil {
                break
            }
            if DispatchTime.now() >= deadline {
                timedOut = true
                break
            }
            usleep(5_000)
            continue
        case .failure(let error):
            inspectionFailure = error
        }
        break
    }

    let groupCleanupSucceeded = terminateProcessToolGroup(groupLeaderPID)
    let childResult = waitForProcessToolChild(
        groupLeaderPID,
        timeoutSeconds: groupCleanupSucceeded ? 2 : 0.1
    )

    if callerDisconnected {
        let childExitedCleanly: Bool
        if case .success = childResult {
            childExitedCleanly = true
        } else {
            childExitedCleanly = false
        }
        exitProcessToolControllerAfterCallerDisconnect(
            statusPath: statusPath,
            runnerStatusPath: runnerStatusPath,
            groupCleanupSucceeded: groupCleanupSucceeded && childExitedCleanly
        )
    }
    if let inspectionFailure {
        let suffix = processToolCleanupFailureSuffix(
            groupCleanupSucceeded: groupCleanupSucceeded,
            childResult: childResult
        )
        publishProcessToolStatus(
            "launchFailed:\(inspectionFailure.localizedDescription)\(suffix)",
            to: statusPath,
            exitCode: 125
        )
    }
    guard let childResult else {
        let status = if cancelled {
            "cancelled:groupSignalFailed"
        } else if timedOut {
            "timedOut:groupSignalFailed"
        } else {
            "launchFailed:Child process did not exit after cleanup signaling"
        }
        publishProcessToolStatus(status, to: statusPath, exitCode: 125)
    }
    guard case .success(let exitCode) = childResult else {
        let reason: String
        if case .failure(let error) = childResult {
            reason = error.localizedDescription
        } else {
            reason = "Unknown child wait failure"
        }
        let suffix = processToolCleanupFailureSuffix(
            groupCleanupSucceeded: groupCleanupSucceeded,
            childResult: childResult
        )
        publishProcessToolStatus("launchFailed:\(reason)\(suffix)", to: statusPath, exitCode: 125)
    }

    if !cancelled {
        switch readProcessToolCancellationInput() {
        case .none:
            break
        case .requested:
            cancelled = true
        case .statusAcknowledged:
            break
        case .callerDisconnected:
            exitProcessToolControllerAfterCallerDisconnect(
                statusPath: statusPath,
                runnerStatusPath: runnerStatusPath,
                groupCleanupSucceeded: groupCleanupSucceeded
            )
        case .failed(let error):
            publishProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath, exitCode: 125)
        }
    }

    switch consumeProcessToolRunnerFailure(at: runnerStatusPath) {
    case .success(.some(let reason)):
        let suffix = processToolCleanupFailureSuffix(
            groupCleanupSucceeded: groupCleanupSucceeded,
            childResult: childResult
        )
        publishProcessToolStatus("launchFailed:\(reason)\(suffix)", to: statusPath, exitCode: 125)
    case .success(.none):
        break
    case .failure(let error):
        let suffix = processToolCleanupFailureSuffix(
            groupCleanupSucceeded: groupCleanupSucceeded,
            childResult: childResult
        )
        publishProcessToolStatus("launchFailed:\(error.localizedDescription)\(suffix)", to: statusPath, exitCode: 125)
    }

    let finalStatus: String
    if cancelled {
        finalStatus = groupCleanupSucceeded ? "cancelled:groupSignaled" : "cancelled:groupSignalFailed"
    } else if timedOut {
        finalStatus = groupCleanupSucceeded ? "timedOut:groupSignaled" : "timedOut:groupSignalFailed"
    } else if groupCleanupSucceeded {
        finalStatus = "completed:\(exitCode)"
    } else {
        finalStatus = "completedCleanupFailed:\(exitCode)"
    }
    publishProcessToolStatus(finalStatus, to: statusPath, exitCode: 0)
}

func processToolRequest(from args: [String: Value]) throws -> ProcessToolRequest {
    guard let command = args["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !command.isEmpty else {
        throw ProcessToolError.missingCommand
    }

    let timeout = args["timeoutSeconds"]?.doubleValue
        ?? args["timeoutSeconds"]?.intValue.map(Double.init)
        ?? 30
    guard timeout > 0 else {
        throw ProcessToolError.invalidTimeout
    }

    var environment: [String: String] = [:]
    if let envObject = args["env"]?.objectValue {
        for (key, value) in envObject {
            if let string = value.stringValue {
                environment[key] = string
            }
        }
    }

    return ProcessToolRequest(
        command: command,
        workingDirectory: args["workingDirectory"]?.stringValue ?? args["dir"]?.stringValue,
        environment: environment,
        timeoutSeconds: timeout
    )
}

typealias ProcessToolStatusRemover = @Sendable (URL) throws -> Void
typealias ProcessToolCancellationSignalFactory = @Sendable (FileHandle) -> ProcessToolCancellationSignal

private func removeProcessToolStatus(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
}

private func makeProcessToolCancellationSignal(writeHandle: FileHandle) -> ProcessToolCancellationSignal {
    ProcessToolCancellationSignal(writeHandle: writeHandle)
}

func runProcessTool(
    _ request: ProcessToolRequest,
    maxOutputBytes: Int = 1_048_576,
    launcherExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
    temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
    statusRemover: @escaping ProcessToolStatusRemover = removeProcessToolStatus,
    cancellationSignalFactory: @escaping ProcessToolCancellationSignalFactory = makeProcessToolCancellationSignal
) async throws -> ProcessToolResult {
    let process = Process()
    let statusURL = temporaryDirectoryURL
        .appendingPathComponent("holoscape-process-tool-\(UUID().uuidString).status")
    process.executableURL = launcherExecutableURL
    process.arguments = [
        "--holoscape-process-controller",
        request.command,
        String(request.timeoutSeconds),
        statusURL.path,
    ]

    if let workingDirectory = request.workingDirectory, !workingDirectory.isEmpty {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessToolError.invalidWorkingDirectory(workingDirectory)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    if !request.environment.isEmpty {
        var env = ProcessInfo.processInfo.environment
        request.environment.forEach { key, value in env[key] = value }
        process.environment = env
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let cancellationPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = cancellationPipe

    let stdout = ProcessToolOutputBuffer(maxBytes: maxOutputBytes)
    let stderr = ProcessToolOutputBuffer(maxBytes: maxOutputBytes)
    let stdoutReader = ProcessToolPipeReader(handle: stdoutPipe.fileHandleForReading, buffer: stdout)
    let stderrReader = ProcessToolPipeReader(handle: stderrPipe.fileHandleForReading, buffer: stderr)
    let cancellation = cancellationSignalFactory(cancellationPipe.fileHandleForWriting)
    let statusExchange = ProcessToolStatusExchange()
    statusExchange.start(
        statusURL: statusURL,
        remover: statusRemover,
        acknowledge: { cancellation.acknowledgeStatus() }
    )
    stdoutReader.start()
    stderrReader.start()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let cancellationOutcome = cancellation.finish()
                let stdoutOutcome = stdoutReader.finish()
                let stderrOutcome = stderrReader.finish()
                let outputPipesClosed = stdoutOutcome.closedCleanly && stderrOutcome.closedCleanly
                let standardOutput = stdoutOutcome.output
                let standardError = stderrOutcome.output
                let statusOutcome = statusExchange.finish()
                let unconfirmedSignalingFailure = cancellationOutcome.signalingFailure()
                if let observationFailure = statusOutcome?.observationFailure {
                    continuation.resume(throwing: processToolFailure(
                        .executionStatusUnavailable("Could not read controller status: \(observationFailure)"),
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                if let protocolFailure = processToolControllerProtocolFailure(
                    terminationReason: process.terminationReason,
                    terminationStatus: process.terminationStatus
                ) {
                    continuation.resume(throwing: processToolFailure(
                        protocolFailure,
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                guard let statusOutcome else {
                    continuation.resume(throwing: processToolFailure(
                        .executionStatusUnavailable("Controller exited without a status record"),
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                if let cleanupFailure = statusOutcome.cleanupFailure {
                    continuation.resume(throwing: processToolFailure(
                        .statusCleanupFailed(cleanupFailure),
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                guard let status = statusOutcome.status,
                      let parsed = parseProcessToolControllerStatus(status) else {
                    continuation.resume(throwing: processToolFailure(
                        .executionStatusUnavailable("Controller exited with an invalid status record"),
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                if let controllerFailure = processToolControllerExitFailure(
                    for: parsed,
                    terminationReason: process.terminationReason,
                    terminationStatus: process.terminationStatus
                ) {
                    continuation.resume(throwing: processToolFailure(
                        controllerFailure,
                        addingSignalingFailure: unconfirmedSignalingFailure
                    ))
                    return
                }
                if let signalingFailure = cancellationOutcome.signalingFailure(ignoringBrokenPipeWrite: true) {
                    continuation.resume(throwing: processToolSignalingFailure(
                        signalingFailure,
                        alongside: parsed
                    ))
                    return
                }
                let cancellationRequested = cancellationOutcome.wasRequested

                switch parsed {
                case .completed(let exitCode):
                    if cancellationRequested {
                        continuation.resume(
                            throwing: outputPipesClosed
                                ? CancellationError()
                                : ProcessToolError.cancellationCleanupFailed
                        )
                        return
                    }
                    continuation.resume(returning: ProcessToolResult(
                        command: request.command,
                        workingDirectory: request.workingDirectory,
                        exitCode: exitCode,
                        timedOut: false,
                        stdout: standardOutput.string,
                        stderr: standardError.string,
                        stdoutTruncated: standardOutput.truncated,
                        stderrTruncated: standardError.truncated,
                        processGroupCleanupSucceeded: outputPipesClosed ? nil : false
                    ))
                case .completedCleanupFailed(let exitCode):
                    if cancellationRequested {
                        continuation.resume(throwing: ProcessToolError.cancellationCleanupFailed)
                        return
                    }
                    continuation.resume(returning: ProcessToolResult(
                        command: request.command,
                        workingDirectory: request.workingDirectory,
                        exitCode: exitCode,
                        timedOut: false,
                        stdout: standardOutput.string,
                        stderr: standardError.string,
                        stdoutTruncated: standardOutput.truncated,
                        stderrTruncated: standardError.truncated,
                        processGroupCleanupSucceeded: false
                    ))
                case .timedOut(let groupCleanupSucceeded):
                    if cancellationRequested {
                        if groupCleanupSucceeded && outputPipesClosed {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: ProcessToolError.cancellationCleanupFailed)
                        }
                        return
                    }
                    continuation.resume(returning: ProcessToolResult(
                        command: request.command,
                        workingDirectory: request.workingDirectory,
                        exitCode: nil,
                        timedOut: true,
                        stdout: standardOutput.string,
                        stderr: standardError.string,
                        stdoutTruncated: standardOutput.truncated,
                        stderrTruncated: standardError.truncated,
                        processGroupCleanupSucceeded: groupCleanupSucceeded && outputPipesClosed
                    ))
                case .cancelled(let groupCleanupSucceeded):
                    if groupCleanupSucceeded && outputPipesClosed {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: ProcessToolError.cancellationCleanupFailed)
                    }
                case .launchFailed(let reason):
                    continuation.resume(throwing: ProcessToolError.launchFailed(reason))
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                statusExchange.stop()
                stdoutReader.cancel()
                stderrReader.cancel()
                do {
                    try cancellationPipe.fileHandleForReading.close()
                } catch {
                    cancellation.recordFailure("parent read close failed: \(error.localizedDescription)")
                }
                let cancellationOutcome = cancellation.finish()
                var reason = error.localizedDescription
                if let signalingFailure = cancellationOutcome.signalingFailure() {
                    reason += "; cancellation channel cleanup also failed: \(signalingFailure)"
                }
                continuation.resume(throwing: ProcessToolError.launchFailed(reason))
                return
            }
            do {
                try cancellationPipe.fileHandleForReading.close()
            } catch {
                cancellation.recordFailure("parent read close failed: \(error.localizedDescription)")
            }
        }
    } onCancel: {
        cancellation.request()
    }
}

func formatProcessToolResult(_ result: ProcessToolResult) -> String {
    var lines: [String] = []
    lines.append("command: \(result.command)")
    if let workingDirectory = result.workingDirectory {
        lines.append("workingDirectory: \(workingDirectory)")
    }
    if result.timedOut {
        lines.append("timedOut: true")
    } else {
        lines.append("exitCode: \(result.exitCode ?? -1)")
    }
    if result.stdoutTruncated {
        lines.append("stdoutTruncated: true")
    }
    if result.stderrTruncated {
        lines.append("stderrTruncated: true")
    }
    if result.processGroupCleanupSucceeded == false {
        lines.append("processGroupCleanupSucceeded: false")
    }
    lines.append("stdout:")
    lines.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
    lines.append("stderr:")
    lines.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
    return lines.joined(separator: "\n")
}

func processToolResultIsError(_ result: ProcessToolResult) -> Bool {
    result.timedOut
        || (result.exitCode ?? 0) != 0
        || result.processGroupCleanupSucceeded == false
}
