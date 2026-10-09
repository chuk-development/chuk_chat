#!/usr/bin/env python3
"""Download images, check them, drop duplicates, pack them into one ZIP.

Usage (the list comes on stdin as JSON):

    python3 /workspace/skills/web-images/pack_images.py --zip downloads/name.zip <<'EOF'
    [{"url": "https://...", "name": "1-front", "page": "https://shop/product"},
     {"url": "https://...", "name": "2-back",  "page": "https://shop/product"}]
    EOF

Each file is checked: the download worked, it is a real image (Pillow opens
it), the longer side has at least --min-px pixels, and it is not the same
picture as an earlier one (same bytes, or the same picture at another size).
WebP, AVIF, GIF, BMP and TIFF are converted to JPG (PNG when the picture has
transparency), because many viewers cannot open AVIF or WebP. Each OK line
names the main colours and says "greyscale" for a picture without colour,
so a wrong colour variant shows without a vision model.
The checked files stay in --keep (default tmp/images) for a vision check;
delete that folder when you are done. One line per image is printed, then the
ZIP path. Exit code 0 when at least one image is in the ZIP.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import ipaddress
import json
import os
import re
import socket
import sys
import urllib.parse
import urllib.request
import zipfile

try:
    from PIL import Image
except ImportError:  # pragma: no cover - the sandbox image has Pillow
    Image = None

BROWSER_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0 Safari/537.36"
)
MAX_BYTES = 25 * 1024 * 1024
EXT = {"JPEG": ".jpg", "PNG": ".png", "WEBP": ".webp", "GIF": ".gif", "AVIF": ".avif",
       "BMP": ".bmp", "TIFF": ".tif"}


def check_public_url(url: str) -> None:
    """Refuse a URL that is not public http(s).

    The model writes the URL list. A ``file://`` URL would put a local file
    into the ZIP that goes to the user, and an internal address (loopback,
    LAN, link-local such as 169.254.169.254) would reach a service that is
    not on the internet. Every address the host name resolves to must be
    public.
    """
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise ValueError(f"only http and https URLs are allowed, not {parts.scheme or 'none'}")
    host = parts.hostname
    if not host:
        raise ValueError("the URL has no host")
    try:
        infos = socket.getaddrinfo(host, parts.port or (443 if parts.scheme == "https" else 80))
    except socket.gaierror as exc:
        raise ValueError(f"cannot resolve {host}") from exc
    for info in infos:
        address = ipaddress.ip_address(info[4][0].split("%", 1)[0])
        if not address.is_global:
            raise ValueError(f"{host} is not a public address")


class _PublicRedirects(urllib.request.HTTPRedirectHandler):
    """Check each redirect target with the same rule as the first URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_PublicRedirects())


def fetch(url: str, page: str | None) -> tuple[bytes, str]:
    check_public_url(url)
    # JPEG and PNG first: a CDN with automatic formats (``auto=format``) then
    # sends a file that every viewer opens.
    headers = {"User-Agent": BROWSER_UA, "Accept": "image/jpeg,image/png;q=0.9,image/*;q=0.5"}
    if page:
        headers["Referer"] = page
    request = urllib.request.Request(url, headers=headers)
    with _OPENER.open(request, timeout=60) as response:
        data = response.read(MAX_BYTES + 1)
        kind = response.headers.get("content-type", "")
    if len(data) > MAX_BYTES:
        raise ValueError("bigger than 25 MB")
    return data, kind


def average_hash(image) -> int:
    """A 256-bit picture fingerprint: the same picture at another size or
    quality gives (almost) the same value; another angle does not."""
    small = image.convert("L").resize((16, 16))
    pixels = list(small.tobytes())
    mean = sum(pixels) / len(pixels)
    value = 0
    for pixel in pixels:
        value = (value << 1) | (1 if pixel >= mean else 0)
    return value


def colour_name(red: int, green: int, blue: int) -> str:
    """A coarse colour name for one pixel."""
    import colorsys

    hue, sat, val = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)
    if val < 0.18:
        return "black"
    if sat < 0.18:
        if val > 0.86:
            return "white"
        if val > 0.62:
            return "light grey"
        return "grey" if val > 0.38 else "dark grey"
    degrees = hue * 360
    for limit, name in ((15, "red"), (40, "orange"), (65, "yellow"), (170, "green"),
                        (200, "cyan"), (260, "blue"), (290, "purple"), (345, "pink")):
        if degrees < limit:
            return name
    return "red"


def colour_summary(image) -> str:
    """``white 61%, red 22%, light grey 9%`` plus ``greyscale`` when less than
    3 % of the picture has colour."""
    small = image.convert("RGB")
    small.thumbnail((96, 96))
    data = small.tobytes()
    counts: dict[str, int] = {}
    coloured = 0
    total = len(data) // 3
    for offset in range(0, len(data), 3):
        name = colour_name(data[offset], data[offset + 1], data[offset + 2])
        counts[name] = counts.get(name, 0) + 1
        if name not in ("black", "white", "light grey", "grey", "dark grey"):
            coloured += 1
    top = sorted(counts.items(), key=lambda item: -item[1])[:4]
    text = ", ".join(f"{name} {count * 100 // max(total, 1)}%" for name, count in top)
    if coloured * 100 < 3 * max(total, 1):
        text += " (greyscale)"
    return text


def to_viewable(image, data: bytes, fmt: str) -> tuple[bytes, str]:
    """JPEG and PNG stay as they are; any other format becomes JPEG, or PNG
    when the picture has transparency."""
    if fmt.upper() in ("JPEG", "PNG"):
        return data, fmt.upper()
    has_alpha = image.mode in ("RGBA", "LA") or (image.mode == "P" and "transparency" in image.info)
    out = io.BytesIO()
    if has_alpha:
        image.convert("RGBA").save(out, "PNG", optimize=True)
        return out.getvalue(), "PNG"
    image.convert("RGB").save(out, "JPEG", quality=92)
    return out.getvalue(), "JPEG"


def safe_name(name: str, index: int) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name or "").strip("-.")
    return cleaned[:60] or f"image-{index}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", required=True, help="Path of the ZIP to write.")
    parser.add_argument("--min-px", type=int, default=600, help="Smallest longer side.")
    parser.add_argument("--keep", default="tmp/images", help="Folder for the checked files.")
    args = parser.parse_args()
    # Relative paths are read from the workspace root (this file lives in
    # <workspace>/skills/web-images/), not from wherever the shell stands.
    workspace = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if not os.path.isabs(args.zip):
        args.zip = os.path.join(workspace, args.zip)
    if not os.path.isabs(args.keep):
        args.keep = os.path.join(workspace, args.keep)

    try:
        items = json.load(sys.stdin)
    except ValueError as exc:
        print(f"bad JSON on stdin: {exc}")
        return 2
    if not isinstance(items, list) or not items:
        print("give a JSON list of {url, name, page}")
        return 2

    os.makedirs(args.keep, exist_ok=True)
    seen_bytes: dict[str, str] = {}
    seen_pictures: list[tuple[int, str]] = []
    kept: list[tuple[str, str]] = []
    for index, item in enumerate(items, 1):
        url = str(item.get("url") or "").strip()
        page = str(item.get("page") or "").strip() or None
        label = safe_name(str(item.get("name") or ""), index)
        if not url:
            print(f"SKIP {label}: no url")
            continue
        try:
            data, kind = fetch(url, page)
        except Exception as exc:  # noqa: BLE001 - report and go on
            print(f"SKIP {label}: download failed ({type(exc).__name__}: {exc})")
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen_bytes:
            print(f"SKIP {label}: same file as {seen_bytes[digest]}")
            continue
        if Image is None:
            fmt, size, fingerprint, colours = "", (0, 0), None, ""
        else:
            try:
                image = Image.open(io.BytesIO(data))
                image.load()
            except Exception:  # noqa: BLE001
                print(f"SKIP {label}: not an image (content-type {kind or 'none'})")
                continue
            fmt, size = image.format or "", image.size
            fingerprint = average_hash(image)
            colours = colour_summary(image)
        if size != (0, 0) and max(size) < args.min_px:
            print(f"SKIP {label}: too small ({size[0]}x{size[1]})")
            continue
        if fingerprint is not None:
            twin = next(
                (name for value, name in seen_pictures if (value ^ fingerprint).bit_count() <= 12),
                None,
            )
            if twin:
                print(f"SKIP {label}: same picture as {twin} ({size[0]}x{size[1]})")
                continue
        note = ""
        if Image is not None:
            original = fmt
            data, fmt = to_viewable(image, data, fmt)
            if fmt != original.upper():
                note = f" (converted from {original or 'unknown'})"
        else:
            colours = ""
        extension = EXT.get(fmt.upper(), os.path.splitext(url.split("?")[0])[1] or ".img")
        filename = label + extension
        path = os.path.join(args.keep, filename)
        with open(path, "wb") as handle:
            handle.write(data)
        seen_bytes[digest] = filename
        if fingerprint is not None:
            seen_pictures.append((fingerprint, filename))
        kept.append((path, filename))
        shade = f"; colours: {colours}" if colours else ""
        print(f"OK   {filename}: {size[0]}x{size[1]} {fmt}{note} {len(data) // 1024} KB{shade}; from {page or url}")

    if not kept:
        print("NO IMAGES: nothing passed the checks")
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(args.zip)), exist_ok=True)
    with zipfile.ZipFile(args.zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, filename in kept:
            archive.write(path, filename)
    print(f"ZIP  {args.zip}: {len(kept)} images, {os.path.getsize(args.zip) // 1024} KB")
    print(f"Checked files are in {args.keep}/ (delete the folder when done).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
