import Foundation

enum AgentAuthType: Sendable {
    case oauth
    case apiKey(String)
    /// Restored API-agent cleanup authority that must survive without a key.
    /// Resolve from Keychain before any replacement process launch.
    case deferredAPIKey
}
