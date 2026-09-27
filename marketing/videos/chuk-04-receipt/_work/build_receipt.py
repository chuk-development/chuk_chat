#!/usr/bin/env python3
"""Generate compositions/frames/03-receipt.html and _work/receipt_times.json.

One source of truth for the receipt layout, the print schedule (on the beat
grid of the supplied track), the camera moves and the printer SFX events.

World coordinates: the printer slot is the line y = 0, x = 0 is the paper
centre, the paper hangs upward (negative y). Screen point of world P is
(cam.x + s * P.x, cam.y + s * P.y).
"""
import json
import os
import random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BARCODE = json.load(open(os.path.join(ROOT, "_work/barcode.json")))

Q = 60.0 / 110.0          # quarter note, s
E = Q / 2                 # eighth
S16 = Q / 4               # sixteenth
BAR = 4 * Q
DUR = 26.182              # frame length (bar 1 .. bar 20 of the cut)

# bars in frame-local time (bar 1 = 0.0). Bars 4-11 of the cut are the musical
# edit + ticking stop, so the list below names the bars by their local time.
def bar(n):
    return (n - 1) * BAR
T_STAB1 = 5.727           # "0" #1 lands on the stab, music stops
T_HIT1 = 8.160            # music back (grid 8.176, onset ~8.14)
T_BAR12 = 8.727
T_BAR13 = 10.909
T_ZERO2 = 11.454          # bar 13 beat 2 hit
T_HIT2 = 12.520           # hit after the short stop
T_BAR14 = 13.091

PW, PAD_TOP_LEADER = 820, 110
FS = 36                   # receipt body font px
CH = FS * 0.6             # JetBrains Mono advance
COLS = 33
CONTENT_W = COLS * CH
CONTENT_X = (PW - CONTENT_W) / 2
RH = 58
GAP = 6                   # emerged row bottom sits GAP px above the slot


def row_text(label, value, dots=True):
    n = COLS - len(label) - len(value) - 2
    assert n >= 3, (label, value, n)
    return label, n, value


ROWS = []  # dicts: id, kind, h, ... ; y filled later


def add(rid, kind, h, **kw):
    ROWS.append(dict(id=rid, kind=kind, h=h, **kw))


add("leader", "blank", PAD_TOP_LEADER)
add("logo", "logo", 100)
add("brand", "center", 70, text="CHUK CHAT", cls="r-brand")
add("sub", "center", 50, text="THE SHORT VERSION", cls="r-sub")
add("rule1", "rule", 50, text="-" * COLS)
add("chats", "item", RH, label="Your chats", value="encrypted")
add("device", "right", RH, value="on your device")
add("training", "item", RH, label="Training on your data", value="0", gag=True)
add("tracking", "item", RH, label="Tracking", value="0", gag=True)
add("models", "item", RH, label="Models", value="open-weight only")
add("switch", "item", RH, label="Model switch", value="every message")
add("connectors", "item", RH, label="Connectors", value="50+")
add("opensource", "item", RH, label="Open source", value="100%")
add("price", "item", RH, label="Price", value="€20 / month")
add("credits", "item", RH, label="incl. AI credits", value="€16")
add("from", "item", RH, label="From", value="Germany")
add("flares", "item", RH, label="Lens flares", value="0", gag=True)
add("rule2", "rule", 46, text="=" * COLS)
add("total", "left", RH, text="TOTAL", cls="r-total")
add("slogan1", "left", 84, text="Private and Secure.", cls="r-big")
add("slogan2", "left", 84, text="Always.", cls="r-big")
add("rule3", "rule", 46, text="=" * COLS)
add("barcode", "barcode", 130)
add("url", "center", 62, text="chuk.chat", cls="r-url")
add("tail", "blank", 60)

y = 0
for r in ROWS:
    r["y"] = y
    y += r["h"]
    r["bottom"] = y
L = y
BY = {r["id"]: r for r in ROWS}


def paper_top_for(rid):
    return -GAP - BY[rid]["bottom"]


# ---------------------------------------------------------------- print schedule
# (row id, local time, feed duration). The feed brings that row out of the slot.
FEEDS = [
    ("logo", bar(1), 0.22),
    ("brand", bar(1) + E, 0.16),
    ("sub", bar(1) + 2 * E, 0.14),
    ("rule1", bar(1) + 4 * E, 0.14),
    ("chats", bar(2), 0.16),
    ("device", bar(2) + 2 * Q, 0.16),
    ("training", bar(3), 0.16),
    ("tracking", T_BAR12, 0.16),
    ("models", T_BAR14, 0.16),
    ("switch", T_BAR14 + 2 * Q, 0.16),
    ("connectors", T_BAR14 + BAR, 0.16),
    ("opensource", T_BAR14 + BAR + 2 * Q, 0.16),
    ("price", T_BAR14 + 2 * BAR, 0.16),
    ("credits", T_BAR14 + 2 * BAR + 2 * Q, 0.16),
    ("from", T_BAR14 + 3 * BAR, 0.16),
    ("flares", T_BAR14 + 3 * BAR + 2 * Q, 0.16),
    ("total", T_BAR14 + 4 * BAR, 0.24),            # rule2 + TOTAL together
    ("slogan1", T_BAR14 + 4 * BAR + E, 0.18),
    ("slogan2", T_BAR14 + 4 * BAR + 2 * E, 0.18),
    ("rule3", T_BAR14 + 4 * BAR + 4 * E, 0.14),
    ("barcode", T_BAR14 + 4 * BAR + 5 * E, 0.28),
    ("url", T_BAR14 + 4 * BAR + 6 * E, 0.16),
]
T_TEAR = T_BAR14 + 5 * BAR          # bar 19 downbeat = 24.0

# dot ticks for the gag rows: (row, [times]); the "0" stamps: (row, time)
dots_training = [bar(3) + k * S16 for k in range(1, 9)]
dots_tracking = [T_BAR12 + k * E for k in range(1, 9)]
t_flares = T_BAR14 + 3 * BAR + 2 * Q
dots_flares = [t_flares + k * S16 for k in range(1, 4)]
DOTS = [("training", dots_training), ("tracking", dots_tracking), ("flares", dots_flares)]
STAMPS = [("training", T_STAB1), ("tracking", T_ZERO2), ("flares", t_flares + Q)]

# ---------------------------------------------------------------- camera
ZERO_X = CONTENT_X + 32 * CH + 0.3 * 58 - PW / 2   # world x of the double-size zero centre
ROW_CY = -GAP - RH / 2                         # world y of a freshly emerged row centre
ZERO_CY = ROW_CY - 8                           # the double-size zero sits a little higher
LIFT = 110
paper_final = paper_top_for("url")
REC_CY = paper_final - LIFT + L / 2

# key: (time, dur, ease, s, Fx, Fy, Cx, Cy)
S_CLOSE = 1.70                                  # default: receipt ~73% of the frame width
NEWEST = (960, 580)                             # screen anchor of the freshly printed row
T_TOTAL = T_BAR14 + 4 * BAR                     # bar 18 downbeat
CAM = [
    (0.0, 0.0, "none", 1.45, 0, -200, 960, 560),                       # header: whole receipt (<= 1 s)
    (1.00, 0.40, "power3.inOut", S_CLOSE, 0, ROW_CY, *NEWEST),          # close on the newest row
    (1.40, T_STAB1 + 0.36 - 1.40 - 0.05, "sine.inOut", 1.76, 14, ROW_CY, *NEWEST),
    (T_STAB1 + 0.36, 0.09, "power4.out", 4.20, ZERO_X - 190 / 4.2, ZERO_CY, 960, 500),
    (T_STAB1 + 0.45, T_HIT1 - T_STAB1 - 0.45, "sine.inOut", 4.40, ZERO_X - 190 / 4.4, ZERO_CY, 960, 500),
    (T_HIT1, 0.13, "power3.out", S_CLOSE, 0, ROW_CY, *NEWEST),
    (T_BAR12 + 0.70, 2.00, "sine.inOut", 1.85, ZERO_X - 260 / 1.85, ZERO_CY, 960, 520),
    (T_ZERO2 + 0.15, 0.08, "power4.out", 4.60, ZERO_X - 190 / 4.6, ZERO_CY, 960, 500),
    (T_ZERO2 + 0.23, T_HIT2 - T_ZERO2 - 0.23, "sine.inOut", 4.75, ZERO_X - 190 / 4.75, ZERO_CY, 960, 500),
    (T_HIT2, 0.14, "power3.out", S_CLOSE, 0, ROW_CY, *NEWEST),
    (T_HIT2 + 0.2, t_flares + Q - T_HIT2 - 0.2, "sine.inOut", 1.78, -16, ROW_CY, *NEWEST),
    (t_flares + Q + 0.03, 0.08, "power4.out", 2.30, 0, ZERO_CY, 960, 540),       # "Lens flares ... 0"
    (T_TOTAL, 0.10, "power4.out", 2.10, 0, ROW_CY, 960, 700),                     # TOTAL punch-in on the downbeat
    (T_TOTAL + 4 * E, 0.50, "sine.inOut", 1.72, 0, -130, 960, 560),              # barcode + chuk.chat, held close
    (T_TEAR + 0.05, 0.80, "power2.out", 1.62, 0, -130 - LIFT - 20, 960, 560),    # follow the torn receipt up
    (T_TEAR + 0.90, 0.50, "power3.inOut", 0.60, 0, REC_CY, 960, 540),            # pull back: whole receipt (<= 1.2 s)
]


def cam_xy(s, fx, fy, cx, cy):
    return round(cx - s * fx, 2), round(cy - s * fy, 2)


cam_keys = []
for (t, d, ease, s, fx, fy, cx, cy) in CAM:
    x, yy = cam_xy(s, fx, fy, cx, cy)
    cam_keys.append(dict(t=round(t, 3), d=round(d, 3), ease=ease, s=s, x=x, y=yy))

feed_keys = [dict(t=round(t, 3), d=d, y=paper_top_for(rid), row=rid) for rid, t, d in FEEDS]

PLAN = dict(
    dur=DUR, L=L, PW=PW, initialTop=paper_top_for("leader"), feeds=feed_keys, cam=cam_keys,
    dots={rid: [round(t, 3) for t in ts] for rid, ts in DOTS},
    stamps={rid: round(t, 3) for rid, t in STAMPS},
    tear=round(T_TEAR, 3), lift=LIFT,
    tilt=[[0.0, 0.0, "none", -1.0], [0.0, 5.9, "sine.inOut", -2.2], [T_HIT1, 13.1, "none", -1.4],
          [round(T_TOTAL, 3), 0.1, "power4.out", -2.6], [round(T_TOTAL + 4 * E, 3), 0.5, "sine.inOut", -1.8],
          [round(T_TEAR, 3), 0.9, "power2.inOut", 0.0]],
)

# ---------------------------------------------------------------- audio events
audio = []
for k in feed_keys:
    audio.append(["feed", k["t"], k["d"] + 0.04])
for rid, ts in DOTS:
    for t in ts:
        audio.append(["dot", round(t, 3), 0])
for rid, t in STAMPS:
    audio.append(["stamp", round(t, 3), 0])
audio.sort(key=lambda e: e[1])
json.dump(dict(audio=audio, tear=T_TEAR, plan=PLAN), open(os.path.join(ROOT, "_work/receipt_times.json"), "w"), indent=1)

# ---------------------------------------------------------------- markup
def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def zigzag_polygon(w, h, period=24.0, depth=9.0, seed=3):
    rnd = random.Random(seed)
    n = int(round(w / (period / 2)))
    step = w / n
    top, bot = [], []
    for i in range(n + 1):
        x = round(i * step, 1)
        d = depth + rnd.uniform(-2.2, 2.2)
        top.append((x, round(d, 1) if i % 2 == 0 else round(rnd.uniform(0, 1.5), 1)))
    for i in range(n, -1, -1):
        x = round(i * step, 1)
        d = depth + rnd.uniform(-2.2, 2.2)
        bot.append((x, round(h - (d if i % 2 == 0 else rnd.uniform(0, 1.5)), 1)))
    pts = top + bot
    return "polygon(" + ", ".join(f"{x}px {y}px" for x, y in pts) + ")"


def barcode_svg():
    m = 5
    w = BARCODE["widths"]
    total = sum(w) * m
    x = 0
    rects = []
    for i, wd in enumerate(w):
        if i % 2 == 0:
            rects.append(f'<rect x="{x}" y="0" width="{wd * m}" height="96"/>')
        x += wd * m
    return f'<svg class="r-bars" width="{total}" height="96" viewBox="0 0 {total} 96" xmlns="http://www.w3.org/2000/svg" fill="#1F1E1A">{"".join(rects)}</svg>'


rows_html = []
for r in ROWS:
    style = f'top:{r["y"]}px;height:{r["h"]}px;line-height:{r["h"]}px'
    rid = f'r-row-{r["id"]}'
    k = r["kind"]
    if k == "blank":
        inner = ""
    elif k == "logo":
        inner = '<img class="r-logoimg" src="assets/logo-ink.svg" alt="" />'
    elif k in ("center", "left"):
        inner = f'<span class="{r["cls"]}" data-layout-allow-overlap>{esc(r["text"])}</span>'
    elif k == "rule":
        inner = f'<span class="r-ruletxt" data-layout-allow-overlap>{esc(r["text"])}</span>'
    elif k == "right":
        pad = " " * (COLS - len(r["value"]))
        inner = f'<span class="r-grid" data-layout-allow-overlap>{pad}<b class="r-val" data-layout-allow-overlap>{esc(r["value"])}</b></span>'
    elif k == "item":
        label, n, value = row_text(r["label"], r["value"])
        dcls = "r-dots" + (" r-dots-gag" if r.get("gag") else "")
        vcls = "r-val" + (" r-zero" if r.get("gag") else "")
        inner = (f'<span class="r-grid" data-layout-allow-overlap><span class="r-lab" data-layout-allow-overlap>{esc(label)}</span> '
                 f'<span class="{dcls}" id="r-dots-{r["id"]}" data-layout-allow-overlap>{"." * n}</span> '
                 f'<b class="{vcls}" id="r-val-{r["id"]}" data-layout-allow-overlap>{esc(value)}</b></span>')
    elif k == "barcode":
        inner = barcode_svg()
    else:
        raise ValueError(k)
    align = {"center": "center", "logo": "center", "barcode": "center"}.get(k, "left")
    rows_html.append(f'<div class="r-row r-{k}" id="{rid}" style="{style};text-align:{align}">{inner}</div>')

tpl = open(os.path.join(ROOT, "_work/03-receipt.template.html")).read()
html = (tpl.replace("/*PLAN*/", json.dumps(PLAN))
        .replace("<!--ROWS-->", "\n              ".join(rows_html))
        .replace("__L__", str(L))
        .replace("__CLIP__", zigzag_polygon(PW, L))
        .replace("__DUR__", str(DUR))
        .replace("__CX__", f"{CONTENT_X:.1f}"))
out = os.path.join(ROOT, "compositions/frames/03-receipt.html")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w").write(html)
print("wrote", out, "L =", L, "tear at", round(T_TEAR, 3), "rec centre", REC_CY)
for k in feed_keys:
    print(f'  feed {k["row"]:<11} t={k["t"]:7.3f} top={k["y"]}')
