"""Retry, then fall back to another model (CHAT-181, idea 4).

The loop retries a failed model call by itself (:mod:`.model_retry`). Before
this module it always asked the SAME model again, for up to 30 minutes, also
when the provider of that model was down for good or the model had left the
catalogue. :data:`~chuk_agents_runtime.backend.TOOL_CALL_CAPABLE_MODELS` was
kept "so a fallback chain can walk it", but nothing walked it.

The rule now:

* A transient failure (5xx, 429, a network error, an empty stream; the
  :func:`~chuk_agents_runtime.model_retry.classify` rule) is retried on the
  same model first. After :data:`RETRIES_BEFORE_FALLBACK` failed retries the
  run moves to the next model of the chain.
* "Model gone" (HTTP 404 or 410, or an error code such as
  ``model_not_found``) moves to the next model at once: a retry cannot help.
* Any other failure (400, 401, 402, 403, ...) never falls back: the request
  or the account is wrong, and another model would fail the same way or
  spend money the user did not agree to.

The chain is the run's own model first, then the tool-capable models in
order, each model once. A fallback model runs without the provider pin of
the first model (a pin names a provider of ONE model). When the chain is
used up, the normal retry rule goes on with the last model.

Environment: ``AGENTS_MODEL_FALLBACK=0`` turns the fallback off.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Sequence
from typing import Any

from .model_retry import _chain, _status, classify

logger = logging.getLogger(__name__)

#: Failed retries on the same model before the run moves to the next one.
RETRIES_BEFORE_FALLBACK = 2

#: Statuses that say "this model is not served (any more)".
GONE_STATUSES = frozenset({404, 410})

#: Error codes of the OpenAI error body that say the same.
GONE_CODES = frozenset({"model_not_found", "model_not_available", "model_retired", "invalid_model"})

FALLBACK_ENV = "AGENTS_MODEL_FALLBACK"


def fallback_enabled(environ: dict[str, str] | None = None) -> bool:
    env = os.environ if environ is None else environ
    return (env.get(FALLBACK_ENV, "") or "").strip().lower() not in ("0", "false", "off", "no")


def _error_code(exc: BaseException) -> str | None:
    body = getattr(exc, "body", None)
    if isinstance(body, dict):
        error = body.get("error") if isinstance(body.get("error"), dict) else body
        code = error.get("code") if isinstance(error, dict) else None
        if isinstance(code, str) and code:
            return code
    code = getattr(exc, "code", None)
    return code if isinstance(code, str) and code else None


def model_gone(exc: BaseException) -> bool:
    """True when the failure says the model itself is not served."""
    for item in _chain(exc):
        status = _status(item)
        if status in GONE_STATUSES:
            return True
        code = _error_code(item)
        if code is not None and code.lower() in GONE_CODES:
            return True
    return False


class FallbackChain:
    """The models one run may move through, and when to move.

    ``build(model_id)`` makes the model object for a fallback model (the
    loop's ``model_factory`` shape). ``retries_before`` is the number of
    failed retries on one model before :meth:`next_model` moves on.
    """

    def __init__(
        self,
        primary: str,
        chain: Sequence[str],
        build: Callable[[str], Any],
        *,
        retries_before: int = RETRIES_BEFORE_FALLBACK,
    ) -> None:
        self.primary = primary
        seen = {primary}
        self._queue: list[str] = []
        for model_id in chain:
            if model_id and model_id not in seen:
                seen.add(model_id)
                self._queue.append(model_id)
        self._build = build
        self._retries_before = max(0, int(retries_before))
        self.current = primary
        #: The models the run moved to, in order (for the log and the tests).
        self.used: list[str] = []

    @property
    def exhausted(self) -> bool:
        return not self._queue

    def wants_fallback(self, exc: BaseException, attempts: int) -> bool:
        """Whether a failure after ``attempts`` failed retries on the current
        model moves the run to the next model."""
        if self.exhausted:
            return False
        if model_gone(exc):
            return True
        retryable, _ = classify(exc)
        return retryable and attempts >= self._retries_before

    def next_model(self) -> tuple[str, Any] | None:
        """``(model id, model)`` of the next model, or ``None`` when the chain
        is used up or the model cannot be built."""
        while self._queue:
            model_id = self._queue.pop(0)
            try:
                model = self._build(model_id)
            except Exception:  # noqa: BLE001 — a model that cannot be built is skipped
                logger.warning("fallback model %s could not be built", model_id, exc_info=True)
                continue
            logger.warning("model %s failed; the run falls back to %s", self.current, model_id)
            self.current = model_id
            self.used.append(model_id)
            return model_id, model
        return None


__all__ = [
    "FALLBACK_ENV",
    "GONE_CODES",
    "GONE_STATUSES",
    "RETRIES_BEFORE_FALLBACK",
    "FallbackChain",
    "fallback_enabled",
    "model_gone",
]
