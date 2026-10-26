#!/usr/bin/env python3
"""Side-by-side fidelity sheets: the real screenshot crop (scaled to the video's scale)
above the same piece from the rendered frame.

Screenshots are 1.75 px per app CSS px. The video draws the composer at 2.2 and the
chat column at 2.0 px per CSS px, so the screenshot crop is scaled by 2.2/1.75 or 2.0/1.75.
Run after a snapshot:  python3 _work/fidelity.py <composer_frame.png> <chat_frame.png>
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W = Path(__file__).resolve().parent
OUT = W / "fidelity"
OUT.mkdir(exist_ok=True)
REF = W / "ref"
FONT = ImageFont.truetype(str(W.parent / "assets/fonts/Ubuntu-wght.ttf"), 28)


def sheet(ref_img, ref_box, scale, vid_img, vid_box, name, title):
    r = ref_img.crop(ref_box)
    r = r.resize((round(r.width * scale), round(r.height * scale)), Image.LANCZOS)
    v = vid_img.crop(vid_box)
    w = max(r.width, v.width) + 40
    h = r.height + v.height + 160
    c = Image.new("RGB", (w, h), (20, 20, 19))
    d = ImageDraw.Draw(c)
    d.text((20, 14), f"REAL APP (screenshot, scaled {scale:.3f}) - {title}", fill=(230, 230, 220), font=FONT)
    c.paste(r, (20, 56))
    y = 56 + r.height + 30
    d.text((20, y), "VIDEO RENDER (same scale)", fill=(230, 230, 220), font=FONT)
    c.paste(v, (20, y + 42))
    c.save(OUT / name, quality=92)
    print("wrote", OUT / name)


home = Image.open(REF / "home_ui.png").convert("RGB")
tool = Image.open(REF / "tool_calling_ui.png").convert("RGB")
comp_frame = Image.open(sys.argv[1]).convert("RGB")
chat_frame = Image.open(sys.argv[2]).convert("RGB")

# composer: screenshot composer at x 1388, y 920 (4K px); video composer at 291.2, 366.2
s = 2.2 / 1.75
rx, ry, rw, rh = 1380, 910, 1080, 300
vx = 291.2 - (1388 - rx) * s
vy = 366.2 - (920 - ry) * s
sheet(home, (rx, ry, rx + rw, ry + rh), s, comp_frame,
      (round(vx), round(vy), round(vx + rw * s), round(vy + rh * s)), "composer.jpg",
      "composer: Ask me anything !, plus, Fast, mic, send, disclaimer")

# chat: align on the user bubble's right edge and top
s = 2.0 / 1.75
rx, ry, rw, rh = 1260, 160, 1320, 750
bub_r_ref, bub_t_ref = 2556, 170
bub_r_vid, bub_t_vid = 1688, 234
vx = bub_r_vid - (bub_r_ref - rx) * s
vy = bub_t_vid - (bub_t_ref - ry) * s
vh = min(rh * s, 1080 - vy)
sheet(tool, (rx, ry, rx + rw, ry + round(vh / s)), s, chat_frame,
      (round(vx), round(vy), round(vx + rw * s), round(vy + vh)), "chat.jpg",
      "user bubble, Worked for 2s, steps, source chips, answer text")

# close-ups at 2x of the same pieces
for name in ("composer.jpg", "chat.jpg"):
    im = Image.open(OUT / name)
    print(name, im.size)
