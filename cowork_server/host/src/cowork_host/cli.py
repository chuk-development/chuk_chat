"""``cowork-host`` console entry point.

Three subcommands, matching how the plan says a host is set up (§5: "install =
one shell script + ``connect``"):

``connect``
    The **one-time** pairing. It prints the code, waits until the app has paired,
    stores the trust, and exits. If the systemd service already holds the port it
    is stopped for the handover and started again afterwards, so the user never
    has to think about the service.

``run``
    What the systemd unit executes: bring the host up and stay up. Already
    paired hosts reconnect with no code. This is also the default when no
    subcommand is given, so the old ``cowork-host --pair`` still works.

``status``
    Read-only: is this host paired, where is its state, what is the service
    doing. Touches no port, so it is safe while the service runs.

The pairing persistence itself (``paired.json``, ``--pair`` to re-pair) lives in
:mod:`cowork_host.pairing_store` and :class:`cowork_host.host.LocalHost` and is
not duplicated here — this module only decides *when* to pair.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from cowork_agent import DEFAULT_MODEL_ID, MockModelClient

from .host import DEFAULT_WORKSPACE, LocalHost
from .identity import HOST_DEVICE_ID
from .pairing_store import HostPairingStore
from .service import UNIT_NAME, SystemdUserService, user_unit_path

#: How long ``connect`` waits for the app before giving up, in seconds.
DEFAULT_CONNECT_TIMEOUT = 600.0

SUBCOMMANDS = ("run", "connect", "status")


def _mock_model_factory():
    """Offline/dev model: a canned 2-turn agent that runs one demo command and
    finishes. Lets the transport + pairing + sandbox path be exercised with no
    account and no credits. Not for real use."""
    return MockModelClient(
        [
            '<tool_call>{"name": "run_command", "arguments": {"command": '
            '"echo hello from the CoWork mock agent > cowork_smoke.txt && echo ran"}}'
            "</tool_call>",
            "Ran the demo command and wrote cowork_smoke.txt (mock model, no account used).",
        ]
    )


# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    """Options shared by ``run`` and ``connect`` (both build a real host)."""
    parser.add_argument(
        "--port", type=int, default=8787, help="relay TCP port (default 8787)"
    )
    parser.add_argument(
        "--workspace",
        default=os.environ.get("COWORK_HOME", DEFAULT_WORKSPACE),
        help=f"host workspace directory (default {DEFAULT_WORKSPACE}, or $COWORK_HOME)",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL_ID,
        help=f"preferred model id (default {DEFAULT_MODEL_ID})",
    )
    parser.add_argument(
        "--sandbox",
        choices=("local", "docker"),
        default=os.environ.get("COWORK_SANDBOX_KIND", "local"),
        help="sandbox backend for the agent (default local, or $COWORK_SANDBOX_KIND)",
    )
    parser.add_argument(
        "--agent-name",
        default=None,
        help="use / create an agent with this name (default: reuse the first, "
        "else auto-assign one)",
    )
    parser.add_argument(
        "--supabase-url",
        default=os.environ.get("SUPABASE_URL"),
        help="Supabase project URL (or env SUPABASE_URL)",
    )
    parser.add_argument(
        "--anon-key",
        default=os.environ.get("SUPABASE_ANON_KEY"),
        help="Supabase anon key (or env SUPABASE_ANON_KEY)",
    )
    parser.add_argument(
        "--pair",
        action="store_true",
        help="forget the stored pairing and print one fresh, single-use code — "
        "the deliberate way to pair a new device (the old device stops working)",
    )
    parser.add_argument(
        "--mock-model",
        action="store_true",
        help="offline/dev: no account needed; a canned agent runs one demo "
        "command — for testing the transport + pairing without credits",
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cowork-host",
        description="Run the CoWork platform locally: a blind localhost relay, "
        "an agent, and the pairing initiator — no production relay.",
    )
    sub = parser.add_subparsers(dest="command")

    run_parser = sub.add_parser(
        "run",
        help="run the host until stopped (what the systemd service executes)",
        description="Bring the host up and stay up. This is the default command.",
    )
    _add_common_arguments(run_parser)

    connect_parser = sub.add_parser(
        "connect",
        help="pair with the app once, then let the service take over",
        description="One-time pairing. Prints the code, waits for the app, stores "
        "the trust and exits. The systemd service is stopped for the handover and "
        "started again afterwards.",
    )
    _add_common_arguments(connect_parser)
    connect_parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_CONNECT_TIMEOUT,
        help=f"seconds to wait for the app (default {DEFAULT_CONNECT_TIMEOUT:g})",
    )
    connect_parser.add_argument(
        "--no-service",
        action="store_true",
        help="do not stop/start the systemd service around pairing",
    )

    status_parser = sub.add_parser(
        "status",
        help="show pairing and service state (starts nothing)",
    )
    status_parser.add_argument(
        "--workspace",
        default=os.environ.get("COWORK_HOME", DEFAULT_WORKSPACE),
        help=f"host workspace directory (default {DEFAULT_WORKSPACE}, or $COWORK_HOME)",
    )
    return parser


def normalize_argv(argv: list[str]) -> list[str]:
    """Default to ``run`` so the pre-subcommand CLI keeps working.

    ``cowork-host``, ``cowork-host --pair`` and ``cowork-host --port 9000`` all
    mean "run"; a leading word is only taken as a subcommand when it is one.
    """
    if not argv:
        return ["run"]
    first = argv[0]
    if first in SUBCOMMANDS or first in ("-h", "--help"):
        return list(argv)
    if first.startswith("-"):
        return ["run", *argv]
    return list(argv)


def _log(message: str) -> None:
    print(f"[cowork-host] {message}", flush=True)


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------


def is_paired(workspace: str) -> bool:
    """True when this workspace already holds a pairing (``paired.json``).

    Read straight off disk: ``connect`` must answer "already paired?" *without*
    binding the port the running service holds.
    """
    store = HostPairingStore(Path(workspace).expanduser() / "paired.json")
    return store.load() is not None


def _build_host(args: argparse.Namespace) -> LocalHost:
    return LocalHost(
        port=args.port,
        workspace_dir=args.workspace,
        model_id=args.model,
        sandbox_kind=args.sandbox,
        agent_name=args.agent_name,
        supabase_url=args.supabase_url,
        anon_key=args.anon_key,
        force_repair=args.pair,
        model_factory_override=_mock_model_factory if args.mock_model else None,
        logger=_log,
    )


def _print_banner(host: LocalHost) -> None:
    print("", flush=True)
    print("  CoWork host is ready.", flush=True)
    print(f"    Relay:     {host.url}", flush=True)
    print(
        f"    Agent:     {host.agent.name}  (workspace: {host.agent.workspace_dir})",
        flush=True,
    )
    print(f"    Device:    {host.device_id}", flush=True)
    # The app-free stop (§7.1). Printed here because the moment you need it is
    # the moment the app is the thing that is not working.
    print(f"    Stop a run without the app:  touch {host.estop_path}", flush=True)
    print("", flush=True)
    code = host.pairing_code
    if host.has_stored_pairing or code is None:
        # Already paired: reconnect authenticates with the stored device keys —
        # no code exists, so there is nothing to print and nothing to replay.
        print(
            f"  Already paired. Waiting for the CoWork app to reconnect on  "
            f"{host.url}  (no code needed).",
            flush=True,
        )
        print(
            "  To pair a different device, run  cowork-host connect --pair "
            "(or delete paired.json in the workspace). That mints one fresh "
            "code and stops the current device.",
            flush=True,
        )
    else:
        print(
            f"  Open the CoWork app, Connect to  {host.url}  and enter code:  "
            f"{code}",
            flush=True,
        )
        print(
            "  This code works EXACTLY ONCE. After pairing it is destroyed and "
            "the app reconnects on its own, with no code, forever.",
            flush=True,
        )
    print("", flush=True)


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------


def cmd_run(
    args: argparse.Namespace,
    *,
    host_factory: Callable[[argparse.Namespace], LocalHost] = _build_host,
) -> int:
    host = host_factory(args)
    if args.pair:
        _log("--pair: the stored pairing was dropped; a fresh single-use code follows.")
    if args.mock_model:
        _log("MOCK MODEL mode: no account, canned agent — transport test only.")
    host.start()
    _print_banner(host)

    stop = threading.Event()
    try:
        while not stop.wait(1.0):
            pass
    except KeyboardInterrupt:
        print("", flush=True)
        _log("shutting down...")
    finally:
        host.stop()
    return 0


# --------------------------------------------------------------------------
# connect
# --------------------------------------------------------------------------


def cmd_connect(
    args: argparse.Namespace,
    *,
    host_factory: Callable[[argparse.Namespace], LocalHost] = _build_host,
    service: SystemdUserService | None = None,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> int:
    """Pair once, then hand the host back to the service.

    Idempotent on purpose: on an already-paired host it changes nothing and
    succeeds, so re-running ``connect`` (or an installer that calls it) is safe.
    Re-pairing a different device is the explicit ``--pair``.
    """
    workspace = args.workspace
    if is_paired(workspace) and not args.pair:
        print("  This host is already paired — nothing to do.", flush=True)
        print(
            "  The app reconnects on its own, with no code. To pair a DIFFERENT "
            "device (the current one stops working):",
            flush=True,
        )
        print("      cowork-host connect --pair", flush=True)
        return 0

    svc = service if service is not None else SystemdUserService()
    manage_service = not args.no_service and svc.available()
    resume_service = False
    if manage_service and svc.is_active():
        # The service holds the relay port; pairing needs it.
        _log(f"stopping {UNIT_NAME} for pairing")
        if not svc.stop():
            _log(f"could not stop {UNIT_NAME}; continuing (the port may be busy)")
        else:
            resume_service = True

    host = host_factory(args)
    if args.pair:
        _log("--pair: the stored pairing was dropped; a fresh single-use code follows.")
    paired = False
    try:
        host.start()
        _print_banner(host)
        deadline = monotonic() + max(args.timeout, 0.0)
        while monotonic() < deadline:
            if host.has_stored_pairing:
                paired = True
                break
            sleep(0.5)
    except KeyboardInterrupt:
        print("", flush=True)
        _log("pairing cancelled")
    finally:
        host.stop()

    if paired:
        print("", flush=True)
        print("  Paired. The code is dead and will never be accepted again.", flush=True)
    else:
        print("", flush=True)
        print(
            f"  Not paired: no app completed pairing within {args.timeout:g}s. "
            "Run  cowork-host connect  again.",
            flush=True,
        )

    if manage_service and (resume_service or svc.is_enabled()):
        _log(f"starting {UNIT_NAME}")
        if not svc.start():
            _log(
                f"could not start {UNIT_NAME} — start it yourself: "
                f"systemctl --user start {UNIT_NAME}"
            )
    elif paired and not manage_service:
        print(
            "  No systemd service is installed here. Keep the host running with:"
            "\n      cowork-host run",
            flush=True,
        )
    return 0 if paired else 1


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------


def cmd_status(
    args: argparse.Namespace,
    *,
    service: SystemdUserService | None = None,
    out: Callable[..., Any] = print,
) -> int:
    workspace = Path(args.workspace).expanduser()
    svc = service if service is not None else SystemdUserService()
    paired = is_paired(str(workspace))
    out("")
    out(f"  Workspace: {workspace}")
    out(f"  Device:    {HOST_DEVICE_ID}")
    out(f"  Paired:    {'yes (reconnects with no code)' if paired else 'no'}")
    out(f"  Service:   {svc.state()}  ({user_unit_path(svc.unit)})")
    estop = workspace / "ESTOP"
    out(
        f"  ESTOP:     {'ENGAGED — no new work runs' if estop.exists() else 'clear'}"
        f"  ({estop})"
    )
    if not paired:
        out("")
        out("  Pair the app once:   cowork-host connect")
    out("")
    return 0


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(normalize_argv(list(sys.argv[1:] if argv is None else argv)))
    command = getattr(args, "command", None) or "run"
    if command == "connect":
        return cmd_connect(args)
    if command == "status":
        return cmd_status(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
