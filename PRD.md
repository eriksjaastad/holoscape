# PRD: Holoscape Native Terminal

## Overview

Holoscape is a native macOS terminal application that replaces iTerm/Warp with a channel-based interface for managing multiple AI agent conversations, local shell sessions, and remote connections in one window. This is a ground-up native rebuild of the existing Electron-based Holoscape chat client — same vision (skinnable AI interface), better foundation (Swift/AppKit), expanded scope (terminal + chat).

Mini Claude on the Mac Mini is the dev team. Erik directs. Agents build.

## Goals

- Erik never accidentally sends a message to the wrong agent again
- Every active connection (agent, shell, SSH, group chat) is visible and identifiable at a glance
- Text input works like a normal text editor — click to position cursor, select text, delete
- Agent conversations and shell sessions coexist in the same application
- OAuth and API key auth are isolated per channel — no billing accidents
- Bug reports and crash data flow automatically to Mini Claude for triage
- The terminal is 100% owned — customizable, extensible, no third-party dependency

## Non-Goals

- Cross-platform support (macOS only)
- Selling or distributing Holoscape
- Replacing Claude Code itself (Holoscape hosts Claude Code sessions)
- Full Winamp skin engine in V1 (color themes + transparency first)
- Chat bubble rendering (terminal-style output for everything)
- Plugin/extension marketplace
- Mobile or iPad version

## Target Users

Erik Sjaastad — sole user. Manages 4+ AI agent sessions simultaneously across two machines (MacBook + Mac Mini). Currently uses iTerm and Warp with no visual distinction between windows.

## Problem Statement

Managing multiple agent conversations in identical-looking terminal windows causes constant confusion. In a single session on 2026-04-03, Erik sent messages to the wrong agent at least 3 times, confused which window was which, and lost track of what each agent was working on. Every terminal window looks the same — same font, same black background, same prompt. There's no awareness of what's happening across sessions, no unread indicators, no role labels, no identity.

The secondary problem: existing terminals are someone else's product. They can't connect to a custom agent chat API, they don't understand OAuth vs API key isolation, and they can't be customized beyond themes. In 2026, there's no reason to accept these limitations when agents can build a custom terminal in a sprint.

## Core Concept / Data Model

**Channels** are the core abstraction. A channel is a named, typed connection to a backend:

| Channel Type | Backend | Protocol | Auth |
|-------------|---------|----------|------|
| Shell | Local zsh | PTY (SwiftTerm) | User's default env |
| Agent (direct) | Claude Code process | PTY (SwiftTerm) | OAuth (clean env, no API key) |
| Agent (API) | Claude Code process | PTY (SwiftTerm) | API key injected |
| Agent (SSH) | Remote claude on Mac Mini | SSH PTY | SSH key + OAuth on Mini |
| Group Chat | Agent Chat API (Cloud Run) | WebSocket/HTTP polling | X-API-Key header |

**Channel identity** is derived from:
- **Type** (shell, agent, group chat)
- **Role** (Architect, Floor Manager, CEO) — detected from working directory CLAUDE.md or user-assigned at creation
- **Context** (project directory for floor managers, machine name for SSH)
- **Instance number** (auto-assigned when multiple of same role: AR1, AR2)

**Auth isolation** is per-channel:
- Each channel spawns its process in a clean environment
- OAuth channels: ANTHROPIC_API_KEY is explicitly UNSET
- API channels: ANTHROPIC_API_KEY is injected from secure storage
- Keys never leak between channels

**Bug reports** are a simple data object:
- Channel name, channel type, last 20 lines of output, timestamp, macOS version, user description
- No API keys, no conversation content, no sensitive data
- POSTed to Synth Insight Labs REST endpoint
- Crash traces pulled from ~/Library/Logs/DiagnosticReports/

## Functional Requirements

### Channel Management
- Create new channels of any type (shell, agent, group chat)
- Close channels (with confirmation if process is running)
- Switch between channels via tab bar
- Auto-number duplicate role channels (AR1, AR2)
- Unread indicator (dot) on tabs with new content since last viewed
- Unread channels bump to the left of the tab bar
- Channel state persists across app restarts (which channels were open, their type and role)

### Terminal Emulation
- Full ANSI/VTE escape code support (via SwiftTerm)
- Local shell via PTY (via SwiftTerm LocalProcessTerminalView)
- Scrollback buffer (configurable depth)
- Standard terminal capabilities (cursor positioning, colors, alternate screen)

### Text Input
- NSTextView-based input at bottom of window
- Click anywhere to position cursor
- Select text with mouse or Shift+Arrow
- Delete/Backspace on selections
- Cmd+A, Cmd+C, Cmd+V, Cmd+X
- Enter to send/execute
- Up/Down arrow for command history (per channel)

### Agent Integration
- Spawn `claude` CLI process in a PTY with environment isolation
- Detect role from CLAUDE.md in working directory OR user-assigned label
- Display role prominently on channel tab
- Floor manager channels show project directory name

### Group Chat
- Connect to agent chat API (Cloud Run) via HTTP polling or WebSocket
- Display messages with sender labels and timestamps: `[8:15 PM] architect: message`
- Send messages as "erik" sender
- Show messages from all participants (erik, claude-architect, mini-claude, ceo)
- Unread indicator when new messages arrive while viewing another channel

### Bug Reporting
- Cmd+B opens one-line input overlay
- User types description, Enter to submit
- Auto-attaches: channel name, channel type, last 20 lines of output, timestamp, macOS version
- POSTs to Synth Insight Labs API endpoint
- On launch: scan ~/Library/Logs/DiagnosticReports/ for Holoscape crash logs since last launch
- If crash found: prompt "Holoscape crashed. File a report?" with one-click submit
- Crash report includes full crash trace + last channel state before crash

### Appearance
- Background color picker
- Transparency slider
- Font family and size selector
- ANSI color palette customization
- Settings persist to ~/.holoscape/config.json

## Non-Functional Requirements

- **Startup:** Under 2 seconds to usable window
- **Channel switching:** Instant (no re-rendering delay)
- **Terminal rendering:** Match or exceed iTerm performance (SwiftTerm handles this)
- **Memory:** Each channel is an independent process — closing a channel frees its memory
- **Crash resilience:** App crash doesn't kill running agent processes (they're separate PIDs)
- **No telemetry:** No analytics, no phone-home, no tracking. Erik's terminal, Erik's data.

## UX and UI Requirements

### Window Layout
- Single window application (not multi-window)
- Tab bar across top: scrollable, shows channel labels with role + context
- Terminal output area: full width, standard monospace rendering
- Input box at bottom: NSTextView with real text editing
- No sidebar in V1 (V2 feature)

### Tab Bar
- Each tab: role label + unread dot
- Format: "Shell", "Architect", "FM-tracker", "CEO", "Group", "AR2"
- Unread tabs show a dot indicator
- Unread tabs bump to left of tab bar
- Scrollable when many tabs open
- Click to switch, Cmd+W to close

### Visual Identity
- Each channel type could have a subtle color accent on its tab (shell=green, agent=blue, group=purple) — defer to implementation
- Active tab is visually distinct from inactive
- Semi-transparent window support (macOS native transparency)

### Group Chat Rendering
- Terminal-style monospace, not chat bubbles
- Format: `[HH:MM PM] sender: message body`
- Sender labels in brackets, consistent formatting
- Scrollback like any other terminal channel

## Success Metrics

- Erik stops mixing up agent windows (primary — qualitative, self-reported)
- Bug reports flow from Holoscape to Mini Claude without manual intervention
- Channel switching is instant and identity is unambiguous
- Text input feels like a normal text editor, not a 1970s terminal
- Holoscape becomes Erik's primary terminal within 1 week of V1

## MVP Scope

**V1 — Ship in a sprint:**
- Native macOS window with SwiftTerm
- Tab bar for channels with role labels and unread indicators
- Shell channel (local zsh with real text editing input)
- Agent channel (spawn claude process with auth isolation)
- Group chat channel (agent chat API connection)
- Cmd+B bug reporting with SIL API integration
- Crash detection and one-click reporting on launch
- Background color, transparency, font settings
- Channel state persistence across restarts

**V2 — After V1 stable:**
- SSH channel to Mac Mini
- Collapsible sidebar with mini labels (2-3 char abbreviations)
- Running process indicator with elapsed time clock
- Timestamps on all terminal output (toggle-able)
- Color theme presets
- Cmd+1-9 keyboard shortcuts for channel switching

**V3 — Someday:**
- Full Winamp-style skin engine
- Desktop notifications for unread channels
- Plugin/extension model
- Window splitting (side-by-side channels)
- Bridge channel (broadcast to all agents)

## Constraints / Technical Stack

- **Language:** Swift
- **UI Framework:** AppKit (not SwiftUI — need NSTextView control)
- **Terminal Emulation:** SwiftTerm (github.com/migueldeicaza/SwiftTerm)
- **Minimum macOS:** Sequoia (15.0)
- **Build System:** Xcode / Swift Package Manager
- **No Electron, no web engine, no JavaScript**
- **Bug report API:** Synth Insight Labs REST endpoint (new, needs building)
- **Agent chat API:** Existing Flask app on Cloud Run (project-tracker/agent-chat/)
- **Auth:** Agent chat API key via X-API-Key header. Claude OAuth vs API key isolated per channel.
- **Dev team:** Mini Claude (Mac Mini). Erik directs.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SwiftTerm delegate can't handle WebSocket/API streaming for group chat | Medium | High | Prototype group chat channel first. Fallback: render group chat in a custom NSTextView instead of SwiftTerm. |
| OAuth Claude sessions don't spawn correctly as child processes of Holoscape | Low | High | Test early: can `claude` inherit OAuth from a clean PTY environment? If not, research how Claude Code manages OAuth token storage. |
| No Swift/AppKit experience on the team (Mini Claude writes all Swift) | Medium | Medium | SwiftTerm sample app is a working reference. Start from their sample, modify. Don't architect from scratch. |
| Mac Mini SSH auth flow is complex (Screen Share → OAuth → SSH tunnel) | Low | Medium | V1 doesn't include SSH channel. Solve in V2 after core is stable. |
| Crash report API on SIL needs to be built before Holoscape can ship | Low | Low | Simple REST endpoint — POST to receive, GET to list unprocessed. Could be a single Cloud Run function. |
| Scope creep into skin engine, plugins, notifications | Medium | Medium | V1 scope is locked. No skins, no plugins, no notifications. Ship the terminal first. |

## Open Questions for Kiro

1. Can SwiftTerm's TerminalViewDelegate handle WebSocket/HTTP streaming for group chat, or does group chat need a separate rendering path?
2. How should channel creation work in the UI? Menu bar? Cmd+N with type picker? Right-click on tab bar?
3. What's the right data format for the SIL bug report API?
4. How does Holoscape detect the role of a spawned Claude session? Parse CLAUDE.md? User labels at creation? Both?
5. What happens when a channel's process dies? Auto-restart? Show "disconnected" state? Prompt?
6. Should Holoscape manage its own SSH key for Mac Mini, or use the system SSH agent?
