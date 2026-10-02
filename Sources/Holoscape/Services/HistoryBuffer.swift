import Foundation

/// Lightweight struct capturing a channel's name, type, and state for reports.
struct ChannelStateInfo: Codable, Sendable {
    let channelName: String
    let channelType: ChannelType
    let state: String
}

/// A timestamped command entry.
struct CommandEntry: Codable, Sendable {
    let command: String
    let channelName: String
    let timestamp: Date
}

/// A timestamped channel switch event.
struct ChannelSwitchEntry: Codable, Sendable {
    let fromChannel: String?
    let toChannel: String
    let timestamp: Date
}

/// A timestamped settings change event.
struct SettingsChangeEntry: Codable, Sendable {
    let setting: String
    let oldValue: String
    let newValue: String
    let timestamp: Date
}

/// A timestamped error event.
struct ErrorEntry: Codable, Sendable {
    let message: String
    let context: String?
    let timestamp: Date
}

/// Snapshot of the history buffer for inclusion in reports.
struct HistorySnapshot: Codable, Sendable {
    let recentCommands: [CommandEntry]
    let recentChannelSwitches: [ChannelSwitchEntry]
    let recentSettingsChanges: [SettingsChangeEntry]
    let recentErrors: [ErrorEntry]
    let capturedAt: Date
}

/// Rolling event buffer that runs in the background.
/// Captures commands, channel switches, settings changes, and errors.
/// Periodically flushed to disk for crash recovery.
@MainActor
final class HistoryBuffer {
    private var commands: [CommandEntry] = []
    private var channelSwitches: [ChannelSwitchEntry] = []
    private var settingsChanges: [SettingsChangeEntry] = []
    private var errors: [ErrorEntry] = []

    private let maxCommands = 20
    private let maxSwitches = 10
    private let maxSettingsChanges = 5
    private let maxErrors = 20

    private let persistURL: URL
    private var flushTimer: Timer?
    private var isDirty: Bool = false

    init(persistURL: URL? = nil, startsPeriodicFlush: Bool = true) {
        self.persistURL = persistURL ?? Self.defaultPersistURL
        if startsPeriodicFlush {
            startPeriodicFlush()
        }
    }

    private static var defaultPersistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".holoscape/history-buffer.json")
    }

    func stopPeriodicFlush() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    // MARK: - Recording Events

    func recordCommand(_ command: String, channelName: String) {
        let entry = CommandEntry(command: command, channelName: channelName, timestamp: Date())
        commands.append(entry)
        if commands.count > maxCommands {
            commands.removeFirst(commands.count - maxCommands)
        }
        isDirty = true
    }

    func recordChannelSwitch(from: String?, to: String) {
        let entry = ChannelSwitchEntry(fromChannel: from, toChannel: to, timestamp: Date())
        channelSwitches.append(entry)
        if channelSwitches.count > maxSwitches {
            channelSwitches.removeFirst(channelSwitches.count - maxSwitches)
        }
        isDirty = true
    }

    func recordSettingsChange(setting: String, oldValue: String, newValue: String) {
        let entry = SettingsChangeEntry(setting: setting, oldValue: oldValue, newValue: newValue, timestamp: Date())
        settingsChanges.append(entry)
        if settingsChanges.count > maxSettingsChanges {
            settingsChanges.removeFirst(settingsChanges.count - maxSettingsChanges)
        }
        isDirty = true
    }

    func recordError(_ message: String, context: String? = nil) {
        let entry = ErrorEntry(message: message, context: context, timestamp: Date())
        errors.append(entry)
        if errors.count > maxErrors {
            errors.removeFirst(errors.count - maxErrors)
        }
        isDirty = true
    }

    // MARK: - Snapshot

    func snapshot() -> HistorySnapshot {
        HistorySnapshot(
            recentCommands: commands,
            recentChannelSwitches: channelSwitches,
            recentSettingsChanges: settingsChanges,
            recentErrors: errors,
            capturedAt: Date()
        )
    }

    // MARK: - Persistence

    @discardableResult
    func flush() -> Result<Void, Error> {
        guard isDirty else { return .success(()) }
        let snap = snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: persistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snap)
            try data.write(to: persistURL, options: .atomic)
            isDirty = false
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Load the last persisted snapshot (for crash recovery).
    static func loadPersistedSnapshot(from url: URL? = nil) -> HistorySnapshot? {
        let url = url ?? defaultPersistURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HistorySnapshot.self, from: data)
    }

    private func startPeriodicFlush() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let result = self?.flush() else { return }
                if case let .failure(error) = result {
                    NSLog("HistoryBuffer flush failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
