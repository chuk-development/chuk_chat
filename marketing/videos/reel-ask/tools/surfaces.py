"""The two surfaces a reel can run on.

chat       the Chuk Chat Android app: top bar, bottom-anchored thread, composer.
assistant  the Android assistant overlay over the home screen
           (chuk.chat onthego.html / uc-assistant.css, sizes raised for 9:16).

Each surface returns (html, css, js). The JS reads the timing object T.
Every block that appears later is a row (.r) that grows from 0 to its natural
height, so the bottom-anchored column pushes up like the real app.
"""
from icons import icon
from kit import composer, esc, md_words, step_row, tb_chat

# ================================================================ chat
CHAT_JS = r"""
  // ---- chat surface ----
  // Aim the tap first, on the final layout, before any tween moves things.
  var TAP = $('.tap-target'), TAPR = TAP ? atFinal(function () { return rectIn(TAP, SCR); }) : null;
  if ($('.r-fm')) { grow('.r-fm', T.bubble - 0.3, 0.4, 'power3.out'); rise('.fm-b', T.bubble - 0.3, { y: 34, s: 0.96, d: 0.4 }); }
  grow('.r-ub', T.bubble, 0.42, 'power3.out');
  rise('.ub-b', T.bubble, { y: 34, s: 0.96, d: 0.42 });
  grow('.r-meta', T.meta, 0.3);
  fadeIn('.dots', T.meta, 0.2);
  var steps = $$('.r-st');
  if (steps.length) {
    showBetween('.dots', -1, T.steps);
    var runs = $$('.m-run');
    runs.forEach(function (e, i) { showBetween(e, T.steps + i * T.step_gap, i + 1 < runs.length ? T.steps + (i + 1) * T.step_gap : T.answer); });
    fadeIn(runs[0], T.steps, 0.2);
    runs.forEach(function (e) { spin(e.querySelector('.spin')); });
    steps.forEach(function (r, i) {
      var t = T.steps + i * T.step_gap;
      grow(r, t, 0.3);
      rise(r.firstElementChild, t, { y: 10, d: 0.3 });
    });
    if (T.fold_steps) steps.forEach(function (r) { fold(r, T.answer, 0.35); });
  } else {
    showBetween('.dots', -1, T.answer);
    $$('.m-run').forEach(function (e) { showBetween(e, -1, -1); });
  }
  dots('.dots', T.meta, T.answer);
  showBetween('.m-done', T.answer, 999);
  fadeIn('.m-done', T.answer, 0.25);
  fadeIn('.tb-title', T.answer, 0.4);
  streamGrow('.r-ans', '.ans', T.answer + 0.05, T.wps);
  grow('.r-card', T.card, 0.5, 'power2.out');
  rise('.cardw > *', T.card, { y: 22, d: 0.45 });
"""


def chat_surface(reel, card_html):
    att = reel.get("attachment")
    rows = []
    if att:
        rows.append(f'<div data-layout-allow-overflow class="r r-fm"><div class="fm"><div class="fm-b"><span class="fm-ic">{icon("h-pdf")}</span>'
                    f'<span class="fm-t"><b>{esc(att["name"])}</b><small>{esc(att.get("meta", ""))}</small></span></div></div></div>')
    rows.append(f'<div data-layout-allow-overflow class="r r-ub"><div class="ub"><p class="ub-b">{esc(reel["prompt"])}</p></div></div>')
    verbs = {"Ran": "Running", "Searched": "Searching", "Read": "Reading"}
    labels = [reel["running"]] if reel.get("running_fixed") else [
        f'{verbs.get(s["text"], s["text"])} {s.get("detail", "")}'.strip() for s in reel.get("steps", [])] or [reel.get("running", "Working")]
    runs = "".join(f'<span class="m-run"><i class="spin"></i>{esc(lb)}</span>' for lb in labels)
    rows.append(f'<div data-layout-allow-overflow class="r r-meta"><div class="meta"><span class="dots"><i></i><i></i><i></i></span>'
                f'{runs}'
                f'<span class="m-done">{esc(reel.get("worked", "Worked for 6s"))}{icon("h-arrow-right01")}</span></div></div>')
    fold = reel.get("fold_steps", True)
    for i, s in enumerate(reel.get("steps", [])):
        rows.append(step_row(s, i).replace('data-layout-allow-overflow class="r r-st', 'data-layout-allow-overflow class="r r-st' + (' r-fold' if fold else ''), 1))
    rows.append(f'<div data-layout-allow-overflow class="r r-ans"><div class="ans">{md_words(reel["answer"])}</div></div>')
    rows.append(f'<div data-layout-allow-overflow class="r r-card"><div class="cardw">{card_html}</div></div>')
    body = (f'<div class="layer surface chat-surface" data-layout-allow-overlap data-layout-allow-occlusion>'
            f'<div class="cv"><div class="col">{"".join(rows)}</div></div>'
            f'{tb_chat(reel.get("chat_title", "New chat"))}{composer()}</div>')
    css = """
.surface { z-index: 1; background: #262624; }
.tb-title { opacity: 0; }
"""
    return body, css, CHAT_JS


# ================================================================ assistant
ASSIST_CSS = """
.surface { z-index: 1; }
.as-surface { --as-on: #E8E4D8; --as-onv: rgba(232, 228, 216, 0.88); --as-surf: rgba(38, 38, 36, 0.975); --as-line: rgba(232, 228, 216, 0.16); --as-high: rgba(76, 76, 72, 0.94); }
.home { position: absolute; inset: 0; overflow: hidden;
  background: radial-gradient(circle at 70% 26%, rgba(255, 196, 150, 0.95) 0, rgba(246, 160, 122, 0.9) 58px, rgba(236, 140, 118, 0) 64px),
    radial-gradient(circle at 70% 26%, rgba(255, 170, 130, 0.35) 0, rgba(255, 170, 130, 0) 190px),
    radial-gradient(90% 40% at 0% 62%, rgba(118, 98, 186, 0.5), transparent 70%),
    linear-gradient(176deg, #171A36 0%, #2B2B58 26%, #5A447A 50%, #A25F7E 72%, #D98172 100%); }
.home::before, .home::after { content: ""; position: absolute; border-radius: 50%; }
.home::before { left: -40%; top: 47%; width: 150%; height: 40%; background: linear-gradient(180deg, #6B4379 0%, #8E5378 45%, #B56A78 100%); transform: rotate(-8deg); }
.home::after { left: 20%; top: 58%; width: 130%; height: 50%; background: linear-gradient(180deg, #7E4A76 0%, #A65E77 50%, #CF7C74 100%); transform: rotate(10deg); }
.ph-glance { position: absolute; z-index: 1; left: 28px; top: 62px; display: flex; align-items: center; gap: 10px; font-size: 21px; color: #FFFFFF; white-space: nowrap; }
.ph-glance i { display: block; width: 1px; height: 20px; background: rgba(255, 255, 255, 0.55); }
.ph-glance svg { width: 21px; height: 21px; color: #E8EAF2; }
.ph-grid, .ph-dock { position: absolute; z-index: 1; left: 10px; right: 10px; display: grid; grid-template-columns: repeat(4, 1fr); justify-items: center; }
.ph-grid { top: 540px; row-gap: 28px; }
.ph-dock { top: 716px; }
.ph-ic { width: 56px; height: 56px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: #33262F; color: #FFB8A1; }
.ph-ic svg { width: 27px; height: 27px; }
.as-scrim { position: absolute; inset: 0; z-index: 2; background: rgba(0, 0, 0, 0.22); opacity: 0; }
.as { position: absolute; z-index: 3; left: 16px; right: 16px; bottom: 26px; font-family: "Arimo", sans-serif; letter-spacing: 0.2px; color: var(--as-on); }
.asw { padding-bottom: 10px; }
.as-panel { padding: 16px 18px; border: 1px solid var(--as-line); border-radius: 22px; background: var(--as-surf); }
.as-brand { font-size: 17.5px; line-height: 1.3; letter-spacing: 2px; color: var(--as-onv); }
.as-status { position: relative; height: 32px; margin-top: 6px !important; }
.as-status span { position: absolute; left: 0; top: 0; font-size: 26px; line-height: 1.2; font-weight: 700; white-space: nowrap; }
.as-heard { padding-top: 8px; font-size: 18px; line-height: 1.38; color: #F09A7C; }
.as-answer { padding-top: 10px; font-size: 18px; line-height: 1.42; color: var(--as-onv); }
.as-answer .wb { font-weight: 700; color: var(--as-on); }
.as-tools { padding: 10px 18px; }
.as-tool { display: flex; align-items: center; gap: 12px; padding: 5px 0; font-size: 18px; line-height: 1.3; color: var(--as-onv); white-space: nowrap; }
.as-tic { position: relative; flex: none; width: 24px; height: 24px; display: flex; align-items: center; justify-content: center; color: var(--ok); }
.as-tic svg { width: 22px; height: 22px; }
.as-tic .as-spin { position: absolute; left: 1px; top: 1px; width: 22px; height: 22px; border: 3px solid transparent; border-top-color: var(--acc); border-right-color: var(--acc); border-radius: 50%; }
.as-wave { display: flex; align-items: center; justify-content: center; gap: 5.4px; height: 60px; padding: 8px 20px; }
.as-wave i { flex: none; width: 4.8px; height: 8px; border-radius: 4px; background: var(--acc); }
.as-btns { display: flex; align-items: center; gap: 10px; height: 52px; margin-top: 10px; }
.as-round { flex: none; width: 52px; height: 52px; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: var(--as-high); color: var(--as-on); }
.as-round svg { width: 24px; height: 24px; }
.as-pill { position: relative; flex: 1; height: 52px; border-radius: 26px; background: var(--acc); color: #FFFFFF; font-size: 18px; font-weight: 700; }
.as-pill > span { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 8px; white-space: nowrap; }
.as-pill svg { width: 22px; height: 22px; }
.as-action { display: flex; align-items: center; gap: 14px; }
.as-action-ic { flex: none; width: 46px; height: 46px; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: rgba(217, 119, 87, 0.18); color: var(--acc); }
.as-action-ic svg { width: 24px; height: 24px; }
.as-action-t { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.as-action-t b { font-size: 19px; font-weight: 700; }
.as-action-t small { font-size: 17.5px; color: var(--as-onv); white-space: nowrap; }
"""

ASSIST_JS = r"""
  // ---- assistant overlay ----
  var TAP = null, TAPR = null;
  tl.fromTo('.as-scrim', { opacity: 0 }, { opacity: 1, duration: 0.3 }, T.as_open);
  tl.fromTo(['.ph-grid', '.ph-dock'], { opacity: 1 }, { opacity: 0.12, duration: 0.3 }, T.as_open);
  tl.fromTo('.ph-glance', { opacity: 1 }, { opacity: 0, duration: 0.3 }, T.as_places);
  tl.fromTo('.ph-glance', { opacity: 0 }, { opacity: 1, duration: 0.3, immediateRender: false }, T.as_act + 0.2);
  grow('.r-dock', T.as_open, 0.4, 'power3.out');
  rise('.r-dock .asw', T.as_open, { y: 40, d: 0.4 });
  grow('.r-stat', T.as_heard, 0.35, 'power3.out');
  rise('.r-stat .as-panel', T.as_heard, { y: 20, d: 0.35 });
  // The request shows while listening, hides while the turn runs, and returns quoted with the answer.
  grow('.r-heard', T.as_heard, 0.35, 'power3.out');
  stream('.as-heard', T.as_heard + 0.15, T.heard_wps);
  fold('.r-heard', T.as_work, 0.3);
  (function () {
    var e = $('.as-heard');
    ups.push(function (t) { var d = (t < T.as_work + 0.32 || t >= T.as_act) ? '' : 'none'; if (e.__d !== d) { e.style.display = d; e.__d = d; } });
  })();
  grow('.r-heard', T.as_act, 0.35);
  showBetween('.s-listen', -1, T.as_work); showBetween('.s-work', T.as_work, T.as_act); showBetween('.s-done', T.as_act, 999);
  showBetween('.p-pause', -1, T.as_work); showBetween('.p-work', T.as_work, T.as_act); showBetween('.p-pause2', T.as_act, 999);
  grow('.r-tools', T.as_work, 0.3);
  $$('.r-tool').forEach(function (r, i) {
    var t = i < 2 ? T.as_work + 0.1 + i * T.as_tool_gap : T.as_nav;
    grow(r, t, 0.3); rise(r.firstElementChild, t, { y: 8, d: 0.3 });
  });
  spin('.as-spin');
  showBetween('.as-spin', -1, T.as_nav_ok); showBetween('.t3-ok', T.as_nav_ok, 999);
  pop('.t3-ok', T.as_nav_ok, { s: 0.3 });
  grow('.r-places', T.as_places, 0.5, 'power2.out');
  rise('.r-places .as-panel', T.as_places, { y: 26, d: 0.45 });
  fold('.r-places', T.as_act, 0.4);
  grow('.r-act', T.as_act, 0.4, 'back.out(1.4)');
  pop('.r-act .as-panel', T.as_act, { s: 0.9, ease: 'back.out(2)' });
  streamGrow('.r-aans', '.as-answer', T.as_act + 0.1, T.wps);
  // Waveform (uc-assistant.css / _WavePainter): listening level vs busy line.
  var env = [0.142, 0.282, 0.415, 0.541, 0.655, 0.756, 0.841, 0.91, 0.959, 0.99, 1, 0.99, 0.959, 0.91, 0.841, 0.756, 0.655, 0.541, 0.415, 0.282, 0.142];
  var bars = $$('.as-wave i');
  ups.push(function (t) {
    var busy = t >= T.as_work && t < T.as_act;
    var talking = t >= T.as_heard && t < T.as_heard + 1.0;
    var level = talking ? 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3)) : 0.1;
    for (var i = 0; i < bars.length; i++) {
      var wave = 0.5 + 0.5 * Math.sin((t / 1.8) * Math.PI * 2 + i * 0.8);
      var h = busy ? 4 + 8 * wave : Math.min(40, 4 + (3 + 33 * level) * env[i] * (0.45 + 0.55 * wave));
      bars[i].style.height = h.toFixed(2) + 'px';
      var c = busy ? 'rgba(232,228,216,0.52)' : '#D97757';
      if (bars[i].__c !== c) { bars[i].style.background = c; bars[i].__c = c; }
    }
  });
"""


def assistant_surface(reel, card_html):
    a = reel["assistant"]
    grid = ["h-calendar01", "h-clock01", "h-image01", "asst-sun", "asst-note", "asst-folder", "h-settings02", "asst-logo"]
    dock = ["asst-call", "asst-message", "h-globe02", "asst-camera"]
    gridh = "".join(f'<span class="ph-ic">{icon(g)}</span>' for g in grid)
    dockh = "".join(f'<span class="ph-ic">{icon(g)}</span>' for g in dock)
    check = icon("asst-check")
    tools = ""
    for i, t in enumerate(a["tools"]):
        tic = (f'<span class="as-tic"><i class="as-spin"></i><span class="t3-ok">{check}</span></span>' if i == 2
               else f'<span class="as-tic">{check}</span>')
        tools += f'<div data-layout-allow-overflow class="r r-tool"><p class="as-tool">{tic}{esc(t)}</p></div>'
    bars = "".join("<i></i>" for _ in range(21))
    body = f"""<div class="layer surface as-surface" data-layout-allow-overlap data-layout-allow-occlusion>
      <div class="home">
        <div class="ph-glance"><span>{esc(a.get("date", "Fri, Sep 25"))}</span><i></i>{icon("asst-cloud")}<span>{esc(a.get("temp", "14°C"))}</span></div>
        <div class="ph-grid">{gridh}</div>
        <div class="ph-dock">{dockh}</div>
      </div>
      <div class="as-scrim"></div>
      <div class="as">
        <div data-layout-allow-overflow class="r r-places r-fold"><div class="asw">{card_html}</div></div>
        <div data-layout-allow-overflow class="r r-act"><div class="asw"><div class="as-panel"><div class="as-action"><span class="as-action-ic">{icon("asst-nav-r")}</span>
          <span class="as-action-t"><b>{esc(a["action"])}</b><small>{esc(a["action_detail"])}</small></span></div></div></div></div>
        <div data-layout-allow-overflow class="r r-stat"><div class="asw"><div class="as-panel">
          <p class="as-brand">CHUK CHAT</p>
          <p class="as-status"><span class="s-listen">Listening</span><span class="s-work">Working …</span><span class="s-done">Listening</span></p>
          <div data-layout-allow-overflow class="r r-heard"><p class="as-heard">{md_words("“" + reel["prompt"] + "”")}</p></div>
          <div data-layout-allow-overflow class="r r-aans"><div class="as-answer">{md_words(reel["answer"])}</div></div>
        </div></div></div>
        <div data-layout-allow-overflow class="r r-tools"><div class="asw"><div class="as-panel as-tools">{tools}</div></div></div>
        <div data-layout-allow-overflow class="r r-dock"><div class="asw" style="padding-bottom:0"><div class="as-panel as-wave">{bars}</div>
          <div class="as-btns"><span class="as-round">{icon("h-plus-sign")}</span>
            <span class="as-pill"><span class="p-pause">{icon("h-mic02")}Pause</span><span class="p-work">{icon("h-mic02")}Working …</span><span class="p-pause2">{icon("h-mic02")}Pause</span></span>
            <span class="as-round">{icon("h-cancel01")}</span></div></div></div>
      </div>
    </div>"""
    return body, ASSIST_CSS, ASSIST_JS
