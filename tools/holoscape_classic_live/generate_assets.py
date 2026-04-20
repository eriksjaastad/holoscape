#!/usr/bin/env python3
"""Generate placeholder chrome + animation assets for HoloscapeClassic-live.

Produces a 1000×700 logical chrome PNG at 2x (2000×1400 px) with:
- Charcoal base color (#0e0f14) filling the silhouette
- 16px cut corners (alpha=0)
- Accent cyan bevel outlining the top band (tab bar region)
- Accent magenta bevel outlining the bottom band

Also produces a tiny sprite sheet fixture so the HoloscapeClassic-live
manifest's sprite animation has real bytes to reference. Everything
here is placeholder-quality — real art lands when Erik commissions it.

Run from repo root:
    uv run tools/holoscape_classic_live/generate_assets.py
"""

from __future__ import annotations
import argparse
import os
from pathlib import Path

from PIL import Image, ImageDraw


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SKIN_DIR = REPO_ROOT / "Sources/Holoscape/Resources/Skins/HoloscapeClassic-live"
ASSETS_DIR = SKIN_DIR / "assets"

LOGICAL_WIDTH = 1000
LOGICAL_HEIGHT = 700
SCALE = 2  # 2x backing for Retina

CORNER_RADIUS = 16  # logical points

BASE_COLOR = (14, 15, 20, 255)       # #0e0f14
TAB_BAND_COLOR = (0, 180, 220, 255)  # #00b4dc cyan accent
BOT_BAND_COLOR = (255, 68, 180, 255) # #ff44b4 magenta accent


def generate_chrome_png() -> None:
    """Full chrome PNG with 16pt cut corners and decorative bands."""
    pixel_w = LOGICAL_WIDTH * SCALE
    pixel_h = LOGICAL_HEIGHT * SCALE
    img = Image.new("RGBA", (pixel_w, pixel_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded-corner base fill.
    radius_px = CORNER_RADIUS * SCALE
    draw.rounded_rectangle(
        [(0, 0), (pixel_w, pixel_h)],
        radius=radius_px,
        fill=BASE_COLOR,
    )

    # Top band (tab bar region) — 32pt tall.
    top_band_h = 32 * SCALE
    draw.rectangle(
        [(0, 0), (pixel_w, top_band_h)],
        fill=TAB_BAND_COLOR,
    )
    # Cut the corners on the top band the same way the base is cut.
    # Easier approach: mask the top band by re-drawing the corners
    # as transparent.
    for cx, cy in [(0, 0), (pixel_w, 0)]:
        dx = 1 if cx == 0 else -1
        dy = 1
        draw.pieslice(
            [(cx - radius_px, cy - radius_px), (cx + radius_px, cy + radius_px)],
            start=180 if cx == 0 else 270,
            end=270 if cx == 0 else 360,
            fill=(0, 0, 0, 0),
        )

    # Bottom band — 40pt tall, at y = height - 40.
    bot_band_h = 40 * SCALE
    draw.rectangle(
        [(0, pixel_h - bot_band_h), (pixel_w, pixel_h)],
        fill=BOT_BAND_COLOR,
    )

    # Cut corners must stay transparent — masking with a pieslice.
    # PIL's rounded_rectangle already cut the outer corners; we only
    # need to re-clip the band rectangles so they match.

    out = SKIN_DIR / "chrome@2x.png"
    img.save(out, "PNG")

    # Assert alpha invariants (fail-early contract for test fixtures).
    corner = img.getpixel((0, 0))
    center = img.getpixel((pixel_w // 2, pixel_h // 2))
    assert corner[3] == 0, f"top-left corner must be transparent; got alpha={corner[3]}"
    assert center[3] == 255, f"center must be opaque; got alpha={center[3]}"
    print(f"wrote {out} ({pixel_w}×{pixel_h})")


def generate_opaque_chrome_png() -> None:
    """Reduce Transparency variant — same silhouette, cut corners
    stay transparent, but semi-transparent edges (there are none in
    the base chrome) stay at full alpha."""
    pixel_w = LOGICAL_WIDTH * SCALE
    pixel_h = LOGICAL_HEIGHT * SCALE
    img = Image.new("RGBA", (pixel_w, pixel_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    radius_px = CORNER_RADIUS * SCALE
    draw.rounded_rectangle(
        [(0, 0), (pixel_w, pixel_h)],
        radius=radius_px,
        fill=BASE_COLOR,
    )
    top_band_h = 32 * SCALE
    draw.rectangle(
        [(0, 0), (pixel_w, top_band_h)],
        fill=TAB_BAND_COLOR,
    )
    bot_band_h = 40 * SCALE
    draw.rectangle(
        [(0, pixel_h - bot_band_h), (pixel_w, pixel_h)],
        fill=BOT_BAND_COLOR,
    )
    out = SKIN_DIR / "chrome-opaque@2x.png"
    img.save(out, "PNG")
    print(f"wrote {out} ({pixel_w}×{pixel_h})")


def generate_sprite_sheet() -> None:
    """4×8 sprite sheet with 30 frames of an LCD marquee — each frame
    is a solid cyan band with a text-like shape offset by frame index.
    Placeholder art; visual is a sliding gradient."""
    cell_w = 40
    cell_h = 24
    rows = 4
    cols = 8
    sheet = Image.new("RGBA", (cell_w * cols, cell_h * rows), (0, 0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    for frame_idx in range(30):
        r = frame_idx // cols
        c = frame_idx % cols
        x0 = c * cell_w
        y0 = r * cell_h
        # Band fill.
        draw.rectangle([(x0, y0), (x0 + cell_w, y0 + cell_h)], fill=(0, 60, 80, 255))
        # Moving marker — a 4-pixel column that shifts by frame.
        marker_x = x0 + (frame_idx * 2) % cell_w
        draw.rectangle(
            [(marker_x, y0 + 4), (marker_x + 4, y0 + cell_h - 4)],
            fill=(0, 220, 255, 255),
        )
    out = ASSETS_DIR / "lcd-marquee.png"
    sheet.save(out, "PNG")
    print(f"wrote {out} ({sheet.width}×{sheet.height})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    generate_chrome_png()
    generate_opaque_chrome_png()
    generate_sprite_sheet()


if __name__ == "__main__":
    main()
