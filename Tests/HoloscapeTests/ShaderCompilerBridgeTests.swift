import XCTest
import Cspirv_cross

/// Link smoke test for the vendored spirv-cross C library (card 2 of #5930).
/// Proves Cspirv_cross imports from Swift and its C API is callable. Does not
/// exercise any shader compilation logic — that lives in card 4 (#5941).
final class ShaderCompilerBridgeTests: XCTestCase {
    func testSpirvCrossContextCreateAndDestroy() {
        var ctx: spvc_context? = nil
        let result = spvc_context_create(&ctx)
        XCTAssertEqual(result, SPVC_SUCCESS, "spvc_context_create should succeed")
        XCTAssertNotNil(ctx, "spvc_context_create should populate the context handle")
        spvc_context_destroy(ctx)
    }
}
