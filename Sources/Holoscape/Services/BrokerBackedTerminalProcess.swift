import AppKit
import SwiftTerm

/// TerminalProcess implementation backed by Holoscape's broker runtime instead
/// of SwiftTerm's LocalProcessTerminalView owning the child process directly.
///
/// This is the opt-in bridge for #7168: SwiftTerm remains the renderer, while
/// process input/output/resize flow through BrokerSessionCoordinator and the
/// native PTY runtime behind it.
@MainActor
final class BrokerBackedTerminalProcess: TerminalProcess {
    enum TerminalError: Error, Equatable {
        case startFailed(String)
        case sessionNotStarted
    }

    private let channelID: UUID
    private let channelType: ChannelType
    private let label: String?
    private let environmentProfile: BrokerEnvironmentProfile
    private let coordinator: any BrokerSessionCoordinating
    private let terminalView: HoloscapeTerminalView
    private var outputHandler: (() -> Void)?
    private var userInputHandler: ((ArraySlice<UInt8>) -> Void)?
    private var terminationHandler: ((Int32?) -> Void)?
    private var outputTimer: Timer?
    private(set) var brokerSessionID: BrokerSessionID?
    private var didNotifyTermination = false

    var terminalContentView: NSView { terminalView }
    var currentGridSize: TerminalGridSize { terminalView.currentGridSize }

    init(
        channelID: UUID,
        channelType: ChannelType,
        label: String?,
        environmentProfile: BrokerEnvironmentProfile,
        coordinator: any BrokerSessionCoordinating = BrokerSessionCoordinator(runtime: NativePTYBrokerSessionRuntime()),
        terminalView: HoloscapeTerminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.label = label
        self.environmentProfile = environmentProfile
        self.coordinator = coordinator
        self.terminalView = terminalView

        terminalView.setUserInputHandler { [weak self] data in
            guard let self else { return }
            self.userInputHandler?(data)
            self.send(Array(data))
        }
    }

    func startProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        let request = BrokerSessionLaunchRequest(
            command: executable,
            arguments: args,
            workingDirectory: currentDirectory,
            environmentProfile: environmentProfile,
            initialSize: currentGridSize
        )

        do {
            let record = try coordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelID
            )
            brokerSessionID = record.id
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
            assertionFailure("Broker-backed terminal start failed: \(error)")
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let brokerSessionID else {
            assertionFailure("Broker-backed terminal input before session start")
            return
        }
        do {
            try coordinator.sendInput(brokerSessionID, bytes: bytes)
            pollOutputOnce()
        } catch {
            assertionFailure("Broker-backed terminal input failed: \(error)")
        }
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        outputHandler = handler
        if handler == nil {
            outputTimer?.invalidate()
            outputTimer = nil
        } else if brokerSessionID != nil {
            startOutputPump()
        }
    }

    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?) {
        userInputHandler = handler
    }

    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {
        terminationHandler = handler
    }

    func lastLines(_ count: Int) -> [String] {
        terminalView.lastLines(count)
    }

    func pollOutputOnce() {
        guard let brokerSessionID else { return }
        do {
            let data = try coordinator.readAvailableOutput(brokerSessionID)
            if !data.isEmpty {
                let bytes = Array(data)
                terminalView.feed(byteArray: bytes[...])
                outputHandler?()
            }
            try notifyTerminationIfNeeded(for: brokerSessionID)
        } catch {
            assertionFailure("Broker-backed terminal output read failed: \(error)")
        }
    }

    func resizeToCurrentGrid() {
        guard let brokerSessionID else {
            assertionFailure("Broker-backed terminal resize before session start")
            return
        }
        do {
            try coordinator.resize(brokerSessionID, size: currentGridSize)
        } catch {
            assertionFailure("Broker-backed terminal resize failed: \(error)")
        }
    }

    private func startOutputPump() {
        outputTimer?.invalidate()
        outputTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOutputOnce()
            }
        }
    }

    private func notifyTerminationIfNeeded(for brokerSessionID: BrokerSessionID) throws {
        guard !didNotifyTermination else { return }
        guard try !coordinator.isRunning(brokerSessionID) else { return }
        let exitCode = try coordinator.terminationStatus(brokerSessionID)
        didNotifyTermination = true
        outputTimer?.invalidate()
        outputTimer = nil
        if let exitCode {
            _ = try coordinator.exit(brokerSessionID, exitCode: exitCode)
        } else {
            _ = try coordinator.markErrored(brokerSessionID)
        }
        terminationHandler?(exitCode)
    }
}
