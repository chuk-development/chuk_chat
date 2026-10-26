#!/usr/bin/env python3
"""Fidelity sheets for the UI pieces episode 10 adds (real app above, video rebuild below).

Reference halves (real app): from the repo root,
  flutter test marketing/videos/chuk-10-private-images/_work/fidelity_test/real_widgets_test.dart
renders the REAL MessageBubble with a running and a finished generate_image call, the REAL
DesktopMediaModal (its chrome; the library needs a signed-in user), and the loaded library
grid (toolbar, _MediaFilterBar, _ImageTile hovered) copied verbatim from
media_manager_page.dart, all in the Clawed dark theme at 2 px per app px.
Video halves: the same markup and classes episode.py uses, laid out like the test.

Run:  python3 _work/fidelity.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))

from chukvid import fidelity, ui  # noqa: E402
from chukvid.core import esc, hi  # noqa: E402
from episode import DELETE02, EP_CSS, IMG, MM_DATE, MM_SIZE, MODEL, OTHERS, PROMPT, spinner  # noqa: E402

F = HERE / "fidelity"
P = HERE.parent
COL = 620


def head(text, arrow, top):
    return (f'<p class="g-head" style="position:absolute;left:20px;top:{top}px;margin:0"><span>{esc(text)}</span>'
            f'{hi(arrow, 16)}</p>')


# generating: header, activity row, loader tile (positions measured on the real render)
gen = (head("Generating image for 5s", "h-arrow-down01", 58) +
       f'<div class="g-step" style="position:absolute;left:20px;top:85px"><span class="a-badge" style="border-color:#43423F">{hi("h-flash", 14)}</span>'
       f'<span>Ran generate image<b>{esc(PROMPT)}</b></span></div>'
       f'<div class="g-tile" style="position:absolute;left:20px;top:118.5px;width:{COL}px;height:465px">'
       f'<div class="g-load">{hi("h-sparkles", 18 / 0.86)}{spinner("sp", 26, 2.5)}<span class="lbl">Generating…</span>'
       f'<span class="dim">1024 × 768</span></div></div>')
fidelity.harness(P, gen, (660, 640), F / "vid-generating.png", extra_css=EP_CSS)
fidelity.sheet(F / "real-generating.png", F / "vid-generating.png", F / "generating.jpg",
               "MessageBubble: generate_image running (activity row + _loaderTile)")

done = (head("Worked for 9s", "h-arrow-right01", 163) +
        f'<div class="g-tile" style="position:absolute;left:20px;top:193.5px;width:{COL}px;height:465px">'
        f'<div class="g-img" style="opacity:1"><img src="{IMG}" alt=""><span class="g-pill">{hi("h-sparkles", 10 / 0.86)}<span>{MODEL}</span></span></div></div>'
        f'<div class="a-ai" style="position:absolute;left:20px;top:670px;width:{COL}px"><p>Here\'s Bruno on the beach, in watercolour.</p></div>')
fidelity.harness(P, done, (660, 860), F / "vid-done.png", extra_css=EP_CSS)
fidelity.sheet(F / "real-done.png", F / "vid-done.png", F / "done.jpg",
               "MessageBubble: finished turn, image at its ratio + model pill")

# library grid: toolbar, filter track, five tiles, the first hovered
tile = (1000 - 40 - 4 * 14) / 5
tiles = (f'<div class="mm-tile"><img src="{IMG}" alt="" style="opacity:1"><div class="mm-hov" style="opacity:1"></div>'
         f'<div class="mm-acts" style="opacity:1"><span class="mm-act">{hi("h-download01", 17 / 0.86)}</span>'
         f'<span class="mm-act del">{DELETE02.format(s=17)}</span></div><div class="mm-meta" style="opacity:1">{MM_DATE} · {MM_SIZE}</div></div>' +
         "".join(f'<div class="mm-tile"><img src="{s}" alt="" style="opacity:1"></div>' for s in OTHERS))
grid = (f'<div style="position:absolute;left:0;top:0;width:1000px;height:460px">'
        f'<div class="mm-tool" style="margin-top:8px"><span class="mm-count">5 images</span><span class="a-grow"></span><span class="mm-chip"><i>{hi("h-refresh", 22 / 0.86)}</i></span></div>'
        f'<div class="mm-filter" style="top:60px"><span class="mm-seg on">Images  5</span><span class="mm-seg">Artifacts</span></div>'
        f'<div class="mm-grid" style="top:120px;grid-template-columns:repeat(5, {tile:.2f}px)">{tiles}</div></div>')
fidelity.harness(P, grid, (1000, 460), F / "vid-grid.png", extra_css=EP_CSS)
fidelity.sheet(F / "real-grid.png", F / "vid-grid.png", F / "grid.jpg",
               "Media library: toolbar, _MediaFilterBar, _ImageTile (hover: actions, date · size)")

# modal chrome: panel, title, close chip, toolbar (the real one shows its no-session error body)
modal = (f'<div class="mm-panel" style="left:24px;top:24px;width:952px;height:592px">'
         f'<div class="mm-head"><span class="mm-title">Media Manager</span><span class="a-grow"></span><span class="mm-close">{hi("h-cancel01", 20 / 0.86)}</span></div>'
         f'<div class="mm-tool"><span class="mm-count">0 images</span><span class="a-grow"></span><span class="mm-chip"><i>{hi("h-refresh", 22 / 0.86)}</i></span></div></div>')
fidelity.harness(P, modal, (1000, 640), F / "vid-modal.png", extra_css=EP_CSS, bg="#000000")
fidelity.sheet(F / "real-modal.png", F / "vid-modal.png", F / "modal.jpg",
               "DesktopMediaModal chrome (title, close chip, toolbar)")
