#!/usr/bin/env python3
"""Register the bridge with the browsers on this machine.

The host manifest is the whole access rule: ``allowed_origins`` names the one
extension that may start the bridge, and only the local user can write the file.
That is why the add-on needs no port, no token and no origin check.

Usage:
    ./install_host_manifest.py --chrome-id <32-char extension id>
    ./install_host_manifest.py --firefox-id cowork@chuk.dev
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

NAME = "dev.chuk.cowork"
BRIDGE = Path(__file__).resolve().parent / "cowork_browser_bridge.py"

CHROMIUM_DIRS = {
    "chrome": "~/.config/google-chrome/NativeMessagingHosts",
    "chromium": "~/.config/chromium/NativeMessagingHosts",
    "brave": "~/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts",
}
FIREFOX_DIR = "~/.mozilla/native-messaging-hosts"


def write(directory: str, manifest: dict) -> Path:
    target = Path(os.path.expanduser(directory))
    target.mkdir(parents=True, exist_ok=True)
    path = target / f"{NAME}.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome-id", help="extension id as chrome://extensions shows it")
    parser.add_argument("--firefox-id", default="cowork@chuk.dev")
    parser.add_argument("--no-firefox", action="store_true")
    args = parser.parse_args()

    if not BRIDGE.exists():
        raise SystemExit(f"bridge not found: {BRIDGE}")

    written = []
    if args.chrome_id:
        manifest = {
            "name": NAME,
            "description": "CoWork browser bridge",
            "path": str(BRIDGE),
            "type": "stdio",
            "allowed_origins": [f"chrome-extension://{args.chrome_id}/"],
        }
        for directory in CHROMIUM_DIRS.values():
            written.append(write(directory, manifest))

    if not args.no_firefox:
        manifest = {
            "name": NAME,
            "description": "CoWork browser bridge",
            "path": str(BRIDGE),
            "type": "stdio",
            "allowed_extensions": [args.firefox_id],
        }
        written.append(write(FIREFOX_DIR, manifest))

    for path in written:
        print(path)
    if not written:
        print("nothing written — pass --chrome-id, or drop --no-firefox")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
