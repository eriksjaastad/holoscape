import Foundation

// MARK: - Surface Descriptor
//
// JSON structure describing one chrome surface's visual properties.
// Every field is optional; a surface that omits a field falls back to
// the built-in default (the value currently hardcoded in the view file).

struct SurfaceDescriptor: Codable, Equatable, Sendable {
    var fill: FillDescriptor?
    var border: BorderDescriptor?
    var corner: CornerDescriptor?
    var padding: PaddingDescriptor?
    var shadow: ShadowDescriptor?
    var font: FontDescriptor?
    var text: TextDescriptor?
    var animation: AnimationDescriptor?
    var states: [StateVariant]?
}

// MARK: - Fill

/// Background of a surface. Exactly one of `color`, `image`, or `gradient`.
/// Encoded with a `kind` discriminator in JSON:
///
///   { "kind": "color", "value": "#1a1a2e" }
///   { "kind": "image", "path": "assets/tab.png", "tile": "stretch" }
///   { "kind": "gradient", "direction": "vertical", "stops": [...] }
enum FillDescriptor: Codable, Equatable, Sendable {
    case color(String)
    case image(path: String, tile: TileMode)
    case gradient(direction: GradientDirection, stops: [GradientStop])

    enum TileMode: String, Codable, Sendable {
        case stretch
        case tile
        case ninepatch
    }

    enum GradientDirection: String, Codable, Sendable {
        case vertical
        case horizontal
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value, path, tile, direction, stops
    }

    private enum Kind: String, Codable {
        case color, image, gradient
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .color:
            self = .color(try c.decode(String.self, forKey: .value))
        case .image:
            let path = try c.decode(String.self, forKey: .path)
            let tile = try c.decodeIfPresent(TileMode.self, forKey: .tile) ?? .stretch
            self = .image(path: path, tile: tile)
        case .gradient:
            let direction = try c.decode(GradientDirection.self, forKey: .direction)
            let stops = try c.decode([GradientStop].self, forKey: .stops)
            self = .gradient(direction: direction, stops: stops)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .color(let value):
            try c.encode(Kind.color, forKey: .kind)
            try c.encode(value, forKey: .value)
        case .image(let path, let tile):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(tile, forKey: .tile)
        case .gradient(let direction, let stops):
            try c.encode(Kind.gradient, forKey: .kind)
            try c.encode(direction, forKey: .direction)
            try c.encode(stops, forKey: .stops)
        }
    }
}

struct GradientStop: Codable, Equatable, Sendable {
    var offset: Double   // 0.0 to 1.0
    var color: String    // hex
}

// MARK: - Border / Corner / Padding / Shadow

struct BorderDescriptor: Codable, Equatable, Sendable {
    var color: String
    var width: Double
}

/// Corner radius. Either a single value (uniform) or a 4-tuple
/// [topLeft, topRight, bottomRight, bottomLeft].
///
/// JSON encoding: number or 4-element array.
enum CornerDescriptor: Codable, Equatable, Sendable {
    case uniform(Double)
    case asymmetric(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double)

    init(from decoder: Decoder) throws {
        let single = try? decoder.singleValueContainer().decode(Double.self)
        if let value = single {
            self = .uniform(value)
            return
        }
        var array = try decoder.unkeyedContainer()
        if let expected = array.count, expected != 4 {
            throw DecodingError.dataCorruptedError(
                in: array,
                debugDescription: "CornerDescriptor asymmetric form requires exactly 4 elements, got \(expected)")
        }
        let tl = try array.decode(Double.self)
        let tr = try array.decode(Double.self)
        let br = try array.decode(Double.self)
        let bl = try array.decode(Double.self)
        self = .asymmetric(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .uniform(let value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case .asymmetric(let tl, let tr, let br, let bl):
            var c = encoder.unkeyedContainer()
            try c.encode(tl); try c.encode(tr); try c.encode(br); try c.encode(bl)
        }
    }
}

struct PaddingDescriptor: Codable, Equatable, Sendable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double
}

struct ShadowDescriptor: Codable, Equatable, Sendable {
    var color: String
    var opacity: Double
    var blur: Double
    var offsetX: Double
    var offsetY: Double
}

// MARK: - Font / Text

struct FontDescriptor: Codable, Equatable, Sendable {
    var family: String
    var size: Double
    var weight: String?   // "regular", "bold", "medium", etc.
}

struct TextDescriptor: Codable, Equatable, Sendable {
    var color: String
    var shadow: ShadowDescriptor?
}

// MARK: - Animation

struct AnimationDescriptor: Codable, Equatable, Sendable {
    var `default`: CurveDescriptor?
    var fill: CurveDescriptor?
    var corner: CurveDescriptor?
    // Additional per-property overrides added as needed.
}

struct CurveDescriptor: Codable, Equatable, Sendable {
    var duration: Double
    var curve: String   // "linear", "easeIn", "easeOut", "easeInOut", "spring"
}

// MARK: - State Variants + Match Expressions

/// A conditional override that applies when its `match` expression
/// evaluates true against the current ReactiveUniformSnapshot.
/// Evaluated in array order; last match wins (CSS-cascade semantics).
struct StateVariant: Codable, Equatable, Sendable {
    var name: String
    var match: MatchExpression
    // Any subset of SurfaceDescriptor fields to override when active:
    var fill: FillDescriptor?
    var border: BorderDescriptor?
    var corner: CornerDescriptor?
    var animation: AnimationDescriptor?
    var text: TextDescriptor?
}

/// Maps JSON match keys (e.g., "agentState") to operator-or-scalar values.
/// Multi-key matches are combined with logical AND.
struct MatchExpression: Codable, Equatable, Sendable {
    var conditions: [String: MatchValue]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        conditions = try c.decode([String: MatchValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(conditions)
    }
}

/// Either a bare scalar (shorthand for `$eq`), an operator dictionary
/// (e.g., `{"$gte": 1, "$lt": 5}`), or a nested timeSince expression.
enum MatchValue: Codable, Equatable, Sendable {
    case scalar(Double)
    case operators([String: Double])
    case timeSince([String: MatchValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Double.self) {
            self = .scalar(value)
            return
        }
        // Decode as a generic nested dict so we can inspect keys.
        // Operator dicts have all keys starting with `$` (e.g., `$gte`).
        // timeSince dicts have bare uniform names (e.g., `iTimeAgentStateChange`).
        guard let nested = try? c.decode([String: MatchValue].self), !nested.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "MatchValue expected scalar, operator dict, or timeSince dict")
        }
        let hasDollarKey = nested.keys.contains { $0.hasPrefix("$") }
        let allDollarKeys = nested.keys.allSatisfy { $0.hasPrefix("$") }
        if hasDollarKey && allDollarKeys {
            // All keys start with `$` — must be an operator dict with Double values.
            var ops: [String: Double] = [:]
            for (key, value) in nested {
                guard case .scalar(let scalar) = value else {
                    throw DecodingError.dataCorruptedError(
                        in: c,
                        debugDescription: "Operator '\(key)' must have a numeric value")
                }
                ops[key] = scalar
            }
            self = .operators(ops)
        } else if hasDollarKey {
            // Mixed `$`-keys and bare keys — malformed.
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "MatchValue mixes operator keys ($-prefixed) with bare keys")
        } else {
            self = .timeSince(nested)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .scalar(let value):
            try c.encode(value)
        case .operators(let ops):
            try c.encode(ops)
        case .timeSince(let nested):
            try c.encode(nested)
        }
    }
}
