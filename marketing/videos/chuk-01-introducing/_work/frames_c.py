"""Frames 07 models, 08 on the go, 09 proof, 10 end card."""
from frames_a import PAPER_BG, logo_svg
from icons import icon
from kit import (APP_X, APP_Y, ZOOM, chrome, composer, cursor, esc, headband, page,
                 words, write)

# ---------------------------------------------------------------- 07 models
PRISM_CSS = """
    .sky-prism { background: #F7F4EF; }
    .sc-blob { position: absolute; width: 1344px; height: 1344px; border-radius: 50%; }
    .sc-blob--a { left: -480px; top: -576px; background: radial-gradient(circle, rgba(77, 107, 254, 0.4), transparent 62%); }
    .sc-blob--b { right: -538px; top: -192px; background: radial-gradient(circle, rgba(124, 92, 255, 0.34), transparent 62%); }
    .sc-blob--c { left: 192px; bottom: -768px; background: radial-gradient(circle, rgba(255, 120, 110, 0.32), transparent 62%); }
    .sc-blob--d { right: -192px; bottom: -864px; background: radial-gradient(circle, rgba(245, 165, 36, 0.3), transparent 62%); }
"""

MODELS = [("deepseek", "DeepSeek V4 Pro 0813"), ("moonshot", "Kimi K3"), ("zai", "GLM 5.3"),
          ("qwen", "Qwen3.8 27B"), ("minimax", "MiniMax M3"), ("mistral", "Mistral Small 4")]


def f07():
    fid, dur = "07-models", 6.0
    tick = icon("h-tick02", "z18")
    mn1 = f"""<div class="mn m7-mn1">
      <div class="mn-g">
        <div class="mn-row pick"><span class="mn-ic">{icon("h-flash", "z18")}</span><span class="mn-l">Fast</span><span class="mn-ic mn-tick" style="visibility:visible">{tick}</span></div>
        <div class="mn-row"><span class="mn-ic">{icon("h-ai-brain01", "z18")}</span><span class="mn-l">Thinking</span></div>
        <div class="mn-row m7-choose"><span class="mn-ic">{icon("h-settings02", "z18")}</span><span class="mn-l">Choose model</span><span class="mn-ic mn-dim">{icon("h-arrow-right01", "z18")}</span></div>
      </div></div>"""
    rows = "".join(
        f'<div class="mn-row m7-mdl m7-m-{k}"><span class="mn-logo" style="--logo: url(\'assets/logos/models/{k}.svg\')"></span>'
        f'<span class="mn-l">{esc(n)}</span><span class="mn-ic mn-tick m7-t-{k}">{tick}</span></div>'
        for k, n in MODELS)
    mn2 = f"""<div class="mn m7-mn2">
      <div class="mn-g"><div class="mn-row m7-r0"><span class="mn-ic">{icon("menu-reasoning", "i18")}</span><span class="mn-l">Reasoning</span><span class="mn-v">Low</span><span class="mn-ic mn-dim">{icon("h-arrow-right01", "z18")}</span></div></div>
      <div class="mn-g">{rows}
        <div class="mn-row m7-more"><span class="mn-ic">{icon("h-plus-sign", "z18")}</span><span class="mn-l">More models</span><span class="mn-ic mn-dim">{icon("h-arrow-right01", "z18")}</span></div>
      </div></div>"""
    pill = (f'<span class="m7-pl m7-pl0">{icon("h-flash", "z15")}<b>Fast</b></span>'
            f'<span class="m7-pl m7-pl1">{icon("h-settings02", "z15")}<b>Kimi K3</b></span>'
            f'<span class="m7-pl m7-pl2">{icon("h-settings02", "z15")}<b>Qwen3.8 27B</b></span>'
            f'{icon("h-arrow-down01", "z12 a-dn")}')
    css = PRISM_CSS + """
    .m7-cam { position: absolute; inset: 0; transform-origin: 1300px 560px; }
    .m7-pl { display: inline-flex; align-items: center; gap: 5px; }
    .m7-hover { background: rgba(255, 255, 255, 0.05); }
"""

    def block(n, ask, meta, ans):
        return (f'<div class="m7-b{n}"><div class="a-user"><p class="a-bubble">{esc(ask)}</p></div>'
                f'<div class="a-tl"><p class="a-tl-head"><span>{esc(meta)}</span>{icon("h-arrow-right01", "z16")}</p></div>'
                f'<div class="a-ai m7-a{n}"><p>{words(ans)}</p></div></div>')

    body = f"""
    <div class="clip fill sky-prism" data-start="0" data-duration="{dur}" data-track-index="0">
      <span class="sc-blob sc-blob--a m7-bl"></span><span class="sc-blob sc-blob--b m7-bl"></span>
      <span class="sc-blob sc-blob--c m7-bl"></span><span class="sc-blob sc-blob--d m7-bl"></span>
    </div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      {headband("05 — Every model, one budget", "Switch the model for each message.")}
      <div class="m7-cam">
        <div class="winpos m7-win">
          <div class="app m7-app">
            {chrome()}
            <div class="a-chat">
              <div class="a-thread"><div class="a-col">
                {block(1, "Write my cover letter for the office manager job.", "Thought for 3s", "Dear Ms Berger, I am applying for the office manager position…")}
                <div style="height:10px"></div>
                {block(2, "Translate the letter into German.", "Thought for 2s", "Sehr geehrte Frau Berger, hiermit bewerbe ich mich…")}
              </div></div>
              {composer(pill_html=pill, extra=mn1 + mn2)}
            </div>
          </div>
        </div>
        {cursor("m7")}
      </div>
    </div>"""

    def fx(lx):
        return APP_X + lx * ZOOM

    def fy(ly):
        return APP_Y + ly * ZOOM
    pillp, choose, kimi = (fx(794), fy(486.6)), (fx(687), fy(435.6)), (fx(639), fy(200.6))
    js = f"""
  headline(0.0);
  headOut(1.0);
  winIn('.m7-win', 1.0);
  $$('.m7-bl').forEach(function (b, i) {{
    tl.fromTo(b, {{ scale: 0.82, opacity: 0.35 }}, {{ scale: 1, opacity: 1, duration: 0.7, ease: 'power3.out' }}, 0);
    tl.fromTo(b, {{ x: 0, y: 0 }}, {{ x: (i % 2 ? -1 : 1) * 60, y: (i < 2 ? 1 : -1) * 40, duration: DUR, ease: 'sine.inOut', immediateRender: false }}, 0);
  }});
  var cur = $('.m7-cur'), rip = $('.m7-rip');
  tl.fromTo(cur, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.01, immediateRender: true }}, 1.1);
  cursorPath(cur, [[0, 1760, 1130], [1.5, {pillp[0]-4:.0f}, {pillp[1]-3:.0f}, 0.4],
                   [1.95, {choose[0]-4:.0f}, {choose[1]-3:.0f}, 0.32],
                   [2.72, {kimi[0]-4:.0f}, {kimi[1]-3:.0f}, 0.5],
                   [3.6, 1700, 760, 0.6]]);
  tl.set(rip, {{ x: {pillp[0]:.0f}, y: {pillp[1]:.0f} }}, 1.54);
  click(cur, rip, 1.55, '.m7-app .a-pill');
  tl.set(rip, {{ x: {choose[0]:.0f}, y: {choose[1]:.0f} }}, 1.99);
  click(cur, rip, 2.0);
  tl.set(rip, {{ x: {kimi[0]:.0f}, y: {kimi[1]:.0f} }}, 2.79);
  click(cur, rip, 2.8);
  tl.fromTo(cur, {{ opacity: 1 }}, {{ opacity: 0, duration: 0.25, immediateRender: false }}, 3.6);
  // level 1 menu
  var mn1 = $('.m7-mn1'), mn2 = $('.m7-mn2');
  tl.fromTo(mn1, {{ opacity: 0, scale: 0.96, transformOrigin: '100% 100%' }}, {{ opacity: 1, scale: 1, duration: 0.14, ease: 'power2.out' }}, 1.57);
  tl.fromTo('.m7-choose', {{ backgroundColor: 'rgba(255,255,255,0)' }}, {{ backgroundColor: 'rgba(204,204,204,0.16)', duration: 0.06, immediateRender: false }}, 1.95);
  tl.fromTo(mn1, {{ opacity: 1 }}, {{ opacity: 0, duration: 0.1, immediateRender: false }}, 2.07);
  // level 2 menu: the model list cascades
  tl.fromTo(mn2, {{ opacity: 0, scale: 0.97, transformOrigin: '100% 100%' }}, {{ opacity: 1, scale: 1, duration: 0.16, ease: 'power2.out' }}, 2.12);
  $$('.m7-mn2 .mn-row').forEach(function (r, i) {{
    tl.fromTo(r, {{ opacity: 0, x: 16 }}, {{ opacity: 1, x: 0, duration: 0.24, ease: 'power3.out' }}, 2.14 + i * 0.035);
  }});
  var km = $('.m7-m-moonshot');
  tl.fromTo(km, {{ backgroundColor: 'rgba(255,255,255,0)' }}, {{ backgroundColor: 'rgba(255,255,255,0.05)', duration: 0.1, immediateRender: false }}, 2.6);
  tl.fromTo(km, {{ backgroundColor: 'rgba(255,255,255,0.05)' }}, {{ backgroundColor: 'rgba(204,204,204,0.16)', duration: 0.06, immediateRender: false }}, 2.77);
  ups.push(function (t) {{ var on = t >= 2.8; $('.m7-t-moonshot').style.visibility = on ? 'visible' : 'hidden'; km.classList.toggle('pick', on); }});
  tl.fromTo(mn2, {{ opacity: 1 }}, {{ opacity: 0, duration: 0.14, immediateRender: false }}, 3.1);
  // the pill names the model in use
  showBetween($('.m7-pl0'), -1, 3.12);
  showBetween($('.m7-pl1'), 3.12, 4.4);
  showBetween($('.m7-pl2'), 4.4, 99);
  var pl = $('.m7-app .a-pill');
  tl.fromTo(pl, {{ scale: 1 }}, {{ scale: 1.1, duration: 0.12, ease: 'power2.out', immediateRender: false }}, 4.4);
  tl.fromTo(pl, {{ scale: 1.1 }}, {{ scale: 1, duration: 0.25, ease: 'power2.inOut', immediateRender: false }}, 4.52);
  // messages, one model each
  tl.fromTo('.m7-b1', {{ opacity: 0, y: 120 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'power3.out' }}, 3.3);
  stream($('.m7-a1'), 3.65, 18);
  tl.fromTo('.m7-b2', {{ opacity: 0, y: 120 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'power3.out' }}, 4.8);
  stream($('.m7-a2'), 5.12, 18);
  // camera: close on the menu while picking, then back to the whole chat
  tl.fromTo('.m7-cam', {{ scale: 1 }}, {{ scale: 1.1, duration: 0.5, ease: 'power2.out' }}, 1.3);
  tl.fromTo('.m7-cam', {{ scale: 1.1 }}, {{ scale: 1.0, duration: 0.5, ease: 'power3.inOut', immediateRender: false }}, 3.12);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 08 on the go
STREET_CSS = """
    .sky-street { background: linear-gradient(180deg, #181C33 0%, #332F52 42%, #9A5E78 74%, #E29B75 100%); }
    .sc-city { position: absolute; left: 0; right: 0; bottom: 0; width: 1920px; height: 454px; }
"""

PHONE_CSS = """
    .o8-phpos { position: absolute; left: 1165px; top: -157px; }
    .phone { --as-on: #E8E4D8; --as-onv: rgba(232, 228, 216, 0.861); --as-onv60: rgba(232, 228, 216, 0.517);
      --as-surf: rgba(38, 38, 36, 0.93); --as-line: rgba(232, 228, 216, 0.1575); --as-high: rgba(76, 76, 72, 0.9);
      --ph-tile: #33262F; --ph-glyph: #FFB8A1;
      position: relative; width: 411px; height: 891px; zoom: 1.4; padding: 8px; border-radius: 50px; background: #0B0C10;
      font-family: "Arimo", sans-serif; text-align: left;
      box-shadow: inset 0 0 0 1.5px #2A2C33, 0 0 0 1px rgba(255, 255, 255, 0.08), 0 50px 110px -20px rgba(0, 0, 0, 0.7); }
    .phone-screen { position: relative; height: 100%; overflow: hidden; border-radius: 42px; color: var(--as-on);
      background: radial-gradient(circle at 70% 26%, rgba(255, 196, 150, 0.95) 0, rgba(246, 160, 122, 0.9) 58px, rgba(236, 140, 118, 0) 64px),
        radial-gradient(90% 40% at 0% 62%, rgba(118, 98, 186, 0.5), transparent 70%),
        linear-gradient(176deg, #171A36 0%, #2B2B58 26%, #5A447A 50%, #A25F7E 72%, #D98172 100%); }
    .phone-screen::before, .phone-screen::after { content: ""; position: absolute; z-index: 0; border-radius: 50%; }
    .phone-screen::before { left: -40%; top: 47%; width: 150%; height: 40%; background: linear-gradient(180deg, #6B4379 0%, #8E5378 45%, #B56A78 100%); transform: rotate(-8deg); }
    .phone-screen::after { left: 20%; top: 58%; width: 130%; height: 50%; background: linear-gradient(180deg, #7E4A76 0%, #A65E77 50%, #CF7C74 100%); transform: rotate(10deg); }
    .ph-status { position: absolute; z-index: 1; left: 0; right: 0; top: 0; height: 40px; display: flex; align-items: center; justify-content: space-between; padding: 2px 24px 0 28px; font-size: 14px; font-weight: 500; color: #fff; }
    .ph-cam { position: absolute; left: 50%; top: 11px; width: 20px; height: 20px; margin-left: -10px; border-radius: 50%; background: #050506; box-shadow: inset 0 0 0 3px #111217; }
    .ph-sys { display: flex; align-items: center; gap: 5px; }
    .ph-sys svg { width: 15px; height: 15px; }
    .ph-glance { position: absolute; z-index: 1; left: 28px; top: 66px; display: flex; align-items: center; gap: 9px; font-size: 21px; color: #fff; }
    .ph-glance i { width: 1px; height: 20px; background: rgba(255, 255, 255, 0.55); }
    .ph-glance svg { width: 20px; height: 20px; color: #E8EAF2; }
    .ph-grid { position: absolute; z-index: 1; left: 10px; right: 10px; top: 150px; display: grid; grid-template-columns: repeat(4, 1fr); justify-items: center; row-gap: 26px; }
    .ph-app { display: flex; flex-direction: column; align-items: center; width: 88px; }
    .ph-ic { width: 54px; height: 54px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: var(--ph-tile); color: var(--ph-glyph); }
    .ph-ic svg { width: 26px; height: 26px; }
    .ph-lbl { margin-top: 6px; font-size: 12px; line-height: 16px; color: #fff; white-space: nowrap; }
    .ph-bar { position: absolute; left: 50%; bottom: 8px; z-index: 3; width: 100px; height: 4px; margin-left: -50px; border-radius: 2px; background: rgba(255, 255, 255, 0.85); }
    .as-st { position: absolute; z-index: 2; left: 24px; right: 24px; bottom: 162px; display: flex; flex-direction: column; }
    .as-dock { position: absolute; z-index: 2; left: 24px; right: 24px; bottom: 36px; display: flex; flex-direction: column; }
    .as-panel { margin-bottom: 10px; padding: 18px; border: 1px solid var(--as-line); border-radius: 22px; background: rgba(38, 38, 36, 0.95); }
    .as-brand { margin: 0; font-size: 13px; line-height: 1.43; letter-spacing: 1.4px; color: var(--as-onv); }
    .as-status { margin: 8px 0 0; font-size: 28px; line-height: 1.2; font-weight: 500; color: var(--as-on); }
    .as-heard { margin: 8px 0 0; font-size: 20px; line-height: 1.35; color: #D97757; }
    .as-answer { margin: 8px 0 0; font-size: 20px; line-height: 1.4; color: var(--as-onv); }
    .as-answer strong { font-weight: 700; color: var(--as-on); }
    .as-tools { padding: 12px 18px; }
    .as-tool { margin: 0; display: flex; align-items: center; gap: 10px; padding: 5px 0; font-size: 20px; line-height: 1.3; color: var(--as-onv); }
    .as-tool.run { color: #D97757; }
    .as-tic { flex: none; width: 20px; height: 20px; display: flex; align-items: center; justify-content: center; }
    .as-tic svg { width: 18px; height: 18px; }
    .as-spin { width: 17px; height: 17px; border: 2px solid transparent; border-top-color: #D97757; border-right-color: #D97757; border-radius: 50%; }
    .as-card-h { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; font-size: 20px; font-weight: 700; }
    .as-card-h svg { width: 16px; height: 16px; color: #D97757; }
    .as-place { display: flex; align-items: center; gap: 10px; padding: 9px 0; border-top: 1px solid var(--as-line); }
    .as-place-t { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
    .as-place-t b { font-size: 20px; font-weight: 700; }
    .as-place-t small { font-size: 16px; color: var(--as-onv); }
    .as-rate { display: flex; align-items: center; gap: 3px; font-size: 17px; font-weight: 700; }
    .as-rate svg { width: 14px; height: 14px; color: #F4B642; }
    .as-action { display: flex; align-items: center; gap: 12px; }
    .as-action-ic { width: 40px; height: 40px; border-radius: 50%; background: rgba(217, 119, 87, 0.18); color: #D97757; display: flex; align-items: center; justify-content: center; }
    .as-action-ic svg { width: 20px; height: 20px; }
    .as-action-t { display: flex; flex-direction: column; gap: 2px; }
    .as-action-t b { font-size: 20px; font-weight: 700; }
    .as-action-t small { font-size: 17px; color: var(--as-onv); }
    .as-wave { display: flex; align-items: center; justify-content: center; gap: 5.4px; height: 58px; padding: 8px 20px; }
    .as-wave i { flex: none; width: 4.6px; height: 8px; border-radius: 4px; background: #D97757; }
    .as-btns { display: flex; align-items: center; gap: 10px; height: 48px; }
    .as-round { flex: none; width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: var(--as-high); color: var(--as-on); }
    .as-pill { flex: 1; height: 48px; display: flex; align-items: center; justify-content: center; gap: 8px; border-radius: 24px; background: #D97757; color: #E8E4D8; font-size: 18px; font-weight: 600; }
    .o8-hb { position: absolute; left: 130px; top: 370px; }
    .o8-hb .hb-eyebrow { text-align: left; }
    .o8-title { margin-top: 26px; font-family: "Arimo", sans-serif; font-size: 100px; font-weight: 400; letter-spacing: -0.04em; line-height: 1.04; color: #F6F3EC; }
    .o8-title .ln { display: block; white-space: nowrap; }
    .o8-title .wd { display: inline-block; }
"""


def f08():
    fid, dur = "08-onthego", 4.8
    heard = "“Find a pharmacy that is open now and take me there.”"
    env = [0.142, 0.282, 0.415, 0.541, 0.655, 0.756, 0.841, 0.91, 0.959, 0.99, 1, 0.99, 0.959, 0.91,
           0.841, 0.756, 0.655, 0.541, 0.415, 0.282, 0.142]
    grid = ["h-calendar01", "h-clock01", "h-image01", "asst-sun", "asst-note", "asst-folder", "h-settings02", "asst-logo"]
    apps = ["Calendar", "Clock", "Photos", "Weather", "Notes", "Files", "Settings", "Chuk Chat"]
    gridh = "".join(f'<span class="ph-app"><span class="ph-ic">{icon(g)}</span><span class="ph-lbl">{a}</span></span>'
                    for g, a in zip(grid, apps))
    check = icon("asst-check")
    places = [("Pharmacy at the market", "Marktplatz 4", "open until 20:00", "4.7"),
              ("Linden Pharmacy", "Lindenstraße 21", "open until 19:00", "4.5"),
              ("Harbour Pharmacy", "Kaistraße 8", "open until 18:30", "4.4")]
    placeh = "".join(
        f'<div class="as-place"><span class="as-place-t"><b>{esc(n)}</b><small>{esc(a)} · {esc(m)}</small></span>'
        f'<span class="as-rate">{icon("asst-star")}<b>{r}</b></span></div>' for n, a, m, r in places)
    answer = ("Three pharmacies are open. The closest is <strong>Pharmacy at the market</strong>, "
              "400 m away. Navigation is running.")
    bars = "".join('<i></i>' for _ in env)
    lines = ["Hold the home button.", "Ask. Done."]
    title = "".join('<span class="ln">' + " ".join(f'<span class="wd">{esc(w)}</span>' for w in ln.split()) + '</span>'
                    for ln in lines)
    body = f"""
    <div class="clip fill sky-street" data-start="0" data-duration="{dur}" data-track-index="0">
      <svg class="sc-city" viewBox="0 0 1440 360" preserveAspectRatio="xMidYMax slice"><g fill="#141729"><path d="M0 360 V210 H70 V160 H150 V230 H210 V120 H300 V200 H350 V250 H420 V140 H520 V220 H580 V90 H660 V190 H720 V240 H800 V150 H890 V210 H950 V110 H1040 V200 H1100 V250 H1170 V130 H1260 V200 H1320 V170 H1440 V360 Z"/></g><g fill="#F6C977"><rect x="228" y="140" width="10" height="12"/><rect x="258" y="170" width="10" height="12"/><rect x="440" y="160" width="10" height="12"/><rect x="470" y="190" width="10" height="12"/><rect x="600" y="110" width="10" height="12"/><rect x="630" y="140" width="10" height="12"/><rect x="600" y="170" width="10" height="12"/><rect x="820" y="170" width="10" height="12"/><rect x="850" y="200" width="10" height="12"/><rect x="970" y="130" width="10" height="12"/><rect x="1000" y="160" width="10" height="12"/><rect x="1190" y="150" width="10" height="12"/><rect x="1220" y="180" width="10" height="12"/><rect x="90" y="180" width="10" height="12"/><rect x="120" y="210" width="10" height="12"/></g></svg>
    </div>
    <div class="clip fill tone-dark" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="o8-hb"><p class="hb-eyebrow">06 — On the go</p><h2 class="o8-title">{title}</h2></div>
      <div class="o8-phpos">
        <div class="phone"><div class="phone-screen">
          <div class="ph-status"><span>18:42</span><span class="ph-cam"></span><span class="ph-sys">{icon("asst-wifi")}{icon("asst-cell")}{icon("asst-battery")}</span></div>
          <div class="ph-glance" data-layout-allow-overlap><span>Fri, Sep 25</span><i></i>{icon("asst-cloud")}<span>14°C</span></div>
          <div class="ph-grid o8-grid" data-layout-allow-overlap>{gridh}</div>
          <div class="as-st o8-sA">
            <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Listening</p><p class="as-heard o8-heard"></p></div>
          </div>
          <div class="as-st o8-sB">
            <div class="as-panel o8-places"><div class="as-card-h">{icon("h-location01")}<b>Pharmacy</b></div>{placeh}</div>
            <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Working …</p></div>
            <div class="as-panel as-tools">
              <p class="as-tool o8-t1"><span class="as-tic">{check}</span>Location</p>
              <p class="as-tool o8-t2"><span class="as-tic">{check}</span>Places: Pharmacy</p>
              <p class="as-tool run o8-t3"><span class="as-tic"><i class="as-spin o8-spin"></i></span>Navigation: Pharmacy at the market</p>
            </div>
          </div>
          <div class="as-st o8-sC">
            <div class="as-panel o8-act"><div class="as-action"><span class="as-action-ic">{icon("asst-nav-r")}</span><span class="as-action-t"><b>Navigation started</b><small>Pharmacy at the market</small></span></div></div>
            <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Listening</p>
              <p class="as-heard">{esc(heard)}</p><div class="as-answer o8-ans">{words(answer.replace('<strong>', '').replace('</strong>', ''))}</div></div>
          </div>
          <div class="as-dock">
            <div class="as-panel as-wave o8-wave">{bars}</div>
            <div class="as-btns"><span class="as-round">{icon("h-plus-sign", "z22")}</span>
              <span class="as-pill">{icon("h-mic02", "z20")}<span class="o8-p0">Pause</span><span class="o8-p1">Working …</span><span class="o8-p2">Pause</span></span>
              <span class="as-round">{icon("h-cancel01", "z22")}</span></div>
          </div>
          <span class="ph-bar"></span>
        </div></div>
      </div>
    </div>"""
    css = STREET_CSS + PHONE_CSS
    js = f"""
  var ws = $$('.o8-title .wd');
  tl.fromTo('.o8-hb .hb-eyebrow', {{ opacity: 0, y: 10 }}, {{ opacity: 1, y: 0, duration: 0.4, ease: 'power3.out' }}, 0);
  ws.forEach(function (w, i) {{ tl.fromTo(w, {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'power3.out' }}, 0.05 + i * 0.06); }});
  tl.fromTo('.o8-phpos', {{ y: 420 }}, {{ y: 0, duration: 0.75, ease: 'power3.out' }}, 0);
  tl.fromTo('.o8-phpos', {{ scale: 1 }}, {{ scale: 1.02, duration: DUR, ease: 'power1.inOut', transformOrigin: '50% 100%', immediateRender: false }}, 0);
  // state A: listening, the request is heard
  type($('.o8-heard'), {heard!r}, 0.35, 62);
  showBetween($('.o8-sA'), -1, 1.25);
  // state B: working with tools
  showBetween($('.o8-sB'), 1.25, 3.0);
  tl.fromTo('.o8-sB', {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 1.25);
  rise('.o8-t1', 1.3, {{ y: 6, d: 0.25 }});
  rise('.o8-t2', 1.42, {{ y: 6, d: 0.25 }});
  rise('.o8-t3', 1.54, {{ y: 6, d: 0.25 }});
  rise('.o8-places', 1.72, {{ y: 16, d: 0.4 }});
  tl.fromTo('.o8-grid', {{ opacity: 1 }}, {{ opacity: 0, duration: 0.15, immediateRender: false }}, 1.62);
  tl.fromTo('.o8-grid', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, immediateRender: false }}, 3.0);
  spin($('.o8-spin'));
  // state C: answer + action
  showBetween($('.o8-sC'), 3.0, 99);
  tl.fromTo('.o8-sC', {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 3.0);
  rise('.o8-act', 3.0, {{ y: 16, d: 0.4 }});
  stream($('.o8-ans'), 3.2, 16);
  showBetween($('.o8-p0'), -1, 1.25); showBetween($('.o8-p1'), 1.25, 3.0); showBetween($('.o8-p2'), 3.0, 99);
  // waveform: speaking while listening, idle while busy
  var env = {env};
  var bars = $$('.o8-wave i');
  ups.push(function (t) {{
    var busy = t >= 1.25 && t < 3.0;
    var level = t < 1.25 ? 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3)) : 0.08;
    for (var i = 0; i < bars.length; i++) {{
      var wave = 0.5 + 0.5 * Math.sin((t / 1.8) * Math.PI * 2 + i * 0.8);
      var h = busy ? 4 + 8 * wave : Math.min(36, 4 + (3 + 29 * level) * env[i] * (0.45 + 0.55 * wave));
      bars[i].style.height = h.toFixed(2) + 'px';
      bars[i].style.background = busy ? 'rgba(232,228,216,0.52)' : '#D97757';
    }}
  }});
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 09 proof
def f09():
    fid, dur = "09-proof", 6.0
    chips = [("h-lock", "End-to-end encrypted"), ("i-shield", "Never used for training"),
             ("i-layers", "Open-weight models only"), (None, "€20/month, €16 AI credits included")]

    def chip(i, ic, txt):
        ich = icon(ic, "p9-ic") if ic else '<span class="p9-eur">€</span>'
        return f'<span class="p9-chip p9-c{i}">{ich}<span>{esc(txt)}</span></span>'
    title = " ".join(f'<span class="wd">{esc(w)}</span>' for w in "One private chat for all your work.".split())
    css = PAPER_BG + """
    .p9-grp { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; transform-origin: 960px 540px; }
    .p9-title { font-family: "Arimo", sans-serif; font-size: 96px; font-weight: 400; letter-spacing: -0.045em; line-height: 1; color: #26251F; white-space: nowrap; }
    .p9-title .wd { display: inline-block; }
    .p9-rows { margin-top: 90px; display: flex; flex-direction: column; align-items: center; gap: 28px; }
    .p9-row { display: flex; gap: 28px; }
    .p9-chip { display: inline-flex; align-items: center; gap: 18px; height: 112px; padding: 0 48px 0 40px; border-radius: 999px; background: #F3F0E8;
      border: 1.5px solid #E6E1D5; font-family: "Arimo", sans-serif; font-size: 46px; font-weight: 500; letter-spacing: -0.02em; color: #26251F; white-space: nowrap; }
    .p9-ic { width: 46px; height: 46px; color: #D97757; }
    .p9-eur { width: 46px; height: 46px; display: inline-flex; align-items: center; justify-content: center; font-family: "Chuk Chat Mono", monospace; font-size: 40px; font-weight: 700; color: #D97757; }
"""
    body = f"""
    <div class="clip fill paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="p9-grp">
        <h2 class="p9-title">{title}</h2>
        <div class="p9-rows">
          <div class="p9-row">{chip(0, *chips[0])}{chip(1, *chips[1])}</div>
          <div class="p9-row">{chip(2, *chips[2])}{chip(3, *chips[3])}</div>
        </div>
      </div>
    </div>"""
    js = """
  $$('.p9-title .wd').forEach(function (w, i) {
    tl.fromTo(w, { opacity: 0, y: 50 }, { opacity: 1, y: 0, duration: 0.55, ease: 'power3.out' }, 0.02 + i * 0.05);
  });
  [1.2, 2.4, 3.6, 4.8].forEach(function (t, i) {
    tl.fromTo('.p9-c' + i, { opacity: 0, scale: 0.7, y: 24 }, { opacity: 1, scale: 1, y: 0, duration: 0.5, ease: 'back.out(1.8)' }, t);
  });
  tl.fromTo('.p9-grp', { scale: 1 }, { scale: 1.03, duration: DUR, ease: 'power1.inOut' }, 0);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 10 end card
def f10():
    fid, dur = "10-endcard", 5.695
    css = PAPER_BG + """
    .e10-grp { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; transform-origin: 960px 520px; }
    .e10-lock { display: flex; align-items: center; gap: 34px; }
    .e10-logo { width: 150px; height: 150px; overflow: visible; }
    .e10-name { font-family: "Arimo", sans-serif; font-size: 140px; font-weight: 500; letter-spacing: -0.05em; line-height: 1; color: #26251F; white-space: nowrap; }
    .e10-slogan { margin-top: 58px; font-family: "Arimo", sans-serif; font-size: 54px; font-weight: 400; letter-spacing: -0.03em; color: #5F5D55; white-space: nowrap; }
    .e10-slogan .wd { display: inline-block; }
    .e10-url { margin-top: 34px; padding: 14px 38px; border-radius: 999px; background: #F3F0E8; border: 1.5px solid #E6E1D5; font-family: "Chuk Chat Mono", monospace; font-size: 40px; font-weight: 600; letter-spacing: 0.02em; color: #26251F; }
"""
    slogan = " ".join(f'<span class="wd">{w}</span>' for w in "Private and Secure. Always.".split())
    body = f"""
    <div class="clip fill paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="e10-grp">
        <div class="e10-lock">{logo_svg("e10-logo")}<span class="e10-name">Chuk Chat</span></div>
        <p class="e10-slogan">{slogan}</p>
        <p class="e10-url">chuk.chat</p>
      </div>
    </div>"""
    js = """
  tl.fromTo('.e10-logo-a', { x: -120, y: -70, rotation: -80, opacity: 0, transformOrigin: '50% 50%' },
    { x: 0, y: 0, rotation: 0, opacity: 1, duration: 0.62, ease: 'power3.out', transformOrigin: '50% 50%' }, 0);
  tl.fromTo('.e10-logo-b', { x: 120, y: 70, rotation: -80, opacity: 0, transformOrigin: '50% 50%' },
    { x: 0, y: 0, rotation: 0, opacity: 1, duration: 0.62, ease: 'power3.out', transformOrigin: '50% 50%' }, 0);
  tl.fromTo('.e10-name', { opacity: 0, x: -40 }, { opacity: 1, x: 0, duration: 0.7, ease: 'power3.out' }, 0.18);
  // the final hit (57.705 s = local 2.4 s)
  $$('.e10-slogan .wd').forEach(function (w, i) {
    tl.fromTo(w, { opacity: 0, y: 36 }, { opacity: 1, y: 0, duration: 0.55, ease: 'power3.out' }, 2.4 + i * 0.07);
  });
  tl.fromTo('.e10-url', { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 0.5, ease: 'power3.out' }, 2.62);
  tl.fromTo('.e10-grp', { scale: 1.0 }, { scale: 1.03, duration: DUR, ease: 'power1.inOut' }, 0);
"""
    return write(fid, page(fid, dur, css, body, js))


if __name__ == "__main__":
    for f in (f07, f08, f09, f10):
        print(f())
