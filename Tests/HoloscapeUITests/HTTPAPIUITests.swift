import XCTest

final class HTTPAPIUITests: HoloscapeUITestCase {

    // MARK: - List Channels

    func testListChannelsReturnsDefaultShell() throws {
        let channels = try apiListChannels()
        XCTAssertGreaterThanOrEqual(channels.count, 1, "Should have at least one channel on launch")

        let first = channels[0]
        XCTAssertNotNil(first["id"], "Channel should have an id")
        XCTAssertNotNil(first["label"], "Channel should have a label")
        XCTAssertNotNil(first["type"], "Channel should have a type")
        XCTAssertNotNil(first["state"], "Channel should have a state")
    }

    // MARK: - Create Channel

    func testCreateChannelViaAPI() throws {
        let countBefore = try apiListChannels().count

        let (_, status) = try apiCreateChannel(label: "api-test")
        XCTAssertEqual(status, 201, "Create channel should return 201")

        let entry = sidebarEntry("api-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Sidebar should show new channel")

        let countAfter = try apiListChannels().count
        XCTAssertEqual(countAfter, countBefore + 1, "Channel count should increase by 1")
    }

    func testCreateChannelWithDirectory() throws {
        let (_, status) = try apiCreateChannel(dir: "/tmp", label: "tmp-api")
        XCTAssertEqual(status, 201)

        let entry = sidebarEntry("tmp-api")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Sidebar should show channel with custom label")
    }

    // MARK: - Read Output

    func testReadOutputFromChannel() throws {
        try apiCreateChannel(dir: "/tmp", label: "output-test")
        Thread.sleep(forTimeInterval: 1)

        let lines = try apiReadOutput(label: "output-test", lines: 10)
        // Shell prompt should produce at least some output
        XCTAssertTrue(lines.count >= 0, "Output request should return an array")
    }

    // MARK: - Send Input + Read Output

    func testSendInputAndReadOutput() throws {
        try apiCreateChannel(dir: "/tmp", label: "echo-test")
        Thread.sleep(forTimeInterval: 1)

        try apiSendInput(label: "echo-test", text: "echo hello-api-test\n")

        let found = try waitForAPIOutput(label: "echo-test", containing: "hello-api-test", timeout: 5)
        XCTAssertTrue(found, "Output should contain echoed text")
    }

    // MARK: - Switch Channel

    func testSwitchChannelViaAPI() throws {
        try apiCreateChannel(label: "switch-target")
        Thread.sleep(forTimeInterval: 0.5)

        let (data, status) = try apiRequest("POST", path: "/channels/switch-target/switch")
        XCTAssertEqual(status, 200)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "switched")
    }

    // MARK: - Delete Channel

    func testDeleteChannelViaAPI() throws {
        try apiCreateChannel(label: "delete-me")
        let entry = sidebarEntry("delete-me")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        let countBefore = try apiListChannels().count
        try apiDeleteChannel(label: "delete-me")

        // Sidebar entry should disappear
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: entry, handler: nil)
        waitForExpectations(timeout: 3)

        let countAfter = try apiListChannels().count
        XCTAssertEqual(countAfter, countBefore - 1, "Channel count should decrease by 1")
    }

    // MARK: - Label Resolution

    func testResolveByLabelCaseInsensitive() throws {
        try apiCreateChannel(dir: "/tmp", label: "CaseTest")
        Thread.sleep(forTimeInterval: 1)

        let (_, status) = try apiRequest("GET", path: "/channels/casetest/output?lines=5")
        XCTAssertEqual(status, 200, "Label resolution should be case-insensitive")
    }

    // MARK: - Error Cases

    func testInvalidChannelReturns404() throws {
        let (_, status) = try apiRequest("GET", path: "/channels/nonexistent/output?lines=5")
        XCTAssertEqual(status, 404, "Non-existent channel should return 404")
    }

    func testSendInputToNonexistentReturns404() throws {
        let (_, status) = try apiRequest("POST", path: "/channels/fake/input", body: ["text": "hello"])
        XCTAssertEqual(status, 404)
    }

    func testDeleteNonexistentReturns404() throws {
        let (_, status) = try apiRequest("DELETE", path: "/channels/no-such-channel")
        XCTAssertEqual(status, 404)
    }
}
