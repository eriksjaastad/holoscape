# Holoscape terminal IME QA matrix

Status: acceptance matrix for card #5934. Fill this with real manual evidence before claiming daily-driver IME coverage.

## Purpose

Holoscape inherits `NSTextInputClient` behavior from SwiftTerm through `HoloscapeTerminalView`. This matrix protects that path while the broker, skins, shaped windows, and future renderer work evolve.

Terminal input must keep AppKit as the composition authority:

- composition/preedit text stays in SwiftTerm/AppKit marked-text handling;
- committed IME/dictation text is sent as typed input, not paste;
- control keys during composition edit/cancel composition before terminal control bytes leak through;
- candidate/dictation overlays remain positioned at the terminal cursor and visible above terminal content.

## Environments to record

For each run, record:

- macOS version/build;
- Holoscape git commit;
- input source name and language;
- tab type: broker-backed local shell and any remaining direct SwiftTerm path;
- skin/layout mode: standard, skinned chrome, shaped-window/overlay mode when available;
- shell/program under test.

## Matrix

| Case | Input source / setup | Steps | Expected result | Broker-backed result | Direct-path result | Evidence / notes |
|---|---|---|---|---|---|---|
| Japanese Hiragana composition | Japanese - Romaji / Hiragana | Type a multi-character word, open candidate list, move selection, commit | Only committed text reaches shell; preedit remains marked until commit | Pending | Pending | |
| Korean 2-set composition | Korean - 2-Set | Type jamo forming syllables, backspace during composition, commit | Composition edits syllable/preedit; no prior terminal char is deleted before commit | Pending | Pending | |
| Chinese Pinyin candidates | Simplified Chinese - Pinyin | Type pinyin, select non-first candidate, commit | Candidate selection commits chosen text once | Pending | Pending | |
| Dead-key accent composition | U.S. International or Option-e then vowel | With `optionAsMetaKey` off, compose accent; repeat with it on | Non-meta mode composes; meta mode behavior is explicit and documented | Pending | Pending | |
| Dictation interim text | macOS Dictation enabled | Start dictation in a shell prompt, speak short phrase, stop dictation | Interim marked text appears at cursor; final committed text is typed input | Pending | Pending | |
| Backspace during IME composition | Any active IME with preedit | Type preedit text, press Backspace / Ctrl-H before commit | Backspace edits/cancels composition; does not delete previous terminal text | Pending | Pending | |
| Escape / Command-period during composition | Any active IME with preedit | Start composition, press Escape and Command-period | Composition cancellation is single and predictable; no double Escape reaches shell | Pending | Pending | |
| Tab switch mid-composition | Any active IME with preedit | Start composition, switch to another tab, switch back | Composition is preserved or cancelled visibly/cleanly; no hidden stale marked text | Pending | Pending | |
| Candidate window geometry | Any candidate-list IME | Trigger candidates near top, middle, and bottom of terminal | Candidate window tracks terminal cursor in screen coordinates | Pending | Pending | |
| Skinned/overlay visibility | Any marked-text IME, skin/chrome enabled | Start composition with skin overlays visible | Marked/preedit overlay stays visible and is not covered by Metal/chrome layers | Pending | Pending | |

## Pass criteria

A case is pass only when the evidence names the exact input source and observed behavior. Do not mark speculative passes from source reading.

Create implementation cards only for observed failures. Do not port Ghostty's full `NSTextInputClient` implementation while SwiftTerm's inherited path is passing.
