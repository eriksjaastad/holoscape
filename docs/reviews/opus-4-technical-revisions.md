Good question. Let me provide concrete technical revisions to make this roadmap executable. I'll focus on what would actually help developers ship this.

---

# Technical Roadmap Revisions

## 1. Add Phase 0.5: Technical Validation Spikes

**The roadmap jumps from "documentation complete" to "build Electron window." That's dangerous.** 

Three high-risk integrations need validation before committing to the full timeline:

```markdown
### Phase 0.5: Technical Spikes (1 week, before Phase 1)

**Goal:** Validate risky technical assumptions with throwaway prototypes

#### Spike 1: Transparent Window + Three.js Performance (2 days)
- [ ] Create minimal Electron app with:
  - `transparent: true, frame: false, vibrancy: 'ultra-dark'`
  - Three.js scene with 5,000 particles
  - Simple breathing animation (sin wave on positions)
- [ ] Measure on target hardware:
  - [ ] FPS (must hit 60fps sustained)
  - [ ] CPU % at idle (target: <5%)
  - [ ] Memory usage (target: <200MB)
  - [ ] GPU memory (target: <100MB)
- [ ] **GATE:** If targets not met, document what changes are needed before Phase 1

#### Spike 2: Streaming API + Visualizer State Sync (1 day)
- [ ] Extend spike 1 with:
  - OpenAI streaming call (hardcoded key, throwaway)
  - Visualizer state changes on: stream start, first token, stream end
- [ ] Verify no dropped frames during API activity
- [ ] **GATE:** If state sync causes jank, design buffering strategy

#### Spike 3: Non-Rectangular Window Hit Testing (1 day)
- [ ] Apply CSS clip-path to spike 1 window
- [ ] Test: Can you drag by the curved edges?
- [ ] Test: Does click-through work on transparent areas?
- [ ] Test: Does window shadow render correctly?
- [ ] **GATE:** If hit testing fails, determine if SVG mask or native approach needed
```

**Why this matters:** The entire project assumes these three things work well together. If they don't, the timeline and approach need to change. Find out in week 1, not week 12.

---

## 2. Restructure Phase 1: Foundation First, Features Second

**Current Phase 1 mixes infrastructure with features.** Split them:

```markdown
### Phase 1A: Development Infrastructure (Week 1-2)

#### Week 1: Project Scaffold
- [ ] TypeScript configuration:
  - [ ] `tsconfig.json` with strict mode
  - [ ] Separate configs for main/renderer/preload
  - [ ] Path aliases (`@/main`, `@/renderer`, `@/shared`)
- [ ] Build tooling:
  - [ ] Vite for renderer (faster than webpack)
  - [ ] esbuild for main process
  - [ ] electron-builder configuration
- [ ] Linting/formatting:
  - [ ] ESLint with TypeScript rules
  - [ ] Prettier configuration
  - [ ] Pre-commit hooks (husky + lint-staged)
- [ ] Testing infrastructure:
  - [ ] Vitest for unit tests
  - [ ] Playwright for E2E tests
  - [ ] Test file naming convention: `*.test.ts`, `*.e2e.ts`

#### Week 2: Core Architecture Scaffolding
- [ ] IPC bridge types:
  ```typescript
  // src/shared/ipc.ts
  export interface IPCChannels {
    'chat:send': { message: string; connectionId: string };
    'chat:response': { delta: string; done: boolean };
    'visualizer:state': { state: 'idle' | 'listening' | 'thinking' | 'locked' };
    'network:status': { online: boolean };
  }
  ```
- [ ] Preload script with typed contextBridge
- [ ] Main process service registry pattern
- [ ] Error boundary in renderer (React or vanilla)
- [ ] Logging infrastructure:
  - [ ] Structured logging (pino or winston)
  - [ ] Log levels from env var
  - [ ] Renderer logs forwarded to main via IPC

### Phase 1B: Window + Visualizer (Week 3-4)
[Current Phase 1 content, but with infrastructure already in place]
```

---

## 3. Define the Data Model Early

**The roadmap never specifies where state lives.** Add this to Phase 1:

```markdown
### Data Model Specification (Phase 1A, Week 2)

#### Conversation State
```typescript
// src/shared/types/conversation.ts
interface Message {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
  connectionId: string;
  metadata?: {
    model: string;
    tokens?: { input: number; output: number };
    latencyMs?: number;
  };
}

interface Conversation {
  id: string;
  connectionId: string;
  messages: Message[];
  createdAt: number;
  updatedAt: number;
}
```

#### Storage Strategy
- [ ] **In-memory:** Active conversation (renderer state)
- [ ] **SQLite:** Conversation history (main process, encrypted)
- [ ] **OS Keychain:** API keys only (via keytar)
- [ ] **electron-store:** User preferences (non-sensitive)

#### State Sync Pattern
- [ ] Renderer owns UI state
- [ ] Main process owns persistence
- [ ] IPC for state sync (not shared memory)
- [ ] Optimistic updates in renderer, confirmed by main
```

---

## 4. Reorder Security Layer to Phase 1

**Current problem:** Orchestrator in Phase 1, Security Layer in Phase 2. But Orchestrator routes through Security Layer.

**Fix:** Design Security Layer interfaces in Phase 1, implement in Phase 2.

```markdown
### Phase 1B: Security Layer Foundation (Week 4)

**Design only - no UI yet**

#### Risk Assessment Types
```typescript
// src/shared/types/security.ts
type RiskLevel = 'green' | 'yellow' | 'red';

interface ActionDescriptor {
  type: string;
  category: 'network' | 'filesystem' | 'shell' | 'browser';
  target?: string;
  riskLevel: RiskLevel;
}

interface SecurityAssessment {
  action: ActionDescriptor;
  riskLevel: RiskLevel;
  requiresAuthorization: boolean;
  reason?: string;
}
```

#### Action Catalog v0
```typescript
// src/main/security/actionCatalog.ts
const ACTION_RISK_MAP: Record<string, RiskLevel> = {
  // Network
  'network:chat': 'green',
  'network:api-call': 'yellow',
  
  // Filesystem (v1.0: read-only default)
  'fs:read': 'green',
  'fs:write': 'red',      // Disabled in v1.0
  'fs:delete': 'red',     // Disabled in v1.0
  
  // Shell (v1.0: disabled)
  'shell:execute': 'red', // Disabled in v1.0
};
```

#### Security Layer Interface
```typescript
// src/main/security/SecurityLayer.ts
interface SecurityLayer {
  assessRisk(action: ActionDescriptor): SecurityAssessment;
  isActionEnabled(actionType: string): boolean;
  requestAuthorization(action: ActionDescriptor): Promise<boolean>;
}
```

**Note:** Implementation happens in Phase 2. This is interface design only.
```

---

## 5. Add Error Handling Patterns

**The roadmap mentions "handle errors gracefully" but never specifies how.**

```markdown
### Error Handling Specification (Phase 1A, Week 2)

#### Error Types
```typescript
// src/shared/types/errors.ts
type ErrorCode = 
  | 'NETWORK_OFFLINE'
  | 'API_RATE_LIMITED'
  | 'API_AUTH_FAILED'
  | 'API_SERVER_ERROR'
  | 'API_TIMEOUT'
  | 'KEYCHAIN_ACCESS_DENIED'
  | 'UNKNOWN';

interface HologramError {
  code: ErrorCode;
  message: string;
  recoverable: boolean;
  retryAfterMs?: number;
  context?: Record<string, unknown>;
}
```

#### Error Flow
```
API Error → Adapter throws HologramError
         → Orchestrator catches, logs, decides retry
         → If not recoverable, sends to renderer via IPC
         → Renderer shows toast/inline error
         → Visualizer transitions to 'idle' (not 'error' state)
```

#### Retry Strategy
```typescript
// src/main/api/retry.ts
const RETRY_CONFIG = {
  maxAttempts: 3,
  backoffMs: [1000, 2000, 4000],
  retryableCodes: ['API_SERVER_ERROR', 'API_TIMEOUT', 'NETWORK_OFFLINE'],
  nonRetryableCodes: ['API_AUTH_FAILED', 'API_RATE_LIMITED'],
};
```
```

---

## 6. Make Offline Resilience Part of Phase 1

**Currently in "Technical Debt." Should be foundational.**

```markdown
### Phase 1B: Offline Resilience (Week 4)

**Required for "local-first" claim to be true**

#### Network Monitor
```typescript
// src/main/network/NetworkMonitor.ts
class NetworkMonitor {
  private online: boolean = true;
  
  constructor() {
    // Browser API (renderer context)
    window.addEventListener('online', () => this.setOnline(true));
    window.addEventListener('offline', () => this.setOnline(false));
    
    // Also ping actual endpoint (navigator.onLine can lie)
    setInterval(() => this.verifyConnectivity(), 30000);
  }
  
  private async verifyConnectivity(): Promise<void> {
    try {
      await fetch('https://api.openai.com/v1/models', { 
        method: 'HEAD',
        signal: AbortSignal.timeout(5000)
      });
      this.setOnline(true);
    } catch {
      this.setOnline(false);
    }
  }
}
```

#### Offline UI Behavior
- [ ] Visualizer continues breathing (no network dependency)
- [ ] Chat history remains scrollable/readable
- [ ] Send button disabled with tooltip: "Waiting for connection..."
- [ ] Subtle "Offline" badge in corner
- [ ] No error dialogs (graceful, not alarming)

#### Message Queueing (Basic)
- [ ] Failed sends stored in memory (not persisted in v1.0)
- [ ] On reconnect, show "Retry" button (don't auto-send)
- [ ] Queue cleared on app restart (v1.0 simplification)
```

---

## 7. Specify Three.js Architecture

**The roadmap says "implement breathing particle sphere" but doesn't specify how.**

```markdown
### Three.js Visualizer Architecture (Phase 1B, Week 3)

#### File Structure
```
src/renderer/visualizer/
├── Visualizer.ts          # Main class, owns Scene/Renderer
├── ParticleSystem.ts      # InstancedMesh + ShaderMaterial
├── shaders/
│   ├── particle.vert      # Vertex shader
│   └── particle.frag      # Fragment shader
├── states/
│   ├── IdleState.ts       # Blue, slow breathing
│   ├── ThinkingState.ts   # Purple, faster pulse
│   ├── ListeningState.ts  # Green, responsive
│   └── LockedState.ts     # Red, slow pulse
└── utils/
    └── particleGeometry.ts # Sphere point distribution
```

#### Performance Requirements
```typescript
// src/renderer/visualizer/config.ts
const VISUALIZER_CONFIG = {
  particleCounts: {
    low: 2_000,      // Intel integrated
    medium: 5_000,   // Discrete GPU
    high: 10_000,    // Apple Silicon
  },
  targetFps: 60,
  minAcceptableFps: 30,
  budgetMs: 8,       // Per frame
};
```

#### GPU-Based Animation (Required)
All animation MUST happen in vertex shader to avoid per-particle JS updates:

```glsl
// src/renderer/visualizer/shaders/particle.vert
uniform float uTime;
uniform float uBreathSpeed;
uniform float uBreathIntensity;
attribute float aPhase;  // Per-particle random offset

void main() {
  float breath = sin(uTime * uBreathSpeed + aPhase) * uBreathIntensity;
  vec3 pos = position * (1.0 + breath);
  // ... projection
}
```

#### State Transition Pattern
```typescript
// src/renderer/visualizer/Visualizer.ts
class Visualizer {
  private currentState: VisualizerState;
  private transitionProgress: number = 1.0;
  
  transitionTo(newState: VisualizerState, durationMs: number = 500): void {
    // Lerp between current and new state uniforms
    // Don't snap - always smooth transition
  }
}
```
```

---

## 8. Clarify Adapter Implementation Order

**Phase 2-3 interleaves adapters with other work. Be explicit about order:**

```markdown
### API Adapter Implementation Order

#### Phase 2: OpenAI First (Single Provider)
```typescript
// Complete before adding others:
src/main/api/
├── types.ts              # Shared interfaces
├── BaseAdapter.ts        # Abstract base class
├── adapters/
│   └── OpenAIAdapter.ts  # FULLY COMPLETE first
├── ConnectionManager.ts  # Works with one adapter
└── StreamingHandler.ts   # SSE parsing
```

#### Phase 3: Add Anthropic (Tests Abstraction)
```typescript
// If this is painful, abstraction is wrong:
src/main/api/adapters/
├── OpenAIAdapter.ts      # Already complete
└── AnthropicAdapter.ts   # Second adapter tests the abstraction
```

#### Phase 3: Add Custom Endpoint (Tests Extensibility)
```typescript
// If this is painful, extension model is wrong:
src/main/api/adapters/
├── OpenAIAdapter.ts
├── AnthropicAdapter.ts
└── CustomAdapter.ts      # Third adapter proves the pattern
```

**Rule:** Don't add adapter 2 until adapter 1 is complete AND tested. Don't add adapter 3 until adapter 2 works without changing base classes.
```

---

## 9. Add Testing Milestones

**The roadmap has no testing strategy. Add gates:**

```markdown
### Testing Requirements by Phase

#### Phase 1 Exit Criteria
- [ ] Unit tests for: IPC bridge, error types, security types
- [ ] E2E test: App launches, shows visualizer, closes cleanly
- [ ] Performance test: Visualizer holds 60fps for 60 seconds
- [ ] Coverage: 40%+ on `src/shared/` and `src/main/`

#### Phase 2 Exit Criteria
- [ ] Unit tests for: OpenAI adapter, keychain wrapper, streaming handler
- [ ] Integration test: Send message → receive streamed response
- [ ] E2E test: Full chat flow with mocked API
- [ ] Security test: API key never appears in logs
- [ ] Coverage: 60%+ on `src/main/api/`

#### Phase 3 Exit Criteria
- [ ] Unit tests for: All adapters, connection manager
- [ ] Integration test: Switch between connections mid-session
- [ ] E2E test: Offline → Online recovery flow
- [ ] Coverage: 60%+ on `src/main/`

#### Per-Phase Test Types
| Type | Tool | When Run |
|------|------|----------|
| Unit | Vitest | Pre-commit, CI |
| Integration | Vitest + mocks | CI only |
| E2E | Playwright | CI, pre-release |
| Performance | Custom benchmark | Weekly, pre-release |
```

---

## 10. Simplify Phase 4-7 (Defer Complexity)

**The current Phase 4 (GPU optimization) is over-specified for a project with no working code.**

```markdown
### Revised Phase 4: Performance Polish

**Only after core functionality works**

#### Week 13-14: Measure First
- [ ] Add performance monitoring overlay (dev mode only):
  - FPS counter
  - Frame time graph
  - Memory usage (JS heap + GPU via renderer.info)
- [ ] Run 24-hour soak test, log metrics every 60 seconds
- [ ] Identify actual bottlenecks (don't assume)

#### Week 15-16: Optimize Based on Data
- [ ] Address top 3 measured issues (not assumed issues)
- [ ] Document before/after for each optimization
- [ ] If no issues found, ship early and skip to Phase 5

**Delete from Phase 4:**
- Detailed particle optimization specs (premature)
- GPU memory management specs (implement if needed)
- Shader compilation tracking (nice-to-have)

**Why:** Don't optimize what you haven't measured. The current Phase 4 assumes problems that may not exist.
```

---

## Summary: Key Structural Changes

| Current Issue | Revision |
|---------------|----------|
| No technical validation before committing | Add Phase 0.5: Technical Spikes |
| Mixing infrastructure with features | Split Phase 1 into 1A (infra) and 1B (features) |
| No data model specification | Add data model + storage strategy to Phase 1A |
| Security Layer after Orchestrator | Design Security interfaces in Phase 1B |
| No error handling patterns | Add error types + retry strategy to Phase 1A |
| Offline in "Technical Debt" | Move to Phase 1B as foundational |
| Vague Three.js implementation | Add architecture + shader requirements |
| No testing milestones | Add exit criteria per phase |
| Over-specified optimization | Replace with "measure then optimize" |

---

## Revised Phase Summary

| Phase | Name | Duration | Key Deliverables |
|-------|------|----------|------------------|
| 0.5 | Technical Spikes | 1 week | Validated: performance, streaming, hit-testing |
| 1A | Infrastructure | 2 weeks | TypeScript, build tools, testing, IPC types |
| 1B | Foundation | 2 weeks | Window, visualizer, offline, security interfaces |
| 2 | Single AI | 4 weeks | OpenAI adapter, keychain, streaming, security impl |
| 3 | Multi-AI | 4 weeks | Anthropic, Custom, connection switching |
| 4 | Polish | 2-4 weeks | Measure, optimize only what's needed |
| 5+ | Aesthetics & Extensions | Variable | Non-rectangular, skins, MCP (only if core is solid) |

**Total (to MVP):** 15-17 weeks if spikes pass, core phases execute cleanly.