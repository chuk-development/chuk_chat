#!/usr/bin/env python3
"""Weight-space programming on Qwen3.5-4B for Chalk 3D from a photo.

wsp.py gen  <out_dir> <subjects,...> [--edit edit.json] [--n 1] [--think]
wsp.py acts <run_dir> <out.pt>        # residual + MLP outputs on the run's own tokens
wsp.py edit <dirs.pt> <edit.json> --layers 15,19 --k 64 --scale 1.0

The model reads a photo and the Chalk system prompt, writes one ```chalk fence.
The Chalk engine (tools/chalk/cli.mjs) scores it: errors, lints, visible parts.
"""
import argparse, json, re, subprocess, sys, time
from pathlib import Path
import torch

ROOT = Path(__file__).resolve().parents[2]
CHALK = ROOT / 'tools/chalk'
PHOTOS = ROOT / '_scratch/wsp/photos'
MODEL = 'Qwen/Qwen3.5-4B'
ASK = 'Baue das Objekt auf dem Foto als 3D-Modell in Chalk. Nur ein ```chalk Block.'


def load(edit=None):
    from transformers import AutoProcessor, AutoModelForImageTextToText
    proc = AutoProcessor.from_pretrained(MODEL)
    # 12 GB card, 8.5 GB bf16 weights do not fit next to the desktop. Everything is 4-bit NF4
    # except down_proj (the matrices the edit changes, kept bf16 and exact), vision and lm_head.
    from transformers import BitsAndBytesConfig
    q = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type='nf4', bnb_4bit_compute_dtype=torch.bfloat16,
                           llm_int8_skip_modules=['down_proj', 'visual', 'lm_head', 'mtp'])
    model = AutoModelForImageTextToText.from_pretrained(MODEL, dtype=torch.bfloat16, device_map='cuda', quantization_config=q)
    model.eval()
    if edit:
        apply_edit(model, json.loads(Path(edit).read_text()))
    return proc, model


def layers(model):
    return model.model.language_model.layers


def apply_edit(model, spec):
    """spec: [{layer, dir: [hidden floats], cols: [neuron ids], scale}] -> W[:, j] -= scale * d (d.W[:, j])"""
    for e in spec:
        W = layers(model)[e['layer']].mlp.down_proj.weight  # [hidden, intermediate]
        d = torch.tensor(e['dir'], dtype=torch.float32, device=W.device)
        d = d / d.norm()
        cols = torch.tensor(e['cols'], device=W.device)
        Wc = W[:, cols].float()
        Wc -= e.get('scale', 1.0) * torch.outer(d, d @ Wc)
        W.data[:, cols] = Wc.to(W.dtype)
    print('edit:', sum(len(e['cols']) * W.shape[0] for e in spec), 'weights changed', file=sys.stderr)


def photo(subject):
    d = PHOTOS / subject
    fs = sorted(d.glob('ref*.jpg'))
    return fs[0] if fs else None


def prompt(proc, img, think):
    from PIL import Image
    im = Image.open(img).convert('RGB')
    im.thumbnail((448, 448))
    msgs = [{'role': 'system', 'content': [{'type': 'text', 'text': (CHALK / 'PROMPT.md').read_text()}]},
            {'role': 'user', 'content': [{'type': 'image', 'image': im}, {'type': 'text', 'text': ASK}]}]
    return proc.apply_chat_template(msgs, add_generation_prompt=True, tokenize=True, return_dict=True,
                                    return_tensors='pt', enable_thinking=think)


def fence(t):
    t = re.sub(r'<think>.*?</think>', '', t, flags=re.S)
    m = re.search(r'```chalk\s*\n(.*?)(```|$)', t, re.S)
    return m.group(1) if m else None


def score(code, path):
    if code is None:
        return {'fence': 0, 'errors': 0, 'lints': 0, 'parts': 0, 'valid': 0}
    path.write_text(code)
    p = subprocess.run(['node', str(CHALK / 'cli.mjs'), str(path), str(path.with_suffix('.svg'))],
                       capture_output=True, text=True, timeout=60)
    fb = p.stdout + p.stderr
    sec, errs, lints = None, [], []
    for l in fb.split('\n'):
        if l.startswith('ERRORS:'): sec = errs; continue
        if l.startswith('LINTS:'): sec = lints; continue
        if l.startswith('render '): sec = None; continue
        if sec is not None and l.strip(): sec.append(l)
    if p.returncode and not errs:
        errs.append('crash: ' + p.stderr.strip().split('\n')[-1][:200])
    m = re.search(r'model parts visible px: (.*)', fb)
    parts = len(m.group(1).split()) if m else 0
    return {'fence': 1, 'errors': len(errs), 'lints': len(lints), 'parts': parts,
            'valid': int(not errs and parts >= 3), 'err': errs[:6], 'lint': lints[:4]}


def gen(a):
    proc, model = load(a.edit)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    rows = []
    for s in a.subjects.split(','):
        img = photo(s)
        if not img:
            print('no photo', s, file=sys.stderr); continue
        for k in range(a.n):
            torch.manual_seed(1000 + k)
            x = prompt(proc, img, a.think)
            x = x.to('cuda')
            t = time.time()
            with torch.no_grad():
                y = model.generate(**x, max_new_tokens=a.max, do_sample=True, temperature=0.6, top_p=0.95, top_k=20)
            new = y[0, x['input_ids'].shape[1]:]
            text = proc.decode(new, skip_special_tokens=True)
            tag = f'{s}_{k}'
            (out / f'{tag}.txt').write_text(text)
            r = {'tag': tag, 'tokens': len(new), 'trunc': int(len(new) >= a.max), 'sec': round(time.time() - t, 1),
                 **score(fence(text), out / f'{tag}.chalk')}
            rows.append(r)
            print(json.dumps({k2: r[k2] for k2 in ('tag', 'tokens', 'trunc', 'valid', 'errors', 'lints', 'parts')}), flush=True)
    (out / 'rows.json').write_text(json.dumps(rows, indent=1, ensure_ascii=False))
    summ = summary(rows)
    (out / 'summary.json').write_text(json.dumps(summ))
    print('SUMMARY', json.dumps(summ))


def summary(rows):
    n = max(len(rows), 1)
    f = lambda k: round(sum(r[k] for r in rows) / n, 3)
    return {'n': len(rows), 'valid': f('valid'), 'fence': f('fence'), 'trunc': f('trunc'),
            'errors': f('errors'), 'lints': f('lints'), 'parts': f('parts'), 'tokens': f('tokens')}


def bad_lines(code_file):
    """Line numbers (1-based, in the chalk code) that the engine reports as errors."""
    p = subprocess.run(['node', str(CHALK / 'cli.mjs'), str(code_file), str(code_file.with_suffix('.svg'))], capture_output=True, text=True, timeout=60)
    return {int(m) for m in re.findall(r'^line (\d+):', p.stdout, re.M)}


def acts(a):
    """Per layer: mean MLP output on tokens of error lines minus tokens of clean lines (token level)."""
    proc, model = load()
    run = Path(a.run)
    rows = json.loads((run / 'rows.json').read_text())
    keep = set(Path(a.subjects).read_text().strip().split(',')) if a.subjects else None
    L = layers(model)
    store = {}
    T = [0]  # answer length; only the answer slice leaves the GPU
    hooks = [l.mlp.register_forward_hook(lambda m, i, o, j=j: store.__setitem__(j, o.reshape(-1, o.shape[-1])[-T[0]:].float().cpu())) for j, l in enumerate(L)]
    S = {'good': 0, 'bad': 0}; N = {'good': 0, 'bad': 0}
    for r in rows:
        s = r['tag'].rsplit('_', 1)[0]
        if keep and s not in keep or not r['fence']:
            continue
        text = (run / f"{r['tag']}.txt").read_text()
        m = re.search(r'```chalk\s*\n', text)
        bad = bad_lines(run / f"{r['tag']}.chalk")
        enc = proc.tokenizer(text, return_offsets_mapping=True, add_special_tokens=False)
        lab = []  # per answer token: 1 bad line, 0 clean line, -1 outside the code
        for st, en in enc['offset_mapping']:
            if st < m.end():
                lab.append(-1); continue
            ln = text.count('\n', m.end(), st) + 1
            line = text[m.end():].split('\n')[ln - 1] if ln - 1 < len(text[m.end():].split('\n')) else ''
            lab.append(-1 if not line.strip() or line.strip().startswith(('#', '```')) else int(ln in bad))
        x = prompt(proc, photo(s), a.think)
        ans = torch.tensor([enc['input_ids']])
        ids = torch.cat([x['input_ids'], ans], 1)
        x['input_ids'] = ids
        x['attention_mask'] = torch.ones_like(ids)
        for k in ('mm_token_type_ids', 'token_type_ids'):  # per-token side arrays must grow with the answer
            if k in x:
                x[k] = torch.cat([x[k], torch.zeros_like(ans)], 1)
        x = x.to('cuda')
        p0 = ids.shape[1] - ans.shape[1]
        T[0] = ans.shape[1]
        with torch.no_grad():
            model.model(**x)  # no lm_head: 9k x 248k logits would not fit
        lab = torch.tensor(lab)
        H = torch.stack([store[j] for j in range(len(L))])  # [layers, T, hidden]
        for g, v in (('good', 0), ('bad', 1)):
            sel = lab == v
            S[g] = S[g] + H[:, sel].sum(1); N[g] += int(sel.sum())
        print(r['tag'], 'bad lines', len(bad), 'tokens bad/good', int((lab == 1).sum()), int((lab == 0).sum()), file=sys.stderr)
    for h in hooks: h.remove()
    G, B = S['good'] / N['good'], S['bad'] / N['bad']
    torch.save({'good': G, 'bad': B, 'cnt': N}, a.outp)
    d = B - G
    print('tokens', N, 'diff/|good| per layer:', [round(x, 2) for x in (d.norm(dim=1) / G.norm(dim=1)).tolist()])


def edit(a):
    from safetensors import safe_open
    D = torch.load(a.dirs)
    d_all = D['bad'] - D['good']
    snap = next((Path.home() / '.cache/huggingface/hub/models--Qwen--Qwen3.5-4B/snapshots').iterdir())
    wmap = json.loads((snap / 'model.safetensors.index.json').read_text())['weight_map']
    spec = []
    for li in map(int, a.layers.split(',')):
        key = next(k for k in wmap if k.endswith(f'layers.{li}.mlp.down_proj.weight') and 'language_model' in k)
        with safe_open(str(snap / wmap[key]), 'pt') as f:
            W = f.get_tensor(key).float()
        d = d_all[li] / d_all[li].norm()
        if a.random:  # control from the paper: a random direction, same layers, same column count
            g = torch.Generator().manual_seed(li); d = torch.randn(d.shape, generator=g); d = d / d.norm()
        proj = d @ W  # how much each neuron writes along d
        cols = proj.abs().topk(a.k).indices.tolist()
        spec.append({'layer': li, 'dir': d.tolist(), 'cols': cols, 'scale': a.scale})
        print(f'layer {li}: top-{a.k} share of |proj| {proj.abs().topk(a.k).values.sum() / proj.abs().sum():.3f}')
    Path(a.outp).write_text(json.dumps(spec))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    g = sp.add_parser('gen'); g.add_argument('out'); g.add_argument('subjects'); g.add_argument('--edit'); g.add_argument('--n', type=int, default=1); g.add_argument('--max', type=int, default=2500); g.add_argument('--think', action='store_true')
    c = sp.add_parser('acts'); c.add_argument('run'); c.add_argument('outp'); c.add_argument('--subjects'); c.add_argument('--think', action='store_true')
    e = sp.add_parser('edit'); e.add_argument('dirs'); e.add_argument('outp'); e.add_argument('--layers', default='15,19'); e.add_argument('--k', type=int, default=64); e.add_argument('--scale', type=float, default=1.0); e.add_argument('--random', action='store_true')
    a = ap.parse_args()
    {'gen': gen, 'acts': acts, 'edit': edit}[a.cmd](a)
