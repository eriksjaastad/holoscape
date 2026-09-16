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

    func testShellActivationRecordsBrokerSessionLifecycleWhenCoordinatorIsInjected() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellChannelControllerTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(registry: registry, now: { Date(timeIntervalSince1970: 300) })
        let terminal = MockTerminalProcess()
        terminal.currentGridSize = TerminalGridSize(columns: 132, rows: 43)
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000716")!
        let controller = ShellChannelController(
            id: channelID,
            instanceNumber: nil,
            label: "work",
            workingDirectory: "/Users/test/work",
            terminal: terminal,
            brokerSessionCoordinator: coordinator
        )

        controller.activate()

        let running = try registry.load().single()
        XCTAssertEqual(running.id, controller.brokerSessionID)
        XCTAssertEqual(running.channelType, .shell)
        XCTAssertEqual(running.label, "work")
        XCTAssertEqual(running.command, "/bin/zsh")
        XCTAssertEqual(running.arguments, ["-o", "nopromptsp", "--login"])
        XCTAssertEqual(running.workingDirectory, "/Users/test/work")
        XCTAssertEqual(running.environmentProfile, .shell)
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.lastAttachedChannelID, channelID)

        controller.deactivate()

        let detached = try registry.load().single()
        XCTAssertEqual(detached.id, running.id)
        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
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

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
