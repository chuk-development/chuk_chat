#!/usr/bin/env python3
"""forge.py <out_dir> "<request>" [--ctx image] [--film] [--rounds 1]

Builds one object assembly by assembly. GLM writes a plan with real boxes. One call
per assembly writes it in great detail, all in parallel. The engine fits each one
into its box, so proportions come from the plan. A critic then rebuilds the worst.
"""
import argparse, concurrent.futures as cf, json, re, subprocess, sys, time
from pathlib import Path
from PIL import Image
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import draw
from draw import llm, uri, jpg, fence


def blocks():
    lines = (HERE / 'PROMPT.md').read_text().split('\n')
    return '\n'.join(lines[44:119])


def obj(text):
    return json.loads(re.search(r'\{.*\}', text, re.S).group())


def measure(frag):
    p = subprocess.run(['node', str(HERE / 'bbox.mjs')], input=frag, capture_output=True, text=True)
    return json.loads(p.stdout) if p.stdout.strip() else {'parts': 0, 'errors': [p.stderr[-300:]], 'lo': [0, 0, 0], 'hi': [0, 0, 0], 'ids': [], 'tris': 0}


def indent(text, n=2):
    return '\n'.join(' ' * n + l if l.strip() else l for l in text.strip('\n').split('\n'))


def normal(frag):
    """A model often forgets to indent below the first group line."""
    lines = [l.rstrip() for l in frag.split('\n') if l.strip()]
    if lines and lines[0].startswith('group') and len(lines) > 1 and not any(l.startswith(' ') for l in lines[1:6] if not l.startswith('#')):
        return '\n'.join([lines[0]] + ['  ' + l for l in lines[1:]])
    return '\n'.join(lines)


def fit(frag, m, box):
    """Puts the assembly into its planned box. Moderate stretch only, shape stays."""
    target = [box[i + 3] - box[i] for i in range(3)]
    have = [max(m['hi'][i] - m['lo'][i], 1e-6) for i in range(3)]
    ratio = [t / h for t, h in zip(target, have)]
    # One scale for all axes, or round parts turn into ovals. Small corrections only:
    # build() sends a big error back to the model, so nothing shrinks in silence.
    mid = max(0.8, min(1.25, min(sorted(ratio)[1], max(ratio))))
    s = [mid, mid, mid]
    c0 = [(m['hi'][i] + m['lo'][i]) / 2 for i in range(3)]
    c1 = [(box[i + 3] + box[i]) / 2 for i in range(3)]
    if all(0.8 < r < 1.25 for r in ratio) and all(abs(c1[i] - c0[i]) < 0.12 * max(target) for i in range(3)):
        return frag
    at = [c1[i] - c0[i] * s[i] for i in range(3)]
    f = lambda v: ','.join(f'{x:.4f}' for x in v)
    return f'group fit_{id(frag) % 99999} at={f(at)} scale={f(s)}\n{indent(frag)}'


def build(plan, a, content_img, feedback=''):
    sys_prompt = (HERE / 'PROMPT_PART.md').read_text() + blocks()
    text = f"Request: {plan['request']}\n\nWhole object: {plan['subject']}, size {plan['size']} {plan['unit']} (length, height, width).\nLook: {plan['look']}\n\nAll assemblies, so that yours fits:\n" + '\n'.join(f"- {x['id']}: {x['what']} box {x['box']}" for x in plan['assemblies'])
    text += f"\n\nYOU BUILD: id `{a['id']}`\nWhat: {a['what']}\nBox: {a['box']}\nForm: {a.get('shape', '')}\nDetails to include: {'; '.join(a.get('details', []))}{feedback}"
    text += '\n\nOuter skin `hull`, stations along x (x: y bottom .. y top, z half width):\n' + plan['table']
    content = [{'type': 'text', 'text': text}] + content_img
    best, note = None, ''
    for _ in range(3):
        reply = llm(plan['model'], content + ([{'type': 'text', 'text': note}] if note else []), system=sys_prompt)
        frag = normal(fence(reply))
        m = measure(frag)
        if None in m['lo'] + m['hi']:
            m['parts'] = 0
        miss = misfit(m, a['box'])
        if m['parts'] and (best is None or (miss, -m['parts']) < (best[2], -best[1]['parts'])):
            best = (frag, m, miss)
        if m['parts'] >= 25 and miss < 1.4:
            break
        if None in m['lo'] + m['hi']:
            note = f"Your last version had no parts that build. Errors: {m['errors'][:6]}. Write the full assembly again, inside the box {a['box']}."
            continue
        note = f"Your last version measures min {[round(v, 2) for v in m['lo']]} max {[round(v, 2) for v in m['hi']]} but the box is {a['box']}. It is wrong by a factor {miss:.1f}. Usual cause: world numbers inside a group that has at=, or inside ring or repeat, so the offset counts twice. Children of a group are relative to it. Write the full assembly again, inside the box. Your last version:\n```chalk\n{frag[:9000]}\n```"
    return best[:2] if best else None


def misfit(m, box):
    """How many times an assembly is too big or too far from its box. 1 is perfect."""
    if not m['parts'] or None in m['lo'] + m['hi']:
        return 99.0
    worst = 1.0
    for i in range(3):
        want = max(box[i + 3] - box[i], 1e-6)
        worst = max(worst, (m['hi'][i] - m['lo'][i]) / want, 1 + max(box[i] - m['lo'][i], m['hi'][i] - box[i + 3], 0) / want)
    return worst


def show_form(frag, out, name, yaw):
    f = out / f'{name}.chalk'
    f.write_text(f'canvas dark\nmodel obj 1100 620 keep=1 view={yaw},12\n{indent(frag)}\n')
    render(f, out / f'{name}.png', 24)
    subprocess.run(['python3', str(HERE / 'render3d.py'), str(f), str(out / f'{name}_side.png'), '--samples', '16', '--size', '1000x560', '--view', '0,4'], capture_output=True, timeout=500)
    subprocess.run(['montage', str(out / f'{name}.png'), str(out / f'{name}_side.png'), '-tile', '2x', '-geometry', '800x+2+2', str(out / f'{name}_both.png')])
    return (out / f'{name}_both.png').read_bytes()


def forge_form(a, out, imgs, model):
    """Skins in parallel, the vote keeps the best, then rounds of correction by eye."""
    system = (HERE / 'PROMPT_FORM.md').read_text()

    def one(i):
        msgs = [{'type': 'text', 'text': a.request + ' Build the outer skin.'}] + imgs
        frag = None
        for _ in range(3):
            frag = normal(fence(llm(model, msgs, system=system)))
            m = measure(frag)
            if m['parts'] and not m['errors']:
                break
            msgs = msgs + [{'type': 'text', 'text': f"Your last answer had these errors. Write it all again, correct:\n{m['errors']}"}]
        show_form(frag, out, f'form{i}', 35)
        return i, frag
    with cf.ThreadPoolExecutor(3) as ex:
        forms = [r for r in ex.map(one, range(a.forms)) if measure(r[1])['parts']]
    k = 0
    if len(forms) > 1:
        ask = [{'type': 'text', 'text': f'Request: {a.request}\nFirst image: reference, if any. Then numbered skins, each with two views. Which has the most correct silhouette and proportions? One number from 1 to {len(forms)}.'}] + imgs + [uri((out / f'form{i}_both.png').read_bytes(), 'image/png') for i, _ in forms]
        m = re.search(r'\d+', llm(model, ask, effort='low', tokens=3000))
        k = int(m.group()) - 1 if m else 0
        k = k if 0 <= k < len(forms) else 0
    best = forms[k][1]
    for r in range(a.formfix):
        pic = show_form(best, out, f'fix{r}', 35)
        ask = [{'type': 'text', 'text': f'Request: {a.request}\nFirst image: reference. Last image: your skin, three-quarter and side view. Compare with care: overall proportions, nose shape, height of top line, tail, windows, colour zones. Then write the full corrected skin. Your skin:\n```chalk\n{best}\n```'}] + imgs + [uri(pic, 'image/png')]
        new = normal(fence(llm(model, ask, system=system)))
        m = measure(new)
        if not m['parts'] or m['errors']:
            continue
        p2 = show_form(new, out, f'fix{r}b', 35)
        vote = llm(model, [{'type': 'text', 'text': f'Request: {a.request}\nFirst image: reference. Then skin A, then skin B. Which is closer? Answer A or B.'}] + imgs + [uri(pic, 'image/png'), uri(p2, 'image/png')], effort='low', tokens=3000)
        if 'B' in vote.upper()[:20]:
            best = new
    return best


def table(frag):
    p = subprocess.run(['node', str(HERE / 'sections.mjs')], input=frag, capture_output=True, text=True)
    return p.stdout


def assemble(plan, built):
    head = f"canvas dark\ntitle \"{plan['title']}\"\nmodel obj 1100 620 keep=1 tidy=1 view={plan['view'][0]},{plan['view'][1]}{' cut=' + plan['cut'] if plan.get('cut') else ''}\n"
    static, moving = [], [plan['form']]
    for a in plan['assemblies']:
        if a['id'] not in built:
            continue
        frag, m = built[a['id']]
        (static if a.get('static') else moving).append(fit(frag, m, a['box']))
    body = '\n'.join(indent(x, 2) for x in static)
    if plan.get('cut'):
        moving[0] = moving[0].replace('group hull', 'group hull shell=1', 1)
    body += '\n  group whole\n' + '\n'.join(indent(x, 4) for x in moving)
    return head + body + '\n' + (indent(plan['rig']) + '\n' if plan.get('rig') else '')


def render(chalk, png, samples=48, view=''):
    args = ['python3', str(HERE / 'render3d.py'), str(chalk), str(png), '--samples', str(samples)]
    if view:
        args += ['--view', view]
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=500).stdout
    except subprocess.TimeoutExpired:
        return 'render timeout'


def scene_errors(path):
    code = "import('./export3d.mjs').then(m=>{const s=m.exportScene(require('fs').readFileSync(process.argv[1],'utf8'));console.log(JSON.stringify(s.errors.filter(e=>/^mech|joint|anim|no part|step|action|template|cylinder/.test(e)).slice(0,20)))}).catch(e=>console.log(JSON.stringify([String(e)])))"
    p = subprocess.run(['node', '-e', code, str(path)], capture_output=True, text=True, cwd=HERE, timeout=300)
    try:
        return json.loads(p.stdout.strip().split('\n')[-1])
    except Exception:
        return ['export failed: ' + p.stderr[-300:]]


def group_table(scene):
    return subprocess.run(['node', str(HERE / 'ids.mjs')], input=scene, capture_output=True, text=True).stdout


def rig_block(plan, a, model, out):
    """The moving heart of a machine, written before the parts that surround it."""
    system = (HERE / 'PROMPT_RIG.md').read_text()
    msg = f"Request: {a.request}\nPlan: {json.dumps({k: plan.get(k) for k in ('subject', 'size', 'unit', 'motion')}, ensure_ascii=False)}\nBuild it in the same units as the plan, with the crank where the plan needs it."
    errs = []
    for _ in range(3):
        reply = llm(model, msg + (f'\nYour last version had these errors, fix them:\n{errs}' if errs else ''), system=system)
        text = fence(reply)
        test = 'canvas dark\nmodel m 800 400 keep=1\n' + indent(text) + '\n  anim\n    step "t" 1\n      run turns=1\n'
        (out / 'rig.chalk').write_text(test)
        errs = scene_errors(out / 'rig.chalk')
        if not errs:
            return text
    return text


def film(scene, a, plan, model, out, log):
    """Joints and film. The checker sends numbers back until the machine holds together."""
    system = (HERE / 'PROMPT_MECH.md').read_text()
    table_ = group_table(scene)
    (out / 'groups.txt').write_text(table_)
    has_rig = '\n  mech\n' in scene
    base = f"Request: {a.request}\nMotion: {plan.get('motion', '')}\nPlan: {json.dumps([{k: x.get(k) for k in ('id', 'what', 'static')} for x in plan['assemblies']], ensure_ascii=False)}\nGroups:\n{table_}"
    if has_rig:
        base += '\nA rig exists:\n' + scene[scene.index('\n  mech\n'):].split('\n  anim')[0][:6000]
    errs, best = [], None
    for k in range(4):
        reply = llm(model, base + (f'\n\nYour last version:\n```chalk\n{best}\n```\nErrors:\n' + '\n'.join(errs) if errs else ''), system=system, tokens=40000)
        best = fence(reply)
        lines = [l for l in best.split('\n') if l.strip()]
        if not any(l.strip().startswith('run ') for l in lines) or not any(l.strip() == 'anim' for l in lines):
            errs = ['Your answer had no `anim` block with `run`. Write the full fence: mech and anim.']
            log.setdefault('mech_errors', []).append(1)
            continue
        i = next((n for n, l in enumerate(lines) if l.strip() == 'anim'), len(lines))
        joints = [l.strip() for l in lines[:i] if l.strip() and l.strip() != 'mech']
        anim = lines[i:]
        body = scene
        if has_rig:
            body = body.replace('\n  mech\n', '\n  mech\n' + ''.join('    ' + j + '\n' for j in joints), 1)
        else:
            body = body.rstrip('\n') + '\n  mech\n' + ''.join('    ' + j + '\n' for j in joints)
        ind = len(anim[0]) - len(anim[0].lstrip()) if anim else 0
        text = body.rstrip('\n') + '\n' + '\n'.join('  ' + l[ind:] for l in anim) + '\n'
        (out / 'scene.chalk').write_text(text)
        errs = scene_errors(out / 'scene.chalk')
        log.setdefault('mech_errors', []).append(len(errs))
        if not errs:
            break
    log['mech_left'] = errs[:8]


def views(chalk, out, name, plan):
    """Three angles, so a critic sees what one good angle hides."""
    y = plan['view'][0]
    pics = []
    for i, v in enumerate([f"{y},{plan['view'][1]}", '0,6', f'{y + 180},20']):
        render(chalk, out / f'{name}_v{i}.png', 24, v)
        pics.append(str(out / f'{name}_v{i}.png'))
    subprocess.run(['montage', *pics, '-tile', '2x', '-geometry', '800x+2+2', str(out / f'{name}.png')])
    return (out / f'{name}.png').read_bytes()


def run(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    model = a.model
    refs = []
    if a.ctx:
        shot = Image.open(a.ctx).convert('RGB')
        reply = llm(model, [{'type': 'text', 'text': f'Request: {a.request}\nFind the physical object in this screenshot. Read the pixel numbers of the red grid. JSON only: {{"box":[x0,y0,x1,y1]}}'}, uri(jpg(draw.grid(shot), 1000))], effort='high', tokens=8000)
        b = obj(reply)['box']
        k = max(shot.size) / 1000
        refs = [shot.crop(tuple(int(v * k) for v in b))]
    else:
        head = obj(llm(model, f'Request: {a.request}\n\nJSON only: {{"subject": "english name of the physical thing", "query": "image search words for one clean photo that shows it whole"}}', effort='low', tokens=3000))
        urls = draw.search(head['query']) + draw.commons(head['subject'])
        with cf.ThreadPoolExecutor(8) as ex:
            images = [i for i in ex.map(draw.fetch, urls[:14]) if i][:8]
        if images:
            pick = llm(model, [{'type': 'text', 'text': f'Request: {a.request}\nWhich picture shows the real object best, whole and clear, three-quarter view? One number.'}, uri(jpg(draw.sheet(images), 1400))], effort='low', tokens=3000)
            m = re.search(r'\d+', pick)
            k = int(m.group()) - 1 if m else 0
            refs = [images[k if 0 <= k < len(images) else 0]]
    if refs:
        refs[0].save(out / 'reference.png')
    imgs = [uri(jpg(i, 1400)) for i in refs]
    form = forge_form(a, out, imgs, model)
    stations = table(form)
    (out / 'form.chalk').write_text(form)
    plan = obj(llm(model, [{'type': 'text', 'text': a.request + '\n\nThe skin:\n```chalk\n' + form + '\n```\nIts surface:\n' + stations}] + imgs, system=(HERE / 'PROMPT_PLAN.md').read_text()))
    plan['form'] = form
    plan['table'] = stations
    plan['request'] = a.request
    plan['model'] = model
    (out / 'plan.json').write_text(json.dumps(plan, indent=1, ensure_ascii=False))
    plan['rig'] = rig_block(plan, a, model, out) if plan.get('crank') else ''
    if plan['rig']:
        plan['table'] += '\n\nThe moving heart exists already, do not build crank, pistons or rods. Build around it. These are the real numbers:\n' + plan['rig'][plan['rig'].index('mech'):]
    t1 = time.time()
    built = {}
    with cf.ThreadPoolExecutor(10) as ex:
        for x, r in zip(plan['assemblies'], ex.map(lambda x: build(plan, x, imgs), plan['assemblies'])):
            if r:
                built[x['id']] = r
                (out / f"a_{x['id']}.chalk").write_text(r[0])
    t2 = time.time()
    scene = assemble(plan, built)
    (out / 'r0.chalk').write_text(scene)
    views(out / 'r0.chalk', out, 'r0', plan)
    log = {'plan_s': round(t1 - t0), 'build_s': round(t2 - t1), 'assemblies': {k: v[1]['parts'] for k, v in built.items()}, 'parts': sum(v[1]['parts'] for v in built.values()), 'errors': sum(len(v[1]['errors']) for v in built.values())}
    for r in range(a.rounds):
        ask = [{'type': 'text', 'text': f"Request: {a.request}\nFirst image: reference, if any. Last image: our model. Assemblies: {[x['id'] for x in plan['assemblies']]}.\nThe last image shows three angles: front three-quarter, side, rear. Find what stops it from looking real and right: wrong form, wrong place, wrong size, stray or huge parts that do not exist on the real thing, too plain. The skin itself has the id hull. JSON only: {{\"fix\": [{{\"id\": \"assembly id or hull\", \"action\": \"rebuild or remove\", \"problem\": \"exact words what is wrong and what it must be\"}}]}}, at most 6, worst first. Use remove for a thing that must not exist."}] + imgs + [uri((out / f'r{r}.png').read_bytes(), 'image/png')]
        fixes = [f for f in obj(llm(model, ask, tokens=12000)).get('fix', []) if f.get('id') in built or f.get('id') == 'hull'][:6]
        log.setdefault('fixes', []).append(fixes)
        new = dict(built)
        keep_form = plan['form']
        for f in list(fixes):
            if f['id'] == 'hull':
                fixes.remove(f)
                skin = normal(fence(llm(model, [{'type': 'text', 'text': f"Request: {a.request}\nA reviewer said about your skin: {f['problem']}\nWrite the full corrected skin. Your skin:\n```chalk\n{plan['form']}\n```"}] + imgs, system=(HERE / 'PROMPT_FORM.md').read_text())))
                m = measure(skin)
                if m['parts'] and not m['errors']:
                    plan['form'] = skin
            elif f.get('action') == 'remove':
                fixes.remove(f)
                new.pop(f['id'], None)
        by = {x['id']: x for x in plan['assemblies']}
        def redo(f):
            old = built[f['id']][0]
            note = f"\n\nA first version exists. A reviewer said: {f['problem']}\nWrite the full assembly again, better and denser. First version:\n```chalk\n{old}\n```"
            return f['id'], build(plan, by[f['id']], imgs, note)
        with cf.ThreadPoolExecutor(5) as ex:
            for i, res in ex.map(redo, fixes):
                if res:
                    new[i] = res
        scene2 = assemble(plan, new)
        (out / f'r{r + 1}.chalk').write_text(scene2)
        views(out / f'r{r + 1}.chalk', out, f'r{r + 1}', plan)
        if not (out / f'r{r + 1}.png').exists():
            plan['form'] = keep_form
            (out / f'r{r + 1}.png').write_bytes((out / f'r{r}.png').read_bytes())
            continue
        vote = llm(model, [{'type': 'text', 'text': f'Request: {a.request}\nFirst image: reference, if any. Then model A, then model B. Which looks more real and more like the thing? Answer A or B.'}] + imgs + [uri((out / f'r{r}.png').read_bytes(), 'image/png'), uri((out / f'r{r + 1}.png').read_bytes(), 'image/png')], effort='low', tokens=3000)
        if 'B' in vote.upper()[:20]:
            built = new
            scene = scene2
        else:
            plan['form'] = keep_form
            (out / f'r{r + 1}.chalk').write_text(scene)
            views(out / f'r{r + 1}.chalk', out, f'r{r + 1}', plan)
    (out / 'scene.chalk').write_text(scene)
    if a.film:
        film(scene, a, plan, model, out, log)
        log['film'] = subprocess.run(['python3', str(HERE / 'render3d.py'), str(out / 'scene.chalk'), str(out / 'film.mp4'), '--samples', '24', '--size', '1280x720', '--fps', '24'], capture_output=True, text=True).stdout[-200:]
    render(out / 'scene.chalk', out / 'final.png', 96, f"{plan['view'][0]},{plan['view'][1]}")
    log['total_s'] = round(time.time() - t0)
    (out / 'log.json').write_text(json.dumps(log, indent=1, ensure_ascii=False))
    return log


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('out'); ap.add_argument('request')
    ap.add_argument('--ctx'); ap.add_argument('--model', default='glm-5.3-flash')
    ap.add_argument('--film', action='store_true'); ap.add_argument('--rounds', type=int, default=2); ap.add_argument('--forms', type=int, default=3); ap.add_argument('--formfix', type=int, default=2)
    print(json.dumps(run(ap.parse_args()), ensure_ascii=False)[:1500])
