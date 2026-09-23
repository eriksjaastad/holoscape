# Holoscape first-launch setup

Holoscape should start as a normal terminal before it asks for any macOS trust. Use this guide when installing on a fresh Mac or when Setup Diagnostics reports a warning.

Open **Holoscape > Setup Diagnostics…** first. It checks config/bootstrap errors, broker-host launch failures, notification authorization, Accessibility trust, Automation guidance, and crash diagnostics readability without forcing broad permission prompts. Actionable permission rows include an **Open System Settings** button for the matching macOS pane.

## Recommended first run

1. Build/install Holoscape normally.
2. Launch Holoscape and confirm a local shell opens.
3. Open **Holoscape > Setup Diagnostics…**.
4. Fix only the rows that apply to your workflow. Do not grant broad macOS privacy access just because a future feature might need it.

## Permissions and prompts

| Surface | When Holoscape needs it | macOS path | Setup guidance |
| --- | --- | --- | --- |
| Notifications | Off-screen channel alerts and notification click-through | System Settings > Notifications > Holoscape | Optional. Holoscape defers the permission prompt until the first eligible background notification. If denied, enable it here later. |
| Accessibility | Future/agent workflows that control UI, or test runners that drive the app | System Settings > Privacy & Security > Accessibility | Optional for normal terminal use. Enable Holoscape only if a workflow explicitly needs UI control. UI tests may also need the test runner re-approved after rebuilds. |
| Automation | Per-target Apple Events such as controlling System Events or another app | System Settings > Privacy & Security > Automation | Do not pre-grant anything proactively; macOS creates rows only after first use. Enable only the exact target apps Holoscape should control. |
| Full Disk Access | Reading crash reports if DiagnosticReports is unreadable on the machine | System Settings > Privacy & Security > Full Disk Access | Not recommended by default. Grant only if Setup Diagnostics says crash diagnostics are unreadable and recent-crash detection matters. |
| Network volumes | Shell/agent working directories under `/Volumes/...` | macOS prompts when a user-initiated process accesses the volume | Avoid auto-restored tabs parked on network volumes. Reconnect intentionally and grant once if that volume is part of the workflow. |

## Config and broker diagnostics

### Config file

Holoscape stores app-owned config under `~/.holoscape/config.json` unless `HOLOSCAPE_CONFIG_DIR` overrides it.

If Setup Diagnostics reports a config load/save failure:

1. Inspect the path shown in the diagnostic.
2. Repair malformed JSON instead of deleting it blindly.
3. Fix ownership/permissions if the directory is unwritable.
4. Relaunch or press **Refresh** in Setup Diagnostics.

Holoscape uses safe defaults when config cannot be loaded and does not overwrite malformed config automatically.

### Broker host launch

Broker-backed terminal sessions require Holoscape's bundled broker helper. If Setup Diagnostics reports a broker-host launch failure:

1. Rebuild Holoscape from a clean checkout.
2. Confirm the app bundle includes the broker host helper.
3. Relaunch Holoscape and refresh diagnostics.

Holoscape intentionally does not hide this behind an in-process fallback; missing broker infrastructure is a setup failure, not a degraded-success path.

## Prompt audit

The current audit lives at `docs/macos-permission-audit.md`. It found current or likely prompt surfaces for notifications, network volume working directories, Accessibility, Automation/Apple Events, and crash diagnostics. It did not find current production use of `NSOpenPanel`, `NSSavePanel`, security-scoped bookmarks, `NSAppleScript`, `osascript`, camera, microphone, contacts, calendars, location, or screen recording APIs.

If a future feature adds a new macOS privacy surface, update `docs/macos-permission-audit.md` and this setup guide in the same change.

## Screenshot note

This guide intentionally uses exact System Settings paths instead of checked-in screenshots for now. macOS Settings UI changes across releases; before public release, add current macOS screenshots for Notifications, Accessibility, Automation, and Full Disk Access from the supported OS version.
