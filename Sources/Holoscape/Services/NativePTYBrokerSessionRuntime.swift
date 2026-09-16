import Darwin
import Foundation

/// In-process native PTY runtime for the first broker-backed local sessions.
///
/// This is still not the final out-of-process survival broker. It deliberately
/// owns a real PTY/process pair behind `BrokerSessionRuntime`, which lets the
/// coordinator facade exercise launch, input/output, resize, and termination
/// semantics before the process host is moved outside the UI app.
final class NativePTYBrokerSessionRuntime: BrokerSessionRuntime, @unchecked Sendable {
    enum RuntimeError: Error, Equatable {
        case duplicateSession(BrokerSessionID)
        case missingSession(BrokerSessionID)
        case openPTYFailed(errno: Int32)
        case launchFailed(String)
        case resizeFailed(errno: Int32)
        case exitCodeMismatch(expected: Int32, observed: Int32)
        case unsupportedEnvironmentProfile(BrokerEnvironmentProfile, reason: String)
    }

    private final class Session: @unchecked Sendable {
        let process: Process
        let masterHandle: FileHandle
        let lock = NSLock()
        var output = Data()
        var terminationStatus: Int32?

        init(process: Process, masterHandle: FileHandle) {
            self.process = process
            self.masterHandle = masterHandle
        }

        func appendOutput(_ data: Data) {
            lock.lock()
            output.append(data)
            lock.unlock()
        }

        func readOutput() -> Data {
            lock.lock()
            let snapshot = output
            output.removeAll(keepingCapacity: true)
            lock.unlock()
            return snapshot
        }

        func writeInput(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            try masterHandle.write(contentsOf: data)
        }

        func markTerminated(_ status: Int32) {
            lock.lock()
            terminationStatus = status
            lock.unlock()
        }

        func observedTerminationStatus() -> Int32? {
            lock.lock()
            let status = terminationStatus
            lock.unlock()
            return status
        }
    }

    private let lock = NSLock()
    private var sessions: [BrokerSessionID: Session] = [:]

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        lock.lock()
        defer { lock.unlock() }

        if sessions[id] != nil {
            throw RuntimeError.duplicateSession(id)
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(
            ws_row: UInt16(request.initialSize.rows),
            ws_col: UInt16(request.initialSize.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw RuntimeError.openPTYFailed(errno: errno)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.command)
        process.arguments = request.arguments
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.environment = try environment(for: request.environmentProfile)

        let slaveRead = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let slaveWrite = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let slaveError = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        process.standardInput = slaveRead
        process.standardOutput = slaveWrite
        process.standardError = slaveError

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let session = Session(process: process, masterHandle: masterHandle)
        process.terminationHandler = { [weak session] process in
            session?.markTerminated(process.terminationStatus)
        }
        masterHandle.readabilityHandler = { [weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            session?.appendOutput(data)
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            masterHandle.closeFile()
            slaveRead.closeFile()
            slaveWrite.closeFile()
            slaveError.closeFile()
            throw RuntimeError.launchFailed(error.localizedDescription)
        }

        slaveRead.closeFile()
        slaveWrite.closeFile()
        slaveError.closeFile()
        sessions[id] = session
    }

    func detachSession(id: BrokerSessionID) throws {
        _ = try session(for: id)
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        _ = try session(for: id)
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        let session = try removeSession(id)
        let isRunning = session.process.isRunning
        let observedExitCode = isRunning ? nil : Optional(session.process.terminationStatus)
        let hasMismatchedExitCode = exitCode.map { expected in
            observedExitCode.map { observed in observed != expected } ?? false
        } ?? false
        close(session)
        if let exitCode, let observedExitCode, hasMismatchedExitCode {
            throw RuntimeError.exitCodeMismatch(expected: exitCode, observed: observedExitCode)
        }
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        close(try removeSession(id))
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try session(for: id).writeInput(Data(bytes))
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try session(for: id).readOutput()
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        let session = try session(for: id)
        var windowSize = winsize(
            ws_row: UInt16(size.rows),
            ws_col: UInt16(size.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(session.masterHandle.fileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw RuntimeError.resizeFailed(errno: errno)
        }
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        try session(for: id).process.isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let session = try session(for: id)
        if let status = session.observedTerminationStatus() {
            return status
        }
        return session.process.isRunning ? nil : session.process.terminationStatus
    }

    private func close(_ session: Session) {
        session.masterHandle.readabilityHandler = nil
        if session.process.isRunning {
            session.process.terminate()
            session.process.waitUntilExit()
        }
        session.masterHandle.closeFile()
    }

    private func session(for id: BrokerSessionID) throws -> Session {
        lock.lock()
        let session = sessions[id]
        lock.unlock()
        guard let session else {
            throw RuntimeError.missingSession(id)
        }
        return session
    }

    private func removeSession(_ id: BrokerSessionID) throws -> Session {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        guard let session else {
            throw RuntimeError.missingSession(id)
        }
        return session
    }

    private func environment(for profile: BrokerEnvironmentProfile) throws -> [String: String] {
        switch profile {
        case .shell:
            var environment = ProcessInfo.processInfo.environment
            // Keep zsh's Apple Terminal-compatible OSC 7 directory updates working
            // while shell sessions are broker-owned instead of SwiftTerm-owned.
            environment["TERM_PROGRAM"] = "Apple_Terminal"
            return environment
        case .agentOAuth:
            // Match AgentChannelController's clean OAuth environment. Inheriting
            // the UI process environment here could silently leak API keys into
            // subscription-billed agent sessions.
            return AuthEnvironmentBuilder.buildEnvironment(
                for: .oauth,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        case .agentAPI:
            // The registry intentionally stores only a profile name, not raw
            // secrets. Until the broker has a Keychain-backed env recipe, API-key
            // sessions must fail loudly instead of launching without auth or
            // inheriting secrets from the UI process.
            throw RuntimeError.unsupportedEnvironmentProfile(
                profile,
                reason: "agent API broker sessions require a Keychain-backed environment recipe"
            )
        case .ssh:
            let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
            return ProcessInfo.processInfo.environment.filter { allowedKeys.contains($0.key) }
        }
    }
}
