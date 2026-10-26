#!/usr/bin/env python3
"""Run `hyperframes check --json` in a project folder and print one line per finding."""
import json
import subprocess
import sys

d = sys.argv[1]
out = subprocess.run(["npx", "--yes", "hyperframes@0.8.202", "check", "--json"], cwd=d, capture_output=True, text=True).stdout
r = json.loads(out[out.index("{"):])
print("ok:", r.get("ok"))
for sec, s in r.items():
    if isinstance(s, dict) and "findings" in s:
        print(f"[{sec}] errors={s.get('errorCount')} warnings={s.get('warningCount')}")
        for f in s["findings"]:
            if f["severity"] == "info":
                continue
            print(" ", f["severity"], f["code"], f.get("time"), f.get("selector"), f.get("containerSelector") or "",
                  "|", (f.get("text") or f.get("message") or "")[:100])
