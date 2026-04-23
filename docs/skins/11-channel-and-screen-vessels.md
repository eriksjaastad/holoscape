# Channel And Screen Vessels

> **Status:** Design, draft 1.
> **Purpose:** define how Holoscape can render the channel list and the main terminal surface as skinned "vessels" instead of plain sidebar + pane chrome.
> **Builds on:** [`06-chrome-skinning.md`](./06-chrome-skinning.md), [`10-skin-roadmap.md`](./10-skin-roadmap.md), current v4 chrome-mode reconstruction and skin pipeline.

---

## 1. Purpose

The current skinning engine can transform the outer shell of the window, but the internal layout still reads as a conventional app:

- sidebar on the left
- tab strip on top
- terminal/content area on the right

That is enough for themed chrome, but not enough for "device-like" skins where the navigation and the main terminal feel like embedded hardware surfaces.

This doc defines a coding direction for the next layer:

- **Channel vessel**: the skinned viewport that reveals the list of channels/tabs
- **Screen vessel**: the skinned viewport that frames the main terminal/input area
- **Seam**: the mechanical join between them

The design goal is not arbitrary freeform UI. The design goal is to let skins define **how normal Holoscape structures are revealed**, while Holoscape still owns the actual list, terminal, selection, and focus behavior.

---

## 2. What Exists Today

The current structure is already closer to this than it looks.

### Layout ownership

`MainWindowController` already owns a stable app-content tree:

- `splitView`
- `sidebarContainer`
- `rightPane`
- `sessionLauncher`
- `sidebarView`
- terminal / input stack inside the right pane

This is important: we do **not** need a new app architecture to start vessel work.

### Channel surfaces today

There are already two channel-list presentations:

- [`SidebarView.swift`](../../Sources/Holoscape/Views/SidebarView.swift)
  - vertical channel list
  - backed by `NSScrollView` + `NSStackView`
- [`TabBarView.swift`](../../Sources/Holoscape/Views/TabBarView.swift)
  - horizontal channel strip
  - already owns hover/pressed/active state and skin-driven rendering

This means Holoscape already has the semantic split we need:

- **vertical channel list**
- **horizontal channel list**

The missing piece is not channel logic. The missing piece is **vesselization**: how those existing channel views are framed, clipped, docked, and made to read like part of the skin.

### Main screen surface today

The right side already behaves like one main content surface. In practice it is:

- tab bar when the sidebar is collapsed
- split-pane/terminal area
- input area

That is enough to define a first **screen vessel** without rethinking terminal architecture.

---

## 3. Core Design Rule

The core rule for vessel work is:

**Graphics define the vessel. Holoscape still owns the content.**

More concretely:

- skins define where the channel list is revealed
- skins define how the main screen is framed
- Holoscape still owns scrolling, selection, focus, actions, list ordering, terminal rendering, and input

This avoids the trap of turning skins into layout scripts or custom app logic.

---

## 4. Target Model

Holoscape should expose three skinnable internal surfaces:

### 4.1 Channel Vessel

The skinned window through which channels are revealed.

Examples:

- left vertical pod
- right vertical instrument column
- top horizontal rail
- bottom horizontal bay
- later: circular or partially masked aperture

The first implementation must assume that the underlying channel content is still linear:

- vertical list for left/right docking
- horizontal list for top/bottom docking

### 4.2 Screen Vessel

The dominant screen body that frames:

- terminal viewport
- split-pane stack
- input area
- optionally the top tab strip when the sidebar is collapsed

The screen vessel is the "main display" of the skin. It should read as one device cavity rather than as raw app panes with decoration.

### 4.3 Seam

The seam is the visual docking edge between channel vessel and screen vessel.

This is a first-class design surface because it is what makes the layout feel like:

- two attached hardware masses
- one control spine and one screen body
- one top rail and one screen slab

Without a deliberate seam, the result falls back to "app with border art."

---

## 5. First Implementation Scope

The first implementation should be intentionally constrained.

### In scope

- docked channel vessel at `left`, `right`, `top`, or `bottom`
- channel vessel with cap/stretch/cap structure
- visual clipping/reveal for the channel content
- framed screen vessel around the main content area
- a seam surface between vessel and screen
- skin-driven placement of detached traffic lights when the vessel layout wants them on the left/top side

### Out of scope for the first pass

- arbitrary freeform positioning of channel content
- many simultaneous independent vessels
- circular/radial channel layout semantics
- curved text layout
- skin-authored interaction logic
- replacing the terminal/input architecture

The right sequence is:

1. prove docked vessels
2. prove shaped reveal windows
3. later experiment with circular/radial reveals

---

## 6. Proposed Internal Abstractions

The current code should evolve through wrappers and adapters, not by throwing away `SidebarView` and `TabBarView`.

### 6.1 `ChannelVesselView`

New container view responsible for:

- docking orientation
- vessel frame art / mask
- cap/stretch/cap layout
- hosting either the vertical or horizontal channel presenter
- optional launcher placement when the vessel owns launcher UI visually

It should **not** own channel semantics.

Its job is to host one of the existing channel presenters and reveal it through a skinned structure.

### 6.2 Channel Presenter Modes

The channel vessel should host one presenter at a time:

- **vertical presenter**
  - existing `SidebarView`
- **horizontal presenter**
  - existing `TabBarView`

This means the vessel abstraction should select presentation mode based on docking:

- `left` / `right` → vertical
- `top` / `bottom` → horizontal

Later experimental modes can add:

- `maskedVertical`
- `maskedHorizontal`
- `radialWindowed`

But those should still sit behind the same vessel container.

### 6.3 `ScreenVesselView`

New container view responsible for:

- framing the right/main content body
- applying bezel/glass/inner-border treatment
- optionally owning top bridge / bottom lip decorative bands
- hosting the existing right-side content subtree

It should wrap existing content, not replace it.

### 6.4 `VesselSeamView`

New view for the join between channel and screen masses.

This exists because:

- the seam may be visual only
- the seam may need its own fill/border/mask
- it should not be hardcoded into either vessel

The seam lets skins express:

- hinge
- docking rail
- recessed channel
- bracket
- gasket / shadow join

without complicating the vessel host views.

---

## 7. Manifest Direction

The existing skin format already handles surfaces well, but vessels introduce a new problem: **layout and reveal geometry**.

The first vessel design should add a narrowly scoped layout section rather than overload generic surfaces.

Recommended direction:

```json
"layout": {
  "channelVessel": { ... },
  "screenVessel": { ... },
  "seam": { ... }
}
```

The point of this is not to create a scene graph. The point is to add a small amount of structural intent that the existing surface system does not express cleanly.

### 7.1 Channel vessel fields

Minimum useful fields:

- `dock`: `left | right | top | bottom`
- `mode`: `vertical | horizontal`
- `size`: width for left/right, height for top/bottom
- `caps`: fixed start/end cap extents
- `viewportRect`: the inner reveal area for the channel presenter
- `trafficLights`: optional placement mode when this vessel owns the controls visually
- `launcherPlacement`: whether launcher stays inside the vessel head/cap or outside it

### 7.2 Screen vessel fields

Minimum useful fields:

- `frameRect` or implied fill region relative to the app host
- `viewportInsets` for the main content cavity
- optional decorative bands:
  - top bridge
  - bottom lip
  - right pod area

### 7.3 Seam fields

Minimum useful fields:

- `thickness`
- `style`
- optional `joinRect` override if the seam is not just a full shared edge

This should stay intentionally shallow in V1.

---

## 8. Stretch Model

This is the most important design behavior to get right.

The channel vessel must be stretchable without looking broken.

### 8.1 Left / right docking

If the vessel docks left or right:

- fixed top cap
- fixed bottom cap
- stretchable middle rail
- channel list lives in the rail's reveal area

This is the model for:

- handset-like pods
- columnar receivers
- porthole towers
- vertical instrument bays

### 8.2 Top / bottom docking

If the vessel docks top or bottom:

- fixed left cap
- fixed right cap
- stretchable middle span
- channel strip lives in the span reveal area

This is the model for:

- top bridge rails
- lower transport strips
- dashboard spans

### 8.3 Why this matters

This keeps the expressive art in the anchors/caps and keeps the center region simpler and scalable.

That makes skin authoring dramatically easier and avoids forcing the whole vessel to be a single rigid decorative object.

---

## 9. Rendering Model

Vessels should be layered, not hand-painted as one inseparable image unless the skin explicitly chooses a baked whole-shell approach.

Recommended internal composition:

### Channel vessel

- vessel background / base art
- vessel mask or reveal geometry
- presenter host (`SidebarView` or `TabBarView`)
- vessel overlay details

### Screen vessel

- outer frame
- inner cavity frame
- content host
- optional overlay details

### Seam

- seam base
- optional highlight/shadow/gasket overlay

The reason to layer this way is flexibility:

- simple skins can use regular rounded-rect reveal
- more advanced skins can add clipped apertures and overlays
- future circular/radial reveals can change the mask without changing list semantics

---

## 10. Coding Strategy

This should be implemented in phases.

### Phase 1: Docked vessel wrappers

Goal:

- make left/right/top/bottom vessel layouts real using current presenters

Implementation:

- wrap `SidebarView` and `TabBarView` in `ChannelVesselView`
- wrap the main right-side content in `ScreenVesselView`
- add `VesselSeamView`
- keep reveal windows rectangular or rounded-rect only
- keep scrolling and interactions entirely owned by the presenters

Success criteria:

- a skin can choose left/right/top/bottom vessel docking
- the channel region reads as a dedicated vessel
- the screen body reads as a separate mass

### Phase 2: Masked reveal windows

Goal:

- let the channel list feel embedded in a pod or instrument

Implementation:

- add mask support for the channel presenter host
- support edge fades or clipped windows
- support non-plain vessel outlines without changing presenter logic

Success criteria:

- channels look revealed through a device aperture, not just a decorated box

### Phase 3: Advanced vessel experiments

Goal:

- support shapes like circular or partial-window list reveals

Implementation:

- add new channel presentation modes that still operate over the same list model
- keep text layout linear at first; only later consider curved text

Success criteria:

- experimental skins can use more radical list vessels without destabilizing standard docked skins

---

## 11. Interaction Contract

This must stay stable across vessel designs.

### Channel interactions

Regardless of vessel shape:

- click selects a channel
- context menu still works
- unread/active/notification state still works
- keyboard navigation still targets the same underlying list model
- accessibility should continue to see a list of channels, not just decorative shapes

### Main screen interactions

Regardless of vessel frame:

- terminal focus and typing must not change
- split panes remain standard Holoscape panes
- input area remains standard input area

This is why the vessel layer must stay visually powerful but semantically thin.

---

## 12. Traffic Lights

Traffic lights are part of the vessel system once the vessel claims the top-left or top-edge mass.

Recommended rule:

- if the channel vessel docks `left` or `top`, it may visually own the traffic-light landing zone
- the controls remain standard detached AppKit buttons under the hood
- the skin only defines where the controls belong and what surface they sit on

This keeps behavior standard while letting the vessel look like the place where system controls live.

---

## 13. Test Strategy

The first vessel implementation should add coverage at three levels.

### Unit / controller

- vessel docking picks the correct presenter mode
- cap/stretch/cap layout computes expected frames
- traffic-light landing zone updates correctly by docking mode

### Integration

- persisted launch with a vesselized skin mounts content into the correct vessel hierarchy
- switching vesselized skin ↔ default preserves a sane layout graph
- left/right/top/bottom docking all keep the window usable

### UI

- channel list remains selectable and scrollable through the vessel
- main terminal remains focusable and responsive
- traffic lights remain usable when owned visually by the vessel

---

## 14. Why This Is The Right Scope

This design is ambitious enough to unlock next-level skins, but constrained enough to actually ship.

It does **not** require:

- a skin scripting VM
- a new terminal model
- a fully arbitrary scene graph
- replacing channel semantics

It **does** require:

- a small structural layout layer for vessels
- wrapper views around existing presenters
- mask/reveal logic
- a clear separation between graphics and app behavior

That is the right boundary.

---

## 15. Bottom Line

Holoscape already has the semantic pieces needed for advanced skins:

- a vertical channel list
- a horizontal channel strip
- a dominant main terminal surface

What it lacks is a way for skins to turn those into **device-like vessels**.

That should be the next design target:

- **channel vessel**
- **screen vessel**
- **seam**

Once those are real, skins can start treating the channel list like an instrument display and the main terminal like a real screen body, without turning the whole app into custom layout code.
