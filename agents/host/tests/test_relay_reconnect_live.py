"""The host comes back to the cloud relay on its own (Plane CHAT-33).

These tests use real sockets, not fakes. A small relay stand-in runs as its own
process (so it can be killed or frozen with SIGSTOP), and a TCP proxy that the
test controls sits between the host and the relay. The host side is the
production code: :class:`HostParty` with ``reconnect=True`` on a real
:class:`CloudRelayTransport`.

Three ways a link dies:

- the relay process dies and comes back (a deploy, a crash);
- the path goes silent but no socket closes (laptop sleep, Wi-Fi change, a NAT
  that forgot the flow). The TCP socket never errors, so only the websocket
  keepalive ping can see it;
- the relay process hangs (SIGSTOP). The kernel still ACKs TCP, so again only
  the keepalive can see it.

The keepalive comes from ``websockets.sync.client.connect`` (ping every 20 s,
20 s for the pong). The tests use short values so that they run in seconds.
Set ``CHUK_RECONNECT_REAL_TIMINGS=1`` to run them with the production values and
see the real recovery times (about one minute per case).
"""

from __future__ import annotations

import base64
import functools
import os
import signal
import socket
import subprocess
import sys
import textwrap
import threading
import time

import pytest
from websockets.sync.client import connect as ws_connect

from chuk_agents_crypto import Pairing
from chuk_agents_host.cloud_relay import TCP_USER_TIMEOUT_SECONDS, CloudRelayTransport
from chuk_agents_host.identity import HOST_DEVICE_ID, load_or_create_identity
from chuk_agents_host.party import HostParty

REAL_TIMINGS = os.environ.get("CHUK_RECONNECT_REAL_TIMINGS") == "1"

if REAL_TIMINGS:
    # What production uses: the library defaults and the party's own backoff.
    CONNECT = ws_connect
    BACKOFF = (1.0, 2.0, 5.0, 10.0, 20.0, 30.0)
    OPEN_TIMEOUT = 15.0
    TCP_USER_TIMEOUT = TCP_USER_TIMEOUT_SECONDS
    DETECT_LIMIT = 90.0
else:
    CONNECT = functools.partial(
        ws_connect, ping_interval=0.3, ping_timeout=0.3, close_timeout=0.3
    )
    BACKOFF = (0.1, 0.2, 0.5)
    OPEN_TIMEOUT = 1.0
    TCP_USER_TIMEOUT = 1.0
    DETECT_LIMIT = 10.0


# -- the relay stand-in ------------------------------------------------------

# Speaks the executor side of the relay wire: ``auth`` -> ``auth_ok``, answers
# the app-level ``ping``, ignores the rest. The websockets server answers
# protocol pings by itself, like the real relay.
_RELAY_SOURCE = textwrap.dedent(
    """
    import asyncio, json, sys
    from websockets.asyncio.server import serve

    from websockets.exceptions import ConnectionClosed

    async def handler(ws):
        try:
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("type") == "auth":
                    await ws.send(json.dumps({"type": "auth_ok"}))
                elif msg.get("type") == "ping":
                    await ws.send(json.dumps({"type": "pong"}))
        except ConnectionClosed:
            pass

    async def main(port):
        async with serve(handler, "127.0.0.1", port, ping_interval=None):
            print("READY", flush=True)
            await asyncio.Future()

    asyncio.run(main(int(sys.argv[1])))
    """
)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class RelayProcess:
    def __init__(self, port: int) -> None:
        self.port = port
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        self.proc = subprocess.Popen(
            [sys.executable, "-c", _RELAY_SOURCE, str(self.port)],
            stdout=subprocess.PIPE,
            text=True,
        )
        line = self.proc.stdout.readline()
        assert line.strip() == "READY", f"relay stand-in did not start: {line!r}"

    def kill(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()

    def pause(self) -> None:
        self.proc.send_signal(signal.SIGSTOP)

    def resume(self) -> None:
        self.proc.send_signal(signal.SIGCONT)


# -- a proxy the test can black-hole -----------------------------------------


class BlackHoleProxy:
    """Forwards TCP to the relay. :meth:`black_hole` makes every open
    connection silent for good while its sockets stay open: no FIN, no RST,
    exactly what a sleeping laptop or a dropped NAT entry looks like to the
    host. Connections made while black-holed are silent too. :meth:`restore`
    lets new connections through again; the silent ones stay dead."""

    def __init__(self, upstream_port: int) -> None:
        self.upstream_port = upstream_port
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(16)
        self.port = self._listener.getsockname()[1]
        self._generation = 0
        self._dead_generations: set[int] = set()
        self._blackholed = False
        self._lock = threading.Lock()
        self._sockets: list[socket.socket] = []
        self._stopped = False
        self._parked = threading.Event()
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def black_hole(self) -> None:
        with self._lock:
            self._blackholed = True
            self._dead_generations.add(self._generation)

    def restore(self) -> None:
        with self._lock:
            self._blackholed = False
            self._generation += 1

    def close(self) -> None:
        self._stopped = True
        self._parked.set()
        for s in [self._listener, *self._sockets]:
            try:
                s.close()
            except OSError:
                pass

    def _accept_loop(self) -> None:
        while not self._stopped:
            try:
                client, _ = self._listener.accept()
            except OSError:
                return
            self._sockets.append(client)
            with self._lock:
                gen = self._generation
                if self._blackholed:
                    # Accepted at TCP level, then nothing ever again.
                    continue
            try:
                upstream = socket.create_connection(("127.0.0.1", self.upstream_port))
            except OSError:
                client.close()
                continue
            self._sockets.append(upstream)
            for src, dst in ((client, upstream), (upstream, client)):
                threading.Thread(
                    target=self._pump, args=(src, dst, gen), daemon=True
                ).start()

    def _pump(self, src: socket.socket, dst: socket.socket, gen: int) -> None:
        while not self._stopped:
            try:
                data = src.recv(65536)
            except OSError:
                return
            if not data:
                # Pass the close on, unless this connection is black-holed.
                with self._lock:
                    dead = gen in self._dead_generations
                if not dead:
                    try:
                        dst.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                return
            with self._lock:
                dead = gen in self._dead_generations
            if dead:
                # Stop reading for good: the kernel buffers fill up and the
                # sender's writes stall, as on a real dead path.
                self._parked.wait()
                return
            try:
                dst.sendall(data)
            except OSError:
                return


# -- the host under test -----------------------------------------------------


class Timeline:
    """Timestamps of the host log lines that matter."""

    def __init__(self) -> None:
        self.lines: list[tuple[float, str]] = []
        self._lock = threading.Lock()

    def __call__(self, line: str) -> None:
        with self._lock:
            self.lines.append((time.monotonic(), line))

    def accepted_after(self, t0: float) -> float | None:
        with self._lock:
            for ts, line in self.lines:
                if ts >= t0 and "accepted this host as an executor" in line:
                    return ts
        return None

    def down_after(self, t0: float) -> float | None:
        with self._lock:
            for ts, line in self.lines:
                if ts >= t0 and "pipe down" in line:
                    return ts
        return None

    def wait_accepted(self, t0: float, limit: float) -> float | None:
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            ts = self.accepted_after(t0)
            if ts is not None:
                return ts
            time.sleep(0.02)
        return None


def _party(tmp_path, port: int, log: Timeline) -> HostParty:
    identity = load_or_create_identity(tmp_path / "host_device.key")
    transport = CloudRelayTransport(
        device_id="00000000-0000-4000-8000-000000000001",
        base_url=f"ws://127.0.0.1:{port}",
        token_provider=lambda: "test-jwt",
        logger=log,
        open_timeout=OPEN_TIMEOUT,
        tcp_user_timeout=TCP_USER_TIMEOUT,
        connect=CONNECT,
    )
    return HostParty(
        transport=transport,
        channel_id="testchannel00",
        pairing_factory=lambda: Pairing.initiator(
            device_id=HOST_DEVICE_ID,
            device_identity=identity,
            channel_id="testchannel00",
            digits="428913",
        ),
        device_id=HOST_DEVICE_ID,
        device_identity=identity,
        key_version=1,
        build_task_server=lambda *_args: None,
        logger=log,
        reconnect=True,
        backoff_seconds=BACKOFF,
    )


@pytest.fixture
def relay():
    r = RelayProcess(_free_port())
    r.start()
    yield r
    try:
        r.resume()
    except Exception:  # noqa: BLE001
        pass
    r.kill()


def _report(name: str, **times: float | None) -> None:
    parts = ", ".join(
        f"{k}={'never' if v is None else f'{v:.2f}s'}" for k, v in times.items()
    )
    print(f"\n[CHAT-33] {name}: {parts}")


def test_the_host_redials_after_the_relay_dies_and_comes_back(tmp_path, relay):
    log = Timeline()
    party = _party(tmp_path, relay.port, log)
    party.start()
    try:
        assert log.wait_accepted(0.0, 10.0), "first connect never happened"
        relay.kill()
        t_kill = time.monotonic()
        # Down for a while: the host keeps dialling with backoff.
        time.sleep(3.0)
        relay.start()
        t_back = time.monotonic()
        ts = log.wait_accepted(t_back, DETECT_LIMIT + 35.0)
        down = log.down_after(t_kill)
        _report(
            "relay killed 3 s, restarted",
            noticed_drop=None if down is None else down - t_kill,
            back_after_restart=None if ts is None else ts - t_back,
        )
        assert down is not None and down - t_kill < 2.0, "the drop went unnoticed"
        assert ts is not None, "the host never came back after the relay restart"
    finally:
        party.stop()


def test_the_host_notices_a_silent_link_and_redials(tmp_path, relay):
    """Laptop sleep / network change: the socket stays open, nothing arrives."""
    proxy = BlackHoleProxy(relay.port)
    log = Timeline()
    party = _party(tmp_path, proxy.port, log)
    party.start()
    try:
        assert log.wait_accepted(0.0, 10.0), "first connect never happened"
        proxy.black_hole()
        t_cut = time.monotonic()
        # The network stays away for a few seconds, then comes back.
        time.sleep(2.0)
        proxy.restore()
        t_net = time.monotonic()
        ts = log.wait_accepted(t_cut, DETECT_LIMIT + 35.0)
        down = log.down_after(t_cut)
        _report(
            "silent link (black hole 2 s)",
            noticed_drop=None if down is None else down - t_cut,
            back_after_cut=None if ts is None else ts - t_cut,
            back_after_network=None if ts is None else ts - t_net,
        )
        assert down is not None, "a silent link was never noticed"
        assert ts is not None, "the host never came back after the network did"
    finally:
        party.stop()
        proxy.close()


def test_the_host_notices_a_hung_relay_and_redials(tmp_path, relay):
    """SIGSTOP: the kernel still ACKs, the relay answers nothing."""
    log = Timeline()
    party = _party(tmp_path, relay.port, log)
    party.start()
    try:
        assert log.wait_accepted(0.0, 10.0), "first connect never happened"
        relay.pause()
        t_stop = time.monotonic()
        deadline = time.monotonic() + DETECT_LIMIT
        while time.monotonic() < deadline and log.down_after(t_stop) is None:
            time.sleep(0.05)
        down = log.down_after(t_stop)
        relay.resume()
        t_cont = time.monotonic()
        ts = log.wait_accepted(t_cont, DETECT_LIMIT + 35.0)
        _report(
            "relay SIGSTOP until noticed, then SIGCONT",
            noticed_drop=None if down is None else down - t_stop,
            back_after_sigcont=None if ts is None else ts - t_cont,
        )
        assert down is not None, "a hung relay was never noticed"
        assert ts is not None, "the host never came back after SIGCONT"
    finally:
        party.stop()


def test_a_silent_link_is_noticed_while_the_host_is_sending(tmp_path, relay):
    """A run streams while the path dies. The writes fill the TCP buffers and
    block while they hold the websockets send lock, so the keepalive ping
    cannot run. Without ``TCP_USER_TIMEOUT`` this link stayed open until TCP
    gave up by itself (about 15 minutes on Linux)."""
    proxy = BlackHoleProxy(relay.port)
    log = Timeline()
    transport = CloudRelayTransport(
        device_id="00000000-0000-4000-8000-000000000001",
        base_url=f"ws://127.0.0.1:{proxy.port}",
        token_provider=lambda: "test-jwt",
        logger=log,
        open_timeout=OPEN_TIMEOUT,
        tcp_user_timeout=TCP_USER_TIMEOUT,
        connect=CONNECT,
    )
    link = transport.open()
    ended = threading.Event()

    def pump() -> None:
        for _ in link.messages():
            pass
        ended.set()

    stop_sending = threading.Event()

    def stream() -> None:
        # Random bytes: permessage-deflate would shrink a repeated character
        # to nothing, and the buffers would never fill.
        chunk = {"type": "frame", "data": base64.b64encode(os.urandom(49152)).decode()}
        while not stop_sending.is_set():
            link.send(chunk)

    threading.Thread(target=pump, daemon=True).start()
    try:
        proxy.black_hole()
        t_cut = time.monotonic()
        sender = threading.Thread(target=stream, daemon=True)
        sender.start()
        noticed = ended.wait(DETECT_LIMIT)
        elapsed = time.monotonic() - t_cut
        stop_sending.set()
        _report(
            "silent link while sending",
            noticed_drop=elapsed if noticed else None,
        )
        assert noticed, "a stalled send kept a dead link open"
    finally:
        stop_sending.set()
        proxy.close()
        link.close()
