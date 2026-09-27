"""Frames 01 hook, 02 title, 03 private."""
from icons import icon
from kit import (APP_X, APP_Y, ZOOM, acts, chrome, composer, cursor, esc, headband,
                 page, tl_head, words, write)

PAPER_BG = """
    .lg-box { position: relative; }
    .lg-half { position: absolute; left: 0; top: 0; width: 100%; height: 100%; display: block; overflow: visible; }
    .paper { background: radial-gradient(ellipse 80% 70% at 50% 45%, #FDFBF7 0%, #FAF7F0 62%, #F3EFE5 100%); }
"""

LOGO_A = ("M2365 4644c-123-17-233-41-310-66-641-213-1147-829-1251-1521-20-136-20-368 1-493 79-468 376-837 "
          "785-977 135-46 265-67 418-67 208 0 366 34 609 131 88 35 103 44 107 67 6 27 106 651 106 659 0 2-30-20-67-50"
          "-141-112-280-186-428-229-117-33-319-33-425 0-123 39-187 78-285 177-76 75-99 106-138 185-60 120-86 224-94 "
          "370-11 213 35 416 141 636 66 135 146 243 257 350 139 132 288 219 444 260 100 26 316 26 405 0 148-44 273-123 "
          "361-228 29-35 51-54 54-46 11 35 105 663 100 675-11 31-223 116-370 149-67 15-353 27-420 18z")
LOGO_B = ("M2758 3464c-89-16-231-60-375-115-89-35-102-43-107-67-6-28-106-651-106-659 0-3 21 14 47 37 115 101 302 "
          "201 453 242 69 19 109 23 215 22 220-1 342-52 495-204 70-70 94-102 133-180 72-144 90-224 91-410 0-92-5-185"
          "-13-229-30-167-114-372-211-517-73-108-235-269-340-336-170-109-284-142-485-142-133 0-145 1-238 33-120 41-239 "
          "121-315 210-30 36-54 56-57 49-11-34-105-663-101-674 11-29 183-102 331-140 82-21 131-27 265-31 261-8 455 32 "
          "690 144 213 100 438 271 600 454 241 273 414 639 465 986 21 141 21 375-1 501-91 539-471 940-973 1026-116 "
          "20-354 20-463 0z")


def logo_svg(cls, color="#26251F"):
    """Two stacked single-path SVGs in one box, so each half can move as an HTML layer."""
    g = 'transform="translate(0 500) scale(.1 -.1)"'
    half = lambda k, d: (f'<svg class="lg-half {cls}-{k}" viewBox="0 0 500 500" aria-hidden="true">'
                         f'<g {g}><path fill="{color}" d="{d}"/></g></svg>')
    return f'<div class="lg-box {cls}">{half("a", LOGO_A)}{half("b", LOGO_B)}</div>'


LOGO_CSS = """
    .lg-box { position: relative; }
    .lg-half { position: absolute; left: 0; top: 0; width: 100%; height: 100%; display: block; overflow: visible; }
"""


# ---------------------------------------------------------------- 01 hook
def f01():
    fid, dur = "01-hook", 5.205
    prompt = "How do I tell my boss that I am burned out?"
    Z = 1.9
    CX, CY = 238, 398  # composer top-left in frame px
    css = PAPER_BG + f"""
    .h1-cam {{ position: absolute; inset: 0; transform-origin: 960px 528px; }}
    .h1-comp {{ position: absolute; left: {CX}px; top: {CY}px; }}
    .h1-comp .a-composer {{ zoom: {Z}; width: 760px; box-shadow: 0 30px 70px -24px rgba(38, 37, 31, 0.5); }}
    .h1-comp .a-field {{ color: var(--fg); position: relative; }}
    .h1-ph {{ color: rgba(232, 228, 216, 0.8); }}
    .h1-typed {{ color: var(--fg); white-space: pre; }}
    .h1-caret {{ display: inline-block; width: 2px; height: 19px; margin-left: 1px; vertical-align: -3px; background: var(--acc); }}
    .h1-fly {{ position: absolute; left: {CX + 900}px; top: {CY - 20}px; }}
    .h1-fly .a-bubble {{ zoom: 1.8; max-width: none; white-space: nowrap; }}
"""
    body = f"""
    <div class="clip fill paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="h1-cam">
        <div class="h1-comp a-vars">
          <div class="a-composer">
            <div class="a-field"><span class="h1-ph">Ask me anything !</span><span class="h1-typed"></span><i class="h1-caret"></i></div>
            <div class="a-row">
              <span class="a-btn a-plus">{icon("h-plus-sign", "z24")}</span>
              <span class="a-grow"></span>
              <span class="a-pill">{icon("h-flash", "z15")}<b>Fast</b>{icon("h-arrow-down01", "z12 a-dn")}</span>
              <span class="a-btn a-mic">{icon("h-mic02", "z22")}</span>
              <span class="a-send h1-send">{icon("h-send-horizontal", "z26")}</span>
            </div>
          </div>
        </div>
        <div class="h1-fly a-vars"><p class="a-bubble h1-bub">{esc(prompt)}</p></div>
        {cursor("h1")}
      </div>
    </div>"""
    field = (CX + 200 * Z, CY + 30 * Z)
    send = (CX + 722 * Z, CY + 34 * Z)
    js = f"""
  var cur = $('.h1-cur'), rip = $('.h1-rip');
  var T0 = 0.72, CPS = 13.2;
  // camera: slow push for the whole hook
  tl.fromTo('.h1-cam', {{ scale: 1 }}, {{ scale: 1.055, duration: DUR, ease: 'power1.inOut' }}, 0);
  // cursor: moving at frame 0, clicks the field, rests, then goes to send
  cursorPath(cur, [[0, 1330, 860], [0.5, {field[0]-4:.0f}, {field[1]-3:.0f}, 0.5],
                   [1.35, {field[0]+180:.0f}, {field[1]+120:.0f}, 0.7],
                   [4.55, {send[0]-4:.0f}, {send[1]-3:.0f}, 0.62]]);
  tl.set(rip, {{ x: {field[0]:.0f}, y: {field[1]:.0f} }}, 0.54);
  click(cur, rip, 0.55);
  tl.set(rip, {{ x: {send[0]:.0f}, y: {send[1]:.0f} }}, 4.9);
  click(cur, rip, 4.905);
  // placeholder -> typing
  var ph = $('.h1-ph'), typed = $('.h1-typed'), car = $('.h1-caret');
  showBetween(ph, -1, 0.55);
  var tEnd = type(typed, {prompt!r}, T0, CPS);
  caret(car, T0, tEnd, 4.905);
  ups.push(function (t) {{ car.style.display = t < 0.55 ? 'none' : ''; }});
  // send pop on the downbeat (4.905)
  var send = $('.h1-send');
  tl.fromTo(send, {{ scale: 1 }}, {{ scale: 0.88, duration: 0.09, ease: 'power2.in', immediateRender: false }}, 4.815);
  tl.fromTo(send, {{ scale: 0.88 }}, {{ scale: 1.2, duration: 0.11, ease: 'power2.out', immediateRender: false }}, 4.905);
  tl.fromTo(send, {{ scale: 1.2 }}, {{ scale: 1, duration: 0.2, ease: 'power2.inOut', immediateRender: false }}, 5.015);
  // the message leaves as a bubble; the field clears
  tl.fromTo(typed, {{ opacity: 1 }}, {{ opacity: 0, duration: 0.01, immediateRender: false }}, 4.905);
  var bub = $('.h1-bub');
  tl.fromTo(bub, {{ opacity: 0 }}, {{ opacity: 1, duration: 0.01 }}, 4.905);
  tl.fromTo(bub, {{ x: -887, y: 36 }}, {{ x: -380, y: -112, duration: 0.3, ease: 'power3.out' }}, 4.905);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 02 title
def f02():
    fid, dur = "02-title", 4.5
    css = PAPER_BG + """
    .t2-grp { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; transform-origin: 960px 520px; }
    .t2-logo { width: 150px; height: 150px; overflow: visible; }
    .t2-title { margin-top: 44px; font-family: "Arimo", sans-serif; font-size: 118px; font-weight: 400; letter-spacing: -0.045em; line-height: 1; color: #26251F; white-space: nowrap; }
    .t2-title .wd { display: inline-block; }
    .t2-title .t2-soft { color: #8C8A80; }
    .t2-eb { margin-top: 42px; height: 30px; font-family: "Chuk Chat Mono", monospace; font-size: 28px; font-weight: 600; letter-spacing: 0.2em; text-transform: uppercase; color: #B8860B; white-space: pre; }
"""
    body = f"""
    <div class="clip fill paper" data-start="0" data-duration="{dur}" data-track-index="0"></div>
    <div class="clip fill" data-start="0" data-duration="{dur}" data-track-index="1">
      <div class="t2-grp">
        {logo_svg("t2-logo")}
        <h1 class="t2-title"><span class="wd t2-soft">Introducing</span> <span class="wd">Chuk</span> <span class="wd">Chat</span></h1>
        <p class="t2-eb"></p>
      </div>
    </div>"""
    js = """
  tl.fromTo('.t2-logo-a', { x: -120, y: -70, rotation: -80, opacity: 0, transformOrigin: '50% 50%' },
    { x: 0, y: 0, rotation: 0, opacity: 1, duration: 0.62, ease: 'power3.out', transformOrigin: '50% 50%' }, 0);
  tl.fromTo('.t2-logo-b', { x: 120, y: 70, rotation: -80, opacity: 0, transformOrigin: '50% 50%' },
    { x: 0, y: 0, rotation: 0, opacity: 1, duration: 0.62, ease: 'power3.out', transformOrigin: '50% 50%' }, 0);
  $$('.t2-title .wd').forEach(function (w, i) {
    tl.fromTo(w, { opacity: 0, y: 60 }, { opacity: 1, y: 0, duration: 0.6, ease: 'power3.out' }, 0.16 + i * 0.09);
  });
  type($('.t2-eb'), 'Private AI chat from Germany', 2.1, 34);
  tl.fromTo('.t2-grp', { scale: 1 }, { scale: 1.04, duration: DUR, ease: 'power1.inOut' }, 0);
"""
    return write(fid, page(fid, dur, css, body, js))


# ---------------------------------------------------------------- 03 private
NIGHT_CSS = """
    .sky-night { background: radial-gradient(ellipse at 50% 120%, rgba(90, 110, 190, 0.35), transparent 60%), linear-gradient(180deg, #0A0F1F 0%, #131A33 55%, #1D2444 100%); }
    .sc-stars { position: absolute; left: 0; right: 0; top: -120px; bottom: 0;
      background-image:
        radial-gradient(2.2px 2.2px at 6% 14%, #fff 50%, transparent 52%), radial-gradient(1.6px 1.6px at 14% 38%, #fff 50%, transparent 52%),
        radial-gradient(2.4px 2.4px at 22% 8%, #fff 50%, transparent 52%), radial-gradient(1.6px 1.6px at 31% 26%, #fff 50%, transparent 52%),
        radial-gradient(2px 2px at 39% 12%, #fff 50%, transparent 52%), radial-gradient(1.4px 1.4px at 46% 34%, #fff 50%, transparent 52%),
        radial-gradient(2.2px 2.2px at 55% 6%, #fff 50%, transparent 52%), radial-gradient(1.6px 1.6px at 63% 22%, #fff 50%, transparent 52%),
        radial-gradient(1.4px 1.4px at 71% 40%, #fff 50%, transparent 52%), radial-gradient(2.2px 2.2px at 79% 16%, #fff 50%, transparent 52%),
        radial-gradient(1.6px 1.6px at 88% 30%, #fff 50%, transparent 52%), radial-gradient(2px 2px at 95% 10%, #fff 50%, transparent 52%),
        radial-gradient(1.4px 1.4px at 9% 58%, #fff 50%, transparent 52%), radial-gradient(1.6px 1.6px at 27% 66%, #fff 50%, transparent 52%),
        radial-gradient(1.4px 1.4px at 51% 60%, #fff 50%, transparent 52%), radial-gradient(2px 2px at 68% 70%, #fff 50%, transparent 52%),
        radial-gradient(1.4px 1.4px at 84% 56%, #fff 50%, transparent 52%), radial-gradient(1.6px 1.6px at 93% 74%, #fff 50%, transparent 52%),
        radial-gradient(1.6px 1.6px at 4% 84%, #fff 50%, transparent 52%), radial-gradient(1.4px 1.4px at 97% 88%, #fff 50%, transparent 52%); }
    .sc-stars--b { background-position: 58px 76px; opacity: 0.6; }
    .sc-moon { position: absolute; left: 1610px; top: 100px; width: 118px; height: 118px; border-radius: 50%;
      background: radial-gradient(circle at 36% 34%, #FFF7E4, #EDE1C4 58%, #D2C6A8); }
"""


def f03():
    fid, dur = "03-private", 7.2
    lead = "Start with facts, not with blame."
    items = ["Ask for 20 minutes at a calm moment.",
             "Say what changed: sleep, focus, sick days.",
             "Bring one clear request, like fewer projects for a month."]
    lis = "".join(f"<li>{words(i)}</li>" for i in items)
    css = NIGHT_CSS + """
    .p3-cam { position: absolute; inset: 0; transform-origin: 960px 150px; }
    .p3-vault { padding-top: 296px; background: rgba(18, 22, 40, 0.18); }
    .p3-badge { font-size: 19px; padding: 11px 22px; gap: 10px; }
    .p3-badge svg { width: 20px; height: 20px; }
    .p3-note { font-size: 16px; margin-top: 10px; }
"""
    body = f"""
    <div class="clip fill sky-night" data-start="0" data-duration="{dur}" data-track-index="0">
      <div class="sc-stars p3-st1"></div><div class="sc-stars sc-stars--b p3-st2"></div><div class="sc-moon p3-moon"></div>
    </div>
    <div class="clip fill tone-dark" data-start="0" data-duration="{dur}" data-track-index="1">
      {headband("01 — The private questions", "The questions you would not ask anyone else.")}
      <div class="p3-cam">
        <div class="winpos p3-win">
          <div class="app p3-app">
            {chrome()}
            <div class="a-chat">
              <div class="a-thread"><div class="a-col">
                <div class="a-user p3-u1"><p class="a-bubble p3-bub" data-scramble>How do I tell my boss that I am burned out?</p></div>
                <div class="a-tl p3-tl">{tl_head("Thinking", "Thought for 4s", "p3")}</div>
                <div class="a-ai p3-ans" data-scramble><p><strong>{words(lead)}</strong></p><ul>{lis}</ul></div>
                <div class="p3-acts">{acts()}</div>
              </div></div>
              {composer()}
            </div>
            <div class="vault p3-vault">
              <span class="vault-badge p3-badge">{icon("h-lock", "i18")}What our server stores</span>
              <span class="vault-note p3-note">AES-256-GCM · the key stays on your device</span>
            </div>
          </div>
        </div>
      </div>
    </div>"""
    js = """
  headline(0.0);
  headOut(1.0);
  winIn('.p3-win', 1.0);
  tl.fromTo('.p3-st1', { y: 0 }, { y: -26, duration: DUR, ease: 'none' }, 0);
  tl.fromTo('.p3-st2', { y: 0 }, { y: -14, duration: DUR, ease: 'none' }, 0);
  tl.fromTo('.p3-moon', { y: 0 }, { y: 18, duration: DUR, ease: 'none' }, 0);
  // the question arrives from the composer (continues the hook's send)
  tl.fromTo('.p3-u1', { opacity: 0, y: 150 }, { opacity: 1, y: 0, duration: 0.5, ease: 'power3.out' }, 1.2);
  rise('.p3-tl', 1.62, { y: 8, d: 0.3 });
  spin($('.p3-spin'));
  showBetween($('.p3-run'), -1, 2.25);
  showBetween($('.p3-done'), 2.25, 99);
  var endA = stream($('.p3-ans'), 2.3, 14.5);
  fadeIn('.p3-acts', endA + 0.05, 0.3);
  // 4.8 downbeat: the chat becomes what the server stores
  scramble($$('[data-scramble]'), 4.8, 1.15, 20260927);
  tl.fromTo('.p3-bub', { backgroundColor: '#B6674D', color: '#E8E4D8' }, { backgroundColor: '#33343C', color: '#9DA6C8', duration: 0.6, ease: 'power1.inOut' }, 4.8);
  tl.fromTo('.p3-ans', { color: '#E8E4D8' }, { color: '#8791B5', duration: 0.6, ease: 'power1.inOut' }, 4.8);
  tl.fromTo('.p3-vault', { opacity: 0 }, { opacity: 1, duration: 0.35, ease: 'power1.out' }, 4.8);
  tl.fromTo('.p3-badge', { y: -18, scale: 0.92 }, { y: 0, scale: 1, duration: 0.5, ease: 'back.out(2)' }, 4.8);
  rise('.p3-note', 5.05, { y: 8, d: 0.4 });
  // camera: close on the chat, a slow push while it answers, a nudge on the reveal
  tl.fromTo('.p3-cam', { scale: 1 }, { scale: 1.07, duration: 2.9, ease: 'power1.inOut' }, 1.5);
  tl.fromTo('.p3-cam', { scale: 1.07 }, { scale: 1.13, duration: 1.4, ease: 'power2.out', immediateRender: false }, 4.8);
"""
    return write(fid, page(fid, dur, css, body, js))


if __name__ == "__main__":
    for f in (f01, f02, f03):
        print(f())
