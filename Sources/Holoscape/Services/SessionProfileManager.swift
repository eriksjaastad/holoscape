import Foundation

@MainActor
class SessionProfileManager {
    private let configService: ConfigService
    private let discoveryService: ProjectDiscoveryService

    init(configService: ConfigService, discoveryService: ProjectDiscoveryService) {
        self.configService = configService
        self.discoveryService = discoveryService
    }

    /// Returns all sessions grouped by source.
    /// Built-in profiles always available.
    static let builtInProfiles: [SessionProfile] = [
        SessionProfile(label: "Bridge", connection: .bridge, command: "", directory: ""),
    ]

    func allSessions() -> (preconfigured: [SessionProfile], discovered: [SessionProfile], recent: [RecentSession]) {
        let config = configService.load()
        let userProfiles = config.sessionProfiles ?? []
        let preconfigured = userProfiles + Self.builtInProfiles
        let discovered = discoveryService.cached()
        let recent = config.recentSessions ?? []
        return (preconfigured, discovered, recent)
    }

    /// Resolve a label to a SessionProfile.
    /// Checks preconfigured → discovered → creates new SSH project session from ssh_defaults.
    func resolve(label: String) -> SessionProfile {
        let config = configService.load()

        // Check built-in profiles
        if let match = Self.builtInProfiles.first(where: { $0.label == label }) {
            return match
        }

        // Check preconfigured profiles
        if let match = (config.sessionProfiles ?? []).first(where: { $0.label == label }) {
            return match.resolved(with: config.sshDefaults)
        }

        // Check discovered projects
        if let match = discoveryService.cached().first(where: { $0.label == label }) {
            return match.resolved(with: config.sshDefaults)
        }

        // Create a new SSH project session from defaults
        let defaults = config.sshDefaults ?? .default
        let discovery = config.projectDiscovery ?? .default
        return SessionProfile(
            label: label,
            connection: .ssh,
            command: discovery.command,
            directory: "\(discovery.root)/\(label)",
            host: defaults.host,
            user: defaults.user
        )
    }

    /// Record a session as recently used. Deduplicates, prepends, caps at 20.
    func recordRecentSession(label: String) {
        var config = configService.load()
        var recent = config.recentSessions ?? []

        // Remove existing entry with same label
        recent.removeAll { $0.label == label }

        // Prepend new entry
        recent.insert(RecentSession(label: label, timestamp: Date()), at: 0)

        // Cap at 20
        if recent.count > 20 {
            recent = Array(recent.prefix(20))
        }

        config.recentSessions = recent
        configService.save(config)
    }
}
