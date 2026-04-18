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

    /// Unread state flows through a `channelUnread: { $gte: 1 }` state
    /// variant on `sidebarRowNormal`. Providing a skin that overrides
    /// the variant must repaint unread rows.
    func testUnreadStateRespondsToSkinVariant() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        // Build a surface with a skin-defined unread variant.
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        let unreadOrange = NSColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        surfaces[.sidebarRowNormal] = SkinContext.ResolvedSurface(
            fill: .color(.clear),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .lightGray, shadow: nil),
            animation: nil,
            states: [
                StateVariant(
                    name: "unread",
                    match: MatchExpression(conditions: ["channelUnread": .operators(["$gte": 1])]),
                    fill: .color("#ff8000")
                )
            ]
        )
        entry.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        entry.configure(label: "test", hasUnread: true, state: .active, isActive: false)

        assertCGColorComponentsHex(entry.layer?.backgroundColor, unreadOrange.cgColor,
                                   reason: "Unread row must pick up the skin's unread state variant")
    }

    // MARK: - Helpers

    // MARK: - Notification-state regression guards

    /// Permission-prompt state flows through a
    /// `notificationKind: 2` variant on `sidebarRowNormal`. A skin that
    /// overrides that variant must repaint permission-state rows.
    func testPermissionStateRespondsToSkinVariant() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        let permissionMagenta = NSColor(red: 0.8, green: 0, blue: 0.5, alpha: 1)
        surfaces[.sidebarRowNormal] = SkinContext.ResolvedSurface(
            fill: .color(.clear),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .lightGray, shadow: nil),
            animation: nil,
            states: [
                StateVariant(
                    name: "permission",
                    match: MatchExpression(conditions: ["notificationKind": .scalar(2)]),
                    fill: .color("#cc0080")
                )
            ]
        )
        entry.skinContext = SkinContext(surfaces: surfaces, reactive: snap)
        entry.configure(label: "test", hasUnread: false, state: .active,
                        isActive: false, notificationType: "permission_prompt")
        assertCGColorComponentsHex(entry.layer?.backgroundColor, permissionMagenta.cgColor,
                                   reason: "Permission row must pick up the skin's notificationKind=2 variant")
    }

    /// Per-entry snapshot isolation — two rows with different
    /// `hasUnread` must resolve to different fills at the same moment.
    /// This is the whole point of Option B; would be impossible with a
    /// shared snapshot.
    func testTwoRowsWithDifferentUnreadResolveIndependently() {
        let quiet = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        let loud = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))

        let snap = ReactiveUniformSnapshot()
        var surfaces = SkinContext.builtInDefaults(reactive: snap).allResolvedSurfacesForTesting
        surfaces[.sidebarRowNormal] = SkinContext.ResolvedSurface(
            fill: .color(.clear),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .lightGray, shadow: nil),
            animation: nil,
            states: [
                StateVariant(
                    name: "unread",
                    match: MatchExpression(conditions: ["channelUnread": .operators(["$gte": 1])]),
                    fill: .color("#ff0000")
                )
            ]
        )
        let ctx = SkinContext(surfaces: surfaces, reactive: snap)
        quiet.skinContext = ctx
        loud.skinContext = ctx

        quiet.configure(label: "quiet", hasUnread: false, state: .active, isActive: false)
        loud.configure(label: "loud", hasUnread: true, state: .active, isActive: false)

        // Quiet resolves to the base `.clear` fill — fully transparent.
        let quietAlpha = quiet.layer?.backgroundColor?.alpha ?? -1
        XCTAssertEqual(quietAlpha, 0, accuracy: 0.001,
                       "Row without unread must resolve to transparent base fill")
        // Loud resolves to the state variant (→ red). Hex-derived so
        // use the relaxed tolerance.
        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor
        assertCGColorComponentsHex(loud.layer?.backgroundColor, red,
                                   reason: "Row with unread must resolve to the unread variant color — independently of its sibling")
    }

    // MARK: - Fallback / skinned-default parity

    /// Guards against drift between `SidebarTabEntry`'s standalone-render
    /// fallback constants and `SkinContext.builtInDefaults`' state
    /// variants. For each (hasUnread, notificationType) combination the
    /// skinned path should paint the same CGColor the standalone path
    /// would — and if a future contributor tweaks one side without the
    /// other, this test fires.
    func testSkinnedDefaultMatchesStandaloneFallback() {
        struct Case {
            let label: String
            let hasUnread: Bool
            let notificationType: String?
            let expectedHex: String
        }
        let cases: [Case] = [
            Case(label: "unread", hasUnread: true, notificationType: nil, expectedHex: "#1a1a38"),
            Case(label: "idle", hasUnread: false, notificationType: "idle_prompt", expectedHex: "#0d4019"),
            Case(label: "permission", hasUnread: false, notificationType: "permission_prompt", expectedHex: "#66400d"),
        ]
        for testCase in cases {
            let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
            entry.skinContext = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())
            entry.configure(label: testCase.label, hasUnread: testCase.hasUnread,
                            state: .active, isActive: false,
                            notificationType: testCase.notificationType)
            let expected = NSColor(hex: testCase.expectedHex)?.cgColor ?? .clear
            assertCGColorComponentsHex(entry.layer?.backgroundColor, expected,
                                       reason: "Skinned default for \(testCase.label) must match fallback hex \(testCase.expectedHex)")
        }
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

    /// Strict equality (0.001). Use when both sides are constructed
    /// from the same NSColor(red:) path so no hex rounding is involved.
    private func assertCGColorComponents(_ actual: CGColor?, _ expected: CGColor,
                                         reason: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        assertCGColorComponents(actual, expected, accuracy: 0.001, reason: reason, file: file, line: line)
    }

    /// Relaxed tolerance (0.01) for cases where the expected color is
    /// hex-derived; 8-bit hex can't represent arbitrary floating-point
    /// component values exactly (`#80` = 128/255 ≈ 0.502 vs 0.5).
    private func assertCGColorComponentsHex(_ actual: CGColor?, _ expected: CGColor,
                                            reason: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        assertCGColorComponents(actual, expected, accuracy: 0.01, reason: reason, file: file, line: line)
    }

    private func assertCGColorComponents(_ actual: CGColor?, _ expected: CGColor,
                                         accuracy: CGFloat,
                                         reason: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        guard let a = actual?.components, let e = expected.components else {
            XCTFail("\(reason): missing components", file: file, line: line)
            return
        }
        XCTAssertEqual(a.count, e.count, reason, file: file, line: line)
        for (ac, ec) in zip(a, e) {
            XCTAssertEqual(ac, ec, accuracy: accuracy, reason, file: file, line: line)
        }
    }
}
