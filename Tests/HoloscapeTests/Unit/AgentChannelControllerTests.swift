import XCTest
@testable import Holoscape

@MainActor
final class AgentChannelControllerTests: XCTestCase {
    func testLaunchInvocationUsesEnvForBareCommand() {
        let invocation = AgentChannelController.launchInvocation(for: "claude")

        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.args, ["claude"])
        XCTAssertEqual(invocation.execName, "claude")
    }

    func testLaunchInvocationExpandsAbsoluteOrTildeCommand() {
        let invocation = AgentChannelController.launchInvocation(for: "~/.local/bin/claude")

        XCTAssertEqual(invocation.executable, "\(NSHomeDirectory())/.local/bin/claude")
        XCTAssertTrue(invocation.args.isEmpty)
        XCTAssertEqual(invocation.execName, "claude")
    }
}
