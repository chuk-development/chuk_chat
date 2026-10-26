#!/usr/bin/env python3
"""Screenshot a local HTML file with the HyperFrames chrome: shot_html.py in.html out.png W H"""
import glob, os, sys
from playwright.sync_api import sync_playwright
C = sorted(glob.glob(os.path.expanduser('~/.cache/hyperframes/chrome/chrome-headless-shell/*/chrome-headless-shell-linux64/chrome-headless-shell')))[-1]
src, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with sync_playwright() as p:
    b = p.chromium.launch(executable_path=C)
    pg = b.new_page(viewport={'width': w, 'height': h})
    pg.goto('file://' + os.path.abspath(src)); pg.wait_for_timeout(500)
    pg.screenshot(path=out); b.close()
