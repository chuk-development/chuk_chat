#!/usr/bin/env python3
"""Fidelity sheets for the app pieces of episode 13 (none of them is in _lib yet).

Reference halves (real app): flutter test marketing/videos/chuk-13-connectors/_work/
fidelity_test/real_widgets_test.dart renders the REAL McpConnectorsPage and the REAL
McpConnectorDetailPage (Clawed dark theme, Ubuntu as the system UI font, 2 px per app px)
-> _work/fidelity/real-*.png, plus real-*.json with every text's box and style.
Video halves: the rebuilt pages from episode.py, alone, at the same 2 px per app px.

Run (after the widget test):  python3 _work/fidelity.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))
from PIL import Image  # noqa: E402

from chukvid import fidelity  # noqa: E402
import episode  # noqa: E402

F = HERE / "fidelity"
P = HERE.parent                      # the 16:9 project: its assets/ hold the logos


def side_by_side(ref, vid, out, title):
    """Real | video next to each other (the pages are tall)."""
    r, v = Image.open(ref).convert("RGB"), Image.open(vid).convert("RGB")
    c = Image.new("RGB", (r.width + v.width + 40, max(r.height, v.height)), (20, 20, 19))
    c.paste(r, (0, 0))
    c.paste(v, (r.width + 40, 0))
    from PIL import ImageDraw, ImageFont
    font = ImageFont.truetype(str(HERE.parents[1] / "_lib/assets/fonts/Ubuntu-wght.ttf"), 30)
    s = Image.new("RGB", (c.width + 40, c.height + 80), (20, 20, 19))
    d = ImageDraw.Draw(s)
    d.text((20, 20), f"REAL APP (left)  |  VIDEO RENDER (right), 2 px per app px - {title}", fill=(230, 230, 220), font=font)
    s.paste(c, (20, 70))
    s.save(out, quality=92)
    print("wrote", out, s.size)


for name, w, h, body in [
    ("list-600", 600, 900, episode.connectors_page("p", 600, 900)),
    ("list-connected-376", 376, 900, episode.connectors_page("p", 376, 900, connected=True)),
    ("detail-600", 600, 760, episode.detail_page("d", 600, 760)[0]),
    ("detail-376", 376, 760, episode.detail_page("d", 376, 760)[0]),
]:
    vid = F / f"vid-{name}.png"
    fidelity.harness(P, body, (w, h), vid, extra_css=episode.EP_CSS)
    side_by_side(F / f"real-{name}.png", vid, F / f"{name}.jpg", f"lib/pages/mcp_connectors_page.dart ({name})")
