#!/usr/bin/env python3
"""Fidelity sheets for the episode 14 pieces (the library has none of them).

Reference halves (real app): the REAL Flutter widgets rendered by
_work/fidelity_test/real_widgets_test.dart (LoginPage in sign-up mode, OtpVerificationPage,
the danger zone and the three AlertDialogs of _deleteAccount, Clawed dark theme, 2 px per app px)
-> _work/fidelity/real-*.png.
Video halves: pieces.py laid out like the test (same viewport, same 2 px per app px) and put in
the same state with plain DOM calls -> _work/fidelity/vid-*.png. Sheets: _work/fidelity/*.jpg.

Run:  python3 _work/fidelity.py      (after the flutter test, from anywhere)
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
sys.path.insert(0, str(HERE))
from chukvid import fidelity  # noqa: E402

import pieces as P  # noqa: E402

F = HERE / "fidelity"
PROJ = HERE.parent
EMAIL, PW = "sam@example.com", "Tide-Lantern-48!"

# plain-DOM versions of what the timeline does in the video
JS = """
<script>
function $(s){return document.querySelector(s);}
function floatLab(id){ $(id+'-lab').style.opacity=0; $(id+'-flab').style.opacity=1; }
function focus(id){ $(id+'-ring').style.opacity=1; $(id+'-gap').style.opacity=1; floatLab(id); }
function val(id,t){ $(id+'-val').textContent=t; floatLab(id); }
function meter(id,st){ $(id).style.display='flex'; for(var i=0;i<4;i++){ $(id+'-b'+i).style.background = i<st.segs?st.color:'rgba(158,158,158,0.3)'; }
  for(var j=0;j<4;j++){ $(id+'-l'+j).style.display = j===st.idx?'inline':'none'; } $(id+'-reqs').style.display=st.valid?'none':'flex';
  st.has.forEach(function(ok,i){ $(id+'-q'+i).className='lg-req'+(ok?' ok':''); }); }
function tick(id){ $(id+'-tick').style.opacity=1; }
</script>
"""


def page(body, w, h, script):
    return (f'<div class="lg-page" style="left:0;top:0;width:{w}px;height:{h}px">{body}</div>{JS}'
            f'<script>{script}</script>')


def st(pw):
    import json
    return json.dumps(P.strength(pw))


def dots(n):
    return "•" * n


shots = []
# sign-up: empty, mid-typing (Tide-La, password focused), filled
shots.append(("signup-empty", page(P.signup_card("s"), 480, 900, ""), (480, 900),
              "LoginPage, sign-up mode (login_page.dart): display name optional, email, password, confirm, two checkboxes"))
shots.append(("signup-typing", page(P.signup_card("s"), 480, 900,
              f"val('#s-mail','{EMAIL}'); focus('#s-pw'); val('#s-pw','{dots(7)}'); meter('#s-m',{st('Tide-La')});"), (480, 900),
              "typing the password: strength meter + requirement list (password_strength_meter.dart)"))
shots.append(("signup-filled", page(P.signup_card("s"), 480, 900,
              f"val('#s-mail','{EMAIL}'); val('#s-pw','{dots(16)}'); meter('#s-m',{st(PW)}); val('#s-pw2','{dots(16)}');"
              "tick('#s-cb1'); tick('#s-cb2'); $('#s-go').style.opacity=1;"), (480, 900),
              "filled: sam@example.com, strong password, both boxes ticked, Create account enabled"))
shots.append(("otp", page(P.otp_card("o", EMAIL), 480, 640,
              "focus('#o-code'); $('#o-code-val').textContent='482915'; $('#o-r0').style.display='none'; $('#o-r2').style.display='inline';"), (480, 640),
              "OtpVerificationPage: the 6-digit code from the email"))
DZ = f'<div style="position:absolute;left:16px;top:8px">{P.danger("d", 608)}</div>'
shots.append(("danger", f'<div class="fill" style="background:#262624">{DZ}</div>', (640, 760),
              "account_settings_page.dart: Danger zone, ExpressiveInfoCard + FilledButton (errorContainer)"))
for name, dlg, extra, title in (
        ("delete-1", P.step1("k"), "", "_deleteAccount step 1: AlertDialog, the erase list incl. active subscriptions"),
        ("delete-2", P.step2("k"), "", "_deleteAccount step 2: final warning"),
        ("delete-3", P.step3("k"), f"focus('#k-pw'); val('#k-pw','{dots(16)}');", "_deleteAccount step 3: password again, Verify & Delete")):
    body = (f'<div class="fill" style="background:#262624">{DZ}<div class="dlg-bar" style="opacity:1"></div>{dlg}</div>{JS}'
            f'<script>document.querySelector("#k").style.opacity=1;{extra}</script>')
    shots.append((name, body, (640, 760), title))

if __name__ == "__main__":
    only = sys.argv[1:]
    for name, body, size, title in shots:
        if only and name not in only:
            continue
        vid = F / f"vid-{name}.png"
        fidelity.harness(PROJ, body, size, vid, extra_css=P.CSS)
        fidelity.sheet(F / f"real-{name}.png", vid, F / f"{name}.jpg", title)
