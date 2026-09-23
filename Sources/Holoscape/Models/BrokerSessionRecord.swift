import Foundation

/// Stable broker-owned session identity that can outlive a window, tab, or UI process.
struct BrokerSessionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        precondition(!rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "BrokerSessionID cannot be empty")
        self.rawValue = rawValue
    }
}

/// Terminal character-cell size known by the broker side of a PTY session.
struct TerminalGridSize: Codable, Equatable, Sendable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        precondition(columns > 0, "TerminalGridSize columns must be positive")
        precondition(rows > 0, "TerminalGridSize rows must be positive")
        self.columns = columns
        self.rows = rows
    }
}

/// Named environment recipe for a broker launch.
///
/// The broker registry stores this profile name instead of raw environment values so durable
/// session records do not persist secrets copied from the UI process environment.
enum BrokerEnvironmentProfile: String, Codable, Equatable, Sendable {
    case shell
    case agentOAuth
    case agentAPI
    case ssh
}

/// Internal lifecycle states for process-survival work.
///
/// UI-facing `ChannelState` remains intentionally small for now; broker sessions need the richer
/// vocabulary required by docs/session-survival-substrate.md before tab truth can be mapped cleanly.
enum BrokerSessionLifecycle: String, Codable, Equatable, Sendable {
    case creating
    case running
    case detached
    case reattaching
    case exited
    case errored
    case stale
    case terminating
}

/// Safe launch intent passed to the future Holoscape-owned native session broker.
///
/// This is not a process handle and deliberately does not contain raw environment key/value pairs.
struct BrokerSessionLaunchRequest: Codable, Equatable, Sendable {
    let command: String
    let arguments: [String]
    let workingDirectory: String?
    let environmentProfile: BrokerEnvironmentProfile
    let initialSize: TerminalGridSize

    init(
        command: String,
        arguments: [String] = [],
        workingDirectory: String?,
        environmentProfile: BrokerEnvironmentProfile,
        initialSize: TerminalGridSize
    ) {
        precondition(!command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Broker launch command cannot be empty")
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentProfile = environmentProfile
        self.initialSize = initialSize
    }
}

/// Durable registry record for a broker-owned PTY session.
struct BrokerSessionRecord: Codable, Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case exitedSessionMissingExitCode
        case liveSessionHasExitCode
    }

    let id: BrokerSessionID
    let channelType: ChannelType
    let label: String?
    let command: String
    let arguments: [String]
    let workingDirectory: String?
    let environmentProfile: BrokerEnvironmentProfile
    let lifecycle: BrokerSessionLifecycle
    let exitCode: Int32?
    let createdAt: Date
    let updatedAt: Date
    let lastAttachedChannelID: UUID?

    func validate() throws {
        if lifecycle == .exited && exitCode == nil {
            throw ValidationError.exitedSessionMissingExitCode
        }
        if lifecycle != .exited && exitCode != nil {
            throw ValidationError.liveSessionHasExitCode
        }
    }
}
