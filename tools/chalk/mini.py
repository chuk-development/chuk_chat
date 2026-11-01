#!/usr/bin/env python3
"""mini.py <out_dir> "<request>": one GLM call for one machine. Errors go back at most twice."""
import json, re, subprocess, sys, time
from pathlib import Path
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from draw import llm

MODEL = 'glm-5.3-flash'


def fence(t):
    m = re.search(r'```(?:mini)?\n(.*?)```', t, re.S)
    return m.group(1) if m else t


def main(out, request):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    system = (HERE / 'PROMPT_MINI.md').read_text()
    t0, note, r = time.time(), '', {}
    for i in range(5):
        src = fence(llm(MODEL, request + note, system=system, effort='low', tokens=6000))
        (out / 'scene.mini').write_text(src)
        r = json.loads(subprocess.run(['node', str(HERE / 'mini.mjs'), str(out / 'scene.mini'), str(out / 'scene.chalk')], capture_output=True, text=True).stdout)
        if not r['errors']:
            break
        note = '\n\nYour last version:\n' + src + '\nErrors:\n' + '\n'.join(r['errors'])
    print(json.dumps({'request': request, 'rounds': i + 1, 'sec': round(time.time() - t0, 1), **r}, ensure_ascii=False))


main(sys.argv[1], sys.argv[2])
