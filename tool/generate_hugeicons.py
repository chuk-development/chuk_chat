#!/usr/bin/env python3
"""Generate the app's icon assets from the HugeIcons free set.

The set ships as JavaScript modules holding `[tag, attributes]` pairs. This
turns the ones the app uses into plain SVG under `assets/icons/hugeicons/`, so
the icons are checked in and shipped with the build — nothing is fetched at run
time and no icon package is a dependency.

Usage:
    python3 tool/generate_hugeicons.py <path to @hugeicons/core-free-icons>

The package is MIT licensed; the licence is checked in next to the assets.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Every icon the app refers to (lib/ui/expressive/huge_icon.dart).
WANTED = [
    "Message01Icon", "Album02Icon", "Folder03Icon", "Settings01Icon",
    "UserIcon", "User02Icon", "CheckIcon", "PlusIcon", "PlusSignIcon",
    "Search01Icon", "ComputerIcon", "LaptopIcon", "ArrowLeft01Icon",
    "ArrowLeft02Icon", "Download01Icon", "Download04Icon", "Share01Icon",
    "Share08Icon", "Cancel01Icon", "MoreHorizontalIcon", "SheetIcon",
    "File01Icon", "File02Icon", "Note01Icon", "TextIcon", "Pdf01Icon",
    "FileTextIcon", "FileScriptIcon", "FileSpreadsheetIcon", "FileCodeIcon",
    "SourceCodeIcon", "BracesIcon", "TerminalIcon", "Database01Icon",
    "Zip01Icon", "Presentation01Icon", "Image01Icon", "Video01Icon",
    "BookOpen01Icon", "Pen01Icon", "Key01Icon", "InfoIcon",
    "InformationCircleIcon", "Clock01Icon", "Notification01Icon",
    "Delete02Icon", "Copy01Icon", "RefreshIcon", "Mic01Icon", "SentIcon",
    "Attachment01Icon", "PuzzleIcon", "Robot01Icon", "SparklesIcon",
    "ArrowRight01Icon", "ArrowDown01Icon", "ArrowUp01Icon", "ViewIcon",
    "ViewOffIcon", "Edit02Icon", "PaintBoardIcon", "AlertCircleIcon",
    "Alert02Icon", "Globe02Icon", "FlashIcon", "StopIcon", "StopCircleIcon",
    "PlayCircleIcon", "Mic02Icon", "SendHorizontalIcon", "ArrowUpRight01Icon",
    "UserGroupIcon", "Settings02Icon", "Call02Icon", "ImageNotFound01Icon",
    "CheckmarkCircle02Icon", "LinkSquare02Icon", "Menu01Icon", "Add01Icon",
    "Remove01Icon", "Wrench01Icon", "Bug01Icon", "Home01Icon", "StarIcon",
    "Bookmark01Icon", "Tick02Icon", "Cancel02Icon", "Loading03Icon",
    "Album01Icon", "Folder01Icon", "FileEditIcon", "Comment01Icon",
    "CheckmarkCircle01Icon", "CircleIcon", "Dollar01Icon", "Timer01Icon",
    "Chatting01Icon", "Blockchain01Icon", "Layers01Icon", "ListViewIcon",
    "GridViewIcon", "FilterIcon", "Sorting01Icon", "Link01Icon",
    "Calendar01Icon", "MapPinIcon",
    "Location01Icon", "Logout01Icon", "Moon02Icon", "Sun01Icon",
    "Alert01Icon", "AiBrain01Icon",
]

CAMEL = re.compile(r"([a-z0-9])([A-Z])")


def parse(source: str) -> list:
    """Read the module's array. Keys are bare identifiers, values are already
    JSON scalars, so one substitution makes it JSON."""
    body = source[source.index("[") : source.rindex("]") + 1]
    body = re.sub(r"(\{|,)\s*([A-Za-z][A-Za-z0-9]*)\s*:", r'\1"\2":', body)
    return json.loads(body)


def attribute_name(key: str) -> str:
    """`strokeLinecap` -> `stroke-linecap`."""
    return CAMEL.sub(r"\1-\2", key).lower()


def to_svg(nodes: list) -> str:
    lines = []
    for tag, attributes in nodes:
        pairs = " ".join(
            f'{attribute_name(key)}="{value}"'
            for key, value in attributes.items()
            if key != "key"
        )
        lines.append(f"  <{tag} {pairs} />")
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'width="24" height="24" fill="none">\n' + "\n".join(lines) + "\n</svg>\n"
    )


def file_stem(icon: str) -> str:
    """`ArrowLeft02Icon` -> `arrow-left02`."""
    stem = re.sub(r"Icon$", "", icon)
    return CAMEL.sub(r"\1-\2", stem).lower()


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    source = Path(sys.argv[1]) / "dist" / "esm"
    if not source.is_dir():
        print(f"not an unpacked @hugeicons/core-free-icons: {sys.argv[1]}")
        return 2
    out = Path(__file__).resolve().parent.parent / "assets" / "icons" / "hugeicons"
    out.mkdir(parents=True, exist_ok=True)
    written, missing = [], []
    for icon in WANTED:
        module = source / f"{icon}.js"
        if not module.exists():
            missing.append(icon)
            continue
        svg = to_svg(parse(module.read_text(encoding="utf-8")))
        (out / f"{file_stem(icon)}.svg").write_text(svg, encoding="utf-8")
        written.append(file_stem(icon))
    print(f"wrote {len(written)} icons to {out}")
    if missing:
        print("not in this version of the set:", ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
