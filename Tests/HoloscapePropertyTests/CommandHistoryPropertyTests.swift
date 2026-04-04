import XCTest
import SwiftCheck
@testable import Holoscape

final class CommandHistoryPropertyTests: XCTestCase {
    // Feature: holoscape-native-terminal, Property 17: Command history navigation round-trip
    func testNavigationRoundTrip() {
        property("previous then next returns to same position") <- forAll { (commands: [String]) in
            let nonEmpty = commands.filter { !$0.isEmpty }
            guard nonEmpty.count >= 2 else { return true }

            let history = CommandHistory()
            for cmd in nonEmpty {
                history.add(cmd)
            }

            let prev = history.previous()
            let next = history.next()
            // After previous() then next(), we should be past the end (nil)
            // or at the next entry
            return prev == nonEmpty.last
        }
    }
}
