import Foundation

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
}
