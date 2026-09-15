import XCTest
@testable import Holoscape

@MainActor
final class ShellChannelControllerTests: XCTestCase {
    func testActivateUsesInjectedTerminalProcess() {
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: "/tmp",
            terminal: terminal
        )

        controller.activate()

        XCTAssertTrue(terminal.startProcessCalled)
        XCTAssertEqual(terminal.lastExecutable, "/bin/zsh")
        XCTAssertEqual(terminal.lastArgs, ["-o", "nopromptsp", "--login"])
        XCTAssertEqual(terminal.lastExecName, "zsh")
        XCTAssertEqual(terminal.lastCurrentDirectory, "/tmp")
        XCTAssertEqual(controller.state, .active)
    }

    func testShellOutputHandlerRoutesThroughTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate

        controller.activate()
        terminal.outputHandler?()

        XCTAssertEqual(delegate.outputCount, 1)
    }

    func testShellUserInputHandlerRoutesThroughTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: NSHomeDirectory(),
            terminal: terminal
        )

        controller.activate()
        terminal.userInputHandler?(Array("cd /tmp\n".utf8)[...])

        XCTAssertEqual(controller.workingDirectory, "/tmp")
    }

    func testShellLastLinesUsesTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        terminal.lines = ["one", "two", "three"]
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)

        XCTAssertEqual(controller.lastLines(2), ["two", "three"])
    }

    func testGenericShellLabelUsesDirectoryName() {
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            label: "Shell",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        XCTAssertEqual(controller.displayLabel, "holoscape")
    }

    func testCustomShellLabelIsPreserved() {
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            label: "logs",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        XCTAssertEqual(controller.displayLabel, "logs")
    }
}
