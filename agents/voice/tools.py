"""Function tools for the voice agent.

Every tool follows the same contract:

  * **Return a short, speakable string.**  It goes straight into the LLM's
    context and gets voiced, so no markdown, no URLs, no JSON dumps.
  * **Push the rich version to the app** via ``UiBridge.card``.  The card
    carries the full structured data (hourly forecast, result list, chart
    points, …) so the phone can render what speech can't convey.

That split is what makes the assistant feel like a heads-up display: the voice
gives you the answer, the screen gives you the detail.

All tools use free, key-less APIs so a fresh checkout works without extra
secrets.  HTTP goes through ``utils.http_context.http_session()`` — a pooled,
job-scoped aiohttp session (see the LiveKit tool best-practices docs).
"""

from __future__ import annotations

import ast
import asyncio
import logging
import math
import operator
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html import unescape
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from livekit.agents import RunContext, StopResponse, function_tool, utils
from livekit.agents.beta.tools.end_call import EndCallTool

import delegation
from background import BackgroundRunner
from call_config import END_CALL_EXTRA_DESCRIPTION, END_CALL_GOODBYE_INSTRUCTIONS
from delegation import TaskBook
from ui_bridge import UiBridge

logger = logging.getLogger("voice-agent.tools")

_HTTP_TIMEOUT = 12.0
_UA = "Mozilla/5.0 (compatible; VoiceAssistant/1.0)"
#: Wikimedia answers 403 to generic user agents (robot policy): the UA must
#: name the client and give a contact URL. Nominatim asks for the same.
_BOT_UA = "chuk-voice/0.1 (https://github.com/chuk-development/chuk_chat)"


@dataclass
class SessionData:
    """Per-session state handed to every tool through ``ctx.userdata``."""

    ui: UiBridge
    #: Detached work the agent reports back on by itself.
    runner: BackgroundRunner
    #: Tasks handed to the chuk_chat app with ``delegate_task``.
    tasks: TaskBook = field(default_factory=TaskBook)
    #: OpenAI client for the chuk API proxy (worker JWT + voice grant). Used
    #: by web search when VOICE_SEARCH_MODEL is set.
    proxy: Any = None


def _ui(ctx: RunContext) -> UiBridge:
    return ctx.userdata.ui  # type: ignore[no-any-return]


async def _get_json(
    url: str, params: dict[str, Any] | None = None, *, user_agent: str = _UA
) -> Any:
    session = utils.http_context.http_session()
    async with session.get(
        url,
        params=params,
        timeout=_HTTP_TIMEOUT,
        headers={"User-Agent": user_agent},
    ) as resp:
        resp.raise_for_status()
        return await resp.json(content_type=None)


async def _get_text(url: str, params: dict[str, Any] | None = None) -> str:
    session = utils.http_context.http_session()
    async with session.get(
        url,
        params=params,
        timeout=_HTTP_TIMEOUT,
        headers={"User-Agent": _UA},
    ) as resp:
        resp.raise_for_status()
        return await resp.text()


# ---------------------------------------------------------------------------
# Geocoding (shared by weather / time / maps)
# ---------------------------------------------------------------------------


async def _geocode(location: str) -> dict[str, Any] | None:
    """Resolve a place name to coordinates.

    Open-Meteo's geocoder is fast and returns the timezone, but only knows
    populated places — it can't find "Brandenburger Tor" or a street address.
    Nominatim (OpenStreetMap) can, so it backs up the miss.
    """
    data = await _get_json(
        "https://geocoding-api.open-meteo.com/v1/search",
        {"name": location, "count": 1, "language": "de", "format": "json"},
    )
    results = data.get("results") or []
    if results:
        return results[0]

    try:
        osm = await _get_json(
            "https://nominatim.openstreetmap.org/search",
            {"q": location, "format": "jsonv2", "limit": 1, "accept-language": "de"},
        )
    except Exception as e:  # noqa: BLE001
        logger.debug("nominatim lookup failed: %s", e)
        return None

    if not osm:
        return None

    hit = osm[0]
    parts = [p.strip() for p in (hit.get("display_name") or "").split(",")]
    return {
        "name": hit.get("name") or (parts[0] if parts else location),
        "latitude": float(hit["lat"]),
        "longitude": float(hit["lon"]),
        "country": parts[-1] if parts else "",
        "admin1": parts[-3] if len(parts) >= 3 else "",
        # Nominatim has no timezone field; callers fall back to UTC.
        "timezone": None,
    }


# ---------------------------------------------------------------------------
# Weather
# ---------------------------------------------------------------------------

# Open-Meteo WMO weather codes → (spoken German description, icon key for the app)
_WEATHER_CODES: dict[int, tuple[str, str]] = {
    0: ("klar", "clear"),
    1: ("überwiegend klar", "mostly_clear"),
    2: ("teils bewölkt", "partly_cloudy"),
    3: ("bedeckt", "overcast"),
    45: ("neblig", "fog"),
    48: ("Reifnebel", "fog"),
    51: ("leichter Nieselregen", "drizzle"),
    53: ("Nieselregen", "drizzle"),
    55: ("starker Nieselregen", "drizzle"),
    56: ("gefrierender Nieselregen", "freezing_drizzle"),
    57: ("starker gefrierender Nieselregen", "freezing_drizzle"),
    61: ("leichter Regen", "rain"),
    63: ("Regen", "rain"),
    65: ("starker Regen", "heavy_rain"),
    66: ("gefrierender Regen", "freezing_rain"),
    67: ("starker gefrierender Regen", "freezing_rain"),
    71: ("leichter Schneefall", "snow"),
    73: ("Schneefall", "snow"),
    75: ("starker Schneefall", "heavy_snow"),
    77: ("Schneegriesel", "snow"),
    80: ("leichte Regenschauer", "showers"),
    81: ("Regenschauer", "showers"),
    82: ("heftige Regenschauer", "heavy_showers"),
    85: ("Schneeschauer", "snow_showers"),
    86: ("starke Schneeschauer", "snow_showers"),
    95: ("Gewitter", "thunderstorm"),
    96: ("Gewitter mit Hagel", "thunderstorm_hail"),
    99: ("schweres Gewitter mit Hagel", "thunderstorm_hail"),
}


def _describe_code(code: int) -> tuple[str, str]:
    return _WEATHER_CODES.get(code, ("unbekannt", "unknown"))


@function_tool()
async def get_weather(ctx: RunContext, location: str, days: int = 3) -> str:
    """Get the current weather and forecast for a place, and show it on screen.

    Use this for any weather question: right now, later today, or the next few
    days. Always call it rather than guessing — the user sees a live card.

    Args:
        location: City, region or address, e.g. "Berlin", "Cupertino CA".
        days: How many forecast days to fetch, 1 to 7. Use 1 for "right now".
    """
    days = max(1, min(int(days), 7))

    place = await _geocode(location)
    if place is None:
        return f"Ich konnte den Ort {location} nicht finden."

    lat, lon = place["latitude"], place["longitude"]
    name = place.get("name") or location
    country = place.get("country") or ""

    data = await _get_json(
        "https://api.open-meteo.com/v1/forecast",
        {
            "latitude": lat,
            "longitude": lon,
            "current": (
                "temperature_2m,apparent_temperature,relative_humidity_2m,"
                "weather_code,wind_speed_10m,precipitation,is_day"
            ),
            "hourly": "temperature_2m,precipitation_probability,weather_code",
            "daily": (
                "weather_code,temperature_2m_max,temperature_2m_min,"
                "precipitation_probability_max,sunrise,sunset"
            ),
            "timezone": "auto",
            "forecast_days": days,
        },
    )

    current = data.get("current") or {}
    code = int(current.get("weather_code") or 0)
    spoken_cond, icon = _describe_code(code)
    temp = current.get("temperature_2m")
    feels = current.get("apparent_temperature")

    daily = data.get("daily") or {}
    day_list = [
        {
            "date": d,
            "code": int(c),
            "icon": _describe_code(int(c))[1],
            "condition": _describe_code(int(c))[0],
            "max": mx,
            "min": mn,
            "precip_prob": pp,
        }
        for d, c, mx, mn, pp in zip(
            daily.get("time", []),
            daily.get("weather_code", []),
            daily.get("temperature_2m_max", []),
            daily.get("temperature_2m_min", []),
            daily.get("precipitation_probability_max", []),
        )
    ]

    # Next 12 hours only — enough for the app's sparkline, small enough to send.
    hourly = data.get("hourly") or {}
    now_iso = (data.get("current") or {}).get("time") or ""
    times = hourly.get("time", [])
    start = next((i for i, t in enumerate(times) if t >= now_iso), 0)
    hours = [
        {
            "time": t,
            "temp": tp,
            "precip_prob": pp,
            "icon": _describe_code(int(c))[1],
        }
        for t, tp, pp, c in list(
            zip(
                times,
                hourly.get("temperature_2m", []),
                hourly.get("precipitation_probability", []),
                hourly.get("weather_code", []),
            )
        )[start : start + 12]
    ]

    await _ui(ctx).card(
        "weather",
        title=name,
        subtitle=country,
        source="Open-Meteo",
        data={
            "icon": icon,
            "condition": spoken_cond,
            "temperature": temp,
            "apparent": feels,
            "humidity": current.get("relative_humidity_2m"),
            "wind": current.get("wind_speed_10m"),
            "precipitation": current.get("precipitation"),
            "is_day": bool(current.get("is_day", 1)),
            "units": data.get("current_units") or {},
            "hourly": hours,
            "daily": day_list,
            "latitude": lat,
            "longitude": lon,
        },
    )

    spoken = f"In {name} ist es gerade {spoken_cond} bei {round(temp)} Grad"
    if feels is not None and abs(feels - temp) >= 2:
        spoken += f", gefühlt {round(feels)}"
    spoken += "."
    if day_list:
        today = day_list[0]
        spoken += f" Heute zwischen {round(today['min'])} und {round(today['max'])} Grad"
        if (today.get("precip_prob") or 0) >= 30:
            spoken += f", Regenwahrscheinlichkeit {today['precip_prob']} Prozent"
        spoken += "."
    return spoken


# ---------------------------------------------------------------------------
# Web search
# ---------------------------------------------------------------------------

_TAG_RE = re.compile(r"<[^>]+>")


def _strip_html(value: str) -> str:
    return unescape(_TAG_RE.sub("", value)).strip()


#: A search-capable model behind the chuk API proxy (``/chat/completions``).
#: Unset: web search uses Wikipedia only. The worker holds no provider keys,
#: so search goes through the proxy like every other model call.
_SEARCH_MODEL = os.environ.get("VOICE_SEARCH_MODEL", "").strip()

_SOURCE_RE = re.compile(
    r"Title:\s*(?P<title>.*?)\nURL:\s*(?P<url>\S+)\nContent:\s*(?P<content>.*?)(?=\nTitle:\s|\Z)",
    re.DOTALL,
)


def _parse_sources(executed_tools: list[dict[str, Any]], limit: int = 6) -> list[dict[str, str]]:
    """Pull (title, url, snippet) triples out of the search tool's raw output."""
    seen: set[str] = set()
    results: list[dict[str, str]] = []
    for tool in executed_tools or []:
        for m in _SOURCE_RE.finditer(str(tool.get("output") or "")):
            url = m.group("url").strip()
            if url in seen:
                continue
            seen.add(url)
            results.append(
                {
                    "title": m.group("title").strip(),
                    "url": url,
                    "snippet": re.sub(r"\s+", " ", m.group("content")).strip()[:300],
                }
            )
            if len(results) >= limit:
                return results
    return results


async def _proxy_search(proxy: Any, query: str) -> tuple[str, list[dict[str, str]]]:
    """Web search through the chuk proxy. Returns (answer, sources).

    Models that search server-side (for example Groq compound) may return the
    raw hits under ``executed_tools``; the sources are parsed from there.
    """
    if proxy is None or not _SEARCH_MODEL:
        return "", []
    resp = await proxy.chat.completions.create(
        model=_SEARCH_MODEL,
        messages=[
            {
                "role": "system",
                # Without an explicit order to search, a search model happily
                # answers from its own (stale) weights and skips the tool.
                "content": (
                    "Always use your web search tool before answering. Never "
                    "answer from memory. Be factual and concise: three "
                    "sentences at most, no markdown, no lists. Answer in the "
                    "language of the query."
                ),
            },
            {"role": "user", "content": query},
        ],
        timeout=25.0,
    )
    message = resp.choices[0].message.model_dump() if resp.choices else {}
    answer = _strip_html(message.get("content") or "").replace("**", "")
    return answer, _parse_sources(message.get("executed_tools") or [])


async def _wikipedia_summary(query: str, lang: str = "de") -> dict[str, Any] | None:
    try:
        search = await _get_json(
            f"https://{lang}.wikipedia.org/w/api.php",
            {
                "action": "query",
                "list": "search",
                "srsearch": query,
                "srlimit": 1,
                "format": "json",
            },
            user_agent=_BOT_UA,
        )
        hits = (search.get("query") or {}).get("search") or []
        if not hits:
            return None
        title = hits[0]["title"]
        from urllib.parse import quote

        return await _get_json(
            f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{quote(title, safe='')}",
            user_agent=_BOT_UA,
        )
    except Exception as e:  # noqa: BLE001
        logger.debug("wikipedia lookup failed: %s", e)
        return None


@function_tool()
async def search_web(ctx: RunContext, query: str) -> str:
    """Search the live web for facts, news, prices, people, or anything current.

    Call this whenever the answer could have changed since training, is about a
    specific person/company/product, or you are not certain. Do not guess.
    The user sees the sources as tappable cards.

    Args:
        query: A focused search query. Use the user's language and include the
            key entity, e.g. "Bundesliga Tabelle aktuell" not "sport".
    """
    async with ctx.with_filler("Moment, ich schaue nach.", delay=2.5, interval=8):
        search, wiki = await asyncio.gather(
            _proxy_search(getattr(ctx.userdata, "proxy", None), query),
            _wikipedia_summary(query),
            return_exceptions=True,
        )

    if isinstance(search, BaseException):
        logger.warning("web search failed: %s", search)
        answer, results = "", []
    else:
        answer, results = search
    if isinstance(wiki, BaseException):
        wiki = None

    if not answer and not results and not wiki:
        return f"Ich habe zu '{query}' nichts Brauchbares gefunden."

    await _ui(ctx).card(
        "search",
        title=query,
        subtitle=answer or None,
        source="Web",
        data={
            "answer": answer,
            "results": results,
            "summary": (
                {
                    "title": wiki.get("title"),
                    "extract": wiki.get("extract"),
                    "image": ((wiki.get("thumbnail") or {}).get("source")),
                    "url": ((wiki.get("content_urls") or {}).get("desktop") or {}).get("page"),
                }
                if wiki
                else None
            ),
        },
    )

    # Speakable digest: the model gets the text and decides what to voice.
    parts: list[str] = []
    if answer:
        parts.append(answer)
    if wiki and wiki.get("extract"):
        parts.append(wiki["extract"])
    for r in results[:3]:
        if r["snippet"]:
            parts.append(f"{r['title']}: {r['snippet']}")
    return "\n".join(parts)[:2500]


@function_tool()
async def read_page(ctx: RunContext, url: str) -> str:
    """Read the full text of a specific web page the user asked about.

    Use after search_web when a single result needs to be read in depth, or
    when the user gives you a URL directly.

    Args:
        url: Absolute http(s) URL of the page to read.
    """
    if not url.startswith(("http://", "https://")):
        return "Das ist keine gültige Adresse."
    try:
        html = await _get_text(url)
    except Exception as e:  # noqa: BLE001
        return f"Die Seite konnte ich nicht laden: {e}"

    body = re.sub(r"(?is)<(script|style|nav|footer|header)[^>]*>.*?</\1>", " ", html)
    text = re.sub(r"\s+", " ", _strip_html(body)).strip()
    title_m = re.search(r"(?is)<title[^>]*>(.*?)</title>", html)
    title = _strip_html(title_m.group(1)) if title_m else url

    await _ui(ctx).card(
        "article",
        title=title,
        subtitle=url,
        source=url,
        data={"url": url, "text": text[:8000]},
    )
    return text[:4000] or "Die Seite enthält keinen lesbaren Text."


# ---------------------------------------------------------------------------
# News
# ---------------------------------------------------------------------------

_RSS_ITEM_RE = re.compile(r"<item>(.*?)</item>", re.DOTALL)


def _rss_field(item: str, tag: str) -> str:
    m = re.search(rf"<{tag}[^>]*>(.*?)</{tag}>", item, re.DOTALL)
    if not m:
        return ""
    return _strip_html(m.group(1).replace("<![CDATA[", "").replace("]]>", ""))


@function_tool()
async def get_news(ctx: RunContext, topic: str = "", language: str = "de") -> str:
    """Get current headlines, optionally about a specific topic.

    Args:
        topic: What the news should be about, e.g. "Bitcoin", "Bundesliga".
            Leave empty for the general top stories.
        language: Two-letter language code for the edition, e.g. "de" or "en".
    """
    lang = (language or "de").lower()[:2]
    region = {"de": "DE", "en": "US"}.get(lang, lang.upper())
    base = "https://news.google.com/rss"
    url = f"{base}/search" if topic else base
    params = {"hl": f"{lang}-{region}", "gl": region, "ceid": f"{region}:{lang}"}
    if topic:
        params["q"] = topic

    try:
        xml = await _get_text(url, params)
    except Exception as e:  # noqa: BLE001
        return f"Die Nachrichten konnte ich nicht abrufen: {e}"

    items = []
    for raw in _RSS_ITEM_RE.findall(xml)[:8]:
        items.append(
            {
                "title": _rss_field(raw, "title"),
                "url": _rss_field(raw, "link"),
                "source": _rss_field(raw, "source"),
                "published": _rss_field(raw, "pubDate"),
            }
        )

    if not items:
        return "Ich habe dazu keine aktuellen Meldungen gefunden."

    await _ui(ctx).card(
        "news",
        title=topic or "Schlagzeilen",
        subtitle=f"{len(items)} Meldungen",
        source="Google News",
        data={"items": items},
    )
    headlines = " ".join(f"{i + 1}. {it['title']}." for i, it in enumerate(items[:5]))
    return f"Aktuelle Meldungen: {headlines}"


# ---------------------------------------------------------------------------
# Math
# ---------------------------------------------------------------------------

_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}
_UNARY_OPS = {ast.UAdd: operator.pos, ast.USub: operator.neg}
_MATH_NAMES: dict[str, Any] = {
    "pi": math.pi,
    "e": math.e,
    "tau": math.tau,
    "sqrt": math.sqrt,
    "sin": math.sin,
    "cos": math.cos,
    "tan": math.tan,
    "asin": math.asin,
    "acos": math.acos,
    "atan": math.atan,
    "log": math.log,
    "log2": math.log2,
    "log10": math.log10,
    "exp": math.exp,
    "abs": abs,
    "round": round,
    "floor": math.floor,
    "ceil": math.ceil,
    "min": min,
    "max": max,
    "pow": math.pow,
    "factorial": math.factorial,
    "hypot": math.hypot,
    "degrees": math.degrees,
    "radians": math.radians,
}


def _eval_node(node: ast.AST) -> Any:
    """Evaluate a whitelisted arithmetic AST — no eval(), no attribute access."""
    if isinstance(node, ast.Expression):
        return _eval_node(node.body)
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (int, float)):
            return node.value
        raise ValueError("Nur Zahlen sind erlaubt.")
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        return _BIN_OPS[type(node.op)](_eval_node(node.left), _eval_node(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_eval_node(node.operand))
    if isinstance(node, ast.Name) and node.id in _MATH_NAMES:
        return _MATH_NAMES[node.id]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        fn = _MATH_NAMES.get(node.func.id)
        if not callable(fn):
            raise ValueError(f"Unbekannte Funktion: {node.func.id}")
        return fn(*[_eval_node(a) for a in node.args])
    raise ValueError("Ausdruck nicht erlaubt.")


@function_tool()
async def calculate(ctx: RunContext, expression: str) -> str:
    """Evaluate a mathematical expression exactly.

    Always use this instead of doing arithmetic yourself — you make mistakes,
    this does not. Supports + - * / % ** and sqrt, sin, cos, log, factorial, etc.

    Args:
        expression: The expression in plain math notation, e.g. "17 * 23.5",
            "sqrt(144) + 2**10", "log10(1000)".
    """
    cleaned = expression.replace("^", "**").replace(",", ".").replace("×", "*").replace("÷", "/")
    try:
        value = _eval_node(ast.parse(cleaned, mode="eval"))
    except Exception as e:  # noqa: BLE001
        return f"Das konnte ich nicht berechnen: {e}"

    if isinstance(value, float) and value.is_integer() and abs(value) < 1e15:
        pretty = str(int(value))
    elif isinstance(value, float):
        pretty = f"{value:.10g}"
    else:
        pretty = str(value)

    await _ui(ctx).card(
        "calc",
        title=pretty,
        subtitle=expression,
        data={"expression": expression, "result": pretty},
    )
    return f"{expression} ergibt {pretty}."


# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------


@function_tool()
async def get_time(ctx: RunContext, location: str = "") -> str:
    """Get the current date and time, optionally in another city's timezone.

    Args:
        location: City or country to get local time for. Leave empty for the
            server's own time (UTC-based).
    """
    tz = timezone.utc
    label = "UTC"

    if location:
        place = await _geocode(location)
        if place is None:
            return f"Den Ort {location} kenne ich nicht."
        label = place.get("name") or location
        try:
            tz = ZoneInfo(place.get("timezone") or "UTC")
        except ZoneInfoNotFoundError:
            tz = timezone.utc

    now = datetime.now(tz)
    await _ui(ctx).card(
        "time",
        title=now.strftime("%H:%M"),
        subtitle=label,
        data={
            "iso": now.isoformat(),
            "time": now.strftime("%H:%M"),
            "date": now.strftime("%A, %d.%m.%Y"),
            "timezone": str(tz),
            "location": label,
        },
    )
    return f"In {label} ist es {now.strftime('%H:%M')} Uhr am {now.strftime('%d.%m.%Y')}."


# ---------------------------------------------------------------------------
# Currency & markets
# ---------------------------------------------------------------------------


@function_tool()
async def convert_currency(
    ctx: RunContext, amount: float, from_currency: str, to_currency: str
) -> str:
    """Convert money between currencies at today's exchange rate.

    Args:
        amount: How much to convert.
        from_currency: Three-letter source code, e.g. "EUR".
        to_currency: Three-letter target code, e.g. "USD".
    """
    src, dst = from_currency.upper()[:3], to_currency.upper()[:3]
    try:
        data = await _get_json(
            "https://api.frankfurter.dev/v1/latest",
            {"base": src, "symbols": dst, "amount": amount},
        )
        value = (data.get("rates") or {}).get(dst)
    except Exception as e:  # noqa: BLE001
        return f"Der Kurs war nicht abrufbar: {e}"

    if value is None:
        return f"Den Kurs von {src} nach {dst} gibt es nicht."

    rate = value / amount if amount else 0
    await _ui(ctx).card(
        "currency",
        title=f"{value:,.2f} {dst}",
        subtitle=f"{amount:,.2f} {src}",
        source="Frankfurter / EZB",
        data={
            "amount": amount,
            "from": src,
            "to": dst,
            "result": value,
            "rate": rate,
            "date": data.get("date"),
        },
    )
    return f"{amount:g} {src} sind {value:,.2f} {dst}."


@function_tool()
async def get_stock(ctx: RunContext, symbol: str) -> str:
    """Get the current price and day performance of a stock, index or crypto.

    Args:
        symbol: Ticker symbol, e.g. "AAPL", "TSLA", "^GDAXI" for the DAX,
            "BTC-EUR" for Bitcoin in euro.
    """
    try:
        data = await _get_json(
            f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}",
            {"range": "1d", "interval": "5m"},
        )
        result = (data.get("chart") or {}).get("result") or []
        if not result:
            return f"Zu {symbol} habe ich keine Kursdaten gefunden."
        meta = result[0]["meta"]
        closes = [
            c
            for c in ((result[0].get("indicators") or {}).get("quote") or [{}])[0].get("close", [])
            if c is not None
        ]
    except Exception as e:  # noqa: BLE001
        return f"Die Kursdaten waren nicht abrufbar: {e}"

    price = meta.get("regularMarketPrice")
    prev = meta.get("chartPreviousClose") or meta.get("previousClose") or price
    change = (price - prev) if (price and prev) else 0
    pct = (change / prev * 100) if prev else 0
    currency = meta.get("currency") or ""

    await _ui(ctx).card(
        "stock",
        title=f"{price:,.2f} {currency}",
        subtitle=meta.get("shortName") or symbol,
        source="Yahoo Finance",
        data={
            "symbol": symbol,
            "name": meta.get("shortName") or symbol,
            "price": price,
            "change": change,
            "change_pct": pct,
            "currency": currency,
            "series": closes[-60:],
        },
    )
    direction = "im Plus" if change >= 0 else "im Minus"
    return f"{meta.get('shortName') or symbol} steht bei {price:,.2f} {currency}, {abs(pct):.2f} Prozent {direction}."


# ---------------------------------------------------------------------------
# Places / map
# ---------------------------------------------------------------------------


@function_tool()
async def show_place(ctx: RunContext, query: str) -> str:
    """Show a place on a map in the app.

    Use when the user asks where something is, or wants to see a location.

    Args:
        query: Place name or address, e.g. "Brandenburger Tor Berlin".
    """
    place = await _geocode(query)
    if place is None:
        return f"Den Ort {query} habe ich nicht gefunden."

    name = place.get("name") or query
    detail = ", ".join(
        p for p in [place.get("admin1"), place.get("country")] if p
    )
    await _ui(ctx).card(
        "map",
        title=name,
        subtitle=detail,
        source="Open-Meteo Geocoding",
        data={
            "latitude": place["latitude"],
            "longitude": place["longitude"],
            "name": name,
            "detail": detail,
            "population": place.get("population"),
            "elevation": place.get("elevation"),
        },
    )
    return f"{name} liegt in {detail}. Ich zeige es dir auf der Karte."


# ---------------------------------------------------------------------------
# Lists and links
# ---------------------------------------------------------------------------

#: A card holds at most this many list items.
_MAX_LIST_ITEMS = 20


@function_tool()
async def show_list(ctx: RunContext, title: str, items: list[str], urls: list[str] | None = None) -> str:
    """Show a list on the user's screen: steps, options, a shopping list, links.

    Use it whenever a list is easier to read than to hear. Say only the
    headline aloud; the card carries the items.

    Args:
        title: Short heading for the card, e.g. "Einkaufsliste".
        items: The entries, one short line each, in order.
        urls: Optional. One link per entry, in the same order as items. Use an
            empty string for an entry without a link.
    """
    entries = [i.strip() for i in items if i and i.strip()][:_MAX_LIST_ITEMS]
    if not entries:
        return "The list was empty. Nothing to show."
    links = list(urls or [])
    data_items: list[dict[str, str]] = []
    for idx, text in enumerate(entries):
        item = {"title": text}
        url = links[idx].strip() if idx < len(links) and links[idx] else ""
        if url.startswith(("http://", "https://")):
            item["url"] = url
        data_items.append(item)

    await _ui(ctx).card(
        "list",
        title=title,
        subtitle=f"{len(data_items)} Einträge",
        data={"items": data_items},
    )
    return f"Die Liste '{title}' mit {len(data_items)} Einträgen ist auf dem Bildschirm."


# ---------------------------------------------------------------------------
# Background work & proactive speech
# ---------------------------------------------------------------------------


@function_tool()
async def set_reminder(ctx: RunContext, minutes: float, about: str) -> str:
    """Remind the user about something after a delay, by speaking up yourself.

    Args:
        minutes: How long to wait, in minutes. Accepts fractions, e.g. 0.5.
        about: What to remind them about, in their own words.
    """
    delay = max(0.1, float(minutes)) * 60
    runner: BackgroundRunner = ctx.userdata.runner

    async def _wait() -> str:
        await asyncio.sleep(delay)
        return about

    job = runner.start(f"Erinnerung: {about}", _wait())
    due = datetime.now(timezone.utc) + timedelta(seconds=delay)

    await _ui(ctx).card(
        "reminder",
        title=about,
        subtitle=f"in {minutes:g} Minuten",
        data={"job_id": job.id, "about": about, "due_iso": due.isoformat()},
    )
    return f"Erinnerung gesetzt: in {minutes:g} Minuten an {about}."


@function_tool()
async def check_background_tasks(ctx: RunContext) -> str:
    """Check what you are still working on in the background."""
    runner: BackgroundRunner = ctx.userdata.runner
    pending = runner.pending
    if not pending:
        return "Im Hintergrund läuft gerade nichts."
    return "Ich arbeite noch an: " + " ".join(
        f"{j.label} (seit {int(j.elapsed)} Sekunden)." for j in pending
    )


@function_tool()
async def stay_silent(ctx: RunContext) -> str:
    """Say nothing at all and just keep listening.

    Call this instead of answering when speaking would be wrong: the user was
    clearly talking to someone else, thinking out loud, or the room picked up
    background chatter. A person would stay quiet — so do that. Never use it to
    dodge a question actually put to you.
    """
    # StopResponse ends the turn without generating any speech, which is the
    # only way to truly say nothing — an "empty" reply still costs a TTS turn.
    raise StopResponse


# ---------------------------------------------------------------------------
# Device tools — forwarded to the Flutter app over RPC
# ---------------------------------------------------------------------------


@function_tool()
async def open_link(ctx: RunContext, url: str, label: str = "") -> str:
    """Open a link on the user's phone (website, maps, phone number, email).

    Args:
        url: The URL to open, e.g. "https://…", "tel:+49…", "mailto:…".
        label: Short human description of what is being opened.
    """
    try:
        result = await _ui(ctx).call_client("open_link", {"url": url, "label": label})
    except Exception as e:  # noqa: BLE001
        logger.warning("open_link failed: %s", e)
        return f"Ich konnte das auf deinem Gerät nicht öffnen: {e}"
    if isinstance(result, dict) and result.get("error"):
        return f"Ich konnte das auf deinem Gerät nicht öffnen: {result['error']}"
    return f"Ich habe {label or url} auf deinem Gerät geöffnet."


#: What the model reads when the phone gives no position (permission denied,
#: location off, no app, timeout). It says it plainly and asks for a place.
_NO_LOCATION = (
    "Location not available right now (no permission, or location is off). "
    "Tell the user in one short sentence that you can't see their location "
    "right now, and ask which place they mean. Do not retry."
)


#: Longest place name taken from the app; a longer one is not trusted.
_MAX_PLACE_CHARS = 100


def _clean_place(value: Any) -> str | None:
    """The app's optional ``place``: a trimmed, non-empty string of at most
    ``_MAX_PLACE_CHARS`` characters, else None (then the worker looks it up)."""
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    if not text or len(text) > _MAX_PLACE_CHARS:
        return None
    return text


async def _reverse_geocode(lat: float, lon: float) -> str | None:
    """Place name (town or city) for a position, via Nominatim. None on failure."""
    try:
        data = await _get_json(
            "https://nominatim.openstreetmap.org/reverse",
            {"lat": lat, "lon": lon, "format": "jsonv2", "zoom": 10, "accept-language": "de"},
            user_agent=_BOT_UA,
        )
    except Exception as e:  # noqa: BLE001
        logger.debug("reverse geocoding failed: %s", e)
        return None
    if not isinstance(data, dict):
        return None
    address = data.get("address")
    if not isinstance(address, dict):
        address = {}
    for key in ("city", "town", "village", "municipality", "county", "state"):
        value = address.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    name = data.get("name")
    return name.strip() if isinstance(name, str) and name.strip() else None


@function_tool()
async def get_device_location(ctx: RunContext) -> str:
    """Get the user's current location from their phone.

    Call this first whenever the user says "here", "nearby", "where I am", or
    asks about local weather without naming a city.
    """
    try:
        result = await _ui(ctx).call_client("get_location")
    except Exception as e:  # noqa: BLE001 — RPC error, no app, timeout
        logger.info("get_location failed: %s", e)
        return _NO_LOCATION

    if not isinstance(result, dict) or result.get("error"):
        return _NO_LOCATION
    try:
        lat = float(result["latitude"])
        lon = float(result["longitude"])
    except (KeyError, TypeError, ValueError):
        return _NO_LOCATION

    place = _clean_place(result.get("place")) or await _reverse_geocode(lat, lon)
    accuracy = result.get("accuracy")
    where = f"{lat:.4f}, {lon:.4f}"
    if isinstance(accuracy, (int, float)):
        where += f" (accuracy about {round(accuracy)} m)"
    if place:
        return (
            f"The user is in or near {place} ({where}). Use \"{place}\" as the "
            "location for the next tool."
        )
    return f"The user is at {where}. No place name was found."


# ---------------------------------------------------------------------------
# Delegation — hand real work to the chuk_chat app
# ---------------------------------------------------------------------------


@function_tool()
async def delegate_task(ctx: RunContext, task: str) -> str:
    """Hand a piece of real work to the chuk_chat app and keep talking.

    Use it for anything your own tools cannot do: files, the browser, code,
    research, messages, image generation, or any tool you do not have. It
    returns at once. The result comes later, and you are told when it arrives.

    Args:
        task: The full task, self-contained. The worker does not hear this
            call, so include every detail the user gave.
    """
    task = (task or "").strip()
    if not task:
        return "The task was empty. Ask the user what exactly you should do."

    data: SessionData = ctx.userdata
    try:
        raw = await data.ui.call_client(
            delegation.DELEGATE_METHOD,
            {"task": task},
            timeout=delegation.DELEGATE_TIMEOUT,
        )
    except Exception as e:  # noqa: BLE001 — never let a failed hand-off end the call
        logger.warning("delegate_task failed: %s", e)
        return delegation.failed_to_start_line(str(e) or type(e).__name__)

    response = delegation.parse_delegate_response(raw)
    if not response.ok or response.task_id is None:
        logger.warning("delegate_task rejected by app: %s", response.error)
        return delegation.failed_to_start_line(response.error or "unknown error")

    data.tasks.start(response.task_id, task)
    logger.info("delegated task %s: %s", response.task_id, delegation.short_task(task))
    return delegation.started_line(response.task_id)


@function_tool()
async def check_tasks(ctx: RunContext) -> str:
    """List the tasks you handed off with delegate_task, and their status."""
    data: SessionData = ctx.userdata
    return data.tasks.summary()


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

#: Every tool the agent gets. Keep this list tight — a long toolset measurably
#: degrades the model's ability to pick the right one (see LiveKit tool-loop
#: design docs), so add capability by making tools broader, not by adding more.
ALL_TOOLS = [
    get_weather,
    search_web,
    read_page,
    get_news,
    calculate,
    get_time,
    convert_currency,
    get_stock,
    show_place,
    show_list,
    set_reminder,
    check_background_tasks,
    stay_silent,
    open_link,
    get_device_location,
]


def build_tools(*, mode: str, delegate_available: bool) -> list[Any]:
    """The toolset for one call.

    ``delegate_task`` exists only when the app can take tasks. Then
    ``set_reminder`` (an in-call timer) is left out. Deep research always goes
    through ``delegate_task``; the worker has no research model of its own.

    ``end_call`` lets the agent hang up when the user says goodbye. It deletes
    the room, so the app sees the disconnect and saves the transcript. It is
    hidden while the agent greets (``ignore_on_enter``). A new instance per
    call: the toolset keeps per-session state.
    """
    selected: list[Any] = list(ALL_TOOLS)
    if delegate_available:
        # An in-call timer dies at hang-up and blocks the away flow. With a
        # delegate, reminders go to the host agent, which schedules them and
        # can call back with call_user.
        selected.remove(set_reminder)
        selected.append(delegate_task)
    selected.append(check_tasks)
    selected.append(
        EndCallTool(
            delete_room=True,
            ignore_on_enter=True,
            extra_description=END_CALL_EXTRA_DESCRIPTION,
            end_instructions=END_CALL_GOODBYE_INSTRUCTIONS,
        )
    )
    return selected
