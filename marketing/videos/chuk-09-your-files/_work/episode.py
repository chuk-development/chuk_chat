#!/usr/bin/env python3
"""Episode 09 "your-files": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 09): a photo of a lab report is dragged into the real
composer, "what does this say about my thyroid?", the answer. Cut: the Storage bucket
images/<uid>/<uuid>.enc, one object opened: ciphertext. "Stored as ciphertext. / Only you
hold the key." (storage + key only: the server and the model get the file in plain text
to answer, so nothing here says they never see it)
Claim (PRIVACY_CLAIMS.md, Files and images, may say): your photos, scans and files are
encrypted on your device before they are stored; Storage only holds .enc ciphertext.

Builds both formats from one spec:
  ../chuk-09-your-files/            16:9 1920x1080
  ../chuk-09-your-files-vertical/   9:16 1080x1920 (re-laid out, not cropped)
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

MUSIC = VIDEOS.parent / "_shared/music/s1-summer-bells-45s.wav"
DUR = 45.0
C = json.loads((HERE / "cipher.json").read_text())
ENV = C["envelope"]
CT = ENV["ciphertext"]
JPG = HERE / "gen/lab-report.jpg"
IMG = "assets/img/lab-report.jpg"
FILE_NAME = "IMG_2041.jpg"
JPG_SIZE = human_bytes(C["jpg_bytes"])          # what the attachment card shows
OBJ_SIZE = human_bytes(C["object_bytes"])       # the .enc object in Storage

PROMPT = "what does this say about my thyroid?"
ANSWER = [
    "Your TSH is 6.8 mIU/L, above the 0.4–4.0 range, while free T4 is still normal. "
    "Your TPO antibodies are raised too.",
    "Together this often points to an early underactive thyroid (Hashimoto's). "
    "Ask your doctor about a repeat test in 6 to 8 weeks.",
]
STEPS = [("h-bulb", "User shares a thyroid panel and asks what it means.", None)]

# ------------------------------------------------------------------ cuts on the beat grid
# 109 BPM, beat 0.55 s; the steady part ends with the strongest hit at 34.72, then the
# track fades out under the end card. Rough targets, snapped to the beat grid.
TARGETS = [4.1, 11.6, 19.8, 22.0, 28.1, 32.5, 34.7]


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + EP_CSS)
    ep.asset(JPG, "img/lab-report.jpg")
    ep.write()                                   # scaffold first: `beats` needs the music in place
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.4)
    v = fmt.vertical
    cs = 1.3 if v else 1.0                       # cursor scale

    s01_hook(ep, cut[0], cut[1], v)
    s02_drop(ep, cut[1], cut[2], v, cs)
    s03_answer(ep, cut[2], cut[3], v)
    scenes.card(ep, "s04", cut[3], cut[4], ["Now look at", "our storage."] if v else ["Now look at our storage."])
    s05_storage(ep, cut[4], cut[5], v, cs)
    s06_block(ep, cut[5], cut[6], v)
    scenes.card(ep, "s07", cut[6], cut[7],
                ["Stored as", "ciphertext.", "Only you hold", "the key."] if v
                else ["Stored as ciphertext.", "Only you hold the key."], bg="@TAN@")
    scenes.end_card(ep, "s08", cut[7], DUR)
    ep.write()
    ep.report()
    return ep


EP_CSS = """
.photo { position: absolute; border-radius: 14px; overflow: hidden; box-shadow: 0 24px 50px -22px rgba(0,0,0,0.45); }
.photo img { display: block; width: 100%; height: 100%; object-fit: cover; }
.pcap { position: absolute; text-align: center; font-family: 'Ubuntu', sans-serif; font-weight: 500; color: @SOFT@; white-space: nowrap; }
"""


# =================================================================== s01 the photo (hook)
def s01_hook(ep, a, b, v):
    if v:
        pw, ph, px, py = 540, 720, 270, 270
        cap_y, lines, size, ly = py + ph + 34, ["A photo of your", "lab results."], 112, 1130
        lx, align = 0, "center"
    else:
        pw, ph, px, py = 480, 640, 250, 200
        cap_y, lines, size, ly = py + ph + 30, ["A photo of your", "lab results."], 108, 410
        lx, align = 880, "left"
    lh = round(size * 1.12)
    capsz = 32 if v else 28
    ldivs = "".join(
        f'<div class="serif" id="s01-l{i}" style="position:absolute;left:{lx}px;right:0;top:{ly + i * lh}px;'
        f'font-size:{size}px;line-height:{lh}px;text-align:{align}">{esc(t)}</div>' for i, t in enumerate(lines))
    css = f"""
#s01-all {{ transform-origin: {ep.fmt.cx}px {ep.fmt.cy}px; }}
#s01-ph {{ left: {px}px; top: {py}px; width: {pw}px; height: {ph}px; }}
#s01-cap {{ left: {px - 100}px; width: {pw + 200}px; top: {cap_y}px; font-size: {capsz}px; }}
"""
    body = f"""
    <div id="s01-all" class="fill">
      <div class="photo" id="s01-ph"><img src="{IMG}" alt=""></div>
      <div class="pcap" id="s01-cap">{FILE_NAME} · {JPG_SIZE}</div>
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s01-ph', {{ y: 26, rotation: -5 }}, {{ y: 0, rotation: -3, duration: 0.9, ease: 'expo.out' }}, 0);
  tl.fromTo('#s01-cap', {{ opacity: 0.0 }}, {{ opacity: 1, duration: 0.4 }}, 0.35);
  hfReveal(tl, '#s01-l0', 0.7);
  hfReveal(tl, '#s01-l1', 1.15);
  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s01", a, b, css, body, js)


# =================================================================== s02 drag the photo into the composer, ask
def s02_drop(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        Z = 1.9
        win = dict(left=24, top=400, w=520, h=400)   # app px inside the zoom box
        cw = 460
        tile = dict(x=405, y=250, w=270, h=360)      # video px on the canvas
        cap_sz = 30
    else:
        Z = 2.0
        win = dict(left=270, top=60, w=640, h=420)
        cw = 560
        tile = dict(x=110, y=330, w=270, h=360)
        cap_sz = 28
    W, H = fmt.W / Z, fmt.H / Z
    cl = win["left"] + (win["w"] - cw) / 2
    comp_bottom_y = win["top"] + win["h"] - 44            # app px, the composer's bottom edge
    bottom = H - comp_bottom_y
    comp_top_att = comp_bottom_y - 198                    # composer height with one image row
    # targets in video px
    field = ((cl + 2 + 14 + 6) * Z, (comp_top_att + 106 + 14) * Z)
    send = ((cl + cw - 2 - 14 - 22) * Z, (comp_top_att + 2 + 14 + 18) * Z)
    over_h = comp_bottom_y - 135 - win["top"]             # message area above the (empty) composer
    # drop below the overlay card so its text stays readable under the drag image
    drop_pt = ((win["left"] + win["w"] / 2) * Z, (win["top"] + over_h / 2 + 70) * Z)
    tcx, tcy = tile["x"] + tile["w"] / 2, tile["y"] + tile["h"] / 2
    # ghost (the drag image) is a small copy of the photo, held at its top-left by the hand
    gw, gh = round(tile["w"] * 0.55), round(tile["h"] * 0.55)
    att = ui.attach_card("s02-card", IMG, JPG_SIZE)
    inner = f"""
        <div id="s02-win" class="a-win" style="left:{win['left']}px;top:{win['top']}px;width:{win['w']}px;height:{win['h']}px">
          <div id="s02-drop" class="fill" style="opacity:0">{ui.drop_overlay('s02-dov', over_h)}</div>
        </div>
        {ui.composer('s02', cw, cl, bottom=bottom, attach=att)}
        {ui.disclaimer('s02-disc', comp_bottom_y + 8)}
"""
    css = f"""
#s02-cam {{ transform-origin: {drop_pt[0]:.0f}px {drop_pt[1]:.0f}px; }}
#s02-tile {{ left: {tile['x']}px; top: {tile['y']}px; width: {tile['w']}px; height: {tile['h']}px; }}
#s02-tcap {{ left: {tile['x'] - 80}px; width: {tile['w'] + 160}px; top: {tile['y'] + tile['h'] + 22}px; font-size: {cap_sz}px; }}
#s02-ghost {{ left: 0; top: 0; width: {gw}px; height: {gh}px; opacity: 0; z-index: 50; border-radius: 10px; }}
#s02-comp {{ z-index: 3; }}
"""
    body = f"""
    <div id="s02-cam" class="fill">
      <div class="photo" id="s02-tile"><img src="{IMG}" alt=""></div>
      <div class="pcap" id="s02-tcap">{FILE_NAME}</div>
      {ui.appz('s02-z', fmt, Z, inner)}
      <div class="photo" id="s02-ghost"><img src="{IMG}" alt=""></div>
      {cursor('s02-cur', cs)}
    </div>
"""
    # the ghost hangs below-right of the pointer, like a desktop drag image
    gx, gy = -gw * 0.3, -gh * 0.15
    type_start = 3.65
    type_end = type_start + len(PROMPT) / 18
    js = f"""
  tl.fromTo('#s02-z', {{ opacity: 0, y: 24 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s02-tile', {{ rotation: -3, opacity: 1 }}, {{ rotation: -3, opacity: 1, duration: 0.01 }}, 0);
  tl.fromTo('#s02-tcap', {{ opacity: 1 }}, {{ opacity: 1, duration: 0.01 }}, 0);
  tl.set('#s02-caret', {{ opacity: 0 }}, 0);
  // pick up the photo
  tl.fromTo('#s02-cur', {{ x: {tcx - 140:.0f}, y: {fmt.H + 60} }}, {{ x: {tcx:.0f}, y: {tcy:.0f}, duration: 0.75, ease: 'power2.inOut' }}, 0.2);
  hfShape(tl, '#s02-cur', 0.85, 'hand');
  hfClick(tl, '#s02-cur', 1.0, 'hand');
  tl.to('#s02-tile', {{ opacity: 0.45, duration: 0.15 }}, 1.05);
  tl.fromTo('#s02-ghost', {{ x: {tcx + gx:.0f}, y: {tcy + gy:.0f}, rotation: -3, opacity: 0 }}, {{ opacity: 0.92, duration: 0.12 }}, 1.05);
  // drag it into the window
  tl.to('#s02-cur', {{ x: {drop_pt[0]:.0f}, y: {drop_pt[1]:.0f}, duration: 1.25, ease: 'power2.inOut' }}, 1.12);
  tl.to('#s02-ghost', {{ x: {drop_pt[0] + gx:.0f}, y: {drop_pt[1] + gy:.0f}, rotation: 0, duration: 1.25, ease: 'power2.inOut' }}, 1.12);
  tl.to('#s02-drop', {{ opacity: 1, duration: 0.15 }}, 1.45);
  tl.fromTo('#s02-dov-card', {{ scale: 0.96 }}, {{ scale: 1, duration: 0.25, ease: 'power2.out' }}, 1.45);
  // drop: the overlay goes, the image card appears in the composer
  hfClick(tl, '#s02-cur', 2.45, 'hand');
  tl.to('#s02-ghost', {{ opacity: 0, scale: 0.6, duration: 0.18, ease: 'power2.in' }}, 2.50);
  tl.to('#s02-drop', {{ opacity: 0, duration: 0.15 }}, 2.52);
  tl.to('#s02-tile', {{ opacity: 1, duration: 0.2 }}, 2.52);
  tl.set('#s02-att', {{ display: 'flex' }}, 2.55);
  tl.fromTo('#s02-card', {{ opacity: 0, scale: 0.7 }}, {{ opacity: 1, scale: 1, duration: 0.3, ease: 'back.out(1.6)' }}, 2.55);
  hfShape(tl, '#s02-cur', 2.65, 'arrow');
  // click into the field and type
  tl.to('#s02-cur', {{ x: {field[0]:.0f}, y: {field[1]:.0f}, duration: 0.6, ease: 'power2.inOut' }}, 2.70);
  hfShape(tl, '#s02-cur', 3.15, 'ibeam');
  hfClick(tl, '#s02-cur', 3.35, 'ibeam');
  tl.set('#s02-caret', {{ opacity: 1 }}, 3.40);
  tl.set('#s02-ph', {{ display: 'none' }}, {type_start});
  tl.set('#s02-caret', {{ display: 'none' }}, {type_start});
  tl.set('#s02-typed', {{ display: 'inline' }}, {type_start});
  tl.set('#s02-caret2', {{ opacity: 1 }}, {type_start});
  hfShape(tl, '#s02-cur', {type_start + 0.05}, 'arrow');
  tl.to('#s02-cur', {{ x: {drop_pt[0] + 260:.0f}, y: {drop_pt[1] - 40:.0f}, duration: 0.6, ease: 'power2.out' }}, {type_start + 0.05});
  var end = hfType(tl, document.getElementById('s02-typed'), {PROMPT!r}, {type_start}, 18);
  // send
  tl.to('#s02-cur', {{ x: {send[0]:.0f}, y: {send[1]:.0f}, duration: 0.7, ease: 'power2.inOut' }}, end + 0.12);
  hfShape(tl, '#s02-cur', end + 0.75, 'hand');
  tl.to('#s02-send', {{ backgroundColor: '#C9684A', duration: 0.1 }}, end + 0.75);
  hfClick(tl, '#s02-cur', end + 0.95, 'hand');
  tl.to('#s02-send', {{ scale: 0.9, duration: 0.08 }}, end + 0.95);
  tl.to('#s02-send', {{ scale: 1, backgroundColor: '@ACC@', duration: 0.14 }}, end + 1.03);
  tl.set('#s02-typed', {{ display: 'none' }}, end + 1.1);
  tl.set('#s02-att', {{ display: 'none' }}, end + 1.1);
  tl.set('#s02-ph', {{ display: 'inline' }}, end + 1.1);
  tl.set('#s02-caret2', {{ opacity: 0 }}, end + 1.1);
  tl.set('#s02-caret', {{ display: 'block', opacity: 1 }}, end + 1.1);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: 1.06, duration: {b - a - 2.6:.2f}, ease: 'power1.inOut' }}, 2.6);
"""
    assert type_end + 1.2 < b - a, (type_end, b - a)
    ep.add("s02", a, b, css, body, js)


# =================================================================== s03 the answer
def s03_answer(ep, a, b, v):
    fmt = ep.fmt
    if v:
        Z, colw, img = 2.2, 440, 262
        col_top = 118
        pan = 0
    else:
        Z, colw, img = 2.0, 728, 262
        col_top = 66
        pan = -205                               # video px: scroll up as the answer arrives
    W, H = fmt.W / Z, fmt.H / Z
    cx = (W - colw) / 2
    win_top = col_top - 30
    win_h = 640 if v else 560
    wtl, wend = ui.worked_js("s03", 0.95, len(STEPS))
    inner = f"""
        <div id="s03-win" class="a-win" style="left:{cx - (16 if v else 56):.2f}px;top:{win_top}px;width:{colw + (32 if v else 112)}px;height:{win_h}px"></div>
        <div id="s03-col" class="a-col" style="left:{cx:.2f}px;top:{col_top}px;width:{colw}px">
          {ui.user_message('s03-u', PROMPT, image=IMG, wrap=v, img_size=img)}
          {ui.worked('s03', 3, STEPS)}
          {ui.answer('s03-ai', ANSWER)}
        </div>
"""
    # push-in target: the photo in the bubble (top right of the column)
    ox, oy = (cx + colw - img / 2) * Z, (col_top + img / 2) * Z + pan
    if v:                                        # keep the answer's left edge in frame
        ox, oy = fmt.cx, fmt.cy
    css = f"""
#s03-cam {{ transform-origin: {ox:.0f}px {oy:.0f}px; }}
"""
    body = f"""
    <div id="s03-cam" class="fill" data-layout-allow-overflow>
      <div id="s03-pan" class="fill">{ui.appz('s03-z', fmt, Z, inner)}</div>
    </div>
"""
    js = f"""
  tl.fromTo('#s03-z', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 0);
  tl.fromTo('#s03-u-img', {{ opacity: 0, y: 50 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s03-u-bub', {{ opacity: 0, y: 50 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0.08);
  {wtl}
  tl.fromTo('#s03-pan', {{ y: 0 }}, {{ y: {pan}, duration: 1.3, ease: 'power2.inOut' }}, 1.1);
  hfStream(tl, '#s03-ai-p0', {wend + 0.4:.2f});
  hfStream(tl, '#s03-ai-p1', {wend + 0.4 + 21 * 0.085 + 0.25:.2f});
  tl.fromTo('#s03-cam', {{ scale: 1 }}, {{ scale: {1.035 if v else 1.08}, duration: 2.2, ease: 'power2.inOut' }}, {b - a - 2.3:.2f});
"""
    ep.add("s03", a, b, css, body, js)


# =================================================================== s05 the Storage bucket, one object opened
def s05_storage(ep, a, b, v, cs):
    fmt = ep.fmt
    uid_label = mask_uuid_short(C["user_id"])
    rows_src = [(C["object"], C["object_bytes"], C["modified"])] + [
        (o["name"], o["bytes"], o["modified"]) for o in C["others"]]

    def short(n):  # 9:16 shows the middle of the uuid elided, keeps the .enc ending
        stem, _, ext = n.partition(".")
        return stem[:13] + "…" + stem[-4:] + "." + ext

    if v:
        cols = [("Name", 640), ("Size", 358)]
        rows = [[short(n), human_bytes(s)] for n, s, _ in rows_src]
        row_h = 92
        left, top = 40, round(fmt.cy - (92 + 64 + 5 * row_h) / 2)
        ex = dict(left=40, top=360, width=1000, ct=51 * 6 - 22)
        line_top, lines, lsize = 1200, ["Storage only holds", "ciphertext."], 100
    else:
        cols = [("Name", 820), ("Size", 190), ("Type", 380), ("Last modified", 290)]
        rows = [[n, human_bytes(s), "application/octet-stream", m] for n, s, m in rows_src]
        left, top = 120, 250
        row_h = 80
        ex = dict(left=160, top=130, width=1600, ct=84 * 4 - 20)
        line_top, lines, lsize = 846, ["Storage only holds ciphertext."], 96
    card = ui.storage_list("s05-st", "images", uid_label, cols, rows, mine=0, left=left, top=top)
    more = f"+ {len(CT) - ex['ct']:,} more characters"
    viewer = ui.envelope_viewer("s05-ex", short(C["object"]) if v else C["object"], "application/octet-stream" if not v else "octet-stream",
                                OBJ_SIZE, ENV, ex["left"], ex["top"], ex["width"], ct_chars=ex["ct"], more=more, icon="file")
    lh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s05-l{i}" style="top:{line_top + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    name_y = top + 92 + 64 + row_h / 2
    css = f"""
#s05-st .st-row:not(.st-head) {{ height: {row_h}px; }}
{'#s05-st .st-name { font-size: 28px; } #s05-st .st-dim { font-size: 28px; }' if v else ''}
#s05-ex {{ opacity: 0; }}
#s05-sel {{ left: {left}px; top: {top + 92 + 64}px; width: {sum(w for _, w in cols) + 2}px; height: {row_h}px; }}
"""
    body = f"""
    <div id="s05-stw" class="fill">{card}<div class="sb-sel" id="s05-sel"></div></div>
    {viewer}
    {ldivs}
    {cursor('s05-cur', cs)}
"""
    js = f"""
  tl.fromTo('#s05-st', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s05-st .st-row', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, stagger: 0.06 }}, 0.12);
  tl.fromTo('#s05-cur', {{ x: {fmt.W - 200}, y: {fmt.H + 60} }}, {{ x: {left + (260 if v else 420)}, y: {name_y + 14:.0f}, duration: 0.9, ease: 'power2.inOut' }}, 0.45);
  tl.to('#s05-st-r0', {{ backgroundColor: '#F1F3F5', duration: 0.15 }}, 1.2);
  hfClick(tl, '#s05-cur', 1.45);
  tl.to('#s05-sel', {{ opacity: 1, duration: 0.08 }}, 1.5);
  hfClick(tl, '#s05-cur', 1.72);
  // the object opens: its whole content is this envelope
  tl.to('#s05-cur', {{ x: {fmt.W - 120}, y: {fmt.H + 80}, duration: 0.6, ease: 'power3.in' }}, 1.9);
  tl.to('#s05-stw', {{ opacity: 0, y: -40, duration: 0.35, ease: 'power2.in' }}, 1.9);
  tl.fromTo('#s05-ex', {{ opacity: 0, scale: 0.94, y: 60 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 2.0);
  tl.fromTo('#s05-ex-b .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.2, stagger: 0.08 }}, 2.15);
  tl.fromTo('#s05-ex', {{ y: 0 }}, {{ y: -14, duration: {b - a - 2.6:.2f}, ease: 'none', immediateRender: false }}, 2.6);
  {''.join(f"hfReveal(tl, '#s05-l{i}', {2.9 + i * 0.4:.2f}, 0.09);" for i in range(len(lines)))}
"""
    ep.add("s05", a, b, css, body, js)


# =================================================================== s06 colour block: the photo becomes ciphertext
def s06_block(ep, a, b, v):
    fmt = ep.fmt
    if v:
        sq, sx, sy = 560, 260, 290
        fs, lh_c, pad = 30, 38, 24
        lines, lsize, ltop = ["Encrypted on", "your device,", "before it's stored."], 108, 1010
    else:
        sq, sx, sy = 420, 750, 80
        fs, lh_c, pad = 22, 29, 20
        lines, lsize, ltop = ["Encrypted on your device,", "before it's stored."], 96, 590
    cols = int((sq - 2 * pad) / (fs * 0.6))
    nrows = int((sq - 2 * pad) / lh_c)
    rows = [CT[i * cols:(i + 1) * cols] for i in range(nrows)]
    lh = round(lsize * 1.12)
    ldivs = "".join(f'<div class="card-line serif" id="s06-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px;color:@CANVAS@">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    rows_html = "".join(f'<div class="s06-row" id="s06-r{i}"></div>' for i in range(nrows))
    lock = 104 if v else 88
    css = f"""
#s06-bg {{ background: @BROWN@; }}
#s06-all {{ transform-origin: {fmt.cx}px {sy + sq / 2}px; }}
#s06-sq {{ position: absolute; left: {sx}px; top: {sy}px; width: {sq}px; height: {sq}px; border-radius: 12px; overflow: hidden; }}
#s06-sq img {{ display: block; width: 100%; height: 100%; object-fit: cover; }}
#s06-ct {{ position: absolute; inset: 0; background: #46302A; border: 2px solid rgba(244,238,228,0.3); border-radius: 12px; padding: {pad}px; font-family: 'ChukMono', monospace; font-size: {fs}px; line-height: {lh_c}px; color: @CANVAS@; }}
.s06-row {{ white-space: pre; height: {lh_c}px; overflow: hidden; }}
#s06-lock {{ position: absolute; left: {sx + sq - lock * 0.62:.0f}px; top: {sy + sq - lock * 0.62:.0f}px; width: {lock}px; height: {lock}px; border-radius: 50%; background: @CANVAS@; color: @BROWN@; display: flex; align-items: center; justify-content: center; }}
"""
    body = f"""
    <div id="s06-bg" class="fill"></div>
    <div id="s06-all" class="fill">
      <div id="s06-sq"><img src="{IMG}" alt=""><div id="s06-ct">{rows_html}</div></div>
      <div id="s06-lock">{hi('h-lock', lock * 0.58)}</div>
      {ldivs}
    </div>
"""
    js = f"""
  var rows = {json.dumps(rows)};
  var pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var els = rows.map(function (_, i) {{ return document.getElementById('s06-r' + i); }});
  function render(t) {{
    els.forEach(function (el, i) {{
      var t0 = i * 0.07, s = '';
      for (var j = 0; j < rows[i].length; j++) {{
        var tj = t0 + j * 0.006;
        if (t < tj) s += ' ';
        else if (t < tj + 0.3) s += pool[Math.floor(hfHash(i * 97 + j, Math.floor(t * 30)) * pool.length)];
        else s += rows[i][j];
      }}
      if (el.textContent !== s) el.textContent = s;
    }});
  }}
  var prox = {{ t: 0 }};
  render(0);
  tl.fromTo('#s06-all', {{ scale: 1.0 }}, {{ scale: 1.04, duration: {b - a:.2f}, ease: 'none' }}, 0);
  tl.fromTo('#s06-sq', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'expo.out' }}, 0);
  tl.fromTo('#s06-ct', {{ clipPath: 'inset(0 0 100% 0)' }}, {{ clipPath: 'inset(0 0 0% 0)', duration: {0.07 * nrows + 0.2:.2f}, ease: 'none' }}, 0.45);
  tl.fromTo(prox, {{ t: 0 }}, {{ t: 2.0, duration: 2.0, ease: 'none', onUpdate: function () {{ render(prox.t); }} }}, 0.45);
  tl.fromTo('#s06-lock', {{ opacity: 0, y: 30, scale: 0.7 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.5, ease: 'back.out(1.5)' }}, 1.55);
  {''.join(f"hfReveal(tl, '#s06-l{i}', {1.75 + i * 0.4:.2f});" for i in range(len(lines)))}
"""
    ep.add("s06", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-09-your-files")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-09-your-files-vertical")
