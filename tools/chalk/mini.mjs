#!/usr/bin/env node
// mini <in.mini> <out.chalk>: a small kit that cannot fail. The model names parts and how they
// connect. The engine finds every position, ratio, layer, frame and camera. See PROMPT_MINI.md.
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const rad = (d) => d * Math.PI / 180;
const f = (...v) => v.map((x) => Number(x.toFixed(4))).join(',');
const GEAR = 0.1;      // module: a gear with 20 teeth has r=1
const DEPTH = 0.3;     // thickness of a wheel
const LAYER = 0.42;    // distance between layers in front of the back plate
const COLORS = ['#c9a24b', '#b5461f', '#3f7fb5', '#5a9e6f', '#b9b090', '#8a6fb0'];

export function parseMini(src) {
  const items = [], steps = [], errors = [];
  let title = 'Machine';
  src.split('\n').forEach((raw, i) => {
    const line = raw.replace(/#(?![0-9a-fA-F]{6}\b).*$/, '').trim();
    if (!line) return;
    const quoted = line.match(/"([^"]*)"/)?.[1];
    const words = line.replace(/"[^"]*"/, '').trim().split(/\s+/);
    const kv = {}, args = [];
    for (const w of words.slice(1)) { const m = w.match(/^(\w+)=(.*)$/); if (m) kv[m[1]] = m[2]; else args.push(w); }
    const cmd = words[0];
    if (cmd === 'title') title = quoted ?? title;
    else if (cmd === 'step') steps.push({ text: quoted ?? '', on: kv.on, line: i + 1 });
    else if (['wheel', 'gear', 'piston', 'block'].includes(cmd)) items.push({ cmd, id: args[0], kv, line: i + 1 });
    else errors.push(`line ${i + 1}: unknown word "${cmd}". Use only title, wheel, gear, piston, block, step`);
  });
  return { title, items, steps, errors };
}

// Places all parts. Returns errors in words the model can act on.
export function layout({ items, errors }) {
  const byId = new Map();
  let next = 0;
  for (const p of items) {
    const need = (k) => { if (p.kv[k] === undefined) { errors.push(`line ${p.line}: ${p.cmd} ${p.id} needs ${k}=`); return false; } return true; };
    if (!p.id || byId.has(p.id)) { errors.push(`line ${p.line}: ${p.cmd} needs a new, unique id`); continue; }
    p.color = p.kv.color ?? COLORS[next++ % COLORS.length];
    p.dir = Number(p.kv.dir ?? 0);
    if (p.cmd === 'block') {
      const [w, h] = String(p.kv.size ?? '2,1').split(',').map(Number);
      p.w = w; p.h = h;
      const base = byId.get(p.kv.on);
      if (p.kv.on && !base) { errors.push(`line ${p.line}: block ${p.id}: no part "${p.kv.on}" above this line`); continue; }
      if (base) {
        const bw = base.w ?? base.r * 2, bh = base.h ?? base.r * 2;
        const s = { top: [0, (bh + h) / 2], bottom: [0, -(bh + h) / 2], left: [-(bw + w) / 2, 0], right: [(bw + w) / 2, 0] }[p.kv.side ?? 'top'] ?? [0, (bh + h) / 2];
        p.x = base.x + s[0]; p.y = base.y + s[1];
      } else [p.x, p.y] = String(p.kv.at ?? '0,0').split(',').map(Number);
      byId.set(p.id, p);
      continue;
    }
    if (p.cmd === 'piston') {
      const w = byId.get(p.kv.to);
      if (!w || !w.rotor) { errors.push(`line ${p.line}: piston ${p.id}: to= must name a wheel or gear above this line`); continue; }
      p.wheel = w;
      p.s = w.r * 0.6; p.bore = Math.max(0.3, w.r * 0.6);
      p.L = w.r + p.s + p.bore / 2 + 0.25;
      const far = p.L + p.s * 2 + p.bore;
      p.x = w.x + far * Math.cos(rad(p.dir)); p.y = w.y + far * Math.sin(rad(p.dir)); p.w = p.bore; p.h = p.bore;
      byId.set(p.id, p);
      continue;
    }
    p.rotor = true;
    if (p.cmd === 'gear') { if (!need('teeth')) continue; p.teeth = Number(p.kv.teeth); p.r = GEAR * p.teeth / 2; }
    else { if (!need('r')) continue; p.r = Number(p.kv.r); }
    const to = byId.get(p.kv.to);
    if (p.kv.to && !to?.rotor) { errors.push(`line ${p.line}: ${p.id}: to= must name a wheel or gear above this line`); continue; }
    if (!to) {
      [p.x, p.y] = String(p.kv.at ?? '0,0').split(',').map(Number);
      p.layer = 0; p.ratio = 1; p.rho = 0;
    } else {
      const by = p.kv.by ?? (p.cmd === 'gear' ? 'mesh' : 'belt');
      p.by = by; p.parent = to;
      if (by === 'mesh') {
        if (p.cmd !== 'gear' || to.cmd !== 'gear') { errors.push(`line ${p.line}: by=mesh needs two gears`); continue; }
        const d = to.r + p.r, phi = rad(p.dir);
        p.x = to.x + d * Math.cos(phi); p.y = to.y + d * Math.sin(phi); p.layer = to.layer;
        p.ratio = -to.teeth / p.teeth;
        p.rho = phi + Math.PI - (2 * Math.PI / p.teeth) * (0.5 - ((phi - to.rho) * to.teeth) / (2 * Math.PI));
      } else if (by === 'axle') {
        p.x = to.x; p.y = to.y; p.layer = to.layer + 1; p.ratio = 1; p.rho = 0;
      } else if (by === 'belt' || by === 'chain') {
        const dist = Number(p.kv.dist ?? (to.r + p.r) * 1.8);
        if (dist < to.r + p.r + 0.1) { errors.push(`line ${p.line}: ${p.id}: dist=${dist} is too small. Use at least ${(to.r + p.r + 0.2).toFixed(2)}`); continue; }
        p.x = to.x + dist * Math.cos(rad(p.dir)); p.y = to.y + dist * Math.sin(rad(p.dir)); p.layer = to.layer;
        p.ratio = to.r / p.r; p.rho = 0;
      } else { errors.push(`line ${p.line}: by=${by} is unknown. Use mesh, belt, chain or axle`); continue; }
      p.ratio *= 1;
    }
    p.chainRatio = (to?.chainRatio ?? 1) * p.ratio;
    byId.set(p.id, p);
  }
  // Two parts in one layer that are not connected must not overlap.
  const rotors = [...byId.values()].filter((p) => p.rotor);
  for (let i = 0; i < rotors.length; i++) for (let j = 0; j < i; j++) {
    const a = rotors[i], b = rotors[j];
    if (a.layer !== b.layer || a.parent === b || b.parent === a) continue;
    const d = Math.hypot(a.x - b.x, a.y - b.y);
    if (d < a.r + b.r + 0.05) errors.push(`line ${a.line}: ${a.id} overlaps ${b.id} (gap ${(d - a.r - b.r).toFixed(2)}). Change dir= of ${a.id}`);
  }
  return byId;
}

function wheelText(p, z) {
  let s = `  group ${p.id} at=${f(p.x, p.y, z)}\n`;
  const add = (t) => { s += `    ${t}\n`; };
  if (p.cmd === 'gear') {
    add(`gear ${p.id}g teeth=${p.teeth} r=${p.r.toFixed(4)} h=${DEPTH} axis=z phase=${p.rho.toFixed(5)} color=${p.color} mat=paint`);
    add(`cyl ${p.id}h r=${(Math.max(0.12, p.r * 0.2)).toFixed(3)} h=${DEPTH * 1.3} axis=z color=#2a2c30 mat=metal`);
    return s;
  }
  const r = p.r;
  add(`cyl ${p.id}r r=${r.toFixed(3)} hole=${(r * 0.8).toFixed(3)} h=${DEPTH} axis=z color=${p.color} mat=paint`);
  add(`cyl ${p.id}h r=${(r * 0.2).toFixed(3)} h=${DEPTH * 1.3} axis=z color=#2a2c30 mat=metal`);
  const blades = Number(p.kv.blades ?? 0), n = blades || Number(p.kv.spokes ?? 6);
  for (let i = 0; i < n; i++) {
    const a = 360 * i / n, c = Math.cos(rad(a)), q = Math.sin(rad(a)), L = r * 0.8, m = L / 2 + r * 0.05;
    add(`box ${p.id}s${i} size=${f(L, blades ? r * 0.28 : r * 0.1, DEPTH * 0.5)} at=${f(c * m, q * m, 0)} rot=0,0,${a} round=0 color=${blades ? p.color : '#55585e'} mat=${blades ? 'paint' : 'metal'}`);
  }
  return s;
}

export function toChalk(m, byId) {
  const parts = [...byId.values()];
  const zOf = (p) => 0.2 + DEPTH / 2 + LAYER * p.layer;
  const pinZ = (w) => zOf(w) + DEPTH / 2 + 0.32;
  let lo = [1e9, 1e9], hi = [-1e9, -1e9];
  const grow = (x, y, r = 0) => { lo = [Math.min(lo[0], x - r), Math.min(lo[1], y - r)]; hi = [Math.max(hi[0], x + r), Math.max(hi[1], y + r)]; };
  let body = '', mech = '';
  for (const p of parts) {
    if (p.cmd === 'block') {
      grow(p.x, p.y, 0); grow(p.x - p.w / 2, p.y - p.h / 2); grow(p.x + p.w / 2, p.y + p.h / 2);
      body += `  box ${p.id} size=${f(p.w, p.h, 0.34)} at=${f(p.x, p.y, 0.17)} round=0.02 color=${p.kv.color ?? '#59606a'} mat=cast\n`;
    } else if (p.rotor) {
      grow(p.x, p.y, p.r);
      const z = zOf(p);
      const pins = parts.filter((q) => q.wheel === p).map((q) => {
        const d = [Math.cos(rad(q.dir)), Math.sin(rad(q.dir))], h = pinZ(p) - z + 0.1;
        return `    cyl ${q.id}_pn r=0.07 h=${h.toFixed(3)} axis=z at=${f(d[0] * q.s, d[1] * q.s, h / 2 - 0.05)} color=#c8cbd0 mat=chrome\n`;
      }).join('');
      body += wheelText(p, z) + pins;
      body += `  cyl ${p.id}a r=${(Math.max(0.07, p.r * 0.09)).toFixed(3)} h=${(z + DEPTH + 0.2).toFixed(3)} axis=z at=${f(p.x, p.y, (z + DEPTH) / 2 - 0.1)} color=#c8cbd0 mat=chrome\n`;
      const bh = z - DEPTH / 2 - 0.01;
      body += `  cyl ${p.id}m r=${(Math.max(0.16, p.r * 0.2)).toFixed(3)} h=${bh.toFixed(3)} axis=z at=${f(p.x, p.y, bh / 2)} color=#6f7277 mat=cast\n`;
      const of = p.parent ? ` of=${p.parent.id} ratio=${p.ratio.toFixed(5)}` : '';
      mech += `    rotor ${p.id} at=${f(p.x, p.y, z)} axis=z${of}\n`;
      if (p.by === 'belt' || p.by === 'chain') {
        const a = p.parent, pitch = 0.09;
        mech += `    chain ${p.id}_b of=${a.id} ra=${(a.r + 0.03).toFixed(3)} rb=${(p.r + 0.03).toFixed(3)} a=${f(a.x, a.y, z)} b=${f(p.x, p.y, z)} axis=z pitch=${pitch}${p.by === 'belt' ? ' belt=1' : ''}\n`;
      }
    } else if (p.cmd === 'piston') {
      const w = p.wheel, a = rad(p.dir), d = [Math.cos(a), Math.sin(a)], ang = p.dir - 90;
      const z = pinZ(w);
      const pin = [w.x + d[0] * p.s, w.y + d[1] * p.s], wrist = [w.x + d[0] * (p.s + p.L), w.y + d[1] * (p.s + p.L)];
      const low = p.L - p.s - p.bore * 0.6, high = p.L + p.s + p.bore * 0.7, mid = (low + high) / 2;
      grow(w.x + d[0] * high, w.y + d[1] * high, p.bore);
      const c = [w.x + d[0] * mid, w.y + d[1] * mid];
      body += `  group ${p.id}_cyl at=${f(c[0], c[1], z)} rot=0,0,${ang}\n`;
      body += `    cyl ${p.id}_w r=${(p.bore * 0.62).toFixed(3)} hole=${(p.bore * 0.54).toFixed(3)} h=${(high - low).toFixed(3)} axis=y color=#bcd4e6 mat=glass\n`;
      body += `    cyl ${p.id}_c r=${(p.bore * 0.66).toFixed(3)} h=0.1 axis=y at=0,${((high - low) / 2).toFixed(3)},0 color=#59606a mat=cast\n`;
      body += `  box ${p.id}_m size=${f(p.bore * 0.9, high - low, z - p.bore * 0.62)} at=${f(c[0], c[1], (z - p.bore * 0.62) / 2)} rot=0,0,${ang} round=0 color=#3a3d42 mat=cast\n`;
      body += `  group ${p.id} at=${f(wrist[0], wrist[1], z)} rot=0,0,${ang}\n    cyl ${p.id}_p r=${(p.bore * 0.52).toFixed(3)} h=${(p.bore * 0.8).toFixed(3)} axis=y color=#d7d9dd mat=chrome\n`;
      body += `  group ${p.id}_r at=${f(pin[0], pin[1], z)} rot=0,0,${ang}\n    box ${p.id}_rb size=${f(0.1, p.L, 0.08)} at=0,${(p.L / 2).toFixed(3)},0 round=0 color=#8d9196 mat=metal\n`;
      mech += `    piston ${p.id} crank=${w.id} pin=${f(pin[0], pin[1], z)} wrist=${f(wrist[0], wrist[1], z)}\n`;
      mech += `    rod ${p.id}_r crank=${w.id} pin=${f(pin[0], pin[1], z)} wrist=${p.id}\n`;
    }
  }
  const pad = 0.6, cx = (lo[0] + hi[0]) / 2, cy = (lo[1] + hi[1]) / 2, W = hi[0] - lo[0] + pad * 2, H = hi[1] - lo[1] + pad * 2;
  let frame = `  box plate size=${f(W, H, 0.12)} at=${f(cx, cy, -0.06)} round=0.03 color=#e6e0d2 mat=matte\n`;
  frame += `  box foot size=${f(W * 0.8, 0.14, 1.6)} at=${f(cx, lo[1] - pad - 0.07, 0.2)} round=0.03 color=#8a8275 mat=cast\n`;
  const fastest = Math.max(1, ...parts.filter((p) => p.rotor).map((p) => Math.abs(p.chainRatio)));
  const steps = m.steps.length ? m.steps : [{ text: m.title }];
  const SEC = 3.5, turns = (1.5 * SEC / fastest).toFixed(2);
  let anim = '';
  steps.forEach((s, i) => {
    const near = s.on && byId.has(s.on) && i < steps.length - 1 && i > 0;
    anim += `    step "${s.text}" ${SEC}\n      run turns=${turns}\n      camera view=${i % 2 ? -12 : 12},9 zoom=${near ? 1.6 : 1}${near ? ` on=${s.on}` : ''}\n`;
  });
  return `canvas dark\ntitle "${m.title}"\nmodel obj 1100 620 keep=1 view=12,9\n${frame}${body}  mech\n${mech}  anim\n${anim}`;
}

export function compileMini(src) {
  const m = parseMini(src);
  const byId = layout(m);
  for (const s of m.steps) if (s.on && !byId.has(s.on)) m.errors.push(`line ${s.line}: step on=${s.on}: no such part`);
  if (!byId.size) m.errors.push('no parts');
  if (![...byId.values()].some((p) => p.rotor)) m.errors.push('nothing moves: add a wheel or a gear');
  return { errors: m.errors, chalk: m.errors.length ? '' : toChalk(m, byId), parts: byId.size };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , file, dest] = process.argv;
  const r = compileMini(readFileSync(file, 'utf8'));
  if (dest && r.chalk) writeFileSync(dest, r.chalk);
  console.log(JSON.stringify({ parts: r.parts, errors: r.errors }));
}
