import XCTest
@testable import Holoscape

final class ConfigServiceTests: XCTestCase {
    func testConfigSerializationRoundTrip() throws {
        let config = HoloscapeConfig(
            appearance: AppearanceConfig(
                backgroundColor: "#ff0000",
                transparency: 0.8,
                fontFamily: "Menlo",
                fontSize: 14.0,
                ansiColors: ["red": "#ff0000"]
            ),
            channels: [
                ChannelMetadata(
                    id: UUID(),
                    type: .shell,
                    role: "Shell",
                    context: nil,
                    instanceNumber: 1,
                    workingDirectory: "/tmp"
                ),
            ],
            lastLaunchTimestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(decoded.appearance.backgroundColor, config.appearance.backgroundColor)
        XCTAssertEqual(decoded.appearance.transparency, config.appearance.transparency)
        XCTAssertEqual(decoded.appearance.fontFamily, config.appearance.fontFamily)
        XCTAssertEqual(decoded.channels.count, config.channels.count)
        XCTAssertEqual(decoded.channels.first?.type, .shell)
    }

    func testMalformedConfigFallsBackToDefaults() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let malformed = "{ not valid json !!!".data(using: .utf8)!
        let result = try? decoder.decode(HoloscapeConfig.self, from: malformed)
        XCTAssertNil(result, "Malformed JSON should not decode successfully")
    }

    func testMalformedConfigRecordsDiagnosticWithoutOverwritingFile() throws {
        let configDir = temporaryConfigDir()
        let configURL = configDir.appendingPathComponent("config.json")
        let malformed = "{ not valid json !!!"
        try malformed.write(to: configURL, atomically: true, encoding: .utf8)
        let service = ConfigService(configDir: configDir)

        let loaded = service.load()

        XCTAssertEqual(loaded, HoloscapeConfig.default)
        XCTAssertEqual(service.lastDiagnostic?.operation, .load)
        XCTAssertEqual(service.lastDiagnostic?.configPath, configURL.path)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), malformed)
    }

    func testFailedSaveDoesNotPoisonLoadCacheWithUnsavedConfig() throws {
        let tempRoot = temporaryConfigDir()
        let configDir = tempRoot.appendingPathComponent("not-a-directory")
        try "blocking file".write(to: configDir, atomically: true, encoding: .utf8)
        let service = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Unsaved Font"

        service.save(config)
        let loaded = service.load()

        XCTAssertEqual(service.lastDiagnostic?.operation, .load)
        XCTAssertEqual(loaded.appearance.fontFamily, HoloscapeConfig.default.appearance.fontFamily)
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigServiceTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
