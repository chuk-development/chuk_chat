#!/usr/bin/env node
// video <file.chalk> <out.mp4> [fps]: renders the timeline to a film, and
// <out>.strip.png, a strip of keyframes the model can look at.
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { parse, render } from './scene.mjs';

const [, , file, out, fpsArg] = process.argv;
const fps = Number(fpsArg ?? 15);
const src = readFileSync(file, 'utf8');
const tmp = `${out}.frames`;
rmSync(tmp, { recursive: true, force: true });
mkdirSync(tmp, { recursive: true });
const cache = new Map();
const first = render(parse(src).root, { cache, time: 0 });
const total = first.ctx.duration ?? 0;
const tail = 1.2;
const frames = Math.max(1, Math.round((total + tail) * fps));
const t0 = Date.now();
const files = [];
for (let f = 0; f < frames; f++) {
  const r = render(parse(src).root, { cache, time: f / fps });
  const name = path.resolve(`${tmp}/f${String(f).padStart(4, '0')}.svg`);
  writeFileSync(name, r.svg);
  files.push(name);
}
const t1 = Date.now();
execFileSync('python3', [new URL('shot.py', import.meta.url).pathname, ...files], { maxBuffer: 1e8 });
execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-framerate', String(fps), '-i', `${tmp}/f%04d.png`, '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-pix_fmt', 'yuv420p', '-crf', '20', out]);
const pngs = readdirSync(tmp).filter((n) => n.endsWith('.png')).sort();
const pick = Array.from({ length: 6 }, (_, i) => `${tmp}/${pngs[Math.round((i / 5) * (pngs.length - 1))]}`);
execFileSync('montage', [...pick, '-tile', '3x', '-geometry', '640x+3+3', `${out}.strip.png`]);
rmSync(tmp, { recursive: true, force: true });
console.log(`${frames} frames, ${total}s, render ${Math.round((t1 - t0) / frames)} ms/frame, total ${Math.round((Date.now() - t0) / 1000)}s`);
