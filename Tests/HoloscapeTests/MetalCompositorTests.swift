import XCTest
@testable import Holoscape

@MainActor
final class MetalCompositorTests: XCTestCase {

    func testGlobalsUBOLayoutTotalSize() {
        // The UBO must be large enough for all fields including iPalette[256]
        XCTAssertGreaterThanOrEqual(GlobalsUBOLayout.totalSize, 4556,
            "UBO must fit all fields through iTimeLastNotification")
        // Verify 16-byte alignment
        XCTAssertEqual(GlobalsUBOLayout.totalSize % 16, 0,
            "Total size must be 16-byte aligned")
    }

    func testGlobalsUBOFieldOrdering() {
        // Verify key fields are at increasing offsets
        XCTAssertLessThan(GlobalsUBOLayout.iResolution, GlobalsUBOLayout.iTime)
        XCTAssertLessThan(GlobalsUBOLayout.iTime, GlobalsUBOLayout.iFrame)
        XCTAssertLessThan(GlobalsUBOLayout.iFrame, GlobalsUBOLayout.iPalette)
        XCTAssertLessThan(GlobalsUBOLayout.iPalette, GlobalsUBOLayout.iBackgroundColor)
        XCTAssertLessThan(GlobalsUBOLayout.iBackgroundColor, GlobalsUBOLayout.iAgentState)
        XCTAssertLessThan(GlobalsUBOLayout.iAgentState, GlobalsUBOLayout.iTimeLastNotification)
    }

    func testGlobalsUBOPaletteSize() {
        // iPalette[256] in std140: each vec3 padded to 16 bytes = 4096 bytes
        let paletteEnd = GlobalsUBOLayout.iPalette + 256 * 16
        XCTAssertEqual(paletteEnd, GlobalsUBOLayout.iBackgroundColor,
            "iPalette must be followed immediately by iBackgroundColor")
    }

    func testIdentityShaderCompiles() throws {
        guard let url = Bundle.module.url(forResource: "identity", withExtension: "glsl") else {
            XCTFail("identity.glsl not found in bundle")
            return
        }
        let compiler = ShaderCompiler()
        let compiled = try compiler.compile(glslPath: url)
        XCTAssertFalse(compiled.mslSource.isEmpty, "MSL output should not be empty")
        XCTAssertTrue(compiled.mslSource.contains("main0"),
            "spirv-cross should name the entry point main0")
    }

    func testMetalCompositorInitWithIdentityShader() throws {
        guard let url = Bundle.module.url(forResource: "identity", withExtension: "glsl") else {
            XCTFail("identity.glsl not found in bundle")
            return
        }
        let compiler = ShaderCompiler()
        let compiled = try compiler.compile(glslPath: url)

        // Create a dummy source view (offscreen, no window)
        let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        sourceView.wantsLayer = true
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        hostView.wantsLayer = true

        // This tests that the Metal pipeline compiles and the compositor initializes
        // without error. It won't render (no window/display link) but proves the
        // shader → MSL → MTLLibrary → MTLRenderPipelineState path works.
        let compositor = try MetalCompositor(
            compiledShader: compiled,
            sourceView: sourceView,
            hostView: hostView
        )
        // If we got here, init succeeded — pipeline state was created
        XCTAssertNotNil(compositor)
    }
}
