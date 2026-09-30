"""Chat scenes: light floating bubbles on warm paper (Muse grammar), the
avatar with a live status line, and result cards that copy the real app
(dark surface, app fonts; markup from chuk.chat layouts/partials/uc/*)."""
from common import brand_badge, esc, logo_svg, text_w, words_html, wrap
from icons import icon

# ---------------------------------------------------------------- avatar + status pill
AV_CY = 262          # avatar centre y
AV_D = 176           # avatar diameter
PILL_TOP = 336       # pill top (overlaps the avatar a little)
NAME_CY = 376
STAT_CY = 428
THREAD_Y0 = 560      # first message top
BUB_FS, BUB_W8, BUB_LH = 50, 430, 64
PADX, PADY = 40, 26
MAXW = 860
CARD_X = round((1080 - 460 * 2.1) / 2)
X_L, X_R = 64, 1016


def avatar(sid, statuses=(), dur_hint=None):
    """statuses: [(t0, t1, icon_html, text)]. Returns html (and js via avatar_js)."""
    name_w = text_w("Chuk Chat", 42, 620, -0.01)
    short_w = name_w + 76
    widest = max([text_w(s[3], 34, 460) + 54 for s in statuses] + [name_w])
    tall_w = widest + 84
    st = []
    for i, (t0, t1, ic, txt) in enumerate(statuses):
        st.append(f'<span id="{sid}-st{i}" class="av-st">{ic}<span>{esc(txt)}</span></span>')
    return f"""
      <div id="{sid}-av" class="av">
        <span class="av-c" style="left:{540 - AV_D / 2}px;top:{AV_CY - AV_D / 2}px">{logo_svg("av-logo")}</span>
        <span id="{sid}-ps" class="av-pill" style="left:{540 - short_w / 2:.1f}px;width:{short_w:.1f}px;top:{PILL_TOP}px;height:80px"></span>
        <span id="{sid}-pt" class="av-pill" style="left:{540 - tall_w / 2:.1f}px;width:{tall_w:.1f}px;top:{PILL_TOP}px;height:128px;opacity:0"></span>
        <span class="av-name" style="top:{NAME_CY - 24}px">Chuk Chat</span>
        <span class="av-stat" style="top:{STAT_CY - 22}px">{"".join(st)}</span>
      </div>"""


def avatar_js(sid, t_in, statuses, pop=True):
    js = []
    if pop:
        js += [f"A('#{sid}-av .av-c','s',{t_in:.3f},0.45,0.4,1,'bk');", f"A('#{sid}-av .av-c','o',{t_in:.3f},0.15,0,1,'o2');",
               f"A('#{sid}-ps','o',{t_in + 0.12:.3f},0.2,0,1,'o2');", f"A('#{sid}-ps','y',{t_in + 0.12:.3f},0.35,-24,0,'o3');",
               f"A('#{sid}-av .av-name','o',{t_in + 0.16:.3f},0.2,0,1,'o2');", f"A('#{sid}-av .av-name','y',{t_in + 0.16:.3f},0.35,-20,0,'o3');"]
    # tall pill visible while any status is shown
    spans = []
    for t0, t1, *_ in statuses:
        if spans and abs(spans[-1][1] - t0) < 0.05:
            spans[-1][1] = t1
        else:
            spans.append([t0, t1])
    for t0, t1 in spans:
        js += [f"A('#{sid}-pt','o',{t0:.3f},0.16,0,1,'o2');", f"A('#{sid}-pt','o',{t1:.3f},0.16,1,0,'i2');",
               f"A('#{sid}-ps','o',{t0:.3f},0.16,1,0,'i2');", f"A('#{sid}-ps','o',{t1:.3f},0.16,0,1,'o2');"]
    for i, (t0, t1, *_rest) in enumerate(statuses):
        s = f"#{sid}-st{i}"
        js += [f"A('{s}','o',{t0 + 0.04:.3f},0.18,0,1,'o2');", f"A('{s}','y',{t0 + 0.04:.3f},0.26,16,0,'o3');",
               f"A('{s}','o',{t1 - 0.12:.3f},0.12,1,0,'i2');", f"A('{s}','y',{t1 - 0.12:.3f},0.14,0,-12,'i2');"]
    return "\n".join(js)


def st_dots():
    return '<span class="st-dots"><i></i><i></i><i></i></span>'


def st_logo(name):
    return brand_badge(name, "st-bb")


def st_icon(name):
    return f'<span class="st-ic">{icon(name)}</span>'


AV_CSS = f"""
    .av {{ position: absolute; inset: 0; }}
    .av-c {{ position: absolute; width: {AV_D}px; height: {AV_D}px; border-radius: 50%; background: #26251F; display: flex; align-items: center; justify-content: center;
      box-shadow: 0 22px 44px -20px rgba(38, 37, 31, 0.55), 0 0 0 6px #FFFFFF; }}
    .av-logo {{ width: 60%; height: 60%; }}
    .av-pill {{ position: absolute; border-radius: 40px; background: #FFFFFF; box-shadow: 0 16px 36px -16px rgba(38, 37, 31, 0.28), 0 0 0 1px rgba(38, 37, 31, 0.05); }}
    .av-name {{ position: absolute; left: 0; width: 1080px; height: 48px; line-height: 48px; text-align: center; font-size: 42px; font-weight: 620; letter-spacing: -0.01em; color: #26251F; }}
    .av-stat {{ position: absolute; left: 0; width: 1080px; height: 44px; }}
    .av-st {{ position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 12px; opacity: 0; white-space: nowrap;
      font-size: 34px; font-weight: 460; color: #625F56; line-height: 44px; }}
    .st-dots {{ display: inline-flex; gap: 6px; align-items: center; height: 30px; padding: 0 2px; }}
    .st-dots i {{ width: 9px; height: 9px; border-radius: 50%; background: #8C8A80; display: block; }}
    .st-bb {{ width: 36px; height: 36px; border-radius: 9px; }}
    .st-ic {{ width: 34px; height: 34px; color: #D97757; display: flex; align-items: center; justify-content: center; }}
    .st-ic svg {{ width: 32px; height: 32px; }}
"""

# ---------------------------------------------------------------- bubbles
BUB_CSS = """
    .th { position: absolute; left: 0; top: 0; width: 1080px; height: 1920px;
      -webkit-mask-image: linear-gradient(180deg, transparent 0, transparent 470px, #000 548px, #000 100%);
      mask-image: linear-gradient(180deg, transparent 0, transparent 470px, #000 548px, #000 100%); }
    .th-in { position: absolute; left: 0; top: 0; width: 1080px; height: 1920px; }
    .bub { position: absolute; padding: 26px 40px; font-size: 50px; font-weight: 430; line-height: 64px; letter-spacing: -0.01em; opacity: 0; white-space: nowrap; }
    .bub .ln { display: block; }
    .bub-u { background: #D97757; color: #FFFFFF; border-radius: 46px 46px 14px 46px; box-shadow: 0 14px 30px -18px rgba(160, 80, 50, 0.6); }
    .bub-a { background: #F1EDE4; color: #26251F; border-radius: 46px 46px 46px 14px; }
    .bub-a .w { opacity: 0; }
    .bub-d { display: flex; align-items: center; gap: 12px; }
    .bub-d i { width: 17px; height: 17px; border-radius: 50%; background: #8C8A80; display: block; }
    .cmp { position: absolute; left: 56px; top: 1646px; width: 968px; height: 112px; border-radius: 56px; background: #FFFFFF;
      box-shadow: 0 18px 40px -22px rgba(38, 37, 31, 0.35), 0 0 0 1px rgba(38, 37, 31, 0.07); display: flex; align-items: center; gap: 18px; padding: 0 16px 0 30px; opacity: 0; }
    .cmp-plus { width: 44px; height: 44px; color: #5F5D55; }
    .cmp-plus svg { width: 44px; height: 44px; }
    .cmp-ph { flex: 1; font-size: 40px; font-weight: 420; color: #8C8A80; white-space: nowrap; }
    .cmp-send { width: 80px; height: 80px; border-radius: 50%; background: #D97757; display: flex; align-items: center; justify-content: center; color: #fff; }
    .cmp-send svg { width: 40px; height: 40px; transform: rotate(-90deg); }
"""


class Thread:
    """Messages placed top-down in thread space; the thread scrolls by y."""

    def __init__(self, sid, y0=THREAD_Y0):
        self.sid, self.y = sid, y0
        self.items = {}
        self.html = []
        self.js = []
        self.last_who = None

    def _place(self, key, h, who, slot=None, gap=None):
        if slot is not None:
            y = self.items[slot][0]
        else:
            if gap is None:
                gap = 22 if who == self.last_who else 34
            y = self.y + (gap if self.items else 0)
            self.y = y + h
        self.items[key] = (y, h)
        self.last_who = who
        return y

    def user(self, key, text, t):
        lines = wrap(text, BUB_FS, BUB_W8, MAXW - 2 * PADX, -0.01)
        w = max(text_w(ln, BUB_FS, BUB_W8, -0.01) for ln in lines) + 2 * PADX + 2
        h = len(lines) * BUB_LH + 2 * PADY
        y = self._place(key, h, "u")
        inner = "".join(f'<span class="ln">{esc(ln)}</span>' for ln in lines)
        self.html.append(f'<div id="{self.sid}-{key}" class="bub bub-u" style="left:{X_R - w:.1f}px;top:{y}px;width:{w:.1f}px">{inner}</div>')
        s = f"#{self.sid}-{key}"
        self.js += [f"A('{s}','o',{t:.3f},0.18,0,1,'o2');", f"A('{s}','y',{t:.3f},0.42,90,0,'o3');",
                    f"A('{s}','s',{t:.3f},0.42,0.94,1,'o3');"]
        return y, h

    def assistant(self, key, text, t, wps=9, slot=None):
        lines = wrap(text, BUB_FS, BUB_W8, MAXW - 2 * PADX, -0.01)
        w = max(text_w(ln, BUB_FS, BUB_W8, -0.01) for ln in lines) + 2 * PADX + 2
        h = len(lines) * BUB_LH + 2 * PADY
        y = self._place(key, h, "a", slot=slot)
        inner = "".join(f'<span class="ln">{words_html(ln)}</span>' for ln in lines)
        self.html.append(f'<div id="{self.sid}-{key}" class="bub bub-a" style="left:{X_L}px;top:{y}px;width:{w:.1f}px">{inner}</div>')
        s = f"#{self.sid}-{key}"
        self.js += [f"A('{s}','o',{t:.3f},0.12,0,1,'o2');", f"stream('{s}',{t + 0.05:.3f},{wps});"]
        return y, h

    def dots(self, key, t0, t1, slot_key=None):
        h = BUB_LH + 2 * PADY
        if slot_key is None:
            y = self._place(key, h, "a")
        else:
            y = self.items[slot_key][0]
            self.items[key] = (y, h)
        self.html.append(f'<div id="{self.sid}-{key}" class="bub bub-a bub-d" style="left:{X_L}px;top:{y}px;width:160px;height:{h}px"><i></i><i></i><i></i></div>')
        s = f"#{self.sid}-{key}"
        self.js += [f"A('{s}','o',{t0:.3f},0.15,0,1,'o2');", f"A('{s}','s',{t0:.3f},0.3,0.7,1,'bk');",
                    f"A('{s}','o',{t1:.3f},0.12,1,0,'i2');", f"dots('{s}');"]
        return y, h

    def reserve(self, key, h, who="a"):
        return self._place(key, h, who)

    def card(self, key, html, h, t, x=80):
        y = self._place(key, h, "a")
        self.html.append(f'<div id="{self.sid}-{key}" class="card-w" style="left:{x}px;top:{y}px">{html}</div>')
        s = f"#{self.sid}-{key}"
        self.js += [f"A('{s}','o',{t:.3f},0.16,0,1,'o2');", f"A('{s}','y',{t:.3f},0.5,170,0,'o4');",
                    f"A('{s}','s',{t:.3f},0.5,0.9,1,'o4');"]
        return y

    def scroll(self, keys):
        """keys: [(t, dur, target_scroll)] -> scroll track on the inner thread."""
        prev = 0
        self.js.append(f"A('#{self.sid}-thi','y',0,0,0,0);")
        for t, d, v in keys:
            self.js.append(f"A('#{self.sid}-thi','y',{t:.3f},{d},{prev},{v},'io3');")
            prev = v

    def fade(self, keys, t, d=0.3):
        for k in keys:
            self.js.append(f"A('#{self.sid}-{k}','o',{t:.3f},{d},1,0,'o2');")

    def top_of(self, key):
        return self.items[key][0]

    def bottom_of(self, key):
        y, h = self.items[key]
        return y + h


def composer(sid):
    return (f'<div id="{sid}-cmp" class="cmp"><span class="cmp-plus">{icon("h-plus-sign")}</span>'
            f'<span class="cmp-ph">Ask me anything</span><span class="cmp-send">{icon("h-arrow-right01")}</span></div>')


def composer_js(sid, t_in, t_out):
    s = f"#{sid}-cmp"
    return (f"A('{s}','o',{t_in:.3f},0.2,0,1,'o2');A('{s}','y',{t_in:.3f},0.4,60,0,'o3');"
            f"A('{s}','o',{t_out:.3f},0.2,1,0,'i2');A('{s}','y',{t_out:.3f},0.3,0,80,'i2');")


# ---------------------------------------------------------------- app card CSS (dark surface, zoom 2)
CARD_CSS = """
    .card-w { position: absolute; opacity: 0; }
    .ac { zoom: 2.1; --fg: #E8E4D8; --fg85: rgba(232, 228, 216, 0.85); --fg70: rgba(232, 228, 216, 0.72); --fg55: rgba(232, 228, 216, 0.6);
      --fg30: rgba(232, 228, 216, 0.3); --fg15: rgba(232, 228, 216, 0.15); --bg: #262624; --lift: #333330; --acc: #D97757;
      position: relative; width: 460px; padding: 18px 20px 20px; border-radius: 22px; background: var(--bg); color: var(--fg);
      font-family: "Ubuntu", sans-serif; font-size: 16px; line-height: 1.4; text-align: left;
      box-shadow: 0 34px 70px -30px rgba(20, 16, 8, 0.6), 0 0 0 1px rgba(255, 255, 255, 0.06); }
    .ac p { margin: 0; }
    .ac svg { flex: none; display: block; }
    .i16 { width: 16px; height: 16px; } .i18 { width: 18px; height: 18px; } .i20 { width: 20px; height: 20px; }
    /* agent timeline head: "Worked for 9s >" */
    .tl-h { display: flex; align-items: center; gap: 8px; font-size: 16px; color: var(--fg55); white-space: nowrap; }
    .tl-h .bb { width: 24px; height: 24px; border-radius: 6px; box-shadow: none; }
    .tl-h .bbs { display: inline-flex; gap: 5px; margin-left: 4px; }
    .tl-h .chev { width: 16px; height: 16px; color: var(--fg55); margin-left: auto; }
    /* agent steps while it works */
    .sc-h { display: flex; align-items: center; gap: 9px; font-size: 17px; color: var(--fg70); white-space: nowrap; }
    .sc-spin { width: 16px; height: 16px; border: 2px solid rgba(255, 255, 255, 0.16); border-top-color: var(--acc); border-radius: 50%; display: block; flex: none; }
    .sc-row { position: relative; display: flex; align-items: center; gap: 11px; margin-top: 12px; padding: 10px 12px; border-radius: 14px; background: var(--lift); border: 1px solid var(--fg15);
      font-size: 17px; color: var(--fg70); white-space: nowrap; opacity: 0; }
    .sc-row b { font-weight: 500; color: var(--fg); font-family: "Chuk Chat Mono", monospace; }
    .sc-row .bb { width: 30px; height: 30px; border-radius: 8px; box-shadow: none; }
    .sc-st { position: relative; margin-left: auto; width: 22px; height: 22px; }
    .sc-st > * { position: absolute; inset: 0; }
    .sc-ok { color: #86C795; opacity: 0; }
    .sc-ok svg { width: 22px; height: 22px; }
    /* plan answer */
    .pl-lead { margin-top: 14px !important; font-family: "Chuk Chat Mono", monospace; font-size: 17px; color: var(--fg85); }
    .pl-row { display: flex; align-items: center; gap: 12px; margin-top: 12px; padding: 12px 12px 12px 12px; border-radius: 14px; background: var(--lift); border: 1px solid var(--fg15); }
    .pl-day { flex: none; width: 58px; height: 40px; border-radius: 10px; background: rgba(217, 119, 87, 0.2); color: #F0A585; display: flex; align-items: center; justify-content: center;
      font-size: 17px; font-weight: 700; letter-spacing: 0.02em; }
    .pl-t { flex: 1; min-width: 0; font-family: "Chuk Chat Mono", monospace; font-size: 17px; color: var(--fg); white-space: nowrap; }
    .pl-row .bb { width: 30px; height: 30px; border-radius: 8px; box-shadow: none; }
    .pl-pri { flex: none; padding: 2px 8px; border-radius: 7px; background: rgba(229, 115, 115, 0.18); color: #F2A2A2; font-size: 16px; font-weight: 600; }
    /* artifact panel with the PDF page */
    .ap-h { display: flex; align-items: center; gap: 9px; height: 34px; font-size: 17px; white-space: nowrap; }
    .ap-h b { font-weight: 600; }
    .ap-h .ap-doc { color: var(--acc); }
    .ap-type { padding: 2px 8px; border-radius: 6px; background: rgba(217, 119, 87, 0.16); color: #F0A585; font-size: 16px; font-weight: 500; }
    .ap-dl { margin-left: auto; display: inline-flex; align-items: center; gap: 5px; color: var(--acc); font-size: 16px; font-weight: 600; }
    .ap-b { margin-top: 12px; padding: 16px; border-radius: 12px; background: #1E1E1C; }
    .pg { padding: 22px 24px 20px; background: #FFFFFF; color: #29251F; font-family: "Ubuntu", sans-serif; font-size: 16px; border-radius: 3px; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35); }
    .pg-from { margin: 0 0 14px !important; font-size: 16px; line-height: 1.35; color: #6A6358; }
    .pg-l { display: block; }
    .pg-top { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 10px; padding-bottom: 7px; border-bottom: 2px solid #29251F; }
    .pg-top b { font-size: 30px; letter-spacing: -0.02em; }
    .pg-top span { font-family: "Chuk Chat Mono", monospace; font-size: 16px; color: #6F685C; }
    .pg-to { margin: 0 0 10px !important; color: #4F493F; }
    .pg-row { display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid #E7E1D6; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .pg-tot { padding-top: 11px; border-bottom: 0; font-size: 20px; font-weight: 800; }
    /* email card */
    .ml { overflow: hidden; border: 1px solid rgba(217, 119, 87, 0.3); border-radius: 14px; background: #2D2D2B; }
    .ml-h { display: flex; align-items: center; gap: 9px; padding: 11px 14px; background: rgba(217, 119, 87, 0.1); font-size: 17px; font-weight: 600; white-space: nowrap; }
    .ml-h svg { color: var(--acc); }
    .ml-b { padding: 11px 14px 14px; }
    .ml-row { display: flex; font-size: 16px; white-space: nowrap; }
    .ml-row span { width: 36px; font-weight: 500; color: rgba(232, 228, 216, 0.6); }
    .ml-t { margin: 9px 0 12px !important; font-size: 16px; line-height: 1.45; color: rgba(232, 228, 216, 0.84); }
    .ml-t .w { opacity: 0; }
    .ml-att { display: inline-flex; align-items: center; gap: 7px; margin-bottom: 12px; padding: 6px 11px 6px 8px; border-radius: 10px; background: rgba(0, 0, 0, 0.22); font-size: 16px; font-weight: 500; white-space: nowrap; }
    .ml-att svg { color: var(--acc); }
    .ml-btn { display: flex; align-items: center; justify-content: center; gap: 7px; padding: 11px; border-radius: 100px; background: var(--acc); color: #fff; font-size: 17px; font-weight: 500; }
"""


def plan_card():
    rows = [("Mon", "Fix the login bug", "linear", True), ("Tue", "Send the report", "todoist", False),
            ("Thu", "Review the launch plan", "notion", False)]
    rh = ""
    for i, (d, t, src, pri) in enumerate(rows):
        p = '<span class="pl-pri">High</span>' if pri else ""
        rh += f'<div class="pl-row pl-r{i}"><span class="pl-day">{d}</span><span class="pl-t">{esc(t)}</span>{p}{brand_badge(src)}</div>'
    bbs = "".join(brand_badge(n) for n in ("linear", "todoist", "notion"))
    return f"""<div class="ac pl">
      <p class="tl-h">Worked for 9s<span class="bbs">{bbs}</span>{icon("h-arrow-right01", "chev")}</p>
      <p class="pl-lead">Your week, in order:</p>
      {rh}
    </div>"""


def steps_card():
    rows = [("linear", "linear list issues"), ("todoist", "todoist find-tasks"), ("notion", "notion search")]
    rh = ""
    for i, (b, t) in enumerate(rows):
        rh += (f'<div class="sc-row sc-r{i}">{brand_badge(b)}<span>Ran <b>{esc(t)}</b></span>'
               f'<span class="sc-st"><i class="sc-spin sc-sp{i}"></i><span class="sc-ok sc-k{i}">{icon("h-tick02")}</span></span></div>')
    return f"""<div class="ac sc">
      <p class="sc-h"><i class="sc-spin sc-sph"></i>Working …</p>
      {rh}
    </div>"""


PLAN_H = 2.1 * (18 + 24 + 14 + 24 + 3 * (12 + 66) + 20)


def pdf_card():
    return f"""<div class="ac ap">
      <div class="ap-h">{icon("h-pdf", "i20 ap-doc")}<b>Invoice Mrs Weber</b><span class="ap-type">PDF</span>
        <span class="ap-dl">{icon("h-download01", "i18")}Download</span></div>
      <div class="ap-b"><div class="pg">
        <p class="pg-from"><span class="pg-l">Brandt Carpentry</span><span class="pg-l">Hafenstraße 12 · 24103 Kiel</span></p>
        <div class="pg-top"><b>Invoice</b><span>No. 2026-031</span></div>
        <p class="pg-to">Mrs Weber</p>
        <div class="pg-row pg-r0"><span>Kitchen shelf, labour 6 h × €58</span><span>€348.00</span></div>
        <div class="pg-row pg-r1"><span>Material</span><span>€140.00</span></div>
        <div class="pg-row pg-tot"><span>Total</span><span class="pg-sum">€488.00</span></div>
      </div></div>
    </div>"""


PDF_H = 915  # measured on the rendered frame (card 560-1475 px)

MAIL_BODY = ("Dear Mrs Weber, thank you for your order. Here is the invoice for the kitchen shelf. "
             "Total: €488.00, payable within 14 days. Kind regards, Jan Brandt")


def mail_card():
    return f"""<div class="ac mlc">
      <div class="ml">
        <p class="ml-h">{icon("h-email", "i20")}Your invoice 2026-031</p>
        <div class="ml-b">
          <p class="ml-row"><span>To</span>weber@example.de</p>
          <p class="ml-t">{words_html(MAIL_BODY)}</p>
          <span class="ml-att">{icon("h-pdf", "i18")}Invoice Mrs Weber.pdf</span>
          <p class="ml-btn">{icon("h-link01", "i18")}Open in Mail App</p>
        </div>
      </div>
    </div>"""


MAIL_H = 2.1 * (18 + 44 + 11 + 22 + 9 + 5 * 23.2 + 12 + 38 + 12 + 44 + 14 + 20 + 2)


# ---------------------------------------------------------------- week scene (11.0-19.5)
def week():
    sid = "wk"
    statuses = [(12.0, 12.5, st_dots(), "is typing"),
                (13.9, 14.5, st_dots(), "is working"),
                (14.5, 15.25, st_logo("linear"), "Checking Linear…"),
                (15.25, 16.0, st_logo("todoist"), "Checking Todoist…"),
                (16.0, 16.65, st_logo("notion"), "Checking Notion…"),
                (16.65, 17.15, st_icon("h-sparkles"), "Making your plan")]
    th = Thread(sid)
    th.user("u1", "This week is a mess.", 11.4)
    th.assistant("a1", "Want me to sort it?", 12.5)
    th.dots("d1", 12.0, 12.52, slot_key="a1")
    th.user("u2", "Check Linear, Todoist and Notion. Make me a plan.", 13.25)
    y_card = th.reserve("slot", 116)
    th.dots("d2", 13.95, 14.45, slot_key="slot")
    th.html.append(f'<div id="{sid}-steps" class="card-w" style="left:{CARD_X}px;top:{y_card}px">{steps_card()}</div>')
    th.js += [f"A('#{sid}-steps','o',14.45,0.15,0,1,'o2');", f"A('#{sid}-steps','y',14.45,0.4,60,0,'o3');",
              f"A('#{sid}-steps','o',16.95,0.2,1,0,'i2');", "spin('#wk-steps .sc-sph');"]
    for i, (t0, t1) in enumerate([(14.5, 15.25), (15.25, 16.0), (16.0, 16.7)]):
        th.js += [f"A('#{sid}-steps .sc-r{i}','o',{t0:.3f},0.15,0,1,'o2');", f"A('#{sid}-steps .sc-r{i}','x',{t0:.3f},0.35,-30,0,'o3');",
                  f"spin('#wk-steps .sc-sp{i}');", f"A('#{sid}-steps .sc-sp{i}','o',{t1:.3f},0.1,1,0,'lin');",
                  f"A('#{sid}-steps .sc-k{i}','o',{t1:.3f},0.12,0,1,'o2');", f"A('#{sid}-steps .sc-k{i}','s',{t1:.3f},0.3,0.4,1,'bk');"]
    th.items.pop("slot")
    th.y = y_card - 34
    th.last_who = "u"
    th.card("plan", plan_card(), PLAN_H, 17.0, x=CARD_X)
    y_plan = th.top_of("plan")
    th.scroll([(16.9, 0.55, -(y_plan - THREAD_Y0))])
    th.fade(["u1", "a1", "u2"], 16.9)
    rows_js = "".join(f"A('#{sid}-plan .pl-r{i}','o',{17.125 + i * 0.125:.3f},0.2,0,1,'o2');"
                      f"A('#{sid}-plan .pl-r{i}','x',{17.125 + i * 0.125:.3f},0.4,-40,0,'o3');" for i in range(3))
    html = f"""
    <div id="s-{sid}" class="clip scene" data-start="11" data-duration="8.55" data-track-index="1">
      <div class="th"><div id="{sid}-thi" class="th-in">{"".join(th.html)}</div></div>
      {composer(sid)}
      {avatar(sid, statuses)}
    </div>"""
    js = "\n".join(th.js) + "\n" + avatar_js(sid, 11.0, statuses) + "\n" + composer_js(sid, 11.05, 12.95) + "\n" + rows_js + f"""
  A('#s-{sid} .th','o',19.2,0.25,1,0,'i2');
  A('#s-{sid} .th','y',19.2,0.3,0,60,'i2');
"""
    return html, js


# ---------------------------------------------------------------- invoice scene (25.0-35.5)
def invoice():
    sid = "iv"
    statuses = [(26.15, 27.0, st_dots(), "is working"),
                (27.0, 28.7, st_icon("h-pdf"), "Compiling document"),
                (31.55, 33.15, st_icon("h-email"), "Writing email")]
    th = Thread(sid)
    th.user("u1", "Write the invoice for Mrs Weber: kitchen shelf, 6 hours at €58, material €140. As PDF.", 25.3)
    y_slot = th.reserve("slot", 116)
    th.dots("d1", 26.2, 27.8, slot_key="slot")
    th.items.pop("slot")
    th.y = y_slot - 34
    th.last_who = "u"
    th.card("pdf", pdf_card(), PDF_H, 27.8, x=CARD_X)
    th.user("u2", "Now email it to her.", 31.0)
    y_slot2 = th.reserve("slot2", 116)
    th.dots("d2", 31.6, 33.0, slot_key="slot2")
    th.items.pop("slot2")
    th.y = y_slot2 - 34
    th.last_who = "u"
    th.card("mail", mail_card(), MAIL_H, 33.0, x=CARD_X)
    s_pdf = -(th.top_of("pdf") - THREAD_Y0)
    s_u2 = -(th.bottom_of("u2") + 34 + 116 + 60 - 1780)
    s_mail = -(th.top_of("u2") - THREAD_Y0)
    keys = [(27.7, 0.55, s_pdf)]
    if s_u2 < s_pdf:
        keys.append((30.9, 0.5, s_u2))
    keys.append((32.9, 0.55, s_mail))
    th.scroll(keys)
    th.fade(["u1"], 27.7)
    th.fade(["pdf"], 32.9)
    pj = f"""
  A('#{sid}-pdf .pg-r0','o',28.3,0.2,0,1,'o2'); A('#{sid}-pdf .pg-r0','x',28.3,0.35,-24,0,'o3');
  A('#{sid}-pdf .pg-r1','o',28.55,0.2,0,1,'o2'); A('#{sid}-pdf .pg-r1','x',28.55,0.35,-24,0,'o3');
  A('#{sid}-pdf .pg-tot','o',28.8,0.2,0,1,'o2');
  count('#{sid}-pdf .pg-sum', 0, 488, 28.8, 29.5, eur);
  A('#{sid}-pdf .pg-tot','s',29.5,0.35,1.06,1,'bk');
  stream('#{sid}-mail .ml-t', 33.35, 26);
  A('#{sid}-mail .ml-att','o',34.2,0.2,0,1,'o2'); A('#{sid}-mail .ml-att','s',34.2,0.35,0.7,1,'bk');
  A('#{sid}-mail .ml-btn','o',34.45,0.2,0,1,'o2'); A('#{sid}-mail .ml-btn','s',34.45,0.4,0.85,1,'bk');
  A('#s-{sid} .th','o',35.2,0.25,1,0,'i2');
  A('#s-{sid} .th','y',35.2,0.3,0,60,'i2');
"""
    html = f"""
    <div id="s-{sid}" class="clip scene" data-start="25" data-duration="10.55" data-track-index="1">
      <div class="th"><div id="{sid}-thi" class="th-in">{"".join(th.html)}</div></div>
      {composer(sid)}
      {avatar(sid, statuses)}
    </div>"""
    js = "\n".join(th.js) + "\n" + avatar_js(sid, 25.0, statuses) + "\n" + composer_js(sid, 25.02, 26.9) + pj
    return html, js, th
