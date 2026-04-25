# Holoscape Progress (2026-04-24)

## Current State

The chrome/vessel foundation is still the stable baseline. The latest skinning work reopens the visual composition problem narrowly: make MercuryDeck read as two hardware masses without destabilizing the runtime foundation.

Skinning update from 2026-04-24:
- `MercuryDeck` now has a generated two-mass baked chrome shell: left channel spine, transparent separation gap, right main text body, and bottom input drawer
- chrome-mode masking now derives from the baked Base_Layer alpha, so transparent gaps in the skin can visually break the single-window slab
- detached traffic lights move onto the main text body for left-vessel skins and are centered in the generated MercuryDeck landing dock
- chrome-mode windows now install explicit drag handles over the visible metal frame; `isMovableByWindowBackground` remains only a fallback because app subviews consume most mouse events
- skin layout now exposes easy variables for channel/screen gap, side vessel height, vertical alignment, and signed offset
- the input panel has a real draggable resize handle and skin-driven container chrome
- `tools/mercury_deck/generate_assets.swift` is now the source for MercuryDeck's baked PNG assets

Locked dogfood baseline from 2026-04-24:
- keep `MercuryDeck` selected as the current proven skin baseline
- keep `layout.vesselGap = 20`
- keep `layout.channelVessel.height = 618`
- keep `layout.channelVessel.verticalAlign = "top"`
- keep `layout.channelVessel.verticalOffset = 18`
- keep traffic lights on the main text body landing dock, not the side channel spine
- keep root-level chrome drag regions on the visible metal frame; AppKit background dragging alone is not reliable
- keep default local shells opening in `~/projects`
- keep restored generic `Shell` channels dynamic so the tab label follows the current directory
- keep shell directory tracking independent of OSC 7 so `cd holoscape`, `cd ..`, `cd -`, and absolute `cd` update tabs even when zsh does not emit current-directory notifications
- keep the launcher semantics as: `holoscape` opens a shell in that project, `Claude` opens Claude in `~/projects`, `Claude holoscape` opens Claude in that project, and `ssh user@host` opens SSH
- keep Claude launch path resolved through `PATH` with `~/.local/bin` included; do not hardcode `/opt/homebrew/bin/claude`
- keep SSH home-directory launch from quoting `~`; use remote `$HOME` handling or no `cd` for plain home

Do not change the locked baseline without updating the corresponding tests:
- `MercuryDeckIntegrationTests`
- `MainWindowControllerChromeBranchTests`
- `MainWindowControllerVesselLayoutTests`
- `ShapedContentViewTests`
- `ShellChannelControllerTests`
- `ShellDirectoryTrackerTests`
- `SessionProfileManagerTests`
- `SSHChannelControllerTests`

What is still true for skinning:
- there is still one real macOS window and one real app interior
- the skin can extend outside the main text window by using transparent chrome space inside the larger window bounds
- true drawing outside the OS window bounds is not a supported AppKit path; use a larger transparent chrome canvas or child windows if that becomes a hard product requirement

What changed in this session:
- the message-board discussion got clarified into the right ownership boundary
- the right answer is not "Holoscape invents its own cross-computer mailbox"
- the right answer is "Project Tracker owns the canonical message ledger and cross-computer communication model; Holoscape surfaces that as a single `Message Board` tab"
- a concrete architecture brief was written at `docs/project-tracker-message-board-plan.md`
- a small separate Holoscape task was created for notification hook / client detection expansion so tab-state behavior can recognize `Claude`, `Clawed`, and `Codex`
- a Project Tracker proposal was created for the larger PT-owned message-board architecture

What is true now:
- Holoscape already has enough UI shape to surface this later because there is an existing chat-style channel/controller pattern
- Project Tracker already has the real durable primitive in `pt message` with `recipient` and `reply_to`
- `.claude/inbox` exists, but it should be treated as adjacent legacy plumbing or a compatibility shim, not the future source of truth for agent-to-agent communication
- `.codex` does not present a stable inbox/outbox convention worth building the architecture around

## Next Goal

Keep chrome/vessel work stable, but shift the next functional work around messaging into the correct split:

- Project Tracker defines the message-board model and API contract
- Holoscape later adds a thin PT-backed `Message Board` surface

Concrete target:
- do not start building a Holoscape-local message board store
- let Project Tracker decide whether the board is all `pt message` traffic or a metadata-filtered subset on the same ledger
- keep the smaller `Claude` / `Clawed` / `Codex` client-detection task independent so it can ship without waiting on the larger architecture

## Next Order Of Work

1. Keep the current chrome-host + vessel milestone as the stable baseline
2. Treat `docs/project-tracker-message-board-plan.md` as the handoff brief for PT ownership
3. Have Project Tracker decide the canonical semantics for the board on top of `messages`
4. Only after PT's contract exists, implement a PT-backed `Message Board` channel or controller in Holoscape
5. Separately implement the smaller hook/client-detection task for `Claude`, `Clawed`, and `Codex`

## Do Not Drift Into

- building a second message database inside Holoscape
- treating `.claude/inbox` or `.claude/outbox` as the permanent protocol
- coupling the message-board architecture to `.codex` internal state
- reopening `MercuryDeck` visual iteration instead of respecting the current engineering focus

## Constraints To Keep True

- one real Holoscape window with one real app interior
- vessel graphics still frame existing Holoscape content rather than replacing app behavior
- cross-computer message semantics belong to Project Tracker, not Holoscape
- Holoscape should become a surface for PT-backed communication, not its own source of truth
