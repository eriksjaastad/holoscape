# Hologram Development Roadmap

**Building a white-label AI Agent Operating System with soul**

---

## Vision

Create a desktop AI interface that:
- Supports **all major AI APIs** (OpenAI, Anthropic, Google, custom endpoints)
- Features **Sonique-inspired aesthetic** (biomorphic, kinetic, non-rectangular)
- Uses **Orchestrator Architecture** (Hub & Spoke - Cortana commands specialist sub-agents)
- Includes **MCP Support** for drag-and-drop skills
- Implements **Security Layer** with Green/Yellow/Red permission scopes
- Includes **full skin replacement system** (changes appearance AND personality)
- Integrates **hologram visualizer** (Three.js - always breathing, never frozen)
- Works as **menu bar app** with hotkey activation
- Treats **Cortana as one connection** among many
- **Local-only, zero telemetry** - users bring their own API keys

---

## Core Principles

### Product Stance
- **Local-first:** No cloud dependency for core functionality
- **Zero telemetry:** No analytics, crash reporting, or usage pings by default
- **User-owned keys:** Users supply their own API keys, stored in OS keychain
- **Direct connections:** App talks directly to provider endpoints (no relay servers)
- **Transparent network:** All network destinations are user-configured and visible
- **No background calls:** No automatic update checks, no phone-home, manual "Check for updates" only
- **Trust promise:** "No account. No cloud dependency. No background network calls. All network destinations are user-configured and visible."

### Trust & Security
- **API keys in OS keychain** (macOS Keychain, Windows Credential Manager)
- **Signed releases** with checksums
- **No logs with sensitive data** (keys never appear in logs)
- **Panic button:** One-click "Delete all keys"
- **Permission system:** Green/Yellow/Red risk levels with explicit authorization

### Design Philosophy
- **"The Window is a Lie"** (Sonique principle) - No rectangular constraints
- **Cool > Efficiency** - Revolutionary tech deserves revolutionary design
- **Visualizer NEVER stops** - Always breathing, even when idle
- **Build Orchestrator NOW** - Even if single path initially
- **The Mantra:** "If Sonique could make an MP3 player look like alien technology in 1999, we can make an AI interface look magical in 2025."

---

## ⚠️ Critical Reading: Engineering Counterpoint

**Before investing time in this project, read the "Critical Counterpoint: Engineering Concerns" section in [`docs/IMPLEMENTATION_DIRECTIVES.md`](docs/IMPLEMENTATION_DIRECTIVES.md).**

That section raises serious concerns about the "Cool > Efficiency" philosophy, technical red flags, and what's missing from this project's planning. This roadmap and the counterpoint should be read together.

### Additional Concerns Specific to This Roadmap

**1. The "7 AI Reviews with Unanimous Consensus" Is Not Validation**

This roadmap cites agreement from 7 AI models as evidence the architecture is sound. This reasoning is flawed:

- **AI models tend to agree with well-structured prompts.** If you present a detailed, internally-consistent vision, AI models will generally affirm it. They're optimized to be helpful, not to challenge fundamental assumptions.
- **Consensus ≠ correctness.** Seven AI models agreeing doesn't mean the timeline is realistic, the technical approach is sound, or the product will find users. It means the documents are coherent.
- **No AI model said "don't build this."** That should be a yellow flag. Real technical review includes "this might not be worth doing" as a possible conclusion.
- **The reviews validated internal consistency, not external viability.** Whether users want a Sonique-inspired AI chat client in 2025 is a market question, not an architecture question.

The phrase "unprecedented consensus" appears in the session logs. Unprecedented agreement from AI models reviewing AI-generated architecture documents is not unprecedented — it's expected.

**2. Three Pivots on Day 1 Predicts Scope Instability**

From the session log:
> "The pivot happened THREE times: Morning: Cortana interface → Sonique-inspired design. Afternoon: White-label AI client. Evening: Agent Operating System."

This pattern — expanding scope during planning rather than constraining it — typically continues into implementation. The 42-52 week timeline assumes the vision stabilizes. If it keeps expanding (as Day 1 suggests it will), the timeline becomes meaningless.

**3. Documentation-to-Code Ratio Is Inverted**

Current state:
- ~4,800 lines of documentation
- ~100 lines of actual code
- Ratio: **48:1**

Healthy projects typically have the inverse — more code than docs. Extensive upfront documentation often indicates:
- Analysis paralysis
- Premature optimization of architecture
- Avoidance of the hard work of implementation
- A vision that's easier to describe than to build

The existence of detailed GPU memory management specs (Phase 4) before a single Three.js line has been written suggests planning has outpaced reality-testing.

**4. Success Criteria Are Unfalsifiable**

From this document's success criteria:
- "A screenshot looks 'impossible'"
- "Users say 'this is the coolest thing I've ever seen'"
- "Feels like talking to the future"

These cannot be objectively measured, which means the project can never definitively fail — or succeed. This protects the vision from reality but makes it impossible to know when to stop, pivot, or ship.

---

## Security & Privacy Checklist (Built-in from Day 1)

These are **mandatory** requirements that must be maintained throughout development:

### 🔐 Data & Privacy
- [ ] **No telemetry by default** - No analytics, crash reporting, or usage pings
- [ ] **No cloud dependency** - Core app works offline
- [ ] **Direct API connections** - No relay servers between user and providers
- [ ] **No remote assets** - No CDNs, external fonts, or marketplace thumbnails (unless explicit opt-in)
- [ ] **Clear network policy** - Document all network calls, make them user-visible

### 🔑 API Key Management
- [ ] **OS keychain storage** - macOS Keychain, Windows Credential Manager
- [ ] **Never log keys** - Keys never appear in logs, console, or error dialogs
- [ ] **Masked display** - UI fields showing keys masked by default
- [ ] **Panic button** - One-click "Delete all keys" feature
- [ ] **Local-only mode** - Obvious indicator when in local-only mode

### 🛡️ Security Fundamentals
- [ ] **Signed releases** - macOS notarization / Windows code signing
- [ ] **Checksums published** - SHA-256 hashes for all releases
- [ ] **Permission system** - Green/Yellow/Red risk levels implemented
- [ ] **Red Switch UI** - High-risk actions require explicit authorization
- [ ] **Sandbox for plugins** - If plugins added, constrained API with explicit permissions

### 📦 Updates & Extensibility
- [ ] **Manual updates** - No auto-update phoning home (or make it explicit opt-in)
- [ ] **Skins are safe** - Visual assets only, no arbitrary code execution
- [ ] **Plugin permissions** - If plugins supported, clear UI showing what they can access
- [ ] **Offline capable** - Core features work without network

### 📄 Documentation & Trust
- [ ] **Security statement** - Plain English "Security and Privacy" page
- [ ] **Public wording** - "No account. No cloud. No telemetry. Keys stored locally."
- [ ] **Release page** - Clear changelog, download links, checksums
- [ ] **Open source option** - Consider open-sourcing key-handling and network code

---

## Development Phases

### Phase 0: Foundation & Security Design ✅ COMPLETE
**Status:** ✅ Complete (December 19, 2025)  
**Goal:** Documentation, architecture planning, security model design

#### Completed:
- [x] Project structure created
- [x] Core vision documented
- [x] Sonique research completed
- [x] Three.js visualizer code obtained
- [x] Orchestrator architecture designed
- [x] API abstraction layer designed
- [x] Security & legal concerns documented
- [x] Security checklist integrated into roadmap
- [x] Finalize Phase 0 documentation
- [x] Get advisor feedback on roadmap (7 AI reviews completed!)
- [x] Set up Git repository
- [x] Initialize npm/Electron project
- [x] First successful Electron app launch
- [x] Milestone tracking system created

#### Deferred to Later Phases:
- [ ] Document skin format specification (Phase 7 pre-work)

**Security Focus:** Design privacy-preserving architecture from day one ✅

**Achievement:** Roadmap reviewed and approved by 7 different AIs with unprecedented consensus on architecture and security model.

**Next:** Phase 1 - Foundation, Security & Offline Resilience

---

### Phase 1: Foundation, Security & Offline Resilience
**Goal:** Transparent window with security foundation and offline resilience

#### Week 1-2: Electron Foundation + Router + Security Foundation
- [ ] Initialize Electron project with security config
  - `frame: false, transparent: true, vibrancy: 'ultra-dark'`
  - Content Security Policy configured
  - No remote content loading
- [ ] Create frameless, transparent window
- [ ] Add custom drag handles (`-webkit-app-region`)
- [ ] Implement macOS menu bar integration
- [ ] Set up global hotkey (show/hide)
- [ ] **Build Router layer with security hooks** (intent classifier)
  - [ ] **Local intent classification** (regex/keyword patterns for offline operation)
  - [ ] Define pattern libraries for Red/Yellow/Green actions
  - [ ] Fallback to cloud LLM for ambiguous cases (when online)
  - [ ] Queue ambiguous cases for cloud analysis when reconnected
  - [ ] **Critical:** Security assessment must work 100% offline
- [ ] **Build Security Layer foundation:**
  - [ ] Define RiskLevel enum (Green/Yellow/Red)
  - [ ] Define Action interface with risk mapping
  - [ ] **Create Action Catalog v0** (explicit list of all possible actions):
    - Network calls (model API requests) → Green/Yellow based on provider
    - Filesystem reads → Green (read-only safe)
    - Filesystem writes → Yellow (creates files)
    - Filesystem deletes → Red (destructive)
    - Shell execution → Red (dangerous, v1.0 disabled by default)
    - Browser automation → Yellow (web requests, v1.0 basic only)
    - **v1.0 ships with only network + filesystem reads enabled by default**
  - [ ] Create SecurityLayer.assessRisk() signature
  - [ ] Document risk classification for planned actions
  - [ ] Design "Red Switch" state machine
- [ ] Test window positioning and sizing
- [ ] **Security Check:** Verify no external network calls
- [ ] **Security Check:** Verify Three.js will be bundled locally (no CDN)
- [ ] **Security Check:** Verify Router can classify intents offline (no LLM required for basic patterns)

#### Week 3-4: Three.js Visualizer + Orchestrator Stub + Offline Resilience
- [ ] Set up Three.js in Electron
- [ ] Implement breathing particle sphere
- [ ] Create visualizer states (Idle/Listening/Thinking/Locked)
- [ ] **Implement Orchestrator stub** (personality from config, NO sub-agent dispatch yet)
- [ ] **Load system prompt from `config/personas/cortana.json`**
- [ ] Build basic chat UI (simple first, Sonique-ify later)
- [ ] Add message input/output
- [ ] Implement idle animation loop (NEVER static)
- [ ] **Offline Resilience (CRITICAL):**
  - [ ] Implement network status detection (navigator.onLine + ping test)
  - [ ] Add "Offline" indicator in UI (subtle badge/icon)
  - [ ] Visualizer continues running offline (no network dependency)
  - [ ] Chat history remains accessible (read-only from local storage)
  - [ ] Disable send button with "Waiting for connection..." tooltip
  - [ ] Queue failed messages for retry on reconnection
  - [ ] Test: Disconnect WiFi, verify app doesn't crash
  - [ ] Test: Verify visualizer + history work offline
- [ ] **Security Check:** Verify visualizer doesn't leak data
- [ ] **Security Check:** Offline mode doesn't expose keys in logs

**Milestone:** Transparent window with breathing hologram + security foundation + offline resilience

**Security Review:**
- [ ] No telemetry in build
- [ ] No external asset loading
- [ ] Visualizer runs without network
- [ ] Security Layer foundation exists (sub-agent dispatch in Phase 3)
- [ ] App gracefully degrades offline (doesn't crash)
- [ ] Orchestrator stub loads personality correctly

---

### Phase 2: Single AI Connection + Complete Security Layer
**Goal:** Connect to one AI with full security architecture

#### Week 5-6: Keychain + OpenAI Integration + Security Hardening
- [ ] **Implement OS keychain storage** (keytar or equivalent)
- [ ] Create API key input UI (masked by default)
- [ ] **Add "Rotate key" button** (delete old, prompt for new)
- [ ] **Never log API keys** (audit all logging code)
- [ ] **Implement request/response logging** (sanitized - no keys, log errors)
- [ ] **Add log rotation** (max 10MB, 7 days retention, auto-purge)
- [ ] **Add "Clear logs" button** in Settings
- [ ] Build OpenAI adapter (direct connection)
- [ ] Send message → get response
- [ ] Display response in chat window
- [ ] **Implement auto-save conversation state** (crash recovery)
- [ ] **Add conversation encryption** (OS keychain-derived key)
- [ ] **Add conversation size limit** (max 10MB, auto-prune old messages)
- [ ] **Add "Clear history" button** in Settings
- [ ] **Security Check:** Keys never in logs/console
- [ ] **Security Check:** Conversation encryption works

#### Week 7-8: Complete Security Layer + Permission System
- [ ] **Implement complete Security Layer** (risk assessment engine)
- [ ] **Create Permission Scope UI** (Green/Yellow/Red visual indicators)
- [ ] **Build "Red Switch" authorization UI** (Sonique drawer style)
- [ ] **Integrate Security Layer with Router** (all actions pass through security)
- [ ] Implement SSE streaming for OpenAI
- [ ] Display tokens as they arrive
- [ ] Add loading/thinking indicators (visualizer state changes)
- [ ] Handle errors gracefully (no key leaks in errors)
- [ ] **Add "Delete all keys" panic button**
- [ ] **Implement PII detection in logs** (strip sensitive patterns)
- [ ] Test with various prompts and edge cases
- [ ] **Test:** Intentionally trigger errors, verify keys not in logs

**Milestone:** Can chat with GPT-4o in real-time. Complete Security Layer blocks high-risk actions.

**Security Review:**
- [ ] Keys stored in OS keychain only
- [ ] Keys never appear in UI (unless explicitly shown)
- [ ] Keys never in error messages or logs
- [ ] Permission system works (Green/Yellow/Red)
- [ ] Red actions require explicit authorization
- [ ] Panic button wipes all keys
- [ ] Conversations encrypted at rest
- [ ] Logs sanitized and rotated
- [ ] PII detection prevents sensitive data leaks

---

### Phase 3: Multi-AI Support + First Sub-Agent
**Goal:** Abstract API layer, add Anthropic/Google, **implement sub-agent dispatch**

#### Week 9-10: Abstraction Layer + Connection Manager
- [ ] Build Connection Manager (add/remove/list profiles)
- [ ] Create BaseAdapter interface
- [ ] Refactor OpenAI adapter to use base
- [ ] Implement Anthropic adapter (direct connection)
- [ ] Implement Google adapter (direct connection)
- [ ] Add connection switching UI
- [ ] **Implement first sub-agent: Coder Agent (Claude)**
- [ ] **Enable Orchestrator sub-agent dispatch** (NOW that Security Layer exists)
- [ ] **Test security integration:** Sub-agent actions pass through Security Layer
- [ ] Test connection management flow
- [ ] **Security Check:** All connections direct, no relay

#### Week 11-12: Custom Endpoints + More Sub-Agents
- [ ] Add custom endpoint adapter (for Cortana)
- [ ] **Implement File Agent** (local file operations)
  - [ ] Move-not-modify rule (never edit in-place)
  - [ ] Audit log for all file operations (separate log file)
  - [ ] Handle file companions together (like PNG + YAML)
  - [ ] Sandbox: only write inside allowed directories
  - [ ] File extension whitelist (security)
  - [ ] File size limits per operation (prevent abuse)
- [ ] **Implement Web Agent** (search/scrape)
- [ ] Build conversation history manager
- [ ] **Test multi-agent workflows** (e.g., "write code and save it")
- [ ] Handle provider-specific features
- [ ] Add error recovery and fallbacks
- [ ] **Security Check:** File Agent respects permissions
- [ ] **Security Check:** File audit logs don't leak sensitive paths

**Milestone:** Can switch between GPT-4o, Claude, Gemini. Orchestrator dispatches to multiple sub-agents through Security Layer.

**Security Review:**
- [ ] All API connections are direct (no relay)
- [ ] Each connection stores keys separately
- [ ] Connection UI shows where data goes
- [ ] Sub-agents respect permission system (all actions pass through Security Layer)
- [ ] File Agent cannot write outside allowed dirs
- [ ] File audit logs are secure and size-limited

---

### Phase 4: Hologram Visualizer Polish
**Goal:** Transform from prototype to "living artifact" with production-grade performance

#### Week 13-14: Three.js Enhancement + Performance Monitoring
- [ ] **Optimize particle rendering:**
  - [ ] Implement InstancedMesh for 10K+ particles (reduce draw calls to 1)
  - [ ] Use custom ShaderMaterial (avoid Three.js built-in overhead)
  - [ ] Move breathing animation to GPU vertex shader (not CPU)
  - [ ] Use BufferGeometry with dynamic attributes
  - [ ] Enable frustum culling for off-screen particles
  - [ ] Implement texture atlases for particle variations
  - [ ] Define particle count limits by GPU tier:
    - Low-end (Intel integrated): 10K particles
    - Mid-tier (discrete GPU): 50K particles
    - High-end (M1/M2/M3): 100K particles
- [ ] Add color customization per skin
- [ ] Implement smooth state transitions
- [ ] Add subtle physics-based movement
- [ ] Test performance across devices
- [ ] Ensure 60fps minimum (30fps acceptable)
- [ ] **GPU Memory Management:**
  - [ ] Proper disposal of Three.js objects (geometry.dispose(), material.dispose(), texture.dispose())
  - [ ] Track VRAM vs System RAM separately (renderer.info.memory)
  - [ ] Texture count monitoring (detect leaks via renderer.info.memory.textures)
  - [ ] Draw call count monitoring (renderer.info.render.calls, target <100/frame)
  - [ ] Triangle count monitoring (renderer.info.render.triangles)
  - [ ] WebGL context loss handler (webglcontextlost event)
  - [ ] GPU memory leak testing (1 hour soak test, max 10MB/hour drift)
  - [ ] Shader compilation time tracking (cold start optimization)
- [ ] **Performance Monitoring:**
  - [ ] Add FPS counter (dev mode, top-right corner)
  - [ ] Track frame time budget (<8ms target for 120fps, <16ms for 60fps)
  - [ ] Alert if < 30fps sustained (5+ seconds)
  - [ ] Per-frame GPU time (EXT_disjoint_timer_query if available)
  - [ ] Performance profiler dashboard (dev mode)
  - [ ] Sample metrics (every 60 frames, not every frame to reduce overhead)
- [ ] **Battery Impact Testing:**
  - [ ] Test continuous animation battery drain (MacBook Pro M1, M2, M3)
  - [ ] Implement "Power saver mode" (reduces particles by 50%, lowers FPS cap to 30)
  - [ ] Battery status detection (`navigator.getBattery()` API)
  - [ ] Auto-enable power saver when battery < 20%
  - [ ] **Pause visualizer when window minimized/hidden** (drops to 1fps or pauses entirely)
  - [ ] **Resume visualizer smoothly when window shown** (fade-in animation)
- [ ] **Performance Budgets (NEW):**
  - [ ] Define and document targets:
    - FPS: 60fps target, 30fps minimum
    - Frame time: <8ms target, <16ms acceptable
    - Draw calls: <100 per frame
    - VRAM: <200MB for visualizer alone
  - [ ] Auto-trigger power saver if sustained <30fps for 5+ seconds
- [ ] **Security Check:** Visualizer isolated from network

#### Week 15-16: Animation System Integration
- [ ] Add idle animation (slow breathing)
- [ ] Add thinking animation (faster pulse)
- [ ] Add speaking animation (active movement)
- [ ] Add locked animation (red, slow pulse)
- [ ] Sync with chat state changes
- [ ] Add "heartbeat" that never stops
- [ ] Polish transitions between states
- [ ] **Make it feel alive**

**Milestone:** Hologram reacts to conversation state, never looks frozen

**Security Review:**
- [ ] Animations don't expose sensitive data
- [ ] Visualizer state changes don't trigger network calls

---

### Phase 5: Sonique Aesthetic Transformation
**Goal:** Transform from rectangle to biomorphic UI

#### Week 17-18: Non-Rectangular Window
- [ ] Implement CSS `clip-path` for curved edges
- [ ] Add SVG mask support
- [ ] Test custom window shapes
- [ ] Optimize transparency rendering
- [ ] Add macOS vibrancy effects
- [ ] Test on different displays/themes
- [ ] Ensure drag handles work on curved edges
- [ ] **Security Check:** Custom window doesn't bypass OS security

#### Week 19-20: Sonique-Inspired Elements
- [ ] Design curved chat bubbles
- [ ] Implement kinetic menu animations
- [ ] Build "fishbowl" layout (visualizer + chat)
- [ ] Add Halo-inspired HUD elements
- [ ] Integrate Ampolyte/Halo fonts
- [ ] Polish all transitions
- [ ] Add optional sound effects (easily disabled)
- [ ] **Test that it looks "impossible"**

**Milestone:** Interface looks unmistakably "Hologram" - alien glass, not software

**Security Review:**
- [ ] Custom UI doesn't create new attack surfaces
- [ ] Audio assets are local (no CDN)
- [ ] Fonts are bundled (no external loading)

---

### Phase 6: MCP Integration + Skill System
**Goal:** Model Context Protocol support for extensible skills

#### Week 21-22: MCP Foundation
- [ ] Research MCP specification thoroughly
- [ ] Design skill manifest format
- [ ] Implement MCP skill loader
- [ ] Create sandbox environment for skills
- [ ] Build skill permission system
- [ ] Create example MCP skills (Weather, Spotify)
- [ ] Add skill management UI
- [ ] Test skill hot-swapping
- [ ] **Security Check:** Skills run in sandbox

#### Week 23-24: Skill Ecosystem
- [ ] Document skill creation guide
- [ ] Create skill marketplace UI (local only)
- [ ] Build skill preview system
- [ ] Add skill import/export
- [ ] Implement skill signatures/hashes
- [ ] Test community skill workflow
- [ ] **Integrate with Orchestrator dispatcher**
- [ ] **Add skill permission warnings**

**Milestone:** Users can install MCP skills as "extensions" with clear permission model

**Security Review:**
- [ ] Skills run in constrained sandbox
- [ ] Skill permissions explicitly requested
- [ ] UI clearly shows what skill can access
- [ ] Skills cannot access API keys
- [ ] Skill marketplace is local (no phoning home)
- [ ] Skills signed/hashed for integrity

---

### Phase 7: Skin System + White-Label Personalities
**Goal:** Users can fully customize appearance AND personality

#### Week 25-26: Skin Architecture
- [ ] Design skin manifest format (visual + personality)
- [ ] Implement skin loader (assets only, no code execution)
- [ ] Create default skins:
  - Cortana (Halo-inspired, military, brief)
  - Wizard (mystical, verbose, archaic English)
  - Minimal (clean, modern, no personality)
- [ ] Add skin switcher UI
- [ ] **Link skins to personality configs**
- [ ] Test skin hot-swapping
- [ ] **Security Check:** Skins cannot execute code

#### Week 27-28: Skin Creation Tools + Community
- [ ] Document skin format specification
- [ ] Create personality editor UI
- [ ] Build skin preview system
- [ ] Add import/export (with hash verification)
- [ ] Test white-label workflow (skin changes personality)
- [ ] Document custom skin creation guide
- [ ] Plan community skin hosting (separate from app)
- [ ] **Implement takedown process for copyright**

**Milestone:** Users can install skins that change both appearance AND AI personality

**Security Review:**
- [ ] Skins are assets + config only (no JavaScript)
- [ ] Skin parser safely handles malformed files
- [ ] Skin format doesn't allow arbitrary file access
- [ ] Community skins hosted separately (optional)
- [ ] Takedown process documented for DMCA

---

### Phase 8: Cortana Integration (Special Connection)
**Goal:** Make Cortana a first-class connection with memory features

#### Week 29-30: Cortana Adapter
- [ ] Connect to Cortana backend API
- [ ] Handle memory context in responses
- [ ] Add special UI for memory references
- [ ] Implement timeline view (optional)
- [ ] Test with real Cortana data
- [ ] **Security Check:** Cortana connection respects privacy

#### Week 31-32: Cortana Features Polish
- [ ] Add "Remember this" command
- [ ] Show memory sources in chat
- [ ] Implement confidence indicators
- [ ] Add safety layer UI (circuit breakers)
- [ ] Polish Cortana-specific experience
- [ ] Test memory query workflows

**Milestone:** Cortana is fully integrated as special connection type

**Security Review:**
- [ ] Cortana data stays local (or user's server)
- [ ] Memory queries don't leak to other providers
- [ ] Circuit breakers prevent obsessive querying

---

### Phase 9: Polish, Security Audit & Release
**Goal:** Ship v1.0 with full security review

#### Week 33-34: Security Audit + Bug Fixes
- [ ] **Comprehensive security audit**
  - [ ] Verify no telemetry in release build
  - [ ] Audit all network calls
  - [ ] Test keychain storage security
  - [ ] Verify permission system works
  - [ ] Test panic button (delete all keys)
  - [ ] Review all logging (no sensitive data)
  - [ ] Test with malicious inputs
- [ ] Fix all critical bugs
- [ ] Optimize rendering performance
- [ ] Reduce memory usage if needed
- [ ] Test on various macOS versions
- [ ] Document known limitations

#### Week 35-36: Release Preparation
- [ ] **Set up code signing** (macOS notarization)
- [ ] **Generate checksums** (SHA-256 for all builds)
- [ ] Write user documentation
- [ ] **Create "Security & Privacy" page** (plain English)
- [ ] Create demo video
- [ ] Set up DMG installer
- [ ] Test installation flow
- [ ] Write release notes
- [ ] **Publish checksums and release page**
- [ ] Consider open-sourcing key handling code

**Milestone:** Hologram 1.0 released with full security transparency

**Final Security Checklist:**
- [ ] No account required
- [ ] No cloud dependency
- [ ] No telemetry by default
- [ ] Keys in OS keychain
- [ ] All connections direct to providers
- [ ] Signed release with checksums
- [ ] Security page published
- [ ] Panic button works
- [ ] Permission system enforced
- [ ] Open source consideration documented

---

## Open Questions

### Architecture:
- Should conversation history sync across connections?
- How do we handle context windows (4K vs 128K)?
- Should we support local models (Ollama, LM Studio)?
- What's the performance impact of continuous visualizer on battery?
- ~~**Offline mode:** How should app behave when network is down?~~ **RESOLVED: Basic offline resilience in Phase 1**
  - ~~Cache last responses?~~ → v1.1
  - ~~Queue actions for retry?~~ → Basic queuing in v1.0, advanced in v1.1
  - ~~Detect network status?~~ → Phase 1 ✅

### Security & Privacy:
- Should we open-source the entire app or just key-handling code?
- How do we handle crash reports if no telemetry? (Manual export?)
- Should update checks be manual or opt-in auto?
- How do we verify community skins are safe?

### Design:
- How "weird" can we make the window shape before it's unusable?
- Should visualizer be always-on or toggleable?
- What's the default size/position?
- How many default skins should we ship with?

### Business:
- Is this open source or proprietary?
- Do we build a "Parent API" service for users without keys?
- Should we monetize? (Donations, paid skins, hosted version?)
- What's the liability if user's API keys are compromised?

### Features:
- Voice input/output? (TTS/STT)
- Plugin system for third-party extensions? (security concerns)
- Mobile companion app (future)?
- Collaboration features? (Share conversations?)

### Legal & Compliance:
- Do we need a privacy policy if we collect nothing?
- How do we handle DMCA for community skins?
- Provider terms compliance (are we a "competing service"?)
- Export controls on AI software?

---

## Technical Debt & Future Work

### Post-Launch (v1.1+):
- [ ] Windows support (currently macOS-focused)
- [ ] Linux support
- [ ] Voice integration (speech-to-text, text-to-speech)
- [ ] Context window management (summarization)
- [ ] **Conversation export** (Markdown/JSON with key masking)
- [ ] **Rate limit tracking** per provider (alert when approaching limits)
- [ ] Cost tracking per connection
- [ ] Model comparison mode (same prompt to multiple models)
- [ ] Prompt templates library
- [ ] Advanced rate limiting
- [ ] Conversation search
- [ ] **Advanced offline mode enhancements:**
  - [ ] Cache last N responses (local LLM fallback)
  - [ ] Advanced message queuing with retry strategies
  - [ ] Offline conversation mode with local models (Ollama)

### Known Limitations to Document:
- macOS only in v1.0 (Windows/Linux later)
- Requires user's own API keys
- No conversation sync across devices
- Basic offline capability (visualizer + history, no new messages)
- Custom skins require technical knowledge

---

## Success Criteria

### The App is Ready for v1.0 When:

**Technical:**
- [ ] All Phase 9 security checklist items complete
- [ ] No critical bugs in issue tracker
- [ ] Performance targets met (see IMPLEMENTATION_DIRECTIVES.md)
- [ ] Tested on macOS 12, 13, 14, 15
- [ ] Signed and notarized
- [ ] Documentation complete

**Design:**
- [ ] A screenshot looks "impossible" (people ask "how?")
- [ ] The visualizer feels alive (never frozen)
- [ ] Window shape is non-rectangular and beautiful
- [ ] UI is usable while looking alien

**Architecture:**
- [ ] Orchestrator supports MCP without rewrite
- [ ] Adding new sub-agents doesn't require UI changes
- [ ] Swapping skins changes personality correctly
- [ ] Permission system enforced throughout

**Trust:**
- [ ] Users say "I trust this with my API keys"
- [ ] Security page is clear and honest
- [ ] Panic button is obvious and works
- [ ] All network calls are documented

**Cool Factor:**
- [ ] Users say "this is the coolest thing I've ever seen"
- [ ] Erik shows it to friends and they want it
- [ ] People share screenshots on social media
- [ ] Feels like talking to the future

### The App Has Failed If:

- [ ] It looks like a standard chat window
- [ ] The visualizer is static or removed
- [ ] Actions are hardcoded (no orchestrator)
- [ ] Users say "it's just another AI client"
- [ ] Security claims are inaccurate
- [ ] API keys are ever logged or leaked
- [ ] Telemetry was added without explicit opt-in
- [ ] Users don't trust it with their keys

---

## Session Log

### December 19, 2025 - Fresh Eyes "Scope Control" Review ✅

**Reviewer:** Anonymous fresh perspective (never seen project before)

**Focus:** Scope control, trust math, "will this ship?"

**Valid Concerns Raised:**

1. **Better "No Telemetry" Promise:**
   - Original: "Zero telemetry, transparent network calls"
   - **NEW:** "No account. No cloud dependency. No background network calls. All network destinations are user-configured and visible."
   - This is more specific and harder to accidentally violate
   - ✅ Adopted

2. **Action Catalog Missing:**
   - We have Green/Yellow/Red but no explicit list of what actions exist
   - **NEW:** Action Catalog v0 added to Phase 1 security foundation
   - Explicit list: network, filesystem (read/write/delete), shell, browser
   - v1.0 ships with only network + filesystem reads enabled by default
   - ✅ Added

3. **Battery When Hidden:**
   - Already had power saver mode, but not explicit pause when minimized
   - **NEW:** Pause visualizer when window minimized (1fps or paused)
   - ✅ Clarified

**Already Addressed:**
- Three hard problems → MCP/marketplace already on v1.1 cut list ✅
- Plugins = supply chain risk → Already sandboxed, Phase 6, v2-tier ✅
- Battery drain → Already had power saver, auto-disable when minimized ✅

**Reviewer's Verdict:** Valid scope concerns, mostly already handled, minor tweaks needed

**Status:** All tweaks applied ✅

---

### December 19, 2025 - Phase 0 Complete! 🎉

**Status:** ✅ **PHASE 0 SHIPPED**

**Completed:**
- Git repository initialized
- npm/Electron project created
- Core dependencies installed (Electron, Three.js)
- First successful app launch (frameless, transparent window)
- Milestone tracking system established
- 7 AI reviews completed with unanimous architectural consensus

**The Moment:**
First window screenshot captured at 11:19 PM. The app already looks "impossible" - translucent, floating, alien glass. And we haven't even added the particle sphere yet.

**Erik's verdict:** "man this is a badass project" 🔥

**What's Next:**
Phase 1 begins! First tasks:
- Build Security Layer foundation (Risk enums, Action Catalog)
- Set up Three.js breathing particle sphere
- Implement offline resilience
- Create Orchestrator stub with Cortana personality

**See:** `docs/milestones/2025-12-19_phase-0-complete.png`

---

### December 19, 2025 - Final Gemini Review: "Hidden Dragon" Found ✅

**Reviewer:** Gemini 3 Flash (Strategic Architect assisting with prompt creation)

**Status:** ✅ **FINAL PASS - READY TO BUILD**

**Critical Issue Identified:**
- **"Hidden Dragon"** - Router's intent classifier has circular dependency with offline state
- Problem: If Router uses LLM to classify intent, but we're offline, Security Layer is blind
- Example: User says "delete files" offline → Router can't ask GPT-4 what this means → Security can't assess risk
- **Solution:** Router needs local pattern matching (regex/keywords) that works 100% offline
- Cloud LLM only for ambiguous cases when online

**Roadmap Update:**
- ✅ Added local intent classification requirement to Phase 1, Week 1-2
- ✅ Security assessment must work offline (no cloud dependency for basic patterns)
- ✅ Pattern libraries for Red/Yellow/Green actions defined locally

**Key Quote:**
> "You cannot wait for the cloud to tell you if a user is trying to delete files."

**Gemini's Verdict:**
- Roadmap matured from "Vision Board" to "Engineering Spec"
- Timeline honest (42+ weeks)
- Security stance ironclad
- **Status: READY TO BUILD**

**Phase 0 Status:** ✅ **COMPLETE**

---

### December 18-19, 2025 - Round 2 Reviews: UNANIMOUS VERDICT (Day 2)

**Completed:**
- Claude Opus 4 review
- Claude Sonnet (Composer) review
- Gemini 3 Flash Preview review
- GPT-5.1 Codex Max review
- Grok Code Fast review

**UNPRECEDENTED CONSENSUS: All 5 reviewers gave "CONDITIONAL PASS" ⚠️**

**Critical Issues Identified (100% Agreement):**

1. **OFFLINE MODE MUST BE PHASE 1** ⚠️
   - All 5 reviewers independently flagged this
   - Cannot claim "Local-First" if app crashes when WiFi disconnects
   - Quote (Grok): "Positioning offline mode in 'Technical Debt' is architecturally dishonest"
   - **RESOLVED:** Moved to Phase 1, Week 3-4

2. **SECURITY LAYER BEFORE ORCHESTRATOR** ⚠️
   - All 5 detected dependency inversion
   - Quote (Claude): "Building the roof before the foundation"
   - Orchestrator dispatches actions, so Security Layer must exist first
   - **RESOLVED:** Restructured Phase 1 (Security foundation Week 1-2, Orchestrator stub Week 3-4)

3. **TIMELINE IS UNREALISTIC** ⚠️
   - Opus: 48-52 weeks actual
   - Claude: 42-44 weeks
   - Grok: 52-60 weeks
   - All agree 36 weeks is 30-40% too optimistic
   - **ACKNOWLEDGED:** Realistic estimate now 42-52 weeks

4. **GPU MONITORING INSUFFICIENT** ⚠️
   - All 5 flag missing: VRAM tracking, WebGL context limits, draw call budgets
   - **RESOLVED:** Enhanced Phase 4 with comprehensive GPU metrics

**Roadmap Updates Made (v2.0 → v3.0):**

- ✅ **Phase 1 Restructured:**
  - Week 1-2: Electron + Router + Security Foundation
  - Week 3-4: Visualizer + Orchestrator Stub + Offline Resilience
  
- ✅ **Offline Mode Added to Phase 1:**
  - Network status detection
  - Graceful degradation (visualizer + history work offline)
  - Message queuing for retry
  - ~14 hours effort (all reviewers agreed minimal)

- ✅ **Security Layer Enhancements (Phase 2):**
  - Log rotation and sanitization
  - Conversation encryption
  - PII detection in logs
  - Clear logs/history buttons

- ✅ **GPU Monitoring Enhanced (Phase 4):**
  - VRAM vs System RAM tracking
  - Texture/draw call/triangle count monitoring
  - WebGL context loss handling
  - Shader compilation time tracking
  - Performance budgets defined

- ✅ **Timeline Reality Acknowledged:**
  - Original: 36 weeks
  - Realistic: 42-52 weeks
  - 24-week forced ship: Requires cut list (documented)

**The "24-Week Cut List" (All 5 Agreed):**
1. Phase 6 (MCP Integration) → v1.1
2. Phase 7 (Skin Community Features) → v1.1
3. Phase 8 (Cortana Special Integration) → v1.1
4. Phase 5 (Advanced Sonique) → Reduce to basic non-rectangular

**Key Insight:**
The level of consensus across 5 different AI models is extraordinary. When completely independent reviewers all identify the same issues, it's a strong signal those issues are real.

**Review Documents:**
- `docs/reviews/claude-opus-4-review-v2.md`
- `docs/reviews/claude-review-v2.md`
- `docs/reviews/gemini-3-flash-preview-review-v2.md`
- `docs/reviews/gpt-5.1-codex-max-review-v2.md`
- `docs/reviews/Grok-review-v2.md`

**Next Steps:**
- Erik reviews updated roadmap (v3.0)
- Finalize Phase 0 with corrected sequencing
- Begin Phase 1 with proper foundation (Security first, then Orchestrator)

---

### December 18-19, 2025 - Four-Review Consensus (Day 2, Round 1)

**Completed:**
- Opus 4.5 comprehensive architecture review
- Grok detailed code review
- GPT-5.1.1 Codex max review  
- Gemini 3 Flash Preview strategic review

**Strong Consensus Across All 4 Reviews:**
1. **Cross-pollination is critical** - Reuse patterns from Trading, Cortana, Agent OS, Image Workflow, Hypocrisy Now
2. **Timeline realism** - Phase 1 needs 6-8 weeks (not 4), implementation 2-3x longer than docs
3. **GPU/Performance gaps** ⚠️ - All 4 flagged: GPU memory leaks, battery impact, need monitoring
4. **Offline mode missing** ⚠️ - Network detection, cache responses, queue actions

**Roadmap Updates Made:**
- ✅ Added GPU/performance monitoring to Phase 4 (FPS counter, memory leak testing, power saver mode)
- ✅ Added API key rotation button to Phase 2
- ✅ Added request/response logging (sanitized) to Phase 2
- ✅ Added crash recovery (auto-save conversation) to Phase 2
- ✅ Added explicit File Agent safety rules to Phase 3 (move-not-modify, audit logs, companions)
- ✅ Added Three.js bundling check to Phase 1
- ✅ Added offline mode to Open Questions and Technical Debt
- ✅ Added conversation export and rate limit tracking to Technical Debt

**Key Quote from Gemini:**
> "Hologram is the 'Body' to Cortana's 'Soul.' By leveraging the local-first security model... we're building an interface that feels like the future (Sonique 1999 vibe) but operates with industrial-grade reliability (Trading Projects 2025 vibe)."

**Review Documents:**
- `docs/reviews/OPUS_4.5_REVIEW.md`
- `docs/reviews/GROK_CODE_REVIEW.md`
- `docs/reviews/gpt5.1.1.md`
- `docs/reviews/gemini-3-flash-preview__hologram-roadmap-review.md`

**Next Steps:**
- Round 2 reviews with fresh contexts (if needed for consensus check)
- Finalize Phase 0 after review feedback
- Begin Phase 1 implementation

---

### December 18-19, 2025 - Master Architect Review (Day 2)

**Completed:**
- Claude Opus 4.5 comprehensive architecture review
- Cross-pollination analysis across Erik's 5 major projects
- Detailed sprint breakdowns with realistic time estimates
- Definition of Done checklists for v1.0
- Gap detection and risk register

**New Document Created:**
- `OPUS_4.5_REVIEW.md` - Complete strategic review by Claude Opus 4.5

**Key Cross-Pollination Discoveries:**
1. **Agent OS** → Use kernel architecture, db.py pattern, plugin interface
2. **Cortana Personal AI** → Port 4-layer safety architecture, circuit breakers
3. **Trading Projects** → Adapt risk classification, API retry patterns
4. **Hypocrisy Now** → Apply offline-first philosophy, connection pooling (future)
5. **Image Workflow** → Adopt code quality rules, FileTracker patterns

**Revised Timeline:**
- Phase 1 (original 4 weeks) → **6-8 weeks** (Three.js + Electron complexity)
- Phase 2 (original 4 weeks) → **4-5 weeks** (well-defined security layer)
- Phase 3 (original 4 weeks) → **5-6 weeks** (multi-API coordination)

**Strategic Insight:**
Hologram is the **UI layer** that unifies:
- Agent OS (kernel/runtime)
- Cortana (memory/personality backend)
- Trading (risk patterns)

**Next Steps:**
1. Erik reviews ARCHITECT_REVIEW.md
2. Initialize Electron project with transparency config
3. Port Agent OS db.py to TypeScript
4. Begin Sprint 1.1 (Electron Foundation)

---

### December 18, 2025 - Project Launch (Day 1)

**Major Events:**
- Project created (split from Cortana interface)
- Gemini insight: "AI companies use boring chat windows"
- Erik's pivot: "Why don't we make a white label version?"
- Hologram born as standalone project
- **Second pivot:** Agent Operating System (Hub & Spoke architecture)
- ChatGPT security review completed

**Decisions Made:**
- Desktop app (Electron)
- Menu bar mode
- Sonique aesthetic (non-rectangular, biomorphic)
- **Orchestrator pattern** from day one
- **MCP integration** (not "later" - build socket now)
- Skin system changes appearance AND personality
- Multi-AI support as core feature
- **Local-only, zero telemetry** as hard requirement
- **Security layer** (Green/Yellow/Red permissions)

**Documents Created:**
- README.md (project overview)
- CLAUDE.md (AI collaborator context)
- ROADMAP.md (this file - comprehensive plan)
- SESSION_NOTES_DAY_1.md (detailed session notes)
- IMPLEMENTATION_DIRECTIVES.md (developer bible)
- ORCHESTRATOR_ARCHITECTURE.md (Hub & Spoke design)
- API_ABSTRACTION_LAYER.md (multi-AI support)
- Hologram_LocalOnly_Concerns_and_Checklist.pdf (security review)

**The Energy:**
- Erik went from "I need to get to work" to "wait, one more thing..." THREE TIMES
- His brain "lit up" when discussing the interface
- Nearly missed work deadline because of excitement
- This is the sign of something special 🔥

**Key Quote:**
> "If Sonique could make an MP3 player look like alien technology in 1999, we can make an AI interface look magical in 2025."

**Next Session:**
- Get advisor feedback on this roadmap
- Revisions based on feedback
- Finalize Phase 0
- Initialize Git repository
- Begin Phase 1 when ready

### December 18-19, 2025 - Security Review

**Completed:**
- ChatGPT security consultation
- Legal/compliance concerns documented
- Product stance clarified (local-only, no telemetry)
- Security checklist integrated into roadmap
- All concerns from PDF extracted and incorporated

**Key Insights from ChatGPT:**
- "Zero data collected" is fragile - use "No account. No cloud. No telemetry."
- API keys in OS keychain is the right model
- Direct-to-provider connections reduce terms risk
- Skins should be assets only (no code execution)
- Plugins need sandbox + explicit permissions
- Signed releases + checksums = trust signals

**Security Decisions:**
- Default to no telemetry (no exceptions)
- Manual update checks (or explicit opt-in)
- Skins are visual only (v1.0)
- Plugins postponed until sandboxing ready
- One-click "Delete all keys" panic button
- Keys never in logs, console, or error messages

---

## Resources

### Inspiration:
- Sonique (2001 MP3 player)
- Winamp skins
- Halo UI (Cortana aesthetic)
- Modern glass/translucent UIs
- Cyberpunk 2077 interface elements

### Technical References:
- Electron documentation
- Three.js examples
- OpenAI/Anthropic/Google API docs
- MCP (Model Context Protocol) specification
- macOS app design guidelines
- macOS Keychain Services documentation

### Related Projects:
- **Cortana Personal AI** - Erik's memory AI (primary use case)
- **AI-journal** - Multi-AI interaction journal (data source)
- **Trading Projects** - Additional data sources

### Security & Privacy:
- OWASP Electron Security Guidelines
- macOS Code Signing and Notarization
- Windows Code Signing Best Practices
- API Provider Terms of Service (OpenAI, Anthropic, Google)

---

## Notes

### Philosophy:
- **"Janky compass, not detailed map"** - iterate and adjust
- **"Cool > Efficiency"** - spend the CPU on magic
- **Priority:** Cool factor > feature completeness
- **Timeline:** Flexible - adjust based on feedback and discoveries
- **Success Metric:** "Does this make talking to AI feel special?"

### For Advisors Reviewing This Roadmap:

**We need feedback on:**
1. **Security model** - Is local-only + OS keychain sufficient?
2. **Phase ordering** - Should we build differently?
3. **Open source** - All, some, or none?
4. **Legal concerns** - Privacy policy needed? DMCA handling?
5. **Provider compliance** - Are we violating any terms?
6. **Monetization** - If any, what's ethical?
7. **Scope** - Is this too ambitious for v1.0?

**What we're confident about:**
- The vision (revolutionary tech deserves revolutionary design)
- The architecture (Orchestrator pattern is sound)
- The security stance (local-only, no telemetry)
- The user model (bring your own keys)

**What we're uncertain about:**
- Legal/compliance edge cases
- Community content moderation (skins)
- Plugin security model
- Business sustainability

---

## Revision History

**v1.0** - December 18, 2025 (Initial)
- Basic roadmap created during project launch
- 9 development phases outlined

**v2.0** - December 18-19, 2025 (Security Integration)
- Security & privacy checklist added
- ChatGPT legal review integrated
- Security checkpoints added to all phases
- Success criteria expanded with security focus
- Open questions expanded with legal concerns
- Ready for advisor review

**v3.0** - December 19, 2025 (Round 2 Consensus - MAJOR RESTRUCTURE)
- **CRITICAL:** Offline mode moved from Technical Debt → Phase 1
- **CRITICAL:** Phase 1 restructured (Security Layer foundation before Orchestrator)
- **CRITICAL:** Timeline reality check (36 weeks → 42-52 weeks realistic)
- GPU monitoring massively enhanced (VRAM, WebGL context, performance budgets)
- Security hardening in Phase 2 (log rotation, conversation encryption, PII detection)
- File Agent enhanced with security constraints
- Sub-agent dispatch explicitly tied to completed Security Layer
- 24-week cut list documented (MCP, Skin Community, Cortana Special → v1.1)
- Based on **UNANIMOUS CONSENSUS** from 5 independent AI reviewers

**Next:** Implementation begins with corrected sequencing

---

*Last updated: December 19, 2025*  
*Status: **v3.0 FINAL - Phase 0 Complete ✅ | Phase 1 In Progress 🚀***  
*Timeline: Realistic 42-52 weeks*  
*Started: December 18, 2025*

---

**Phase 0 Complete. Phase 1 begins. Let's build something beautiful. Securely. Realistically.** 💜🔒✨

