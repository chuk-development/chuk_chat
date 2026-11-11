#!/usr/bin/env python3
"""Generate the scene files and index.html of chuk-07-launch.

Shared CSS, icons, cursor and the CC mark live here once and are written
into every scene file, because a scene file must carry its own styles.
Run:  python3 _work/build.py   (from the project root)
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMP = ROOT / "compositions"
COMP.mkdir(exist_ok=True)

# ------------------------------------------------------------------ tokens
CANVAS, GRID, TAN, BROWN = "#F4EEE4", "#E6DCCD", "#DCCBB4", "#5C4033"
INK, SOFT, SURF, BORDER = "#2A1F17", "#6E5D4E", "#FFFDF9", "#E2D6C6"
BUBBLE, ACCENT = "#EADFCF", "#8B5A2B"

# ------------------------------------------------------------------ icons (24 viewBox, stroke)
ICON_PATHS = {
    "search": '<circle cx="11" cy="11" r="7"/><path d="M16.5 16.5 21 21"/>',
    "chart": '<path d="M4 20V11M10 20V5M16 20v-6M21 20H3"/>',
    "map": '<path d="M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2z"/><path d="M9 4v14M15 6v14"/>',
    "file": '<path d="M14 3H6.5A1.5 1.5 0 0 0 5 4.5v15A1.5 1.5 0 0 0 6.5 21h11a1.5 1.5 0 0 0 1.5-1.5V8z"/><path d="M14 3v5h5"/>',
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "send": '<path d="M21 3 10.5 13.5"/><path d="M21 3 14.5 21l-4-7.5L3 9.5z"/>',
    "bolt": '<path d="M13 2 4.5 13.5H11L10 22l8.5-11.5H12z"/>',
    "chev": '<path d="m6 9 6 6 6-6"/>',
    "mic": '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3.2 3.6 3.2 14.4 0 18M12 3c-3.2 3.6-3.2 14.4 0 18"/>',
    "check": '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    "lock": '<rect x="5" y="11" width="14" height="10" rx="2.2"/><path d="M8 11V7.5a4 4 0 0 1 8 0V11"/>',
    "route": '<circle cx="6" cy="19" r="2.2"/><circle cx="18" cy="5" r="2.2"/><path d="M8.2 19H15a3.5 3.5 0 0 0 0-7H9a3.5 3.5 0 0 1 0-7h6.8"/>',
}


def icon(name, cls="ic", sw=2):
    return (f'<svg class="{cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">'
            f'{ICON_PATHS[name]}</svg>')


# star mark: eight hand-drawn rays
def star(cls="star", id_=""):
    rays = []
    lens = [10.6, 9.4, 10.2, 9.0, 10.8, 9.6, 10.0, 9.2]
    import math
    for i, L in enumerate(lens):
        a = math.radians(i * 45 + (3 if i % 2 else -2))
        x1, y1 = 12 + 2.2 * math.cos(a), 12 + 2.2 * math.sin(a)
        x2, y2 = 12 + L * math.cos(a), 12 + L * math.sin(a)
        rays.append(f'M{x1:.2f} {y1:.2f}L{x2:.2f} {y2:.2f}')
    idattr = f' id="{id_}"' if id_ else ""
    return (f'<svg{idattr} class="{cls}" viewBox="0 0 24 24" fill="none" stroke="{ACCENT}" '
            f'stroke-width="2.6" stroke-linecap="round"><path d="{"".join(rays)}"/></svg>')


LOGO_PATHS = (ROOT / "assets/img/logo.svg").read_text()
LOGO_PATHS = "".join(re.findall(r"<path[^>]*/>", LOGO_PATHS, re.S))


def logo(cls="mark", id_=""):
    idattr = f' id="{id_}"' if id_ else ""
    return (f'<svg{idattr} class="{cls}" viewBox="0 0 500 500"><g transform="translate(0,500) '
            f'scale(0.1,-0.1)" fill="currentColor">{LOGO_PATHS}</g></svg>')


ARROW = ('<svg class="cur-arrow" viewBox="0 0 28 40"><path d="M2.5 2.5v29.2l7.3-6.9 4.9 11.6 '
         '4.6-2-4.8-11.3h9.9z" fill="#14100c" stroke="#ffffff" stroke-width="2.2" '
         'stroke-linejoin="round"/></svg>')
HAND = ('<svg class="cur-hand" viewBox="0 0 34 38"><path d="M12 4.2a2.6 2.6 0 0 1 5.2 0V15.5'
        'h.4v-2.6a2.6 2.6 0 0 1 5.2 0v3.4a2.6 2.6 0 0 1 5.2 0v2.4a2.5 2.5 0 0 1 4.6 1.3v6.4'
        'c0 5.6-3.8 9.6-9.6 9.6h-3.3c-3.6 0-5.8-1.6-7.9-4.6L4.9 23.2a2.6 2.6 0 0 1 4-3.3l3.1 3.6z" '
        'fill="#ffffff" stroke="#14100c" stroke-width="2" stroke-linejoin="round"/>'
        '<path d="M17.4 16v6.5M22.6 17v5.5M27.8 19v4" stroke="#14100c" stroke-width="1.6" '
        'stroke-linecap="round"/></svg>')


def cursor(id_):
    return f'<div class="cur" id="{id_}">{ARROW}{HAND}</div>'


COMMON_CSS = f"""
@font-face {{ font-family: 'Newsreader'; src: url('assets/fonts/Newsreader-Disp600.ttf') format('truetype'); font-weight: 600; font-style: normal; }}
@font-face {{ font-family: 'ChukMono'; src: url('assets/fonts/jetbrains-mono-latin-wght.woff2') format('woff2'); font-weight: 100 800; font-style: normal; }}
#root {{ position: absolute; inset: 0; overflow: hidden; font-family: 'ChukMono', monospace; color: {INK}; }}
.serif {{ font-family: 'Newsreader', serif; font-weight: 600; letter-spacing: -0.01em; color: {INK}; }}
.mono {{ font-family: 'ChukMono', monospace; }}
.abs {{ position: absolute; }}
.ic {{ width: 1em; height: 1em; display: block; flex: none; }}
.star {{ display: block; transform-origin: 50% 50%; }}
.mark {{ display: block; }}
.surface {{ background: {SURF}; border: 2px solid {BORDER}; box-shadow: 0 8px 30px rgba(42,31,23,.08); }}
.bubble {{ background: {BUBBLE}; color: {INK}; border-radius: 28px; white-space: nowrap; }}
.word {{ display: inline-block; }}
.cur {{ position: absolute; left: 0; top: 0; width: 0; height: 0; z-index: 60; }}
.cur svg {{ position: absolute; overflow: visible; }}
.cur-arrow {{ left: -5px; top: -4px; width: 48px; height: 68px; transform-origin: 5px 4px; }}
.cur-hand {{ left: -21px; top: -5px; width: 56px; height: 62px; opacity: 0; transform-origin: 21px 5px; }}
.caret {{ display: inline-block; width: 3px; height: 1.05em; background: {ACCENT}; vertical-align: -0.16em; margin-left: 2px; }}
"""

COMMON_JS = r"""
function hfWords(sel) {
  document.querySelectorAll(sel).forEach(function (el) {
    var words = el.textContent.trim().split(/\s+/);
    el.textContent = '';
    words.forEach(function (w, i) {
      var s = document.createElement('span');
      s.className = 'word';
      s.textContent = w;
      el.appendChild(s);
      if (i < words.length - 1) el.appendChild(document.createTextNode(' '));
    });
  });
}
function hfType(tl, el, text, start, cps) {
  el.textContent = '';
  var spans = [];
  Array.from(text).forEach(function (c) {
    var s = document.createElement('span');
    s.textContent = c;
    s.style.display = 'none';
    el.appendChild(s);
    spans.push(s);
  });
  spans.forEach(function (s, i) { tl.set(s, { display: 'inline' }, start + (i + 1) / cps); });
  return start + text.length / cps;
}
function hfClick(tl, cur, t, hand) {
  var sel = cur + (hand ? ' .cur-hand' : ' .cur-arrow');
  tl.to(sel, { scale: 0.86, duration: 0.08, ease: 'power2.out' }, t);
  tl.to(sel, { scale: 1, duration: 0.14, ease: 'power2.out' }, t + 0.08);
}
function hfHand(tl, cur, t, on) {
  tl.to(cur + ' .cur-arrow', { opacity: on ? 0 : 1, duration: 0.06 }, t);
  tl.to(cur + ' .cur-hand', { opacity: on ? 1 : 0, duration: 0.06 }, t);
}
function hfHash(i, j) {
  var h = (i * 374761393 + j * 668265263) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}
"""


def scene(cid, css, body, js, dur):
    return f"""<template>
  <style>
{COMMON_CSS}
{css}
  </style>
  <div id="root" data-composition-id="{cid}" data-width="1920" data-height="1080" data-duration="{dur}">
{body}
  </div>
  <script>
{COMMON_JS}
(function () {{
  var tl = gsap.timeline({{ paused: true }});
{js}
  window.__timelines["{cid}"] = tl;
}})();
  </script>
</template>
"""


SCENES = []  # (id, start, dur)


def add(cid, start, dur, css, body, js):
    SCENES.append((cid, start, dur))
    (COMP / f"{cid}.html").write_text(scene(cid, css, body, js, dur))


# =================================================================== 01 title
add("s01", 0.0, 2.46, f"""
#s01-bg {{ position: absolute; inset: 0; background: {TAN}; }}
#s01-t {{ position: absolute; left: 0; right: 0; top: 470px; text-align: center; font-size: 110px; line-height: 1.1; }}
""", f"""
    <div id="s01-bg"></div>
    <h1 id="s01-t" class="serif">Meet Chuk Chat.</h1>
""", """
  hfWords('#s01-t');
  var w = document.querySelectorAll('#s01-t .word');
  tl.fromTo(w, { color: '#B7A285', filter: 'blur(5px)' }, { color: '#2A1F17', filter: 'blur(0px)', duration: 0.32, ease: 'power2.out', stagger: 0.12 }, 0.05);
  tl.to('#s01-t', { opacity: 1, duration: 0.01 }, 2.4);
""")

# =================================================================== 02 greeting + chips
CHIPS = [("search", "Research", 250), ("chart", "Make a chart", 320),
         ("map", "Plan a trip", 300), ("file", "Read a file", 300)]
chips_html = "".join(
    f'<div class="chip surface" id="s02-chip{i}" style="width:{w}px">{icon(ic)}<span>{t}</span></div>'
    for i, (ic, t, w) in enumerate(CHIPS))

COMPOSER_CSS = f"""
.composer {{ position: absolute; border-radius: 38px; background: {SURF}; border: 2px solid {BORDER}; box-shadow: 0 8px 30px rgba(42,31,23,.08); }}
.composer .ph {{ position: absolute; color: #9A8877; }}
.composer .txt {{ position: absolute; color: {INK}; white-space: normal; }}
.composer .send {{ position: absolute; border-radius: 50%; background: {ACCENT}; color: {SURF}; display: flex; align-items: center; justify-content: center; }}
.composer .row {{ position: absolute; display: flex; align-items: center; }}
.composer .rbtn {{ border-radius: 50%; border: 2px solid {BORDER}; display: flex; align-items: center; justify-content: center; color: {SOFT}; flex: none; }}
.composer .pill {{ display: flex; align-items: center; border: 2px solid {BORDER}; border-radius: 999px; color: {SOFT}; flex: none; }}
"""

add("s02", 2.46, 5.41, COMPOSER_CSS + f"""
#s02-cam {{ position: absolute; inset: 0; transform-origin: 960px 516px; }}
#s02-greet {{ position: absolute; left: 0; right: 0; top: 238px; display: flex; align-items: center; justify-content: center; gap: 30px; }}
#s02-greet .mark {{ width: 92px; height: 92px; color: {INK}; }}
#s02-gt {{ font-size: 84px; line-height: 1; }}
#s02-comp {{ left: 340px; top: 400px; width: 1240px; height: 233px; }}
#s02-comp .ph {{ left: 34px; top: 36px; font-size: 34px; }}
#s02-comp .send {{ right: 26px; top: 24px; width: 70px; height: 70px; font-size: 34px; }}
#s02-comp .row.l {{ left: 26px; bottom: 24px; gap: 16px; }}
#s02-comp .row.r {{ right: 26px; bottom: 24px; gap: 16px; }}
#s02-comp .rbtn {{ width: 58px; height: 58px; font-size: 28px; }}
#s02-comp .pill {{ height: 58px; padding: 0 22px; gap: 10px; font-size: 28px; }}
#s02-mode {{ background: {BUBBLE}; border-color: {BUBBLE} !important; color: {INK} !important; opacity: 0; }}
#s02-chips {{ position: absolute; left: 0; right: 0; top: 663px; display: flex; justify-content: center; gap: 24px; }}
.chip {{ height: 84px; border-radius: 22px; display: flex; align-items: center; justify-content: center; gap: 14px; font-size: 30px; color: {INK}; box-shadow: none; }}
.chip .ic {{ font-size: 30px; color: {SOFT}; }}
""", f"""
    <div id="s02-cam">
      <div id="s02-greet">{logo()}<div id="s02-gt" class="serif">What's on your mind, Lea?</div></div>
      <div id="s02-comp" class="composer">
        <div class="ph">Ask me anything</div>
        <div class="send">{icon('send')}</div>
        <div class="row l"><div class="rbtn">{icon('plus')}</div><div class="pill" id="s02-mode">{icon('map')}<span>Plan a trip</span></div></div>
        <div class="row r"><div class="pill">{icon('bolt')}<span>Fast</span>{icon('chev')}</div><div class="rbtn">{icon('mic')}</div></div>
      </div>
      <div id="s02-chips">{chips_html}</div>
    </div>
    {cursor('s02-cur')}
""", """
  hfWords('#s02-gt');
  tl.fromTo('#s02-greet .mark', { opacity: 0.35, scale: 0.7, rotation: -30 }, { opacity: 1, scale: 1, rotation: 0, duration: 0.55, ease: 'expo.out' }, 0.0);
  tl.fromTo('#s02-gt .word', { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.16, stagger: 0.07, ease: 'power2.out' }, 0.0);
  tl.fromTo('#s02-comp', { opacity: 0, scaleX: 0.3, filter: 'blur(10px)' }, { opacity: 1, scaleX: 1, filter: 'blur(0px)', duration: 0.5, ease: 'power3.out' }, 0.4);
  tl.fromTo('#s02-comp > *', { opacity: 0 }, { opacity: 1, duration: 0.2 }, 0.72);
  tl.set('#s02-mode', { opacity: 0 }, 0.72);
  tl.fromTo('.chip', { opacity: 0, y: 26, scale: 0.94 }, { opacity: 1, y: 0, scale: 1, duration: 0.45, stagger: 0.07, ease: 'expo.out' }, 0.85);
  // cursor
  tl.fromTo('#s02-cur', { x: 1980, y: 1120 }, { x: 1112, y: 712, duration: 1.0, ease: 'power2.inOut' }, 1.55);
  hfHand(tl, '#s02-cur', 2.45, true);
  tl.to('#s02-chip2', { backgroundColor: '#F1E8DA', duration: 0.12 }, 2.45);
  hfClick(tl, '#s02-cur', 2.85, true);
  tl.to('#s02-chip2', { scale: 0.96, duration: 0.08 }, 2.85);
  tl.to('#s02-chip2', { scale: 1, backgroundColor: '#EADFCF', borderColor: '#8B5A2B', duration: 0.16 }, 2.93);
  // the chip's label drops into the composer
  tl.fromTo('#s02-mode', { opacity: 0, y: 30, scale: 0.8 }, { opacity: 1, y: 0, scale: 1, duration: 0.45, ease: 'expo.out' }, 3.05);
  hfHand(tl, '#s02-cur', 3.25, false);
  tl.to('#s02-cur', { x: 1500, y: 1180, duration: 0.7, ease: 'power3.in' }, 3.3);
  // push in on the composer
  tl.fromTo('#s02-cam', { scale: 1 }, { scale: 1.2, duration: 1.6, ease: 'power2.inOut' }, 3.75);
  tl.to('#s02-chips', { opacity: 0, duration: 0.6, ease: 'power2.in' }, 4.4);
  tl.to('#s02-greet', { opacity: 0, duration: 0.6, ease: 'power2.in' }, 4.6);
""")

# =================================================================== 03 ask: type, send, sources
PROMPT = "find three cafés near kiel harbour and a walk between them"
SOURCES = [
    ("Cafés at the Kiel harbour front", "kiel-sailing-city.de"),
    ("Kiellinie: where locals get coffee", "kn-online.de"),
    ("Walk: Kiellinie to Seeburg, 2.4 km", "komoot.com"),
]
src_html = "".join(
    f'<div class="srow" id="s03-src{i}"><div class="fav">{icon("globe")}</div>'
    f'<div class="stxt"><div class="st">{t}</div><div class="sd">{d}</div></div></div>'
    for i, (t, d) in enumerate(SOURCES))

add("s03", 7.87, 7.86, COMPOSER_CSS + f"""
#s03-comp {{ left: 216px; top: 360px; width: 1488px; height: 280px; border-radius: 45px; }}
#s03-comp .ph {{ left: 42px; top: 42px; font-size: 41px; }}
#s03-comp .txt {{ left: 42px; top: 40px; width: 1310px; font-size: 41px; line-height: 58px; }}
#s03-comp .send {{ right: 32px; top: 29px; width: 84px; height: 84px; font-size: 40px; }}
#s03-comp .row.l {{ left: 32px; bottom: 29px; gap: 19px; }}
#s03-comp .row.r {{ right: 32px; bottom: 29px; gap: 19px; }}
#s03-comp .rbtn {{ width: 70px; height: 70px; font-size: 34px; }}
#s03-comp .pill {{ height: 70px; padding: 0 26px; gap: 12px; font-size: 34px; }}
#s03-mode {{ background: {BUBBLE}; border-color: {BUBBLE} !important; color: {INK} !important; }}
#s03-ub {{ position: absolute; right: 216px; top: 150px; font-size: 36px; padding: 24px 34px; opacity: 0; }}
#s03-status {{ position: absolute; left: 216px; top: 282px; display: flex; align-items: center; gap: 24px; opacity: 0; }}
#s03-status .star {{ width: 66px; height: 66px; }}
#s03-status .serif {{ font-size: 58px; }}
#s03-srcs {{ position: absolute; left: 216px; top: 410px; width: 1488px; border-radius: 32px; padding: 10px 0; opacity: 0; }}
.srow {{ display: flex; align-items: center; gap: 30px; height: 122px; padding: 0 40px; border-top: 2px solid #EFE6D9; }}
.srow:first-child {{ border-top: none; }}
.fav {{ width: 66px; height: 66px; border-radius: 50%; background: {BUBBLE}; color: {ACCENT}; display: flex; align-items: center; justify-content: center; font-size: 34px; flex: none; }}
.st {{ font-size: 34px; color: {INK}; }}
.sd {{ font-size: 28px; color: {SOFT}; margin-top: 6px; }}
""", f"""
    <div id="s03-comp" class="composer">
      <div class="ph" id="s03-ph">Ask me anything</div>
      <div class="txt"><span id="s03-typed"></span><span class="caret" id="s03-caret"></span></div>
      <div class="send" id="s03-send">{icon('send')}</div>
      <div class="row l"><div class="rbtn">{icon('plus')}</div><div class="pill" id="s03-mode">{icon('map')}<span>Plan a trip</span></div></div>
      <div class="row r"><div class="pill">{icon('bolt')}<span>Fast</span>{icon('chev')}</div><div class="rbtn">{icon('mic')}</div></div>
    </div>
    <div id="s03-ub" class="bubble">{PROMPT}</div>
    <div id="s03-status">{star(id_='s03-star')}<div class="serif">Searching the web…</div></div>
    <div id="s03-srcs" class="surface">{src_html}</div>
    {cursor('s03-cur')}
""", f"""
  tl.fromTo('#s03-comp', {{ scale: 1.03 }}, {{ scale: 1, duration: 0.45, ease: 'power3.out' }}, 0);
  tl.set('#s03-ph', {{ opacity: 0 }}, 0.3);
  var end = hfType(tl, document.getElementById('s03-typed'), {PROMPT!r}, 0.3, 18);
  tl.fromTo('#s03-caret', {{ opacity: 1 }}, {{ opacity: 0, duration: 0.01, repeat: 9, yoyo: true, repeatDelay: 0.42 }}, end + 0.05);
  // cursor to send
  tl.fromTo('#s03-cur', {{ x: 1990, y: 1100 }}, {{ x: 1632, y: 438, duration: 0.95, ease: 'power2.inOut' }}, 3.55);
  hfHand(tl, '#s03-cur', 4.4, true);
  tl.to('#s03-send', {{ backgroundColor: '#76491F', duration: 0.1 }}, 4.4);
  hfClick(tl, '#s03-cur', 4.78, true);
  tl.to('#s03-send', {{ scale: 0.9, duration: 0.08 }}, 4.78);
  tl.to('#s03-send', {{ scale: 1, duration: 0.14 }}, 4.86);
  // sent: composer leaves, the message becomes the bubble
  tl.to('#s03-comp', {{ y: 140, opacity: 0, duration: 0.3, ease: 'power3.in' }}, 4.98);
  tl.to('#s03-cur', {{ x: 1760, y: 1160, duration: 0.5, ease: 'power3.in' }}, 4.98);
  tl.fromTo('#s03-ub', {{ opacity: 0, y: 220, scale: 0.92, filter: 'blur(8px)' }}, {{ opacity: 1, y: 0, scale: 1, filter: 'blur(0px)', duration: 0.55, ease: 'expo.out' }}, 5.05);
  tl.fromTo('#s03-status', {{ opacity: 0, filter: 'blur(8px)' }}, {{ opacity: 1, filter: 'blur(0px)', duration: 0.2, ease: 'power2.out' }}, 5.3);
  tl.fromTo('#s03-star', {{ rotation: 0, scale: 0.6 }}, {{ rotation: 180, scale: 1, duration: 0.6, ease: 'expo.out' }}, 5.3);
  tl.to('#s03-star', {{ rotation: 420, duration: 2.0, ease: 'none' }}, 5.9);
  tl.to('#s03-star', {{ scale: 0.82, duration: 0.33, yoyo: true, repeat: 5, ease: 'sine.inOut' }}, 5.9);
  tl.fromTo('#s03-srcs', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'expo.out' }}, 5.5);
  tl.fromTo('.srow', {{ opacity: 0, x: -24 }}, {{ opacity: 1, x: 0, duration: 0.4, stagger: 0.12, ease: 'expo.out' }}, 5.58);
""")

# =================================================================== 04 map
add("s04", 15.73, 3.86, f"""
#s04-cam {{ position: absolute; inset: 0; transform-origin: 960px 620px; }}
#s04-card {{ position: absolute; left: 210px; top: 150px; width: 1500px; height: 780px; border-radius: 36px; overflow: hidden; }}
#s04-bar {{ position: absolute; left: 0; right: 0; top: 0; height: 100px; display: flex; align-items: center; gap: 18px; padding: 0 40px; font-size: 34px; border-bottom: 2px solid {BORDER}; background: {SURF}; }}
#s04-bar .ic {{ font-size: 38px; color: {ACCENT}; }}
#s04-bar .dot {{ color: {SOFT}; }}
#s04-map {{ position: absolute; left: 0; top: 100px; width: 1500px; height: 680px; }}
.pin {{ position: absolute; width: 0; height: 0; }}
.pin svg {{ position: absolute; left: -30px; top: -78px; width: 60px; height: 80px; transform-origin: 30px 78px; }}
.plab {{ position: absolute; white-space: nowrap; font-size: 30px; padding: 12px 20px; border-radius: 16px; background: {SURF}; border: 2px solid {BORDER}; color: {INK}; }}
""", f"""
    <div id="s04-cam">
      <div id="s04-card" class="surface">
        <div id="s04-bar">{icon('route')}<span>3 cafés</span><span class="dot">·</span><span>2.4 km walk</span><span class="dot">·</span><span>32 min</span></div>
        <svg id="s04-map" viewBox="0 0 1500 680">
          <rect width="1500" height="680" fill="#F3ECE0"/>
          <path d="M560 680C640 520 820 420 980 330S1240 160 1300 0H1500V680Z" fill="#D5DDDB"/>
          <path d="M560 680C640 520 820 420 980 330S1240 160 1300 0" fill="none" stroke="#C9D2CF" stroke-width="6"/>
          <path d="M120 120h260v170H120zM180 380h190v140H180zM640 90h220v140H640z" fill="#E6E2CE"/>
          <g fill="none" stroke="#FFFFFF" stroke-linecap="round">
            <path d="M0 330C200 320 340 300 470 250S700 160 760 0" stroke-width="16"/>
            <path d="M0 560H520" stroke-width="12"/><path d="M300 680V0" stroke-width="12"/>
            <path d="M0 200H600" stroke-width="10"/><path d="M520 680C560 500 600 420 640 340" stroke-width="10"/>
            <path d="M100 680V420M420 0V130M900 0V180M1000 0C960 100 940 160 900 220" stroke-width="8"/>
          </g>
          <path id="s04-route" pathLength="1" d="M430 556C500 520 560 470 640 430S760 380 800 352 920 280 980 250 1060 200 1090 176" fill="none" stroke="{ACCENT}" stroke-width="9" stroke-linecap="round" stroke-dasharray="1 1.2" stroke-dashoffset="1.1"/>
        </svg>
        <div class="pin" id="s04-p0" style="left:430px;top:656px"><svg viewBox="0 0 60 80"><path d="M30 78C30 78 4 46 4 28a26 26 0 0 1 52 0c0 18-26 50-26 50z" fill="{ACCENT}"/><circle cx="30" cy="28" r="10" fill="#FFFDF9"/></svg></div>
        <div class="pin" id="s04-p1" style="left:800px;top:452px"><svg viewBox="0 0 60 80"><path d="M30 78C30 78 4 46 4 28a26 26 0 0 1 52 0c0 18-26 50-26 50z" fill="{ACCENT}"/><circle cx="30" cy="28" r="10" fill="#FFFDF9"/></svg></div>
        <div class="pin" id="s04-p2" style="left:1090px;top:276px"><svg viewBox="0 0 60 80"><path d="M30 78C30 78 4 46 4 28a26 26 0 0 1 52 0c0 18-26 50-26 50z" fill="{ACCENT}"/><circle cx="30" cy="28" r="10" fill="#FFFDF9"/></svg></div>
        <div class="plab" id="s04-l0" style="left:150px;top:680px">Rösterei am Hafen</div>
        <div class="plab" id="s04-l1" style="left:846px;top:392px">Café Kiellinie</div>
        <div class="plab" id="s04-l2" style="left:640px;top:196px">Strandcafé Seeburg</div>
      </div>
    </div>
""", """
  tl.fromTo('#s04-card', { opacity: 0.4, y: 60, filter: 'blur(10px)' }, { opacity: 1, y: 0, filter: 'blur(0px)', duration: 0.5, ease: 'expo.out' }, 0);
  ['#s04-p0', '#s04-p1', '#s04-p2'].forEach(function (p, i) {
    tl.fromTo(p + ' svg', { y: -60, scale: 0.6, opacity: 0 }, { y: 0, scale: 1, opacity: 1, duration: 0.45, ease: 'back.out(1.6)' }, 0.45 + i * 0.18);
    tl.fromTo('#s04-l' + i, { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.2 }, 0.6 + i * 0.18);
  });
  tl.fromTo('#s04-route', { attr: { 'stroke-dashoffset': 1.1 } }, { attr: { 'stroke-dashoffset': 0 }, duration: 1.4, ease: 'power2.inOut' }, 1.0);
  tl.fromTo('#s04-cam', { scale: 1 }, { scale: 1.3, duration: 2.2, ease: 'power2.inOut' }, 1.55);
""")

# =================================================================== 05 encryption (colour block)
CIPHER = "U2FsdGVkX1+7QkZ0b3J2aW5uQ2h1a0NoYXQ4fH9yZWFkb25seVNlYWxlZA"[:len(PROMPT)]
add("s05", 19.59, 7.93, f"""
#s05-flood {{ position: absolute; inset: 0; background: {BROWN}; }}
#s05-b {{ position: absolute; left: 0; right: 0; top: 300px; display: flex; justify-content: center; }}
#s05-bub {{ font-size: 40px; padding: 30px 40px; border: 2px solid transparent; }}
#s05-lock {{ position: absolute; left: 912px; top: 170px; width: 96px; height: 96px; border-radius: 50%; background: {CANVAS}; color: {BROWN}; display: flex; align-items: center; justify-content: center; font-size: 50px; opacity: 0; }}
#s05-lines {{ position: absolute; left: 0; right: 0; top: 520px; text-align: center; }}
#s05-lines .serif {{ color: {CANVAS}; font-size: 92px; line-height: 1.16; }}
#s05-de {{ position: absolute; left: 0; right: 0; top: 872px; display: flex; justify-content: center; align-items: center; gap: 16px; font-size: 30px; color: #E7DACA; opacity: 0; }}
#s05-de svg {{ width: 34px; height: 34px; flex: none; }}
""", f"""
    <div id="s05-all" style="position:absolute;inset:0">
    <div id="s05-flood"></div>
    <div id="s05-b"><div id="s05-bub" class="bubble"><span id="s05-txt">{PROMPT}</span></div></div>
    <div id="s05-lock">{icon('lock')}</div>
    <div id="s05-lines"><div class="serif" id="s05-l1">Encrypted on your device.</div><div class="serif" id="s05-l2">Only you can read it.</div></div>
    <div id="s05-de"><svg viewBox="0 0 34 34"><defs><clipPath id="s05-fc"><circle cx="17" cy="17" r="16"/></clipPath></defs><g clip-path="url(#s05-fc)"><rect width="34" height="12" fill="#000000"/><rect y="11" width="34" height="12" fill="#DD0000"/><rect y="22" width="34" height="12" fill="#FFCE00"/></g><circle cx="17" cy="17" r="16" fill="none" stroke="#E7DACA" stroke-width="1.5"/></svg><span>Made in Germany</span></div>
    </div>
""", f"""
  var plain = {PROMPT!r}, cipher = {CIPHER!r};
  var pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  var el = document.getElementById('s05-txt');
  el.textContent = '';
  var spans = Array.from(plain).map(function (c) {{ var s = document.createElement('span'); s.textContent = c; el.appendChild(s); return s; }});
  function render(t) {{
    spans.forEach(function (s, i) {{
      var ti = i * 0.024;
      var c;
      if (t <= 0 || t < ti) c = plain[i];
      else if (t < ti + 0.2) c = pool[Math.floor(hfHash(i, Math.floor(t * 30)) * pool.length)];
      else c = cipher[i];
      if (s.textContent !== c) s.textContent = c;
    }});
  }}
  var prox = {{ t: 0 }};
  render(0);
  // colour flood
  tl.fromTo('#s05-flood', {{ clipPath: 'circle(0% at 50% 33%)' }}, {{ clipPath: 'circle(120% at 50% 33%)', duration: 0.55, ease: 'power2.inOut' }}, 0.2);
  tl.fromTo('#s05-bub', {{ scale: 1.04 }}, {{ scale: 1, duration: 0.5, ease: 'power3.out' }}, 0);
  // scramble
  tl.fromTo(prox, {{ t: 0 }}, {{ t: 1.8, duration: 1.8, ease: 'none', onUpdate: function () {{ render(prox.t); }} }}, 1.0);
  tl.to('#s05-bub', {{ backgroundColor: '#46302A', color: '#F4EEE4', borderColor: '#7A5A48', duration: 1.4, ease: 'power1.inOut' }}, 1.1);
  tl.fromTo('#s05-lock', {{ opacity: 0, y: 30, scale: 0.7 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.5, ease: 'back.out(1.5)' }}, 2.75);
  hfWords('#s05-l1'); hfWords('#s05-l2');
  tl.fromTo('#s05-l1 .word', {{ opacity: 0, filter: 'blur(6px)' }}, {{ opacity: 1, filter: 'blur(0px)', duration: 0.16, stagger: 0.08, ease: 'power2.out' }}, 3.2);
  tl.fromTo('#s05-l2 .word', {{ opacity: 0, filter: 'blur(6px)' }}, {{ opacity: 1, filter: 'blur(0px)', duration: 0.16, stagger: 0.08, ease: 'power2.out' }}, 3.75);
  tl.fromTo('#s05-de', {{ opacity: 0, filter: 'blur(6px)' }}, {{ opacity: 1, filter: 'blur(0px)', duration: 0.3 }}, 4.9);
  // the whole brown panel wipes up off frame
  tl.to('#root > *', {{ y: -1100, duration: 0.5, ease: 'power3.in' }}, 7.42);
""")

# =================================================================== 06 follow-ups + pdf
add("s06", 27.52, 5.90, f"""
.fu {{ position: absolute; right: 216px; font-size: 44px; padding: 22px 36px; }}
#s06-b1 {{ top: 270px; }}
#s06-b2 {{ top: 396px; }}
#s06-pdf {{ position: absolute; right: 216px; top: 528px; width: 640px; height: 132px; border-radius: 26px; display: flex; align-items: center; gap: 26px; padding: 0 30px; }}
#s06-pdf .pi {{ width: 76px; height: 86px; border-radius: 14px; background: {BUBBLE}; color: {ACCENT}; display: flex; align-items: center; justify-content: center; font-size: 44px; flex: none; }}
#s06-pdf .pn {{ font-size: 34px; color: {INK}; }}
#s06-pdf .ps {{ font-size: 28px; color: {SOFT}; margin-top: 6px; }}
#s06-star {{ position: absolute; left: 216px; top: 760px; width: 74px; height: 74px; opacity: 0; }}
""", f"""
    <div class="fu bubble" id="s06-b1"><span id="s06-t1"></span><span class="caret" id="s06-c1"></span></div>
    <div class="fu bubble" id="s06-b2"><span id="s06-t2"></span><span class="caret" id="s06-c2"></span></div>
    <div id="s06-pdfw" class="abs" style="inset:0"><div id="s06-pdf" class="surface"><div class="pi">{icon('file')}</div><div><div class="pn">bank-statement.pdf</div><div class="ps">PDF · 214 KB</div></div></div></div>
    {star(id_='s06-star')}
    {cursor('s06-cur')}
""", """
  tl.fromTo('#s06-b1', { opacity: 0.4, scale: 0.9, transformOrigin: '100% 50%' }, { opacity: 1, scale: 1, duration: 0.3, ease: 'expo.out' }, 0.0);
  var e1 = hfType(tl, document.getElementById('s06-t1'), 'actually one more thing', 0.3, 18);
  tl.set('#s06-c1', { opacity: 0 }, e1 + 0.3);
  tl.set('#s06-b2', { opacity: 0 }, 0);
  tl.fromTo('#s06-b2', { opacity: 0, scale: 0.9, transformOrigin: '100% 50%' }, { opacity: 1, scale: 1, duration: 0.3, ease: 'expo.out' }, 1.75);
  var e2 = hfType(tl, document.getElementById('s06-t2'), 'what did i spend on coffee this month?', 1.9, 18);
  tl.set('#s06-c2', { opacity: 0 }, e2 + 0.35);
  // cursor drags the PDF in from the lower right
  tl.fromTo('#s06-pdfw', { x: 760, y: 560, rotation: 4, opacity: 0 }, { x: 760, y: 560, rotation: 4, opacity: 1, duration: 0.01 }, 3.55);
  tl.fromTo('#s06-cur', { x: 1980, y: 1240 }, { x: 1980, y: 1240, duration: 0.01 }, 0);
  tl.to('#s06-pdfw', { x: 0, y: 0, rotation: 0, duration: 0.8, ease: 'power2.inOut' }, 3.6);
  tl.to('#s06-cur', { x: 1300, y: 640, duration: 0.8, ease: 'power2.inOut' }, 3.6);
  hfClick(tl, '#s06-cur', 4.4, false);
  tl.fromTo('#s06-pdf', { scale: 1.03 }, { scale: 1, duration: 0.3, ease: 'power3.out' }, 4.4);
  tl.to('#s06-cur', { x: 1560, y: 1180, duration: 0.6, ease: 'power3.in' }, 4.6);
  tl.fromTo('#s06-star', { opacity: 0, scale: 0.5, rotation: -40 }, { opacity: 1, scale: 1, rotation: 0, duration: 0.5, ease: 'expo.out' }, 4.75);
  tl.to('#s06-star', { rotation: 200, duration: 0.6, ease: 'none' }, 5.25);
""")

# =================================================================== 07 progress -> chart
STEPS = ["Read the PDF", "Find coffee", "Add it up"]
steps_html = "".join(
    f'<div class="prow" id="s07-r{i}"><div class="pst"><div class="pnum">{i+1}</div>'
    f'<svg class="spin" viewBox="0 0 52 52"><circle cx="26" cy="26" r="22" fill="none" stroke="{ACCENT}" stroke-width="4" stroke-linecap="round" stroke-dasharray="40 200"/></svg>'
    f'<div class="pdone">{icon("check", sw=2.6)}</div></div><div class="ptx">{t}</div></div>'
    for i, t in enumerate(STEPS))
WEEKS = [("Week 1", 9.60), ("Week 2", 12.40), ("Week 3", 8.30), ("Week 4", 12.50)]
bars_html = "".join(
    f'<div class="bcol"><div class="bval">€{v:.2f}</div><div class="bar" id="s07-bar{i}" '
    f'style="height:{v/12.5*290:.0f}px;background:{ACCENT if i == 3 else "#D3BEA3"}"></div>'
    f'<div class="blab">{w}</div></div>'
    for i, (w, v) in enumerate(WEEKS))

add("s07", 33.42, 5.92, f"""
#s07-prog {{ position: absolute; left: 460px; top: 250px; width: 1000px; border-radius: 34px; padding: 26px 44px 22px; }}
#s07-prog .ph {{ font-size: 30px; color: {SOFT}; display: flex; justify-content: space-between; align-items: center; height: 56px; }}
#s07-prog .ph .ic {{ font-size: 32px; }}
.prow {{ display: flex; align-items: center; gap: 30px; height: 104px; }}
.pst {{ position: relative; width: 56px; height: 56px; flex: none; }}
.pnum {{ position: absolute; inset: 0; border-radius: 50%; border: 3px solid {BORDER}; display: flex; align-items: center; justify-content: center; font-size: 28px; color: {SOFT}; }}
.spin {{ position: absolute; left: 2px; top: 2px; width: 52px; height: 52px; opacity: 0; transform-origin: 50% 50%; }}
.pdone {{ position: absolute; inset: 0; border-radius: 50%; background: {ACCENT}; color: {SURF}; display: flex; align-items: center; justify-content: center; font-size: 34px; opacity: 0; }}
.ptx {{ font-size: 42px; color: {INK}; }}
#s07-chart {{ position: absolute; left: 360px; top: 170px; width: 1200px; height: 740px; border-radius: 36px; padding: 44px 60px; opacity: 0; }}
#s07-chart .ch {{ font-size: 30px; color: {SOFT}; }}
#s07-chart .big {{ display: flex; align-items: baseline; gap: 22px; margin-top: 14px; }}
#s07-num {{ font-size: 104px; color: {INK}; font-weight: 600; letter-spacing: -0.02em; }}
#s07-chart .big span.u {{ font-size: 40px; color: {SOFT}; }}
#s07-bars {{ position: absolute; left: 60px; right: 60px; bottom: 44px; height: 420px; display: flex; justify-content: space-around; align-items: flex-end; border-bottom: 0; }}
.bcol {{ display: flex; flex-direction: column; align-items: center; width: 180px; }}
.bval {{ font-size: 30px; color: {INK}; margin-bottom: 12px; }}
.bar {{ width: 150px; border-radius: 16px 16px 6px 6px; transform-origin: 50% 100%; }}
.blab {{ font-size: 28px; color: {SOFT}; margin-top: 16px; }}
""", f"""
    <div id="s07-prog" class="surface"><div class="ph"><span>Progress</span>{icon('chev')}</div>{steps_html}</div>
    <div id="s07-chart" class="surface">
      <div class="ch">Coffee · October</div>
      <div class="big"><span id="s07-num">€42.80</span><span class="u">this month</span></div>
      <div id="s07-bars">{bars_html}</div>
    </div>
""", """
  tl.fromTo('#s07-prog', { opacity: 0.4, y: 40, filter: 'blur(8px)' }, { opacity: 1, y: 0, filter: 'blur(0px)', duration: 0.45, ease: 'expo.out' }, 0);
  [0.3, 0.85, 1.4].forEach(function (t, i) {
    var r = '#s07-r' + i;
    tl.to(r + ' .pnum', { opacity: 0, duration: 0.1 }, t);
    tl.fromTo(r + ' .spin', { opacity: 0, rotation: 0 }, { opacity: 1, rotation: 0, duration: 0.1 }, t);
    tl.to(r + ' .spin', { rotation: 540, duration: 0.55, ease: 'none' }, t);
    tl.to(r + ' .spin', { opacity: 0, duration: 0.08 }, t + 0.5);
    tl.fromTo(r + ' .pdone', { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.3, ease: 'back.out(2)' }, t + 0.5);
  });
  // blur swap to the result
  tl.to('#s07-prog', { opacity: 0, filter: 'blur(8px)', duration: 0.18, ease: 'power2.in' }, 2.3);
  tl.fromTo('#s07-chart', { opacity: 0, scale: 0.96, filter: 'blur(10px)' }, { opacity: 1, scale: 1, filter: 'blur(0px)', duration: 0.45, ease: 'expo.out' }, 2.45);
  var num = document.getElementById('s07-num'), prox = { v: 0 };
  tl.fromTo(prox, { v: 0 }, { v: 42.8, duration: 0.9, ease: 'power3.out', onUpdate: function () { num.textContent = '€' + prox.v.toFixed(2); } }, 2.55);
  tl.fromTo('.bar', { scaleY: 0 }, { scaleY: 1, duration: 0.6, stagger: 0.08, ease: 'expo.out' }, 2.7);
  tl.fromTo('.bval, .blab', { opacity: 0 }, { opacity: 1, duration: 0.25, stagger: 0.04 }, 2.9);
""")

# =================================================================== 08 models
MODELS = [("deepseek", "DeepSeek V4 Pro"), ("moonshot", "Kimi K3"), ("zai", "GLM 5.3"),
          ("qwen", "Qwen3.8"), ("minimax", "MiniMax M3"), ("mistral", "Mistral Small 4")]
rows_html = "".join(
    f'<div class="mrow" id="s08-m{i}"><img src="assets/logos/{lg}.svg" alt=""/><span>{n}</span>'
    f'<div class="mchk" id="s08-k{i}">{icon("check", sw=2.6)}</div></div>'
    for i, (lg, n) in enumerate(MODELS))

add("s08", 39.34, 5.89, COMPOSER_CSS + f"""
#s08-comp {{ left: 260px; top: 560px; width: 1400px; height: 230px; border-radius: 40px; }}
#s08-comp .ph {{ left: 44px; top: 42px; font-size: 40px; }}
#s08-comp .send {{ right: 30px; top: 28px; width: 80px; height: 80px; font-size: 38px; }}
#s08-comp .row.l {{ left: 30px; bottom: 28px; }}
#s08-comp .rbtn {{ width: 68px; height: 68px; font-size: 32px; }}
#s08-pill {{ position: absolute; right: 30px; bottom: 26px; height: 74px; padding: 0 26px; gap: 14px; font-size: 34px; color: {INK} !important; background: {SURF}; }}
#s08-pill img {{ width: 40px; height: 40px; }}
#s08-pill .ic {{ font-size: 30px; color: {SOFT}; }}
#s08-pill .nm {{ position: relative; height: 74px; display: flex; align-items: center; }}
#s08-pill .nm span {{ white-space: nowrap; }}
#s08-list {{ position: absolute; left: 856px; top: 112px; width: 760px; border-radius: 30px; padding: 12px; transform-origin: 90% 100%; opacity: 0; }}
.mrow {{ position: relative; display: flex; align-items: center; gap: 24px; height: 86px; padding: 0 26px; border-radius: 18px; font-size: 36px; color: {INK}; background-color: rgba(241,232,218,0); }}
.mrow img {{ width: 46px; height: 46px; flex: none; }}
.mchk {{ position: absolute; right: 26px; top: 26px; font-size: 34px; color: {ACCENT}; opacity: 0; }}
#s08-line {{ position: absolute; left: 0; right: 0; top: 250px; text-align: center; font-size: 96px; line-height: 1.1; }}
""", f"""
    <div id="s08-line" class="serif">Every open model. One price.</div>
    <div id="s08-comp" class="composer">
      <div class="ph">Ask me anything</div>
      <div class="send">{icon('send')}</div>
      <div class="row l"><div class="rbtn">{icon('plus')}</div></div>
      <div class="pill" id="s08-pill"><img id="s08-pl0" src="assets/logos/deepseek.svg" alt=""/><img id="s08-pl1" src="assets/logos/moonshot.svg" alt="" style="display:none"/><span class="nm"><span id="s08-pn0">DeepSeek V4 Pro</span><span id="s08-pn1" style="display:none">Kimi K3</span></span>{icon('chev')}</div>
    </div>
    <div id="s08-list" class="surface">{rows_html}</div>
    {cursor('s08-cur')}
""", """
  tl.set('#s08-k0', { opacity: 1 }, 0);
  tl.fromTo('#s08-comp', { opacity: 0.4, y: 50, filter: 'blur(8px)' }, { opacity: 1, y: 0, filter: 'blur(0px)', duration: 0.45, ease: 'expo.out' }, 0);
  tl.fromTo('#s08-line', { opacity: 0 }, { opacity: 0, duration: 0.01 }, 0);
  tl.fromTo('#s08-cur', { x: 1980, y: 1120 }, { x: 1360, y: 714, duration: 0.85, ease: 'power2.inOut' }, 0.25);
  hfHand(tl, '#s08-cur', 1.0, true);
  tl.to('#s08-pill', { backgroundColor: '#F1E8DA', duration: 0.1 }, 1.0);
  hfClick(tl, '#s08-cur', 1.2, true);
  // pill becomes the menu
  tl.fromTo('#s08-list', { opacity: 0, scale: 0.4, filter: 'blur(8px)' }, { opacity: 1, scale: 1, filter: 'blur(0px)', duration: 0.35, ease: 'power3.out' }, 1.25);
  tl.fromTo('.mrow', { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.3, stagger: 0.035, ease: 'expo.out' }, 1.3);
  hfHand(tl, '#s08-cur', 1.45, false);
  tl.to('#s08-cur', { x: 1200, y: 290, duration: 0.7, ease: 'power2.inOut' }, 1.5);
  tl.to('#s08-m1', { backgroundColor: '#F1E8DA', duration: 0.1 }, 2.15);
  hfHand(tl, '#s08-cur', 2.15, true);
  hfClick(tl, '#s08-cur', 2.45, true);
  tl.to('#s08-k0', { opacity: 0, duration: 0.1 }, 2.5);
  tl.fromTo('#s08-k1', { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.25, ease: 'back.out(2)' }, 2.5);
  // the menu folds back into the pill, which now says Kimi K3
  tl.to('#s08-list', { opacity: 0, scale: 0.4, filter: 'blur(8px)', duration: 0.28, ease: 'power3.in' }, 2.8);
  tl.set('#s08-pl0, #s08-pn0', { display: 'none' }, 3.0);
  tl.set('#s08-pl1, #s08-pn1', { display: 'block' }, 3.0);
  tl.to('#s08-pill', { backgroundColor: '#FFFDF9', duration: 0.1 }, 3.0);
  tl.fromTo('#s08-pill', { scale: 1.08 }, { scale: 1, duration: 0.35, ease: 'power3.out' }, 3.0);
  hfHand(tl, '#s08-cur', 2.85, false);
  tl.to('#s08-cur', { x: 1700, y: 1160, duration: 0.6, ease: 'power3.in' }, 2.9);
  hfWords('#s08-line');
  tl.set('#s08-line', { opacity: 1 }, 3.05);
  tl.fromTo('#s08-line .word', { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.16, stagger: 0.08, ease: 'power2.out' }, 3.1);
""")

# =================================================================== 09 connectors
CONN = [("notion", "Notion"), ("github", "GitHub"), ("google-calendar", "Google Calendar"),
        ("gmail", "Gmail"), ("slack", "Slack"), ("todoist", "Todoist")]
tiles_html = "".join(
    f'<div class="tile surface" id="s09-t{i}"><img src="assets/logos/{lg}.svg" alt=""/><span>{n}</span>'
    + (f'<div class="tok" id="s09-ok">{icon("check", sw=2.8)}</div>' if i == 0 else "") + '</div>'
    for i, (lg, n) in enumerate(CONN))

add("s09", 45.23, 3.93, f"""
#s09-h {{ position: absolute; left: 0; right: 0; top: 150px; text-align: center; font-size: 84px; line-height: 1.1; }}
#s09-grid {{ position: absolute; left: 394px; top: 330px; width: 1132px; display: grid; grid-template-columns: repeat(3, 356px); gap: 32px; }}
.tile {{ position: relative; height: 250px; border-radius: 30px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 26px; font-size: 32px; color: {INK}; }}
.tile img {{ width: 104px; height: 104px; }}
.tok {{ position: absolute; right: 18px; top: 18px; width: 52px; height: 52px; border-radius: 50%; background: {ACCENT}; color: {SURF}; display: flex; align-items: center; justify-content: center; font-size: 32px; opacity: 0; }}
""", f"""
    <div id="s09-h" class="serif">Connect the tools you already use.</div>
    <div id="s09-grid">{tiles_html}</div>
    {cursor('s09-cur')}
""", """
  tl.fromTo('.tile', { opacity: 0.3, scale: 0.82, y: 30 }, { opacity: 1, scale: 1, y: 0, duration: 0.5, stagger: 0.05, ease: 'back.out(1.4)' }, 0.0);
  hfWords('#s09-h');
  tl.fromTo('#s09-h .word', { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.16, stagger: 0.07, ease: 'power2.out' }, 0.55);
  tl.fromTo('#s09-cur', { x: 1980, y: 1150 }, { x: 688, y: 452, duration: 1.0, ease: 'power2.inOut' }, 1.2);
  hfHand(tl, '#s09-cur', 2.05, true);
  tl.to('#s09-t0', { backgroundColor: '#F7F0E5', duration: 0.1 }, 2.05);
  hfClick(tl, '#s09-cur', 2.35, true);
  tl.to('#s09-t0', { scale: 0.97, duration: 0.08 }, 2.35);
  tl.to('#s09-t0', { scale: 1, borderColor: '#8B5A2B', duration: 0.16 }, 2.43);
  tl.fromTo('#s09-ok', { opacity: 0, scale: 0.4 }, { opacity: 1, scale: 1, duration: 0.35, ease: 'back.out(2)' }, 2.5);
  hfHand(tl, '#s09-cur', 2.75, false);
  tl.to('#s09-cur', { x: 300, y: 1180, duration: 0.6, ease: 'power3.in' }, 2.8);
""")

# =================================================================== 10 everywhere
mini_bars = "".join(f'<div style="height:{v/12.5*100:.0f}%;background:{ACCENT if i == 3 else "#D3BEA3"}"></div>'
                    for i, (_, v) in enumerate(WEEKS))
add("s10", 49.16, 3.44, f"""
#s10-cam {{ position: absolute; inset: 0; transform-origin: 960px 540px; }}
#s10-desk {{ position: absolute; left: 110px; top: 140px; width: 1290px; height: 800px; border-radius: 26px; overflow: hidden; background: {SURF}; }}
.tbar {{ position: absolute; left: 0; right: 0; top: 0; height: 58px; border-bottom: 2px solid {BORDER}; display: flex; align-items: center; gap: 12px; padding: 0 24px; background: #FAF5EE; }}
.tbar i {{ width: 16px; height: 16px; border-radius: 50%; background: {BORDER}; display: block; }}
.side {{ position: absolute; left: 0; top: 58px; bottom: 0; width: 320px; background: #F7F1E8; border-right: 2px solid {BORDER}; padding: 28px 18px; }}
.side .sh {{ display: flex; align-items: center; gap: 14px; font-size: 30px; padding: 0 12px 24px; }}
.side .sh .mark {{ width: 40px; height: 40px; color: {INK}; }}
.side .it {{ font-size: 28px; color: {SOFT}; padding: 16px 14px; border-radius: 14px; white-space: nowrap; }}
.side .it.on {{ background: {BUBBLE}; color: {INK}; }}
.main {{ position: absolute; left: 320px; right: 70px; top: 58px; bottom: 0; padding: 40px 48px; }}
.main .ub {{ position: absolute; right: 48px; top: 40px; font-size: 28px; padding: 18px 26px; border-radius: 22px; }}
.main .ans {{ position: absolute; left: 48px; top: 150px; display: flex; gap: 18px; align-items: flex-start; font-size: 30px; line-height: 1.4; width: 820px; }}
.main .ans .star {{ width: 44px; height: 44px; flex: none; margin-top: 2px; }}
.mchart {{ position: absolute; left: 110px; top: 270px; width: 560px; height: 260px; border-radius: 22px; padding: 26px 30px; }}
.mchart .mb {{ position: absolute; left: 30px; right: 30px; bottom: 26px; height: 150px; display: flex; gap: 30px; align-items: flex-end; }}
.mchart .mb div {{ flex: 1; border-radius: 10px 10px 4px 4px; }}
.mchart .mt {{ font-size: 28px; color: {SOFT}; }}
.main .rc {{ position: absolute; left: 48px; right: 48px; bottom: 34px; height: 96px; border-radius: 30px; border: 2px solid {BORDER}; font-size: 28px; color: #9A8877; display: flex; align-items: center; padding: 0 30px; }}
.main .rc .snd {{ position: absolute; right: 16px; top: 13px; width: 66px; height: 66px; border-radius: 50%; background: {ACCENT}; color: {SURF}; display: flex; align-items: center; justify-content: center; font-size: 30px; }}
#s10-phone {{ position: absolute; left: 1330px; top: 110px; width: 470px; height: 880px; border-radius: 64px; background: {INK}; padding: 14px; }}
#s10-phone .scr {{ position: relative; width: 100%; height: 100%; border-radius: 52px; background: {SURF}; overflow: hidden; }}
#s10-phone .ph-h {{ position: absolute; left: 0; right: 0; top: 0; height: 120px; border-bottom: 2px solid {BORDER}; display: flex; align-items: flex-end; justify-content: center; padding-bottom: 20px; font-size: 28px; }}
#s10-phone .pub {{ position: absolute; right: 22px; top: 150px; width: 340px; font-size: 28px; padding: 16px 22px; border-radius: 22px; white-space: normal; line-height: 1.35; }}
#s10-phone .pans {{ position: absolute; left: 26px; top: 330px; width: 390px; font-size: 28px; line-height: 1.4; }}
#s10-phone .pans .star {{ width: 40px; height: 40px; margin-bottom: 12px; }}
#s10-phone .pch {{ position: absolute; left: 26px; right: 26px; top: 540px; height: 170px; border-radius: 20px; }}
#s10-phone .pch .mb {{ position: absolute; left: 20px; right: 20px; bottom: 18px; height: 120px; display: flex; gap: 18px; align-items: flex-end; }}
#s10-phone .pch .mb div {{ flex: 1; border-radius: 8px 8px 3px 3px; }}
#s10-phone .prc {{ position: absolute; left: 22px; right: 22px; bottom: 26px; height: 84px; border-radius: 42px; border: 2px solid {BORDER}; font-size: 28px; color: #9A8877; display: flex; align-items: center; padding: 0 26px; }}
""", f"""
    <div id="s10-cam">
      <div id="s10-desk" class="surface">
        <div class="tbar"><i></i><i></i><i></i></div>
        <div class="side"><div class="sh">{logo()}<span>Chuk Chat</span></div>
          <div class="it on">Coffee spend</div><div class="it">Kiel cafés walk</div><div class="it">Hamburg trip</div><div class="it">Tax letter</div></div>
        <div class="main">
          <div class="ub bubble">what did i spend on coffee this month?</div>
          <div class="ans">{star()}<div>You spent €42.80 on coffee in October.</div></div>
          <div class="mchart surface"><div class="mt">Coffee · October</div><div class="mb">{mini_bars}</div></div>
          <div class="rc">Reply…<div class="snd">{icon('send')}</div></div>
        </div>
      </div>
      <div id="s10-phone"><div class="scr">
        <div class="ph-h">Coffee spend</div>
        <div class="pub bubble">what did i spend on coffee this month?</div>
        <div class="pans">{star()}<div>You spent €42.80 on coffee in October.</div></div>
        <div class="pch surface"><div class="mb">{mini_bars}</div></div>
        <div class="prc">Reply…</div>
      </div></div>
    </div>
""", """
  tl.fromTo('#s10-desk', { x: -260, opacity: 0.4, filter: 'blur(12px)' }, { x: 0, opacity: 1, filter: 'blur(0px)', duration: 0.6, ease: 'expo.out' }, 0);
  tl.fromTo('#s10-phone', { x: 300, opacity: 0.3, filter: 'blur(12px)' }, { x: 0, opacity: 1, filter: 'blur(0px)', duration: 0.6, ease: 'expo.out' }, 0.06);
  tl.fromTo('#s10-cam', { scale: 1.07 }, { scale: 1, duration: 1.4, ease: 'power2.out' }, 0);
""")

# =================================================================== 11 question card
add("s11", 52.60, 3.93, f"""
#s11-bg {{ position: absolute; inset: 0; background: {TAN}; }}
#s11-t {{ position: absolute; left: 0; right: 0; top: 476px; text-align: center; font-size: 104px; line-height: 1.1; }}
""", """
    <div id="s11-bg"></div>
    <h1 id="s11-t" class="serif">What will you ask next?</h1>
""", """
  tl.fromTo('#s11-bg', { clipPath: 'inset(0 0 0 100%)' }, { clipPath: 'inset(0 0 0 0%)', duration: 0.45, ease: 'power2.inOut' }, 0);
  hfWords('#s11-t');
  tl.fromTo('#s11-t .word', { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.18, stagger: 0.08, ease: 'power2.out' }, 0.45);
  tl.to('#s11-t .word', { opacity: 0, filter: 'blur(8px)', duration: 0.16, stagger: 0.03, ease: 'power2.in' }, 3.62);
""")

# =================================================================== 12 end card
add("s12", 56.53, 5.47, f"""
#s12-bg {{ position: absolute; inset: 0; background: {TAN}; }}
#s12-lock {{ position: absolute; left: 0; right: 0; top: 400px; display: flex; align-items: center; justify-content: center; gap: 34px; }}
#s12-lock .mark {{ width: 150px; height: 150px; color: {INK}; }}
#s12-wm {{ font-size: 124px; line-height: 1; }}
#s12-sl {{ position: absolute; left: 0; right: 0; top: 618px; text-align: center; font-size: 38px; color: {SOFT}; }}
""", f"""
    <div id="s12-bg"></div>
    <div id="s12-lock">{logo(id_='s12-mark')}<div id="s12-wm" class="serif">Chuk Chat</div></div>
    <div id="s12-sl" class="mono">Private and Secure. Always.</div>
""", """
  tl.fromTo('#s12-mark', { clipPath: 'inset(100% 0 0 0)', scale: 0.86 }, { clipPath: 'inset(0% 0 0 0)', scale: 1, duration: 0.6, ease: 'power3.out' }, 0.05);
  tl.fromTo('#s12-wm', { clipPath: 'inset(0 100% 0 0)' }, { clipPath: 'inset(0 0% 0 0)', duration: 0.55, ease: 'power3.inOut' }, 0.55);
  hfWords('#s12-sl');
  tl.fromTo('#s12-sl .word', { opacity: 0, filter: 'blur(6px)' }, { opacity: 1, filter: 'blur(0px)', duration: 0.18, stagger: 0.09, ease: 'power2.out' }, 1.15);
""")

# =================================================================== index
hosts = "\n".join(
    f'      <div id="{cid}" data-composition-id="{cid}" data-composition-src="compositions/{cid}.html" '
    f'data-start="{s}" data-duration="{d}" data-track-index="1" data-track-kind="graphics" '
    f'data-width="1920" data-height="1080" style="z-index:{i+2}"></div>'
    for i, (cid, s, d) in enumerate(SCENES))

INDEX = f"""<!doctype html>
<html lang="en" data-composition-variables='[{{"id":"color-ground","type":"color","label":"Background","default":"{CANVAS}"}},{{"id":"color-ink","type":"color","label":"Text","default":"{INK}"}},{{"id":"color-accent","type":"color","label":"Accent","default":"{ACCENT}"}}]'>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: {CANVAS}; }}
      #root {{ width: 100%; height: 100%; position: relative; background: {CANVAS}; }}
      #ground {{ position: absolute; inset: 0; z-index: 1; background-color: {CANVAS};
        background-image: linear-gradient({GRID} 1px, transparent 1px), linear-gradient(90deg, {GRID} 1px, transparent 1px);
        background-size: 48px 48px; background-position: -1px 11px; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="62" data-width="1920" data-height="1080">
      <div id="ground" class="clip" data-start="0" data-duration="62" data-track-index="0" data-track-kind="graphics"></div>
{hosts}
      <audio id="music" data-timeline-role="music" src="assets/audio/music.wav" data-start="0" data-duration="62" data-track-index="2" data-volume="1"></audio>
    </div>
    <script>
      const tl = gsap.timeline({{ paused: true }});
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
"""
(ROOT / "index.html").write_text(INDEX)
print("wrote", len(SCENES), "scenes")
for cid, s, d in SCENES:
    print(f"  {cid}  {s:6.2f} - {s+d:6.2f}")
