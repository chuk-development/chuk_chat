// Kinematics. One master angle drives every moving part, so nothing can run out of
// step. A `mech` block lists joints. Parts stand in their rest pose at angle 0.
//   mech
//     rotor crank at=0,0,0 axis=x                     turns with the master angle
//     rotor cam at=0,1.1,0 axis=x of=crank ratio=-0.5 geared to another rotor
//     piston p1 crank=crank pin=x,y,z wrist=x,y,z     slides on the line from crank centre to wrist
//     rod r1 crank=crank pin=x,y,z wrist=p1           big end on the pin, small end on the piston
//     couple c1 crank=wheel1 pin=x,y,z                side rod: moves with the pin, does not turn
//     lift v1 of=cam dir=0,-1,0 by=0.1 at=40 width=120  cam lobe: out and back once per turn
//     rocker a1 of=v1 at=x,y,z axis=x deg=9           tilts with a lift
//     travel whole of=wheel1 r=0.9 dir=-1,0,0         rolls without slip
//     fire f1 of=crank at=x,y,z piston=p1 phase=45 width=120 cycle=720   burns, grows and dies
//     sway l1 of=crank at=x,y,z axis=z deg=20 phase=90  rocks with the crank: link, lever
//     sway v1 of=crank dir=1,0,0 by=0.1 phase=90        slides with the crank: valve rod
//     bar b1 a=x,y,z b=x,y,z ja=joint jb=joint          stiff rod between two moving points
// A rotor can take its parts by place: `rotor w1 at=.. axis=z in=truck claim=0.5 width=1.6
// skip=shoe,box` takes all parts of group truck inside that cylinder.
// `travel track of=w dir=1,0,0 r=1 wrap=0.7` repeats, so sleepers run past for ever.
import { nums } from './parse.mjs';
import { poseMatrix, composeMatrix } from './raster.mjs';

const AXES = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const scale = (a, k) => [a[0] * k, a[1] * k, a[2] * k];
const unit = (a) => { const l = Math.hypot(...a) || 1; return scale(a, 1 / l); };
const apply = (M, p) => [0, 1, 2].map((c) => M[c] * p[0] + M[c + 3] * p[1] + M[c + 6] * p[2] + M[c + 9]);
const vec = (v) => AXES[v] ?? (v ? unit(nums(v)) : null);

function bounds(parts, id) {
  const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  let n = 0;
  for (const p of parts) {
    if (!p.path.includes(id)) continue;
    for (let i = 0; i < p.tris.length; i += 3) { n++; for (let c = 0; c < 3; c++) { lo[c] = Math.min(lo[c], p.tris[i + c]); hi[c] = Math.max(hi[c], p.tris[i + c]); } }
  }
  return n ? { lo, hi, mid: lo.map((v, c) => (v + hi[c]) / 2) } : null;
}

// Distance from a point to the nearest part box of a group. Inside a part it is 0.
function reach(parts, id, point) {
  let best = 1e9;
  for (const p of parts) {
    if (!p.path.includes(id)) continue;
    const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    for (let i = 0; i < p.tris.length; i += 3) for (let c = 0; c < 3; c++) { lo[c] = Math.min(lo[c], p.tris[i + c]); hi[c] = Math.max(hi[c], p.tris[i + c]); }
    best = Math.min(best, Math.hypot(...[0, 1, 2].map((c) => Math.max(lo[c] - point[c], 0, point[c] - hi[c]))));
  }
  return best;
}

const JOINTS = ['rotor', 'piston', 'rod', 'couple', 'lift', 'rocker', 'travel', 'fire', 'sway', 'bar'];

// Parts join a rotor by place, so a wheel needs no group of its own.
function claim(parts, id, kv) {
  const at = nums(kv.at), axis = vec(kv.axis) ?? [0, 0, 1], R = Number(kv.claim), W = Number(kv.width ?? 1e9);
  const skip = String(kv.skip ?? '').split(',').filter(Boolean);
  for (const p of parts) {
    if (kv.in && !p.path.includes(kv.in)) continue;
    if (skip.some((s) => p.id?.includes(s))) continue;
    let inside = p.tris.length > 0;
    for (let i = 0; inside && i < p.tris.length; i += 3) {
      const r = sub([p.tris[i], p.tris[i + 1], p.tris[i + 2]], at), t = dot(r, axis);
      if (Math.abs(t) > W || Math.hypot(...sub(r, scale(axis, t))) > R) inside = false;
    }
    if (inside) p.path = [...p.path, id];
  }
}

export function readMech(model, parts, errors) {
  const node = model.kids.find((k) => k.cmd === 'mech');
  if (!node) return null;
  const joints = new Map();
  const order = [];
  for (const k of node.kids) {
    const id = k.args[0], kv = k.kv;
    if (!JOINTS.includes(k.cmd)) { errors.push(`line ${k.line}: unknown joint "${k.cmd}". Joints: ${JOINTS.join(' ')}`); continue; }
    if (k.cmd === 'rotor' && kv.claim) claim(parts, id, kv);
    const box = bounds(parts, id);
    if (!box) { errors.push(`line ${k.line}: ${k.cmd}: no part "${id}"`); continue; }
    const j = { type: k.cmd, id, line: k.line, of: kv.of ?? kv.crank ?? null, box };
    if (k.cmd === 'rotor') {
      j.axis = vec(kv.axis ?? kv.dir) ?? [0, 1, 0];
      j.at = kv.at ? nums(kv.at) : box.mid.slice();
      j.ratio = Number(kv.ratio ?? 1);
    } else if (k.cmd === 'piston' || k.cmd === 'rod' || k.cmd === 'couple') {
      j.pin = nums(kv.pin);
      if (j.pin.length < 3) { errors.push(`line ${k.line}: ${k.cmd} ${id} needs pin=x,y,z`); continue; }
      if (k.cmd === 'piston') { j.wrist = nums(kv.wrist); j.dir = vec(kv.dir); }
      if (k.cmd === 'rod') j.slider = kv.wrist;
    } else if (k.cmd === 'lift') {
      j.dir = vec(kv.dir) ?? [0, 1, 0];
      Object.assign(j, { by: Number(kv.by ?? 0.1), peak: Number(kv.at ?? 0), width: Number(kv.width ?? 120) });
    } else if (k.cmd === 'rocker') {
      j.at = nums(kv.at); j.axis = vec(kv.axis) ?? [1, 0, 0]; j.deg = Number(kv.deg ?? 10);
    } else if (k.cmd === 'travel') {
      j.dir = vec(kv.dir) ?? [-1, 0, 0]; j.r = Number(kv.r ?? 1); j.wrap = Number(kv.wrap ?? 0);
    } else if (k.cmd === 'sway') {
      j.at = kv.at ? nums(kv.at) : null; j.axis = vec(kv.axis); j.dir = vec(kv.dir);
      Object.assign(j, { deg: Number(kv.deg ?? 0), by: Number(kv.by ?? 0), phase: Number(kv.phase ?? 0) * Math.PI / 180 });
    } else if (k.cmd === 'bar') {
      j.a = nums(kv.a); j.b = nums(kv.b); j.ja = kv.ja ?? null; j.jb = kv.jb ?? null;
    } else if (k.cmd === 'fire') {
      j.at = nums(kv.at); j.piston = kv.piston;
      Object.assign(j, { peak: Number(kv.phase ?? 0), width: Number(kv.width ?? 120), cycle: Number(kv.cycle ?? 720) });
    }
    joints.set(id, j);
    order.push(j);
  }
  for (const j of order) {
    if (j.type === 'bar') for (const r of [j.ja, j.jb]) if (r && !joints.has(r)) errors.push(`line ${j.line}: bar ${j.id}: no joint "${r}"`);
    if (j.of && !joints.has(j.of)) errors.push(`line ${j.line}: ${j.type} ${j.id}: no joint "${j.of}"`);
    if (j.type === 'rod' && !joints.has(j.slider)) errors.push(`line ${j.line}: rod ${j.id}: no piston "${j.slider}"`);
  }
  const m = { joints, order };
  checkMech(m, parts, errors);
  if (!errors.some((e) => e.startsWith('mech'))) sweep(m, parts, errors);
  return m;
}

// Total turn ratio from the master down the chain of `of`.
function angleOf(m, id, theta, seen = 0) {
  const j = m.joints.get(id);
  if (!j || seen > 16) return 0;
  const base = j.of ? angleOf(m, j.of, theta, seen + 1) : theta;
  return j.type === 'rotor' ? base * j.ratio : base;
}

function pinAt(m, j, theta) {
  const crank = m.joints.get(j.of);
  if (!crank?.at) return j.pin;
  return apply(poseMatrix([0, 0, 0], crank.at, crank.axis, angleOf(m, crank.id, theta)), j.pin);
}

// Slider-crank: the wrist stays on its line and at rod length from the pin.
function wristAt(m, j, theta) {
  const crank = m.joints.get(j.of);
  const r = sub(j.wrist, crank.at);
  const d = j.dir ?? unit(sub(r, scale(crank.axis, dot(r, crank.axis))));
  const L2 = dot(sub(j.wrist, j.pin), sub(j.wrist, j.pin));
  const P = pinAt(m, j, theta);
  const Q = sub(j.wrist, P);
  const b = dot(Q, d), disc = b * b - dot(Q, Q) + L2;
  const s = -b + Math.sqrt(Math.max(0, disc));
  return { W: add(j.wrist, scale(d, s)), P, ok: disc >= 0 };
}

const bump = (deg, peak, width, cycle = 360) => {
  const a = ((deg - peak) % cycle + cycle * 1.5) % cycle - cycle / 2;
  return Math.abs(a) < width / 2 ? 0.5 + 0.5 * Math.cos(2 * Math.PI * a / width) : 0;
};

const liftShare = (m, j, theta) => bump(angleOf(m, j.of, theta) * 180 / Math.PI, j.peak, j.width);

export function solve(m, theta) {
  const out = new Map();
  for (const j of m.order) {
    if (j.type === 'rotor') out.set(j.id, poseMatrix([0, 0, 0], j.at, j.axis, angleOf(m, j.id, theta)));
    else if (j.type === 'piston') { const { W } = wristAt(m, j, theta); out.set(j.id, poseMatrix(sub(W, j.wrist), j.wrist, [1, 0, 0], 0)); }
    else if (j.type === 'couple') out.set(j.id, poseMatrix(sub(pinAt(m, j, theta), j.pin), [0, 0, 0], [1, 0, 0], 0));
    else if (j.type === 'rod') {
      const s = m.joints.get(j.slider);
      if (!s) continue;
      const { W, P } = wristAt(m, s, theta);
      const a = sub(j.pin, s.wrist), b = sub(P, W);
      const n = unit(cross(a, b));
      const ang = Math.atan2(Math.hypot(...cross(a, b)), dot(a, b));
      out.set(j.id, poseMatrix(sub(W, s.wrist), s.wrist, n, ang));
    } else if (j.type === 'lift') out.set(j.id, poseMatrix(scale(j.dir, j.by * liftShare(m, j, theta)), [0, 0, 0], [1, 0, 0], 0));
    else if (j.type === 'rocker') out.set(j.id, poseMatrix([0, 0, 0], j.at, j.axis, j.deg * Math.PI / 180 * liftShare(m, m.joints.get(j.of), theta)));
    else if (j.type === 'travel') {
      let d = j.r * angleOf(m, j.of, theta);
      if (j.wrap) d = ((d % j.wrap) + j.wrap) % j.wrap;
      out.set(j.id, poseMatrix(scale(j.dir, d), [0, 0, 0], [1, 0, 0], 0));
    } else if (j.type === 'sway') {
      const v = Math.sin(angleOf(m, j.of, theta) + j.phase);
      out.set(j.id, j.dir ? poseMatrix(scale(j.dir, j.by * v), [0, 0, 0], [1, 0, 0], 0) : poseMatrix([0, 0, 0], j.at, j.axis ?? [0, 0, 1], j.deg * Math.PI / 180 * v));
    } else if (j.type === 'bar') {
      const A = j.ja && out.get(j.ja) ? apply(out.get(j.ja), j.a) : j.a;
      const B = j.jb && out.get(j.jb) ? apply(out.get(j.jb), j.b) : j.b;
      const u = sub(j.b, j.a), v = sub(B, A), n = cross(u, v), l = Math.hypot(...n);
      out.set(j.id, poseMatrix(sub(A, j.a), j.a, l > 1e-12 ? n : [1, 0, 0], Math.atan2(l, dot(u, v))));
    }
    else if (j.type === 'fire') {
      const f = bump(angleOf(m, j.of, theta) * 180 / Math.PI, j.peak, j.width, j.cycle);
      const size = poseMatrix([0, 0, 0], j.at, [1, 0, 0], 0, Math.max(0.001, f));
      const carry = j.piston ? out.get(j.piston) : null;
      out.set(j.id, carry ? composeMatrix(carry, size) : size);
    }
  }
  return out;
}

// Finds the faults that make a film look broken, before anybody renders it.
function checkMech(m, parts, errors) {
  const size = (() => { let lo = 1e9, hi = -1e9; for (const j of m.order) { lo = Math.min(lo, ...j.box.lo); hi = Math.max(hi, ...j.box.hi); } return hi - lo; })();
  const tol = size * 0.03;
  for (const j of m.order) {
    if (j.type === 'rotor') {
      let sum = [0, 0, 0], n = 0, far = 0;
      for (const p of parts) {
        if (!p.path.includes(j.id)) continue;
        for (let i = 0; i < p.tris.length; i += 3) {
          const r = sub([p.tris[i], p.tris[i + 1], p.tris[i + 2]], j.at);
          const off = sub(r, scale(j.axis, dot(r, j.axis)));
          sum = add(sum, off); far = Math.max(far, Math.hypot(...off)); n++;
        }
      }
      const shift = Math.hypot(...sum) / (n || 1);
      if (shift > far * 0.3) errors.push(`mech: rotor ${j.id} is not centred on its axis: mean offset ${shift.toFixed(3)} at radius ${far.toFixed(3)}. Give each wheel its own id and the true at=`);
    }
    if (j.type === 'piston' || j.type === 'rod' || j.type === 'couple') {
      const crank = m.joints.get(j.of);
      if (!crank) continue;
      if (crank.type !== 'rotor') { errors.push(`mech: ${j.id}: crank= must name a rotor`); continue; }
      const along = dot(sub(j.pin, crank.at), crank.axis);
      const r = Math.hypot(...sub(sub(j.pin, crank.at), scale(crank.axis, along)));
      if (r < size * 0.002) errors.push(`mech: ${j.id}: pin sits on the axis of ${crank.id}, so nothing moves`);
      const gap = reach(parts, crank.id, j.pin);
      if (gap > tol) errors.push(`mech: ${j.id}: pin is ${gap.toFixed(3)} away from ${crank.id}`);
    }
    if (j.type === 'rod') {
      const s = m.joints.get(j.slider);
      if (!s) continue;
      if (Math.hypot(...sub(j.pin, s.pin)) > 1e-6) errors.push(`mech: rod ${j.id} and piston ${s.id} use different pins`);
      const a = reach(parts, j.id, j.pin), b = reach(parts, j.id, s.wrist);
      if (a > tol) errors.push(`mech: rod ${j.id} does not reach the pin: gap ${a.toFixed(3)}`);
      if (b > tol) errors.push(`mech: rod ${j.id} does not reach the wrist: gap ${b.toFixed(3)}`);
    }
    if (j.type === 'piston') {
      const crank = m.joints.get(j.of);
      if (!crank) continue;
      for (let i = 0; i < 24; i++) if (!wristAt(m, j, i / 24 * Math.PI * 2).ok) { errors.push(`mech: piston ${j.id}: rod is too short for this crank`); break; }
      if (reach(parts, j.id, j.wrist) > tol) errors.push(`mech: piston ${j.id}: wrist is outside the piston`);
    }
  }
}

// Turns the machine through a full cycle and measures what no single picture shows:
// a moving group that hangs in the air, and moving parts that run through standing parts.
// Parts that touch at rest are neighbours, a piston slides in its liner and that is fine.
function sweep(m, parts, errors) {
  const ids = new Set(m.order.map((j) => j.id));
  const moving = m.order.filter((j) => j.type !== 'travel' && j.type !== 'fire');
  const fixed = parts.filter((p) => !p.path.some((id) => ids.has(id)) && !p.ground && !p.decal && p.mat !== 'glass');
  if (!fixed.length) return;
  const lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  for (const p of parts) if (!p.ground && !p.decal) for (let i = 0; i < p.tris.length; i += 3) for (let c = 0; c < 3; c++) { lo[c] = Math.min(lo[c], p.tris[i + c]); hi[c] = Math.max(hi[c], p.tris[i + c]); }
  const N = 240, cell = Math.max(...hi.map((v, c) => v - lo[c])) / (N - 8);
  const key = (x, y, z) => Math.floor((x - lo[0]) / cell + 4) + N * Math.floor((y - lo[1]) / cell + 4) + N * N * Math.floor((z - lo[2]) / cell + 4);
  const grid = new Map();
  for (const p of fixed) {
    const t = p.tris;
    for (let i = 0; i + 8 < t.length; i += 9) {
      const e = Math.max(Math.hypot(t[i] - t[i + 3], t[i + 1] - t[i + 4], t[i + 2] - t[i + 5]), Math.hypot(t[i] - t[i + 6], t[i + 1] - t[i + 7], t[i + 2] - t[i + 8]));
      const n = Math.min(60, Math.ceil(e / cell));
      for (let a = 0; a <= n; a++) for (let b = 0; a + b <= n; b++) {
        const u = a / n, v = b / n, w = 1 - u - v;
        grid.set(key(w * t[i] + u * t[i + 3] + v * t[i + 6], w * t[i + 1] + u * t[i + 4] + v * t[i + 7], w * t[i + 2] + u * t[i + 5] + v * t[i + 8]), p.id);
      }
    }
  }
  const around = (q, R, f) => { for (let a = -R; a <= R; a++) for (let b = -R; b <= R; b++) for (let c = -R; c <= R; c++) { const o = grid.get(key(q[0] + a * cell, q[1] + b * cell, q[2] + c * cell)); if (o) f(o); } };
  for (const j of moving) {
    const all = parts.filter((p) => p.path.includes(j.id));
    const n = all.reduce((t, p) => t + p.tris.length / 3, 0), every = Math.max(1, Math.round(n / 1200));
    const pts = [];
    for (const p of all) for (let i = 0; i < p.tris.length; i += 3 * every) pts.push([p.tris[i], p.tris[i + 1], p.tris[i + 2]]);
    const near = new Set();
    for (const q of pts) around(q, 2, (o) => near.add(o));
    if (j.type === 'rotor' && !j.of && !near.size) errors.push(`mech: ${j.id} hangs in the air: it touches no standing part. Its middle is ${j.box.mid.map((v) => v.toFixed(2))}. Give it a shaft or a mount`);
    const hits = new Map();
    for (let k = 1; k < 36; k++) {
      const M = solve(m, k / 36 * Math.PI * 4).get(j.id);
      for (const q of pts) {
        const w = apply(M, q), o = grid.get(key(...w));
        if (o && !near.has(o)) hits.set(o, (hits.get(o) ?? 0) + 1);
      }
    }
    for (const [other, c] of [...hits].sort((x, y) => y[1] - x[1]).slice(0, 2)) if (c > 12) errors.push(`mech: ${j.id} runs through ${other} while it moves (${c} hits). Make room or move the axis`);
  }
}

// Master angle over time. `run turns=6` in a step sets the speed there. The speed
// changes smoothly, so the machine runs up and down and never jumps.
export function masterAngle(tl) {
  const rate = 240, n = Math.ceil(tl.total * rate) + 1;
  const v = new Float64Array(n);
  for (const s of tl.steps) {
    const run = s.ops.find((o) => o.cmd === 'run');
    const speed = run ? Number(run.kv.turns ?? 1) * Math.PI * 2 / s.dur : 0;
    for (let i = Math.floor(s.start * rate); i < Math.min(n, Math.ceil((s.start + s.dur) * rate)); i++) v[i] = speed;
  }
  // Two box filters give a soft ramp of half a second.
  const blur = (a, w) => { const b = new Float64Array(a.length); let t = 0; for (let i = 0; i < a.length; i++) { t += a[i]; if (i >= w) t -= a[i - w]; b[i] = t / Math.min(i + 1, w); } return b; };
  const smooth = blur(blur(v, rate >> 2), rate >> 2);
  const angle = new Float64Array(n);
  for (let i = 1; i < n; i++) angle[i] = angle[i - 1] + smooth[i] / rate;
  return (t) => angle[Math.max(0, Math.min(n - 1, Math.round(t * rate)))];
}
