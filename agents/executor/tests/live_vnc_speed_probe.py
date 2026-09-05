#!/usr/bin/env python3
"""Live VNC throughput probe (§9.1) — measures the real cost of the browser view.

Speaks minimal RFB 3.8 to the agent's x11vnc through the EXACT executor path
(`docker exec -i <cid> socat STDIO TCP:127.0.0.1:5900`), negotiating the pixel
format flutter_rfb uses (bgra8888, 4 bytes/pixel) and a chosen ENCODING. It
measures a full framebuffer refresh and a burst of incremental updates and
reports bytes, transfer time, achievable FPS, and the base64 + JSON overhead the
sealed channel adds (the app never sees raw RFB — every chunk is base64'd into a
JSON frame).

Why encodings matter: the pure-Dart client (dart_rfb) originally decoded only
`raw` + `copyRect`, so x11vnc sent UNCOMPRESSED pixels: a full 1280x800 frame
was 4.1 MB. x11vnc also speaks zlib, ZRLE and Tight (with JPEG) — the same
encodings noVNC decodes — and on browser content those are 10-100x smaller.
This probe measures each one on the REAL current screen content so we pick a
decoder on numbers, not hope.

Usage:
    python3 live_vnc_speed_probe.py <container-id>                # all encodings
    python3 live_vnc_speed_probe.py <container-id> --encoding zrle
    python3 live_vnc_speed_probe.py <container-id> --encoding tight --quality 6
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import time

# RFB encoding numbers (RFC 6143 + TightVNC extensions).
ENC_RAW = 0
ENC_COPYRECT = 1
ENC_HEXTILE = 5
ENC_ZLIB = 6
ENC_TIGHT = 7
ENC_ZRLE = 16

ENCODINGS = {
    "raw": ENC_RAW,
    "hextile": ENC_HEXTILE,
    "zlib": ENC_ZLIB,
    "zrle": ENC_ZRLE,
    "tight": ENC_TIGHT,
}

BYTES_PER_PIXEL = 4  # bgra8888, what flutter_rfb forces
TPIXEL_BYTES = 3  # Tight packs 24-bit true colour into 3 bytes


def _read_exact(pipe, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = pipe.read(n - len(buf))
        if not chunk:
            raise EOFError(f"pipe closed after {len(buf)}/{n} bytes")
        buf.extend(chunk)
    return bytes(buf)


def _handshake(proc) -> tuple[int, int]:
    """RFB 3.8 handshake with security=None. Returns (width, height)."""
    stdin, stdout = proc.stdin, proc.stdout
    server_version = _read_exact(stdout, 12)
    if not server_version.startswith(b"RFB "):
        raise RuntimeError(f"not an RFB server: {server_version!r}")
    stdin.write(b"RFB 003.008\n")
    stdin.flush()
    num_types = _read_exact(stdout, 1)[0]
    if num_types == 0:
        reason_len = struct.unpack(">I", _read_exact(stdout, 4))[0]
        raise RuntimeError(f"server refused: {_read_exact(stdout, reason_len)!r}")
    types = _read_exact(stdout, num_types)
    if 1 not in types:
        raise RuntimeError(f"no None security type offered: {list(types)}")
    stdin.write(bytes([1]))
    stdin.flush()
    if struct.unpack(">I", _read_exact(stdout, 4))[0] != 0:
        raise RuntimeError("security handshake failed")
    stdin.write(bytes([1]))  # ClientInit shared=1
    stdin.flush()
    server_init = _read_exact(stdout, 24)
    width, height = struct.unpack(">HH", server_init[:4])
    name_len = struct.unpack(">I", server_init[20:24])[0]
    _read_exact(stdout, name_len)
    return width, height


def _set_pixel_format_bgra8888(proc) -> None:
    pixel_format = struct.pack(
        ">BBBB HHH BBB xxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0
    )
    proc.stdin.write(b"\x00\x00\x00\x00" + pixel_format)
    proc.stdin.flush()


def _set_encodings(proc, encoding: int, quality: int | None) -> None:
    """Advertise the chosen encoding first, copyRect, raw as the fallback, plus
    the Tight quality pseudo-encoding (-32..-23 = JPEG quality 0..9)."""
    encodings = [encoding, ENC_COPYRECT, ENC_RAW]
    if encoding == ENC_TIGHT and quality is not None and quality >= 0:
        encodings.append(-32 + min(9, quality))
    msg = struct.pack(">BxH", 2, len(encodings))
    for enc in encodings:
        msg += struct.pack(">i", enc)
    proc.stdin.write(msg)
    proc.stdin.flush()


def _request_update(proc, width: int, height: int, *, incremental: bool) -> None:
    proc.stdin.write(
        struct.pack(">BBHHHH", 3, 1 if incremental else 0, 0, 0, width, height)
    )
    proc.stdin.flush()


def _read_compact_len(stdout) -> tuple[int, int]:
    """Tight's 1-3 byte compact length. Returns (value, bytes_consumed)."""
    b0 = _read_exact(stdout, 1)[0]
    value = b0 & 0x7F
    used = 1
    if b0 & 0x80:
        b1 = _read_exact(stdout, 1)[0]
        value |= (b1 & 0x7F) << 7
        used = 2
        if b1 & 0x80:
            b2 = _read_exact(stdout, 1)[0]
            value |= b2 << 14
            used = 3
    return value, used


def _consume_tight_rect(stdout, w: int, h: int) -> int:
    """Consume one Tight-encoded rectangle body; return bytes consumed."""
    control = _read_exact(stdout, 1)[0]
    consumed = 1
    ctype = control >> 4
    if ctype == 8:  # fill: one TPIXEL
        _read_exact(stdout, TPIXEL_BYTES)
        return consumed + TPIXEL_BYTES
    if ctype == 9:  # jpeg
        n, used = _read_compact_len(stdout)
        _read_exact(stdout, n)
        return consumed + used + n
    # basic compression: bits 4-5 stream id, bit 6 = explicit filter follows
    filter_id = 0
    if control & 0x40:
        filter_id = _read_exact(stdout, 1)[0]
        consumed += 1
    if filter_id == 1:  # palette
        num_colors = _read_exact(stdout, 1)[0] + 1
        consumed += 1
        _read_exact(stdout, num_colors * TPIXEL_BYTES)
        consumed += num_colors * TPIXEL_BYTES
        row_bytes = (w + 7) // 8 if num_colors <= 2 else w
        raw_size = row_bytes * h
    else:  # copy (0) or gradient (2): full TPIXEL rows
        raw_size = w * h * TPIXEL_BYTES
    if raw_size < 12:
        _read_exact(stdout, raw_size)
        return consumed + raw_size
    n, used = _read_compact_len(stdout)
    _read_exact(stdout, n)
    return consumed + used + n


def _consume_hextile_rect(stdout, w: int, h: int) -> int:
    """Consume one Hextile rectangle (16x16 tiles); return bytes consumed."""
    consumed = 0
    for ty in range(0, h, 16):
        th = min(16, h - ty)
        for tx in range(0, w, 16):
            tw = min(16, w - tx)
            sub = _read_exact(stdout, 1)[0]
            consumed += 1
            if sub & 1:  # raw tile
                n = tw * th * BYTES_PER_PIXEL
                _read_exact(stdout, n)
                consumed += n
                continue
            if sub & 2:  # background specified
                _read_exact(stdout, BYTES_PER_PIXEL)
                consumed += BYTES_PER_PIXEL
            if sub & 4:  # foreground specified
                _read_exact(stdout, BYTES_PER_PIXEL)
                consumed += BYTES_PER_PIXEL
            if sub & 8:  # any subrects
                count = _read_exact(stdout, 1)[0]
                consumed += 1
                per = (BYTES_PER_PIXEL if sub & 16 else 0) + 2
                _read_exact(stdout, count * per)
                consumed += count * per
    return consumed


class _Recorder:
    """Wraps the pipe so every byte read is also captured (for --dump)."""

    def __init__(self, pipe) -> None:
        self._pipe = pipe
        self.buf = bytearray()

    def read(self, n: int) -> bytes:
        chunk = self._pipe.read(n)
        if chunk:
            self.buf.extend(chunk)
        return chunk


def _read_one_update(proc, rects_out: list | None = None) -> tuple[int, int]:
    """Read one FramebufferUpdate. Returns (bytes_consumed, num_rects).

    With ``rects_out`` given, every rectangle is appended as a dict
    {x, y, w, h, encoding, body} where body is the exact encoded bytes that
    followed the 12-byte rect header — a real server-produced test vector."""
    stdout = proc.stdout if rects_out is None else _Recorder(proc.stdout)
    header = _read_exact(stdout, 4)
    consumed = 4
    msg_type = header[0]
    if msg_type != 0:
        if msg_type == 3:  # ServerCutText — should never happen now, drain anyway
            body = _read_exact(stdout, 7)
            text_len = struct.unpack(">I", body[3:7])[0]
            _read_exact(stdout, text_len)
            return 8 + text_len, 0
        return consumed, 0
    num_rects = struct.unpack(">H", header[2:4])[0]
    for _ in range(num_rects):
        rect = _read_exact(stdout, 12)
        consumed += 12
        x, y, w, h, encoding = struct.unpack(">HHHHi", rect)
        body_start = len(stdout.buf) if rects_out is not None else 0
        if encoding == ENC_RAW:
            n = w * h * BYTES_PER_PIXEL
            _read_exact(stdout, n)
            consumed += n
        elif encoding == ENC_COPYRECT:
            _read_exact(stdout, 4)
            consumed += 4
        elif encoding in (ENC_ZLIB, ENC_ZRLE):
            n = struct.unpack(">I", _read_exact(stdout, 4))[0]
            _read_exact(stdout, n)
            consumed += 4 + n
        elif encoding == ENC_TIGHT:
            consumed += _consume_tight_rect(stdout, w, h)
        elif encoding == ENC_HEXTILE:
            consumed += _consume_hextile_rect(stdout, w, h)
        else:
            raise RuntimeError(f"unexpected encoding {encoding}")
        if rects_out is not None:
            rects_out.append({
                "x": x, "y": y, "w": w, "h": h, "encoding": encoding,
                "body": bytes(stdout.buf[body_start:]),
            })
    return consumed, num_rects


def _capture_region(
    container: str, *, port: int, user: str, encoding_name: str,
    quality: int | None, region: tuple[int, int, int, int],
) -> list[dict]:
    """One fresh connection; one non-incremental update of ``region``; return
    the recorded rectangles. Fresh connection = fresh Tight zlib streams, so
    the vector decodes standalone."""
    argv = [
        "docker", "exec", "-i", "-u", user, container,
        "socat", "STDIO", f"TCP:127.0.0.1:{port}",
    ]
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        _handshake(proc)
        _set_pixel_format_bgra8888(proc)
        _set_encodings(proc, ENCODINGS[encoding_name], quality)
        rx, ry, rw, rh = region
        proc.stdin.write(struct.pack(">BBHHHH", 3, 0, rx, ry, rw, rh))
        proc.stdin.flush()
        rects: list[dict] = []
        _read_one_update(proc, rects)
        return rects
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


def _raw_region_pixels(rects: list[dict], region: tuple[int, int, int, int]) -> bytes:
    """Assemble raw rects into one bgra8888 buffer covering ``region``."""
    rx, ry, rw, rh = region
    out = bytearray(rw * rh * BYTES_PER_PIXEL)
    for r in rects:
        if r["encoding"] != ENC_RAW:
            raise RuntimeError(f"raw capture got encoding {r['encoding']}")
        body = r["body"]
        for row in range(r["h"]):
            src = row * r["w"] * BYTES_PER_PIXEL
            dst = ((r["y"] - ry + row) * rw + (r["x"] - rx)) * BYTES_PER_PIXEL
            out[dst:dst + r["w"] * BYTES_PER_PIXEL] = body[src:src + r["w"] * BYTES_PER_PIXEL]
    return bytes(out)


def dump_vectors(
    container: str, *, port: int, user: str, quality: int,
    region: tuple[int, int, int, int], out_dir: str, name: str, tries: int = 5,
) -> int:
    """Capture raw -> tight -> raw for one screen region and write a test vector.

    Only accepted when both raw captures are byte-identical (the screen held
    still across all three connections), so the Tight bytes provably encode
    exactly the raw pixels saved next to them."""
    import base64
    import json
    import os

    os.makedirs(out_dir, exist_ok=True)
    for attempt in range(1, tries + 1):
        raw1 = _raw_region_pixels(
            _capture_region(container, port=port, user=user, encoding_name="raw",
                            quality=None, region=region), region)
        tight = _capture_region(container, port=port, user=user, encoding_name="tight",
                                quality=quality, region=region)
        raw2 = _raw_region_pixels(
            _capture_region(container, port=port, user=user, encoding_name="raw",
                            quality=None, region=region), region)
        if raw1 != raw2:
            print(f"attempt {attempt}: screen changed between captures, retrying")
            continue
        encs = sorted({r["encoding"] for r in tight})
        if encs != [ENC_TIGHT] and encs != [ENC_COPYRECT, ENC_TIGHT]:
            print(f"attempt {attempt}: tight capture used encodings {encs}, retrying")
            continue
        rx, ry, rw, rh = region
        raw_path = os.path.join(out_dir, f"{name}.raw.bgra")
        with open(raw_path, "wb") as f:
            f.write(raw1)
        subtypes = sorted({r["body"][0] >> 4 for r in tight if r["encoding"] == ENC_TIGHT})
        meta = {
            "region": {"x": rx, "y": ry, "w": rw, "h": rh},
            "pixel_format": "bgra8888",
            "tight_quality": quality,
            "raw_file": os.path.basename(raw_path),
            "rects": [
                {"x": r["x"], "y": r["y"], "w": r["w"], "h": r["h"],
                 "encoding": r["encoding"],
                 "body_b64": base64.b64encode(r["body"]).decode()}
                for r in tight
            ],
        }
        json_path = os.path.join(out_dir, f"{name}.tight.json")
        with open(json_path, "w") as f:
            json.dump(meta, f)
        tight_bytes = sum(len(r["body"]) + 12 for r in tight)
        print(f"wrote {json_path} ({len(tight)} rects, {tight_bytes} B tight; "
              f"tight sub-encodings {subtypes}) and {raw_path} ({len(raw1)} B raw)")
        return 0
    print("giving up: screen never held still / tight not negotiated")
    return 1


def measure(
    container: str, *, port: int, user: str, encoding_name: str,
    quality: int | None, seconds: float,
) -> dict:
    argv = [
        "docker", "exec", "-i", "-u", user, container,
        "socat", "STDIO", f"TCP:127.0.0.1:{port}",
    ]
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        width, height = _handshake(proc)
        _set_pixel_format_bgra8888(proc)
        _set_encodings(proc, ENCODINGS[encoding_name], quality)

        t0 = time.monotonic()
        _request_update(proc, width, height, incremental=False)
        full_bytes, full_rects = _read_one_update(proc)
        full_dt = time.monotonic() - t0

        frames = 0
        total = 0
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            _request_update(proc, width, height, incremental=True)
            got, _ = _read_one_update(proc)
            frames += 1
            total += got
        return {
            "encoding": encoding_name,
            "width": width,
            "height": height,
            "full_bytes": full_bytes,
            "full_rects": full_rects,
            "full_dt": full_dt,
            "inc_frames": frames,
            "inc_bytes": total,
            "seconds": seconds,
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


def _report(r: dict, raw_full: int | None) -> None:
    fb = r["full_bytes"]
    dt = r["full_dt"]
    b64 = fb * 4 / 3
    ratio = f"  ({raw_full / fb:.1f}x smaller than raw)" if raw_full and fb else ""
    print(f"== {r['encoding']} ==")
    print(f"  full refresh:    {fb/1e6:.3f} MB in {dt*1000:.0f} ms "
          f"= {fb/1e6/dt:.1f} MB/s, max {1/dt:.1f} FPS{ratio}")
    print(f"  rects in frame:  {r['full_rects']}")
    print(f"  sealed channel:  {b64/1e6:.3f} MB base64 -> "
          f"{int(b64 // (64*1024)) + 1} x 64KiB JSON frames")
    inc = r["inc_bytes"]
    n = r["inc_frames"]
    print(f"  incremental:     {n} updates in {r['seconds']:.0f}s, "
          f"{inc/1024:.1f} KiB total ({inc/1024/r['seconds']:.1f} KiB/s idle)")
    # What one full refresh per second would cost on the wire, base64 included.
    print(f"  => 1 full-frame/s costs {b64/1e6:.2f} MB/s; "
          f"30 FPS full-motion would be {b64*30/1e6:.1f} MB/s")
    print()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("container")
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--user", default="cowork")
    ap.add_argument("--port", type=int, default=5900)
    ap.add_argument("--encoding", choices=sorted(ENCODINGS), default=None,
                    help="one encoding; default runs them all")
    ap.add_argument("--quality", type=int, default=6,
                    help="Tight JPEG quality 0-9 (default 6); -1 = no JPEG pseudo-encoding")
    ap.add_argument("--dump", metavar="DIR",
                    help="write a Tight test vector (+ matching raw pixels) for --region")
    ap.add_argument("--region", default="0,0,1280,800",
                    help="x,y,w,h screen region for --dump (default full)")
    ap.add_argument("--name", default="vector", help="vector file stem for --dump")
    args = ap.parse_args()

    if args.dump:
        region = tuple(int(v) for v in args.region.split(","))
        if len(region) != 4:
            ap.error("--region needs x,y,w,h")
        return dump_vectors(
            args.container, port=args.port, user=args.user, quality=args.quality,
            region=region, out_dir=args.dump, name=args.name,
        )

    names = [args.encoding] if args.encoding else ["raw", "hextile", "zlib", "zrle", "tight"]
    raw_full: int | None = None
    print(f"container {args.container} port {args.port} — pixel format bgra8888")
    print()
    for name in names:
        try:
            r = measure(
                args.container, port=args.port, user=args.user,
                encoding_name=name, quality=args.quality, seconds=args.seconds,
            )
        except Exception as exc:  # noqa: BLE001 — a probe must report, not crash
            print(f"== {name} == FAILED: {type(exc).__name__}: {exc}")
            print()
            continue
        if name == "raw":
            raw_full = r["full_bytes"]
            print(f"display {r['width']}x{r['height']}, theoretical raw frame "
                  f"{r['width']*r['height']*BYTES_PER_PIXEL/1e6:.2f} MB")
            print()
        _report(r, raw_full)
    return 0


if __name__ == "__main__":
    sys.exit(main())
