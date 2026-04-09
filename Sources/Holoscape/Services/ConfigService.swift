import Foundation

class ConfigService {
    private let configDir: URL
    private let configURL: URL

    /// In-memory cache — avoids disk reads on every load().
    private var cachedConfig: HoloscapeConfig?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".holoscape")
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
            return config
        } catch {
            NSLog("ConfigService: Failed to load config (\(error)). Using defaults.")
            let defaultConfig = HoloscapeConfig.default
            save(defaultConfig)
            return defaultConfig
        }
    }

    func save(_ config: HoloscapeConfig) {
        cachedConfig = config
        do {
            try ensureDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("ConfigService: Failed to save config: \(error)")
        }
    }

    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: configDir.path) {
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true
            )
        }
    }
}
