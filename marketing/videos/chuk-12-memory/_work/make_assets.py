#!/usr/bin/env python3
"""Episode 12 assets: real ciphertext of the workspace row and the memory, plus icons.

1. Workspace "Tax helper": its name, description and system prompt go into ONE envelope,
   exactly like WorkspaceStorageService.sealedProjectColumns -> EncryptedMeta.encode:
   jsonEncode({"v":1,"tbl":"projects","row":<id>,"name",...,"custom_system_prompt"}), then
   EncryptionService.encryptInBackground (short strings: encrypt()) -> the envelope
   {"v":"1","kv":1,"nonce","ciphertext","mac"} (AES-256-GCM, 12-byte nonce, 16-byte mac).
   The plain columns keep the placeholder: name = kEncryptedPlaceholder ("🔒"),
   description = NULL, custom_system_prompt = NULL.
2. Memory: notes_tools.dart _saveIdentityText -> EncryptionService.encrypt(trimmed) ->
   upsert user_preferences.identity_memory. Same envelope.
   Neighbour rows (other workspaces of the user, other users' preference rows) are real
   ciphertext of plausible plaintext; only their envelopes are shown.
   Key random, thrown away: nobody can open what the video shows.
3. Icons: HugeIcons SVGs from the repo (assets/icons/hugeicons, what AppIcon draws) and,
   where icon_map.dart has no HugeIcon, the Material glyph outline from Flutter's
   MaterialIcons-Regular.otf (what AppIcon falls back to). -> gen/icons.json
4. The lock emoji subset from Noto Color Emoji (the placeholder "🔒" in the table).
Run once:  python3 _work/make_assets.py   -> _work/cipher.json, _work/gen/*
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid import cipher  # noqa: E402

GEN = HERE / "gen"
GEN.mkdir(exist_ok=True)

WS_NAME = "Tax helper"
WS_DESC = "My German tax return: receipts, deadlines, deductions."
WS_PROMPT = "Help me with my German tax return. Ask before you assume. Keep answers short."
MEMORY_OLD = "- Lives in Hamburg\n- Files taxes with ELSTER"
MEMORY_NEW = "- Self-employed since 2024"
MEMORY = MEMORY_OLD + "\n" + MEMORY_NEW


def dart_json(obj):
    """Dart jsonEncode: insertion order, no spaces, non-ASCII kept."""
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def seal_meta(key, table, row, fields):
    body = {"v": 1, "tbl": table, "row": row}
    body.update({k: v for k, v in fields.items() if v is not None})
    plain = dart_json(body)
    env, text = cipher.encrypt_bytes(plain.encode(), key)
    return env, text, plain


key = cipher.new_key()
user = cipher.uid()

ws_id = cipher.uid()
env, text, plain = seal_meta(key, "projects", ws_id, {
    "name": WS_NAME, "description": WS_DESC, "custom_system_prompt": WS_PROMPT})
workspaces = [{"id": ws_id, "envelope": env, "text": text, "plain_len": len(plain.encode()),
               "updated_at": "2026-10-26 09:41:12+00"}]
for name, desc, prompt, when in (
        ("Thesis", "Chapter drafts and sources.", "Be strict about citations.", "2026-10-21 18:07:40+00"),
        ("Kitchen plans", None, "Metric units only.", "2026-10-09 11:52:03+00")):
    rid = cipher.uid()
    e, t, p = seal_meta(key, "projects", rid, {"name": name, "description": desc, "custom_system_prompt": prompt})
    workspaces.append({"id": rid, "envelope": e, "text": t, "plain_len": len(p.encode()), "updated_at": when})

mem_env, mem_text = cipher.encrypt_bytes(MEMORY.encode(), key)
prefs = [{"user_id": user, "envelope": mem_env, "text": mem_text, "updated_at": "2026-10-26 09:42:30+00"}]
for n, when in ((140, "2026-10-25 22:14:09+00"), (58, "2026-10-24 07:31:55+00")):
    e, t = cipher.encrypt_bytes(("- " + "x" * n).encode(), cipher.new_key())
    prefs.append({"user_id": cipher.uid(), "envelope": e, "text": t, "updated_at": when})

out = {
    "user_id": user,
    "workspace": {"name": WS_NAME, "description": WS_DESC, "prompt": WS_PROMPT},
    "memory": {"old": MEMORY_OLD, "new": MEMORY_NEW, "text": MEMORY},
    "workspaces": workspaces,
    "prefs": prefs,
}
(HERE / "cipher.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
print("encrypted_meta plain", workspaces[0]["plain_len"], "B -> envelope", len(text), "chars, ct",
      len(env["ciphertext"]))
print("memory", len(MEMORY.encode()), "B -> envelope", len(mem_text), "chars, ct", len(mem_env["ciphertext"]))

# ------------------------------------------------------------------ icons
icons = {}
HUGE = REPO / "assets/icons/hugeicons"
for name in ("arrow-left02", "file01", "message01", "settings01", "settings02", "information-circle", "tick02"):
    svg = (HUGE / f"{name}.svg").read_text()
    vb = re.search(r'viewBox="([^"]+)"', svg).group(1)
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1).strip()
    inner = re.sub(r'stroke="#[0-9a-fA-F]+"', 'stroke="currentColor"', inner)
    inner = re.sub(r'fill="#[0-9a-fA-F]+"', 'fill="currentColor"', inner)
    icons[name] = {"viewBox": vb, "inner": inner, "kind": "huge"}

from fontTools.pens.svgPathPen import SVGPathPen  # noqa: E402
from fontTools.pens.transformPen import TransformPen  # noqa: E402
from fontTools.ttLib import TTFont  # noqa: E402

flutter = Path(shutil.which("flutter")).resolve().parents[1]
mi = TTFont(str(flutter / "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"))
cmap = mi.getBestCmap()
gs = mi.getGlyphSet()
upm = mi["head"].unitsPerEm
for name, cp in (("m-rocket-launch-outlined", 0xF0653), ("m-save", 0xE550),
                 ("m-open-in-full-rounded", 0xF0032), ("m-download-outlined", 0xEFF2)):
    g = cmap[cp]
    pen = SVGPathPen(gs)
    # font units, y up, baseline 0 -> a 24 x 24 box, y down (Material: em box = icon box)
    s = 24 / upm
    tp = TransformPen(pen, (s, 0, 0, -s, 0, 24 * (mi["hhea"].ascent / upm)))
    gs[g].draw(tp)
    icons[name] = {"viewBox": "0 0 24 24", "inner": f'<path d="{pen.getCommands()}" fill="currentColor"/>',
                   "kind": "material"}
(GEN / "icons.json").write_text(json.dumps(icons, indent=1))
print("icons", ", ".join(icons), "| MaterialIcons upm", upm, "ascent", mi["hhea"].ascent, "descent", mi["hhea"].descent)

# ------------------------------------------------------------------ the lock emoji
subprocess.run([sys.executable, "-m", "fontTools.subset", "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
                "--unicodes=U+1F512", f"--output-file={GEN / 'lock-emoji.ttf'}"], check=True)
print("emoji subset", (GEN / "lock-emoji.ttf").stat().st_size, "bytes")
