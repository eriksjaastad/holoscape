import XCTest
@testable import Holoscape

final class ModelCodableTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - ChannelMetadata

    func testChannelMetadataRoundTrip() throws {
        let original = ChannelMetadata(
            id: UUID(),
            type: .agentDirect,
            role: "Floor Manager",
            context: "some context",
            instanceNumber: 3,
            workingDirectory: "/Users/test/projects/foo"
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChannelMetadata.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testChannelMetadataWithNilOptionals() throws {
        let original = ChannelMetadata(
            id: UUID(),
            type: .shell,
            role: "Shell",
            context: nil,
            instanceNumber: nil,
            workingDirectory: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ChannelMetadata.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.instanceNumber)
        XCTAssertNil(decoded.workingDirectory)
    }

    func testChannelMetadataAllChannelTypes() throws {
        let types: [ChannelType] = [.shell, .agentDirect, .agentAPI, .groupChat]

        for type in types {
            let original = ChannelMetadata(
                id: UUID(), type: type, role: "Test",
                context: nil, instanceNumber: nil, workingDirectory: nil
            )
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(ChannelMetadata.self, from: data)
            XCTAssertEqual(decoded.type, type, "Round trip failed for \(type)")
        }
    }

    // MARK: - HoloscapeConfig

    func testHoloscapeConfigRoundTrip() throws {
        let original = HoloscapeConfig(
            appearance: AppearanceConfig(
                backgroundColor: "#1a1a2e",
                transparency: 0.85,
                fontFamily: "Menlo",
                fontSize: 14.0,
                ansiColors: ["red": "#ff0000", "green": "#00ff00"]
            ),
            channels: [
                ChannelMetadata(id: UUID(), type: .shell, role: "Shell", context: nil, instanceNumber: 1, workingDirectory: "/tmp"),
                ChannelMetadata(id: UUID(), type: .agentDirect, role: "Agent", context: "ctx", instanceNumber: nil, workingDirectory: nil),
            ],
            lastLaunchTimestamp: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testHoloscapeConfigDefaultValues() throws {
        let config = HoloscapeConfig.default

        XCTAssertEqual(config.appearance.backgroundColor, "#1a1a2e")
        XCTAssertEqual(config.appearance.transparency, 1.0)
        XCTAssertEqual(config.appearance.fontFamily, "SF Mono")
        XCTAssertEqual(config.appearance.fontSize, 13.0)
        XCTAssertNil(config.appearance.ansiColors)
        XCTAssertTrue(config.channels.isEmpty)
        XCTAssertNil(config.lastLaunchTimestamp)
    }

    func testHoloscapeConfigDefaultRoundTrip() throws {
        let original = HoloscapeConfig.default
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - AppearanceConfig

    func testAppearanceConfigWithAnsiColors() throws {
        let original = AppearanceConfig(
            backgroundColor: "#000000",
            transparency: 0.5,
            fontFamily: "Courier",
            fontSize: 12.0,
            ansiColors: [
                "black": "#000000",
                "red": "#ff0000",
                "green": "#00ff00",
                "yellow": "#ffff00",
                "blue": "#0000ff",
                "magenta": "#ff00ff",
                "cyan": "#00ffff",
                "white": "#ffffff",
            ]
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppearanceConfig.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.ansiColors?.count, 8)
    }

    func testAppearanceConfigWithoutAnsiColors() throws {
        let original = AppearanceConfig(
            backgroundColor: "#1a1a2e",
            transparency: 1.0,
            fontFamily: "SF Mono",
            fontSize: 13.0,
            ansiColors: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppearanceConfig.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.ansiColors)
    }

    // MARK: - BugReport

    func testBugReportRoundTrip() throws {
        let original = BugReport(
            channelName: "Shell 1",
            channelType: .shell,
            lastOutputLines: ["$ ls", "file1.txt", "file2.txt"],
            timestamp: Date(timeIntervalSince1970: 1700000000),
            macOSVersion: "15.0",
            description: "Terminal stops responding after typing one character",
            appVersion: nil,
            hardwareModel: nil,
            allChannelStates: nil,
            appearanceConfig: nil,
            splitLayout: nil,
            uptime: nil,
            historyBuffer: nil,
            screenshotData: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BugReport.self, from: data)

        XCTAssertEqual(decoded.channelName, original.channelName)
        XCTAssertEqual(decoded.channelType, original.channelType)
        XCTAssertEqual(decoded.lastOutputLines, original.lastOutputLines)
        XCTAssertEqual(decoded.description, original.description)
        XCTAssertEqual(decoded.macOSVersion, original.macOSVersion)
    }

    func testBugReportEmptyOutputLines() throws {
        let original = BugReport(
            channelName: "Agent",
            channelType: .agentDirect,
            lastOutputLines: [],
            timestamp: Date(),
            macOSVersion: "15.0",
            description: "No output",
            appVersion: nil,
            hardwareModel: nil,
            allChannelStates: nil,
            appearanceConfig: nil,
            splitLayout: nil,
            uptime: nil,
            historyBuffer: nil,
            screenshotData: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BugReport.self, from: data)

        XCTAssertTrue(decoded.lastOutputLines.isEmpty)
    }

    // MARK: - CrashReport

    func testCrashReportRoundTrip() throws {
        let original = CrashReport(
            crashTrace: "Exception Type: EXC_BAD_ACCESS\nThread 0 Crashed",
            lastChannelState: [
                ChannelMetadata(id: UUID(), type: .shell, role: "Shell", context: nil, instanceNumber: 1, workingDirectory: nil)
            ],
            timestamp: Date(timeIntervalSince1970: 1700000000),
            macOSVersion: "15.0",
            appVersion: nil,
            hardwareModel: nil,
            historySnapshot: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CrashReport.self, from: data)

        XCTAssertEqual(decoded.crashTrace, original.crashTrace)
        XCTAssertEqual(decoded.lastChannelState?.count, 1)
        XCTAssertEqual(decoded.macOSVersion, original.macOSVersion)
    }

    func testCrashReportWithNilChannelState() throws {
        let original = CrashReport(
            crashTrace: "crash trace here",
            lastChannelState: nil,
            timestamp: Date(),
            macOSVersion: "15.0",
            appVersion: nil,
            hardwareModel: nil,
            historySnapshot: nil
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CrashReport.self, from: data)

        XCTAssertNil(decoded.lastChannelState)
    }

    // MARK: - ChannelType

    func testChannelTypeRawValues() {
        XCTAssertEqual(ChannelType.shell.rawValue, "shell")
        XCTAssertEqual(ChannelType.agentDirect.rawValue, "agentDirect")
        XCTAssertEqual(ChannelType.agentAPI.rawValue, "agentAPI")
        XCTAssertEqual(ChannelType.groupChat.rawValue, "groupChat")
    }

    func testChannelTypeFromRawValue() {
        XCTAssertEqual(ChannelType(rawValue: "shell"), .shell)
        XCTAssertEqual(ChannelType(rawValue: "agentDirect"), .agentDirect)
        XCTAssertEqual(ChannelType(rawValue: "agentAPI"), .agentAPI)
        XCTAssertEqual(ChannelType(rawValue: "groupChat"), .groupChat)
        XCTAssertNil(ChannelType(rawValue: "invalid"))
    }

    // MARK: - ChannelState

    func testChannelStateRawValues() {
        XCTAssertEqual(ChannelState.active.rawValue, "active")
        XCTAssertEqual(ChannelState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(ChannelState.connecting.rawValue, "connecting")
    }

    // MARK: - GroupChatMessage

    func testGroupChatMessageRoundTrip() throws {
        let original = GroupChatMessage(
            sender: "erik",
            body: "hello world",
            timestamp: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(GroupChatMessage.self, from: data)

        XCTAssertEqual(decoded.sender, original.sender)
        XCTAssertEqual(decoded.body, original.body)
    }

    func testGroupChatMessageFormatted() {
        let date = Date(timeIntervalSince1970: 1700000000) // Nov 14, 2023
        let msg = GroupChatMessage(sender: "erik", body: "test message", timestamp: date)
        let formatted = msg.formatted()

        XCTAssertTrue(formatted.contains("erik"), "Should contain sender")
        XCTAssertTrue(formatted.contains("test message"), "Should contain body")
        XCTAssertTrue(formatted.hasPrefix("["), "Should start with timestamp bracket")
        XCTAssertTrue(formatted.contains("]"), "Should have closing bracket")
    }

    func testGroupChatMessageFormattedStructure() {
        let msg = GroupChatMessage(
            sender: "bot",
            body: "response",
            timestamp: Date()
        )
        let formatted = msg.formatted()

        // Expected format: [h:mm a] sender: body
        let regex = try! NSRegularExpression(pattern: #"^\[\d{1,2}:\d{2} [AP]M\] bot: response$"#)
        let range = NSRange(formatted.startIndex..., in: formatted)
        XCTAssertNotNil(regex.firstMatch(in: formatted, range: range), "Format should be [h:mm AM/PM] sender: body, got: \(formatted)")
    }

    // MARK: - BugReportResponse

    func testBugReportResponseRoundTrip() throws {
        let original = BugReportResponse(success: true, message: "Report received")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BugReportResponse.self, from: data)

        XCTAssertEqual(decoded.success, true)
        XCTAssertEqual(decoded.message, "Report received")
    }

    func testBugReportResponseWithNilMessage() throws {
        let original = BugReportResponse(success: false, message: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(BugReportResponse.self, from: data)

        XCTAssertEqual(decoded.success, false)
        XCTAssertNil(decoded.message)
    }
}
