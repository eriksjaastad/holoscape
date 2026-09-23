# Holoscape split panes pattern from Ghostty

Status: read-only spike for card #5933.

## Scope

This spike reads Ghostty's macOS split implementation in `~/projects/github-repos/ghostty/macos/Sources/Features/Splits/` plus the terminal controller integration points that own split lifecycle and focus routing.

The goal is not to port Ghostty's UI wholesale. Holoscape still needs a tank-solid terminal/session substrate first. The useful part is Ghostty's separation between a pure split model, a thin renderer, and controller-owned lifecycle operations.

## Ghostty split model

Ghostty models panes as a generic value tree:

- `SplitTree<ViewType>` has an optional `root` and optional `zoomed` node.
- `Node` is either `.leaf(view:)` or `.split(Split)`.
- `Split` stores `direction`, `ratio`, `left`, and `right`.
- `Direction.horizontal` means left/right. `Direction.vertical` means top/bottom.
- `NewDirection` names user intent: left, right, up, down.
- `Path` records a stable route through the tree for replacement and Codable zoom restoration.

Key design choice: most tree operations return a new `SplitTree` instead of mutating nodes in place. Insert, remove, replace, resize, equalize, and zoom updates therefore stay easy to reason about and undo.

Ghostty leaves the terminal surface itself as the leaf value. The model does not know terminal processes, tabs, windows, or AppKit focus. It only knows tree structure, ratios, identity, Codable shape, and spatial relationships.

## Pane lifecycle

### Creation

A new split is created by `BaseTerminalController.newSplit(...)`:

1. Verify the target surface belongs to this controller's `surfaceTree`.
2. Create a new `Ghostty.SurfaceView` from the Ghostty app handle and optional base config.
3. Insert it into the tree with `surfaceTree.inserting(view:at:direction:)`.
4. Replace the controller's surface tree, move focus to the new surface, and register undo as `New Split`.

The important boundary is that split creation belongs to the controller, not the SwiftUI split view. The renderer emits intent; the controller creates the terminal surface and owns focus/undo side effects.

### Closing

Closing a surface works by node removal:

1. Resolve the leaf node for the requested surface.
2. Optionally confirm when a process is alive.
3. Pick a next focus target before removal: previous leaf unless the closing node is the leftmost leaf, then next leaf.
4. Remove the node. If a child of a split disappears, the sibling collapses up to replace the parent split.
5. Replace the tree, refocus, and register undo as `Close Terminal`.

This collapse-on-remove rule is the main lifecycle simplifier. There is no empty pane state inside the tree; either a leaf exists, or its sibling replaces the split.

### Moving panes

Ghostty supports drag/drop reparenting:

- Each leaf installs an `onDrop` delegate for a transferable surface id.
- The drop location maps to a `TerminalSplitDropZone` (`top`, `bottom`, `left`, `right`) using proximity to the nearest edge.
- A drop emits `TerminalSplitOperation.drop` to the controller.
- Same-window moves remove the source node first, then insert it around the destination.
- Cross-window moves find the source controller by tree ownership, remove the source from that tree, and insert it into the destination tree.
- Dropping a surface outside any target can detach it into a new window, unless the source tree is already a single pane.

This gives Ghostty both split panes and window detach/reattach without making AppKit's transient `surface.window` relationship the source of truth. It maintains a weak surface-to-controller map and falls back to scanning windows only when needed.

### Resizing and equalizing

There are two resizing paths:

- Dragging a divider updates that split node's ratio directly via `TerminalSplitOperation.resize`.
- Keyboard resize uses spatial lookup: find the nearest ancestor split matching the requested resize axis, compute a ratio delta from the current view bounds, clamp to `0.1...0.9`, and replace that split node.

Double-clicking a divider calls equalize. Equalization sets each split's ratio from the relative leaf weight of its children, with same-direction child splits contributing their full weight.

## Focus routing

Ghostty tracks focus outside the model in `BaseTerminalController.focusedSurface`, while `SplitTree` provides target selection.

There are two routing families:

1. Linear focus: `.previous` and `.next` walk all leaves in tree order and wrap around.
2. Spatial focus: `.left`, `.right`, `.up`, `.down` builds a relative spatial map and picks the nearest candidate slot in that direction.

For spatial navigation, Ghostty computes bounds for every node from split ratios. It includes both structural split nodes and leaf nodes in the candidate list, then prefers leaf nodes. If the closest candidate is a split, it chooses that subtree's leftmost or rightmost leaf based on direction.

Zoom is a tree-level pointer to a node. Rendering uses `tree.zoomed ?? tree.root`; navigation can either preserve zoom by moving `zoomed` to the newly focused node, or clear zoom, depending on config.

Focus application remains side-effectful controller work: after resolving the target, Ghostty calls `Ghostty.moveFocus(to:from:)` on the main queue and synchronizes each surface's focus state with window key status and first-responder state.

## Rendering pattern

Ghostty renders the split tree with a recursive SwiftUI view:

- `TerminalSplitTreeView` receives a `SplitTree<SurfaceView>` and an action closure.
- `TerminalSplitSubtreeView` switches on leaf vs split.
- Leaves render `Ghostty.InspectableSurface` plus drag/drop overlays.
- Splits render a purpose-built `SplitView` with two child views and a divider.
- The view uses explicit structural identity (`.id(node.structuralIdentity)`) because implicit SwiftUI identity is unstable for recursive split trees.

`SplitView` itself is intentionally dumb:

- calculate left/right or top/bottom frames from a ratio;
- draw a 1 pt visible divider with a wider invisible hitbox;
- expose resize cursor and accessibility adjustable actions;
- update the ratio binding while dragging;
- call `onEqualize` on double tap.

The renderer does not create processes, close panes, choose focus policy, or own undo.

## What Holoscape should copy

### 1. Make split layout a terminal-core model, not a skin feature

Holoscape should introduce a value model like `TerminalSplitTree<ChannelID>` or `TerminalPaneTree<PaneID>` before building split UI. Leaves should reference Holoscape channel/session identity, not `NSView` instances. The tree should be Codable and versioned so split layouts can survive relaunch alongside channel metadata.

This preserves the roadmap rule: splits are terminal/workspace structure, not visual skin state.

### 2. Keep pane operations side-effect-free until the controller boundary

Adopt the Ghostty split between:

- pure tree operations: insert, remove, replace, resize, equalize, focus target;
- controller operations: create broker-backed session, attach/detach view, focus AppKit responder, register undo, persist config.

That matters more for Holoscape than Ghostty because Holoscape's session survival broker must not be accidentally coupled to view lifecycle. A pane split should attach a new pane to a broker session; closing a pane should choose between closing a view, detaching from a session, or terminating the process according to explicit policy.

### 3. Use stable pane identity instead of AppKit view identity

Ghostty compares leaves by `NSView` object identity because its leaves are `SurfaceView`s. Holoscape should use durable identifiers:

- `ChannelID` or `BrokerSessionID` for the terminal/session leaf;
- an independent `PaneID` if multiple panes can ever show the same session;
- tree paths only as persistence helpers, not as the primary identity.

### 4. Implement focus routing as model tests first

Ghostty's `focusTarget` is pure enough to test. Holoscape should start splits with tests for:

- insert left/right/up/down around a target leaf;
- remove a leaf and collapse the sibling;
- previous/next focus wrapping;
- spatial focus on asymmetric nested layouts;
- zoom target persistence and clearing;
- equalize ratios by child weights.

Do this before any SwiftUI/AppKit split UI. It protects terminal correctness and prevents a visual refactor from inventing session semantics.

### 5. Treat drag/drop detach as later work

Ghostty's drag/drop and cross-window moves are useful, but they are not the first Holoscape slice. Holoscape should first ship deterministic keyboard/menu split creation and focus movement. Drag/drop can come after pane/session identity is persisted and undo semantics are clear.

## Holoscape-specific cautions

- **Do not make splits a Project Tracker/plugin feature.** Splits are core terminal workspace structure. Plugins may contribute commands later, but the pane tree belongs to core.
- **Do not let closing a pane silently kill a broker-backed long-running session.** Ghostty confirms process-kill on close; Holoscape must be stricter because session survival is a core promise. Closing a pane may need `detach`, `terminate`, or `hide` choices.
- **Do not use `NSView` identity for persistence.** Broker/session/channel identity must outlive a SwiftUI/AppKit view rebuild.
- **Do not add split rendering before the channel state model can explain each pane.** Tab/sidebar truth and pane truth must agree about running/ready/needs-approval/error/stale states.
- **Do not let skin chrome own split geometry.** Skins can style dividers later; the split tree and ratios must remain functional with skins off.

## Suggested future implementation cards

1. **Define Holoscape pane tree model.** Add a versioned Codable `TerminalPaneTree` with leaf ids, split directions, ratios, zoom, insert/remove/replace/equalize/spatial-focus operations, and unit tests.
2. **Persist pane layout separately from session survival.** Store pane layout in config/channel metadata while broker sessions remain independently restorable.
3. **Add menu/keyboard split commands.** Split active pane left/right/up/down, move focus, equalize, resize by increments; no drag/drop in first slice.
4. **Render split panes with skin-independent dividers.** Use a simple AppKit/SwiftUI renderer that consumes the pane tree and channel ids, preserving terminal focus and accessibility.
5. **Define close/detach policy.** Explicitly separate close pane, detach pane, and terminate session so Holoscape never violates process survival by copying Ghostty's simpler close behavior.

## Source map

- `SplitTree.swift` — core model, Codable, structural identity, insertion/removal/replacement, focus routing, resizing, equalization, spatial mapping.
- `SplitView.swift` and `SplitView.Divider.swift` — pure SwiftUI split renderer and divider behavior.
- `TerminalSplitTreeView.swift` — recursive tree rendering plus resize/drop actions.
- `BaseTerminalController.swift` — lifecycle owner for split creation, close, move, focus, zoom, resize, undo, and cross-window ownership.
- `TerminalView.swift` — high-level terminal view model/delegate seam: SwiftUI renders the tree and reports split operations upward.
