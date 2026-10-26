"""The real Chuk Chat UI, rebuilt 1:1, plus the light "server side" looks.

App pieces are written in app CSS px (what Flutter calls logical px) inside a wrapper
with CSS `zoom` (see appz()). Values are measured on assets/screenshots/*.webp (1.75
screenshot px per app px) or read from the widget code in lib/ (named per piece).

Every function returns HTML; the classes live in APP_CSS / SB_CSS / ST_CSS, which an
Episode adds to every scene (Episode(..., extra_css=ui.ALL_CSS)).
"""
from .core import T, esc, hi

# ------------------------------------------------------------------ app CSS (from 08 + new pieces)
APP_CSS = """
.appz { position: absolute; left: 0; top: 0; transform-origin: 0 0; }
.a-win { position: absolute; background: @BG@; border-radius: 18px; box-shadow: 0 0 0 1px rgba(255,255,255,0.07), 0 24px 60px -24px rgba(0,0,0,0.45); overflow: hidden; }
.a-vars { --fg: @FG@; --fg85: rgba(232,228,216,0.85); --fg70: rgba(232,228,216,0.7); --fg55: rgba(232,228,216,0.55);
  --fg30: rgba(232,228,216,0.3); --fg15: rgba(232,228,216,0.15); --bg: @BG@; --acc: @ACC@; --bubble: @BUBBLE@;
  color: var(--fg); font-family: 'Ubuntu', sans-serif; font-size: 14px; line-height: 1.4; }
.a-composer { position: absolute; display: flex; flex-direction: column; justify-content: space-between;
  min-height: 135px; padding: 14px; border: 2px solid @LINE@; border-radius: 30px; background: var(--bg); }
.a-field { position: relative; min-height: 40px; margin-left: -1px; padding: 4px 58px 0 0; font-size: 17px; font-weight: 600; line-height: 1.4; white-space: nowrap; }
.a-ph { color: rgba(232,228,216,0.8); }
.a-typed { color: var(--fg); }
.a-caret0 { position: absolute; left: -1px; top: 3px; width: 2px; height: 1.3em; background: var(--acc); }
.a-caret { display: inline-block; width: 2px; height: 1.2em; background: var(--acc); vertical-align: -0.22em; }
.a-send { position: absolute; top: 14px; right: 14px; width: 44px; height: 36px; border-radius: 20px; background: var(--acc); color: #fff; display: flex; align-items: center; justify-content: center; }
.a-send svg { transform: scaleY(0.95); }
.a-row { display: flex; align-items: center; gap: 8px; }
.a-grow { flex: 1; }
.a-btn { width: 44px; height: 36px; border: 2px solid @LINE@; border-radius: 18px; display: inline-flex; align-items: center; justify-content: center; color: var(--fg); }
.a-pill { height: 36px; padding: 0 11px; border: 2px solid @LINE@; border-radius: 18px; display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 600; color: var(--fg); white-space: nowrap; }
.a-dn { margin-left: -3px; color: var(--fg70); }
.a-disc { position: absolute; left: 0; right: 0; font-size: 11.5px; color: var(--fg70); text-align: center; white-space: nowrap; }
.a-col { position: absolute; }
.a-user { display: flex; flex-direction: column; align-items: flex-end; }
.a-bubble { max-width: 80%; padding: 10px 14px; border: 1px solid var(--fg30); border-radius: 16px; background: var(--bubble); color: var(--fg);
  font-family: 'ChukMono', monospace; font-size: 16.4px; font-weight: 400; line-height: 1.38; white-space: nowrap; margin: 0; }
.a-bubble.wrap { white-space: normal; }
.a-ai { margin-top: 8px; font-family: 'ChukMono', monospace; font-size: 16.4px; font-weight: 400; line-height: 1.45; color: var(--fg); }
.a-ai p { margin: 0 0 8px; }
.a-tl { margin-top: 14px; font-family: 'Ubuntu', sans-serif; }
.a-tl-head { display: inline-flex; align-items: center; gap: 4px; margin: 0; padding: 4px 2px; font-size: 12.7px; font-weight: 500; color: var(--fg55); }
.a-steps { position: relative; padding-top: 4px; }
.a-steps-line { position: absolute; left: 13px; top: 17px; bottom: 15px; width: 1px; background: var(--fg15); }
.a-step { position: relative; display: flex; align-items: center; gap: 10px; min-height: 26px; margin-bottom: 8px; font-size: 12.7px; color: var(--fg55); white-space: nowrap; }
.a-badge { flex: none; width: 26px; height: 26px; border-radius: 50%; border: 1px solid var(--fg15); background: var(--bg); display: flex; align-items: center; justify-content: center; color: var(--fg55); }
.a-step b { margin-left: 0.6em; font-weight: 500; color: var(--fg85); }
.a-srcs { display: flex; align-items: center; gap: 6px; height: 30px; margin: -4px 0 8px 36px; }
.a-src { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 8px; border-radius: 15px; background: rgba(232,228,216,0.06); font-size: 12.7px; color: var(--fg70); white-space: nowrap; }
.a-fav { flex: none; width: 16px; height: 16px; border-radius: 3px; display: block; }

/* attachment bar in the composer: lib/widgets/attachment_preview_bar.dart (_ImageAttachmentCard,
   _RemoveButton) placed by chat_ui_desktop.dart _buildSearchBar: padding bottom 14, left 2, right 44+8 */
.a-att { display: flex; padding: 2px 0; margin: 0 52px 14px 2px; }
.a-attc { flex: none; width: 72px; height: 72px; padding: 2px; border-radius: 16px; margin-right: 8px;
  background: linear-gradient(135deg, rgba(217,119,87,0.6), rgba(217,119,87,0.1)); }
.a-atti { position: relative; width: 68px; height: 68px; border-radius: 14px; overflow: hidden; }
/* Image.memory(cacheWidth: 144, cacheHeight: 144) decodes the photo squashed to a square
   before BoxFit.cover, so the whole photo shows, distorted: object-fit fill is the match */
.a-atti img { display: block; width: 100%; height: 100%; object-fit: fill; }
.a-attb { position: absolute; left: 4px; bottom: 4px; padding: 2px 5px; border-radius: 6px; background: rgba(0,0,0,0.6);
  color: @BG@; font-size: 10px; font-weight: 600; line-height: 12px; white-space: nowrap; }
.a-attx { position: absolute; top: 3px; right: 3px; width: 24px; height: 24px; border-radius: 50%; background: #31312F;
  border: 1px solid rgba(232,228,216,0.16); display: flex; align-items: center; justify-content: center; color: var(--fg); }

/* user image above the bubble: message_bubble/images.dart _buildImagesGrid (desktop user square
   (maxWidth*0.45).clamp(200,320), radius 12, cover, no frame); layout.dart: SizedBox 2 + bubble
   margin-top 10 (_runGapAbove of a new group) */
.a-uimg { width: 260px; height: 260px; border-radius: 12px; overflow: hidden; }
.a-uimg img { display: block; width: 100%; height: 100%; object-fit: cover; }
.a-uimg + .a-bubble { margin-top: 12px; }

/* drag-and-drop overlay: chat_ui_desktop.dart _isDraggingFiles (accent 10 % tint, card bg,
   radius 16, 2 px accent border, padding 24/32, cloud_upload 32 accent, gap 16, 18 px w600) */
.a-drop { position: absolute; inset: 0; background: rgba(217,119,87,0.1); }
.a-dropr { position: absolute; left: 0; right: 0; top: 0; display: flex; align-items: center; justify-content: center; }
.a-dropc { display: flex; align-items: center; gap: 16px; padding: 24px 32px; background: var(--bg); border: 2px solid var(--acc);
  border-radius: 16px; font-size: 18px; font-weight: 600; letter-spacing: 0.25px; color: var(--fg); white-space: nowrap; }
/* letter-spacing: the Text inherits the M3 bodyMedium style (0.25) */
.a-dropc svg { width: 32px; height: 32px; flex: none; color: var(--acc); }
"""

# Material Icons cloud_upload (AppIcon has no HugeIcon for it, so Flutter draws the Material glyph)
CLOUD_UPLOAD = ('<svg viewBox="0 0 24 24" fill="currentColor"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 '
                '5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65'
                '-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>')


def appz(id_, fmt, zoom, inner, cls="a-vars"):
    """Zoomed wrapper: inside it, coordinates are app px, 1 app px = zoom video px."""
    return (f'<div id="{id_}" class="appz {cls}" style="width:{fmt.W / zoom:.2f}px;height:{fmt.H / zoom:.2f}px;zoom:{zoom}">'
            f'{inner}</div>')


def composer(pid, width, left, top=None, placeholder="Ask me anything !", attach=None, bottom=None):
    """The desktop composer (chat_ui_desktop.dart _buildSearchBar).
    Ids: {pid}-comp, -att (attachment row, hidden until shown), -ph, -typed, -caret (idle caret),
    -caret2 (typing caret), -send. Pass bottom= (distance from the wrapper's bottom, app px)
    to let the composer grow upwards when the attachment row appears, like the app."""
    att = ""
    if attach:
        att = f'<div class="a-att" id="{pid}-att" style="display:none">{attach}</div>'
    pos = f"top:{top:.2f}px" if bottom is None else f"bottom:{bottom:.2f}px"
    return f"""<div id="{pid}-comp" class="a-composer" style="left:{left:.2f}px;{pos};width:{width}px">
          {att}<div class="a-field"><span id="{pid}-caret" class="a-caret0"></span><span id="{pid}-ph" class="a-ph">{esc(placeholder)}</span><span id="{pid}-typed" class="a-typed" style="display:none"></span><span id="{pid}-caret2" class="a-caret" style="opacity:0"></span></div>
          <div class="a-row">
            <span class="a-btn">{hi('h-plus-sign', 24)}</span>
            <span class="a-grow"></span>
            <span class="a-pill">{hi('h-flash', 15)}<b>Fast</b><span class="a-dn">{hi('h-arrow-down01', 12)}</span></span>
            <span class="a-btn">{hi('h-mic02', 22)}</span>
          </div>
          <span id="{pid}-send" class="a-send">{hi('h-send-horizontal', 26)}</span>
        </div>"""


def disclaimer(id_, top):
    return f'<p id="{id_}" class="a-disc" style="top:{top:.2f}px">You\'re chatting with an AI/LLM — it can be wrong. Check key info.</p>'


def attach_card(id_, src, size_label):
    """_ImageAttachmentCard: 72 px, 2 px gradient frame, size badge, remove chip."""
    return (f'<div class="a-attc" id="{id_}"><div class="a-atti"><img src="{src}" alt="">'
            f'<span class="a-attb">{esc(size_label)}</span>'
            f'<span class="a-attx">{hi("h-cancel01", 15 / 0.86)}</span></div></div>')


def drop_overlay(id_, region_h=None, text="Drop files here to upload"):
    """Tints its whole parent; the card centres in the top region_h app px (the message
    area above the composer) or in the whole parent."""
    reg = f' style="height:{region_h:.2f}px"' if region_h else ' style="bottom:0"'
    return (f'<div class="a-drop" id="{id_}"><div class="a-dropr"{reg}><div class="a-dropc" id="{id_}-card">'
            f'{CLOUD_UPLOAD}<span>{esc(text)}</span></div></div></div>')


def user_message(id_, text, image=None, wrap=False, img_size=260):
    """User turn: optional image square above the coral bubble."""
    img = ""
    if image:
        img = (f'<div class="a-uimg" id="{id_}-img" style="width:{img_size}px;height:{img_size}px">'
               f'<img src="{image}" alt=""></div>')
    w = " wrap" if wrap else ""
    return f'<div class="a-user" id="{id_}">{img}<p id="{id_}-bub" class="a-bubble{w}">{esc(text)}</p></div>'


def worked(pid, secs, steps, chips=()):
    """The "Worked for Ns" block. steps: [(icon, text, bold or None)], chips: [(img_src, label)].
    Ids: {pid}-head, -line, -st0.., -srcs."""
    rows = []
    for i, (icon, text, bold) in enumerate(steps):
        b = f'<b>{esc(bold)}</b>' if bold else ""
        rows.append(f'<div class="a-step" id="{pid}-st{i}"><span class="a-badge">{hi(icon, 14)}</span><span>{esc(text)}{b}</span></div>')
    if chips:
        c = "".join(f'<span class="a-src"><img class="a-fav" src="{s}" alt="">{esc(l)}</span>' for s, l in chips)
        rows.append(f'<div class="a-srcs" id="{pid}-srcs">{c}</div>')
    return (f'<div class="a-tl" id="{pid}-tl"><p class="a-tl-head" id="{pid}-head"><span>Worked for {secs}s</span>'
            f'{hi("h-arrow-down01", 16)}</p><div class="a-steps"><div class="a-steps-line" id="{pid}-line"></div>'
            f'{"".join(rows)}</div></div>')


def worked_js(pid, t, n_steps, chips=False):
    """Entrance of worked(): head, line, steps, chips. Returns the JS and the end time."""
    js = [f"tl.fromTo('#{pid}-head', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25 }}, {t:.2f});",
          f"tl.fromTo('#{pid}-line', {{ scaleY: 0, transformOrigin: '50% 0%' }}, {{ scaleY: 1, duration: 0.6, ease: 'power2.out' }}, {t + 0.15:.2f});"]
    for i in range(n_steps):
        js.append(f"tl.fromTo('#{pid}-st{i}', {{ opacity: 0, x: -10 }}, {{ opacity: 1, x: 0, duration: 0.35, ease: 'power3.out' }}, {t + 0.15 + 0.3 * i:.2f});")
    end = t + 0.15 + 0.3 * n_steps + 0.2
    if chips:
        js.append(f"tl.fromTo('#{pid}-srcs .a-src', {{ opacity: 0, y: 8 }}, {{ opacity: 1, y: 0, duration: 0.3, stagger: 0.12, ease: 'power3.out' }}, {end - 0.1:.2f});")
        end += 0.5
    return "\n  ".join(js), end


def answer(id_, paragraphs):
    ps = "".join(f'<p id="{id_}-p{i}">{esc(p)}</p>' for i, p in enumerate(paragraphs))
    return f'<div class="a-ai" id="{id_}">{ps}</div>'


# ------------------------------------------------------------------ server side: Supabase table look (08)
SB_CSS = """
.sb-card { position: absolute; background: #FFFFFF; border: 1px solid #DFE3E8; border-radius: 18px; overflow: hidden; box-shadow: 0 20px 50px -24px rgba(0,0,0,0.25); }
.sb-ic { width: 30px; height: 30px; flex: none; color: #687076; }
.sb-bar { height: 92px; display: flex; align-items: center; gap: 16px; padding: 0 28px; border-bottom: 1px solid #E6E8EB; color: #11181C; white-space: nowrap; }
.sb-name { font-size: 34px; font-weight: 600; }
.sb-tag { font-size: 24px; color: #687076; padding: 4px 12px; border: 1px solid #E6E8EB; border-radius: 8px; white-space: nowrap; }
.sb-grow { flex: 1; }
.sb-btn { display: flex; align-items: center; gap: 10px; font-size: 26px; color: #3E4347; padding: 8px 16px; border: 1px solid #E6E8EB; border-radius: 10px; }
.sb-btn .sb-ic { width: 24px; height: 24px; color: #3E4347; }
.sb-tr { display: flex; height: 80px; border-bottom: 1px solid #E6E8EB; background: #FFFFFF; }
.sb-tr:last-child { border-bottom: none; }
.sb-head { height: 72px; background: #F8F9FA; }
.sb-chk { width: 64px; flex: none; display: flex; align-items: center; justify-content: center; border-right: 1px solid #E6E8EB; }
.sb-box { width: 20px; height: 20px; border: 1.5px solid #C1C8CD; border-radius: 5px; }
.sb-th { flex: none; display: flex; align-items: center; gap: 12px; padding: 0 18px; border-right: 1px solid #E6E8EB; font-size: 27px; color: #11181C; white-space: nowrap; }
.sb-th b { font-weight: 600; }
.sb-th span { font-size: 23px; color: #889096; }
.sb-td { flex: none; display: flex; align-items: center; gap: 14px; padding: 0 18px; border-right: 1px solid #E6E8EB; font-family: 'ChukMono', monospace; font-size: 25px; color: #3E4347; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.sb-td:last-child, .sb-th:last-child { border-right: none; }
.sb-mine .sb-td { color: #11181C; }
.sb-sel { position: absolute; border: 3px solid #3ECF8E; border-radius: 3px; opacity: 0; }
.ex-bar { height: 76px; display: flex; align-items: center; gap: 16px; padding: 0 32px; border-bottom: 1px solid #E6E8EB; font-size: 28px; color: #11181C; white-space: nowrap; }
.ex-bar b { font-weight: 600; }
.ex-bar .sb-ic { width: 28px; height: 28px; color: #687076; }
.ex-body { padding: 26px 40px 30px; font-variant-ligatures: none; font-family: 'ChukMono', monospace; font-size: 30px; line-height: 46px; color: #11181C; }
.ex-l { white-space: pre-wrap; word-break: break-all; }
.ex-k { color: #687076; }
.ex-v { color: #11181C; }
.ex-more { color: #889096; }
"""

SVG = {
    "table": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 10v10"/></svg>',
    "filter": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M7 12h10M10 18h4"/></svg>',
    "sort": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4v16M3 16l4 4 4-4M17 20V4M13 8l4-4 4 4"/></svg>',
    "key": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l3 3"/></svg>',
    # Lucide-style shapes, the set Supabase Studio uses
    "bucket": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16l-1.6 12.2a2 2 0 0 1-2 1.8H7.6a2 2 0 0 1-2-1.8z"/><path d="M8 7a4 4 0 0 1 8 0"/></svg>',
    "folder": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2.5h8.5A1.5 1.5 0 0 1 21 10v8.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"/></svg>',
    "file": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>',
    "chev": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></svg>',
    "upload": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V4M7 9l5-5 5 5M5 20h14"/></svg>',
    "lock": '<svg class="sb-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
}


def db_table(id_, name, tag, cols, rows, mine=None, left=100, top=296, buttons=("Filter", "Sort")):
    """08's Supabase table editor look. cols: [(name, type, width)], rows: [[cell html, ...]].
    Ids: {id_} card, {id_}-r{i} rows, {id_}-cell{i}-{j} cells."""
    th = '<div class="sb-chk"><span class="sb-box"></span></div>' + "".join(
        f'<div class="sb-th" style="width:{w}px"><b>{esc(n)}</b><span>{esc(t)}</span></div>' for n, t, w in cols)
    trs = []
    for i, r in enumerate(rows):
        cls = " sb-mine" if i == mine else ""
        cells = "".join(f'<div class="sb-td" id="{id_}-cell{i}-{j}" style="width:{cols[j][2]}px">{c}</div>' for j, c in enumerate(r))
        trs.append(f'<div class="sb-tr{cls}" id="{id_}-r{i}"><div class="sb-chk"><span class="sb-box"></span></div>{cells}</div>')
    btns = "".join(f'<span class="sb-btn">{SVG[b.lower()]}{b}</span>' for b in buttons)
    width = 64 + sum(c[2] for c in cols) + 2
    return (f'<div class="sb-card" id="{id_}" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="sb-bar">{SVG["table"]}<span class="sb-name">{esc(name)}</span><span class="sb-tag">{esc(tag)}</span>'
            f'<span class="sb-grow"></span>{btns}</div><div class="sb-tr sb-head">{th}</div>{"".join(trs)}</div>')


def envelope_viewer(id_, title, tag, right, env, left, top, width, ct_chars=None, more=None, icon="key"):
    """White card with the envelope JSON pretty-printed (08's opened cell).
    env: dict in key order. ct_chars cuts the ciphertext; more is a grey note after it."""
    lines = [("{", None)]
    keys = list(env)
    for i, k in enumerate(keys):
        v = env[k]
        comma = "," if i < len(keys) - 1 else ""
        if isinstance(v, str):
            if k == "ciphertext" and ct_chars and len(v) > ct_chars:
                vs = f'"{v[:ct_chars]}…"{comma}'
            else:
                vs = f'"{v}"{comma}'
        else:
            vs = f"{v}{comma}"
        lines.append((f'  "{k}": ', vs, k))
    lines.append(("}", None))
    body = []
    for ln in lines:
        k, v = ln[0], ln[1]
        extra = ""
        if len(ln) > 2 and ln[2] == "ciphertext" and more:
            extra = f'<span class="ex-more">  {esc(more)}</span>'
        body.append(f'<div class="ex-l"><span class="ex-k">{esc(k)}</span>' +
                    (f'<span class="ex-v">{esc(v)}</span>' if v else "") + extra + '</div>')
    return (f'<div class="sb-card" id="{id_}" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="ex-bar">{SVG[icon]}<b>{esc(title)}</b><span class="sb-tag">{esc(tag)}</span><span class="sb-grow"></span>'
            f'<span style="font-size:24px;color:#687076">{esc(right)}</span></div>'
            f'<div class="ex-body" id="{id_}-b">{"".join(body)}</div></div>')


# ------------------------------------------------------------------ server side: Supabase Storage browser
# Supabase Studio > Storage > bucket > folder, list view: a light card, breadcrumb bar,
# column header (Name, Size, Type, Last modified), one row per object. Same type scale
# and colours as the table editor above, so both read as one product.
ST_CSS = """
.st-crumb { display: flex; align-items: center; gap: 12px; font-size: 30px; color: #687076; white-space: nowrap; }
.st-crumb b { color: #11181C; font-weight: 600; }
.st-crumb .sb-ic { width: 26px; height: 26px; color: #889096; }
.st-row { display: flex; align-items: center; height: 80px; border-bottom: 1px solid #E6E8EB; background: #FFFFFF; white-space: nowrap; }
.st-row:last-child { border-bottom: none; }
.st-head { height: 64px; background: #F8F9FA; font-size: 24px; font-weight: 600; color: #687076; }
.st-c { flex: none; display: flex; align-items: center; gap: 16px; padding: 0 24px; overflow: hidden; }
.st-name { font-family: 'ChukMono', monospace; font-size: 26px; color: #11181C; }
.st-dim { font-family: 'Ubuntu', sans-serif; font-size: 25px; color: #687076; }
.st-head .st-c { font-family: 'Ubuntu', sans-serif; }
.st-name .sb-ic { width: 30px; height: 30px; color: #889096; }
.st-ext { color: #11181C; }
"""


def storage_list(id_, bucket, folder_label, cols, rows, mine=None, left=100, top=200):
    """cols: [(label, width)], rows: [[name, size, type, modified]] (plain text).
    The name column gets a file icon; ids: {id_}-r{i}, {id_}-name{i}."""
    head = "".join(f'<div class="st-c" style="width:{w}px">{esc(l)}</div>' for l, w in cols)
    trs = []
    for i, r in enumerate(rows):
        cells = []
        for j, v in enumerate(r):
            w = cols[j][1]
            if j == 0:
                stem, dot, ext = v.rpartition(".enc") if v.endswith(".enc") else (v, "", "")
                nm = esc(stem) + (f'<span class="st-ext">.enc</span>' if dot else "")
                cells.append(f'<div class="st-c st-name" style="width:{w}px" id="{id_}-name{i}">{SVG["file"]}<span>{nm}</span></div>')
            else:
                cells.append(f'<div class="st-c st-dim" style="width:{w}px">{esc(v)}</div>')
        trs.append(f'<div class="st-row{" sb-mine" if i == mine else ""}" id="{id_}-r{i}">{"".join(cells)}</div>')
    width = sum(w for _, w in cols) + 2
    return (f'<div class="sb-card" id="{id_}" style="left:{left}px;top:{top}px;width:{width}px">'
            f'<div class="sb-bar"><div class="st-crumb">{SVG["bucket"]}<b>{esc(bucket)}</b>{SVG["chev"]}'
            f'{SVG["folder"]}<span>{esc(folder_label)}</span></div><span class="sb-grow"></span>'
            f'<span class="sb-tag">{SVG["lock"].replace("sb-ic", "sb-ic st-lk")}Private</span>'
            f'<span class="sb-btn">{SVG["upload"]}Upload</span></div>'
            f'<div class="st-row st-head">{head}</div>{"".join(trs)}</div>')


ST_CSS += ".sb-tag .st-lk { width: 22px; height: 22px; display: inline-block; vertical-align: -3px; margin-right: 8px; color: #687076; }\n"

ALL_CSS = APP_CSS + SB_CSS + ST_CSS
