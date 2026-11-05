#!/usr/bin/env python3
"""Benchmark for Chalk pipelines.

Each config runs over the task list and gets scored:
  hit    blind recognition: a judge sees the picture with no title and no labels
         and names it. No hint is given. Keywords decide the hit.
  score  judge rating 0 to 10 of the same blind picture.

Usage: bench.py <out> --configs a,b --tasks set [--judge model]
"""
import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent))
import argparse, base64, concurrent.futures as cf, json, re, statistics as S, subprocess, threading, time, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
KEY = (ROOT / '_scratch/rtgfx/.melious_key').read_text().strip()
URL = 'https://api.melious.ai/v1/chat/completions'
GATE = threading.Semaphore(5)

OBJECTS = {
    'tank': ('Zeichne einen Kampfpanzer in 3D und benenne die Hauptteile.', 'tank|panzer'),
    'f35': ('Draw an F-35 fighter jet in 3D.', 'jet|fighter|aircraft|plane|f-35|f35|airplane'),
    'heli': ('Zeichne einen Helikopter in 3D.', 'helicopter|chopper|helikopter'),
    'excavator': ('Show an excavator in 3D.', 'excavator|digger|backhoe|bagger'),
    'car': ('Zeichne einen Sportwagen in 3D.', 'car|sports|automobile|vehicle|auto'),
    'bicycle': ('Draw a bicycle in 3D.', 'bicycle|bike|fahrrad'),
    'guitar': ('Zeichne eine E-Gitarre in 3D.', 'guitar|gitarre'),
    'rocket': ('Show a Falcon 9 rocket on the pad in 3D.', 'rocket|rakete|launch'),
    'windmill': ('Zeichne eine Windkraftanlage in 3D.', 'wind turbine|windmill|windrad|turbine'),
    'locomotive': ('Draw a steam locomotive in 3D.', 'locomotive|train|lokomotive|engine'),
    'microscope': ('Zeichne ein Mikroskop in 3D.', 'microscope|mikroskop'),
    'horse': ('Draw a horse in 3D.', 'horse|pferd|pony'),
    'elephant': ('Zeichne einen Elefanten in 3D.', 'elephant|elefant'),
    'shark': ('Draw a shark in 3D.', 'shark|hai'),
    'sub': ('Zeichne ein U-Boot in 3D.', 'submarine|u-boot|sub'),
    'ship': ('Draw a container ship in 3D.', 'ship|vessel|schiff|freighter'),
    'pi': ('Zeichne einen Raspberry Pi 5 in 3D.', 'raspberry|circuit|board|pcb|computer|motherboard|arduino'),
    'drone': ('Draw a quadcopter drone in 3D.', 'drone|quadcopter|multicopter'),
    'pelican': ('Draw a pelican riding a bicycle.', 'pelican|bird'),
    'camera': ('Zeichne eine Spiegelreflexkamera in 3D.', 'camera|kamera|dslr'),
    'chair': ('Draw an office chair in 3D.', 'chair|stuhl'),
    'lighthouse': ('Draw a lighthouse on a rock in 3D.', 'lighthouse|leuchtturm'),
    'plane': ('Zeichne ein Passagierflugzeug in 3D.', 'plane|airliner|aircraft|airplane|flugzeug|jet'),
    'tractor': ('Draw a farm tractor in 3D.', 'tractor|traktor'),
}
FRESH = {
    'motorbike': ('Zeichne ein Motorrad in 3D.', 'motorcycle|motorbike|motorrad|bike'),
    'crane': ('Draw a mobile crane truck in 3D.', 'crane|kran'),
    'firetruck': ('Zeichne ein Feuerwehrauto in 3D.', 'fire|feuerwehr'),
    'penguin': ('Draw a penguin in 3D.', 'penguin|pinguin'),
    'dino': ('Zeichne einen Tyrannosaurus Rex in 3D.', 'dinosaur|rex|dino'),
    'violin': ('Draw a violin in 3D.', 'violin|geige|fiddle|cello|viola'),
    'sailboat': ('Zeichne ein Segelboot in 3D.', 'sail|segel|boat|yacht'),
    'robotarm': ('Draw an industrial robot arm in 3D.', 'robot|arm'),
    'shuttle': ('Zeichne das Space Shuttle in 3D.', 'shuttle|orbiter|spacecraft'),
    'bulldozer': ('Draw a bulldozer in 3D.', 'bulldozer|dozer|raupe'),
    'cow': ('Zeichne eine Kuh in 3D.', 'cow|kuh|cattle|bull'),
    'tram': ('Draw a modern city tram in 3D.', 'tram|streetcar|train|strassenbahn|light rail'),
}
WEIRD = {
    'toaster': ('Zeichne einen Toaster in 3D.', 'toaster'),
    'barrow': ('Draw a wheelbarrow in 3D.', 'wheelbarrow|barrow|schubkarre'),
    'zeppelin': ('Zeichne einen Zeppelin in 3D.', 'zeppelin|airship|blimp|dirigible'),
    'gnome': ('Draw a garden gnome in 3D.', 'gnome|zwerg|dwarf'),
    'tap': ('Zeichne einen Wasserhahn in 3D.', 'faucet|tap|wasserhahn'),
    'gumball': ('Draw a gumball machine in 3D.', 'gumball|candy|kaugummi'),
    'gondola': ('Zeichne eine venezianische Gondel in 3D.', 'gondola|gondel|boat'),
    'stapler': ('Draw a desk stapler in 3D.', 'stapler|hefter|tacker'),
    'mushroom': ('Zeichne einen Fliegenpilz in 3D.', 'mushroom|pilz|toadstool|fungus|amanita'),
    'pyramid': ('Draw the Great Sphinx of Giza in 3D.', 'sphinx'),
    'lobster': ('Zeichne einen Hummer (das Tier) in 3D.', 'lobster|hummer|crayfish'),
    'accordion': ('Draw an accordion in 3D.', 'accordion|akkordeon|concertina|bellows'),
    'skeleton': ('Zeichne einen menschlichen Schädel in 3D.', 'skull|schädel|cranium'),
    'teapot': ('Draw a Japanese cast iron teapot in 3D.', 'teapot|kettle|tea'),
    'snail': ('Zeichne eine Schnecke mit Haus in 3D.', 'snail|schnecke'),
    'trebuchet': ('Draw a medieval trebuchet in 3D.', 'trebuchet|catapult|siege'),
}
OBJECTS.update(FRESH)
OBJECTS.update(WEIRD)
CORE = ['tank', 'f35', 'heli', 'excavator', 'car', 'guitar', 'horse', 'elephant', 'locomotive', 'microscope', 'ship', 'tractor']


def call(model, messages, effort=None, max_tokens=48000, temperature=0.4):
    body = {'model': model, 'messages': messages, 'max_tokens': max_tokens, 'temperature': temperature}
    if effort:
        body['reasoning_effort'] = effort
    req = urllib.request.Request(URL, json.dumps(body).encode(), {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'})
    t = time.time()
    waited = [0]
    last = None
    for attempt in range(8):
        try:
            with GATE:
                d = json.load(urllib.request.urlopen(req, timeout=280))
            return d['choices'][0]['message'].get('content') or '', d.get('usage', {}), time.time() - t - waited[0]
        except Exception as e:
            last = e
            pause = min(40, 6 * (attempt + 1))
            waited[0] += pause
            time.sleep(pause)
    raise last


def prompt(size):
    p = (HERE / 'PROMPT.md').read_text()
    head, *rest = re.split(r'(?=^# Example \d)', p, flags=re.M)
    if size == 'plus':
        return p + (HERE / 'PROMPT_PLUS.md').read_text()
    if size == 'full':
        return p
    if size == 'mid':
        return head + ''.join(rest[:4])
    if size == 'short':  # Format only, no examples, no advice.
        return re.sub(r'# How to make it excellent.*?(?=# Feedback)', '', head, flags=re.S)
    raise ValueError(size)


def fence(text):
    m = re.search(r'```(?:chalk)?\s*\n(.*?)```', text, re.S)
    return m.group(1) if m else (None if 'DONE' in text else text)


def shot(svg):
    for _ in range(3):
        subprocess.run(['python3', str(HERE / 'shot.py'), str(svg.resolve())], capture_output=True)
        if svg.with_suffix('.png').exists():
            return True
    return False


def draw_step(d, tag, sources, modes=('', )):
    """Renders the file list. Returns feedback text and the issue count."""
    d.mkdir(parents=True, exist_ok=True)
    p = subprocess.run(['node', str(HERE / 'step.mjs'), str(d), tag, *[str(s) for s in sources]], capture_output=True, text=True)
    fb = p.stdout.strip() or ('ERRORS:\n' + p.stderr[-500:])
    for suffix in ['', '.blind', '.ids', '.side', '.top', '.front']:
        f = d / f'{tag}{suffix}.svg'
        if f.exists():
            shot(f)
    views = [d / f'{tag}.{v}.png' for v in ('side', 'top', 'front')]
    if all(v.exists() for v in views):
        subprocess.run(['montage', *[str(v) for v in views], '-tile', '3x1', '-geometry', '700x+4+4', str(d / f'{tag}.ortho.png')], capture_output=True)
    n = sum(1 for l in fb.split('\n') if l.startswith(('line ', 'model ', 'label ', 'arrow ', 'text in', 'canvas is'))) - fb.count('\nmodel parts')
    return fb, max(0, n)


def img(path):
    return {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(path.read_bytes()).decode()}}


PLAN = '''

# Required first step

Before the fence, write a BUILD SHEET as plain text, in English, max 25 lines:
1. Identity: the 5 features that make this exact thing unmistakable, from memory of real photos.
2. Real dimensions in numbers: overall length, height, width, and the size of each main part.
3. Side outline: for each main body, list the top and bottom outline points you will use.
4. Part list in build order: each part, its shape from the catalogue or kit, its parent, and where on the parent.
5. Detail list: 6 small details that make it look real.
Then write the ```chalk fence that follows the sheet exactly. Do not add anything the user did not ask for.
'''

CRITIC = """You are a strict art director. The picture was made from Chalk parts for this request:

{req}

Judge what you see, not what was intended. First say in one line what you think the object is. Then list at most 6 concrete defects, worst first: wrong proportions, missing recognizable features, floating or hidden parts, ugly camera angle, too plain. For each defect name the part id if you know it, and give the concrete fix with numbers. If it is excellent answer exactly: GOOD

Part ids and pixel sizes:
{fb}"""

JUDGE_PICK = 'Which picture shows "{req}" best: real likeness, proportions, detail? The pictures are in order 1 to {n}. Answer with one number only.'


def references(req, model, cache):
    """One cheap call names the subject, then photos and facts are fetched."""
    cache.mkdir(parents=True, exist_ok=True)
    done = cache / 'facts.txt'
    if not done.exists():
        text, _, _ = call(model, [{'role': 'user', 'content': 'Name the physical subject of this request as a 1 to 4 word English encyclopedia search term. Answer with the term only.\n\n' + req}], 'low', 2000)
        term = text.strip().strip('"').split('\n')[0]
        import refs
        files, facts = refs.fetch(term, cache, 3)
        done.write_text(term + '\n\n' + facts)
    return sorted(cache.glob('ref*.jpg')), done.read_text()


def single(cfg, req, system, d, stats):
    user = req
    if cfg.get('ref'):
        files, facts = references(req, 'glm-5.3-flash', Path(cfg['_base']) / 'refs' / d.name)
        content = [{'type': 'text', 'text': req + '\n\nFacts from an encyclopedia:\n' + facts[:2600]}]
        if cfg.get('ref') != 'text':
            content += [img(f) for f in files]
            content[0]['text'] += '\n\nReference photos follow.'
        user = content
    msgs = [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}]
    text, u, dt = call(cfg['model'], msgs, cfg['effort'])
    stats['t'] += dt
    stats['in'] += u.get('prompt_tokens', 0)
    stats['out'] += u.get('completion_tokens', 0)
    return text, msgs


def pipeline(name, req, cfg, out):
    d = out / name
    d.mkdir(parents=True, exist_ok=True)
    system = prompt(cfg.get('prompt', 'full'))
    if cfg.get('plan'):
        system += PLAN
    st = {'t': 0.0, 'in': 0, 'out': 0}
    n = cfg.get('drafts', 1)
    # Drafts run side by side, so the wall time counts the slowest only.
    def one(i):
        s = {'t': 0.0, 'in': 0, 'out': 0}
        text, msgs = single(cfg, req, system, d, s)
        code = fence(text) or ''
        f = d / f'd{i}.chalk'
        f.write_text(code)
        fb, issues = draw_step(d, f'd{i}', [f])
        return {'i': i, 'text': text, 'msgs': msgs, 'fb': fb, 'issues': issues, 's': s, 'file': f}
    with cf.ThreadPoolExecutor(n) as ex:
        drafts = list(ex.map(one, range(n)))
    st['t'] += max(x['s']['t'] for x in drafts)
    for x in drafts:
        st['in'] += x['s']['in']
        st['out'] += x['s']['out']
    best = drafts[0]
    if n > 1:
        pngs = [d / f'd{x["i"]}.png' for x in drafts]
        c = [{'type': 'text', 'text': JUDGE_PICK.format(req=req, n=n)}] + [img(p) for p in pngs if p.exists()]
        text, u, dt = call(cfg['model'], [{'role': 'user', 'content': c}], 'low', 2000)
        st['t'] += dt
        st['in'] += u.get('prompt_tokens', 0)
        st['out'] += u.get('completion_tokens', 0)
        m = re.search(r'\d', text)
        k = int(m.group()) - 1 if m else 0
        fewest = min(x['issues'] for x in drafts)
        pick = drafts[k if 0 <= k < n else 0]
        best = pick if pick['issues'] <= fewest + 2 else min(drafts, key=lambda x: x['issues'])
    files = [best['file']]
    last = best['file'].stem
    issues = best['issues']
    fb = best['fb']
    msgs = best['msgs'] + [{'role': 'assistant', 'content': best['text']}]
    for r in range(cfg.get('rounds', 0)):
        tag = f'r{r + 1}'
        look = d / f'{last}.png'
        if not look.exists():
            break
        ids = d / f'{last}.ids.png'
        ortho = d / f'{last}.ortho.png'
        images = [img(look)] + ([img(ids)] if cfg.get('ids') and ids.exists() else []) + ([img(ortho)] if cfg.get('ortho') and ortho.exists() else [])
        idnote = ' The second image paints each part in its own color with its id.' if cfg.get('ids') else ''
        if cfg.get('ortho'):
            idnote = ' The second image shows three flat views left to right: side, top, front. Each part has its own color and its id. Use them to find wrong positions, wrong proportions, and parts that stick out or do not connect.'
        if cfg.get('critic'):
            c = [{'type': 'text', 'text': CRITIC.format(req=req, fb=fb) + idnote}] + images
            crit, u, dt = call(cfg['model'], [{'role': 'user', 'content': c}], cfg.get('critic_effort', 'low'), 4000)
            st['t'] += dt
            st['in'] += u.get('prompt_tokens', 0)
            st['out'] += u.get('completion_tokens', 0)
            (d / f'{tag}.critic').write_text(crit)
            if crit.strip().startswith('GOOD'):
                break
            ask = [{'type': 'text', 'text': f'{fb}\n\nArt director review:\n{crit}\n\nFix every point with edits. Add the missing features. Never reply DONE here.' + idnote}] + images
        elif cfg.get('text_only'):
            ask = fb + '\n\nFix what is listed, or answer DONE.'
        else:
            ask = [{'type': 'text', 'text': fb + '\n\nThis is your picture. Judge it hard. Answer with edits or DONE.' + idnote}] + images
        msgs.append({'role': 'user', 'content': ask})
        text, u, dt = call(cfg['model'], msgs, cfg['effort'])
        st['t'] += dt
        st['in'] += u.get('prompt_tokens', 0)
        st['out'] += u.get('completion_tokens', 0)
        msgs.append({'role': 'assistant', 'content': text})
        code = fence(text)
        if code is None:
            break
        f = d / f'{tag}.chalk'
        f.write_text(code)
        new_fb, new_issues = draw_step(d, tag, files + [f])
        if new_issues > issues + 1:
            msgs.append({'role': 'user', 'content': 'That edit made it worse, it was rejected. The last picture stands.'})
            continue
        files.append(f)
        last, issues, fb = tag, new_issues, new_fb
    return {'name': name, 'seconds': round(st['t'], 1), 'in': st['in'], 'out': st['out'], 'issues': issues, 'last': last}


def judge(name, keywords, rec, out, model):
    p = out / name / f'{rec["last"]}.blind.png'
    if not p.exists():
        return {'hit': 0, 'score': 0, 'said': 'no image'}
    c = [{'type': 'text', 'text': 'What object is shown? Name it in 1 to 4 words. Then on a new line give a score from 0 to 10 for how good and how realistic this illustration is as a technical drawing. Be strict: 5 is a recognizable but crude model, 8 is a good textbook illustration. Format:\nNAME: ...\nSCORE: n'}, img(p)]
    text, _, _ = call(model, [{'role': 'user', 'content': c}], None, 1500, 0.0)
    nm = re.search(r'NAME:\s*(.*)', text)
    sc = re.search(r'SCORE:\s*([\d.]+)', text)
    said = (nm.group(1) if nm else text[:60]).strip()
    return {'hit': int(bool(re.search(keywords, said, re.I))), 'score': float(sc.group(1)) if sc else 0, 'said': said}


def run_cfg(tag, cfg, tasks, base, judge_model):
    out = base / tag
    out.mkdir(parents=True, exist_ok=True)
    cfg['_base'] = str(base)
    def job(n):
        try:
            rec = pipeline(n, OBJECTS[n][0], cfg, out)
            rec.update(judge(n, OBJECTS[n][1], rec, out, judge_model))
            return rec
        except Exception as e:
            return {'name': n, 'seconds': 0, 'in': 0, 'out': 0, 'hit': 0, 'score': 0, 'said': 'FAIL ' + repr(e)[:120], 'issues': -1}
    with cf.ThreadPoolExecutor(cfg.get('par', 6)) as ex:
        res = list(ex.map(job, tasks))
    (out / 'res.json').write_text(json.dumps(res, indent=1, ensure_ascii=False))
    ok = [r for r in res if r['issues'] >= 0]
    row = {'cfg': tag, 'n': len(ok), 'hit%': round(100 * S.mean(r['hit'] for r in res)), 'score': round(S.mean(r['score'] for r in ok), 2) if ok else 0,
           's_med': S.median(r['seconds'] for r in ok) if ok else 0, 'out_med': S.median(r['out'] for r in ok) if ok else 0, 'in_med': S.median(r['in'] for r in ok) if ok else 0, 'issues': S.mean(r['issues'] for r in ok) if ok else 0}
    print(json.dumps(row), flush=True)
    print('   ', ' | '.join(f"{r['name']}={r['said'][:18]}/{r['score']}" for r in res), flush=True)
    return row


CONFIGS = json.loads((HERE / 'configs.json').read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--configs', required=True)
    ap.add_argument('--tasks', default='core')
    ap.add_argument('--judge', default='qwen3.8-max')
    a = ap.parse_args()
    tasks = CORE if a.tasks == 'core' else list(FRESH) if a.tasks == 'fresh' else list(WEIRD) if a.tasks == 'weird' else [n for n in OBJECTS if n not in FRESH and n not in WEIRD] if a.tasks == 'all' else a.tasks.split(',')
    base = Path(a.out)
    for c in a.configs.split(','):
        run_cfg(c, CONFIGS[c], tasks, base, a.judge)


main()
