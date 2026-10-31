#!/usr/bin/env node
// bbox: reads one Chalk fragment from stdin, prints its bounds, part count and errors.
import { parse } from './parse.mjs';
import { buildParts } from './raster.mjs';
import { readFileSync } from 'node:fs';
const frag = readFileSync(0, 'utf8');
const src = `model m 800 400 keep=1\n${frag.split('\n').map((l) => `  ${l}`).join('\n')}\n`;
const { root } = parse(src);
const model = root.kids.find((k) => k.cmd === 'model');
const errors = [];
const parts = buildParts(model, errors);
const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
let tris = 0;
for (const p of parts) { tris += p.tris.length / 9; for (let i = 0; i < p.tris.length; i += 3) for (let c = 0; c < 3; c++) { lo[c] = Math.min(lo[c], p.tris[i + c]); hi[c] = Math.max(hi[c], p.tris[i + c]); } }
const ids = [...parts.pivots.keys()];
console.log(JSON.stringify({ lo, hi, parts: parts.length, tris, errors: errors.slice(0, 12), ids }));
