# Chrome Prototype — Laptop Visual Verification Checklist

**Task**: `claude-specs/chrome/tasks.md` Task 1.2, PRD §15 Risk #1 mitigation
**Goal**: Confirm AppKit honors per-pixel PNG alpha on a borderless `NSWindow`, gating the entire 20-PR PNG-chrome rollout.

Do this on the laptop against a bright, high-contrast desktop backdrop — a desktop wallpaper with strong color variation in the screen area where Holoscape will appear. The test fails if cut-corner pixels render dark instead of revealing the desktop.

## Procedure

1. **Desktop prep.** Set a bright, patterned wallpaper (the macOS default "Sequoia Sunrise" or any photo with visible detail works). Close other windows so the area where Holoscape will open is bare desktop.

2. **Build.**
   ```bash
   swift build -c debug
   ```

3. **Launch with the prototype flag.**
   ```bash
   HOLOSCAPE_PNG_CHROME_PROTOTYPE=1 swift run Holoscape
   ```
   Expected startup log: `[chrome-prototype] installed ChromeHostView (1000×700) with known_good_alpha.png`

4. **Screenshot: BEFORE.** Move the Holoscape window so it overlaps a known-bright region of the wallpaper. Screenshot the full screen (⌘⇧3). Save as `before-prototype.png` — this is the baseline without the prototype.
   - Actually: skip this. The BEFORE is "what the app looked like pre-PR" and any prior screenshot works. The AFTER is the only one that matters.

5. **Screenshot: AFTER.** With `HOLOSCAPE_PNG_CHROME_PROTOTYPE=1` running, window positioned over a bright desktop area, screenshot (⌘⇧3). Save as `after-prototype.png`.

6. **Inspection checklist.** Verify each of the following, by eye:
   - [ ] The window is a magenta (`#ff44cc`) rectangle with four 64×64-pixel cut corners.
   - [ ] The cut-corner regions (top-left, top-right, bottom-left, bottom-right triangles) show the desktop wallpaper through them — not black, not dark gray, not any opaque color.
   - [ ] The magenta fill is fully opaque — desktop does NOT bleed through the interior.
   - [ ] No window chrome (title bar, traffic lights, border) is visible.
   - [ ] No window shadow is visible around the magenta region.

7. **Quit.** ⌘Q. Remove the env flag for subsequent runs.

**Deferred to PR #3 (NOT a PR #1 pass criterion):** cut-corner click-through to the desktop. That behavior requires `ShapedContentView` + `HitRegionSampler` above `ChromeHostView`, which doesn't land until the full view graph ships in PR #3. The prototype installs `ChromeHostView` directly as the contentView, so clicks on transparent corners hit the window rather than passing through. Visual transparency (step 6) is the only PR #1 gate.

## Pass criteria

All checkboxes in step 6 check. The cut corners visibly reveal the desktop. No opaque bleed in the corners, no transparency in the interior.

## Fail modes to watch for

- **Cut corners render dark / opaque** — AppKit is not honoring per-pixel alpha on the chrome host's `layer.contents`. This is the Risk #1 failure that kills the architecture; stop and investigate (is the window style actually `.borderless`? is `isOpaque = false`? is there a parent view painting an opaque background?).
- **Everything is transparent including the interior** — alpha is being inverted or the fixture PNG is wrong. Re-run the Python generator and check the asserted alpha values in its output.
- **Window won't render at all** — `ChromeHostView` frame or `layer.contents` didn't attach; check the NSLog output for the `[chrome-prototype]` messages.
## On pass

Attach `after-prototype.png` to the PR as visual proof. Erik confirms in the PR comment: "Laptop visual check passed — cut corners transparent, interior opaque." PR #3 (ChromeHostView + InteriorView, including the polygon-sampler hit-test wiring) is cleared to start.

## On fail

Stop the rollout. Open a `docs/research/` note with the failure mode observed. The architectural assumption behind PRD §6 has failed and the whole plan needs re-evaluation — most likely candidate is a regression of the `CALayer.mask` descendant-background-bypass from Amplify v1, surfacing in a different guise.
