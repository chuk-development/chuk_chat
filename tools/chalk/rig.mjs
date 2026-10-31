// Rig macros: a model describes a machine as a table, and the engine does the trigonometry.
//   template pis            one piston, wrist at the origin, crown toward +y
//     ...
//   template con            one con rod, big end at the origin, small end at 0,L,0
//     ...
//   mech
//     crankshaft crank at=0,0,0 axis=x r=0.43 throws=-1.8:0,-0.6:90,0.6:270,1.8:180
//     cylinder a1 crank=crank x=-1.92 throw=0 angle=45 rod=1.55 piston=pis conrod=con flame=0.4 crown=0.34
//     geartrain g at=0,0,0 axis=z dir=0 teeth=20,40,15 module=0.05 h=0.1 of=crank color=#b9b090
//       gears that really mesh in a line, ids g0 g1 g2, with their true ratios
//     chain c of=g0 ra=0.2 a=x,y,z b=x,y,z rb=0.1 axis=z pitch=0.05
//       a closed chain or belt around two wheels. `of` turns at wheel a. belt=1 gives a smooth band
//     spokedwheel w at=x,y,z axis=z r=0.34 width=0.025 spokes=32 of=crank ratio=1
// `angle` is the cylinder line, `throw` the crank pin, both in degrees around the crank axis.
import { parse, nums } from './parse.mjs';

const AXES = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] };
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const fmt = (v) => v.map((x) => Number(x.toFixed(5))).join(',');
const rad = (d) => d * Math.PI / 180;

function frame(kv) {
  const a = AXES[kv.axis ?? 'x'] ?? nums(kv.axis);
  const u = Math.abs(a[1]) > 0.9 ? [1, 0, 0] : [0, 1, 0];
  const v = cross(a, u);
  return { at: kv.at ? nums(kv.at) : [0, 0, 0], a, u, v };
}

const at = (f, x, deg, r) => [0, 1, 2].map((c) => f.at[c] + f.a[c] * x + r * (f.u[c] * Math.cos(rad(deg)) + f.v[c] * Math.sin(rad(deg))));

function web(id, x, deg, r, t) {
  const R = r * 1.72, pts = [];
  for (let a = -58; a <= 58; a += 13) pts.push([R * Math.sin(rad(a)), -R * Math.cos(rad(a))]);
  pts.push([r * 0.7, -r * 0.28], [r * 0.56, r * 0.5]);
  for (let a = 0; a <= 180; a += 20) pts.push([r * 0.5 * Math.cos(rad(a)), r + r * 0.5 * Math.sin(rad(a))]);
  pts.push([-r * 0.56, r * 0.5], [-r * 0.7, -r * 0.28]);
  const text = pts.map((p) => fmt(p)).join(' ');
  return `  group ${id} at=${fmt([x, 0, 0])} rot=${deg},0,0\n    plate ${id}p pts=${text} h=${t} rot=0,90,0 color=#6f7277 mat=cast\n`;
}

function crankText(k, f) {
  const r = Number(k.kv.r ?? 0.4), id = k.args[0];
  const throws = String(k.kv.throws).split(',').map((s) => s.split(':').map(Number));
  const j = Number(k.kv.journal ?? r * 0.56), p = Number(k.kv.pin ?? r * 0.4), t = Number(k.kv.web ?? r * 0.28);
  const span = Number(k.kv.pinlen ?? 0.5 * Math.abs((throws[1]?.[0] ?? 1) - throws[0][0]));
  const xs = throws.map((v) => v[0]);
  const pitch = xs.length > 1 ? Math.abs(xs[1] - xs[0]) : span * 2;
  let s = `group ${id} at=${fmt(f.at)} basis=${fmt(f.a)},${fmt(f.u)}\n`;
  throws.forEach(([x, deg], i) => {
    s += `  cyl ${id}pin${i} r=${p} h=${span} axis=x at=${fmt([x, r * Math.cos(rad(deg)), r * Math.sin(rad(deg))])} color=#d6d9de mat=chrome\n`;
    s += web(`${id}w${i}a`, x - span / 2 - t / 2, deg, r, t) + web(`${id}w${i}b`, x + span / 2 + t / 2, deg, r, t);
    s += `  cyl ${id}m${i} r=${j} h=${(pitch - span - 2 * t).toFixed(4)} axis=x at=${fmt([x + pitch / 2, 0, 0])} color=#c9ccd2 mat=chrome\n`;
  });
  const first = xs[0] - pitch / 2;
  s += `  cyl ${id}m r=${j} h=${(pitch - span - 2 * t).toFixed(4)} axis=x at=${fmt([first, 0, 0])} color=#c9ccd2 mat=chrome\n`;
  return s;
}

function gearText(id, f, cfg) {
  const { teeth, m, h, color, dir } = cfg;
  const local = (x, y) => [0, 1, 2].map((c) => f.at[c] + f.u[c] * x + f.v[c] * y);
  let px = 0, py = 0, rho = 0, prev = null;
  const out = [];
  teeth.forEach((t, i) => {
    if (i) {
      const d = m * (prev + t) / 2;
      px += d * Math.cos(rad(dir)); py += d * Math.sin(rad(dir));
      // Tooth on one side meets a gap on the other.
      const phi = rad(dir);
      rho = phi + Math.PI - (2 * Math.PI / t) * (0.5 - ((phi - rho) * prev) / (2 * Math.PI));
    }
    const c = local(px, py);
    out.push({ id: `${id}${i}`, at: c, r: m * t / 2, text: `group ${id}${i} at=${fmt(c)} basis=${fmt(f.u)},${fmt(f.v)}\n  gear ${id}${i}g teeth=${t} r=${(m * t / 2).toFixed(4)} h=${h} axis=z phase=${rho.toFixed(5)} color=${color} mat=brushed\n  cyl ${id}${i}h r=${(m * t * 0.09).toFixed(4)} h=${(h * 1.6).toFixed(4)} axis=z color=#c9ccd2 mat=chrome\n` });
    prev = t;
  });
  return out;
}

// A closed loop around two wheels: arcs and the two straight runs, in the wheel plane.
function loopPath(A, ra, B, rb, axis) {
  const d = [0, 1, 2].map((c) => B[c] - A[c]);
  const L = Math.hypot(...d), x = d.map((v) => v / L), y = cross(axis, x);
  const a = Math.asin((ra - rb) / L);
  const P = (C, r, t) => [0, 1, 2].map((c) => C[c] + r * (x[c] * Math.cos(t) + y[c] * Math.sin(t)));
  const pts = [];
  const steps = 48;
  for (let i = 0; i <= steps; i++) pts.push(P(A, ra, Math.PI / 2 + a + (i / steps) * (Math.PI - 2 * a)));
  for (let i = 0; i <= steps; i++) pts.push(P(B, rb, -Math.PI / 2 + a + (i / steps) * (Math.PI + 2 * -a) + 0));
  pts.push(pts[0]);
  return pts;
}

export function along(path, s, normal) {
  for (let i = 1; i < path.length; i++) {
    const d = [0, 1, 2].map((c) => path[i][c] - path[i - 1][c]), l = Math.hypot(...d);
    if (s <= l || i === path.length - 1) {
      const t = d.map((v) => v / (l || 1));
      return { p: [0, 1, 2].map((c) => path[i - 1][c] + t[c] * s), t, n: cross(normal, t) };
    }
    s -= l;
  }
  return { p: path[0], t: [1, 0, 0], n: [0, 1, 0] };
}

export function expandRig(model, errors) {
  if (model.rigged) return;
  model.rigged = true;
  const mech = model.kids.find((k) => k.cmd === 'mech');
  if (!mech) return;
  const templates = new Map(model.kids.filter((k) => k.cmd === 'template').map((k) => [k.args[0], k]));
  const cranks = new Map();
  const joints = [];
  const added = [];
  const fired = new Map();
  const group = (id, kv, kids) => ({ cmd: 'group', args: [id], kv, kids, line: 0 });
  const joint = (cmd, id, kv, line) => ({ cmd, args: [id], kv, kids: [], line });
  for (const k of mech.kids) {
    if (k.cmd === 'crankshaft') {
      const f = frame(k.kv);
      cranks.set(k.args[0], { f, r: Number(k.kv.r ?? 0.4) });
      added.push(...parse(crankText(k, f)).root.kids);
      joints.push(joint('rotor', k.args[0], { at: fmt(f.at), axis: fmt(f.a) }, k.line));
    } else if (k.cmd === 'geartrain') {
      const f = frame(k.kv);
      const teeth = String(k.kv.teeth).split(',').map(Number), m = Number(k.kv.module ?? 0.05);
      const list = gearText(k.args[0], f, { teeth, m, h: Number(k.kv.h ?? 0.1), color: k.kv.color ?? '#b9b090', dir: Number(k.kv.dir ?? 0) });
      let ratio = Number(k.kv.ratio ?? 1), last = k.kv.of ?? null;
      list.forEach((g, i) => {
        added.push(...parse(g.text).root.kids);
        const kv = { at: fmt(g.at), axis: fmt(f.a), ratio: String(i ? -teeth[i - 1] / teeth[i] : ratio) };
        if (last) kv.of = last;
        joints.push(joint('rotor', g.id, kv, k.line));
        last = g.id;
      });
    } else if (k.cmd === 'chain') {
      const a = AXES[k.kv.axis ?? 'z'] ?? nums(k.kv.axis), A = nums(k.kv.a), B = nums(k.kv.b);
      const ra = Number(k.kv.ra ?? 0.1), rb = Number(k.kv.rb ?? ra), pitch = Number(k.kv.pitch ?? ra / 4), id = k.args[0];
      const path = loopPath(A, ra, B, rb, a);
      let total = 0;
      for (let i = 1; i < path.length; i++) total += Math.hypot(...[0, 1, 2].map((c) => path[i][c] - path[i - 1][c]));
      const n = Math.min(200, Math.round(total / pitch));
      const size = pitch * 0.95, belt = k.kv.belt;
      const local = belt
        ? `  box ${id}b size=${size * 1.1},${pitch * 0.3},${pitch * 1.1} round=0 color=#16171a mat=rubber\n`
        : `  box ${id}o size=${size * 1.3},${pitch * 0.46},${pitch * 0.1} at=0,0,${pitch * 0.32} round=0 color=#b6b9bf mat=brushed\n  box ${id}i size=${size * 1.3},${pitch * 0.46},${pitch * 0.1} at=0,0,${-pitch * 0.32} round=0 color=#8d9096 mat=brushed\n  cyl ${id}p r=${pitch * 0.15} h=${pitch * 0.72} axis=z color=#dfe1e5 mat=chrome\n`;
      for (let i = 0; i < n; i++) {
        const lid = `${id}_${i}`;
        const s0 = i / n * total;
        const pose = along(path, s0, a);
        added.push(...parse(`group ${lid} at=${fmt(pose.p)} basis=${fmt(pose.t)},${fmt(pose.n)}\n${local}`).root.kids);
        joints.push({ ...joint('along', lid, { of: k.kv.of, r: String(ra), s0: String(s0) }, k.line), path, total, normal: a });
      }
    } else if (k.cmd === 'spokedwheel') {
      const f = frame(k.kv), id = k.args[0], r = Number(k.kv.r ?? 0.34), w = Number(k.kv.width ?? 0.025), n = Number(k.kv.spokes ?? 32);
      const tyre = Number(k.kv.tyre ?? r * 0.07), rim = r - tyre * 2;
      let t = `group ${id} at=${fmt(f.at)} basis=${fmt(f.u)},${fmt(f.v)}\n  lathe ${id}t pts=${-w},${r - tyre * 2} ${-w * 0.8},${r - tyre * 0.5} 0,${r} ${w * 0.8},${r - tyre * 0.5} ${w},${r - tyre * 2} ${-w},${r - tyre * 2} axis=z color=${k.kv.color ?? '#16171a'} mat=rubber\n  cyl ${id}r r=${(r - tyre * 1.9).toFixed(4)} hole=${(r - tyre * 3).toFixed(4)} h=${w * 1.2} axis=z color=${k.kv.rim ?? '#c9ccd2'} mat=brushed\n  cyl ${id}h r=${(r * 0.06).toFixed(4)} h=${w * 3} axis=z color=#c9ccd2 mat=chrome\n`;
      for (let i = 0; i < n; i++) {
        const a0 = rad(i / n * 360), a1 = a0 + rad(i % 2 ? 40 : -40), hub = r * 0.05, tip = rim - tyre * 0.9, z = (i % 2 ? 1 : -1) * w * 0.9;
        t += `  tube ${id}s${i} pts=${fmt([hub * Math.cos(a1), hub * Math.sin(a1), z])} ${fmt([tip * Math.cos(a0), tip * Math.sin(a0), 0])} r=${(r * 0.0045).toFixed(5)} color=#d6d9de mat=chrome\n`;
      }
      added.push(...parse(t).root.kids);
      const kv = { at: fmt(f.at), axis: fmt(f.a), ratio: String(k.kv.ratio ?? 1) };
      if (k.kv.of) kv.of = k.kv.of;
      joints.push(joint('rotor', id, kv, k.line));
    } else if (k.cmd === 'cylinder') {
      const c = cranks.get(k.kv.crank);
      const P = templates.get(k.kv.piston), R = templates.get(k.kv.conrod);
      if (!c) { errors.push(`line ${k.line}: cylinder ${k.args[0]}: no crankshaft "${k.kv.crank}" above this line`); continue; }
      if (!P || !R) { errors.push(`line ${k.line}: cylinder ${k.args[0]}: no template "${!P ? k.kv.piston : k.kv.conrod}"`); continue; }
      const id = k.args[0], x = Number(k.kv.x ?? 0), th = Number(k.kv.throw ?? 0), ang = Number(k.kv.angle ?? 0), L = Number(k.kv.rod ?? 1.5), r = c.r;
      const d = rad(th - ang);
      const s = r * Math.cos(d) + Math.sqrt(Math.max(0, L * L - (r * Math.sin(d)) ** 2));
      const pin = at(c.f, x, th, r), wrist = at(c.f, x, ang, s);
      const line = [0, 1, 2].map((i) => c.f.u[i] * Math.cos(rad(ang)) + c.f.v[i] * Math.sin(rad(ang)));
      const up = [0, 1, 2].map((i) => (wrist[i] - pin[i]) / L);
      added.push(group(`p_${id}`, { at: fmt(wrist), basis: `${fmt(c.f.a)},${fmt(line)}` }, P.kids));
      added.push(group(`r_${id}`, { at: fmt(pin), basis: `${fmt(c.f.a)},${fmt(up)}` }, R.kids));
      joints.push(joint('piston', `p_${id}`, { crank: k.kv.crank, pin: fmt(pin), wrist: fmt(wrist) }, k.line));
      joints.push(joint('rod', `r_${id}`, { crank: k.kv.crank, pin: fmt(pin), wrist: `p_${id}` }, k.line));
      if (k.kv.flame) {
        // Four strokes: a cylinder burns at its top dead centre, on every second turn.
        const tdc = Math.round(((ang - th) % 360 + 360) % 360);
        const n = fired.get(tdc) ?? 0;
        fired.set(tdc, n + 1);
        const crown = Number(k.kv.crown ?? 0.3), fr = Number(k.kv.flame);
        const spot = [0, 1, 2].map((i) => wrist[i] + line[i] * (crown + fr * 0.2));
        added.push(...parse(`sphere f_${id} r=${fr} scale=1,0.32,1 at=${fmt(spot)} color=#ff8a24 mat=light\n`).root.kids);
        added.at(-1).kv.basis = `${fmt(c.f.a)},${fmt(line)}`;
        joints.push(joint('fire', `f_${id}`, { of: k.kv.crank, at: fmt(spot), piston: `p_${id}`, phase: String(tdc + 360 * (n % 2) + 18), width: '100', cycle: '720' }, k.line));
      }
    } else joints.push(k);
  }
  mech.kids = joints;
  model.kids = [...added, ...model.kids.filter((k) => k.cmd !== 'template')];
}
