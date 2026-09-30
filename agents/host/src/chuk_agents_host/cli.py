"""``agents-host`` console entry point (``cowork-host`` is an alias).

Three subcommands, matching how the plan says a host is set up (§5: "install =
one shell script + ``connect``"):

``connect``
    The **one-time** pairing. It prints the code, waits until the app has paired,
    stores the trust, and exits. If the systemd service already holds the port it
    is stopped for the handover and started again afterwards, so the user never
    has to think about the service.

    ``connect --token <P>-<D>`` is the install-command path: the logged-in app
    minted the token and waits for this host. No code and no QR is shown. See
    :mod:`chuk_agents_host.install_token`.

``run``
    What the systemd unit executes: bring the host up and stay up. Already
    paired hosts reconnect with no code. This is also the default when no
    subcommand is given, so the old ``cowork-host --pair`` still works.

``status``
    Read-only: is this host paired, where is its state, what is the service
    doing. Touches no port, so it is safe while the service runs.

The pairing persistence itself (``paired.json``, ``--pair`` to re-pair) lives in
:mod:`chuk_agents_host.pairing_store` and :class:`chuk_agents_host.host.LocalHost` and is
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

from chuk_agents_config import locate_state_home, resolve_state_home
from chuk_agents_runtime import DEFAULT_MODEL_ID, MockModelClient

from .account_store import AccountStore
from .cloud_relay import DEFAULT_RELAY_BASE_URL
from .host import DEFAULT_WORKSPACE, TRANSPORT_CLOUD, TRANSPORT_LOCAL, LocalHost
from .identity import HOST_DEVICE_ID
from .install_token import InstallToken, InvalidInstallToken, parse_install_token
from .pairing_store import HostPairingStore
from .pairing_uri import qr_lines
from .service import UNIT_NAME, SystemdUserService, user_unit_path

WORKSPACE_HELP = (
    f"host state directory (default $AGENTS_HOME, else "
    f"$XDG_DATA_HOME/chuk-agents = {DEFAULT_WORKSPACE}). A legacy ~/.cowork, "
    "or host files at the top of ~/.agents, are moved there once by run/connect"
)

#: The commands that own the state and may move a legacy directory. The others
#: only read it, so they look where it is now and never move anything.
_STATE_OWNERS = ("run", "connect")

#: How long ``connect`` waits for the app before giving up, in seconds.
DEFAULT_CONNECT_TIMEOUT = 600.0

#: How long ``connect --token`` waits. The app keeps its claim open for 30
#: minutes after it mints the token, so the host waits the same time.
DEFAULT_TOKEN_CONNECT_TIMEOUT = 1800.0

#: How long ``connect`` keeps the host up after the ceremony, so the app can
#: send the account token (§15 step 7) before the host stops. The app sends it
#: at once; the bound only stops a lost frame from holding ``connect`` forever.
PROVISION_GRACE_SECONDS = 60.0

#: The environment variable ``connect`` reads the install token from. A
#: command line (``/proc/<pid>/cmdline``) is readable by every local user; the
#: environment is readable only by the same user. The bootstrap uses this.
INSTALL_TOKEN_ENV = "AGENTS_INSTALL_TOKEN"

#: Exit code for a usage error (the same code argparse uses).
EXIT_USAGE = 2

SUBCOMMANDS = ("run", "connect", "status", "doctor", "trace")


def _mock_model_factory():
    """Offline/dev model: a canned 2-turn agent that runs one demo command and
    finishes. Lets the transport + pairing + sandbox path be exercised with no
    account and no credits. Not for real use."""
    # Tool calls are native (no text protocol): the first turn is a structured
    # run_command call, the second a bare-text final answer.
    from chuk_agents_runtime.model import tool_call_response

    return MockModelClient(
        [
            tool_call_response(
                (
                    "run_command",
                    {
                        "command": (
                            "echo hello from the Agents mock agent > agents_smoke.txt "
                            "&& echo ran"
                        )
                    },
                )
            ),
            "Ran the demo command and wrote agents_smoke.txt (mock model, no account used).",
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
        default=os.environ.get("AGENTS_RELAY_URL", DEFAULT_RELAY_BASE_URL),
        help=f"cloud relay base URL (default {DEFAULT_RELAY_BASE_URL}, or "
        "$AGENTS_RELAY_URL). It rides in the pairing QR, so a self-hosted "
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
        default=None,
        help=WORKSPACE_HELP,
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
        default=os.environ.get("AGENTS_SANDBOX_KIND", "auto"),
        help="sandbox backend for the agent: auto (docker when the daemon "
        "answers, else local), local, or docker. Default auto, or "
        "$AGENTS_SANDBOX_KIND",
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
    parser.add_argument(
        "--trace",
        action="store_true",
        help="DEVELOPER SWITCH, off by default: write a JSONL run trace that "
        "says which segment of a slow turn was slow (us, the transport or the "
        "provider). Read it back with  agents-host trace --last. Same as "
        "AGENTS_TRACE=1",
    )
    parser.add_argument(
        "--trace-content",
        action="store_true",
        help="DEVELOPER SWITCH, off by default: implies --trace and ALSO traces "
        "message content, scrubbed. Structure is always safe; text is not, so "
        "this is a second, deliberate switch. Same as AGENTS_TRACE_CONTENT=1",
    )
    parser.add_argument(
        "--trace-dir",
        default=None,
        help="where the trace JSONL goes (default <workspace>/trace, or "
        "$AGENTS_TRACE_DIR). Developer switch; ignored while tracing is off",
    )
    parser.add_argument(
        "--trace-max-bytes",
        type=int,
        default=None,
        help="rolling-file cap for the trace in bytes, 3 backups beside it (or "
        "$AGENTS_TRACE_MAX_BYTES). Developer switch; ignored while tracing is off",
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agents-host",
        description="Run the Agents platform locally: a blind localhost relay, "
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
        default=None,
        help=f"seconds to wait for the app (default {DEFAULT_CONNECT_TIMEOUT:g}, "
        f"or {DEFAULT_TOKEN_CONNECT_TIMEOUT:g} with --token)",
    )
    connect_parser.add_argument(
        "--token",
        default=None,
        metavar="TOKEN",
        help="the install token from the Chuk app. It pairs this computer with "
        "the account of that app. An existing pairing is replaced. No code or "
        "QR is shown. Other local users can read a command line, so prefer "
        f"${INSTALL_TOKEN_ENV}, which only you can read. --token wins over it",
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
        default=None,
        help=WORKSPACE_HELP,
    )

    doctor_parser = sub.add_parser(
        "doctor",
        help="check that the backend can actually work (docker, image, browser)",
        description="Ask every part of the backend whether it works, instead of "
        "finding out mid-run. Starts the browser server and makes it answer.",
    )
    doctor_parser.add_argument(
        "--workspace",
        default=None,
        help=WORKSPACE_HELP,
    )
    doctor_parser.add_argument(
        "--quick",
        action="store_true",
        help="skip starting the browser server (no container, no minute of wait)",
    )

    trace_parser = sub.add_parser(
        "trace",
        help="read a run trace back: where did the four minutes go",
        description="Print the attribution of a traced run — prepare, connect, "
        "provider wait, provider stream, tools, retries — and then the phase "
        "timeline. Starts nothing and opens no port. Turn tracing on first with "
        "agents-host run --trace (or AGENTS_TRACE=1).",
    )
    trace_parser.add_argument(
        "run_id",
        nargs="?",
        default=None,
        help="the run to print; a prefix of the id is enough. Omit it for the list",
    )
    trace_parser.add_argument(
        "--list",
        dest="list_runs",
        action="store_true",
        help="list the runs in the trace, newest first (the default with no run id)",
    )
    trace_parser.add_argument(
        "--last",
        action="store_true",
        help="print the most recent run",
    )
    trace_parser.add_argument(
        "--workspace",
        default=None,
        help=WORKSPACE_HELP,
    )
    trace_parser.add_argument(
        "--trace-dir",
        default=None,
        help="read the trace from this directory or file instead of "
        "<workspace>/trace (or $AGENTS_TRACE_DIR)",
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
    print(f"[agents-host] {message}", flush=True)


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


#: The files a token re-pair replaces. They are kept aside until the new
#: pairing is stored, so a wrong or expired token does not cost the old pairing.
_TRUST_FILES = ("paired.json", "account.json")

#: Suffix of the kept-aside copies.
_BACKUP_SUFFIX = ".before-token"


def _backup_path(workspace: str, name: str) -> Path:
    return Path(workspace).expanduser() / f"{name}{_BACKUP_SUFFIX}"


def _write_private(path: Path, data: bytes) -> None:
    """Write ``data`` owner-only (0600) from the first byte, then swap it in."""
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def backup_trust(workspace: str) -> bool:
    """Copy the stored pairing and account file aside before a token re-pair.

    The host then clears the originals as for ``--pair``, so the old trust is
    not offered while the new ceremony runs. Returns True when a pairing was
    kept aside.
    """
    kept = False
    for name in _TRUST_FILES:
        source = Path(workspace).expanduser() / name
        if source.is_file():
            _write_private(_backup_path(workspace, name), source.read_bytes())
            kept = kept or name == "paired.json"
    return kept


def restore_trust(workspace: str) -> bool:
    """Put the kept-aside files back (the token re-pair did not complete).

    Returns True when a pairing was restored."""
    restored = False
    for name in _TRUST_FILES:
        backup = _backup_path(workspace, name)
        if backup.is_file():
            os.replace(backup, Path(workspace).expanduser() / name)
            restored = restored or name == "paired.json"
    return restored


def drop_trust_backup(workspace: str) -> None:
    """Delete the kept-aside files (the new pairing is stored)."""
    for name in _TRUST_FILES:
        _backup_path(workspace, name).unlink(missing_ok=True)


def recover_trust_backup(workspace: str) -> None:
    """Finish a token re-pair that a crash or a kill cut off.

    A new pairing on disk means it completed: the backup is old. No pairing
    on disk means it did not: the old pairing comes back.
    """
    if not _backup_path(workspace, "paired.json").is_file() and not _backup_path(
        workspace, "account.json"
    ).is_file():
        return
    if is_paired(workspace):
        drop_trust_backup(workspace)
    elif restore_trust(workspace):
        _log("restored the pairing that an interrupted install command kept aside")


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
        from chuk_agents_sandbox import docker_available
    except Exception:  # noqa: BLE001 — a missing backend is just "local"
        return "local"
    try:
        return "docker" if docker_available() else "local"
    except Exception:  # noqa: BLE001 — a broken daemon is just "local"
        return "local"


def _start_tracing(args: argparse.Namespace) -> None:
    """Turn the run trace on when a flag or the environment asked for it.

    Off is the default and off is silent: no file is created and nothing is
    printed, so a normal host start looks exactly as it always did. The
    ``store_true`` flags are passed as ``None`` when unset on purpose —
    :meth:`TraceSettings.from_env` drops ``None``/``False`` overrides, so
    ``AGENTS_TRACE=1`` still decides for a systemd unit that passes no flags.
    """
    from chuk_agents_runtime.trace import TraceSettings, configure_tracing

    settings = TraceSettings.from_env(
        enabled=getattr(args, "trace", False) or getattr(args, "trace_content", False) or None,
        content=getattr(args, "trace_content", False) or None,
        directory=getattr(args, "trace_dir", None),
        max_bytes=getattr(args, "trace_max_bytes", None),
    )
    tracer = configure_tracing(settings, workspace=args.workspace)
    if not getattr(tracer, "enabled", False):
        return
    path = getattr(tracer, "path", "?")
    _log(f"run trace ON -> {path}")
    _log(
        "  content tracing "
        + ("ON (messages are written, scrubbed)" if settings.content else "off (structure only)")
        + f"; read it back with  agents-host trace --last --trace-dir {Path(path).parent}"
    )


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
        install_token=getattr(args, "install_token", None),
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
    print("  Scan this with the Agents app:", flush=True)
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
    print("  Agents host is ready.", flush=True)
    print(f"    Relay:     {host.url}", flush=True)
    print(
        f"    Agent:     {host.agent.name}  (workspace: {host.agent.workspace_dir})",
        flush=True,
    )
    print(f"    Device:    {host.device_id}", flush=True)
    print(f"    Sandbox:   {host.sandbox_summary}", flush=True)
    # The app-free stop (§7.1). Printed here because the moment you need it is
    # the moment the app is the thing that is not working.
    print(f"    Stop a run without the app:  touch {host.estop_path}", flush=True)
    print("", flush=True)
    code = host.pairing_code
    if host.has_stored_pairing or code is None:
        # Already paired: reconnect authenticates with the stored device keys —
        # no code exists, so there is nothing to print and nothing to replay.
        print(
            f"  Already paired. Waiting for the Agents app to reconnect on  "
            f"{host.url}  (no code needed).",
            flush=True,
        )
        print(
            "  To pair a different device, run  agents-host connect --pair "
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
            f"  Open the Agents app, Connect to  {host.url}  and enter code:  "
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
    _start_tracing(args)
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


def stored_account_token(workspace: str) -> dict | None:
    """The account token in ``account.json``, or None. Read-only."""
    return AccountStore(Path(workspace).expanduser() / "account.json").token()


def _wait_for_provisioning(
    workspace: str,
    before: dict | None,
    *,
    sleep: Callable[[float], None],
    monotonic: Callable[[], float],
) -> bool:
    """Keep the host up after the ceremony until the app has sent the account
    token, for at most :data:`PROVISION_GRACE_SECONDS`.

    Right after pairing the app sends the sealed ``account_authentication``
    frame (§15 step 7). A host that stops at once drops the app's socket before
    it arrives, and the app reports that the link failed. The token counts as
    received when ``account.json`` holds one that was not there before the
    pairing started. Returns True when it is stored.
    """

    def provisioned() -> bool:
        current = stored_account_token(workspace)
        return current is not None and current != before

    if provisioned():
        return True
    _log("paired; waiting for the app to send the account token")
    deadline = monotonic() + PROVISION_GRACE_SECONDS
    while monotonic() < deadline:
        sleep(0.5)
        if provisioned():
            _log("account token received")
            return True
    _log(
        "paired, but the app did not send the account token in "
        f"{PROVISION_GRACE_SECONDS:g}s. The host waits on its heal channel; the "
        "app provisions it when it connects again"
    )
    return False


def _pair_and_wait(
    args: argparse.Namespace,
    host_factory: Callable[[argparse.Namespace], LocalHost],
    *,
    token: InstallToken | None,
    already_paired: bool,
    sleep: Callable[[float], None],
    monotonic: Callable[[], float],
    result: dict,
) -> None:
    """Build the host, show how to pair, and wait until the app has paired or
    the time is up. Writes ``paired`` / ``cancelled`` into ``result``, so the
    caller sees them even when this raises."""
    _start_tracing(args)
    host = host_factory(args)
    if token is not None:
        if already_paired:
            _log("this computer was paired before; the install token replaces that pairing")
    elif args.pair:
        _log("--pair: the stored pairing was dropped; a fresh single-use code follows.")
    # What account.json holds now (after the host cleared it for a re-pair),
    # so a new token from the app can be told apart from an old one.
    before = stored_account_token(args.workspace)
    try:
        host.start()
        if token is not None:
            # No code and no QR: the app that minted the token is waiting.
            print("", flush=True)
            print("  Waiting for the Chuk app to confirm this computer...", flush=True)
        else:
            _print_banner(
                host,
                qr=not getattr(args, "no_qr", False),
                qr_invert=not getattr(args, "qr_light", False),
            )
        deadline = monotonic() + max(args.timeout, 0.0)
        while monotonic() < deadline:
            if host.has_stored_pairing:
                result["paired"] = True
                break
            sleep(0.5)
        if result["paired"]:
            _wait_for_provisioning(
                args.workspace, before, sleep=sleep, monotonic=monotonic
            )
    except KeyboardInterrupt:
        print("", flush=True)
        _log("pairing cancelled")
        result["cancelled"] = True
    finally:
        host.stop()


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

    ``--token`` is different: the user just ran a fresh install command from
    the app, so the intent is clear. The stored pairing (and the account
    token) is replaced, the same as ``--pair``.
    """
    token: InstallToken | None = None
    # Read the variable once and remove it at once, so no child process (the
    # sandbox, the agent's commands) inherits the secret.
    env_token = os.environ.pop(INSTALL_TOKEN_ENV, None) or None
    raw_token = getattr(args, "token", None)
    if raw_token is None:
        raw_token = env_token
    if raw_token is not None:
        try:
            token = parse_install_token(raw_token)
        except InvalidInstallToken as exc:
            # The message never holds the token itself.
            print(f"  error: {exc}.", file=sys.stderr, flush=True)
            return EXIT_USAGE
        if getattr(args, "local_relay", False):
            print(
                "  error: --token needs the cloud relay. Remove --local-relay.",
                file=sys.stderr,
                flush=True,
            )
            return EXIT_USAGE
    args.install_token = token
    timeout = getattr(args, "timeout", None)
    if timeout is None:
        timeout = DEFAULT_TOKEN_CONNECT_TIMEOUT if token else DEFAULT_CONNECT_TIMEOUT
    args.timeout = timeout

    workspace = args.workspace
    recover_trust_backup(workspace)
    already_paired = is_paired(workspace)
    if already_paired and not args.pair and token is None:
        print("  This host is already paired — nothing to do.", flush=True)
        print(
            "  The app reconnects on its own, with no code. To pair a DIFFERENT "
            "device (the current one stops working):",
            flush=True,
        )
        print("      agents-host connect --pair", flush=True)
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

    # A token re-pair keeps the old pairing aside (after the service stopped,
    # so nothing writes the files any more) until the new one is stored.
    kept_aside = token is not None and backup_trust(workspace)
    result = {"paired": False, "cancelled": False}
    try:
        _pair_and_wait(
            args,
            host_factory,
            token=token,
            already_paired=already_paired,
            sleep=sleep,
            monotonic=monotonic,
            result=result,
        )
    finally:
        if token is not None:
            # The disk decides, not the loop: a pairing that completed while
            # the host stopped still counts. Anything else (timeout, Ctrl-C,
            # an error) puts the old pairing back before the service restarts.
            if result["paired"] or is_paired(workspace):
                result["paired"] = True
                drop_trust_backup(workspace)
            elif restore_trust(workspace) and kept_aside:
                _log("not paired: the previous pairing is back in place")
    paired = result["paired"]
    cancelled = result["cancelled"]

    if paired and token is not None:
        print("", flush=True)
        print("  Paired with your Chuk account.", flush=True)
    elif paired:
        print("", flush=True)
        print("  Paired. The code is dead and will never be accepted again.", flush=True)
    elif token is not None:
        print("", flush=True)
        if cancelled:
            print("  Not paired. Run the install command again.", flush=True)
        else:
            print(
                "  The install command expired. Create a new one in the Chuk app.",
                flush=True,
            )
    else:
        print("", flush=True)
        print(
            f"  Not paired: no app completed pairing within {args.timeout:g}s. "
            "Run  agents-host connect  again.",
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
            "\n      agents-host run",
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
        out("  Pair the app once:   agents-host connect")
    out("")
    return 0


# --------------------------------------------------------------------------
# trace
# --------------------------------------------------------------------------


TRACE_HOW_TO = (
    "  No trace file yet. Tracing is a developer switch and it is off by default.\n"
    "  Turn it on and run the host again:\n"
    "      agents-host run --trace          (or: AGENTS_TRACE=1 agents-host run)\n"
    "  Then:  agents-host trace --last"
)


def _trace_source(args: argparse.Namespace):
    from chuk_agents_runtime.trace import trace_dir_for

    explicit = getattr(args, "trace_dir", None) or os.environ.get("AGENTS_TRACE_DIR")
    if explicit:
        return Path(explicit).expanduser()
    return trace_dir_for(getattr(args, "workspace", None))


def _print_run_table(rows: list[dict], out: Callable[..., Any]) -> None:
    out("")
    out(
        f"  {'RUN':<26} {'SESSION':<16} {'STARTED':<20} {'SPAN':>9} "
        f"{'RND':>4} {'LINES':>6}  REASON"
    )
    for row in rows:
        started = (
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(row["started_wall"]))
            if row["started_wall"]
            else "?"
        )
        out(
            f"  {row['run_id'][:26]:<26} {row['session_key'][:16]:<16} {started:<20} "
            f"{row['total_ms'] / 1000:>8.1f}s {row['rounds']:>4} {row['lines']:>6}  "
            f"{row['reason']}"
        )
    out("")
    out("  Print one:  agents-host trace <run id prefix>      (or --last)")
    out("")


def cmd_trace(args: argparse.Namespace, *, out: Callable[..., Any] = print) -> int:
    """Read a trace back. Starts no host, opens no port, needs no pairing —
    the moment you need this is the moment the host is the thing misbehaving."""
    from chuk_agents_runtime.trace_report import list_runs, read_lines, trace_files, waterfall

    source = _trace_source(args)
    if not any(candidate.is_file() for candidate in trace_files(source)):
        out(f"  No trace at {source}.")
        out(TRACE_HOW_TO)
        return 1

    run_id = getattr(args, "run_id", None)
    if not run_id and getattr(args, "last", False):
        runs = list_runs(source)
        if not runs:
            out(f"  The trace at {source} holds no complete run yet.")
            return 1
        run_id = runs[0]["run_id"]

    if not run_id:
        runs = list_runs(source)
        if not runs:
            out(f"  The trace at {source} holds no run yet.")
            out(TRACE_HOW_TO)
            return 1
        _print_run_table(runs, out)
        return 0

    lines = read_lines(source, run_id=run_id)
    if not lines:
        out(f"  No run in {source} starts with '{run_id}'.")
        out("  List what is there:  agents-host trace --list")
        return 1
    out(waterfall(lines))
    return 0


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def workspace_for(command: str, explicit: str | None) -> str:
    """The state directory one command works on.

    ``--workspace`` wins, then ``$AGENTS_HOME`` (or ``$COWORK_HOME``), then the
    default. ``run`` and ``connect`` own the state, so they move a legacy
    directory into the default first; ``status``, ``doctor`` and ``trace``
    only look, and find the state wherever it is now. Both answers are the
    same directory once the move has happened.
    """
    if command in _STATE_OWNERS:
        return str(resolve_state_home(explicit, logger=_log))
    return str(locate_state_home(explicit))


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(normalize_argv(list(sys.argv[1:] if argv is None else argv)))
    command = getattr(args, "command", None) or "run"
    args.workspace = workspace_for(command, getattr(args, "workspace", None))
    if command == "connect":
        return cmd_connect(args)
    if command == "status":
        return cmd_status(args)
    if command == "doctor":
        from .doctor import cmd_doctor

        return cmd_doctor(args)
    if command == "trace":
        return cmd_trace(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
