import XCTest
@testable import Holoscape

final class SkinLayoutDescriptorTests: XCTestCase {

    func testSkinDefinitionDecodesVesselLayoutBlock() throws {
        let json = """
        {
          "version": "4.0",
          "name": "Vessel Skin",
          "layout": {
            "channelVessel": {
              "dock": "left",
              "size": 248,
              "capStart": 96,
              "capEnd": 56,
              "variant": "mercuryControlSpine"
            },
            "screenVessel": {
              "viewportInsets": { "top": 12, "right": 14, "bottom": 14, "left": 12 },
              "variant": "mercuryScreenBody"
            },
            "seam": { "thickness": 20, "style": "mechanical" }
          }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        let layout = try XCTUnwrap(skin.layout)
        let channel = try XCTUnwrap(layout.channelVessel)
        let screen = try XCTUnwrap(layout.screenVessel)
        let seam = try XCTUnwrap(layout.seam)

        XCTAssertEqual(channel.dock, .left)
        XCTAssertEqual(channel.size, 248)
        XCTAssertEqual(channel.capStart, 96)
        XCTAssertEqual(channel.capEnd, 56)
        XCTAssertEqual(channel.variant, .mercuryControlSpine)
        XCTAssertEqual(screen.viewportInsets, SkinLayoutInsets(top: 12, right: 14, bottom: 14, left: 12))
        XCTAssertEqual(screen.variant, .mercuryScreenBody)
        XCTAssertEqual(seam.thickness, 20)
        XCTAssertEqual(seam.style, .mechanical)
    }

    func testUnsupportedDockDecodesWithoutFailingManifest() throws {
        let json = """
        {
          "layout": {
            "channelVessel": { "dock": "right", "size": 240, "capStart": 64, "capEnd": 40 },
            "screenVessel": {
              "viewportInsets": { "top": 6, "right": 6, "bottom": 6, "left": 6 }
            },
            "seam": { "thickness": 10, "style": "flat" }
          }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        guard case .unsupported("right") = skin.layout?.channelVessel?.dock else {
            return XCTFail("Unknown dock values must decode as unsupported instead of failing the full manifest")
        }
    }

    func testUnsupportedVariantsDecodeWithoutFailingManifest() throws {
        let json = """
        {
          "layout": {
            "channelVessel": {
              "dock": "left",
              "size": 248,
              "capStart": 96,
              "capEnd": 56,
              "variant": "heroSpine"
            },
            "screenVessel": {
              "viewportInsets": { "top": 12, "right": 14, "bottom": 14, "left": 12 },
              "variant": "heroScreen"
            },
            "seam": { "thickness": 20, "style": "mechanical" }
          }
        }
        """.data(using: .utf8)!

        let skin = try JSONDecoder().decode(SkinDefinition.self, from: json)
        guard case .unsupported("heroSpine") = skin.layout?.channelVessel?.variant else {
            return XCTFail("Unknown channel vessel variants must decode as unsupported")
        }
        guard case .unsupported("heroScreen") = skin.layout?.screenVessel?.variant else {
            return XCTFail("Unknown screen vessel variants must decode as unsupported")
        }
    }
}
