#!/usr/bin/env python3
"""Screenshot a local HTML file with the HyperFrames chrome: shot_html.py in.html out.png W H"""
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
from chukvid.core import launch_chrome  # noqa: E402

src, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with sync_playwright() as p:
    b = launch_chrome(p)
    pg = b.new_page(viewport={'width': w, 'height': h})
    pg.goto(Path(src).resolve().as_uri())
    pg.wait_for_timeout(500)
    pg.screenshot(path=out)
    b.close()
