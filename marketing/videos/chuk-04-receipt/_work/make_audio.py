#!/usr/bin/env python3
"""Build every audio file for video 04 (The receipt).

Sources: the supplied track (assets/bgm/track.wav) and the bundled media-use
SFX library (Pixabay licence). Printer buzz and paper rip are synthesised here
(local, deterministic, seeded). No music generation, no TTS.

Timeline (video seconds):
  frame 01 hype      0.000 - 3.800
  frame 02 shorter   3.800 - 5.400
  frame 03 receipt   5.400 - 31.582
  frame 04 endcard  31.582 - 35.307

Bed: segment A = track 7.10-12.859 s (bar 1 downbeat 7.169 -> video 5.400),
segment B = track 28.092-52.349 s (grid point 28.169 -> video 11.127), joined
inside the track's own stop. The ticking stop, the short stop and the final
stab of the track then land on the receipt gags and the end card.
"""
import json
import os
import subprocess

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SFX_LIB = os.path.expanduser("~/.claude/skills/media-use/audio/assets/sfx")
SR = 44100
TOTAL = 35.307

Q = 60.0 / 110.0            # quarter note
OFF_A = 5.400 - 7.169       # video = track + OFF_A
OFF_B = 11.127 - 28.169     # video = track + OFF_B


def load(path, sr=SR):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ac", "2", "-ar", str(sr), "-f", "f32le", "-"],
        check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()


def place(buf, clip, t, gain=1.0):
    i = int(round(t * SR))
    if i < 0:
        clip = clip[-i:]
        i = 0
    n = min(len(clip), len(buf) - i)
    if n > 0:
        buf[i:i + n] += clip[:n] * gain


def fade(clip, fin=0.0, fout=0.0):
    c = clip.copy()
    n = len(c)
    if fin > 0:
        k = min(n, int(fin * SR))
        c[:k] *= np.linspace(0, 1, k)[:, None]
    if fout > 0:
        k = min(n, int(fout * SR))
        c[n - k:] *= np.linspace(1, 0, k)[:, None]
    return c


def seg(x, t0, t1):
    return x[int(round(t0 * SR)):int(round(t1 * SR))]


def write(name, buf, peak=None):
    if peak is not None:
        m = float(np.max(np.abs(buf))) or 1.0
        buf = buf * (peak / m)
    buf = np.clip(buf, -1, 1)
    path = os.path.join(ROOT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path, buf.astype(np.float32), SR, subtype="PCM_16")
    return path, len(buf) / SR


# ---------------------------------------------------------------- bed
def build_bed():
    track = load(os.path.join(ROOT, "assets/bgm/track.wav"))
    bed = np.zeros((int(TOTAL * SR) + 1, 2), dtype=np.float32)
    a = fade(seg(track, 7.10, 12.859), fin=0.005, fout=0.03)
    b = fade(seg(track, 28.092, 52.349), fin=0.025, fout=0.30)
    place(bed, a, 7.10 + OFF_A)
    place(bed, b, 28.092 + OFF_B)
    return write("assets/bgm/bed.wav", bed)


# ---------------------------------------------------------------- hype + tape stop
def tape_stop(x, t_stop, dur):
    """Read x at a playback rate that falls from 1 to 0 over dur seconds."""
    n_out = int(dur * SR)
    tau = np.arange(n_out) / SR
    rate = (1.0 - tau / dur) ** 1.6
    pos = t_stop * SR + np.cumsum(rate)
    idx = np.clip(pos, 0, len(x) - 2)
    i0 = np.floor(idx).astype(int)
    frac = (idx - i0)[:, None]
    y = x[i0] * (1 - frac) + x[i0 + 1] * frac
    env = np.clip((1.0 - tau / dur) * 1.4, 0, 1)[:, None]
    return y * env


def build_hype():
    length = 6.0
    mix = np.zeros((int(length * SR), 2), dtype=np.float32)
    whoosh = load(os.path.join(SFX_LIB, "whoosh-cinematic.mp3"))
    impact = load(os.path.join(SFX_LIB, "impact-bass-1.mp3"))
    boom = load(os.path.join(SFX_LIB, "impact-bass-2.mp3"))
    riser = load(os.path.join(SFX_LIB, "riser.mp3"))
    sparkle = load(os.path.join(SFX_LIB, "sparkle.mp3"))
    place(mix, whoosh[int(2.0 * SR):], 0.0, 0.9)        # whoosh peak lands ~0.5 s
    place(mix, impact, 0.07, 0.9)                        # "THE MOST POWERFUL" slam
    place(mix, impact, 0.50, 1.0)                        # "AI EVER" slam
    place(mix, boom, 0.50, 0.2)                          # sub rumble under the slams
    place(mix, riser, 0.35, 2.2)                         # riser crests at ~3.35 s, into the stop
    place(mix, sparkle, 1.00, 0.55)                      # lens flare shimmer
    t_stop, d_stop = 3.40, 0.45
    out = np.zeros((int(3.9 * SR), 2), dtype=np.float32)
    head = mix[:int(t_stop * SR)]
    out[:len(head)] = head
    ts = tape_stop(mix, t_stop, d_stop)
    out[len(head):len(head) + len(ts)] = ts
    out = fade(out, fout=0.02)
    return write("assets/sfx/hype.wav", out, peak=0.89)


# ---------------------------------------------------------------- key clicks (frame 02)
def build_keys():
    key = load(os.path.join(SFX_LIB, "key-press.mp3"))
    text = "Ours is shorter."
    out = np.zeros((int(1.2 * SR), 2), dtype=np.float32)
    t = 0.15
    rng = np.random.default_rng(4)
    for ch in text:
        g = 0.6 + 0.4 * rng.random()
        if ch != " ":
            place(out, key, t, g)
        t += 0.028
    return write("assets/sfx/keys.wav", out, peak=0.5)


# ---------------------------------------------------------------- printer (frame 03)
BP = butter(2, [350, 5200], btype="bandpass", fs=SR, output="sos")
HP = butter(2, 900, btype="highpass", fs=SR, output="sos")


def buzz(dur, f0=1180.0, seed=0):
    """Thermal printer stepper buzz."""
    rng = np.random.default_rng(seed)
    n = int(dur * SR)
    t = np.arange(n) / SR
    wob = 1.0 + 0.012 * np.sin(2 * np.pi * 7 * t)
    ph = 2 * np.pi * np.cumsum(f0 * wob) / SR
    tone = 0.55 * np.sign(np.sin(ph)) * 0.35 + 0.35 * np.sin(2 * ph) + 0.2 * np.sin(3.02 * ph)
    rattle = 0.65 + 0.35 * (np.sin(2 * np.pi * 96 * t) > 0)
    noise = rng.standard_normal(n) * 0.25
    sig = (tone * rattle + noise)
    env = np.minimum(1, t / 0.006) * np.minimum(1, (dur - t) / 0.02)
    sig = sosfilt(BP, sig * env)
    clack = np.zeros(n)
    k = min(n, int(0.008 * SR))
    clack[:k] = rng.standard_normal(k) * np.linspace(1, 0, k) * 0.9
    sig = sig + sosfilt(HP, clack)
    return np.stack([sig, sig * 0.96], axis=1).astype(np.float32)


def tick(seed=0, amp=1.0):
    rng = np.random.default_rng(100 + seed)
    n = int(0.03 * SR)
    t = np.arange(n) / SR
    s = rng.standard_normal(n) * np.exp(-t / 0.004) + 0.6 * np.sin(2 * np.pi * 2600 * t) * np.exp(-t / 0.006)
    s = sosfilt(HP, s) * amp
    return np.stack([s, s], axis=1).astype(np.float32)


def stamp(seed=0):
    b = buzz(0.07, f0=760.0, seed=200 + seed) * 1.3
    t = tick(seed, 1.4)
    out = np.zeros((max(len(b), len(t)), 2), dtype=np.float32)
    out[:len(b)] += b
    out[:len(t)] += t
    return out


def build_printer(events):
    out = np.zeros((int(26.3 * SR), 2), dtype=np.float32)
    for i, (kind, t, d) in enumerate(events):
        if kind == "feed":
            place(out, buzz(d, seed=i), t, 1.0)
        elif kind == "dot":
            place(out, tick(i, 0.7), t, 1.0)
        elif kind == "stamp":
            place(out, stamp(i), t, 1.0)
    return write("assets/sfx/printer.wav", out, peak=0.7)


def build_rip():
    rng = np.random.default_rng(7)
    dur = 0.55
    n = int(dur * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    # crackle: dense random impulses, faster in the middle of the pull
    dens = 0.08 + 0.5 * np.exp(-((t - 0.16) / 0.09) ** 2)
    crack = (rng.random(n) < dens * 0.2).astype(float) * rng.standard_normal(n) * 3.0
    body = noise * 0.5 + crack
    env = np.clip(t / 0.02, 0, 1) * np.exp(-np.clip(t - 0.12, 0, None) / 0.13)
    s = sosfilt(butter(2, [700, 7000], btype="bandpass", fs=SR, output="sos"), body * env)
    st = np.stack([s, np.roll(s, 40) * 0.95], axis=1).astype(np.float32)
    return write("assets/sfx/rip.wav", st, peak=0.8)


def printer_events():
    """Receipt frame local times, kept in lockstep with 03-receipt.html (TIMES)."""
    with open(os.path.join(ROOT, "_work/receipt_times.json")) as f:
        return json.load(f)["audio"]


if __name__ == "__main__":
    for fn in (build_bed, build_hype, build_keys, build_rip):
        print(fn.__name__, fn())
    print("build_printer", build_printer(printer_events()))
