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

        let response = HoloscapeAPIServer.readOutput(
            id: "API",
            queryItems: [HTTPQueryItem(name: "lines", value: "-1")]
        ) { _ in
            resolutionCount += 1
            return self.makeChannel()
        }

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(resolutionCount, 0)
    }

    @MainActor
    func testReadOutputRejectsMalformedLineParametersBeforeResolvingChannel() throws {
        let requestTargets = [
            "/channels/API/output?lines=",
            "/channels/API/output?lines",
            "/channels/API/output?lines=invalid",
            "/channels/API/output?lines=999999999999999999999999",
            "/channels/API/output?lines=invalid&lines=0",
            "/channels/API/output?%6cines=invalid&lines=5"
        ]

        for requestTarget in requestTargets {
            var resolutionCount = 0
            let request = try parsedRequest(target: requestTarget)

            let response = HoloscapeAPIServer.readOutput(
                id: "API",
                queryItems: request.queryItems
            ) { _ in
                resolutionCount += 1
                return self.makeChannel()
            }

            XCTAssertEqual(response.status, 400, requestTarget)
            XCTAssertEqual(resolutionCount, 0, requestTarget)
        }
    }

    @MainActor
    func testOutputLineParameterDefaultsOnlyWhenOmitted() {
        XCTAssertEqual(HoloscapeAPIServer.outputLineCount(from: []), 50)
        XCTAssertEqual(
            HoloscapeAPIServer.outputLineCount(
                from: [HTTPQueryItem(name: "lines", value: "0")]
            ),
            0
        )
        XCTAssertNil(HoloscapeAPIServer.outputLineCount(
            from: [HTTPQueryItem(name: "lines", value: "-1")]
        ))
    }

    private func parsedRequest(target: String) throws -> HTTPRequest {
        let data = Data("GET \(target) HTTP/1.1\r\n\r\n".utf8)
        guard case .request(let request) = HTTPParser.parse(data, maximumRequestBytes: 1024) else {
            throw ParsingError.notRouted
        }
        return request
    }

    private enum ParsingError: Error {
        case notRouted
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
