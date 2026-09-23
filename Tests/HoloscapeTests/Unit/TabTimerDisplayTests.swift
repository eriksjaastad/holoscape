import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class TabTimerDisplayTests: XCTestCase {
    func testTopTabTitleDoesNotAppendElapsedActivationTimer() {
        let channel = MockTimerChannel(
            label: "ai-memory",
            state: .active,
            activatedAt: Date().addingTimeInterval(-24 * 60)
        )
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))

        tabBar.updateTabs(channels: [channel], activeId: channel.channelId)

        let titles = tabBar.allSubviews(of: NSButton.self).map(\.title)
        XCTAssertTrue(titles.contains("ai-memory"))
        XCTAssertFalse(titles.contains { $0.contains("24m") || $0.contains("(") })
    }

    func testSidebarRunningTabShowsLabelWithoutTimerOrRunningText() {
        let channel = MockTimerChannel(
            label: "ai-memory",
            state: .active,
            activatedAt: Date().addingTimeInterval(-24 * 60)
        )
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        sidebar.updateTabs(channels: [channel], activeId: channel.channelId)

        let fieldValues = sidebar.allSubviews(of: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(fieldValues.contains("ai-memory"))
        XCTAssertFalse(fieldValues.contains { $0.contains("24m") || $0 == "running" })
    }
}

@MainActor
private final class MockTimerChannel: ChannelController {
    let channelId = UUID()
    let channelType: ChannelType = .shell
    let displayBaseLabel: String
    var displayLabel: String { displayBaseLabel }
    var hasUnread = false
    let state: ChannelState
    var persistentState: PersistentChannelState {
        PersistentChannelState.fromRuntimeState(state)
    }
    let contentView = NSView()
    var recoveryAction: ChannelRecoveryAction? = nil
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?
    let activatedAt: Date?

    init(label: String, state: ChannelState, activatedAt: Date?) {
        self.displayBaseLabel = label
        self.state = state
        self.activatedAt = activatedAt
    }

    func sendInput(_ text: String) {}
    func activate() {}
    func deactivate() {}
    func retry() {}
    func lastLines(_ count: Int) -> [String] { [] }
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
