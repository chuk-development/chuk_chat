#!/usr/bin/env python3
"""Prints the table for one or two runs of scripts/perf_bench.sh.

Each run is also compared to the budgets in docs/perf_budgets.json. Lines
over budget are listed under "budget"; with --strict the script exits 1 when
any run is over. Usage: perf_bench_table.py [--strict] RUN.jsonl [RUN.jsonl]
"""
import json
import os
import statistics
import sys

BUDGETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "perf_budgets.json")


def load(path):
    rows, cold = {}, []
    shell, starts = [], []
    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if "phase" in r:
            rows[r["phase"]] = r
        elif "cold" in r:
            shell.append(r)
        elif "coldrun" in r:
            starts.append(r)
        elif "error" in r:
            print("ERROR", r["error"])
    # shell[0] is the seeding launch; each later one follows one coldrun.
    for s, r in zip(shell[1:], starts):
        cold.append((r["am_total_ms"], s["main_at"] + s["shell_ms"] - r["start_epoch"]))
    return rows, cold


def table(rows, cold):
    print(f"{'path':34} {'n':>2} {'fr':>4} {'wall':>7} {'b50':>5} {'b90':>5} {'b99':>6} {'bmax':>6} "
          f"{'r50':>5} {'r90':>5} {'r99':>6} {'rmax':>6} {'j16':>4} {'j33':>4} {'ins':>4}")
    for r in rows.values():
        print(f"{r['phase'][:34]:34} {r['n']:>2} {r['frames']:>4} {r['wall_med']:>7.1f} "
              f"{r['build_p50']:>5.1f} {r['build_p90']:>5.1f} {r['build_p99']:>6.1f} {r['build_max']:>6.1f} "
              f"{r['raster_p50']:>5.1f} {r['raster_p90']:>5.1f} {r['raster_p99']:>6.1f} {r['raster_max']:>6.1f} "
              f"{r['jank_16ms']:>4} {r['jank_33ms']:>4} {r['inset_steps']:>4}")
    if cold:
        print(f"cold start: am TotalTime med {statistics.median(c[0] for c in cold):.0f} ms, "
              f"launch to shell med {statistics.median(c[1] for c in cold):.0f} ms, n={len(cold)}")


def crawl(path):
    rows, problems, skips, done = [], [], [], None
    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if "crawl" in r:
            rows.append(json.loads(r["crawl"]))
        elif "crawl_problem" in r:
            problems.append(("?", "?", "?", r["crawl_problem"]))
        elif "crawl_skip" in r:
            skips.append(r["crawl_skip"])
        elif "crawl_done" in r:
            done = r
    if not rows:
        return
    print(f"crawl: {len(rows)} actions, screens {len({x['s'] for x in rows})}, {done}")
    by = {}
    for r in rows:
        by.setdefault(r["s"], []).append(r)
    print(f"{'screen':38} {'acts':>4} {'first med':>9} {'settled med':>11} {'worst':>6} {'stall':>6} {'jank':>5} {'probl':>5}")
    for s, v in sorted(by.items(), key=lambda kv: -max(x["worst"] for x in kv[1])):
        firsts = sorted(x["first"] for x in v if x["first"] is not None) or [0]
        sets = sorted(x["settled"] for x in v if x["settled"] is not None) or [0]
        print(f"{s[:38]:38} {len(v):>4} {statistics.median(firsts):>9.0f} {statistics.median(sets):>11.0f} "
              f"{max(x['worst'] for x in v):>6} {max(x['stall'] for x in v):>6} {sum(x['jank'] for x in v):>5} {sum(len(x['p']) for x in v):>5}")
    print("worst hops (by worst frame, then settle time):")
    print(f"  {'worst':>5} {'stall':>5} {'first':>5} {'settl':>5} {'jank':>4} kind    from > to | button")
    for r in sorted(rows, key=lambda x: (-x["worst"], -(x["settled"] or 0)))[:40]:
        q = "" if r["quiet"] else " NOT-SETTLED"
        print(f"  {r['worst']:>5} {r['stall']:>5} {str(r['first']):>5} {str(r['settled']):>5} {r['jank']:>4} "
              f"{r['k']:7} {r['s'][:26]} > {r['to'][:26]} | {r['l'][:36]}{q}")
    print("problems:")
    seen = {}
    for r in rows:
        for p in r["p"]:
            seen.setdefault(p[:160], []).append(f"{r['k']} {r['s']} | {r['l']}")
    for p, where in sorted(seen.items(), key=lambda kv: -len(kv[1])):
        print(f"  x{len(where)} {p}\n      first at: {where[0]}")
    for p in problems:
        print("  between actions:", p[3][:200])
    print("skipped:", skips)


def budget_for(phases, name):
    for prefix, limits in phases.items():
        if name.startswith(prefix):
            return limits
    return None


def check_budgets(path, rows, cold):
    """Lists every value over its budget; returns how many there are."""
    if not os.path.exists(BUDGETS):
        return 0
    budgets = json.load(open(BUDGETS))
    over = []
    for name, row in rows.items():
        limits = budget_for(budgets.get("phases", {}), name)
        for metric, limit in (limits or {}).items():
            value = row.get(metric)
            if isinstance(value, (int, float)) and value > limit:
                over.append(f"{name}: {metric} {value} > {limit}")
    cs = budgets.get("cold_start", {})
    if cold:
        am = statistics.median(c[0] for c in cold)
        shell = statistics.median(c[1] for c in cold)
        if "am_total_ms" in cs and am > cs["am_total_ms"]:
            over.append(f"cold start: am TotalTime med {am:.0f} > {cs['am_total_ms']}")
        if "to_shell_ms" in cs and shell > cs["to_shell_ms"]:
            over.append(f"cold start: to shell med {shell:.0f} > {cs['to_shell_ms']}")
    mem = budgets.get("memory", {})
    rss = os.path.splitext(path)[0] + ".rss"
    if "avd_rss_mb" in mem and os.path.exists(rss):
        run = longest = peak = 0
        for line in open(rss):
            parts = line.split()
            mb = int(parts[1]) if len(parts) == 2 and parts[1].isdigit() else 0
            peak = max(peak, mb)
            run = run + 1 if mb > mem["avd_rss_mb"] else 0
            longest = max(longest, run)
        if longest >= mem.get("seconds_over", 30):
            over.append(f"AVD RSS over {mem['avd_rss_mb']} MB for {longest} s (peak {peak} MB)")
        else:
            print(f"AVD RSS peak {peak} MB (budget {mem['avd_rss_mb']} MB sustained)")
    if over:
        print(f"budget: {len(over)} over (docs/perf_budgets.json)")
        for o in over:
            print("  OVER", o)
    else:
        print("budget: all within docs/perf_budgets.json")
    return len(over)


args = [a for a in sys.argv[1:] if a != "--strict"]
total_over = 0
for p in args:
    print("==", p)
    rows, cold = load(p)
    table(rows, cold)
    crawl(p)
    total_over += check_budgets(p, rows, cold)
if "--strict" in sys.argv[1:] and total_over:
    sys.exit(1)
