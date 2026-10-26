"""Fidelity sheets: the real app piece above the video's rebuild, at the same scale.

Two kinds of reference:
* a crop of a real screenshot (assets/screenshots/*.webp), as 08 did, or
* the REAL Flutter widget rendered by a widget test to PNG (see
  chuk-09-your-files/_work/fidelity_test/real_widgets_test.dart for the pattern:
  buildAppTheme(Clawed dark) + the widget, RepaintBoundary.toImage at pixelRatio 2).

harness() renders a library piece alone, laid out like the widget test, with the
project's fonts, so the two halves line up pixel for pixel.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .core import COMMON_CSS, LIB, T, launch_chrome
from .ui import ALL_CSS


def harness(project_dir, body, size, out_png, ratio=2.0, bg="#262624", extra_css=""):
    """Render `body` (app px, inside a-vars) at `size` app px, `ratio` device px per app px."""
    from playwright.sync_api import sync_playwright
    project_dir = Path(project_dir).resolve()
    w, h = size
    page = f"""<!doctype html><html><head><meta charset="utf-8"><base href="{project_dir.as_uri()}/">
<style>* {{ margin: 0; padding: 0; box-sizing: border-box; }} html, body {{ width: {w}px; height: {h}px; background: {bg}; overflow: hidden; }}
{COMMON_CSS}
{T(ALL_CSS)}
{T(extra_css)}
</style></head><body><div id="root" class="a-vars" style="background:{bg}">{T(body)}</div></body></html>"""
    tmp = project_dir / "_work" / f".harness-{Path(out_png).stem}.html"
    tmp.write_text(page)
    with sync_playwright() as p:
        b = launch_chrome(p)
        pg = b.new_page(viewport={"width": w, "height": h}, device_scale_factor=ratio)
        pg.goto(tmp.as_uri())
        pg.wait_for_timeout(500)
        pg.screenshot(path=str(out_png))
        b.close()
    tmp.unlink()
    return out_png


def sheet(ref_png, vid_png, out_jpg, title, ref_label="REAL APP", vid_label="VIDEO RENDER (same scale)"):
    font = ImageFont.truetype(str(LIB / "assets/fonts/Ubuntu-wght.ttf"), 28)
    r = Image.open(ref_png).convert("RGB")
    v = Image.open(vid_png).convert("RGB")
    w = max(r.width, v.width) + 40
    h = r.height + v.height + 160
    c = Image.new("RGB", (w, h), (20, 20, 19))
    d = ImageDraw.Draw(c)
    d.text((20, 14), f"{ref_label} - {title}", fill=(230, 230, 220), font=font)
    c.paste(r, (20, 56))
    y = 56 + r.height + 30
    d.text((20, y), vid_label, fill=(230, 230, 220), font=font)
    c.paste(v, (20, y + 42))
    c.save(out_jpg, quality=92)
    print("wrote", out_jpg, c.size)
    return out_jpg
