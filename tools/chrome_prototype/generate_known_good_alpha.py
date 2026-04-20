"""Generate the PNG-chrome transparency prototype's known-good alpha fixture.

PR #1 of the PNG-chrome architecture (claude-specs/chrome/tasks.md Task 1.1).
The whole MVP is gated on AppKit honoring per-pixel alpha on a borderless
window (PRD §15 Risk #1). This script emits a 1000x700 RGBA PNG whose alpha
channel is the window shape: opaque interior, transparent 64-pixel cut corners
at all four corners, so the visual test is unmistakable.

Run from the repo root:

    uv run --with pillow Tools/chrome_prototype/generate_known_good_alpha.py

Writes to Sources/Holoscape/Resources/Prototype/known_good_alpha.png so
Bundle.module can load it at runtime. The env-flag branch in
MainWindowController reads it via Bundle.module when
HOLOSCAPE_PNG_CHROME_PROTOTYPE=1.
"""

from PIL import Image
import pathlib

# Anchor via __file__ so the script is safe to run from any CWD. This file
# lives at Tools/chrome_prototype/generate_known_good_alpha.py; two parents
# up is the repo root.
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT_PATH = REPO_ROOT / "Sources/Holoscape/Resources/Prototype/known_good_alpha.png"

WIDTH = 1000
HEIGHT = 700
CUT = 64  # size of each cut corner, in pixels

# Visible fill — a deliberate bright magenta so any leaked opaque pixel
# outside the shape is instantly obvious on Erik's bright desktop backdrop.
FILL = (0xff, 0x44, 0xcc, 0xff)  # RGBA
TRANSPARENT = (0, 0, 0, 0)


def inside_shape(x: int, y: int) -> bool:
    """True if the pixel should be opaque.

    Shape is a rectangle with 64-pixel cut corners — the diagonal cut runs
    from (0, CUT) down to (CUT, 0) at the top-left, mirrored at each
    corner. Any pixel on or below the diagonal (corner-ward) is cut away.
    """
    # Top-left corner
    if x < CUT and y < CUT and (x + y) < CUT:
        return False
    # Top-right corner
    if x >= WIDTH - CUT and y < CUT and ((WIDTH - 1 - x) + y) < CUT:
        return False
    # Bottom-left corner
    if x < CUT and y >= HEIGHT - CUT and (x + (HEIGHT - 1 - y)) < CUT:
        return False
    # Bottom-right corner
    if x >= WIDTH - CUT and y >= HEIGHT - CUT and ((WIDTH - 1 - x) + (HEIGHT - 1 - y)) < CUT:
        return False
    return True


def main() -> None:
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    img = Image.new("RGBA", (WIDTH, HEIGHT), TRANSPARENT)
    pixels = img.load()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if inside_shape(x, y):
                pixels[x, y] = FILL
    img.save(OUT_PATH)

    # Pixel-verify the invariants from Task 1.1: alpha == 0 at corners,
    # alpha == 1 (255) at center.
    corner_alpha = img.getpixel((0, 0))[3]
    center_alpha = img.getpixel((WIDTH // 2, HEIGHT // 2))[3]
    assert corner_alpha == 0, f"corner alpha should be 0, got {corner_alpha}"
    assert center_alpha == 255, f"center alpha should be 255, got {center_alpha}"
    print(f"wrote {OUT_PATH}  ({WIDTH}x{HEIGHT}, corner alpha={corner_alpha}, center alpha={center_alpha})")


if __name__ == "__main__":
    main()
