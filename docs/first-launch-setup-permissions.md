# First-launch setup and macOS permission flow audit

Status: Phase 4 first slice for #7172.

## Scope

This audit focuses on the setup/permission behavior a daily-driver terminal user sees before Holoscape is trusted:

- config directory/bootstrap writes;
- default first channel creation;
- crash-report retry/check timing;
- notification permission prompts;
- boundaries that must stay inside Holoscape core.

Project Tracker, external workboards, and cross-computer sync remain out of core and must stay plugin-scoped.

## Current behavior checked

- `ConfigService.load()` creates `~/.holoscape/config.json` or `$HOLOSCAPE_CONFIG_DIR/config.json` when absent.
- `AppDelegate.applicationDidFinishLaunching` creates the window, restores saved/broker sessions when allowed, and falls back to a shell in `DefaultWorkingDirectory.preferredURL`.
- Crash report retry/check happens after the window exists and is skipped under UI testing.
- Notifications are optional app behavior, controlled by `NotificationConfig`.

## First-launch gap closed in this slice

Before this slice, `AppDelegate` created `NotificationService` and then scheduled `requestAuthorization()` three seconds after launch. That meant a first-launch Holoscape user could get a macOS notification TCC prompt before seeing why notifications matter.

That is poor terminal setup behavior: a terminal should open and be usable before asking for OS-level trust.

This slice changes notification authorization to be lazy:

- constructing `NotificationService` does not request permission;
- active-window output does not request permission;
- disabled notification config does not request permission;
- the first eligible background notification requests authorization and, if granted, delivers that notification.

Regression coverage: `NotificationServiceTests` verifies each of those paths with an injected notification-center client.

## #7172 close-out

The first-launch/setup slice now covers:

1. Config/bootstrap failure behavior:
   - malformed config still starts with defaults, but the corrupt file is not overwritten;
   - config directory path conflicts record a load/save diagnostic instead of silently poisoning the in-memory cache with unsaved settings;
   - `ConfigService.lastDiagnostic` exposes the failing operation/path/message for the setup diagnostics surface.
2. A visible **Holoscape > Setup Diagnostics…** surface for config failures, broker host launch failures, notification permission state, Accessibility trust, Automation guidance, and crash diagnostics readability.
3. A macOS privacy audit at `docs/macos-permission-audit.md`, including shell/agent working directories, network volume restore behavior, crash-report storage, and current non-use of broader TCC APIs.
4. A first-launch setup guide at `SETUP.md` with exact System Settings paths and the policy that broad permissions stay optional/user-initiated.
5. Project Tracker remains absent from setup: core first launch works as a standalone terminal.
