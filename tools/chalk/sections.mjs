#!/usr/bin/env node
// sections: reads a skin fragment from stdin, prints its outer surface at stations.
import { parse } from './parse.mjs';
import { buildParts } from './raster.mjs';
import { readFileSync } from 'node:fs';
const frag = readFileSync(0, 'utf8');
const { root } = parse(`model m 800 400 keep=1\n${frag.split('\n').map((l) => `  ${l}`).join('\n')}\n`);
const parts = buildParts(root.kids.find((k) => k.cmd === 'model'), []);
let x0 = 1e9, x1 = -1e9;
for (const p of parts) for (let i = 0; i < p.tris.length; i += 3) { x0 = Math.min(x0, p.tris[i]); x1 = Math.max(x1, p.tris[i]); }
const N = 24, cols = Array.from({ length: N }, () => [1e9, -1e9, 0]);
for (const p of parts) for (let i = 0; i < p.tris.length; i += 3) {
  const k = Math.min(N - 1, Math.floor(((p.tris[i] - x0) / (x1 - x0 || 1)) * N)), c = cols[k];
  c[0] = Math.min(c[0], p.tris[i + 1]); c[1] = Math.max(c[1], p.tris[i + 1]); c[2] = Math.max(c[2], Math.abs(p.tris[i + 2]));
}
cols.forEach((c, k) => { if (c[1] > -1e8) console.log(`x ${(x0 + ((k + 0.5) / N) * (x1 - x0)).toFixed(2)}: y ${c[0].toFixed(2)} .. ${c[1].toFixed(2)}, z +-${c[2].toFixed(2)}`); });
