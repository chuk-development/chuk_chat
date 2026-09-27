"""Frames 05-09: images, files, documents, email + calendar, tools."""
from icons import icon
from kit import beat_page, bubble, esc, step, words, write


# ---------------------------------------------------------------- 05 images
def f05():
    fid, dur = "f05-images", 4
    card = f"""<div class="rc ig-c">
      {bubble("A sunlit bike workshop, film photo")}
      <div class="ig">
        <img class="ig-img" src="assets/img/generated-workshop.jpg" alt="" />
        <div class="ig-noise"></div>
        <span class="ig-gen"><i class="spin ig-spin"></i>Generating image</span>
      </div>
      <div class="ig-row"><span class="ig-tile">{icon("h-image01", "i20")}</span>
        <span class="ig-txt"><b>workshop.png</b><small>1920 × 1080 · generated</small></span>
        <span class="ig-btn">{icon("h-pencil-edit02", "z18")}Edit</span><span class="ig-btn">{icon("h-download01", "z18")}Save</span></div>
    </div>"""
    css = """
    .ig { position: relative; width: 540px; height: 304px; margin-top: 14px; overflow: hidden; border-radius: 12px; background: #1B1A18; }
    .ig-img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
    .ig-noise { position: absolute; inset: -40px; background: url("assets/img/noise.png") 0 0 / 256px 256px repeat; mix-blend-mode: normal; }
    .ig-gen { position: absolute; left: 12px; bottom: 12px; display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 10px;
      background: rgba(20, 19, 17, 0.82); color: var(--fg); font-size: 15px; font-weight: 500; }
    .ig-row { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
    .ig-tile { flex: none; width: 38px; height: 38px; border-radius: 8px; background: #4B4B47; display: flex; align-items: center; justify-content: center; }
    .ig-txt { flex: 1; display: flex; flex-direction: column; line-height: 1.25; }
    .ig-txt b { font-size: 16px; font-weight: 600; }
    .ig-txt small { font-size: 15px; color: var(--fg70); }
    .ig-btn { display: inline-flex; align-items: center; gap: 6px; padding: 7px 12px; border-radius: 999px; color: var(--acc); font-size: 15px; font-weight: 600; }
"""
    js = """
  fadeIn('.ig', 0.15, 0.2);
  // The image resolves out of noise: grain fades, blur clears, colour comes up.
  tl.fromTo('.ig-img', { filter: 'blur(26px) saturate(0.25) brightness(0.7)', scale: 1.1 },
    { filter: 'blur(0px) saturate(1) brightness(1)', scale: 1, duration: 2.3, ease: 'power2.inOut' }, 0.3);
  tl.fromTo('.ig-noise', { opacity: 0.95 }, { opacity: 0, duration: 2.0, ease: 'power1.in' }, 0.3);
  var nz = $('.ig-noise');
  ups.push(function (t) { var k = Math.floor(t * 24); nz.style.backgroundPosition = ((k * 97) % 256) + 'px ' + ((k * 61) % 256) + 'px'; });
  spin($('.ig-spin'));
  fadeOut('.ig-gen', 2.35, 0.2);
  rise('.ig-row', 2.6, { y: 10 });
"""
    return write(fid, beat_page(fid, dur, 5, "paper", ["Create", "images"], "Generate and edit images.", card, css, js))


# ---------------------------------------------------------------- 06 files
def f06():
    fid, dur = "f06-files", 4
    pts = [("2", "Rent €1,150 a month, warm."), ("4", "Notice period: 3 months."), ("6", "Pets need written consent.")]
    lis = "".join(f'<p class="fl-li fl-l{i}"><i class="fl-pg fl-p{i}">p. {p}</i>{words(t)}</p>' for i, (p, t) in enumerate(pts))
    lines = "".join(f'<i class="fl-ln" style="width:{w}%"></i>' for w in (96, 88, 92, 70, 94, 84, 90, 62, 92, 80))
    card = f"""<div class="rc fl-c">
      {bubble("What are the key points?", doc="lease.pdf")}
      {step("read", "Read", "lease.pdf · 12 pages", "fl-step")}
      <div class="fl-row">
        <div class="fl-stack">
          <span class="fl-sh fl-sh2"></span><span class="fl-sh fl-sh1"></span>
          <div class="fl-page"><p class="fl-pt">Lease</p>{lines}
            <span class="fl-hl fl-h0"></span><span class="fl-hl fl-h1"></span><span class="fl-hl fl-h2"></span>
            <span class="fl-no"><span class="fl-n0">p. 2</span><span class="fl-n1">p. 4</span><span class="fl-n2">p. 6</span></span>
          </div>
        </div>
        <div class="a-ai fl-ans"><p class="fl-intro">{words("The key points:")}</p>{lis}</div>
      </div>
    </div>"""
    css = """
    .fl-row { display: flex; align-items: flex-start; gap: 18px; margin-top: 14px; }
    .fl-stack { position: relative; flex: none; width: 152px; height: 206px; margin: 4px 0 0 4px; }
    .fl-sh { position: absolute; width: 146px; height: 198px; border-radius: 6px; background: #CFCAC0; }
    .fl-sh2 { left: 8px; top: 8px; opacity: 0.45; }
    .fl-sh1 { left: 4px; top: 4px; opacity: 0.75; }
    .fl-page { position: absolute; left: 0; top: 0; width: 146px; height: 198px; padding: 12px 12px; border-radius: 6px; background: #FBFAF7; overflow: hidden; }
    .fl-pt { margin: 0 0 8px !important; font-size: 15px; font-weight: 700; color: #29251F; }
    .fl-ln { display: block; height: 6px; margin: 0 0 8px; border-radius: 3px; background: #DCD6CB; }
    .fl-hl { position: absolute; left: 8px; right: 8px; height: 14px; border-radius: 4px; background: rgba(245, 200, 80, 0.55); }
    .fl-h0 { top: 51px; } .fl-h1 { top: 93px; } .fl-h2 { top: 135px; }
    .fl-no { position: absolute; right: 8px; bottom: 8px; height: 24px; }
    .fl-no > span { position: absolute; right: 0; bottom: 0; padding: 1px 7px; border-radius: 6px; background: #29251F; color: #FBFAF7; font-size: 15px; font-weight: 700; white-space: nowrap; }
    .fl-ans { flex: 1; min-width: 0; margin-top: 0; font-size: 17px; }
    .fl-intro { margin: 0 0 8px !important; color: var(--fg85); }
    .fl-li { margin: 0 0 10px !important; line-height: 1.4; }
    .fl-pg { display: inline-flex; align-items: center; height: 24px; margin-right: 8px; padding: 0 7px; border-radius: 7px; background: rgba(217, 119, 87, 0.2); color: #F0A585;
      font-family: var(--ui-font); font-size: 15px; font-weight: 700; font-style: normal; vertical-align: 1px; white-space: nowrap; }
"""
    js = """
  rise('.fl-step', 0.4);
  tl.fromTo('.fl-stack', { opacity: 0, y: 16, rotation: -3 }, { opacity: 1, y: 0, rotation: 0, duration: 0.45, ease: 'power3.out' }, 0.55);
  stream($('.fl-intro'), 1.0, 12);
  [1.35, 1.95, 2.55].forEach(function (t, i) {
    pop('.fl-p' + i, t, { s: 0.4 });
    stream($('.fl-l' + i), t + 0.08, 14);
    tl.fromTo('.fl-h' + i, { opacity: 0, scaleX: 0, transformOrigin: '0% 50%' }, { opacity: 1, scaleX: 1, duration: 0.3, ease: 'power2.out' }, t);
    if (i > 0) fadeOut('.fl-h' + (i - 1), t, 0.2);
    showBetween($('.fl-n' + i), t, i < 2 ? [1.95, 2.55][i] : 99);
  });
"""
    return write(fid, beat_page(fid, dur, 6, "night", ["Read your", "files"], "Ask your PDFs and photos.", card, css, js))


# ---------------------------------------------------------------- 07 documents
def f07():
    fid, dur = "f07-documents", 4
    code = [
        ('<span class="k">&lt;header</span> <span class="a">class</span>=<span class="s">"nav"</span><span class="k">&gt;</span>'),
        ('  <span class="k">&lt;b&gt;</span>Café Anker<span class="k">&lt;/b&gt;</span>'),
        ('<span class="k">&lt;/header&gt;</span>'),
        ('<span class="k">&lt;h1&gt;</span>Coffee by the harbour.<span class="k">&lt;/h1&gt;</span>'),
        ('<span class="k">&lt;ul</span> <span class="a">class</span>=<span class="s">"menu"</span><span class="k">&gt;</span>'),
        ('  <span class="k">&lt;li&gt;</span>Flat white <span class="k">&lt;i&gt;</span>3.40<span class="k">&lt;/i&gt;</span>'),
        ('  <span class="k">&lt;li&gt;</span>Cardamom bun <span class="k">&lt;i&gt;</span>3.20<span class="k">&lt;/i&gt;</span>'),
        ('  <span class="k">&lt;li&gt;</span>Fish roll <span class="k">&lt;i&gt;</span>5.90<span class="k">&lt;/i&gt;</span>'),
    ]
    codeh = "".join(f'<p class="dc-cl dc-cl{i}"><span class="dc-no">{i + 1}</span>{c}</p>' for i, c in enumerate(code))
    menu = [("Flat white", "3.40"), ("Cardamom bun", "3.20"), ("Fish roll", "5.90")]
    mh = "".join(f'<p class="dc-m dc-m{i}"><span>{a}</span><i></i><b>{b}</b></p>' for i, (a, b) in enumerate(menu))
    card = f"""<div class="rc dc-c">
      {bubble("Make a menu page for our café")}
      <div class="dc-ap">
        <div class="dc-ph">{icon("h-file-text", "i18")}<b>Café Anker menu</b><span class="dc-type">HTML</span>
          <span class="dc-seg"><span class="dc-sp">{icon("h-eye", "z16")}Preview</span><span class="dc-sc">{icon("h-source-code", "z16")}Code</span></span></div>
        <div class="dc-body">
          <div class="dc-lp">
            <p class="dc-nav"><b>Café Anker</b><span>Menu</span><span>Visit</span></p>
            <p class="dc-t">Coffee by the harbour.</p>
            <p class="dc-sub">Open daily, 8 to 6.</p>
            {mh}
            <p class="dc-btn">Order ahead</p>
          </div>
          <div class="dc-code">{codeh}</div>
        </div>
        <div class="dc-link">{icon("h-globe02", "z18")}<span>artifacts.chuk.chat/m4q9-cafe-anker</span><span class="dc-pub">Public</span></div>
      </div>
    </div>"""
    css = """
    .dc-ap { margin-top: 14px; overflow: hidden; border: 1px solid var(--fg15); border-radius: 12px; }
    .dc-ph { position: relative; display: flex; align-items: center; gap: 8px; height: 46px; padding: 0 10px 0 12px; border-bottom: 1px solid rgba(232, 228, 216, 0.12); font-size: 16px; white-space: nowrap; }
    .dc-ph b { font-weight: 600; }
    .dc-type { padding: 2px 7px; border-radius: 6px; background: rgba(217, 119, 87, 0.15); color: var(--acc); font-size: 15px; font-weight: 500; }
    .dc-seg { position: relative; display: inline-flex; margin-left: auto; border: 1.5px solid var(--fg30); border-radius: 16px; font-size: 15px; font-weight: 500; overflow: hidden; }
    .dc-seg > span { position: relative; z-index: 1; display: inline-flex; align-items: center; gap: 5px; height: 30px; padding: 0 10px; }
    .dc-seg > span + span { border-left: 1.5px solid var(--fg30); }
    .dc-body { position: relative; height: 262px; padding: 10px; }
    .dc-lp { position: absolute; inset: 10px; padding: 14px 18px; border-radius: 6px; background: #FFF8EE; color: #29251F; }
    .dc-nav { display: flex; align-items: center; gap: 14px; color: #6B6357; font-size: 15px; }
    .dc-nav b { margin-right: auto; font-size: 18px; font-weight: 800; letter-spacing: -0.02em; color: #1F5A73; }
    .dc-t { margin: 10px 0 2px !important; font-size: 30px; font-weight: 750; line-height: 1.05; letter-spacing: -0.035em; }
    .dc-sub { margin: 0 0 8px !important; font-size: 15px; color: #6B6357; }
    .dc-m { display: flex; align-items: baseline; gap: 6px; margin: 0 !important; font-size: 16px; line-height: 1.55; }
    .dc-m i { flex: 1; border-bottom: 2px dotted #CDBFAA; transform: translateY(-4px); }
    .dc-m b { font-weight: 700; }
    .dc-btn { display: inline-block; margin-top: 8px !important; padding: 5px 14px; border-radius: 999px; background: #1F5A73; color: #fff; font-size: 15px; font-weight: 600; }
    .dc-code { position: absolute; inset: 10px; padding: 10px 12px; border-radius: 6px; background: #1C1C1A; font-family: var(--chat-font); font-size: 15px; line-height: 1.52; color: #E8E4D8; white-space: pre; overflow: hidden; }
    .dc-cl { margin: 0 !important; }
    .dc-no { display: inline-block; width: 22px; color: rgba(232, 228, 216, 0.4); }
    .dc-code .k { color: #E8A07F; } .dc-code .a { color: #9CC4E4; } .dc-code .s { color: #B5CE8C; }
    .dc-link { display: flex; align-items: center; gap: 8px; height: 44px; padding: 0 12px; border-top: 1px solid rgba(232, 228, 216, 0.12); font-size: 15px; color: var(--fg85); white-space: nowrap; }
    .dc-link svg { color: #86C795; }
    .dc-pub { margin-left: auto; padding: 2px 9px; border-radius: 6px; background: rgba(134, 199, 149, 0.16); color: #86C795; font-weight: 700; }
"""
    js = """
  rise('.dc-ap', 0.25, { y: 12, d: 0.4 });
  ['.dc-nav', '.dc-t', '.dc-sub', '.dc-m0', '.dc-m1', '.dc-m2', '.dc-btn'].forEach(function (s, i) {
    rise(s, 0.5 + i * 0.2, { y: 8, d: 0.3 });
  });
  rise('.dc-link', 2.0, { y: 8 });
  pop('.dc-pub', 2.2, { s: 0.5 });
  // Code tab flip on the downbeat of bar 2's last beat.
  tl.fromTo('.dc-sp', { backgroundColor: 'rgba(87, 67, 58, 1)' }, { backgroundColor: 'rgba(87, 67, 58, 0)', duration: 0.25, ease: 'power1.inOut' }, 2.75);
  tl.fromTo('.dc-sc', { backgroundColor: 'rgba(87, 67, 58, 0)' }, { backgroundColor: 'rgba(87, 67, 58, 1)', duration: 0.25, ease: 'power1.inOut' }, 2.75);
  tl.fromTo('.dc-code', { opacity: 0 }, { opacity: 1, duration: 0.2, ease: 'power1.out' }, 2.8);
  fadeOut('.dc-lp', 2.8, 0.2);
  $$('.dc-cl').forEach(function (l, i) { fadeIn(l, 2.85 + i * 0.05, 0.15); });
"""
    return write(fid, beat_page(fid, dur, 7, "day", ["Documents", "and pages"], "Makes PDFs, pages and code.", card, css, js))


# ---------------------------------------------------------------- 08 email + calendar
def f08():
    fid, dur = "f08-email", 4
    body = "Hi Tom, can we do the planning call on Friday at 10:00? It takes 30 minutes. Best, Lea"
    card = f"""<div class="rc em-c">
      {bubble("Invite Tom to Friday's planning call")}
      <div class="em">
        <p class="em-h">{icon("h-email", "i20")}Planning call on Friday</p>
        <div class="em-b">
          <p class="em-row em-to"><span>To</span>tom@example.com</p>
          <p class="em-t">{words(body)}</p>
          <p class="em-btn">{icon("h-link-square02", "z18")}Open in Mail App</p>
        </div>
      </div>
      {step("ran", "Ran", "create calendar event", "em-step")}
      <div class="ev"><span class="ev-d"><small>OCT</small><b>2</b></span>
        <span class="ev-t"><b>Planning call</b><small>Fri 10:00 – 10:30 · with Tom</small></span>
        <span class="ev-ok">{icon("h-tick02", "z16")}Added</span></div>
    </div>"""
    css = """
    .em { margin-top: 14px; overflow: hidden; border: 1px solid rgba(217, 119, 87, 0.3); border-radius: 12px; background: #2D2D2B; }
    .em-h { display: flex; align-items: center; gap: 9px; padding: 10px 14px; background: rgba(217, 119, 87, 0.1); font-size: 17px; font-weight: 600; }
    .em-h svg { color: var(--acc); }
    .em-b { padding: 10px 14px 14px; }
    .em-row { display: flex; font-size: 16px; }
    .em-row span { width: 36px; font-size: 15px; font-weight: 500; color: rgba(232, 228, 216, 0.6); }
    .em-t { margin: 8px 0 12px !important; font-size: 16px; line-height: 1.45; color: rgba(232, 228, 216, 0.8); }
    .em-btn { display: flex; align-items: center; justify-content: center; gap: 7px; padding: 10px; border-radius: 100px; background: var(--acc); color: #fff; font-size: 16px; font-weight: 500; }
    .ev { display: flex; align-items: center; gap: 12px; margin-top: 10px; padding: 10px 12px; border: 1px solid var(--fg15); border-radius: 12px; background: var(--lift); }
    .ev-d { flex: none; width: 52px; height: 56px; border-radius: 10px; background: rgba(217, 119, 87, 0.18); display: flex; flex-direction: column; align-items: center; justify-content: center; line-height: 1; }
    .ev-d small { font-size: 15px; font-weight: 700; color: #F0A585; letter-spacing: 0.04em; }
    .ev-d b { margin-top: 3px; font-size: 24px; font-weight: 700; }
    .ev-t { flex: 1; display: flex; flex-direction: column; gap: 3px; white-space: nowrap; }
    .ev-t b { font-size: 17px; font-weight: 700; }
    .ev-t small { font-size: 15px; color: var(--fg82); }
    .ev-ok { display: inline-flex; align-items: center; gap: 5px; padding: 4px 10px; border-radius: 8px; background: rgba(134, 199, 149, 0.16); color: #86C795; font-size: 15px; font-weight: 700; }
"""
    js = """
  rise('.em', 0.25, { y: 12, d: 0.4 });
  rise('.em-to', 0.5, { y: 6 });
  stream($('.em-t'), 0.65, 22);
  pop('.em-btn', 1.55, { s: 0.85, ease: 'back.out(1.6)' });
  rise('.em-step', 2.0);
  tl.fromTo('.ev', { opacity: 0, y: -26, scale: 0.94 }, { opacity: 1, y: 0, scale: 1, duration: 0.45, ease: 'back.out(1.7)' }, 2.5);
  pop('.ev-ok', 2.85, { s: 0.4 });
"""
    return write(fid, beat_page(fid, dur, 8, "prism", ["Email and", "calendar"], "Drafts emails. Books the date.", card, css, js))


# ---------------------------------------------------------------- 09 tools
def f09():
    fid, dur = "f09-tools", 4
    logos = ["notion", "linear", "github", "todoist", "dropbox", "figma", "stripe", "asana", "airtable", "calcom", "vercel"]
    tiles = "".join(f'<span class="tl-t tl-t{i}"><img src="assets/logos/connectors/{c}.png" alt="" /></span>' for i, c in enumerate(logos))
    tiles += '<span class="tl-t tl-t11 tl-more">+50</span>'
    items = [("Tue", "Send the offer to Nordlicht"), ("Thu", "Newsletter draft"), ("Fri", "Q4 budget review")]
    lis = "".join(f'<p class="tl-li tl-l{i}"><span class="w tl-day">{d} </span>{words(t)}</p>' for i, (d, t) in enumerate(items))
    card = f"""<div class="rc tl-c">
      {bubble("What's due this week? Check Notion.")}
      <p class="tl-lab">Connected tools</p>
      <div class="tl-grid">{tiles}</div>
      {step("ran", "Ran", "notion search", "tl-step", "")}
      <div class="a-ai tl-ans">{lis}</div>
    </div>"""
    css = """
    .tl-lab { margin: 12px 0 8px !important; font-size: 15px; font-weight: 500; color: var(--fg55); }
    .tl-grid { display: grid; grid-template-columns: repeat(6, 80px); justify-content: space-between; row-gap: 12px; }
    .tl-t { width: 80px; height: 80px; border-radius: 20px; background: #FFFFFF; display: flex; align-items: center; justify-content: center; }
    .tl-t img { width: 46px; height: 46px; object-fit: contain; }
    .tl-more { background: rgba(217, 119, 87, 0.2); color: #F0A585; font-size: 22px; font-weight: 700; }
    .tl-ans { margin-top: 8px; font-size: 17px; }
    .tl-li { margin: 0 0 4px !important; white-space: nowrap; }
    .tl-day { display: inline-block; width: 52px; color: #F0A585; font-weight: 700; }
"""
    js = """
  // Drop 2: the connector tiles slot in on 16th notes.
  for (var i = 0; i < 12; i++) {
    tl.fromTo('.tl-t' + i, { opacity: 0, y: -34, scale: 0.6 }, { opacity: 1, y: 0, scale: 1, duration: 0.3, ease: 'back.out(2)' }, 0.12 + i * 0.125);
  }
  rise('.tl-step', 1.75);
  stream($('.tl-l0'), 2.05, 16); stream($('.tl-l1'), 2.45, 16); stream($('.tl-l2'), 2.85, 16);
  tl.fromTo('.tl-step .a-badge', { color: 'rgba(232,228,216,0.6)' }, { color: '#86C795', duration: 0.2 }, 2.0);
"""
    return write(fid, beat_page(fid, dur, 9, "network", ["Your", "tools"], "Works with Notion, Linear, GitHub and 50+ more.", card, css, js))
