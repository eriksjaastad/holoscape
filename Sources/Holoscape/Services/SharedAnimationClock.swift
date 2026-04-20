import Foundation
import QuartzCore
import os.signpost

/// Phase-clock shared by every `AnimatedLayerRenderer` attached to a
/// `ChromeHostView`. A single `DispatchSourceTimer` drives every
/// subscribed renderer so layers remain in phase (Req 11.2) and the
/// animated-chrome per-frame budget is measured from one place
/// (Req 11.3, `os_signpost` category `"chrome.animation.tick"`).
///
/// MVP uses a dispatch-source timer at ~60 Hz; the design names
/// `CADisplayLink` but getting one requires either an NSView anchor
/// or platform API hops that are heavier than the 8 ms-per-frame
/// budget requires at MVP scale. Upgrading to `CADisplayLink` or
/// `CVDisplayLink` is a follow-up once PR #19's debug-overlay
/// signpost traces prove the tick cadence matters.
///
/// Subscribers are held weakly — a renderer going out of scope (skin
/// unload, density-mode teardown) drops off the subscriber list on
/// next tick without the caller having to `unsubscribe` first.
@MainActor
final class SharedAnimationClock {

    // MARK: - Types

    /// Weak box so subscriber list doesn't retain renderers. Nil
    /// entries get swept on `prune()`.
    private struct WeakRenderer {
        weak var renderer: AnimatedLayerRenderer?
    }

    // MARK: - State

    private var subscribers: [WeakRenderer] = []
    private var tickTimer: DispatchSourceTimer?
    private var isRunning = false
    private var isPaused = false
    private let signpostLog = OSLog(
        subsystem: "com.holoscape.chrome",
        category: "chrome.animation.tick"
    )
    private let fps: Double

    init(fps: Double = 60) {
        self.fps = fps
    }

    // MARK: - Phase

    /// Phase seconds — monotonic, matches `CACurrentMediaTime()` so
    /// it advances at wall-clock rate regardless of system clock
    /// changes (Req 9.5 shader `time` uniform feeds from this).
    var phaseSeconds: Double { CACurrentMediaTime() }

    // MARK: - Subscription

    func subscribe(_ renderer: AnimatedLayerRenderer) {
        // Defensive: don't double-add. Equality via ObjectIdentifier
        // avoids hashability requirements on the protocol.
        if subscribers.contains(where: { $0.renderer === renderer }) {
            return
        }
        subscribers.append(WeakRenderer(renderer: renderer))
    }

    func unsubscribe(_ renderer: AnimatedLayerRenderer) {
        subscribers.removeAll { $0.renderer === renderer || $0.renderer == nil }
    }

    // MARK: - Lifecycle

    /// Start delivering ticks. No-op when already running. `pause()`
    /// + `resume()` are the runtime on/off switches; `start()`/`stop()`
    /// govern the underlying timer's existence.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / fps))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.resume()
        tickTimer = timer
    }

    func stop() {
        tickTimer?.cancel()
        tickTimer = nil
        isRunning = false
        isPaused = false
    }

    /// Freeze tick delivery without tearing down subscribers.
    /// Reduce Motion (Req 15.3) + density `.minimal` (Req 15.5)
    /// both land here — the timer still fires, but `tick()`
    /// short-circuits so renderers hold their current frame.
    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    // MARK: - Tick

    /// Forward a tick to every live subscriber. Dead entries (weak
    /// references to deallocated renderers) get pruned here so the
    /// subscriber list doesn't grow unbounded.
    func tick() {
        guard !isPaused else { return }
        let phase = phaseSeconds
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "tick", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "tick", signpostID: signpostID) }

        // Collect live renderers first so pruning doesn't race with
        // forwarding (subscribers array mutates during iteration if
        // an uninstall fires inside tick, which can happen when a
        // renderer self-removes mid-frame).
        let live = subscribers.compactMap { $0.renderer }
        for renderer in live {
            renderer.tick(phaseSeconds: phase)
        }

        // Sweep dead entries.
        prune()
    }

    private func prune() {
        subscribers.removeAll { $0.renderer == nil }
    }

    // MARK: - Test hooks

    #if DEBUG
    /// Test access to the live subscriber count (after pruning).
    /// Internal because unit tests live inside `@testable import
    /// Holoscape`; not exposed as public API.
    var _testLiveSubscriberCount: Int {
        subscribers.lazy.compactMap { $0.renderer }.count
    }

    var _testIsRunning: Bool { isRunning }
    var _testIsPaused: Bool { isPaused }

    /// Drive a single tick manually (test-only — bypasses the
    /// timer so tests don't wait on wall-clock).
    func _testTick() {
        tick()
    }
    #endif
}
