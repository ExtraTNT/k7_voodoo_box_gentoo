#!/usr/bin/env python3
"""Pixel-art Gentoo wallpaper in the s2466 colours, xterm-256 palette only.

    python3 art/wallpaper.py LOGO.svg OUT.png [WIDTH HEIGHT CELL]

LOGO.svg: the Gentoo logo, e.g.
  https://upload.wikimedia.org/wikipedia/commons/4/48/Gentoo_Linux_logo_matte.svg
Needs rsvg-convert and Pillow (in the WSL build distro:
  apk add python3 py3-pillow rsvg-convert).

The logo is rendered at CELL x the grid size, averaged per cell, and its
brightness mapped onto an amber ramp with 4x4 ordered dithering; a 1-cell
rim in #303030 lifts it off the background. The PNG is indexed (< 256 colours).
"""
import io
import subprocess
import sys

from PIL import Image

BG = "#121212"       # xterm 233, the theme background
RIM = "#303030"      # xterm 236, the theme's borders
# dark -> light, xterm 94 130 136 179 222; 179 is the theme accent
# (#d7a65f ~ #d7af5f), 222 its highlight (#ffcf87 ~ #ffd787)
RAMP = ["#875f00", "#af5f00", "#af8700", "#d7af5f", "#ffd787"]
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def rgb(hexcolour):
    return tuple(int(hexcolour[i:i + 2], 16) for i in (1, 3, 5))


def render_cells(svg, rows, cell):
    """RGBA logo, one pixel per grid cell (premultiplied box average)."""
    png = subprocess.run(["rsvg-convert", "-h", str(rows * cell), svg],
                         check=True, capture_output=True).stdout
    big = Image.open(io.BytesIO(png)).convert("RGBa")
    w = big.width // cell
    return big.resize((w, rows), Image.BOX, box=(0, 0, w * cell, rows * cell)).convert("RGBA")


def luminance(r, g, b):
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255


def level(lum, x, y, lo=0.30, hi=1.0):
    """Ramp index for a brightness, ordered-dithered between two levels."""
    t = min(max((lum - lo) / (hi - lo), 0.0), 1.0) * (len(RAMP) - 1)
    return min(int(t + (BAYER[y % 4][x % 4] + 0.5) / 16), len(RAMP) - 1)


def logo_mask(cells):
    w, h = cells.size
    px = cells.load()
    return {(x, y) for y in range(h) for x in range(w) if px[x, y][3] >= 128}


def rim_of(mask):
    near = {(x + dx, y + dy) for x, y in mask for dx in (-1, 0, 1) for dy in (-1, 0, 1)}
    return near - mask


def compose(cells, cols, rows, top):
    """The grid image (one pixel per cell), palette indices as colours."""
    grid = Image.new("RGB", (cols, rows), rgb(BG))
    ox, oy = (cols - cells.width) // 2, top + (rows - top - cells.height) // 2
    px, out = cells.load(), grid.load()
    mask = logo_mask(cells)
    for x, y in rim_of(mask):
        if 0 <= x + ox < cols and 0 <= y + oy < rows:
            out[x + ox, y + oy] = rgb(RIM)
    for x, y in mask:
        r, g, b, _ = px[x, y]
        out[x + ox, y + oy] = rgb(RAMP[level(luminance(r, g, b), x + ox, y + oy)])
    return grid


def main(svg, out, width=1280, height=1024, cell=8):
    cols, rows = width // cell, height // cell
    logo_rows = rows * 11 // 20                   # logo: 55 % of the screen height
    cells = render_cells(svg, logo_rows, cell)
    grid = compose(cells, cols, rows, top=2)      # keep clear of the i3bar
    palette = Image.new("P", (1, 1))
    flat = [c for h in [BG, RIM] + RAMP for c in rgb(h)]
    palette.putpalette(flat + [0] * (768 - len(flat)))
    big = grid.resize((width, height), Image.NEAREST)
    big.quantize(palette=palette, dither=Image.Dither.NONE).save(out, optimize=True)
    print(f"{out}: {width}x{height}, {cols}x{rows} cells of {cell}px, {2 + len(RAMP)} colours")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 6):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], *map(int, sys.argv[3:]))
