// Rig macros: a model describes a machine as a table, and the engine does the trigonometry.
//   template pis            one piston, wrist at the origin, crown toward +y
//     ...
//   template con            one con rod, big end at the origin, small end at 0,L,0
//     ...
//   mech
//     crankshaft crank at=0,0,0 axis=x r=0.43 throws=-1.8:0,-0.6:90,0.6:270,1.8:180
//     cylinder a1 crank=crank x=-1.92 throw=0 angle=45 rod=1.55 piston=pis conrod=con flame=0.4 crown=0.34
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
