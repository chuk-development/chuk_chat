#!/usr/bin/env python3
"""Episode 10 assets: the "generated" watercolour, the real request body and the real
ciphertext size of the stored image.

1. _work/bruno.html (SVG watercolour, seeded filters, no paid generation) -> rendered at
   1536x1152 (4:3, the server default image_size landscape_4_3) -> JPEG quality 85, what
   ImageCompressionService.compressImage stores (max 1920 px, first quality 85, < 2 MB).
   -> _work/gen/bruno.jpg
2. The request body exactly as api_server build_openrouter_image_request() builds it
   (routers/ai/images.py:427-442, provider policy :56-60), key order kept.
3. The JPEG bytes -> EncryptionService.encryptBytes envelope (AES-256-GCM, v "1", random
   key thrown away). Its JSON is the .enc object at images/<uid>/<uuid>.enc; only its size
   is kept (the film never prints the envelope). Neighbours: real ciphertext of random
   bytes, only names and sizes are shown.
Run once:  python3 _work/make_assets.py   -> _work/gen/bruno.jpg, _work/cipher.json
"""
import io
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid import cipher  # noqa: E402
from PIL import Image  # noqa: E402

GEN = HERE / "gen"
GEN.mkdir(exist_ok=True)
PROMPT = "a watercolour of our dog Bruno on the beach"

subprocess.run([sys.executable, str(HERE / "shot_html.py"), str(HERE / "bruno.html"),
                str(GEN / "bruno.png"), "1536", "1152"], check=True)
buf = io.BytesIO()
Image.open(GEN / "bruno.png").convert("RGB").save(buf, "JPEG", quality=85)
(GEN / "bruno.jpg").write_bytes(buf.getvalue())
(GEN / "bruno.png").unlink()
jpg = buf.getvalue()

# Older generations of the same user in the library: crops of the same painting, graded,
# so the grid holds more than one picture (no second drawing needed).
from PIL import ImageEnhance  # noqa: E402
src = Image.open(io.BytesIO(jpg)).convert("RGB")
for name, box, tint, sat in (("other1", (0, 380, 760, 950), (238, 150, 96), 1.15),   # headland, sunset
                             ("other2", (560, 760, 900, 1100), None, 1.1),           # ball and prints
                             ("other3", (980, 60, 1480, 560), (120, 160, 210), 0.9), # sun and gull
                             ("other4", (700, 400, 1000, 700), None, 1.2)):          # Bruno's head
    im = src.crop(box).resize((900, 900), Image.LANCZOS)
    im = ImageEnhance.Color(im).enhance(sat)
    if tint:
        im = Image.blend(im, Image.new("RGB", im.size, tint), 0.22)
    im.save(GEN / f"{name}.jpg", "JPEG", quality=85)

request = {
    "model": "krea/krea-2-large",          # IMAGE_MODELS["krea"], DEFAULT_IMAGE_MODEL
    "prompt": PROMPT,
    "n": 1,
    "provider": {"zdr": True, "data_collection": "deny", "allow_fallbacks": False},
    "aspect_ratio": "4:3",                 # landscape_4_3 -> "4:3"
}

key = cipher.new_key()
_, env_text = cipher.encrypt_bytes(jpg, key)
user = cipher.uid()
mine = cipher.uid()
others = []
for n, when in ((412_331, "2026-10-24 19:02"), (1_604_877, "2026-10-21 10:47"),
                (238_904, "2026-10-12 08:31"), (955_120, "2026-10-03 21:15")):
    _, t = cipher.encrypt_bytes(os.urandom(n), key)
    others.append({"name": cipher.uid() + ".enc", "bytes": len(t.encode()), "modified": when})

out = {
    "prompt": PROMPT,
    "request": request,
    "user_id": user,
    "object": mine + ".enc",
    "jpg_bytes": len(jpg),
    "object_bytes": len(env_text.encode()),
    "modified": "2026-10-26 09:41",
    "others": others,
}
(HERE / "cipher.json").write_text(json.dumps(out, indent=1))
print("jpg", len(jpg), "->", cipher.human_bytes(len(jpg)), "| object", out["object_bytes"], "->",
      cipher.human_bytes(out["object_bytes"]))
