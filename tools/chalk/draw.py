#!/usr/bin/env python3
"""The pipeline: any request, with or without a context image, to a picture and a film.

draw.py <out_dir> "<request>" [--ctx image] [--model glm-5.3-flash] [--film]
"""
import argparse, base64, concurrent.futures as cf, io, json, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path
from PIL import Image, ImageDraw
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import cutout
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
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    log = {}
    plan = json.loads(re.search(r'\{.*\}', llm(a.model, f'Request: {a.request}\n\nAnswer as JSON only: {{"subject": "english name of the physical thing to show, or empty when the request is about an abstract process", "query": "image search words that find one clean photo of it, whole object, side or three quarter view, plain white background"}}', effort='low', tokens=3000), re.S).group())
    log['plan'] = plan
    (out / 'plan.json').write_text(json.dumps(plan))
    if a.ctx:
        source = Image.open(a.ctx).convert('RGB')
        box = llm(a.model, [{'type': 'text', 'text': f'Request: {a.request}\nFind the one physical object the request is about in this screenshot. Ignore page decoration, text and graphics. Read the pixel numbers of the red grid. Answer as JSON only: {{"box":[x0,y0,x1,y1]}} in those pixels, tight around the object.'}, uri(jpg(grid(source), 1000))], effort='high', tokens=8000)
        b = json.loads(re.search(r'\{.*\}', box, re.S).group())['box']
        k = max(source.size) / 1000
        crop = source.crop(tuple(int(v * k) for v in b))
        crop.save(out / 'source.png')
    elif plan.get('subject'):
        urls = search(plan['query']) + search(plan['subject'] + ' photo') + commons(plan['subject'])
        with cf.ThreadPoolExecutor(8) as ex:
            images = [i for i in ex.map(fetch, urls[:24]) if i][:8]
        if not images:
            raise RuntimeError('no images')
        sheet(images).save(out / 'candidates.jpg')
        pick = llm(a.model, [{'type': 'text', 'text': f'Request: {a.request}\nPick the picture that shows the true object best: one whole object, nothing cut off, plain background, no people, no text, no watermark, a real photo if possible. Answer with the number only.'}, uri(jpg(sheet(images), 1400))], effort='low', tokens=3000)
        m = re.search(r'\d+', pick)
        k = int(m.group()) - 1 if m else 0
        images[k if 0 <= k < len(images) else 0].save(out / 'source.png')
    else:
        return None
    log['plain'], log['fill'] = [round(float(x), 2) for x in cutout.cut(out / 'source.png', out / 'cut.png', force_model=bool(a.ctx))]
    picture = Image.open(out / 'cut.png')
    system = (HERE / 'PROMPT_PHOTO.md').read_text()
    note = ' This picture comes from the screenshot of the user. It is the real thing. Where a part is in the picture is where it really is.' if a.ctx else ''
    text = llm(a.model, [{'type': 'text', 'text': a.request + note}, uri(jpg(grid(picture), 1000))], system=system)
    scene = fence(text)
    # The model gives pixels of the grid picture. The engine wants shares of 1000.
    gw, gh = grid(picture).size

    def share(m):
        b = [float(v) for v in m.group(2).split(',')]
        return f'{m.group(1)}box={b[0] * 1000 / gw:.0f},{b[1] * 1000 / gh:.0f},{b[2] * 1000 / gw:.0f},{b[3] * 1000 / gh:.0f}'

    scene = re.sub(r'(region\s+\S+\s+)box=([\d.,]+)', share, scene)
    (out / 'scene.chalk').write_text(scene)
    # Cut each region out of the picture, so a moved part has its real outline.
    from rembg import new_session, remove
    session = new_session('u2net')
    W, H = picture.size
    for rid, box in re.findall(r'region\s+(\S+)\s+box=([\d,]+)', scene):
        b = [int(v) for v in box.split(',')]
        c = picture.crop((b[0] * W // 1000, b[1] * H // 1000, max(b[2] * W // 1000, b[0] * W // 1000 + 4), max(b[3] * H // 1000, b[1] * H // 1000 + 4))).convert('RGB')
        remove(c, session=session).save(out / f'region_{rid}.png')
    log['seconds_to_scene'] = round(time.time() - t0, 1)
    env = dict(**__import__('os').environ, CHALK_CTX=str(out.resolve()))
    p = subprocess.run(['node', str(HERE / 'cli.mjs'), str(out / 'scene.chalk'), str((out / 'scene.svg').resolve())], capture_output=True, text=True, env=env)
    log['feedback'] = p.stdout[-400:] + p.stderr[-300:]
    subprocess.run(['python3', str(HERE / 'shot.py'), str((out / 'scene.svg').resolve())], capture_output=True)
    if a.film:
        v = subprocess.run(['node', str(HERE / 'video.mjs'), str(out / 'scene.chalk'), str((out / 'film.mp4').resolve()), '15'], capture_output=True, text=True, env=env)
        log['film'] = v.stdout.strip()[-80:] + v.stderr[-200:]
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
