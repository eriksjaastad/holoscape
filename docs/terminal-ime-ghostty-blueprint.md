# Holoscape IME / NSTextInputClient blueprint from Ghostty

Status: findings for card #5934.

## Scope

Read-only spike against Ghostty's `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, focused on its `NSTextInputClient` path and how it supports CJK/IME composition, dictation, marked text, and command-key edge cases.

Holoscape's terminal view is currently `HoloscapeTerminalView`, a subclass of SwiftTerm's `LocalProcessTerminalView`. SwiftTerm's macOS `TerminalView` already conforms to `NSTextInputClient`; this blueprint is therefore not a call to replace SwiftTerm's input system immediately. It identifies what Ghostty gets right and what Holoscape should verify or adapt around SwiftTerm before claiming daily-driver IME quality.

## Current Holoscape/SwiftTerm baseline

Holoscape-specific code:

- `Sources/Holoscape/Views/HoloscapeTerminalView.swift` does not implement `NSTextInputClient` directly.
- It overrides `send(source:data:)`, `rangeChanged`, link opening, context menus, and some selection behavior, then delegates input to SwiftTerm.
- Broker-backed tabs route user input through `BrokerBackedTerminalProcess.send(_:)`; direct/local tabs route through SwiftTerm's `LocalProcessTerminalView` process delegate.

SwiftTerm baseline from `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift`:

- `TerminalView` conforms to `NSTextInputClient`.
- It tracks `markedTextStorage`, `markedSelectedRange`, a `DictationOverlayTextView`, and `kittyIsComposing`.
- `keyDown(with:)` calls `interpretKeyEvents([event])` for normal text and IME paths.
- `insertText(_:replacementRange:)` sends committed text as UTF-8 or Kitty keyboard protocol events depending on negotiated keyboard flags.
- `setMarkedText(_:selectedRange:replacementRange:)` stores marked text and shows an overlay at the cursor.
- `doCommand(by:)` maps standard AppKit commands to terminal escape sequences and Kitty events.

Conclusion: Holoscape is not at zero. It inherits meaningful AppKit IME support from SwiftTerm. The risk is that Holoscape's broker/input wrappers, option/meta policy, skin overlays, and future renderer work can bypass or visually break that support.

## Ghostty behaviors worth copying or testing

### 1. Treat AppKit as the composition authority

Ghostty does not try to manually parse IME keystrokes first. In `keyDown(with:)`, it calls `interpretKeyEvents([translationEvent])`, then reasons about what AppKit produced:

- marked text means an active preedit/composition;
- `insertText` during a composition is committed IME text;
- keyboard layout changes during the event can mean the input method consumed it;
- control characters during composition belong to the IME, not the terminal.

Holoscape should preserve this rule: terminal key encoding is downstream of AppKit composition, not a replacement for it.

### 2. Keep explicit marked/preedit state

Ghostty stores marked text in `markedText: NSMutableAttributedString` and exposes it through:

- `hasMarkedText()`
- `markedRange()`
- `setMarkedText(...)`
- `unmarkText()`
- `validAttributesForMarkedText()`

It also syncs marked text to the terminal core via `syncPreedit(...)`, so the terminal can render preedit text at the right position.

SwiftTerm already stores marked text and shows a `DictationOverlayTextView`. For Holoscape, the blueprint is to avoid adding a second marked-text layer in `HoloscapeTerminalView`. Instead, any Holoscape-specific styling or skin vessel work should leave SwiftTerm's marked-text overlay visible and above terminal content.

### 3. Send committed IME text as typed input, not paste

Ghostty's `insertText` explicitly sends committed IME/dictation text as key input, never as paste:

> All committed text (IME, dictation, etc.) must be sent as key events so programs treat it as typed input, never as a paste.

SwiftTerm has the same conceptual distinction: `insertText(..., isPaste: false)` sends normal text, while paste paths can use bracketed paste.

Holoscape's broker path must preserve this distinction. `BrokerBackedTerminalProcess` sees only bytes after SwiftTerm has encoded text; that is fine as long as Holoscape does not introduce a separate input box or command transport for terminal tabs that bypasses `TerminalView.insertText`.

### 4. Suppress raw control input while composing

Ghostty has `shouldSuppressComposingControlInput(...)` to stop single C0 control characters from leaking into the terminal while an IME is composing. Example: Japanese composition plus Backspace/Ctrl-H should cancel or edit composition, not delete a prior terminal character.

SwiftTerm has composition-aware Kitty paths through `kittyIsComposing`, but Holoscape should add regression coverage around this behavior because it is easy to break when wrapping input or changing option/meta handling.

### 5. Handle command-key AppKit detours deliberately

Ghostty has a `performKeyEquivalent` / `lastPerformKeyEvent` workaround for command/control-modified keys because `NSTextInputClient` can route some command keys through `doCommand` before `keyDown`.

Holoscape probably does not need to copy this unless a concrete keybinding bug appears, but the lesson is important: command-key terminal shortcuts, app menu shortcuts, and IME composition share AppKit's responder chain. New global shortcuts or command palette work must be tested while an IME is active.

### 6. Put candidate windows at the terminal cursor

Ghostty implements `firstRect(forCharacterRange:actualRange:)` by asking the terminal core for the IME point, converting Ghostty's top-left coordinates into AppKit/screen coordinates.

SwiftTerm's implementation should be verified rather than assumed. Holoscape skins, shaped windows, overlay vessels, Metal views, and transformed layouts can all make candidate-window positioning wrong even if SwiftTerm's base math is correct.

## Holoscape implementation blueprint

### Phase A — characterize inherited SwiftTerm behavior before changing code

Add a focused manual QA checklist and, where feasible, UI tests around `HoloscapeTerminalView`:

1. Japanese Hiragana IME: type a multi-character composition, move within the candidate list, commit, verify only committed text reaches the shell.
2. Korean 2-set IME: verify jamo composition and commit behavior, including the AppKit event identity caveat Ghostty calls out.
3. Chinese Pinyin IME: verify candidate selection and commit.
4. Dead keys / accent composition: Option-e then vowel with `optionAsMetaKey` off and on.
5. Dictation: verify interim marked text position and committed text path.
6. Backspace/Ctrl-H while composing: verify it edits/cancels composition and does not delete terminal text.
7. Command-period / Escape while composing: verify app shortcut handling does not double-send Escape.
8. Broker-backed tab and direct SwiftTerm tab, if both paths still exist.

Acceptance: document which cases pass through inherited SwiftTerm behavior and which fail in Holoscape's wrappers.

### Phase B — make HoloscapeTerminalView explicitly protect SwiftTerm IME paths

If Phase A finds no failures, add a small code comment and tests around `HoloscapeTerminalView` stating that it intentionally inherits SwiftTerm's `NSTextInputClient` implementation and must not bypass `interpretKeyEvents`, `insertText`, or `setMarkedText` for terminal tabs.

If failures exist, patch `HoloscapeTerminalView` narrowly:

- do not reimplement the full `NSTextInputClient` contract unless SwiftTerm is insufficient;
- prefer overriding only the broken edge (`firstRect`, overlay layering, command-key interaction) and call `super` for the rest;
- keep terminal input through SwiftTerm so broker-backed and local sessions share AppKit composition behavior.

### Phase C — skin/layout compatibility

Before shaped windows and skin vessels are considered IME-safe, verify:

- marked-text overlay remains above terminal content and below any modal chrome;
- candidate windows appear at the cursor in normal, skinned, and shaped-window layouts;
- Metal renderer or shader layers do not cover marked text;
- switching tabs mid-composition either preserves composition correctly or cancels loudly/cleanly.

### Phase D — future native terminal core boundary

If Holoscape ever replaces SwiftTerm with a native terminal parser/renderer, copy Ghostty's architecture more directly:

- a terminal view owns `markedText` and `keyTextAccumulator` state;
- `keyDown` always routes through `interpretKeyEvents` before terminal encoding;
- `insertText` sends committed text as typed input, not paste;
- preedit state is a first-class terminal-core event, not a visual-only overlay;
- cursor/candidate geometry comes from terminal grid coordinates converted into screen coordinates.

## Proposed follow-up card

**IME QA matrix for HoloscapeTerminalView**

Acceptance criteria:

- Create `docs/terminal-ime-qa-matrix.md` with the Phase A matrix above.
- Run the matrix manually on broker-backed local shell tabs.
- Record pass/fail evidence and exact macOS input sources used.
- Create implementation cards only for observed failures, not speculative rewrites.

## Recommendation

Do not start by porting Ghostty's entire `NSTextInputClient` implementation into Holoscape. SwiftTerm already provides the protocol implementation Holoscape inherits.

Do make IME behavior a protected terminal-correctness gate: characterize it, preserve the inherited AppKit composition path, and only patch the specific places where Holoscape's broker, skins, or layout layers break SwiftTerm's baseline.
