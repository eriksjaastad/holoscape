import XCTest

final class TimestampToggleUITests: HoloscapeUITestCase {
    func testViewMenuDoesNotAdvertiseUnsupportedTimestamps() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()
        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertFalse(timestampItem.exists, "View menu must not expose a timestamp toggle that has no rendering behavior")
        app.typeKey(.escape, modifierFlags: [])
    }
}
