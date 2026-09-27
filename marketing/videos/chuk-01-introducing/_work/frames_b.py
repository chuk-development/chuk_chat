"""Frames 04 founders, 05 business, 06 connectors."""
from icons import icon
from kit import (APP_H, APP_W, APP_X, APP_Y, ZOOM, acts, art_card, chrome, composer, esc,
                 headband, page, panel_foot, panel_head, step, tl_head, words, write)

SPLIT_CSS = """
    .split .a-chat { flex: 0 0 476px; }
"""

# ---------------------------------------------------------------- 04 founders
DAWN_CSS = """
    .sky-dawn { background: linear-gradient(180deg, #F4E6D4 0%, #F6D4A6 48%, #F1B872 78%, #E8A150 100%); }
    .sc-sun { position: absolute; left: 60px; top: 560px; width: 520px; height: 520px; border-radius: 50%;
      background: radial-gradient(circle, #FFF3D1 0 34%, #FAD08A 56%, rgba(250, 208, 138, 0) 71%); }
    .sc-hills { position: absolute; left: 0; right: 0; bottom: 0; width: 1920px; height: 346px; }
"""

BIKE = ('<svg viewBox="0 0 200 110" preserveAspectRatio="xMidYMid meet"><g fill="none" stroke="#29251F" stroke-width="5" '
        'stroke-linecap="round" stroke-linejoin="round"><circle cx="52" cy="74" r="26"/><circle cx="148" cy="74" r="26"/>'
        '<path d="M52 74 L82 34 H132 L148 74 M82 34 L104 74 L132 34 M104 74 H52" stroke="#1F6F5C"/>'
        '<path d="M76 26 H92 M126 22 L132 34 M122 22 H138"/></g></svg>')


def f04():
    fid, dur = "04-founders", 7.2
    ask = "Build a landing page for my bike repair service and publish it."
    done = "Done. Your page is live, and anyone with the link can open it: "
    url = "https://artifacts.chuk.chat/k7f2-spoke"
    css = DAWN_CSS + SPLIT_CSS + """
    .f4-cam { position: absolute; inset: 0; transform-origin: 1420px 150px; }
    .f4-bub:empty { visibility: hidden; }
"""
    body = f"""
    <div class="clip fill sky-dawn" data-start="0" data-duration="{dur}" data-track-index="0">
      <div class="sc-sun f4-sun"></div>
      <svg class="sc-hills" viewBox="0 0 1440 320" preserveAspectRatio="none"><path d="M0 210 C240 150 420 190 640 170 C860 150 1080 110 1440 160 L1440 320 L0 320 Z" fill="#E7B070" opacity=".55"/><path d="M0 250 C200 220 460 240 720 225 C980 210 1200 200 1440 230 L1440 320 L0 320 Z" fill="#D9955A" opacity=".6"/></svg>
    </div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      {headband("02 — Building a product to sell", "From idea to launch page in one chat.")}
      <div class="f4-cam">
        <div class="winpos f4-win">
          <div class="app split f4-app">
            {chrome()}
            <div class="a-chat f4-chat">
              <div class="a-thread"><div class="a-col">
                <div class="a-user"><p class="a-bubble f4-bub"></p></div>
                <div class="a-tl f4-tl">{tl_head("Running create artifact", "Worked for 12s", "f4")}
                  <div class="a-steps ovl f4-steps">{step("run", "artifact manager", cls="f4-s1")}{step("run", "create artifact", cls="f4-s2")}</div>
                </div>
                {art_card("h-code-m", "Spoke landing page", "HTML · v1", "f4-art")}
                <div class="a-ai f4-ans"><p>{words(done)}<a>{words(url)}</a></p></div>
              </div></div>
              {composer()}
            </div>
            <div class="a-panel f4-panel"><div class="a-panel-in">
              {panel_head("h-code-m", "Spoke landing page", "HTML")}
              <div class="a-pb">
                <div class="lp">
                  <div class="lp-nav f4-lp1"><b>Spoke</b><span>Prices</span><span>Areas</span><span>Book</span></div>
                  <div class="lp-hero f4-lp2">
                    <p class="lp-title">Bike repair at your door.</p>
                    <p class="lp-sub">We come to you. Fixed prices, same-day visits.</p>
                    <span class="lp-btn">Book a repair</span>
                  </div>
                  <div class="lp-art f4-lp3">{BIKE}</div>
                  <div class="lp-feats"><span class="f4-ft">Same-day visits</span><span class="f4-ft">Fixed prices</span><span class="f4-ft">All brands</span></div>
                </div>
              </div>
              {panel_foot()}
            </div></div>
          </div>
        </div>
      </div>
    </div>"""
    js = f"""
  headline(0.0);
  headOut(1.0);
  winIn('.f4-win', 1.0);
  tl.fromTo('.f4-sun', {{ y: 150 }}, {{ y: -40, duration: DUR, ease: 'power1.out' }}, 0);
  // chat sits centred until the panel opens
  tl.fromTo('.f4-chat', {{ x: 238 }}, {{ x: 238, duration: 0.01 }}, 0);
  tl.fromTo('.f4-panel', {{ x: 480 }}, {{ x: 480, duration: 0.01 }}, 0);
  var tType = type($('.f4-bub'), {ask!r}, 1.3, 40);
  rise('.f4-tl', tType + 0.05, {{ y: 8, d: 0.3 }});
  spin($('.f4-spin'));
  showBetween($('.f4-run'), -1, 3.9);
  showBetween($('.f4-done'), 3.9, 99);
  rise('.f4-s1', tType + 0.2, {{ y: 6, d: 0.3 }});
  rise('.f4-s2', tType + 0.55, {{ y: 6, d: 0.3 }});
  fadeOut('.f4-steps', 3.75, 0.15);
  rise('.f4-art', 3.95, {{ y: 10, d: 0.4 }});
  // the artifact panel opens on the downbeat: chat slides left, panel slides in
  tl.fromTo('.f4-chat', {{ x: 238 }}, {{ x: 0, duration: 0.7, ease: 'power3.inOut', immediateRender: false }}, 4.1);
  tl.fromTo('.f4-panel', {{ x: 480 }}, {{ x: 0, duration: 0.7, ease: 'power3.inOut', immediateRender: false }}, 4.1);
  rise('.f4-lp1', 4.45, {{ y: 10, d: 0.35 }});
  rise('.f4-lp2', 4.6, {{ y: 14, d: 0.45 }});
  rise('.f4-lp3', 4.75, {{ y: 14, d: 0.45 }});
  $$('.f4-ft').forEach(function (e, i) {{ rise(e, 4.9 + i * 0.08, {{ y: 10, d: 0.35 }}); }});
  stream($('.f4-ans'), 5.15, 16);
  // camera: push toward the published page
  tl.fromTo('.f4-cam', {{ scale: 1 }}, {{ scale: 1.1, duration: 1.8, ease: 'power2.inOut' }}, 4.6);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 05 business
DAY_CSS = """
    .sky-day { background: linear-gradient(180deg, #F9F1E4 0%, #F2E4CE 100%); }
    .sc-awning { position: absolute; top: 0; left: 0; right: 0; height: 50px;
      background: repeating-linear-gradient(90deg, #D7775A 0 64px, #FAF3E8 64px 128px); box-shadow: 0 6px 24px rgba(120, 60, 30, 0.12); }
    .sc-awning::after { content: ""; position: absolute; left: 0; right: 0; bottom: -16px; height: 16px;
      background: radial-gradient(circle at 32px 0, #D7775A 16px, transparent 16.5px) 0 0 / 128px 16px repeat-x,
                  radial-gradient(circle at 96px 0, #FAF3E8 16px, transparent 16.5px) 0 0 / 128px 16px repeat-x; }
    .sc-beams { position: absolute; left: -400px; right: -400px; top: -200px; bottom: -200px;
      background: linear-gradient(112deg, transparent 28%, rgba(255, 255, 255, 0.6) 36%, transparent 44%, transparent 54%, rgba(255, 255, 255, 0.45) 60%, transparent 67%); }
"""


def f05():
    fid, dur = "05-business", 7.2
    ask = "Write the invoice for Mrs Weber: kitchen shelf, 6 hours at €58, material €140. As PDF."
    ask2 = "Now write Mrs Weber a short email about it."
    body_txt = ("Dear Mrs Weber, thank you for your order. Here is the invoice for the kitchen shelf. "
                "Total: €488.00, payable within 14 days. Kind regards, Jan Brandt")
    css = DAY_CSS + SPLIT_CSS + """
    .b5-cam { position: absolute; inset: 0; transform-origin: 1420px 150px; }
    .b5-bub:empty { visibility: hidden; }
    .b5-hl { background: rgba(217, 119, 87, 0.0); margin: 0 -8px; padding-left: 8px; padding-right: 8px; border-radius: 4px; }
"""
    body = f"""
    <div class="clip fill sky-day" data-start="0" data-duration="{dur}" data-track-index="0">
      <div class="sc-beams b5-beams"></div><div class="sc-awning"></div>
    </div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      {headband("03 — Running a small business", "The office work,|done between two jobs.")}
      <div class="b5-cam">
        <div class="winpos b5-win">
          <div class="app split b5-app">
            {chrome()}
            <div class="a-chat b5-chat">
              <div class="a-thread"><div class="a-col b5-col">
                <div class="a-user"><p class="a-bubble b5-bub"></p></div>
                <div class="a-tl b5-tl">{tl_head("Compiling document", "Worked for 6s", "b5")}
                  <div class="a-steps ovl b5-steps">{step("run", "typst compile", cls="b5-s1")}</div>
                </div>
                {art_card("h-pdf", "Invoice Mrs Weber", "Typst · PDF · v1", "b5-art")}
                <div class="a-user b5-u2"><p class="a-bubble">{esc(ask2)}</p></div>
                <div class="a-mail b5-mail">
                  <div class="a-mail-h">{icon("h-email", "i18")}<span>Your invoice 2026-031</span></div>
                  <div class="a-mail-b">
                    <p class="a-mail-row"><span>To</span>weber@example.de</p>
                    <p class="a-mail-t">{esc(body_txt)}</p>
                    <span class="a-mail-btn b5-mbtn">{icon("h-link01", "z16")}Open in Mail App</span>
                  </div>
                </div>
              </div></div>
              {composer()}
            </div>
            <div class="a-panel b5-panel"><div class="a-panel-in">
              {panel_head("h-pdf", "Invoice Mrs Weber", "Typst")}
              <div class="a-pb a-pb--pdf">
                <div class="a-page b5-page">
                  <p class="doc-from b5-d1">Brandt Carpentry · Hafenstraße 12 · 24103 Kiel</p>
                  <div class="doc-top b5-d2"><b>Invoice</b><span>No. 2026-031</span></div>
                  <p class="doc-to b5-d3">Mrs Weber</p>
                  <div class="doc-row b5-d4"><span>Kitchen shelf, labour 6 h × €58</span><span>€348.00</span></div>
                  <div class="doc-row b5-d5"><span>Material</span><span>€140.00</span></div>
                  <div class="doc-row doc-total b5-d6 b5-hl"><span>Total</span><span>€488.00</span></div>
                </div>
              </div>
              {panel_foot()}
            </div></div>
          </div>
        </div>
      </div>
    </div>"""
    js = f"""
  headline(0.0);
  headOut(1.0);
  winIn('.b5-win', 1.0);
  tl.fromTo('.b5-beams', {{ x: -60 }}, {{ x: 80, duration: DUR, ease: 'none' }}, 0);
  tl.fromTo('.b5-chat', {{ x: 238 }}, {{ x: 238, duration: 0.01 }}, 0);
  tl.fromTo('.b5-panel', {{ x: 480 }}, {{ x: 480, duration: 0.01 }}, 0);
  var tType = type($('.b5-bub'), {ask!r}, 1.3, 60);
  rise('.b5-tl', tType + 0.06, {{ y: 8, d: 0.3 }});
  spin($('.b5-spin'));
  showBetween($('.b5-run'), -1, 3.35);
  showBetween($('.b5-done'), 3.35, 99);
  rise('.b5-s1', tType + 0.2, {{ y: 6, d: 0.3 }});
  fadeOut('.b5-steps', 3.2, 0.14);
  rise('.b5-art', 3.37, {{ y: 10, d: 0.4 }});
  tl.fromTo('.b5-chat', {{ x: 238 }}, {{ x: 0, duration: 0.7, ease: 'power3.inOut', immediateRender: false }}, 3.5);
  tl.fromTo('.b5-panel', {{ x: 480 }}, {{ x: 0, duration: 0.7, ease: 'power3.inOut', immediateRender: false }}, 3.5);
  ['.b5-d1', '.b5-d2', '.b5-d3', '.b5-d4', '.b5-d5'].forEach(function (q, i) {{ rise(q, 3.95 + i * 0.14, {{ y: 8, d: 0.35 }}); }});
  tl.fromTo('.b5-d6', {{ opacity: 0, scale: 0.94 }}, {{ opacity: 1, scale: 1, duration: 0.4, ease: 'back.out(2.2)' }}, 4.8);
  tl.fromTo('.b5-d6', {{ backgroundColor: 'rgba(217,119,87,0.28)' }}, {{ backgroundColor: 'rgba(217,119,87,0)', duration: 1.2, ease: 'power1.out', immediateRender: false }}, 4.8);
  // second message: the thread scrolls up, the email card lands
  tl.fromTo('.b5-col', {{ y: 0 }}, {{ y: -214, duration: 0.55, ease: 'power3.inOut' }}, 5.3);
  rise('.b5-u2', 5.35, {{ y: 60, d: 0.5 }});
  rise('.b5-mail', 5.95, {{ y: 16, d: 0.45 }});
  // camera: push toward the invoice and hold
  tl.fromTo('.b5-cam', {{ scale: 1 }}, {{ scale: 1.06, duration: 1.1, ease: 'power2.inOut' }}, 3.9);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 06 connectors
NET_CSS = """
    .sky-net { background: radial-gradient(ellipse at 50% 50%, #F4F6F0 0%, #E6ECE2 70%, #DCE4D7 100%); }
    .sc-web { position: absolute; left: -96px; top: -54px; width: 2112px; height: 1188px; }
    .c6-node { position: absolute; left: 0; top: 0; width: 100px; height: 100px; margin: -50px 0 0 -50px; }
    .c6-tile { width: 100px; height: 100px; border-radius: 26px; background: #fff; display: flex; align-items: center; justify-content: center;
      box-shadow: 0 12px 30px rgba(40, 60, 40, 0.14), 0 0 0 1px rgba(40, 60, 40, 0.07); }
    .c6-tile img { width: 56px; height: 56px; object-fit: contain; display: block; }
    .c6-cam { position: absolute; inset: 0; transform-origin: 960px 150px; }
    .c6-lg { background: #fff; border-color: rgba(255, 255, 255, 0.4); }
    .c6-lg img { width: 19px; height: 19px; object-fit: contain; display: block; }
"""

ORBIT = ["github", "linear", "stripe", "dropbox", "todoist", "figma", "calcom", "notion", "airtable",
         "zapier", "asana", "sentry"]


def logo_step(logo, text_html):
    return (f'<div class="a-step"><span class="a-badge c6-lg" style="background: #fff url(\'assets/logos/connectors/{logo}.png\') center / 19px 19px no-repeat"></span>'
            f'<span class="a-step-t">{text_html}</span></div>')


def f06():
    fid, dur = "06-connectors", 7.2
    ask = "What is due this week? Check Linear, Todoist and Notion, then make me a plan."
    lead = "Your week, in order:"
    items = ["Mon: fix the login bug (Linear, high priority)",
             "Tue: send the Q3 report (Todoist)",
             "Thu: review the launch plan (Notion)"]
    lis = "".join(f"<li>{words(i)}</li>" for i in items)
    nodes = "".join(
        f'<div class="c6-node"><div class="c6-tile"><img src="assets/logos/connectors/{k}.png" alt=""/></div></div>'
        for k in ORBIT)
    steps = (logo_step("linear", "Ran linear list issues").replace('class="a-step"', 'class="a-step c6-s1"')
             + logo_step("todoist", "Ran todoist find-tasks").replace('class="a-step"', 'class="a-step c6-s2"')
             + logo_step("notion", "Searched<b>launch plan</b>").replace('class="a-step"', 'class="a-step c6-s3"'))
    body = f"""
    <div class="clip fill sky-net" data-start="0" data-duration="{dur}" data-track-index="0">
      <svg class="sc-web c6-web" viewBox="0 0 1440 900" preserveAspectRatio="xMidYMid slice"><g stroke="#9DB39A" stroke-width="1" fill="none" opacity=".55"><path d="M110 140 L720 450 L1320 120"/><path d="M60 520 L720 450 L1380 560"/><path d="M200 820 L720 450 L1240 830"/><path d="M420 60 L720 450 L1010 40"/><path d="M110 140 L60 520 L200 820"/><path d="M1320 120 L1380 560 L1240 830"/></g><circle cx="720" cy="450" r="260" stroke="#B7C8B3" stroke-dasharray="3 7" fill="none"/><circle cx="720" cy="450" r="420" stroke="#C9D6C5" stroke-dasharray="2 9" fill="none"/></svg>
    </div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="c6-orbit">{nodes}</div>
      {headband("04 — Connecting every tool", "All your tools.|One chat to drive them.")}
      <div class="c6-cam">
        <div class="winpos c6-win">
          <div class="app c6-app">
            {chrome()}
            <div class="a-chat">
              <div class="a-thread"><div class="a-col">
                <div class="a-user"><p class="a-bubble c6-bub"></p></div>
                <div class="a-tl c6-tl">{tl_head("Running todoist find-tasks", "Worked for 9s", "c6")}
                  <div class="a-steps ovl c6-steps">{steps}</div>
                </div>
                <div class="a-ai c6-ans"><p><strong>{words(lead)}</strong></p><ul>{lis}</ul></div>
                <div class="c6-acts">{acts()}</div>
              </div></div>
              {composer()}
            </div>
          </div>
        </div>
      </div>
    </div>"""
    js = f"""
  headline(0.0);
  headOut(1.62);
  winIn('.c6-win', 1.6);
  tl.fromTo('.c6-web', {{ rotation: 0 }}, {{ rotation: 6, duration: DUR, ease: 'none', transformOrigin: '50% 50%' }}, 0);
  // the tools orbit the headline, then get pulled into the one chat
  var nodes = $$('.c6-node'), N = nodes.length;
  ups.push(function (t) {{
    var k = c01((t - 1.5) / 0.45); k = k * k;
    for (var i = 0; i < N; i++) {{
      var a = (i / N) * Math.PI * 2 + 0.22 * t - 0.5;
      var x = 960 + 830 * Math.cos(a), y = 540 + 410 * Math.sin(a);
      var pop = c01((t - 0.04 - i * 0.035) / 0.35);
      var sc = (0.4 + 0.6 * (1 - Math.pow(1 - pop, 3))) * (1 - 0.7 * k);
      var px = x + (960 - x) * k, py = y + (620 - y) * k;
      nodes[i].style.transform = 'translate(' + px.toFixed(1) + 'px,' + py.toFixed(1) + 'px) scale(' + sc.toFixed(3) + ')';
      nodes[i].style.opacity = (pop * (1 - k)).toFixed(3);
    }}
  }});
  var tType = type($('.c6-bub'), {ask!r}, 2.0, 52);
  rise('.c6-tl', tType + 0.05, {{ y: 8, d: 0.3 }});
  spin($('.c6-spin'));
  showBetween($('.c6-run'), -1, 4.8);
  showBetween($('.c6-done'), 4.8, 99);
  rise('.c6-s1', 3.65, {{ y: 6, d: 0.3 }});
  rise('.c6-s2', 4.0, {{ y: 6, d: 0.3 }});
  rise('.c6-s3', 4.35, {{ y: 6, d: 0.3 }});
  fadeOut('.c6-steps', 4.66, 0.14);
  var endA = stream($('.c6-ans'), 4.85, 16);
  fadeIn('.c6-acts', endA + 0.05, 0.3);
  tl.fromTo('.c6-cam', {{ scale: 1 }}, {{ scale: 1.07, duration: 2.0, ease: 'power2.inOut' }}, 4.8);
"""
    return write(fid, page(fid, dur, NET_CSS, body, js))


if __name__ == "__main__":
    for f in (f04, f05, f06):
        print(f())
