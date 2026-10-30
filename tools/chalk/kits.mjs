// Kits are macros: one line expands into many colored parts. They give a quality
// floor that does not depend on the model. Each kit is plain Chalk.
import { parseLine, parse } from './parse.mjs';

const fmt = (v) => Number(v.toFixed(3));
const P = (a) => a.map((p) => p.map(fmt).join(',')).join(' ');

const KITS = {
  // Tank or digger track. Runs along X, centred.
  tracks(id, k) {
    const L = +(k.len ?? 6), H = +(k.h ?? 0.9), W = +(k.w ?? 0.6), n = +(k.wheels ?? 6), belt = k.color ?? 'rubber', rim = k.rim ?? 'darkmetal';
    const r = H * 0.27, top = H - 0.05, inner = L / 2 - H * 0.42;
    const loop = [[-inner - H * 0.42, H * 0.56], [-inner, top], [inner, top], [inner + H * 0.42, H * 0.56], [inner, 0.03], [-inner, 0.03]];
    let s = `group ${id}\n`;
    s += `  extrude ${id}_belt pts=${P(loop)} h=${W} axis=z color=${belt}\n`;
    const links = Math.round(L / (H * 0.2));
    s += `  repeat ${links} step=${fmt((2 * inner) / (links - 1))},0,0 at=${fmt(-inner)},0,0\n    box ${id}_lug size=${fmt(H * 0.09)},0.05,${fmt(W * 1.05)} round=0 color=dark\n`;
    s += `  repeat ${links} step=${fmt((2 * inner) / (links - 1))},0,0 at=${fmt(-inner)},${fmt(top + 0.01)},0\n    box ${id}_ltop size=${fmt(H * 0.09)},0.05,${fmt(W * 1.05)} round=0 color=dark\n`;
    s += `  repeat ${n} step=${fmt((2 * inner) / (n - 1))},0,0 at=${fmt(-inner)},${fmt(r + 0.08)},${fmt(W / 2 + 0.01)}\n    cyl ${id}_rw r=${fmt(r)} h=0.08 axis=z color=${rim}\n    cyl ${id}_hub r=${fmt(r * 0.35)} h=0.1 axis=z color=steel at=0,0,0.04\n`;
    s += `  gear ${id}_spr teeth=10 r=${fmt(H * 0.34)} h=0.1 axis=z at=${fmt(inner + H * 0.16)},${fmt(H * 0.56)},${fmt(W / 2 + 0.02)} color=steel\n`;
    s += `  cyl ${id}_idl r=${fmt(H * 0.3)} h=0.09 axis=z at=${fmt(-inner - H * 0.14)},${fmt(H * 0.56)},${fmt(W / 2 + 0.02)} color=${rim}\n`;
    return s;
  },
  // Road wheel: tyre, rim and spokes. Axle along Z.
  rimwheel(id, k) {
    const r = +(k.r ?? 0.35), w = +(k.w ?? 0.2), t = k.color ?? 'rubber', c = k.rim ?? 'alu', sp = +(k.spokes ?? 5);
    let s = `group ${id}\n  wheel ${id}_t r=${r} w=${w} axis=z color=${t}\n  cyl ${id}_r r=${fmt(r * 0.7)} hole=${fmt(r * 0.6)} h=${fmt(w * 0.8)} axis=z color=${c}\n  cyl ${id}_h r=${fmt(r * 0.18)} h=${fmt(w * 0.85)} axis=z color=${c}\n`;
    s += `  ring ${sp} r=${fmt(r * 0.4)} axis=z\n    box ${id}_s size=${fmt(r * 0.45)},${fmt(r * 0.11)},${fmt(w * 0.35)} round=0 color=${c}\n`;
    return s;
  },
  // Propeller with a spinner. Axis along Y by default, use rot to turn it.
  prop(id, k) {
    const r = +(k.r ?? 1), b = +(k.blades ?? 2), c = k.color ?? 'dark';
    let s = `group ${id}\n  lathe ${id}_sp pts=${fmt(-r * 0.03)},${fmt(r * 0.07)} ${fmt(r * 0.02)},${fmt(r * 0.07)} ${fmt(r * 0.09)},0.001 smooth=1 color=${k.hub ?? 'steel'}\n`;
    s += `  ring ${b} r=${fmt(r * 0.5)} axis=y\n    limb ${id}_b pts=${fmt(-r * 0.46)},0,0,${fmt(r * 0.02)} 0,0,${fmt(r * 0.05)},${fmt(r * 0.03)} ${fmt(r * 0.3)},0,${fmt(r * 0.03)},${fmt(r * 0.03)} ${fmt(r * 0.5)},0,0,${fmt(r * 0.012)} color=${c}\n`;
    return s;
  },
  // Standing or sitting person, feet at y=0, facing +X, 1.75 tall by default.
  person(id, k) {
    const h = +(k.height ?? 1.75), u = h / 1.75, skin = k.skin ?? 'skin', top = k.color ?? 'blue', leg = k.legs ?? 'navy', pose = k.pose ?? 'stand';
    const c = (v) => fmt(v * u);
    const hip = pose === 'sit' ? 0.5 : 0.93;
    let s = `group ${id}\n`;
    s += `  limb ${id}_torso pts=0,${c(hip)},0,${c(0.14)} 0,${c(hip + 0.3)},0,${c(0.16)} 0,${c(hip + 0.52)},0,${c(0.13)} color=${top}\n`;
    s += `  sphere ${id}_head r=${c(0.115)} at=${c(0.01)},${c(hip + 0.72)},0 color=${skin}\n`;
    s += `  limb ${id}_neck pts=0,${c(hip + 0.52)},0,${c(0.05)} 0,${c(hip + 0.64)},0,${c(0.05)} color=${skin}\n`;
    s += `  mirror z\n`;
    if (pose === 'sit') {
      s += `    limb ${id}_leg pts=0,${c(hip)},${c(0.1)},${c(0.08)} ${c(0.4)},${c(hip)},${c(0.1)},${c(0.065)} ${c(0.45)},${c(0.1)},${c(0.1)},${c(0.05)} color=${leg}\n`;
      s += `    limb ${id}_foot pts=${c(0.42)},${c(0.05)},${c(0.1)},${c(0.05)} ${c(0.6)},${c(0.04)},${c(0.1)},${c(0.04)} color=dark\n`;
    } else {
      s += `    limb ${id}_leg pts=0,${c(hip)},${c(0.1)},${c(0.08)} ${c(0.02)},${c(0.5)},${c(0.1)},${c(0.06)} 0,${c(0.08)},${c(0.1)},${c(0.05)} color=${leg}\n`;
      s += `    limb ${id}_foot pts=${c(-0.02)},${c(0.05)},${c(0.1)},${c(0.05)} ${c(0.2)},${c(0.04)},${c(0.1)},${c(0.04)} color=dark\n`;
    }
    const raise = pose === 'wave';
    s += `    limb ${id}_arm pts=0,${c(hip + 0.48)},${c(0.19)},${c(0.055)} ${c(0.04)},${c(hip + (raise ? 0.6 : 0.22))},${c(raise ? 0.32 : 0.22)},${c(0.045)} ${c(0.1)},${c(hip + (raise ? 0.85 : 0.0))},${c(raise ? 0.38 : 0.24)},${c(0.04)} color=${top}\n`;
    s += `    sphere ${id}_hand r=${c(0.045)} at=${c(0.1)},${c(hip + (raise ? 0.9 : -0.05))},${c(raise ? 0.38 : 0.24)} color=${skin}\n`;
    return s;
  },
  // Four-legged animal with real anatomy. Head toward +x, feet at y=0.
  // Numbers are shares of the shoulder height. Good defaults fit a horse.
  quadruped(id, k) {
    const H = +(k.height ?? 1.6), L = +(k.length ?? 1.05) * H, leg = +(k.leg ?? 0.56) * H, deep = +(k.depth ?? 0.24) * H;
    const neckL = +(k.neck ?? 0.55) * H, neckA = (+(k.neckangle ?? 45) * Math.PI) / 180, head = +(k.head ?? 0.42) * H, thick = +(k.thick ?? 1), c = k.color ?? 'brown', hoof = k.hoof ?? 'dark';
    const f = (v) => fmt(v);
    const sn = +(k.snout ?? 1);
    const yb = leg + deep * 0.8, xc = L * 0.34, xh = -L * 0.34, z = deep * 0.48;
    const nx = xc + L * 0.14 + Math.cos(neckA) * neckL, ny = yb + deep * 0.4 + Math.sin(neckA) * neckL;
    const hx = nx + head * 0.55, hy = ny - head * 0.28;
    let s = `group ${id}\n  blob ${id}_skin k=0.45 color=${c}\n`;
    s += `    limb ${id}_trunk pts=${f(xh - L * 0.08)},${f(yb + deep * 0.1)},0,${f(deep * 0.86)} ${f(xh + L * 0.15)},${f(yb)},0,${f(deep * 0.93)} ${f(0)},${f(yb - deep * 0.02)},0,${f(deep * 0.9)} ${f(xc)},${f(yb + deep * 0.05)},0,${f(deep)}\n`;
    s += `    limb ${id}_neck pts=${f(xc + L * 0.08)},${f(yb + deep * 0.3)},0,${f(deep * 0.68)} ${f(xc + L * 0.14 + Math.cos(neckA) * neckL * 0.55)},${f(yb + Math.sin(neckA) * neckL * 0.6 + deep * 0.3)},0,${f(deep * 0.42)} ${f(nx)},${f(ny)},0,${f(deep * 0.3)}\n`;
    s += `    limb ${id}_skull pts=${f(nx)},${f(ny)},0,${f(head * 0.27)} ${f(hx)},${f(hy)},0,${f(head * 0.2)}\n`;
    s += `    limb ${id}_muzzle pts=${f(hx)},${f(hy)},0,${f(head * 0.2)} ${f(hx + (nx + head * 1.02 - hx) * sn)},${f(hy + (ny - head * 0.5 - hy) * sn)},0,${f(head * 0.13)}\n`;
    s += `    mirror z\n`;
    const legs = [[xc, 1, 0.6], [xh, 1.25, 0.72]];
    legs.forEach(([x, w, bend], i) => {
      const dir = i ? -1 : 1, r0 = deep * 0.34 * w * thick, r1 = deep * 0.15 * thick;
      s += `      limb ${id}_leg${i} pts=${f(x)},${f(yb - deep * 0.3)},${f(z)},${f(r0 * 1.1)} ${f(x - dir * L * 0.015)},${f(leg * bend)},${f(z)},${f(r0 * 0.72)} ${f(x + dir * L * 0.02)},${f(leg * 0.34)},${f(z)},${f(r1 * 1.1)} ${f(x)},${f(leg * 0.1)},${f(z)},${f(r1 * 0.9)} ${f(x + L * 0.02)},${f(0.03 * H)},${f(z)},${f(r1 * 1.2)}\n`;
    });
    const tl = +(k.tail ?? 0.55) * H;
    s += `  limb ${id}_tail pts=${f(xh - L * 0.17)},${f(yb + deep * 0.5)},0,${f(deep * 0.1)} ${f(xh - L * 0.24)},${f(yb + deep * 0.1)},0,${f(deep * 0.09)} ${f(xh - L * 0.26)},${f(yb - tl * 0.7)},0,${f(deep * 0.1)} ${f(xh - L * 0.25)},${f(yb - tl)},0,${f(deep * 0.04)} color=${k.tailcolor ?? 'dark'}\n`;
    const ear = k.ears ?? 'pointy';
    s += `  mirror z\n    sphere ${id}_eye r=${f(head * 0.045)} at=${f(nx + head * 0.2)},${f(ny + head * 0.05)},${f(head * 0.2)} color=black\n`;
    if (ear === 'pointy') s += `    cone ${id}_ear r=${f(head * 0.09)} h=${f(head * 0.3)} at=${f(nx - head * 0.08)},${f(ny + head * 0.3)},${f(head * 0.13)} color=${c}\n`;
    if (ear === 'floppy') s += `    limb ${id}_ear pts=${f(nx - head * 0.05)},${f(ny + head * 0.1)},${f(head * 0.2)},${f(head * 0.07)} ${f(nx - head * 0.1)},${f(ny - head * 0.3)},${f(head * 0.28)},${f(head * 0.1)} color=${k.earcolor ?? c}\n`;
    if (ear === 'round') s += `    sphere ${id}_ear r=${f(head * 0.13)} at=${f(nx - head * 0.08)},${f(ny + head * 0.27)},${f(head * 0.18)} color=${c}\n`;
    if (ear === 'big') s += `    sphere ${id}_ear r=${f(head)} scale=0.75,1,0.1 at=${f(nx - head * 0.35)},${f(ny + head * 0.1)},${f(deep * 0.55)} rot=0,-20,0 color=${k.earcolor ?? c}\n`;
    if (k.horns) s += `    limb ${id}_horn pts=${f(nx - head * 0.05)},${f(ny + head * 0.22)},${f(head * 0.13)},${f(head * 0.06)} ${f(nx - head * 0.05)},${f(ny + head * 0.62)},${f(head * 0.3)},${f(head * 0.04)} ${f(nx + head * 0.15)},${f(ny + head * 0.85)},${f(head * 0.32)},${f(head * 0.01)} color=${k.horns === '1' ? 'white' : k.horns}\n`;
    if (k.tusks) s += `    limb ${id}_tusk pts=${f(hx)},${f(hy - head * 0.15)},${f(head * 0.16)},${f(head * 0.07)} ${f(hx + head * 0.35)},${f(hy - head * 0.55)},${f(head * 0.2)},${f(head * 0.05)} ${f(hx + head * 0.8)},${f(hy - head * 0.5)},${f(head * 0.2)},${f(head * 0.012)} color=white\n`;
    if (k.trunk) {
      s += `  limb ${id}_trk pts=${f(hx)},${f(hy)},0,${f(head * 0.2)} ${f(hx + head * 0.45)},${f(hy - leg * 0.3)},0,${f(head * 0.15)} ${f(hx + head * 0.55)},${f(hy - leg * 0.7)},0,${f(head * 0.1)} ${f(hx + head * 0.4)},${f(hy - leg * 0.98)},0,${f(head * 0.07)} color=${c}\n`;
    }
    if (k.mane) s += `  limb ${id}_mane pts=${f(xc + L * 0.02)},${f(yb + deep * 1.05)},0,${f(deep * 0.1)} ${f(xc + L * 0.1 + Math.cos(neckA) * neckL * 0.55)},${f(yb + Math.sin(neckA) * neckL * 0.62 + deep * 0.72)},0,${f(deep * 0.13)} ${f(nx - head * 0.08)},${f(ny + head * 0.26)},0,${f(deep * 0.1)} color=${k.mane === '1' ? 'dark' : k.mane}\n`;
    return s;
  },
  // Fish or shark, nose at +x.
  fish(id, k) {
    const L = +(k.length ?? 3), d = +(k.depth ?? 0.2) * L, c = k.color ?? 'gray', fin = k.fin ?? c;
    const f = fmt;
    let s = `group ${id}\n  blob ${id}_skin k=0.5 color=${c}\n    limb ${id}_b pts=${f(L * 0.5)},0,0,${f(d * 0.08)} ${f(L * 0.3)},0,0,${f(d * 0.42)} ${f(L * 0.05)},0,0,${f(d * 0.5)} ${f(-L * 0.25)},0,0,${f(d * 0.3)} ${f(-L * 0.45)},0,0,${f(d * 0.08)}\n`;
    s += `  plate ${id}_dorsal pts=${f(L * 0.08)},${f(d * 0.4)} ${f(-L * 0.08)},${f(d * 1.05)} ${f(-L * 0.12)},${f(d * 0.35)} h=${f(d * 0.06)} color=${fin}\n`;
    s += `  plate ${id}_tail pts=${f(-L * 0.44)},0 ${f(-L * 0.6)},${f(d * 0.85)} ${f(-L * 0.53)},0 ${f(-L * 0.58)},${f(-d * 0.55)} h=${f(d * 0.06)} color=${fin}\n`;
    s += `  mirror z\n    plate ${id}_pec pts=${f(L * 0.15)},0 ${f(L * 0.02)},${f(-d * 0.7)} ${f(-L * 0.03)},0 h=${f(d * 0.05)} rot=25,0,0 at=0,${f(-d * 0.2)},${f(d * 0.42)} color=${fin}\n    sphere ${id}_eye r=${f(d * 0.05)} at=${f(L * 0.33)},${f(d * 0.08)},${f(d * 0.3)} color=black\n`;
    return s;
  },
  // Two gears that really mesh. Both lie in the XY plane, axles along z.
  // In `anim`, write: drive pair turns=3
  gearpair(id, k) {
    const a = +(k.teeth1 ?? 12), b = +(k.teeth2 ?? 36), m = +(k.module ?? 0.1), h = +(k.h ?? 0.3);
    const ra = (m * a) / 2, rb = (m * b) / 2, gap = ra + rb;
    let s = `group ${id}\n`;
    s += `  group ${id}_a at=${fmt(-gap / 2)},0,0 axis=z\n    gear ${id}_ga teeth=${a} r=${fmt(ra)} h=${h} axis=z color=${k.color1 ?? 'orange'}\n    cyl ${id}_sa r=${fmt(ra * 0.28)} h=${fmt(h * 2.6)} axis=z color=steel\n    box ${id}_ma size=${fmt(ra * 0.7)},${fmt(ra * 0.16)},${fmt(h * 1.1)} at=${fmt(ra * 0.5)},0,0 color=white\n`;
    s += `  group ${id}_b at=${fmt(gap / 2)},0,0 axis=z\n    gear ${id}_gb teeth=${b} r=${fmt(rb)} h=${h} phase=${fmt(Math.PI + Math.PI / b)} axis=z color=${k.color2 ?? 'blue'}\n    cyl ${id}_sb r=${fmt(ra * 0.28)} h=${fmt(h * 2.6)} axis=z color=steel\n    box ${id}_mb size=${fmt(rb * 0.6)},${fmt(ra * 0.16)},${fmt(h * 1.1)} at=${fmt(rb * 0.45)},0,0 color=white\n`;
    return s;
  },
  // Tree: trunk and clumps of leaves.
  tree(id, k) {
    const h = +(k.height ?? 5), c = k.color ?? 'green';
    return `group ${id}\n  limb ${id}_t pts=0,0,0,${fmt(h * 0.05)} 0,${fmt(h * 0.5)},0,${fmt(h * 0.03)} ${fmt(h * 0.03)},${fmt(h * 0.7)},0,${fmt(h * 0.015)} color=brown\n  sphere ${id}_a r=${fmt(h * 0.28)} at=0,${fmt(h * 0.72)},0 color=${c}\n  sphere ${id}_b r=${fmt(h * 0.2)} at=${fmt(h * 0.2)},${fmt(h * 0.6)},${fmt(h * 0.08)} color=${c}\n  sphere ${id}_c r=${fmt(h * 0.2)} at=${fmt(-h * 0.2)},${fmt(h * 0.62)},${fmt(-h * 0.06)} color=${c}\n`;
  },
  // Row of ventilation slots on a surface, in the XZ plane.
  vents(id, k) {
    const n = +(k.n ?? 6), w = +(k.w ?? 1), d = +(k.d ?? 0.1), g = +(k.gap ?? 0.18), c = k.color ?? 'black';
    return `repeat ${n} step=0,0,${g} id=${id}\n  box ${id}_v size=${w},0.02,${d} round=0 color=${c}\n`;
  },
  // Small parts scattered on a board, the same layout for one id.
  scatter(id, k) {
    const [w, d] = (k.area ?? '6,4').split(',').map(Number), n = +(k.n ?? 40), sz = +(k.size ?? 0.12);
    let seed = 7;
    for (const c of id) seed = (seed * 31 + c.charCodeAt(0)) >>> 0;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 2 ** 32; };
    const colors = (k.colors ?? 'black,dark,gold,gray,brown').split(',');
    let s = `group ${id}\n`;
    for (let i = 0; i < n; i++) {
      const x = fmt((rnd() - 0.5) * w), z = fmt((rnd() - 0.5) * d), a = fmt(sz * (0.5 + rnd())), b = fmt(sz * (0.5 + rnd()));
      s += `  box ${id}${i} size=${a},${fmt(sz * 0.5)},${b} round=0 at=${x},0,${z} color=${colors[i % colors.length]}\n`;
    }
    return s;
  },
};
export const KIT_NAMES = Object.keys(KITS);

const keep = ['at', 'rot', 'scale', 'label', 'shell', 'mat'];

// Walks a list of model nodes and replaces kit lines by their expansion.
export function expandKits(kids) {
  return kids.flatMap((n) => {
    if (n.cmd === 'mirror' || n.cmd === 'group' || n.cmd === 'repeat' || n.cmd === 'ring') {
      return [{ ...n, kids: expandKits(n.kids) }];
    }
    const kit = KITS[n.cmd];
    if (!kit) return [n];
    const id = n.args[0] ?? `kit${n.line}`;
    const body = parse(kit(id, n.kv)).root.kids;
    body.forEach(function mark(b) { b.line = n.line; b.kit = true; b.kids.forEach(mark); });
    const wrapper = { cmd: 'group', args: [id], kv: {}, kids: body, line: n.line };
    if (n.cmd === 'gearpair') wrapper.gearset = { a: `${id}_a`, b: `${id}_b`, ratio: Number(n.kv.teeth1 ?? 12) / Number(n.kv.teeth2 ?? 36) };
    for (const k of keep) if (n.kv[k] !== undefined) wrapper.kv[k] = n.kv[k];
    return [wrapper];
  });
}
void parseLine;
