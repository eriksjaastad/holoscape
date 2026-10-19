import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class MainWindowComposerTests: XCTestCase {
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
        input.string = "wait for prompt"
        input.didChangeText()

        input.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))

        XCTAssertTrue(channel.sentInputs.isEmpty)
        XCTAssertEqual(input.string, "wait for prompt")
        XCTAssertEqual(fixture.controller.composerStateForTesting(channelId: channel.channelId).draft, "wait for prompt")
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
        state: ChannelState = .active
    ) -> MockChannelController {
        var result: MockChannelController!
        _ = manager.createChannel(type: type, role: label, workingDirectory: nil) { id, type, label, number, _ in
            let channel = MockChannelController(id: id, type: type, label: label, instanceNumber: number, state: state)
            result = channel
            return channel
        }
        return result
    }
}
