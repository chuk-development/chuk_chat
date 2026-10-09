"""The ``web_fetch`` extractors: short JSON, feeds as lines, page images.

Live test 2026-10-09: research read GitHub through curl pipes, and the image
job needed 17 model rounds. These pin what makes the plain tool good enough
for both: compact JSON with ``fields``, one line per feed entry, and a list
of a page's images with the icons moved out.
"""

from __future__ import annotations

import json

import httpx

from chuk_agents_runtime import make_web_fetch_handler
from chuk_agents_runtime.web_extract import (
    extract_images,
    parse_fields,
    project,
    render_feed,
    render_json,
)
from chuk_agents_runtime.web_fetch import BOT_CHECK_HINT, WEB_FETCH_SCHEMA

COMMITS = [
    {
        "sha": "abc",
        "node_id": "x" * 40,
        "commit": {"author": {"name": "A", "date": "2026-10-06T10:00:00Z"}, "message": "Fix it"},
        "html_url": "https://github.com/o/r/commit/abc",
        "url": "https://api.github.com/repos/o/r/commits/abc",
    },
    {
        "sha": "def",
        "commit": {"author": {"name": "B", "date": "2026-10-01T09:00:00Z"}, "message": "Add"},
        "html_url": "https://github.com/o/r/commit/def",
    },
]


# -- JSON -----------------------------------------------------------------------


def test_fields_keep_only_the_named_dotted_keys_of_each_item():
    out = project(COMMITS, ["sha", "commit.author.date", "html_url", "missing.key"])
    assert out == [
        {"sha": "abc", "commit.author.date": "2026-10-06T10:00:00Z",
         "html_url": "https://github.com/o/r/commit/abc"},
        {"sha": "def", "commit.author.date": "2026-10-01T09:00:00Z",
         "html_url": "https://github.com/o/r/commit/def"},
    ]


def test_fields_reach_into_a_wrapped_item_list():
    data = {"total_count": 2, "incomplete_results": False, "items": COMMITS}
    out = project(data, ["sha"])
    assert out == {"total_count": 2, "incomplete_results": False,
                   "items": [{"sha": "abc"}, {"sha": "def"}]}


def test_render_json_is_compact_with_one_item_per_line():
    text = render_json(json.dumps(COMMITS), ["sha", "commit.message"])
    assert text.splitlines() == [
        "[",
        '{"sha":"abc","commit.message":"Fix it"},',
        '{"sha":"def","commit.message":"Add"}',
        "]",
    ]
    assert json.loads(text) == [
        {"sha": "abc", "commit.message": "Fix it"},
        {"sha": "def", "commit.message": "Add"},
    ]


def test_render_json_without_fields_still_drops_the_indent():
    text = render_json('{"b": 1, "a": [2]}')
    assert text == '{"b":1,"a":[2]}'
    assert render_json("not json") == "not json"


def test_a_long_projected_string_is_cut():
    out = project([{"body": "x" * 5_000}], ["body"])
    assert len(out[0]["body"]) < 700


def test_fields_arrive_as_a_list_a_json_string_or_a_comma_list():
    assert parse_fields(["a", " b "]) == ["a", "b"]
    assert parse_fields('["a","b.c"]') == ["a", "b.c"]
    assert parse_fields("a, b.c") == ["a", "b.c"]
    assert parse_fields(None) == []


# -- feeds ----------------------------------------------------------------------

ATOM = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <title>arXiv Query: CSM</title>
  <opensearch:totalResults>42</opensearch:totalResults>
  <entry>
    <id>http://arxiv.org/abs/2610.00001v1</id>
    <published>2026-10-06T10:00:00Z</published>
    <updated>2026-10-07T10:00:00Z</updated>
    <title>A Full-Duplex
      Speech Model</title>
    <summary>We study turn taking. """ + "Long text. " * 80 + """</summary>
    <author><name>Ada</name></author>
    <author><name>Bob</name></author>
    <link href="https://arxiv.org/abs/2610.00001v1" rel="alternate" type="text/html"/>
    <link href="https://arxiv.org/pdf/2610.00001v1" rel="related" title="pdf"/>
  </entry>
</feed>"""

RSS = """<?xml version="1.0"?>
<rss version="2.0"><channel><title>Blog</title>
<item><title>Release 2.0</title><link>https://blog.test/2</link>
<pubDate>Tue, 06 Oct 2026 08:00:00 GMT</pubDate><description>&lt;p&gt;New &lt;b&gt;things&lt;/b&gt;&lt;/p&gt;</description></item>
</channel></rss>"""


def test_an_atom_feed_becomes_one_line_per_entry():
    text = render_feed(ATOM)
    lines = text.splitlines()
    assert lines[0] == "Feed: arXiv Query: CSM (1 entries of 42 results)"
    assert lines[1] == (
        "- 2026-10-06T10:00:00Z | A Full-Duplex Speech Model | "
        "https://arxiv.org/abs/2610.00001v1 | updated 2026-10-07T10:00:00Z | Ada, Bob"
    )
    assert lines[2].startswith("  We study turn taking.")
    assert len(lines[2]) < 320


def test_an_rss_feed_becomes_lines_without_markup():
    text = render_feed(RSS)
    assert "- Tue, 06 Oct 2026 08:00:00 GMT | Release 2.0 | https://blog.test/2" in text
    assert "New things" in text and "<b>" not in text


def test_a_document_that_is_not_a_feed_is_left_to_the_caller():
    assert render_feed("<?xml version='1.0'?><svg></svg>") is None
    assert render_feed("<feed><broken") is None


# -- images ---------------------------------------------------------------------

PAGE = """<html><head><title>Raspberry Pi 5</title>
<meta property="og:image" content="/media/pi5-hero.jpg">
<script type="application/ld+json">{"@type":"Product","name":"Raspberry Pi 5 8GB",
 "image":["https://shop.test/media/pi5-side.jpg"]}</script>
</head><body>
<img src="/img/logo.svg" alt="Shop">
<img src="/media/pi5-hero.jpg?width=300" alt="Raspberry Pi 5" width="300" height="300">
<img data-src="/media/pi5-back.jpg" src="data:image/gif;base64,AAAA" alt="Raspberry Pi 5 back">
<img srcset="/media/pi5-top_400x.jpg 400w, /media/pi5-top_2000x.jpg 2000w" alt="top view">
<img src="/media/icon-cart.png" width="24" height="24">
<a href="/media/pi5-full.png">full size</a>
</body></html>"""


def test_images_are_found_absolute_and_logos_moved_out():
    found = extract_images(PAGE, base_url="https://shop.test/p/pi5")
    urls = [row["url"] for row in found["images"]]
    assert found["title"] == "Raspberry Pi 5"
    # Page-level pictures lead.
    assert urls[0] == "https://shop.test/media/pi5-hero.jpg"
    assert "https://shop.test/media/pi5-side.jpg" in urls[:2]
    # Lazy images, the biggest srcset entry and linked originals are found.
    assert "https://shop.test/media/pi5-back.jpg" in urls
    assert "https://shop.test/media/pi5-top_2000x.jpg" in urls
    assert "https://shop.test/media/pi5-top_400x.jpg" not in urls
    assert "https://shop.test/media/pi5-full.png" in urls
    # The same picture in a smaller size counts once; data: URIs never.
    assert not any("width=300" in url for url in urls)
    assert not any(url.startswith("data:") for url in urls)
    # Five photos: the two icons are counted, not listed.
    assert found["likely_icons"] == 2
    assert not any(row.get("likely_icon") for row in found["images"])


def test_with_few_photos_the_icons_are_listed_last_and_flagged():
    page = (
        '<img src="/img/logo.svg" alt="Shop"><img src="/p/case-red.jpg" alt="Case red">'
        '<img src="/media/icon-cart.png" width="24" height="24">'
    )
    found = extract_images(page, "https://shop.test/")
    urls = [row["url"] for row in found["images"]]
    assert urls[0] == "https://shop.test/p/case-red.jpg"
    flagged = {row["url"] for row in found["images"] if row.get("likely_icon")}
    assert flagged == {"https://shop.test/img/logo.svg", "https://shop.test/media/icon-cart.png"}
    assert found["icons_listed"] is True


def test_icons_are_left_out_when_the_page_has_enough_photos():
    body = "".join(f'<img src="/p/photo-{i}.jpg" alt="Pi {i}">' for i in range(8))
    found = extract_images(f"<html><body><img src='/logo.png'>{body}</body></html>", "https://s.test/")
    assert found["likely_icons"] == 1
    assert all(not row.get("likely_icon") for row in found["images"])
    assert len(found["images"]) == 8


def test_broken_html_still_yields_images():
    found = extract_images('<img src="/a.jpg" alt="x"><div><img src=', "https://s.test/")
    assert [row["url"] for row in found["images"]][:1] == ["https://s.test/a.jpg"]


# -- through the tool ---------------------------------------------------------


def _tool(response: httpx.Response):
    def handle(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            response.status_code, headers=response.headers, content=response.content
        )

    return make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
        resolve=lambda host, port: ["93.184.216.34"],
    )


def test_the_tool_projects_json_fields():
    fetch = _tool(httpx.Response(200, headers={"content-type": "application/json"},
                                 text=json.dumps(COMMITS)))
    result = fetch("https://api.test/commits", fields=["sha", "commit.author.date"])
    assert result["ok"] is True
    assert json.loads(result["content"]) == [
        {"sha": "abc", "commit.author.date": "2026-10-06T10:00:00Z"},
        {"sha": "def", "commit.author.date": "2026-10-01T09:00:00Z"},
    ]


def test_the_tool_turns_a_feed_into_lines():
    fetch = _tool(httpx.Response(200, headers={"content-type": "application/atom+xml"}, text=ATOM))
    result = fetch("https://export.arxiv.test/api/query?q=x")
    assert result["content"].startswith("Feed: arXiv Query: CSM")


def test_the_tool_lists_images_on_request():
    fetch = _tool(httpx.Response(200, headers={"content-type": "text/html"}, text=PAGE))
    result = fetch("https://shop.test/p/pi5", extract="images")
    assert result["ok"] is True and result["title"] == "Raspberry Pi 5"
    assert result["images"][0]["url"] == "https://shop.test/media/pi5-hero.jpg"
    assert "content" not in result


def test_images_need_an_html_page():
    fetch = _tool(httpx.Response(200, headers={"content-type": "application/json"}, text="{}"))
    result = fetch("https://api.test/x", extract="images")
    assert result["ok"] is False and "HTML" in result["error"]


def test_a_bot_check_answer_points_at_the_browser():
    fetch = _tool(
        httpx.Response(
            403,
            headers={"content-type": "text/html", "server": "cloudflare", "cf-mitigated": "challenge"},
            text="<title>Just a moment...</title>",
        )
    )
    result = fetch("https://www.raspberrypi.test/products/pi5/")
    assert result["ok"] is False and result["status"] == 403
    assert result["hint"] == BOT_CHECK_HINT
    assert "browser_navigate" in result["hint"]


def test_a_plain_403_carries_no_browser_hint():
    fetch = _tool(httpx.Response(403, headers={"content-type": "text/plain"}, text="forbidden"))
    result = fetch("https://api.test/private")
    assert result == {"ok": False, "url": "https://api.test/private", "status": 403, "error": "HTTP 403"}


def test_the_schema_offers_fields_and_image_extraction():
    props = WEB_FETCH_SCHEMA["properties"]
    assert props["fields"]["type"] == "array"
    assert props["extract"]["enum"] == ["text", "images"]


# -- grep: data that the visible text hides (round 2, TurnBench) ---------------

from chuk_agents_runtime.web_extract import compile_grep, grep_sources, script_urls

LEADERBOARD = """<html><head>
<script src="/_next/static/chunks/a.js?dpl=1" async=""></script>
<script src="https://cdn.other.test/analytics.js"></script>
<script src="/_next/static/chunks/a.js?dpl=1"></script>
</head><body><div role="row" class="cursor-pointer"><span>1</span>
<span>p99lab turn-1-mini</span><span>0.975</span></div></body></html>"""
BUNDLE = (
    'x={submissions:[{model:"sparrow-2",display_name:"Tavus Sparrow-2",submitted:"2026-09-01"},'
    + "pad" * 200
    + '{model:"turn-1-mini",display_name:"p99lab turn-1-mini",submitted:"2026-10-05"}]}'
)


def test_compile_grep_escapes_each_word():
    pattern = compile_grep("submitted | a.b(c")
    assert pattern.search("SUBMITTED") and pattern.search(" a.b(cx")
    assert not pattern.search(" aXb(c")  # the dot is literal, no regex
    assert compile_grep("  |  ") is None


def test_grep_words_split_on_bars_and_commas_and_start_a_word():
    """Round 2 live: the model wrote ``submitted|date|score``. Each part is
    one literal word; ``date`` must not match inside ``update``."""
    from chuk_agents_runtime.web_extract import grep_terms

    assert grep_terms("submitted|date|score") == ["submitted", "date", "score"]
    assert grep_terms("2026, 2025 |Submitted|(baseline)") == ["2026", "2025", "Submitted", "baseline"]
    assert grep_terms("Submitted October") == ["Submitted October"]
    pattern = compile_grep("submitted|date")
    assert pattern.search('{submitted:"2026-10-05"}')
    assert pattern.search("dateCreated") and not pattern.search("update()")


def test_script_urls_keep_the_page_host_only_and_once():
    urls = script_urls(LEADERBOARD, "https://bench.test/")
    assert urls == ["https://bench.test/_next/static/chunks/a.js?dpl=1"]


def test_grep_sources_returns_snippets_and_counts_all():
    found = grep_sources([("https://bench.test/a.js", BUNDLE)], compile_grep("submitted"))
    assert found["counts"] == {"submitted": 2}
    [group] = found["matches"]
    assert group["url"] == "https://bench.test/a.js"
    assert any('model:"turn-1-mini"' in t and '"2026-10-05"' in t for t in group["snippets"])
    assert found["files_searched"] == 1


def test_frequent_noise_words_cannot_push_the_dated_data_out():
    """Round 2 live: ``date`` matched 400 times in a framework bundle and
    filled the result before the bundle with ``submitted:"2026-10-05"``."""
    from chuk_agents_runtime.web_extract import GREP_MAX_CHARS

    framework = ";".join(f"function update{i}(){{validate(date{i})}}" for i in range(600))
    sources = [("https://bench.test/framework.js", framework), ("https://bench.test/data.js", BUNDLE)]
    found = grep_sources(sources, compile_grep("submitted|date|score"))
    text = json.dumps(found)
    assert "2026-10-05" in text and "2026-09-01" in text
    assert len(text) < GREP_MAX_CHARS + 1_500
    assert found["counts"]["date"] == 600 and "cut" in found


def test_a_short_line_comes_back_whole():
    page = "Intro line\nSubmitted October 5, 2026 by p99lab.\nOther line"
    found = grep_sources([("https://b.test/m", page)], compile_grep("submitted"))
    assert found["matches"][0]["snippets"] == ["Submitted October 5, 2026 by p99lab."]


def _site(pages: dict[str, httpx.Response]):
    def handle(request: httpx.Request) -> httpx.Response:
        response = pages.get(str(request.url))
        if response is None:
            return httpx.Response(404, text="missing")
        return httpx.Response(response.status_code, headers=response.headers, content=response.content)

    return make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
        resolve=lambda host, port: ["93.184.216.34"],
    )


def test_the_tool_greps_a_page_and_its_script_files():
    fetch = _site(
        {
            "https://bench.test/": httpx.Response(200, headers={"content-type": "text/html"}, text=LEADERBOARD),
            "https://bench.test/_next/static/chunks/a.js?dpl=1": httpx.Response(
                200, headers={"content-type": "application/javascript"}, text=BUNDLE
            ),
        }
    )
    # Without scripts: the visible page has no dates.
    only_page = fetch("https://bench.test/", grep="submitted")
    assert only_page["ok"] is True and only_page["counts"] == {}
    # With scripts: the bundle gives each entry with its date, also for the
    # regex-style call the model makes.
    result = fetch("https://bench.test/", grep="submitted|date", scripts=True)
    assert result["counts"]["submitted"] == 2 and result["files_searched"] == 2
    [group] = result["matches"]
    assert group["url"] == "https://bench.test/_next/static/chunks/a.js?dpl=1"
    assert any('"2026-10-05"' in t for t in group["snippets"])
    assert "content" not in result


def test_a_script_on_a_blocked_address_is_not_fetched():
    page = '<script src="/app.js"></script>'
    calls: list[str] = []

    def handle(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(200, headers={"content-type": "text/html"}, text=page)

    def resolve(host: str, port: int) -> list[str]:
        return ["93.184.216.34"] if not calls else ["127.0.0.1"]

    fetch = make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)), resolve=resolve
    )
    result = fetch("https://bench.test/", grep="x", scripts=True)
    assert result["scripts_failed"] == ["https://bench.test/app.js"]
    assert calls == ["https://bench.test/"]


def test_a_long_feed_keeps_every_entry_with_shorter_summaries():
    entry = (
        "<entry><id>http://arxiv.org/abs/2610.{n:05d}v1</id><published>2026-10-06T10:00:00Z</published>"
        "<title>Paper {n}</title><summary>" + "word " * 200 + "</summary>"
        '<link href="https://arxiv.org/abs/2610.{n:05d}v1" rel="alternate"/></entry>'
    )
    feed = '<feed xmlns="http://www.w3.org/2005/Atom"><title>q</title>' + "".join(
        entry.format(n=n) for n in range(30)
    ) + "</feed>"
    text = render_feed(feed)
    assert text.count("\n- ") == 30
    summaries = [line for line in text.splitlines() if line.startswith("  ")]
    assert max(len(line) for line in summaries) < 170


# -- round 2: shop facts and lists in fields ------------------------------------

from chuk_agents_runtime.web_extract import product_facts


def test_fields_map_over_a_list_inside_an_object():
    data = {"product": {"title": "Case", "variants": [
        {"id": 1, "title": "Red/White", "sku": "SC1159", "price": "9.60"},
        {"id": 2, "title": "Black", "sku": "SC1160", "price": "9.60"},
    ]}}
    out = project(data, ["product.title", "product.variants.sku", "product.variants.0.title"])
    assert out == {"product.title": "Case", "product.variants.sku": ["SC1159", "SC1160"],
                   "product.variants.0.title": "Red/White"}


def test_product_facts_come_from_json_ld_offers():
    block = json.dumps({"@context": "https://schema.org", "@type": "Product",
                        "name": "Gehäuse rot/weiß", "sku": "RPI5-CASE-RE", "mpn": "SC1159",
                        "brand": {"@type": "Brand", "name": "Raspberry Pi"},
                        "offers": {"@type": "Offer", "price": "9.90", "priceCurrency": "EUR",
                                   "availability": "https://schema.org/InStock"}})
    assert product_facts([block], {}) == {
        "name": "Gehäuse rot/weiß", "brand": "Raspberry Pi", "sku": "RPI5-CASE-RE",
        "mpn": "SC1159", "price": "9.90", "currency": "EUR", "availability": "InStock",
    }


def test_a_zero_price_is_never_a_price():
    """Live test 2026-10-09: a shop's "0.00 / on request" became a price."""
    block = json.dumps({"@type": "Product", "name": "Case",
                        "offers": {"price": "0.00", "priceCurrency": "EUR"}})
    facts = product_facts([block], {"itemprop:price": "0,00"})
    assert facts["price"] is None and facts["name"] == "Case"


def test_meta_tags_give_the_price_when_json_ld_has_none():
    facts = product_facts([], {"product:price:amount": "12,50", "product:price:currency": "EUR"})
    assert facts == {"price": "12,50", "currency": "EUR"}


def test_the_image_list_carries_the_product_facts():
    page = ('<html><head><meta property="product:price:amount" content="9.60">'
            '<meta property="product:price:currency" content="GBP"></head>'
            '<body><img src="/c.jpg" alt="Case"></body></html>')
    found = extract_images(page, "https://shop.test/")
    assert found["product"] == {"price": "9.60", "currency": "GBP"}
