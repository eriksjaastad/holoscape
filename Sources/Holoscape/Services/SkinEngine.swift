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
        skinDir: nil
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

    /// Dedicated serial queue FSEvents posts its callbacks on. Separate
    /// from main so the callback doesn't contend with UI work; the
    /// callback immediately hops back to main before touching any engine
    /// state.
    private let watcherQueue = DispatchQueue(label: "holoscape.skin.watcher")

    init() {
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            self.skinsDirectory = URL(fileURLWithPath: override).appendingPathComponent("skins")
        } else {
            self.skinsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".holoscape/skins")
        }
    }

    /// List all available skin names. Always includes "Default" first.
    func availableSkins() -> [String] {
        var skins = ["Default"]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: skinsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return skins
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                let skinJson = entry.appendingPathComponent("skin.json")
                if FileManager.default.fileExists(atPath: skinJson.path) {
                    skins.append(entry.lastPathComponent)
                }
            }
        }
        return skins
    }

    /// Load a skin definition by name. Returns nil for "Default" or invalid skins.
    func loadSkin(named name: String) -> SkinDefinition? {
        guard name != "Default" else { return nil }
        let skinDir = skinsDirectory.appendingPathComponent(name)
        let skinJson = skinDir.appendingPathComponent("skin.json")
        guard let data = try? Data(contentsOf: skinJson) else {
            NSLog("SkinEngine: Could not read skin.json for '\(name)'")
            return nil
        }
        guard var skin = try? JSONDecoder().decode(SkinDefinition.self, from: data) else {
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
    private func assertPathResolvesInside(_ fileURL: URL, root: URL, originalPath: String) throws {
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
            if let fill = surface.fill, case .image(let path, _) = fill {
                paths.insert(path)
            }
            if let states = surface.states {
                for state in states {
                    if let fill = state.fill, case .image(let path, _) = fill {
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
        let skinDir = skinsDirectory.appendingPathComponent(skinName)
        guard FileManager.default.fileExists(atPath: skinDir.path) else {
            NSLog("SkinEngine: Cannot watch '\(skinName)' — directory does not exist")
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
        let paths = [skinDir.path] as CFArray

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
        currentWatchedDir = skinDir
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

        let skinDir = skinsDirectory.appendingPathComponent(name)

        // Images may throw SkinAssetError.invalidPath — surface as parseFailure
        // so callers have one error type to handle.
        let images: [String: NSImage]
        do {
            images = try loadImages(from: skinDir, manifest: manifest)
        } catch {
            throw SkinLoadError.parseFailure("image load failed for '\(name)': \(error)")
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
                resolvedSurfaces[key] = SkinContext.convert(descriptor, for: key, imageCache: images)
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

        return LoadedSkin(
            name: name,
            surfaces: effectiveSurfaces,
            fonts: fonts,
            images: images,
            skinDir: skinDir
        )
    }
}
