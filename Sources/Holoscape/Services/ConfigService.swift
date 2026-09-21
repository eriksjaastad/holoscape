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

    /// In-memory cache — avoids disk reads on every load().
    private var cachedConfig: HoloscapeConfig?
    private(set) var lastDiagnostic: ConfigServiceDiagnostic?

    init() {
        // Allow UI tests to isolate config in a per-test directory by setting
        // HOLOSCAPE_CONFIG_DIR in launchEnvironment. Without this override,
        // every test shares ~/.holoscape/config.json, which forces the save
        // guard in applicationWillTerminate / scheduleSaveState to skip
        // persistence under --ui-testing to avoid cross-test pollution —
        // which in turn breaks restart/persistence tests.
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            self.configDir = URL(fileURLWithPath: override)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.configDir = home.appendingPathComponent(".holoscape")
        }
        self.configURL = configDir.appendingPathComponent("config.json")
    }

    /// Test-only init that injects the config directory directly. Avoids the
    /// setenv/unsetenv pattern, which is a process-global mutation unsafe
    /// under parallel XCTest execution.
    init(configDir: URL) {
        self.configDir = configDir
        self.configURL = configDir.appendingPathComponent("config.json")
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

    func save(_ config: HoloscapeConfig) {
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            cachedConfig = config
            lastDiagnostic = nil
        } catch {
            recordDiagnostic(operation: .save, error: error)
        }
    }

    private func ensureDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: configDir.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: configDir.path])
            }
            return
        }
        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true
        )
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
