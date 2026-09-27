"""Frames 00 (hook wall) and 01-04 (research, charts, maps, weather)."""
from icons import icon
from kit import PIN_SVG, beat_page, bubble, esc, page, step, words, write, logo

# ---------------------------------------------------------------- shared data
BTC = [76.4, 76.1, 75.8, 76.3, 75.6, 75.2, 74.9, 75.3, 75.9, 76.6, 77.2, 76.9, 77.6, 78.3, 78.0,
       78.8, 79.2, 79.5, 79.1, 78.6, 78.1, 78.4, 79.0, 79.6, 79.3, 80.1, 80.6, 80.4, 80.9, 81.2]


def smooth_path(pts):
    """Catmull-Rom -> cubic bezier path through pts."""
    d = f"M{pts[0][0]:.1f} {pts[0][1]:.1f}"
    for i in range(len(pts) - 1):
        p0 = pts[max(i - 1, 0)]; p1 = pts[i]; p2 = pts[i + 1]; p3 = pts[min(i + 2, len(pts) - 1)]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}"
    return d


def chart_svg(cls, w, h, left, top, bottom, lo, hi, ylabels, xlabels, fs, stroke, idp):
    """Line chart with area, grid and labels (numbers = logical px of the svg)."""
    right = w - 8
    n = len(BTC)
    xs = [left + (right - left) * i / (n - 1) for i in range(n)]
    ys = [top + (bottom - top) * (hi - v) / (hi - lo) for v in BTC]
    pts = list(zip(xs, ys))
    line = smooth_path(pts)
    area = line + f" L{xs[-1]:.1f} {bottom:.1f} L{xs[0]:.1f} {bottom:.1f} Z"
    grid, lab = "", ""
    for v in ylabels:
        y = top + (bottom - top) * (hi - v) / (hi - lo)
        grid += f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="rgba(232,228,216,0.14)" stroke-dasharray="4 5"/>'
        lab += f'<text x="{left - 10}" y="{y + fs * 0.35:.1f}" text-anchor="end">{v:g}K</text>'
    for i, t in xlabels:
        anchor = "start" if i == 0 else ("end" if i == n - 1 else "middle")
        lab += f'<text x="{xs[i]:.1f}" y="{h - 4}" text-anchor="{anchor}">{t}</text>'
    ex, ey = pts[-1]
    return (f'<svg class="{cls}" width="{w}" height="{h}" viewBox="0 0 {w} {h}" aria-hidden="true">'
            f'<defs><linearGradient id="{idp}-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F59E0B" stop-opacity="0.38"/>'
            f'<stop offset="1" stop-color="#F59E0B" stop-opacity="0"/></linearGradient>'
            f'<clipPath id="{idp}-clip"><rect class="{cls}-clr" x="0" y="0" width="{w}" height="{h}"/></clipPath></defs>'
            f'<g class="{cls}-grid">{grid}</g>'
            f'<g fill="rgba(232,228,216,0.62)" font-family="Ubuntu, sans-serif" font-size="{fs}" class="{cls}-lab">{lab}</g>'
            f'<g clip-path="url(#{idp}-clip)"><path d="{area}" fill="url(#{idp}-g)"/>'
            f'<path d="{line}" fill="none" stroke="#F59E0B" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"/></g>'
            f'<circle class="{cls}-dot" cx="{ex:.1f}" cy="{ey:.1f}" r="{stroke + 2.5}" fill="#F59E0B" stroke="#262624" stroke-width="2.5"/>'
            f'</svg>')


# Kiel map: harbour (Ostseekai) north on the fjord shore, old town (Alter Markt) south-west.
def kiel_map(cls, w=540, h=290, fs=15, labels=True):
    water = ("M330 0 L540 0 L540 290 L372 290 C366 262 378 240 368 214 L352 214 L352 204 L366 202 "
             "C360 176 352 160 350 140 L334 140 L334 130 L348 128 C344 100 338 80 330 56 L316 56 L316 46 L328 44 Z")
    park = "M40 196 L120 188 L128 250 L52 262 Z"
    park2 = "M430 60 L520 50 L520 110 L446 118 Z"
    roads_minor = [
        "M0 70 L300 62", "M0 128 L310 122", "M40 0 L60 290", "M140 0 L150 290", "M220 0 L236 290",
        "M0 250 L360 238", "M96 150 L260 146", "M180 190 L250 188",
    ]
    roads_major = ["M300 0 L318 60 L318 140 L324 214 L336 290", "M0 186 L330 176", "M180 176 L196 290"]
    rm = "".join(f'<path d="{d}"/>' for d in roads_minor)
    rj = "".join(f'<path d="{d}"/>' for d in roads_major)
    route = "M306 58 L318 66 L318 140 L322 176 L262 180 L214 182 L190 184 L186 196"
    lab = ""
    if labels:
        lab = (f'<text x="452" y="178" font-style="italic" fill="#7F909C" font-size="{fs}">Kieler</text>'
               f'<text x="452" y="{178 + fs + 3}" font-style="italic" fill="#7F909C" font-size="{fs}">Förde</text>'
               f'<text x="60" y="118" fill="#8A8883" font-size="{fs}">Altstadt</text>')
    return (f'<svg class="{cls}" data-layout-allow-overflow width="{w}" height="{h}" viewBox="0 0 540 290" preserveAspectRatio="xMidYMid slice" aria-hidden="true">'
            f'<rect width="540" height="290" fill="#E9E8E4"/>'
            f'<path d="{park}" fill="#DCE3D3"/><path d="{park2}" fill="#DCE3D3"/>'
            f'<g stroke="#D3D1CB" stroke-width="9" fill="none" stroke-linecap="round">{rm}</g>'
            f'<g stroke="#FFFFFF" stroke-width="6" fill="none" stroke-linecap="round">{rm}</g>'
            f'<g stroke="#CFCCC4" stroke-width="13" fill="none" stroke-linecap="round" stroke-linejoin="round">{rj}</g>'
            f'<g stroke="#FFFFFF" stroke-width="9" fill="none" stroke-linecap="round" stroke-linejoin="round">{rj}</g>'
            f'<path d="{water}" fill="#CBD5DC"/>'
            f'<g font-family="Ubuntu, sans-serif">{lab}</g>'
            f'<path class="{cls}-route-c" d="{route}" fill="none" stroke="#1E6FB8" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path class="{cls}-route" d="{route}" fill="none" stroke="#42A5F5" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>'
            f'</svg>')


# Weather glyphs (simple strokes, 24 box)
def wx_icon(kind, cls="wxi"):
    sun = ('<circle cx="12" cy="12" r="4.4" fill="#FFD166"/>'
           '<g stroke="#FFD166" stroke-width="1.8" stroke-linecap="round"><path d="M12 2.6v2.3M12 19.1v2.3M2.6 12h2.3M19.1 12h2.3'
           'M5.4 5.4l1.6 1.6M17 17l1.6 1.6M5.4 18.6 7 17M17 7l1.6-1.6"/></g>')
    cloud = '<path d="M7.2 19h9.9a4.1 4.1 0 0 0 .5-8.2 5.6 5.6 0 0 0-10.7 1.5A3.4 3.4 0 0 0 7.2 19Z" fill="#E6EAF2"/>'
    small_sun = ('<circle cx="8.6" cy="8.6" r="3.6" fill="#FFD166"/><g stroke="#FFD166" stroke-width="1.6" stroke-linecap="round">'
                 '<path d="M8.6 1.8v1.7M1.8 8.6h1.7M3.8 3.8l1.2 1.2M13.4 3.8l-1.2 1.2"/></g>')
    part_cloud = '<path d="M9.4 20h8.4a3.6 3.6 0 0 0 .4-7.2 4.9 4.9 0 0 0-9.3 1.3A3 3 0 0 0 9.4 20Z" fill="#E6EAF2"/>'
    rain = ('<path d="M7.2 15h9.9a4.1 4.1 0 0 0 .5-8.2 5.6 5.6 0 0 0-10.7 1.5A3.4 3.4 0 0 0 7.2 15Z" fill="#C9D2E0"/>'
            '<g stroke="#6FB7FF" stroke-width="1.8" stroke-linecap="round"><path d="M8.5 17.5l-1 3M12.5 17.5l-1 3M16.5 17.5l-1 3"/></g>')
    moon = '<path d="M15.5 3.5a8.5 8.5 0 1 0 5 13.9A7 7 0 0 1 15.5 3.5Z" fill="#E9E4C8"/>'
    body = {"sun": sun, "cloud": cloud, "part": small_sun + part_cloud, "rain": rain, "moon": moon}[kind]
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{body}</svg>'


WALK = ('<svg class="i20" viewBox="0 0 24 24" aria-hidden="true"><g fill="none" stroke="#64B5F6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        '<circle cx="13" cy="4" r="1.8" fill="#64B5F6" stroke="none"/><path d="M11 21l2-6 3 3v4M9 11l3-3 3 3 3 1M12 8l-1 7M9 11l-2 4"/></g></svg>')

# ---------------------------------------------------------------- 00 hook wall
MODELS = [("DeepSeek V4 Pro 0813", "deepseek"), ("Kimi K3", "moonshot"), ("GLM 5.3", "zai"),
          ("Qwen3.8 27B", "qwen"), ("MiniMax M3", "minimax"), ("Mistral Small 4", "mistral")]


def f00():
    fid, dur = "f00-hook", 4
    cw, ch, gap = 560, 316, 30

    def card(i, inner, extra=""):
        r, c = divmod(i, 3)
        return (f'<div class="hw-c hw-c{i} {extra}" style="left:{c * (cw + gap)}px; top:{r * (ch + gap)}px">{inner}</div>')

    chart = ('<p class="hw-h">BTC / USD <span class="hw-up">+6.3%</span></p>'
             + chart_svg("hw-ch", 520, 220, 8, 14, 206, 74, 82, [], [], 1, 5, "hw"))
    mp = (kiel_map("hw-map", 560, 316, labels=False)
          + '<span class="hw-pin hw-pin-a"></span>'
          + f'<span class="hw-pin-b">{PIN_SVG}</span>'
          + '<p class="hw-maplab">14 min walk</p>')
    wx = (f'<div class="hw-wx"><div class="hw-wx-top">{wx_icon("part", "hw-wxi")}<span class="hw-temp">17°</span></div>'
          f'<p class="hw-city">Hamburg</p><div class="hw-hours">'
          + "".join(f'<span>{wx_icon(k, "hw-hi")}<b>{t}°</b></span>' for k, t in
                    [("sun", 14), ("part", 17), ("part", 18), ("cloud", 16), ("rain", 13)])
          + '</div></div>')
    email = (f'<div class="hw-mail"><p class="hw-mail-h">{icon("h-email", "hw-ic")}Planning call</p>'
             '<p class="hw-mail-to">To: Tom</p><p class="hw-mail-btn">Open in Mail App</p></div>')
    image = '<img class="hw-img" src="assets/img/generated-workshop.jpg" alt="" />'
    lp = ('<div class="hw-lp"><p class="hw-lp-nav">Café Anker</p><p class="hw-lp-t">Coffee by the harbour.</p>'
          '<p class="hw-lp-row"><span>Flat white</span><span>3.40</span></p><p class="hw-lp-btn">Order ahead</p></div>')
    models = ('<div class="hw-models">' + "".join(
        f'<span class="hw-ml" style="--logo:url(\'assets/logos/models/{lg}.svg\')"></span>' for _, lg in MODELS)
        + '</div><p class="hw-mlab">6 open models</p>')
    pdf = ('<div class="hw-pdf" data-layout-allow-overflow><p class="hw-pdf-t">Lease summary</p>'
           + "".join(f'<i style="width:{w}%"></i>' for w in (92, 84, 88, 60, 90, 76))
           + f'<p class="hw-pdf-tag">{icon("h-pdf", "hw-ic")}PDF</p></div>')
    conns = ('<div class="hw-conn">' + "".join(
        f'<span><img src="assets/logos/connectors/{c}.png" alt="" /></span>' for c in
        ["notion", "linear", "github", "todoist", "figma", "stripe", "dropbox"]) + '<span class="hw-more">+50</span></div>')

    cells = [chart, mp, wx, email, image, lp, models, pdf, conns]
    wall = "".join(card(i, x, "hw-imgc" if i == 4 else ("hw-lpc" if i == 5 else ("hw-pdfc" if i == 7 else ("hw-mapc" if i == 1 else ""))))
                   for i, x in enumerate(cells))
    css = """
    .hw-wrap { position: absolute; left: 90px; top: 36px; width: 1740px; height: 1008px; transform-origin: 870px 504px; }
    .hw-c { position: absolute; width: 560px; height: 316px; overflow: hidden; border-radius: 26px; background: #262624; color: #E8E4D8;
      box-shadow: 0 30px 70px -26px rgba(20, 16, 8, 0.5), 0 0 0 1px rgba(255, 255, 255, 0.07); font-family: "Ubuntu", sans-serif; }
    .hw-c svg { display: block; }
    .hw-h { position: absolute; left: 28px; top: 20px; margin: 0; font-size: 36px; font-weight: 700; white-space: nowrap; }
    .hw-up { margin-left: 10px; font-size: 36px; color: #86C795; }
    .hw-ch { position: absolute; left: 20px; top: 84px; }
    .hw-map { position: absolute; left: 0; top: 0; }
    .hw-pin { position: absolute; width: 30px; height: 30px; border-radius: 50%; border: 7px solid #2E9D4B; background: #fff; }
    .hw-pin-a { left: 304px; top: 48px; }
    .hw-pin-b { position: absolute; left: 163px; top: 166px; width: 52px; height: 52px; }
    .hw-pin-b svg { width: 52px; height: 52px; }
    .hw-maplab { position: absolute; left: 20px; bottom: 18px; margin: 0; padding: 6px 16px; border-radius: 12px; background: rgba(0, 0, 0, 0.82); color: #fff; font-size: 36px; font-weight: 500; white-space: nowrap; }
    .hw-wx { position: absolute; inset: 0; padding: 22px 28px; background: linear-gradient(160deg, #34405A 0%, #2A3246 60%, #232937 100%); }
    .hw-wx-top { display: flex; align-items: center; gap: 16px; }
    .hw-wxi { width: 84px; height: 84px; }
    .hw-temp { font-size: 96px; font-weight: 300; line-height: 1; letter-spacing: -0.03em; }
    .hw-city { margin: 4px 0 0; font-size: 36px; color: rgba(232, 228, 216, 0.8); }
    .hw-hours { display: flex; justify-content: space-between; margin-top: 14px; }
    .hw-hours span { display: flex; align-items: center; gap: 4px; }
    .hw-hi { width: 36px; height: 36px; }
    .hw-hours b { font-size: 36px; font-weight: 700; }
    .hw-mail { position: absolute; inset: 0; display: flex; flex-direction: column; }
    .hw-mail-h { display: flex; align-items: center; gap: 14px; margin: 0; padding: 22px 28px; background: rgba(217, 119, 87, 0.12); font-size: 38px; font-weight: 700; }
    .hw-ic { width: 38px; height: 38px; color: #D97757; }
    .hw-mail-to { margin: 20px 28px 0; font-size: 36px; color: rgba(232, 228, 216, 0.72); }
    .hw-mail-btn { margin: auto 28px 26px; padding: 14px; border-radius: 999px; background: #D97757; color: #fff; font-size: 36px; font-weight: 500; text-align: center; }
    .hw-img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
    .hw-lp { position: absolute; inset: 14px; padding: 18px 24px; border-radius: 14px; background: #FFF8EE; color: #29251F; }
    .hw-lp-nav { margin: 0; font-size: 36px; font-weight: 800; color: #1F5A73; letter-spacing: -0.02em; }
    .hw-lp-t { margin: 8px 0 0; font-size: 44px; font-weight: 750; line-height: 1.04; letter-spacing: -0.035em; }
    .hw-lp-row { display: flex; justify-content: space-between; margin: 14px 0 0; font-size: 36px; }
    .hw-lp-btn { display: inline-block; margin: 14px 0 0; padding: 6px 22px; border-radius: 999px; background: #1F5A73; color: #fff; font-size: 36px; }
    .hw-models { display: grid; grid-template-columns: repeat(3, 1fr); gap: 22px 0; justify-items: center; padding: 34px 30px 0; }
    .hw-ml { width: 84px; height: 84px; background: #E8E4D8; -webkit-mask: var(--logo) center / 80px 80px no-repeat; mask: var(--logo) center / 80px 80px no-repeat; }
    .hw-mlab { margin: 22px 0 0; text-align: center; font-size: 36px; color: rgba(232, 228, 216, 0.8); }
    .hw-pdf { position: absolute; left: 110px; top: 22px; width: 340px; height: 330px; padding: 22px 26px; border-radius: 8px; background: #FBFAF7; color: #29251F; }
    .hw-pdf-t { margin: 0 0 12px; font-size: 36px; font-weight: 700; letter-spacing: -0.02em; white-space: nowrap; }
    .hw-pdf i { display: block; height: 12px; margin: 0 0 14px; border-radius: 6px; background: #DCD6CB; }
    .hw-pdf-tag { position: absolute; right: -90px; top: 150px; display: flex; align-items: center; gap: 8px; margin: 0; padding: 8px 18px; border-radius: 12px; background: #262624; color: #E8E4D8; font-size: 36px; font-weight: 600; }
    .hw-pdfc { background: #3A3935; }
    .hw-conn { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; padding: 34px 38px; }
    .hw-conn span { width: 104px; height: 104px; border-radius: 24px; background: #fff; display: flex; align-items: center; justify-content: center; }
    .hw-conn img { width: 60px; height: 60px; object-fit: contain; }
    .hw-conn .hw-more { background: rgba(217, 119, 87, 0.2); color: #F0A585; font-size: 38px; font-weight: 700; }
    .hw-band { position: absolute; left: 0; right: 0; top: 846px; height: 234px; display: flex; align-items: center; justify-content: center; }
    .hw-hl { margin: 0; font-family: "Inter", sans-serif; font-size: 108px; font-weight: 400; letter-spacing: -0.045em; line-height: 1; color: #26251F; white-space: nowrap; }
    .hw-hl .wd { display: inline-block; }
    .hw-hl .hw-b { color: #26251F; }
"""
    hl = ('<span class="wd hw-w0">One</span> <span class="wd hw-w1">app.</span> '
          '<span class="wd hw-w2">All</span> <span class="wd hw-w3">of</span> <span class="wd hw-w4">this.</span>')
    body = f"""    <div id="{fid}-world" class="clip sc sc--paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div id="{fid}-stage" class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="hw-wrap">{wall}</div>
      <div class="hw-band"><p class="hw-hl">{hl}</p></div>
    </div>"""
    js = """
  // Camera: close on the generated image at frame 0, pulls back until the wall sits above the band (V2).
  tl.fromTo('.hw-wrap', { scale: 1.55, y: 40 }, { scale: 0.8, y: -107, duration: 2.0, ease: 'power2.inOut' }, 0);
  // Cards tile in on 16th notes; image, map and PDF are already there at frame 0.
  var order = [[3, 0.125], [5, 0.25], [2, 0.375], [0, 0.5], [6, 0.625], [8, 0.75]];
  order.forEach(function (o) {
    tl.fromTo('.hw-c' + o[0], { opacity: 0, scale: 0.86 }, { opacity: 1, scale: 1, duration: 0.3, ease: 'back.out(1.8)' }, o[1]);
  });
  tl.fromTo('.hw-c4', { scale: 1.04 }, { scale: 1, duration: 0.6, ease: 'power2.out' }, 0);
  // Results build inside the tiles.
  tl.fromTo('.hw-ch-clr', { attr: { width: 0 } }, { attr: { width: 520 }, duration: 1.1, ease: 'power1.inOut' }, 0.55);
  pop('.hw-ch-dot', 1.62, { s: 0.2 });
  draw('.hw-map-route', 0.1, 1.1);
  draw('.hw-map-route-c', 0.1, 1.1);
  pop('.hw-pin-b', 1.2, { s: 0.3 });
  $$('.hw-hours span').forEach(function (s, i) { pop(s, 0.5 + i * 0.1, { s: 0.5 }); });
  $$('.hw-conn span').forEach(function (s, i) { pop(s, 0.85 + i * 0.07, { s: 0.4 }); });
  $$('.hw-ml').forEach(function (s, i) { pop(s, 0.75 + i * 0.07, { s: 0.4 }); });
  // Headline band in the break (V2): "One app." then "All of this."
  [[0, 2.0], [1, 2.06], [2, 2.5], [3, 2.56], [4, 2.62]].forEach(function (w) {
    tl.fromTo('.hw-w' + w[0], { opacity: 0, y: 60 }, { opacity: 1, y: 0, duration: 0.45, ease: 'power3.out' }, w[1]);
  });
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 01 research
def f01():
    fid, dur = "f01-research", 4
    srcs = [("R", "#4C7A34", "rhs.org.uk"), ("G", "#2E6B45", "gardenersworld.com"),
            ("W", "#5E5E5E", "wikipedia.org"), ("K", "#1E4E3D", "kew.org")]
    chips = "".join(f'<span class="rs-src rs-s{i}"><span class="rs-num">{i + 1}</span><i class="a-fav" style="background:{c}">{l}</i>{esc(d)}</span>'
                    for i, (l, c, d) in enumerate(srcs))
    chips += '<span class="rs-src rs-s4 rs-more">+4 more</span>'
    items = [("ZZ plant: happy in low light.", 1), ("Snake plant: water once a month.", 2), ("Pothos: grows almost anywhere.", 3)]
    lis = "".join(f'<p class="rs-li rs-l{i}"><span class="w">{i + 1}. </span>{words(t)}<i class="rs-cite rs-c{i}">{c}</i></p>'
                  for i, (t, c) in enumerate(items))
    favs = "".join(f'<i class="a-fav" style="background:{c}">{l}</i>' for l, c, _ in srcs)
    card = f"""<div class="rc rs">
      {bubble("Best plants for a dark flat?")}
      {step("search", "Searched", "low light houseplants", "rs-step")}
      <div class="rs-srcs">{chips}</div>
      <div class="a-ai rs-ans"><p class="rs-intro">{words("Three that need little light:")}</p>{lis}</div>
      <div class="rs-foot"><span class="rs-pill"><span class="rs-favs">{favs}</span>8 sources</span></div>
    </div>"""
    css = """
    .rs-srcs { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0 0 37px; }
    .rs-src { display: inline-flex; align-items: center; gap: 7px; height: 32px; padding: 0 12px 0 6px; border: 1px solid var(--fg15); border-radius: 16px;
      background: rgba(232, 228, 216, 0.06); font-size: 15px; font-weight: 500; color: var(--fg85); white-space: nowrap; }
    .rs-num { width: 20px; text-align: center; font-family: var(--chat-font); font-size: 15px; font-weight: 700; color: var(--fg55); }
    .rs-more { padding: 0 12px; color: var(--fg55); }
    .rs-ans { font-size: 17px; }
    .rs-intro { margin: 0 0 4px !important; color: var(--fg85); }
    .rs-li { position: relative; margin: 0 0 3px !important; white-space: nowrap; }
    .rs-cite { display: inline-flex; align-items: center; justify-content: center; min-width: 24px; height: 24px; margin-left: 8px; padding: 0 6px; border-radius: 7px;
      background: rgba(217, 119, 87, 0.2); color: #F0A585; font-family: var(--ui-font); font-size: 15px; font-weight: 700; font-style: normal; vertical-align: 2px; }
    .rs-foot { display: flex; justify-content: flex-end; margin-top: 12px; }
    .rs-pill { display: inline-flex; align-items: center; gap: 8px; height: 34px; padding: 0 14px 0 6px; border: 1px solid var(--fg15); border-radius: 17px; background: var(--lift);
      font-size: 15px; font-weight: 500; color: var(--fg85); }
    .rs-favs { display: inline-flex; }
    .rs-favs .a-fav { margin-right: -5px; box-shadow: 0 0 0 2px var(--lift); }
    .rs-favs .a-fav:last-child { margin-right: 2px; }
"""
    js = """
  rise('.rs-step', 0.45);
  [0.62, 0.74, 0.86, 0.98, 1.1].forEach(function (t, i) { pop('.rs-s' + i, t, { s: 0.7 }); });
  stream($('.rs-intro'), 1.3, 14);
  stream($('.rs-l0'), 1.55, 16); pop('.rs-c0', 1.95, { s: 0.3 });
  stream($('.rs-l1'), 2.05, 16); pop('.rs-c1', 2.5, { s: 0.3 });
  stream($('.rs-l2'), 2.55, 16); pop('.rs-c2', 3.0, { s: 0.3 });
  rise('.rs-foot', 3.1, { y: 8 });
"""
    return write(fid, beat_page(fid, dur, 1, "library", ["Research", "the web"], "Search the web and cite sources.", card, css, js))


# ---------------------------------------------------------------- 02 charts
def f02():
    fid, dur = "f02-charts", 4
    svg = chart_svg("bt", 508, 250, 52, 12, 214, 74, 82, [82, 80, 78, 76, 74],
                    [(0, "Aug 29"), (10, "Sep 8"), (20, "Sep 18"), (29, "Sep 27")], 15, 3, "bt")
    card = f"""<div class="rc bt-c">
      {bubble("Chart Bitcoin for the last 30 days")}
      <div class="a-ai bt-lead">{words("Up 6.3% in 30 days, near the high.")}</div>
      <div class="bt-p">
        <div class="bt-top"><b>Bitcoin / USD · 30 days</b><span class="bt-v">$<span class="bt-num">74.0</span>K</span><span class="bt-chg">+6.3%</span></div>
        {svg}
      </div>
    </div>"""
    css = """
    .bt-lead { font-size: 17px; }
    .bt-p { margin-top: 12px; padding: 14px 12px 10px 4px; border: 1px solid var(--fg15); border-radius: 14px; background: rgba(232, 228, 216, 0.035); }
    .bt-top { display: flex; align-items: center; gap: 10px; padding: 0 4px 8px 12px; font-size: 16px; white-space: nowrap; }
    .bt-top b { flex: 1; font-weight: 700; }
    .bt-v { font-family: var(--chat-font); font-size: 18px; font-weight: 700; color: #F8C66B; }
    .bt-chg { padding: 2px 8px; border-radius: 8px; background: rgba(134, 199, 149, 0.16); color: #86C795; font-size: 15px; font-weight: 700; }
    .bt { display: block; }
"""
    js = """
  stream($('.bt-lead'), 0.3, 16);
  fadeIn('.bt-grid', 0.4, 0.3); fadeIn('.bt-lab', 0.45, 0.3);
  tl.fromTo('.bt-clr', { attr: { width: 52 } }, { attr: { width: 508 }, duration: 1.9, ease: 'power1.inOut' }, 0.6);
  count($('.bt-num'), 74.0, 81.2, 0.6, 2.5, function (v) { return v.toFixed(1); });
  pop('.bt-dot', 2.5, { s: 0.2 });
  pop('.bt-chg', 2.65, { s: 0.5 });
"""
    return write(fid, beat_page(fid, dur, 2, "prism", ["Live", "charts"], "Charts from live data.", card, css, js))


# ---------------------------------------------------------------- 03 maps
def f03():
    fid, dur = "f03-maps", 4
    card = f"""<div class="rc mp-c">
      {bubble("Kiel harbour to the old town, on foot")}
      <div class="mp-box">
        {kiel_map("mp")}
        <span class="mp-o"></span>
        <span class="mp-lab mp-la">Ostseekai</span>
        <span class="mp-d">{PIN_SVG}</span>
        <span class="mp-lab mp-lb">Alter Markt</span>
      </div>
      <div class="mp-sum">{WALK}<b>Ostseekai → Alter Markt</b><span>1.1 km · 14 min</span></div>
    </div>"""
    css = """
    .mp-box { position: relative; width: 540px; height: 290px; margin-top: 14px; overflow: hidden; border-radius: 12px; border: 1px solid var(--fg15); }
    .mp { display: block; }
    .mp-o { position: absolute; left: 296px; top: 48px; width: 22px; height: 22px; border-radius: 50%; border: 5px solid #2E9D4B; background: #fff; }
    .mp-d { position: absolute; left: 167px; top: 158px; width: 38px; height: 38px; }
    .mp-d svg { width: 38px; height: 38px; }
    .mp-lab { position: absolute; padding: 3px 9px; border-radius: 6px; background: rgba(0, 0, 0, 0.84); color: #fff; font-size: 15px; font-weight: 500; white-space: nowrap; }
    .mp-la { left: 330px; top: 30px; }
    .mp-lb { left: 64px; top: 216px; }
    .mp-sum { display: flex; align-items: center; gap: 8px; margin-top: 12px; padding: 0 4px; white-space: nowrap; }
    .mp-sum b { flex: 1; font-size: 17px; font-weight: 600; }
    .mp-sum span { font-size: 16px; font-weight: 500; color: var(--fg82); }
"""
    js = """
  fadeIn('.mp-box', 0.25, 0.3);
  pop('.mp-o', 0.6, { s: 0.2 }); rise('.mp-la', 0.7, { y: 6 });
  tl.fromTo('.mp-d', { opacity: 0, y: -40 }, { opacity: 1, y: 0, duration: 0.4, ease: 'bounce.out' }, 1.0); rise('.mp-lb', 1.15, { y: 6 });
  draw('.mp-route-c', 1.3, 1.3); draw('.mp-route', 1.3, 1.3);
  rise('.mp-sum', 2.7, { y: 10 });
"""
    return write(fid, beat_page(fid, dur, 3, "network", ["Maps and", "routes"], "Places and routes on a map.", card, css, js))


# ---------------------------------------------------------------- 04 weather
def f04():
    fid, dur = "f04-weather", 4
    hours = [("09:00", "sun", 14), ("12:00", "part", 17), ("15:00", "part", 18), ("18:00", "cloud", 16),
             ("21:00", "moon", 13), ("00:00", "cloud", 11), ("03:00", "rain", 10), ("06:00", "cloud", 11)]
    hh = "".join(f'<span class="wx-h wx-h{i}"><small>{t}</small>{wx_icon(k, "wx-hi")}<b>{v}°</b></span>' for i, (t, k, v) in enumerate(hours))
    stat = lambda i, ic, v, l: f'<span class="wx-st wx-st{i}">{ic}<span><b>{v}</b><small>{l}</small></span></span>'
    drop = '<svg class="i18" viewBox="0 0 24 24"><path d="M12 3s6 6.4 6 10.4A6 6 0 0 1 6 13.4C6 9.4 12 3 12 3Z" fill="none" stroke="#9FB3D1" stroke-width="1.8"/></svg>'
    wind = '<svg class="i18" viewBox="0 0 24 24"><path d="M3 9h11a3 3 0 1 0-3-3M3 15h15a3 3 0 1 1-3 3" fill="none" stroke="#9FB3D1" stroke-width="1.8" stroke-linecap="round"/></svg>'
    umb = '<svg class="i18" viewBox="0 0 24 24"><path d="M3 12a9 9 0 0 1 18 0ZM12 12v6a2 2 0 0 0 4 0" fill="none" stroke="#9FB3D1" stroke-width="1.8" stroke-linejoin="round"/></svg>'
    days = [("Sat", "sun", "", 11, 19), ("Sun", "rain", "60%", 10, 15)]
    dd = "".join(f'<p class="wx-d wx-d{i}"><span class="wx-dn">{d}</span>{wx_icon(k, "wx-di")}<span class="wx-dp">{p}</span>'
                 f'<span class="wx-lo">{lo}°</span><b>{hi}°</b></p>' for i, (d, k, p, lo, hi) in enumerate(days))
    card = f"""<div class="rc wx-c">
      {bubble("Weather in Hamburg this weekend?")}
      <div class="wx">
        <p class="wx-loc">{icon("h-location01", "z16")}Hamburg, Germany</p>
        <div class="wx-main">{wx_icon("part", "wx-big")}<div><p class="wx-t"><span class="wx-num">0</span>°C</p><p class="wx-cond">Partly cloudy</p><p class="wx-feel">Feels like 16°C</p></div></div>
        <div class="wx-stats">{stat(0, drop, "72%", "Humidity")}{stat(1, wind, "14 km/h W", "Wind")}{stat(2, umb, "0 mm", "Rain")}</div>
        <div class="wx-hours">{hh}</div>
        <div class="wx-days">{dd}</div>
      </div>
    </div>"""
    css = """
    .wx { margin-top: 14px; padding: 14px 16px 10px; border-radius: 14px; background: linear-gradient(160deg, #34405A 0%, #2A3246 58%, #232937 100%); border: 1px solid rgba(255, 255, 255, 0.06); }
    .wx-loc { display: flex; align-items: center; gap: 6px; font-size: 15px; color: rgba(232, 228, 216, 0.8); }
    .wx-main { display: flex; align-items: center; gap: 14px; margin-top: 4px; }
    .wx-big { width: 70px; height: 70px; }
    .wx-t { font-size: 46px; font-weight: 300; line-height: 1.05; letter-spacing: -0.02em; }
    .wx-cond { font-size: 17px; font-weight: 500; }
    .wx-feel { font-size: 15px; color: rgba(232, 228, 216, 0.66); }
    .wx-stats { display: flex; gap: 22px; margin-top: 10px; padding-bottom: 12px; border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
    .wx-st { display: flex; align-items: center; gap: 7px; }
    .wx-st > span { display: flex; flex-direction: column; line-height: 1.15; }
    .wx-st b { font-size: 16px; font-weight: 700; white-space: nowrap; }
    .wx-st small { font-size: 15px; color: rgba(232, 228, 216, 0.66); }
    .wx-hours { display: flex; justify-content: space-between; padding: 10px 0 10px; border-bottom: 1px solid rgba(255, 255, 255, 0.1); }
    .wx-h { display: flex; flex-direction: column; align-items: center; gap: 3px; width: 60px; }
    .wx-h small { font-size: 15px; color: rgba(232, 228, 216, 0.7); }
    .wx-hi { width: 26px; height: 26px; }
    .wx-h b { font-size: 16px; font-weight: 700; }
    .wx-days { padding-top: 4px; }
    .wx-d { display: flex; align-items: center; gap: 10px; height: 32px; font-size: 16px; }
    .wx-dn { width: 44px; }
    .wx-di { width: 24px; height: 24px; }
    .wx-dp { flex: 1; font-size: 15px; color: #6FB7FF; }
    .wx-lo { color: rgba(232, 228, 216, 0.66); }
    .wx-d b { width: 36px; text-align: right; font-weight: 700; }
"""
    js = """
  rise('.wx', 0.3, { y: 14, d: 0.4 });
  count($('.wx-num'), 0, 17, 0.45, 1.1, function (v) { return Math.round(v); });
  pop('.wx-big', 0.5, { s: 0.5 });
  [0, 1, 2].forEach(function (i) { rise('.wx-st' + i, 1.0 + i * 0.1, { y: 8 }); });
  for (var i = 0; i < 8; i++) pop('.wx-h' + i, 1.5 + i * 0.125, { s: 0.5 });
  rise('.wx-d0', 2.6, { y: 8 }); rise('.wx-d1', 2.85, { y: 8 });
"""
    return write(fid, beat_page(fid, dur, 4, "dawn", ["Weather"], "Weather at a glance.", card, css, js))
