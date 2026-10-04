import Darwin
import Foundation

/// Process-backed JSON-lines transport for the app-side broker client.
///
/// This is the narrow app/helper boundary for #7168. The app supplies an
/// explicit broker-host executable; this transport starts it with stdin/stdout
/// pipes, sends exactly one newline-delimited request frame, and reads exactly
/// one newline-delimited response frame. It has no in-process fallback: launch,
/// write, EOF, and non-zero helper exits all surface as typed failures so broker
/// availability problems cannot masquerade as a working terminal session.
final class BrokerSessionHostProcessTransport: @unchecked Sendable {
    enum TransportError: Error, Equatable {
        case launchFailed(String)
        case writeFailed(String)
        case readFailed(String)
        case responseTimedOut
        case transportClosed
        case helperClosedPipe(exitStatus: Int32?)
        case helperExited(exitStatus: Int32)
    }

    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let responseTimeoutSeconds: Int
    private let maximumResponseFrameSize: Int
    // Narrow test observers make otherwise scheduler-dependent ownership
    // boundaries observable. Production callers leave them nil.
    private let requestLockWaitObserver: (() -> Void)?
    private let requestLockAcquiredObserver: (() -> Void)?
    private let responseReadObserver: ((Int32) -> Void)?
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var readBuffer = Data()
    private var isClosed = false
    private var activeRequestCount = 0
    private var descriptorsClosed = false
    private static let terminationGracePeriodMilliseconds = 250
    private static let pollIntervalMilliseconds = 50

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        responseTimeoutSeconds: Int = 5,
        maximumResponseFrameSize: Int = BrokerSessionHostProtocolLimits.maximumResponseFrameSize,
        requestLockWaitObserver: (() -> Void)? = nil,
        requestLockAcquiredObserver: (() -> Void)? = nil,
        responseReadObserver: ((Int32) -> Void)? = nil
    ) throws {
        precondition(maximumResponseFrameSize > 0, "Broker host process maximum response frame size must be positive")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        // Helper diagnostics are not part of the JSON-lines protocol. Send them
        // directly to the null device so an unread stderr pipe can never apply
        // backpressure and prevent the helper from producing its response.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw TransportError.launchFailed(error.localizedDescription)
        }

        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let inputDescriptor = inputHandle.fileDescriptor
        let outputDescriptor = outputHandle.fileDescriptor
        do {
            try Self.configureOwnedWriter(inputDescriptor)
            try Self.configureNonblocking(outputDescriptor)
        } catch {
            try? inputHandle.close()
            try? outputHandle.close()
            Self.terminateLaunchedProcess(process)
            throw TransportError.launchFailed("Could not configure broker transport descriptors: \(error.localizedDescription)")
        }

        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.maximumResponseFrameSize = maximumResponseFrameSize
        self.requestLockWaitObserver = requestLockWaitObserver
        self.requestLockAcquiredObserver = requestLockAcquiredObserver
        self.responseReadObserver = responseReadObserver
    }

    deinit {
        close()
    }

    func sendFrame(_ frame: Data) throws -> Data {
        if !requestLock.try() {
            requestLockWaitObserver?()
            requestLock.lock()
        }
        defer { requestLock.unlock() }
        requestLockAcquiredObserver?()
        try admitRequest()
        defer { releaseRequestOwnership() }

        if !process.isRunning {
            throw TransportError.helperExited(exitStatus: process.terminationStatus)
        }
        try writeFrame(frame)
        return try readResponseFrameLocked()
    }

    func close() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        let shouldCloseDescriptors = activeRequestCount == 0
        stateLock.unlock()

        if shouldCloseDescriptors {
            closeDescriptorsIfSafe()
        }
        terminateHelperBoundedly()
    }

    private func admitRequest() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isClosed {
            throw TransportError.transportClosed
        }
        activeRequestCount += 1
    }

    private func releaseRequestOwnership() {
        stateLock.lock()
        activeRequestCount -= 1
        let shouldCloseDescriptors = isClosed && activeRequestCount == 0
        stateLock.unlock()
        if shouldCloseDescriptors {
            closeDescriptorsIfSafe()
        }
    }

    private func closeDescriptorsIfSafe() {
        stateLock.lock()
        guard !descriptorsClosed, activeRequestCount == 0 else {
            stateLock.unlock()
            return
        }
        descriptorsClosed = true
        stateLock.unlock()
        try? inputHandle.close()
        try? outputHandle.close()
    }

    private func writeFrame(_ frame: Data) throws {
        try frame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                try throwIfClosed()
                var pollFD = pollfd(fd: inputDescriptor, events: Int16(POLLOUT), revents: 0)
                let readyCount = poll(&pollFD, 1, Int32(Self.pollIntervalMilliseconds))
                if readyCount < 0 {
                    if errno == EINTR { continue }
                    try throwIfClosed()
                    throw TransportError.writeFailed(String(cString: strerror(errno)))
                }
                if readyCount == 0 { continue }
                let remaining = rawBuffer.count - offset
                let wrote = Darwin.write(inputDescriptor, baseAddress.advanced(by: offset), remaining)
                if wrote > 0 {
                    offset += wrote
                    continue
                }
                if wrote < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                try throwIfClosed()
                throw TransportError.writeFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func readResponseFrameLocked() throws -> Data {
        if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            return try consumeBufferedFrame(through: newlineIndex)
        }
        guard readBuffer.count < maximumResponseFrameSize else {
            try rejectOversizedResponse()
        }

        var inactivityDeadline = monotonicDeadline(after: responseTimeoutSeconds)
        while true {
            try throwIfClosed()
            let remainingMilliseconds = monotonicRemainingMilliseconds(until: inactivityDeadline)
            if remainingMilliseconds == 0 {
                throw TransportError.responseTimedOut
            }
            var pollFD = pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0)
            let readyCount = poll(&pollFD, 1, remainingMilliseconds)
            if readyCount == 0 { continue }
            if readyCount < 0 {
                if errno == EINTR { continue }
                try throwIfClosed()
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            responseReadObserver?(outputDescriptor)
            let byteCount = Darwin.read(outputDescriptor, &bytes, bytes.count)
            if byteCount > 0 {
                let incoming = bytes.prefix(byteCount)
                let bufferedCount = readBuffer.count
                if let newlineIndex = incoming.firstIndex(of: 0x0A) {
                    let throughDelimiter = incoming.distance(from: incoming.startIndex, to: newlineIndex) + 1
                    guard throughDelimiter <= maximumResponseFrameSize - bufferedCount else {
                        try rejectOversizedResponse()
                    }
                    readBuffer.append(contentsOf: incoming)
                    let bufferedNewlineIndex = readBuffer.index(
                        readBuffer.startIndex,
                        offsetBy: bufferedCount + throughDelimiter - 1
                    )
                    return try consumeBufferedFrame(through: bufferedNewlineIndex)
                }
                guard incoming.count < maximumResponseFrameSize - bufferedCount else {
                    try rejectOversizedResponse()
                }
                readBuffer.append(contentsOf: incoming)
                inactivityDeadline = monotonicDeadline(after: responseTimeoutSeconds)
                continue
            }
            if byteCount < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            try throwIfClosed()
            if byteCount == 0 {
                if process.isRunning {
                    throw TransportError.helperClosedPipe(exitStatus: nil)
                }
                throw TransportError.helperClosedPipe(exitStatus: process.terminationStatus)
            }
            throw TransportError.readFailed(String(cString: strerror(errno)))
        }
    }

    private func consumeBufferedFrame(through newlineIndex: Data.Index) throws -> Data {
        let frameSize = readBuffer.distance(from: readBuffer.startIndex, to: newlineIndex) + 1
        guard frameSize <= maximumResponseFrameSize else {
            try rejectOversizedResponse()
        }
        let frame = readBuffer.prefix(through: newlineIndex)
        readBuffer.removeSubrange(...newlineIndex)
        return Data(frame)
    }

    private func rejectOversizedResponse() throws -> Never {
        close()
        throw BrokerSessionHostProtocolError.frameTooLarge(maximumBytes: maximumResponseFrameSize)
    }

    private func throwIfClosed() throws {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        if closed {
            throw TransportError.transportClosed
        }
    }

    private func monotonicDeadline(after seconds: Int) -> UInt64 {
        let nonnegativeSeconds = UInt64(max(0, seconds))
        let (timeoutNanoseconds, multiplyOverflow) = nonnegativeSeconds.multipliedReportingOverflow(by: 1_000_000_000)
        if multiplyOverflow { return .max }
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, addOverflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return addOverflow ? .max : deadline
    }

    private func monotonicRemainingMilliseconds(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0 }
        let remainingNanoseconds = deadline - now
        // Round up, never down: a sub-millisecond remainder must not become an
        // early timeout. The result is capped before conversion to Int32.
        let milliseconds = remainingNanoseconds / 1_000_000
            + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
        return Int32(min(milliseconds, UInt64(Self.pollIntervalMilliseconds)))
    }

    private func terminateHelperBoundedly() {
        guard process.isRunning else { return }
        process.terminate()
        let terminationDeadline = DispatchTime.now() + .milliseconds(Self.terminationGracePeriodMilliseconds)
        while process.isRunning, DispatchTime.now() < terminationDeadline {
            usleep(10_000)
        }
        guard process.isRunning else { return }

        let result = Darwin.kill(process.processIdentifier, SIGKILL)
        if result != 0, errno != ESRCH {
            NSLog("Broker helper force-termination failed: %s", strerror(errno))
            return
        }
        let killDeadline = DispatchTime.now() + .milliseconds(Self.terminationGracePeriodMilliseconds)
        while process.isRunning, DispatchTime.now() < killDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            NSLog("Broker helper termination could not be confirmed within %dms", Self.terminationGracePeriodMilliseconds * 2)
        }
    }

    private static func configureOwnedWriter(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try configureNonblocking(descriptor)
    }

    private static func configureNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func terminateLaunchedProcess(_ process: Process) {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        let deadline = DispatchTime.now() + .milliseconds(terminationGracePeriodMilliseconds)
        while process.isRunning, DispatchTime.now() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            NSLog("Broker helper cleanup after descriptor configuration failure could not be confirmed")
        }
    }
}
