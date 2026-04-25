import XCTest
@testable import Holoscape

@MainActor
final class ShellChannelControllerTests: XCTestCase {
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
