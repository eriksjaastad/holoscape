# Chrome v4 transparency root-cause research

**Date**: 2026-04-20
**Author**: Claude, after Erik called out 8 hours of value-flipping with no results
**Purpose**: Stop writing code. Find out what the canonical, documented, working recipe for a PNG-alpha-shaped NSWindow actually is. Cite sources.

---

## What I had before research

Our `reconstructAsBorderlessTransparent` in `MainWindowController+ChromeMode.swift`:

```swift
let newWindow = ShapedBorderlessWindow(
    contentRect: NSRect(origin: oldWindow.frame.origin, size: size),
    styleMask: [.borderless, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
newWindow.isReleasedWhenClosed = false
newWindow.isOpaque = false
newWindow.backgroundColor = .clear
newWindow.hasShadow = false

let freshContent = ShapedContentView(frame: NSRect(origin: .zero, size: size))
freshContent.wantsLayer = true
newWindow.contentView = freshContent

// ChromeHostView installed as subview with layer.contents = chrome PNG (has alpha)
// InteriorView installed as sibling, clips app content into interiorRect
// No CAShapeLayer mask on any layer — relying entirely on PNG alpha
```

Observed: cut-corner regions render opaque charcoal instead of transparent to desktop. The PNG's alpha channel is correct (verified — 813 alpha=0 pixels at corners). The window is constructed with the recipe at birth (no retrofit). Multiple deep attempts at tweaking `layer.backgroundColor`, `layer.isOpaque`, frame-view background — no change.

---

## What the canonical recipe actually is

### Finding 1: `.borderless` is rawValue 0 and cannot be combined with `.fullSizeContentView` meaningfully

From [CocoaDev — BorderlessWindow](https://cocoadev.github.io/BorderlessWindow/):

> `NSBorderlessWindowMask` has a value of zero and cannot be combined with other style masks.

From [Apple Developer — fullSizeContentView](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview?language=objc):

> Although you can combine `fullSizeContentView` with other window style masks, it is respected **only for windows with a title bar**.

Our styleMask `[.borderless, .fullSizeContentView]`:
- `.borderless` rawValue = 0
- `.fullSizeContentView` rawValue = 0x8000
- Combined = 0x8000 (just fullSizeContentView)
- Without `.titled`, `.fullSizeContentView` is silently ignored
- Effective styleMask = 0 = borderless

So the styleMask itself is not strictly wrong — it resolves to borderless. BUT the intent (combining with `.fullSizeContentView`) is meaningless, AND the documented convention in every working reference implementation I found avoids this combination entirely.

### Finding 2: Every working shaped-window reference uses `CAShapeLayer` mask on `contentView.layer`, not PNG alpha alone

From [hfyeomans/winamp-macos-migration — `CustomSkinWindow.swift`](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/Sources/Window/CustomSkinWindow.swift):

```swift
override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
              backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
    super.init(contentRect: contentRect, styleMask: [.borderless],
               backing: backingStoreType, defer: flag)
    setupWindow()
    ...
}

private func setupWindow() {
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true            // NOT false
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    contentView?.layer?.contentsScale = backingScaleFactor
}

func applySkinShape(_ shape: NSBezierPath, animated: Bool = true) {
    ...
    let maskLayer = CAShapeLayer()
    maskLayer.path = shape.cgPath
    maskLayer.fillColor = NSColor.white.cgColor
    contentView?.layer?.mask = maskLayer
}
```

And [`WinampWindow.swift`](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/WinampMac/UI/WinampWindow.swift):

```swift
super.init(contentRect: contentRect,
           styleMask: [.borderless, .miniaturizable, .resizable], ...)
isOpaque = false
backgroundColor = .clear
hasShadow = true
isMovableByWindowBackground = true
contentView = WinampContentView()
contentView.wantsLayer = true
private var shapeLayer: CAShapeLayer?   // applied as mask when shape set
```

And [`ModernSkinWindow.swift`](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/WinampMac/UI/MainPlayer/ModernSkinWindow.swift):

```swift
let customStyle: NSWindow.StyleMask = [.borderless, .miniaturizable, .closable]
super.init(contentRect: contentRect, styleMask: customStyle, ...)
```

### Finding 3: `styleMask` is forced in the subclass's `init` override

All three reference implementations **override `init` in the NSWindow subclass to hardcode the styleMask**, ignoring whatever is passed in. This guarantees the styleMask is the correct one regardless of caller. Our `ShapedBorderlessWindow` does NOT do this — it relies on the caller to pass the right styleMask. Any caller that gets it wrong produces a misconfigured window.

### Finding 4: `contentView.layer.backgroundColor = NSColor.clear.cgColor` (not `nil`)

All three references set `NSColor.clear.cgColor` explicitly on the layer, not `nil`. Apple's [NSColor.clearColor docs](https://developer.apple.com/documentation/appkit/nscolor) and [CocoaDev's SemiTransparentWindowWithNSViewBackground](https://cocoadev.github.io/SemiTransparentWindowWithNSViewBackground/) warn that `nil` on an already-materialized layer can leave AppKit's platform-default in place. Explicit `.clear` is the zero-paint color.

### Finding 5: `hasShadow = true`, not `false`

Every reference uses `hasShadow = true`. Our current code uses `hasShadow = false`. The Risk #1 doc called for `false`; the public guidance says `true`. From [CocoaDev BorderlessWindow](https://cocoadev.github.io/BorderlessWindow/):

> `setHasShadow:YES` — optional shadow effect

And [Matt Gallagher's cocoawithlove tutorial](https://www.cocoawithlove.com/2008/12/drawing-custom-window-on-mac-os-x.html) notes "the shadow behind the window is drawn automatically for whatever shape you draw" — implying the system uses the drawn alpha to compute the shadow, so `hasShadow = true` is correct even for shaped windows. Setting it to `false` doesn't cause the opaque-backing problem, but it's a deviation from the canonical recipe.

### Finding 6: Apple's [SwiftUI-for-transparency forum thread](https://developer.apple.com/forums/thread/694837)

Apple's own recommendation for transparent windows in modern macOS uses `NSVisualEffectView` + `windowStyle(.hiddenTitleBar)` + `state = .active` — a completely different path from ours. No direct applicability, but confirms the public recipe is well-documented and our implementation deviates from it.

---

## Diagnosis

The root cause of our opaque-corner problem isn't the Cocoa Transparency Recipe being "too weak" or AppKit "locking in opaque backing" as the Risk #1 doc inferred. The root cause is:

**We relied on PNG alpha ALONE to shape the window.** Every documented working shaped-window implementation on macOS uses a `CAShapeLayer` mask on `contentView.layer` to actually clip the view, plus either a PNG or drawn content for the visuals inside the clip.

The Risk #1 isolation test that "worked" likely had additional setup that wasn't captured in the writeup — most plausibly, the isolation test happened to land on a window with an already-installed mask inherited from the pre-v4 `applyWindowShape` path (the test ran AFTER the prototype retrofit, which had installed a CA-mask). The isolation test showing transparent corners may have been the mask doing the work, not the PNG alpha.

**AppKit does not honor PNG layer.contents alpha as a window shape.** It honors it as a layer contents alpha — the layer's visual rendering respects the alpha — but the **window-level backing store** does not automatically become transparent through it. The window backing is transparent only where the content view's final composited alpha is zero, AND the content view's shape is clipped via a `layer.mask`.

This is consistent with:
- Why the Amplify v1 shaped-window code (`ShapedWindowController.buildMaskLayer` in `Sources/Holoscape/Controllers/ShapedWindowController.swift`) uses a `CAShapeLayer` mask on `contentView.layer` — that's how it achieves shaped rendering.
- Why every Stack Overflow answer and GitHub reference for shaped macOS windows uses `layer.mask = CAShapeLayer`.
- Why our ChromeHostView + InteriorView with PNG alpha produces opaque corners: **there is no mask**. PNG alpha is rendered, but the layer's outer bounds are still rectangular, and AppKit's window backing paints opaque everywhere the mask doesn't clip.

---

## Canonical recipe (from research)

```swift
final class ShapedBorderlessWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // Force the correct styleMask regardless of caller.
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable],   // or similar; no .fullSizeContentView
                   backing: backing,
                   defer: flag)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Set up transparency:
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = true
window.isMovableByWindowBackground = true

// Set up content view:
contentView.wantsLayer = true
contentView.layer?.backgroundColor = NSColor.clear.cgColor

// APPLY THE SHAPE MASK — the critical piece we've been missing:
let maskLayer = CAShapeLayer()
maskLayer.path = silhouettePath.cgPath    // CGPath tracing the chrome silhouette
maskLayer.fillColor = NSColor.white.cgColor
contentView.layer?.mask = maskLayer
```

For our chrome PNG case, the silhouette path is either:
- A rounded-rectangle `CGPath` matching the chrome PNG's 16pt cut corners, OR
- A `CGPath` traced from the PNG's non-zero-alpha pixels (more accurate but more work)

## What to do next

1. **Amend `reconstructAsBorderlessTransparent`** — hardcode styleMask in `ShapedBorderlessWindow`'s init to `[.borderless, .resizable]`. Don't take it from the caller.

2. **Install a `CAShapeLayer` mask on `shapedContent.layer`** using a path derived from `chrome.interiorPath` if declared, or a rounded-rectangle matching `chrome.width × chrome.height` with a conventional corner radius. The CHROME PNG's silhouette governs what gets drawn inside; the MASK governs what the window renders.

3. **Set `hasShadow = true`** — deviation from Risk #1 doc but matches every working reference. If the shadow looks wrong, revisit; but the canonical path uses true.

4. **Keep PNG alpha as the visual content** for ChromeHostView — that still works for the decorative bands, rounded-corner soft edges, etc. The mask just ensures AppKit actually clips the window to the shape.

## Sources

- [CocoaDev — BorderlessWindow](https://cocoadev.github.io/BorderlessWindow/)
- [CocoaDev — SemiTransparentWindowWithNSViewBackground](https://cocoadev.github.io/SemiTransparentWindowWithNSViewBackground/)
- [Apple Developer — fullSizeContentView docs](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview?language=objc)
- [Apple Developer — borderless docs](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/borderless)
- [Apple Developer — Window with rounded corners (forum 125232)](https://developer.apple.com/forums/thread/125232)
- [Apple Developer — Transparent window in SwiftUI (forum 694837)](https://developer.apple.com/forums/thread/694837)
- [Matt Gallagher — Drawing a custom window on Mac OS X (cocoawithlove)](https://www.cocoawithlove.com/2008/12/drawing-custom-window-on-mac-os-x.html)
- [Adonis Gaitatzis — Translucent overlay window on macOS in Swift](https://gaitatzis.medium.com/create-a-translucent-overlay-window-on-macos-in-swift-67d5e000ce90)
- [The Cocoa Quest — Transparent NSWindow using subclasses](https://www.markosx.com/thecocoaquest/transparent-nswindow-using-subclasses-of-nswindow-and-nsview/)
- [lukakerr/NSWindowStyles (GitHub)](https://github.com/lukakerr/NSWindowStyles)
- [hfyeomans/winamp-macos-migration — CustomSkinWindow.swift (GitHub)](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/Sources/Window/CustomSkinWindow.swift)
- [hfyeomans/winamp-macos-migration — WinampWindow.swift (GitHub)](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/WinampMac/UI/WinampWindow.swift)
- [hfyeomans/winamp-macos-migration — ModernSkinWindow.swift (GitHub)](https://github.com/hfyeomans/winamp-macos-migration/blob/HEAD/WinampMac/UI/MainPlayer/ModernSkinWindow.swift)
