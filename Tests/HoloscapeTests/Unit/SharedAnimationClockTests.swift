import XCTest
import QuartzCore
@testable import Holoscape

/// Chrome v4 Task 19.1 — SharedAnimationClock invariants.
///
/// Pins:
/// - Subscribers held weakly; dropped-ref renderers get pruned.
/// - start/stop/pause/resume state transitions.
/// - tick forwards phaseSeconds to every live subscriber.
/// - subscribe/unsubscribe idempotent.
@MainActor
final class SharedAnimationClockTests: XCTestCase {

    // MARK: - Test renderer

    private final class SpyRenderer: AnimatedLayerRenderer {
        let id: String
        let z: Int = 1
        let layer: CALayer = CALayer()
        var ticks: [Double] = []
        var pauseCallCount = 0
        var resumeCallCount = 0

        init(id: String) { self.id = id }

        func install(in parent: CALayer) {}
        func updateParams(_ params: ChromeAnimationLayer.Params) {}
        func tick(phaseSeconds: Double) { ticks.append(phaseSeconds) }
        func pause() { pauseCallCount += 1 }
        func resume() { resumeCallCount += 1 }
        func uninstall() {}
    }

    // MARK: - Subscribe / unsubscribe

    func testSubscribeAddsOne() {
        let clock = SharedAnimationClock()
        let r = SpyRenderer(id: "a")
        clock.subscribe(r)
        XCTAssertEqual(clock._testLiveSubscriberCount, 1)
    }

    func testSubscribeTwiceKeepsOne() {
        let clock = SharedAnimationClock()
        let r = SpyRenderer(id: "a")
        clock.subscribe(r)
        clock.subscribe(r)
        XCTAssertEqual(clock._testLiveSubscriberCount, 1,
            "Double-subscribe must not duplicate the entry")
    }

    func testUnsubscribeRemoves() {
        let clock = SharedAnimationClock()
        let r = SpyRenderer(id: "a")
        clock.subscribe(r)
        clock.unsubscribe(r)
        XCTAssertEqual(clock._testLiveSubscriberCount, 0)
    }

    func testWeakRefPrunesDeallocatedRenderer() {
        let clock = SharedAnimationClock()
        do {
            let r = SpyRenderer(id: "ephemeral")
            clock.subscribe(r)
            XCTAssertEqual(clock._testLiveSubscriberCount, 1)
        }
        // r is out of scope now. A tick prunes the dead entry.
        clock._testTick()
        XCTAssertEqual(clock._testLiveSubscriberCount, 0,
            "Tick must prune subscribers that were deallocated")
    }

    // MARK: - Lifecycle

    func testStartSetsRunning() {
        let clock = SharedAnimationClock()
        XCTAssertFalse(clock._testIsRunning)
        clock.start()
        XCTAssertTrue(clock._testIsRunning)
        clock.stop()
        XCTAssertFalse(clock._testIsRunning)
    }

    func testStartTwiceIsIdempotent() {
        let clock = SharedAnimationClock()
        clock.start()
        clock.start()  // Should not crash / double-timer.
        XCTAssertTrue(clock._testIsRunning)
        clock.stop()
    }

    func testPauseBlocksTickDelivery() {
        let clock = SharedAnimationClock()
        let r = SpyRenderer(id: "a")
        clock.subscribe(r)

        clock._testTick()
        XCTAssertEqual(r.ticks.count, 1, "Pre-pause tick must fire")

        clock.pause()
        clock._testTick()
        XCTAssertEqual(r.ticks.count, 1, "Paused tick must not forward to subscribers")

        clock.resume()
        clock._testTick()
        XCTAssertEqual(r.ticks.count, 2, "Resumed tick must forward again")
    }

    // MARK: - Tick

    func testTickForwardsPhaseSecondsToEverySubscriber() {
        let clock = SharedAnimationClock()
        let r1 = SpyRenderer(id: "one")
        let r2 = SpyRenderer(id: "two")
        clock.subscribe(r1)
        clock.subscribe(r2)

        clock._testTick()
        clock._testTick()

        XCTAssertEqual(r1.ticks.count, 2)
        XCTAssertEqual(r2.ticks.count, 2)
        // Ticks should be monotonic (CACurrentMediaTime-driven).
        XCTAssertLessThanOrEqual(r1.ticks[0], r1.ticks[1])
        XCTAssertLessThanOrEqual(r2.ticks[0], r2.ticks[1])
    }

    // MARK: - Phase seconds

    func testPhaseSecondsIsCACurrentMediaTime() {
        let clock = SharedAnimationClock()
        let before = CACurrentMediaTime()
        let phase = clock.phaseSeconds
        let after = CACurrentMediaTime()
        XCTAssertGreaterThanOrEqual(phase, before)
        XCTAssertLessThanOrEqual(phase, after)
    }
}
