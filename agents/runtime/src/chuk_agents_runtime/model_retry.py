"""Autonomous retry of a failed model call (Plane CHAT-31).

The host keeps running when the app is closed, so a provider hiccup must not
end a task and wait for a "Resend" tap. When the model call fails in a way
that can pass (a timeout, a 5xx, a 429, a network error, an empty stream), the
loop waits and asks the model again, by itself:

* quick retries first (``QUICK_DELAYS``: 2, 5, 15, 30 s),
* then once per ``SLOW_INTERVAL`` (60 s),
* until ``window`` seconds (30 min by default) have passed since the first
  failure of this call. Then the turn fails with a clear reason.

Only the model request is asked again. A tool that already ran keeps its
stored result: the loop rebuilds the request from the store, which holds every
finished turn and every tool result (``loop._process_history``).

A ``Retry-After`` header of a 429/503 is respected (bounded by the slow
interval, so the app never shows a wait of hours).

Environment: ``AGENTS_MODEL_RETRY_WINDOW_S`` sets the window; ``0`` turns
the autonomous retry off (the first failure ends the turn, as before).
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import Callable, Sequence

#: Waits before the first retries, in seconds.
QUICK_DELAYS: tuple[float, ...] = (2.0, 5.0, 15.0, 30.0)
#: The wait between retries after the quick ones.
SLOW_INTERVAL = 60.0
#: How long one model call is retried, from its first failure.
DEFAULT_WINDOW = 30 * 60.0

#: HTTP statuses that can pass: the request was fine, the service was not.
RETRYABLE_STATUSES = frozenset({408, 409, 425, 429, 500, 502, 503, 504})


@dataclass(frozen=True)
class RetryPolicy:
    quick_delays: Sequence[float] = QUICK_DELAYS
    slow_interval: float = SLOW_INTERVAL
    window: float = DEFAULT_WINDOW

    @classmethod
    def from_env(cls) -> "RetryPolicy":
        raw = os.environ.get("AGENTS_MODEL_RETRY_WINDOW_S", "").strip()
        try:
            window = float(raw) if raw else DEFAULT_WINDOW
        except ValueError:
            window = DEFAULT_WINDOW
        return cls(window=max(0.0, window))

    @property
    def enabled(self) -> bool:
        return self.window > 0

    def delay(self, attempt: int, retry_after: float | None = None) -> float:
        """The wait before retry number ``attempt`` (1 = the first retry)."""
        if attempt <= len(self.quick_delays):
            base = float(self.quick_delays[attempt - 1])
        else:
            base = float(self.slow_interval)
        if retry_after is not None and retry_after > base:
            return min(retry_after, max(base, self.slow_interval))
        return base


#: How long a model call is retried when a person waits for the answer.
#: The 30 min window is for a run nobody watches (an automation, a mail).
#: On 2026-11-12 a typed message was retried for 23 and for 31 minutes; the
#: person saw nothing and could not pick another model in that time.
ATTENDED_WINDOW = 3 * 60.0


def attended_policy(policy: RetryPolicy, attended: bool) -> RetryPolicy:
    """``policy``, with the short window when a person waits for the run."""
    if not attended or policy.window <= ATTENDED_WINDOW:
        return policy
    return RetryPolicy(
        quick_delays=policy.quick_delays,
        slow_interval=policy.slow_interval,
        window=ATTENDED_WINDOW,
    )


class EmptyModelResponse(RuntimeError):
    """The stream closed without a single part and without a finish reason:
    the provider dropped the answer, the request itself was fine."""

    def __init__(self) -> None:
        super().__init__("the model sent an empty answer")


def _chain(exc: BaseException) -> list[BaseException]:
    seen: list[BaseException] = []
    current: BaseException | None = exc
    while current is not None and current not in seen and len(seen) < 8:
        seen.append(current)
        current = current.__cause__ or current.__context__
    return seen


def _status(exc: BaseException) -> int | None:
    for name in ("status_code", "status"):
        value = getattr(exc, name, None)
        if isinstance(value, int) and 100 <= value <= 599:
            return value
    response = getattr(exc, "response", None)
    value = getattr(response, "status_code", None)
    return value if isinstance(value, int) else None


def _is_network_error(exc: BaseException) -> bool:
    """A transport failure: no answer, a cut connection, a timeout."""
    if isinstance(exc, (TimeoutError, ConnectionError, EmptyModelResponse)):
        return True
    names = {cls.__name__ for cls in type(exc).__mro__}
    return bool(
        names
        & {
            # httpx / httpx2
            "TransportError",
            "TimeoutException",
            "NetworkError",
            "RemoteProtocolError",
            # openai SDK
            "APIConnectionError",
            "APITimeoutError",
            # the loop's own "nothing for 45 s"
            "FirstEventTimeout",
            # an error event inside a started stream (the route's
            # ``upstream_interrupted``): no status, the request was fine
            "APIError",
        }
    )


def classify(exc: BaseException) -> tuple[bool, str]:
    """``(retryable, reason)`` for a failed model call. ``reason`` is short
    text for the app and the log ("HTTP 503", "network error", ...)."""
    for item in _chain(exc):
        status = _status(item)
        if status is not None:
            if status in RETRYABLE_STATUSES or 520 <= status <= 599:
                return True, "rate limited" if status == 429 else f"HTTP {status}"
            # 4xx: the request itself is wrong (402 no credits, 400, 401, ...).
            return False, f"HTTP {status}"
        if isinstance(item, EmptyModelResponse):
            return True, "empty answer"
        if type(item).__name__ == "FirstEventTimeout":
            return True, "no answer"
        if _is_network_error(item):
            return True, "network error"
    # A pydantic-ai ``ModelAPIError`` without a status is a connection failure.
    if any(type(item).__name__ == "ModelAPIError" for item in _chain(exc)):
        return True, "network error"
    return False, type(exc).__name__


def retry_after_seconds(exc: BaseException) -> float | None:
    """The ``Retry-After`` header of the failure, in seconds, if any."""
    for item in _chain(exc):
        headers = getattr(item, "headers", None)
        if headers is None:
            response = getattr(item, "response", None)
            headers = getattr(response, "headers", None)
        if not headers:
            continue
        try:
            raw = headers.get("retry-after") or headers.get("Retry-After")
        except Exception:  # noqa: BLE001 — odd header object: no hint
            continue
        if raw is None:
            continue
        try:
            return max(0.0, float(raw))
        except (TypeError, ValueError):
            return None
    return None


@dataclass
class RetryTracker:
    """The retries of one model call. ``next_delay`` says how long to wait
    before the next retry, or ``None`` when the window is used up."""

    policy: RetryPolicy
    clock: Callable[[], float] = time.monotonic
    attempts: int = 0
    first_failure: float | None = None
    last_reason: str = ""
    #: The last failure could pass, but the window is used up.
    gave_up: bool = False
    history: list[str] = field(default_factory=list)

    def next_delay(self, exc: BaseException) -> float | None:
        retryable, reason = classify(exc)
        self.last_reason = reason
        self.history.append(reason)
        self.gave_up = False
        if not retryable or not self.policy.enabled:
            return None
        now = self.clock()
        if self.first_failure is None:
            self.first_failure = now
        self.attempts += 1
        delay = self.policy.delay(self.attempts, retry_after_seconds(exc))
        if now + delay - self.first_failure > self.policy.window:
            self.attempts -= 1
            self.gave_up = True
            return None
        return delay

    def reset(self) -> None:
        self.attempts = 0
        self.first_failure = None
        self.gave_up = False

    def give_up_message(self) -> str:
        """What the app shows when the window is used up."""
        if self.first_failure is None:
            return f"The model service failed ({self.last_reason}). Send the message again."
        minutes = max(1, round((self.clock() - self.first_failure) / 60))
        return (
            f"The model service did not answer for {minutes} min "
            f"({self.attempts} tries, last error: {self.last_reason}), so the "
            "task stopped. Send the message again later, or pick another model."
        )
