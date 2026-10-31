#!/usr/bin/env python3
"""The pipeline: any request, with or without a context image, to a picture and a film.

draw.py <out_dir> "<request>" [--ctx image] [--model glm-5.3-flash] [--film]
"""
import argparse, base64, concurrent.futures as cf, io, json, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path
from PIL import Image, ImageDraw
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
KEY = (HERE.parent.parent / '_scratch/rtgfx/.melious_key').read_text().strip()
URL = 'https://api.melious.ai/v1/chat/completions'
WEB = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36'}


STOCK = re.compile(r'istock|shutterstock|alamy|gettyimages|dreamstime|123rf|depositphotos|vecteezy|adobestock|freepik|bigstock|pond5|canstock', re.I)


def llm(model, content, system=None, effort='high', tokens=48000):
    msgs = ([{'role': 'system', 'content': system}] if system else []) + [{'role': 'user', 'content': content}]
    body = {'model': model, 'messages': msgs, 'max_tokens': tokens, 'temperature': 0.3, 'reasoning_effort': effort}
    req = urllib.request.Request(URL, json.dumps(body).encode(), {'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json', 'User-Agent': 'chalk-draw/1.0'})
    for attempt in range(8):
        try:
            d = json.load(urllib.request.urlopen(req, timeout=280))
            return d['choices'][0]['message'].get('content') or ''
        except Exception:
            time.sleep(6 * (attempt + 1))
    raise RuntimeError('model call failed')


def uri(data, mime='image/jpeg'):
    return {'type': 'image_url', 'image_url': {'url': f'data:{mime};base64,' + base64.b64encode(data).decode()}}


def jpg(im, size=900):
    im = im.convert('RGB')
    im.thumbnail((size, size))
    b = io.BytesIO()
    im.save(b, 'JPEG', quality=85)
    return b.getvalue()


def search(query, n=14):
    u = 'https://www.bing.com/images/search?' + urllib.parse.urlencode({'q': query, 'form': 'HDRSC2'})
    html = urllib.request.urlopen(urllib.request.Request(u, headers=WEB), timeout=20).read().decode('utf8', 'ignore')
    urls = [x.replace('&amp;', '&') for x in re.findall(r'murl&quot;:&quot;(.*?)&quot;', html)]
    return [u for u in urls if not STOCK.search(u)][:n]


def commons(subject):
    import refs
    return refs.photos(subject, 6)


def fetch(url):
    try:
        data = urllib.request.urlopen(urllib.request.Request(url, headers=WEB), timeout=12).read()
        im = Image.open(io.BytesIO(data)).convert('RGB')
        return im if min(im.size) >= 300 else None
    except Exception:
        return None


def sheet(images):
    """Numbered contact sheet, so the model can pick by number."""
    cell = 300
    cols = 4
    rows = (len(images) + cols - 1) // cols
    s = Image.new('RGB', (cols * cell, rows * cell), 'white')
    for i, im in enumerate(images):
        t = im.copy()
        t.thumbnail((cell - 10, cell - 10))
        s.paste(t, (i % cols * cell + 5, i // cols * cell + 5))
        d = ImageDraw.Draw(s)
        d.rectangle([i % cols * cell + 4, i // cols * cell + 4, i % cols * cell + 44, i // cols * cell + 34], fill='black')
        d.text((i % cols * cell + 12, i // cols * cell + 10), str(i + 1), fill='white', font_size=20)
    return s


def grid(im):
    """Grid in real pixels of the picture the model sees. Models read those best."""
    bg = Image.new('RGB', im.size, 'white')
    bg.paste(im, mask=im.split()[3] if im.mode == 'RGBA' else None)
    scale = 1000 / max(bg.size)
    bg = bg.resize((round(bg.width * scale), round(bg.height * scale)))
    d = ImageDraw.Draw(bg)
    W, H = bg.size
    for k in range(0, 1001, 100):
        if k <= W:
            d.line([k, 0, k, H], fill=(255, 0, 0), width=1)
            d.text((k + 2, 2), str(k), fill=(200, 0, 0), font_size=13)
        if k <= H:
            d.line([0, k, W, k], fill=(255, 0, 0), width=1)
            d.text((2, k + 2), str(k), fill=(200, 0, 0), font_size=13)
    return bg


def fence(t):
    m = re.search(r'```(?:chalk)?\s*\n(.*?)```', t, re.S)
    return m.group(1) if m else t


def run(a):
    """A 3D model is always generated. Images are only references for the model."""
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    plan = json.loads(re.search(r'\{.*\}', llm(a.model, f'Request: {a.request}\n\nAnswer as JSON only: {{"subject": "english name of the physical thing, or empty for an abstract topic", "query": "image search words for one clean photo that shows it whole", "animate": true or false}}', effort='low', tokens=3000), re.S).group())
    refs_img = []
    if a.ctx:
        shot = Image.open(a.ctx).convert('RGB')
        reply = llm(a.model, [{'type': 'text', 'text': f'Request: {a.request}\nFind the physical object in this screenshot. Ignore decoration. Read the pixel numbers of the red grid. Answer as JSON only: {{"box":[x0,y0,x1,y1]}} tight around the object.'}, uri(jpg(grid(shot), 1000))], effort='high', tokens=8000)
        b = json.loads(re.search(r'\{.*\}', reply, re.S).group())['box']
        k = max(shot.size) / 1000
        crop = shot.crop(tuple(int(v * k) for v in b))
        crop.save(out / 'reference.png')
        refs_img = [crop]
    elif plan.get('subject'):
        urls = search(plan['query']) + commons(plan['subject'])
        with cf.ThreadPoolExecutor(8) as ex:
            images = [i for i in ex.map(fetch, urls[:16]) if i][:8]
        if images:
            sheet(images).save(out / 'candidates.jpg')
            pick = llm(a.model, [{'type': 'text', 'text': f'Request: {a.request}\nWhich picture shows the real object best, whole and clear? Answer with one number.'}, uri(jpg(sheet(images), 1400))], effort='low', tokens=3000)
            m = re.search(r'\d+', pick)
            k = int(m.group()) - 1 if m else 0
            refs_img = [images[k if 0 <= k < len(images) else 0]]
            refs_img[0].save(out / 'reference.png')
    system = (HERE / 'PROMPT.md').read_text() + (HERE / 'PROMPT_PLUS.md').read_text()
    text = a.request
    if plan.get('animate') or a.film:
        text += ' This needs an `anim` block.'
    if refs_img:
        text += ' The image is your reference. Build a detailed 3D model from Chalk parts that matches it.'
    content = [{'type': 'text', 'text': text}] + [uri(jpg(i, 1400)) for i in refs_img]
    env = dict(**__import__('os').environ)

    def draft(i):
        reply = llm(a.model, content, system=system)
        f = out / f'd{i}.chalk'
        f.write_text(fence(reply))
        p = subprocess.run(['node', str(HERE / 'cli.mjs'), str(f), str((out / f'd{i}.svg').resolve())], capture_output=True, text=True, env=env)
        subprocess.run(['python3', str(HERE / 'shot.py'), str((out / f'd{i}.svg').resolve())], capture_output=True)
        issues = sum(1 for l in p.stdout.split('\n') if l.startswith(('line ', 'model ', 'label ')) and 'parts visible' not in l)
        return i, issues, p.stdout[-300:] + p.stderr[-200:]

    with cf.ThreadPoolExecutor(3) as ex:
        drafts = [d for d in ex.map(draft, range(3)) if (out / f'd{d[0]}.png').exists()]
    ask = [{'type': 'text', 'text': f'Request: {a.request}\nThe first image is the reference, if there is one. Then come the numbered results. Which result looks most like the real thing, with the right parts in the right place? Answer with one number from 1 to {len(drafts)}.'}]
    ask += [uri(jpg(i, 900)) for i in refs_img] + [uri((out / f'd{d[0]}.png').read_bytes(), 'image/png') for d in drafts]
    m = re.search(r'\d+', llm(a.model, ask, effort='low', tokens=3000))
    k = int(m.group()) - 1 if m else 0
    pick = drafts[k if 0 <= k < len(drafts) else 0]
    fewest = min(d[1] for d in drafts)
    if pick[1] > fewest + 2:
        pick = min(drafts, key=lambda d: d[1])
    (out / 'scene.chalk').write_text((out / f'd{pick[0]}.chalk').read_text())
    log = {'plan': plan, 'seconds_to_scene': round(time.time() - t0, 1), 'issues': [d[1] for d in drafts], 'picked': pick[0], 'feedback': pick[2][-200:]}
    subprocess.run(['node', str(HERE / 'cli.mjs'), str(out / 'scene.chalk'), str((out / 'scene.svg').resolve())], capture_output=True, env=env)
    subprocess.run(['python3', str(HERE / 'shot.py'), str((out / 'scene.svg').resolve())], capture_output=True)
    if a.film:
        v = subprocess.run(['node', str(HERE / 'video.mjs'), str(out / 'scene.chalk'), str((out / 'film.mp4').resolve()), '15'], capture_output=True, text=True, env=env)
        log['film'] = v.stdout.strip()[-70:] + v.stderr[-150:]
    (out / 'log.json').write_text(json.dumps(log, indent=1))
    return log


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('request')
    ap.add_argument('--ctx')
    ap.add_argument('--model', default='glm-5.3-flash')
    ap.add_argument('--film', action='store_true')
    print(json.dumps(run(ap.parse_args()), ensure_ascii=False)[:700])
