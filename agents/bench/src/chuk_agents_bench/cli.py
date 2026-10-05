"""``agents-bench`` - the command line.

    agents-bench snapshot                      # copy the live state DB to _scratch/bench
    agents-bench report [--fresh] [--json]     # run timings from the copy
    agents-bench offline --session KEY         # replay prepare, no model call
    agents-bench live --yes-spend-credits      # real prompts, scratch session

Every mode reads a COPY of the state database. ``report`` and ``offline`` take
the copy themselves when it is missing (``--fresh`` takes a new one).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import runs as runs_mod
from .snapshot import age_text, ensure_copy, live_db_path, snapshot


def _add_db(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--db",
        help="state DB copy to read (default: _scratch/bench/executor-state.db; "
        "a path inside the live state dir is copied first, never read in place)",
    )
    parser.add_argument(
        "--fresh", action="store_true", help="take a new copy of the live DB first"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agents-bench", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)

    snap = sub.add_parser("snapshot", help="copy the live state DB (read-only, backup API)")
    snap.add_argument("--source", help=f"DB to copy (default: {live_db_path()})")
    snap.add_argument("--out", help="where to write the copy")

    rep = sub.add_parser("report", help="per-run timings, p50/p95 by session and model")
    _add_db(rep)
    rep.add_argument("--session", help="only this session key")
    rep.add_argument("--prompt", help="only runs whose prompt starts like this (first 40 chars)")
    rep.add_argument("--model", help="only models containing this text")
    rep.add_argument("--provider", help="only providers containing this text")
    rep.add_argument("--state", help="only runs in this state (finished, failed, ...)")
    rep.add_argument("--since", help="only runs since 24h / 90m / 7d / 2026-10-05[T03:00]")
    rep.add_argument("--last", type=int, default=20, help="newest runs to list (default 20)")
    rep.add_argument("--all", action="store_true",
                     help="include runs without timings (model_calls = 0)")
    rep.add_argument("--log", action="append", default=[],
                     help="also parse backend 'model call' lines from this file ('-' = stdin)")
    rep.add_argument("--json", action="store_true", help="print JSON instead of text")

    off = sub.add_parser("offline", help="replay the prepare pipeline of one session")
    _add_db(off)
    off.add_argument("--session", required=True, help="session key to replay")
    off.add_argument("--passes", type=int, default=3, help="runs to simulate (default 3)")
    off.add_argument("--rounds", type=int, default=1, help="model requests per run (default 1)")
    off.add_argument("--runtime-src",
                     help="import chuk_agents_runtime from this .../agents/runtime/src "
                     "(no .pyc is written there); default: this checkout")
    off.add_argument("--skills-root",
                     help="the agent's skills dir (default: guessed from the session key)")
    off.add_argument("--no-skills", action="store_true", help="use an empty skill library")
    off.add_argument("--summarizer", choices=("stub", "none"), default="stub",
                     help="stub = count aux calls (default); none = tier 1 only")
    off.add_argument("--aux-delay-ms", type=float, default=0.0,
                     help="make every stub summary take this long")
    off.add_argument("--context-length", type=int, help="ladder context length override")
    off.add_argument("--cold", action="store_true",
                     help="delete the session's cached summary in the working copy first")
    off.add_argument("--profile", action="store_true",
                     help="cProfile pass 1's ladder_prepare and print the top functions")
    off.add_argument("--profile-top", type=int, default=25)
    off.add_argument("--baseline", help="an earlier --json result to compare against")
    off.add_argument("--json", action="store_true", help="print JSON instead of text")
    off.add_argument("--out", help="also write the JSON result to this file")

    live = sub.add_parser("live", help="real prompts to a scratch session (spends credits)")
    live.add_argument("--yes-spend-credits", action="store_true",
                      help="required: this mode calls the real model and is billed")
    live.add_argument("--prompt", default="hi", help="prompt to send (default 'hi')")
    live.add_argument("-n", "--count", type=int, default=3, help="how many turns (default 3)")
    live.add_argument("--model", help="model id (default: the account's resolved default)")
    live.add_argument("--seed-session",
                      help="copy this session's rows (from the DB copy) into the scratch session")
    live.add_argument("--db", help="DB copy to seed from (default: _scratch/bench copy)")
    live.add_argument("--no-aux", action="store_true", help="tier-1 ladder only, no aux model")
    live.add_argument("--json", action="store_true")
    return parser


def _cmd_snapshot(args: argparse.Namespace) -> int:
    path = snapshot(args.source, args.out)
    print(path)
    return 0


def _cmd_report(args: argparse.Namespace) -> int:
    db = ensure_copy(args.db, fresh=args.fresh)
    flt = runs_mod.RunFilter(
        session=args.session,
        prompt=args.prompt,
        model=args.model,
        provider=args.provider,
        state=args.state,
        since=runs_mod.parse_since(args.since),
        include_unmeasured=args.all,
    )
    report = runs_mod.build_report(
        runs_mod.load_runs(db), flt, last=args.last, source=f"{db} ({age_text(db)})"
    )
    log_records: list[dict] = []
    for item in args.log:
        if item == "-":
            log_records.extend(runs_mod.parse_log(sys.stdin))
        else:
            with open(item, encoding="utf-8", errors="replace") as handle:
                log_records.extend(runs_mod.parse_log(handle))
    log_summary = runs_mod.summarize_log(log_records) if args.log else None

    if args.json:
        data = report.as_dict()
        if log_summary is not None:
            data["log"] = log_summary
        print(json.dumps(data, indent=2, default=str))
    else:
        print(runs_mod.render_text(report))
        if log_summary is not None:
            print()
            print(runs_mod.render_log_text(log_summary))
    return 0


def _cmd_offline(args: argparse.Namespace) -> int:
    from . import offline

    db = ensure_copy(args.db, fresh=args.fresh)
    if args.no_skills:
        skills_root = None
    else:
        skills_root = args.skills_root or offline.guess_skills_root(args.session)
    result = offline.replay(
        db,
        args.session,
        passes=args.passes,
        rounds=args.rounds,
        runtime_src=args.runtime_src,
        skills_root=skills_root,
        summarizer=args.summarizer,
        aux_delay_ms=args.aux_delay_ms,
        context_length=args.context_length,
        cold=args.cold,
        profile=args.profile,
        profile_top=args.profile_top,
    )
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(offline.render_json(result), encoding="utf-8")
    if args.json:
        print(offline.render_json(result))
    else:
        baseline = offline.load_baseline(args.baseline) if args.baseline else None
        print(f"skills root {skills_root or '(none)'}")
        print(offline.render_text(result, baseline))
    return 0


def _cmd_live(args: argparse.Namespace) -> int:
    if not args.yes_spend_credits:
        print("live mode calls the real model and is billed; add --yes-spend-credits",
              file=sys.stderr)
        return 2
    from . import live

    seed_db = ensure_copy(args.db) if args.seed_session else None
    client, label = live.backend_client(args.model)
    result = live.run_live(
        client,
        prompts=[args.prompt] * max(1, args.count),
        label=label,
        seed_db=seed_db,
        seed_session=args.seed_session,
        with_aux=not args.no_aux,
    )
    print(json.dumps(result.as_dict(), indent=2, default=str) if args.json
          else live.render_text(result))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    handler = {
        "snapshot": _cmd_snapshot,
        "report": _cmd_report,
        "offline": _cmd_offline,
        "live": _cmd_live,
    }[args.mode]
    return handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
