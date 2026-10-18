import XCTest
@testable import Holoscape

@MainActor
final class SessionLauncherItemTests: XCTestCase {
    @MainActor
    private final class DelegateSpy: SessionLauncherDelegate {
        var selectedBuiltIn: SessionProfile?
        var selectedRecent: RecentSession?

        func sessionLauncher(_ launcher: SessionLauncherView, didSelectBuiltInProfile profile: SessionProfile, root: URL) {
            selectedBuiltIn = profile
        }
        func sessionLauncher(_ launcher: SessionLauncherView, didSelectProfile profile: SessionProfile) {}
        func sessionLauncher(_ launcher: SessionLauncherView, didSelectRecentSession recent: RecentSession) {
            selectedRecent = recent
        }
        func sessionLauncher(_ launcher: SessionLauncherView, didTypeNewName name: String) {}
        func sessionLauncherDidRequestRefresh(_ launcher: SessionLauncherView) {}
    }
    func testBuiltInItemsUseConciseDescriptionsInChannelSection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-built-ins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = DirectoryLauncherModel.snapshot(
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

        let snapshot = DirectoryLauncherModel.snapshot(
            root: root,
            configured: [profile],
            builtIn: [],
            discovered: [],
            recent: []
        )
        let item = try XCTUnwrap(snapshot.sections.first?.items.first)

        XCTAssertEqual(item.label, "production")
        XCTAssertEqual(item.detail, "SSH to server.example · ~/services · /bin/zsh")
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
        XCTAssertTrue(launcher.resultsFitViewportForTesting)
    }

    func testFilteredResultsSelectFirstItemAndSupportArrowNavigation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-keyboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpine"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 500, height: 36))
        launcher.updateItems(configured: [], builtIn: [], discovered: [], recent: [], root: root)
        launcher.comboBoxForTesting.stringValue = "alp"
        launcher.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        XCTAssertEqual(launcher.selectedItemLabelForTesting, "alpha")
        launcher.moveSelectionForTesting(by: 1)
        XCTAssertEqual(launcher.selectedItemLabelForTesting, "alpine")
    }

    func testReturnActivatesPreselectedBuiltInWithEmptyQueryAndPublishesAccessibilityState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 500, height: 36))
        let spy = DelegateSpy()
        launcher.launcherDelegate = spy
        launcher.updateItems(configured: [], builtIn: SessionProfileManager.builtInProfiles, discovered: [], recent: [], root: root)

        XCTAssertEqual(launcher.selectedItemLabelForTesting, "Shell")
        XCTAssertEqual(launcher.selectedItemAccessibilityValueForTesting, "selected")
        XCTAssertTrue(launcher.control(launcher.comboBoxForTesting, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(spy.selectedBuiltIn, SessionProfileManager.builtInProfiles[0])
    }

    func testRecentSelectionPreservesExactSameLabelProfileIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let exactProfile = SessionProfile(
            label: "Claude",
            connection: .ssh,
            command: "claude --resume",
            directory: "~/projects/remote",
            host: "remote.example",
            user: "erik"
        )
        let recent = RecentSession(label: "Claude", timestamp: Date(), profile: exactProfile)
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 500, height: 36))
        let spy = DelegateSpy()
        launcher.launcherDelegate = spy
        launcher.updateItems(configured: [], builtIn: [], discovered: [], recent: [recent], root: root)

        XCTAssertTrue(launcher.control(launcher.comboBoxForTesting, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(spy.selectedRecent, recent)
    }

    func testResultRowsUseLauncherSkinFont() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let expected = try XCTUnwrap(NSFont(name: "Menlo", size: 17))
        let surface = SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: nil,
            corner: .uniform(0),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: expected,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil,
            states: []
        )
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 500, height: 36))
        launcher.skinContext = SkinContext(
            surfaces: [.sessionLauncherContainer: surface],
            reactive: ReactiveUniformSnapshot()
        )
        launcher.updateItems(configured: [], builtIn: SessionProfileManager.builtInProfiles, discovered: [], recent: [], root: root)

        XCTAssertEqual(launcher.firstResultFontForTesting?.fontDescriptor.postscriptName, expected.fontDescriptor.postscriptName)
        XCTAssertEqual(launcher.firstResultFontForTesting?.pointSize, 17)
    }
}
