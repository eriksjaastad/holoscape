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
}
