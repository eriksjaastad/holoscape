import XCTest
@testable import Holoscape

final class ShellDirectoryTrackerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-shell-tracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testRelativeCdUpdatesCurrentDirectoryFromTypedInput() throws {
        let project = tempRoot.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var tracker = ShellDirectoryTracker(currentDirectory: tempRoot.path)

        let next = tracker.consume(data: Array("cd holoscape\r".utf8)[...])

        XCTAssertEqual(next, project.standardizedFileURL.path)
        XCTAssertEqual(tracker.currentDirectory, project.standardizedFileURL.path)
    }

    func testBackspaceEditingIsAppliedBeforeCdResolution() throws {
        let project = tempRoot.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var tracker = ShellDirectoryTracker(currentDirectory: tempRoot.path)

        let bytes = Array("cd holoscapx".utf8) + [127] + Array("e\r".utf8)
        let next = tracker.consume(data: bytes[...])

        XCTAssertEqual(next, project.standardizedFileURL.path)
    }

    func testCdDashReturnsPreviousDirectory() throws {
        let project = tempRoot.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var tracker = ShellDirectoryTracker(currentDirectory: tempRoot.path)

        _ = tracker.consume(data: Array("cd holoscape\r".utf8)[...])
        let next = tracker.consume(data: Array("cd -\r".utf8)[...])

        XCTAssertEqual(next, tempRoot.standardizedFileURL.path)
        XCTAssertEqual(tracker.currentDirectory, tempRoot.standardizedFileURL.path)
    }

    func testHostDirectoryUpdateAcceptsFileURL() throws {
        let project = tempRoot.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var tracker = ShellDirectoryTracker(currentDirectory: tempRoot.path)

        let next = tracker.applyHostDirectoryUpdate(project.absoluteString)

        XCTAssertEqual(next, project.standardizedFileURL.path)
    }
}
