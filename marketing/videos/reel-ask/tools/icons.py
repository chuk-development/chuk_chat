"""Inline icon helper. Reads the HugeIcons symbols the website ships
(read-only source) and returns stand-alone <svg> elements, so no frame
depends on a shared sprite id in the assembled page."""
import re

SITE = "/home/user/git/chuk.chat/layouts/partials/uc"
_SYM = re.compile(r'<symbol\s+id="([^"]+)"([^>]*)>(.*?)</symbol>', re.S)


def _load():
    icons = {}
    for f in ("app-icons.html", "sprite.html", "onthego.html", "models.html"):
        src = open(f"{SITE}/{f}", encoding="utf-8").read()
        for m in _SYM.finditer(src):
            sid, attrs, inner = m.group(1), m.group(2), m.group(3)
            vb = re.search(r'viewBox="([^"]+)"', attrs)
            rest = re.sub(r'\s*viewBox="[^"]*"', "", attrs).strip()
            icons[sid] = (vb.group(1) if vb else "0 0 24 24", rest, inner.strip())
    return icons


ICONS = _load()


def icon(name, cls=""):
    vb, rest, inner = ICONS[name]
    fa = f" {rest}" if rest else ""
    ca = f' class="{cls}"' if cls else ""
    return f'<svg{ca} viewBox="{vb}"{fa} aria-hidden="true">{inner}</svg>'


if __name__ == "__main__":
    print(len(ICONS), sorted(ICONS)[:80])
