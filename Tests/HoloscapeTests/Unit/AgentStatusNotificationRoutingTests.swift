import XCTest
@testable import Holoscape

@MainActor
final class AgentStatusNotificationRoutingTests: XCTestCase {
    func testScopedOwnerRoutesToMatchingAgentWhenShellAndAgentsShareDirectory() {
        let directory = "/tmp/shared-agent-status-routing"
        let shell = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: directory,
            terminal: MockTerminalProcess()
        )
        let first = makeActiveAgent(directory: directory)
        let second = makeActiveAgent(directory: directory)

        let resolved = HoloscapeAPIServer.resolveNotificationChannel(
            channels: [shell, first, second],
            cwd: directory,
            ownerToken: second.adapterOwnerToken
        )

        XCTAssertEqual(resolved?.channelId, second.channelId)
    }

    func testScopedOwnerNeverFallsBackToShellOrForeignAgent() {
        let directory = "/tmp/shared-agent-status-rejection"
        let shell = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: directory,
            terminal: MockTerminalProcess()
        )
        let agent = makeActiveAgent(directory: directory)

        XCTAssertNil(HoloscapeAPIServer.resolveNotificationChannel(
            channels: [shell, agent],
            cwd: directory,
            ownerToken: "foreign-owner"
        ))
    }

    func testTokenlessLegacyNotificationRequiresUniqueEligibleChannel() {
        let directory = "/tmp/tokenless-agent-status-routing"
        let first = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: directory,
            terminal: MockTerminalProcess()
        )
        let second = ShellChannelController(
            id: UUID(),
            instanceNumber: 2,
            workingDirectory: directory,
            terminal: MockTerminalProcess()
        )

        XCTAssertEqual(HoloscapeAPIServer.resolveNotificationChannel(
            channels: [first],
            cwd: directory,
            ownerToken: nil
        )?.channelId, first.channelId)
        XCTAssertNil(HoloscapeAPIServer.resolveNotificationChannel(
            channels: [first, second],
            cwd: directory,
            ownerToken: nil
        ))
    }

    func testTokenlessNotificationDoesNotSelectFreshScopedAgentOverShell() {
        let directory = "/tmp/tokenless-scoped-agent-routing"
        let shell = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: directory,
            terminal: MockTerminalProcess()
        )
        let agent = makeActiveAgent(directory: directory)

        XCTAssertEqual(HoloscapeAPIServer.resolveNotificationChannel(
            channels: [agent, shell],
            cwd: directory,
            ownerToken: nil
        )?.channelId, shell.channelId)
    }

    private func makeActiveAgent(directory: String) -> AgentChannelController {
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: URL(fileURLWithPath: directory),
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: MockTerminalProcess()
        )
        controller.activate()
        return controller
    }
}