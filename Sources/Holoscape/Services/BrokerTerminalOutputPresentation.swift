import AppKit
import SwiftTerm

/// Owns broker-output presentation state separately from session lifecycle.
/// SwiftTerm mutation remains main-actor-bound, while delivery handshakes use
/// thread-safe gates so the serial read lane never acknowledges unseen bytes.
@MainActor
final class BrokerTerminalOutputPresentation {
    private let terminalView: HoloscapeTerminalView
    private let deliveryTimeout: TimeInterval
    private let deliveryGate = BrokerOutputDeliveryGate()
    private var outputHandler: (() -> Void)?
    private var nextDeliveryGeneration: UInt = 0
    /// Identifies the terminal-view ownership window allowed to consume broker
    /// output. A queued main-actor delivery must still hold this exact lease;
    /// matching the broker ID alone is insufficient because teardown deliberately
    /// preserves that ID for later reattach.
    private(set) var activeDeliveryGeneration: UInt?
    private(set) var activeHandoffGeneration: UInt?
    private(set) var lastScrollbackReplay: ScrollbackReplay?
    /// The broker session whose output generation is already represented by the
    /// current terminal view.
    var presentedBrokerSessionID: BrokerSessionID?
    /// Bytes rendered before acknowledgement failed. A retry strips this exact
    /// prefix while still acknowledging the full transactional generation.
    private var presentedUnacknowledgedOutput: (sessionID: BrokerSessionID, data: Data)?
    var hasOutputHandler: Bool { outputHandler != nil }

    init(
        terminalView: HoloscapeTerminalView,
        deliveryTimeout: TimeInterval
    ) {
        self.terminalView = terminalView
        self.deliveryTimeout = deliveryTimeout
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        outputHandler = handler
    }

    func clearReplay() {
        lastScrollbackReplay = nil
    }

    func presentReplay(_ replay: ScrollbackReplay) {
        lastScrollbackReplay = replay
        guard !replay.data.isEmpty else { return }
        feedStatusLine(replayStatus(for: replay))
        terminalView.feed(byteArray: Array(replay.data)[...])
        outputHandler?()
    }

    func presentReplayFailure(_ description: String, sessionID: BrokerSessionID) {
        lastScrollbackReplay = nil
        feedStatusLine(
            "Holoscape reattached the live session, but could not restore its persisted scrollback (\(description)). The corrupted tail was skipped; new output will continue normally."
        )
        outputHandler?()
        NSLog("Broker-backed terminal scrollback replay failed for \(sessionID.rawValue): \(description)")
    }

    func render(_ data: Data) {
        guard !data.isEmpty else { return }
        terminalView.feed(byteArray: Array(data)[...])
        outputHandler?()
    }

    func retainPresentedUnacknowledgedOutput(_ data: Data, for sessionID: BrokerSessionID) {
        guard !data.isEmpty else { return }
        presentedUnacknowledgedOutput = (sessionID, data)
    }

    @discardableResult
    func beginDeliveryOwnership() -> UInt {
        nextDeliveryGeneration &+= 1
        activeDeliveryGeneration = nextDeliveryGeneration
        return nextDeliveryGeneration
    }

    func revokeDeliveryOwnership() {
        activeDeliveryGeneration = nil
        stopHandoff()
    }

    func beginHandoff() -> UInt {
        let generation = deliveryGate.open()
        activeHandoffGeneration = generation
        return generation
    }

    func stopHandoff() {
        activeHandoffGeneration = nil
        deliveryGate.close()
    }

    func makeSampleHandler(
        deliveryGeneration: UInt,
        handoffGeneration: UInt,
        isAuthorized: @escaping @MainActor (BrokerSessionID) -> Bool,
        onFailure: @escaping @MainActor (BrokerSessionID, Error) -> Void
    ) -> @Sendable (BrokerSessionID, Data) -> Bool {
        let deliveryTimeout = self.deliveryTimeout
        let deliveryGate = self.deliveryGate
        return { [weak self] id, data in
            guard !data.isEmpty else { return true }
            let acceptance = BrokerOutputDeliveryAcceptance()
            guard deliveryGate.install(acceptance, generation: handoffGeneration) else {
                return false
            }
            defer { deliveryGate.remove(acceptance) }
            DispatchQueue.main.async { [weak self] in
                defer { acceptance.signalCompletion() }
                guard let self,
                      self.activeDeliveryGeneration == deliveryGeneration,
                      isAuthorized(id),
                      acceptance.beginDelivery() else { return }
                var dataToRender = data
                if let presented = self.presentedUnacknowledgedOutput,
                   presented.sessionID == id {
                    if data.starts(with: presented.data) {
                        dataToRender = Data(data.dropFirst(presented.data.count))
                    }
                    self.presentedUnacknowledgedOutput = nil
                }
                self.render(dataToRender)
                acceptance.finishDelivery()
            }
            if acceptance.wait(timeout: deliveryTimeout) == .timedOut,
               acceptance.cancelIfPending() {
                DispatchQueue.main.async {
                    onFailure(id, BrokerOutputDeliveryFailure.timedOut)
                }
                return false
            }
            if acceptance.isDelivering {
                acceptance.wait()
            }
            return acceptance.wasAccepted
        }
    }

    private func replayStatus(for replay: ScrollbackReplay) -> String {
        let source: String
        switch replay.source {
        case .liveBrokerMemory:
            source = "live broker memory"
        case .persistedDiskTail:
            source = "persisted disk scrollback"
        case .unknown:
            source = "broker scrollback"
        }
        return "Holoscape restored \(replay.data.count) bytes from \(source). Older output beyond the \(replay.maxBytes)-byte replay cap is not retained."
    }

    private func feedStatusLine(_ message: String) {
        terminalView.feed(byteArray: Array("\r\n[\(message)]\r\n".utf8)[...])
    }
}

final class BrokerOutputDeliveryAcceptance: @unchecked Sendable {
    private enum State {
        case pending
        case delivering
        case accepted
        case cancelled
    }

    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var state = State.pending
    private var completionSignaled = false

    func beginDelivery() -> Bool {
        lock.withLock {
            guard state == .pending else { return false }
            state = .delivering
            return true
        }
    }

    func finishDelivery() {
        lock.withLock {
            if state == .delivering {
                state = .accepted
            }
        }
    }

    func cancelIfPending() -> Bool {
        let cancelled = lock.withLock { () -> Bool in
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
        if cancelled { signalCompletion() }
        return cancelled
    }

    func signalCompletion() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !completionSignaled else { return false }
            completionSignaled = true
            return true
        }
        if shouldSignal { completion.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        completion.wait(timeout: .now() + timeout)
    }

    func wait() {
        completion.wait()
    }

    var isDelivering: Bool {
        lock.withLock { state == .delivering }
    }

    var wasAccepted: Bool {
        lock.withLock { state == .accepted }
    }
}

final class BrokerOutputDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt = 0
    private var activeGeneration: UInt?
    private var current: BrokerOutputDeliveryAcceptance?

    func open() -> UInt {
        let result = lock.withLock { () -> (generation: UInt, previous: BrokerOutputDeliveryAcceptance?) in
            nextGeneration &+= 1
            let previous = current
            activeGeneration = nextGeneration
            current = nil
            return (nextGeneration, previous)
        }
        _ = result.previous?.cancelIfPending()
        return result.generation
    }

    func install(_ acceptance: BrokerOutputDeliveryAcceptance, generation: UInt) -> Bool {
        let result = lock.withLock { () -> (installed: Bool, previous: BrokerOutputDeliveryAcceptance?) in
            guard activeGeneration == generation else { return (false, nil) }
            let previous = current
            current = acceptance
            return (true, previous)
        }
        guard result.installed else {
            _ = acceptance.cancelIfPending()
            return false
        }
        _ = result.previous?.cancelIfPending()
        return true
    }

    func remove(_ acceptance: BrokerOutputDeliveryAcceptance) {
        lock.withLock {
            if current === acceptance {
                current = nil
            }
        }
    }

    func close() {
        let acceptance = lock.withLock { () -> BrokerOutputDeliveryAcceptance? in
            activeGeneration = nil
            let acceptance = current
            current = nil
            return acceptance
        }
        _ = acceptance?.cancelIfPending()
    }
}

private enum BrokerOutputDeliveryFailure: Error, CustomStringConvertible {
    case timedOut

    var description: String {
        "Broker output delivery to the terminal timed out"
    }
}
