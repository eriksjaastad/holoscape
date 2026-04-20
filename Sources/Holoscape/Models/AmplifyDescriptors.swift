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

// MARK: - Chrome (v4)
//
// PNG-alpha compositing-host chrome, first shipped in Skin_Definition v4.
// A skin with a `chrome` descriptor routes through Chrome_Mode_Branch in
// `MainWindowController`: the window is constructed borderless +
// transparent + non-resizable, `ChromeHostView` becomes the sole root
// view, and `InteriorView` — sized to `interiorRect` — hosts every app
// subview. v1/v2/v3 manifests omit `chrome` and keep their existing
// rendering path unchanged (backward-compatibility invariant, Req 16.1).

/// Rectangle in chrome-image coordinates (top-left origin, logical
/// points). Distinct from `CGRect` so models stay AppKit-free and
/// Sendable. Consumed by `ChromeDescriptor.interiorRect` and every
/// `ChromeAnimationLayer.rect`.
struct SkinRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Parameters for a `.particle` animated layer. Every field maps 1-to-1
/// to a `CAEmitterCell` property at render time (PR #10 —
/// `ParticleLayerRenderer`). `image` is bundle-relative; `nil` triggers
/// the procedurally-generated soft-dot fallback.
struct ParticleParams: Codable, Equatable, Sendable {
    enum BlendMode: String, Codable, Sendable { case normal, additive, screen }

    var birthRate: Double
    var lifetime: Double
    var lifetimeRange: Double?
    var velocity: Double
    var velocityRange: Double?
    var emissionAngle: Double          // radians
    var emissionRange: Double          // radians
    var color: String                  // "#rrggbbaa"
    var colorRange: String?
    var scale: Double
    var scaleRange: Double?
    var image: String?
    var blendMode: BlendMode?
}

/// Parameters for a `.ledArray` animated layer. Cell positions are in
/// layer-local coords; `palette` indexes the RGB swatch set; `pattern`
/// drives per-cell state evolution against `SharedAnimationClock` phase
/// (PR #11 — `LEDArrayLayerRenderer`).
struct LedArrayParams: Codable, Equatable, Sendable {
    struct LedCell: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var defaultState: Int
    }

    /// State-evolution rule. Codable form uses a single-key discriminator
    /// so the worked manifest example (`"pattern": { "phased": { "hz":
    /// 2.0 } }`) round-trips without an outer type tag. `.steady` encodes
    /// as `{ "steady": {} }` to keep the shape consistent across cases.
    enum Pattern: Equatable, Sendable {
        case steady
        case blink(hz: Double, duty: Double)
        case phased(hz: Double)
        case random(hz: Double, density: Double)
        case marquee(cellsPerSecond: Double, windowSize: Int)
    }

    var cellSize: Double
    var cells: [LedCell]
    var palette: [String]              // hex colors
    var pattern: Pattern
}

extension LedArrayParams.Pattern: Codable {
    private enum Tag: String, CodingKey {
        case steady, blink, phased, random, marquee
    }

    private struct Empty: Codable, Equatable {}

    private struct BlinkPayload: Codable, Equatable {
        var hz: Double
        var duty: Double
    }

    private struct PhasedPayload: Codable, Equatable {
        var hz: Double
    }

    private struct RandomPayload: Codable, Equatable {
        var hz: Double
        var density: Double
    }

    private struct MarqueePayload: Codable, Equatable {
        var cellsPerSecond: Double
        var windowSize: Int
    }

    /// Raw CodingKey that accepts any string. Used for a first pass over
    /// the JSON object so we can count and reject unknown keys — a typed
    /// `keyedBy: Tag.self` container silently drops keys that aren't in
    /// the enum, which would let `{ "phased": {...}, "garbage": {} }`
    /// decode as `.phased` without complaint.
    private struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: RawKey.self)
        guard raw.allKeys.count == 1, let rawTag = raw.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "LedArrayParams.Pattern expected exactly one of: steady, blink, phased, random, marquee; got \(raw.allKeys.map(\.stringValue))"
            ))
        }
        guard let tag = Tag(rawValue: rawTag.stringValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "LedArrayParams.Pattern unknown discriminator '\(rawTag.stringValue)'; expected one of: steady, blink, phased, random, marquee"
            ))
        }
        let container = try decoder.container(keyedBy: Tag.self)
        switch tag {
        case .steady:
            _ = try container.decode(Empty.self, forKey: .steady)
            self = .steady
        case .blink:
            let p = try container.decode(BlinkPayload.self, forKey: .blink)
            self = .blink(hz: p.hz, duty: p.duty)
        case .phased:
            let p = try container.decode(PhasedPayload.self, forKey: .phased)
            self = .phased(hz: p.hz)
        case .random:
            let p = try container.decode(RandomPayload.self, forKey: .random)
            self = .random(hz: p.hz, density: p.density)
        case .marquee:
            let p = try container.decode(MarqueePayload.self, forKey: .marquee)
            self = .marquee(cellsPerSecond: p.cellsPerSecond, windowSize: p.windowSize)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .steady:
            try container.encode(Empty(), forKey: .steady)
        case let .blink(hz, duty):
            try container.encode(BlinkPayload(hz: hz, duty: duty), forKey: .blink)
        case let .phased(hz):
            try container.encode(PhasedPayload(hz: hz), forKey: .phased)
        case let .random(hz, density):
            try container.encode(RandomPayload(hz: hz, density: density), forKey: .random)
        case let .marquee(cellsPerSecond, windowSize):
            try container.encode(MarqueePayload(cellsPerSecond: cellsPerSecond, windowSize: windowSize), forKey: .marquee)
        }
    }
}

/// Parameters for a `.spriteAnim` animated layer. `sheet` is a bundle-
/// relative PNG laid out as a `gridRows × gridCols` atlas; the renderer
/// advances `contentsRect` through `frameCount` frames at `fps`
/// (PR #11 — `SpriteAnimLayerRenderer`). `frameCount` may be less than
/// `gridRows * gridCols` to support irregular atlases.
struct SpriteAnimParams: Codable, Equatable, Sendable {
    enum Loop: String, Codable, Sendable { case loop, pingPong, once }

    var sheet: String
    var gridRows: Int
    var gridCols: Int
    var frameCount: Int
    var fps: Double
    var loop: Loop
}

/// Parameters for a `.shader` animated layer. MVP ships three presets as
/// built-in Metal fragment functions (PR #12 — `ChromeShaders.metal` +
/// `ShaderPresetLayerRenderer`); `ChromeManifestValidator` rejects any
/// other preset at load time.
struct ShaderParams: Codable, Equatable, Sendable {
    enum Preset: String, Codable, Sendable { case glow, scanlines, noise }

    var preset: Preset
    var color: String?
    var intensity: Double?
    var hz: Double?
}

/// One animated layer stacked above Base_Layer inside ChromeHostView.
/// Exactly one `Params` field is non-nil, matching `kind`; validator
/// (PR #5) enforces this. `z > 0` is required — Base_Layer occupies an
/// implicit `z = 0` and the validator rejects animations at `z <= 0`.
struct ChromeAnimationLayer: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case particle, ledArray, spriteAnim, shader
    }

    /// Forward-compatible binding surface. MVP recognizes only `.none`
    /// and `.time`; validator rejects unknown cases with a banner
    /// naming the offending `id`. Post-MVP adds `.cpuLoad`,
    /// `.keystrokeRate`, etc. additively.
    enum DataSource: String, Codable, Sendable {
        case none, time
    }

    /// Per-kind parameter bundle. Exactly one field should be non-nil;
    /// validator enforces that it matches `kind`.
    struct Params: Codable, Equatable, Sendable {
        var particle: ParticleParams?
        var ledArray: LedArrayParams?
        var spriteAnim: SpriteAnimParams?
        var shader: ShaderParams?
    }

    var id: String
    var kind: Kind
    var rect: SkinRect
    var z: Int
    var phaseOffset: Double?
    var speedMultiplier: Double?
    var dataSource: DataSource?
    var params: Params
}

/// Root of the Chrome v4 manifest field. `mode == .baked` means the
/// skin ships a pre-rendered `image`; `mode == .composed` means
/// `ChromeBakePipeline` (PR #4) composites one from v3 surface
/// descriptors. `interiorRect` names the window region where app
/// content lives; `InteriorView` (PR #3) is pinned there. `animations`
/// drive per-frame layers stacked above the static Base_Layer.
///
/// Skin_Definition gains an optional `chrome: ChromeDescriptor?` in v4
/// — present routes through Chrome_Mode_Branch; absent preserves the
/// pre-v4 rendering path (Req 16.1, 16.3).
struct ChromeDescriptor: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case baked, composed }

    var mode: Mode
    var image: String?                 // required when mode == .baked; bundle-relative
    var imageOpaque: String?           // Reduce Transparency variant; optional
    var width: Int                     // logical points; equals nominal window width
    var height: Int                    // logical points
    var interiorRect: SkinRect         // top-left origin in chrome-image coords
    var interiorPath: [Polygon]?       // concave interiors only
    var animations: [ChromeAnimationLayer]?

    private enum CodingKeys: String, CodingKey {
        case mode, image, imageOpaque, width, height, interiorRect, interiorPath, animations
    }

    /// Decode-time enforcement of Req 1.2: `mode == .baked` requires a
    /// non-nil, non-empty `image` path. Composed mode leaves `image`
    /// optional — `ChromeBakePipeline` produces the image at load time.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decode(Mode.self, forKey: .mode)
        self.image = try c.decodeIfPresent(String.self, forKey: .image)
        self.imageOpaque = try c.decodeIfPresent(String.self, forKey: .imageOpaque)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.interiorRect = try c.decode(SkinRect.self, forKey: .interiorRect)
        self.interiorPath = try c.decodeIfPresent([Polygon].self, forKey: .interiorPath)
        self.animations = try c.decodeIfPresent([ChromeAnimationLayer].self, forKey: .animations)

        if mode == .baked {
            // Req 1.2 — a whitespace-only path is functionally empty;
            // trim before the check so decoded manifests can't carry a
            // path that `SkinEngine` would later fail on silently.
            guard let path = image,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .image,
                    in: c,
                    debugDescription: "ChromeDescriptor.mode == .baked requires a non-empty image path"
                )
            }
        }
    }

    /// Synthesized memberwise init — preserved explicitly because the
    /// custom `init(from:)` otherwise suppresses it.
    init(
        mode: Mode,
        image: String? = nil,
        imageOpaque: String? = nil,
        width: Int,
        height: Int,
        interiorRect: SkinRect,
        interiorPath: [Polygon]? = nil,
        animations: [ChromeAnimationLayer]? = nil
    ) {
        self.mode = mode
        self.image = image
        self.imageOpaque = imageOpaque
        self.width = width
        self.height = height
        self.interiorRect = interiorRect
        self.interiorPath = interiorPath
        self.animations = animations
    }
}
