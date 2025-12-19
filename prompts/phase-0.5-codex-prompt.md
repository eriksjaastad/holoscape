# Phase 0.5: Technical Spikes - Prompt for GPT 5.1 Codex Mini

**Project:** Hologram (working title, may become "Aether")  
**Goal:** Complete Phase 0.5 technical validation spikes  
**Context:** This is a passion project — a desktop AI chat client with a particle visualizer that should look "impossible"

---

## Current State

The project already has:
- Electron app with transparent, frameless window (`transparent: true, frame: false, vibrancy: 'ultra-dark'`)
- Three.js particle sphere with breathing animation (two nested icosahedron point clouds)
- FPS/CPU/Memory metrics overlay
- Basic file structure in `/src/`

**Existing files:**
- `src/main.js` — Electron main process
- `src/renderer.js` — Three.js visualizer with metrics
- `src/index.html` — Canvas and metrics panel
- `src/styles.css` — Styling
- `src/preload.js` — Context bridge

---

## Your Tasks

### Spike 1: Performance Measurement (PARTIAL - needs completion)

The visualizer exists. Now we need to verify it meets targets.

**Tasks:**
1. Run the app and observe the metrics panel for 60+ seconds
2. Document the results:
   - FPS: Target is **60fps sustained** (30fps minimum acceptable)
   - CPU: Target is **<5% at idle**
   - Memory/Heap: Target is **<200MB**
3. If targets are NOT met:
   - Identify the bottleneck
   - Propose specific optimizations (e.g., reduce particle count, switch to InstancedMesh, move animation to shader)
4. Create a file `docs/spikes/spike-1-results.md` documenting:
   - Test hardware (Erik's machine specs if detectable, or note "developer machine")
   - Measured FPS/CPU/Memory
   - Pass/Fail for each target
   - Recommended optimizations if any

**Exit criteria:** Results documented, pass/fail determined

---

### Spike 2: Streaming API + Visualizer State Sync (BUILD THIS)

**Goal:** Add OpenAI streaming and sync visualizer state to API activity

**Tasks:**
1. Create `src/api/openai-stream.js`:
   - Export an async generator that streams responses from OpenAI
   - Use native fetch with ReadableStream (not axios)
   - Accept: API key (from env or hardcoded test key), messages array
   - Yield each token as it arrives
   - Handle errors gracefully

2. Create a simple test UI in `src/index.html`:
   - Add a text input and "Send" button below the visualizer
   - Input should be styled minimally (this is a spike, not final UI)

3. Wire up visualizer state changes:
   - **Idle** (blue, slow breathing) — default state
   - **Thinking** (purple, faster pulse) — when waiting for first token
   - **Speaking** (green/cyan, active movement) — while tokens are streaming
   - Return to Idle when stream completes

4. Implement state changes in `renderer.js`:
   - Create a `setVisualizerState(state)` function that changes:
     - Particle color (outer material)
     - Animation speed (breathing multiplier)
   - Expose this function globally: `window.setVisualizerState = setVisualizerState`

5. Test: Type a message, hit send, observe:
   - Visualizer goes purple (thinking)
   - Visualizer goes cyan (speaking) when tokens arrive
   - Visualizer returns to blue (idle) when done
   - FPS should NOT drop during streaming (no jank)

6. Document in `docs/spikes/spike-2-results.md`:
   - Does state sync work?
   - Any dropped frames during API activity?
   - If janky, what buffering strategy is needed?

**Technical notes:**
- Use `window.hologram` from preload for any IPC needed
- API key can be hardcoded for spike testing (we'll secure it in Phase 2)
- The streaming URL is `https://api.openai.com/v1/chat/completions` with `stream: true`

**Exit criteria:** Can send a message, see visualizer change states, receive streamed response

---

### Spike 3: Non-Rectangular Hit Testing (BUILD THIS)

**Goal:** Apply CSS clip-path and verify dragging still works on curved edges

**Tasks:**
1. Add a clip-path to the body or main container in `styles.css`:
   ```css
   body {
     clip-path: ellipse(48% 48% at 50% 50%);
     /* Or try a rounded organic shape */
   }
   ```

2. Test the following:
   - Can you drag the window by clicking near the curved edges?
   - Does click-through work on transparent areas outside the clip-path?
   - Does the visualizer render correctly inside the clipped area?

3. Try at least 2-3 different clip-path shapes:
   - Ellipse
   - Rounded polygon
   - Custom SVG-based path (if simple shapes fail)

4. Document findings in `docs/spikes/spike-3-results.md`:
   - Which shapes work?
   - Does hit-testing work correctly?
   - Any issues with the drag region (`-webkit-app-region: drag`)?
   - Recommendation: CSS clip-path vs SVG mask vs native approach?

5. If clip-path breaks dragging:
   - Document the issue
   - Propose alternatives (explicit drag handles, different masking approach)

**Exit criteria:** Non-rectangular window working OR blockers documented with alternatives

---

## File Structure to Create

```
docs/spikes/
├── spike-1-results.md   # Performance measurements
├── spike-2-results.md   # Streaming + state sync results
└── spike-3-results.md   # Clip-path + hit testing results

src/api/
└── openai-stream.js     # OpenAI streaming helper
```

---

## Important Constraints

1. **No external CDNs** — All assets must be bundled locally (Three.js is already in node_modules)
2. **No API key logging** — Never log API keys, even in test code
3. **Keep it simple** — This is a spike, not production code. Ugly is fine. Working is required.
4. **Document everything** — Results are as important as code. If something doesn't work, explain why.

---

## Success Criteria

Phase 0.5 is complete when:
- [ ] Spike 1: Performance targets validated OR optimization path documented
- [ ] Spike 2: Streaming works and visualizer changes state without jank
- [ ] Spike 3: Non-rectangular window renders and is draggable OR blockers documented

---

## Questions?

If you're unsure about something:
1. Make a reasonable choice and document it
2. Note alternatives you considered
3. Move forward — we can iterate

Don't block on perfection. Ship the spike.

---

*Prompt created: December 20, 2025*
*For: GPT 5.1 Codex Mini (mid-tier execution model)*
*Reviewed by: Claude Opus 4*

