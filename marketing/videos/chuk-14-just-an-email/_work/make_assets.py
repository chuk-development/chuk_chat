#!/usr/bin/env python3
"""Episode 14 assets: the layout probe.

Episode 09 made ciphertext here; episode 14 has no stored data to show. What it needs is
where things sit: the cursor clicks real targets (fields, checkboxes, dialog buttons) and the
camera frames them, and the sign-up card re-centres itself while the strength meter grows
(LoginPage centres the card and scrolls when it is taller than the window). So the pieces of
pieces.py are laid out once in headless Chrome with the project fonts, in every state the film
shows, and every rect (app px, relative to the window) goes to _work/layout.json.

Run once (and after any change to pieces.py or the window sizes):
    python3 _work/make_assets.py
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))
from chukvid.core import COMMON_CSS, T, launch_chrome  # noqa: E402
from chukvid.ui import ALL_CSS  # noqa: E402
import pieces as P  # noqa: E402

PROJ = HERE.parent
EMAIL, PW = "sam@example.com", "Tide-Lantern-48!"
# app-px window sizes per format: (sign-up/code window), (settings window)
WINDOWS = {"16x9": {"login": (560, 740), "settings": (640, 460)},
           "9x16": {"login": (440, 780), "settings": (440, 640)}}


SETUP = """
function $(s){return document.querySelector(s);}
function val(id,t){ $(id+'-val').textContent=t; }
function meter(id,st){ $(id).style.display='flex'; $(id+'-l'+st.idx).style.display='inline';  $(id+'-reqs').style.display=st.valid?'none':'flex'; }
function R(sel){ var w=$('#win').getBoundingClientRect(), r=$(sel).getBoundingClientRect();
  return [r.left-w.left, r.top-w.top, r.width, r.height]; }
"""


def states(fmt):
    lw, lh = WINDOWS[fmt]["login"]
    sw, sh = WINDOWS[fmt]["settings"]
    login = lambda body: f'<div id="win" class="lg-page" style="left:0;top:0;width:{lw}px;height:{lh}px">{body}</div>'  # noqa: E731
    sets = lambda body: f'<div id="win" class="fill" style="width:{sw}px;height:{sh}px;background:#262624">{body}</div>'  # noqa: E731
    sel_s = ["#s", "#s-name", "#s-mail", "#s-pw", "#s-m", "#s-pw2", "#s-cb1 .lg-box", "#s-cb2 .lg-box", "#s-go"]
    dz = f'<div style="position:absolute;left:16px;top:8px">{P.danger("d", sw - 32)}</div>'
    out = [
        ("signup_empty", login(P.signup_card("s")), "", sel_s),
        ("signup_list", login(P.signup_card("s")),
         f"val('#s-mail','{EMAIL}'); val('#s-pw','xxxxxxx'); meter('#s-m',{json.dumps(P.strength('Tide-La'))});", sel_s),
        ("signup_strong", login(P.signup_card("s")),
         f"val('#s-mail','{EMAIL}'); val('#s-pw','x'); meter('#s-m',{json.dumps(P.strength(PW))});", sel_s),
        ("otp", login(P.otp_card("o", EMAIL)), "", ["#o", "#o-code", "#o-go"]),
        ("danger", sets(dz), "", ["#d", "#d-btn"]),
    ]
    for i, fn in ((1, P.step1), (2, P.step2), (3, P.step3)):
        out.append((f"dlg{i}", sets(dz + fn("k")), "", ["#k", "#k-a0", "#k-a1"] + (["#k-pw"] if i == 3 else [])))
    return out


def main():
    from playwright.sync_api import sync_playwright
    result = {}
    with sync_playwright() as p:
        b = launch_chrome(p)
        pg = b.new_page(viewport={"width": 1200, "height": 1200})
        for fmt in WINDOWS:
            res = {"windows": WINDOWS[fmt]}
            for name, body, script, sels in states(fmt):
                html = (f'<!doctype html><html><head><meta charset="utf-8"><base href="{PROJ.as_uri()}/"><style>'
                        f'* {{ margin:0; padding:0; box-sizing:border-box; }}{COMMON_CSS}{T(ALL_CSS)}{P.CSS}</style></head>'
                        f'<body><div id="root" class="a-vars">{T(body)}</div><script>{SETUP}{script}</script></body></html>')
                tmp = HERE / ".probe.html"
                tmp.write_text(html)
                pg.goto(tmp.as_uri())
                pg.evaluate("document.fonts.ready")
                pg.wait_for_timeout(300)
                res[name] = {s: [round(v, 2) for v in pg.evaluate(f"R({json.dumps(s)})")] for s in sels}
            result[fmt] = res
        b.close()
    (HERE / ".probe.html").unlink()
    (HERE / "layout.json").write_text(json.dumps(result, indent=1))
    for fmt, r in result.items():
        print(fmt, {k: v.get("#s", v.get("#k", v.get("#o", v.get("#d")))) for k, v in r.items() if k != "windows"})


if __name__ == "__main__":
    main()
