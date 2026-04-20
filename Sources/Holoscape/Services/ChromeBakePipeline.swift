import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Load-time baker for v4 PNG-alpha chrome (Component 3 of
/// `claude-specs/chrome/design.md`). Two modes:
///
/// - **baked**: the skin ships a pre-rendered RGBA PNG at
///   `chrome.image`. Decode, SHA the inputs, hand back the CGImage.
///   This is the path reference skins like HoloscapeClassic-live
///   take (PR #14).
///
/// - **composed**: the skin leaves `chrome.image` nil and lets the
///   pipeline paint the Base_Layer at load time by walking v3 surface
///   descriptors. Existing v3 skins (HoloscapeSynthwave, AmplifyDemo)
///   migrate via PRs #15/#16 with zero author repainting — the same
///   surface descriptors that drive per-view rendering in v3 drive the
///   offscreen compositor here.
///
/// Either mode populates `~/Library/Caches/holoscape-skins/<sha>.png`
/// so warm reloads skip the CGContext step entirely (≤ 30 ms budget,
/// Requirement 5.8). `purgeLRU(preservingSHAs:)` enforces the 50 MB
/// cap shared with the `.wamp` unzip cache (Requirement 5.6).
@MainActor
final class ChromeBakePipeline {

    // MARK: - Configuration

    /// Root directory for cached baked chrome PNGs. Real builds use
    /// `~/Library/Caches/holoscape-skins/`; tests override via the init
    /// arg so they stage disposable caches under their temp directories.
    let cacheRoot: URL

    /// Hard cap on on-disk cache size. Shared with the `.wamp` unzip
    /// cache (Requirement 5.6) — the two caches coordinate by each
    /// running `purgeLRU(preservingSHAs:)` independently when the sum
    /// of their sizes exceeds this cap. PR #4 only enforces the cap
    /// on the chrome side; the shared-cap coordination lands alongside
    /// PR #18's hot-reload work once both caches are wired into a
    /// single size-accounting surface.
    static let cacheSizeCapBytes: Int64 = 50 * 1024 * 1024

    /// Y-extent (in logical chrome-image points) of the tab bar strip
    /// at the top of a composed-mode chrome. Matches the existing v3
    /// tabs-in-titlebar constant from `MainWindowController` so a
    /// composed-mode skin lays out identically to the v3 window it
    /// migrated from (Requirement 5's "zero author repainting" story).
    private static let composedTabBarHeight: Double = 32

    /// X-extent (in logical chrome-image points) of the sidebar strip
    /// at the left of a composed-mode chrome. Matches
    /// `SidebarView.sidebarWidth` for the same reason as above.
    private static let composedSidebarWidth: Double = 220

    private let fileManager: FileManager

    // MARK: - Errors

    enum BakeError: Error {
        /// CGContext init failed or an asset couldn't render into it.
        case compositingFailed(String)
        /// Cache write failed — disk full, permission denied. Per
        /// design.md error policy, this is NOT thrown at runtime:
        /// `writeCacheEntryBestEffort` logs and returns the
        /// in-memory image. The case exists for enum parity with
        /// the spec and future stricter policies.
        case cacheWriteFailed(URL)
        /// Cache read failed — corrupt PNG. Per design.md error
        /// policy, `cachedImage(for:)` deletes the corrupt entry and
        /// returns nil; the outer bake call then re-runs from inputs.
        /// Carries the underlying Error so a future stricter policy
        /// could surface the root cause to the banner.
        case cacheReadFailed(URL, Error)
        /// `chrome.mode == .baked` but the referenced image couldn't be
        /// decoded from the skin dir.
        case imageDecodeFailed(String)
        /// `chrome` field was nil on the manifest; the pipeline was
        /// invoked where it shouldn't have been.
        case missingChromeDescriptor
    }

    // MARK: - Init

    init(cacheRoot: URL? = nil, fileManager: FileManager = .default) {
        if let cacheRoot {
            self.cacheRoot = cacheRoot
        } else if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"],
                  !override.isEmpty {
            // Tests and dev builds that already override the config dir
            // get their chrome cache under the same dir so nothing leaks
            // into the real user cache.
            self.cacheRoot = URL(fileURLWithPath: override)
                .appendingPathComponent("caches/holoscape-skins")
        } else {
            self.cacheRoot = fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("holoscape-skins")
        }
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Public interface (Component 3)

    /// Returns the Base_Layer CGImage for a v4 manifest plus the SHA
    /// that keys its cache entry. Cache hits decode the stored PNG;
    /// cache misses compose or decode, write to cache best-effort, and
    /// return the in-memory image either way.
    ///
    /// `reduceTransparency == true` (accessibility preference) swaps
    /// the translucent variant for an opaque one: `chrome.imageOpaque`
    /// if declared, else a synthesized variant that multiplies source
    /// alpha to 1.0 on every non-zero-alpha pixel (Req 15.1, 15.2).
    /// The opaque variant caches alongside the translucent one at
    /// `<sha>.opaque.png` so toggling the preference doesn't re-bake.
    func bake(
        manifest: SkinDefinition,
        skinDir: URL,
        reduceTransparency: Bool = false
    ) throws -> (image: CGImage, sha: String) {
        guard let chrome = manifest.chrome else {
            throw BakeError.missingChromeDescriptor
        }

        let sha = try computeSHA(manifest: manifest, chrome: chrome, skinDir: skinDir)

        // Opaque variant branch (Req 15.1 / 15.2). Keeps cache keys
        // symmetric: `<sha>.png` holds the translucent chrome,
        // `<sha>.opaque.png` holds the opacified one. Toggling Reduce
        // Transparency at runtime does not re-bake — only re-reads.
        if reduceTransparency {
            if let cached = cachedOpaqueImage(for: sha) {
                touchOpaqueCacheEntry(sha: sha)
                return (cached, sha)
            }
            let opaqueImage: CGImage
            if let opaquePath = chrome.imageOpaque, chrome.mode == .baked {
                // Author-shipped opaque variant wins when present
                // AND the skin is in baked mode (composed mode's
                // imageOpaque would have to be baked from separate
                // v3 surface state, which is post-MVP).
                let url = skinDir.appendingPathComponent(opaquePath)
                guard fileManager.fileExists(atPath: url.path),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw BakeError.imageDecodeFailed("chrome.imageOpaque '\(opaquePath)' missing or corrupt")
                }
                opaqueImage = image
            } else {
                // Synthesize: start from the normal baked image, then
                // opacify (alpha == 0 stays zero; alpha > 0 becomes
                // alpha == 255). Matches Req 15.2 verbatim.
                let source: CGImage
                if let cached = cachedImage(for: sha) {
                    source = cached
                } else {
                    switch chrome.mode {
                    case .baked:
                        source = try decodeBakedImage(chrome: chrome, skinDir: skinDir)
                    case .composed:
                        source = try compositeImage(chrome: chrome, manifest: manifest, skinDir: skinDir)
                    }
                    writeCacheEntryBestEffort(image: source, sha: sha)
                }
                guard let opacified = opacifyImage(source) else {
                    throw BakeError.compositingFailed("failed to opacify chrome image for Reduce Transparency variant")
                }
                opaqueImage = opacified
            }
            writeOpaqueCacheEntryBestEffort(image: opaqueImage, sha: sha)
            return (opaqueImage, sha)
        }

        if let cached = cachedImage(for: sha) {
            touchCacheEntry(sha: sha)
            return (cached, sha)
        }

        let image: CGImage
        switch chrome.mode {
        case .baked:
            image = try decodeBakedImage(chrome: chrome, skinDir: skinDir)
        case .composed:
            image = try compositeImage(chrome: chrome, manifest: manifest, skinDir: skinDir)
        }

        writeCacheEntryBestEffort(image: image, sha: sha)
        return (image, sha)
    }

    /// Read a cached baked PNG if it exists. Used by `bake` on cache
    /// hit; exposed so `SkinEngine` can pre-warm or inspect the cache
    /// without invoking the bake path.
    ///
    /// **Side effect (per design.md error policy, line 693):** a
    /// corrupt cache entry is deleted from disk so the next `bake`
    /// call misses cleanly instead of hitting the same bad bytes.
    /// Callers that want to inspect the raw file (e.g., cache
    /// diagnostics) must go through `FileManager` directly.
    func cachedImage(for sha: String) -> CGImage? {
        let url = cacheURL(for: sha)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // Corrupt cache entry — delete so the next bake re-populates.
            try? fileManager.removeItem(at: url)
            return nil
        }
        return image
    }

    /// Enforce the 50 MB cap by deleting least-recently-used entries.
    /// `preservingSHAs` names the entries that MUST stay (the active
    /// skin's chrome + any hot-reload candidates); these are never
    /// evicted even if doing so would push the cache below cap.
    /// Requirement 5.6.
    func purgeLRU(preservingSHAs: Set<String>) throws {
        let entries = try listCacheEntries()
        var totalBytes: Int64 = entries.reduce(0) { $0 + $1.sizeBytes }

        if totalBytes <= Self.cacheSizeCapBytes { return }

        // LRU eviction: sort oldest-first by access time; drop entries
        // until under cap or we're out of evictable entries.
        let evictable = entries
            .filter { !preservingSHAs.contains($0.sha) }
            .sorted { $0.accessTime < $1.accessTime }

        for entry in evictable {
            if totalBytes <= Self.cacheSizeCapBytes { break }
            try fileManager.removeItem(at: entry.url)
            totalBytes -= entry.sizeBytes
        }
    }

    // MARK: - SHA

    /// Deterministic SHA-256 over manifest JSON + referenced asset
    /// bytes. Determinism is load-bearing for Property 5 — two
    /// independent bakes of the same inputs must produce the same
    /// SHA so the cache stays stable across machines and across
    /// reruns. Sorted keys on the JSON encode, sorted asset paths
    /// on the concat, UTF-8 throughout.
    func computeSHA(manifest: SkinDefinition, chrome: ChromeDescriptor, skinDir: URL) throws -> String {
        var hasher = SHA256()

        // 1. Manifest JSON (sortedKeys — every implementation of
        //    JSONEncoder must agree on the byte output for the same
        //    input tree).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        hasher.update(data: manifestData)

        // 2. Every referenced asset, in sorted-path order. Silent-miss
        //    on a referenced asset is fine for hashing — the subsequent
        //    bake step surfaces a more informative error if the asset
        //    is actually needed to paint.
        let assetPaths = referencedAssetPaths(manifest: manifest, chrome: chrome)
        for path in assetPaths.sorted() {
            // Separator between path and bytes so two paths with the
            // same suffix don't collide: `foo.png` + `bar.png` bytes
            // must not equal `foobar.png` + `.png` bytes.
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0x00]))
            let url = skinDir.appendingPathComponent(path)
            if let bytes = try? Data(contentsOf: url) {
                hasher.update(data: bytes)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every asset the bake depends on. Extracted here so
    /// `computeSHA` and `compositeImage` use the same list and
    /// stay in sync by construction.
    private func referencedAssetPaths(manifest: SkinDefinition, chrome: ChromeDescriptor) -> Set<String> {
        var paths: Set<String> = []

        // Chrome image(s).
        if let p = chrome.image { paths.insert(p) }
        if let p = chrome.imageOpaque { paths.insert(p) }

        // v3 surfaces — any image-fill path.
        if let surfaces = manifest.surfaces {
            for (_, descriptor) in surfaces {
                if case .image(let path, _, _) = descriptor.fill {
                    paths.insert(path)
                }
                for state in descriptor.states ?? [] {
                    if case .image(let path, _, _) = state.fill {
                        paths.insert(path)
                    }
                }
            }
        }

        // v1 fields (still read by SkinContext for backward compat).
        if let p = manifest.windowBackgroundImage { paths.insert(p) }
        if let p = manifest.sidebarBackgroundImage { paths.insert(p) }
        if let p = manifest.tabBarBackgroundImage { paths.insert(p) }

        // Chrome animations.
        for anim in chrome.animations ?? [] {
            if let p = anim.params.particle?.image { paths.insert(p) }
            if let p = anim.params.spriteAnim?.sheet { paths.insert(p) }
        }

        return paths
    }

    // MARK: - Baked mode

    /// Decode a skin-shipped PNG at `chrome.image`. Requirement 1.2
    /// already enforced at manifest decode that this path is
    /// non-empty, so the only failure mode here is a disk / format
    /// issue.
    private func decodeBakedImage(chrome: ChromeDescriptor, skinDir: URL) throws -> CGImage {
        guard let relativePath = chrome.image else {
            throw BakeError.imageDecodeFailed("chrome.image nil in .baked mode — manifest should have failed decode")
        }
        let url = skinDir.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BakeError.imageDecodeFailed("chrome.image not found at \(url.path)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BakeError.imageDecodeFailed("CGImage decode failed for \(url.path)")
        }
        return image
    }

    // MARK: - Composed mode

    /// Composite a v3-surface chrome into a `(chrome.width * 2,
    /// chrome.height * 2)` RGBA context and return the resulting
    /// CGImage. Requirement 5.1 — "walk the skin's v3 surfaces and
    /// draw them into a CGContext." The layout follows the existing
    /// v3 window structure so migration is drop-in (zero repaint by
    /// the author): window background spans the full chrome; the tab
    /// bar container band paints the top strip; the sidebar container
    /// paints the left strip below the tab bar.
    private func compositeImage(chrome: ChromeDescriptor, manifest: SkinDefinition, skinDir: URL) throws -> CGImage {
        let logicalWidth = chrome.width
        let logicalHeight = chrome.height
        let scale = 2
        let pixelWidth = logicalWidth * scale
        let pixelHeight = logicalHeight * scale

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw BakeError.compositingFailed("CGContext init failed at \(pixelWidth)x\(pixelHeight)")
        }

        context.interpolationQuality = .high
        // CGContext origin is bottom-left; our chrome coords are
        // top-left. Flip Y once so every `paintBand(surface:in:)`
        // call can pass a top-left rect and the paint lands at the
        // right spot.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

        // Composed layout (see class-level doc on constants):
        //
        //   ┌─────────────────────────────────────────┐
        //   │                 tabBar.container          │  (top 32pt band)
        //   ├──────────┬──────────────────────────────┤
        //   │          │                              │
        //   │ sidebar  │  (interior — not painted;   │
        //   │ .cont.   │   window.background shows)  │
        //   │          │                              │
        //   └──────────┴──────────────────────────────┘
        //
        // window.background paints FIRST as the base color of the
        // whole chrome. The two band surfaces overlay on top.
        let fullRect = NSRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
        paintBand(
            surfaceKey: .windowBackground,
            rect: fullRect,
            into: context,
            manifest: manifest,
            skinDir: skinDir
        )

        let tabBarRect = NSRect(
            x: 0,
            y: 0,
            width: logicalWidth,
            height: Int(Self.composedTabBarHeight)
        )
        paintBand(
            surfaceKey: .tabBarContainer,
            rect: tabBarRect,
            into: context,
            manifest: manifest,
            skinDir: skinDir
        )

        let sidebarRect = NSRect(
            x: 0,
            y: Int(Self.composedTabBarHeight),
            width: Int(Self.composedSidebarWidth),
            height: logicalHeight - Int(Self.composedTabBarHeight)
        )
        paintBand(
            surfaceKey: .sidebarContainer,
            rect: sidebarRect,
            into: context,
            manifest: manifest,
            skinDir: skinDir
        )

        guard let image = context.makeImage() else {
            throw BakeError.compositingFailed("CGContext.makeImage failed after compositing")
        }
        return image
    }

    /// Paint a single band surface into the context at `rect` (top-left
    /// coords, logical points). A missing descriptor is a silent no-op
    /// — composed-mode skins legitimately omit strips they don't want
    /// to paint.
    private func paintBand(
        surfaceKey: SurfaceKey,
        rect: NSRect,
        into context: CGContext,
        manifest: SkinDefinition,
        skinDir: URL
    ) {
        guard let descriptor = manifest.surfaces?[surfaceKey.rawValue] else { return }
        guard let fill = descriptor.fill else { return }

        // The context is already flipped so `rect` is top-left. We
        // paint in that flipped space directly.
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        switch fill {
        case .color(let hex):
            guard let color = NSColor(hex: hex) else { return }
            context.setFillColor(color.cgColor)
            context.fill(rect)

        case .image(let relativePath, let tile, let sprite):
            let url = skinDir.appendingPathComponent(relativePath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

            // Sprite sheet fill (Req 5.1 — "walk v3 surfaces +
            // sprites"). Pick the `.normal` cell — chrome bands paint
            // at their resting state; per-state variants (active /
            // hover / pressed) are for runtime per-element painting
            // inside InteriorView, not the baked chrome.
            if let sprite {
                paintSpriteCell(
                    image: image,
                    sprite: sprite,
                    rect: rect,
                    into: context
                )
                return
            }

            // Ninepatch tile-mode without a sidecar falls back to
            // stretch, matching `SkinContext.applyTileMode`'s behavior
            // (Req 13.5 graceful degradation). Sidecar-driven 9-slice
            // resolution lands alongside PR #18's hot-reload work when
            // sidecar-map propagation wires through the bake pipeline.
            _ = tile
            context.draw(image, in: rect)

        case .gradient(let direction, let stops):
            guard stops.count >= 2 else { return }
            let cgColors = stops.compactMap { NSColor(hex: $0.color)?.cgColor } as CFArray
            let locations = stops.map { CGFloat($0.offset) }
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: locations
            ) else { return }
            let start: CGPoint
            let end: CGPoint
            switch direction {
            case .vertical:
                start = CGPoint(x: rect.midX, y: rect.minY)
                end = CGPoint(x: rect.midX, y: rect.maxY)
            case .horizontal:
                start = CGPoint(x: rect.minX, y: rect.midY)
                end = CGPoint(x: rect.maxX, y: rect.midY)
            }
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
    }

    /// Render a single sprite cell from `sheet` into `rect`. Picks the
    /// `.normal` cell for chrome-band bakes (stateful cells belong to
    /// runtime per-element surfaces, not the baked chrome). If
    /// `stateMap` omits `normal`, falls back to full-sheet stretch —
    /// matches `SkinContext.applySpriteCell`'s fallback (Req 5.3).
    private func paintSpriteCell(
        image: CGImage,
        sprite: SpriteDescriptor,
        rect: NSRect,
        into context: CGContext
    ) {
        let cell = sprite.stateMap[SpriteState.normal.rawValue]
            ?? sprite.stateMap.values.first
        guard let cell else {
            context.draw(image, in: rect)
            return
        }
        // Crop the sheet to the cell's pixel rect and draw at `rect`.
        let cellPixelRect = CGRect(
            x: cell.col * sprite.cellWidth,
            y: cell.row * sprite.cellHeight,
            width: sprite.cellWidth,
            height: sprite.cellHeight
        )
        guard let cropped = image.cropping(to: cellPixelRect) else {
            context.draw(image, in: rect)
            return
        }
        context.draw(cropped, in: rect)
    }

    // MARK: - Opacify

    /// Multiply source alpha to 1.0 on every non-zero-alpha pixel,
    /// leaving fully-transparent pixels alone. Implements Req 15.2's
    /// Reduce Transparency fallback when the skin doesn't ship an
    /// author-provided `chrome.imageOpaque`. Preserves the chrome
    /// silhouette exactly — only semitransparent edges become fully
    /// opaque.
    func opacifyImage(_ source: CGImage) -> CGImage? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ptr = context.data else { return nil }
        let pixels = ptr.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * 4
                let alpha = pixels[i + 3]
                if alpha > 0 && alpha < 0xFF {
                    // Reverse premultiplication so the RGB channels
                    // scale back to their full-alpha values, then
                    // re-store with alpha = 255. Without this,
                    // semitransparent edges turn darker when
                    // opacified (premultiplied RGB was already
                    // scaled by the source alpha).
                    let a = Double(alpha) / 255.0
                    let r = min(255, Int(round(Double(pixels[i]) / a)))
                    let g = min(255, Int(round(Double(pixels[i + 1]) / a)))
                    let b = min(255, Int(round(Double(pixels[i + 2]) / a)))
                    pixels[i] = UInt8(r)
                    pixels[i + 1] = UInt8(g)
                    pixels[i + 2] = UInt8(b)
                    pixels[i + 3] = 0xFF
                }
            }
        }
        return context.makeImage()
    }

    // MARK: - Cache I/O

    private func cacheURL(for sha: String) -> URL {
        cacheRoot.appendingPathComponent("\(sha).png")
    }

    private func opaqueCacheURL(for sha: String) -> URL {
        cacheRoot.appendingPathComponent("\(sha).opaque.png")
    }

    /// Read a cached OPAQUE baked PNG if it exists. Separate from
    /// `cachedImage(for:)` so Reduce Transparency toggles don't
    /// collide with the translucent cache entry.
    func cachedOpaqueImage(for sha: String) -> CGImage? {
        let url = opaqueCacheURL(for: sha)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return image
    }

    private func writeOpaqueCacheEntryBestEffort(image: CGImage, sha: String) {
        let url = opaqueCacheURL(for: sha)
        let pngUTI = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, pngUTI, 1, nil) else {
            NSLog("ChromeBakePipeline: opaque cache write to \(url.path) failed — CGImageDestination create")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            NSLog("ChromeBakePipeline: opaque cache write to \(url.path) failed — finalize")
        }
    }

    private func touchOpaqueCacheEntry(sha: String) {
        let url = opaqueCacheURL(for: sha)
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    /// Writes the PNG to cache. Per Req 5 + error-handling doc: a
    /// cache write failure logs and returns; the caller still has the
    /// in-memory CGImage and is not blocked.
    private func writeCacheEntryBestEffort(image: CGImage, sha: String) {
        let url = cacheURL(for: sha)
        let pngUTI = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, pngUTI, 1, nil) else {
            NSLog("ChromeBakePipeline: cache write to \(url.path) failed — CGImageDestination create")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            NSLog("ChromeBakePipeline: cache write to \(url.path) failed — finalize")
        }
    }

    /// Mark a cache entry as recently used so LRU eviction deprioritises
    /// it. Called on cache hit; noop on miss.
    private func touchCacheEntry(sha: String) {
        let url = cacheURL(for: sha)
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    // MARK: - LRU internals

    private struct CacheEntry {
        let sha: String
        let url: URL
        let sizeBytes: Int64
        let accessTime: Date
    }

    private func listCacheEntries() throws -> [CacheEntry] {
        guard fileManager.fileExists(atPath: cacheRoot.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var out: [CacheEntry] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "png" else { continue }
            let sha = url.deletingPathExtension().lastPathComponent
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            let time = values.contentModificationDate ?? .distantPast
            out.append(CacheEntry(sha: sha, url: url, sizeBytes: size, accessTime: time))
        }
        return out
    }
}

// `NSColor(hex:)` is defined in SkinContext.swift — this pipeline
// reuses that extension rather than re-declaring it.
