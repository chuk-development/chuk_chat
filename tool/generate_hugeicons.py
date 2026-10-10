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
    "ViewOffIcon", "Edit02Icon", "PencilEdit02Icon", "PaintBoardIcon",
    "AlertCircleIcon",
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
    # Agent mail (docs/AGENT_MAIL.md §6).
    "Mail01Icon", "InboxIcon", "Archive02Icon", "UserCheck01Icon",
    "UserBlock01Icon",
    # One icon set on the Agents profile and settings pages (UI audit
    # 2026-10-05, item 9): replacements for filled Material fallbacks.
    "CreditCardIcon", "FingerPrintIcon", "Mortarboard01Icon",
    "UserCircleIcon", "ClipboardPasteIcon", "Task01Icon", "IdIcon",
    "CheckmarkBadge01Icon", "CallEnd01Icon", "CloudOffIcon",
    "ComputerRemoveIcon", "Unlink01Icon", "PauseCircleIcon",
    "CodeIcon",
    # OpenUI Icon component (lib/openui/openui_icons.dart): the lucide
    # names the model writes, mapped to this set.
    "TickDouble02Icon", "CancelCircleIcon", "AddCircleIcon", "MinusSignIcon",
    "MinusSignCircleIcon", "HelpCircleIcon", "UnavailableIcon", "Shield01Icon",
    "SecurityCheckIcon", "ShieldAlertIcon", "SquareLock02Icon",
    "SquareUnlock02Icon", "SlidersHorizontalIcon", "MoreVerticalIcon",
    "NotificationOff01Icon", "FavouriteIcon", "ThumbsUpIcon", "ThumbsDownIcon",
    "Flag01Icon", "Tag01Icon", "Award01Icon", "ChampionIcon", "Medal01Icon",
    "CrownIcon", "FireIcon", "Rocket01Icon", "Target01Icon", "Idea01Icon",
    "GiftIcon", "RecordIcon", "SquareIcon", "Undo02Icon", "Redo02Icon",
    "ClipboardIcon", "ClipboardListIcon", "ClipboardCheckIcon", "Upload01Icon",
    "Login01Icon", "PowerIcon", "CheckListIcon", "LeftToRightListNumberIcon",
    "DashboardSquare01Icon", "PackageIcon", "FolderOpenIcon", "Camera01Icon",
    "MusicNote01Icon", "HeadphonesIcon", "VolumeHighIcon", "VolumeMute01Icon",
    "PlayIcon", "PauseIcon", "Tv01Icon", "Book02Icon", "NewsIcon",
    "PaintBrush01Icon", "ServerStack01Icon", "CpuIcon", "HardDriveIcon",
    "QuoteDownIcon", "HashtagIcon", "AtIcon", "UserAdd01Icon", "Contact01Icon",
    "SmileIcon", "Sad01Icon", "Baby01Icon", "Briefcase01Icon",
    "Building03Icon", "FactoryIcon", "Store01Icon", "SchoolIcon",
    "Hospital01Icon", "StethoscopeIcon", "Cardiogram01Icon", "Activity01Icon",
    "Medicine01Icon", "AccessibilityIcon", "Hold01Icon", "Agreement01Icon",
    "Calendar03Icon", "CalendarCheckIn01Icon", "HourglassIcon",
    "AlarmClockIcon", "WorkHistoryIcon", "SmartWatch01Icon", "EuroIcon",
    "PoundIcon", "BitcoinIcon", "Wallet01Icon", "Money03Icon", "Coins01Icon",
    "PiggyBankIcon", "Invoice01Icon", "PercentIcon", "Calculator01Icon",
    "BankIcon", "ChartIncreaseIcon", "ChartDecreaseIcon",
    "ChartLineData01Icon", "ChartHistogramIcon", "PieChartIcon",
    "ChartAverageIcon", "DashboardSpeed01Icon", "BalanceScaleIcon",
    "ShoppingCart01Icon", "ShoppingBag01Icon", "ShoppingBasket01Icon",
    "DeliveryTruck01Icon", "Ticket01Icon", "QrCodeIcon", "BarcodeIcon",
    "ScanIcon", "DiscountIcon", "MapsIcon", "Navigation03Icon",
    "Compass01Icon", "Airplane01Icon", "AirplaneTakeOff01Icon",
    "AirplaneLanding01Icon", "Car01Icon", "Bus01Icon", "Train01Icon",
    "Bicycle01Icon", "BoatIcon", "Hotel01Icon", "BedIcon", "Luggage01Icon",
    "MountainIcon", "TentIcon", "Route01Icon", "FuelStationIcon",
    "ParkingAreaSquareIcon", "Restaurant01Icon", "Coffee01Icon", "DrinkIcon",
    "Pizza01Icon", "AnchorIcon", "CloudIcon", "CloudAngledRainIcon",
    "CloudLittleRainIcon", "CloudSnowIcon", "CloudAngledZapIcon",
    "SunCloud01Icon", "CloudFogIcon", "FastWindIcon", "TemperatureIcon",
    "DropletIcon", "UmbrellaIcon", "SnowIcon", "SunriseIcon", "SunsetIcon",
    "RainbowIcon", "Tornado01Icon", "PineTreeIcon", "Tree06Icon", "Leaf01Icon",
    "FlowerIcon", "Plant01Icon", "CatIcon", "Recycle01Icon", "Wifi01Icon",
    "BluetoothIcon", "SmartPhone01Icon", "Tablet01Icon", "PrinterIcon",
    "RssIcon", "BatteryFullIcon", "Plug01Icon", "Cursor01Icon",
    "ArrowRight02Icon", "ArrowUp02Icon", "ArrowDown02Icon",
    "ArrowDownRight01Icon", "ArrowDataTransferVerticalIcon",
    "ArrowDataTransferHorizontalIcon", "RepeatIcon", "ShuffleIcon",
    "Maximize01Icon", "Minimize01Icon", "MoveIcon", "Dumbbell01Icon",
    "GameController01Icon", "FootballIcon", "HammerIcon", "Scissor01Icon",
    "MicroscopeIcon", "TestTubeIcon", "Atom01Icon", "RulerIcon",
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
