import XCTest
@testable import Holoscape

/// Functional tests for `ShaderCompiler` — the GLSL→SPIR-V→MSL service from
/// card 4 of the shader pipeline (#5941 under #5930). These complement the
/// link smoke test in `ShaderCompilerBridgeTests.swift`.
@MainActor
final class ShaderCompilerTests: XCTestCase {

    func testHappyPathCompilesTrivialShader() throws {
        let path = try writeTempShader("""
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = vec4(1.0);
        }
        """)
        let result = try ShaderCompiler().compile(glslPath: path)
        XCTAssertFalse(result.mslSource.isEmpty,
                       "Compiled MSL source should not be empty")
        XCTAssertTrue(
            result.mslSource.contains("iAgentState"),
            "MSL output should contain the iAgentState uniform declaration " +
            "from the Holoscape shader prefix")
    }

    func testSyntaxErrorThrowsParseFailure() throws {
        let path = try writeTempShader("void mainImage() { !!! garbage }")
        do {
            _ = try ShaderCompiler().compile(glslPath: path)
            XCTFail("Expected ShaderCompileError.parseFailure")
        } catch let error as ShaderCompileError {
            switch error {
            case .preprocessFailure(let log), .parseFailure(let log):
                XCTAssertFalse(
                    log.isEmpty,
                    "glslang failure log should not be empty for a broken " +
                    "shader")
            default:
                XCTFail("Expected .preprocessFailure or .parseFailure, " +
                        "got \(error)")
            }
        }
    }

    func testPrefixIsPrependedAndExtensionUniformsAreVisible() throws {
        // Reference the extension uniform directly — if the prefix weren't
        // prepended, `iAgentState` would be an undeclared identifier and
        // glslang_shader_parse would return 0.
        let path = try writeTempShader("""
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = vec4(float(iAgentState), 0.0, 0.0, 1.0);
        }
        """)
        let result = try ShaderCompiler().compile(glslPath: path)
        XCTAssertTrue(
            result.mslSource.contains("iAgentState"),
            "MSL output should reference iAgentState through the Globals UBO")
    }

    // MARK: - Helpers

    private func writeTempShader(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shader_\(UUID().uuidString).glsl")
        try source.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
