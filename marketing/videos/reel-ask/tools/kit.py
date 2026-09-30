"""Shared kit for the "Ask Chuk Chat to ..." micro-reels.

One reel = one standalone HyperFrames composition, 1080x1920, 30 fps:
  title card -> Android phone slides up -> prompt -> dots -> answer + result card
  -> swipe into the full-screen result -> small "chuk.chat" tag.

Coordinates:
  * The canvas is in px (1080x1920).
  * Everything inside the phone screen (.scr) is in dp: the screen is
    411 x 822 dp, drawn with CSS zoom Z = 800 / 411, so 18 dp -> 35 px.
    The smallest UI text is 17.5 dp = 34 px on the canvas.

Sources (read-only): the Android store screenshots
(fastlane/metadata/android/en-US/images/phoneScreenshots) for the chat look,
chuk.chat layouts/partials/uc/onthego.html + assets/css/uc-assistant.css for the
assistant overlay, and marketing/videos/chuk-06-features/tools/kit.py for the
deterministic runtime.
"""
import html
import re

from icons import icon

GSAP = "https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"

W, H = 1080, 1920
SCR_W_DP, SCR_H_DP = 411, 822
SCR_W_PX = 800
Z = SCR_W_PX / SCR_W_DP  # 1.9465
BEZEL = 12
PH_W = SCR_W_PX + 2 * BEZEL          # 824
PH_H = round(SCR_H_DP * Z) + 2 * BEZEL  # 1624
PH_LEFT = (W - PH_W) // 2            # 128
PH_TOP = 122                         # safe margin 120 px


def esc(s):
    return html.escape(s, quote=False)


def md_words(text, cls="w"):
    """Split text into word spans for streaming. **bold** is kept as bold spans."""
    out = []
    for part in re.split(r"(\*\*[^*]+\*\*)", text):
        if not part:
            continue
        bold = part.startswith("**") and part.endswith("**")
        seg = part[2:-2] if bold else part
        for m in re.finditer(r"\s*\S+\s*", seg):
            c = f"{cls} wb" if bold else cls
            out.append(f'<span class="{c}">{esc(m.group(0))}</span>')
    return "".join(out)


def md_inline(text):
    """**bold** -> <b>, everything else escaped (no streaming spans)."""
    out = []
    for part in re.split(r"(\*\*[^*]+\*\*)", text):
        if part.startswith("**") and part.endswith("**") and len(part) > 4:
            out.append(f"<b>{esc(part[2:-2])}</b>")
        else:
            out.append(esc(part))
    return "".join(out)


# ---------------------------------------------------------------- small glyphs
BACK = ('<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12H4.5M10.5 5.5 4 12l6.5 6.5" fill="none" '
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>')
SHARE = ('<svg viewBox="0 0 24 24" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" '
         'stroke-linejoin="round"><circle cx="18" cy="5.5" r="2.6"/><circle cx="6" cy="12" r="2.6"/><circle cx="18" cy="18.5" r="2.6"/>'
         '<path d="m8.4 10.8 7.2-4M8.4 13.2l7.2 4"/></g></svg>')
LOCK = ('<svg viewBox="0 0 24 24" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" '
        'stroke-linejoin="round"><rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/></g></svg>')
PIN = ('<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 1.8a7.6 7.6 0 0 0-7.6 7.6c0 5.5 7.6 12.8 7.6 12.8s7.6-7.3 7.6-12.8A7.6 7.6 0 0 0 12 1.8Z" '
       'fill="currentColor" stroke="#FFFFFF" stroke-width="1.4"/><circle cx="12" cy="9.4" r="2.9" fill="#FFFFFF"/></svg>')

LOGO_PATHS = (
    '<path d="M2365 4644 c-123 -17 -233 -41 -310 -66 -641 -213 -1147 -829 -1251 -1521 -20 -136 -20 -368 1 -493 79 -468 376 -837 785 -977 135 -46 265 -67 418 -67 208 0 366 34 609 131 88 35 103 44 107 67 6 27 106 651 106 659 0 2 -30 -20 -67 -50 -141 -112 -280 -186 -428 -229 -117 -33 -319 -33 -425 0 -123 39 -187 78 -285 177 -76 75 -99 106 -138 185 -60 120 -86 224 -94 370 -11 213 35 416 141 636 66 135 146 243 257 350 139 132 288 219 444 260 100 26 316 26 405 0 148 -44 273 -123 361 -228 29 -35 51 -54 54 -46 11 35 105 663 100 675 -11 31 -223 116 -370 149 -67 15 -353 27 -420 18z"/>'
    '<path d="M2758 3464 c-89 -16 -231 -60 -375 -115 -89 -35 -102 -43 -107 -67 -6 -28 -106 -651 -106 -659 0 -3 21 14 47 37 115 101 302 201 453 242 69 19 109 23 215 22 220 -1 342 -52 495 -204 70 -70 94 -102 133 -180 72 -144 90 -224 91 -410 0 -92 -5 -185 -13 -229 -30 -167 -114 -372 -211 -517 -73 -108 -235 -269 -340 -336 -170 -109 -284 -142 -485 -142 -133 0 -145 1 -238 33 -120 41 -239 121 -315 210 -30 36 -54 56 -57 49 -11 -34 -105 -663 -101 -674 11 -29 183 -102 331 -140 82 -21 131 -27 265 -31 261 -8 455 32 690 144 213 100 438 271 600 454 241 273 414 639 465 986 21 141 21 375 -1 501 -91 539 -471 940 -973 1026 -116 20 -354 20 -463 0z"/>')


def logo(cls, color):
    return (f'<svg class="{cls}" viewBox="0 0 500 500" aria-hidden="true"><g transform="translate(0,500) scale(0.1,-0.1)" '
            f'fill="{color}">{LOGO_PATHS}</g></svg>')


def conn_logo(name, cls="lg"):
    return f'<span class="{cls}"><img src="{{A}}logos/connectors/{name}.png" alt="" /></span>'


# ---------------------------------------------------------------- CSS
# {A} = asset prefix ("assets/" for index.html, "../assets/" for compositions/)
FONT_CSS = """
@font-face { font-family: "Chuk Mono"; src: url("{A}fonts/ChukMono-subset.woff2") format("woff2"); font-weight: 100 800; font-style: normal; font-display: block; }
@font-face { font-family: "Arimo"; src: url("{A}fonts/Arimo-subset.woff2") format("woff2"); font-weight: 400 700; font-style: normal; font-display: block; }
@font-face { font-family: "Inter"; src: url("{A}fonts/Inter-subset.woff2") format("woff2"); font-weight: 100 900; font-style: normal; font-display: block; }
@font-face { font-family: "Merriweather"; src: url("{A}fonts/Merriweather-subset.woff2") format("woff2"); font-weight: 400; font-style: normal; font-display: block; }
@font-face { font-family: "Merriweather"; src: url("{A}fonts/Merriweather-Bold-subset.woff2") format("woff2"); font-weight: 700; font-style: normal; font-display: block; }
"""

CANVAS_CSS = """
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; width: 1080px; height: 1920px; overflow: hidden; background: #26251F; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: #26251F; }
.fill { position: absolute; inset: 0; overflow: hidden; }
.ground { background: radial-gradient(ellipse 90% 62% at 50% 46%, #2D2C26 0%, #26251F 58%, #1C1B17 100%); }

/* ---------- Title card ---------- */
.tc { position: absolute; left: 60px; right: 60px; top: 0; bottom: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }
.tc-in { display: flex; flex-direction: column; align-items: center; }
.tc-logo { display: block; width: 92px; height: 92px; margin-bottom: 54px; }
.tt { margin: 0; font-family: "Inter", sans-serif; font-weight: 760; font-size: 110px; line-height: 1.05; letter-spacing: -0.03em; color: #F4F0E6; }
.tt .ln { display: block; white-space: nowrap; }
.tt .lw { display: inline-block; }
.tt .wd { display: inline-block; }
.tt .hl { color: #E07B5A; }

/* ---------- Phone ---------- */
.phone { position: absolute; left: PH_LEFTpx; top: PH_TOPpx; width: PH_Wpx; height: PH_Hpx; padding: BEZELpx; border-radius: 80px; background: #0B0B0A;
  box-shadow: inset 0 0 0 2.5px #4A4843, inset 0 0 0 4px #141412, 0 0 0 1px rgba(255, 255, 255, 0.07), 0 48px 96px -24px rgba(0, 0, 0, 0.8); }

/* ---------- End tag ---------- */
.tag { position: absolute; left: 0; right: 0; top: 1756px; height: 42px; display: flex; align-items: center; justify-content: center; gap: 14px;
  font-family: "Chuk Mono", monospace; font-size: 36px; font-weight: 500; letter-spacing: 0.01em; color: #E8E4D8; }
.tag svg { display: block; width: 38px; height: 38px; }
.mb-defs { position: absolute; width: 0; height: 0; overflow: hidden; }
"""

SCREEN_CSS = """
/* ---------- Screen (dp) ---------- */
.scr { position: relative; width: 411px; height: 822px; zoom: ZOOM; overflow: hidden; border-radius: 34px; background: #262624; color: #E8E4D8;
  font-family: "Arimo", sans-serif; font-size: 17.5px; line-height: 1.35; text-align: left;
  --fg: #E8E4D8; --fg85: rgba(232, 228, 216, 0.86); --fg70: rgba(232, 228, 216, 0.72); --muted: #908E87; --ph: #88867F;
  --line: rgba(232, 228, 216, 0.15); --lift: #31312E; --card: #2E2E2B; --acc: #D97757; --acc2: #F0A585; --ok: #86C795;
  --mono: "Chuk Mono", monospace; }
.scr *, .scr *::before, .scr *::after { box-sizing: border-box; }
.scr p { margin: 0; }
.scr svg { display: block; flex: none; }
.scr img { display: block; }
.layer { position: absolute; inset: 0; }

/* Status bar (above every layer) */
.sb { position: absolute; z-index: 60; left: 0; right: 0; top: 0; height: 38px; display: flex; align-items: center; justify-content: space-between;
  padding: 3px 22px 0 26px; font-size: 17.5px; font-weight: 500; letter-spacing: 0.2px; color: #F4F2EC; }
.sb-cam { position: absolute; left: 50%; top: 10px; width: 17px; height: 17px; margin-left: -8.5px; border-radius: 50%; background: #050506; box-shadow: inset 0 0 0 3px #121214; }
.sb-sys { display: flex; align-items: center; gap: 5px; }
.sb-sys svg { width: 17px; height: 17px; }
.hbar { position: absolute; z-index: 61; left: 50%; bottom: 7px; width: 110px; height: 4.5px; margin-left: -55px; border-radius: 3px; background: rgba(240, 238, 232, 0.92); }

/* Top bar */
.tb { position: absolute; z-index: 20; left: 12px; right: 12px; top: 44px; height: 48px; display: flex; align-items: center; gap: 8px; }
.veil { position: absolute; z-index: 19; left: 0; right: 0; top: 0; height: 132px;
  background: linear-gradient(180deg, rgba(38, 38, 36, 0.98) 0%, rgba(38, 38, 36, 0.95) 62%, rgba(38, 38, 36, 0.55) 84%, rgba(38, 38, 36, 0) 100%); }
.tb-b { flex: none; width: 48px; height: 48px; border-radius: 50%; background: var(--lift); display: flex; align-items: center; justify-content: center; color: var(--fg); }
.tb-b svg { width: 23px; height: 23px; }
.tb-new { background: var(--acc); color: #FFFFFF; }
.tb-t { position: relative; flex: 0 1 auto; min-width: 0; height: 48px; padding: 0 18px; border-radius: 24px; background: var(--lift); display: flex; align-items: center;
  font-size: 17.5px; font-weight: 700; color: #DAD6CB; white-space: nowrap; overflow: hidden; }
.tb-t span { overflow: hidden; text-overflow: ellipsis; }
.tb-sp { flex: 1; }
.tb-chip { flex: none; height: 34px; padding: 0 12px; border-radius: 17px; display: flex; align-items: center; font-size: 17.5px; font-weight: 700; }

/* Chat viewport, bottom-anchored column */
.cv { position: absolute; left: 0; right: 0; top: 0; bottom: 146px; overflow: hidden; }
.col { position: absolute; left: 16px; right: 16px; bottom: 6px; }
.r { height: 0; overflow: hidden; }

/* User bubble (store screenshot: #B6674D, 1.3 dp edge #C48B77, mono text #E8E4D8) */
.ub { display: flex; justify-content: flex-end; padding-top: 16px; }
.ub-b { max-width: 318px; padding: 11px 15px 12px; border: 1.3px solid #C48B77; border-radius: 15px; background: #B6674D; color: #E8E4D8;
  font-family: var(--mono); font-size: 18px; line-height: 1.42; }
/* File message row (DESIGN.md: radius 18) */
.fm { display: flex; justify-content: flex-end; padding-top: 16px; }
.fm-b { display: flex; align-items: center; gap: 12px; width: 300px; padding: 11px 16px 11px 11px; border: 1px solid var(--line); border-radius: 18px; background: var(--lift); }
.fm-ic { flex: none; width: 46px; height: 54px; border-radius: 10px; background: rgba(217, 119, 87, 0.18); color: var(--acc2); display: flex; align-items: center; justify-content: center; }
.fm-ic svg { width: 26px; height: 26px; }
.fm-t { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.fm-t b { font-size: 18px; font-weight: 700; color: var(--fg); }
.fm-t small { font-size: 17.5px; color: var(--fg70); }

/* Meta row: dots -> running -> worked for */
.meta { position: relative; height: 50px; padding-top: 12px; }
.meta > * { position: absolute; left: 0; top: 12px; }
.dots { display: flex; align-items: center; gap: 7px; height: 36px; padding: 0 15px; border-radius: 18px; background: #34342F; }
.dots i { display: block; width: 8.5px; height: 8.5px; border-radius: 50%; background: #B9B6AC; }
.m-run, .m-done { display: flex; align-items: center; gap: 8px; height: 36px; font-size: 17.5px; color: var(--muted); white-space: nowrap; }
.m-done svg { width: 17px; height: 17px; }
.spin { display: block; flex: none; width: 17px; height: 17px; border: 2.4px solid rgba(232, 228, 216, 0.16); border-top-color: var(--acc); border-radius: 50%; }

/* Tool steps */
.st { display: flex; align-items: center; gap: 12px; padding-top: 8px; font-size: 17.5px; color: var(--muted); white-space: nowrap; }
.st b { font-weight: 400; color: var(--fg85); }
.st-badge { flex: none; width: 34px; height: 34px; border-radius: 50%; border: 1px solid var(--line); background: #262624; display: flex; align-items: center; justify-content: center; color: var(--muted); }
.st-badge svg { width: 17px; height: 17px; }
.st-badge.lgb { background: #FFFFFF; border-color: #FFFFFF; overflow: hidden; }
.st-badge.lgb img { width: 22px; height: 22px; object-fit: contain; }

/* Answer (mono, like the app) */
.ans { padding-top: 8px; font-family: var(--mono); font-size: 18px; line-height: 1.45; color: var(--fg); }
.ans .wb, .ans b { font-weight: 700; }
.w { display: inline; }
.cardw { padding-top: 14px; padding-bottom: 2px; }

/* Composer (store screenshot: 2 dp #565551 edge, placeholder #88867F, coral caret) */
.cmp { position: absolute; z-index: 21; left: 10px; right: 10px; bottom: 24px; height: 114px; border: 2px solid #565551; border-radius: 30px; background: #262624; }
.cmp-f { position: absolute; left: 20px; top: 15px; display: flex; align-items: center; gap: 1px; font-size: 18px; color: var(--ph); white-space: nowrap; }
.caret { display: block; width: 2px; height: 24px; background: var(--acc); }
.cmp-row { position: absolute; left: 12px; right: 10px; bottom: 10px; height: 46px; display: flex; align-items: center; gap: 12px; color: #BDBAB1; }
.cmp-row .g { flex: 1; }
.cmp-plus svg { width: 26px; height: 26px; }
.cmp-pill { display: flex; align-items: center; gap: 6px; height: 42px; padding: 0 14px; border: 2px solid #565551; border-radius: 21px; }
.cmp-pill svg { width: 20px; height: 20px; }
.cmp-pill .dn { width: 15px; height: 15px; }
.cmp-mic svg { width: 24px; height: 24px; }
.cmp-send { width: 46px; height: 46px; border-radius: 50%; background: var(--acc); color: #FFFFFF; display: flex; align-items: center; justify-content: center; }
.cmp-send svg { width: 23px; height: 23px; }

/* Touch indicator (Android "show taps") */
.tap { position: absolute; z-index: 58; left: 0; top: 0; width: 50px; height: 50px; margin: -25px 0 0 -25px; border-radius: 50%;
  background: rgba(255, 255, 255, 0.34); border: 2px solid rgba(255, 255, 255, 0.6); opacity: 0; }

/* Full-screen result (slides in from the right) */
.fs { position: absolute; inset: 0; z-index: 30; overflow: hidden; background: #1E1E1C; }
.dim { position: absolute; inset: 0; z-index: 29; background: #000000; opacity: 0; }
.fs-tb { position: absolute; z-index: 5; left: 12px; right: 12px; top: 44px; height: 48px; display: flex; align-items: center; gap: 8px; }
.fs-veil { position: absolute; z-index: 4; left: 0; right: 0; top: 0; height: 112px; background: linear-gradient(180deg, rgba(30, 30, 28, 0.97) 0%, rgba(30, 30, 28, 0.9) 50%, rgba(30, 30, 28, 0) 100%); }

/* Document viewer (shared by PDF-like results) */
.dv { position: absolute; left: 0; right: 0; top: 104px; bottom: 96px; display: flex; justify-content: center; }
.pg { width: 387px; padding: 26px 24px; border-radius: 6px; background: #FFFFFF; color: #29251F; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45); transform-origin: 50% 40%; }
.sb, .hbar { transition: none; }

/* Artifact card (in chat) */
.ac { border: 1.5px solid rgba(232, 228, 216, 0.17); border-radius: 18px; background: var(--card); padding: 12px; }
.ac-top { display: flex; align-items: center; gap: 14px; }
.ac-txt { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.ac-txt b { font-size: 18px; font-weight: 700; color: var(--fg); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ac-txt small { font-size: 17.5px; color: var(--fg70); white-space: nowrap; }
.ac-btns { display: flex; justify-content: flex-end; align-items: center; gap: 10px; margin-top: 12px; }
.ac-btn { height: 44px; padding: 0 18px; border-radius: 22px; display: flex; align-items: center; gap: 7px; font-size: 17.5px; font-weight: 700; color: var(--acc2); border: 1.5px solid rgba(217, 119, 87, 0.45); }
.ac-btn.pri { background: var(--acc); border-color: var(--acc); color: #FFFFFF; }
.ac-btn svg { width: 19px; height: 19px; }
"""


def tb_chat(title):
    """Chat top bar: menu, chat title pill (fades in with the answer), panel, new chat."""
    return (f'<div class="veil"></div><div class="tb">'
            f'<span class="tb-b">{icon("h-menu01")}</span>'
            f'<span class="tb-t tb-title"><span>{esc(title)}</span></span>'
            f'<span class="tb-sp"></span>'
            f'<span class="tb-b">{icon("h-copy01")}</span>'
            f'<span class="tb-b tb-new">{icon("h-pencil-edit02")}</span></div>')


def tb_full(title, actions=("download",), chip=None, chip_style=""):
    acts = ""
    for a in actions:
        g = {"download": icon("h-download01"), "share": SHARE, "more": icon("h-more-horizontal")}[a]
        acts += f'<span class="tb-b">{g}</span>'
    ch = f'<span class="tb-chip" style="{chip_style}">{esc(chip)}</span>' if chip else ""
    return (f'<div class="fs-veil"></div><div class="fs-tb">'
            f'<span class="tb-b">{BACK}</span>'
            f'<span class="tb-t"><span>{esc(title)}</span></span>{ch}'
            f'<span class="tb-sp"></span>{acts}</div>')


def status_bar(clock):
    return (f'<div class="sb"><span>{esc(clock)}</span><span class="sb-cam"></span>'
            f'<span class="sb-sys">{icon("asst-wifi")}{icon("asst-cell")}{icon("asst-battery")}</span></div>')


def composer():
    return (f'<div class="cmp"><div class="cmp-f"><i class="caret"></i><span>Ask me anything !</span></div>'
            f'<div class="cmp-row"><span class="cmp-plus">{icon("h-plus-sign")}</span>'
            f'<span class="cmp-pill">{icon("h-flash")}{icon("h-arrow-down01", "dn")}</span>'
            f'<span class="g"></span><span class="cmp-mic">{icon("h-mic02")}</span>'
            f'<span class="cmp-send">{icon("h-send-horizontal")}</span></div></div>')


def step_row(s, i):
    """One tool step. s = {"logo": "linear"} or {"icon": "flash|search|file"}, "text", "detail"."""
    if s.get("logo"):
        badge = f'<span class="st-badge lgb"><img src="{{A}}logos/connectors/{s["logo"]}.png" alt="" /></span>'
    else:
        ic = {"flash": "h-flash", "search": "h-search01", "file": "h-file01", "ok": "h-tick02"}[s.get("icon", "flash")]
        badge = f'<span class="st-badge">{icon(ic)}</span>'
    det = f' <b>{esc(s["detail"])}</b>' if s.get("detail") else ""
    return f'<div data-layout-allow-overflow class="r r-st r-st{i}"><div class="st">{badge}<span>{esc(s["text"])}{det}</span></div></div>'


# ---------------------------------------------------------------- JS runtime
RUNTIME = r"""
  var R = document.querySelector('[data-composition-id="main"]');
  var $ = function (s) { return R.querySelector(s); };
  var $$ = function (s) { return Array.prototype.slice.call(R.querySelectorAll(s)); };
  var tl = gsap.timeline({ paused: true });
  var ups = [];
  var SCR = $('.scr');
  var K = SCR.getBoundingClientRect().width / 411;           // canvas px per dp
  function c01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function sm(x) { x = c01(x); return x * x * (3 - 2 * x); }
  function el(s) { return typeof s === 'string' ? $(s) : s; }
  function kNow() { return SCR.getBoundingClientRect().width / 411; }
  function hOf(r) { return r.firstElementChild.getBoundingClientRect().height / kNow(); }
  function rectIn(e, ref) {            // dp rect of e relative to ref
    var k = kNow(), a = e.getBoundingClientRect(), b = ref.getBoundingClientRect();
    return { x: (a.left - b.left) / k, y: (a.top - b.top) / k, w: a.width / k, h: a.height / k };
  }
  function setText(e, s) { if (e.__v !== s) { e.textContent = s; e.__v = s; } }
  function rise(s, t, o) {
    o = o || {};
    tl.fromTo(el(s), { opacity: 0, y: o.y == null ? 12 : o.y, scale: o.s == null ? 1 : o.s },
      { opacity: 1, y: 0, scale: 1, duration: o.d || 0.35, ease: o.ease || 'power3.out' }, t);
  }
  function pop(s, t, o) {
    o = o || {};
    tl.fromTo(el(s), { opacity: 0, scale: o.s || 0.6 }, { opacity: 1, scale: 1, duration: o.d || 0.32, ease: o.ease || 'back.out(2.2)' }, t);
  }
  function fadeIn(s, t, d) { tl.fromTo(el(s), { opacity: 0 }, { opacity: 1, duration: d || 0.3, ease: 'power1.out' }, t); }
  function fadeOut(s, t, d) { tl.fromTo(el(s), { opacity: 1 }, { opacity: 0, duration: d || 0.25, ease: 'power1.in', immediateRender: false }, t); }
  function showBetween(e, t0, t1) {
    e = el(e);
    ups.push(function (t) { var d = (t >= t0 && t < t1) ? '' : 'none'; if (e.__d !== d) { e.style.display = d; e.__d = d; } });
  }
  // A row (.r) grows from 0 to its natural height: the column is bottom-anchored, so it pushes up.
  function grow(s, t, d, ease) {
    var r = el(s), h = hOf(r);
    d = d || 0.4;
    tl.fromTo(r, { height: 0 }, { height: h, duration: d, ease: ease || 'power2.out', immediateRender: false }, t);
    tl.set(r, { height: 'auto' }, t + d + 0.001);   // nested rows may grow later
    return h;
  }
  // Layout as it is at the end (every row open, folded rows closed): used to aim the tap.
  function atFinal(fn) {
    var rows = $$('.r'), saved = rows.map(function (r) { return r.style.height; });
    rows.forEach(function (r) { r.style.height = r.classList.contains('r-fold') ? '0px' : 'auto'; });
    var res = fn();
    rows.forEach(function (r, i) { r.style.height = saved[i]; });
    return res;
  }
  function fold(s, t, d) {
    var r = el(s), h = hOf(r);
    tl.fromTo(r, { height: h }, { height: 0, duration: d || 0.35, ease: 'power2.inOut', immediateRender: false }, t);
  }
  // Streams the words of block `blk` (inside row `r`) and grows the row line by line.
  function streamGrow(r, blk, t0, wps, fade) {
    r = el(r); blk = el(blk);
    var ws = Array.prototype.slice.call(blk.querySelectorAll('.w'));
    var top = blk.getBoundingClientRect().top, K = kNow();
    var padTop = parseFloat(getComputedStyle(blk).paddingTop) || 0;
    var lines = [], lineStart = [];
    ws.forEach(function (w, i) {
      var b = (w.getBoundingClientRect().bottom - top) / K;
      var last = lines.length ? lines[lines.length - 1] : -1;
      if (b > last + 2) { lines.push(b); lineStart.push(t0 + i / wps); }
      else { lines[lines.length - 1] = Math.max(last, b); }
    });
    var full = hOf(r);
    fade = fade || 0.12;
    ups.push(function (t) {
      for (var i = 0; i < ws.length; i++) {
        var o = c01((t - t0 - i / wps) / fade);
        if (ws[i].__o !== o) { ws[i].style.opacity = o; ws[i].__o = o; }
      }
      var h = 0;
      if (t >= t0) {
        h = padTop * sm((t - t0) / 0.12) + (lines[0] - padTop) * sm((t - t0) / 0.14);
        for (var j = 1; j < lines.length; j++) h += (lines[j] - lines[j - 1]) * sm((t - lineStart[j]) / 0.16);
        if (t >= lineStart[lines.length - 1] + 0.16) h = full;
      }
      var hs = h.toFixed(2) + 'px';
      if (r.__h !== hs) { r.style.height = hs; r.__h = hs; }
    });
    return t0 + ws.length / wps;
  }
  function stream(blk, t0, wps, fade) {
    var ws = Array.prototype.slice.call(el(blk).querySelectorAll('.w'));
    fade = fade || 0.12;
    ups.push(function (t) {
      for (var i = 0; i < ws.length; i++) {
        var o = c01((t - t0 - i / wps) / fade);
        if (ws[i].__o !== o) { ws[i].style.opacity = o; ws[i].__o = o; }
      }
    });
    return t0 + ws.length / wps;
  }
  function spin(e) { e = el(e); ups.push(function (t) { e.style.transform = 'rotate(' + ((t * 420) % 360).toFixed(1) + 'deg)'; }); }
  function count(e, a, b, t0, t1, fmt) {
    e = el(e);
    ups.push(function (t) { var k = c01((t - t0) / (t1 - t0)); k = 1 - Math.pow(1 - k, 3); setText(e, fmt(a + (b - a) * k)); });
  }
  function draw(s, t, d, ease) {
    var e = el(s), L = Math.ceil(e.getTotalLength()) + 2;
    e.style.strokeDasharray = L + ' ' + L;
    tl.fromTo(e, { strokeDashoffset: L }, { strokeDashoffset: 0, duration: d, ease: ease || 'power1.inOut' }, t);
  }
  function dots(s, t0, t1) {
    var ds = $$(s + ' i');
    ups.push(function (t) {
      for (var i = 0; i < ds.length; i++) {
        var ph = (t - t0) * 2.6 - i * 0.22;
        var k = (t >= t0 && t < t1) ? Math.max(0, Math.sin(ph * Math.PI * 2)) : 0;
        ds[i].style.transform = 'translateY(' + (-4.5 * k).toFixed(2) + 'px)';
        ds[i].style.opacity = (0.45 + 0.55 * k).toFixed(3);
      }
    });
  }
  function tapAt(target, t, rc) {
    var tp = $('.tap');
    rc = rc || rectIn(el(target), SCR);
    tp.style.left = (rc.x + rc.w / 2).toFixed(1) + 'px';
    tp.style.top = (rc.y + rc.h / 2).toFixed(1) + 'px';
    tl.fromTo(tp, { opacity: 0, scale: 0.5 }, { opacity: 1, scale: 1, duration: 0.14, ease: 'power2.out', immediateRender: false }, t);
    tl.fromTo(tp, { opacity: 1, scale: 1 }, { opacity: 0, scale: 1.25, duration: 0.3, ease: 'power1.in', immediateRender: false }, t + 0.2);
    tl.fromTo(el(target), { scale: 1 }, { scale: 0.94, duration: 0.1, ease: 'power2.in', immediateRender: false }, t);
    tl.fromTo(el(target), { scale: 0.94 }, { scale: 1, duration: 0.3, ease: 'back.out(3)', immediateRender: false }, t + 0.12);
  }
"""

FINISH = r"""
  var drv = { t: 0 };
  tl.to(drv, { t: DUR, duration: DUR, ease: 'none', onUpdate: function () {
    for (var i = 0; i < ups.length; i++) ups[i](drv.t);
  } }, 0);
  for (var i = 0; i < ups.length; i++) ups[i](0);
  window.__timelines["main"] = tl;
"""

# Title in, phone up, swipe to the full-screen result, end tag.
FRAME_JS = r"""
  // Title: fit the longest line into 960 px, words rise in from frame 0.
  (function () {
    var tt = $('.tt'), base = parseFloat(getComputedStyle(tt).fontSize), mw = 0;
    $$('.tt .lw').forEach(function (l) { mw = Math.max(mw, l.getBoundingClientRect().width); });
    if (mw > 960) tt.style.fontSize = (base * 960 / mw).toFixed(1) + 'px';
  })();
  tl.fromTo('.tc-logo', { opacity: 0.35, scale: 0.9 }, { opacity: 1, scale: 1, duration: 0.45, ease: 'power3.out' }, 0);
  $$('.tt .wd').forEach(function (w, i) {
    tl.fromTo(w, { opacity: 0.18, y: 34 }, { opacity: 1, y: 0, duration: 0.42, ease: 'power3.out' }, i * 0.05);
  });
  tl.fromTo('.tc-in', { opacity: 1, scale: 1, y: 0 }, { opacity: 0, scale: 0.94, y: -50, duration: 0.3, ease: 'power2.in', immediateRender: false }, T.title_out);
  // Phone: slides up and settles (reference: 0.4 s, lands on the drop).
  tl.fromTo('.phone', { opacity: 0, y: 260, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: T.phone_land - T.phone_in, ease: 'power3.out' }, T.phone_in);
  // Swipe into the full-screen result.
  var SW = T.swipe, SD = T.swipe_d;
  tl.fromTo('.fs', { x: 411 }, { x: 0, duration: SD, ease: 'power3.inOut' }, SW);
  tl.fromTo('.surface', { x: 0 }, { x: -130, duration: SD, ease: 'power3.inOut' }, SW);
  tl.fromTo('.dim', { opacity: 0 }, { opacity: 0.55, duration: SD, ease: 'power2.in' }, SW);
  showBetween($('.fs'), SW - 0.001, 999);
  showBetween($('.surface'), -1, SW + SD + 0.02);   // fully covered once the result has landed
  // Horizontal motion blur during the swipe (SVG filter, off outside the move).
  var blur = $('#mb-blur'), fsEl = $('.fs'), sfEl = $('.surface');
  ups.push(function (t) {
    var k = (t > SW && t < SW + SD) ? Math.sin(Math.PI * (t - SW) / SD) : 0;
    var on = k > 0.02;
    var f = on ? 'url(#mb)' : 'none';
    if (fsEl.__f !== f) { fsEl.style.filter = f; sfEl.style.filter = f; fsEl.__f = f; }
    if (on) blur.setAttribute('stdDeviation', (7 * k).toFixed(2) + ' 0');
  });
  if ($('.fs-light-top')) tl.fromTo('.sb', { color: '#F4F2EC' }, { color: '#1E1E1C', duration: 0.2, ease: 'none' }, SW + SD * 0.55);
  if ($('.fs-light-bottom')) tl.fromTo('.hbar', { backgroundColor: 'rgba(240,238,232,0.92)' }, { backgroundColor: 'rgba(30,30,28,0.85)', duration: 0.2, ease: 'none' }, SW + SD * 0.55);
  // End tag, last 0.8 s.
  tl.fromTo('.tag', { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.4, ease: 'power3.out' }, T.tag);
"""


MB_FILTER = ('<svg class="mb-defs" width="0" height="0" aria-hidden="true"><defs><filter id="mb" x="-8%" y="0%" width="116%" height="100%" '
             'color-interpolation-filters="sRGB"><feGaussianBlur id="mb-blur" stdDeviation="0 0"/></filter></defs></svg>')


def page(title, T, css, body, js, dur, prefix):
    """Standalone composition (root not wrapped in <template>)."""
    import json
    full_css = (FONT_CSS + CANVAS_CSS + SCREEN_CSS + css)
    full_css = (full_css.replace("PH_LEFT", str(PH_LEFT)).replace("PH_TOP", str(PH_TOP)).replace("PH_W", str(PH_W))
                .replace("PH_H", str(PH_H)).replace("BEZEL", str(BEZEL)).replace("ZOOM", f"{Z:.5f}"))
    doc = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1080, height=1920" />
    <title>{esc(title)}</title>
    <script src="{GSAP}"></script>
    <style>
{full_css}
    </style>
  </head>
  <body>
    <!-- Generated by tools/build.py from reels/*.json. Do not edit by hand. -->
    <div id="root" data-composition-id="main" data-start="0" data-duration="{dur}" data-fps="30" data-width="1080" data-height="1920">
{body.replace('<!--MBFILTER-->', MB_FILTER)}
    </div>
    <script>
(function () {{
  var DUR = {dur};
  var T = {json.dumps(T)};
  function build() {{
{RUNTIME}
{js}
{FRAME_JS}
{FINISH}
  }}
  var fams = ['18px "Chuk Mono"', '700 18px "Chuk Mono"', '18px Arimo', '700 18px Arimo', '760 100px Inter', '18px Merriweather', '700 18px Merriweather'];
  Promise.all(fams.map(function (f) {{ return document.fonts.load(f); }}))
    .then(function () {{ return document.fonts.ready; }})
    .then(build, build);
}})();
    </script>
  </body>
</html>
"""
    return doc.replace("{A}", prefix)
