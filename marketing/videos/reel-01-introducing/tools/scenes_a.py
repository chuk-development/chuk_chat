"""Scenes: icon burst, Introducing + kinetic headline + "Many worlds",
the "AI that ... for you" lists and the "Done!" screen."""
import math
import random

from common import (CORAL, INK, Icon, Word, emoji, esc, kinetic, text_w, tile)

# ---------------------------------------------------------------- 1. burst (0-2.6)
BURST_SET = ["laptop", "spiral_calendar", "envelope", "world_map", "bar_chart", "locked", "receipt", "mobile_phone",
             "artist_palette", "speech_balloon", "magnifying_glass_tilted_left", "globe_with_meridians", "memo",
             "chart_increasing", "framed_picture", "page_facing_up", "round_pushpin", "key", "light_bulb", "books",
             "hot_beverage", "pencil", "clipboard", "file_folder", "camera", "package", "compass", "sparkles",
             "open_book", "paperclip", "alarm_clock", "headphone"]


def burst():
    rnd = random.Random(7)
    cols, rows = 7, 12
    objs = []
    names = BURST_SET[:]
    rnd.shuffle(names)
    k = 0
    for r in range(rows):
        for c in range(cols):
            gx = (c - (cols - 1) / 2) / ((cols - 1) / 2) * 1.08
            gy = (r - (rows - 1) / 2) / ((rows - 1) / 2) * 1.1
            gx += rnd.uniform(-0.09, 0.09)
            gy += rnd.uniform(-0.05, 0.05)
            if abs(gx) < 0.25 and abs(gy) < 0.14:
                continue  # the tile sits here
            d = rnd.uniform(0.82, 1.22)
            rot0 = rnd.uniform(-24, 24)
            rv = rnd.uniform(-40, 40)
            objs.append((names[k % len(names)], gx, gy, d, rot0, rv))
            k += 1
    imgs = "".join(f'<img class="bo" src="assets/emoji/{n}.png" alt="" />' for n, *_ in objs)
    data = ",".join(f"[{gx:.3f},{gy:.3f},{d:.3f},{r0:.1f},{rv:.1f}]" for _, gx, gy, d, r0, rv in objs)
    html = f"""
    <div id="s-burst" class="clip scene" data-start="0" data-duration="2.7" data-track-index="1">
      <div id="bu-field" class="abs" style="left:0;top:0;width:1080px;height:1920px">{imgs}</div>
      <div id="bu-tile" class="abs" style="left:430px;top:850px;width:220px;height:220px">{tile("bu-t")}</div>
    </div>"""
    css = """
    .bo { position: absolute; left: 412px; top: 832px; width: 256px; height: 256px; opacity: 0; will-change: transform; }
    .bu-t { width: 220px; height: 220px; }
"""
    js = f"""
  // Burst: a field of 3D objects flies out of the tile, like a camera diving through it.
  (function () {{
    var D = [{data}];
    var B = $$('#bu-field .bo');
    function zoom(p) {{ return (1 - Math.exp(-11 * p)) * (1 + 7.5 * p * p * p); }}
    U(function (t) {{
      if (t > 2.75) return;
      var p = (t - 1.0) / 1.5;
      for (var i = 0; i < B.length; i++) {{
        var el = B[i], d = D[i];
        if (p <= 0) {{ if (el.__v !== 0) {{ el.style.opacity = 0; el.__v = 0; }} continue; }}
        var z = zoom(Math.min(p, 1.2)) * d[2];
        var x = d[0] * 560 * z, y = d[1] * 1000 * z;
        var sc = 0.36 * z;
        var off = Math.abs(x) > 700 + 140 * sc || Math.abs(y) > 1100 + 140 * sc;
        var o = off ? 0 : Math.min(1, p / 0.05);
        el.style.opacity = o.toFixed(3); el.__v = o;
        el.style.transform = 'translate(' + x.toFixed(1) + 'px,' + y.toFixed(1) + 'px) rotate(' + (d[3] + d[4] * p).toFixed(1) + 'deg) scale(' + sc.toFixed(4) + ')';
      }}
    }});
  }})();
  A('#bu-tile', 's', 0, 0.55, 0.9, 1, 'bk');
  A('#bu-tile', 's', 0.62, 0.36, 1, 0.9, 'io2');
  A('#bu-tile', 's', 0.98, 0.3, 0.9, 1.08, 'bk');
  A('#bu-tile', 's', 1.88, 0.3, 1.08, 0, 'i3');
  A('#bu-tile', 'r', 1.88, 0.3, 0, -20, 'i2');
  A('#bu-field', 'o', 2.3, 0.3, 1, 0, 'lin');
"""
    return html, css, js


# ---------------------------------------------------------------- 2. headline (2.5-10.9)
KIN_Y = [700, 832, 964]


def headline():
    lines = [
        [Word("Chuk Chat", 3.0, "coral"), Icon(tile("ki-tile"), 5.0), Word("is", 4.75)],
        [Word("your", 5.5), Icon(emoji("locked"), 6.0), Word("private", 5.62)],
        [Word("AI", 6.25), Icon(emoji("speech_balloon"), 6.75), Word("chat", 6.37)],
    ]
    kh, kj = kinetic("k1", lines, KIN_Y, t_out=8.2)
    # "Chuk Chat" is the name under "Introducing" first, then moves up into line 1.
    intro_dy = 898 - KIN_Y[0]
    kj = kj.replace("A('#k1-0-0','y',3.000,0.36,46,0,'o3');",
                    f"A('#k1-0-0','y',3.000,0.42,{intro_dy + 40},{intro_dy},'o3');\n"
                    f"A('#k1-0-0','y',4.300,0.45,{intro_dy},0,'io3');")
    assert "4.300" in kj
    w2 = [
        [Word("One", 9.0), Word("private", 9.08), Word("chat.", 9.16)],
        [Word("Many", 9.5), Icon(emoji("globe_with_meridians"), 9.85), Word("worlds.", 9.62)],
    ]
    wh, wj = kinetic("k2", w2, [766, 898], t_out=10.5, out_stagger=0.03)
    html = f"""
    <div id="s-head" class="clip scene" data-start="2.4" data-duration="8.55" data-track-index="2">
      <p id="hd-intro" class="hl" style="top:{766 - 69.4:.1f}px">Introducing</p>
      {kh}
      {wh}
    </div>"""
    css = """
    .ki-tile { width: 108px; height: 108px; }
"""
    js = f"""
  A('#hd-intro', 'o', 2.5, 0.5, 0, 1, 'o2');
  A('#hd-intro', 'y', 2.5, 0.6, 36, 0, 'o3');
  A('#hd-intro', 'o', 4.2, 0.22, 1, 0, 'i2');
  A('#hd-intro', 'y', 4.2, 0.3, 0, -40, 'i2');
{kj}
{wj}
"""
    return html, css, js


# ---------------------------------------------------------------- lists "AI that ... for you"
def ai_list(sid, start, dur, items, t_items, t_out, track=1, for_you=True, tail_html="", tail_js=""):
    """items: [(emoji, text)]; t_items: appear time of each item. Middle line swaps like a ticker."""
    ya, ym, yf = 720, 862, 1004
    mid = []
    for i, (em, txt) in enumerate(items):
        mid.append(f'<div id="{sid}-m{i}" class="lm"><span class="lm-ic">{emoji(em)}</span><span class="lm-t">{esc(txt)}</span></div>')
    fy = f'<p id="{sid}-f" class="hl lf" style="top:{yf - 69.4:.1f}px">for you</p>' if for_you else ""
    html = f"""
    <div id="{sid}" class="clip scene" data-start="{start}" data-duration="{dur}" data-track-index="{track}">
      <p id="{sid}-a" class="hl la" style="top:{ya - 69.4:.1f}px">AI that</p>
      <div class="lm-wrap" style="top:{ym - 60}px">{"".join(mid)}</div>
      {fy}
      {tail_html}
    </div>"""
    js = [f"A('#{sid}-a','o',{start:.3f},0.22,0,1,'o2');", f"A('#{sid}-a','y',{start:.3f},0.4,46,0,'o3');"]
    if for_you:
        tf = t_items[0] + 0.25
        js += [f"A('#{sid}-f','o',{tf:.3f},0.22,0,1,'o2');", f"A('#{sid}-f','y',{tf:.3f},0.4,46,0,'o3');"]
    for i, t in enumerate(t_items):
        s = f"#{sid}-m{i}"
        js += [f"A('{s}','o',{t:.3f},0.06,0,1,'lin');", f"A('{s}','y',{t:.3f},0.34,124,0,'io3');",
               f"A('{s} .lm-ic','s',{t + 0.04:.3f},0.42,0.3,1,'bk');", f"A('{s} .lm-ic','r',{t + 0.04:.3f},0.5,-18,0,'o3');"]
        t_next = t_items[i + 1] if i + 1 < len(t_items) else t_out
        js += [f"A('{s}','y',{t_next:.3f},0.34,0,-124,'io3');"]
    js += [f"A('#{sid}-a','o',{t_out:.3f},0.2,1,0,'i2');", f"A('#{sid}-a','y',{t_out:.3f},0.26,0,-34,'i2');"]
    if for_you:
        js += [f"A('#{sid}-f','o',{t_out + 0.1:.3f},0.2,1,0,'i2');", f"A('#{sid}-f','y',{t_out + 0.1:.3f},0.26,0,-34,'i2');"]
    return html, "\n".join(js) + tail_js


LIST_CSS = """
    .la, .lf { opacity: 0; }
    .lm-wrap { position: absolute; left: 0; width: 1080px; height: 120px; overflow: hidden; }
    .lm { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 22px; opacity: 0; white-space: nowrap; }
    .lm-ic { flex: none; width: 104px; height: 104px; display: block; }
    .lm-ic img { width: 100%; height: 100%; object-fit: contain; display: block; }
    .lm-t { font-size: 88px; font-weight: 520; letter-spacing: -0.02em; color: #3A3832; line-height: 1.2; }
"""


def list1():
    items = [("spiral_calendar", "plans your week"), ("receipt", "writes the invoice"),
             ("envelope", "drafts your emails"), ("magnifying_glass_tilted_left", "researches the web")]
    return ai_list("l1", 21.0, 4.0, items, [21.25, 22.0, 22.75, 23.5], 24.55)


def list2():
    items = [("bar_chart", "charts your data"), ("world_map", "maps your route"),
             ("artist_palette", "makes images"), ("page_facing_up", "reads your PDFs")]
    return ai_list("l2", 37.0, 4.0, items, [37.25, 38.0, 38.75, 39.5], 40.55)


# ---------------------------------------------------------------- Done screen
def done(sid, start, dur, avatar_html, track=2):
    """Avatar stays on top, a coral ring draws, "Done!" lands."""
    tw = text_w("Done!", 124, 560, -0.02)
    ring = 118
    gap = 28
    total = ring + gap + tw
    x0 = 540 - total / 2
    y = 900
    html = f"""
    <div id="{sid}" class="clip scene" data-start="{start}" data-duration="{dur}" data-track-index="{track}">
      {avatar_html}
      <svg id="{sid}-ring" class="dn-ring" style="left:{x0:.1f}px;top:{y - ring / 2:.1f}px" viewBox="0 0 120 120">
        <circle class="dn-c" cx="60" cy="60" r="52" />
        <path class="dn-k" d="M38 61 L53 76 L83 45" />
      </svg>
      <p id="{sid}-t" class="dn-t" style="left:{x0 + ring + gap:.1f}px;top:{y - 80:.1f}px">Done!</p>
    </div>"""
    t = start + 0.12
    js = f"""
  A('#{sid}-ring','s',{t:.3f},0.4,0.5,1,'bk');
  A('#{sid}-ring','o',{t:.3f},0.12,0,1,'o2');
  A('#{sid}-ring .dn-c','dash',{t:.3f},0.45,330,0,'o3');
  A('#{sid}-ring .dn-k','dash',{t + 0.28:.3f},0.28,72,0,'o3');
  A('#{sid}-t','o',{t + 0.06:.3f},0.22,0,1,'o2');
  A('#{sid}-t','x',{t + 0.06:.3f},0.45,-26,0,'o3');
  A('#{sid}-t','y',{t + 0.06:.3f},0.4,30,0,'o3');
  A('#{sid}-ring','o',{start + dur - 0.22:.3f},0.18,1,0,'i2');
  A('#{sid}-t','o',{start + dur - 0.22:.3f},0.18,1,0,'i2');
  A('#{sid}-t','y',{start + dur - 0.22:.3f},0.22,0,-30,'i2');
"""
    return html, js


DONE_CSS = """
    .dn-ring { position: absolute; width: 118px; height: 118px; opacity: 0; overflow: visible; }
    .dn-c { fill: none; stroke: #D97757; stroke-width: 10; stroke-dasharray: 330; stroke-dashoffset: 330; stroke-linecap: round; transform: rotate(-90deg); transform-origin: 60px 60px; }
    .dn-k { fill: none; stroke: #D97757; stroke-width: 11; stroke-dasharray: 72; stroke-dashoffset: 72; stroke-linecap: round; stroke-linejoin: round; }
    .dn-t { position: absolute; font-size: 124px; font-weight: 560; letter-spacing: -0.02em; line-height: 160px; color: #26251F; white-space: nowrap; opacity: 0; }
"""
