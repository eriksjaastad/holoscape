import Foundation
import AppKit
import CoreGraphics

/// Result of validating a chrome manifest against its baked Base_Layer
/// image and optional declared window shape. Returned by
/// `ChromeManifestValidator.validate`; consumed by `SkinEngine`
/// (populates `LoadedSkin.chromeValidation`) and by
/// `MainWindowController` (propagates `warningReason` into the
/// `SkinWarningBanner`).
///
/// `valid == false` means the manifest has a FATAL issue — missing
/// image, non-RGBA, dimension mismatch, `interiorRect` outside image
/// bounds (Requirement 12.8). In that case the chrome load fails over
/// to rectangular rendering using v3 surface fills.
///
/// `valid == true` with `warningReason != nil` means the manifest
/// loads but has a non-fatal issue the user should see — polygon/alpha
/// disagreement, sub-minimum size, per-layer param validation failure,
/// etc.
struct ChromeValidationResult: Equatable {
    /// Overall pass/fail. `false` means FATAL (Req 12.8) — caller
    /// must route through the rectangular fallback.
    let valid: Bool

    /// Short user-visible string fed into `SkinWarningBanner`. `nil`
    /// when everything passed cleanly.
    let warningReason: String?

    /// Animation layer `id`s that failed per-layer validation and are
    /// dropped from the install set. `ChromeHostView.installAnimatedLayers`
    /// (PR #10) must skip any id in this set.
    let disabledAnimationIDs: Set<String>

    /// Observed polygon-vs-alpha bounding-box delta in logical pixels
    /// (max across x/y dimensions). `0` = perfect agreement. Spec
    /// warns above 2 (Req 12.2, Property 4).
    let polygonAlphaDeltaPixels: Int
}

/// Load-time checks over a chrome manifest (Requirement 12). Called by
/// `SkinEngine.loadComposite` after the bake pipeline produces the
/// Base_Layer image. Stateless — every invocation reads inputs and
/// returns a fresh `ChromeValidationResult`.
///
/// Keeping this as an `enum` (stateless namespace) mirrors the spec's
/// Component 4 shape and keeps the call sites noise-free — no
/// lifecycle, no shared state, no configuration.
@MainActor
enum ChromeManifestValidator {

    // MARK: - Tunable thresholds

    /// Polygon/alpha bounding-box disagreement threshold in logical
    /// pixels. Fires the disagreement warning above this value (Req
    /// 12.2, Property 4). 2 px is generous — MSAA edges and
    /// sub-pixel antialiasing routinely shift alpha bbox by 1 px
    /// even when a skin is "correctly" authored.
    static let polygonAlphaToleranceLogicalPixels = 2

    /// Minimum logical width beneath which the validator emits a
    /// "small-chrome" sanity warning (Req 12.9). Not a rejection —
    /// authors CAN ship tiny chrome if they mean to.
    static let minimumChromeWidth = 200

    /// Minimum logical height, paired with the width check above.
    static let minimumChromeHeight = 100

    /// Shader presets the MVP renderer recognizes (Req 12.5). PR
    /// #12 ships `glow`, `scanlines`, `noise`; post-MVP extensions
    /// add cases here AND in `ShaderParams.Preset`.
    static let validShaderPresets: Set<String> = ["glow", "scanlines", "noise"]

    // MARK: - Public interface (Component 4)

    static func validate(
        manifest: SkinDefinition,
        baseImage: CGImage,
        windowShape: WindowShapeDescriptor?
    ) -> ChromeValidationResult {
        guard let chrome = manifest.chrome else {
            // Caller bug — validator shouldn't be invoked without a
            // v4 chrome field. Fail closed rather than silently pass.
            return ChromeValidationResult(
                valid: false,
                warningReason: "chrome manifest field missing",
                disabledAnimationIDs: [],
                polygonAlphaDeltaPixels: 0
            )
        }

        var disabled: Set<String> = []
        var warnings: [String] = []

        // --- FATAL checks (Req 12.8) ---

        // Image must be RGBA. Neither mode-baked NOR composed should
        // produce a non-RGBA CGImage, but the validator enforces
        // this invariant so downstream alpha-honoring code paths can
        // trust it. `alphaInfo` == none or noneSkip means the image
        // has no alpha channel — fatal.
        let alphaInfo = baseImage.alphaInfo
        let hasAlpha: Bool
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            hasAlpha = false
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
            hasAlpha = true
        @unknown default:
            hasAlpha = true
        }
        if !hasAlpha {
            return ChromeValidationResult(
                valid: false,
                warningReason: "chrome.image is not an RGBA PNG (alphaInfo=\(alphaInfo.rawValue))",
                disabledAnimationIDs: [],
                polygonAlphaDeltaPixels: 0
            )
        }

        // Image pixel dimensions must match declared chrome size at
        // 2x backing scale (the bake pipeline produces (w*2, h*2)
        // pixels for composed mode; baked mode expects the author's
        // PNG to be at 2x too).
        let expectedPixelWidth = chrome.width * 2
        let expectedPixelHeight = chrome.height * 2
        if baseImage.width != expectedPixelWidth || baseImage.height != expectedPixelHeight {
            return ChromeValidationResult(
                valid: false,
                warningReason: "chrome.image pixel dimensions (\(baseImage.width)×\(baseImage.height)) don't match declared chrome size at 2x (\(expectedPixelWidth)×\(expectedPixelHeight))",
                disabledAnimationIDs: [],
                polygonAlphaDeltaPixels: 0
            )
        }

        // Interior rect must be inside the image bounds.
        let interiorFitsImage = chrome.interiorRect.x >= 0
            && chrome.interiorRect.y >= 0
            && chrome.interiorRect.x + chrome.interiorRect.width <= Double(chrome.width)
            && chrome.interiorRect.y + chrome.interiorRect.height <= Double(chrome.height)
        if !interiorFitsImage {
            return ChromeValidationResult(
                valid: false,
                warningReason: "chrome.interiorRect (\(Self.describe(chrome.interiorRect))) falls outside chrome bounds (\(chrome.width)×\(chrome.height))",
                disabledAnimationIDs: [],
                polygonAlphaDeltaPixels: 0
            )
        }

        // --- NON-FATAL warnings ---

        // Req 12.9 — small-chrome sanity warning.
        if chrome.width < Self.minimumChromeWidth || chrome.height < Self.minimumChromeHeight {
            warnings.append("chrome dimensions (\(chrome.width)×\(chrome.height)) below minimum \(Self.minimumChromeWidth)×\(Self.minimumChromeHeight) — may not render correctly")
        }

        // Req 12.1 / 12.2 — polygon vs alpha bbox agreement.
        let deltaPixels: Int
        if let windowShape, let polygons = windowShape.polygons, !polygons.isEmpty {
            let polygonBBox = Self.polygonBoundingBox(polygons)
            let alphaBBox = Self.alphaBoundingBoxLogical(baseImage: baseImage, chromeWidth: chrome.width, chromeHeight: chrome.height)
            deltaPixels = Self.maxDelta(polygonBBox: polygonBBox, alphaBBox: alphaBBox)
            if deltaPixels > Self.polygonAlphaToleranceLogicalPixels {
                warnings.append("polygon/alpha bbox disagreement: \(deltaPixels) px (tolerance \(Self.polygonAlphaToleranceLogicalPixels))")
            }
        } else {
            deltaPixels = 0
        }

        // Req 12.3 — unique animation ids.
        if let animations = chrome.animations {
            var seen: Set<String> = []
            for anim in animations {
                if !seen.insert(anim.id).inserted {
                    disabled.insert(anim.id)
                    warnings.append("duplicate animation id '\(anim.id)'")
                }
            }

            // Req 12.4 / 12.5 / 12.6 — per-layer validation.
            for anim in animations where !disabled.contains(anim.id) {
                if let reason = validateAnimation(anim, chrome: chrome, skinDir: manifest.skinDirForValidation) {
                    disabled.insert(anim.id)
                    warnings.append("animation '\(anim.id)' — \(reason)")
                }
            }
        }

        let reason = warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        return ChromeValidationResult(
            valid: true,
            warningReason: reason,
            disabledAnimationIDs: disabled,
            polygonAlphaDeltaPixels: deltaPixels
        )
    }

    // MARK: - Per-animation validation

    /// Returns a reason string if the animation fails validation,
    /// `nil` if it passes. Caller adds the id-prefixed wrapper.
    private static func validateAnimation(
        _ anim: ChromeAnimationLayer,
        chrome: ChromeDescriptor,
        skinDir: URL?
    ) -> String? {
        // Req 12.4 — rect inside chrome bounds.
        let r = anim.rect
        let rectInside = r.x >= 0
            && r.y >= 0
            && r.x + r.width <= Double(chrome.width)
            && r.y + r.height <= Double(chrome.height)
        if !rectInside {
            return "rect (\(Self.describe(r))) outside chrome bounds (\(chrome.width)×\(chrome.height))"
        }

        // Req 10.4 — z > 0 (Base_Layer occupies implicit z = 0).
        // Extension to Task 9.1 noted in design.md — enforced at the
        // validator to match the per-layer contract.
        if anim.z <= 0 {
            return "z must be > 0 (Base_Layer owns z=0); got \(anim.z)"
        }

        // Req 12.5 — dataSource must be .none or .time when present.
        // Codable already restricts the enum to those cases, but
        // future additive cases post-MVP would decode without
        // validator coverage; a future extension adds a case here.

        // Req 12.5 — kind-specific param validation.
        switch anim.kind {
        case .particle:
            guard let params = anim.params.particle else {
                return "kind=.particle but params.particle missing"
            }
            if params.birthRate <= 0 {
                return "particle.birthRate must be > 0; got \(params.birthRate)"
            }
            // Req 12.6 — asset existence.
            if let imagePath = params.image, let dir = skinDir {
                let url = dir.appendingPathComponent(imagePath)
                if !FileManager.default.fileExists(atPath: url.path) {
                    return "particle image '\(imagePath)' not found in skin bundle"
                }
            }

        case .ledArray:
            guard let params = anim.params.ledArray else {
                return "kind=.ledArray but params.ledArray missing"
            }
            if params.palette.isEmpty {
                return "ledArray.palette must be non-empty"
            }
            for (i, cell) in params.cells.enumerated() {
                if cell.defaultState < 0 || cell.defaultState >= params.palette.count {
                    return "ledArray.cells[\(i)].defaultState=\(cell.defaultState) outside palette range [0, \(params.palette.count))"
                }
            }

        case .spriteAnim:
            guard let params = anim.params.spriteAnim else {
                return "kind=.spriteAnim but params.spriteAnim missing"
            }
            if params.gridRows * params.gridCols < params.frameCount {
                return "spriteAnim.gridRows×gridCols=\(params.gridRows * params.gridCols) < frameCount=\(params.frameCount)"
            }
            if let dir = skinDir {
                let url = dir.appendingPathComponent(params.sheet)
                if !FileManager.default.fileExists(atPath: url.path) {
                    return "spriteAnim sheet '\(params.sheet)' not found in skin bundle"
                }
            }

        case .shader:
            guard let params = anim.params.shader else {
                return "kind=.shader but params.shader missing"
            }
            if !Self.validShaderPresets.contains(params.preset.rawValue) {
                return "shader.preset '\(params.preset.rawValue)' unknown (expected one of \(Self.validShaderPresets.sorted()))"
            }
        }

        return nil
    }

    // MARK: - Polygon / alpha bounding boxes

    /// Bounding box of every vertex in every polygon, in logical pts.
    /// Empty polygon list returns a zero rect — caller should gate on
    /// non-empty polygons before invoking.
    static func polygonBoundingBox(_ polygons: [Polygon]) -> NSRect {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for poly in polygons {
            for pt in poly.points {
                if pt.x < minX { minX = pt.x }
                if pt.y < minY { minY = pt.y }
                if pt.x > maxX { maxX = pt.x }
                if pt.y > maxY { maxY = pt.y }
            }
        }
        if !minX.isFinite { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Bounding box of non-zero-alpha pixels in the base image, in
    /// logical points. Walks the pixel buffer once — O(w*h) but
    /// only runs at skin load, well inside the 500 ms bake budget.
    static func alphaBoundingBoxLogical(
        baseImage: CGImage,
        chromeWidth: Int,
        chromeHeight: Int
    ) -> NSRect {
        let pixelWidth = baseImage.width
        let pixelHeight = baseImage.height
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }

        // Draw into a canonical RGBA8 context so `alphaInfo` matches
        // our sampling assumption regardless of the source image's
        // native pixel format. Small-N per-bake, so the extra
        // allocation is cheap vs. the asymmetric sampling headache.
        let bytesPerRow = pixelWidth * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .zero }
        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let pixelsPtr = context.data else { return .zero }
        let pixels = pixelsPtr.assumingMemoryBound(to: UInt8.self)

        var minX = pixelWidth
        var minY = pixelHeight
        var maxX = -1
        var maxY = -1

        for y in 0..<pixelHeight {
            let rowStart = y * bytesPerRow
            for x in 0..<pixelWidth {
                let alpha = pixels[rowStart + x * 4 + 3]
                if alpha > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        if maxX < 0 { return .zero }

        // Scale pixel coords back to logical points. The bake
        // pipeline produces 2x pixels; compare against that ratio
        // directly rather than trust a hardcoded `2`.
        let scaleX = Double(chromeWidth) / Double(pixelWidth)
        let scaleY = Double(chromeHeight) / Double(pixelHeight)
        return NSRect(
            x: Double(minX) * scaleX,
            y: Double(minY) * scaleY,
            width: Double(maxX - minX + 1) * scaleX,
            height: Double(maxY - minY + 1) * scaleY
        )
    }

    /// Max logical-pixel delta across any of the four bbox edges.
    /// Spec says "any dimension" which the tests read as "edge
    /// disagreement", not "width/height disagreement" — disagree on
    /// left edge by 5 and right edge by 0 means 5 px delta.
    static func maxDelta(polygonBBox p: NSRect, alphaBBox a: NSRect) -> Int {
        let dxMin = abs(p.minX - a.minX)
        let dyMin = abs(p.minY - a.minY)
        let dxMax = abs(p.maxX - a.maxX)
        let dyMax = abs(p.maxY - a.maxY)
        return Int(ceil(max(dxMin, dyMin, dxMax, dyMax)))
    }

    // MARK: - Formatting

    private static func describe(_ rect: SkinRect) -> String {
        "x=\(rect.x), y=\(rect.y), w=\(rect.width), h=\(rect.height)"
    }
}

// MARK: - SkinDefinition hook for skinDir

private extension SkinDefinition {
    /// Stub accessor used only by `ChromeManifestValidator` when the
    /// caller didn't thread `skinDir` through the invocation (unit
    /// tests that don't care about asset-existence checks). Production
    /// callers via `SkinEngine` always pass `skinDir` into
    /// `validate(manifest:baseImage:windowShape:skinDir:)` via the
    /// overload below, bypassing this path.
    var skinDirForValidation: URL? { nil }
}

extension ChromeManifestValidator {
    /// Convenience overload for `SkinEngine.loadComposite` that threads
    /// the resolved skin directory through to asset-existence checks
    /// (Req 12.6). Tests that don't care about asset existence can
    /// use the stateless three-arg form above.
    static func validate(
        manifest: SkinDefinition,
        baseImage: CGImage,
        windowShape: WindowShapeDescriptor?,
        skinDir: URL
    ) -> ChromeValidationResult {
        // Run the standard validation, then layer asset-existence
        // on top — the base call can't see skinDir (SkinDefinition
        // is a value type with no knowledge of its origin path).
        var result = validate(manifest: manifest, baseImage: baseImage, windowShape: windowShape)
        guard let chrome = manifest.chrome, let animations = chrome.animations else {
            return result
        }
        var warnings = result.warningReason.map { [$0] } ?? []
        var disabled = result.disabledAnimationIDs

        for anim in animations where !disabled.contains(anim.id) {
            var assetMissing: String? = nil
            if anim.kind == .particle, let path = anim.params.particle?.image {
                let url = skinDir.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    assetMissing = "particle image '\(path)' not found in skin bundle"
                }
            }
            if anim.kind == .spriteAnim, let path = anim.params.spriteAnim?.sheet {
                let url = skinDir.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    assetMissing = "spriteAnim sheet '\(path)' not found in skin bundle"
                }
            }
            if let reason = assetMissing {
                disabled.insert(anim.id)
                warnings.append("animation '\(anim.id)' — \(reason)")
            }
        }

        let combined = warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        result = ChromeValidationResult(
            valid: result.valid,
            warningReason: combined,
            disabledAnimationIDs: disabled,
            polygonAlphaDeltaPixels: result.polygonAlphaDeltaPixels
        )
        return result
    }
}
