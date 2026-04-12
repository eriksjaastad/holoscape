import XCTest
import AppKit

final class TerminalInputUITests: HoloscapeUITestCase {

    // MARK: - No Input Box for Shell

    func testShellChannelHasNoInputBox() throws {
        // Shell tabs should type directly into the terminal — no separate input box
        let inputBox = app.textViews["input-box"]
        // Give UI a moment to settle
        Thread.sleep(forTimeInterval: 1)
        // Input box should either not exist or not be hittable for shell channels
        if inputBox.exists {
            XCTAssertFalse(inputBox.isHittable, "Input box should not be hittable in shell channels")
        }
    }

    // MARK: - Terminal View

    func testTerminalViewExistsForShell() throws {
        let terminal = terminalView()
        XCTAssertTrue(terminal.waitForExistence(timeout: 3), "Terminal view should exist with accessibility identifier")
    }

    func testTerminalViewAcceptsKeystrokes() throws {
        // Get the default channel label from the API
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        // Click the terminal to ensure focus
        let terminal = terminalView()
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))
        terminal.click()

        // Type a command — the keystrokes go directly to the terminal
        app.typeText("echo typing-test-123\n")

        let found = try waitForAPIOutput(channelRef: channelRef, containing: "typing-test-123", timeout: 5)
        XCTAssertTrue(found, "Terminal should accept keystrokes and produce output")
    }

    // MARK: - Focus Behavior

    func testTerminalFocusOnChannelSwitch() throws {
        // Create a second channel via API
        try apiCreateChannel(label: "focus-test")
        Thread.sleep(forTimeInterval: 1)

        // Switch back to first channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        // Type into the terminal — focus should be on the terminal
        let terminal = terminalView()
        if terminal.exists {
            terminal.click()
        }
        app.typeText("echo focus-check\n")

        let found = try waitForAPIOutput(channelRef: channelRef, containing: "focus-check", timeout: 5)
        XCTAssertTrue(found, "Terminal should have focus after channel switch")
    }

    func testTerminalFocusAfterAppReactivation() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        // Activate Finder to take focus away
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        Thread.sleep(forTimeInterval: 0.5)

        // Re-activate Holoscape
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        // Terminal should have focus — type and verify
        let terminal = terminalView()
        if terminal.exists {
            terminal.click()
        }
        app.typeText("echo refocus-test\n")

        let found = try waitForAPIOutput(channelRef: channelRef, containing: "refocus-test", timeout: 5)
        XCTAssertTrue(found, "Terminal should regain focus after app reactivation")
    }

    // MARK: - Copy

    func testCopyFromTerminal() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        // Send known text via API
        try apiSendInput(channelRef: channelRef, text: "echo COPY_TARGET_TEXT\n")
        Thread.sleep(forTimeInterval: 1)

        // Select all and copy
        let terminal = terminalView()
        if terminal.exists {
            terminal.click()
        }
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let pasteboard = NSPasteboard.general
        let contents = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(contents.contains("COPY_TARGET_TEXT"), "Clipboard should contain copied terminal text")
    }
}
