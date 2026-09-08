#!/usr/bin/env python3
"""Native-messaging host: the add-on's end of the line, on this machine.

Chrome (and Firefox) start this process themselves when the add-on calls
``runtime.connectNative``. The two of us then speak Chrome's native-messaging
framing on stdio: a 4-byte little-endian length, then that many bytes of UTF-8
JSON. Nothing is listening on a port, so there is nothing for anything else on
the machine to connect to; the only caller is the extension named in the host
manifest's ``allowed_origins``.

Everything that arrives from the browser is forwarded, unchanged, to the CoWork
host over a unix socket, and everything the host says goes back to the browser
the same way. This process holds no state and makes no decisions.
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import threading

DEFAULT_SOCKET = os.path.expanduser("~/.cowork/browser-bridge.sock")
MAX_FRAME = 64 * 1024 * 1024  # Chrome's own ceiling for a message from the add-on.


def read_frame(stream) -> dict | None:
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack("<I", header)
    if length > MAX_FRAME:
        raise ValueError(f"frame of {length} bytes is over the limit")
    body = stream.read(length)
    if len(body) < length:
        return None
    return json.loads(body.decode("utf-8"))


def write_frame(stream, payload: dict) -> None:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    stream.write(struct.pack("<I", len(body)))
    stream.write(body)
    stream.flush()


class HostLink:
    """The unix socket to the CoWork host, with newline-delimited JSON on it."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.sock: socket.socket | None = None
        self.lock = threading.Lock()

    def connect(self) -> bool:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(self.path)
        except OSError:
            return False
        self.sock = sock
        return True

    def send(self, payload: dict) -> None:
        if self.sock is None:
            return
        line = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        with self.lock:
            self.sock.sendall(line)

    def lines(self):
        if self.sock is None:
            return
        buffer = b""
        while True:
            chunk = self.sock.recv(65536)
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line.strip():
                    yield json.loads(line.decode("utf-8"))


def pump_host_to_browser(link: HostLink, out) -> None:
    try:
        for payload in link.lines():
            write_frame(out, payload)
    except (OSError, ValueError, json.JSONDecodeError):
        pass


def main() -> int:
    path = os.environ.get("COWORK_BRIDGE_SOCKET", DEFAULT_SOCKET)
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    link = HostLink(path)
    if not link.connect():
        # Answer once so the add-on can tell "no host here" from "host is silent",
        # then leave. The add-on retries on its own alarm.
        write_frame(stdout, {"type": "browser_attach_error", "error": f"no CoWork host at {path}"})
        return 0

    write_frame(stdout, {"type": "bridge_ready", "socket": path})
    reader = threading.Thread(target=pump_host_to_browser, args=(link, stdout), daemon=True)
    reader.start()

    while True:
        try:
            frame = read_frame(stdin)
        except (ValueError, json.JSONDecodeError) as err:
            write_frame(stdout, {"type": "browser_result", "ok": False, "error": str(err)})
            continue
        if frame is None:
            return 0
        link.send(frame)


if __name__ == "__main__":
    raise SystemExit(main())
