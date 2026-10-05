"""End-to-end functional run of the Agents host, isolated (bead chuk_chat-b95f).

One real :class:`LocalHost` with its own state directory
(``<repo>/_scratch/e2e/home``, also ``$AGENTS_HOME``), the loopback relay (no
cloud), the docker sandbox on ``agents-browser:latest`` and a scripted model
(no credits, no network to prod). A controller double plays the app over the
real relay: it pairs, provisions, and then stays attached, so every flow sees
the same sealed frames the app sees.

This file is NOT collected by the normal suite (its name does not start with
``test_``): it needs docker, the browser image and a few minutes. Run it on
purpose::

    cd agents/host
    .venv/bin/python -m pytest tests/e2e_isolated_flows.py -v -s

Evidence (frames, runs rows, screenshots) lands in ``_scratch/e2e/``.
Every container this run creates carries this host's owner label and is
removed at the end; the production host's containers are never touched.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

import pytest
from websockets.sync.client import connect

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_runtime.cost import PriceBook
from chuk_agents_runtime.model import ModelResponse

from chuk_agents_executor import task_payload
from chuk_agents_executor.protocol import approval_decision_payload
from chuk_agents_host import LocalHost
from chuk_agents_host.channels import ChannelSettings, PROMPT_MARKER, TelegramTiming
from chuk_agents_host.coworker_names import host_agent_id
from chuk_agents_host.identity import HOST_DEVICE_ID
from chuk_agents_host.protocol import frame_envelope, join_message

from fake_telegram import TOKEN, FakeTelegram
from test_local_run import ControllerDouble

REPO = Path(__file__).resolve().parents[3]
E2E = REPO / "_scratch" / "e2e"
HOME = E2E / "home"
IMAGE = "agents-browser:latest"

MODEL = "z-ai/glm-5.3-flash"
PROVIDER = "deepinfra/fp4"
PRICES = [
    {
        "id": MODEL,
        "providers": [
            {
                "slug": PROVIDER,
                # 1000 prompt + 100 completion = 0.002 EUR per model call.
                "pricing": {"prompt": 1e-06, "completion": 1e-05, "cache_read": 5e-07},
            }
        ],
    }
]
USAGE = {"prompt_tokens": 1000, "completion_tokens": 100, "total_tokens": 1100}
PW = "mcp__playwright__"
#: One thread for flow 1 and most browser flows. The box's one browser server
#: is shared by all threads of the coworker (bead chuk_chat-wrdv); flow 2b
#: checks that with a second thread.
BROWSER_KEY = "e2e-browser"


def _docker_ok() -> bool:
    try:
        if subprocess.run(["docker", "info"], capture_output=True, timeout=20).returncode:
            return False
        return (
            subprocess.run(
                ["docker", "image", "inspect", IMAGE], capture_output=True, timeout=20
            ).returncode
            == 0
        )
    except Exception:  # noqa: BLE001
        return False


pytestmark = pytest.mark.skipif(not _docker_ok(), reason=f"docker or {IMAGE} missing")


# -- evidence ----------------------------------------------------------------------


def evidence(flow: str, **data: Any) -> None:
    E2E.mkdir(parents=True, exist_ok=True)
    with (E2E / "evidence.jsonl").open("a") as fh:
        fh.write(json.dumps({"flow": flow, "at": time.time(), **data}, default=str) + "\n")


# -- the scripted model ---------------------------------------------------------------


def answer(text: str) -> ModelResponse:
    return ModelResponse(text=text, raw={"content": text, "usage": dict(USAGE)})


def call(*calls: tuple[str, dict]) -> ModelResponse:
    response = tool_call_response(*calls)
    response.raw = {"usage": dict(USAGE)}
    return response


Step = ModelResponse | str | Callable[[list[dict]], ModelResponse]


class Router:
    """Picks a script per task from the last user message. The executor calls
    the factory more than once per task (the loop client and the browser
    client), so the choice is made on the first ``complete`` of an instance."""

    def __init__(self) -> None:
        self.routes: list[tuple[str, Callable[[], list[Step]]]] = []
        self.aux_delay: float | None = None
        self.aux_calls: list[dict] = []
        self.models: list["RoutedModel"] = []

    def route(self, marker: str, script: Callable[[], list[Step]]) -> None:
        self.routes.insert(0, (marker, script))

    def factory(self) -> "RoutedModel":
        model = RoutedAuxModel(self) if self.aux_delay is not None else RoutedModel(self)
        self.models.append(model)
        return model

    def last_with(self, marker: str) -> "RoutedModel | None":
        for model in reversed(self.models):
            if model.chosen == marker:
                return model
        return None


class RoutedModel(MockModelClient):
    model_id = MODEL
    provider_slug = PROVIDER

    def __init__(self, router: Router) -> None:
        super().__init__([])
        self._router = router
        self.chosen: str | None = None

    def complete(self, messages: list[dict]) -> ModelResponse:
        if self.chosen is None:
            last_user = next(
                (m for m in reversed(messages) if m.get("role") == "user"), {}
            )
            text = str(last_user.get("content") or "")
            self.chosen = ""
            self._responses = [answer("ok")]
            for marker, script in self._router.routes:
                if marker in text:
                    self.chosen = marker
                    self._responses = list(script())
                    break
        self.calls.append([dict(m) for m in messages])
        if not self._responses:
            return answer("(script exhausted)")
        item = self._responses.pop(0)
        if callable(item) and not isinstance(item, ModelResponse):
            item = item(messages)
        if isinstance(item, str):
            return answer(item)
        return item


class AuxClient:
    """The cheap housekeeping client (context summary). Slow on purpose: a turn
    that waited for it would show it in ``prepare_ms``."""

    model_id = MODEL
    provider_slug = PROVIDER

    def __init__(self, router: Router) -> None:
        self._router = router

    def complete(self, messages: list[dict]) -> ModelResponse:
        started = time.monotonic()
        time.sleep(self._router.aux_delay or 0.0)
        self._router.aux_calls.append(
            {"thread": threading.current_thread().name, "started": started, "wall": time.time() - (time.monotonic() - started),
             "chars": sum(len(str(m.get("content") or "")) for m in messages)}
        )
        return answer("GOAL: e2e context test\nCOMPLETED: seeded history summarised")

    def cheap_clone(self, *_a: Any, **_k: Any) -> "AuxClient":
        return AuxClient(self._router)

    def close(self) -> None:
        pass


class RoutedAuxModel(RoutedModel):
    def cheap_clone(self, *_a: Any, **_k: Any) -> AuxClient:
        return AuxClient(self._router)


# -- a throwaway web server for the sandbox browser ---------------------------------------
#
# The plan was an http.server on the docker bridge (172.17.0.1). On this machine
# the host firewall drops container -> host traffic on the bridge (a curl from a
# throwaway container times out), and changing it needs root. So the page is
# served from INSIDE the agent's own container instead: a python http.server
# over a directory of the bind-mounted workspace. The test writes the pages on
# the host side; the sandbox browser reads them on 127.0.0.1, and the host's own
# URL watch reads them over the bridge on the container's address (host ->
# container is allowed).

WWW_PORT = 8765


class Site:
    def __init__(self, workspace: Path, container: str) -> None:
        self.root = workspace / ".e2e-www"
        self.root.mkdir(parents=True, exist_ok=True)
        self.log = workspace / ".e2e-www.log"
        self.container = container
        subprocess.run(
            ["docker", "exec", "-d", container, "sh", "-c",
             f"cd /workspace/.e2e-www && exec python3 -m http.server {WWW_PORT} "
             f"--bind 0.0.0.0 >> /workspace/.e2e-www.log 2>&1"],
            check=True, capture_output=True, timeout=30,
        )
        self.ip = subprocess.run(
            ["docker", "inspect", "-f",
             "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        self._bump = time.time()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            probe = subprocess.run(
                ["docker", "exec", container, "python3", "-c",
                 f"import urllib.request;urllib.request.urlopen('http://127.0.0.1:{WWW_PORT}/',timeout=2)"],
                capture_output=True, timeout=20,
            )
            if probe.returncode == 0:
                break
            time.sleep(0.5)

    def page(self, path: str, html: str) -> str:
        target = self.root / path.lstrip("/")
        target.write_text(html)
        # A strictly later mtime per write: http.server answers
        # If-Modified-Since with a second-resolution Last-Modified.
        self._bump = max(self._bump + 2, time.time())
        os.utime(target, (self._bump, self._bump))
        return self.url(path)

    def url(self, path: str) -> str:
        """The URL as the sandbox browser sees it."""
        return f"http://127.0.0.1:{WWW_PORT}{path}"

    def host_url(self, path: str) -> str:
        """The URL as the host (URL watch) sees it."""
        return f"http://{self.ip}:{WWW_PORT}{path}"

    @property
    def hits(self) -> list[str]:
        try:
            lines = self.log.read_text().splitlines()
        except OSError:
            return []
        return [m.group(1) for m in (re.search(r'"GET (\S+) ', line) for line in lines) if m]

    def close(self) -> None:
        pass  # dies with the container


# -- the app, attached for the whole run ------------------------------------------------


class App(ControllerDouble):
    """The controller double, but long-lived: it pairs and provisions once,
    then keeps the socket open. A reader thread opens every sealed frame;
    tests send frames and wait for the ones they expect."""

    def __init__(self, url: str, channel_id: str, code: str) -> None:
        super().__init__(url, channel_id, code)
        self.frames: list[dict] = []
        self._cond = threading.Condition()
        self._send_lock = threading.Lock()
        self._ready = threading.Event()
        self._closing = False
        self._ws = None
        self._thread: threading.Thread | None = None

    def open(self, timeout: float = 30.0) -> None:
        self._ws = connect(self._url, open_timeout=10.0, max_size=64 * 1024 * 1024)
        self._ws.send(json.dumps(join_message(self._channel_id, "controller")))
        self._thread = threading.Thread(target=self._read, daemon=True, name="e2e-app")
        self._thread.start()
        assert self._ready.wait(timeout), "pairing / provisioning did not finish"

    def _provision_and_task(self, ws, prompt: str) -> None:  # pairing done
        token = {
            "type": "account_authentication",
            "access_token": "mock-access",
            "refresh_token": "mock-refresh",
            "user_id": "user-e2e",
        }
        with self._send_lock:
            ws.send(json.dumps(frame_envelope(self._seal(token))))
        self._ready.set()

    def _read(self) -> None:
        ws = self._ws
        while not self._closing:
            try:
                raw = ws.recv(timeout=1.0)
            except TimeoutError:
                continue
            except Exception:  # noqa: BLE001 — socket closed
                return
            msg = json.loads(raw)
            if msg.get("type") == "pairing":
                self._on_pairing(ws, msg.get("data") or {}, "")
            elif msg.get("type") == "frame":
                payload = self._open(msg["frame"])
                payload["_rx"] = time.time()
                if payload.get("type") == "done" and payload.get("run_id") and not payload.get("replay"):
                    # What the app does once it rendered a live done: without
                    # it the host announces the run as "finished while away".
                    try:
                        with self._send_lock:
                            ws.send(json.dumps(frame_envelope(self._seal(
                                {"type": "run_ack", "run_id": payload["run_id"]}))))
                    except Exception:  # noqa: BLE001
                        pass
                with self._cond:
                    self.frames.append(payload)
                    self._cond.notify_all()

    def send(self, payload: dict) -> None:
        with self._send_lock:
            self._ws.send(json.dumps(frame_envelope(self._seal(payload))))

    def mark(self) -> int:
        with self._cond:
            return len(self.frames)

    def wait(
        self, predicate: Callable[[dict], bool], *, since: int = 0, timeout: float = 60.0
    ) -> dict:
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                for frame in self.frames[since:]:
                    if predicate(frame):
                        return frame
                left = deadline - time.monotonic()
                if left <= 0:
                    types = [f.get("type") for f in self.frames[since:]]
                    raise AssertionError(f"frame not seen in {timeout}s; got {types[-40:]}")
                self._cond.wait(min(left, 1.0))

    def since(self, mark: int) -> list[dict]:
        with self._cond:
            return list(self.frames[mark:])

    def start(self, prompt: str, session_key: str, **extra) -> int:
        """Send a task and return the frame mark it started at."""
        mark = self.mark()
        payload = task_payload(prompt, session_key)
        payload.update(extra)
        self.send(payload)
        return mark

    def finish(self, session_key: str, mark: int, *, timeout: float = 120.0) -> list[dict]:
        self.wait(
            lambda f: f.get("type") == "done" and f.get("session_key") == session_key
            and not f.get("replay"),
            since=mark,
            timeout=timeout,
        )
        return [f for f in self.since(mark) if f.get("session_key") in (session_key, None)]

    def task(self, prompt: str, session_key: str, *, timeout: float = 120.0, **extra) -> list[dict]:
        """Send a task and return every frame of that session until its done."""
        mark = self.mark()
        payload = task_payload(prompt, session_key)
        payload.update(extra)
        self.send(payload)
        self.wait(
            lambda f: f.get("type") == "done" and f.get("session_key") in (session_key, None)
            and not f.get("replay"),
            since=mark,
            timeout=timeout,
        )
        return [f for f in self.since(mark) if f.get("session_key") in (session_key, None)]

    def close(self) -> None:
        self._closing = True
        try:
            if self._ws is not None:
                self._ws.close()
        except Exception:  # noqa: BLE001
            pass
        if self._thread is not None:
            self._thread.join(timeout=5)


# -- the isolated host --------------------------------------------------------------------


class Rig:
    def __init__(self) -> None:
        self.router = Router()
        self.site: Site | None = None
        self.telegram: FakeTelegram | None = None
        self.host: LocalHost | None = None
        self.app: App | None = None
        self.log_lines: list[str] = []
        self.desktop: list[tuple[str, str]] = []

    def log(self, line: str) -> None:
        self.log_lines.append(line)
        with (E2E / "host.log").open("a") as fh:
            fh.write(f"{time.strftime('%H:%M:%S')} {line}\n")

    @property
    def db(self) -> str:
        return str(HOME / "executor-state.db")

    def runs(self, session_key: str) -> list[dict]:
        con = sqlite3.connect(self.db)
        con.row_factory = sqlite3.Row
        try:
            rows = con.execute(
                "SELECT * FROM runs WHERE session_key=? ORDER BY started_at", (session_key,)
            ).fetchall()
            return [dict(r) for r in rows]
        finally:
            con.close()

    def container(self) -> str:
        from chuk_agents_sandbox import find_agent_container

        found = find_agent_container(
            agent_id=self.host.agent.id, owner=str(HOME.resolve())
        )
        assert found, "the agent has no container"
        return found.id

    def dexec(self, script: str, timeout: float = 60.0) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["docker", "exec", "-i", self.container(), "python3", "-c", script],
            capture_output=True, text=True, timeout=timeout,
        )


@pytest.fixture(scope="module")
def rig():
    if HOME.exists():
        # The transcript directory is read-only on purpose (the agent must not
        # edit its own transcript); make it writable to clear the old run.
        subprocess.run(["chmod", "-R", "u+w", str(HOME)], check=False)
        shutil.rmtree(HOME)
    HOME.mkdir(parents=True)
    for name in ("evidence.jsonl", "host.log"):
        (E2E / name).unlink(missing_ok=True)
    before = set(_containers())
    mp = pytest.MonkeyPatch()
    mp.setenv("AGENTS_HOME", str(HOME))
    mp.setenv("AGENTS_SANDBOX_IMAGE", IMAGE)
    mp.setenv("AGENTS_DESKTOP_NOTIFY", "0")
    mp.setenv("AGENTS_AGENT_MAIL", "0")
    mp.setenv("AGENTS_TAKEOVER_WAIT_SECONDS", "120")
    for name in ("AGENTS_NTFY_TOPIC", "AGENTS_WEBHOOK_URL", "AGENTS_BROWSER_TARGET"):
        mp.delenv(name, raising=False)
    r = Rig()
    r.telegram = FakeTelegram().__enter__()
    host = LocalHost(
        port=0,
        workspace_dir=str(HOME),
        agent_name="e2e-worker",
        channel_id="e2echannel00",
        digits="271828",
        sandbox_kind="docker",
        model_factory_override=r.router.factory,
        channel_settings=ChannelSettings(
            telegram_api_base=r.telegram.base_url,
            timing=TelegramTiming(poll_timeout=1, backoff_base=0.05, backoff_max=0.2, send_interval=0.0),
        ),
        logger=r.log,
    )
    r.host = host
    host.start()
    try:
        r.app = App(host.url, host.channel_id, host.pairing_code)
        r.app.open()
        # The price list the provisioning would read from /v1/models_info.
        host._price_book = PriceBook(PRICES)
        # The agent's box, up before the first flow; the test page server lives in it.
        env = host._make_environment()
        env.run_bash("true", internal=True)
        r.site = Site(Path(host._workspace_for_agent(host.agent.id)), r.container())
        # Record what a toast would say instead of showing one.

        class _Desktop:
            def notify(self, title, body, *a, **k):
                r.desktop.append((title, body))
                return True

        host._desktop_notifier = _Desktop()
        if getattr(host, "_notifier", None) is not None:
            host._notifier._desktop = host._desktop_notifier
        yield r
    finally:
        try:
            if r.app is not None:
                r.app.close()
        finally:
            host.stop()
            from chuk_agents_sandbox import DockerEnvironment

            try:
                DockerEnvironment(agent_id=host.agent.id, image=IMAGE).remove()
            except Exception as exc:  # noqa: BLE001
                r.log(f"container remove: {exc}")
            r.telegram.__exit__(None, None, None)
            mp.undo()
            leftover = set(_containers()) - before
            evidence("cleanup", new_containers_left=sorted(leftover))


def _containers() -> list[str]:
    out = subprocess.run(
        ["docker", "ps", "-a", "--format", "{{.Names}}"], capture_output=True, text=True
    ).stdout
    return [line for line in out.splitlines() if line]


def _strip(frames: list[dict]) -> list[dict]:
    """Frames for the evidence file, without bulky data."""
    out = []
    for f in frames:
        g = {k: v for k, v in f.items() if k not in ("data",)}
        for key in ("result", "text", "final_answer"):
            if isinstance(g.get(key), str) and len(g[key]) > 300:
                g[key] = g[key][:300] + "..."
        out.append(g)
    return out


# -- flow 1: a task, streamed answer, done with cost, runs row ---------------------------


def test_flow1_task_streams_and_records_the_run(rig: Rig):
    # 0.4 s of "thinking" so the first-token clock has something to measure.
    rig.router.route("flow1", lambda: [lambda _m: (time.sleep(0.4), answer("The answer is 42."))[1]])
    frames = rig.app.task("flow1: what is the answer?", BROWSER_KEY)
    types = [f["type"] for f in frames]
    done = [f for f in frames if f["type"] == "done"][-1]
    evidence("1", types=types, done=_strip([done])[0])
    assert "delta" in types, types
    text = "".join(f.get("text", "") for f in frames if f["type"] == "delta")
    assert "42" in text
    assert done["final_answer"] == "The answer is 42."
    assert done["reason"] == "finished"
    cost = done.get("cost")
    assert cost and cost["currency"] == "EUR" and cost["eur"] == pytest.approx(0.002), done
    run = rig.runs(BROWSER_KEY)[-1]
    evidence(
        "1-row",
        **{k: run[k] for k in ("state", "prepare_ms", "first_token_ms", "model_wait_ms", "cost_eur", "prompt_tokens", "completion_tokens", "tokens_spent")},
    )
    assert run["state"] == "finished"
    assert run["cost_eur"] == pytest.approx(0.002)
    assert run["prepare_ms"] >= 0


# -- flow 2: browser tools, a local page, a screenshot without black area ----------------

PAGE_HTML = """<!doctype html><html><head><title>E2E page</title>
<style>html,body{margin:0;height:100%;background:#f4c430}</style></head>
<body><h1 style="margin:0;padding:40px;font:48px sans-serif">e2e page</h1>
<button id="b" onclick="document.title='clicked'">Press</button></body></html>"""

PIXELS = r'''
import sys, json
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
px = im.load()
def black(x, y):
    r, g, b = px[x, y]
    return r < 8 and g < 8 and b < 8
rows = sum(1 for y in range(h) if all(black(x, y) for x in range(0, w, 4)))
cols = sum(1 for x in range(w) if all(black(x, y) for y in range(0, h, 4)))
print(json.dumps({"size": [w, h], "black_rows": rows, "black_cols": cols}))
'''

ROOT_GRAB = r'''
import json, subprocess
from PIL import ImageGrab
im = ImageGrab.grab(xdisplay=":99")
im.save("/tmp/e2e-root.png")
out = subprocess.run(["xdpyinfo", "-display", ":99"], capture_output=True, text=True).stdout
dims = [l.split()[1] for l in out.splitlines() if "dimensions:" in l]
print(json.dumps({"size": list(im.size), "xdpyinfo": dims}))
'''


def test_flow2_browser_screenshot_fills_the_display(rig: Rig):
    assert "browser ready" in rig.host.sandbox_summary, rig.host.sandbox_summary
    url = rig.site.page("/e2e.html", PAGE_HTML)
    rig.router.route(
        "flow2",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            call((PW + "browser_take_screenshot", {"type": "png", "filename": "e2e-shot.png"})),
            answer("screenshot taken"),
        ],
    )
    frames = rig.app.task("flow2: open the page and take a screenshot", BROWSER_KEY, timeout=180)
    tools = [f for f in frames if f["type"] == "tool"]
    evidence("2-tools", tools=_strip(tools), hits=rig.site.hits)
    names = [t.get("name") for t in tools]
    assert PW + "browser_navigate" in names and PW + "browser_take_screenshot" in names, names
    assert "/e2e.html" in rig.site.hits, "the sandbox browser never reached the page"
    assert all(t.get("status") == "completed" for t in tools), tools
    # The screenshot lands in the bind-mounted workspace (the MCP server's cwd).
    workspace = Path(rig.host._workspace_for_agent(rig.host.agent.id))
    png = workspace / "e2e-shot.png"
    assert png.exists(), "no screenshot file in the workspace"
    shutil.copy(png, E2E / "flow2-screenshot.png")
    shot = json.loads(rig.dexec(PIXELS.replace("sys.argv[1]", "'/workspace/e2e-shot.png'")).stdout)
    # The whole X display, i.e. what the VNC live view shows.
    root = json.loads(rig.dexec(ROOT_GRAB).stdout)
    root_px = json.loads(rig.dexec(PIXELS.replace("sys.argv[1]", "'/tmp/e2e-root.png'")).stdout)
    subprocess.run(["docker", "cp", f"{rig.container()}:/tmp/e2e-root.png", str(E2E / "flow2-display.png")],
                   capture_output=True, timeout=30)
    evidence("2", screenshot=shot, display=root, display_pixels=root_px)
    display = [int(v) for v in root["xdpyinfo"][0].split("x")]
    # browser_take_screenshot is the page viewport: the window is the display
    # plus 1 px (browser-mcp.sh), minus the browser's own toolbar in height.
    assert display[0] <= shot["size"][0] <= display[0] + 1, (shot, display)
    assert display[1] * 0.8 <= shot["size"][1] <= display[1], (shot, display)
    assert shot["black_rows"] == 0 and shot["black_cols"] == 0, shot
    assert root_px["size"] == display
    assert root_px["black_rows"] == 0 and root_px["black_cols"] == 0, root_px


def test_flow2b_a_second_thread_of_the_coworker_browses_too(rig: Rig):
    """chuk_chat-wrdv: a second thread of the same coworker (same box, same
    browser profile) gets the browser too; the box runs one browser server."""
    url = rig.site.page("/second.html", PAGE_HTML)
    rig.router.route(
        "flow2b",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            answer("second thread browsed"),
        ],
    )
    key = "e2e-thread2"
    frames = rig.app.task("flow2b: open the page from another thread", key, timeout=180)
    tools = [f for f in frames if f["type"] == "tool"]
    ps = subprocess.run(["docker", "exec", rig.container(), "ps", "-eo", "pid,args"],
                        capture_output=True, text=True, timeout=30).stdout
    owners = [ln for ln in ps.splitlines() if "browser-mcp-owner" in ln]
    evidence("2b", tools=_strip(tools), owners=owners)
    assert [t.get("status") for t in tools] == ["completed"], tools
    assert "/second.html" in rig.site.hits
    assert frames[-1]["final_answer"] == "second thread browsed"
    assert len(owners) <= 1, owners


# -- flow 3: browser takeover, decided by the user and resolved by the host ---------------

LOGIN_HTML = """<!doctype html><html><head><title>Sign in</title></head>
<body style="background:#fff"><h1>Sign in</h1><input name="user"></body></html>"""

AUTO_LOGIN_HTML = """<!doctype html><html><head><title>Sign in</title>
<script>setTimeout(function(){ location.href = "/home.html"; }, 6000);</script></head>
<body><h1>Sign in (leaves by itself)</h1></body></html>"""

HOME_HTML = """<!doctype html><html><head><title>Home</title></head>
<body><h1>Signed in</h1></body></html>"""


def _tool_result(frames: list[dict], name: str) -> dict:
    tool = [f for f in frames if f["type"] == "tool" and f.get("name") == name][-1]
    raw = tool.get("result")
    try:
        return json.loads(raw) if isinstance(raw, str) else (raw or {})
    except ValueError:
        return {"raw": raw}


def test_flow3a_takeover_blocks_until_the_user_decides(rig: Rig):
    url = rig.site.page("/login.html", LOGIN_HTML)
    rig.router.route(
        "flow3a",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            call(("request_takeover", {"kind": "login", "reason": "e2e sign in"})),
            answer("continuing after the sign in"),
        ],
    )
    key = BROWSER_KEY
    mark = rig.app.start("flow3a: sign in for me", key)
    ask = rig.app.wait(
        lambda f: (f.get("type") == "approval_request" and f.get("action") == "browser_takeover"
                   and not f.get("decision"))
        or (f.get("type") == "done" and f.get("session_key") == key),
        since=mark, timeout=120,
    )
    if ask["type"] == "done":
        frames = [f for f in rig.app.since(mark) if f.get("session_key") in (key, None)]
        ps = subprocess.run(["docker", "exec", rig.container(), "ps", "-eo", "pid,etimes,args"],
                            capture_output=True, text=True, timeout=30).stdout
        evidence("3a-fail", frames=_strip(frames),
                 browser_procs=[ln for ln in ps.splitlines() if "browser-mcp" in ln or "playwright" in ln][:10],
                 log=[ln for ln in rig.log_lines if "mcp" in ln.lower() or "browser" in ln.lower()][-20:])
        raise AssertionError(f"no takeover card; tool said {_tool_result(frames, 'request_takeover')}")
    # The run waits: no done while the card is open.
    time.sleep(3)
    assert not any(f.get("type") == "done" and f.get("session_key") == key for f in rig.app.since(mark))
    asked_at = time.time()
    rig.app.send(approval_decision_payload(approval_id=ask["approval_id"], approved=True))
    frames = rig.app.finish(key, mark, timeout=60)
    done = frames[-1]
    result = _tool_result(frames, "request_takeover")
    evidence("3a", ask=_strip([ask])[0], result=result, done_after_s=round(done["_rx"] - asked_at, 2))
    assert ask["kind"] == "login" and ask.get("session_key") == key
    assert "status" in json.dumps(result) and "done" in json.dumps(result), result
    assert done["final_answer"] == "continuing after the sign in"


def test_flow3b_takeover_resolves_itself_when_the_page_leaves_the_login(rig: Rig):
    rig.site.page("/home.html", HOME_HTML)
    url = rig.site.page("/login2.html", AUTO_LOGIN_HTML)
    rig.router.route(
        "flow3b",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            call(("request_takeover", {"kind": "login", "reason": "e2e auto"})),
            answer("auto continued"),
        ],
    )
    key = BROWSER_KEY
    mark = rig.app.start("flow3b: sign in, I will do it", key)
    ask = rig.app.wait(
        lambda f: f.get("type") == "approval_request" and f.get("action") == "browser_takeover"
        and not f.get("decision"),
        since=mark, timeout=120,
    )
    decided = rig.app.wait(
        lambda f: f.get("type") == "approval_request" and f.get("approval_id") == ask["approval_id"]
        and f.get("decision"),
        since=mark, timeout=60,
    )
    frames = rig.app.finish(key, mark, timeout=60)
    result = _tool_result(frames, "request_takeover")
    evidence("3b", ask=_strip([ask])[0], decided=_strip([decided])[0], result=result,
             resolved_after_s=round(decided["_rx"] - ask["_rx"], 2))
    assert decided["decision"] == "approved" and decided["decision_reason"] == "auto", decided
    assert "/home.html" in rig.site.hits
    assert frames[-1]["final_answer"] == "auto continued"


# -- flow 4: per-action approval, "always this site" ---------------------------------------


def test_flow4_browser_act_asks_once_then_always_this_site(rig: Rig):
    agent = host_agent_id(HOST_DEVICE_ID)
    mark = rig.app.mark()
    rig.app.send({"type": "agent_permissions_set", "agent_id": agent,
                  "approvals": {"classes": {"browser_act": "ask"}}})
    perms = rig.app.wait(lambda f: f.get("type") == "agent_permissions", since=mark, timeout=30)
    assert perms["approvals"]["classes"]["browser_act"] == "ask", perms
    url = rig.site.page("/act.html", PAGE_HTML)
    rig.router.route(
        "flow4",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            call((PW + "browser_press_key", {"key": "Tab"})),
            call((PW + "browser_press_key", {"key": "Tab"})),
            answer("pressed twice"),
        ],
    )
    key = BROWSER_KEY
    mark = rig.app.start("flow4: press tab twice", key)
    card = rig.app.wait(
        lambda f: (f.get("type") == "approval_request" and f.get("action") == "action_approval")
        or (f.get("type") == "done" and f.get("session_key") == key),
        since=mark, timeout=120,
    )
    if card["type"] == "done":
        frames = [f for f in rig.app.since(mark) if f.get("session_key") in (key, None)]
        evidence("4-fail", frames=_strip(frames))
        raise AssertionError("no approval card for browser_act")
    assert card["action_class"] == "browser_act", card
    assert "always_this_site" in card["options"], card
    rig.app.send(approval_decision_payload(
        approval_id=card["approval_id"], approved=True, scope="always_this_site"))
    frames = rig.app.finish(key, mark, timeout=90)
    every = rig.app.since(mark)
    cards = [f for f in every if f.get("type") == "approval_request" and f.get("action") == "action_approval"
             and not f.get("decision")]
    presses = [f for f in frames if f["type"] == "tool" and f.get("name") == PW + "browser_press_key"]
    broadcast = [f for f in every if f.get("type") == "agent_permissions"]
    evidence("4", card=_strip([card])[0], cards=len(cards),
             presses=[p.get("status") for p in presses], press_results=[p.get("result") for p in presses],
             sites=(broadcast[-1]["approvals"].get("sites") if broadcast else None))
    # Back to the default, so later flows browse without a card.
    rig.app.send({"type": "agent_permissions_set", "agent_id": agent,
                  "approvals": {"classes": {"browser_act": "allow"}, "sites": {"browser_act": []}}})
    assert len(cards) == 1, cards
    assert broadcast and card.get("site") in broadcast[-1]["approvals"]["sites"].get("browser_act", [])
    # The card was for the first (unsearched) press, and it ran
    # (chuk_chat-3oh6); the second press asked nothing and ran.
    assert [p.get("status") for p in presses] == ["completed", "completed"], presses


def test_flow4s_browser_act_after_search_tools_runs_the_approved_call(rig: Rig):
    """The same card, but the model searched for the tool first (what a real
    model is told to do). Narrows chuk_chat-3oh6 to unsearched calls."""
    agent = host_agent_id(HOST_DEVICE_ID)
    mark = rig.app.mark()
    rig.app.send({"type": "agent_permissions_set", "agent_id": agent,
                  "approvals": {"classes": {"browser_act": "ask"}, "sites": {"browser_act": []}}})
    rig.app.wait(lambda f: f.get("type") == "agent_permissions"
                 and f["approvals"]["classes"]["browser_act"] == "ask", since=mark, timeout=30)
    url = rig.site.page("/act2.html", PAGE_HTML)
    rig.router.route(
        "flow4s",
        lambda: [
            call((PW + "browser_navigate", {"url": url})),
            call(("search_tools", {"queries": ["browser_press_key"]})),
            call((PW + "browser_press_key", {"key": "Tab"})),
            answer("pressed once"),
        ],
    )
    key = BROWSER_KEY
    mark = rig.app.start("flow4s: search, then press tab", key)
    card = rig.app.wait(
        lambda f: (f.get("type") == "approval_request" and f.get("action") == "action_approval")
        or (f.get("type") == "done" and f.get("session_key") == key),
        since=mark, timeout=120,
    )
    try:
        assert card["type"] == "approval_request", "no card"
        rig.app.send(approval_decision_payload(approval_id=card["approval_id"], approved=True, scope="once"))
        frames = rig.app.finish(key, mark, timeout=90)
    finally:
        rig.app.send({"type": "agent_permissions_set", "agent_id": agent,
                      "approvals": {"classes": {"browser_act": "allow"}}})
    presses = [f for f in frames if f["type"] == "tool" and f.get("name") == PW + "browser_press_key"]
    evidence("4s", statuses=[p.get("status") for p in presses],
             results=[str(p.get("result"))[:300] for p in presses])
    assert [p.get("status") for p in presses] == ["completed"], presses


# -- flow 5: a file for the user ---------------------------------------------------------


def test_flow5_send_file_to_user_reaches_the_app_and_the_store(rig: Rig):
    from chuk_agents_runtime import StateStore

    script = "import os; open('e2e-file.bin','wb').write(bytes(range(256))*8)"
    rig.router.route(
        "flow5",
        lambda: [
            call(("run_command", {"command": f'python3 -c "{script}"'})),
            call(("send_file_to_user", {"path": "e2e-file.bin"})),
            answer("file sent"),
        ],
    )
    key = "e2e-flow5"
    frames = rig.app.task("flow5: make me a file", key)
    files = [f for f in frames if f["type"] == "file"]
    expected = bytes(range(256)) * 8
    evidence("5", files=_strip(files), tools=[(f.get("name"), f.get("status")) for f in frames if f["type"] == "tool"])
    assert len(files) == 1, [f["type"] for f in frames]
    frame = files[0]
    assert frame["name"] == "e2e-file.bin" and frame["size"] == len(expected)
    assert base64.b64decode(frame["data"]) == expected
    store = StateStore(rig.db)
    try:
        replay = store.replay_events(store.route(key))
        row = next(e for e in replay if e["type"] == "file")
        blob = store.event_blob(row["mid"]) if "mid" in row else None
    finally:
        store.close()
    evidence("5-store", row={k: v for k, v in row.items() if k != "data"}, blob_bytes=len(blob or b""))
    assert blob == expected, "the persisted file row has no matching blob"


# -- flow 6: automations ----------------------------------------------------------------


def _automation_events(frames: list[dict], automation_id: str) -> list[dict]:
    return [f for f in frames if f.get("type") == "automation" and f.get("id") == automation_id]


def test_flow6a_a_schedule_fires_a_run(rig: Rig):
    rig.router.route("flow6-sched-fired", lambda: [answer("scheduled hello")])
    rig.router.route(
        "flow6a",
        lambda: [
            call(("schedule_task", {"spec": "in 5s", "prompt": "flow6-sched-fired say hello",
                                    "name": "e2e schedule"})),
            answer("scheduled"),
        ],
    )
    key = "e2e-auto"
    mark = rig.app.mark()
    rig.app.task("flow6a: remind me in 5 seconds", key)
    created = next(f for f in rig.app.since(mark) if f.get("type") == "automation" and f.get("event") == "created")
    aid = created["id"]
    fired = rig.app.wait(lambda f: f.get("type") == "automation" and f.get("id") == aid
                         and f.get("event") == "fired", since=mark, timeout=90)
    run_done = rig.app.wait(lambda f: f.get("type") == "done" and f.get("run_id") == fired.get("run_id"),
                            since=mark, timeout=60)
    evidence("6a", created=_strip([created])[0], fired=_strip([fired])[0],
             fired_after_s=round(fired["_rx"] - created["_rx"], 1),
             done=_strip([run_done])[0])
    assert run_done["final_answer"] == "scheduled hello"
    assert run_done.get("host_notified") is True
    rows = [r for r in rig.runs(key) if r["run_id"] == fired["run_id"]]
    assert rows and rows[0]["state"] == "finished"


WATCH_V1 = "<html><body><h1>Price</h1><p>129 EUR</p></body></html>"
WATCH_V2 = "<html><body><h1>Price</h1><p>99 EUR</p></body></html>"
WATCH_V3 = "<html><body><h1>Price</h1><p>99 EUR</p><footer>updated</footer></body></html>"


def test_flow6b_watch_url_fires_only_on_change_and_on_change_mutes_the_push(rig: Rig):
    manager = rig.host._automations
    # The SSRF guard refuses private addresses by design; the page lives in the
    # agent's box on the docker bridge, so this run lifts it (test seam).
    manager._allow_private_urls = True
    manager._rate_window = 0.0
    rig.site.page("/watch.html", WATCH_V1)
    url = rig.site.host_url("/watch.html")
    fires = {"n": 0}

    def watch_script():
        fires["n"] += 1
        if fires["n"] == 1:
            return [call(("automation_result", {"changed": True, "summary": "price 99 EUR"})),
                    answer("the price dropped to 99 EUR")]
        return [call(("automation_result", {"changed": False, "summary": "price 99 EUR"})),
                answer("nothing new")]

    rig.router.route("flow6-watch-fired", watch_script)
    rig.router.route(
        "flow6b",
        lambda: [
            call(("watch_url", {"url": url, "prompt": "flow6-watch-fired check the price",
                                "every": 900, "name": "e2e price", "notify": "on_change"})),
            answer("watching"),
        ],
    )
    key = "e2e-auto"
    mark = rig.app.mark()
    rig.app.task("flow6b: watch the price page", key)
    created = next(f for f in rig.app.since(mark) if f.get("type") == "automation" and f.get("event") == "created")
    aid = created["id"]
    store = manager.store

    def check() -> int:
        store.update(aid, next_fire_at=0)
        return manager.run_url_checks_once()

    hits_before = len(rig.site.hits)
    assert check() == 0, "the first check must only record a baseline"
    assert check() == 0, "an unchanged page must not fire"
    unchanged_errors = store.get(aid).get("last_error")
    desktop_before = len(rig.desktop)
    rig.site.page("/watch.html", WATCH_V2)
    assert check() == 1, store.get(aid)
    fired1 = rig.app.wait(lambda f: f.get("type") == "automation" and f.get("id") == aid
                          and f.get("event") == "fired", since=mark, timeout=60)
    done1 = rig.app.wait(lambda f: f.get("type") == "done" and f.get("run_id") == fired1["run_id"],
                         since=mark, timeout=60)
    time.sleep(1)
    desktop_after_change = len(rig.desktop)
    mark2 = rig.app.mark()
    rig.site.page("/watch.html", WATCH_V3)
    assert check() == 1
    fired2 = rig.app.wait(lambda f: f.get("type") == "automation" and f.get("id") == aid
                          and f.get("event") == "fired", since=mark2, timeout=60)
    done2 = rig.app.wait(lambda f: f.get("type") == "done" and f.get("run_id") == fired2["run_id"],
                         since=mark2, timeout=60)
    result2 = rig.app.wait(lambda f: f.get("type") == "automation" and f.get("id") == aid
                           and f.get("event") == "result" and f.get("run_id") == fired2["run_id"],
                           since=mark2, timeout=30)
    time.sleep(1)
    evidence("6b", url=url, fetches=len(rig.site.hits) - hits_before, last_error=unchanged_errors,
             fired1=_strip([fired1])[0], done1_result=done1.get("automation_result"),
             done2_result=done2.get("automation_result"), result2=_strip([result2])[0],
             desktop=rig.desktop[desktop_before:])
    assert unchanged_errors in (None, ""), unchanged_errors
    assert done1.get("automation_result", {}).get("changed") is True
    assert desktop_after_change == desktop_before + 1, rig.desktop
    assert done2.get("automation_result", {}).get("changed") is False
    assert result2["changed"] is False and result2.get("reported") is True
    assert len(rig.desktop) == desktop_after_change, "an unchanged on_change run still notified"
    rig.app.send({"type": "automation_control", "id": aid, "action": "cancel"})


# -- flow 7: weekly budget ----------------------------------------------------------------


def _week_spend(rig: Rig) -> float:
    from chuk_agents_runtime.cost import week_start

    con = sqlite3.connect(rig.db)
    try:
        (total,) = con.execute(
            "SELECT COALESCE(SUM(cost_eur), 0) FROM usage_lines WHERE created_at >= ?",
            (week_start(),),
        ).fetchone()
    finally:
        con.close()
    return float(total or 0.0)


def test_flow7_budget_refuses_the_next_run_and_override_runs(rig: Rig):
    agent = host_agent_id(HOST_DEVICE_ID)
    spent = _week_spend(rig)
    budget = (int(spent * 100) + 2) / 100.0  # 1-2 cents above what is spent
    mark = rig.app.mark()
    rig.app.send({"type": "agent_permissions_set", "agent_id": agent, "budget_weekly": budget})
    reply = rig.app.wait(lambda f: f.get("type") == "agent_permissions" and "budget_weekly" in f,
                         since=mark, timeout=30)
    assert reply["budget_weekly"] == budget, reply
    try:
        # 12 model calls = 0.024 EUR: this run crosses the budget.
        rig.router.route(
            "flow7-spend",
            lambda: [call(("run_command", {"command": "true"})) for _ in range(11)] + [answer("spent")],
        )
        rig.router.route("flow7-again", lambda: [answer("ran on the override")])
        key = "e2e-budget"
        first = rig.app.task("flow7-spend: do a lot", key, timeout=180)
        warnings = [f for f in first if f["type"] == "budget_warning"]
        second = rig.app.task("flow7-again: once more", key)
        done2 = [f for f in second if f["type"] == "done"][-1]
        third = rig.app.task("flow7-again: once more", key, budget_override=True)
        done3 = [f for f in third if f["type"] == "done"][-1]
        evidence("7", spent_before=spent, budget=budget, spend_after_first=_week_spend(rig),
                 warnings=_strip(warnings), refused=_strip([done2])[0], override=_strip([done3])[0])
        assert first[-1]["reason"] == "finished"
        assert any(w["level"] == "exceeded" for w in warnings), warnings
        assert done2["reason"] == "budget_exceeded", done2
        assert done2["iterations"] == 0 and done2["tokens_spent"] == 0
        assert done3["reason"] == "finished" and done3["iterations"] >= 1, done3
        assert done3["final_answer"] == "ran on the override"
    finally:
        rig.app.send({"type": "agent_permissions_set", "agent_id": agent, "budget_weekly": 0})


# -- flow 8: Telegram -----------------------------------------------------------------------


def test_flow8_telegram_link_inbound_run_reply(rig: Rig):
    agent = host_agent_id(HOST_DEVICE_ID)
    fake = rig.telegram
    rig.router.route(
        PROMPT_MARKER,
        lambda: [
            call(("run_command", {"command": "printf 'a,b\\n1,2\\n' > report.csv"})),
            call(("send_file_to_user", {"path": "report.csv"})),
            answer("**Report** attached."),
        ],
    )
    mark = rig.app.mark()
    rig.app.send({"type": "agent_channel_set", "agent_id": agent, "channel": "telegram",
                  "action": "enable", "token": TOKEN})
    reply = rig.app.wait(lambda f: f.get("type") == "agent_channel", since=mark, timeout=30)
    assert reply.get("enabled") is True and "error" not in reply, reply
    fake.push_message("/start", chat_id=8150)
    assert fake.wait_for(lambda: fake.messages(8150), timeout=30)
    code = re.search(r"\b(\d{6})\b", fake.messages(8150)[-1]["text"]).group(1)
    mark = rig.app.mark()
    rig.app.send({"type": "agent_channel_set", "agent_id": agent, "channel": "telegram",
                  "action": "link", "code": code})
    linked = rig.app.wait(lambda f: f.get("type") == "agent_channel"
                          and (f.get("linked") is True or "error" in f), since=mark, timeout=30)
    assert linked["linked"] is True, linked
    fake.push_message("make me the report", chat_id=8150)
    assert fake.wait_for(lambda: any(s["method"] == "sendDocument" for s in fake.sent), timeout=90), fake.sent
    answers = [m for m in fake.messages(8150) if "attached" in m["text"]]
    doc = next(s for s in fake.sent if s["method"] == "sendDocument")
    runs = [r for r in rig.runs(agent) if PROMPT_MARKER in (r["prompt"] or "")]
    evidence("8", code_sent=True, answer=answers[-1]["text"] if answers else None,
             document={"filename": doc["filename"], "bytes": len(doc["data"])},
             run=({k: runs[-1][k] for k in ("state", "reason", "session_key")} if runs else None))
    assert answers and answers[-1]["text"] == "<b>Report</b> attached."
    assert doc["filename"] == "report.csv" and doc["data"] == b"a,b\n1,2\n"
    assert runs and runs[-1]["state"] == "finished"
    rig.app.send({"type": "agent_channel_set", "agent_id": agent, "channel": "telegram", "action": "disable"})


# -- flow 9: a long session: the summary is made off the turn path ----------------------------


def test_flow9_long_session_summary_runs_in_the_background(rig: Rig):
    from chuk_agents_runtime import StateStore

    key = "e2e-ctx"
    store = StateStore(rig.db)
    try:
        sid = store.route(key)
        chunk = "The quick brown fox reports on build step {i}. " * 110  # ~5.4k chars
        for i in range(70):  # ~380k chars, ~95k tokens: past tier 2, under the hard ceiling
            store.append_message(sid, "user", {"role": "user", "content": f"step {i}: go on"})
            store.append_message(sid, "assistant", {"role": "assistant", "content": chunk.format(i=i)})
    finally:
        store.close()
    rig.router.aux_delay = 4.0
    rig.router.aux_calls.clear()
    try:
        rig.router.route("flow9", lambda: [answer("short answer")])
        t0 = time.time()
        rig.app.task("flow9 first turn", key, timeout=180)
        first_turn_end = time.time()
        # The background job runs after (or during) the turn, never inside prepare.
        deadline = time.time() + 60
        while time.time() < deadline and not rig.router.aux_calls:
            time.sleep(0.5)
        time.sleep(rig.router.aux_delay + 1)
        aux_after_first = list(rig.router.aux_calls)
        con = sqlite3.connect(rig.db)
        try:
            summary_rows = con.execute(
                "SELECT COUNT(*) FROM context_summaries WHERE session_id=?", (sid,)
            ).fetchone()[0]
        finally:
            con.close()
        n_before_second = len(rig.router.aux_calls)
        rig.app.task("flow9 second turn", key, timeout=180)
        aux_during_second = rig.router.aux_calls[n_before_second:]
        first, second = rig.runs(key)[-2:]
        evidence("9", first={k: first[k] for k in ("prepare_ms", "model_wait_ms", "first_token_ms", "prompt_tokens")},
                 second={k: second[k] for k in ("prepare_ms", "model_wait_ms", "first_token_ms", "prompt_tokens")},
                 first_turn_wall_s=round(first_turn_end - t0, 2), aux_after_first=aux_after_first,
                 aux_during_second=aux_during_second, summary_rows=summary_rows)
        assert aux_after_first, "the first turn started no background summary"
        assert summary_rows >= 1
        assert first["prepare_ms"] < 2000, first
        assert second["prepare_ms"] < 500, second
        # The aux client sleeps 4 s per call: a turn that waited for it would
        # show >= 4000 ms in prepare_ms.
    finally:
        rig.router.aux_delay = None
