#!/usr/bin/env python3
"""Which widgets build, lay out and paint in a phase of the phone benchmark.

Needs a profile APK built with `scripts/perf_bench.sh --census`, running. The
app prints `PERFBENCH {"census":"<phase>"}` after each phase and then waits;
this script reads the VM timeline over HTTP at that moment. See
docs/PERFORMANCE.md.
"""
import collections
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request

SERIAL, LABEL = sys.argv[1], sys.argv[2]
OUT = f"_scratch/perf/{LABEL}.census.txt"


def adb(*a):
    return subprocess.check_output(["adb", "-s", SERIAL, *a], text=True)


log = subprocess.Popen(["adb", "-s", SERIAL, "logcat", "-v", "raw", "-s", "flutter:I"],
                       stdout=subprocess.PIPE, text=True)
base = None


def call(method, **params):
    q = urllib.parse.urlencode({k: "[" + ",".join(v) + "]" for k, v in params.items()})
    with urllib.request.urlopen(f"{base}{method}?{q}", timeout=60) as r:
        return json.load(r).get("result", {})


def report(name, out):
    tl = call("getVMTimeline")["traceEvents"]
    stacks = collections.defaultdict(list)
    self_us = collections.Counter()
    count = collections.Counter()
    roots = collections.Counter()
    for e in sorted((e for e in tl if e.get("ph") in "BE"), key=lambda e: e["ts"]):
        s = stacks[e["tid"]]
        if e["ph"] == "B":
            # A build event right under BUILD is a dirty root: the widget
            # whose markNeedsBuild started this rebuild.
            if s and s[-1][0] == "BUILD":
                roots[e["name"]] += 1
            s.append([e["name"], e["ts"], 0])
        elif s:
            n, ts, child = s.pop()
            dur = e["ts"] - ts
            self_us[n] += dur - child
            count[n] += 1
            if s:
                s[-1][2] += dur
    for e in tl:
        if e.get("ph") == "X":
            self_us[e["name"]] += e.get("dur", 0)
            count[e["name"]] += 1
    out.write(f"\n=== {name}\n{'self ms':>9} {'count':>6}  name\n")
    for n, us in self_us.most_common(45):
        out.write(f"{us / 1000:>9.1f} {count[n]:>6}  {n}\n")
    if roots:
        out.write("dirty roots (widget built straight under BUILD):\n")
        for n, c in roots.most_common(20):
            out.write(f"{c:>7}  {n}\n")
    call("clearVMTimeline")
    profile(out)


def isolate():
    with urllib.request.urlopen(f"{base}getVM", timeout=60) as r:
        vm = json.load(r)["result"]
    return next(i["id"] for i in vm["isolates"] if "main" in i["name"])


def profile(out):
    """Dart CPU samples of the UI isolate since the last marker."""
    iso = isolate()
    url = f"{base}getCpuSamples?isolateId={iso}&timeOriginMicros=0&timeExtentMicros=9007199254740991"
    with urllib.request.urlopen(url, timeout=120) as r:
        res = json.load(r).get("result", {})
    fns = res.get("functions", [])
    name = []
    for f in fns:
        fn = f.get("function", {})
        owner = (fn.get("owner") or {}).get("name", "") if isinstance(fn, dict) else ""
        name.append(f"{owner}.{fn.get('name', '?')}" if owner else str(fn.get("name", "?")))
    incl, excl = collections.Counter(), collections.Counter()
    samples = res.get("samples", [])
    for smp in samples:
        st = smp.get("stack", [])
        if st:
            excl[name[st[0]]] += 1
        for n in {name[i] for i in st}:
            incl[n] += 1
    out.write(f"-- cpu samples {len(samples)}, period {res.get('samplePeriod')} us\n")
    out.write("inclusive:\n")
    for n, c in incl.most_common(400):
        out.write(f"{c:>7}  {n}\n")
    out.write("exclusive:\n")
    for n, c in excl.most_common(25):
        out.write(f"{c:>7}  {n}\n")
    urllib.request.urlopen(f"{base}clearCpuSamples?isolateId={iso}", timeout=60).read()


with open(OUT, "w") as out:
    for line in log.stdout:
        m = re.search(r"VM service is listening on (http://127\.0\.0\.1:(\d+)/\S+?/?)\s*$", line)
        if m:
            local = adb("forward", "tcp:0", f"tcp:{m.group(2)}").strip()
            base = f"http://127.0.0.1:{local}/" + m.group(1).split("/", 3)[3].rstrip("/") + "/"
            call("setVMTimelineFlags", recordedStreams=["Dart", "Embedder", "GC"])
            urllib.request.urlopen(f"{base}setFlag?name=profiler&value=true", timeout=30).read()
            print("census attached", flush=True)
        if "PERFBENCH" in line and '"census"' in line:
            name = json.loads(line.split("PERFBENCH ", 1)[1])["census"]
            report(name, out)
            out.flush()
            print("census", name, flush=True)
            if name == "end":
                break
log.kill()
print("wrote", OUT)
