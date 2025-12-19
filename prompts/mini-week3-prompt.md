# GPT Mini: Phase 1B Week 3 — Window Polish + Visualizer Enhancement

## Your Mission
Polish the Electron window with macOS integration and enhance the visualizer with GPU-based animation and smooth state transitions.

## Important Context
- Phase 0.5 spikes already built: transparent window, drag handle, particle sphere, streaming chat
- Phase 1A completed: TypeScript, service architecture, logging, error handling
- The app WORKS — your job is to enhance, not rebuild
- The detailed step-by-step instructions are in: `prompts/phase-1b-week3-prompt.md`

## What You're Building
1. **macOS Menu Bar** — Standard app menu with preferences, edit, view, window, help
2. **Global Hotkey** — Cmd+Shift+H to toggle window from anywhere
3. **GPU Shader Animation** — Move breathing animation to vertex shader
4. **Smooth State Transitions** — Interpolate color/speed between states
5. **Window Service** — Centralized window management
6. **New States** — Add 'listening' (orange) and 'error' (red) to visualizer

---

## How to Work

### Step 1: Read the detailed prompt
Open and read `prompts/phase-1b-week3-prompt.md` completely before starting.

### Step 2: Work through each step in order
1. macOS Menu (`src/main/menu.ts`)
2. Global Shortcuts (`src/main/shortcuts.ts`)
3. GPU Vertex Shader (update `src/renderer/visualizer.ts`)
4. Verify shared types have all states
5. Add window IPC channels
6. Create Window Service

### Step 3: Verify after each step
- After menu: App should show menu bar when focused
- After shortcuts: Cmd+Shift+H should toggle window
- After shader: Visualizer should still animate (test transitions)
- Final: All verification items pass

---

## 🛑 IF YOU GET STUCK — STOP AND ASK

**Do NOT guess or make assumptions if you encounter:**

1. **Shader errors** — GLSL has strict syntax
   - Copy the exact error from DevTools console
   - Note which line in the shader

2. **globalShortcut not registering** — macOS security
   - Check if app has Accessibility permissions
   - Document what `globalShortcut.register()` returns

3. **Menu not appearing** — Common Electron issue
   - Verify Menu.setApplicationMenu() is after app.whenReady()
   - Check if window is focused

4. **Color interpolation looks wrong** — THREE.Color quirks
   - Describe what the visual looks like
   - Note which transition (e.g., idle → thinking)

5. **TypeScript errors in shader code** — Template literal issues
   - Document the exact TS error

### Format for questions:
```
## BLOCKED: [Brief description]

**Step I'm on:** [Step number and name]

**What I was trying to do:**
[Description]

**What went wrong:**
[Error message or confusion]

**What I've tried:**
[List of attempts]

**My question:**
[Specific question for Opus]
```

---

## Success Criteria

When complete, ALL of these should work:

- [ ] `npm run typecheck` — No TypeScript errors
- [ ] `npm run lint` — ESLint passes
- [ ] `npm run build` — All bundles created
- [ ] `npm run dev` — Test interactively:

### Menu Bar
- [ ] "Hologram" menu appears in macOS menu bar
- [ ] About, Preferences, Quit work
- [ ] Edit menu has undo/redo/copy/paste
- [ ] View menu has reload/devtools/zoom
- [ ] Window menu has Show/Hide Hologram

### Global Hotkey
- [ ] Cmd+Shift+H hides window
- [ ] Cmd+Shift+H shows window (from any app)
- [ ] Window gets focus when shown

### Visualizer States
- [ ] **idle** — Cyan (#7efbff), slow breathing
- [ ] **thinking** — Purple (#ca79ff), medium breathing
- [ ] **speaking** — Green (#4dfdd1), fast breathing
- [ ] **listening** — Orange (#ffcc66), medium breathing
- [ ] **error** — Red (#ff6666), jittery breathing

### Smooth Transitions
- [ ] State changes smoothly interpolate color
- [ ] Breathing speed transitions smoothly
- [ ] No jarring pops between states

### Performance
- [ ] FPS still 60+ (GPU shader should help, not hurt)
- [ ] No visible frame drops during transitions

---

## Files You'll Create
- `src/main/menu.ts`
- `src/main/shortcuts.ts`
- `src/main/services/window.ts`

## Files You'll Modify
- `src/main/index.ts`
- `src/renderer/visualizer.ts`
- `src/shared/ipc-types.ts`

---

## Start Here
1. Read `prompts/phase-1b-week3-prompt.md`
2. Begin with Step 1 (macOS Menu)
3. Work through all 6 steps
4. Run verification checks
5. Report completion or ask questions if blocked

Good luck! 🚀

