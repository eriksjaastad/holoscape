import XCTest
@testable import Holoscape

/// Requirement 3.4: SurfaceKey enum covers every chrome surface with stable
/// raw values. Rename drift must be caught by the compiler.
final class SurfaceKeyTests: XCTestCase {

    func testAllCasesCount() {
        // 23 v2 surfaces (chrome-skinning) + 13 v3 surfaces (Amplify) = 36
        // total. The v2 catalog lives in docs/skins/06-chrome-skinning.md §6;
        // the Amplify additions are in claude-specs/amplify/design.md
        // §SurfaceKey extensions.
        XCTAssertEqual(SurfaceKey.allCases.count, 36)
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
        // v2 surfaces
        XCTAssertEqual(SurfaceKey(rawValue: "tabBar.tab.active"), .tabBarTabActive)
        XCTAssertEqual(SurfaceKey(rawValue: "sidebar.row.indicator"), .sidebarRowIndicator)
        XCTAssertEqual(SurfaceKey(rawValue: "window.background"), .windowBackground)
        XCTAssertEqual(SurfaceKey(rawValue: "inputBox.field"), .inputBoxField)

        // v3 (Amplify) surfaces — pin the raw values so a typo on the
        // enum side is caught here and not at skin-author time.
        XCTAssertEqual(SurfaceKey(rawValue: "tabBar.tab.hover"), .tabBarTabHover)
        XCTAssertEqual(SurfaceKey(rawValue: "tabBar.tab.pressed"), .tabBarTabPressed)
        XCTAssertEqual(SurfaceKey(rawValue: "sidebar.row.pressed"), .sidebarRowPressed)
        XCTAssertEqual(SurfaceKey(rawValue: "sessionLauncher.button.normal"), .sessionLauncherButtonNormal)
        XCTAssertEqual(SurfaceKey(rawValue: "sessionLauncher.button.hover"), .sessionLauncherButtonHover)
        XCTAssertEqual(SurfaceKey(rawValue: "sessionLauncher.button.pressed"), .sessionLauncherButtonPressed)
        XCTAssertEqual(SurfaceKey(rawValue: "readerPanel.titleBar"), .readerPanelTitleBar)
        XCTAssertEqual(SurfaceKey(rawValue: "readerPanel.background"), .readerPanelBackground)
        XCTAssertEqual(SurfaceKey(rawValue: "readerPanel.closeButton.normal"), .readerPanelCloseButtonNormal)
        XCTAssertEqual(SurfaceKey(rawValue: "readerPanel.closeButton.hover"), .readerPanelCloseButtonHover)
        XCTAssertEqual(SurfaceKey(rawValue: "readerPanel.closeButton.pressed"), .readerPanelCloseButtonPressed)
        XCTAssertEqual(SurfaceKey(rawValue: "window.shape"), .windowShape)
        XCTAssertEqual(SurfaceKey(rawValue: "window.dragHandle"), .windowDragHandle)
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
