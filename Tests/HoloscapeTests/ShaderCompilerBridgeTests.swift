import XCTest
import Cspirv_cross
import Cglslang

/// Link smoke tests for the vendored C libraries behind the shader pipeline
/// (#5930). Each test proves the corresponding library imports from Swift and
/// its C API is callable. Shader compilation logic lives in card 4 (#5941).
final class ShaderCompilerBridgeTests: XCTestCase {
    func testSpirvCrossContextCreateAndDestroy() {
        var ctx: spvc_context? = nil
        let result = spvc_context_create(&ctx)
        XCTAssertEqual(result, SPVC_SUCCESS, "spvc_context_create should succeed")
        XCTAssertNotNil(ctx, "spvc_context_create should populate the context handle")
        spvc_context_destroy(ctx)
    }

    func testGlslangInitializeAndFinalize() {
        let initialized = glslang_initialize_process()
        XCTAssertEqual(initialized, 1, "glslang_initialize_process should return nonzero")
        glslang_finalize_process()
    }
}
