#!/usr/bin/env python3
"""Fidelity sheets for the app pieces of episode 12.

Reference halves (real app): flutter test marketing/videos/chuk-12-memory/_work/
fidelity_test/real_widgets_test.dart renders the real widgets of the workspace Settings
tab (workspace_detail_page.dart) and of the Memory section (system_prompt_page.dart) in
the Clawed dark theme at 2 px per app px -> _work/fidelity/real-*.png.
Video halves: ui12.workspace_page() / ui12.memory_page() in the same state and size.
Also writes diff-*.png (absolute difference, x4) to spot offsets.

Run:  python3 _work/fidelity.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))
from PIL import Image, ImageChops  # noqa: E402

from chukvid import fidelity  # noqa: E402
import ui12  # noqa: E402
from episode import C, HINT_PROMPT, MEMORY_EXAMPLE, MEMORY_HINT  # noqa: E402

F = HERE / "fidelity"
P = HERE.parent
W = C["workspace"]
M = C["memory"]

ws = ui12.workspace_page("fw", 760, 700, 0, W["name"], W["description"], 4, 2, "3m ago", HINT_PROMPT)
ws = ws.replace('<span id="fw-typed" style="display:none"></span>', f'<span id="fw-typed">{W["prompt"]}</span>')
ws = ws.replace('id="fw-save" style="opacity:0"', 'id="fw-save"')
ws = ws.replace(f'<span class="w-hint" id="fw-ph">{ui12.esc(HINT_PROMPT)}</span>', "")
fidelity.harness(P, ws, (760, 700), F / "vid-workspace.png", extra_css=ui12.CSS)

mem = ui12.memory_page("fm", 760, 560, 0, MEMORY_HINT, M["old"], "\n" + M["new"], MEMORY_EXAMPLE)
mem = mem.replace('<span id="fm-typed"></span>', f'<span id="fm-typed">\n{M["new"]}</span>')  # typed: Enter + the line
n0 = len(M["old"])
mem = mem.replace(f'id="fm-cnt{n0}" style="display:inline"', f'id="fm-cnt{n0}" style="display:none"')
mem = mem.replace(f'id="fm-cnt{len(M["text"])}" style="display:none"', f'id="fm-cnt{len(M["text"])}" style="display:inline"')
mem = mem.replace('class="w-btn w-msave"', 'class="w-btn w-msave on"')
fidelity.harness(P, mem, (760, 560), F / "vid-memory.png", extra_css=ui12.CSS)

for name, title in (("workspace", "workspace_detail_page.dart Settings tab: header, tabs, cards, fields, Save Changes"),
                    ("memory", "system_prompt_page.dart Memory section: header, info card, field, import row, Save")):
    fidelity.sheet(F / f"real-{name}.png", F / f"vid-{name}.png", F / f"{name}.jpg", title)
    a = Image.open(F / f"real-{name}.png").convert("RGB")
    b = Image.open(F / f"vid-{name}.png").convert("RGB").resize(a.size)
    ImageChops.difference(a, b).point(lambda v: min(255, v * 4)).save(F / f"diff-{name}.png")
