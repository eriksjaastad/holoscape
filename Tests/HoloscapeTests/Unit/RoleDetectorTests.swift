import XCTest
@testable import Holoscape

final class RoleDetectorTests: XCTestCase {
    func testDetectsFloorManager() {
        let content = """
        # CLAUDE.md

        > **You are the floor manager of holoscape.**
        """
        XCTAssertEqual(RoleDetector.detectRole(from: content), "floor manager")
    }

    func testDetectsArchitect() {
        let content = "> **You are the architect.**"
        XCTAssertEqual(RoleDetector.detectRole(from: content), "architect")
    }

    func testDetectsCEO() {
        let content = "> **You are the CEO.**"
        XCTAssertEqual(RoleDetector.detectRole(from: content), "CEO")
    }

    func testDetectsCaretaker() {
        let content = """
        # Claude -- Mac Mini (Auxesis Caretaker)

        > **You are the caretaker for Auxesis on this Mac Mini.**
        """
        XCTAssertEqual(RoleDetector.detectRole(from: content), "caretaker for Auxesis on this Mac Mini")
    }

    func testReturnsNilForNoMatch() {
        let content = "# Just a README\n\nNothing to see here."
        XCTAssertNil(RoleDetector.detectRole(from: content))
    }

    func testReturnsNilForEmptyContent() {
        XCTAssertNil(RoleDetector.detectRole(from: ""))
    }

    func testShortLabelSingleWord() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "architect"), "ARC")
        XCTAssertEqual(RoleDetector.shortLabel(for: "CEO"), "CEO")
    }

    func testShortLabelMultiWord() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "floor manager"), "FM")
    }

    func testShortLabelCaseInsensitive() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "Floor Manager"), "FM")
    }
}
