"""Inbound webhooks on the host (research H44; docs/WIRE_CONTRACT.md,
"Inbound webhooks").

The flow: the app makes a server webhook (``POST /v1/agents/webhooks``) and
gets its secret URL ``https://api.chuk.chat/v1/hooks/wh_...`` once. The app
then sends ``automation_create`` with ``kind: "webhook"`` and the server's
row id as ``spec.webhook_id``. Someone POSTs to the URL. The API server
answers ``202`` and pushes ONE unsealed control frame ``webhook_event`` on the
executor socket (api_server ``routers/cowork/cowork_webhooks.py``). The
host's ``webhook`` row with that id checks the sender's signature (if the row
has a ``signing_secret``) and the filter, and queues a fire.

The host never sees the secret URL token. ``webhook_id`` in the frame is the
server's row uuid; ``webhook_id_hash`` (sha256 of the secret) is not used.

This module holds what does not need the automation store:

- :func:`decode_event` — the relay frame -> a checked :class:`WebhookEvent`.
- :func:`verify_signature` — GitHub, Stripe, Svix / Standard Webhooks,
  Slack, GitLab, and a generic ``x-signature-256``.
- :func:`event_payload` — the event as trigger payload (untrusted data).
- :class:`SeenEvents` — a small LRU of event ids against a double delivery.
- :func:`sender_message_ids` and :class:`ReplayGuard` — the sender's own
  message id (``svix-id``, ``webhook-id``, ``x-github-delivery``, the Stripe
  event id, ...) is remembered for a TTL window, so a captured signed call
  that is POSTed again (the server gives it a new ``event_id``) is refused.

Nothing here logs a body or a header value.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from chuk_agents_runtime.automations import WEBHOOK_ID_RE, filter_header_allowed, missing

#: The relay control frame (server -> host, top level, not sealed).
TYPE_WEBHOOK_EVENT = "webhook_event"
#: The frame versions this host reads. Another ``v`` is ignored.
FRAME_VERSIONS = (1,)
#: The server refuses a body over this with 413; the host drops a frame over
#: it as ``too_large``.
MAX_BODY_BYTES = 256 * 1024
#: The server forwards at most 32 headers of at most 1024 characters.
MAX_HEADERS = 32
MAX_HEADER_CHARS = 1024
#: A signature timestamp (Stripe, Svix / Standard Webhooks, Slack) older or
#: newer than this, against ``received_at``, is refused.
SIGNATURE_TOLERANCE_SECONDS = 300
#: One event's body in the model's payload. The merged payload is cut again
#: to the automation payload cap (16 KB).
EVENT_BODY_CHARS = 12 * 1024
SEEN_EVENTS = 2048
#: How long a sender's message id is remembered against a replay. Schemes with
#: a signed timestamp refuse an old call anyway after
#: ``SIGNATURE_TOLERANCE_SECONDS``; GitHub / GitLab / generic have no signed
#: timestamp, so the window is long.
REPLAY_TTL_SECONDS = 24 * 3600
REPLAY_IDS = 4096
_EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

#: What :meth:`AutomationManager.offer_webhook` did with an event.
OUTCOME_QUEUED = "queued"
OUTCOME_FILTERED = "filtered"
OUTCOME_UNKNOWN = "unknown_webhook"
OUTCOME_DUPLICATE = "duplicate"
#: A signed call whose sender message id was already accepted (a replay).
OUTCOME_REPLAY = "replay"
OUTCOME_BAD_SIGNATURE = "bad_signature"
OUTCOME_PAUSED = "paused"
OUTCOME_TOO_LARGE = "too_large"
OUTCOME_MALFORMED = "malformed"
OUTCOME_UNKNOWN_VERSION = "unknown_version"
#: ``agent_id`` names an agent this host does not run.
OUTCOME_OTHER_AGENT = "other_agent"
#: ``device_id`` names another host of the user.
OUTCOME_OTHER_DEVICE = "other_device"


def is_secret_header(name: str) -> bool:
    """A header the model never sees: signatures and tokens."""
    return "signature" in name or "token" in name or "secret" in name


@dataclass
class WebhookEvent:
    """One forwarded call, checked."""

    webhook_id: str
    event_id: str
    received_at: float
    method: str
    headers: dict[str, str]
    raw: bytes
    #: The parsed JSON body, or the missing marker for a body that is not JSON.
    document: Any
    agent_id: str | None = None
    device_id: str | None = None


class WebhookFrameError(ValueError):
    """The frame is not a usable ``webhook_event``. ``reason`` is the ledger word."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _parse_time(value: Any) -> float:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if isinstance(value, str) and value.strip():
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            return datetime.fromisoformat(text).timestamp()
        except ValueError:
            pass
    return time.time()


def decode_event(frame: dict[str, Any]) -> WebhookEvent:
    """Read a ``webhook_event`` frame. Raises :class:`WebhookFrameError` with
    ``unknown_version``, ``malformed`` or ``too_large``."""
    if frame.get("v") not in FRAME_VERSIONS:
        raise WebhookFrameError(OUTCOME_UNKNOWN_VERSION)
    webhook_id = frame.get("webhook_id")
    event_id = frame.get("event_id")
    if not isinstance(webhook_id, str) or not WEBHOOK_ID_RE.match(webhook_id.lower()):
        raise WebhookFrameError(OUTCOME_MALFORMED)
    if not isinstance(event_id, str) or not _EVENT_ID_RE.match(event_id):
        raise WebhookFrameError(OUTCOME_MALFORMED)
    body = frame.get("body")
    if body is None:
        body = ""
    if not isinstance(body, str):
        raise WebhookFrameError(OUTCOME_MALFORMED)
    encoding = frame.get("body_encoding") or "utf8"
    if encoding == "utf8":
        # A cheap bound before the encode: a UTF-8 character is 1..4 bytes.
        if len(body) > MAX_BODY_BYTES:
            raise WebhookFrameError(OUTCOME_TOO_LARGE)
        raw = body.encode("utf-8", "surrogatepass")
    elif encoding == "base64":
        if len(body) > (MAX_BODY_BYTES * 4) // 3 + 8:
            raise WebhookFrameError(OUTCOME_TOO_LARGE)
        try:
            raw = base64.b64decode(body, validate=True)
        except (binascii.Error, ValueError):
            raise WebhookFrameError(OUTCOME_MALFORMED) from None
    else:
        raise WebhookFrameError(OUTCOME_MALFORMED)
    if len(raw) > MAX_BODY_BYTES:
        raise WebhookFrameError(OUTCOME_TOO_LARGE)
    headers: dict[str, str] = {}
    given = frame.get("headers")
    if isinstance(given, dict):
        for key, value in list(given.items())[:MAX_HEADERS]:
            name = str(key).strip().lower()
            if name and isinstance(value, str):
                headers[name] = value[:MAX_HEADER_CHARS]
    document: Any = missing()
    if raw:
        try:
            document = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):
            document = missing()
    method = frame.get("method")
    agent_id = frame.get("agent_id")
    device_id = frame.get("device_id")
    return WebhookEvent(
        webhook_id=webhook_id.lower(),
        event_id=event_id,
        received_at=_parse_time(frame.get("received_at")),
        method=method[:10] if isinstance(method, str) and method else "POST",
        headers=headers,
        raw=raw,
        document=document,
        agent_id=agent_id if isinstance(agent_id, str) and agent_id else None,
        device_id=device_id if isinstance(device_id, str) and device_id else None,
    )


def _hmac(key: bytes, message: bytes) -> bytes:
    return hmac.new(key, message, hashlib.sha256).digest()


def _fresh(stamp: str, reference: float) -> bool:
    # ``isdigit`` alone accepts "²" or Arabic-Indic digits; only ASCII counts.
    if not (stamp.isascii() and stamp.isdigit()) or len(stamp) > 12:
        return False
    return abs(reference - int(stamp)) <= SIGNATURE_TOLERANCE_SECONDS


def _bytes(text: str) -> bytes:
    """A header value as bytes for a constant-time compare.
    ``hmac.compare_digest`` raises on a non-ASCII ``str``; bytes never do."""
    return text.encode("utf-8", "surrogatepass")


def _hex_equal(given: str, digest: bytes) -> bool:
    return hmac.compare_digest(_bytes(given.strip().lower()), digest.hex().encode("ascii"))


def _svix_key(secret: str) -> bytes:
    """Svix / Standard Webhooks: ``whsec_<base64>``; the key is the decoded
    bytes. A secret without the prefix that is not base64 is used as text."""
    text = secret[6:] if secret.startswith("whsec_") else secret
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return secret.encode("utf-8")


def verify_signature(secret: str, event: WebhookEvent, *, now: float | None = None) -> bool:
    """Check the sender's signature with the row's ``signing_secret``. The
    first scheme whose header is present decides:

    - GitHub / Gitea / generic: ``x-hub-signature-256`` or
      ``x-signature-256``: ``sha256=<hex>`` or ``<hex>``, HMAC-SHA256 of the
      raw body.
    - Stripe: ``stripe-signature: t=<unix>,v1=<hex>[,v1=...]`` over
      ``"<t>.<body>"``.
    - Svix (``svix-id`` / ``svix-timestamp`` / ``svix-signature``) and
      Standard Webhooks (``webhook-id`` / ``webhook-timestamp`` /
      ``webhook-signature``): ``v1,<base64>`` (space separated list) over
      ``"<id>.<timestamp>.<body>"``, key = base64 of a ``whsec_`` secret.
    - Slack: ``x-slack-signature: v0=<hex>`` over ``"v0:<ts>:<body>"`` with
      ``x-slack-request-timestamp``.
    - GitLab: ``x-gitlab-token`` equals the secret.

    Timestamps must be within 5 minutes of ``received_at``. No signature
    header = not verified. Every compare is constant-time and on bytes, so a
    non-ASCII header is a plain mismatch, not an exception."""
    reference = event.received_at if now is None else now
    headers = event.headers
    key = secret.encode("utf-8")
    for name in ("x-hub-signature-256", "x-signature-256"):
        given = headers.get(name)
        if given:
            value = given.strip()
            if value.lower().startswith("sha256="):
                value = value[7:]
            return _hex_equal(value, _hmac(key, event.raw))
    stripe = headers.get("stripe-signature")
    if stripe:
        stamp, candidates = "", []
        for part in stripe.split(","):
            name, _, value = part.strip().partition("=")
            if name == "t":
                stamp = value
            elif name == "v1":
                candidates.append(value)
        if not candidates or not _fresh(stamp, reference):
            return False
        digest = _hmac(key, stamp.encode() + b"." + event.raw)
        return any(_hex_equal(c, digest) for c in candidates)
    for prefix in ("svix-", "webhook-"):
        signature = headers.get(prefix + "signature")
        if not signature:
            continue
        msg_id = headers.get(prefix + "id") or ""
        stamp = headers.get(prefix + "timestamp") or ""
        if not msg_id or not _fresh(stamp, reference):
            return False
        expected = base64.b64encode(
            _hmac(_svix_key(secret), f"{msg_id}.{stamp}.".encode() + event.raw)
        ).decode()
        ok = False
        for item in signature.split():
            version, _, value = item.partition(",")
            if version == "v1" and hmac.compare_digest(_bytes(value), expected.encode("ascii")):
                ok = True
        return ok
    slack = headers.get("x-slack-signature")
    if slack:
        stamp = headers.get("x-slack-request-timestamp") or ""
        if not slack.startswith("v0=") or not _fresh(stamp, reference):
            return False
        return _hex_equal(slack[3:], _hmac(key, f"v0:{stamp}:".encode() + event.raw))
    gitlab = headers.get("x-gitlab-token")
    if gitlab is not None:
        return hmac.compare_digest(_bytes(gitlab), key)
    return False


def payload_header_allowed(name: str) -> bool:
    """Whether header ``name`` reaches the model. An allowlist (the headers a
    filter may read, :func:`chuk_agents_runtime.automations.filter_header_allowed`),
    never a denylist: an unknown header (``authorization``, ``cookie``,
    ``x-api-key``, a vendor's own auth header) stays on the host."""
    return filter_header_allowed(name) and not is_secret_header(name)


def event_payload(event: WebhookEvent) -> dict[str, Any]:
    """The event as trigger payload. Untrusted: it goes after the payload
    marker only. Only allowlisted headers go in (:func:`payload_header_allowed`);
    the body is the parsed JSON when it is small enough, else the first
    characters as text."""
    out: dict[str, Any] = {
        "event_id": event.event_id,
        "received_at": event.received_at,
        "method": event.method,
        "headers": {k: v for k, v in event.headers.items() if payload_header_allowed(k)},
    }
    if event.document is not missing():
        encoded = json.dumps(event.document, ensure_ascii=False)
        if len(encoded) <= EVENT_BODY_CHARS:
            out["body"] = event.document
        else:
            out["body_text"] = encoded[:EVENT_BODY_CHARS]
            out["body_truncated"] = True
        return out
    try:
        text = event.raw.decode("utf-8")
    except UnicodeDecodeError:
        out["body_base64"] = base64.b64encode(event.raw[: EVENT_BODY_CHARS * 3 // 4]).decode("ascii")
        out["body_bytes"] = len(event.raw)
        if len(event.raw) > EVENT_BODY_CHARS * 3 // 4:
            out["body_truncated"] = True
        return out
    out["body_text"] = text[:EVENT_BODY_CHARS]
    if len(text) > EVENT_BODY_CHARS:
        out["body_truncated"] = True
    return out


class SeenEvents:
    """The last ``size`` event ids. Thread-safe."""

    def __init__(self, size: int = SEEN_EVENTS) -> None:
        self._size = size
        self._ids: OrderedDict[str, None] = OrderedDict()
        self._lock = threading.Lock()

    def __contains__(self, event_id: object) -> bool:
        with self._lock:
            return event_id in self._ids

    def check_and_add(self, event_id: str) -> bool:
        """True when ``event_id`` was seen before."""
        with self._lock:
            if event_id in self._ids:
                self._ids.move_to_end(event_id)
                return True
            self._ids[event_id] = None
            while len(self._ids) > self._size:
                self._ids.popitem(last=False)
            return False


#: Delivery-id headers of senders that sign only the body. The header itself
#: is NOT signed, so it is a second key only; the body MAC is the first.
_DELIVERY_HEADERS = (
    "x-github-delivery",
    "x-gitea-delivery",
    "x-gogs-delivery",
    "x-gitlab-event-uuid",
)
_SENDER_ID_MAX = 200


def _bounded(key: str) -> str:
    if len(key) > _SENDER_ID_MAX:
        # Bounded memory per entry; a digest keeps it unique.
        return "sha256:" + hashlib.sha256(_bytes(key)).hexdigest()
    return key


def sender_message_ids(event: WebhookEvent) -> list[str]:
    """The keys that name this delivery for the replay check. Read only after
    :func:`verify_signature` passed: then the scheme that decided is the one
    whose headers are present. A call is a replay when ANY key was seen.

    - Svix / Standard Webhooks: ``svix-id`` / ``webhook-id`` (signed).
    - Stripe: the event id ``id`` of the signed JSON body.
    - Slack: timestamp + signature (the MAC covers the timestamp).
    - GitHub / Gitea / generic ``x-signature-256``: the body MAC itself (an
      attacker cannot make a new one) and the delivery header.
    - GitLab: the delivery header (the token signs nothing)."""
    headers = event.headers
    keys: list[str] = []
    for prefix in ("svix-", "webhook-"):
        if headers.get(prefix + "signature") and headers.get(prefix + "id"):
            keys.append(prefix + headers[prefix + "id"])
            break
    if not keys and headers.get("stripe-signature"):
        doc = event.document
        if isinstance(doc, dict) and isinstance(doc.get("id"), str) and doc["id"]:
            keys.append("stripe:" + doc["id"])
    if not keys and headers.get("x-slack-signature"):
        keys.append("slack:" + (headers.get("x-slack-request-timestamp") or "") + ":" + headers["x-slack-signature"])
    if not keys:
        for name in ("x-hub-signature-256", "x-signature-256"):
            value = (headers.get(name) or "").strip().lower()
            if value:
                keys.append("mac:" + value.removeprefix("sha256="))
                break
        for name in _DELIVERY_HEADERS:
            value = (headers.get(name) or "").strip()
            if value:
                keys.append(name + ":" + value)
                break
    return [_bounded(k) for k in keys]


class ReplayGuard:
    """Sender message ids per webhook row, each kept ``ttl`` seconds.
    Thread-safe; bounded to ``size`` entries (oldest out first)."""

    def __init__(self, ttl: float = REPLAY_TTL_SECONDS, size: int = REPLAY_IDS) -> None:
        self._ttl = ttl
        self._size = size
        self._ids: OrderedDict[tuple[str, str], float] = OrderedDict()
        self._lock = threading.Lock()

    def check_and_add(self, webhook_id: str, message_ids: list[str], now: float) -> bool:
        """True when any of ``message_ids`` was accepted for ``webhook_id``
        within the TTL (a replay); nothing is recorded then. Otherwise all
        are recorded and False is returned."""
        keys = [(webhook_id, m) for m in message_ids]
        with self._lock:
            while self._ids:
                oldest_key, oldest_at = next(iter(self._ids.items()))
                if now - oldest_at <= self._ttl:
                    break
                del self._ids[oldest_key]
            for key in keys:
                seen_at = self._ids.get(key)
                if seen_at is not None and now - seen_at <= self._ttl:
                    return True
            for key in keys:
                self._ids[key] = now
                self._ids.move_to_end(key)
            while len(self._ids) > self._size:
                self._ids.popitem(last=False)
            return False


__all__ = [
    "FRAME_VERSIONS",
    "MAX_BODY_BYTES",
    "OUTCOME_BAD_SIGNATURE",
    "OUTCOME_DUPLICATE",
    "OUTCOME_FILTERED",
    "OUTCOME_MALFORMED",
    "OUTCOME_OTHER_AGENT",
    "OUTCOME_OTHER_DEVICE",
    "OUTCOME_PAUSED",
    "OUTCOME_QUEUED",
    "OUTCOME_REPLAY",
    "OUTCOME_TOO_LARGE",
    "OUTCOME_UNKNOWN",
    "OUTCOME_UNKNOWN_VERSION",
    "REPLAY_TTL_SECONDS",
    "ReplayGuard",
    "SeenEvents",
    "TYPE_WEBHOOK_EVENT",
    "WebhookEvent",
    "WebhookFrameError",
    "decode_event",
    "event_payload",
    "is_secret_header",
    "payload_header_allowed",
    "sender_message_ids",
    "verify_signature",
]
