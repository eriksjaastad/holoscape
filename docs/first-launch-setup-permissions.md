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

## Remaining #7172 slices

1. Audit config/bootstrap failure behavior: `ConfigService.load()` currently falls back to defaults after load errors and attempts to save defaults. Decide which errors should fail loudly vs. recover.
2. Add a visible setup/diagnostics surface for missing/unwritable config, broker host launch failures, and notification permission state.
3. Review macOS privacy surfaces beyond notifications: shell/agent process launch environment, crash-report storage, and any future Automation/Accessibility/Full Disk Access claims.
4. Keep Project Tracker absent from setup: core first launch must work as a standalone terminal.
