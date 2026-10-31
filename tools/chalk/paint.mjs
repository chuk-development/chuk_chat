// Surface work on finished meshes. These commands follow the real curved skin:
//   paint hull color=#111 mat=glass box=x0,y0,z0,x1,y1,z1   a zone in a box
//   paint hull color=#fff plane=0,1,0,1.2                   where n.p > d
//   paint hull color=#111 poly=x,y x,y ... axis=z both=1    a window, seen along an axis
//   seam hull plane=1,0,0,2.1 w=0.012                       a panel line
//   decal hull "Text" at=x,y axis=z h=0.3 color=#fff        printed text on the skin
// Keys combine: all of them must hold. both=1 also does the mirror side (z to -z).
import { nums, points } from './parse.mjs';
import { smoothNormals } from './raster.mjs';

function smooth(p) {
  if (p.length < 4) return p;
  const out = [];
  for (let i = 0; i < p.length; i++) {
    const [a, b, c, d] = [p[(i - 1 + p.length) % p.length], p[i], p[(i + 1) % p.length], p[(i + 2) % p.length]];
    for (let k = 0; k < 6; k++) {
      const t = k / 6, t2 = t * t, t3 = t2 * t;
      out.push([0, 1].map((j) => 0.5 * (2 * b[j] + (c[j] - a[j]) * t + (2 * a[j] - 5 * b[j] + 4 * c[j] - d[j]) * t2 + (3 * b[j] - a[j] - 3 * c[j] + d[j]) * t3)));
    }
  }
  return out;
}

function ear(poly) {
  const area = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
  let s = 0;
  poly.forEach((p, i) => { const q = poly[(i + 1) % poly.length]; s += p[0] * q[1] - q[0] * p[1]; });
  const v = s > 0 ? poly.slice() : poly.slice().reverse();
  const out = [];
  let guard = v.length * v.length + 10;
  while (v.length > 3 && guard-- > 0) {
    for (let i = 0; i < v.length; i++) {
      const a = v[(i - 1 + v.length) % v.length], b = v[i], c = v[(i + 1) % v.length];
      if (area(a, b, c) <= 1e-12) continue;
      if (v.some((p) => p !== a && p !== b && p !== c && area(a, b, p) >= 0 && area(b, c, p) >= 0 && area(c, a, p) >= 0)) continue;
      out.push([a, b, c]); v.splice(i, 1); break;
    }
  }
  if (v.length === 3) out.push(v);
  return out;
}

// One convex cell is a list of half spaces [nx, ny, nz, d] with n.p >= d.
function cells(k) {
  const base = [];
  if (k.box) { const b = nums(k.box); for (let c = 0; c < 3; c++) { const n = [0, 0, 0]; n[c] = 1; base.push([...n, b[c]]); n[c] = -1; base.push([...n, -b[c + 3]]); } }
  for (const key of ['plane', 'plane2', 'plane3']) if (k[key]) { const p = nums(k[key]), l = Math.hypot(p[0], p[1], p[2]) || 1; base.push([p[0] / l, p[1] / l, p[2] / l, p[3] / l]); }
  if (!k.poly) return [base];
  const axis = 'xyz'.indexOf(k.axis ?? 'z'), [u, v] = [0, 1, 2].filter((c) => c !== axis);
  const pts = k.sharp ? points(k.poly) : smooth(points(k.poly));
  return ear(pts).map((tri) => {
    let s = 0;
    tri.forEach((p, i) => { const q = tri[(i + 1) % 3]; s += p[0] * q[1] - q[0] * p[1]; });
    const list = base.slice();
    tri.forEach((p, i) => {
      const q = tri[(i + 1) % 3], ex = q[0] - p[0], ey = q[1] - p[1], l = Math.hypot(ex, ey) || 1;
      const n = [0, 0, 0], sign = s > 0 ? 1 : -1;
      n[u] = (-ey / l) * sign; n[v] = (ex / l) * sign;
      list.push([...n, n[u] * p[0] + n[v] * p[1]]);
    });
    return list;
  });
}

function clip(poly, [a, b, c, d]) {
  const out = [];
  for (let i = 0; i < poly.length; i++) {
    const p = poly[i], q = poly[(i + 1) % poly.length];
    const dp = a * p[0] + b * p[1] + c * p[2] - d, dq = a * q[0] + b * q[1] + c * q[2] - d;
    if (dp >= 0) out.push(p);
    if (dp * dq < 0) { const t = dp / (dp - dq); out.push(p.map((v, k) => v + (q[k] - v) * t)); }
  }
  return out;
}

// Area test: a sliver on a plane must not count as a piece, or pieces multiply.
function solid(p) {
  if (p.length < 3) return false;
  let x = 0, y = 0, z = 0;
  const o = p[0];
  for (let i = 1; i + 1 < p.length; i++) {
    const a = [p[i][0] - o[0], p[i][1] - o[1], p[i][2] - o[2]], b = [p[i + 1][0] - o[0], p[i + 1][1] - o[1], p[i + 1][2] - o[2]];
    x += a[1] * b[2] - a[2] * b[1]; y += a[2] * b[0] - a[0] * b[2]; z += a[0] * b[1] - a[1] * b[0];
  }
  return x * x + y * y + z * z > 1e-14;
}

// Splits the part into what lies in the cells and the rest. Normals are carried over.
function split(part, cellList, keepRest = true) {
  const T = part.tris, N = (part.normals ??= smoothNormals(T));
  const inT = [], inN = [], outT = [], outN = [];
  const emit = (poly, tt, nn) => { for (let i = 1; i + 1 < poly.length; i++) for (const v of [poly[0], poly[i], poly[i + 1]]) { tt.push(v[0], v[1], v[2]); nn.push(v[3], v[4], v[5]); } };
  for (let f = 0; f < T.length; f += 9) {
    let rest = [[0, 1, 2].map((c) => [T[f + c * 3], T[f + c * 3 + 1], T[f + c * 3 + 2], N[f + c * 3], N[f + c * 3 + 1], N[f + c * 3 + 2]])];
    for (const cell of cellList) {
      const next = [];
      for (const start of rest) {
        let inside = start, leftover = [];
        for (const h of cell) {
          if (!inside.length) break;
          const off = clip(inside, [-h[0], -h[1], -h[2], -h[3]]);
          if (solid(off)) leftover.push(off);
          inside = clip(inside, h);
          if (!solid(inside)) inside = [];
        }
        // A polygon that misses this cell stays whole. Only real borders cut it.
        if (inside.length > 2) { emit(inside, inT, inN); next.push(...leftover); } else next.push(start);
      }
      rest = next;
    }
    if (keepRest) for (const poly of rest) emit(poly, outT, outN);
  }
  return { inT: new Float32Array(inT), inN: new Float32Array(inN), outT: new Float32Array(outT), outN: new Float32Array(outN) };
}

const mirrorCell = (cell) => cell.map(([a, b, c, d]) => [a, b, -c, d]);

export function applySurface(parts, ops, hex, errors) {
  for (const op of ops) {
    const id = op.args[0];
    const list = id === '*' ? parts.slice() : parts.filter((p) => p.path.includes(id) && !p.decal);
    if (!list.length) { errors.push(`line ${op.line}: ${op.cmd}: no part "${id}"`); continue; }
    const k = op.kv;
    if (op.cmd === 'decal') { decal(parts, list, op, hex, errors); continue; }
    let cl;
    if (op.cmd === 'seam') {
      const p = nums(k.plane), l = Math.hypot(p[0], p[1], p[2]) || 1, w = Number(k.w ?? 0.01) / 2;
      const n = [p[0] / l, p[1] / l, p[2] / l], d = p[3] / l;
      cl = cells({ ...k, plane: undefined, poly: undefined }).map((c) => [...c, [...n, d - w], [-n[0], -n[1], -n[2], -d - w]]);
    } else cl = cells(k);
    if (k.both) cl = [...cl, ...cl.map(mirrorCell)];
    const color = op.cmd === 'seam' ? hex(k.color ?? '#14161a') : hex(k.color ?? 'dark');
    for (const part of list) {
      const r = split(part, cl);
      if (!r.inT.length) continue;
      part.tris = r.outT; part.normals = r.outN;
      parts.push({ ...part, id: `${part.id}~${op.line}`, tris: r.inT, normals: r.inN, color, colorName: k.color ?? (op.cmd === 'seam' ? 'dark' : part.colorName), mat: k.mat ?? (op.cmd === 'seam' ? 'matte' : part.mat), label: null, painted: true });
    }
  }
  for (let i = parts.length - 1; i >= 0; i--) if (!parts[i].tris.length) parts.splice(i, 1);
}

function decal(parts, list, op, hex, errors) {
  const k = op.kv, text = op.args[1] ?? k.text ?? '', axis = 'xyz'.indexOf(k.axis ?? 'z');
  const at = nums(k.at), h = Number(k.h ?? 0.2), [u, v] = axis === 1 ? [0, 2] : axis === 0 ? [2, 1] : [0, 1];
  const aspect = Math.max(0.6, text.length * Number(k.wide ?? 0.58));
  const w = Number(k.w ?? h * aspect);
  const sides = k.both ? [1, -1] : [Number(k.side ?? 1)];
  for (const side of sides) {
    // Text reads left to right when seen from outside.
    const flip = (axis === 2 && side < 0) || (axis === 0 && side > 0);
    const b = [-1e6, -1e6, -1e6, 1e6, 1e6, 1e6];
    b[u] = at[0] - w / 2; b[u + 3] = at[0] + w / 2; b[v] = at[1] - h / 2; b[v + 3] = at[1] + h / 2;
    for (const part of list) {
      const r = split(part, cells({ box: b.join(',') }), false);
      const pos = [], nor = [], uv = [];
      for (let f = 0; f < r.inT.length; f += 9) {
        // Keep only faces that look to this side.
        if ((r.inN[f + axis] + r.inN[f + 3 + axis] + r.inN[f + 6 + axis]) * side < 0.3) continue;
        for (let c = 0; c < 3; c++) {
          const o = f + c * 3;
          pos.push(r.inT[o], r.inT[o + 1], r.inT[o + 2]);
          nor.push(r.inN[o], r.inN[o + 1], r.inN[o + 2]);
          const s = (r.inT[o + u] - at[0]) / w + 0.5, t = (r.inT[o + v] - at[1]) / h + 0.5;
          uv.push(flip ? 1 - s : s, axis === 1 ? 1 - t : t);
        }
      }
      if (pos.length) parts.push({ ...part, id: `${part.id}~d${op.line}`, tris: new Float32Array(pos), normals: new Float32Array(nor), uv: new Float32Array(uv), decal: { text, color: k.color ?? '#ffffff', bold: !!k.bold, aspect: w / h }, label: null, noSnap: true });
    }
  }
}
