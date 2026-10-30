import Network
import XCTest
@testable import Holoscape

final class HoloscapeAPIServerSecurityTests: XCTestCase {
    func testListenerParametersRequireLoopbackInterface() {
        let parameters = HoloscapeAPIServer.listenerParameters()

        XCTAssertEqual(parameters.requiredInterfaceType, .loopback)
    }

    @MainActor
    func testSendInputWaitsForChannelAcknowledgementAndRejectsFailure() async throws {
        let channel = makeChannel()
        let responseTask = Task { @MainActor in
            await HoloscapeAPIServer.submitInput("pwd", to: channel)
        }
        await Task.yield()

        XCTAssertEqual(channel.sentInputs, ["pwd"])
        channel.finishSubmission(succeeded: false)
        let response = await responseTask.value

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(response.statusText, "Service Unavailable")
    }

    @MainActor
    private func makeChannel() -> MockChannelController {
        MockChannelController(
            type: .shell,
            label: "API",
            state: .active
        )
    }
}
