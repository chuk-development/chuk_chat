// CPU renderer: z-buffer, cel shading, edge lines from the id, depth and normal
// buffers, soft ground shadow. No GPU, no assets, small enough to port to Dart.
import zlib from 'node:zlib';
import { buildShape, SHAPES, COLORS3D, shapeKeys, isCommon } from './geom.mjs';
import { nums } from './parse.mjs';

const hex = (c) => {
  const s = (COLORS3D[c] ?? c ?? '#b8bcc0').replace('#', '');
  const v = s.length === 3 ? s.split('').map((x) => x + x).join('') : s;
  const n = parseInt(v, 16);
  return Number.isNaN(n) ? [184, 188, 192] : [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};

const IDENT = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]; // 3x3 then translate
const mul = (a, b) => {
  const o = new Array(12);
  for (let c = 0; c < 3; c++) for (let r = 0; r < 3; r++) o[c * 3 + r] = a[r] * b[c * 3] + a[r + 3] * b[c * 3 + 1] + a[r + 6] * b[c * 3 + 2];
  for (let r = 0; r < 3; r++) o[9 + r] = a[r] * b[9] + a[r + 3] * b[10] + a[r + 6] * b[11] + a[9 + r];
  return o;
};
const translate = ([x, y, z]) => [1, 0, 0, 0, 1, 0, 0, 0, 1, x, y, z];
const scaleM = ([x, y, z]) => [x, 0, 0, 0, y, 0, 0, 0, z, 0, 0, 0];
const rotM = ([rx, ry, rz]) => {
  const d = Math.PI / 180;
  const [a, b, c] = [rx * d, ry * d, rz * d];
  const X = [1, 0, 0, 0, Math.cos(a), Math.sin(a), 0, -Math.sin(a), Math.cos(a), 0, 0, 0];
  const Y = [Math.cos(b), 0, -Math.sin(b), 0, 1, 0, Math.sin(b), 0, Math.cos(b), 0, 0, 0];
  const Z = [Math.cos(c), Math.sin(c), 0, -Math.sin(c), Math.cos(c), 0, 0, 0, 1, 0, 0, 0];
  return mul(Z, mul(Y, X));
};
const apply = (m, [x, y, z]) => [
  m[0] * x + m[3] * y + m[6] * z + m[9],
  m[1] * x + m[4] * y + m[7] * z + m[10],
  m[2] * x + m[5] * y + m[8] * z + m[11],
];
const nodeMatrix = (kv) => {
  let m = IDENT;
  if (kv.at) m = mul(m, translate(nums(kv.at)));
  if (kv.rot) m = mul(m, rotM(nums(kv.rot)));
  if (kv.scale) {
    const s = nums(kv.scale);
    m = mul(m, scaleM(s.length === 1 ? [s[0], s[0], s[0]] : s));
  }
  return m;
};

// Walks a model tree into flat parts: {id, color, mat, label, tris}.
export function buildParts(model, errors) {
  const parts = [];
  const seen = new Set();
  const walk = (node, M, ctx, top) => {
    const { cmd, kv } = node;
    const inh = { color: kv.color ?? ctx.color, mat: kv.mat ?? ctx.mat, label: ctx.label, group: ctx.group, shell: kv.shell ?? ctx.shell };
    if (cmd === 'group' || cmd === 'repeat' || cmd === 'ring' || cmd === 'mirror') {
      const id = kv.id ?? (cmd === 'group' ? node.args[0] : null);
      if (kv.label) { inh.label = kv.label; inh.group = id ?? `g${node.line}`; }
      const base = mul(M, nodeMatrix(kv));
      const each = (m, i) => { for (const k of node.kids) walk(k, m, inh, top ?? `${node.line}:${i}`); };
      if (cmd === 'group') {
        each(base, 0);
      } else if (cmd === 'repeat') {
        const n = Number(node.args[0] ?? kv.n ?? 2), step = nums(kv.step, [0, 0, 0]), rs = nums(kv.rotstep, [0, 0, 0]);
        for (let i = 0; i < n; i++) each(mul(mul(base, translate(step.map((v) => v * i))), rotM(rs.map((v) => v * i))), i);
      } else if (cmd === 'ring') {
        const n = Number(node.args[0] ?? kv.n ?? 6), r = Number(kv.r ?? 1), axis = kv.axis ?? 'y';
        for (let i = 0; i < n; i++) {
          const a = (i / n) * 360, d = (a * Math.PI) / 180;
          const off = axis === 'y' ? [Math.cos(d) * r, 0, Math.sin(d) * r] : axis === 'x' ? [0, Math.cos(d) * r, Math.sin(d) * r] : [Math.cos(d) * r, Math.sin(d) * r, 0];
          const rt = axis === 'y' ? [0, -a, 0] : axis === 'x' ? [a, 0, 0] : [0, 0, a];
          each(mul(mul(base, translate(off)), rotM(rt)), i);
        }
      } else {
        const axis = node.args[0] ?? 'x';
        each(base, 0);
        const s = [axis === 'x' ? -1 : 1, axis === 'y' ? -1 : 1, axis === 'z' ? -1 : 1];
        each(mul(scaleM(s), base), 1);
      }
      return;
    }
    if (!SHAPES.has(cmd)) {
      errors.push(`line ${node.line}: unknown 3D shape "${cmd}". Shapes: ${[...SHAPES].join(' ')}`);
      return;
    }
    for (const k of Object.keys(kv)) {
      if (!isCommon(k) && !shapeKeys(cmd).includes(k)) errors.push(`line ${node.line}: ${cmd} has no "${k}". Keys: ${shapeKeys(cmd).join(' ')}`);
    }
    const mesh = buildShape(node);
    if (!mesh || !mesh.t.length || mesh.t.some(Number.isNaN)) {
      errors.push(`line ${node.line}: ${cmd} gave no valid geometry`);
      return;
    }
    const m = mul(M, nodeMatrix(kv));
    const flip = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[3] * (m[1] * m[8] - m[2] * m[7]) + m[6] * (m[1] * m[5] - m[2] * m[4]) < 0;
    const t = new Float32Array(mesh.t.length);
    for (let i = 0; i < t.length; i += 3) {
      const p = apply(m, [mesh.t[i], mesh.t[i + 1], mesh.t[i + 2]]);
      t[i] = p[0]; t[i + 1] = p[1]; t[i + 2] = p[2];
    }
    if (flip) {
      for (let i = 0; i < t.length; i += 9) {
        for (let k = 0; k < 3; k++) { const v = t[i + 3 + k]; t[i + 3 + k] = t[i + 6 + k]; t[i + 6 + k] = v; }
      }
    }
    const id = node.args[0] ?? `${cmd}@${node.line}`;
    seen.add(id);
    parts.push({
      id, color: hex(kv.color ?? ctx.color), mat: kv.mat ?? ctx.mat ?? (/(steel|alu|metal|titanium|copper|gold|brass)/.test(kv.color ?? ctx.color ?? '') ? 'metal' : 'matte'),
      label: kv.label ?? ctx.label, group: kv.label ? null : ctx.group, shell: kv.shell ?? ctx.shell, tris: t, top: top ?? `${node.line}`, line: node.line,
    });
  };
  for (const k of model.kids) walk(k, IDENT, {}, null);
  return parts;
}

function smoothNormals(tris, creaseCos = 0.72) {
  const n = tris.length / 9;
  const face = new Float32Array(n * 3);
  const map = new Map();
  const key = (i) => `${Math.round(tris[i] * 2e3)},${Math.round(tris[i + 1] * 2e3)},${Math.round(tris[i + 2] * 2e3)}`;
  for (let f = 0; f < n; f++) {
    const o = f * 9;
    const ax = tris[o + 3] - tris[o], ay = tris[o + 4] - tris[o + 1], az = tris[o + 5] - tris[o + 2];
    const bx = tris[o + 6] - tris[o], by = tris[o + 7] - tris[o + 1], bz = tris[o + 8] - tris[o + 2];
    let nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
    const l = Math.hypot(nx, ny, nz) || 1;
    nx /= l; ny /= l; nz /= l;
    face[f * 3] = nx; face[f * 3 + 1] = ny; face[f * 3 + 2] = nz;
    for (let c = 0; c < 3; c++) {
      const k = key(o + c * 3);
      if (!map.has(k)) map.set(k, []);
      map.get(k).push(f);
    }
  }
  const out = new Float32Array(n * 9);
  for (let f = 0; f < n; f++) {
    const fx = face[f * 3], fy = face[f * 3 + 1], fz = face[f * 3 + 2];
    for (let c = 0; c < 3; c++) {
      let x = 0, y = 0, z = 0;
      for (const g of map.get(key(f * 9 + c * 3))) {
        const gx = face[g * 3], gy = face[g * 3 + 1], gz = face[g * 3 + 2];
        if (gx * fx + gy * fy + gz * fz > creaseCos) { x += gx; y += gy; z += gz; }
      }
      const l = Math.hypot(x, y, z) || 1;
      out[f * 9 + c * 3] = x / l; out[f * 9 + c * 3 + 1] = y / l; out[f * 9 + c * 3 + 2] = z / l;
    }
  }
  return out;
}

const smoothstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const LIGHT = (() => { const l = [-0.45, 0.8, 0.55], n = Math.hypot(...l); return l.map((v) => v / n); })();

// Writes a transparent RGBA image of the model plus part statistics.
export function renderModel(parts, opt) {
  const { w, h, yaw = 35, pitch = 22, cut = null, explode = 0, marginX = 0, ink = [34, 36, 40], persp = 0.12 } = opt;
  const SS = 2;
  const W = w * SS, H = h * SS;

  // Bounds and explode offsets.
  let min = [1e9, 1e9, 1e9], max = [-1e9, -1e9, -1e9];
  for (const p of parts) {
    for (let i = 0; i < p.tris.length; i += 3) {
      for (let k = 0; k < 3; k++) { min[k] = Math.min(min[k], p.tris[i + k]); max[k] = Math.max(max[k], p.tris[i + k]); }
    }
  }
  const center = [0, 1, 2].map((k) => (min[k] + max[k]) / 2);
  const size = Math.max(...[0, 1, 2].map((k) => max[k] - min[k])) || 1;
  const offsets = new Map();
  if (explode) {
    const tops = new Map();
    for (const p of parts) {
      const t = tops.get(p.top) ?? { s: [0, 0, 0], n: 0 };
      for (let i = 0; i < p.tris.length; i += 3) { t.s[0] += p.tris[i]; t.s[1] += p.tris[i + 1]; t.s[2] += p.tris[i + 2]; t.n++; }
      tops.set(p.top, t);
    }
    for (const [k, t] of tops) offsets.set(k, t.s.map((v, i) => (v / t.n - center[i]) * explode));
  }

  const yr = (yaw * Math.PI) / 180, pr = (pitch * Math.PI) / 180;
  const cy = Math.cos(yr), sy = Math.sin(yr), cp = Math.cos(pr), sp = Math.sin(pr);
  const view = (x, y, z) => {
    const X = x - center[0], Y = y - center[1], Z = z - center[2];
    const a = cy * X + sy * Z, b = -sy * X + cy * Z;
    return [a, cp * Y - sp * b, sp * Y + cp * b];
  };
  const lightV = view(center[0] + LIGHT[0], center[1] + LIGHT[1], center[2] + LIGHT[2]);

  // Fit to the frame.
  let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
  const pdepth = size / Math.max(persp, 0.01);
  const proj = (v) => { const f = pdepth / (pdepth - v[2]); return [v[0] * f, v[1] * f, v[2]]; };
  for (const p of parts) {
    const off = offsets.get(p.top) ?? [0, 0, 0];
    for (let i = 0; i < p.tris.length; i += 3) {
      const q = proj(view(p.tris[i] + off[0], p.tris[i + 1] + off[1], p.tris[i + 2] + off[2]));
      x0 = Math.min(x0, q[0]); x1 = Math.max(x1, q[0]); y0 = Math.min(y0, q[1]); y1 = Math.max(y1, q[1]);
    }
  }
  const pad = 14;
  const scale = Math.min((w - pad * 2 - marginX * 2) / (x1 - x0 || 1), (h - pad * 2) / (y1 - y0 || 1)) * SS;
  const ox = W / 2 - ((x0 + x1) / 2) * scale, oy = H / 2 + ((y0 + y1) / 2) * scale;

  const zbuf = new Float32Array(W * H).fill(-1e9);
  const idbuf = new Int32Array(W * H).fill(-1);
  const nbuf = new Float32Array(W * H * 3);
  const col = new Uint8ClampedArray(W * H * 4);

  const cutAxis = cut ? 'xyz'.indexOf(cut[0]) : -1;
  // `cut=z>0` removes everything with z > 0. Only `shell=1` parts are cut, if any
  // part has the flag, so the inside of a cutaway stays whole.
  const cutGreater = cut && cut[1] === '>';
  const cutVal = cut ? Number(cut.slice(2)) : 0;
  const anyShell = parts.some((p) => p.shell);
  const kept = (x, y, z) => (cutGreater ? [x, y, z][cutAxis] <= cutVal : [x, y, z][cutAxis] >= cutVal);

  const stats = parts.map(() => ({ px: 0, sx: 0, sy: 0 }));
  parts.forEach((part, pi) => {
    part.normals ??= smoothNormals(part.tris);
    const t = part.tris, N = part.normals;
    const off = offsets.get(part.top) ?? [0, 0, 0];
    const col0 = part.color;
    const glass = part.mat === 'glass';
    const cutHere = cutAxis >= 0 && (part.shell || !anyShell);
    const metal = part.mat === 'metal';
    const inner = col0.map((v) => v * 0.42);
    for (let f = 0; f < t.length; f += 9) {
      const pv = [], sc = [], nv = [], wp = [];
      for (let c = 0; c < 3; c++) {
        const o = f + c * 3;
        const wx = t[o], wy = t[o + 1], wz = t[o + 2];
        wp.push([wx, wy, wz]);
        const v = view(wx + off[0], wy + off[1], wz + off[2]);
        const q = proj(v);
        pv.push(v);
        sc.push([ox + q[0] * scale, oy - q[1] * scale, q[2]]);
        const nw = view(center[0] + N[o], center[1] + N[o + 1], center[2] + N[o + 2]);
        nv.push(nw);
      }
      const [a, b, c] = sc;
      const area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
      if (Math.abs(area) < 1e-6) continue;
      const back = area > 0; // screen Y points down
      if (back && !cutHere) continue;
      const bx0 = Math.max(0, Math.floor(Math.min(a[0], b[0], c[0])));
      const bx1 = Math.min(W - 1, Math.ceil(Math.max(a[0], b[0], c[0])));
      const by0 = Math.max(0, Math.floor(Math.min(a[1], b[1], c[1])));
      const by1 = Math.min(H - 1, Math.ceil(Math.max(a[1], b[1], c[1])));
      for (let y = by0; y <= by1; y++) {
        for (let x = bx0; x <= bx1; x++) {
          const px = x + 0.5, py = y + 0.5;
          const w0 = ((b[0] - px) * (c[1] - py) - (b[1] - py) * (c[0] - px)) / area;
          const w1 = ((c[0] - px) * (a[1] - py) - (c[1] - py) * (a[0] - px)) / area;
          const w2 = 1 - w0 - w1;
          if (w0 < 0 || w1 < 0 || w2 < 0) continue;
          if (glass && ((x + y * 3) % 5) < 3) continue;
          const z = w0 * a[2] + w1 * b[2] + w2 * c[2];
          const i = y * W + x;
          if (z <= zbuf[i]) continue;
          if (cutHere) {
            const wx = w0 * wp[0][0] + w1 * wp[1][0] + w2 * wp[2][0];
            const wy = w0 * wp[0][1] + w1 * wp[1][1] + w2 * wp[2][1];
            const wz = w0 * wp[0][2] + w1 * wp[1][2] + w2 * wp[2][2];
            if (!kept(wx, wy, wz)) continue;
          }
          zbuf[i] = z;
          idbuf[i] = pi;
          let nx = w0 * nv[0][0] + w1 * nv[1][0] + w2 * nv[2][0];
          let ny = w0 * nv[0][1] + w1 * nv[1][1] + w2 * nv[2][1];
          let nz = w0 * nv[0][2] + w1 * nv[1][2] + w2 * nv[2][2];
          const l = Math.hypot(nx, ny, nz) || 1;
          nx /= l; ny /= l; nz /= l;
          if (back) { nx = -nx; ny = -ny; nz = -nz; }
          nbuf[i * 3] = nx; nbuf[i * 3 + 1] = ny; nbuf[i * 3 + 2] = nz;
          const d = Math.max(0, nx * lightV[0] + ny * lightV[1] + nz * lightV[2]);
          let tone = 0.66 + 0.34 * smoothstep(0.12, 0.62, d);
          tone += 0.07 * (ny * 0.5 + 0.5);
          const base = back ? inner : col0;
          let r = base[0] * tone, g = base[1] * tone, bl = base[2] * tone;
          if (metal && !back) {
            const rz = 2 * nz * nz - 1; // reflection toward the viewer
            const band = smoothstep(0.55, 0.8, ny * 0.6 + rz * 0.4) * 0.28 - smoothstep(0.1, -0.5, ny) * 0.16;
            r += 255 * band * 0.6; g += 255 * band * 0.6; bl += 255 * band * 0.6;
          }
          col[i * 4] = r; col[i * 4 + 1] = g; col[i * 4 + 2] = bl; col[i * 4 + 3] = 255;
        }
      }
    }
  });

  // Edge lines.
  const edge = new Uint8Array(W * H);
  const depthTol = size * scale * 0.0;
  const dz = (size * 0.012);
  for (let y = 1; y < H - 1; y++) {
    for (let x = 1; x < W - 1; x++) {
      const i = y * W + x;
      const id = idbuf[i];
      let e = 0;
      for (const j of [i + 1, i + W]) {
        const o = idbuf[j];
        if (id < 0 && o < 0) continue;
        if (id !== o) { e = 1; continue; }
        if (Math.abs(zbuf[i] - zbuf[j]) > dz) { e = 1; continue; }
        const nd = nbuf[i * 3] * nbuf[j * 3] + nbuf[i * 3 + 1] * nbuf[j * 3 + 1] + nbuf[i * 3 + 2] * nbuf[j * 3 + 2];
        if (nd < 0.75) e = 1;
      }
      if (e) edge[i] = 1;
    }
  }

  // Downsample with lines drawn over the colour.
  const rgba = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy2 = 0; sy2 < SS; sy2++) {
        for (let sx2 = 0; sx2 < SS; sx2++) {
          const i = (y * SS + sy2) * W + x * SS + sx2;
          let cr = col[i * 4], cg = col[i * 4 + 1], cb = col[i * 4 + 2], ca = col[i * 4 + 3];
          if (edge[i] || edge[i - 1] || edge[i - W]) { cr = ink[0]; cg = ink[1]; cb = ink[2]; ca = 255; }
          r += cr * ca; g += cg * ca; b += cb * ca; a += ca;
        }
      }
      const o = (y * w + x) * 4;
      if (a) { rgba[o] = r / a; rgba[o + 1] = g / a; rgba[o + 2] = b / a; rgba[o + 3] = a / (SS * SS); }
    }
  }

  // Ground shadow: a blurred mask of the model, under it.
  const shadow = new Float32Array(w * h);
  for (let y = 0; y < H; y += 2) {
    for (let x = 0; x < W; x += 2) {
      if (idbuf[y * W + x] < 0) continue;
      const sx = Math.round(x / SS), sy2 = Math.round(y / SS + h * 0.03 + (h - y / SS) * 0.04);
      if (sx >= 0 && sx < w && sy2 >= 0 && sy2 < h) shadow[sy2 * w + sx] = 1;
    }
  }
  const blur = (src, rad) => {
    const tmp = new Float32Array(src.length), out = new Float32Array(src.length);
    for (let y = 0; y < h; y++) { let s = 0; for (let x = -rad; x < w; x++) { s += src[y * w + Math.min(w - 1, x + rad)] || 0; if (x - rad - 1 >= 0) s -= src[y * w + x - rad - 1]; if (x >= 0) tmp[y * w + x] = s / (2 * rad + 1); } }
    for (let x = 0; x < w; x++) { let s = 0; for (let y = -rad; y < h; y++) { s += tmp[Math.min(h - 1, y + rad) * w + x] || 0; if (y - rad - 1 >= 0) s -= tmp[(y - rad - 1) * w + x]; if (y >= 0) out[y * w + x] = s / (2 * rad + 1); } }
    return out;
  };
  const soft = blur(blur(shadow, 7), 7);
  for (let i = 0; i < w * h; i++) {
    const a0 = rgba[i * 4 + 3] / 255, sa = soft[i] * 0.2 * (1 - a0);
    const out = a0 + sa;
    if (out > 0) {
      for (let k = 0; k < 3; k++) rgba[i * 4 + k] = (rgba[i * 4 + k] * a0 + 40 * sa) / out;
      rgba[i * 4 + 3] = out * 255;
    }
  }

  // Part statistics in output pixels.
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const id = idbuf[y * W + x];
      if (id >= 0) { const s = stats[id]; s.px++; s.sx += x / SS; s.sy += y / SS; }
    }
  }
  return {
    rgba, w, h,
    stats: stats.map((s, i) => ({ id: parts[i].id, px: s.px / (SS * SS), x: s.px ? s.sx / s.px : 0, y: s.px ? s.sy / s.px : 0 })),
    idAt: (x, y) => { const v = idbuf[Math.round(y) * SS * W + Math.round(x) * SS]; return v >= 0 ? parts[v].id : null; },
    pixelsOf: (ids) => {
      const set = new Set(ids); const out = [];
      for (let y = 0; y < H; y += 4) for (let x = 0; x < W; x += 4) { const v = idbuf[y * W + x]; if (v >= 0 && set.has(v)) out.push([x / SS, y / SS]); }
      return out;
    },
  };
}

// Parts that touch nothing else. This finds floating geometry for the model.
export function floatingParts(parts) {
  const boxes = parts.map((p) => {
    const b = [1e9, 1e9, 1e9, -1e9, -1e9, -1e9];
    for (let i = 0; i < p.tris.length; i += 3) for (let k = 0; k < 3; k++) { b[k] = Math.min(b[k], p.tris[i + k]); b[k + 3] = Math.max(b[k + 3], p.tris[i + k]); }
    return b;
  });
  const size = Math.max(...boxes.map((b) => Math.max(b[3] - b[0], b[4] - b[1], b[5] - b[2])), 1e-6);
  const tol = size * 0.01;
  const touch = (a, b) => [0, 1, 2].every((k) => a[k] <= b[k + 3] + tol && b[k] <= a[k + 3] + tol);
  const seen = new Set();
  const groups = [];
  parts.forEach((_, i) => {
    if (seen.has(i)) return;
    const g = [];
    const st = [i];
    seen.add(i);
    while (st.length) {
      const c = st.pop();
      g.push(c);
      parts.forEach((__, j) => { if (!seen.has(j) && touch(boxes[c], boxes[j])) { seen.add(j); st.push(j); } });
    }
    groups.push(g);
  });
  groups.sort((a, b) => b.length - a.length);
  return groups.slice(1).flat().map((i) => parts[i].id);
}

export function encodePng(rgba, w, h) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1);
  }
  const table = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
  const crc = (buf) => { let c = -1; for (const b of buf) c = table[(c ^ b) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0))]);
}
