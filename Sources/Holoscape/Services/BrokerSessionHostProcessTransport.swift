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
        case helperClosedPipe(exitStatus: Int32?)
        case helperExited(exitStatus: Int32)
    }

    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let responseTimeoutSeconds: Int
    private let lock = NSLock()
    private var readBuffer = Data()
    private var isClosed = false

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        responseTimeoutSeconds: Int = 5
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw TransportError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputPipe.fileHandleForReading
        self.responseTimeoutSeconds = responseTimeoutSeconds
    }

    deinit {
        close()
    }

    func sendFrame(_ frame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        if !process.isRunning {
            throw TransportError.helperExited(exitStatus: process.terminationStatus)
        }

        do {
            try inputHandle.write(contentsOf: frame)
        } catch {
            throw TransportError.writeFailed(error.localizedDescription)
        }

        return try readResponseFrameLocked()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? inputHandle.close()
        try? outputHandle.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func readResponseFrameLocked() throws -> Data {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let frame = readBuffer.prefix(through: newlineIndex)
                readBuffer.removeSubrange(...newlineIndex)
                return Data(frame)
            }

            var pollFD = pollfd(fd: outputHandle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let readyCount = poll(&pollFD, 1, Int32(responseTimeoutSeconds * 1000))
            if readyCount == 0 {
                throw TransportError.responseTimedOut
            }
            if readyCount < 0 {
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let byteCount = Darwin.read(outputHandle.fileDescriptor, &bytes, bytes.count)
            if byteCount == 0 {
                if process.isRunning {
                    throw TransportError.helperClosedPipe(exitStatus: nil)
                }
                throw TransportError.helperClosedPipe(exitStatus: process.terminationStatus)
            }
            if byteCount < 0 {
                throw TransportError.readFailed(String(cString: strerror(errno)))
            }
            readBuffer.append(contentsOf: bytes.prefix(byteCount))
        }
    }
}
