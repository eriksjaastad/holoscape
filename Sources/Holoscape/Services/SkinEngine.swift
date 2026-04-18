import Foundation
import AppKit
import CoreText

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

@MainActor
class SkinEngine {
    private let skinsDirectory: URL

    /// Density gate. When `isSkinActive()` returns false (Off mode), `apply`
    /// returns its input unchanged so chrome views render the pre-skinning
    /// hardcoded defaults — enforcing the zero-overhead-idle-chrome guarantee
    /// (Property 7, Requirement 15.1). When nil, skin application proceeds
    /// normally (pre-DensityModeManager default).
    weak var densityModeManager: DensityModeManager?

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
}
