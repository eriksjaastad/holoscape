import Foundation

/// Manifest describing a Holoscape skin.
///
/// Two format generations coexist:
///
/// - **v1** (original): a flat set of 10 optional color/image fields applied
///   to the AppearanceConfig. Chrome view appearance was hardcoded and
///   ignored these fields beyond ANSI palette colors.
/// - **v2**: adds an optional `surfaces` dictionary describing per-chrome-surface
///   appearance (fill, border, corner, animation, state variants). Chrome views
///   resolve their appearance through SkinContext at runtime.
///
/// V1 skins continue to load and render correctly. When a manifest has both v1
/// fields and a v2 `surfaces` dictionary, v2 takes precedence for any surface
/// it defines and v1 fields fall through for surfaces it doesn't.
struct SkinDefinition: Codable, Equatable, Sendable {
    // MARK: - v1 fields (unchanged)
    var windowBackground: String?
    var titleBarBackground: String?
    var sidebarBackground: String?
    var tabActiveColor: String?
    var tabInactiveColor: String?
    var textForeground: String?
    var ansiColors: [String]?            // 16 hex strings
    var windowBackgroundImage: String?    // relative path to PNG
    var sidebarBackgroundImage: String?   // relative path to PNG
    var tabBarBackgroundImage: String?    // relative path to PNG

    // MARK: - v2 fields (optional, additive)

    /// Schema version. Defaults to `"1.0"` when absent.
    var version: String?

    /// Human-readable skin name (shown in the Appearance Settings picker).
    var name: String?

    /// Skin author attribution.
    var author: String?

    /// Short description shown alongside the name.
    var description: String?

    /// Per-chrome-surface appearance overrides. Keyed by the raw value of
    /// `SurfaceKey` (e.g., `"tabBar.tab.active"`). Unknown keys are ignored
    /// to preserve forward compatibility.
    var surfaces: [String: SurfaceDescriptor]?
}
