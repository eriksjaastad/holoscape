# Holoscape global keybind pattern from Ghostty

Status: read-only spike for card #5932.

## Scope and decision

This spike reads Ghostty's macOS global-keybind implementation in `~/projects/github-repos/ghostty/macos/Sources/Features/Global Keybinds/` plus the config and action paths that decide when the event tap exists and what a captured key does.

Holoscape should **not add a global event tap now**. Card #5862 already delivered an in-app shortcut for opening a shell, and no current requirement needs a shortcut while another app is active. A global tap would add an Accessibility permission dependency and a system-wide input interception surface for no present daily-driver benefit.

If Holoscape later adds a quick-terminal or summon-window feature, Ghostty's pattern is a useful starting point: enable capture only when an explicit global binding exists, reuse the same typed action resolver used for local shortcuts, and consume an event only after that resolver confirms it handled the action.

## Ghostty's architecture

Ghostty divides the feature into four responsibilities:

1. **Configuration owns intent.** A binding marked `global:` is stored with a `global` flag. Global/all bindings cannot be multi-key sequences.
2. **Core action routing owns semantics.** `ghostty_app_key` resolves the event through the same binding set used for local keys. When the app is unfocused it rejects non-global bindings; global actions are dispatched through the app-wide action path.
3. **AppDelegate owns lifecycle.** After config load or reload, it asks `ghostty_app_has_global_keybinds(...)` whether any global binding exists, enabling or disabling the singleton event tap accordingly.
4. **GlobalEventTap owns only OS capture.** It converts `CGEvent` to `NSEvent`, then to Ghostty's existing key-event model. It does not maintain a second shortcut registry or execute UI commands itself.

That separation is the strongest part of the design. System-wide capture is an adapter around the command system, not a parallel command system.

## Event-tap lifecycle

`GlobalEventTap` is a singleton with two mutually exclusive live states:

- `eventTap != nil`: a tap exists;
- `enableTimer != nil`: the app is waiting for Accessibility trust.

`enable()` is idempotent while either state is active. It follows this sequence:

1. If already enabled or already polling, return.
2. If `AXIsProcessTrusted()` is true, try to create the tap once.
3. Otherwise call `AXIsProcessTrustedWithOptions` with the prompt flag once.
4. Poll the non-prompting trust check once per second.
5. When trust appears, invalidate the timer before attempting tap creation.
6. If creation fails despite trust, log the failure and stop rather than retrying forever.

The distinction in steps 3-5 is deliberate. The source notes that repeatedly attempting `CGEvent.tapCreate` without permission leaks a CoreGraphics Mach port, so Ghostty prompts once and polls the trust predicate instead.

`disable()` is also idempotent. It invalidates the permission timer and the tap's Mach port, then clears both references. Deinitialization calls `disable()`.

On app startup, Ghostty delays enabling for two seconds so the Accessibility prompt is not buried beneath initial windows. On later config reloads it enables immediately. If config no longer contains global bindings, AppDelegate disables the tap.

## Capture and dispatch behavior

Ghostty creates a `.cgSessionEventTap` at `.headInsertEventTap` with `.defaultTap`, listening only for `keyDown`.

The tap source is installed on the main run loop in common modes. The callback must therefore stay small:

1. Return the original event for everything except `keyDown` and tap-disabled notifications.
2. Re-enable the existing tap if macOS disabled it because of timeout or user input.
3. Ignore captured keys while Ghostty is active, because AppDelegate's local `NSEvent` monitor handles those.
4. Resolve AppDelegate and the Ghostty app instance.
5. Convert the `CGEvent` to `NSEvent`, then to Ghostty's core key-event representation.
6. Call `ghostty_app_key`.
7. Return `nil` only when the core reports that it handled the key; otherwise return the original event unchanged.

This produces exactly one routing path for active and inactive application states. The difference is capture source, not command semantics.

## Permission and failure contract

A global event tap changes Holoscape's current permission story.

Today `docs/macos-permission-audit.md` says Accessibility is diagnostic-only and no production feature requests it. A global keybind feature would make Accessibility a functional dependency for configured global bindings, so the audit, setup diagnostics, and setup guide would need to change in the same PR.

The feature must remain optional:

- no global bindings means no prompt, timer, or event tap;
- denied permission must not affect ordinary terminal startup or local shortcuts;
- the UI must distinguish `disabled`, `waitingForPermission`, `enabled`, and `failedToCreateTap` rather than silently pretending a binding works;
- removing the final global binding must cancel permission polling and disable capture;
- plugin absence or failure must never affect the capture service or core terminal startup.

Ghostty logs tap-creation failure but exposes no user-facing state in this module. Holoscape should improve that contract through its existing Setup Diagnostics surface instead of copying the silent UI behavior.

## What Holoscape should copy

### 1. One command registry for local and global shortcuts

A shortcut descriptor should contain a typed action and a scope such as `local` or `global`. Both AppKit menu shortcuts and a future global capture adapter should invoke the same resolver. Do not duplicate selectors, closures, or key parsing in the event-tap service.

The resolver should return an explicit handled result. The global adapter may suppress the system event only after receiving `handled`; unavailable, invalid, or failed actions should leave the event untouched unless the action contract explicitly says otherwise.

### 2. Demand-driven capture

Enable system-wide capture only when the effective configuration contains at least one enabled global binding. Re-evaluate after every config change. This keeps Accessibility prompts out of the default first-launch path.

### 3. Explicit lifecycle state

Model capture lifecycle as testable state rather than two loosely related optionals. At minimum:

- disabled;
- awaiting Accessibility permission;
- enabling;
- enabled;
- failed with a diagnostic.

Use a generation/token for delayed enable work so a stale startup delay cannot re-enable capture after config removes the last global binding. Ghostty's uncancelled `asyncAfter` enable is a pattern Holoscape should not copy.

### 4. Bounded callback work

The event-tap callback should only normalize, resolve, enqueue an already-authorized typed action when necessary, and return. It must not perform broker RPCs, filesystem access, plugin IPC, process launch waits, or any other blocking work. macOS can disable slow taps; re-enabling is recovery, not permission to block repeatedly.

### 5. Observable permission recovery

Reuse Setup Diagnostics for trust state, a direct System Settings link, and tap-creation failure. Prompt only from a user-authored global binding or explicit enable action. Do not request Accessibility during normal first launch.

## What Holoscape should not copy

- **Do not introduce the tap for an in-app shortcut.** AppKit menu key equivalents already handle those without Accessibility permission.
- **Do not hardwire a Project Tracker action.** External commands must remain removable plugin descriptors routed through the plugin command boundary.
- **Do not execute commands directly in the C callback.** The callback is an input adapter, not a controller.
- **Do not infer success from permission alone.** `AXIsProcessTrusted()` can be true while tap creation still fails.
- **Do not retry tap creation forever.** Preserve a diagnostic and require a bounded, explicit retry path.
- **Do not allow a stale delayed enable to override newer config.** Cancel or invalidate delayed work with a generation check.
- **Do not consume unknown keys.** Returning the original event is the safe default.
- **Do not route app commands by writing bytes into the active PTY.** Summon/new-window/new-channel actions belong to typed app controllers.

## Suggested future design

Only create implementation cards when Holoscape has a concrete cross-application shortcut requirement, such as summoning a persistent quick terminal.

1. **Define global shortcut configuration and conflict validation.** Keep typed actions and stable command ids in core; reject sequences and ambiguous duplicates before activation.
2. **Add a permission-aware capture service.** Inject trust checks, prompt calls, tap creation, scheduling, and event routing for deterministic tests.
3. **Connect capture to the existing command resolver.** Local and global paths must produce the same action result and target selection.
4. **Expose Setup Diagnostics state.** Show denied, waiting, enabled, and failed-to-create states without making terminal startup depend on them.
5. **Add app-hosted smoke coverage.** Unit-test lifecycle and routing with seams; validate the real Accessibility/tap behavior in an app-hosted manual smoke test because headless tests cannot safely grant TCC permissions.

## Required behavior matrix for a future implementation

| Configuration / runtime state | Expected result |
| --- | --- |
| No global bindings | No prompt, polling, or event tap |
| First global binding, permission absent | One prompt request; non-leaking trust polling; local terminal remains usable |
| Binding removed while polling | Polling stops; stale delayed work cannot create a tap |
| Permission granted | One tap creation attempt; state becomes enabled or a visible failure |
| Tap creation fails despite trust | No infinite retry; diagnostic remains actionable |
| App active | Local monitor handles the binding; global callback passes the event through |
| App inactive, matching global binding | Typed action runs once; event is consumed only when handled |
| App inactive, local-only or unknown binding | Event passes through unchanged |
| macOS disables tap | Existing tap is re-enabled without duplicating sources |
| Config reload changes bindings | Capture lifecycle and resolver use the same new config generation |
| Plugin command becomes unavailable | Core remains usable; event is not falsely reported as handled |
| Secure input or teardown occurs | No stuck enabled state, duplicate tap, or unbounded retry |

## Verification strategy for future code

Deterministic tests should cover:

- idempotent enable/disable;
- prompt-once behavior and trust polling without repeated tap creation;
- cancellation while waiting for permission;
- stale startup-delay rejection after config reload;
- creation failure after trust and explicit retry;
- active/inactive routing without double execution;
- handled versus pass-through event consumption;
- tap-disabled recovery;
- plugin-unavailable behavior;
- no blocking broker/plugin work on the callback path.

A real app-hosted smoke test should verify an actual configured shortcut while another app is frontmost, denial and later grant of Accessibility permission, config removal, and app termination. This cannot be replaced by a unit test that only asserts a callback was non-null.

## Source map

- `macos/Sources/Features/Global Keybinds/GlobalEventTap.swift` — permission prompt/polling, event-tap creation, run-loop attachment, callback filtering, tap recovery, and event consumption.
- `macos/Sources/App/AppDelegate.swift` — local event monitor plus config-driven global tap enable/disable and launch-delay behavior.
- `src/input/Binding.zig` — global binding flag, parser restrictions, and action definitions.
- `src/App.zig` — app-scope key resolution, focused/unfocused filtering, and global action dispatch.
- `src/apprt/embedded.zig` — `hasGlobalKeybinds` scan and exported C API.
- `include/ghostty.h` — public `ghostty_app_has_global_keybinds` declaration.
