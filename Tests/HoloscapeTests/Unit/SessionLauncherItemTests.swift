import XCTest
@testable import Holoscape

@MainActor
final class SessionLauncherItemTests: XCTestCase {
    func testBuiltInLauncherItemsExposePlainLabelsAndDescriptions() {
        let shell = LauncherItem(profile: SessionProfileManager.builtInProfiles[0], isHeader: false)
        let agentOAuth = LauncherItem(profile: SessionProfileManager.builtInProfiles[1], isHeader: false)
        let groupChat = LauncherItem(profile: SessionProfileManager.builtInProfiles[4], isHeader: false)

        XCTAssertEqual(shell.label, "Shell")
        XCTAssertTrue(shell.displayText.contains("Local zsh"))
        XCTAssertEqual(agentOAuth.label, "Agent (OAuth)")
        XCTAssertTrue(agentOAuth.displayText.contains("browser login"))
        XCTAssertEqual(groupChat.label, "Group Chat")
        XCTAssertTrue(groupChat.displayText.contains("Shared agent chat"))
    }

    func testProjectLauncherItemNamesConnectionAndDirectory() {
        let profile = SessionProfile(
            label: "holoscape",
            connection: .local,
            command: "/bin/zsh",
            directory: "/Users/eriksjaastad/projects/holoscape-agent"
        )

        let item = LauncherItem(profile: profile, isHeader: false)

        XCTAssertEqual(item.label, "holoscape")
        XCTAssertEqual(item.detail, "Local session in /Users/eriksjaastad/projects/holoscape-agent")
        XCTAssertEqual(item.displayText, "holoscape — Local session in /Users/eriksjaastad/projects/holoscape-agent")
    }

    func testHeaderItemsAreNotDecoratedWithDescriptions() {
        let header = LauncherItem.header("Projects")

        XCTAssertTrue(header.isHeader)
        XCTAssertEqual(header.label, "--- Projects ---")
        XCTAssertEqual(header.displayText, "--- Projects ---")
    }
}
