"""The user's Home dashboard (docs/DASHBOARD.md).

One document per host, under the fixed key ``user``, in the host's
``executor-state.db``. Every agent of the host reads and writes the same
document through the ``dashboard`` tool; the app reads it with
``dashboard_get`` and changes it with ``dashboard_op``. The host is the truth.

The store validates every write against catalogue v1 (§3), bumps ``version``
by one per stored change, keeps the last 200 applied ``op_id`` values in the
same database (so a retried app op is never applied twice, also across a
host restart) and tells its listeners about every stored change, which is
how the host pushes ``dashboard_state`` to the attached apps.
"""
from __future__ import annotations

import copy
import json
import re
import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, timedelta, tzinfo
from typing import Any, Callable

from .chat_documents import validate_chart
from .registry import ToolRegistry
from .sqlite_tuning import tune_connection

DASHBOARD_KEY = "user"
MAX_WIDGETS = 40
MAX_DOCUMENT_BYTES = 128 * 1024
MAX_TITLE = 60
MAX_ENTRIES = 2000
MAX_OP_IDS = 200
#: How many tracker entries the ``get`` result shows the model (the newest).
TOOL_ENTRIES_SHOWN = 20

WIDGET_TYPES = ("tracker", "metric", "checklist", "note", "chart", "agenda", "prompts", "weather")
SIZES = ("half", "full")
TRACKER_ICONS = ("dumbbell", "run", "water", "book", "sleep", "heart", "check")
TRACKER_PERIODS = ("day", "week")
METRIC_TONES = ("good", "warn", "bad", "neutral")
WEATHER_UNITS = ("C", "F")
ACTIONS = ("get", "add", "update", "remove", "move", "log", "check")
APP_ACTIONS = ("log", "check", "remove", "move", "update")

COMMON_FIELDS = ("id", "type", "title", "size", "by", "updated_at")
TYPE_FIELDS: dict[str, tuple[str, ...]] = {
    "tracker": ("unit", "goal", "period", "steps", "icon", "entries"),
    "metric": ("value", "unit", "delta", "tone", "trend", "caption"),
    "checklist": ("items",),
    "note": ("text",),
    "chart": ("spec",),
    "agenda": ("date", "items"),
    "prompts": ("items",),
    "weather": ("place", "current", "daily", "unit"),
}
#: The catalogue in one line per type, for the tool description and errors.
CATALOGUE = {
    "tracker": "goal (number>0, required), unit, period (day|week), steps (1-3 positive numbers), "
               "icon (" + "|".join(TRACKER_ICONS) + "), entries [{at, value}]",
    "metric": "value (number or text, required), unit, delta (text like '+4 %'), "
              "tone (good|warn|bad|neutral), trend (up to 60 numbers, oldest first), caption",
    "checklist": "items [{id, text (<=200), done}] (<=50)",
    "note": "text (Markdown, <=4000)",
    "chart": "spec (chart JSON: kind bar|column_delta|line|grouped|stacked, title, unit, "
             "points [{label, value}] or series [{name, points}], <=60 points)",
    "agenda": "date (YYYY-MM-DD), items [{time HH:MM, title, place}] (<=30)",
    "prompts": "items [{label (<=30), prompt}] (<=6)",
    "weather": "place, current {temp, condition, code (WMO)}, daily [{date, code, max, min}] (<=7), unit (C|F)",
}

_ID = re.compile(r"^[a-z0-9_-]{1,40}$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


class DashboardError(ValueError):
    """A refused write. The message says why, for the model and the app."""


@dataclass
class DashboardResult:
    """What one action did. ``changed`` is False for ``get`` and for a
    duplicate ``op_id``; ``message`` is the short text for the model."""

    dashboard: dict
    message: str
    changed: bool = False
    duplicate: bool = False


# --- small validators --------------------------------------------------------


def _is_number(value: Any) -> bool:
    return (type(value) in (int, float) and value == value
            and value not in (float("inf"), float("-inf")))


def _number(value: Any, where: str) -> float | int:
    if not _is_number(value):
        raise DashboardError(f"{where} must be a number")
    return value


def _text(value: Any, where: str, limit: int | None = None, required: bool = False) -> str:
    if not isinstance(value, str):
        raise DashboardError(f"{where} must be text")
    if required and not value.strip():
        raise DashboardError(f"{where} must not be empty")
    if limit is not None and len(value) > limit:
        raise DashboardError(f"{where} is longer than {limit} characters")
    return value


def _keys(obj: Any, allowed: tuple[str, ...], where: str) -> dict:
    if not isinstance(obj, dict):
        raise DashboardError(f"{where} must be an object")
    unknown = sorted(set(obj) - set(allowed))
    if unknown:
        raise DashboardError(f"{where} has unknown fields {unknown}; allowed: {', '.join(allowed)}")
    return obj


def _list(value: Any, where: str, limit: int) -> list:
    if not isinstance(value, list):
        raise DashboardError(f"{where} must be a list")
    if len(value) > limit:
        raise DashboardError(f"{where} has more than {limit} entries")
    return value


def _fmt(value: float | int) -> str:
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, float):
        return f"{value:.2f}".rstrip("0").rstrip(".")
    return str(value)


def slugify(title: str) -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "-", title.lower()).strip("-_")
    slug = re.sub(r"-{2,}", "-", slug)[:40].strip("-_")
    return slug or "widget"


def _unique_id(base: str, taken: set[str]) -> str:
    if base not in taken:
        return base
    for n in range(2, 1000):
        suffix = f"-{n}"
        candidate = base[: 40 - len(suffix)] + suffix
        if candidate not in taken:
            return candidate
    raise DashboardError("could not make a unique widget id; pass one")


# --- the catalogue -----------------------------------------------------------


def _validate_tracker(w: dict, parse_at: Callable[[Any, str], datetime]) -> None:
    if "goal" not in w:
        raise DashboardError("tracker needs goal (a number > 0)")
    if _number(w["goal"], "tracker goal") <= 0:
        raise DashboardError("tracker goal must be > 0")
    w.setdefault("unit", "")
    _text(w["unit"], "tracker unit", 20)
    w.setdefault("period", "day")
    if w["period"] not in TRACKER_PERIODS:
        raise DashboardError("tracker period must be day or week")
    w.setdefault("steps", [1, 10, 25])
    steps = w["steps"]
    if (not isinstance(steps, list) or not 1 <= len(steps) <= 3
            or any(not _is_number(s) or s <= 0 for s in steps)):
        raise DashboardError("tracker steps must be 1-3 positive numbers, such as [1, 10, 25]")
    w.setdefault("icon", "check")
    if w["icon"] not in TRACKER_ICONS:
        raise DashboardError("tracker icon must be one of " + ", ".join(TRACKER_ICONS))
    w.setdefault("entries", [])
    entries = w["entries"]
    if not isinstance(entries, list):
        raise DashboardError("tracker entries must be a list of {at, value}")
    clean = []
    for index, entry in enumerate(entries, 1):
        _keys(entry, ("at", "value"), f"tracker entry {index}")
        _number(entry.get("value"), f"tracker entry {index} value")
        at = parse_at(entry.get("at"), f"tracker entry {index} at")
        clean.append((at, {"at": at.isoformat(timespec="seconds"), "value": entry["value"]}))
    clean.sort(key=lambda pair: pair[0])
    w["entries"] = [e for _, e in clean[-MAX_ENTRIES:]]


def _validate_metric(w: dict) -> None:
    if "value" not in w:
        raise DashboardError("metric needs value (a number or text)")
    if not (_is_number(w["value"]) or isinstance(w["value"], str)):
        raise DashboardError("metric value must be a number or text")
    if isinstance(w["value"], str):
        _text(w["value"], "metric value", 40)
    for key, limit in (("unit", 20), ("delta", 20), ("caption", 200)):
        if key in w:
            _text(w[key], f"metric {key}", limit)
    if "tone" in w and w["tone"] not in METRIC_TONES:
        raise DashboardError("metric tone must be one of " + ", ".join(METRIC_TONES))
    if "trend" in w:
        for value in _list(w["trend"], "metric trend", 60):
            _number(value, "metric trend value")


def _validate_checklist(w: dict) -> None:
    items = _list(w.setdefault("items", []), "checklist items", 50)
    taken: set[str] = set()
    for index, item in enumerate(items, 1):
        where = f"checklist item {index}"
        _keys(item, ("id", "text", "done"), where)
        _text(item.get("text"), f"{where} text", 200, required=True)
        item.setdefault("done", False)
        if not isinstance(item["done"], bool):
            raise DashboardError(f"{where} done must be true or false")
        if "id" not in item or item["id"] in ("", None):
            item["id"] = _unique_id(slugify(item["text"]), taken)
        if not isinstance(item["id"], str) or not _ID.fullmatch(item["id"]):
            raise DashboardError(f"{where} id must match [a-z0-9_-]{{1,40}}")
        if item["id"] in taken:
            raise DashboardError(f"{where} id {item['id']!r} is used twice")
        taken.add(item["id"])


def _validate_note(w: dict) -> None:
    _text(w.setdefault("text", ""), "note text", 4000)


def _validate_chart(w: dict) -> None:
    if "spec" not in w:
        raise DashboardError("chart needs spec (the chart JSON with points or series)")
    try:
        validate_chart(w["spec"])
    except ValueError as exc:
        raise DashboardError(str(exc)) from None
    spec = w["spec"]
    total = (len(spec["points"]) if "points" in spec
             else sum(len(s["points"]) for s in spec["series"]))
    if total > 60:
        raise DashboardError("chart has more than 60 points in all")


def _validate_agenda(w: dict) -> None:
    if "date" in w and (not isinstance(w["date"], str) or not _DATE.fullmatch(w["date"])):
        raise DashboardError("agenda date must be YYYY-MM-DD")
    items = _list(w.setdefault("items", []), "agenda items", 30)
    for index, item in enumerate(items, 1):
        where = f"agenda item {index}"
        _keys(item, ("time", "title", "place"), where)
        if not isinstance(item.get("time"), str) or not _TIME.fullmatch(item["time"]):
            raise DashboardError(f"{where} time must be HH:MM")
        _text(item.get("title"), f"{where} title", 120, required=True)
        if "place" in item:
            _text(item["place"], f"{where} place", 120)


def _validate_prompts(w: dict) -> None:
    items = _list(w.setdefault("items", []), "prompts items", 6)
    for index, item in enumerate(items, 1):
        where = f"prompts item {index}"
        _keys(item, ("label", "prompt"), where)
        _text(item.get("label"), f"{where} label", 30, required=True)
        _text(item.get("prompt"), f"{where} prompt", 2000, required=True)


def _validate_weather(w: dict) -> None:
    if "place" in w:
        _text(w["place"], "weather place", 80)
    w.setdefault("unit", "C")
    if w["unit"] not in WEATHER_UNITS:
        raise DashboardError("weather unit must be C or F")
    if "current" in w:
        current = _keys(w["current"], ("temp", "condition", "code"), "weather current")
        if "temp" in current:
            _number(current["temp"], "weather current temp")
        if "condition" in current:
            _text(current["condition"], "weather current condition", 60)
        if "code" in current and type(current["code"]) is not int:
            raise DashboardError("weather current code must be a WMO code (a whole number)")
    daily = _list(w.setdefault("daily", []), "weather daily", 7)
    for index, day in enumerate(daily, 1):
        where = f"weather day {index}"
        _keys(day, ("date", "code", "max", "min"), where)
        if not isinstance(day.get("date"), str) or not _DATE.fullmatch(day["date"]):
            raise DashboardError(f"{where} date must be YYYY-MM-DD")
        if "code" in day and type(day["code"]) is not int:
            raise DashboardError(f"{where} code must be a WMO code (a whole number)")
        for key in ("max", "min"):
            if key in day:
                _number(day[key], f"{where} {key}")


# --- the store ---------------------------------------------------------------


Listener = Callable[[dict], None]


class DashboardStore:
    """The host's one dashboard. Safe to share between threads: every call
    opens its own connection and every write is one ``BEGIN IMMEDIATE``.

    ``clock`` returns the current time (aware); ``tz`` is the zone the tracker
    maths uses for "today". ``None`` for ``tz`` is the system's local zone,
    with its daylight-saving rules."""

    def __init__(self, db_path: str, *, clock: Callable[[], datetime] | None = None,
                 tz: tzinfo | None = None) -> None:
        self.path = db_path
        self._tz = tz
        self._clock = clock
        self._listeners: list[Listener] = []
        self._listeners_lock = threading.Lock()
        with self._connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS dashboard ("
                       "key TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS dashboard_ops ("
                       "seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE)")

    @contextmanager
    def _connect(self):
        db = tune_connection(sqlite3.connect(self.path, timeout=10))
        try:
            with db:
                yield db
        finally:
            db.close()

    # -- time ------------------------------------------------------------

    def now(self) -> datetime:
        now = self._clock() if self._clock is not None else datetime.now(self._tz)
        return self._local(now)

    def _local(self, moment: datetime) -> datetime:
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=self._tz) if self._tz else moment.astimezone()
        return moment.astimezone(self._tz) if self._tz else moment.astimezone()

    def parse_at(self, value: Any, where: str = "at") -> datetime:
        """An ISO 8601 time. One without an offset is read as local time."""
        if not isinstance(value, str) or not value.strip():
            raise DashboardError(f"{where} must be an ISO 8601 time, such as 2026-11-02T08:10:00+01:00")
        try:
            moment = datetime.fromisoformat(value.strip())
        except ValueError:
            raise DashboardError(
                f"{where} must be an ISO 8601 time, such as 2026-11-02T08:10:00+01:00") from None
        return self._local(moment)

    # -- listeners -------------------------------------------------------

    def add_listener(self, listener: Listener) -> None:
        with self._listeners_lock:
            self._listeners.append(listener)

    def remove_listener(self, listener: Listener) -> None:
        with self._listeners_lock:
            if listener in self._listeners:
                self._listeners.remove(listener)

    def _notify(self, doc: dict) -> None:
        with self._listeners_lock:
            listeners = list(self._listeners)
        for listener in listeners:
            try:
                listener(copy.deepcopy(doc))
            except Exception:  # noqa: BLE001,S110 — a push never breaks a write
                pass

    # -- reading ---------------------------------------------------------

    def get(self) -> dict:
        with self._connect() as db:
            return self._load(db)

    @staticmethod
    def _load(db) -> dict:
        row = db.execute("SELECT payload FROM dashboard WHERE key=?", (DASHBOARD_KEY,)).fetchone()
        return json.loads(row[0]) if row else {"version": 0, "widgets": []}

    # -- tracker maths (§3) ----------------------------------------------

    def _period_start(self, moment: datetime, period: str) -> date:
        day = self._local(moment).date()
        return day - timedelta(days=day.weekday()) if period == "week" else day

    def tracker_summary(self, widget: dict) -> dict:
        period = widget.get("period", "day")
        goal = widget.get("goal") or 0
        sums: dict[date, float] = {}
        for entry in widget.get("entries", []):
            try:
                key = self._period_start(self.parse_at(entry["at"]), period)
            except (DashboardError, KeyError):
                continue
            sums[key] = sums.get(key, 0) + entry.get("value", 0)
        current = self._period_start(self.now(), period)
        step = timedelta(days=7 if period == "week" else 1)
        today = sums.get(current, 0)
        cursor = current if goal and today >= goal else current - step
        streak = 0
        while goal and sums.get(cursor, 0) >= goal:
            streak += 1
            cursor -= step
        return {"today": today, "goal": goal, "unit": widget.get("unit", ""),
                "period": period, "streak": streak, "reached": bool(goal) and today >= goal}

    def summary_text(self, widget: dict) -> str:
        s = self.tracker_summary(widget)
        label = "this week" if s["period"] == "week" else "today"
        unit = f" {s['unit']}" if s["unit"] else ""
        return f"{label} {_fmt(s['today'])}/{_fmt(s['goal'])}{unit}, streak {s['streak']}"

    # -- writing ---------------------------------------------------------

    def apply(self, action: str, args: dict | None = None, *, by: str,
              op_id: str | None = None) -> DashboardResult:
        """Run one action of the tool (§4) or the app (§5). Raises
        :class:`DashboardError` for a refused write; nothing is stored then."""
        args = dict(args or {})
        if action not in ACTIONS:
            raise DashboardError("action must be one of " + ", ".join(ACTIONS))
        if action == "get":
            return DashboardResult(self.get(), "")
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            doc = self._load(db)
            if op_id and db.execute("SELECT 1 FROM dashboard_ops WHERE op_id=?",
                                    (op_id,)).fetchone():
                return DashboardResult(doc, f"op {op_id} was applied before (version {doc['version']})",
                                       duplicate=True)
            expected = args.pop("expected_version", None)
            if expected is not None and expected != doc["version"]:
                raise DashboardError(
                    f"the dashboard changed: it is at version {doc['version']}, not {expected}. "
                    "Call action=get and try again.")
            new = copy.deepcopy(doc)
            message = getattr(self, f"_do_{action}")(new, args, by)
            new["version"] = doc["version"] + 1
            raw = json.dumps(new, ensure_ascii=False, allow_nan=False)
            if len(raw.encode()) > MAX_DOCUMENT_BYTES:
                raise DashboardError("the dashboard would exceed 128 KiB; remove or shorten widgets")
            db.execute("INSERT INTO dashboard VALUES(?,?) ON CONFLICT(key) "
                       "DO UPDATE SET payload=excluded.payload", (DASHBOARD_KEY, raw))
            if op_id:
                db.execute("INSERT INTO dashboard_ops(op_id) VALUES(?)", (op_id,))
                db.execute("DELETE FROM dashboard_ops WHERE seq <= "
                           "(SELECT MAX(seq) FROM dashboard_ops) - ?", (MAX_OP_IDS,))
        self._notify(new)
        return DashboardResult(new, f"{message} (version {new['version']})", changed=True)

    def _stamp(self, widget: dict, by: str) -> None:
        widget["by"] = (by or "Agent")[:60]
        widget["updated_at"] = self.now().isoformat(timespec="seconds")

    def _validate(self, widget: dict) -> dict:
        if not isinstance(widget, dict):
            raise DashboardError("widget must be an object")
        kind = widget.get("type")
        if kind not in WIDGET_TYPES:
            raise DashboardError(
                f"unknown widget type {kind!r}; allowed types: " + ", ".join(WIDGET_TYPES))
        allowed = COMMON_FIELDS + TYPE_FIELDS[kind]
        unknown = sorted(set(widget) - set(allowed))
        if unknown:
            raise DashboardError(
                f"{kind} has unknown fields {unknown}; allowed: {', '.join(allowed)}. "
                f"{kind}: {CATALOGUE[kind]}")
        _text(widget.get("title"), "title", MAX_TITLE, required=True)
        widget["title"] = widget["title"].strip()
        widget.setdefault("size", "half" if kind in ("tracker", "metric") else "full")
        if widget["size"] not in SIZES:
            raise DashboardError("size must be half or full")
        try:
            if kind == "tracker":
                _validate_tracker(widget, self.parse_at)
            else:
                globals()[f"_validate_{kind}"](widget)
        except DashboardError as exc:
            raise DashboardError(f"{exc}. {kind}: {CATALOGUE[kind]}") from None
        return widget

    @staticmethod
    def _find(doc: dict, widget_id: Any) -> tuple[int, dict]:
        for index, widget in enumerate(doc["widgets"]):
            if widget.get("id") == widget_id:
                return index, widget
        ids = ", ".join(w.get("id", "?") for w in doc["widgets"]) or "none"
        raise DashboardError(f"no widget with id {widget_id!r}; ids: {ids}")

    @staticmethod
    def _index(value: Any, size: int) -> int:
        if value is None:
            return size
        if type(value) is not int:
            raise DashboardError("index must be a whole number (0 is the first place)")
        return max(0, min(value, size))

    def _do_add(self, doc: dict, args: dict, by: str) -> str:
        widget = args.get("widget")
        if not isinstance(widget, dict):
            raise DashboardError("add needs widget, an object with type and title. Types: "
                                 + "; ".join(f"{k}: {v}" for k, v in CATALOGUE.items()))
        if len(doc["widgets"]) >= MAX_WIDGETS:
            raise DashboardError(f"the dashboard holds at most {MAX_WIDGETS} widgets; remove one first")
        widget = copy.deepcopy(widget)
        widget.pop("by", None)
        widget.pop("updated_at", None)
        taken = {w["id"] for w in doc["widgets"]}
        if widget.get("id") in (None, ""):
            widget["id"] = _unique_id(slugify(str(widget.get("title") or widget.get("type") or "")), taken)
        elif not isinstance(widget["id"], str) or not _ID.fullmatch(widget["id"]):
            raise DashboardError("id must match [a-z0-9_-]{1,40}; leave it out to make one from the title")
        elif widget["id"] in taken:
            raise DashboardError(f"a widget with id {widget['id']!r} exists; use update or another id")
        self._validate(widget)
        self._stamp(widget, by)
        index = self._index(args.get("index"), len(doc["widgets"]))
        doc["widgets"].insert(index, widget)
        text = f"added {widget['type']} {widget['title']!r} (id {widget['id']}) at place {index}"
        if widget["type"] == "tracker":
            text += f": {self.summary_text(widget)}"
        return text

    def _do_update(self, doc: dict, args: dict, by: str) -> str:
        index, old = self._find(doc, args.get("id"))
        patch = args.get("patch")
        if not isinstance(patch, dict) or not patch:
            raise DashboardError("update needs patch, an object of the fields to change")
        if "type" in patch and patch["type"] != old["type"]:
            raise DashboardError("type cannot change; remove the widget and add a new one")
        if "id" in patch and patch["id"] != old["id"]:
            raise DashboardError("id cannot change")
        patch = {k: v for k, v in patch.items() if k not in ("by", "updated_at")}
        widget = {**copy.deepcopy(old), **copy.deepcopy(patch)}
        self._validate(widget)
        self._stamp(widget, by)
        doc["widgets"][index] = widget
        return f"updated {widget['title']!r} ({', '.join(sorted(patch)) or 'nothing'})"

    def _do_remove(self, doc: dict, args: dict, by: str) -> str:
        index, widget = self._find(doc, args.get("id"))
        del doc["widgets"][index]
        return f"removed {widget['title']!r}"

    def _do_move(self, doc: dict, args: dict, by: str) -> str:
        index, widget = self._find(doc, args.get("id"))
        if args.get("index") is None:
            raise DashboardError("move needs index (0 is the first place)")
        del doc["widgets"][index]
        target = self._index(args.get("index"), len(doc["widgets"]))
        doc["widgets"].insert(target, widget)
        return f"moved {widget['title']!r} to place {target}"

    def _do_log(self, doc: dict, args: dict, by: str) -> str:
        index, widget = self._find(doc, args.get("id"))
        if widget["type"] != "tracker":
            raise DashboardError(f"log works on a tracker; {widget['id']!r} is a {widget['type']}")
        value = args.get("value")
        if not _is_number(value) or value == 0:
            raise DashboardError("log needs value, a number that is not 0 (negative corrects)")
        at = self.parse_at(args["at"]) if args.get("at") else self.now()
        widget = copy.deepcopy(widget)
        widget["entries"] = [*widget.get("entries", []),
                             {"at": at.isoformat(timespec="seconds"), "value": value}]
        self._validate(widget)
        self._stamp(widget, by)
        doc["widgets"][index] = widget
        unit = f" {widget['unit']}" if widget.get("unit") else ""
        return f"logged {_fmt(value)}{unit} to {widget['title']}: {self.summary_text(widget)}"

    def _do_check(self, doc: dict, args: dict, by: str) -> str:
        index, widget = self._find(doc, args.get("id"))
        if widget["type"] != "checklist":
            raise DashboardError(f"check works on a checklist; {widget['id']!r} is a {widget['type']}")
        done = args.get("done", True)
        if not isinstance(done, bool):
            raise DashboardError("done must be true or false")
        widget = copy.deepcopy(widget)
        for item in widget["items"]:
            if item["id"] == args.get("item"):
                item["done"] = done
                break
        else:
            ids = ", ".join(i["id"] for i in widget["items"]) or "none"
            raise DashboardError(f"no item {args.get('item')!r} in {widget['title']!r}; items: {ids}")
        self._stamp(widget, by)
        doc["widgets"][index] = widget
        left = sum(1 for i in widget["items"] if not i["done"])
        return (f"{'ticked' if done else 'unticked'} {item['text']!r} in {widget['title']}: "
                f"{left} of {len(widget['items'])} open")

    # -- the view for the model ------------------------------------------

    def model_view(self, doc: dict | None = None) -> dict:
        """The document for the ``get`` action: trackers carry a summary and
        only their newest entries, so a long history does not fill the
        model's context."""
        doc = copy.deepcopy(doc if doc is not None else self.get())
        for widget in doc["widgets"]:
            if widget.get("type") == "tracker":
                entries = widget.get("entries", [])
                widget["summary"] = self.summary_text(widget)
                if len(entries) > TOOL_ENTRIES_SHOWN:
                    widget["entries"] = entries[-TOOL_ENTRIES_SHOWN:]
                    widget["entries_total"] = len(entries)
        return doc


# --- the tool ----------------------------------------------------------------

TOOL_DESCRIPTION = (
    "The user's Home dashboard in the app: add widgets such as a tracker (push-ups, water), "
    "metric, checklist, note, chart, agenda, prompts, weather; log values. One dashboard for "
    "the user, shared by all agents. The app draws native widgets: never write HTML. "
    "Actions: get; add {widget, index?}; update {id, patch}; remove {id}; move {id, index}; "
    "log {id, value, at?} (tracker; negative value corrects); check {id, item, done}. "
    "Pass expected_version from get on writes. Every widget: type, title (<=60), id "
    "([a-z0-9_-], made from the title if left out), size (half|full). Types: "
    + "; ".join(f"{k}: {v}" for k, v in CATALOGUE.items())
    + ". Example: add widget={\"type\":\"tracker\",\"title\":\"Push-ups\",\"unit\":\"reps\","
    "\"goal\":100,\"icon\":\"dumbbell\"}."
)


def register_dashboard_tool(registry: ToolRegistry, store: DashboardStore,
                            by: str | Callable[[], str] = "Agent") -> None:
    """The ``dashboard`` tool (§4). ``by`` is the agent's name, stamped on
    every widget it changes."""

    def dashboard(action: str, id: str | None = None, widget: dict | None = None,
                  patch: dict | None = None, index: int | None = None,
                  value: float | None = None, at: str | None = None,
                  item: str | None = None, done: bool | None = None,
                  expected_version: int | None = None):
        if action == "get":
            return store.model_view()
        args = {k: v for k, v in (("id", id), ("widget", widget), ("patch", patch),
                                  ("index", index), ("value", value), ("at", at),
                                  ("item", item), ("done", done),
                                  ("expected_version", expected_version)) if v is not None}
        name = by() if callable(by) else by
        try:
            return store.apply(action, args, by=name).message
        except DashboardError as exc:
            return f"refused, nothing was stored: {exc}"

    registry.register("dashboard", {
        "type": "object",
        "description": TOOL_DESCRIPTION,
        "properties": {
            "action": {"type": "string", "enum": list(ACTIONS)},
            "id": {"type": "string", "description": "the widget id"},
            "widget": {"type": "object", "description": "for add: the widget without by/updated_at"},
            "patch": {"type": "object", "description": "for update: the fields to change (top level)"},
            "index": {"type": "integer", "description": "the place, 0 is the first"},
            "value": {"type": "number", "description": "for log"},
            "at": {"type": "string", "description": "for log: ISO 8601 time, default now"},
            "item": {"type": "string", "description": "for check: the checklist item id"},
            "done": {"type": "boolean"},
            "expected_version": {"type": "integer"},
        },
        "required": ["action"],
    # Not deferrable: "track my push-ups" must find the tool at once, and the
    # schema is small. The description carries the catalogue.
    }, dashboard)


# --- the frames (§5) ---------------------------------------------------------


def handle_dashboard_frame(store: DashboardStore, payload: dict) -> dict:
    """Answer one ``dashboard_get`` / ``dashboard_op`` frame of the app: a
    ``dashboard_state`` (with the op's ``op_id``), or a ``dashboard_error``
    when the op is refused. A duplicate ``op_id`` is answered again, not
    applied again."""
    kind = payload.get("type")
    if kind == "dashboard_get":
        return {"type": "dashboard_state", "dashboard": store.get()}
    op_id = payload.get("op_id")
    op_id = op_id if isinstance(op_id, str) and op_id else None
    action = payload.get("action")
    try:
        if op_id is None:
            raise DashboardError("dashboard_op needs op_id")
        if action not in APP_ACTIONS:
            raise DashboardError("action must be one of " + ", ".join(APP_ACTIONS))
        args = {k: v for k, v in payload.items() if k not in ("type", "op_id", "action")}
        result = store.apply(action, args, by="You", op_id=op_id)
    except DashboardError as exc:
        return {"type": "dashboard_error", "op_id": op_id or "", "message": str(exc)}
    return {"type": "dashboard_state", "dashboard": result.dashboard, "op_id": op_id}
