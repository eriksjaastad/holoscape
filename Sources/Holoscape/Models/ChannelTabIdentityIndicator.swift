import Foundation

/// Compact, UI-safe identity shown in tab labels for attached agents and
/// transport-like channels. The value is derived from Holoscape's channel model
/// and launch metadata; it is display-only and never changes process routing.
enum ChannelTabIdentityIndicator: String, Codable, Equatable, Sendable {
    case claude
    case codex
    case gemini
    case ollama
    case ssh

    var icon: String {
        switch self {
        case .claude: return "◆"
        case .codex: return "◈"
        case .gemini: return "✦"
        case .ollama: return "●"
        case .ssh: return "⌁"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        case .ssh: return "SSH"
        }
    }

    var tabPrefix: String { "\(icon) " }

    static func detect(from parts: [String?]) -> ChannelTabIdentityIndicator? {
        let searchable = parts
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        guard !searchable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if searchable.contains("claude") { return .claude }
        if searchable.contains("codex") { return .codex }
        if searchable.contains("gemini") { return .gemini }
        if searchable.contains("ollama") { return .ollama }
        return nil
    }
}
