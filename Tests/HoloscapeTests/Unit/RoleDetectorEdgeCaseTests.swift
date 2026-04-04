import XCTest
@testable import Holoscape

final class RoleDetectorEdgeCaseTests: XCTestCase {

    // MARK: - Role Detection Edge Cases

    func testRoleWithExtraWhitespace() {
        let content = "> **You are the  floor manager  of holoscape.**"
        let role = RoleDetector.detectRole(from: content)
        XCTAssertNotNil(role)
        // Should trim whitespace
        XCTAssertFalse(role!.hasPrefix(" "))
        XCTAssertFalse(role!.hasSuffix(" "))
    }

    func testRoleDetectionCaseInsensitive() {
        let lower = RoleDetector.detectRole(from: "> **you are the architect.**")
        let upper = RoleDetector.detectRole(from: "> **You are the architect.**")
        XCTAssertEqual(lower, upper)
    }

    func testRoleWithoutProject() {
        let content = "> **You are the Architect.**"
        let role = RoleDetector.detectRole(from: content)
        XCTAssertEqual(role, "Architect")
    }

    func testRoleWithProject() {
        let content = "> **You are the floor manager of holoscape.**"
        let role = RoleDetector.detectRole(from: content)
        XCTAssertEqual(role, "floor manager")
    }

    func testRoleWithoutTrailingPeriod() {
        let content = "> **You are the CEO**"
        let role = RoleDetector.detectRole(from: content)
        XCTAssertEqual(role, "CEO")
    }

    func testMultipleRolePatternsReturnsFirst() {
        let content = """
        > **You are the Architect.**
        > **You are the floor manager of project-x.**
        """
        let role = RoleDetector.detectRole(from: content)
        XCTAssertEqual(role, "Architect")
    }

    func testNoRolePatternReturnsNil() {
        let content = "# CLAUDE.md\n\nThis is a regular file with no role."
        XCTAssertNil(RoleDetector.detectRole(from: content))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(RoleDetector.detectRole(from: ""))
    }

    func testPartialPatternDoesNotMatch() {
        let content = "**You are the**"
        XCTAssertNil(RoleDetector.detectRole(from: content))
    }

    func testRoleEmbeddedInLargerDocument() {
        let content = """
        # CLAUDE.md - holoscape

        > **You are the floor manager of holoscape.** You own this project's Kanban board, write code, create PRs.

        Run `pt info -p holoscape` for tech stack.
        Run `pt memory search "holoscape"` before starting work.

        ## Build

        ```bash
        swift build
        ```
        """
        let role = RoleDetector.detectRole(from: content)
        XCTAssertEqual(role, "floor manager")
    }

    // MARK: - Short Label Edge Cases

    func testShortLabelSingleShortWord() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "CEO"), "CEO")
    }

    func testShortLabelSingleLongWord() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "architect"), "ARC")
    }

    func testShortLabelTwoWords() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "floor manager"), "FM")
    }

    func testShortLabelThreeWords() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "chief technology officer"), "CTO")
    }

    func testShortLabelPreservesCase() {
        // Input case shouldn't matter — output is always uppercase
        XCTAssertEqual(RoleDetector.shortLabel(for: "Floor Manager"), "FM")
        XCTAssertEqual(RoleDetector.shortLabel(for: "FLOOR MANAGER"), "FM")
        XCTAssertEqual(RoleDetector.shortLabel(for: "floor manager"), "FM")
    }

    func testShortLabelSingleCharacterWord() {
        XCTAssertEqual(RoleDetector.shortLabel(for: "a"), "A")
    }
}
