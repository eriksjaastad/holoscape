import XCTest

final class URLSchemeUITests: HoloscapeUITestCase {

    // MARK: - Basic URL Scheme

    func testNewChannelViaURLScheme() throws {
        let countBefore = sidebarEntryCount()

        openURL("holoscape://new-channel?type=shell&label=url-test")
        Thread.sleep(forTimeInterval: 2)

        let entry = sidebarEntry("url-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "URL scheme should create a new channel with label 'url-test'")
        XCTAssertGreaterThan(sidebarEntryCount(), countBefore, "Sidebar should have more entries after URL scheme")
    }

    func testURLSchemeWithDirectory() throws {
        openURL("holoscape://new-channel?type=shell&dir=/tmp&label=tmp-url")
        Thread.sleep(forTimeInterval: 2)

        let entry = sidebarEntry("tmp-url")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "URL scheme with dir should create channel")
    }

    func testURLSchemeWithCommand() throws {
        openURL("holoscape://new-channel?type=shell&label=cmd-test&cmd=echo%20url-cmd")
        Thread.sleep(forTimeInterval: 2)

        let entry = sidebarEntry("cmd-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "URL scheme with cmd should create channel")

        let found = try waitForAPIOutput(label: "cmd-test", containing: "url-cmd", timeout: 5)
        XCTAssertTrue(found, "Command from URL scheme should produce output")
    }

    // MARK: - Edge Cases

    func testURLSchemeUnknownHostIgnored() throws {
        openURL("holoscape://bogus-action")
        Thread.sleep(forTimeInterval: 1)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should not crash on unknown URL scheme action")
    }

    func testURLSchemeNoParamsCreatesShell() throws {
        let countBefore = sidebarEntryCount()

        openURL("holoscape://new-channel")
        Thread.sleep(forTimeInterval: 2)

        XCTAssertGreaterThan(sidebarEntryCount(), countBefore, "URL scheme with no params should still create a channel")
    }
}
