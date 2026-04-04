import XCTest
import SwiftCheck
@testable import Holoscape

final class ModelCodablePropertyTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testChannelMetadataRoundTripProperty() {
        property("Any ChannelMetadata survives encode/decode round trip") <- forAll(
            Gen<String>.fromElements(of: ["shell", "agentDirect", "agentAPI", "groupChat"]),
            String.arbitrary,
            Optional<String>.arbitrary,
            Optional<Int>.arbitrary
        ) { (typeRaw: String, role: String, context: String?, instanceNum: Int?) in
            let type = ChannelType(rawValue: typeRaw)!
            let original = ChannelMetadata(
                id: UUID(),
                type: type,
                role: role,
                context: context,
                instanceNumber: instanceNum,
                workingDirectory: nil
            )
            guard let data = try? self.encoder.encode(original),
                  let decoded = try? self.decoder.decode(ChannelMetadata.self, from: data) else {
                return false
            }
            return original == decoded
        }
    }

    func testAppearanceConfigRoundTripProperty() {
        property("Any AppearanceConfig survives encode/decode round trip") <- forAll(
            String.arbitrary,
            Double.arbitrary.suchThat { $0 >= 0 && $0 <= 1 },
            String.arbitrary,
            Double.arbitrary.suchThat { $0 > 0 && $0 < 200 }
        ) { (bg: String, transparency: Double, fontFamily: String, fontSize: Double) in
            let original = AppearanceConfig(
                backgroundColor: bg,
                transparency: transparency,
                fontFamily: fontFamily,
                fontSize: fontSize,
                ansiColors: nil
            )
            guard let data = try? self.encoder.encode(original),
                  let decoded = try? self.decoder.decode(AppearanceConfig.self, from: data) else {
                return false
            }
            return original == decoded
        }
    }

    func testChannelTypeAllCasesRoundTrip() {
        let types: [ChannelType] = [.shell, .agentDirect, .agentAPI, .groupChat]
        for type in types {
            let data = try! encoder.encode(type)
            let decoded = try! decoder.decode(ChannelType.self, from: data)
            XCTAssertEqual(type, decoded)
        }
    }

    func testChannelStateAllCasesRoundTrip() {
        let states: [ChannelState] = [.active, .disconnected, .connecting]
        for state in states {
            let data = try! encoder.encode(state)
            let decoded = try! decoder.decode(ChannelState.self, from: data)
            XCTAssertEqual(state, decoded)
        }
    }

    func testGroupChatMessageFormattedContainsSenderAndBody() {
        property("Formatted message always contains sender and body") <- forAll(
            String.arbitrary.suchThat { !$0.isEmpty },
            String.arbitrary.suchThat { !$0.isEmpty }
        ) { (sender: String, body: String) in
            let msg = GroupChatMessage(sender: sender, body: body, timestamp: Date())
            let formatted = msg.formatted()
            return formatted.contains(sender) && formatted.contains(body)
        }
    }
}
