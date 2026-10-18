import XCTest
@testable import Holoscape

@MainActor
final class SessionLauncherItemTests: XCTestCase {
    func testBuiltInItemsUseConciseDescriptionsInChannelSection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-built-ins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = try DirectoryLauncherModel.snapshot(
            root: root,
            configured: [],
            builtIn: SessionProfileManager.builtInProfiles,
            discovered: [],
            recent: []
        )
        let channels = try XCTUnwrap(snapshot.sections.first { $0.title == "Channels" })

        XCTAssertEqual(channels.items[0].label, "Shell")
        XCTAssertEqual(channels.items[0].detail, "Local shell")
        XCTAssertEqual(channels.items[1].label, "Agent (OAuth)")
        XCTAssertEqual(channels.items[1].detail, "Agent with browser sign-in")
        XCTAssertEqual(channels.items[4].label, "Group Chat")
        XCTAssertEqual(channels.items[4].detail, "Shared agent chat")
    }

    func testSavedProfileKeepsConnectionContextSeparateFromItsLabel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = SessionProfile(
            label: "production",
            connection: .ssh,
            command: "/bin/zsh",
            directory: "~/services",
            host: "server.example"
        )

        let snapshot = try DirectoryLauncherModel.snapshot(
            root: root,
            configured: [profile],
            builtIn: [],
            discovered: [],
            recent: []
        )
        let item = try XCTUnwrap(snapshot.sections.first?.items.first)

        XCTAssertEqual(item.label, "production")
        XCTAssertEqual(item.detail, "SSH to server.example")
        XCTAssertEqual(item.kind, .profile)
    }

    func testResultsUseTopAnchoredScrollGeometry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        launcher.updateItems(
            configured: [],
            builtIn: SessionProfileManager.builtInProfiles,
            discovered: [],
            recent: [],
            root: root
        )

        XCTAssertTrue(launcher.resultsStartAtTopForTesting)
    }
}
