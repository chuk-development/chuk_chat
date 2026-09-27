"""Frames 10-14: workspaces, models, Android assistant, everywhere, price + end card."""
from icons import icon
from kit import CURSOR_SVG, beat_page, bubble, esc, logo, page, step, words, write
from frames_a import MODELS


# ---------------------------------------------------------------- 10 workspaces
def f10():
    fid, dur = "f10-workspaces", 4
    files = [("h-pdf", "payslips-2025.pdf"), ("h-pdf", "tax-return-2024.pdf"), ("h-image01", "desk-receipt.jpg")]
    fh = "".join(f'<span class="ws-f ws-f{i}">{icon(ic, "z18")}{esc(n)}</span>' for i, (ic, n) in enumerate(files))
    card = f"""<div class="rc ws-c">
      <div class="ws-top"><span class="ws-ic">{icon("asst-folder", "i22")}</span><b>Tax helper</b><span class="ws-tag">Workspace</span></div>
      <p class="ws-lab">Instructions</p>
      <p class="ws-ins">Help with my German tax return. Short answers. Cite my files.</p>
      <p class="ws-lab">Files · 3</p>
      <div class="ws-files">{fh}</div>
      <div class="ws-chat">
        {bubble("Can I deduct my home office?")}
        <div class="a-ai ws-ans">{words("Yes: €6 per day, up to €1,260 a year. You claimed it in 2024 too.")}</div>
        <span class="ws-cite">{icon("h-pdf", "z16")}tax-return-2024.pdf · p. 3</span>
      </div>
    </div>"""
    css = """
    .ws-top { display: flex; align-items: center; gap: 10px; }
    .ws-ic { flex: none; width: 40px; height: 40px; border-radius: 11px; background: rgba(217, 119, 87, 0.18); color: var(--acc); display: flex; align-items: center; justify-content: center; }
    .ws-top b { flex: 1; font-size: 21px; font-weight: 700; }
    .ws-tag { padding: 3px 9px; border: 1px solid var(--fg30); border-radius: 8px; font-size: 15px; color: var(--fg70); }
    .ws-lab { margin: 12px 0 4px !important; font-size: 15px; font-weight: 500; color: var(--fg55); }
    .ws-ins { padding: 8px 12px; border-radius: 10px; background: rgba(232, 228, 216, 0.06); font-size: 16px; line-height: 1.4; color: var(--fg85); }
    .ws-files { display: flex; flex-wrap: wrap; gap: 8px; }
    .ws-f { display: inline-flex; align-items: center; gap: 6px; height: 32px; padding: 0 11px 0 9px; border: 1px solid var(--fg15); border-radius: 9px; background: var(--lift); font-size: 15px; white-space: nowrap; }
    .ws-f svg { color: #F0A585; }
    .ws-chat { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--fg15); }
    .ws-ans { margin-top: 10px; font-size: 17px; }
    .ws-cite { display: inline-flex; align-items: center; gap: 6px; margin-top: 8px; padding: 4px 10px; border-radius: 8px; background: rgba(217, 119, 87, 0.18); color: #F0A585; font-size: 15px; font-weight: 600; }
"""
    js = """
  rise('.ws-ins', 0.25, { y: 8 });
  [0.5, 0.625, 0.75].forEach(function (t, i) { tl.fromTo('.ws-f' + i, { opacity: 0, x: -18 }, { opacity: 1, x: 0, duration: 0.3, ease: 'power3.out' }, t); });
  rise('.ws-chat', 1.0, { y: 12 });
  stream($('.ws-ans'), 1.4, 12);
  pop('.ws-cite', 2.8, { s: 0.6 });
"""
    return write(fid, beat_page(fid, dur, 10, "library", ["Your own", "assistants"], "Workspaces with your files and rules.", card, css, js))


# ---------------------------------------------------------------- 11 models
def f11():
    fid, dur = "f11-models", 4
    rows = "".join(
        f'<div class="mn-row mn-r{i}"><span class="mn-hl"></span><span class="mn-logo" style="--logo: url(\'assets/logos/models/{lg}.svg\')"></span>'
        f'<span class="mn-l">{esc(n)}</span><span class="mn-tick mn-t{i}">{icon("h-tick02", "z18")}</span></div>'
        for i, (n, lg) in enumerate(MODELS))
    picks = [0, 1, 3, 5]  # DeepSeek -> Kimi -> Qwen -> Mistral
    pills = "".join(f'<span class="pl pl{k}">{icon("h-settings02", "z16")}<b>{esc(MODELS[m][0])}</b></span>' for k, m in enumerate(picks))
    card = f"""<div class="rc md-c">
      <div class="mn">{rows}</div>
      <div class="md-comp">
        <p class="md-field">Ask me anything !</p>
        <div class="md-row"><span class="md-btn">{icon("h-plus-sign", "z24")}</span><span class="md-grow"></span>
          <span class="md-pill">{pills}{icon("h-arrow-down01", "z14")}</span>
          <span class="md-btn">{icon("h-mic02", "z22")}</span><span class="md-send">{icon("h-send-horizontal", "z24")}</span></div>
      </div>
      <div class="ripple md-rip"></div>
      <div class="cursor md-cur">{CURSOR_SVG}</div>
    </div>"""
    css = """
    .mn { display: flex; flex-direction: column; gap: 3px; padding: 3px; border: 2px solid var(--fg30); border-radius: 21px; background: var(--bg); }
    .mn-row { position: relative; display: flex; align-items: center; height: 46px; padding: 0 16px; border-radius: 6px; }
    .mn-row:first-child { border-top-left-radius: 18px; border-top-right-radius: 18px; }
    .mn-row:last-child { border-bottom-left-radius: 18px; border-bottom-right-radius: 18px; }
    .mn-hl { position: absolute; inset: 0; border-radius: inherit; background: rgba(204, 204, 204, 0.16); opacity: 0; }
    .mn-logo { position: relative; flex: none; width: 26px; height: 26px; margin-right: 12px; background: var(--fg); -webkit-mask: var(--logo) center / 25px 25px no-repeat; mask: var(--logo) center / 25px 25px no-repeat; }
    .mn-l { position: relative; flex: 1; font-size: 17px; font-weight: 600; color: rgba(232, 228, 216, 0.88); white-space: nowrap; }
    .mn-tick { position: relative; opacity: 0; color: var(--fg); }
    .md-comp { margin-top: 16px; padding: 12px 14px; border: 2px solid #615F5A; border-radius: 28px; }
    .md-field { padding: 0 4px 10px; font-size: 17px; font-weight: 600; color: rgba(232, 228, 216, 0.75); }
    .md-row { display: flex; align-items: center; gap: 8px; }
    .md-grow { flex: 1; }
    .md-btn { width: 44px; height: 36px; border: 2px solid #615F5A; border-radius: 18px; display: inline-flex; align-items: center; justify-content: center; }
    .md-send { width: 44px; height: 36px; border-radius: 20px; background: var(--acc); color: #fff; display: flex; align-items: center; justify-content: center; }
    .md-pill { position: relative; height: 36px; padding: 0 10px; border: 2px solid #615F5A; border-radius: 18px; display: inline-flex; align-items: center; gap: 6px; font-size: 15px; font-weight: 600; white-space: nowrap; }
    .md-pill .pl { display: inline-flex; align-items: center; gap: 6px; }
    .md-pill b { font-weight: 600; }
    .md-cur { left: 0; top: 0; width: 18px; height: 25px; }
    .md-cur svg { width: 18px; height: 25px; }
    .md-rip { left: -12px; top: -12px; width: 24px; height: 24px; border-width: 2px; }
"""
    # Row centres in card px (see .rc padding 20 + .mn border 2 + padding 3; rows 46 + gap 3).
    ry = [48 + 49 * i for i in range(6)]
    js = f"""
  var RY = {ry};
  var cur = $('.md-cur'), rip = $('.md-rip');
  fadeIn(cur, 0.3, 0.2);
  cursorPath(cur, [[0, 470, 420], [0.9, 300, RY[1] - 2, 0.55], [1.9, 300, RY[3] - 2, 0.5], [2.9, 300, RY[5] - 2, 0.5]]);
  tl.fromTo(rip, {{ x: 300, y: RY[1] }}, {{ x: 300, y: RY[1], duration: 0.01 }}, 0);
  var picks = [0, 1, 3, 5], at = [0, 1.0, 2.0, 3.0];
  tl.set('.mn-t0', {{ opacity: 1 }}, 0);
  for (var k = 1; k < 4; k++) {{
    (function (k) {{
      var t = at[k], m = picks[k], prev = picks[k - 1];
      tl.set(rip, {{ x: 300, y: RY[m] }}, t - 0.02);
      ripple(rip, t);
      press(cur, t, 0.86, '3px 2px');
      tl.fromTo('.mn-r' + m + ' .mn-hl', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.12 }}, t - 0.1);
      tl.fromTo('.mn-r' + m + ' .mn-hl', {{ opacity: 1 }}, {{ opacity: 0.55, duration: 0.4, immediateRender: false }}, t + 0.3);
      if (k > 1) tl.fromTo('.mn-r' + prev + ' .mn-hl', {{ opacity: 0.55 }}, {{ opacity: 0, duration: 0.2, immediateRender: false }}, t);
      tl.set('.mn-t' + prev, {{ opacity: 0 }}, t);
      tl.fromTo('.mn-t' + m, {{ opacity: 0, scale: 0.4 }}, {{ opacity: 1, scale: 1, duration: 0.25, ease: 'back.out(2)' }}, t);
    }})(k);
  }}
  for (var k = 0; k < 4; k++) showBetween($('.pl' + k), k === 0 ? -1 : at[k], k < 3 ? at[k + 1] : 99);
  for (var k = 1; k < 4; k++) tl.fromTo('.pl' + k, {{ opacity: 0, y: 8 }}, {{ opacity: 1, y: 0, duration: 0.25, ease: 'power3.out' }}, at[k]);
"""
    return write(fid, beat_page(fid, dur, 11, "dawn", ["Pick the", "model"], "Every open model. Switch per message.", card, css, js))


# ---------------------------------------------------------------- 12 Android assistant
PHONE_CSS = """
    .ph { position: relative; width: 411px; height: 891px; zoom: 1.18; padding: 8px; border-radius: 50px; background: #0B0C10;
      font-family: "Ubuntu", sans-serif; text-align: left; color: #E8E4D8;
      box-shadow: inset 0 0 0 1.5px #2A2C33, 0 0 0 1px rgba(255, 255, 255, 0.08), 0 50px 110px -20px rgba(0, 0, 0, 0.7); }
    .ph-screen { position: relative; height: 100%; overflow: hidden; border-radius: 42px;
      background: radial-gradient(circle at 70% 26%, rgba(255, 196, 150, 0.95) 0, rgba(246, 160, 122, 0.9) 58px, rgba(236, 140, 118, 0) 64px),
        radial-gradient(90% 40% at 0% 62%, rgba(118, 98, 186, 0.5), transparent 70%),
        linear-gradient(176deg, #171A36 0%, #2B2B58 26%, #5A447A 50%, #A25F7E 72%, #D98172 100%); }
    .ph-screen::before, .ph-screen::after { content: ""; position: absolute; z-index: 0; border-radius: 50%; }
    .ph-screen::before { left: -40%; top: 47%; width: 150%; height: 40%; background: linear-gradient(180deg, #6B4379 0%, #8E5378 45%, #B56A78 100%); transform: rotate(-8deg); }
    .ph-screen::after { left: 20%; top: 58%; width: 130%; height: 50%; background: linear-gradient(180deg, #7E4A76 0%, #A65E77 50%, #CF7C74 100%); transform: rotate(10deg); }
    .ph-status { position: absolute; z-index: 1; left: 0; right: 0; top: 0; height: 42px; display: flex; align-items: center; justify-content: space-between; padding: 2px 26px 0 30px; font-size: 24px; font-weight: 500; color: #fff; }
    .ph-cam { position: absolute; left: 50%; top: 11px; width: 20px; height: 20px; margin-left: -10px; border-radius: 50%; background: #050506; box-shadow: inset 0 0 0 3px #111217; }
    .ph-sys { display: flex; align-items: center; gap: 5px; }
    .ph-sys svg { width: 16px; height: 16px; }
    .ph-glance { position: absolute; z-index: 1; left: 28px; top: 66px; display: flex; align-items: center; gap: 10px; font-size: 24px; color: #fff; white-space: nowrap; }
    .ph-glance i { width: 1px; height: 22px; background: rgba(255, 255, 255, 0.55); }
    .ph-glance svg { width: 24px; height: 24px; color: #E8EAF2; }
    .ph-grid { position: absolute; z-index: 1; left: 14px; right: 14px; top: 140px; display: grid; grid-template-columns: repeat(4, 1fr); justify-items: center; row-gap: 22px; }
    .ph-ic { width: 58px; height: 58px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #33262F; color: #FFB8A1; }
    .ph-ic svg { width: 28px; height: 28px; }
    .ph-bar { position: absolute; left: 50%; bottom: 8px; z-index: 3; width: 100px; height: 4px; margin-left: -50px; border-radius: 2px; background: rgba(255, 255, 255, 0.85); }
    .as-st { position: absolute; z-index: 2; left: 22px; right: 22px; bottom: 154px; display: flex; flex-direction: column; }
    .as-dock { position: absolute; z-index: 2; left: 22px; right: 22px; bottom: 30px; display: flex; flex-direction: column; }
    .as-panel { margin-bottom: 10px; padding: 16px 18px; border: 1px solid rgba(232, 228, 216, 0.16); border-radius: 22px; background: rgba(38, 38, 36, 0.96); }
    .as-brand { font-size: 24px; line-height: 1.2; letter-spacing: 2px; color: rgba(232, 228, 216, 0.86); }
    .as-status { margin-top: 6px !important; font-size: 32px; line-height: 1.15; font-weight: 500; }
    .as-heard { margin-top: 8px !important; font-size: 25px; line-height: 1.3; color: #F09A7C; }
    .as-answer { margin-top: 8px !important; font-size: 25px; line-height: 1.3; color: rgba(232, 228, 216, 0.9); }
    .as-tool { display: flex; align-items: center; gap: 10px; padding: 4px 0; font-size: 25px; line-height: 1.3; color: rgba(232, 228, 216, 0.9); white-space: nowrap; }
    .as-tic { flex: none; width: 26px; height: 26px; display: flex; align-items: center; justify-content: center; color: #86C795; }
    .as-tic svg { width: 24px; height: 24px; }
    .as-spin { width: 22px; height: 22px; border: 3px solid transparent; border-top-color: #D97757; border-right-color: #D97757; border-radius: 50%; }
    .as-action { display: flex; align-items: center; gap: 14px; }
    .as-action-ic { flex: none; width: 50px; height: 50px; border-radius: 50%; background: rgba(217, 119, 87, 0.2); color: #F09A7C; display: flex; align-items: center; justify-content: center; }
    .as-action-ic svg { width: 26px; height: 26px; }
    .as-action-t { display: flex; flex-direction: column; gap: 2px; }
    .as-action-t b { font-size: 26px; font-weight: 700; }
    .as-action-t small { font-size: 24px; color: rgba(232, 228, 216, 0.84); }
    .as-wave { display: flex; align-items: center; justify-content: center; gap: 5.4px; height: 58px; padding: 8px 20px; }
    .as-wave i { flex: none; width: 4.6px; height: 8px; border-radius: 4px; background: #D97757; }
    .as-btns { display: flex; align-items: center; gap: 10px; height: 52px; }
    .as-round { flex: none; width: 52px; height: 52px; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: rgba(76, 76, 72, 0.92); }
    .as-pill { position: relative; flex: 1; height: 52px; display: flex; align-items: center; justify-content: center; gap: 8px; border-radius: 26px; background: #D97757; color: #FFFFFF; font-size: 24px; font-weight: 600; }
    .as-pill > span { display: inline-flex; align-items: center; gap: 8px; }
"""


def f12():
    fid, dur = "f12-android", 4
    heard = "“Text Anna that I'm ten minutes late.”"
    env = [0.142, 0.282, 0.415, 0.541, 0.655, 0.756, 0.841, 0.91, 0.959, 0.99, 1, 0.99, 0.959, 0.91,
           0.841, 0.756, 0.655, 0.541, 0.415, 0.282, 0.142]
    grid = ["h-calendar01", "h-clock01", "h-image01", "asst-sun", "asst-note", "asst-folder", "h-settings02", "asst-logo"]
    gridh = "".join(f'<span class="ph-ic">{icon(g)}</span>' for g in grid)
    check = icon("asst-check")
    bars = "".join("<i></i>" for _ in env)
    card = f"""<div class="ph"><div class="ph-screen">
      <div class="ph-status"><span>17:52</span><span class="ph-cam"></span><span class="ph-sys">{icon("asst-wifi")}{icon("asst-cell")}{icon("asst-battery")}</span></div>
      <div class="ph-glance"><span>Mon, Sep 28</span><i></i>{icon("asst-cloud")}<span>14°C</span></div>
      <div class="ph-grid an-grid">{gridh}</div>
      <div class="as-st an-sA">
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Listening</p><p class="as-heard">{esc(heard)}</p></div>
      </div>
      <div class="as-st an-sB">
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Working …</p></div>
        <div class="as-panel">
          <p class="as-tool an-t1"><span class="as-tic">{check}</span>Contact: Anna</p>
          <p class="as-tool an-t2"><span class="as-tic"><i class="as-spin an-spin"></i></span>SMS to Anna</p>
        </div>
      </div>
      <div class="as-st an-sC">
        <div class="as-panel an-act"><div class="as-action"><span class="as-action-ic">{icon("asst-message")}</span>
          <span class="as-action-t"><b>Message sent</b><small>To Anna: I'm ten minutes late.</small></span></div></div>
        <div class="as-panel"><p class="as-brand">CHUK CHAT</p><p class="as-status">Done</p>
          <p class="as-answer an-ans">{words("Anna has your message. Drive safe.")}</p></div>
      </div>
      <div class="as-dock">
        <div class="as-panel as-wave an-wave">{bars}</div>
        <div class="as-btns"><span class="as-round">{icon("h-plus-sign", "z24")}</span>
          <span class="as-pill">{icon("h-mic02", "z22")}<span class="an-p0">Pause</span><span class="an-p1">Working …</span><span class="an-p2">Pause</span></span>
          <span class="as-round">{icon("h-cancel01", "z24")}</span></div>
      </div>
      <span class="ph-bar"></span>
    </div></div>"""
    js = f"""
  // A: the request is heard; B: tools run; C: the result card + answer. Cuts on beats 1.0 and 2.0 (break).
  fadeIn('.an-sA .as-heard', 0.2, 0.25);
  showBetween($('.an-sA'), -1, 1.0);
  showBetween($('.an-sB'), 1.0, 2.0);
  tl.fromTo('.an-sB', {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 1.0);
  rise('.an-t1', 1.1, {{ y: 6, d: 0.25 }});
  rise('.an-t2', 1.4, {{ y: 6, d: 0.25 }});
  spin($('.an-spin'));
  showBetween($('.an-sC'), 2.0, 99);
  tl.fromTo('.an-sC', {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 2.0);
  tl.fromTo('.an-act', {{ scale: 0.9 }}, {{ scale: 1, duration: 0.4, ease: 'back.out(2)' }}, 2.0);
  stream($('.an-ans'), 2.4, 10);
  tl.fromTo('.an-grid', {{ opacity: 1 }}, {{ opacity: 0.25, duration: 0.2, immediateRender: false }}, 0.9);
  showBetween($('.an-p0'), -1, 1.0); showBetween($('.an-p1'), 1.0, 2.0); showBetween($('.an-p2'), 2.0, 99);
  var env = {env};
  var bars = $$('.an-wave i');
  ups.push(function (t) {{
    var busy = t >= 1.0 && t < 2.0;
    var level = t < 1.0 ? 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3)) : 0.08;
    for (var i = 0; i < bars.length; i++) {{
      var wave = 0.5 + 0.5 * Math.sin((t / 1.8) * Math.PI * 2 + i * 0.8);
      var h = busy ? 4 + 8 * wave : Math.min(38, 4 + (3 + 31 * level) * env[i] * (0.45 + 0.55 * wave));
      bars[i].style.height = h.toFixed(2) + 'px';
      bars[i].style.background = busy ? 'rgba(232,228,216,0.52)' : '#D97757';
    }}
  }});
"""
    return write(fid, beat_page(fid, dur, 12, "street", ["Android", "assistant"], "Hold the home button. Ask.", card, PHONE_CSS, js))


# ---------------------------------------------------------------- 13 everywhere
def f13():
    fid, dur = "f13-everywhere", 4
    lines = [("09:00", "Market"), ("12:30", "Lunch"), ("20:00", "Cinema")]

    def chat(p):
        ls = "".join(f'<p class="dv-li {p}-l{i}"><b>{a}</b> {b}</p>' for i, (a, b) in enumerate(lines))
        return (f'<div class="dv-user"><span class="dv-bub">Plan Saturday</span></div>'
                f'<div class="dv-ans">{ls}</div>')
    plats = ["Mac", "Windows", "Linux", "Android", "Web"]
    ch = "".join(f'<span class="dv-chip dv-c{i}">{p}</span>' for i, p in enumerate(plats))
    card = f"""<div class="dv">
      <div class="dv-win"><div class="dv-win-in">
        <div class="dv-bar"><i></i><i></i><i></i></div>
        <div class="dv-rail"><span>{icon("h-menu01", "z20")}</span><span class="dv-acc">{icon("h-pencil-edit02", "z20")}</span><span class="dv-acc">{icon("h-image01", "z20")}</span></div>
        <div class="dv-col">{chat("dw")}
          <div class="dv-comp"><span>Ask me anything !</span><i>{icon("h-send-horizontal", "z20")}</i></div></div>
      </div></div>
      <div class="dv-ph"><div class="dv-ph-in"><div class="dv-ph-scr">
        <div class="dv-ph-top"><span class="dv-cam"></span></div>
        <div class="dv-ph-col">{chat("dp")}</div>
        <span class="dv-sync">{icon("h-tick02", "z16")}Synced</span>
      </div></div></div>
      <div class="dv-chips">{ch}</div>
      <p class="dv-lock">{icon("h-lock", "dv-lk")}Synced and end-to-end encrypted</p>
    </div>"""
    css = """
    .dv { position: relative; width: 1090px; height: 820px; }
    .dv-win { position: absolute; left: 0; top: 30px; }
    .dv-win-in { position: relative; width: 500px; height: 310px; zoom: 1.6; overflow: hidden; border-radius: 14px; background: #262624; color: #E8E4D8;
      box-shadow: 0 34px 80px -26px rgba(20, 16, 8, 0.55), 0 0 0 1px rgba(255, 255, 255, 0.07); font-family: "Ubuntu", sans-serif; }
    .dv-bar { position: absolute; left: 14px; top: 12px; display: flex; gap: 6px; }
    .dv-bar i { width: 10px; height: 10px; border-radius: 50%; background: #5A5852; }
    .dv-rail { position: absolute; left: 12px; top: 40px; display: flex; flex-direction: column; gap: 14px; color: #E8E4D8; }
    .dv-rail span { display: flex; }
    .dv-acc { color: #D97757; }
    .dv-col { position: absolute; left: 70px; right: 30px; top: 22px; bottom: 16px; display: flex; flex-direction: column; }
    .dv-user { display: flex; justify-content: flex-end; }
    .dv-bub { padding: 6px 12px; border-radius: 13px 13px 4px 13px; background: #AD6048; color: #fff; font-family: "Chuk Chat Mono", monospace; font-size: 18px; white-space: nowrap; }
    .dv-ans { margin-top: 8px; font-family: "Chuk Chat Mono", monospace; font-size: 18px; line-height: 1.45; }
    .dv-li { margin: 0; white-space: nowrap; }
    .dv-li b { color: #F0A585; font-weight: 700; }
    .dv-comp { margin-top: auto; display: flex; align-items: center; justify-content: space-between; height: 46px; padding: 0 8px 0 16px; border: 2px solid #615F5A; border-radius: 23px;
      font-size: 18px; font-weight: 600; color: rgba(232, 228, 216, 0.75); }
    .dv-comp i { width: 40px; height: 32px; border-radius: 16px; background: #D97757; color: #fff; display: flex; align-items: center; justify-content: center; }
    .dv-ph { position: absolute; left: 770px; top: 150px; }
    .dv-ph-in { width: 196px; height: 406px; zoom: 1.6; padding: 6px; border-radius: 30px; background: #0B0C10;
      box-shadow: inset 0 0 0 1.5px #2A2C33, 0 40px 80px -24px rgba(0, 0, 0, 0.6); }
    .dv-ph-scr { position: relative; height: 100%; overflow: hidden; border-radius: 25px; background: #262624; color: #E8E4D8; }
    .dv-ph-top { height: 26px; }
    .dv-cam { position: absolute; left: 50%; top: 8px; width: 12px; height: 12px; margin-left: -6px; border-radius: 50%; background: #050506; }
    .dv-ph-col { padding: 8px 9px 0; }
    .dv-ph-col .dv-bub { font-size: 18px; padding: 6px 10px; }
    .dv-sync { position: absolute; left: 12px; bottom: 14px; display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 8px; background: rgba(134, 199, 149, 0.16); color: #86C795;
      font-family: "Ubuntu", sans-serif; font-size: 18px; font-weight: 700; }
    .dv-chips { position: absolute; left: 0; top: 590px; display: flex; gap: 10px; }
    .dv-chip { display: inline-flex; align-items: center; height: 64px; padding: 0 22px; border-radius: 32px; background: #FFFFFF; border: 1.5px solid #E6E1D5;
      font-family: "Ubuntu", sans-serif; font-size: 32px; font-weight: 500; color: #26251F; box-shadow: 0 10px 24px -14px rgba(20, 16, 8, 0.3); }
    .dv-lock { position: absolute; left: 0; top: 684px; display: inline-flex; align-items: center; gap: 14px; height: 68px; margin: 0; padding: 0 28px 0 22px; border-radius: 34px;
      background: #26251F; color: #F6F3EC; font-family: "Ubuntu", sans-serif; font-size: 32px; font-weight: 500; white-space: nowrap; }
    .dv-lk { width: 34px; height: 34px; color: #86C795; }
"""
    js = """
  // Desktop answers first; the phone shows the same chat a beat later.
  [0, 1, 2].forEach(function (i) { rise('.dw-l' + i, 0.45 + i * 0.2, { y: 6, d: 0.3 }); });
  tl.fromTo('.dv-ph', { opacity: 0, x: 60 }, { opacity: 1, x: 0, duration: 0.45, ease: 'power3.out' }, 0.2);
  [0, 1, 2].forEach(function (i) { rise('.dp-l' + i, 1.0 + i * 0.2, { y: 6, d: 0.3 }); });
  pop('.dv-sync', 1.6, { s: 0.5 });
  for (var i = 0; i < 5; i++) pop('.dv-c' + i, 2.0 + i * 0.125, { s: 0.6 });
  rise('.dv-lock', 2.75, { y: 14, d: 0.4 });
"""
    return write(fid, beat_page(fid, dur, 13, "prism", ["Everywhere"], "Mac, Windows, Linux, Android, Web.", card, css, js))


# ---------------------------------------------------------------- 14 price + end card
def f14():
    fid, dur = "f14-end", 8
    css = """
    .en-price { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }
    .en-p1 { margin: 0; font-family: "Inter", sans-serif; font-size: 170px; font-weight: 400; letter-spacing: -0.05em; line-height: 1; color: #26251F; white-space: nowrap; }
    .en-p2 { margin: 34px 0 0; font-family: "Inter", sans-serif; font-size: 60px; font-weight: 400; letter-spacing: -0.025em; color: #4E4C45; white-space: nowrap; }
    .en-p2 b { font-weight: 500; color: #B4532F; }
    .en-lock { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; padding-bottom: 10px; }
    .en-brand { display: flex; align-items: center; gap: 34px; }
    .en-logo { width: 140px; height: 140px; display: block; }
    .en-name { font-family: "Chuk Chat Mono", monospace; font-size: 124px; font-weight: 700; letter-spacing: -4px; line-height: 1; color: #26251F; white-space: nowrap; }
    .en-slogan { margin: 52px 0 0; font-family: "Inter", sans-serif; font-size: 80px; font-weight: 300; letter-spacing: -0.03em; line-height: 1.05; color: #26251F; white-space: nowrap; }
    .en-url { margin: 46px 0 0; padding: 12px 38px; border: 2px solid rgba(38, 37, 31, 0.28); border-radius: 999px; background: #F3F0E8;
      font-family: "Chuk Chat Mono", monospace; font-size: 44px; font-weight: 600; letter-spacing: 0.01em; color: #26251F; }
"""
    body = f"""    <div id="{fid}-world" class="clip sc sc--paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div id="{fid}-stage" class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="en-price"><p class="en-p1">€20 / month</p><p class="en-p2"><b>€16</b> AI credits included</p></div>
      <div class="en-lock">
        <div class="en-brand">{logo("en-logo")}<span class="en-name">Chuk Chat</span></div>
        <p class="en-slogan">Private and Secure. Always.</p>
        <p class="en-url">chuk.chat</p>
      </div>
    </div>"""
    js = """
  // Price on the downbeat (V56), end card on the next bar (V58), then it holds.
  tl.fromTo('.en-p1', { opacity: 0, y: 50 }, { opacity: 1, y: 0, duration: 0.45, ease: 'power3.out' }, 0);
  tl.fromTo('.en-p2', { opacity: 0, y: 24 }, { opacity: 1, y: 0, duration: 0.45, ease: 'power3.out' }, 0.5);
  tl.fromTo('.en-price', { opacity: 1, y: 0 }, { opacity: 0, y: -40, duration: 0.22, ease: 'power2.in', immediateRender: false }, 1.8);
  tl.fromTo('.en-logo', { opacity: 0, scale: 0.9 }, { opacity: 1, scale: 1, duration: 0.5, ease: 'power3.out' }, 2.0);
  tl.fromTo('.en-name', { opacity: 0, x: -20 }, { opacity: 1, x: 0, duration: 0.5, ease: 'power3.out' }, 2.0);
  tl.fromTo('.en-slogan', { opacity: 0, y: 22 }, { opacity: 1, y: 0, duration: 0.55, ease: 'power3.out' }, 2.5);
  tl.fromTo('.en-url', { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.5, ease: 'power3.out' }, 3.0);
"""
    return write(fid, page(fid, dur, css, body, js))
