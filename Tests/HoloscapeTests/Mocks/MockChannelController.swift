import AppKit
@testable import Holoscape

@MainActor
class MockChannelController: NSObject, ChannelController {
    let channelId: UUID
    let channelType: ChannelType
    var hasUnread: Bool = false
    private(set) var state: ChannelState
    weak var delegate: ChannelControllerDelegate?
    let commandHistory = CommandHistory()
    var displayBaseLabelOverride: String?
    var displayBaseLabel: String { displayBaseLabelOverride ?? displayLabel }
    var displayLabel: String
    private(set) var customDisplayLabel: String?
    let instanceNumber: Int?
    var tabIdentityIndicatorOverride: ChannelTabIdentityIndicator?
    var navigationContextOverride: ChannelNavigationContext?
    var recoveryActionOverride: ChannelRecoveryAction?
    var persistentStateOverride: PersistentChannelState?
    private(set) var lastInteractionAt: Date = Date()
    private let _contentView: NSView

    var contentView: NSView { _contentView }

    var tabIdentityIndicator: ChannelTabIdentityIndicator? {
        tabIdentityIndicatorOverride
    }

    var navigationContext: ChannelNavigationContext {
        navigationContextOverride ?? ChannelNavigationContext(
            typeLabel: channelType.sidebarPrefix,
            identityLabel: tabIdentityIndicator?.accessibilityLabel,
            locationPath: nil
        )
    }

    var recoveryAction: ChannelRecoveryAction? {
        recoveryActionOverride ?? (state == .disconnected ? .reconnect : nil)
    }

    var persistentState: PersistentChannelState {
        persistentStateOverride ?? PersistentChannelState.fromRuntimeState(
            state,
            recoveryAction: recoveryAction
        )
    }

    var activateCallCount = 0
    var deactivateCallCount = 0
    var closeDeactivationCallCount = 0
    var appTerminationDeactivationCallCount = 0
    var appTerminationOutcome: TerminalCleanupOutcome = .completed
    var defersDeactivationCompletion = false
    private var pendingDeactivationCompletion: (@MainActor (TerminalCleanupOutcome) -> Void)?
    var sentInputs: [String] = []
    private var pendingSubmissionCompletion: (@MainActor (Bool) -> Void)?

    init(
        id: UUID = UUID(),
        type: ChannelType = .shell,
        label: String = "Mock",
        instanceNumber: Int? = nil,
        state: ChannelState = .disconnected,
        contentView: NSView = NSView()
    ) {
        self.channelId = id
        self.channelType = type
        self.displayLabel = label
        self.instanceNumber = instanceNumber
        self.state = state
        self._contentView = contentView
        super.init()
    }

    func sendInput(_ text: String) {
        sentInputs.append(text)
    }

    func submitInput(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        sentInputs.append(text)
        pendingSubmissionCompletion = completion
    }

    func finishSubmission(succeeded: Bool) {
        let completion = pendingSubmissionCompletion
        pendingSubmissionCompletion = nil
        completion?(succeeded)
    }

    func activate() {
        activateCallCount += 1
        state = .active
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        deactivateCallCount += 1
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func deactivate(completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void) {
        deactivate()
        if defersDeactivationCompletion {
            pendingDeactivationCompletion = completion
        } else {
            completion(.completed)
        }
    }

    func deactivateForClose(completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void) {
        closeDeactivationCallCount += 1
        deactivate(completion: completion)
    }

    func deactivateForAppTermination(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        appTerminationDeactivationCallCount += 1
        let outcome = appTerminationOutcome
        deactivate { _ in completion(outcome) }
    }

    func finishDeactivation() {
        let completion = pendingDeactivationCompletion
        pendingDeactivationCompletion = nil
        completion?(.completed)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        return []
    }

    func setCustomDisplayLabel(_ label: String?) {
        customDisplayLabel = ChannelCustomDisplayLabel.normalized(label)
        if let customDisplayLabel {
            displayLabel = customDisplayLabel
        }
    }

    func recordUserInteraction(at date: Date = Date()) {
        lastInteractionAt = date
    }
}
