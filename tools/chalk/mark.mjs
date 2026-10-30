#!/usr/bin/env node
// mark <dir> <round> <cx> <cy>: draws a user circle on the picture and prints it as text.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parse, render, describeStroke } from './scene.mjs';
import { applyEdits } from './parse.mjs';
const [, , dir, rnd, cx, cy] = process.argv;
const { root } = parse(readFileSync(`${dir}/r0.chalk`, 'utf8'));
for (let r = 1; r <= Number(rnd); r++) if (existsSync(`${dir}/r${r}.chalk`)) applyEdits(root, readFileSync(`${dir}/r${r}.chalk`, 'utf8'));
const res = render(root);
const pts = [];
for (let i = 0; i <= 24; i++) { const a = (i / 24) * Math.PI * 2; pts.push([+cx + Math.cos(a) * 55, +cy + Math.sin(a) * 36]); }
console.log(describeStroke(res, pts));
const path = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0]} ${p[1]}`).join('');
writeFileSync(`${dir}/r${rnd}.mark.svg`, res.svg.replace('</svg>', `<path d="${path}" fill="none" stroke="#e02020" stroke-width="4"/></svg>`));
execFileSync('python3', [new URL('shot.py', import.meta.url).pathname, `${process.cwd()}/${dir}/r${rnd}.mark.svg`]);
