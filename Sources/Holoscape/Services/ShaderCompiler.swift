import Foundation
import Cglslang
import Cspirv_cross

/// A compiled user shader, ready to hand to Metal in a later card.
struct CompiledShader {
    /// Metal Shading Language source text emitted by spirv-cross.
    let mslSource: String
}

/// Failure modes of `ShaderCompiler.compile(glslPath:)`. Each failing stage
/// attaches the log produced by glslang or spirv-cross so the caller can show
/// it to the shader author.
enum ShaderCompileError: Error {
    case prefixMissing
    case readFailure(path: String, underlying: Error)
    case preprocessFailure(log: String)
    case parseFailure(log: String)
    case linkFailure(log: String)
    case spirvGenerationFailed(log: String)
    case mslTranslationFailed(log: String)
}

/// Compiles a GLSL fragment shader to Metal Shading Language via
/// glslang → SPIR-V → spirv-cross. Mirrors Ghostty's shader pipeline from
/// `~/projects/github-repos/ghostty/src/renderer/shadertoy.zig`; target is
/// Vulkan 1.2 / SPIR-V 1.5 / GLSL 430.
///
/// The service prepends `holoscape_prefix.glsl` (the Ghostty shadertoy prefix
/// plus Holoscape's reactive-uniform extension block) to every user shader
/// before compilation. See `docs/skins/05-reactive-uniforms.md` and
/// `docs/skins/07-shader-pipeline-plan.md` for the design.
@MainActor
final class ShaderCompiler {
    // Safe without synchronization only while ShaderCompiler is @MainActor.
    // A future card that moves compile off-main must guard this latch with
    // a lock or replace it with dispatch_once-style initialization.
    private static var glslangInitialized = false

    init() {
        if !Self.glslangInitialized {
            _ = glslang_initialize_process()
            Self.glslangInitialized = true
        }
    }

    /// Compile a user GLSL fragment shader at `glslPath` and return its
    /// Metal Shading Language translation. Throws `ShaderCompileError` on
    /// any failure along the pipeline.
    func compile(glslPath: URL) throws -> CompiledShader {
        let combinedSource = try loadAndPrepend(glslPath: glslPath)
        let spirv = try runGlslang(source: combinedSource)
        return CompiledShader(mslSource: try runSpirvCross(spirv: spirv))
    }

    // MARK: - Stage 1: load prefix + user shader

    private func loadAndPrepend(glslPath: URL) throws -> String {
        guard let prefixURL = Bundle.module.url(
            forResource: "holoscape_prefix",
            withExtension: "glsl"
        ) else {
            throw ShaderCompileError.prefixMissing
        }
        let prefix: String
        do {
            prefix = try String(contentsOf: prefixURL, encoding: .utf8)
        } catch {
            throw ShaderCompileError.readFailure(
                path: prefixURL.path, underlying: error)
        }
        let user: String
        do {
            user = try String(contentsOf: glslPath, encoding: .utf8)
        } catch {
            throw ShaderCompileError.readFailure(
                path: glslPath.path, underlying: error)
        }
        return prefix + "\n" + user
    }

    // MARK: - Stage 2: GLSL → SPIR-V via glslang

    private func runGlslang(source: String) throws -> [UInt32] {
        return try source.withCString { sourcePtr -> [UInt32] in
            var input = makeGlslangInput(code: sourcePtr)

            guard let shader = glslang_shader_create(&input) else {
                throw ShaderCompileError.preprocessFailure(
                    log: "glslang_shader_create returned null")
            }
            defer { glslang_shader_delete(shader) }

            if glslang_shader_preprocess(shader, &input) == 0 {
                throw ShaderCompileError.preprocessFailure(
                    log: infoLog(shader))
            }
            if glslang_shader_parse(shader, &input) == 0 {
                throw ShaderCompileError.parseFailure(log: infoLog(shader))
            }

            guard let program = glslang_program_create() else {
                throw ShaderCompileError.linkFailure(
                    log: "glslang_program_create returned null")
            }
            defer { glslang_program_delete(program) }

            glslang_program_add_shader(program, shader)
            if glslang_program_link(
                program, Int32(GLSLANG_MSG_DEFAULT_BIT.rawValue)) == 0
            {
                throw ShaderCompileError.linkFailure(
                    log: programLog(program))
            }

            glslang_program_SPIRV_generate(program, GLSLANG_STAGE_FRAGMENT)
            let wordCount = glslang_program_SPIRV_get_size(program)
            guard wordCount > 0,
                  let wordsPtr = glslang_program_SPIRV_get_ptr(program)
            else {
                let messages = glslang_program_SPIRV_get_messages(program)
                let log = messages.map { String(cString: $0) } ?? "<no messages>"
                throw ShaderCompileError.spirvGenerationFailed(log: log)
            }
            return Array(UnsafeBufferPointer(start: wordsPtr, count: wordCount))
        }
    }

    private func makeGlslangInput(
        code: UnsafePointer<CChar>
    ) -> glslang_input_t {
        var input = glslang_input_t()
        input.language = GLSLANG_SOURCE_GLSL
        input.stage = GLSLANG_STAGE_FRAGMENT
        input.client = GLSLANG_CLIENT_VULKAN
        input.client_version = GLSLANG_TARGET_VULKAN_1_2
        input.target_language = GLSLANG_TARGET_SPV
        input.target_language_version = GLSLANG_TARGET_SPV_1_5
        input.code = code
        input.default_version = 100
        input.default_profile = GLSLANG_NO_PROFILE
        input.force_default_version_and_profile = 0
        input.forward_compatible = 0
        input.messages = GLSLANG_MSG_DEFAULT_BIT
        input.resource = glslang_default_resource()
        return input
    }

    private func infoLog(_ shader: OpaquePointer) -> String {
        guard let cstr = glslang_shader_get_info_log(shader) else { return "" }
        return String(cString: cstr)
    }

    private func programLog(_ program: OpaquePointer) -> String {
        guard let cstr = glslang_program_get_info_log(program) else { return "" }
        return String(cString: cstr)
    }

    // MARK: - Stage 3: SPIR-V → MSL via spirv-cross

    private func runSpirvCross(spirv: [UInt32]) throws -> String {
        var ctx: spvc_context? = nil
        guard spvc_context_create(&ctx) == SPVC_SUCCESS, let ctx else {
            throw ShaderCompileError.mslTranslationFailed(
                log: "spvc_context_create failed")
        }
        defer { spvc_context_destroy(ctx) }

        return try spirv.withUnsafeBufferPointer { buffer -> String in
            var parsedIR: spvc_parsed_ir? = nil
            if spvc_context_parse_spirv(
                ctx, buffer.baseAddress, buffer.count, &parsedIR) != SPVC_SUCCESS
            {
                throw ShaderCompileError.mslTranslationFailed(
                    log: lastError(ctx))
            }

            var compiler: spvc_compiler? = nil
            if spvc_context_create_compiler(
                ctx, SPVC_BACKEND_MSL, parsedIR,
                SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler
            ) != SPVC_SUCCESS {
                throw ShaderCompileError.mslTranslationFailed(
                    log: lastError(ctx))
            }

            var options: spvc_compiler_options? = nil
            if spvc_compiler_create_compiler_options(compiler, &options)
                != SPVC_SUCCESS
            {
                throw ShaderCompileError.mslTranslationFailed(
                    log: lastError(ctx))
            }
            _ = spvc_compiler_options_set_bool(
                options,
                SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING,
                SPVC_TRUE)
            if spvc_compiler_install_compiler_options(compiler, options)
                != SPVC_SUCCESS
            {
                throw ShaderCompileError.mslTranslationFailed(
                    log: lastError(ctx))
            }

            var mslCString: UnsafePointer<CChar>? = nil
            if spvc_compiler_compile(compiler, &mslCString) != SPVC_SUCCESS {
                throw ShaderCompileError.mslTranslationFailed(
                    log: lastError(ctx))
            }
            guard let mslCString else {
                throw ShaderCompileError.mslTranslationFailed(
                    log: "spvc_compiler_compile returned null source")
            }
            return String(cString: mslCString)
        }
    }

    private func lastError(_ ctx: spvc_context) -> String {
        guard let cstr = spvc_context_get_last_error_string(ctx) else {
            return ""
        }
        return String(cString: cstr)
    }
}
