import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class ChannelDisplayLabelResolverTests: XCTestCase {
    func testSuffixClearsWhenRenamedBaseNoLongerCollides() {
        let projects = MockChannel(baseLabel: "projects")
        let renamed = MockChannel(baseLabel: "ai-memory")

        let labels = ChannelDisplayLabelResolver.labels(for: [projects, renamed])

        XCTAssertEqual(labels[projects.channelId], "projects")
        XCTAssertEqual(labels[renamed.channelId], "ai-memory")
    }

    func testCurrentCollisionsReceiveStableOrderSuffixes() {
        let first = MockChannel(baseLabel: "projects")
        let second = MockChannel(baseLabel: "projects")
        let third = MockChannel(baseLabel: "projects")

        let labels = ChannelDisplayLabelResolver.labels(for: [first, second, third])

        XCTAssertEqual(labels[first.channelId], "projects")
        XCTAssertEqual(labels[second.channelId], "projects 2")
        XCTAssertEqual(labels[third.channelId], "projects 3")
    }

    func testCollisionComparisonIsCaseInsensitive() {
        let first = MockChannel(baseLabel: "Projects")
        let second = MockChannel(baseLabel: "projects")

        let labels = ChannelDisplayLabelResolver.labels(for: [first, second])

        XCTAssertEqual(labels[first.channelId], "Projects")
        XCTAssertEqual(labels[second.channelId], "projects 2")
    }
}

@MainActor
private final class MockChannel: ChannelController {
    let channelId = UUID()
    let channelType: ChannelType = .shell
    var hasUnread = false
    var state: ChannelState = .active
    var recoveryAction: ChannelRecoveryAction? = nil
    var commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?
    let contentView = NSView()
    var activatedAt: Date? = nil

    let displayBaseLabel: String
    var displayLabel: String { displayBaseLabel }

    init(baseLabel: String) {
        self.displayBaseLabel = baseLabel
    }

    func sendInput(_ text: String) {}
    func activate() {}
    func deactivate() {}
    func retry() {}
    func lastLines(_ count: Int) -> [String] { [] }
}
