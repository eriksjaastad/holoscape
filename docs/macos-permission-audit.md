# macOS Permission Prompt Audit

Card: #5871  
Scope: Holoscape launch and normal terminal use. This audit lists code paths that can cause macOS privacy, notification, or network-volume prompts and separates confirmed prompt sources from low-risk local app-storage access.

## Summary

| Surface | Prompt risk | Current behavior | Next hardening |
| --- | --- | --- | --- |
| User notifications | Confirmed TCC prompt | Deferred until first eligible background notification | Covered by setup diagnostics; include in setup guide. |
| Network volume working directories | Confirmed TCC prompt | Restored `/Volumes/...` tabs no longer auto-launch fresh processes without a broker session | Keep explicit reconnect user-initiated; include in setup guide. |
| Accessibility | Possible TCC prompt when workflows need UI control | Diagnostics read trust state with `AXIsProcessTrusted()` only | Keep as diagnostic/setup guidance until a feature actually needs it. |
| Automation / Apple Events | Possible TCC prompt if Holoscape controls System Events or other apps | No direct Apple Event sender found in current source; diagnostics warn because planned workflows may need it | Do not request proactively; document per-target Automation grant flow. |
| Crash logs | Possible Full Disk Access edge case, no prompt expected for own user logs | Reads `~/Library/Logs/DiagnosticReports` after launch to find Holoscape crashes | Fail silent today; setup diagnostics could surface unreadable diagnostics directory later. |
| Shell/agent subprocess cwd | Inherits file access risk of selected cwd | Local broker sets `Process.currentDirectoryURL` from saved/profile directory | Treat user-selected protected locations as user-initiated; avoid auto-starting risky saved paths. |
| Project discovery SSH | No macOS privacy prompt expected | Runs `/usr/bin/ssh` to remote host and `ls` configured root | Network/auth failure only; no TCC hardening needed. |
| Skin/config/scrollback storage | No prompt expected when under app-owned user paths | Reads/writes `~/.holoscape`, user caches, bundled resources | Keep user-installed skin paths under `~/.holoscape/skins`; avoid arbitrary recursive scans. |

## Confirmed or high-probability prompt sources

### Notifications

Source:
- `Sources/Holoscape/Services/NotificationService.swift`
- `Sources/Holoscape/Services/SetupDiagnosticsService.swift`

Prompt trigger:
- `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])`

Current behavior:
- App launch does not request notification permission.
- Permission is requested lazily only when Holoscape is in the background and an eligible channel notification would be delivered.
- Setup Diagnostics checks notification settings without prompting.

Setup guidance:
- User should grant notifications in the first background-notification prompt, or review System Settings > Notifications > Holoscape if denied.

### Network volume working directories

Sources:
- `Sources/Holoscape/AppDelegate.swift`
- `Sources/Holoscape/Services/NativePTYBrokerSessionRuntime.swift`
- `Sources/Holoscape/Controllers/ShellChannelController.swift`
- `Sources/Holoscape/Controllers/AgentChannelController.swift`

Prompt trigger:
- Launching a new local shell/agent process with `Process.currentDirectoryURL` set to a path under `/Volumes/...` can cause macOS to ask for network volume access.

Current behavior after #5870:
- On restore, saved shell/agent tabs under `/Volumes/...` do not auto-launch a fresh process unless a broker session exists to reattach.
- Tabs remain visible and can be reconnected explicitly by the user, making the prompt user-initiated instead of recurring every launch.

Setup guidance:
- Avoid parking auto-restored tabs in network volume directories unless the broker session is already alive.
- If a network volume is needed, launch/reconnect the tab intentionally and grant access once.

### Accessibility

Source:
- `Sources/Holoscape/Services/SetupDiagnosticsService.swift`

Prompt trigger:
- No prompt is triggered by the current diagnostics path. `AXIsProcessTrusted()` reads trust state.
- Future UI-control workflows may require Accessibility permission.

Current behavior:
- Setup Diagnostics reports whether Holoscape is trusted for Accessibility automation.

Setup guidance:
- System Settings > Privacy & Security > Accessibility > enable Holoscape only if agent/setup workflows need UI control.

### Automation / Apple Events

Source:
- `Sources/Holoscape/Services/SetupDiagnosticsService.swift`

Prompt trigger:
- No current direct sender found for `NSAppleScript`, Apple Event descriptors, `osascript`, or System Events control in `Sources/Holoscape`.
- macOS Automation prompts would appear per target app if a future workflow controls System Events or another app.

Current behavior:
- Setup Diagnostics warns that Automation is per-target and may prompt on first use.

Setup guidance:
- Do not pre-grant nonexistent targets. After first use, review System Settings > Privacy & Security > Automation and enable only the specific target apps Holoscape should control.

## Lower-risk file access inventory

### App-owned config, history, scrollback, and skin data

Sources:
- `Sources/Holoscape/Services/ConfigService.swift`
- `Sources/Holoscape/Services/HistoryBuffer.swift`
- `Sources/Holoscape/Services/DiskBackedScrollbackStore.swift`
- `Sources/Holoscape/Services/SkinEngine.swift`
- `Sources/Holoscape/Services/ChromeBakePipeline.swift`

Paths:
- `~/.holoscape/config.json`
- `~/.holoscape/history-buffer.json`
- `~/.holoscape/skins`
- user caches under `~/Library/Caches/...`
- bundled package resources

Prompt risk:
- Low, because these are normal user-home app support/cache locations or bundled resources.
- User-installed skins can reference assets, but path traversal and symlink escape checks keep asset reads inside the skin directory.

### Crash diagnostics

Source:
- `Sources/Holoscape/Services/CrashReportScanner.swift`

Path:
- `~/Library/Logs/DiagnosticReports`

Prompt risk:
- Usually readable for the current user; may fail under stricter privacy settings.
- Current scanner returns no crashes if the directory cannot be listed/read.

Hardening candidate:
- Add a Setup Diagnostics item if the diagnostics directory is unreadable, but do not request Full Disk Access by default.

### Remote project discovery

Source:
- `Sources/Holoscape/Services/ProjectDiscoveryService.swift`

Behavior:
- Runs `/usr/bin/ssh` to `user@host` and executes `ls -1 <root>`.

Prompt risk:
- No macOS privacy prompt expected. Failures are SSH/network/auth failures, not TCC.

## Not found in current source

The audit did not find current production use of:

- `NSOpenPanel` / `NSSavePanel`
- security-scoped bookmarks
- `NSAppleScript`
- direct Apple Event descriptor sending
- `osascript`
- direct Full Disk Access APIs
- camera, microphone, contacts, calendars, location, screen recording APIs

## Follow-up recommendations

1. Keep #5881 focused on a user-facing setup guide/wizard using this inventory.
2. Do not add broad permission prompts at launch. Prefer diagnostics plus user-initiated actions.
3. If future features add Apple Events, file pickers, screen recording, or security-scoped bookmarks, update this audit in the same PR as the feature.
4. Consider a small diagnostics addition for unreadable crash diagnostics only if crash-reporting dogfood shows silent misses.
