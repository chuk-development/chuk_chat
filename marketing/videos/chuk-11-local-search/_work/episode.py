#!/usr/bin/env python3
"""Episode 11 "local-search": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 11): the real sidebar search. The Search row turns into the
field, "landlord" is typed, the list filters on every key. Next to it a small panel counts
what the app sends while you search: keys typed 8, requests 0. Then the code that does
it, in the app. "Searching your chats happens on your device." "There is no server search."
Claim (PRIVACY_CLAIMS.md, Search, may say): Searching your chats happens on your device.
There is no server search. Not said: anything about the local cache being encrypted, and
nothing about the model's search_chats tool (its results go to the model).

Facts behind the shots:
  16:9  lib/platform_specific/sidebar_desktop.dart _filterDesktopChats: a synchronous filter
        over ChatStorageService.savedChats (title + message text), in memory.
  9:16  lib/platform_specific/sidebar_mobile.dart _filterMobileChats: the same filter in a
        background isolate (compute(_filterChatsIsolate, ...)).
  (The search_chats tool reads the local SQLite chat_cache.db, LocalChatCacheNative.search;
  the API server has no search endpoint.)

Builds both formats from one spec:
  ../chuk-11-local-search/            16:9 1920x1080
  ../chuk-11-local-search-vertical/   9:16 1080x1920 (re-laid out, not cropped)
Run: python3 _work/episode.py   (make_assets.py has nothing to make for this episode)
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent
VIDEOS = PROJ.parent
sys.path.insert(0, str(VIDEOS / "_lib"))
sys.path.insert(0, str(HERE))

from chukvid import LANDSCAPE, VERTICAL, Episode, beats, scenes, ui  # noqa: E402
from chukvid.core import cursor, esc, hi  # noqa: E402
import sidebar as sb  # noqa: E402

MUSIC = VIDEOS.parent / "_shared/music/s3-english-garden-45s.wav"
DUR = 45.0
QUERY = "landlord"
QUERIES = [""] + [QUERY[:i] for i in range(1, len(QUERY) + 1)]   # list state per keystroke
CPS = 5.5          # search typing: slower than the 18 chars/s prompt typing, so each filter step reads

# ------------------------------------------------------------------ cuts on the beat grid
# s3-english-garden: 117 BPM, beat 0.51 s; the big hits are 18.45, 27.66 and 34.31, the
# track thins out after 35 and ends near 41. Rough targets, snapped to the beat grid.
TARGETS = [4.1, 12.3, 15.4, 18.45, 25.6, 31.2, 34.3]

# ------------------------------------------------------------------ the real code (verbatim lines)
CODE_DESKTOP = (
    "lib/platform_specific/sidebar_desktop.dart",
    "_filterDesktopChats",
    [   # sidebar_desktop.dart lines 142-152, the else branch, de-indented by 6
        "final lowerQuery = searchQuery.toLowerCase();",
        "filteredRecentChats = ChatStorageService.savedChats.where((chat) {",
        "  final titleMatches = deriveSidebarChatTitle(",
        "    chat,",
        "  ).toLowerCase().contains(lowerQuery);",
        "  if (titleMatches) return true;",
        "  return (chat.messagesOrNull ?? const []).any(",
        "    (message) => message.text.toLowerCase().contains(lowerQuery),",
        "  );",
        "}).toList();",
    ],
)
CODE_MOBILE = (
    "sidebar_mobile.dart",
    "background isolate",
    [   # sidebar_mobile.dart: line 239 (the call) and lines 674-695 (_filterChatsIsolate), excerpt
        "await compute(_filterChatsIsolate, {",
        "  'chats': payload,",
        "  'query': lowerQuery,",
        "});",
        "",
        "for (final dynamic entry in chats) {",
        "  …",
        "  if (preview.contains(query)) {",
        "    matches.add(id);",
        "    continue;",
        "  }",
        "  final bool hasMatch = messages.any(",
        "    (dynamic message) =>",
        "        (message as String).contains(query),",
        "  );",
    ],
)


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + sb.CSS + EP_CSS)
    ep.write()                                   # scaffold first: `beats` needs the music in place
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.4)
    v = fmt.vertical
    cs = 1.3 if v else 1.0                       # cursor scale

    s01_hook(ep, cut[0], cut[1], v)
    s02_search(ep, cut[1], cut[2], v, cs)
    s03_log(ep, cut[2], cut[3], v)
    scenes.card(ep, "s04", cut[3], cut[4], ["So where did", "it search?"] if v else ["So where did it search?"])
    s05_code(ep, cut[4], cut[5], v)
    s06_block(ep, cut[5], cut[6], v)
    scenes.card(ep, "s07", cut[6], cut[7], ["There is no", "server search."] if v else ["There is no server search."], bg="@TAN@")
    scenes.end_card(ep, "s08", cut[7], DUR)
    ep.write()
    ep.report()
    return ep


EP_CSS = """
/* the request counter panel: a visual device, light card in the server-view type scale (08) */
.nl-bar { height: 92px; display: flex; align-items: center; gap: 16px; padding: 0 32px; border-bottom: 1px solid #E6E8EB; color: #11181C; white-space: nowrap; }
.nl-bar .sb-ic { width: 32px; height: 32px; color: #687076; }
.nl-title { font-size: 32px; font-weight: 600; }
.nl-head { display: flex; height: 64px; align-items: center; background: #F8F9FA; border-bottom: 1px solid #E6E8EB; font-size: 30px; font-weight: 600; color: #687076; }
.nl-head span { padding: 0 32px; }
.nl-body { display: flex; align-items: center; justify-content: center; color: #889096; font-size: 34px; border-bottom: 1px solid #E6E8EB; }
.nl-foot { display: flex; height: 96px; align-items: center; padding: 0 32px; gap: 18px; font-size: 32px; color: #3E4347; white-space: nowrap; }
.nl-num { position: relative; display: inline-block; min-width: 1.2ch; font-family: 'ChukMono', monospace; font-weight: 600; font-size: 40px; color: #11181C; }
.nl-num span { position: absolute; left: 0; top: 50%; transform: translateY(-50%); }
.nl-sep { width: 1px; height: 44px; background: #E6E8EB; margin: 0 14px; }
.nl-zero { color: #1F9D60; }
.nl-dot { width: 14px; height: 14px; border-radius: 50%; background: #E5484D; flex: none; }
.nl-rec { font-size: 30px; color: #687076; }
/* code card: 08's opened-cell card with code lines */
.cd-body { padding: 30px 40px 34px; font-family: 'ChukMono', monospace; font-variant-ligatures: none; color: #11181C; }
.cd-l { white-space: pre; }
.cd-hl { background: rgba(217,119,87,0.22); border-radius: 6px; box-shadow: inset 0 -3px 0 #D97757; }
.cd-dim { color: #889096; }
#s05-cd .sb-tag { font-size: 28px; }
/* hook: chat tiles drifting past */
.hk-col { position: absolute; }
.hk-col .sbx-tile { background: #363634; color: #E8E4D8; }
"""

# 9:16: list text at least 34 px
V_LOG_CSS = """
#X .nl-title, #X .nl-rec, #X .nl-body, #X .nl-foot { font-size: 34px; }
#X .nl-num { font-size: 44px; }
"""

SVG_NET = sb.svg_icon("wifi01", 32 / 0.86, cls="sb-ic")


def count_spans(prefix, n):
    """n+1 stacked digits 0..n; show one at a time with tl.set display."""
    return "".join(f'<span id="{prefix}{i}" style="{"" if i == 0 else "display:none"}">{i}</span>' for i in range(n + 1))


def netlog(id_, left, top, width, body_h, compact=False):
    """The request counter: what the app sent while you searched. Ids: {id_}-k{n} (keys typed),
    {id_}-zero (the request count)."""
    head = "" if compact else ('<div class="nl-head"><span style="width:200px">Method</span>'
                               '<span style="flex:1">Host</span><span style="width:190px">Status</span></div>')
    return (f'<div class="sb-card" id="{id_}" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="nl-bar">{SVG_NET}<span class="nl-title">Requests while you search</span>'
            f'<span class="sb-grow"></span><span class="nl-dot"></span><span class="nl-rec">Recording</span></div>'
            f'{head}<div class="nl-body" style="height:{body_h}px">No requests</div>'
            f'<div class="nl-foot"><span>Keys typed</span><span class="nl-num">{count_spans(id_ + "-k", len(QUERY))}</span>'
            f'<span class="nl-sep"></span><span>Requests sent</span><span class="nl-num nl-zero" id="{id_}-zero">0</span></div></div>')


def type_js(pid, log, t0, cps=CPS):
    """The keystrokes: one character, one list state, one keys-typed count at a time."""
    js = [f"tl.set('#{pid}-hint', {{ display: 'none' }}, {t0:.3f});",
          f"tl.set('#{pid}-caret', {{ display: 'none' }}, {t0:.3f});",
          f"tl.set('#{pid}-typed', {{ display: 'inline' }}, {t0:.3f});",
          f"tl.set('#{pid}-caret2', {{ display: 'inline-block' }}, {t0:.3f});",
          f"var tend = hfType(tl, document.getElementById('{pid}-typed'), {QUERY!r}, {t0:.3f}, {cps});"]
    for i in range(1, len(QUERY) + 1):
        t = t0 + i / cps
        js.append(f"tl.set('#{pid}-L{i - 1}', {{ display: 'none' }}, {t:.3f});")
        js.append(f"tl.set('#{pid}-L{i}', {{ display: 'block' }}, {t:.3f});")
        if log:
            js.append(f"tl.set('#{log}-k{i - 1}', {{ display: 'none' }}, {t:.3f});")
            js.append(f"tl.set('#{log}-k{i}', {{ display: 'inline' }}, {t:.3f});")
    js.append(f"tl.to('#{pid}-clear', {{ opacity: 1, duration: 0.05 }}, {t0 + 1 / cps:.3f});")
    return "\n  ".join(js), t0 + len(QUERY) / cps


# =================================================================== s01 hook: a long history
def s01_hook(ep, a, b, v):
    fmt = ep.fmt
    items = [it for _, grp in sb.groups_for("") for it in grp]   # every chat, its real date line
    tiles = "".join(
        f'<div class="sbx-card sbx-tile" style="margin:0 0 3px;border-radius:{"20px 20px 6px 6px" if i == 0 else "6px"}">'
        f'<div class="sbx-tt"><div class="sbx-t1">{esc(t)}</div><div class="sbx-t2">{esc(d)}</div></div>'
        f'<span class="sbx-hov"></span><span class="sbx-dots">{hi("h-more-horizontal", 18)}</span></div>'
        for i, (t, d) in enumerate(items))
    if v:
        Z, colw, cx, ctop = 2.9, 360, (fmt.W / 2.9 - 360) / 2, 0
        lines, size, ly, align, lx = ["You asked about", "it once.", "Now find it."], 112, 1120, "center", 0
        mask_h, mask_top = 820, 220
        drift = -260
    else:
        Z, colw, cx, ctop = 2.5, 320, 1030 / 2.5, 0
        lines, size, ly, align, lx = ["You asked about", "it once.", "Now find it."], 104, 330, "left", 130
        mask_h, mask_top = 1080, 0
        drift = -300
    lh = round(size * 1.12)
    ldivs = "".join(
        f'<div class="serif" id="s01-l{i}" style="position:absolute;left:{lx}px;right:0;top:{ly + i * lh}px;'
        f'font-size:{size}px;line-height:{lh}px;text-align:{align}">{esc(t)}</div>' for i, t in enumerate(lines))
    inner = f'<div class="hk-col" id="s01-col" style="left:{cx:.2f}px;top:{ctop:.2f}px;width:{colw}px">{tiles}</div>'
    css = f"""
#s01-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#s01-mask {{ position: absolute; left: 0; right: 0; top: {mask_top}px; height: {mask_h}px; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 80%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 16%, #000 80%, transparent 100%); }}
"""
    body = f"""
    <div id="s01-all" class="fill" data-layout-allow-overflow>
      <div id="s01-mask">{ui.appz('s01-z', fmt, Z, inner)}</div>
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s01-col', {{ y: 40 }}, {{ y: {drift / Z:.1f}, duration: {b - a:.2f}, ease: 'none' }}, 0);
  tl.fromTo('#s01-z', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5 }}, 0);
  hfReveal(tl, '#s01-l0', 0.35);
  hfReveal(tl, '#s01-l1', 0.8);
  hfReveal(tl, '#s01-l2', 1.75);
  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s01", a, b, css, body, js)


# =================================================================== s02 the real sidebar search
def s02_search(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        Z, kind, pw = 2.9, "mobile", 360
        win_h = 340                                  # app px shown: head bar to the second result
        wl, wt = (fmt.W / Z - pw) / 2, 236 / Z       # app px
        nav_y = 66 + 45                              # the Search row, panel px
        log = netlog("s02-log", 40, 1244, 1000, 96, compact=True)
        pan = 0
    else:
        Z, kind, pw = 2.5, "desktop", 320
        win_h = 540
        wl, wt = 44, 24
        nav_y = 64 + 90
        log = netlog("s02-log", 1000, 250, 800, 236)
        pan = -190                                   # video px: show the third result
    panel = sb.sidebar("s02-sb", kind, 540 if not v else 470, QUERIES, account=not v)
    inner = (f'<div class="a-win" id="s02-win" style="left:{wl:.2f}px;top:{wt:.2f}px;width:{pw}px;height:{win_h}px;'
             f'border-radius:{18 if not v else 22}px">{panel}</div>')
    # targets in video px
    sx, sy = (wl + 8 + (8 if v else 0) + 120) * Z, (wt + nav_y + 21) * Z
    css = f"""
#s02-cam {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#s02-log {{ z-index: 4; }}
{V_LOG_CSS.replace('#X', '#s02-log') if v else ''}
"""
    body = f"""
    <div id="s02-cam" class="fill" data-layout-allow-overflow>
      <div id="s02-pan" class="fill">{ui.appz('s02-z', fmt, Z, inner)}</div>
      {log}
      {cursor('s02-cur', cs)}
    </div>
"""
    t_click = 1.35
    t0 = 2.05
    tjs, tend = type_js("s02-sb", "s02-log", t0)
    js = f"""
  tl.fromTo('#s02-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s02-log', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0.15);
  tl.fromTo('#s02-cur', {{ x: {sx + 260:.0f}, y: {fmt.H + 60} }}, {{ x: {sx:.0f}, y: {sy:.0f}, duration: 0.9, ease: 'power2.inOut' }}, 0.25);
  hfShape(tl, '#s02-cur', 1.05, 'hand');
  tl.to('#s02-sb-searchnav', {{ backgroundColor: '#41413E', duration: 0.1 }}, 1.1);
  hfClick(tl, '#s02-cur', {t_click});
  // the Search row turns into the field (SidebarDesktop/_SidebarMobile._searchActive)
  tl.set('#s02-sb-searchnav', {{ display: 'none' }}, {t_click + 0.1:.2f});
  tl.set('#s02-sb-field', {{ display: 'flex' }}, {t_click + 0.1:.2f});
  tl.to('#s02-sb-caret', {{ opacity: 0, duration: 0.01 }}, {t_click + 0.55:.2f});
  tl.to('#s02-sb-caret', {{ opacity: 1, duration: 0.01 }}, {t_click + 0.6 + 0.25:.2f});
  hfShape(tl, '#s02-cur', {t_click + 0.25:.2f}, 'arrow');
  tl.to('#s02-cur', {{ x: {sx + (330 if v else 360):.0f}, y: {sy + (520 if v else 330):.0f}, duration: 0.6, ease: 'power2.out' }}, {t_click + 0.3:.2f});
  {tjs}
  tl.to('#s02-cur', {{ x: {fmt.W + 80}, y: {fmt.H * 0.7:.0f}, duration: 0.8, ease: 'power3.in' }}, tend + 0.3);
  tl.fromTo('#s02-pan', {{ y: 0 }}, {{ y: {pan}, duration: 1.1, ease: 'power2.inOut', immediateRender: false }}, tend + 0.5);
  tl.fromTo('#s02-log-zero', {{ scale: 1 }}, {{ scale: 1.25, duration: 0.18, ease: 'power2.out', yoyo: true, repeat: 1 }}, tend + 0.7);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    assert tend + 1.7 < b - a, (tend, b - a)
    ep.add("s02", a, b, css, body, js)


# =================================================================== s03 the request counter, close
def s03_log(ep, a, b, v):
    fmt = ep.fmt
    if v:
        log = netlog("s03-log", 40, 330, 1000, 300, compact=True)
        lines, lsize, ltop = ["Not one", "request."], 120, 1050
    else:
        log = netlog("s03-log", 360, 120, 1200, 300)
        lines, lsize, ltop = ["Not one request."], 112, 820
    log = log.replace('id="s03-log-k0" style=""', 'id="s03-log-k0" style="display:none"').replace(
        f'id="s03-log-k{len(QUERY)}" style="display:none"', f'id="s03-log-k{len(QUERY)}" style=""')
    lh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s03-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    css = f"""
#s03-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
{V_LOG_CSS.replace('#X', '#s03-log') if v else ''}
#s03-log .nl-foot {{ height: {120 if not v else 110}px; font-size: {38 if not v else 36}px; }}
#s03-log .nl-num {{ font-size: {56 if not v else 52}px; }}
"""
    body = f"""
    <div id="s03-all" class="fill">
      {log}
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s03-log', {{ opacity: 0, scale: 0.94, y: 40 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s03-log-zero', {{ scale: 1.6 }}, {{ scale: 1, duration: 0.5, ease: 'back.out(2)' }}, 0.35);
  {''.join(f"hfReveal(tl, '#s03-l{i}', {0.7 + i * 0.35:.2f});" for i in range(len(lines)))}
  tl.fromTo('#s03-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s03", a, b, css, body, js)


# =================================================================== s05 the code that does it
def _wrap(line, width):
    """Soft-wrap a code line like an editor: continuation lines indent 4 more."""
    if len(line) <= width:
        return [line]
    ind = len(line) - len(line.lstrip())
    cut = line.rfind(" ", 0, width)
    cut = cut if cut > ind else width
    return [line[:cut]] + _wrap(" " * (ind + 4) + line[cut:].lstrip(), width)


def s05_code(ep, a, b, v):
    fmt = ep.fmt
    path, tag, lines = CODE_MOBILE if v else CODE_DESKTOP
    if v:
        fs, lh, left, top, width, wrapw = 34, 50, 40, 250, 1000, 44
        ltxt, lsize, ltop = ["Right here,", "in the app."], 112, 1180
    else:
        fs, lh, left, top, width, wrapw = 30, 46, 140, 96, 1640, 80
        ltxt, lsize, ltop = ["Right here, in the app."], 104, 846
    rows = []
    for ln in lines:
        for part in _wrap(ln, wrapw):
            h = esc(part)
            for key in ("contains(lowerQuery)", "contains(query)"):
                h = h.replace(esc(key), f'<span class="cd-hl">{esc(key)}</span>')
            if part.strip() == "…":
                h = f'<span class="cd-dim">{h}</span>'
            rows.append(f'<div class="cd-l">{h or " "}</div>')
    card = (f'<div class="sb-card" id="s05-cd" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="ex-bar">{ui.SVG["file"]}<b>{esc(path)}</b><span class="sb-tag">{esc(tag)}</span>'
            f'<span class="sb-grow"></span><span style="font-size:26px;color:#687076">Dart</span></div>'
            f'<div class="cd-body" id="s05-b" style="font-size:{fs}px;line-height:{lh}px">{"".join(rows)}</div></div>')
    llh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s05-l{i}" style="top:{ltop + i * llh}px;font-size:{lsize}px;line-height:{llh}px">{esc(t)}</div>'
                    for i, t in enumerate(ltxt))
    css = f"""
#s05-all {{ transform-origin: {fmt.cx}px {top + 200}px; }}
"""
    body = f"""
    <div id="s05-all" class="fill">
      {card}
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s05-cd', {{ opacity: 0, y: 50 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s05-b .cd-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.2, stagger: 0.06 }}, 0.2);
  tl.fromTo('#s05-b .cd-hl', {{ backgroundColor: 'rgba(217,119,87,0)', boxShadow: 'inset 0 0px 0 #D97757' }}, {{ backgroundColor: 'rgba(217,119,87,0.22)', boxShadow: 'inset 0 -3px 0 #D97757', duration: 0.4, stagger: 0.25 }}, 1.6);
  {''.join(f"hfReveal(tl, '#s05-l{i}', {2.6 + i * 0.4:.2f});" for i in range(len(ltxt)))}
  tl.fromTo('#s05-all', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s05", a, b, css, body, js)


# =================================================================== s06 brown block: it happens on the device
LAPTOP = ('<svg viewBox="0 0 24 24" fill="none" style="width:100%;height:100%"><path d="M20.5 16.5V8.5C20.5 6.14 20.5 4.96 19.77 4.23'
          'C19.04 3.5 17.86 3.5 15.5 3.5H8.5C6.14 3.5 4.96 3.5 4.23 4.23C3.5 4.96 3.5 6.14 3.5 8.5V16.5" stroke="currentColor" '
          'stroke-width="0.2" stroke-linecap="round" stroke-linejoin="round"/><path d="M21.98 20.5H2.02C1.63 20.5 1.38 20.11 1.55 19.78'
          'L3.5 16.5H20.5L22.44 19.78C22.62 20.11 22.37 20.5 21.98 20.5Z" stroke="currentColor" stroke-width="0.2" '
          'stroke-linecap="round" stroke-linejoin="round"/></svg>')
PHONE = ('<svg viewBox="-0.2 0 13.4 20.5" fill="none" style="width:100%;height:100%"><path d="M8 .25H5C2.64.25 1.46.25.73.98 0 1.71 0 2.89 0 5.25'
         'v9.5c0 2.36 0 3.54.73 4.27.73.73 1.91.73 4.27.73h3c2.36 0 3.54 0 4.27-.73.73-.73.73-1.91.73-4.27v-9.5c0-2.36 0-3.54-.73-4.27'
         'C11.54.25 10.36.25 8 .25Z" stroke="currentColor" stroke-width="0.16"/></svg>')


def s06_block(ep, a, b, v):
    fmt = ep.fmt
    results = [t for t in (c for _, c in sb.CHATS) if QUERY in t.lower()]
    if v:
        dev, dx, dy, dw, dh = PHONE, 296, 250, 488, 750
        sx, sy, sw = 336, 360, 408             # the screen area inside the outline
        pill_fs, row_fs, row_h = 38, 34, 100
        rows = results
        lines, lsize, ltop = ["Searching your", "chats happens", "on your device."], 104, 1110
    else:
        dev, dx, dy, dw, dh = LAPTOP, 560, 40, 800, 800
        sx, sy, sw = 690, 196, 540
        pill_fs, row_fs, row_h = 32, 30, 84
        rows = results
        lines, lsize, ltop = ["Searching your chats", "happens on your device."], 96, 800
    pill = (f'<div id="s06-pill" style="position:absolute;left:{sx}px;top:{sy}px;width:{sw}px;height:{pill_fs * 2.1:.0f}px;border-radius:999px;'
            f'border:3px solid rgba(244,238,228,0.75);display:flex;align-items:center;gap:16px;padding:0 24px;color:@CANVAS@;'
            f'font-family:Ubuntu,sans-serif;font-size:{pill_fs}px">{sb.svg_icon("search01", pill_fs * 1.2)}<span id="s06-q"></span>'
            f'<span class="sbx-caret2" style="height:{pill_fs * 1.1:.0f}px;background:@ACC@"></span></div>')
    rws = "".join(
        f'<div class="s06-r" id="s06-r{i}" style="position:absolute;left:{sx}px;top:{sy + pill_fs * 2.1 + 26 + i * row_h:.0f}px;width:{sw}px;height:{row_h - 12}px;'
        f'border-radius:14px;background:rgba(244,238,228,0.12);display:block;line-height:{row_h - 12}px;padding:0 22px;text-overflow:ellipsis;'
        f'font-family:Ubuntu,sans-serif;font-weight:500;font-size:{row_fs}px;color:@CANVAS@;white-space:nowrap;overflow:hidden">{esc(r)}</div>'
        for i, r in enumerate(rows))
    lh = round(lsize * 1.12)
    ldivs = "".join(f'<div class="card-line serif" id="s06-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px;color:@CANVAS@">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    css = f"""
#s06-bg {{ background: @BROWN@; }}
#s06-all {{ transform-origin: {fmt.cx}px {dy + dh / 2}px; }}
#s06-dev {{ position: absolute; left: {dx}px; top: {dy}px; width: {dw}px; height: {dh}px; color: rgba(244,238,228,0.85); }}
"""
    body = f"""
    <div id="s06-bg" class="fill"></div>
    <div id="s06-all" class="fill">
      <div id="s06-dev">{dev}</div>
      {pill}
      {rws}
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s06-dev', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s06-pill', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 0.3);
  hfType(tl, document.getElementById('s06-q'), {QUERY!r}, 0.45, 12);
  tl.fromTo('#s06-all .s06-r', {{ opacity: 0, y: 16 }}, {{ opacity: 1, y: 0, duration: 0.3, stagger: 0.12, ease: 'power3.out' }}, 1.2);
  {''.join(f"hfReveal(tl, '#s06-l{i}', {1.6 + i * 0.4:.2f});" for i in range(len(lines)))}
  tl.fromTo('#s06-all', {{ scale: 1 }}, {{ scale: 1.04, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s06", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-11-local-search")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-11-local-search-vertical")
