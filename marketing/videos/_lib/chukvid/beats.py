"""Beat grid helpers.

The beat file comes from the CLI: `npx hyperframes beats <project>` writes
beats/assets/audio/music.wav.json. Episodes pick their cuts with snap()/cuts().
"""
import json
import subprocess
from pathlib import Path

from .core import HF_VERSION


def ensure(project_dir):
    """Run `hyperframes beats` once for the project and return the beat list."""
    f = Path(project_dir) / "beats/assets/audio/music.wav.json"
    if not f.exists():
        subprocess.run(["npx", "--yes", f"hyperframes@{HF_VERSION}", "beats", str(project_dir)], check=True)
    return load(f)


def load(path):
    data = json.loads(Path(path).read_text())
    return [(b["time"], b.get("strength", 0.0)) for b in data["beats"]]


def snap(t, beats, strong=0.0):
    """Nearest beat time to t (only beats with strength >= strong)."""
    cand = [b for b, s in beats if s >= strong] or [b for b, _ in beats]
    return min(cand, key=lambda b: abs(b - t))


def cuts(targets, beats, duration, strong=0.0):
    """[0, snap(t1), snap(t2), ..., duration] for rough cut targets in seconds."""
    out = [0.0]
    for t in targets:
        out.append(round(snap(t, beats, strong), 3))
    out.append(float(duration))
    assert all(a < b for a, b in zip(out, out[1:])), out
    return out


def tempo(beats):
    """Median beat interval in seconds."""
    ts = [b for b, _ in beats]
    d = sorted(b - a for a, b in zip(ts, ts[1:]))
    return d[len(d) // 2] if d else 0.5
