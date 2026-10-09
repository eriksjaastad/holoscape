import Foundation
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

    func testMissingConfiguredProjectRootRemainsLaunchTarget() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-missing-project-root-\(UUID().uuidString)", isDirectory: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))
        XCTAssertEqual(
            DefaultWorkingDirectory.localSessionDirectory(named: "unknown-project", root: missingRoot.path).path,
            missingRoot.standardizedFileURL.path
        )
    }
}
