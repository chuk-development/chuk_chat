"""Shared pieces for reel 01: text measurement, the kinetic-line layout, the
deterministic JS animation engine and the base CSS.

Everything on screen is one monolithic composition (index.html). Every
animated value is a pure function of the timeline time t, so any frame can be
rendered on its own (seek-safe).
"""
import html
import os
import re

from PIL import ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
INTER_TTF = os.path.join(PROJECT, "_work", "InterVariable.ttf")  # measurement only (same outlines as the woff2 subset)
UBUNTU_TTF = os.path.join(PROJECT, "_work", "Ubuntu-wdth-wght.ttf")

W, H = 1080, 1920
FPS = 30
DUR = 59.7

PAPER = "#FDFBF7"
INK = "#26251F"
INK_SOFT = "#5F5D55"
INK_FAINT = "#8C8A80"
CORAL = "#D97757"


def esc(s):
    return html.escape(s, quote=False)


# ---------------------------------------------------------------- measurement
_FONTS = {}


def _font(path, size, axes):
    key = (path, size, tuple(axes))
    if key not in _FONTS:
        f = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.RAQM)
        f.set_variation_by_axes(list(axes))
        _FONTS[key] = f
    return _FONTS[key]


def text_w(text, size, wght=400, ls_em=0.0, family="inter"):
    """Rendered advance width in px (Chrome: font-optical-sizing auto -> opsz = px, clamped)."""
    if family == "inter":
        f = _font(INTER_TTF, size, (min(32, max(14, size)), wght))
    else:
        f = _font(UBUNTU_TTF, size, (100, wght))
    return f.getlength(text) + ls_em * size * len(text)


def wrap(text, size, wght, max_w, ls_em=0.0, family="inter"):
    """Greedy word wrap with the real font. Returns a list of lines."""
    words = text.split()
    lines, cur = [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if cur and text_w(t, size, wght, ls_em, family) > max_w:
            lines.append(cur)
            cur = w
        else:
            cur = t
    if cur:
        lines.append(cur)
    return lines


# ---------------------------------------------------------------- kinetic lines
KFS = 112          # headline font size
KW = 540           # headline weight
KLS = -0.02        # letter spacing (em)
KLH = 1.24         # line box height factor
ICON_BOX = 124     # inline icon box
ICON_GAP = 18      # gap between a word and an inline icon


def space_w(size=KFS, wght=KW, ls=KLS):
    return text_w("a a", size, wght, ls) - text_w("aa", size, wght, ls)


class Word:
    def __init__(self, text, t_in, cls=""):
        self.kind, self.text, self.t_in, self.cls = "w", text, t_in, cls
        self.w = text_w(text, KFS, KW, KLS)


class Icon:
    def __init__(self, html_inner, t_open, t_pop=None, box=ICON_BOX):
        self.kind, self.inner, self.t_open = "i", html_inner, t_open
        self.t_pop = t_open + 0.08 if t_pop is None else t_pop
        self.w = box
        self.box = box


def line_layout(tokens, t, cx=W / 2):
    """x (left edge) of each visible token at time t; None when not visible yet."""
    sp = space_w()
    vis = []
    for tok in tokens:
        on = (tok.t_in <= t + 1e-6) if tok.kind == "w" else (tok.t_open <= t + 1e-6)
        vis.append(on)
    items = [(i, tok) for i, tok in enumerate(tokens) if vis[i]]
    total = 0.0
    gaps = []
    for k, (i, tok) in enumerate(items):
        if k > 0:
            prev = items[k - 1][1]
            g = ICON_GAP if (prev.kind == "i" or tok.kind == "i") else sp
            gaps.append(g)
            total += g
        total += tok.w
    x = cx - total / 2
    out = [None] * len(tokens)
    for k, (i, tok) in enumerate(items):
        if k > 0:
            x += gaps[k - 1]
        out[i] = x
        x += tok.w
    return out


def kinetic(prefix, lines, ys, t_out=None, out_stagger=0.035, move=0.3):
    """Lay out a kinetic headline block.

    lines: list of token lists; ys: centre y of each line.
    Returns (html, js). Words rise in at t_in; the line re-centres as words
    arrive; an icon slot opens (neighbours slide apart) and the icon pops in.
    """
    h, js = [], []
    lh = KFS * KLH
    n_out = 0
    for li, (toks, y) in enumerate(zip(lines, ys)):
        events = sorted({(tok.t_in if tok.kind == "w" else tok.t_open) for tok in toks})
        final = line_layout(toks, 1e9)
        for ti, tok in enumerate(toks):
            tid = f"{prefix}-{li}-{ti}"
            xs = []
            for e in events:
                lay = line_layout(toks, e)
                if lay[ti] is not None:
                    xs.append((e, lay[ti] - final[ti]))
            # A token that arrives while its neighbours re-centre starts attached to its
            # left neighbour's previous position and slides with it (no overlap).
            t_first = tok.t_in if tok.kind == "w" else tok.t_open
            prev_lay = line_layout(toks, t_first - 1e-3)
            left = None
            for lj in range(ti - 1, -1, -1):
                if prev_lay[lj] is not None:
                    left = lj
                    break
            if left is not None and tok.kind == "w":
                lt = toks[left]
                g = ICON_GAP if (lt.kind == "i" or tok.kind == "i") else space_w()
                attach = prev_lay[left] + lt.w + g - final[ti]
                if abs(attach - xs[0][1]) > 0.5:
                    xs.insert(0, (t_first - 1e-3, attach))
            if tok.kind == "w":
                h.append(f'<span id="{tid}" class="kw {tok.cls}" style="left:{final[ti]:.1f}px;top:{y - lh / 2:.1f}px">{esc(tok.text)}</span>')
            else:
                top = y - tok.box / 2 - 4
                h.append(f'<span id="{tid}" class="ki" style="left:{final[ti]:.1f}px;top:{top:.1f}px;width:{tok.box}px;height:{tok.box}px">'
                         f'<span class="ki-in">{tok.inner}</span></span>')
            sel = "#" + tid
            # x keyframes (re-centering)
            first_t, first_x = xs[0]
            js.append(f"A('{sel}','x',0,0,{first_x:.1f},{first_x:.1f});")
            prev = first_x
            for e, x in xs[1:]:
                if abs(x - prev) > 0.05:
                    js.append(f"A('{sel}','x',{e:.3f},{move},{prev:.1f},{x:.1f},'o3');")
                    prev = x
            if tok.kind == "w":
                js.append(f"A('{sel}','o',{tok.t_in:.3f},0.22,0,1,'o2');")
                js.append(f"A('{sel}','y',{tok.t_in:.3f},0.36,46,0,'o3');")
            else:
                js.append(f"A('{sel} .ki-in','o',{tok.t_pop:.3f},0.12,0,1,'o2');")
                js.append(f"A('{sel} .ki-in','s',{tok.t_pop:.3f},0.42,0.2,1,'bk');")
                js.append(f"A('{sel} .ki-in','r',{tok.t_pop:.3f},0.5,-14,0,'o3');")
            if t_out is not None:
                to = t_out + n_out * out_stagger
                n_out += 1
                tgt = sel if tok.kind == "w" else sel + " .ki-in"
                js.append(f"A('{tgt}','o',{to:.3f},0.2,1,0,'i2');")
                if tok.kind == "w":
                    js.append(f"A('{sel}','y',{to:.3f},0.26,0,-34,'i2');")
                else:
                    js.append(f"A('{tgt}','s',{to:.3f},0.22,1,0.4,'i2');")
    return "\n".join(h), "\n".join(js)


# ---------------------------------------------------------------- logo
LOGO_PATHS = (
    '<path d="M2365 4644 c-123 -17 -233 -41 -310 -66 -641 -213 -1147 -829 -1251 -1521 -20 -136 -20 -368 1 -493 79 -468 376 -837 785 -977 135 -46 265 -67 418 -67 208 0 366 34 609 131 88 35 103 44 107 67 6 27 106 651 106 659 0 2 -30 -20 -67 -50 -141 -112 -280 -186 -428 -229 -117 -33 -319 -33 -425 0 -123 39 -187 78 -285 177 -76 75 -99 106 -138 185 -60 120 -86 224 -94 370 -11 213 35 416 141 636 66 135 146 243 257 350 139 132 288 219 444 260 100 26 316 26 405 0 148 -44 273 -123 361 -228 29 -35 51 -54 54 -46 11 35 105 663 100 675 -11 31 -223 116 -370 149 -67 15 -353 27 -420 18z"/>'
    '<path d="M2758 3464 c-89 -16 -231 -60 -375 -115 -89 -35 -102 -43 -107 -67 -6 -28 -106 -651 -106 -659 0 -3 21 14 47 37 115 101 302 201 453 242 69 19 109 23 215 22 220 -1 342 -52 495 -204 70 -70 94 -102 133 -180 72 -144 90 -224 91 -410 0 -92 -5 -185 -13 -229 -30 -167 -114 -372 -211 -517 -73 -108 -235 -269 -340 -336 -170 -109 -284 -142 -485 -142 -133 0 -145 1 -238 33 -120 41 -239 121 -315 210 -30 36 -54 56 -57 49 -11 -34 -105 -663 -101 -674 11 -29 183 -102 331 -140 82 -21 131 -27 265 -31 261 -8 455 32 690 144 213 100 438 271 600 454 241 273 414 639 465 986 21 141 21 375 -1 501 -91 539 -471 940 -973 1026 -116 20 -354 20 -463 0z"/>')


def logo_svg(cls="", color="#F4EFE3"):
    c = f' class="{cls}"' if cls else ""
    return (f'<svg{c} viewBox="0 0 500 500" aria-hidden="true"><g transform="translate(0,500) scale(0.1,-0.1)" '
            f'fill="{color}">{LOGO_PATHS}</g></svg>')


def tile(cls=""):
    """The Chuk Chat app tile: ink rounded square, cream logo."""
    return f'<span class="tile {cls}">{logo_svg("tile-logo")}</span>'


def emoji(name, cls="em"):
    return f'<img class="{cls}" src="assets/emoji/{name}.png" alt="" />'


# ---------------------------------------------------------------- connector glyphs (simple-icons, CC0)
def _si_path(name):
    src = open(os.path.join(PROJECT, "assets", "logos", "svg", f"{name}.svg"), encoding="utf-8").read()
    return re.search(r'<path d="([^"]+)"', src).group(1)


BRANDS = {  # name: (circle colour, glyph colour)
    "notion": ("#FFFFFF", "#111111"),
    "linear": ("#5E6AD2", "#FFFFFF"),
    "github": ("#181717", "#FFFFFF"),
    "todoist": ("#E44332", "#FFFFFF"),
    "dropbox": ("#0061FF", "#FFFFFF"),
    "figma": ("#1E1E1E", "#FFFFFF"),
}


def glyph(name, cls="", color=None):
    fill = color or BRANDS[name][1]
    c = f' class="{cls}"' if cls else ""
    return f'<svg{c} viewBox="0 0 24 24" aria-hidden="true"><path fill="{fill}" d="{_si_path(name)}"/></svg>'


def brand_badge(name, cls=""):
    """Small square logo chip as the app shows a connector (white tile, brand glyph in brand colour)."""
    colour = {"notion": "#111111", "linear": "#5E6AD2", "github": "#181717", "todoist": "#E44332",
              "dropbox": "#0061FF", "figma": "#F24E1E"}[name]
    return f'<span class="bb {cls}">{glyph(name, "bb-g", colour)}</span>'


# ---------------------------------------------------------------- CSS
BASE_CSS = """
@font-face { font-family: "Inter"; src: url("assets/fonts/Inter-subset.woff2") format("woff2"); font-weight: 100 900; font-style: normal; font-display: block; }
@font-face { font-family: "Ubuntu"; src: url("assets/fonts/Ubuntu-subset.woff2") format("woff2"); font-weight: 100 800; font-stretch: 75% 100%; font-style: normal; font-display: block; }
@font-face { font-family: "Chuk Chat Mono"; src: url("assets/fonts/ChukChatMono-wght.woff2") format("woff2"); font-weight: 100 800; font-style: normal; font-display: block; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { margin: 0; width: 1080px; height: 1920px; overflow: hidden; background: #FDFBF7; }
#root { position: relative; width: 100%; height: 100%; overflow: hidden; background: #FDFBF7; color: #26251F;
  font-family: "Inter", sans-serif; font-optical-sizing: auto; -webkit-font-smoothing: antialiased; }
.scene { position: absolute; inset: 0; width: 100%; height: 100%; overflow: hidden; }
.abs { position: absolute; }
svg { display: block; }

/* background: warm paper + a soft dawn glow rising from the bottom */
.bg { position: absolute; inset: 0; background: #FDFBF7; }
.dawn { position: absolute; left: -200px; right: -200px; bottom: -160px; height: 1300px; }
.dawn-a { position: absolute; inset: 0; background: radial-gradient(78% 64% at 50% 100%, rgba(240, 164, 98, 0.78) 0%, rgba(244, 188, 136, 0.62) 30%, rgba(248, 214, 178, 0.40) 55%, rgba(251, 236, 218, 0.16) 75%, rgba(253, 251, 247, 0) 92%); }
.dawn-b { position: absolute; left: -10%; right: 35%; bottom: 0; height: 62%; background: radial-gradient(60% 70% at 30% 100%, rgba(228, 128, 100, 0.30) 0%, rgba(228, 128, 100, 0) 72%); }
.dawn-c { position: absolute; left: 35%; right: -10%; bottom: 0; height: 72%; background: radial-gradient(60% 70% at 70% 100%, rgba(244, 184, 96, 0.34) 0%, rgba(244, 184, 96, 0) 72%); }

/* kinetic headline */
.kw { position: absolute; display: block; height: 138.9px; line-height: 138.9px; white-space: nowrap; font-size: 112px; font-weight: 540;
  letter-spacing: -0.02em; color: #26251F; opacity: 0; }
.kw.coral { color: #D97757; }
.ki { position: absolute; display: block; }
.ki-in { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; opacity: 0; }
.ki-in img { width: 100%; height: 100%; object-fit: contain; }

/* app tile */
.tile { position: relative; display: flex; align-items: center; justify-content: center; border-radius: 24%; background: #26251F;
  box-shadow: 0 18px 40px -18px rgba(38, 37, 31, 0.55), inset 0 0 0 1px rgba(255, 255, 255, 0.06); }
.tile-logo { width: 62%; height: 62%; }

/* big centred lines */
.hl { position: absolute; left: 0; width: 1080px; text-align: center; white-space: nowrap; font-size: 112px; font-weight: 540; letter-spacing: -0.02em; line-height: 1.24; color: #26251F; }

/* connector badge */
.bb { display: inline-flex; align-items: center; justify-content: center; border-radius: 22%; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(38, 37, 31, 0.1); }
.bb-g { width: 64%; height: 64%; }
"""

# ---------------------------------------------------------------- JS engine
ENGINE = r"""
  var R = document.getElementById('root');
  var $ = function (s) { return R.querySelector(s); };
  var $$ = function (s) { return Array.prototype.slice.call(R.querySelectorAll(s)); };
  var EZ = {
    lin: function (k) { return k; },
    o2: function (k) { return 1 - (1 - k) * (1 - k); },
    o3: function (k) { return 1 - Math.pow(1 - k, 3); },
    o4: function (k) { return 1 - Math.pow(1 - k, 4); },
    o5: function (k) { return 1 - Math.pow(1 - k, 5); },
    i2: function (k) { return k * k; },
    i3: function (k) { return k * k * k; },
    io2: function (k) { return k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2; },
    io3: function (k) { return k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2; },
    bk: function (k) { var c1 = 2.2, c3 = c1 + 1; return 1 + c3 * Math.pow(k - 1, 3) + c1 * Math.pow(k - 1, 2); },
    bks: function (k) { var c1 = 1.25, c3 = c1 + 1; return 1 + c3 * Math.pow(k - 1, 3) + c1 * Math.pow(k - 1, 2); },
    ex: function (k) { return k >= 1 ? 1 : 1 - Math.pow(2, -10 * k); }
  };
  function c01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  var TR = [], UPS = [];
  function trk(el) { if (!el.__k) { el.__k = { el: el, p: {}, last: {} }; TR.push(el.__k); } return el.__k; }
  function els(sel) { return typeof sel === 'string' ? $$(sel) : (sel.length != null ? sel : [sel]); }
  // A(selector, prop, t0, duration, from, to, ease): one animation segment.
  // props: x y (px) s sx sy (scale) r (deg) o (opacity) dash (stroke-dashoffset) blur (px)
  function A(sel, prop, t0, d, v0, v1, ez) {
    var list = els(sel);
    if (!list.length) { console.warn('A: no match ' + sel); }
    list.forEach(function (el) {
      var k = trk(el);
      (k.p[prop] = k.p[prop] || []).push([t0, Math.max(d, 1e-6), v0, v1, EZ[ez || 'o3']]);
    });
  }
  function val(segs, t) {
    var v = segs[0][2];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i];
      if (t < s[0]) break;
      if (t >= s[0] + s[1]) v = s[3]; else v = s[2] + (s[3] - s[2]) * s[4]((t - s[0]) / s[1]);
    }
    return v;
  }
  function g(k, name, t, dflt) { var s = k.p[name]; return s ? val(s, t) : dflt; }
  function renderTracks(t) {
    for (var i = 0; i < TR.length; i++) {
      var k = TR[i], p = k.p, st = k.el.style;
      if (p.x || p.y || p.s || p.sx || p.sy || p.r) {
        var s = g(k, 's', t, 1);
        var tf = 'translate(' + g(k, 'x', t, 0).toFixed(2) + 'px,' + g(k, 'y', t, 0).toFixed(2) + 'px) rotate(' + g(k, 'r', t, 0).toFixed(2) +
          'deg) scale(' + (s * g(k, 'sx', t, 1)).toFixed(4) + ',' + (s * g(k, 'sy', t, 1)).toFixed(4) + ')';
        if (k.last.tf !== tf) { st.transform = tf; k.last.tf = tf; }
      }
      if (p.o) { var o = c01(g(k, 'o', t, 1)).toFixed(3); if (k.last.o !== o) { st.opacity = o; k.last.o = o; } }
      if (p.dash) { var d = g(k, 'dash', t, 0).toFixed(2); if (k.last.d !== d) { st.strokeDashoffset = d; k.last.d = d; } }
      if (p.blur) { var b = g(k, 'blur', t, 0); var f = b > 0.05 ? 'blur(' + b.toFixed(2) + 'px)' : 'none'; if (k.last.b !== f) { st.filter = f; k.last.b = f; } }
    }
  }
  function U(fn) { UPS.push(fn); }
  function show(sel, t0, t1) {
    els(sel).forEach(function (el) {
      U(function (t) { var on = t >= t0 && t < t1; var d = on ? '' : 'none'; if (el.__d !== d) { el.style.display = d; el.__d = d; } });
    });
  }
  // word-by-word stream: children with class .w fade in at wps words per second
  function stream(sel, t0, wps, fade) {
    els(sel).forEach(function (el) {
      var ws = Array.prototype.slice.call(el.querySelectorAll('.w'));
      fade = fade || 0.12;
      U(function (t) {
        for (var i = 0; i < ws.length; i++) {
          var o = c01((t - t0 - i / wps) / fade);
          if (ws[i].__o !== o) { ws[i].style.opacity = o; ws[i].__o = o; }
        }
      });
    });
  }
  function setText(el, s) { if (el.__v !== s) { el.textContent = s; el.__v = s; } }
  function count(sel, a, b, t0, t1, fmt) {
    var el = $(sel);
    U(function (t) { var k = c01((t - t0) / (t1 - t0)); k = 1 - Math.pow(1 - k, 3); setText(el, fmt(a + (b - a) * k)); });
  }
  function eur(v) { var s = v.toFixed(2); var p = s.split('.'); return '€' + p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',') + '.' + p[1]; }
  // typing dots: three dots bounce while visible
  function dots(sel) {
    els(sel).forEach(function (el) {
      var ds = Array.prototype.slice.call(el.querySelectorAll('i'));
      U(function (t) {
        for (var i = 0; i < ds.length; i++) {
          var ph = Math.sin((t * 2.2 - i * 0.18) * Math.PI * 2);
          var y = ph > 0 ? -ph * 9 : 0;
          var o = 0.35 + 0.65 * Math.max(0, ph);
          ds[i].style.transform = 'translateY(' + y.toFixed(2) + 'px)';
          ds[i].style.opacity = o.toFixed(3);
        }
      });
    });
  }
  function spin(sel) {
    els(sel).forEach(function (el) { U(function (t) { el.style.transform = 'rotate(' + ((t * 420) % 360).toFixed(1) + 'deg)'; }); });
  }
"""

FINISH = r"""
  TR.forEach(function (k) { for (var p in k.p) k.p[p].sort(function (a, b) { return a[0] - b[0]; }); });
  function renderAll(t) { renderTracks(t); for (var i = 0; i < UPS.length; i++) UPS[i](t); }
  var tl = gsap.timeline({ paused: true });
  var drv = { t: 0 };
  tl.to(drv, { t: DUR, duration: DUR, ease: 'none', onUpdate: function () { renderAll(drv.t); } }, 0);
  renderAll(0);
  window.__timelines["main"] = tl;
"""


def words_html(text, cls="w"):
    """Wrap each word (with its trailing space) in a span for streaming."""
    return "".join(f'<span class="{cls}">{esc(p)}</span>' for p in re.findall(r"\S+\s*", text))
