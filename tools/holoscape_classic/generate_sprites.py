"""Generate the HoloscapeClassic skin's sprite sheets.

Emits beveled chrome button states (Winamp 2.x aesthetic — flat dark
chrome with 1px highlight/shadow bevels and an LCD-green accent on
hover/pressed). Run from the repo root:

    uv run --with pillow Tools/holoscape_classic/generate_sprites.py

Regenerate any time the palette is tweaked. Output ends up at
Sources/Holoscape/Resources/Skins/HoloscapeClassic/assets/*.png.
"""

from PIL import Image
import os
import pathlib

# Resolve OUT_DIR via __file__ so the script is safe to run from any
# CWD. This file lives at Tools/holoscape_classic/generate_sprites.py
# — two parents up is the repo root.
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT_DIR = str(REPO_ROOT / "Sources/Holoscape/Resources/Skins/HoloscapeClassic/assets")

# Winamp-class palette: dark chrome with LCD green accent.
CHROME_HIGHLIGHT = (0x7a, 0x7a, 0x7a)   # top + left edge highlight
CHROME_SHADOW    = (0x12, 0x12, 0x12)   # bottom + right edge shadow
CHROME_TOP       = (0x4a, 0x4a, 0x4a)   # body gradient top
CHROME_BOT       = (0x32, 0x32, 0x32)   # body gradient bottom
LCD_GREEN        = (0x00, 0xc8, 0x78)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_button(img, ox, W, H, state):
    """Draw a W×H beveled button at column offset `ox` in `img`.

    `state` picks the palette:
      - normal  : flat chrome with standard bevel
      - hover   : slightly lighter chrome + LCD-green inner bevel
      - pressed : inverted bevel (dark top/left, light bottom/right)
                  + LCD-green inner bevel. Visually "pushed in."
    """
    if state == "normal":
        body_top, body_bot = CHROME_TOP, CHROME_BOT
        hl, sh = CHROME_HIGHLIGHT, CHROME_SHADOW
        accent = None
    elif state == "hover":
        body_top = lerp(CHROME_TOP, (0xff, 0xff, 0xff), 0.12)
        body_bot = lerp(CHROME_BOT, (0xff, 0xff, 0xff), 0.12)
        hl = lerp(CHROME_HIGHLIGHT, (0xff, 0xff, 0xff), 0.2)
        sh = CHROME_SHADOW
        accent = LCD_GREEN
    elif state == "pressed":
        body_top, body_bot = CHROME_BOT, CHROME_TOP   # inverted gradient
        hl, sh = CHROME_SHADOW, CHROME_HIGHLIGHT        # inverted bevel
        accent = LCD_GREEN
    else:
        raise ValueError(f"unknown state {state}")

    for y in range(H):
        for x in range(W):
            on_top   = y == 0
            on_left  = x == 0
            on_right = x == W - 1
            on_bot   = y == H - 1

            if on_top or on_left:
                color = hl
            elif on_bot or on_right:
                color = sh
            else:
                t = (y - 1) / max(1, H - 3)
                color = lerp(body_top, body_bot, t)
            img.putpixel((ox + x, y), color + (255,))

    # LCD green inner bevel — 1px ring just inside the outer bevel.
    # Gives hover / pressed a faint glow so the button reads as "live"
    # without masking the underlying chrome.
    if accent:
        for y in range(1, H - 1):
            for x in range(1, W - 1):
                on_inner = (y == 1 or y == H - 2 or x == 1 or x == W - 2)
                if on_inner:
                    existing = img.getpixel((ox + x, y))[:3]
                    blended = lerp(existing, accent, 0.35)
                    img.putpixel((ox + x, y), blended + (255,))


def draw_tab_sprite(img, ox, W, H, state):
    """Active / normal / hover tab background. Wider than the button
    because tabs carry a label. Uses the same bevel vocabulary but
    with the LCD-green on the active tab's top edge.
    """
    if state == "active":
        body_top = lerp(CHROME_TOP, LCD_GREEN, 0.15)
        body_bot = CHROME_TOP
        hl = LCD_GREEN                      # green top/left highlight
        sh = CHROME_SHADOW
    elif state == "hover":
        body_top = lerp(CHROME_TOP, (0xff, 0xff, 0xff), 0.1)
        body_bot = CHROME_BOT
        hl = CHROME_HIGHLIGHT
        sh = CHROME_SHADOW
    else:  # normal
        body_top = CHROME_TOP
        body_bot = CHROME_BOT
        hl = CHROME_HIGHLIGHT
        sh = CHROME_SHADOW

    for y in range(H):
        for x in range(W):
            on_top   = y == 0
            on_left  = x == 0
            on_right = x == W - 1
            # No bottom highlight — tab blends into tab-bar container.
            if on_top or on_left:
                color = hl
            elif on_right:
                color = sh
            else:
                t = (y - 1) / max(1, H - 2)
                color = lerp(body_top, body_bot, t)
            img.putpixel((ox + x, y), color + (255,))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # Refresh button: 3 cells × 24×24.
    BW, BH = 24, 24
    btn = Image.new("RGBA", (BW * 3, BH), (0, 0, 0, 0))
    draw_button(btn, BW * 0, BW, BH, "normal")
    draw_button(btn, BW * 1, BW, BH, "hover")
    draw_button(btn, BW * 2, BW, BH, "pressed")
    btn_path = os.path.join(OUT_DIR, "button-sprite.png")
    btn.save(btn_path)
    print(f"wrote {btn_path}")

    # Tab sprite: 3 cells × 120×28 (normal / hover / active).
    TW, TH = 120, 28
    tab = Image.new("RGBA", (TW * 3, TH), (0, 0, 0, 0))
    draw_tab_sprite(tab, TW * 0, TW, TH, "normal")
    draw_tab_sprite(tab, TW * 1, TW, TH, "hover")
    draw_tab_sprite(tab, TW * 2, TW, TH, "active")
    tab_path = os.path.join(OUT_DIR, "tab-sprite.png")
    tab.save(tab_path)
    print(f"wrote {tab_path}")


if __name__ == "__main__":
    main()
