#!/usr/bin/env python3
"""Generate the scene files and index.html of chuk-08-what-we-see.

The app pieces copy the markup and CSS of the chuk.chat website rebuild
(layouts/partials/uc/*.html, assets/css/usecases.css), which matches the
real app screenshots at 1.75 screenshot px per CSS px. Here a zoom factor
per scene makes them big. Icons are the app's own HugeIcons
(_work/ref/app-icons.html, copied from the website).

Run:  python3 _work/make_cipher.py   (once; writes _work/cipher.json)
      python3 _work/build.py         (from the project root)
"""
import html
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "_work"
COMP = ROOT / "compositions"
REPO = ROOT.parents[2]                     # chuk_chat (chuk-08 -> videos -> marketing -> repo)
LIB = ROOT.parent / "_lib"
COMP.mkdir(exist_ok=True)

# GSAP 3.14.2, vendored in marketing/videos/_lib (no network request at render time)
(ROOT / "assets/js").mkdir(parents=True, exist_ok=True)
shutil.copy2(LIB / "assets/js/gsap.min.js", ROOT / "assets/js/gsap.min.js")
# Music is gitignored (marketing/**/*.wav): take it from marketing/_shared/music, see
# marketing/videos/_lib/README.md (section Music) for the Epidemic Sound track and edit id.
MUSIC_SRC = ROOT.parents[1] / "_shared/music/07-chasing-horizons-62s.wav"
MUSIC = ROOT / "assets/audio/music.wav"
if MUSIC_SRC.is_file():
    MUSIC.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(MUSIC_SRC, MUSIC)
elif not MUSIC.is_file():
    raise SystemExit(f"missing music: {MUSIC_SRC}\nMusic WAVs are gitignored. See "
                     "marketing/videos/_lib/README.md (section Music), then put the file there.")

CIPH = json.loads((WORK / "cipher.json").read_text())
PROMPT = CIPH["prompt"]
ANSWER = CIPH["answer"]
ENV = CIPH["envelope"]
CT = ENV["ciphertext"]

SRC_FILE = REPO / "lib/services/encryption_service.dart"
CODE_FIRST, CODE_LAST = 52, 67
CODE = SRC_FILE.read_text().split("\n")[CODE_FIRST - 1:CODE_LAST]
FILE_LINES = len(SRC_FILE.read_text().rstrip("\n").split("\n"))

# ------------------------------------------------------------------ tokens
TOK = {
    "CANVAS": "#F4EEE4", "GRID": "#E6DCCD", "TAN": "#DCCBB4", "BROWN": "#5C4033",
    "INK": "#2A1F17", "SOFT": "#6E5D4E",
    # the app (measured on assets/screenshots, same as the website rebuild)
    "BG": "#262624", "FG": "#E8E4D8", "ACC": "#D97757", "BUBBLE": "#B6674D", "LINE": "#615F5A",
}


def T(s):
    for k, v in TOK.items():
        s = s.replace("@" + k + "@", v)
    return s


# ------------------------------------------------------------------ app icons (HugeIcons)
_ICONS = {}
for m in re.finditer(r'<symbol id="(h-[^"]+)" viewBox="([^"]+)"[^>]*>(.*?)</symbol>',
                     (WORK / "ref/app-icons.html").read_text(), re.S):
    _ICONS[m.group(1)] = (m.group(2), m.group(3))


def hi(name, box, cls=""):
    """App icon drawn at 0.86 of its box, like the app does."""
    vb, inner = _ICONS[name]
    px = round(box * 0.86, 2)
    return (f'<svg class="hi {cls}" viewBox="{vb}" fill="none" style="width:{px}px;height:{px}px">'
            f'{inner}</svg>')


LOGO_PATHS = "".join(re.findall(r"<path[^>]*/>", (ROOT / "assets/img/logo.svg").read_text(), re.S))


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
IBEAM = ('<svg class="cur-ibeam" viewBox="0 0 20 40"><path d="M4 3c3 0 6 1 6 4v26c0 3-3 4-6 4M16 3'
         'c-3 0-6 1-6 4v26c0 3 3 4 6 4M6 20h8" fill="none" stroke="#ffffff" stroke-width="5" '
         'stroke-linecap="round"/><path d="M4 3c3 0 6 1 6 4v26c0 3-3 4-6 4M16 3c-3 0-6 1-6 4v26'
         'c0 3 3 4 6 4M6 20h8" fill="none" stroke="#14100c" stroke-width="2.2" '
         'stroke-linecap="round"/></svg>')


def cursor(id_):
    return f'<div class="cur" id="{id_}">{ARROW}{HAND}{IBEAM}</div>'


COMMON_CSS = T("""
@font-face { font-family: 'Newsreader'; src: url('assets/fonts/Newsreader-Disp600.ttf') format('truetype'); font-weight: 600; font-style: normal; }
@font-face { font-family: 'ChukMono'; src: url('assets/fonts/jetbrains-mono-latin-wght.woff2') format('woff2'); font-weight: 100 800; font-style: normal; }
@font-face { font-family: 'Ubuntu'; src: url('assets/fonts/Ubuntu-wght.ttf') format('truetype'); font-weight: 100 800; font-style: normal; }
#root { position: absolute; inset: 0; overflow: hidden; font-family: 'Ubuntu', sans-serif; color: @INK@; }
#root * { box-sizing: border-box; }
.serif { font-family: 'Newsreader', serif; font-weight: 600; letter-spacing: -0.01em; color: @INK@; }
.mono { font-family: 'ChukMono', monospace; }
.word { display: inline-block; }
.hi { display: block; flex: none; }
.mark { display: block; }
.cur { position: absolute; left: 0; top: 0; width: 0; height: 0; z-index: 60; }
.cur svg { position: absolute; overflow: visible; }
.cur-arrow { left: -5px; top: -4px; width: 48px; height: 68px; transform-origin: 5px 4px; }
.cur-hand { left: -21px; top: -5px; width: 56px; height: 62px; opacity: 0; transform-origin: 21px 5px; }
.cur-ibeam { left: -10px; top: -20px; width: 20px; height: 40px; opacity: 0; transform-origin: 10px 20px; }
.card-line { position: absolute; left: 0; right: 0; text-align: center; }
""")

# The app, copied from chuk.chat assets/css/usecases.css (.app vars, composer, bubble,
# answer, agent timeline). Sizes are CSS px of the app; a zoomed wrapper scales them.
APP_CSS = T("""
.appz { position: absolute; left: 0; top: 0; transform-origin: 0 0; }
.a-win { position: absolute; background: @BG@; border-radius: 18px; box-shadow: 0 0 0 1px rgba(255,255,255,0.07), 0 24px 60px -24px rgba(0,0,0,0.45); overflow: hidden; }
.a-vars { --fg: @FG@; --fg85: rgba(232,228,216,0.85); --fg70: rgba(232,228,216,0.7); --fg55: rgba(232,228,216,0.55);
  --fg30: rgba(232,228,216,0.3); --fg15: rgba(232,228,216,0.15); --bg: @BG@; --acc: @ACC@; --bubble: @BUBBLE@;
  color: var(--fg); font-family: 'Ubuntu', sans-serif; font-size: 14px; line-height: 1.4; }
.a-composer { position: absolute; display: flex; flex-direction: column; justify-content: space-between;
  min-height: 135px; padding: 14px; border: 2px solid @LINE@; border-radius: 30px; background: var(--bg); }
.a-field { position: relative; min-height: 40px; margin-left: -1px; padding: 4px 58px 0 0; font-size: 17px; font-weight: 600; line-height: 1.4; white-space: nowrap; }
.a-ph { color: rgba(232,228,216,0.8); }
.a-typed { color: var(--fg); }
.a-caret0 { position: absolute; left: -1px; top: 3px; width: 2px; height: 1.3em; background: var(--acc); }
.a-caret { display: inline-block; width: 2px; height: 1.2em; background: var(--acc); vertical-align: -0.22em; }
.a-send { position: absolute; top: 14px; right: 14px; width: 44px; height: 36px; border-radius: 20px; background: var(--acc); color: #fff; display: flex; align-items: center; justify-content: center; }
.a-send svg { transform: scaleY(0.95); }
.a-row { display: flex; align-items: center; gap: 8px; }
.a-grow { flex: 1; }
.a-btn { width: 44px; height: 36px; border: 2px solid @LINE@; border-radius: 18px; display: inline-flex; align-items: center; justify-content: center; color: var(--fg); }
.a-pill { height: 36px; padding: 0 11px; border: 2px solid @LINE@; border-radius: 18px; display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 600; color: var(--fg); white-space: nowrap; }
.a-dn { margin-left: -3px; color: var(--fg70); }
.a-disc { position: absolute; left: 0; right: 0; font-size: 11.5px; color: var(--fg70); text-align: center; white-space: nowrap; }
.a-col { position: absolute; }
.a-user { display: flex; justify-content: flex-end; }
.a-bubble { max-width: 80%; padding: 10px 14px; border: 1px solid var(--fg30); border-radius: 16px; background: var(--bubble); color: var(--fg);
  font-family: 'ChukMono', monospace; font-size: 16.4px; font-weight: 400; line-height: 1.38; white-space: nowrap; }
.a-ai { margin-top: 8px; font-family: 'ChukMono', monospace; font-size: 16.4px; font-weight: 400; line-height: 1.45; color: var(--fg); }
.a-ai p { margin: 0 0 8px; }
.a-tl { margin-top: 14px; font-family: 'Ubuntu', sans-serif; }
.a-tl-head { display: inline-flex; align-items: center; gap: 4px; margin: 0; padding: 4px 2px; font-size: 12.7px; font-weight: 500; color: var(--fg55); }
.a-steps { position: relative; padding-top: 4px; }
.a-steps-line { position: absolute; left: 13px; top: 17px; bottom: 15px; width: 1px; background: var(--fg15); }
.a-step { position: relative; display: flex; align-items: center; gap: 10px; min-height: 26px; margin-bottom: 8px; font-size: 12.7px; color: var(--fg55); white-space: nowrap; }
.a-badge { flex: none; width: 26px; height: 26px; border-radius: 50%; border: 1px solid var(--fg15); background: var(--bg); display: flex; align-items: center; justify-content: center; color: var(--fg55); }
.a-step b { margin-left: 0.6em; font-weight: 500; color: var(--fg85); }
.a-srcs { display: flex; align-items: center; gap: 6px; height: 30px; margin: -4px 0 8px 36px; }
.a-src { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 8px; border-radius: 15px; background: rgba(232,228,216,0.06); font-size: 12.7px; color: var(--fg70); white-space: nowrap; }
.a-fav { flex: none; width: 16px; height: 16px; border-radius: 3px; display: block; }
""")

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
function hfClick(tl, cur, t, part) {
  var sel = cur + ' .cur-' + (part || 'arrow');
  tl.to(sel, { scale: 0.86, duration: 0.08, ease: 'power2.out' }, t);
  tl.to(sel, { scale: 1, duration: 0.14, ease: 'power2.out' }, t + 0.08);
}
function hfShape(tl, cur, t, part) {
  ['arrow', 'hand', 'ibeam'].forEach(function (p) {
    tl.to(cur + ' .cur-' + p, { opacity: p === part ? 1 : 0, duration: 0.06 }, t);
  });
}
function hfHash(i, j) {
  var h = (i * 374761393 + j * 668265263) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}
function hfReveal(tl, sel, t, stagger) {
  hfWords(sel);
  tl.fromTo(sel + ' .word', { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.32, stagger: stagger || 0.08, ease: 'power3.out' }, t);
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
  window.__timelines = window.__timelines || {{}};
  window.__timelines["{cid}"] = tl;
}})();
  </script>
</template>
"""


SCENES = []  # (id, start, dur)


def add(cid, start, end, css, body, js):
    dur = round(end - start, 2)
    SCENES.append((cid, start, dur))
    (COMP / f"{cid}.html").write_text(scene(cid, T(css), T(body), T(js), dur))


def card(cid, start, end, lines, bg, size=104, top=None, t0=0.1):
    """Serif card: one or two lines, words rise in."""
    n = len(lines)
    lh = round(size * 1.12)
    top = top if top is not None else round(540 - n * lh / 2)
    divs = "".join(
        f'<div class="card-line serif" id="{cid}-l{i}" style="top:{top + i * lh}px;font-size:{size}px;line-height:{lh}px">'
        f'{html.escape(t)}</div>' for i, t in enumerate(lines))
    bgdiv = f'<div id="{cid}-bg" style="position:absolute;inset:0;background:{bg}"></div>' if bg else ""
    js = "".join(f"  hfReveal(tl, '#{cid}-l{i}', {t0 + i * 0.45:.2f});\n" for i in range(n))
    js += f"  tl.fromTo('#{cid}-txt', {{ scale: 1 }}, {{ scale: 1.035, duration: {end - start:.2f}, ease: 'none' }}, 0);\n"
    add(cid, start, end, "", f'    {bgdiv}<div id="{cid}-txt" style="position:absolute;inset:0">{divs}</div>', js)


# =================================================================== timing (beats of the track)
# 122.2 BPM, beat 0.49 s. Cuts on beats: 3.42 9.84 17.70 20.04 29.00 35.88 43.77 46.73 49.66 52.60
CUTS = [0.0, 3.42, 9.84, 17.70, 20.04, 29.00, 35.88, 43.77, 46.73, 49.66, 52.60, 62.0]

# =================================================================== 01 tan card
card("s01", CUTS[0], CUTS[1], ["Some questions you'd", "never ask out loud."], "@TAN@", size=112, t0=0.15)

# =================================================================== 02 the composer, typing, send
Z2 = 2.2
# app px inside the zoomed wrapper (1920/Z x 1080/Z)
W2, H2 = 1920 / Z2, 1080 / Z2
CW2 = 608                     # composer width in the home screenshot (1064 px / 1.75)
CX2 = (W2 - CW2) / 2
CY2 = (H2 - 158) / 2
add("s02", CUTS[1], CUTS[2], APP_CSS + f"""
#s02-cam {{ position: absolute; inset: 0; transform-origin: 960px 520px; }}
#s02-z {{ width: {W2:.2f}px; height: {H2:.2f}px; zoom: {Z2}; }}
#s02-win {{ left: {CX2 - 46:.2f}px; top: {CY2 - 44:.2f}px; width: {CW2 + 92}px; height: {158 + 76}px; }}
#s02-comp {{ left: {CX2:.2f}px; top: {CY2:.2f}px; width: {CW2}px; }}
#s02-disc {{ top: {CY2 + 135 + 8:.2f}px; }}
#s02-typed {{ display: none; }}
""", f"""
    <div id="s02-cam">
      <div id="s02-z" class="appz a-vars">
        <div id="s02-win" class="a-win"></div>
        <div id="s02-comp" class="a-composer">
          <div class="a-field"><span id="s02-caret" class="a-caret0"></span><span id="s02-ph" class="a-ph">Ask me anything !</span><span id="s02-typed" class="a-typed"></span><span id="s02-caret2" class="a-caret" style="opacity:0"></span></div>
          <div class="a-row">
            <span class="a-btn">{hi('h-plus-sign', 24)}</span>
            <span class="a-grow"></span>
            <span class="a-pill">{hi('h-flash', 15)}<b>Fast</b><span class="a-dn">{hi('h-arrow-down01', 12)}</span></span>
            <span class="a-btn">{hi('h-mic02', 22)}</span>
          </div>
          <span id="s02-send" class="a-send">{hi('h-send-horizontal', 26)}</span>
        </div>
        <p id="s02-disc" class="a-disc">You're chatting with an AI/LLM — it can be wrong. Check key info.</p>
      </div>
      {cursor('s02-cur')}
    </div>
""", f"""
  // the window piece arrives
  tl.fromTo('#s02-z', {{ opacity: 0, y: 24 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: 1.1, duration: 4.4, ease: 'power1.inOut' }}, 2.0);
  tl.set('#s02-caret', {{ opacity: 0 }}, 0);
  // cursor into the field
  tl.fromTo('#s02-cur', {{ x: 1500, y: 1180 }}, {{ x: {(CX2 + 22) * Z2 + 260:.0f}, y: {(CY2 + 30) * Z2:.0f}, duration: 1.0, ease: 'power2.inOut' }}, 0.35);
  hfShape(tl, '#s02-cur', 1.1, 'ibeam');
  hfClick(tl, '#s02-cur', 1.45, 'ibeam');
  tl.set('#s02-caret', {{ opacity: 1 }}, 1.5);
  // the caret blinks once before the first key
  tl.set('#s02-caret', {{ opacity: 0 }}, 1.75);
  tl.set('#s02-caret', {{ opacity: 1 }}, 1.95);
  tl.set('#s02-ph', {{ display: 'none' }}, 2.05);
  tl.set('#s02-caret', {{ display: 'none' }}, 2.05);
  tl.set('#s02-typed', {{ display: 'inline' }}, 2.05);
  tl.set('#s02-caret2', {{ opacity: 1 }}, 2.05);
  hfShape(tl, '#s02-cur', 2.1, 'arrow');
  tl.to('#s02-cur', {{ x: 1240, y: 760, duration: 0.6, ease: 'power2.out' }}, 2.1);
  var end = hfType(tl, document.getElementById('s02-typed'), {PROMPT!r}, 2.05, 18);
  // to send
  tl.to('#s02-cur', {{ x: {(CX2 + CW2 - 2 - 14 - 22) * Z2:.0f}, y: {(CY2 + 2 + 14 + 20) * Z2:.0f}, duration: 0.75, ease: 'power2.inOut' }}, end + 0.15);
  hfShape(tl, '#s02-cur', end + 0.8, 'hand');
  tl.to('#s02-send', {{ backgroundColor: '#C9684A', duration: 0.1 }}, end + 0.8);
  hfClick(tl, '#s02-cur', end + 1.05, 'hand');
  tl.to('#s02-send', {{ scale: 0.9, duration: 0.08 }}, end + 1.05);
  tl.to('#s02-send', {{ scale: 1, backgroundColor: '@ACC@', duration: 0.14 }}, end + 1.13);
  tl.set('#s02-typed', {{ display: 'none' }}, end + 1.2);
  tl.set('#s02-ph', {{ display: 'inline' }}, end + 1.2);
  tl.set('#s02-caret2', {{ opacity: 0 }}, end + 1.2);
  tl.set('#s02-caret', {{ display: 'block', opacity: 1 }}, end + 1.2);
""")
S02_TYPE_END = 2.05 + len(PROMPT) / 18

# =================================================================== 03 the answer
Z3 = 2.0
W3, H3 = 1920 / Z3, 1080 / Z3
COLW = 728
CX3 = (W3 - COLW) / 2
WIN3_H = 370
WIN3_Y = (H3 - WIN3_H) / 2
FAVS = [("nhs.uk", "nhs.uk"), ("mayoclinic.org", "mayoclinic.org"), ("aerzteblatt.de", "aerzteblatt.de")]
chips = "".join(f'<span class="a-src" id="s03-src{i}"><img class="a-fav" src="assets/fav/{f}.png" alt="">{h}</span>'
                for i, (f, h) in enumerate(FAVS))
P1 = ANSWER[0] + " " + ANSWER[1]
P2 = ANSWER[2] + " " + ANSWER[3]
add("s03", CUTS[2], CUTS[3], APP_CSS + f"""
#s03-cam {{ position: absolute; inset: 0; transform-origin: {(CX3 + COLW - 260) * Z3:.0f}px {(WIN3_Y + 32 + 22) * Z3:.0f}px; }}
#s03-z {{ width: {W3:.2f}px; height: {H3:.2f}px; zoom: {Z3}; }}
#s03-win {{ left: {CX3 - 56:.2f}px; top: {WIN3_Y:.2f}px; width: {COLW + 112}px; height: {WIN3_H}px; }}
#s03-col {{ left: {CX3:.2f}px; top: {WIN3_Y + 32:.2f}px; width: {COLW}px; }}
""", f"""
    <div id="s03-cam" data-layout-allow-overflow>
      <div id="s03-z" class="appz a-vars">
        <div id="s03-win" class="a-win"></div>
        <div id="s03-col" class="a-col">
          <div class="a-user"><p id="s03-bub" class="a-bubble">{html.escape(PROMPT)}</p></div>
          <div class="a-tl" id="s03-tl">
            <p class="a-tl-head" id="s03-head"><span>Worked for 2s</span>{hi('h-arrow-down01', 16)}</p>
            <div class="a-steps">
              <div class="a-steps-line" id="s03-line"></div>
              <div class="a-step" id="s03-st0"><span class="a-badge">{hi('h-bulb', 14)}</span><span>User asks what a ferritin of 9 means.</span></div>
              <div class="a-step" id="s03-st1"><span class="a-badge">{hi('h-search01', 14)}</span><span>Searched<b>ferritin 9 µg/L low</b></span></div>
              <div class="a-srcs" id="s03-srcs">{chips}</div>
            </div>
          </div>
          <div class="a-ai" id="s03-ai"><p id="s03-p1">{html.escape(P1)}</p><p id="s03-p2">{html.escape(P2)}</p></div>
        </div>
      </div>
    </div>
""", """
  tl.fromTo('#s03-bub', { opacity: 0, y: 60 }, { opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }, 0);
  tl.fromTo('#s03-head', { opacity: 0 }, { opacity: 1, duration: 0.25 }, 0.45);
  tl.fromTo('#s03-line', { scaleY: 0, transformOrigin: '50% 0%' }, { scaleY: 1, duration: 0.6, ease: 'power2.out' }, 0.6);
  tl.fromTo('#s03-st0', { opacity: 0, x: -10 }, { opacity: 1, x: 0, duration: 0.35, ease: 'power3.out' }, 0.6);
  tl.fromTo('#s03-st1', { opacity: 0, x: -10 }, { opacity: 1, x: 0, duration: 0.35, ease: 'power3.out' }, 0.9);
  tl.fromTo('#s03-srcs .a-src', { opacity: 0, y: 8 }, { opacity: 1, y: 0, duration: 0.3, stagger: 0.12, ease: 'power3.out' }, 1.15);
  // the answer streams in, word by word
  hfWords('#s03-p1'); hfWords('#s03-p2');
  tl.fromTo('#s03-ai .word', { opacity: 0 }, { opacity: 1, duration: 0.05, stagger: 0.085, ease: 'none' }, 1.75);
  // push in on the question
  tl.fromTo('#s03-cam', { scale: 1 }, { scale: 1.4, duration: 2.6, ease: 'power2.inOut' }, 5.2);
""")

# =================================================================== 04 serif on canvas
card("s04", CUTS[3], CUTS[4], ["Here's what we store."], None, size=112)

# =================================================================== 05 the database row
def mask_uuid(u):
    return u[:4] + "····-····-····-····" + u[-4:]


ROWS = [
    (CIPH["others"][0]["id"], CIPH["others"][0]["payload"], "2026-10-26 08:12:44+00", False),
    (CIPH["row_id"], CIPH["envelope_text"], "2026-10-26 09:41:07+00", True),
    (CIPH["others"][1]["id"], CIPH["others"][1]["payload"], "2026-10-25 21:03:19+00", False),
    (CIPH["others"][2]["id"], CIPH["others"][2]["payload"], "2026-10-24 17:56:02+00", False),
]
UID = mask_uuid(CIPH["user_id"])
COLS = [("id", "uuid", 300), ("user_id", "uuid", 340), ("encrypted_payload", "text", 640), ("updated_at", "timestamptz", 376)]
TBL_X, TBL_Y, TBL_W = 100, 296, 1720
ROW_H, HEAD_H, BAR_H, CHK_W = 80, 72, 92, 64


def th():
    cells = f'<div class="sb-chk"><span class="sb-box"></span></div>'
    for name, typ, w in COLS:
        cells += f'<div class="sb-th" style="width:{w}px"><b>{name}</b><span>{typ}</span></div>'
    return f'<div class="sb-tr sb-head">{cells}</div>'


def tr(i, rid, payload, ts, mine):
    pid = ' id="s05-cell" data-layout-allow-overflow' if mine else ""
    inner = f'<span id="s05-scroll" class="sb-scroll" data-layout-allow-overlap>{html.escape(payload)}</span>' if mine else html.escape(payload)
    return (f'<div class="sb-tr{" sb-mine" if mine else ""}" id="s05-r{i}"><div class="sb-chk"><span class="sb-box"></span></div>'
            f'<div class="sb-td" style="width:{COLS[0][2]}px">{rid}</div>'
            f'<div class="sb-td" style="width:{COLS[1][2]}px">{UID}</div>'
            f'<div class="sb-td sb-pay" style="width:{COLS[2][2]}px"{pid}>{inner}</div>'
            f'<div class="sb-td" style="width:{COLS[3][2]}px">{ts}</div></div>')


TABLE_SVG = ('<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
             'stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/>'
             '<path d="M3 10h18M3 15h18M9 10v10"/></svg>')
FILTER_SVG = ('<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
              'stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M7 12h10M10 18h4"/></svg>')
SORT_SVG = ('<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            'stroke-linecap="round" stroke-linejoin="round"><path d="M7 4v16M3 16l4 4 4-4M17 20V4M13 8l4-4 4 4"/></svg>')
KEY_SVG = ('<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
           'stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l3 3"/></svg>')

ENV_PRETTY = [
    ('{', None), ('  "v": ', '"2",'), ('  "kv": ', '1,'), ('  "nonce": ', f'"{ENV["nonce"]}",'),
    ('  "ciphertext": ', f'"{CT}",'), ('  "mac": ', f'"{ENV["mac"]}"'), ('}', None)]
env_html = "".join(
    f'<div class="ex-l"><span class="ex-k">{html.escape(k)}</span>' +
    (f'<span class="ex-v">{html.escape(v)}</span>' if v else "") + '</div>'
    for k, v in ENV_PRETTY)
CELL_X = TBL_X + CHK_W + COLS[0][2] + COLS[1][2]
CELL_Y = TBL_Y + BAR_H + HEAD_H + ROW_H  # second row
add("s05", CUTS[4], CUTS[5], f"""
#s05-tbl {{ position: absolute; left: {TBL_X}px; top: {TBL_Y}px; width: {TBL_W}px; background: #FFFFFF; border: 1px solid #DFE3E8; border-radius: 18px; overflow: hidden; box-shadow: 0 20px 50px -24px rgba(0,0,0,0.25); }}
.sb-bar {{ height: {BAR_H}px; display: flex; align-items: center; gap: 16px; padding: 0 28px; border-bottom: 1px solid #E6E8EB; color: #11181C; }}
.sb-bar .sb-ic {{ width: 30px; height: 30px; color: #687076; }}
.sb-name {{ font-size: 34px; font-weight: 600; }}
.sb-tag {{ font-size: 24px; color: #687076; padding: 4px 12px; border: 1px solid #E6E8EB; border-radius: 8px; }}
.sb-grow {{ flex: 1; }}
.sb-btn {{ display: flex; align-items: center; gap: 10px; font-size: 26px; color: #3E4347; padding: 8px 16px; border: 1px solid #E6E8EB; border-radius: 10px; }}
.sb-btn .sb-ic {{ width: 24px; height: 24px; color: #3E4347; }}
.sb-tr {{ display: flex; height: {ROW_H}px; border-bottom: 1px solid #E6E8EB; background: #FFFFFF; }}
.sb-tr:last-child {{ border-bottom: none; }}
.sb-head {{ height: {HEAD_H}px; background: #F8F9FA; }}
.sb-chk {{ width: {CHK_W}px; flex: none; display: flex; align-items: center; justify-content: center; border-right: 1px solid #E6E8EB; }}
.sb-box {{ width: 20px; height: 20px; border: 1.5px solid #C1C8CD; border-radius: 5px; }}
.sb-th {{ flex: none; display: flex; align-items: center; gap: 12px; padding: 0 18px; border-right: 1px solid #E6E8EB; font-size: 27px; color: #11181C; }}
.sb-th b {{ font-weight: 600; }}
.sb-th span {{ font-size: 23px; color: #889096; }}
.sb-td {{ flex: none; display: flex; align-items: center; padding: 0 18px; border-right: 1px solid #E6E8EB; font-family: 'ChukMono', monospace; font-size: 25px; color: #3E4347; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.sb-mine .sb-td {{ color: #11181C; }}
.sb-pay {{ position: relative; }}
.sb-scroll {{ display: inline-block; white-space: nowrap; }}
#s05-sel {{ position: absolute; left: {CELL_X - TBL_X}px; top: {CELL_Y - TBL_Y}px; width: {COLS[2][2]}px; height: {ROW_H}px; border: 3px solid #3ECF8E; border-radius: 3px; opacity: 0; }}
#s05-ex {{ position: absolute; left: 160px; top: 150px; width: 1600px; background: #FFFFFF; border: 1px solid #DFE3E8; border-radius: 18px; box-shadow: 0 24px 60px -24px rgba(0,0,0,0.3); overflow: hidden; opacity: 0; }}
.ex-bar {{ height: 76px; display: flex; align-items: center; gap: 16px; padding: 0 32px; border-bottom: 1px solid #E6E8EB; font-size: 28px; color: #11181C; }}
.ex-bar b {{ font-weight: 600; }}
.ex-bar .sb-ic {{ width: 28px; height: 28px; color: #687076; }}
.ex-body {{ padding: 26px 40px 30px; font-family: 'ChukMono', monospace; font-size: 30px; line-height: 46px; color: #11181C; }}
.ex-l {{ white-space: pre-wrap; word-break: break-all; }}
.ex-k {{ color: #687076; }}
.ex-v {{ color: #11181C; }}
#s05-line {{ top: 862px; font-size: 92px; line-height: 104px; }}
""", f"""
    <div id="s05-tblw" style="position:absolute;inset:0">
      <div id="s05-tbl">
        <div class="sb-bar">{TABLE_SVG}<span class="sb-name">encrypted_chats</span><span class="sb-tag">public</span><span class="sb-grow"></span><span class="sb-btn">{FILTER_SVG}Filter</span><span class="sb-btn">{SORT_SVG}Sort</span></div>
        {th()}
        {"".join(tr(i, *r) for i, r in enumerate(ROWS))}
        <div id="s05-sel"></div>
      </div>
    </div>
    <div id="s05-ex">
      <div class="ex-bar">{KEY_SVG}<b>encrypted_payload</b><span class="sb-tag">text</span><span class="sb-grow"></span><span style="font-size:24px;color:#687076">row {CIPH['row_id'][:8]}…</span></div>
      <div class="ex-body" id="s05-exb">{env_html}</div>
    </div>
    <div class="card-line serif" id="s05-line">This is all our server stores.</div>
    {cursor('s05-cur')}
""", f"""
  tl.fromTo('#s05-tbl', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('.sb-tr', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, stagger: 0.06 }}, 0.15);
  // the long base64 slides through the cell
  tl.fromTo('#s05-scroll', {{ x: 0 }}, {{ x: -2600, duration: 2.2, ease: 'power1.inOut' }}, 0.7);
  // cursor clicks the cell
  tl.fromTo('#s05-cur', {{ x: 1560, y: 1160 }}, {{ x: {CELL_X + 330}, y: {CELL_Y + 36}, duration: 1.0, ease: 'power2.inOut' }}, 1.2);
  tl.to('#s05-r1', {{ backgroundColor: '#F1F3F5', duration: 0.15 }}, 2.1);
  hfClick(tl, '#s05-cur', 2.45);
  tl.to('#s05-sel', {{ opacity: 1, duration: 0.08 }}, 2.5);
  hfClick(tl, '#s05-cur', 2.75);
  // the cell opens: the full envelope
  tl.to('#s05-cur', {{ x: 1700, y: 1180, duration: 0.6, ease: 'power3.in' }}, 2.95);
  tl.to('#s05-tblw', {{ opacity: 0, y: -40, duration: 0.35, ease: 'power2.in' }}, 2.95);
  tl.fromTo('#s05-ex', {{ opacity: 0, scale: 0.94, y: 60 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 3.05);
  tl.fromTo('#s05-exb .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.2, stagger: 0.09 }}, 3.25);
  tl.fromTo('#s05-ex', {{ y: 0 }}, {{ y: -16, duration: 5.4, ease: 'none', immediateRender: false }}, 3.6);
  hfReveal(tl, '#s05-line', 4.6, 0.09);
""")

# =================================================================== 06 colour block: the bubble becomes ciphertext
CIPH_SHOWN = CT[:len(PROMPT)]
add("s06", CUTS[5], CUTS[6], APP_CSS + f"""
#s06-bg {{ position: absolute; inset: 0; background: @BROWN@; }}
#s06-all {{ position: absolute; inset: 0; transform-origin: 960px 480px; }}
#s06-bw {{ position: absolute; left: 0; right: 0; top: 330px; display: flex; justify-content: center; }}
#s06-bub {{ font-size: 44px; padding: 26px 36px; border-radius: 42px; border-width: 2px; max-width: none; }}
#s06-lock {{ position: absolute; left: 912px; top: 180px; width: 96px; height: 96px; border-radius: 50%; background: @CANVAS@; color: @BROWN@; display: flex; align-items: center; justify-content: center; }}
#s06-l0 {{ top: 560px; font-size: 96px; line-height: 110px; color: @CANVAS@; }}
#s06-l1 {{ top: 680px; font-size: 96px; line-height: 110px; color: @CANVAS@; }}
""", f"""
    <div id="s06-bg"></div>
    <div id="s06-all" class="a-vars">
      <div id="s06-bw"><p id="s06-bub" class="a-bubble"><span id="s06-txt">{html.escape(PROMPT)}</span></p></div>
      <div id="s06-lock">{hi('h-lock', 56)}</div>
      <div class="card-line serif" id="s06-l0">Encrypted on your device.</div>
      <div class="card-line serif" id="s06-l1">With a key only you hold.</div>
    </div>
""", f"""
  var plain = {PROMPT!r}, cipher = {CIPH_SHOWN!r};
  var pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var el = document.getElementById('s06-txt');
  el.textContent = '';
  var spans = Array.from(plain).map(function (c) {{ var s = document.createElement('span'); s.textContent = c; el.appendChild(s); return s; }});
  function render(t) {{
    spans.forEach(function (s, i) {{
      var ti = i * 0.03;
      var c;
      if (t <= 0 || t < ti) c = plain[i];
      else if (t < ti + 0.25) c = pool[Math.floor(hfHash(i, Math.floor(t * 30)) * pool.length)];
      else c = cipher[i];
      if (s.textContent !== c) s.textContent = c;
    }});
  }}
  var prox = {{ t: 0 }};
  render(0);
  tl.fromTo('#s06-all', {{ scale: 1.0 }}, {{ scale: 1.04, duration: 6.88, ease: 'none' }}, 0);
  tl.fromTo('#s06-bub', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo(prox, {{ t: 0 }}, {{ t: 1.9, duration: 1.9, ease: 'none', onUpdate: function () {{ render(prox.t); }} }}, 0.7);
  tl.to('#s06-bub', {{ backgroundColor: '#46302A', borderColor: 'rgba(244,238,228,0.3)', duration: 1.2, ease: 'power1.inOut' }}, 1.2);
  tl.fromTo('#s06-lock', {{ opacity: 0, y: 30, scale: 0.7 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.5, ease: 'back.out(1.5)' }}, 2.6);
  hfReveal(tl, '#s06-l0', 3.0);
  hfReveal(tl, '#s06-l1', 3.6);
""")

# =================================================================== 07 the code on GitHub
DART_KW = {"final", "await", "return", "required", "bool", "true", "false", "async", "static", "const", "int", "dynamic", "List", "Future", "String"}


def dart_html(line):
    out = []
    for m in re.finditer(r"('[^']*')|(\b\d+\b)|([A-Za-z_][A-Za-z0-9_]*)|(\s+)|(.)", line):
        s, n, ident, ws, other = m.groups()
        if s:
            out.append(f'<span class="tk-s">{html.escape(s)}</span>')
        elif n:
            out.append(f'<span class="tk-n">{n}</span>')
        elif ident:
            nxt = line[m.end():m.end() + 1]
            if ident in ("final", "await", "return", "required", "true", "false", "async", "static", "const"):
                out.append(f'<span class="tk-k">{ident}</span>')
            elif ident in ("int", "dynamic", "String", "bool"):
                out.append(f'<span class="tk-k">{ident}</span>')
            elif nxt in ("(",):
                out.append(f'<span class="tk-f">{ident}</span>')
            elif ident[0].isupper() or ident.startswith("k") and ident[1:2].isupper():
                out.append(f'<span class="tk-t">{ident}</span>')
            else:
                out.append(html.escape(ident))
        elif ws:
            out.append(ws)
        else:
            out.append(html.escape(other))
    return "".join(out)


code_rows = "".join(
    f'<div class="gh-ln" id="s07-ln{CODE_FIRST + i}"><span class="gh-no">{CODE_FIRST + i}</span>'
    f'<span class="gh-code">{dart_html(l)}</span></div>' for i, l in enumerate(CODE))
REPO_SVG = ('<svg class="gh-ic" viewBox="0 0 16 16" fill="currentColor"><path d="M2 2.5A2.5 2.5 0 0 1 4.5 0h8.75a.75.75 0 0 1 .75.75v12.5a.75.75 0 0 1-.75.75h-2.5a.75.75 0 0 1 0-1.5h1.75v-2h-8a1 1 0 0 0-.714 1.7.75.75 0 1 1-1.072 1.05A2.495 2.495 0 0 1 2 11.5Zm10.5-1h-8a1 1 0 0 0-1 1v6.708A2.486 2.486 0 0 1 4.5 9h8ZM5 12.25a.25.25 0 0 1 .25-.25h3.5a.25.25 0 0 1 .25.25v3.25a.25.25 0 0 1-.4.2l-1.45-1.087a.249.249 0 0 0-.3 0L5.4 15.7a.25.25 0 0 1-.4-.2Z"/></svg>')
FILE_SVG = ('<svg class="gh-ic" viewBox="0 0 16 16" fill="currentColor"><path d="M2 1.75C2 .784 2.784 0 3.75 0h6.586c.464 0 .909.184 1.237.513l2.914 2.914c.329.328.513.773.513 1.237v9.586A1.75 1.75 0 0 1 13.25 16h-9.5A1.75 1.75 0 0 1 2 14.25Zm1.75-.25a.25.25 0 0 0-.25.25v12.5c0 .138.112.25.25.25h9.5a.25.25 0 0 0 .25-.25V6h-2.75A1.75 1.75 0 0 1 9 4.25V1.5Zm6.75.062V4.25c0 .138.112.25.25.25h2.688l-.011-.013-2.914-2.914-.013-.011Z"/></svg>')
GH_Y_CODE = 90 + 72 + 66 + 64   # panel top + rows
LN_H = 46
add("s07", CUTS[6], CUTS[7], f"""
#s07-cam {{ position: absolute; inset: 0; transform-origin: 600px 400px; }}
#s07-gh {{ position: absolute; left: 150px; top: 90px; width: 1620px; height: {72 + 66 + 64 + 16 * LN_H + 40}px; background: #0D1117; border: 1px solid #30363D; border-radius: 16px; overflow: hidden; color: #E6EDF3; box-shadow: 0 24px 60px -24px rgba(0,0,0,0.45); }}
.gh-ic {{ width: 28px; height: 28px; flex: none; color: #9198A1; }}
.gh-repo {{ height: 72px; display: flex; align-items: center; gap: 14px; padding: 0 30px; background: #010409; border-bottom: 1px solid #30363D; font-size: 28px; }}
.gh-repo .own {{ color: #E6EDF3; }}
.gh-repo .sep {{ color: #9198A1; }}
.gh-repo b {{ color: #E6EDF3; font-weight: 600; }}
.gh-path {{ height: 66px; display: flex; align-items: center; gap: 10px; padding: 0 30px; font-size: 28px; color: #4493F8; }}
.gh-path .sep {{ color: #9198A1; }}
.gh-path b {{ color: #E6EDF3; font-weight: 600; }}
.gh-tool {{ height: 64px; display: flex; align-items: center; gap: 18px; padding: 0 22px; background: #151B23; border-top: 1px solid #30363D; border-bottom: 1px solid #30363D; font-size: 24px; color: #9198A1; }}
.gh-seg {{ display: flex; border: 1px solid #3D444D; border-radius: 8px; overflow: hidden; }}
.gh-seg span {{ padding: 6px 18px; color: #E6EDF3; }}
.gh-seg .on {{ background: #262C36; }}
.gh-code-w {{ position: relative; padding: 20px 0; font-family: 'ChukMono', monospace; font-size: 30px; }}
.gh-ln {{ position: relative; display: flex; height: {LN_H}px; line-height: {LN_H}px; white-space: pre; }}
.gh-no {{ width: 110px; flex: none; text-align: right; padding-right: 26px; color: #6E7681; }}
.gh-code {{ color: #E6EDF3; }}
.gh-hl {{ position: absolute; left: 0; right: 0; height: {LN_H}px; background: rgba(187,128,9,0.22); border-left: 4px solid #BB8009; opacity: 0; }}
.tk-k {{ color: #FF7B72; }}
.tk-s {{ color: #A5D6FF; }}
.tk-n {{ color: #79C0FF; }}
.tk-f {{ color: #D2A8FF; }}
.tk-t {{ color: #FFA657; }}
#s07-line {{ top: 852px; font-size: 92px; line-height: 104px; }}
""", f"""
    <div id="s07-cam" data-layout-allow-overflow>
      <div id="s07-gh">
        <div class="gh-repo">{REPO_SVG}<span class="own">chuk-development</span><span class="sep">/</span><b>chuk_chat</b></div>
        <div class="gh-path"><span>chuk_chat</span><span class="sep">/</span><span>lib</span><span class="sep">/</span><span>services</span><span class="sep">/</span><b>encryption_service.dart</b></div>
        <div class="gh-tool"><span class="gh-seg"><span class="on">Code</span><span>Blame</span></span><span>{FILE_LINES} lines</span></div>
        <div class="gh-code-w">
          <div class="gh-hl" id="s07-hl53" style="top:{20 + (53 - CODE_FIRST) * LN_H}px"></div>
          <div class="gh-hl" id="s07-hl55" style="top:{20 + (55 - CODE_FIRST) * LN_H}px"></div>
          <div class="gh-hl" id="s07-hl64" style="top:{20 + (64 - CODE_FIRST) * LN_H}px"></div>
          {code_rows}
        </div>
      </div>
    </div>
    <div class="card-line serif" id="s07-line">Don't trust us. Read the code.</div>
""", f"""
  tl.fromTo('#s07-gh', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('.gh-ln', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, stagger: 0.03 }}, 0.15);
  // slow push-in on AesGcm.with256bits(), then the nonce
  tl.to('#s07-hl53', {{ opacity: 1, duration: 0.3 }}, 0.9);
  tl.fromTo('#s07-cam', {{ scale: 1, x: 0, y: 0 }}, {{ scale: 1.6, x: 120, y: 26, duration: 2.0, ease: 'power2.inOut' }}, 0.8);
  tl.to('#s07-hl55', {{ opacity: 1, duration: 0.3 }}, 2.9);
  tl.to('#s07-cam', {{ x: 60, y: -121, duration: 1.1, ease: 'power2.inOut' }}, 2.8);
  // back out; the panel makes room for the line
  tl.to('#s07-cam', {{ scale: 0.72, x: 0, y: -80, duration: 1.0, ease: 'power3.inOut' }}, 4.2);
  tl.to('#s07-hl64', {{ opacity: 1, duration: 0.3 }}, 4.6);
  hfReveal(tl, '#s07-line', 5.0, 0.09);
""")

# =================================================================== 08 three short beats
card("s08a", CUTS[7], CUTS[8], ["Your key never leaves your device."], None, size=100)
card("s08b", CUTS[8], CUTS[9], ["No ads. No tracking."], "@TAN@", size=112)
card("s08c", CUTS[9], CUTS[10], ["Run from Germany, under EU law."], None, size=104)

# =================================================================== 09 end card
# Official lockup only: assets/img/logo.svg (mark) and assets/img/wordmark.svg (outlined
# "Chuk Chat" + slogan, Liberation Mono Bold). Inlined as-is; only the fills go to ink.
_wm = (ROOT / "assets/img/wordmark.svg").read_text()
WM_VB = re.search(r'viewBox="([^"]+)"', _wm).group(1)
WM_INNER = re.search(r"<svg[^>]*>(.*)</svg>", _wm, re.S).group(1).replace('fill="#000000"', 'fill="@INK@"')
_vb = [float(x) for x in WM_VB.split()]
WM_W = 900
WM_H = round(WM_W * _vb[3] / _vb[2], 1)
MARK_H = 440
GAP1, GAP2, URL_H = 40, 58, 40
TOP9 = round((1080 - (MARK_H + GAP1 + WM_H + GAP2 + URL_H)) / 2)
add("s09", CUTS[10], CUTS[11], f"""
@font-face {{ font-family: 'LiberationMono'; src: url('assets/fonts/LiberationMono-Regular.ttf') format('truetype'); font-weight: 400; font-style: normal; }}
#s09-bg {{ position: absolute; inset: 0; background: @TAN@; }}
#s09-lock {{ position: absolute; inset: 0; transform-origin: 960px 540px; }}
#s09-mark {{ position: absolute; left: {(1920 - MARK_H) / 2:.1f}px; top: {TOP9}px; width: {MARK_H}px; height: {MARK_H}px; color: @INK@; }}
#s09-wm {{ position: absolute; display: block; left: {(1920 - WM_W) / 2:.1f}px; top: {TOP9 + MARK_H + GAP1}px; width: {WM_W}px; height: {WM_H}px; }}
#s09-url {{ top: {TOP9 + MARK_H + GAP1 + WM_H + GAP2:.1f}px; font-family: 'LiberationMono', monospace; font-size: 30px; line-height: {URL_H}px; color: @SOFT@; }}
""", f"""
    <div id="s09-bg"></div>
    <div id="s09-lock">
      {logo(id_='s09-mark')}
      <svg id="s09-wm" viewBox="{WM_VB}" xmlns="http://www.w3.org/2000/svg">{WM_INNER}</svg>
      <div class="card-line" id="s09-url">chuk.chat</div>
    </div>
""", """
  tl.fromTo('#s09-mark', { clipPath: 'inset(100% 0 0 0)', y: 30 }, { clipPath: 'inset(0% 0 0 0)', y: 0, duration: 0.7, ease: 'power3.out' }, 0.05);
  tl.fromTo('#s09-wm', { clipPath: 'inset(0 100% 0 0)' }, { clipPath: 'inset(0 0% 0 0)', duration: 0.8, ease: 'power3.inOut' }, 0.6);
  tl.fromTo('#s09-url', { opacity: 0 }, { opacity: 1, duration: 0.5 }, 1.7);
  tl.fromTo('#s09-lock', { scale: 1 }, { scale: 1.015, duration: 9.4, ease: 'none' }, 0);
""")

# =================================================================== index
hosts = "\n".join(
    f'      <div id="{cid}" class="clip" data-composition-id="{cid}" data-composition-src="compositions/{cid}.html" '
    f'data-start="{s}" data-duration="{d}" data-track-index="1" data-track-kind="graphics" '
    f'data-width="1920" data-height="1080" style="z-index:{i + 2}"></div>'
    for i, (cid, s, d) in enumerate(SCENES))

INDEX = T(f"""<!doctype html>
<html lang="en" data-composition-variables='[{{"id":"color-ground","type":"color","label":"Background","default":"@CANVAS@"}},{{"id":"color-ink","type":"color","label":"Text","default":"@INK@"}}]'>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <script src="assets/js/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: @CANVAS@; }}
      #root {{ width: 100%; height: 100%; position: relative; background: @CANVAS@; }}
      #ground {{ position: absolute; inset: 0; z-index: 1; background-color: @CANVAS@;
        background-image: linear-gradient(@GRID@ 1px, transparent 1px), linear-gradient(90deg, @GRID@ 1px, transparent 1px);
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
      window.__timelines = window.__timelines || {{}};
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
""")
(ROOT / "index.html").write_text(INDEX)
print("wrote", len(SCENES), "scenes")
for cid, s, d in SCENES:
    print(f"  {cid}  {s:6.2f} - {s + d:6.2f}")
print("typing ends at s02 +", round(S02_TYPE_END, 2))
