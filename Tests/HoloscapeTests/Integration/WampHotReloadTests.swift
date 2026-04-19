import XCTest
import ZIPFoundation
@testable import Holoscape

/// Amplify Task 21.1 — hot reload path through `.wamp` bundles.
///
/// The directory-layout hot-reload pipeline (`HotReloadTests`) already
/// pins the FSEventStream → delegate round-trip with a real file
/// write. This file pins the *additional* Amplify invariant: when
/// `startWatching` is called with a skin name that resolves to a
/// `.wamp` bundle, the engine installs its FSEventStream against the
/// bundle FILE (not a directory) — the `activeBundleFileURL` branch
/// of `SkinEngine.startWatching`. That's the new code path Amplify
/// added; its directory-layout sibling is covered elsewhere.
///
/// Scope is deliberately narrow: "can the engine install a watcher on
/// a `.wamp`, and does `stopWatching` release it." The end-to-end
/// "edit the .wamp → chrome reloads" walk-through is a Mac-Mini
/// dogfood step on the chrome-skinning parent spec (Task 16), not a
/// headless unit test — full FSEvents round-trips on file paths
/// interact badly with accumulated test-suite state and introduce
/// flakes that tell us nothing about the engine's correctness.
///
/// Uses `HOLOSCAPE_CONFIG_DIR` to redirect the engine at a per-test
/// temp directory so the real `~/.holoscape/skins/` is never touched.
@MainActor
final class WampHotReloadTests: XCTestCase {

    private var tempDir: URL!
    private var skinsDir: URL!
    private var bundleURL: URL!
    private var originalEnv: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-wamp-hotreload-\(UUID().uuidString)")
        skinsDir = tempDir.appendingPathComponent("skins")
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)

        bundleURL = skinsDir.appendingPathComponent("TestWamp.wamp")
        try writeBundle(windowColor: "#ff0000", to: bundleURL)

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

    // MARK: - `.wamp` branch of startWatching creates a watcher

    /// Calling `startWatching` on a skin that resolves to a `.wamp`
    /// must install an FSEventStream. `_currentStreamIsNil` exposes
    /// only a boolean — enough to assert "watcher installed" without
    /// widening the engine's public API.
    func testStartWatchingOnWampSkinInstallsWatcher() {
        let engine = SkinEngine()
        XCTAssertTrue(engine._currentStreamIsNil,
                      "Precondition: fresh engine has no watcher installed")

        engine.startWatching(skinName: "TestWamp")

        XCTAssertFalse(engine._currentStreamIsNil,
                       "startWatching on a .wamp-backed skin must install a watcher against the bundle file")
        engine.stopWatching()
    }

    // MARK: - stopWatching releases the watcher

    func testStopWatchingReleasesWampWatcher() {
        let engine = SkinEngine()
        engine.startWatching(skinName: "TestWamp")
        XCTAssertFalse(engine._currentStreamIsNil,
                       "Precondition: watcher must be installed before we can test release")

        engine.stopWatching()
        XCTAssertTrue(engine._currentStreamIsNil,
                      "stopWatching must release the FSEventStream and clear currentStream")
    }

    // MARK: - Missing `.wamp` produces a safe no-op

    /// Graceful degradation: if the named `.wamp` skin doesn't exist,
    /// `startWatching` must log and short-circuit rather than crash
    /// or install a watcher against a missing path. Same rule the
    /// directory path pins in `HotReloadTests.testStartWatchingMissingSkinIsNoOp`.
    func testStartWatchingOnMissingWampIsNoOp() throws {
        // Remove the fixture bundle to simulate an unresolvable name.
        try FileManager.default.removeItem(at: bundleURL)

        let engine = SkinEngine()
        engine.startWatching(skinName: "TestWamp")

        XCTAssertTrue(engine._currentStreamIsNil,
                      "startWatching on a missing .wamp must not install a watcher")
    }

    // MARK: - Helpers

    nonisolated private func writeBundle(windowColor: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        let manifest = """
        {
          "version": "3.0",
          "name": "TestWamp",
          "surfaces": {
            "window.background": { "fill": { "kind": "color", "value": "\(windowColor)" } }
          }
        }
        """
        let data = Data(manifest.utf8)
        try archive.addEntry(
            with: "skin.json",
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }
}
