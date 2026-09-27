"""Assemble compositions/chuk-window.html from tools/chuk-window.src.html.

The source keeps three placeholders so the long static parts stay out of the
file you edit: <!--SPRITE--> (HugeIcons subset), <!--LP--> (the Spoke landing
page from the founders world), <!--PAGE--> (the invoice from the business
world). Run: python3 tools/build_window.py
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = os.path.join(ROOT, "tools")
src = open(os.path.join(T, "chuk-window.src.html")).read()
for key, name in (("<!--SPRITE-->", "icon-subset.svg.html"), ("<!--LP-->", "_lp.html"), ("<!--PAGE-->", "_page.html")):
    assert key in src, key
    src = src.replace(key, open(os.path.join(T, name)).read().strip())
open(os.path.join(ROOT, "compositions", "chuk-window.html"), "w").write(src)
print("compositions/chuk-window.html written:", len(src.splitlines()), "lines")
