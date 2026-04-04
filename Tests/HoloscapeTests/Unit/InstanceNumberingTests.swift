import XCTest
@testable import Holoscape

final class InstanceNumberingTests: XCTestCase {

    @MainActor
    func testFirstChannelHasNoInstanceNumber() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~")
        let channel = manager.createChannel(from: profile)
        XCTAssertEqual(channel.displayLabel, "mini-claude")
    }

    @MainActor
    func testSecondChannelGetsInstanceNumber() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~")
        let ch1 = manager.createChannel(from: profile)
        let ch2 = manager.createChannel(from: profile)

        // First channel stays unnumbered (it was created before there were multiples)
        // Second channel gets number 2
        XCTAssertEqual(ch1.displayLabel, "mini-claude")
        XCTAssertEqual(ch2.displayLabel, "mini-claude 2")
    }

    @MainActor
    func testThirdChannelGetsNumber3() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "architect", connection: .local, command: "claude", directory: "~")
        _ = manager.createChannel(from: profile)
        _ = manager.createChannel(from: profile)
        let ch3 = manager.createChannel(from: profile)

        XCTAssertEqual(ch3.displayLabel, "architect 3")
    }

    @MainActor
    func testCloseDoesNotRenumber() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "test", connection: .local, command: "claude", directory: "~")
        let ch1 = manager.createChannel(from: profile)
        let ch2 = manager.createChannel(from: profile)

        // Close the first channel
        manager.closeChannel(id: ch1.channelId)

        // ch2 should still have its label
        XCTAssertEqual(ch2.displayLabel, "test 2")

        // Create a third — should get 3, not reuse 1
        let ch3 = manager.createChannel(from: profile)
        XCTAssertEqual(ch3.displayLabel, "test 3")
    }

    @MainActor
    func testDifferentLabelsGetSeparateNumbering() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile1 = SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~")
        let profile2 = SessionProfile(label: "architect", connection: .local, command: "claude", directory: "~")

        let mc1 = manager.createChannel(from: profile1)
        let ar1 = manager.createChannel(from: profile2)
        let mc2 = manager.createChannel(from: profile1)

        XCTAssertEqual(mc1.displayLabel, "mini-claude")
        XCTAssertEqual(ar1.displayLabel, "architect")
        XCTAssertEqual(mc2.displayLabel, "mini-claude 2")
    }

    @MainActor
    func testSSHChannelFromProfile() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let channel = manager.createChannel(from: profile)

        XCTAssertEqual(channel.channelType, .ssh)
        XCTAssertEqual(channel.displayLabel, "architect")
    }

    @MainActor
    func testLocalShellFromProfile() {
        let configService = ConfigService()
        let manager = ChannelManager(configService: configService)

        let profile = SessionProfile(label: "shell", connection: .local, command: "/bin/zsh", directory: "~")
        let channel = manager.createChannel(from: profile)

        XCTAssertEqual(channel.channelType, .shell)
    }
}
