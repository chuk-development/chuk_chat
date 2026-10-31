#!/usr/bin/env python3
"""render3d.py <file.chalk> <out.png|out.mp4> [--samples 48] [--size 1600x900] [--fps 24]

Exports a scene and renders it in the PBR viewer. Chrome runs headless on the GPU.
"""
import argparse, json, shutil, subprocess, sys, base64
from pathlib import Path
from playwright.sync_api import sync_playwright
HERE = Path(__file__).parent


def bundle():
    src, out = HERE / 'view/viewer.js', HERE / 'view/viewer.bundle.js'
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        subprocess.run([str(HERE / 'node_modules/.bin/esbuild'), str(src), '--bundle', '--format=iife', '--global-name=chalk', '--minify', '--alias:three/addons=' + str(HERE / 'node_modules/three/examples/jsm'), f'--outfile={out}', '--log-level=error'], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file'); ap.add_argument('out')
    ap.add_argument('--samples', type=int, default=48)
    ap.add_argument('--size', default='1600x900')
    ap.add_argument('--fps', type=int, default=24)
    ap.add_argument('--frame', type=int, default=-1)
    ap.add_argument('--view', default='')
    a = ap.parse_args()
    bundle()
    out = Path(a.out).resolve()
    js = out.with_suffix('.scene.json')
    r = subprocess.run(['node', str(HERE / 'export3d.mjs'), a.file, str(js)], capture_output=True, text=True)
    print(r.stdout.strip() or r.stderr[-800:])
    w, h = map(int, a.size.split('x'))
    with sync_playwright() as p:
        b = p.chromium.launch(channel='chrome', headless=True, args=['--use-angle=gl-egl', '--ignore-gpu-blocklist'])
        pg = b.new_page(viewport={'width': w, 'height': h})
        pg.on('pageerror', lambda e: print('PAGE', e))
        pg.on('console', lambda m: print('LOG', m.text) if m.type == 'error' else None)
        pg.goto('file://' + str(HERE / 'view/page.html'))
        pg.wait_for_function('window.chalk')
        scene = js.read_text()
        info = pg.evaluate('''([s,w,h])=>{const d=JSON.parse(s);const r=chalk.load(d);chalk.setSize(w,h);document.getElementById('t').textContent=d.title;window.D=d;return {gpu:chalk.gpu(),frames:d.frames,fps:d.fps,...r}}''', [scene, w, h])
        print(info)
        if a.view:
            pg.evaluate('v=>{const [l,h]=D.box;chalk.setCamera([v[0],v[1],v[2]??1,(l[0]+h[0])/2,(l[1]+h[1])/2,(l[2]+h[2])/2])}', [float(x) for x in a.view.split(',')])
        frame = "([f,n])=>{const c=chalk.setFrame(f);document.getElementById('cap').textContent=c;chalk.render(n)}"
        if out.suffix == '.png':
            pg.evaluate(frame, [info['frames'] - 1 if a.frame < 0 else a.frame, a.samples])
            pg.screenshot(path=str(out))
        else:
            tmp = out.with_suffix('.frames'); shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir()
            n = int(info['frames'] * a.fps / info['fps'])
            for i in range(n):
                pg.evaluate(frame, [round(i * info['fps'] / a.fps), a.samples])
                pg.screenshot(path=str(tmp / f'f{i:05d}.jpg'), type='jpeg', quality=95)
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-framerate', str(a.fps), '-i', str(tmp / 'f%05d.jpg'), '-pix_fmt', 'yuv420p', '-crf', '18', str(out)], check=True)
            pick = [tmp / f'f{round(k / 5 * (n - 1)):05d}.jpg' for k in range(6)]
            subprocess.run(['montage', *map(str, pick), '-tile', '3x', '-geometry', '640x+3+3', str(out.with_suffix('.strip.png'))])
            shutil.rmtree(tmp)
        b.close()
    js.unlink(missing_ok=True)


main()
