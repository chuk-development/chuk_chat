"""``cowork-host`` console entry point.

Starts the whole local platform and prints the pairing instructions the user
types into the CoWork app. Runs until Ctrl-C, then shuts down cleanly.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading

from cowork_agent import DEFAULT_MODEL_ID, MockModelClient

from .host import DEFAULT_WORKSPACE, LocalHost


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


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cowork-host",
        description="Run the whole CoWork platform locally: a blind localhost "
        "relay, an agent, and the pairing initiator — no production relay.",
    )
    parser.add_argument(
        "--port", type=int, default=8787, help="relay TCP port (default 8787)"
    )
    parser.add_argument(
        "--workspace",
        default=DEFAULT_WORKSPACE,
        help=f"host workspace directory (default {DEFAULT_WORKSPACE})",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL_ID,
        help=f"preferred model id (default {DEFAULT_MODEL_ID})",
    )
    parser.add_argument(
        "--sandbox",
        choices=("local", "docker"),
        default="local",
        help="sandbox backend for the agent (default local)",
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
    return parser


def _log(message: str) -> None:
    print(f"[cowork-host] {message}", flush=True)


def _print_banner(host: LocalHost) -> None:
    print("", flush=True)
    print("  CoWork host is ready.", flush=True)
    print(f"    Relay:     {host.url}", flush=True)
    print(
        f"    Agent:     {host.agent.name}  (workspace: {host.agent.workspace_dir})",
        flush=True,
    )
    print(f"    Device:    {host.device_id}", flush=True)
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
            "  To pair a different device, restart with  cowork-host --pair "
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


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    host = LocalHost(
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


if __name__ == "__main__":
    sys.exit(main())
