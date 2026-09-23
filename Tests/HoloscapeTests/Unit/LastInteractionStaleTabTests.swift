import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class LastInteractionStaleTabTests: XCTestCase {
    func testChannelRecordsUserInteractionTimestamp() {
        let channel = MockChannelController(label: "agent", state: .active)
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        channel.recordUserInteraction(at: first)
        XCTAssertEqual(channel.lastInteractionAt, first)

        channel.recordUserInteraction(at: second)
        XCTAssertEqual(channel.lastInteractionAt, second)
    }

    func testTopTabShowsStaleBadgeWhenLastInteractionExceedsThreshold() {
        let channel = MockChannelController(label: "agent", state: .active)
        channel.recordUserInteraction(at: Date(timeIntervalSince1970: 0))
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))

        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            now: Date(timeIntervalSince1970: 46 * 60),
            staleThreshold: 45 * 60
        )

        let titles = view.allSubviews(of: NSButton.self).map(\.title)
        XCTAssertTrue(titles.contains("◌ agent"), "Expected stale badge prefix once the tab crosses the configured threshold, got \(titles)")
    }

    func testTopTabDoesNotShowStaleBadgeBeforeConfiguredThreshold() {
        let channel = MockChannelController(label: "agent", state: .active)
        channel.recordUserInteraction(at: Date(timeIntervalSince1970: 0))
        let view = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))

        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            now: Date(timeIntervalSince1970: 44 * 60),
            staleThreshold: 45 * 60
        )

        let titles = view.allSubviews(of: NSButton.self).map(\.title)
        XCTAssertTrue(titles.contains("agent"))
        XCTAssertFalse(titles.contains("◌ agent"))
    }

    func testSidebarAccessibilityMarksStaleInteraction() throws {
        let channel = MockChannelController(label: "agent", state: .active)
        channel.recordUserInteraction(at: Date(timeIntervalSince1970: 0))
        let view = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))

        view.updateTabs(
            channels: [channel],
            activeId: channel.channelId,
            now: Date(timeIntervalSince1970: 46 * 60),
            staleThreshold: 45 * 60
        )

        let entry = try XCTUnwrap(view.allSubviews(of: SidebarTabEntry.self).first)
        XCTAssertEqual(entry.accessibilityValue() as? String, "stale-interaction")
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        var matches: [T] = []
        for subview in subviews {
            if let typed = subview as? T {
                matches.append(typed)
            }
            matches.append(contentsOf: subview.allSubviews(of: type))
        }
        return matches
    }
}
