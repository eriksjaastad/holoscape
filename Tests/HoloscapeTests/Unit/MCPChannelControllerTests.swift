import XCTest
@testable import Holoscape

final class MCPChannelControllerTests: XCTestCase {

    @MainActor
    func testDisplayLabelWithoutInstance() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080/mcp/ceo")!, label: "CEO", instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "CEO")
    }

    @MainActor
    func testDisplayLabelWithInstance() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080/mcp/ceo")!, label: "CEO", instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "CEO 2")
    }

    @MainActor
    func testChannelTypeIsMCP() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080")!, label: "CEO", instanceNumber: nil)
        XCTAssertEqual(controller.channelType, .mcp)
    }

    @MainActor
    func testInitialStateIsDisconnected() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080")!, label: "CEO", instanceNumber: nil)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testSendInputGuardsEmptyText() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080")!, label: "CEO", instanceNumber: nil)
        // Should not crash or send when disconnected
        controller.sendInput("")
        controller.sendInput("test")
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testDeactivateResetsState() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080")!, label: "CEO", instanceNumber: nil)
        controller.deactivate()
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.activatedAt)
    }

    @MainActor
    func testEndpointAccessible() {
        let url = URL(string: "http://localhost:8080/mcp/ceo")!
        let controller = MCPChannelController(id: UUID(), endpoint: url, label: "CEO", instanceNumber: nil)
        XCTAssertEqual(controller.endpoint, url)
    }

    @MainActor
    func testProfileLabelAccessible() {
        let controller = MCPChannelController(id: UUID(), endpoint: URL(string: "http://localhost:8080")!, label: "Auxesis CEO", instanceNumber: nil)
        XCTAssertEqual(controller.profileLabel, "Auxesis CEO")
    }
}
