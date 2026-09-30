"""Result card types. A reel's JSON names one type in card.type.

Each type gives:
  chat(d)  -> the card inside the chat (or the assistant overlay), dp units
  full(d)  -> the full-screen result the reel swipes into (a .fs layer)
  css      -> styles for both
  js(d)    -> animation; reads T.card (card lands), T.full (swipe landed)

A new reel of an existing kind needs only JSON. A new kind of result is one
new entry in TYPES.
"""
import json

from icons import icon
from kit import LOCK, PIN, SHARE, esc, md_inline, md_words, tb_full

TYPES = {}


def card_type(name):
    def reg(cls):
        TYPES[name] = cls()
        return cls
    return reg


def logo_img(name, cls="lgs"):
    return f'<span class="{cls}"><img src="{{A}}logos/connectors/{name}.png" alt="" /></span>'


# ================================================================ document (invoice, any PDF)
@card_type("document")
class Document:
    css = """
.dc-th { flex: none; width: 66px; height: 88px; border-radius: 5px; background: #FBFAF7; padding: 10px 8px; display: flex; flex-direction: column; gap: 5px; }
.dc-th i { display: block; height: 4px; border-radius: 2px; background: #D9D3C8; }
.dc-th i.h { width: 62%; height: 8px; margin-bottom: 4px; background: #3A362F; }
.dc-th i.s { width: 70%; }
.dc-th i.t { margin-top: auto; height: 8px; background: #E39A7F; }
.ac-txt em { font-style: normal; font-size: 18px; font-weight: 700; color: var(--fg); white-space: nowrap; }
.fs-doc .dv { top: 112px; }
.fs-doc .pg { height: 560px; padding: 28px 24px; transform-origin: 50% 0%; }
.pg-from { font-size: 18px; color: #837C71; }
.pg-top { display: flex; align-items: baseline; justify-content: space-between; margin-top: 30px; padding-bottom: 12px; border-bottom: 3px solid #29251F; }
.pg-top b { font-size: 44px; font-weight: 700; letter-spacing: -0.02em; }
.pg-top span { font-family: var(--mono); font-size: 17.5px; color: #6E675C; }
.pg-to { margin-top: 18px !important; font-size: 20px; color: #4F493F; }
.pg-rows { margin-top: 30px; }
.pg-row { display: flex; justify-content: space-between; gap: 12px; padding: 15px 0; border-bottom: 1.5px solid #E7E1D6; font-size: 20.5px; font-variant-numeric: tabular-nums; white-space: nowrap; }
.pg-tot { position: relative; margin-top: 10px; padding: 16px 12px; border: 0; border-radius: 10px; font-size: 28px; font-weight: 700; margin-left: -12px; margin-right: -12px; }
.pg-tot-bg { position: absolute; inset: 0; border-radius: 8px; background: rgba(217, 119, 87, 0.2); }
.pg-tot span { position: relative; }
.pg-note { margin-top: 30px !important; font-size: 18px; color: #837C71; }
.dv-foot { position: absolute; left: 16px; right: 16px; bottom: 30px; height: 50px; display: flex; align-items: center; justify-content: space-between; }
.dv-ver { display: flex; align-items: center; gap: 6px; height: 44px; padding: 0 16px; border-radius: 22px; background: var(--lift); font-size: 17.5px; font-weight: 700; color: var(--fg85); }
.dv-ver svg { width: 16px; height: 16px; }
"""

    def chat(self, d):
        return (f'<div class="ac dc"><div class="ac-top"><span class="dc-th"><i class="h"></i><i></i><i class="s"></i><i></i><i></i><i class="t"></i></span>'
                f'<span class="ac-txt"><b>{esc(d["title"])}</b><small>{esc(d["meta"])}</small><em>{esc(d.get("highlight", ""))}</em></span></div>'
                f'<div class="ac-btns"><span class="ac-btn">{icon("h-download01")}Download</span><span class="ac-btn pri tap-target">Open</span></div></div>')

    def full(self, d):
        doc = d["doc"]
        rows = "".join(f'<div class="pg-row"><span>{esc(a)}</span><span>{esc(b)}</span></div>' for a, b in doc["rows"])
        tot = doc["total"]
        return (f'<div class="fs fs-doc" data-layout-allow-overlap data-layout-allow-occlusion>{tb_full(d["title"], ("share",))}'
                f'<div class="dv"><div class="pg">'
                f'<p class="pg-from">{esc(doc["from"])}</p>'
                f'<div class="pg-top"><b>{esc(doc["heading"])}</b><span>{esc(doc["number"])}</span></div>'
                f'<p class="pg-to">{esc(doc["to"])}</p>'
                f'<div class="pg-rows">{rows}<div class="pg-row pg-tot"><i class="pg-tot-bg"></i><span>{esc(tot[0])}</span><span>{esc(tot[1])}</span></div></div>'
                f'<p class="pg-note">{esc(doc.get("note", ""))}</p>'
                f'</div></div>'
                f'<div class="dv-foot"><span class="dv-ver">{esc(d.get("version", "Version v1"))}{icon("h-arrow-down01")}</span>'
                f'<span class="ac-btn pri">{icon("h-download01")}Download</span></div></div>')

    def js(self, d):
        return r"""
  // document: thumbnail lines settle, the total lights up in the viewer
  $$('.dc-th i').forEach(function (e, i) { tl.fromTo(e, { scaleX: 0, transformOrigin: '0% 50%' }, { scaleX: 1, duration: 0.3, ease: 'power2.out' }, T.card + 0.2 + i * 0.06); });
  tl.fromTo('.pg-tot-bg', { opacity: 0, scaleX: 0.2, transformOrigin: '0% 50%' }, { opacity: 1, scaleX: 1, duration: 0.45, ease: 'power3.out' }, T.full + 0.25);
  tl.fromTo('.pg-tot', { scale: 1 }, { scale: 1.06, duration: 0.2, ease: 'power2.out' }, T.full + 0.3);
  tl.fromTo('.pg-tot', { scale: 1.06 }, { scale: 1, duration: 0.4, ease: 'back.out(2)', immediateRender: false }, T.full + 0.5);
  tl.fromTo('.pg', { scale: 1 }, { scale: 1.035, duration: DUR - T.full, ease: 'none' }, T.full);
"""


# ================================================================ plan (week from connectors)
@card_type("plan")
class Plan:
    css = """
.pl { padding: 14px 14px 12px; }
.pl-h { display: flex; align-items: baseline; justify-content: space-between; padding: 0 2px 8px; }
.pl-h b { font-size: 19px; font-weight: 700; }
.pl-h span { font-size: 17.5px; color: var(--fg70); }
.pl-r { display: flex; align-items: center; gap: 12px; height: 50px; border-top: 1px solid var(--line); white-space: nowrap; }
.pl-d { flex: none; width: 46px; font-family: var(--mono); font-size: 17.5px; font-weight: 700; color: var(--acc2); }
.pl-t { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; font-size: 18px; color: var(--fg); }
.lgs { flex: none; width: 30px; height: 30px; border-radius: 8px; background: #FFFFFF; display: flex; align-items: center; justify-content: center; overflow: hidden; }
.lgs img { width: 22px; height: 22px; object-fit: contain; }
.pl-more { display: flex; align-items: center; justify-content: space-between; padding-top: 10px; border-top: 1px solid var(--line); }
.pl-more > span:first-child { font-size: 17.5px; color: var(--fg70); }
.fs-plan { background: #262624; }
.pv { position: absolute; left: 16px; right: 16px; top: 104px; }
.pv-sub { display: flex; align-items: center; gap: 8px; padding: 2px 4px 14px; font-size: 17.5px; color: var(--muted); }
.pv-sub .lgs { width: 26px; height: 26px; border-radius: 7px; }
.pv-sub .lgs img { width: 19px; height: 19px; }
.pv-i { display: flex; align-items: center; gap: 14px; margin-bottom: 12px; padding: 18px 16px; border-radius: 18px; background: var(--card); border: 1px solid rgba(232, 228, 216, 0.1); }
.pv-d { flex: none; width: 58px; height: 58px; border-radius: 14px; background: rgba(217, 119, 87, 0.16); display: flex; align-items: center; justify-content: center;
  font-family: var(--mono); font-size: 17.5px; font-weight: 700; color: var(--acc2); }
.pv-b { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 5px; }
.pv-b b { font-size: 20px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pv-b small { display: flex; align-items: center; gap: 8px; font-size: 17.5px; color: var(--fg70); white-space: nowrap; }
.pv-b small .lgs { width: 26px; height: 26px; border-radius: 7px; }
.pv-b small .lgs img { width: 19px; height: 19px; }
.pv-tag { flex: none; height: 32px; padding: 0 11px; border-radius: 16px; display: flex; align-items: center; background: rgba(217, 119, 87, 0.2); color: var(--acc2); font-size: 17.5px; font-weight: 700; }
"""

    def chat(self, d):
        items = d["items"]
        shown = items[: d.get("chat_rows", 3)]
        rows = "".join(f'<div class="pl-r"><span class="pl-d">{esc(i["day"])}</span><span class="pl-t">{esc(i["task"])}</span>{logo_img(i["src"])}</div>'
                       for i in shown)
        more = len(items) - len(shown)
        return (f'<div class="ac pl"><div class="pl-h"><b>{esc(d["title"])}</b><span>{len(items)} due</span></div>{rows}'
                f'<div class="pl-more"><span>{"+%d more" % more if more else ""}</span><span class="ac-btn pri tap-target">Open plan</span></div></div>')

    def full(self, d):
        srcs = []
        for i in d["items"]:
            if i["src"] not in srcs:
                srcs.append(i["src"])
        sub = "".join(logo_img(s) for s in srcs)
        items = ""
        for i in d["items"]:
            tag = f'<span class="pv-tag">{esc(i["tag"])}</span>' if i.get("tag") else ""
            items += (f'<div class="pv-i"><span class="pv-d">{esc(i["day"])}</span><div class="pv-b"><b>{esc(i["task"])}</b>'
                      f'<small>{logo_img(i["src"])}{esc(i.get("src_label", i["src"].title()))}</small></div>{tag}</div>')
        return (f'<div class="fs fs-plan" data-layout-allow-overlap data-layout-allow-occlusion>{tb_full(d["title"], ("share",))}'
                f'<div class="pv"><p class="pv-sub">{sub}<span>{len(d["items"])} due this week</span></p>{items}</div></div>')

    def js(self, d):
        return r"""
  // plan: rows of the full plan cascade in as the screen lands, the priority tag pops
  $$('.pv-i').forEach(function (e, i) { tl.fromTo(e, { opacity: 0, x: 60 }, { opacity: 1, x: 0, duration: 0.4, ease: 'power3.out' }, T.swipe + 0.15 + i * 0.07); });
  $$('.pv-tag').forEach(function (e) { pop(e, T.full + 0.35, { s: 0.4 }); });
"""


# ================================================================ chart
def smooth_path(pts):
    d = f"M{pts[0][0]:.1f} {pts[0][1]:.1f}"
    for i in range(len(pts) - 1):
        p0 = pts[max(i - 1, 0)]; p1 = pts[i]; p2 = pts[i + 1]; p3 = pts[min(i + 2, len(pts) - 1)]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}"
    return d


def chart_svg(cls, series, w, h, left, top, bottom, lo, hi, yticks, xlabels, fs, stroke, fmt, color="#F59E0B"):
    right = w - 10
    n = len(series)
    xs = [left + (right - left) * i / (n - 1) for i in range(n)]
    ys = [top + (bottom - top) * (hi - v) / (hi - lo) for v in series]
    pts = list(zip(xs, ys))
    line = smooth_path(pts)
    area = line + f" L{xs[-1]:.1f} {bottom:.1f} L{xs[0]:.1f} {bottom:.1f} Z"
    grid = lab = ""
    for v in yticks:
        y = top + (bottom - top) * (hi - v) / (hi - lo)
        grid += f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="rgba(232,228,216,0.14)" stroke-dasharray="4 5"/>'
        if left > 0:
            lab += f'<text x="{left - 10}" y="{y + fs * 0.35:.1f}" text-anchor="end">{esc(fmt.format(v))}</text>'
    for i, t in xlabels:
        anchor = "start" if i == 0 else ("end" if i == n - 1 else "middle")
        lab += f'<text x="{xs[i]:.1f}" y="{h - 4}" text-anchor="{anchor}">{esc(t)}</text>'
    ex, ey = pts[-1]
    gid = f"{cls}-g"
    return (f'<svg class="{cls}" width="{w}" height="{h}" viewBox="0 0 {w} {h}" aria-hidden="true">'
            f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{color}" stop-opacity="0.34"/>'
            f'<stop offset="1" stop-color="{color}" stop-opacity="0"/></linearGradient>'
            f'<clipPath id="{cls}-clip"><rect class="{cls}-clr" x="0" y="0" width="{w}" height="{h}"/></clipPath></defs>'
            f'<g class="{cls}-grid">{grid}</g>'
            f'<g fill="rgba(232,228,216,0.72)" font-family="Arimo, sans-serif" font-size="{fs}" class="{cls}-lab">{lab}</g>'
            f'<g clip-path="url(#{cls}-clip)"><path d="{area}" fill="url(#{gid})"/>'
            f'<path d="{line}" fill="none" stroke="{color}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"/></g>'
            f'<circle class="{cls}-dot" cx="{ex:.1f}" cy="{ey:.1f}" r="{stroke + 3}" fill="{color}" stroke="#262624" stroke-width="3"/>'
            f'</svg>')


@card_type("chart")
class Chart:
    css = """
.ch { padding: 14px 12px 10px; }
.ch-top { display: flex; align-items: center; gap: 10px; padding: 0 4px; white-space: nowrap; }
.ch-top b { flex: 1; font-size: 18px; font-weight: 700; }
.ch-chg { height: 32px; padding: 0 11px; border-radius: 10px; display: inline-flex; align-items: center; background: rgba(134, 199, 149, 0.16); color: var(--ok); font-size: 17.5px; font-weight: 700; }
.ch-v { padding: 4px 4px 2px; font-family: var(--mono); font-size: 28px; font-weight: 700; color: #F8C66B; }
.ch-svg { display: block; margin-top: 4px; }
.fs-chart { background: #262624; }
.cf { position: absolute; left: 12px; right: 12px; top: 104px; }
.cf-v { padding: 6px 6px 0; font-family: var(--mono); font-size: 50px; font-weight: 700; letter-spacing: -0.02em; color: #F8C66B; line-height: 1.1; }
.cf-c { display: flex; align-items: center; gap: 10px; padding: 8px 6px 0; font-size: 18px; color: var(--fg85); }
.cf-tabs { display: flex; gap: 8px; margin: 22px 6px 14px; }
.cf-tabs span { height: 40px; padding: 0 16px; border-radius: 20px; display: flex; align-items: center; font-size: 17.5px; font-weight: 700; color: var(--muted); border: 1.5px solid var(--line); }
.cf-tabs span.on { background: var(--acc); border-color: var(--acc); color: #FFFFFF; }
.cf-svg { display: block; }
.cf-stats { display: flex; gap: 10px; margin-top: 22px; }
.cf-stats span { flex: 1; padding: 12px 14px; border-radius: 16px; background: var(--card); font-size: 17.5px; color: var(--fg70); display: flex; flex-direction: column; gap: 4px; }
.cf-stats b { font-family: var(--mono); font-size: 21px; font-weight: 700; color: var(--fg); }
"""

    def _xl(self, d):
        return [tuple(x) for x in d["x_labels"]]

    def chat(self, d):
        s = d["series"]
        svg = chart_svg("ch-svg", s, 352, 176, 0, 12, 142, d["lo"], d["hi"], d["y_ticks"],
                        [x for x in self._xl(d) if x[0] in (0, len(s) - 1)], 17.5, 3.4, d.get("y_fmt", "{}"))
        return (f'<div class="ac ch tap-target"><div class="ch-top"><b>{esc(d["title"])}</b><span class="ch-chg">{esc(d["change"])}</span></div>'
                f'<p class="ch-v">{esc(d.get("prefix", ""))}<span class="ch-num">{d["from_value"]}</span>{esc(d.get("suffix", ""))}</p>{svg}</div>')

    def full(self, d):
        s = d["series"]
        svg = chart_svg("cf-svg", s, 387, 400, 62, 16, 360, d["lo"], d["hi"], d["y_ticks"], self._xl(d), 17.5, 4.2, d.get("y_fmt", "{}"))
        tabs = "".join(f'<span class="{"on" if t == d.get("range_on") else ""}">{esc(t)}</span>' for t in d.get("ranges", []))
        stats = "".join(f'<span>{esc(a)}<b>{esc(b)}</b></span>' for a, b in d.get("stats", []))
        return (f'<div class="fs fs-chart" data-layout-allow-overlap data-layout-allow-occlusion>{tb_full(d["full_title"], ("share",))}'
                f'<div class="cf"><p class="cf-v">{esc(d.get("prefix", ""))}{esc(d["to_value"])}{esc(d.get("suffix", ""))}</p>'
                f'<p class="cf-c"><span class="ch-chg">{esc(d["change"])}</span>{esc(d.get("change_label", ""))}</p>'
                f'<div class="cf-tabs">{tabs}</div>{svg}<div class="cf-stats">{stats}</div></div></div>')

    def js(self, d):
        return (r"""
  // chart: the line draws while the price counts up; it draws again full screen
  fadeIn('.ch-svg-grid', T.card + 0.15, 0.3); fadeIn('.ch-svg-lab', T.card + 0.2, 0.3);
  tl.fromTo('.ch-svg-clr', { attr: { width: 0 } }, { attr: { width: 352 }, duration: 1.7, ease: 'power1.inOut' }, T.card + 0.3);
  count('.ch-num', FROMV, TOV, T.card + 0.3, T.card + 2.0, function (v) { return v.toFixed(1); });
  pop('.ch-svg-dot', T.card + 2.0, { s: 0.2 });
  pop('.ch .ch-chg', T.card + 2.15, { s: 0.5 });
  tl.fromTo('.cf-svg-clr', { attr: { width: 62 } }, { attr: { width: 387 }, duration: 1.1, ease: 'power2.inOut' }, T.full - 0.05);
  pop('.cf-svg-dot', T.full + 1.05, { s: 0.2 });
""".replace("FROMV", json.dumps(d["from_value"])).replace("TOV", json.dumps(float(d["to_value"]))))


# ================================================================ web page (published artifact)
@card_type("webpage")
class WebPage:
    css = """
.wp { padding: 0; overflow: hidden; }
.wp-h { display: flex; align-items: center; gap: 9px; height: 54px; padding: 0 14px; border-bottom: 1px solid rgba(232, 228, 216, 0.12); white-space: nowrap; }
.wp-h svg { width: 21px; height: 21px; color: var(--acc2); }
.wp-h b { flex: 1; font-size: 18px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; }
.wp-type { height: 30px; padding: 0 9px; border-radius: 8px; display: flex; align-items: center; background: rgba(217, 119, 87, 0.16); color: var(--acc2); font-size: 17.5px; font-weight: 700; }
.wp-prev { margin: 12px; padding: 16px 16px 14px; border-radius: 10px; background: #FFF8EE; color: #29251F; }
.wp-prev .n { display: flex; align-items: center; gap: 12px; font-size: 17.5px; color: #6B6357; }
.wp-prev .n b { margin-right: auto; font-size: 19px; font-weight: 700; color: #1F5A73; }
.wp-prev .t { margin-top: 10px !important; font-size: 25px; font-weight: 700; line-height: 1.1; letter-spacing: -0.02em; }
.wp-link { display: flex; align-items: center; gap: 9px; height: 52px; padding: 0 14px; border-top: 1px solid rgba(232, 228, 216, 0.12); font-size: 17.5px; color: #9CC4E4; white-space: nowrap; }
.wp-link svg { width: 20px; height: 20px; color: var(--ok); }
.fs-web { background: #FFF8EE; }
.fs-web .fs-veil { background: linear-gradient(180deg, #262624 0%, #262624 100%); height: 154px; }
.wb-url { position: absolute; z-index: 6; left: 12px; right: 12px; top: 100px; height: 44px; display: flex; align-items: center; gap: 8px; padding: 0 14px; border-radius: 22px;
  background: #1A1A18; font-size: 17.5px; color: var(--fg); white-space: nowrap; }
.wb-url svg { width: 18px; height: 18px; color: var(--ok); }
.wb { position: absolute; left: 0; right: 0; top: 154px; bottom: 0; padding: 22px 22px 0; color: #29251F; }
.wb-nav { display: flex; align-items: center; gap: 18px; font-size: 18px; color: #6B6357; }
.wb-nav b { margin-right: auto; font-size: 26px; font-weight: 700; letter-spacing: -0.02em; color: #1F5A73; }
.wb-hero { margin-top: 24px; padding: 24px 22px 26px; border-radius: 20px; background: #F3E3C8; }
.wb-t { font-size: 44px; font-weight: 700; line-height: 1.03; letter-spacing: -0.035em; }
.wb-s { margin-top: 12px !important; font-size: 19px; line-height: 1.35; color: #5E574B; }
.wb-mh { margin-top: 28px !important; font-family: var(--mono); font-size: 18px; font-weight: 700; letter-spacing: 0.08em; color: #1F5A73; }
.wb-m { display: flex; align-items: baseline; gap: 8px; margin-top: 15px; font-size: 21.5px; }
.wb-m i { flex: 1; border-bottom: 2.5px dotted #CDBFAA; transform: translateY(-6px); }
.wb-m b { font-weight: 700; font-variant-numeric: tabular-nums; }
.wb-btn { display: inline-flex; align-items: center; height: 56px; margin-top: 28px; padding: 0 28px; border-radius: 28px; background: #1F5A73; color: #FFFFFF; font-size: 19px; font-weight: 700; }
"""

    def chat(self, d):
        p = d["page"]
        nav = "".join(f"<span>{esc(n)}</span>" for n in p["nav"])
        return (f'<div class="ac wp"><div class="wp-h">{icon("h-code-m")}<b>{esc(d["title"])}</b><span class="wp-type">{esc(d.get("kind", "HTML"))}</span></div>'
                f'<div class="wp-prev"><p class="n"><b>{esc(p["brand"])}</b>{nav}</p><p class="t">{esc(p["headline"])}</p></div>'
                f'<div class="wp-link tap-target">{icon("h-globe02")}<span>{esc(d["url"])}</span></div></div>')

    def full(self, d):
        p = d["page"]
        nav = "".join(f"<span>{esc(n)}</span>" for n in p["nav"])
        menu = "".join(f'<p class="wb-m"><span>{esc(a)}</span><i></i><b>{esc(b)}</b></p>' for a, b in p["menu"])
        return (f'<div class="fs fs-web fs-light-bottom" data-layout-allow-overlap data-layout-allow-occlusion>{tb_full(d["title"], ("share",), chip="Public", chip_style="background: rgba(134,199,149,0.16); color: #86C795;")}'
                f'<div class="wb-url">{LOCK}<span>{esc(d["url"])}</span></div>'
                f'<div class="wb"><p class="wb-nav"><b>{esc(p["brand"])}</b>{nav}</p>'
                f'<div class="wb-hero"><p class="wb-t">{esc(p["headline"])}</p><p class="wb-s">{esc(p["sub"])}</p></div>'
                f'<p class="wb-mh">{esc(p.get("menu_title", "MENU"))}</p>{menu}'
                f'<span class="wb-btn">{esc(p["cta"])}</span></div></div>')

    def js(self, d):
        return r"""
  // web page: the preview builds in the card; the live page sections load after the swipe
  rise('.wp-prev .n', T.card + 0.25, { y: 8 }); rise('.wp-prev .t', T.card + 0.4, { y: 10 });
  rise('.wp-link', T.card + 0.6, { y: 8 });
  ['.wb-nav', '.wb-hero', '.wb-mh'].concat($$('.wb-m'), ['.wb-btn']).forEach(function (s, i) {
    rise(s, T.swipe + 0.2 + i * 0.07, { y: 16, d: 0.4 });
  });
  pop('.fs-web .tb-chip', T.full + 0.2, { s: 0.5 });
"""


# ================================================================ PDF page with highlighted lines (lease)
@card_type("highlights")
class Highlights:
    css = """
.hl { padding-top: 2px; }
.hl-i { display: flex; align-items: flex-start; gap: 10px; margin-bottom: 12px; font-family: var(--mono); font-size: 18px; line-height: 1.45; }
.hl-n { flex: none; width: 24px; font-weight: 700; color: var(--acc2); }
.hl-t { flex: 1; min-width: 0; }
.hl .wb { font-weight: 700; }
.hl-p { flex: none; display: flex; align-items: center; height: 30px; margin-top: -1px; padding: 0 9px; border-radius: 9px; background: rgba(217, 119, 87, 0.18); color: var(--acc2);
  font-family: "Arimo", sans-serif; font-size: 17.5px; font-weight: 700; white-space: nowrap; }
.hl-src { display: flex; align-items: center; gap: 12px; margin-top: 4px; padding: 10px 12px 10px 10px; border: 1.5px solid rgba(232, 228, 216, 0.17); border-radius: 18px; background: var(--card); }
.hl-src .fm-ic { width: 40px; height: 46px; }
.hl-src .fm-ic svg { width: 22px; height: 22px; }
.hl-src b { flex: 1; font-size: 18px; font-weight: 700; }
.fs-hl { background: #1E1E1C; }
.lp { position: relative; height: 580px; padding: 24px 22px 20px 46px; font-family: "Merriweather", serif; }
.lp-pn { position: absolute; right: 22px; top: 22px; font-family: "Arimo", sans-serif; font-size: 17.5px; color: #6E675C; }
.lp-h { margin: 22px 0 8px !important; font-size: 20px; font-weight: 700; color: #29251F; }
.lp-h:first-of-type { margin-top: 30px !important; }
.lp-p { font-size: 18px; line-height: 1.66; color: #3E3930; }
.lp mark { position: relative; padding: 1px 0; border-radius: 3px; color: inherit; background: rgba(245, 196, 64, 0); -webkit-box-decoration-break: clone; box-decoration-break: clone; }
.lp-mk { position: absolute; left: 10px; width: 26px; height: 26px; border-radius: 50%; background: var(--acc); color: #FFFFFF; font-family: "Arimo", sans-serif; font-size: 17.5px; font-weight: 700;
  display: flex; align-items: center; justify-content: center; }
.dv .lp { width: 387px; }
"""

    def chat(self, d):
        items = ""
        for i, p in enumerate(d["points"]):
            items += (f'<div class="hl-i hl-i{i}"><span class="hl-n">{i + 1}.</span><p class="hl-t">{md_words(p["text"])}</p>'
                      f'<span class="hl-p">p. {p["page"]}</span></div>')
        src = d["source"]
        return (f'<div class="hl">{items}<div class="hl-src"><span class="fm-ic">{icon("h-pdf")}</span><b>{esc(src["name"])}</b>'
                f'<span class="ac-btn pri tap-target">{esc(src["open"])}</span></div></div>')

    def full(self, d):
        pg = d["page_view"]
        body = ""
        for blk in pg["blocks"]:
            if blk["kind"] == "h":
                body += f'<p class="lp-h">{esc(blk["text"])}</p>'
            else:
                parts = ""
                for seg in blk["segs"]:
                    if isinstance(seg, str):
                        parts += esc(seg)
                    else:
                        parts += f'<mark class="mk{seg["mark"]}">{esc(seg["text"])}</mark>'
                body += f'<p class="lp-p">{parts}</p>'
        markers = "".join(f'<span class="lp-mk lp-mk{m}">{m}</span>' for m in pg.get("markers", []))
        return (f'<div class="fs fs-hl" data-layout-allow-overlap data-layout-allow-occlusion>{tb_full(d["source"]["name"], ("share",), chip=pg["chip"], chip_style="background: var(--lift); color: var(--fg85);")}'
                f'<div class="dv"><div class="pg lp"><span class="lp-pn">{esc(pg["label"])}</span>{body}{markers}</div></div></div>')

    def js(self, d):
        marks = json.dumps([m for m in d["page_view"].get("markers", [])])
        return (r"""
  // highlights: the points arrive one by one; in the PDF the lines light up with their numbers
  $$('.hl-i').forEach(function (e, i) { rise(e, T.card + 0.1 + i * 0.28, { y: 10, d: 0.35 }); });
  $$('.hl-p').forEach(function (e, i) { pop(e, T.card + 0.3 + i * 0.28, { s: 0.4 }); });
  rise('.hl-src', T.card + 0.1 + 3 * 0.28, { y: 10 });
  var MKS = MARKS;
  // Place each number next to the first line of its highlight (measured on the page itself).
  var lp = $('.lp');
  MKS.forEach(function (m, i) {
    var mk = $('.lp-mk' + m), hl = $('.mk' + m);
    var k = kNow(), cr = hl.getClientRects()[0], lr = lp.getBoundingClientRect();
    mk.style.top = ((cr.top - lr.top) / k + cr.height / k / 2 - 13).toFixed(1) + 'px';
    mk.style.left = '10px';
    var t = T.full + 0.25 + i * 0.4;
    tl.fromTo(hl, { backgroundColor: 'rgba(245,196,64,0)' }, { backgroundColor: 'rgba(245,196,64,0.55)', duration: 0.35, ease: 'power1.out' }, t);
    pop(mk, t + 0.05, { s: 0.3 });
  });
""".replace("MARKS", marks))


# ================================================================ places + navigation (assistant)
# Map in a 411 x 822 dp space (the full screen). Pins: [x, y] tip positions.
MAP_W, MAP_H = 411, 822


def city_map(cls, vb, labels=False, route=True, ids=""):
    water = "M372 0 C360 120 380 220 352 330 C336 400 360 470 344 560 C330 640 350 740 330 822 L411 822 L411 0 Z"
    park = "M30 560 L112 552 L118 650 L36 660 Z"
    square = "M92 342 L182 340 L184 396 L94 398 Z"
    minor = ["M40 0 L44 822", "M110 0 L114 822", "M292 0 L296 822", "M0 120 L360 116", "M0 230 L360 226",
             "M0 320 L352 316", "M0 520 L346 516", "M0 610 L340 606", "M0 720 L336 716", "M0 770 L215 640"]
    major = ["M215 0 L215 822", "M0 410 L352 406"]
    mn = "".join(f'<path d="{d}"/>' for d in minor)
    mj = "".join(f'<path d="{d}"/>' for d in major)
    lab = ""
    if labels:
        lab = ('<g font-family="Arimo, sans-serif" fill="#5F5D57" font-size="11.3">'
               '<text x="100" y="357">Marktplatz</text>'
               '<text transform="translate(226 530) rotate(90)" text-anchor="middle">Holstenstraße</text>'
               '<text x="236" y="510">Kaistraße</text>'
               '</g>')
    rt = ""
    if route:
        path = "M215 462 L215 408 L140 408 L140 392"
        rt = (f'<path class="{ids}route-c" d="{path}" fill="none" stroke="#1D5FB0" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>'
              f'<path class="{ids}route" d="{path}" fill="none" stroke="#4C9BF5" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round"/>')
    return (f'<svg class="{cls}" viewBox="{vb}" preserveAspectRatio="xMidYMid slice" aria-hidden="true">'
            f'<rect x="0" y="0" width="{MAP_W}" height="{MAP_H}" fill="#ECEAE4"/>'
            f'<path d="{park}" fill="#D6E2CC"/><path d="{square}" fill="#E3DCCD"/>'
            f'<g stroke="#D7D3CA" stroke-width="9" fill="none" stroke-linecap="round">{mn}</g>'
            f'<g stroke="#FFFFFF" stroke-width="6" fill="none" stroke-linecap="round">{mn}</g>'
            f'<g stroke="#D2CDC2" stroke-width="15" fill="none" stroke-linecap="round">{mj}</g>'
            f'<g stroke="#FFFFFF" stroke-width="11" fill="none" stroke-linecap="round">{mj}</g>'
            f'<path d="{water}" fill="#C6D4DD"/>{lab}{rt}</svg>')


@card_type("places")
class Places:
    css = """
.pc-h { display: flex; align-items: center; gap: 9px; padding-bottom: 10px; }
.pc-h svg { width: 21px; height: 21px; color: var(--acc); }
.pc-h b { flex: 1; font-size: 19px; font-weight: 700; }
.pc-h span { font-size: 17.5px; color: var(--as-onv); }
.pc-map { position: relative; width: 357px; height: 124px; margin: 0 -8px 6px; border-radius: 14px; overflow: hidden; }
.pc-svg { position: absolute; left: 0; top: 0; width: 100%; height: 100%; }
.pin { position: absolute; width: 32px; height: 32px; margin: -31px 0 0 -16px; color: #E53935; }
.pin svg { width: 32px; height: 32px; }
.pin.big { width: 44px; height: 44px; margin: -43px 0 0 -22px; }
.pin.big svg { width: 44px; height: 44px; }
.me { position: absolute; width: 20px; height: 20px; margin: -10px 0 0 -10px; border-radius: 50%; background: #3B82F6; border: 3.5px solid #FFFFFF; }
.pc-r { position: relative; display: flex; align-items: center; gap: 10px; padding: 5px 8px; margin: 0 -8px; border-radius: 12px; white-space: nowrap; }
.pc-hi { position: absolute; inset: 0; border-radius: 12px; background: rgba(217, 119, 87, 0.18); opacity: 0; }
.pc-t { position: relative; flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.pc-t b { font-size: 18.5px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; }
.pc-t small { font-size: 17.5px; color: var(--as-onv); overflow: hidden; text-overflow: ellipsis; }
.pc-n { position: relative; flex: none; color: var(--acc); }
.pc-n svg { width: 22px; height: 22px; }
.fs-nav { background: #ECEAE4; }
.fs-nav::before { content: ""; position: absolute; z-index: 4; left: 0; right: 0; top: 0; height: 44px; background: linear-gradient(180deg, rgba(236, 234, 228, 0.95), rgba(236, 234, 228, 0)); }
.nv-svg { position: absolute; left: 0; top: 0; width: 411px; height: 822px; }
.nv-ban { position: absolute; z-index: 5; left: 12px; right: 12px; top: 46px; display: flex; align-items: center; gap: 14px; padding: 16px 18px; border-radius: 24px;
  background: #262624; color: var(--fg); box-shadow: 0 10px 26px rgba(0, 0, 0, 0.28); }
.nv-ic { flex: none; width: 52px; height: 52px; border-radius: 50%; background: var(--acc); color: #FFFFFF; display: flex; align-items: center; justify-content: center; }
.nv-ic svg { width: 28px; height: 28px; }
.nv-bt { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
.nv-bt b { font-size: 23px; font-weight: 700; }
.nv-bt small { font-size: 17.5px; color: var(--fg85); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.nv-sheet { position: absolute; z-index: 5; left: 0; right: 0; bottom: 0; padding: 20px 22px 42px; border-radius: 28px 28px 0 0; background: #262624; color: var(--fg);
  box-shadow: 0 -8px 24px rgba(0, 0, 0, 0.2); }
.nv-eta { display: flex; align-items: baseline; gap: 12px; }
.nv-eta b { font-size: 34px; font-weight: 700; color: var(--acc2); }
.nv-eta span { font-size: 19px; color: var(--fg85); }
.nv-name { margin-top: 8px !important; font-size: 20px; font-weight: 700; }
.nv-addr { margin-top: 3px !important; font-size: 17.5px; color: var(--fg70); }
"""
    # card crop of the city map (x, y, w, h) -> the card map is 363 dp wide (panel inner + bleed)
    CARD_VB = (78, 340, 314, 110)
    FULL_VB = (88, 196, 260, 520)

    def _pos(self, vb, box_w, box_h, x, y):
        s = max(box_w / vb[2], box_h / vb[3])
        ox = (box_w - vb[2] * s) / 2
        oy = (box_h - vb[3] * s) / 2
        return ox + (x - vb[0]) * s, oy + (y - vb[1]) * s

    def chat(self, d):
        vb = self.CARD_VB
        bw, bh = 357, 124
        pins = ""
        for i, p in enumerate(d["places"]):
            x, y = self._pos(vb, bw, bh, *p["xy"])
            pins += f'<span class="pin pin{i}" style="left:{x:.1f}px;top:{y:.1f}px">{PIN}</span>'
        mx, my = self._pos(vb, bw, bh, *d["me"])
        pins += f'<span class="me" style="left:{mx:.1f}px;top:{my:.1f}px"></span>'
        rows = ""
        for i, p in enumerate(d["places"]):
            rows += (f'<div class="pc-r pc-r{i}"><i class="pc-hi"></i><span class="pc-t"><b>{esc(p["name"])}</b><small>{esc(p["meta"])}</small></span>'
                     f'<span class="pc-n">{icon("asst-nav-o")}</span></div>')
        svg = city_map("pc-svg", " ".join(str(v) for v in vb), route=False)
        return (f'<div class="as-panel pc"><div class="pc-h">{icon("h-location01")}<b>{esc(d["title"])}</b><span>{esc(d["count"])}</span></div>'
                f'<div class="pc-map">{svg}{pins}</div>{rows}</div>')

    def full(self, d):
        vb = self.FULL_VB
        bw, bh = MAP_W, MAP_H
        pins = ""
        for i, p in enumerate(d["places"]):
            x, y = self._pos(vb, bw, bh, *p["xy"])
            big = " big" if i == 0 else ""
            pins += f'<span class="pin{big} fpin{i}" style="left:{x:.1f}px;top:{y:.1f}px">{PIN}</span>'
        mx, my = self._pos(vb, bw, bh, *d["me"])
        pins += f'<span class="me fme" style="left:{mx:.1f}px;top:{my:.1f}px"></span>'
        nav = d["nav"]
        svg = city_map("nv-svg", " ".join(str(v) for v in vb), labels=True, route=True, ids="nv-")
        return (f'<div class="fs fs-nav fs-light-top" data-layout-allow-overlap data-layout-allow-occlusion>{svg}{pins}'
                f'<div class="nv-ban"><span class="nv-ic">{icon("asst-nav-r")}</span><span class="nv-bt"><b>{esc(nav["banner"])}</b><small>{esc(nav["banner_sub"])}</small></span></div>'
                f'<div class="nv-sheet"><p class="nv-eta"><b>{esc(nav["eta"])}</b><span>{esc(nav["distance"])}</span></p>'
                f'<p class="nv-name">{esc(nav["name"])}</p><p class="nv-addr">{esc(nav["address"])}</p></div></div>')

    def js(self, d):
        return r"""
  // places: pins drop onto the map, rows follow; the chosen row lights up; full screen draws the route
  $$('.pc .pin').forEach(function (p, i) { tl.fromTo(p, { opacity: 0, y: -46 }, { opacity: 1, y: 0, duration: 0.42, ease: 'bounce.out' }, T.as_places + 0.2 + i * 0.13); });
  pop('.pc .me', T.as_places + 0.15, { s: 0.3 });
  $$('.pc-r').forEach(function (r, i) { rise(r, T.as_places + 0.3 + i * 0.12, { y: 8, d: 0.3 }); });
  tl.fromTo('.pc-r0 .pc-hi', { opacity: 0 }, { opacity: 1, duration: 0.3 }, T.as_nav);
  draw('.nv-route-c', T.full - 0.05, 0.8); draw('.nv-route', T.full - 0.05, 0.8);
  tl.fromTo('.fpin0', { y: -60, opacity: 0 }, { y: 0, opacity: 1, duration: 0.5, ease: 'bounce.out' }, T.full + 0.6);
  rise('.nv-ban', T.swipe + 0.25, { y: -30, d: 0.45 });
  rise('.nv-sheet', T.swipe + 0.3, { y: 80, d: 0.5 });
"""
