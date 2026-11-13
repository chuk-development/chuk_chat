import subprocess, time, sys
Q = "select queryid::text as id, calls, round(total_exec_time)::bigint as ms, left(regexp_replace(query, '\\s+', ' ', 'g'), 110) as q from extensions.pg_stat_statements"
def snap():
    for _ in range(8):
        r = subprocess.run([sys.executable, 'scripts/supabase/query.py'], input=Q, capture_output=True, text=True)
        if r.returncode == 0:
            d = {}
            for line in r.stdout.splitlines():
                p = line.split(' | ', 3)
                if len(p) == 4:
                    try: d[p[0]] = (int(p[1]), int(p[2]), p[3])
                    except ValueError: pass
            return d
        time.sleep(5)
    raise SystemExit('db not answering')
W = int(sys.argv[1]) if len(sys.argv) > 1 else 90
t0 = time.time(); a = snap(); time.sleep(W); b = snap(); dt = time.time() - t0
rows = [(b[k][1]-a.get(k,(0,0,''))[1], b[k][0]-a.get(k,(0,0,''))[0], b[k][2]) for k in b]
tot = sum(r[0] for r in rows)
print(f'--- {dt:.0f} s window, total exec {tot} ms = {tot/10/dt:.1f} % of one core')
for ms, c, q in sorted(rows, reverse=True)[:14]:
    if c: print(ms, 'ms |', c, 'calls |', q)
