import XCTest
@testable import Holoscape

/// Task 11 — Integration tests for `SkinEngine.startWatching` /
/// `stopWatching` + the `SkinEngineFileWatcherDelegate` fire path.
///
/// Scope is the engine's half of the hot-reload pipeline: the
/// FSEventStream watcher, the main-queue hop, and delegate delivery.
/// `MainWindowController`'s debounce is a separate concern tested
/// indirectly via the Mac-Mini dogfood pass.
///
/// Uses `HOLOSCAPE_CONFIG_DIR` to redirect the engine at a per-test
/// temp directory — real `~/.holoscape/skins/` is never touched.
@MainActor
final class HotReloadTests: XCTestCase {

    private var tempDir: URL!
    private var skinsDir: URL!
    private var skinDir: URL!
    private var originalEnv: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-hotreload-\(UUID().uuidString)")
        skinsDir = tempDir.appendingPathComponent("skins")
        skinDir = skinsDir.appendingPathComponent("TestSkin")
        try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        try writeSkinJson(windowColor: "#ff0000", to: skinDir)

        originalEnv = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"]
        setenv("HOLOSCAPE_CONFIG_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        if let original = originalEnv {
            setenv("HOLOSCAPE_CONFIG_DIR", original, 1)
        } else {
            unsetenv("HOLOSCAPE_CONFIG_DIR")
        }
        try super.tearDownWithError()
    }

    // MARK: - Happy path: a write fires the delegate

    func testFileWriteFiresDelegate() throws {
        let engine = SkinEngine()
        let spy = CountingSpy()
        engine.fileWatcherDelegate = spy

        let didFire = expectation(description: "delegate fires within 2s of a write")
        spy.onFire = { _ in didFire.fulfill() }

        engine.startWatching(skinName: "TestSkin")

        // FSEventStreamStart needs a beat to become ready after
        // SetDispatchQueue + Start. Wait synchronously, then do the
        // triggering write with `try` so a filesystem failure fails
        // the test loudly rather than being swallowed into a vacuous
        // "no fire" outcome.
        let ready = expectation(description: "stream start settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ready.fulfill() }
        wait(for: [ready], timeout: 1.0)

        try writeSkinJson(windowColor: "#00ff00")
        wait(for: [didFire], timeout: 3.0)

        XCTAssertGreaterThan(spy.fireCount, 0,
                             "at least one fire expected after a real file write")
        engine.stopWatching()
    }

    // MARK: - stopWatching silences subsequent writes

    func testStopWatchingSilencesFires() throws {
        let engine = SkinEngine()
        let spy = CountingSpy()
        engine.fileWatcherDelegate = spy

        engine.startWatching(skinName: "TestSkin")
        engine.stopWatching()

        // Write AFTER stopWatching — delegate must not fire. `try`
        // (not `try?`) so a silent write failure can't vacuously
        // satisfy the no-fire assertion.
        try writeSkinJson(windowColor: "#0000ff")

        let noFire = expectation(description: "no fire within 1s window")
        noFire.isInverted = true
        spy.onFire = { _ in noFire.fulfill() }
        wait(for: [noFire], timeout: 1.0)

        XCTAssertEqual(spy.fireCount, 0,
                       "delegate must not fire after stopWatching")
    }

    // MARK: - Switching skins re-points the watcher

    func testStartWatchingReplacesPreviousStream() throws {
        // Create a SECOND skin. Watching it should ignore writes to
        // the first one — the watcher is scoped to the active skin's
        // directory, not the whole skins root.
        let otherSkin = skinsDir.appendingPathComponent("OtherSkin")
        try FileManager.default.createDirectory(at: otherSkin, withIntermediateDirectories: true)
        try Data(#"{"name":"OtherSkin"}"#.utf8)
            .write(to: otherSkin.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let spy = CountingSpy()
        engine.fileWatcherDelegate = spy

        engine.startWatching(skinName: "TestSkin")
        engine.startWatching(skinName: "OtherSkin")  // replaces

        // Let the stream swap settle. FSEvents delivers buffered events
        // asynchronously; without this wait, a residual event from the
        // TestSkin stream can leak through during the switch window and
        // fire the delegate with the now-current directory (OtherSkin).
        // That's a transient fire, not a persistent breach of the
        // scoped-watcher contract; waiting past the FSEvents latency
        // (0.05s) + a main-queue hop puts us firmly past it.
        let settleExpectation = expectation(description: "stream swap settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            settleExpectation.fulfill()
        }
        wait(for: [settleExpectation], timeout: 1.0)
        // Reset spy AFTER the settle window so any transitional fire
        // is counted out — we care about steady-state isolation.
        spy.fireCount = 0

        // Write to the ORIGINAL (now un-watched) skin.
        try writeSkinJson(windowColor: "#aaaaaa")

        let noFire = expectation(description: "no fire from un-watched skin")
        noFire.isInverted = true
        spy.onFire = { _ in noFire.fulfill() }
        wait(for: [noFire], timeout: 1.0)

        XCTAssertEqual(spy.fireCount, 0,
                       "writes to a no-longer-watched skin must not fire")
        engine.stopWatching()
    }

    // MARK: - Default and missing-skin startWatching is a safe no-op

    func testStartWatchingDefaultIsNoOp() throws {
        let engine = SkinEngine()
        let spy = CountingSpy()
        engine.fileWatcherDelegate = spy

        engine.startWatching(skinName: "Default")

        // No stream was created; no fires are possible. `try` (not
        // `try?`) so a write failure fails the test rather than
        // silently passing the no-fire assertion.
        try writeSkinJson(windowColor: "#ff00ff")
        let noFire = expectation(description: "no fire for Default")
        noFire.isInverted = true
        spy.onFire = { _ in noFire.fulfill() }
        wait(for: [noFire], timeout: 0.5)
    }

    func testStartWatchingMissingSkinIsNoOp() throws {
        let engine = SkinEngine()
        let spy = CountingSpy()
        engine.fileWatcherDelegate = spy

        // Skin with no directory on disk. Engine should log and skip,
        // not crash. A subsequent write to a completely unrelated path
        // (our tempDir root) must not fire the delegate.
        engine.startWatching(skinName: "NonExistent")

        try Data("unrelated".utf8).write(to: tempDir.appendingPathComponent("sibling.txt"))
        let noFire = expectation(description: "no fire for missing skin")
        noFire.isInverted = true
        spy.onFire = { _ in noFire.fulfill() }
        wait(for: [noFire], timeout: 0.5)
    }

    // MARK: - Helpers

    /// nonisolated so `setUpWithError` (non-actor-isolated) can call it.
    /// Takes `skinDir` as a parameter — can't read the MainActor-isolated
    /// instance property from a nonisolated method.
    nonisolated private func writeSkinJson(windowColor: String, to skinDir: URL) throws {
        let json = """
        {
          "version": "2.0",
          "name": "TestSkin",
          "surfaces": {
            "window.background": { "fill": { "kind": "color", "value": "\(windowColor)" } }
          }
        }
        """
        try Data(json.utf8).write(to: skinDir.appendingPathComponent("skin.json"))
    }

    /// @MainActor overload for tests that already have the isolated
    /// `skinDir` property on hand.
    private func writeSkinJson(windowColor: String) throws {
        try writeSkinJson(windowColor: windowColor, to: skinDir)
    }
}

/// Minimal delegate that counts calls and forwards to a test-supplied
/// closure. Not thread-safe; acceptable here because the engine hops
/// to main before firing us.
@MainActor
private final class CountingSpy: SkinEngineFileWatcherDelegate {
    var fireCount: Int = 0
    var onFire: ((URL) -> Void)?

    func skinEngineDidDetectChange(in directory: URL) {
        fireCount += 1
        onFire?(directory)
    }
}
