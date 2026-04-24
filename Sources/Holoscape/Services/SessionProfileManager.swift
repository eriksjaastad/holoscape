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
        SessionProfile(label: "Shell", connection: .local, command: "/bin/zsh", directory: DefaultWorkingDirectory.preferredPath),
        SessionProfile(label: "Claude", connection: .local, command: "claude", directory: DefaultWorkingDirectory.preferredPath),
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
        let requestedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = configService.load()

        if let directSSH = directSSHProfile(from: requestedLabel, config: config) {
            return directSSH
        }

        if let claudeProject = claudeProjectProfile(from: requestedLabel, config: config) {
            return claudeProject
        }

        // Check built-in profiles
        if let match = Self.builtInProfiles.first(where: { $0.label.caseInsensitiveCompare(requestedLabel) == .orderedSame }) {
            return match
        }

        // Check preconfigured profiles
        if let match = (config.sessionProfiles ?? []).first(where: { $0.label.caseInsensitiveCompare(requestedLabel) == .orderedSame }) {
            return match.resolved(with: config.sshDefaults)
        }

        // Check discovered projects
        if let match = discoveryService.cached().first(where: { $0.label.caseInsensitiveCompare(requestedLabel) == .orderedSame }) {
            return match.resolved(with: config.sshDefaults)
        }

        // Create a new SSH project session only when SSH defaults are
        // configured. Otherwise treat typed text as a local project
        // launcher under ~/projects so "Open session..." is useful out
        // of the box on this Mac.
        let defaults = config.sshDefaults ?? .default
        let discovery = config.projectDiscovery ?? .default
        guard !defaults.host.isEmpty, !defaults.user.isEmpty, discovery.connection == "ssh" else {
            return SessionProfile(
                label: requestedLabel,
                connection: .local,
                command: "/bin/zsh",
                directory: DefaultWorkingDirectory.localSessionDirectory(named: requestedLabel, root: discovery.root).path
            )
        }
        return SessionProfile(
            label: requestedLabel,
            connection: .ssh,
            command: discovery.command,
            directory: "\(discovery.root)/\(requestedLabel)",
            host: defaults.host,
            user: defaults.user
        )
    }

    private func claudeProjectProfile(from label: String, config: HoloscapeConfig) -> SessionProfile? {
        let words = label.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2 else { return nil }

        let projectName: String
        if words[0].caseInsensitiveCompare("claude") == .orderedSame {
            projectName = words[1]
        } else if words[1].caseInsensitiveCompare("claude") == .orderedSame {
            projectName = words[0]
        } else {
            return nil
        }

        let root = (config.projectDiscovery ?? .default).root
        let directory = DefaultWorkingDirectory.localSessionDirectory(named: projectName, root: root)
        return SessionProfile(
            label: "Claude-\(directory.lastPathComponent)",
            connection: .local,
            command: "claude",
            directory: directory.path
        )
    }

    private func directSSHProfile(from label: String, config: HoloscapeConfig) -> SessionProfile? {
        let parts = label.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("ssh") == .orderedSame else {
            return nil
        }

        let destination = parts[1]
        guard !destination.isEmpty else { return nil }

        let destinationParts = destination.split(separator: "@", maxSplits: 1).map(String.init)
        let defaults = config.sshDefaults ?? .default
        let user: String
        let host: String
        if destinationParts.count == 2 {
            user = destinationParts[0]
            host = destinationParts[1]
        } else {
            user = defaults.user.isEmpty ? NSUserName() : defaults.user
            host = destination
        }
        guard !user.isEmpty, !host.isEmpty else { return nil }

        return SessionProfile(
            label: host,
            connection: .ssh,
            command: "exec ${SHELL:-/bin/zsh} -l",
            directory: "~",
            host: host,
            user: user
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
