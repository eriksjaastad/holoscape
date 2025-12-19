# Spike 3 – Non-Rectangular Hit Testing

## Implementation
- Applied `clip-path: ellipse(45% 48% at 50% 50%)` to `#visualizer-root`, so the breathing sphere now renders inside a soft oval and the surrounding pixels are transparent.
- Added `#drag-handle` with `-webkit-app-region: drag` so the window can still be moved even though the native frame is gone.

## Test Results

### Click-through on transparent areas
- [ ] Clicks pass through to apps behind: NO  
  **Notes:** Clicking anywhere inside the clipped window, even in the fully transparent corners, still activates the Electron window. macOS continues to treat the entire window as opaque for hit-testing, so the clip-path only affects rendering, not mouse events.

### Dragging
- [x] Drag handle works: YES
- [x] Inside ellipse blocks drag: YES
- [ ] Outside ellipse behavior: still clickable (treated as window surface)

### Visual
- [x] Ellipse clips correctly: YES
- [x] Three.js renders inside clip: YES
- [x] No visual artifacts at edges: YES

## Verdict
**SPIKE 3: PARTIAL** — Clip-path works visually and the drag handle is functional, but transparent regions do not allow click-through on macOS. Because Electron still considers the full window as interactive, the test reveals a blocking issue: CSS clip-path alone cannot modify hit-testing behavior.

## Recommended Follow-up
- Investigate Electron’s `BrowserWindow.setIgnoreMouseEvents()` in tandem with the clip-path to make the transparent pixels truly click-through.
- Alternatively explore native-shaped windows or masking at the native layer if the CSS + `setIgnoreMouseEvents()` combo proves unreliable (especially across platforms).

