"""The Hindsight memory service: one sidecar per host process (§12).

``memory.backend = hindsight`` replaces the in-process Mem0 store with
`Hindsight <https://github.com/vectorize-io/hindsight>`_ (MIT), run as a
separate process from its own virtual environment (``agents/memory``):

    host process                          sidecar (agents/memory/.venv)
    ┌─────────────────────────────┐       ┌──────────────────────────────┐
    │ HindsightService            │ spawn │ chuk_agents_memory launcher  │
    │  ├ MemoryGateway 127.0.0.1  │──────▶│  ├ pg0 (Postgres + pgvector) │
    │  │   /v1/embeddings ──────▶ api.chuk.chat/v1/embeddings          │
    │  │   /v1/chat/completions ▶ api.chuk.chat/v1/chat/completions      │
    │  │   (both with the live account JWT, refreshed on a 401)          │
    │  └ HindsightAPI (httpx) ────┼──────▶│  └ Hindsight API 127.0.0.1   │
    └─────────────────────────────┘       └──────────────────────────────┘

Rules this module keeps:

* **Once per host, never per turn.** :func:`configure_memory_service` is called
  by the host at start; the sidecar itself starts lazily on the first memory
  use and is supervised (restart with backoff) until :func:`shutdown_memory_service`.
* **Loopback only, two secrets.** The gateway and the Hindsight API bind
  ``127.0.0.1`` on random ports, each behind its own random bearer. Sandbox
  containers run on Docker's bridge network and cannot reach host loopback.
* **The data lives at ``<state_home>/hindsight``** — never in an agent
  workspace, so no container mount can reach it.
* **One embedding space.** The database's vector column has one dimension for
  every bank, so the model, the dimension and the query prefix are stamped in
  ``<state_home>/hindsight/embedding.json``. A different configuration later
  refuses to start (memory degrades to a no-op) instead of mixing two vector
  spaces. Hindsight itself also refuses a dimension change once rows exist.
* **No local fallback.** Embeddings come from the proxy only; when the proxy or
  the account session is down, memory is a no-op and says so.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import socket
import subprocess
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx

from .memory_gateway import (
    SIDECAR_LLM_TIMEOUT,
    check_account_url,
    DEFAULT_EMBED_BASE_URL,
    DEFAULT_EMBED_DIMS,
    DEFAULT_EMBED_MODEL,
    DEFAULT_MAX_TOKENS,
    DEFAULT_MEMORY_MODEL,
    DEFAULT_RATE_PER_MINUTE,
    MemoryGateway,
)
from .web_search import DEFAULT_BASE_URL as ACCOUNT_BASE_URL

logger = logging.getLogger(__name__)

BACKENDS = ("mem0", "hindsight")
#: ``hindsight`` since the live probe passed (bead chuk_chat-381g,
#: ``tests/live_memory_hindsight.py``). ``AGENTS_MEM_BACKEND=mem0`` goes back.
DEFAULT_BACKEND = "hindsight"

#: Qwen3 embeddings are instruction-aware: queries carry an instruction,
#: documents do not. Part of the stamp — changing it changes the query space.
DEFAULT_QUERY_PREFIX = "Instruct: Given a question, retrieve memories that answer it\nQuery: "
DEFAULT_RECALL_TIMEOUT_MS = 1500
DEFAULT_RECALL_BUDGET = "low"
DEFAULT_RECALL_MAX_TOKENS = 800
DEFAULT_START_TIMEOUT = 180.0
DEFAULT_RERANK_PROVIDER = "rrf"
STAMP_NAME = "embedding.json"
#: Python logging of the sidecar (rotated by the launcher: 5 MB x 3, content
#: withheld). ``sidecar.out`` catches raw stdout/stderr (banner, crashes).
LOG_NAME = "sidecar.log"
OUT_NAME = "sidecar.out"
OUT_MAX_BYTES = 1024 * 1024
#: How often a ready sidecar is probed, and how many misses mean "degraded".
HEALTH_INTERVAL = 30.0
HEALTH_MISSES = 2
#: Above this many pending async operations in a bank, automatic turn and
#: summary retains are dropped (``memory_add`` still goes through).
RETAIN_BACKLOG_CAP = 500
#: The environment a sidecar may inherit. Everything else — above all any
#: provider key in the host's environment — stays out of it.
PASSTHROUGH_ENV = (
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "TMPDIR",
    "XDG_CACHE_HOME",
    "UV_CACHE_DIR",
    "UV_PYTHON_INSTALL_DIR",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
)
#: ``agents/runtime/src/chuk_agents_runtime`` -> ``agents/memory``.
DEFAULT_SIDECAR_PROJECT = Path(__file__).resolve().parents[3] / "memory"


def memory_backend(environ: Mapping[str, str] | None = None) -> str:
    """``AGENTS_MEM_BACKEND``, read at call time (tests flip it per test)."""
    env = os.environ if environ is None else environ
    value = (env.get("AGENTS_MEM_BACKEND") or DEFAULT_BACKEND).strip().lower()
    return value if value in BACKENDS else DEFAULT_BACKEND


def _int(env: Mapping[str, str], name: str, default: int) -> int:
    try:
        return int(env.get(name) or default)
    except ValueError:
        return default


def _bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    raw = env.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class HindsightSettings:
    """Everything the service needs, read from the memory settings (env)."""

    state_home: Path
    dirname: str = "hindsight"
    sidecar_project: Path = DEFAULT_SIDECAR_PROJECT
    llm_model: str = DEFAULT_MEMORY_MODEL
    llm_max_tokens: int = DEFAULT_MAX_TOKENS
    embed_base_url: str = DEFAULT_EMBED_BASE_URL
    embed_model: str = DEFAULT_EMBED_MODEL
    embed_dims: int = DEFAULT_EMBED_DIMS
    embed_query_prefix: str = DEFAULT_QUERY_PREFIX
    rate_per_minute: int = DEFAULT_RATE_PER_MINUTE
    rerank_provider: str = DEFAULT_RERANK_PROVIDER
    recall_timeout: float = DEFAULT_RECALL_TIMEOUT_MS / 1000.0
    recall_budget: str = DEFAULT_RECALL_BUDGET
    recall_max_tokens: int = DEFAULT_RECALL_MAX_TOKENS
    start_timeout: float = DEFAULT_START_TIMEOUT
    import_mem0: bool = True
    embed_api_key_ref: str = ""
    account_base_url: str = ACCOUNT_BASE_URL
    mem0_collection: str = "cowork_memory"
    qdrant_dirname: str = "qdrant"

    @property
    def data_dir(self) -> Path:
        return self.state_home / self.dirname

    @property
    def stamp(self) -> dict:
        return {
            "model": self.embed_model,
            "dimensions": self.embed_dims,
            "query_prefix": self.embed_query_prefix,
        }

    @property
    def stamp_label(self) -> str:
        return f"{self.embed_model}@{self.embed_dims}"

    @classmethod
    def from_env(
        cls, state_home: str | Path, environ: Mapping[str, str] | None = None
    ) -> "HindsightSettings":
        env = os.environ if environ is None else environ
        project = env.get("AGENTS_MEM_SIDECAR_PROJECT") or ""
        budget = (env.get("AGENTS_MEM_RECALL_BUDGET") or DEFAULT_RECALL_BUDGET).strip().lower()
        prefix = env.get("AGENTS_MEM_EMBED_QUERY_PREFIX")
        return cls(
            state_home=Path(state_home).expanduser(),
            dirname=env.get("AGENTS_MEM_HINDSIGHT_DIRNAME") or "hindsight",
            sidecar_project=Path(project).expanduser() if project else DEFAULT_SIDECAR_PROJECT,
            llm_model=env.get("AGENTS_MEM_HINDSIGHT_LLM_MODEL") or DEFAULT_MEMORY_MODEL,
            llm_max_tokens=_int(env, "AGENTS_MEM_HINDSIGHT_LLM_MAX_TOKENS", DEFAULT_MAX_TOKENS),
            embed_base_url=env.get("AGENTS_MEM_EMBED_BASE_URL") or DEFAULT_EMBED_BASE_URL,
            embed_model=env.get("AGENTS_MEM_EMBED_MODEL") or DEFAULT_EMBED_MODEL,
            embed_dims=_int(env, "AGENTS_MEM_EMBED_DIMS", DEFAULT_EMBED_DIMS),
            embed_query_prefix=DEFAULT_QUERY_PREFIX if prefix is None else prefix,
            rate_per_minute=_int(env, "AGENTS_MEM_RATE_PER_MINUTE", DEFAULT_RATE_PER_MINUTE),
            rerank_provider=env.get("AGENTS_MEM_RERANK_PROVIDER") or DEFAULT_RERANK_PROVIDER,
            recall_timeout=_int(env, "AGENTS_MEM_RECALL_TIMEOUT_MS", DEFAULT_RECALL_TIMEOUT_MS)
            / 1000.0,
            recall_budget=budget if budget in ("low", "mid", "high") else DEFAULT_RECALL_BUDGET,
            recall_max_tokens=_int(env, "AGENTS_MEM_RECALL_MAX_TOKENS", DEFAULT_RECALL_MAX_TOKENS),
            start_timeout=float(
                _int(env, "AGENTS_MEM_SIDECAR_START_TIMEOUT", int(DEFAULT_START_TIMEOUT))
            ),
            import_mem0=_bool(env, "AGENTS_MEM_IMPORT_MEM0", True),
            mem0_collection=env.get("AGENTS_MEM_COLLECTION") or "cowork_memory",
            qdrant_dirname=env.get("AGENTS_MEM_QDRANT_DIRNAME") or "qdrant",
            embed_api_key_ref=(env.get("AGENTS_MEM_EMBED_API_KEY_REF") or "").strip(),
        )


# -- the HTTP client of the sidecar ------------------------------------------


class HindsightError(Exception):
    """A failed call to the sidecar (transport error or non-2xx status)."""


class HindsightAPI:
    """A small sync client for the Hindsight REST API (thread-safe: httpx).

    Deliberately not ``hindsight-client``: its sync methods run an event loop
    per thread, and it would pull aiohttp into the host environment for five
    calls.
    """

    def __init__(
        self, base_url: str, api_key: str, *, http: httpx.Client | None = None, timeout: float = 30.0
    ) -> None:
        self._base = base_url.rstrip("/")
        self._http = http or httpx.Client(timeout=timeout)
        self._owns_http = http is None
        self._headers = {"Authorization": f"Bearer {api_key}"}
        self._banks: set[str] = set()
        self._lock = threading.Lock()

    def close(self) -> None:
        if self._owns_http:
            self._http.close()

    def _call(self, method: str, path: str, *, timeout: float | None = None, **kwargs: Any) -> Any:
        try:
            response = self._http.request(
                method,
                f"{self._base}{path}",
                headers=self._headers,
                timeout=timeout if timeout is not None else httpx.USE_CLIENT_DEFAULT,
                **kwargs,
            )
        except httpx.HTTPError as exc:
            raise HindsightError(f"{method} {path}: {type(exc).__name__}") from None
        if response.status_code >= 400:
            raise HindsightError(f"{method} {path}: HTTP {response.status_code}")
        if not response.content:
            return {}
        try:
            return response.json()
        except ValueError:
            return {}

    def health(self) -> bool:
        try:
            response = self._http.get(f"{self._base}/health/ready", timeout=2.0)
        except httpx.HTTPError:
            return False
        return response.status_code == 200

    def ensure_bank(
        self, bank_id: str, *, name: str, mission: str, timeout: float | None = None
    ) -> None:
        with self._lock:
            if bank_id in self._banks:
                return
        self._call(
            "PUT",
            f"/v1/default/banks/{bank_id}",
            json={"name": name, "mission": mission},
            timeout=timeout,
        )
        with self._lock:
            self._banks.add(bank_id)

    def retain(
        self,
        bank_id: str,
        items: list[dict],
        *,
        async_: bool,
        operation_id: str | None = None,
        timeout: float | None = None,
    ) -> dict:
        body: dict[str, Any] = {"items": items, "async": bool(async_)}
        if operation_id:
            body["operation_id"] = operation_id
        return self._call(
            "POST", f"/v1/default/banks/{bank_id}/memories", json=body, timeout=timeout
        )

    def recall(
        self,
        bank_id: str,
        query: str,
        *,
        budget: str = "low",
        max_tokens: int = 800,
        types: list[str] | None = None,
        prefer_observations: bool = True,
        timeout: float | None = None,
    ) -> list[dict]:
        body: dict[str, Any] = {
            "query": query,
            "budget": budget,
            "max_tokens": int(max_tokens),
            "prefer_observations": bool(prefer_observations),
        }
        if types:
            body["types"] = types
        result = self._call(
            "POST", f"/v1/default/banks/{bank_id}/memories/recall", json=body, timeout=timeout
        )
        items = result.get("results") if isinstance(result, dict) else None
        return [item for item in items or [] if isinstance(item, dict)]

    def list_memories(self, bank_id: str, *, limit: int = 20) -> list[dict]:
        result = self._call(
            "GET",
            f"/v1/default/banks/{bank_id}/memories/list",
            params={"limit": int(limit)},
        )
        items = result.get("items") if isinstance(result, dict) else None
        return [item for item in items or [] if isinstance(item, dict)]

    def pending_operations(self, bank_id: str, *, timeout: float | None = 5.0) -> int:
        """How many async operations of the bank still wait for the worker."""
        result = self._call(
            "GET",
            f"/v1/default/banks/{bank_id}/operations",
            params={"status": "pending", "limit": 1},
            timeout=timeout,
        )
        total = result.get("total") if isinstance(result, dict) else None
        return int(total) if isinstance(total, int) else 0

    def operation(self, bank_id: str, operation_id: str) -> dict:
        return self._call("GET", f"/v1/default/banks/{bank_id}/operations/{operation_id}")


# -- the service ---------------------------------------------------------------


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def sidecar_command(project: Path) -> list[str] | None:
    """How to run the sidecar: its own venv's python when it is synced, else
    ``uv run`` (which creates the venv on first use). ``None``: no way."""
    python = project / ".venv" / "bin" / "python"
    if python.exists():
        return [str(python), "-m", "chuk_agents_memory"]
    uv = shutil.which("uv")
    if uv and (project / "pyproject.toml").exists():
        return [uv, "run", "--project", str(project), "--frozen", "--no-dev", "python", "-m", "chuk_agents_memory"]
    return None


def check_stamp(settings: HindsightSettings) -> str | None:
    """``None`` when the stored embedding space matches the settings (or
    nothing is stored yet), else a one-line reason."""
    path = settings.data_dir / STAMP_NAME
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return f"{path} is unreadable"
    want = settings.stamp
    for key in ("model", "dimensions", "query_prefix"):
        if stored.get(key) != want[key]:
            return (
                f"embedding {key} changed ({stored.get(key)!r} -> {want[key]!r}); "
                "the stored memories must be re-embedded first"
            )
    return None


def write_stamp(settings: HindsightSettings) -> None:
    path = settings.data_dir / STAMP_NAME
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    body = dict(settings.stamp, created=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    path.write_text(json.dumps(body, indent=2) + "\n", encoding="utf-8")


class HindsightService:
    """The sidecar, its gateway and its client, owned by one host process.

    States: ``stopped`` → ``starting`` → ``ready`` (→ ``starting`` again after a
    crash). Terminal: ``failed`` (no way to run the sidecar, or too many
    crashes) and ``embedding_mismatch`` (see :func:`check_stamp`). In a terminal
    state every memory call degrades to a no-op.
    """

    #: Restart budget: this many crashes inside ``RESTART_WINDOW`` seconds.
    MAX_RESTARTS = 5
    RESTART_WINDOW = 600.0
    HEALTH_INTERVAL = HEALTH_INTERVAL

    def __init__(
        self,
        settings: HindsightSettings,
        session_provider: Callable[[], Any],
        *,
        popen: Callable[..., Any] = subprocess.Popen,
        gateway_factory: Callable[..., MemoryGateway] | None = None,
        api_factory: Callable[[str, str], HindsightAPI] | None = None,
        command: list[str] | None = None,
        logger_fn: Callable[[str], None] | None = None,
    ) -> None:
        self.settings = settings
        self._session_provider = session_provider
        self._popen = popen
        self._gateway_factory = gateway_factory or MemoryGateway
        self._api_factory = api_factory or (lambda url, key: HindsightAPI(url, key))
        self._command = command
        self._log = logger_fn or (lambda message: logger.info("%s", message))
        self.state = "stopped"
        self.reason: str | None = None
        self._lock = threading.Lock()
        self._ready = threading.Event()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._process: Any = None
        self._gateway: MemoryGateway | None = None
        self._api: HindsightAPI | None = None
        self._api_key = secrets.token_urlsafe(32)
        self.port: int | None = None
        self.started_at: float | None = None
        self.ready_after: float | None = None
        self.restarts: list[float] = []
        self.degraded = False

    # -- public ----------------------------------------------------------

    @property
    def terminal(self) -> bool:
        return self.state in ("failed", "embedding_mismatch")

    def start(self) -> None:
        """Start the supervisor thread once. Non-blocking and idempotent."""
        with self._lock:
            if self._thread is not None or self.terminal:
                return
            self._stopping.clear()
            self.state = "starting"
            self.started_at = time.monotonic()
            self._thread = threading.Thread(
                target=self._supervise, name="hindsight-supervisor", daemon=True
            )
            self._thread.start()

    def ready(self) -> bool:
        return self._ready.is_set() and self.state == "ready"

    def has_session(self) -> bool:
        try:
            session = self._session_provider()
        except Exception:  # noqa: BLE001 — a broken provider means no session
            return False
        return session is not None and bool(getattr(session, "access_token", None))

    def wait_ready(self, timeout: float) -> bool:
        """Start if needed; ``True`` once the sidecar answers. ``timeout=0``
        just checks."""
        if self.terminal:
            return False
        if not self.ready() and not self.has_session():
            # Nothing to embed or think with before the account is provisioned;
            # the first call after it starts the sidecar.
            return False
        self.start()
        if timeout <= 0:
            return self.ready()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._ready.wait(min(0.25, max(0.0, deadline - time.monotonic()))):
                return self.ready()
            if self.terminal:
                return False
        return self.ready()

    def recall_ticket(self) -> str:
        """A one-time foreground marker for the next recall query (see
        :meth:`MemoryGateway.issue_ticket`); empty when there is no gateway."""
        gateway = self._gateway
        issue = getattr(gateway, "issue_ticket", None)
        return issue() if callable(issue) else ""

    def api(self) -> HindsightAPI | None:
        return self._api if self.ready() else None

    def status(self) -> dict:
        return {
            "state": self.state,
            "reason": self.reason,
            "port": self.port,
            "pid": getattr(self._process, "pid", None),
            "ready_after_s": self.ready_after,
            "restarts": len(self.restarts),
            "degraded": self.degraded,
            "gateway": dict(self._gateway.stats) if self._gateway is not None else {},
        }

    def stop(self, timeout: float = 20.0) -> None:
        self._stopping.set()
        self._ready.clear()
        process = self._process
        if process is not None:
            _terminate(process, timeout)
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout)
        with self._lock:
            self._thread = None
            self._process = None
            if not self.terminal:
                self.state = "stopped"
        if self._api is not None:
            self._api.close()
            self._api = None
        if self._gateway is not None:
            self._gateway.stop()
            self._gateway = None

    # -- supervisor ------------------------------------------------------

    def _supervise(self) -> None:
        try:
            self._supervise_inner()
        except Exception as exc:  # noqa: BLE001 — a supervisor crash is a terminal state, not a host crash
            self._fail(f"supervisor error: {type(exc).__name__}: {exc}")

    def _fail(self, reason: str, state: str = "failed") -> None:
        self.reason = reason
        self.state = state
        self._ready.clear()
        self._log(f"[memory] hindsight disabled: {reason}")

    def _supervise_inner(self) -> None:
        mismatch = check_stamp(self.settings)
        if mismatch:
            self._fail(mismatch, state="embedding_mismatch")
            return
        if self.settings.embed_api_key_ref:
            self._fail(
                "memory.embed_api_key_ref is set, but the Hindsight backend only "
                "uses the account session: clear the setting (or use memory.backend = mem0)"
            )
            return
        account_host = urlparse(self.settings.account_base_url).hostname or ""
        try:
            check_account_url(self.settings.embed_base_url, account_host)
        except ValueError as exc:
            self._fail(f"memory.embed_base_url refused: {exc}")
            return
        command = self._command or sidecar_command(self.settings.sidecar_project)
        if not command:
            self._fail(
                f"no sidecar at {self.settings.sidecar_project} "
                "(run `uv sync` there, or install uv)"
            )
            return
        data_dir = self.settings.data_dir
        data_dir.mkdir(parents=True, exist_ok=True)
        if self._gateway is None:
            self._gateway = self._gateway_factory(
                self._session_provider,
                model_id=self.settings.llm_model,
                # One base for both routes: `/embeddings` and `/chat/completions`.
                api_base_url=self.settings.embed_base_url,
                embed_model=self.settings.embed_model,
                embed_dims=self.settings.embed_dims,
                max_tokens=self.settings.llm_max_tokens,
                rate_per_minute=self.settings.rate_per_minute,
                query_prefix=self.settings.embed_query_prefix,
                allowed_host=account_host,
            ).start()
        while not self._stopping.is_set():
            self.port = _free_port()
            if self._api is not None:
                self._api.close()
            self._api = self._api_factory(f"http://127.0.0.1:{self.port}", self._api_key)
            spawned = time.monotonic()
            self._process = self._spawn(command)
            if self._wait_healthy(self._process):
                self.ready_after = round(time.monotonic() - spawned, 2)
                write_stamp(self.settings)
                self.state = "ready"
                self._ready.set()
                self._log(
                    f"[memory] hindsight ready on 127.0.0.1:{self.port} "
                    f"in {self.ready_after}s"
                )
                self._wait_exit(self._process)
            if self._stopping.is_set():
                # `stop()` may have looked before this process existed.
                _terminate(self._process, 10.0)
                return
            self._ready.clear()
            self.state = "degraded" if self.degraded else "starting"
            code = self._process.poll() if self._process is not None else None
            _terminate(self._process, 10.0)
            now = time.monotonic()
            self.restarts = [t for t in self.restarts if now - t < self.RESTART_WINDOW] + [now]
            if len(self.restarts) > self.MAX_RESTARTS:
                self._fail(f"sidecar exited {len(self.restarts)} times (last code {code}); see {data_dir / LOG_NAME}")
                return
            delay = min(60.0, 2.0 ** len(self.restarts))
            self._log(f"[memory] hindsight sidecar exited (code {code}); restart in {delay:.0f}s")
            if self._stopping.wait(delay):
                return

    def _spawn(self, command: list[str]) -> Any:
        data_dir = self.settings.data_dir
        out_path = data_dir / OUT_NAME
        try:
            if out_path.stat().st_size > OUT_MAX_BYTES:
                out_path.replace(data_dir / (OUT_NAME + ".1"))
        except FileNotFoundError:
            pass
        argv = [
            *command,
            "--state-dir",
            str(data_dir),
            "--port",
            str(self.port),
            "--parent-pid",
            str(os.getpid()),
            "--log-file",
            str(data_dir / LOG_NAME),
        ]
        env = {key: os.environ[key] for key in PASSTHROUGH_ENV if key in os.environ}
        env.update(self.sidecar_env())
        log = open(out_path, "ab")  # noqa: SIM115 — handed to the child, closed below
        try:
            return self._popen(
                argv,
                cwd=str(data_dir),
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        finally:
            log.close()

    def sidecar_env(self) -> dict[str, str]:
        """The Hindsight configuration handed to the sidecar."""
        s = self.settings
        gateway = self._gateway
        gw_url = gateway.base_url if gateway is not None else ""
        gw_key = gateway.secret if gateway is not None else ""
        return {
            "HINDSIGHT_API_HOST": "127.0.0.1",
            "HINDSIGHT_API_LOG_LEVEL": "warning",
            "HINDSIGHT_API_TENANT_EXTENSION": (
                "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension"
            ),
            "HINDSIGHT_API_TENANT_API_KEY": self._api_key,
            "HINDSIGHT_API_MCP_ENABLED": "false",
            "HINDSIGHT_API_ENABLE_FILE_UPLOAD_API": "false",
            "HINDSIGHT_API_SKIP_LLM_VERIFICATION": "true",
            "HINDSIGHT_API_LLM_PROVIDER": "openai",
            "HINDSIGHT_API_LLM_BASE_URL": gw_url,
            "HINDSIGHT_API_LLM_API_KEY": gw_key,
            "HINDSIGHT_API_LLM_MODEL": s.llm_model,
            "HINDSIGHT_API_LLM_MAX_CONCURRENT": "2",
            # One call, one bill: the gateway spends at most its chat budget
            # (slot wait + upstream) before it answers, which is below this
            # timeout, and a failed call is retried at most once.
            "HINDSIGHT_API_LLM_MAX_RETRIES": "1",
            "HINDSIGHT_API_RETAIN_LLM_MAX_RETRIES": "1",
            "HINDSIGHT_API_CONSOLIDATION_LLM_MAX_RETRIES": "1",
            "HINDSIGHT_API_REFLECT_LLM_MAX_RETRIES": "1",
            "HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_MAX_RETRIES": "1",
            "HINDSIGHT_API_LLM_TIMEOUT": str(SIDECAR_LLM_TIMEOUT),
            "HINDSIGHT_API_EMBEDDINGS_MAX_RETRIES": "1",
            "HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS": str(s.llm_max_tokens),
            "HINDSIGHT_API_RETAIN_CHUNK_SIZE": "3000",
            "HINDSIGHT_API_EMBEDDINGS_PROVIDER": "openai",
            "HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL": gw_url,
            "HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY": gw_key,
            "HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL": s.embed_model,
            "HINDSIGHT_API_EMBEDDINGS_OPENAI_DIMENSIONS": str(s.embed_dims),
            "HINDSIGHT_API_EMBEDDINGS_QUERY_PREFIX": s.embed_query_prefix,
            "HINDSIGHT_API_EMBEDDINGS_MAX_CONCURRENT_REQUESTS": "2",
            "HINDSIGHT_API_RERANKER_PROVIDER": s.rerank_provider,
            "HINDSIGHT_API_DB_POOL_MIN_SIZE": "1",
            "HINDSIGHT_API_DB_POOL_MAX_SIZE": "10",
            # Hindsight reserves 2 worker slots for consolidation by default,
            # and only the rest is usable by retain: with max 2 slots, async
            # retains would sit `pending` forever (found by the live probe).
            # One reserved slot each, plus a shared pool of two.
            "HINDSIGHT_API_WORKER_MAX_SLOTS": "4",
            "HINDSIGHT_API_WORKER_CONSOLIDATION_RESERVED_SLOTS": "1",
            "HINDSIGHT_API_WORKER_RETAIN_RESERVED_SLOTS": "1",
            "HINDSIGHT_API_WORKER_MAX_RETRIES": "3",
            "LITELLM_LOCAL_MODEL_COST_MAP": "True",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
        }

    def _wait_healthy(self, process: Any) -> bool:
        deadline = time.monotonic() + self.settings.start_timeout
        while time.monotonic() < deadline and not self._stopping.is_set():
            if process.poll() is not None:
                return False
            api = self._api
            if api is not None and api.health():
                return True
            self._stopping.wait(0.25)
        if not self._stopping.is_set():
            self._log(
                f"[memory] hindsight did not answer within {self.settings.start_timeout:.0f}s"
            )
        return False

    def _wait_exit(self, process: Any) -> None:
        """Watch a ready sidecar: its exit, and a health probe every
        ``HEALTH_INTERVAL`` seconds. ``HEALTH_MISSES`` misses in a row mean the
        sidecar is stuck: it is marked degraded and restarted (with backoff)."""
        self.degraded = False
        misses = 0
        next_probe = time.monotonic() + self.HEALTH_INTERVAL
        while not self._stopping.is_set():
            if process.poll() is not None:
                return
            if time.monotonic() >= next_probe:
                next_probe = time.monotonic() + self.HEALTH_INTERVAL
                api = self._api
                if api is not None and api.health():
                    misses = 0
                else:
                    misses += 1
                    if misses >= HEALTH_MISSES:
                        self.degraded = True
                        self.reason = "memory degraded: the sidecar stopped answering its health check"
                        self._ready.clear()
                        self._log(f"[memory] {self.reason}; restarting it")
                        return
            self._stopping.wait(min(1.0, self.HEALTH_INTERVAL))


def _terminate(process: Any, timeout: float) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        process.terminate()
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    except Exception:  # noqa: BLE001 — stopping must finish
        pass


# -- the process-wide handle -------------------------------------------------------

_SHARED_LOCK = threading.Lock()
_SHARED: HindsightService | None = None


def configure_memory_service(
    *,
    state_home: str | Path,
    session_provider: Callable[[], Any],
    environ: Mapping[str, str] | None = None,
    logger: Callable[[str], None] | None = None,
    **kwargs: Any,
) -> HindsightService | None:
    """Create the host's service once. A no-op (``None``) unless the backend is
    ``hindsight``. Does not start the sidecar — the first memory use does."""
    global _SHARED
    if memory_backend(environ) != "hindsight":
        return None
    with _SHARED_LOCK:
        if _SHARED is None:
            settings = HindsightSettings.from_env(state_home, environ)
            _SHARED = HindsightService(settings, session_provider, logger_fn=logger, **kwargs)
        return _SHARED


def shared_memory_service() -> HindsightService | None:
    return _SHARED


def shutdown_memory_service(timeout: float = 20.0) -> None:
    """Stop the sidecar and forget the handle (host shutdown)."""
    global _SHARED
    with _SHARED_LOCK:
        service, _SHARED = _SHARED, None
    if service is not None:
        from .memory_hindsight import drain_retains

        drain_retains(timeout=min(timeout, 20.0))
        service.stop(timeout)


__all__ = [
    "BACKENDS",
    "DEFAULT_BACKEND",
    "HindsightAPI",
    "HindsightError",
    "HindsightService",
    "HindsightSettings",
    "check_stamp",
    "configure_memory_service",
    "memory_backend",
    "shared_memory_service",
    "shutdown_memory_service",
    "sidecar_command",
    "write_stamp",
]
