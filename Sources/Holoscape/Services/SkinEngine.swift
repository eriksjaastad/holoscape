import Foundation
import AppKit
import CoreText
import CoreServices

/// Result of registering a skin's fonts.
///
/// `fonts` maps PostScript names to the decoded `CGFont` instances so
/// callers can resolve a `font.family` reference without re-parsing the
/// file. `registeredURLs` is the list callers must pass back to
/// `unregisterFonts(urls:)` on skin unload — pairing the register/
/// unregister calls keeps process-scope font registration symmetric
/// (Requirement 8.3).
struct SkinFontBundle {
    var fonts: [String: CGFont]
    var registeredURLs: [URL]
}

/// Errors raised while loading or validating a skin's asset references.
enum SkinAssetError: Error, Equatable {
    /// Asset path violated the sandbox rules — contained `..`, an
    /// absolute path, an HTTP(S) URL, a `file://` URL, or resolved via
    /// a symlink to somewhere outside the skin directory. The `path`
    /// field is the offending manifest value.
    case invalidPath(String)
}

/// Callback channel for `SkinEngine.startWatching(skinName:)`.
///
/// The engine posts `skinEngineDidDetectChange(in:)` on the main thread
/// whenever FSEventStream reports any change inside the actively-watched
/// skin's directory. `MainWindowController` conforms and debounces the
/// hits before re-running `reloadSkin(named:)` — a single delegate call
/// means a single test surface and avoids the "global notification →
/// 5 chrome views each repaint twice" problem (Task 11.3 no-double-paint
/// rule established in PR #106).
@MainActor
protocol SkinEngineFileWatcherDelegate: AnyObject {
    /// The watched skin directory fired one or more filesystem events.
    /// Called on the main thread. The `directory` is the skin root —
    /// the delegate can read `directory.lastPathComponent` to recover
    /// the skin name. Fires after the FSEvents → main-queue hop but
    /// BEFORE any debounce; the delegate is expected to debounce.
    func skinEngineDidDetectChange(in directory: URL)
}

/// Errors raised by `SkinEngine.loadComposite(named:)`.
enum SkinLoadError: Error, Equatable {
    /// No folder at `~/.holoscape/skins/<name>/` or its `skin.json` is
    /// missing / unreadable.
    case notFound(String)
    /// `skin.json` parsed or asset load failed. Carries a short reason
    /// for logging; callers keep their previous `SkinContext` on this.
    case parseFailure(String)
}

/// Everything `MainWindowController` needs to apply a skin in one atomic unit.
///
/// Returned by `SkinEngine.loadComposite(named:)`. Three consumers funnel
/// through this: the Appearance-Settings picker, the launch-time persistence
/// load, and Task 11's hot-reload path. Keeps those three code paths from
/// drifting.
///
/// `surfaces` is nil for "Default" — callers pass it straight to
/// `MainWindowController.applySkin(_:)` which interprets nil as
/// "restore built-in defaults."
struct LoadedSkin {
    /// The skin folder name (or `"Default"`).
    let name: String
    /// Converted per-surface appearance map, ready for `applySkin(_:)`.
    /// Nil for `.defaults`.
    let surfaces: [SurfaceKey: SkinContext.ResolvedSurface]?
    /// Registered fonts. Empty bundle for `.defaults`. Callers must pass
    /// the PREVIOUS bundle to `unregisterFonts(_:)` before storing this
    /// one, so process-scope registrations stay symmetric (Property 9).
    let fonts: SkinFontBundle
    /// Decoded images keyed by their manifest path. Empty for `.defaults`.
    let images: [String: NSImage]
    /// Absolute URL of the skin's directory. Nil for `.defaults`. Used
    /// by Task 11 to scope its FSEventStream watcher.
    let skinDir: URL?
    /// Amplify Task 5.2 — validated window shape when the manifest
    /// declares `windowShape` AND the `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS`
    /// env flag is on AND validation passes. Nil in every other case
    /// (flag off, no `windowShape` field, or validation rejected the
    /// descriptor). `MainWindowController.applySkin` reads this to
    /// decide whether to reconstruct the window.
    let windowShape: ResolvedWindowShape?
    /// Set when a non-nil `windowShape` field in the manifest failed
    /// validation. Chrome-layer banners (Requirement 13.2) read this
    /// to surface a user-visible warning without digging through logs.
    /// Nil when validation succeeded or no shape was declared.
    let validationBannerReason: String?
    /// Amplify Task 9.3 — validated drag regions from the manifest.
    /// Empty when the manifest declares none. Each region's polygons
    /// have been pruned to `≥ 3 vertices` per Req 13.5; a descriptor
    /// whose polygons all fail validation is dropped silently.
    let dragRegions: [ResolvedDragRegion]

    /// Chrome v4 — the raw `ChromeDescriptor` from the manifest.
    /// `nil` for v1/v2/v3 skins (Req 16.1 backward-compat invariant).
    /// `MainWindowController.applyChromeSkin` (PR #5) keys the
    /// Chrome_Mode_Branch off this being non-nil.
    let chrome: ChromeDescriptor?

    /// Chrome v4 — the Base_Layer image. Non-nil when `chrome != nil`
    /// (either decoded from `chrome.image` for baked mode or composed
    /// by `ChromeBakePipeline` for composed mode). The sha under
    /// which this image is cached is `chromeSHA`.
    let baseImage: CGImage?

    /// SHA-256 key for the cached baked image at
    /// `~/Library/Caches/holoscape-skins/<sha>.png`. Non-nil iff
    /// `baseImage != nil`. Used for LRU purge (PR #4) and for hot
    /// reload diff (PR #18 — unchanged SHA means no re-bake needed).
    let chromeSHA: String?

    /// Sentinel returned when the requested skin is `"Default"` — lets
    /// callers treat Default as "no skin loaded" without a special case.
    ///
    /// `@MainActor` because `LoadedSkin` holds `NSImage` (non-Sendable);
    /// the sentinel is only read from main-thread code paths (picker,
    /// MainWindowController), so main-actor isolation is correct.
    @MainActor
    static let defaults = LoadedSkin(
        name: "Default",
        surfaces: nil,
        fonts: SkinFontBundle(fonts: [:], registeredURLs: []),
        images: [:],
        skinDir: nil,
        windowShape: nil,
        validationBannerReason: nil,
        dragRegions: [],
        chrome: nil,
        baseImage: nil,
        chromeSHA: nil
    )
}

@MainActor
class SkinEngine {
    /// Absolute path to the skins root — `~/.holoscape/skins/` or the
    /// test-override directory from `HOLOSCAPE_CONFIG_DIR`. Exposed so
    /// Task 11's FSEventStream watcher reads from the same location the
    /// loader does.
    let skinsDirectory: URL

    /// Density gate. When `isSkinActive()` returns false (Off mode), `apply`
    /// returns its input unchanged so chrome views render the pre-skinning
    /// hardcoded defaults — enforcing the zero-overhead-idle-chrome guarantee
    /// (Property 7, Requirement 15.1). When nil, skin application proceeds
    /// normally (pre-DensityModeManager default).
    weak var densityModeManager: DensityModeManager?

    /// Receiver of FSEventStream fires. `MainWindowController` conforms;
    /// it debounces the events and calls `reloadSkin(named:)` on the
    /// trailing edge. Weak because the delegate outlives the engine via
    /// the app's object graph.
    weak var fileWatcherDelegate: SkinEngineFileWatcherDelegate?

    // MARK: - File-watcher state (Task 11)
    //
    // Only one skin is watched at a time (the currently-loaded one). The
    // picker flips skins by calling stopWatching() + startWatching(newName).
    // Watching the full skins root would wake the debouncer on every save
    // to every sibling skin — no user benefit.

    /// `nonisolated(unsafe)` because deinit on a `@MainActor` class is
    /// nonisolated in Swift 6. FSEventStream* C APIs are thread-safe, so
    /// the teardown in deinit is safe even though the compiler can't
    /// verify the OpaquePointer is Sendable. Reads/writes in normal
    /// paths (`startWatching`, `stopWatching`, `fileWatcherDidFireSomeEvents`)
    /// all happen on the main actor. Matches the project convention for
    /// this shape (cf. `MainWindowController.elapsedTimeTimer`).
    nonisolated(unsafe) private var currentStream: FSEventStreamRef?
    private var currentWatchedDir: URL?

    /// Test-only view of the watcher slot. `currentStream` is private
    /// (and `FSEventStreamRef` is an opaque pointer that doesn't round-
    /// trip cleanly through Swift's extension-access rules), so this
    /// narrow boolean accessor exists so `ZeroOverheadPropertyTests` can
    /// assert "construction opens no stream" without widening the real
    /// API.
    internal var _currentStreamIsNil: Bool { currentStream == nil }

    /// Dedicated serial queue FSEvents posts its callbacks on. Separate
    /// from main so the callback doesn't contend with UI work; the
    /// callback immediately hops back to main before touching any engine
    /// state.
    private let watcherQueue = DispatchQueue(label: "holoscape.skin.watcher")

    /// Loader for `.wamp` ZIP bundles (Amplify Task 3). Unzips to a
    /// hash-keyed subdirectory under `cacheRoot` and returns the
    /// directory URL, which downstream loaders (`loadImages`,
    /// `loadNinepatchSidecar`, `registerFonts`) consume identically
    /// to a directory-layout skin.
    let wampLoader: WampBundleLoader

    /// Chrome v4 load-time baker (Task 7.2). Fires only when a
    /// manifest declares `chrome != nil`; produces the Base_Layer
    /// CGImage from either a pre-rendered PNG (baked mode) or a
    /// composed-from-v3-surfaces render (composed mode). Cache lives
    /// at `~/Library/Caches/holoscape-skins/<sha>.png`.
    let bakePipeline: ChromeBakePipeline

    init() {
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            self.skinsDirectory = URL(fileURLWithPath: override).appendingPathComponent("skins")
        } else {
            self.skinsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".holoscape/skins")
        }

        // `.wamp` cache lives under
        // `~/Library/Caches/<bundleID>/Holoscape/Skins/`. Respects
        // HOLOSCAPE_CONFIG_DIR so tests stage a disposable cache under
        // their temp config dir and don't pollute the real user cache.
        let cacheRoot: URL
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            cacheRoot = URL(fileURLWithPath: override)
                .appendingPathComponent("caches/Skins")
        } else {
            cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Holoscape/Skins")
        }
        self.wampLoader = WampBundleLoader(cacheRoot: cacheRoot)
        self.bakePipeline = ChromeBakePipeline()

        // WampBundleLoader needs the sandbox helpers from `self`.
        // Assignment deferred until after `self` is fully initialized.
        self.wampLoader.sandbox = self

        // Startup LRU cleanup — evicts stale cache entries so first
        // launch after a while doesn't sit with a bloated cache. Best
        // effort; any failure is logged and swallowed.
        do {
            try self.wampLoader.purgeLRU(preserving: nil)
        } catch {
            NSLog("SkinEngine: LRU cache purge at init failed: \(error.localizedDescription)")
        }
    }

    /// List all available skin names. Always includes "Default" first,
    /// followed by BUNDLED reference skins (shipped inside the .app via
    /// `Bundle.module.resourceURL/Skins/`), followed by USER skins at
    /// `~/.holoscape/skins/`. Names are deduped: if a user installs a
    /// skin with the same folder name as a bundled one, the user's
    /// override wins — but the name appears only once in the picker.
    func availableSkins() -> [String] {
        var skins = ["Default"]
        var seen: Set<String> = []
        for name in bundledSkinNames() where seen.insert(name).inserted {
            skins.append(name)
        }
        for name in userSkinNames() where seen.insert(name).inserted {
            skins.append(name)
        }
        return skins
    }

    /// Enumerate skin names under the user's `~/.holoscape/skins/`
    /// (or the `HOLOSCAPE_CONFIG_DIR` test override). Both directory-
    /// layout and `.wamp` bundle skins are included; `.wamp` extensions
    /// are stripped for display.
    private func userSkinNames() -> [String] {
        enumerateSkinFolders(at: skinsDirectory) + enumerateWampBundles(at: skinsDirectory)
    }

    /// Enumerate skin names under the app bundle's `Resources/Skins/`.
    /// Empty in unit tests (no Bundle.main.resourceURL) or when no bundled
    /// skins are shipped. Both directory and `.wamp` forms are included.
    private func bundledSkinNames() -> [String] {
        guard let root = bundledSkinsDirectory() else { return [] }
        return enumerateSkinFolders(at: root) + enumerateWampBundles(at: root)
    }

    /// Absolute URL of the app bundle's bundled-skins directory, or nil
    /// when running in an environment without a resource bundle.
    ///
    /// Uses `Bundle.module` — SwiftPM's auto-generated accessor for the
    /// Holoscape target's resource bundle (`Holoscape_Holoscape.bundle`
    /// inside the .app). `Bundle.main.resourceURL` points one level up
    /// and doesn't include the nested `Skins/` tree.
    ///
    /// Respects the `HOLOSCAPE_BUNDLE_SKINS_DIR` env var for tests —
    /// lets integration tests stage a fake bundled-skins directory
    /// without having to mock the module bundle.
    private func bundledSkinsDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_BUNDLE_SKINS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.module.resourceURL?.appendingPathComponent("Skins")
    }

    /// Shared directory-walk: return sorted folder names under `root`
    /// that contain a `skin.json` file. Missing or unreadable `root` is
    /// not an error — callers treat it as "no skins in this location."
    private func enumerateSkinFolders(at root: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var names: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let skinJson = entry.appendingPathComponent("skin.json")
            if FileManager.default.fileExists(atPath: skinJson.path) {
                names.append(entry.lastPathComponent)
            }
        }
        return names
    }

    /// Amplify Task 3.6 — enumerate `.wamp` bundle skins under `root`,
    /// returning their display names (filename minus `.wamp` extension).
    /// Name collisions between `foo/` and `foo.wamp` in the same
    /// directory dedupe by base name; `availableSkins` then dedupes
    /// across user/bundle locations via its own `Set`.
    private func enumerateWampBundles(at root: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var names: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard entry.pathExtension.lowercased() == "wamp" else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            names.append(entry.deletingPathExtension().lastPathComponent)
        }
        return names
    }

    /// Resolve a skin name to its on-disk directory. User-installed skins
    /// at `~/.holoscape/skins/` take precedence over bundled skins of the
    /// same name — matches the "user override wins" rule in `availableSkins`.
    /// Returns nil for "Default" (no directory) and for unknown names.
    ///
    /// For `.wamp` bundles (Amplify Task 3.6) the path is:
    ///   1. Look for `<name>/` directory (v2 layout) — if present, win.
    ///   2. Look for `<name>.wamp` file — if present, unzip via
    ///      `wampLoader` and return the cache subdirectory URL.
    /// Checked in user-dir first, then bundle-dir. A bundle unzip
    /// failure returns nil (with a logged error) so an unreadable
    /// `.wamp` degrades to "skin not found" rather than crashing.
    private func resolveSkinDir(named name: String) -> URL? {
        guard name != "Default" else { return nil }

        // User directory: try dir-layout first, then `.wamp`.
        if let url = resolveSkinLocation(named: name, under: skinsDirectory) {
            return url
        }

        // Bundle directory: same order.
        if let bundleRoot = bundledSkinsDirectory(),
           let url = resolveSkinLocation(named: name, under: bundleRoot) {
            return url
        }

        return nil
    }

    /// Single-location resolver. Checked by `resolveSkinDir` once per
    /// location (user, bundle).
    private func resolveSkinLocation(named name: String, under root: URL) -> URL? {
        let dir = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("skin.json").path) {
            return dir
        }
        let wampURL = root.appendingPathComponent(name + ".wamp")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: wampURL.path, isDirectory: &isDir), !isDir.boolValue {
            do {
                return try wampLoader.unzipIfNeeded(bundleURL: wampURL)
            } catch {
                NSLog("SkinEngine: could not unzip '\(wampURL.lastPathComponent)': \(error)")
                return nil
            }
        }
        return nil
    }

    /// URL of the `.wamp` bundle backing `name`, or nil if `name`
    /// resolves to a directory-layout skin (or doesn't exist). Used by
    /// `startWatching` so the FSEventStream watches the bundle file
    /// rather than the unzipped cache subdirectory (the cache dir only
    /// changes when the bundle's hash changes).
    private func activeBundleFileURL(for name: String) -> URL? {
        guard name != "Default" else { return nil }
        // Same precedence as resolveSkinDir: user-dir wins over bundle,
        // and within each location dir-layout wins over `.wamp`.
        for root in [skinsDirectory, bundledSkinsDirectory()].compactMap({ $0 }) {
            let dir = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("skin.json").path) {
                return nil  // dir-layout wins — no bundle file backing it
            }
            let wampURL = root.appendingPathComponent(name + ".wamp")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: wampURL.path, isDirectory: &isDir), !isDir.boolValue {
                return wampURL
            }
        }
        return nil
    }

    /// Load a skin definition by name. Returns nil for "Default" or invalid
    /// skins. Resolves through `resolveSkinDir` so bundled skins load just
    /// as cleanly as user-installed ones; callers don't care which source.
    func loadSkin(named name: String) -> SkinDefinition? {
        guard let skinDir = resolveSkinDir(named: name) else { return nil }
        let skinJson = skinDir.appendingPathComponent("skin.json")
        guard let data = try? Data(contentsOf: skinJson) else {
            NSLog("SkinEngine: Could not read skin.json for '\(name)'")
            return nil
        }
        guard let skin = try? JSONDecoder().decode(SkinDefinition.self, from: data) else {
            NSLog("SkinEngine: Invalid skin.json for '\(name)'")
            return nil
        }
        return skin
    }

    /// Apply a skin's colors to an AppearanceConfig.
    ///
    /// When density mode is `.off`, returns the input unchanged — the skin
    /// engine is fully bypassed in that mode.
    ///
    /// TODO (Task 8.1): When image loading lands in SkinEngine, check
    /// `densityModeManager?.shouldRenderImages()` at the loadImages call
    /// site and substitute color fallbacks when false. That's the correct
    /// insertion point per the plan — retrofitting SkinContext (which is
    /// immutable post-construction) would be wrong.
    func apply(skin: SkinDefinition, to config: AppearanceConfig) -> AppearanceConfig {
        guard densityModeManager?.isSkinActive() ?? true else {
            return config
        }

        var result = config
        if let bg = skin.windowBackground {
            result.backgroundColor = bg
        }
        if let ansi = skin.ansiColors, ansi.count == 16 {
            let names = [
                "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                "brightBlack", "brightRed", "brightGreen", "brightYellow",
                "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
            ]
            var colors: [String: String] = result.ansiColors ?? [:]
            for (i, name) in names.enumerated() {
                colors[name] = ansi[i]
            }
            if let fg = skin.textForeground {
                colors["foreground"] = fg
            }
            result.ansiColors = colors
        }
        return result
    }

    // MARK: - Asset pipeline (Task 8.1, 8.3)

    /// String-level validation of an asset path declared in a manifest.
    /// Rejects, in order:
    ///   - absolute paths (leading `/`)
    ///   - URLs with `http://`, `https://`, or `file://` schemes
    ///   - `..` path-traversal segments (anywhere in the path)
    ///
    /// This is the first half of the sandbox gate. `loadImages` also
    /// runs `assertPathResolvesInside(_:root:)` to catch symlink
    /// targets that escape the skin directory.
    ///
    /// Call before any file-system access. Color and gradient fills
    /// never reach this — only image references hit the gate.
    func validateAssetPath(_ path: String) throws {
        if path.hasPrefix("/") {
            throw SkinAssetError.invalidPath(path)
        }
        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
            throw SkinAssetError.invalidPath(path)
        }
        // Component check catches both leading `../foo` and mid-path
        // `assets/../../etc/passwd` traversals. Single-dot (`.`) segments
        // are permitted — they're a no-op that collapse during path
        // resolution and don't escape the sandbox. Percent-encoded
        // traversal (`%2e%2e`) is not decoded here; it passes the string
        // gate but never resolves to a real file, so the decode step
        // silently skips it (no escape possible).
        for component in path.split(separator: "/") {
            if component == ".." {
                throw SkinAssetError.invalidPath(path)
            }
        }
    }

    /// Second-half sandbox gate: resolve any symlinks along the file's
    /// path and confirm the real location stays inside `root`. Defends
    /// against a skin package that passes string validation but smuggles
    /// in a symlink like `assets/bg.png -> ../../.ssh/id_rsa`.
    /// Internal (not private) so `WampBundleLoader` can reuse the exact
    /// same symlink-resolution rule. Amplify Task 3.3 specifies the
    /// `.wamp` sandbox reuses this helper rather than duplicating it.
    func assertPathResolvesInside(_ fileURL: URL, root: URL, originalPath: String) throws {
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedFile == resolvedRoot || resolvedFile.hasPrefix(boundary) else {
            throw SkinAssetError.invalidPath(originalPath)
        }
    }

    /// Walk every surface in the manifest (top-level fill plus every
    /// state-variant fill), extract `.image` paths, validate each, and
    /// load the PNG via `NSImage(contentsOfFile:)`. Returns a map keyed
    /// by the manifest's relative path so callers can round-trip from a
    /// descriptor back to the loaded image without re-resolving URLs.
    ///
    /// Files that parse-validate but fail to decode are logged and
    /// skipped so one bad asset doesn't wipe out the whole skin. A path
    /// that fails `validateAssetPath` is a hard error and propagates.
    func loadImages(from skinDir: URL, manifest: SkinDefinition) throws -> [String: NSImage] {
        guard let surfaces = manifest.surfaces else { return [:] }

        var paths: Set<String> = []
        for (_, surface) in surfaces {
            if let fill = surface.fill, case .image(let path, _, _) = fill {
                paths.insert(path)
            }
            if let states = surface.states {
                for state in states {
                    if let fill = state.fill, case .image(let path, _, _) = fill {
                        paths.insert(path)
                    }
                }
            }
        }

        var images: [String: NSImage] = [:]
        for path in paths {
            try validateAssetPath(path)
            let fileURL = skinDir.appendingPathComponent(path)
            try assertPathResolvesInside(fileURL, root: skinDir, originalPath: path)
            guard let image = NSImage(contentsOfFile: fileURL.path) else {
                // One bad asset must not sink the whole skin — log and
                // skip so siblings still render (Requirement 1.5 spirit).
                NSLog("SkinEngine: Could not decode image at '\(path)'")
                continue
            }
            images[path] = image
        }
        return images
    }

    /// Load the ninepatch sidecar for an image, if one exists.
    ///
    /// For an image at `assets/tab-bg.png` in a skin, the sidecar is
    /// expected at `assets/tab-bg.ninepatch.json` alongside it. Returns
    /// `nil` for the common case where no sidecar is present.
    ///
    /// Sidecars that parse but fail `NinepatchSidecar.isValid` (degenerate
    /// ranges, negative starts, wrong element count) are logged and
    /// dropped — the caller should fall back to `.stretch` tile mode,
    /// per Requirement 2.3's "zero-width bands are treated as invalid".
    func loadNinepatchSidecar(for imagePath: String, in skinDir: URL) throws -> NinepatchSidecar? {
        try validateAssetPath(imagePath)

        let imageURL = skinDir.appendingPathComponent(imagePath)
        // Strip the image extension (e.g. `.png`) and append `.ninepatch.json`
        // so `assets/tab-bg.png` → `assets/tab-bg.ninepatch.json`.
        let sidecarURL = imageURL
            .deletingPathExtension()
            .appendingPathExtension("ninepatch.json")

        // Build the sidecar's relative path so an escape error names the
        // actual offender (the sidecar file), not the image that implied it.
        let sidecarRelPath = (imagePath as NSString)
            .deletingPathExtension
            .appending(".ninepatch.json")

        try assertPathResolvesInside(sidecarURL, root: skinDir, originalPath: sidecarRelPath)

        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: sidecarURL) else {
            NSLog("SkinEngine: Could not read ninepatch sidecar at '\(sidecarURL.path)'")
            return nil
        }

        guard let sidecar = try? JSONDecoder().decode(NinepatchSidecar.self, from: data) else {
            NSLog("SkinEngine: Invalid ninepatch sidecar JSON at '\(sidecarURL.path)'")
            return nil
        }

        guard sidecar.isValid else {
            NSLog("SkinEngine: Ninepatch sidecar at '\(sidecarURL.path)' has invalid stretch ranges; falling back to stretch tile mode")
            return nil
        }

        return sidecar
    }

    // MARK: - Font registration (Task 8.4)

    /// Scan `assets/fonts/` under the skin directory for `.otf` / `.ttf`
    /// files, register each with Core Text at process scope, and return
    /// a bundle the caller can hand back on skin unload.
    ///
    /// A missing `assets/fonts/` directory is not an error — returns
    /// `.empty`. A file that fails to decode or register is logged and
    /// skipped so siblings still load (Requirement 8.4 fallback).
    ///
    /// Process scope (not persistent) is required by Requirement 8.2 —
    /// skin fonts must not leak into Font Book.
    func registerFonts(from skinDir: URL) -> SkinFontBundle {
        let fontsDir = skinDir.appendingPathComponent("assets/fonts")

        // Distinguish "directory doesn't exist" (fine) from "directory
        // exists but couldn't be read" (permission denied, I/O error —
        // worth logging so silent empty bundles don't mask a real bug).
        if !FileManager.default.fileExists(atPath: fontsDir.path) {
            return SkinFontBundle(fonts: [:], registeredURLs: [])
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: fontsDir,
                includingPropertiesForKeys: nil
            )
        } catch {
            NSLog("SkinEngine: Could not read fonts directory '\(fontsDir.path)': \(error.localizedDescription)")
            return SkinFontBundle(fonts: [:], registeredURLs: [])
        }

        var fonts: [String: CGFont] = [:]
        var registeredURLs: [URL] = []

        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "otf" || ext == "ttf" else { continue }

            var registerError: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registerError) else {
                let detail = registerError?.takeRetainedValue().localizedDescription ?? "unknown"
                NSLog("SkinEngine: Failed to register font '\(url.lastPathComponent)': \(detail)")
                continue
            }

            guard let dataProvider = CGDataProvider(url: url as CFURL),
                  let cgFont = CGFont(dataProvider) else {
                NSLog("SkinEngine: Registered font '\(url.lastPathComponent)' but could not decode CGFont; rolling back")
                var rollbackError: Unmanaged<CFError>?
                if !CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &rollbackError) {
                    // Registration succeeded but rollback failed — the font
                    // is now leaked into process scope. Log so the failure
                    // is visible rather than silently rotting.
                    let detail = rollbackError?.takeRetainedValue().localizedDescription ?? "unknown"
                    NSLog("SkinEngine: Rollback failed for '\(url.lastPathComponent)' — font leaked into process scope: \(detail)")
                }
                continue
            }

            let name = (cgFont.postScriptName as String?) ?? url.deletingPathExtension().lastPathComponent
            if fonts[name] != nil {
                // Two files decoded to the same PostScript name. Last wins
                // (simple, deterministic) but log so the map/URL-list size
                // mismatch is visible to anyone chasing a "registered but
                // can't look up" bug.
                NSLog("SkinEngine: Duplicate PostScript name '\(name)' in fonts directory; last file wins")
            }
            fonts[name] = cgFont
            registeredURLs.append(url)
        }

        return SkinFontBundle(fonts: fonts, registeredURLs: registeredURLs)
    }

    /// Deregister every URL in the bundle. Idempotent — calling twice
    /// on the same bundle logs the second failure and returns.
    func unregisterFonts(_ bundle: SkinFontBundle) {
        for url in bundle.registeredURLs {
            var error: Unmanaged<CFError>?
            if !CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error) {
                let detail = error?.takeRetainedValue().localizedDescription ?? "unknown"
                NSLog("SkinEngine: Failed to unregister font '\(url.lastPathComponent)': \(detail)")
            }
        }
    }

    // MARK: - File-system watcher (Task 11)

    /// Start watching `~/.holoscape/skins/<skinName>/` for any file change.
    /// On fire, hops back to the main thread and notifies
    /// `fileWatcherDelegate`. Replaces any previously-active stream —
    /// safe to call repeatedly; callers do `startWatching(skinName:)`
    /// on every skin switch without first calling `stopWatching()`.
    ///
    /// No-op for `"Default"` (no directory to watch) or when the
    /// skin directory doesn't exist yet. The latter matters for the
    /// launch path: if the persisted `skinName` points at a missing
    /// folder, we log and skip rather than fail.
    ///
    /// FSEvents coalescing latency is deliberately short (0.05s) so our
    /// 200ms debounce on the delegate side remains the authoritative
    /// window — FSEvents itself shouldn't be batching events across a
    /// wider interval than we plan for.
    func startWatching(skinName: String) {
        stopWatching()
        guard skinName != "Default" else { return }

        // Decide what path to pin the watcher to:
        // - `.wamp` bundle: watch the bundle FILE. FSEventStream accepts
        //   file paths and reports writes. When a designer saves over
        //   the `.wamp`, the hash changes, `unzipIfNeeded` re-extracts,
        //   and downstream code picks up the new context.
        // - directory-layout skin: watch the SKIN DIRECTORY (pre-Amplify
        //   behavior). Unchanged.
        let watchPath: URL
        let watchKind: String
        if let bundleURL = activeBundleFileURL(for: skinName) {
            watchPath = bundleURL
            watchKind = "bundle file"
        } else {
            let skinDir = skinsDirectory.appendingPathComponent(skinName)
            watchPath = skinDir
            watchKind = "directory"
        }
        guard FileManager.default.fileExists(atPath: watchPath.path) else {
            NSLog("SkinEngine: Cannot watch '\(skinName)' — \(watchKind) does not exist")
            return
        }

        // FSEventStreamContext carries `self` across the C boundary via
        // an opaque pointer. passUnretained is safe because the stream
        // lifetime is bounded by this instance: we invalidate it in
        // stopWatching() (called from deinit), so the callback can never
        // outlive `self`.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [watchPath.path] as CFArray

        let callback: FSEventStreamCallback = { (_, info, _, _, _, _) in
            // C-function-pointer callback: nonisolated, runs on
            // watcherQueue. Retrieve self and immediately hop to main
            // before touching any engine state. Number of events and
            // their specific paths are ignored — the debounce on the
            // delegate side coalesces all events into one reload pass.
            guard let info else { return }
            let engine = Unmanaged<SkinEngine>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                engine.fileWatcherDidFireSomeEvents()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            /* latency (FSEvents coalescing) */ 0.05,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            NSLog("SkinEngine: FSEventStreamCreate failed for '\(skinName)'")
            return
        }

        FSEventStreamSetDispatchQueue(stream, watcherQueue)
        FSEventStreamStart(stream)
        currentStream = stream
        // `currentWatchedDir` historically named — holds the watched
        // path (either skin directory or `.wamp` file URL). The
        // delegate reads `lastPathComponent` off this to recover the
        // skin name, which works for both shapes.
        currentWatchedDir = watchPath
    }

    /// Stop watching the currently-watched skin directory. Three-call
    /// teardown (Stop → Invalidate → Release) is the canonical pattern —
    /// missing any of them leaks the stream into the system event graph.
    func stopWatching() {
        guard let stream = currentStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        currentStream = nil
        currentWatchedDir = nil
    }

    /// Called after the main-queue hop from the FSEventStream callback.
    /// Simply forwards the event to the delegate; the delegate debounces.
    private func fileWatcherDidFireSomeEvents() {
        guard let dir = currentWatchedDir else { return }
        fileWatcherDelegate?.skinEngineDidDetectChange(in: dir)
    }

    deinit {
        // Teardown inline rather than calling stopWatching() — deinit is
        // nonisolated on a @MainActor class, so instance methods are not
        // callable synchronously. FSEventStream* C calls have no actor
        // affinity and are safe to invoke here.
        if let stream = currentStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Composite load (Task 11 prep)

    /// Load a skin fully — manifest, images, surfaces map, fonts — in one
    /// atomic unit. Picker, launch-time persistence, and Task 11 hot reload
    /// all funnel through this so the "apply a skin" sequence stays
    /// in a single code path.
    ///
    /// Throws:
    /// - `SkinLoadError.notFound` when the named skin folder or its
    ///   `skin.json` can't be read.
    /// - `SkinLoadError.parseFailure` when the manifest JSON is malformed,
    ///   the surfaces dict fails to convert, or image loading throws.
    ///
    /// Any throw leaves process state unchanged — no partial font
    /// registration leaks because fonts are registered LAST, after every
    /// other fallible step succeeds. Callers keep their previous
    /// `SkinContext` and `SkinFontBundle` on error.
    ///
    /// `Default` returns `LoadedSkin.defaults` immediately without touching
    /// disk — the sentinel lets callers treat "no skin" uniformly.
    func loadComposite(named name: String) throws -> LoadedSkin {
        if name == "Default" {
            return .defaults
        }

        guard let manifest = loadSkin(named: name) else {
            throw SkinLoadError.notFound(name)
        }

        // Resolve to user dir or bundled dir — loadSkin already succeeded
        // via resolveSkinDir, so this second call is guaranteed to find
        // the same directory.
        guard let skinDir = resolveSkinDir(named: name) else {
            throw SkinLoadError.notFound(name)
        }

        // Images may throw SkinAssetError.invalidPath — surface as parseFailure
        // so callers have one error type to handle.
        let images: [String: NSImage]
        do {
            images = try loadImages(from: skinDir, manifest: manifest)
        } catch {
            throw SkinLoadError.parseFailure("image load failed for '\(name)': \(error)")
        }

        // For each loaded image, attempt to load its `.ninepatch.json`
        // sidecar. A missing sidecar is not an error — the image just
        // won't have ninepatch metadata when a surface references it
        // with `tile: "ninepatch"` (applyTileMode falls back to stretch).
        // This is the wiring fix from Task 13 — previously SkinContext
        // always received nil sidecars regardless of what was on disk.
        var ninepatches: [String: NinepatchSidecar] = [:]
        for path in images.keys {
            if let sidecar = try? loadNinepatchSidecar(for: path, in: skinDir) {
                ninepatches[path] = sidecar
            }
        }

        // Convert v2 surfaces descriptor → ResolvedSurface map. Each surface's
        // fill/state variants are resolved against the image cache. Unknown
        // SurfaceKey raw values in the manifest are logged and skipped — they
        // come from forward-compat manifests and don't invalidate the load.
        var resolvedSurfaces: [SurfaceKey: SkinContext.ResolvedSurface] = [:]
        if let rawSurfaces = manifest.surfaces {
            for (rawKey, descriptor) in rawSurfaces {
                guard let key = SurfaceKey(rawValue: rawKey) else {
                    NSLog("SkinEngine: Unknown surface key '\(rawKey)' in skin '\(name)' — ignoring")
                    continue
                }
                resolvedSurfaces[key] = SkinContext.convert(
                    descriptor,
                    for: key,
                    imageCache: images,
                    ninepatches: ninepatches
                )
            }
        }

        // Register fonts LAST. Any earlier throw returns without touching
        // CTFontManager state. If registerFonts itself partially registers
        // and then has an internal failure, its returned bundle already
        // reflects what actually registered (loadComposite doesn't retry),
        // so callers can still drain symmetrically.
        let fonts = registerFonts(from: skinDir)

        // `surfaces` nil means "manifest had no v2 surfaces block" — caller
        // should fall back to built-in defaults. An empty non-nil map means
        // "v2 surfaces block existed but every key was unknown" — treat
        // the same as nil so chrome views pick defaults rather than
        // rendering an empty resolved state.
        let effectiveSurfaces: [SurfaceKey: SkinContext.ResolvedSurface]? =
            resolvedSurfaces.isEmpty ? nil : resolvedSurfaces

        // Amplify Task 5.2 — validate `manifest.windowShape` when the
        // feature flag is on. Gating here (rather than in the renderer)
        // keeps the flag-off path completely free of shaped-window
        // allocations (Property 12). Validation failures produce a
        // banner reason the chrome layer can surface per Req 13.2.
        let (validatedShape, bannerReason) = resolveWindowShape(
            from: manifest,
            skinName: name
        )

        // Amplify Task 9 — resolve drag regions from the manifest.
        // Empty when no declarations OR when every polygon fails
        // validation. HIG warnings for small regions are logged here
        // (Req 4.5 / 15.5) — visible bbox checks beat users finding
        // out at drag time that 30×30 drag targets don't work.
        let resolvedDragRegions = resolveDragRegions(from: manifest, skinName: name)

        // Chrome v4 Task 7.2 — bake the Base_Layer when the manifest
        // declares a `chrome` field. Baked mode decodes the shipped
        // PNG; composed mode walks v3 surfaces into a CGContext. A
        // bake failure logs and degrades to `chrome = nil` so the
        // pre-v4 rendering path still applies — aligned with
        // `ChromeBakePipeline.BakeError` handling policy (design.md).
        var loadedChrome: ChromeDescriptor? = manifest.chrome
        var loadedBaseImage: CGImage? = nil
        var loadedChromeSHA: String? = nil
        if let chrome = manifest.chrome {
            do {
                let (image, sha) = try bakePipeline.bake(manifest: manifest, skinDir: skinDir)
                loadedChrome = chrome
                loadedBaseImage = image
                loadedChromeSHA = sha
            } catch {
                NSLog("SkinEngine: chrome bake failed for '\(name)': \(error); falling back to pre-v4 path")
                loadedChrome = nil
                loadedBaseImage = nil
                loadedChromeSHA = nil
            }
        }

        return LoadedSkin(
            name: name,
            surfaces: effectiveSurfaces,
            fonts: fonts,
            images: images,
            skinDir: skinDir,
            windowShape: validatedShape,
            validationBannerReason: bannerReason,
            dragRegions: resolvedDragRegions,
            chrome: loadedChrome,
            baseImage: loadedBaseImage,
            chromeSHA: loadedChromeSHA
        )
    }

    /// Amplify Task 9.4 — build `ResolvedDragRegion`s from the
    /// manifest's `dragRegions` array. Polygons with fewer than 3
    /// vertices are dropped per Req 13.5; descriptors where every
    /// polygon fails are omitted. Any polygon whose bbox is under
    /// 44×44 pts emits an HIG warning naming the offending region
    /// index (Req 4.5 / 15.5).
    private func resolveDragRegions(
        from manifest: SkinDefinition,
        skinName: String
    ) -> [ResolvedDragRegion] {
        guard let descriptors = manifest.dragRegions else { return [] }

        var resolved: [ResolvedDragRegion] = []
        for (index, descriptor) in descriptors.enumerated() {
            let pruned = descriptor.prunedToValidPolygons()
            guard !pruned.polygons.isEmpty else {
                NSLog("SkinEngine: skin '\(skinName)' dragRegions[\(index)] has no valid polygons; dropping")
                continue
            }
            let region = ResolvedDragRegion(
                polygons: pruned.polygons,
                modifier: pruned.modifier ?? .none
            )
            // HIG warning — 44×44 is the documented minimum touch
            // target. Warning only; we still use the region (skin
            // author's choice). PRD §10 / Amplify Req 4.5.
            let bbox = region.boundingBox
            if bbox.width < 44 || bbox.height < 44 {
                NSLog("SkinEngine: skin '\(skinName)' dragRegions[\(index)] bounding box \(bbox) is under 44×44 pts — violates HIG touch-target minimum")
            }
            resolved.append(region)
        }
        return resolved
    }

    /// Private helper for Task 5.2 — one place to keep the "only
    /// when flag is on" gate and the validation call together. Nominal
    /// content-view bounds default to the pre-Amplify `1000×700` launch
    /// size so polygons authored against that canvas validate correctly;
    /// runtime checks against the actual window bounds happen when the
    /// renderer installs the mask (Task 5.3).
    private func resolveWindowShape(
        from manifest: SkinDefinition,
        skinName: String
    ) -> (ResolvedWindowShape?, String?) {
        guard let shapeDescriptor = manifest.windowShape else { return (nil, nil) }

        guard ShapedWindowController.isFeatureFlagEnabled() else {
            NSLog("SkinEngine: skin '\(skinName)' declares windowShape but HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS is off — ignoring")
            return (nil, nil)
        }

        let nominalBounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        if let resolved = ShapedWindowController.validate(shapeDescriptor, against: nominalBounds) {
            return (resolved, nil)
        } else {
            return (nil, "Skin \(skinName): invalid window shape, using rectangle")
        }
    }
}
