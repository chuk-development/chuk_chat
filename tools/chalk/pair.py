#!/usr/bin/env python3
"""Head to head. For each task a judge sees two blind pictures in random order and picks.
pair.py <runA> <runB>   (run dirs hold <task>/ and res.json)"""
import base64, json, random, re, sys, time, urllib.request
from pathlib import Path
import concurrent.futures as cf
KEY = (Path(__file__).parent.parent.parent / '_scratch/rtgfx/.melious_key').read_text().strip()
A, B = Path(sys.argv[1]), Path(sys.argv[2])
def pic(run, name):
    last = next(r for r in json.loads((run / 'res.json').read_text()) if r['name'] == name).get('last')
    return run / name / f'{last}.blind.png'
def uri(p):
    return {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(p.read_bytes()).decode()}}
def duel(name):
    a, b = pic(A, name), pic(B, name)
    if not (a.exists() and b.exists()):
        return None
    votes = 0
    for flip in (False, True):
        first, second = (b, a) if flip else (a, b)
        body = {'model': 'glm-5.3-flash', 'max_tokens': 8000, 'temperature': 0, 'reasoning_effort': 'low', 'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': f'Two illustrations of "{name}". Which looks more like the real thing, with better proportions, detail and finish? Answer FIRST or SECOND.'}, uri(first), uri(second)]}]}
        for attempt in range(6):
            try:
                r = urllib.request.Request('https://api.melious.ai/v1/chat/completions', json.dumps(body).encode(), {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'})
                t = json.load(urllib.request.urlopen(r, timeout=120))['choices'][0]['message']['content']
                break
            except Exception:
                time.sleep(6 * (attempt + 1))
        else:
            return None
        u = t.upper()
        pick_first = u.rfind('FIRST') > u.rfind('SECOND')
        votes += (pick_first != flip)
    return votes
names = [r['name'] for r in json.loads((A / 'res.json').read_text())]
with cf.ThreadPoolExecutor(4) as ex:
    res = dict(zip(names, ex.map(duel, names)))
ok = [v for v in res.values() if v is not None]
print(f'{A.name} vs {B.name}: A gets {sum(ok)}/{2 * len(ok)} votes', {k: v for k, v in res.items()})
