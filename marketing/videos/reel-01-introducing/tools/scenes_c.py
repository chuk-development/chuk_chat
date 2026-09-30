"""Scenes: Android assistant (the one phone frame), Connect your apps,
the last "AI that" list and the end card."""
from common import BRANDS, Icon, Word, emoji, esc, glyph, kinetic, logo_svg, tile, words_html
from icons import icon

# ---------------------------------------------------------------- Android (41.0-47.6)
PH_Z = 1.72
PH_W, PH_H = 411, 891
PH_X = round((1080 - PH_W * PH_Z) / 2)
PH_Y = 196

PHONE_CSS = f"""
    .phw {{ position: absolute; left: {PH_X}px; top: {PH_Y}px; width: {PH_W * PH_Z:.0f}px; height: {PH_H * PH_Z:.0f}px; opacity: 0; transform-origin: 50% 58%; }}
    .ph {{ position: relative; width: {PH_W}px; height: {PH_H}px; zoom: {PH_Z}; padding: 8px; border-radius: 50px; background: #0B0C10;
      font-family: "Ubuntu", sans-serif; text-align: left; color: #E8E4D8;
      box-shadow: inset 0 0 0 1.5px #2A2C33, 0 0 0 1px rgba(255, 255, 255, 0.08), 0 40px 80px -30px rgba(38, 30, 20, 0.55); }}
    .ph p {{ margin: 0; }}
    .ph svg {{ display: block; flex: none; }}
    .ph-screen {{ position: relative; height: 100%; overflow: hidden; border-radius: 42px;
      background: radial-gradient(circle at 70% 26%, rgba(255, 196, 150, 0.95) 0, rgba(246, 160, 122, 0.9) 58px, rgba(236, 140, 118, 0) 64px),
        radial-gradient(90% 40% at 0% 62%, rgba(118, 98, 186, 0.5), transparent 70%),
        linear-gradient(176deg, #171A36 0%, #2B2B58 26%, #5A447A 50%, #A25F7E 72%, #D98172 100%); }}
    .ph-screen::before, .ph-screen::after {{ content: ""; position: absolute; z-index: 0; border-radius: 50%; }}
    .ph-screen::before {{ left: -40%; top: 47%; width: 150%; height: 40%; background: linear-gradient(180deg, #6B4379 0%, #8E5378 45%, #B56A78 100%); transform: rotate(-8deg); }}
    .ph-screen::after {{ left: 20%; top: 58%; width: 130%; height: 50%; background: linear-gradient(180deg, #7E4A76 0%, #A65E77 50%, #CF7C74 100%); transform: rotate(10deg); }}
    .ph-status {{ position: absolute; z-index: 1; left: 0; right: 0; top: 0; height: 42px; display: flex; align-items: center; justify-content: space-between; padding: 2px 26px 0 30px; font-size: 20px; font-weight: 500; color: #fff; }}
    .ph-cam {{ position: absolute; left: 50%; top: 11px; width: 20px; height: 20px; margin-left: -10px; border-radius: 50%; background: #050506; box-shadow: inset 0 0 0 3px #111217; }}
    .ph-sys {{ display: flex; align-items: center; gap: 5px; }}
    .ph-sys svg {{ width: 16px; height: 16px; }}
    .ph-glance {{ position: absolute; z-index: 1; left: 28px; top: 66px; display: flex; align-items: center; gap: 10px; font-size: 22px; color: #fff; white-space: nowrap; }}
    .ph-glance i {{ width: 1px; height: 22px; background: rgba(255, 255, 255, 0.55); }}
    .ph-glance svg {{ width: 22px; height: 22px; color: #E8EAF2; }}
    .ph-grid {{ position: absolute; z-index: 1; left: 14px; right: 14px; top: 140px; display: grid; grid-template-columns: repeat(4, 1fr); justify-items: center; row-gap: 22px; }}
    .ph-ic {{ width: 58px; height: 58px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #33262F; color: #FFB8A1; }}
    .ph-ic svg {{ width: 28px; height: 28px; }}
    .ph-bar {{ position: absolute; left: 50%; bottom: 8px; z-index: 5; width: 100px; height: 4px; margin-left: -50px; border-radius: 2px; background: rgba(255, 255, 255, 0.85); }}
    .ph-hold {{ position: absolute; left: 50%; bottom: -24px; z-index: 4; width: 110px; height: 110px; margin-left: -55px; border-radius: 50%; background: rgba(255, 255, 255, 0.28);
      box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.6); opacity: 0; }}
    .as-scrim {{ position: absolute; inset: 0; z-index: 1; background: rgba(12, 10, 18, 0.45); opacity: 0; }}
    .as-st {{ position: absolute; z-index: 2; left: 18px; right: 18px; bottom: 150px; display: flex; flex-direction: column; opacity: 0; }}
    .as-dock {{ position: absolute; z-index: 2; left: 18px; right: 18px; bottom: 26px; display: flex; flex-direction: column; opacity: 0; }}
    .as-panel {{ margin-bottom: 10px; padding: 16px 18px; border: 1px solid rgba(232, 228, 216, 0.16); border-radius: 22px; background: rgba(38, 38, 36, 0.97); }}
    .as-brand {{ font-size: 19px; line-height: 1.2; letter-spacing: 2px; color: rgba(232, 228, 216, 0.84); }}
    .as-status {{ margin-top: 6px !important; font-size: 30px; line-height: 1.15; font-weight: 500; }}
    .as-heard {{ margin-top: 8px !important; font-size: 24px; line-height: 1.3; color: #F09A7C; }}
    .as-heard .w {{ opacity: 0; }}
    .as-answer {{ margin-top: 8px !important; font-size: 22px; line-height: 1.34; color: rgba(232, 228, 216, 0.92); }}
    .as-answer .w {{ opacity: 0; }}
    .as-answer b {{ font-weight: 700; color: #fff; }}
    .as-tool {{ display: flex; align-items: center; gap: 10px; padding: 3px 0; font-size: 22px; line-height: 1.3; color: rgba(232, 228, 216, 0.92); white-space: nowrap; }}
    .as-tic {{ flex: none; width: 26px; height: 26px; display: flex; align-items: center; justify-content: center; color: #86C795; }}
    .as-tic svg {{ width: 24px; height: 24px; }}
    .as-spin {{ width: 22px; height: 22px; border: 3px solid transparent; border-top-color: #D97757; border-right-color: #D97757; border-radius: 50%; display: block; }}
    .as-card-h {{ display: flex; align-items: center; gap: 8px; margin-bottom: 4px; font-size: 23px; font-weight: 700; }}
    .as-card-h svg {{ width: 22px; height: 22px; color: #D97757; }}
    .as-place {{ position: relative; display: flex; flex-direction: column; gap: 2px; padding: 9px 0; border-top: 1px solid rgba(232, 228, 216, 0.14); white-space: nowrap; }}
    .as-pr1 {{ display: flex; align-items: center; gap: 10px; }}
    .as-pr1 > b {{ flex: 1; min-width: 0; font-size: 22px; font-weight: 700; }}
    .as-place small {{ font-size: 19px; color: rgba(232, 228, 216, 0.84); }}
    .as-rate {{ display: flex; align-items: center; gap: 3px; font-size: 19px; font-weight: 700; }}
    .as-rate svg {{ width: 18px; height: 18px; color: #F4B642; }}
    .as-nav {{ width: 22px; height: 22px; color: #D97757; }}
    .as-tap {{ position: absolute; left: 150px; top: 50%; width: 60px; height: 60px; margin: -30px 0 0 -30px; border-radius: 50%; background: rgba(255, 255, 255, 0.35); opacity: 0; }}
    .as-action {{ display: flex; align-items: center; gap: 14px; }}
    .as-action-ic {{ flex: none; width: 50px; height: 50px; border-radius: 50%; background: rgba(217, 119, 87, 0.2); color: #F09A7C; display: flex; align-items: center; justify-content: center; }}
    .as-action-ic svg {{ width: 26px; height: 26px; }}
    .as-action-t {{ display: flex; flex-direction: column; gap: 2px; white-space: nowrap; }}
    .as-action-t b {{ font-size: 24px; font-weight: 700; }}
    .as-action-t small {{ font-size: 21px; color: rgba(232, 228, 216, 0.84); }}
    .as-wave {{ display: flex; align-items: center; justify-content: center; gap: 5.4px; height: 58px; padding: 8px 20px; }}
    .as-wave i {{ flex: none; width: 4.6px; height: 8px; border-radius: 4px; background: #D97757; display: block; }}
    .as-btns {{ display: flex; align-items: center; gap: 10px; height: 52px; }}
    .as-round {{ flex: none; width: 52px; height: 52px; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: rgba(76, 76, 72, 0.92); }}
    .as-round svg {{ width: 24px; height: 24px; }}
    .as-pill {{ position: relative; flex: 1; height: 52px; display: flex; align-items: center; justify-content: center; gap: 8px; border-radius: 26px; background: #D97757; color: #FFFFFF; font-size: 21px; font-weight: 600; }}
    .as-pill svg {{ width: 22px; height: 22px; }}
    .as-pill > span {{ display: inline-flex; align-items: center; gap: 8px; }}
"""

ENV = [0.142, 0.282, 0.415, 0.541, 0.655, 0.756, 0.841, 0.91, 0.959, 0.99, 1, 0.99, 0.959, 0.91,
       0.841, 0.756, 0.655, 0.541, 0.415, 0.282, 0.142]

PLACES = [("Pharmacy at the market", "Marktplatz 4 · open until 20:00", "4.7"),
          ("Linden Pharmacy", "Lindenstraße 21 · open until 19:00", "4.5"),
          ("Harbour Pharmacy", "Kaistraße 8 · open until 18:30", "4.4")]


def android():
    sid = "an"
    heard = "Find a pharmacy that is open now."
    grid = ["h-calendar01", "h-clock01", "h-image01", "asst-sun", "asst-note", "asst-folder", "h-settings02", "asst-logo"]
    gridh = "".join(f'<span class="ph-ic">{icon(g)}</span>' for g in grid)
    check = icon("asst-check")
    bars = "".join("<i></i>" for _ in ENV)
    places = "".join(
        f'<div class="as-place an-pl{i}"><div class="as-pr1"><b>{esc(n)}</b>'
        f'<span class="as-rate">{icon("asst-star")}<b>{r}</b></span></div><small>{esc(m)}</small>'
        + ('<span class="as-tap an-tap"></span>' if i == 0 else "") + '</div>'
        for i, (n, m, r) in enumerate(PLACES))
    answer = ('The closest is <b>Pharmacy at the market</b>, 400 m away. Navigation is running.')
    ans_html = "".join(f'<span class="w">{p}</span>' for p in
                       ["The ", "closest ", "is ", "<b>Pharmacy ", "at ", "the ", "market</b>, ", "400 ", "m ", "away. ",
                        "Navigation ", "is ", "running."])
    assert answer
    phone = f"""<div class="ph"><div class="ph-screen">
      <div class="ph-status"><span>18:42</span><span class="ph-cam"></span><span class="ph-sys">{icon("asst-wifi")}{icon("asst-cell")}{icon("asst-battery")}</span></div>
      <div class="ph-glance"><span>Fri, Sep 25</span><i></i>{icon("asst-cloud")}<span>14°C</span></div>
      <div class="ph-grid">{gridh}</div>
      <div class="as-scrim an-scrim"></div>
      <div class="as-st an-sA">
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Listening</p><p class="as-heard an-heard">{words_html("“" + heard + "”")}</p></div>
      </div>
      <div class="as-st an-sB">
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Working …</p></div>
        <div class="as-panel">
          <p class="as-tool an-t1"><span class="as-tic">{check}</span>Location</p>
          <p class="as-tool an-t2"><span class="as-tic"><i class="as-spin an-spin"></i></span>Places: Pharmacy</p>
        </div>
      </div>
      <div class="as-st an-sC">
        <div class="as-panel"><div class="as-card-h">{icon("h-location01")}<b>Pharmacy</b></div>{places}</div>
      </div>
      <div class="as-st an-sD">
        <div class="as-panel an-act"><div class="as-action"><span class="as-action-ic">{icon("asst-nav-r")}</span>
          <span class="as-action-t"><b>Navigation started</b><small>Pharmacy at the market</small></span></div></div>
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-heard">“{esc(heard)}”</p>
          <p class="as-answer an-ans">{ans_html}</p></div>
      </div>
      <div class="as-dock an-dock">
        <div class="as-panel as-wave an-wave">{bars}</div>
        <div class="as-btns"><span class="as-round">{icon("h-plus-sign")}</span>
          <span class="as-pill">{icon("h-mic02")}<span class="an-p0">Pause</span><span class="an-p1">Working …</span><span class="an-p2">Pause</span></span>
          <span class="as-round">{icon("h-cancel01")}</span></div>
      </div>
      <span class="ph-hold an-hold"></span>
      <span class="ph-bar"></span>
    </div></div>"""
    title_lines = [[Word("Hold", 41.0), Word("the", 41.08)], [Word("home", 41.25), Word("button.", 41.33)]]
    kh, kj = kinetic("k4", title_lines, [720, 852], t_out=None)
    html = f"""
    <div id="s-{sid}" class="clip scene" data-start="41" data-duration="6.65" data-track-index="1">
      <div id="an-title">{kh}</div>
      <div id="an-phw" class="phw">{phone}</div>
    </div>"""
    env = "[" + ",".join(str(e) for e in ENV) + "]"
    js = kj + f"""
  // title card, then the phone rises; the title leaves upward
  A('#an-title', 'o', 41.8, 0.2, 1, 0, 'i2');
  A('#an-title', 'y', 41.8, 0.3, 0, -90, 'i2');
  A('#an-phw', 'o', 42.0, 0.2, 0, 1, 'o2');
  A('#an-phw', 'y', 42.0, 0.65, 900, 0, 'o4');
  A('#an-phw', 's', 42.95, 0.75, 1, 1.08, 'io3');
  A('#an-phw', 'y', 47.0, 0.36, 0, 1850, 'i3');
  // hold the home handle
  A('.an-hold', 'o', 42.55, 0.12, 0, 1, 'o2');
  A('.an-hold', 's', 42.55, 0.45, 0.3, 1.3, 'o3');
  A('.an-hold', 'o', 42.95, 0.2, 1, 0, 'i2');
  A('.an-scrim', 'o', 42.8, 0.3, 0, 1, 'o2');
  A('.an-dock', 'o', 42.8, 0.2, 0, 1, 'o2'); A('.an-dock', 'y', 42.8, 0.4, 60, 0, 'o3');
  // A listening
  A('.an-sA', 'o', 42.95, 0.2, 0, 1, 'o2'); A('.an-sA', 'y', 42.95, 0.4, 40, 0, 'o3');
  stream('.an-heard', 43.1, 7);
  show('.an-sA', 0, 43.9);
  // B working
  show('.an-sB', 43.9, 44.6);
  A('.an-sB', 'o', 43.9, 0.15, 0, 1, 'o2'); A('.an-sB', 'y', 43.9, 0.3, 24, 0, 'o3');
  A('.an-t1', 'o', 43.98, 0.15, 0, 1, 'o2'); A('.an-t2', 'o', 44.15, 0.15, 0, 1, 'o2');
  spin('.an-spin');
  // C places
  show('.an-sC', 44.6, 45.75);
  A('.an-sC', 'o', 44.6, 0.15, 0, 1, 'o2'); A('.an-sC', 'y', 44.6, 0.35, 30, 0, 'o3');
  A('.an-pl0', 'o', 44.7, 0.18, 0, 1, 'o2'); A('.an-pl1', 'o', 44.83, 0.18, 0, 1, 'o2'); A('.an-pl2', 'o', 44.96, 0.18, 0, 1, 'o2');
  A('.an-pl0', 'x', 44.7, 0.35, 30, 0, 'o3'); A('.an-pl1', 'x', 44.83, 0.35, 30, 0, 'o3'); A('.an-pl2', 'x', 44.96, 0.35, 30, 0, 'o3');
  A('.an-tap', 'o', 45.5, 0.08, 0, 1, 'o2'); A('.an-tap', 's', 45.5, 0.3, 0.4, 1.4, 'o3'); A('.an-tap', 'o', 45.65, 0.12, 1, 0, 'i2');
  A('.an-pl0', 's', 45.48, 0.1, 1, 0.97, 'o2'); A('.an-pl0', 's', 45.6, 0.2, 0.97, 1, 'o2');
  // D navigation started + answer
  show('.an-sD', 45.75, 99);
  A('.an-sD', 'o', 45.75, 0.15, 0, 1, 'o2'); A('.an-sD', 'y', 45.75, 0.35, 30, 0, 'o3');
  A('.an-act', 's', 45.75, 0.45, 0.88, 1, 'bk');
  stream('.an-ans', 45.95, 16);
  show('.an-p0', 0, 43.9); show('.an-p1', 43.9, 45.75); show('.an-p2', 45.75, 99);
  (function () {{
    var env = {env};
    var bars = $$('.an-wave i');
    U(function (t) {{
      if (t < 42.5 || t > 47.7) return;
      var busy = t >= 43.9 && t < 45.75;
      var talk = t >= 43.0 && t < 43.9;
      var level = talk ? 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3)) : 0.1;
      for (var i = 0; i < bars.length; i++) {{
        var wave = 0.5 + 0.5 * Math.sin((t / 1.8) * Math.PI * 2 + i * 0.8);
        var h = busy ? 4 + 8 * wave : Math.min(38, 4 + (3 + 31 * level) * env[i] * (0.45 + 0.55 * wave));
        bars[i].style.height = h.toFixed(2) + 'px';
        bars[i].style.background = busy ? 'rgba(232,228,216,0.52)' : '#D97757';
      }}
    }});
  }})();
"""
    return html, PHONE_CSS, js


# ---------------------------------------------------------------- Connect your apps (49.0-53.0)
LOGOS = [("notion", -250, -205, 200), ("linear", 235, -215, 180), ("github", 300, 30, 212),
         ("todoist", 120, 255, 184), ("dropbox", -170, 230, 196), ("figma", -305, 15, 172)]
CX, CY = 540, 1236


def connect():
    sid = "cn"
    circ = []
    for i, (n, dx, dy, s) in enumerate(LOGOS):
        bg = BRANDS[n][0]
        ring = "box-shadow: 0 0 0 2px rgba(38,37,31,0.08), 0 18px 36px -18px rgba(38,37,31,0.45);"
        circ.append(f'<div id="cn-l{i}" class="cn-p" style="left:{CX - s / 2:.0f}px;top:{CY - s / 2:.0f}px;width:{s}px;height:{s}px">'
                    f'<span class="cn-b" style="background:{bg};{ring}">{glyph(n, "cn-g")}</span>'
                    f'<svg class="cn-k" viewBox="0 0 120 120"><circle cx="60" cy="60" r="52"/><path d="M38 61 L53 76 L83 45"/></svg></div>')
    l1 = [[Word("Connect", 49.0)], [Word("your", 49.12), Word("apps", 49.2)]]
    k1h, k1j = kinetic("k5", l1, [650, 782], t_out=50.95, out_stagger=0.03)
    ring = ('<svg class="cn-ik" viewBox="0 0 120 120"><circle cx="60" cy="60" r="50"/><path d="M38 61 L53 76 L83 45"/></svg>')
    l2 = [[Word("All", 51.2), Word("in", 51.26)], [Word("one", 51.4), Word("place", 51.48), Icon(ring, 51.75, box=104)]]
    k2h, k2j = kinetic("k6", l2, [650, 782], t_out=52.55, out_stagger=0.03)
    html = f"""
    <div id="s-{sid}" class="clip scene" data-start="49" data-duration="4.05" data-track-index="2">
      {k1h}{k2h}
      {"".join(circ)}
    </div>"""
    js = [k1j, k2j]
    for i, (n, dx, dy, s) in enumerate(LOGOS):
        t = 49.15 + i * 0.09
        el = f"#cn-l{i}"
        js += [f"A('{el}','x',{t:.3f},0.65,{dx * 2.6:.0f},{dx},'o4');", f"A('{el}','y',{t:.3f},0.65,{dy * 2.6:.0f},{dy},'o4');",
               f"A('{el}','o',{t:.3f},0.2,0,1,'o2');", f"A('{el}','s',{t:.3f},0.65,0.5,1,'o4');",
               f"A('{el}','x',50.6,0.45,{dx},{dx * 0.52:.1f},'io3');", f"A('{el}','y',50.6,0.45,{dy},{dy * 0.52:.1f},'io3');",
               f"A('{el} .cn-b','s',{51.0 + i * 0.06:.3f},0.2,1,0,'i2');",
               f"A('{el} .cn-k','s',{51.05 + i * 0.06:.3f},0.4,0,0.95,'bk');",
               f"A('{el} .cn-k','s',{52.35 + i * 0.04:.3f},0.25,0.95,0,'i2');"]
    js.append("""
  (function () {
    var P = $$('#s-cn .cn-b');
    U(function (t) {
      if (t < 49 || t > 51.3) return;
      for (var i = 0; i < P.length; i++) {
        var k = Math.min(1, Math.max(0, (t - 49.8) / 0.4)) * (1 - Math.min(1, Math.max(0, (t - 50.5) / 0.2)));
        var y = Math.sin(t * 2.6 + i * 1.3) * 10 * k;
        P[i].style.translate = '0 ' + y.toFixed(2) + 'px';
      }
    });
    var K = $$('#s-cn .cn-k');
    U(function (t) {
      if (t < 51.3 || t > 52.7) return;
      for (var i = 0; i < K.length; i++) {
        var y = Math.sin((t - 51.3) * 4.2 + i * 1.1) * 9;
        K[i].style.translate = '0 ' + y.toFixed(2) + 'px';
      }
    });
  })();
""")
    css = """
    .cn-p { position: absolute; opacity: 0; }
    .cn-b { position: absolute; inset: 0; border-radius: 50%; display: flex; align-items: center; justify-content: center; }
    .cn-g { width: 52%; height: 52%; }
    .cn-k { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; transform: scale(0); }
    .cn-k circle { fill: #FFFFFF; stroke: #D97757; stroke-width: 9; }
    .cn-k path { fill: none; stroke: #D97757; stroke-width: 10; stroke-linecap: round; stroke-linejoin: round; }
    .cn-ik { width: 100%; height: 100%; overflow: visible; }
    .cn-ik circle { fill: none; stroke: #D97757; stroke-width: 10; }
    .cn-ik path { fill: none; stroke: #D97757; stroke-width: 11; stroke-linecap: round; stroke-linejoin: round; }
"""
    return html, css, "\n".join(js)


# ---------------------------------------------------------------- last list + end card (53.0-59.7)
END_FLOATERS = [("locked", 150, 270, 118, -12), ("envelope", 930, 250, 110, 10), ("spiral_calendar", 110, 1560, 124, 8),
                ("speech_balloon", 960, 1540, 120, -8), ("laptop", 290, 1700, 104, 6), ("world_map", 800, 1720, 100, -6),
                ("bar_chart", 70, 900, 92, 10), ("receipt", 1010, 880, 92, -10)]


def ending():
    sid = "en"
    items = [("locked", "keeps your chats", "encrypted"), ("shield", "never trains", "on them")]
    mids = []
    for i, (em, a, b) in enumerate(items):
        mids.append(f'<div id="en-m{i}" class="em2"><div class="em2-l"><span class="lm-ic">{emoji(em)}</span><span class="lm-t">{esc(a)}</span></div>'
                    f'<div class="em2-l"><span class="lm-t">{esc(b)}</span></div></div>')
    fl = "".join(f'<img class="en-f en-f{i}" src="assets/emoji/{n}.png" alt="" style="left:{x - s / 2:.0f}px;top:{y - s / 2:.0f}px;width:{s}px;height:{s}px" />'
                 for i, (n, x, y, s, r) in enumerate(END_FLOATERS))
    html = f"""
    <div id="s-{sid}" class="clip scene" data-start="53" data-duration="6.7" data-track-index="1">
      {fl}
      <p id="en-a" class="hl la" style="top:{640 - 69.4:.1f}px">AI that</p>
      <div class="em2-wrap">{"".join(mids)}</div>
      <div id="en-tile" class="abs" style="left:440px;top:1060px;width:200px;height:200px">{tile("en-t")}</div>
      <p id="en-wm" class="en-wm">Chuk Chat</p>
      <p id="en-sl" class="en-sl">Private and Secure. Always.</p>
      <p id="en-url" class="en-url"><span>chuk.chat</span></p>
      <p id="en-pf" class="en-pf">Mac · Windows · Linux · Android · Web</p>
    </div>"""
    js = """
  A('#en-a','o',53.0,0.22,0,1,'o2'); A('#en-a','y',53.0,0.4,46,0,'o3');
  A('#en-m0','o',53.25,0.06,0,1,'lin'); A('#en-m0','y',53.25,0.4,240,0,'io3');
  A('#en-m0 .lm-ic','s',53.3,0.42,0.2,1,'bk'); A('#en-m0 .lm-ic','r',53.3,0.5,-18,0,'o3');
  A('#en-m0','y',54.5,0.4,0,-240,'io3');
  A('#en-m1','o',54.5,0.06,0,1,'lin'); A('#en-m1','y',54.5,0.4,240,0,'io3');
  A('#en-m1 .lm-ic','s',54.55,0.42,0.2,1,'bk'); A('#en-m1 .lm-ic','r',54.55,0.5,-18,0,'o3');
  A('#en-a','o',55.75,0.2,1,0,'i2'); A('#en-a','y',55.75,0.26,0,-34,'i2');
  A('#en-m1','o',55.8,0.2,1,0,'i2'); A('#en-m1','y',55.8,0.26,0,-34,'i2');
  // the tile appears under the list, then carries into the end card
  A('#en-tile','o',53.7,0.15,0,1,'o2'); A('#en-tile','s',53.7,0.5,0.25,0.75,'bk');
  A('#en-tile','y',55.9,0.6,0,-480,'io3'); A('#en-tile','s',55.9,0.6,0.75,1,'io3');
  A('#en-wm','o',56.3,0.25,0,1,'o2'); A('#en-wm','y',56.3,0.45,40,0,'o3');
  A('#en-sl','o',56.55,0.25,0,1,'o2'); A('#en-sl','y',56.55,0.45,40,0,'o3');
  A('#en-url','o',56.8,0.2,0,1,'o2'); A('#en-url','s',56.8,0.45,0.7,1,'bk');
  A('#en-pf','o',57.0,0.3,0,1,'o2'); A('#en-pf','y',57.0,0.45,30,0,'o3');
  A('#en-tile','s',57.0,0.3,1.06,1,'o3');
"""
    for i, (n, x, y, s, r) in enumerate(END_FLOATERS):
        t = 56.35 + i * 0.07
        dx = (x - 540) * 0.25
        dy = (y - 960) * 0.25
        js += (f"A('.en-f{i}','o',{t:.2f},0.3,0,1,'o2');A('.en-f{i}','s',{t:.2f},0.6,0.3,1,'bk');"
               f"A('.en-f{i}','x',{t:.2f},0.6,{-dx:.0f},0,'o3');A('.en-f{i}','y',{t:.2f},0.6,{-dy:.0f},0,'o3');"
               f"A('.en-f{i}','r',{t:.2f},3.4,{r * 2},{-r},'o2');"
               f"A('.en-f{i}','y',{t + 0.6:.2f},2.8,0,{-14 - i % 3 * 6},'io2');\n")
    css = """
    .em2-wrap { position: absolute; left: 0; top: 730px; width: 1080px; height: 240px; overflow: hidden; }
    .em2 { position: absolute; inset: 0; opacity: 0; }
    .em2-l { display: flex; align-items: center; justify-content: center; gap: 22px; height: 116px; white-space: nowrap; }
    .en-t { width: 200px; height: 200px; }
    .en-f { position: absolute; opacity: 0; object-fit: contain; }
    .en-wm { position: absolute; left: 0; top: 802px; width: 1080px; text-align: center; font-family: "Chuk Chat Mono", monospace; font-size: 124px; font-weight: 620;
      letter-spacing: -0.02em; line-height: 150px; color: #26251F; opacity: 0; white-space: nowrap; }
    .en-sl { position: absolute; left: 0; top: 956px; width: 1080px; text-align: center; font-size: 62px; font-weight: 360; letter-spacing: -0.02em; line-height: 80px; color: #26251F; opacity: 0; white-space: nowrap; }
    .en-url { position: absolute; left: 0; top: 1080px; width: 1080px; height: 96px; display: flex; justify-content: center; opacity: 0; }
    .en-url span { display: flex; align-items: center; height: 96px; padding: 0 44px; border-radius: 48px; background: #F3F0E8; box-shadow: 0 0 0 2px #E2DCCF;
      font-family: "Chuk Chat Mono", monospace; font-size: 52px; font-weight: 560; color: #26251F; }
    .en-pf { position: absolute; left: 0; top: 1212px; width: 1080px; text-align: center; font-size: 42px; font-weight: 440; line-height: 56px; color: #4F4D46; opacity: 0; white-space: nowrap; }
"""
    return html, css, js
