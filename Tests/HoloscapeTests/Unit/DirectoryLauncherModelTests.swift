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

        let snapshot = try DirectoryLauncherModel.snapshot(
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

        let snapshot = try DirectoryLauncherModel.snapshot(
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
}
