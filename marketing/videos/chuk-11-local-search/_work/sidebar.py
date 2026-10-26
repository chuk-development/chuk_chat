"""The real chat sidebar, rebuilt 1:1 for episode 11 (episode-only; a candidate for _lib/ui.py).

Sources (Clawed dark theme, values read from the code and measured on the REAL widgets
rendered by fidelity_test/real_sidebar_test.dart at 2 px per app px):
  lib/platform_specific/sidebar_desktop.dart   desktop panel, 320 wide (kDesktopSidebarWidth)
  lib/platform_specific/sidebar_mobile.dart    phone panel, full screen width (360 here)
  lib/widgets/sidebar/sidebar_chrome.dart      SbFloatingBar, SbBlock, SbNavCard, SbSearchField,
                                               SbGroupHeader, SbChatTile, SbAccountLine
  lib/widgets/sidebar/sidebar_common.dart      nav cards, time groups (sbGroupByTime)
Theme tokens (real-tokens.json): panel #31312F (cardColor.darken 0.02), bars #262624
(scaffold), cards #363634 (surfaceContainer), onSurface #E8E4D8, onSurfaceVariant = onSurface
at 0xDC alpha, accent #D97757. Text: bodyLarge 16/1.5 ls 0.5, labelLarge 14 ls 0.1,
labelMedium 12 ls 0.5, bodySmall 12/1.33 ls 0.4, all Ubuntu.
All sizes are app px; draw inside chukvid.ui.appz().
"""
import datetime as dt
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid.core import esc, hi  # noqa: E402

HUGE = REPO / "assets/icons/hugeicons"
TODAY = dt.date(2026, 10, 26)          # the day the real widgets were rendered (fidelity)

# (days before today, title): fictional, harmless, private-feeling. Same list as the test.
CHATS = [
    (0, "Salary talk prep"),
    (1, "Landlord won't return deposit"),
    (2, "Rash on my arm"),
    (4, "Letter to my landlord about mould"),
    (9, "Sleep after night shifts"),
    (17, "Is this mole normal?"),
    (35, "Can my landlord enter without asking?"),
    (42, "Splitting rent with Sam"),
    (57, "Therapist or GP first?"),
]


def svg_icon(name, box, cls="hi", style=""):
    """A HugeIcons SVG from the app's own assets/icons/hugeicons/, drawn at 0.86 of its
    box like HugeIcon (lib/widgets/icons/huge_icon.dart _opticalInset)."""
    src = (HUGE / f"{name}.svg").read_text()
    vb = re.search(r'viewBox="([^"]+)"', src).group(1)
    inner = re.search(r"<svg[^>]*>(.*)</svg>", src, re.S).group(1)
    px = round(box * 0.86, 2)
    return (f'<svg class="{cls}" viewBox="{vb}" fill="none" style="width:{px}px;height:{px}px;{style}">'
            f'{inner}</svg>')


# Material Icons expand_more_rounded (AppIcon has no HugeIcon for it), turned 180 deg = open
CHEVRON_UP = ('<svg class="sbx-chev" viewBox="0 0 24 24" fill="currentColor" style="transform:rotate(180deg)">'
              '<path d="M15.88 9.29 12 13.17 8.12 9.29a.996.996 0 1 0-1.41 1.41l4.59 4.59c.39.39 1.02.39 1.41 0'
              'l4.59-4.59a.996.996 0 0 0 0-1.41c-.39-.38-1.03-.39-1.42 0z"/></svg>')


def groups_for(query=""):
    """sbGroupByTime over the chats the filter keeps (title contains query, lower case),
    newest first. Returns [(label, [(title, date_line)])]."""
    q = query.lower()
    start_week = TODAY - dt.timedelta(days=6)
    out = {}
    order = []
    for days, title in CHATS:
        if q and q not in title.lower():
            continue
        d = TODAY - dt.timedelta(days=days)
        if d >= TODAY:
            label, line = "Today", "9:41 AM"          # debugSbChatTimeOfDayOverride in the test
        elif d >= start_week:
            label = "This week"
        elif d.month == TODAY.month and d.year == TODAY.year:
            label = "This month"
        else:
            label = d.strftime("%B %Y")
        if d < TODAY:
            line = d.strftime("%a, %b ") + str(d.day)  # formatMediumDate (en_US)
        if label not in out:
            out[label] = []
            order.append(label)
        out[label].append((title, line))
    return [(l, out[l]) for l in order]


CSS = """
.sbx { position: absolute; overflow: hidden; background: #31312F; font-family: 'Ubuntu', sans-serif; color: #E8E4D8; }
.sbx * { box-sizing: border-box; }
.sbx-bar { position: absolute; background: #262624; border-radius: 20px 20px 6px 6px; display: flex; align-items: center; }
.sbx-wm { display: block; flex: none; }
.sbx-menu { position: absolute; width: 48px; height: 40px; display: flex; align-items: center; justify-content: center; color: #E8E4D8; }
.sbx-round { flex: none; width: 42px; height: 42px; border-radius: 50%; background: #D97757; color: #FFFFFF; display: flex; align-items: center; justify-content: center; }
.sbx-nav { position: absolute; display: flex; flex-direction: column; gap: 3px; }
.sbx-card { position: relative; background: #363634; }
.sbx-navc { height: 42px; padding: 5px 8px; display: flex; align-items: center; gap: 10px; border-radius: 6px; }
.sbx-navi { width: 30px; height: 30px; flex: none; display: flex; align-items: center; justify-content: center; color: #D97757; }
.sbx-lab { font-size: 16px; font-weight: 600; letter-spacing: 0.5px; line-height: 24px; white-space: nowrap; }
.sbx-field { height: 42px; border-radius: 20px; display: flex; align-items: center; }
.sbx-ring { position: absolute; inset: 0; border: 1.5px solid rgba(217,119,87,0.55); border-radius: 20px; pointer-events: none; }
.sbx-fico { width: 40px; flex: none; display: flex; align-items: center; justify-content: center; color: rgba(232,228,216,0.86); }
.sbx-ftext { position: relative; flex: 1; font-size: 14px; line-height: 20px; letter-spacing: 0; white-space: nowrap; padding-left: 5px; }
.sbx-hint { color: rgba(232,228,216,0.86); }
.sbx-caret { position: absolute; left: 4px; top: -1px; width: 2px; height: 22px; background: #D97757; }
.sbx-caret2 { display: inline-block; width: 2px; height: 20px; margin-left: 1px; background: #D97757; vertical-align: -5px; }
.sbx-clear { width: 32px; flex: none; margin-right: 10px; display: flex; align-items: center; justify-content: center; color: rgba(232,228,216,0.86); }
.sbx-list { position: absolute; left: 0; right: 0; }
.sbx-hdr { margin-top: 10px; height: 38px; padding: 6px 18px 6px 14px; display: flex; align-items: center; border-radius: 20px 20px 6px 6px; }
.sbx-hl { flex: 1; font-size: 14px; font-weight: 700; letter-spacing: 0.1px; line-height: 20px; color: rgba(232,228,216,0.86); white-space: nowrap; }
.sbx-hc { font-size: 12px; font-weight: 500; letter-spacing: 0.5px; color: rgba(232,228,216,0.6); margin-right: 8px; }
.sbx-chev { width: 20px; height: 20px; flex: none; color: rgba(232,228,216,0.86); }
.sbx-tile { margin-top: 3px; min-height: 56px; padding: 6px 4px 6px 12px; display: flex; align-items: center; border-radius: 6px; }
.sbx-tile.last { border-radius: 6px 6px 20px 20px; }
.sbx-tt { flex: 1; min-width: 0; }
.sbx-t1 { font-size: 16px; font-weight: 500; letter-spacing: 0.65px; line-height: 24px; position: relative; top: -0.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.sbx-t2 { margin-top: 2px; font-size: 12px; letter-spacing: 0.4px; line-height: 16px; color: rgba(232,228,216,0.86); white-space: nowrap; }
.sbx-dots { width: 28px; height: 28px; flex: none; display: flex; align-items: center; justify-content: center; color: rgba(232,228,216,0.75); }
.sbx-hov { width: 28px; flex: none; }
.sbx-acct { position: absolute; height: 56px; padding: 4px 8px 4px 14px; border-radius: 20px; background: #262624; display: flex; align-items: center; }
.sbx-an { flex: 1; font-size: 16px; font-weight: 700; letter-spacing: 0.5px; }
.sbx-chip { padding: 5px 10px; border-radius: 999px; background: #4C4C48; font-size: 13px; color: rgba(232,228,216,0.86); margin-left: 10px; margin-right: 4.5px; }
.sbx-gear { width: 40px; height: 40px; display: flex; align-items: center; justify-content: center; color: rgba(232,228,216,0.86); }
"""


def _list_html(pid, k, groups, desktop):
    rows = []
    inset = 8
    for label, items in groups:
        rows.append(f'<div class="sbx-card sbx-hdr" style="margin-left:{inset}px;margin-right:{inset}px">'
                    f'<span class="sbx-hl">{esc(label)}</span><span class="sbx-hc">{len(items)}</span>{CHEVRON_UP}</div>')
        for i, (title, line) in enumerate(items):
            last = " last" if i == len(items) - 1 else ""
            trail = (f'<span class="sbx-hov"></span><span class="sbx-dots">{hi("h-more-horizontal", 18)}</span>'
                     if desktop else "")
            rows.append(f'<div class="sbx-card sbx-tile{last}" style="margin-left:{inset}px;margin-right:{inset}px">'
                        f'<div class="sbx-tt"><div class="sbx-t1">{esc(title)}</div><div class="sbx-t2">{esc(line)}</div></div>'
                        f'{trail}</div>')
    return f'<div class="sbx-lst" id="{pid}-L{k}" style="{"" if k == 0 else "display:none"}">{"".join(rows)}</div>'


def sidebar(pid, kind, height, queries, left=0, top=0, account=True):
    """The whole panel. kind 'desktop' (320 wide, hamburger on top) or 'mobile' (360 wide).
    queries: the field contents to pre-build list states for (state 0 = idle, all chats).
    Ids: {pid} panel, {pid}-searchnav (the Search card), {pid}-field (the open field, hidden),
    {pid}-hint, {pid}-caret (idle caret), {pid}-typed, {pid}-caret2, {pid}-clear,
    {pid}-L{k} (list for queries[k]; k = 0 is the idle list)."""
    desktop = kind == "desktop"
    W = 320 if desktop else 360
    from chukvid.core import wordmark
    wm_h = round(15 * 1.907822, 2)
    wm_svg, _ = wordmark(f"{pid}-wm", "#E8E4D8", 1)
    # the lockup's width for a given height (repo wordmark.svg viewBox)
    vb = [float(x) for x in re.search(r'viewBox="([^"]+)"', wm_svg).group(1).split()]
    wm_w = round(wm_h * vb[2] / vb[3], 2)
    wm_svg = wm_svg.replace("<svg ", f'<svg class="sbx-wm" style="width:{wm_w}px;height:{wm_h}px" ', 1)
    if desktop:
        bar = (f'<div class="sbx-bar" style="left:8px;right:8px;top:16px;height:48px;padding-left:52px">{wm_svg}</div>'
               f'<div class="sbx-menu" style="left:7px;top:20px">{hi("h-menu01", 24)}</div>')
        nav_top, nav_side = 64, 8
        navs = [("pencil-edit02", "New chat"), ("image01", "Media")]
        list_top = 64 + 3 * 45 - 3 + 6
    else:
        bar = (f'<div class="sbx-bar" style="left:12px;right:12px;top:8px;height:58px;padding:6px 6px 6px 14px">'
               f'{wm_svg}<span style="flex:1"></span><span class="sbx-round">{svg_icon("pencil-edit02", 22)}</span></div>')
        nav_top, nav_side = 66, 12
        navs = [("image01", "Media")]
        list_top = 66 + 2 * 45 - 3 + 6
    n = len(navs) + 1
    cards = []
    for i, (ic, lab) in enumerate(navs):
        rad = "6px" if i < n - 1 else "6px 6px 20px 20px"
        cards.append(f'<div class="sbx-card sbx-navc" style="border-radius:{rad}"><span class="sbx-navi">{svg_icon(ic, 24)}</span>'
                     f'<span class="sbx-lab">{esc(lab)}</span></div>')
    # the Search row: nav card until clicked, then the outlined field (SbSearchField transparent)
    cards.append(f'<div style="position:relative;height:42px">'
                 f'<div class="sbx-card sbx-navc" id="{pid}-searchnav" style="position:absolute;inset:0;border-radius:6px 6px 20px 20px">'
                 f'<span class="sbx-navi">{svg_icon("search01", 24)}</span><span class="sbx-lab">Search</span></div>'
                 f'<div class="sbx-card sbx-field" id="{pid}-field" style="position:absolute;inset:0;display:none">'
                 f'<span class="sbx-fico">{svg_icon("search01", 19)}</span>'
                 f'<span class="sbx-ftext"><span id="{pid}-caret" class="sbx-caret"></span><span id="{pid}-hint" class="sbx-hint">Search chats</span>'
                 f'<span id="{pid}-typed" style="display:none"></span><span id="{pid}-caret2" class="sbx-caret2" style="display:none"></span></span>'
                 f'<span class="sbx-clear" id="{pid}-clear" style="opacity:0">{svg_icon("cancel01", 17)}</span>'
                 f'<span class="sbx-ring"></span></div></div>')
    nav = f'<div class="sbx-nav" style="left:{nav_side}px;right:{nav_side}px;top:{nav_top}px">{"".join(cards)}</div>'
    lists = "".join(_list_html(pid, k, groups_for(q), desktop) for k, q in enumerate(queries))
    acct = ""
    if account:
        side = 8 if desktop else 12
        acct = (f'<div class="sbx-acct" style="left:{side}px;right:{side}px;bottom:10px"><span class="sbx-an">Account</span>'
                f'<span class="sbx-chip">€--</span><span class="sbx-gear">{svg_icon("settings01", 20)}</span></div>')
    return (f'<div class="sbx" id="{pid}" style="left:{left}px;top:{top}px;width:{W}px;height:{height}px">'
            f'<div class="sbx-list" style="top:{list_top}px">{lists}</div>{nav}{bar}{acct}</div>')
