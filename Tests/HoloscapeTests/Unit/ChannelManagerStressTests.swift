import XCTest
@testable import Holoscape

@MainActor
final class ChannelManagerStressTests: XCTestCase {

    // MARK: - Create/Close Symmetry

    func testCreateAndCloseNetZero() {
        let counts = [1, 2, 5, 10, 20]
        for n in counts {
            let manager = ChannelManager(configService: ConfigService())
            var ids: [UUID] = []
            for _ in 0..<n {
                let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
                    MockChannelController(id: id)
                }
                ids.append(ch.channelId)
            }
            XCTAssertEqual(manager.count, n)

            for id in ids {
                manager.closeChannel(id: id)
            }
            XCTAssertEqual(manager.count, 0, "After closing all \(n) channels, count should be 0")
        }
    }

    func testCloseInReverseOrder() {
        let manager = ChannelManager(configService: ConfigService())
        var ids: [UUID] = []
        for _ in 0..<5 {
            let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
                MockChannelController(id: id)
            }
            ids.append(ch.channelId)
        }

        for id in ids.reversed() {
            manager.closeChannel(id: id)
        }
        XCTAssertEqual(manager.count, 0)
    }

    func testCloseInArbitraryOrder() {
        let manager = ChannelManager(configService: ConfigService())
        var ids: [UUID] = []
        for _ in 0..<5 {
            let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
                MockChannelController(id: id)
            }
            ids.append(ch.channelId)
        }

        let closeOrder = [2, 0, 4, 1, 3]
        for i in closeOrder {
            manager.closeChannel(id: ids[i])
        }
        XCTAssertEqual(manager.count, 0)
    }

    // MARK: - Ordering Invariants

    func testMoveToFrontPreservesAllChannels() {
        let manager = ChannelManager(configService: ConfigService())
        var ids: [UUID] = []
        for _ in 0..<5 {
            let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
                MockChannelController(id: id)
            }
            ids.append(ch.channelId)
        }

        for id in ids {
            manager.moveUnreadToFront(id: id)
            let allIds = manager.allChannels().map { $0.channelId }
            XCTAssertEqual(Set(allIds), Set(ids), "Moving to front should not lose or duplicate channels")
            XCTAssertEqual(allIds.count, ids.count)
        }
    }

    func testRepeatedMoveToFrontIsIdempotent() {
        let manager = ChannelManager(configService: ConfigService())
        var ids: [UUID] = []
        for _ in 0..<3 {
            let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
                MockChannelController(id: id)
            }
            ids.append(ch.channelId)
        }

        // Move same channel to front multiple times
        manager.moveUnreadToFront(id: ids[2])
        let afterFirst = manager.allChannels().map { $0.channelId }
        manager.moveUnreadToFront(id: ids[2])
        let afterSecond = manager.allChannels().map { $0.channelId }

        XCTAssertEqual(afterFirst, afterSecond, "Moving same channel to front twice should be idempotent")
    }

    // MARK: - Mixed Channel Types

    func testMixedChannelTypesCoexist() {
        let manager = ChannelManager(configService: ConfigService())
        let types: [(ChannelType, String)] = [
            (.shell, "Shell"),
            (.agentDirect, "Agent"),
            (.agentAPI, "Agent"),
            (.groupChat, "Chat"),
            (.shell, "Shell"),
        ]

        for (type, role) in types {
            _ = manager.createChannel(type: type, role: role, workingDirectory: nil) { id, t, _, _, _ in
                MockChannelController(id: id, type: t, label: role)
            }
        }

        XCTAssertEqual(manager.count, 5)
        let all = manager.allChannels()
        XCTAssertEqual(all[0].channelType, .shell)
        XCTAssertEqual(all[1].channelType, .agentDirect)
        XCTAssertEqual(all[2].channelType, .agentAPI)
        XCTAssertEqual(all[3].channelType, .groupChat)
        XCTAssertEqual(all[4].channelType, .shell)
    }

    // MARK: - Double Close Safety

    func testDoubleCloseIsNoOp() {
        let manager = ChannelManager(configService: ConfigService())
        let ch = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
            MockChannelController(id: id)
        }
        let id = ch.channelId

        manager.closeChannel(id: id)
        XCTAssertEqual(manager.count, 0)

        // Second close should not crash or corrupt state
        manager.closeChannel(id: id)
        XCTAssertEqual(manager.count, 0)
    }

    // MARK: - Interleaved Create and Close

    func testInterleavedCreateAndClose() {
        let manager = ChannelManager(configService: ConfigService())

        let ch1 = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
            MockChannelController(id: id)
        }
        let ch2 = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
            MockChannelController(id: id)
        }
        XCTAssertEqual(manager.count, 2)

        manager.closeChannel(id: ch1.channelId)
        XCTAssertEqual(manager.count, 1)

        let ch3 = manager.createChannel(type: .shell, role: "Shell", workingDirectory: nil) { id, _, _, _, _ in
            MockChannelController(id: id)
        }
        XCTAssertEqual(manager.count, 2)

        // Remaining channels should be ch2 and ch3
        let all = manager.allChannels()
        XCTAssertEqual(all[0].channelId, ch2.channelId)
        XCTAssertEqual(all[1].channelId, ch3.channelId)
    }
}
