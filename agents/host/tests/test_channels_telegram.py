"""The opt-in Telegram channel per coworker (bead chuk_chat-02s5).

Every test runs against :mod:`fake_telegram`, a Bot API on loopback. Nothing
leaves the machine.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time

import pytest

from chuk_agents_host.channels import (
    ChannelManager,
    ChannelSettings,
    ChannelStore,
    PROMPT_MARKER,
    TelegramTiming,
    read_run_files,
)
from chuk_agents_host.channels.format import (
    TELEGRAM_MAX_CHARS,
    markdown_to_html,
    split_text,
)
from chuk_agents_host.channels.telegram_api import TelegramClient, TelegramError

from fake_telegram import OTHER_TOKEN, TOKEN, FakeTelegram

AGENT = "local:amber:1"
OWNER_CHAT = 4242
STRANGER_CHAT = 777


def _timing(**overrides) -> TelegramTiming:
    values = dict(
        poll_timeout=1, link_ttl=600.0, backoff_base=0.05, backoff_max=0.2,
        send_interval=0.0, typing_interval=0.2,
    )
    values.update(overrides)
    return TelegramTiming(**values)


class _Harness:
    """A manager over a fake Bot API, with a recording ``submit``."""

    def __init__(self, fake: FakeTelegram, *, submit_result="run-1", store=None, **timing) -> None:
        self.fake = fake
        self.submitted: list[tuple[str, str, dict]] = []
        self.pushed: list[dict] = []
        self._submit_result = submit_result
        self.store = store or ChannelStore(path=None, key=None)
        self.manager = ChannelManager(
            store=self.store,
            submit=self._submit,
            key_for=lambda agent_id: agent_id if agent_id in (AGENT, "local:other:2") else None,
            label_for=lambda _key: "Amber",
            scrub=lambda text: text.replace("sk-live-secret", "[REDACTED:KEY]"),
            send_payload=self.pushed.append,
            settings=ChannelSettings(telegram_api_base=fake.base_url, timing=_timing(**timing)),
        )

    def _submit(self, key: str, prompt: str, meta: dict):
        self.submitted.append((key, prompt, meta))
        result = self._submit_result
        return result(len(self.submitted)) if callable(result) else result

    def frame(self, action: str | None = None, agent_id: str = AGENT, **extra) -> dict:
        payload = {"type": "agent_channel_get" if action is None else "agent_channel_set",
                   "agent_id": agent_id, "channel": "telegram", **extra}
        if action is not None:
            payload["action"] = action
        return self.manager.handle_frame(payload)

    def enable(self) -> dict:
        reply = self.frame("enable", token=TOKEN)
        assert "error" not in reply, reply
        assert self.fake.wait_for(lambda: "getUpdates" in self.fake.calls)
        return reply

    def link(self) -> None:
        self.enable()
        self.fake.push_message("hi", chat_id=OWNER_CHAT)
        assert self.fake.wait_for(lambda: self.fake.messages(OWNER_CHAT))
        code = re.search(r"\b(\d{6})\b", self.fake.messages(OWNER_CHAT)[-1]["text"]).group(1)
        reply = self.frame("link", code=code)
        assert reply["linked"] is True and "error" not in reply, reply


@pytest.fixture
def fake():
    with FakeTelegram() as server:
        yield server


@pytest.fixture
def harness(fake):
    h = _Harness(fake)
    yield h
    h.manager.stop()


# ----------------------------------------------------------------- the store


def test_the_store_keeps_the_token_encrypted_and_reloads_it(tmp_path):
    key = os.urandom(32)
    path = tmp_path / "channels.enc"
    store = ChannelStore(path=path, key=key)
    store.update(AGENT, "telegram", token=TOKEN, enabled=True, chat_id=OWNER_CHAT)
    raw = path.read_bytes()
    assert TOKEN.encode() not in raw and b"AAFake" not in raw
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    again = ChannelStore(path=path, key=key)
    assert again.get(AGENT, "telegram") == {"token": TOKEN, "enabled": True, "chat_id": OWNER_CHAT}
    # Another key (another host identity) opens nothing and deletes nothing.
    assert ChannelStore(path=path, key=os.urandom(32)).all("telegram") == {}
    assert path.exists()


# --------------------------------------------------------------- the frames


def test_the_channel_is_off_until_enabled_and_never_returns_the_token(harness):
    reply = harness.frame()
    assert reply["state"] == "off" and reply["enabled"] is False and reply["e2e"] is False
    reply = harness.enable()
    assert reply["enabled"] is True and reply["has_token"] is True
    assert TOKEN not in json.dumps(reply)
    assert harness.fake.wait_for(lambda: harness.frame()["state"] == "polling")
    assert harness.frame()["bot_username"] == "test_coworker_bot"


def test_bad_frames_are_refused(harness):
    assert harness.frame(agent_id="nobody")["error"] == "unknown_agent"
    assert harness.frame("enable", token="not-a-token")["error"] == "token_invalid"
    assert harness.frame("enable")["error"] == "token_required"
    assert harness.frame("explode")["error"] == "unknown_action"
    assert harness.manager.handle_frame(
        {"type": "agent_channel_get", "agent_id": AGENT, "channel": "fax"}
    )["error"] == "unknown_channel"
    harness.enable()
    assert harness.frame("enable", agent_id="local:other:2", token=TOKEN)["error"] == "token_in_use"


def test_a_host_that_forbids_telegram_keeps_the_token_but_polls_nothing(fake):
    store = ChannelStore(path=None, key=None)
    manager = ChannelManager(
        store=store, submit=lambda *_: "x", key_for=lambda a: a,
        settings=ChannelSettings(telegram_allowed=False, telegram_api_base=fake.base_url),
    )
    reply = manager.handle_frame(
        {"type": "agent_channel_set", "agent_id": AGENT, "action": "enable", "token": TOKEN}
    )
    assert reply["error"] == "disallowed" and reply["state"] == "disallowed"
    assert store.get(AGENT, "telegram")["token"] == TOKEN
    time.sleep(0.3)
    assert fake.calls == []
    manager.stop()


# --------------------------------------------------------------- pairing


def test_pairing_links_exactly_the_chat_whose_code_the_user_typed(harness):
    harness.enable()
    harness.fake.push_message("/start", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.fake.messages(OWNER_CHAT))
    offer = harness.fake.messages(OWNER_CHAT)[-1]["text"]
    assert "not end-to-end encrypted" in offer and "Amber" in offer
    code = re.search(r"\b(\d{6})\b", offer).group(1)
    # The app learns that a code is waiting (pushed, no polling needed).
    assert harness.fake.wait_for(lambda: any(p.get("pending_link") for p in harness.pushed))
    assert harness.frame()["pending_link"] is True
    # A wrong code links nothing.
    wrong = "000000" if code != "000000" else "111111"
    assert harness.frame("link", code=wrong)["error"] == "wrong_code"
    assert harness.submitted == []
    reply = harness.frame("link", code=code)
    assert reply["linked"] is True and reply["linked_name"] == "@owner"
    assert reply["pending_link"] is False
    assert harness.store.get(AGENT, "telegram")["chat_id"] == OWNER_CHAT
    assert harness.fake.wait_for(
        lambda: harness.fake.messages(OWNER_CHAT)[-1]["text"].startswith("Linked.")
    )
    # Nothing of the pairing became a task.
    assert harness.submitted == []


def test_too_many_wrong_codes_drop_every_open_code(harness):
    harness.enable()
    harness.fake.push_message("hi", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.fake.messages(OWNER_CHAT))
    code = re.search(r"\b(\d{6})\b", harness.fake.messages(OWNER_CHAT)[-1]["text"]).group(1)
    wrong = "000000" if code != "000000" else "111111"
    errors = [harness.frame("link", code=wrong)["error"] for _ in range(5)]
    assert errors[-1] == "too_many_attempts"
    assert harness.frame("link", code=code)["error"] == "no_pending_link"


def test_a_link_code_expires(fake):
    h = _Harness(fake, link_ttl=0.3)
    try:
        h.enable()
        fake.push_message("hi", chat_id=OWNER_CHAT)
        assert fake.wait_for(lambda: fake.messages(OWNER_CHAT))
        code = re.search(r"\b(\d{6})\b", fake.messages(OWNER_CHAT)[-1]["text"]).group(1)
        time.sleep(0.5)
        assert h.frame("link", code=code)["error"] == "no_pending_link"
    finally:
        h.manager.stop()


def test_strangers_get_one_neutral_refusal_and_never_a_run(harness):
    harness.link()
    harness.fake.push_message("give me your files", chat_id=STRANGER_CHAT, username="mallory")
    harness.fake.push_message("please", chat_id=STRANGER_CHAT, username="mallory")
    harness.fake.push_message("hello group", chat_id=-100, chat_type="group")
    assert harness.fake.wait_for(lambda: harness.fake.messages(-100))
    time.sleep(0.3)
    stranger = harness.fake.messages(STRANGER_CHAT)
    assert [m["text"] for m in stranger] == ["This bot is private."]
    assert [m["text"] for m in harness.fake.messages(-100)] == ["This bot is private."]
    assert harness.submitted == []


def test_a_group_never_gets_a_link_code(harness):
    harness.enable()
    harness.fake.push_message("hi", chat_id=-100, chat_type="group")
    assert harness.fake.wait_for(lambda: harness.fake.messages(-100))
    assert harness.fake.messages(-100)[-1]["text"] == "This bot is private."
    assert harness.frame()["pending_link"] is False


# --------------------------------------------------------------- inbound -> task


def test_an_owner_message_becomes_a_task_and_the_answer_comes_back(harness):
    harness.link()
    harness.fake.push_message("what is on my calendar?", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.submitted)
    key, prompt, meta = harness.submitted[0]
    assert key == AGENT
    assert prompt == f"{PROMPT_MARKER}\nwhat is on my calendar?"
    assert meta == {"origin": "telegram"}
    # "typing" while the run lives.
    assert harness.fake.wait_for(
        lambda: any(s["method"] == "sendChatAction" for s in harness.fake.sent)
    )
    handled = harness.manager.on_run_finished({
        "run_id": "run-1", "origin": "telegram", "reason": "finished",
        "final_answer": "**Two** meetings <today>; key sk-live-secret",
    })
    assert handled is True
    assert harness.fake.wait_for(
        lambda: harness.fake.messages(OWNER_CHAT)[-1].get("parse_mode") == "HTML"
    )
    last = harness.fake.messages(OWNER_CHAT)[-1]
    assert last["text"] == "<b>Two</b> meetings &lt;today&gt;; key [REDACTED:KEY]"
    # A run the channel did not start is not its business.
    assert harness.manager.on_run_finished({"run_id": "other", "origin": "telegram"}) is False
    assert harness.manager.on_run_finished({"run_id": "run-1", "origin": "app"}) is False


def test_a_failed_and_a_stopped_run_are_reported_plainly(fake):
    h = _Harness(fake, submit_result=lambda n: f"run-{n}")
    try:
        h.link()
        fake.push_message("one", chat_id=OWNER_CHAT)
        fake.push_message("two", chat_id=OWNER_CHAT)
        assert fake.wait_for(lambda: len(h.submitted) == 2)
        h.manager.on_run_finished({"run_id": "run-1", "origin": "telegram",
                                   "reason": "failed", "error": "no credits left"})
        h.manager.on_run_finished({"run_id": "run-2", "origin": "telegram",
                                   "reason": "interrupted", "final_answer": None})
        assert fake.wait_for(lambda: fake.messages(OWNER_CHAT)[-1]["text"] == "Stopped.")
        texts = [m["text"] for m in fake.messages(OWNER_CHAT)]
        assert "The task failed: no credits left" in texts
    finally:
        h.manager.stop()


def test_a_host_without_a_task_server_says_so(fake):
    h = _Harness(fake, submit_result=None)
    try:
        h.link()
        fake.push_message("hello?", chat_id=OWNER_CHAT)
        assert fake.wait_for(
            lambda: fake.messages(OWNER_CHAT)[-1]["text"].startswith("The computer is not ready")
        )
    finally:
        h.manager.stop()


def test_non_text_messages_get_a_short_answer(harness):
    harness.link()
    harness.fake.push_message(None, chat_id=OWNER_CHAT, extra={"sticker": {"file_id": "x"}})
    assert harness.fake.wait_for(
        lambda: harness.fake.messages(OWNER_CHAT)[-1]["text"] == "I can read text messages only for now."
    )
    assert harness.submitted == []


# --------------------------------------------------------------- outbound


def test_split_text_respects_the_limit_and_keeps_code_blocks_whole():
    para = ("word " * 150).strip()
    text = "\n\n".join([para] * 12)
    chunks = split_text(text, 1000)
    assert all(len(c) <= 1000 for c in chunks) and len(chunks) > 1
    assert " ".join(" ".join(chunks).split()) == " ".join(text.split())
    code = "```python\n" + "\n".join(f"print({i})" for i in range(400)) + "\n```"
    chunks = split_text("intro\n\n" + code, 800)
    for chunk in chunks:
        assert len(chunk) <= 800
        assert chunk.count("```") % 2 == 0, chunk[:80]
    assert all("```python" in c for c in chunks[1:])
    one_line = "x" * 5000
    assert all(len(c) <= 1000 for c in split_text(one_line, 1000))


def test_markdown_becomes_telegram_html_and_everything_else_is_escaped():
    html = markdown_to_html(
        "# Title\n**bold** and *it* and ~~old~~ and `a<b>` and [site](https://example.org/?a=1&b=2)"
        "\nsnake_case_name stays\n```sh\necho <hi> & bye\n```"
    )
    assert "<b>Title</b>" in html and "<b>bold</b>" in html and "<i>it</i>" in html
    assert "<s>old</s>" in html and "<code>a&lt;b&gt;</code>" in html
    assert '<a href="https://example.org/?a=1&amp;b=2">site</a>' in html
    assert "snake_case_name stays" in html
    assert '<pre><code class="language-sh">echo &lt;hi&gt; &amp; bye</code></pre>' in html


def test_a_long_answer_is_split_into_several_messages(harness):
    harness.link()
    harness.fake.push_message("write a lot", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.submitted)
    before = len(harness.fake.messages(OWNER_CHAT))
    answer = "\n\n".join(f"Paragraph {i}: " + ("lorem ipsum " * 60) for i in range(20))
    harness.manager.on_run_finished(
        {"run_id": "run-1", "origin": "telegram", "final_answer": answer}
    )
    assert harness.fake.wait_for(
        lambda: "Paragraph 19" in harness.fake.messages(OWNER_CHAT)[-1]["text"]
    )
    parts = harness.fake.messages(OWNER_CHAT)[before:]
    assert len(parts) >= 3
    assert all(len(p["text"]) <= TELEGRAM_MAX_CHARS for p in parts)
    joined = " ".join(p["text"] for p in parts)
    assert all(f"Paragraph {i}:" in joined for i in range(20))


def test_markup_telegram_refuses_is_sent_again_as_plain_text(harness):
    harness.link()
    harness.fake.reject_html = True
    harness.fake.push_message("go", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.submitted)
    harness.manager.on_run_finished(
        {"run_id": "run-1", "origin": "telegram", "final_answer": "**done**"}
    )
    assert harness.fake.wait_for(lambda: harness.fake.messages(OWNER_CHAT)[-1]["text"] == "**done**")
    assert "parse_mode" not in harness.fake.messages(OWNER_CHAT)[-1]


def test_a_rate_limited_send_waits_and_retries(harness):
    harness.link()
    harness.fake.push_message("go", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.submitted)
    harness.fake.fail("sendMessage", (429, 0.2))
    started = time.monotonic()
    harness.manager.on_run_finished(
        {"run_id": "run-1", "origin": "telegram", "final_answer": "after the wait"}
    )
    assert harness.fake.wait_for(
        lambda: harness.fake.messages(OWNER_CHAT)[-1]["text"] == "after the wait"
    )
    assert time.monotonic() - started >= 0.2


def test_files_the_agent_sent_go_out_as_photo_and_document(harness, tmp_path):
    db = tmp_path / "executor-state.db"
    _seed_run_db(db)
    harness.manager._db_path = str(db)
    harness.link()
    harness.fake.push_message("make me a chart", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.submitted)
    harness.manager.on_run_finished({
        "run_id": "run-1", "origin": "telegram", "final_answer": "Here it is.",
        "prompt": f"{PROMPT_MARKER}\nmake me a chart",
    })
    assert harness.fake.wait_for(
        lambda: any(s["method"] == "sendDocument" for s in harness.fake.sent)
    )
    photo = next(s for s in harness.fake.sent if s["method"] == "sendPhoto")
    doc = next(s for s in harness.fake.sent if s["method"] == "sendDocument")
    assert photo["filename"] == "chart.png" and photo["data"] == b"\x89PNG-bytes"
    assert photo["chat_id"] == OWNER_CHAT
    assert doc["filename"] == "report.csv" and doc["data"] == b"a,b\n1,2\n"
    # The earlier run's file in the same window is not this run's.
    assert not any(s.get("filename") == "old.txt" for s in harness.fake.sent)


def _seed_run_db(path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER,
            role TEXT, content TEXT, created_at REAL);
        CREATE TABLE event_blobs (message_id INTEGER PRIMARY KEY, data BLOB NOT NULL);
        CREATE TABLE runs (run_id TEXT PRIMARY KEY, session_id INTEGER, first_mid INTEGER,
            last_mid INTEGER);
        """
    )
    rows = [
        ("user", {"role": "user", "content": "earlier app task"}),
        ("event", {"type": "file", "name": "old.txt", "mime_type": "text/plain"}),
        ("user", {"role": "user", "content": f"{PROMPT_MARKER}\nmake me a chart"}),
        ("event", {"type": "file", "name": "chart.png", "mime_type": "image/png"}),
        ("event", {"type": "file", "name": "report.csv", "mime_type": "text/csv"}),
        ("assistant", {"role": "assistant", "content": "Here it is."}),
    ]
    blobs = {"old.txt": b"old", "chart.png": b"\x89PNG-bytes", "report.csv": b"a,b\n1,2\n"}
    for role, content in rows:
        cur = conn.execute(
            "INSERT INTO messages(session_id, role, content, created_at) VALUES (1, ?, ?, 0)",
            (role, json.dumps(content)),
        )
        if role == "event":
            conn.execute("INSERT INTO event_blobs VALUES (?, ?)", (cur.lastrowid, blobs[content["name"]]))
    conn.execute("INSERT INTO runs VALUES ('run-1', 1, 0, 6)")
    conn.commit()
    conn.close()


def test_read_run_files_without_a_run_is_empty(tmp_path):
    db = tmp_path / "s.db"
    _seed_run_db(db)
    assert read_run_files(str(db), {"run_id": "missing"}) == []
    assert read_run_files(str(db), {}) == []


# --------------------------------------------------------------- resilience


def test_the_poller_backs_off_on_errors_and_recovers(harness):
    harness.fake.fail("getUpdates", 502, "drop", (429, 0.1), 500)
    harness.enable()
    assert harness.fake.wait_for(lambda: harness.frame()["state"] == "polling", timeout=10)
    calls = harness.fake.calls.count("getUpdates")
    assert calls >= 5
    # A state change on the way was pushed to the app.
    assert any(p.get("state") == "backoff" for p in harness.pushed)
    # It still works after the storm.
    harness.fake.push_message("hi", chat_id=OWNER_CHAT)
    assert harness.fake.wait_for(lambda: harness.fake.messages(OWNER_CHAT))


def test_a_refused_token_stops_the_poller(fake):
    h = _Harness(fake)
    try:
        fake.fail("getMe", 401)
        h.frame("enable", token=TOKEN)
        assert fake.wait_for(lambda: h.frame()["state"] == "unauthorized")
        calls = len(fake.calls)
        time.sleep(0.4)
        assert len(fake.calls) == calls  # no hammering with a dead token
        assert TOKEN not in json.dumps(h.frame())
    finally:
        h.manager.stop()


def test_a_webhook_conflict_is_reported_and_retried(harness):
    harness.fake.fail("getUpdates", 409)
    harness.enable()
    assert harness.fake.wait_for(lambda: any(p.get("state") == "conflict" for p in harness.pushed))
    assert harness.fake.wait_for(lambda: harness.frame()["state"] == "polling")


def test_the_offset_survives_a_restart_so_no_message_is_handled_twice(fake, tmp_path):
    store = ChannelStore(path=tmp_path / "channels.enc", key=os.urandom(32))
    h = _Harness(fake, store=store)
    h.link()
    fake.push_message("first task", chat_id=OWNER_CHAT)
    assert fake.wait_for(lambda: h.submitted)
    h.manager.stop()
    offset = store.get(AGENT, "telegram")["offset"]
    assert offset == fake.next_update_id
    h2 = _Harness(fake, store=store)
    try:
        h2.manager.start()
        assert fake.wait_for(lambda: fake.offsets and fake.offsets[-1] == offset)
        time.sleep(0.3)
        assert h2.submitted == []
    finally:
        h2.manager.stop()


def test_stop_cuts_a_long_poll_at_once(fake):
    h = _Harness(fake, poll_timeout=30)
    h.enable()
    time.sleep(0.2)  # inside the 30 s long poll now
    started = time.monotonic()
    h.manager.stop()
    assert time.monotonic() - started < 3.0
    assert not any(
        t.name.startswith("telegram-") and t.is_alive() for t in threading.enumerate()
    )


def test_disable_stops_polling_and_keeps_the_link(harness):
    harness.link()
    reply = harness.frame("disable")
    assert reply["enabled"] is False and reply["state"] == "off" and reply["linked"] is True
    calls = len(harness.fake.calls)
    time.sleep(0.3)
    assert len(harness.fake.calls) == calls
    reply = harness.frame("enable")  # the stored token is reused
    assert reply["enabled"] is True and reply["linked"] is True
    reply = harness.frame("forget")
    assert reply["has_token"] is False and reply["linked"] is False


def test_a_new_token_drops_the_old_link(harness):
    harness.link()
    reply = harness.frame("enable", token=OTHER_TOKEN)
    assert reply["linked"] is False


def test_errors_never_carry_the_token(fake):
    client = TelegramClient(TOKEN, base_url=fake.base_url)
    fake.fail("getMe", 500)
    with pytest.raises(TelegramError) as info:
        client.get_me()
    assert TOKEN not in str(info.value) and "AAFake" not in repr(info.value)
    bad = TelegramClient("1:" + "x" * 40, base_url="http://127.0.0.1:9")
    with pytest.raises(TelegramError) as info:
        bad.get_me()
    assert info.value.kind == "network" and "xxxx" not in str(info.value)
