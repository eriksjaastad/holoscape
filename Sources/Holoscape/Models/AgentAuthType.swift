import Foundation

enum AgentAuthType: Sendable {
    case oauth
    case apiKey(String)
}
