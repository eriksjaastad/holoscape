import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class MainWindowComposerTests: XCTestCase {
    private final class RecordingBrokerSessionCoordinator: BrokerSessionCoordinating {
        private var nextID = 0

        func start(
            _ request: BrokerSessionLaunchRequest,
            channelType: ChannelType,
            label: String?,
            attachedChannelID: UUID?
        ) throws -> BrokerSessionRecord {
            nextID += 1
            return BrokerSessionRecord(
                id: BrokerSessionID(rawValue: "main-window-label-\(nextID)"),
                channelType: channelType,
                label: label,
                command: request.command,
                arguments: request.arguments,
                workingDirectory: request.workingDirectory,
                environmentProfile: request.environmentProfile,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                lastAttachedChannelID: attachedChannelID
            )
        }

        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func retireUntrackedSession(_ id: BrokerSessionID) throws {}
        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func reattachableSessions() throws -> [BrokerSessionRecord] { [] }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func updateWorkingDirectory(_ id: BrokerSessionID, to directory: String) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(_ id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? { nil }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
    }

    func testPTYChannelsDefaultToComposerAndKeepDraftsIsolated() throws {
        let fixture = try makeFixture()
        let first = fixture.makeChannel(type: .shell, label: "One")
        let second = fixture.makeChannel(type: .ssh, label: "Two")

        fixture.controller.switchToChannel(first.channelId)
        XCTAssertFalse(fixture.controller.inputContainerForTesting.isHidden)
        fixture.controller.inputBoxForTesting.string = "first draft"
        fixture.controller.inputBoxForTesting.didChangeText()

        fixture.controller.switchToChannel(second.channelId)
        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "")
        fixture.controller.inputBoxForTesting.string = "second draft"
        fixture.controller.inputBoxForTesting.didChangeText()

        fixture.controller.switchToChannel(first.channelId)
        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "first draft")
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: second.channelId).draft, "second draft")
    }

    func testSwitchingChannelsWhileViewingHistoryPreservesOriginalDraft() throws {
        let fixture = try makeFixture()
        let first = fixture.makeChannel(type: .shell, label: "One")
        let second = fixture.makeChannel(type: .ssh, label: "Two")
        first.commandHistory.add("older command")
        first.commandHistory.add("newest command")

        fixture.controller.switchToChannel(first.channelId)
        let input = fixture.controller.inputBoxForTesting
        input.string = "unsent draft"
        input.didChangeText()
        input.setSelectedRange(NSRange(location: 0, length: 0))
        input.keyDown(with: keyEvent(keyCode: 126, characters: ""))
        XCTAssertEqual(input.string, "newest command")

        fixture.controller.switchToChannel(second.channelId)
        fixture.controller.switchToChannel(first.channelId)

        XCTAssertEqual(input.string, "unsent draft")
        XCTAssertEqual(
            fixture.controller.composerStateForTesting(channelId: first.channelId).draft,
            "unsent draft"
        )

        input.setSelectedRange(NSRange(location: 0, length: 0))
        input.keyDown(with: keyEvent(keyCode: 126, characters: ""))
        XCTAssertEqual(input.string, "newest command")
    }

    func testSplitPaneActivationSwitchesComposerDraftOwnership() throws {
        let fixture = try makeFixture()
        let first = fixture.makeChannel(type: .shell, label: "One")
        let second = fixture.makeChannel(type: .ssh, label: "Two")

        fixture.controller.switchToChannel(first.channelId)
        fixture.controller.inputBoxForTesting.string = "first draft"
        fixture.controller.inputBoxForTesting.didChangeText()
        fixture.controller.switchToChannel(second.channelId)
        fixture.controller.inputBoxForTesting.string = "second draft"
        fixture.controller.inputBoxForTesting.didChangeText()
        fixture.controller.switchToChannel(first.channelId)

        fixture.controller.splitPaneManager(
            fixture.controller.splitPaneManagerForTesting,
            activePaneDidChange: second.channelId
        )

        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "second draft")
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: first.channelId).draft, "first draft")
    }

    func testExplicitRawTogglePreservesDraftAndPublishesAccessibilityState() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .agentDirect, label: "Agent")
        fixture.controller.switchToChannel(channel.channelId)
        fixture.controller.inputBoxForTesting.string = "keep me"
        fixture.controller.inputBoxForTesting.didChangeText()

        let control = fixture.controller.composerModeControlForTesting
        XCTAssertEqual(control.accessibilityIdentifier(), "composer-mode-toggle")
        XCTAssertEqual(control.accessibilityValue() as? String, "Composer")
        control.selectedSegment = 1
        XCTAssertTrue(control.sendAction(control.action, to: control.target))

        XCTAssertTrue(fixture.controller.inputContainerForTesting.isHidden)
        XCTAssertEqual(control.accessibilityValue() as? String, "Raw Terminal")
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: channel.channelId).draft, "keep me")

        control.selectedSegment = 0
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        XCTAssertFalse(fixture.controller.inputContainerForTesting.isHidden)
        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "keep me")
    }

    func testComposerStateIsRemovedOnlyAfterChannelActuallyCloses() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .shell, label: "Closing")
        channel.defersDeactivationCompletion = true
        fixture.controller.switchToChannel(channel.channelId)
        fixture.controller.inputBoxForTesting.string = "unsent"
        fixture.controller.inputBoxForTesting.didChangeText()

        fixture.manager.closeChannel(id: channel.channelId)
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: channel.channelId).draft, "unsent")

        channel.finishDeactivation()
        XCTAssertNil(fixture.manager.channel(for: channel.channelId))
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: channel.channelId), ComposerChannelState())
    }

    func testNonPTYChannelIsComposerOnly() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .bridge, label: "Bridge")

        fixture.controller.switchToChannel(channel.channelId)

        let control = fixture.controller.composerModeControlForTesting
        XCTAssertFalse(control.isHidden)
        XCTAssertFalse(control.isEnabled(forSegment: 1))
        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertFalse(fixture.controller.inputContainerForTesting.isHidden)
    }

    func testConnectingPTYChannelRejectsSubmissionWithoutClearingDraft() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .shell, label: "Connecting", state: .connecting)
        fixture.controller.switchToChannel(channel.channelId)
        let input = fixture.controller.inputBoxForTesting
        fixture.controller.setComposerDraftForTesting("wait for prompt", channelId: channel.channelId)

        input.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertTrue(channel.sentInputs.isEmpty)
        XCTAssertEqual(input.string, "wait for prompt")
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: channel.channelId).draft, "wait for prompt")
        XCTAssertTrue(fixture.controller.inputContainerForTesting.isHidden)
        XCTAssertFalse(input.isEditable)
        XCTAssertFalse(fixture.controller.composerModeControlForTesting.isEnabled(forSegment: 1))
        XCTAssertFalse(fixture.controller.inputUnavailableViewForTesting.isHidden)
        XCTAssertEqual(fixture.controller.inputUnavailableLabelForTesting.stringValue, "Session is connecting")
        XCTAssertTrue(fixture.controller.inputRecoveryButtonForTesting.isHidden)
    }

    func testStalePTYChannelShowsActionableRecreateStateAndReenablesInputAfterRecovery() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .shell, label: "Stopped", state: .stale)
        channel.recoveryActionOverride = .recreateBrokerSession
        fixture.controller.setComposerDraftForTesting("pwd", channelId: channel.channelId)

        fixture.controller.switchToChannel(channel.channelId)

        XCTAssertTrue(fixture.controller.inputContainerForTesting.isHidden)
        XCTAssertFalse(fixture.controller.inputBoxForTesting.isEditable)
        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "pwd")
        XCTAssertFalse(fixture.controller.inputUnavailableViewForTesting.isHidden)
        XCTAssertEqual(fixture.controller.inputUnavailableLabelForTesting.stringValue, "Session stopped")
        XCTAssertFalse(fixture.controller.inputRecoveryButtonForTesting.isHidden)
        XCTAssertEqual(fixture.controller.inputRecoveryButtonForTesting.title, "Recreate Session")
        XCTAssertEqual(
            fixture.controller.inputRecoveryButtonForTesting.toolTip,
            ChannelRecoveryAction.recreateBrokerSession.operatorGuidance
        )

        fixture.controller.setChannelMutationEnabled(false)
        XCTAssertFalse(fixture.controller.inputRecoveryButtonForTesting.isEnabled)
        fixture.controller.inputRecoveryButtonForTesting.performClick(nil)
        XCTAssertEqual(channel.state, .stale)

        fixture.controller.setChannelMutationEnabled(true)
        XCTAssertTrue(fixture.controller.inputRecoveryButtonForTesting.isEnabled)
        fixture.controller.inputRecoveryButtonForTesting.performClick(nil)

        XCTAssertEqual(channel.state, .active)
        XCTAssertFalse(fixture.controller.inputContainerForTesting.isHidden)
        XCTAssertTrue(fixture.controller.inputBoxForTesting.isEditable)
        XCTAssertTrue(fixture.controller.inputUnavailableViewForTesting.isHidden)
        XCTAssertTrue(fixture.controller.composerModeControlForTesting.isEnabled(forSegment: 1))
        XCTAssertEqual(fixture.controller.inputBoxForTesting.string, "pwd")
    }

    func testActiveStateRefreshPreservesUnrelatedFirstResponder() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .agentDirect, label: "Agent")
        fixture.controller.switchToChannel(channel.channelId)
        let selectionOwner = NSTextField(string: "selected output")
        fixture.controller.window.contentView?.addSubview(selectionOwner)
        XCTAssertTrue(fixture.controller.window.makeFirstResponder(selectionOwner))
        let firstResponder = try XCTUnwrap(fixture.controller.window.firstResponder)

        channel.delegate?.channelStateDidChange(channel, to: .active)

        XCTAssertTrue(fixture.controller.window.firstResponder === firstResponder)
    }

    func testFailedAcknowledgedSubmissionPreservesDraft() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .shell, label: "Active")
        fixture.controller.switchToChannel(channel.channelId)
        let input = fixture.controller.inputBoxForTesting
        input.string = "keep after failure"
        input.didChangeText()

        input.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
        XCTAssertEqual(channel.sentInputs, ["keep after failure"])
        channel.finishSubmission(succeeded: false)

        XCTAssertEqual(input.string, "keep after failure")
        XCTAssertEqual(
            fixture.controller.composerStateForTesting(channelId: channel.channelId).draft,
            "keep after failure"
        )
    }

    func testClosingActiveChannelDetachesAlternateScreenMonitorImmediately() throws {
        let fixture = try makeFixture()
        let terminal = HoloscapeTerminalView(frame: .zero)
        let channel = fixture.makeChannel(type: .shell, label: "Closing", contentView: terminal)
        channel.defersDeactivationCompletion = true
        fixture.controller.switchToChannel(channel.channelId)
        XCTAssertNotNil(terminal.onAlternateScreenChanged)

        fixture.controller.closeChannel(id: channel.channelId)

        XCTAssertNil(terminal.onAlternateScreenChanged)
    }

    func testReselectingActiveTabOrSidebarPreservesSelectionAndUndo() throws {
        let fixture = try makeFixture()
        let channel = fixture.makeChannel(type: .shell, label: "Active")
        fixture.controller.switchToChannel(channel.channelId)
        let input = fixture.controller.inputBoxForTesting
        input.insertText("alpha", replacementRange: NSRange(location: 0, length: 0))
        input.setSelectedRange(NSRange(location: 2, length: 0))

        fixture.controller.tabBarView(TabBarView(frame: .zero), didSelectChannelWithId: channel.channelId)
        fixture.controller.sidebarView(SidebarView(frame: .zero), didSelectChannelWithId: channel.channelId)
        fixture.controller.switchToChannel(channel.channelId)

        XCTAssertEqual(input.selectedRange(), NSRange(location: 2, length: 0))
        input.undoManager?.undo()
        XCTAssertEqual(input.string, "")
    }

    func testOpenChannelUsesExplicitShellAndAgentLabelsAsCustomPresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowOpenChannelLabels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigService(configDir: directory)
        let broker = RecordingBrokerSessionCoordinator()
        let manager = ChannelManager(
            configService: config,
            brokerBackedShellCoordinator: broker
        )
        let controller = MainWindowController(channelManager: manager, configService: config)

        let shellResult = controller.openChannel(
            type: "shell",
            directory: directory.path,
            label: "  Workspace  "
        )
        let agentResult = controller.openChannel(
            type: "agent",
            directory: directory.path,
            label: "  Operator  ",
            command: "codex"
        )

        let channels = manager.allChannels()
        XCTAssertEqual(shellResult, MainWindowController.ChannelOpenResult.created(channels[0].channelId))
        XCTAssertEqual(agentResult, MainWindowController.ChannelOpenResult.created(channels[1].channelId))
        XCTAssertEqual(channels.map { $0.channelType }, [ChannelType.shell, ChannelType.agentDirect])
        XCTAssertEqual(channels.map { $0.customDisplayLabel }, ["Workspace", "Operator"])
        XCTAssertEqual(channels.map { $0.displayLabel }, ["Workspace", "Operator"])
        XCTAssertEqual((channels[1] as? AgentChannelController)?.persistedCommand, "codex")
        XCTAssertEqual(channels[1].tabIdentityIndicator, ChannelTabIdentityIndicator.codex)
    }

    private func keyEvent(keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeFixture() throws -> ComposerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowComposerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = ConfigService(configDir: directory)
        let manager = ChannelManager(configService: config)
        return ComposerFixture(
            directory: directory,
            manager: manager,
            controller: MainWindowController(channelManager: manager, configService: config)
        )
    }
}

@MainActor
private final class ComposerFixture {
    let directory: URL
    let manager: ChannelManager
    let controller: MainWindowController

    init(directory: URL, manager: ChannelManager, controller: MainWindowController) {
        self.directory = directory
        self.manager = manager
        self.controller = controller
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeChannel(
        type: ChannelType,
        label: String,
        state: ChannelState = .active,
        contentView: NSView = NSView()
    ) -> MockChannelController {
        var result: MockChannelController!
        _ = manager.createChannel(type: type, role: label, workingDirectory: nil) { id, type, label, number, _ in
            let channel = MockChannelController(
                id: id,
                type: type,
                label: label,
                instanceNumber: number,
                state: state,
                contentView: contentView
            )
            result = channel
            return channel
        }
        return result
    }
}
