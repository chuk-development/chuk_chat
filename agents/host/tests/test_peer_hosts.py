"""Hosts that work together (CHAT-177, phase 2).

Two in-process hosts (two :class:`PeerHub`) talk through a fake relay that
follows the live relay's ``peer`` rules (api_server docs/COWORK_RELAY.md,
"Host to host frames"): same user only, uuid4 targets, 1 MB cap, a rate
limit, and an error frame to the sender for every refusal.
"""

from __future__ import annotations

import base64
import json
import os
import queue
import stat
import threading
import time
import uuid
from pathlib import Path

import pytest
from chuk_agents_crypto import AgentsFrameRejected, AgentsFrameRejection, DeviceIdentity
from chuk_agents_manager import RoomBinding, RoomStore, RoomTranscriptStore

from chuk_agents_host import peer_channel, peer_hub
from chuk_agents_host.cloud_relay import CloudRelayLink, CloudRelayTransport
from chuk_agents_host.peer_hub import MAX_ASKS_PER_RUN, PeerHub
from chuk_agents_host.peer_rpc import PeerRpcError
from chuk_agents_host.peers_store import PeerStore
from chuk_agents_host.room_service import RoomService, dispatch_room_frame
from chuk_agents_host.shared_files import SharedFileStore

RELAY_CAP = 1_000_000


class FakeRelay:
    """The relay's ``peer`` route, delivered on its own thread like a network."""

    def __init__(self, *, rate: int = 200, window: float = 10.0) -> None:
        self.hubs: dict[str, PeerHub] = {}
        self.users: dict[str, str] = {}
        self.online: set[str] = set()
        self.rate = rate
        self.window = window
        self.sent: list[float] = []
        self.frames: list[dict] = []
        self.errors: list[dict] = []
        self.max_frame = 0
        self._queue: queue.Queue = queue.Queue()
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    def attach(self, device_id: str, hub: PeerHub, user: str = "user-1") -> None:
        self.hubs[device_id] = hub
        self.users[device_id] = user
        self.online.add(device_id)

    def sender(self, device_id: str):
        def send(frame: dict) -> bool:
            if device_id not in self.online:
                return False  # this host's own socket is down
            self._queue.put((device_id, frame))
            return True

        return send

    def _error(self, sender: str, frame: dict, code: str) -> None:
        error = {
            "type": "cowork_error",
            "code": code,
            "target_device_id": frame.get("target_device_id"),
            "req_id": frame.get("req_id"),
        }
        self.errors.append(error)
        self.hubs[sender].on_relay_error(error)

    def _pump(self) -> None:
        while True:
            sender, frame = self._queue.get()
            raw = json.dumps(frame, separators=(",", ":"))
            self.max_frame = max(self.max_frame, len(raw))
            self.frames.append(frame)
            target = frame.get("target_device_id")
            if len(raw) > RELAY_CAP:
                self._error(sender, frame, "payload_too_large")
                continue
            if not peer_hub.is_uuid4(target) or target == sender:
                self._error(sender, frame, "invalid_target")
                continue
            if "body" not in frame:
                self._error(sender, frame, "invalid_body")
                continue
            now = time.monotonic()
            self.sent = [t for t in self.sent if now - t < self.window]
            if len(self.sent) >= self.rate:
                self._error(sender, frame, "rate_limited")
                continue
            self.sent.append(now)
            if target not in self.online or self.users.get(target) != self.users.get(sender):
                self._error(sender, frame, "peer_unreachable")
                continue
            self.hubs[target].on_relay_peer(
                {"type": "peer", "from_device_id": sender, "body": frame["body"]}
            )


class Host:
    """One host's hub plus what the host gives it: agents, workspaces, a
    scripted task runner."""

    def __init__(self, root: Path, relay: FakeRelay, name: str, *, user: str = "user-1") -> None:
        self.id = str(uuid.uuid4())
        self.name = name
        self.root = root
        self.identity = DeviceIdentity.generate()
        self.agents: dict[str, str] = {}  # agent id -> name
        self.tasks: list[tuple[str, str, str]] = []
        self.answer = lambda agent_id, text, key: f"{self.agents[agent_id]} on {name} read {len(text)} chars"
        self.hub = PeerHub(
            own_host_id=self.id,
            identity=self.identity,
            store=PeerStore(root / "peers.json"),
            shared=SharedFileStore(root / "shared-files"),
            send_frame=relay.sender(self.id),
            host_name=name,
            run_task=self._run,
            list_agents=lambda: [
                {"agent_id": a, "name": n, "persona": f"I am {n}."} for a, n in self.agents.items()
            ],
            is_own_agent=lambda a: a in self.agents,
            workspace_for=self.workspace,
            log=lambda _m: None,
            task_idle_seconds=5.0,
            heartbeat_seconds=0.2,
            file_idle_seconds=3.0,
            retry_sleep=0.05,
        )
        relay.attach(self.id, self.hub, user)

    def _run(self, agent_id: str, text: str, key: str) -> str | None:
        self.tasks.append((agent_id, text, key))
        return self.answer(agent_id, text, key)

    def add_agent(self, agent_id: str, name: str) -> None:
        self.agents[agent_id] = name
        self.workspace(agent_id)

    def workspace(self, agent_id: str) -> str:
        path = self.root / "ws" / agent_id.replace(":", "_")
        path.mkdir(parents=True, exist_ok=True)
        return str(path)

    def introduce(self, other: "Host", key: bytes, **extra) -> dict:
        return self.hub.handle_app_frame({
            "type": "host_peer_introduce",
            "peer_host_id": other.id,
            "peer_public_key": base64.b64encode(other.identity.public_key_bytes()).decode(),
            "pair_key": base64.b64encode(key).decode(),
            "name": other.name,
            "kind": "cloud" if other.name.startswith("Cloud") else "pc",
            **extra,
        })


@pytest.fixture
def pair(tmp_path):
    relay = FakeRelay()
    pc = Host(tmp_path / "pc", relay, "PC")
    cloud = Host(tmp_path / "cloud", relay, "Cloud-Computer")
    key = os.urandom(32)
    assert pc.introduce(cloud, key)["ok"]
    assert cloud.introduce(pc, key)["ok"]
    pc.add_agent("local:ada", "Ada")
    cloud.add_agent("local:bob", "Bob")
    yield relay, pc, cloud
    pc.hub.shutdown()
    cloud.hub.shutdown()


# -- introduce / forget / list ------------------------------------------------


def test_introduce_stores_the_peer_0600_and_lists_it(pair):
    _, pc, cloud = pair
    answer = pc.hub.handle_app_frame({"type": "host_peer_list"})
    assert answer["type"] == "host_peer_list" and answer["ok"] is True
    assert answer["host_id"] == pc.id
    assert answer["public_key"] == base64.b64encode(pc.identity.public_key_bytes()).decode()
    assert answer["peers"] == [
        {"peer_host_id": cloud.id, "name": "Cloud-Computer", "kind": "cloud", "online": None}
    ]
    mode = stat.S_IMODE(os.stat(pc.root / "peers.json").st_mode)
    assert mode == 0o600
    # The record survives a restart (a new store reads the file).
    assert PeerStore(pc.root / "peers.json").get(cloud.id).name == "Cloud-Computer"


@pytest.mark.parametrize(
    "change, reason",
    [
        ({"peer_host_id": "not-a-uuid"}, "uuid4"),
        ({"pair_key": base64.b64encode(b"short").decode()}, "32 bytes"),
        ({"peer_public_key": "!!"}, "Ed25519"),
    ],
)
def test_a_bad_introduce_is_refused_with_a_reason(pair, change, reason):
    _, pc, cloud = pair
    answer = pc.introduce(cloud, os.urandom(32), **change)
    assert answer["ok"] is False and reason in answer["error"]


def test_a_host_is_never_its_own_peer(pair):
    _, pc, _ = pair
    answer = pc.introduce(pc, os.urandom(32))
    assert answer["ok"] is False and "own peer" in answer["error"]


def test_forget_removes_the_peer_and_its_frames_are_dropped(pair):
    relay, pc, cloud = pair
    answer = cloud.hub.handle_app_frame({"type": "host_peer_forget", "peer_host_id": pc.id})
    assert answer["ok"] and answer["peers"] == []
    # The PC still knows the cloud box, but the cloud box drops its frames:
    # the call times out instead of reaching an agent.
    with pytest.raises(PeerRpcError) as info:
        pc.hub.rpc.call(cloud.id, "agent_list", {}, timeout=1.0)
    assert info.value.code == "timeout"
    assert cloud.tasks == []


# -- the sealed body ------------------------------------------------------------


def _channels(tmp_path):
    a_id, b_id = str(uuid.uuid4()), str(uuid.uuid4())
    a_key, b_key = DeviceIdentity.generate(), DeviceIdentity.generate()
    k = os.urandom(32)
    a_store, b_store = PeerStore(tmp_path / "a.json"), PeerStore(tmp_path / "b.json")
    for store, other, ident in ((a_store, b_id, b_key), (b_store, a_id, a_key)):
        from chuk_agents_host.peers_store import parse_introduce

        store.put(parse_introduce({
            "peer_host_id": other,
            "peer_public_key": base64.b64encode(ident.public_key_bytes()).decode(),
            "pair_key": base64.b64encode(k).decode(),
        }, own_host_id="x"))
    a = peer_channel.PeerChannel(own_host_id=a_id, identity=a_key, records=a_store.get)
    b = peer_channel.PeerChannel(own_host_id=b_id, identity=b_key, records=b_store.get)
    return a, b, a_id, b_id


def test_seal_open_round_trip_and_the_relay_sees_no_plaintext(tmp_path):
    a, b, a_id, b_id = _channels(tmp_path)
    [body] = a.seal(b_id, {"t": "req", "id": "1", "kind": "task", "args": {"text": "secret plan"}})
    assert "secret plan" not in json.dumps(body)
    assert body["device_id"] == a_id
    assert b.open(a_id, body)["args"]["text"] == "secret plan"


def test_a_tampered_body_is_refused(tmp_path):
    a, b, a_id, b_id = _channels(tmp_path)
    [body] = a.seal(b_id, {"t": "req", "id": "1"})
    raw = bytearray(base64.b64decode(body["ciphertext"]))
    raw[0] ^= 1
    with pytest.raises(AgentsFrameRejected) as info:
        b.open(a_id, {**body, "ciphertext": base64.b64encode(bytes(raw)).decode()})
    assert info.value.rejection is AgentsFrameRejection.BAD_SIGNATURE


def test_a_replayed_body_is_refused_but_reordering_is_fine(tmp_path):
    a, b, a_id, b_id = _channels(tmp_path)
    first = a.seal(b_id, {"t": "chunk", "id": "1", "data": {"n": 1}})[0]
    second = a.seal(b_id, {"t": "chunk", "id": "1", "data": {"n": 2}})[0]
    assert b.open(a_id, second)["data"] == {"n": 2}
    assert b.open(a_id, first)["data"] == {"n": 1}  # late, but new
    with pytest.raises(AgentsFrameRejected) as info:
        b.open(a_id, first)
    assert info.value.rejection is AgentsFrameRejection.REPLAYED_SEQUENCE


def test_a_body_from_another_sender_or_an_unknown_peer_is_refused(tmp_path):
    a, b, a_id, b_id = _channels(tmp_path)
    [body] = a.seal(b_id, {"t": "req", "id": "1"})
    with pytest.raises(AgentsFrameRejected):
        b.open(str(uuid.uuid4()), body)  # unknown peer
    other = str(uuid.uuid4())
    with pytest.raises(AgentsFrameRejected):
        b.open(a_id, {**body, "device_id": other})  # header says another host


def test_a_large_message_is_fragmented_under_the_relay_cap(tmp_path):
    a, b, a_id, b_id = _channels(tmp_path)
    text = base64.b64encode(os.urandom(1_500_000)).decode()
    bodies = a.seal(b_id, {"t": "end", "id": "9", "ok": True, "result": {"text": text}})
    assert len(bodies) > 1
    for body in bodies:
        frame = {"req_id": "x", "type": "peer", "target_device_id": b_id, "body": body}
        assert len(json.dumps(frame, separators=(",", ":"))) < RELAY_CAP
    out = [b.open(a_id, body) for body in bodies]
    assert out[:-1] == [None] * (len(bodies) - 1)
    assert out[-1]["result"]["text"] == text


# -- the route and the relay's codes ------------------------------------------


def test_agent_list_over_the_route_marks_the_peer_online(pair):
    _, pc, cloud = pair
    roster = pc.hub.roster()
    assert {(r["name"], r["host_name"], r["local"]) for r in roster} == {
        ("Ada", "PC", True),
        ("Bob", "Cloud-Computer", False),
    }
    assert pc.hub.is_online(cloud.id) is True
    assert pc.hub.cached_name("local:bob") == "Bob"


def test_an_offline_peer_is_reported_at_once(pair):
    relay, pc, cloud = pair
    relay.online.discard(cloud.id)
    started = time.monotonic()
    with pytest.raises(PeerRpcError) as info:
        pc.hub.rpc.call(cloud.id, "agent_list", {}, timeout=10.0)
    assert info.value.code == "peer_unreachable"
    assert time.monotonic() - started < 3.0
    assert pc.hub.is_online(cloud.id) is False


def test_a_peer_of_another_account_is_unreachable(tmp_path):
    relay = FakeRelay()
    pc = Host(tmp_path / "pc", relay, "PC", user="user-1")
    stranger = Host(tmp_path / "x", relay, "X", user="user-2")
    key = os.urandom(32)
    pc.introduce(stranger, key)
    stranger.introduce(pc, key)
    with pytest.raises(PeerRpcError) as info:
        pc.hub.rpc.call(stranger.id, "agent_list", {}, timeout=5.0)
    assert info.value.code == "peer_unreachable"


def test_the_relay_rate_limit_reaches_the_caller(tmp_path):
    relay = FakeRelay(rate=1, window=60.0)
    pc = Host(tmp_path / "pc", relay, "PC")
    cloud = Host(tmp_path / "cloud", relay, "Cloud-Computer")
    key = os.urandom(32)
    pc.introduce(cloud, key)
    cloud.introduce(pc, key)
    cloud.add_agent("local:bob", "Bob")
    # The first frame (the request) passes; the answer is refused.
    with pytest.raises(PeerRpcError):
        pc.hub.rpc.call(cloud.id, "agent_list", {}, timeout=1.0)
    with pytest.raises(PeerRpcError) as info:
        pc.hub.rpc.call(cloud.id, "agent_list", {}, timeout=5.0)
    assert info.value.code == "rate_limited"
    assert any(e["code"] == "rate_limited" for e in relay.errors)


def test_an_unknown_target_never_leaves_the_host(pair):
    relay, pc, _ = pair
    with pytest.raises(PeerRpcError) as info:
        pc.hub.remote_task(str(uuid.uuid4()), "local:x", "hi")
    assert info.value.code == "not_a_peer"
    assert relay.frames == []


class _Ws:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    def send(self, raw: str) -> None:
        self.sent.append(json.loads(raw))

    def close(self) -> None:
        pass


def test_the_cloud_link_hands_peer_frames_and_refusals_to_the_hub():
    seen: list[dict] = []
    refused: list[dict] = []
    ws = _Ws()
    link = CloudRelayLink(
        ws, on_peer=seen.append, on_peer_error=lambda f: refused.append(f) or True
    )
    sender = str(uuid.uuid4())
    assert link.handle_frame({"type": "peer", "from_device_id": sender, "body": {"x": 1}}) == []
    assert seen == [{"type": "peer", "from_device_id": sender, "body": {"x": 1}}]
    link.handle_frame({"type": "cowork_error", "code": "peer_unreachable",
                       "target_device_id": sender, "req_id": "r1"})
    assert refused and refused[0]["req_id"] == "r1"
    assert link.send_control_checked({"type": "peer"}) is True
    link.close()
    assert link.send_control_checked({"type": "peer"}) is False


def test_the_transport_has_no_peer_route_before_a_connect():
    transport = CloudRelayTransport(device_id=str(uuid.uuid4()))
    assert transport.send_peer_frame({"type": "peer"}) is False


# -- a group with a member on another host --------------------------------------


def _group(pc: Host, emitted: list[dict]) -> tuple[RoomService, RoomBinding]:
    binding = RoomBinding()
    binding.register("local:ada", lambda prompt: "Ada: done on the PC")

    def members_ready(room_id, members):
        for member in members:
            if member.host_id and member.host_id != pc.id:
                binding.register(
                    member.agent_id, pc.hub.remote_sender(member.host_id, member.agent_id, room_id)
                )

    service = RoomService(
        room_store=RoomStore(":memory:"),
        binding=binding,
        emit=emitted.append,
        transcript=RoomTranscriptStore(":memory:"),
        members_ready=members_ready,
        local_host_id=pc.id,
    )
    return service, binding


def test_a_group_round_runs_a_member_on_the_peer_host(pair):
    relay, pc, cloud = pair
    emitted: list[dict] = []
    service, _ = _group(pc, emitted)
    dispatch_room_frame(service, {
        "type": "room_create", "room_id": "g1", "name": "Team",
        "members": [
            {"agent_id": "local:ada", "handle": "ada", "host_id": pc.id},
            {"agent_id": "local:bob", "handle": "bob", "host_id": cloud.id},
        ],
    })
    dispatch_room_frame(service, {"type": "room_list_request"})
    listed = emitted.pop()["rooms"][0]["members"]
    assert listed == [
        {"agent_id": "local:ada", "handle": "ada"},  # this host: no host_id
        {"agent_id": "local:bob", "handle": "bob", "host_id": cloud.id},
    ]
    dispatch_room_frame(service, {"type": "room_task", "room_id": "g1", "message": "status?"})
    turns = {e["agent_id"]: e["text"] for e in emitted if e["type"] == "room_turn"}
    assert turns["local:ada"] == "Ada: done on the PC"
    assert turns["local:bob"].startswith("Bob on Cloud-Computer read")
    assert emitted[-1]["type"] == "room_done"
    # The remote member ran in the group's own thread on its host.
    assert cloud.tasks[0][0] == "local:bob" and cloud.tasks[0][2] == "room:g1"


def test_an_offline_member_host_is_named_and_the_round_goes_on(pair):
    relay, pc, cloud = pair
    relay.online.discard(cloud.id)
    emitted: list[dict] = []
    service, _ = _group(pc, emitted)
    dispatch_room_frame(service, {
        "type": "room_create", "room_id": "g1", "name": "Team",
        "members": [
            {"agent_id": "local:bob", "handle": "bob", "host_id": cloud.id},
            {"agent_id": "local:ada", "handle": "ada"},
        ],
    })
    dispatch_room_frame(service, {"type": "room_task", "room_id": "g1", "message": "status?"})
    turns = [(e["agent_id"], e["text"]) for e in emitted if e["type"] == "room_turn"]
    assert turns == [
        ("local:bob", "(Cloud-Computer is offline, no reply)"),
        ("local:ada", "Ada: done on the PC"),
    ]
    assert emitted[-1]["type"] == "room_done"


def test_room_create_moves_a_member_to_another_host(pair):
    _, pc, cloud = pair
    service, _ = _group(pc, [])
    members = [{"agent_id": "local:bob", "handle": "bob"}]
    service.handle_room_create("g1", "Team", members)
    service.handle_room_create("g1", "Team", [{**members[0], "host_id": cloud.id}])
    room = service._rooms.get("g1")
    assert room.members[0].host_id == cloud.id
    service.handle_room_add_member("g1", "local:ada", "ada", pc.id)
    assert service._rooms.get("g1").member_by_id("local:ada").host_id is None


# -- files ---------------------------------------------------------------------


def _write(host: Host, agent_id: str, name: str, data: bytes) -> None:
    Path(host.workspace(agent_id), name).write_bytes(data)


def test_share_then_fetch_on_another_host(pair):
    _, pc, cloud = pair
    data = os.urandom(700_000)
    _write(pc, "local:ada", "report.bin", data)
    shared = pc.hub.share_file("local:ada", "report.bin")
    assert shared["ok"], shared
    ref = shared["ref"]
    assert ref == {"sha256": ref["sha256"], "name": "report.bin", "size": 700_000, "host_id": pc.id}
    got = cloud.hub.fetch_file("local:bob", json.dumps(ref))  # the text form works too
    assert got["ok"], got
    assert got["path"] == f".agents/inbox/{ref['sha256']}/report.bin"
    assert Path(cloud.workspace("local:bob"), got["path"]).read_bytes() == data
    # Cached: a second fetch moves no bytes.
    assert cloud.hub.shared.has(ref["sha256"])


def test_a_shared_file_is_posted_to_the_group(pair):
    _, pc, _ = pair
    posts: list[tuple] = []
    pc.hub._room_post = lambda room, agent, text: posts.append((room, agent, text)) or True
    _write(pc, "local:ada", "a.txt", b"hello")
    result = pc.hub.tools_for("local:ada", "room:g1").share_file("a.txt")
    assert result["posted_to_group"] is True
    room, agent, text = posts[0]
    assert (room, agent) == ("g1", "local:ada") and result["ref"]["sha256"] in text


def test_a_sha_mismatch_is_refused_and_the_partial_is_dropped(pair):
    _, pc, cloud = pair
    _write(pc, "local:ada", "x.bin", b"A" * 5000)
    ref = pc.hub.share_file("local:ada", "x.bin")["ref"]
    # The bytes on the PC no longer match the reference (same size).
    (pc.root / "shared-files" / "blobs" / ref["sha256"]).write_bytes(b"B" * 5000)
    got = cloud.hub.fetch_file("local:bob", ref)
    assert got["ok"] is False and "sha256_mismatch" in got["error"]
    assert cloud.hub.shared.partial_size(ref["sha256"]) == 0
    assert not cloud.hub.shared.has(ref["sha256"])


def test_a_broken_fetch_resumes_at_its_offset(pair, monkeypatch):
    relay, pc, cloud = pair
    monkeypatch.setattr(peer_hub, "CHUNK_BYTES", 1024)
    monkeypatch.setattr(peer_hub, "FILE_WINDOW_CHUNKS", 1)
    data = os.urandom(5 * 1024)
    _write(pc, "local:ada", "big.bin", data)
    ref = pc.hub.share_file("local:ada", "big.bin")["ref"]
    offsets: list[int] = []
    serve = pc.hub._serve_file_get

    def counting(peer, args, emit):
        offsets.append(args["offset"])
        if len(offsets) == 3:
            relay.online.discard(pc.id)  # the PC drops off mid-transfer
        return serve(peer, args, emit)

    pc.hub.rpc.register("file_get", counting)
    first = cloud.hub.fetch_file("local:bob", ref)
    assert first["ok"] is False and "offline" in first["error"]
    held = cloud.hub.shared.partial_size(ref["sha256"])
    assert 0 < held < len(data)
    relay.online.add(pc.id)
    second = cloud.hub.fetch_file("local:bob", ref)
    assert second["ok"], second
    assert Path(cloud.workspace("local:bob"), second["path"]).read_bytes() == data
    assert held in offsets[3:]  # the second fetch started where the first stopped
    assert 0 not in offsets[3:]


def test_the_size_cap_holds_on_both_sides(pair, tmp_path):
    _, pc, cloud = pair
    huge = {"host_id": pc.id, "sha256": "a" * 64, "name": "x", "size": 201 * 1024 * 1024}
    got = cloud.hub.fetch_file("local:bob", huge)
    assert got["ok"] is False and "over" in got["error"]
    small = SharedFileStore(tmp_path / "small", max_bytes=10)
    pc.hub.shared = small
    _write(pc, "local:ada", "eleven.txt", b"x" * 11)
    assert "limit" in pc.hub.share_file("local:ada", "eleven.txt")["error"]


def test_share_refuses_a_path_out_of_the_workspace(pair):
    _, pc, _ = pair
    outside = pc.root / "outside.txt"
    outside.write_text("secret")
    ws = Path(pc.workspace("local:ada"))
    os.symlink(outside, ws / "link.txt")
    for path in ("../../outside.txt", str(outside), "link.txt", "/etc/passwd"):
        result = pc.hub.share_file("local:ada", path)
        assert result["ok"] is False, path


def test_a_received_file_lands_only_in_the_inbox_and_never_through_a_symlink(pair):
    _, pc, cloud = pair
    _write(pc, "local:ada", "a.txt", b"hello")
    ref = pc.hub.share_file("local:ada", "a.txt")["ref"]
    ws = Path(cloud.workspace("local:bob"))
    elsewhere = cloud.root / "elsewhere"
    elsewhere.mkdir()
    os.symlink(elsewhere, ws / ".agents")  # planted by the agent
    got = cloud.hub.fetch_file("local:bob", {**ref, "name": "../../a.txt"})
    assert got["ok"] is False
    assert list(elsewhere.iterdir()) == []


def test_send_file_to_agent_puts_it_into_the_other_agents_inbox(pair):
    _, pc, cloud = pair
    _write(pc, "local:ada", "plan.md", b"# plan")
    result = pc.hub.send_file_to_agent("local:ada", "Bob@Cloud-Computer", "plan.md")
    assert result["ok"], result
    assert Path(cloud.workspace("local:bob"), result["path"]).read_bytes() == b"# plan"
    pc.add_agent("local:cid", "Cid")
    local = pc.hub.send_file_to_agent("local:ada", "Cid", "plan.md")
    assert local["ok"] and Path(pc.workspace("local:cid"), local["path"]).read_bytes() == b"# plan"


# -- ask_agent -------------------------------------------------------------------


def test_ask_agent_reaches_an_agent_on_the_peer_host(pair):
    _, pc, cloud = pair
    cloud.answer = lambda agent_id, text, key: "42"
    result = pc.hub.tools_for("local:ada", "local:ada").ask_agent("bob", "what is the answer?")
    assert result == {"ok": True, "agent": "Bob@Cloud-Computer", "answer": "42"}
    agent_id, text, key = cloud.tasks[0]
    assert agent_id == "local:bob" and "what is the answer?" in text and "Ada" in text
    assert key.startswith("ask:")


def test_ask_agent_names_the_choices_for_an_unknown_name(pair):
    _, pc, _ = pair
    result = pc.hub.ask_agent("local:ada", "zed", "hi")
    assert result["ok"] is False and "Bob@Cloud-Computer" in result["error"]
    assert pc.hub.ask_agent("local:ada", "ada", "hi")["error"] == "you cannot ask yourself"


def test_the_loop_guard_stops_a_third_hop(pair):
    _, pc, cloud = pair
    # Bob was asked by Ada (hop 1) and asks the PC's Ada back (hop 2): allowed.
    cloud.hub.set_depth("ask:x", 1)
    assert cloud.hub.tools_for("local:bob", "ask:x").ask_agent("ada", "and you?")["ok"]
    # Ada, now at hop 2, may not ask on.
    pc.hub.set_depth("ask:y", 2)
    refused = pc.hub.tools_for("local:ada", "ask:y").ask_agent("bob", "again?")
    assert refused["ok"] is False and "loop guard" in refused["error"]
    # A peer also refuses a task that claims a deeper chain.
    with pytest.raises(PeerRpcError) as info:
        pc.hub.remote_task(cloud.id, "local:bob", "deep", depth=3)
    assert info.value.code == "loop_guard"


def test_the_served_task_knows_its_depth(pair):
    _, pc, cloud = pair
    seen: list[int] = []
    cloud.answer = lambda agent_id, text, key: seen.append(cloud.hub.depth_of(key)) or "ok"
    pc.hub.ask_agent("local:ada", "bob", "hi", depth=1)
    assert seen == [2]


def test_one_run_may_ask_only_a_few_times(pair):
    _, pc, _ = pair
    tools = pc.hub.tools_for("local:ada", "local:ada")
    for _ in range(MAX_ASKS_PER_RUN):
        assert tools.ask_agent("bob", "hi")["ok"]
    assert "at most" in tools.ask_agent("bob", "hi")["error"]


def test_a_task_for_an_agent_the_peer_does_not_have_is_refused(pair):
    _, pc, cloud = pair
    with pytest.raises(PeerRpcError) as info:
        pc.hub.remote_task(cloud.id, "local:nobody", "hi")
    assert info.value.code == "unknown_agent"
    assert cloud.tasks == []


def test_a_long_task_stays_alive_on_heartbeats(pair):
    _, pc, cloud = pair
    pc.hub._task_idle = 1.0
    cloud.answer = lambda agent_id, text, key: time.sleep(2.5) or "slow but done"
    assert pc.hub.remote_task(cloud.id, "local:bob", "work") == "slow but done"


# -- the tools inside a real agent run ------------------------------------------


def test_a_pool_member_runs_a_peer_task_and_its_model_can_call_ask_agent(tmp_path):
    """``RoomAgentPool.run_task`` (what a peer's ``task`` runs on) drives a real
    executor run; the run carries the peer tools of that agent and session."""
    from chuk_agents_runtime import MockModelClient, tool_call_response
    from chuk_agents_sandbox import make_environment

    from chuk_agents_host.room_agents import RoomAgentPool

    asked: list[tuple] = []

    class Tools:
        def __init__(self, agent_id, key):
            self.agent_id, self.key = agent_id, key

        def share_file(self, path):
            return {"ok": True}

        def fetch_file(self, ref):
            return {"ok": True}

        def send_file_to_agent(self, agent, path):
            return {"ok": True}

        def ask_agent(self, agent, text):
            asked.append((self.agent_id, self.key, agent, text))
            return {"ok": True, "agent": "Bob@Cloud", "answer": "42"}

    clients: list[MockModelClient] = []

    def wiring(_agent_id):
        def factory():
            client = MockModelClient([
                tool_call_response(("ask_agent", {"agent": "bob", "text": "the answer?"})),
                "Bob says 42.",
            ])
            clients.append(client)
            return client

        return factory, None

    def environment(agent_id):
        workdir = tmp_path / "boxes" / agent_id.replace(":", "_")
        workdir.mkdir(parents=True, exist_ok=True)
        return make_environment("local", workdir=str(workdir))

    binding = RoomBinding()
    pool = RoomAgentPool(
        binding=binding,
        model_wiring=wiring,
        environment_factory=environment,
        db_dir=tmp_path / "room-agents",
        system_prompt="You are an agent.",
        turn_timeout=30.0,
        peer_tools_for=lambda agent_id, key: Tools(agent_id, key),
    )
    try:
        answer = pool.run_task("local:ada", "ask bob", "ask:peer:local:x")
        # The member runs, but a plain task puts it into no group's binding.
        assert pool.running_ids == frozenset({"local:ada"})
        assert binding.online_ids == frozenset()
    finally:
        pool.shutdown()
    assert answer == "Bob says 42."
    assert asked == [("local:ada", "ask:peer:local:x", "bob", "the answer?")]


# -- the host wiring --------------------------------------------------------------


def _local_host(tmp_path):
    from chuk_agents_host.host import LocalHost

    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "state"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
    )


def test_the_host_names_the_capability_and_answers_peer_frames(tmp_path):
    from chuk_agents_host.peer_hub import CAPABILITY

    host = _local_host(tmp_path)
    sent: list[dict] = []
    host._send_host_payload = lambda payload: sent.append(payload) or True
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        host._on_agent_frame({"type": "agent_list"})
        route = [p for p in sent if p["type"] == "host_route"][-1]
        assert CAPABILITY in route["capabilities"]
        answer = host._peer_hub.handle_app_frame({"type": "host_peer_list"})
        assert answer["host_id"] == host.relay_device_id
        # No peer yet: no peer tools in any run.
        assert host._peer_tools_for("local:amber:1", "local:amber:1") is None
        other = DeviceIdentity.generate()
        introduced = host._peer_hub.handle_app_frame({
            "type": "host_peer_introduce",
            "peer_host_id": str(uuid.uuid4()),
            "peer_public_key": base64.b64encode(other.public_key_bytes()).decode(),
            "pair_key": base64.b64encode(os.urandom(32)).decode(),
            "name": "Cloud-Computer",
            "kind": "cloud",
        })
        assert introduced["ok"] and len(introduced["peers"]) == 1
        assert (tmp_path / "state" / "peers.json").exists()
        tools = host._peer_tools_for("local:amber:1", "room:g1")
        assert tools is not None
        # The roster a peer gets: the host's own agent and the app's agents.
        names = {row["agent_id"]: row["name"] for row in host._peer_roster_rows()}
        assert names["local:amber:1"] == "amber"
        assert host._serves_agent("local:amber:1")
        assert not host._serves_agent("local:stranger")
    finally:
        host.stop()


def test_the_host_puts_a_remote_member_on_the_peer_route(tmp_path):
    from chuk_agents_manager import RoomMember

    host = _local_host(tmp_path)
    try:
        peer = str(uuid.uuid4())
        host._room_members_ready(
            "g1", (RoomMember("local:bob", "bob", host_id=peer),)
        )
        assert host._room_binding.is_online("local:bob")
        # The peer is not linked: the member's line says so, the round goes on.
        runner = host._room_binding.member_runner()
        reply = runner(RoomMember("local:bob", "bob", host_id=peer), "hi")
        assert reply == "(another computer is offline, no reply)"
    finally:
        host.stop()
