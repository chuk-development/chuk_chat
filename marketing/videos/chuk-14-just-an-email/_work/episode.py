#!/usr/bin/env python3
"""Episode 14 "just-an-email": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 14): a generic sign-up wall asks for a phone number, a date of
birth and the contacts. Cut: "We ask for two things." The real Chuk Chat sign-up page, an email
and a password typed, the one-time code from the email. Brown block: no phone number, no Google
or Apple login, no ads, no tracking SDK in the app. Then the real account deletion: Danger
zone, the three dialogs, the password again. "Leave whenever you want."
Claims (PRIVACY_CLAIMS.md, may say): Account: an email and a password, no phone number, no
Google or Apple login, delete your account any time. Tracking: no ads, no tracking SDK in the app.
Facts: lib/services/auth_service.dart:33-45, lib/pages/login_page.dart, otp_verification_page.dart,
account_settings_page.dart _deleteAccount, api_server routers/billing/user.py:238-269.

Builds both formats from one spec:
  ../chuk-14-just-an-email/            16:9 1920x1080
  ../chuk-14-just-an-email-vertical/   9:16 1080x1920 (re-laid out, not cropped)
Run (once, and after pieces.py changes): python3 _work/make_assets.py   then: python3 _work/episode.py
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent
VIDEOS = PROJ.parent
sys.path.insert(0, str(VIDEOS / "_lib"))
sys.path.insert(0, str(HERE))

from chukvid import LANDSCAPE, VERTICAL, Episode, beats, scenes, ui  # noqa: E402
from chukvid.core import cursor, esc  # noqa: E402
import pieces as P  # noqa: E402

MUSIC = VIDEOS.parent / "_shared/music/s2-sky-falling-45s.wav"
DUR = 45.0
LAYOUT = json.loads((HERE / "layout.json").read_text())
EMAIL = "sam@example.com"          # fictional (example.com is reserved for examples)
PW = "Tide-Lantern-48!"            # 16 chars: every rule met, "Strong password"
CODE = "482915"
CPS = 18                           # typing speed, series rule

# ------------------------------------------------------------------ cuts on the beat grid
# 122.6 BPM, beat 0.49 s. Hits: 5.66, 8.59, 19.86 (after the dip), 27.48 (the track opens up),
# fade-out from 42.5. Rough targets, snapped to the beat grid.
TARGETS = [5.66, 8.59, 16.91, 19.86, 25.25, 27.48, 35.84, 38.73]


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + P.CSS + EP_CSS)
    ep.write()                                   # scaffold first: `beats` needs the music in place
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.3)
    v = fmt.vertical
    lay = LAYOUT[fmt.name]

    s01_wall(ep, cut[0], cut[1], v)
    scenes.card(ep, "s02", cut[1], cut[2], ["We ask for", "two things."] if v else ["We ask for two things."])
    s03_signup(ep, cut[2], cut[3], v, lay)
    s04_code(ep, cut[3], cut[4], v, lay)
    s05_block(ep, cut[4], cut[5], v)
    scenes.card(ep, "s06", cut[5], cut[6], ["And when you", "want to leave?"] if v else ["And when you want to leave?"])
    s07_delete(ep, cut[6], cut[7], v, lay)
    scenes.card(ep, "s08", cut[7], cut[8], ["Leave whenever", "you want."] if v else ["Leave whenever you want."], bg="@TAN@")
    scenes.end_card(ep, "s09", cut[8], DUR)
    ep.write()
    ep.report()
    return ep


EP_CSS = """
/* s01: a generic sign-up form of "other apps" (no brand, neutral greys) */
.gw { position: absolute; background: #FFFFFF; border-radius: 28px; padding: 48px; font-family: 'Ubuntu', sans-serif; color: #1C1F24;
  box-shadow: 0 30px 70px -30px rgba(0,0,0,0.35); overflow: hidden; }
.gw-h { font-size: 46px; line-height: 56px; font-weight: 600; }
.gw-step { margin-top: 6px; font-size: 30px; line-height: 38px; color: #6B7280; }
.gw-blk { margin-top: 24px; }
.gw-l { font-size: 30px; line-height: 40px; font-weight: 500; color: #4B5563; }
.gw-box { margin-top: 8px; height: 80px; border-radius: 14px; background: #F3F4F6; border: 2px solid #E5E7EB; display: flex; align-items: center; gap: 16px; padding: 0 24px;
  font-size: 32px; color: #7C8591; white-space: nowrap; }
.gw-chip { height: 52px; padding: 0 16px; border-radius: 10px; background: #E5E7EB; color: #374151; display: flex; align-items: center; font-weight: 500; }
.gw-btn { margin-top: 32px; height: 84px; border-radius: 42px; background: #1F2937; color: #FFFFFF; display: flex; align-items: center; justify-content: center; font-size: 32px; font-weight: 600; }
.gw-dim { position: absolute; inset: 0; background: rgba(17,24,39,0.35); opacity: 0; }
.gw-sheet { position: absolute; background: #FFFFFF; border-radius: 28px; padding: 40px; font-family: 'Ubuntu', sans-serif; color: #1C1F24;
  box-shadow: 0 30px 80px -20px rgba(0,0,0,0.5); opacity: 0; }
.gw-ico { width: 80px; height: 80px; border-radius: 40px; background: #E5E7EB; color: #374151; display: flex; align-items: center; justify-content: center; }
.gw-st { margin-top: 24px; font-size: 36px; line-height: 46px; font-weight: 600; }
.gw-sb { margin-top: 10px; font-size: 30px; line-height: 40px; color: #6B7280; }
.gw-acts { margin-top: 32px; display: flex; gap: 16px; justify-content: flex-end; }
.gw-acts span { height: 76px; padding: 0 32px; border-radius: 38px; display: flex; align-items: center; font-size: 32px; font-weight: 600; }
.gw-no { color: #374151; background: #F3F4F6; }
.gw-yes { color: #FFFFFF; background: #1F2937; }
.wall-line { position: absolute; white-space: nowrap; }
"""

CONTACTS = ('<svg viewBox="0 0 24 24" width="44" height="44" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" '
            'stroke-linejoin="round"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 2.9-6.5 6.5-6.5s6.5 2.9 6.5 6.5"/>'
            '<circle cx="17" cy="9" r="2.6"/><path d="M16.5 13.6c2.9.2 5 2.5 5 5.4"/></svg>')


# =================================================================== camera over an app window
class Cam:
    """The app window sits in a ui.appz() at base zoom z0, its centre on the frame's (cx, cy).
    shot(z, ax, ay): the camera frames window point (ax, ay) (app px) at zoom z; scr() gives
    the screen position of a window point under such a shot (for the cursor)."""

    def __init__(self, ep, cid, z0, win_w, win_h):
        self.ep, self.cid, self.fmt = ep, cid, ep.fmt
        self.z0, self.ww, self.wh = z0, win_w, win_h
        aw, ah = self.fmt.W / z0, self.fmt.H / z0
        self.wx = self.fmt.cx / z0 - win_w / 2          # window left/top in appz px
        self.wy = self.fmt.cy / z0 - win_h / 2
        self.aw, self.ah = aw, ah

    def tf(self, z, ax, ay):
        k = z / self.z0
        px, py = (self.wx + ax) * self.z0, (self.wy + ay) * self.z0
        return dict(scale=round(k, 4), x=round(self.fmt.cx - k * px, 2), y=round(self.fmt.cy - k * py, 2))

    def scr(self, shot, ax, ay):
        z, cx, cy = shot
        return (round(self.fmt.cx + z * (ax - cx), 1), round(self.fmt.cy + z * (ay - cy), 1))

    def set(self, shot, t=0):
        d = self.tf(*shot)
        return f"tl.set('#{self.cid}', {{ scale: {d['scale']}, x: {d['x']}, y: {d['y']}, transformOrigin: '0 0' }}, {t:.2f});"

    def to(self, shot, t, dur, ease="power2.inOut"):
        d = self.tf(*shot)
        return f"tl.to('#{self.cid}', {{ scale: {d['scale']}, x: {d['x']}, y: {d['y']}, duration: {dur:.2f}, ease: '{ease}' }}, {t:.2f});"


def band(v, inner):
    """9:16: the app view is clipped to the safe band (y 220..1540), so no UI text sits under
    the platform's own top and bottom chrome. 16:9: unchanged."""
    if not v:
        return inner
    return f'<div class="fill" style="clip-path: inset(220px 24px 380px 24px round 32px)">{inner}</div>'


def ctr(r):
    return (r[0] + r[2] / 2, r[1] + r[3] / 2)


def focus_js(f, t, on=True):
    """Focus ring + border gap + the label floating up (Flutter animates it in ~0.17 s)."""
    o = 1 if on else 0
    js = [f"tl.to('#{f}-ring', {{ opacity: {o}, duration: 0.12 }}, {t:.2f});",
          f"tl.to('#{f}-gap', {{ opacity: {o}, duration: 0.12 }}, {t:.2f});",
          f"tl.set('#{f}-cur', {{ opacity: {o} }}, {t:.2f});"]
    if on:
        js += [f"tl.to('#{f}-lab', {{ opacity: 0, duration: 0.15 }}, {t:.2f});",
               f"tl.to('#{f}-flab', {{ opacity: 1, duration: 0.15 }}, {t:.2f});"]
    return "\n  ".join(js)


def spin_js(sel, t, until):
    return (f"tl.set('{sel}', {{ display: 'block' }}, {t:.2f});\n"
            f"  tl.fromTo('{sel}', {{ rotation: 0 }}, {{ rotation: {round((until - t) * 400)}, duration: {until - t:.2f}, ease: 'none' }}, {t:.2f});")


# =================================================================== s01 the sign-up wall of other apps (hook)
def s01_wall(ep, a, b, v):
    fmt = ep.fmt
    if v:
        card = dict(left=70, top=226, width=860)
        sheet = dict(left=330, top=880, width=680)
        lines, size, lx, ly, align = ["Some apps want", "all of this."], 104, 0, 1296, "center"
    else:
        card = dict(left=110, top=110, width=700)
        sheet = dict(left=540, top=590, width=640)
        lines, size, lx, ly, align = ["Some apps want", "all of this."], 84, 1180, 330, "left"
    lh = round(size * 1.12)
    blocks = [("Full name", '<span>First and last name</span>'),
              ("Phone number", '<span class="gw-chip">+1</span><span>(555) 000-0000</span>'),
              ("Date of birth", '<span>MM / DD / YYYY</span>')]
    bh = "".join(f'<div class="gw-blk" id="s01-b{i}" style="display:none"><div class="gw-l">{esc(l)}</div><div class="gw-box">{box}</div></div>'
                 for i, (l, box) in enumerate(blocks))
    ldivs = "".join(
        f'<div class="serif wall-line" id="s01-l{i}" style="left:{lx}px;{"right:0;" if v else ""}top:{ly + i * lh}px;'
        f'font-size:{size}px;line-height:{lh}px;text-align:{align}">{esc(t)}</div>' for i, t in enumerate(lines))
    css = f"""
#s01-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#s01-card {{ left: {card['left']}px; top: {card['top']}px; width: {card['width']}px; }}
#s01-sheet {{ left: {sheet['left']}px; top: {sheet['top']}px; width: {sheet['width']}px; }}
"""
    body = f"""
    <div id="s01-all" class="fill">
      <div class="gw" id="s01-card" data-layout-allow-overlap>
        <div class="gw-h">Create your account</div>
        <div class="gw-step">Step 1 of 3</div>
        {bh}
        <div class="gw-btn" id="s01-btn" style="display:none">Continue</div>
        <div class="gw-dim" id="s01-dim"></div>
      </div>
      <div class="gw-sheet" id="s01-sheet" data-layout-allow-overlap>
        <div class="gw-ico">{CONTACTS}</div>
        <div class="gw-st">Allow access to your contacts?</div>
        <div class="gw-sb">To find people you know.</div>
        <div class="gw-acts"><span class="gw-no">Don't allow</span><span class="gw-yes">Allow</span></div>
      </div>
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s01-card', {{ y: 24 }}, {{ y: 0, duration: 0.6, ease: 'expo.out' }}, 0);
  tl.set('#s01-b0', {{ display: 'block' }}, 0.36);
  tl.fromTo('#s01-b0', {{ opacity: 0, y: 18 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 0.36);
  tl.set('#s01-b1', {{ display: 'block' }}, 1.24);
  tl.fromTo('#s01-b1', {{ opacity: 0, y: 18 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 1.24);
  tl.set('#s01-b2', {{ display: 'block' }}, 2.23);
  tl.fromTo('#s01-b2', {{ opacity: 0, y: 18 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: 'power3.out' }}, 2.23);
  tl.set('#s01-btn', {{ display: 'flex' }}, 2.73);
  tl.fromTo('#s01-btn', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 2.73);
  tl.fromTo('#s01-sheet', {{ opacity: 0, y: 60, scale: 0.96 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.45, ease: 'expo.out' }}, 3.19);
  hfReveal(tl, '#s01-l0', 0.8);
  hfReveal(tl, '#s01-l1', 3.69);
  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s01", a, b, css, body, js)


# =================================================================== s03 the real sign-up page
def login_window(ep, cid, z0, win, inner_card):
    return ui.appz(f"{cid}-z", ep.fmt, z0, f'<div class="a-win lg-page" id="{cid}-win" style="left:{(ep.fmt.W / z0 - win[0]) / 2:.2f}px;'
                   f'top:{(ep.fmt.cy / z0 - win[1] / 2):.2f}px;width:{win[0]}px;height:{win[1]}px">{inner_card}</div>')


def s03_signup(ep, a, b, v, lay):
    fmt = ep.fmt
    win = lay["windows"]["login"]
    E, L, S = lay["signup_empty"], lay["signup_list"], lay["signup_strong"]
    z0 = 1.85 if v else 1.4
    cam = Cam(ep, "s03-cam", z0, *win)
    cs = 1.3 if v else 1.0
    wcx, wcy = win[0] / 2, win[1] / 2
    K0 = (z0, wcx, wcy)
    K1 = (2.4 if v else 2.0, wcx, ctr(E["#s-mail"])[1] - 40)
    pw_top, list_bot = L["#s-pw"][1], L["#s-m"][1] + L["#s-m"][3]
    K2 = (2.9 if v else 2.6, wcx, (pw_top + list_bot) / 2)
    K3 = (2.4 if v else 2.0, wcx, ctr(S["#s-pw2"])[1] - 30)
    lower = (S["#s-pw2"][1] + S["#s"][1] + S["#s"][3]) / 2          # Confirm password .. card bottom
    K4 = (2.4 if v else 1.9, wcx, lower)
    # cursor targets
    mail = cam.scr(K0, *ctr(E["#s-mail"]))
    cb1 = cam.scr(K4, *ctr(S["#s-cb1 .lg-box"]))
    cb2 = cam.scr(K4, *ctr(S["#s-cb2 .lg-box"]))
    go = cam.scr(K4, *ctr(S["#s-go"]))
    card = P.signup_card("s03").replace('id="s03"', 'id="s03-card"')
    css = f"""
#s03-out {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
"""
    body = f"""
    <div id="s03-out" class="fill">
      {band(v, f'<div id="s03-cam" class="fill" data-layout-allow-overflow>{login_window(ep, "s03", z0, win, card)}</div>')}
      {cursor('s03-cur', cs)}
    </div>
"""
    t_mail = 1.15
    t_pw = 2.35
    t_pw2 = t_pw + len(PW) / CPS + 0.3
    t_cb = t_pw2 + len(PW) / CPS + 0.45
    dots = "•" * len(PW)
    js = f"""
  {cam.set(K0)}
  tl.fromTo('#s03-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'expo.out' }}, 0);
  tl.set('#s03-cur', {{ opacity: 1 }}, 0);
  // click into Email
  tl.fromTo('#s03-cur', {{ x: {mail[0] + 300:.0f}, y: {fmt.H + 60} }}, {{ x: {mail[0] + 40:.0f}, y: {mail[1]:.0f}, duration: 0.6, ease: 'power2.inOut' }}, 0.2);
  hfShape(tl, '#s03-cur', 0.7, 'ibeam');
  hfClick(tl, '#s03-cur', 0.85, 'ibeam');
  {focus_js('s03-mail', 0.92)}
  tl.to('#s03-cur', {{ opacity: 0, duration: 0.2 }}, 1.0);
  {cam.to(K1, 0.95, 0.6)}
  var e1 = hfType(tl, document.getElementById('s03-mail-val'), {EMAIL!r}, {t_mail}, {CPS});
  // next field (textInputAction.next): Password, with the strength meter
  {focus_js('s03-mail', t_pw - 0.2, on=False)}
  {focus_js('s03-pw', t_pw - 0.2)}
  {cam.to(K2, t_pw - 0.3, 0.55)}
  hfType(tl, document.getElementById('s03-pw-val'), {dots!r}, {t_pw}, {CPS});
  {P.meter_js('s03-m', PW, t_pw, CPS)}
  // Confirm password
  {focus_js('s03-pw', t_pw2 - 0.15, on=False)}
  {focus_js('s03-pw2', t_pw2 - 0.15)}
  {cam.to(K3, t_pw2 - 0.25, 0.5)}
  hfType(tl, document.getElementById('s03-pw2-val'), {dots!r}, {t_pw2}, {CPS});
  {cam.to(K4, t_cb - 0.35, 0.6)}
  // the two boxes, then Create account
  hfShape(tl, '#s03-cur', {t_cb:.2f}, 'arrow');
  tl.set('#s03-cur', {{ x: {cb1[0] + 220:.0f}, y: {cb1[1] + 180:.0f} }}, {t_cb - 0.01:.2f});
  tl.to('#s03-cur', {{ opacity: 1, duration: 0.15 }}, {t_cb:.2f});
  tl.to('#s03-cur', {{ x: {cb1[0]:.0f}, y: {cb1[1]:.0f}, duration: 0.4, ease: 'power2.inOut' }}, {t_cb + 0.1:.2f});
  hfShape(tl, '#s03-cur', {t_cb + 0.42:.2f}, 'hand');
  hfClick(tl, '#s03-cur', {t_cb + 0.5:.2f}, 'hand');
  tl.to('#s03-cb1-tick', {{ opacity: 1, duration: 0.12 }}, {t_cb + 0.55:.2f});
  tl.to('#s03-cur', {{ x: {cb2[0]:.0f}, y: {cb2[1]:.0f}, duration: 0.3, ease: 'power2.inOut' }}, {t_cb + 0.65:.2f});
  hfClick(tl, '#s03-cur', {t_cb + 1.0:.2f}, 'hand');
  tl.to('#s03-cb2-tick', {{ opacity: 1, duration: 0.12 }}, {t_cb + 1.05:.2f});
  tl.to('#s03-go', {{ opacity: 1, duration: 0.15 }}, {t_cb + 1.05:.2f});
  tl.to('#s03-cur', {{ x: {go[0] + 30:.0f}, y: {go[1]:.0f}, duration: 0.45, ease: 'power2.inOut' }}, {t_cb + 1.2:.2f});
  hfClick(tl, '#s03-cur', {t_cb + 1.75:.2f}, 'hand');
  tl.set('#s03-go', {{ opacity: 0 }}, {t_cb + 1.85:.2f});
  tl.set('#s03-dis', {{ opacity: 0 }}, {t_cb + 1.85:.2f});
  {spin_js('#s03-spin', t_cb + 1.85, b - a)}
  tl.to('#s03-cur', {{ x: {go[0] + 260:.0f}, y: {go[1] + 160:.0f}, duration: 0.6, ease: 'power2.out' }}, {t_cb + 2.0:.2f});
  tl.fromTo('#s03-out', {{ scale: 1 }}, {{ scale: 1.04, duration: {b - a - t_cb - 1.9:.2f}, ease: 'power1.inOut' }}, {t_cb + 1.9:.2f});
"""
    assert t_cb + 2.4 < b - a, (t_cb, b - a)
    ep.add("s03", a, b, css, body, js)


# =================================================================== s04 the one-time code
def s04_code(ep, a, b, v, lay):
    fmt = ep.fmt
    win = lay["windows"]["login"]
    O = lay["otp"]
    z0 = 1.85 if v else 1.4
    cam = Cam(ep, "s04-cam", z0, *win)
    cs = 1.3 if v else 1.0
    oc = ctr(O["#o"])
    K0 = (2.15 if v else 1.6, win[0] / 2, oc[1])
    K1 = (2.3 if v else 1.72, win[0] / 2, oc[1])
    go = cam.scr(K1, *ctr(O["#o-go"]))
    card = P.otp_card("s04", EMAIL).replace('id="s04"', 'id="s04-card"')
    body = f"""
    {band(v, f'<div id="s04-cam" class="fill" data-layout-allow-overflow>{login_window(ep, "s04", z0, win, card)}</div>')}
    {cursor('s04-cur', cs)}
"""
    t_code = 0.45
    js = f"""
  {cam.set(K0)}
  {cam.to(K1, 0.2, b - a - 0.2, 'power1.inOut')}
  tl.fromTo('#s04-card', {{ opacity: 0, x: 60 }}, {{ opacity: 1, x: 0, duration: 0.35, ease: 'power3.out' }}, 0);
  {focus_js('s04-code', 0.0)}
  hfType(tl, document.getElementById('s04-code-val'), {CODE!r}, {t_code}, 10);
  tl.set('#s04-r0', {{ display: 'none' }}, 1.0); tl.set('#s04-r1', {{ display: 'inline' }}, 1.0);
  tl.set('#s04-r1', {{ display: 'none' }}, 2.0); tl.set('#s04-r2', {{ display: 'inline' }}, 2.0);
  tl.fromTo('#s04-cur', {{ x: {go[0] + 280:.0f}, y: {go[1] + 260:.0f} }}, {{ x: {go[0] + 20:.0f}, y: {go[1]:.0f}, duration: 0.6, ease: 'power2.inOut' }}, 1.1);
  hfShape(tl, '#s04-cur', 1.6, 'hand');
  hfClick(tl, '#s04-cur', 1.8, 'hand');
  tl.set('#s04-go', {{ opacity: 0 }}, 1.9);
  {spin_js('#s04-spin', 1.9, b - a)}
  {focus_js('s04-code', 1.9, on=False)}
"""
    ep.add("s04", a, b, "", body, js)


# =================================================================== s05 colour block: what is not asked
def s05_block(ep, a, b, v):
    fmt = ep.fmt
    if v:
        groups = [["No phone", "number."], ["No Google or", "Apple login."], ["No ads. No", "tracking SDK", "in the app."]]
        size, gap = 96, 54
    else:
        groups = [["No phone number."], ["No Google or Apple login."], ["No ads. No tracking SDK in the app."]]
        size, gap = 96, 40
    lh = round(size * 1.12)
    total = sum(len(g) for g in groups) * lh + gap * (len(groups) - 1)
    top = round(fmt.cy - total / 2)
    divs, y, k = [], top, 0
    for gi, g in enumerate(groups):
        for t in g:
            divs.append(f'<div class="card-line serif g{gi}" id="s05-l{k}" style="top:{y}px;font-size:{size}px;line-height:{lh}px;color:@CANVAS@">{esc(t)}</div>')
            y += lh
            k += 1
        y += gap
    css = f"""
#s05-bg {{ background: @BROWN@; }}
#s05-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
"""
    body = f"""
    <div id="s05-bg" class="fill"></div>
    <div id="s05-all" class="fill">{''.join(divs)}</div>
"""
    starts = [0.15, 1.45, 2.75]
    js = "".join(f"  hfReveal(tl, '#s05-all .g{gi}', {starts[gi]:.2f}, 0.07);\n" for gi in range(len(groups)))
    js += f"  tl.fromTo('#s05-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);\n"
    ep.add("s05", a, b, css, body, js)


# =================================================================== s07 delete the account
def s07_delete(ep, a, b, v, lay):
    fmt = ep.fmt
    win = lay["windows"]["settings"]
    z0 = 2.3 if v else 2.1                     # the Danger zone note (12 app px) reads at 25+ px
    cam = Cam(ep, "s07-cam", z0, *win)
    cs = 1.3 if v else 1.0
    wcx, wcy = win[0] / 2, win[1] / 2
    K0 = (z0, wcx, 260 if v else wcy)
    K1 = (2.45, wcx, 290) if v else (2.25, wcx, wcy)   # 9:16: keep the dimmed header inside the band
    btn = cam.scr(K0, *ctr(lay["danger"]["#d-btn"]))
    yes = cam.scr(K1, *ctr(lay["dlg1"]["#k-a1"]))
    every = cam.scr(K1, *ctr(lay["dlg2"]["#k-a1"]))
    verify = cam.scr(K1, *ctr(lay["dlg3"]["#k-a1"]))
    dz = f'<div style="position:absolute;left:16px;top:8px">{P.danger("s07d", win[0] - 32)}</div>'
    inner = (f'<div class="a-win" id="s07-win" style="left:{(fmt.W / z0 - win[0]) / 2:.2f}px;top:{fmt.cy / z0 - win[1] / 2:.2f}px;'
             f'width:{win[0]}px;height:{win[1]}px" data-layout-allow-overlap>{dz}<div class="dlg-bar" id="s07-bar"></div>'
             f'{P.step1("s07a")}{P.step2("s07b")}{P.step3("s07c")}</div>')
    css = f"""
#s07-out {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
"""
    body = f"""
    <div id="s07-out" class="fill">
      {band(v, f'<div id="s07-cam" class="fill" data-layout-allow-overflow>{ui.appz("s07-z", fmt, z0, inner)}</div>')}
      {cursor('s07-cur', cs)}
    </div>
"""
    dots = "•" * len(PW)
    t3 = 4.9
    tt = t3 + 0.3
    te = tt + len(PW) / CPS

    def dlg_in(d, t):
        return f"tl.fromTo('#{d}', {{ opacity: 0, scale: 0.92 }}, {{ opacity: 1, scale: 1, duration: 0.22, ease: 'power2.out' }}, {t:.2f});"

    def dlg_out(d, t):
        return f"tl.to('#{d}', {{ opacity: 0, duration: 0.12 }}, {t:.2f});"

    js = f"""
  {cam.set(K0)}
  tl.fromTo('#s07-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.45, ease: 'expo.out' }}, 0);
  tl.fromTo('#s07-cur', {{ x: {btn[0] + 320:.0f}, y: {fmt.H + 60} }}, {{ x: {btn[0] + 40:.0f}, y: {btn[1]:.0f}, duration: 0.65, ease: 'power2.inOut' }}, 0.2);
  hfShape(tl, '#s07-cur', 0.75, 'hand');
  hfClick(tl, '#s07-cur', 1.0, 'hand');
  // step 1: "Delete Account?"
  tl.to('#s07-bar', {{ opacity: 1, duration: 0.15 }}, 1.1);
  {dlg_in('s07a', 1.1)}
  {cam.to(K1, 1.15, 0.55)}
  hfShape(tl, '#s07-cur', 1.3, 'arrow');
  tl.to('#s07-cur', {{ x: {yes[0]:.0f}, y: {yes[1] + 6:.0f}, duration: 0.7, ease: 'power2.inOut' }}, 2.3);
  hfShape(tl, '#s07-cur', 2.95, 'hand');
  tl.to('#s07a-a1-h', {{ opacity: 0.08, duration: 0.1 }}, 2.95);
  hfClick(tl, '#s07-cur', 3.3, 'hand');
  {dlg_out('s07a', 3.4)}
  // step 2: "This is permanent"
  {dlg_in('s07b', 3.5)}
  hfShape(tl, '#s07-cur', 3.55, 'arrow');
  tl.to('#s07-cur', {{ x: {every[0]:.0f}, y: {every[1] + 6:.0f}, duration: 0.55, ease: 'power2.inOut' }}, 3.95);
  hfShape(tl, '#s07-cur', 4.45, 'hand');
  tl.to('#s07b-a1-h', {{ opacity: 0.08, duration: 0.1 }}, 4.45);
  hfClick(tl, '#s07-cur', 4.7, 'hand');
  {dlg_out('s07b', 4.8)}
  // step 3: the password again
  {dlg_in('s07c', t3)}
  {focus_js('s07c-pw', t3)}
  hfShape(tl, '#s07-cur', {t3 + 0.05:.2f}, 'arrow');
  tl.to('#s07-cur', {{ x: {verify[0] + 120:.0f}, y: {verify[1] + 150:.0f}, duration: 0.4, ease: 'power2.out' }}, {t3 + 0.05:.2f});
  hfType(tl, document.getElementById('s07c-pw-val'), {dots!r}, {tt:.2f}, {CPS});
  tl.to('#s07-cur', {{ x: {verify[0]:.0f}, y: {verify[1] + 6:.0f}, duration: 0.5, ease: 'power2.inOut' }}, {te + 0.1:.2f});
  hfShape(tl, '#s07-cur', {te + 0.55:.2f}, 'hand');
  tl.to('#s07c-a1-h', {{ opacity: 0.08, duration: 0.1 }}, {te + 0.55:.2f});
  hfClick(tl, '#s07-cur', {te + 0.8:.2f}, 'hand');
  tl.set('#s07c-a1-t', {{ opacity: 0 }}, {te + 0.9:.2f});
  tl.set('#s07c-a1-h', {{ opacity: 0 }}, {te + 0.9:.2f});
  tl.set('#s07c-a0', {{ color: 'rgba(232,228,216,0.38)' }}, {te + 0.9:.2f});
  {spin_js('#s07c-a1-spin', te + 0.9, b - a)}
  tl.to('#s07-cur', {{ x: {verify[0] + 200:.0f}, y: {verify[1] + 200:.0f}, duration: 0.6, ease: 'power2.out' }}, {te + 1.0:.2f});
  tl.fromTo('#s07-out', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a - te - 0.9:.2f}, ease: 'power1.inOut' }}, {te + 0.9:.2f});
"""
    assert te + 1.6 < b - a, (te, b - a)
    ep.add("s07", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-14-just-an-email")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-14-just-an-email-vertical")
