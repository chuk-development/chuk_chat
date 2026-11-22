"""Hosts of one account that work together (CHAT-177, phase 2).

The hub ties the parts together for one host:

- the peers the app introduced (:mod:`peers_store`, ``peers.json``),
- the sealed body of every ``peer`` relay frame (:mod:`peer_channel`),
- request and answer on top of it (:mod:`peer_rpc`),
- the shared files (:mod:`shared_files`).

It answers the app's ``host_peer_introduce`` / ``host_peer_forget`` /
``host_peer_list`` frames, serves the peer requests (``task``,
``agent_list``, ``file_get``, ``file_push``), gives a group a sender for a
member on another host, and backs the agent tools ``share_file``,
``fetch_file``, ``send_file_to_agent`` and ``ask_agent``.

Wire shapes: docs/WIRE_CONTRACT.md, "Hosts that work together".
"""

from __future__ import annotations

import base64
import collections
import json
import secrets
import threading
import time
from collections.abc import Callable
from typing import Any

from chuk_agents_crypto import AgentsFrameRejected, DeviceIdentity

from .peer_channel import PeerChannel
from .peer_rpc import PeerRpc, PeerRpcError, chunk_heartbeat
from .peers_store import PeerError, PeerRecord, PeerStore, is_uuid4, parse_introduce
from .shared_files import CHUNK_BYTES, SharedFileStore, ShareError, clean_ref, is_sha256

#: The app's frames (sealed app channel).
FRAME_INTRODUCE = "host_peer_introduce"
FRAME_FORGET = "host_peer_forget"
FRAME_LIST = "host_peer_list"
APP_FRAMES = (FRAME_INTRODUCE, FRAME_FORGET, FRAME_LIST)

#: Named in ``host_route.capabilities``: the app sends the frames above, and
#: room members with ``host_id``, only to a host that names it.
CAPABILITY = "host_peers"

#: The peer request kinds.
KIND_TASK = "task"
KIND_AGENT_LIST = "agent_list"
KIND_FILE_GET = "file_get"
KIND_FILE_PUSH = "file_push"

#: Relay and call codes that mean "that host is not there now".
OFFLINE_CODES = frozenset({"peer_unreachable", "timeout", "not_a_peer", "invalid_target"})

#: How deep a chain of ``ask_agent`` calls may go: the user's agent asks B
#: (hop 1), B asks C (hop 2); C cannot ask on.
MAX_ASK_DEPTH = 2
#: ``ask_agent`` calls one run may make (the groups' rounds cap, for one agent).
MAX_ASKS_PER_RUN = 4

#: A task on a peer: whole run at most, and the longest silence (the serving
#: host sends a heartbeat chunk every :data:`HEARTBEAT_SECONDS`).
TASK_TIMEOUT_SECONDS = 30 * 60.0
TASK_IDLE_SECONDS = 90.0
HEARTBEAT_SECONDS = 20.0
#: ``agent_list`` answers fast or not at all; a roster is kept this long.
AGENT_LIST_TIMEOUT_SECONDS = 15.0
ROSTER_TTL_SECONDS = 60.0
#: Chunks one ``file_get`` request returns (8 x 256 KiB = 2 MiB), and the
#: silence after which a fetch gives up for now (it resumes on the next call).
FILE_WINDOW_CHUNKS = 8
FILE_IDLE_SECONDS = 60.0
FILE_RETRIES = 3
#: Outbound ``peer`` frames this host sends per window. The relay allows 200
#: per user per 10 s for all hosts together, so one host keeps under half.
RATE_FRAMES = 90
RATE_WINDOW_SECONDS = 10.0
#: Longest text a task or a question carries.
MAX_TASK_CHARS = 200_000
#: Longest persona summary in ``agent_list``.
PERSONA_CHARS = 200


class FrameRate:
    """A blocking sliding-window limit on outbound frames."""

    def __init__(self, frames: int, window: float) -> None:
        self._frames = max(1, frames)
        self._window = window
        self._sent: collections.deque[float] = collections.deque()
        self._lock = threading.Lock()

    def acquire(self) -> None:
        while True:
            with self._lock:
                now = time.monotonic()
                while self._sent and now - self._sent[0] >= self._window:
                    self._sent.popleft()
                if len(self._sent) < self._frames:
                    self._sent.append(now)
                    return
                wait = self._window - (now - self._sent[0])
            time.sleep(max(0.01, wait))


class PeerHub:
    """The multi-host side of one host."""

    def __init__(
        self,
        *,
        own_host_id: str,
        identity: DeviceIdentity,
        store: PeerStore,
        shared: SharedFileStore,
        send_frame: Callable[[dict], bool],
        host_name: Callable[[], str] | str = "Computer",
        host_kind: str = "pc",
        run_task: Callable[[str, str, str], "str | None"] | None = None,
        list_agents: Callable[[], list[dict]] | None = None,
        is_own_agent: Callable[[str], bool] | None = None,
        workspace_for: Callable[[str], str] | None = None,
        room_post: Callable[[str, str, str], bool] | None = None,
        log: Callable[[str], None] | None = None,
        rate_frames: int = RATE_FRAMES,
        rate_window: float = RATE_WINDOW_SECONDS,
        workers: int = 8,
        task_idle_seconds: float = TASK_IDLE_SECONDS,
        heartbeat_seconds: float = HEARTBEAT_SECONDS,
        file_idle_seconds: float = FILE_IDLE_SECONDS,
        retry_sleep: float = 2.0,
    ) -> None:
        self.own_host_id = own_host_id
        self._identity = identity
        self.store = store
        self.shared = shared
        self._send_frame = send_frame
        self._host_name = host_name
        self._host_kind = host_kind
        self._run_task = run_task
        self._list_agents = list_agents
        self._is_own_agent = is_own_agent
        self._workspace_for = workspace_for
        self._room_post = room_post
        self._log = log or (lambda _m: None)
        self._rate = FrameRate(rate_frames, rate_window)
        self._task_idle = task_idle_seconds
        self._heartbeat = heartbeat_seconds
        self._file_idle = file_idle_seconds
        self._retry_sleep = retry_sleep
        self.channel = PeerChannel(own_host_id=own_host_id, identity=identity, records=store.get)
        self.rpc = PeerRpc(send=self._send, workers=workers, log=self._log)
        self.rpc.register(KIND_TASK, self._serve_task)
        self.rpc.register(KIND_AGENT_LIST, self._serve_agent_list)
        self.rpc.register(KIND_FILE_GET, self._serve_file_get)
        self.rpc.register(KIND_FILE_PUSH, self._serve_file_push)
        # Last thing seen of each peer: True (a valid frame came), False (the
        # relay said unreachable). Missing = not known yet.
        self._online: dict[str, bool] = {}
        # relay req_id -> peer, for the relay's error frames (bounded).
        self._req_peer: collections.OrderedDict[str, str] = collections.OrderedDict()
        self._rosters: dict[str, tuple[float, list[dict]]] = {}
        # session key -> ask depth of the run on it (a task from a peer).
        self._depths: collections.OrderedDict[str, int] = collections.OrderedDict()
        self._fetch_locks: dict[str, threading.Lock] = {}
        self._lock = threading.Lock()

    def shutdown(self) -> None:
        self.rpc.shutdown()

    # -- names ---------------------------------------------------------------

    def host_name(self) -> str:
        name = self._host_name() if callable(self._host_name) else self._host_name
        return str(name or "Computer")

    def peer_name(self, host_id: str | None) -> str:
        if not host_id or host_id == self.own_host_id:
            return self.host_name()
        record = self.store.get(host_id)
        return record.name if record is not None else "another computer"

    def is_online(self, host_id: str) -> bool | None:
        with self._lock:
            return self._online.get(host_id)

    def has_peers(self) -> bool:
        return bool(self.store.all())

    # -- relay in / out --------------------------------------------------------

    def _send(self, peer: str, message: dict) -> list[str]:
        """Seal one message to ``peer`` and hand its frames to the relay.
        Returns the relay req ids, empty when the peer is unknown or the
        relay link is down."""
        lock = self.channel.send_lock(peer)
        if lock is None:
            return []
        ids: list[str] = []
        with lock:
            try:
                bodies = self.channel.seal(peer, message)
            except KeyError:
                return []
            for body in bodies:
                self._rate.acquire()
                req_id = secrets.token_hex(8)
                with self._lock:
                    self._req_peer[req_id] = peer
                    while len(self._req_peer) > 4096:
                        self._req_peer.popitem(last=False)
                frame = {"req_id": req_id, "type": "peer", "target_device_id": peer, "body": body}
                try:
                    sent = self._send_frame(frame)
                except Exception:  # noqa: BLE001 — a dead link is "not sent"
                    sent = False
                if not sent:
                    return []
                ids.append(req_id)
        return ids

    def on_relay_peer(self, frame: dict) -> None:
        """A ``peer`` frame from the relay. Bad frames are dropped and logged
        without content."""
        sender = frame.get("from_device_id")
        if not is_uuid4(sender):
            self._log("[peers] dropped a peer frame without a sender id")
            return
        try:
            message = self.channel.open(sender, frame.get("body"))
        except AgentsFrameRejected as exc:
            self._log(f"[peers] dropped a frame from {sender[:8]}: {exc.rejection.value}")
            return
        except Exception as exc:  # noqa: BLE001 — never kill the reader thread
            self._log(f"[peers] dropped a frame from {sender[:8]}: {type(exc).__name__}")
            return
        with self._lock:
            self._online[sender] = True
        if message is None:
            return  # one fragment of more
        self.rpc.on_message(sender, message)

    def on_relay_error(self, frame: dict) -> bool:
        """A ``cowork_error`` for one of our ``peer`` frames. ``True`` when it
        was ours."""
        req_id = frame.get("req_id")
        code = str(frame.get("code") or "failed")[:64]
        with self._lock:
            peer = self._req_peer.pop(req_id, None) if isinstance(req_id, str) else None
            if peer is None and isinstance(frame.get("target_device_id"), str):
                target = frame["target_device_id"]
                peer = target if self.store.get(target) is not None else None
            if peer is not None and code in ("peer_unreachable", "invalid_target"):
                self._online[peer] = False
        handled = self.rpc.fail_request(req_id, code)
        if peer is not None:
            self._log(f"[peers] the relay refused a frame to {peer[:8]}: {code}")
        return handled or peer is not None

    # -- the app's frames ----------------------------------------------------

    def handle_app_frame(self, payload: dict) -> dict:
        """Answer ``host_peer_introduce`` / ``_forget`` / ``_list`` with one
        ``host_peer_list``. Only the paired app's sealed channel gets here."""
        kind = payload.get("type")
        error: str | None = None
        if kind == FRAME_INTRODUCE:
            try:
                record = parse_introduce(payload, own_host_id=self.own_host_id)
                self.store.put(record)
                self.channel.forget(record.host_id)
                with self._lock:
                    self._rosters.pop(record.host_id, None)
                self._log(f"[peers] linked with {record.host_id[:8]} ({record.kind})")
            except PeerError as exc:
                error = str(exc)
        elif kind == FRAME_FORGET:
            host_id = payload.get("peer_host_id")
            if isinstance(host_id, str) and self.store.remove(host_id):
                self.channel.forget(host_id)
                self.rpc.fail_peer(host_id, "not_a_peer", "this computer was unlinked")
                with self._lock:
                    self._online.pop(host_id, None)
                    self._rosters.pop(host_id, None)
                self._log(f"[peers] forgot {host_id[:8]}")
        answer = self.peer_list()
        answer["request"] = kind if kind in APP_FRAMES else FRAME_LIST
        answer["ok"] = error is None
        if error is not None:
            answer["error"] = error
        return answer

    def peer_list(self) -> dict:
        return {
            "type": FRAME_LIST,
            "host_id": self.own_host_id,
            "public_key": base64.b64encode(self._identity.public_key_bytes()).decode("ascii"),
            "name": self.host_name(),
            "kind": self._host_kind,
            "peers": [
                {**record.summary(), "online": self.is_online(record.host_id)}
                for record in self.store.all()
            ],
        }

    # -- serving a peer ------------------------------------------------------

    def _own_agent(self, agent_id: object) -> str:
        if not isinstance(agent_id, str) or not agent_id:
            raise PeerRpcError("bad_request", "agent_id is missing")
        if self._is_own_agent is None or not self._is_own_agent(agent_id):
            raise PeerRpcError("unknown_agent", "no such agent on this host")
        return agent_id

    def set_depth(self, session_key: str, depth: int) -> None:
        with self._lock:
            self._depths[session_key] = depth
            self._depths.move_to_end(session_key)
            while len(self._depths) > 512:
                self._depths.popitem(last=False)

    def depth_of(self, session_key: str) -> int:
        with self._lock:
            return self._depths.get(session_key, 0)

    def _serve_task(self, peer: str, args: dict, emit) -> dict:
        agent_id = self._own_agent(args.get("agent_id"))
        text = args.get("text")
        if not isinstance(text, str) or not text.strip():
            raise PeerRpcError("bad_request", "text is empty")
        depth = args.get("depth")
        depth = depth if isinstance(depth, int) and not isinstance(depth, bool) else 1
        if depth > MAX_ASK_DEPTH:
            raise PeerRpcError("loop_guard", f"more than {MAX_ASK_DEPTH} hops")
        if self._run_task is None:
            raise PeerRpcError("not_ready", "this host runs no tasks yet")
        room_id = args.get("room_id")
        if isinstance(room_id, str) and room_id:
            session_key = f"room:{room_id[:80]}"
        else:
            sender = args.get("from_agent")
            tail = sender[:80] if isinstance(sender, str) and sender else "agent"
            session_key = f"ask:{peer[:8]}:{tail}"
        self.set_depth(session_key, depth)
        stop = threading.Event()
        chunk_heartbeat(emit, stop, self._heartbeat)
        try:
            reply = self._run_task(agent_id, text[:MAX_TASK_CHARS], session_key)
        finally:
            stop.set()
        if not isinstance(reply, str) or not reply:
            raise PeerRpcError("no_reply", "the agent gave no answer")
        return {"text": reply}

    def _local_roster(self) -> list[dict]:
        if self._list_agents is None:
            return []
        try:
            rows = self._list_agents()
        except Exception:  # noqa: BLE001 — an empty roster, not a dead frame
            return []
        out = []
        for row in rows or []:
            if not isinstance(row, dict) or not isinstance(row.get("agent_id"), str):
                continue
            out.append({
                "agent_id": row["agent_id"],
                "name": str(row.get("name") or row["agent_id"])[:80],
                "persona": str(row.get("persona") or "")[:PERSONA_CHARS],
            })
        return out

    def _serve_agent_list(self, peer: str, args: dict, emit) -> dict:
        return {
            "agents": self._local_roster(),
            "host": {"host_id": self.own_host_id, "name": self.host_name(), "kind": self._host_kind},
        }

    def _serve_file_get(self, peer: str, args: dict, emit) -> dict:
        sha = args.get("sha256")
        offset = args.get("offset", 0)
        if not is_sha256(sha) or not isinstance(offset, int) or isinstance(offset, bool):
            raise PeerRpcError("bad_request", "sha256 and offset are needed")
        size = self.shared.size(sha)
        if size is None:
            raise PeerRpcError("no_such_file", "this host has not shared that file")
        if offset < 0 or offset > size:
            raise PeerRpcError("bad_request", "offset is outside the file")
        chunks = args.get("chunks", FILE_WINDOW_CHUNKS)
        chunks = min(max(chunks, 1), FILE_WINDOW_CHUNKS) if isinstance(chunks, int) else 1
        position = offset
        for _ in range(chunks):
            if position >= size:
                break
            data = self.shared.read_chunk(sha, position, CHUNK_BYTES)
            if not data:
                break
            emit({"offset": position, "data": base64.b64encode(data).decode("ascii")})
            position += len(data)
        return {"sha256": sha, "size": size, "next_offset": position, "eof": position >= size}

    def _serve_file_push(self, peer: str, args: dict, emit) -> dict:
        agent_id = self._own_agent(args.get("agent_id"))
        ref = clean_ref(args.get("ref"))
        if ref is None or ref["host_id"] != peer:
            raise PeerRpcError("bad_request", "ref must name a file of the sending host")
        stop = threading.Event()
        chunk_heartbeat(emit, stop, self._heartbeat)
        try:
            result = self.fetch_file(agent_id, ref)
        finally:
            stop.set()
        if not result.get("ok"):
            raise PeerRpcError("fetch_failed", str(result.get("error") or ""))
        return {"path": result["path"], "size": result["size"]}

    # -- calling a peer ------------------------------------------------------

    def _call(self, host_id: str, kind: str, args: dict, **kw) -> dict:
        if self.store.get(host_id) is None:
            raise PeerRpcError("not_a_peer", "that computer is not linked to this one")
        try:
            return self.rpc.call(host_id, kind, args, **kw)
        except PeerRpcError as exc:
            if exc.code in ("peer_unreachable", "timeout"):
                with self._lock:
                    self._online[host_id] = False
            raise

    def remote_task(
        self,
        host_id: str,
        agent_id: str,
        text: str,
        *,
        room_id: str | None = None,
        depth: int = 1,
        from_agent: str | None = None,
    ) -> str:
        args: dict[str, Any] = {"agent_id": agent_id, "text": text[:MAX_TASK_CHARS], "depth": depth}
        if room_id:
            args["room_id"] = room_id
        if from_agent:
            args["from_agent"] = from_agent
        result = self._call(
            host_id, KIND_TASK, args,
            timeout=TASK_TIMEOUT_SECONDS, idle_timeout=self._task_idle,
        )
        text_out = result.get("text")
        if not isinstance(text_out, str) or not text_out:
            raise PeerRpcError("no_reply", "the agent gave no answer")
        return text_out

    def remote_sender(self, host_id: str, agent_id: str, room_id: str) -> Callable[[str], "str | None"]:
        """The group seam (``RoomBinding.register``) for a member on a peer
        host. An offline host answers with one line that says so, and the
        round goes on without it."""

        def send(prompt: str) -> str | None:
            try:
                return self.remote_task(host_id, agent_id, prompt, room_id=room_id, depth=1)
            except PeerRpcError as exc:
                name = self.peer_name(host_id)
                if exc.code in OFFLINE_CODES:
                    self._log(f"[peers] group member on {host_id[:8]} not reached: {exc.code}")
                    return f"({name} is offline, no reply)"
                self._log(f"[peers] group member on {host_id[:8]} failed: {exc.code}")
                return None

        return send

    def roster(self, *, refresh: bool = False) -> list[dict]:
        """Every agent this host can reach: its own, then each peer's (cached
        :data:`ROSTER_TTL_SECONDS`). A peer that does not answer keeps its
        last roster, marked offline."""
        out = [
            {**row, "host_id": self.own_host_id, "host_name": self.host_name(), "local": True}
            for row in self._local_roster()
        ]
        for record in self.store.all():
            out.extend(self._peer_roster(record, refresh=refresh))
        return out

    def _peer_roster(self, record: PeerRecord, *, refresh: bool) -> list[dict]:
        now = time.monotonic()
        with self._lock:
            cached = self._rosters.get(record.host_id)
        rows: list[dict] | None = None
        if cached is not None and not refresh and now - cached[0] < ROSTER_TTL_SECONDS:
            rows = cached[1]
        else:
            try:
                result = self._call(
                    record.host_id, KIND_AGENT_LIST, {}, timeout=AGENT_LIST_TIMEOUT_SECONDS
                )
                rows = [
                    {
                        "agent_id": str(a["agent_id"]),
                        "name": str(a.get("name") or a["agent_id"])[:80],
                        "persona": str(a.get("persona") or "")[:PERSONA_CHARS],
                    }
                    for a in result.get("agents") or []
                    if isinstance(a, dict) and isinstance(a.get("agent_id"), str)
                ]
                with self._lock:
                    self._rosters[record.host_id] = (now, rows)
            except PeerRpcError:
                rows = cached[1] if cached is not None else []
        return [
            {**row, "host_id": record.host_id, "host_name": record.name, "local": False}
            for row in rows
        ]

    def cached_name(self, agent_id: str) -> str | None:
        """The name a peer gave one of its agents, from the cached rosters."""
        with self._lock:
            rosters = list(self._rosters.values())
        for _, rows in rosters:
            for row in rows:
                if row.get("agent_id") == agent_id:
                    return row.get("name")
        return None

    def resolve_agent(self, spec: str) -> dict:
        """One roster row for ``name``, ``name@host`` or an agent id. Raises
        :class:`ShareError` with the choices when it names none or several."""
        text = (spec or "").strip().lstrip("@")
        if not text:
            raise ShareError("name the agent")
        name, _, host = text.rpartition("@") if "@" in text else (text, "", "")
        rows = self.roster()
        if host:
            needle = host.lower()
            rows = [
                r for r in rows
                if r["host_name"].lower() == needle or r["host_id"].startswith(needle)
            ]
        exact = [r for r in rows if r["agent_id"] == name]
        if not exact:
            exact = [r for r in rows if r["name"].lower() == name.lower()]
        if len(exact) == 1:
            return exact[0]
        choices = ", ".join(f"{r['name']}@{r['host_name']}" for r in (exact or rows)[:20])
        if not exact:
            raise ShareError(f"no agent named {text!r}. Known: {choices or 'none'}")
        raise ShareError(f"{text!r} names several agents; use name@host: {choices}")

    # -- the agent tools -----------------------------------------------------

    def ask_agent(self, from_agent: str, spec: str, text: str, *, depth: int = 0) -> dict:
        if depth + 1 > MAX_ASK_DEPTH:
            return {"ok": False, "error": f"loop guard: a chain of agents may be at most {MAX_ASK_DEPTH} deep"}
        if not isinstance(text, str) or not text.strip():
            return {"ok": False, "error": "text is empty"}
        try:
            target = self.resolve_agent(spec)
        except ShareError as exc:
            return {"ok": False, "error": str(exc)}
        if target["local"] and target["agent_id"] == from_agent:
            return {"ok": False, "error": "you cannot ask yourself"}
        sender_name = self._agent_label(from_agent)
        framed = (
            f"[A question from the agent {sender_name} on {self.host_name()}. "
            "Your answer goes back to that agent.]\n\n" + text
        )
        who = f"{target['name']}@{target['host_name']}"
        if target["local"]:
            if self._run_task is None:
                return {"ok": False, "error": "this host runs no tasks yet"}
            session_key = f"ask:local:{from_agent[:80]}"
            self.set_depth(session_key, depth + 1)
            try:
                reply = self._run_task(target["agent_id"], framed, session_key)
            except Exception as exc:  # noqa: BLE001 — a tool error, not a dead run
                return {"ok": False, "agent": who, "error": type(exc).__name__}
            if not reply:
                return {"ok": False, "agent": who, "error": "no answer"}
            return {"ok": True, "agent": who, "answer": reply}
        try:
            reply = self.remote_task(
                target["host_id"], target["agent_id"], framed,
                depth=depth + 1, from_agent=from_agent,
            )
        except PeerRpcError as exc:
            if exc.code in OFFLINE_CODES:
                return {"ok": False, "agent": who, "error": f"{target['host_name']} is offline"}
            return {"ok": False, "agent": who, "error": exc.code}
        return {"ok": True, "agent": who, "answer": reply}

    def _agent_label(self, agent_id: str) -> str:
        for row in self._local_roster():
            if row["agent_id"] == agent_id:
                return row["name"]
        return agent_id[:40] or "agent"

    def _workspace(self, agent_id: str) -> str:
        if self._workspace_for is None:
            raise ShareError("this host has no workspaces")
        return self._workspace_for(agent_id)

    def share_file(self, agent_id: str, path: str, *, room_id: str | None = None) -> dict:
        try:
            ref = self.shared.put_from_workspace(
                self._workspace(agent_id), path, host_id=self.own_host_id
            )
        except ShareError as exc:
            return {"ok": False, "error": str(exc)}
        posted = False
        if room_id and self._room_post is not None:
            note = (
                f"Shared file {ref['name']} ({ref['size']} bytes). "
                f"ref: {json.dumps(ref, separators=(',', ':'))}"
            )
            try:
                posted = bool(self._room_post(room_id, agent_id, note))
            except Exception:  # noqa: BLE001 — the ref is still good
                posted = False
        return {"ok": True, "ref": ref, "posted_to_group": posted}

    def fetch_file(self, agent_id: str, raw_ref: object) -> dict:
        ref = clean_ref(raw_ref)
        if ref is None:
            return {"ok": False, "error": "ref must be {host_id, sha256, name, size}"}
        if ref["size"] > self.shared.max_bytes:
            return {"ok": False, "error": f"the file is over {self.shared.max_bytes} bytes"}
        try:
            workspace = self._workspace(agent_id)
            if not self.shared.has(ref["sha256"]):
                if ref["host_id"] == self.own_host_id:
                    return {"ok": False, "error": "this host has no file with that sha256"}
                self._pull(ref)
            path = self.shared.deliver(ref["sha256"], ref["name"], workspace)
        except ShareError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "path": path, "size": ref["size"], "sha256": ref["sha256"]}

    def _pull(self, ref: dict) -> None:
        """Fetch one file from its host into the shared store, from where an
        earlier fetch stopped. Raises :class:`ShareError`."""
        sha, size, host_id = ref["sha256"], ref["size"], ref["host_id"]
        if self.store.get(host_id) is None:
            raise ShareError("the file is on a computer that is not linked to this one")
        with self._lock:
            lock = self._fetch_locks.setdefault(sha, threading.Lock())
        with lock:
            if self.shared.has(sha):
                return
            if self.shared.partial_size(sha) > size:
                self.shared.drop_partial(sha)
            failures = 0
            while self.shared.partial_size(sha) < size:
                offset = self.shared.partial_size(sha)
                got: list[tuple[int, bytes]] = []

                def on_chunk(data: dict) -> None:
                    position = data.get("offset")
                    blob = data.get("data")
                    if isinstance(position, int) and isinstance(blob, str):
                        got.append((position, base64.b64decode(blob, validate=True)))

                try:
                    result = self._call(
                        host_id, KIND_FILE_GET,
                        {"sha256": sha, "offset": offset, "chunks": FILE_WINDOW_CHUNKS},
                        timeout=FILE_IDLE_SECONDS * 4, idle_timeout=self._file_idle,
                        on_chunk=on_chunk,
                    )
                except PeerRpcError as exc:
                    failures += 1
                    if exc.code in ("rate_limited", "timeout", "busy") and failures <= FILE_RETRIES:
                        time.sleep(self._retry_sleep)
                        continue
                    held = self.shared.partial_size(sha)
                    if exc.code in OFFLINE_CODES:
                        raise ShareError(
                            f"{self.peer_name(host_id)} is offline; {held} of {size} bytes "
                            "are here, fetch_file again to go on"
                        ) from None
                    raise ShareError(f"fetch failed: {exc.code}") from None
                if result.get("size") != size:
                    self.shared.drop_partial(sha)
                    raise ShareError("the file on the other host has another size")
                for position, blob in sorted(got):
                    if position != self.shared.partial_size(sha):
                        break  # a gap: ask again from where the file ends
                    self.shared.append_partial(sha, position, blob)
                if self.shared.partial_size(sha) > size:
                    self.shared.drop_partial(sha)
                    raise ShareError("the other host sent more bytes than the file has")
                if not got:
                    failures += 1
                    if failures > FILE_RETRIES:
                        raise ShareError("the other host sent no data")
            self.shared.finish_partial(sha, ref["name"], size)

    def send_file_to_agent(
        self, from_agent: str, spec: str, path: str, *, room_id: str | None = None
    ) -> dict:
        shared = self.share_file(from_agent, path)
        if not shared.get("ok"):
            return shared
        ref = shared["ref"]
        try:
            target = self.resolve_agent(spec)
        except ShareError as exc:
            return {"ok": False, "ref": ref, "error": str(exc)}
        who = f"{target['name']}@{target['host_name']}"
        if target["local"]:
            try:
                where = self.shared.deliver(ref["sha256"], ref["name"], self._workspace(target["agent_id"]))
            except ShareError as exc:
                return {"ok": False, "ref": ref, "agent": who, "error": str(exc)}
            return {"ok": True, "ref": ref, "agent": who, "path": where}
        try:
            result = self._call(
                target["host_id"], KIND_FILE_PUSH,
                {"agent_id": target["agent_id"], "ref": ref, "from_agent": from_agent},
                timeout=TASK_TIMEOUT_SECONDS, idle_timeout=self._task_idle,
            )
        except PeerRpcError as exc:
            reason = f"{target['host_name']} is offline" if exc.code in OFFLINE_CODES else exc.code
            if exc.message and exc.code not in OFFLINE_CODES:
                reason = f"{exc.code}: {exc.message}"
            return {"ok": False, "ref": ref, "agent": who, "error": reason}
        return {"ok": True, "ref": ref, "agent": who, "path": result.get("path")}

    def tools_for(self, agent_id: str, session_key: str) -> "PeerTools":
        """The backend of the four agent tools for one run of ``agent_id``."""
        room_id = session_key[5:] if session_key.startswith("room:") else None
        return PeerTools(self, agent_id, room_id=room_id, depth=self.depth_of(session_key))


class PeerTools:
    """What ``chuk_agents_runtime.peer_tools`` calls, bound to one run."""

    def __init__(self, hub: PeerHub, agent_id: str, *, room_id: str | None, depth: int) -> None:
        self._hub = hub
        self._agent_id = agent_id
        self._room_id = room_id
        self._depth = depth
        self._asks = 0
        self._lock = threading.Lock()

    def share_file(self, path: str) -> dict:
        return self._hub.share_file(self._agent_id, path, room_id=self._room_id)

    def fetch_file(self, ref: object) -> dict:
        return self._hub.fetch_file(self._agent_id, ref)

    def send_file_to_agent(self, agent: str, path: str) -> dict:
        return self._hub.send_file_to_agent(self._agent_id, agent, path, room_id=self._room_id)

    def ask_agent(self, agent: str, text: str) -> dict:
        with self._lock:
            if self._asks >= MAX_ASKS_PER_RUN:
                return {"ok": False, "error": f"at most {MAX_ASKS_PER_RUN} ask_agent calls per task"}
            self._asks += 1
        return self._hub.ask_agent(self._agent_id, agent, text, depth=self._depth)
