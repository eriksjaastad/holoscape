import XCTest
import QuartzCore
@testable import Holoscape

/// Chrome v4 Task 19.4 — ParticleLayerRenderer invariants (Req 6).
///
/// Pins:
/// - Installs a CAEmitterLayer as the root layer.
/// - Maps ParticleParams fields to CAEmitterCell properties.
/// - Soft-dot fallback when params.image == nil.
/// - compositingFilter applied for additive / screen blend modes.
/// - pause zeroes birthRate; resume restores it.
@MainActor
final class ParticleLayerRendererTests: XCTestCase {

    private func makeParams(
        birthRate: Double = 10,
        blendMode: ParticleParams.BlendMode? = nil
    ) -> ParticleParams {
        ParticleParams(
            birthRate: birthRate,
            lifetime: 2.0,
            lifetimeRange: 0.5,
            velocity: 20,
            velocityRange: 5,
            emissionAngle: 1.57,
            emissionRange: 3.14,
            color: "#ffaa33ff",
            colorRange: nil,
            scale: 0.5,
            scaleRange: 0.1,
            image: nil,
            blendMode: blendMode
        )
    }

    // MARK: - Layer type

    func testRootLayerIsCAEmitterLayer() {
        let renderer = ParticleLayerRenderer(
            id: "test",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams()
        )
        XCTAssertTrue(renderer.layer is CAEmitterLayer,
            "Root layer must be CAEmitterLayer (Req 6.1)")
    }

    func testIDAndZPreserved() {
        let renderer = ParticleLayerRenderer(
            id: "my-particle",
            z: 3,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams()
        )
        XCTAssertEqual(renderer.id, "my-particle")
        XCTAssertEqual(renderer.z, 3)
    }

    // MARK: - Install

    func testInstallAddsLayerToParentAtRectFrame() {
        let parent = CALayer()
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 2,
            rect: SkinRect(x: 50, y: 60, width: 200, height: 100),
            params: makeParams()
        )
        renderer.install(in: parent)
        XCTAssertTrue(parent.sublayers?.contains(renderer.layer) ?? false,
            "Install must add the layer as a sublayer of parent")
        XCTAssertEqual(renderer.layer.frame,
            NSRect(x: 50, y: 60, width: 200, height: 100),
            "Layer frame must match SkinRect")
    }

    // MARK: - Param mapping (Req 6.2)

    func testParamsMappedToEmitterCell() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(birthRate: 42)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        let cell = emitter.emitterCells!.first!
        XCTAssertEqual(cell.birthRate, 42, accuracy: 0.001)
        XCTAssertEqual(cell.lifetime, 2.0, accuracy: 0.001)
        XCTAssertEqual(cell.lifetimeRange, 0.5, accuracy: 0.001)
        XCTAssertEqual(cell.velocity, 20, accuracy: 0.001)
        XCTAssertEqual(cell.velocityRange, 5, accuracy: 0.001)
        XCTAssertEqual(cell.scale, 0.5, accuracy: 0.001)
    }

    // MARK: - Soft dot fallback (Req 6.3)

    func testSoftDotInstalledWhenImageNil() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams()  // image: nil
        )
        let emitter = renderer.layer as! CAEmitterLayer
        let cell = emitter.emitterCells!.first!
        XCTAssertNotNil(cell.contents,
            "Procedurally-generated soft dot must fill cell.contents when params.image is nil (Req 6.3)")
    }

    // MARK: - Blend modes (Req 6.4)

    func testAdditiveBlendModeSetsCompositingFilter() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(blendMode: .additive)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        let cell = emitter.emitterCells!.first!
        let filter = cell.value(forKey: "compositingFilter") as? String
        XCTAssertEqual(filter, "plusL",
            "additive blend must map to plusL compositingFilter (Req 6.4)")
    }

    func testScreenBlendModeSetsCompositingFilter() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(blendMode: .screen)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        let cell = emitter.emitterCells!.first!
        let filter = cell.value(forKey: "compositingFilter") as? String
        XCTAssertEqual(filter, "screenBlendMode")
    }

    func testNormalBlendModeLeavesCompositingFilterNil() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(blendMode: .normal)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        let cell = emitter.emitterCells!.first!
        XCTAssertNil(cell.value(forKey: "compositingFilter") as? String)
    }

    // MARK: - Pause / resume

    func testPauseZeroesBirthRate() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(birthRate: 50)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        XCTAssertEqual(emitter.emitterCells!.first!.birthRate, 50, accuracy: 0.001)

        renderer.pause()
        XCTAssertEqual(emitter.emitterCells!.first!.birthRate, 0, accuracy: 0.001,
            "pause must set birthRate = 0 so emitter stops spawning new particles")
    }

    func testResumeRestoresBirthRate() {
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams(birthRate: 30)
        )
        let emitter = renderer.layer as! CAEmitterLayer
        renderer.pause()
        renderer.resume()
        XCTAssertEqual(emitter.emitterCells!.first!.birthRate, 30, accuracy: 0.001,
            "resume must restore birthRate to the declared value")
    }

    // MARK: - Uninstall

    func testUninstallRemovesLayerFromParent() {
        let parent = CALayer()
        let renderer = ParticleLayerRenderer(
            id: "p",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: makeParams()
        )
        renderer.install(in: parent)
        renderer.uninstall()
        XCTAssertFalse(parent.sublayers?.contains(renderer.layer) ?? false,
            "uninstall must remove the layer from parent")
    }
}
