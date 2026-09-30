"""The Hindsight service (§12): settings, the sidecar environment, the
embedding stamp guard, and the supervisor lifecycle — with a fake process and
a fake API, so no sidecar is ever started here."""

from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

import pytest

from chuk_agents_runtime import hindsight_service as hs
from chuk_agents_runtime.hindsight_service import (
    HindsightService,
    HindsightSettings,
    check_stamp,
    configure_memory_service,
    memory_backend,
    shared_memory_service,
    shutdown_memory_service,
    sidecar_command,
    write_stamp,
)


class Session:
    access_token = "tok"

    def refresh(self, **kwargs):
        pass


class FakeProcess:
    def __init__(self) -> None:
        self.returncode: int | None = None
        self.pid = 4242
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode


class FakeAPI:
    def __init__(self, url: str, key: str) -> None:
        self.url, self.key = url, key
        self.healthy = True
        self.closed = False

    def health(self) -> bool:
        return self.healthy

    def close(self):
        self.closed = True


class FakeGateway:
    def __init__(self, session_provider, **kwargs) -> None:
        self.kwargs = kwargs
        self.secret = "gw-secret"
        self.base_url = "http://127.0.0.1:1/v1"
        self.stats: dict = {}
        self.stopped = False

    def start(self):
        return self

    def stop(self):
        self.stopped = True

    def issue_ticket(self):
        return "\u27e6t\u27e7 "


def _settings(tmp_path: Path, **overrides) -> HindsightSettings:
    base = dict(state_home=tmp_path, start_timeout=5.0)
    base.update(overrides)
    return HindsightSettings(**base)


_DEFAULT = object()


def _service(tmp_path, *, popen=None, session=_DEFAULT, **overrides):
    if session is _DEFAULT:
        session = Session()
    spawned: list[dict] = []
    processes: list[FakeProcess] = []

    def fake_popen(argv, **kwargs):
        spawned.append({"argv": argv, **kwargs})
        process = FakeProcess()
        processes.append(process)
        return process

    service = HindsightService(
        _settings(tmp_path, **overrides),
        lambda: session,
        popen=popen or fake_popen,
        gateway_factory=FakeGateway,
        api_factory=FakeAPI,
        command=["python", "-m", "chuk_agents_memory"],
    )
    return service, spawned, processes


def test_backend_is_read_at_call_time():
    assert memory_backend({}) == hs.DEFAULT_BACKEND
    assert memory_backend({"AGENTS_MEM_BACKEND": "hindsight"}) == "hindsight"
    assert memory_backend({"AGENTS_MEM_BACKEND": "MEM0"}) == "mem0"
    assert memory_backend({"AGENTS_MEM_BACKEND": "chroma"}) == hs.DEFAULT_BACKEND


def test_settings_from_env(tmp_path):
    settings = HindsightSettings.from_env(
        tmp_path,
        {
            "AGENTS_MEM_EMBED_DIMS": "1536",
            "AGENTS_MEM_RATE_PER_MINUTE": "7",
            "AGENTS_MEM_RECALL_TIMEOUT_MS": "1500",
            "AGENTS_MEM_RECALL_BUDGET": "HIGH",
            "AGENTS_MEM_IMPORT_MEM0": "false",
            "AGENTS_MEM_SIDECAR_PROJECT": str(tmp_path / "sc"),
        },
    )
    assert settings.data_dir == tmp_path / "hindsight"
    assert settings.embed_dims == 1536 and settings.embed_model == "qwen3-embedding-8b"
    assert settings.rate_per_minute == 7
    assert settings.recall_timeout == 1.5 and settings.recall_budget == "high"
    assert settings.import_mem0 is False
    assert settings.sidecar_project == tmp_path / "sc"
    assert settings.llm_model == "deepseek/deepseek-v4-flash"
    assert settings.stamp_label == "qwen3-embedding-8b@1536"


def test_the_sidecar_env_is_loopback_rrf_pinned_and_keyless(tmp_path, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-leak")
    service, spawned, _ = _service(tmp_path)
    service.start()
    assert service.wait_ready(5)
    env = spawned[0]["env"]
    assert "OPENAI_API_KEY" not in env
    assert env["HINDSIGHT_API_HOST"] == "127.0.0.1"
    assert env["HINDSIGHT_API_RERANKER_PROVIDER"] == "rrf"
    assert env["HINDSIGHT_API_MCP_ENABLED"] == "false"
    assert env["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] == "openai"
    assert env["HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL"] == "qwen3-embedding-8b"
    assert env["HINDSIGHT_API_EMBEDDINGS_OPENAI_DIMENSIONS"] == "1024"
    assert env["HINDSIGHT_API_EMBEDDINGS_QUERY_PREFIX"].startswith("Instruct: ")
    assert env["HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL"] == "http://127.0.0.1:1/v1"
    assert env["HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY"] == "gw-secret"
    assert env["HINDSIGHT_API_LLM_API_KEY"] == "gw-secret"
    assert env["HINDSIGHT_API_LLM_MODEL"] == "deepseek/deepseek-v4-flash"
    assert env["HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS"] == "8192"
    # One call, one bill: a single retry, and a timeout above the gateway budget.
    from chuk_agents_runtime.memory_gateway import CHAT_BUDGET_SECONDS

    assert int(env["HINDSIGHT_API_LLM_TIMEOUT"]) > CHAT_BUDGET_SECONDS
    for key in ("LLM", "RETAIN_LLM", "CONSOLIDATION_LLM", "REFLECT_LLM", "EMBEDDINGS"):
        assert env[f"HINDSIGHT_API_{key}_MAX_RETRIES"] == "1"
    assert env["HINDSIGHT_API_TENANT_EXTENSION"].endswith(":ApiKeyTenantExtension")
    assert env["HINDSIGHT_API_TENANT_API_KEY"] == service._api_key  # noqa: SLF001
    assert env["LITELLM_LOCAL_MODEL_COST_MAP"] == "True"
    # Async retain must always have a worker slot (reservations < max slots).
    reserved = int(env["HINDSIGHT_API_WORKER_CONSOLIDATION_RESERVED_SLOTS"]) + int(
        env["HINDSIGHT_API_WORKER_RETAIN_RESERVED_SLOTS"]
    )
    assert int(env["HINDSIGHT_API_WORKER_RETAIN_RESERVED_SLOTS"]) >= 1
    assert int(env["HINDSIGHT_API_WORKER_MAX_SLOTS"]) > reserved
    argv = spawned[0]["argv"]
    assert argv[:3] == ["python", "-m", "chuk_agents_memory"]
    assert argv[argv.index("--state-dir") + 1] == str(tmp_path / "hindsight")
    assert spawned[0]["cwd"] == str(tmp_path / "hindsight")
    assert argv[argv.index("--log-file") + 1] == str(tmp_path / "hindsight" / "sidecar.log")
    assert service.recall_ticket() == "\u27e6t\u27e7 "
    assert spawned[0]["start_new_session"] is True
    service.stop()


def test_ready_writes_the_stamp_and_stop_terminates(tmp_path):
    service, spawned, processes = _service(tmp_path)
    assert service.wait_ready(5)
    stamp = json.loads((tmp_path / "hindsight" / "embedding.json").read_text())
    assert stamp["model"] == "qwen3-embedding-8b" and stamp["dimensions"] == 1024
    assert service.api() is not None
    assert service.status()["state"] == "ready"
    service.stop()
    assert processes[0].terminated
    assert service.state == "stopped" and service.api() is None


def test_start_is_once_per_service(tmp_path):
    service, spawned, _ = _service(tmp_path)
    for _ in range(5):
        service.start()
    assert service.wait_ready(5)
    service.start()
    assert len(spawned) == 1
    service.stop()


def test_a_mismatched_stamp_never_starts_the_sidecar(tmp_path):
    write_stamp(_settings(tmp_path, embed_dims=768))
    service, spawned, _ = _service(tmp_path)
    assert service.wait_ready(2) is False
    deadline = time.monotonic() + 2
    while service.state != "embedding_mismatch" and time.monotonic() < deadline:
        time.sleep(0.02)
    assert service.state == "embedding_mismatch" and service.terminal
    assert "dimensions" in (service.reason or "")
    assert spawned == []
    assert check_stamp(_settings(tmp_path, embed_dims=768)) is None


def test_no_session_means_no_start(tmp_path):
    service, spawned, _ = _service(tmp_path, session=None)
    assert service.wait_ready(0.5) is False
    assert spawned == [] and service.state == "stopped"


def test_a_crashed_sidecar_is_restarted(tmp_path, monkeypatch):
    monkeypatch.setattr(HindsightService, "RESTART_WINDOW", 60.0)
    service, spawned, processes = _service(tmp_path)
    assert service.wait_ready(5)
    # Make the backoff instant for the test.
    monkeypatch.setattr(service._stopping, "wait", lambda timeout=None: service._stopping.is_set())  # noqa: SLF001
    processes[0].returncode = 1  # the sidecar died
    deadline = time.monotonic() + 5
    while len(spawned) < 2 and time.monotonic() < deadline:
        time.sleep(0.02)
    assert len(spawned) == 2
    assert service.wait_ready(5)
    assert len(service.restarts) == 1
    service.stop()


def test_too_many_crashes_is_terminal(tmp_path, monkeypatch):
    monkeypatch.setattr(HindsightService, "MAX_RESTARTS", 1)

    class Dead(FakeProcess):
        def __init__(self):
            super().__init__()
            self.returncode = 3

    service = HindsightService(
        _settings(tmp_path),
        lambda: Session(),
        popen=lambda argv, **kw: Dead(),
        gateway_factory=FakeGateway,
        api_factory=FakeAPI,
        command=["x"],
    )
    monkeypatch.setattr(service._stopping, "wait", lambda timeout=None: service._stopping.is_set())  # noqa: SLF001
    service.start()
    deadline = time.monotonic() + 5
    while service.state != "failed" and time.monotonic() < deadline:
        time.sleep(0.02)
    assert service.state == "failed" and service.wait_ready(0) is False


def test_sidecar_command_prefers_the_synced_venv(tmp_path, monkeypatch):
    project = tmp_path / "memory"
    (project / ".venv" / "bin").mkdir(parents=True)
    monkeypatch.setattr(hs.shutil, "which", lambda name: "/usr/bin/uv")
    assert sidecar_command(project) is None  # no project, no venv python
    (project / "pyproject.toml").write_text("[project]\n")
    assert sidecar_command(project)[:4] == ["/usr/bin/uv", "run", "--project", str(project)]
    (project / ".venv" / "bin" / "python").write_text("")
    assert sidecar_command(project) == [
        str(project / ".venv" / "bin" / "python"), "-m", "chuk_agents_memory",
    ]


def test_no_sidecar_is_a_terminal_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(hs.shutil, "which", lambda name: None)
    service = HindsightService(
        _settings(tmp_path, sidecar_project=tmp_path / "missing"),
        lambda: Session(),
        popen=lambda *a, **k: pytest.fail("must not spawn"),
        gateway_factory=FakeGateway,
        api_factory=FakeAPI,
    )
    service.start()
    deadline = time.monotonic() + 2
    while service.state != "failed" and time.monotonic() < deadline:
        time.sleep(0.02)
    assert service.state == "failed"
    assert "no sidecar" in (service.reason or "")


def test_the_shared_service_is_configured_only_for_hindsight(tmp_path, monkeypatch):
    shutdown_memory_service()
    assert configure_memory_service(
        state_home=tmp_path, session_provider=lambda: None, environ={"AGENTS_MEM_BACKEND": "mem0"}
    ) is None
    assert shared_memory_service() is None
    first = configure_memory_service(
        state_home=tmp_path, session_provider=lambda: None, environ={"AGENTS_MEM_BACKEND": "hindsight"}
    )
    again = configure_memory_service(
        state_home=tmp_path / "other", session_provider=lambda: None,
        environ={"AGENTS_MEM_BACKEND": "hindsight"},
    )
    assert first is not None and again is first and shared_memory_service() is first
    assert first.settings.data_dir == tmp_path / "hindsight"
    shutdown_memory_service()
    assert shared_memory_service() is None


def test_real_terminate_helper_handles_a_stubborn_process():
    process = subprocess.Popen(["sleep", "30"])
    hs._terminate(process, 5)  # noqa: SLF001
    assert process.poll() is not None


def test_stop_from_another_thread_while_starting(tmp_path):
    started = threading.Event()

    class SlowAPI(FakeAPI):
        def health(self):
            started.set()
            return False

    service = HindsightService(
        _settings(tmp_path),
        lambda: Session(),
        popen=lambda argv, **kw: FakeProcess(),
        gateway_factory=FakeGateway,
        api_factory=SlowAPI,
        command=["x"],
    )
    service.start()
    assert started.wait(3)
    service.stop(timeout=3)
    assert service.state == "stopped"


def _wait_state(service, state, timeout=3.0):
    deadline = time.monotonic() + timeout
    while service.state != state and time.monotonic() < deadline:
        time.sleep(0.02)
    return service.state


def test_an_api_key_ref_stops_memory_with_a_clear_reason(tmp_path):
    service, spawned, _ = _service(tmp_path, embed_api_key_ref="my-key")
    service.start()
    assert _wait_state(service, "failed") == "failed"
    assert "embed_api_key_ref" in service.reason and spawned == []


def test_a_foreign_embedding_host_stops_memory(tmp_path):
    for url in ("https://evil.example/v1", "http://api.chuk.chat/v1"):
        service, spawned, _ = _service(tmp_path / url.split("//")[1].replace("/", "_"), embed_base_url=url)
        service.start()
        assert _wait_state(service, "failed") == "failed"
        assert "refused" in service.reason and spawned == []


def test_a_sidecar_that_stops_answering_is_degraded_and_restarted(tmp_path, monkeypatch):
    service, spawned, processes = _service(tmp_path)
    monkeypatch.setattr(service, "HEALTH_INTERVAL", 0.05)
    assert service.wait_ready(5)
    monkeypatch.setattr(service._stopping, "wait", lambda timeout=None: service._stopping.is_set() or time.sleep(min(timeout or 0, 0.05)))  # noqa: SLF001
    service._api.healthy = False  # noqa: SLF001 — the sidecar hangs
    deadline = time.monotonic() + 5
    while len(spawned) < 2 and time.monotonic() < deadline:
        time.sleep(0.02)
    assert len(spawned) == 2 and processes[0].terminated
    assert "degraded" in (service.reason or "")
    assert service.wait_ready(5) and service.status()["degraded"] is False
    service.stop()
