"""Tile PNG frames into a labelled contact sheet: python3 tools/sheet.py OUT.jpg COLS W frame1.png ..."""
import os
import sys

from PIL import Image, ImageDraw

out, cols, w = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fs = sys.argv[4:]
ims = [Image.open(f).convert("RGB") for f in fs]
h = int(w * ims[0].height / ims[0].width)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (w + 6), rows * (h + 30)), "#222")
d = ImageDraw.Draw(sheet)
for i, (f, im) in enumerate(zip(fs, ims)):
    x, y = (i % cols) * (w + 6), (i // cols) * (h + 30)
    sheet.paste(im.resize((w, h)), (x, y + 26))
    d.text((x + 4, y + 6), os.path.basename(f), fill="white")
sheet.save(out, quality=88)
