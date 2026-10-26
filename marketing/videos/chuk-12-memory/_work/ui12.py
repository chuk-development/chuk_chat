"""Episode-only app pieces for 12 "memory", rebuilt 1:1 from the Flutter widgets.

Sources (values measured on the real widget renders in fidelity/real-*.png, made by
fidelity_test/real_widgets_test.dart, and read from the theme, fidelity/theme-values.txt):
* FloatingAppBar (lib/widgets/floating_app_bar.dart): 62 px band, back chip 42 at (10,10),
  title pill at x 60 (radius 18, padding 16/11, 15 px w800, iconFg .92), page-colour scrim
  (stops 0, .72, 1), optional TabBar below (48 px, label = titleSmall 14 w500,
  unselected onSurfaceVariant, divider outlineVariant 1 px, indicator 3 px label width).
* workspace_detail_page.dart _buildSettingsTab: Card (radius 16, #363634, padding 20),
  identity row (avatar 48 r14, displayColor .2), labels 13 w600 iconFg .7 (line 19),
  TextFormField (fill #2E2E2C, radius 16, no border, focused 2 px accent, text bodyLarge
  16 / 24 ls .5, padding 16 v / 20 h), Custom System Prompt card, Save Changes
  (FilledButton, displayColor, white, save glyph 18).
* system_prompt_page.dart Memory section: ExpressiveSectionHeader (titleMedium 16 w700
  primary, padding 6/16/6/8), ExpressiveInfoCard (#2E2E2C r26, padding 16/14, info 18,
  bodySmall 12 h1.4 onSurfaceVariant), _MaterialTextField (JetBrains Mono 14 h1.5 ls .3,
  fill #2E2E2C, 1 px outlineVariant, r16, focused 2 px primary, expand chip 32 #41413E),
  OutlinedButton "Import from another AI", "N characters", Save changes (52, accent).
* Server side, 9:16 only: record_panel(), the Supabase row editor side panel in the
  light look of 08's table editor (same card, colours and type), each column a label
  over its value.
Displayed colour tokens of the Clawed dark theme (contrast .55): bg #262624, fg #E8E4D8,
accent #D97757, workspace colour #8B5CF6 (Workspace.displayColor of "Tax helper").
"""
import json
from pathlib import Path

from chukvid.core import esc

HERE = Path(__file__).resolve().parent
_ICONS = json.loads((HERE / "gen/icons.json").read_text())

WS = "#8B5CF6"                  # Workspace("Tax helper").displayColor (kWorkspaceColors[1])
WS20 = "rgba(139,92,246,0.2)"   # displayColor.withValues(alpha: 0.2) (dark)


def ic(name, size, color="currentColor", style=""):
    """AppIcon: HugeIcons draw at 0.86 of the box (huge_icon.dart _opticalInset); a
    Material fallback glyph fills its box like Icon."""
    d = _ICONS[name]
    px = size * (0.86 if d["kind"] == "huge" else 1.0)
    return (f'<span class="w-ic" style="width:{size}px;height:{size}px;color:{color};{style}">'
            f'<svg viewBox="{d["viewBox"]}" fill="none" style="width:{px:.2f}px;height:{px:.2f}px">'
            f'{d["inner"]}</svg></span>')


CSS = """
@font-face { font-family: 'ChukEmoji'; src: url('assets/fonts/lock-emoji.ttf') format('truetype'); }
.w-page { position: absolute; left: 0; top: 0; overflow: hidden; background: @BG@; color: @FG@; font-family: 'Ubuntu', sans-serif;
  font-size: 14px; line-height: 1.4; letter-spacing: 0.3px; }
.w-ic { display: inline-flex; align-items: center; justify-content: center; flex: none; }
.w-ic svg { display: block; }
.w-scroll { position: absolute; left: 0; right: 0; top: 0; }
.w-scrim { position: absolute; left: 0; right: 0; top: 0; background: linear-gradient(@BG@ 0%, @BG@ 72%, rgba(38,38,36,0) 100%); }
.w-chip { position: absolute; left: 10px; top: 10px; width: 42px; height: 42px; border-radius: 50%; background: #31312F;
  display: flex; align-items: center; justify-content: center; color: @FG@; }
.w-pill { position: absolute; left: 60px; display: flex; align-items: center; gap: 10px; padding: 11px 16px; border-radius: 18px;
  background: #31312F; font-size: 15px; font-weight: 800; line-height: 17.6px; letter-spacing: 0; color: rgba(232,228,216,0.92); white-space: nowrap; }
.w-pico { width: 30px; height: 30px; border-radius: 8px; background: rgba(139,92,246,0.2); display: flex; align-items: center; justify-content: center; }
.w-tabs { position: absolute; left: 0; right: 0; top: 62px; height: 48px; display: flex; }
.w-tab { position: relative; flex: 1; display: flex; align-items: center; justify-content: center; }
.w-tabl { position: relative; display: flex; align-items: center; height: 46px; font-size: 14px; font-weight: 500; letter-spacing: 0.1px;
  color: rgba(232,228,216,0.86); white-space: nowrap; }
.w-tabl .w-ic { margin-right: 6px; color: @FG@; }
.w-tab.on .w-tabl, .w-tab.on .w-tabl .w-ic { color: #8B5CF6; }
.w-badge { margin-left: 6px; padding: 1px 6px; border-radius: 10px; background: rgba(139,92,246,0.15); color: #8B5CF6; font-size: 11px;
  font-weight: 600; line-height: 1.4; letter-spacing: 0; }
.w-ind { position: absolute; left: 0; right: 0; bottom: -1px; height: 3px; border-radius: 3px 3px 0 0; background: #8B5CF6; }
.w-div { position: absolute; left: 0; right: 0; top: 109px; height: 1px; background: rgba(232,228,216,0.26); }
.w-content { position: absolute; left: 16px; right: 16px; }
.w-card { position: relative; background: #363634; border-radius: 16px; padding: 20px; }
.w-card + .w-card { margin-top: 16px; }
.w-row { display: flex; align-items: center; }
.w-av { width: 48px; height: 48px; border-radius: 14px; background: rgba(139,92,246,0.2); display: flex; align-items: center; justify-content: center; margin-right: 16px; }
.w-stat { font-size: 14px; font-weight: 500; line-height: 19.6px; color: @FG@; }
.w-upd { margin-top: 2px; font-size: 12px; line-height: 16.8px; letter-spacing: 0.1px; color: rgba(232,228,216,0.5); }
.w-lbl { font-size: 13px; font-weight: 600; line-height: 19px; color: rgba(232,228,216,0.7); }
.w-f { position: relative; background: #2E2E2C; border-radius: 16px; padding: 16px 20px; font-size: 16px; line-height: 24px; letter-spacing: 0.5px;
  color: @FG@; white-space: pre-wrap; word-break: normal; }
.w-ring { position: absolute; inset: 0; border-radius: 16px; box-shadow: inset 0 0 0 2px @ACC@; opacity: 0; }
.w-hint { color: rgba(232,228,216,0.861); font-size: 15px; letter-spacing: 0.3px; }
.w-caret { display: inline-block; width: 2px; height: 1.15em; background: @ACC@; vertical-align: -0.2em; margin-left: 0; }
.w-caret.abs { position: absolute; left: 20px; top: 18px; height: 20px; }
.w-ctitle { font-size: 15px; font-weight: 600; line-height: 21px; letter-spacing: 0.1px; color: @FG@; }
.w-csub { margin-top: 4px; font-size: 12px; line-height: 16.8px; letter-spacing: 0.1px; color: rgba(232,228,216,0.5); }
.w-btn { display: flex; align-items: center; justify-content: center; gap: 8px; border-radius: 999px; font-size: 14px; font-weight: 600;
  letter-spacing: 0.1px; white-space: nowrap; }
.w-save { margin-top: 16px; height: 48px; background: #8B5CF6; color: #FFFFFF; }
/* memory page */
.w-sec { padding: 16px 6px 8px; font-size: 16px; font-weight: 700; line-height: 24px; letter-spacing: 0.1px; color: @ACC@; }
.w-info { display: flex; align-items: flex-start; gap: 12px; padding: 14px 16px; border-radius: 26px; background: #2E2E2C;
  font-size: 12px; line-height: 16.8px; letter-spacing: 0.2px; color: rgba(232,228,216,0.86); }
.w-info .w-ic { color: rgba(232,228,216,0.86); }
.w-mf { position: relative; margin-top: 12px; min-height: 158px; background: #2E2E2C; border-radius: 16px; padding: 16px 20px;
  box-shadow: inset 0 0 0 1px rgba(232,228,216,0.26); font-family: 'ChukMono', monospace; font-size: 14px; line-height: 21px;
  letter-spacing: 0.3px; color: @FG@; white-space: pre-wrap; font-variant-ligatures: contextual; }
.w-full { position: absolute; top: 6px; right: 6px; width: 32px; height: 32px; border-radius: 50%; background: #41413E;
  display: flex; align-items: center; justify-content: center; }
.w-mrow { display: flex; align-items: center; margin-top: 12px; }
.w-out { height: 48px; padding: 0 18px; box-shadow: inset 0 0 0 1px rgba(232,228,216,0.576); color: @FG@; }
.w-count { margin-left: 12px; font-size: 12px; line-height: 16.8px; letter-spacing: 0.4px; color: rgba(232,228,216,0.86); white-space: nowrap; }
.w-msave { margin-top: 24px; height: 52px; font-size: 15px; background: rgba(232,228,216,0.12); color: rgba(232,228,216,0.38); }
.w-msave.on { background: @ACC@; color: @FG@; }
/* server side: row editor panel (9:16) */
.rp-f { padding: 22px 32px 0; }
.rp-l { display: flex; align-items: baseline; gap: 14px; font-size: 34px; line-height: 44px; color: #11181C; white-space: nowrap; }
.rp-l b { font-weight: 600; }
.rp-l span { color: #889096; }
.rp-v { margin-top: 10px; padding: 12px 18px; border: 1px solid #DFE3E8; border-radius: 10px; background: #F8F9FA; font-family: 'ChukMono', 'ChukEmoji', monospace;
  font-size: 34px; line-height: 48px; color: #11181C; font-variant-ligatures: none; white-space: pre-wrap; word-break: break-all; }
.rp-null { color: #889096; }
.rp-last { padding-bottom: 28px; }
.emo { font-family: 'ChukEmoji'; }
"""


def header(title, icon=None, tabs=None, sel=None):
    """FloatingAppBar (+ TabBar). tabs: [(icon, label, badge or None)]."""
    h = 110 if tabs else 62
    pico = f'<span class="w-pico">{ic(icon, 16, WS)}</span>' if icon else ""
    pill_h = 52 if icon else 39.6
    out = [f'<div class="w-scrim" style="height:{h}px"></div>',
           f'<div class="w-chip">{ic("arrow-left02", 22)}</div>',
           f'<div class="w-pill" style="top:{31 - pill_h / 2:.1f}px">{pico}<span>{esc(title)}</span></div>']
    if tabs:
        ts = []
        for i, (tic, lab, badge) in enumerate(tabs):
            on = " on" if i == sel else ""
            b = f'<span class="w-badge">{badge}</span>' if badge else ""
            ind = '<span class="w-ind"></span>' if i == sel else ""
            ts.append(f'<div class="w-tab{on}"><div class="w-tabl">{ic(tic, 18)}<span>{esc(lab)}</span>{b}{ind}</div></div>')
        out.append(f'<div class="w-div"></div><div class="w-tabs">{"".join(ts)}</div>')
    return "".join(out)


def workspace_page(pid, width, height, scroll, name, desc, chats, files, updated, hint):
    """workspace_detail_page.dart, Settings tab. Ids: {pid}-pf (prompt field), -ph (hint),
    -typed, -caret, -save (Save Changes, hidden until a change)."""
    content = f"""
<div class="w-content" data-layout-allow-overlap id="{pid}-c" style="top:{78 - scroll}px">
  <div class="w-card">
    <div class="w-row"><span class="w-av">{ic('m-rocket-launch-outlined', 24, WS)}</span>
      <div><div class="w-stat">{chats} chats, {files} files</div><div class="w-upd">Updated {esc(updated)}</div></div></div>
    <div class="w-lbl" style="margin-top:20px">Workspace Name</div>
    <div class="w-f" style="margin-top:8px;height:56px">{esc(name)}</div>
    <div class="w-lbl" style="margin-top:16px">Description</div>
    <div class="w-f" style="margin-top:8px;height:104px">{esc(desc)}</div>
  </div>
  <div class="w-card">
    <div class="w-row">{ic('settings02', 20, WS, 'margin-right:8px')}<span class="w-ctitle">Custom System Prompt</span></div>
    <div class="w-csub">These instructions are sent to the AI at the start of every chat in this workspace.</div>
    <div class="w-f" id="{pid}-pf" style="margin-top:12px;height:176px"><span class="w-ring" id="{pid}-ring"></span><span class="w-caret abs" id="{pid}-caret0" style="opacity:0"></span><span class="w-hint" id="{pid}-ph">{esc(hint)}</span><span id="{pid}-typed" style="display:none"></span><span class="w-caret" id="{pid}-caret" style="opacity:0"></span></div>
  </div>
  <div class="w-btn w-save" id="{pid}-save" style="opacity:0">{ic('m-save', 18)}<span>Save Changes</span></div>
</div>"""
    tabs = [("file01", "Files", files), ("message01", "Chats", chats), ("settings01", "Settings", None)]
    return (f'<div class="w-page" id="{pid}" style="width:{width}px;height:{height}px">{content}'
            f'{header(name, "m-rocket-launch-outlined", tabs, 2)}</div>')


def memory_page(pid, width, height, scroll, hint_text, old, new, hint_example):
    """system_prompt_page.dart, the Memory section. Ids: {pid}-mf (field), -typed, -caret,
    -cnt{n} (one span per character count), -save."""
    counts = "".join(f'<span id="{pid}-cnt{n}" style="display:{"inline" if n == len(old) else "none"}">{n} characters</span>'
                     for n in range(len(old), len(old) + len(new) + 1))
    content = f"""
<div class="w-content" data-layout-allow-overlap id="{pid}-c" style="top:{70 - scroll}px">
  <div class="w-sec">Memory</div>
  <div class="w-info">{ic('information-circle', 18)}<span>{esc(hint_text)}</span></div>
  <div class="w-mf" id="{pid}-mf"><span class="w-ring" id="{pid}-ring"></span><span>{esc(old)}</span><span id="{pid}-typed"></span><span class="w-caret" id="{pid}-caret" style="opacity:0"></span><span class="w-full">{ic('m-open-in-full-rounded', 16, 'rgba(232,228,216,0.86)')}</span></div>
  <div class="w-mrow"><span class="w-btn w-out">{ic('m-download-outlined', 18)}<span>Import from another AI</span></span><span class="w-count">{counts}</span></div>
  <div class="w-btn w-msave" id="{pid}-save">{ic('tick02', 20)}<span>Save changes</span></div>
</div>"""
    return (f'<div class="w-page" id="{pid}" style="width:{width}px;height:{height}px">{content}'
            f'{header("AI Identity & Memory")}</div>')


def record_panel(id_, table, row_label, fields, left, top, width, icon_svg):
    """Supabase row editor side panel (light). fields: [(name, type, value_html)]."""
    fs = []
    for i, (n, t, v) in enumerate(fields):
        last = " rp-last" if i == len(fields) - 1 else ""
        fs.append(f'<div class="rp-f{last}" id="{id_}-f{i}"><div class="rp-l"><b>{esc(n)}</b><span>{esc(t)}</span></div>'
                  f'<div class="rp-v" id="{id_}-v{i}">{v}</div></div>')
    return (f'<div class="sb-card" id="{id_}" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="sb-bar">{icon_svg}<span class="sb-name">{esc(table)}</span><span class="sb-tag">{esc(row_label)}</span></div>'
            f'{"".join(fs)}</div>')
