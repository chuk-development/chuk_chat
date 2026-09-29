"""Server → Flutter UI channel.

Two one-way data topics plus a request/response RPC channel:

  ``ui.card``    — structured payloads the app renders as rich cards
                   (weather, search results, news, charts, maps, …).
  ``ui.tool``    — live tool-call status so the app can show a chip/spinner
                   while a tool runs, mirroring ``tool_execution_updated``.
  RPC (outbound) — device capabilities that only exist on the phone
                   (open a URL, GPS position, battery, …).

Everything here is best-effort: a disconnected or older client must never
break a tool call, so all failures are swallowed and logged at debug level.
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Any

from livekit import rtc

logger = logging.getLogger("voice-agent.ui")

CARD_TOPIC = "ui.card"
TOOL_TOPIC = "ui.tool"

#: Bump when the card payload shape changes so old app builds can ignore it.
PROTOCOL_VERSION = 1

_RPC_TIMEOUT = 15.0


class UiBridge:
    """Pushes structured UI payloads to the connected Flutter client."""

    def __init__(self, room: rtc.Room, preferred_identity: str | None = None) -> None:
        self._room = room
        #: The chuk_chat app joins as ``chuk-<user_id>``. RPCs go there first.
        self._preferred_identity = preferred_identity

    # -- helpers -------------------------------------------------------------

    @property
    def client_identity(self) -> str | None:
        """Identity of the app participant.

        The preferred identity (``chuk-<user_id>``) wins when it is in the room.
        Else the first non-agent remote participant, if any.
        """
        remotes = self._room.remote_participants
        if self._preferred_identity and self._preferred_identity in remotes:
            return self._preferred_identity
        for p in remotes.values():
            if p.kind != rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
                return p.identity
        return None

    async def _publish(self, topic: str, payload: dict[str, Any]) -> None:
        try:
            await self._room.local_participant.publish_data(
                json.dumps(payload, ensure_ascii=False),
                topic=topic,
                reliable=True,
            )
        except Exception as e:  # noqa: BLE001 — UI push must never break a tool
            logger.debug("ui publish failed (topic=%s): %s", topic, e)

    # -- cards ---------------------------------------------------------------

    async def card(
        self,
        kind: str,
        *,
        title: str,
        subtitle: str | None = None,
        data: dict[str, Any] | None = None,
        source: str | None = None,
    ) -> str:
        """Render a card in the app. Returns the card id."""
        card_id = str(uuid.uuid4())
        await self._publish(
            CARD_TOPIC,
            {
                "v": PROTOCOL_VERSION,
                "id": card_id,
                "kind": kind,
                "title": title,
                "subtitle": subtitle,
                "source": source,
                "data": data or {},
                "ts": time.time(),
            },
        )
        return card_id

    # -- tool status ---------------------------------------------------------

    async def tool_status(
        self,
        *,
        call_id: str,
        name: str,
        status: str,
        message: str | None = None,
    ) -> None:
        """Mirror a tool lifecycle transition to the app.

        ``status`` is one of ``running`` / ``done`` / ``error`` / ``cancelled``.
        """
        await self._publish(
            TOOL_TOPIC,
            {
                "v": PROTOCOL_VERSION,
                "call_id": call_id,
                "name": name,
                "status": status,
                "message": message,
                "ts": time.time(),
            },
        )

    # -- client-side tools ---------------------------------------------------

    async def call_client(
        self,
        method: str,
        payload: dict[str, Any] | None = None,
        *,
        timeout: float = _RPC_TIMEOUT,
    ) -> Any:
        """Invoke an RPC method the Flutter app registered.

        Raises ``RuntimeError`` when no client is connected so the calling tool
        can return a spoken explanation instead of failing silently.
        """
        identity = self.client_identity
        if not identity:
            raise RuntimeError("No app connected to handle this request.")

        raw = await self._room.local_participant.perform_rpc(
            destination_identity=identity,
            method=method,
            payload=json.dumps(payload or {}, ensure_ascii=False),
            response_timeout=timeout,
        )
        try:
            return json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            return raw
