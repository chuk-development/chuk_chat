#!/usr/bin/env python3
"""Live VNC CONNECT-LATENCY probe (cowork-c0zd) — where the wait before the
first picture goes.

The throughput probe next to this file (``live_vnc_speed_probe.py``) answers
"how fast do frames flow once the view runs". This one answers the other half
the user complained about: "it loads forever". It walks the EXACT executor
start path and stamps every step:

  1. ``docker exec <box> true``          — reach the box at all
  2. ``agents-vnc-up``                   — x11vnc up (warm: reused; cold: started)
  3. window probe (``xwininfo``)         — how many pages are on the display
  4. ``docker exec -i socat``            — the byte pipe the bridge uses
  5. RFB handshake (version/auth/init)   — with the per-view VNC secret
  6. SetPixelFormat + SetEncodings
  7. first FULL FramebufferUpdate        — the first picture the user sees

With ``--cold`` it kills x11vnc first, so the cold start (the case a fresh view
hits) is measured instead of the warm reuse.

Usage:
    python3 live_vnc_connect_probe.py <container-id> [--cold] [--repeat N]
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from live_vnc_speed_probe import (  # noqa: E402
    ENC_COPYRECT,
    ENC_RAW,
    ENC_TIGHT,
    _read_exact,
    _read_one_update,
    _set_pixel_format_bgra8888,
)

WINDOW_COUNT_SH = (
    'DISPLAY=${AGENTS_BROWSER_DISPLAY:-:99} xwininfo -root -children '
    "2>/dev/null | grep -Eci '\\(\"[^\"]*[Cc]hrom'; exit 0"
)


def _des_encrypt_block(key: bytes, block: bytes) -> bytes:
    """VNC auth DES: the key bytes are bit-REVERSED per byte, then plain DES-ECB.

    Implemented here (not via a crypto dependency) so the probe runs on a bare
    interpreter, the same reason the rest of this file speaks RFB by hand.
    """
    # Standard DES tables.
    PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,
           60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,
           37,29,21,13,5,28,20,12,4]
    PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,
           52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32]
    IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,
          64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,
          61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
    FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,
          37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,
          34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25]
    E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,
         19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1]
    P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,
         13,30,6,22,11,4,25]
    SHIFTS = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
    S = [
     [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,
      3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,
      0,6,13],
     [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,
      11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,
      0,5,14,9],
     [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,
      15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,
      11,5,2,12],
     [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,
      14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,
      12,7,2,14],
     [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,
      8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,
      10,4,5,3],
     [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,
      3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,
      6,0,8,13],
     [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,
      8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,
      14,2,3,12],
     [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,
      9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,
      3,5,6,11],
    ]

    def bits(data: bytes) -> list[int]:
        return [(b >> (7 - i)) & 1 for b in data for i in range(8)]

    def unbits(bl: list[int]) -> bytes:
        return bytes(
            sum(bl[i + j] << (7 - j) for j in range(8)) for i in range(0, len(bl), 8)
        )

    def permute(block: list[int], table: list[int]) -> list[int]:
        return [block[i - 1] for i in table]

    kb = permute(bits(key), PC1)
    c, d = kb[:28], kb[28:]
    subkeys = []
    for shift in SHIFTS:
        c = c[shift:] + c[:shift]
        d = d[shift:] + d[:shift]
        subkeys.append(permute(c + d, PC2))
    b = permute(bits(block), IP)
    left, right = b[:32], b[32:]
    for k in subkeys:
        expanded = permute(right, E)
        x = [expanded[i] ^ k[i] for i in range(48)]
        out: list[int] = []
        for i in range(8):
            six = x[i * 6:i * 6 + 6]
            row = (six[0] << 1) | six[5]
            col = (six[1] << 3) | (six[2] << 2) | (six[3] << 1) | six[4]
            val = S[i][row * 16 + col]
            out += [(val >> (3 - j)) & 1 for j in range(4)]
        f = permute(out, P)
        left, right = right, [left[i] ^ f[i] for i in range(32)]
    return unbits(permute(right + left, FP))


def _vnc_auth_response(password: str, challenge: bytes) -> bytes:
    key = password.encode()[:8].ljust(8, b"\0")
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in key)
    return _des_encrypt_block(key, challenge[:8]) + _des_encrypt_block(
        key, challenge[8:16]
    )


def _handshake_timed(proc, password: str | None) -> tuple[int, int, dict]:
    """RFB 3.8 handshake, stamping each leg. Returns (w, h, marks)."""
    stdin, stdout = proc.stdin, proc.stdout
    marks: dict[str, float] = {}
    t0 = time.perf_counter()
    server_version = _read_exact(stdout, 12)
    marks["server_version"] = time.perf_counter() - t0
    if not server_version.startswith(b"RFB "):
        raise RuntimeError(f"not an RFB server: {server_version!r}")
    stdin.write(b"RFB 003.008\n")
    stdin.flush()
    num_types = _read_exact(stdout, 1)[0]
    if num_types == 0:
        reason_len = struct.unpack(">I", _read_exact(stdout, 4))[0]
        raise RuntimeError(f"server refused: {_read_exact(stdout, reason_len)!r}")
    types = list(_read_exact(stdout, num_types))
    marks["security_types"] = time.perf_counter() - t0
    if password is not None and 2 in types:
        stdin.write(bytes([2]))
        stdin.flush()
        challenge = _read_exact(stdout, 16)
        stdin.write(_vnc_auth_response(password, challenge))
        stdin.flush()
    elif 1 in types:
        stdin.write(bytes([1]))
        stdin.flush()
    else:
        raise RuntimeError(f"no usable security type: {types}")
    if struct.unpack(">I", _read_exact(stdout, 4))[0] != 0:
        raise RuntimeError("security handshake failed (wrong password?)")
    marks["auth"] = time.perf_counter() - t0
    stdin.write(bytes([1]))  # ClientInit shared=1
    stdin.flush()
    server_init = _read_exact(stdout, 24)
    width, height = struct.unpack(">HH", server_init[:4])
    name_len = struct.unpack(">I", server_init[20:24])[0]
    _read_exact(stdout, name_len)
    marks["server_init"] = time.perf_counter() - t0
    return width, height, marks


def _set_encodings(proc, *, cursor: bool) -> None:
    encodings = [ENC_TIGHT, ENC_COPYRECT, ENC_RAW, -32 + 6]
    if cursor:
        encodings += [-239, -232]  # cursor pseudo-encoding, cursor position
    msg = struct.pack(">BxH", 2, len(encodings))
    for enc in encodings:
        msg += struct.pack(">i", enc)
    proc.stdin.write(msg)
    proc.stdin.flush()


def _run(label: str, argv: list[str], out: list) -> subprocess.CompletedProcess:
    t = time.perf_counter()
    proc = subprocess.run(argv, capture_output=True)
    out.append((label, time.perf_counter() - t, proc.returncode))
    return proc


def probe(
    container: str,
    *,
    password: str,
    port: int = 5900,
    cold: bool = False,
    cursor: bool = False,
) -> dict:
    steps: list[tuple[str, float, int]] = []
    if cold:
        _run(
            "kill x11vnc (cold)",
            ["docker", "exec", "-u", "root", container, "pkill", "-f", "x11vnc"],
            steps,
        )
        time.sleep(0.5)
    t_start = time.perf_counter()
    _run("docker exec true", ["docker", "exec", container, "true"], steps)
    up = _run(
        "agents-vnc-up",
        [
            "docker", "exec", "-i", "-u", "root",
            "-e", f"AGENTS_VNC_PASSWD={password}",
            container, "agents-vnc-up",
        ],
        steps,
    )
    if up.returncode != 0:
        raise RuntimeError(f"agents-vnc-up failed rc={up.returncode}: {up.stderr!r}")
    _run(
        "window probe (xwininfo)",
        ["docker", "exec", container, "sh", "-lc", WINDOW_COUNT_SH],
        steps,
    )
    t_socat = time.perf_counter()
    proc = subprocess.Popen(
        [
            "docker", "exec", "-i", container,
            "socat", "STDIO", f"TCP:127.0.0.1:{port}",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    try:
        width, height, marks = _handshake_timed(proc, password)
        steps.append(("socat + RFB handshake", time.perf_counter() - t_socat, 0))
        t_fmt = time.perf_counter()
        _set_pixel_format_bgra8888(proc)
        _set_encodings(proc, cursor=cursor)
        proc.stdin.write(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
        proc.stdin.flush()
        first_bytes, rects = _read_one_update(proc)
        steps.append(("first FULL frame", time.perf_counter() - t_fmt, 0))
        total = time.perf_counter() - t_start
        return {
            "steps": steps,
            "marks": marks,
            "width": width,
            "height": height,
            "first_bytes": first_bytes,
            "first_rects": rects,
            "total": total,
            "windows": (up.stdout or b"").decode(errors="replace").strip(),
        }
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("container")
    parser.add_argument("--password", default="probe123")
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--cold", action="store_true", help="kill x11vnc first")
    parser.add_argument("--cursor", action="store_true",
                        help="also ask for the cursor pseudo-encodings")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    for run in range(args.repeat):
        result = probe(
            args.container,
            password=args.password,
            port=args.port,
            cold=args.cold,
            cursor=args.cursor,
        )
        print(f"--- run {run + 1} ({'cold' if args.cold else 'warm'}) "
              f"{result['width']}x{result['height']} {result['windows']}")
        for label, dt, rc in result["steps"]:
            print(f"  {label:30s} {dt * 1000:8.1f} ms" + ("" if rc == 0 else f" rc={rc}"))
        for label, dt in result["marks"].items():
            print(f"    handshake/{label:20s} {dt * 1000:8.1f} ms (cumulative)")
        print(f"  {'TOTAL to first picture':30s} {result['total'] * 1000:8.1f} ms  "
              f"({result['first_bytes']} B, {result['first_rects']} rects)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
