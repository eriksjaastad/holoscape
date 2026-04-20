import XCTest
import QuartzCore
@testable import Holoscape

/// Chrome v4 Task 23.5 — ShaderPresetLayerRenderer invariants (Req 9).
/// Pins preset rendering paths (glow/scanlines/noise) + pause.
@MainActor
final class ShaderPresetLayerRendererTests: XCTestCase {

    private let rect = SkinRect(x: 0, y: 650, width: 1000, height: 50)

    // MARK: - Preset construction

    func testGlowPresetBuilds() {
        let r = ShaderPresetLayerRenderer(
            id: "g", z: 1, rect: rect,
            params: ShaderParams(preset: .glow, color: "#4488ff", intensity: 0.3, hz: 0.5)
        )
        XCTAssertNotNil(r)
        XCTAssertNotNil(r?.layer.backgroundColor,
            "glow layer must install with a background color")
    }

    func testScanlinesPresetBuilds() {
        let r = ShaderPresetLayerRenderer(
            id: "s", z: 1, rect: rect,
            params: ShaderParams(preset: .scanlines, color: "#000000", intensity: 0.3, hz: 1)
        )
        XCTAssertNotNil(r)
        XCTAssertNotNil(r?.layer.contents,
            "scanlines layer must install with a striped contents image")
    }

    func testNoisePresetBuilds() {
        let r = ShaderPresetLayerRenderer(
            id: "n", z: 1, rect: rect,
            params: ShaderParams(preset: .noise, color: "#ffffff", intensity: 0.25, hz: 30)
        )
        XCTAssertNotNil(r)
        XCTAssertNotNil(r?.layer.contents)
    }

    // MARK: - Install

    func testInstallAddsLayerAtRectFrame() {
        let parent = CALayer()
        let r = ShaderPresetLayerRenderer(
            id: "g", z: 2, rect: SkinRect(x: 100, y: 200, width: 400, height: 50),
            params: ShaderParams(preset: .glow, color: "#ffffff", intensity: 0.5, hz: 1)
        )!
        r.install(in: parent)
        XCTAssertTrue(parent.sublayers?.contains(r.layer) ?? false)
        XCTAssertEqual(r.layer.frame, NSRect(x: 100, y: 200, width: 400, height: 50))
    }

    // MARK: - Tick mutations

    func testGlowTickMutatesOpacity() {
        let r = ShaderPresetLayerRenderer(
            id: "g", z: 1, rect: rect,
            params: ShaderParams(preset: .glow, color: "#ffffff", intensity: 1.0, hz: 1)
        )!
        r.tick(phaseSeconds: 0)
        let o1 = r.layer.opacity
        r.tick(phaseSeconds: 0.5)
        let o2 = r.layer.opacity
        XCTAssertNotEqual(o1, o2, "glow opacity must pulse over phase (Req 9.1)")
    }

    func testScanlinesTickScrollsContentsRect() {
        let r = ShaderPresetLayerRenderer(
            id: "s", z: 1, rect: rect,
            params: ShaderParams(preset: .scanlines, color: "#000000", intensity: 0.3, hz: 1)
        )!
        r.tick(phaseSeconds: 0)
        let rect1 = r.layer.contentsRect
        r.tick(phaseSeconds: 0.4)
        let rect2 = r.layer.contentsRect
        XCTAssertNotEqual(rect1.origin.y, rect2.origin.y,
            "scanlines contentsRect.y must advance over phase")
    }

    func testNoiseTickSwapsImage() {
        let r = ShaderPresetLayerRenderer(
            id: "n", z: 1, rect: rect,
            params: ShaderParams(preset: .noise, color: "#ffffff", intensity: 0.25, hz: 30)
        )!
        let initial = r.layer.contents
        r.tick(phaseSeconds: 0.5)  // 30 Hz * 0.5s = bucket 15
        let tickOne = r.layer.contents
        XCTAssertTrue(initial as AnyObject !== tickOne as AnyObject,
            "noise tick must swap contents to a new noise frame")
    }

    // MARK: - Pause

    func testPauseStopsTickMutation() {
        let r = ShaderPresetLayerRenderer(
            id: "g", z: 1, rect: rect,
            params: ShaderParams(preset: .glow, color: "#ffffff", intensity: 1.0, hz: 1)
        )!
        r.tick(phaseSeconds: 0)
        let pausedOpacity = r.layer.opacity
        r.pause()
        r.tick(phaseSeconds: 5)
        XCTAssertEqual(r.layer.opacity, pausedOpacity, accuracy: 0.001,
            "Paused tick must not mutate layer state")
        r.resume()
        r.tick(phaseSeconds: 5)
        XCTAssertNotNil(r.layer.opacity)
    }

    // MARK: - Z-order

    func testZPositionSetFromInit() {
        let r = ShaderPresetLayerRenderer(
            id: "g", z: 7, rect: rect,
            params: ShaderParams(preset: .glow, color: "#ffffff", intensity: 1.0, hz: 1)
        )!
        XCTAssertEqual(r.layer.zPosition, 7)
    }
}
