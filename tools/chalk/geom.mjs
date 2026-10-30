// 3D catalogue: every shape is one line in the format and becomes triangles.
// Parametric generators (fan, gear, chip...) give real detail for a few tokens.
import { nums, points } from './parse.mjs';

export const COLORS3D = {
  steel: '#aeb6bf', alu: '#d5dade', darkmetal: '#5a6068', titanium: '#8c8f94',
  copper: '#c9794a', gold: '#d9b24a', brass: '#c7a64f', black: '#2a2c30',
  white: '#f2f1ec', gray: '#9aa0a6', dark: '#3f4347', rubber: '#26272a',
  plastic: '#d8d6d0', pcb: '#2f8f5b', red: '#d9534f', orange: '#ee8f3a',
  yellow: '#f2c94c', green: '#59b36b', blue: '#4a90d9', sky: '#8fc7ee',
  navy: '#27415f', purple: '#8a6fd1', pink: '#ec8fb0', teal: '#3fb3a6',
  brown: '#8a5a3c', wood: '#c49a6c', skin: '#e8b998', glass: '#bfe3f2',
  camo: '#7c8a86', jetgray: '#8f979e',
};

const PARAMS = {
  box: ['size'], cyl: ['r', 'h', 'r2', 'axis', 'hole'], cone: ['r', 'h', 'axis'], sphere: ['r', 'scale3'],
  lathe: ['pts', 'axis', 'smooth'], extrude: ['pts', 'h', 'axis'], loft: ['sections', 'axis', 'square'],
  tube: ['pts', 'r', 'flat'], fan: ['blades', 'r', 'hub', 'h', 'axis', 'twist'],
  gear: ['teeth', 'r', 'h', 'axis'], spring: ['r', 'wire', 'turns', 'h', 'axis'],
  chip: ['size', 'pins'], header: ['n', 'rows', 'pitch', 'pinh'], screw: ['r', 'h'],
  wheel: ['r', 'w', 'axis'], port: ['type', 'size'], limb: ['pts'],
};
export const SHAPES = new Set(Object.keys(PARAMS));
const COMMON = new Set(['id', 'at', 'rot', 'scale', 'color', 'mat', 'label', 'seg', 'shell']);

export function shapeKeys(cmd) { return PARAMS[cmd]; }
export function isCommon(k) { return COMMON.has(k); }

class Mesh {
  constructor() { this.t = []; }
  tri(a, b, c) { this.t.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]); }
  quad(a, b, c, d) { this.tri(a, b, c); this.tri(a, c, d); }
  add(o) { for (const v of o.t) this.t.push(v); return this; }
  map(f) {
    for (let i = 0; i < this.t.length; i += 3) {
      const p = f([this.t[i], this.t[i + 1], this.t[i + 2]]);
      this.t[i] = p[0]; this.t[i + 1] = p[1]; this.t[i + 2] = p[2];
    }
    return this;
  }
}

// Profile is [along, radius] around Y.
function revolve(profile, seg) {
  const m = new Mesh();
  const ring = (y, r, a) => [Math.cos(a) * r, y, -Math.sin(a) * r];
  for (let i = 0; i + 1 < profile.length; i++) {
    const [y0, r0] = profile[i], [y1, r1] = profile[i + 1];
    for (let s = 0; s < seg; s++) {
      const a0 = (s / seg) * Math.PI * 2, a1 = ((s + 1) / seg) * Math.PI * 2;
      m.quad(ring(y0, r0, a0), ring(y0, r0, a1), ring(y1, r1, a1), ring(y1, r1, a0));
    }
  }
  const capProfile = (y, r) => {
    if (r <= 1e-6) return;
    for (let s = 0; s < seg; s++) {
      const a0 = (s / seg) * Math.PI * 2, a1 = ((s + 1) / seg) * Math.PI * 2;
      m.tri([0, y, 0], ring(y, r, a0), ring(y, r, a1));
    }
  };
  capProfile(...profile[0]);
  capProfile(...profile.at(-1));
  return m;
}

const axisTo = (axis) => {
  if (axis === 'x') return ([x, y, z]) => [y, x, z];
  if (axis === 'z') return ([x, y, z]) => [x, z, y];
  return (p) => p;
};

function box([w, h, d]) {
  const m = new Mesh();
  const X = w / 2, Y = h / 2, Z = d / 2;
  const v = (a, b, c) => [a * X, b * Y, c * Z];
  m.quad(v(-1, -1, 1), v(1, -1, 1), v(1, 1, 1), v(-1, 1, 1));
  m.quad(v(1, -1, -1), v(-1, -1, -1), v(-1, 1, -1), v(1, 1, -1));
  m.quad(v(-1, 1, 1), v(1, 1, 1), v(1, 1, -1), v(-1, 1, -1));
  m.quad(v(-1, -1, -1), v(1, -1, -1), v(1, -1, 1), v(-1, -1, 1));
  m.quad(v(1, -1, 1), v(1, -1, -1), v(1, 1, -1), v(1, 1, 1));
  m.quad(v(-1, -1, -1), v(-1, -1, 1), v(-1, 1, 1), v(-1, 1, -1));
  return m;
}

function earclip(poly) {
  let area = 0;
  poly.forEach((p, i) => { const q = poly[(i + 1) % poly.length]; area += p[0] * q[1] - q[0] * p[1]; });
  const idx = poly.map((_, i) => i);
  if (area < 0) idx.reverse();
  const out = [];
  const cross = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
  let guard = idx.length * idx.length + 8;
  while (idx.length > 3 && guard-- > 0) {
    let clipped = false;
    for (let i = 0; i < idx.length; i++) {
      const ia = idx[(i + idx.length - 1) % idx.length], ib = idx[i], ic = idx[(i + 1) % idx.length];
      const a = poly[ia], b = poly[ib], c = poly[ic];
      if (cross(a, b, c) <= 1e-12) continue;
      const inside = idx.some((j) => {
        if (j === ia || j === ib || j === ic) return false;
        const p = poly[j];
        return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0;
      });
      if (inside) continue;
      out.push([ia, ib, ic]);
      idx.splice(i, 1);
      clipped = true;
      break;
    }
    if (!clipped) break;
  }
  if (idx.length === 3) out.push(idx.slice());
  return out;
}

// Polygon in the XZ plane, thickness along Y.
function extrude(poly, h) {
  const m = new Mesh();
  const t = earclip(poly);
  const top = (p) => [p[0], h / 2, p[1]], bot = (p) => [p[0], -h / 2, p[1]];
  for (const [a, b, c] of t) {
    m.tri(top(poly[a]), top(poly[c]), top(poly[b]));
    m.tri(bot(poly[a]), bot(poly[b]), bot(poly[c]));
  }
  poly.forEach((p, i) => {
    const q = poly[(i + 1) % poly.length];
    m.quad(top(p), top(q), bot(q), bot(p));
  });
  return m;
}

const catmull = (a, b, c, d, t) => 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t);

function smoothRows(rows, sub = 5) {
  const out = [];
  for (let i = 0; i + 1 < rows.length; i++) {
    const a = rows[Math.max(0, i - 1)], b = rows[i], c = rows[i + 1], d = rows[Math.min(rows.length - 1, i + 2)];
    for (let s = 0; s < sub; s++) {
      out.push(b.map((_, k) => Math.max(k === 0 ? -Infinity : 0, catmull(a[k] ?? b[k], b[k], c[k], d[k] ?? c[k], s / sub))));
    }
  }
  out.push(rows.at(-1));
  return out;
}

// Sections are pos,width,height[,yoffset]. Gives fuselages, hulls, bodies.
function loft(sections, seg, square) {
  const rows = smoothRows(sections.map((s) => [s[0], s[1], s[2], (s[3] ?? 0) + 1000])).map((r) => [r[0], r[1], r[2], r[3] - 1000]);
  const e = square ? 0.4 : 1;
  const ring = (r, a) => {
    const c = Math.cos(a), s = Math.sin(a);
    return [r[0], r[3] + (Math.sign(s) * Math.abs(s) ** e * r[2]) / 2, (Math.sign(c) * Math.abs(c) ** e * r[1]) / 2];
  };
  const m = new Mesh();
  for (let i = 0; i + 1 < rows.length; i++) {
    for (let k = 0; k < seg; k++) {
      const a0 = (k / seg) * Math.PI * 2, a1 = ((k + 1) / seg) * Math.PI * 2;
      m.quad(ring(rows[i], a0), ring(rows[i + 1], a0), ring(rows[i + 1], a1), ring(rows[i], a1));
    }
  }
  for (const r of [rows[0], rows.at(-1)]) {
    if (r[1] < 1e-5 && r[2] < 1e-5) continue;
    const c = [r[0], r[3], 0];
    for (let k = 0; k < seg; k++) {
      m.tri(c, ring(r, (k / seg) * Math.PI * 2), ring(r, ((k + 1) / seg) * Math.PI * 2));
    }
  }
  return m;
}

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const crossv = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = (a) => { const l = Math.hypot(...a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

function tube(pts, r, seg, flat = 1, smooth = true) {
  const path = smooth && pts.length > 2 ? smoothRows(pts.map((p) => [p[0], p[1] + 1e4, p[2] + 1e4]), 6).map((p) => [p[0], p[1] - 1e4, p[2] - 1e4]) : pts;
  const m = new Mesh();
  let up = [0, 1, 0];
  let prev = null;
  path.forEach((p, i) => {
    const t = norm(sub(path[Math.min(i + 1, path.length - 1)], path[Math.max(i - 1, 0)]));
    if (Math.abs(dot(up, t)) > 0.95) up = [1, 0, 0];
    const u = norm(crossv(t, up));
    const v = norm(crossv(u, t));
    up = v;
    const ring = [];
    for (let k = 0; k < seg; k++) {
      const a = (k / seg) * Math.PI * 2;
      const cu = Math.cos(a) * r * flat, cv = Math.sin(a) * r;
      ring.push([p[0] + u[0] * cu + v[0] * cv, p[1] + u[1] * cu + v[1] * cv, p[2] + u[2] * cu + v[2] * cv]);
    }
    if (prev) for (let k = 0; k < seg; k++) m.quad(prev[k], prev[(k + 1) % seg], ring[(k + 1) % seg], ring[k]);
    else for (let k = 1; k + 1 < seg; k++) m.tri(ring[0], ring[k + 1], ring[k]);
    prev = ring;
  });
  for (let k = 1; k + 1 < seg; k++) m.tri(prev[0], prev[k], prev[k + 1]);
  return m;
}

// Tube with a radius at each point: limbs, vessels, branches, tails, necks.
function limb(pts, seg) {
  const rows = smoothRows(pts.map((p) => [p[0] + 1e4, p[1] + 1e4, p[2] + 1e4, p[3]]), 6).map((p) => [p[0] - 1e4, p[1] - 1e4, p[2] - 1e4, p[3]]);
  const m = new Mesh();
  let up = [0, 1, 0], prev = null;
  rows.forEach((p, i) => {
    const t = norm(sub(rows[Math.min(i + 1, rows.length - 1)], rows[Math.max(i - 1, 0)]));
    if (Math.abs(dot(up, t)) > 0.95) up = [1, 0, 0];
    const u = norm(crossv(t, up)), v = norm(crossv(u, t));
    up = v;
    const ring = [];
    for (let k = 0; k < seg; k++) {
      const a = (k / seg) * Math.PI * 2, cu = Math.cos(a) * p[3], cv = Math.sin(a) * p[3];
      ring.push([p[0] + u[0] * cu + v[0] * cv, p[1] + u[1] * cu + v[1] * cv, p[2] + u[2] * cu + v[2] * cv]);
    }
    if (prev) for (let k = 0; k < seg; k++) m.quad(prev[k], prev[(k + 1) % seg], ring[(k + 1) % seg], ring[k]);
    else for (let k = 1; k + 1 < seg; k++) m.tri(ring[0], ring[k + 1], ring[k]);
    prev = ring;
  });
  for (let k = 1; k + 1 < seg; k++) m.tri(prev[0], prev[k], prev[k + 1]);
  return m;
}

// Connector on a circuit board. The opening faces +Z.
function port(type, scale) {
  const dims = {
    usb: [1.3, 1.45, 1.4, '#c8ccd0'], usbc: [0.9, 0.32, 0.75, '#c8ccd0'], hdmi: [1.45, 0.35, 0.75, '#c8ccd0'],
    ethernet: [1.6, 1.35, 2.1, '#c8ccd0'], jack: [0.6, 0.6, 1.2, '#222222'], sd: [1.2, 0.15, 1.4, '#c8ccd0'],
    fpc: [2.2, 0.28, 0.45, '#efe9dc'], power: [0.9, 1.0, 1.4, '#222222'],
  }[type] ?? [1, 0.5, 1];
  const [w, h, d] = dims.slice(0, 3).map((v) => v * scale);
  const m = box([w, h, d]);
  m.add(box([w * 0.8, h * 0.68, d * 0.03]).map(([x, y, z]) => [x, y, z + d / 2 + d * 0.015]));
  return m;
}

function fan(blades, r, hub, h, twist) {
  const m = revolve([[-h / 2, 0], [-h / 2, hub * 0.55], [-h * 0.1, hub], [h / 2, hub], [h / 2, 0]], 32);
  for (let b = 0; b < blades; b++) {
    const a = (b / blades) * Math.PI * 2;
    const blade = new Mesh();
    const steps = 6;
    const chord = Math.min((2 * Math.PI * r / blades) * 0.8, r * 0.24);
    const t = 0.012 * r;
    const sect = (i) => {
      const f = i / steps, rad = hub + (r - hub) * f;
      const ang = twist * (1 - f * 0.6);
      const c = chord * (0.75 + 0.35 * f) / 2, cy = Math.cos(ang) * c, cz = Math.sin(ang) * c;
      return [[rad, -cy, -cz], [rad, -t, t], [rad, cy, cz], [rad, t, -t]];
    };
    for (let i = 0; i < steps; i++) {
      const p = sect(i), q = sect(i + 1);
      for (let k = 0; k < 4; k++) blade.quad(p[k], q[k], q[(k + 1) % 4], p[(k + 1) % 4]);
    }
    const end = sect(steps);
    blade.quad(end[0], end[1], end[2], end[3]);
    m.add(blade.map(([x, y, z]) => [Math.cos(a) * x + Math.sin(a) * z, y, -Math.sin(a) * x + Math.cos(a) * z]));
  }
  return m;
}

function gear(teeth, r, h) {
  const poly = [];
  const root = r * 0.84, n = teeth * 4;
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2;
    const R = i % 4 === 1 || i % 4 === 2 ? r : root;
    poly.push([Math.cos(a) * R, Math.sin(a) * R]);
  }
  return extrude(poly, h);
}

function spring(r, wire, turns, h) {
  const pts = [];
  const n = Math.round(turns * 18);
  for (let i = 0; i <= n; i++) {
    const a = (i / n) * turns * Math.PI * 2;
    pts.push([Math.cos(a) * r, (i / n - 0.5) * h, Math.sin(a) * r]);
  }
  return tube(pts, wire, 8, 1, false);
}

function chip([w, h, d], pins) {
  const m = box([w, h, d]);
  const pw = Math.min(w, d) * 0.05;
  const count = pins;
  for (let i = 0; i < count; i++) {
    const f = (i + 0.5) / count - 0.5;
    for (const s of [-1, 1]) {
      m.add(box([pw * 2, h * 0.25, pw]).map(([x, y, z]) => [x + s * (w / 2 + pw), y - h * 0.3, z + f * d * 0.92]));
      m.add(box([pw, h * 0.25, pw * 2]).map(([x, y, z]) => [x + f * w * 0.92, y - h * 0.3, z + s * (d / 2 + pw)]));
    }
  }
  return m;
}

function header(n, rows, pitch, pinh) {
  const m = new Mesh();
  m.add(box([n * pitch, pitch * 0.9, rows * pitch]));
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < rows; j++) {
      const x = (i - (n - 1) / 2) * pitch, z = (j - (rows - 1) / 2) * pitch;
      m.add(box([pitch * 0.25, pinh, pitch * 0.25]).map(([a, b, c]) => [a + x, b + pinh / 2, c + z]));
    }
  }
  return m;
}

function screw(r, h, seg) {
  const m = revolve([[0, r * 0.55], [h, r * 0.55]], seg);
  m.add(revolve([[h, r], [h + r * 0.7, r]], 6));
  return m;
}

function wheel(r, w, seg) {
  const hw = w / 2;
  const m = revolve([[-hw, r * 0.72], [-hw * 1.02, r * 0.92], [-hw * 0.7, r], [hw * 0.7, r], [hw * 1.02, r * 0.92], [hw, r * 0.72]], seg);
  return m;
}

export function buildShape(node) {
  const { cmd, kv } = node;
  const seg = Number(kv.seg ?? 32);
  const n = (k, d) => (kv[k] === undefined ? d : Number(kv[k]));
  const ax = axisTo(kv.axis);
  switch (cmd) {
    case 'box': return box(nums(kv.size, [1, 1, 1]));
    case 'cyl': {
      const r = n('r', 0.5), h = n('h', 1), r2 = n('r2', r), hole = n('hole', 0);
      const prof = hole
        ? [[-h / 2, hole], [-h / 2, r], [h / 2, r2], [h / 2, hole], [-h / 2, hole]]
        : [[-h / 2, r], [h / 2, r2]];
      return revolve(prof, seg).map(ax);
    }
    case 'cone': return revolve([[-n('h', 1) / 2, n('r', 0.5)], [n('h', 1) / 2, 0]], seg).map(ax);
    case 'sphere': {
      const r = n('r', 0.5), p = [];
      for (let i = 0; i <= 16; i++) { const a = (i / 16) * Math.PI - Math.PI / 2; p.push([Math.sin(a) * r, Math.cos(a) * r]); }
      return revolve(p, seg);
    }
    case 'lathe': {
      let p = points(kv.pts);
      if (kv.smooth) p = smoothRows(p, 5);
      return revolve(p, seg).map(ax);
    }
    case 'extrude': return extrude(points(kv.pts), n('h', 0.1)).map(ax);
    case 'loft': {
      const m = loft(points(kv.sections), seg, kv.square);
      if (kv.axis === 'y') return m.map(([x, y, z]) => [y, x, z]);
      if (kv.axis === 'z') return m.map(([x, y, z]) => [z, y, x]);
      return m;
    }
    case 'tube': return tube(points(kv.pts), n('r', 0.05), Number(kv.seg ?? 12), n('flat', 1));
    case 'fan': return fan(n('blades', 16), n('r', 1), n('hub', 0.3), n('h', 0.3), n('twist', 0.8)).map(ax);
    case 'gear': return gear(n('teeth', 16), n('r', 1), n('h', 0.2)).map(ax);
    case 'spring': return spring(n('r', 0.3), n('wire', 0.04), n('turns', 6), n('h', 1)).map(ax);
    case 'chip': return chip(nums(kv.size, [1, 0.15, 1]), n('pins', 8));
    case 'header': return header(n('n', 10), n('rows', 2), n('pitch', 0.254), n('pinh', 0.6));
    case 'screw': return screw(n('r', 0.15), n('h', 0.6), 16);
    case 'port': return port(kv.type, n('size', 1));
    case 'limb': return limb(points(kv.pts), Number(kv.seg ?? 18));
    case 'wheel': return wheel(n('r', 1), n('w', 0.4), seg).map(ax);
    default: return null;
  }
}
