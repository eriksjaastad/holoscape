# GPT Mini: Phase 1A Week 2 — Core Architecture

## Your Mission
Build the foundational patterns for type-safe IPC, service management, structured logging, and error handling.

## Important Context
- Week 1 is complete — TypeScript project with Vite/esbuild/ESLint/Vitest all working
- The app currently works: visualizer animates, chat streams, metrics display
- Your job is to add architectural patterns WITHOUT breaking existing functionality
- The detailed step-by-step instructions are in: `prompts/phase-1a-week2-prompt.md`

## What You're Building
1. **IPC Type System** — Type-safe channels for main ↔ renderer communication
2. **Service Registry** — Centralized lifecycle management for main process services
3. **Structured Logging** — Production-safe logging that never leaks sensitive data
4. **Error Handling** — Consistent error types with classification utilities

---

## How to Work

### Step 1: Read the detailed prompt
Open and read `prompts/phase-1a-week2-prompt.md` completely before starting.

### Step 2: Work through each step in order
The prompt has 8 numbered steps. Complete them sequentially:
1. IPC Types (`src/shared/ipc-types.ts`)
2. Typed Preload bridge
3. Service Registry (`src/main/services/index.ts`)
4. Logger Service (`src/main/services/logger.ts`)
5. Error Utilities (`src/shared/errors.ts`)
6. Update Main process
7. Update shared types index
8. Add error tests

### Step 3: Verify after each step
- After new files: `npm run typecheck` should pass
- After modifying preload: `npm run build:preload` should succeed
- After modifying main: `npm run build:main` should succeed
- After tests: `npm run test` should pass

---

## 🛑 IF YOU GET STUCK — STOP AND ASK

**Do NOT guess or make assumptions if you encounter:**

1. **Import path errors** — Path aliases (`@shared/`, `@main/`) may need adjustment
   - Document which file, which import, what error

2. **Type mismatches** — The existing code uses slightly different types
   - Stop and ask: "Should I update the existing code or adjust the new types?"

3. **Circular dependency warnings** — The type re-exports might cause issues
   - Document the exact error and which files are involved

4. **Logger not working** — Service registry integration might have issues
   - Capture console output and any errors

5. **Tests failing** — Error utility tests might need adjustment
   - Show the failing test and the actual vs expected output

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
- [ ] `npm run test` — All tests pass (including new error tests)
- [ ] `npm run build` — All bundles created
- [ ] `npm run dev` — App launches with service initialization logs in console:
  ```
  [timestamp] [INFO] [ServiceRegistry] Initialized: logger
  [timestamp] [INFO] [Main] App ready, initializing services
  [timestamp] [INFO] [Main] Creating main window
  ```
- [ ] Visualizer still animates
- [ ] Chat still streams responses
- [ ] Metrics overlay still works

---

## Files You'll Create
- `src/shared/ipc-types.ts`
- `src/shared/errors.ts`
- `src/shared/errors.test.ts`
- `src/main/services/index.ts`
- `src/main/services/logger.ts`

## Files You'll Modify
- `src/preload/index.ts`
- `src/main/index.ts`
- `src/shared/types.ts`

---

## Start Here
1. Read `prompts/phase-1a-week2-prompt.md`
2. Begin with Step 1 (IPC Types)
3. Work through all 8 steps
4. Run verification checks
5. Report completion or ask questions if blocked

Good luck! 🚀

