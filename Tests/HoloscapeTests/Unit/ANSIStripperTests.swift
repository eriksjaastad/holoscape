import XCTest
@testable import Holoscape

/// Task 12.2 coverage for `ANSIStripper.strip(_:)` — the ANSI-escape
/// stripper used by Reader Mode when presenting scrollback as plain text.
///
/// The stripper is deliberately conservative: only known control-sequence
/// shapes are removed. Everything else (regular text, whitespace, Unicode
/// glyphs, box-drawing characters, malformed escapes that don't match a
/// shape) passes through unchanged. These tests pin those invariants.
final class ANSIStripperTests: XCTestCase {

    // MARK: - Plain input

    func testPlainASCIIPassesThrough() {
        let input = "hello world\nthe quick brown fox"
        XCTAssertEqual(ANSIStripper.strip(input), input)
    }

    func testUnicodePassesThrough() {
        // Emoji + box-drawing + CJK characters must survive. Rendering
        // these correctly is the whole point of using a stripper rather
        // than a blanket "strip non-ASCII" filter.
        let input = "┌─ box ─┐\n│ 日本語 │\n└ 🚀 ──┘"
        XCTAssertEqual(ANSIStripper.strip(input), input)
    }

    // MARK: - CSI (SGR + cursor moves + erase)

    func testSGRColorCodesRemoved() {
        let input = "\u{1B}[0;31mred text\u{1B}[0m normal"
        XCTAssertEqual(ANSIStripper.strip(input), "red text normal")
    }

    func testCursorMovementRemoved() {
        // Cursor up/down/erase-screen/goto-column — all CSI shapes.
        let input = "\u{1B}[2J\u{1B}[H\u{1B}[10;5Hpayload\u{1B}[K"
        XCTAssertEqual(ANSIStripper.strip(input), "payload")
    }

    func testCSIWithIntermediateBytesRemoved() {
        // Intermediate bytes (0x20–0x2F) are rare but legal. Include one
        // so the regex's intermediate-byte character class is exercised.
        let input = "before\u{1B}[1 qafter"  // `1 q` is a DECSCUSR sequence
        XCTAssertEqual(ANSIStripper.strip(input), "beforeafter")
    }

    // MARK: - OSC

    func testOSCTerminatedByBELRemoved() {
        // OSC 0 sets the window title. BEL-terminated is the common form
        // emitted by bash/zsh via PROMPT_COMMAND.
        let input = "\u{1B}]0;My Title\u{07}shell prompt $ "
        XCTAssertEqual(ANSIStripper.strip(input), "shell prompt $ ")
    }

    func testOSCTerminatedByStringTerminatorRemoved() {
        // ST (`ESC \`) is the formally-spec'd OSC terminator. iTerm2 and
        // some other terminals emit it instead of BEL.
        let input = "before\u{1B}]1337;RemoteHost=user@host\u{1B}\\after"
        XCTAssertEqual(ANSIStripper.strip(input), "beforeafter")
    }

    func testTwoAdjacentOSCSequencesEachRemovedSeparately() {
        // Non-greedy OSC match: two back-to-back OSC blocks should each
        // get stripped to their own terminator, not glued into one huge
        // match that eats the text between them.
        let input = "\u{1B}]0;first\u{07}KEEP\u{1B}]0;second\u{07}END"
        XCTAssertEqual(ANSIStripper.strip(input), "KEEPEND")
    }

    // MARK: - Lone two-byte escapes

    func testLoneESCSingleByteCommandRemoved() {
        // ESC M = reverse index; ESC 7 is NOT in @–_ so won't match —
        // but ESC = is 0x3D, also not in @–_. We use ESC M (0x4D) and
        // ESC _ (0x5F) which ARE in range. ESC D (0x44) = index.
        let input = "x\u{1B}My\u{1B}Dz"
        XCTAssertEqual(ANSIStripper.strip(input), "xyz")
    }

    func testLoneESCNotInRangeStaysIntact() {
        // ESC 0 (0x30) is in neither CSI nor the @–_ single-byte range.
        // Stripper should leave it alone rather than silently eating the
        // digit after ESC. Matches the "conservative" doctrine.
        let input = "a\u{1B}0b"
        // Current behavior: ESC + 0 survives. If we later strip more
        // escape shapes, this test captures the current contract.
        XCTAssertEqual(ANSIStripper.strip(input), "a\u{1B}0b")
    }

    // MARK: - BEL

    func testBareBELRemoved() {
        // Bells issued outside an OSC context (e.g. `printf '\a'`) have
        // no useful rendering in a reader view. Strip them.
        let input = "ring\u{07}ring"
        XCTAssertEqual(ANSIStripper.strip(input), "ringring")
    }

    // MARK: - Malformed / edge cases

    func testLoneTrailingESCSurvives() {
        // ESC at end-of-input without a follow-up byte can't be classified
        // as any known sequence. Conservative rule: leave it alone.
        let input = "abc\u{1B}"
        XCTAssertEqual(ANSIStripper.strip(input), "abc\u{1B}")
    }

    func testEmptyStringPassesThrough() {
        XCTAssertEqual(ANSIStripper.strip(""), "")
    }

    // MARK: - Realistic sample

    func testRealisticPromptAndCommandOutput() {
        // Mimics a bash session: title-setter OSC, green prompt, command,
        // red error, reset. After stripping, only the visible text should
        // remain (plus the newlines that separate lines).
        let input = """
            \u{1B}]0;erik@macbook: ~/projects/holoscape\u{07}\u{1B}[0;32m➜ \u{1B}[0;36mholoscape\u{1B}[0m git status
            On branch \u{1B}[0;33mfeat/reader-mode\u{1B}[0m
            \u{1B}[0;31mfatal: no commits yet\u{1B}[0m
            """
        let expected = """
            ➜ holoscape git status
            On branch feat/reader-mode
            fatal: no commits yet
            """
        XCTAssertEqual(ANSIStripper.strip(input), expected)
    }
}
