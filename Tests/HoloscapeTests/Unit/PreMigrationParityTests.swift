import XCTest
import AppKit
@testable import Holoscape

/// Task 10 — Pre-migration parity checkpoint.
///
/// Every surface in `SkinContext.builtInDefaults` must resolve to the
/// exact color the pre-migration chrome view painted. Freezing the
/// pre-migration values here catches drift in `SkinContext.defaultSurface`
/// that would change how Holoscape looks with no skin loaded — one of
/// the spec's hard contracts for Task 10.
///
/// Reference SHA: `e0aae6f` — merge of PR #102, immediately before PR
/// #103 started migrating views. Colors below were extracted via:
///   `git show e0aae6f:Sources/Holoscape/Views/<View>.swift` and
///   `git show e0aae6f:Sources/Holoscape/Controllers/MainWindowController.swift`
///
/// Note on the Mac-Mini pass: this test freezes the built-in defaults
/// at the COLOR level. A full visual regression (rendered chrome vs.
/// a pre-migration build) still requires Mac-Mini dogfooding — see
/// `claude-specs/chrome-skinning/tasks.md` Task 10's body for that
/// follow-up. The laptop-side invariant is "every default fill matches
/// the pre-migration hex"; the Mac-Mini pass verifies no layout / font
/// / shadow / compositing regression on top.
@MainActor
final class PreMigrationParityTests: XCTestCase {

    // MARK: - Window
    //
    // Source: MainWindowController.swift at e0aae6f
    //   window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)

    func testWindowBackgroundMatchesPreMigration() {
        assertDefaultFillEquals(.windowBackground,
                                NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
    }

    func testWindowTitleBarMatchesWindowBackground() {
        // Pre-migration: no distinct title bar color; window chrome used
        // the same value. The tab bar covers the titlebar band today via
        // tabs-in-titlebar (PR #98), so this surface is spec-level but
        // not painted.
        assertDefaultFillEquals(.windowTitleBar,
                                NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
    }

    // MARK: - Tab bar
    //
    // Source: TabBarView.swift at e0aae6f
    //   barBg         = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0)
    //   activeTabBg   = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0)
    //   idleBg        = NSColor(red: 0.10, green: 0.22, blue: 0.12, alpha: 1.0)
    //   permissionBg  = NSColor(red: 0.24, green: 0.16, blue: 0.08, alpha: 1.0)

    func testTabBarContainerMatchesPreMigration() {
        assertDefaultFillEquals(.tabBarContainer,
                                NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0))
    }

    func testTabBarTabActiveMatchesPreMigration() {
        assertDefaultFillEquals(.tabBarTabActive,
                                NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
    }

    func testTabBarTabIdleMatchesPreMigration() {
        assertDefaultFillEquals(.tabBarTabIdle,
                                NSColor(red: 0.10, green: 0.22, blue: 0.12, alpha: 1.0))
    }

    func testTabBarTabPermissionMatchesPreMigration() {
        assertDefaultFillEquals(.tabBarTabPermission,
                                NSColor(red: 0.24, green: 0.16, blue: 0.08, alpha: 1.0))
    }

    func testTabBarNormalTabIsClear() {
        // Normal tabs had no fill — the button chrome floated over the bar.
        assertDefaultFillEquals(.tabBarTabNormal, .clear)
    }

    func testTabBarUnreadMarkerIsClear() {
        // Marker was drawn by the button's own layer ring; no filled
        // surface. Keeps clear so the unread variant has somewhere to go.
        assertDefaultFillEquals(.tabBarTabUnreadMarker, .clear)
    }

    // MARK: - Sidebar
    //
    // Source: SidebarView.swift at e0aae6f
    //   containerBg = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0)
    //   activeBg    = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0)
    //   unreadBg    = NSColor(red: 0.10, green: 0.10, blue: 0.22, alpha: 1.0)
    //   sidebarRowIndicator: systemGreen (base) / yellow / red via state variants

    func testSidebarContainerMatchesPreMigration() {
        assertDefaultFillEquals(.sidebarContainer,
                                NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0))
    }

    func testSidebarRowSelectedMatchesPreMigration() {
        assertDefaultFillEquals(.sidebarRowSelected,
                                NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
    }

    func testSidebarRowNormalIsClear() {
        // Base fill is clear; per-row state variants paint the
        // notification states (unread / idle / permission).
        assertDefaultFillEquals(.sidebarRowNormal, .clear)
    }

    func testSidebarRowHoverIsClear() {
        assertDefaultFillEquals(.sidebarRowHover, .clear)
    }

    func testSidebarRowIndicatorIsSystemGreen() {
        // Base indicator is the active (connected) color; state variants
        // paint yellow for connecting and red for disconnected. A missing
        // variant stays visible as the active green — bug-visible rather
        // than silently going invisible.
        assertDefaultFillEquals(.sidebarRowIndicator, .systemGreen)
    }

    func testSidebarSectionHeaderIsClear() {
        assertDefaultFillEquals(.sidebarSectionHeader, .clear)
    }

    // MARK: - Input box
    //
    // Source: InputBoxView.swift at e0aae6f
    //   backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0)

    func testInputBoxContainerMatchesPreMigration() {
        assertDefaultFillEquals(.inputBoxContainer,
                                NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0))
    }

    func testInputBoxFieldMatchesPreMigration() {
        // Field used the same color as the container pre-migration — no
        // distinct field color. Both surfaces retain the same default.
        assertDefaultFillEquals(.inputBoxField,
                                NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0))
    }

    func testInputBoxPlaceholderIsClear() {
        assertDefaultFillEquals(.inputBoxPlaceholder, .clear)
    }

    // MARK: - Session launcher
    //
    // Source: SessionLauncherView.swift at e0aae6f
    //   layer.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0)

    func testSessionLauncherContainerMatchesPreMigration() {
        assertDefaultFillEquals(.sessionLauncherContainer,
                                NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0))
    }

    func testSessionLauncherRowIsClear() {
        assertDefaultFillEquals(.sessionLauncherRow, .clear)
    }

    // MARK: - Split pane
    //
    // Source: SplitPaneView.swift at e0aae6f
    //   activeBorder = NSColor.systemBlue.withAlphaComponent(0.6)
    //
    // The splitPaneDivider surface is reused for the active-pane border
    // color (documented in SmallViewsSkinContextTests). Its FILL is
    // systemBlue@0.6 alpha — views pull .border from the skin but the
    // default fill at the SkinContext layer carries the historical color
    // so a theme-less render matches pre-migration.

    func testSplitPaneDividerMatchesPreMigration() {
        assertDefaultFillEquals(.splitPaneDivider,
                                NSColor.systemBlue.withAlphaComponent(0.6))
    }

    // MARK: - Orphan surfaces (spec-level, no painter today)

    func testTerminalContainerPaddingMatchesPreMigration() {
        // TerminalContainerView was deleted in PR #107. The surface
        // remains in the enum at spec level; its default matches the
        // window-chrome color since that's what a future terminal-
        // wrapping view would paint against.
        assertDefaultFillEquals(.terminalContainerPadding,
                                NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
    }

    func testSettingsAndDialogPanelsMatchWindowChrome() {
        // These surfaces weren't painted in the 5 migrated views
        // (settings/dialogs live in separate nibs). Defaults align with
        // the window chrome color so they don't pop on presentation.
        let chrome = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        assertDefaultFillEquals(.settingsPanel, chrome)
        assertDefaultFillEquals(.dialogContainer, chrome)
    }

    // MARK: - Enum integrity

    func testAllSurfaceKeysHaveAFill() {
        // Cheap invariant: defaultSurface must return a .color fill for
        // every key. Catches a new SurfaceKey case added without a
        // corresponding default (the `switch` in defaultSurface is
        // exhaustive so this is belt-and-suspenders).
        //
        // 23 v2 (chrome-skinning) + 13 v3 (Amplify) = 36 total. The pre-
        // migration parity below iterates the v2 subset explicitly so
        // this test purely guards "every case has a default."
        XCTAssertEqual(SurfaceKey.allCases.count, 36,
                       "Surface catalog size is load-bearing: every skin manifest key references this set")
        for key in SurfaceKey.allCases {
            let resolved = SkinContext.defaultSurface(for: key)
            switch resolved.fill {
            case .color:
                break
            default:
                XCTFail("Surface \(key) defaulted to non-color fill (\(resolved.fill))")
            }
        }
    }

    // MARK: - Helper

    /// Compare `SkinContext.defaultSurface(for: key).fill` against the
    /// expected NSColor within 1/255 tolerance (RGB8 round-trip noise).
    ///
    /// The test accepts any color representation — sRGB, device RGB,
    /// catalog — as long as the sRGB-normalized component values agree.
    /// A strict `== cgColor` compare would false-fail across color-
    /// space conversions that don't change the observable color.
    private func assertDefaultFillEquals(_ key: SurfaceKey, _ expected: NSColor,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let resolved = SkinContext.defaultSurface(for: key)
        guard case .color(let actual) = resolved.fill else {
            XCTFail("\(key) resolved to non-color fill", file: file, line: line)
            return
        }
        let a = actual.usingColorSpace(.sRGB) ?? actual
        let e = expected.usingColorSpace(.sRGB) ?? expected
        let tolerance: CGFloat = 1.0 / 255.0
        XCTAssertEqual(a.redComponent,   e.redComponent,   accuracy: tolerance,
                       "\(key) red drift", file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: tolerance,
                       "\(key) green drift", file: file, line: line)
        XCTAssertEqual(a.blueComponent,  e.blueComponent,  accuracy: tolerance,
                       "\(key) blue drift", file: file, line: line)
        XCTAssertEqual(a.alphaComponent, e.alphaComponent, accuracy: tolerance,
                       "\(key) alpha drift", file: file, line: line)
    }
}
