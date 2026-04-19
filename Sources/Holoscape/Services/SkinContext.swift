import AppKit
import QuartzCore

/// The runtime object that chrome views query for their appearance.
///
/// Built once per skin load by `SkinEngine` from a `SkinDefinition` manifest.
/// Immutable after construction — all mutable state lives in the
/// `ReactiveUniformSnapshot` that drives state variant selection.
///
/// Chrome views call `currentState(for:)` each layout pass to get the
/// appearance for a surface, then `applyFill(to:from:)` and
/// `applyBorderAndCorner(to:from:)` to paint the underlying `CALayer`.
///
/// When no skin is loaded, `SkinContext.builtInDefaults(reactive:)` returns
/// a context whose surfaces all resolve to the pre-skinning hardcoded
/// colors — views render identically to the pre-skinning build.
@MainActor
final class SkinContext {

    // MARK: - Resolved appearance types

    struct ResolvedSurface {
        var fill: ResolvedFill
        var border: ResolvedBorder?
        var corner: ResolvedCorner
        var padding: NSEdgeInsets
        var shadow: ResolvedShadow?
        var font: NSFont?
        var text: ResolvedText
        var animation: ResolvedAnimation?
        /// State variants evaluated by `currentState(for:)`. The array is
        /// preserved verbatim from the manifest; evaluation reads from
        /// the reactive snapshot and applies overrides in CSS-cascade
        /// order (later matches overwrite earlier ones).
        var states: [StateVariant]
    }

    enum ResolvedFill {
        case color(NSColor)
        /// Image fill. The fourth associated value is Amplify Task 11's
        /// sprite metadata — non-nil when the manifest declared a
        /// `sprite: { ... }` alongside the image path AND descriptor
        /// validation passed (`SpriteDescriptor.isValid(imageSize:)`).
        /// When present, `applyFill` renders the cell matching the
        /// caller's `spriteState` via `layer.contentsRect` UV offset
        /// rather than cropping the NSImage per state. When nil, the
        /// image renders in its declared tile mode (stretch / tile /
        /// ninepatch).
        case image(NSImage, FillDescriptor.TileMode, NinepatchSidecar?, SpriteDescriptor?)
        case gradient(FillDescriptor.GradientDirection, [GradientStop])
    }

    struct ResolvedBorder {
        let color: NSColor
        let width: CGFloat
    }

    enum ResolvedCorner: Equatable {
        case uniform(CGFloat)
        case asymmetric(topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat)
    }

    struct ResolvedShadow {
        let color: NSColor
        let opacity: Float
        let blur: CGFloat
        let offset: CGSize
    }

    struct ResolvedText {
        let color: NSColor
        let shadow: ResolvedShadow?
    }

    struct ResolvedAnimation {
        /// Fallback curve applied when a per-property override is absent.
        let `default`: ResolvedCurve?
        let fill: ResolvedCurve?
        let corner: ResolvedCurve?
    }

    struct ResolvedCurve {
        let duration: CFTimeInterval
        let timingFunction: CAMediaTimingFunctionName
        let isSpring: Bool
    }

    // MARK: - Public state

    let surfaces: [SurfaceKey: ResolvedSurface]
    let reactive: ReactiveUniformSnapshot
    let fontRegistry: [String: CGFont]
    let imageCache: [String: NSImage]

    // MARK: - Construction

    init(
        surfaces: [SurfaceKey: ResolvedSurface],
        reactive: ReactiveUniformSnapshot,
        fontRegistry: [String: CGFont] = [:],
        imageCache: [String: NSImage] = [:]
    ) {
        self.surfaces = surfaces
        self.reactive = reactive
        self.fontRegistry = fontRegistry
        self.imageCache = imageCache
    }

    /// Build a SkinContext whose surfaces all use the built-in defaults
    /// (matching the pre-skinning hardcoded colors). Used when no skin
    /// is loaded so chrome views always have a context to query.
    static func builtInDefaults(reactive: ReactiveUniformSnapshot) -> SkinContext {
        var defaults: [SurfaceKey: ResolvedSurface] = [:]
        for key in SurfaceKey.allCases {
            defaults[key] = Self.defaultSurface(for: key)
        }
        return SkinContext(surfaces: defaults, reactive: reactive)
    }

    // MARK: - Resolution

    /// Return the base surface descriptor (state variants NOT applied).
    /// Falls back to the built-in default for keys not in the manifest.
    func resolve(_ key: SurfaceKey) -> ResolvedSurface {
        surfaces[key] ?? Self.defaultSurface(for: key)
    }

    /// Return the surface with matching state variants applied in CSS-cascade
    /// order (later matches overwrite earlier ones).
    func currentState(for key: SurfaceKey) -> ResolvedSurface {
        currentState(for: key, with: reactive)
    }

    /// Resolve `key` with state variants evaluated against an override
    /// `snapshot` instead of the context's shared one. Lets per-row
    /// views (sidebar tab entries) carry their own state — unread,
    /// notificationKind, connection state — and get correct
    /// per-row matching without polluting the shared snapshot.
    func currentState(for key: SurfaceKey, with snapshot: ReactiveUniformSnapshot) -> ResolvedSurface {
        var resolved = resolve(key)
        guard !resolved.states.isEmpty else { return resolved }
        for variant in resolved.states where evaluateMatch(variant.match, with: snapshot) {
            applyVariant(variant, to: &resolved)
        }
        return resolved
    }

    // MARK: - CALayer application

    /// Apply a resolved surface's fill to the given layer. Handles all three
    /// fill variants: `color` via `backgroundColor`, `image` via `contents`
    /// (with optional ninepatch `contentsCenter`), and `gradient` by
    /// inserting a dedicated `CAGradientLayer` sublayer.
    ///
    /// `backingScale` sets `layer.contentsScale` so image assets render
    /// crisply on Retina displays (Requirement 7.3). Callers that know
    /// the hosting window pass `view.window?.backingScaleFactor ?? 2.0`;
    /// the default of `2.0` is the correct assumption for modern Macs
    /// when the window isn't yet available.
    func applyFill(
        to layer: CALayer,
        from resolved: ResolvedSurface,
        backingScale: CGFloat = 2.0,
        spriteState: SpriteState = .normal
    ) {
        // Clear any previously installed gradient sublayer before reapplying.
        removeGradientSublayer(from: layer)

        layer.contentsScale = backingScale

        switch resolved.fill {
        case .color(let color):
            layer.backgroundColor = color.cgColor
            layer.contents = nil
            layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .image(let image, let tile, let ninepatch, let sprite):
            layer.backgroundColor = nil
            layer.contents = image
            if let sprite, Self.shouldRenderSprites(for: layer) {
                // Amplify Task 11 — sprite sheet. Full sheet goes into
                // layer.contents; layer.contentsRect picks the cell.
                // State transitions later only mutate contentsRect —
                // no per-state CGImage reallocation.
                applySpriteCell(sprite: sprite, state: spriteState, to: layer,
                                imageSize: image.size)
            } else {
                // Non-sprite image (or density == .minimal): fall back
                // to existing tile-mode path. Reset contentsRect to the
                // unit square so a prior sprite-cell UV doesn't leak.
                layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                applyTileMode(tile, ninepatch: ninepatch, to: layer, imageSize: image.size)
            }
        case .gradient(let direction, let stops):
            layer.backgroundColor = nil
            layer.contents = nil
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            insertGradientSublayer(direction: direction, stops: stops, into: layer)
        }
    }

    /// Compute + apply the UV rectangle for the current sprite state.
    ///
    /// Fallback chain (Requirement 5.3):
    ///   1. `stateMap[state]` present → use its cell
    ///   2. `stateMap["normal"]` present → use that
    ///   3. Otherwise → full sheet in stretch mode (unit contentsRect)
    ///
    /// The UV rect is `(col * cellW / imageW, row * cellH / imageH,
    /// cellW / imageW, cellH / imageH)`. `layer.contentsGravity` is
    /// `.resize` so the selected cell fills the layer bounds regardless
    /// of aspect ratio — consistent with how sprite-sheet buttons
    /// render in Winamp-style skins.
    private func applySpriteCell(
        sprite: SpriteDescriptor,
        state: SpriteState,
        to layer: CALayer,
        imageSize: CGSize
    ) {
        let key = state.rawValue
        let cell = sprite.stateMap[key]
            ?? sprite.stateMap[SpriteState.normal.rawValue]

        guard let cell else {
            // Neither state's cell nor `normal` is mapped — fall back
            // to full-sheet stretch. Documented behavior (Req 5.3).
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            layer.contentsGravity = .resize
            return
        }

        guard imageSize.width > 0, imageSize.height > 0 else {
            NSLog("SkinContext: sprite sheet has zero dimension (\(imageSize)); falling back to unit contentsRect")
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            layer.contentsGravity = .resize
            return
        }

        let u = CGFloat(cell.col * sprite.cellWidth) / imageSize.width
        let v = CGFloat(cell.row * sprite.cellHeight) / imageSize.height
        let w = CGFloat(sprite.cellWidth) / imageSize.width
        let h = CGFloat(sprite.cellHeight) / imageSize.height
        layer.contentsRect = CGRect(x: u, y: v, width: w, height: h)
        layer.contentsGravity = .resize
    }

    /// Amplify Task 11.6 — density-mode gate. Density `.minimal`
    /// suppresses sprite slicing and falls back to full-sheet stretch
    /// rendering (Req 5.6 / 11.2). `.full` or no manager attached =
    /// render sprites. Read via a layer-associated `DensityModeManager`
    /// reference; falls back to true (render) if no manager is wired.
    ///
    /// Method is static + layer-anchored so tests can flip the result
    /// without spinning up a full context. Production call path reads
    /// the manager from the SkinContext via an ambient property (set
    /// at MainWindowController wiring time).
    private static func shouldRenderSprites(for layer: CALayer) -> Bool {
        return Self.ambientDensityManager?.shouldRenderSprites() ?? true
    }

    /// Ambient density manager for sprite rendering. Set once by
    /// MainWindowController at init time (when the manager is constructed).
    /// A property-level reference rather than an instance property keeps
    /// applyFill's signature unchanged and lets per-surface sprite
    /// decisions use the same density state as the rest of the chrome.
    nonisolated(unsafe) static var ambientDensityManager: DensityModeManager?

    /// Apply border, corner radius, and shadow to the layer.
    func applyBorderAndCorner(to layer: CALayer, from resolved: ResolvedSurface) {
        if let border = resolved.border {
            layer.borderColor = border.color.cgColor
            layer.borderWidth = border.width
        } else {
            layer.borderColor = nil
            layer.borderWidth = 0
        }

        switch resolved.corner {
        case .uniform(let r):
            layer.cornerRadius = r
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .asymmetric(let tl, let tr, let br, let bl):
            // CALayer supports one radius per layer. For asymmetric corners
            // we approximate by picking the max and masking to the corners
            // that use it. True per-corner radii require a mask layer with
            // a bezier path — deferred until we see a skin that needs it.
            let maxRadius = max(max(tl, tr), max(br, bl))
            layer.cornerRadius = maxRadius
            var mask: CACornerMask = []
            if tl > 0 { mask.insert(.layerMinXMinYCorner) }
            if tr > 0 { mask.insert(.layerMaxXMinYCorner) }
            if bl > 0 { mask.insert(.layerMinXMaxYCorner) }
            if br > 0 { mask.insert(.layerMaxXMaxYCorner) }
            layer.maskedCorners = mask
        }

        if let shadow = resolved.shadow {
            layer.shadowColor = shadow.color.cgColor
            layer.shadowOpacity = shadow.opacity
            layer.shadowRadius = shadow.blur
            layer.shadowOffset = shadow.offset
        } else {
            layer.shadowOpacity = 0
        }
    }

    // MARK: - Match expression evaluation

    /// Evaluate a match expression against the current reactive snapshot.
    /// Multi-key matches are combined with logical AND. Unknown keys or
    /// operators are logged once and treated as non-matching.
    func evaluateMatch(_ expr: MatchExpression) -> Bool {
        evaluateMatch(expr, with: reactive)
    }

    func evaluateMatch(_ expr: MatchExpression, with snapshot: ReactiveUniformSnapshot) -> Bool {
        for (key, value) in expr.conditions {
            if !evaluateCondition(key: key, value: value, snapshot: snapshot) {
                return false
            }
        }
        return true
    }

    private func evaluateCondition(key: String, value: MatchValue, snapshot: ReactiveUniformSnapshot) -> Bool {
        // Special-case `timeSince` — the key is the JSON literal, the value
        // is a nested dict keyed by timestamp uniform name.
        if key == "timeSince" {
            guard case .timeSince(let nested) = value else { return false }
            return evaluateTimeSince(nested, snapshot: snapshot)
        }

        // All other keys read an Int32 scalar from the snapshot.
        guard let snapshotValue = snapshot.intValue(forMatchKey: key) else {
            // Unknown match key — log and skip (Requirement 12.3).
            NSLog("SkinContext: unknown match key '\(key)', skipping")
            return false
        }
        let snapshot = Double(snapshotValue)

        switch value {
        case .scalar(let target):
            return snapshot == target
        case .operators(let ops):
            for (op, target) in ops {
                if !applyOperator(op, snapshot: snapshot, target: target) {
                    return false
                }
            }
            return true
        case .timeSince:
            // timeSince appearing as value with a non-"timeSince" key is
            // malformed — treat as non-matching.
            NSLog("SkinContext: timeSince value under non-timeSince key '\(key)', skipping")
            return false
        }
    }

    /// Evaluate a `timeSince` expression. Nested dict keys are timestamp
    /// uniform names (e.g., `iTimeAgentStateChange`); values are the
    /// scalar-or-operators expressions to compare elapsed seconds against.
    private func evaluateTimeSince(_ nested: [String: MatchValue], snapshot: ReactiveUniformSnapshot) -> Bool {
        for (uniformName, condition) in nested {
            guard let stamp = snapshot.timestamp(named: uniformName) else {
                NSLog("SkinContext: unknown timestamp '\(uniformName)' in timeSince, skipping")
                return false
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - stamp
            switch condition {
            case .scalar(let target):
                if elapsed != target { return false }
            case .operators(let ops):
                for (op, target) in ops {
                    if !applyOperator(op, snapshot: elapsed, target: target) {
                        return false
                    }
                }
            case .timeSince:
                return false  // Nested timeSince inside timeSince is nonsense.
            }
        }
        return true
    }

    private func applyOperator(_ op: String, snapshot: Double, target: Double) -> Bool {
        switch op {
        case "$eq":  return snapshot == target
        case "$ne":  return snapshot != target
        case "$gt":  return snapshot >  target
        case "$gte": return snapshot >= target
        case "$lt":  return snapshot <  target
        case "$lte": return snapshot <= target
        default:
            NSLog("SkinContext: unknown operator '\(op)', skipping")
            return false
        }
    }

    // MARK: - State variant application

    private func applyVariant(_ variant: StateVariant, to resolved: inout ResolvedSurface) {
        if let fill = variant.fill {
            // Ninepatch limitation: state-variant image fills with tile mode
            // `ninepatch` get a nil sidecar here because SkinContext doesn't
            // currently store the ninepatches map alongside imageCache. No
            // shipped skin uses a state-variant image fill yet; if one does,
            // add a `ninepatches: [String: NinepatchSidecar]` property on
            // SkinContext alongside `imageCache` and thread it through at
            // both the init-time wiring (SkinEngine.loadComposite) and this
            // call site. Until then, the tile mode falls back to stretch
            // for state-variant image fills.
            if let converted = Self.convertFill(fill, imageCache: imageCache) {
                resolved.fill = converted
            }
        }
        if let border = variant.border, let converted = Self.convertBorder(border) {
            resolved.border = converted
        }
        if let corner = variant.corner {
            resolved.corner = Self.convertCorner(corner)
        }
        if let animation = variant.animation {
            resolved.animation = Self.convertAnimation(animation)
        }
        if let text = variant.text, let converted = Self.convertText(text) {
            resolved.text = converted
        }
    }

    // MARK: - Image / gradient / fill helpers

    private func applyTileMode(_ mode: FillDescriptor.TileMode, ninepatch: NinepatchSidecar?, to layer: CALayer, imageSize: CGSize) {
        switch mode {
        case .stretch:
            layer.contentsGravity = .resize
            layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .tile:
            // CALayer does not natively tile `contents`. True tiling requires
            // a CGPattern or a dedicated pattern layer — deferred until a skin
            // needs it. For now, log the degradation so skin authors see it
            // in Console.app and fall back to stretch.
            NSLog("SkinContext: tile mode not yet implemented, falling back to stretch")
            layer.contentsGravity = .resize
            layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .ninepatch:
            guard let sidecar = ninepatch, sidecar.isValid, imageSize.width > 0, imageSize.height > 0 else {
                // Fall back to stretch for invalid ninepatch (Requirement 7.5).
                layer.contentsGravity = .resize
                layer.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
                return
            }
            let x = CGFloat(sidecar.stretchX[0]) / imageSize.width
            let width = CGFloat(sidecar.stretchX[1] - sidecar.stretchX[0]) / imageSize.width
            let y = CGFloat(sidecar.stretchY[0]) / imageSize.height
            let height = CGFloat(sidecar.stretchY[1] - sidecar.stretchY[0]) / imageSize.height
            layer.contentsCenter = CGRect(x: x, y: y, width: width, height: height)
            layer.contentsGravity = .resize
        }
    }

    private static let gradientSublayerName = "holoscape.skin.gradient"

    private func removeGradientSublayer(from layer: CALayer) {
        layer.sublayers?.removeAll { $0.name == Self.gradientSublayerName }
    }

    private func insertGradientSublayer(direction: FillDescriptor.GradientDirection, stops: [GradientStop], into layer: CALayer) {
        // Parse each stop's hex; abort the gradient if any stop has an
        // invalid color (mismatched colors/locations produces undefined
        // CAGradientLayer output). Caller falls back to no fill, which
        // shows the layer's existing backgroundColor.
        var cgColors: [CGColor] = []
        for stop in stops {
            guard let color = NSColor(hex: stop.color) else {
                NSLog("SkinContext: gradient stop has invalid hex '\(stop.color)', falling back to solid color")
                return
            }
            cgColors.append(color.cgColor)
        }
        guard cgColors.count == stops.count else {
            NSLog("SkinContext: gradient color count mismatch (\(cgColors.count) vs \(stops.count) stops)")
            return
        }

        let gradient = CAGradientLayer()
        gradient.name = Self.gradientSublayerName
        gradient.frame = layer.bounds
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        gradient.colors = cgColors
        gradient.locations = stops.map { NSNumber(value: $0.offset) }
        switch direction {
        case .vertical:
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        case .horizontal:
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }
        layer.insertSublayer(gradient, at: 0)
    }

    // MARK: - Descriptor → ResolvedSurface conversion

    /// Convert a parsed `SurfaceDescriptor` from a skin manifest into the
    /// runtime `ResolvedSurface` used by chrome views. Missing fields fall
    /// back to the default for that surface key.
    ///
    /// `ninepatches` maps manifest image paths to their loaded `.ninepatch.json`
    /// sidecars. `SkinEngine.loadComposite` builds this map alongside the
    /// image cache so image fills with `tile: "ninepatch"` can resolve their
    /// stretch regions. Default empty dict keeps existing callers (tests,
    /// legacy apply path) compatible — they get `nil` sidecars which is
    /// the pre-wiring behavior.
    static func convert(
        _ descriptor: SurfaceDescriptor,
        for key: SurfaceKey,
        imageCache: [String: NSImage] = [:],
        ninepatches: [String: NinepatchSidecar] = [:]
    ) -> ResolvedSurface {
        var base = defaultSurface(for: key)
        if let fill = descriptor.fill,
           let converted = convertFill(fill, imageCache: imageCache, ninepatches: ninepatches) {
            base.fill = converted
        }
        if let border = descriptor.border, let converted = convertBorder(border) {
            base.border = converted
        }
        if let corner = descriptor.corner {
            base.corner = convertCorner(corner)
        }
        if let padding = descriptor.padding {
            base.padding = NSEdgeInsets(top: padding.top, left: padding.left, bottom: padding.bottom, right: padding.right)
        }
        if let shadow = descriptor.shadow, let converted = convertShadow(shadow) {
            base.shadow = converted
        }
        if let font = descriptor.font, let converted = convertFont(font) {
            base.font = converted
        }
        if let text = descriptor.text, let converted = convertText(text) {
            base.text = converted
        }
        if let animation = descriptor.animation {
            base.animation = convertAnimation(animation)
        }
        if let states = descriptor.states {
            base.states = states
        }
        return base
    }

    private static func convertFill(
        _ fill: FillDescriptor,
        imageCache: [String: NSImage],
        ninepatches: [String: NinepatchSidecar] = [:]
    ) -> ResolvedFill? {
        switch fill {
        case .color(let hex):
            guard let color = NSColor(hex: hex) else { return nil }
            return .color(color)
        case .image(let path, let tile, let sprite):
            // Amplify Task 11.2 — sprite descriptors validate at load
            // time. An invalid sprite (dimension mismatch, out-of-bounds
            // cell) is dropped here so the render path never has to
            // guard against it. `applyFill` receives sprite = nil and
            // falls back to the declared tile mode (stretch-mode fill).
            guard let image = imageCache[path] else {
                NSLog("SkinContext: image '\(path)' not in cache, fill falls back")
                return nil
            }
            let validatedSprite: SpriteDescriptor?
            if let sprite, sprite.isValid(imageSize: image.size) {
                validatedSprite = sprite
            } else {
                if sprite != nil {
                    NSLog("SkinContext: sprite descriptor for '\(path)' failed isValid(imageSize:); falling back to stretch")
                }
                validatedSprite = nil
            }
            // Ninepatch sidecar lookup — callers (SkinEngine.loadComposite)
            // populate the ninepatches dict keyed by the manifest image path.
            // A nil sidecar here is the legitimate "no sidecar file exists"
            // case; applyTileMode treats ninepatch-without-sidecar as the
            // stretch fallback.
            return .image(image, tile, ninepatches[path], validatedSprite)
        case .gradient(let direction, let stops):
            guard stops.count >= 2 else { return nil }
            return .gradient(direction, stops)
        }
    }

    private static func convertBorder(_ border: BorderDescriptor) -> ResolvedBorder? {
        guard let color = NSColor(hex: border.color) else { return nil }
        return ResolvedBorder(color: color, width: CGFloat(border.width))
    }

    private static func convertCorner(_ corner: CornerDescriptor) -> ResolvedCorner {
        switch corner {
        case .uniform(let r):
            return .uniform(CGFloat(r))
        case .asymmetric(let tl, let tr, let br, let bl):
            return .asymmetric(topLeft: CGFloat(tl), topRight: CGFloat(tr), bottomRight: CGFloat(br), bottomLeft: CGFloat(bl))
        }
    }

    private static func convertShadow(_ shadow: ShadowDescriptor) -> ResolvedShadow? {
        guard let color = NSColor(hex: shadow.color) else { return nil }
        return ResolvedShadow(
            color: color,
            opacity: Float(shadow.opacity),
            blur: CGFloat(shadow.blur),
            offset: CGSize(width: shadow.offsetX, height: shadow.offsetY)
        )
    }

    private static func convertFont(_ font: FontDescriptor) -> NSFont? {
        let size = CGFloat(font.size)
        if font.family.lowercased() == "system" {
            return NSFont.systemFont(ofSize: size)
        }
        return NSFont(name: font.family, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Runtime font resolution (Amplify Task 13)

    /// Resolve a surface's font at runtime, preferring skin-registered
    /// fonts (from `SkinEngine.registerFonts` CTFontManager process
    /// scope) before system lookup. Three-step fallback chain,
    /// guaranteed to terminate (Property 8):
    ///
    ///   1. `fontRegistry[family]` — skin-shipped font registered via
    ///      `CTFontManagerRegisterFontsForURL(_, .process, _)` at
    ///      skin-load time. Keyed by PostScript name.
    ///   2. `NSFont(name: family, size:)` — system-installed font
    ///      lookup. Handles built-in families like `"SF Mono"` or
    ///      `"Menlo"` that authors reference by name.
    ///   3. `NSFont.monospacedSystemFont(ofSize:weight:)` — guaranteed
    ///      fallback; never returns nil. Chrome views that call this
    ///      method always get a renderable font.
    ///
    /// Returns `nil` only when the surface has no FontDescriptor —
    /// chrome views interpret that as "keep the pre-Amplify hardcoded
    /// font" (don't overwrite).
    func resolvedFont(for key: SurfaceKey) -> NSFont? {
        guard let resolved = surfaces[key], let font = resolved.font else {
            // No surface defined, or surface defined without a font
            // descriptor. Caller preserves the pre-Amplify font.
            return nil
        }
        // `resolved.font` was populated at build time by `convertFont`,
        // which DOESN'T know about the registry. Redirect through the
        // registry lookup first. The FontDescriptor's family/size live
        // on the raw descriptor — but we've lost that at resolve time.
        // Use the font's postScriptName + size as the registry key and
        // fall through to the already-resolved font when no match.
        if let psName = font.fontDescriptor.postscriptName,
           let cgFont = fontRegistry[psName] {
            let size = font.pointSize
            let resolved = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            return resolved as NSFont
        }
        // Registry miss — keep the font convertFont already resolved
        // (NSFont(name:) or monospacedSystem fallback). Guaranteed
        // non-nil per convertFont's chain.
        return font
    }

    private static func convertText(_ text: TextDescriptor) -> ResolvedText? {
        guard let color = NSColor(hex: text.color) else { return nil }
        return ResolvedText(color: color, shadow: text.shadow.flatMap(convertShadow))
    }

    private static func convertAnimation(_ animation: AnimationDescriptor) -> ResolvedAnimation {
        return ResolvedAnimation(
            default: animation.default.flatMap(convertCurve),
            fill: animation.fill.flatMap(convertCurve),
            corner: animation.corner.flatMap(convertCurve)
        )
    }

    private static func convertCurve(_ curve: CurveDescriptor) -> ResolvedCurve {
        let duration = CFTimeInterval(curve.duration)
        switch curve.curve {
        case "linear":     return ResolvedCurve(duration: duration, timingFunction: .linear, isSpring: false)
        case "easeIn":     return ResolvedCurve(duration: duration, timingFunction: .easeIn, isSpring: false)
        case "easeOut":    return ResolvedCurve(duration: duration, timingFunction: .easeOut, isSpring: false)
        case "easeInEaseOut", "easeInOut":
            return ResolvedCurve(duration: duration, timingFunction: .easeInEaseOut, isSpring: false)
        case "spring":     return ResolvedCurve(duration: duration, timingFunction: .default, isSpring: true)
        default:           return ResolvedCurve(duration: duration, timingFunction: .default, isSpring: false)
        }
    }

    // MARK: - Built-in defaults

    /// Built-in default surface values matching the pre-skinning hardcoded
    /// view colors. Future refactor wires these per-surface from the
    /// existing view files; for now all surfaces share a neutral default
    /// so the absence of a skin doesn't crash.
    ///
    /// A handful of surfaces seed state variants that reproduce the old
    /// notification-state and connection-status colors (`sidebarRowNormal`
    /// picks up permission/idle/unread variants, `sidebarRowIndicator`
    /// picks up connection-state variants). Per-entry snapshots drive
    /// these so two sidebar rows can resolve to different colors at the
    /// same time.
    static func defaultSurface(for key: SurfaceKey) -> ResolvedSurface {
        let fill: ResolvedFill
        switch key {
        case .windowBackground, .windowTitleBar:
            fill = .color(NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
        case .tabBarContainer:
            fill = .color(NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0))
        case .tabBarTabActive:
            fill = .color(NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
        case .tabBarTabIdle:
            fill = .color(NSColor(red: 0.10, green: 0.22, blue: 0.12, alpha: 1.0))
        case .tabBarTabPermission:
            fill = .color(NSColor(red: 0.24, green: 0.16, blue: 0.08, alpha: 1.0))
        case .tabBarTabNormal, .tabBarTabUnreadMarker:
            fill = .color(NSColor.clear)
        case .sidebarContainer:
            fill = .color(NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0))
        case .sidebarRowNormal, .sidebarRowHover:
            fill = .color(NSColor.clear)
        case .sidebarRowSelected:
            fill = .color(NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
        case .sidebarRowIndicator:
            // Base is "active" green so an unmatched connection-state
            // variant still produces a visible dot (bug-visible rather
            // than silently invisible). Variants override for the
            // connecting and disconnected states.
            fill = .color(NSColor.systemGreen)
        case .sidebarSectionHeader:
            fill = .color(NSColor.clear)
        case .inputBoxContainer, .inputBoxField:
            fill = .color(NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1.0))
        case .inputBoxPlaceholder:
            fill = .color(NSColor.clear)
        case .sessionLauncherContainer:
            fill = .color(NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0))
        case .sessionLauncherRow:
            fill = .color(NSColor.clear)
        case .splitPaneDivider:
            fill = .color(NSColor.systemBlue.withAlphaComponent(0.6))
        case .terminalContainerPadding:
            fill = .color(NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
        case .settingsPanel, .dialogContainer:
            fill = .color(NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))

        // MARK: Amplify (v3) defaults
        //
        // The 13 v3 surfaces default to the nearest v2 pre-skinning color
        // so a v3 manifest that omits these keys renders identically to
        // the chrome-skinning build. Consumers that start reading these
        // surfaces (sprite-sheet chrome views, Reader Mode, shaped-window
        // drag handle) opt in per task group; until they do, these
        // defaults guarantee no visual regression.
        case .tabBarTabHover, .tabBarTabPressed:
            // Match tabBarTabActive hue so sprite-less v3 skins still
            // show a reasonable hover/pressed color. Sprite sheets
            // override via FillDescriptor.image(sprite:).
            fill = .color(NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
        case .sidebarRowPressed:
            // Darker sibling of sidebarRowSelected for press feedback.
            fill = .color(NSColor(red: 0.10, green: 0.10, blue: 0.20, alpha: 1.0))
        case .sessionLauncherButtonNormal:
            fill = .color(NSColor.clear)
        case .sessionLauncherButtonHover:
            fill = .color(NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
        case .sessionLauncherButtonPressed:
            fill = .color(NSColor(red: 0.10, green: 0.10, blue: 0.20, alpha: 1.0))
        case .readerPanelBackground, .readerPanelTitleBar:
            // Match window chrome so Reader Mode doesn't pop on first
            // present. ReaderModeController overrides when a v3 skin
            // declares reader surfaces (Task 17).
            fill = .color(NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0))
        case .readerPanelCloseButtonNormal:
            fill = .color(NSColor.clear)
        case .readerPanelCloseButtonHover:
            fill = .color(NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0))
        case .readerPanelCloseButtonPressed:
            fill = .color(NSColor(red: 0.10, green: 0.10, blue: 0.20, alpha: 1.0))
        case .windowShape, .windowDragHandle:
            // Non-rendering surfaces — windowShape carries the mask path
            // semantics, windowDragHandle carries drag-region cursor
            // semantics. Both return clear fills so a consumer that
            // accidentally paints them gets invisible output rather than
            // a visible default color bleeding through.
            fill = .color(NSColor.clear)
        }

        let text = defaultText(for: key)
        let states = defaultStates(for: key)

        return ResolvedSurface(
            fill: fill,
            border: nil,
            corner: .uniform(0),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: nil,
            text: text,
            animation: nil,
            states: states
        )
    }

    /// Built-in default text color — currently uniform (`.white`) except
    /// on the sidebar "normal" row where the pre-skinning label color is
    /// light gray. State variants override where needed.
    private static func defaultText(for key: SurfaceKey) -> ResolvedText {
        switch key {
        case .sidebarRowNormal, .sidebarRowHover:
            return ResolvedText(color: .lightGray, shadow: nil)
        default:
            return ResolvedText(color: .white, shadow: nil)
        }
    }

    /// Built-in state variants. Reproduces the pre-skinning per-row
    /// notification and connection-state colors so `SidebarTabEntry`
    /// can write `notificationKind`, `channelUnread`, and
    /// `channelConnectionState` into its own snapshot and let state
    /// resolution produce the right color.
    ///
    /// Notification kind mapping (matches design.md Requirement 12):
    ///   0 = none, 1 = info (idle prompt), 2 = warn (permission prompt),
    ///   3 = error (reserved).
    private static func defaultStates(for key: SurfaceKey) -> [StateVariant] {
        switch key {
        case .sidebarRowNormal:
            return [
                StateVariant(
                    name: "unread",
                    match: MatchExpression(conditions: [
                        "channelUnread": .operators(["$gte": 1]),
                    ]),
                    fill: .color("#1a1a38"),
                    text: TextDescriptor(color: "#ffffff", shadow: nil)
                ),
                StateVariant(
                    name: "idle",
                    match: MatchExpression(conditions: [
                        "notificationKind": .scalar(1),
                    ]),
                    fill: .color("#0d4019"),
                    text: TextDescriptor(color: "#66ff80", shadow: nil)
                ),
                StateVariant(
                    name: "permission",
                    match: MatchExpression(conditions: [
                        "notificationKind": .scalar(2),
                    ]),
                    fill: .color("#66400d"),
                    text: TextDescriptor(color: "#ffcc4d", shadow: nil)
                ),
            ]
        case .sidebarRowIndicator:
            // Base fill is systemGreen (active). No need for an "active"
            // variant — the absence of a match falls through to the
            // base, which IS the active color. Variants paint the two
            // non-default states.
            return [
                StateVariant(
                    name: "connecting",
                    match: MatchExpression(conditions: [
                        "channelConnectionState": .scalar(1),
                    ]),
                    fill: .color("#ffcc00")  // approximates NSColor.systemYellow
                ),
                StateVariant(
                    name: "disconnected",
                    match: MatchExpression(conditions: [
                        "channelConnectionState": .scalar(2),
                    ]),
                    fill: .color("#ff3b30")  // approximates NSColor.systemRed
                ),
            ]
        default:
            return []
        }
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    /// Parse `#rgb`, `#rgba`, `#rrggbb`, or `#rrggbbaa`. Returns nil for
    /// malformed input. Ignores leading `#` if present.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 4, 6, 8].contains(s.count), s.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let expanded: String
        if s.count == 3 {
            expanded = s.map { "\($0)\($0)" }.joined() + "ff"
        } else if s.count == 4 {
            expanded = s.map { "\($0)\($0)" }.joined()
        } else if s.count == 6 {
            expanded = s + "ff"
        } else {
            expanded = s
        }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let r = CGFloat((value >> 24) & 0xff) / 255.0
        let g = CGFloat((value >> 16) & 0xff) / 255.0
        let b = CGFloat((value >>  8) & 0xff) / 255.0
        let a = CGFloat( value        & 0xff) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
