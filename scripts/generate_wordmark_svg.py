#!/usr/bin/env python3
"""Regenerate assets/wordmark.svg — the frozen brand lockup.

Reproduces the chuk.chat website nav lockup as glyph outlines so the app
renders it pixel-identically on every platform:

    Chuk Chat                       Liberation Mono Bold 22px
    Private and Secure. Always.     Liberation Mono Regular 10px, +0.5px tracking

(The website CSS asks for "Courier New"; Liberation Mono is the
metric-compatible font browsers substitute on Linux, and it is what the
original frozen wordmark glyphs were vectorized from.)

Vertical rhythm matches the website's stacked line boxes (22px line over
10px line, no gap) using hhea font metrics, the same way Chrome lays out
the nav. The slogan group carries fill-opacity to mimic the website's
lighter #888-on-#2d2d2d slogan color while the app tints the whole SVG
with a single color filter (per-pixel alpha survives BlendMode.srcIn).

Usage: python3 scripts/generate_wordmark_svg.py
"""

import re
import sys
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "assets" / "wordmark.svg"

def find_font(filename, fc_pattern):
    """Locate a Liberation Mono face: known Debian path, else fc-match."""
    known = Path("/usr/share/fonts/truetype/liberation") / filename
    if known.exists():
        return str(known)
    import subprocess

    path = subprocess.run(
        ["fc-match", "--format=%{file}", fc_pattern],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if filename not in path:
        sys.exit(f"error: {fc_pattern} not installed (fc-match gave {path}); "
                 "install fonts-liberation")
    return path


BOLD = find_font("LiberationMono-Bold.ttf", "Liberation Mono:bold")
REGULAR = find_font("LiberationMono-Regular.ttf", "Liberation Mono")

WORDMARK = "Chuk Chat"
WORDMARK_PX = 22.0
SLOGAN = "Private and Secure. Always."
SLOGAN_PX = 10.0
SLOGAN_TRACKING_PX = 0.5  # CSS letter-spacing on .logo-slogan
SLOGAN_OPACITY = 0.55  # ≈ #888 slogan over #2d2d2d wordmark on white

# Frozen geometry of the original single-line wordmark: its baseline sat
# at y=15.941 so that the ascender ink (h, k) touched y=0 exactly.
WORDMARK_BASELINE_Y = 15.941


def fmt(v, nd=3):
    s = f"{v:.{nd}f}".rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def glyph_ink_bbox(d):
    """Ink bbox of an SVG path in font units (control points; exact enough
    for quadratics whose on-curve extremes dominate mono glyphs)."""
    xs, ys = [], []
    x = y = 0.0
    cur = None
    buf = []
    for cmd, num in re.findall(r"([A-Za-z])|(-?\d+\.?\d*)", d):
        if cmd:
            cur = cmd
            buf = []
            continue
        buf.append(float(num))
        if cur in "ML" and len(buf) == 2:
            x, y = buf
            xs.append(x), ys.append(y)
            buf = []
        elif cur == "Q" and len(buf) == 4:
            xs += buf[0::2]
            ys += buf[1::2]
            x, y = buf[2], buf[3]
            buf = []
        elif cur == "V" and len(buf) == 1:
            y = buf[0]
            xs.append(x), ys.append(y)
            buf = []
        elif cur == "H" and len(buf) == 1:
            x = buf[0]
            xs.append(x), ys.append(y)
            buf = []
    return min(xs), min(ys), max(xs), max(ys)


def line_paths(font_path, text, px, baseline_y, pen_x, tracking=0.0):
    """Outline one text line. Returns (svg path elements, ink bbox)."""
    font = TTFont(font_path)
    upm = font["head"].unitsPerEm
    scale = px / upm
    glyph_set = font.getGlyphSet()
    cmap = font.getBestCmap()
    paths = []
    ink = [1e9, 1e9, -1e9, -1e9]
    x = pen_x
    for ch in text:
        if ch != " ":
            glyph = glyph_set[cmap[ord(ch)]]
            pen = SVGPathPen(glyph_set)
            glyph.draw(pen)
            d = pen.getCommands()
            x0, y0, x1, y1 = glyph_ink_bbox(d)
            ink[0] = min(ink[0], x + x0 * scale)
            ink[1] = min(ink[1], baseline_y - y1 * scale)
            ink[2] = max(ink[2], x + x1 * scale)
            ink[3] = max(ink[3], baseline_y - y0 * scale)
            paths.append(
                f'<path transform="translate({fmt(x)},{fmt(baseline_y)}) '
                f'scale({fmt(scale, 6)},-{fmt(scale, 6)})" d="{d}"/>'
            )
        x += glyph_set[cmap[ord(ch)]].width * scale + tracking
    return paths, ink


def css_baseline_gap():
    """Distance between the two baselines when Chrome stacks a 22px line
    box directly above a 10px line box (line-height == font-size)."""
    font = TTFont(BOLD)
    upm = font["head"].unitsPerEm
    asc = font["hhea"].ascent / upm
    desc = -font["hhea"].descent / upm

    def baseline_in_box(px):
        half_leading = (px - px * (asc + desc)) / 2
        return half_leading + px * asc

    return WORDMARK_PX + baseline_in_box(SLOGAN_PX) - baseline_in_box(WORDMARK_PX)


def main():
    # Line 1 — frozen wordmark. Pen starts at -0.859 so the C's ink hits
    # x=0 exactly, matching the original hand-frozen file.
    wm_paths, wm_ink = line_paths(BOLD, WORDMARK, WORDMARK_PX, WORDMARK_BASELINE_Y, -0.859)

    # Line 2 — slogan, text-box left-aligned with the wordmark like the
    # website nav (same pen origin, not ink-aligned).
    slogan_baseline = WORDMARK_BASELINE_Y + css_baseline_gap()
    sl_paths, sl_ink = line_paths(
        REGULAR, SLOGAN, SLOGAN_PX, slogan_baseline, -0.859, SLOGAN_TRACKING_PX
    )

    min_x = min(wm_ink[0], sl_ink[0])
    min_y = min(wm_ink[1], sl_ink[1])
    max_x = max(wm_ink[2], sl_ink[2])
    max_y = max(wm_ink[3], sl_ink[3])

    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="{fmt(min_x, 2)} {fmt(min_y, 2)} {fmt(max_x - min_x, 2)} {fmt(max_y - min_y, 2)}">'
        f'<g fill="#000000">{"".join(wm_paths)}</g>'
        f'<g fill="#000000" fill-opacity="{SLOGAN_OPACITY}">{"".join(sl_paths)}</g>'
        f"</svg>"
    )
    OUT.write_text(svg)

    wordmark_ink_h = wm_ink[3] - wm_ink[1]
    total_h = max_y - min_y
    print(f"wordmark ink: {wm_ink}")
    print(f"slogan ink:   {sl_ink}")
    print(f"viewBox: {fmt(min_x,2)} {fmt(min_y,2)} {fmt(max_x-min_x,2)} {fmt(max_y-min_y,2)}")
    print(f"wordmark ink height: {wordmark_ink_h:.4f}")
    print(f"total/wordmark height ratio: {total_h / wordmark_ink_h:.6f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
