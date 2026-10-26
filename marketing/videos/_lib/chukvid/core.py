"""Canvas, tokens, fonts, icons, cursor, motion helpers and the project writer.

Everything here is extracted from chuk-08-what-we-see/_work/build.py, the look the
owner approved. Change a value here and every episode changes with it.
"""
import html
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent          # marketing/videos/_lib
VIDEOS = LIB.parent                                   # marketing/videos
REPO = VIDEOS.parent.parent                           # chuk_chat
HF_VERSION = "0.8.202"                                # pinned CLI, same as 08

# ------------------------------------------------------------------ formats
@dataclass(frozen=True)
class Format:
    name: str
    W: int
    H: int
    vertical: bool
    safe_top: int      # no text above this line
    safe_bottom: int   # no text below H - safe_bottom

    @property
    def cx(self):
        return self.W / 2

    @property
    def cy(self):
        """Centre of the safe band (the frame centre in 16:9)."""
        return self.safe_top + (self.H - self.safe_top - self.safe_bottom) / 2

    def pick(self, landscape, vertical):
        return vertical if self.vertical else landscape


LANDSCAPE = Format("16x9", 1920, 1080, False, 0, 0)
# Shorts / Reels / TikTok draw their own UI: keep text out of the top 220 px
# and the bottom 380 px (caption, handle, buttons).
VERTICAL = Format("9x16", 1080, 1920, True, 220, 380)
FORMATS = {"16x9": LANDSCAPE, "9x16": VERTICAL}

# ------------------------------------------------------------------ tokens
TOK = {
    # canvas around the UI (Anthropic no-people grammar, 08)
    "CANVAS": "#F4EEE4", "GRID": "#E6DCCD", "TAN": "#DCCBB4", "BROWN": "#5C4033",
    "INK": "#2A1F17", "SOFT": "#6E5D4E",
    # the app, "Clawed" dark preset (lib/theme/theme_presets.dart), measured on
    # assets/screenshots/*.webp
    "BG": "#262624", "FG": "#E8E4D8", "ACC": "#D97757", "BUBBLE": "#B6674D", "LINE": "#615F5A",
}
GRID_STEP = 48


def T(s):
    """Replace @NAME@ tokens with colours."""
    for k, v in TOK.items():
        s = s.replace("@" + k + "@", v)
    return s


esc = html.escape

# ------------------------------------------------------------------ app icons (HugeIcons)
_ICONS = {}
for _m in re.finditer(r'<symbol id="(h-[^"]+)" viewBox="([^"]+)"[^>]*>(.*?)</symbol>',
                      (LIB / "assets/ref/app-icons.html").read_text(), re.S):
    _ICONS[_m.group(1)] = (_m.group(2), _m.group(3))


def hi(name, box, cls="", style=""):
    """App icon (HugeIcons stroke set) drawn at 0.86 of its box, like the app does."""
    vb, inner = _ICONS[name]
    px = round(box * 0.86, 2)
    return (f'<svg class="hi {cls}" viewBox="{vb}" fill="none" style="width:{px}px;height:{px}px;{style}">'
            f'{inner}</svg>')


def icon_names():
    return sorted(_ICONS)


# ------------------------------------------------------------------ brand (never re-typed)
def _logo_paths():
    return "".join(re.findall(r"<path[^>]*/>", (REPO / "assets/logo.svg").read_text(), re.S))


def logo(cls="mark", id_=""):
    """The CC mark from repo assets/logo.svg, filled with currentColor."""
    idattr = f' id="{id_}"' if id_ else ""
    return (f'<svg{idattr} class="{cls}" viewBox="0 0 500 500"><g transform="translate(0,500) '
            f'scale(0.1,-0.1)" fill="currentColor">{_logo_paths()}</g></svg>')


def wordmark(id_, colour, width):
    """Repo assets/wordmark.svg inlined as-is, only the black fills recoloured.
    Returns (svg_html, height_px)."""
    wm = (REPO / "assets/wordmark.svg").read_text()
    vb = re.search(r'viewBox="([^"]+)"', wm).group(1)
    inner = re.search(r"<svg[^>]*>(.*)</svg>", wm, re.S).group(1).replace('fill="#000000"', f'fill="{colour}"')
    v = [float(x) for x in vb.split()]
    h = round(width * v[3] / v[2], 1)
    return (f'<svg id="{id_}" viewBox="{vb}" xmlns="http://www.w3.org/2000/svg">{inner}</svg>', h)


# ------------------------------------------------------------------ cursor (arrow, hand, I-beam)
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


def cursor(id_, scale=1.0):
    """Cursor actor. Move it with x/y tweens on #id; the tip is at (0,0)."""
    st = f' style="--cs:{scale}"' if scale != 1.0 else ""
    return f'<div class="cur" id="{id_}"{st}><div class="cur-s">{ARROW}{HAND}{IBEAM}</div></div>'


# ------------------------------------------------------------------ CSS shared by every scene
COMMON_CSS = T("""
@font-face { font-family: 'Newsreader'; src: url('assets/fonts/Newsreader-Disp600.ttf') format('truetype'); font-weight: 600; font-style: normal; }
@font-face { font-family: 'ChukMono'; src: url('assets/fonts/jetbrains-mono-latin-wght.woff2') format('woff2'); font-weight: 100 800; font-style: normal; }
@font-face { font-family: 'Ubuntu'; src: url('assets/fonts/Ubuntu-wght.ttf') format('truetype'); font-weight: 100 800; font-style: normal; }
@font-face { font-family: 'LiberationMono'; src: url('assets/fonts/LiberationMono-Regular.ttf') format('truetype'); font-weight: 400; font-style: normal; }
#root { position: absolute; inset: 0; overflow: hidden; font-family: 'Ubuntu', sans-serif; color: @INK@; }
#root * { box-sizing: border-box; }
.serif { font-family: 'Newsreader', serif; font-weight: 600; letter-spacing: -0.01em; color: @INK@; }
.mono { font-family: 'ChukMono', monospace; }
.word { display: inline-block; }
.hi { display: block; flex: none; }
.mark { display: block; }
.cur { position: absolute; left: 0; top: 0; width: 0; height: 0; z-index: 60; }
.cur-s { position: absolute; left: 0; top: 0; width: 0; height: 0; transform: scale(var(--cs, 1)); transform-origin: 0 0; }
.cur svg { position: absolute; overflow: visible; }
.cur-arrow { left: -5px; top: -4px; width: 48px; height: 68px; transform-origin: 5px 4px; }
.cur-hand { left: -21px; top: -5px; width: 56px; height: 62px; opacity: 0; transform-origin: 21px 5px; }
.cur-ibeam { left: -10px; top: -20px; width: 20px; height: 40px; opacity: 0; transform-origin: 10px 20px; }
.card-line { position: absolute; left: 0; right: 0; text-align: center; }
.fill { position: absolute; inset: 0; }
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
function hfStream(tl, sel, t, stagger) {
  hfWords(sel);
  tl.fromTo(sel + ' .word', { opacity: 0 }, { opacity: 1, duration: 0.05, stagger: stagger || 0.085, ease: 'none' }, t);
}
"""

# GSAP 3.14.2, vendored (no network request at render time). The page loads the
# project copy that Episode.write() puts in assets/js/.
GSAP_FILE = LIB / "assets/js/gsap.min.js"
GSAP = "assets/js/gsap.min.js"

MUSIC_DIR = VIDEOS.parent / "_shared/music"


def require_file(path, what, hint):
    """Stop with a clear message when a local-only input (gitignored media) is missing."""
    path = Path(path)
    if not path.is_file():
        raise SystemExit(f"missing {what}: {path}\n{hint}")
    return path


def require_music(path):
    return require_file(path, "music", "Music WAVs are gitignored. See marketing/videos/_lib/README.md "
                        "(section Music) for the Epidemic Sound track and edit id, then put the "
                        f"file in {MUSIC_DIR}.")


def find_chrome():
    """A headless Chrome for Playwright scripts (asset shots, fidelity harness).

    Order: $CHROME_PATH, the HyperFrames CLI cache (any platform folder), else None,
    which lets Playwright use its own Chromium. Never a machine-specific path."""
    import glob
    import os
    env = os.environ.get("CHROME_PATH")
    if env:
        return require_file(env, "Chrome ($CHROME_PATH)", "Point CHROME_PATH at a Chrome binary.")
    hits = sorted(glob.glob(str(Path.home() / ".cache/hyperframes/chrome/chrome-headless-shell/*/*/chrome-headless-shell*")))
    hits = [h for h in hits if os.access(h, os.X_OK)]
    return hits[-1] if hits else None


def launch_chrome(playwright):
    """playwright.chromium.launch() with find_chrome(); a clear error if no browser exists."""
    exe = find_chrome()
    try:
        return playwright.chromium.launch(**({"executable_path": exe} if exe else {}))
    except Exception as e:  # noqa: BLE001
        raise SystemExit("no headless Chrome found. Run `npx hyperframes browser ensure` "
                         "or `python3 -m playwright install chromium`, or set CHROME_PATH.\n" + str(e))


# ------------------------------------------------------------------ the episode / project writer
class Episode:
    """One HyperFrames project for one format.

    ep = Episode("chuk-09-your-files", LANDSCAPE, duration=45, music=...)
    ep.add("s01", 0, 3.4, css, body, js)     # a sub-composition
    ep.write()                               # index.html + scaffolding + assets
    """

    def __init__(self, folder, fmt, duration, music, extra_css=""):
        self.dir = Path(folder)
        self.fmt = fmt
        self.duration = duration
        self.music = require_music(music)
        self.extra_css = extra_css   # CSS added to every scene (ui.APP_CSS etc.)
        self.scenes = []             # (id, start, dur)
        self.assets = {}             # dest (relative to assets/) -> source path
        (self.dir / "compositions").mkdir(parents=True, exist_ok=True)

    @property
    def W(self):
        return self.fmt.W

    @property
    def H(self):
        return self.fmt.H

    def asset(self, src, dest):
        """Copy a file into the project's assets/ at write(). Returns the root-relative path."""
        self.assets[dest] = Path(src)
        return "assets/" + dest

    def _scene(self, cid, css, body, js, dur):
        return f"""<template>
  <style>
{COMMON_CSS}
{T(self.extra_css)}
{T(css)}
  </style>
  <div id="root" data-composition-id="{cid}" data-width="{self.W}" data-height="{self.H}" data-duration="{dur}">
{T(body)}
  </div>
  <script>
{COMMON_JS}
(function () {{
  var tl = gsap.timeline({{ paused: true }});
{T(js)}
  window.__timelines = window.__timelines || {{}};
  window.__timelines["{cid}"] = tl;
}})();
  </script>
</template>
"""

    def add(self, cid, start, end, css, body, js):
        dur = round(end - start, 3)
        self.scenes.append((cid, round(start, 3), dur))
        (self.dir / "compositions" / f"{cid}.html").write_text(self._scene(cid, css, body, js, dur))

    # ---------------------------------------------------------------- scaffolding
    def write(self):
        d = self.dir
        name = d.name
        # assets: fonts, brand, music, episode files
        fonts = d / "assets/fonts"
        fonts.mkdir(parents=True, exist_ok=True)
        for f in (LIB / "assets/fonts").iterdir():
            shutil.copy2(f, fonts / f.name)
        img = d / "assets/img"
        img.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / "assets/logo.svg", img / "logo.svg")
        shutil.copy2(REPO / "assets/wordmark.svg", img / "wordmark.svg")
        (d / "assets/audio").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.music, d / "assets/audio/music.wav")
        (d / "assets/js").mkdir(parents=True, exist_ok=True)
        shutil.copy2(GSAP_FILE, d / "assets/js/gsap.min.js")
        for dest, src in self.assets.items():
            p = d / "assets" / dest
            p.parent.mkdir(parents=True, exist_ok=True)
            if not (p.exists() and p.resolve() == Path(src).resolve()):   # source may be this project's own tracked copy
                shutil.copy2(src, p)
        # project files (same shape as `hyperframes init` writes)
        (d / "hyperframes.json").write_text(json.dumps({
            "$schema": "https://hyperframes.heygen.com/schema/hyperframes.json",
            "registry": "https://raw.githubusercontent.com/heygen-com/hyperframes/main/registry",
            "paths": {"blocks": "compositions", "components": "compositions/components", "assets": "assets"},
            "media": {"autoProxy": True},
            "authoringSkill": "hyperframes",
        }, indent=2) + "\n")
        (d / "package.json").write_text(json.dumps({
            "name": name, "private": True, "type": "module",
            "scripts": {k: f"npx --yes hyperframes@{HF_VERSION} {v}" for k, v in
                        (("dev", "preview"), ("check", "check"), ("render", "render"), ("publish", "publish"))},
        }, indent=2) + "\n")
        meta = d / "meta.json"
        if not meta.exists():
            meta.write_text(json.dumps({"id": name, "name": name}, indent=2) + "\n")
        (d / ".gitignore").write_text(".hyperframes/*\n!.hyperframes/caption-skin.html\n.waveform-cache/\n"
                                      ".thumbnails/\nnode_modules/\n_work/final/\n_work/snap*/\n__pycache__/\n")
        (d / "index.html").write_text(self.index_html())
        return d

    def index_html(self):
        W, H, D = self.W, self.H, self.duration
        hosts = "\n".join(
            f'      <div id="{cid}" class="clip" data-composition-id="{cid}" data-composition-src="compositions/{cid}.html" '
            f'data-start="{s}" data-duration="{dur}" data-track-index="1" data-track-kind="graphics" '
            f'data-width="{W}" data-height="{H}" style="z-index:{i + 2}"></div>'
            for i, (cid, s, dur) in enumerate(self.scenes))
        return T(f"""<!doctype html>
<html lang="en" data-composition-variables='[{{"id":"color-ground","type":"color","label":"Background","default":"@CANVAS@"}},{{"id":"color-ink","type":"color","label":"Text","default":"@INK@"}}]'>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={W}, height={H}" />
    <script src="{GSAP}"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; background: @CANVAS@; }}
      #root {{ width: 100%; height: 100%; position: relative; background: @CANVAS@; }}
      #ground {{ position: absolute; inset: 0; z-index: 1; background-color: @CANVAS@;
        background-image: linear-gradient(@GRID@ 1px, transparent 1px), linear-gradient(90deg, @GRID@ 1px, transparent 1px);
        background-size: {GRID_STEP}px {GRID_STEP}px; background-position: -1px 11px; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{D}" data-width="{W}" data-height="{H}">
      <div id="ground" class="clip" data-start="0" data-duration="{D}" data-track-index="0" data-track-kind="graphics"></div>
{hosts}
      <audio id="music" data-timeline-role="music" src="assets/audio/music.wav" data-start="0" data-duration="{D}" data-track-index="2" data-volume="1"></audio>
    </div>
    <script>
      const tl = gsap.timeline({{ paused: true }});
      window.__timelines = window.__timelines || {{}};
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
""")

    def report(self):
        print(f"wrote {self.dir.name}: {len(self.scenes)} scenes, {self.fmt.W}x{self.fmt.H}, {self.duration}s")
        for cid, s, d in self.scenes:
            print(f"  {cid:6s} {s:6.2f} - {s + d:6.2f}")
