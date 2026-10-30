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
    func testCloseWaitsForAcknowledgementAndRejectsRetryableFailure() async {
        var pendingCompletion: ((TerminalCleanupOutcome) -> Void)?
        let responseTask = Task { @MainActor in
            await HoloscapeAPIServer.closeChannel { completion in
                pendingCompletion = completion
            }
        }
        await Task.yield()

        XCTAssertNotNil(pendingCompletion)
        pendingCompletion?(.retryableFailure(TerminalSessionFailure(
            kind: .brokerHostUnavailable,
            description: "cleanup failed"
        )))
        let response = await responseTask.value

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(response.statusText, "Service Unavailable")
    }

    @MainActor
    func testReadOutputRejectsNegativeLineCountBeforeResolvingChannel() {
        var resolutionCount = 0

        let response = HoloscapeAPIServer.readOutput(id: "API", lines: -1) { _ in
            resolutionCount += 1
            return self.makeChannel()
        }

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(resolutionCount, 0)
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
