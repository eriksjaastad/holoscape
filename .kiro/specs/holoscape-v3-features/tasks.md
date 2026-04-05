# Implementation Plan: Holoscape V3 Features

## Overview

Incremental implementation of six V3 features on top of the existing V1/V1.5/V2 Holoscape codebase. Tasks modify and extend existing Swift/AppKit code — no rebuild. Each task references specific requirements and builds on previous steps. Property tests use SwiftCheck (already a dependency).

## Tasks

- [ ] 1. Extend V3 data models and enums
  - [ ] 1.1 Add `.bridge` case to `ConnectionType` and `ChannelType` enums
    - Modify `Sources/Holoscape/Models/ChannelType.swift` to add `case bridge`
    - Modify `SessionProfile.swift` or wherever `ConnectionType` is defined to add `case bridge`
    - _Requirements: 3.7, 3.8_

  - [ ] 1.2 Add `pinnedAt: Date?` field to `ChannelMetadata`
    - Modify `Sources/Holoscape/Models/ChannelMetadata.swift` to add optional `pinnedAt` field
    - Ensure `CodingKeys` includes `pinnedAt` and existing init/decode handles nil for backward compat
    - _Requirements: 4.7_

  - [ ] 1.3 Create `NotificationConfig` model
    - Create `Sources/Holoscape/Models/NotificationConfig.swift` with `enabled: Bool` and `perChannelType: [String: Bool]?`
    - Include `static let default` with shell=false, agent/ssh/mcp/groupChat=true
    - _Requirements: 1.7_

  - [ ] 1.4 Create `SplitLayoutConfig` and `PaneConfig` models
    - Create `Sources/Holoscape/Models/SplitLayoutConfig.swift` with `panes: [PaneConfig]` and `activePaneId: UUID?`
    - `PaneConfig` has `paneId: UUID` and `channelId: UUID`
    - _Requirements: 2.8_

  - [ ] 1.5 Create `SkinDefinition` model
    - Create `Sources/Holoscape/Models/SkinDefinition.swift` with color hex fields, ANSI array, image path fields, and `resolvedSkinDirectory: URL?` (excluded from Codable)
    - _Requirements: 6.2, 6.3_

  - [ ] 1.6 Extend `HoloscapeConfig` and `AppearanceConfig` with V3 fields
    - Add `notifications: NotificationConfig?` and `splitLayout: SplitLayoutConfig?` to `HoloscapeConfig`
    - Add `skinName: String?` to `AppearanceConfig`
    - All fields optional for backward compatibility with V2 configs
    - _Requirements: 1.7, 2.8, 6.7_

  - [ ]* 1.7 Write property test for V3 config serialization round-trip
    - **Property 1: V3 Config serialization round-trip**
    - Create `Tests/HoloscapePropertyTests/ConfigV3RoundTripPropertyTests.swift`
    - Generate random `HoloscapeConfig` with V3 fields, verify `decode(encode(value)) == value`
    - **Validates: Requirements 1.7, 2.8, 4.7, 6.2, 6.3, 6.7**

  - [ ]* 1.8 Write property test for V2 config backward compatibility
    - **Property 19: V2 config backward compatibility with V3**
    - Create `Tests/HoloscapePropertyTests/ConfigV3BackwardCompatPropertyTests.swift`
    - Generate V2-only configs, encode, decode as V3, verify V2 fields preserved and V3 fields nil
    - **Validates: Requirements 1.7, 6.7**

  - [ ]* 1.9 Write property test for ConnectionType and ChannelType enum round-trip
    - **Property 20: ConnectionType and ChannelType enum round-trip**
    - Create `Tests/HoloscapePropertyTests/EnumRoundTripV3PropertyTests.swift`
    - Verify `Type(rawValue: case.rawValue) == case` for all cases including `.bridge`
    - **Validates: Requirements 3.7, 3.8**

  - [ ]* 1.10 Write unit tests for V3 model encoding/decoding
    - Create `Tests/HoloscapeTests/Unit/V3ModelTests.swift`
    - Test `NotificationConfig`, `SplitLayoutConfig`, `SkinDefinition`, `ChannelMetadata` with `pinnedAt`, and config backward compat
    - _Requirements: 1.7, 2.8, 4.7, 6.2, 6.3, 6.7_

- [ ] 2. Checkpoint — Ensure all model tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 3. Implement NotificationService
  - [ ] 3.1 Create `NotificationService` and `NotificationChannelSwitchDelegate`
    - Create `Sources/Holoscape/Services/NotificationService.swift`
    - Implement `requestAuthorization()`, `notifyIfNeeded(channel:firstLine:)`, and `UNUserNotificationCenterDelegate` methods
    - Guard conditions: `authorized`, `!NSApp.isActive`, `config.notifications.enabled`, per-channel-type toggle
    - Notification content: channel label as title, first line truncated to 100 chars as body, channel UUID as thread identifier and userInfo
    - Click handler: bring app to front via `NSApp.activate()`, call delegate `switchToChannel()`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.8, 1.9_

  - [ ] 3.2 Integrate NotificationService into AppDelegate and MainWindowController
    - Initialize `NotificationService` in `AppDelegate`, call `requestAuthorization()` on launch
    - Set `MainWindowController` as `channelSwitchDelegate`
    - In `MainWindowController.channelDidReceiveOutput`, call `notificationService.notifyIfNeeded()`
    - _Requirements: 1.1, 1.4_

  - [ ] 3.3 Add notification toggles to AppearanceSettingsWindowController
    - Add a "Notifications" section with global enable/disable toggle and per-channel-type toggles (shell, agent, SSH, MCP, group chat)
    - Read/write `NotificationConfig` via `ConfigService`
    - _Requirements: 1.10_

  - [ ]* 3.4 Write property test for notification guard conditions
    - **Property 2: Notification delivery respects guard conditions**
    - Create `Tests/HoloscapePropertyTests/NotificationGuardPropertyTests.swift`
    - Generate random `NotificationConfig`, channel types, app active states; verify delivery logic
    - **Validates: Requirements 1.6, 1.8, 1.9**

  - [ ]* 3.5 Write property test for notification content construction
    - **Property 3: Notification content construction**
    - Create `Tests/HoloscapePropertyTests/NotificationContentPropertyTests.swift`
    - Generate random labels and output lines; verify title = label, body ≤ 100 chars
    - **Validates: Requirements 1.3**

  - [ ]* 3.6 Write unit tests for NotificationService
    - Create `Tests/HoloscapeTests/Unit/NotificationServiceTests.swift`
    - Test with app active (no notification), enabled=false, specific type disabled, content construction, click routing
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.8, 1.9_

- [ ] 4. Implement SplitPaneManager and SplitPaneView
  - [ ] 4.1 Create `SplitPaneView`
    - Create `Sources/Holoscape/Views/SplitPaneView.swift`
    - NSView subclass with `paneId: UUID`, content view management, active border highlight (blue when active, clear when inactive), and `onClicked` callback via `mouseDown`
    - _Requirements: 2.4_

  - [ ] 4.2 Create `SplitPaneManager`
    - Create `Sources/Holoscape/Views/SplitPaneManager.swift` (or Controllers/)
    - Implement `showContent()`, `splitHorizontal()`, `splitVertical()`, `closeActivePane()`, `setActivePane()`, `removeChannel()`, `exportLayout()`
    - Recursive NSSplitView nesting, max 4 panes, active pane tracking with `SplitPaneManagerDelegate`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.6, 2.7, 2.8, 2.9, 2.10_

  - [ ] 4.3 Integrate SplitPaneManager into MainWindowController
    - Replace single `TerminalContainerView` usage with `SplitPaneManager`
    - Add keyboard shortcuts: Cmd+D → `splitHorizontal()`, Cmd+Shift+D → `splitVertical()`, Cmd+Shift+W → `closeSplitPane()`
    - Route input to active pane's channel via `splitPaneManager.activeChannelId`
    - Track active pane ID independently from sidebar selection
    - Persist split layout to `HoloscapeConfig.splitLayout` on changes and restore on launch
    - _Requirements: 2.1, 2.2, 2.5, 2.6, 2.8, 2.9_

  - [ ]* 4.4 Write property tests for split pane count
    - **Property 4: Split operation increases pane count**
    - Create `Tests/HoloscapePropertyTests/SplitPaneCountPropertyTests.swift`
    - Generate random pane counts (1-4) and orientations; verify count = min(initial+1, 4)
    - **Validates: Requirements 2.1, 2.2, 2.3**

  - [ ]* 4.5 Write property test for close pane count
    - **Property 5: Close pane decreases pane count**
    - Create `Tests/HoloscapePropertyTests/ClosePaneCountPropertyTests.swift`
    - Generate random pane counts (1-4); verify count = max(initial-1, 1)
    - **Validates: Requirements 2.6, 2.7**

  - [ ]* 4.6 Write property test for active pane input routing
    - **Property 6: Active pane input routing**
    - Create `Tests/HoloscapePropertyTests/ActivePaneRoutingPropertyTests.swift`
    - Generate multi-pane configs, set each as active, verify `activeChannelId` matches
    - **Validates: Requirements 2.5**

  - [ ]* 4.7 Write property test for channel close removes pane
    - **Property 7: Channel close removes its pane**
    - Create `Tests/HoloscapePropertyTests/ChannelClosePanePropertyTests.swift`
    - Generate multi-pane configs, close a channel, verify pane removed
    - **Validates: Requirements 2.10**

  - [ ]* 4.8 Write unit tests for SplitPaneManager
    - Create `Tests/HoloscapeTests/Unit/SplitPaneManagerTests.swift`
    - Test single→split→2 panes, split at 4 (no-op), close at 2→1, close at 1 (no-op), removeChannel
    - _Requirements: 2.1, 2.2, 2.3, 2.6, 2.7, 2.10_

- [ ] 5. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 6. Implement BridgeChannelController
  - [ ] 6.1 Add `agentChannels()` helper to ChannelManager
    - Extend `Sources/Holoscape/Controllers/ChannelManager.swift` with `agentChannels()` method
    - Filter `allChannels()` for active channels with types `.agentDirect`, `.agentAPI`, `.ssh`, `.mcp`
    - _Requirements: 3.2_

  - [ ] 6.2 Create `BridgeChannelController`
    - Create `Sources/Holoscape/Controllers/BridgeChannelController.swift`
    - Implement `ChannelController` protocol with NSTextView-based content view
    - `sendInput()`: query `channelManager.agentChannels()`, forward to each, log broadcast in text view
    - Display `[System] No active agent channels to broadcast to.` when no agents active
    - Log format: `[H:MM AM/PM] → broadcast: <message text>`
    - _Requirements: 3.2, 3.3, 3.4, 3.5, 3.6, 3.10_

  - [ ] 6.3 Add Bridge session profile and wire into ChannelManager
    - Add preconfigured "Bridge" profile to `SessionProfileManager`
    - In `ChannelManager.createChannel(from:)`, handle `.bridge` connection type by creating `BridgeChannelController`
    - _Requirements: 3.1, 3.9_

  - [ ]* 6.4 Write property test for bridge forwarding to agents only
    - **Property 8: Bridge channel forwards to agents only**
    - Create `Tests/HoloscapePropertyTests/BridgeForwardingPropertyTests.swift`
    - Generate mixed channel sets; verify bridge forwards to agents only, not shell/groupChat/bridge
    - **Validates: Requirements 3.2, 3.3, 3.4**

  - [ ]* 6.5 Write property test for bridge broadcast log formatting
    - **Property 9: Bridge broadcast log formatting**
    - Create `Tests/HoloscapePropertyTests/BridgeLogFormatPropertyTests.swift`
    - Generate random messages and timestamps; verify log matches `[H:MM AM/PM] → broadcast: <text>`
    - **Validates: Requirements 3.5**

  - [ ]* 6.6 Write property test for bridge empty agent list
    - **Property 18: Bridge channel empty agent list message**
    - Create `Tests/HoloscapePropertyTests/BridgeEmptyAgentsPropertyTests.swift`
    - Generate random input texts with no agents; verify system message displayed
    - **Validates: Requirements 3.10**

  - [ ]* 6.7 Write unit tests for BridgeChannelController
    - Create `Tests/HoloscapeTests/Unit/BridgeChannelControllerTests.swift`
    - Test sendInput with mock agents + shell (agents receive, shell doesn't), no agents (system message), log format
    - _Requirements: 3.2, 3.3, 3.4, 3.5, 3.10_

- [ ] 7. Implement Tab Pinning
  - [ ] 7.1 Add pin management to MainWindowController
    - Add `pinnedChannelIds: Set<UUID>` and `pinnedTimestamps: [UUID: Date]` properties
    - Implement `contextMenuTogglePin()` action
    - Modify unread reordering to skip pinned channels
    - Persist pin state via `ChannelMetadata.pinnedAt` in config save/restore
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.7_

  - [ ] 7.2 Modify SidebarView for pinned section
    - Update `SidebarView.updateTabs()` to accept `pinnedIds: Set<UUID>` parameter
    - Render pinned tabs in a fixed section at top with separator, unpinned below
    - Sort pinned tabs by `pinnedAt` ascending (earliest first)
    - Add pin icon (📌) to `SidebarTabEntry` for pinned tabs
    - _Requirements: 4.2, 4.4, 4.5, 4.6_

  - [ ] 7.3 Modify TabBarView for pinned section
    - Update `TabBarView` to render pinned tabs in a fixed left section
    - Pinned tabs don't reorder on unread changes
    - _Requirements: 4.2, 4.5_

  - [ ] 7.4 Add Pin/Unpin to context menu
    - Extend the existing right-click context menu in `MainWindowController.buildContextMenu(for:)` with "Pin"/"Unpin" item
    - Show "Pin" for unpinned channels, "Unpin" for pinned channels
    - _Requirements: 4.1_

  - [ ]* 7.5 Write property tests for pin management
    - **Property 10: Pin/unpin round-trip** — Create `Tests/HoloscapePropertyTests/PinUnpinRoundTripPropertyTests.swift`
    - **Property 11: Pinned tab ordering by timestamp** — Create `Tests/HoloscapePropertyTests/PinOrderingPropertyTests.swift`
    - **Property 12: Unread reordering preserves pinned positions** — Create `Tests/HoloscapePropertyTests/PinnedPositionPropertyTests.swift`
    - **Property 13: Context menu shows correct pin action** — Create `Tests/HoloscapePropertyTests/PinContextMenuPropertyTests.swift`
    - **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5**

  - [ ]* 7.6 Write unit tests for pin management
    - Create `Tests/HoloscapeTests/Unit/PinManagementTests.swift`
    - Test pin/unpin toggle, pinned ordering with specific timestamps, unread reordering with pinned channels
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.7_

- [ ] 8. Implement Search (Cmd+F)
  - [ ] 8.1 Create `SearchBarView`
    - Create `Sources/Holoscape/Views/SearchBarView.swift`
    - NSView with search text field, match count label, prev/next/close buttons
    - `SearchBarDelegate` protocol for query changes, next/prev/close actions
    - Accessibility: role=toolbar, title="Search Bar"
    - _Requirements: 5.1, 5.7_

  - [ ] 8.2 Integrate SearchBarView into MainWindowController
    - Add search bar below tab bar with height constraint (0 when hidden, 32 when visible)
    - Cmd+F toggles visibility and focuses search field
    - Escape closes search bar and clears highlights
    - Implement `SearchBarDelegate`: on query change, search active channel's buffer; on next/prev, navigate matches
    - For PTY channels: use SwiftTerm `TerminalView.search()` or buffer text extraction
    - For NSTextView channels: search `NSTextStorage` with range-based matching
    - Limit search to most recent 10,000 lines
    - On active channel change while search bar open: clear results and re-execute query
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.8, 5.9_

  - [ ]* 8.3 Write property tests for search
    - **Property 14: Search match navigation wraps correctly** — Create `Tests/HoloscapePropertyTests/SearchNavigationPropertyTests.swift`
    - **Property 15: Search finds all occurrences** — Create `Tests/HoloscapePropertyTests/SearchMatchCountPropertyTests.swift`
    - **Validates: Requirements 5.2, 5.3, 5.4**

  - [ ]* 8.4 Write unit tests for SearchBarView
    - Create `Tests/HoloscapeTests/Unit/SearchBarTests.swift`
    - Test match count display (0 → "No matches", 5 at index 2 → "3 of 5"), clear resets state
    - _Requirements: 5.1, 5.7_

- [ ] 9. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 10. Implement Skin Engine
  - [ ] 10.1 Create `SkinEngine`
    - Create `Sources/Holoscape/Services/SkinEngine.swift`
    - Implement `availableSkins()` — list directories under `~/.holoscape/skins/` that contain `skin.json`, prepend "Default"
    - Implement `loadSkin(named:)` — return nil for "Default" or invalid skins, decode `skin.json` as `SkinDefinition`, resolve image paths
    - Implement `apply(skin:to:)` — merge skin colors into `AppearanceConfig`
    - _Requirements: 6.1, 6.4, 6.6, 6.8, 6.9_

  - [ ] 10.2 Add skin picker to AppearanceSettingsWindowController
    - Add a dropdown listing `SkinEngine.availableSkins()`
    - On selection: load skin, apply to appearance config, save `skinName` to config
    - On launch: if `skinName` is set, load and apply; if load fails, fall back to Default
    - _Requirements: 6.5, 6.7_

  - [ ]* 10.3 Write property tests for skin engine
    - **Property 16: Skin application sets correct colors** — Create `Tests/HoloscapePropertyTests/SkinApplicationPropertyTests.swift`
    - **Property 17: Invalid skin falls back to nil** — Create `Tests/HoloscapePropertyTests/InvalidSkinFallbackPropertyTests.swift`
    - **Validates: Requirements 6.4, 6.8**

  - [ ]* 10.4 Write unit tests for SkinEngine and SkinDefinition
    - Create `Tests/HoloscapeTests/Unit/SkinEngineTests.swift` and `Tests/HoloscapeTests/Unit/SkinDefinitionTests.swift`
    - Test availableSkins with empty dir → ["Default"], loadSkin("Default") → nil, loadSkin with valid/invalid dirs, apply with known skin, SkinDefinition JSON decoding
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.8_

- [ ] 11. Wire everything together and final integration
  - [ ] 11.1 Add Bridge profile to SessionProfileManager
    - Modify `Sources/Holoscape/Services/SessionProfileManager.swift` to include preconfigured Bridge profile in default profiles
    - _Requirements: 3.1_

  - [ ] 11.2 Apply skin on app launch and skin change
    - In `MainWindowController` or `AppDelegate`, on launch: check `config.appearance.skinName`, load via `SkinEngine`, apply colors to all views (sidebar, tab bar, terminal background, ANSI palette)
    - On skin change from settings: reload and reapply
    - _Requirements: 6.4, 6.6, 6.7_

  - [ ] 11.3 Persist and restore split layout on quit/launch
    - On quit: call `splitPaneManager.exportLayout()`, save to `config.splitLayout`
    - On launch: if `config.splitLayout` exists, restore panes with matching channels
    - Handle missing channels gracefully (skip invalid panes, fall back to single pane)
    - _Requirements: 2.8_

  - [ ] 11.4 Persist and restore pin state on quit/launch
    - On config save: write `pinnedAt` timestamps into `ChannelMetadata`
    - On config load: reconstruct `pinnedChannelIds` and `pinnedTimestamps` from `ChannelMetadata.pinnedAt`
    - _Requirements: 4.7_

  - [ ]* 11.5 Write integration tests for V3 feature wiring
    - Create `Tests/HoloscapeTests/Unit/V3IntegrationTests.swift`
    - Test notification flow end-to-end with mock UNUserNotificationCenter
    - Test bridge → agent forwarding with mock channels
    - Test config save/restore cycle with V3 fields
    - _Requirements: 1.3, 1.4, 3.2, 3.5, 2.8, 4.7, 6.7_

- [ ] 12. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document (20 properties)
- Unit tests validate specific examples and edge cases
- All V3 config fields are optional to maintain backward compatibility with V2 configs
- The implementation extends existing files where noted — no rebuild of V1/V1.5/V2 code
