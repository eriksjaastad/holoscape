import CoreGraphics
import Foundation

/// Optional app-content vessel layout for skins that want to wrap the
/// built-in channel list and terminal surfaces inside a stronger shell
/// composition. V1 keeps this intentionally narrow: one left-docked,
/// vertical channel vessel; one framed screen vessel; one simple seam.
struct SkinLayoutDescriptor: Codable, Equatable, Sendable {
    var channelVessel: ChannelVesselLayoutDescriptor?
    var screenVessel: ScreenVesselLayoutDescriptor?
    var seam: SeamLayoutDescriptor?
}

struct ChannelVesselLayoutDescriptor: Codable, Equatable, Sendable {
    var dock: ChannelVesselDock
    var size: CGFloat
    var capStart: CGFloat
    var capEnd: CGFloat
    var variant: ChannelVesselVariant?
}

enum ChannelVesselDock: Equatable, Sendable {
    case left
    case unsupported(String)
}

extension ChannelVesselDock: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "left":
            self = .left
        default:
            self = .unsupported(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .left:
            try container.encode("left")
        case .unsupported(let raw):
            try container.encode(raw)
        }
    }
}

enum ChannelVesselVariant: Equatable, Sendable {
    case plain
    case mercuryControlSpine
    case unsupported(String)
}

extension ChannelVesselVariant: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "plain":
            self = .plain
        case "mercuryControlSpine":
            self = .mercuryControlSpine
        default:
            self = .unsupported(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain:
            try container.encode("plain")
        case .mercuryControlSpine:
            try container.encode("mercuryControlSpine")
        case .unsupported(let raw):
            try container.encode(raw)
        }
    }
}

struct ScreenVesselLayoutDescriptor: Codable, Equatable, Sendable {
    var viewportInsets: SkinLayoutInsets
    var variant: ScreenVesselVariant?
}

enum ScreenVesselVariant: Equatable, Sendable {
    case plain
    case mercuryScreenBody
    case unsupported(String)
}

extension ScreenVesselVariant: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "plain":
            self = .plain
        case "mercuryScreenBody":
            self = .mercuryScreenBody
        default:
            self = .unsupported(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain:
            try container.encode("plain")
        case .mercuryScreenBody:
            try container.encode("mercuryScreenBody")
        case .unsupported(let raw):
            try container.encode(raw)
        }
    }
}

struct SeamLayoutDescriptor: Codable, Equatable, Sendable {
    var thickness: CGFloat
    var style: VesselSeamStyle
}

enum VesselSeamStyle: Equatable, Sendable {
    case flat
    case mechanical
    case unsupported(String)
}

extension VesselSeamStyle: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "flat":
            self = .flat
        case "mechanical":
            self = .mechanical
        default:
            self = .unsupported(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flat:
            try container.encode("flat")
        case .mechanical:
            try container.encode("mechanical")
        case .unsupported(let raw):
            try container.encode(raw)
        }
    }
}

struct SkinLayoutInsets: Codable, Equatable, Sendable {
    var top: CGFloat
    var right: CGFloat
    var bottom: CGFloat
    var left: CGFloat
}
