#!/usr/bin/env python3
"""Mix assets/sfx/keys.wav from tools/keystrokes.json (deterministic)."""
import json, subprocess, wave, os
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SR = 44100
SRC = os.path.expanduser("~/.claude/skills/media-use/audio/assets/sfx/key-press.mp3")

def load(path):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()

key = load(SRC)
data = json.load(open(os.path.join(ROOT, "tools/keystrokes.json")))
total = data["total"]
out = np.zeros(int(total * SR) + SR, dtype=np.float32)
rng = np.random.default_rng(3202609)

def place(t, gain, rate):
    n = int(len(key) / rate)
    x = np.interp(np.arange(n) * rate, np.arange(len(key)), key).astype(np.float32)
    i = int(round(t * SR))
    j = min(len(out), i + n)
    out[i:j] += x[: j - i] * gain

for h in data["hits"]:
    k = h["kind"]
    if k == "send":
        place(h["t"], 1.0, 0.82)          # the big Enter key
    elif h["space"]:
        place(h["t"], 0.85, 0.9)          # space bar: deeper
    elif k in ("sel", "del"):
        place(h["t"], 0.8, 0.96)
    elif k == "bs":
        place(h["t"], rng.uniform(0.6, 0.8), rng.uniform(1.0, 1.06))
    else:
        place(h["t"], rng.uniform(0.55, 0.85), rng.uniform(0.94, 1.07))

out = out[: int(total * SR)]
peak = float(np.max(np.abs(out)))
if peak > 0.98:
    out *= 0.98 / peak
pcm = (np.clip(out, -1, 1) * 32767).astype(np.int16)
stereo = np.repeat(pcm[:, None], 2, axis=1)
os.makedirs(os.path.join(ROOT, "assets/sfx"), exist_ok=True)
with wave.open(os.path.join(ROOT, "assets/sfx/keys.wav"), "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(stereo.tobytes())
print(f"keys.wav: {len(data['hits'])} hits, peak {peak:.3f}")
