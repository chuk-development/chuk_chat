#!/usr/bin/env python3
"""Generate compositions/frames/NN-*.html for video 02 "Nobody's reading".

One generator so the rebuilt Chuk Chat window, the fonts, the cipher strings
and the shared coordinates are identical in every frame (frame 5 -> 6 -> 7 hand
off the same window). Run from the project root:  python3 _work/build_frames.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "compositions", "frames")
os.makedirs(OUT, exist_ok=True)
ICONS = json.load(open(os.path.join(ROOT, "_work", "icons.json")))

QUESTION = "How do I tell my boss that I am burned out?"
LEAD = "Start with facts, not with blame."
BULLETS = [
    "Ask for 20 minutes at a calm moment.",
    "Say what changed: sleep, focus, sick days.",
    "Bring one clear request, like fewer projects for a month.",
]
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
FPS = 30


def lcg(seed):
    s = seed & 0xFFFFFFFF

    def nxt():
        nonlocal s
        s = (1664525 * s + 1013904223) & 0xFFFFFFFF
        return s

    return nxt


def cipher_of(text, seed):
    r = lcg(seed)
    return "".join(ch if ch.isspace() else B64[r() % len(B64)] for ch in text)


Q_CIPHER = cipher_of(QUESTION, 0x5EC12E7)
LEAD_CIPHER = cipher_of(LEAD, 0x0BADF00D)
BULLET_CIPHERS = [cipher_of(b, 0x1234 + i * 977) for i, b in enumerate(BULLETS)]


def scramble_frames(orig, cipher, seconds, seed, forward=True):
    """Rows for a left-to-right swap orig->cipher (forward) or cipher->orig.

    A 4-glyph churn band rides the edge so the swap reads as live noise.
    Deterministic: fixed seed, rows computed here once.
    """
    r = lcg(seed)
    n = max(2, round(seconds * FPS))
    rows = []
    total = len(orig)
    for k in range(n + 1):
        cut = round(total * k / n)
        chars = []
        for i in range(total):
            src_done = cipher[i] if forward else orig[i]
            src_todo = orig[i] if forward else cipher[i]
            if orig[i].isspace():
                chars.append(orig[i])
            elif i < cut - 4 or k == n:
                chars.append(src_done)
            elif i < cut:
                chars.append(B64[r() % len(B64)])
            else:
                chars.append(src_todo)
        rows.append("".join(chars))
    return rows


def icon(name, cls, stroke_color="currentColor"):
    ic = ICONS[name]
    fill = ic["fill"]
    fill_attr = f' fill="{fill}"' if fill else ""
    return (
        f'<svg class="{cls}" viewBox="{ic["viewBox"]}"{fill_attr} '
        f'xmlns="http://www.w3.org/2000/svg" aria-hidden="true">{ic["inner"]}</svg>'
    )


FONTS = """
@font-face{font-family:"Chuk Chat Mono";src:url("assets/fonts/jetbrains-mono-latin-wght.woff2") format("woff2");font-weight:100 800;font-display:block;}
@font-face{font-family:"Arimo";src:url("assets/fonts/Arimo-wght.ttf") format("truetype");font-weight:400 700;font-style:normal;font-display:block;}
@font-face{font-family:"Ubuntu";src:url("assets/fonts/Ubuntu-wdth-wght.ttf") format("truetype");font-weight:300 800;font-style:normal;font-display:block;}
"""

GSAP = '<script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>'

BASE_CSS = """
#root{position:absolute;inset:0;overflow:hidden;font-family:"Arimo",sans-serif;color:#26251F;}
#root *{box-sizing:border-box;}
.bg{position:absolute;inset:0;}
.stage{position:absolute;inset:0;}
"""

# ---------------------------------------------------------------- night world
NIGHT_CSS = """
.bg.night{background:radial-gradient(ellipse at 50% 120%, rgba(90,110,190,0.35), transparent 60%),linear-gradient(180deg,#0A0F1F 0%,#131A33 55%,#1D2444 100%);}
.stars{position:absolute;inset:0;background-image:
 radial-gradient(1.8px 1.8px at 6% 14%, #fff 50%, transparent 52%),
 radial-gradient(1.4px 1.4px at 14% 38%, #fff 50%, transparent 52%),
 radial-gradient(2px 2px at 22% 8%, #fff 50%, transparent 52%),
 radial-gradient(1.4px 1.4px at 39% 6%, #fff 50%, transparent 52%),
 radial-gradient(1.8px 1.8px at 55% 5%, #fff 50%, transparent 52%),
 radial-gradient(1.4px 1.4px at 71% 9%, #fff 50%, transparent 52%),
 radial-gradient(1.8px 1.8px at 93% 30%, #fff 50%, transparent 52%),
 radial-gradient(1.2px 1.2px at 4% 62%, #fff 50%, transparent 52%),
 radial-gradient(1.4px 1.4px at 96% 66%, #fff 50%, transparent 52%),
 radial-gradient(1.2px 1.2px at 9% 88%, #fff 50%, transparent 52%),
 radial-gradient(1.2px 1.2px at 90% 92%, #fff 50%, transparent 52%);opacity:.7;}
.moon{position:absolute;left:1604px;top:52px;width:128px;height:128px;border-radius:50%;background:radial-gradient(circle at 36% 34%, #FFF7E4, #EDE1C4 58%, #D2C6A8);}
"""

NIGHT_BG = '<div class="bg night clip" data-start="0" data-duration="__DUR__" data-track-index="0"><div class="stars"></div><div class="moon"></div></div>'

# ------------------------------------------------------- the Chuk Chat window
# Logical 1000 x 580 (the site's desktop mock is 1000 x 720), zoom 1.4 so
# 16 px chat text reads 22.4 px. Hero wrapper sits at (260, 134).
WIN_LEFT, WIN_TOP, WIN_ZOOM = 260, 134, 1.4
WIN_W, WIN_H = 1000, 580
SPLIT_LEFT, SPLIT_TOP, SPLIT_SCALE = 80, 317, 0.55

APP_CSS = """
.win{position:absolute;left:260px;top:134px;width:1400px;height:812px;transform-origin:0 0;}
.app{--fg:#E8E4D8;--fg85:rgba(232,228,216,.85);--fg70:rgba(232,228,216,.7);--fg55:rgba(232,228,216,.55);--fg30:rgba(232,228,216,.3);--fg15:rgba(232,228,216,.15);--bg:#262624;--lift:#333330;--acc:#D97757;--bubble:#B6674D;
 position:relative;display:flex;width:1000px;height:580px;zoom:1.4;overflow:hidden;border-radius:18px;background:var(--bg);color:var(--fg);
 font-family:"Ubuntu",sans-serif;font-size:14px;line-height:1.4;text-align:left;
 box-shadow:0 50px 110px -30px rgba(12,10,6,.6),0 0 0 1px rgba(255,255,255,.07);}
.app svg{flex:none;}
.z12{width:10.4px;height:10.4px;}.z15{width:13px;height:13px;}.z16{width:13.8px;height:13.8px;}.z18{width:15.5px;height:15.5px;}
.z22{width:18.9px;height:18.9px;}.z24{width:20.6px;height:20.6px;}.z26{width:22.4px;height:22.4px;}.i18{width:18px;height:18px;}
.a-menu{position:absolute;left:7px;top:20px;z-index:3;width:48px;height:40px;display:flex;align-items:center;justify-content:center;color:var(--fg);}
.a-rail{position:absolute;left:16px;top:70px;z-index:3;display:flex;flex-direction:column;gap:15px;color:var(--acc);}
.a-rail>span{width:30px;height:30px;display:flex;align-items:center;justify-content:center;}
.a-chat{position:relative;flex:1 1 0;min-width:0;display:flex;flex-direction:column;margin-left:48px;}
.a-thread{flex:1;min-height:0;display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden;-webkit-mask-image:linear-gradient(180deg,transparent 0,#000 70px);mask-image:linear-gradient(180deg,transparent 0,#000 70px);}
.a-col{width:760px;margin:0 auto;padding:20px 16px 22px;}
.a-foot{position:relative;z-index:2;flex:none;display:flex;flex-direction:column;align-items:center;padding:0 0 16px;}
.a-composer{position:relative;display:flex;flex-direction:column;justify-content:space-between;width:760px;height:135px;padding:14px;border:2px solid #615F5A;border-radius:30px;background:var(--bg);}
.a-field{min-height:40px;padding:2px 58px 0 4px;font-size:16px;font-weight:500;line-height:1.4;color:var(--fg);white-space:pre;}
.a-field.ph{color:rgba(232,228,216,.8);font-weight:600;}
.a-send{position:absolute;top:14px;right:14px;width:44px;height:36px;border-radius:20px;background:var(--acc);color:#fff;display:flex;align-items:center;justify-content:center;}
.a-row{display:flex;align-items:center;gap:8px;}
.a-grow{flex:1;order:2;}
.a-btn{width:44px;height:36px;border:2px solid #615F5A;border-radius:18px;display:inline-flex;align-items:center;justify-content:center;color:var(--fg);}
.a-plus{order:1;}.a-mic{order:4;}
.a-pill{order:3;height:36px;padding:0 9px;border:2px solid #615F5A;border-radius:18px;display:inline-flex;align-items:center;gap:5px;font-size:12px;font-weight:600;color:var(--fg);white-space:nowrap;}
.a-dn{margin-left:-3px;color:var(--fg70);}
.a-disc{margin:8px 0 0;height:15px;font-size:11px;line-height:15px;color:var(--fg70);text-align:center;}
.a-user{display:flex;justify-content:flex-end;margin-top:10px;}
.a-bubble{max-width:80%;height:44px;padding:10px 14px;border:1px solid var(--fg30);border-radius:16px 16px 5px 16px;background:var(--bubble);color:var(--fg);font-family:"Chuk Chat Mono",monospace;font-size:16px;font-weight:400;line-height:22px;white-space:pre;}
.a-tl{margin-top:14px;height:25px;}
.a-tl-head{display:inline-flex;align-items:center;gap:4px;margin:0;padding:4px 2px;height:25px;font-size:12px;font-weight:500;color:var(--fg55);}
.a-ai{margin-top:8px;font-family:"Chuk Chat Mono",monospace;font-size:16px;font-weight:400;line-height:23px;color:var(--fg);}
.a-ai p{margin:0 0 8px;height:23px;white-space:pre;}
.a-ai strong{font-weight:700;}
.a-ai ul{list-style:none;margin:0 0 8px;padding-left:32px;}
.a-ai li{position:relative;margin-bottom:4px;height:23px;white-space:pre;}
.a-ai li::before{content:"";position:absolute;left:-18px;top:.6em;width:6px;height:6px;border-radius:50%;background:currentColor;}
.a-acts{display:flex;align-items:center;gap:6px;margin-top:4px;height:32px;}
.a-act{display:inline-flex;align-items:center;border:1px solid var(--fg15);border-radius:100px;background:var(--lift);padding:4px 8px;}
.a-act>span{width:34px;height:22px;display:inline-flex;align-items:center;justify-content:center;color:var(--fg);}
"""


def app_window(thread_html, field_text, field_ph=False):
    field_cls = "a-field ph" if field_ph else "a-field"
    return f"""
<div class="win"><div class="app">
  <span class="a-menu">{icon('menu01','z24')}</span>
  <span class="a-rail"><span>{icon('pencil-edit02','z24')}</span><span>{icon('image01','z24')}</span></span>
  <div class="a-chat">
    <div class="a-thread"><div class="a-col">{thread_html}</div></div>
    <div class="a-foot">
      <div class="a-composer">
        <div class="{field_cls}">{field_text}</div>
        <div class="a-row">
          <span class="a-btn a-plus">{icon('plus-sign','z24')}</span>
          <span class="a-grow"></span>
          <span class="a-pill">{icon('flash','z15')}<b>Fast</b>{icon('arrow-down01','z12 a-dn')}</span>
          <span class="a-btn a-mic">{icon('mic02','z22')}</span>
          <span class="a-send">{icon('send-horizontal','z26')}</span>
        </div>
      </div>
      <p class="a-disc">You're chatting with an AI/LLM — it can be wrong. Check key info.</p>
    </div>
  </div>
</div></div>"""


def user_bubble(text):
    return f'<div class="a-user"><p class="a-bubble">{text}</p></div>'


# Send button centre in page px (logical 866, 439.6 inside the 1000 x 580 window)
SEND_X = WIN_LEFT + 866 * WIN_ZOOM
SEND_Y = WIN_TOP + 439.6 * WIN_ZOOM

CURSOR_CSS = """
.cur{position:absolute;left:0;top:0;width:44px;height:44px;z-index:50;}
.cur svg{width:44px;height:44px;display:block;}
.cur .ring{position:absolute;left:-6px;top:-6px;width:22px;height:22px;border-radius:999px;border:2px solid currentColor;opacity:0;}
.cur.light{color:rgba(255,255,255,.9);filter:drop-shadow(0 8px 18px rgba(0,0,0,.28));}
.cur.light path{fill:#ffffff;stroke:rgba(0,0,0,.45);}
.cur.dark{color:rgba(24,24,27,.75);filter:drop-shadow(0 6px 14px rgba(0,0,0,.18));}
.cur.dark path{fill:#18181b;stroke:rgba(255,255,255,.85);}
"""


def cursor(tone):
    return (
        f'<div class="cur {tone}"><div class="ring"></div><svg viewBox="0 0 24 24">'
        '<path d="M3 2.8 20.6 14 12.8 15.5 9 22 3 2.8Z" stroke-width="1.4"/></svg></div>'
    )


def template(fid, dur, css, body, js):
    body = body.replace("__DUR__", f"{dur}").replace('<div class="bg ', f'<div id="f{fid}-bg" class="bg ', 1)
    return f"""<template>
<style>
{FONTS}
{BASE_CSS}
{css}
</style>
<div id="root" data-composition-id="{fid}" data-width="1920" data-height="1080" data-duration="{dur}">
{body}
</div>
{GSAP}
<script>
(function () {{
  var root = document.getElementById("root");
  var q = function (s) {{ return root.querySelector(s); }};
  var qa = function (s) {{ return Array.prototype.slice.call(root.querySelectorAll(s)); }};
  var tl = gsap.timeline({{ paused: true }});
{js}
  tl.seek(0);
  window.__timelines = window.__timelines || {{}};
  window.__timelines["{fid}"] = tl;
}})();
</script>
</template>
"""


def write(fid, html):
    path = os.path.join(OUT, f"{fid}.html")
    with open(path, "w") as fh:
        fh.write(html)
    print("wrote", os.path.relpath(path, ROOT))


def js_rows(rows):
    return json.dumps(rows, ensure_ascii=False)


# =================================================================== F1 hook
def f01():
    fid, dur = "01-hook", 4.264
    css = """
.bg.paper{background:#FDFBF7;}
.head{position:absolute;left:0;right:0;top:238px;text-align:center;font-size:92px;line-height:1.06;letter-spacing:-0.04em;font-weight:500;color:#26251F;}
.head .ln{display:block;}
.head .w{display:inline-block;}
.box{position:absolute;left:250px;top:470px;width:1420px;height:140px;background:#FFFFFF;border:1px solid #E6E1D5;border-radius:26px;
 box-shadow:0 1px 3px rgba(38,37,31,.06),0 28px 70px -34px rgba(38,37,31,.30);display:flex;align-items:center;padding:0 52px;}
.typed{font-size:56px;letter-spacing:-0.02em;color:#26251F;white-space:pre;line-height:1;}
.caret{display:inline-block;width:4px;height:64px;margin-left:6px;background:#26251F;border-radius:2px;}
"""
    words1 = "Everything you type into an AI".split(" ")
    words2 = "goes somewhere.".split(" ")
    ln = lambda ws: " ".join(f'<span class="w">{w}</span>' for w in ws)
    body = f"""
<div class="bg paper clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage">
  <div class="head"><span class="ln">{ln(words1)}</span><span class="ln">{ln(words2)}</span></div>
  <div class="box"><span class="typed"></span><span class="caret"></span></div>
</div>"""
    # typing schedule: first glyph at frame 0, a human-ish uneven rhythm
    jitter = [0, 0.012, -0.006, 0.018, -0.01, 0.004, 0.02, -0.004, 0.008, -0.012]
    sched = []
    t = 0.0
    for i in range(1, len(QUESTION) + 1):
        sched.append([round(max(0.0, t), 3), QUESTION[:i]])
        step = 0.034 + jitter[i % len(jitter)]
        if QUESTION[i - 1] == " ":
            step += 0.018
        t += step
    type_end = sched[-1][0]
    js = f"""
  var typed = q(".typed"), caret = q(".caret"), box = q(".box");
  var sched = {json.dumps(sched)};
  tl.set(typed, {{ textContent: "" }}, 0);
  sched.forEach(function (s) {{ tl.set(typed, {{ textContent: s[1] }}, s[0]); }});
  // caret: solid while typing, then a finite blink
  var tEnd = {type_end};
  [0.55, 1.08, 1.61, 2.14, 2.67].forEach(function (d, i) {{
    tl.set(caret, {{ opacity: i % 2 === 0 ? 0 : 1 }}, tEnd + d);
  }});
  tl.fromTo(box, {{ scale: 0.985 }}, {{ scale: 1, duration: 0.6, ease: "power3.out" }}, 0);
  // strong beat 1.737: the box drops, the headline rises word by word
  tl.to(box, {{ y: 150, duration: 0.8, ease: "power3.inOut" }}, 1.70);
  qa(".head .w").forEach(function (w, i) {{
    tl.fromTo(w, {{ y: 46, opacity: 0 }}, {{ y: 0, opacity: 1, duration: 0.7, ease: "expo.out" }}, 1.78 + i * 0.075);
  }});
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================ neutral world
NEUTRAL_CSS = """
.bg.cold{background:linear-gradient(180deg,#ECEEF1 0%,#E2E5E9 100%);}
.lab{position:absolute;font-family:"Chuk Chat Mono",monospace;font-size:26px;font-weight:500;letter-spacing:0.02em;color:#5A616B;}
"""


# ================================================================ F2 trip
def f02():
    fid, dur = "02-trip", 6.631
    css = NEUTRAL_CSS + CURSOR_CSS + """
.nw{position:absolute;left:80px;top:250px;width:640px;height:620px;background:#F7F8FA;border:1px solid #CDD2D8;border-radius:18px;overflow:hidden;
 box-shadow:0 30px 70px -40px rgba(20,24,30,.35);}
.nw-top{position:absolute;left:0;right:0;top:0;height:52px;border-bottom:1px solid #DDE1E6;display:flex;align-items:center;gap:9px;padding-left:22px;}
.nw-top i{width:13px;height:13px;border-radius:50%;background:#C9CED5;display:block;}
.nw-side{position:absolute;left:0;top:52px;bottom:0;width:140px;background:#EEF0F3;border-right:1px solid #DDE1E6;}
.nw-side b{position:absolute;left:22px;height:14px;border-radius:7px;background:#D5D9DF;display:block;}
.nw-main{position:absolute;left:140px;top:52px;right:0;bottom:0;}
.nb{position:absolute;right:20px;top:80px;width:360px;padding:16px 20px;border:1px solid transparent;background:#DDE1E6;border-radius:18px 18px 5px 18px;font-size:24px;line-height:32px;color:#2F343B;}
.ncomp{position:absolute;left:20px;right:20px;bottom:20px;height:136px;background:#FFFFFF;border:1px solid #C9CED5;border-radius:14px;}
.ncomp .tx{position:absolute;left:20px;top:16px;right:20px;font-size:24px;line-height:32px;color:#2F343B;}
.nsend{position:absolute;right:14px;bottom:14px;width:100px;height:46px;border-radius:10px;background:#5B616A;color:#FFFFFF;font-size:22px;font-weight:700;display:flex;align-items:center;justify-content:center;}
.rack{position:absolute;left:1400px;top:300px;width:360px;height:532px;background:#3A3F47;border-radius:18px;box-shadow:0 36px 80px -40px rgba(20,24,30,.55);}
.unit{position:absolute;left:24px;right:24px;height:84px;background:#454B54;border-radius:10px;}
.unit .vent{position:absolute;left:22px;height:6px;width:150px;border-radius:3px;background:#353A41;}
.unit .led{position:absolute;top:36px;width:12px;height:12px;border-radius:50%;background:#6B737E;}
.unit .slot{position:absolute;left:22px;right:22px;top:37px;height:10px;border-radius:5px;background:#1E2126;}
.dot{position:absolute;top:562px;width:8px;height:8px;border-radius:50%;background:#B3BAC3;}
.cam{position:absolute;inset:0;transform-origin:0 0;}
.card{position:absolute;left:0;top:0;width:420px;padding:16px 20px;background:#FFFFFF;border:1px solid #CDD2D8;border-radius:18px 18px 5px 18px;font-size:28px;line-height:37px;color:#2F343B;
 box-shadow:0 18px 40px -22px rgba(20,24,30,.45);transform-origin:0 0;}
"""
    side = "".join(
        f'<b style="top:{30 + i * 40}px;width:{w}px;{"background:#C6CBD2;" if i == 0 else ""}"></b>'
        for i, w in enumerate([96, 84, 100, 70, 90])
    )
    units = ""
    for i in range(5):
        top = 24 + i * 100
        inner = ""
        if i == 2:
            inner = '<span class="slot"></span>'
        else:
            inner = "".join(f'<span class="vent" style="top:{22 + v * 16}px"></span>' for v in range(3))
            inner += "".join(
                f'<span class="led" style="left:{230 + L * 22}px"></span>' for L in range(3)
            )
        units += f'<div class="unit" style="top:{top}px">{inner}</div>'
    dots_x = [730 + i * 21 for i in range(32)]
    dots = "".join(f'<span class="dot" style="left:{x - 4}px"></span>' for x in dots_x)
    body = f"""
<div class="bg cold clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage">
  <div class="cam">
  <div class="lab lab-l" style="left:80px;top:196px">Your device</div>
  <div class="lab lab-r" style="left:1400px;top:246px">Their server</div>
  <div class="nw">
    <div class="nw-top"><i></i><i></i><i></i></div>
    <div class="nw-side">{side}</div>
    <div class="nw-main">
      <div class="nb">{QUESTION}</div>
      <div class="ncomp"><div class="tx">{QUESTION}</div><div class="nsend">Send</div></div>
    </div>
  </div>
  <div class="dots">{dots}</div>
  <div class="rack">{units}</div>
  <div class="card" data-layout-allow-overlap>{QUESTION}</div>
  {cursor('dark')}
  </div>
</div>"""
    # Send button centre: window (80,250) + main left 140 ... right edge 700-14-50 = 636, y = 870-20-14-23 = 813
    sx, sy = 636, 813
    js = f"""
  var nb = q(".nb"), tx = q(".ncomp .tx"), send = q(".nsend"), card = q(".card"), rack = q(".rack");
  var cur = q(".cur"), ring = q(".cur .ring"), cam = q(".cam");
  // camera: open close on the device (window centre 400,560 -> screen centre), pull back
  // to the split as the card lifts, push into the rack on arrival
  tl.set(cam, {{ x: 960 - 400 * 1.45, y: 540 - 560 * 1.45, scale: 1.45 }}, 0);
  tl.to(cam, {{ x: 0, y: 0, scale: 1, duration: 0.95, ease: "power3.inOut" }}, 1.72);
  tl.to(cam, {{ x: 960 - 1580 * 1.3, y: 540 - 566 * 1.3, scale: 1.3, duration: 0.6, ease: "power3.inOut" }}, 4.5);
  // rack + labels arrive, the dotted line draws on
  tl.fromTo(q(".lab-l"), {{ opacity: 0, y: 12 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, 0.05);
  tl.fromTo(rack, {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }}, 0.22);
  tl.fromTo(q(".lab-r"), {{ opacity: 0, y: 12 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, 0.4);
  var dots = qa(".dot");
  dots.forEach(function (d, i) {{
    tl.fromTo(d, {{ scale: 0, opacity: 0 }}, {{ scale: 1, opacity: 1, duration: 0.18, ease: "power2.out" }}, 0.55 + i * 0.022);
  }});
  // the bubble is not in the thread yet
  tl.fromTo(nb, {{ opacity: 0 }}, {{ opacity: 0, duration: 0.01 }}, 0);
  // pointer to Send, click on the phrase downbeat (1.578)
  tl.fromTo(cur, {{ x: 760, y: 950, opacity: 0 }}, {{ x: 760, y: 950, opacity: 1, duration: 0.2 }}, 0.55);
  tl.to(cur, {{ x: {sx - 5}, y: {sy - 5}, duration: 0.85, ease: "power3.inOut" }}, 0.7);
  tl.to(send, {{ backgroundColor: "#3F444B", duration: 0.08 }}, 1.578);
  tl.to(send, {{ backgroundColor: "#5B616A", duration: 0.25 }}, 1.70);
  tl.fromTo(ring, {{ opacity: 0.85, scale: 0.2 }}, {{ opacity: 0, scale: 2.4, duration: 0.45, ease: "power2.out" }}, 1.578);
  tl.set(tx, {{ textContent: "" }}, 1.61);
  tl.fromTo(nb, {{ opacity: 0, y: 16 }}, {{ opacity: 1, y: 0, duration: 0.35, ease: "power3.out", immediateRender: false }}, 1.62);
  tl.to(cur, {{ x: 760, y: 960, opacity: 0, duration: 0.5, ease: "power2.in" }}, 1.85);
  // a readable copy lifts off the bubble and rides the line (bubble at 340,382)
  tl.fromTo(card, {{ x: 340, y: 382, scale: 0.857, opacity: 0 }}, {{ x: 340, y: 382, scale: 0.857, opacity: 1, duration: 0.12 }}, 1.80);
  tl.to(card, {{ x: 720, y: 446, scale: 1, rotation: -1.5, duration: 0.6, ease: "power2.inOut" }}, 1.92);
  tl.to(card, {{ x: 980, rotation: 0, duration: 2.35, ease: "none" }}, 2.52);
  tl.to(card, {{ x: 1555, y: 560, scale: 0.12, opacity: 0, duration: 0.2, ease: "power2.in" }}, 4.87);
  // ticks light as the card's centre passes (centre x = left + 180)
  dots.forEach(function (d, i) {{
    var x = {json.dumps(dots_x)}[i], t;
    if (x < 930) t = 2.0 + (x - 730) / (930 - 730) * 0.52;
    else if (x <= 1190) t = 2.52 + (x - 930) / (1190 - 930) * 2.35;
    else t = 4.87 + (x - 1190) / (1390 - 1190) * 0.18;
    tl.to(d, {{ backgroundColor: "#3A3F47", scale: 1.35, duration: 0.08 }}, t);
  }});
  // arrival on 5.052, then LEDs blink with the drum fill
  var leds = qa(".led");
  tl.fromTo(q(".slot"), {{ backgroundColor: "#1E2126" }}, {{ backgroundColor: "#AEB5BE", duration: 0.06 }}, 5.05);
  tl.to(q(".slot"), {{ backgroundColor: "#1E2126", duration: 0.4 }}, 5.14);
  [5.368, 5.684, 6.0, 6.315].forEach(function (t, k) {{
    leds.forEach(function (l, i) {{
      var on = (i + k) % 3 === 0;
      tl.set(l, {{ backgroundColor: on ? "#E6E9ED" : "#6B737E" }}, t);
    }});
  }});
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================== F3 stamps
OTHER_QUESTIONS = [
    "Is this mole something to worry about?",
    "How do I pay off my credit card debt?",
    "Can my landlord keep my deposit?",
    "Why do I feel tired all the time?",
    "Should I tell my partner about the loan?",
    None,  # our question sits here (row 1, col 1)
    "Is it normal to cry at work?",
    "How do I ask for a raise?",
    "My kid is being bullied. What do I do?",
    "Is my contract even legal?",
    "How do I stop panic attacks?",
    "Can I get fired for being sick?",
]


def record_html(text, meta, cls, stamps=True):
    if isinstance(text, (list, tuple)):
        text = "".join(f'<span style="display:block">{t}</span>' for t in text)
    st = ""
    if stamps:
        st = (
            '<span class="stamp s1">Stored</span>'
            '<span class="stamp s2">Logged</span>'
            '<span class="stamp s3">May be used for training</span>'
        )
    return (
        f'<div class="rec {cls}"><div class="rec-card"><div class="rec-meta">{meta}</div>'
        f'<div class="rec-msg">{text}</div></div>{st}</div>'
    )


def f03():
    fid, dur = "03-stamps", 8.526
    css = NEUTRAL_CSS + """
.rec{position:absolute;left:0;top:0;width:1400px;height:420px;transform-origin:0 0;}
.rec-card{position:absolute;inset:0;background:#F9FAFB;border:1px solid #CDD2D8;border-radius:22px;box-shadow:0 36px 80px -46px rgba(20,24,30,.5);}
.rec-meta{position:absolute;left:56px;top:40px;right:56px;padding-bottom:22px;border-bottom:1px solid #DDE1E6;font-family:"Chuk Chat Mono",monospace;font-size:24px;color:#5A616B;letter-spacing:0.01em;}
.rec-msg{position:absolute;left:56px;top:128px;right:120px;font-size:76px;line-height:1.08;letter-spacing:-0.03em;color:#2F343B;}
.stamp{position:absolute;font-family:"Chuk Chat Mono",monospace;font-weight:800;text-transform:uppercase;letter-spacing:0.06em;font-size:58px;line-height:1;
 color:#A8463C;border:6px solid #A8463C;border-radius:14px;padding:12px 28px;background:rgba(168,70,60,.05);white-space:nowrap;transform-origin:50% 50%;mix-blend-mode:multiply;}
.stamp.s1{left:1010px;top:-40px;}
.stamp.s2{left:60px;top:318px;}
.stamp.s3{left:410px;top:356px;}
.hero{left:260px;top:290px;}
.headline{position:absolute;left:0;right:0;top:170px;text-align:center;font-size:104px;line-height:1;letter-spacing:-0.04em;font-weight:500;color:#2F343B;}
"""
    cell_w, cell_h, gap_x, gap_y = 400, 120, 28, 30
    scale = cell_w / 1400
    grid_left = (1920 - (4 * cell_w + 3 * gap_x)) / 2
    grid_top = 378
    cells = []
    for idx in range(12):
        r, c = divmod(idx, 4)
        cells.append((grid_left + c * (cell_w + gap_x), grid_top + r * (cell_h + gap_y)))
    others = ""
    stamp_rot = [-8, 6, -3]
    for idx, qtext in enumerate(OTHER_QUESTIONS):
        if qtext is None:
            continue
        x, y = cells[idx]
        others += (
            f'<div class="tile" style="position:absolute;left:{x:.1f}px;top:{y:.1f}px;width:{cell_w}px;height:{cell_h}px;">'
            + record_html(qtext, f"log · session {7101 + idx * 37:x} · 14:{idx + 10:02d}", "mini").replace(
                'class="rec mini"', f'class="rec mini" style="transform:scale({scale:.5f})"'
            )
            + "</div>"
        )
    hero = record_html(["How do I tell my boss", "that I am burned out?"], "log · 2026-09-27 14:02:17 · session 7f3a91", "hero")
    body = f"""
<div class="bg cold clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage">
  <div class="lab lab-top" style="left:110px;top:96px">Their server</div>
  <div class="others">{others}</div>
  {hero}
  <div class="headline">Out of your hands.</div>
</div>"""
    ox, oy = cells[5]
    js = f"""
  var hero = q(".rec.hero");
  var st = qa(".rec.hero .stamp");
  var rots = {json.dumps(stamp_rot)};
  // mini tiles: stamps already on, hidden until the pull-back
  qa(".rec.mini .stamp").forEach(function (s, i) {{ gsap.set(s, {{ rotation: rots[i % 3] }}); }});
  tl.fromTo(hero, {{ scale: 1.04, opacity: 0.4 }}, {{ scale: 1, opacity: 1, duration: 0.45, ease: "expo.out" }}, 0);
  tl.fromTo(q(".lab-top"), {{ opacity: 0 }}, {{ opacity: 1, duration: 0.4 }}, 0.1);
  // three slams on the strong beats
  [0.947, 3.474, 5.053].forEach(function (t, i) {{
    tl.fromTo(st[i], {{ scale: 2.3, opacity: 0, rotation: rots[i] }}, {{ scale: 1, opacity: 0.94, rotation: rots[i], duration: 0.13, ease: "power4.in" }}, t - 0.13);
    tl.fromTo(hero, {{ y: 0 }}, {{ y: 10, duration: 0.05, ease: "power1.out", immediateRender: false }}, t);
    tl.to(hero, {{ y: 0, duration: 0.3, ease: "power2.out" }}, t + 0.05);
  }});
  // slow creep while it is being stamped (tension)
  tl.fromTo(q(".stage"), {{ scale: 1 }}, {{ scale: 1.035, duration: 5.9, ease: "none", transformOrigin: "50% 50%" }}, 0);
  // zoom-out: the record becomes one tile of the archive
  tl.to(q(".stage"), {{ scale: 1, duration: 1.1, ease: "power3.inOut" }}, 5.95);
  tl.to(hero, {{ x: {ox - 260:.1f}, y: {oy - 290:.1f}, scale: {scale:.5f}, duration: 1.1, ease: "power3.inOut" }}, 5.95);
  qa(".tile").forEach(function (t, i) {{
    tl.fromTo(t, {{ opacity: 0, y: 18 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, 6.35 + i * 0.045);
  }});
  tl.fromTo(q(".headline"), {{ opacity: 0, y: 34 }}, {{ opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }}, 6.9);
"""
    write(fid, template(fid, dur, css, body, js))


# ================================================================== F4 or
def f04():
    fid, dur = "04-or", 1.579
    css = """
.bg.paper{background:#FDFBF7;}
.or{position:absolute;left:0;right:0;top:0;bottom:0;display:flex;align-items:center;justify-content:center;font-size:230px;line-height:1;letter-spacing:-0.04em;font-weight:500;color:#26251F;}
.or span{display:inline-block;}
"""
    body = """
<div class="bg paper clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage"><div class="or"><span class="o">Or</span><span class="d">.</span><span class="d">.</span><span class="d">.</span></div></div>"""
    js = """
  tl.fromTo(q(".o"), { y: 40, opacity: 0 }, { y: 0, opacity: 1, duration: 0.5, ease: "expo.out" }, 0.0);
  qa(".d").forEach(function (d, i) {
    tl.fromTo(d, { y: 14, opacity: 0 }, { y: 0, opacity: 1, duration: 0.22, ease: "power3.out" }, 0.36 + i * 0.32);
  });
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================ F5 encrypt
HEAD_CSS = """
.nh{position:absolute;left:960px;top:388px;width:880px;font-size:88px;line-height:1.06;letter-spacing:-0.035em;font-weight:500;color:#F6F3EC;}
.nh .ln{display:block;}
"""
HEAD_HTML = '<div class="nh"><span class="ln">Encrypted on</span><span class="ln">your device,</span><span class="ln">before we store it.</span></div>'


def f05():
    fid, dur = "05-encrypt", 5.053
    css = NIGHT_CSS + APP_CSS + CURSOR_CSS + HEAD_CSS + ".cam{position:absolute;inset:0;transform-origin:0 0;}"
    thread = user_bubble(QUESTION)
    body = f"""
{NIGHT_BG}
<div class="stage">
  <div class="cam">
  {app_window(thread, QUESTION)}
  {cursor('light')}
  </div>
  {HEAD_HTML}
</div>"""
    rows = scramble_frames(QUESTION, Q_CIPHER, 1.1, 0xC0FFEE, forward=True)
    js = f"""
  var win = q(".win"), bub = q(".a-bubble"), field = q(".a-field"), sendB = q(".a-send");
  var cur = q(".cur"), ring = q(".cur .ring"), cam = q(".cam");
  // release downbeat: the window lands
  tl.fromTo(win, {{ y: 80, scale: 0.94, opacity: 0.2 }}, {{ y: 0, scale: 1, opacity: 1, duration: 0.8, ease: "expo.out" }}, 0);
  tl.fromTo(q(".a-user"), {{ opacity: 0 }}, {{ opacity: 0, duration: 0.01 }}, 0);
  // pointer to the coral send button, click on 0.948
  tl.fromTo(cur, {{ x: 1560, y: 1090, opacity: 0 }}, {{ x: 1560, y: 1090, opacity: 1, duration: 0.15 }}, 0.2);
  tl.to(cur, {{ x: {SEND_X - 5:.1f}, y: {SEND_Y - 5:.1f}, duration: 0.62, ease: "power3.inOut" }}, 0.28);
  tl.fromTo(ring, {{ opacity: 0.85, scale: 0.2 }}, {{ opacity: 0, scale: 2.4, duration: 0.45, ease: "power2.out" }}, 0.948);
  tl.fromTo(sendB, {{ scale: 1 }}, {{ scale: 0.9, duration: 0.07, ease: "power2.out", yoyo: true, repeat: 1 }}, 0.948);
  tl.set(field, {{ textContent: "Ask me anything !", color: "rgba(232,228,216,.8)", fontWeight: 600 }}, 0.98);
  tl.fromTo(q(".a-user"), {{ opacity: 0, y: 14 }}, {{ opacity: 1, y: 0, duration: 0.35, ease: "power3.out", immediateRender: false }}, 0.99);
  tl.to(cur, {{ x: 1720, y: 1100, opacity: 0, duration: 0.55, ease: "power2.in" }}, 1.25);
  // on the device, before it leaves: the text turns into ciphertext
  var rows = {js_rows(rows)};
  // camera pushes in on the bubble + composer (page 1044,722 -> screen centre)
  tl.fromTo(cam, {{ x: 0, y: 0, scale: 1 }}, {{ x: 960 - 1044 * 1.5, y: 540 - 722 * 1.5, scale: 1.5, duration: 0.8, ease: "power3.inOut" }}, 1.0);
  rows.forEach(function (r, i) {{ tl.set(bub, {{ textContent: r }}, 1.62 + i / 30); }});
  tl.to(bub, {{ backgroundColor: "#33343C", color: "#9DA6C8", borderColor: "rgba(160,180,255,.22)", duration: 1.1, ease: "power1.inOut" }}, 1.62);
  tl.to(cam, {{ x: 0, y: 0, scale: 1, duration: 0.85, ease: "power3.inOut" }}, 3.40);
  // strong beat 3.474: the window steps left, the line lands on the right
  tl.to(win, {{ x: {SPLIT_LEFT - WIN_LEFT}, y: {SPLIT_TOP - WIN_TOP}, scale: {SPLIT_SCALE}, duration: 0.85, ease: "power3.inOut" }}, 3.40);
  qa(".nh .ln").forEach(function (l, i) {{
    tl.fromTo(l, {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }}, 3.62 + i * 0.12);
  }});
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================== F6 noise
VAULT_CSS = """
.lab2{position:absolute;font-family:"Chuk Chat Mono",monospace;font-size:26px;font-weight:500;color:#F2C56B;}
.ndot{position:absolute;top:591px;width:8px;height:8px;border-radius:50%;background:rgba(246,243,236,.28);}
.vault{position:absolute;left:1180px;top:318px;width:660px;height:444px;border-radius:24px;background:rgba(14,17,30,.62);border:1px solid rgba(160,180,255,.22);
 box-shadow:0 40px 90px -40px rgba(0,0,0,.6);}
.v-badge{position:absolute;left:36px;top:36px;display:inline-flex;align-items:center;gap:12px;padding:14px 26px;border:1px solid rgba(160,180,255,.32);border-radius:999px;
 background:rgba(14,17,30,.9);color:#DDE4FF;font-family:"Ubuntu",sans-serif;font-size:28px;font-weight:600;}
.v-badge svg{width:28px;height:28px;}
.v-bub{position:absolute;left:36px;right:36px;top:128px;padding:16px 22px;border:1px solid rgba(160,180,255,.22);border-radius:18px 18px 6px 18px;background:#33343C;color:#9DA6C8;
 font-family:"Chuk Chat Mono",monospace;font-size:26px;line-height:36px;word-break:break-all;}
.v-ans{position:absolute;left:36px;right:36px;top:250px;font-family:"Chuk Chat Mono",monospace;font-size:22px;line-height:32px;color:#8791B5;white-space:pre;overflow:hidden;}
.v-note{position:absolute;left:36px;right:36px;top:372px;font-family:"Chuk Chat Mono",monospace;font-size:22px;color:#AEB8DB;}
.ccard{position:absolute;left:0;top:0;width:380px;padding:14px 20px;border:1px solid rgba(160,180,255,.22);border-radius:18px 18px 6px 18px;background:#33343C;color:#9DA6C8;
 font-family:"Chuk Chat Mono",monospace;font-size:24px;line-height:33px;word-break:break-all;box-shadow:0 20px 44px -24px rgba(0,0,0,.7);}
"""


def vault_html():
    ans = "\n".join([LEAD_CIPHER] + BULLET_CIPHERS[:2])
    return f'''<div class="vault">
    <span class="v-badge">{icon('lock','i18')}What our server stores</span>
    <div class="v-bub">{Q_CIPHER}</div>
    <div class="v-ans">{ans}</div>
    <div class="v-note">AES-256-GCM · the key stays on your device</div>
  </div>'''


NDOTS_X = [872 + i * 21 for i in range(15)]


def ndots_html():
    return "".join(f'<span class="ndot" style="left:{x - 4}px"></span>' for x in NDOTS_X)


def f06():
    fid, dur = "06-noise", 5.053
    css = NIGHT_CSS + APP_CSS + HEAD_CSS + VAULT_CSS + """
.a-bubble{background:#33343C;color:#9DA6C8;border-color:rgba(160,180,255,.22);}
"""
    thread = user_bubble(Q_CIPHER)
    dots_x = NDOTS_X
    dots = ndots_html()
    body = f"""
{NIGHT_BG}
<div class="stage">
  {app_window(thread, "Ask me anything !", field_ph=True)}
  {HEAD_HTML}
  <div class="lab2 lab-d" style="left:80px;top:262px">Your device</div>
  <div class="lab2 lab-s" style="left:1180px;top:262px">Our server</div>
  <div class="ndots">{dots}</div>
  {vault_html()}
  <div class="ccard">{Q_CIPHER}</div>
</div>"""
    # bubble in the split window: logical (436..888, 339..383) -> page
    k = WIN_ZOOM * SPLIT_SCALE
    bx = SPLIT_LEFT + 436 * k
    by = SPLIT_TOP + 339 * k
    js = f"""
  var win = q(".win"), card = q(".ccard"), vault = q(".vault");
  // handoff from frame 5: identical split state at t = 0
  tl.set(win, {{ x: {SPLIT_LEFT - WIN_LEFT}, y: {SPLIT_TOP - WIN_TOP}, scale: {SPLIT_SCALE} }}, 0);
  qa(".nh .ln").forEach(function (l, i) {{
    tl.fromTo(l, {{ opacity: 1, y: 0 }}, {{ opacity: 0, y: -26, duration: 0.4, ease: "power2.in" }}, 0.02 + i * 0.05);
  }});
  tl.fromTo(q(".lab-d"), {{ opacity: 0, y: 12 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, 0.35);
  tl.fromTo(vault, {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }}, 0.45);
  tl.fromTo(q(".lab-s"), {{ opacity: 0, y: 12 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, 0.55);
  // the badge names the panel at once; its contents wait for the arrival
  tl.fromTo(q(".v-badge"), {{ opacity: 0, y: -10 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "expo.out" }}, 0.7);
  tl.fromTo([q(".v-bub"), q(".v-ans"), q(".v-note")], {{ opacity: 0 }}, {{ opacity: 0, duration: 0.01 }}, 0);
  var dots = qa(".ndot");
  dots.forEach(function (d, i) {{
    tl.fromTo(d, {{ scale: 0, opacity: 0 }}, {{ scale: 1, opacity: 1, duration: 0.18, ease: "power2.out" }}, 0.6 + i * 0.025);
  }});
  // 0.947: the ciphertext leaves the device as a card of noise
  tl.fromTo(card, {{ x: {bx:.1f}, y: {by - 10:.1f}, scale: 0.72, opacity: 0 }}, {{ x: {bx - 20:.1f}, y: {by - 70:.1f}, scale: 1, opacity: 1, duration: 0.35, ease: "power3.out" }}, 0.947);
  tl.to(card, {{ x: 800, y: 474, duration: 0.45, ease: "power2.inOut" }}, 1.30);
  tl.to(card, {{ x: 1216, y: 430, duration: 1.72, ease: "power1.inOut" }}, 1.75);
  dots.forEach(function (d, i) {{
    var x = {json.dumps(dots_x)}[i];
    var t = x < 990 ? 1.30 + (x - 872) / (990 - 872) * 0.45 : 1.75 + (x - 990) / (1406 - 990) * 1.72;
    tl.to(d, {{ backgroundColor: "#F2C56B", duration: 0.1 }}, t);
  }});
  // 3.474: it lands as the stored ciphertext
  tl.to(card, {{ opacity: 0, duration: 0.12 }}, 3.47);
  tl.fromTo(q(".v-bub"), {{ opacity: 0, y: 6 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: "power3.out", immediateRender: false }}, 3.46);
  tl.fromTo(q(".v-ans"), {{ opacity: 0 }}, {{ opacity: 1, duration: 0.5, ease: "power2.out", immediateRender: false }}, 3.75);
  tl.fromTo(q(".v-note"), {{ opacity: 0, y: 10 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "expo.out", immediateRender: false }}, 4.0);
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================= F7 answer
def f07():
    fid, dur = "07-answer", 5.052
    css = NIGHT_CSS + APP_CSS + VAULT_CSS + """
.cam{position:absolute;inset:0;transform-origin:0 0;}
.ndot{background:#F2C56B;}
.eyebrow{position:absolute;left:260px;top:72px;font-family:"Chuk Chat Mono",monospace;font-size:30px;font-weight:500;color:#F2C56B;}
.w{opacity:1;}
"""

    def words(text, cls="w"):
        parts = text.split(" ")
        return " ".join(f'<span class="{cls}">{p}</span>' for p in parts)

    thread = (
        user_bubble(Q_CIPHER)
        + '<div class="a-tl"><p class="a-tl-head"><span>Thought for 4s</span>'
        + icon("arrow-right01", "z16")
        + "</p></div>"
        + '<div class="a-ai"><p><strong>'
        + words(LEAD)
        + "</strong></p><ul>"
        + "".join(f"<li>{words(b)}</li>" for b in BULLETS)
        + "</ul></div>"
        + '<div class="a-acts"><span class="a-act"><span>'
        + icon("copy01", "z18")
        + "</span><span>"
        + icon("refresh", "z18")
        + "</span><span>"
        + icon("alt-route", "i18")
        + "</span></span></div>"
    )
    body = f"""
{NIGHT_BG}
<div class="stage">
  <div class="ndots">{ndots_html()}</div>
  {vault_html()}
  <div class="lab2 lab-d" style="left:80px;top:262px">Your device</div>
  <div class="lab2 lab-s" style="left:1180px;top:262px">Our server</div>
  <div class="cam">{app_window(thread, "Ask me anything !", field_ph=True)}</div>
  <div class="eyebrow">Back on your device</div>
</div>"""
    rows = scramble_frames(QUESTION, Q_CIPHER, 0.7, 0xD15EA5E, forward=False)
    # hidden content below the bubble, in logical px (explicit heights in APP_CSS)
    H_TL, H_LEAD, H_LI, H_UL_END, H_ACTS = 39, 8 + 31, 27, 8, 36
    total = H_TL + H_LEAD + 3 * H_LI + H_UL_END + H_ACTS
    js = f"""
  var win = q(".win"), bub = q(".a-bubble"), col = q(".a-col");
  // handoff from frame 6: split state, vault ghost on the right
  tl.set(win, {{ x: {SPLIT_LEFT - WIN_LEFT}, y: {SPLIT_TOP - WIN_TOP}, scale: {SPLIT_SCALE} }}, 0);
  tl.fromTo([q(".vault"), q(".lab-s")], {{ opacity: 1, x: 0 }}, {{ opacity: 0, x: 60, duration: 0.45, ease: "power2.in" }}, 0.0);
  tl.fromTo([q(".ndots"), q(".lab-d")], {{ opacity: 1 }}, {{ opacity: 0, duration: 0.3, ease: "power1.in" }}, 0.0);
  tl.to(win, {{ x: 0, y: 0, scale: 1, duration: 0.85, ease: "power3.inOut" }}, 0.05);
  tl.fromTo(q(".eyebrow"), {{ opacity: 0, y: 14 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "expo.out" }}, 0.45);
  tl.to(q(".eyebrow"), {{ opacity: 0, y: -10, duration: 0.35, ease: "power2.in" }}, 1.25);
  // camera pushes in on the answer block (page 994,501 -> screen centre)
  tl.fromTo(q(".cam"), {{ x: 0, y: 0, scale: 1 }}, {{ x: 960 - 994 * 1.45, y: 540 - 501 * 1.45, scale: 1.45, duration: 0.8, ease: "power3.inOut" }}, 1.2);
  // bubble keeps its frame-6 place: the answer is laid out below, pushed out of view
  tl.set(bub, {{ backgroundColor: "#33343C", color: "#9DA6C8", borderColor: "rgba(160,180,255,.22)" }}, 0);
  tl.fromTo(col, {{ y: {total} }}, {{ y: {total}, duration: 0.01 }}, 0);
  var hidden = qa(".a-tl, .a-acts, .a-ai li").concat(qa(".a-ai .w"));
  hidden.forEach(function (h) {{ tl.fromTo(h, {{ opacity: 0 }}, {{ opacity: 0, duration: 0.01 }}, 0); }});
  // decrypted with the key on this device
  var rows = {js_rows(rows)};
  rows.forEach(function (r, i) {{ tl.set(bub, {{ textContent: r }}, 0.82 + i / 30); }});
  tl.to(bub, {{ backgroundColor: "#B6674D", color: "#E8E4D8", borderColor: "rgba(232,228,216,.3)", duration: 0.7, ease: "power1.inOut" }}, 0.82);
  // the answer arrives; the thread scrolls up by exactly what appears
  var off = {total};
  function step(h, t) {{ off -= h; tl.to(col, {{ y: off, duration: 0.28, ease: "power2.out" }}, t); }}
  step({H_TL}, 1.45);
  tl.fromTo(q(".a-tl"), {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, immediateRender: false }}, 1.47);
  step({H_LEAD}, 1.72);
  qa(".a-ai p .w").forEach(function (w, i) {{
    tl.fromTo(w, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.12, immediateRender: false }}, 1.74 + i * 0.07);
  }});
  var liStarts = [2.28, 2.72, 3.12];
  qa(".a-ai li").forEach(function (li, j) {{
    step({H_LI} + (j === 2 ? {H_UL_END} : 0), liStarts[j]);
    tl.fromTo(li, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.1, immediateRender: false }}, liStarts[j] + 0.02);
    qa(".a-ai li:nth-child(" + (j + 1) + ") .w").forEach(function (w, i) {{
      tl.fromTo(w, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.1, immediateRender: false }}, liStarts[j] + 0.02 + i * 0.045);
    }});
  }});
  step({H_ACTS}, 3.62);
  tl.fromTo(q(".a-acts"), {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, immediateRender: false }}, 3.66);
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================== F8 claim
def f08():
    fid, dur = "08-claim", 5.053
    css = """
.bg.paper{background:#FDFBF7;}
.eb{position:absolute;left:0;right:0;top:268px;text-align:center;font-family:"Chuk Chat Mono",monospace;font-size:30px;font-weight:500;color:#946A06;}
.l1,.l2{position:absolute;left:0;right:0;text-align:center;font-size:124px;line-height:1;letter-spacing:-0.045em;font-weight:500;}
.l1{top:352px;color:#26251F;}
.l2{top:500px;color:#26251F;}
.chips{position:absolute;left:0;right:0;top:708px;display:flex;justify-content:center;gap:18px;}
.chip{display:inline-flex;align-items:center;gap:12px;padding:16px 30px;border-radius:999px;background:rgba(255,255,255,.7);border:1px solid rgba(38,37,31,.12);font-size:32px;color:#26251F;}
.chip svg{width:28px;height:28px;color:#5F5D55;}
"""
    body = f"""
<div class="bg paper clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage">
  <div class="eb">Private AI chat from Germany</div>
  <div class="l1">We keep only ciphertext.</div>
  <div class="l2">Never used for training.</div>
  <div class="chips"><span class="chip">{icon('lock','i18')}End-to-end encrypted storage</span><span class="chip">No tracking</span></div>
</div>"""
    js = """
  tl.fromTo(q(".l1"), { opacity: 0, y: 44 }, { opacity: 1, y: 0, duration: 0.9, ease: "expo.out" }, 0.05);
  tl.fromTo(q(".eb"), { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.7, ease: "power3.out" }, 0.3);
  tl.fromTo(q(".l2"), { opacity: 0, y: 44 }, { opacity: 1, y: 0, duration: 0.9, ease: "expo.out" }, 0.93);
  qa(".chip").forEach(function (c, i) {
    tl.fromTo(c, { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.7, ease: "expo.out" }, 3.45 + i * 0.12);
  });
"""
    write(fid, template(fid, dur, css, body, js))


# ============================================================ F9 end card
def f09():
    fid, dur = "09-endcard", 4.389
    css = """
.bg.paper{background:#FDFBF7;}
.lock{position:absolute;left:0;right:0;top:360px;display:flex;align-items:center;justify-content:center;gap:34px;}
.logo{width:136px;height:136px;display:block;}
.word{font-family:"Chuk Chat Mono",monospace;font-weight:700;font-size:118px;letter-spacing:-0.02em;color:#26251F;line-height:1;}
.slogan{position:absolute;left:0;right:0;top:560px;text-align:center;font-family:"Chuk Chat Mono",monospace;font-size:44px;color:#5F5D55;}
.url{position:absolute;left:0;right:0;top:668px;display:flex;justify-content:center;}
.url span{display:inline-block;padding:18px 40px;border-radius:999px;background:#26251F;color:#FDFBF7;font-family:"Chuk Chat Mono",monospace;font-weight:600;font-size:38px;}
"""
    body = """
<div class="bg paper clip" data-start="0" data-duration="__DUR__" data-track-index="0"></div>
<div class="stage">
  <div class="lock"><img class="logo" src="assets/logo-ink.svg" alt="Chuk Chat logo"><span class="word">Chuk Chat</span></div>
  <div class="slogan">Private and Secure. Always.</div>
  <div class="url"><span>chuk.chat</span></div>
</div>"""
    js = """
  tl.fromTo(q(".logo"), { opacity: 0, scale: 0.86, rotation: -12 }, { opacity: 1, scale: 1, rotation: 0, duration: 0.9, ease: "expo.out" }, 0.0);
  tl.fromTo(q(".word"), { opacity: 0, x: -24 }, { opacity: 1, x: 0, duration: 0.8, ease: "expo.out" }, 0.16);
  tl.fromTo(q(".slogan"), { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }, 0.62);
  tl.fromTo(q(".url span"), { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.8, ease: "expo.out" }, 0.95);
"""
    write(fid, template(fid, dur, css, body, js))


if __name__ == "__main__":
    for fn in (f01, f02, f03, f04, f05, f06, f07, f08, f09):
        fn()
    print("Q_CIPHER", Q_CIPHER)
