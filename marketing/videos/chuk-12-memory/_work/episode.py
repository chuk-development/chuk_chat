#!/usr/bin/env python3
"""Episode 12 "memory": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 12): the workspace "Tax helper" gets its custom instructions,
the Memory gets one more line ("- Self-employed since 2024"). Cut: what reaches the
database. The projects row holds the placeholder "🔒" / NULL in the plain columns and one
AES-256-GCM envelope in encrypted_meta; user_preferences.identity_memory is an envelope too.
"It remembers you. Encrypted."
Claim (PRIVACY_CLAIMS.md, Workspaces and memory, may say): your instructions and memory are
encrypted on your device before they are stored. Not said: "everything is encrypted"
(row ids, timestamps, sizes are plain; the table shows updated_at in plain text).
Code: lib/services/workspace_storage_service.dart:81-94, 227-233, 345-385 (sealed columns),
lib/services/encrypted_meta.dart (envelope body {v,tbl,row,...}),
lib/tool_handlers/notes_tools.dart:502-527, 755 (memory: EncryptionService.encrypt -> upsert).

Builds both formats from one spec:
  ../chuk-12-memory/            16:9 1920x1080
  ../chuk-12-memory-vertical/   9:16 1080x1920 (re-laid out, not cropped)
Run (once): python3 _work/make_assets.py   then: python3 _work/episode.py
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
from chukvid.cipher import mask_uuid_short  # noqa: E402
from chukvid.core import cursor, esc, hi  # noqa: E402
import ui12  # noqa: E402

MUSIC = VIDEOS.parent / "_shared/music/s4-every-beat-45s.wav"
DUR = 45.0
C = json.loads((HERE / "cipher.json").read_text())
W = C["workspace"]
M = C["memory"]
WS_ROWS = C["workspaces"]
PREFS = C["prefs"]

# strings exactly as the app shows them
HINT_PROMPT = ("e.g., You are a senior developer helping with a Flutter workspace. "
               "Use Dart best practices...")                       # workspace_detail_page.dart
MEMORY_HINT = ("Long-term knowledge the AI remembers across conversations. The AI can also "
               "update this when it learns important facts or decisions.")   # l10n memoryHint
MEMORY_EXAMPLE = ""                                                 # field is never empty here
TYPED_MEM = "\n" + M["new"]                                         # Enter, then the new line

# ------------------------------------------------------------------ cuts on the beat grid
# s4-every-beat: 123.4 BPM, beat 0.49 s, beats up to 35.06; then the track rings out under
# the end card. Rough targets, snapped to the beat grid.
TARGETS = [3.9, 11.7, 18.0, 20.46, 25.3, 29.68, 32.62, 35.06]
CPS = 18                                                            # typing, chars/s


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + ui12.CSS + EP_CSS)
    ep.asset(HERE / "gen/lock-emoji.ttf", "fonts/lock-emoji.ttf")
    ep.write()                                   # scaffold first: `beats` needs the music in place
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.4)
    v = fmt.vertical
    cs = 1.3 if v else 1.0                       # cursor scale

    s01_hook(ep, cut[0], cut[1], v)
    s02_workspace(ep, cut[1], cut[2], v, cs)
    s03_memory(ep, cut[2], cut[3], v, cs)
    scenes.card(ep, "s04", cut[3], cut[4], ["What reaches", "our database?"] if v else ["What reaches our database?"])
    s05_projects(ep, cut[4], cut[5], v, cs)
    s06_prefs(ep, cut[5], cut[6], v, cs)
    s07_block(ep, cut[6], cut[7], v)
    scenes.card(ep, "s08", cut[7], cut[8], ["It remembers", "you. Encrypted."] if v else ["It remembers you. Encrypted."],
                bg="@TAN@")
    scenes.end_card(ep, "s09", cut[8], DUR)
    ep.write()
    ep.report()
    return ep


EP_CSS = """
.memo { position: absolute; left: 0; right: 0; text-align: center; font-family: 'ChukMono', monospace; font-weight: 400;
  color: @SOFT@; white-space: pre; font-variant-ligatures: none; }
.memo .a-caret { background: @SOFT@; }
.emo { font-family: 'ChukEmoji'; font-style: normal; }
.nul { color: #889096; }
"""


def win_geom(fmt):
    """The app window (a-win) for the page shots, in app px inside the zoom box."""
    if fmt.vertical:
        return dict(Z=2.5, left=12, top=92, w=408, h=520)
    return dict(Z=2.2, left=(fmt.W / 2.2 - 800) / 2, top=10, w=800, h=471)


# =================================================================== s01 hook: what does it remember
def s01_hook(ep, a, b, v):
    fmt = ep.fmt
    if v:
        lines, size, msize = ["What does", "your AI remember", "about you?"], 112, 40
    else:
        lines, size, msize = ["What does your AI", "remember about you?"], 112, 46
    lh = round(size * 1.12)
    gap = 70
    block = len(lines) * lh + gap + msize * 1.4
    top = round(fmt.cy - block / 2)
    ldivs = "".join(f'<div class="card-line serif" id="s01-l{i}" style="top:{top + i * lh}px;font-size:{size}px;'
                    f'line-height:{lh}px">{esc(t)}</div>' for i, t in enumerate(lines))
    mtop = top + len(lines) * lh + gap
    css = f"""
#s01-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}
#s01-m {{ top: {mtop}px; font-size: {msize}px; line-height: {msize * 1.4:.0f}px; }}
"""
    body = f"""
    <div id="s01-all" class="fill">
      {ldivs}
      <div class="memo" id="s01-m"><span id="s01-mt"></span><span class="a-caret" id="s01-mc" style="opacity:0"></span></div>
    </div>
"""
    t0 = 1.35
    js = f"""
  hfReveal(tl, '#s01-l0', 0.12);
  hfReveal(tl, '#s01-l1', 0.5);
  {"hfReveal(tl, '#s01-l2', 0.88);" if v else ""}
  tl.set('#s01-mc', {{ opacity: 1 }}, {t0 - 0.2});
  var e = hfType(tl, document.getElementById('s01-mt'), {M['new']!r}, {t0}, {CPS});
  tl.set('#s01-mc', {{ opacity: 0 }}, e + 0.3);
  tl.set('#s01-mc', {{ opacity: 1 }}, e + 0.6);
  tl.set('#s01-mc', {{ opacity: 0 }}, e + 0.9);
  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s01", a, b, css, body, js)


# =================================================================== s02 workspace settings: the instructions
def s02_workspace(ep, a, b, v, cs):
    fmt = ep.fmt
    g = win_geom(fmt)
    if v:                                        # the Settings tab ends at Save Changes: a shorter window
        g.update(top=112, h=480)
    Z = g["Z"]
    scroll = 320
    sub = 33.6 if v else 16.8                    # the card subtitle wraps to two lines at 408 px
    field_top = -242 + 338 + 16 + 20 + 21 + 4 + sub + 12          # page px
    save_cy = field_top + 176 + 20 + 16 + 24
    page = ui12.workspace_page("s02-w", g["w"], g["h"], scroll, W["name"], W["description"], 4, 2, "3m ago", HINT_PROMPT)
    inner = f'<div id="s02-win" class="a-win" style="left:{g["left"]:.2f}px;top:{g["top"]}px;width:{g["w"]}px;height:{g["h"]}px">{page}</div>'

    def vid(x, y):
        return ((g["left"] + x) * Z, (g["top"] + y) * Z)
    field = vid(16 + 20 + 20 + 8, field_top + 30)
    save = vid(g["w"] / 2 + (120 if v else 170), save_cy)
    css = f"""
#s02-cam {{ transform-origin: {fmt.cx}px {fmt.H * 0.45:.0f}px; }}
"""
    body = f"""
    <div id="s02-cam" class="fill">
      {ui.appz('s02-z', fmt, Z, inner)}
      {cursor('s02-cur', cs)}
    </div>
"""
    t_click = 1.25
    t_type = 1.55
    t_end = t_type + len(W["prompt"]) / CPS
    js = f"""
  tl.fromTo('#s02-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s02-cur', {{ x: {fmt.W - 160}, y: {fmt.H + 60} }}, {{ x: {field[0]:.0f}, y: {field[1]:.0f}, duration: 0.8, ease: 'power2.inOut' }}, 0.3);
  hfShape(tl, '#s02-cur', 0.95, 'ibeam');
  hfClick(tl, '#s02-cur', {t_click}, 'ibeam');
  tl.to('#s02-w-ring', {{ opacity: 1, duration: 0.08 }}, {t_click + 0.05});
  tl.set('#s02-w-caret0', {{ opacity: 1 }}, {t_click + 0.08});
  // first key: the hint goes, the Save Changes button appears (_hasSettingsChanges)
  tl.set('#s02-w-caret0', {{ opacity: 0 }}, {t_type});
  tl.set('#s02-w-ph', {{ display: 'none' }}, {t_type});
  tl.set('#s02-w-typed', {{ display: 'inline' }}, {t_type});
  tl.set('#s02-w-caret', {{ opacity: 1 }}, {t_type});
  tl.set('#s02-w-save', {{ opacity: 1 }}, {t_type + 1 / CPS:.3f});
  hfShape(tl, '#s02-cur', {t_type + 0.05}, 'arrow');
  tl.to('#s02-cur', {{ x: {field[0] + 120:.0f}, y: {field[1] + 260:.0f}, duration: 0.6, ease: 'power2.out' }}, {t_type + 0.05});
  var e = hfType(tl, document.getElementById('s02-w-typed'), {W['prompt']!r}, {t_type}, {CPS});
  // save
  tl.to('#s02-cur', {{ x: {save[0]:.0f}, y: {save[1]:.0f}, duration: 0.6, ease: 'power2.inOut' }}, e + 0.1);
  hfShape(tl, '#s02-cur', e + 0.62, 'hand');
  hfClick(tl, '#s02-cur', e + 0.8, 'hand');
  tl.to('#s02-w-save', {{ scale: 0.97, backgroundColor: '#7A4FDB', duration: 0.08 }}, e + 0.8);
  tl.to('#s02-w-save', {{ scale: 1, backgroundColor: '{ui12.WS}', duration: 0.12 }}, e + 0.88);
  tl.set('#s02-w-save', {{ opacity: 0 }}, e + 1.05);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: {1.03 if v else 1.025}, duration: {b - a - 0.4:.2f}, ease: 'power1.inOut' }}, 0.4);
"""
    assert t_end + 1.15 < b - a, (t_end, b - a)
    ep.add("s02", a, b, css, body, js)


# =================================================================== s03 memory: one more line
def s03_memory(ep, a, b, v, cs):
    fmt = ep.fmt
    g = win_geom(fmt)
    Z = g["Z"]
    scroll = 0 if v else 20
    info_h = 78.4 if v else 61.6                  # the hint wraps to three lines at 408 px
    field_top = 70 - scroll + 48 + info_h + 12
    save_cy = field_top + 158 + 12 + 48 + 24 + 26
    page = ui12.memory_page("s03-m", g["w"], g["h"], scroll, MEMORY_HINT, M["old"], TYPED_MEM, MEMORY_EXAMPLE)
    inner = f'<div id="s03-win" class="a-win" style="left:{g["left"]:.2f}px;top:{g["top"]}px;width:{g["w"]}px;height:{g["h"]}px">{page}</div>'

    def vid(x, y):
        return ((g["left"] + x) * Z, (g["top"] + y) * Z)
    line2 = M["old"].split("\n")[1]
    end2 = vid(16 + 20 + len(line2) * 8.7 + 6, field_top + 16 + 21 * 1.5)
    save = vid(g["w"] / 2 + (120 if v else 170), save_cy)
    n0 = len(M["old"])
    css = f"""
#s03-cam {{ transform-origin: {fmt.cx}px {fmt.H * 0.4:.0f}px; }}
"""
    body = f"""
    <div id="s03-cam" class="fill">
      {ui.appz('s03-z', fmt, Z, inner)}
      {cursor('s03-cur', cs)}
    </div>
"""
    t_click = 1.05
    t_type = 1.4
    t_end = t_type + len(TYPED_MEM) / CPS
    counts = "".join(
        f"tl.set('#s03-m-cnt{n0 + i}', {{ display: 'none' }}, {t_type + (i + 1) / CPS:.3f});"
        f"tl.set('#s03-m-cnt{n0 + i + 1}', {{ display: 'inline' }}, {t_type + (i + 1) / CPS:.3f});"
        for i in range(len(TYPED_MEM)))
    js = f"""
  tl.fromTo('#s03-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s03-cur', {{ x: {fmt.W - 160}, y: {fmt.H + 60} }}, {{ x: {end2[0]:.0f}, y: {end2[1]:.0f}, duration: 0.75, ease: 'power2.inOut' }}, 0.2);
  hfShape(tl, '#s03-cur', 0.8, 'ibeam');
  hfClick(tl, '#s03-cur', {t_click}, 'ibeam');
  tl.to('#s03-m-ring', {{ opacity: 1, duration: 0.08 }}, {t_click + 0.05});
  tl.set('#s03-m-caret', {{ opacity: 1 }}, {t_click + 0.08});
  hfShape(tl, '#s03-cur', {t_type + 0.05}, 'arrow');
  tl.to('#s03-cur', {{ x: {end2[0] + 260:.0f}, y: {end2[1] + 200:.0f}, duration: 0.6, ease: 'power2.out' }}, {t_type + 0.05});
  var e = hfType(tl, document.getElementById('s03-m-typed'), {TYPED_MEM!r}, {t_type}, {CPS});
  {counts}
  // the first change enables Save changes (_hasAnyChanges)
  tl.set('#s03-m-save', {{ backgroundColor: '@ACC@', color: '@FG@' }}, {t_type + 1 / CPS:.3f});
  tl.to('#s03-cur', {{ x: {save[0]:.0f}, y: {save[1]:.0f}, duration: 0.6, ease: 'power2.inOut' }}, e + 0.12);
  hfShape(tl, '#s03-cur', e + 0.64, 'hand');
  hfClick(tl, '#s03-cur', e + 0.82, 'hand');
  tl.to('#s03-m-save', {{ scale: 0.97, backgroundColor: '#C9684A', duration: 0.08 }}, e + 0.82);
  tl.to('#s03-m-save', {{ scale: 1, duration: 0.12 }}, e + 0.9);
  // saved: nothing changed any more, the button is disabled again
  tl.set('#s03-m-save', {{ backgroundColor: 'rgba(232,228,216,0.12)', color: 'rgba(232,228,216,0.38)' }}, e + 1.15);
  tl.fromTo('#s03-cam', {{ scale: 1 }}, {{ scale: {1.03 if v else 1.025}, duration: {b - a - 0.4:.2f}, ease: 'power1.inOut' }}, 0.4);
"""
    assert t_end + 1.3 < b - a, (t_end, b - a)
    ep.add("s03", a, b, css, body, js)


# =================================================================== server-side helpers
def big_table_css(cid):
    """08's table editor, type raised to 30 px (16:9 floor for table text)."""
    return f"""
#{cid} .sb-td, #{cid} .sb-th, #{cid} .sb-th span, #{cid} .sb-btn, #{cid} .sb-tag {{ font-size: 30px; }}
#{cid} .sb-th span {{ color: #889096; }}
#{cid} .sb-name {{ font-size: 36px; }}
#{cid} .sb-td {{ font-family: 'ChukMono', 'ChukEmoji', monospace; font-variant-ligatures: none; }}
"""


def viewer_css(cid, v):
    if not v:
        return f"#{cid} .ex-bar, #{cid} .ex-bar .sb-tag, #{cid} .ex-bar span {{ font-size: 30px !important; }}\n"
    return f"""
#{cid} .ex-body {{ font-size: 34px; line-height: 50px; padding: 26px 36px 30px; }}
#{cid} .ex-bar, #{cid} .ex-bar .sb-tag, #{cid} .ex-bar span {{ font-size: 34px !important; }}
#{cid} .ex-bar {{ height: 92px; }}
"""


def serif_lines(cid, lines, top, size, color="@INK@"):
    lh = round(size * 1.1)
    return "".join(f'<div class="card-line serif" id="{cid}-l{i}" style="top:{top + i * lh}px;font-size:{size}px;'
                   f'line-height:{lh}px;color:{color}">{esc(t)}</div>' for i, t in enumerate(lines))


NUL = '<span class="nul">NULL</span>'
LOCK = '<span class="emo">🔒</span>'


# =================================================================== s05 the projects row
def s05_projects(ep, a, b, v, cs):
    fmt = ep.fmt
    me = WS_ROWS[0]
    if v:
        cid = "s05-rp"
        em = me["text"]
        em_show = esc(em[:44 * 3 - 1]) + "…"
        card = ui12.record_panel(cid, "projects", "row " + mask_uuid_short(me["id"]), [
            ("name", "text", LOCK), ("description", "text", NUL), ("custom_system_prompt", "text", NUL),
            ("encrypted_meta", "text", em_show)], 40, 250, 1000, ui.SVG["table"])
        target = (40 + 300, 250 + 92 + 150 * 3 + 22 + 44 + 10 + 60)
        ex = dict(left=40, top=250, width=1000, ct=130)
        lines, ltop, lsize = ["Placeholders", "and ciphertext."], 1180, 100
        sel = ""
        tcss = f"#{cid} .sb-name {{ font-size: 40px; }} #{cid} .sb-tag {{ font-size: 34px; }} #{cid} .sb-bar {{ height: 92px; }}"
    else:
        cid = "s05-tb"
        cols = [("name", "text", 210), ("description", "text", 280), ("custom_system_prompt", "text", 450),
                ("encrypted_meta", "text", 720)]
        rows = [[LOCK, NUL, NUL, esc(r["text"][:44])] for r in WS_ROWS]
        left, top = 97, 250
        card = ui.db_table(cid, "projects", "public", cols, rows, mine=0, left=left, top=top)
        cx = left + 64 + 210 + 280 + 450
        sel = f'<div class="sb-sel" id="s05-sel" style="left:{cx}px;top:{top + 92 + 72}px;width:722px;height:80px"></div>'
        target = (cx + 330, top + 92 + 72 + 46)
        ex = dict(left=160, top=120, width=1600, ct=200)
        lines, ltop, lsize = ["Placeholders and ciphertext."], 800, 96
        tcss = big_table_css(cid)
    more = f"+ {len(me['envelope']['ciphertext']) - ex['ct']:,} more characters"
    # the bar names the row by its id: the database has no readable name for it
    viewer = ui.envelope_viewer("s05-ex", "encrypted_meta", "text", "id " + mask_uuid_short(me["id"]),
                                me["envelope"], ex["left"], ex["top"], ex["width"], ct_chars=ex["ct"], more=more, icon="key")
    if v:  # the tag already says "text"; keep the bar short
        viewer = ui.envelope_viewer("s05-ex", "encrypted_meta", "text", "", me["envelope"], ex["left"], ex["top"],
                                    ex["width"], ct_chars=ex["ct"], more=more, icon="key")
    css = f"""
{tcss}
{viewer_css('s05-ex', v)}
#s05-ex {{ opacity: 0; }}
"""
    body = f"""
    <div id="s05-tw" class="fill">{card}{sel}</div>
    {viewer}
    {serif_lines('s05', lines, ltop, lsize)}
    {cursor('s05-cur', cs)}
"""
    rowsel = f"#{cid}-r0" if not v else f"#{cid}-v3"
    js = f"""
  tl.fromTo('#{cid}', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#{cid} {".sb-tr" if not v else ".rp-f"}', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, stagger: 0.07 }}, 0.1);
  tl.fromTo('#s05-cur', {{ x: {fmt.W - 200}, y: {fmt.H + 60} }}, {{ x: {target[0]:.0f}, y: {target[1]:.0f}, duration: 0.8, ease: 'power2.inOut' }}, 0.35);
  tl.to('{rowsel}', {{ backgroundColor: {'"#F1F3F5"' if not v else '"#EEF0F3"'}, duration: 0.15 }}, 1.05);
  hfClick(tl, '#s05-cur', 1.2);
  {"tl.to('#s05-sel', { opacity: 1, duration: 0.08 }, 1.25);" if not v else ""}
  hfClick(tl, '#s05-cur', 1.42);
  tl.to('#s05-cur', {{ x: {fmt.W - 120}, y: {fmt.H + 80}, duration: 0.55, ease: 'power3.in' }}, 1.6);
  tl.to('#s05-tw', {{ opacity: 0, y: -40, duration: 0.3, ease: 'power2.in' }}, 1.6);
  tl.fromTo('#s05-ex', {{ opacity: 0, scale: 0.94, y: 60 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 1.7);
  tl.fromTo('#s05-ex-b .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.18, stagger: 0.07 }}, 1.82);
  tl.fromTo('#s05-ex', {{ y: 0 }}, {{ y: -12, duration: {b - a - 2.3:.2f}, ease: 'none', immediateRender: false }}, 2.3);
  {''.join(f"hfReveal(tl, '#s05-l{i}', {2.45 + i * 0.35:.2f}, 0.08);" for i in range(len(lines)))}
"""
    ep.add("s05", a, b, css, body, js)


# =================================================================== s06 the memory row
def s06_prefs(ep, a, b, v, cs):
    fmt = ep.fmt
    me = PREFS[0]
    if v:
        cid = "s06-rp"
        card = ui12.record_panel(cid, "user_preferences", "row", [
            ("user_id", "uuid", esc(mask_uuid_short(me["user_id"]))),
            ("identity_memory", "text", esc(me["text"])),
            ("updated_at", "timestamptz", esc(me["updated_at"]))], 40, 270, 1000, ui.SVG["table"])
        lines, ltop, lsize = ["Your memory,", "too."], 1230, 104
        css = f"#{cid} .sb-name {{ font-size: 40px; }} #{cid} .sb-tag {{ font-size: 34px; }} #{cid} .sb-bar {{ height: 92px; }}"
        body = f"""
    {card}
    {serif_lines('s06', lines, ltop, lsize)}
"""
        js = f"""
  tl.fromTo('#{cid}', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#{cid} .rp-f', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, stagger: 0.08 }}, 0.1);
  tl.fromTo('#{cid}-v1', {{ backgroundColor: '#F8F9FA' }}, {{ backgroundColor: '#EEF0F3', duration: 0.3 }}, 0.9);
  tl.fromTo('#{cid}', {{ y: 0 }}, {{ y: -12, duration: {b - a - 0.6:.2f}, ease: 'none', immediateRender: false }}, 0.6);
  {''.join(f"hfReveal(tl, '#s06-l{i}', {1.3 + i * 0.35:.2f});" for i in range(len(lines)))}
"""
        ep.add("s06", a, b, css, body, js)
        return
    cid = "s06-tb"
    cols = [("user_id", "uuid", 300), ("identity_memory", "text", 860), ("updated_at", "timestamptz", 500)]
    rows = [[esc(mask_uuid_short(r["user_id"])), esc(r["text"][:44]), esc(r["updated_at"])] for r in PREFS]
    left, top = 97, 250
    card = ui.db_table(cid, "user_preferences", "public", cols, rows, mine=0, left=left, top=top)
    cx = left + 64 + 300
    sel = f'<div class="sb-sel" id="s06-sel" style="left:{cx}px;top:{top + 92 + 72}px;width:862px;height:80px"></div>'
    target = (cx + 420, top + 92 + 72 + 46)
    viewer = ui.envelope_viewer("s06-ex", "identity_memory", "text", f"{len(me['text'])} characters",
                                me["envelope"], 160, 150, 1600, icon="key")
    lines, ltop, lsize = ["Your memory, too."], 790, 96
    css = f"""
{big_table_css(cid)}
{viewer_css('s06-ex', v)}
#s06-ex {{ opacity: 0; }}
"""
    body = f"""
    <div id="s06-tw" class="fill">{card}{sel}</div>
    {viewer}
    {serif_lines('s06', lines, ltop, lsize)}
    {cursor('s06-cur', cs)}
"""
    js = f"""
  tl.fromTo('#{cid}', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#{cid} .sb-tr', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, stagger: 0.07 }}, 0.1);
  tl.fromTo('#s06-cur', {{ x: {fmt.W - 200}, y: {fmt.H + 60} }}, {{ x: {target[0]:.0f}, y: {target[1]:.0f}, duration: 0.7, ease: 'power2.inOut' }}, 0.3);
  tl.to('#{cid}-r0', {{ backgroundColor: '#F1F3F5', duration: 0.15 }}, 0.9);
  hfClick(tl, '#s06-cur', 1.0);
  tl.to('#s06-sel', {{ opacity: 1, duration: 0.08 }}, 1.05);
  hfClick(tl, '#s06-cur', 1.22);
  tl.to('#s06-cur', {{ x: {fmt.W - 120}, y: {fmt.H + 80}, duration: 0.5, ease: 'power3.in' }}, 1.4);
  tl.to('#s06-tw', {{ opacity: 0, y: -40, duration: 0.3, ease: 'power2.in' }}, 1.4);
  tl.fromTo('#s06-ex', {{ opacity: 0, scale: 0.94, y: 60 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 1.5);
  tl.fromTo('#s06-ex-b .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.18, stagger: 0.07 }}, 1.6);
  tl.fromTo('#s06-ex', {{ y: 0 }}, {{ y: -12, duration: {b - a - 2.1:.2f}, ease: 'none', immediateRender: false }}, 2.1);
  {''.join(f"hfReveal(tl, '#s06-l{i}', {2.2 + i * 0.35:.2f}, 0.08);" for i in range(len(lines)))}
"""
    ep.add("s06", a, b, css, body, js)


# =================================================================== s07 colour block: the memory becomes ciphertext
def s07_block(ep, a, b, v):
    fmt = ep.fmt
    ct = PREFS[0]["envelope"]["ciphertext"]
    fs, lhc, pad = 40, 58, 36
    if v:
        bw, bx, by = 860, 110, 380
        lines, lsize, ltop = ["Encrypted on", "your device.", "Then stored."], 108, 880
    else:
        bw, bx, by = 760, 580, 160
        lines, lsize, ltop = ["Encrypted on your device.", "Then stored."], 96, 640
    cols = int((bw - 2 * pad) / (fs * 0.6))
    rows = [ct[i:i + cols] for i in range(0, len(ct), cols)]
    start = M["text"].split("\n") + [""] * max(0, len(rows) - 3)
    n = max(len(rows), len(start))
    rows += [""] * (n - len(rows))
    start = [s.ljust(cols) for s in start]
    rows = [r.ljust(cols) for r in rows]
    bh = 2 * pad + n * lhc
    lock = 104 if v else 92
    lh = round(lsize * 1.12)
    ldivs = "".join(f'<div class="card-line serif" id="s07-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;'
                    f'line-height:{lh}px;color:@CANVAS@">{esc(t)}</div>' for i, t in enumerate(lines))
    rows_html = "".join(f'<div class="s07-row" id="s07-r{i}"></div>' for i in range(n))
    css = f"""
#s07-bg {{ background: @BROWN@; }}
#s07-all {{ transform-origin: {fmt.cx}px {by + bh / 2}px; }}
#s07-box {{ position: absolute; left: {bx}px; top: {by}px; width: {bw}px; height: {bh}px; padding: {pad}px; border-radius: 16px;
  background: #46302A; border: 2px solid rgba(244,238,228,0.3); font-family: 'ChukMono', monospace; font-size: {fs}px;
  line-height: {lhc}px; color: @CANVAS@; font-variant-ligatures: none; }}
.s07-row {{ white-space: pre; height: {lhc}px; overflow: hidden; }}
#s07-lock {{ position: absolute; left: {bx + bw - lock * 0.62:.0f}px; top: {by + bh - lock * 0.62:.0f}px; width: {lock}px; height: {lock}px;
  border-radius: 50%; background: @CANVAS@; color: @BROWN@; display: flex; align-items: center; justify-content: center; }}
"""
    body = f"""
    <div id="s07-bg" class="fill"></div>
    <div id="s07-all" class="fill">
      <div id="s07-box">{rows_html}</div>
      <div id="s07-lock">{hi('h-lock', lock * 0.58)}</div>
      {ldivs}
    </div>
"""
    js = f"""
  var A = {json.dumps(start)}, B = {json.dumps(rows)};
  var pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var els = B.map(function (_, i) {{ return document.getElementById('s07-r' + i); }});
  function render(t) {{
    els.forEach(function (el, i) {{
      var s = '';
      for (var j = 0; j < B[i].length; j++) {{
        var tj = i * 0.12 + j * 0.016;
        if (t < tj) s += A[i][j];
        else if (t < tj + 0.28) s += pool[Math.floor(hfHash(i * 131 + j, Math.floor(t * 30)) * pool.length)];
        else s += B[i][j];
      }}
      if (el.textContent !== s) el.textContent = s;
    }});
  }}
  var prox = {{ t: 0 }};
  render(0);
  tl.fromTo('#s07-all', {{ scale: 1.0 }}, {{ scale: 1.04, duration: {b - a:.2f}, ease: 'none' }}, 0);
  tl.fromTo('#s07-box', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.4, ease: 'expo.out' }}, 0);
  tl.fromTo(prox, {{ t: 0 }}, {{ t: 1.6, duration: 1.6, ease: 'none', onUpdate: function () {{ render(prox.t); }} }}, 0.35);
  tl.fromTo('#s07-lock', {{ opacity: 0, y: 30, scale: 0.7 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.45, ease: 'back.out(1.5)' }}, 1.35);
  {''.join(f"hfReveal(tl, '#s07-l{i}', {1.0 + i * 0.35:.2f});" for i in range(len(lines)))}
"""
    ep.add("s07", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-12-memory")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-12-memory-vertical")
