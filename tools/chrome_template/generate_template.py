#!/usr/bin/env python3
"""Generate docs/chrome-template.png — a 1000×700 RGBA starter
template for skin authors. Shows the interiorRect as a semitransparent
rectangle + cut corners outlined in magenta. Annotated with labels.

Run from repo root:
    uv run tools/chrome_template/generate_template.py
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
OUT = REPO_ROOT / "docs/chrome-template.png"

WIDTH = 1000
HEIGHT = 700
SCALE = 2
CORNER_R = 16 * SCALE

INTERIOR_INSET_X = 40 * SCALE
INTERIOR_INSET_Y = 60 * SCALE


def main() -> None:
    pw = WIDTH * SCALE
    ph = HEIGHT * SCALE
    img = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Silhouette — rounded rectangle filled with a light
    # semitransparent grey so authors can see the bounds.
    draw.rounded_rectangle(
        [(0, 0), (pw, ph)],
        radius=CORNER_R,
        fill=(40, 40, 50, 200),
        outline=(255, 68, 204, 255),  # magenta outline
        width=4,
    )

    # Interior rect (x=40, y=60, w=920, h=600 logical).
    ix0, iy0 = INTERIOR_INSET_X, INTERIOR_INSET_Y
    ix1, iy1 = pw - INTERIOR_INSET_X, ph - 40 * SCALE
    draw.rectangle(
        [(ix0, iy0), (ix1, iy1)],
        fill=(0, 180, 220, 100),
        outline=(0, 220, 255, 255),
        width=2,
    )

    # Labels. Fall back to default PIL font if no TrueType is on
    # the system (CI + laptop).
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 20 * SCALE)
    except OSError:
        font = ImageFont.load_default()
    draw.text((20, 4), "chrome silhouette (width, height)", fill=(255, 68, 204, 255), font=font)
    draw.text((ix0 + 20, iy0 + 20), "interiorRect — app content lives here", fill=(255, 255, 255, 230), font=font)
    draw.text(
        (20, ph - 30 * SCALE),
        "top band (~32pt) = tab bar region for composed-mode bakes",
        fill=(255, 255, 255, 200),
        font=font,
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, "PNG")
    print(f"wrote {OUT} ({pw}×{ph})")


if __name__ == "__main__":
    main()
