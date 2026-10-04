import Darwin
import Foundation

/// Unix-domain-socket broker host transport for durable app/broker separation.
///
/// Unlike the stdio helper mode, this server is not tied to a single UI process'
/// stdin/stdout lifetime. A broker process can listen on a local socket, keep its
/// `BrokerSessionRuntime` in memory across client disconnects, and answer one
/// newline-delimited protocol frame per client connection.
struct BrokerSessionHostUnixSocketServer: @unchecked Sendable {
    enum ServerError: Error, Equatable {
        case socketPathTooLong(String)
        case socketFailed(String)
        case bindFailed(String)
        case listenFailed(String)
        case acceptFailed(String)
        case readFailed(String)
        case writeFailed(String)
        case timedOut(String)
    }

    enum Reachability: Equatable {
        case reachable
        case unreachable
        case indeterminate
    }

    private let socketPath: String
    private let host: BrokerSessionHost
    private let codec: BrokerSessionHostCodec
    private let backlog: Int32
    private let readChunkSize: Int
    private let maxConcurrentHandlers: Int
    private let requestTimeoutMilliseconds: Int
    private let maximumFrameSize: Int

    init(
        socketPath: String,
        host: BrokerSessionHost,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        backlog: Int32 = 16,
        readChunkSize: Int = 4096,
        maxConcurrentHandlers: Int = 8,
        requestTimeoutMilliseconds: Int = 10_000,
        maximumFrameSize: Int = BrokerSessionHostProtocolLimits.maximumRequestFrameSize
    ) {
        precondition(readChunkSize > 0, "Broker host socket read chunk size must be positive")
        precondition(maximumFrameSize > 0, "Broker host socket maximum frame size must be positive")
        self.socketPath = socketPath
        self.host = host
        self.codec = codec
        self.backlog = backlog
        self.readChunkSize = readChunkSize
        self.maxConcurrentHandlers = max(1, maxConcurrentHandlers)
        self.requestTimeoutMilliseconds = max(1, requestTimeoutMilliseconds)
        self.maximumFrameSize = maximumFrameSize
    }

    func run(maxConnections: Int? = nil) throws {
        let socketHadBrokerLockMarker = FileManager.default.fileExists(atPath: socketPath + ".lock")
        let brokerLockFD = try acquireBrokerLock()
        var shouldRemoveNewLockMarker = !socketHadBrokerLockMarker
        defer {
            if shouldRemoveNewLockMarker {
                unlink(socketPath + ".lock")
            }
            Darwin.close(brokerLockFD)
        }
        let serverFD = try makeListeningSocket(
            socketHadBrokerLockMarker: socketHadBrokerLockMarker
        )
        shouldRemoveNewLockMarker = false
        let group = DispatchGroup()
        let errorBox = BrokerSocketServerErrorBox()
        let handlerSlots = DispatchSemaphore(value: maxConcurrentHandlers)
        defer {
            group.wait()
            Darwin.close(serverFD)
            unlink(socketPath)
        }

        var handledConnections = 0
        while maxConnections.map({ handledConnections < $0 }) ?? true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                throw ServerError.acceptFailed(String(cString: strerror(errno)))
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(requestTimeoutMilliseconds) * 1_000_000
            do {
                try Self.configureAcceptedClientSocket(clientFD)
            } catch {
                Darwin.close(clientFD)
                throw error
            }
            if handlerSlots.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .timedOut {
                Darwin.close(clientFD)
                errorBox.setIfEmpty(ServerError.timedOut(socketPath))
                handledConnections += 1
                continue
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    handlerSlots.signal()
                    group.leave()
                }
                do {
                    try handleConnection(clientFD, deadline: deadline)
                } catch {
                    errorBox.setIfEmpty(error)
                }
            }
            handledConnections += 1
        }
        group.wait()
        if let error = errorBox.value {
            throw error
        }
    }

    private func acquireBrokerLock() throws -> Int32 {
        let lockPath = socketPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let message = errno == EWOULDBLOCK
                ? "broker lock is already held: \(lockPath)"
                : String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError.bindFailed(message)
        }
        return fd
    }

    static func socketPathHasActiveBrokerLock(_ socketPath: String) -> Bool {
        let fd = open(socketPath + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    private func makeListeningSocket(socketHadBrokerLockMarker: Bool) throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError.socketPathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }

        if FileManager.default.fileExists(atPath: socketPath) {
            switch Self.socketPathBrokerReachability(
                socketPath,
                hasBrokerLockMarker: socketHadBrokerLockMarker
            ) {
            case .reachable:
                Darwin.close(fd)
                throw ServerError.bindFailed("socket path already has a reachable broker: \(socketPath)")
            case .indeterminate:
                Darwin.close(fd)
                throw ServerError.bindFailed("socket path may have a reachable broker: \(socketPath)")
            case .unreachable:
                unlink(socketPath)
            }
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in pathBytes.indices {
                rawBuffer[index] = pathBytes[index]
            }
            rawBuffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError.bindFailed(message)
        }

        guard listen(fd, backlog) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            unlink(socketPath)
            throw ServerError.listenFailed(message)
        }

        return fd
    }

    static func socketPathHasReachableBroker(
        _ socketPath: String,
        timeoutMilliseconds: Int = 250
    ) -> Bool {
        socketPathBrokerReachability(
            socketPath,
            timeoutMilliseconds: timeoutMilliseconds
        ) == .reachable
    }

    static func socketPathBrokerReachability(
        _ socketPath: String,
        timeoutMilliseconds: Int = 250,
        hasBrokerLockMarker: Bool? = nil
    ) -> Reachability {
        let codec = BrokerSessionHostCodec()
        let probeFrame: Data
        do {
            probeFrame = try codec.encodeRequest(.listSessions)
        } catch {
            return .indeterminate
        }

        let responseFrame: Data
        do {
            responseFrame = try BrokerSessionHostUnixSocketTransport(
                socketPath: socketPath,
                requestTimeoutMilliseconds: timeoutMilliseconds
            ).sendFrame(probeFrame)
        } catch BrokerSessionHostUnixSocketTransport.TransportError.connectFailed {
            let lockMarkerExists = hasBrokerLockMarker
                ?? FileManager.default.fileExists(atPath: socketPath + ".lock")
            if FileManager.default.fileExists(atPath: socketPath), !lockMarkerExists {
                return .indeterminate
            }
            return .unreachable
        } catch {
            return .indeterminate
        }

        do {
            _ = try codec.decodeResponse(responseFrame)
            return .reachable
        } catch {
            return .indeterminate
        }
    }

    static func configureAcceptedClientSocket(_ clientFD: Int32) throws {
        var noSigPipe: Int32 = 1
        guard setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }

        let currentFlags = fcntl(clientFD, F_GETFL)
        guard currentFlags >= 0, fcntl(clientFD, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }
    }

    private func handleConnection(_ clientFD: Int32, deadline acceptanceDeadline: UInt64) throws {
        defer { Darwin.close(clientFD) }
        let requestFrame: Data
        do {
            requestFrame = try readFrame(from: clientFD, deadline: acceptanceDeadline)
        } catch let error as BrokerSessionHostProtocolError {
            let failure = BrokerSessionHostResponse.failure(
                BrokerSessionHostFailure(code: "protocol-error", message: String(describing: error))
            )
            try writeAll(try codec.encodeResponse(failure), to: clientFD, deadline: acceptanceDeadline)
            return
        }
        let deadline = min(
            acceptanceDeadline,
            BrokerSessionHostUnixSocketTransport.requestDeadline(from: requestFrame)
                ?? acceptanceDeadline
        )
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw ServerError.timedOut(socketPath)
        }
        let responseFrame: Data
        do {
            responseFrame = try host.handle(requestFrame) {
                DispatchTime.now().uptimeNanoseconds < deadline
            }
        } catch {
            let failure = BrokerSessionHostResponse.failure(
                BrokerSessionHostFailure(code: "protocol-error", message: String(describing: error))
            )
            responseFrame = try codec.encodeResponse(failure)
        }
        try writeAll(responseFrame, to: clientFD, deadline: deadline)
    }

    private func readFrame(from fd: Int32, deadline: UInt64) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            try waitUntilReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return buffer }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw ServerError.readFailed(String(cString: strerror(errno)))
            }
            guard count <= maximumFrameSize - buffer.count else {
                throw BrokerSessionHostProtocolError.frameTooLarge(maximumBytes: maximumFrameSize)
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.last == 0x0A { return buffer }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                try waitUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw ServerError.writeFailed(String(cString: strerror(errno)))
                }
                bytesWritten += result
            }
        }
    }

    private func waitUntilReady(fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ServerError.timedOut(socketPath) }
            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
            let timeout = Int32(min(UInt64(Int32.max), remainingMilliseconds))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result == 0 { throw ServerError.timedOut(socketPath) }
            if result < 0 {
                if errno == EINTR { continue }
                throw ServerError.readFailed(String(cString: strerror(errno)))
            }
            if descriptor.revents & (events | Int16(POLLHUP)) != 0 {
                return
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw ServerError.readFailed("invalid socket descriptor")
            }
            if descriptor.revents & Int16(POLLERR) != 0 {
                return
            }
        }
    }
}

/// One-request-per-connection Unix socket client transport for
/// `BrokerSessionHostClientRuntime`.
final class BrokerSessionHostUnixSocketTransport: @unchecked Sendable {
    enum TransportError: Error, Equatable {
        case socketPathTooLong(String)
        case socketFailed(String)
        case connectFailed(String)
        case writeFailed(String)
        case readFailed(String)
        case timedOut(String)
        case emptyResponse
        case invalidRequestFrame(String)
    }

    private static let requestDeadlineKey = "_holoscapeRequestDeadlineUptimeNanoseconds"
    private let socketPath: String
    private let readChunkSize: Int
    private let requestTimeoutMilliseconds: Int

    init(
        socketPath: String,
        readChunkSize: Int = 4096,
        requestTimeoutMilliseconds: Int = 10_000
    ) {
        self.socketPath = socketPath
        self.readChunkSize = readChunkSize
        self.requestTimeoutMilliseconds = max(1, requestTimeoutMilliseconds)
    }

    func sendFrame(_ frame: Data) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(requestTimeoutMilliseconds) * 1_000_000
        let requestFrame = try Self.addingRequestDeadline(deadline, to: frame)
        let fd = try connectSocket(deadline: deadline)
        defer { Darwin.close(fd) }
        try writeAll(requestFrame, to: fd, deadline: deadline)
        shutdown(fd, SHUT_WR)
        let response = try readFrame(from: fd, deadline: deadline)
        guard !response.isEmpty else { throw TransportError.emptyResponse }
        return response
    }

    private static func addingRequestDeadline(_ deadline: UInt64, to frame: Data) throws -> Data {
        var payload = frame
        if payload.last == 0x0A {
            payload.removeLast()
        }
        do {
            guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw TransportError.invalidRequestFrame("request frame must be a JSON object")
            }
            object[requestDeadlineKey] = String(deadline)
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            encoded.append(0x0A)
            return encoded
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.invalidRequestFrame(String(describing: error))
        }
    }

    static func requestDeadline(from frame: Data) -> UInt64? {
        var payload = frame
        if payload.last == 0x0A {
            payload.removeLast()
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let rawDeadline = object[requestDeadlineKey] as? String
        else {
            return nil
        }
        return UInt64(rawDeadline)
    }

    private func connectSocket(deadline: UInt64) throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TransportError.socketPathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.socketFailed(String(cString: strerror(errno)))
        }

        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TransportError.socketFailed(message)
        }

        let currentFlags = fcntl(fd, F_GETFL)
        guard currentFlags >= 0, fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TransportError.socketFailed(message)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in pathBytes.indices {
                rawBuffer[index] = pathBytes[index]
            }
            rawBuffer[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                throw TransportError.connectFailed(message)
            }
            do {
                try waitUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
            } catch {
                Darwin.close(fd)
                throw error
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                throw TransportError.connectFailed(message)
            }
            guard socketError == 0 else {
                let message = String(cString: strerror(socketError))
                Darwin.close(fd)
                throw TransportError.connectFailed(message)
            }
        }
        return fd
    }

    private func readFrame(from fd: Int32, deadline: UInt64) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            try waitUntilReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return buffer }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.last == 0x0A { return buffer }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                try waitUntilReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw TransportError.writeFailed(String(cString: strerror(errno)))
                }
                bytesWritten += result
            }
        }
    }

    private func waitUntilReady(fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw TransportError.timedOut(socketPath) }
            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
            let timeout = Int32(min(UInt64(Int32.max), remainingMilliseconds))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result == 0 { throw TransportError.timedOut(socketPath) }
            if result < 0 {
                if errno == EINTR { continue }
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }
            if descriptor.revents & (events | Int16(POLLHUP)) != 0 {
                return
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw TransportError.readFailed("invalid socket descriptor")
            }
            if descriptor.revents & Int16(POLLERR) != 0 {
                return
            }
        }
    }
}

private final class BrokerSocketServerErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setIfEmpty(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if storedError == nil {
            storedError = error
        }
    }
}
