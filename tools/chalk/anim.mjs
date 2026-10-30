// Timeline. `anim` holds steps. Every step has text, seconds and actions on parts:
//   step "Lift the clip" 1.2
//     move clip by=0,0.3,0        ends displaced
//     move cam from=0,5,0         arrives from there at its place
//     spin rotor turns=3
//     show part / hide part / pulse part / camera view=20,40 zoom=2 on=part
// The final pose is the static picture, so one scene gives picture and film.
import { nums } from './parse.mjs';
import { poseMatrix, composeMatrix } from './raster.mjs';

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
const clamp = (t) => Math.max(0, Math.min(1, t));

// Matrix that stretches the unit rod between two world points.
function rodMatrix(A, B) {
  const y = [B[0] - A[0], B[1] - A[1], B[2] - A[2]];
  const l = Math.hypot(...y) || 1e-6, u = y.map((v) => v / l);
  const s = Math.abs(u[1]) > 0.9 ? [1, 0, 0] : [0, 1, 0];
  const x = [u[1] * s[2] - u[2] * s[1], u[2] * s[0] - u[0] * s[2], u[0] * s[1] - u[1] * s[0]];
  const xl = Math.hypot(...x) || 1;
  const X = x.map((v) => v / xl);
  const Z = [X[1] * u[2] - X[2] * u[1], X[2] * u[0] - X[0] * u[2], X[0] * u[1] - X[1] * u[0]];
  return [...X, ...y, ...Z, ...A];
}

// Rods in a still picture and in a film.
export function linkPose(parts, moveOf) {
  const point = (id) => {
    const piv = parts.pivots.get(id) ?? [0, 0, 0];
    const i = parts.findIndex((p) => p.id === id || p.path.includes(id));
    const M = i >= 0 ? moveOf?.(i) : null;
    if (!M || M === 'hidden') return piv;
    return [0, 1, 2].map((c) => M[c] * piv[0] + M[c + 3] * piv[1] + M[c + 6] * piv[2] + M[c + 9]);
  };
  return (i) => (parts[i].link ? rodMatrix(point(parts[i].link.a), point(parts[i].link.b)) : moveOf?.(i) ?? null);
}

export function timeline(node) {
  const anim = node.kids.find((k) => k.cmd === 'anim');
  if (!anim) return null;
  let t = 0;
  const steps = anim.kids.filter((s) => s.cmd === 'step').map((s) => {
    const dur = Number(s.args[1] ?? s.kv.t ?? 1.5);
    const r = { text: s.args[0] ?? '', start: t, dur, ops: s.kids, line: s.line };
    t += dur;
    return r;
  });
  return { steps, total: t };
}

export function checkTimeline(tl, parts, errors) {
  const known = new Set(parts.pivots.keys());
  for (const s of tl.steps) {
    for (const op of s.ops) {
      if (!['move', 'osc', 'spin', 'drive', 'show', 'hide', 'pulse', 'camera'].includes(op.cmd)) errors.push(`line ${op.line}: unknown action "${op.cmd}". Actions: move osc spin show hide pulse camera`);
      else if (op.cmd === 'drive' ? !parts.gearsets.has(op.args[0]) : op.cmd !== 'camera' && !known.has(op.args[0])) errors.push(`line ${op.line}: ${op.cmd}: no part "${op.args[0]}"`);
    }
  }
}

// A film at 15 frames shows a fast rotor as standing still, like a wagon wheel.
// The shown speed is capped so that the eye can follow the turn.
const shown = (turns, step) => Math.sign(turns) * Math.min(Math.abs(turns), 1.1 * step.dur);

// Time past the end gives the final pose.
export function pose(tl, parts, time) {
  const state = new Map();
  const get = (id) => { if (!state.has(id)) state.set(id, { off: [0, 0, 0], ang: 0, axis: null, scale: 1, hidden: false, glow: 0 }); return state.get(id); };
  for (const s of tl.steps) {
    const raw = clamp((time - s.start) / s.dur), e = ease(raw);
    for (const op of s.ops) {
      const id = op.args[0], k = op.kv;
      if (op.cmd === 'camera') continue;
      const st = get(id);
      if (op.cmd === 'move') {
        if (k.from) { const f = nums(k.from); st.off = st.off.map((v, i) => v + f[i] * (1 - e)); }
        if (k.by) { const b = nums(k.by); st.off = st.off.map((v, i) => v + b[i] * e); }
      } else if (op.cmd === 'osc') {
        // Back and forth, a piston or a valve.
        const b = nums(k.by, [0, 0, 0]), n = Number(k.cycles ?? 1), phase = Number(k.phase ?? 0);
        const v = 0.5 - 0.5 * Math.cos((raw * n + phase) * Math.PI * 2);
        st.off = st.off.map((x, i) => x + b[i] * v);
      } else if (op.cmd === 'drive') {
        // Meshing gears: the second one turns the other way, at the tooth ratio.
        const set = parts.gearsets.get(id);
        if (set) {
          const turns = shown(Number(k.turns ?? 1), s);
          const A = get(set.a), B = get(set.b);
          A.ang += raw * turns * Math.PI * 2; A.axis = [0, 0, 1];
          B.ang -= raw * turns * set.ratio * Math.PI * 2; B.axis = [0, 0, 1];
        }
      } else if (op.cmd === 'spin') {
        const inMech = s.ops.some((o) => o.cmd === 'osc');
        const turns = inMech ? Number(k.turns ?? 1) : shown(Number(k.turns ?? 1), s);
        st.ang += raw * turns * Math.PI * 2;
        st.axis = k.axis ? { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] }[k.axis] : parts.axes.get(id);
      } else if (op.cmd === 'show') {
        st.scale = Math.min(st.scale, e);
        st.hidden = st.hidden || raw <= 0;
      } else if (op.cmd === 'hide') {
        st.hidden = st.hidden || raw >= 1;
        st.scale = Math.min(st.scale, 1 - e);
      } else if (op.cmd === 'pulse') {
        if (raw > 0 && raw < 1) st.glow = Math.max(st.glow, Math.sin(raw * Math.PI * 3) ** 2 * 0.75);
      }
    }
  }
  const motion = (i) => {
    let m = null;
    for (const id of parts[i].path) {
      const st = state.get(id);
      if (!st) continue;
      if (st.hidden) return 'hidden';
      const piv = parts.pivots.get(id) ?? [0, 0, 0];
      const p = poseMatrix(st.off, piv, st.axis ?? [0, 1, 0], st.ang, st.scale);
      m = m ? composeMatrix(p, m) : p;
    }
    return m;
  };
  const gone = (id) => { const st = state.get(id); return st ? Math.min(1, Math.hypot(...st.off) * 3) : 0; };
  const xf = linkPose(parts, motion);
  const tint = (i) => Math.max(0, ...parts[i].path.map((id) => state.get(id)?.glow ?? 0));
  return { xf, tint, gone };
}

// Camera keys: each `camera` action blends from the previous key over its step.
export function cameraAt(tl, base, time, centerOf) {
  let from = { yaw: base[0], pitch: base[1], zoom: 1, focus: null };
  let cur = from;
  for (const s of tl.steps) {
    for (const op of s.ops) {
      if (op.cmd !== 'camera') continue;
      const v = nums(op.kv.view, [from.yaw, from.pitch]);
      const on = op.kv.on ?? op.args[0];
      const to = { yaw: v[0], pitch: v[1], zoom: Number(op.kv.zoom ?? from.zoom), focus: on ? centerOf(on) : from.focus };
      if (time < s.start) { from = to; continue; }
      const e = ease(clamp((time - s.start) / s.dur));
      const mix = (a, b) => a + (b - a) * e;
      const fa = from.focus ?? centerOf(null), fb = to.focus ?? centerOf(null);
      cur = { yaw: mix(from.yaw, to.yaw), pitch: mix(from.pitch, to.pitch), zoom: mix(from.zoom, to.zoom), focus: fa.map((x, i) => mix(x, fb[i])) };
      from = to;
    }
  }
  return cur;
}

export function caption(tl, time) {
  return tl.steps.find((s) => time >= s.start && time < s.start + s.dur)?.text ?? tl.steps.at(-1)?.text ?? '';
}
