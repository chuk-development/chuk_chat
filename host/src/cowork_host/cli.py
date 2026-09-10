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

from .cloud_relay import DEFAULT_RELAY_BASE_URL
from .host import DEFAULT_WORKSPACE, TRANSPORT_CLOUD, TRANSPORT_LOCAL, LocalHost
from .identity import HOST_DEVICE_ID
from .pairing_store import HostPairingStore
from .pairing_uri import qr_lines
from .service import UNIT_NAME, SystemdUserService, user_unit_path

#: How long ``connect`` waits for the app before giving up, in seconds.
DEFAULT_CONNECT_TIMEOUT = 600.0

SUBCOMMANDS = ("run", "connect", "status")


def _mock_model_factory():
    """Offline/dev model: a canned 2-turn agent that runs one demo command and
    finishes. Lets the transport + pairing + sandbox path be exercised with no
    account and no credits. Not for real use."""
    # Tool calls are native (no text protocol): the first turn is a structured
    # run_command call, the second a bare-text final answer.
    from cowork_agent.model import tool_call_response

    return MockModelClient(
        [
            tool_call_response(
                (
                    "run_command",
                    {
                        "command": (
                            "echo hello from the CoWork mock agent > cowork_smoke.txt "
                            "&& echo ran"
                        )
                    },
                )
            ),
            "Ran the demo command and wrote cowork_smoke.txt (mock model, no account used).",
        ]
    )


# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    """Options shared by ``run`` and ``connect`` (both build a real host)."""
    parser.add_argument(
        "--port", type=int, default=8787, help="loopback relay TCP port (default "
        "8787; only used with --local-relay)",
    )
    parser.add_argument(
        "--local-relay",
        action="store_true",
        help="same-machine development: run the blind loopback relay on "
        "127.0.0.1 instead of dialling the cloud relay. A phone can never reach "
        "this — it is a loopback address.",
    )
    parser.add_argument(
        "--relay-url",
        default=os.environ.get("COWORK_RELAY_URL", DEFAULT_RELAY_BASE_URL),
        help=f"cloud relay base URL (default {DEFAULT_RELAY_BASE_URL}, or "
        "$COWORK_RELAY_URL). It rides in the pairing QR, so a self-hosted "
        "backend needs no rebuild.",
    )
    parser.add_argument(
        "--no-qr",
        action="store_true",
        help="print only the pairing code, no QR block",
    )
    parser.add_argument(
        "--qr-light",
        action="store_true",
        help="render the QR for a light-background terminal (default assumes a "
        "dark one; a scan fails on the wrong polarity)",
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
    parser.add_argument("--provider", default=None,
                        help="default provider slug for new autonomous sessions")
    parser.add_argument("--reasoning-effort", default=None,
                        help="default reasoning effort for new autonomous sessions")
    parser.add_argument(
        "--sandbox",
        choices=("auto", "local", "docker"),
        default=os.environ.get("COWORK_SANDBOX_KIND", "auto"),
        help="sandbox backend for the agent: auto (docker when the daemon "
        "answers, else local), local, or docker. Default auto, or "
        "$COWORK_SANDBOX_KIND",
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


def resolve_sandbox_kind(choice: str) -> str:
    """``auto`` -> the best backend this machine actually has.

    ``local`` runs the agent's commands on this machine; it has no container,
    and therefore no watchable browser (§9.1) — the Playwright MCP server lives
    inside the image. So ``auto`` takes docker whenever the daemon answers, and
    only falls back to local when it does not (bead cowork-3i5c).
    """
    if choice != "auto":
        return choice
    try:
        from cowork_sandbox import docker_available
    except Exception:  # noqa: BLE001 — a missing backend is just "local"
        return "local"
    try:
        return "docker" if docker_available() else "local"
    except Exception:  # noqa: BLE001 — a broken daemon is just "local"
        return "local"


def _build_host(args: argparse.Namespace) -> LocalHost:
    host = LocalHost(
        port=args.port,
        workspace_dir=args.workspace,
        model_id=args.model,
        provider_slug=getattr(args, "provider", None),
        reasoning_effort=getattr(args, "reasoning_effort", None),
        sandbox_kind=resolve_sandbox_kind(args.sandbox),
        agent_name=args.agent_name,
        supabase_url=args.supabase_url,
        anon_key=args.anon_key,
        force_repair=args.pair,
        # The cloud relay is the default: a phone on mobile data can reach a host
        # no other way, and the host may itself sit behind carrier NAT. The
        # loopback relay is the explicit same-machine developer opt-in.
        transport=TRANSPORT_LOCAL if getattr(args, "local_relay", False) else TRANSPORT_CLOUD,
        relay_base_url=getattr(args, "relay_url", DEFAULT_RELAY_BASE_URL),
        model_factory_override=_mock_model_factory if args.mock_model else None,
        logger=_log,
    )
    # A pairing code that expires unused is replaced by a fresh one, and the
    # replacement is printed the same way the first one was.
    qr = not getattr(args, "no_qr", False)
    qr_invert = not getattr(args, "qr_light", False)
    host.set_pairing_reset_listener(
        lambda: _on_pairing_reset(host, qr=qr, qr_invert=qr_invert)
    )
    return host


def _print_pairing_qr(host: LocalHost, *, invert: bool = True) -> bool:
    """Print the QR the phone scans. False when there is nothing to print.

    The QR is the default mobile path (there is no keyboard next to a terminal),
    but it is never the only one: the code is printed either way, so a terminal
    that renders the blocks badly, a missing library, or a broken camera all still
    leave a way to pair.
    """
    # ``getattr``: a banner must never be what stops a pairing. A host that
    # offers no URI (an older one, a test double) still prints its code below.
    uri = getattr(host, "pairing_uri", None)
    if not uri:
        return False
    lines = qr_lines(uri, invert=invert)
    if not lines:
        return False
    print("  Scan this with the CoWork app:", flush=True)
    print("", flush=True)
    for line in lines:
        print("    " + line, flush=True)
    print("", flush=True)
    return True


def _on_pairing_reset(host: LocalHost, *, qr: bool, qr_invert: bool) -> None:
    """Print the code that replaced an expired one. Same banner, one line of
    context so the user knows why the code on screen changed."""
    print("", flush=True)
    print(
        "  The previous pairing code expired unused (5 minutes). Here is a "
        "fresh one — the old code and QR are dead.",
        flush=True,
    )
    _print_banner(host, qr=qr, qr_invert=qr_invert)


def _print_banner(host: LocalHost, *, qr: bool = True, qr_invert: bool = True) -> None:
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
        if qr:
            _print_pairing_qr(host, invert=qr_invert)
        # The paste-able line, for a terminal with no camera pointed at it. The
        # QR and this link carry the same string; the code alone carries only the
        # §15 half of it.
        uri = getattr(host, "pairing_uri", None)
        if uri:
            print(f"  ...or paste this link into the app:  {uri}", flush=True)
            print("", flush=True)
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
    _print_banner(
        host,
        qr=not getattr(args, "no_qr", False),
        qr_invert=not getattr(args, "qr_light", False),
    )

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
        _print_banner(
            host,
            qr=not getattr(args, "no_qr", False),
            qr_invert=not getattr(args, "qr_light", False),
        )
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
