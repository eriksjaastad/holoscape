import XCTest
@testable import Holoscape

@MainActor
final class AppDelegateRestoredShellTests: XCTestCase {
    func testRestoredLegacyRootShellMigratesToDefaultProjectDirectory() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "/",
            workingDirectory: "/"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, DefaultWorkingDirectory.preferredPath)
    }

    func testRestoredFileURLRootShellMigratesToDefaultProjectDirectory() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Shell",
            workingDirectory: "file:///"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, DefaultWorkingDirectory.preferredPath)
    }

    func testRestoredNamedDirectoryIsPreserved() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "holoscape",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertEqual(restored.label, "holoscape")
        XCTAssertEqual(restored.workingDirectory, "/Users/test/projects/holoscape")
    }

    func testRestoredGenericShellLabelBecomesDynamicDirectoryLabel() {
        let metadata = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Shell",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        let restored = AppDelegate.restoredShellLaunchParameters(from: metadata)

        XCTAssertNil(restored.label)
        XCTAssertEqual(restored.workingDirectory, "/Users/test/projects/holoscape")
    }
}
