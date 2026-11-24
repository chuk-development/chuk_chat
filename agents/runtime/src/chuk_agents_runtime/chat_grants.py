"""Allow for this chat" grants (CHAT-180, Grok Bot item 8).

An approval card can offer ``always_this_chat``
(:data:`~chuk_agents_runtime.action_policy.SCOPE_CHAT`). The user's yes then
covers the action class in this one chat (one ``session_key``); the agent's
other chats still ask. The grant is kept in the state store as the session
feature ``chat_approvals`` (``{"classes": [...]}``), so it outlives a host
restart and goes away with the chat.

The executor reads the grant into the run's policy
(:meth:`~chuk_agents_runtime.action_policy.ActionPolicy.with_chat`): it turns
``ask`` into ``allow`` for those classes, never ``deny`` into anything. An
always-ask class (``payment``) is never granted.
"""

from __future__ import annotations

from typing import Any

from .action_policy import ACTION_CLASSES, ALWAYS_ASK_CLASSES

FEATURE_KIND = "chat_approvals"


def _classes(doc: Any) -> list[str]:
    raw = doc.get("classes") if isinstance(doc, dict) else None
    if not isinstance(raw, list):
        return []
    return [c for c in raw if isinstance(c, str) and c in ACTION_CLASSES and c not in ALWAYS_ASK_CLASSES]


def chat_classes(store: Any, session_key: str) -> frozenset[str]:
    """The classes allowed for the chat ``session_key``. Empty on any error."""
    if store is None or not session_key:
        return frozenset()
    try:
        return frozenset(_classes(store.load_feature(session_key, FEATURE_KIND)))
    except Exception:  # noqa: BLE001 — an unreadable grant is no grant
        return frozenset()


def grant_chat(store: Any, session_key: str, action_class: str) -> bool:
    """Allow ``action_class`` for the chat ``session_key``. ``True`` when the
    grant changed something."""
    if store is None or not session_key:
        return False
    if action_class not in ACTION_CLASSES or action_class in ALWAYS_ASK_CLASSES:
        return False

    def update(current: Any) -> tuple[dict, bool]:
        listed = _classes(current)
        if action_class in listed:
            return {"classes": listed}, False
        return {"classes": [*listed, action_class]}, True

    return bool(store.update_feature(session_key, FEATURE_KIND, update))


def clear_chat(store: Any, session_key: str) -> None:
    """Drop every grant of the chat ``session_key``."""
    if store is not None and session_key:
        store.save_feature(session_key, FEATURE_KIND, None)


__all__ = ["FEATURE_KIND", "chat_classes", "clear_chat", "grant_chat"]
