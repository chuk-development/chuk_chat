"""Episode 14 app pieces, rebuilt 1:1 from the Flutter widgets (not yet in chukvid.ui).

All values are app px (Flutter logical px) inside chukvid.ui.appz(). Source per piece:
* sign-up page:  lib/pages/login_page.dart (sign-up mode), theme lib/constants.dart buildAppTheme
                 (InputDecorationTheme: filled surfaceLow, radius 16, 2 px accent ring on focus,
                 labelStyle 15 onSurfaceVariant, floatingLabelStyle 14 accent, contentPadding 16/16;
                 ElevatedButton surfaceHigh pill 48; TextButton accent 14 w600)
* strength meter: lib/widgets/password_strength_meter.dart + lib/utils/input_validator.dart
* code page:     lib/pages/otp_verification_page.dart
* danger zone:   lib/pages/account_settings_page.dart (ExpressiveSectionHeader, ExpressiveInfoCard,
                 FilledButton errorContainer) from lib/widgets/expressive_settings.dart
* dialogs:       _deleteAccount() in account_settings_page.dart (AlertDialog, M3 defaults,
                 dialogTheme surfaceHigh radius 28)
Colours: Clawed dark (bg #262624, fg #E8E4D8, accent #D97757, contrast 0.55), sampled on the
real widget renders in fidelity/real-*.png.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "_lib"))
from chukvid.core import REPO, esc  # noqa: E402

# ------------------------------------------------------------------ icons
_INSET = 0.86   # lib/widgets/icons/huge_icon.dart _opticalInset


def huge(name, size, color="currentColor", cls=""):
    """HugeIcon from the app's own assets/icons/hugeicons/<name>.svg, drawn at 0.86 of its box."""
    svg = (REPO / f"assets/icons/hugeicons/{name}.svg").read_text()
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    px = round(size * _INSET, 2)
    pad = (size - px) / 2
    return (f'<span class="ic {cls}" style="width:{size}px;height:{size}px;color:{color}">'
            f'<svg viewBox="0 0 24 24" fill="none" style="width:{px}px;height:{px}px;margin:{pad:.2f}px">{inner}</svg></span>')


_MAT = {}


def _material_font():
    """MaterialIcons-Regular.otf from the Flutter SDK: $FLUTTER_ROOT, else the SDK of the
    `flutter` on PATH. A clear error if neither has it."""
    import os
    import shutil
    roots = []
    if os.environ.get("FLUTTER_ROOT"):
        roots.append(Path(os.environ["FLUTTER_ROOT"]))
    exe = shutil.which("flutter")
    if exe:
        roots.append(Path(exe).resolve().parent.parent)        # <sdk>/bin/flutter
    rel = "bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
    for r in roots:
        if (r / rel).is_file():
            return r / rel
    raise SystemExit(f"MaterialIcons-Regular.otf not found under {[str(r) for r in roots] or 'no Flutter SDK'}. "
                     "Set FLUTTER_ROOT to the Flutter SDK, or run `flutter precache` once.")


def material(code, size, color="currentColor", cls=""):
    """A Material Icons glyph (AppIcon falls back to it when the set has no HugeIcon),
    outlined from the Flutter SDK's MaterialIcons-Regular.otf."""
    if code not in _MAT:
        from fontTools.pens.svgPathPen import SVGPathPen
        from fontTools.ttLib import TTFont
        f = TTFont(_material_font())
        gs = f.getGlyphSet()
        name = f.getBestCmap()[code]
        pen = SVGPathPen(gs)
        gs[name].draw(pen)
        _MAT[code] = (pen.getCommands(), f["head"].unitsPerEm, f["hhea"].ascent)
    d, em, asc = _MAT[code]
    return (f'<span class="ic {cls}" style="width:{size}px;height:{size}px;color:{color}">'
            f'<svg viewBox="0 0 {em} {em}" style="width:{size}px;height:{size}px">'
            f'<path transform="matrix(1 0 0 -1 0 {asc})" fill="currentColor" d="{d}"/></svg></span>')


DELETE_FOREVER = 0xe1ba
LOCK_OUTLINE = 0xe3b1
MARK_EMAIL_READ = 0xf1b5
RADIO_UNCHECKED = 0xe504

# ------------------------------------------------------------------ CSS
CSS = """
.ic { display: inline-flex; flex: none; align-items: center; justify-content: center; }
.ic svg { display: block; flex: none; }
.lg-page { position: absolute; background: #262624; overflow: hidden; display: flex; align-items: safe center; justify-content: center; }
.lg-card { width: 400px; flex: none; background: #333330; border: 1px solid rgba(232,228,216,0.2); border-radius: 16px; padding: 23px;
  display: flex; flex-direction: column; font-family: 'Ubuntu', sans-serif; color: #E8E4D8; }
.lg-h { font-size: 24px; line-height: 32px; font-weight: 400; text-align: center; color: #E8E4D8; }
.lg-sub { margin-top: 8px; font-size: 14px; line-height: 20px; letter-spacing: 0.25px; text-align: center; color: rgba(232,228,216,0.7); }
.lg-f { position: relative; height: 56px; flex: none; border-radius: 16px; background: #2E2E2C; }
.lg-ring { position: absolute; inset: 0; border-radius: 16px; border: 2px solid #D97757; opacity: 0; }
.lg-gap { position: absolute; top: 0; height: 2.5px; background: #2E2E2C; opacity: 0; }
.lg-lab { position: absolute; left: 20px; top: 0; font-size: 14px; line-height: 16px; white-space: nowrap; transform-origin: 0 50%;
  color: rgba(232,228,216,0.861); transform: translateY(20px) scale(1.0714); }
.lg-lab.fl { color: #D97757; transform: translateY(-8px) scale(0.75); }
.lg-val { position: absolute; left: 20px; top: 16px; height: 24px; font-size: 16px; line-height: 24px; letter-spacing: 0.6px; white-space: nowrap; color: #E8E4D8; }
.lg-val.dots { letter-spacing: 0.28px; }
.lg-cur { display: inline-block; width: 2px; height: 20px; margin-left: 1px; vertical-align: -4px; background: #D97757; opacity: 0; }
.lg-sfx { position: absolute; right: 0; top: 4px; width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; color: #E8E4D8; }
.lg-pfx { position: absolute; left: 0; top: 4px; width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; color: rgba(232,228,216,0.861); }
.lg-meter { display: none; flex-direction: column; margin-top: 12px; }
.lg-bars { display: flex; gap: 4px; height: 4px; }
.lg-bar { flex: 1; height: 4px; border-radius: 2px; background: rgba(158,158,158,0.3); }
.lg-strength { margin-top: 8px; font-size: 12px; line-height: 17px; font-weight: 500; }
.lg-reqs { margin-top: 12px; display: flex; flex-direction: column; }
.lg-req { display: flex; align-items: center; gap: 8px; height: 17px; margin-bottom: 4px; font-size: 12px; line-height: 17px; white-space: nowrap; color: #9E9E9E; }
.lg-req .on { display: none; }
.lg-req.ok { color: #4CAF50; }
.lg-req.ok .on { display: inline-flex; }
.lg-req.ok .off { display: none; }
.lg-row { display: flex; }
.lg-cb { width: 48px; height: 48px; flex: none; position: relative; }
.lg-box { position: absolute; left: 15px; top: 15px; width: 18px; height: 18px; border-radius: 2px; border: 2px solid rgba(232,228,216,0.5); }
.lg-tick { position: absolute; left: 15px; top: 15px; width: 18px; height: 18px; border-radius: 2px; background: #D97757; opacity: 0; }
.lg-tick svg { position: absolute; inset: 0; }
.lg-cbt { font-size: 12px; line-height: 16px; letter-spacing: 0.28px; color: rgba(232,228,216,0.7); }
.lg-cbt a { color: #D97757; text-decoration: underline; text-underline-offset: 2px; }
.lg-btn { height: 48px; flex: none; border-radius: 999px; display: flex; align-items: center; justify-content: center; gap: 8px;
  font-size: 14px; font-weight: 600; letter-spacing: 0.1px; white-space: nowrap; }
.lg-btn.elev { background: rgba(232,228,216,0.12); color: rgba(232,228,216,0.38); }
.lg-spin { position: absolute; left: 50%; top: 50%; margin: -10px 0 0 -10px; }
.lg-elev { position: relative; height: 48px; flex: none; }
.lg-elev .lg-btn { position: absolute; inset: 0; }
.lg-elev .on { background: #41413E; color: #E8E4D8; opacity: 0; }
.lg-tbtn { height: 48px; flex: none; display: flex; align-items: center; justify-content: center; font-size: 14px; font-weight: 600; letter-spacing: 0.1px; color: #D97757; white-space: nowrap; }
.lg-tbtn.dis { color: rgba(232,228,216,0.38); }
/* settings: danger zone */
.dz { position: absolute; font-family: 'Ubuntu', sans-serif; }
.dz-h { padding: 16px 6px 8px; font-size: 16px; line-height: 24px; font-weight: 700; letter-spacing: 0.15px; color: #FFB4AB; }
.dz-info { display: flex; align-items: flex-start; gap: 12px; padding: 14px 16px; border-radius: 26px; background: #93000A; color: #FFDAD6;
  font-size: 12px; line-height: 16.8px; letter-spacing: 0.28px; }
.dz-btn { margin-top: 12px; height: 48px; border-radius: 999px; background: #93000A; color: #FFDAD6; display: flex; align-items: center; justify-content: center; gap: 8px;
  font-size: 14px; font-weight: 600; letter-spacing: 0.1px; white-space: nowrap; }
/* AlertDialog */
.dlg-bar { position: absolute; inset: 0; background: rgba(0,0,0,0.54); opacity: 0; }
.dlg-wrap { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
.dlg { min-width: 280px; max-width: calc(100% - 80px); background: #41413E; border-radius: 28px; font-family: 'Ubuntu', sans-serif;
  box-shadow: 0 3px 6px rgba(0,0,0,0.18); opacity: 0; }
.dlg-t { display: flex; align-items: center; gap: 10px; padding: 24px 24px 0; font-size: 24px; line-height: 32px; color: #E8E4D8; white-space: nowrap; }
.dlg-c { padding: 16px 24px 24px; font-size: 14px; line-height: 20px; letter-spacing: 0.2px; color: #E8E4D8; white-space: pre-wrap; }
.dlg-c .pl { white-space: normal; }
.dlg-a { display: flex; justify-content: flex-end; gap: 8px; padding: 0 24px 24px; }
.dlg-a span { height: 44px; padding: 0 16px; border-radius: 999px; display: flex; align-items: center; font-size: 14px; font-weight: 600; letter-spacing: 0.1px; color: #D97757; white-space: nowrap; position: relative; }
.dlg-a span.err { color: #FFB4AB; }
.dlg-a span i { position: absolute; inset: 0; border-radius: 999px; background: currentColor; opacity: 0; }
.dlg-pw { margin-top: 0; }
.dspin { margin: -8px 0 0 -8px; }
"""

# CircularProgressIndicator(strokeWidth: 2), primary colour; the arc turns with the timeline
SPIN = ('<svg class="lg-spin" id="{id}" viewBox="0 0 20 20" style="width:{s}px;height:{s}px;display:none">'
        '<circle cx="10" cy="10" r="9" fill="none" stroke="#D97757" stroke-width="2" stroke-linecap="butt" stroke-dasharray="38 99"/></svg>')
CHECK = ('<svg viewBox="0 0 18 18"><path d="M2.7 8.1 7.2 12.6 15.3 4.5" fill="none" stroke="#E8E4D8" stroke-width="2"/></svg>')


# ------------------------------------------------------------------ text fields
_FONT = None


def text_w(text, size):
    """Advance width of Ubuntu text (PIL), for the border gap behind a floated label."""
    global _FONT
    from PIL import ImageFont
    if _FONT is None:
        _FONT = str(HERE.parents[1] / "_lib/assets/fonts/Ubuntu-wght.ttf")
    return ImageFont.truetype(_FONT, 200).getlength(text) * size / 200


def field(pid, label, value="", obscure=False, suffix=None, prefix=None, floated=False):
    """A filled TextFormField. Ids: {pid} (box), -ring (2 px focus ring), -gap (ring gap behind
    the floated label), -lab, -val (typed text), -cur (caret). The floated label sits at x 20
    (also over a prefix icon, as M3 does); the value starts at 20, or 52 after a prefix."""
    sfx = f'<span class="lg-sfx">{suffix}</span>' if suffix else ""
    pfx = f'<span class="lg-pfx">{prefix}</span>' if prefix else ""
    vleft = 52 if prefix else 20
    gw = round(text_w(label, 10.5) + 8, 1)
    return (f'<div class="lg-f" id="{pid}">{pfx}'
            f'<span class="lg-ring" id="{pid}-ring"></span>'
            f'<span class="lg-gap" id="{pid}-gap" style="left:16px;width:{gw}px"></span>'
            f'<span class="lg-lab" id="{pid}-lab" style="left:{vleft}px;opacity:{0 if floated else 1}">{esc(label)}</span>'
            f'<span class="lg-lab fl" id="{pid}-flab" style="opacity:{1 if floated else 0}">{esc(label)}</span>'
            f'<span class="lg-val{" dots" if obscure else ""}" style="left:{vleft}px"><span id="{pid}-val">{esc(value)}</span>'
            f'<span class="lg-cur" id="{pid}-cur"></span></span>{sfx}</div>')


def strength(pw):
    """InputValidator.validatePasswordStrength + PasswordStrengthMeter visuals."""
    has = [len(pw) >= 8, bool(re.search(r"[A-Z]", pw)), bool(re.search(r"[a-z]", pw)),
           bool(re.search(r"[0-9]", pw)), bool(re.search(r"[^A-Za-z0-9]", pw))]
    score = sum(has) + (len(pw) >= 16) + (len(pw) >= 20)
    if score <= 2:
        s = ("#F44336", 1, "Weak password")
    elif score <= 4:
        s = ("#FF9800", 2, "Fair password")
    elif score <= 5:
        s = ("#FFEB3B", 3, "Good password")
    else:
        s = ("#4CAF50", 4, "Strong password")
    return dict(color=s[0], segs=s[1], label=s[2], has=has, valid=all(has), idx=s[1] - 1)


LEVELS = [("#F44336", "Weak password"), ("#FF9800", "Fair password"), ("#FFEB3B", "Good password"), ("#4CAF50", "Strong password")]


REQS = ["At least 8 characters", "Uppercase letter (A-Z)", "Lowercase letter (a-z)", "Number (0-9)",
        "Special character (!@#$%^&*)"]


def meter(pid):
    bars = "".join(f'<span class="lg-bar" id="{pid}-b{i}"></span>' for i in range(4))
    levels = "".join(f'<span id="{pid}-l{i}" style="display:none;color:{c}">{t}</span>'
                     for i, (c, t) in enumerate(LEVELS))
    reqs = "".join(
        f'<div class="lg-req" id="{pid}-q{i}">{material(RADIO_UNCHECKED, 16, "#9E9E9E", "off")}'
        f'{huge("checkmark-circle02", 16, "#4CAF50", "on")}<span>{esc(t)}</span></div>' for i, t in enumerate(REQS))
    return (f'<div class="lg-meter" id="{pid}"><div class="lg-bars">{bars}</div>'
            f'<div class="lg-strength" id="{pid}-lab">{levels}</div><div class="lg-reqs" id="{pid}-reqs">{reqs}</div></div>')


def meter_js(pid, pw, t0, cps=18):
    """tl.set calls that walk the meter through every prefix of pw while it is typed."""
    out = [f"tl.set('#{pid}', {{ display: 'flex' }}, {t0 + 1 / cps:.3f});"]
    for n in range(1, len(pw) + 1):
        t = t0 + n / cps
        st = strength(pw[:n])
        for i in range(4):
            out.append(f"tl.set('#{pid}-b{i}', {{ backgroundColor: '{st['color'] if i < st['segs'] else 'rgba(158,158,158,0.3)'}' }}, {t:.3f});")
        for i in range(4):
            out.append(f"tl.set('#{pid}-l{i}', {{ display: '{'inline' if i == st['idx'] else 'none'}' }}, {t:.3f});")
        out.append(f"tl.set('#{pid}-reqs', {{ display: '{'none' if st['valid'] else 'flex'}' }}, {t:.3f});")
        for i, ok in enumerate(st["has"]):
            out.append(f"tl.set('#{pid}-q{i}', {{ attr: {{ class: 'lg-req{' ok' if ok else ''}' }} }}, {t:.3f});")
    return "\n  ".join(out)


def checkbox_row(pid, text_html, center=False, top_pad=12):
    al = "center" if center else "flex-start"
    pad = "" if center else f"padding-top:{top_pad}px;"
    return (f'<div class="lg-row" style="align-items:{al}"><span class="lg-cb" id="{pid}"><span class="lg-box"></span>'
            f'<span class="lg-tick" id="{pid}-tick">{CHECK}</span></span>'
            f'<span class="lg-cbt" style="{pad}flex:1">{text_html}</span></div>')


EYE_OFF = None


def signup_card(pid, email_label="Email"):
    """LoginPage in sign-up mode (after "Don't have an account? Sign up"), empty."""
    eye = huge("view-off", 24, "#E8E4D8")
    terms = ('I agree to the <a>Terms of Service</a> and <a>Privacy Policy</a>')
    return f"""<div class="lg-card" id="{pid}">
      <div class="lg-h">Welcome to Chuk Chat</div>
      <div class="lg-sub">Create an account with email &amp; password</div>
      <div style="height:24px;flex:none"></div>
      {field(pid + '-name', 'Display name')}
      <div style="height:16px;flex:none"></div>
      {field(pid + '-mail', email_label)}
      <div style="height:16px;flex:none"></div>
      {field(pid + '-pw', 'Password', obscure=True, suffix=eye)}
      {meter(pid + '-m')}
      <div style="height:16px;flex:none"></div>
      {field(pid + '-pw2', 'Confirm password', obscure=True, suffix=eye)}
      <div style="height:16px;flex:none"></div>
      {checkbox_row(pid + '-cb1', terms)}
      <div style="height:4px;flex:none"></div>
      {checkbox_row(pid + '-cb2', 'I confirm that I am at least 16 years old', center=True)}
      <div style="height:24px;flex:none"></div>
      <div class="lg-elev" data-layout-allow-overlap><span class="lg-btn elev"><span id="{pid}-dis">Create account</span>{SPIN.format(id=pid + '-spin', s=20)}</span><span class="lg-btn on" id="{pid}-go">Create account</span></div>
      <div style="height:16px;flex:none"></div>
      <div class="lg-tbtn" id="{pid}-alt">Already have an account? Sign in</div>
    </div>"""


def otp_card(pid, email, code_label="Verification code"):
    return f"""<div class="lg-card" id="{pid}">
      <div style="display:flex;justify-content:center">{material(MARK_EMAIL_READ, 48, "#D97757")}</div>
      <div style="height:16px;flex:none"></div>
      <div class="lg-h">Enter the code</div>
      <div class="lg-sub" style="margin-top:12px">We emailed a 6-digit code to {esc(email)}. Enter it below to confirm your account.</div>
      <div style="height:24px;flex:none"></div>
      <div class="lg-f otp" id="{pid}-code"><span class="lg-ring" id="{pid}-code-ring"></span>
        <span class="lg-gap" id="{pid}-code-gap" style="left:16px;width:{round(text_w(code_label, 10.5) + 8, 1)}px"></span><span class="lg-lab" id="{pid}-code-lab">{esc(code_label)}</span><span class="lg-lab fl" id="{pid}-code-flab" style="opacity:0">{esc(code_label)}</span>
        <span class="otp-v" id="{pid}-code-v"><span id="{pid}-code-val"></span><span class="lg-cur" id="{pid}-code-cur"></span></span></div>
      <div style="height:24px;flex:none"></div>
      <div class="lg-elev" data-layout-allow-overlap><span class="lg-btn elev"><span style="opacity:0">Verify</span>{SPIN.format(id=pid + '-spin', s=20)}</span><span class="lg-btn on" id="{pid}-go" style="opacity:1">Verify</span></div>
      <div style="height:8px;flex:none"></div>
      <div class="lg-tbtn dis" id="{pid}-resend"><span>Resend code in <span id="{pid}-r0">60</span><span id="{pid}-r1" style="display:none">59</span><span id="{pid}-r2" style="display:none">58</span>s</span></div>
      <div class="lg-tbtn">Use a different email</div>
    </div>"""


CSS += """
.lg-f.otp { height: 64px; }
.otp-v { position: absolute; left: 16px; right: 16px; top: 16px; height: 32px; text-align: center; font-size: 24px; line-height: 32px; letter-spacing: 8px; color: #E8E4D8; white-space: nowrap; }
.otp-v .lg-cur { height: 26px; vertical-align: -5px; margin-left: -6px; }
"""


def danger(pid, width):
    warn = huge("alert02", 18, "#FFDAD6")
    return f"""<div class="dz" id="{pid}" style="width:{width}px">
      <div class="dz-h">Danger zone</div>
      <div class="dz-info">{warn}<span style="flex:1">Deleting your account will cancel all subscriptions, remove your data, and cannot be undone.</span></div>
      <div class="dz-btn" id="{pid}-btn">{material(DELETE_FOREVER, 18, "#FFDAD6")}<span>Delete Account</span></div>
    </div>"""


STEP1_BODY = ("Are you sure you want to delete your account?\n\nThis will permanently erase:\n  • All your chats and messages\n"
              "  • All stored memories\n  • Your profile and settings\n  • Any active subscriptions\n\n"
              "This action is irreversible. Your data cannot be recovered.")
STEP2_BODY = ("This is your last chance to turn back.\n\nOnce deleted, there is absolutely no way to recover your account, chats, "
              "memories, or any associated data.\n\nEverything will be gone forever.\n\nDo you still want to proceed?")


def dialog(pid, title, body, actions, icon=None, pre=True, extra=""):
    """AlertDialog. actions: [(label, is_error)]; ids {pid}, {pid}-a{i} (and -a{i}-h hover ink)."""
    ic = icon or ""
    acts = "".join(f'<span id="{pid}-a{i}" class="{"err" if e else ""}"><i id="{pid}-a{i}-h"></i><b id="{pid}-a{i}-t" style="font-weight:600">{esc(l)}</b>'
                   + (SPIN.replace('margin: -10px', '').format(id=f"{pid}-a{i}-spin", s=16).replace('class="lg-spin"', 'class="lg-spin dspin"') if e else "") + '</span>'
                   for i, (l, e) in enumerate(actions))
    b = esc(body) if pre else f'<div class="pl">{esc(body)}</div>'
    return (f'<div class="dlg-wrap"><div class="dlg" id="{pid}"><div class="dlg-t">{ic}<span>{esc(title)}</span></div>'
            f'<div class="dlg-c">{b}{extra}</div><div class="dlg-a">{acts}</div></div></div>')


def step1(pid):
    return dialog(pid, "Delete Account?", STEP1_BODY, [("Cancel", False), ("Yes, I want to delete", True)],
                  icon=huge("alert02", 28, "#FFB4AB"))


def step2(pid):
    # the body wraps at the dialog's max width (like Text in AlertDialog)
    return dialog(pid, "This is permanent", STEP2_BODY, [("No, keep my account", False), ("Delete everything", True)],
                  icon=material(DELETE_FOREVER, 28, "#FFB4AB"), pre=True)


def step3(pid):
    pw = field(pid + "-pw", "Password", obscure=True, prefix=material(LOCK_OUTLINE, 24), floated=True)
    return dialog(pid, "Confirm your password", "To confirm account deletion, please enter your password.",
                  [("Cancel", False), ("Verify & Delete", True)],
                  extra=f'<div style="height:16px"></div><div style="white-space:normal">{pw}</div>')
