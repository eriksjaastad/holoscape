import XCTest
import AppKit
@testable import Holoscape

/// Task 9.2 — SidebarView + SidebarTabEntry read container, selected-row,
/// and normal-row fills from the injected SkinContext. The four
/// notification-state colors (permission / idle / unread + their text
/// tints) remain hardcoded; state-variant reactive matching for those
/// lands with Task 11.
@MainActor
final class SidebarViewSkinContextTests: XCTestCase {

    private func context(_ overrides: [SurfaceKey: NSColor]) -> SkinContext {
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        for (key, color) in overrides {
            surfaces[key] = SkinContext.ResolvedSurface(
                fill: .color(color), border: nil, corner: .uniform(0),
                padding: .init(), shadow: nil, font: nil,
                text: .init(color: color, shadow: nil),
                animation: nil, states: []
            )
        }
        return SkinContext(surfaces: surfaces, reactive: snap)
    }

    // MARK: - SidebarView container

    func testSidebarContainerRepaintsFromSkin() {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let teal = NSColor(red: 0, green: 0.5, blue: 0.5, alpha: 1)
        view.skinContext = context([.sidebarContainer: teal])
        XCTAssertEqual(view.layer?.backgroundColor, teal.cgColor)
    }

    func testSidebarContainerNilRestoresBuiltIn() {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        view.skinContext = context([.sidebarContainer: .red])
        view.skinContext = nil

        let expected = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor
        guard let actual = view.layer?.backgroundColor,
              let a = actual.components, let e = expected.components else {
            XCTFail("Missing components")
            return
        }
        XCTAssertEqual(a.count, e.count)
        for (ac, ec) in zip(a, e) {
            XCTAssertEqual(ac, ec, accuracy: 0.001)
        }
    }

    // MARK: - SidebarTabEntry selected/normal

    func testTabEntrySelectedFillFromSkin() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let purple = NSColor(red: 0.5, green: 0, blue: 0.8, alpha: 1)
        entry.skinContext = context([.sidebarRowSelected: purple])
        entry.configure(label: "test", hasUnread: false, state: .active, isActive: true)
        assertCGColorComponents(entry.layer?.backgroundColor, purple.cgColor,
                                reason: "Selected row fill comes from sidebar.row.selected")
    }

    func testTabEntryNormalFillFromSkin() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let navy = NSColor(red: 0.05, green: 0.05, blue: 0.15, alpha: 1)
        entry.skinContext = context([.sidebarRowNormal: navy])
        entry.configure(label: "test", hasUnread: false, state: .active, isActive: false)
        assertCGColorComponents(entry.layer?.backgroundColor, navy.cgColor,
                                reason: "Non-active, non-notification, non-unread rows use sidebar.row.normal")
    }

    // MARK: - Notification path

    func testSkinDidChangeNotificationRefreshesContainer() {
        // Set a skin, forcibly wipe the layer background, then post
        // .skinDidChange and assert the observer re-resolves the fill.
        // Breaks if the selector is misnamed or the observer isn't wired.
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let gold = NSColor(red: 1, green: 0.84, blue: 0, alpha: 1)
        view.skinContext = context([.sidebarContainer: gold])
        view.layer?.backgroundColor = NSColor.black.cgColor

        NotificationCenter.default.post(name: .skinDidChange, object: nil)
        assertCGColorComponents(view.layer?.backgroundColor, gold.cgColor,
                                reason: "SidebarView observer must re-resolve on .skinDidChange")
    }

    func testSkinDidChangeNotificationReRunsEntryConfigure() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        entry.configure(label: "test", hasUnread: false, state: .active, isActive: true)

        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        entry.skinContext = context([.sidebarRowSelected: red])
        entry.layer?.backgroundColor = NSColor.clear.cgColor

        NotificationCenter.default.post(name: .skinDidChange, object: nil)
        assertCGColorComponents(entry.layer?.backgroundColor, red.cgColor,
                                reason: "Entry observer must re-run last configure on .skinDidChange")
    }

    // MARK: - Forwarding to existing rows

    func testSidebarSkinSwapPropagatesToExistingEntries() throws {
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        let channel = MockChannelController(type: .shell, label: "A", state: .active)
        view.updateTabs(channels: [channel], activeId: channel.channelId)

        // Dig the entry out of the stack view — it's the first
        // arranged subview under the scroll view.
        guard let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first,
              let stack = scroll.documentView as? NSStackView,
              let entry = stack.arrangedSubviews.first as? SidebarTabEntry else {
            XCTFail("Expected one SidebarTabEntry after updateTabs")
            return
        }

        let lime = NSColor(red: 0.5, green: 1, blue: 0, alpha: 1)
        view.skinContext = context([.sidebarRowSelected: lime])
        assertCGColorComponents(entry.layer?.backgroundColor, lime.cgColor,
                                reason: "didSet forwarding loop must propagate context to existing rows")
    }

    // MARK: - Unread regression guard

    /// Parallel to testPermissionStateIgnoresSkinFillToday — confirms
    /// the unread state is a deferred hardcoded path that must NOT
    /// pick up a skin fill until Task 11 wires reactive matches.
    func testUnreadStateIgnoresSkinFill() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        entry.skinContext = context([
            .sidebarRowSelected: .red,
            .sidebarRowNormal: .blue,
        ])
        entry.configure(label: "test", hasUnread: true, state: .active, isActive: false)

        let expected = NSColor(red: 0.1, green: 0.1, blue: 0.22, alpha: 1.0).cgColor
        assertCGColorComponents(entry.layer?.backgroundColor, expected,
                                reason: "Unread state must stay hardcoded — skin wiring lands with Task 11")
    }

    // MARK: - Helpers

    // MARK: - Notification-state regression guards

    /// Notification-state colors aren't skinned yet — they must stay
    /// on the hardcoded values regardless of what the skin declares
    /// for `sidebar.row.*`. Regression guard for Task 11 not being
    /// accidentally blocked here.
    func testPermissionStateIgnoresSkinFillToday() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        entry.skinContext = context([
            .sidebarRowSelected: .red,
            .sidebarRowNormal: .blue,
        ])
        entry.configure(label: "test", hasUnread: false, state: .active,
                        isActive: false, notificationType: "permission_prompt")
        let expected = NSColor(red: 0.4, green: 0.25, blue: 0.05, alpha: 1.0).cgColor
        assertCGColorComponents(entry.layer?.backgroundColor, expected,
                                reason: "Permission bg must stay hardcoded until Task 11")
    }

    // MARK: - Skin swap re-applies configure

    func testSkinSwapReRunsLastConfigure() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        entry.configure(label: "test", hasUnread: false, state: .active, isActive: true)

        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        entry.skinContext = context([.sidebarRowSelected: red])
        assertCGColorComponents(entry.layer?.backgroundColor, red.cgColor,
                                reason: "Assigning a skin context must re-run the last configure")
    }

    // MARK: - Helpers

    private func assertCGColorComponents(_ actual: CGColor?, _ expected: CGColor,
                                         reason: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let a = actual?.components, let e = expected.components else {
            XCTFail("\(reason): missing components", file: file, line: line)
            return
        }
        XCTAssertEqual(a.count, e.count, reason, file: file, line: line)
        for (ac, ec) in zip(a, e) {
            XCTAssertEqual(ac, ec, accuracy: 0.001, reason, file: file, line: line)
        }
    }
}
