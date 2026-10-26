#!/usr/bin/env python3
"""Fidelity sheets for episode 11: the real sidebars above the rebuild, same scale.

Reference halves (real app): flutter test marketing/videos/chuk-11-local-search/_work/
fidelity_test/real_sidebar_test.dart renders the REAL SidebarDesktop (320 x 540, with the
hamburger of root_wrapper_desktop.dart) and SidebarMobile (360 x 470) in the Clawed dark
theme at 2 px per app px, idle, with the field open and with "landlord" typed
-> _work/fidelity/real-*.png.
Video halves: sidebar.py at the same size and 2 px per app px.

Run:  python3 _work/fidelity.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))
from PIL import Image  # noqa: E402

from chukvid import fidelity  # noqa: E402
import sidebar as sb  # noqa: E402

F = HERE / "fidelity"
P = HERE.parent


def side_by_side(a, b, out):
    """Real left, rebuild right, one image (easier to compare a tall panel)."""
    ra, rb = Image.open(a).convert("RGB"), Image.open(b).convert("RGB")
    c = Image.new("RGB", (ra.width + rb.width + 30, max(ra.height, rb.height)), (20, 20, 19))
    c.paste(ra, (0, 0))
    c.paste(rb, (ra.width + 30, 0))
    c.save(out)


STATES = {"idle": "", "search": "landlord"}
for kind, (w, h) in (("desktop", (320, 540)), ("mobile", (360, 470))):
    for state, q in STATES.items():
        html = sb.sidebar("s", kind, h, [q])
        if q:
            html = html.replace('id="s-searchnav" style="', 'id="s-searchnav" style="display:none;')
            html = html.replace('id="s-field" style="position:absolute;inset:0;display:none"', 'id="s-field" style="position:absolute;inset:0"')
            html = html.replace('id="s-hint" class="sbx-hint"', 'id="s-hint" class="sbx-hint" style="display:none"')
            html = html.replace('<span id="s-caret" class="sbx-caret"></span>', '')
            html = html.replace('<span id="s-typed" style="display:none"></span>', f'<span id="s-typed">{q}</span>')
            html = html.replace('id="s-clear" style="opacity:0"', 'id="s-clear"')
        vid = F / f"vid-{kind}-{state}.png"
        fidelity.harness(P, html, (w, h), vid, extra_css=sb.CSS)
        side_by_side(F / f"real-{kind}-{state}.png", vid, F / f"cmp-{kind}-{state}.png")
        fidelity.sheet(F / f"real-{kind}-{state}.png", vid, F / f"{kind}-{state}.jpg",
                       f"Sidebar{kind.title()} ({w} wide), {'idle' if not q else 'search: ' + q}")
