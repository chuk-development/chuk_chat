# scripts · Signaturen

## scripts/generate_icons.py  (270 Z.)
- L10 `def draw_chat_brain_icon(size, line_width_ratio=0.08, padding_ratio=0.05)`  — Draw a chat bubble with brain icon (Material You style)
- L142 `def generate_android_icons()`  — Generate Android launcher icons (mipmap)
- L161 `def generate_ios_icons()`  — Generate iOS app icons
- L196 `def generate_web_icons()`  — Generate web app icons
- L214 `def generate_adaptive_icon()`  — Generate Android Adaptive Icon (foreground + background)

## scripts/generate_wordmark_svg.py  (185 Z.)
- L30 `REPO = Path(__file__).resolve().parent.parent`
- L31 `OUT = REPO / "assets" / "wordmark.svg"`
- L33 `def find_font(filename, fc_pattern)`  — Locate a Liberation Mono face: known Debian path, else fc-match.
- L50 `BOLD = find_font("LiberationMono-Bold.ttf", "Liberation Mono:bold")`
- L51 `REGULAR = find_font("LiberationMono-Regular.ttf", "Liberation Mono")`
- L53 `WORDMARK = "Chuk Chat"`
- L54 `WORDMARK_PX = 22.0`
- L55 `SLOGAN = "Private and Secure. Always."`
- L56 `SLOGAN_PX = 10.0`
- L57 `SLOGAN_TRACKING_PX = 0.5`
- L58 `SLOGAN_OPACITY = 0.55`
- L62 `WORDMARK_BASELINE_Y = 15.941`
- L65 `def fmt(v, nd=3)`
- L70 `def glyph_ink_bbox(d)`  — Ink bbox of an SVG path in font units (control points; exact enough
- L103 `def line_paths(font_path, text, px, baseline_y, pen_x, tracking=0.0)`  — Outline one text line. Returns (svg path elements, ink bbox).
- L132 `def css_baseline_gap()`  — Distance between the two baselines when Chrome stacks a 22px line
- L147 `def main(): # Line 1 — frozen wordmark. Pen starts at -0.859 so the C's ink hits # x=0 exactly, matching the original hand-frozen file.`

## scripts/release_notes.py  (195 Z.)
- L23 `DEFAULT_REPO = "chuk-development/chuk_chat"`
- L26 `SECTIONS: list[tuple[str, tuple[str, ...]]] = [ ("New Features", ("feat",)), ("Bug Fixes", ("fix",)), ("Performance", ("`
- L39 `COMMIT_RE = re.compile( r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?" r"(?P<breaking>!)?:\s*(?P<subject>.+)$" )`
- L43 `MERGE_RE = re.compile(r"^Merge (branch|remote-tracking branch|pull request)\b")`
- L46 `def run(*args: str) -> str`
- L50 `def tag_exists(tag: str) -> bool`
- L55 `def version_key(tag: str) -> tuple[int, int, int, int, int, str]`  — Sort key for `v1.2.3` and `v1.2.3-pre.4` tags.
- L76 `def previous_tag(tag: str) -> str | None`  — The release tag the changelog starts from.
- L93 `def commit_of(tag: str) -> str`  — The short commit a tag points at, or "" when it cannot be resolved.
- L102 `def collect(rev_range: str) -> list[tuple[str, str]]`  — Every non-merge commit in the range, oldest first.
- L116 `def section_for(subject: str) -> tuple[str, str]`  — Return (section title, cleaned subject) for one commit subject.
- L137 `def render(tag: str, prev: str | None, repo: str) -> str`
- L174 `def main() -> int`
