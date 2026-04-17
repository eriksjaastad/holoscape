import XCTest
@testable import Holoscape

/// Requirement 3.4: SurfaceKey enum covers every chrome surface with stable
/// raw values. Rename drift must be caught by the compiler.
final class SurfaceKeyTests: XCTestCase {

    func testAllCasesCount() {
        // 23 surfaces per the catalog in docs/skins/06-chrome-skinning.md §6.
        XCTAssertEqual(SurfaceKey.allCases.count, 23)
    }

    func testAllRawValuesAreUnique() {
        let raws = SurfaceKey.allCases.map(\.rawValue)
        let uniq = Set(raws)
        XCTAssertEqual(raws.count, uniq.count, "Duplicate raw values detected")
    }

    func testAllRawValuesNonEmpty() {
        for key in SurfaceKey.allCases {
            XCTAssertFalse(key.rawValue.isEmpty, "\(key) has an empty raw value")
        }
    }

    func testRawValuesAreHierarchical() {
        // Every key either has no dot (single-level, e.g. never used today)
        // or uses dot-separated hierarchy. None should use slashes or spaces.
        for key in SurfaceKey.allCases {
            XCTAssertFalse(key.rawValue.contains("/"), "\(key.rawValue) uses slash")
            XCTAssertFalse(key.rawValue.contains(" "), "\(key.rawValue) contains space")
        }
    }

    func testKnownKeysResolve() {
        XCTAssertEqual(SurfaceKey(rawValue: "tabBar.tab.active"), .tabBarTabActive)
        XCTAssertEqual(SurfaceKey(rawValue: "sidebar.row.indicator"), .sidebarRowIndicator)
        XCTAssertEqual(SurfaceKey(rawValue: "window.background"), .windowBackground)
        XCTAssertEqual(SurfaceKey(rawValue: "inputBox.field"), .inputBoxField)
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(SurfaceKey(rawValue: "nonexistent.surface"))
        XCTAssertNil(SurfaceKey(rawValue: ""))
        XCTAssertNil(SurfaceKey(rawValue: "TabBar.Container"))  // case-sensitive
    }

    func testCodableRoundTrip() throws {
        for key in SurfaceKey.allCases {
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(SurfaceKey.self, from: data)
            XCTAssertEqual(key, decoded)
        }
    }
}
