#!/usr/bin/env python3
"""Asks a model for animated explanations and renders each one to a film.
animtest.py <out> [model] [effort]"""
import concurrent.futures as cf, json, re, subprocess, sys, time, urllib.request
from pathlib import Path
HERE = Path(__file__).parent
KEY = (HERE.parent.parent / '_scratch/rtgfx/.melious_key').read_text().strip()
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
model = sys.argv[2] if len(sys.argv) > 2 else 'glm-5.3-flash'
effort = sys.argv[3] if len(sys.argv) > 3 else 'high'
TASKS = {
    'picam': 'Wie schließe ich eine Kamera an einen Raspberry Pi 5 an? Zeig es mir animiert: Klappe anheben, Kabel von oben einstecken, Klappe zu.',
    'engine': 'Zeig animiert, wie ein Viertaktmotor mit einem Kolben arbeitet. Kolben bewegt sich, Kurbelwelle dreht sich.',
    'heli': 'Show how a helicopter lifts off, animated: rotors spin up, then it rises.',
    'gear': 'Erkläre animiert, wie ein Getriebe mit zwei Zahnrädern die Drehzahl ändert.',
    'lego': 'Show animated how a chair gets assembled from its parts, piece by piece.',
    'rocket': 'Show a two stage rocket separating in flight, animated.',
}
system = (HERE / 'PROMPT.md').read_text() + (HERE / 'PROMPT_PLUS.md').read_text()
def run(name):
    extra = ''
    lib = HERE / 'library' / {'picam': 'rpi5.chalk'}.get(name, 'none')
    if lib.exists():
        extra = '\n\nVetted library model. Keep these lines unchanged at the start of the model, keep its ids, and add the camera, cable, labels and animation:\n```chalk\n' + lib.read_text() + '```\nThe camera cable goes into socket cam0, which runs along z near the bottom edge. Its latch is cam0_latch. The camera module must be visible: a small green board with a black lens, joined to a flat ribbon cable. Put them in one group with an id. Module and ribbon arrive together from above, the ribbon end stops in the slot. Do not zoom further than 1.6. End on the whole board with the camera lying beside it.'
    body = {'model': model, 'max_tokens': 48000, 'temperature': 0.4, 'reasoning_effort': effort, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': TASKS[name] + '\nThis needs an `anim` block.' + extra}]}
    t = time.time()
    for a in range(8):
        try:
            r = urllib.request.Request('https://api.melious.ai/v1/chat/completions', json.dumps(body).encode(), {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'chalk-eval/1.0'})
            d = json.load(urllib.request.urlopen(r, timeout=280)); break
        except Exception:
            time.sleep(8 * (a + 1))
    text = d['choices'][0]['message']['content']
    m = re.search(r'```(?:chalk)?\s*\n(.*?)```', text, re.S)
    f = out / f'{name}.chalk'; f.write_text(m.group(1) if m else text)
    dt = round(time.time() - t, 1)
    p = subprocess.run(['node', str(HERE / 'cli.mjs'), str(f), str(out / f'{name}.svg')], capture_output=True, text=True)
    v = subprocess.run(['node', str(HERE / 'video.mjs'), str(f), str(out / f'{name}.mp4'), '12'], capture_output=True, text=True)
    print(name, dt, 's', d['usage']['completion_tokens'], 'tok |', [l for l in p.stdout.split('\n') if l.startswith('line ')][:4], v.stdout.strip()[:80], v.stderr[-120:], flush=True)
names = sys.argv[4].split(',') if len(sys.argv) > 4 else list(TASKS)
with cf.ThreadPoolExecutor(3) as ex:
    list(ex.map(run, names))
