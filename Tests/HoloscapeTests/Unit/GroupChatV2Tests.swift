import AppKit
import XCTest
@testable import Holoscape

final class GroupChatV2Tests: XCTestCase {

    @MainActor
    func testV2DisplayLabelWithLabel() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Group Chat", instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "Group Chat")
    }

    @MainActor
    func testV2DisplayLabelWithInstance() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Group Chat", instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "Group Chat 2")
    }

    @MainActor
    func testV1ConvenienceInitDisplaysChat() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key")
        XCTAssertEqual(controller.displayLabel, "Chat")
    }

    @MainActor
    func testActivatedAtInitiallyNil() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Chat", instanceNumber: nil)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testDeactivateResetsActivatedAt() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com", apiKey: "key", label: "Chat", instanceNumber: nil)
        controller.deactivate()
        XCTAssertNil(controller.activatedAt)
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testApiURLAndKeyAccessible() {
        let controller = GroupChatChannelController(id: UUID(), apiURL: "https://chat.example.com/", apiKey: "my-key", label: "Chat", instanceNumber: nil, apiKeyEnv: "MY_KEY_ENV")
        XCTAssertEqual(controller.apiURL, "https://chat.example.com")  // trailing slash stripped
        XCTAssertEqual(controller.apiKey, "my-key")
        XCTAssertEqual(controller.apiKeyEnv, "MY_KEY_ENV")
    }

    @MainActor
    func testMessageStylingDistinguishesUserFromAgentTurns() {
        let date = Date(timeIntervalSince1970: 0)
        let user = GroupChatChannelController.attributedMessage(sender: "erik", body: "Open the log", date: date)
        let agent = GroupChatChannelController.attributedMessage(sender: "claude", body: "Reading it now", date: date)

        XCTAssertTrue(user.string.contains("YOU"))
        XCTAssertTrue(agent.string.contains("CLAUDE"))

        let userAccent = user.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let agentAccent = agent.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(userAccent, agentAccent)

        let userBackground = user.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        let agentBackground = agent.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(userBackground, agentBackground)
    }
}
