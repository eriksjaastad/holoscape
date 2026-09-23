import XCTest
@testable import Holoscape

@MainActor
final class AgentChannelPromptTests: XCTestCase {
    func testBlankPromptUsesDefaultDirectoryAndBasenameLabel() {
        let defaultDirectory = URL(fileURLWithPath: "/Users/erik/projects")

        let resolved = MainWindowController.resolvedAgentChannelPrompt(
            directoryInput: "   ",
            labelInput: "   ",
            defaultDirectory: defaultDirectory
        )

        XCTAssertEqual(resolved.workingDirectory.path, "/Users/erik/projects")
        XCTAssertEqual(resolved.label, "projects")
    }

    func testDirectoryPromptDefaultsBlankLabelToChosenDirectoryName() {
        let resolved = MainWindowController.resolvedAgentChannelPrompt(
            directoryInput: "/Users/erik/projects/holoscape",
            labelInput: "",
            defaultDirectory: URL(fileURLWithPath: "/Users/erik/projects")
        )

        XCTAssertEqual(resolved.workingDirectory.path, "/Users/erik/projects/holoscape")
        XCTAssertEqual(resolved.label, "holoscape")
    }

    func testPromptTrimsExplicitLabelAndExpandsTildeDirectory() {
        let resolved = MainWindowController.resolvedAgentChannelPrompt(
            directoryInput: "~/projects/auxesis",
            labelInput: "  Auxesis Agent  ",
            defaultDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(resolved.workingDirectory.path, NSHomeDirectory() + "/projects/auxesis")
        XCTAssertEqual(resolved.label, "Auxesis Agent")
    }

    func testInlineAgentInputParsesDirectoryAndLabelFromLauncherText() {
        let resolved = MainWindowController.agentChannelPromptResult(
            fromInlineInput: "Agent (OAuth) /Users/erik/projects/holoscape as Holoscape Agent",
            kindLabel: "Agent (OAuth)",
            defaultDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(resolved?.workingDirectory.path, "/Users/erik/projects/holoscape")
        XCTAssertEqual(resolved?.label, "Holoscape Agent")
    }

    func testInlineAgentInputWithoutFieldsUsesDefaultDirectoryAndBasename() {
        let resolved = MainWindowController.agentChannelPromptResult(
            fromInlineInput: "Agent (API Key)",
            kindLabel: "Agent (API Key)",
            defaultDirectory: URL(fileURLWithPath: "/Users/erik/projects")
        )

        XCTAssertEqual(resolved?.workingDirectory.path, "/Users/erik/projects")
        XCTAssertEqual(resolved?.label, "projects")
    }
}
