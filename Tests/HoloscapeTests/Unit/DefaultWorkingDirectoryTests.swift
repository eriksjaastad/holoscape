import XCTest
@testable import Holoscape

final class DefaultWorkingDirectoryTests: XCTestCase {
    func testLaunchURLFallsBackToPreferredDirectoryWhenURLSchemeOmitsDirectory() {
        XCTAssertEqual(
            DefaultWorkingDirectory.launchURL(fromOptionalPath: nil),
            DefaultWorkingDirectory.preferredURL
        )
        XCTAssertEqual(
            DefaultWorkingDirectory.launchURL(fromOptionalPath: ""),
            DefaultWorkingDirectory.preferredURL
        )
    }

    func testLaunchURLExpandsExplicitDirectory() {
        XCTAssertEqual(
            DefaultWorkingDirectory.launchURL(fromOptionalPath: "~/projects"),
            DefaultWorkingDirectory.projectsURL
        )
    }
}
