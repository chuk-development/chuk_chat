#!/usr/bin/env python3
"""Runs the draw, feedback, fix loop against a model and records the numbers.

Usage: eval.py <out_dir> [--effort low] [--rounds 3] [--only name,name] [--model glm-5.3-flash]
Key file: _scratch/rtgfx/.melious_key
"""
import argparse, base64, concurrent.futures as cf, json, re, subprocess, time, urllib.request
from pathlib import Path


HERE = Path(__file__).parent
ROOT = HERE.parent.parent
KEY = (ROOT / '_scratch/rtgfx/.melious_key').read_text().strip()
URL = 'https://api.melious.ai/v1/chat/completions'

TASKS = {
    'f35': 'Ist das echt? Kann eine F-35B wirklich in der Luft schweben? Zeichne den Jet in 3D und erkläre wie es funktioniert.',
    'pi': 'Wie schließe ich eine Kamera an einen Raspberry Pi 5 an? Zeig mir genau wie.',
    'tensor': 'Wie erstellt ein Tensor Trainingsdaten für ein Sprachmodell?',
    'turbofan': 'Show me how a turbofan engine works, with a cutaway.',
    'heart': 'Wie pumpt das menschliche Herz Blut?',
    'pelican': 'Draw a pelican riding a bicycle.',
    'fourstroke': 'Erkläre den Viertaktmotor mit einem Kolben in 3D.',
    'git': 'Was ist der Unterschied zwischen git merge und git rebase?',
    'espresso': 'Wie funktioniert eine Siebträger-Espressomaschine innen?',
    'cat': 'Zeichne eine Katze, die auf einem Sofa schläft, handgezeichnet.',
    'solar': 'Zeig das Sonnensystem in 3D und warum es Jahreszeiten gibt.',
    'watch': 'Zeig das Innere einer mechanischen Uhr als Explosionszeichnung.',
    'tank': 'Zeichne einen Kampfpanzer in 3D und benenne die Hauptteile.',
    'drone': 'How does a quadcopter drone stay in the air? Show it in 3D.',
    'phone': 'Zeig ein Smartphone als Explosionszeichnung.',
    'boat': 'Wie segelt ein Segelboot gegen den Wind? In 3D.',
    'hand': 'Zeig die Knochen einer menschlichen Hand in 3D.',
    'lighthouse': 'Draw a lighthouse on a cliff, hand-drawn, with a small boat.',
}


def call(model, messages, effort):
    body = {'model': model, 'messages': messages, 'max_tokens': 16000, 'temperature': 0.4}
    if effort:
        body['reasoning_effort'] = effort
    req = urllib.request.Request(URL, json.dumps(body).encode(), {
        'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'chalk-eval/1.0'})
    t = time.time()
    for attempt in range(3):
        try:
            d = json.load(urllib.request.urlopen(req, timeout=300))
            return d['choices'][0]['message'].get('content') or '', d.get('usage', {}), time.time() - t
        except Exception as e:  # Retry rate limits and gateway errors.
            if attempt == 2:
                raise
            time.sleep(4 * (attempt + 1))


def fence(text):
    m = re.search(r'```(?:chalk)?\s*\n(.*?)```', text, re.S)
    return m.group(1) if m else (None if 'DONE' in text else text)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def image_part(png):
    b = base64.b64encode(png.read_bytes()).decode()
    return {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + b}}


def task(name, prompt, a, system, out):
    d = out / name
    d.mkdir(parents=True, exist_ok=True)
    msgs = [{'role': 'system', 'content': system}, {'role': 'user', 'content': prompt}]
    rec = {'name': name, 'rounds': [], 'prompt_tokens': 0, 'completion_tokens': 0, 'seconds': 0}
    scene = None
    best = (0, 10**9)
    for r in range(a.rounds + 1):
        text, usage, dt = call(a.model, msgs, a.effort)
        rec['prompt_tokens'] += usage.get('prompt_tokens', 0)
        rec['completion_tokens'] += usage.get('completion_tokens', 0)
        rec['seconds'] += dt
        (d / f'r{r}.txt').write_text(text)
        code = fence(text)
        msgs.append({'role': 'assistant', 'content': text})
        if code is None:
            rec['rounds'].append({'r': r, 'done': True, 'seconds': round(dt, 1)})
            break
        cmd = ['node', str(HERE / 'loop.mjs'), str(d), str(r)]
        (d / f'r{r}.chalk').write_text(code)
        p = run(cmd)
        fb = p.stdout.strip() or p.stderr[-600:]
        (d / f'r{r}.feedback').write_text(fb)
        for _ in range(3):
            run(['python3', str(HERE / 'shot.py'), str((d / f'r{r}.svg').resolve())])
            if (d / f'r{r}.png').exists():
                break
        issues = fb.count('\nline ') + fb.count('\nmodel ') - fb.count('\nmodel parts')
        rec['rounds'].append({'r': r, 'seconds': round(dt, 1), 'chars': len(code), 'issues': issues, 'ok': 'OK:' in fb})
        # An edit round that makes things worse is thrown away, the model is told.
        if r and issues > best[1]:
            (d / f'r{r}.chalk').unlink()
            (d / f'r{r}.svg').unlink(missing_ok=True)
            (d / f'r{r}.png').unlink(missing_ok=True)
            msgs.append({'role': 'user', 'content': 'That edit made the picture worse, so it was rejected. The last picture stands.\n' + fb + '\nFix only the listed problems, or answer DONE.'})
            continue
        best = (r, issues)
        scene = r
        if r == a.rounds:
            break
        content = [{'type': 'text', 'text': fb + '\n\nThis is your picture. Judge it hard. Answer with edits or DONE.'}, image_part(d / f'r{r}.png')]
        msgs.append({'role': 'user', 'content': content})
    rec['last'] = scene
    rec['seconds'] = round(rec['seconds'], 1)
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--effort', default='low')
    ap.add_argument('--rounds', type=int, default=2)
    ap.add_argument('--only', default='')
    ap.add_argument('--model', default='glm-5.3-flash')
    ap.add_argument('--ask', default='')
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    system = (HERE / 'PROMPT.md').read_text()
    if a.ask:
        TASKS.clear()
        TASKS['ask'] = a.ask
    names = [n for n in TASKS if not a.only or n in a.only.split(',')]
    with cf.ThreadPoolExecutor(6) as ex:
        futs = {ex.submit(task, n, TASKS[n], a, system, out): n for n in names}
        res = []
        for f in cf.as_completed(futs):
            try:
                res.append(f.result())
                print(json.dumps(res[-1]))
            except Exception as e:
                print('FAIL', futs[f], repr(e)[:300])
    (out / 'summary.json').write_text(json.dumps(res, indent=1))


main()
