"""A message to the user while the agent keeps working (``send_message``).

CHAT-79. The owner asked the Mail agent a question and heard nothing for
more than five minutes; he could not tell a busy agent from a broken one.
Like Grok Bot, the agent now says first what it is about to do ("I am going
through your mail, about a minute"), works on, and the result comes as its
own message at the end.

The message goes out at once as a ``message`` frame (docs/WIRE_CONTRACT.md,
"send_message") and is stored as an event row, so a replay shows it as its
own bubble at its place in the thread. The final answer stays the run's
normal answer: this tool never ends the run.

Whether the agent sends one is the model's decision, steered by the prompt
section below. Nothing here reads the model's text to guess it.
"""

from __future__ import annotations

from typing import Protocol

from .registry import ToolRegistry

#: Longer text belongs in the final answer.
MAX_MESSAGE_CHARS = 1000
#: A run that sends more than this is chatting instead of working.
MAX_MESSAGES_PER_RUN = 6

SEND_MESSAGE_SCHEMA = {
    "type": "object",
    "description": (
        "Send the user a short chat message NOW and keep working. It shows "
        "at once as its own message in the chat. Use it (1) at the start of "
        "work that needs several steps or more than about 30 seconds: one "
        "short sentence that says what you are doing, e.g. 'I am going "
        "through your inbox now, this takes about a minute.'; (2) at once "
        "when something blocks you or needs the user, e.g. a connector that "
        "must be signed in again. Never use it for the final answer: that is "
        "your normal reply when the work is done. Write in the user's "
        "language."
    ),
    "properties": {
        "text": {
            "type": "string",
            "description": f"The message, at most {MAX_MESSAGE_CHARS} characters.",
        },
    },
    "required": ["text"],
}

PROMPT_SECTION = "\n".join(
    [
        "# Keep the user informed",
        "",
        "- When a request needs several tool calls or will take more than "
        "about 30 seconds, call `send_message` FIRST with one short sentence "
        "that says what you are about to do. Then do the work. Your final "
        "answer comes as your normal reply at the end.",
        "- When something fails or blocks you (a connector needs a new "
        "sign-in, a service does not answer), tell the user at once with "
        "`send_message`, then go on with what you can still do.",
        "- A quick question you can answer right away needs no "
        "`send_message`: just answer.",
    ]
)


class AgentMessageBackend(Protocol):
    """What the executor binds to one run: deliver ``text`` to the thread."""

    def send(self, text: str) -> dict:
        """``{"ok": True}`` when the message went out, else ``{"ok": False,
        "error": ...}``."""


def make_send_message_handler(backend: AgentMessageBackend):
    sent = {"count": 0}

    def send_message(text: str) -> dict:
        body = " ".join(str(text or "").split()) if "\n" not in str(text or "") else str(text).strip()
        if not body:
            return {"ok": False, "error": "text is empty"}
        if len(body) > MAX_MESSAGE_CHARS:
            return {
                "ok": False,
                "error": f"text is longer than {MAX_MESSAGE_CHARS} characters; put details in the final answer",
            }
        if sent["count"] >= MAX_MESSAGES_PER_RUN:
            return {
                "ok": False,
                "error": "enough messages for this task; finish the work and answer",
            }
        result = backend.send(body)
        if not isinstance(result, dict) or not result.get("ok"):
            message = result.get("error") if isinstance(result, dict) else None
            return {"ok": False, "error": str(message or "the message could not be sent")}
        sent["count"] += 1
        return {"ok": True, "delivered": True, "note": "The user sees it now. Keep working."}

    return send_message


def register_message_tools(
    registry: ToolRegistry, backend: AgentMessageBackend | None
) -> list[str]:
    """Register ``send_message`` when the run has somewhere to send it."""
    if backend is None or registry.has("send_message"):
        return []
    registry.register(
        "send_message",
        SEND_MESSAGE_SCHEMA,
        make_send_message_handler(backend),
    )
    return ["send_message"]
