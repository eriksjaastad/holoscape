import XCTest
@testable import Holoscape

@MainActor
final class DirectoryLauncherModelTests: XCTestCase {
    func testRootUsesReadableActiveDirectoryAndFallsBackWhenMissing() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-root-\(UUID().uuidString)", isDirectory: true)
        let active = workspace.appendingPathComponent("active", isDirectory: true)
        let fallback = workspace.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertEqual(
            DirectoryLauncherModel.root(activeDirectory: active.path, fallback: fallback),
            active.standardizedFileURL
        )
        XCTAssertEqual(
            DirectoryLauncherModel.root(
                activeDirectory: workspace.appendingPathComponent("missing").path,
                fallback: fallback
            ),
            fallback.standardizedFileURL
        )
    }

    func testSnapshotListsActualChildDirectoriesAndSeparatesSections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Beta", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("README.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = DirectoryLauncherModel.snapshot(
            root: root,
            configured: [SessionProfile(label: "Saved SSH", connection: .ssh, command: "", directory: "~")],
            builtIn: SessionProfileManager.builtInProfiles,
            discovered: [],
            recent: [RecentSession(label: "Yesterday", timestamp: Date())]
        )

        XCTAssertEqual(snapshot.root, root.standardizedFileURL)
        XCTAssertEqual(snapshot.sections.map(\.title), ["Channels", "Directories", "Saved Sessions", "Recent"])
        XCTAssertEqual(snapshot.sections[1].items.map(\.label), ["alpha", "Beta"])
        XCTAssertEqual(
            snapshot.sections[1].items.map { $0.profile?.directory },
            [
                root.appendingPathComponent("alpha", isDirectory: true).standardizedFileURL.path,
                root.appendingPathComponent("Beta", isDirectory: true).standardizedFileURL.path,
            ]
        )
    }

    func testFilteringPreservesSectionIdentityAndMatchesPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("holoscape", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = DirectoryLauncherModel.snapshot(
            root: root,
            configured: [],
            builtIn: SessionProfileManager.builtInProfiles,
            discovered: [],
            recent: []
        )
        let filtered = snapshot.filtered(by: "holoscape-launcher-filter")

        XCTAssertEqual(filtered.sections.map(\.title), ["Directories"])
        XCTAssertEqual(filtered.sections[0].items.map(\.label), ["holoscape"])
    }

    func testSnapshotPreservesDistinctProfilesThatShareDirectoryOrLabel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-profiles-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let shell = SessionProfile(label: "project", connection: .local, command: "/bin/zsh", directory: project.path)
        let agent = SessionProfile(label: "project", connection: .local, command: "claude", directory: project.path)

        let snapshot = DirectoryLauncherModel.snapshot(
            root: root,
            configured: [shell, agent],
            builtIn: [],
            discovered: [],
            recent: []
        )

        XCTAssertEqual(snapshot.sections.map(\.title), ["Directories", "Saved Sessions"])
        XCTAssertEqual(snapshot.sections[1].items.compactMap(\.profile), [shell, agent])
    }

    func testUnreadableRootKeepsIndependentSectionsAndReportsError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-launcher-root-\(UUID().uuidString)", isDirectory: true)
        let saved = SessionProfile(label: "Saved", connection: .local, command: "custom", directory: "/work")

        let snapshot = DirectoryLauncherModel.snapshot(
            root: missing,
            configured: [saved],
            builtIn: SessionProfileManager.builtInProfiles,
            discovered: [],
            recent: [RecentSession(label: "Recent", timestamp: Date())]
        )

        XCTAssertNotNil(snapshot.directoryError)
        XCTAssertEqual(snapshot.sections.map(\.title), ["Channels", "Saved Sessions", "Recent"])
    }

    func testMissingActiveDirectoryFallsBackToProjectsPath() {
        XCTAssertEqual(
            DirectoryLauncherModel.root(activeDirectory: "/definitely/missing/holoscape-directory"),
            DefaultWorkingDirectory.projectsURL
        )
    }

    func testPerChildResourceFailureIsReportedWithoutDroppingOtherDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-resource-errors-\(UUID().uuidString)")
        let good = root.appendingPathComponent("good")
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = DirectoryLauncherModel.snapshot(
            root: root,
            configured: [], builtIn: [], discovered: [], recent: [],
            resourceValues: { url in
                if url.lastPathComponent == "bad" { throw NSError(domain: "test", code: 1) }
                return try url.resourceValues(forKeys: [.isDirectoryKey])
            }
        )

        XCTAssertEqual(snapshot.sections.first?.items.map { $0.label }, ["good"])
        XCTAssertTrue(snapshot.directoryError?.contains("bad") == true)
    }

    func testExactLabelMatchOutranksSubstringDetailMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-exact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let filtered = DirectoryLauncherModel.snapshot(
            root: root, configured: [], builtIn: SessionProfileManager.builtInProfiles, discovered: [], recent: []
        ).filtered(by: "local")

        XCTAssertEqual(filtered.sections.first?.title, "Directories")
        XCTAssertEqual(filtered.sections.first?.items.first?.label, "local")
    }
}
