import XCTest
import SwiftCheck
@testable import Holoscape

final class RoleDetectionPropertyTests: XCTestCase {
    // Feature: holoscape-native-terminal, Property 11: CLAUDE.md role detection round-trip
    func testRoleDetectionRoundTrip() {
        // Generate role strings that don't contain special regex chars or periods
        let safeRoles = Gen<String>.fromElements(of: [
            "architect",
            "floor manager",
            "CEO",
            "caretaker",
            "developer",
            "researcher",
            "distribution researcher",
        ])

        property("Detected role matches embedded role") <- forAll(safeRoles) { (role: String) in
            let content = "> **You are the \(role).**"
            let detected = RoleDetector.detectRole(from: content)
            return detected == role
        }
    }

    func testNoMatchReturnsNil() {
        let noRoleContent = Gen<String>.fromElements(of: [
            "Just some text",
            "# README",
            "**bold text** but not a role",
            "You are the best but not in the right format",
            "",
        ])

        property("Non-matching content returns nil") <- forAll(noRoleContent) { (content: String) in
            return RoleDetector.detectRole(from: content) == nil
        }
    }
}
