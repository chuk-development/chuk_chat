#!/usr/bin/env python3
"""Episode 09 assets: the fake lab report photo and the real ciphertext of it.

1. _work/lab_report.html (clearly fictional, no real person) -> _work/gen/lab-report.jpg
   (rendered 1500x2000, stored 1440x1920 like ImageCompressionService, like a phone photo of a printout).
2. Those exact JPEG bytes -> EncryptionService.encryptBytes envelope (AES-256-GCM, v "1",
   random key thrown away). That JSON is what Storage holds at images/<uid>/<uuid>.enc.
3. Neighbour objects of the same user: real ciphertext of random bytes, only their names
   and sizes are shown.
Run once:  python3 _work/make_assets.py   -> _work/gen/lab-report.jpg, _work/cipher.json
"""
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid import cipher  # noqa: E402
from chukvid.core import launch_chrome  # noqa: E402
from playwright.sync_api import sync_playwright  # noqa: E402

GEN = HERE / "gen"
GEN.mkdir(exist_ok=True)

with sync_playwright() as p:
    b = launch_chrome(p)
    pg = b.new_page(viewport={"width": 1500, "height": 2000})
    pg.goto((HERE / "lab_report.html").as_uri())
    pg.wait_for_timeout(300)
    pg.screenshot(path=str(GEN / "lab-report.png"))
    b.close()
# ImageCompressionService caps uploads at 1920 px: store what the app would store
from PIL import Image  # noqa: E402
Image.open(GEN / "lab-report.png").convert("RGB").resize((1440, 1920), Image.LANCZOS).save(
    GEN / "lab-report.jpg", quality=86)
(GEN / "lab-report.png").unlink()

jpg = (GEN / "lab-report.jpg").read_bytes()
key = cipher.new_key()
env, env_text = cipher.encrypt_bytes(jpg, key)
obj_bytes = len(env_text.encode())

user = cipher.uid()
mine = cipher.uid()
others = []
for n, suffix, when in ((412_331, ".enc", "2026-10-24 19:02"), (1_204_877, ".file.enc", "2026-10-19 10:47"),
                        (238_904, ".enc", "2026-10-12 08:31"), (655_120, ".enc", "2026-10-03 21:15")):
    _, t = cipher.encrypt_bytes(os.urandom(n), key)
    others.append({"name": cipher.uid() + suffix, "bytes": len(t.encode()), "modified": when})

out = {
    "user_id": user,
    "object": mine + ".enc",
    "jpg_bytes": len(jpg),
    "object_bytes": obj_bytes,
    "modified": "2026-10-26 09:41",
    "envelope": env,
    "others": others,
}
(HERE / "cipher.json").write_text(json.dumps(out, indent=1))
print("jpg", len(jpg), "bytes ->", cipher.human_bytes(len(jpg)), "| object", obj_bytes, "bytes ->",
      cipher.human_bytes(obj_bytes), "| ct chars", len(env["ciphertext"]))
