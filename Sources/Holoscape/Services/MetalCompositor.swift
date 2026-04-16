import AppKit
import Metal
import QuartzCore
import IOSurface

/// Renders a user shader behind the terminal view using Metal.
///
/// Each frame: captures the terminal's CALayer into an IOSurface-backed
/// MTLTexture (iChannel0), populates the Globals UBO, renders a fullscreen
/// triangle with the compiled shader, and presents the result on a
/// CAMetalLayer that visually occludes the terminal. The terminal view
/// remains underneath for hit testing.
@MainActor
final class MetalCompositor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let metalLayer: CAMetalLayer
    private let uniformBuffer: MTLBuffer

    private var frameCount: Int = 0
    private var startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // IOSurface capture pipeline
    private var ioSurface: IOSurface?
    private var captureTexture: MTLTexture?
    private var captureContext: CGContext?
    private var currentPixelSize: (w: Int, h: Int) = (0, 0)

    private var displayLink: CADisplayLink?
    private weak var sourceView: NSView?
    private weak var hostView: NSView?

    // MARK: - Initialization

    init(compiledShader: CompiledShader, sourceView: NSView, hostView: NSView) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalCompositorError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalCompositorError.noCommandQueue
        }
        self.device = device
        self.commandQueue = queue
        self.sourceView = sourceView
        self.hostView = hostView

        // Compile vertex shader
        let vertexLibrary: MTLLibrary
        do {
            vertexLibrary = try device.makeLibrary(source: Self.vertexShaderSource, options: nil)
        } catch {
            throw MetalCompositorError.vertexCompileFailed(error.localizedDescription)
        }
        guard let vertexFunction = vertexLibrary.makeFunction(name: "fullscreen_vertex") else {
            throw MetalCompositorError.vertexCompileFailed("fullscreen_vertex not found")
        }

        // Compile fragment shader from user's MSL
        let fragmentLibrary: MTLLibrary
        do {
            fragmentLibrary = try device.makeLibrary(source: compiledShader.mslSource, options: nil)
        } catch {
            throw MetalCompositorError.fragmentCompileFailed(error.localizedDescription)
        }
        // spirv-cross names the entry point "main0"
        guard let fragmentFunction = fragmentLibrary.makeFunction(name: "main0") else {
            // Fall back to searching for any fragment function
            let names = fragmentLibrary.functionNames
            throw MetalCompositorError.fragmentCompileFailed(
                "main0 not found in MSL library. Available: \(names)")
        }

        // Build render pipeline
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunction
        desc.fragmentFunction = fragmentFunction
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw MetalCompositorError.pipelineCreationFailed(error.localizedDescription)
        }

        // Uniform buffer (~4.7 KB for the Globals UBO)
        guard let buffer = device.makeBuffer(
            length: GlobalsUBOLayout.totalSize,
            options: .storageModeShared
        ) else {
            throw MetalCompositorError.bufferCreationFailed
        }
        self.uniformBuffer = buffer

        // CAMetalLayer
        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.contentsScale = hostView.window?.backingScaleFactor ?? 2.0
        self.metalLayer = ml
    }

    // MARK: - Lifecycle

    func start() {
        guard let hostView, let hostLayer = hostView.layer else { return }

        // Add metal layer on top of the terminal content
        metalLayer.frame = hostView.bounds
        metalLayer.contentsScale = hostView.window?.backingScaleFactor ?? 2.0
        metalLayer.zPosition = 10
        hostLayer.addSublayer(metalLayer)

        startTime = CFAbsoluteTimeGetCurrent()
        frameCount = 0

        // Create display link
        displayLink = hostView.displayLink(target: self, selector: #selector(renderFrame(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        metalLayer.removeFromSuperlayer()
    }

    func updateLayout() {
        guard let hostView else { return }
        metalLayer.frame = hostView.bounds
        metalLayer.contentsScale = hostView.window?.backingScaleFactor ?? 2.0
    }

    // MARK: - Per-frame render

    @objc private func renderFrame(_ link: CADisplayLink) {
        guard let sourceView, let sourceLayer = sourceView.layer else { return }

        let scale = metalLayer.contentsScale
        let bounds = metalLayer.bounds
        let pixelW = Int(bounds.width * scale)
        let pixelH = Int(bounds.height * scale)
        guard pixelW > 0, pixelH > 0 else { return }

        // Resize capture resources if needed
        if pixelW != currentPixelSize.w || pixelH != currentPixelSize.h {
            rebuildCapture(width: pixelW, height: pixelH)
        }

        guard let captureContext, let captureTexture else { return }

        // 1. Capture terminal layer into IOSurface-backed CGContext
        captureContext.saveGState()
        captureContext.scaleBy(x: scale, y: scale)
        sourceLayer.render(in: captureContext)
        captureContext.restoreGState()

        // 2. Update uniform buffer
        updateUniforms(width: Float(pixelW), height: Float(pixelH))
        frameCount += 1

        // 3. Get drawable (transient failures are normal during resize/pressure)
        metalLayer.drawableSize = CGSize(width: pixelW, height: pixelH)
        guard let drawable = metalLayer.nextDrawable() else {
            #if DEBUG
            NSLog("MetalCompositor: nextDrawable() returned nil (frame %d)", frameCount)
            #endif
            return
        }

        // 4. Render
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            #if DEBUG
            NSLog("MetalCompositor: command buffer/encoder creation failed (frame %d)", frameCount)
            #endif
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(captureTexture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - IOSurface capture pipeline

    private func rebuildCapture(width: Int, height: Int) {
        let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
        let unalignedBPR = width * 4
        let bytesPerRow = (unalignedBPR + alignment - 1) / alignment * alignment

        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurface(properties: properties) else {
            NSLog("MetalCompositor: IOSurface creation failed (%dx%d)", width, height)
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: surface.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            NSLog("MetalCompositor: CGContext creation failed (%dx%d)", width, height)
            return
        }

        // Flip Y for CoreGraphics (origin at bottom-left) vs Metal (top-left)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: texDesc, iosurface: surface, plane: 0) else {
            NSLog("MetalCompositor: MTLTexture creation from IOSurface failed (%dx%d)", width, height)
            return
        }

        self.ioSurface = surface
        self.captureContext = ctx
        self.captureTexture = texture
        self.currentPixelSize = (width, height)
    }

    // MARK: - Uniform buffer

    /// Populates the subset of Globals UBO fields needed for card 5 (identity render).
    /// Only iResolution, iTime, and iFrame are written; all other fields remain
    /// zero-initialized by Metal. Cursor/palette uniforms land in card 6 (#5944),
    /// agent-state uniforms in card 7 (#5945).
    private func updateUniforms(width: Float, height: Float) {
        let ptr = uniformBuffer.contents()
        let now = Float(CFAbsoluteTimeGetCurrent() - startTime)

        // iResolution (vec3 at offset 0)
        ptr.storeBytes(of: width, toByteOffset: GlobalsUBOLayout.iResolution, as: Float.self)
        ptr.storeBytes(of: height, toByteOffset: GlobalsUBOLayout.iResolution + 4, as: Float.self)
        ptr.storeBytes(of: Float(1.0), toByteOffset: GlobalsUBOLayout.iResolution + 8, as: Float.self)

        // iTime (float at offset 16)
        ptr.storeBytes(of: now, toByteOffset: GlobalsUBOLayout.iTime, as: Float.self)

        // iFrame (int at offset 28)
        ptr.storeBytes(of: Int32(frameCount), toByteOffset: GlobalsUBOLayout.iFrame, as: Int32.self)
    }

    // MARK: - Vertex shader

    private static let vertexShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.uv = float2((vid << 1) & 2, vid & 2);
        out.position = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }
    """
}

// MARK: - Errors

enum MetalCompositorError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case vertexCompileFailed(String)
    case fragmentCompileFailed(String)
    case pipelineCreationFailed(String)
    case bufferCreationFailed

    var description: String {
        switch self {
        case .noDevice: return "No Metal device available"
        case .noCommandQueue: return "Failed to create Metal command queue"
        case .vertexCompileFailed(let msg): return "Vertex shader compilation failed: \(msg)"
        case .fragmentCompileFailed(let msg): return "Fragment shader compilation failed: \(msg)"
        case .pipelineCreationFailed(let msg): return "Pipeline creation failed: \(msg)"
        case .bufferCreationFailed: return "Failed to create uniform buffer"
        }
    }
}

// MARK: - std140 UBO layout

/// Byte offsets matching the std140 layout of holoscape_prefix.glsl's Globals UBO.
/// std140 rules: vec3 aligned to 16 bytes, arrays of vec3 have 16-byte stride,
/// scalars (float/int) aligned to 4 bytes, vec4 aligned to 16 bytes.
enum GlobalsUBOLayout {
    // Shadertoy-compatible uniforms
    static let iResolution          = 0     // vec3 (12 bytes + 4 pad)
    static let iTime                = 16    // float
    static let iTimeDelta           = 20    // float
    static let iFrameRate           = 24    // float
    static let iFrame               = 28    // int
    static let iChannelTime         = 32    // float[4] — std140: 4 × 16 = 64
    static let iChannelResolution   = 96    // vec3[4] — std140: 4 × 16 = 64
    static let iMouse               = 160   // vec4 (16 bytes)
    static let iDate                = 176   // vec4 (16 bytes)
    static let iSampleRate          = 192   // float (4 bytes + 12 pad to align next vec4)

    // Ghostty cursor/focus uniforms
    static let iCurrentCursor       = 208   // vec4
    static let iPreviousCursor      = 224   // vec4
    static let iCurrentCursorColor  = 240   // vec4
    static let iPreviousCursorColor = 256   // vec4
    static let iCurrentCursorStyle  = 272   // int
    static let iPreviousCursorStyle = 276   // int
    static let iCursorVisible       = 280   // int
    static let iTimeCursorChange    = 284   // float
    static let iTimeFocus           = 288   // float
    static let iFocus               = 292   // int (4 bytes + pad to 16 for array)

    // iPalette: vec3[256] at next 16-byte boundary after offset 296 → 304
    static let iPalette             = 304   // vec3[256] — 256 × 16 = 4096

    // Post-palette colors (after 304 + 4096 = 4400)
    static let iBackgroundColor     = 4400  // vec3 (12 + 4 pad)
    static let iForegroundColor     = 4416  // vec3 (12 + 4 pad)
    static let iCursorColor         = 4432  // vec3 (12 + 4 pad)
    static let iCursorText          = 4448  // vec3 (12 + 4 pad)
    static let iSelectionFgColor    = 4464  // vec3 (12 + 4 pad)
    static let iSelectionBgColor    = 4480  // vec3 (12 + 4 pad)

    // Holoscape extensions (after 4480 + 16 = 4496)
    static let iOutputEventCount    = 4496  // int
    static let iTimeLastOutput      = 4500  // float
    static let iCommandState        = 4504  // int
    static let iPrevCommandState    = 4508  // int
    static let iLastCommandExitCode = 4512  // int
    static let iTimeCommandStart    = 4516  // float
    static let iTimeCommandEnd      = 4520  // float
    static let iAgentState          = 4524  // int
    static let iPrevAgentState      = 4528  // int
    static let iTimeAgentStateChange = 4532 // float
    static let iChannelId           = 4536  // int
    static let iChannelIsActive     = 4540  // int
    static let iChannelUnread       = 4544  // int
    static let iNotificationKind    = 4548  // int
    static let iTimeLastNotification = 4552 // float

    // Total size rounded up to 16-byte alignment
    static let totalSize            = 4560
}
