#!/usr/bin/env python3
"""Episode 13 "connectors": the spec and the episode-only scene code.

Story (SERIES-PRIVACY.md row 13): every connector is a key to one of your accounts.
The real Connectors page, Notion, Connect. The browser signs in at mcp.notion.com and
hands the code back to localhost, this device. Back in the app: Connected. Cut: the
secret record mcp_secrets_<id> sits in the device's secure storage; the backup in
Supabase cowork_mcp_connectors is one AES-256-GCM blob. "Your logins stay with you."
Claim (PRIVACY_CLAIMS.md, Connectors, may say): sign-in runs directly between your
device and the service; tokens stay in your device's secure storage, the backup is
encrypted on the device. Notion / Linear / Todoist only. GitHub never appears.

Builds both formats from one spec:
  ../chuk-13-connectors/            16:9 1920x1080
  ../chuk-13-connectors-vertical/   9:16 1080x1920 (re-laid out, not cropped)
Run (once): python3 _work/make_assets.py   then: python3 _work/episode.py
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent
VIDEOS = PROJ.parent
REPO = VIDEOS.parent.parent
sys.path.insert(0, str(VIDEOS / "_lib"))

from chukvid import LANDSCAPE, VERTICAL, Episode, beats, scenes, ui  # noqa: E402
from chukvid.cipher import mask_uuid_short  # noqa: E402
from chukvid.core import cursor, esc  # noqa: E402

MUSIC = VIDEOS.parent / "_shared/music/s1-summer-bells-45s.wav"
DUR = 45.0
S = json.loads((HERE / "secrets.json").read_text())
ENV = S["envelope"]
FID = HERE / "fidelity"

# real catalogue entries (lib/services/mcp/mcp_catalogue.dart), in page order
CATALOGUE = {
    "Recommended": [
        ("excalidraw", "Excalidraw", "Draw diagrams and hand them back as editable scenes."),
        ("canva", "Canva", "Create and edit designs, export them, search your folders."),
        ("notion", "Notion", "Search, read and write pages and databases."),
        ("stripe", "Stripe", "Look up customers, payments, subscriptions and products, and create payment links."),
    ],
    "Productivity": [
        ("box", "Box", "Files, folders and content in Box."),
        ("linear", "Linear", "Issues, projects and cycles."),
        ("atlassian", "Atlassian", "Jira issues and Confluence pages."),
        ("asana", "Asana", "Tasks, projects and workspaces."),
        ("monday", "monday.com", "Boards, items and updates."),
        ("plane", "Plane", "Issues, cycles, modules and projects."),
        ("todoist", "Todoist", "Tasks, projects and due dates."),
    ],
}
NOTION_URL = "https://mcp.notion.com/mcp"
NOTION_TOOLS = 14
LEGAL = ("Connecting signs you in to notion.com. What you send through this connector is "
         "handled by them, under their terms and privacy policy.")
# the authorize request McpOAuth builds (response_type, client_id, redirect_uri, PKCE S256,
# state, resource), and the loopback redirect (mcp_redirect_io.dart: localhost:<port>/mcp/callback)
AUTH_HOST = "mcp.notion.com"
AUTH_PATH = ("/authorize?response_type=code&client_id=" + S["record"]["credentials"]["client_id"] +
             "&redirect_uri=http%3A%2F%2Flocalhost%3A51823%2Fmcp%2Fcallback&code_challenge=Xq0v…"
             "&code_challenge_method=S256&state=…&resource=https%3A%2F%2Fmcp.notion.com%2Fmcp")
CB_HOST = "localhost:51823"
CB_PATH = "/mcp/callback?code=…&state=…&iss=https%3A%2F%2Fmcp.notion.com"

TARGETS = [4.1, 11.0, 17.6, 19.8, 22.0, 28.1, 32.5, 34.7]


# ------------------------------------------------------------------ icons from the app's own HugeIcons files
def huge(name, box, style=""):
    """assets/icons/hugeicons/<name>.svg, drawn at 0.86 of its box like AppIcon/HugeIcon."""
    svg = (REPO / f"assets/icons/hugeicons/{name}.svg").read_text()
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    px = round(box * 0.86, 2)
    return (f'<svg class="hi" viewBox="0 0 24 24" fill="none" style="width:{px}px;height:{px}px;{style}">'
            f'{inner}</svg>')


def build(fmt, folder):
    ep = Episode(folder, fmt, DUR, MUSIC, extra_css=ui.ALL_CSS + EP_CSS)
    for cid in ("excalidraw", "canva", "notion", "stripe", "box", "linear", "atlassian", "asana", "monday", "plane", "todoist"):
        ep.asset(REPO / f"assets/mcp_icons/{cid}.png", f"img/mcp/{cid}.png")
    ep.asset(HERE / "gen/fav-notion.com.png", "img/brand/notion-256.png")
    ep.asset(HERE / "gen/fav-linear.app.png", "img/brand/linear-180.jpg")
    ep.write()
    grid = beats.ensure(folder)
    cut = beats.cuts(TARGETS, grid, DUR, strong=0.4)
    v = fmt.vertical
    cs = 1.3 if v else 1.0

    s01_hook(ep, cut[0], cut[1], v)
    s02_connect(ep, cut[1], cut[2], v, cs)
    s03_browser(ep, cut[2], cut[3], v, cs)
    s04_connected(ep, cut[3], cut[4], v)
    scenes.card(ep, "s05", cut[4], cut[5], ["So where is", "the key now?"] if v else ["So where is the key now?"])
    s06_keychain(ep, cut[5], cut[6], v)
    s07_backup(ep, cut[6], cut[7], v, cs)
    scenes.card(ep, "s08", cut[7], cut[8], ["Your logins", "stay with you."] if v else ["Your logins stay with you."], bg="@TAN@")
    scenes.end_card(ep, "s09", cut[8], DUR)
    ep.write()
    ep.report()
    return ep


# =================================================================== the Connectors page, rebuilt 1:1
# lib/pages/mcp_connectors_page.dart + widgets/expressive_settings.dart + floating_app_bar.dart +
# settings_search_bar.dart, Clawed dark. Every number is the real widget's, checked against
# the widget test render (_work/fidelity/real-*.json, app px).
EP_CSS = """
.cx-page { position: absolute; left: 0; top: 0; background: @BG@; color: @FG@; font-family: 'Ubuntu', sans-serif; }
/* FloatingAppBar: 42 px chips (#31312F), title 15 w800 at 92 % */
.cx-back { position: absolute; left: 10px; top: 10px; width: 42px; height: 42px; border-radius: 21px; background: #31312F;
  display: flex; align-items: center; justify-content: center; color: @FG@; }
.cx-title { position: absolute; top: 10px; height: 42px; padding: 0 16px; border-radius: 18px; background: #31312F;
  font-size: 15px; font-weight: 800; line-height: 42px; color: rgba(232,228,216,0.92); white-space: nowrap; }
/* PinnedSettingsSearchBar: 44 px field, radius 22, #41413E, search_rounded 20 */
.cx-search { position: absolute; left: 16px; top: 64px; height: 44px; border-radius: 22px; background: #41413E;
  display: flex; align-items: center; color: rgba(232,228,216,0.86); font-size: 14px; letter-spacing: 0.25px; }
.cx-search .hi { margin: 0 14px 0 14px; width: 20px; height: 20px; }
.cx-search svg path { stroke-width: 1.5; }
.cx-intro { position: absolute; left: 16px; top: 130px; font-size: 14px; line-height: 20px; letter-spacing: 0.25px; color: rgba(232,228,216,0.7); }
/* ExpressiveSectionHeader: titleMedium w700, primary, padding 16/6/8 */
.cx-sec { position: absolute; left: 22px; height: 24px; font-size: 16px; line-height: 24px; font-weight: 700; letter-spacing: 0.15px; color: @ACC@; }
/* ExpressiveTile: surfaceContainer #363634, padding 12/14, radius 26 outer / 6 inner, gap 3 */
.cx-tile { position: absolute; left: 16px; display: flex; align-items: center; padding: 12px 14px; background: #363634; border-radius: 6px; }
.cx-tile.first { border-top-left-radius: 26px; border-top-right-radius: 26px; }
.cx-tile.last { border-bottom-left-radius: 26px; border-bottom-right-radius: 26px; }
.cx-ico { flex: none; width: 42px; height: 42px; border-radius: 12.6px; overflow: hidden; margin-right: 14px; }
.cx-ico img { display: block; width: 100%; height: 100%; object-fit: cover; }
.cx-txt { flex: 1; min-width: 0; }
.cx-name { font-size: 16px; line-height: 24px; font-weight: 600; letter-spacing: 0.15px; color: @FG@; white-space: nowrap; }
.cx-sub { margin-top: 2px; font-size: 12px; line-height: 16px; letter-spacing: 0.32px; color: rgba(232,228,216,0.86);
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
/* ExpressiveBadge: surfaceContainerHighest #4C4C48, padding 6/12, labelMedium w600 */
.cx-badge { flex: none; margin-left: 12px; padding: 6px 12px; border-radius: 999px; background: #4C4C48;
  font-size: 12px; line-height: 16px; font-weight: 600; letter-spacing: 0.5px; color: @FG@; white-space: nowrap; }
/* McpConnectorDetailPage */
.cx-dico { position: absolute; width: 72px; height: 72px; border-radius: 21.6px; overflow: hidden; }
.cx-dico img { display: block; width: 100%; height: 100%; }
.cx-c { position: absolute; left: 16px; text-align: center; }
.cx-dtitle { font-size: 22px; line-height: 28px; color: @FG@; }
.cx-ddesc { font-size: 14px; line-height: 20px; letter-spacing: 0.25px; color: rgba(232,228,216,0.7); }
.cx-legal { font-size: 12px; line-height: 16px; letter-spacing: 0.4px; color: rgba(232,228,216,0.7); }
.cx-link { position: absolute; font-size: 14px; line-height: 16px; font-weight: 600; letter-spacing: 0.1px; color: @ACC@; white-space: nowrap; }
.cx-btn { position: absolute; left: 16px; height: 52px; border-radius: 26px; background: @ACC@; display: flex; align-items: center;
  justify-content: center; font-size: 14px; font-weight: 600; letter-spacing: 0.1px; color: @FG@; }
.cx-busy { position: absolute; left: 16px; height: 52px; display: flex; align-items: center; justify-content: center; gap: 16px; opacity: 0; }
.cx-busy span { padding: 0 16px; font-size: 14px; font-weight: 600; letter-spacing: 0.1px; color: @ACC@; }
.cx-spin { width: 24px; height: 24px; }
.cx-lab { position: absolute; left: 16px; font-size: 14px; line-height: 20px; font-weight: 500; letter-spacing: 0.1px; color: rgba(232,228,216,0.6); }
.cx-card { position: absolute; left: 16px; padding: 16px; border-radius: 16px; background: #31312F; }
.cx-card small { display: block; font-size: 12px; line-height: 16px; letter-spacing: 0.4px; color: rgba(232,228,216,0.6); }
.cx-card div { margin-top: 4px; font-size: 14px; line-height: 20px; letter-spacing: 0.25px; color: @FG@; }

/* the brand tiles of the hook */
.tile { position: absolute; border-radius: 30%; overflow: hidden; background: #FFFFFF; box-shadow: 0 24px 50px -24px rgba(0,0,0,0.45); }
.tile img { display: block; width: 100%; height: 100%; object-fit: cover; }
.tile.pad img { width: 76%; height: 76%; margin: 12%; object-fit: contain; }
.keyi { position: absolute; color: @INK@; display: flex; align-items: center; justify-content: center; }
.keyi svg path { stroke-width: 1.6; }

/* the browser (neutral, light; not a copy of any vendor's page) */
.bw { position: absolute; background: #FFFFFF; border-radius: 22px; overflow: hidden; box-shadow: 0 0 0 1px rgba(0,0,0,0.06), 0 30px 70px -30px rgba(0,0,0,0.4); }
.bw-bar { display: flex; align-items: center; gap: 22px; padding: 0 28px; background: #EFE9E0; border-bottom: 1px solid #E2D9CC; }
.bw-dots { display: flex; gap: 12px; }
.bw-dots i { display: block; width: 18px; height: 18px; border-radius: 50%; background: #D3C7B6; }
.bw-url { flex: 1; min-width: 0; display: flex; align-items: center; gap: 14px; padding: 0 26px; border-radius: 999px; background: #FFFFFF;
  font-family: 'Ubuntu', sans-serif; color: #6E5D4E; white-space: nowrap; overflow: hidden; }
.bw-url b { font-weight: 600; color: @INK@; }
.bw-url .p { overflow: hidden; text-overflow: ellipsis; }
.bw-url svg { flex: none; color: #6E5D4E; }
.bw-hl { position: relative; }
.bw-hl::after { content: ''; position: absolute; left: -4px; right: -4px; bottom: -6px; height: 5px; border-radius: 3px; background: @ACC@; transform: scaleX(var(--hl, 0)); transform-origin: 0 50%; }
.bw-body { position: absolute; left: 0; right: 0; bottom: 0; display: flex; align-items: center; justify-content: center; background: #FFFFFF; }
.cs { display: flex; flex-direction: column; align-items: center; text-align: center; color: #1F1A16; }
.cs h2 { margin: 0; font-family: 'Ubuntu', sans-serif; font-weight: 600; letter-spacing: -0.01em; color: #1F1A16; }
.cs p { margin: 0; color: #5E5249; }
.cs-ws { display: flex; align-items: center; gap: 18px; border: 2px solid #E6DFD4; border-radius: 18px; color: #1F1A16; }
.cs-av { display: flex; align-items: center; justify-content: center; border-radius: 10px; background: #F1ECE4; font-weight: 600; color: #5E5249; }
.cs-btns { display: flex; gap: 20px; }
.cs-b { display: flex; align-items: center; justify-content: center; border-radius: 14px; font-weight: 600; }
.cs-b.ghost { border: 2px solid #E6DFD4; color: #1F1A16; background: #FFFFFF; }
.cs-b.solid { background: #1F1A16; color: #FFFFFF; }
.cb { display: flex; flex-direction: column; align-items: center; gap: 22px; color: #1F1A16; opacity: 0; }

/* secure storage card on the brown block */
.vault { position: absolute; background: @CANVAS@; border-radius: 20px; overflow: hidden; color: @INK@; }
.vault-bar { display: flex; align-items: center; gap: 16px; padding: 0 32px; border-bottom: 1px solid #E2D6C4; white-space: nowrap; }
.vault-bar b { font-weight: 600; }
.vault-tag { padding: 4px 12px; border: 1px solid #DCCBB4; border-radius: 8px; color: @SOFT@; }
.vault-body { font-family: 'ChukMono', monospace; font-variant-ligatures: none; white-space: pre; color: @INK@; }
.vault-body .k { color: @SOFT@; }
.vault-body .m { letter-spacing: 0.08em; color: #8A7866; }
.vault-foot { display: flex; align-items: center; gap: 16px; border-top: 1px solid #E2D6C4; color: @SOFT@; white-space: nowrap; }
.vault-foot b { font-family: 'ChukMono', monospace; font-weight: 400; color: @INK@; }

/* server-view text at the 30 px floor */
.sb-td { font-size: 30px; }
.sb-th { font-size: 30px; }
.sb-th span { font-size: 30px; }
.sb-name { font-size: 36px; }
.sb-tag { font-size: 30px; }
.sb-btn { font-size: 30px; }
.ex-bar { font-size: 32px; }
.ex-bar span { font-size: 30px !important; }
"""

SPINNER = ('<svg class="cx-spin" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10.75" fill="none" stroke="@ACC@" '
           'stroke-width="2.5" stroke-linecap="butt" stroke-dasharray="50 100"/></svg>')


def list_layout(pw, connected=False):
    """Tops of every block of McpConnectorsPage, app px (verified against real-list*.json)."""
    y = 130 + (40 if pw < 400 else 20) + 20        # intro (1 or 2 lines) + SizedBox 20
    blocks = []
    groups = ([("Connected", [("notion", "Notion", CATALOGUE["Recommended"][2][2], f"{NOTION_TOOLS} tools")])] if connected else [])
    for sec, rows in CATALOGUE.items():
        rows = [(c, n, d, "Connect") for c, n, d in rows if not (connected and c == "notion")]
        groups.append((sec, rows))
    # subtitle line counts as the real page wraps them (widget test, real-list*-<w>.json)
    jf = FID / f"real-list{'-connected' if connected else ''}-{pw}.json"
    real = {t["text"]: t["h"] for t in json.loads(jf.read_text())} if jf.exists() else {}
    for sec, rows in groups:
        y += 16
        blocks.append(("sec", sec, y))
        y += 24 + 8
        for i, (cid, name, desc, badge) in enumerate(rows):
            lines = max(1, round(real.get(desc, 16 if len(desc) < 40 else 32) / 16))
            h = 24 + 24 + 2 + 16 * lines
            # the Productivity group goes on below the frame: no tile here is its last
            blocks.append(("tile", (cid, name, desc, badge, i == 0, i == len(rows) - 1 and sec != "Productivity", h), y))
            y += h + 3
        y -= 3
    return blocks


def connectors_page(pid, pw, ph, connected=False):
    out = [f'<div class="cx-title" style="left:10px">Connectors</div>',
           f'<div class="cx-search" style="width:{pw - 32}px">{huge("search01", 20)}<span>Search connectors…</span></div>',
           f'<div class="cx-intro" style="width:{pw - 32}px">Connectors let the assistant use tools and data from other services.</div>']
    for kind, data, y in list_layout(pw, connected):
        if kind == "sec":
            out.append(f'<div class="cx-sec" style="top:{y}px">{esc(data)}</div>')
        else:
            cid, name, desc, badge, first, last, h = data
            cls = " first" * first + " last" * last
            out.append(f'<div class="cx-tile{cls}" id="{pid}-t-{cid}" style="top:{y}px;width:{pw - 32}px;height:{h}px">'
                       f'<div class="cx-ico"><img src="assets/img/mcp/{cid}.png" alt=""></div>'
                       f'<div class="cx-txt"><div class="cx-name">{esc(name)}</div><div class="cx-sub">{esc(desc)}</div></div>'
                       f'<div class="cx-badge">{esc(badge)}</div></div>')
    return f'<div class="cx-page" id="{pid}" style="width:{pw}px;height:{ph}px">{"".join(out)}</div>'


def tile_top(pw, cid, connected=False):
    for kind, data, y in list_layout(pw, connected):
        if kind == "tile" and data[0] == cid:
            return y, data[6]
    raise KeyError(cid)


def detail_page(pid, pw, ph):
    """McpConnectorDetailPage for Notion, not connected, with the busy row (spinner + Cancel)
    stacked on the Connect button. Tops from the widget test (real-detail-<w>.json)."""
    J = {t["text"][:12]: t for t in json.loads((FID / f"real-detail-{pw}.json").read_text())}
    title_y = J["Notion"]["y"] if J["Notion"]["y"] > 100 else 174
    legal_y = J["Connecting s"]["y"]
    link_y = J["Terms"]["y"]
    btn_y = J["Connect"]["y"] - 18                 # 52 px button, label 16 px centred
    lab_y = J["Details"]["y"]
    url_y = lab_y + 28
    terms_x, priv_x = J["Terms"]["x"], J["Privacy poli"]["x"]
    return f"""<div class="cx-page" id="{pid}" style="width:{pw}px;height:{ph}px">
      <div class="cx-back">{huge("arrow-left02", 22)}</div>
      <div class="cx-title" style="left:60px">Notion</div>
      <div class="cx-dico" style="left:{(pw - 72) / 2}px;top:86px"><img src="assets/img/mcp/notion.png" alt=""></div>
      <div class="cx-c cx-dtitle" style="top:{title_y}px;width:{pw - 32}px">Notion</div>
      <div class="cx-c cx-ddesc" style="top:214px;width:{pw - 32}px">{esc(CATALOGUE['Recommended'][2][2])}</div>
      <div class="cx-c cx-legal" style="top:{legal_y}px;width:{pw - 32}px">{esc(LEGAL)}</div>
      <div class="cx-link" style="left:{terms_x}px;top:{link_y}px">Terms</div>
      <div class="cx-link" style="left:{priv_x}px;top:{link_y}px">Privacy policy</div>
      <div class="cx-btn" id="{pid}-btn" style="top:{btn_y}px;width:{pw - 32}px">Connect</div>
      <div class="cx-busy" id="{pid}-busy" style="top:{btn_y}px;width:{pw - 32}px"><div id="{pid}-spin" style="width:24px;height:24px">{SPINNER}</div><span>Cancel</span></div>
      <div class="cx-lab" style="top:{lab_y}px;width:{pw - 32}px">Details</div>
      <div class="cx-card" style="top:{url_y}px;width:{pw - 32}px"><small>Server URL</small><div>{NOTION_URL}</div></div>
    </div>""", btn_y


# =================================================================== s01 hook: three keys
def s01_hook(ep, a, b, v):
    fmt = ep.fmt
    if v:
        ts, gap, ty = 230, 60, 380
        lines, size, ly = ["Every connector", "is a key to", "your account."], 108, 900
        ky = ty + ts + 40
    else:
        ts, gap, ty = 200, 80, 150
        lines, size, ly = ["Every connector is a key", "to one of your accounts."], 100, 650
        ky = ty + ts + 36
    x0 = fmt.cx - (3 * ts + 2 * gap) / 2
    tiles = [("notion", "assets/img/brand/notion-256.png", True), ("linear", "assets/img/brand/linear-180.jpg", False),
             ("todoist", "assets/img/mcp/todoist.png", False)]
    lh = round(size * 1.12)
    kz = round(ts * 0.42)
    body = []
    for i, (cid, src, pad) in enumerate(tiles):
        x = x0 + i * (ts + gap)
        bg = "" if pad else "background:transparent;"
        body.append(f'<div class="tile{" pad" if pad else ""}" id="s01-t{i}" style="left:{x:.0f}px;top:{ty}px;width:{ts}px;height:{ts}px;{bg}"><img src="{src}" alt=""></div>')
        body.append(f'<div class="keyi" id="s01-k{i}" style="left:{x + (ts - kz) / 2:.0f}px;top:{ky}px;width:{kz}px;height:{kz}px">{huge("key01", kz / 0.86)}</div>')
    for i, t in enumerate(lines):
        body.append(f'<div class="card-line serif" id="s01-l{i}" style="top:{ly + i * lh}px;font-size:{size}px;line-height:{lh}px">{esc(t)}</div>')
    css = f"#s01-all {{ transform-origin: {fmt.cx}px {fmt.cy}px; }}"
    js = "".join(
        f"  tl.fromTo('#s01-t{i}', {{ opacity: {1 if i == 0 else 0}, y: 40, scale: 0.92 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.6, ease: 'expo.out' }}, {0.05 + i * 0.14:.2f});\n"
        f"  tl.fromTo('#s01-k{i}', {{ opacity: 0, y: -26, rotation: -40 }}, {{ opacity: 1, y: 0, rotation: 0, duration: 0.55, ease: 'back.out(1.6)' }}, {0.55 + i * 0.14:.2f});\n"
        for i in range(3))
    js += "".join(f"  hfReveal(tl, '#s01-l{i}', {1.05 + i * 0.42:.2f});\n" for i in range(len(lines)))
    js += f"  tl.fromTo('#s01-all', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);\n"
    ep.add("s01", a, b, css, f'<div id="s01-all" class="fill">{"".join(body)}</div>', js)


# =================================================================== s02 Connectors page -> Notion -> Connect
def s02_connect(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        Z, pw, wl, wt, wh = 2.85, 376, 1.5, 80, 660
        pan_list, pan_det = -260, 0
    else:
        Z, pw, wl, wt, wh = 2.5, 600, 84, 24, 640
        pan_list, pan_det = -260, -60
    lst = connectors_page("s02-list", pw, wh)
    det, btn_y = detail_page("s02-det", pw, wh)
    ny, nh = tile_top(pw, "notion")
    inner = f"""<div class="a-win" id="s02-win" style="left:{wl}px;top:{wt}px;width:{pw}px;height:{wh}px">
        <div id="s02-L" class="fill">{lst}</div>
        <div id="s02-D" class="fill" style="opacity:0">{det}</div>
      </div>"""

    def vp(x, y, pan):
        return (wl + x) * Z, (wt + y) * Z + pan
    row = vp(pw * 0.66, ny + nh / 2 + 6, pan_list)
    btn = vp(pw / 2 + 40, btn_y + 30, pan_det)
    css = f"""
#s02-cam {{ transform-origin: {btn[0]:.0f}px {btn[1]:.0f}px; }}
#s02-list-t-notion {{ transform-origin: 50% 50%; }}
#s02-det-btn {{ transform-origin: 50% 50%; }}
#s02-det-spin svg {{ transform-origin: 50% 50%; }}
"""
    body = f"""
    <div id="s02-cam" class="fill">
      <div id="s02-pan" class="fill">{ui.appz('s02-z', fmt, Z, inner)}</div>
      {cursor('s02-cur', cs)}
    </div>
"""
    js = f"""
  tl.fromTo('#s02-z', {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s02-pan', {{ y: 0 }}, {{ y: {pan_list}, duration: 1.1, ease: 'power2.inOut' }}, 0.45);
  // to the Notion row
  tl.fromTo('#s02-cur', {{ x: {fmt.W * 0.75:.0f}, y: {fmt.H + 60} }}, {{ x: {row[0]:.0f}, y: {row[1]:.0f}, duration: 1.0, ease: 'power2.inOut' }}, 0.75);
  hfShape(tl, '#s02-cur', 1.7, 'hand');
  tl.to('#s02-list-t-notion', {{ backgroundColor: '#41413E', duration: 0.12 }}, 1.75);
  hfClick(tl, '#s02-cur', 1.95, 'hand');
  tl.to('#s02-list-t-notion', {{ scale: 0.985, borderRadius: 26, duration: 0.1 }}, 1.95);
  tl.to('#s02-list-t-notion', {{ scale: 1, duration: 0.13 }}, 2.07);
  // the detail page opens (ZoomPageTransitionsBuilder: fade + slight zoom)
  tl.to('#s02-L', {{ opacity: 0, scale: 1.04, duration: 0.3, ease: 'power2.in' }}, 2.15);
  tl.fromTo('#s02-D', {{ opacity: 0, scale: 0.92 }}, {{ opacity: 1, scale: 1, duration: 0.4, ease: 'power3.out' }}, 2.2);
  tl.to('#s02-pan', {{ y: {pan_det}, duration: 0.6, ease: 'power2.inOut' }}, 2.2);
  hfShape(tl, '#s02-cur', 2.25, 'arrow');
  // Connect
  tl.to('#s02-cur', {{ x: {btn[0]:.0f}, y: {btn[1]:.0f}, duration: 0.8, ease: 'power2.inOut' }}, 2.6);
  hfShape(tl, '#s02-cur', 3.35, 'hand');
  hfClick(tl, '#s02-cur', 3.6, 'hand');
  tl.to('#s02-det-btn', {{ scale: 0.97, backgroundColor: '#C9684A', duration: 0.08 }}, 3.6);
  tl.to('#s02-det-btn', {{ opacity: 0, duration: 0.12 }}, 3.75);
  tl.to('#s02-det-busy', {{ opacity: 1, duration: 0.12 }}, 3.8);
  tl.fromTo('#s02-det-spin svg', {{ rotation: 0 }}, {{ rotation: 1080, duration: {b - a - 3.8:.2f}, ease: 'none' }}, 3.8);
  hfShape(tl, '#s02-cur', 3.9, 'arrow');
  tl.to('#s02-cur', {{ x: {btn[0] + 300:.0f}, y: {btn[1] + 120:.0f}, duration: 0.7, ease: 'power2.out' }}, 3.95);
  tl.fromTo('#s02-cam', {{ scale: 1 }}, {{ scale: 1.05, duration: {b - a - 3.7:.2f}, ease: 'power1.inOut' }}, 3.7);
"""
    ep.add("s02", a, b, css, body, js)


# =================================================================== s03 the browser signs in at Notion
def s03_browser(ep, a, b, v, cs):
    fmt = ep.fmt
    if v:
        bx, by, bw, bh = 40, 240, 1000, 1000
        bar_h, url_h, url_fs, lock = 120, 80, 34, 32
        logo, h2, pfs, ws_h, ws_fs, btn_w, btn_h, btn_fs, gap = 150, 50, 34, 100, 34, 330, 96, 36, 34
        lines, lsize, ltop = ["Sign-in runs between", "your device and Notion."], 82, 1300
        cb_fs = 40
    else:
        bx, by, bw, bh = 260, 50, 1400, 700
        bar_h, url_h, url_fs, lock = 104, 64, 30, 28
        logo, h2, pfs, ws_h, ws_fs, btn_w, btn_h, btn_fs, gap = 120, 46, 30, 88, 30, 300, 84, 32, 26
        lines, lsize, ltop = ["Sign-in runs between your device and Notion."], 80, 830
        cb_fs = 38
    lh = round(lsize * 1.12)
    ldivs = "".join(f'<div class="card-line serif" id="s03-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    lock_svg = huge("square-lock02", lock / 0.86)
    body_h = bh - bar_h
    css = f"""
#s03-cam {{ transform-origin: {fmt.cx}px {by + bh / 2}px; }}
#s03-bw {{ left: {bx}px; top: {by}px; width: {bw}px; height: {bh}px; }}
#s03-bar {{ height: {bar_h}px; }}
#s03-url {{ height: {url_h}px; font-size: {url_fs}px; }}
#s03-body {{ top: {bar_h}px; height: {body_h}px; }}
#s03-cs {{ gap: {gap}px; }}
#s03-cs .tile {{ position: relative; width: {logo}px; height: {logo}px; box-shadow: 0 0 0 2px #EEE8DF; }}
#s03-cs h2 {{ font-size: {h2}px; line-height: {round(h2 * 1.2)}px; }}
#s03-cs p {{ font-size: {pfs}px; line-height: {round(pfs * 1.35)}px; }}
#s03-ws {{ height: {ws_h}px; padding: 0 30px; font-size: {ws_fs}px; }}
#s03-ws .cs-av {{ width: {ws_h - 36}px; height: {ws_h - 36}px; font-size: {ws_fs}px; }}
#s03-cs .cs-b {{ width: {btn_w}px; height: {btn_h}px; font-size: {btn_fs}px; }}
#s03-allow {{ transform-origin: 50% 50%; }}
#s03-cb {{ font-size: {cb_fs}px; }}
#s03-u2 {{ display: none; }}
"""
    url1 = f'{lock_svg}<span class="p"><b class="bw-hl" id="s03-host">{AUTH_HOST}</b>{esc(AUTH_PATH)}</span>'
    url2 = f'{huge("laptop", lock / 0.86)}<span class="p"><b class="bw-hl" id="s03-host2">{CB_HOST}</b>{esc(CB_PATH)}</span>'
    sub = "This lets the app on your device<br>read and write pages in:" if v else "This lets the app on your device read and write pages in:"
    body = f"""
    <div id="s03-cam" class="fill">
      <div class="bw" id="s03-bw">
        <div class="bw-bar" id="s03-bar"><div class="bw-dots"><i></i><i></i><i></i></div>
          <div class="bw-url" id="s03-url"><span id="s03-u1" style="display:contents">{url1}</span><span id="s03-u2" style="display:none">{url2}</span></div></div>
        <div class="bw-body" id="s03-body">
          <div class="cs" id="s03-cs">
            <div class="tile pad" id="s03-logo"><img src="assets/img/brand/notion-256.png" alt=""></div>
            <h2 id="s03-h">Allow access to Notion?</h2>
            <p id="s03-p">{sub}</p>
            <div class="cs-ws" id="s03-ws"><span class="cs-av">A</span>Alex's workspace</div>
            <div class="cs-btns" id="s03-btns"><span class="cs-b ghost">Cancel</span><span class="cs-b solid" id="s03-allow">Allow access</span></div>
          </div>
          <div class="cb fill" id="s03-cb" style="justify-content:center"><span>Connected. You can close this tab.</span></div>
        </div>
      </div>
      {ldivs}
      {cursor('s03-cur', cs)}
    </div>
"""
    allow_x = fmt.cx + (btn_w + 20) / 2
    allow_y = by + bar_h + body_h / 2 + (logo + gap * 4 + round(h2 * 1.2) + round(pfs * 1.35) * (2 if v else 1) + ws_h + btn_h) / 2 - btn_h / 2
    js = f"""
  tl.fromTo('#s03-bw', {{ opacity: 0, y: 60 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: 'expo.out' }}, 0);
  tl.fromTo('#s03-cs > *', {{ opacity: 0, y: 16 }}, {{ opacity: 1, y: 0, duration: 0.4, stagger: 0.07, ease: 'power3.out' }}, 0.45);
  tl.fromTo('#s03-host', {{ '--hl': 0 }}, {{ '--hl': 1, duration: 0.5, ease: 'power2.out' }}, 1.0);
  {''.join(f"hfReveal(tl, '#s03-l{i}', {1.35 + i * 0.4:.2f});" for i in range(len(lines)))}
  tl.fromTo('#s03-cur', {{ x: {fmt.W * 0.8:.0f}, y: {fmt.H + 60} }}, {{ x: {allow_x:.0f}, y: {allow_y:.0f}, duration: 1.0, ease: 'power2.inOut' }}, 2.3);
  hfShape(tl, '#s03-cur', 3.2, 'hand');
  hfClick(tl, '#s03-cur', 3.55, 'hand');
  tl.to('#s03-allow', {{ scale: 0.95, backgroundColor: '#3A322C', duration: 0.08 }}, 3.55);
  tl.to('#s03-allow', {{ scale: 1, duration: 0.12 }}, 3.63);
  // the authorization server redirects to the loopback listener on this device
  tl.to('#s03-cs', {{ opacity: 0, duration: 0.2 }}, 3.9);
  tl.set('#s03-u1', {{ display: 'none' }}, 4.0);
  tl.set('#s03-u2', {{ display: 'contents' }}, 4.0);
  tl.fromTo('#s03-host2', {{ '--hl': 0 }}, {{ '--hl': 1, duration: 0.5, ease: 'power2.out' }}, 4.1);
  tl.to('#s03-cb', {{ opacity: 1, duration: 0.3 }}, 4.15);
  hfShape(tl, '#s03-cur', 3.95, 'arrow');
  tl.to('#s03-cur', {{ x: {fmt.W + 80}, y: {fmt.H * 0.7:.0f}, duration: 0.8, ease: 'power3.in' }}, 4.1);
  tl.fromTo('#s03-cam', {{ scale: 1 }}, {{ scale: 1.035, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s03", a, b, css, body, js)


# =================================================================== s04 back in the app: Connected
def s04_connected(ep, a, b, v):
    fmt = ep.fmt
    if v:
        Z, pw, wl, wt, wh = 2.85, 376, 1.5, 80, 660
    else:
        Z, pw, wl, wt, wh = 2.5, 600, 84, 24, 640
    page = connectors_page("s04-p", pw, wh, connected=True)
    ny, nh = tile_top(pw, "notion", connected=True)
    inner = f'<div class="a-win" id="s04-win" style="left:{wl}px;top:{wt}px;width:{pw}px;height:{wh}px">{page}</div>'
    oy = (wt + ny + nh / 2) * Z
    css = f"#s04-cam {{ transform-origin: {fmt.cx}px {oy:.0f}px; }}\n#s04-p-t-notion {{ transform-origin: 50% 50%; }}"
    body = f'<div id="s04-cam" class="fill">{ui.appz("s04-z", fmt, Z, inner)}</div>'
    js = f"""
  tl.fromTo('#s04-z', {{ opacity: 0, scale: 0.96 }}, {{ opacity: 1, scale: 1, duration: 0.35, ease: 'power3.out' }}, 0);
  tl.fromTo('#s04-p-t-notion', {{ backgroundColor: '#4A4A46' }}, {{ backgroundColor: '#363634', duration: 1.2, ease: 'power2.out' }}, 0.35);
  tl.fromTo('#s04-p-t-notion .cx-badge', {{ scale: 0.6, opacity: 0 }}, {{ scale: 1, opacity: 1, duration: 0.4, ease: 'back.out(1.8)' }}, 0.4);
  tl.fromTo('#s04-cam', {{ scale: 1 }}, {{ scale: {1.06 if v else 1.1}, duration: {b - a:.2f}, ease: 'power1.inOut' }}, 0);
"""
    ep.add("s04", a, b, css, body, js)


# =================================================================== s06 brown block: the secure storage record
def s06_keychain(ep, a, b, v):
    fmt = ep.fmt
    r = S["record"]
    masked = "••••••••••••••••"
    lines = [
        ("{", None),
        ('  "credentials": { ', [("k", '"client_id": '), ("v", f'"{r["credentials"]["client_id"]}"'), ("", " },")]),
        ('  "tokens": {', None),
        ('    ', [("k", '"access_token": '), ("m", f'"{masked}"'), ("", ",")]),
        ('    ', [("k", '"refresh_token": '), ("m", f'"{masked}"'), ("", ",")]),
        ('    ', [("k", '"expires_at": '), ("v", f'"{r["tokens"]["expires_at"][:19]}Z"')]),
        ('  },', None),
        ('  ', [("k", '"issuer": '), ("v", f'"{r["issuer"]}"'), ("", ",")]),
        ('  ', [("k", '"token_endpoint": '), ("v", f'"{r["token_endpoint"]}"')]),
        ("}", None),
    ]
    if v:
        left, top, width, fs, lhc, bar_h, bar_fs = 40, 240, 1000, 34, 50, 100, 36
        foot_fs = 34
        lt, ls, ltop = ["Your tokens stay", "in your device's", "secure storage."], 100, 1185
        # 9:16 keeps the record but shortens the long lines
        lines[1] = ('  "credentials": {', None)
        lines.insert(2, ('    ', [("k", '"client_id": '), ("v", f'"{r["credentials"]["client_id"]}"')]))
        lines.insert(3, ('  },', None))
        lines[-3] = ('  ', [("k", '"issuer": '), ("v", '"…mcp.notion.com"'), ("", ",")])
        lines[-2] = ('  ', [("k", '"token_endpoint": '), ("v", '"…/token"')])
    else:
        left, top, width, fs, lhc, bar_h, bar_fs = 200, 60, 1520, 32, 48, 92, 34
        foot_fs = 30
        lt, ls, ltop = ["Your tokens stay in your", "device's secure storage."], 84, 832
    rows = []
    for i, (pre, parts) in enumerate(lines):
        s = esc(pre)
        for cls, t in parts or []:
            s += f'<span class="{cls}">{esc(t)}</span>' if cls else esc(t)
        rows.append(f'<div class="vl" id="s06-r{i}">{s}</div>')
    llh = round(ls * 1.12)
    ldivs = "".join(f'<div class="card-line serif" id="s06-l{i}" style="top:{ltop + i * llh}px;font-size:{ls}px;line-height:{llh}px;color:@CANVAS@">{esc(t)}</div>'
                    for i, t in enumerate(lt))
    key_name = "mcp_secrets_notion"
    foot = ("mcp_connections_v1 · SQLite" if v else "Name, address and tools: SQLite, <b>mcp_connections_v1</b>, no secret")
    css = f"""
#s06-bg {{ background: @BROWN@; }}
#s06-all {{ transform-origin: {fmt.cx}px {top + 300}px; }}
#s06-v {{ left: {left}px; top: {top}px; width: {width}px; }}
#s06-v .vault-bar {{ height: {bar_h}px; font-size: {bar_fs}px; }}
#s06-v .vault-bar svg {{ color: @BROWN@; }}
#s06-v .vault-tag {{ font-size: {34 if v else 30}px; }}
#s06-v .vault-body {{ padding: 24px 36px 26px; font-size: {fs}px; line-height: {lhc}px; }}
#s06-v .vault-foot {{ padding: 20px 36px; font-size: {foot_fs}px; }}
"""
    body = f"""
    <div id="s06-bg" class="fill"></div>
    <div id="s06-all" class="fill">
      <div class="vault" id="s06-v">
        <div class="vault-bar">{huge("square-lock02", bar_fs * 1.4)}<b>Secure storage</b><span class="vault-tag">this device</span><span style="flex:1"></span><span class="mono" style="font-variant-ligatures:none">{key_name}</span></div>
        <div class="vault-body">{''.join(rows)}</div>
        <div class="vault-foot" id="s06-foot">{huge("database01", foot_fs * 1.3)}<span>{foot if not v else 'Config: SQLite, <b>mcp_connections_v1</b>'}</span></div>
      </div>
      {ldivs}
    </div>
"""
    js = f"""
  tl.fromTo('#s06-v', {{ opacity: 0, y: 50, scale: 0.97 }}, {{ opacity: 1, y: 0, scale: 1, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s06-v .vl', {{ opacity: 0, x: -12 }}, {{ opacity: 1, x: 0, duration: 0.25, stagger: 0.06, ease: 'power3.out' }}, 0.25);
  tl.fromTo('#s06-foot', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3 }}, 1.2);
  {''.join(f"hfReveal(tl, '#s06-l{i}', {1.5 + i * 0.4:.2f});" for i in range(len(lt)))}
  tl.fromTo('#s06-all', {{ scale: 1 }}, {{ scale: 1.03, duration: {b - a:.2f}, ease: 'none' }}, 0);
"""
    ep.add("s06", a, b, css, body, js)


# =================================================================== s07 the backup: one encrypted blob
def s07_backup(ep, a, b, v, cs):
    fmt = ep.fmt
    uid = mask_uuid_short(S["user_id"])
    ct_cell = esc(S["envelope_text"][:60]) + "…"
    if v:
        cols = [("user_id", "uuid", 300), ("ciphertext", "text", 640)]
        rows = [[uid, ct_cell]]
        left, top = 38, 700
        ex = dict(left=40, top=290, width=1000, ct=280)
        lines, lsize, ltop = ["The backup is", "encrypted on", "your device."], 92, 1225
        title = "ciphertext"
    else:
        cols = [("user_id", "uuid", 300), ("ciphertext", "text", 900), ("updated_at", "timestamptz", 470)]
        rows = [[uid, ct_cell, S["updated_at"]]]
        left, top = 89, 380
        ex = dict(left=160, top=110, width=1600, ct=84 * 4 - 20)
        lines, lsize, ltop = ["The backup is encrypted on your device."], 92, 860
        title = "ciphertext"
    table = ui.db_table("s07-t", "cowork_mcp_connectors", "1 row", cols, rows, mine=0, left=left, top=top)
    more = f"+ {len(ENV['ciphertext']) - ex['ct']:,} more" + ("" if v else " characters")
    viewer = ui.envelope_viewer("s07-ex", title, "text", f"row {uid}" if not v else "", ENV, ex["left"], ex["top"], ex["width"],
                                ct_chars=ex["ct"], more=more)
    lh = round(lsize * 1.1)
    ldivs = "".join(f'<div class="card-line serif" id="s07-l{i}" style="top:{ltop + i * lh}px;font-size:{lsize}px;line-height:{lh}px">{esc(t)}</div>'
                    for i, t in enumerate(lines))
    cx0 = left + 64 + cols[0][2]
    cell = (cx0 + 260, top + 92 + 72 + 40)
    big = ('#s07-t .sb-td, #s07-t .sb-th { font-size: 34px; } #s07-t .sb-th span { font-size: 34px; } #s07-ex .sb-tag, #s07-ex .ex-bar span { font-size: 34px !important; } '
           '#s07-t .sb-name { font-size: 38px; } #s07-t .sb-tag, #s07-t .sb-btn { font-size: 34px; } '
           '#s07-ex .ex-body { font-size: 34px; line-height: 50px; padding: 24px 36px 28px; } '
           '#s07-ex .ex-bar { font-size: 36px; height: 84px; } #s07-t .sb-tr:not(.sb-head) { height: 92px; }') if v else ''
    css = big + f"""
#s07-ex {{ opacity: 0; }}
#s07-sel {{ left: {cx0}px; top: {top + 92 + 72}px; width: {cols[1][2]}px; height: {92 if v else 80}px; }}
"""
    body = f"""
    <div id="s07-tw" class="fill">{table}<div class="sb-sel" id="s07-sel"></div></div>
    {viewer}
    {ldivs}
    {cursor('s07-cur', cs)}
"""
    js = f"""
  tl.fromTo('#s07-t', {{ opacity: 0, y: 40 }}, {{ opacity: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 0);
  tl.fromTo('#s07-cur', {{ x: {fmt.W - 200}, y: {fmt.H + 60} }}, {{ x: {cell[0]}, y: {cell[1]}, duration: 0.85, ease: 'power2.inOut' }}, 0.35);
  hfClick(tl, '#s07-cur', 1.25);
  tl.to('#s07-sel', {{ opacity: 1, duration: 0.08 }}, 1.3);
  hfClick(tl, '#s07-cur', 1.5);
  tl.to('#s07-cur', {{ x: {fmt.W - 120}, y: {fmt.H + 80}, duration: 0.6, ease: 'power3.in' }}, 1.7);
  tl.to('#s07-tw', {{ opacity: 0, y: -40, duration: 0.35, ease: 'power2.in' }}, 1.7);
  tl.fromTo('#s07-ex', {{ opacity: 0, scale: 0.94, y: 60 }}, {{ opacity: 1, scale: 1, y: 0, duration: 0.55, ease: 'expo.out' }}, 1.8);
  tl.fromTo('#s07-ex-b .ex-l', {{ opacity: 0 }}, {{ opacity: 1, duration: 0.2, stagger: 0.08 }}, 1.95);
  tl.fromTo('#s07-ex', {{ y: 0 }}, {{ y: -12, duration: {b - a - 2.4:.2f}, ease: 'none', immediateRender: false }}, 2.4);
  {''.join(f"hfReveal(tl, '#s07-l{i}', {2.3 + i * 0.4:.2f}, 0.09);" for i in range(len(lines)))}
"""
    ep.add("s07", a, b, css, body, js)


if __name__ == "__main__":
    which = sys.argv[1:] or ["16x9", "9x16"]
    if "16x9" in which:
        build(LANDSCAPE, VIDEOS / "chuk-13-connectors")
    if "9x16" in which:
        build(VERTICAL, VIDEOS / "chuk-13-connectors-vertical")
