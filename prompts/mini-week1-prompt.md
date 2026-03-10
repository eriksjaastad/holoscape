# GPT Mini: Phase 1A Week 1 — Project Scaffold

## Your Mission
Convert the working JavaScript Electron app into a proper TypeScript project with build tooling, linting, and testing infrastructure.

## Important Context
- This is the Hologram project — a desktop AI chat client with a Three.js particle visualizer
- Phase 0.5 spikes are complete — the app already works (transparent window, streaming chat, metrics overlay)
- Your job is to add TypeScript + tooling WITHOUT breaking existing functionality
- The detailed step-by-step instructions are in: `prompts/phase-1a-week1-prompt.md`

## How to Work

### Step 1: Read the detailed prompt
Open and read `prompts/phase-1a-week1-prompt.md` completely before starting.

### Step 2: Work through each step in order
The prompt has 13 numbered steps. Complete them sequentially.

### Step 3: Verify after each major step
After completing each step, verify it works before moving on:
- After dependencies: `npm install` should succeed
- After TypeScript configs: `npx tsc --noEmit` should run (may have errors until files are converted)
- After file conversions: Check that imports resolve
- After scripts: Run each script to verify

---

## 🛑 IF YOU GET STUCK — STOP AND ASK

**Do NOT guess or make assumptions if you encounter:**

1. **Import errors you can't resolve** — Stop and document:
   - What file has the error
   - What import is failing
   - What you've tried

2. **Build failures you don't understand** — Stop and document:
   - The exact error message
   - Which step you were on
   - What the build command was

3. **Conflicting instructions** — Stop and ask:
   - "The prompt says X but the existing code does Y — which should I follow?"

4. **Missing context about existing code** — Stop and ask:
   - "I need to understand how X works before I can convert it"

5. **Decisions that could go multiple ways** — Stop and ask:
   - "Should I do A or B? Here are the tradeoffs..."

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
- [ ] `npm run test` — Vitest runs (placeholder test passes)
- [ ] `npm run build` — Creates `dist/` with main, preload, renderer bundles
- [ ] `npm run dev` — App launches with hot reload
- [ ] Visualizer animates smoothly (should still be ~120fps)
- [ ] Chat input sends messages and gets streaming responses
- [ ] Metrics overlay shows FPS/CPU/Heap

---

## Files You'll Create
- `tsconfig.json`, `tsconfig.main.json`, `tsconfig.preload.json`, `tsconfig.renderer.json`
- `vite.config.ts`, `vitest.config.ts`
- `.eslintrc.cjs`, `.prettierrc`, `.prettierignore`
- `src/main/index.ts`
- `src/preload/index.ts`
- `src/renderer/main.ts`
- `src/shared/types.ts`, `src/shared/types.test.ts`
- `src/api/openai-stream.ts`

## Files You'll Move/Convert
- `src/main.js` → `src/main/index.ts`
- `src/preload.js` → `src/preload/index.ts`
- `src/renderer.js` → `src/renderer/main.ts`
- `src/index.html` → `src/renderer/index.html`
- `src/styles.css` → `src/renderer/styles.css`
- `src/api/openai-stream.js` → `src/api/openai-stream.ts`

---

## Start Here
1. Read `prompts/phase-1a-week1-prompt.md`
2. Begin with Step 1 (Install Dependencies)
3. Work through all 13 steps
4. Run verification checks
5. Report completion or ask questions if blocked

Good luck! 🚀

## Related Documentation

- [Tiered AI Sprint Planning](patterns/tiered-ai-sprint-planning.md) - prompt engineering
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [[sales_strategy]] - sales/business
