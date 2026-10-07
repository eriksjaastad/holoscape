import AppKit
import SwiftTerm

@MainActor
class AgentChannelController: NSObject, ChannelController, LocalProcessTerminalViewDelegate {
    let channelId: UUID
    let channelType: ChannelType
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let terminal: TerminalProcess
    private let brokerSessionCoordinator: (any BrokerSessionCoordinating)?
    private(set) var brokerSessionID: BrokerSessionID?
    var pendingExitedOutputRetirement: BrokerExitedOutputRetirement? {
        terminal.pendingExitedOutputRetirement
    }
    /// Broker session this tab could not reattach because the broker no longer
    /// owns it. Retained (and persisted) while the tab is stale so the recreate
    /// guidance and the tab/session association survive relaunch/restore.
    private(set) var staleBrokerSessionID: BrokerSessionID?
    private let authType: AgentAuthType
    private let workingDirectory: URL?
    private let userLabel: String?
    private(set) var customDisplayLabel: String?
    private let command: String
    private var detectedRole: String?
    let instanceNumber: Int?
    private let useRawLabel: Bool
    private(set) var activatedAt: Date?
    private(set) var lastInteractionAt: Date = Date()
    private var persistentStatesBySource: [PersistentChannelStateSource: PersistentChannelState] = [:]
    private(set) var adapterPersistentState: PersistentChannelState? {
        get { persistentStatesBySource[.agentAdapter] }
        set { persistentStatesBySource[.agentAdapter] = newValue }
    }
    private(set) var terminalOutputPersistentState: PersistentChannelState? {
        get { persistentStatesBySource[.terminalOutput] }
        set { persistentStatesBySource[.terminalOutput] = newValue }
    }
    private(set) var adapterOwnerToken = UUID().uuidString
    private var requiresAdapterOwnerToken = true
    private var lastStartFailureKind: TerminalStartFailureKind?
    private var pendingRestoredAttention: (state: PersistentChannelState, brokerSessionID: BrokerSessionID)?
    private var lastSessionFailureState: PersistentChannelState?
    private(set) var brokerSessionPersistenceIsAuthoritative = false

    var persistentState: PersistentChannelState {
        if let lastSessionFailureState { return lastSessionFailureState }
        let runtimeState = PersistentChannelState.fromRuntimeState(
            state,
            source: staleBrokerSessionID == nil ? .processLifecycle : .brokerRegistry,
            recoveryAction: recoveryAction
        )
        let sourceStates = persistentStatesBySource.values.filter { state in
            // Supplemental healthy/busy plugin presentation must never make a
            // process-less channel look usable. Attention states remain visible
            // so plugin failures are not silently discarded on process teardown.
            self.state == .active || state.source != .plugin || state.kind.requiresOperatorAttention
        }
        return ([runtimeState] + sourceStates)
            .max { lhs, rhs in
                if lhs.kind.displayPriority != rhs.kind.displayPriority {
                    return lhs.kind.displayPriority < rhs.kind.displayPriority
                }
                return Self.sourceDisplayPriority(lhs.source) < Self.sourceDisplayPriority(rhs.source)
            }
            ?? runtimeState
    }

    private static func sourceDisplayPriority(_ source: PersistentChannelStateSource) -> Int {
        switch source {
        case .brokerRegistry: return 60
        case .processLifecycle: return 50
        case .terminalOutput: return 40
        case .agentAdapter: return 30
        case .userAction: return 20
        case .plugin: return 10
        }
    }

    var notificationDirectoryPath: String? {
        workingDirectory?.path
    }

    var persistedWorkingDirectory: String? {
        workingDirectory?.path
    }

    var persistedCommand: String {
        command
    }

    var persistedUseRawLabel: Bool {
        useRawLabel
    }

    var displayBaseLabel: String {
        if let customDisplayLabel {
            return customDisplayLabel
        }
        return ChannelGitBranchLabel.decorate(undecoratedDisplayBaseLabel, workingDirectory: workingDirectory?.path)
    }

    func setCustomDisplayLabel(_ label: String?) {
        customDisplayLabel = ChannelCustomDisplayLabel.normalized(label)
    }

    var displayLabel: String {
        let base = displayBaseLabel
        if customDisplayLabel != nil {
            return base
        }
        if let num = instanceNumber {
            let undecorated = undecoratedDisplayBaseLabel
            if useRawLabel {
                return "\(base) \(num)"
            }
            return base == undecorated ? "\(base)\(num)" : "\(base) \(num)"
        }
        return base
    }

    private var undecoratedDisplayBaseLabel: String {
        if useRawLabel, let label = userLabel {
            return label
        }
        if let role = detectedRole ?? userLabel {
            let short = RoleDetector.shortLabel(for: role)
            if role.lowercased().contains("floor manager"),
               let dir = workingDirectory {
                return "\(short)-\(dir.lastPathComponent)"
            }
            return short
        }
        return "Agent"
    }

    var tabIdentityIndicator: ChannelTabIdentityIndicator? {
        ChannelTabIdentityIndicator.detect(from: [command, userLabel, detectedRole])
    }

    var contentView: NSView { terminal.terminalContentView }

    var recoveryAction: ChannelRecoveryAction? {
        guard state == .disconnected || state == .stale else { return nil }
        switch lastStartFailureKind {
        case .brokerHostUnavailable:
            return .retryBrokerHost
        case .brokerSessionStale:
            return .recreateBrokerSession
        case .failed, .none:
            return state == .disconnected ? .reconnect : nil
        }
    }

    static func brokerBacked(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false,
        command: String = "claude",
        existingBrokerSessionID: BrokerSessionID? = nil,
        pendingExitedOutputRetirement: BrokerExitedOutputRetirement? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil,
        coordinator: (any BrokerSessionCoordinating)? = nil
    ) -> AgentChannelController {
        let environmentProfile: BrokerEnvironmentProfile
        let channelType: ChannelType
        switch authType {
        case .oauth:
            environmentProfile = .agentOAuth
            channelType = .agentDirect
        case .apiKey, .deferredAPIKey:
            environmentProfile = .agentAPI
            channelType = .agentAPI
        }
        let terminal = BrokerBackedTerminalProcess(
            channelID: id,
            channelType: channelType,
            label: userLabel,
            environmentProfile: environmentProfile,
            existingBrokerSessionID: existingBrokerSessionID,
            pendingExitedOutputRetirement: pendingExitedOutputRetirement,
            coordinator: coordinator ?? BrokerSessionCoordinator(runtime: BrokerSessionHostClientRuntime.currentExecutableHostRuntime())
        )
        return AgentChannelController(
            id: id,
            authType: authType,
            workingDirectory: workingDirectory,
            userLabel: userLabel,
            instanceNumber: instanceNumber,
            useRawLabel: useRawLabel,
            command: command,
            terminal: terminal,
            brokerSessionCoordinator: nil,
            restoredStaleBrokerSessionID: restoredStaleBrokerSessionID
        )
    }

    init(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false,
        command: String = "claude",
        terminal: TerminalProcess? = nil,
        brokerSessionCoordinator: (any BrokerSessionCoordinating)? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil
    ) {
        self.channelId = id
        self.authType = authType
        self.channelType = {
            switch authType {
            case .oauth: return .agentDirect
            case .apiKey, .deferredAPIKey: return .agentAPI
            }
        }()
        self.workingDirectory = workingDirectory
        self.userLabel = userLabel
        self.command = command
        self.instanceNumber = instanceNumber
        self.useRawLabel = useRawLabel
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.brokerSessionCoordinator = brokerSessionCoordinator
        super.init()
        if let terminalView = self.terminal as? LocalProcessTerminalView {
            terminalView.processDelegate = self
        }
        self.terminal.setUserInputHandler { [weak self] _ in
            guard let self else { return }
            self.recordUserInteraction()
            self.clearTerminalOutputPersistentState()
        }
        self.terminal.setSessionFailureHandler { [weak self] failure in
            self?.handleSessionFailure(failure)
        }
        self.terminal.setStartCompletionHandler { [weak self] in
            self?.finishActivation()
        }
        self.terminal.setTerminationHandler { [weak self] exitCode in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            if self.brokerSessionCoordinator == nil {
                self.brokerSessionID = self.terminal.brokerOwnedSessionID
                self.brokerSessionPersistenceIsAuthoritative = true
            }
            self.transitionToDisconnected(invalidateAdapterOwner: true)
        }
        // Output notifications handled by Claude Code hooks (idle_prompt, permission_prompt)
        // rangeChanged is too noisy for unread detection (fires on cursor blinks, redraws)

        // Detect role from CLAUDE.md if working directory provided
        if let dir = workingDirectory {
            self.detectedRole = RoleDetector.detectRole(in: dir)
        }

        // A tab whose broker session the broker no longer owns comes back stale
        // with the same recreate guidance it showed before the app quit. It does
        // not activate: starting a replacement here would be a silent substitute
        // for the recovery action the guidance promises.
        if let restoredStaleBrokerSessionID {
            self.staleBrokerSessionID = restoredStaleBrokerSessionID
            self.lastStartFailureKind = .brokerSessionStale
            self.state = .stale
        }
    }

    func sendInput(_ text: String) {
        guard state == .active else { return }
        recordUserInteraction()
        clearTerminalOutputPersistentState()
        commandHistory.add(text)
        let bytes = Array((text + "\n").utf8)
        terminal.send(bytes)
    }

    func activate() {
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)

        // Retirement-only restore must not depend on credentials, but any later
        // replacement launch resolves the API key again and fails closed.
        let envPairs: [String]?
        if case .deferredAPIKey = authType,
           terminal.pendingExitedOutputRetirement != nil {
            envPairs = nil
        } else {
            let launchAuthType: AgentAuthType
            do {
                if case .deferredAPIKey = authType {
                    launchAuthType = try AgentAPIKeyResolver().authType()
                } else {
                    launchAuthType = authType
                }
            } catch {
                NSLog("Agent terminal start refused because API-key auth is unavailable: \(error)")
                lastStartFailureKind = .failed
                transitionToDisconnected()
                return
            }
            var env = AuthEnvironmentBuilder.buildEnvironment(
                for: launchAuthType,
                workingDirectory: workingDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            )
            env["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN"] = adapterOwnerToken
            envPairs = env.map { "\($0.key)=\($0.value)" }
        }

        let launch = Self.launchInvocation(for: command)

        terminal.setOutputHandler { [weak self] in
            guard let self else { return }
            self.refreshTerminalOutputPersistentState()
            self.delegate?.channelDidReceiveOutput(self)
        }

        guard recordBrokerStart(
            command: launch.executable,
            arguments: launch.args,
            environmentProfile: brokerEnvironmentProfile,
            label: userLabel,
            workingDirectory: workingDirectory?.path
        ) else {
            transitionToDisconnected()
            return
        }

        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: envPairs,
            execName: launch.execName,
            currentDirectory: workingDirectory?.path
        )
        if terminal.completesStartAsynchronously { return }
        finishActivation()
    }

    private func finishActivation() {
        if let sessionFailure = terminal.sessionFailure {
            pendingRestoredAttention = nil
            handleSessionFailure(sessionFailure)
            return
        }
        if let startFailure = terminal.startFailureDescription {
            pendingRestoredAttention = nil
            NSLog("Agent terminal start failed: \(startFailure)")
            if brokerSessionCoordinator == nil, terminal.brokerOwnedSessionID == nil {
                brokerSessionID = nil
                brokerSessionPersistenceIsAuthoritative = true
            }
            let failedState = applyBrokerFailure(kind: terminal.startFailureKind)
            state = failedState
            delegate?.channelStateDidChange(self, to: failedState)
            return
        }
        if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
            brokerSessionID = terminalBrokerSessionID
            if let restoredOwnerToken = terminal.agentStatusOwnerToken,
               !restoredOwnerToken.isEmpty {
                adapterOwnerToken = restoredOwnerToken
                requiresAdapterOwnerToken = true
            } else {
                // Records written before owner-token persistence can only prove
                // ownership through an unscoped legacy hook. Never adopt an
                // arbitrary scoped token after reattach.
                requiresAdapterOwnerToken = false
            }
        }
        brokerSessionPersistenceIsAuthoritative = true
        lastSessionFailureState = nil
        lastStartFailureKind = nil
        staleBrokerSessionID = nil
        state = .active
        let now = Date()
        activatedAt = now
        recordUserInteraction(at: now)
        delegate?.channelStateDidChange(self, to: .active)
        if let pendingRestoredAttention {
            self.pendingRestoredAttention = nil
            if brokerSessionID == pendingRestoredAttention.brokerSessionID {
                restorePersistentAttentionState(pendingRestoredAttention.state)
            }
        }
    }

    func recordUserInteraction(at date: Date = Date()) {
        lastInteractionAt = date
    }

    private func refreshTerminalOutputPersistentState() {
        let detected = TerminalOutputStatusDetector.persistentState(fromLastLines: terminal.lastLines(40))
        guard detected != terminalOutputPersistentState else { return }
        terminalOutputPersistentState = detected
        delegate?.channelStateDidChange(self, to: state)
    }

    private func clearTerminalOutputPersistentState() {
        guard terminalOutputPersistentState != nil else { return }
        terminalOutputPersistentState = nil
        delegate?.channelStateDidChange(self, to: state)
    }

    func deactivate() {
        deactivate(completion: {})
    }

    func deactivate(completion: @escaping @MainActor () -> Void) {
        terminal.setOutputHandler(nil)
        terminal.detachBrokerSession(completion: completion)
        recordBrokerDetach()
        transitionToDisconnected()
    }

    func retry() {
        activate()
    }

    func applyPersistentState(_ state: PersistentChannelState) {
        if state.source == .agentAdapter {
            // Internal producers and persisted restore already target this exact
            // controller. Only the explicit owner-token overload is an external
            // hook trust boundary.
            guard self.state == .active else { return }
            adapterPersistentState = state
            delegate?.channelStateDidChange(self, to: self.state)
            return
        }
        persistentStatesBySource[state.source] = state
        delegate?.channelStateDidChange(self, to: self.state)
    }

    func acceptsAdapterEvent(ownerToken: String?) -> Bool {
        guard state == .active else { return false }
        if requiresAdapterOwnerToken {
            return ownerToken == adapterOwnerToken
        }
        return ownerToken == nil
    }

    func applyPersistentState(_ state: PersistentChannelState, adapterOwnerToken ownerToken: String?) {
        if state.source == .agentAdapter {
            // Adapter events describe only the currently running agent process.
            // Delayed hooks from an exited process must not overwrite truthful
            // disconnected/stale lifecycle state.
            guard acceptsAdapterEvent(ownerToken: ownerToken) else { return }
            adapterPersistentState = state
            delegate?.channelStateDidChange(self, to: self.state)
            return
        }
        // Each producer owns and replaces only its own slot. This lets a plugin
        // report recovery without erasing agent state, and lets process teardown
        // clear process-owned attention without deleting plugin-owned failures.
        persistentStatesBySource[state.source] = state
        delegate?.channelStateDidChange(self, to: self.state)
    }

    /// Restore durable agent attention only when a live process can still own
    /// that state. Preserve the source-specific clearing contract: terminal
    /// prompts clear on user input, while adapter state remains adapter-owned.
    func restorePersistentAttentionState(_ restoredState: PersistentChannelState) {
        guard state == .active else { return }
        switch (restoredState.source, restoredState.kind) {
        case (.terminalOutput, .needsApproval),
             (.terminalOutput, .error),
             (.agentAdapter, .needsApproval),
             (.agentAdapter, .error),
             (.agentAdapter, .stale):
            break
        case (.terminalOutput, _),
             (.agentAdapter, _),
             (.processLifecycle, _),
             (.brokerRegistry, _),
             (.userAction, _),
             (.plugin, _):
            return
        }
        guard restoredState.kind.displayPriority >= persistentState.kind.displayPriority else { return }

        switch restoredState.source {
        case .terminalOutput:
            terminalOutputPersistentState = restoredState
            delegate?.channelStateDidChange(self, to: state)
        case .agentAdapter:
            // This state came from this tab's persisted metadata rather than an
            // external hook request, so process-owner validation does not apply.
            adapterPersistentState = restoredState
            delegate?.channelStateDidChange(self, to: state)
        case .processLifecycle, .brokerRegistry, .userAction, .plugin:
            break
        }
    }

    /// Preserve saved attention while production broker reattach is still
    /// completing off-main. Apply it only after the same durable process
    /// generation has successfully re-established ownership.
    func restorePersistentAttentionState(
        _ restoredState: PersistentChannelState,
        afterReattaching brokerSessionID: BrokerSessionID
    ) {
        if state == .active, self.brokerSessionID == brokerSessionID {
            restorePersistentAttentionState(restoredState)
        } else if state == .connecting {
            pendingRestoredAttention = (restoredState, brokerSessionID)
        }
    }

    static func launchInvocation(for command: String) -> (executable: String, args: [String], execName: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("/usr/bin/env", ["claude"], "claude")
        }

        if trimmed.contains(where: { $0.isWhitespace }) {
            return ("/bin/zsh", ["-lc", "exec \(trimmed)"], "zsh")
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return (expanded, [], URL(fileURLWithPath: expanded).lastPathComponent)
        }

        return ("/usr/bin/env", [trimmed], trimmed)
    }

    private func channelState(for startFailureKind: TerminalStartFailureKind?) -> ChannelState {
        switch startFailureKind {
        case .brokerHostUnavailable, .brokerSessionStale:
            return .stale
        case .failed, .none:
            return .disconnected
        }
    }

    /// Apply a broker failure reported by the terminal — at start time or from a
    /// live session that lost its broker — to the tab's recovery fields.
    ///
    /// Keeping this in one place is what makes the guidance a tab shows depend on
    /// the failure kind rather than on when the failure was noticed: a broker host
    /// outage keeps the handle and offers `retryBrokerHost`, a dropped session
    /// keeps the dead identity and offers `recreateBrokerSession`.
    private func applyBrokerFailure(kind: TerminalStartFailureKind?) -> ChannelState {
        lastStartFailureKind = kind
        adapterPersistentState = nil
        terminalOutputPersistentState = nil
        switch kind {
        case .brokerHostUnavailable:
            // Outage is retryable: keep the handle so retry reattaches the same
            // broker session instead of spawning a replacement.
            if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
                brokerSessionID = terminalBrokerSessionID
            }
            staleBrokerSessionID = nil
        case .brokerSessionStale:
            // The broker no longer owns the session. Retry must spawn a
            // replacement, so drop the live handle, but keep the dead identity so
            // guidance and tab metadata survive relaunch.
            brokerSessionID = nil
            staleBrokerSessionID = terminal.staleBrokerSessionID
            invalidateAdapterOwner()
        case .failed, .none:
            // An indeterminate reattach failure can still belong to the saved
            // process generation (for example, a temporarily unreadable registry).
            // Mirror any retained terminal handle so retry cannot create a second
            // process merely because the failure was not classifiable.
            if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
                brokerSessionID = terminalBrokerSessionID
            }
        }
        return channelState(for: kind)
    }

    /// Downgrade a live tab whose broker host or session disappeared underneath
    /// it. Reported by the terminal process so the failure is explicit instead of
    /// being swallowed or trapping in the middle of an output poll.
    private func handleSessionFailure(_ failure: TerminalSessionFailure) {
        lastSessionFailureState = failure.kind == .failed
            ? brokerFailureState(reason: failure.description)
            : nil
        if terminal.brokerOwnedSessionID == nil {
            brokerSessionID = nil
            brokerSessionPersistenceIsAuthoritative = true
        }
        let downgradedState = applyBrokerFailure(kind: failure.kind)
        guard state != downgradedState else {
            // Repeated reports (further keystrokes, a layout pass) must not churn
            // the tab bar or rewrite persisted state.
            return
        }
        state = downgradedState
        delegate?.channelStateDidChange(self, to: downgradedState)
    }

    func lastLines(_ count: Int) -> [String] {
        terminal.lastLines(count)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.terminal.resizeToCurrentGrid()
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            self.transitionToDisconnected(invalidateAdapterOwner: true)
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private var brokerEnvironmentProfile: BrokerEnvironmentProfile {
        switch authType {
        case .oauth: return .agentOAuth
        case .apiKey, .deferredAPIKey: return .agentAPI
        }
    }

    private func transitionToDisconnected(invalidateAdapterOwner: Bool = false) {
        pendingRestoredAttention = nil
        adapterPersistentState = nil
        terminalOutputPersistentState = nil
        persistentStatesBySource[.processLifecycle] = nil
        persistentStatesBySource[.brokerRegistry] = nil
        if invalidateAdapterOwner {
            self.invalidateAdapterOwner()
        }
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    private func invalidateAdapterOwner() {
        adapterOwnerToken = UUID().uuidString
        requiresAdapterOwnerToken = true
    }

    private func recordBrokerStart(
        command: String,
        arguments: [String],
        environmentProfile: BrokerEnvironmentProfile,
        label: String?,
        workingDirectory: String?
    ) -> Bool {
        guard let brokerSessionCoordinator else { return true }
        let request = BrokerSessionLaunchRequest(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentProfile: environmentProfile,
            initialSize: terminal.currentGridSize
        )
        do {
            brokerSessionID = try brokerSessionCoordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelId
            ).id
            return true
        } catch {
            // An injected coordinator means this channel owns its broker metadata
            // (test-injected agents). A broker host outage here is an expected
            // runtime condition, so report it and let the caller take its explicit
            // disconnected/reconnect path instead of trapping.
            NSLog("Agent broker session start failed: \(error)")
            return false
        }
    }

    private func recordBrokerDetach() {
        guard let brokerSessionCoordinator, let brokerSessionID else { return }
        do {
            _ = try brokerSessionCoordinator.detach(brokerSessionID)
        } catch {
            // Detach runs on tab teardown and during app termination. If the
            // broker host is unavailable, the durable record keeps its current
            // lifecycle — still reattachable and reconciled on the next launch —
            // so log loudly rather than trapping the app while it is closing.
            NSLog("Agent broker session detach failed: \(error)")
        }
    }

    private func recordBrokerExit(exitCode: Int32?) {
        guard let brokerSessionCoordinator, let brokerSessionID else { return }
        do {
            if let exitCode {
                _ = try brokerSessionCoordinator.exit(brokerSessionID, exitCode: exitCode)
            } else {
                _ = try brokerSessionCoordinator.markErrored(brokerSessionID)
            }
        } catch {
            // Same boundary as detach: an unavailable broker must not trap the app
            // on process exit. The unrecorded transition stays reconcilable.
            NSLog("Agent broker session exit failed: \(error)")
            lastSessionFailureState = brokerFailureState(reason: String(describing: error))
        }
    }

    private func brokerFailureState(reason: String) -> PersistentChannelState {
        PersistentChannelState(
            kind: .error,
            source: .brokerRegistry,
            reason: reason,
            recoveryAction: recoveryAction
        )
    }
}
