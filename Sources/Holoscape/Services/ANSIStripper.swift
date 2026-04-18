import Foundation

/// Removes ANSI control sequences from terminal output so the bytes can
/// be rendered as plain text (e.g. in Reader Mode's NSTextView).
///
/// Conservative on purpose: only recognized escape shapes are stripped.
/// Anything that doesn't match a known CSI / OSC / single-byte escape
/// passes through unchanged — regular text, whitespace, Unicode glyphs,
/// box-drawing characters all survive.
///
/// Covered sequences (in strip order):
///
///   1. **CSI** (Control Sequence Introducer) — `ESC [` followed by
///      parameter bytes (`0x30`–`0x3F`), intermediate bytes (`0x20`–`0x2F`),
///      and a final byte in `@`–`~` (`0x40`–`0x7E`). SGR color codes,
///      cursor moves, erase-line, etc.
///   2. **OSC** (Operating System Command) — `ESC ]` followed by any
///      payload terminated by either BEL (`\u{07}`) or ST (`ESC \`).
///      Used by shells to set terminal title, hyperlink targets, etc.
///   3. **Lone two-byte escapes** — `ESC` followed by a single byte in
///      `@`–`_` (DEC index, reverse index, SS2/SS3, etc.).
///   4. **Bare BEL** — `\u{07}` on its own. Not useful in a reader view.
///
/// Order matters: CSI must run first. The lone-escape rule would
/// otherwise eat the `ESC [` prefix and leave the CSI body behind as
/// plaintext. With CSI running first, the full sequence is consumed
/// before the single-byte rule can see the `[`.
///
/// The ESC byte is interpolated into the pattern as a literal Swift
/// character (`\u{1B}` outside a raw string) rather than sitting inside
/// the regex text as an escape. ICU's regex engine does not uniformly
/// recognize the `\u{...}` brace form, so interpolation is the reliable
/// way to match ESC across platforms.
enum ANSIStripper {

    private static let esc = "\u{1B}"

    /// Apply all strippers in sequence. Input is not mutated.
    static func strip(_ input: String) -> String {
        var result = input

        // CSI: ESC [ (params 0x30-0x3F) (intermediates 0x20-0x2F) (final 0x40-0x7E)
        result = result.replacingOccurrences(
            of: "\(esc)\\[[\\x30-\\x3F]*[\\x20-\\x2F]*[\\x40-\\x7E]",
            with: "",
            options: .regularExpression)

        // OSC: ESC ] <payload> (BEL | ESC \). Non-greedy so adjacent
        // OSC sequences don't get glued into one match.
        result = result.replacingOccurrences(
            of: "\(esc)\\].*?(?:\\x07|\(esc)\\\\)",
            with: "",
            options: .regularExpression)

        // Lone two-byte escapes: ESC followed by @–_. Runs AFTER CSI so
        // it doesn't eat the `[` of a CSI sequence.
        result = result.replacingOccurrences(
            of: "\(esc)[\\x40-\\x5F]",
            with: "",
            options: .regularExpression)

        // Bare BEL characters.
        result = result.replacingOccurrences(of: "\u{07}", with: "")

        return result
    }
}
