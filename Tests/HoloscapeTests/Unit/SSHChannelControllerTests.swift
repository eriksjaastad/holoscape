import XCTest
@testable import Holoscape

final class SSHChannelControllerTests: XCTestCase {

    // MARK: - Display Label

    @MainActor
    func testDisplayLabelWithoutInstanceNumber() {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "architect")
    }

    @MainActor
    func testDisplayLabelWithInstanceNumber() {
        let profile = SessionProfile(label: "mini-claude", connection: .ssh, command: "claude", directory: "~", host: "mac-mini.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "mini-claude 2")
    }

    @MainActor
    func testDisplayLabelProjectDirectory() {
        let profile = SessionProfile(label: "holoscape", connection: .ssh, command: "claude", directory: "~/projects/holoscape", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "holoscape")
    }

    // MARK: - Channel Type

    @MainActor
    func testChannelTypeIsSSH() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "host", user: "user")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.channelType, .ssh)
    }

    // MARK: - Activation Guards

    @MainActor
    func testActivateWithMissingHostStaysDisconnected() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: nil, user: nil)
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        controller.activate()
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testActivateWithEmptyHostStaysDisconnected() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        controller.activate()
        XCTAssertEqual(controller.state, .disconnected)
    }

    // MARK: - Profile Access

    @MainActor
    func testProfileIsAccessible() {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.profile.label, "architect")
        XCTAssertEqual(controller.profile.host, "MacBook.local")
        XCTAssertEqual(controller.profile.directory, "~/projects")
    }
}
