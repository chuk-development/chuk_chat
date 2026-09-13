"""here.now publish connector: gating, approval policy, and the real flow.

Two layers are pinned here. The **policy** layer (a fake environment that scripts
the sandbox publisher's output) proves the important guarantees without a
network: the tool is absent unless enabled, a public publish waits on the gate,
a denial does not publish, ``auto`` skips the gate, and an unattended run with
no gate refuses rather than publishing. The **flow** layer runs the embedded
publisher for real against a stub here.now server over ``LocalEnvironment`` — so
the three-step create -> upload -> finalize protocol, and the 24h-expiry note,
are exercised end to end with stdlib only.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from chuk_agents_runtime import (
    HereNowConfig,
    LocalEnvironment,
    PublishRequest,
    ToolRegistry,
    make_publish_handler,
    register_herenow_tools,
)
from chuk_agents_runtime.environment import ProcessResult


# -- policy layer: a fake environment scripting the publisher --------------


class FakeEnv:
    """Returns a canned ``HN_RESULT`` line per mode, and records the modes seen."""

    def __init__(self, scan: dict, publish: dict) -> None:
        self._scan = scan
        self._publish = publish
        self.modes: list[str] = []

    def run_bash(self, cmd: str, *, timeout: int = 120, internal: bool = False):
        mode = "scan" if "HN_MODE=scan" in cmd else "publish"
        self.modes.append(mode)
        payload = self._scan if mode == "scan" else self._publish
        return ProcessResult(
            exit_code=0, stdout="HN_RESULT " + json.dumps(payload) + "\n", stderr=""
        )


SCAN_OK = {"ok": True, "file_count": 2, "total_bytes": 1024, "has_index": True}
PUBLISH_OK = {
    "ok": True,
    "url": "https://bright-canvas-a7k2.here.now/",
    "slug": "bright-canvas-a7k2",
    "anonymous": True,
    "expires_at": "2026-09-04T12:00:00.000Z",
    "claim_url": "https://here.now/c/tok123",
    "file_count": 2,
    "total_bytes": 1024,
}


def test_disabled_config_registers_no_tool() -> None:
    registry = ToolRegistry()
    register_herenow_tools(registry, LocalEnvironment(), HereNowConfig(enabled=False))
    assert not registry.has("herenow_publish")
    # None config (no connector at all) is the same.
    register_herenow_tools(registry, LocalEnvironment(), None)
    assert not registry.has("herenow_publish")


def test_enabled_config_registers_tool() -> None:
    registry = ToolRegistry()
    register_herenow_tools(
        registry, FakeEnv(SCAN_OK, PUBLISH_OK), HereNowConfig(enabled=True), gate=lambda r: True
    )
    assert registry.has("herenow_publish")


def test_ask_mode_waits_on_gate_then_publishes() -> None:
    env = FakeEnv(SCAN_OK, PUBLISH_OK)
    seen: list[PublishRequest] = []

    def gate(req: PublishRequest) -> bool:
        seen.append(req)
        return True

    handler = make_publish_handler(env, HereNowConfig(enabled=True, approval="ask"), gate)
    result = handler("site")
    assert result["ok"] is True
    assert result["url"] == PUBLISH_OK["url"]
    # The gate saw the scan's real measurements, and the scan ran before it.
    assert env.modes == ["scan", "publish"]
    assert seen and seen[0].file_count == 2 and seen[0].total_bytes == 1024
    # Anonymous publish always tells the user it is public and expires.
    assert result["public"] is True and result["anonymous"] is True
    assert result["expires_at"] == PUBLISH_OK["expires_at"]
    assert "expires 24 hours" in result["note"]


def test_denied_gate_does_not_publish() -> None:
    env = FakeEnv(SCAN_OK, PUBLISH_OK)
    handler = make_publish_handler(env, HereNowConfig(enabled=True, approval="ask"), lambda r: False)
    result = handler("site")
    assert result["ok"] is False
    assert result.get("declined") is True
    # Scanned to build the prompt, but never reached publish.
    assert env.modes == ["scan"]


def test_auto_mode_skips_the_gate() -> None:
    env = FakeEnv(SCAN_OK, PUBLISH_OK)

    def gate(req: PublishRequest) -> bool:  # must not be called
        raise AssertionError("auto mode must not ask")

    handler = make_publish_handler(env, HereNowConfig(enabled=True, approval="auto"), gate)
    result = handler("site")
    assert result["ok"] is True
    assert env.modes == ["scan", "publish"]


def test_ask_mode_without_a_gate_refuses() -> None:
    # An unattended run (cron, no user): asks-by-policy but nobody to ask.
    env = FakeEnv(SCAN_OK, PUBLISH_OK)
    handler = make_publish_handler(env, HereNowConfig(enabled=True, approval="ask"), None)
    result = handler("site")
    assert result["ok"] is False
    assert "approval" in result["error"]
    assert env.modes == ["scan"]  # scanned, never published


def test_empty_path_is_rejected_before_any_run() -> None:
    env = FakeEnv(SCAN_OK, PUBLISH_OK)
    handler = make_publish_handler(env, HereNowConfig(enabled=True, approval="auto"), None)
    assert handler("   ")["ok"] is False
    assert env.modes == []


def test_config_from_entry_defaults_safe() -> None:
    # Malformed / unknown collapses to disabled + ask (never silently enabled).
    assert HereNowConfig.from_entry(None).enabled is False
    assert HereNowConfig.from_entry({"enabled": True, "approval": "weird"}).approval == "ask"
    c = HereNowConfig.from_entry({"enabled": True, "approval": "auto", "base_url": "https://x/"})
    assert c.enabled and c.approval == "auto" and c.base_url == "https://x"


# -- flow layer: the real publisher against a stub here.now server ----------


class _StubHereNow(BaseHTTPRequestHandler):
    uploaded: dict[str, bytes] = {}
    finalized = threading.Event()

    def log_message(self, *args):  # silence
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length) if length else b""
        host = self.headers.get("host")
        base = f"http://{host}"
        if self.path == "/api/v1/publish":
            req = json.loads(body)
            uploads = [
                {
                    "path": f["path"],
                    "method": "PUT",
                    "url": f"{base}/upload/{f['path']}",
                    "headers": {"x-test": "1"},
                }
                for f in req["files"]
            ]
            self._json(200, {
                "slug": "stub-site",
                "siteUrl": f"{base}/site/stub-site/",
                "status": "pending",
                "isLive": False,
                "requiresFinalize": True,
                "anonymous": True,
                "claimToken": "tok",
                "claimUrl": f"{base}/c/tok",
                "expiresAt": "2026-09-04T12:00:00.000Z",
                "upload": {
                    "versionId": "v1",
                    "uploads": uploads,
                    "finalizeUrl": f"{base}/api/v1/publish/stub-site/finalize",
                    "expiresInSeconds": 3600,
                },
            })
        elif self.path.endswith("/finalize"):
            _StubHereNow.finalized.set()
            self._json(200, {
                "success": True,
                "slug": "stub-site",
                "siteUrl": f"{base}/site/stub-site/",
                "currentVersionId": "v1",
            })
        else:
            self._json(404, {"error": "no"})

    def do_PUT(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length) if length else b""
        key = self.path[len("/upload/"):]
        _StubHereNow.uploaded[key] = body
        self.send_response(200)
        self.end_headers()


@pytest.fixture()
def stub_server():
    _StubHereNow.uploaded = {}
    _StubHereNow.finalized = threading.Event()
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHereNow)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()


def test_publisher_runs_the_real_three_step_flow(tmp_path, stub_server) -> None:
    site = tmp_path / "site"
    site.mkdir()
    (site / "index.html").write_text("<h1>hi</h1>")
    (site / "style.css").write_text("body{color:red}")

    config = HereNowConfig(enabled=True, approval="ask", base_url=stub_server)
    handler = make_publish_handler(LocalEnvironment(), config, gate=lambda r: True)
    result = handler(str(site), name="My Page")

    assert result["ok"] is True, result
    assert result["url"].endswith("/site/stub-site/")
    assert result["anonymous"] is True
    assert result["expires_at"] == "2026-09-04T12:00:00.000Z"
    assert "expires 24 hours" in result["note"]
    # Both files actually reached the upload targets, byte-exact.
    assert _StubHereNow.uploaded["index.html"] == b"<h1>hi</h1>"
    assert _StubHereNow.uploaded["style.css"] == b"body{color:red}"
    assert _StubHereNow.finalized.is_set()


def test_publisher_reports_a_missing_path(tmp_path, stub_server) -> None:
    config = HereNowConfig(enabled=True, approval="auto", base_url=stub_server)
    handler = make_publish_handler(LocalEnvironment(), config, None)
    result = handler(str(tmp_path / "nope"))
    assert result["ok"] is False
    assert "does not exist" in result["error"]
