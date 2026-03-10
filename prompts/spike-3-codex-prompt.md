# Spike 3: Non-Rectangular Hit Testing

**Goal:** Validate that we can create non-rectangular window shapes with proper mouse interaction.

## Context
- Spike 1 & 2 are complete — transparent window + Three.js visualizer + OpenAI streaming all work
- The app currently runs in a rectangular transparent window
- We want to support arbitrary shapes (circles, organic blobs, etc.) for skins
- This spike tests whether CSS `clip-path` works for visual clipping AND hit testing

## What You're Building

### Step 1: Add clip-path to the visualizer container

In `src/styles.css`, add a clip-path to `#visualizer-root` that creates a rounded/circular shape:

```css
#visualizer-root {
  /* existing styles... */
  clip-path: ellipse(45% 48% at 50% 50%);
}
```

This creates an oval that clips the visualizer. The transparent window background should show through the clipped areas.

### Step 2: Add a custom title bar for dragging

Since `frame: false` removes the native title bar, we need a draggable region. Add to `src/index.html`:

```html
<div id="drag-handle" style="-webkit-app-region: drag;"></div>
```

Style it in `src/styles.css`:
```css
#drag-handle {
  position: fixed;
  top: 0;
  left: 50%;
  transform: translateX(-50%);
  width: 120px;
  height: 24px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 0 0 12px 12px;
  -webkit-app-region: drag;
  cursor: grab;
  z-index: 1000;
}
```

### Step 3: Test click-through on clipped areas

The key question: Do mouse clicks pass through to the desktop on areas outside the clip-path?

**Test procedure:**
1. Run `npm run dev`
2. Position the window over another app (Finder, browser, etc.)
3. Click on the transparent area OUTSIDE the ellipse clip-path
4. **Expected:** Click should pass through to the app behind
5. **If it doesn't pass through:** Document this as a blocker

### Step 4: Test dragging behavior

1. Try dragging by the drag-handle → Should work
2. Try dragging by clicking inside the ellipse → Should NOT drag (we want interaction there)
3. Try dragging by clicking outside the ellipse → Document behavior

### Step 5: Document results

Create `docs/spikes/spike-3-results.md`:

```markdown
# Spike 3 – Non-Rectangular Hit Testing

## Implementation
- Applied `clip-path: ellipse(...)` to `#visualizer-root`
- Added `#drag-handle` with `-webkit-app-region: drag`

## Test Results

### Click-through on transparent areas
- [ ] Clicks pass through to apps behind: YES / NO / PARTIAL
- Notes: (describe behavior)

### Dragging
- [ ] Drag handle works: YES / NO
- [ ] Inside ellipse blocks drag: YES / NO  
- [ ] Outside ellipse behavior: (describe)

### Visual
- [ ] Ellipse clips correctly: YES / NO
- [ ] Three.js renders inside clip: YES / NO
- [ ] No visual artifacts at edges: YES / NO

## Verdict
**SPIKE 3: PASSED / FAILED / PARTIAL**

If failed, recommended approach: (SVG mask / native approach / other)
```

## Files to modify
- `src/styles.css` — Add clip-path and drag-handle styles
- `src/index.html` — Add drag-handle element
- `docs/spikes/spike-3-results.md` — Create with test results

## Success criteria
- Ellipse visually clips the visualizer
- Drag handle allows window movement
- Click-through behavior is documented (pass or fail, we just need to know)

## If click-through doesn't work
This is expected on some platforms. Document the issue and note that we may need:
1. **SVG mask approach** — More complex but cross-platform
2. **setIgnoreMouseEvents()** — Electron API for programmatic hit testing
3. **Native window shape** — Platform-specific but most reliable

The goal of this spike is to LEARN what works, not necessarily to solve it completely.


## Related Documentation


