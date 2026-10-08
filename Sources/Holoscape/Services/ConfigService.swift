import Foundation

struct ConfigServiceDiagnostic: Equatable, Sendable {
    enum Operation: String, Sendable {
        case load
        case save
    }

    let operation: Operation
    let configPath: String
    let message: String
}

class ConfigService {
    private let configDir: URL
    private let configURL: URL
    private let persistence: DurableAtomicFileCommitter.Persistence

    /// In-memory cache — avoids disk reads on every load().
    private var cachedConfig: HoloscapeConfig?
    /// Identity of the directory whose parent linkage was last established.
    /// Path equality is insufficient because deletion and recreation can occur
    /// entirely between two saves.
    private var durableDirectoryIdentity: DurableDirectoryIdentity?
    private(set) var lastDiagnostic: ConfigServiceDiagnostic?

    init() {
        // Allow UI tests to isolate config in a per-test directory by setting
        // HOLOSCAPE_CONFIG_DIR in launchEnvironment. Without this override,
        // every test shares ~/.holoscape/config.json, which forces the save
        // guard in applicationWillTerminate / scheduleSaveState to skip
        // persistence under --ui-testing to avoid cross-test pollution —
        // which in turn breaks restart/persistence tests.
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            self.configDir = URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.configDir = home.appendingPathComponent(".holoscape").standardizedFileURL.resolvingSymlinksInPath()
        }
        self.configURL = configDir.appendingPathComponent("config.json")
        self.persistence = .live
    }

    /// Test-only init that injects the config directory directly. Avoids the
    /// setenv/unsetenv pattern, which is a process-global mutation unsafe
    /// under parallel XCTest execution.
    init(
        configDir: URL,
        persistence: DurableAtomicFileCommitter.Persistence = .live,
        assumeExistingDirectoryIsDurable: Bool = true
    ) {
        let canonicalConfigDir = configDir.standardizedFileURL.resolvingSymlinksInPath()
        self.configDir = canonicalConfigDir
        self.configURL = canonicalConfigDir.appendingPathComponent("config.json")
        self.persistence = persistence
        // Callers of this test-only initializer own fixture-directory setup.
        // Treat an already-present fixture root as established so the suite
        // does not issue real F_FULLFSYNC calls for every isolated test path.
        if assumeExistingDirectoryIsDurable {
            self.durableDirectoryIdentity = try? DurableDirectoryIdentity.read(at: canonicalConfigDir)
        }
    }

    func load() -> HoloscapeConfig {
        if let cached = cachedConfig {
            return cached
        }
        do {
            try ensureDirectoryExists()
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                let defaultConfig = HoloscapeConfig.default
                save(defaultConfig)
                return defaultConfig
            }
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let config = try decoder.decode(HoloscapeConfig.self, from: data)
            cachedConfig = config
            lastDiagnostic = nil
            return config
        } catch {
            recordDiagnostic(operation: .load, error: error)
            return HoloscapeConfig.default
        }
    }

    @discardableResult
    func save(_ config: HoloscapeConfig) -> Bool {
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let committedConfig = try decoder.decode(HoloscapeConfig.self, from: data)
            do {
                try DurableAtomicFileCommitter(persistence: persistence).commit(
                    data,
                    to: configURL,
                    directoryIdentity: durableDirectoryIdentity
                )
            } catch let error as DurableAtomicFileCommitter.CommitError {
                if case .replacementCommitted = error {
                    // The new file is already visible. Preserve that truth in
                    // memory even though its crash durability is uncertain.
                    cachedConfig = committedConfig
                }
                throw error
            }
            cachedConfig = committedConfig
            lastDiagnostic = nil
            return true
        } catch {
            recordDiagnostic(operation: .save, error: error)
            return false
        }
    }

    private func ensureDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: configDir.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: configDir.path])
            }
            let currentIdentity = try DurableDirectoryIdentity.read(at: configDir)
            if durableDirectoryIdentity == currentIdentity {
                durableDirectoryIdentity = currentIdentity
                return
            }
        }
        var missingDirectories: [URL] = []
        var candidate = configDir
        while !FileManager.default.fileExists(atPath: candidate.path) {
            missingDirectories.append(candidate)
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: candidate.path])
            }
            candidate = parent
        }

        for directory in missingDirectories.reversed() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        let currentIdentity = try DurableDirectoryIdentity.read(at: configDir)
        let needsDurabilityInitialization = !missingDirectories.isEmpty
            || durableDirectoryIdentity != currentIdentity
        let directoriesToSynchronize = needsDurabilityInitialization
            ? Self.directoryEntryParents(endingAt: configDir)
            : missingDirectories.reversed().map { $0.deletingLastPathComponent() }
        for directory in directoriesToSynchronize {
            try persistence.synchronizeDirectory(directory)
        }
        durableDirectoryIdentity = currentIdentity
    }

    /// Synchronize the full ancestry until one complete pass succeeds. This
    /// repairs a prior attempt that created directories but failed before their
    /// entries became durable, including retries by a fresh ConfigService.
    private static func directoryEntryParents(endingAt directoryURL: URL) -> [URL] {
        let components = directoryURL.standardizedFileURL.pathComponents
        guard components.first == "/", components.count > 1 else { return [] }

        var result = [URL(fileURLWithPath: "/", isDirectory: true)]
        var parent = result[0]
        for component in components.dropFirst().dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            result.append(parent)
        }
        return result
    }

    private func recordDiagnostic(operation: ConfigServiceDiagnostic.Operation, error: Error) {
        let diagnostic = ConfigServiceDiagnostic(
            operation: operation,
            configPath: configURL.path,
            message: error.localizedDescription
        )
        lastDiagnostic = diagnostic
        NSLog("ConfigService: \(operation.rawValue) failed for \(diagnostic.configPath): \(diagnostic.message)")
    }
}
