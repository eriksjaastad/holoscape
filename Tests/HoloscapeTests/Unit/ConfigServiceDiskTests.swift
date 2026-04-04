import XCTest
@testable import Holoscape

final class ConfigServiceDiskTests: XCTestCase {
    func testLoadReturnsValidConfig() {
        let service = ConfigService()
        let config = service.load()

        // Should load without crashing and return a valid config
        // (may be defaults or a previously saved config)
        XCTAssertFalse(config.appearance.fontFamily.isEmpty)
        XCTAssertGreaterThan(config.appearance.fontSize, 0)
        XCTAssertGreaterThanOrEqual(config.appearance.transparency, 0)
        XCTAssertLessThanOrEqual(config.appearance.transparency, 1.0)
    }

    func testSaveAndLoadRoundTrip() {
        let service = ConfigService()

        var config = HoloscapeConfig.default
        config.appearance.fontFamily = "Menlo"
        config.appearance.fontSize = 16.0
        config.channels = [
            ChannelMetadata(
                id: UUID(),
                type: .agentDirect,
                role: "FM",
                context: nil,
                instanceNumber: 1,
                workingDirectory: "/tmp"
            )
        ]

        service.save(config)
        let loaded = service.load()

        XCTAssertEqual(loaded.appearance.fontFamily, "Menlo")
        XCTAssertEqual(loaded.appearance.fontSize, 16.0)
        XCTAssertEqual(loaded.channels.count, 1)
        XCTAssertEqual(loaded.channels.first?.role, "FM")
    }

    func testSaveOverwritesPreviousConfig() {
        let service = ConfigService()

        var config1 = HoloscapeConfig.default
        config1.appearance.fontFamily = "Courier"
        service.save(config1)

        var config2 = HoloscapeConfig.default
        config2.appearance.fontFamily = "Monaco"
        service.save(config2)

        let loaded = service.load()
        XCTAssertEqual(loaded.appearance.fontFamily, "Monaco")
    }

    func testSaveWithLastLaunchTimestamp() {
        let service = ConfigService()
        let now = Date()

        var config = HoloscapeConfig.default
        config.lastLaunchTimestamp = now
        service.save(config)

        let loaded = service.load()
        XCTAssertNotNil(loaded.lastLaunchTimestamp)
        // ISO8601 encoding loses sub-second precision
        XCTAssertEqual(
            Int(loaded.lastLaunchTimestamp!.timeIntervalSince1970),
            Int(now.timeIntervalSince1970)
        )
    }
}
