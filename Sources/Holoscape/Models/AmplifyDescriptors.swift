import Foundation

// MARK: - Point / Polygon
//
// Geometric primitives used by Window_Shape_Descriptor and
// Drag_Region_Descriptor. Points are in content-view coordinates;
// polygons are ordered lists of at least 3 vertices defining a closed
// region. Ray-cast hit testing (Jordan curve theorem) and CAShapeLayer
// path construction both read from these primitives without any
// intermediate form.

struct Point: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct Polygon: Codable, Equatable, Sendable {
    var points: [Point]

    /// A polygon with fewer than 3 vertices cannot define a closed region.
    /// Consumed at validate time by `ShapedWindowController.validate` and
    /// drag-region parsing, which drop invalid entries with a logged
    /// warning (graceful degradation per Requirement 13.5).
    func isValid() -> Bool { points.count >= 3 }
}

// MARK: - Window Shape

/// Declares the window's non-rectangular shape (Requirement 2). MVP
/// ships `kind: polygons` only; `kind: mask` is accepted by Codable so
/// v3 manifests round-trip cleanly, but `ShapedWindowController.validate`
/// rejects it with `"kind: mask is post-MVP; ignoring shape"` (Requirement
/// 2.9). Reserved for the Phase-2 PNG-alpha mask path.
struct WindowShapeDescriptor: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case polygons
        case mask
    }

    var kind: Kind
    var polygons: [Polygon]?   // required when kind == .polygons
    var maskPath: String?      // reserved; post-MVP (kind == .mask)
}

// MARK: - Drag Regions

/// Declares skin-authored drag-handle polygon regions. mouseDown inside
/// any polygon invokes `window.performDrag(with:)` so a borderless
/// shaped window is still draggable from its skin-painted chrome
/// (Requirement 4).
struct DragRegionDescriptor: Codable, Equatable, Sendable {
    /// Modifier gating on drag initiation. Default `.none` means any
    /// mouseDown inside the polygon starts a drag. `.command` requires
    /// `NSEvent.modifierFlags.contains(.command)` at mouseDown time
    /// (Requirement 4.7). Additional modifiers can be added without
    /// breaking decoded manifests because the enum rejects unknown
    /// values via Codable's default decoding (manifests with an
    /// unrecognized modifier fall back to `.none` via decodeIfPresent).
    enum Modifier: String, Codable, Sendable {
        case none
        case command
    }

    var polygons: [Polygon]
    var modifier: Modifier?

    /// Drop individual polygons whose vertex count is below 3. Returns
    /// a copy with only valid polygons; callers use this to surface a
    /// single warning per malformed descriptor instead of one per
    /// vertex (Requirement 13.5).
    func prunedToValidPolygons() -> DragRegionDescriptor {
        var copy = self
        copy.polygons = polygons.filter { $0.isValid() }
        return copy
    }
}

// MARK: - Sprite Sheets

/// One cell's position inside a sprite sheet, in grid coordinates.
/// Pixel coordinates are derived at render time from
/// `(col * cellWidth, row * cellHeight)`.
struct SpriteCell: Codable, Equatable, Sendable {
    var row: Int
    var col: Int
}

/// Sprite-sheet metadata attached to a `FillDescriptor.image`. At render
/// time, `SkinContext.applyFill` assigns the full sheet to `layer.contents`
/// once per skin load and sets `layer.contentsRect` to the UV rect of
/// the cell matching the current `Sprite_State`. State transitions mutate
/// `contentsRect` only — no per-state NSImage crop, no CGImage reallocation
/// on the hot path. Design §6 SkinContext.applyFill.
struct SpriteDescriptor: Codable, Equatable, Sendable {
    var cellWidth: Int
    var cellHeight: Int
    var rows: Int
    var cols: Int
    /// State name → cell position. Keys come from `SpriteState.rawValue`.
    /// At resolve time, missing states fall back to `normal`; if
    /// `normal` is also absent the full sheet renders in stretch mode
    /// (Requirement 5.3).
    var stateMap: [String: SpriteCell]

    /// Validate the descriptor against the loaded sheet's pixel size.
    /// Rejects dimension mismatches at load time so the hot render path
    /// never needs out-of-bounds checks (Requirement 5.4).
    func isValid(imageSize: CGSize) -> Bool {
        guard cellWidth > 0, cellHeight > 0, rows > 0, cols > 0 else { return false }
        let maxPixelWidth = cellWidth * cols
        let maxPixelHeight = cellHeight * rows
        guard Double(maxPixelWidth) <= imageSize.width,
              Double(maxPixelHeight) <= imageSize.height else { return false }
        // Every cell in the stateMap must fit within the declared grid.
        for cell in stateMap.values {
            guard cell.row >= 0, cell.row < rows,
                  cell.col >= 0, cell.col < cols else { return false }
        }
        return true
    }
}

/// Interactive state published by a chrome view. Raw values are the
/// `SpriteDescriptor.stateMap` keys; Int32 representation is what
/// `ReactiveUniformSnapshot.spriteState` carries so state-variant match
/// expressions can key off `spriteState`.
///
/// The enum is ordered so that Int32 rawInt equals the common-sense
/// interactivity level (0 = idle/normal, 6 = most-foregrounded). Keep
/// this mapping stable — `fromInt32` and anything reading
/// `snapshot.spriteState` both depend on it.
enum SpriteState: String, Codable, Sendable, CaseIterable {
    case normal    // 0
    case hover     // 1
    case pressed   // 2
    case active    // 3
    case disabled  // 4
    case focused   // 5
    case selected  // 6

    /// Int32 representation written into `ReactiveUniformSnapshot.spriteState`.
    var rawInt: Int32 {
        switch self {
        case .normal:   return 0
        case .hover:    return 1
        case .pressed:  return 2
        case .active:   return 3
        case .disabled: return 4
        case .focused:  return 5
        case .selected: return 6
        }
    }

    /// Inverse of `rawInt`. Out-of-range values fall back to `.normal`
    /// rather than crashing — snapshots read from match expressions
    /// that might carry arbitrary integers, and `.normal` is the safe
    /// pre-Amplify default.
    static func fromInt32(_ value: Int32) -> SpriteState {
        switch value {
        case 0: return .normal
        case 1: return .hover
        case 2: return .pressed
        case 3: return .active
        case 4: return .disabled
        case 5: return .focused
        case 6: return .selected
        default: return .normal
        }
    }
}
