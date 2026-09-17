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
    }

    private let socketPath: String
    private let host: BrokerSessionHost
    private let codec: BrokerSessionHostCodec
    private let backlog: Int32
    private let readChunkSize: Int

    init(
        socketPath: String,
        host: BrokerSessionHost,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        backlog: Int32 = 16,
        readChunkSize: Int = 4096
    ) {
        self.socketPath = socketPath
        self.host = host
        self.codec = codec
        self.backlog = backlog
        self.readChunkSize = readChunkSize
    }

    func run(maxConnections: Int? = nil) throws {
        let serverFD = try makeListeningSocket()
        defer {
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
            defer { }
            try handleConnection(clientFD)
            handledConnections += 1
        }
    }

    private func makeListeningSocket() throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError.socketPathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.socketFailed(String(cString: strerror(errno)))
        }

        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.socketPathHasReachableBroker(socketPath) {
                Darwin.close(fd)
                throw ServerError.bindFailed("socket path already has a reachable broker: \(socketPath)")
            }
            unlink(socketPath)
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

    static func socketPathHasReachableBroker(_ socketPath: String) -> Bool {
        do {
            let codec = BrokerSessionHostCodec()
            let probeFrame = try codec.encodeRequest(.listSessions)
            let responseFrame = try BrokerSessionHostUnixSocketTransport(socketPath: socketPath).sendFrame(probeFrame)
            _ = try codec.decodeResponse(responseFrame)
            return true
        } catch {
            return false
        }
    }

    private func handleConnection(_ clientFD: Int32) throws {
        defer { Darwin.close(clientFD) }
        let requestFrame = try readFrame(from: clientFD)
        let responseFrame: Data
        do {
            responseFrame = try host.handle(requestFrame)
        } catch {
            let failure = BrokerSessionHostResponse.failure(
                BrokerSessionHostFailure(code: "protocol-error", message: String(describing: error))
            )
            responseFrame = try codec.encodeResponse(failure)
        }
        try writeAll(responseFrame, to: clientFD)
    }

    private func readFrame(from fd: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return buffer }
            if count < 0 {
                if errno == EINTR { continue }
                throw ServerError.readFailed(String(cString: strerror(errno)))
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.last == 0x0A { return buffer }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ServerError.writeFailed(String(cString: strerror(errno)))
                }
                bytesWritten += result
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
        case emptyResponse
    }

    private let socketPath: String
    private let readChunkSize: Int

    init(socketPath: String, readChunkSize: Int = 4096) {
        self.socketPath = socketPath
        self.readChunkSize = readChunkSize
    }

    func sendFrame(_ frame: Data) throws -> Data {
        let fd = try connectSocket()
        defer { Darwin.close(fd) }
        try writeAll(frame, to: fd)
        shutdown(fd, SHUT_WR)
        let response = try readFrame(from: fd)
        guard !response.isEmpty else { throw TransportError.emptyResponse }
        return response
    }

    private func connectSocket() throws -> Int32 {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TransportError.socketPathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.socketFailed(String(cString: strerror(errno)))
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
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TransportError.connectFailed(message)
        }
        return fd
    }

    private func readFrame(from fd: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 { return buffer }
            if count < 0 {
                if errno == EINTR { continue }
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if buffer.last == 0x0A { return buffer }
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw TransportError.writeFailed(String(cString: strerror(errno)))
                }
                bytesWritten += result
            }
        }
    }
}
