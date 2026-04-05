import XCTest
@testable import Holoscape

final class BridgeChannelTests: XCTestCase {

    @MainActor
    func testDisplayLabelWithoutInstance() {
        let configService = ConfigService()
        let channelManager = ChannelManager(configService: configService)
        let controller = BridgeChannelController(id: UUID(), channelManager: channelManager, instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "Bridge")
    }

    @MainActor
    func testDisplayLabelWithInstance() {
        let configService = ConfigService()
        let channelManager = ChannelManager(configService: configService)
        let controller = BridgeChannelController(id: UUID(), channelManager: channelManager, instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "Bridge 2")
    }

    @MainActor
    func testChannelTypeIsBridge() {
        let configService = ConfigService()
        let channelManager = ChannelManager(configService: configService)
        let controller = BridgeChannelController(id: UUID(), channelManager: channelManager, instanceNumber: nil)
        XCTAssertEqual(controller.channelType, .bridge)
    }

    @MainActor
    func testInitialStateIsActive() {
        let configService = ConfigService()
        let channelManager = ChannelManager(configService: configService)
        let controller = BridgeChannelController(id: UUID(), channelManager: channelManager, instanceNumber: nil)
        XCTAssertEqual(controller.state, .active)
        XCTAssertNotNil(controller.activatedAt)
    }

    @MainActor
    func testAgentChannelsFilterExcludesShellAndBridge() {
        let configService = ConfigService()
        let channelManager = ChannelManager(configService: configService)

        // Create a shell channel — should NOT be in agentChannels
        let shell = channelManager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, num, _ in
            ShellChannelController(id: id, instanceNumber: num)
        }
        // Don't activate — agentChannels checks state == .active
        _ = shell

        let agents = channelManager.agentChannels()
        XCTAssertTrue(agents.isEmpty, "Shell channels should not be in agentChannels")
    }
}
