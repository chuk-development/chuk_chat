// Photo to 3D: the cut-out object is inflated from its silhouette, with the real
// pixels on it. Works for anything that has a picture. Regions cut it into parts
// that can carry a label and move.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { nums } from './parse.mjs';

const CACHE = new Map();

function load(name) {
  const dirs = [process.env.CHALK_CTX, new URL('./library', import.meta.url).pathname].filter(Boolean);
  const file = dirs.flatMap((d) => [name, `${name}.png`].map((n) => path.join(d, n))).find((f) => existsSync(f));
  if (!file) return null;
  if (CACHE.has(file)) return CACHE.get(file);
  const [w, h] = execFileSync('identify', ['-format', '%w %h', file]).toString().trim().split(' ').map(Number);
  const rgba = execFileSync('convert', [file, '-alpha', 'on', '-depth', '8', 'rgba:-'], { maxBuffer: 1e9 });
  const img = { w, h, rgba };
  CACHE.set(file, img);
  return img;
}

// Two-pass chamfer distance to the outside of the mask.
function distance(mask, w, h) {
  const d = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) d[i] = mask[i] ? 1e6 : 0;
  const a = 1, b = 1.4142;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = y * w + x;
    if (x) d[i] = Math.min(d[i], d[i - 1] + a);
    if (y) d[i] = Math.min(d[i], d[i - w] + a);
    if (x && y) d[i] = Math.min(d[i], d[i - w - 1] + b);
    if (y && x + 1 < w) d[i] = Math.min(d[i], d[i - w + 1] + b);
  }
  for (let y = h - 1; y >= 0; y--) for (let x = w - 1; x >= 0; x--) {
    const i = y * w + x;
    if (x + 1 < w) d[i] = Math.min(d[i], d[i + 1] + a);
    if (y + 1 < h) d[i] = Math.min(d[i], d[i + w] + a);
    if (x + 1 < w && y + 1 < h) d[i] = Math.min(d[i], d[i + w + 1] + b);
    if (x && y + 1 < h) d[i] = Math.min(d[i], d[i + w - 1] + b);
  }
  return d;
}

// `photo id tex=name width=4 depth=0.25` with `region id box=x0,y0,x1,y1 label=".."`
// children. Box numbers are shares of the picture, 0 to 1000. x runs right, y up.
export function buildPhoto(node, errors) {
  const kv = node.kv;
  const img = load(kv.tex);
  if (!img) { errors.push(`line ${node.line}: photo: no image "${kv.tex}"`); return []; }
  const longest = Math.max(img.w, img.h), N = Math.min(230, longest);
  const gw = Math.max(8, Math.round((img.w / longest) * N)), gh = Math.max(8, Math.round((img.h / longest) * N));
  const alpha = (gx, gy) => {
    const x = Math.min(img.w - 1, Math.floor(((gx + 0.5) / gw) * img.w)), y = Math.min(img.h - 1, Math.floor(((gy + 0.5) / gh) * img.h));
    return img.rgba[(y * img.w + x) * 4 + 3];
  };
  const mask = new Uint8Array(gw * gh);
  for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) mask[y * gw + x] = alpha(x, y) > 128 ? 1 : 0;
  const dist = distance(mask, gw, gh);
  // The mesh is one cell wider than the mask. The exact edge comes from the photo's
  // alpha in the renderer, so no stair steps show.
  const wide = mask.slice();
  for (let y = 1; y + 1 < gh; y++) for (let x = 1; x + 1 < gw; x++) if (!mask[y * gw + x] && (mask[y * gw + x - 1] || mask[y * gw + x + 1] || mask[(y - 1) * gw + x] || mask[(y + 1) * gw + x])) wide[y * gw + x] = 1;
  let peak = 1;
  for (const v of dist) peak = Math.max(peak, v);
  const W = Number(kv.width ?? 4), scale = W / gw, H = gh * scale;
  const depth = Number(kv.depth ?? 0.22) * W;
  // Round the edge, then keep the middle flat enough for a thin object.
  const slab = kv.profile === 'flat';
  const height = (i) => {
    if (slab) return depth * 0.5; // boards, phones, cards, signs
    const t = Math.min(1, dist[i] / peak);
    return depth * 0.5 * Math.sqrt(1 - (1 - t) ** 2);
  };
  const P = (x, y, sign) => {
    const i = Math.min(gh - 1, Math.max(0, y)) * gw + Math.min(gw - 1, Math.max(0, x));
    return [x * scale - W / 2, H / 2 - y * scale, sign * height(i)];
  };
  const regions = node.kids.filter((k) => k.cmd === 'region').map((k) => {
    const b = nums(k.kv.box, [0, 0, 1000, 1000]);
    const m = load(`region_${k.args[0]}`);
    const box = [b[0] / 1000, b[1] / 1000, b[2] / 1000, b[3] / 1000];
    const inside = (u, v) => {
      if (u < box[0] || u >= box[2] || v < box[1] || v >= box[3]) return false;
      if (!m) return true;
      const x = Math.floor(((u - box[0]) / (box[2] - box[0])) * m.w), y = Math.floor(((v - box[1]) / (box[3] - box[1])) * m.h);
      return m.rgba[(Math.min(m.h - 1, y) * m.w + Math.min(m.w - 1, x)) * 4 + 3] > 128;
    };
    return { id: k.args[0], label: k.kv.label, inside, tris: [] };
  });
  const rest = { id: node.args[0], label: kv.label, tris: [] };
  const push = (t, a, b, c) => t.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]);
  for (let y = 0; y + 1 < gh; y++) {
    for (let x = 0; x + 1 < gw; x++) {
      if (!wide[y * gw + x] || !wide[y * gw + x + 1] || !wide[(y + 1) * gw + x] || !wide[(y + 1) * gw + x + 1]) continue;
      const a = P(x, y, 1), b = P(x + 1, y, 1), c = P(x + 1, y + 1, 1), d = P(x, y + 1, 1);
      const e = P(x, y, -1), f = P(x + 1, y, -1), g = P(x + 1, y + 1, -1), j = P(x, y + 1, -1);
      push(rest.tris, a, d, c); push(rest.tris, a, c, b);
      push(rest.tris, e, g, j); push(rest.tris, e, f, g);
      const u = (x + 0.5) / gw, v = (y + 0.5) / gh;
      for (const r of regions) if (r.inside(u, v)) {
        // A region is a copy of its pixels, a little in front of the body.
        const lift = (q) => [q[0], q[1], q[2] + depth * 0.012];
        push(r.tris, lift(a), lift(d), lift(c)); push(r.tris, lift(a), lift(c), lift(b));
      }
      // Side walls close a slab at the outline.
      if (slab) for (const [n, s, t] of [[wide[y * gw + x + 2], b, c], [wide[(y - 1) * gw + x] , a, b]]) if (!n) { const S = [s[0], s[1], -s[2]], T = [t[0], t[1], -t[2]]; push(rest.tris, s, t, T); push(rest.tris, s, T, S); }
    }
  }
  const tex = { w: img.w, h: img.h, rgba: img.rgba, W, H };
  tex.regions = regions.map((r) => ({ id: r.id, inside: r.inside }));
  return [rest, ...regions].filter((r) => r.tris.length).map((r) => ({ id: r.id, label: r.label, tris: Float32Array.from(r.tris), tex, region: r !== rest }));
}
