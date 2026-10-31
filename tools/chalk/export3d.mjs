#!/usr/bin/env node
// export3d <file.chalk> <out.json>: turns the first model of a scene into a baked
// scene for the PBR viewer. Parts are merged by motion and material, and every
// motion group gets one matrix per frame, so the viewer needs no Chalk logic.
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parse } from './parse.mjs';
import { buildParts, smoothNormals, bestView } from './raster.mjs';
import { timeline, checkTimeline, pose, cameraAt, caption } from './anim.mjs';
import { readMech } from './mech.mjs';

const FPS = 30;
const findModel = (n) => (n.cmd === 'model' ? n : n.kids?.map(findModel).find(Boolean));
const b64 = (a) => Buffer.from(a.buffer, a.byteOffset, a.byteLength).toString('base64');

// Explode: every top-level unit moves away from the centre of the model.
function exploded(parts, k) {
  const mid = [0, 0, 0];
  let n = 0;
  const tops = new Map();
  for (const p of parts) {
    const t = tops.get(p.top) ?? [0, 0, 0, 0];
    for (let i = 0; i < p.tris.length; i += 3) { for (let c = 0; c < 3; c++) { t[c] += p.tris[i + c]; mid[c] += p.tris[i + c]; } t[3]++; n++; }
    tops.set(p.top, t);
  }
  for (const p of parts) {
    const t = tops.get(p.top);
    for (let c = 0; c < 3; c++) {
      const d = (t[c] / t[3] - mid[c] / n) * k;
      for (let i = c; i < p.tris.length; i += 3) p.tris[i] += d;
    }
  }
}

export function exportScene(src) {
  const parsed = parse(src).root;
  const model = findModel(parsed);
  if (!model) throw new Error('no model');
  const errors = [];
  const parts = buildParts(model, errors);
  if (model.kv.explode) exploded(parts, Number(model.kv.explode));
  const tl = timeline(model);
  if (tl) checkTimeline(tl, parts, errors);
  const mech = readMech(model, parts, errors);
  if (tl) tl.mech = mech;
  // fit=id: the camera frames this group. A long track does not make the train small.
  if (model.kv.fit) for (const p of parts) if (!p.path.includes(model.kv.fit)) p.ground = true;
  const auto = !model.kv.view;
  const base = auto ? bestView(parts, [35, 22]) : model.kv.view.split(',').map(Number);
  const animated = new Set();
  if (tl) for (const s of tl.steps) for (const op of s.ops) if (op.cmd !== 'camera') animated.add(op.args[0]);
  if (tl) for (const s of tl.steps) for (const op of s.ops) if (op.cmd === 'drive') { const g = parts.gearsets.get(String(op.args[0]).split(/[._]/)[0]) ?? parts.gearsets.get(op.args[0]); if (g) { animated.add(g.a); animated.add(g.b); } }
  if (tl && mech) for (const id of mech.joints.keys()) animated.add(id);
  const motionKey = (p) => (p.link ? `link:${p.id}` : p.path.filter((id) => animated.has(id)).join('/'));
  const groups = new Map();
  parts.forEach((p, i) => {
    const key = motionKey(p);
    if (!groups.has(key)) groups.set(key, { key, rep: i, meshes: new Map() });
    const g = groups.get(key);
    const mk = p.decal ? `d${i}` : `${p.color.join(',')}|${p.mat}|${p.colorName ?? ''}|${p.shell ? 1 : 0}`;
    if (!g.meshes.has(mk)) g.meshes.set(mk, { color: p.color, mat: p.mat, name: p.colorName ?? '', shell: !!p.shell, decal: p.decal, uv: p.uv, list: [] });
    g.meshes.get(mk).list.push(p);
  });
  let lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
  const grow = (x, y, z) => { lo = [Math.min(lo[0], x), Math.min(lo[1], y), Math.min(lo[2], z)]; hi = [Math.max(hi[0], x), Math.max(hi[1], y), Math.max(hi[2], z)]; };
  // Poses per frame, for motion blur. Many small groups (chain links) share a budget.
  const SUB = groups.size > 150 ? 1 : groups.size > 70 ? 2 : 4;
  const frames = tl ? Math.max(1, Math.ceil((tl.total + 1.2) * FPS)) : 1;
  const out = { fps: FPS, frames, title: parsed.kids?.find((c) => c.cmd === 'title')?.args?.[0] ?? '', cut: model.kv.cut ?? null, cap: model.kv.cap ?? null, sub: SUB, groups: [], captions: [], camera: [], tris: 0, parts: parts.length };
  const poses = tl ? Array.from({ length: frames * SUB }, (_, f) => pose(tl, parts, f / FPS / SUB)) : [null];
  for (const g of groups.values()) {
    const rec = { key: g.key, meshes: [], matrices: null, glow: null };
    for (const m of g.meshes.values()) {
      const size = m.list.reduce((t, p) => t + p.tris.length, 0);
      const pos = new Float32Array(size), nor = new Float32Array(size);
      let o = 0;
      for (const p of m.list) {
        const N = p.normals ?? smoothNormals(p.tris);
        pos.set(p.tris, o); nor.set(N, o); o += p.tris.length;
      }
      out.tris += size / 9;
      rec.meshes.push({ color: m.color, mat: m.mat, name: m.name, shell: m.shell, pos: b64(pos), nor: b64(nor), ...(m.decal ? { decal: m.decal, uv: b64(m.uv) } : {}) });
    }
    if (tl && g.key) {
      const mats = new Float32Array(poses.length * 13);
      const glow = new Float32Array(poses.length);
      poses.forEach((P, f) => {
        const X = P.xf(g.rep);
        if (X === 'hidden') { mats[f * 13 + 12] = 0; return; }
        const m = X ?? [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];
        mats.set(m, f * 13); mats[f * 13 + 12] = 1;
        glow[f] = P.tint(g.rep);
      });
      rec.matrices = b64(mats);
      rec.glow = b64(glow);
    }
    out.groups.push(rec);
  }
  // The frame holds every pose. Ground parts do not count.
  for (const P of tl ? [poses[0], poses[poses.length >> 1], poses.at(-1)] : [null]) {
    parts.forEach((p, i) => {
      if (p.ground || p.decal) return;
      const X = P ? P.xf(i) : null;
      if (X === 'hidden') return;
      for (let v = 0; v < p.tris.length; v += 27) {
        const x = p.tris[v], y = p.tris[v + 1], z = p.tris[v + 2];
        if (X) grow(X[0] * x + X[3] * y + X[6] * z + X[9], X[1] * x + X[4] * y + X[7] * z + X[10], X[2] * x + X[5] * y + X[8] * z + X[11]);
        else grow(x, y, z);
      }
    });
  }
  out.box = [lo, hi];
  // Points for a tight camera fit.
  const fit = [];
  const every = Math.max(1, Math.round(parts.reduce((t, p) => t + (p.ground || p.decal ? 0 : p.tris.length / 3), 0) / 4000));
  for (const P of tl ? [poses[0], poses[poses.length >> 1], poses.at(-1)] : [null]) {
    parts.forEach((p, i) => {
      if (p.ground || p.decal) return;
      const X = P ? P.xf(i) : null;
      if (X === 'hidden') return;
      for (let v = 0; v < p.tris.length; v += 3 * every) {
        const x = p.tris[v], y = p.tris[v + 1], z = p.tris[v + 2];
        if (X) fit.push(X[0] * x + X[3] * y + X[6] * z + X[9], X[1] * x + X[4] * y + X[7] * z + X[10], X[2] * x + X[5] * y + X[8] * z + X[11]);
        else fit.push(x, y, z);
      }
    });
  }
  out.fit = b64(new Float32Array(fit));
  const centre = lo.map((v, c) => (v + hi[c]) / 2);
  out.floor = Math.min(lo[1], ...parts.flatMap((p) => { let m = 1e9; for (let i = 1; i < p.tris.length; i += 3) m = Math.min(m, p.tris[i]); return [m]; }));
  if (tl) {
    for (let f = 0; f < frames; f++) {
      const P = poses[f * SUB];
      const t = f / FPS;
      const centerOf = (id) => {
        if (id && parts.pivots.has(id)) {
          const piv = parts.pivots.get(id);
          const i = parts.findIndex((p) => p.path.includes(id));
          const M = i >= 0 ? P.xf(i) : null;
          if (!M || M === 'hidden') return piv;
          return [0, 1, 2].map((c) => M[c] * piv[0] + M[c + 3] * piv[1] + M[c + 6] * piv[2] + M[c + 9]);
        }
        return centre;
      };
      const c = cameraAt(tl, base, Math.min(t, tl.total), centerOf);
      out.camera.push([c.yaw, c.pitch, c.zoom, ...(c.focus ?? centre)]);
      out.captions.push(caption(tl, t));
    }
  } else {
    out.camera.push([base[0], base[1], 1, ...centre]);
    out.captions.push('');
  }
  out.errors = errors;
  out.labels = [...new Set(parts.map((p) => p.label).filter(Boolean))];
  return out;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , file, dest] = process.argv;
  const scene = exportScene(readFileSync(file, 'utf8'));
  writeFileSync(dest, JSON.stringify(scene));
  console.log(JSON.stringify({ parts: scene.parts, tris: scene.tris, groups: scene.groups.length, frames: scene.frames, errors: scene.errors.slice(0, 8) }));
}
