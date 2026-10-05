"""What a run cost, in euro, at the price the chuk API really charges
(docs/WIRE_CONTRACT.md, "Cost per run and weekly budget", bead chuk_chat-qcbv).

The price source is the account's own ``GET /v1/models_info`` list, which the
host already reads once at start: every model names its providers, and every
provider carries ``pricing`` in USD per token (``prompt``, ``completion``,
``cache_read``, ``cache_write``). That ``pricing`` is the discounted price the
API bills with (``api_server`` ``routers/ai/multiplex.py``, ``_bill_usage``),
not ``pricing_listed``. The API deducts credits 1:1 USD -> EUR
(``services/payment_service.py``, ``calculate_cost``), so the euro figure here
is the USD figure, the same as the app's balance.

The OpenAI-compatible route the agent loop uses does not send the charge back
(it strips OpenRouter's own ``cost``, which is our cost, not the user's
charge). So the host prices the usage itself with the same formula:

- the cached part of the prompt costs ``cache_read`` (``prompt`` when the
  provider lists no cache price: never free);
- the rest of the prompt costs ``prompt``;
- completion tokens (reasoning included) cost ``completion``.

A provider the API cannot find for the model is billed at the model's cheapest
provider by prompt price (``find_pricing_provider``); the same rule is here.

Rounding: the API rounds every call to 0.0001 EUR. The host prices the tokens
of a whole run at once, so a run's figure can differ from the sum of its bills
by at most 0.00005 EUR per model call.
"""

from __future__ import annotations

import datetime as _dt
import math
import threading
from collections.abc import Callable, Iterable, Mapping
from decimal import Decimal
from typing import Any

#: The currency of every figure on the wire. Credits are deducted 1:1 from
#: the USD price, and the app shows the balance in euro.
CURRENCY = "EUR"

#: Share of the weekly budget at which the host warns once.
BUDGET_WARN_RATIO = 0.8

#: Line kinds (``usage_lines.kind``, ``cost.lines[].kind``).
LINE_RUN = "run"
LINE_AUX = "aux"
LINE_BROWSER = "browser"


def _price(pricing: Mapping[str, Any] | None, key: str) -> Decimal:
    if not isinstance(pricing, Mapping):
        return Decimal(0)
    value = pricing.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return Decimal(0)
    try:
        number = Decimal(str(value))
    except ArithmeticError:
        return Decimal(0)
    if not number.is_finite() or number < 0:
        return Decimal(0)
    return number


def cost_eur(
    pricing: Mapping[str, Any] | None,
    *,
    prompt_tokens: int,
    completion_tokens: int,
    cached_tokens: int = 0,
) -> float:
    """The charge for these tokens at ``pricing`` (USD per token), in euro.

    The same formula as the API's ``payment_service.calculate_cost``:
    ``prompt_tokens`` includes ``cached_tokens``; the cached part costs
    ``cache_read`` (or ``prompt`` when there is no cache price). Not rounded
    to the API's 0.0001 per call: a run is priced as a whole."""
    prompt = max(0, int(prompt_tokens or 0))
    completion = max(0, int(completion_tokens or 0))
    cached = min(max(0, int(cached_tokens or 0)), prompt)
    prompt_price = _price(pricing, "prompt")
    cache_price = _price(pricing, "cache_read") or prompt_price
    total = (
        Decimal(prompt - cached) * prompt_price
        + Decimal(cached) * cache_price
        + Decimal(completion) * _price(pricing, "completion")
    )
    return float(total)


def round_eur(value: float) -> float:
    """Euro rounded for a frame: 6 decimals, so a cheap aux call still shows."""
    return round(float(value), 6)


class PriceBook:
    """``(model id, provider slug) -> pricing`` from a ``/v1/models_info`` list."""

    def __init__(self, models: Iterable[Mapping[str, Any]] | None = None) -> None:
        self._models: dict[str, list[dict[str, Any]]] = {}
        for entry in models or ():
            if not isinstance(entry, Mapping):
                continue
            model_id = entry.get("id")
            providers = entry.get("providers")
            if not isinstance(model_id, str) or not isinstance(providers, list):
                continue
            self._models[model_id] = [
                dict(p)
                for p in providers
                if isinstance(p, Mapping) and isinstance(p.get("pricing"), Mapping)
            ]

    def __bool__(self) -> bool:
        return bool(self._models)

    def pricing(self, model_id: str | None, provider: str | None) -> dict[str, Any] | None:
        """The pricing the API bills ``model_id`` on ``provider`` with, or
        ``None`` for a model the list does not know."""
        if not model_id:
            return None
        providers = self._models.get(model_id)
        if not providers:
            return None
        if provider:
            wanted = str(provider).lower()
            for entry in providers:
                if str(entry.get("slug") or "").lower() == wanted:
                    return dict(entry["pricing"])
        # The API's fallback (``find_pricing_provider``): the cheapest
        # provider by prompt price, so an unpinned call is never free.
        cheapest = min(providers, key=lambda e: float(_price(e.get("pricing"), "prompt")))
        return dict(cheapest["pricing"])

    def cost(
        self,
        model_id: str | None,
        provider: str | None,
        *,
        prompt_tokens: int,
        completion_tokens: int,
        cached_tokens: int = 0,
    ) -> float | None:
        """The run's charge in euro, or ``None`` when the model has no price."""
        pricing = self.pricing(model_id, provider)
        if pricing is None:
            return None
        return cost_eur(
            pricing,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            cached_tokens=cached_tokens,
        )


def cost_block(lines: Iterable[Mapping[str, Any]]) -> dict[str, Any] | None:
    """The ``cost`` block of a ``done`` frame from a run's summed usage lines
    (:meth:`chuk_agents_runtime.state.StateStore.usage_lines`).

    ``eur`` is the total only when every line is priced: a total that leaves
    out a line it could not price would be a wrong number, so it is absent
    then (the lines still carry the tokens). ``None`` when the run spent no
    tokens at all (a refused or failed run)."""
    out_lines: list[dict[str, Any]] = []
    total = 0.0
    complete = True
    sums = {"input_tokens": 0, "output_tokens": 0, "cached_tokens": 0}
    for line in lines:
        prompt = int(line.get("prompt_tokens") or 0)
        completion = int(line.get("completion_tokens") or 0)
        cached = int(line.get("cached_tokens") or 0)
        if not (prompt or completion):
            continue
        body: dict[str, Any] = {
            "kind": str(line.get("kind") or LINE_RUN),
            "input_tokens": prompt,
            "output_tokens": completion,
            "cached_tokens": cached,
        }
        if line.get("model"):
            body["model"] = str(line["model"])
        if line.get("provider"):
            body["provider"] = str(line["provider"])
        if line.get("calls"):
            body["calls"] = int(line["calls"])
        eur = line.get("cost_eur")
        if eur is None:
            complete = False
        else:
            body["eur"] = round_eur(float(eur))
            total += float(eur)
        sums["input_tokens"] += prompt
        sums["output_tokens"] += completion
        sums["cached_tokens"] += cached
        out_lines.append(body)
    if not out_lines:
        return None
    block: dict[str, Any] = {"currency": CURRENCY, **sums, "lines": out_lines}
    if complete:
        block["eur"] = round_eur(total)
    return block


# -- usage of the housekeeping clients (aux summary, memory, browser) --------


def usage_split(usage: Mapping[str, Any] | None) -> tuple[int, int, int]:
    """``(prompt, completion, cached)`` from a backend usage dict. Missing
    fields count as zero."""
    if not isinstance(usage, Mapping):
        return 0, 0, 0

    def first(*keys: str) -> int:
        for key in keys:
            value = usage.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
                return int(value)
        return 0

    cached = 0
    details = usage.get("prompt_tokens_details")
    if isinstance(details, Mapping):
        value = details.get("cached_tokens")
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
            cached = int(value)
    if not cached:
        cached = first("cached_tokens", "cache_read_tokens", "cache_read_input_tokens")
    return (
        first("prompt_tokens", "input_tokens"),
        first("completion_tokens", "output_tokens"),
        cached,
    )


#: ``(kind, model id, provider slug, usage dict)`` -> None.
UsageSink = Callable[[str, str | None, str | None, Mapping[str, Any]], None]


class MeteredClient:
    """A blocking :class:`~chuk_agents_runtime.model.ModelClient` that reports
    the usage of every call it makes to ``sink``, tagged with ``kind``.

    The executor wraps the aux client (context summary, memory extraction) and
    the browser client with it, so their calls become their own cost lines. A
    clone (``cheap_clone``, which a background summary job uses) is metered
    too, so a summary made after the run still lands in the books. Every other
    attribute passes through to the wrapped client."""

    def __init__(self, client: Any, sink: UsageSink, *, kind: str = LINE_AUX) -> None:
        self._client = client
        self._sink = sink
        self._kind = kind

    @property
    def wrapped(self) -> Any:
        return self._client

    def complete(self, messages: list[dict]) -> Any:
        response = self._client.complete(messages)
        raw = getattr(response, "raw", None)
        usage = raw.get("usage") if isinstance(raw, Mapping) else None
        if isinstance(usage, Mapping) and any(usage_split(usage)):
            try:
                self._sink(
                    self._kind,
                    getattr(self._client, "model_id", None),
                    getattr(self._client, "provider_slug", None),
                    usage,
                )
            except Exception:  # noqa: BLE001 — bookkeeping must not fail a call
                pass
        return response

    def cheap_clone(self, *args: Any, **kwargs: Any) -> "MeteredClient":
        clone = self._client.cheap_clone(*args, **kwargs)
        return MeteredClient(clone, self._sink, kind=self._kind)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._client, name)


def metered(client: Any, sink: UsageSink | None, *, kind: str = LINE_AUX) -> Any:
    """``client`` wrapped in a :class:`MeteredClient`, or as it is when there
    is no client or no sink. ``cheap_clone`` stays only when the client has
    one, so ``getattr(client, "cheap_clone", None)`` keeps its meaning."""
    if client is None or sink is None:
        return client
    if not callable(getattr(client, "cheap_clone", None)):
        return _MeteredNoClone(client, sink, kind=kind)
    return MeteredClient(client, sink, kind=kind)


class _MeteredNoClone(MeteredClient):
    """A metered client whose wrapped client cannot clone itself."""

    cheap_clone = None  # type: ignore[assignment]


# -- weeks and days ----------------------------------------------------------


def day_start(now: float | None = None) -> float:
    """Unix time of the host's local midnight today."""
    moment = _dt.datetime.fromtimestamp(now if now is not None else _now()).astimezone()
    midnight = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.timestamp()


def week_start(now: float | None = None) -> float:
    """Unix time of the host's local Monday 00:00 of this week (ISO week)."""
    moment = _dt.datetime.fromtimestamp(now if now is not None else _now()).astimezone()
    monday = (moment - _dt.timedelta(days=moment.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return monday.timestamp()


def _now() -> float:
    import time

    return time.time()


# -- the weekly budget -------------------------------------------------------

#: Budget states (``agent_status.cost.budget_state``, ``budget_warning.level``).
BUDGET_OK = "ok"
BUDGET_WARNING = "warning"
BUDGET_EXCEEDED = "exceeded"

#: The highest weekly budget a user may set, in euro. A typo guard, not a cap
#: on spending: 0 already means "no budget".
MAX_BUDGET_WEEKLY = 10_000.0


def budget_state(spent: float, budget: float) -> str:
    """``ok`` / ``warning`` (at 80 %) / ``exceeded`` (at 100 %). No budget
    (``budget <= 0``) is always ``ok``."""
    if budget <= 0:
        return BUDGET_OK
    if spent >= budget:
        return BUDGET_EXCEEDED
    if spent >= budget * BUDGET_WARN_RATIO:
        return BUDGET_WARNING
    return BUDGET_OK


def valid_budget(value: Any) -> float:
    """A ``budget_weekly`` value from the app, or :class:`ValueError`. A plain
    number (not a bool, not a string), finite, ``0 <= x <= 10000``."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("budget_weekly must be a number")
    number = float(value)
    if not math.isfinite(number) or number < 0 or number > MAX_BUDGET_WEEKLY:
        raise ValueError(f"budget_weekly must be between 0 and {MAX_BUDGET_WEEKLY:g}")
    return round(number, 2)


class BudgetNotices:
    """Which warning a coworker already got this week, so the host warns once
    per level and week. In memory: a host restart can repeat one warning."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._sent: dict[str, tuple[float, str]] = {}

    def first(self, agent_key: str, week: float, level: str) -> bool:
        """True the first time ``level`` is reached in ``week`` for the agent.
        ``exceeded`` after ``warning`` is a first too; a lower level after a
        higher one is not."""
        rank = {BUDGET_WARNING: 1, BUDGET_EXCEEDED: 2}
        if level not in rank:
            return False
        with self._lock:
            sent = self._sent.get(agent_key)
            if sent is not None and sent[0] == week and rank.get(sent[1], 0) >= rank[level]:
                return False
            self._sent[agent_key] = (week, level)
            return True


__all__ = [
    "BUDGET_EXCEEDED",
    "BUDGET_OK",
    "BUDGET_WARN_RATIO",
    "BUDGET_WARNING",
    "CURRENCY",
    "LINE_AUX",
    "LINE_BROWSER",
    "LINE_RUN",
    "MAX_BUDGET_WEEKLY",
    "BudgetNotices",
    "MeteredClient",
    "PriceBook",
    "UsageSink",
    "budget_state",
    "cost_block",
    "cost_eur",
    "day_start",
    "metered",
    "round_eur",
    "usage_split",
    "valid_budget",
    "week_start",
]
