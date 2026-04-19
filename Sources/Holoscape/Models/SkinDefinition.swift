import Foundation

/// Manifest describing a Holoscape skin.
///
/// Three format generations coexist:
///
/// - **v1** (original): a flat set of 10 optional color/image fields applied
///   to the AppearanceConfig. Chrome view appearance was hardcoded and
///   ignored these fields beyond ANSI palette colors.
/// - **v2**: adds an optional `surfaces` dictionary describing per-chrome-surface
///   appearance (fill, border, corner, animation, state variants). Chrome views
///   resolve their appearance through SkinContext at runtime.
/// - **v3 (Amplify)**: adds optional `windowShape` (non-rectangular window
///   polygons) and `dragRegions` (skin-authored drag handles) alongside sprite
///   metadata carried on `FillDescriptor.image`. `version: "3.0"` signals an
///   Amplify manifest, but every v3 field is optional — a manifest that omits
///   all v3 fields decodes and renders identically to its v2 form.
///
/// V1 and v2 skins continue to load and render correctly. When a manifest has
/// both v1 fields and a v2 `surfaces` dictionary, v2 takes precedence for any
/// surface it defines and v1 fields fall through for surfaces it doesn't.
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

    // MARK: - v3 fields (Amplify, optional, additive)

    /// Non-rectangular window shape. When present and the
    /// `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` env flag is on, the main window
    /// is reconstructed borderless with a `CAShapeLayer` mask built from
    /// the declared polygons. See `WindowShapeDescriptor` for the
    /// MVP-vs-post-MVP kind split.
    var windowShape: WindowShapeDescriptor?

    /// Skin-authored drag-handle regions. Each descriptor's polygons
    /// install an `NSTrackingArea`; a `mouseDown` inside any polygon
    /// triggers `window.performDrag(with:)`.
    var dragRegions: [DragRegionDescriptor]?
}
