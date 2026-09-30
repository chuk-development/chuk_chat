"""Turn one reel data file into a HyperFrames composition.

  python3 tools/build.py <slug>      reels/<slug>.json -> compositions/ask-<slug>.html (+ index.html)
  python3 tools/build.py --all       every reels/*.json

index.html is a copy of the last reel built (for `npx hyperframes check`,
`snapshot` and the Studio preview). The render uses compositions/ask-<slug>.html.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import cards  # noqa: E402
from kit import esc, logo, page, status_bar  # noqa: E402
from surfaces import assistant_surface, chat_surface  # noqa: E402

# Beat grid of the music bed (100 BPM, bed starts at 38.43 s of the track, on the drop):
# beats at about 0.07 + 0.6 k. Phone lands, answer, card and swipe sit on beats.
DEFAULTS = {
    "duration": 12.0,
    "title_out": 2.0,
    "phone_in": 2.05, "phone_land": 2.445,
    "bubble": 2.745,
    "meta": 3.1,
    "steps": 3.4, "step_gap": 0.42,
    "answer": 4.845,
    "wps": 16.0,          # answer words per second
    "card_min": 6.045,
    "swipe": 9.045, "swipe_d": 0.45,
    "tag": 11.2,
    # assistant overlay
    "as_open": 2.745, "as_heard": 2.9, "heard_wps": 11.0, "as_work": 4.05, "as_tool_gap": 0.35,
    "as_places": 4.845, "as_nav": 6.3, "as_nav_ok": 6.85, "as_act": 7.245,
}

REQUIRED = ["slug", "title", "prompt", "answer", "card"]


def title_html(spec):
    """'Ask Chuk Chat to|[turn your notes]|[into an invoice]': | = line break, [..] = coral."""
    lines = []
    for ln in spec.split("|"):
        out, hl = [], False
        for tok in re.findall(r"\[|\]|[^\s\[\]]+", ln):
            if tok == "[":
                hl = True
            elif tok == "]":
                hl = False
            else:
                out.append(f'<span class="wd{" hl" if hl else ""}">{esc(tok)}</span>')
        lines.append(f'<span class="ln"><span class="lw">{" ".join(out)}</span></span>')
    return "".join(lines)


_INTER = None


def title_px(spec, base=110.0, max_w=960.0, tracking=-0.03):
    """Estimate the fitted title size (the runtime fits the widest line into 960 px)."""
    global _INTER
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    if _INTER is None:
        f = TTFont(os.path.join(ROOT, "assets", "fonts", "Inter-subset.woff2"))
        _INTER = instancer.instantiateVariableFont(f, {"wght": 760, "opsz": 32})
    cmap, hmtx, upm = _INTER.getBestCmap(), _INTER["hmtx"], _INTER["head"].unitsPerEm
    widest = 0.0
    for ln in spec.replace("[", "").replace("]", "").split("|"):
        adv = sum(hmtx[cmap[ord(c)]][0] for c in ln if ord(c) in cmap)
        widest = max(widest, adv / upm * base + tracking * base * (len(ln) - 1))
    return base if widest <= max_w else base * max_w / widest


def word_count(text):
    return len(re.findall(r"\S+", text.replace("**", "")))


def build(slug):
    path = os.path.join(ROOT, "reels", f"{slug}.json")
    reel = json.load(open(path, encoding="utf-8"))
    missing = [k for k in REQUIRED if k not in reel]
    if missing:
        raise SystemExit(f"{path}: missing {missing}")
    card = reel["card"]
    ctype = cards.TYPES.get(card["type"])
    if not ctype:
        raise SystemExit(f"{path}: unknown card.type {card['type']!r} (known: {sorted(cards.TYPES)})")

    surface = reel.get("surface", "chat")
    T = dict(DEFAULTS)
    T.update(reel.get("timing", {}))
    T["fold_steps"] = bool(reel.get("fold_steps", True))
    n = word_count(reel["answer"])
    if surface == "chat":
        answer_end = T["answer"] + 0.05 + n / T["wps"]
        if "card" not in reel.get("timing", {}):
            T["card"] = round(max(T["card_min"], answer_end + 0.12), 3)
    else:
        T["card"] = T["as_places"]
        answer_end = T["as_act"] + 0.1 + n / T["wps"]
    T["full"] = round(T["swipe"] + T["swipe_d"], 3)
    T["tap"] = round(T["swipe"] - 0.32, 3)
    dur = float(T["duration"])
    if answer_end > T["swipe"] - 0.6:
        print(f"warning: {slug}: answer ends at {answer_end:.2f}s, close to the swipe at {T['swipe']}s", file=sys.stderr)

    tpx = title_px(reel["title"])
    if tpx < 96:
        print(f"warning: {slug}: title fits at {tpx:.0f}px (< 96). Break the widest line with |.", file=sys.stderr)
    card_chat = ctype.chat(card)
    card_full = ctype.full(card)
    if surface == "chat":
        s_html, s_css, s_js = chat_surface(reel, card_chat)
        tap_js = "  if (TAP) tapAt(TAP, T.tap, TAPR);\n"
    elif surface == "assistant":
        s_html, s_css, s_js = assistant_surface(reel, card_chat)
        tap_js = ""
    else:
        raise SystemExit(f"{path}: unknown surface {surface!r}")

    body = f"""      <div id="reel" class="clip fill" data-start="0" data-duration="{dur}" data-track-index="0">
        <div class="fill ground"></div><!--MBFILTER-->
        <div class="tc"><div class="tc-in">{logo("tc-logo", "#E8E4D8")}<h1 class="tt">{title_html(reel["title"])}</h1></div></div>
        <div class="phone"><div class="scr">
          {s_html}
          <div class="dim"></div>
          {card_full}
          {status_bar(reel.get("clock", "12:00"))}
          <span class="hbar"></span>
          <span class="tap"></span>
        </div></div>
        <div class="tag">{logo("tag-logo", "#E8E4D8")}<span>chuk.chat</span></div>
      </div>"""
    js = s_js + ctype.js(card) + tap_js
    css = s_css + ctype.css
    name = f"Ask Chuk Chat - {slug}"
    os.makedirs(os.path.join(ROOT, "compositions"), exist_ok=True)
    comp = os.path.join(ROOT, "compositions", f"ask-{slug}.html")
    with open(comp, "w", encoding="utf-8") as f:
        f.write(page(name, T, css, body, js, dur, "assets/"))
    with open(os.path.join(ROOT, "index.html"), "w", encoding="utf-8") as f:
        f.write(page(name, T, css, body, js, dur, "assets/"))
    print(f"{slug}: {comp} ({dur:.1f}s, title ~{tpx:.0f}px, card {card['type']}, surface {surface}, card at {T['card']}s, answer ends {answer_end:.2f}s)")
    return comp


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    slugs = ([os.path.splitext(os.path.basename(p))[0] for p in sorted(glob.glob(os.path.join(ROOT, "reels", "*.json")))]
             if args == ["--all"] else args)
    for s in slugs:
        build(s)


if __name__ == "__main__":
    main()
