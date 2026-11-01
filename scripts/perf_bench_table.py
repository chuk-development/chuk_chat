#!/usr/bin/env python3
"""Prints the table for one or two runs of scripts/perf_bench.sh."""
import json
import statistics
import sys


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


for p in sys.argv[1:]:
    print("==", p)
    table(*load(p))
    crawl(p)
