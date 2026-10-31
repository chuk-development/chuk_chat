#!/usr/bin/env node
// ids: reads a scene from stdin and lists each group with its true world box, so a
// model can write joints from measured numbers.
import { readFileSync } from 'node:fs';
import { parse } from './parse.mjs';
import { buildParts } from './raster.mjs';
const find = (n) => (n.cmd === 'model' ? n : n.kids?.map(find).find(Boolean));
const model = find(parse(readFileSync(0, 'utf8')).root);
const parts = buildParts(model, []);
const f = (v) => v.map((x) => x.toFixed(2)).join(',');
const rows = [];
for (const id of parts.pivots.keys()) {
  const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  let n = 0;
  for (const p of parts) {
    if (!p.path.includes(id)) continue;
    n++;
    for (let i = 0; i < p.tris.length; i += 3) for (let c = 0; c < 3; c++) { lo[c] = Math.min(lo[c], p.tris[i + c]); hi[c] = Math.max(hi[c], p.tris[i + c]); }
  }
  if (n) rows.push(`${id}: parts ${n}, min ${f(lo)}, max ${f(hi)}, mid ${f(lo.map((v, c) => (v + hi[c]) / 2))}`);
}
console.log(rows.slice(0, 400).join('\n'));
