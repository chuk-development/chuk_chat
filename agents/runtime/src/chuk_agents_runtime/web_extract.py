"""Small extractors that keep a ``web_fetch`` result short and useful.

A fetched page goes straight into the prompt, and it stays there for every
later round of the task. The live test of 2026-10-09 showed where that hurts:

- **API JSON** (GitHub, Hugging Face) came back pretty-printed with every
  field. A GitHub commit list is mostly URL templates and nested ids; 40 000
  characters held about ten commits. :func:`render_json` writes compact JSON,
  and ``fields`` keeps only the named keys of each item.
- **Feeds** (arXiv's API, GitHub ``releases.atom``) came back as raw XML.
  :func:`render_feed` turns an Atom or RSS document into one line per entry:
  date, title, link, authors and the start of the summary.
- **Images**: the Markdown view drops every image without an ``alt`` text,
  lazy-loaded ``data-src`` images, ``srcset`` originals, ``og:image`` and the
  JSON-LD product images. :func:`extract_images` lists them all, absolute,
  de-duplicated, with the size the page declares, and moves logos, icons and
  thumbnails to the end, so the model can pick the right product photo
  without a browser round trip.

Every function is pure: text in, text or rows out. Malformed input never
raises; the caller falls back to the plain text.
"""

from __future__ import annotations

import json
import re
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin, urlsplit
from xml.etree import ElementTree

# -- JSON ---------------------------------------------------------------------

#: A projected string value is cut here. ``fields`` is for the facts (dates,
#: titles, ids), not for long bodies.
FIELD_STRING_CAP = 600
#: Wrapper keys under which an API returns its list of items
#: (GitHub search: ``items``).
_LIST_KEYS = ("items", "results", "data", "models", "papers", "entries", "releases")


def _resolve(item: Any, path: str) -> tuple[bool, Any]:
    """Follow a dotted path. A number picks a list item; a name on a list
    takes that key of every item (``product.variants.sku`` gives all SKUs)."""
    return _follow(item, path.split("."))


def _follow(current: Any, parts: list[str]) -> tuple[bool, Any]:
    for index, part in enumerate(parts):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit() and int(part) < len(current):
            current = current[int(part)]
        elif isinstance(current, list):
            values = []
            for element in current:
                found, value = _follow(element, parts[index:])
                if found:
                    values.append(value)
            return bool(values), values
        else:
            return False, None
    return True, current


def _cap(value: Any) -> Any:
    if isinstance(value, str) and len(value) > FIELD_STRING_CAP:
        return value[:FIELD_STRING_CAP] + "…"
    return value


def _pick(item: Any, fields: list[str]) -> Any:
    if not isinstance(item, dict):
        return item
    out: dict[str, Any] = {}
    for path in fields:
        found, value = _resolve(item, path)
        if found:
            out[path] = _cap(value)
    return out


def project(data: Any, fields: list[str]) -> Any:
    """Keep only ``fields`` (dotted paths, e.g. ``commit.author.date``).

    A list is projected item by item. An object is projected itself, unless
    none of the fields is in it and it wraps one list of items (``{"items":
    [...]}``): then that list is projected and the other plain values stay.
    """
    if not fields:
        return data
    if isinstance(data, list):
        return [_pick(item, fields) for item in data]
    if not isinstance(data, dict):
        return data
    picked = _pick(data, fields)
    if picked:
        return picked
    for key in _LIST_KEYS + tuple(k for k in data if k not in _LIST_KEYS):
        value = data.get(key)
        if isinstance(value, list) and value and isinstance(value[0], dict):
            rest = {
                k: v for k, v in data.items()
                if k != key and isinstance(v, (str, int, float, bool)) and v is not None
            }
            return {**rest, key: [_pick(item, fields) for item in value]}
    return picked


def render_json(text: str, fields: list[str] | None = None) -> str:
    """Compact JSON, one list item per line. Invalid JSON is passed through."""
    try:
        data = json.loads(text)
    except (ValueError, TypeError):
        return text
    if fields:
        data = project(data, fields)

    def dump(value: Any) -> str:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    if isinstance(data, list):
        return "[\n" + ",\n".join(dump(item) for item in data) + "\n]"
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, list) and value and isinstance(value[0], dict):
                head = {k: v for k, v in data.items() if k != key}
                lines = ",\n".join(dump(item) for item in value)
                prefix = dump(head)[:-1] + ("," if head else "")
                return f'{prefix}"{key}":[\n{lines}\n]}}'
    return dump(data)


def parse_fields(raw: Any) -> list[str]:
    """``fields`` as the model sends it: a list, or one comma-separated string."""
    if isinstance(raw, str) and raw.strip().startswith("["):
        try:
            raw = json.loads(raw)
        except ValueError:
            raw = raw.strip().strip("[]")
    if isinstance(raw, str):
        items = [item.strip().strip("'\"") for item in raw.split(",")]
    elif isinstance(raw, (list, tuple)):
        items = [str(x) for x in raw]
    else:
        return []
    return [item.strip() for item in items if item and item.strip()][:40]


# -- feeds (Atom, RSS) ----------------------------------------------------------

FEED_SUMMARY_CAP = 300
FEED_SHORT_SUMMARY_CAP = 160
FEED_MAX_ENTRIES = 100
_TAGS_RE = re.compile(r"<[^>]+>")
_SPACE_RE = re.compile(r"\s+")


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _child(element: ElementTree.Element, name: str) -> ElementTree.Element | None:
    for child in element:
        if _local(child.tag) == name:
            return child
    return None


def _children(element: ElementTree.Element, name: str) -> list[ElementTree.Element]:
    return [child for child in element if _local(child.tag) == name]


def _text(element: ElementTree.Element | None) -> str:
    if element is None:
        return ""
    raw = "".join(element.itertext())
    return _SPACE_RE.sub(" ", _TAGS_RE.sub(" ", raw)).strip()


def _entry_line(entry: ElementTree.Element, summary_cap: int = 300) -> str:
    title = _text(_child(entry, "title"))
    link = ""
    for candidate in _children(entry, "link"):
        href = candidate.get("href") or (candidate.text or "").strip()
        if href and candidate.get("rel", "alternate") == "alternate":
            link = href
            break
        link = link or href
    if not link:
        ident = _text(_child(entry, "id"))
        link = ident if ident.startswith("http") else ""
    date = ""
    for name in ("published", "pubDate", "date", "updated"):
        date = _text(_child(entry, name))
        if date:
            break
    updated = _text(_child(entry, "updated"))
    authors = [
        _text(_child(author, "name")) or _text(author)
        for author in _children(entry, "author") + _children(entry, "creator")
    ]
    authors = [a for a in authors if a]
    summary = _text(_child(entry, "summary")) or _text(_child(entry, "description")) or _text(
        _child(entry, "content")
    )
    head = " | ".join(part for part in (date, title, link) if part)
    if updated and updated != date:
        head += f" | updated {updated}"
    if authors:
        keep = 4 if summary_cap >= FEED_SUMMARY_CAP else 2
        shown = ", ".join(authors[:keep]) + (f" +{len(authors) - keep}" if len(authors) > keep else "")
        head += f" | {shown}"
    line = f"- {head}"
    if summary:
        cut = summary[:summary_cap] + ("…" if len(summary) > summary_cap else "")
        line += f"\n  {cut}"
    return line


def render_feed(text: str) -> str | None:
    """An Atom or RSS document as one short line per entry, newest as given.
    ``None`` when ``text`` is not a feed (the caller keeps the raw text)."""
    head = text.lstrip()[:2000]
    if "<feed" not in head and "<rss" not in head and "<rdf:RDF" not in head:
        return None
    try:
        root = ElementTree.fromstring(text.encode("utf-8") if isinstance(text, str) else text)
    except (ElementTree.ParseError, ValueError):
        return None
    kind = _local(root.tag)
    if kind == "feed":
        channel, entries = root, _children(root, "entry")
    elif kind == "rss":
        channel = _child(root, "channel")
        if channel is None:
            return None
        entries = _children(channel, "item")
    elif kind == "RDF":
        found = _child(root, "channel")
        channel = found if found is not None else root
        entries = _children(root, "item")
    else:
        return None
    title = _text(_child(channel, "title"))
    total = _text(_child(root, "totalResults"))
    lines = [f"Feed: {title}" if title else "Feed"]
    lines[0] += f" ({len(entries)} entries" + (f" of {total} results" if total else "") + ")"
    # A long result list (an arXiv query over a week) keeps every entry and
    # cuts the summaries shorter instead.
    cap = FEED_SUMMARY_CAP if len(entries) <= 15 else FEED_SHORT_SUMMARY_CAP
    for entry in entries[:FEED_MAX_ENTRIES]:
        lines.append(_entry_line(entry, cap))
    if not entries:
        lines.append("(no entries)")
    return "\n".join(lines)


# -- images -------------------------------------------------------------------

MAX_IMAGES = 40
#: With fewer photos than this, the icons are listed too (up to
#: :data:`MIN_ICONS_SHOWN`), so a page of only small pictures is not empty.
MIN_PHOTOS = 5
MIN_ICONS_SHOWN = 10
#: Below this many pixels on the longer side (when the page says) an image
#: is a thumbnail or an icon, not a product photo.
SMALL_IMAGE_PX = 300
_ICON_RE = re.compile(
    r"(logo|icon|sprite|favicon|placeholder|spinner|loader|badge|flag|avatar|"
    r"pixel|blank|spacer|1x1|rating|stars?[-_.]|payment|social|thumb)",
    re.IGNORECASE,
)
_IMAGE_EXT_RE = re.compile(r"\.(jpe?g|png|webp|avif|gif|bmp|tiff?)(?:$|[?#])", re.IGNORECASE)
_SIZE_IN_URL_RE = re.compile(r"(?:[_\-/=x](\d{2,4})x(\d{2,4})(?:[_\-./?]|$))|(?:[?&](?:w|width)=(\d{2,4}))")


def _largest_from_srcset(srcset: str) -> tuple[str, int | None]:
    """The biggest candidate of a ``srcset`` and its width when the
    descriptor is a ``w`` width (an ``x`` density says nothing about pixels)."""
    best, best_rank, best_width = "", -1.0, None
    for candidate in srcset.split(","):
        parts = candidate.strip().split()
        if not parts:
            continue
        rank, width = 0.0, None
        if len(parts) > 1:
            descriptor = parts[1].lower()
            try:
                if descriptor.endswith("w"):
                    width = int(float(descriptor[:-1]))
                    rank = float(width)
                elif descriptor.endswith("x"):
                    rank = float(descriptor[:-1])
            except ValueError:
                pass
        if rank > best_rank:
            best, best_rank, best_width = parts[0], rank, width
    return best, best_width


def _int(value: str | None) -> int | None:
    try:
        number = int(float(str(value).strip().rstrip("px")))
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


class _ImageCollector(HTMLParser):
    def __init__(self, base_url: str) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.found: list[dict] = []
        self.title = ""
        self._in_title = False
        self._ld_depth = 0
        self._ld_chunks: list[str] = []
        self.ld_blocks: list[str] = []
        #: Price facts from meta and microdata tags (``og:price:amount``,
        #: ``itemprop="price"``), first value per key.
        self.meta: dict[str, str] = {}

    def _add(self, url: str, source: str, *, alt: str = "", width: int | None = None,
             height: int | None = None) -> None:
        url = (url or "").strip()
        if not url or url.startswith(("data:", "blob:", "javascript:")):
            return
        try:
            absolute = urljoin(self.base_url, url) if self.base_url else url
        except ValueError:
            return
        if urlsplit(absolute).scheme not in ("http", "https"):
            return
        self.found.append(
            {"url": absolute, "alt": alt.strip()[:160], "width": width, "height": height,
             "source": source}
        )

    def handle_starttag(self, tag: str, attrs: list) -> None:
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "title":
            self._in_title = True
        elif tag == "img":
            alt = a.get("alt") or a.get("title") or ""
            width, height = _int(a.get("width")), _int(a.get("height"))
            srcset = a.get("srcset") or a.get("data-srcset") or ""
            if srcset:
                url, w = _largest_from_srcset(srcset)
                self._add(url, "img srcset", alt=alt, width=w or width,
                          height=height if not w else None)
            for key in ("data-zoom-image", "data-large_image", "data-full", "data-original",
                        "data-src", "data-lazy-src", "src"):
                if a.get(key):
                    self._add(a[key], f"img {key}" if key != "src" else "img",
                              alt=alt, width=width, height=height)
                    break
        elif tag == "source" and (a.get("srcset") or a.get("data-srcset")):
            url, w = _largest_from_srcset(a.get("srcset") or a.get("data-srcset"))
            self._add(url, "picture source", width=w)
        if tag in ("meta", "span", "div", "link", "data") and a.get("itemprop"):
            prop = a["itemprop"].lower()
            value = a.get("content") or a.get("value") or a.get("href") or ""
            if prop in ("price", "pricecurrency", "availability", "sku", "mpn", "gtin13", "name") and value:
                self.meta.setdefault(f"itemprop:{prop}", value.strip())
        if tag == "meta":
            prop = (a.get("property") or a.get("name") or "").lower()
            if prop in ("og:price:amount", "product:price:amount", "og:price:currency",
                        "product:price:currency", "product:availability", "og:availability"):
                self.meta.setdefault(prop, (a.get("content") or "").strip())
        if tag == "meta":
            key = (a.get("property") or a.get("name") or "").lower()
            if key in ("og:image", "og:image:url", "og:image:secure_url", "twitter:image",
                       "twitter:image:src"):
                self._add(a.get("content", ""), key)
        elif tag == "link" and "image_src" in a.get("rel", "").lower():
            self._add(a.get("href", ""), "link image_src")
        elif tag == "a" and _IMAGE_EXT_RE.search(a.get("href", "")):
            self._add(a.get("href", ""), "link to image file", alt=a.get("title", ""))
        elif tag == "script" and "ld+json" in a.get("type", "").lower():
            self._ld_depth += 1
            self._ld_chunks = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        elif tag == "script" and self._ld_depth:
            self._ld_depth -= 1
            self.ld_blocks.append("".join(self._ld_chunks))
            self._ld_chunks = []

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title = (self.title + data).strip()
        elif self._ld_depth:
            self._ld_chunks.append(data)


def _ld_images(block: str) -> list[tuple[str, str]]:
    """``(url, product name)`` pairs from one JSON-LD block."""
    try:
        data = json.loads(block)
    except (ValueError, TypeError):
        return []
    out: list[tuple[str, str]] = []

    def walk(node: Any, name: str) -> None:
        if isinstance(node, list):
            for item in node:
                walk(item, name)
            return
        if not isinstance(node, dict):
            return
        own = node.get("name") if isinstance(node.get("name"), str) else name
        image = node.get("image")
        for value in image if isinstance(image, list) else [image]:
            if isinstance(value, str):
                out.append((value, own or ""))
            elif isinstance(value, dict):
                url = value.get("contentUrl") or value.get("url")
                if isinstance(url, str):
                    out.append((url, own or ""))
        for key, value in node.items():
            if key != "image" and isinstance(value, (dict, list)):
                walk(value, own or "")

    walk(data, "")
    return out


def _price(value: Any) -> str | None:
    """A price as text, or ``None`` for a missing, zero or unreadable one.
    A shop that shows "0.00" or "auf Anfrage" has no price for the model."""
    if value is None or isinstance(value, bool):
        return None
    text = str(value).strip().replace("\u00a0", "")
    number = text.replace(",", ".") if text.count(",") == 1 and "." not in text else text.replace(",", "")
    try:
        amount = float(number)
    except ValueError:
        return None
    return text if amount > 0 else None


def _short(value: Any) -> str | None:
    if isinstance(value, dict):
        value = value.get("name") or value.get("@id")
    if isinstance(value, list):
        value = value[0] if value else None
    if value is None or isinstance(value, (dict, list)):
        return None
    text = str(value).strip()
    return text.rsplit("/", 1)[-1] if text.startswith("http") and "schema.org" in text else text or None


def product_facts(ld_blocks: list[str], meta: dict[str, str]) -> dict:
    """Name, part numbers, price and stock of the page's product, from
    JSON-LD ``Product`` first, then from meta and microdata tags. A missing
    or zero price is left out: never report 0.00 as a price."""
    found: dict[str, Any] = {}

    def offers_of(node: dict) -> list[dict]:
        offers = node.get("offers")
        if isinstance(offers, dict):
            inner = offers.get("offers")
            return [o for o in inner if isinstance(o, dict)] if isinstance(inner, list) else [offers]
        if isinstance(offers, list):
            return [o for o in offers if isinstance(o, dict)]
        return []

    def walk(node: Any) -> None:
        if found or not isinstance(node, (dict, list)):
            return
        if isinstance(node, list):
            for item in node:
                walk(item)
            return
        kind = node.get("@type")
        kinds = kind if isinstance(kind, list) else [kind]
        if "Product" in kinds:
            facts = {
                "name": _short(node.get("name")),
                "brand": _short(node.get("brand")),
                "sku": _short(node.get("sku")),
                "mpn": _short(node.get("mpn")),
                "gtin": _short(node.get("gtin13") or node.get("gtin") or node.get("gtin12")),
            }
            for offer in offers_of(node):
                price = _price(offer.get("price") or offer.get("lowPrice"))
                if price:
                    facts["price"] = price
                    facts["currency"] = _short(offer.get("priceCurrency"))
                    facts["availability"] = _short(offer.get("availability"))
                    break
            found.update({k: v for k, v in facts.items() if v})
            return
        for value in node.values():
            walk(value)

    for block in ld_blocks:
        try:
            walk(json.loads(block))
        except (ValueError, TypeError):
            continue
        if found:
            break
    if "price" not in found:
        price = _price(meta.get("product:price:amount") or meta.get("og:price:amount")
                       or meta.get("itemprop:price"))
        if price:
            found["price"] = price
            currency = (meta.get("product:price:currency") or meta.get("og:price:currency")
                        or meta.get("itemprop:pricecurrency"))
            if currency:
                found["currency"] = currency
    for key, meta_key in (("availability", "itemprop:availability"), ("sku", "itemprop:sku"),
                          ("mpn", "itemprop:mpn"), ("gtin", "itemprop:gtin13")):
        if key not in found and meta.get(meta_key):
            found[key] = _short(meta[meta_key])
    if found and "price" not in found:
        found["price"] = None  # the page shows no usable price
    return found


def _size_hint(url: str) -> int | None:
    match = _SIZE_IN_URL_RE.search(url)
    if not match:
        return None
    numbers = [int(n) for n in match.groups() if n]
    return max(numbers) if numbers else None


def extract_images(html: str, base_url: str = "") -> dict:
    """Every image a page names, as rows: ``url``, ``alt``, ``width`` /
    ``height`` (when the page or the URL says), ``source`` (where on the page
    it was found) and ``likely_icon``. Product photos first: page-level images
    (``og:image``, JSON-LD) and big ones lead, icons and thumbnails go last.
    The result is capped at :data:`MAX_IMAGES` rows."""
    collector = _ImageCollector(base_url)
    try:
        collector.feed(html)
        collector.close()
    except Exception:  # noqa: BLE001, S110 — a broken page still yields what was read
        pass
    for block in collector.ld_blocks:
        for url, name in _ld_images(block):
            collector._add(url, "json-ld", alt=name)

    merged: dict[str, dict] = {}
    order: list[str] = []
    for row in collector.found:
        key = _image_key(row["url"])
        if key not in merged:
            merged[key] = dict(row)
            order.append(key)
            continue
        kept = merged[key]
        # The same picture in another size: keep the original (a URL without
        # a size parameter), then the bigger one, then https.
        if _preference(row) > _preference(kept):
            kept["url"] = row["url"]
            kept["width"], kept["height"] = row.get("width"), row.get("height")
        for field in ("alt", "width", "height"):
            if not kept.get(field) and row.get(field):
                kept[field] = row[field]
        if row["source"] not in kept["source"]:
            kept["source"] += f", {row['source']}"

    rows: list[dict] = []
    for key in order:
        row = merged[key]
        url = row["url"]
        size = _declared(row) or _size_hint(url)
        path = urlsplit(url).path.lower()
        icon = bool(
            _ICON_RE.search(path)
            or path.endswith((".svg", ".ico", ".gif"))
            or (size is not None and size < SMALL_IMAGE_PX)
        )
        clean = {"url": url}
        if row.get("alt"):
            clean["alt"] = row["alt"]
        if row.get("width"):
            clean["width"] = row["width"]
        if row.get("height"):
            clean["height"] = row["height"]
        clean["source"] = row["source"]
        if icon:
            clean["likely_icon"] = True
        rows.append(clean)

    def rank(item: tuple[int, dict]) -> tuple:
        index, row = item
        page_level = any(s in row["source"] for s in ("og:image", "json-ld", "twitter:image"))
        size = max(row.get("width") or 0, row.get("height") or 0)
        return (bool(row.get("likely_icon")), not page_level, -size, index)

    ranked = [row for _, row in sorted(enumerate(rows), key=rank)]
    photos = [row for row in ranked if not row.get("likely_icon")]
    icons = [row for row in ranked if row.get("likely_icon")]
    # Icons cost tokens and are almost never the answer: they are listed
    # only when the page has hardly any other picture.
    shown = photos[:MAX_IMAGES] if len(photos) >= MIN_PHOTOS else (photos + icons)[:MIN_ICONS_SHOWN + len(photos)]
    result = {
        "title": collector.title[:200],
        "images": shown,
        "total": len(ranked),
        "likely_icons": len(icons),
        "icons_listed": len(photos) < MIN_PHOTOS,
    }
    product = product_facts(collector.ld_blocks, collector.meta)
    if product:
        result["product"] = product
    return result


#: Query keys that only pick a size, a crop or a cache version of a picture.
_SIZE_KEYS = frozenset(
    {"width", "height", "w", "h", "crop", "fit", "quality", "q", "format", "fm", "auto",
     "v", "ts", "dpr", "resize", "scale"}
)


def _image_key(url: str) -> str:
    """One key per picture: scheme dropped, size and cache parameters dropped."""
    parts = urlsplit(url)
    query = "&".join(
        sorted(
            pair for pair in parts.query.split("&")
            if pair and pair.split("=", 1)[0].lower() not in _SIZE_KEYS
        )
    )
    return f"{parts.netloc.lower()}{parts.path}?{query}"


def _sized(url: str) -> bool:
    """True when the URL itself asks for a size (``width=300``, ``_300x300``)."""
    parts = urlsplit(url)
    keys = {pair.split("=", 1)[0].lower() for pair in parts.query.split("&") if pair}
    return bool(keys & {"width", "height", "w", "h", "resize", "scale"}) or _size_hint(url) is not None


def _preference(row: dict) -> tuple:
    return (not _sized(row["url"]), _declared(row), row["url"].startswith("https:"))


def _declared(row: dict) -> int:
    return max(row.get("width") or 0, row.get("height") or 0) or (_size_hint(row["url"]) or 0)


# -- grep (page source and script files) ---------------------------------------

#: The whole ``grep`` result is cut here (snippet text, all sources). A grep
#: is a pointer into a page, not a second copy of it.
GREP_MAX_CHARS = 4_000
#: Characters before and after a match in a long (minified) line. The text
#: before is longer: a data record names its item first, its fields after
#: (``{model:"turn-1-mini",display_name:...,submitted:"2026-10-05"``).
GREP_BEFORE = 100
GREP_AFTER = 50
#: A line up to this long is returned whole.
GREP_LINE = 240
GREP_MAX_TERMS = 10
_GREP_SPLIT_RE = re.compile(r"[|,\n]+|\s{2,}")
_SCRIPT_SRC_RE = re.compile(r"""<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["']""", re.IGNORECASE)


def grep_terms(text: str) -> list[str]:
    """The words of a ``grep`` argument. ``|`` and ``,`` separate words (the
    model writes regex-style alternatives); one space does not, so a phrase
    such as ``Submitted October`` stays one term. Regex characters are kept
    as plain text."""
    terms: list[str] = []
    for raw in _GREP_SPLIT_RE.split(str(text or "")):
        term = raw.strip().strip("()^$\"'")
        if term and term.lower() not in (t.lower() for t in terms):
            terms.append(term[:100])
    return terms[:GREP_MAX_TERMS]


def compile_grep(text: str) -> re.Pattern[str] | None:
    """The ``grep`` argument as one case-insensitive pattern of literal words.

    Each word must start a word (``date`` finds ``date`` and ``dateCreated``,
    not ``update``): in a script bundle the word inside other words is noise
    that hid the real data in the live test of 2026-10-09. Each word is
    escaped, so a pattern can never backtrack on a 300 KB minified file."""
    terms = grep_terms(text)
    if not terms:
        return None
    alternatives = "|".join(re.escape(term) for term in terms)
    return re.compile(rf"(?<![A-Za-z0-9_])(?:{alternatives})", re.IGNORECASE)


def script_urls(html: str, base_url: str) -> list[str]:
    """The ``<script src>`` files of a page on the page's own host, absolute,
    in page order, without duplicates. Other hosts (analytics, CDNs of third
    parties) do not carry the page's data."""
    host = urlsplit(base_url).netloc.lower()
    seen: list[str] = []
    for match in _SCRIPT_SRC_RE.finditer(html):
        try:
            url = urljoin(base_url, match.group(1).strip())
        except ValueError:
            continue
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or parts.netloc.lower() != host:
            continue
        if url not in seen:
            seen.append(url)
    return seen


def _window(text: str, start: int, end: int) -> tuple[str, int]:
    """The line around a match when the line is short, else a window of
    characters around it. Returns the snippet and where it ends."""
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    line_end = len(text) if line_end < 0 else line_end
    if line_end - line_start <= GREP_LINE:
        return text[line_start:line_end], line_end
    left = max(line_start, start - GREP_BEFORE)
    right = min(line_end, end + GREP_AFTER)
    return text[left:right], right


_DATE_RE = re.compile(
    r"\b(?:19|20)\d\d-[01]\d-[0-3]\d|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? \d{1,2},? (?:19|20)\d\d"
    r"|\b\d{1,2}\.\s?\d{1,2}\.\s?(?:19|20)\d\d"
)
#: At most this many matches are cut into snippets; the rest are counted.
GREP_MAX_CANDIDATES = 400


def grep_sources(sources: list[tuple[str, str]], pattern: re.Pattern[str]) -> dict:
    """Short snippets around the matches, grouped by source, the whole
    result cut at :data:`GREP_MAX_CHARS`.

    Which snippets fit: first the ones that carry a date (a grep looks for
    the facts of an entry, and its date is the one the model gets wrong
    without it), then the ones of rare words: a word that matches 12 times
    (``submitted``) is the data, a word that matches 400 times (``date`` in a
    framework bundle) is noise and must not use up the space. ``counts``
    says how often each word matched, so the model can narrow the search."""
    counts: dict[str, int] = {}
    candidates: list[tuple[str, int, int, int]] = []  # word, source, start, end
    for index, (_url, text) in enumerate(sources):
        for match in pattern.finditer(text):
            word = match.group(0).lower()
            counts[word] = counts.get(word, 0) + 1
            if len(candidates) < GREP_MAX_CANDIDATES * 4:
                candidates.append((word, index, match.start(), match.end()))

    snippets: list[tuple[bool, int, int, int, int, str]] = []
    taken: dict[int, list[tuple[int, int]]] = {}  # source -> snippet spans
    # Rare words first, so a flood of one common word cannot use up the
    # candidate budget before the rare ones get their snippets.
    for word, index, start, end in sorted(candidates, key=lambda c: (counts[c[0]], c[1], c[2])):
        if any(left <= start < right for left, right in taken.get(index, ())):
            continue  # inside a snippet already cut
        text, stop = _window(sources[index][1], start, end)
        taken.setdefault(index, []).append((stop - len(text), stop))
        text = _SPACE_RE.sub(" ", text).strip()
        if text:
            snippets.append((not _DATE_RE.search(text), counts[word], index, start, stop, text))
        if len(snippets) >= GREP_MAX_CANDIDATES:
            break

    chosen: dict[int, list[tuple[int, str]]] = {}
    seen: set[str] = set()
    used = 0
    left_out = 0
    for _no_date, _count, index, start, _stop, text in sorted(snippets):
        if text in seen:
            continue
        if used + len(text) > GREP_MAX_CHARS:
            left_out += 1
            continue
        seen.add(text)
        used += len(text)
        chosen.setdefault(index, []).append((start, text))
    grouped = [
        {"url": sources[index][0], "snippets": [t for _, t in sorted(items)]}
        for index, items in sorted(chosen.items())
    ]
    result: dict[str, Any] = {
        "matches": grouped,
        "counts": counts,
        "files_searched": len(sources),
    }
    if left_out:
        result["cut"] = (
            f"{left_out} more snippets did not fit in {GREP_MAX_CHARS} characters; "
            "search for a rarer word"
        )
    return result


__all__ = [
    "compile_grep",
    "extract_images",
    "grep_sources",
    "grep_terms",
    "parse_fields",
    "product_facts",
    "project",
    "render_feed",
    "render_json",
    "script_urls",
]
