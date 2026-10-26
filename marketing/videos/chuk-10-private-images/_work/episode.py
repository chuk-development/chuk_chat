#!/usr/bin/env python3
"""Episode 10 "private-images": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 10): "a watercolour of our dog Bruno on the beach" goes into
the real composer, the real image block generates (activity row, loader tile, the image
with its model pill). Cut: the request the server sends, with "zdr": true,
"data_collection": "deny", "allow_fallbacks": false; the result waits in server RAM
(15 min at most) and is deleted on the first download; Storage holds it as .enc; the
media manager decrypts it on the device. "Zero retention. / Then encrypted." (retention +
storage only: the server and the image provider get the prompt and the image to make it)
Claim (PRIVACY_CLAIMS.md, Generated images, may say): made with zero data retention
(zdr, data_collection: deny), kept in server RAM at most 15 min, then stored encrypted.

Builds both formats from one spec:
  ../chuk-10-private-images/            16:9 1920x1080
  ../chuk-10-private-images-vertical/   9:16 1080x1920 (re-laid out, not cropped)
Run (once): python3 _work/make_assets.py   then: python3 _work/episode.py
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent
VIDEOS = PROJ.parent
sys.path.insert(0, str(VIDEOS / "_lib"))

from chukvid import LANDSCAPE, VERTICAL, Episode, beats, scenes, ui  # noqa: E402
from chukvid.cipher import human_bytes, mask_uuid_short  # noqa: E402
from chukvid.core import cursor, esc, hi  # noqa: E402

MUSIC = VIDEOS.parent / "_shared/music/s2-sky-falling-45s.wav"
DUR = 45.0
C = json.loads((HERE / "cipher.json").read_text())
PROMPT = C["prompt"]
REQ = C["request"]
IMG = "assets/img/bruno.jpg"
OTHERS = [f"assets/img/other{i}.jpg" for i in range(1, 5)]
OBJ_SIZE = human_bytes(C["object_bytes"])                 # Storage list (formatBytes look)
MM_SIZE = f"{C['object_bytes'] / 1024:.1f} KB"             # media_manager_page _formatFileSize
MM_DATE = "26/10/2026"                                     # media_manager_page _formatDate
MODEL = "Krea 2 Large"                                     # IMAGE_MODELS["krea"].label
ANSWER = ["Here's Bruno on the beach, in watercolour."]

# ------------------------------------------------------------------ cuts on the beat grid
# 122.6 BPM, beat 0.49 s. Quiet dip 18-19.8 (bridge card), lift at 19.86, the drop at
# 27.48 (strongest hit: the image is deleted from server RAM on it), full energy to 42,
# fade 42-45 under the end card. Rough targets, snapped to the beat grid.
TARGETS = [3.19, 9.55, 17.41, 19.86, 24.75, 29.95, 33.84, 38.24, 40.7]


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + EP_CSS)
    ep.asset(HERE / "gen/bruno.jpg", "img/bruno.jpg")
    for i in range(1, 5):
        ep.asset(HERE / f"gen/other{i}.jpg", f"img/other{i}.jpg")
    ep.write()                                   # scaffold first: `beats` needs the music in place
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.4)
    v = fmt.vertical
    cs = 1.3 if v else 1.0                       # cursor scale

    s01_hook(ep, cut[0], cut[1], v)
    s02_prompt(ep, cut[1], cut[2], v, cs)
    s03_generate(ep, cut[2], cut[3], v)
    scenes.card(ep, "s04", cut[3], cut[4], ["Here's how", "it was made."] if v else ["Here's how it was made."])
    s05_request(ep, cut[4], cut[5], v)
    s06_memory(ep, cut[5], cut[6], v)
    s07_storage(ep, cut[6], cut[7], v)
    s08_media(ep, cut[7], cut[8], v, cs)
    scenes.card(ep, "s09", cut[8], cut[9], ["Zero retention.", "Then encrypted."], bg="@TAN@")
    scenes.end_card(ep, "s10", cut[9], DUR)
    ep.write()
    ep.report()
    return ep


# ------------------------------------------------------------------ episode-only app pieces
# Values from the real widgets (fidelity_test renders them; sheets in _work/fidelity/):
# * image block: message_bubble/images.dart _loaderTile (grey 30 % over the surface =
#   #4A4A49, radius 12, auto_awesome 18 at onSurface 60 %, spinner 26 stroke 2.5 accent,
#   "Generating…" 12/600, size label 11 at 45 %) and _captionedTile (image at its own
#   ratio, full width, radius 12, model pill: black 55 %, radius 6, padding 3/6, sparkle 10,
#   9 px w600 white). Activity row: agent_activity_timeline.dart (bolt_outlined -> flash,
#   "Ran generate image" + the prompt at onSurface 85 % w500).
# * media manager: desktop_media_modal.dart (panel bg, radius 28, outlineVariant #595853,
#   title titleLarge w700, close chip 40 on surfaceContainerHigh #41413E) and
#   media_manager_page.dart (_buildToolbar, _MediaFilterBar on FloatingChromeSurface
#   #31312F, _buildDesktopGrid maxExtent 220 / spacing 14, _ImageTile radius 18 on #41413E,
#   hover: black 12 %, two 30 px actions, gradient + "date · size" 11/600 white).
DELETE02 = ('<svg class="hi" viewBox="0 0 24 24" fill="none" style="width:{s}px;height:{s}px"><g stroke="currentColor" '
            'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19.5 5.5L18.88 15.53C18.72 18.09 '
            '18.64 19.37 18 20.29C17.68 20.74 17.27 21.13 16.8 21.42C15.84 22 14.56 22 11.99 22C9.42 22 8.14 22 7.18 21.41'
            'C6.7 21.13 6.3 20.74 5.98 20.28C5.34 19.36 5.26 18.08 5.1 15.52L4.5 5.5"/><path d="M3 5.5H21M16.06 5.5L15.37 '
            '4.09C14.92 3.16 14.69 2.69 14.3 2.4C14.21 2.33 14.12 2.27 14.03 2.22C13.59 2 13.07 2 12.03 2C10.97 2 10.44 2 '
            '10 2.23C9.9 2.29 9.8 2.35 9.72 2.41C9.32 2.72 9.1 3.2 8.66 4.17L8.05 5.5"/><path d="M9.5 16.5V10.5M14.5 '
            '16.5V10.5"/></g></svg>')

EP_CSS = """
.print { position: absolute; background: #FBF7EF; padding: 22px 22px 22px; border-radius: 6px; box-shadow: 0 30px 60px -28px rgba(0,0,0,0.45); }
.print img { display: block; width: 100%; height: 100%; object-fit: cover; }
.pcap { position: absolute; text-align: center; font-family: 'Ubuntu', sans-serif; font-weight: 500; color: @SOFT@; white-space: nowrap; }
/* image block */
.g-step { display: flex; align-items: center; gap: 10px; height: 26px; font-size: 12.7px; color: var(--fg55); white-space: nowrap; }
.g-step b { margin-left: 0.5em; font-weight: 500; color: var(--fg85); }
.g-tile { position: relative; border-radius: 12px; overflow: hidden; background: #4A4A49; }
.g-load { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; color: rgba(232,228,216,0.6); }
.g-load .lbl { margin-top: 10px; font-size: 12px; font-weight: 600; }
.g-load .dim { margin-top: 2px; font-size: 11px; color: rgba(232,228,216,0.45); }
.g-spin { width: 26px; height: 26px; margin-top: 8px; display: block; }
.g-img { position: absolute; inset: 0; opacity: 0; }
.g-img img { display: block; width: 100%; height: 100%; object-fit: cover; }
.g-pill { position: absolute; right: 6px; bottom: 6px; display: flex; align-items: center; gap: 3px; padding: 3px 6px; border-radius: 6px;
  background: rgba(0,0,0,0.55); color: #fff; font-size: 9px; font-weight: 600; line-height: 1; white-space: nowrap; }
.g-pill .hi { color: rgba(255,255,255,0.9); }
.g-head { display: inline-flex; align-items: center; gap: 4px; padding: 4px 2px; font-size: 12.7px; font-weight: 500; color: var(--fg55); white-space: nowrap; }
.g-n { display: none; }
/* media manager */
.mm-panel { position: absolute; background: @BG@; border: 1px solid #595853; border-radius: 28px; overflow: hidden;
  box-shadow: 0 30px 70px -30px rgba(0,0,0,0.55); }
.mm-head { display: flex; align-items: center; padding: 16px 12px 4px 20px; height: 64px; }
.mm-title { font-size: 22px; font-weight: 700; color: var(--fg); letter-spacing: 0; }
.mm-close { width: 40px; height: 40px; border-radius: 50%; background: #41413E; display: flex; align-items: center; justify-content: center; color: var(--fg); }
.mm-tool { display: flex; align-items: center; height: 48px; margin: 8px 12px 4px 20px; }
.mm-count { font-size: 14px; color: #CDCABF; letter-spacing: 0.25px; }
.mm-chip { width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; }
.mm-chip i { width: 42px; height: 42px; border-radius: 50%; background: #31312F; display: flex; align-items: center; justify-content: center; color: var(--fg); }
.mm-filter { position: absolute; left: 12px; right: 12px; height: 52px; padding: 4px; border-radius: 999px; background: #31312F; display: flex; }
.mm-seg { flex: 1; display: flex; align-items: center; justify-content: center; border-radius: 999px; font-size: 14px; font-weight: 600; letter-spacing: 0.1px; color: #CFCBC1; white-space: pre; }
.mm-seg.on { background: @ACC@; color: var(--fg); }
.mm-grid { position: absolute; left: 20px; right: 20px; display: grid; gap: 14px; }
.mm-tile { position: relative; aspect-ratio: 1; border-radius: 18px; overflow: hidden; background: #41413E; border: 2px solid transparent; }
.mm-tile img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; }
.mm-tile .mm-sp { position: absolute; left: 50%; top: 50%; width: 22px; height: 22px; margin: -11px 0 0 -11px; }
.mm-hov { position: absolute; inset: 0; background: rgba(0,0,0,0.12); opacity: 0; }
.mm-acts { position: absolute; top: 6px; right: 6px; display: flex; gap: 6px; opacity: 0; }
.mm-act { width: 30px; height: 30px; border-radius: 50%; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; color: #fff; }
.mm-act.del { color: #F2B8B5; }
.mm-meta { position: absolute; left: 0; right: 0; bottom: 0; padding: 14px 10px 8px; background: linear-gradient(to top, rgba(0,0,0,0.66), rgba(0,0,0,0));
  color: #fff; font-size: 11px; font-weight: 600; white-space: nowrap; opacity: 0; }
/* server views: bigger type for this episode (>= 30 px in 16:9, >= 34 px in 9:16) */
.rq-hl { position: absolute; left: 0; right: 0; background: rgba(220,203,180,0.7); border-left: 6px solid @BROWN@; transform-origin: 0 50%; }
.rq-true { color: #11181C; font-weight: 700; }
"""


def spinner(id_, size, stroke, colour="@ACC@"):
    """CircularProgressIndicator (indeterminate): an accent arc, turned by the timeline."""
    r = (size - stroke) / 2
    c = 2 * 3.14159 * r
    return (f'<svg id="{id_}" class="g-spin" viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px">'
            f'<circle cx="{size / 2}" cy="{size / 2}" r="{r:.2f}" fill="none" stroke="{colour}" stroke-width="{stroke}" '
            f'stroke-linecap="round" stroke-dasharray="{c * 0.28:.2f} {c:.2f}"/></svg>')


def spin_js(sel, t0, t1):
    return f"tl.fromTo('{sel}', {{ rotation: 0 }}, {{ rotation: {round((t1 - t0) * 400)}, duration: {t1 - t0:.2f}, ease: 'none', transformOrigin: '50% 50%' }}, {t0:.2f});"


# =================================================================== s01 the picture paints itself in (hook)
def s01_hook(ep, a, b, v):
    if v:
        pw, ph, px, py = 900, 675, 90, 300
        lines, size, ly, lx, align = ["One picture", "of Bruno.", "Where does it go?"], 104, 1105, 0, "center"
    else:
        pw, ph, px, py = 880, 660, 140, 200
        lines, size, ly, lx, align = ["One picture", "of Bruno.", "Where does it go?"], 84, 340, 1110, "left"
    lh = round(size * 1.14)
    ldivs = "".join(
        f'<div class="serif" id="s01-l{i}" style="position:absolute;left:{lx}px;right:{0 if v else 60}px;top:{ly + i * lh + (24 if i == 2 else 0)}px;'
        f'font-size:{size}px;line-height:{lh}px;text-align:{align}{";color:@SOFT@" if i == 2 else ""}">{esc(t)}</div>'
        for i, t in enumerate(lines))
    css = f"""
#s01-all {{ transform-origin: {px + pw / 2}px {py + ph / 2}px; }}
#s01-pr {{ left: {px - 22}px; top: {py - 22}px; width: {pw + 44}px; height: {ph + 44}px; }}
#s01-paint {{ width: 100%; height: 100%; -webkit-mask-image: radial-gradient(circle at 58% 62%, #000 0%, #000 var(--r), transparent calc(var(--r) + 18%)); mask-image: radial-gradient(circle at 58% 62%, #000 0%, #000 var(--r), transparent calc(var(--r) + 18%)); --r: 28%; }}
"""
    body = f"""
    <div id="s01-all" class="fill">
      <div class="print" id="s01-pr"><div id="s01-paint"><img src="{IMG}" alt=""></div></div>
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s01-pr', {{ y: 16, rotation: -2.2 }}, {{ y: 0, rotation: -1.5, duration: 0.7, ease: 'expo.out' }}, 0);
  tl.fromTo('#s01-paint', {{ '--r': '28%' }}, {{ '--r': '95%', duration: 1.4, ease: 'power2.out' }}, 0.15);
  hfReveal(tl, '#s01-l0', 0.55);
  hfReveal(tl, '#s01-l1', 0.85);
  hfReveal(tl, '#s01-l2', 1.6);
  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s01", a, b, css, body, js)


# =================================================================== s02 type the request, send
def s02_prompt(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        Z, win, cw = 1.9, dict(left=24, top=300, w=520, h=420), 460
    else:
        Z, win, cw = 2.2, dict(left=60, top=40, w=753, h=410), 660
    H = fmt.H / Z
    cl = win["left"] + (win["w"] - cw) / 2
    comp_bottom_y = win["top"] + win["h"] - 44
    bottom = H - comp_bottom_y
    comp_top = comp_bottom_y - 135
    field = ((cl + 2 + 14 + 6) * Z, (comp_top + 14 + 14) * Z)
    send = ((cl + cw - 2 - 14 - 22) * Z, (comp_top + 2 + 14 + 18) * Z)
    inner = f"""
        <div id="s02-win" class="a-win" style="left:{win['left']}px;top:{win['top']}px;width:{win['w']}px;height:{win['h']}px"></div>
        {ui.composer('s02', cw, cl, bottom=bottom)}
        {ui.disclaimer('s02-disc', comp_bottom_y + 8)}
"""
    cam_o = ((win["left"] + win["w"] / 2) * Z, (comp_top + 60) * Z)
    css = f"""
#s02-cam {{ transform-origin: {cam_o[0]:.0f}px {cam_o[1]:.0f}px; }}
#s02-disc {{ left: {win['left']}px; width: {win['w']}px; right: auto; }}
"""
    body = f"""
    <div id="s02-cam" class="fill">
      {ui.appz('s02-z', fmt, Z, inner)}
      {cursor('s02-cur', cs)}
    </div>
"""
    type_start = 1.45
    type_end = type_start + len(PROMPT) / 18
    js = f"""
  tl.fromTo('#s02-z', {{ opacity: 0, y: 24 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.set('#s02-caret', {{ opacity: 0 }}, 0);
  tl.fromTo('#s02-cur', {{ x: {field[0] + 300:.0f}, y: {fmt.H + 60} }}, {{ x: {field[0]:.0f}, y: {field[1]:.0f}, duration: 0.8, ease: 'power2.inOut' }}, 0.2);
  hfShape(tl, '#s02-cur', 0.75, 'ibeam');
  hfClick(tl, '#s02-cur', 1.05, 'ibeam');
  tl.set('#s02-caret', {{ opacity: 1 }}, 1.1);
  tl.set('#s02-ph', {{ display: 'none' }}, {type_start});
  tl.set('#s02-caret', {{ display: 'none' }}, {type_start});
  tl.set('#s02-typed', {{ display: 'inline' }}, {type_start});
  tl.set('#s02-caret2', {{ opacity: 1 }}, {type_start});
  hfShape(tl, '#s02-cur', {type_start + 0.05}, 'arrow');
  tl.to('#s02-cur', {{ x: {field[0] + (60 if v else 120):.0f}, y: {field[1] - (380 if v else 160):.0f}, duration: 0.6, ease: 'power2.out' }}, {type_start + 0.05});
  var end = hfType(tl, document.getElementById('s02-typed'), {PROMPT!r}, {type_start}, 18);
  tl.to('#s02-cur', {{ x: {send[0]:.0f}, y: {send[1]:.0f}, duration: 0.7, ease: 'power2.inOut' }}, end + 0.12);
  hfShape(tl, '#s02-cur', end + 0.75, 'hand');
  tl.to('#s02-send', {{ backgroundColor: '#C9684A', duration: 0.1 }}, end + 0.75);
  hfClick(tl, '#s02-cur', end + 0.95, 'hand');
  tl.to('#s02-send', {{ scale: 0.9, duration: 0.08 }}, end + 0.95);
  tl.to('#s02-send', {{ scale: 1, backgroundColor: '@ACC@', duration: 0.14 }}, end + 1.03);
  tl.set('#s02-typed', {{ display: 'none' }}, end + 1.1);
  tl.set('#s02-ph', {{ display: 'inline' }}, end + 1.1);
  tl.set('#s02-caret2', {{ opacity: 0 }}, end + 1.1);
  tl.set('#s02-caret', {{ display: 'block', opacity: 1 }}, end + 1.1);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: 1.05, duration: {b - a - 0.6:.2f}, ease: 'power1.inOut' }}, 0.6);
"""
    assert type_end + 1.2 < b - a, (type_end, b - a)
    ep.add("s02", a, b, css, body, js)


# =================================================================== s03 the real image block generates
def s03_generate(ep, a, b, v):
    fmt = ep.fmt
    if v:
        Z, colw, col_top, pan = 2.2, 440, 150, 0
    else:
        Z, colw, col_top, pan = 2.2, 570, 18, -204
    W = fmt.W / Z
    cx = (W - colw) / 2
    tile_h = round(colw * 768 / 1024, 1)                  # landscape_4_3 loader, then the 4:3 image
    side = 16 if v else 40
    win_h = 590 if v else fmt.H / Z + 400              # 9:16: the window ends under the answer
    t_load, t_done = 0.95, 4.35
    secs = [(2, 0.6), (3, 1.35), (4, 2.35), (5, 3.35)]    # "Generating image for Ns", counted on the turn clock
    nspans = "".join(f'<span class="g-n" id="s03-n{n}">{n}</span>' for n, _ in secs)
    inner = f"""
        <div id="s03-win" class="a-win" style="left:{cx - side:.2f}px;top:{col_top - 30}px;width:{colw + 2 * side}px;height:{win_h:.0f}px"></div>
        <div id="s03-col" class="a-col" style="left:{cx:.2f}px;top:{col_top}px;width:{colw}px">
          {ui.user_message('s03-u', PROMPT, wrap=v)}
          <div id="s03-ai" style="margin-top:14px">
            <div style="position:relative;height:30px">
              <p class="g-head" id="s03-h1" style="position:absolute;left:0;top:0;margin:0"><span>Generating image for {nspans}s</span>{hi('h-arrow-down01', 16)}</p>
              <p class="g-head" id="s03-h2" style="position:absolute;left:0;top:0;margin:0;opacity:0"><span>Worked for 9s</span>{hi('h-arrow-right01', 16)}</p>
            </div>
            <div id="s03-step" class="g-step"><span class="a-badge" style="border-color:#43423F">{hi('h-flash', 14)}</span><span>Ran generate image<b>{esc(PROMPT)}</b></span></div>
            <div id="s03-low" style="margin-top:8px">
              <div class="g-tile" id="s03-tile" style="width:{colw}px;height:{tile_h}px">
                <div class="g-load" id="s03-load">{hi('h-sparkles', 18 / 0.86)}{spinner('s03-spin', 26, 2.5)}<span class="lbl">Generating…</span><span class="dim">1024 × 768</span></div>
                <div class="g-img" id="s03-img"><img src="{IMG}" alt=""><span class="g-pill">{hi('h-sparkles', 10 / 0.86)}<span>{MODEL}</span></span></div>
              </div>
              {ui.answer('s03-ai-t', ANSWER)}
            </div>
          </div>
        </div>
"""
    oy = (col_top + 120 + tile_h / 2) * Z + pan if v else 1050   # 16:9: keep the answer line in frame
    css = f"""
#s03-cam {{ transform-origin: {fmt.cx:.0f}px {oy:.0f}px; }}
#s03-ai-t {{ margin-top: 16px; }}
"""
    body = f"""
    <div id="s03-cam" class="fill" data-layout-allow-overflow>
      <div id="s03-pan" class="fill">{ui.appz('s03-z', fmt, Z, inner)}</div>
    </div>
"""
    sjs = "".join(
        (f"tl.set('#s03-n{secs[i - 1][0]}', {{ display: 'none' }}, {t:.2f});" if i else "") +
        f"tl.set('#s03-n{n}', {{ display: 'inline' }}, {t:.2f});" for i, (n, t) in enumerate(secs))
    js = f"""
  tl.fromTo('#s03-z', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 0);
  tl.fromTo('#s03-u-bub', {{ opacity: 0, y: 50 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s03-h1', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25 }}, 0.55);
  {sjs}
  tl.fromTo('#s03-step', {{ opacity: 0, x: -10 }}, {{ opacity: 1, x: 0, duration: 0.35, ease: 'power3.out' }}, 0.7);
  tl.fromTo('#s03-tile', {{ opacity: 0, scale: 0.97 }}, {{ opacity: 1, scale: 1, duration: 0.4, ease: 'power2.out' }}, {t_load});
  {spin_js('#s03-spin', t_load, t_done + 0.3)}
  // the image arrives: the turn settles, the activity row folds away
  tl.to('#s03-img', {{ opacity: 1, duration: 0.5, ease: 'power1.out' }}, {t_done});
  tl.to('#s03-load', {{ opacity: 0, duration: 0.3 }}, {t_done + 0.2});
  tl.to('#s03-h1', {{ opacity: 0, duration: 0.15 }}, {t_done + 0.1});
  tl.to('#s03-h2', {{ opacity: 1, duration: 0.15 }}, {t_done + 0.2});
  tl.to('#s03-step', {{ opacity: 0, duration: 0.2 }}, {t_done + 0.2});
  tl.to('#s03-low', {{ y: -34, duration: 0.35, ease: 'power2.inOut' }}, {t_done + 0.25});
  tl.fromTo('#s03-pan', {{ y: 0 }}, {{ y: {pan}, duration: 0.9, ease: 'power2.inOut' }}, {t_done + 0.2});
  hfStream(tl, '#s03-ai-t-p0', {t_done + 0.7:.2f});
  tl.fromTo('#s03-cam', {{ scale: 1 }}, {{ scale: {1.03 if v else 1.05}, duration: {b - a - t_done:.2f}, ease: 'power1.inOut' }}, {t_done});
"""
    ep.add("s03", a, b, css, body, js)


# =================================================================== s05 the request the server sends upstream
def s05_request(ep, a, b, v):
    fmt = ep.fmt
    p = REQ["provider"]
    tf = lambda x: "true" if x is True else ("false" if x is False else json.dumps(x))  # noqa: E731
    if v:
        ind = "  "
        rows = ["{", f'{ind}"model": "{REQ["model"]}",', f'{ind}"prompt":', f'{ind}"{REQ["prompt"]}",', f'{ind}"n": {REQ["n"]},',
                f'{ind}"provider": {{']
    else:
        ind = "  "
        rows = ["{", f'{ind}"model": "{REQ["model"]}",', f'{ind}"prompt": "{REQ["prompt"]}",', f'{ind}"n": {REQ["n"]},',
                f'{ind}"provider": {{']
    hl0 = len(rows)
    rows += [f'{ind * 2}"{k}": {tf(p[k])}{"," if i < len(p) - 1 else ""}' for i, k in enumerate(p)]
    rows += [f"{ind}}},", f'{ind}"aspect_ratio": "{REQ["aspect_ratio"]}"', "}"]
    if v:
        fs, lh, left, top, width, pad = 34, 50, 16, 250, 1048, 22
        line_top, lines, lsize = 1180, ["Made with zero", "data retention."], 104
    else:
        fs, lh, left, top, width, pad = 32, 47, 240, 40, 1440, 40
        line_top, lines, lsize = 846, ["Made with zero data retention."], 96
    body_rows = []
    for i, r in enumerate(rows):
        k, sep, val = r.partition(": ")
        if sep:
            body_rows.append(f'<div class="ex-l" id="s05-r{i}"><span class="ex-k">{esc(k)}: </span><span class="ex-v{" rq-true" if hl0 <= i < hl0 + 3 else ""}">{esc(val)}</span></div>')
        else:
            body_rows.append(f'<div class="ex-l" id="s05-r{i}"><span class="ex-k">{esc(r)}</span></div>')
    from chukvid.ui import SVG
    card = (f'<div class="sb-card" id="s05-card" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="ex-bar">{SVG["upload"].replace("M12 15V4M7 9l5-5 5 5M5 20h14", "M5 12h12M13 7l5 5-5 5M4 4v16")}'
            f'<b>Image request</b><span class="sb-tag">openrouter.ai</span><span class="sb-grow"></span>'
            f'<span style="font-size:{30 if v else 28}px;color:#687076">{"JSON" if v else "POST /api/v1/images"}</span></div>'
            f'<div class="ex-body" id="s05-b" style="position:relative;padding:{pad - 4}px {pad}px {pad}px;font-size:{fs}px;line-height:{lh}px">'
            f'<div class="rq-hl" id="s05-hl" style="top:{pad - 4 + hl0 * lh}px;height:{3 * lh}px;left:-{pad}px;right:-{pad}px"></div>'
            f'<div style="position:relative">{"".join(body_rows)}</div></div></div>')
    lh2 = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s05-l{i}" style="top:{line_top + i * lh2}px;font-size:{lsize}px;line-height:{lh2}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    css = f"""
#s05-card .ex-bar {{ font-size: {30 if v else 28}px; }}
#s05-card .ex-bar .sb-tag {{ font-size: {28 if v else 24}px; }}
#s05-cardw {{ transform-origin: {left + width / 2}px {top + 300}px; }}
"""
    body = f"""
    <div id="s05-cardw" class="fill">{card}</div>
    {ldivs}
"""
    js = f"""
  tl.fromTo('#s05-card', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s05-b .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.2, stagger: 0.05 }}, 0.15);
  tl.fromTo('#s05-hl', {{ scaleX: 0 }}, {{ scaleX: 1, duration: 0.55, ease: 'power2.inOut' }}, 1.05);
  tl.fromTo('#s05-cardw', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
  {''.join(f"hfReveal(tl, '#s05-l{i}', {1.7 + i * 0.4:.2f}, 0.09);" for i in range(len(lines)))}
"""
    ep.add("s05", a, b, css, body, js)


# =================================================================== s06 colour block: server RAM, 15 min at most, gone on download
def s06_memory(ep, a, b, v):
    fmt = ep.fmt
    t_drop = 27.48 - a                                  # the strongest hit: the app downloads it
    if v:
        R, cx, cy = 230, fmt.cx, 560
        lines, lsize, ltop, lx, align = ["Kept in server", "memory: 15 min", "at most."], 100, 900, 0, "center"
        sub_top, sub_size = ltop + 3 * 112 + 40, 60
    else:
        R, cx, cy = 250, 520, 520
        lines, lsize, ltop, lx, align = ["Kept in server memory:", "15 minutes at most."], 88, 330, 900, "left"
        sub_top, sub_size = ltop + 2 * 100 + 70, 58
    lh = round(lsize * 1.12)
    ldivs = "".join(
        f'<div class="serif" id="s06-l{i}" style="position:absolute;left:{lx}px;right:{0 if v else 40}px;top:{ltop + i * lh}px;font-size:{lsize}px;'
        f'line-height:{lh}px;text-align:{align};color:@CANVAS@">{esc(t)}</div>' for i, t in enumerate(lines))
    sub = (f'<div class="serif" id="s06-sub" style="position:absolute;left:{lx}px;right:{0 if v else 40}px;top:{sub_top}px;font-size:{sub_size}px;'
           f'line-height:{round(sub_size * 1.2)}px;text-align:{align};color:#E9C9A8">Deleted on the first download.</div>')
    circ = 2 * 3.14159 * (R - 14)
    ticks = [("15:00", 0.0), ("14:59", 1.0), ("14:58", 2.0)]
    tdivs = "".join(f'<span class="s06-t" id="s06-t{i}" style="display:{"inline" if i == 0 else "none"}">{t}</span>' for i, (t, _) in enumerate(ticks))
    tjs = "".join(f"tl.set('#s06-t{i - 1}', {{ display: 'none' }}, {0.3 + tt:.2f}); tl.set('#s06-t{i}', {{ display: 'inline' }}, {0.3 + tt:.2f});"
                  for i, (_, tt) in enumerate(ticks) if i)
    css = f"""
#s06-bg {{ background: @BROWN@; }}
#s06-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#s06-ring {{ position: absolute; left: {cx - R}px; top: {cy - R}px; width: {2 * R}px; height: {2 * R}px; }}
#s06-mid {{ position: absolute; left: {cx - R}px; top: {cy - R}px; width: {2 * R}px; height: {2 * R}px; display: flex; flex-direction: column; align-items: center; justify-content: center; color: @CANVAS@; }}
#s06-clock {{ font-family: 'ChukMono', monospace; font-variant-ligatures: none; font-size: {104 if v else 110}px; line-height: 1; font-weight: 500; }}
#s06-cap {{ margin-top: 18px; font-family: 'ChukMono', monospace; font-size: {36 if v else 34}px; color: #E9C9A8; white-space: nowrap; }}
#s06-gone {{ position: absolute; left: {cx - R}px; top: {cy - R}px; width: {2 * R}px; height: {2 * R}px; display: flex; flex-direction: column; align-items: center; justify-content: center; color: @CANVAS@; opacity: 0; }}
#s06-gone .s06-x {{ font-family: 'ChukMono', monospace; font-size: {40 if v else 38}px; color: #E9C9A8; margin-top: 18px; }}
"""
    body = f"""
    <div id="s06-bg" class="fill"></div>
    <div id="s06-all" class="fill">
      <svg id="s06-ring" viewBox="0 0 {2 * R} {2 * R}">
        <circle cx="{R}" cy="{R}" r="{R - 14}" fill="none" stroke="rgba(244,238,228,0.18)" stroke-width="14"/>
        <circle id="s06-arc" cx="{R}" cy="{R}" r="{R - 14}" fill="none" stroke="@CANVAS@" stroke-width="14" stroke-linecap="round"
          stroke-dasharray="{circ:.1f} {circ:.1f}" stroke-dashoffset="0" transform="rotate(-90 {R} {R})"/>
      </svg>
      <div id="s06-mid"><div id="s06-clock">{tdivs}</div><div id="s06-cap">server RAM</div></div>
      <div id="s06-gone">{hi('h-tick02', 120)}<div class="s06-x">deleted</div></div>
      {ldivs}
      {sub}
    </div>
"""
    js = f"""
  tl.fromTo('#s06-all', {{ scale: 1.0 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
  tl.fromTo('#s06-ring', {{ opacity: 0, scale: 0.85 }}, {{ opacity: 1, scale: 1, duration: 0.5, ease: 'back.out(1.4)' }}, 0);
  tl.fromTo('#s06-mid', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 0.15);
  {tjs}
  tl.fromTo('#s06-arc', {{ strokeDashoffset: 0 }}, {{ strokeDashoffset: {circ * 3 / 900:.2f}, duration: {t_drop - 0.6:.2f}, ease: 'none' }}, 0.3);
  hfReveal(tl, '#s06-l0', 0.35);
  hfReveal(tl, '#s06-l1', 0.8);
  {"hfReveal(tl, '#s06-l2', 1.2);" if v else ""}
  // first download (the app fetches it): the entry is dropped at once
  tl.to('#s06-arc', {{ strokeDashoffset: {circ:.1f}, duration: 0.35, ease: 'power3.in' }}, {t_drop - 0.25:.2f});
  tl.to('#s06-mid', {{ opacity: 0, scale: 0.9, duration: 0.2 }}, {t_drop - 0.05:.2f});
  tl.to('#s06-arc', {{ opacity: 0, duration: 0.1 }}, {t_drop + 0.08:.2f});
  tl.fromTo('#s06-gone', {{ opacity: 0, scale: 0.8 }}, {{ opacity: 1, scale: 1, duration: 0.4, ease: 'back.out(1.6)' }}, {t_drop + 0.05:.2f});
  hfReveal(tl, '#s06-sub', {t_drop + 0.25:.2f}, 0.07);
"""
    assert 1.5 < t_drop < b - a - 1.5, t_drop
    ep.add("s06", a, b, css, body, js)


# =================================================================== s07 Storage: it is stored as .enc
def s07_storage(ep, a, b, v):
    fmt = ep.fmt
    uid_label = mask_uuid_short(C["user_id"])
    rows_src = [(C["object"], C["object_bytes"], C["modified"])] + [(o["name"], o["bytes"], o["modified"]) for o in C["others"]]

    def short(n):
        stem, _, ext = n.partition(".")
        return stem[:8] + "…" + stem[-4:] + "." + ext

    if v:
        cols = [("Name", 700), ("Size", 316)]
        rows = [[short(n), human_bytes(s)] for n, s, _ in rows_src]
        row_h, left, top = 100, 31, 330
        line_top, lines, lsize = 1190, ["Then stored", "encrypted."], 108
        nfs, dfs = 36, 34
    else:
        cols = [("Name", 1010), ("Size", 220), ("Last modified", 370)]
        rows = [[n, human_bytes(s), m] for n, s, m in rows_src]
        row_h, left, top = 86, 160, 60
        line_top, lines, lsize = 836, ["Then stored encrypted."], 96
        nfs, dfs = 32, 30
    card = ui.storage_list("s07-st", "images", uid_label, cols, rows, mine=0, left=left, top=top)
    lh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s07-l{i}" style="top:{line_top + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    css = f"""
#s07-st .st-row:not(.st-head) {{ height: {row_h}px; }}
#s07-st .st-name {{ font-size: {nfs}px; }}
#s07-st .st-dim {{ font-size: {dfs}px; }}
#s07-st .st-head {{ height: 70px; font-size: {dfs}px; }}
#s07-st .st-crumb {{ font-size: {dfs + 4}px; }}
#s07-st .sb-tag, #s07-st .sb-btn {{ font-size: {dfs - 2}px; }}
#s07-st .st-name .sb-ic {{ width: 34px; height: 34px; }}
#s07-sel {{ left: {left}px; top: {top + 92 + 70}px; width: {sum(w for _, w in cols) + 2}px; height: {row_h}px; }}
#s07-w {{ transform-origin: {fmt.cx}px {top + 200}px; }}
"""
    body = f"""
    <div id="s07-w" class="fill">{card}<div class="sb-sel" id="s07-sel"></div></div>
    {ldivs}
"""
    js = f"""
  tl.fromTo('#s07-st', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s07-st .st-row', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, stagger: 0.06 }}, 0.12);
  tl.fromTo('#s07-st-r0', {{ backgroundColor: '#FFFFFF' }}, {{ backgroundColor: '#ECF8F2', duration: 0.3 }}, 0.75);
  tl.to('#s07-sel', {{ opacity: 1, duration: 0.15 }}, 0.75);
  tl.fromTo('#s07-w', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
  {''.join(f"hfReveal(tl, '#s07-l{i}', {1.0 + i * 0.4:.2f}, 0.09);" for i in range(len(lines)))}
"""
    ep.add("s07", a, b, css, body, js)


# =================================================================== s08 the media manager decrypts it on the device
def s08_media(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        Z, pw, cols = 1.36, 760, 4
        px_, py_ = (fmt.W / Z - pw) / 2, 560 / Z
        lines, lsize, ltop = ["Opened on", "your device."], 108, 270
        push = 2.45
    else:
        Z, pw, cols = 1.7, 1000, 5
        px_, py_ = (fmt.W / Z - pw) / 2, 250 / Z
        lines, lsize, ltop = ["Opened on your device."], 92, 64
        push = 1.85
    inner_w = pw - 40
    tile = (inner_w - (cols - 1) * 14) / cols
    grid_top = 64 + 60 + 52 + 8                          # head, toolbar, filter track + 8
    ph = grid_top + tile + 20 + 2
    srcs = [IMG] + OTHERS
    tiles = []
    for i, s in enumerate(srcs[:cols] if cols < 5 else srcs):
        extra = ""
        if i == 0:
            extra = (f'<div class="mm-hov" id="s08-hov"></div><div class="mm-acts" id="s08-acts"><span class="mm-act">{hi("h-download01", 17 / 0.86)}</span>'
                     f'<span class="mm-act del">{DELETE02.format(s=17)}</span></div><div class="mm-meta" id="s08-meta">{MM_DATE} · {MM_SIZE}</div>')
        tiles.append(f'<div class="mm-tile" id="s08-t{i}"><svg class="mm-sp" id="s08-sp{i}" viewBox="0 0 22 22"><circle cx="11" cy="11" r="10" fill="none" '
                     f'stroke="@ACC@" stroke-width="2" stroke-linecap="round" stroke-dasharray="17.6 62.8"/></svg>'
                     f'<img id="s08-i{i}" src="{s}" alt="">{extra}</div>')
    n = len(tiles)
    inner = f"""
      <div class="mm-panel" id="s08-panel" style="left:{px_:.1f}px;top:{py_:.1f}px;width:{pw}px;height:{ph:.1f}px">
        <div class="mm-head"><span class="mm-title">Media Manager</span><span class="a-grow"></span><span class="mm-close">{hi('h-cancel01', 20 / 0.86)}</span></div>
        <div class="mm-tool"><span class="mm-count">{n} images</span><span class="a-grow"></span><span class="mm-chip"><i>{hi('h-refresh', 22 / 0.86)}</i></span></div>
        <div class="mm-filter" style="top:{64 + 60}px"><span class="mm-seg on">Images  {n}</span><span class="mm-seg">Artifacts</span></div>
        <div class="mm-grid" style="top:{grid_top}px;grid-template-columns:repeat({cols}, {tile:.2f}px)">{''.join(tiles)}</div>
      </div>
"""
    # Bruno tile centre and hover point, video px
    tcx, tcy = (px_ + 20 + tile / 2) * Z, (py_ + grid_top + tile / 2) * Z
    lh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s08-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    css = f"""
#s08-cam {{ transform-origin: {(px_ + 20) * Z - 20:.0f}px {tcy + tile * Z * 0.25:.0f}px; }}
"""
    body = f"""
    <div id="s08-cam" class="fill" data-layout-allow-overflow>
      {ui.appz('s08-z', fmt, Z, inner)}
      {cursor('s08-cur', cs)}
    </div>
    <div id="s08-lw" class="fill">{ldivs}</div>
"""
    pops = "".join(
        f"tl.to('#s08-i{i}', {{ opacity: 1, duration: 0.25 }}, {0.55 + i * 0.13:.2f}); tl.set('#s08-sp{i}', {{ opacity: 0 }}, {0.62 + i * 0.13:.2f});"
        for i in range(n))
    spins = "".join(spin_js(f'#s08-sp{i}', 0, 0.7 + i * 0.13) for i in range(n))
    t_push = 1.85
    js = f"""
  tl.fromTo('#s08-panel', {{ opacity: 0, scale: 0.98 }}, {{ opacity: 1, scale: 1, duration: 0.25, ease: 'power3.out' }}, 0);
  {spins}
  {pops}
  {''.join(f"hfReveal(tl, '#s08-l{i}', {0.35 + i * 0.4:.2f}, 0.09);" for i in range(len(lines)))}
  tl.fromTo('#s08-cur', {{ x: {tcx + 520:.0f}, y: {fmt.H + 60} }}, {{ x: {tcx + 30:.0f}, y: {tcy - 10:.0f}, duration: 0.85, ease: 'power2.inOut' }}, 0.5);
  tl.to('#s08-hov', {{ opacity: 1, duration: 0.14 }}, 1.3);
  tl.to('#s08-acts', {{ opacity: 1, duration: 0.14 }}, 1.3);
  tl.to('#s08-meta', {{ opacity: 1, duration: 0.14 }}, 1.3);
  tl.to('#s08-lw', {{ opacity: 0, duration: 0.3 }}, {t_push + 0.1});
  tl.to('#s08-cur', {{ x: {tcx + 150:.0f}, y: {tcy - 60:.0f}, duration: 0.5, ease: 'power2.out' }}, {t_push - 0.2});
  tl.fromTo('#s08-cam', {{ scale: 1 }}, {{ scale: {push}, duration: 1.4, ease: 'power2.inOut' }}, {t_push});
"""
    ep.add("s08", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-10-private-images")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-10-private-images-vertical")
