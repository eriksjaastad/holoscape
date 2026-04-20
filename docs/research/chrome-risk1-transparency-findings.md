# Chrome PR #1 — Risk #1 Finding: Retrofit Doesn't Work, Reconstruct Does

**Date**: 2026-04-20
**Context**: First PR of the PNG-chrome 20-PR rollout (`claude-specs/chrome/tasks.md` Task Group 1). Gated by PRD §15 Risk #1 — "AppKit may not honor per-pixel alpha on `ChromeHostView`'s layer.contents when used as a window background."
**Outcome**: Risk #1 **is** cleared. AppKit does honor per-pixel PNG alpha on a borderless `NSWindow`. **But only when the window is constructed borderless + transparent from birth. Retrofit after init is impossible.**

---

## What we tried

PR #1's `applyPngChromePrototype()` in `MainWindowController.swift` took a shortcut: on the existing window already constructed with `[.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]`, at the end of `init()` we reconfigured it as `.borderless`, set `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, locked size to 1000×700, and swapped `contentView` to a `ChromeHostView` whose `layer.contents` was a known-good alpha PNG (1000×700 with 64-px cut corners, pixel-verified alpha 0 at corners and 255 in center).

## What we observed

A magenta rectangle rendered correctly in the window's rectangular bounding box. The 64-px cut-corner triangles rendered as **opaque dark charcoal** — NOT the desktop behind. Visual screenshot (`after-prototype-failed.png` attached to PR #147) showed: window over a light wallpaper, magenta interior opaque, cut corners dark. Alpha was present in the PNG, but AppKit composited the window's own opaque backing behind it.

## Diagnostics run

Runtime dump confirmed every property was configured correctly:

```
[chrome-prototype] frameView=NSNextStepFrame layer.backgroundColor=nil layer.isOpaque=false
[chrome-prototype] image alphaInfo=3 (last) size=1000x700
[chrome-prototype] pixel(0,0) RGBA=(0,0,0,0)          ← corner alpha 0 confirmed
[chrome-prototype] pixel(500,350) RGBA=(255,68,204,255) ← center opaque magenta
[chrome-prototype] window.isOpaque=false
[chrome-prototype] window.backgroundColor=Optional(Generic Gray 0 0)  ← .clear
[chrome-prototype] window.hasShadow=false
[chrome-prototype] styleMask=0  ← .borderless
```

All of this matches the Cocoa Transparency Recipe. All of it was correct at render time. And it still didn't work.

## The isolation test

In `applyPngChromePrototype()`, after reconfiguring the main window, we also constructed a **second**, freshly-built `NSWindow` from scratch using the same recipe — borderless from birth, never titled, never resizable, same ChromeHostView with the same PNG, set `.floating` level so Erik could see it distinctly from the main window.

**The isolation test window rendered cut corners as transparent.** The desktop showed through. Click-through routing worked (other windows covered the main app but couldn't cover the floating isolation window because of its `.floating` level — they sat beneath it).

The main window — configured identically at runtime by every documented property — continued to render opaque dark corners.

## The finding

**AppKit locks in opaque window backing at window construction time.** Setting `styleMask = [.borderless]`, `isOpaque = false`, `backgroundColor = .clear`, and `hasShadow = false` after the window has already been constructed with a titled style does NOT reverse that. Some internal state associated with `NSWindow`'s backing store (most likely the backing `CALayer` or `IOSurface` configured at birth for an opaque titled window) persists beyond property flips. The Cocoa Transparency Recipe requires borderless-from-birth; there is no retrofit path.

This explains why every previous attempt in the Amplify v1 investigation (`docs/research/shaped-window-transparency-findings.md`) to "fix transparency" by setting properties on the existing window ran into the same wall from a different angle. The descendant-background-bypass symptom on the CA-mask path was downstream of the real issue: the window's own backing was opaque because it was born that way.

## Implications for the Chrome MVP

**`claude-specs/chrome/design.md` Component 9 (`MainWindowController` Chrome_Mode_Branch) and `claude-specs/chrome/tasks.md` Task 13.1 both need amendment.** They currently call for "configuring" the window when `chrome` is declared. That must change to **constructing a new borderless `NSWindow`** and swapping the controller's window reference. The old window gets torn down cleanly (its delegate moved to the new one, `isReleasedWhenClosed = false` set so ARC doesn't double-release).

The requirement surfaces in Req 3.1 and must be added as an explicit AC: "the window is NEWLY CONSTRUCTED as borderless + transparent, not reconfigured from a titled predecessor."

Reverse case — when a v2/v3 skin without `chrome` loads after a v4 skin — needs the same treatment: construct a fresh titled window.

## Cost to the plan

Small. PR #5 (MainWindowController chrome-mode branch, currently Task 11 in `tasks.md`) absorbs the window-reconstruction work. The existing `ShapedBorderlessWindow` subclass (carried forward from Amplify v1, canBecomeKey/canBecomeMain overrides) is what the new window is instanced from. Delegate handoff + child-window migration + menu item / first responder continuity are the moving parts; none of them are novel. Estimated: 1/2 day added to PR #5's scope.

## Artifacts

- Failing screenshot: PR #147 comment attachment (main window, opaque dark corners).
- Passing screenshot: would attach from Erik's isolation-test observation if we had taken one; the floating pink window with transparent cut corners.
- Diagnostic log: `/tmp/holoscape-prototype.log` from the laptop run at 2026-04-20 00:22.
- Prototype code: `Sources/Holoscape/Controllers/MainWindowController.swift::applyPngChromePrototype` (on `main` behind `HOLOSCAPE_PNG_CHROME_PROTOTYPE=1`). Stays gated; retirement tracked in `claude-specs/chrome/tasks.md` final PR.

## Verdict

Risk #1 is cleared. Proceed with the 20-PR plan. The amendment below folds the reconstruct-not-retrofit finding into the spec so PR #5 implementers know to build this correctly the first time.
