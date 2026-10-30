// Turns a parsed scene into an SVG: flex layout for 2D, hand-drawn lines,
// embedded 3D renders, labels with leader lines, and text feedback for the model.
import { readFileSync } from 'node:fs';
import { parse, nodeId, nums, points } from './parse.mjs';
import { buildParts, renderModel, floatingParts, encodePng } from './raster.mjs';

const THEMES = {
  paper: { bg: '#fbf7ee', ink: '#2b2b2b', mute: '#77736a' },
  white: { bg: '#ffffff', ink: '#222222', mute: '#777777' },
  dark: { bg: '#17191d', ink: '#ecebe6', mute: '#9a9a94' },
  blueprint: { bg: '#123a63', ink: '#e8f1fa', mute: '#a9c4de' },
};
const FILL = {
  blue: ['#d8ecfa', '#2f7fbf'], green: ['#dcf2df', '#2f9e55'], red: ['#fcdcd8', '#d0453c'],
  yellow: ['#fdf2c4', '#c79a10'], orange: ['#fde4c8', '#d9771a'], purple: ['#e9e1fa', '#7354c4'],
  pink: ['#fbe0ea', '#cc4f83'], teal: ['#d3f1ec', '#1f9a8c'], gray: ['#ecebe6', '#6b6b66'], none: ['none', null],
};

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const textW = (s, size) => Math.max(...String(s).split('\n').map((l) => l.length)) * size * 0.54;

function rng(seed) {
  let s = 0;
  for (const c of String(seed)) s = (s * 31 + c.charCodeAt(0)) | 0;
  return () => { s = (s * 1664525 + 1013904223) | 0; return ((s >>> 8) & 0xffff) / 0xffff; };
}

// A line drawn by hand: slight bow and overshoot, always the same for one seed.
function roughLine(x1, y1, x2, y2, r, amp = 1.1) {
  const len = Math.hypot(x2 - x1, y2 - y1);
  const a = Math.min(amp, len * 0.02 + 0.3);
  const j = () => (r() - 0.5) * 2 * a;
  const mx = (x1 + x2) / 2 + j() * 1.4, my = (y1 + y2) / 2 + j() * 1.4;
  return `M${(x1 + j()).toFixed(1)} ${(y1 + j()).toFixed(1)} Q${mx.toFixed(1)} ${my.toFixed(1)} ${(x2 + j()).toFixed(1)} ${(y2 + j()).toFixed(1)}`;
}

function roughRect(x, y, w, h, stroke, fill, seed, sw = 1.8, radius = 0) {
  const r = rng(seed);
  let d = '';
  for (const pass of [0, 1]) {
    const k = pass ? 1.5 : 1;
    d += roughLine(x - k, y, x + w + k, y, r) + roughLine(x + w, y - k, x + w, y + h + k, r) + roughLine(x + w + k, y + h, x - k, y + h, r) + roughLine(x, y + h + k, x, y - k, r);
  }
  const f = fill && fill !== 'none' ? `<rect x="${x + 1.5}" y="${y + 1.5}" width="${w - 2}" height="${h - 2}" rx="${radius}" fill="${fill}"/>` : '';
  return `${f}<path d="${d}" fill="none" stroke="${stroke}" stroke-width="${sw}" stroke-linecap="round"/>`;
}

function curvePath(pts) {
  if (pts.length < 3) return pts.map((p, i) => `${i ? 'L' : 'M'}${p[0]} ${p[1]}`).join('');
  let d = `M${pts[0][0]} ${pts[0][1]}`;
  for (let i = 0; i + 1 < pts.length; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[i], c = pts[i + 1], e = pts[Math.min(pts.length - 1, i + 2)];
    d += `C${(b[0] + (c[0] - a[0]) / 6).toFixed(1)} ${(b[1] + (c[1] - a[1]) / 6).toFixed(1)} ${(c[0] - (e[0] - b[0]) / 6).toFixed(1)} ${(c[1] - (e[1] - b[1]) / 6).toFixed(1)} ${c[0]} ${c[1]}`;
  }
  return d;
}

function arrowHead(x, y, ang, color, size = 11) {
  const a = (t) => `${(x - Math.cos(ang + t) * size).toFixed(1)} ${(y - Math.sin(ang + t) * size).toFixed(1)}`;
  return `<path d="M${a(0.42)} L${x.toFixed(1)} ${y.toFixed(1)} L${a(-0.42)}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function textBlock(x, y, s, size, color, anchor = 'middle', weight = 400) {
  const lines = String(s).split('\n');
  const lh = size * 1.25;
  const y0 = y - ((lines.length - 1) * lh) / 2 + size * 0.34;
  return lines.map((l, i) => `<text x="${x}" y="${(y0 + i * lh).toFixed(1)}" font-size="${size}" fill="${color}" text-anchor="${anchor}" font-weight="${weight}">${esc(l)}</text>`).join('');
}

const wrap = (s, max, size) => {
  const per = Math.max(8, Math.floor(max / (size * 0.54)));
  const out = [];
  for (const para of String(s).split('\n')) {
    let line = '';
    for (const w of para.split(' ')) {
      if ((line + ' ' + w).trim().length > per) { out.push(line); line = w; } else line = (line + ' ' + w).trim();
    }
    out.push(line);
  }
  return out.join('\n');
};

const MAX_W = 1240;

function subtreeIds(n, out = new Set()) {
  const id = nodeId(n);
  if (id) out.add(id);
  if (!['model', 'sketch'].includes(n.cmd)) n.kids.forEach((k) => subtreeIds(k, out));
  return out;
}

// Measure: every element gets w/h. Place: every element gets x/y.
function measure(n, ctx) {
  const k = n.kv;
  const num = (key, d) => (k[key] === undefined ? d : Number(k[key]));
  const body = () => n.args.at(-1) ?? '';
  switch (n.cmd) {
    case 'row': case 'col': case 'card': {
      const row = n.cmd === 'row' || (n.cmd === 'card' && k.dir === 'row');
      const gap = num('gap', row ? 48 : 28);
      let flow = n.kids.filter((c) => c.cmd !== 'arrow');
      flow.forEach((c) => measure(c, ctx));
      // A row that is too wide wraps, so the model never has to count pixels.
      if (row && n.cmd === 'row' && flow.reduce((s, c) => s + c.w + gap, -gap) > MAX_W) {
        const lines = [[]];
        let used = 0;
        for (const c of flow) {
          if (used + c.w > MAX_W && lines.at(-1).length) { lines.push([]); used = 0; }
          lines.at(-1).push(c);
          used += c.w + gap;
        }
        const wrapped = lines.map((kids) => ({ cmd: 'row', args: [], kv: { gap: String(gap) }, kids, line: n.line }));
        wrapped.forEach((w) => measure(w, ctx));
        n.flow = wrapped; n.row = false; n.gap = 28; n.pad = 0; n.head = 0; n.gaps = [];
        n.w = Math.max(...wrapped.map((w) => w.w));
        n.h = wrapped.reduce((s, w) => s + w.h, 0) + 28 * (wrapped.length - 1);
        break;
      }
      // Leave room between neighbours when an arrow with a label runs between them.
      const gaps = flow.slice(1).map((c, i) => {
        let need = gap;
        for (const a of ctx.arrows) {
          const label = a.args[2];
          if (!label) continue;
          const [x, y] = [subtreeIds(flow[i]), subtreeIds(c)];
          if ((x.has(a.args[0]) && y.has(a.args[1])) || (x.has(a.args[1]) && y.has(a.args[0]))) need = Math.max(need, row ? textW(label, 16) + 44 : 70);
        }
        return need;
      });
      const main = flow.reduce((s, c) => s + (row ? c.w : c.h), 0) + gaps.reduce((s, g) => s + g, 0);
      const cross = Math.max(0, ...flow.map((c) => (row ? c.h : c.w)));
      const pad = n.cmd === 'card' ? 22 : 0;
      const head = n.cmd === 'card' && n.args[1] ? 34 : 0;
      n.w = (row ? main : cross) + pad * 2; n.h = (row ? cross : main) + pad * 2 + head;
      n.flow = flow; n.pad = pad; n.head = head; n.gap = gap; n.gaps = gaps; n.row = row;
      break;
    }
    case 'title': n.size = num('size', 38); n.w = textW(body(), n.size); n.h = n.size * 1.4; break;
    case 'h2': n.size = num('size', 26); n.w = textW(body(), n.size); n.h = n.size * 1.4; break;
    case 'text': n.size = num('size', 20); n.text = wrap(body(), num('w', 640), n.size); n.w = textW(n.text, n.size); n.h = n.text.split('\n').length * n.size * 1.25 + 2; break;
    case 'note': n.size = num('size', 19); n.text = wrap(body(), num('w', 260), n.size); n.w = textW(n.text, n.size) + 30; n.h = n.text.split('\n').length * n.size * 1.25 + 24; break;
    case 'box': case 'pill': case 'circle': case 'diamond': {
      n.size = num('size', 20);
      n.text = wrap(n.args[1] ?? '', num('w', 220) - 24, n.size);
      const tw = textW(n.text, n.size) + 40, th = n.text.split('\n').length * n.size * 1.25 + 36;
      n.w = Math.max(num('w', 0), tw, 90); n.h = Math.max(num('h', 0), th, 64);
      if (n.cmd === 'circle') n.w = n.h = Math.max(n.w, n.h);
      if (n.cmd === 'diamond') { n.w *= 1.5; n.h *= 1.5; }
      break;
    }
    case 'sketch': n.w = Number(n.args[1] ?? 240); n.h = Number(n.args[2] ?? 200); break;
    case 'model': n.w = Number(n.args[1] ?? 760); n.h = Number(n.args[2] ?? 460); break;
    case 'bars': { const items = points(k.data ?? ''); n.items = String(k.data ?? '').split(/[\s;]+/).map((s) => s.split(':')); n.w = num('w', 420); n.h = num('h', 240); void items; break; }
    case 'matrix': {
      n.rows = String(k.rows ?? n.args[1] ?? '').split(';').map((r) => r.split(','));
      n.cell = num('cell', 46);
      n.w = Math.max(...n.rows.map((r) => r.length)) * n.cell; n.h = n.rows.length * n.cell;
      break;
    }
    default:
      ctx.errors.push(`line ${n.line}: unknown element "${n.cmd}". Elements: title h2 text note box pill circle diamond row col card sketch model bars matrix arrow`);
      n.w = 0; n.h = 0; n.bad = true;
  }
}

function place(n, x, y) {
  n.x = x; n.y = y;
  if (!n.flow) return;
  let cur = (n.row ? x : y) + n.pad + (n.row ? 0 : n.head);
  const crossStart = (n.row ? y + n.head : x) + n.pad;
  const crossSize = (n.row ? n.h - n.head : n.w) - n.pad * 2;
  const align = n.kv.align ?? 'center';
  n.flow.forEach((c, i) => {
    const size = n.row ? c.h : c.w;
    const off = align === 'start' ? 0 : align === 'end' ? crossSize - size : (crossSize - size) / 2;
    const g = n.gaps[i] ?? n.gap;
    if (n.row) { place(c, cur, crossStart + off); cur += c.w + g; } else { place(c, crossStart + off, cur); cur += c.h + g; }
  });
}

function drawSketch(n, theme) {
  const r = rng(n.args[0] ?? n.line);
  let s = '';
  const ink = theme.ink;
  const col = (v, d = ink) => (FILL[v]?.[1] ?? v ?? d);
  const fil = (v) => (FILL[v]?.[0] ?? v ?? 'none');
  for (const k of n.kids) {
    const pts = points(k.kv.pts).map(([a, b]) => [a + n.x, b + n.y]);
    const sw = k.kv.sw ?? 2.4;
    if (k.cmd === 'line' || k.cmd === 'curve' || k.cmd === 'shape' || k.cmd === 'poly') {
      const closed = k.cmd === 'shape' || k.cmd === 'poly';
      let d;
      if (k.cmd === 'poly') { d = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0]} ${p[1]}`).join('') + 'Z'; } else if (k.cmd === 'line') { d = ''; for (let i = 0; i + 1 < pts.length; i++) d += roughLine(...pts[i], ...pts[i + 1], r); } else d = curvePath(closed ? [...pts, pts[0]] : pts) + (closed ? 'Z' : '');
      s += `<path d="${d}" fill="${closed ? fil(k.kv.fill) : 'none'}" stroke="${col(k.kv.color)}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
      if (k.kv.arrow) { const a = pts.at(-2), b = pts.at(-1); s += arrowHead(b[0], b[1], Math.atan2(b[1] - a[1], b[0] - a[0]), col(k.kv.color)); }
    } else if (k.cmd === 'dot') {
      const [cx, cy] = nums(k.args[0] ?? k.kv.at, [0, 0]);
      const rad = Number(k.kv.r ?? 18);
      s += `<ellipse cx="${n.x + cx}" cy="${n.y + cy}" rx="${rad}" ry="${rad * (0.96 + r() * 0.08)}" fill="${fil(k.kv.fill)}" stroke="${col(k.kv.color)}" stroke-width="${sw}"/>`;
    } else if (k.cmd === 'label') {
      const [cx, cy] = nums(k.args[0], [0, 0]);
      s += textBlock(n.x + cx, n.y + cy, k.args[1] ?? '', Number(k.kv.size ?? 17), col(k.kv.color), k.kv.anchor ?? 'middle');
    }
  }
  return s;
}

function drawModel(n, ctx, theme) {
  const k = n.kv;
  const parts = buildParts(n, ctx.errors);
  if (!parts.length) return '';
  const labels = new Map();
  parts.forEach((p, i) => {
    if (!p.label) return;
    const key = p.group ?? p.id;
    if (!labels.has(key)) labels.set(key, { text: p.label, idx: [] });
    labels.get(key).idx.push(i);
  });
  const marginX = labels.size ? Number(k.margin ?? 130) : 0;
  const [yaw, pitch] = nums(k.view, [35, 22]);
  const res = renderModel(parts, {
    w: Math.round(n.w), h: Math.round(n.h), yaw, pitch, cut: k.cut, explode: Number(k.explode ?? 0), marginX,
    ink: theme.bg === '#fbf7ee' || theme.bg === '#ffffff' ? [36, 38, 42] : [12, 14, 18],
  });
  const png = encodePng(res.rgba, res.w, res.h).toString('base64');
  let out = `<image x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" href="data:image/png;base64,${png}"/>`;
  const fl = floatingParts(parts);
  if (fl.length && !k.explode) ctx.lints.push(`model ${n.args[0] ?? ''}: not connected to the main body: ${fl.slice(0, 8).join(', ')}`);
  const hidden = new Set(res.stats.filter((s) => s.px < 4).map((s) => s.id));
  res.stats.forEach((s) => { if (s.px >= 4) hidden.delete(s.id); });
  for (const id of hidden) ctx.lints.push(`model ${n.args[0] ?? ''}: part "${id}" is not visible (hidden or too small)`);

  // Labels sit in two columns, sorted by height, so leaders never cross.
  const anchors = [];
  for (const [, l] of labels) {
    const pix = res.pixelsOf(l.idx);
    if (!pix.length) { ctx.lints.push(`label "${l.text}": its part is hidden in this view`); continue; }
    const mx = pix.reduce((s, p) => s + p[0], 0) / pix.length, my = pix.reduce((s, p) => s + p[1], 0) / pix.length;
    let best = pix[0], bd = 1e18;
    for (const p of pix) { const d = (p[0] - mx) ** 2 + (p[1] - my) ** 2; if (d < bd) { bd = d; best = p; } }
    anchors.push({ text: l.text, ax: best[0], ay: best[1] });
  }
  const mid = n.w / 2;
  const sides = [anchors.filter((a) => a.ax < mid), anchors.filter((a) => a.ax >= mid)];
  // Keep the sides balanced when one is crowded.
  while (Math.abs(sides[0].length - sides[1].length) > 2) {
    const [big, small] = sides[0].length > sides[1].length ? sides : [sides[1], sides[0]];
    big.sort((a, b) => Math.abs(a.ax - mid) - Math.abs(b.ax - mid));
    small.push(big.shift());
  }
  sides.forEach((side, si) => {
    side.sort((a, b) => a.ay - b.ay);
    const step = 40;
    const ys = side.map((a) => a.ay);
    for (let i = 1; i < ys.length; i++) ys[i] = Math.max(ys[i], ys[i - 1] + step);
    const over = ys.length ? ys.at(-1) - (n.h - 20) : 0;
    if (over > 0) ys.forEach((_, i) => { ys[i] -= over; });
    for (let i = ys.length - 2; i >= 0; i--) ys[i] = Math.min(ys[i], ys[i + 1] - step);
    side.forEach((a, i) => {
      const size = 18;
      const tw = textW(a.text, size) + 20;
      const lx = si === 0 ? Math.max(4, marginX - tw - 2) : Math.min(n.w - tw - 4, n.w - marginX + 2);
      const ex = si === 0 ? lx + tw : lx;
      const X = n.x, Y = n.y, ly = Math.max(16, ys[i]);
      out += `<path d="M${X + a.ax} ${Y + a.ay} L${X + ex} ${Y + ly}" stroke="${theme.ink}" stroke-width="1.5" fill="none"/>`;
      out += `<circle cx="${X + a.ax}" cy="${Y + a.ay}" r="3.5" fill="#fff" stroke="${theme.ink}" stroke-width="1.5"/>`;
      out += `<rect x="${X + lx}" y="${Y + ly - 14}" width="${tw}" height="28" rx="3" fill="#fffdf6" stroke="${theme.ink}" stroke-width="1.2"/>`;
      out += textBlock(X + lx + tw / 2, Y + ly, a.text, size, '#222');
    });
  });
  ctx.models.push({ node: n, res, parts });
  return out;
}

function draw(n, ctx, theme) {
  if (n.bad) return '';
  const k = n.kv;
  const [fill, stroke] = FILL[k.color] ?? FILL.gray;
  const id = nodeId(n);
  if (id) ctx.ids.set(id, n);
  const cx = n.x + n.w / 2, cy = n.y + n.h / 2;
  switch (n.cmd) {
    case 'row': case 'col': return n.flow.map((c) => draw(c, ctx, theme)).join('');
    case 'card': {
      let s = roughRect(n.x, n.y, n.w, n.h, FILL[k.color]?.[1] ?? theme.mute, k.color ? fill : 'none', id ?? n.line, 1.6);
      if (n.args[1]) s += textBlock(n.x + n.pad, n.y + 24, n.args[1], 22, theme.ink, 'start', 700);
      return s + n.flow.map((c) => draw(c, ctx, theme)).join('');
    }
    case 'title': case 'h2': return textBlock(n.x, cy, n.args.at(-1), n.size, theme.ink, 'start', 700);
    case 'text': return textBlock(n.x, cy, n.text, n.size, k.color ? (FILL[k.color]?.[1] ?? k.color) : theme.ink, 'start');
    case 'note': return `<rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" fill="${FILL[k.color ?? 'yellow']?.[0] ?? '#fdf2c4'}" transform="rotate(-1 ${cx} ${cy})"/>` + textBlock(n.x + 15, cy, n.text, n.size, '#333', 'start');
    case 'box': return roughRect(n.x, n.y, n.w, n.h, stroke, fill, id) + textBlock(cx, cy, n.text, n.size, '#222');
    case 'pill': return `<rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="${n.h / 2}" fill="${fill}" stroke="${stroke}" stroke-width="2"/>` + textBlock(cx, cy, n.text, n.size, '#222');
    case 'circle': return `<ellipse cx="${cx}" cy="${cy}" rx="${n.w / 2}" ry="${n.h / 2}" fill="${fill}" stroke="${stroke}" stroke-width="2"/>` + textBlock(cx, cy, n.text, n.size, '#222');
    case 'diamond': return `<path d="M${cx} ${n.y}L${n.x + n.w} ${cy}L${cx} ${n.y + n.h}L${n.x} ${cy}Z" fill="${fill}" stroke="${stroke}" stroke-width="2" stroke-linejoin="round"/>` + textBlock(cx, cy, n.text, n.size, '#222');
    case 'sketch': return drawSketch(n, theme);
    case 'model': return drawModel(n, ctx, theme);
    case 'bars': {
      const max = Math.max(...n.items.map((i) => Number(i[1]) || 0), 1e-9);
      const bw = n.w / n.items.length;
      return n.items.map(([lab, v], i) => {
        const h = ((Number(v) || 0) / max) * (n.h - 60);
        const x = n.x + i * bw + bw * 0.16;
        return roughRect(x, n.y + n.h - 30 - h, bw * 0.68, h, stroke, fill, `${id}${i}`) + textBlock(x + bw * 0.34, n.y + n.h - 12, lab, 16, theme.ink) + textBlock(x + bw * 0.34, n.y + n.h - 44 - h, v, 16, theme.ink);
      }).join('');
    }
    case 'matrix': return n.rows.map((r, j) => r.map((v, i) => {
      const x = n.x + i * n.cell, y = n.y + j * n.cell;
      return roughRect(x, y, n.cell, n.cell, stroke, fill, `${id}${i}${j}`, 1.4) + textBlock(x + n.cell / 2, y + n.cell / 2, v.trim(), 18, '#222');
    }).join('')).join('');
    default: return '';
  }
}

function boundaryPoint(n, tx, ty) {
  const cx = n.x + n.w / 2, cy = n.y + n.h / 2;
  const dx = tx - cx, dy = ty - cy;
  if (n.cmd === 'circle') { const l = Math.hypot(dx, dy) || 1; return [cx + (dx / l) * (n.w / 2 + 5), cy + (dy / l) * (n.h / 2 + 5)]; }
  const s = Math.min((n.w / 2 + 6) / (Math.abs(dx) || 1e-6), (n.h / 2 + 6) / (Math.abs(dy) || 1e-6));
  return [cx + dx * s, cy + dy * s];
}

function drawArrow(a, ctx, theme) {
  const [from, to, label] = a.args;
  const A = ctx.ids.get(from), B = ctx.ids.get(to);
  if (!A || !B) { ctx.errors.push(`line ${a.line}: arrow: no element "${!A ? from : to}". Ids: ${[...ctx.ids.keys()].join(' ')}`); return ''; }
  const col = FILL[a.kv.color]?.[1] ?? theme.ink;
  const [x1, y1] = boundaryPoint(A, B.x + B.w / 2, B.y + B.h / 2);
  const [x2, y2] = boundaryPoint(B, A.x + A.w / 2, A.y + A.h / 2);
  for (const [nid, n] of ctx.ids) {
    if (n === A || n === B || !['box', 'pill', 'circle', 'diamond', 'note'].includes(n.cmd)) continue;
    const steps = 24;
    for (let i = 1; i < steps; i++) {
      const x = x1 + ((x2 - x1) * i) / steps, y = y1 + ((y2 - y1) * i) / steps;
      if (x > n.x && x < n.x + n.w && y > n.y && y < n.y + n.h) { ctx.lints.push(`arrow ${from}->${to} runs through "${nid}"`); break; }
    }
  }
  const r = rng(`${from}${to}`);
  const dash = a.kv.dash ? ' stroke-dasharray="7 7"' : '';
  let s = `<path d="${roughLine(x1, y1, x2, y2, r)}" fill="none" stroke="${col}" stroke-width="2.2" stroke-linecap="round"${dash}/>`;
  s += arrowHead(x2, y2, Math.atan2(y2 - y1, x2 - x1), col);
  if (a.kv.both) s += arrowHead(x1, y1, Math.atan2(y1 - y2, x1 - x2), col);
  if (label) {
    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, tw = textW(label, 16) + 10;
    s += `<rect x="${mx - tw / 2}" y="${my - 12}" width="${tw}" height="24" fill="${theme.bg}"/>` + textBlock(mx, my, label, 16, theme.mute);
  }
  return s;
}

let fontCss = null;
function fonts() {
  if (fontCss) return fontCss;
  const f = readFileSync(new URL('../../vendor/markdraw/fonts/Excalifont-Regular.ttf', import.meta.url)).toString('base64');
  fontCss = `@font-face{font-family:Hand;src:url(data:font/ttf;base64,${f})}text{font-family:Hand,sans-serif}`;
  return fontCss;
}

// Full render of a tree. Errors never stop the drawing.
export function render(root) {
  const ctx = { errors: [], lints: [], ids: new Map(), models: [], arrows: [] };
  const canvas = root.kids.find((k) => k.cmd === 'canvas');
  const theme = THEMES[canvas?.args[0] ?? 'paper'] ?? THEMES.paper;
  const body = { cmd: 'col', args: [], kv: { gap: canvas?.kv.gap ?? 34, align: 'start' }, kids: [], line: 0 };
  const arrows = [];
  const pull = (n) => {
    n.kids = n.kids.filter((c) => {
      if (c.cmd === 'arrow') { arrows.push(c); return false; }
      if (!['model', 'sketch'].includes(c.cmd)) pull(c);
      return true;
    });
  };
  body.kids = root.kids.filter((k) => k.cmd !== 'canvas');
  pull(body);
  ctx.arrows = arrows;
  measure(body, ctx);
  const P = 44;
  place(body, P, P);
  const main = draw(body, ctx, theme);
  const lines = arrows.map((a) => drawArrow(a, ctx, theme)).join('');
  const W = Math.ceil(body.w + P * 2), H = Math.ceil(body.h + P * 2);
  if (W > 1700 || H > 1400) ctx.lints.push(`canvas is ${W}x${H}, which is large. Use smaller parts or a row less.`);
  ctx.ids.forEach((n, id) => {
    if (n.text && n.cmd !== 'text' && n.cmd !== 'note' && textW(n.text, n.size) > n.w) ctx.lints.push(`text in "${id}" overflows`);
  });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><style>${fonts()}</style><rect width="100%" height="100%" fill="${theme.bg}"/>${main}${lines}</svg>`;
  return { svg, W, H, ctx };
}

// The text the model reads back after each draw.
export function feedback(root, r) {
  const out = [];
  const items = [];
  r.ctx.ids.forEach((n, id) => { if (n.cmd !== 'sketch') items.push(`${id}:${n.cmd}@${Math.round(n.x)},${Math.round(n.y)}`); });
  out.push(`canvas ${r.W}x${r.H}`);
  if (items.length) out.push(`elements: ${items.join(' ')}`);
  for (const m of r.ctx.models) {
    const big = m.res.stats.filter((s) => s.px >= 4).sort((a, b) => b.px - a.px).map((s) => `${s.id}=${Math.round(s.px)}`);
    out.push(`model parts visible px: ${big.slice(0, 40).join(' ')}`);
  }
  if (r.ctx.errors.length) out.push(`ERRORS:\n${r.ctx.errors.join('\n')}`);
  if (r.ctx.lints.length) out.push(`LINTS:\n${r.ctx.lints.join('\n')}`);
  if (!r.ctx.errors.length && !r.ctx.lints.length) out.push('OK: no errors, no lints.');
  return out.join('\n');
}

// A user stroke as text: what it touches, in the model's own ids.
export function describeStroke(r, pts) {
  const hits = new Map();
  for (const [x, y] of pts) {
    r.ctx.ids.forEach((n, id) => { if (x >= n.x && x <= n.x + n.w && y >= n.y && y <= n.y + n.h && n.cmd !== 'model') hits.set(id, (hits.get(id) ?? 0) + 1); });
  }
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const closed = Math.hypot(pts[0][0] - pts.at(-1)[0], pts[0][1] - pts.at(-1)[1]) < 30;
  const box = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
  // A 3D part counts only if the mark holds a large share of what is visible of it.
  const inside = (x, y) => {
    const rx = (box[2] - box[0]) / 2 || 1, ry = (box[3] - box[1]) / 2 || 1;
    return ((x - (box[0] + box[2]) / 2) / rx) ** 2 + ((y - (box[1] + box[3]) / 2) / ry) ** 2 <= 1;
  };
  for (const m of r.ctx.models) {
    const n = m.node;
    const count = new Map();
    for (let x = box[0]; x <= box[2]; x += 3) {
      for (let y = box[1]; y <= box[3]; y += 3) {
        const lx = x - n.x, ly = y - n.y;
        if (lx < 0 || ly < 0 || lx >= n.w || ly >= n.h || !inside(x, y)) continue;
        const id = m.res.idAt(lx, ly);
        if (id) count.set(id, (count.get(id) ?? 0) + 9);
      }
    }
    for (const [id, px] of count) {
      const total = m.res.stats.filter((s) => s.id === id).reduce((t, s) => t + s.px, 0);
      if (px / total >= 0.35) hits.set(id, px / total);
    }
    // The part under the centre always counts, so a small mark on a big part hits it.
    const middle = m.res.idAt((box[0] + box[2]) / 2 - n.x, (box[1] + box[3]) / 2 - n.y);
    if (middle) hits.set(middle, Math.max(hits.get(middle) ?? 0, 1));
  }
  const list = [...hits.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id).slice(0, 6);
  return `user ${closed ? 'circled' : 'drew a line over'} ${list.join(', ') || 'empty space'} at ${box.map(Math.round).join(',')}`;
}

export { parse };
