import XCTest
import AppKit
@testable import Holoscape

/// Regression coverage for the intentional built-in Default baseline.
@MainActor
final class PreMigrationParityTests: XCTestCase {
    func testDefaultPaletteUsesModernCoolDarkBaseline() throws {
        let expected: [SurfaceKey: String] = [
            .windowBackground: "#10151d",
            .tabBarContainer: "#121b27",
            .tabBarTabActive: "#24485b",
            .sidebarContainer: "#121b27",
            .inputBoxField: "#182331",
            .sessionLauncherContainer: "#121b27",
            .settingsPanel: "#182331",
            .dialogContainer: "#182331",
        ]
        for (key, hex) in expected {
            guard case .color(let actual) = SkinContext.defaultSurface(for: key).fill,
                  let expectedColor = NSColor(hex: hex) else {
                XCTFail("Expected a color fill for \(key)")
                continue
            }
            assertColor(actual, equals: expectedColor, key: key)
        }
    }

    func testDefaultTransparentAndNonRenderingSurfacesStayTransparent() {
        for key in [SurfaceKey.tabBarTabNormal, .tabBarTabUnreadMarker,
                  .sidebarRowNormal, .sidebarSectionHeader, .inputBoxPlaceholder,
                  .sessionLauncherRow, .windowShape, .windowDragHandle] {
            guard case .color(let color) = SkinContext.defaultSurface(for: key).fill else {
                XCTFail("Expected a color fill for \(key)")
                continue
            }
            XCTAssertEqual(color, NSColor.clear, "\(key) must remain transparent")
        }
    }

    func testDefaultChromeHasRoundedGeometryBordersPaddingTypographyAndAnimation() {
        let input = SkinContext.defaultSurface(for: .inputBoxField)
        XCTAssertEqual(input.corner, .uniform(9))
        XCTAssertEqual(input.border?.width, 1)
        XCTAssertEqual(input.padding.top, 10)
        XCTAssertEqual(input.padding.left, 12)
        XCTAssertEqual(input.padding.bottom, 10)
        XCTAssertEqual(input.padding.right, 12)
        XCTAssertNotNil(input.font)
        XCTAssertNotNil(input.animation)

        let launcher = SkinContext.defaultSurface(for: .sessionLauncherContainer)
        XCTAssertEqual(launcher.corner, .uniform(14))
        XCTAssertEqual(launcher.border?.width, 1)
        XCTAssertEqual(launcher.padding.top, 12)
        XCTAssertEqual(launcher.padding.left, 14)
        XCTAssertEqual(launcher.padding.bottom, 12)
        XCTAssertEqual(launcher.padding.right, 14)
        XCTAssertNil(launcher.animation, "Container chrome should not animate without an interaction state")

        let tab = SkinContext.defaultSurface(for: .tabBarTabActive)
        XCTAssertEqual(tab.corner, .uniform(8))
        XCTAssertNil(tab.border, "Individual tabs should not draw nested borders")
        XCTAssertNotNil(tab.font)
        XCTAssertNotNil(tab.animation)

        let window = SkinContext.defaultSurface(for: .windowBackground)
        XCTAssertEqual(window.corner, .uniform(0))
        XCTAssertNil(window.border)
        XCTAssertNil(window.font)
        XCTAssertNil(window.animation)
    }

    func testDefaultSemanticStatesRemainDistinctAndReadable() throws {
        let snapshot = ReactiveUniformSnapshot()
        let context = SkinContext.builtInDefaults(reactive: snapshot)

        func row(notification: Int32, unread: Int32) -> SkinContext.ResolvedSurface {
            snapshot.setNotificationKind(notification)
            snapshot.setChannelState(channelId: 1, isActive: 0, unread: unread)
            return context.currentState(for: .sidebarRowNormal, with: snapshot)
        }

        let unread = row(notification: 0, unread: 1)
        let idle = row(notification: 1, unread: 0)
        let permission = row(notification: 2, unread: 0)
        guard case .color(let unreadFill) = unread.fill,
              case .color(let idleFill) = idle.fill,
              case .color(let permissionFill) = permission.fill else {
            return XCTFail("Semantic states must resolve to color fills")
        }
        XCTAssertNotEqual(unreadFill, idleFill)
        XCTAssertNotEqual(idleFill, permissionFill)
        XCTAssertNotEqual(unreadFill, permissionFill)
        XCTAssertEqual(unread.text.color, try XCTUnwrap(NSColor(hex: "#e7f2f8")))
        XCTAssertEqual(idle.text.color, try XCTUnwrap(NSColor(hex: "#75e6bd")))
        XCTAssertEqual(permission.text.color, try XCTUnwrap(NSColor(hex: "#f0c674")))
    }

    func testAppearanceConfigDefaultMatchesWindowBaseline() {
        XCTAssertEqual(AppearanceConfig.default.backgroundColor, "#10151d")
        XCTAssertEqual(AppearanceConfig.default.fontFamily, "SF Mono")
    }

    private func assertColor(_ actual: NSColor, equals expected: NSColor, key: SurfaceKey,
                             file: StaticString = #filePath, line: UInt = #line) {
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 1.0 / 255.0, "\(key) red", file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 1.0 / 255.0, "\(key) green", file: file, line: line)
        XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 1.0 / 255.0, "\(key) blue", file: file, line: line)
    }
}
