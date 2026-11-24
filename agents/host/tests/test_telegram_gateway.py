"""The Telegram gateway (CHAT-184) against a fake Bot API and a fake host.

No network: the Bot API is an ``httpx.MockTransport``. The gateway's threads
are not started; the tests call ``handle_update`` / ``poll_once`` / ``pump``
and move a fake clock.
"""

from __future__ import annotations

import base64
import io
import json
import os
from types import SimpleNamespace

import httpx
import pytest

from chuk_agents_host.gateways import (
    build_gateways,
    split_message,
    telegram_token_store,
)
from chuk_agents_host.gateways.cli import cmd_telegram
from chuk_agents_host.gateways.store import GatewayStore, TokenStore
from chuk_agents_host.gateways.telegram import (
    EDIT_INTERVAL,
    HELP_TEXT,
    NOT_READY_TEXT,
    REFUSAL_TEXT,
    TelegramGateway,
)
from chuk_agents_host.gateways.telegram_api import TelegramApiError, TelegramBotApi
from chuk_agents_host.identity import load_or_create_identity

TOKEN = "123456:SECRET-token_value"
OWNER = 1001
STRANGER = 2002


class FakeBot:
    """A Bot API that answers every method and records the calls."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.updates: list[dict] = []
        self.files: dict[str, bytes] = {}
        self.next_id = 100
        self.fail: dict[str, dict] = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        assert TOKEN in path  # the token rides in the URL, and only there
        if "/file/bot" in path:
            name = path.rsplit("/", 1)[-1]
            return httpx.Response(200, content=self.files[name])
        method = path.rsplit("/", 1)[-1]
        if request.headers.get("content-type", "").startswith("multipart/"):
            body = {"_multipart": request.content}
        else:
            body = json.loads(request.content or b"{}")
        self.calls.append((method, body))
        if method in self.fail:
            return httpx.Response(400, json={"ok": False, **self.fail.pop(method)})
        if method == "getUpdates":
            out, self.updates = self.updates, []
            return httpx.Response(200, json={"ok": True, "result": out})
        if method == "getMe":
            return httpx.Response(200, json={"ok": True, "result": {"username": "mybot"}})
        if method == "getFile":
            fid = body["file_id"]
            return httpx.Response(
                200,
                json={"ok": True, "result": {"file_path": f"docs/{fid}", "file_size": len(self.files[fid])}},
            )
        if method in ("sendMessage", "sendDocument"):
            self.next_id += 1
            return httpx.Response(200, json={"ok": True, "result": {"message_id": self.next_id}})
        return httpx.Response(200, json={"ok": True, "result": True})

    def sent(self, method: str) -> list[dict]:
        return [body for m, body in self.calls if m == method]

    def texts(self) -> list[str]:
        return [b["text"] for m, b in self.calls if m in ("sendMessage", "editMessageText")]


class FakeHost:
    def __init__(self, workspace) -> None:
        self.workspace = workspace
        self.listeners: list = []
        self.submitted: list[tuple[str, str, dict]] = []
        self.stopped: list[str] = []
        self.approvals: list[tuple] = []
        self.is_ready = True
        self.counter = 0

    def ready(self):
        return self.is_ready

    def subscribe(self, listener):
        if listener not in self.listeners:
            self.listeners.append(listener)
        return True

    def submit(self, session_key, prompt, meta):
        self.counter += 1
        self.submitted.append((session_key, prompt, meta))
        return f"run{self.counter}"

    def stop(self, session_key):
        self.stopped.append(session_key)
        return 1

    def resolve_approval(self, approval_id, approved, scope):
        self.approvals.append((approval_id, approved, scope))

    def agents(self):
        return [
            {"agent_id": "host:dev", "name": "Ada"},
            {"agent_id": "local:bob:1:x", "name": "Bob"},
        ]

    def default_agent(self):
        return "host:dev"

    def workspace_for(self, session_key):
        return str(self.workspace)

    def secret(self, name):
        return None

    def emit(self, payload):
        for listener in self.listeners:
            listener(payload)


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture()
def env(tmp_path):
    bot = FakeBot()
    api = TelegramBotApi(TOKEN, client=httpx.Client(transport=httpx.MockTransport(bot.handler)))
    ws = tmp_path / "ws"
    ws.mkdir()
    host = FakeHost(ws)
    store = GatewayStore(tmp_path / "state", "telegram")
    clock = Clock()
    logs: list[str] = []
    gw = TelegramGateway(api, host, store, clock=clock, log=logs.append)
    return SimpleNamespace(bot=bot, host=host, store=store, clock=clock, gw=gw, logs=logs, ws=ws, tmp=tmp_path)


def msg(user_id, text=None, *, chat_type="private", update_id=1, **extra):
    message = {
        "message_id": 5,
        "from": {"id": user_id, "is_bot": False, "first_name": "U"},
        "chat": {"id": user_id, "type": chat_type},
        **({"text": text} if text is not None else {}),
        **extra,
    }
    return {"update_id": update_id, "message": message}


def pair(env, user_id=OWNER):
    code = env.store.new_pairing_code()
    env.gw.handle_update(msg(user_id, f"/pair {code}"))
    assert env.store.is_paired(user_id)


# -- access ---------------------------------------------------------------------


def test_unknown_sender_gets_one_refusal_per_hour(env):
    env.gw.handle_update(msg(STRANGER, "hello"))
    env.gw.handle_update(msg(STRANGER, "hello again"))
    assert env.bot.texts() == [REFUSAL_TEXT]
    assert env.host.submitted == []
    env.clock.now += 3601
    env.gw.handle_update(msg(STRANGER, "later"))
    assert env.bot.texts() == [REFUSAL_TEXT, REFUSAL_TEXT]


def test_refusals_are_capped_per_minute(env):
    for uid in range(5000, 5030):
        env.gw.handle_update(msg(uid, "hi"))
    assert len(env.bot.texts()) == 20


def test_pairing_code_works_once(env):
    code = env.store.new_pairing_code()
    env.gw.handle_update(msg(OWNER, f"/pair {code.lower()}"))
    assert env.store.is_paired(OWNER)
    assert "Paired" in env.bot.texts()[-1]
    env.gw.handle_update(msg(STRANGER, f"/pair {code}"))
    assert not env.store.is_paired(STRANGER)


def test_pairing_code_expires(env, monkeypatch):
    store = GatewayStore(env.tmp / "state2", "telegram", clock=lambda: 0.0)
    code = store.new_pairing_code()
    late = GatewayStore(env.tmp / "state2", "telegram", clock=lambda: 601.0)
    assert not late.redeem_code(code, OWNER)


def test_wrong_codes_lock_the_sender_out(env):
    for _ in range(5):
        env.gw.handle_update(msg(STRANGER, "/pair AAAA-AAAA"))
    replies = len(env.bot.texts())
    code = env.store.new_pairing_code()
    env.gw.handle_update(msg(STRANGER, f"/pair {code}"))
    assert not env.store.is_paired(STRANGER)
    assert len(env.bot.texts()) == replies  # silent


def test_group_chats_are_ignored(env):
    pair(env)
    before = len(env.bot.calls)
    env.gw.handle_update(msg(OWNER, "hi", chat_type="group"))
    assert len(env.bot.calls) == before and env.host.submitted == []


def test_store_file_is_private_and_holds_no_code(env):
    code = env.store.new_pairing_code()
    raw = env.store.path.read_text()
    assert code.replace("-", "") not in raw and code not in raw
    assert oct(os.stat(env.store.path).st_mode & 0o777) == "0o600"


# -- routing ----------------------------------------------------------------------


def test_message_becomes_a_run_on_a_stable_thread(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "what time is it"))
    env.gw.handle_update(msg(OWNER, "and now"))
    (k1, p1, m1), (k2, _p2, _m2) = env.host.submitted
    assert k1 == k2 and k1.startswith("host:dev#auto-telegram-")
    assert p1 == "what time is it"
    assert m1 == {"origin": "telegram", "mode_session_key": "host:dev"}
    # The route survives a new gateway (a host restart).
    gw2 = TelegramGateway(env.gw._api, env.host, env.store, clock=env.clock)
    gw2.handle_update(msg(OWNER, "again"))
    assert env.host.submitted[-1][0] == k1


def test_new_starts_another_thread(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "one"))
    env.gw.handle_update(msg(OWNER, "/new"))
    env.gw.handle_update(msg(OWNER, "two"))
    assert env.host.submitted[0][0] != env.host.submitted[1][0]


def test_agent_lists_and_switches(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "/agent"))
    assert "* Ada" in env.bot.texts()[-1] and "- Bob" in env.bot.texts()[-1]
    env.gw.handle_update(msg(OWNER, "/agent bob"))
    env.gw.handle_update(msg(OWNER, "hi bob"))
    key, _prompt, meta = env.host.submitted[-1]
    assert key.startswith("local:bob:1:x#auto-telegram-")
    assert meta["mode_session_key"] == "local:bob:1:x"
    env.gw.handle_update(msg(OWNER, "/agent nobody"))
    assert "No agent" in env.bot.texts()[-1]


def test_stop_stops_the_thread(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "work"))
    env.gw.handle_update(msg(OWNER, "/stop"))
    assert env.host.stopped == [env.host.submitted[0][0]]


def test_not_ready_host_says_so(env):
    pair(env)
    env.host.is_ready = False
    env.gw.handle_update(msg(OWNER, "hi"))
    assert env.bot.texts()[-1] == NOT_READY_TEXT


def test_help(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "/start"))
    assert env.bot.texts()[-1] == HELP_TEXT


# -- streaming ----------------------------------------------------------------------


def test_stream_is_throttled_then_final(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "hi"))
    placeholder = env.bot.sent("sendMessage")[-1]
    assert placeholder["text"] == "..."
    env.host.emit({"type": "delta", "text": "Hel", "run_id": "run1"})
    env.host.emit({"type": "delta", "text": "lo", "run_id": "run99"})  # not ours
    env.gw.pump()
    assert env.bot.sent("editMessageText") == []  # too early
    env.clock.now += EDIT_INTERVAL
    env.host.emit({"type": "delta", "text": "lo", "run_id": "run1"})
    env.gw.pump()
    assert env.bot.sent("editMessageText")[-1]["text"] == "Hello"
    env.host.emit({"type": "done", "run_id": "run1", "final_answer": "Hello there."})
    env.gw.pump()
    assert env.bot.sent("editMessageText")[-1]["text"] == "Hello there."
    assert env.gw.owns_run("run1")


def test_long_answer_is_split(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "long"))
    answer = ("word " * 2000).strip()
    env.host.emit({"type": "done", "run_id": "run1", "final_answer": answer})
    env.gw.pump()
    texts = [env.bot.sent("editMessageText")[-1]["text"]] + [
        b["text"] for b in env.bot.sent("sendMessage")[-2:]
    ]
    assert all(len(t) <= 4096 for t in texts)
    assert " ".join(texts).split() == answer.split()


def test_error_is_reported(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "x"))
    env.host.emit({"type": "error", "run_id": "run1", "message": "model down"})
    env.gw.pump()
    assert "model down" in env.bot.texts()[-1]


# -- approvals ------------------------------------------------------------------------


def _ask(env, options=("once", "always_this_agent", "deny")):
    pair(env)
    env.gw.handle_update(msg(OWNER, "send the mail"))
    env.host.emit(
        {
            "type": "approval_request",
            "approval_id": "a" * 32,
            "action": "action_approval",
            "options": list(options),
            "summary": "Send a mail to bob@example.com",
            "run_id": "run1",
        }
    )
    env.gw.pump()
    card = env.bot.sent("sendMessage")[-1]
    return card


def _press(env, data, user=OWNER):
    env.gw.handle_update(
        {
            "update_id": 9,
            "callback_query": {
                "id": "cb1",
                "from": {"id": user},
                "data": data,
                "message": {"message_id": 1, "chat": {"id": OWNER}},
            },
        }
    )


def test_approval_buttons_map_to_answers(env):
    card = _ask(env)
    labels = [b["text"] for b in card["reply_markup"]["inline_keyboard"][0]]
    assert labels == ["Allow once", "Always", "Skip"]
    assert "bob@example.com" in card["text"]
    _press(env, f"ap:{'a' * 32}:a")
    assert env.host.approvals == [("a" * 32, True, "always_this_agent")]


def test_skip_is_deny_and_once_is_once(env):
    _ask(env)
    _press(env, f"ap:{'a' * 32}:s")
    _press(env, f"ap:{'a' * 32}:o")
    assert env.host.approvals == [("a" * 32, False, "deny"), ("a" * 32, True, "once")]


def test_no_always_button_without_a_lasting_option(env):
    card = _ask(env, options=("once", "deny"))
    labels = [b["text"] for b in card["reply_markup"]["inline_keyboard"][0]]
    assert labels == ["Allow once", "Skip"]


def test_buttons_from_strangers_or_unknown_approvals_do_nothing(env):
    _ask(env)
    _press(env, f"ap:{'a' * 32}:o", user=STRANGER)
    _press(env, f"ap:{'b' * 32}:o")
    assert env.host.approvals == []


def test_decision_closes_the_card(env):
    _ask(env)
    env.host.emit(
        {"type": "approval_request", "approval_id": "a" * 32, "decision": "denied",
         "decision_reason": "timeout", "run_id": "run1"}
    )
    env.gw.pump()
    assert env.bot.sent("editMessageText")[-1]["text"].endswith("Not allowed (timeout).")


# -- files ------------------------------------------------------------------------------


def test_file_event_goes_out_as_a_document(env):
    pair(env)
    env.gw.handle_update(msg(OWNER, "make a csv"))
    env.host.emit(
        {"type": "file", "run_id": "run1", "name": "../report.csv", "mime_type": "text/csv",
         "data": base64.b64encode(b"a,b\n1,2\n").decode()}
    )
    env.gw.pump()
    (body,) = env.bot.sent("sendDocument")
    assert b'filename="report.csv"' in body["_multipart"]
    assert b"a,b\n1,2\n" in body["_multipart"]


def test_document_in_lands_in_the_workspace(env):
    pair(env)
    env.bot.files["F1"] = b"%PDF-1.4 data"
    env.gw.handle_update(
        msg(OWNER, None, caption="read this",
            document={"file_id": "F1", "file_name": "../../evil.pdf", "file_size": 13})
    )
    _key, prompt, _meta = env.host.submitted[-1]
    assert prompt.startswith("read this")
    saved = [p for p in (env.ws / "telegram").iterdir()]
    assert len(saved) == 1 and saved[0].name.endswith("-evil.pdf")
    assert saved[0].read_bytes() == b"%PDF-1.4 data"
    assert f"telegram/{saved[0].name}" in prompt


def test_photo_without_caption(env):
    pair(env)
    env.bot.files["small"] = b"s"
    env.bot.files["big"] = b"bigger"
    env.gw.handle_update(
        msg(OWNER, None, photo=[{"file_id": "small", "file_size": 1}, {"file_id": "big", "file_size": 6}])
    )
    _key, prompt, _meta = env.host.submitted[-1]
    (saved,) = list((env.ws / "telegram").iterdir())
    assert saved.read_bytes() == b"bigger" and "The user sent a file." in prompt


def test_symlinked_inbox_is_refused(env, tmp_path):
    pair(env)
    outside = tmp_path / "outside"
    outside.mkdir()
    (env.ws / "telegram").symlink_to(outside)
    env.bot.files["F1"] = b"x"
    env.gw.handle_update(msg(OWNER, None, document={"file_id": "F1", "file_name": "a.txt"}))
    assert list(outside.iterdir()) == []
    assert "could not save" in env.bot.texts()[-1]
    assert env.host.submitted == []


# -- polling and the API client ------------------------------------------------------------


def test_poll_once_advances_the_offset(env):
    env.bot.updates = [msg(STRANGER, "hi", update_id=41), msg(STRANGER, "hi", update_id=42)]
    assert env.gw.poll_once(timeout=0) == 2
    assert env.store.offset() == 43
    env.gw.poll_once(timeout=0)
    assert env.bot.sent("getUpdates")[-1]["offset"] == 43


def test_api_errors_never_carry_the_token():
    def boom(request):
        raise httpx.ConnectError(f"failed {request.url}")

    api = TelegramBotApi(TOKEN, client=httpx.Client(transport=httpx.MockTransport(boom)))
    with pytest.raises(TelegramApiError) as info:
        api.get_me()
    assert TOKEN not in str(info.value) and "SECRET" not in repr(info.value)
    assert info.value.__cause__ is None and info.value.__suppress_context__
    assert TOKEN not in repr(api)


def test_api_error_has_retry_after():
    def limited(request):
        return httpx.Response(
            429, json={"ok": False, "error_code": 429, "description": "Too Many Requests",
                       "parameters": {"retry_after": 3}},
        )

    api = TelegramBotApi(TOKEN, client=httpx.Client(transport=httpx.MockTransport(limited)))
    with pytest.raises(TelegramApiError) as info:
        api.send_message(1, "x")
    assert info.value.code == 429 and info.value.retry_after == 3


def test_split_message():
    assert split_message("", 10) == [""]
    assert split_message("abc", 10) == ["abc"]
    parts = split_message("aaaa bbbb cccc", 10)
    assert parts == ["aaaa bbbb", "cccc"]
    assert split_message("x" * 25, 10) == ["x" * 10, "x" * 10, "x" * 5]


# -- token store, build, CLI ------------------------------------------------------------------


def test_token_store_seals_the_token(tmp_path):
    identity = load_or_create_identity(tmp_path / "host_device.key")
    store = telegram_token_store(tmp_path, identity)
    store.put(TOKEN)
    assert TOKEN not in store.path.read_text()
    assert oct(os.stat(store.path).st_mode & 0o777) == "0o600"
    assert telegram_token_store(tmp_path, identity).get() == TOKEN
    other = load_or_create_identity(tmp_path / "other.key")
    assert TokenStore(store.path, os.urandom(32)).get() is None
    assert telegram_token_store(tmp_path, other).get() is None


def test_build_gateways_is_off_without_a_token(tmp_path):
    identity = load_or_create_identity(tmp_path / "host_device.key")
    host = FakeHost(tmp_path)
    assert build_gateways(host, tmp_path, identity, environ={}) == []
    telegram_token_store(tmp_path, identity).put(TOKEN)
    (gw,) = build_gateways(host, tmp_path, identity, environ={})
    assert gw.name == "telegram"
    assert build_gateways(host, tmp_path, identity, environ={"AGENTS_GATEWAYS": "0"}) == []


def test_cli_token_pair_status(tmp_path):
    out: list[str] = []
    identity = load_or_create_identity(tmp_path / "host_device.key")
    args = SimpleNamespace(workspace=str(tmp_path), telegram_command="token")
    stdin = io.StringIO(TOKEN + "\n")
    assert cmd_telegram(args, out=out.append, stdin=stdin, identity=identity) == 0
    assert telegram_token_store(tmp_path, identity).get() == TOKEN
    assert all(TOKEN not in line for line in out)

    bad = io.StringIO("not a token\n")
    assert cmd_telegram(args, out=out.append, stdin=bad, identity=identity) == 2

    args.telegram_command = "pair"
    out.clear()
    assert cmd_telegram(args, out=out.append) == 0
    code = out[-1].split()[-1]
    assert GatewayStore(tmp_path, "telegram").redeem_code(code, OWNER, "Me")

    args.telegram_command = "status"
    out.clear()
    assert cmd_telegram(args, out=out.append, identity=identity) == 0
    assert out[0] == "Token stored: yes" and str(OWNER) in out[1]

    args.telegram_command, args.user_id = "unpair", str(OWNER)
    assert cmd_telegram(args, out=out.append) == 0
    assert not GatewayStore(tmp_path, "telegram").is_paired(OWNER)

    args.telegram_command = "off"
    assert cmd_telegram(args, out=out.append, identity=identity) == 0
    assert telegram_token_store(tmp_path, identity).get() is None


# -- the bridge to the real host ------------------------------------------------------------


def test_host_bridge_finds_the_executor_late():
    from chuk_agents_host.gateways.host_bridge import HostBridge

    calls: list = []

    class Exec:
        def add_event_listener(self, fn):
            calls.append(("listen", fn))

        def submit_task(self, key, prompt, meta):
            calls.append(("submit", key, prompt, meta))
            return "r1"

        def stop_session(self, key):
            return 2

        def resolve_approval(self, aid, approved, scope):
            calls.append(("approve", aid, approved, scope))

        def workspace_for(self, key):
            return "/ws"

    class Names:
        def list(self):
            return [
                {"agent_id": "host:dev", "name": "Ada", "host": True},
                {"agent_id": "local:b:1:x", "name": "Bob", "host": False},
            ]

    executor = Exec()
    host = SimpleNamespace(
        _party=None, _agent=SimpleNamespace(id="agent-row"), _device_id="dev",
        _coworker_names=Names(), _secrets_vault=SimpleNamespace(env=lambda: {"TELEGRAM_BOT_TOKEN": "t"}),
    )
    bridge = HostBridge(host)
    assert not bridge.ready() and bridge.submit("k", "p", {}) is None and bridge.stop("k") == 0
    host._party = SimpleNamespace(
        task_server=SimpleNamespace(supervisor=SimpleNamespace(executor=lambda aid: executor))
    )
    assert bridge.ready() and bridge.subscribe(print)
    assert bridge.submit("k", "p", {"origin": "telegram"}) == "r1"
    assert bridge.stop("k") == 2
    bridge.resolve_approval("a", True, "once")
    assert bridge.workspace_for("k") == "/ws"
    assert bridge.default_agent() == "host:dev"
    assert bridge.agents() == [
        {"agent_id": "host:dev", "name": "Ada"},
        {"agent_id": "local:b:1:x", "name": "Bob"},
    ]
    assert bridge.secret("TELEGRAM_BOT_TOKEN") == "t"
    assert ("approve", "a", True, "once") in calls
