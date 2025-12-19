# Mini: Week 4 — Chat UI + Offline Resilience

## Context
You are completing Week 4 of Phase 1B for the Hologram project. This is an Electron app with a Three.js particle visualizer.

## Your Mission
Add 4 new services, offline handling UI, and security types.

## Read This First
**Detailed instructions:** `prompts/phase-1b-week4-prompt.md`

That file contains:
- Complete code for all 4 new services
- Updated IPC types
- HTML/CSS changes
- Step-by-step verification

## Quick Summary

### You're creating:
1. **ChatHistoryService** — Persist messages with electron-store
2. **OrchestratorService** — Load personality config
3. **NetworkService** — Detect online/offline, emit events
4. **SecurityService** — Risk assessment stub
5. **Offline UI** — Badge + disabled controls when offline

### Files to create:
- `src/main/services/chat-history.ts`
- `src/main/services/orchestrator.ts`
- `src/main/services/network.ts`
- `src/main/services/security.ts`
- `src/shared/security-types.ts`
- `config/personality.json`

### Files to modify:
- `src/shared/ipc-types.ts` — Add ChatMessage type, new IPC channels
- `src/shared/types.ts` — Export security types
- `src/main/index.ts` — Register all 4 services
- `src/renderer/index.html` — Add offline badge element
- `src/renderer/styles.css` — Add offline badge styles
- `src/renderer/chat.ts` — Subscribe to network events, update UI

---

## Step-by-Step Verification

After each step, verify it works:

1. **Install dependencies:**
   ```bash
   npm install electron-store
   ```

2. **Update IPC types** → `npm run build` should succeed

3. **Create security types** → TypeScript compiles

4. **Create ChatHistoryService** → Service logs on startup

5. **Create personality.json** → File exists in config/

6. **Create OrchestratorService** → Logs personality name on startup

7. **Create NetworkService** → Logs online/offline status

8. **Create SecurityService** → Service initializes

9. **Register all services in main/index.ts** → All 4 log during startup

10. **Add offline badge HTML/CSS** → Badge element exists (hidden)

11. **Update chat.ts** → Offline handling works

12. **Final verification:**
    ```bash
    npm run build && npm run lint && npm test
    ```

---

## Visual Success Criteria

When offline:
- Red "Offline" badge appears in top-right corner
- Send button disabled
- Chat panel slightly faded
- Status shows "Offline"
- Visualizer keeps animating (never stops!)

When online:
- Badge hidden
- Send button enabled
- Chat panel normal
- Status shows "Idle"

---

## IF STUCK — STOP AND ASK

Don't spend more than 10 minutes on any single error.

If blocked, create a question file or message with:
```
## BLOCKED: [Brief description]
**What I tried:** [List what you attempted]
**Error:** [Exact error message]
**Question:** [What you need to know]
```

Common issues:
- `electron-store` may need ESM import adjustments
- `net.isOnline()` requires Electron main process
- IPC channel names must match exactly

---

## Success Checklist

- [ ] `npm install electron-store` completes
- [ ] `npm run build` succeeds
- [ ] `npm run lint` passes
- [ ] `npm test` passes
- [ ] App opens, visualizer runs
- [ ] Console shows all 4 services initializing
- [ ] Disconnect WiFi → offline badge appears
- [ ] Reconnect WiFi → badge disappears
- [ ] Chat history persists across app restarts

---

Start with Step 1 in `prompts/phase-1b-week4-prompt.md`.

Good luck! 🛡️

