# Holoscape Discovery Brief

**Date:** 2026-04-03
**Status:** GO — ready for /strategy (PRD)

---

## The Idea

Native macOS terminal application that replaces iTerm/Warp. Channels connect to different backends: local shell, AI agents (Claude Code), SSH (Mac Mini), and group chat (agent chat API). Skinnable like Winamp. Real text editing in the input box.

Replaces the existing Electron-based Holoscape chat client with a ground-up native Swift/AppKit rebuild.

## The Real Why

**Sovereignty + sanity.** Erik manages 4+ agent conversations in identical-looking terminal windows and can't tell them apart. Tonight he mixed up windows at least 3 times, sending messages to the wrong agent. The problem isn't that existing terminals are bad — they all look the same and have no awareness of what's happening across sessions.

Secondary motivation: agents can build anything now. There's no reason to use someone else's terminal when you can build exactly what you want and change it whenever you want.

## Expert Panel

| Lens | Key Finding |
|------|-------------|
| UX Advocate | The "wrong window" problem is the core pain. Role labels, unread indicators, and channel identity solve it. |
| Infrastructure Realist | Two auth paths (OAuth subscription vs API key) must be isolated per channel. Agent chat API already exists. SwiftTerm handles terminal emulation. |
| Domain Expert | SwiftTerm's delegate protocol maps perfectly to the channel model. Each channel type is a different delegate implementation. |
| Market Realist | Audience of one = zero compromise. Building for yourself is a superpower. |

## Confirmed Strengths

- Clear, visceral pain point (wrong window, happened multiple times in one session)
- All backend infrastructure already exists (agent chat API on Cloud Run, SSH to Mini, OAuth/API auth)
- SwiftTerm eliminates the hardest problem (terminal emulation, ANSI, PTY)
- AppKit NSTextView gives real text editing (click, select, delete) for the input box
- Agents build the code — Erik directs, Claude executes

## Blind Spots

- Mac Mini auth: Screen Share to authorize OAuth, then SSH tunnel carries the session. Holoscape needs to handle this flow.
- Skin system scope: V1 should be color themes + transparency, not full Winamp skin engine.
- No prior Swift/AppKit experience — agent does 99% of the Swift work.
- SwiftTerm's delegate model needs prototyping with WebSocket/API backends (proven with PTY, unproven with HTTP streaming).

## Open Questions

1. Can SwiftTerm's delegate handle streaming from agent chat API (WebSocket) or only PTY?
2. How does OAuth Claude session spawning work when Holoscape is the parent process?
3. What's the minimum viable skin system that feels like "yours"?
4. How does Holoscape detect the role (Architect, Floor Manager, CEO) of a spawned session?

## Architecture (from research)

**Stack:** Swift + AppKit + SwiftTerm
- SwiftTerm: terminal emulation, ANSI parsing, PTY management
- AppKit NSTextView: real text editing input
- Agent chat API: WebSocket for live group chat
- SSH: remote PTY to Mac Mini

**Channel Types:**
1. **Shell** — PTY delegate, connects to local zsh
2. **Agent (direct)** — spawns `claude` process in a PTY, siloed conversation
3. **Agent (SSH)** — SSH PTY to Mac Mini for remote agent sessions
4. **Group chat** — WebSocket delegate to agent chat API, all agents see and respond
5. **Bridge** — broadcast channel, messages go to all agents

**Auth Isolation:**
- OAuth channels: clean environment, no ANTHROPIC_API_KEY
- API channels: ANTHROPIC_API_KEY injected
- Holoscape manages isolation so keys never leak between channel types

**Channel Identity:**
- Each channel shows role + context: "Architect", "FM-project-tracker", "CEO"
- Multiple same-role channels auto-number: AR1, AR2
- Floor managers show project directory
- Tabs across top, scrollable, unread indicator (dot or badge)
- Unread channels bump to the left so they don't get lost
- Collapsible sidebar with mini labels (V2)

**Display:**
- Terminal-style output for everything (no chat bubbles)
- Group chat: same monospace output with sender labels + timestamps
- Settings: background color, transparency, font, color scheme
- Standard terminal capabilities (zsh, cursor, scrollback)

## Scope Assessment

**Sprint project (1-2 weeks).** V1 is minimal:
- Native macOS window with SwiftTerm
- Tab bar for channels
- Shell channel (local zsh with real text editing input)
- Agent channel (spawn claude process)
- Group chat channel (agent chat API)
- Role labels on tabs
- Unread dot indicator
- Transparency + font + color settings

**Bug reporting (built into V1):**
- `Cmd+B`: one-line bug input, auto-attaches current channel, last N lines of output, timestamp. No forms.
- Crash recovery: on launch, detect crash logs from `~/Library/Logs/DiagnosticReports/`. Show what happened, one click to file.
- All reports POST to Synth Insight Labs API endpoint (not GitHub). Simple REST: POST to submit, GET for unprocessed.
- Mini Claude checks this endpoint on every startup BEFORE doing anything else. He triages and fixes — he's the dev team for Holoscape.
- Pipeline: Holoscape (MacBook) → SIL API → Mini Claude (Mac Mini) → fix → PR

V2 adds:
- SSH channel to Mac Mini
- Collapsible sidebar with mini labels
- Running process clock/timer
- Timestamp display
- Skin system (color themes)

V3 (someday):
- Full Winamp-style skin engine
- Custom window shapes
- Notification system
- Plugin/extension model

## Inputs for /strategy

- **Problem:** Managing multiple agent conversations in identical terminal windows causes constant confusion
- **Audience:** Erik (audience of one)
- **Constraints:** Native macOS (no Electron), must work with existing agent chat API, must handle OAuth vs API key isolation
- **Non-goals:** Selling it, cross-platform, replacing Claude Code itself
- **Success metric:** Erik stops mixing up agent windows

## Recommendation

**GO.** Pain is real and happened tonight. Infrastructure exists. Technical risk is low. SwiftTerm does the hard part. Ship V1 in a sprint, iterate forever.

## Research References

- SwiftTerm: github.com/migueldeicaza/SwiftTerm
- Cousin Claude research brief (terminal engineering options)
- Agent internals research: ~/projects/__Knowledge/claude-code-internals-research.md
- Existing Holoscape (Electron): ~/projects/holoscape/
