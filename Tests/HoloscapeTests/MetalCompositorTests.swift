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

    func testScanlinesShaderCompiles() throws {
        guard let url = Bundle.module.url(forResource: "scanlines", withExtension: "glsl") else {
            XCTFail("scanlines.glsl not found in bundle")
            return
        }
        let compiler = ShaderCompiler()
        let compiled = try compiler.compile(glslPath: url)
        XCTAssertFalse(compiled.mslSource.isEmpty)
        XCTAssertTrue(compiled.mslSource.contains("main0"))
    }

    func testMSLTextureBindingIndex() throws {
        // Print the compiled MSL to see how iChannel0 is declared
        guard let url = Bundle.module.url(forResource: "identity", withExtension: "glsl") else {
            XCTFail("identity.glsl not found"); return
        }
        let compiled = try ShaderCompiler().compile(glslPath: url)

        // Find the texture declaration in the MSL
        let msl = compiled.mslSource
        let lines = msl.components(separatedBy: "\n")
        let textureLines = lines.filter { $0.contains("texture") || $0.contains("sampler") }
        print("=== MSL texture/sampler declarations ===")
        for line in textureLines { print(line) }

        // Find the main0 function signature
        let main0Lines = lines.filter { $0.contains("main0") }
        print("=== MSL main0 signature ===")
        for line in main0Lines { print(line) }

        // Check what binding index the texture uses
        let hasTexture0 = msl.contains("texture(0)")
        let hasTexture1 = msl.contains("texture(1)")
        print("Contains [[texture(0)]]: \(hasTexture0)")
        print("Contains [[texture(1)]]: \(hasTexture1)")

        // The texture should be at index 0 (binding=0 in GLSL)
        XCTAssertTrue(hasTexture0, "iChannel0 should be at [[texture(0)]]")
    }

    func testOffscreenRenderWithKnownTexture() throws {
        // This test creates a green input texture, renders through the identity
        // shader, reads back the output, and verifies the pixels are green (not black).
        // This isolates whether the texture binding works.

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("No Metal device"); return
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("No command queue"); return
        }

        // Compile identity shader
        guard let url = Bundle.module.url(forResource: "identity", withExtension: "glsl") else {
            XCTFail("identity.glsl not found"); return
        }
        let compiled = try ShaderCompiler().compile(glslPath: url)

        // Build pipeline
        let vertexLib = try device.makeLibrary(source: MetalCompositor.vertexShaderSource, options: nil)
        let fragLib = try device.makeLibrary(source: compiled.mslSource, options: nil)
        guard let vertexFn = vertexLib.makeFunction(name: "fullscreen_vertex"),
              let fragFn = fragLib.makeFunction(name: "main0") else {
            XCTFail("Could not find shader functions"); return
        }

        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertexFn
        pipeDesc.fragmentFunction = fragFn
        pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)

        let width = 64, height = 64

        // Create input texture (solid green) — this is iChannel0
        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        inputDesc.usage = [.shaderRead]
        inputDesc.storageMode = .shared
        guard let inputTexture = device.makeTexture(descriptor: inputDesc) else {
            XCTFail("Could not create input texture"); return
        }

        // Fill with solid green (BGRA: B=0, G=255, R=0, A=255)
        var greenPixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: greenPixels.count, by: 4) {
            greenPixels[i + 0] = 0     // B
            greenPixels[i + 1] = 255   // G
            greenPixels[i + 2] = 0     // R
            greenPixels[i + 3] = 255   // A
        }
        inputTexture.replace(
            region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0, withBytes: greenPixels, bytesPerRow: width * 4)

        // Create output texture (render target)
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outputDesc.usage = [.renderTarget, .shaderRead]
        outputDesc.storageMode = .shared
        guard let outputTexture = device.makeTexture(descriptor: outputDesc) else {
            XCTFail("Could not create output texture"); return
        }

        // Create UBO buffer (all zeros is fine for identity shader)
        guard let uboBuffer = device.makeBuffer(length: GlobalsUBOLayout.totalSize, options: .storageModeShared) else {
            XCTFail("Could not create UBO buffer"); return
        }
        // Set iResolution so the shader can compute UVs
        let ptr = uboBuffer.contents()
        ptr.storeBytes(of: Float(width), toByteOffset: GlobalsUBOLayout.iResolution, as: Float.self)
        ptr.storeBytes(of: Float(height), toByteOffset: GlobalsUBOLayout.iResolution + 4, as: Float.self)
        ptr.storeBytes(of: Float(1.0), toByteOffset: GlobalsUBOLayout.iResolution + 8, as: Float.self)

        // Render
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outputTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            XCTFail("Could not create render encoder"); return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputTexture, index: 0)
        encoder.setFragmentBuffer(uboBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Read back output pixels
        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)
        outputTexture.getBytes(
            &outputPixels,
            bytesPerRow: width * 4,
            from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0)

        // Check center pixel — should be green, not black
        let centerIdx = (height / 2 * width + width / 2) * 4
        let b = outputPixels[centerIdx + 0]
        let g = outputPixels[centerIdx + 1]
        let r = outputPixels[centerIdx + 2]
        let a = outputPixels[centerIdx + 3]
        print("=== Center pixel: R=\(r) G=\(g) B=\(b) A=\(a) ===")

        XCTAssertGreaterThan(g, 200, "Green channel should be bright (got \(g)) — iChannel0 texture binding is broken if this fails")
        XCTAssertLessThan(r, 50, "Red channel should be near zero (got \(r))")
        XCTAssertEqual(a, 255, "Alpha should be 255 (got \(a))")
    }

    func testScanlinesProduceAlternatingRows() throws {
        // Full pipeline test: solid white input → scanlines shader → verify
        // alternating bright/dark rows in the output. Proves the shader
        // actually modifies pixels, not just passes through.

        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTFail("No Metal device"); return
        }
        guard let queue = device.makeCommandQueue() else {
            XCTFail("No command queue"); return
        }

        guard let url = Bundle.module.url(forResource: "scanlines", withExtension: "glsl") else {
            XCTFail("scanlines.glsl not found"); return
        }
        let compiled = try ShaderCompiler().compile(glslPath: url)

        let vertexLib = try device.makeLibrary(source: MetalCompositor.vertexShaderSource, options: nil)
        let fragLib = try device.makeLibrary(source: compiled.mslSource, options: nil)
        guard let vertexFn = vertexLib.makeFunction(name: "fullscreen_vertex"),
              let fragFn = fragLib.makeFunction(name: "main0") else {
            XCTFail("Could not find shader functions"); return
        }

        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertexFn
        pipeDesc.fragmentFunction = fragFn
        pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)

        let width = 64, height = 64

        // Solid white input
        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        inputDesc.usage = [.shaderRead]
        inputDesc.storageMode = .shared
        guard let inputTexture = device.makeTexture(descriptor: inputDesc) else {
            XCTFail("Could not create input texture"); return
        }
        var whitePixels = [UInt8](repeating: 255, count: width * height * 4)
        inputTexture.replace(
            region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0, withBytes: whitePixels, bytesPerRow: width * 4)

        // Output texture
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outputDesc.usage = [.renderTarget, .shaderRead]
        outputDesc.storageMode = .shared
        guard let outputTexture = device.makeTexture(descriptor: outputDesc) else {
            XCTFail("Could not create output texture"); return
        }

        // UBO with resolution set
        guard let uboBuffer = device.makeBuffer(length: GlobalsUBOLayout.totalSize, options: .storageModeShared) else {
            XCTFail("Could not create UBO buffer"); return
        }
        let ptr = uboBuffer.contents()
        ptr.storeBytes(of: Float(width), toByteOffset: GlobalsUBOLayout.iResolution, as: Float.self)
        ptr.storeBytes(of: Float(height), toByteOffset: GlobalsUBOLayout.iResolution + 4, as: Float.self)
        ptr.storeBytes(of: Float(1.0), toByteOffset: GlobalsUBOLayout.iResolution + 8, as: Float.self)

        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            XCTFail("Could not create sampler"); return
        }

        // Render
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = outputTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            XCTFail("Could not create render encoder"); return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inputTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBuffer(uboBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Read back and verify alternating rows
        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)
        outputTexture.getBytes(
            &outputPixels,
            bytesPerRow: width * 4,
            from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0)

        // The scanlines shader darkens every row where mod(fragCoord.y, 3.0) < 1.0
        // to 40%. On white input (255), dark rows should be ~102, bright rows ~255.
        var darkRows = 0
        var brightRows = 0
        let midX = width / 2
        for y in 0..<height {
            let idx = (y * width + midX) * 4
            let g = outputPixels[idx + 1]  // green channel
            if g < 150 {
                darkRows += 1
            } else {
                brightRows += 1
            }
        }

        print("=== Scanline test: \(darkRows) dark rows, \(brightRows) bright rows out of \(height) ===")

        // Roughly 1/3 should be dark (mod 3 < 1), 2/3 bright
        XCTAssertGreaterThan(darkRows, 10, "Should have dark scanline rows (got \(darkRows))")
        XCTAssertGreaterThan(brightRows, 30, "Should have bright rows between scanlines (got \(brightRows))")
        XCTAssertNotEqual(darkRows, 0, "If all rows are the same brightness, the shader isn't working")
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
        // Verify stop/start lifecycle doesn't crash on headless init
        compositor.stop()
        compositor.stop() // idempotent
    }
}
